//
//  HostApp.swift
//  HaloLink macOS host
//
//  Streaming engine shared by the command line host and the macOS app GUI.
//
//  One session =
//    virtual display -> ScreenCaptureKit -> { H.264 encoder -> HLDP TCP transport,
//                                            MJPEG hub -> HTTP server,
//                                            PNG frame saver,
//                                            H.264 dump file }
//    HLDP/HTTP control frames -> CGEvent input injection (v1.1: OFF by default)
//
//  The engine owns lifecycle (start/stop session), adaptive display sizing
//  (tablet panel / match-main / portrait rotation), TCC checks, READY line,
//  watchdog timers and clean teardown. The GUI (AppDelegate/MainWindow) only
//  drives it through the public facade below.
//

import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Shared, lock-protected display bounds used by the input injector so that it
/// always maps coordinates against the *current* arrangement.
final class BoundsBox {
    private let lock = NSLock()
    private var value: CGRect = .zero

    func set(_ rect: CGRect) {
        lock.lock()
        value = rect
        lock.unlock()
    }

    func get() -> CGRect {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Engine phase (shown in the GUI status line and used for lifecycle guards).
enum HostPhase: Equatable {
    case idle
    case starting
    case running
    case stopping
    case failed(String)

    var isRunning: Bool { self == .running }

    var text: String {
        switch self {
        case .idle: return "已停止"
        case .starting: return "正在启动…"
        case .running: return "运行中"
        case .stopping: return "正在停止…"
        case .failed(let message): return "错误: \(message)"
        }
    }
}

/// Snapshot for the GUI (read at ~4 Hz).
struct HostStatus {
    var phase: HostPhase = .idle
    var sessionActive = false
    var transportReady = false
    var transportTarget = ""
    var displayID: UInt32 = 0
    var captureWidth = 0
    var captureHeight = 0
    var logicalWidth = 0
    var logicalHeight = 0
    var retina = false
    var streamFPS = 0
    var orientation = "landscape"
    var tabletPanelWidth = 0
    var tabletPanelHeight = 0
    var renderMode: RenderMode = .hidpiScale
    var achievedRetina = false
    var scaleMode: ScaleModeOption = .fit
    var inputEnabled = false
    var tabletInputReported: Bool?
    var captureFps = 0.0
    var encodeFps = 0.0
    var kbps = 0.0
    var rttMs = 0.0
    var mjpegClients = 0
    var frames = 0
    var uptime = 0.0
    var message: String?
}

final class HostApp: NSObject {
    // MARK: - GUI callbacks
    var onPhaseChanged: ((HostPhase) -> Void)?
    var onTransportReady: (() -> Void)?
    var onTransportLost: (() -> Void)?
    /// GUI hook: called when switching the backing scale needs a fresh process
    /// (CGVirtualDisplay's 2x mode handle is only obtainable while 2x is active, and
    /// the display object cannot be re-created in-process).
    var onRenderModeRequiresRelaunch: ((RenderMode) -> Void)?

    // MARK: - Configuration / state
    private(set) var options: Options
    private let guiMode: Bool

    private let virtualDisplay = VirtualDisplay()
    private let capture = CaptureEngine()
    private let mjpegHub: MJPEGHub
    private let inputInjector: InputInjector
    private let stats = HostStats()
    private let latency = LatencyTracker()
    private let boundsBox = BoundsBox()

    private var encoder: H264Encoder?
    private var frameSaver: FrameSaver?
    private var transport: LinkTransport?
    private var webServer: WebServer?
    private var demoWindow: DemoWindowController?
    private var synthetic: SyntheticSource?

    private var phase: HostPhase = .idle
    private var lastFailureMessage: String?
    private var sessionActive = false
    private var shuttingDown = false

    private var sourceDisplayID: CGDirectDisplayID = 0
    private var capturePixelWidth = 0
    private var capturePixelHeight = 0
    private var logicalWidth = 0
    private var logicalHeight = 0
    private var isMirrorMode = false
    private var modeDescription = "virtual"
    private var streamFPS: Int
    private var wantsVideoStream = false
    private var lastReconfigureTime: TimeInterval = 0

    // Tablet screen info (HLDP v1.1)
    private var tabletNativeLandscape: (width: Int, height: Int) = (2800, 1840)
    private var tabletOrientation = "landscape"
    private var tabletInputReported: Bool?
    private var tabletSupportsFrameTs = false
    private var displayDebounce: DispatchWorkItem?
    private var pendingDisplayMessage: [String: Any]?
    private var lastDisplayRebuildTime: TimeInterval = 0

    private var lastFrame: CVPixelBuffer?
    private var lastFramePTS: CMTime = .zero
    private var frameIndex = 0

    private var statsTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var autoExitItem: DispatchWorkItem?
    private var singleInstanceLock: SingleInstanceLock?
    private var activityToken: NSObjectProtocol?
    private var lastFrameTime: TimeInterval = 0
    private var lastGapWarningTime: TimeInterval = 0
    private var lastCaptureRestartTime: TimeInterval = 0
    private var lastKeepaliveTime: TimeInterval = 0
    private var resumeLogged = false
    private var signalSources: [DispatchSourceSignal] = []
    private var startedAt = Clock.now()
    private var readyEmitted = false
    private var screenObserverInstalled = false
    private var wakeObserver: NSObjectProtocol?

    private var dumpQueue = DispatchQueue(label: "com.halolink.h264dump")
    private var dumpFileHandle: FileHandle?
    private var dumpURL: URL?
    private var dumpBytes = 0
    private var dumpEnabled = false

    // MARK: - Init

    init(options: Options, guiMode: Bool = false) {
        self.options = options
        self.guiMode = guiMode
        self.streamFPS = options.fps
        self.mjpegHub = MJPEGHub(defaultWidth: options.webWidth,
                                 defaultQuality: options.webQuality)
        let box = boundsBox
        self.inputInjector = InputInjector(boundsProvider: { box.get() })
        super.init()
        Log.verbose = options.verbose
        mjpegHub.onJPEGEncoded = { [weak self] in
            self?.stats.recordJPEGFrame()
        }
        inputInjector.setEnabled(options.inputEnabled)
    }

    // MARK: - Global resources (log file, App Nap, single-instance lock)

    /// Acquires process-wide resources exactly once. Returns false when another
    /// HaloLink instance is already running.
    func acquireGlobalResources() -> Bool {
        if let path = Log.enableFileLogging() {
            Log.logFilePath = path
        }
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
                reason: "HaloLink is streaming an extended display to a tablet")
            Log.info("App Nap disabled for the duration of the run")
        }
        if singleInstanceLock == nil {
            if let lock = SingleInstanceLock() {
                singleInstanceLock = lock
                Log.info("single-instance lock acquired: \(lock.pathDescription)")
            } else {
                Log.error(SingleInstanceLock.lastFailureReason ??
                          "another HaloLink host is already running")
                phase = .failed("另一个 HaloLink 已在运行")
                return false
            }
        }
        return true
    }

