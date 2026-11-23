import { window, display, uiMaterial, promptAction } from '@kit.ArkUI';
import { displaySync } from '@kit.ArkGraphics2D';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { KeyCode } from '@kit.InputKit';
import { Log, LogLine } from '../common/Logger';
import { AppSettings, SettingsStore } from '../common/Settings';
import { DecoderBridge } from '../decoder/DecoderBridge';
import { DisplayServer, ServerListener, StreamStats } from '../net/DisplayServer';
import { CodecConfig, DEFAULT_PORT, LinkState } from '../net/Protocol';

function clamp01(value: number): number {
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}

/** Maps HarmonyOS KeyCode values to the HLDP "key" names understood by the Mac host. */
function keyNameOf(code: number): string {
  if (code >= KeyCode.KEYCODE_A && code <= KeyCode.KEYCODE_Z) {
    return String.fromCharCode('A'.charCodeAt(0) + (code - KeyCode.KEYCODE_A));
  }
  if (code >= KeyCode.KEYCODE_0 && code <= KeyCode.KEYCODE_9) {
    return String.fromCharCode('0'.charCodeAt(0) + (code - KeyCode.KEYCODE_0));
  }
  if (code >= KeyCode.KEYCODE_F1 && code <= KeyCode.KEYCODE_F12) {
    return `F${code - KeyCode.KEYCODE_F1 + 1}`;
  }
  switch (code) {
    case KeyCode.KEYCODE_DEL: return 'BACKSPACE';
    case KeyCode.KEYCODE_FORWARD_DEL: return 'FORWARD_DELETE';
    case KeyCode.KEYCODE_ENTER: return 'ENTER';
    case KeyCode.KEYCODE_ESCAPE: return 'ESCAPE';
    case KeyCode.KEYCODE_TAB: return 'TAB';
    case KeyCode.KEYCODE_SPACE: return 'SPACE';
    case KeyCode.KEYCODE_DPAD_UP: return 'UP';
    case KeyCode.KEYCODE_DPAD_DOWN: return 'DOWN';
    case KeyCode.KEYCODE_DPAD_LEFT: return 'LEFT';
    case KeyCode.KEYCODE_DPAD_RIGHT: return 'RIGHT';
    case KeyCode.KEYCODE_MOVE_HOME: return 'HOME';
    case KeyCode.KEYCODE_MOVE_END: return 'END';
    case KeyCode.KEYCODE_PAGE_UP: return 'PAGEUP';
    case KeyCode.KEYCODE_PAGE_DOWN: return 'PAGEDOWN';
    case KeyCode.KEYCODE_CTRL_LEFT: return 'CTRL';
    case KeyCode.KEYCODE_CTRL_RIGHT: return 'CTRL_RIGHT';
    case KeyCode.KEYCODE_SHIFT_LEFT: return 'SHIFT';
    case KeyCode.KEYCODE_SHIFT_RIGHT: return 'SHIFT_RIGHT';
    case KeyCode.KEYCODE_ALT_LEFT: return 'ALT';
    case KeyCode.KEYCODE_ALT_RIGHT: return 'ALT_RIGHT';
    case KeyCode.KEYCODE_META_LEFT: return 'META';
    case KeyCode.KEYCODE_META_RIGHT: return 'META_RIGHT';
    case KeyCode.KEYCODE_CAPS_LOCK: return 'CAPSLOCK';
    case KeyCode.KEYCODE_MENU: return 'MENU';
    // Punctuation is sent as the literal US-layout character: the Mac host's
    // InputInjector maps "a".."z", "0".."9", "-", "=", "[", "]", "\\", ";",
    // "'", ",", ".", "/", "`" directly to CGKeyCode.
    case KeyCode.KEYCODE_MINUS: return '-';
    case KeyCode.KEYCODE_EQUALS: return '=';
    case KeyCode.KEYCODE_LEFT_BRACKET: return '[';
    case KeyCode.KEYCODE_RIGHT_BRACKET: return ']';
    case KeyCode.KEYCODE_BACKSLASH: return '\\';
    case KeyCode.KEYCODE_SEMICOLON: return ';';
    case KeyCode.KEYCODE_APOSTROPHE: return "'";
    case KeyCode.KEYCODE_COMMA: return ',';
    case KeyCode.KEYCODE_PERIOD: return '.';
    case KeyCode.KEYCODE_SLASH: return '/';
    case KeyCode.KEYCODE_GRAVE: return '`';
    default: return `KEYCODE_${code}`;
  }
}

/**
 * HaloLink tablet client page.
 *
 * UI policy (user feedback): no hand-made "glass" surfaces and no looping light
 * animations. Every surface is a standard ArkUI component; the official
 * HarmonyOS 26 immersive material (`systemMaterial` + `uiMaterial`) is applied
 * where the platform supports it, with the system default look as fallback.
 */
@Entry
@Component
struct Index {
  // ---- connection / session state
  @State linkState: string = LinkState.IDLE;
  @State stateDetail: string = '正在启动…';
  @State serverRunning: boolean = false;
  @State localIp: string = '';
  @State port: number = DEFAULT_PORT;
  @State clientAddr: string = '';
  @State configText: string = '未连接';

  // ---- video surface geometry (vp)
  @State screenW: number = 1120;
  @State screenH: number = 736;
  @State videoW: number = 2800;
  @State videoH: number = 1840;
  @State boxW: number = 1120;
  @State boxH: number = 736;

  // ---- live stats
  @State rxFps: number = 0;
  @State decodedFps: number = 0;
  @State decodeMs: number = 0;
  // v1.3 latency breakdown (ms) + present rate
  @State recvMs: number = 0;
  @State renderMs: number = 0;
  @State e2eMs: number = 0;
  @State presentHz: number = 0;
  @State bitrateMbps: number = 0;
  @State decodedFrames: number = 0;
  @State droppedFrames: number = 0;
  @State droppedNoKeyframe: number = 0;
  @State queueFrames: number = 0;
  @State stalled: boolean = false;
  // ---- display / frame-rate adaptation
  @State screenPxW: number = 2800;
  @State screenPxH: number = 1840;
  @State density: number = 2.5;
  @State refreshRate: number = 60;
  @State streamFps: number = 0;
  @State syncExpected: number = 60;
  @State materialSupported: boolean = false;
  @State materialAppState: string = 'unknown';
  // ---- v1.1: orientation / display mode / input switch
  @State orientation: string = 'landscape';
  @State displayMode: string = 'fit';          // 'fit' | 'fill'
  @State touchEnabled: boolean = false;        // default OFF (v1.1)
  @State expectingRemoteConfig: boolean = false;
  @State lastDisplayNotify: string = '-';
  @State hudVisible: boolean = true;   // floating controls auto-hide (3s) while streaming
  // ---- v1.2 virtual display render mode
  @State renderMode: string = 'scale';        // 'pixel1to1' | 'scale' (from host config)
  @State virtualPxW: number = 0;
  @State virtualPxH: number = 0;
  @State virtualPtW: number = 0;
  @State virtualPtH: number = 0;
  @State virtualRetina: boolean = false;

  // ---- UI state
  @State showSettings: boolean = false;
  @State showLogs: boolean = false;
  @State textValue: string = '';
  @State portInput: string = `${DEFAULT_PORT}`;
  @State webUrlInput: string = '';
  @State decoderError: string = '';
  @State webMode: boolean = false;
  @State logLines: LogLine[] = [];
  @State surfaceReady: boolean = false;
  @State hintText: string = '';

