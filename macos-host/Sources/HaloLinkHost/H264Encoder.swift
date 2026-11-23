//
//  H264Encoder.swift
//  HaloLink macOS host
//
//  Hardware H.264 encoding of ScreenCaptureKit frames with VideoToolbox.
//
//  Design:
//   * real-time, no frame reordering (no B frames), 1 second GOP, Main profile by
//     default for maximum decoder compatibility (HarmonyOS AVCodec).
//   * VideoToolbox emits AVCC (4-byte big-endian length prefixed NALUs); we convert
//     to Annex-B and repeat SPS/PPS before every IDR so a decoder can join at any
//     keyframe (and on the very first frame after "ready").
//   * frames are dropped (not queued) when the encoder is 3 frames behind, which
//     keeps latency low; the transport requests a fresh IDR after any drop.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct EncodedVideoFrame {
    let data: Data
    let pts: CMTime
    let isKeyframe: Bool
    /// Wall-clock capture time (Unix microseconds) of the frame that produced this
    /// access unit. Used for HLDP v1.3 frame timestamps and encodeMs accounting.
    let captureTimestampUs: UInt64
    /// Time from the frame entering the host to the encoded output callback.
    let encodeMs: Double
}

/// Per-frame timing passed through VideoToolbox's `sourceFrameRefcon`.
///
/// Two different clocks are involved and must NOT be mixed:
///  * `captureEpochUs` — Unix epoch microseconds, only for the HLDP v1.3 wire
///    timestamp (must match the tablet's wall clock);
///  * `submitUptimeNs` — `mach_absolute_time` nanoseconds, only for measuring
///    internal durations (encodeMs), immune to wall-clock changes.
private final class FrameTimingBox {
    let captureEpochUs: UInt64
    let submitUptimeNs: UInt64

    init(captureEpochUs: UInt64) {
        self.captureEpochUs = captureEpochUs
        self.submitUptimeNs = DispatchTime.now().uptimeNanoseconds
    }
}

final class H264Encoder {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var fps: Int
    private(set) var profile: String

    /// Called from a VideoToolbox callback thread with a ready-to-send Annex-B
    /// access unit. Do not block here.
    var onEncodedFrame: ((EncodedVideoFrame) -> Void)?
    /// Called when a frame is dropped because the encoder is behind (statistics).
    var onFrameDropped: (() -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    /// Keep at most 2 frames in flight inside VideoToolbox: a deeper queue adds
    /// ~1 frame of latency with no benefit at the target frame rates.
    private let maxOutstandingFrames: Int = {
        if let raw = ProcessInfo.processInfo.environment["HALOLINK_VT_OUTSTANDING"],
           let value = Int(raw), value > 0 {
            return value
        }
        return 2
    }()

    private var useLowLatencyRateControl: Bool {
        ProcessInfo.processInfo.environment["HALOLINK_VT_LOWLATENCY"] != "0"
    }
    private var outstandingFrames = 0
    private var forceNextKeyframe = true
    /// True when the low-latency rate controller was negotiated (HLDP v1.3).
    private(set) var lowLatencyRateControlActive = false
    private var recoveryKeyframePending = false
    private var lastForcedKeyframeTime: TimeInterval = 0
    private var finished = false
    private var totalFrames = 0
    private var totalBytes = 0
    private var keyframes = 0
    private var dropped = 0

    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    init(width: Int, height: Int, fps: Int, bitrate: Int, profile: String) throws {
        self.width = width
        self.height = height
        self.fps = fps
        self.profile = profile

        func createSession(lowLatencyRateControl: Bool) -> (OSStatus, VTCompressionSession?) {
            var specification: [String: Any] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ]
            if lowLatencyRateControl {
                specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
            }
            var sessionOut: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: haloLinkEncoderCallback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &sessionOut)
            return (status, sessionOut)
        }

