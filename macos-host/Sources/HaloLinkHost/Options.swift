//
//  Options.swift
//  HaloLink macOS host
//
//  Hand-rolled command line parser (no external deps). Supports "--flag value"
//  and "--flag=value" forms.
//

import Foundation

enum DisplayModeOption: String {
    case virtual   // create a CGVirtualDisplay (real extended display) — default
    case mirror    // no virtual display: capture the main display (fallback)
}

enum HIDPIOption: String {
    case auto   // attempt a 2x backing store, accept whatever macOS gives us
    case on     // same as auto (kept for symmetry; verified + reported)
    case off    // 1x framebuffer (crisp pixels, small UI)
}

/// Virtual display rendering mode (HLDP v1.2).
enum RenderMode: String, CaseIterable {
    /// 原生 1:1 像素模式：虚拟屏 = 平板原生分辨率（2800x1840, 1x），平板逐像素显示。
    case pixel1to1
    /// HiDPI 最大化：取平板分辨率下 macOS 支持的最大 2x 模式（2800x1840 @2x 优先），
    /// 平板端少量裁切。
    case hidpiScale = "scale"
    /// 高级 CLI 参数（主界面不出现）：虚拟屏 = Mac 主屏几何（2940x1912 @2x）。
    case matchMain

    var title: String {
        switch self {
        case .pixel1to1: return "原生 1:1 像素"
        case .hidpiScale: return "HiDPI 最大化"
        case .matchMain: return "贴合 Mac 内置屏（高级）"
        }
    }
}

/// What the virtual display shows with respect to the tablet panel (config field).
enum ScaleModeOption: String {
    case fit    // letterbox
    case fill   // crop to fill
}

struct Endpoint {
    let host: String
    let port: UInt16

    var description: String { "\(host):\(port)" }

    static func parse(_ raw: String, defaultPort: UInt16 = 9528) -> Endpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            // [::1]:9528
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            var port = defaultPort
            let after = trimmed[trimmed.index(after: close)...]
            if after.hasPrefix(":") {
                guard let p = UInt16(after.dropFirst()) else { return nil }
                port = p
            }
            return Endpoint(host: host, port: port)
        }
        guard let colon = trimmed.lastIndex(of: ":") else {
            return Endpoint(host: trimmed, port: defaultPort)
        }
        let host = String(trimmed[..<colon])
        guard !host.isEmpty, let port = UInt16(trimmed[trimmed.index(after: colon)...]) else {
            return nil
        }
        return Endpoint(host: host, port: port)
    }
}

struct Options {
    // Display
    var width: UInt32 = 2800
    var height: UInt32 = 1848       // 2800x1848 supports a 2x (HiDPI) mode on macOS
    var fps: Int = 60
    var hidpi: HIDPIOption = .auto
    /// --auto (default): adapt the virtual display / stream to the tablet's
    /// reported panel size and refresh rate after the HLDP hello message.
    /// Explicit --width/--height/--fps always win over auto adaptation.
    var auto = true
    /// v1.2: virtual display rendering mode.
    var renderMode: RenderMode = .hidpiScale
    /// v1.1 config.scaleMode (rendered on the tablet).
    var scaleMode: ScaleModeOption = .fit
    /// v1.1: touch/keyboard injection总开关, default OFF.
    var inputEnabled = false
    var widthExplicit = false
    var heightExplicit = false
    var fpsExplicit = false
    var displayMode: DisplayModeOption = .virtual
    var displayName: String = "HaloLink Display"
    var showCursor = true

    // Encoding
    var bitrate: Int = 24_000_000
    var profile: String = "main"

    // Transport
    var connect: Endpoint? = nil
    var listen: Endpoint? = nil

    // Web
    var httpPort: Int = 8080
    var noWeb = false
    var webWidth: Int = 1600
    var webQuality: Double = 0.55
    var webFps: Int = 30

    // Utilities / testing
    var listDisplays = false
    var verbose = false
    var saveFrames: String? = nil
    var dumpH264: String? = nil
    var seconds: Double? = nil
    var demo = false
    var synthetic = false
    var gui = false
    /// Diagnostics: print hdc discovery + `hdc list targets -v` and exit (read-only).
    var hdcProbe = false
    var showHelp = false

    var hasTransportTarget: Bool { connect != nil || listen != nil }
    var webEnabled: Bool { !noWeb && httpPort > 0 }

