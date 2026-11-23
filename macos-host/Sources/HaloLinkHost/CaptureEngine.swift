//
//  CaptureEngine.swift
//  HaloLink macOS host
//
//  ScreenCaptureKit capture of a single display (the virtual extended display, or
//  the main display in mirror/fallback mode).
//
//  Notes / pitfalls handled here:
//   * SCStream is change driven: a static desktop produces very few frames. We
//     keep the last frame in HostApp so it can be re-encoded as a fresh IDR when
//     a tablet client connects.
//   * For a HiDPI display SCDisplay.width/height are *points*, while the frames
//     are delivered at the requested pixel size — the capture size therefore
//     comes from the caller (mode pixel size), never from SCDisplay.
//   * NV12 (420v) is used: VideoToolbox consumes it directly (no BGRA->NV12
//     conversion) and it avoids full/limited-range colour surprises.
//

import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

protocol CaptureEngineDelegate: AnyObject {
    func captureEngine(_ engine: CaptureEngine, didOutput buffer: CVPixelBuffer, pts: CMTime)
    func captureEngine(_ engine: CaptureEngine, didFail message: String, fatal: Bool)
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var delegate: CaptureEngineDelegate?

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.halolink.capture",
                                             qos: .userInteractive)
    private let lifecycleQueue = DispatchQueue(label: "com.halolink.capture.lifecycle",
                                               qos: .userInitiated)
    private let stateLock = NSLock()
    private let contentTimeout: TimeInterval = 8.0
    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    private var running = false
    private var restarting = false
    private var warnedFrameStatus = false
    private var contentRectWarned = false
    private var frameCount = 0
    private var lastFrameArrival: TimeInterval = 0

    /// Parameters of the active capture, kept so the watchdog can restart the
    /// ScreenCaptureKit stream without the caller having to remember them.
    private var startDisplayID: CGDirectDisplayID = 0
    private var startFPS = 60
    private var startShowCursor = true

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    var capturedFrameCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return frameCount
    }

    /// Enumerates shareable content (synchronous with timeout). Requires the
    /// Screen Recording TCC permission; throws a descriptive error otherwise.
    static func shareableContent(timeout: TimeInterval = 8.0) throws -> SCShareableContent {
        var contentResult: Result<SCShareableContent, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
            content, error in
            if let error = error {
                contentResult = .failure(error)
            } else if let content = content {
                contentResult = .success(content)
            } else {
                contentResult = .failure(HaloLinkError("SCShareableContent returned no content"))
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw HaloLinkError("timed out after \(Int(timeout))s waiting for " +
                                "SCShareableContent (Screen Recording permission?)")
        }
        switch contentResult {
        case .success(let content): return content
        case .failure(let error): throw error
        case .none: throw HaloLinkError("SCShareableContent produced no result")
        }
    }

    func start(displayID: CGDirectDisplayID,
               pixelWidth: Int,
               pixelHeight: Int,
               fps: Int,
               showCursor: Bool) throws {
        guard !isRunning else { return }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        startDisplayID = displayID
        startFPS = max(1, fps)
        startShowCursor = showCursor
        try performStart()
    }

    private func performStart() throws {
        let displayID = startDisplayID
        let pixelWidth = self.pixelWidth
        let pixelHeight = self.pixelHeight
        let fps = startFPS
        let showCursor = startShowCursor

        let content = try Self.shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            let available = content.displays
                .map { "\($0.displayID)(\($0.width)x\($0.height)pt)" }
                .joined(separator: ", ")
            throw HaloLinkError("display \(displayID) not present in SCShareableContent " +
                                "[\(available)]")
        }
        Log.debug("SCShareableContent: \(content.displays.count) display(s), " +
                  "\(content.windows.count) window(s)")
        Log.debug("capture source SCDisplay id=\(display.displayID) " +
                  "points=\(display.width)x\(display.height) requestedPixels=\(pixelWidth)x\(pixelHeight)")

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.minimumFrameInterval = CMTime(value: 1,
                                                    timescale: CMTimeScale(max(1, fps)))
        configuration.queueDepth = 2
        configuration.showsCursor = showCursor
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.shouldBeOpaque = true

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        newStream.startCapture { error in
            startError = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10.0) == .timedOut {
            throw HaloLinkError("SCStream.startCapture timed out")
        }
        if let error = startError {
            throw HaloLinkError("SCStream.startCapture failed: \(error.localizedDescription)")
        }
        self.stream = newStream
        stateLock.lock()
        running = true
        frameCount = 0
        lastFrameArrival = Clock.now()
        stateLock.unlock()
        Log.info("capture started: displayID=\(displayID) " +
                 "\(pixelWidth)x\(pixelHeight)px @\(fps)fps NV12 queueDepth=2 (low-latency)")
    }

    /// Internal stop without logging/spam; safe to call when not running.
    private func performStop() {
        stateLock.lock()
        let stream = self.stream
        self.stream = nil
        running = false
        stateLock.unlock()
        guard let stream = stream else { return }
        let semaphore = DispatchSemaphore(value: 0)
        stream.stopCapture { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + 3.0) == .timedOut {
            Log.warn("SCStream.stopCapture timed out; continuing shutdown")
        }
    }

    func stop() {
        performStop()
        Log.info("capture stopped")
    }

    /// Tears down and re-creates the SCStream in the background. Used by the
    /// capture watchdog when ScreenCaptureKit stops delivering frames (observed
    /// after long idle periods / App Nap before this was worked around).
    func restartInBackground(reason: String,
                             completion: ((Bool) -> Void)? = nil) {
        lifecycleQueue.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            if self.restarting || self.startDisplayID == 0 {
                self.stateLock.unlock()
                completion?(false)
                return
            }
            self.restarting = true
            self.stateLock.unlock()

            Log.warn("restarting ScreenCaptureKit capture (\(reason)) …")
            self.performStop()
            // Give the capture daemon a moment to tear the old stream down.
            Thread.sleep(forTimeInterval: 0.5)
            var success = false
            do {
                try self.performStart()
                success = true
                Log.info("ScreenCaptureKit capture restarted successfully")
            } catch {
                Log.error("capture restart failed: \(error.localizedDescription)")
            }
            self.stateLock.lock()
            self.restarting = false
            self.stateLock.unlock()
            if let completion = completion {
                DispatchQueue.main.async { completion(success) }
            }
        }
    }

    /// Seconds since the last delivered frame (-1 when not running).
    var secondsSinceLastFrame: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running, lastFrameArrival > 0 else { return -1 }
        return Clock.now() - lastFrameArrival
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, isRunning else { return }
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first else {
            return
        }
        if let rawStatus = info[.status] as? Int {
            let status = SCFrameStatus(rawValue: rawStatus)
            if status != .complete {
                if !warnedFrameStatus && status != .idle {
                    Log.debug("dropping SCK frame status=\(status.map(String.init(describing:)) ?? "?" )")
                    warnedFrameStatus = true
                }
                return
            }
        }
        if let contentRect = info[.contentRect] as? CGRect {
            let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            let full = CGRect(x: 0, y: 0, width: width, height: height)
            if !full.equalTo(contentRect.insetBy(dx: -1, dy: -1)) && !contentRectWarned {
                Log.debug("SCK contentRect=\(contentRect) buffer=\(full) " +
                          "(display capture normally yields the full frame)")
                contentRectWarned = true
            }
        }
        stateLock.lock()
        frameCount += 1
        lastFrameArrival = Clock.now()
        stateLock.unlock()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        delegate?.captureEngine(self, didOutput: pixelBuffer, pts: pts)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()
        guard wasRunning else { return }
        let nsError = error as NSError
        var message = "SCStream stopped: \(error.localizedDescription) (domain=\(nsError.domain) code=\(nsError.code))"
        if nsError.code == -3801 || nsError.domain == SCStreamErrorDomain {
            message += " — this usually means the Screen Recording permission was revoked"
        }
        delegate?.captureEngine(self, didFail: message, fatal: true)
    }
}

struct HaloLinkError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
