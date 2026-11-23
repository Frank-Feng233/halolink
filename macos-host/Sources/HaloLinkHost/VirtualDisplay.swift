//
//  VirtualDisplay.swift
//  HaloLink macOS host
//
//  Manages the CGVirtualDisplay-backed extended display: creation via the
//  ObjC bridge (CVirtualDisplay target), placement to the right of the main
//  display, HiDPI verification, main-display safety net and teardown.
//

import AppKit
import CoreGraphics
import Foundation
import CVirtualDisplay

struct DisplayModeSnapshot {
    var pointWidth: UInt32 = 0
    var pointHeight: UInt32 = 0
    var pixelWidth: UInt32 = 0
    var pixelHeight: UInt32 = 0
    var refreshRate: Double = 0

    var isHiDPI: Bool { pixelWidth > pointWidth || pixelHeight > pointHeight }
    var description: String {
        "mode=\(pointWidth)x\(pointHeight) pixels=\(pixelWidth)x\(pixelHeight) " +
        String(format: "refresh=%.0fHz", refreshRate) + " hidpi=\(isHiDPI ? "yes(2x)" : "no(1x)")"
    }
}

final class VirtualDisplay {
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var requestedPixelWidth: UInt32 = 0
    private(set) var requestedPixelHeight: UInt32 = 0
    private(set) var maximumPixelWidth: UInt32 = 0
    private(set) var maximumPixelHeight: UInt32 = 0
    private(set) var mode: DisplayModeSnapshot?
    /// Retained CGDisplayMode handles for in-process 1x <-> 2x switching.
    private var hiDPIModeRef: UnsafeMutableRawPointer?
    private var native1xModeRef: UnsafeMutableRawPointer?

    var isActive: Bool { displayID != 0 }
    var bounds: CGRect { displayID != 0 ? CGDisplayBounds(displayID) : .zero }

    static var isSupported: Bool { hd_virtual_display_available() != 0 }

