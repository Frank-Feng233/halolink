#!/usr/bin/env swift
// HaloLink demo window: 在指定显示器（默认第二块）上显示一个时钟 + 测试图案窗口，
// 用于验证「扩展屏」与延迟/清晰度。
//
// 用法:
//   swift scripts/demo_window.swift                  # 放到第二块显示器（虚拟扩展屏）
//   swift scripts/demo_window.swift --display 1      # 指定 CGGetOnlineDisplayList 索引
//   swift scripts/demo_window.swift --list           # 列出所有显示器
//
// 需要 AppKit；无需任何权限（只创建自己的窗口）。

import AppKit
import CoreGraphics
import Foundation

func listDisplays() {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(16, &ids, &count)
    for (i, id) in ids.enumerated() {
        let b = CGDisplayBounds(id)
        print("[\(i)] displayID=\(id) bounds=(x:\(Int(b.origin.x)) y:\(Int(b.origin.y)) w:\(Int(b.width)) h:\(Int(b.height))) main=\(id == CGMainDisplayID())")
    }
}

func targetDisplayID(indexHint: Int?) -> CGDirectDisplayID {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(16, &ids, &count)
    if let i = indexHint, i < ids.count { return ids[i] }
    if ids.count > 1 {
        // 优先选非主屏
        return ids.first(where: { $0 != CGMainDisplayID() }) ?? ids[0]
    }
    return ids.isEmpty ? CGMainDisplayID() : ids[0]
}

let args = CommandLine.arguments
var indexHint: Int? = nil
if let i = args.firstIndex(of: "--list") { _ = i; listDisplays(); exit(0) }
if let i = args.firstIndex(of: "--display"), i + 1 < args.count { indexHint = Int(args[i + 1]) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let displayID = targetDisplayID(indexHint: indexHint)
let bounds = CGDisplayBounds(displayID)
print("[demo] 使用 displayID=\(displayID), bounds=\(bounds)")

let window = NSWindow(
    contentRect: NSRect(x: bounds.origin.x + 40, y: bounds.origin.y + 40,
                        width: max(800, bounds.width - 80), height: max(600, bounds.height - 80)),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered,
    defer: false)
window.title = "HaloLink 扩展屏测试图案"
window.isReleasedWhenClosed = false
window.level = .normal

final class DemoView: NSView {
    private var timer: Timer?
    private let start = Date()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let W = bounds.width, H = bounds.height
        // 彩色竖条（验证颜色/清晰度）
        let colors: [CGColor] = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                                 CGColor(red: 1, green: 1, blue: 0, alpha: 1),
                                 CGColor(red: 0, green: 1, blue: 1, alpha: 1),
                                 CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                                 CGColor(red: 1, green: 0, blue: 1, alpha: 1),
                                 CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                 CGColor(red: 0, green: 0, blue: 1, alpha: 1),
                                 CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        let bw = W / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: CGFloat(i) * bw, y: H * 0.72, width: bw, height: H * 0.28))
        }
        ctx.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H * 0.72))

        // 时钟 + 毫秒
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let t = f.string(from: now) + String(format: ".%03d", Int(now.timeIntervalSince1970 * 1000) % 1000)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(48, H * 0.10), weight: .bold),
            .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: t, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: (W - sz.width) / 2, y: H * 0.42))

        // 网格（检查缩放是否失真）
        ctx.setStrokeColor(CGColor(red: 0.25, green: 0.3, blue: 0.35, alpha: 1))
        ctx.setLineWidth(1)
        var x: CGFloat = 0
        while x < W { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H * 0.72)); x += 50 }
        var y: CGFloat = 0
        while y < H * 0.72 { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); y += 50 }
        ctx.strokePath()

        // 运行时长 + 分辨率
        let info = String(format: "运行 %.1fs · 窗口 %.0fx%.0f · displayID %u · HaloLink",
                          Date().timeIntervalSince(start), W, H, displayID)
        let ia: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(16, H * 0.025)),
            .foregroundColor: NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.6, alpha: 1)]
        NSAttributedString(string: info, attributes: ia)
            .draw(at: NSPoint(x: 24, y: H * 0.80))
    }
}

window.contentView = DemoView(frame: window.contentLayoutRect)
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()
app.run()
