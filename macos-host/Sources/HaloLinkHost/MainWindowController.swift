//
//  MainWindowController.swift
//  HaloLink macOS host / app
//
//  Programmatic AppKit main window (dark, simple):
//   * status rows (state / channel / resolution / scale / orientation / fps / latency / touch)
//   * start-stop / reconnect / quit
//   * connection method: 自动 / USB 有线 / 无线 (persisted)
//   * display mode: 完整显示（可能留黑边） / 裁剪填满（无黑边，可能裁掉边缘）
//   * virtual display size: 贴合平板 (2800x1848@2x) / 贴合 Mac 内置屏 (2940x1912@2x)
//     with a live explanation line + smart suggestion
//   * touch control switch (default off, v1.1)
//   * manual Wi-Fi address field
//

import AppKit
import Foundation

final class MainWindowController: NSWindowController {
    private let engine: HostApp
    weak var coordinator: ConnectionCoordinator?

    // Status labels
    private let statusLabel = MainWindowController.valueLabel()
    private let connectionLabel = MainWindowController.valueLabel()
    private let resolutionLabel = MainWindowController.valueLabel()
    private let scaleLabel = MainWindowController.valueLabel()
    private let orientationLabel = MainWindowController.valueLabel()
    private let rateLabel = MainWindowController.valueLabel()
    private let latencyLabel = MainWindowController.valueLabel()
    private let touchLabel = MainWindowController.valueLabel()

    // Buttons
    private let startStopButton = NSButton(title: "开启扩展屏", target: nil, action: nil)
    private let reconnectButton = NSButton(title: "重新连接", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)

    // Connection method
    private let methodControl = NSSegmentedControl(labels: ConnectionMethod.allCases.map(\.title),
                                                   trackingMode: .selectOne,
                                                   target: nil, action: nil)
    private let connectionHintLabel = NSTextField(labelWithString: "")
    private let statusMessageLabel = NSTextField(labelWithString: "")

    // Display mode
    private let scaleModeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scaleModeOptions: [(title: String, mode: ScaleModeOption)] = [
        ("完整显示（可能留黑边）—— 等比缩放，画面完整", .fit),
        ("裁剪填满（无黑边，可能裁掉边缘）—— 等比放大后裁切", .fill)
    ]
    private let scaleModeNote = NSTextField(labelWithString:
        "该选项只影响平板端画面缩放方式，不影响虚拟屏分辨率。")

    // Virtual display render mode (HLDP v1.3)
    private let nativeRadio = NSButton(radioButtonWithTitle:
        "原生 1:1 像素：2800×1840（1x，无缩放，最清晰像素映射）", target: nil, action: nil)
    private let hidpiRadio = NSButton(radioButtonWithTitle:
        "HiDPI 最大化：2800×1840 @2x（逻辑 1400×920，推荐）", target: nil, action: nil)
    private let renderExplanationLabel = NSTextField(labelWithString: "实际达成 —")
    private let renderSuggestionLabel = NSTextField(labelWithString: "")

    // Touch
    private let touchControl = NSSegmentedControl(labels: ["触摸控制：关（默认）", "触摸控制：开"],
                                                  trackingMode: .selectOne,
                                                  target: nil, action: nil)

    // Wi-Fi address
    private let endpointField = NSTextField(string: "")
    private let connectButton = NSButton(title: "连接此地址", target: nil, action: nil)
    private let addressHintLabel = NSTextField(labelWithString:
        "无线模式使用此地址；USB 有线模式会忽略它（自动用 127.0.0.1:19528）。")

    private let permissionButton = NSButton(title: "打开权限设置", target: nil, action: nil)

    private var refreshTimer: Timer?
    private var didPromptPermission = false

