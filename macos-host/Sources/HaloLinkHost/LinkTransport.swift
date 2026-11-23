//
//  LinkTransport.swift
//  HaloLink macOS host
//
//  HLDP v1 transport (see specs/PROTOCOL.md).
//
//  Role: the Mac is the TCP *client* (the tablet app is the server). All frames
//  share one TCP connection:
//      1 byte type | 4 byte big-endian payload length | payload
//      0x01 VIDEO (Annex-B H.264 access unit)   Mac -> tablet
//      0x02 CONTROL (UTF-8 JSON)                both ways
//      0x03 PING (no payload)                   Mac -> tablet
//      0x04 PONG (no payload)                   tablet -> Mac
//
//  After connect both sides exchange one UTF-8 JSON *line* before switching to
//  binary framing:
//      tablet -> Mac : {"type":"hello",...}
//      Mac -> tablet : {"type":"config",...}
//      tablet -> Mac : {"type":"ready"}
//
//  `--listen` plays the server side of the handshake (hello/config/ready) and then
//  streams video to the inbound peer; it exists for debugging/reverse setups.
//

import Foundation
import Network

protocol LinkTransportDelegate: AnyObject {
    func transportDidBecomeReady(_ transport: LinkTransport)
    func transportDidClose(_ transport: LinkTransport, reason: String)
    /// Client mode: hello arrived before the host sent config. The host may adapt
    /// its virtual display / stream fps and must call `respond` exactly once.
    func transport(_ transport: LinkTransport, receivedHelloFor screen: [String: Any],
                   hello: [String: Any], respond: @escaping (HLDPConfiguration) -> Void)
    func transport(_ transport: LinkTransport, didReceiveControl message: [String: Any])
    /// HLDP v1.1: the tablet rotated / resized while streaming.
    func transport(_ transport: LinkTransport, didReceiveDisplay message: [String: Any])
    func transport(_ transport: LinkTransport, didMeasureRTT milliseconds: Double)
    func transportRequestsKeyframe(_ transport: LinkTransport)
}

struct HLDPConfiguration {
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int
    var profile: String
    var keyframeIntervalSeconds: Int
    // HLDP v1.1 additions (old tablet apps simply ignore them).
    var scaleMode: String = "fit"
    var retina: Bool = true
    var logicalWidth: Int = 0
    var logicalHeight: Int = 0
    var inputEnabled: Bool = false
    /// HLDP v1.2: "pixel1to1" (native 1:1, no scaling) or "scale" (HiDPI fit/fill).
    var renderMode: String = "scale"
    /// HLDP v1.3: prefix every VIDEO payload with an 8-byte BE capture timestamp
    /// (Unix microseconds) when the tablet advertises the "frameTs" feature.
    var frameTs: Bool = false
}

final class LinkTransport {
    enum Mode {
        case client(host: String, port: UInt16)
        case listener(port: UInt16)
    }

    enum FrameType: UInt8 {
        case video = 0x01
        case control = 0x02
        case ping = 0x03
        case pong = 0x04
    }

    private static let maxPayload = 16 * 1024 * 1024
    private static let handshakeTimeout: TimeInterval = 10.0

    weak var delegate: LinkTransportDelegate?
    let mode: Mode
    private(set) var configuration: HLDPConfiguration

    /// Called (on the main queue) when a client-mode `hello` arrives *before* the
    /// host answers with `config`. Lets the host adapt the virtual display / fps to
    /// the tablet's real panel first. The host must call `respond` exactly once;
    /// if it never does, the current config is sent after 8 seconds.
    var onHello: ((_ screen: [String: Any], _ hello: [String: Any],
                   _ respond: @escaping (HLDPConfiguration) -> Void) -> Void)?
    private let localDeviceDescription: String

    /// Called on the transport queue after a video frame is handed to the socket.
    var onVideoFrameSent: ((Int) -> Void)?
    /// Called when a video frame is dropped due to backpressure.
    var onVideoFrameDropped: (() -> Void)?
    /// Called with the time from encoder output to socket send completion (ms).
    var onVideoSendLatency: ((Double) -> Void)?

