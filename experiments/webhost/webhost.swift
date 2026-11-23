// webhost.swift — minimal standalone MJPEG demo host for macOS.
//
//   CGVirtualDisplay (private API, via bridge.h + ObjC runtime)
//        -> extended virtual display, HiDPI 2x
//   ScreenCaptureKit (SCStream, NV12/420v)
//        -> CoreImage downscale (~1600 px wide) -> ImageIO JPEG (~0.55)
//        -> lock-protected "latest frame" slot
//   Network.framework HTTP:
//        GET  /         self-contained dark viewer page (<img src="/mjpg">)
//        GET  /mjpg     multipart/x-mixed-replace MJPEG stream
//        POST /input    JSON touch/scroll -> CGEvent injection (.cghidEventTap)
//        GET  /status   JSON stats
//        GET  /healthz  "ok"
//
// This is a fast demo/validation artifact, not the final product.
// Build: ./build.sh    Help: ./webhost --help

import Foundation
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import Network
import ScreenCaptureKit
import UniformTypeIdentifiers
import VDBridge

// ============================================================================
// MARK: - CLI
// ============================================================================

struct Options {
    var httpPort: UInt16 = 8080
    var width: Int = 1400          // logical points (HiDPI "looks like")
    var height: Int = 924          // logical points  (1400x924 @2x == 2800x1848)
    var scale: Int = 2             // backing scale: 2 = HiDPI
    var fps: Int = 30
    var seconds: Double = 0        // 0 = run forever
    var saveFramesDir: String? = nil
    var verbose: Bool = false
}

func usageText() -> String {
    return """
    webhost — minimal standalone MJPEG demo host (virtual display -> SCK -> JPEG -> HTTP)

    USAGE:
      ./webhost [options]

    OPTIONS:
      --http-port N      HTTP listen port (default 8080)
      --width N          logical width in points (default 1400)
      --height N         logical height in points (default 924)
      --scale N          backing scale, 2 = HiDPI (default 2)
      --fps N            capture / stream rate (default 30)
      --seconds N        auto-exit after N seconds of running (default 0 = forever)
      --save-frames DIR  save 3 PNG frames for verification
      --verbose          verbose per-frame / per-event logging
      --help, -h         show this help

    EXAMPLES:
      ./webhost --seconds 8 --save-frames /tmp/webhost-frames --verbose
      ./webhost --width 1280 --height 800 --fps 24
    """
}

func parseOptions() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8)); exit(2) }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--http-port":
            guard let v = UInt16(value(a)) else { FileHandle.standardError.write(Data("bad --http-port\n".utf8)); exit(2) }
            o.httpPort = v
        case "--width":
            guard let v = Int(value(a)), v > 0 else { FileHandle.standardError.write(Data("bad --width\n".utf8)); exit(2) }
            o.width = v
        case "--height":
            guard let v = Int(value(a)), v > 0 else { FileHandle.standardError.write(Data("bad --height\n".utf8)); exit(2) }
            o.height = v
        case "--scale":
            guard let v = Int(value(a)), v == 1 || v == 2 else { FileHandle.standardError.write(Data("bad --scale (1 or 2)\n".utf8)); exit(2) }
            o.scale = v
        case "--fps":
            guard let v = Int(value(a)), v >= 1, v <= 120 else { FileHandle.standardError.write(Data("bad --fps (1...120)\n".utf8)); exit(2) }
            o.fps = v
        case "--seconds":
            guard let v = Double(value(a)), v >= 0 else { FileHandle.standardError.write(Data("bad --seconds\n".utf8)); exit(2) }
            o.seconds = v
        case "--save-frames":
            o.saveFramesDir = value(a)
        case "--verbose":
            o.verbose = true
        case "--help", "-h":
            print(usageText())
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(a) (try --help)\n".utf8))
            exit(2)
        }
        i += 1
    }
    return o
}

// ============================================================================
// MARK: - Logging + small helpers
// ============================================================================

var verbose = false
let startTime = Date()

func stamp() -> String { return String(format: "%.3f", Date().timeIntervalSince(startTime)) }
func log(_ s: String) { print("[webhost \(stamp())] \(s)"); fflush(stdout) }
func vlog(_ s: String) { if verbose { log(s) } }
func fmt(_ r: CGRect) -> String { return String(format: "(%.0f,%.0f,%.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height) }

func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var n: UInt32 = 0
    guard CGGetOnlineDisplayList(32, &ids, &n) == .success else { return [] }
    return Array(ids.prefix(Int(n)))
}

func waitOnline(_ id: CGDirectDisplayID, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if onlineDisplayIDs().contains(id) { return true }
        usleep(100_000)
    }
    return false
}

/// Simple "first IPv4 on an en*/bridge* interface, else first non-loopback IPv4".
func lanIP() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var fallback: String?
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING), (flags & IFF_LOOPBACK) == 0 else { continue }
        guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: host)
        let name = String(cString: ptr.pointee.ifa_name)
        if name.hasPrefix("en") || name.hasPrefix("bridge") { return ip }
        if fallback == nil { fallback = ip }
    }
    return fallback
}