    init(engine: HostApp) {
        self.engine = engine
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "HaloLink"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.10, alpha: 1)
        window.minSize = NSSize(width: 680, height: 600)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            self?.refresh()
        }
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - UI construction

    private static func valueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "—")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(calibratedRed: 0.65, green: 0.95, blue: 0.85, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        return label
    }

    private static func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        label.preferredMaxLayoutWidth = MainWindowController.contentWidth
        return label
    }

    private func row(_ title: String, _ value: NSTextField) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true
        let stack = NSStackView(views: [titleLabel, value])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        stack.distribution = .fill
        return stack
    }

    private static let contentWidth: CGFloat = 640

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return box
    }

    private func buildUI() {
        guard let window = window else { return }

        let title = NSTextField(labelWithString: "HaloLink 扩展屏")
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.42, green: 0.95, blue: 0.86, alpha: 1)
        let subtitle = NSTextField(labelWithString: "把鸿蒙平板变成 Mac 的第二块显示器 · HLDP v1.3")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)

        // --- status ---
        let statusBox = NSStackView(views: [
            row("状态", statusLabel),
            row("连接", connectionLabel),
            row("分辨率", resolutionLabel),
            row("缩放", scaleLabel),
            row("方向", orientationLabel),
            row("帧率/码率", rateLabel),
            row("延迟", latencyLabel),
            row("触摸控制", touchLabel)
        ])
        statusBox.orientation = .vertical
        statusBox.spacing = 5
        statusBox.alignment = .leading

        // --- buttons ---
        for button in [startStopButton, reconnectButton, quitButton] {
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.target = self
        }
        startStopButton.action = #selector(toggleSession)
        reconnectButton.action = #selector(reconnect)
        quitButton.action = #selector(quit)
        let buttons = NSStackView(views: [startStopButton, reconnectButton, quitButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        // --- connection method ---
        methodControl.target = self
        methodControl.action = #selector(methodChanged)
        methodControl.segmentStyle = .rounded
        methodControl.font = NSFont.systemFont(ofSize: 11)
        methodControl.setWidth(90, forSegment: 0)
        methodControl.setWidth(110, forSegment: 1)
        methodControl.setWidth(90, forSegment: 2)
        connectionHintLabel.font = NSFont.systemFont(ofSize: 11)
        connectionHintLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        connectionHintLabel.lineBreakMode = .byWordWrapping
        connectionHintLabel.maximumNumberOfLines = 3
        connectionHintLabel.preferredMaxLayoutWidth = 660
        statusMessageLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusMessageLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.35, alpha: 1)
        statusMessageLabel.lineBreakMode = .byWordWrapping
        statusMessageLabel.maximumNumberOfLines = 3
        statusMessageLabel.preferredMaxLayoutWidth = 660
        statusMessageLabel.stringValue = ""

        // --- display mode ---
        scaleModeControl.target = self
        scaleModeControl.action = #selector(scaleModeChanged)
        scaleModeControl.font = NSFont.systemFont(ofSize: 12)
        scaleModeControl.removeAllItems()
        for option in scaleModeOptions {
            scaleModeControl.addItem(withTitle: option.title)
        }
        scaleModeControl.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        scaleModeNote.font = NSFont.systemFont(ofSize: 11)
        scaleModeNote.textColor = NSColor(calibratedWhite: 0.58, alpha: 1)

        // --- virtual display render mode (radio buttons with full explanation) ---
        for radio in [nativeRadio, hidpiRadio] {
            radio.target = self
            radio.action = #selector(renderModeChanged)
            radio.font = NSFont.systemFont(ofSize: 12)
        }
        nativeRadio.tag = 0
        hidpiRadio.tag = 1
        let nativeNote = MainWindowController.noteLabel(
            "1:1：平板逐像素显示，不缩放/不重采样，没有黑边；文字与 UI 会明显变小。")
        let hidpiNote = MainWindowController.noteLabel(
            "HiDPI：macOS 按 2x 渲染、平板端裁切少量边缘（通常 0–8 px），UI 大小舒适。")
        renderExplanationLabel.font = NSFont.systemFont(ofSize: 11)
        renderExplanationLabel.textColor = NSColor(calibratedRed: 0.55, green: 0.85,
                                                   blue: 0.95, alpha: 1)
        renderExplanationLabel.lineBreakMode = .byWordWrapping
        renderExplanationLabel.maximumNumberOfLines = 2
        renderExplanationLabel.preferredMaxLayoutWidth = Self.contentWidth
        renderSuggestionLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        renderSuggestionLabel.textColor = NSColor(calibratedRed: 0.98, green: 0.78,
                                                  blue: 0.32, alpha: 1)
        renderSuggestionLabel.lineBreakMode = .byWordWrapping
        renderSuggestionLabel.maximumNumberOfLines = 2
        renderSuggestionLabel.preferredMaxLayoutWidth = Self.contentWidth
        renderSuggestionLabel.stringValue = ""
        let sizingBox = NSStackView(views: [nativeRadio, nativeNote, hidpiRadio, hidpiNote,
                                            renderExplanationLabel, renderSuggestionLabel])
        sizingBox.orientation = .vertical
        sizingBox.spacing = 5
        sizingBox.alignment = .leading

        // --- touch ---
        touchControl.target = self
        touchControl.action = #selector(touchChanged)
        touchControl.font = NSFont.systemFont(ofSize: 11)
        touchControl.segmentStyle = .rounded

        // --- Wi-Fi address ---
        endpointField.placeholderString = "192.168.1.10:9528"
        endpointField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        endpointField.widthAnchor.constraint(equalToConstant: 190).isActive = true
        endpointField.target = self
        endpointField.action = #selector(connectToAddress)
        connectButton.target = self
        connectButton.action = #selector(connectToAddress)
        connectButton.bezelStyle = .rounded
        addressHintLabel.font = NSFont.systemFont(ofSize: 11)
        addressHintLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        addressHintLabel.lineBreakMode = .byWordWrapping
        addressHintLabel.maximumNumberOfLines = 2
        addressHintLabel.preferredMaxLayoutWidth = 660

        permissionButton.target = self
        permissionButton.action = #selector(openPermissions)
        permissionButton.bezelStyle = .rounded
        permissionButton.font = NSFont.systemFont(ofSize: 11)
        permissionButton.isHidden = true

        let addressRow = NSStackView(views: [endpointField, connectButton])
        addressRow.orientation = .horizontal
        addressRow.spacing = 8

        let stack = NSStackView(views: [
            title, subtitle,
            separator(),
            statusBox,
            separator(),
            buttons,
            separator(),
            MainWindowController.sectionTitle("连接方式"),
            methodControl, connectionHintLabel, statusMessageLabel,
            separator(),
            MainWindowController.sectionTitle("显示模式（平板端）"),
            scaleModeControl, scaleModeNote,
            separator(),
            MainWindowController.sectionTitle("虚拟屏渲染模式（HLDP v1.3）"),
            sizingBox,
            separator(),
            MainWindowController.sectionTitle("触摸控制"),
            touchControl,
            separator(),
            MainWindowController.sectionTitle("无线地址（IP:端口）"),
            addressRow,
            addressHintLabel,
            permissionButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth + 44).isActive = true

        // Scroll view so the richer UI fits on smaller screens.
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        let contentView = NSView()
        window.contentView = contentView
        contentView.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    // MARK: - Public API

    func show() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setConnectionMethod(_ method: ConnectionMethod) {
        if let index = ConnectionMethod.allCases.firstIndex(of: method) {
            methodControl.selectedSegment = index
        }
    }

    func updateEndpointField(_ endpoint: Endpoint) {
        endpointField.stringValue = endpoint.description
    }

    func setConnectionHint(_ text: String?) {
        connectionHintLabel.stringValue = text ?? ""
    }

    func setStatusMessage(_ text: String?) {
        statusMessageLabel.stringValue = text ?? ""
        statusMessageLabel.isHidden = (text ?? "").isEmpty
    }

    func refresh() {
        let status = engine.statusSnapshot()
        let channel = coordinator?.channel ?? .none

        // --- state ---
        statusLabel.stringValue = status.phase.text +
            (status.sessionActive && status.phase == .running ? " ●" : "")
        if case .failed = status.phase {
            statusLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1)
        } else {
            statusLabel.textColor = NSColor(calibratedRed: 0.65, green: 0.95, blue: 0.85, alpha: 1)
        }

        // --- channel ---
        let target = status.transportTarget
        let channelName: String
        if channel.isUSB {
            channelName = "USB 有线"
        } else if !target.isEmpty {
            channelName = "无线"
        } else if status.sessionActive {
            channelName = "仅 Web 浏览器"
        } else {
            channelName = "—"
        }
        if status.transportReady {
            connectionLabel.stringValue = "已连接 · \(channelName)" +
                (target.isEmpty ? "" : " (\(target))") + "（推流中）"
        } else if !target.isEmpty {
            connectionLabel.stringValue = "未连接 · \(channelName) (\(target))"
        } else if status.sessionActive {
            connectionLabel.stringValue = "未连接 · 仅 Web 浏览器模式"
        } else {
            connectionLabel.stringValue = "未启动"
        }

        // --- resolution / scale / orientation / rates / touch ---
        resolutionLabel.stringValue = status.captureWidth > 0
            ? "\(status.captureWidth)×\(status.captureHeight) px" +
              (status.retina ? "（2x HiDPI）" : "（1x）")
            : "—"
        switch status.renderMode {
        case .pixel1to1:
            scaleLabel.stringValue = status.captureWidth > 0
                ? "原生 1:1（1x）· \(status.captureWidth)×\(status.captureHeight) px"
                : "原生 1:1（1x）"
        case .hidpiScale:
            let scaleText = status.scaleMode == .fit ? "完整显示" : "裁剪填满"
            scaleLabel.stringValue = status.captureWidth > 0
                ? "HiDPI 2x · 逻辑 \(status.logicalWidth)×\(status.logicalHeight) pt · \(scaleText)"
                : "HiDPI 2x · \(scaleText)"
        case .matchMain:
            scaleLabel.stringValue = "贴合 Mac 内置屏（高级 CLI）"
        }
        orientationLabel.stringValue = status.orientation == "portrait" ? "竖屏" : "横屏"
        rateLabel.stringValue = status.sessionActive
            ? String(format: "%.1f fps · %.0f kbps", status.encodeFps, status.kbps)
            : "—"
        latencyLabel.stringValue = status.sessionActive
            ? String(format: "rtt %.1f ms · 采集 %.1f fps", status.rttMs, status.captureFps)
            : "—"
        var touchText = status.inputEnabled ? "开" : "关（默认）"
        if let reported = status.tabletInputReported {
            touchText += reported ? " · 平板：开" : " · 平板：关"
        }
        touchLabel.stringValue = touchText

        // --- controls ---
        startStopButton.title = status.sessionActive ? "停止" : "开启扩展屏"
        touchControl.selectedSegment = engine.options.inputEnabled ? 1 : 0
        if let index = scaleModeOptions.firstIndex(where: { $0.mode == engine.options.scaleMode }) {
            scaleModeControl.selectItem(at: index)
        }
        scaleModeControl.isEnabled = engine.options.renderMode == .hidpiScale
        nativeRadio.state = engine.options.renderMode == .pixel1to1 ? .on : .off
        hidpiRadio.state = engine.options.renderMode == .hidpiScale ? .on : .off
        let panelW = status.tabletPanelWidth > 0 ? status.tabletPanelWidth : 2800
        let panelH = status.tabletPanelHeight > 0 ? status.tabletPanelHeight : 1840
        nativeRadio.title = "原生 1:1 像素：\(panelW)×\(panelH)（1x，无缩放，最清晰像素映射）"
        if status.renderMode == .hidpiScale && status.captureWidth > 0 {
            hidpiRadio.title = "HiDPI 最大化：\(status.captureWidth)×\(status.captureHeight) @2x" +
                "（逻辑 \(status.logicalWidth)×\(status.logicalHeight)，推荐）"
        } else {
            hidpiRadio.title = "HiDPI 最大化：\(panelW)×\(panelH) @2x（逻辑 " +
                "\(panelW / 2)×\(panelH / 2)，推荐）"
        }

        // --- live explanation: actual achieved virtual display vs tablet panel ---
        if status.captureWidth > 0 {
            let retina = status.retina ? "2x" : "1x"
            let modeName = status.renderMode == .pixel1to1 ? "原生 1:1" : "HiDPI 最大化"
            var text = "实际达成：\(modeName) · \(status.captureWidth)×\(status.captureHeight) px = " +
                "\(status.logicalWidth)×\(status.logicalHeight) pt (\(retina))"
            if status.tabletPanelWidth > 0 {
                text += " · 平板面板 \(status.tabletPanelWidth)×\(status.tabletPanelHeight)"
                let extraW = status.captureWidth - status.tabletPanelWidth
                let extraH = status.captureHeight - status.tabletPanelHeight
                if extraW == 0 && extraH == 0 {
                    text += " · 完全一致（无裁切）"
                } else if extraW > 0 || extraH > 0 {
                    text += " · 相对面板多 \(max(0, extraW))×\(max(0, extraH)) px（平板端裁切）"
                } else {
                    text += " · 比面板少 \(max(0, -extraW))×\(max(0, -extraH)) px（平板端补边）"
                }
            }
            renderExplanationLabel.stringValue = text
        } else {
            renderExplanationLabel.stringValue = "实际达成 —（点“开启扩展屏”后显示）"
        }

        // --- smart suggestion (never changes settings automatically) ---
        var suggestion = ""
        if engine.options.renderMode == .pixel1to1 {
            suggestion = "1:1 模式下平板逐像素显示，上方“显示模式（fit/fill）”不影响画面。"
        } else if engine.options.scaleMode == .fit {
            suggestion = "提示：HiDPI 模式建议把显示模式切到「裁剪填满」，平板端裁掉少量边缘即可无黑边铺满。"
        } else {
            suggestion = "提示：如想保留完整画面边缘，可把显示模式切回「完整显示（可能留黑边）」。"
        }
        renderSuggestionLabel.stringValue = suggestion
        renderSuggestionLabel.isHidden = suggestion.isEmpty

        if case .failed = status.phase {
            permissionButton.isHidden = false
        } else {
            permissionButton.isHidden = true
        }
        if case .failed(let message) = status.phase, message.contains("权限"),
           !didPromptPermission {
            didPromptPermission = true
            showPermissionAlert(message)
        }
    }

    private func showPermissionAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "HaloLink 需要权限"
        alert.informativeText = message + "\n\n请在「系统设置 → 隐私与安全性」中允许 HaloLink 的" +
            "「屏幕录制」（采集扩展屏）和「辅助功能」（触摸回传），然后重新点击“开启扩展屏”。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = HostApp.ensureScreenRecordingPermission()
        }
    }

    // MARK: - Actions

    @objc private func toggleSession() {
        let status = engine.statusSnapshot()
        if status.sessionActive {
            engine.stopSession(reason: "user pressed stop")
            refresh()
            return
        }
        if !HostApp.screenRecordingGranted() {
            _ = HostApp.ensureScreenRecordingPermission()
        }
        coordinator?.reconnect()
        refresh()
    }

    @objc private func reconnect() {
        coordinator?.reconnect()
        refresh()
    }

    @objc private func methodChanged() {
        let index = methodControl.selectedSegment
        guard index >= 0, index < ConnectionMethod.allCases.count else { return }
        coordinator?.setMethod(ConnectionMethod.allCases[index])
        refresh()
    }

    @objc private func connectToAddress() {
        guard let endpoint = Endpoint.parse(endpointField.stringValue) else {
            setStatusMessage("地址格式无效，请填写 host:port，例如 192.168.1.10:9528")
            return
        }
        setStatusMessage(nil)
        coordinator?.useAddress(endpoint)
        refresh()
    }

    @objc private func scaleModeChanged() {
        let index = scaleModeControl.indexOfSelectedItem
        let mode = (index >= 0 && index < scaleModeOptions.count) ? scaleModeOptions[index].mode : .fit
        engine.setScaleMode(mode)
        refresh()
    }

    @objc private func renderModeChanged() {
        let mode: RenderMode = nativeRadio.state == .on ? .pixel1to1 : .hidpiScale
        engine.setRenderMode(mode)
        refresh()
    }

    @objc private func touchChanged() {
        engine.setInputEnabled(touchControl.selectedSegment == 1)
        refresh()
    }

    @objc private func openPermissions() {
        _ = HostApp.ensureScreenRecordingPermission()
        InputInjector.openAccessibilitySettingsPane()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window must not quit the app: it keeps running in the menu bar.
        sender.orderOut(nil)
        return false
    }
}