    static let usage: String = """
    HaloLink macOS host — turn a HarmonyOS tablet into a real extended display.

    USAGE:
      halolink-host [options]

    DEFAULT (no --connect / --listen):
      Creates a virtual extended display and serves the browser fallback:
      open http://<mac-lan-ip>:8080/ on the tablet (no app install needed).

    DISPLAY / CAPTURE:
      --render-mode <m>       pixel1to1 | scale   (v1.2, default scale)
                               pixel1to1: virtual display = tablet native 2800x1840 1x
                                          (tablet shows it 1:1, no scaling, small UI)
                               scale    : largest 2x HiDPI mode for the tablet panel
                                          (2800x1840 @2x = 1400x920 pt preferred;
                                           tablet crops a few edge pixels)
      --scale-match-main      Advanced: virtual display = Mac main screen geometry
                              (1470x956 @2x -> 2940x1912 px); not shown in the app UI
      --scale-mode <m>        fit | fill   (default fit; only meaningful in scale mode)
      --input <off|on>        Touch/keyboard injection (default OFF, v1.1)
      --width <px>            Virtual display framebuffer width  (default 2800)
      --height <px>           Virtual display framebuffer height (default 1848)
                              (use 2800x1840 for exact MatePad panel pixels; macOS
                               only offers a 1x mode for that 35:23 aspect ratio)
      --fps <n>               Frame rate: capture + encode + refresh (default 60)
      --display-mode <mode>   virtual | mirror   (default virtual)
      --hidpi <mode>          auto | on | off    (default auto = request 2x backing)
      --auto / --no-auto      adapt display size + fps to the tablet's reported
                              screen (HLDP hello); default on. Explicit
                              --width/--height/--fps override the adaptation.
      --name <text>           Virtual display name (default "HaloLink Display")
      --no-cursor             Hide the mouse cursor in the captured stream

    ENCODING:
      --bitrate <bps>         H.264 average bitrate (default 24000000 = 24 Mbps)
      --profile <p>           main | high  (default main, best decoder compat)

    TRANSPORT (HLDP v1 — Mac is the TCP *client*; tablet app is the server):
      --connect <host:port>   Dial the tablet server (e.g. 192.168.1.10:9528)
      --listen <host:port>    Reverse/debug mode: accept one inbound peer
                              (e.g. --listen 0.0.0.0:9528). Default port 9528.

    WEB FALLBACK (default on):
      --http-port <n>         HTTP/MJPEG port (default 8080, 0 disables)
      --web-width <px>        Default MJPEG downscale width (default 1600)
      --web-quality <0..1>    Default JPEG quality (default 0.55)
      --web-fps <n>           Default MJPEG fps (default 30)
      --no-web                Disable the HTTP server

    TESTING / AUTOMATION:
      --list-displays        Print online displays and exit
      --save-frames <dir>    Save up to 8 captured PNG frames (testing evidence)
      --dump-h264 <path>     Write the raw H.264 Annex-B stream to <path>
      --seconds <n>          Auto-exit after n seconds (alias: --duration)
      --demo                 Show a clock + colour-bars window on the virtual display
      --synthetic            Test mode: generate synthetic frames instead of capturing
                             (no Screen Recording permission needed; for CI/protocol tests)
      --verbose              Verbose logging

    MISC:
      -h, --help             Show this help
      --version              Print version

    EXAMPLES:
      halolink-host                                   # web-only mode (tablet browser)
      halolink-host --connect 192.168.1.10:9528      # native tablet app
      halolink-host --display-mode mirror --no-web    # mirror main screen
      halolink-host --seconds 8 --save-frames /tmp/f --verbose   # smoke test
    """