func displayModeInfo(_ id: CGDirectDisplayID) -> String {
    guard let m = CGDisplayCopyDisplayMode(id) else { return "unknown" }
    return String(format: "%dx%d pt / %dx%d px / %.0f Hz", m.width, m.height, m.pixelWidth, m.pixelHeight, m.refreshRate)
}

/// Put the virtual display immediately to the right of the main display (extended, not mirrored).
/// Returns the *actual* bounds afterwards (macOS may re-normalize the arrangement).
@discardableResult
func placeExtendedRight(_ vdID: CGDirectDisplayID) -> CGRect {
    let main = CGDisplayBounds(CGMainDisplayID())
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else {
        log("warning: CGBeginDisplayConfiguration failed; leaving default arrangement")
        return CGDisplayBounds(vdID)
    }
    let r1 = CGConfigureDisplayOrigin(cfg, vdID, Int32(main.maxX), Int32(main.minY))
    let r2 = CGConfigureDisplayMirrorOfDisplay(cfg, vdID, CGDirectDisplayID(0))  // 0 = kCGNullDirectDisplay = unmirror
    guard r1 == .success, r2 == .success, CGCompleteDisplayConfiguration(cfg, .forSession) == .success else {
        CGCancelDisplayConfiguration(cfg)
        log("warning: could not move virtual display (r1=\(r1.rawValue) r2=\(r2.rawValue))")
        return CGDisplayBounds(vdID)
    }
    usleep(400_000)
    return CGDisplayBounds(vdID)
}

/// Safety net from macOS-research §1.5: never let the invisible virtual display become the main display.
func ensurePhysicalStaysMain(_ vdID: CGDirectDisplayID) {
    guard CGMainDisplayID() == vdID else { return }
    log("warning: virtual display became main; restoring a physical display as main")
    guard let physical = onlineDisplayIDs().first(where: { $0 != vdID }) else { return }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
    _ = CGConfigureDisplayOrigin(cfg, physical, 0, 0)
    let pb = CGDisplayBounds(physical)
    _ = CGConfigureDisplayOrigin(cfg, vdID, Int32(pb.maxX), Int32(pb.minY))
    _ = CGCompleteDisplayConfiguration(cfg, .forSession)
    usleep(300_000)
}

func screen(for id: CGDirectDisplayID) -> NSScreen? {
    for s in NSScreen.screens {
        if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           CGDirectDisplayID(n.uint32Value) == id { return s }
    }
    return nil
}

// ============================================================================
// MARK: - Virtual display (CGVirtualDisplay private API)
// ============================================================================

enum VDError: LocalizedError {
    case classMissing, createFailed, applyFailed
    var errorDescription: String? {
        switch self {
        case .classMissing: return "CGVirtualDisplay class not found (private API unavailable on this macOS)"
        case .createFailed: return "CGVirtualDisplay(descriptor:) returned nil"
        case .applyFailed:  return "CGVirtualDisplay.apply(settings) returned false"
        }
    }
}

final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    private var display: CGVirtualDisplay?
    let logicalWidth: Int, logicalHeight: Int, scale: Int
    let physicalWidth: Int, physicalHeight: Int

    init(logicalWidth: Int, logicalHeight: Int, scale: Int, refresh: Double) throws {
        guard NSClassFromString("CGVirtualDisplay") != nil else { throw VDError.classMissing }
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.scale = scale
        let physW = logicalWidth * scale
        let physH = logicalHeight * scale
        self.physicalWidth = physW
        self.physicalHeight = physH

        // PPI >= 200 makes macOS treat it as Retina. Keep area > ~170 cm^2 (macOS 26.1 check).
        let ppi: Double = scale == 2 ? 220.0 : 110.0
        var mmW = Double(physW) * 25.4 / ppi
        var mmH = Double(physH) * 25.4 / ppi
        if mmW * mmH < 170 * 100 { mmW = 208; mmH = 96 }

        let desc = CGVirtualDisplayDescriptor()!
        desc.name = "Harmony Extend Web"
        desc.maxPixelsWide = UInt32(physW)
        desc.maxPixelsHigh = UInt32(physH)
        desc.sizeInMillimeters = CGSize(width: mmW, height: mmH)
        desc.vendorID = 0x484D                       // 'HM'
        desc.productID = UInt32(truncatingIfNeeded: physW * 10_000 + physH)
        desc.serialNum = 0x0007                      // fixed: macOS remembers arrangement for this serial
        desc.queue = DispatchQueue.main
        guard let vd = CGVirtualDisplay(descriptor: desc) else { throw VDError.createFailed }

        let settings = CGVirtualDisplaySettings()!
        settings.hiDPI = scale == 2 ? 1 : 0
        var modes: [CGVirtualDisplayMode] = []
        if scale == 2 {
            modes.append(CGVirtualDisplayMode(width: UInt32(physW), height: UInt32(physH), refreshRate: refresh))
        }
        modes.append(CGVirtualDisplayMode(width: UInt32(logicalWidth), height: UInt32(logicalHeight), refreshRate: refresh))
        settings.modes = modes
        guard vd.apply(settings) else { throw VDError.applyFailed }

        self.display = vd
        self.displayID = vd.displayID
        log("CGVirtualDisplay.apply(hiDPI=\(settings.hiDPI), modes=\(modes.count)) -> true, displayID=\(self.displayID)")
    }

    /// Releasing the CGVirtualDisplay object removes the screen from the system.
    func destroy() {
        guard display != nil else { return }
        display = nil
        log("CGVirtualDisplay released")
    }

    deinit {
        log("VirtualDisplay deinit (CGVirtualDisplay object deallocated)")
    }
}

