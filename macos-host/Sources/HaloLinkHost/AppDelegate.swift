//
//  AppDelegate.swift
//  HaloLink macOS host / app
//
//  Application entry for the double-clickable HaloLink.app: creates the engine,
//  main window and menu bar item, then runs the connection sequence for the
//  selected connection method (自动 / USB 有线 / 无线).
//

import AppKit
import Foundation

// MARK: - Connection method / channel

enum ConnectionMethod: String, CaseIterable {
    case auto
    case usb
    case wifi

    var title: String {
        switch self {
        case .auto: return "自动"
        case .usb: return "USB 有线"
        case .wifi: return "无线"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "自动：优先 USB 直连平板；没有 USB 时使用上次成功的无线地址。"
        case .usb:
            return "USB 有线：只使用 hdc 找 USB 设备并转发端口；没有设备时报告错误，不自动退回无线。"
        case .wifi:
            return "无线：直接连接下方地址（需平板与 Mac 在同一 Wi-Fi，且平板已打开 HaloLink App）。"
        }
    }
}

enum ConnectionChannel {
    case none
    case usb(Endpoint)
    case wifi(Endpoint)

    var isUSB: Bool {
        if case .usb = self { return true }
        return false
    }

    var endpoint: Endpoint? {
        switch self {
        case .none: return nil
        case .usb(let endpoint): return endpoint
        case .wifi(let endpoint): return endpoint
        }
    }

    var transportName: String {
        switch self {
        case .none: return ""
        case .usb: return "USB 有线"
        case .wifi: return "无线"
        }
    }
}

// MARK: - Connection coordinator

final class ConnectionCoordinator {
    static let methodDefaultsKey = "halolink.connectionMethod"
    static let renderModeDefaultsKey = "halolink.renderMode"
    static let hostDefaultsKey = "halolink.lastHost"
    static let portDefaultsKey = "halolink.lastPort"
    static let defaultHost = "192.168.1.10"
    static let defaultPort: UInt16 = 9528

    private let engine: HostApp
    private weak var window: MainWindowController?
    private let queue = DispatchQueue(label: "com.halolink.connection", qos: .userInitiated)
    private var started = false

    private(set) var method: ConnectionMethod
    private(set) var channel: ConnectionChannel = .none
    private(set) var lastError: String?

    init(engine: HostApp) {
        self.engine = engine
        let saved = UserDefaults.standard.string(forKey: Self.methodDefaultsKey) ?? ""
        self.method = ConnectionMethod(rawValue: saved) ?? .auto
    }

    func attach(window: MainWindowController) {
        self.window = window
        window.setConnectionMethod(method)
        window.setConnectionHint(method.detail)
    }

    // MARK: persisted address

