//
//  MJPEGHub.swift
//  HaloLink macOS host
//
//  Converts captured CVPixelBuffers to JPEG for the browser fallback.
//
//  Threading model (important: capture must never block on JPEG encoding):
//   * `submit(_:)` is called from the ScreenCaptureKit capture queue. It only
//     stores the latest pixel buffer reference (dropping older ones) and wakes a
//     single background worker.
//   * The worker takes the newest frame, encodes one JPEG per distinct
//     (width, quality) variant requested by connected browsers, and publishes the
//     JPEG into each client's "latest frame" slot.
//   * Each HTTP client has its own timer and only reads its slot, so a slow
//     client can never stall capture or other clients.
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

final class MJPEGClient {
    let id = UUID()
    let requestedWidth: Int
    let quality: Double
    let fps: Int

    private let lock = NSLock()
    private var pendingJPEG: Data?
    private var pendingSeq: Int64 = 0
    private var sentSeq: Int64 = 0

    init(requestedWidth: Int, quality: Double, fps: Int) {
        self.requestedWidth = requestedWidth
        self.quality = quality
        self.fps = fps
    }

    fileprivate func publish(_ jpeg: Data, seq: Int64) {
        lock.lock()
        pendingJPEG = jpeg
        pendingSeq = seq
        lock.unlock()
    }

    /// Returns the newest JPEG if it has not been sent yet, otherwise nil.
    func takeIfNew() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard pendingSeq > sentSeq, let data = pendingJPEG else { return nil }
        sentSeq = pendingSeq
        return data
    }

    var variantKey: VariantKey { VariantKey(width: requestedWidth, quality: quality) }

    struct VariantKey: Hashable {
        let width: Int
        let quality: Double
    }
}

final class MJPEGHub {
    var defaultWidth: Int
    var defaultQuality: Double

    /// Called on the MJPEG worker queue once per encoded JPEG (statistics only).
    var onJPEGEncoded: (() -> Void)?

    private let clientsLock = NSLock()
    private var clients: [MJPEGClient] = []

    private let stateLock = NSLock()
    private var pendingBuffer: CVPixelBuffer?
    private var pendingSeq: Int64 = 0
    private var frameSeq: Int64 = 0
    private var working = false
    private var stopped = false

    private let workQueue = DispatchQueue(label: "com.halolink.mjpeg", qos: .userInitiated)
    private let statsLock = NSLock()
    private var encodedJPEGs = 0
    private var lastJPEGBytes = 0
    private var totalJPEGBytes = 0
    private var lastEncodeMilliseconds = 0.0
    private var lastFrameWidth = 0
    private var lastFrameHeight = 0
    private var rateWindowStart = Clock.now()
    private var rateWindowFrames = 0
    private var rateWindowBytes = 0
    private var cachedJPEGFPS: Double = 0
    private var cachedJPEGKbps: Double = 0

    /// Maximum number of distinct downscale variants encoded per frame.
    private let maxVariants = 4
    /// Cap concurrent MJPEG viewers so a browser/tab reconnect storm cannot
    /// exhaust CPU or sockets.
    static let maxClients = 8

    init(defaultWidth: Int, defaultQuality: Double) {
        self.defaultWidth = max(160, defaultWidth)
        self.defaultQuality = min(max(0.1, defaultQuality), 0.95)
    }

    // MARK: - Client registration

    /// Returns nil when the server already has `maxClients` MJPEG viewers.
    func registerClient(width: Int?, quality: Double?, fps: Int?) -> MJPEGClient? {
        let resolvedWidth = min(max(160, width ?? defaultWidth), 3840)
        let resolvedQuality = min(max(0.1, quality ?? defaultQuality), 0.95)
        let resolvedFPS = max(1, min(60, fps ?? 30))
        let client = MJPEGClient(requestedWidth: resolvedWidth,
                                 quality: (resolvedQuality * 100).rounded() / 100,
                                 fps: resolvedFPS)
        clientsLock.lock()
        guard clients.count < Self.maxClients else {
            let count = clients.count
            clientsLock.unlock()
            Log.warn("rejecting /mjpg client: \(count)/\(Self.maxClients) already connected")
            return nil
        }
        clients.append(client)
        let count = clients.count
        clientsLock.unlock()
        Log.info("mjpg client +1: w=\(resolvedWidth) q=\(String(format: "%.2f", resolvedQuality)) " +
                 "fps=\(resolvedFPS) (clients=\(count))")
        return client
    }

    func removeClient(_ client: MJPEGClient) {
        clientsLock.lock()
        clients.removeAll { $0 === client }
        let count = clients.count
        clientsLock.unlock()
        Log.info("mjpg client -1 (clients=\(count))")
    }

    var clientCount: Int {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.count
    }

    // MARK: - Frame intake

