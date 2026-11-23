//
//  FrameSaver.swift
//  HaloLink macOS host
//
//  Testing helper for --save-frames: writes a bounded number of captured frames
//  as PNG (via ImageIO) on a background queue, and reports the mean luma so that
//  automated acceptance checks can prove the frames are not black.
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

final class FrameSaver {
    private let directory: URL
    private let maxFrames: Int
    private let minimumInterval: TimeInterval = 0.25
    private let queue = DispatchQueue(label: "com.halolink.framesaver", qos: .utility)
    private let lock = NSLock()
    private var scheduled = 0
    private var lastSubmitTime: TimeInterval = 0
    private var written: [URL] = []
    private var lumaSamples: [Double] = []
    private var finished = false
    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0

    init?(directory path: String, fps: Int, maxFrames: Int = 8) {
        _ = fps
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.error("--save-frames: cannot create directory \(path): \(error.localizedDescription)")
            return nil
        }
        self.directory = url
        self.maxFrames = max(1, maxFrames)
        Log.info("frame saving enabled: \(url.path) (max \(self.maxFrames) PNG, " +
                 "up to ~4/s)")
    }

    var savedFiles: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    var meanLumas: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return lumaSamples
    }

    /// Called on the capture queue for every frame. Cheap: only dispatches when a
    /// PNG should actually be produced.
    func submit(_ pixelBuffer: CVPixelBuffer, frameIndex: Int) {
        _ = frameIndex
        let now = Clock.now()
        lock.lock()
        guard !finished, scheduled < maxFrames else {
            lock.unlock()
            return
        }
        // Keep the capture path cheap: at most ~4 PNG/s, but always take the first frame.
        guard scheduled == 0 || now - lastSubmitTime >= minimumInterval else {
            lock.unlock()
            return
        }
        lastSubmitTime = now
        scheduled += 1
        lock.unlock()

        if pixelWidth == 0 {
            pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
            pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
        }
        let retained = pixelBuffer
        queue.async { [weak self] in
            self?.writePNG(retained)
        }
    }

    private func writePNG(_ pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard status == noErr, let image = cgImage else {
            Log.warn("save-frames: VTCreateCGImageFromCVPixelBuffer failed (\(status))")
            return
        }
        let luma = Self.meanLuma(pixelBuffer)
        lock.lock()
        let index = written.count
        lock.unlock()
        let filename = String(format: "frame-%02d-%dx%d.png", index,
                              CVPixelBufferGetWidth(pixelBuffer),
                              CVPixelBufferGetHeight(pixelBuffer))
        let url = directory.appendingPathComponent(filename)
        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil) else {
            Log.warn("save-frames: cannot create \(url.path)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            Log.warn("save-frames: failed to write \(url.path)")
            return
        }
        lock.lock()
        written.append(url)
        lumaSamples.append(luma)
        let done = written.count
        lock.unlock()
        Log.info(String(format: "saved %@ luma=%.1f (%d/%d)", url.path, luma, done, maxFrames))
    }

    /// Mean of the Y plane (NV12) / green channel (BGRA), sampled on a grid.
    static func meanLuma(_ pixelBuffer: CVPixelBuffer) -> Double {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isPlanar = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return 0 }
        if isPlanar, let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let planeBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var sum = 0.0
            var count = 0
            for y in Swift.stride(from: 0, to: height, by: max(1, height / 24)) {
                let row = bytes + y * planeBytesPerRow
                for x in Swift.stride(from: 0, to: width, by: max(1, width / 32)) {
                    sum += Double(row[x])
                    count += 1
                }
            }
            return count > 0 ? sum / Double(count) : 0
        }
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var sum = 0.0
            var count = 0
            for y in Swift.stride(from: 0, to: height, by: max(1, height / 24)) {
                let row = bytes + y * bytesPerRow
                for x in Swift.stride(from: 0, to: width, by: max(1, width / 32)) {
                    let offset = x * 4
                    sum += 0.114 * Double(row[offset]) + 0.587 * Double(row[offset + 1]) +
                        0.299 * Double(row[offset + 2])
                    count += 1
                }
            }
            return count > 0 ? sum / Double(count) : 0
        }
        return 0
    }

    func finish() {
        lock.lock()
        finished = true
        let saved = written
        let lumas = lumaSamples
        lock.unlock()
        queue.sync {}
        if saved.isEmpty {
            Log.warn("--save-frames: no frames were written")
        } else {
            let lumaText = lumas.map { String(format: "%.1f", $0) }.joined(separator: ",")
            Log.info("--save-frames done: \(saved.count) PNG in \(directory.path) " +
                     "[luma: \(lumaText)]")
        }
    }
}
