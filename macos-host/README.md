# HaloLink macOS Host

macOS host side of **HaloLink** — turns a HarmonyOS tablet into a **real extended
display** (not a mirror) for your Mac.

**最简用法：双击 `HaloLink.app`**（无需终端）。App 自带 `hdc`，会自动检测 USB
连接的平板（启动平板 App + 端口转发）；没有 USB 时使用上次成功的网络地址
（默认 `<tablet-ip>:9528`）；都失败则显示连接页让你填写 IP。菜单栏常驻
图标，关窗口不退出。完整说明见 §3.5。命令行二进制同样保留（见 §4）。


The host

1. creates a real virtual monitor with Apple's private `CGVirtualDisplay` API
   (WindowServer treats it as an external display — you can drag windows onto it),
2. captures it with **ScreenCaptureKit** (NV12),
3. hardware-encodes it with **VideoToolbox** (H.264 Main, real-time, no B frames,
   1 s GOP, Annex-B) and streams it over **TCP** to the tablet app (HLDP v1, the
   Mac is the TCP client; the tablet app is the server), and
4. injects the tablet's touch / scroll / keyboard events back into macOS with
   `CGEvent` (HID event tap).

It also ships an **install-free browser fallback**: a self-contained HTTP server
that serves an MJPEG stream + touch page (`GET /`), so a tablet browser can be
used immediately without deploying the native HAP app.

```
┌─────────────────────────── macOS host (this package) ─────────────────────────┐
│ CGVirtualDisplay ─▶ ScreenCaptureKit ─┬─▶ VideoToolbox H.264 ─▶ HLDP TCP ──────┼─▶ tablet app
│  (extended desktop)                    │                                        │
│                                        ├─▶ MJPEG hub ─▶ HTTP :8080 ─────────────┼─▶ tablet browser
│                                        ├─▶ PNG frame saver (--save-frames)      │
│                                        └─▶ .h264 dump (--dump-h264)             │
│                                                                               │
│ tablet control frames ─▶ InputInjector ─▶ CGEventPost(kCGHIDEventTap) ─▶ macOS │
└───────────────────────────────────────────────────────────────────────────────┘
```

No third-party dependencies: Foundation / AppKit / CoreGraphics / CoreMedia /
CoreVideo / VideoToolbox / ScreenCaptureKit / ImageIO / Network /
ApplicationServices only.

---

## 1. Requirements

- macOS 14+ on Apple Silicon or Intel (developed and tested on **macOS 15.7.5
  arm64, Apple M2** with *Command Line Tools only*, no full Xcode).
- Swift 6.1 toolchain (`swift build` from CLT works).
- Optional: HarmonyOS **Command Line Tools** installed on the build machine so
  `scripts/make_app.sh` can bundle `hdc` (USB auto-connect). Without it the app
  still works over Wi-Fi; only the USB auto-connect is unavailable.
- No entitlements, no Developer ID, no SIP changes. The virtual display uses a
  private-but-long-lived Apple API; code signing is only needed so that macOS can
  bind the two TCC permissions to a stable app identity.

## 2. Build

```bash
cd macos-host

# Command line binary
swift build -c release
# -> .build/release/halolink-host   (swift build --show-bin-path for the exact path)

# App bundle (needed for stable Screen Recording / Accessibility permissions)
bash scripts/make_app.sh
# -> macos-host/HaloLink.app  (ad-hoc or self-signed, see below)
```

`scripts/make_app.sh` builds the release binary, writes `Contents/Info.plist`
(bundle id `com.halolink.host`, `NSScreenCaptureUsageDescription`,
`NSLocalNetworkUsageDescription`, `NSHighResolutionCapable`, `LSUIElement`) and
codesigns the bundle. It tries, in order:

1. `$HALOLINK_SIGN_IDENTITY` if set and usable,
2. an existing **`HaloLink Self-Signed`** code-signing identity in the login
   keychain (the script creates one non-interactively if it can),
3. ad-hoc `codesign -s -` (works, but the cdhash changes on every rebuild and
   **macOS resets the TCC grants**, so you will be asked again).

Check which one was used in the script output. Env knobs: `CONFIG=debug`,
`NO_SIGN=1`, `HALOLINK_SIGN_IDENTITY="My Cert"`.

> **TCC stability:** sign with a stable identity so Screen Recording /
> Accessibility survive rebuilds. If the script falls back to ad-hoc, either
> create a self-signed *Code Signing* certificate in Keychain Access once and
> re-run with `HALOLINK_SIGN_IDENTITY`, or simply re-grant the permissions after
> rebuilding.

## 3. Permissions (TCC)

The host needs two user grants. They are independent:

| Permission | Needed for | How it is requested |
|---|---|---|
| **Screen & System Audio Recording** (`kTCCServiceScreenCapture`) | any ScreenCaptureKit capture | on startup the host calls `CGPreflightScreenCaptureAccess()`; if denied it logs instructions, calls `CGRequestScreenCaptureAccess()` (which adds the app to the list) and opens *System Settings → Privacy & Security → Screen & System Audio Recording*, then exits cleanly with code 2 |
| **Accessibility** (`kTCCServiceAccessibility`) | injecting touch/keyboard into other apps | `AXIsProcessTrustedWithOptions` with prompt; opens *Privacy & Security → Accessibility*; video streaming keeps working without it, input is silently ignored by macOS |

Creating the virtual display itself needs **no** permission. Web fallback also
needs no Accessibility permission (it is still required for input injection).

macOS also shows a **Local Network** prompt the first time the HTTP server accepts
a connection from the tablet; allow it.

### Running as a bundle vs. from a terminal

- `open HaloLink.app --args --seconds 8 --verbose` — the app gets its **own** TCC
  identity: grant Screen Recording / Accessibility once (System
  Settings → Privacy & Security), then relaunch. Logs go to
  `~/Library/Logs/HaloLink/halolink-host.log` (stdout is not visible when
  launched this way; override with `HALOLINK_LOG_FILE`).
- `./HaloLink.app/Contents/MacOS/halolink-host …` or `.build/release/halolink-host …`
  from an already-authorized terminal inherits the terminal's TCC grants — handy
  for automation/CI.

### Troubleshooting permissions

- `open -a HaloLink.app` logs to `~/Library/Logs/HaloLink/halolink-host.log`. If
  the log says *"Screen Recording permission is NOT granted"*, toggle HaloLink on
  in **System Settings → Privacy & Security → Screen & System Audio Recording**
  (the app adds itself to the list when it requests access) and relaunch.
- Accessibility is only needed for input: video will stream even when it is off.
- The system shows a monthly "HaloLink is recording your screen" nag on macOS
  Sequoia+; that is a system prompt and cannot be suppressed by the app.

## 3.5 双击使用 HaloLink.app（推荐）

1. Finder 里双击 `macos-host/HaloLink.app`（首次如果是下载得到的，右键 → **打开**）。
2. 首次运行按提示授权：
   - **屏幕录制**（必须）：系统设置 → 隐私与安全性 → 屏幕与系统音频录制 → 勾选 HaloLink；
   - **辅助功能**（仅当需要触摸/键鼠回传时）：隐私与安全性 → 辅助功能；
   - **本地网络**（首次 HTTP 被平板访问时弹窗）。
   授权后如仍提示缺失，退出 App 再打开一次。
3. 连接优先级（自动）：
   1. `hdc list targets -v` 发现 **USB Connected** 设备 → 自动 `aa start`
      平板 HaloLink App、`hdc fport tcp:19528 tcp:9528`，然后连接
      `127.0.0.1:19528`；
   2. 上次成功的目标（UserDefaults 持久化，默认 `<tablet-ip>:9528`；USB
      连接成功后也会记住 `127.0.0.1:19528`）；
   3. 都失败 → 窗口里的“平板地址”仍可手动填写并点“连接此地址”，并提示在
      平板打开 HaloLink App。