  private xc: XComponentController = new XComponentController();
  private webController: webview.WebviewController = new webview.WebviewController();
  private decoder: DecoderBridge = new DecoderBridge((code: number, message: string): void => {
    this.handleNativeDecoderError(code, message);
  });
  private server: DisplayServer | null = null;
  private context: common.UIAbilityContext | null = null;
  private ipTimer: number = -1;
  private logTimer: number = -1;
  private pressedModifiers: string[] = [];
  private lastDecoderRecovery: number = 0;
  private lastToastTime: number = 0;
  private displaySyncInstance: displaySync.DisplaySync | null = null;
  private immersiveMaterial: uiMaterial.Material | undefined = undefined;
  private mainWindow: window.Window | null = null;
  private resizeDebounceTimer: number = -1;
  private configWaitTimer: number = -1;
  private hudTimer: number = -1;
  private vsyncCount: number = 0;
  private vsyncTimer: number = -1;
  private displayModeUserSet: boolean = false;

  aboutToAppear(): void {
    Log.i('Index aboutToAppear');
    this.context = getContext(this) as common.UIAbilityContext;
    this.measureScreen();
    this.initImmersiveMaterial();
    this.initDisplaySync();
    this.initServer();
    this.loadSettings();
    this.refreshLocalIp();
    this.ipTimer = setInterval(() => {
      this.refreshLocalIp();
    }, 5000);
    this.logTimer = setInterval(() => {
      if (this.showSettings && this.showLogs) {
        this.refreshLogs();
      }
    }, 1000);
    this.keepScreenOn(true);
  }

  aboutToDisappear(): void {
    if (this.ipTimer >= 0) {
      clearInterval(this.ipTimer);
      this.ipTimer = -1;
    }
    if (this.logTimer >= 0) {
      clearInterval(this.logTimer);
      this.logTimer = -1;
    }
    this.decoder.release();
    if (this.server !== null) {
      this.server.stop();
    }
    if (this.hudTimer >= 0) {
      clearTimeout(this.hudTimer);
      this.hudTimer = -1;
    }
    if (this.vsyncTimer >= 0) {
      clearInterval(this.vsyncTimer);
      this.vsyncTimer = -1;
    }
    if (this.displaySyncInstance !== null) {
      try {
        this.displaySyncInstance.stop();
      } catch (err) {
        Log.w(`displaySync stop failed: ${JSON.stringify(err)}`);
      }
      this.displaySyncInstance = null;
    }
  }

  // ================================================================ lifecycle

  private measureScreen(): void {
    window.getLastWindow(this.context).then((win: window.Window) => {
      this.mainWindow = win;
      try {
        // v1.1: follow runtime rotation / window resize (auto-rotation).
        win.on('windowSizeChange', (size: window.Size) => {
          this.handleWindowSizeChange(size);
        });
        Log.i('windowSizeChange listener registered');
      } catch (err) {
        Log.w(`on(windowSizeChange) failed: ${JSON.stringify(err)}`);
      }
      const props: window.WindowProperties = win.getWindowProperties();
      const w = px2vp(props.windowRect.width);
      const h = px2vp(props.windowRect.height);
      if (w > 0 && h > 0) {
        this.screenW = w;
        this.screenH = h;
        this.updateVideoBox();
      }
      Log.i(`window size ${w.toFixed(1)}x${h.toFixed(1)} vp`);
      try {
        const panel = display.getDefaultDisplaySync();
        this.screenPxW = panel.width;
        this.screenPxH = panel.height;
        this.density = panel.densityPixels;
        // `refreshRate` is the current (adaptive) rate; supportedRefreshRates is
        // the panel capability. Use the maximum so hello/displaySync are honest.
        let maxRefresh = panel.refreshRate > 0 ? panel.refreshRate : 60;
        if (panel.supportedRefreshRates !== undefined && panel.supportedRefreshRates.length > 0) {
          maxRefresh = panel.supportedRefreshRates[panel.supportedRefreshRates.length - 1];
        }
        this.refreshRate = maxRefresh;
        this.orientation = this.screenPxW > this.screenPxH ? 'landscape' : 'portrait';
        Log.i(`panel ${this.screenPxW}x${this.screenPxH} density=${this.density} ` +
          `maxRefresh=${this.refreshRate}Hz current=${panel.refreshRate}Hz ` +
          `orientation=${this.orientation} ` +
          `supported=${JSON.stringify(panel.supportedRefreshRates)}`);
        if (this.server !== null) {
          this.server.setPanelInfo(this.screenPxW, this.screenPxH, this.density,
            this.refreshRate, this.orientation);
          this.server.setInputEnabled(this.touchEnabled);
        }
        this.updateVideoBox();
        this.applyFrameRateRange();
      } catch (err) {
        Log.w(`panel info unavailable: ${JSON.stringify(err)}`);
      }
    }).catch((err: BusinessError) => {
      Log.w(`getLastWindow failed: ${err.message}`);
    });
  }

  /** v1.1: window rotated / resized (auto-rotation). Debounced, then notifies Mac. */
  private handleWindowSizeChange(size: window.Size): void {
    if (this.resizeDebounceTimer >= 0) {
      clearTimeout(this.resizeDebounceTimer);
    }
    this.resizeDebounceTimer = setTimeout(() => {
      this.resizeDebounceTimer = -1;
      this.applyWindowSize(size);
    }, 250);
  }

  private applyWindowSize(size: window.Size): void {
    const w = px2vp(size.width);
    const h = px2vp(size.height);
    if (w <= 0 || h <= 0) {
      return;
    }
    this.screenW = w;
    this.screenH = h;
    try {
      const panel = display.getDefaultDisplaySync();
      this.screenPxW = panel.width;
      this.screenPxH = panel.height;
      this.density = panel.densityPixels;
      this.orientation = panel.width > panel.height ? 'landscape' : 'portrait';
      let maxRefresh = panel.refreshRate > 0 ? panel.refreshRate : 60;
      if (panel.supportedRefreshRates !== undefined && panel.supportedRefreshRates.length > 0) {
        maxRefresh = panel.supportedRefreshRates[panel.supportedRefreshRates.length - 1];
      }
      this.refreshRate = maxRefresh;
    } catch (err) {
      this.orientation = w > h ? 'landscape' : 'portrait';
      Log.w(`panel info after resize unavailable: ${JSON.stringify(err)}`);
    }
    this.updateVideoBox();
    Log.i(`window resized -> ${Math.round(w)}x${Math.round(h)}vp ` +
      `panel=${this.screenPxW}x${this.screenPxH} orientation=${this.orientation} ` +
      `displayMode=${this.displayMode}`);
    if (this.server !== null) {
      this.server.setPanelInfo(this.screenPxW, this.screenPxH, this.density,
        this.refreshRate, this.orientation);
      // Only notify the Mac once the binary channel is up (a frame sent during
      // the JSON handshake would confuse the host's line parser).
      if (this.linkState === LinkState.STREAMING) {
        this.server.sendDisplayChange(this.screenPxW, this.screenPxH,
          this.orientation, this.refreshRate);
        this.lastDisplayNotify = `${this.screenPxW}x${this.screenPxH} ${this.orientation} ` +
          `${this.refreshRate}Hz`;
        this.expectingRemoteConfig = true;
        if (this.configWaitTimer >= 0) {
          clearTimeout(this.configWaitTimer);
        }
        this.configWaitTimer = setTimeout(() => {
          this.configWaitTimer = -1;
          if (this.expectingRemoteConfig) {
            this.expectingRemoteConfig = false;
            Log.w('no new config from host within 4s after display change; ' +
              'keeping current layout (fit to new window)');
          }
        }, 4000);
      } else if (this.server !== null) {
        Log.i('display change stored; will be reported in the next hello');
      }
    }
    this.applyFrameRateRange();
  }