    static func savedEndpoint() -> Endpoint {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: hostDefaultsKey) ?? defaultHost
        let port = defaults.object(forKey: portDefaultsKey) as? Int ?? Int(defaultPort)
        return Endpoint(host: host, port: UInt16(clamping: port))
    }

    static func saveEndpoint(_ endpoint: Endpoint) {
        let defaults = UserDefaults.standard
        defaults.set(endpoint.host, forKey: hostDefaultsKey)
        defaults.set(Int(endpoint.port), forKey: portDefaultsKey)
    }

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        window?.setConnectionMethod(method)
        window?.setConnectionHint(method.detail)
        window?.updateEndpointField(Self.savedEndpoint())
        if ProcessInfo.processInfo.environment["HALOLINK_UI_ONLY"] == "1" {
            Log.info("HALOLINK_UI_ONLY=1: GUI preview only — streaming session not started")
            window?.setStatusMessage("UI 预览模式（未启动推流）")
            return
        }
        // Start immediately with the selected method. The session itself (virtual
        // display + web + capture) is started by apply()/ensureSession().
        apply(method, userInitiated: false)
    }

    func setMethod(_ newMethod: ConnectionMethod, userInitiated: Bool = true) {
        method = newMethod
        UserDefaults.standard.set(newMethod.rawValue, forKey: Self.methodDefaultsKey)
        Log.info("connection method -> \(newMethod.title)")
        window?.setConnectionMethod(newMethod)
        window?.setConnectionHint(newMethod.detail)
        apply(newMethod, userInitiated: userInitiated)
    }

    func reconnect() {
        apply(method, userInitiated: true)
    }

    func useAddress(_ endpoint: Endpoint) {
        Self.saveEndpoint(endpoint)
        window?.updateEndpointField(endpoint)
        if method == .usb {
            // Typing a Wi-Fi address implies wireless mode.
            setMethod(.wifi)
        } else {
            apply(method, userInitiated: true)
        }
    }

    /// Called by the engine when the tablet handshake succeeded.
    func noteTransportReady() {
        let target = engine.statusSnapshot().transportTarget
        if let endpoint = Endpoint.parse(target) {
            channel = Self.classify(endpoint)
            lastError = nil
            Self.saveEndpoint(endpoint)
            window?.updateEndpointField(endpoint)
            Log.info("tablet link ready via \(channel.transportName) (\(endpoint.description))")
        }
        refresh()
    }

    func noteTransportLost() {
        refresh()
    }

    // MARK: applying the method

    private func apply(_ selected: ConnectionMethod, userInitiated: Bool) {
        lastError = nil
        window?.setStatusMessage(nil)
        switch selected {
        case .wifi:
            connectWiFi()
        case .usb:
            connectUSB()
        case .auto:
            connectAuto()
        }
        refresh()
    }

    private func ensureSession() {
        if !engine.statusSnapshot().sessionActive {
            _ = engine.startSession()
        }
    }

    private func connectWiFi() {
        let endpoint = Self.savedEndpoint()
        channel = .wifi(endpoint)
        window?.updateEndpointField(endpoint)
        engine.setEndpoint(endpoint)
        ensureSession()
        window?.setStatusMessage(nil)
        refresh()
    }

    private func connectUSB() {
        // Never silently keep an existing Wi-Fi link when the user selected USB.
        engine.stopTransport()
        channel = .none
        window?.setConnectionHint("正在检测 USB 设备（hdc list targets -v）…")
        refresh()
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = HDCBridge.prepareUSBConnectionDetailed()
            DispatchQueue.main.async {
                switch result {
                case .success(let endpoint):
                    self.channel = .usb(endpoint)
                    self.lastError = nil
                    Self.saveEndpoint(endpoint)
                    self.window?.updateEndpointField(endpoint)
                    self.window?.setStatusMessage(nil)
                    self.window?.setConnectionHint(ConnectionMethod.usb.detail)
                    self.engine.setEndpoint(endpoint)
                    self.ensureSession()
                case .noDevice(let message):
                    self.handleUSBFailure(message)
                case .forwardFailed(let message):
                    self.handleUSBFailure(message)
                }
                self.refresh()
            }
        }
    }

    private func handleUSBFailure(_ message: String) {
        channel = .none
        lastError = message
        window?.setConnectionHint(ConnectionMethod.usb.detail)
        window?.setStatusMessage("USB 连接失败：\(message)（未自动退回无线；请插好数据线/" +
                                 "允许 USB 调试后点“重新连接”）")
        Log.error("USB connection mode failed: \(message)")
    }

    private func connectAuto() {
        let endpoint = Self.savedEndpoint()
        channel = .wifi(endpoint)
        window?.updateEndpointField(endpoint)
        engine.setEndpoint(endpoint)
        ensureSession()
        window?.setStatusMessage(nil)
        refresh()
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let usbEndpoint = HDCBridge.prepareUSBConnection() else { return }
            DispatchQueue.main.async {
                Log.info("auto: switched to USB connection \(usbEndpoint.description)")
                self.channel = .usb(usbEndpoint)
                self.lastError = nil
                Self.saveEndpoint(usbEndpoint)
                self.window?.updateEndpointField(usbEndpoint)
                self.window?.setStatusMessage(nil)
                self.engine.setEndpoint(usbEndpoint)
                self.ensureSession()
                self.refresh()
            }
        }
    }

    // MARK: helpers

    static func classify(_ endpoint: Endpoint) -> ConnectionChannel {
        let host = endpoint.host.lowercased()
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return .usb(endpoint)
        }
        return .wifi(endpoint)
    }

    /// True when the engine's transport target looks like the USB/loopback channel.
    static func isLoopbackTarget(_ target: String) -> Bool {
        guard let endpoint = Endpoint.parse(target) else { return false }
        return classify(endpoint).isUSB
    }

    private func refresh() {
        window?.refresh()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private var engine: HostApp!
    private var windowController: MainWindowController!
    private var statusItem: StatusItemController!
    private var coordinator: ConnectionCoordinator!

    init(options: Options) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Log.enableFileLogging()
        Log.info("HaloLink app launching (GUI mode)")
        Log.info("bundle: \(Bundle.main.bundlePath)")
        Log.info("app identity: \(InputInjector.appName)")

        var uiOptions = options
        uiOptions.gui = true
        // Restore the render mode chosen in the UI (used across relaunches too).
        if let saved = UserDefaults.standard.string(forKey: ConnectionCoordinator.renderModeDefaultsKey),
           let mode = RenderMode(rawValue: saved) {
            uiOptions.renderMode = mode
        }
        engine = HostApp(options: uiOptions, guiMode: true)
        engine.onRenderModeRequiresRelaunch = { [weak self] mode in
            guard let self = self else { return }
            Log.info("relaunching app for render mode \(mode.rawValue)")
            UserDefaults.standard.set(mode.rawValue,
                                      forKey: ConnectionCoordinator.renderModeDefaultsKey)
            self.relaunchApp()
            NSApp.terminate(nil)
        }

        windowController = MainWindowController(engine: engine)
        statusItem = StatusItemController(engine: engine, window: windowController)
        coordinator = ConnectionCoordinator(engine: engine)
        coordinator.attach(window: windowController)
        windowController.coordinator = coordinator
        statusItem.coordinator = coordinator

        engine.onPhaseChanged = { [weak self] phase in
            guard let self = self else { return }
            self.windowController.refresh()
            self.statusItem.refresh()
            if case .failed(let message) = phase {
                Log.error("engine phase failed: \(message)")
            }
        }
        engine.onTransportReady = { [weak self] in
            guard let self = self else { return }
            self.coordinator.noteTransportReady()
            self.statusItem.refresh()
        }
        engine.onTransportLost = { [weak self] in
            self?.coordinator.noteTransportLost()
            self?.statusItem.refresh()
        }

        guard engine.acquireGlobalResources() else {
            let alert = NSAlert()
            alert.messageText = "HaloLink 已在运行"
            alert.informativeText = "已经有一个 HaloLink 实例在运行，请在菜单栏中找到它。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        engine.installSignalHandlers(appTerminate: true)
        windowController.show()
        statusItem.refresh()
        // Defer session start until the run loop is actually running: WindowServer
        // needs event-loop iterations to finish registering the virtual display.
        DispatchQueue.main.async { [weak self] in
            self?.coordinator.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running in the menu bar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        windowController?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("application terminating")
        engine?.quit(exitCode: 0, reason: "app quit")
    }

    /// Spawns a detached copy of ourselves after this process exits (used for the
    /// 1x -> 2x render-mode switch, which needs a fresh CGVirtualDisplay).
    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let script = "sleep 1.2; open -n \"\(bundlePath)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            Log.error("relaunch failed: \(error.localizedDescription)")
        }
    }
}
