//
//  SyntheticSource.swift
//  HaloLink macOS host
//
//  Test/CI helper (--synthetic): generates NV12 frames with moving colour bars
//  and feeds them through the exact same encode/MJPEG/dump path as real captured
//  frames. This makes the TCP protocol, H.264 pipeline and HTTP server testable
//  without Screen Recording permission and with deterministic frame rates.
//

import CoreMedia
import CoreVideo
import Foundation

final class SyntheticSource {
    let width: Int
    let height: Int
    let fps: Int

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let queue = DispatchQueue(label: "com.halolink.synthetic", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var started = false
    private var pool: CVPixelBufferPool?
    private var rowScratch: [UInt8] = []
    private var uvScratch: [UInt8] = []

    init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = max(1, fps)
    }

    func start() throws {
        guard !started else { return }
        guard width >= 16, height >= 16 else {
            throw HaloLinkError("synthetic frame size too small")
        }
        try createPool()
        rowScratch = [UInt8](repeating: 0, count: width)
        uvScratch = [UInt8](repeating: 128, count: width) // CbCr row
        started = true

        let interval = 1.0 / Double(fps)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
        Log.info("synthetic frame source started: \(width)x\(height) @\(fps)fps (test mode)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        started = false
        Log.info("synthetic frame source stopped (frames=\(frameIndex))")
    }

    private func createPool() throws {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64
        ]
        var poolOut: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                             attributes as CFDictionary, &poolOut)
        guard status == kCVReturnSuccess, let pool = poolOut else {
            throw HaloLinkError("CVPixelBufferPoolCreate failed (\(status))")
        }
        self.pool = pool
    }

    private func tick() {
        guard started, let pool = pool else { return }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            Log.warn("synthetic: CVPixelBufferPoolCreatePixelBuffer failed (\(status))")
            return
        }
        fill(buffer, frame: frameIndex)
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
        frameIndex += 1
        onFrame?(buffer, pts)
    }

    private func fill(_ pixelBuffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yBytes = yBase.assumingMemoryBound(to: UInt8.self)
        let uvBytes = uvBase.assumingMemoryBound(to: UInt8.self)

        // Vertical colour bars (BT.709 limited-range Y values).
        let barY: [UInt8] = [235, 210, 170, 145, 106, 81, 41, 16]
        let barU: [UInt8] = [128, 16, 146, 54, 34, 90, 240, 128]
        let barV: [UInt8] = [128, 146, 16, 34, 240, 90, 110, 128]
        let barCount = barY.count
        let barWidth = max(1, width / barCount)
        let movingBarWidth = max(2, width / 24)
        let phase = Double(frame) * 0.02
        let movingX = Int((0.5 + 0.5 * sin(phase)) * Double(max(1, width - movingBarWidth)))
        let horizontalBandHeight = max(2, height / 16)
        let bandY = Int((0.5 + 0.5 * sin(phase * 1.7)) * Double(max(1, height - horizontalBandHeight)))

        // Build one luma row (same for every row: only the moving bar changes X).
        for x in 0..<width {
            let bar = ((x / barWidth) % barCount + barCount) % barCount
            var value = barY[bar]
            if x >= movingX && x < movingX + movingBarWidth {
                value = 255
            }
            rowScratch[x] = value
        }
        // One chroma row (CbCr interleaved, 2 bytes per pixel; 420 => width/2
        // chroma samples per row = `width` bytes).
        for sample in 0..<(width / 2) {
            let bar = ((sample * 2 / barWidth) % barCount + barCount) % barCount
            uvScratch[sample * 2] = barU[bar]
            uvScratch[sample * 2 + 1] = barV[bar]
        }

        rowScratch.withUnsafeBufferPointer { row in
            guard let base = row.baseAddress else { return }
            for y in 0..<height {
                memcpy(yBytes + y * yStride, base, width)
            }
        }
        // Moving horizontal band (value inversion) so even a single-column sample
        // sees motion; also makes the stream visually obvious in recordings.
        for y in bandY..<min(height, bandY + horizontalBandHeight) {
            let row = yBytes + y * yStride
            for x in 0..<width {
                row[x] = 255 &- row[x]
            }
        }
        uvScratch.withUnsafeBufferPointer { row in
            guard let base = row.baseAddress else { return }
            // Chroma planes are half height for 420 formats.
            for y in 0..<(height / 2) {
                memcpy(uvBytes + y * uvStride, base, width)
            }
        }
    }
}