    private func releaseGlobalResources() {
        singleInstanceLock?.release()
        singleInstanceLock = nil
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    // MARK: - CLI entry point

    func runCLI() -> Never {
        _ = acquireGlobalResources()
        guard !caseFailed() else {
            exit(4)
        }
        Log.info("HaloLink macOS host 1.3.1 (HLDP v1.3) on \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let path = Log.logFilePath { Log.info("log file: \(path)") }
        logConfiguration()

        // Start the AppKit run loop first and kick off the session on its first
        // iteration: WindowServer completes virtual-display registration (and the
        // mode becomes readable) only while the app's event loop is running.
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.installSignalHandlers()
            guard self.startSession() else {
                Log.error("startup failed: \(self.lastFailureMessage ?? "unknown error")")
                exit(2)
            }
        }
        application.run()
        quit(exitCode: 0, reason: "run loop ended")
    }

    private func caseFailed() -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private func logConfiguration() {
        var parts: [String] = []
        parts.append("size=\(options.width)x\(options.height)")
        parts.append("fps=\(options.fps)")
        parts.append("bitrate=\(options.bitrate / 1_000_000)Mbps")
        parts.append("displayMode=\(options.displayMode.rawValue)")
        parts.append("hidpi=\(options.hidpi.rawValue)")
        parts.append("renderMode=\(options.renderMode.rawValue)")
        parts.append("scaleMode=\(options.scaleMode.rawValue)")
        parts.append("input=\(options.inputEnabled ? "on" : "off")")
        if let connect = options.connect { parts.append("connect=\(connect.description)") }
        if let listen = options.listen { parts.append("listen=\(listen.description)") }
        if !options.hasTransportTarget { parts.append("transport=web-only") }
        parts.append("http=\(options.webEnabled ? String(options.httpPort) : "off")")
        if let dump = options.dumpH264 { parts.append("dumpH264=\(dump)") }
        if let save = options.saveFrames { parts.append("saveFrames=\(save)") }
        if let seconds = options.seconds { parts.append(String(format: "seconds=%.1f", seconds)) }
        Log.info("options: " + parts.joined(separator: " "))
        if let address = NetworkInfo.preferredLANAddress() {
            Log.info("LAN address: \(address) — tablet URL: http://\(address):\(options.httpPort)/")
        }
        Log.info("interfaces: " + NetworkInfo.activeLANAddresses().joined(separator: " "))
    }

    // MARK: - Permissions

    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Checks Screen Recording and, when missing, requests access + opens Settings.
    static func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            Log.info("Screen Recording permission: granted")
            return true
        }
        Log.error("Screen Recording permission is NOT granted for “\(InputInjector.appName)”.")
        Log.error("Fix: System Settings → Privacy & Security → Screen & System Audio Recording " +
                  "→ enable “\(InputInjector.appName)”, then relaunch the app.")
        let granted = CGRequestScreenCaptureAccess()
        InputInjector.openScreenRecordingSettings()
        if granted {
            Log.info("Screen Recording permission was granted — macOS may require a relaunch")
            return true
        }
        return false
    }

    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Session lifecycle

    /// Starts a streaming session. The virtual display needs a few asynchronous
    /// main-queue hops to finish WindowServer registration before its mode becomes
    /// readable (verified: with NSApp active, immediate/sleep-based queries return
    /// NULL and the display would fall back to 1x), so startup is staged: this
    /// method returns `true` when the session is *starting*; the phase becomes
    /// `.running` once the display is finalised and capture is live.
    @discardableResult
    func startSession() -> Bool {
        switch phase {
        case .running, .starting:
            Log.info("start ignored: session already \(phase.text)")
            return true
        case .stopping:
            Log.info("start ignored: session is stopping")
            return false
        case .idle, .failed:
            break
        }

        Log.info("=== starting HaloLink session ===")
        setPhase(.starting)
        lastFailureMessage = nil
        shuttingDown = false
        sessionActive = true
        startedAt = Clock.now()
        readyEmitted = false
        stats.resetFrameTiming()
        latency.resetSession()
        mjpegHub.resume()
        inputInjector.setEnabled(options.inputEnabled)
        Log.verbose = options.verbose

        if options.synthetic {
            Log.info("synthetic frame source requested: skipping Screen Recording requirement")
        } else if !Self.ensureScreenRecordingPermission() {
            return failSession("缺少屏幕录制权限（Screen Recording）")
        }

        options.inputEnabled = inputInjector.isEnabled
        if options.inputEnabled {
            _ = inputInjector.checkAccessibility(prompt: true)
        } else {
            Log.info("input injection disabled (v1.1 default off)")
        }

        wantsVideoStream = options.hasTransportTarget || options.dumpH264 != nil
        guard createDisplay() else {
            return failSession(lastFailureMessage ?? "虚拟显示器创建失败")
        }
        if options.synthetic || options.displayMode == .mirror || !virtualDisplay.isActive {
            finishStartup()
            return true
        }
        // Wait for the virtual display's mode to become readable using real async
        // main-queue hops (sleeps/nested run loops stall WindowServer registration).
        pollDisplayReady(attempt: 0, deadline: Clock.now() + 4.0)
        return true
    }

    private func pollDisplayReady(attempt: Int, deadline: TimeInterval) {
        guard sessionActive, phase == .starting, !shuttingDown else { return }
        if virtualDisplay.refreshMode() != nil {
            // Give WindowServer a moment to settle on the final (HiDPI) mode: the
            // first readable mode can still be the 1x "scaled" default. This delay
            // makes the 2x mode deterministic (probe: ~1 s after registration).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.finishStartup()
            }
            return
        }
        if Clock.now() >= deadline {
            Log.warn("virtual display mode still unreadable after " +
                     String(format: "%.1fs", 4.0) + "; continuing with fallback size")
            finishStartup()
            return
        }
        if Log.verbose, attempt % 5 == 0 {
            Log.debug("waiting for virtual display registration (attempt \(attempt))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollDisplayReady(attempt: attempt + 1, deadline: deadline)
        }
    }

    /// Finalises the display (mode/placement) and starts encoder/capture/web/etc.
    private func finishStartup() {
        guard sessionActive, phase == .starting else { return }
        finalizeDisplay()
        boundsBox.set(currentInputBounds())
        wantsVideoStream = options.hasTransportTarget || options.dumpH264 != nil

        let plan = desiredStreamPlan()
        prepareRenderModeForStreaming(plan: plan) { [weak self] in
            self?.startStreamingServices()
        }
    }

    /// Ensures the display is in the mode required by the plan before capture
    /// starts. Mode switches are asynchronous (run loop must iterate) and 1x <-> 2x
    /// transitions use retained CGDisplayMode handles.
    private func prepareRenderModeForStreaming(plan: RenderPlan,
                                               completion: @escaping () -> Void) {
        guard virtualDisplay.isActive else {
            completion()
            return
        }
        if virtualDisplay.refreshMode()?.isHiDPI == true {
            // 2x is active: capture both retained mode handles now (the 2x mode is
            // not exposed in the public mode list, it must be captured while active).
            virtualDisplay.refreshModeHandles()
            finishRenderModePreparation(plan: plan, completion: completion)
            return
        }
        // The display came up 1x (macOS sometimes picks the scaled default first).
        // Re-declare the rich HiDPI recipe, wait for the 2x mode, then keep its
        // handle so we can switch between 1x/2x in-process later.
        Log.info("capturing 2x HiDPI mode ladder before applying render mode …")
        guard virtualDisplay.beginAdjust(width: UInt32(plan.pixelWidth),
                                         height: UInt32(plan.pixelHeight),
                                         refresh: streamFPS, hidpi: .auto) else {
            finishRenderModePreparation(plan: plan, completion: completion)
            return
        }
        pollForHiDPIMode(deadline: Clock.now() + 2.5) { [weak self] captured in
            guard let self = self else { return }
            if captured {
                self.virtualDisplay.refreshModeHandles()
            } else {
                Log.warn("macOS did not offer a 2x HiDPI mode for " +
                         "\(plan.pixelWidth)x\(plan.pixelHeight); in-app 1x/2x switching " +
                         "will be unavailable for this panel")
            }
            self.finishRenderModePreparation(plan: plan, completion: completion)
        }
    }

    /// Polls until the virtual display reports a 2x mode.
    private func pollForHiDPIMode(deadline: TimeInterval,
                                  completion: @escaping (Bool) -> Void) {
        if virtualDisplay.refreshMode()?.isHiDPI == true {
            completion(true)
            return
        }
        if Clock.now() >= deadline {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollForHiDPIMode(deadline: deadline, completion: completion)
        }
    }

    /// Final step before capture starts: make the display match the plan.
    private func finishRenderModePreparation(plan: RenderPlan,
                                             completion: @escaping () -> Void) {
        let currentHiDPI = virtualDisplay.mode?.isHiDPI ?? false
        if actualSatisfiesPlan(plan) {
            syncDimsFromMode()
            completion()
            return
        }
        if let mode = virtualDisplay.refreshMode(), mode.pixelWidth > 0,
           plan.retina != currentHiDPI,
           Int(mode.pixelWidth) == plan.pixelWidth,
           Int(mode.pixelHeight) == plan.pixelHeight ||
               Int(mode.pixelHeight) == plan.pixelHeight + 8 {
            Log.info("switching virtual display from \(currentHiDPI ? "2x" : "1x") to " +
                     "\(plan.retina ? "2x" : "1x") for render mode \(plan.mode.title)")
            if virtualDisplay.switchRenderMode(retina: plan.retina) {
                pollRenderMode(plan: plan, deadline: Clock.now() + 2.5,
                               didForceSelect: false) { [weak self] mode in
                    guard let self = self else { return }
                    if mode == nil {
                        Log.warn("mode switch did not settle; using " +
                                 self.renderModeDescription())
                    }
                    self.syncDimsFromMode()
                    completion()
                }
                return
            }
        }
        Log.info("display mode \(renderModeDescription()) does not match " +
                 "\(plan.mode.title) plan; correcting asynchronously …")
        reconfigureStream(plan: plan, fps: streamFPS) { [weak self] success in
            guard let self = self else { return }
            if !success {
                Log.warn("could not achieve \(plan.mode.title); using " +
                         self.renderModeDescription() + " (config reports actual)")
            }
            self.syncDimsFromMode()
            completion()
        }
    }

    /// Updates capturePixelWidth/Height + logical size from the active mode.
    private func syncDimsFromMode() {
        guard let mode = virtualDisplay.refreshMode(), mode.pixelWidth > 0 else { return }
        capturePixelWidth = Int(mode.pixelWidth)
        capturePixelHeight = Int(mode.pixelHeight)
        logicalWidth = Int(mode.pointWidth)
        logicalHeight = Int(mode.pointHeight)
    }

    /// Starts encoder/capture/web/transport once the display mode is final.
    private func startStreamingServices() {
        guard sessionActive, phase == .starting else { return }
        wantsVideoStream = options.hasTransportTarget || options.dumpH264 != nil
        if wantsVideoStream, encoder == nil {
            setupEncoder()
        } else if !wantsVideoStream {
            Log.info("H.264 encoder idle (web-only mode)")
        }
        if let directory = options.saveFrames {
            frameSaver = FrameSaver(directory: directory, fps: streamFPS)
        }
        setupDumpFileIfNeeded()

        guard setupWebServer() else {
            _ = failSession(lastFailureMessage ?? "HTTP 服务启动失败")
            return
        }
        setupTransport()

        if !capture.isRunning {
            guard setupCapture() else {
                _ = failSession(lastFailureMessage ?? "屏幕采集启动失败")
                return
            }
        }

        installSessionObservers()
        installStatsTimer()
        installWatchdogTimer()
        if options.demo {
            setupDemoWindow()
        }
        printReadyLine()
        setPhase(.running)
        Log.info("session running: display=\(virtualDisplay.displayID) " +
                 "capture=\(capturePixelWidth)x\(capturePixelHeight)@\(streamFPS) " +
                 "logical=\(logicalWidth)x\(logicalHeight) renderMode=" +
                 "\(options.renderMode.rawValue) achieved=\(renderModeDescription()) " +
                 "input=\(options.inputEnabled ? "on" : "off")")
        if !guiMode, let seconds = options.seconds {
            let item = DispatchWorkItem { [weak self] in
                Log.info("--seconds \(seconds) elapsed, shutting down")
                self?.quit(exitCode: 0, reason: "duration elapsed")
            }
            autoExitItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
            Log.info(String(format: "auto-exit enabled: %.1fs", seconds))
        }
        // Dev/test hook: toggle render modes at given millisecond offsets, e.g.
        // HALOLINK_TEST_TOGGLE_MS="4000,9000" (used by the v1.2 acceptance run).
        if !guiMode, let raw = ProcessInfo.processInfo.environment["HALOLINK_TEST_TOGGLE_MS"] {
            let times = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            for (index, ms) in times.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000.0) { [weak self] in
                    guard let self = self, self.phase == .running else { return }
                    let target: RenderMode = index % 2 == 0
                        ? (self.options.renderMode == .pixel1to1 ? .hidpiScale : .pixel1to1)
                        : (self.options.renderMode == .pixel1to1 ? .hidpiScale : .pixel1to1)
                    Log.info("[test] scheduled render-mode toggle -> \(target.rawValue)")
                    self.setRenderMode(target)
                }
            }
        }
    }

    @discardableResult
    private func failSession(_ message: String) -> Bool {
        lastFailureMessage = message
        Log.error("session startup failed: \(message)")
        cleanupSessionResources(logSummary: false)
        sessionActive = false
        setPhase(.failed(message))
        if !guiMode {
            Log.error("exiting (startup failed)")
            fflush(stdout)
            fflush(stderr)
            exit(2)
        }
        return false
    }

    /// Stops the current streaming session but keeps the process/app alive.
    func stopSession(reason: String) {
        guard sessionActive else {
            if phase != .idle { setPhase(.idle) }
            return
        }
        Log.info("stopping session (\(reason)) …")
        setPhase(.stopping)
        shuttingDown = true
        autoExitItem?.cancel()
        autoExitItem = nil
        cleanupSessionResources(logSummary: true)
        sessionActive = false
        shuttingDown = false
        setPhase(.idle)
        Log.info("session stopped (\(reason))")
    }

    /// Tears down everything a session created. Safe to call repeatedly.
    private func cleanupSessionResources(logSummary: Bool) {
        displayDebounce?.cancel()
        displayDebounce = nil
        pendingDisplayMessage = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        statsTimer?.cancel()
        statsTimer = nil
        demoWindow?.close()
        demoWindow = nil
        removeSessionObservers()
        synthetic?.stop()
        synthetic = nil
        capture.stop()
        transport?.stop()
        transport = nil
        webServer?.stop()
        webServer = nil
        mjpegHub.stop()
        encoder?.finish()
        encoder = nil
        frameSaver?.finish()
        frameSaver = nil
        finishDump()
        if logSummary {
            let snapshot = stats.updateRates()
            Log.info("summary: " + stats.summaryLine(snapshot: snapshot))
            Log.info("latency summary: " +
                     latency.summary(transportRTTMs: snapshot.rttMs).logLine)
        }
        if virtualDisplay.isActive {
            if let mode = virtualDisplay.mode {
                Log.info("virtual display mode was: \(mode.description)")
            }
            virtualDisplay.destroy()
        }
        sourceDisplayID = 0
        capturePixelWidth = 0
        capturePixelHeight = 0
        logicalWidth = 0
        logicalHeight = 0
        lastFrame = nil
        lastFramePTS = .zero
    }

    /// Fully exits (CLI signals, GUI quit, fatal startup failure).
    func quit(exitCode: Int32, reason: String) -> Never {
        Log.info("quitting (\(reason)) …")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 6.0) {
            Log.error("shutdown watchdog fired — forcing exit")
            fflush(stdout)
            fflush(stderr)
            _exit(exitCode)
        }
        stopSession(reason: reason)
        removeSessionObservers()
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
        releaseGlobalResources()
        Log.info("goodbye (reason=\(reason), exit=\(exitCode))")
        fflush(stdout)
        fflush(stderr)
        exit(exitCode)
    }

    private func setPhase(_ newPhase: HostPhase) {
        phase = newPhase
        onPhaseChanged?(newPhase)
    }

    func currentPhase() -> HostPhase { phase }

    // MARK: - GUI facade

    func statusSnapshot() -> HostStatus {
        var status = HostStatus()
        status.phase = phase
        status.sessionActive = sessionActive
        status.transportReady = transport?.isReady ?? false
        status.transportTarget = options.connect?.description ?? options.listen?.description ?? ""
        status.displayID = virtualDisplay.displayID
        status.captureWidth = capturePixelWidth
        status.captureHeight = capturePixelHeight
        status.logicalWidth = logicalWidth
        status.logicalHeight = logicalHeight
        status.retina = virtualDisplay.mode?.isHiDPI ?? false
        status.streamFPS = streamFPS
        status.orientation = tabletOrientation
        let panel = tabletCurrentPixelSize()
        status.tabletPanelWidth = panel.width
        status.tabletPanelHeight = panel.height
        status.renderMode = options.renderMode
        status.achievedRetina = virtualDisplay.mode?.isHiDPI ?? false
        status.scaleMode = options.scaleMode
        status.inputEnabled = options.inputEnabled
        status.tabletInputReported = tabletInputReported
        status.mjpegClients = mjpegHub.clientCount
        let snapshot = stats.snapshot()
        status.captureFps = snapshot.captureFps
        status.encodeFps = snapshot.encodeFps
        status.kbps = snapshot.kbps
        status.rttMs = snapshot.rttMs
        status.frames = snapshot.capturedFrames
        status.uptime = snapshot.uptime
        status.message = lastFailureMessage
        return status
    }

    /// Changes the tablet endpoint. When a session is running the transport is
    /// re-established immediately (capture/display stay untouched).
    func setEndpoint(_ endpoint: Endpoint?) {
        options.connect = endpoint
        options.listen = nil
        Log.info("connection target set to \(endpoint?.description ?? "none (web-only)")")
        if sessionActive {
            restartTransport()
        }
    }

    func restartTransport() {
        guard sessionActive else { return }
        transport?.stop()
        transport = nil
        Log.info("reconnecting to the tablet …")
        setupTransport()
    }

    /// Stops the HLDP transport but keeps the session (virtual display + web
    /// fallback) running. Used by the GUI's "USB 有线" mode when no device is
    /// found: it must report an error instead of silently falling back to Wi-Fi.
    func stopTransport() {
        guard transport != nil else { return }
        transport?.stop()
        transport = nil
        Log.info("HLDP transport stopped by user (connection mode change)")
    }

    /// Whether a tablet link is currently established.
    var isTransportReady: Bool { transport?.isReady ?? false }

    func setInputEnabled(_ enabled: Bool) {
        options.inputEnabled = enabled
        if enabled {
            _ = inputInjector.checkAccessibility(prompt: true)
        }
        inputInjector.setEnabled(enabled)
        broadcastConfig()
        Log.info("touch control \(enabled ? "enabled" : "disabled") from UI")
    }

    func setScaleMode(_ mode: ScaleModeOption) {
        options.scaleMode = mode
        broadcastConfig()
        encoder?.requestKeyframe()
        Log.info("display scale mode -> \(mode.rawValue)")
    }

    /// v1.2: switch virtual display render mode (原生 1:1 / HiDPI 最大化).
    ///
    /// 1x <-> 2x switches are done in-process with retained CGDisplayMode handles
    /// (the display object cannot be re-created in the same process); the capture
    /// pipeline is restarted and the new config is sent to the tablet.
    func setRenderMode(_ mode: RenderMode) {
        guard options.renderMode != mode else { return }
        options.renderMode = mode
        let plan = desiredStreamPlan()
        Log.info("render mode -> \(mode.title) (\(mode.rawValue))")
        guard sessionActive else { return }
        // 1x -> 2x cannot be achieved in-process when the 2x mode was never active
        // (macOS does not expose it in the public mode list). The GUI relaunches
        // itself with the new mode persisted; CLI logs and keeps the current mode.
        if virtualDisplay.mode?.isHiDPI != plan.retina,
           !virtualDisplay.hasModeHandle(retina: plan.retina) {
            if let relaunch = onRenderModeRequiresRelaunch {
                Log.info("render mode needs a fresh process; relaunching HaloLink …")
                relaunch(mode)
                return
            }
            Log.warn("switching \(virtualDisplay.mode?.isHiDPI == true ? "2x -> 1x" : "1x -> 2x") " +
                     "is not supported in-process for this display; keeping current mode")
            options.renderMode = (virtualDisplay.mode?.isHiDPI ?? true) ? .hidpiScale : .pixel1to1
            broadcastConfig()
            return
        }
        reconfigureStream(plan: plan, fps: streamFPS) { [weak self] success in
            guard let self = self else { return }
            if success {
                Log.info("render mode active: \(self.renderModeDescription())")
            } else {
                Log.warn("render mode switch failed; keeping \(self.renderModeDescription())")
                self.options.renderMode = (self.virtualDisplay.mode?.isHiDPI ?? true)
                    ? .hidpiScale : .pixel1to1
            }
            self.broadcastConfig()
            self.encoder?.requestKeyframe()
            self.onPhaseChanged?(self.phase)
        }
    }

    /// Sends the current config again (rotation, scale mode, input toggle).
    func broadcastConfig() {
        guard let transport = transport, transport.isReady else { return }
        let configuration = makeHLDPConfiguration()
        transport.sendConfig(configuration)
    }

    private func makeHLDPConfiguration() -> HLDPConfiguration {
        HLDPConfiguration(width: capturePixelWidth,
                          height: capturePixelHeight,
                          fps: streamFPS,
                          bitrate: options.bitrate,
                          profile: options.profile,
                          keyframeIntervalSeconds: 1,
                          scaleMode: options.scaleMode.rawValue,
                          retina: virtualDisplay.mode?.isHiDPI ?? false,
                          logicalWidth: logicalWidth,
                          logicalHeight: logicalHeight,
                          inputEnabled: options.inputEnabled,
                          renderMode: options.renderMode == .pixel1to1
                              ? "pixel1to1" : "scale",
                          frameTs: tabletSupportsFrameTs)
    }

    // MARK: - Desired display plan (scale target + orientation)

    /// Description of the virtual display a render mode should produce.
    struct RenderPlan {
        let pixelWidth: Int
        let pixelHeight: Int
        let logicalWidth: Int
        let logicalHeight: Int
        /// true = 2x HiDPI (may overshoot the panel by up to 8 px for a better mode);
        /// false = native 1:1 pixels.
        let retina: Bool
        let mode: RenderMode
    }

    /// Tablet pixel size for the current orientation (exact native panel size).
    private func tabletCurrentPixelSize() -> (width: Int, height: Int) {
        if tabletOrientation == "portrait" {
            return (tabletNativeLandscape.height, tabletNativeLandscape.width)
        }
        return tabletNativeLandscape
    }

    /// Computes the virtual display + stream the current render mode wants.
    ///
    /// v1.2:
    ///  * `pixel1to1` -> exact tablet panel pixels as a 1x display (no scaling on
    ///    the tablet; UI appears small);
    ///  * `scale`     -> exact tablet panel pixels as the target of a 2x HiDPI
    ///    display; macOS may only offer a mode that is up to 8 px taller than the
    ///    panel (tablet crops those edge pixels). The exact mode is preferred.
    private func desiredStreamPlan() -> RenderPlan {
        let panel = tabletCurrentPixelSize()
        let forceNoHiDPI = options.renderMode == .pixel1to1 || options.hidpi == .off
        if options.synthetic {
            let pixelW = Int(options.width)
            let pixelH = Int(options.height)
            let hidpi = !forceNoHiDPI && pixelW % 2 == 0 && pixelH % 2 == 0
            return RenderPlan(pixelWidth: pixelW, pixelHeight: pixelH,
                              logicalWidth: hidpi ? pixelW / 2 : pixelW,
                              logicalHeight: hidpi ? pixelH / 2 : pixelH,
                              retina: hidpi, mode: options.renderMode)
        }
        if options.displayMode == .mirror {
            let size = VirtualDisplay.mainDisplayPixelSize()
            let mainMode = VirtualDisplay.modeInfo(for: CGMainDisplayID())
            let hidpi = !forceNoHiDPI && (mainMode?.isHiDPI ?? false)
            return RenderPlan(pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                              logicalWidth: Int(mainMode?.pointWidth ?? size.width),
                              logicalHeight: Int(mainMode?.pointHeight ?? size.height),
                              retina: hidpi, mode: options.renderMode)
        }
        if options.widthExplicit || options.heightExplicit {
            let pixelW = Int(options.width)
            let pixelH = Int(options.height)
            let hidpi = !forceNoHiDPI && pixelW % 2 == 0 && pixelH % 2 == 0
            return RenderPlan(pixelWidth: pixelW, pixelHeight: pixelH,
                              logicalWidth: hidpi ? pixelW / 2 : pixelW,
                              logicalHeight: hidpi ? pixelH / 2 : pixelH,
                              retina: hidpi, mode: options.renderMode)
        }
        switch options.renderMode {
        case .matchMain:
            let size = VirtualDisplay.mainDisplayPixelSize()
            let mainMode = VirtualDisplay.modeInfo(for: CGMainDisplayID())
            return RenderPlan(pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                              logicalWidth: Int(mainMode?.pointWidth ?? size.width / 2),
                              logicalHeight: Int(mainMode?.pointHeight ?? size.height / 2),
                              retina: true, mode: .matchMain)
        case .pixel1to1:
            return RenderPlan(pixelWidth: panel.width, pixelHeight: panel.height,
                              logicalWidth: panel.width, logicalHeight: panel.height,
                              retina: false, mode: .pixel1to1)
        case .hidpiScale:
            return RenderPlan(pixelWidth: panel.width, pixelHeight: panel.height,
                              logicalWidth: panel.width / 2, logicalHeight: panel.height / 2,
                              retina: !forceNoHiDPI, mode: .hidpiScale)
        }
    }

    /// Dev/test hook: when HALOLINK_TEST_SKIP_ARRANGE=1 the display is not moved or
    /// mirrored-configured (allows a side-by-side test display while another
    /// HaloLink instance is running on the same Mac).
    private var skipArrangement: Bool {
        ProcessInfo.processInfo.environment["HALOLINK_TEST_SKIP_ARRANGE"] == "1"
    }

    /// Whether the display's current mode matches the plan (HiDPI plans also accept
    /// the +8 px taller variant that macOS may be forced to use).
    private func actualSatisfiesPlan(_ plan: RenderPlan) -> Bool {
        guard let mode = virtualDisplay.refreshMode(), mode.pixelWidth > 0 else { return false }
        let width = Int(mode.pixelWidth)
        let height = Int(mode.pixelHeight)
        if plan.retina {
            let heightOK = height == plan.pixelHeight || height == plan.pixelHeight + 8
            return mode.isHiDPI && width == plan.pixelWidth && heightOK
        }
        return !mode.isHiDPI && width == plan.pixelWidth && height == plan.pixelHeight
    }

    /// Short human readable description of the achieved display for logs/UI.
    private func renderModeDescription() -> String {
        guard let mode = virtualDisplay.refreshMode(), mode.pixelWidth > 0 else { return "—" }
        let kind = mode.isHiDPI ? "2x HiDPI" : "1x"
        return "\(mode.pixelWidth)×\(mode.pixelHeight) px = " +
            "\(mode.pointWidth)×\(mode.pointHeight) pt (\(kind))"
    }

    /// Framebuffer capacity large enough for every orientation / sizing target.
    ///
    /// Note: macOS drops the 2x (HiDPI) mode ladder when the capacity is much
    /// larger than the declared modes — a square 2940x2940 capacity made the
    /// virtual display come up 1x in testing. We therefore only cover the sizes we
    /// actually use: tablet landscape/portrait and the main display's own size
    /// (never rotated) -> 2940x2808 on a 1470x956 pt / 2940x1912 px Mac.
    private func displayCapacity() -> (width: UInt32, height: UInt32) {
        if let override = ProcessInfo.processInfo.environment["HALOLINK_CAPACITY"],
           case let parts = override.split(separator: "x"), parts.count == 2,
           let w = UInt32(parts[0]), let h = UInt32(parts[1]) {
            return (w, h)
        }
        let main = VirtualDisplay.mainDisplayPixelSize()
        if options.renderMode == .matchMain {
            var w = max(Int(main.width), 2800)
            var h = max(Int(main.height), 2808)
            if w % 2 != 0 { w += 1 }
            if h % 2 != 0 { h += 1 }
            return (UInt32(w), UInt32(h))
        }
        // Only cover the tablet panel in both orientations (+ the 8 px HiDPI anchor).
        // Keeping the capacity *width* equal to the panel width makes macOS pick the
        // exact 2x mode deterministically (a wider capacity such as 2940 randomly
        // makes it fall back to a 1x "scaled" default in testing).
        let landscape = tabletNativeLandscape
        let portrait = (width: landscape.height, height: landscape.width)
        var w = max(landscape.width, portrait.width)
        var h = max(landscape.height + 8, portrait.height + 8)
        if w % 2 != 0 { w += 1 }
        if h % 2 != 0 { h += 1 }
        return (UInt32(w), UInt32(h))
    }

    private func refreshLogicalSize() {
        guard let mode = virtualDisplay.refreshMode() else { return }
        logicalWidth = Int(mode.pointWidth)
        logicalHeight = Int(mode.pointHeight)
    }

    // MARK: - Display / capture setup

    /// Creates/attaches the display (fast, synchronous). Mode verification and
    /// placement happen later in finalizeDisplay() once registration completed.
    @discardableResult
    private func createDisplay() -> Bool {
        isMirrorMode = false
        modeDescription = "virtual"
        if options.synthetic {
            modeDescription = "synthetic"
            sourceDisplayID = 0
            capturePixelWidth = Int(options.width)
            capturePixelHeight = Int(options.height)
            logicalWidth = capturePixelWidth
            logicalHeight = capturePixelHeight
            boundsBox.set(CGDisplayBounds(CGMainDisplayID()))
            Log.info("synthetic test mode: generated frames \(capturePixelWidth)x\(capturePixelHeight)")
            return true
        }
        let plan = desiredStreamPlan()
        if options.displayMode == .mirror {
            isMirrorMode = true
            modeDescription = "mirror"
            sourceDisplayID = CGMainDisplayID()
            capturePixelWidth = plan.pixelWidth
            capturePixelHeight = plan.pixelHeight
            logicalWidth = plan.logicalWidth
            logicalHeight = plan.logicalHeight
            boundsBox.set(CGDisplayBounds(sourceDisplayID))
            Log.info("display-mode=mirror: capturing the main display " +
                     "(\(capturePixelWidth)x\(capturePixelHeight)px)")
            return true
        }

        guard VirtualDisplay.isSupported else {
            Log.error("private CGVirtualDisplay API unavailable on this macOS build; " +
                      "falling back to mirror mode")
            options.displayMode = .mirror
            return createDisplay()
        }

        // A display from a previous instance normally detaches when that process
        // exits, but allow up to 3s for it (never touch displays we do not own).
        var existing = VirtualDisplay.existingHaloLinkDisplay()
        if existing != 0 {
            Log.warn("a HaloLink virtual display (id=\(existing)) is still online; " +
                     "waiting up to 3s for the previous instance to release it …")
            let deadline = Clock.now() + 3.0
            while existing != 0 && Clock.now() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                existing = VirtualDisplay.existingHaloLinkDisplay()
            }
        }

        let capacity = displayCapacity()
        let created = virtualDisplay.create(
            pixelWidth: UInt32(plan.pixelWidth), pixelHeight: UInt32(plan.pixelHeight),
            logicalWidth: UInt32(plan.logicalWidth), logicalHeight: UInt32(plan.logicalHeight),
            maxPixelWidth: capacity.width, maxPixelHeight: capacity.height,
            refresh: streamFPS,
            // Always create with the rich HiDPI declaration: it exposes the exact
            // 2x mode AND a 1x mode, which we retain for in-process switching
            // (CGVirtualDisplay cannot be re-created in the same process).
            hidpi: .auto,
            name: options.displayName)
        guard created else {
            lastFailureMessage = "无法创建虚拟显示器（CGVirtualDisplay），请查看日志"
            return false
        }
        return true
    }

    /// Verifies the display mode, forces the requested mode when needed and
    /// arranges the display to the right of the main display. Called once the mode
    /// is readable and after every runtime reconfiguration.
    @discardableResult
    private func finalizeDisplay() -> Bool {
        guard virtualDisplay.isActive else { return true }
        let plan = desiredStreamPlan()
        // Diagnostics for registration timing.
        if Log.verbose {
            var ids = [CGDirectDisplayID](repeating: 0, count: 32)
            var count: UInt32 = 0
            CGGetOnlineDisplayList(32, &ids, &count)
            let online = Array(ids.prefix(Int(count)))
            Log.debug("post-create: online=\(online) vd=\(virtualDisplay.displayID) " +
                      "included=\(online.contains(virtualDisplay.displayID)) " +
                      "active=\(CGDisplayIsActive(virtualDisplay.displayID))")
            if let direct = CGDisplayCopyDisplayMode(virtualDisplay.displayID) {
                Log.debug("post-create CGDisplayCopyDisplayMode: \(direct.width)x\(direct.height) " +
                          "px=\(direct.pixelWidth)x\(direct.pixelHeight)")
            } else {
                Log.debug("post-create CGDisplayCopyDisplayMode returned nil")
            }
        }
        // Some aspect ratios come up 1x; retry an explicit mode selection once.
        if virtualDisplay.refreshMode() == nil {
            _ = virtualDisplay.waitForModeReady(timeout: 3.0)
        }
        if let mode = virtualDisplay.mode,
           Int(mode.pixelWidth) != plan.pixelWidth || Int(mode.pixelHeight) != plan.pixelHeight {
            Log.info("virtual display came up as \(mode.description); selecting " +
                     "\(plan.pixelWidth)x\(plan.pixelHeight) explicitly")
            _ = virtualDisplay.ensureMode(pixelWidth: UInt32(plan.pixelWidth),
                                          pixelHeight: UInt32(plan.pixelHeight))
            _ = virtualDisplay.refreshMode()
            if let updated = virtualDisplay.mode, !updated.isHiDPI, plan.retina {
                virtualDisplay.debugDumpModes()
            }
        }
        if !skipArrangement {
            _ = virtualDisplay.placeRightOfMain()
            _ = virtualDisplay.ensurePhysicalStaysMain()
        }
        virtualDisplay.refreshModeHandles()
        sourceDisplayID = virtualDisplay.displayID
        if let mode = virtualDisplay.refreshMode(), mode.pixelWidth > 0 {
            capturePixelWidth = Int(mode.pixelWidth)
            capturePixelHeight = Int(mode.pixelHeight)
            logicalWidth = Int(mode.pointWidth)
            logicalHeight = Int(mode.pointHeight)
            if plan.retina && !mode.isHiDPI {
                Log.warn("macOS only exposed a 1x mode for \(plan.pixelWidth)x\(plan.pixelHeight); " +
                         "config reports logical=\(logicalWidth)x\(logicalHeight) retina=false")
            }
        } else {
            capturePixelWidth = plan.pixelWidth
            capturePixelHeight = plan.pixelHeight
            logicalWidth = plan.logicalWidth
            logicalHeight = plan.logicalHeight
        }
        if let mode = virtualDisplay.mode {
            if plan.retina && !mode.isHiDPI {
                Log.warn("macOS did not expose a 2x mode for \(plan.pixelWidth)x" +
                         "\(plan.pixelHeight); desktop renders 1x (config reports the " +
                         "actual logical size)")
                virtualDisplay.debugDumpModes()
            } else if mode.isHiDPI {
                Log.info("HiDPI 2x backing active: desktop \(mode.pointWidth)x" +
                         "\(mode.pointHeight) pt / \(mode.pixelWidth)x\(mode.pixelHeight) px")
            }
        }
        boundsBox.set(currentInputBounds())
        Log.info("extended desktop active: main=\(CGMainDisplayID()) " +
                 "virtual=\(virtualDisplay.displayID) " +
                 "capture=\(capturePixelWidth)x\(capturePixelHeight)px " +
                 "logical=\(logicalWidth)x\(logicalHeight)pt " +
                 "orientation=\(tabletOrientation) renderMode=\(options.renderMode.rawValue) " +
                 "achieved=\(renderModeDescription())")
        return true
    }

    private func setupEncoder() {
        do {
            let encoder = try H264Encoder(width: capturePixelWidth, height: capturePixelHeight,
                                          fps: streamFPS, bitrate: options.bitrate,
                                          profile: options.profile)
            encoder.onFrameDropped = { [weak self] in
                self?.stats.recordDroppedEncode()
            }
            encoder.onEncodedFrame = { [weak self] frame in
                guard let self = self else { return }
                let encodedAt = Clock.now()
                self.stats.recordEncoded(bytes: frame.data.count, keyframe: frame.isKeyframe)
                self.latency.noteEncode(milliseconds: frame.encodeMs)
                if self.dumpEnabled {
                    self.writeDump(frame.data)
                }
                self.transport?.sendVideo(frame.data, isKeyframe: frame.isKeyframe,
                                          captureTimestampUs: frame.captureTimestampUs,
                                          encodedAt: encodedAt)
            }
            self.encoder = encoder
        } catch {
            Log.error("H.264 encoder unavailable: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func setupCapture() -> Bool {
        if options.synthetic {
            let source = SyntheticSource(width: capturePixelWidth, height: capturePixelHeight,
                                         fps: streamFPS)
            source.onFrame = { [weak self] buffer, pts in
                self?.handleFrame(buffer, pts: pts)
            }
            do {
                try source.start()
                synthetic = source
                return true
            } catch {
                lastFailureMessage = "synthetic source failed: \(error.localizedDescription)"
                return false
            }
        }
        capture.delegate = self
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try capture.start(displayID: sourceDisplayID,
                                  pixelWidth: capturePixelWidth,
                                  pixelHeight: capturePixelHeight,
                                  fps: streamFPS,
                                  showCursor: options.showCursor)
                lastError = nil
                break
            } catch {
                lastError = error
                Log.warn("capture start attempt \(attempt)/3 failed: \(error.localizedDescription)")
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.8) }
            }
        }
        if let lastError = lastError {
            Log.error("capture failed: \(lastError.localizedDescription)")
            Log.error("If this is a permission problem: System Settings → Privacy & Security " +
                      "→ Screen & System Audio Recording → enable “\(InputInjector.appName)”")
            lastFailureMessage = "屏幕采集失败：\(lastError.localizedDescription)"
            return false
        }
        return true
    }

    private func currentInputBounds() -> CGRect {
        if virtualDisplay.isActive {
            let bounds = CGDisplayBounds(virtualDisplay.displayID)
            return bounds.isEmpty ? boundsBox.get() : bounds
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    // MARK: - Web server

    @discardableResult
    private func setupWebServer() -> Bool {
        guard options.webEnabled else {
            Log.info("web server disabled")
            return true
        }
        // Preferred port first, then a few neighbours (a busy 8080 must not stop
        // the app from starting).
        let preferred = options.httpPort
        var candidates = [preferred]
        if preferred > 0 && preferred < 65535 {
            candidates.append(contentsOf: (1...5).map { preferred + $0 })
        }
        for port in candidates where port > 0 && port <= 65535 {
            let server = WebServer(port: port, hub: mjpegHub,
                                   inputInjector: inputInjector,
                                   statusProvider: { [weak self] in
                self?.statusJSON() ?? ["error": "host unavailable"]
            })
            do {
                try server.start()
                webServer = server
                if port != preferred {
                    Log.warn("HTTP port \(preferred) is busy; using \(port) instead " +
                             "(tablet URL updated)")
                    options.httpPort = port
                }
                return true
            } catch {
                Log.warn("web server port \(port) failed: \(error.localizedDescription)")
                if port == candidates.last {
                    lastFailureMessage = "HTTP 服务启动失败：\(error.localizedDescription)"
                    return false
                }
            }
        }
        lastFailureMessage = "HTTP 服务启动失败（无可用端口）"
        return false
    }

    private func statusJSON() -> [String: Any] {
        let snapshot = stats.snapshot()
        var json: [String: Any] = [
            "app": "halolink-host",
            "version": "1.3.1",
            "width": capturePixelWidth,
            "height": capturePixelHeight,
            "fps": streamFPS,
            "clients": mjpegHub.clientCount,
            "displayId": Int(virtualDisplay.displayID),
            "mode": modeDescription,
            "encodedFps": (snapshot.encodeFps * 10).rounded() / 10,
            "captureFps": (snapshot.captureFps * 10).rounded() / 10,
            "kbps": (snapshot.kbps * 10).rounded() / 10,
            "sentFps": snapshot.sentFrames,
            "rttMs": (snapshot.rttMs * 10).rounded() / 10,
            "frames": snapshot.capturedFrames,
            "encoded": snapshot.encodedFrames,
            "jpeg": snapshot.jpegFrames,
            "dropped": snapshot.droppedEncode + snapshot.droppedSend,
            "uptime": (snapshot.uptime * 10).rounded() / 10,
            "httpPort": options.httpPort,
            // v1.1 display info
            "scaleMode": options.scaleMode.rawValue,
            "renderMode": options.renderMode.rawValue,
            "retina": virtualDisplay.mode?.isHiDPI ?? false,
            "logicalWidth": logicalWidth,
            "logicalHeight": logicalHeight,
            "orientation": tabletOrientation,
            "inputEnabled": options.inputEnabled,
            "inputReportedByTablet": tabletInputReported.map { $0 as Any } ?? NSNull(),
            "phase": phase.text
        ]
        if let transport = transport {
            json["transport"] = transport.isReady ? "ready" : "down"
            let counters = transport.counters
            json["sentFrames"] = counters.sentFrames
            json["sentBytes"] = counters.sentBytes
            json["transportDropped"] = counters.droppedFrames
        } else {
            json["transport"] = "off"
        }
        let latencySummary = latency.summary(transportRTTMs: snapshot.rttMs)
        json["captureMsAvg"] = (latencySummary.captureAvgMs * 10).rounded() / 10
        json["captureMsP95"] = (latencySummary.captureP95Ms * 10).rounded() / 10
        json["encodeMsAvg"] = (latencySummary.encodeAvgMs * 10).rounded() / 10
        json["encodeMsP95"] = (latencySummary.encodeP95Ms * 10).rounded() / 10
        json["sendMsAvg"] = (latencySummary.sendAvgMs * 10).rounded() / 10
        json["sendMsP95"] = (latencySummary.sendP95Ms * 10).rounded() / 10
        json["e2eMs"] = (latencySummary.e2eMs * 10).rounded() / 10
        // Documentation only: the tablet's rolling-minimum estimator removes clock
        // bias and underestimates true capture→render by captureToSend + minTransport.
        json["e2eMsNote"] = "tablet-reported, min-bias removed; add ~capture-to-send + " +
            "minimum transport (≈20ms) for true capture→render"
        json["captureToSendMsAvg"] =
            ((latencySummary.encodeAvgMs + latencySummary.sendAvgMs) * 10).rounded() / 10
        json["captureToSendMsP95"] =
            ((latencySummary.encodeP95Ms + latencySummary.sendP95Ms) * 10).rounded() / 10
        json["recvMs"] = (latencySummary.recvMs * 10).rounded() / 10
        // `decMs` = HLDP v1.3 decode-stage field; `decodeMs` = legacy metric that
        // the tablet HUD labels "解码". Both are reported verbatim.
        json["decMs"] = (latencySummary.decMs * 10).rounded() / 10
        json["decMsReported"] = latencySummary.decMsReported
        json["decodeMs"] = (latencySummary.decodeMsLegacy * 10).rounded() / 10
        json["renderMs"] = (latencySummary.renderMs * 10).rounded() / 10
        json["presentHz"] = latencySummary.presentHz
        json["frameTs"] = latencySummary.frameTimestampsEnabled
        json["tabletRttMs"] = (latencySummary.tabletRttMs * 10).rounded() / 10
        json["tabletStatsAge"] = latencySummary.tabletStatsAge
        if let anomaly = latencySummary.tabletLatencyAnomaly {
            json["tabletLatencyAnomaly"] = anomaly
        }
        let mjpegRate = mjpegHub.rateSnapshot
        json["mjpegFps"] = (mjpegRate.fps * 10).rounded() / 10
        json["mjpegKbps"] = (mjpegRate.kbps * 10).rounded() / 10
        json["jpegFrames"] = mjpegRate.totalFrames
        json["jpegTotalBytes"] = mjpegRate.totalBytes
        let info = mjpegHub.lastFrameInfo
        json["jpegBytes"] = info.bytes
        json["jpegMs"] = (info.encodeMs * 10).rounded() / 10
        json["jpegWidth"] = info.width
        json["jpegHeight"] = info.height
        return json
    }

    // MARK: - Transport

    private func setupTransport() {
        guard let endpointMode = transportMode() else {
            Log.info("no --connect/--listen target: web-only mode " +
                     "(open the printed URL on the tablet)")
            return
        }
        let transport = LinkTransport(mode: endpointMode,
                                      configuration: makeHLDPConfiguration(),
                                      localDeviceName: ProcessInfo.processInfo.hostName)
        transport.delegate = self
        transport.onVideoFrameSent = { [weak self] bytes in
            self?.stats.recordSent(bytes: bytes)
        }
        transport.onVideoFrameDropped = { [weak self] in
            self?.stats.recordDroppedSend()
        }
        transport.onVideoSendLatency = { [weak self] milliseconds in
            self?.latency.noteSend(milliseconds: milliseconds)
        }
        self.transport = transport
        switch endpointMode {
        case .client(let host, let port):
            Log.info("HLDP transport: connecting to tablet server \(host):\(port)")
        case .listener(let port):
            Log.info("HLDP transport: listening for the tablet on tcp:\(port) (debug mode)")
        }
        transport.start()
    }

    private func transportMode() -> LinkTransport.Mode? {
        if let connect = options.connect {
            return .client(host: connect.host, port: connect.port)
        }
        if let listen = options.listen {
            return .listener(port: listen.port)
        }
        return nil
    }

    // MARK: - H.264 dump

    private func setupDumpFileIfNeeded() {
        guard let path = options.dumpH264 else { return }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            Log.error("--dump-h264: cannot open \(path) for writing; dumping disabled")
            return
        }
        dumpFileHandle = handle
        dumpURL = url
        dumpEnabled = true
        dumpBytes = 0
        Log.info("h264 dump enabled: \(url.path)")
    }

    private func writeDump(_ data: Data) {
        dumpQueue.async { [weak self] in
            guard let self = self, let handle = self.dumpFileHandle else { return }
            do {
                try handle.write(contentsOf: data)
                self.dumpBytes += data.count
            } catch {
                if self.dumpEnabled {
                    Log.error("--dump-h264 write failed: \(error.localizedDescription)")
                    self.dumpEnabled = false
                }
            }
        }
    }

    private func finishDump() {
        dumpEnabled = false
        dumpQueue.sync {}
        if let handle = dumpFileHandle {
            try? handle.synchronize()
            try? handle.close()
            dumpFileHandle = nil
        }
        if let url = dumpURL {
            Log.info("h264 dump written: \(url.path) (\(dumpBytes) bytes)")
        }
        dumpURL = nil
    }

    // MARK: - Demo window

    private func setupDemoWindow() {
        let displayID = virtualDisplay.isActive ? virtualDisplay.displayID : CGMainDisplayID()
        demoWindow = DemoWindowController(displayID: displayID)
        demoWindow?.show()
        if demoWindow != nil {
            Log.info("demo window shown on display \(displayID) (clock + colour bars)")
        } else {
            Log.warn("could not create the demo window")
        }
    }

    private func layoutDemoWindow() {
        guard let demoWindow = demoWindow, virtualDisplay.isActive else { return }
        demoWindow.reposition(to: CGDisplayBounds(virtualDisplay.displayID))
    }

    // MARK: - Signals / observers / timers

    private var signalsInstalled = false

    /// Installs SIGINT/SIGTERM handlers. In CLI mode they quit the process; in app
    /// mode they ask AppKit to terminate (so applicationWillTerminate runs cleanup).
    func installSignalHandlers(appTerminate: Bool = false) {
        guard !signalsInstalled else { return }
        signalsInstalled = true
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                let name = sig == SIGINT ? "SIGINT" : "SIGTERM"
                Log.info("received \(name)")
                if appTerminate {
                    NSApp.terminate(nil)
                } else {
                    self?.quit(exitCode: 0, reason: name)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func installSessionObservers() {
        if !screenObserverInstalled {
            NotificationCenter.default.addObserver(
                self, selector: #selector(screenParametersChanged(_:)),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            screenObserverInstalled = true
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                Log.warn("system woke from sleep — macOS often cannot re-register a virtual " +
                         "display on the old WindowServer connection; restart HaloLink if the " +
                         "tablet stream does not resume")
                self?.screenParametersChanged(Notification(name: NSApplication.didChangeScreenParametersNotification))
            }
        }
    }

    private func removeSessionObservers() {
        if screenObserverInstalled {
            NotificationCenter.default.removeObserver(
                self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
            screenObserverInstalled = false
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        guard phase == .running || phase == .starting else { return }
        if virtualDisplay.isActive, !skipArrangement {
            _ = virtualDisplay.ensurePhysicalStaysMain()
        }
        boundsBox.set(currentInputBounds())
        layoutDemoWindow()
        Log.debug("screen parameters changed: bounds=\(currentInputBounds()) " +
                  "main=\(CGMainDisplayID())")
    }

    private func installStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.phase == .running else { return }
            let snapshot = self.stats.updateRates()
            let transportState = self.transport.map { $0.isReady ? "ready" : "down" } ?? "off"
            let mjpegRate = self.mjpegHub.rateSnapshot
            let latencySummary = self.latency.summary(transportRTTMs: snapshot.rttMs)
            let captureToSendAvg = latencySummary.encodeAvgMs + latencySummary.sendAvgMs
            let captureToSendP95 = latencySummary.encodeP95Ms + latencySummary.sendP95Ms
            if Log.verbose {
                Log.debug(String(format: "host capture→send avg=%.1fms p95=%.1fms " +
                                "(encode %.1f + send %.1f); true e2e ≈ tablet e2e %.1f + " +
                                "minTransport", captureToSendAvg, captureToSendP95,
                                latencySummary.encodeAvgMs, latencySummary.sendAvgMs,
                                latencySummary.e2eMs))
            }
            Log.stats(self.stats.statsLine(snapshot: snapshot) +
                      " clients=\(self.mjpegHub.clientCount) " +
                      "display=\(self.virtualDisplay.displayID) transport=\(transportState) " +
                      String(format: "mjpegFps=%.1f mjpegKbps=%.0f",
                             mjpegRate.fps, mjpegRate.kbps) +
                      " | " + latencySummary.logLine)
        }
        timer.resume()
        statsTimer = timer
    }

    /// No frames for a while: refresh MJPEG with the cached frame, keep the native
    /// client fed with a forced IDR, and restart ScreenCaptureKit if it stays silent.
    private func refreshFromCachedFrame() {
        guard let last = lastFrame else { return }
        let now = Clock.now()
        guard now - lastKeepaliveTime >= 1.0 else { return }
        lastKeepaliveTime = now
        let pts = CMTime(seconds: now, preferredTimescale: 600)
        encoder?.requestKeyframe()
        encoder?.encode(last, pts: pts,
                        captureTimestampUs: Clock.epochMicroseconds(),
                        forceKeyframe: true)
        mjpegHub.submit(last)
    }

    /// Safety-net restart interval for a *silent* ScreenCaptureKit stream, in seconds.
    /// Static desktops legitimately deliver no frames; a short timeout causes an
    /// SCStream restart loop (macOS screen-sharing indicator flickers). Default: 5 min.
    private var captureIdleRestartSeconds: Double {
        if let raw = ProcessInfo.processInfo.environment["HALOLINK_CAPTURE_IDLE_RESTART"],
           let value = Double(raw) {
            return max(0, value)
        }
        return 300
    }

    private func installWatchdogTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.phase == .running, !self.shuttingDown else { return }
            let now = Clock.now()
            let gap: TimeInterval
            if self.options.synthetic {
                gap = self.lastFrameTime > 0 ? now - self.lastFrameTime : 0
            } else {
                gap = self.capture.secondsSinceLastFrame
            }
            guard gap > 2.0 else { return }
            let hasConsumers = self.mjpegHub.clientCount > 0 ||
                (self.transport?.isReady ?? false) || self.options.dumpH264 != nil
            if now - self.lastGapWarningTime >= 10.0 {
                self.lastGapWarningTime = now
                self.resumeLogged = true
                Log.warn(String(format: "capture watchdog: no frames for %.1fs " +
                                "(consumers=%@, clients=%d) — refreshing cached frame",
                                gap, hasConsumers ? "yes" : "no",
                                self.mjpegHub.clientCount))
            }
            if hasConsumers {
                self.refreshFromCachedFrame()
            }
            // Idle desktop: ScreenCaptureKit is change-driven, so a static screen
            // legitimately produces no frames. Restarting the SCStream on idle makes
            // macOS re-arm the "screen sharing" indicator every few seconds (visible
            // flicker) and is also wasteful. Keep only a very long safety net; real
            // failures are handled by the SCStream error delegate below.
            // Override with HALOLINK_CAPTURE_IDLE_RESTART=<seconds> (0 = never).
            if !self.options.synthetic, gap > self.captureIdleRestartSeconds,
               self.captureIdleRestartSeconds > 0,
               now - self.lastCaptureRestartTime >= self.captureIdleRestartSeconds {
                self.lastCaptureRestartTime = now
                self.capture.restartInBackground(reason: String(format:
                    "no captured frames for %.0fs", gap))
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    // MARK: - READY line

    private func printReadyLine() {
        guard !readyEmitted else { return }
        readyEmitted = true
        let displayID = virtualDisplay.displayID
        let httpPort = options.webEnabled ? String(options.httpPort) : "off"
        let url: String
        if options.webEnabled, let address = NetworkInfo.preferredLANAddress() {
            url = "http://\(address):\(options.httpPort)/"
        } else if options.webEnabled {
            url = "http://127.0.0.1:\(options.httpPort)/"
        } else {
            url = "off"
        }
        var connectText = "off"
        if let connect = options.connect { connectText = connect.description }
        if let listen = options.listen { connectText = "listen:" + listen.description }
        let hidpiText = (virtualDisplay.mode?.isHiDPI == true) ? "2x" : "1x"
        let bounds = currentInputBounds()
        let line = String(
            format: "READY display=%u bounds=(%.0f,%.0f,%.0fx%.0f) capture=%dx%d@%d " +
            "logical=%dx%d mode=%@ hidpi=%@ orientation=%@ renderMode=%@ input=%@ " +
            "http=%@ url=%@ connect=%@",
            displayID, bounds.origin.x, bounds.origin.y, bounds.size.width,
            bounds.size.height, capturePixelWidth, capturePixelHeight, streamFPS,
            logicalWidth, logicalHeight, modeDescription as NSString, hidpiText as NSString,
            tabletOrientation as NSString, options.renderMode.rawValue as NSString,
            (options.inputEnabled ? "on" : "off") as NSString,
            httpPort as NSString, url as NSString, connectText as NSString)
        Log.info(line)
    }

    // MARK: - Adaptive resolution / rotation

    /// Asynchronously restarts the capture+encoder pipeline at new dimensions/fps.
    /// MUST NOT block the run loop: WindowServer only completes a virtual display
    /// mode change while the run loop iterates normally. Rate limited (>=2 s, and
    /// callers debounce rotation events).
    private func reconfigureStream(plan: RenderPlan, fps: Int,
                                   completion: @escaping (Bool) -> Void) {
        guard !shuttingDown, phase == .running || phase == .starting,
              !options.synthetic else {
            completion(false)
            return
        }
        let sizeDiffers = abs(plan.pixelWidth - capturePixelWidth) > 2 ||
            abs(plan.pixelHeight - capturePixelHeight) > 2 || !actualSatisfiesPlan(plan)
        let fpsDiffers = fps != streamFPS
        guard sizeDiffers || fpsDiffers else {
            completion(true)
            return
        }
        let now = Clock.now()
        if now - lastReconfigureTime < 2.0 {
            Log.warn("reconfiguration rate-limited (min 2s between attempts)")
            completion(false)
            return
        }
        lastReconfigureTime = now

        let oldWidth = capturePixelWidth
        let oldHeight = capturePixelHeight
        let oldFPS = streamFPS
        Log.info("reconfiguring stream \(oldWidth)x\(oldHeight)@\(oldFPS)fps -> " +
                 "\(plan.pixelWidth)x\(plan.pixelHeight) \(plan.retina ? "2x HiDPI" : "1x")" +
                 "@\(fps)fps …")

        // A running ScreenCaptureKit stream pins the display's current mode.
        capture.stop()
        encoder?.finish()
        encoder = nil

        guard sizeDiffers, virtualDisplay.isActive else {
            restartPipeline(width: oldWidth, height: oldHeight, fps: fps,
                            oldWidth: oldWidth, oldHeight: oldHeight, oldFPS: oldFPS,
                            completion: completion)
            return
        }
        let currentHiDPI = virtualDisplay.mode?.isHiDPI ?? false
        if plan.retina != currentHiDPI,
           let current = virtualDisplay.refreshMode(),
           Int(current.pixelWidth) == plan.pixelWidth,
           Int(current.pixelHeight) == plan.pixelHeight ||
               Int(current.pixelHeight) == plan.pixelHeight + 8 {
            // Same resolution, different backing scale: use retained mode handles
            // (the virtual display cannot be re-created in the same process).
            guard virtualDisplay.switchRenderMode(retina: plan.retina) else {
                Log.warn("could not switch \(currentHiDPI ? "2x" : "1x") -> " +
                         "\(plan.retina ? "2x" : "1x"); keeping current mode")
                restartPipeline(width: oldWidth, height: oldHeight, fps: oldFPS,
                                oldWidth: oldWidth, oldHeight: oldHeight, oldFPS: oldFPS,
                                completion: { _ in completion(false) })
                return
            }
            pollRenderMode(plan: plan, deadline: Clock.now() + 2.5,
                           didForceSelect: false) { [weak self] mode in
                guard let self = self else { return }
                guard let mode = mode, mode.pixelWidth > 0 else {
                    Log.warn("mode switch did not settle; restoring " +
                             "\(oldWidth)x\(oldHeight)@\(oldFPS)fps")
                    _ = self.virtualDisplay.switchRenderMode(retina: currentHiDPI)
                    self.restartPipeline(width: oldWidth, height: oldHeight, fps: oldFPS,
                                         oldWidth: oldWidth, oldHeight: oldHeight,
                                         oldFPS: oldFPS,
                                         completion: { _ in completion(false) })
                    return
                }
                self.restartPipeline(width: Int(mode.pixelWidth),
                                     height: Int(mode.pixelHeight), fps: fps,
                                     oldWidth: oldWidth, oldHeight: oldHeight,
                                     oldFPS: oldFPS, completion: completion)
            }
            return
        }
        guard virtualDisplay.beginAdjust(width: UInt32(plan.pixelWidth),
                                         height: UInt32(plan.pixelHeight),
                                         refresh: fps,
                                         hidpi: plan.retina ? .auto : .off) else {
            Log.warn("runtime virtual-display reconfiguration rejected; " +
                     "keeping \(oldWidth)x\(oldHeight)@\(oldFPS)fps")
            restartPipeline(width: oldWidth, height: oldHeight, fps: oldFPS,
                            oldWidth: oldWidth, oldHeight: oldHeight, oldFPS: oldFPS,
                            completion: { _ in completion(false) })
            return
        }
        pollRenderMode(plan: plan, deadline: Clock.now() + 2.5, didForceSelect: false) {
            [weak self] mode in
            guard let self = self else { return }
            guard let mode = mode, mode.pixelWidth > 0 else {
                Log.warn("macOS did not produce \(plan.pixelWidth)x\(plan.pixelHeight) " +
                         "\(plan.retina ? "2x" : "1x"); restoring " +
                         "\(oldWidth)x\(oldHeight)@\(oldFPS)fps")
                self.restartPipeline(width: oldWidth, height: oldHeight, fps: oldFPS,
                                     oldWidth: oldWidth, oldHeight: oldHeight, oldFPS: oldFPS,
                                     completion: { _ in completion(false) })
                return
            }
            self.virtualDisplay.refreshModeHandles()
            let newWidth = Int(mode.pixelWidth)
            let newHeight = Int(mode.pixelHeight)
            if newWidth != plan.pixelWidth || newHeight != plan.pixelHeight {
                Log.info("macOS achieved \(newWidth)x\(newHeight) for the requested " +
                         "\(plan.pixelWidth)x\(plan.pixelHeight); using the achieved mode " +
                         "(tablet crops/pads accordingly)")
            }
            self.restartPipeline(width: newWidth, height: newHeight, fps: fps,
                                 oldWidth: oldWidth, oldHeight: oldHeight, oldFPS: oldFPS,
                                 completion: completion)
        }
    }

    /// Polls until the display mode satisfies the render plan (asynchronous: the
    /// run loop must iterate for WindowServer to apply the mode change). Falls back
    /// to an explicit mode selection when WindowServer does not auto-switch.
    private func pollRenderMode(plan: RenderPlan, deadline: TimeInterval,
                                didForceSelect: Bool,
                                completion: @escaping (DisplayModeSnapshot?) -> Void) {
        if actualSatisfiesPlan(plan) {
            completion(virtualDisplay.refreshMode())
            return
        }
        if Clock.now() >= deadline {
            if !didForceSelect {
                if let candidate = VirtualDisplay.bestHiDPIMode(
                        displayID: virtualDisplay.displayID,
                        panelWidth: UInt32(plan.pixelWidth),
                        panelHeight: UInt32(plan.pixelHeight)),
                   plan.retina {
                    Log.info("selecting 2x mode \(candidate.description) explicitly")
                    _ = virtualDisplay.forceSelectMode(pixelWidth: candidate.pixelWidth,
                                                       pixelHeight: candidate.pixelHeight,
                                                       refresh: streamFPS)
                } else if !plan.retina {
                    _ = virtualDisplay.forceSelectMode(pixelWidth: UInt32(plan.pixelWidth),
                                                       pixelHeight: UInt32(plan.pixelHeight),
                                                       refresh: streamFPS)
                }
                pollRenderMode(plan: plan, deadline: Clock.now() + 1.8,
                               didForceSelect: true, completion: completion)
            } else {
                completion(nil)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pollRenderMode(plan: plan, deadline: deadline,
                                 didForceSelect: didForceSelect, completion: completion)
        }
    }

    private func restartPipeline(width: Int, height: Int, fps: Int,
                                 oldWidth: Int, oldHeight: Int, oldFPS: Int,
                                 completion: @escaping (Bool) -> Void) {
        capturePixelWidth = width
        capturePixelHeight = height
        streamFPS = fps
        if wantsVideoStream { setupEncoder() }
        do {
            try capture.start(displayID: sourceDisplayID,
                              pixelWidth: capturePixelWidth,
                              pixelHeight: capturePixelHeight,
                              fps: streamFPS,
                              showCursor: options.showCursor)
            if !skipArrangement {
                _ = virtualDisplay.placeRightOfMain()
                _ = virtualDisplay.ensurePhysicalStaysMain()
            }
            refreshLogicalSize()
            boundsBox.set(currentInputBounds())
            layoutDemoWindow()
            encoder?.requestKeyframe()
            Log.info("stream reconfiguration complete — " +
                     "\(capturePixelWidth)x\(capturePixelHeight)@\(streamFPS)fps " +
                     "logical=\(logicalWidth)x\(logicalHeight)")
            completion(true)
        } catch {
            Log.error("capture restart failed after reconfiguration " +
                      "(\(error.localizedDescription)); restoring previous stream")
            capturePixelWidth = oldWidth
            capturePixelHeight = oldHeight
            streamFPS = oldFPS
            if virtualDisplay.isActive, width != oldWidth || height != oldHeight {
                _ = virtualDisplay.beginAdjust(width: UInt32(oldWidth),
                                               height: UInt32(oldHeight),
                                               refresh: oldFPS,
                                               hidpi: (virtualDisplay.mode?.isHiDPI ?? true)
                                                   ? .auto : .off)
                _ = virtualDisplay.ensureMode(pixelWidth: UInt32(oldWidth),
                                              pixelHeight: UInt32(oldHeight))
            }
            if wantsVideoStream { setupEncoder() }
            try? capture.start(displayID: sourceDisplayID,
                               pixelWidth: capturePixelWidth,
                               pixelHeight: capturePixelHeight,
                               fps: streamFPS,
                               showCursor: options.showCursor)
            refreshLogicalSize()
            boundsBox.set(currentInputBounds())
            completion(false)
        }
    }

    /// Handles the HLDP hello (client mode): adapt display/fps to the tablet's real
    /// panel and orientation, then answer with the config that matches what we stream.
    private func adaptToTabletScreen(_ screen: [String: Any],
                                     hello: [String: Any],
                                     respond: @escaping (HLDPConfiguration) -> Void) {
        let rawWidth = Int(InputInjector.doubleValue(screen["width"]) ?? 0)
        let rawHeight = Int(InputInjector.doubleValue(screen["height"]) ?? 0)
        let refresh = InputInjector.doubleValue(screen["refreshRate"]) ?? 0
        let density = InputInjector.doubleValue(screen["density"]) ?? 0
        let orientation = (screen["orientation"] as? String)?.lowercased()
        let device = hello["device"] as? String ?? "tablet"

        // HLDP v1.3: capability negotiation via hello.features.
        if let features = hello["features"] as? [String] {
            let supportsFrameTs = features.contains("frameTs")
            if supportsFrameTs != tabletSupportsFrameTs {
                tabletSupportsFrameTs = supportsFrameTs
                latency.setFrameTimestampsEnabled(supportsFrameTs)
                if supportsFrameTs {
                    Log.info("tablet frameTs feature: supported — VIDEO frames will carry " +
                             "8-byte capture timestamps")
                } else {
                    Log.info("tablet frameTs feature: not supported")
                }
            }
        } else {
            tabletSupportsFrameTs = false
            latency.setFrameTimestampsEnabled(false)
        }

        if rawWidth > 0, rawHeight > 0 {
            tabletNativeLandscape = (max(rawWidth, rawHeight), min(rawWidth, rawHeight))
            tabletOrientation = orientation ??
                (rawHeight > rawWidth ? "portrait" : "landscape")
            Log.info(String(format: "tablet screen %@: %dx%d density=%.2f hz=%.0f " +
                            "orientation=%@", device, rawWidth, rawHeight, density, refresh,
                            tabletOrientation as NSString))
        } else {
            Log.info("tablet screen \(device): size not reported (old app); keeping defaults")
        }

        var targetFPS = streamFPS
        if options.auto, refresh > 0 {
            let tabletFPS = Int(max(24, min(240, refresh.rounded(.down))))
            targetFPS = min(options.fps, tabletFPS)
            Log.info("auto: stream fps = min(--fps \(options.fps), tablet \(tabletFPS)Hz) " +
                     "= \(targetFPS)")
        }

        var respondOnceDone = false
        func respondOnce() {
            guard !respondOnceDone else { return }
            respondOnceDone = true
            let config = makeHLDPConfiguration()
            Log.info("HLDP -> config: \(config.width)x\(config.height)@\(config.fps)fps " +
                     "scaleMode=\(config.scaleMode) retina=\(config.retina) " +
                     "logical=\(config.logicalWidth)x\(config.logicalHeight) " +
                     "input=\(config.inputEnabled)")
            respond(config)
        }

        let plan = desiredStreamPlan()
        let currentAspect = Double(capturePixelWidth) / Double(max(1, capturePixelHeight))
        let targetAspect = Double(plan.pixelWidth) / Double(max(1, plan.pixelHeight))
        let aspectDelta = abs(currentAspect - targetAspect) / max(0.0001, targetAspect)
        let sizeDelta = Double(max(abs(plan.pixelWidth - capturePixelWidth),
                                   abs(plan.pixelHeight - capturePixelHeight))) /
            Double(max(1, capturePixelWidth))
        let renderModeMismatch = !actualSatisfiesPlan(plan)
        let needsResize = renderModeMismatch ||
            (options.auto && (aspectDelta > 0.05 || sizeDelta > 0.05))
        if needsResize {
            Log.info(String(format: "auto: adapting virtual display %dx%d -> %dx%d " +
                            "(renderMode=%@, aspect delta %.1f%%, size delta %.1f%%)",
                            capturePixelWidth, capturePixelHeight, plan.pixelWidth,
                            plan.pixelHeight, options.renderMode.rawValue as NSString,
                            aspectDelta * 100, sizeDelta * 100))
            reconfigureStream(plan: plan, fps: targetFPS) { [weak self] success in
                guard let self = self else { return }
                if success {
                    self.logicalWidth = Int(self.virtualDisplay.mode?.pointWidth ?? 0)
                    self.logicalHeight = Int(self.virtualDisplay.mode?.pointHeight ?? 0)
                }
                respondOnce()
            }
        } else if options.auto, targetFPS != streamFPS {
            reconfigureStream(plan: plan, fps: targetFPS) { _ in respondOnce() }
        } else {
            Log.info("auto: virtual display \(renderModeDescription()) matches tablet panel " +
                     "\(rawWidth)x\(rawHeight) renderMode=\(options.renderMode.rawValue)")
            respondOnce()
        }
    }

    /// HLDP v1.1 §7.3: tablet rotated / resized while streaming.
    func handleDisplayChange(_ message: [String: Any]) {
        guard sessionActive else { return }
        pendingDisplayMessage = message
        displayDebounce?.cancel()
        // Debounce rapid rotation events: coalesce for 450 ms, and never rebuild
        // more than once per 2 s (ScreenCaptureKit start/stop thrashing wedges the
        // capture daemon).
        let sinceLast = Clock.now() - lastDisplayRebuildTime
        let delay = max(0.45, 2.0 - sinceLast)
        let work = DispatchWorkItem { [weak self] in
            self?.processPendingDisplayChange()
        }
        displayDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        Log.info("display change received: " +
                 "\(message["width"] ?? "?")x\(message["height"] ?? "?") " +
                 "orientation=\(message["orientation"] ?? "?") " +
                 "hz=\(message["refreshRate"] ?? "?") — debounced \(String(format: "%.2fs", delay))")
    }

    private func processPendingDisplayChange() {
        guard let message = pendingDisplayMessage, sessionActive else { return }
        pendingDisplayMessage = nil
        let width = Int(InputInjector.doubleValue(message["width"]) ?? 0)
        let height = Int(InputInjector.doubleValue(message["height"]) ?? 0)
        let refresh = InputInjector.doubleValue(message["refreshRate"]) ?? 0
        let orientation = (message["orientation"] as? String)?.lowercased()
        if width > 0, height > 0 {
            tabletNativeLandscape = (max(width, height), min(width, height))
            tabletOrientation = orientation ?? (height > width ? "portrait" : "landscape")
        }
        var targetFPS = streamFPS
        if options.auto, refresh > 0 {
            targetFPS = min(options.fps, Int(max(24, min(240, refresh.rounded(.down)))))
        }
        let plan = desiredStreamPlan()
        lastDisplayRebuildTime = Clock.now()
        Log.info("applying display change: orientation=\(tabletOrientation) " +
                 "target=\(plan.pixelWidth)x\(plan.pixelHeight)@\(targetFPS)fps")
        reconfigureStream(plan: plan, fps: targetFPS) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.refreshLogicalSize()
                self.boundsBox.set(self.currentInputBounds())
            } else {
                Log.warn("display change reconfiguration failed; keeping current display")
            }
            self.broadcastConfig()
            self.encoder?.requestKeyframe()
            self.onPhaseChanged?(self.phase)
        }
    }

    /// Legacy name used by older code paths.
    private func adaptToTabletScreenLegacy() {}
}

// MARK: - Frame path

extension HostApp {
    /// Common path for captured and synthetic frames.
    func handleFrame(_ buffer: CVPixelBuffer, pts: CMTime) {
        guard phase == .running || phase == .starting else { return }
        let now = Clock.now()
        if lastFrameTime > 0 {
            let gap = now - lastFrameTime
            if gap > 2.0 && resumeLogged {
                Log.info(String(format: "capture resumed after a %.1fs gap", gap))
                resumeLogged = false
            }
        }
        lastFrameTime = now
        stats.recordCaptured()
        latency.noteFrameArrival(now)
        frameIndex += 1
        lastFrame = buffer
        lastFramePTS = pts
        if let encoder = encoder {
            let captureUs = Clock.epochMicroseconds()
            encoder.encode(buffer, pts: pts, captureTimestampUs: captureUs)
        }
        mjpegHub.submit(buffer)
        frameSaver?.submit(buffer, frameIndex: frameIndex)
    }
}

// MARK: - CaptureEngineDelegate

extension HostApp: CaptureEngineDelegate {
    func captureEngine(_ engine: CaptureEngine, didOutput buffer: CVPixelBuffer, pts: CMTime) {
        handleFrame(buffer, pts: pts)
    }

    func captureEngine(_ engine: CaptureEngine, didFail message: String, fatal: Bool) {
        Log.error("capture: \(message)")
        guard fatal else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.phase == .running, !self.options.synthetic else { return }
            let now = Clock.now()
            if now - self.lastCaptureRestartTime >= 8.0 {
                self.lastCaptureRestartTime = now
                self.capture.restartInBackground(reason: "SCStream stopped with error")
            } else {
                Log.warn("capture watchdog will retry shortly")
            }
        }
    }
}

// MARK: - LinkTransportDelegate

extension HostApp: LinkTransportDelegate {
    func transport(_ transport: LinkTransport, receivedHelloFor screen: [String: Any],
                   hello: [String: Any],
                   respond: @escaping (HLDPConfiguration) -> Void) {
        adaptToTabletScreen(screen, hello: hello, respond: respond)
    }

    func transport(_ transport: LinkTransport, didReceiveDisplay message: [String: Any]) {
        handleDisplayChange(message)
    }

    func transportDidBecomeReady(_ transport: LinkTransport) {
        Log.info("tablet link ready — streaming video now")
        encoder?.requestKeyframe()
        if let encoder = encoder, let lastFrame = lastFrame {
            encoder.encode(lastFrame, pts: lastFramePTS,
                           captureTimestampUs: Clock.epochMicroseconds(),
                           forceKeyframe: true)
        }
        broadcastConfig()
        onTransportReady?()
    }

    func transportDidClose(_ transport: LinkTransport, reason: String) {
        Log.warn("tablet link closed: \(reason)")
        onTransportLost?()
    }

    func transport(_ transport: LinkTransport, didReceiveControl message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "request_keyframe":
            Log.info("tablet requested a keyframe")
            encoder?.requestKeyframe()
        case "stats":
            let fps = InputInjector.doubleValue(message["rxFps"])
            let decode = InputInjector.doubleValue(message["decodeMs"])
            let rtt = InputInjector.doubleValue(message["rttMs"])
            stats.recordPeerStats(fps: fps, decodeMs: decode, rttMs: rtt)
            latency.recordTabletStats(message)
            if Log.verbose {
                func fmt(_ key: String) -> String {
                    guard let value = message[key] else { return "nil" }
                    return "\(value)"
                }
                Log.debug("peer stats raw: rxFps=\(fmt("rxFps")) decodeMs=\(fmt("decodeMs")) " +
                          "decMs=\(fmt("decMs")) recvMs=\(fmt("recvMs")) " +
                          "renderMs=\(fmt("renderMs")) e2eMs=\(fmt("e2eMs")) " +
                          "presentHz=\(fmt("presentHz")) rttMs=\(fmt("rttMs"))")
            }
            if let inputReported = message["input"] as? Bool {
                if tabletInputReported != inputReported {
                    tabletInputReported = inputReported
                    Log.info("tablet reports touch control \(inputReported ? "ON" : "OFF")")
                }
            }
        case "bye":
            Log.info("tablet sent bye")
        case "touch", "scroll", "key", "text", "mouse":
            inputInjector.handle(message)
        default:
            Log.debug("unhandled control message type=\(type)")
        }
    }

    func transport(_ transport: LinkTransport, didMeasureRTT milliseconds: Double) {
        stats.setRTT(milliseconds)
    }

    func transportRequestsKeyframe(_ transport: LinkTransport) {
        encoder?.requestKeyframe()
    }
}
