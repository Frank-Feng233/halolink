//
//  HDCBridge.swift
//  HaloLink macOS host / app
//
//  Thin wrapper around Huawei's `hdc` tool (HarmonyOS Device Connector) used by
//  the double-clickable app to find a USB-attached tablet, launch the tablet app
//  and forward the app's TCP port to localhost:
//
//      hdc list targets -v         -> "SERIAL  USB  Connected"
//      hdc -t SERIAL shell aa start -a EntryAbility -b com.halolink.display
//      hdc -t SERIAL fport tcp:19528 tcp:9528
//      -> the host then connects to 127.0.0.1:19528
//
//  The hdc binary (and its dylibs) is bundled in HaloLink.app/Contents/Resources/bin
//  by scripts/make_app.sh when a HarmonyOS Command Line Tools installation is
//  found; otherwise common CLT/DevEco/PATH locations are probed.
//

import Foundation

struct HDCTarget {
    let serial: String
    let transport: String   // "USB" or "TCP"
    let state: String

    var isUSB: Bool { transport.uppercased() == "USB" }
}

enum HDCBridge {
    /// HarmonyOS app identity (kept in sync with harmony-app/AppScope/app.json5 and
    /// entry/src/main/module.json5).
    static let appBundleName = "com.halolink.display"
    static let abilityName = "EntryAbility"
    /// Local port the host connects to after `hdc fport`.
    static let forwardedLocalPort: UInt16 = 19528
    /// Port the tablet app listens on.
    static let tabletServerPort: UInt16 = 9528

    // MARK: - Binary discovery

    private static var cachedExecutable: String?