  /** v1.1: dev helper used for rotation testing (also proves the resize path). */
  private async forceOrientation(mode: string): Promise<void> {
    try {
      const win = this.mainWindow;
      if (win === null) {
        Log.w('forceOrientation: main window not ready');
        this.showToast('窗口未就绪，请稍后再试');
        return;
      }
      let target: window.Orientation = window.Orientation.AUTO_ROTATION;
      if (mode === 'landscape') {
        target = window.Orientation.LANDSCAPE;
      } else if (mode === 'portrait') {
        target = window.Orientation.PORTRAIT;
      }
      await win.setPreferredOrientation(target);
      Log.i(`preferred orientation -> ${mode}`);
      this.showToast(mode === 'auto' ? '已恢复自动旋转' : (mode === 'portrait' ? '已切换竖屏' : '已切换横屏'));
    } catch (err) {
      Log.w(`forceOrientation(${mode}) failed: ${JSON.stringify(err)}`);
      this.showToast('切换方向失败');
    }
  }

  /**
   * Official HarmonyOS 26 immersive material ("沉浸光感"). App-level switch:
   * module.json5 metadata `ohos.arkui.UIMaterial.state = enable`.
   */
  private initImmersiveMaterial(): void {
    try {
      const supported = uiMaterial.isImmersiveMaterialSupported();
      const info = uiMaterial.getMaterialInfo();
      this.materialSupported = supported;
      this.materialAppState = `${info.state}`;
      Log.i(`UIMaterial appState=${info.state} type=${info.type} ` +
        `isImmersiveMaterialSupported=${supported}`);
      if (!supported) {
        return;
      }
      const options: uiMaterial.ImmersiveOptions = {
        style: uiMaterial.ImmersiveStyle.THIN,
        materialColor: '#00000000',
        colorInvert: false,
        applyShadow: true,
        interactive: true,
        lightEffect: { color: '#4D7DD3FC' }
      };
      this.immersiveMaterial = new uiMaterial.ImmersiveMaterial(options);
      Log.i('ImmersiveMaterial(THIN) created for floating controls');
    } catch (err) {
      Log.w(`uiMaterial unavailable: ${JSON.stringify(err)}`);
    }
  }

  private initDisplaySync(): void {
    try {
      const ds = displaySync.create();
      ds.on('frame', (info: displaySync.IntervalInfo) => {
        // Vsync tick: count it to measure the real present rate (presentHz).
        this.vsyncCount++;
      });
      this.displaySyncInstance = ds;
      this.applyFrameRateRange();
      ds.start();
      if (this.vsyncTimer >= 0) {
        clearInterval(this.vsyncTimer);
      }
      this.vsyncTimer = setInterval(() => {
        this.presentHz = this.vsyncCount;
        this.vsyncCount = 0;
        if (this.server !== null) {
          this.server.setPresentHz(this.presentHz);
        }
      }, 1000);
      Log.i('displaySync started');
    } catch (err) {
      Log.w(`displaySync unavailable: ${JSON.stringify(err)}`);
      this.displaySyncInstance = null;
    }
  }

  /**
   * v1.3 latency: while streaming, pin the vsync pacing to the HIGHEST panel
   * rate (144Hz on this device) instead of the stream fps. Presenting at 144Hz
   * cuts the compositor wait after RenderOutputBuffer from ~1/30s to ~1/144s
   * (~8ms -> ~3.5ms). Idle UI keeps 60Hz to save power.
   */
  private applyFrameRateRange(): void {
    const ds = this.displaySyncInstance;
    if (ds === null) {
      return;
    }
    const deviceMax = this.refreshRate > 0 ? this.refreshRate : 60;
    const streaming = this.linkState === LinkState.STREAMING || this.webMode;
    const expected = streaming ? deviceMax : 60;
    const max = Math.max(deviceMax, expected);
    const min = streaming ? Math.min(60, deviceMax) : 30;
    const range: ExpectedFrameRateRange = { min: min, expected: expected, max: max };
    try {
      ds.setExpectedFrameRateRange(range);
      this.syncExpected = expected;
      Log.i(`displaySync range min=${min} expected=${expected} max=${max} ` +
        `(screen ${this.refreshRate}Hz, stream ${this.streamFps}fps)`);
    } catch (err) {
      Log.w(`displaySync setExpectedFrameRateRange failed: ${JSON.stringify(err)}`);
    }
  }

  private initServer(): void {
    const listener: ServerListener = {
      onStateChange: (state: LinkState, detail: string): void => {
        this.handleStateChange(state, detail);
      },
      onConfig: (config: CodecConfig): void => {
        this.handleConfig(config);
      },
      onStats: (stats: StreamStats): void => {
        this.handleStats(stats);
      },
      onDecoderError: (message: string): void => {
        this.decoderError = message;
        this.showToast(`解码器: ${message}`);
        Log.e(`decoder error surfaced: ${message}`);
      }
    };
    this.server = new DisplayServer(this.decoder, listener);
  }

  private loadSettings(): void {
    if (this.context === null) {
      return;
    }
    SettingsStore.load(this.context).then((loaded: AppSettings) => {
      this.port = loaded.port;
      this.portInput = `${loaded.port}`;
      this.webUrlInput = loaded.webUrl;
      this.webMode = loaded.webMode && loaded.webUrl.length > 0;
      this.displayMode = loaded.displayMode === 'fill' ? 'fill' : 'fit';
      this.displayModeUserSet = loaded.displayModeUserSet;
      this.touchEnabled = loaded.touchEnabled;
      this.updateVideoBox();
      if (this.server !== null) {
        this.server.setInputEnabled(this.touchEnabled);
        this.server.setPanelInfo(this.screenPxW, this.screenPxH, this.density,
          this.refreshRate, this.orientation);
      }
      Log.i(`settings applied: displayMode=${this.displayMode} ` +
        `(userSet=${this.displayModeUserSet}) touch=${this.touchEnabled}`);
      if (loaded.autoListen && !this.webMode) {
        this.startServer();
      }
    });
  }

  private saveSettings(): void {
    if (this.context === null) {
      return;
    }
    const parsedPort = parseInt(this.portInput, 10);
    if (!isNaN(parsedPort) && parsedPort > 0 && parsedPort < 65536) {
      this.port = parsedPort;
    }
    const settings = new AppSettings();
    settings.port = this.port;
    settings.webUrl = this.webUrlInput;
    settings.autoListen = true;
    settings.webMode = this.webMode;
    settings.displayMode = this.displayMode;
    settings.displayModeUserSet = this.displayModeUserSet;
    settings.touchEnabled = this.touchEnabled;
    SettingsStore.save(this.context, settings);
  }

  private async startServer(): Promise<void> {
    if (this.server === null || this.webMode) {
      return;
    }
    const error = await this.server.start(this.port);
    if (error === null) {
      this.serverRunning = true;
      this.hintText = '';
      this.refreshLocalIp();
    } else {
      this.serverRunning = false;
      this.linkState = LinkState.ERROR;
      this.stateDetail = error;
      this.hintText = error;
      this.showToast(error);
    }
  }

  private async stopServer(): Promise<void> {
    if (this.server !== null) {
      await this.server.stop();
    }
    this.serverRunning = false;
    this.linkState = LinkState.IDLE;
    this.stateDetail = '未监听';
  }

  private refreshLocalIp(): void {
    if (this.server === null) {
      return;
    }
    const ip = this.server.localIp();
    if (ip.length > 0 && ip !== this.localIp) {
      this.localIp = ip;
    }
    const remote = this.server.clientRemote();
    if (remote.length > 0) {
      this.clientAddr = remote;
    }
  }

  private keepScreenOn(enabled: boolean): void {
    window.getLastWindow(this.context).then((win: window.Window) => {
      win.setWindowKeepScreenOn(enabled).catch((err: BusinessError) => {
        Log.w(`setWindowKeepScreenOn failed: ${err.message}`);
      });
    }).catch((err: BusinessError) => {
      Log.w(`getLastWindow failed: ${err.message}`);
    });
  }

