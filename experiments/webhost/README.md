# webhost — minimal standalone MJPEG demo host (macOS)

Fast demo/validation artifact: **virtual display → ScreenCaptureKit → JPEG → HTTP MJPEG + CGEvent input injection**.
Not the final product (the full host lives elsewhere); this exists to prove the whole pipeline on real hardware in one command.

```
CGVirtualDisplay (private API, bridge.h)        → extended virtual display, HiDPI 2x, ~2800×1848 framebuffer
ScreenCaptureKit SCStream (420v / NV12)          → 20–30 fps
CoreImage downscale → ImageIO JPEG q=0.55        → 1600 px wide, lock-protected latest-frame slot
Network.framework NWListener :8080               → / (viewer), /mjpg (MJPEG), /input, /status, /healthz
CGEvent (.hidSystemState, .cghidEventTap)        → touch down/move/up + two-finger scroll
```

## Files

| File | Purpose |
|---|---|
| `webhost.swift` | the whole program (single file, ~1200 lines including embedded HTML/CSS/JS) |
| `bridge.h` + `module.modulemap` | ObjC declaration/module of the private `CGVirtualDisplay*` classes |
| `build.sh` | exact `swiftc` build command |
| `tools/check-displays.swift` | tiny verifier: prints `CGGetOnlineDisplayList()` + bounds/mirror state |
| `webhost` | build product (not committed as source; rebuild with `./build.sh`) |

No third-party dependencies. Built with Command Line Tools only (swiftc 6.1.2, macOS 15.7.5 arm64).

## Build

```bash
cd experiments/webhost
./build.sh
# equivalent:
# swiftc -O webhost.swift -Xcc -fmodule-map-file=module.modulemap -Xcc -I. \
#   -framework ScreenCaptureKit -framework VideoToolbox -framework CoreMedia \
#   -framework CoreVideo -framework CoreGraphics -framework CoreImage \
#   -framework AppKit -framework ImageIO -framework Network -framework Foundation -o webhost
```

Build the display checker once (used for verification):

```bash
swiftc tools/check-displays.swift -o /tmp/check-displays
```

## Run

```bash
# defaults: 1400×924 pt @2x (= 2800×1848 framebuffer), 30 fps, HTTP :8080, run forever
./webhost

# demo/validation: auto-exit after 8 s, save 3 PNGs, verbose logs
./webhost --seconds 8 --save-frames /tmp/webhost-frames --verbose

# options
./webhost --help
#   --http-port N       HTTP listen port (default 8080)
#   --width N           logical width in points (default 1400)
#   --height N          logical height in points (default 924)
#   --scale N           backing scale, 2 = HiDPI (default 2)
#   --fps N             capture / stream rate (default 30)
#   --seconds N         auto-exit after N seconds (default 0 = forever)
#   --save-frames DIR   save 3 PNG frames (encoded frames #1/#31/#61)
#   --verbose           verbose per-frame / per-event logs
```

Expected startup log sequence (≈1.5–2 s):

```
main display: id=1 bounds=(0,0,1470x956)
CGVirtualDisplay.apply(hiDPI=1, modes=2) -> true, displayID=NN
virtual display online; initial bounds=(...)
arrangement: main=(0,0,1470x956) virtual=(1470,0,1400x924) mirrored=false
virtual mode: 1400x924 pt / 2800x1848 px / 60 Hz
beacon window shown on virtual display (animated content source)
HTTP listener ready on 0.0.0.0:8080
capture running: display=NN 30fps pixelFormat=420v -> 1600x1056 JPEG(0.55)
READY http://<lan-ip>:8080/
```

Open `http://<mac-lan-ip>:8080/` on the tablet/another machine. Contract that is honoured:

- Virtual display is **extended**, not mirrored, positioned at `main.maxX`; main display bounds are never changed.
- A small animated "beacon" window is placed on the virtual display: it gives ScreenCaptureKit continuously changing content
  (SCK is change-driven, an idle empty desktop can be nearly static) and guarantees non-black JPEG/PNG frames. It ignores mouse events.
- Capture never waits for HTTP clients: frames go into one lock-protected slot; each streaming client pulls the latest frame at ~`--fps`,
  sends at most one chunk in flight, and simply skips frames it cannot keep up with.
- Ctrl-C / SIGINT / SIGTERM → stop capture, close listener, release `CGVirtualDisplay` on the main thread, exit 0.

## HTTP API

| Method/Path | Behaviour |
|---|---|
| `GET /` | self-contained dark HTML viewer (no external resources): `<img src="/mjpg">`, pointer→normalized touch JSON, wheel/two-finger→scroll JSON, 全屏 button, status HUD |
| `GET /mjpg` | `multipart/x-mixed-replace; boundary=frame`, `Cache-Control: no-cache`, one JPEG part per frame |
| `POST /input` | JSON; returns `{"ok":true}` (200) or 400 |
| `GET /status` | `{"frames":N,"fps":x,"clients":N,"displayID":N,"bounds":{"x":..,"y":..,"width":..,"height":..},"width":1600,"height":1056,"encoded":N,"hiDPI":true,"fpsTarget":30,"uptime":s,"injected":N}` |
| `GET /healthz` | `ok` |

