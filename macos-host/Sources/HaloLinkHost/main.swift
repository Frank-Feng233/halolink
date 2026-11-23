//
//  main.swift
//  HaloLink macOS host
//
//  Entry point. Parses the CLI, then either performs a one-shot utility action
//  (--help / --list-displays / --version) or runs the host.
//

import AppKit
import Foundation

let options = Options.parse(CommandLine.arguments)

if options.showHelp {
    print(Options.usage)
    exit(0)
}

if options.listDisplays {
    VirtualDisplay.listDisplays()
    exit(0)
}

if options.hdcProbe {
    if let executable = HDCBridge.locateExecutable() {
        print("hdc: \(executable)")
    } else {
        print("hdc: not found")
    }
    let targets = HDCBridge.listTargets()
    if targets.isEmpty {
        print("targets: none")
    } else {
        for target in targets {
            print("target: serial=\(target.serial) transport=\(target.transport) " +
                  "state=\(target.state) usb=\(target.isUSB)")
        }
    }
    print("usb_auto_connect: \(HDCBridge.firstUSBTarget() != nil ? "available" : "unavailable")")
    if ProcessInfo.processInfo.environment["HALOLINK_HDC_PREPARE"] == "1" {
        if let endpoint = HDCBridge.prepareUSBConnection() {
            print("prepareUSBConnection: \(endpoint.description)")
        } else {
            print("prepareUSBConnection: failed (no USB target or fport failed)")
        }
    }
    exit(0)
}

// Decide between GUI and CLI:
//  * double-clicking HaloLink.app passes no arguments -> GUI
//  * any CLI flag (or --gui / HALOLINK_GUI=1) -> CLI unless GUI requested
let filteredArguments = CommandLine.arguments.dropFirst().filter {
    !$0.hasPrefix("-psn_")
}
let bundleIsApp = Bundle.main.bundlePath.hasSuffix(".app")
let envWantsGUI = ProcessInfo.processInfo.environment["HALOLINK_GUI"] == "1"
let wantsGUI = options.gui || envWantsGUI || (bundleIsApp && filteredArguments.isEmpty)

if wantsGUI {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AppDelegate(options: options)
    application.delegate = delegate
    application.run()
    exit(0)
} else {
    let host = HostApp(options: options, guiMode: false)
    host.runCLI()
}