    /// Called from the capture queue for each frame. Never blocks.
    func submit(_ pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        let shouldConsider = !stopped
        stateLock.unlock()
        guard shouldConsider, clientCount > 0 else { return }

        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        pendingBuffer = pixelBuffer
        pendingSeq += 1
        let shouldStart = !working
        if shouldStart { working = true }
        stateLock.unlock()

        if shouldStart {
            workQueue.async { [weak self] in
                self?.processLoop()
            }
        }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        pendingBuffer = nil
        stateLock.unlock()
        clientsLock.lock()
        clients.removeAll()
        clientsLock.unlock()
    }

    /// Re-enables the hub for a new streaming session.
    func resume() {
        stateLock.lock()
        stopped = false
        pendingBuffer = nil
        stateLock.unlock()
    }

    var lastFrameInfo: (bytes: Int, encodeMs: Double, width: Int, height: Int, seq: Int64) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (lastJPEGBytes, lastEncodeMilliseconds, lastFrameWidth, lastFrameHeight, frameSeq)
    }

    var jpegCount: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return encodedJPEGs
    }

    /// MJPEG output rate as seen by the browser (the web page cannot measure this
    /// itself because a multipart <img> stream has no per-frame JS event).
    struct RateSnapshot {
        let fps: Double
        let kbps: Double
        let totalFrames: Int
        let totalBytes: Int
    }

    var rateSnapshot: RateSnapshot {
        statsLock.lock()
        defer { statsLock.unlock() }
        return RateSnapshot(fps: cachedJPEGFPS, kbps: cachedJPEGKbps,
                            totalFrames: encodedJPEGs, totalBytes: totalJPEGBytes)
    }

    // MARK: - Worker

    private func processLoop() {
        while true {
            stateLock.lock()
            guard let buffer = pendingBuffer else {
                working = false
                stateLock.unlock()
                return
            }
            let seq = pendingSeq
            pendingBuffer = nil
            stateLock.unlock()

            encodePass(buffer, seq: seq)
        }
    }

    private func encodePass(_ pixelBuffer: CVPixelBuffer, seq: Int64) {
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        guard bufferWidth > 0 else { return }
        clientsLock.lock()
        let snapshot = clients
        clientsLock.unlock()
        guard !snapshot.isEmpty else { return }

        // Group clients into at most `maxVariants` distinct downscale settings.
        var groups: [MJPEGClient.VariantKey: [MJPEGClient]] = [:]
        var order: [MJPEGClient.VariantKey] = []
        for client in snapshot {
            var key = MJPEGClient.VariantKey(width: min(client.requestedWidth, bufferWidth),
                                             quality: client.quality)
            if groups[key] == nil && groups.count >= maxVariants {
                // Reuse the closest already-selected variant instead of encoding
                // yet another size for this frame.
                let nearest = order.min {
                    abs($0.width - key.width) < abs($1.width - key.width)
                } ?? order[0]
                key = nearest
            }
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key]?.append(client)
        }

        let started = Clock.now()
        var lastBytes = 0
        var lastWidth = 0
        var lastHeight = 0
        for key in order {
            guard let jpeg = Self.encodeJPEG(pixelBuffer, targetWidth: key.width,
                                             quality: key.quality) else {
                continue
            }
            lastBytes = jpeg.count
            lastWidth = min(key.width, bufferWidth)
            lastHeight = Int((Double(CVPixelBufferGetHeight(pixelBuffer)) *
                              Double(lastWidth) / Double(bufferWidth)).rounded())
            for client in groups[key] ?? [] {
                client.publish(jpeg, seq: seq)
            }
        }
        let elapsed = (Clock.now() - started) * 1000.0
        statsLock.lock()
        encodedJPEGs += 1
        lastJPEGBytes = lastBytes
        totalJPEGBytes += lastBytes
        lastEncodeMilliseconds = elapsed
        lastFrameWidth = lastWidth
        lastFrameHeight = lastHeight
        frameSeq = seq
        // Rolling 1 second window for the HUD.
        rateWindowFrames += 1
        rateWindowBytes += lastBytes
        let now = Clock.now()
        let window = now - rateWindowStart
        if window >= 1.0 {
            cachedJPEGFPS = Double(rateWindowFrames) / window
            cachedJPEGKbps = Double(rateWindowBytes) * 8.0 / 1000.0 / window
            rateWindowStart = now
            rateWindowFrames = 0
            rateWindowBytes = 0
        }
        statsLock.unlock()
        onJPEGEncoded?()
    }

    // MARK: - JPEG encoding

    static func encodeJPEG(_ pixelBuffer: CVPixelBuffer, targetWidth: Int,
                           quality: Double) -> Data? {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil,
                                                      imageOut: &cgImage)
        guard status == noErr, let image = cgImage, image.width > 0, image.height > 0 else {
            return nil
        }
        let sourceWidth = image.width
        let sourceHeight = image.height
        let width = max(160, min(targetWidth, sourceWidth))
        let height = max(2, Int((Double(sourceHeight) * Double(width) / Double(sourceWidth))
                                    .rounded()))
        var finalImage = image
        if width != sourceWidth || height != sourceHeight {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else {
                return nil
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            finalImage = scaled
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality as String: quality]
        CGImageDestinationAddImage(destination, finalImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