  private showToast(message: string): void {
    const now = Date.now();
    if (now - this.lastToastTime < 800) {
      return;
    }
    this.lastToastTime = now;
    try {
      const options: promptAction.ShowToastOptions = { message: message, duration: 2000 };
      this.getUIContext().getPromptAction().showToast(options);
    } catch (err) {
      Log.w(`toast failed: ${JSON.stringify(err)}`);
    }
  }

  // ================================================================ server events

  private handleStateChange(state: LinkState, detail: string): void {
    this.linkState = state;
    this.stateDetail = detail;
    if (state === LinkState.STREAMING) {
      this.decoderError = '';
      this.refreshLocalIp();
      this.clientAddr = this.server !== null ? this.server.clientRemote() : '';
      this.applyFrameRateRange();
      this.showHudTemporarily();
    }
    if (state === LinkState.IDLE) {
      this.rxFps = 0;
      this.decodedFps = 0;
      this.decodeMs = 0;
      this.bitrateMbps = 0;
      this.stalled = false;
      this.clientAddr = '';
      this.streamFps = 0;
      this.applyFrameRateRange();
    }
  }

  private handleConfig(config: CodecConfig): void {
    this.videoW = config.width;
    this.videoH = config.height;
    this.streamFps = config.fps;
    this.expectingRemoteConfig = false;
    if (this.configWaitTimer >= 0) {
      clearTimeout(this.configWaitTimer);
      this.configWaitTimer = -1;
    }
    // ---- v1.2 render mode: pixel1to1 (native 1:1) | scale (HiDPI 2x + fit/fill)
    const hostMode = (config.renderMode === 'pixel1to1') ? 'pixel1to1' : 'scale';
    this.renderMode = hostMode;
    this.virtualPxW = config.width;
    this.virtualPxH = config.height;
    this.virtualRetina = (hostMode === 'scale') && (config.retina !== false);
    const virtualScale = (hostMode === 'pixel1to1' || !this.virtualRetina) ? 1 : 2;
    this.virtualPtW = (config.logicalWidth !== undefined && config.logicalWidth > 0)
      ? config.logicalWidth : Math.round(config.width / virtualScale);
    this.virtualPtH = (config.logicalHeight !== undefined && config.logicalHeight > 0)
      ? config.logicalHeight : Math.round(config.height / virtualScale);
    Log.i(`render: ${hostMode} virtual=${this.virtualPxW}x${this.virtualPxH}px ` +
      `${this.virtualPtW}x${this.virtualPtH}pt retina=${this.virtualRetina}`);

    // scaleMode only applies to renderMode=scale. For scale, the HiDPI mode
    // defaults to fill (maximum clarity) unless the user/host says otherwise;
    // pixel1to1 ignores fit/fill entirely.
    if (hostMode === 'scale') {
      const hostScaleMode = (config.scaleMode === 'fill') ? 'fill' : 'fit';
      if (!this.displayModeUserSet && this.displayMode !== 'fill') {
        this.displayMode = 'fill';  // HiDPI maximum clarity default
        Log.i(`HiDPI mode defaults displayMode=fill (user not set; host=${hostScaleMode})`);
      }
    }
    Log.i(`config: scaleMode=${config.scaleMode} retina=${config.retina} ` +
      `logical=${config.logicalWidth}x${config.logicalHeight} renderMode=${config.renderMode} ` +
      `hostInput=${config.inputEnabled} touchLocal=${this.touchEnabled}`);
    this.configText = `${config.codec} ${config.width}×${config.height} @${config.fps}fps ` +
      `${Math.round(config.bitrate / 100000) / 10}Mbps`;
    this.updateVideoBox();
    this.applyFrameRateRange();
    Log.i(`adopted stream config: ${config.width}x${config.height}@${config.fps}fps ` +
      `profile=${config.profile}; box=${Math.round(this.boxW)}x${Math.round(this.boxH)}vp; ` +
      `panel=${this.screenPxW}x${this.screenPxH}@${this.refreshRate}Hz`);
  }

  private handleStats(stats: StreamStats): void {
    this.rxFps = stats.rxFps;
    this.decodedFps = stats.decodedFps;
    this.decodeMs = stats.decodeMs;
    this.recvMs = stats.recvMs;
    this.renderMs = stats.renderMs;
    this.e2eMs = stats.e2eMs;
    if (stats.presentHz > 0) {
      this.presentHz = stats.presentHz;
    }
    this.bitrateMbps = (stats.bytesPerSec * 8) / 1000000;
    this.decodedFrames = stats.decodedFrames;
    this.droppedFrames = stats.droppedFrames;
    this.droppedNoKeyframe = stats.droppedNoKeyframe;
    this.queueFrames = stats.queueFrames;
    this.stalled = stats.stalled;
  }

  private handleNativeDecoderError(code: number, message: string): void {
    this.decoderError = `解码器错误 ${code}: ${message}`;
    this.showToast(this.decoderError);
    const now = Date.now();
    if (now - this.lastDecoderRecovery > 3000) {
      this.lastDecoderRecovery = now;
      if (this.server !== null && this.linkState === LinkState.STREAMING) {
        this.server.recoverDecoder();
        return;
      }
    }
    if (this.server !== null) {
      this.server.requestKeyframe(true);
    }
  }

  // ================================================================ video surface

  private updateVideoBox(): void {
    if (this.screenW <= 0 || this.screenH <= 0 || this.videoW <= 0 || this.videoH <= 0) {
      return;
    }
    const density = this.density > 0 ? this.density : 2.5;
    if (this.renderMode === 'pixel1to1') {
      // v1.2 native 1:1 pixels: the XComponent occupies exactly videoPx/density
      // vp, i.e. one surface pixel maps to one physical pixel. No scaling at all:
      // centred, overflow clipped, letterboxed when the virtual screen is smaller.
      this.boxW = this.videoW / density;
      this.boxH = this.videoH / density;
      Log.i(`video box ${this.boxW.toFixed(1)}x${this.boxH.toFixed(1)}vp ` +
        `(renderMode=pixel1to1, video=${this.videoW}x${this.videoH}px, density=${density})`);
      return;
    }
    const screenAspect = this.screenW / this.screenH;
    const videoAspect = this.videoW / this.videoH;
    if (this.displayMode === 'fill') {
      // Cover: scale up until both dimensions are covered, crop the overflow.
      if (videoAspect >= screenAspect) {
        this.boxH = this.screenH;
        this.boxW = this.screenH * videoAspect;
      } else {
        this.boxW = this.screenW;
        this.boxH = this.screenW / videoAspect;
      }
    } else {
      // Fit: complete picture, letterbox/pillarbox with black bars.
      if (videoAspect >= screenAspect) {
        this.boxW = this.screenW;
        this.boxH = this.screenW / videoAspect;
      } else {
        this.boxH = this.screenH;
        this.boxW = this.screenH * videoAspect;
      }
    }
    Log.i(`video box ${Math.round(this.boxW)}x${Math.round(this.boxH)}vp ` +
      `(mode=${this.displayMode}, screen=${Math.round(this.screenW)}x${Math.round(this.screenH)})`);
  }

  private setDisplayMode(mode: string): void {
    if (mode !== 'fit' && mode !== 'fill') {
      return;
    }
    if (this.isPixel1to1()) {
      this.showToast('原生 1:1 像素模式不使用缩放（由 Mac 端虚拟屏分辨率决定）');
      return;
    }
    this.displayMode = mode;
    this.displayModeUserSet = true;
    this.updateVideoBox();
    this.saveSettings();
    Log.i(`display mode -> ${mode}`);
    this.showToast(mode === 'fill' ? '显示模式：裁剪填满（无黑边，可能裁掉边缘）' : '显示模式：完整显示（可能留黑边）');
  }