4. 窗口内容：
   - 状态（运行中/已连接/推流中）、**当前实际通道**（例如
     `已连接 · USB 有线 (127.0.0.1:19528)（推流中）` 或
     `已连接 · 无线 (<tablet-ip>:9528)（推流中）`）、分辨率与 Retina、
     逻辑分辨率与 scaleMode、屏幕方向、帧率/码率、延迟、触摸开关状态
     （含平板上报值）；
   - 按钮：**开启扩展屏 / 停止**、**重新连接**（按当前连接方式）、**退出**；
   - **连接方式（分段控件，持久化，默认“自动”）**：
     - **自动**：优先 USB 直连（hdc → aa start + fport → 127.0.0.1:19528），
       否则使用上次成功的无线地址；
     - **USB 有线**：只使用 USB；`hdc list targets -v` 没有 USB 设备时在窗口
       内红字报错，**不会静默退回无线**；
     - **无线**：直接连接地址框里的 IP:9528（忽略 USB）。
   - **显示模式（平板端）** 下拉框：
     - **完整显示（可能留黑边）** —— 等比缩放，画面完整（`config.scaleMode=fit`）；
     - **裁剪填满（无黑边，可能裁掉边缘）** —— 等比放大后裁切（`scaleMode=fill`）；
     - 下方固定说明：*该选项只影响平板端画面缩放方式，不影响虚拟屏分辨率。*
   - **虚拟屏渲染模式（HLDP v1.2）** 单选（两者都明确标注 HiDPI 与否）：
     - **原生 1:1 像素：2800×1840（1x，无缩放，最清晰像素映射）**：虚拟屏就是
       平板原生分辨率、1x；平板逐像素显示，不缩放/不重采样、无黑边；文字与 UI
       会明显变小，config 为 `renderMode:"pixel1to1", retina:false,
       width/height=2800/1840, logicalWidth/Height=2800/1840`；
     - **HiDPI 最大化：2800×1840 @2x（逻辑 1400×920，推荐）**：macOS 按 2x 渲染，
       平板按像素尽量 1:1 显示；config 为 `renderMode:"scale", retina:true,
       width/height=实际像素, logicalWidth/Height=实际逻辑`；若系统只给 +8 px
       模式则平板端裁掉 8 px（界面会显示实际值）。
     - 下方实时显示 **实际达成**：`实际达成：HiDPI 最大化 · 2800×1840 px =
       1400×920 pt (2x) · 平板面板 2800×1840 · 完全一致（无裁切）`，并按组合
       给出提示（1:1 模式下 fit/fill 无效；HiDPI 建议用“裁剪填满”无黑边铺满）。
   - **触摸控制：关（默认）/ 开**（v1.1 默认 **关**，实时生效并同步给平板）；
   - 无线地址输入框 + “连接此地址”（会自动切到无线方式）。
5. 菜单栏图标（屏幕图标）菜单：显示主窗口、开启/停止扩展屏、重新连接、退出。
   **关闭窗口不会退出 App**，从菜单栏退出即可。
6. 日志：`~/Library/Logs/HaloLink/halolink-host.log`（5 MB 自动轮转；
   `HALOLINK_LOG_FILE` 可覆盖）。

App 与 CLI 使用同一引擎；CLI 测试参数（`--seconds/--save-frames/--dump-h264/
--list-displays/--hdc-probe/--synthetic` 等）在 App 二进制上也可用，例如：

```bash
"macos-host/HaloLink.app/Contents/MacOS/halolink-host" --seconds 8 --save-frames /tmp/frames --verbose
"macos-host/HaloLink.app/Contents/MacOS/halolink-host" --hdc-probe        # 只读诊断
```

## 4. CLI

```
halolink-host [options]
```

Default when neither `--connect` nor `--listen` is given: **web-only mode** —
create the virtual display, start the HTTP server on `:8080`, print the tablet
URL and stay running. This is the guaranteed-usable path (no app install needed).

### Display / capture
| Flag | Default | Meaning |
|---|---|---|
| `--width <px>` | `2800` | virtual display framebuffer width |
| `--height <px>` | `1848` | framebuffer height (see HiDPI note below) |
| `--fps <n>` | `60` | capture + encode + refresh rate (1–240; 90/120 verified, see §11.12) |
| `--auto` / `--no-auto` | `--auto` | adapt virtual-display size / fps / orientation to the tablet's HLDP `hello` (`screen.width/height/density/refreshRate/orientation`). Explicit `--width/--height/--fps` still override. |
| `--render-mode pixel1to1\|scale` | `scale` | HLDP v1.2 virtual-display mode: `pixel1to1` = tablet native pixels at 1x (1:1 on tablet, small UI); `scale` = largest 2x HiDPI mode for the panel (2800×1840 @2x = 1400×920 pt preferred) |
| `--scale-match-main` | | **Advanced CLI only** (not in the app UI): virtual display = Mac main screen geometry (1470×956 @2x → 2940×1912 px) |
| `--scale-tablet` | | Legacy alias for `--render-mode scale` |
| `--scale-mode fit\|fill` | `fit` | reported to the tablet in `config.scaleMode` |
| `--input off\|on` | `off` | touch/keyboard injection master switch (v1.1 default OFF) |
| `--display-mode virtual\|mirror` | `virtual` | `mirror` captures the main display and creates no virtual display (fallback) |
| `--hidpi auto\|on\|off` | `auto` | request a 2x (retina) backing store |
| `--name <text>` | `HaloLink Display` | display name in System Settings |
| `--no-cursor` | off | hide the cursor in the capture |

### Encoding
| Flag | Default | Meaning |
|---|---|---|
| `--bitrate <bps>` | `24000000` | H.264 average bitrate |
| `--profile main\|high` | `main` | H.264 profile (Main = best decoder compatibility) |

### Transport (HLDP v1)
| Flag | Meaning |
|---|---|
| `--connect <host:port>` | dial the tablet app (default port 9528) |
| `--listen <host:port>` | reverse/debug: accept one inbound peer and play the server side of the handshake |

### Web fallback
| Flag | Default | Meaning |
|---|---|---|
| `--http-port <n>` | `8080` | HTTP port (`0` disables) |
| `--web-width <px>` | `1600` | default MJPEG downscale width (`?w=` overrides, clamped) |
| `--web-quality <0..1>` | `0.55` | default JPEG quality (`?q=` overrides) |
| `--web-fps <n>` | `30` | default MJPEG fps (`?fps=` overrides) |
| `--no-web` | | disable the HTTP server |

### Testing / automation
| Flag | Meaning |
|---|---|
| `--list-displays` | print online displays (id, point/pixel size, bounds, main/builtin/mirror, vendor, name) and exit |
| `--save-frames <dir>` | save up to 8 captured PNG frames (~4/s) — used by acceptance tests; logs mean luma per frame |
| `--dump-h264 <path>` | write the raw Annex-B H.264 stream |
| `--seconds <n>` / `--duration <n>` | auto-exit after n seconds |
| `--demo` | show a clock + colour bars window on the virtual display (screenshots/evidence) |
| `--gui` | force the App GUI (double-clicking the bundle implies this) |
| `--hdc-probe` | print hdc discovery + attached USB/TCP targets (read-only) and exit |
| `--synthetic` | generate synthetic NV12 frames instead of capturing — no TCC needed, deterministic 60 fps; for CI and protocol tests |
| `--verbose`, `-v` | debug logging |
| `-h, --help` | usage |

### READY line (for scripts)

Once the display + servers are up, one machine-parsable line is printed:

```
[halolink] READY display=76 bounds=(1470,0,1400x924) capture=2800x1848@60 mode=virtual hidpi=2x http=8080 url=http://<host-ip>:8080/ connect=off
```

`connect=` is `off` in web-only mode, `host:port` for `--connect`, and
`listen:host:port` for `--listen`. The host then prints a stats line every 2 s:

```
[halolink] stats fps=60.0 captureFps=60.0 kbps=545 encoded=240 sent=137 keyframes=6 dropped=0/0 jpeg=129 rtt=0.3ms uptime=4s clients=0 display=76 transport=ready jpegMs=33.0
```

## 5. Web fallback (no app install)

1. Run `halolink-host` (web-only default).
2. The READY line prints `url=http://<mac-lan-ip>:8080/`.
3. On the tablet (HarmonyOS/Chromium browser) open that URL, tap the picture and
   confirm **全屏** (or let the first tap auto-request fullscreen).

Page features: dark fullscreen UI, `<img src="/mjpg">` with `object-fit`
equivalent sizing, pointer events (single finger = mouse move/drag/click), two
fingers = scroll, wheel = scroll, a **键盘/文字** box that posts `{"type":"text"}`
via `POST /input`, a **全屏** button, and a status bar (`/status` every 2 s:
resolution, server fps, kbps, round-trip latency). The page is vanilla
ES5-compatible JS, no CDN, no modules, no WebRTC/MSE.

HTTP endpoints:

| Endpoint | Description |
|---|---|
| `GET /` | self-contained web client |
| `GET /mjpg?w=1600&q=0.55&fps=30` | `multipart/x-mixed-replace` MJPEG; each client has its own latest-frame slot + timer, so a slow browser can never stall capture |
| `POST /input` | JSON control frame (same schema as HLDP CONTROL), returns `{"ok":true}` |
| `GET /status` | JSON: `width,height,fps,clients,displayId,mode,captureFps,encodedFps,mjpegFps,kbps,mjpegKbps,jpeg,jpegBytes,jpegMs,transport,…` (`mjpegFps`/`mjpegKbps` are the numbers the HUD shows in web mode — a browser cannot measure MJPEG fps from a multipart `<img>`, so the server reports them) |
| `GET /healthz` | `ok` |

MJPEG uses `Cache-Control: no-store, no-cache, must-revalidate`, `Pragma: no-cache`
and a fixed boundary (`halolinkframe`). A stalled socket send is dropped after
5 s, and at most **8 concurrent MJPEG viewers** are served (extra requests get
`503`) so a tab-reconnect storm cannot exhaust the host.

