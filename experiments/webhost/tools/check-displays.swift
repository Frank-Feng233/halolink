// tools/check-displays.swift — print online displays (verification helper).
// Build: swiftc tools/check-displays.swift -o /tmp/check-displays && /tmp/check-displays
import CoreGraphics

var ids = [CGDirectDisplayID](repeating: 0, count: 32)
var n: UInt32 = 0
CGGetOnlineDisplayList(32, &ids, &n)
print("online displays: \(n) (main: \(CGMainDisplayID()))")
for id in ids.prefix(Int(n)) {
    let b = CGDisplayBounds(id)
    let mode = CGDisplayCopyDisplayMode(id)
    let px = mode.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"
    print(String(format: "  id=%u bounds=(%.0f,%.0f) %.0fx%.0f mode=%@ main=%@ mirrored=%@ vendor=0x%X",
                 id, b.origin.x, b.origin.y, b.width, b.height,
                 px, CGMainDisplayID() == id ? "true" : "false",
                 CGDisplayIsInMirrorSet(id) != 0 ? "true" : "false",
                 CGDisplayVendorNumber(id)))
}