    static func parse(_ arguments: [String]) -> Options {
        var argv = arguments
        var options = Options()
        var index = 1
        func fail(_ message: String) -> Never {
            Log.error(message)
            Log.info("run with --help for usage")
            exit(1)
        }
        func value(_ flag: String) -> String {
            if index + 1 < argv.count {
                index += 1
                return argv[index]
            }
            fail("missing value for \(flag)")
        }
        func intValue(_ flag: String) -> Int {
            let raw = value(flag)
            guard let n = Int(raw) else { fail("invalid integer for \(flag): \(raw)") }
            return n
        }
        while index < argv.count {
            var arg = argv[index]
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                // Split --flag=value into flag + inline value by rewriting argv.
                let flag = String(arg[..<eq])
                let inline = String(arg[arg.index(after: eq)...])
                argv.insert(inline, at: index + 1)
                arg = flag
            }
            switch arg {
            case "-h", "--help":
                options.showHelp = true
            case "--version":
                Log.info("halolink-host 1.3.1 (HLDP v1.3)")
                exit(0)
            case "--list-displays":
                options.listDisplays = true
            case "--width":
                options.width = UInt32(clamping: intValue(arg))
                options.widthExplicit = true
                options.auto = false
            case "--height":
                options.height = UInt32(clamping: intValue(arg))
                options.heightExplicit = true
                options.auto = false
            case "--fps":
                options.fps = max(1, min(240, intValue(arg)))
                options.fpsExplicit = true
            case "--auto":
                options.auto = true
            case "--no-auto":
                options.auto = false
            case "--bitrate":
                options.bitrate = max(100_000, intValue(arg))
            case "--profile":
                let p = value(arg).lowercased()
                guard p == "main" || p == "high" else { fail("--profile must be main or high") }
                options.profile = p
            case "--display-mode":
                let m = value(arg).lowercased()
                guard let mode = DisplayModeOption(rawValue: m) else {
                    fail("--display-mode must be virtual or mirror")
                }
                options.displayMode = mode
            case "--hidpi":
                let m = value(arg).lowercased()
                guard let mode = HIDPIOption(rawValue: m) else {
                    fail("--hidpi must be auto, on or off")
                }
                options.hidpi = mode
            case "--render-mode":
                let m = value(arg).lowercased()
                switch m {
                case "pixel1to1", "pixel", "1to1", "1:1": options.renderMode = .pixel1to1
                case "scale", "hidpi", "max": options.renderMode = .hidpiScale
                case "match-main", "matchmain": options.renderMode = .matchMain
                default: fail("--render-mode must be pixel1to1 or scale")
                }
            case "--pixel-1to1":
                options.renderMode = .pixel1to1
            case "--hidpi-max":
                options.renderMode = .hidpiScale
            case "--scale-tablet":
                // Legacy alias: tablet panel + HiDPI (now the default "scale" mode).
                options.renderMode = .hidpiScale
            case "--scale-match-main":
                // Advanced CLI-only mode; not exposed in the app UI.
                options.renderMode = .matchMain
            case "--scale-mode":
                let m = value(arg).lowercased()
                guard let mode = ScaleModeOption(rawValue: m) else {
                    fail("--scale-mode must be fit or fill")
                }
                options.scaleMode = mode
            case "--input":
                let m = value(arg).lowercased()
                guard m == "off" || m == "on" else { fail("--input must be off or on") }
                options.inputEnabled = (m == "on")
            case "--name":
                options.displayName = value(arg)
            case "--no-cursor":
                options.showCursor = false
            case "--connect":
                guard let ep = Endpoint.parse(value(arg)) else { fail("invalid --connect endpoint") }
                options.connect = ep
            case "--listen":
                guard let ep = Endpoint.parse(value(arg)) else { fail("invalid --listen endpoint") }
                options.listen = ep
            case "--http-port":
                options.httpPort = max(0, min(65535, intValue(arg)))
            case "--web-width":
                options.webWidth = max(160, min(3840, intValue(arg)))
            case "--web-quality":
                let raw = value(arg)
                guard let q = Double(raw) else { fail("invalid --web-quality: \(raw)") }
                options.webQuality = max(0.1, min(0.95, q))
            case "--web-fps":
                options.webFps = max(1, min(60, intValue(arg)))
            case "--no-web":
                options.noWeb = true
            case "--save-frames":
                options.saveFrames = value(arg)
            case "--dump-h264":
                options.dumpH264 = value(arg)
            case "--seconds", "--duration":
                let raw = value(arg)
                guard let s = Double(raw), s > 0 else { fail("invalid --seconds value") }
                options.seconds = s
            case "--demo":
                options.demo = true
            case "--gui":
                options.gui = true
            case "--hdc-probe":
                options.hdcProbe = true
            case "--synthetic":
                options.synthetic = true
            case "--verbose", "-v":
                options.verbose = true
            default:
                fail("unknown argument: \(arg)")
            }
            index += 1
        }
        if options.fps > 0 {
            options.webFps = min(options.webFps, options.fps)
        }
        return options
    }
}