## 6. Native tablet stream (HLDP v1)

See `specs/PROTOCOL.md`. Summary of the host side:

- TCP **client** (`--connect host:port`, default tablet app server `:9528`);
  `--listen` implements the server role for debugging.
- Handshake: one UTF-8 JSON line each — tablet `hello` → host `config` → tablet
  `ready` (10 s timeout, both roles), then binary framing.
- Binary frame: `1 B type | 4 B BE length | payload`, max 16 MiB.
  `0x01 VIDEO` (Annex-B access unit), `0x02 CONTROL` (JSON), `0x03 PING`,
  `0x04 PONG`.
- The **first VIDEO frame after `ready` is always an IDR with SPS/PPS**
  (frames encoded before the handshake are dropped, stale P-frame flush is
  prevented); SPS/PPS are repeated before every IDR.
- On a fresh connection the host re-encodes the last captured frame as a forced
  IDR, so the tablet shows the current desktop immediately even though
  ScreenCaptureKit is change-driven.
- `request_keyframe` control forces an IDR; `bye` closes; `stats` is logged and
  shown in the periodic stats line; `touch`/`scroll`/`key`/`text` are injected.
- PING every 2 s; a missing PONG for 12 s reconnects (client mode, backoff
  0.5 s→8 s). TCP_NODELAY is enabled.

## 6.5 Adaptive resolution / refresh rate (`--auto`, default on)

The tablet app reports its panel in the HLDP `hello` message:
`{"screen":{"width":2800,"height":1840,"density":2.25,"refreshRate":144}}`.
Before answering `config`, the host:

1. **normalises orientation** (tablet-native portrait values are rotated to the
   landscape virtual display) and **maps 2800×1840 → 2800×1848** — macOS 15 only
   offers a 1x mode for the exact 35:23 aspect ratio, while 2800×1848 gives the
   desired 1400×924 @2x desktop;
2. picks **fps = min(--fps, tablet refreshRate)** (so a 144 Hz tablet still gets
   the 60 fps default while `--fps 90/120` is honoured);
3. if the virtual display differs from the tablet panel by **more than ~5%**
   (aspect or size), it reconfigures the *existing* `CGVirtualDisplay` at runtime
   (`applySettings:` with a new physical-anchor + logical mode pair), restarts the
   encoder and ScreenCaptureKit capture at the new pixel size, and rate-limits
   these reconfigurations to one per 10 s;
4. logs the decision (e.g.
   `tablet screen HUAWEI MatePad 11.5"S: 2800x1840 density=2.25 hz=144` /
   `auto: stream fps = min(--fps 60, tablet 144Hz) = 60` /
   `auto: virtual display 2800x1848 is compatible with tablet panel 2800x1840; keeping it`)
   and answers `config` with the **actual** streaming width/height/fps so the
   tablet can letterbox correctly.

Older tablet app versions that do not send `refreshRate` are handled: the host
keeps its defaults and logs `size not reported`.

**Implementation pitfall (verified with standalone probes):** while the app runs
inside `NSApplication.run()`, WindowServer applies a virtual-display mode change
asynchronously and only when the main run loop iterates normally. Blocking the
thread (sleep or a nested run loop) starves the update and the mode never
changes. The adaptive path therefore stops capture, calls `applySettings:`, then
**polls with `DispatchQueue.main.asyncAfter`**; capture/encoder are restarted from
the completion. A reconfiguration is skipped entirely when the panel is already
compatible (the common MatePad case).

## 6.6 HLDP v1.1：Retina 一致 / 竖屏旋转 / 输入开关

Protocol extension is documented in `specs/PROTOCOL.md` (§7). Host behaviour:

- **config** now carries `scaleMode` (`fit`/`fill`), `retina`, `logicalWidth`,
  `logicalHeight` and `inputEnabled`, plus `protocol:"halolink/1.1"`. Older tablet
  apps ignore the extra fields.
- **Retina consistency**: the virtual display is a 2x HiDPI display. Two sizing
  strategies:
  - `--scale-tablet` (default): tablet native panel → 2800×1848 px / 1400×924 pt;
  - `--scale-match-main`: main display geometry → e.g. 2940×1912 px / 1470×956 pt,
    so elements look the same size as on the built-in screen; the tablet
    scales/crops (fit/fill) to its own panel.
- **Portrait / auto-rotation**: `hello.screen.orientation` and the runtime
  `{"type":"display","width","height","orientation","refreshRate"}` control frame
  are parsed. For portrait the host reconfigures the *same* virtual display to
  1840×2808 px / 920×1404 pt (2x; falls back to 1x and reports the actual logical
  size if macOS refuses), restarts encoder + capture, re-sends `config` and forces
  an IDR. The display keeps its position (right of main), stays non-mirrored and
  the physical display stays main. Rotation events are debounced (450 ms coalesce,
  max one rebuild per 2 s) to avoid ScreenCaptureKit start/stop thrashing; on
  failure the previous display is kept and a warning is logged.
- **Input off by default**: `--input off` (default) drops every
  `touch/scroll/key/text` control frame and logs once; the App's 触摸控制 switch
  toggles it live (and prompts for Accessibility when turned on). The App shows
  `stats.input` reported by the tablet ("平板：开/关").
- **hdc auto-connect** (App): bundled `hdc` → `list targets -v` → for a USB
  target run `aa start -a EntryAbility -b com.halolink.display` and
  `fport tcp:19528 tcp:9528`, then connect to `127.0.0.1:19528`.
  NOTE: removing a stale mapping needs the **full two-part** ruler string
  (`hdc -t SERIAL fport rm tcp:19528 tcp:9528`); the single-part form fails with
  "ruler is not exist" (fixed by the tablet/lead integration and kept here).
- **Connection method selector** (App): 自动 / USB 有线 / 无线, persisted in
  UserDefaults. USB mode never silently falls back to Wi-Fi: it reports
  `USB 连接失败：…` in the window and keeps the session available for the browser
  fallback only. The status row always shows the real channel
  (`已连接 · USB 有线 (127.0.0.1:19528)` / `已连接 · 无线 (ip:9528)`).

## 6.7 HLDP v1.2：虚拟屏两种渲染模式

`config` 新增 `renderMode`（`pixel1to1` | `scale`），协议版本 `halolink/1.2`：

| 模式 | 虚拟屏 | config | 平板端行为 |
|---|---|---|---|
| **原生 1:1 像素** (`pixel1to1`) | 平板原生像素，**1x**（如 2800×1840） | `width/height=2800/1840`, `logicalWidth/Height=2800/1840`, `retina=false` | 逐像素 1:1 显示，不缩放/不重采样；不足补边、超出裁切；忽略 scaleMode |
| **HiDPI 最大化** (`scale`) | 面板像素下 macOS 支持的最大 2x 模式（优先 1400×920 @2x = 2800×1840；实测本机可**精确达成**，无需裁切） | `width/height=实际像素`, `logicalWidth/Height=实际逻辑`, `retina=true` | 按 fit/fill 等比缩放/裁切 |

实现要点（实测）：
- 声明 **rich mode list**（物理锚点 = 面板高 + 8 px，另加多个半尺寸逻辑候选，含
  精确 1400×920）后 macOS 会给出精确 2800×1840 @2x；仅有“锚点+逻辑”一对模式时
  只给 1x。
- 1x/2x 切换使用**保留的 `CGDisplayMode` 句柄**（虚拟屏的 2x 模式不在公共模式列表
  里，必须在 2x 激活时捕获）；`CGVirtualDisplay` 在同一进程内无法销毁重建。
- 从 1x 切到 2x 时若启动时未捕获到 2x 句柄（macOS 创建结果偶尔落到 1x），App 会
  **自动重启自己**（保存所选模式后 relaunch）以重新创建虚拟屏；同家族切换（如
  scale 模式下改 fit/fill）只重启采集管线。
- CLI 无法 relaunch 时记录警告并保持当前模式，config 始终报告实际值。

## 6.8 HLDP v1.3：端到端延迟测量与低延迟优化

### 帧时间戳（需平板 hello features 含 `"frameTs"`）
- host 在 config 里回 `"frameTs": true`（协议版本 `halolink/1.3`）；
- 每个 VIDEO(0x01) 帧 payload = **8 字节大端 Unix 微秒采集时间戳 + Annex-B**；采集
  时间戳取 ScreenCaptureKit 回调收到该帧的时刻（经 `sourceFrameRefcon` 贯穿 VT）；
- 旧平板（features 无 frameTs）→ config `frameTs:false`，payload 保持原格式（已实测
  兼容）。平板侧解析 `captureTsUs` 后回传 stats 的 `recvMs/decMs/renderMs/e2eMs/
  presentHz`，host 写入日志与 `/status`。