`POST /input` payloads (normalized 0..1 over the captured frame; mapped to `CGDisplayBounds(virtualDisplayID)` at injection time):

```json
{"type":"touch","action":"down","x":0.5,"y":0.5}
{"type":"touch","action":"move","x":0.51,"y":0.52}
{"type":"touch","action":"up","x":0.51,"y":0.52}
{"type":"scroll","dy":-42,"dx":0}
```

## Verify (exact commands used)

```bash
cd experiments/webhost
swiftc tools/check-displays.swift -o /tmp/check-displays

# 1) virtual display should be extended to the right of main, main untouched
/tmp/check-displays

# 2) run + capture evidence (auto-exits after 8 s)
rm -rf /tmp/webhost-frames
./webhost --seconds 8 --save-frames /tmp/webhost-frames --verbose

# 3) endpoints while it is running
./webhost --seconds 20 --save-frames /tmp/webhost-frames --verbose & WPID=$!
sleep 3
curl -s http://127.0.0.1:8080/healthz
curl -s http://127.0.0.1:8080/status
curl -s http://127.0.0.1:8080/ > /tmp/viewer.html && wc -c /tmp/viewer.html
curl -s --max-time 3 http://127.0.0.1:8080/mjpg -o /tmp/m.jpg          # exit 28 = expected (endless stream)
head -c 70 /tmp/m.jpg                                                   # "--frame" + Content-Type: image/jpeg + JPEG magic
curl -s -w '\n%{http_code}\n' -X POST -d '{"type":"touch","action":"down","x":0.5,"y":0.5}' http://127.0.0.1:8080/input
kill -INT $WPID; wait $WPID; echo "exit=$?"                             # Ctrl-C path: clean shutdown, exit 0

# 4) after exit: virtual display must be gone from CGGetOnlineDisplayList
/tmp/check-displays

# 5) PNG sanity: 3 PNGs, 1600x1056, non-black
python3 - <<'EOF'
from PIL import Image, ImageStat
import glob
for p in sorted(glob.glob('/tmp/webhost-frames/*.png')):
    im = Image.open(p).convert('RGB')
    print(p, im.size, 'mean_rgb=', tuple(round(v,1) for v in ImageStat.Stat(im).mean))
EOF
```

Observed on this machine (macOS 15.7.5, M2): main display `id=1 bounds=(0,0,1470x956)`; virtual display appears at
`(1470,0,1400x924)`, `mirrored=false`, mode `1400x924 pt / 2800x1848 px / 60 Hz` (HiDPI 2x), `vendor=0x484D`;
capture ≈29 fps, JPEG ≈85 KB/frame, 3 PNGs 1600×1056 with mean RGB ≈ (22,24,26) (clearly non-black);
after exit `CGGetOnlineDisplayList()` contains only the built-in display again.

## Caveats / notes

- **Private API**: `CGVirtualDisplay*` is semi-public (used by DisplayLink / BetterDisplay); `NSClassFromString` is checked and
  creation fails gracefully. Not App-Store-able.
- **TCC**: the process needs *Screen Recording* (SCK) and *Accessibility* (CGEvent injection). The shell that launched it already had both.
  Without Accessibility, events are posted successfully but silently ignored by macOS.
- **HiDPI**: achieved via `hiDPI=1` + declaring both the physical mode (`2800×1848`) and the logical mode (`1400×924`).
  Default run is a 2800×1848 framebuffer; captured output is downscaled to **1600×1056** before JPEG.
- **Frame rate**: SCK is change-driven. With a static virtual desktop the frame count can drop; the animated beacon window keeps it at ~30 fps
  and also guarantees non-black frames. Reported `fps` in `/status` is a measured rolling average, not a timer. Right after a brand-new virtual
  display appears, WindowServer/SCK often ramp up for ~2–3 s (observed ~10–20 fps, then a steady ~29 fps); over an 8 s run the total is still
  >200 frames captured.
- **Shutdown**: `CGVirtualDisplay` is released on the main thread. WindowServer may keep a captured virtual display listed in
  `CGGetOnlineDisplayList()` until the process actually exits; after exit it is always gone (verified with `tools/check-displays`).
  A 6 s watchdog forces exit if SCK teardown hangs.
- **Bandwidth**: MJPEG at 1600×1056 / q=0.55 / 30 fps ≈ 85 KB/frame ≈ 20–25 Mbps; fine for a LAN demo, wasteful vs. the final H.264 host.
- Main display safety net: if the virtual display ever becomes main, it is placed back to the right of a physical display
  (`ensurePhysicalStaysMain`), and arrangement changes use `CGDisplayConfiguration` `.forSession` (never `.permanently`).