        // HLDP v1.3: enable the low-latency rate controller when the encoder
        // supports it (macOS 11.3+), otherwise fall back to the normal session.
        let requestedLowLatency = useLowLatencyRateControl
        var (status, sessionOut) = createSession(lowLatencyRateControl: requestedLowLatency)
        let lowLatencyRateControlActive = requestedLowLatency && status == noErr && sessionOut != nil
        if requestedLowLatency && !lowLatencyRateControlActive {
            Log.warn("low-latency rate control unavailable (OSStatus \(status)); " +
                     "retrying without it")
            (status, sessionOut) = createSession(lowLatencyRateControl: false)
        }
        guard status == noErr, let session = sessionOut else {
            throw HaloLinkError("VTCompressionSessionCreate failed: OSStatus \(status). " +
                                "H.264 hardware encoder unavailable?")
        }
        self.session = session
        self.lowLatencyRateControlActive = lowLatencyRateControlActive
        if requestedLowLatency {
            Log.info("VT low-latency rate control: " +
                     (lowLatencyRateControlActive ? "enabled" : "not available (fallback)") +
                     " · PrioritizeEncodingSpeedOverQuality=on · outstandingLimit=" +
                     "\(maxOutstandingFrames)")
        } else {
            Log.info("VT low-latency rate control: disabled by env (HALOLINK_VT_LOWLATENCY=0) " +
                     "· outstandingLimit=\(maxOutstandingFrames)")
        }