### host 侧分段耗时（日志 + `/status`）
`stats` 行追加 `lat cap=avg/p95ms(样本) enc=avg/p95ms snd=avg/p95ms rtt=…ms
e2e=…ms (recv/dec/render/hz)`；`/status` 增加 `captureMsAvg/P95`、
`encodeMsAvg/P95`、`sendMsAvg/P95`、`e2eMs`、`recvMs`、`decMs`、`renderMs`、
`presentHz`、`frameTs`。含义：
- `captureMs`：SCK 相邻帧回调间隔（SCK 变化驱动：静态桌面大、动画桌面≈1/fps）；
- `encodeMs`：VT 输出回调 - 帧到达 host；
- `sendMs`：socket send 完成 - 编码输出；
- `rtt`：HLDP PING/PONG；`e2e` 等由平板上报。

### 本轮优化（v1.3）
- SCK `queueDepth` 3 → **2**；
- VideoToolbox：优先 `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`（不支持
  自动回退并记录）+ `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`，
  保持 RealTime / 禁用 B 帧 / MaxFrameDelayCount=0；VT 在飞帧上限 2；
- 编码完成**立即** `NWConnection.send`（无攒批），TCP_NODELAY 已开（日志
  `TCP options: TCP_NODELAY=on`）；发送队列仅受 4 MiB 背压阈值限制，重连逻辑不缓存
  旧帧；JPEG/PNG 均在独立队列，不阻塞 SCK 回调；
- 调参环境变量（便于安静环境复测）：`HALOLINK_VT_LOWLATENCY=0|1`、
  `HALOLINK_VT_OUTSTANDING=<n>`。

### 实测（本机 M2，同时有用户正在使用的 60fps 串流 → 硬件编码器竞争）
| 场景 | 优化前 | 优化后 |
|---|---|---|
| 合成源 60fps 回环 `encodeMs` avg/p95 | **31.6–34.5 / 36.3–36.7 ms** | **14.3–28.7 / 35.5–40.8 ms**（波动大，见下） |
| 合成源 `sendMs` | 0.1 ms | 0.1–0.2 ms |
| 合成源捕获间隔 | 16.7 ms | 16.7 ms |
| 真实虚拟屏 + demo（10 fps 动画）捕获间隔 avg/p95 | 81.6–87.0 / 109.7 ms | 87–89 / 115–116 ms |
| 真实虚拟屏 `encodeMs` avg/p95 | 13.0–13.5 / 15.1–20.2 ms | 13.7–14.4 / 14.9–21.9 ms |
| 回环 PING/PONG RTT | 0.2–0.3 ms | 0.2–0.4 ms |

说明：测试期间用户 App 正在以 2800×1840@60 推流，M2 的单个 H.264 硬编码器被两个
60 fps 5.2 MP 流共享，导致优化后合成源基准出现 30–120 帧/15s 的编码丢弃、
平均编码耗时波动（14→52 ms）。**结论方向**：低延迟码控 + 浅队列把"编码完成时延"
从 ~32 ms 降到 ~15 ms 量级（空载首次测量），但在编码器竞争下会牺牲帧率；真实收益
需在安静环境 / 平板联合测量中确认（`e2eMs` 需平板 frameTs 新版上报）。

### USB hdc fport 传输延迟
- 联调时 lead 实测 HLDP PING/PONG（经 `hdc fport tcp:19528→9528`）约 **9–14 ms**，
  是同 Wi-Fi 直连（典型 2–8 ms，取决于路由）的 2–3 倍；
- 本机用 `hdc -t <serial> shell true` 测得命令往返 83–137 ms，这是 hdc 协议 + 远端
  进程创建的**上界**，不能直接代表 fport 数据面延迟；
- **RNDIS/USB 网络不可用**：USB 连接时 `ifconfig` 仅 `en0`（Wi-Fi <tablet-ip>0）有
  IPv4，`en1–en4` 无地址 → 平板未提供 USB 网络共享；HarmonyOS 若开启"USB 共享网络"
  会新增带 IPv4 的 `enX`，届时可直接用平板 IP 走 Wi-Fi 级 TCP；
- 结论：hdc fport 是用户态 TCP 代理（USB 批量传输 + 用户态转发），固有 RTT 偏高；
  低延迟需求建议 **Wi-Fi 直连/热点**（同一路由、5 GHz），USB 只作为稳定/无网场景。
  host 端已把额外排队压到最低（sendMs ~0.1–0.2 ms），剩余延迟主要在 hdc 通道本身。

## 7. Virtual display details

- Created with `CGVirtualDisplayDescriptor` / `CGVirtualDisplaySettings` /
  `CGVirtualDisplayMode` (private CoreGraphics classes resolved through the
  Objective-C runtime; no private headers/symbols at link time).
- **HiDPI recipe** (empirically verified): declare a physical-anchor mode
  (pixel size == `maxPixelsWide/High`) **and** a half-size logical mode, set
  `hiDPI = 1`. macOS then runs the desktop at `width/2 × height/2` points with a
  2x backing store of `width × height` pixels; ScreenCaptureKit reports the
  *point* size for `SCDisplay` but delivers `width × height` pixel frames.
- `sizeInMillimeters` is derived at ~220 PPI with a floor of `208 × 96 mm`
  (macOS 26.1+ refuses to bring up virtual displays with a smaller declared
  area).
- **2800×1840 quirk:** macOS 15.7.5 does **not** expose a 2x mode for the exact
  35:23 aspect ratio `2800×1840` (the MatePad panel size); it silently brings the
  display up 1x. The default height is therefore **1848** (2800×1848 gets a
  1400×924@2x desktop and a 2800×1848 capture). If you need pixel-exact panel
  resolution use `--width 2800 --height 1840` and accept a 1x desktop (small
  UI), or `--hidpi off`.
- The display is arranged **to the right of the main display** with
  `CGConfigureDisplayOrigin` + `CGConfigureDisplayMirrorOfDisplay(…, kCGNullDirectDisplay)`
  inside one `kCGConfigureForSession` transaction. macOS may re-normalise the
  arrangement, so the host always **reads `CGDisplayBounds()` back** and uses the
  runtime value for input coordinate mapping.
- A safety net keeps the *physical* display as the main display (a virtual main
  display would move the menu bar/Dock to an invisible screen). Screen-parameter
  changes are observed and the arrangement/bounds refreshed.
- The virtual display lives as long as the host process (and is created again on
  next launch). Only **one** HaloLink instance can own it at a time: a POSIX file
  lock (`~/Library/Application Support/HaloLink/host.lock`) makes a second
  instance exit immediately with *"another HaloLink host is already running
  (pid …)"*. On startup the host also waits up to 3 s for a display left over by
  a previous instance to detach before creating its own — it never kills another
  process' display.
- **Sleep/wake:** macOS often cannot re-register a virtual display on the old
  WindowServer connection after sleep. Restart the host after a sleep/wake cycle
  if the tablet stream does not resume.

## 8. Input injection

- Normalized tablet coordinates (0..1, top-left) are mapped onto the virtual
  display's **runtime** `CGDisplayBounds()`; global Quartz coordinates are
  top-left origin / y-down, so `global = bounds.origin + normalized * bounds.size`.
- Events are posted to `.cghidEventTap` with a `CGEventSource(stateID:
  .hidSystemState)`: single finger = mouse moved / left down / left up / left
  dragged (with double-click `clickState` detection), two fingers / wheel =
  `CGEventCreateScrollWheelEvent(units: .pixel)`.
- Text uses `CGEventKeyboardSetUnicodeString` (layout independent, surrogate
  pairs kept together); special keys (`ENTER, ESC, BACKSPACE, TAB, arrows,
  DELETE, HOME/END, PAGEUP/DOWN, F1–F12, SPACE, …`), `CMD/CTRL/ALT/SHIFT`
  modifiers and `"CMD+SHIFT+T"`-style combos are supported. A 1 s auto-release
  prevents stuck keys if an "up" event is lost.

## 9. Known limitations

- `CGVirtualDisplay` is a **private API**: it can change or disappear with any
  macOS update. The host detects it at startup and falls back to mirror mode
  instead of crashing. Not distributable via the Mac App Store.
- The 2x/HiDPI mode availability depends on macOS' internal mode table for the
  chosen aspect ratio (see the 2800×1840 quirk). The host logs the mode it
  actually got (`hidpi=2x` / `hidpi=1x` in the READY line).
- Runtime resolution changes are limited to what `applySettings:` accepts on the
  already-created display (bounded by the initial `maxPixelsWide/High`) and can
  take ~0.2–2 s to settle. When macOS refuses the requested mode the host keeps
  the current mode, logs it and still reports the actual size in `config`; use
  `--width/--height` to pick a size at creation time for guaranteed results.
- Ad-hoc code signing resets TCC on every rebuild (see §2/§3).
- macOS Sequoia+ shows the monthly "is recording your screen" nag; this is a
  system prompt the app cannot suppress.
