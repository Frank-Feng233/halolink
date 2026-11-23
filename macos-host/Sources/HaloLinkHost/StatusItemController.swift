//
//  StatusItemController.swift
//  HaloLink macOS host / app
//
//  Menu bar presence: show/hide the main window, start/stop the extended display,
//  reconnect and quit. Closing the window keeps the app alive here.
//

import AppKit
import Foundation

final class StatusItemController {
    private let engine: HostApp
    private weak var windowController: MainWindowController?
    weak var coordinator: ConnectionCoordinator?
    private let statusItem: NSStatusItem
    private let statusMenuItem = NSMenuItem(title: "状态：未连接", action: nil, keyEquivalent: "")
    private let showMenuItem = NSMenuItem(title: "显示主窗口", action: nil, keyEquivalent: "")
    private let startStopMenuItem = NSMenuItem(title: "开启扩展屏", action: nil, keyEquivalent: "")
    private let reconnectMenuItem = NSMenuItem(title: "重新连接", action: nil, keyEquivalent: "")
    private let quitMenuItem = NSMenuItem(title: "退出 HaloLink", action: nil, keyEquivalent: "q")
    private var timer: Timer?

    init(engine: HostApp, window: MainWindowController) {
        self.engine = engine
        self.windowController = window
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "display", accessibilityDescription: "HaloLink") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "HL"
            }
            button.toolTip = "HaloLink 扩展屏"
        }
        buildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        showMenuItem.target = self
        showMenuItem.action = #selector(showWindow)
        startStopMenuItem.target = self
        startStopMenuItem.action = #selector(toggleSession)
        reconnectMenuItem.target = self
        reconnectMenuItem.action = #selector(reconnect)
        quitMenuItem.target = self
        quitMenuItem.action = #selector(quit)
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(showMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(startStopMenuItem)
        menu.addItem(reconnectMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitMenuItem)
        statusItem.menu = menu
    }

    func refresh() {
        let status = engine.statusSnapshot()
        if status.transportReady {
            statusMenuItem.title = "状态：已连接（推流中）"
        } else if status.sessionActive {
            statusMenuItem.title = "状态：等待平板连接"
        } else {
            statusMenuItem.title = "状态：已停止"
        }
        startStopMenuItem.title = status.sessionActive ? "停止扩展屏" : "开启扩展屏"
        if let button = statusItem.button {
            button.appearsDisabled = !status.sessionActive
            button.toolTip = status.transportReady
                ? "HaloLink — 推流中 \(status.captureWidth)×\(status.captureHeight)"
                : "HaloLink — \(status.phase.text)"
        }
    }

    @objc private func showWindow() {
        windowController?.show()
    }

    @objc private func toggleSession() {
        if engine.statusSnapshot().sessionActive {
            engine.stopSession(reason: "menu bar stop")
        } else if let coordinator = coordinator {
            coordinator.reconnect()
        } else {
            _ = engine.startSession()
        }
        windowController?.refresh()
        refresh()
    }

    @objc private func reconnect() {
        if let coordinator = coordinator {
            coordinator.reconnect()
        } else {
            let endpoint = ConnectionCoordinator.savedEndpoint()
            engine.setEndpoint(endpoint)
            if engine.statusSnapshot().sessionActive {
                engine.restartTransport()
            } else {
                _ = engine.startSession()
            }
        }
        windowController?.refresh()
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
