//
//  SingleInstanceLock.swift
//  HaloLink macOS host
//
//  Only one HaloLink host can own the HaloLink virtual display (the private
//  CGVirtualDisplay signature is fixed), so a second instance would fail with a
//  confusing "init returned nil". A POSIX file lock gives a clear, race-free
//  single-instance guarantee: the lock is released automatically when the process
//  exits (even on crash), so no stale lock cleanup is needed.
//

import Darwin
import Foundation

final class SingleInstanceLock {
    private var fileDescriptor: Int32 = -1
    private var lockPath: String = ""
    private var pid: pid_t = 0

    /// Human readable reason when acquisition failed.
    private(set) static var lastFailureReason: String?

    var pathDescription: String { lockPath }

    /// Returns nil when another live instance holds the lock.
    init?() {
        let fileManager = FileManager.default
        var directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HaloLink", isDirectory: true)
        if (try? fileManager.createDirectory(at: directory,
                                             withIntermediateDirectories: true)) == nil {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("HaloLink", isDirectory: true)
            if (try? fileManager.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)) == nil {
                // Cannot create a lock directory at all; allow the run.
                return
            }
        }
        lockPath = directory.appendingPathComponent("host.lock").path
        if let override = ProcessInfo.processInfo.environment["HALOLINK_LOCK_PATH"],
           !override.isEmpty {
            // Dev/test hook: allows a UI-only preview while the real app is running.
            lockPath = override
        }
        pid = getpid()

        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // Cannot open the lock file; allow the run (fail-open: a broken home
            // directory should not prevent the app from working).
            lockPath = ""
            return
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let existing = Self.readPID(from: lockPath)
            SingleInstanceLock.lastFailureReason = existing > 0
                ? "another HaloLink host is already running (pid \(existing)); " +
                  "lock file: \(lockPath)"
                : "another HaloLink host is already running; lock file: \(lockPath)"
            Darwin.close(fd)
            return nil
        }
        fileDescriptor = fd
        writePID()
    }

    private func writePID() {
        guard fileDescriptor >= 0 else { return }
        let text = "\(pid)\n"
        _ = ftruncate(fileDescriptor, 0)
        _ = lseek(fileDescriptor, 0, SEEK_SET)
        text.withCString { pointer in
            _ = Darwin.write(fileDescriptor, pointer, strlen(pointer))
        }
        fsync(fileDescriptor)
    }

    private static func readPID(from path: String) -> pid_t {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(trimmed) else { return 0 }
        return pid_t(value)
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        _ = ftruncate(fileDescriptor, 0)
        _ = flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }
}