- MJPEG is intraframe: at 1600×1056 a JPEG takes ~30 ms on M2 (≈30 fps ceiling
  per variant). Use the native HLDP stream for low latency; the web fallback is
  a convenience path.
- Input injection requires Accessibility; without it the video still streams.
- ScreenCaptureKit is change-driven: a completely static desktop produces few
  frames. The **capture watchdog** detects gaps and re-publishes the cached frame
  (≈1 fps keepalive to connected clients, forced IDRs to the native client); real
  changes still stream at full rate. Use `--demo` or move the pointer for a
  continuously changing desktop.
- The capture watchdog restarts the ScreenCaptureKit stream if no frame arrives
  for >6 s (observed after long idle periods before App Nap was disabled), and
  the process declares a user-initiated activity so macOS does not nap it.
- No audio, single pointer (no multitouch gestures beyond two-finger scroll), no
  TLS/auth on the LAN ports (HLDP v1 has no auth yet).
- **USB auto-connect** needs `hdc` at build time (bundled by `make_app.sh`) and a
  HarmonyOS device with USB debugging authorised. The command construction is
  verified with a stub `hdc`; the real `aa start`/`fport` sequence still needs a
  real-tablet run (coordinate with the tablet app owner).
- **Rotation** is implemented and verified against a simulated tablet (config
  sequence + portrait framebuffer). The current tablet app `hello` does not send
  `screen.orientation` yet, so the real-device rotation path needs the updated
  app that also emits the `display` control frame.
- `--scale-match-main` streams 2940×1912 @60 (≈5.6 MP) — noticeably heavier than
  the tablet-native mode; watch CPU/temperature on long sessions (advanced CLI only).
- v1.2 1x <-> 2x switching: the 2x mode handle is only obtainable while 2x is active.
  If the app is currently in 原生 1:1 mode and the user switches to HiDPI 最大化,
  the app relaunches itself to recreate the virtual display (~2 s, stream reconnects).
  Same-family changes (fit/fill, rotation, fps) do not relaunch.
- App TCC identity: the stable self-signed certificate keeps the Screen Recording
  / Accessibility grants across rebuilds, but the first grant per machine/user is
  still manual (System Settings), and macOS may require relaunching the app once.

## 10. Repository layout

```
macos-host/
├── Package.swift                      SwiftPM manifest (no external deps)
├── README.md
├── scripts/make_app.sh                build + HaloLink.app bundle + signing
└── Sources/
    ├── CVirtualDisplay/               ObjC bridge to private CGVirtualDisplay API
    │   ├── include/CVirtualDisplay.h
    │   └── CVirtualDisplay.m
    └── HaloLinkHost/
        ├── main.swift                 entry point
        ├── Options.swift              CLI parsing + usage
        ├── Log.swift                  [halolink] logger (+ file log)
        ├── NetworkInfo.swift          LAN address discovery
        ├── VirtualDisplay.swift       create/arrange/HiDPI/list displays
        ├── CaptureEngine.swift        ScreenCaptureKit display capture
        ├── H264Encoder.swift          VideoToolbox H.264 + AVCC→Annex-B
        ├── LinkTransport.swift        HLDP v1 TCP client/listener + handshake
        ├── InputInjector.swift        CGEvent touch/scroll/key/text injection
        ├── MJPEGHub.swift             latest-frame slots + JPEG encoding
        ├── WebServer.swift            HTTP server (/ /mjpg /input /status /healthz)
        ├── WebPage.swift              self-contained browser client
        ├── FrameSaver.swift           PNG evidence + mean luma
        ├── SyntheticSource.swift      --synthetic test frame generator
        ├── DemoWindow.swift           --demo clock/colour-bars window
        ├── HostStats.swift            fps/kbps/rtt accounting
        ├── HDCBridge.swift            bundled hdc: USB detect, aa start, fport
        ├── AppDelegate.swift          GUI entry + connection coordinator
        ├── MainWindowController.swift dark AppKit main window
        ├── StatusItemController.swift menu bar item
        └── HostApp.swift              engine: lifecycle, TCC, READY, shutdown
```

## 11. Acceptance test results

Exact commands and observed output from the macOS 15.7.5 / M2 test machine.

Test machine: **macOS 15.7.5 (24G624), Apple M2, arm64, Command Line Tools only
(no full Xcode), SIP enabled**. Tests below were executed as the un-signed release
binary from an already-authorized terminal (so the Screen Recording /
Accessibility TCC grants are inherited).

### 11.1 Build + app bundle

```
$ swift build -c release
[...] Build complete!
$ bash scripts/make_app.sh
[make_app] building (swift build -c release) …
[make_app] binary: .build/arm64-apple-macosx/release/halolink-host
[make_app] creating …/macos-host/HaloLink.app
[make_app] no stable signing identity found; trying to create one (best effort) …
[make_app] codesigning with identity: HaloLink Self-Signed (created)
[make_app] app bundle ready: …/macos-host/HaloLink.app
```
`codesign -dv HaloLink.app` → `Identifier=com.halolink.host`, `Format=app bundle`,
stable self-signed identity (TCC survives rebuilds). Clean build from an empty
`.build` also succeeds (`swift build -c release`, no warnings).

### 11.2 `--list-displays`

```
$ .build/release/halolink-host --list-displays
[halolink] online displays: 1
[halolink] main displayID=1 bounds=(0,0 1470x956)
  idx  displayID  pointSize    pixelSize    bounds                    main  builtin  mirror  vendor    name
  0    1          1470x956     2940x1912    (0,0 1470x956)            yes   yes      no      0x0610    Built-in Retina Display
```
While the host runs, the virtual display appears in the same list
(`0x484C  HaloLink Display  <- HaloLink virtual display`), and

```
$ system_profiler SPDisplaysDataType
        HaloLink Display:
          Resolution: 2800 x 1848
          UI Looks like: 1400 x 924 @ 60.00Hz
          Mirror: Off
          Online: Yes
```
`Simulator`-class independent confirmation that the extended display is real (not
mirrored) and that the 2x HiDPI recipe produced a 1400×924 pt / 2800×1848 px
desktop.

### 11.3 Virtual display capture (`--save-frames`, `--demo`)

```
$ .build/release/halolink-host --seconds 6 --save-frames /tmp/hl-vd --demo \
      --dump-h264 /tmp/hl-vd.h264 --http-port 28085
[halolink] virtual display created: id=77 mode=1400x924 pixels=2800x1848 refresh=60Hz hidpi=yes(2x)
[halolink] virtual display placed at origin=(1470,0) size=1400x924 (requested x=1470) mirrored=no main=1
[halolink] capture started: displayID=77 2800x1848px @60fps NV12
[halolink] READY display=77 bounds=(1470,0,1400x924) capture=2800x1848@60 mode=virtual hidpi=2x http=28085 url=http://<host-ip>:28085/ connect=off
[halolink] saved /tmp/hl-vd/frame-00-2800x1848.png luma=35.0 (1/8)
… 8 PNGs saved (luma 35.0 → 66.3)
[halolink] h264 dump written: /tmp/hl-vd.h264 (617950 bytes)
[halolink] summary: captured=74 encoded=74 (0.6 MB) keyframes=7 sent=0 … avgFps=9.2 uptime=8.0s
[halolink] virtual display 77 destroyed
```
The 8 PNGs are 2800×1848; ffmpeg mean-grey values 0x0b → 0x2d (not black). One
frame is included in this repo: `test-artifacts/captured-frame-2800x1848.png`
(menubar + demo window visible, proving it is the extended desktop, not a black
buffer). Capture fps is low because the desktop demo only animates twice a second
— ScreenCaptureKit is change driven; the native client path handles this with a
cached-frame IDR.

### 11.4 H.264 pipeline

```
$ ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames,width,height,codec_name,profile,pix_fmt,color_space \
    -of default=nw=1 /tmp/hl-vd.h264
codec_name=h264
profile=Main
width=2800
height=1848
pix_fmt=yuv420p
color_space=bt709
nb_read_frames=74

$ ffmpeg -v error -f h264 -i /tmp/hl-vd.h264 -f null -
(no output, exit code 0 → every frame decoded without errors)
```
With `--synthetic` (deterministic 60 fps, no TCC needed):
`nb_read_frames=241`, 241 encoded frames in ~4 s, 5 keyframes (1 s GOP),
231574 bytes dumped, `ffmpeg -f h264 -i … -f null -` exit 0.
Verified: Main profile, no B-frames (`has_b_frames=0`), BT.709 matrix/primaries,
TV range, Annex-B with SPS/PPS before each IDR.

### 11.5 HLDP TCP protocol (Python test peer, `/tmp` only)

`--listen` mode (host = server side of handshake, Python = tablet):