// ============================================================================
// MARK: - Shared stats + latest-frame slot
// ============================================================================

final class SharedStats {
    private let lock = NSLock()
    private var raw = 0
    private var encoded = 0
    private var jpeg: Data?
    private var seq: Int64 = 0
    private var width: Int
    private var height: Int
    private var times: [Double] = []

    init(width: Int, height: Int) { self.width = width; self.height = height }

    func noteRawFrame() {
        lock.lock(); raw += 1; lock.unlock()
    }

    func publish(jpeg: Data, width: Int, height: Int) {
        lock.lock()
        encoded += 1
        seq += 1
        self.jpeg = jpeg
        self.width = width
        self.height = height
        let now = Date().timeIntervalSince1970
        times.append(now)
        if times.count > 90 { times.removeFirst(times.count - 90) }
        lock.unlock()
    }

    /// Returns the latest frame only if it is newer than `seq` (per-client latest-frame slot, no backpressure).
    func frame(after seq: Int64) -> (jpeg: Data, seq: Int64)? {
        lock.lock(); defer { lock.unlock() }
        guard let jpeg, self.seq > seq else { return nil }
        return (jpeg, self.seq)
    }

    struct Snapshot { let raw: Int; let encoded: Int; let fps: Double; let width: Int; let height: Int }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var fps = 0.0
        if times.count >= 2, let first = times.first, let last = times.last, last > first {
            fps = Double(times.count - 1) / (last - first)
        }
        return Snapshot(raw: raw, encoded: encoded, fps: fps, width: width, height: height)
    }
}

// ============================================================================
// MARK: - Input injection (CGEvent -> .cghidEventTap)
// ============================================================================

final class Injector {
    let displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastPoint: CGPoint?
    private var isDown = false
    private(set) var injectedEvents = 0

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    private func clamped(_ u: Double, _ v: Double) -> CGPoint {
        let b = CGDisplayBounds(displayID)   // always read runtime bounds (research pitfall F)
        let cu = min(max(u, 0), 1), cv = min(max(v, 0), 1)
        return CGPoint(x: b.origin.x + cu * b.width, y: b.origin.y + cv * b.height)
    }

    private func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    func ingest(body: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: body),
              let json = obj as? [String: Any] else { return false }
        return handle(json)
    }

    func handle(_ json: [String: Any]) -> Bool {
        let type = (json["type"] as? String ?? "touch").lowercased()
        switch type {
        case "touch", "pointer", "mouse":
            let action = (json["action"] as? String ?? "move").lowercased()
            guard let u = number(json["x"]), let v = number(json["y"]) else { return false }
            let p = clamped(u, v)
            switch action {
            case "down", "start":
                postMouse(.mouseMoved, p)
                postMouse(.leftMouseDown, p)
                isDown = true
            case "move":
                if isDown { postMouse(.leftMouseDragged, p) } else { postMouse(.mouseMoved, p) }
            case "up", "end":
                postMouse(.leftMouseUp, p)
                isDown = false
            default:
                return false
            }
            lastPoint = p
            vlog("input \(action) -> (\(Int(p.x)),\(Int(p.y)))")
        case "scroll":
            let dy = number(json["dy"]) ?? 0
            let dx = number(json["dx"]) ?? 0
            let p = lastPoint ?? clamped(0.5, 0.5)
            let w1 = Int32(min(max(dy.rounded(), -400), 400))
            let w2 = Int32(min(max(dx.rounded(), -400), 400))
            if let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                               wheelCount: 2, wheel1: w1, wheel2: w2, wheel3: 0) {
                e.location = p
                e.post(tap: .cghidEventTap)
            }
            vlog("input scroll dy=\(w1) dx=\(w2) at (\(Int(p.x)),\(Int(p.y)))")
        default:
            return false
        }
        injectedEvents += 1
        return true
    }

    private func postMouse(_ type: CGEventType, _ p: CGPoint) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: p, mouseButton: .left) else { return }
        if type == .leftMouseDown || type == .leftMouseUp {
            e.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        e.post(tap: .cghidEventTap)
    }
}

