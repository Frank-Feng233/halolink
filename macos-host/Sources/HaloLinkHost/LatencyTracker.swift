//
//  LatencyTracker.swift
//  HaloLink macOS host
//
//  HLDP v1.3 latency instrumentation: keeps short ring buffers of per-frame
//  timings and reports avg / p95 for the host-side pipeline stages:
//
//    captureMs : interval between ScreenCaptureKit frame callbacks (frames that
//                are actually delivered; SCK is change driven, so a static desktop
//                shows large values while an animating desktop shows ~1/fps)
//    encodeMs  : VideoToolbox output callback time - frame arrival at the host
//    sendMs    : NWConnection send completion time - encoder output time
//    rttMs     : HLDP PING/PONG round trip (transport level)
//    e2eMs/recvMs/decMs/renderMs/presentHz: reported by the tablet via `stats`
//
//  p95 is computed over the most recent `capacity` samples.
//

import Foundation

final class LatencyTracker {
    private let lock = NSLock()
    private let capacity = 240

    private var captureIntervals: [Double] = []
    private var encodeSamples: [Double] = []
    private var sendSamples: [Double] = []
    private var lastFrameArrival: TimeInterval = 0

    // Tablet-reported end-to-end decomposition (HLDP v1.3 §9.2). Fields are kept
    // exactly as sent by the tablet: `decodeMs` is the legacy decoder-time metric
    // shown by the tablet HUD, while `decMs` is the v1.3 stage breakdown value.
    private(set) var tabletE2EMs: Double = 0
    private(set) var tabletRecvMs: Double = 0
    /// HLDP v1.3 `decMs` (decode stage). 0 when absent.
    private(set) var tabletDecMs: Double = 0
    private(set) var tabletDecMsReported = false
    /// Legacy `decodeMs` (what the tablet HUD labels "解码"). 0 when absent.
    private(set) var tabletDecodeMs: Double = 0
    private(set) var tabletRenderMs: Double = 0
    private(set) var tabletPresentHz: Double = 0
    private(set) var tabletRttMs: Double = 0
    private(set) var tabletRxFps: Double = 0
    private(set) var lastTabletStatsTime: TimeInterval = 0
    /// Set when the tablet's v1.3 `decMs` disagrees with its legacy `decodeMs`
    /// (symptom of the tablet-side clock/FIFO pairing bug); surfaced in `/status`.
    private(set) var tabletLatencyAnomaly: String?
    private(set) var frameTimestampsEnabled = false

    // MARK: - Recording

    func noteFrameArrival(_ time: TimeInterval) {
        lock.lock()
        if lastFrameArrival > 0 {
            let interval = (time - lastFrameArrival) * 1000.0
            if interval > 0 && interval < 5000 {
                captureIntervals.append(interval)
                if captureIntervals.count > capacity { captureIntervals.removeFirst() }
            }
        }
        lastFrameArrival = time
        lock.unlock()
    }

    func noteEncode(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 5000 else { return }
        lock.lock()
        encodeSamples.append(milliseconds)
        if encodeSamples.count > capacity { encodeSamples.removeFirst() }
        lock.unlock()
    }

    func noteSend(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 5000 else { return }
        lock.lock()
        sendSamples.append(milliseconds)
        if sendSamples.count > capacity { sendSamples.removeFirst() }
        lock.unlock()
    }

    func recordTabletStats(_ message: [String: Any]) {
        func value(_ key: String) -> Double? {
            if let double = message[key] as? Double { return double }
            if let int = message[key] as? Int { return Double(int) }
            if let number = message[key] as? NSNumber { return number.doubleValue }
            return nil
        }
        lock.lock()
        if let e2e = value("e2eMs") { tabletE2EMs = e2e }
        if let recv = value("recvMs") { tabletRecvMs = recv }
        if let dec = value("decMs") {
            tabletDecMs = dec
            tabletDecMsReported = true
        }
        if let render = value("renderMs") { tabletRenderMs = render }
        if let hz = value("presentHz") { tabletPresentHz = hz }
        if let decode = value("decodeMs") { tabletDecodeMs = decode }
        if let rtt = value("rttMs") { tabletRttMs = rtt }
        if let rxFps = value("rxFps") { tabletRxFps = rxFps }

        // Sanity check: the v1.3 decode-stage time should be in the same ballpark
        // as the legacy decode metric. A large divergence is a tablet-side
        // clock/FIFO bug, not a host parsing issue.
        if tabletDecMsReported, tabletDecodeMs > 0, tabletDecMs > 0 {
            let ratio = tabletDecMs / max(0.1, tabletDecodeMs)
            if ratio > 3.0, tabletDecMs - tabletDecodeMs > 20.0 {
                tabletLatencyAnomaly = String(format:
                    "tablet decMs=%.1fms vs decodeMs=%.1fms (ratio %.1fx) — " +
                    "likely tablet clock/FIFO skew, host fields shown as reported",
                    tabletDecMs, tabletDecodeMs, ratio)
            } else {
                tabletLatencyAnomaly = nil
            }
        } else {
            tabletLatencyAnomaly = nil
        }
        lastTabletStatsTime = Clock.now()
        lock.unlock()
    }