```
[peer] <- hello: {"protocol":"halolink/1","screen":{"width":2800,"height":1848,…},…}
[peer] -> config sent
[peer] <- {'type': 'ready'}
[peer] RESULT role=listen frames=360 bytes=351096 duration=5.97s fps=60.3
       keyframes=7 pings=3
[peer] first video NAL types=[7, 8, 5] (SPS, PPS, IDR)   ← first frame is always IDR
[peer] PASS
```
The received Annex-B stream is a valid H.264 file: `ffprobe … nb_read_frames=360`,
`ffmpeg -f h264 -i … -f null -` exit 0.

`--connect` mode (Python = tablet server, host dials in):

```
[halolink] TCP connected to 127.0.0.1:19529
[halolink] HLDP hello from PythonTestTablet screen=2800x1848 density=2 hz=60
[halolink] HLDP handshake complete — streaming enabled
[peer] RESULT role=client frames=421 bytes=393446 duration=6.98s fps=60.3 keyframes=9
[peer] PASS   (ffprobe: nb_read_frames=421)
[halolink] HLDP link closed: peer closed the connection
[halolink] reconnecting to 127.0.0.1:19529 in 0.5s (attempt 1)   ← backoff works
```
Control frames were exercised too: `request_keyframe` (produced new IDRs),
`stats` (logged in the periodic line as `peer(fps=60.0 decode=3.2ms rtt=8.0ms)`),
PING/PONG RTT ≈ 0.2 ms on loopback. Video: 2800×1848 @ 60.3 fps, ~0.4–0.9 Mbps
for the mostly-static colour-bar test pattern, `dropped=0/0`.

### 11.6 HTTP / MJPEG web fallback

While `--synthetic --http-port 28080` was running:

```
$ curl -s http://127.0.0.1:28080/healthz           → ok
$ curl -s http://127.0.0.1:28080/status
{"captureFps":57.2,"clients":1,"displayId":0,"encodedFps":0,"fps":60,
 "height":1848,"httpPort":28080,"jpeg":60,"jpegBytes":44076,"jpegHeight":1056,
 "jpegMs":33.8,"jpegWidth":1600,"mode":"synthetic","mjpegFps":19.6,
 "mjpegKbps":8200,"transport":"off","uptime":3.7,"width":2800,…}
$ curl -s --max-time 4 "http://127.0.0.1:28080/mjpg?w=1600&fps=20" -o /tmp/hl2.mjpg
  → 3629468 bytes, 78 multipart parts, 78 JPEG SOI markers
  → starts with `--halolinkframe\r\nContent-Type: image/jpeg\r\nContent-Length: …`
$ curl -s -X POST -H 'Content-Type: application/json' \
       -d '{"type":"touch","action":"down","x":0.5,"y":0.5}' http://127.0.0.1:28080/input
{"ok":true}
$ curl -s http://127.0.0.1:28080/ | head -c 40   → <!DOCTYPE html> …
```
On the real virtual display the same `/mjpg` returned 30 JPEG frames in 2 s
(~2.5 MB) — the extended desktop including the menu bar and the demo window.
JPEG at 1600 px wide takes ~33 ms on M2 (≈30 fps ceiling per variant); the MJPEG
worker runs off the capture path with per-client one-frame slots, so slow or
reconnecting browsers cannot stall capture.

### 11.7 Real tablet end-to-end (by the lead, on the physical MatePad 11.5"S)

> virtual display 2800×1848@2x HiDPI, extended at (1470,0); `/mjpg` streamed to
> the HarmonyOS browser fullscreen; touch/drag injection moved the Mac cursor
> inside the virtual display — tablet tap (1400,900) → Mac (2169,450), expected
> (2170,452); screenshot `demo/tablet-extended-fullscreen.jpeg`.

This confirms the full web-only path (virtual display → SCK → JPEG → HTTP →
tablet browser → touch → CGEvent) on the real device.

### 11.8 TCC behavior

- Binary run from an authorized terminal: `CGPreflightScreenCaptureAccess() == 1`,
  `AXIsProcessTrusted() == 1` → everything above ran without human interaction.
- `open -a HaloLink.app --args …`: the app has its own TCC identity, so the first
  launch logs

```
ERROR: Screen Recording permission is NOT granted for "HaloLink".
… opened System Settings pane: …Privacy_ScreenCapture
ERROR: cannot continue without Screen Recording permission; exiting.
```

  → one human toggle in **System Settings → Privacy & Security → Screen &
  System Audio Recording** (and Accessibility) is required once; stable
  self-signed code signing keeps the grant across rebuilds. Nothing crashed and
  no display was left behind.

### 11.9 Shutdown / no ghost displays

Every run (`--seconds`, SIGINT/SIGTERM handler, capture failure path) tears down
capture, encoder, sockets and the virtual display; after each run
`--list-displays` shows only the built-in display again. A 6 s hard watchdog in
the shutdown path forces `_exit` if any teardown step blocks, and the
`--seconds` auto-exit path is covered by the same code.

### 11.10 Capture stall from the first tablet run — fixed and verified

An early end-to-end run on the tablet froze after ~40 s (frames/captureFps stayed
constant; the page showed a frozen frame) while many short-lived `/mjpg`
reconnections were happening. Fixes (all verified, see §11.13):

- prevent **App Nap** for the whole run (`ProcessInfo.beginActivity`
  `userInitiated|idleSystemSleepDisabled|latencyCritical`) — most likely cause of
  a capture freeze while the user interacts with the tablet, not the Mac;
- **capture watchdog**: if no frame arrives for >2 s it re-publishes the cached
  frame (keeps MJPEG/native clients fed, logs a warning), and after >6 s without
  frames it restarts the `SCStream` (rate-limited to once per 12 s);
- `SCStream.didStopWithError` restarts capture instead of terminating the host;
- MJPEG clients keep their own one-frame slot + timer (already the case) and the
  histogram of `/status` now exposes `mjpegFps`/`mjpegKbps` so the HUD is
  accurate;
- input events are logged with normalized + global coordinates in `--verbose`;
- `/mjpg` rejects a 9th concurrent viewer with `503` and drops socket sends that
  stall for >5 s (half-open TCP after tablet sleep);
- the log file is rotated at 5 MB (`halolink-host.log.1`).

Stress test result: **no freeze** with 4 concurrent MJPEG viewers reconnecting 41
times each (164 connections) over 50 s — frames and JPEG counters kept increasing
every sample, no watchdog restart was needed.

### 11.11 `--auto` adaptive resolution / fps (verified with a simulated tablet)

A Python peer (in `/tmp`, not part of the repo) plays the tablet server and sends
the `hello` message; the host runs as TCP client with a **real virtual display**.

Compatible panel — `2800x1840 @144 Hz` (the real MatePad):

```
[halolink] tablet screen PythonTestTablet: 2800x1840 density=2.00 hz=144
[halolink] auto: stream fps = min(--fps 60, tablet 144Hz) = 60
[halolink] auto: virtual display 2800x1848 is compatible with tablet panel 2800x1840; keeping it
[halolink] HLDP -> config: 2800x1848@60fps codec=h264 profile=main bitrate=24000000
[peer] RESULT frames=118 … (ffprobe: 2800x1848, 118 frames decoded)
```

Mismatching panel — `2560x1600 @60 Hz` (exercises the runtime reconfiguration):

```
[halolink] auto: tablet panel 2560x1600 differs from virtual display 2800x1848
           (aspect delta 5.3%, size delta 8.9%) — adapting
[halolink] auto: reconfiguring stream 2800x1848@60fps -> 2560x1600@60fps …
[halolink] auto: stream reconfiguration complete — 2560x1600@60fps
[halolink] HLDP -> config: 2560x1600@60fps codec=h264 profile=main bitrate=24000000
[peer] <- config: {"width": 2560, "height": 1600, "fps": 60, …}
[peer] RESULT frames=197 …   (ffprobe: width=2560 height=1600 nb_read_frames=197)
```

The virtual display's `system_profiler` entry changed from 2800×1848 to
2560×1600 (1280×800 pt @2x) and the stream continued after the single
stop/reconfigure/start cycle. Reconfiguration is rate limited (10 s) and skipped
when the panel is already compatible.

### 11.12 Frame-rate capabilities (`--fps`)

Measured with `--synthetic` (deterministic generator, so capture is never the
bottleneck) at 2800×1848, 24 Mbps, real-time hardware H.264:

| requested fps | captured fps | actually encoded fps | notes |
|---|---|---|---|
| 60 | 60.0 | 60.0 | default; stable |
| 90 | 90.0 | ~85–88 | works; occasional encoder drops counted in `dropped` |
| 120 | 120.0 | ~82–90 | capture runs at 120, VT hard encoder tops out ≈85–90 fps at 5.2 MP; drops are reported |

CPU for the 120 fps synthetic run: `0.36 s user + 0.17 s sys` over 5.4 s wall
(≈10% of one M2 core — the hardware encoder does the heavy lifting; the synthetic
frame generator dominates here). Recommendation: **60 fps** for the tablet
(144 Hz panel), 90 fps is usable, 120 fps at native 2800×1848 exceeds the
encoder's throughput and is not recommended.