        func set(_ key: CFString, _ value: Any?) {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef?)
            if result != noErr {
                Log.debug("VTSessionSetProperty(\(key)) -> \(result)")
            }
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // HLDP v1.3: bias the encoder towards speed (lower latency) over quality.
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        let profileLevel: CFString = profile.lowercased() == "high"
            ? kVTProfileLevel_H264_High_AutoLevel
            : kVTProfileLevel_H264_Main_AutoLevel
        set(kVTCompressionPropertyKey_ProfileLevel, profileLevel)
        // AverageBitRate is a 32-bit signed property: clamp to Int32.max.
        set(kVTCompressionPropertyKey_AverageBitRate,
            NSNumber(value: min(max(bitrate, 100_000), Int(Int32.max))))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps))     // 1s GOP
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        set(kVTCompressionPropertyKey_Quality, NSNumber(value: 0.65))
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepare != noErr {
            Log.warn("VTCompressionSessionPrepareToEncodeFrames -> \(prepare)")
        }
        Log.info("H.264 encoder ready: \(width)x\(height) @\(fps)fps " +
                 "\(bitrate / 1_000_000)Mbps profile=\(profile) realtime=yes bframes=no gop=1s")
    }

    func requestKeyframe() {
        lock.lock()
        forceNextKeyframe = true
        lock.unlock()
    }

    /// Encodes one frame. Safe to call from the capture queue.
    /// - Parameter captureTimestampUs: wall-clock Unix microseconds when the frame
    ///   was received from ScreenCaptureKit (passed through to the encoded frame).
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime,
                captureTimestampUs: UInt64 = 0,
                forceKeyframe: Bool = false) {
        lock.lock()
        guard let session = session, !finished else {
            lock.unlock()
            return
        }
        if outstandingFrames >= maxOutstandingFrames {
            dropped += 1
            // Request a recovery IDR, but at most once per second: forcing a
            // keyframe for every dropped frame would turn the stream into
            // all-intra at high frame rates (measured at --fps 120).
            recoveryKeyframePending = true
            lock.unlock()
            onFrameDropped?()
            return
        }
        var shouldForce = forceKeyframe || forceNextKeyframe
        if recoveryKeyframePending, !shouldForce,
           Clock.now() - lastForcedKeyframeTime >= 1.0 {
            shouldForce = true
            recoveryKeyframePending = false
        }
        if shouldForce { lastForcedKeyframeTime = Clock.now() }
        if shouldForce { forceNextKeyframe = false }
        outstandingFrames += 1
        lock.unlock()

        let frameProperties: CFDictionary? = shouldForce
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        // Refcon carries BOTH the wire capture timestamp (epoch µs) and the
        // internal submit time (uptime ns) so encodeMs stays correct.
        let timing = FrameTimingBox(captureEpochUs: captureTimestampUs)
        let refcon = Unmanaged.passRetained(timing).toOpaque()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: refcon,
            infoFlagsOut: nil)
        if status != noErr {
            // No output callback will run for a synchronously rejected frame.
            Unmanaged<FrameTimingBox>.fromOpaque(refcon).release()
            lock.lock()
            outstandingFrames = max(0, outstandingFrames - 1)
            lock.unlock()
            Log.warn("VTCompressionSessionEncodeFrame failed: OSStatus \(status)")
        }
    }

    /// Waits for pending frames, then tears the session down. Must not be called
    /// from the VideoToolbox callback thread (call from the main thread).
    func finish() {
        lock.lock()
        guard let session = session else {
            lock.unlock()
            return
        }
        self.session = nil
        finished = true
        lock.unlock()

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        lock.lock()
        let frames = totalFrames
        let bytes = totalBytes
        let keys = keyframes
        let droppedFrames = dropped
        lock.unlock()
        Log.info("encoder stopped: frames=\(frames) bytes=\(bytes) keyframes=\(keys) " +
                 "dropped=\(droppedFrames)")
    }

    // MARK: - Statistics

    struct Counters {
        let frames: Int
        let bytes: Int
        let keyframes: Int
        let dropped: Int
    }

    var counters: Counters {
        lock.lock()
        defer { lock.unlock() }
        return Counters(frames: totalFrames, bytes: totalBytes, keyframes: keyframes,
                        dropped: dropped)
    }

    // MARK: - Callback handling

    fileprivate func handleEncoded(status: OSStatus, sampleBuffer: CMSampleBuffer?,
                                   sourceFrameRefcon: UnsafeMutableRawPointer?) {
        lock.lock()
        outstandingFrames = max(0, outstandingFrames - 1)
        lock.unlock()
        // The timing box is retained when encoding is submitted; always release it.
        let timing: FrameTimingBox? = sourceFrameRefcon.map {
            Unmanaged<FrameTimingBox>.fromOpaque($0).takeRetainedValue()
        }
        guard status == noErr, let sampleBuffer = sampleBuffer else {
            Log.debug("encoder dropped a frame: OSStatus \(status)")
            return
        }
        let captureEpochUs = timing?.captureEpochUs ?? 0
        var encodeMs = 0.0
        if let submitNs = timing?.submitUptimeNs {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs > submitNs {
                // Internal duration: uptime clock on both sides.
                encodeMs = Double(nowNs - submitNs) / 1_000_000.0
            }
        }
        guard let frame = Self.annexBFrame(from: sampleBuffer,
                                           captureTimestampUs: captureEpochUs,
                                           encodeMs: encodeMs) else { return }

        lock.lock()
        totalFrames += 1
        totalBytes += frame.data.count
        if frame.isKeyframe { keyframes += 1 }
        lock.unlock()

        onEncodedFrame?(frame)
    }

    // MARK: - AVCC -> Annex-B

    private static func annexBFrame(from sampleBuffer: CMSampleBuffer,
                                   captureTimestampUs: UInt64,
                                   encodeMs: Double) -> EncodedVideoFrame? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }
        var payload = Data(count: totalLength)
        let copyStatus = payload.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength,
                                              destination: base)
        }
        guard copyStatus == noErr else { return nil }

        var headerLength = 4
        var formatDescription: CMFormatDescription?
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            formatDescription = fmt
            var nalHeaderLen: Int32 = 4
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalHeaderLen)
            if nalHeaderLen > 0, nalHeaderLen <= 4 {
                headerLength = Int(nalHeaderLen)
            }
        }

        // First pass: locate NAL units and detect an IDR slice (type 5).
        var units: [(offset: Int, length: Int)] = []
        var hasIDR = false
        payload.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset + headerLength <= totalLength {
                var nalLength = 0
                for i in 0..<headerLength {
                    nalLength = (nalLength << 8) | Int(bytes[offset + i])
                }
                offset += headerLength
                guard nalLength > 0, offset + nalLength <= totalLength else { break }
                let nalType = bytes[offset] & 0x1F
                if nalType == 5 { hasIDR = true }
                units.append((offset: offset, length: nalLength))
                offset += nalLength
            }
        }
        guard !units.isEmpty else { return nil }
        let isKeyframe = hasIDR

        var output = Data(capacity: totalLength + 256)
        if isKeyframe, let fmt = formatDescription {
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: nil)
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                if status == noErr, let pointer = pointer, size > 0 {
                    output.append(contentsOf: startCode)
                    output.append(pointer, count: size)
                }
            }
        }
        for unit in units {
            output.append(contentsOf: startCode)
            output.append(payload.subdata(in: unit.offset..<(unit.offset + unit.length)))
        }

        return EncodedVideoFrame(data: output,
                                 pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                 isKeyframe: isKeyframe,
                                 captureTimestampUs: captureTimestampUs,
                                 encodeMs: encodeMs)
    }
}

/// VideoToolbox C callback. The refcon is an unretained pointer to H264Encoder,
/// whose lifetime spans the whole encode session (released only after
/// VTCompressionSessionCompleteFrames + Invalidates on shutdown).
private func haloLinkEncoderCallback(
    refcon: UnsafeMutableRawPointer?,
    sourceFrameRefcon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?) {
    guard let refcon = refcon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
    encoder.handleEncoded(status: status, sampleBuffer: sampleBuffer,
                          sourceFrameRefcon: sourceFrameRefcon)
}