    /// Finds the hdc executable: bundle copy first, then env override, PATH, and
    /// common HarmonyOS Command Line Tools / DevEco Studio install locations.
    static func locateExecutable() -> String? {
        // Explicit kill switch for tests / when the user does not want USB support.
        if let override = ProcessInfo.processInfo.environment["HALOLINK_HDC"],
           ["off", "none", "0", "disabled"].contains(override.lowercased()) {
            return nil
        }
        if let cached = cachedExecutable, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        var candidates: [String] = []

        // 1) Explicit override (also used by tests to redirect to a stub hdc).
        if let override = ProcessInfo.processInfo.environment["HALOLINK_HDC"],
           !override.isEmpty {
            candidates.append(override)
        }
        // 2) Bundled with the app (Contents/Resources/bin/hdc) — normal choice.
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("bin/hdc").path)
            candidates.append(resourceURL.appendingPathComponent("bin/hdc_std").path)
        }
        // 3) PATH.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append(String(directory) + "/hdc")
            }
        }
        // 4) Common install locations (globbed below where needed).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "/Library/Developer/CommandLineTools/sdk/default/openharmony/toolchains/hdc",
            "/Library/Developer/CommandLineTools/sdk/default/hms/toolchains/hdc",
            "\(home)/Library/Huawei/Sdk/default/openharmony/toolchains/hdc",
            "\(home)/Library/OpenHarmony/Sdk/default/openharmony/toolchains/hdc",
            "\(home)/command-line-tools/sdk/default/openharmony/toolchains/hdc",
            "\(home)/Downloads/command-line-tools/sdk/default/openharmony/toolchains/hdc",
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
            "/Applications/DevEco-Studio.app/Contents/tools/hdc",
            "\(home)/harmony/huawei/hdc",
            "/opt/homebrew/bin/hdc",
            "/usr/local/bin/hdc"
        ])
        // HarmonyOS SDK unpacked manually (e.g. ~/harmony/huawei/hdc).
        if let harmonyChildren = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/harmony") {
            for child in harmonyChildren {
                candidates.append("\(home)/harmony/\(child)/hdc")
                candidates.append("\(home)/harmony/\(child)/toolchains/hdc")
            }
        }
        // 5) Glob a few SDK roots for any versioned toolchains directory.
        for root in ["\(home)/Library/Huawei/Sdk", "\(home)/Library/OpenHarmony/Sdk",
                     "\(home)/command-line-tools/sdk",
                     "/Library/Developer/CommandLineTools/sdk/default"] {
            if let children = try? FileManager.default.contentsOfDirectory(atPath: root) {
                for child in children {
                    candidates.append("\(root)/\(child)/openharmony/toolchains/hdc")
                    candidates.append("\(root)/\(child)/toolchains/hdc")
                }
            }
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cachedExecutable = candidate
                Log.info("hdc found: \(candidate)")
                return candidate
            }
        }
        Log.warn("hdc not found (bundled copy / CLT / PATH). USB auto-connect will be " +
                 "skipped; network (Wi-Fi) connection still works.")
        return nil
    }

    // MARK: - Running commands

    private static func run(_ executable: String, arguments: [String],
                            timeout: TimeInterval) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // hdc needs HOME for its server config/socket directory.
        if environment["HOME"] == nil { environment["HOME"] = NSHomeDirectory() }
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return (-1, "failed to launch hdc: \(error.localizedDescription)")
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            Log.warn("hdc \(arguments.joined(separator: " ")) timed out after " +
                     String(format: "%.0fs", timeout))
            process.terminate()
            _ = finished.wait(timeout: .now() + 1.0)
            return (-2, "timeout")
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }

    // MARK: - Targets

    static func listTargets(timeout: TimeInterval = 4.0) -> [HDCTarget] {
        guard let executable = locateExecutable() else { return [] }
        let result = run(executable, arguments: ["list", "targets", "-v"], timeout: timeout)
        var targets: [HDCTarget] = []
        for line in result.output.components(separatedBy: .newlines) {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard tokens.count >= 3 else { continue }
            let serial = tokens[0]
            if serial.hasPrefix("[") || serial.lowercased().contains("error") { continue }
            // Typical forms: "SERIAL USB Connected", "ip:port TCP Connected"
            var transport = tokens[tokens.count - 2]
            var state = tokens[tokens.count - 1]
            if tokens.count >= 4, transport.uppercased() != "USB",
               transport.uppercased() != "TCP" {
                transport = tokens[1]
                state = tokens[2]
            }
            guard state.lowercased().contains("connected") else { continue }
            targets.append(HDCTarget(serial: serial, transport: transport, state: state))
        }
        if targets.isEmpty {
            Log.info("hdc list targets: no devices (output: " +
                     result.output.trimmingCharacters(in: .whitespacesAndNewlines) + ")")
        } else {
            Log.info("hdc targets: " +
                     targets.map { "\($0.serial)/\($0.transport)" }.joined(separator: ", "))
        }
        return targets
    }

    static func firstUSBTarget() -> HDCTarget? {
        let targets = listTargets()
        return targets.first(where: { $0.isUSB }) ?? targets.first
    }

    /// Strictly a USB-attached target (used by the "USB 有线" connection mode,
    /// which must never silently fall back to Wi-Fi).
    static func usbOnlyTarget() -> HDCTarget? {
        listTargets().first(where: { $0.isUSB })
    }

    /// Result of the USB connection attempt, so the GUI can report precise errors.
    enum USBPrepareResult {
        case success(Endpoint)
        case noDevice(String)
        case forwardFailed(String)
    }

    static func prepareUSBConnectionDetailed() -> USBPrepareResult {
        guard locateExecutable() != nil else {
            return .noDevice("未找到 hdc 工具（App 内未打包且系统未安装 HarmonyOS CLT）")
        }
        guard let target = usbOnlyTarget() else {
            return .noDevice("hdc 未发现 USB Connected 设备（请连接数据线并允许 USB 调试）")
        }
        Log.info("USB device found: \(target.serial) — launching tablet app + port forward")
        _ = startTabletApp(target)
        guard forwardPort(target) else {
            return .forwardFailed("hdc fport 端口转发失败（设备 \(target.serial)）")
        }
        return .success(Endpoint(host: "127.0.0.1", port: forwardedLocalPort))
    }

    // MARK: - Tablet app + port forwarding

    static func startTabletApp(_ target: HDCTarget) -> Bool {
        guard let executable = locateExecutable() else { return false }
        let result = run(executable,
                         arguments: ["-t", target.serial, "shell", "aa", "start",
                                     "-a", abilityName, "-b", appBundleName],
                         timeout: 8.0)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = result.status == 0 && !output.lowercased().contains("error")
        Log.info("hdc aa start \(appBundleName)/\(abilityName): " +
                 "\(ok ? "ok" : "failed") \(output.prefix(200))")
        return ok
    }

    static func forwardPort(_ target: HDCTarget) -> Bool {
        guard let executable = locateExecutable() else { return false }
        let local = "tcp:\(forwardedLocalPort)"
        let remote = "tcp:\(tabletServerPort)"
        // Remove a stale mapping first. NOTE: the correct hdc syntax needs the FULL
        // two-part ruler string ("tcp:19528 tcp:9528"); the single-part form fails
        // with "ruler is not exist" and leaves the old mapping in place.
        _ = run(executable, arguments: ["-t", target.serial, "fport", "rm", local, remote],
                timeout: 4.0)
        _ = run(executable, arguments: ["-t", target.serial, "fport", "rm", local], timeout: 3.0)
        let result = run(executable,
                         arguments: ["-t", target.serial, "fport", local, remote],
                         timeout: 6.0)
        var output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var ok = output.contains("OK") || output.contains("forward")
        if !ok {
            // The forward may already exist from a previous run; if hdc lists it,
            // reuse it instead of falling back to Wi-Fi.
            let ls = run(executable, arguments: ["fport", "ls"], timeout: 3.0).output
            if ls.contains("\(local) \(remote)") {
                ok = true
                output += " (reusing existing forward)"
            }
        }
        Log.info("hdc fport \(local) -> \(remote): " +
                 "\(ok ? "ok" : "failed") \(output.prefix(200))")
        return ok
    }

    /// Attempts the whole USB auto-connect sequence. Returns the local endpoint on
    /// success (tablet app launched + forwarded), nil when no USB device is present.
    static func prepareUSBConnection() -> Endpoint? {
        guard let target = firstUSBTarget() else { return nil }
        Log.info("USB device found: \(target.serial) — launching tablet app + port forward")
        _ = startTabletApp(target)
        guard forwardPort(target) else {
            Log.warn("hdc fport failed; will try network connection instead")
            return nil
        }
        return Endpoint(host: "127.0.0.1", port: forwardedLocalPort)
    }
}