### 11.13 MJPEG churn / long-run stress test (60 s)

```
$ halolink-host --seconds 62 --http-port 28088 --demo --verbose
# 4 background loops act as 4 browser tabs, each reconnecting /mjpg every ~1.2 s
samples every 5 s:
frames=96  jpeg=66  captureFps=21.0 clients=4 mjpegFps=11.3 mjpegKbps=7677
frames=253 jpeg=199 captureFps=11.0 clients=4 mjpegFps=8.9  mjpegKbps=6020
frames=408 jpeg=329 captureFps=10.5 clients=4 mjpegFps=8.2  mjpegKbps=5577
frames=565 jpeg=461 captureFps=10.5 clients=4 mjpegFps=9.3  mjpegKbps=6160
…
[halolink] summary: captured=… jpeg=461 … uptime=62s
```
164 short-lived MJPEG connections in 50 s; counters keep increasing, `captureFps`
stays ~10 (the demo window animates at 10 fps), **no watchdog restart and no
freeze**, no errors in the log, host exits cleanly and leaves no virtual display.

### 11.14 Input injection precision + diagnostics

`POST /input` with a single tap at normalized (0.25, 0.6), virtual display bounds
`(1470,0,1400x924)`:

```
[halolink] DEBUG: web /input: {"type":"touch","action":"down","x":0.25,"y":0.6,"pointerId":0}
[halolink] DEBUG: input touch action=down normalized=(0.2500,0.6000) -> global=(1820.0,554.4) bounds=(1470,0,1400x924)
cursor before: (898.24, 487.73)
cursor after:  (1820.00, 554.40)     ← exact, 0.0 pt error
drag to (0.75, 0.25) → cursor (2520.00, 231.00)  ← exact
```
`--verbose` logs `web /input: …` (raw JSON) and
`input touch action=… normalized=(x,y) -> global=(px,py) bounds=…` for every
non-move event (moves every 30th), which is the calibration aid requested for
edge-tap diagnosis. The mapping keeps the pointer inside the display bounds, so
edge taps can no longer be clamped onto the neighbouring display.

### 11.15 Mirror mode + single-instance lock (regression checks)

```
$ halolink-host --display-mode mirror --duration 4 --no-web --dump-h264 /tmp/hl-mirror2.h264
[halolink] display-mode=mirror: capturing the main display (2940x1912px) — no extended desktop
[halolink] READY display=0 … capture=2940x1912@60 mode=mirror hidpi=1x http=off …
[halolink] summary: captured=228 encoded=228 (2.3 MB) keyframes=4 …
ffprobe → width=2940 height=1912 nb_read_frames=228     (--duration works as §--seconds alias)
```

```
$ halolink-host --seconds 12            # first instance (owns the display)
$ halolink-host --seconds 5             # second instance
[halolink] ERROR: another HaloLink host is already running (pid 19067);
           lock file: ~/Library/Application Support/HaloLink/host.lock
second instance exit=4
```

### 11.16 SIGINT / auto-exit teardown

```
$ halolink-host --seconds 60 --http-port 28090
   (virtual display id=102 online, 1400x924 @2x, arranged at (1470,0))
$ kill -INT <pid>
[halolink] received SIGINT
[halolink] shutting down (SIGINT) …
[halolink] summary: …
[halolink] virtual display 102 destroyed
[halolink] goodbye (reason=SIGINT, exit=0)
# afterwards: online displays = 1 (only the built-in display), no halolink-host process
```
The same clean teardown was observed for `--seconds` auto-exit and for every
acceptance run; a 6 s hard watchdog in the shutdown path guarantees the process
exits (and therefore WindowServer drops the virtual display) even if a teardown
step blocks.


### 11.17 双击 HaloLink.app（GUI，真实平板 Wi-Fi 联调）

```
$ open macos-host/HaloLink.app          # 双击等价；本机已为 HaloLink 身份授予屏幕录制
# 进程存在，窗口 560x688：owner=HaloLink name=HaloLink
# 日志（~/Library/Logs/HaloLink/halolink-host.log）：
[halolink] app launching (GUI mode)
[halolink] Screen Recording permission: granted
[halolink] HDCP... (skipped USB for this run)
[halolink] HLDP transport: connecting to tablet server <tablet-ip>:9528
[halolink] HLDP hello from HUAWEI MatePad 11.5''S screen=2800x1840 density=2.5 hz=144
[halolink] READY display=134 … capture=2800x1848@60 logical=1400x924 mode=virtual hidpi=2x …
[halolink] session running: display=134 capture=2800x1848@60 logical=1400x924 input=off
[halolink] stats fps=17.5 captureFps=17.5 kbps=1074 encoded=81 sent=81 keyframes=6
           peer(fps=74.0 decode=39.7ms) transport=ready
```
Window screenshot: `test-artifacts/halolink-app-window.png` (状态运行中 ●、已连接
<tablet-ip>:9528（推流中）、2800×1848 px (2x)、逻辑 1400×924 pt · fit、
17.5 fps · 1074 kbps、触摸控制 关（默认）· 平板：关)。SIGTERM/退出后进程与虚拟
显示屏均无残留。

### 11.18 竖屏自动旋转（模拟平板 server；host 真实虚拟屏）

Python peer 发送横屏 hello，6 s 后发送
`{"type":"display","width":1840,"height":2800,"orientation":"portrait","refreshRate":144}`：

```
[peer] config[0]: width=2800 height=1848 fps=60 scaleMode=fit retina=True
                  logical=1400x924 inputEnabled=False
[peer] -> display change: {"type":"display","width":1840,"height":2800,
                           "orientation":"portrait","refreshRate":144}
[peer] config[2]: width=1840 height=2808 fps=60 scaleMode=fit retina=True
                  logical=920x1404 inputEnabled=False
[halolink] display change received … — debounced 0.45s
[halolink] applying display change: orientation=portrait target=1840x2808@60fps
[halolink] stream reconfiguration complete — 1840x2808@60fps logical=920x1404
[halolink] HLDP -> config (update): 1840x2808@60fps scaleMode=fit retina=true logical=920x1404 input=false
```
帧文件：旋转前 2800×1848（58 帧），旋转后 **1840×2808**（76 帧），均由 ffprobe
正常解码；主屏保持 main=1、显示器未镜像、退出后无残留。

### 11.19 `--scale-match-main`（与 Mac 内建屏一致）

```
[halolink] HiDPI 2x backing active: desktop 1470x956 pt / 2940x1912 px
[halolink] READY display=130 … capture=2940x1912@60 logical=1470x956 … scale=matchMain …
[peer] config[0]: width=2940 height=1912 fps=60 scaleMode=fit retina=True
                  logical=1470x956 inputEnabled=False
```

### 11.20 输入默认关闭 / 手动开启

默认 `--input off`：Web `POST /input` 触摸事件后系统光标**完全不动**
（before=after=(1216.59,457.74)），日志：
`ignoring tablet input frames: touch control is OFF …`。
`--input on` 时同一事件精确落点：normalized (0.3,0.4) →
`global=(1890.0,369.6)`（期望 1470+0.3×1400=1890，0.4×924=369.6），日志有
`input touch action=down … -> global=(1890.0,369.6) bounds=(1470,0,1400x924)`。

### 11.21 App 内置 hdc（USB 自动连接命令构造）

`make_app.sh` 打包后：

```
$ HaloLink.app/Contents/Resources/bin/hdc list targets -v
YOUR_DEVICE_SERIAL        USB     Connected       localhost       hdc
$ .build/release/halolink-host --hdc-probe
hdc: …/HaloLink.app/Contents/Resources/bin/hdc
target: serial=YOUR_DEVICE_SERIAL transport=USB state=Connected usb=true
usb_auto_connect: available
```
用 stub hdc 验证自动连接命令序列（不触碰真实平板）：

```
FAKEHDC-CALL: list targets -v
FAKEHDC-CALL: -t FAKE0001 shell aa start -a EntryAbility -b com.halolink.display
FAKEHDC-CALL: -t FAKE0001 fport rm tcp:19528
FAKEHDC-CALL: -t FAKE0001 fport tcp:19528 tcp:9528
prepareUSBConnection: 127.0.0.1:19528
```

### 11.22 最终打包验收

```
$ rm -rf .build && swift build -c release      → Build complete! (48s)
$ bash scripts/make_app.sh                      → HaloLink.app（hdc+libusb 打包、自签、verify 通过）
$ codesign --verify --deep --strict HaloLink.app → OK
$ halolink-host --list-displays                 → 仅内建屏（无残留虚拟屏）
$ halolink-host --seconds 7 --save-frames /tmp/f --demo --dump-h264 /tmp/f.h264 --http-port 28096
   READY display=135 … capture=2800x1848@60 logical=1400x924 mode=virtual hidpi=2x input=off
   /status: 2800x1848 logical=1400x924 retina=True scaleMode=fit input=False
   /mjpg 35 帧 multipart JPEG；/healthz ok
   8×PNG 2800×1848（meanGray 0x0b…0x2c，非黑屏）
   ffprobe: Main 2800x1848 bt709, 108 帧；ffmpeg -f h264 -f null - → rc=0
$ halolink-host --synthetic --listen … + Python peer → 358 帧 @60.0fps，ffprobe 358 帧
$ SIGINT → exit=0，虚拟显示屏摘除，无残留进程
```

