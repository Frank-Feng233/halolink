//
//  HostStats.swift
//  HaloLink macOS host
//
//  Thread-safe counters + rate computation used for the periodic "[halolink] stats"
//  line, the HTTP /status JSON and the shutdown summary.
//

import Foundation

struct HostStatsSnapshot {
    var capturedFrames = 0
    var encodedFrames = 0
    var keyframes = 0
    var encodedBytes = 0
    var sentFrames = 0
    var sentBytes = 0
    var droppedEncode = 0
    var droppedSend = 0
    var jpegFrames = 0
    var captureFps: Double = 0
    var encodeFps: Double = 0
    var kbps: Double = 0
    var sentKbps: Double = 0
    var rttMs: Double = 0
    var peerFps: Double = 0
    var peerDecodeMs: Double = 0
    var peerRttMs: Double = 0
    var uptime: Double = 0
}

final class HostStats {
    private let lock = NSLock()
    private let startTime = Clock.now()

    private var capturedFrames = 0
    private var encodedFrames = 0
    private var keyframes = 0
    private var encodedBytes = 0
    private var sentFrames = 0
    private var sentBytes = 0
    private var droppedEncode = 0
    private var droppedSend = 0
    private var jpegFrames = 0
    private var rttMs: Double = 0
    private var peerFps: Double = 0
    private var peerDecodeMs: Double = 0
    private var peerRttMs: Double = 0

    private var lastRateTime = Clock.now()
    private var lastCaptured = 0
    private var lastEncoded = 0
    private var lastEncodedBytes = 0
    private var lastSent = 0
    private var lastSentBytes = 0
    private var cachedCaptureFps: Double = 0
    private var cachedEncodeFps: Double = 0
    private var cachedKbps: Double = 0
    private var cachedSentKbps: Double = 0

    // MARK: - Recording

    func recordCaptured() {
        lock.lock()
        capturedFrames += 1
        lock.unlock()
    }

    func recordEncoded(bytes: Int, keyframe: Bool) {
        lock.lock()
        encodedFrames += 1
        encodedBytes += bytes
        if keyframe { keyframes += 1 }
        lock.unlock()
    }

    func recordSent(bytes: Int) {
        lock.lock()
        sentFrames += 1
        sentBytes += bytes
        lock.unlock()
    }

    func recordDroppedEncode() {
        lock.lock()
        droppedEncode += 1
        lock.unlock()
    }

    func recordDroppedSend() {
        lock.lock()
        droppedSend += 1
        lock.unlock()
    }

    func recordJPEGFrame() {
        lock.lock()
        jpegFrames += 1
        lock.unlock()
    }

    func setRTT(_ ms: Double) {
        lock.lock()
        rttMs = ms
        lock.unlock()
    }

    func recordPeerStats(fps: Double?, decodeMs: Double?, rttMs: Double?) {
        lock.lock()
        if let fps = fps { peerFps = fps }
        if let decodeMs = decodeMs { peerDecodeMs = decodeMs }
        if let rttMs = rttMs { peerRttMs = rttMs }
        lock.unlock()
    }

    /// Resets per-second rate windows (called when a new streaming session starts).
    func resetFrameTiming() {
        lock.lock()
        lastRateTime = Clock.now()
        lastCaptured = capturedFrames
        lastEncoded = encodedFrames
        lastEncodedBytes = encodedBytes
        lastSent = sentFrames
        lastSentBytes = sentBytes
        cachedCaptureFps = 0
        cachedEncodeFps = 0
        cachedKbps = 0
        cachedSentKbps = 0
        lock.unlock()
    }

    // MARK: - Rates

    /// Recomputes per-second rates. Called by the periodic stats timer.
    @discardableResult
    func updateRates() -> HostStatsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = Clock.now()
        let elapsed = max(0.001, now - lastRateTime)
        cachedCaptureFps = Double(capturedFrames - lastCaptured) / elapsed
        cachedEncodeFps = Double(encodedFrames - lastEncoded) / elapsed
        cachedKbps = Double(encodedBytes - lastEncodedBytes) * 8.0 / 1000.0 / elapsed
        cachedSentKbps = Double(sentBytes - lastSentBytes) * 8.0 / 1000.0 / elapsed
        lastRateTime = now
        lastCaptured = capturedFrames
        lastEncoded = encodedFrames
        lastEncodedBytes = encodedBytes
        lastSent = sentFrames
        lastSentBytes = sentBytes
        return snapshotLocked()
    }

    func snapshot() -> HostStatsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private func snapshotLocked() -> HostStatsSnapshot {
        var snapshot = HostStatsSnapshot()
        snapshot.capturedFrames = capturedFrames
        snapshot.encodedFrames = encodedFrames
        snapshot.keyframes = keyframes
        snapshot.encodedBytes = encodedBytes
        snapshot.sentFrames = sentFrames
        snapshot.sentBytes = sentBytes
        snapshot.droppedEncode = droppedEncode
        snapshot.droppedSend = droppedSend
        snapshot.jpegFrames = jpegFrames
        snapshot.captureFps = cachedCaptureFps
        snapshot.encodeFps = cachedEncodeFps
        snapshot.kbps = cachedKbps
        snapshot.sentKbps = cachedSentKbps
        snapshot.rttMs = rttMs
        snapshot.peerFps = peerFps
        snapshot.peerDecodeMs = peerDecodeMs
        snapshot.peerRttMs = peerRttMs
        snapshot.uptime = Clock.now() - startTime
        return snapshot
    }

    /// One line, used by the periodic timer (every 2s) and on shutdown.
    func statsLine(snapshot: HostStatsSnapshot) -> String {
        var text = String(format: "fps=%.1f captureFps=%.1f kbps=%.0f encoded=%d sent=%d " +
                          "keyframes=%d dropped=%d/%d jpeg=%d rtt=%.1fms uptime=%.0fs",
                          snapshot.encodeFps, snapshot.captureFps, snapshot.kbps,
                          snapshot.encodedFrames, snapshot.sentFrames, snapshot.keyframes,
                          snapshot.droppedEncode, snapshot.droppedSend, snapshot.jpegFrames,
                          snapshot.rttMs, snapshot.uptime)
        if snapshot.peerFps > 0 || snapshot.peerDecodeMs > 0 {
            text += String(format: " peer(fps=%.1f decode=%.1fms rtt=%.1fms)",
                           snapshot.peerFps, snapshot.peerDecodeMs, snapshot.peerRttMs)
        }
        return text
    }

    /// Final human-readable summary printed during shutdown.
    func summaryLine(snapshot: HostStatsSnapshot) -> String {
        let seconds = max(0.001, snapshot.uptime)
        return String(format: "captured=%d encoded=%d (%.1f MB) keyframes=%d sent=%d " +
                      "(%.1f MB) dropped=%d/%d jpeg=%d avgFps=%.1f uptime=%.1fs",
                      snapshot.capturedFrames, snapshot.encodedFrames,
                      Double(snapshot.encodedBytes) / 1_000_000.0, snapshot.keyframes,
                      snapshot.sentFrames, Double(snapshot.sentBytes) / 1_000_000.0,
                      snapshot.droppedEncode, snapshot.droppedSend, snapshot.jpegFrames,
                      Double(snapshot.encodedFrames) / seconds, seconds)
    }
}