// ============================================================================
// MARK: - ScreenCaptureKit capture + JPEG encode
// ============================================================================

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let fps: Int
    private let physicalWidth: Int
    private let physicalHeight: Int
    private let outWidth: Int
    private let outHeight: Int
    private let quality: Double
    private let stats: SharedStats
    private let saveDir: String?
    private let ciContext = CIContext()
    private let captureQueue = DispatchQueue(label: "webhost.capture", qos: .userInteractive)
    private let encodeQueue = DispatchQueue(label: "webhost.encode", qos: .userInteractive)
    private let busyLock = NSLock()
    private var busy = false
    private var stream: SCStream?
    private var encodedCount = 0
    private var savedCount = 0
    private(set) var savedPaths: [String] = []

    init(displayID: CGDirectDisplayID, fps: Int, physicalWidth: Int, physicalHeight: Int,
         outWidth: Int, outHeight: Int, quality: Double, stats: SharedStats, saveDir: String?) {
        self.displayID = displayID
        self.fps = fps
        self.physicalWidth = physicalWidth
        self.physicalHeight = physicalHeight
        self.outWidth = outWidth
        self.outHeight = outHeight
        self.quality = quality
        self.stats = stats
        self.saveDir = saveDir
    }

    func start() async throws {
        var scDisplay: SCDisplay?
        var lastError: Error?
        for attempt in 1...20 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if let d = content.displays.first(where: { $0.displayID == displayID }) {
                    scDisplay = d
                    break
                }
                vlog("waiting for virtual display in SCShareableContent (attempt \(attempt), seen: \(content.displays.map { $0.displayID }))")
            } catch {
                lastError = error
                vlog("SCShareableContent error: \(error.localizedDescription)")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scDisplay else {
            throw NSError(domain: "webhost", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "virtual display \(displayID) not visible to ScreenCaptureKit" +
                    (lastError.map { " (\($0))" } ?? "")
            ])
        }
        vlog("SCShareableContent: virtual display \(scDisplay.displayID) \(scDisplay.width)x\(scDisplay.height)")

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = physicalWidth
        cfg.height = physicalHeight
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 5
        cfg.capturesAudio = false
        cfg.scalesToFit = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        stream = s
        try await s.startCapture()
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        do { try await s.stopCapture() } catch { vlog("stopCapture: \(error)") }
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        stats.noteRawFrame()
        busyLock.lock()
        if busy { busyLock.unlock(); return }
        busy = true
        busyLock.unlock()
        encodeQueue.async { [weak self] in
            guard let self else { return }
            self.encode(pixelBuffer)
            self.busyLock.lock(); self.busy = false; self.busyLock.unlock()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("SCStream stopped with error: \(error.localizedDescription)")
    }

    // MARK: encode pipeline (runs on encodeQueue)
    private func encode(_ pixelBuffer: CVPixelBuffer) {
        let began = Date()
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ci.extent
        guard extent.width >= 1, extent.height >= 1 else { return }
        let scale = min(1.0, Double(outWidth) / Double(extent.width))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let outRect = CGRect(x: 0, y: 0,
                             width: (extent.width * scale).rounded(),
                             height: (extent.height * scale).rounded())
        guard let cg = ciContext.createCGImage(scaled, from: outRect) else { return }
        guard let jpeg = Self.jpegData(cg, quality: quality) else { return }
        stats.publish(jpeg: jpeg, width: cg.width, height: cg.height)
        encodedCount += 1
        if let dir = saveDir { maybeSave(cg, dir: dir) }
        let ms = Date().timeIntervalSince(began) * 1000.0
        if encodedCount <= 5 || encodedCount % 60 == 0 {
            vlog(String(format: "frame #%d %dx%d jpeg=%dB encode=%.1fms", encodedCount, cg.width, cg.height, jpeg.count, ms))
        }
    }

    private func maybeSave(_ cg: CGImage, dir: String) {
        guard savedCount < 3 else { return }
        let wanted = [1, 31, 61]
        guard wanted.contains(encodedCount) else { return }
        savedCount += 1
        let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "frame-%03d.png", savedCount))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            log("warning: cannot create PNG destination \(url.path)")
            return
        }
        CGImageDestinationAddImage(dest, cg, nil)
        if CGImageDestinationFinalize(dest) {
            savedPaths.append(url.path)
            log("saved \(url.path) (\(cg.width)x\(cg.height))")
        } else {
            log("warning: PNG write failed for \(url.path)")
        }
    }

    static func jpegData(_ cg: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// ============================================================================
// MARK: - On-screen beacon (gives the virtual display content to encode)
// ============================================================================

final class BeaconView: NSView {
    var uptime: Double = 0
    var line1 = "Harmony Extend"
    var line2 = ""
    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.035, green: 0.043, blue: 0.06, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedRed: 0.26, green: 0.55, blue: 0.98, alpha: 1).setFill()
        let phase = CGFloat((uptime / 1.8).truncatingRemainder(dividingBy: 1.0))
        NSRect(x: 0, y: 0, width: max(2, bounds.width * phase), height: 4).fill()
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
        ]
        (line1 as NSString).draw(at: NSPoint(x: 24, y: 36), withAttributes: titleAttrs)
        (line2 as NSString).draw(at: NSPoint(x: 24, y: 82), withAttributes: subAttrs)
        (String(format: "uptime %.1fs · MJPEG demo host", uptime) as NSString)
            .draw(at: NSPoint(x: 24, y: 112), withAttributes: subAttrs)
        NSColor(calibratedRed: 0.26, green: 0.55, blue: 0.98, alpha: 1).setFill()
        let dotX = 24.0 + (bounds.width - 48.0) * CGFloat((uptime * 0.5).truncatingRemainder(dividingBy: 1.0))
        NSRect(x: dotX, y: 146, width: 10, height: 10).fill()
        _ = dirtyRect
    }
}

final class BeaconWindow {
    private var window: NSWindow?
    private var timer: Timer?
    private let view = BeaconView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
    private var shown = false

