//
//  WebServer.swift
//  HaloLink macOS host
//
//  Minimal HTTP/1.1 server (Network.framework) implementing the browser fallback:
//    GET  /            -> self-contained dark web client (WebPage.html)
//    GET  /mjpg        -> multipart/x-mixed-replace MJPEG (per-client latest-frame slot)
//    POST /input       -> JSON control frames (touch/scroll/key/text) -> CGEvent
//    GET  /status      -> JSON status
//    GET  /healthz     -> "ok"
//
//  Each MJPEG client gets its own bounded one-frame slot + a timer on the HTTP
//  queue, so a slow/stalled browser cannot stall the capture pipeline.
//

import Foundation
import Network

final class WebServer {
    private let port: UInt16
    private let hub: MJPEGHub
    private let inputInjector: InputInjector
    private let statusProvider: () -> [String: Any]
    private let queue = DispatchQueue(label: "com.halolink.http", qos: .userInitiated)
    private let boundary = "halolinkframe"

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private(set) var isRunning = false
    private(set) var webClientConnections = 0
    private let stateLock = NSLock()

    init(port: Int, hub: MJPEGHub, inputInjector: InputInjector,
         statusProvider: @escaping () -> [String: Any]) {
        self.port = UInt16(clamping: port)
        self.hub = hub
        self.inputInjector = inputInjector
        self.statusProvider = statusProvider
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HaloLinkError("invalid HTTP port \(port)")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        var readyError: Error?
        let readySemaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readySemaphore.signal()
            case .failed(let error):
                readyError = error
                readySemaphore.signal()
            case .cancelled:
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        if readySemaphore.wait(timeout: .now() + 5.0) == .timedOut {
            listener.cancel()
            throw HaloLinkError("HTTP listener did not become ready on port \(port)")
        }
        if let error = readyError {
            throw HaloLinkError("HTTP server failed to listen on port \(port): " +
                                error.localizedDescription)
        }
        self.listener = listener
        isRunning = true
        let address = NetworkInfo.preferredLANAddress() ?? "127.0.0.1"
        Log.info("web server: http://\(address):\(port)/ (MJPEG + touch, no install needed)")
        if let alternate = NetworkInfo.activeLANAddresses().first(where: {
            !$0.hasSuffix(address)
        }) {
            Log.debug("web server: other interfaces \(alternate)")
        }
    }

    func stop() {
        queue.sync {
            guard self.isRunning else { return }
            self.isRunning = false
            self.listener?.cancel()
            self.listener = nil
            for (_, connection) in self.connections {
                connection.close()
            }
            self.connections.removeAll()
        }
        hub.stop()
        Log.info("web server stopped")
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let http = HTTPConnection(connection: connection, server: self,
                                  queue: queue, boundary: boundary,
                                  hub: hub, inputInjector: inputInjector,
                                  statusProvider: statusProvider)
        stateLock.lock()
        connections[ObjectIdentifier(http)] = http
        webClientConnections += 1
        let count = webClientConnections
        stateLock.unlock()
        if count == 1 {
            Log.info("web client connected (total \(count))")
        } else {
            Log.debug("web connection opened (total \(count))")
        }
        http.start()
    }

    fileprivate func connectionDidClose(_ http: HTTPConnection) {
        stateLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(http))
        webClientConnections = max(0, webClientConnections - 1)
        let remaining = webClientConnections
        stateLock.unlock()
        if remaining == 0 {
            Log.info("web clients disconnected (total 0)")
        } else {
            Log.debug("web connection closed (total \(remaining))")
        }
    }
}

// MARK: - One HTTP connection

final class HTTPConnection {
    private let connection: NWConnection
    private weak var server: WebServer?
    private let queue: DispatchQueue
    private let boundary: String
    private let hub: MJPEGHub
    private let inputInjector: InputInjector
    private let statusProvider: () -> [String: Any]

    private var buffer = Data()
    private var headerParsed = false
    private var method = ""
    private var path = ""
    private var query: [String: String] = [:]
    private var httpVersion = "HTTP/1.1"
    private var contentLength = 0
    private var body = Data()
    private var closed = false

    // MJPEG state
    private var mjpegClient: MJPEGClient?
    private var streamTimer: DispatchSourceTimer?
    private var sendingChunk = false
    private var chunkSendStart: TimeInterval = 0

    private var idleTimer: DispatchSourceTimer?