  private setTouchEnabled(enabled: boolean): void {
    this.touchEnabled = enabled;
    if (this.server !== null) {
      this.server.setInputEnabled(enabled);
    }
    this.saveSettings();
    Log.i(`touch回传 -> ${enabled ? 'ENABLED' : 'DISABLED'}`);
    this.showToast(enabled ? '触摸控制已开启' : '触摸控制已关闭');
  }

  private handleSurfaceLoad(): void {
    const surfaceId = this.xc.getXComponentSurfaceId();
    Log.i(`XComponent surface loaded: ${surfaceId}`);
    this.surfaceReady = surfaceId.length > 0;
    if (this.surfaceReady && this.server !== null) {
      this.server.attachSurface(surfaceId);
    }
  }

  private handleSurfaceDestroy(): void {
    Log.i('XComponent surface destroyed');
    this.surfaceReady = false;
    if (this.server !== null) {
      this.server.detachSurface();
    }
  }

  // ================================================================ input

  private handleTouch(event: TouchEvent): void {
    // A tap anywhere on the video brings the floating controls back.
    if (event.type === TouchType.Down) {
      this.showHudTemporarily();
    }
    if (!this.touchEnabled || this.server === null ||
      this.linkState !== LinkState.STREAMING || this.webMode) {
      return;
    }
    let point: TouchObject | null = null;
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (event.changedTouches.length > 0) {
        point = event.changedTouches[0];
      }
    } else if (event.touches.length > 0) {
      point = event.touches[0];
    }
    if (point === null) {
      return;
    }
    let action = 'move';
    if (event.type === TouchType.Down) {
      action = 'down';
    } else if (event.type === TouchType.Up) {
      action = 'up';
    } else if (event.type === TouchType.Cancel) {
      action = 'cancel';
    }
    const x = clamp01(point.x / this.boxW);
    const y = clamp01(point.y / this.boxH);
    this.server.sendTouch(action, Math.round(x * 10000) / 10000, Math.round(y * 10000) / 10000,
      point.id);
  }

  private modifierNameOf(code: number): string {
    switch (code) {
      case KeyCode.KEYCODE_CTRL_LEFT:
      case KeyCode.KEYCODE_CTRL_RIGHT:
        return 'CTRL';
      case KeyCode.KEYCODE_SHIFT_LEFT:
      case KeyCode.KEYCODE_SHIFT_RIGHT:
        return 'SHIFT';
      case KeyCode.KEYCODE_ALT_LEFT:
      case KeyCode.KEYCODE_ALT_RIGHT:
        return 'ALT';
      case KeyCode.KEYCODE_META_LEFT:
      case KeyCode.KEYCODE_META_RIGHT:
        return 'META';
      default:
        return '';
    }
  }

  private handleKey(event: KeyEvent): void {
    if (!this.touchEnabled || this.server === null ||
      this.linkState !== LinkState.STREAMING || this.webMode) {
      return;
    }
    const isDown = event.type === KeyType.Down;
    const modifier = this.modifierNameOf(event.keyCode);
    if (modifier.length > 0) {
      const index = this.pressedModifiers.indexOf(modifier);
      if (isDown && index < 0) {
        this.pressedModifiers.push(modifier);
      } else if (!isDown && index >= 0) {
        this.pressedModifiers.splice(index, 1);
      }
      return;
    }
    const name = keyNameOf(event.keyCode);
    const chord = this.pressedModifiers.length > 0
      ? `${this.pressedModifiers.join('+')}+${name}`
      : name;
    this.server.sendKey(isDown ? 'down' : 'up', chord);
  }

  private handleAxis(event: AxisEvent): void {
    if (!this.touchEnabled || this.server === null ||
      this.linkState !== LinkState.STREAMING || this.webMode) {
      return;
    }
    const dy = event.getVerticalAxisValue();
    const dx = event.getHorizontalAxisValue();
    if (dx === 0 && dy === 0) {
      return;
    }
    this.server.sendScroll(dx, -dy);
  }

  // ================================================================ actions

  private copyAddress(): void {
    const text = this.localIp.length > 0 ? `${this.localIp}:${this.port}` : `:${this.port}`;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.showToast('地址已复制');
      }).catch((err: BusinessError) => {
        this.showToast(`复制失败: ${err.message}`);
      });
    } catch (err) {
      Log.w(`copy failed: ${JSON.stringify(err)}`);
    }
  }

  private async toggleWebMode(enabled: boolean): Promise<void> {
    if (enabled) {
      let url = this.webUrlInput.trim();
      if (url.length === 0) {
        const macIp = this.server !== null ? this.server.clientRemote() : '';
        if (macIp.length > 0) {
          url = `http://${macIp}:8080/`;
        }
      }
      if (url.length === 0) {
        this.showToast('请先填写 Mac Web 地址: http://<mac-ip>:8080/');
        this.webMode = false;
        return;
      }
      this.webUrlInput = url;
      this.webMode = true;
      this.showSettings = false;
      await this.stopServer();
      this.keepScreenOn(true);
      this.saveSettings();
      Log.i(`web mode enabled: ${url}`);
    } else {
      this.webMode = false;
      await this.startServer();
      this.saveSettings();
      Log.i('web mode disabled, back to native streaming');
    }
  }

  private async applyPortAndRestart(): Promise<void> {
    const parsed = parseInt(this.portInput, 10);
    if (isNaN(parsed) || parsed <= 0 || parsed >= 65536) {
      this.showToast('端口无效 (1-65535)');
      return;
    }
    this.port = parsed;
    this.saveSettings();
    if (this.serverRunning) {
      await this.stopServer();
      await this.startServer();
    } else {
      await this.startServer();
    }
  }

  private refreshLogs(): void {
    this.logLines = Log.recent(60);
  }

  private sendTextNow(): void {
    if (!this.touchEnabled) {
      this.showToast('触摸控制已关闭，文本未发送');
      return;
    }
    if (this.server === null || this.textValue.length === 0) {
      return;
    }
    this.server.sendText(this.textValue);
    Log.i(`-> text (${this.textValue.length} chars)`);
    this.showToast(`已发送 ${this.textValue.length} 个字符`);
    this.textValue = '';
  }

  private requestKeyframe(): void {
    if (this.server !== null) {
      this.server.requestKeyframe(true);
      this.showToast('已请求关键帧');
    }
  }

  private exitApp(): void {
    if (this.context === null) {
      return;
    }
    this.stopServer();
    this.context.terminateSelf().catch((err: BusinessError) => {
      Log.w(`terminateSelf failed: ${err.message}`);
    });
  }

  // ================================================================ UI helpers

  private stateColor(): string {
    if (this.linkState === LinkState.STREAMING) {
      return this.stalled ? '#FFC940' : '#2ED573';
    }
    if (this.linkState === LinkState.HANDSHAKE) {
      return '#4EA1FF';
    }
    if (this.linkState === LinkState.ERROR) {
      return '#FF5C5C';
    }
    return this.serverRunning ? '#FFC940' : '#7A8794';
  }

  private stateLabel(): string {
    if (this.linkState === LinkState.STREAMING) {
      return this.stalled ? '画面停滞' : '正在投影';
    }
    if (this.linkState === LinkState.HANDSHAKE) {
      return '正在握手';
    }
    if (this.linkState === LinkState.ERROR) {
      return '错误';
    }
    return this.serverRunning ? '等待 Mac 连接' : '未监听';
  }

  private statsText(): string {
    if (this.linkState !== LinkState.STREAMING) {
      return '';
    }
    let text = `${this.rxFps}→${this.decodedFps}fps · ${this.decodeMs.toFixed(1)}ms · ` +
      `${this.bitrateMbps.toFixed(1)}Mbps`;
    // v1.3: show end-to-end latency when the host sends frame timestamps.
    if (this.e2eMs > 0) {
      text += ` · e2e ${this.e2eMs.toFixed(1)}ms`;
    }
    return text;
  }

  /** Floating HUD auto-hide: show now, hide after 3s of no interaction. */
  private showHudTemporarily(): void {
    this.hudVisible = true;
    if (this.hudTimer >= 0) {
      clearTimeout(this.hudTimer);
    }
    this.hudTimer = setTimeout(() => {
      this.hudTimer = -1;
      if (this.linkState === LinkState.STREAMING && !this.showSettings) {
        this.hudVisible = false;
      }
    }, 3000);
  }

  private hideHudNow(): void {
    if (this.hudTimer >= 0) {
      clearTimeout(this.hudTimer);
      this.hudTimer = -1;
    }
    if (this.vsyncTimer >= 0) {
      clearInterval(this.vsyncTimer);
      this.vsyncTimer = -1;
    }
    this.hudVisible = false;
  }

  /** Pixel size actually used by the video and how much is cropped/letterboxed. */
  private effectiveAreaText(): string {
    if (this.videoW <= 0 || this.videoH <= 0 || this.screenPxW <= 0) {
      return '-';
    }
    const d = this.density > 0 ? this.density : 2.5;
    if (this.isPixel1to1()) {
      const padX = Math.max(0, this.screenPxW - this.videoW);
      const padY = Math.max(0, this.screenPxH - this.videoH);
      const cropX = Math.max(0, this.videoW - this.screenPxW);
      const cropY = Math.max(0, this.videoH - this.screenPxH);
      if (padX === 0 && padY === 0 && cropX === 0 && cropY === 0) {
        return `1:1 像素 ${this.videoW}×${this.videoH}px，正好铺满`;
      }
      if (cropX > 0 || cropY > 0) {
        return `1:1 像素居中，裁切 ${cropX}×${cropY}px（可见 ` +
          `${Math.min(this.videoW, this.screenPxW)}×${Math.min(this.videoH, this.screenPxH)}px）`;
      }
      return `1:1 像素 ${this.videoW}×${this.videoH}px 居中，补黑边 ${padX}×${padY}px`;
    }
    const dispW = Math.round(this.boxW * d);
    const dispH = Math.round(this.boxH * d);
    if (this.displayMode === 'fill') {
      const cropX = Math.max(0, Math.round(Math.abs(this.boxW - this.screenW) * d));
      const cropY = Math.max(0, Math.round(Math.abs(this.boxH - this.screenH) * d));
      return `全屏 ${this.screenPxW}×${this.screenPxH}，裁掉 ${cropX}×${cropY}px`;
    }
    const barX = Math.max(0, Math.round((this.screenW - this.boxW) * d));
    const barY = Math.max(0, Math.round((this.screenH - this.boxH) * d));
    return `${dispW}×${dispH}，黑边 ${barX}×${barY}px`;
  }

  private orientationLabel(): string {
    return this.orientation === 'portrait' ? '竖屏' : '横屏';
  }

  private displayModeLabel(): string {
    return this.displayMode === 'fill' ? '裁剪填满' : '完整显示';
  }

  private displayModeFullLabel(): string {
    return this.displayMode === 'fill'
      ? '裁剪填满（无黑边，可能裁掉边缘）'
      : '完整显示（可能留黑边）';
  }

  private renderModeLabel(): string {
    return this.renderMode === 'pixel1to1' ? '原生 1:1' : 'HiDPI 最大化';
  }

  private isPixel1to1(): boolean {
    return this.renderMode === 'pixel1to1';
  }

  /** "虚拟屏 2800×1848 px = 1400×924 pt (2x) · 模式 HiDPI 最大化" */
  private virtualDisplayText(): string {
    if (this.virtualPxW <= 0) {
      return '-';
    }
    if (this.isPixel1to1()) {
      return `虚拟屏 ${this.virtualPxW}×${this.virtualPxH} px (1x) · 模式 原生 1:1`;
    }
    const scale = this.virtualRetina ? 2 : 1;
    return `虚拟屏 ${this.virtualPxW}×${this.virtualPxH} px = ` +
      `${this.virtualPtW}×${this.virtualPtH} pt (${scale}x) · 模式 HiDPI 最大化`;
  }

  /** Compact spec used in the HUD/title: e.g. "2800×1840 · 横屏 · 1:1像素" */
  private streamSpecText(): string {
    const base = `${this.videoW}×${this.videoH} · ${this.orientationLabel()}`;
    if (this.isPixel1to1()) {
      return `${base} · 1:1像素`;
    }
    return `${base} · ${this.displayModeLabel()}`;
  }

  private touchLabel(): string {
    return this.touchEnabled ? '触摸已开启' : '触摸已关闭';
  }

  private ipText(): string {
    return this.localIp.length > 0 ? `${this.localIp}:${this.port}` : `无法获取 IP · 端口 ${this.port}`;
  }

  // ================================================================ builders

  build() {
    Navigation() {
      Stack({ alignContent: Alignment.Center }) {
        if (this.webMode) {
          this.webLayer()
        } else if (this.linkState === LinkState.HANDSHAKE ||
          this.linkState === LinkState.STREAMING) {
          // Mount the SURFACE as soon as a Mac connects (the decoder needs the
          // surfaceId before it can send "ready"), and unmount it when idle: an
          // idle SURFACE otherwise keeps its last decoded frame (frozen desktop).
          this.videoLayer()
        }
        if (!this.webMode && this.linkState !== LinkState.STREAMING) {
          this.waitingContent()
        }
        if (!this.webMode && this.linkState === LinkState.STREAMING) {
          this.streamingHud()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .onAxisEvent((event: AxisEvent) => {
        this.handleAxis(event);
      })
    }
    .title(this.navTitle())
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(true)
    .hideTitleBar(this.linkState === LinkState.STREAMING || this.webMode)
    .mode(NavigationMode.Stack)
    .menus(this.navMenusBuilder())
    .bindSheet($$this.showSettings, this.settingsSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      title: { title: '设置' }
    })
  }

  @Builder
  videoLayer() {
    Stack() {
      XComponent({
        id: 'halolink_video',
        type: XComponentType.SURFACE,
        controller: this.xc
      })
        .width(this.boxW)
        .height(this.boxH)
        .backgroundColor('#000000')
        .onLoad(() => {
          this.handleSurfaceLoad();
        })
        .onDestroy(() => {
          this.handleSurfaceDestroy();
        })
        .onTouch((event: TouchEvent) => {
          this.handleTouch(event);
        })
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      this.handleKey(event);
    })
  }

  /**
   * Immersive floating HUD for streaming: the video is full-screen and this layer
   * is purely an overlay (transparent middle, so touches reach the XComponent).
   * It auto-hides after 3s; a tap anywhere on the video brings it back.
   */
  @Builder
  streamingHud() {
    if (this.hudVisible) {
      Column() {
        // top gradient bar: live status + keyframe/exit
        Row() {
          Row() {
            Circle({ width: 8, height: 8 }).fill(this.stateColor())
            Text(this.stateLabel())
              .fontSize(15)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
              .margin({ left: 8, right: 12 })
            Text(this.statsText())
              .fontSize(13)
              .fontColor('#C9E9D6')
            Text(`· ${this.streamSpecText()} · ${this.touchLabel()}`)
              .fontSize(13)
              .fontColor('#9AA7B4')
              .margin({ left: 10 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .layoutWeight(1)

          Button('关键帧')
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontColor('#E6FFFFFF')
            .onClick(() => {
              this.requestKeyframe();
              this.showHudTemporarily();
            })
          Button('退出')
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontColor('#E6FFFFFF')
            .onClick(() => {
              this.exitApp();
            })
        }
        .width('100%')
        .padding({ left: 24, right: 16, top: 12, bottom: 22 })
        .linearGradient({
          angle: 180,
          colors: [['#CC000000', 0.0], ['#80000000', 0.55], ['#00000000', 1.0]]
        })

        Blank()

        // single round floating button, fully inside the safe area
        Row() {
          Blank()
          Button('设置')
            .buttonStyle(ButtonStyleMode.NORMAL)
            .height(52)
            .fontSize(15)
            .padding({ left: 20, right: 20 })
            .borderRadius(26)
            .systemMaterial(this.immersiveMaterial)
            .onClick(() => {
              this.showSettings = true;
              this.refreshLogs();
              this.hideHudNow();
            })
        }
        .width('100%')
        .padding({ right: 28, bottom: 36 })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
    }
  }

  @Builder
  webLayer() {
    Stack() {
      if (this.webUrlInput.length > 0) {
        Web({ src: this.webUrlInput, controller: this.webController })
          .width('100%')
          .height('100%')
          .backgroundColor('#000000')
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(false)
          .onPageEnd(() => {
            Log.i(`web page loaded: ${this.webUrlInput}`);
          })
      } else {
        Text('未配置 Web 地址')
          .fontSize(20)
          .fontColor('#FFFFFF')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** Waiting / idle page: plain text on black, standard buttons, no custom cards. */
  @Builder
  waitingContent() {
    Column() {
      Circle({ width: 12, height: 12 }).fill(this.stateColor())
        .margin({ bottom: 18 })
      Text(this.serverRunning ? '等待 Mac 连接' : '监听未启动')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
      Text(this.stateDetail.length > 0 ? this.stateDetail : ' ')
        .fontSize(15)
        .fontColor('#9AA7B4')
        .margin({ top: 10 })
      Text(`平板物理屏 ${this.screenPxW}×${this.screenPxH} (${this.orientationLabel()}) · ` +
        `${this.density.toFixed(2)}x · ${this.refreshRate}Hz` +
        (this.streamFps > 0 ? ` · 流 ${this.streamFps}fps` : ''))
        .fontSize(13)
        .fontColor('#7DD3A0')
        .margin({ top: 8 })
      Text(this.configText !== '未连接' ? this.virtualDisplayText() : '等待 Mac 连接后显示虚拟屏信息')
        .fontSize(12)
        .fontColor('#8A97A3')
        .margin({ top: 4 })
      Text(this.isPixel1to1()
        ? '原生 1:1 像素：逐像素显示，不缩放（超出裁切 / 不足补黑边）'
        : `画面缩放：${this.displayModeFullLabel()}（只影响显示；虚拟屏分辨率由 Mac 端选择）`)
        .fontSize(12)
        .fontColor('#8A97A3')
        .margin({ top: 4 })
      Text(this.touchLabel())
        .fontSize(12)
        .fontColor(this.touchEnabled ? '#7DD3A0' : '#FFC940')
        .margin({ top: 4 })

      Column() {
        Text('在 Mac 上连接本机地址')
          .fontSize(14)
          .fontColor('#8A97A3')
        Text(this.ipText())
          .fontSize(38)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .margin({ top: 8 })
        Row() {
          Button('复制地址')
            .buttonStyle(ButtonStyleMode.NORMAL)
            .height(42)
            .fontSize(15)
            .onClick(() => {
              this.copyAddress();
            })
          Button('Web 模式')
            .buttonStyle(ButtonStyleMode.NORMAL)
            .height(42)
            .fontSize(15)
            .margin({ left: 14 })
            .onClick(() => {
              this.toggleWebMode(true);
            })
          Button(this.serverRunning ? '重新监听' : '开始监听')
            .buttonStyle(ButtonStyleMode.EMPHASIZED)
            .height(42)
            .fontSize(15)
            .margin({ left: 14 })
            .onClick(() => {
              this.applyPortAndRestart();
            })
          Button('设置')
            .buttonStyle(ButtonStyleMode.NORMAL)
            .height(42)
            .fontSize(15)
            .margin({ left: 14 })
            .onClick(() => {
              this.showSettings = true;
              this.refreshLogs();
            })
        }
        .margin({ top: 24 })
      }
      .margin({ top: 40 })

      Text('halolink-host --connect ' + this.ipText())
        .fontSize(13)
        .fontColor('#66737F')
        .margin({ top: 36 })
      Text('USB / 无线调试: hdc fport tcp:9528 tcp:9528 后连接 127.0.0.1:9528')
        .fontSize(12)
        .fontColor('#55616D')
        .margin({ top: 6 })
      if (this.decoderError.length > 0) {
        Text(this.decoderError)
          .fontSize(13)
          .fontColor('#FF8A8A')
          .margin({ top: 18 })
      }
      if (this.hintText.length > 0) {
        Text(this.hintText)
          .fontSize(13)
          .fontColor('#FFC940')
          .margin({ top: 10 })
      }
    }
    .width('100%')
    .padding({ left: 40, right: 40 })
    .alignItems(HorizontalAlign.Center)
  }

  /** Official Navigation title area: app name when idle, live stats when streaming. */
  private navTitle(): NavigationCommonTitle {
    const title: NavigationCommonTitle = {
      main: this.linkState === LinkState.STREAMING ? '正在投影' : 'HaloLink 扩展屏',
      sub: this.linkState === LinkState.STREAMING
        ? `${this.statsText()} · ${this.streamSpecText()} · ${this.touchLabel()}`
        : `${this.stateLabel()} · ${this.orientationLabel()} · ${this.touchLabel()}`
    };
    return title;
  }

  /** Navigation menus: plain text actions in the official title bar area. */
  @Builder
  navMenusBuilder() {
    Row() {
      if (this.webMode) {
        Button('返回原生')
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontColor('#E6FFFFFF')
          .onClick(() => {
            this.toggleWebMode(false);
          })
      } else if (this.linkState === LinkState.STREAMING) {
        Button('关键帧')
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontColor('#E6FFFFFF')
          .onClick(() => {
            this.requestKeyframe();
          })
      }
      Button('设置')
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontColor('#E6FFFFFF')
        .onClick(() => {
          this.showSettings = true;
          this.refreshLogs();
        })
      Button('退出')
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontColor('#E6FFFFFF')
        .onClick(() => {
          this.exitApp();
        })
    }
    .padding({ right: 16 })
  }

  @Builder
  settingsSectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor('#7A8794')
      .width('100%')
      .margin({ top: 18, bottom: 6 })
  }

  @Builder
  settingsInfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#7A8794')
        .width(92)
      Text(value.length > 0 ? value : '-')
        .fontSize(13)
        .fontColor('#C6D2DE')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ top: 4 })
  }

  @Builder
  settingsSheet() {
    Column() {
      Scroll() {
        Column() {
          this.settingsSectionTitle('触摸控制（默认关闭）')
          Row() {
            Column() {
              Text('回传触摸 / 键盘 / 滚轮 / 文本')
                .fontSize(14)
                .fontColor('#C6D2DE')
              Text(this.touchEnabled ? '已开启：平板操作会发送到 Mac' : '已关闭：仅作为扩展显示屏')
                .fontSize(11)
                .fontColor('#7A8794')
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.touchEnabled })
              .systemMaterial(this.immersiveMaterial)
              .onChange((isOn: boolean) => {
                this.setTouchEnabled(isOn);
              })
          }
          .width('100%')
          .margin({ top: 6 })

          Row() {
            Text('文本注入')
              .fontSize(14)
              .fontColor('#C6D2DE')
              .width(72)
            TextInput({ text: this.textValue, placeholder: '要发送到 Mac 的文本' })
              .height(44)
              .layoutWeight(1)
              .enabled(this.touchEnabled)
              .onChange((value: string) => {
                this.textValue = value;
              })
            Button('发送')
              .buttonStyle(ButtonStyleMode.NORMAL)
              .height(44)
              .margin({ left: 10 })
              .enabled(this.touchEnabled)
              .onClick(() => {
                this.sendTextNow();
              })
          }
          .width('100%')
          .margin({ top: 8 })

          this.settingsSectionTitle('画面显示方式（仅 HiDPI 最大化模式）')
          Text(this.isPixel1to1()
            ? '原生 1:1 像素模式不使用缩放：由 Mac 端虚拟屏分辨率决定，逐像素显示（超出裁切 / 不足补黑边）'
            : '只影响画面缩放方式；虚拟屏分辨率由 Mac 端选择（原生 1:1 或 HiDPI 最大化）')
            .fontSize(12)
            .fontColor(this.isPixel1to1() ? '#FFC940' : '#7A8794')
            .width('100%')
          Row() {
            Button('完整显示（可能留黑边）')
              .buttonStyle(this.displayMode === 'fit' && !this.isPixel1to1()
                ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
              .height(44)
              .layoutWeight(1)
              .enabled(!this.isPixel1to1())
              .onClick(() => {
                this.setDisplayMode('fit');
              })
            Button('裁剪填满（可能裁掉边缘）')
              .buttonStyle(this.displayMode === 'fill' && !this.isPixel1to1()
                ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
              .height(44)
              .layoutWeight(1)
              .margin({ left: 12 })
              .enabled(!this.isPixel1to1())
              .onClick(() => {
                this.setDisplayMode('fill');
              })
          }
          .width('100%')
          .margin({ top: 8 })

          this.settingsSectionTitle('旋转测试（联调用）')
          Row() {
            Button('自动旋转')
              .buttonStyle(ButtonStyleMode.NORMAL)
              .height(40)
              .onClick(() => {
                this.forceOrientation('auto');
              })
            Button('强制横屏')
              .buttonStyle(ButtonStyleMode.NORMAL)
              .height(40)
              .margin({ left: 10 })
              .onClick(() => {
                this.forceOrientation('landscape');
              })
            Button('强制竖屏')
              .buttonStyle(ButtonStyleMode.NORMAL)
              .height(40)
              .margin({ left: 10 })
              .onClick(() => {
                this.forceOrientation('portrait');
              })
          }
          .width('100%')
          .margin({ top: 6 })

          this.settingsSectionTitle('状态')
          this.settingsInfoRow('连接', `${this.stateLabel()} (${this.linkState})`)
          this.settingsInfoRow('本机地址', this.ipText())
          this.settingsInfoRow('Mac 客户端', this.clientAddr.length > 0 ? this.clientAddr : '-')
          // ---- v1.2: virtual display / render mode info first (most important)
          this.settingsInfoRow('虚拟屏', this.virtualDisplayText())
          this.settingsInfoRow('渲染模式', `${this.renderModeLabel()} (host config)` +
            (this.isPixel1to1() ? ' · 逐像素不缩放' : ''))
          this.settingsInfoRow('画面显示方式', this.isPixel1to1()
            ? '1:1 像素（不使用缩放）'
            : `${this.displayModeFullLabel()} (来源: ` +
              `${this.displayModeUserSet ? '用户设置' : 'host config'})`)
          this.settingsInfoRow('有效显示区', this.effectiveAreaText())
          this.settingsInfoRow('平板物理屏',
            `${this.screenPxW}×${this.screenPxH} · ${this.orientationLabel()} · ` +
            `${this.density.toFixed(2)}x · ${this.refreshRate}Hz`)
          this.settingsInfoRow('视频流', this.configText)
          this.settingsInfoRow('触摸控制', this.touchLabel())
          this.settingsInfoRow('帧率同步', `expected ${this.syncExpected}fps · 流 ${this.streamFps}fps`)
          this.settingsInfoRow('统计',
            `${this.rxFps}→${this.decodedFps}fps · ${this.decodeMs.toFixed(1)}ms · ${this.bitrateMbps.toFixed(1)}Mbps`)
          this.settingsInfoRow('解码帧/队列', `${this.decodedFrames} · q=${this.queueFrames}`)
          this.settingsInfoRow('丢帧', `${this.droppedFrames} · 等关键帧 ${this.droppedNoKeyframe}`)
          this.settingsInfoRow('沉浸材质',
            this.materialSupported ? `支持 (state=${this.materialAppState})` : '不支持/未启用')
          this.settingsInfoRow('上次 display 上报', this.lastDisplayNotify +
            (this.expectingRemoteConfig ? ' · 等待新 config' : ''))
          if (this.decoderError.length > 0) {
            this.settingsInfoRow('解码器', this.decoderError)
          }

          this.settingsSectionTitle('监听端口')
          Row() {
            TextInput({ text: this.portInput, placeholder: '9528' })
              .type(InputType.Number)
              .height(44)
              .layoutWeight(1)
              .onChange((value: string) => {
                this.portInput = value;
              })
            Button(this.serverRunning ? '应用并重启' : '开始监听')
              .buttonStyle(ButtonStyleMode.EMPHASIZED)
              .height(44)
              .margin({ left: 10 })
              .onClick(() => {
                this.applyPortAndRestart();
              })
            if (this.serverRunning) {
              Button('停止')
                .buttonStyle(ButtonStyleMode.NORMAL)
                .height(44)
                .margin({ left: 8 })
                .onClick(() => {
                  this.stopServer();
                })
            }
          }
          .width('100%')

          this.settingsSectionTitle('Web 兜底 (ArkWeb)')
          Row() {
            TextInput({ text: this.webUrlInput, placeholder: 'http://<mac-ip>:8080/' })
              .height(44)
              .layoutWeight(1)
              .onChange((value: string) => {
                this.webUrlInput = value;
              })
            Button(this.webMode ? '退出 Web' : '进入 Web')
              .buttonStyle(this.webMode ? ButtonStyleMode.NORMAL : ButtonStyleMode.EMPHASIZED)
              .height(44)
              .margin({ left: 10 })
              .onClick(() => {
                this.toggleWebMode(!this.webMode);
              })
          }
          .width('100%')

          this.settingsSectionTitle('操作')
          Row() {
            Button('请求关键帧')
              .buttonStyle(ButtonStyleMode.NORMAL)
              .height(40)
              .onClick(() => {
                this.requestKeyframe();
              })
            Button('清空日志')
              .buttonStyle(ButtonStyleMode.NORMAL)
              .height(40)
              .margin({ left: 10 })
              .onClick(() => {
                Log.clear();
                this.refreshLogs();
              })
            Button('退出 App')
              .buttonStyle(ButtonStyleMode.NORMAL)
              .height(40)
              .margin({ left: 10 })
              .onClick(() => {
                this.exitApp();
              })
          }
          .width('100%')
          .margin({ top: 10 })

          Row() {
            Text('显示运行日志')
              .fontSize(14)
              .fontColor('#C6D2DE')
            Blank()
            // Toggle is one of the officially supported immersive-material
            // components, so it consumes the app-level material (lightEffect
            // gives the press feedback).
            Toggle({ type: ToggleType.Switch, isOn: this.showLogs })
              .systemMaterial(this.immersiveMaterial)
              .onChange((isOn: boolean) => {
                this.showLogs = isOn;
                this.refreshLogs();
              })
          }
          .width('100%')
          .margin({ top: 10 })

          if (this.showLogs) {
            Column() {
              ForEach(this.logLines, (line: LogLine, index: number) => {
                Text(`${line.time} ${line.text}`)
                  .fontSize(11)
                  .fontColor('#A8B6C4')
                  .width('100%')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }, (line: LogLine, index: number) => `${index}_${line.time}_${line.text}`)
            }
            .width('100%')
            .padding(10)
            .margin({ top: 8 })
            .borderRadius(10)
            .backgroundColor('#121820')
            .alignItems(HorizontalAlign.Start)
          }

          Text('权限: 仅需 INTERNET / GET_NETWORK_INFO；完全离线运行，无遥测。')
            .fontSize(11)
            .fontColor('#66737F')
            .width('100%')
            .margin({ top: 20, bottom: 12 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 4 })
  }
}