    func show(on screen: NSScreen, line1: String, line2: String) {
        guard !shown else { return }
        shown = true
        view.line1 = line1
        view.line2 = line2
        let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.level = .normal
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.maxY - view.frame.height - 40))
        w.orderFrontRegardless()
        window = w
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.view.uptime += 1.0 / 30.0
            self.view.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }
}

// ============================================================================
// MARK: - HTTP (Network.framework)
// ============================================================================

final class HTTPConnection {
    private let conn: NWConnection
    private unowned let server: HTTPServer
    private var buffer = Data()
    private var handled = false
    private var streaming = false
    private var closed = false
    private var pendingSend = false
    private var lastSeq: Int64 = -1
    private var timer: DispatchSourceTimer?

    init(conn: NWConnection, server: HTTPServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        conn.start(queue: server.queue)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, !self.streaming {
                self.buffer.append(data)
                self.process()
            }
            if error != nil { self.close(); return }
            if isComplete { self.close(); return }
            if !self.closed { self.receive() }
        }
    }

    private func process() {
        guard !handled else { return }
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: sep) else { return }
        let headerText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { close(); return }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { close(); return }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "content-length" {
                contentLength = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = range.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return }
        var body = Data()
        if contentLength > 0 {
            let end = buffer.index(bodyStart, offsetBy: contentLength)
            body = Data(buffer[bodyStart..<end])
        }
        handled = true
        server.handle(self, method: method, path: path, body: body)
    }

    func respond(status: String, contentType: String, body: Data) {
        guard !closed else { return }
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func beginStream() {
        guard !closed, !streaming else { return }
        streaming = true
        server.registerStreamClient(self)
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
            + "Cache-Control: no-cache, no-store, must-revalidate\r\n"
            + "Pragma: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let t = DispatchSource.makeTimerSource(queue: server.queue)
        t.schedule(deadline: .now() + server.frameInterval, repeating: server.frameInterval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pump() }
        timer = t
        t.resume()
        pump()
    }

    private func pump() {
        guard !closed, !pendingSend else { return }
        guard let f = server.nextFrame(after: lastSeq) else { return }
        lastSeq = f.seq
        pendingSend = true
        var chunk = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(f.jpeg.count)\r\n\r\n".utf8)
        chunk.append(f.jpeg)
        chunk.append(Data("\r\n".utf8))
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingSend = false
            if error != nil { self.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        conn.stateUpdateHandler = nil
        conn.cancel()
        server.connectionClosed(self)
    }
}

final class HTTPServer {
    let queue = DispatchQueue(label: "webhost.http")
    let stats: SharedStats
    let injector: Injector
    let displayID: CGDirectDisplayID
    let fps: Int
    let hiDPI: Bool
    let port: UInt16
    let frameInterval: TimeInterval
    let htmlData: Data

    private let listener: NWListener
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var clients: [ObjectIdentifier: HTTPConnection] = [:]
    private var isReady = false
    private let readySem = DispatchSemaphore(value: 0)
    private(set) var clientsServed = 0

    init(port: UInt16, stats: SharedStats, injector: Injector, fps: Int,
         displayID: CGDirectDisplayID, hiDPI: Bool) throws {
        self.stats = stats
        self.injector = injector
        self.fps = fps
        self.displayID = displayID
        self.hiDPI = hiDPI
        self.port = port
        self.frameInterval = 1.0 / Double(max(1, fps))
        self.htmlData = Data(htmlPage.utf8)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "webhost", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid HTTP port \(port)"])
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params, on: nwPort)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                log("HTTP listener ready on 0.0.0.0:\(self.port)")
                self.readySem.signal()
            case .failed(let err):
                log("HTTP listener failed: \(err)")
                self.readySem.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            self.accept(conn)
        }
        listener.start(queue: queue)
    }

    func waitReady(timeout: TimeInterval) -> Bool {
        if readySem.wait(timeout: .now() + timeout) == .timedOut { return false }
        return isReady
    }

    private func accept(_ conn: NWConnection) {
        let c = HTTPConnection(conn: conn, server: self)
        connections[ObjectIdentifier(c)] = c
        clientsServed += 1
        c.start()
    }

    func connectionClosed(_ c: HTTPConnection) {
        connections.removeValue(forKey: ObjectIdentifier(c))
        let wasStreaming = clients.removeValue(forKey: ObjectIdentifier(c)) != nil
        if wasStreaming {
            log("MJPEG client disconnected (active streams: \(clients.count))")
        } else {
            vlog("http connection closed (active streams: \(clients.count))")
        }
    }

    func registerStreamClient(_ c: HTTPConnection) {
        clients[ObjectIdentifier(c)] = c
        log("MJPEG client connected (active streams: \(clients.count))")
    }

    func nextFrame(after seq: Int64) -> (jpeg: Data, seq: Int64)? {
        return stats.frame(after: seq)
    }

    func handle(_ c: HTTPConnection, method: String, path: String, body: Data) {
        let cleanPath = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        switch (method, cleanPath) {
        case ("GET", "/"), ("GET", "/index.html"):
            c.respond(status: "200 OK", contentType: "text/html; charset=utf-8", body: htmlData)
        case ("GET", "/mjpg"), ("GET", "/stream.mjpg"):
            c.beginStream()
        case ("GET", "/status"):
            c.respond(status: "200 OK", contentType: "application/json", body: statusJSON())
        case ("GET", "/healthz"):
            c.respond(status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data("ok".utf8))
        case ("POST", "/input"):
            let ok = injector.ingest(body: body)
            c.respond(status: ok ? "200 OK" : "400 Bad Request",
                      contentType: "application/json",
                      body: Data("{\"ok\":\(ok)}".utf8))
        default:
            c.respond(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("not found\n".utf8))
        }
    }

    func statusJSON() -> Data {
        let snap = stats.snapshot()
        let b = CGDisplayBounds(displayID)
        let obj: [String: Any] = [
            "frames": snap.raw,
            "encoded": snap.encoded,
            "fps": (snap.fps * 10).rounded() / 10,
            "clients": clients.count,
            "displayID": Int(displayID),
            "bounds": ["x": Double(b.origin.x), "y": Double(b.origin.y),
                       "width": Double(b.width), "height": Double(b.height)],
            "width": snap.width,
            "height": snap.height,
            "hiDPI": hiDPI,
            "fpsTarget": fps,
            "uptime": Int(Date().timeIntervalSince(startTime)),
            "injected": injector.injectedEvents,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
    }

    func stop() {
        queue.sync {
            self.listener.stateUpdateHandler = nil
            self.listener.cancel()
            let all = Array(self.connections.values)
            for c in all { c.close() }
            self.connections.removeAll()
            self.clients.removeAll()
        }
    }
}

