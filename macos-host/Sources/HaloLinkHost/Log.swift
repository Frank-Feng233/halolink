//
//  Log.swift
//  HaloLink macOS host
//
//  Tiny thread-safe logger. Every line starts with "[halolink]" so that scripts
//  can grep for status/READY lines.
//

import Foundation

enum Log {
    private static let lock = NSLock()
    static var verbose = false
    private static var fileHandle: FileHandle?
    static var logFilePath: String?

    /// Also append every line to ~/Library/Logs/HaloLink/halolink-host.log (or
    /// $HALOLINK_LOG_FILE). Useful when the app is started with `open -a`, where
    /// stdout is not visible. Returns the path (nil on failure).
    @discardableResult
    static func enableFileLogging() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard fileHandle == nil else { return logFilePath }
        let path: String
        if let override = ProcessInfo.processInfo.environment["HALOLINK_LOG_FILE"], !override.isEmpty {
            path = override
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            path = home.appendingPathComponent("Library/Logs/HaloLink/halolink-host.log").path
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Keep the log file small: rotate at 5 MB (one .1 backup).
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attributes[.size] as? NSNumber, size.intValue > 5 * 1024 * 1024 {
                let backup = path + ".1"
                try? FileManager.default.removeItem(atPath: backup)
                try? FileManager.default.moveItem(atPath: path, toPath: backup)
            }
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileHandle = handle
            logFilePath = path
            return path
        } catch {
            return nil
        }
    }

    private static func emit(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[halolink] " + text + "\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
            if let handle = fileHandle {
                try? handle.write(contentsOf: data)
            }
        }
    }

    static func info(_ message: String) { emit(message) }
    static func warn(_ message: String) { emit("WARN: " + message) }
    static func error(_ message: String) { emit("ERROR: " + message) }
    static func stats(_ message: String) { emit("stats " + message) }

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        emit("DEBUG: " + message())
    }
}

/// Monotonic clock in seconds, used for FPS/bitrate accounting.
enum Clock {
    /// Monotonic seconds since boot — use for *durations* only.
    static func now() -> Double {
        // CACurrentMediaTime uses mach_absolute_time with timebase conversion.
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }

    /// Unix-epoch microseconds — use for *wire timestamps* (HLDP v1.3 frameTs),
    /// because the tablet compares them against its own wall clock.
    static func epochMicroseconds() -> UInt64 {
        UInt64(max(0.0, Date().timeIntervalSince1970) * 1_000_000.0)
    }
}
