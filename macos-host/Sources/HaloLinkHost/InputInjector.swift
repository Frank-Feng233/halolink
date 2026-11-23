//
//  InputInjector.swift
//  HaloLink macOS host
//
//  Injects tablet touch/keyboard events into macOS as real HID events.
//
//  Key facts (verified against Apple docs + empirical tests):
//   * Events must be posted to `.cghidEventTap`; `.cgSessionEventTap` gets filtered
//     and will not reach other apps.
//   * CG global coordinates are top-left origin, y down, spanning all displays;
//     the virtual display's origin comes from the *runtime* CGDisplayBounds read
//     back after arrangement (macOS re-normalises positions).
//   * Accessibility (AXIsProcessTrusted) is required for cross-app injection;
//     without it CGEventPost silently does nothing — we log loudly.
//   * Text uses CGEventKeyboardSetUnicodeString so layout does not matter.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class InputInjector {
    private let queue = DispatchQueue(label: "com.halolink.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)
    private let boundsProvider: () -> CGRect

    private var leftButtonDown = false
    private var lastPoint: CGPoint?
    private var lastDownTime: TimeInterval = 0
    private var lastDownPoint: CGPoint = .zero
    private var clickCount: Int64 = 1
    private var heldKeys: [CGKeyCode: DispatchWorkItem] = [:]
    private(set) var axTrusted = false
    private var loggedUntrusted = false
    private var moveLogCounter = 0
    /// v1.1: input callback master switch (default OFF; UI/CLI toggles it).
    private var enabled = false
    private var disabledNoticeLogged = false

    var isEnabled: Bool {
        queue.sync { enabled }
    }

    func setEnabled(_ newValue: Bool) {
        queue.sync {
            guard enabled != newValue else { return }
            enabled = newValue
            disabledNoticeLogged = false
            if newValue {
                Log.info("input injection ENABLED by user")
            } else {
                Log.info("input injection DISABLED (control frames will be ignored)")
            }
        }
    }

    /// - Parameter boundsProvider: returns the current virtual display bounds in
    ///   global CG coordinates. Read on every event so re-arrangement is picked up.
    init(boundsProvider: @escaping () -> CGRect) {
        self.boundsProvider = boundsProvider
    }

    // MARK: - Permissions

    @discardableResult
    func checkAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        axTrusted = trusted
        if !trusted {
            Log.warn("Accessibility permission is NOT granted for this process: touch/keyboard " +
                     "input will be injected but macOS will ignore it.")
            Log.warn("Fix: System Settings → Privacy & Security → Accessibility → enable " +
                     (Self.appName) + ", then relaunch.")
            if prompt {
                openAccessibilitySettings()
            }
        } else {
            Log.info("Accessibility permission granted (CGEvent injection enabled)")
        }
        return trusted
    }

    func openAccessibilitySettings() {
        Self.openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Static convenience for the GUI.
    static func openAccessibilitySettingsPane() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
        Log.info("opened System Settings pane: \(urlString)")
    }

    /// Name to show in permission guidance (bundle name when running as an .app).
    static var appName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return "HaloLink"
    }

    // MARK: - Control frame entry point

    /// Handles one CONTROL JSON object from the tablet (or from POST /input).
    func handle(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        if !isEnabled {
            if !disabledNoticeLogged {
                disabledNoticeLogged = true
                Log.info("ignoring tablet input frames: touch control is OFF " +
                         "(enable it in the HaloLink app or pass --input on)")
            }
            return
        }
        if Log.verbose, type != "touch" {
            Log.debug("input \(type): \(Self.describe(message))")
        }
        switch type {
        case "touch":
            handleTouch(message)
        case "scroll":
            let dx = Self.doubleValue(message["dx"]) ?? 0
            let dy = Self.doubleValue(message["dy"]) ?? 0
            injectScroll(dx: dx, dy: dy)
        case "key":
            handleKey(message)
        case "text":
            if let text = message["text"] as? String {
                typeText(text)
            }
        case "mouse": // optional convenience: pointer buttons
            handleMouse(message)
        default:
            // request_keyframe / stats / bye are handled by HostApp.
            break
        }
    }

    // MARK: - Coordinate mapping

    /// Maps normalized (0..1, top-left) tablet coordinates onto the virtual
    /// display's current global bounds.
    func globalPoint(x: Double, y: Double) -> CGPoint {
        let bounds = boundsProvider()
        guard bounds.width > 0, bounds.height > 0 else {
            return CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
        let clampedX = min(max(x, 0.0), 1.0)
        let clampedY = min(max(y, 0.0), 1.0)
        // Keep the last point *inside* the display: a coordinate exactly on the
        // right/bottom edge would otherwise be clamped by macOS to the adjacent
        // display, which showed up as an edge-tap offset on the tablet.
        let maxX = bounds.width > 1 ? bounds.width - 1 : bounds.width
        let maxY = bounds.height > 1 ? bounds.height - 1 : bounds.height
        return CGPoint(x: bounds.origin.x + min(CGFloat(clampedX) * bounds.width, maxX),
                       y: bounds.origin.y + min(CGFloat(clampedY) * bounds.height, maxY))
    }

    // MARK: - Touch / mouse

    private func handleTouch(_ message: [String: Any]) {
        guard let action = message["action"] as? String,
              let x = Self.doubleValue(message["x"]),
              let y = Self.doubleValue(message["y"]) else { return }
        let point = globalPoint(x: x, y: y)
        let pointerId = Int(Self.doubleValue(message["pointerId"]) ?? 0)
        guard pointerId == 0 else { return } // single pointer support on the Mac side
        if Log.verbose {
            let bounds = boundsProvider()
            let actionName = action
            if actionName != "move" {
                Log.debug(String(format: "input touch action=%@ normalized=(%.4f,%.4f) " +
                                "-> global=(%.1f,%.1f) bounds=(%.0f,%.0f,%.0fx%.0f)",
                                actionName as NSString, x, y, point.x, point.y,
                                bounds.origin.x, bounds.origin.y, bounds.size.width,
                                bounds.size.height))
            } else {
                moveLogCounter += 1
                if moveLogCounter % 30 == 0 {
                    Log.debug(String(format: "input touch action=move normalized=(%.4f,%.4f) " +
                                    "-> global=(%.1f,%.1f)", x, y, point.x, point.y))
                }
            }
        }
        warnIfUntrusted()
        queue.async { [weak self] in
            guard let self = self else { return }
            switch action {
            case "down":
                self.postMouseDown(at: point)
            case "move":
                self.postMouseMove(at: point, dragging: self.leftButtonDown)
            case "up":
                self.postMouseUp(at: point)
            case "cancel":
                if self.leftButtonDown { self.postMouseUp(at: self.lastPoint ?? point) }
            default:
                break
            }
        }
    }

    private func handleMouse(_ message: [String: Any]) {
        guard let action = message["action"] as? String,
              let x = Self.doubleValue(message["x"]),
              let y = Self.doubleValue(message["y"]) else { return }
        let point = globalPoint(x: x, y: y)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.postMouseMove(at: point, dragging: false)
            if action == "click" {
                self.postMouseDown(at: point)
                self.postMouseUp(at: point)
            }
        }
    }

    private func postMouseMove(at point: CGPoint, dragging: Bool) {
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: dragging ? .left : .left) else { return }
        if dragging {
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        }
        event.post(tap: .cghidEventTap)
        lastPoint = point
    }

    private func postMouseDown(at point: CGPoint) {
        let now = Clock.now()
        if now - lastDownTime < 0.4,
           hypot(point.x - lastDownPoint.x, point.y - lastDownPoint.y) < 4 {
            clickCount = min(clickCount + 1, 3)
        } else {
            clickCount = 1
        }
        lastDownTime = now
        lastDownPoint = point
        guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.post(tap: .cghidEventTap)
        leftButtonDown = true
        lastPoint = point
    }

    private func postMouseUp(at point: CGPoint) {
        guard leftButtonDown else {
            postMouseMove(at: point, dragging: false)
            return
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.post(tap: .cghidEventTap)
        leftButtonDown = false
        lastPoint = point
    }

    // MARK: - Scroll

    /// Two-finger scroll. `dx`/`dy` are pixel deltas following "natural" direction
    /// (finger moving up produces content moving up), matching trackpad defaults.
    func injectScroll(dx: Double, dy: Double) {
        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return }
        warnIfUntrusted()
        let location = lastPoint ?? CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX,
                                            y: CGDisplayBounds(CGMainDisplayID()).midY)
        let wheelY = Int32(max(-2000, min(2000, dy.rounded())))
        let wheelX = Int32(max(-2000, min(2000, dx.rounded())))
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let event = CGEvent(scrollWheelEvent2Source: self.source, units: .pixel,
                                      wheelCount: 2, wheel1: wheelY, wheel2: wheelX,
                                      wheel3: 0) else { return }
            event.location = location
            event.post(tap: .cghidEventTap)
            self.lastPoint = location
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ message: [String: Any]) {
        guard let keyName = message["key"] as? String else { return }
        let action = (message["action"] as? String) ?? "tap"
        var modifiers: CGEventFlags = []
        if let names = message["modifiers"] as? [String] {
            for name in names { modifiers.formUnion(Self.flag(for: name)) }
        }
        let parts = keyName.split(separator: "+").map { String($0) }
        var keyToken = keyName
        if parts.count > 1 {
            for part in parts.dropLast() { modifiers.formUnion(Self.flag(for: part)) }
            keyToken = parts.last ?? keyName
        }
        warnIfUntrusted()
        queue.async { [weak self] in
            guard let self = self else { return }
            if let flag = Self.modifierFlag(for: keyToken) {
                self.postModifier(flag, down: action != "up", extraFlags: modifiers)
                return
            }
            guard let keyCode = Self.keyCode(for: keyToken) else {
                Log.debug("unknown key from tablet: \(keyName)")
                return
            }
            switch action {
            case "up":
                self.postKey(keyCode, down: false, flags: modifiers)
                self.cancelAutoRelease(keyCode)
            case "down":
                self.postKey(keyCode, down: true, flags: modifiers)
                self.scheduleAutoRelease(keyCode, flags: modifiers)
            default: // tap
                self.postKey(keyCode, down: true, flags: modifiers)
                self.postKey(keyCode, down: false, flags: modifiers)
            }
        }
    }

    private func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode,
                                  keyDown: down) else { return }
        if !flags.isEmpty { event.flags = flags }
        event.post(tap: .cghidEventTap)
    }

    private func postModifier(_ flag: CGEventFlags, down: Bool, extraFlags: CGEventFlags) {
        // A standalone modifier event: use the matching left-side virtual key.
        let keyCode: CGKeyCode
        switch flag {
        case .maskCommand: keyCode = 55
        case .maskShift: keyCode = 56
        case .maskAlternate: keyCode = 58
        case .maskControl: keyCode = 59
        default: return
        }
        var flags = extraFlags
        if down { flags.insert(flag) } else { flags.remove(flag) }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode,
                                  keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Avoids a stuck key if the tablet's "up" event is lost (e.g. app killed).
    private func scheduleAutoRelease(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        cancelAutoRelease(keyCode)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                self.postKey(keyCode, down: false, flags: flags)
                self.heldKeys.removeValue(forKey: keyCode)
            }
        }
        heldKeys[keyCode] = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func cancelAutoRelease(_ keyCode: CGKeyCode) {
        heldKeys.removeValue(forKey: keyCode)?.cancel()
    }

    /// Types arbitrary text using Unicode keyboard events (layout independent).
    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        warnIfUntrusted()
        queue.async { [weak self] in
            guard let self = self else { return }
            let units = Array(text.utf16)
            var index = 0
            while index < units.count {
                // Keep surrogate pairs together (max 20 UTF-16 units per event).
                var length = 0
                var taken = 0
                while index + length < units.count && taken < 20 {
                    let unit = units[index + length]
                    let isHighSurrogate = unit >= 0xD800 && unit <= 0xDBFF
                    let pairLength = (isHighSurrogate && index + length + 1 < units.count) ? 2 : 1
                    if taken + pairLength > 20 && taken > 0 { break }
                    length += pairLength
                    taken += pairLength
                }
                if length == 0 { break }
                var chunk = Array(units[index..<(index + length)])
                guard let down = CGEvent(keyboardEventSource: self.source, virtualKey: 0,
                                         keyDown: true) else { break }
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
                var chunkUp = chunk
                guard let up = CGEvent(keyboardEventSource: self.source, virtualKey: 0,
                                       keyDown: false) else { break }
                up.keyboardSetUnicodeString(stringLength: chunkUp.count, unicodeString: &chunkUp)
                up.post(tap: .cghidEventTap)
                index += length
            }
        }
    }

    // MARK: - Tables

    private func warnIfUntrusted() {
        guard !axTrusted, !loggedUntrusted else { return }
        loggedUntrusted = true
        Log.warn("input injected without Accessibility permission — macOS will ignore it " +
                 "(System Settings → Privacy & Security → Accessibility → \(Self.appName))")
    }

    static func flag(for name: String) -> CGEventFlags {
        switch name.uppercased() {
        case "CMD", "COMMAND", "META", "SUPER", "WIN": return .maskCommand
        case "SHIFT": return .maskShift
        case "ALT", "OPTION", "OPT": return .maskAlternate
        case "CTRL", "CONTROL": return .maskControl
        default: return []
        }
    }

    static func modifierFlag(for token: String) -> CGEventFlags? {
        let flag = self.flag(for: token)
        return flag.isEmpty ? nil : flag
    }

    /// Compact, log-safe rendering of a control message (verbose diagnostics).
    static func describe(_ message: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: message),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(240))
        }
        return "\(message)"
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let double = any as? Double { return double }
        if let int = any as? Int { return Double(int) }
        if let number = any as? NSNumber { return number.doubleValue }
        return nil
    }

    static func keyCode(for token: String) -> CGKeyCode? {
        let upper = token.uppercased()
        if let code = specialKeys[upper] { return code }
        let lower = token.lowercased()
        if let code = characterKeys[lower] { return code }
        if token == " " { return 49 }
        return nil
    }

    /// US-layout virtual key codes.
    private static let characterKeys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50
    ]

    private static let specialKeys: [String: CGKeyCode] = [
        "ENTER": 36, "RETURN": 36, "KP_ENTER": 76,
        "TAB": 48, "SPACE": 49, "BACKSPACE": 51, "DELETE": 51, "DEL": 51,
        "ESCAPE": 53, "ESC": 53,
        "FORWARD_DELETE": 117, "FORWARDDELETE": 117,
        "HOME": 115, "END": 119, "PAGEUP": 116, "PAGE_UP": 116,
        "PAGEDOWN": 121, "PAGE_DOWN": 121,
        "LEFT": 123, "ARROWLEFT": 123, "RIGHT": 124, "ARROWRIGHT": 124,
        "DOWN": 125, "ARROWDOWN": 125, "UP": 126, "ARROWUP": 126,
        "CAPSLOCK": 57, "CAPS_LOCK": 57,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
        "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
        "MENU": 110, "PRINTSCREEN": 105
    ]
}