    private let queue = DispatchQueue(label: "com.halolink.transport", qos: .userInitiated)
    private let stateLock = NSLock()

    private var connection: NWConnection?
    private var listener: NWListener?
    private var connectionGeneration = 0
    private var stopping = false
    private var reconnectAttempt = 0
    private var isReadyInternal = false

    private var receiveBuffer = Data()
    private enum HandshakeStep {
        case awaitHello
        case awaitConfig
        case awaitConfigDecision   // hello received, host is adapting the display
        case awaitReady
        case streaming
    }
    private var handshakeStep: HandshakeStep = .awaitHello
    private var handshakeTimer: DispatchSourceTimer?
    private var helloDecisionTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var lastPingSent: Double = 0
    private var lastPongReceived: Double = 0
    private var queuedVideoBytes = 0
    private var maxQueuedVideoBytes = 4 * 1024 * 1024
    /// True until the first IDR of a new connection has been handed to the socket:
    /// guarantees the tablet's decoder starts on SPS/PPS + IDR, never on a P frame.
    private var awaitingFirstKeyframe = true
    private var frameTsLoggedOnce = false

    // Counters (accessed from the transport queue; exposed under stateLock).
    private var sentVideoFrames = 0
    private var sentVideoBytes = 0
    private var droppedVideoFrames = 0

    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isReadyInternal
    }

    struct Counters {
        let sentFrames: Int
        let sentBytes: Int
        let droppedFrames: Int
    }

    var counters: Counters {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Counters(sentFrames: sentVideoFrames, sentBytes: sentVideoBytes,
                        droppedFrames: droppedVideoFrames)
    }

    init(mode: Mode, configuration: HLDPConfiguration, localDeviceName: String) {
        self.mode = mode
        self.configuration = configuration
        let host = ProcessInfo.processInfo.hostName
        self.localDeviceDescription = "HaloLink on macOS (\(host))"
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopping = false
            switch self.mode {
            case .client(let host, let port):
                self.connectAsClient(host: host, port: port)
            case .listener(let port):
                self.startListener(port: port)
            }
        }
    }

    func stop() {
        queue.sync {
            self.stopping = true
            self.stopTimers()
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.receiveBuffer.removeAll()
            self.setState(ready: false)
            Log.info("TCP transport stopped")
        }
    }

    // MARK: - Client mode

    private func connectAsClient(host: String, port: UInt16) {
        guard !stopping else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            Log.error("invalid TCP port \(port)")
            return
        }
        Log.info("connecting to tablet server \(host):\(port) …")
        let parameters = tcpParameters()
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: nwPort, using: parameters)
        self.connection = connection
        connectionGeneration += 1
        let generation = connectionGeneration
        handshakeStep = .awaitHello
        receiveBuffer.removeAll()
        setState(ready: false)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, generation == self.connectionGeneration else { return }
            switch state {
            case .ready:
                Log.info("TCP connected to \(host):\(port)")
                self.armHandshakeTimeout()
                self.receiveLoop(connection, generation: generation)
            case .failed(let error):
                self.handleDisconnect(reason: "connect failed: \(error.localizedDescription)")
            case .waiting(let error):
                Log.debug("TCP waiting: \(error.localizedDescription)")
            case .cancelled:
                self.handleDisconnect(reason: "connection cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Listen mode

    private func startListener(port: UInt16) {
        guard !stopping else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            Log.error("invalid listen port \(port)")
            return
        }
        do {
            let parameters = tcpParameters()
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                if self.connection != nil {
                    Log.warn("rejecting extra inbound TCP connection while one is active")
                    connection.cancel()
                    return
                }
                Log.info("inbound TCP connection accepted (--listen mode)")
                self.attachListenerConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Log.info("listening for the tablet on tcp:\(port) (reverse/--listen mode)")
                case .failed(let error):
                    Log.error("TCP listener failed: \(error.localizedDescription)")
                    self?.handleDisconnect(reason: "listener failed")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Log.error("cannot listen on tcp:\(port): \(error.localizedDescription)")
        }
    }

    private func attachListenerConnection(_ connection: NWConnection) {
        self.connection = connection
        connectionGeneration += 1
        let generation = connectionGeneration
        receiveBuffer.removeAll()
        handshakeStep = .awaitConfig
        setState(ready: false)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, generation == self.connectionGeneration else { return }
            switch state {
            case .ready:
                self.armHandshakeTimeout()
                self.sendHelloLine()
                self.receiveLoop(connection, generation: generation)
            case .failed(let error):
                self.handleDisconnect(reason: "inbound connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.handleDisconnect(reason: "inbound connection closed")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func tcpParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true          // kill Nagle: saves ~40ms on small control frames
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            Log.debug("TCP options: TCP_NODELAY=on keepalive=on")
        }
        return parameters
    }

    // MARK: - Handshake

    private func armHandshakeTimeout() {
        handshakeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.handshakeTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isReady else { return }
            self.handleDisconnect(reason: "HLDP handshake timed out")
        }
        timer.resume()
        handshakeTimer = timer
    }

    private func sendHelloLine() {
        let screen: [String: Any] = [
            "width": configuration.width,
            "height": configuration.height,
            "density": 2.0,
            "refreshRate": configuration.fps
        ]
        let hello: [String: Any] = [
            "type": "hello",
            "protocol": "halolink/1",
            "device": localDeviceDescription,
            "model": "macOSHost",
            "screen": screen,
            "features": ["touch", "keyboard", "h264"],
            "appVersion": "1.0.0"
        ]
        sendJSONLine(hello)
    }

    private func configJSON(_ configuration: HLDPConfiguration) -> [String: Any] {
        var json: [String: Any] = [
            "type": "config",
            "codec": "h264",
            "width": configuration.width,
            "height": configuration.height,
            "fps": configuration.fps,
            "bitrate": configuration.bitrate,
            "profile": configuration.profile,
            "keyframeInterval": configuration.keyframeIntervalSeconds,
            // v1.1 (backwards compatible: old apps ignore unknown fields)
            "scaleMode": configuration.scaleMode,
            "retina": configuration.retina,
            "logicalWidth": configuration.logicalWidth,
            "logicalHeight": configuration.logicalHeight,
            "inputEnabled": configuration.inputEnabled,
            "renderMode": configuration.renderMode,
            "frameTs": configuration.frameTs
        ]
        json["protocol"] = "halolink/1.3"
        return json
    }

    private func sendConfigLine() {
        sendJSONLine(configJSON(configuration))
    }

    /// Re-sends `config` on an established link (rotation / scale-mode / input
    /// toggle). The tablet is expected to rebuild its decoder surface and request
    /// a keyframe (HLDP v1.1 §7.3).
    func sendConfig(_ configuration: HLDPConfiguration) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.configuration = configuration
            guard self.isReady else { return }
            Log.info("HLDP -> config (update): \(configuration.width)x" +
                     "\(configuration.height)@\(configuration.fps)fps " +
                     "scaleMode=\(configuration.scaleMode) retina=\(configuration.retina) " +
                     "logical=\(configuration.logicalWidth)x\(configuration.logicalHeight) " +
                     "input=\(configuration.inputEnabled)")
            self.sendJSONLine(self.configJSON(configuration), asControl: true)
        }
    }

    private func sendJSONLine(_ object: [String: Any], asControl: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            Log.error("cannot serialise handshake JSON")
            return
        }
        if asControl {
            sendFrame(.control, payload: data)
            return
        }
        var line = data
        line.append(0x0A)
        connection?.send(content: line, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.queue.async {
                    self?.handleDisconnect(reason: "send failed: \(error.localizedDescription)")
                }
            }
        })
        Log.debug("HLDP -> \(String(data: data, encoding: .utf8) ?? "?")")
    }

    private func handleHandshakeLine(_ line: String, generation: Int) {
        guard generation == connectionGeneration else { return }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              let type = message["type"] as? String else {
            handleDisconnect(reason: "invalid handshake line: \(line.prefix(200))")
            return
        }
        switch (handshakeStep, type) {
        case (.awaitHello, "hello"):
            let device = message["device"] as? String ?? "tablet"
            let screen = message["screen"] as? [String: Any] ?? [:]
            let screenText = "\(screen["width"] ?? "?")x\(screen["height"] ?? "?") " +
                "density=\(screen["density"] ?? "?") " +
                "hz=\(screen["refreshRate"] ?? "?")"
            Log.info("HLDP hello from \(device) screen=\(screenText)")
            if onHello != nil || delegate != nil {
                handshakeStep = .awaitConfigDecision
                // Do not let the generic handshake timeout fire while the host is
                // rebuilding the virtual display; the decision timer below guards it.
                handshakeTimer?.cancel()
                handshakeTimer = nil
                var responded = false
                let respond: (HLDPConfiguration) -> Void = { [weak self] newConfig in
                    guard let self = self else { return }
                    self.queue.async {
                        guard !responded, self.handshakeStep == .awaitConfigDecision,
                              !self.stopping else { return }
                        responded = true
                        self.helloDecisionTimer?.cancel()
                        self.helloDecisionTimer = nil
                        self.configuration = newConfig
                        self.handshakeStep = .awaitReady
                        self.sendConfigLine()
                        self.armHandshakeTimeout()
                    }
                }
                let fallback = DispatchSource.makeTimerSource(queue: queue)
                fallback.schedule(deadline: .now() + 8.0)
                fallback.setEventHandler { [weak self] in
                    guard let self = self, !responded else { return }
                    Log.warn("host did not adapt to the tablet screen within 8s; " +
                             "sending the current config")
                    respond(self.configuration)
                }
                fallback.resume()
                helloDecisionTimer = fallback
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let onHello = self.onHello {
                        onHello(screen, message, respond)
                    } else {
                        self.delegate?.transport(self, receivedHelloFor: screen,
                                                 hello: message, respond: respond)
                    }
                }
            } else {
                handshakeStep = .awaitReady
                sendConfigLine()
            }
        case (.awaitConfig, "config"):
            Log.info("HLDP config from peer: " +
                     "\(message["width"] ?? "?")x\(message["height"] ?? "?") " +
                     "@\(message["fps"] ?? "?")fps codec=\(message["codec"] ?? "?")")
            handshakeStep = .streaming
            sendJSONLine(["type": "ready"])
            completeHandshake()
        case (.awaitReady, "ready"):
            handshakeStep = .streaming
            completeHandshake()
        default:
            handleDisconnect(reason: "unexpected handshake message '\(type)' " +
                             "at step \(handshakeStep)")
        }
    }

    private func completeHandshake() {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        reconnectAttempt = 0
        awaitingFirstKeyframe = true
        lastPongReceived = Clock.now()
        lastPingSent = 0
        setState(ready: true)
        Log.info("HLDP handshake complete — streaming enabled")
        startPingTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.transportDidBecomeReady(self)
        }
    }

    // MARK: - Receive loop

    private func receiveLoop(_ connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self, generation == self.connectionGeneration else { return }
            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumeReceiveBuffer(generation: generation)
            }
            if let error = error {
                self.handleDisconnect(reason: "receive error: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.handleDisconnect(reason: "peer closed the connection")
                return
            }
            if !self.stopping && self.connection === connection {
                self.receiveLoop(connection, generation: generation)
            }
        }
    }

    private func consumeReceiveBuffer(generation: Int) {
        guard generation == connectionGeneration else { return }
        if handshakeStep != .streaming {
            let newline = Data([0x0A])
            while let range = receiveBuffer.range(of: newline) {
                let lineData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<range.lowerBound)
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<range.upperBound)
                guard let line = String(data: lineData, encoding: .utf8),
                      !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                handleHandshakeLine(line, generation: generation)
                if handshakeStep == .streaming { break }
            }
            if handshakeStep != .streaming && receiveBuffer.count > 64 * 1024 {
                handleDisconnect(reason: "handshake line too long")
            }
            return
        }
        while receiveBuffer.count >= 5 {
            let type = receiveBuffer[receiveBuffer.startIndex]
            let lengthBytes = receiveBuffer[(receiveBuffer.startIndex + 1)..<(receiveBuffer.startIndex + 5)]
            var length: UInt32 = 0
            for byte in lengthBytes { length = (length << 8) | UInt32(byte) }
            if length > UInt32(Self.maxPayload) {
                handleDisconnect(reason: "frame payload too large (\(length) bytes)")
                return
            }
            let total = 5 + Int(length)
            guard receiveBuffer.count >= total else { return }
            let payloadStart = receiveBuffer.startIndex + 5
            let payload = receiveBuffer.subdata(in: payloadStart..<(payloadStart + Int(length)))
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<(receiveBuffer.startIndex + total))
            handleFrame(type: type, payload: payload)
        }
    }

    private func handleFrame(type: UInt8, payload: Data) {
        switch FrameType(rawValue: type) {
        case .control:
            guard let object = try? JSONSerialization.jsonObject(with: payload),
                  let message = object as? [String: Any] else {
                Log.warn("malformed CONTROL JSON from peer")
                return
            }
            if let messageType = message["type"] as? String, messageType == "ping" {
                sendFrame(.pong, payload: Data())
                return
            }
            let isDisplayMessage = (message["type"] as? String) == "display"
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if isDisplayMessage {
                    self.delegate?.transport(self, didReceiveDisplay: message)
                } else {
                    self.delegate?.transport(self, didReceiveControl: message)
                }
            }
        case .ping:
            sendFrame(.pong, payload: Data())
        case .pong:
            let rtt = (Clock.now() - lastPingSent) * 1000.0
            lastPongReceived = Clock.now()
            if rtt > 0 && rtt < 60_000 {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.transport(self, didMeasureRTT: rtt)
                }
            }
        case .video:
            // The Mac never consumes video from the tablet in HLDP v1.
            break
        case .none:
            Log.debug("unknown frame type \(type) from peer")
        }
    }

    // MARK: - Sending

    func sendVideo(_ annexB: Data, isKeyframe: Bool,
                   captureTimestampUs: UInt64 = 0,
                   encodedAt: TimeInterval = 0) {
        // Check readiness *now*: frames encoded before the handshake completed must
        // not be queued (they would otherwise be flushed as stale P-frames right
        // after "ready").
        stateLock.lock()
        let readyNow = isReadyInternal
        stateLock.unlock()
        if Log.verbose, !frameTsLoggedOnce, configuration.frameTs, captureTimestampUs > 0 {
            frameTsLoggedOnce = true
            Log.debug("frameTs: first VIDEO frame carries epoch captureTs=" +
                      "\(captureTimestampUs)µs")
        }
        guard readyNow else { return }
        queue.async { [weak self] in
            guard let self = self, self.isReady, let connection = self.connection else {
                return
            }
            if self.awaitingFirstKeyframe {
                guard isKeyframe else {
                    self.noteDroppedVideo()
                    return
                }
                self.awaitingFirstKeyframe = false
            }
            guard annexB.count <= Self.maxPayload else {
                self.noteDroppedVideo()
                Log.warn("video frame larger than 16 MiB, dropped")
                return
            }
            if self.queuedVideoBytes > self.maxQueuedVideoBytes {
                self.noteDroppedVideo()
                DispatchQueue.main.async {
                    self.delegate?.transportRequestsKeyframe(self)
                }
                return
            }
            // HLDP v1.3: optional 8-byte big-endian capture timestamp prefix.
            var payload = annexB
            if self.configuration.frameTs, captureTimestampUs > 0 {
                var timestamp = captureTimestampUs.bigEndian
                var prefixed = Data(capacity: annexB.count + 8)
                withUnsafeBytes(of: &timestamp) { prefixed.append(contentsOf: $0) }
                prefixed.append(annexB)
                payload = prefixed
            }
            let frame = self.serializeFrame(.video, payload: payload)
            self.queuedVideoBytes += frame.count
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                self.queue.async {
                    self.queuedVideoBytes = max(0, self.queuedVideoBytes - frame.count)
                    if error != nil {
                        self.handleDisconnect(reason: "video send failed")
                    }
                }
                guard error == nil else { return }
                if encodedAt > 0 {
                    let sendMs = (Clock.now() - encodedAt) * 1000.0
                    self.onVideoSendLatency?(sendMs)
                }
                self.stateLock.lock()
                self.sentVideoFrames += 1
                self.sentVideoBytes += frame.count
                self.stateLock.unlock()
                self.onVideoFrameSent?(frame.count)
            })
        }
    }

    func sendControl(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        queue.async { [weak self] in
            guard let self = self, self.isReady else { return }
            self.sendFrame(.control, payload: data)
        }
    }

    private func sendFrame(_ type: FrameType, payload: Data) {
        guard let connection = connection else { return }
        connection.send(content: serializeFrame(type, payload: payload),
                        completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.queue.async {
                    self?.handleDisconnect(reason: "send failed: \(error.localizedDescription)")
                }
            }
        })
    }

    private func serializeFrame(_ type: FrameType, payload: Data) -> Data {
        var data = Data(capacity: payload.count + 5)
        data.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private func noteDroppedVideo() {
        stateLock.lock()
        droppedVideoFrames += 1
        stateLock.unlock()
        onVideoFrameDropped?()
    }

    // MARK: - Keepalive / teardown

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isReady else { return }
            let now = Clock.now()
            if now - self.lastPongReceived > 12.0 {
                Log.warn("no PONG from tablet for \(Int(now - self.lastPongReceived))s")
                self.handleDisconnect(reason: "keepalive timeout")
                return
            }
            if self.lastPingSent > 0 && self.lastPongReceived >= self.lastPingSent {
                // healthy
            }
            self.lastPingSent = now
            self.sendFrame(.ping, payload: Data())
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopTimers() {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        helloDecisionTimer?.cancel()
        helloDecisionTimer = nil
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func setState(ready: Bool) {
        stateLock.lock()
        isReadyInternal = ready
        stateLock.unlock()
    }

    private func handleDisconnect(reason: String) {
        guard !stopping else { return }
        let wasReady = isReady
        setState(ready: false)
        stopTimers()
        // Invalidate pending NWConnection callbacks for the dead connection.
        connectionGeneration += 1
        connection?.cancel()
        connection = nil
        awaitingFirstKeyframe = true
        queuedVideoBytes = 0
        receiveBuffer.removeAll()
        handshakeStep = .awaitHello
        queuedVideoBytes = 0
        if wasReady {
            Log.warn("HLDP link closed: \(reason)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.transportDidClose(self, reason: reason)
            }
        } else {
            Log.warn("HLDP link unavailable: \(reason)")
        }
        switch mode {
        case .client(let host, let port):
            reconnectAttempt += 1
            let delay = min(8.0, 0.5 * pow(2.0, Double(max(0, reconnectAttempt - 1))))
            Log.info(String(format: "reconnecting to %@:%u in %.1fs (attempt %d)",
                            host, port, delay, reconnectAttempt))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.stopping, self.connection == nil else { return }
                self.connectAsClient(host: host, port: port)
            }
        case .listener:
            // Wait for the next inbound connection (no action needed).
            Log.info("waiting for a new inbound connection")
        }
    }
}