    /// Returns the displayID of an already-online HaloLink virtual display (e.g.
    /// owned by another HaloLink instance), or 0. Used for a clear error message:
    /// two instances cannot own the same virtual display signature.
    static func existingHaloLinkDisplay() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return 0 }
        for index in 0..<Int(count) where
            CGDisplayVendorNumber(ids[index]) == hd_virtual_display_vendor_id() {
            return ids[index]
        }
        return 0
    }

    // MARK: - Creation

    /// Creates the virtual display. Returns true on success.
    /// - Parameters:
    ///   - pixelWidth/Height: framebuffer size of the initial mode.
    ///   - logicalWidth/Height: desktop point size (pixel/2 for 2x; == pixel for 1x).
    ///   - maxPixelWidth/Height: framebuffer capacity, must cover every orientation
    ///     and size the display may be reconfigured to at runtime (rotation,
    ///     --scale-match-main). Modes can never exceed this capacity.
    /// - When `hidpi != .off` a physical-anchor mode + a half-size logical mode are
    ///   declared with hiDPI=1. Some aspect ratios silently fall back to 1x; callers
    ///   inspect `mode` afterwards and report the *actual* mode in the protocol config.
    func create(pixelWidth: UInt32, pixelHeight: UInt32,
                logicalWidth: UInt32, logicalHeight: UInt32,
                maxPixelWidth: UInt32, maxPixelHeight: UInt32,
                refresh: Int, hidpi: HIDPIOption, name: String) -> Bool {
        guard Self.isSupported else {
            Log.error("private CGVirtualDisplay API is not available in this macOS build")
            return false
        }
        let wantHiDPI = hidpi != .off && pixelWidth % 2 == 0 && pixelHeight % 2 == 0
        let logicalW = wantHiDPI ? logicalWidth : pixelWidth
        let logicalH = wantHiDPI ? logicalHeight : pixelHeight

        let created = hd_create_virtual_display_ext(
            pixelWidth, pixelHeight, logicalW, logicalH,
            max(maxPixelWidth, pixelWidth), max(maxPixelHeight, pixelHeight),
            Double(refresh), wantHiDPI ? 1 : 0, name)
        guard created != 0 else {
            let reason = String(cString: hd_last_error())
            Log.error("virtual display creation failed: \(reason.isEmpty ? "unknown error" : reason)")
            return false
        }
        displayID = created
        requestedPixelWidth = pixelWidth
        requestedPixelHeight = pixelHeight
        maximumPixelWidth = max(maxPixelWidth, pixelWidth)
        maximumPixelHeight = max(maxPixelHeight, pixelHeight)
        var maxW: UInt32 = 0
        var maxH: UInt32 = 0
        if hd_virtual_display_max_pixels(&maxW, &maxH) != 0 {
            maximumPixelWidth = maxW
            maximumPixelHeight = maxH
        }
        // WindowServer registers the display asynchronously; with a larger
        // framebuffer capacity the first CGDisplayCopyDisplayMode call can still be
        // NULL. Wait briefly before reading the initial mode.
        // Registration is asynchronous; the mode may not be readable yet. The
        // caller finalises the display once the app's run loop has processed the
        // display-added notification.
        mode = Self.modeInfo(for: created)
        captureModeHandles(after: 0.0)
        Log.info(String(format: "virtual display created: id=%u capacity=%ux%u " +
                        "(mode ready=%@)", created, maximumPixelWidth, maximumPixelHeight,
                        (mode != nil ? "yes" : "pending") as NSString))
        return true
    }

    /// Ensures the current mode has the requested pixel size, forcing an explicit
    /// mode selection (same-process only) when WindowServer did not auto-switch.
    /// Must be followed by asynchronous polling by the caller.
    @discardableResult
    func ensureMode(pixelWidth: UInt32, pixelHeight: UInt32) -> Bool {
        guard displayID != 0 else { return false }
        if let mode = refreshMode(), mode.pixelWidth == pixelWidth,
           mode.pixelHeight == pixelHeight {
            return true
        }
        return forceSelectMode(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                               refresh: Int(mode?.refreshRate ?? 60))
    }

    /// Caches the current (2x) mode and the 1x mode for later switching. The 2x
    /// mode of a virtual display is not exposed in the public mode list, so it must
    /// be captured while active.
    func captureModeHandles(after delay: TimeInterval = 0.0) {
        let capture = { [weak self] in
            guard let self = self, self.displayID != 0 else { return }
            if self.hiDPIModeRef == nil, let current = Self.modeInfo(for: self.displayID),
               current.isHiDPI {
                self.hiDPIModeRef = hd_copy_current_mode(self.displayID)
            }
            if self.native1xModeRef == nil {
                let pixel = self.mode ?? Self.modeInfo(for: self.displayID)
                if let pixel = pixel {
                    self.native1xModeRef = hd_copy_1x_mode(self.displayID,
                                                          pixel.pixelWidth,
                                                          pixel.pixelHeight)
                }
            }
            if Log.verbose {
                Log.debug("mode handles: 2x=\(self.hiDPIModeRef != nil ? "cached" : "none") " +
                          "1x=\(self.native1xModeRef != nil ? "cached" : "none")")
            }
        }
        if delay <= 0 {
            capture()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: capture)
        }
    }

    /// Re-captures both mode handles (call after the mode/server configuration
    /// changed, e.g. after a rotation reconfiguration).
    func refreshModeHandles() {
        if let ref = hiDPIModeRef { hd_release_mode(ref) }
        if let ref = native1xModeRef { hd_release_mode(ref) }
        hiDPIModeRef = nil
        native1xModeRef = nil
        captureModeHandles()
    }

    /// Whether a retained mode handle for the requested backing scale is cached.
    func hasModeHandle(retina: Bool) -> Bool {
        retina ? (hiDPIModeRef != nil) : (native1xModeRef != nil)
    }

    /// Switches the display between its 2x and 1x mode using retained mode handles
    /// (works in-process; the display object is not recreated).
    @discardableResult
    func switchRenderMode(retina: Bool) -> Bool {
        guard displayID != 0 else { return false }
        var ref = retina ? hiDPIModeRef : native1xModeRef
        if ref == nil {
            captureModeHandles()
            ref = retina ? hiDPIModeRef : native1xModeRef
        }
        if ref == nil, !retina, let current = Self.modeInfo(for: displayID) {
            // Last resort: try the public mode list.
            ref = hd_copy_1x_mode(displayID, current.pixelWidth, current.pixelHeight)
            native1xModeRef = ref
        }
        guard let target = ref else {
            Log.warn("no cached \(retina ? "2x" : "1x") mode handle for display \(displayID)")
            return false
        }
        let result = hd_set_mode_ref(displayID, target)
        Log.info("switching display \(displayID) to \(retina ? "2x HiDPI" : "1x") mode: " +
                 "CGError \(result)")
        return result == 0
    }

    /// Waits until the display has a readable mode (WindowServer registers a new
    /// virtual display asynchronously and needs the main run loop to process the
    /// notification; a plain sleep would block that, so we pump the run loop).
    @discardableResult
    func waitForModeReady(timeout: TimeInterval) -> DisplayModeSnapshot? {
        let deadline = Clock.now() + timeout
        while Clock.now() < deadline {
            if let snapshot = Self.modeInfo(for: displayID) {
                mode = snapshot
                return snapshot
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        mode = Self.modeInfo(for: displayID)
        return mode
    }

    /// Dumps the mode ladder for diagnostics (verbose).
    func debugDumpModes() {
        guard Log.verbose, let modes = CGDisplayCopyAllDisplayModes(displayID, nil)
                as? [CGDisplayMode] else { return }
        Log.debug("display \(displayID) modes (\(modes.count)):")
        for mode in modes {
            Log.debug(String(format: "  %ux%u px=%ux%u %.0fHz", mode.width, mode.height,
                             mode.pixelWidth, mode.pixelHeight, mode.refreshRate))
        }
    }

    /// Logical (point) size of the currently active mode.
    func currentLogicalSize() -> (width: UInt32, height: UInt32) {
        guard let mode = refreshMode() else { return (0, 0) }
        return (mode.pointWidth, mode.pointHeight)
    }

    /// Uses the ObjC bridge to find an online display matching our signature.
    func findExisting(width: UInt32, height: UInt32) -> Bool {
        let found = hd_find_virtual_display_id(width, height)
        guard found != 0 else { return false }
        displayID = found
        requestedPixelWidth = width
        requestedPixelHeight = height
        mode = Self.modeInfo(for: found)
        Log.info("attached to existing virtual display id=\(found) " +
                 "(\(mode?.description ?? "mode unknown"))")
        return true
    }

    // MARK: - Placement

    /// Places the virtual display to the right of the main display, clears any
    /// mirroring relationship and returns the *actual* bounds after the change.
    /// macOS may re-normalise the arrangement, so the read-back value is
    /// authoritative for input coordinate mapping.
    @discardableResult
    func placeRightOfMain() -> CGRect {
        guard displayID != 0 else { return .zero }
        _ = hd_ensure_physical_stays_main(displayID)

        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)
        let originX = Int32(mainBounds.origin.x + mainBounds.size.width)
        let originY = Int32(mainBounds.origin.y)

        // Prefer the mode we actually ended up in (keeps a 2x mode intact); if the
        // current mode is not the requested pixel size, try to select the right one.
        var targetW = requestedPixelWidth
        var targetH = requestedPixelHeight
        if let mode = mode, mode.pixelWidth > 0, mode.pixelHeight > 0,
           mode.pixelWidth != targetW || mode.pixelHeight != targetH {
            targetW = mode.pixelWidth
            targetH = mode.pixelHeight
        }
        let err = hd_configure_display(displayID, targetW, targetH, Double(mode?.refreshRate ?? 60),
                                       originX, originY, 1, 1)
        if err != 0 {
            let reason = String(cString: hd_last_error())
            Log.warn("display configuration returned \(err) (\(reason.isEmpty ? "?" : reason)); " +
                     "continuing with current arrangement")
        }
        if CGMainDisplayID() == displayID {
            let repaired = hd_ensure_physical_stays_main(displayID) != 0
            Log.warn("virtual display became the main display; repair \(repaired ? "applied" : "failed")")
        }
        let actual = bounds
        let mirrored = CGDisplayIsInMirrorSet(displayID) != 0
        Log.info(String(format: "virtual display placed at origin=(%.0f,%.0f) size=%.0fx%.0f " +
                        "(requested x=%d) mirrored=%@ main=%u",
                        actual.origin.x, actual.origin.y, actual.size.width,
                        actual.size.height, originX, mirrored ? "yes" : "no",
                        CGMainDisplayID()))
        return actual
    }

    /// Runtime reconfiguration step 1 (used by --auto when the tablet announces a
    /// different panel size): adds the new modes to the *existing* display object
    /// and returns whether WindowServer accepted the request.
    ///
    /// IMPORTANT: while the app is running inside NSApplication.run(), WindowServer
    /// applies the new mode asynchronously and only when the run loop iterates
    /// normally. Callers must NOT block/poll synchronously (a nested run loop
    /// starves the display-configuration update and the mode never changes — this
    /// was verified with a standalone probe). Poll with DispatchQueue.main.asyncAfter
    /// and use `refreshMode()`.
    func beginAdjust(width: UInt32, height: UInt32, refresh: Int,
                     hidpi: HIDPIOption) -> Bool {
        guard displayID != 0 else { return false }
        let tryHiDPI = hidpi != .off && width % 2 == 0 && height % 2 == 0
        let logicalWidth = tryHiDPI ? width / 2 : width
        let logicalHeight = tryHiDPI ? height / 2 : height
        let applied = hd_apply_virtual_display_settings(
            width, height, logicalWidth, logicalHeight, Double(refresh),
            tryHiDPI ? 1 : 0)
        guard applied != 0 else {
            Log.warn("runtime display reconfiguration to \(width)x\(height) failed: " +
                     String(cString: hd_last_error()))
            return false
        }
        requestedPixelWidth = width
        requestedPixelHeight = height
        return true
    }

    /// Re-reads the current display mode (call from the async poll loop).
    @discardableResult
    func refreshMode() -> DisplayModeSnapshot? {
        mode = Self.modeInfo(for: displayID)
        return mode
    }

    /// Tries to force the requested mode explicitly (owner process only). Used as
    /// a fallback when WindowServer does not auto-switch. Must also be followed by
    /// asynchronous polling, never a blocking wait.
    @discardableResult
    func forceSelectMode(pixelWidth: UInt32, pixelHeight: UInt32, refresh: Int) -> Bool {
        guard displayID != 0 else { return false }
        return Self.forceSelectMode(displayID, pixelWidth: pixelWidth,
                                    pixelHeight: pixelHeight, refresh: refresh)
    }

    /// Refreshes the bounds after a mode change (arrangement can be normalised).
    func refreshBounds() -> CGRect {
        return bounds
    }

    /// Polls the display mode until it has the requested pixel size (or times out).
    /// NOTE: only safe outside NSApplication.run(); the app uses async polling.
    static func waitForPixelSize(_ displayID: CGDirectDisplayID, width: UInt32,
                                 height: UInt32, timeout: TimeInterval) -> Bool {
        let deadline = Clock.now() + timeout
        while Clock.now() < deadline {
            if let mode = modeInfo(for: displayID),
               mode.pixelWidth == width, mode.pixelHeight == height {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        return false
    }

    /// Finds the best available 2x HiDPI mode for a tablet panel of the given
    /// pixel size (HLDP v1.2 "HiDPI 最大化"): prefers modes that fully cover the
    /// panel (crop-only, no scaling) with the smallest overshoot (<= 8 px), then
    /// falls back to the largest mode that fits inside the panel.
    static func bestHiDPIMode(displayID: CGDirectDisplayID, panelWidth: UInt32,
                              panelHeight: UInt32) -> DisplayModeSnapshot? {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return nil
        }
        let tolerance: UInt32 = 8
        var cropBest: (snapshot: DisplayModeSnapshot, overflow: Int, area: Int)?
        var fitBest: (snapshot: DisplayModeSnapshot, area: Int)?
        for mode in modes {
            let pw = UInt32(mode.pixelWidth)
            let ph = UInt32(mode.pixelHeight)
            let lw = UInt32(mode.width)
            let lh = UInt32(mode.height)
            guard pw > 0, ph > 0, pw == lw * 2, ph == lh * 2 else { continue } // 2x only
            let snapshot = DisplayModeSnapshot(pointWidth: lw, pointHeight: lh,
                                               pixelWidth: pw, pixelHeight: ph,
                                               refreshRate: mode.refreshRate)
            let covers = pw >= panelWidth && ph >= panelHeight &&
                pw <= panelWidth + tolerance * 2 && ph <= panelHeight + tolerance * 2
            if covers {
                let overflow = Int(pw - panelWidth) + Int(ph - panelHeight)
                let area = Int(pw) * Int(ph)
                if cropBest == nil || overflow < cropBest!.overflow ||
                    (overflow == cropBest!.overflow && area > cropBest!.area) {
                    cropBest = (snapshot, overflow, area)
                }
            } else if pw <= panelWidth && ph <= panelHeight {
                let area = Int(pw) * Int(ph)
                if fitBest == nil || area > fitBest!.area {
                    fitBest = (snapshot, area)
                }
            }
        }
        return cropBest?.snapshot ?? fitBest?.snapshot
    }

    /// Explicitly selects the mode whose pixel size matches the request. Prefers a
    /// 2x (HiDPI) variant when several modes share the pixel size. Returns true
    /// when a CGDisplaySetDisplayMode call reported success.
    static func forceSelectMode(_ displayID: CGDirectDisplayID, pixelWidth: UInt32,
                                pixelHeight: UInt32, refresh: Int) -> Bool {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return false
        }
        var best: CGDisplayMode?
        var bestScore = Double.greatestFiniteMagnitude
        for mode in modes {
            let pw = UInt32(mode.pixelWidth)
            let ph = UInt32(mode.pixelHeight)
            let pointW = UInt32(mode.width)
            let pointH = UInt32(mode.height)
            var score: Double
            if pw == pixelWidth && ph == pixelHeight {
                score = (pointW * 2 == pw) ? 0.0 : 0.2
            } else if pointW == pixelWidth && pointH == pixelHeight {
                score = 1.0
            } else {
                continue
            }
            let rate = mode.refreshRate
            if refresh > 0, rate > 0 {
                score += abs(rate - Double(refresh)) / 1000.0
            }
            if score < bestScore {
                bestScore = score
                best = mode
            }
        }
        guard let chosen = best else {
            Log.debug("reconfigure: no mode matching \(pixelWidth)x\(pixelHeight) px exists")
            return false
        }
        let error = CGDisplaySetDisplayMode(displayID, chosen, nil)
        Log.debug("reconfigure: CGDisplaySetDisplayMode -> \(error.rawValue)")
        return error == .success
    }

    /// Main-display safety net: if some other process made the virtual display
    /// main, put the physical display back to (0,0).
    @discardableResult
    func ensurePhysicalStaysMain() -> Bool {
        guard displayID != 0 else { return false }
        let repaired = hd_ensure_physical_stays_main(displayID) != 0
        if repaired {
            Log.warn("restored physical display as main (virtual display had become main)")
        }
        return repaired
    }

    func destroy() {
        guard displayID != 0 || !Self.isSupported else { return }
        if let ref = hiDPIModeRef { hd_release_mode(ref) }
        if let ref = native1xModeRef { hd_release_mode(ref) }
        hiDPIModeRef = nil
        native1xModeRef = nil
        hd_destroy_virtual_display()
        Log.info("virtual display released (displayID=\(displayID)); it detaches when this " +
                 "process exits")
        displayID = 0
        mode = nil
    }

    // MARK: - Introspection

    static func modeInfo(for displayID: CGDirectDisplayID) -> DisplayModeSnapshot? {
        var snapshot = DisplayModeSnapshot()
        let ok = hd_display_mode_info(displayID, &snapshot.pointWidth, &snapshot.pointHeight,
                                      &snapshot.pixelWidth, &snapshot.pixelHeight,
                                      &snapshot.refreshRate)
        return ok != 0 ? snapshot : nil
    }

    /// Pixel size of the main display's current mode (used for mirror mode capture).
    static func mainDisplayPixelSize() -> (width: UInt32, height: UInt32) {
        let id = CGMainDisplayID()
        if let mode = modeInfo(for: id), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        return (UInt32(CGDisplayPixelsWide(id)), UInt32(CGDisplayPixelsHigh(id)))
    }

    /// Screen (AppKit) coordinate rect for a display, needed to position windows.
    static func cocoaRect(forDisplay displayID: CGDirectDisplayID) -> NSRect {
        let cg = CGDisplayBounds(displayID)
        let mainHeight = NSScreen.screens.first?.frame.height ?? cg.maxY
        return NSRect(x: cg.origin.x, y: mainHeight - cg.origin.y - cg.size.height,
                      width: cg.size.width, height: cg.size.height)
    }

    static func screenName(for displayID: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber, number.uint32Value == displayID {
                return screen.localizedName
            }
        }
        return ""
    }

    static func listDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let err = CGGetOnlineDisplayList(32, &ids, &count)
        guard err == .success else {
            Log.error("CGGetOnlineDisplayList failed: \(err.rawValue)")
            exit(2)
        }
        func pad(_ text: String, _ width: Int) -> String {
            if text.count >= width { return text }
            return text + String(repeating: " ", count: width - text.count)
        }
        Log.info("online displays: \(count)")
        print("  idx  displayID  pointSize    pixelSize    bounds                    main  builtin  mirror  vendor    name")
        for i in 0..<Int(count) {
            let id = ids[i]
            let info = modeInfo(for: id)
            let point = info.map { "\($0.pointWidth)x\($0.pointHeight)" } ?? "?"
            let pixel = info.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"
            let b = CGDisplayBounds(id)
            let boundsText = String(format: "(%.0f,%.0f %.0fx%.0f)", b.origin.x, b.origin.y,
                                    b.size.width, b.size.height)
            let name = screenName(for: id)
            let vendor = CGDisplayVendorNumber(id)
            var line = "  " + pad(String(i), 3) + "  "
            line += pad(String(id), 9) + "  "
            line += pad(point, 12) + " "
            line += pad(pixel, 12) + " "
            line += pad(boundsText, 24) + "  "
            line += pad(CGDisplayIsMain(id) != 0 ? "yes" : "no", 4) + "  "
            line += pad(CGDisplayIsBuiltin(id) != 0 ? "yes" : "no", 7) + "  "
            line += pad(CGDisplayIsInMirrorSet(id) != 0 ? "yes" : "no", 6) + "  "
            line += String(format: "0x%04X", vendor) + "    "
            line += name
            if vendor == hd_virtual_display_vendor_id() {
                line += "  <- HaloLink virtual display"
            }
            print(line)
        }
        let main = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(main)
        Log.info("main displayID=\(main) bounds=" +
                 String(format: "(%.0f,%.0f %.0fx%.0f)", mainBounds.origin.x,
                        mainBounds.origin.y, mainBounds.size.width, mainBounds.size.height))
    }
}