    init(connection: NWConnection, server: WebServer, queue: DispatchQueue,
         boundary: String, hub: MJPEGHub, inputInjector: InputInjector,
         statusProvider: @escaping () -> [String: Any]) {
        self.connection = connection
        self.server = server
        self.queue = queue
        self.boundary = boundary
        self.hub = hub
        self.inputInjector = inputInjector
        self.statusProvider = statusProvider
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        idleTimer = DispatchSource.makeTimerSource(queue: queue)
        idleTimer?.schedule(deadline: .now() + 30, repeating: 30)
        idleTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.mjpegClient == nil && !self.closed {
                self.close()
            }
        }
        idleTimer?.resume()
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                Log.debug("http receive error: \(error.localizedDescription)")
                self.close()
                return
            }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            if isComplete {
                self.close()
                return
            }
            let needsMore = (!self.closed && !self.headerParsed) ||
                (!self.closed && self.contentLength > self.body.count)
            if needsMore {
                self.receive()
            }
        }
    }

    private func process() {
        guard !closed else { return }
        if !headerParsed {
            let marker = Data("\r\n\r\n".utf8)
            guard let range = buffer.range(of: marker) else {
                if buffer.count > 64 * 1024 {
                    respondText(status: 431, text: "request header too large")
                }
                return
            }
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard parseHeader(headerData) else {
                respondText(status: 400, text: "bad request")
                return
            }
            headerParsed = true
        }
        if contentLength > 0 && body.count < contentLength {
            let needed = contentLength - body.count
            let take = min(needed, buffer.count)
            if take > 0 {
                body.append(buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + take)))
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + take))
            }
            if body.count < contentLength {
                receive()
                return
            }
        }
        route()
    }

    private func parseHeader(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return false }
        method = String(parts[0]).uppercased()
        let target = String(parts[1])
        if parts.count >= 3 { httpVersion = String(parts[2]) }
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[..<questionMark])
            query = Self.parseQuery(String(target[target.index(after: questionMark)...]))
        } else {
            path = target
            query = [:]
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                contentLength = max(0, min(Int(value) ?? 0, 4 * 1024 * 1024))
            }
        }
        return true
    }

    private static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            result[key] = value.removingPercentEncoding ?? value
        }
        return result
    }

    // MARK: - Routing

    private func route() {
        idleTimer?.cancel()
        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"), ("GET", "/index.htm"):
            respond(status: 200, contentType: "text/html; charset=utf-8",
                    body: Data(WebPage.html.utf8))
        case ("GET", "/mjpg"), ("GET", "/stream.mjpg"), ("GET", "/mjpeg"):
            startMJPEG()
        case ("GET", "/status"):
            respondJSON(statusProvider())
        case ("GET", "/healthz"):
            respond(status: 200, contentType: "text/plain; charset=utf-8",
                    body: Data("ok".utf8))
        case ("POST", "/input"):
            handleInput()
        case ("GET", "/favicon.ico"):
            respond(status: 204, contentType: nil, body: Data())
        case ("OPTIONS", _):
            respond(status: 204, contentType: nil, body: Data())
        default:
            respondText(status: 404, text: "not found")
        }
    }

    private func handleInput() {
        if Log.verbose {
            let raw = String(data: body, encoding: .utf8) ?? "<binary>"
            Log.debug("web /input: \(String(raw.prefix(240)))")
        }
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let message = object as? [String: Any] else {
            respondJSON(["ok": false, "error": "invalid JSON body"], status: 400)
            return
        }
        inputInjector.handle(message)
        // Accept text-only bodies sent as form encoding (some browsers/preflights).
        respondJSON(["ok": true])
    }

    // MARK: - Responses

    private func corsHeaders() -> [(String, String)] {
        [
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "Content-Type"),
            ("Access-Control-Max-Age", "86400")
        ]
    }

    private func respond(status: Int, contentType: String?, body: Data,
                         closeAfter: Bool = true) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        if let contentType = contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n"
        head += "Pragma: no-cache\r\n"
        head += "Server: halolink/1.0\r\n"
        for (name, value) in corsHeaders() {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: \(closeAfter ? "close" : "keep-alive")\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        send(payload) { [weak self] in
            if closeAfter { self?.close() }
        }
    }

    private func respondJSON(_ object: [String: Any], status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data("{}".utf8)
        respond(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    private func respondText(status: Int, text: String) {
        respond(status: status, contentType: "text/plain; charset=utf-8",
                body: Data(text.utf8))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    // MARK: - MJPEG streaming

    private func startMJPEG() {
        let width = query["w"].flatMap { Int($0) }
        let quality = query["q"].flatMap { Double($0) }
        let fps = query["fps"].flatMap { Int($0) }
        guard let client = hub.registerClient(width: width, quality: quality, fps: fps) else {
            respondText(status: 503, text: "too many MJPEG clients")
            return
        }
        mjpegClient = client

        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n"
        head += "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n"
        head += "Pragma: no-cache\r\n"
        head += "Connection: close\r\n"
        head += "Server: halolink/1.0\r\n"
        for (name, value) in corsHeaders() {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        send(Data(head.utf8))

        let interval = 1.0 / Double(client.fps)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.005, repeating: interval,
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.pumpMJPEGFrame()
        }
        timer.resume()
        streamTimer = timer
        Log.info("mjpg stream started: w=\(client.requestedWidth) " +
                 "q=\(String(format: "%.2f", client.quality)) fps=\(client.fps)")
    }

    private func pumpMJPEGFrame() {
        guard !closed, let client = mjpegClient else { return }
        if sendingChunk {
            // A send completion that never fires (dead peer, half-open TCP after
            // tablet sleep) must not pin this connection forever.
            if chunkSendStart > 0 && Clock.now() - chunkSendStart > 5.0 {
                Log.warn("mjpg client stalled for >5s on a socket send; dropping connection")
                close()
            }
            return
        }
        guard let jpeg = client.takeIfNew() else { return }
        sendingChunk = true
        chunkSendStart = Clock.now()
        var chunk = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        chunk.append(jpeg)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            self.sendingChunk = false
            self.chunkSendStart = 0
            if error != nil { self.close() }
        })
    }

    // MARK: - Sending / closing

    private func send(_ data: Data, completion: (() -> Void)? = nil) {
        guard !closed else {
            completion?()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
                return
            }
            if let completion = completion {
                self?.queue.async(execute: completion)
            }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        streamTimer?.cancel()
        streamTimer = nil
        idleTimer?.cancel()
        idleTimer = nil
        if let client = mjpegClient {
            hub.removeClient(client)
            mjpegClient = nil
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        server?.connectionDidClose(self)
    }
}