    func setFrameTimestampsEnabled(_ enabled: Bool) {
        lock.lock()
        frameTimestampsEnabled = enabled
        lock.unlock()
    }

    // MARK: - Snapshot

    struct Summary {
        var captureAvgMs: Double = 0
        var captureP95Ms: Double = 0
        var captureSamples = 0
        var encodeAvgMs: Double = 0
        var encodeP95Ms: Double = 0
        var encodeSamples = 0
        var sendAvgMs: Double = 0
        var sendP95Ms: Double = 0
        var sendSamples = 0
        var rttMs: Double = 0
        var e2eMs: Double = 0
        var recvMs: Double = 0
        var decMs: Double = 0
        var decMsReported = false
        var decodeMsLegacy: Double = 0
        var renderMs: Double = 0
        var presentHz: Double = 0
        var tabletRttMs: Double = 0
        var tabletStatsAge: Double = 0
        var tabletLatencyAnomaly: String?
        var frameTimestampsEnabled = false

        /// One compact line for logs / shutdown summary.
        var logLine: String {
            // Report the tablet fields exactly as received: `dec` = v1.3 decMs,
            // `decodeMs` = legacy metric shown by the tablet HUD.
            let decText = decMsReported
                ? String(format: "%.1f", decMs)
                : (decodeMsLegacy > 0 ? String(format: "%.1f*", decodeMsLegacy) : "—")
            // e2e is the tablet-reported value (its rolling-minimum estimator removes
            // clock bias and systematically underestimates by roughly
            // captureToSend + minimum transport ≈ 20 ms). True capture→render is
            // therefore higher; the note is part of the line by design.
            var line = String(format: "lat cap=%.1f/%.1fms(%d) enc=%.1f/%.1fms " +
                              "snd=%.1f/%.1fms rtt=%.1fms " +
                              "e2e=%.1fms(tablet-reported, min-bias removed; true " +
                              "capture→render ≈ +20ms) " +
                              "(recv=%.1f dec=%@ decodeMs=%.1f render=%.1f hz=%.0f)",
                              captureAvgMs, captureP95Ms, captureSamples,
                              encodeAvgMs, encodeP95Ms,
                              sendAvgMs, sendP95Ms,
                              rttMs, e2eMs, recvMs, decText, decodeMsLegacy,
                              renderMs, presentHz)
            if let anomaly = tabletLatencyAnomaly {
                line += " WARN tablet-latency-anomaly: " + anomaly
            }
            return line
        }
    }

    func summary(transportRTTMs: Double) -> Summary {
        lock.lock()
        defer { lock.unlock() }
        var result = Summary()
        result.captureAvgMs = Self.average(captureIntervals)
        result.captureP95Ms = Self.percentile(captureIntervals, 0.95)
        result.captureSamples = captureIntervals.count
        result.encodeAvgMs = Self.average(encodeSamples)
        result.encodeP95Ms = Self.percentile(encodeSamples, 0.95)
        result.encodeSamples = encodeSamples.count
        result.sendAvgMs = Self.average(sendSamples)
        result.sendP95Ms = Self.percentile(sendSamples, 0.95)
        result.sendSamples = sendSamples.count
        result.rttMs = transportRTTMs
        result.e2eMs = tabletE2EMs
        result.recvMs = tabletRecvMs
        result.decMs = tabletDecMs
        result.decMsReported = tabletDecMsReported
        result.decodeMsLegacy = tabletDecodeMs
        result.renderMs = tabletRenderMs
        result.presentHz = tabletPresentHz
        result.tabletRttMs = tabletRttMs
        result.tabletStatsAge = lastTabletStatsTime > 0 ? Clock.now() - lastTabletStatsTime : -1
        result.tabletLatencyAnomaly = tabletLatencyAnomaly
        result.frameTimestampsEnabled = frameTimestampsEnabled
        return result
    }

    func resetSession() {
        lock.lock()
        captureIntervals.removeAll()
        encodeSamples.removeAll()
        sendSamples.removeAll()
        lastFrameArrival = 0
        tabletE2EMs = 0
        tabletRecvMs = 0
        tabletDecMs = 0
        tabletRenderMs = 0
        tabletPresentHz = 0
        tabletDecodeMs = 0
        tabletDecMsReported = false
        tabletRttMs = 0
        tabletRxFps = 0
        tabletLatencyAnomaly = nil
        lastTabletStatsTime = 0
        lock.unlock()
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}