### 11.23 App UI 改版（连接方式 / 分辨率语义）

用户反馈「不能选无线还是 USB」「虚拟屏尺寸看不懂哪个是 HiDPI」后改版：
- 新增 **连接方式：自动 / USB 有线 / 无线**（持久化；USB 无设备时红字报错，不静默
  退回无线；状态栏显示真实通道如 `已连接 · USB 有线 (127.0.0.1:19528)（推流中）`）；
- 虚拟屏尺寸改为带完整解释的单选：
  **贴合平板：2800×1848 @2x（逻辑 1400×924）— 推荐** /
  **贴合 Mac 内置屏：2940×1912 @2x（逻辑 1470×956）**，明确标注均为 2x HiDPI，
  并实时显示 `当前虚拟屏 … · 平板屏 … · 比例差异 x.x%` 与组合建议；
- 显示模式改为下拉：**完整显示（可能留黑边）** / **裁剪填满（无黑边，可能裁掉边缘）**，
  并注明只影响平板端缩放、不影响虚拟屏分辨率。

由于改版测试时用户正在使用旧版 App（单实例锁 + 正在推流），未启动第二个推流会话；
用 `HALOLINK_UI_ONLY=1 HALOLINK_LOCK_PATH=/tmp/hl-ui.lock` 做了纯 UI 预览截图：
`test-artifacts/halolink-app-window-v2.png`（720×880 深色窗口，控件无截断）。
构建/打包/签名/内置 hdc 全部重新验证：

```
$ swift build -c release              → Build complete!
$ bash scripts/make_app.sh            → HaloLink.app（hdc 6.5MB + libusb，自签）
$ codesign --verify --deep --strict   → OK
$ HaloLink.app/Contents/MacOS/halolink-host --version → 1.1.0 (HLDP v1.1)
$ HaloLink.app/Contents/MacOS/halolink-host --hdc-probe
  target: serial=YOUR_DEVICE_SERIAL transport=USB state=Connected usb=true
```
新 UI/连接方式切换需用户退出旧 App 后重新双击打开验收（USB 强制模式与无线模式
的实机切换待用户/lead 确认）。

### 11.24 HLDP v1.2 虚拟屏两种渲染模式（实测）

两种模式各创建一次（真实虚拟屏 + Python 模拟平板；测试用独立 display serial
与 `HALOLINK_TEST_SKIP_ARRANGE=1`，不影响用户正在运行的实例）：

**原生 1:1 像素 (`--render-mode pixel1to1`)**
```
[halolink] virtual display created: id=168 capacity=2800x2808 …
[halolink] extended desktop active: … capture=2800x1840px logical=2800x1840pt
           renderMode=pixel1to1 achieved=2800×1840 px = 2800×1840 pt (1x)
[peer] config[0]: width=2800 height=1840 fps=60 scaleMode=fit retina=False
                  logical=2800x1840 inputEnabled=False
raw config: {"renderMode":"pixel1to1","retina":false,"logicalWidth":2800,
             "logicalHeight":1840,"protocol":"halolink/1.2",…}
ffprobe 收到的 H.264: width=2800 height=1840, 34 帧
```

**HiDPI 最大化 (`--render-mode scale`，默认)**
```
[halolink] HiDPI 2x backing active: desktop 1400x920 pt / 2800x1840 px
[halolink] extended desktop active: … capture=2800x1840px logical=1400x920pt
           renderMode=scale achieved=2800×1840 px = 1400×920 pt (2x HiDPI)
[peer] config[0]: width=2800 height=1840 fps=60 scaleMode=fit retina=True
                  logical=1400x920 inputEnabled=False
raw config: {"renderMode":"scale","retina":true,"logicalWidth":1400,
             "logicalHeight":920,"protocol":"halolink/1.2",…}
ffprobe: width=2800 height=1840
```
即 **HiDPI 模式精确达到 2800×1840 @2x，平板端 0 裁切**（用户要求的候选 1 已实现），
`--list-displays` 确认像素/逻辑/比例与上述一致，退出后无残留（在线 HaloLink 屏只剩
用户正在使用的那一块）。

运行中切换：scale → pixel1to1（有 2x 句柄，进程内切换成功）；pixel1to1 → scale
在测试进程中因未捕获 2x 句柄无法完成，App 会自动保存选择并重启自身完成切换
（见 §6.7）。最终打包：`swift build -c release`、`bash scripts/make_app.sh`、
`codesign --verify --deep --strict HaloLink.app` 全部通过；新 UI 截图
`test-artifacts/halolink-app-window-v3.png`。

### 11.25 HLDP v1.3 延迟测量（host 侧）

基线（仅加埋点、未优化）与优化后各跑一轮（独立锁路径/独立 display serial，不影响
用户正在运行的 App）：

- 合成源 60 fps、回环 TCP、平板端模拟（frameTs 能力协商）：config 回显
  `"frameTs": true, "protocol": "halolink/1.3"`，Python peer 验证 719 帧全部带
  8 字节时间戳且单调递增（`framesWithTs=719 monotonic=True`）；基线
  `enc avg/p95=31.6/36.3ms`、`snd=0.1ms`、`rtt=0.2ms`。
- 优化后同一测试：日志 `VT low-latency rate control: enabled · PrioritizeEncodingSpeed
  OverQuality=on · outstandingLimit=2`；`enc avg/p95=14.3–28.7 / 35.5–40.8ms`
  （用户 App 同时在推 60fps 造成编码器竞争，帧率下降到 50–56、dropped 30–130）；
  编码完成后 `sendMs=0.1–0.2ms` 证明无攒批/额外排队。
- 真实虚拟屏（2800×1840）+ demo 动画：`captureMs avg/p95=87/116ms`（SCK 变化驱动，
  demo 仅 10fps）、`encodeMs 13.7/21.9ms`、`sendMs 0.2/0.3ms`。
- 兼容性：不带 frameTs 的旧平板 → config `frameTs:false`、payload 无前缀，peer 正常
  收流 276 帧 PASS。
- USB 通道：`hdc shell true` 往返 83–137ms（上界）；USB 网络共享接口不存在；
  9–14ms 的 fport PING/PONG 需与平板联合复测。
- 打包：`swift build -c release`、`bash scripts/make_app.sh`、
  `codesign --verify --deep --strict HaloLink.app` 通过，版本 `1.3.0 (HLDP v1.3)`。

### 11.26 v1.3.1 联调 bug 修正（2026-11-22）

- **时钟域修正（保留 lead 的 epoch 修复并核查）**：wire 时间戳统一
  `Clock.epochMicroseconds()`（Unix epoch µs，平板时钟域）；内部耗时仍用
  `Clock.now()`（uptime）。grep 确认无 `UInt64(now*1e6)` 等 uptime-µs 泄漏到 wire；
  Python peer 验证 554/554（合成）、110/110（真实虚拟屏）帧 `epochOk`，`epochBad=0`。
- **encodeMs 修正**：VT `sourceFrameRefcon` 改为携带 `FrameTimingBox{ captureEpochUs,
  submitUptimeNs }`（epoch 只用于 wire，uptime 只用于算耗时），回调/同步失败路径都正确
  release；实测 `/status` `encodeMsAvg/P95` 非 0：真实虚拟屏 14.0/23.4ms、合成 60fps
  18–37/38–47ms（用户 App 同时推流，硬编竞争），`sendMs=0.1–0.2ms`、`rtt` 正常。
- **stats 字段核对**：v1.3 联调日志显示平板同时上报 `decodeMs=19.2`（HUD 的“解码”）
  与 `decMs=611.3`（v1.3 阶段值，存在平板侧时钟/FIFO 配对偏差），host 现按原字段分开
  显示：`lat … dec=611.3 decodeMs=19.2 …`，`/status` 增加 `decMsReported`、
  `decodeMs`、`tabletRttMs`、`tabletStatsAge`，并在二者严重不一致时给出
  `tabletLatencyAnomaly` 提示（平板修复后自动消失，已验证一致数据 dec=9.8 /
  decodeMs=18.9 / e2e=19.3 时无告警）。
- 临时 debug 清理：LinkTransport 的 INFO 级 `DEBUG frameTs` 改为仅 verbose 首次
  debug；保留 `peer stats raw`（verbose）便于后续联调。
- 版本 `1.3.1 (HLDP v1.3)`，`make_app.sh` 重新打包、codesign 校验通过。