// ============================================================================
// MARK: - Viewer page (self-contained, no external resources)
// ============================================================================

let htmlPage = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<title>Harmony Extend · MJPEG demo</title>
<style>
  html, body { margin:0; padding:0; width:100%; height:100%; overflow:hidden; background:#08090c; }
  body { touch-action:none; -webkit-user-select:none; user-select:none; overscroll-behavior:none; }
  #screen { position:fixed; inset:0; width:100vw; height:100vh; object-fit:contain; display:block;
            background:#000; -webkit-user-drag:none; }
  #hud { position:fixed; left:12px; bottom:12px; max-width:72vw; padding:7px 10px; border-radius:8px;
         background:rgba(12,14,20,0.72); border:1px solid #232833; color:#9aa4b2;
         font:12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; pointer-events:none; white-space:pre; }
  #fs { position:fixed; right:12px; top:12px; padding:9px 16px; border-radius:9px; border:1px solid #36415a;
        background:rgba(28,35,50,0.88); color:#e6ecf5; font:14px -apple-system, system-ui, sans-serif; }
  #fs:active { background:#3a4a66; }
</style>
</head>
<body>
<img id="screen" src="/mjpg" alt="MJPEG stream">
<div id="hud">connecting…</div>
<button id="fs" type="button">全屏</button>
<script>
(function () {
  var img = document.getElementById('screen');
  var hud = document.getElementById('hud');
  var fsBtn = document.getElementById('fs');
  var frameW = 1600, frameH = 1056;
  var pointers = {};
  var lastMove = 0, lastScroll = 0;
  function send(obj) {
    fetch('/input', { method:'POST', headers:{'Content-Type':'application/json'},
                      body: JSON.stringify(obj), keepalive: true }).catch(function () {});
  }
  function contentRect() {
    var r = img.getBoundingClientRect();
    if (!frameW || !frameH) return { x: r.left, y: r.top, w: r.width, h: r.height };
    var s = Math.min(r.width / frameW, r.height / frameH);
    var w = frameW * s, h = frameH * s;
    return { x: r.left + (r.width - w) / 2, y: r.top + (r.height - h) / 2, w: w, h: h };
  }
  function norm(e) {
    var r = contentRect();
    var u = (e.clientX - r.x) / r.w, v = (e.clientY - r.y) / r.h;
    u = Math.max(0, Math.min(1, u)); v = Math.max(0, Math.min(1, v));
    return { x: Math.round(u * 10000) / 10000, y: Math.round(v * 10000) / 10000 };
  }
  function sendTouch(action, e) {
    var p = norm(e);
    send({ type:'touch', action:action, x:p.x, y:p.y });
  }
  function countPointers() { var n = 0; for (var k in pointers) { n += 1; } return n; }
  img.addEventListener('pointerdown', function (e) {
    e.preventDefault();
    if (img.setPointerCapture) { try { img.setPointerCapture(e.pointerId); } catch (err) {} }
    pointers[e.pointerId] = { x:e.clientX, y:e.clientY };
    if (countPointers() === 1) { sendTouch('down', e); }
  });
  img.addEventListener('pointermove', function (e) {
    if (!pointers[e.pointerId]) return;
    var prev = pointers[e.pointerId];
    pointers[e.pointerId] = { x:e.clientX, y:e.clientY };
    var now = performance.now();
    if (countPointers() >= 2) {
      var dy = e.clientY - prev.y;
      if (now - lastScroll >= 16 && Math.abs(dy) >= 1) {
        send({ type:'scroll', dy: dy * 3 });
        lastScroll = now;
      }
      return;
    }
    if (now - lastMove >= 16) { sendTouch('move', e); lastMove = now; }
  });
  function endPointer(e, sendUp) {
    if (!pointers[e.pointerId]) return;
    delete pointers[e.pointerId];
    if (sendUp && countPointers() === 0) { sendTouch('up', e); }
  }
  img.addEventListener('pointerup', function (e) { endPointer(e, true); });
  img.addEventListener('pointercancel', function (e) { endPointer(e, true); });
  window.addEventListener('wheel', function (e) {
    e.preventDefault();
    var now = performance.now();
    if (now - lastScroll < 16) return;
    lastScroll = now;
    send({ type:'scroll', dy: e.deltaY, dx: e.deltaX });
  }, { passive:false });
  fsBtn.addEventListener('click', function (e) {
    e.stopPropagation();
    var el = document.documentElement;
    var req = el.requestFullscreen || el.webkitRequestFullscreen || el.msRequestFullscreen;
    if (req) { try { req.call(el); } catch (err) {} }
  });
  img.addEventListener('error', function () {
    setTimeout(function () { img.src = '/mjpg?t=' + Date.now(); }, 600);
  });
  function poll() {
    fetch('/status', { cache:'no-store' }).then(function (r) { return r.json(); }).then(function (j) {
      frameW = j.width || frameW; frameH = j.height || frameH;
      hud.textContent = 'frames ' + j.frames + '  fps ' + Number(j.fps).toFixed(1) +
        '  clients ' + j.clients + '\n' + j.displayID + '  ' + j.width + '×' + j.height +
        '  ' + j.uptime + 's';
    }).catch(function () { hud.textContent = 'disconnected — retrying'; });
  }
  setInterval(poll, 1000);
  poll();
})();
</script>
</body>
</html>
"""#

// ============================================================================
// MARK: - Global runtime state + shutdown
// ============================================================================

var vdOpt: VirtualDisplay?
var serverRef: HTTPServer?
var captureRef: Capture?
var injectorRef: Injector?
var beaconRef: BeaconWindow?
var statsRef: SharedStats?
var signalSources: [DispatchSourceSignal] = []
var shuttingDown = false
var finishedShutdown = false
var secondsTimer: Double = 0

func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { shutdown(reason: "signal \(sig)") }
        src.resume()
        signalSources.append(src)
    }
}

func shutdown(reason: String) {
    guard !shuttingDown else { return }
    shuttingDown = true
    log("shutting down (\(reason))…")
    // Safety: if async SCK teardown hangs, force-exit so the virtual display is always released.
    DispatchQueue.global().asyncAfter(deadline: .now() + 6.0) {
        log("shutdown watchdog fired; forcing exit")
        exit(1)
    }
    serverRef?.stop()
    beaconRef?.close()
    if let capture = captureRef {
        Task {
            await capture.stop()
            DispatchQueue.main.async { finishShutdown() }
        }
    } else {
        DispatchQueue.main.async { finishShutdown() }
    }
}

func finishShutdown() {
    guard !finishedShutdown else { return }
    finishedShutdown = true
    let vdID = vdOpt?.displayID
    beaconRef?.close()
    beaconRef = nil
    vdOpt?.destroy()          // main thread, as required (research pitfall D)
    vdOpt = nil
    // WindowServer may keep a ScreenCaptureKit-captured display listed until the process exits;
    // poll briefly for the normal case, then report honestly (external check after exit is authoritative).
    var online = onlineDisplayIDs()
    let deadline = Date().addingTimeInterval(0.6)
    while let vdID, online.contains(vdID), Date() < deadline {
        usleep(100_000)
        online = onlineDisplayIDs()
    }
    if let vdID {
        if online.contains(vdID) {
            log("virtual display \(vdID) released on main thread; WindowServer still lists it in-process, it is unregistered when this process exits")
        } else {
            log("virtual display \(vdID) removed from WindowServer; online displays now: \(online)")
        }
    }
    if let saved = captureRef?.savedPaths, !saved.isEmpty {
        print("SAVED \(saved.count) PNGs: \(saved.joined(separator: ", "))")
    }
    if let snap = statsRef?.snapshot() {
        print(String(format: "SUMMARY capturedFrames=%d encodedJPEGs=%d fps=%.1f frameSize=%dx%d clientsServed=%d injectedEvents=%d",
                     snap.raw, snap.encoded, snap.fps, snap.width, snap.height,
                     serverRef?.clientsServed ?? 0, injectorRef?.injectedEvents ?? 0))
    }
    fflush(stdout)
    exit(0)
}

// ============================================================================
// MARK: - main
// ============================================================================

let opts = parseOptions()
verbose = opts.verbose

_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.accessory)

log("webhost starting: logical \(opts.width)x\(opts.height) @\(opts.scale)x (physical \(opts.width * opts.scale)x\(opts.height * opts.scale)), \(opts.fps) fps, HTTP :\(opts.httpPort), seconds=\(opts.seconds == 0 ? "∞" : String(Int(opts.seconds)))")
if !CGPreflightScreenCaptureAccess() {
    log("warning: CGPreflightScreenCaptureAccess() == false — ScreenCaptureKit may fail")
}
if !AXIsProcessTrusted() {
    log("warning: AXIsProcessTrusted() == false — CGEvent injection will silently do nothing")
}

if let dir = opts.saveFramesDir {
    do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    catch { log("warning: cannot create --save-frames dir \(dir): \(error.localizedDescription)") }
}

let mainBoundsBefore = CGDisplayBounds(CGMainDisplayID())
let mainIDBefore = CGMainDisplayID()
log("main display: id=\(mainIDBefore) bounds=\(fmt(mainBoundsBefore))")
log("online displays before: \(onlineDisplayIDs())")

let physicalW = opts.width * opts.scale
let physicalH = opts.height * opts.scale
let outW = min(1600, physicalW)
let outH = max(1, Int((Double(physicalH) * Double(outW) / Double(physicalW)).rounded()))

let stats = SharedStats(width: outW, height: outH)
statsRef = stats

// 1) virtual display
do {
    vdOpt = try VirtualDisplay(logicalWidth: opts.width, logicalHeight: opts.height, scale: opts.scale, refresh: 60)
} catch {
    log("FATAL: virtual display creation failed: \(error.localizedDescription)")
    exit(1)
}
guard let vdID = vdOpt?.displayID else { exit(1) }
log("virtual display: id=\(vdID) logical=\(vdOpt!.logicalWidth)x\(vdOpt!.logicalHeight) physical=\(vdOpt!.physicalWidth)x\(vdOpt!.physicalHeight)")

guard waitOnline(vdID, timeout: 5) else {
    log("FATAL: virtual display \(vdID) never appeared in CGGetOnlineDisplayList")
    vdOpt?.destroy()
    exit(1)
}
log("virtual display online; initial bounds=\(fmt(CGDisplayBounds(vdID)))")

_ = placeExtendedRight(vdID)
ensurePhysicalStaysMain(vdID)
usleep(300_000)
let vdBounds = CGDisplayBounds(vdID)
let mainBoundsAfter = CGDisplayBounds(CGMainDisplayID())
let mirrored = CGDisplayIsInMirrorSet(vdID) != 0
log("arrangement: main=\(fmt(mainBoundsAfter)) virtual=\(fmt(vdBounds)) mirrored=\(mirrored)")
log("virtual mode: \(displayModeInfo(vdID))")
if mainBoundsAfter != mainBoundsBefore || CGMainDisplayID() != mainIDBefore {
    log("warning: main display changed! before=\(fmt(mainBoundsBefore)) after=\(fmt(mainBoundsAfter))")
}
if vdBounds.origin.x != mainBoundsAfter.maxX || vdBounds.width <= 0 {
    log("warning: virtual display is not exactly at main.maxX (requested right-of-main); actual origin.x=\(vdBounds.origin.x) main.maxX=\(mainBoundsAfter.maxX)")
}

// 2) beacon window on the virtual display -> guarantees changing content for SCK + non-black frames
var vdScreen: NSScreen?
for _ in 0..<30 {
    if let s = screen(for: vdID) { vdScreen = s; break }
    usleep(100_000)
}
beaconRef = BeaconWindow()
if let s = vdScreen {
    beaconRef?.show(on: s, line1: "Harmony Extend",
                    line2: "\(physicalW)×\(physicalH) fb · \(opts.width)×\(opts.height) pt @\(opts.scale)x")
    log("beacon window shown on virtual display (animated content source)")
} else {
    log("warning: NSScreen for virtual display not found; beacon window disabled")
}

// 3) input injector + HTTP server
let injector = Injector(displayID: vdID)
injectorRef = injector
do {
    serverRef = try HTTPServer(port: opts.httpPort, stats: stats, injector: injector,
                               fps: opts.fps, displayID: vdID, hiDPI: opts.scale == 2)
} catch {
    log("FATAL: HTTP server could not be created: \(error.localizedDescription)")
    beaconRef?.close()
    vdOpt?.destroy()
    exit(1)
}
serverRef?.start()
guard serverRef?.waitReady(timeout: 5) == true else {
    log("FATAL: HTTP listener did not become ready on port \(opts.httpPort)")
    beaconRef?.close()
    vdOpt?.destroy()
    exit(1)
}
let ip = lanIP() ?? "127.0.0.1"

// 4) capture pipeline (async, driven by pull from server holding the latest-frame slot)
let capture = Capture(displayID: vdID, fps: opts.fps,
                      physicalWidth: physicalW, physicalHeight: physicalH,
                      outWidth: outW, outHeight: outH, quality: 0.55,
                      stats: stats, saveDir: opts.saveFramesDir)
captureRef = capture

Task {
    do {
        try await capture.start()
        log("capture running: display=\(vdID) \(opts.fps)fps pixelFormat=420v -> \(outW)x\(outH) JPEG(0.55)")
        print("READY http://\(ip):\(opts.httpPort)/")
        print("      (local http://127.0.0.1:\(opts.httpPort)/, display \(vdID), \(outW)x\(outH) @ \(opts.fps)fps)")
        fflush(stdout)
        if opts.seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + opts.seconds) {
                shutdown(reason: "--seconds \(Int(opts.seconds))")
            }
        }
    } catch {
        log("capture failed to start: \(error.localizedDescription)")
        DispatchQueue.main.async { shutdown(reason: "capture start failed") }
    }
}

installSignalHandlers()
NSApplication.shared.run()

// NSApplication.run() returns only if the app is stopped/terminated externally.
log("NSApplication.run() returned")
finishShutdown()