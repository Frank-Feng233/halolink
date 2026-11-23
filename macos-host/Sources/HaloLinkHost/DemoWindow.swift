//
//  DemoWindow.swift
//  HaloLink macOS host
//
//  Optional --demo window: a clock + colour bars shown on the virtual display.
//  Useful for screenshots and for verifying that the extended desktop is alive
//  and being captured (also keeps ScreenCaptureKit producing frames).
//

import AppKit
import CoreGraphics
import Foundation

final class DemoWindowController {
    private var window: NSWindow?
    private var timer: Timer?

    init?(displayID: CGDirectDisplayID) {
        guard displayID != 0 else { return nil }
        let cgBounds = CGDisplayBounds(displayID)
        guard cgBounds.width > 0, cgBounds.height > 0 else { return nil }
        let cocoaRect = Self.cocoaRect(fromCG: cgBounds)
        let window = NSWindow(contentRect: cocoaRect, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.08, alpha: 1)
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = false
        window.contentView = DemoView(frame: NSRect(origin: .zero, size: cocoaRect.size))
        window.setFrame(cocoaRect, display: true)
        self.window = window

        // ~10 fps: keeps ScreenCaptureKit producing frames (it is change driven) and
        // makes the demo/recordings smooth without measurable CPU cost.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.window?.contentView?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func show() {
        window?.orderFrontRegardless()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    func reposition(to cgBounds: CGRect) {
        guard let window = window, cgBounds.width > 0, cgBounds.height > 0 else { return }
        window.setFrame(Self.cocoaRect(fromCG: cgBounds), display: true)
    }

    /// Converts a CoreGraphics global rect (top-left origin, y down) into AppKit
    /// screen coordinates (bottom-left origin, y up, relative to the main screen).
    static func cocoaRect(fromCG rect: CGRect) -> NSRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return NSRect(x: rect.origin.x, y: mainHeight - rect.origin.y - rect.size.height,
                      width: rect.size.width, height: rect.size.height)
    }
}

final class DemoView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        // Background
        NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.08, alpha: 1).setFill()
        bounds.fill()

        // Colour bars across the top
        let colors: [NSColor] = [
            .white, .yellow, .cyan, .green, .magenta, .red, .blue
        ]
        let barHeight = bounds.height * 0.22
        let barWidth = bounds.width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: CGFloat(index) * barWidth, y: bounds.height - barHeight,
                   width: barWidth + 1, height: barHeight).fill()
        }

        // Gradient strip below the bars
        let gradientRect = NSRect(x: 0, y: bounds.height - barHeight * 1.35,
                                  width: bounds.width, height: barHeight * 0.35)
        if let gradient = NSGradient(colors: [.black, .white]) {
            gradient.draw(in: gradientRect, angle: 0)
        }

        // Big clock + labels in the centre
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let clock = formatter.string(from: Date())
        let clockFontSize = max(28, bounds.height * 0.18)
        let clockAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: clockFontSize, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.42, green: 0.95, blue: 0.86, alpha: 1)
        ]
        let clockSize = (clock as NSString).size(withAttributes: clockAttributes)
        (clock as NSString).draw(at: NSPoint(x: (bounds.width - clockSize.width) / 2,
                                             y: bounds.height * 0.48),
                                 withAttributes: clockAttributes)

        let subtitle = "HaloLink — 扩展屏 / Extended Display"
        let subtitleFontSize = max(14, bounds.height * 0.045)
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: subtitleFontSize, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)
        ]
        let subtitleSize = (subtitle as NSString).size(withAttributes: subtitleAttributes)
        (subtitle as NSString).draw(at: NSPoint(x: (bounds.width - subtitleSize.width) / 2,
                                                y: bounds.height * 0.36),
                                    withAttributes: subtitleAttributes)

        let details = String(format: "%dx%d px · main display stays on the Mac",
                             Int(bounds.width), Int(bounds.height))
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(11, bounds.height * 0.03),
                                               weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)
        ]
        let detailSize = (details as NSString).size(withAttributes: detailAttributes)
        (details as NSString).draw(at: NSPoint(x: (bounds.width - detailSize.width) / 2,
                                               y: bounds.height * 0.28),
                                   withAttributes: detailAttributes)

        // Animated marker so the stream always has something to encode.
        let phase = Date().timeIntervalSinceReferenceDate
        let markerX = bounds.width * 0.5 + CGFloat(cos(phase * 0.8)) * bounds.width * 0.28
        let markerY = bounds.height * 0.16 + CGFloat(sin(phase * 1.3)) * bounds.height * 0.04
        NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.2, alpha: 1).setFill()
        NSRect(x: markerX, y: markerY, width: bounds.width * 0.03,
               height: bounds.width * 0.03).fill()
    }
}
