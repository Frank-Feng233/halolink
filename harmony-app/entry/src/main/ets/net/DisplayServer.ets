import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Log } from '../common/Logger';
import { NetUtil } from '../common/NetUtil';
import { DecoderBridge, DecoderSnapshot } from '../decoder/DecoderBridge';
import {
  CodecConfig, DisplayControl, FRAME_CONTROL, FRAME_PING, FRAME_PONG, FRAME_VIDEO, FrameParser,
  FrameSlice, HANDSHAKE_TIMEOUT_MS, HelloMessage, LinkState, MAX_FRAME_BYTES, PROTOCOL_NAME,
  APP_VERSION, ReadyMessage, StatsControl, TouchControl, ScrollControl, KeyControl, TextControl,
  SimpleControl, ScreenInfo, encodeFrame
} from './Protocol';

/** Live transport/decoder statistics surfaced to the UI. */
export interface StreamStats {
  rxFps: number;
  decodedFps: number;
  bytesPerSec: number;
  decodedFrames: number;
  droppedFrames: number;
  droppedNoKeyframe: number;
  framesIn: number;
  queueFrames: number;
  decodeMs: number;
  stalled: boolean;
  // v1.3 latency breakdown (ms) + present rate
  recvMs: number;
  decMs: number;
  renderMs: number;
  e2eMs: number;
  presentHz: number;
}

export interface ServerListener {
  onStateChange: (state: LinkState, detail: string) => void;
  onConfig: (config: CodecConfig) => void;
  onStats: (stats: StreamStats) => void;
  onDecoderError: (message: string) => void;
}

/**
 * HLDP v1 TCP server (the tablet is the server, the Mac connects to us).
 *
 * One Mac client at a time. Handshake JSON lines -> binary frame mode.
 * Video frames are forwarded straight into the native H.264 decoder; a simple
 * stats timer reports rxFps/decodeMs back to the Mac and to the UI.
 */
export class DisplayServer {
  private server: socket.TCPSocketServer | null = null;
  private client: socket.TCPSocketConnection | null = null;
  private clientAddress: string = '';
  private parser: FrameParser = new FrameParser();
  private handshakeBytes: number[] = [];
  private config: CodecConfig | null = null;
  private state: LinkState = LinkState.IDLE;
  private running: boolean = false;
  private port: number = 0;
  private listener: ServerListener;
  private decoder: DecoderBridge;
  private surfaceId: string = '';
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoderErrorReported: boolean = false;
  // panel info reported by the UI (max supported refresh rate etc.)
  private panelWidth: number = 0;
  private panelHeight: number = 0;
  private panelDensity: number = 0;
  private panelRefresh: number = 0;
  private panelOrientation: string = 'landscape';
  private inputEnabled: boolean = false;  // v1.1: touch/key/scroll/text回传默认关闭

  private statsTimer: number = -1;
  private handshakeTimer: number = -1;
  private lastRxTime: number = 0;
  private rxFramesInWindow: number = 0;
  private bytesInWindow: number = 0;
  // v1.3 frame timestamp support (host prefixes each VIDEO payload with Unix-us)
  private frameTsEnabled: boolean = false;
  private presentHz: number = 0;
  private frameTsMissingCount: number = 0;
  private frameTsBadClockCount: number = 0;
  private lastDecodedFrames: number = 0;
  private lastDecodedFps: number = 0;
  private statsLogCounter: number = 0;
  private lastKeyframeRequest: number = 0;
  private lastStats: StreamStats = {
    recvMs: 0, decMs: 0, renderMs: 0, e2eMs: 0, presentHz: 0,
    rxFps: 0, decodedFps: 0, bytesPerSec: 0, decodedFrames: 0, droppedFrames: 0,
    droppedNoKeyframe: 0, framesIn: 0, queueFrames: 0, decodeMs: 0, stalled: false
  };

  constructor(decoder: DecoderBridge, listener: ServerListener) {
    this.decoder = decoder;
    this.listener = listener;
  }

  isRunning(): boolean {
    return this.running;
  }

  currentState(): LinkState {
    return this.state;
  }

  currentConfig(): CodecConfig | null {
    return this.config;
  }

  getPort(): number {
    return this.port;
  }

  clientRemote(): string {
    return this.clientAddress;
  }

  getLastStats(): StreamStats {
    return this.lastStats;
  }

  localIp(): string {
    return NetUtil.localIpv4();
  }

  /** Called by the UI once the real panel capabilities / orientation are known. */
  setPanelInfo(width: number, height: number, density: number, refreshRate: number,
    orientation: string): void {
    this.panelWidth = width;
    this.panelHeight = height;
    this.panelDensity = density;
    this.panelRefresh = refreshRate;
    this.panelOrientation = orientation;
    Log.i(`panel info for hello: ${width}x${height} density=${density} ` +
      `maxRefresh=${refreshRate}Hz orientation=${orientation}`);
  }

  /** v1.1: master switch for touch/keyboard/scroll/text回传. */
  /** v1.3: current vsync/present rate measured by the Index page. */
  setPresentHz(hz: number): void {
    this.presentHz = hz > 0 ? hz : 0;
  }

  private round1(value: number): number {
    return Math.round(value * 10) / 10;
  }

  /** Out-of-range latency must never reach the host/UI (e.g. a bogus 575ms). */
  private sanitizeMs(value: number, maxMs: number): number {
    if (!isFinite(value) || value < 0 || value > maxMs) {
      return 0;
    }
    return this.round1(value);
  }

  /**
   * e2e is validated as recv+dec+render and must stay in a sane range; otherwise
   * report 0 so the UI hides it instead of scaring the user.
   */
  private sanitizeLatency(recv: number, dec: number, render: number, e2e: number): number {
    const sum = recv + dec + render;
    if (!isFinite(e2e) || !isFinite(sum) || e2e <= 0 || e2e > 1000 ||
      Math.abs(e2e - sum) > 15) {
      return 0;
    }
    return this.round1(e2e);
  }

  setInputEnabled(enabled: boolean): void {
    if (this.inputEnabled !== enabled) {
      Log.i(`input回传 ${enabled ? 'ENABLED' : 'DISABLED'}`);
    }
    this.inputEnabled = enabled;
  }

  isInputEnabled(): boolean {
    return this.inputEnabled;
  }

  /**
   * v1.1: tell the Mac the display geometry/orientation changed (rotation or
   * window resize). The Mac is expected to answer with a fresh `config`.
   */
  sendDisplayChange(width: number, height: number, orientation: string,
    refreshRate: number): void {
    this.panelWidth = width;
    this.panelHeight = height;
    this.panelOrientation = orientation;
    if (refreshRate > 0) {
      this.panelRefresh = refreshRate;
    }
    const payload: DisplayControl = {
      type: 'display',
      width: width,
      height: height,
      orientation: orientation,
      refreshRate: this.panelRefresh > 0 ? this.panelRefresh : refreshRate
    };
    this.sendControl(payload);
    Log.i(`-> display ${width}x${height} orientation=${orientation} ` +
      `refresh=${payload.refreshRate}Hz`);
  }

  /** Starts listening. Returns null on success, or an error message. */
  async start(port: number): Promise<string | null> {
    if (this.running) {
      await this.stop();
    }
    this.port = port;
    this.parser.reset();
    this.handshakeBytes = [];
    try {
      const server = socket.constructTCPSocketServerInstance();
      server.on('connect', (conn: socket.TCPSocketConnection) => {
        this.handleConnect(conn);
      });
      server.on('error', (err: BusinessError) => {
        Log.e(`tcp server error: ${err.code} ${err.message}`);
        this.running = false;
        this.setState(LinkState.ERROR, `监听失败: ${err.message}`);
      });
      await server.listen({ address: '0.0.0.0', port: port, family: 1 });
      // NOTE: ArkTS TCPSocketConnection does not expose setExtraOptions/TCP_NODELAY,
      // so small control frames may be coalesced by Nagle. See README "known limits".
      server.setExtraOptions({ TCPNoDelay: true, keepAlive: true, socketTimeout: 0 })
        .catch((err: BusinessError) => {
          Log.w(`server setExtraOptions failed: ${err.message}`);
        });
      this.server = server;
      this.running = true;
      this.setState(LinkState.IDLE, 'waiting for Mac');
      Log.i(`tcp server listening on 0.0.0.0:${port}`);
      return null;
    } catch (err) {
      const e = err as BusinessError;
      this.running = false;
      Log.e(`listen failed: ${e.code} ${e.message}`);
      return `监听 ${port} 失败: ${e.message} (code ${e.code})`;
    }
  }

  async stop(): Promise<void> {
    this.clearTimers();
    const conn = this.client;
    this.client = null;
    if (conn !== null) {
      try {
        await conn.close();
      } catch (err) {
        Log.w(`close client failed: ${JSON.stringify(err)}`);
      }
    }
    const srv = this.server;
    this.server = null;
    if (srv !== null) {
      try {
        await srv.close();
      } catch (err) {
        Log.w(`close server failed: ${JSON.stringify(err)}`);
      }
    }
    this.running = false;
    this.parser.reset();
    this.handshakeBytes = [];
    this.state = LinkState.IDLE;
    this.config = null;
    this.decoderErrorReported = false;
    this.decoder.flush();
    Log.i('tcp server stopped');
  }

  /** Called by the UI once the XComponent surface is available. */
  attachSurface(surfaceId: string): void {
    Log.i(`surface attached: ${surfaceId}`);
    const previous = this.surfaceId;
    this.surfaceId = surfaceId;
    const changed = previous.length > 0 && previous !== surfaceId;
    if (changed && this.config !== null && this.state === LinkState.STREAMING) {
      // The window/surface was recreated (e.g. foreground/background or resize):
      // rebind the native window and force a fresh IDR.
      Log.i('surface changed while streaming, rebinding decoder');
      this.decoder.init(surfaceId, this.config.width, this.config.height);
      this.requestKeyframe(true);
      return;
    }
    if (changed && this.decoder.isInited()) {
      this.decoder.release();
    }
    if (this.config !== null && this.state === LinkState.HANDSHAKE) {
      this.startStreaming();
    }
  }

  /**
   * Soft-recovery after a native decoder error: rebuild the decoder on the same
   * surface/size and force a fresh keyframe. Called by the UI (debounced).
   */
  recoverDecoder(): void {
    if (this.config === null || this.surfaceId.length === 0) {
      return;
    }
    Log.i('decoder soft recovery: re-init + request keyframe');
    const ret = this.decoder.init(this.surfaceId, this.config.width, this.config.height);
    if (ret !== 0) {
      Log.e(`decoder recovery failed: ${ret}`);
    }
    this.requestKeyframe(true);
  }

  detachSurface(): void {
    Log.i('surface detached');
    this.decoder.release();
    this.surfaceId = '';
  }

  requestKeyframe(force: boolean = false): void {
    const now = Date.now();
    if (!force && now - this.lastKeyframeRequest < 400) {
      return;
    }
    this.lastKeyframeRequest = now;
    const payload: SimpleControl = { type: 'request_keyframe' };
    this.sendControl(payload);
    Log.i('-> request_keyframe');
  }

  sendTouch(action: string, x: number, y: number, pointerId: number): void {
    if (!this.inputEnabled) {
      return;
    }
    const payload: TouchControl = { type: 'touch', action: action, x: x, y: y, pointerId: pointerId };
    this.sendControl(payload);
  }

  sendScroll(dx: number, dy: number): void {
    if (!this.inputEnabled) {
      return;
    }
    const payload: ScrollControl = { type: 'scroll', dx: dx, dy: dy };
    this.sendControl(payload);
  }

  sendKey(action: string, key: string): void {
    if (!this.inputEnabled) {
      return;
    }
    const payload: KeyControl = { type: 'key', action: action, key: key };
    this.sendControl(payload);
  }

  sendText(text: string): void {
    if (!this.inputEnabled) {
      Log.w('sendText ignored: input回传 is disabled');
      return;
    }
    const payload: TextControl = { type: 'text', text: text };
    this.sendControl(payload);
  }

  // ---------------------------------------------------------------- internals

  private setState(state: LinkState, detail: string): void {
    this.state = state;
    this.listener.onStateChange(state, detail);
  }

  private handleConnect(conn: socket.TCPSocketConnection): void {
    Log.i(`client connected id=${conn.clientId}`);
    if (this.client !== null) {
      Log.w('rejecting second client: one Mac at a time');
      conn.close().catch((err: BusinessError) => {
        Log.w(`close rejected client: ${err.message}`);
      });
      return;
    }
    this.client = conn;
    this.clientAddress = '';
    this.parser.reset();
    this.handshakeBytes = [];
    this.decoderErrorReported = false;
    this.setState(LinkState.HANDSHAKE, 'Mac connected, handshake...');

    conn.on('message', (info: socket.SocketMessageInfo) => {
      this.handleIncoming(info.message);
    });
    conn.on('close', () => {
      Log.i('client connection closed');
      this.handleClientGone(conn, 'Mac disconnected');
    });
    conn.on('error', (err: BusinessError) => {
      Log.w(`client socket error: ${err.code} ${err.message}`);
      this.handleClientGone(conn, `socket error: ${err.message}`);
    });

    conn.getRemoteAddress().then((addr: socket.NetAddress) => {
      this.clientAddress = addr.address;
      Log.i(`client remote address: ${addr.address}`);
    }).catch((err: BusinessError) => {
      Log.w(`getRemoteAddress failed: ${err.message}`);
    });

    this.sendHello();
  }

  private sendHello(): void {
    let width = this.panelWidth > 0 ? this.panelWidth : 2800;
    let height = this.panelHeight > 0 ? this.panelHeight : 1840;
    let density = this.panelDensity > 0 ? this.panelDensity : 2.5;
    let refreshRate = this.panelRefresh > 0 ? this.panelRefresh : 60;
    try {
      const d = display.getDefaultDisplaySync();
      if (this.panelWidth === 0) {
        width = d.width;
        height = d.height;
      }
      if (this.panelDensity === 0) {
        density = d.densityPixels;
      }
      // `refreshRate` is the *current* rate (adaptive panels idle at 60Hz);
      // `supportedRefreshRates` lists the panel capability, so report the max.
      let maxRate = d.refreshRate > 0 ? d.refreshRate : 60;
      if (d.supportedRefreshRates !== undefined && d.supportedRefreshRates.length > 0) {
        maxRate = d.supportedRefreshRates[d.supportedRefreshRates.length - 1];
      }
      if (this.panelRefresh === 0) {
        refreshRate = maxRate;
      }
    } catch (err) {
      Log.w(`display info unavailable: ${JSON.stringify(err)}`);
    }
    Log.i(`hello screen: ${width}x${height} density=${density} refreshRate=${refreshRate}Hz`);
    const screen: ScreenInfo = {
      width: width, height: height, density: density, refreshRate: refreshRate,
      orientation: this.panelOrientation
    };
    let model = 'TGR-W10';
    let device = 'HUAWEI MatePad 11.5"S';
    try {
      model = deviceInfo.productModel.length > 0 ? deviceInfo.productModel : model;
      device = deviceInfo.marketName.length > 0 ? deviceInfo.marketName : device;
    } catch (err) {
      Log.w(`device info unavailable: ${JSON.stringify(err)}`);
    }
    const hello: HelloMessage = {
      type: 'hello',
      protocol: PROTOCOL_NAME,
      device: device,
      model: model,
      screen: screen,
      features: ['touch', 'keyboard', 'h264', 'frameTs'],
      appVersion: APP_VERSION
    };
    this.sendJsonLine(hello);
    this.startHandshakeTimer();
  }

  private startHandshakeTimer(): void {
    if (this.handshakeTimer >= 0) {
      clearTimeout(this.handshakeTimer);
    }
    this.handshakeTimer = setTimeout(() => {
      this.handshakeTimer = -1;
      if (this.state === LinkState.HANDSHAKE) {
        Log.w('handshake timeout (10s)');
        this.setState(LinkState.ERROR, '握手超时：Mac 未发送 config');
        this.closeClient('handshake timeout');
      }
    }, HANDSHAKE_TIMEOUT_MS);
  }

  private handleIncoming(data: ArrayBuffer): void {
    this.lastRxTime = Date.now();
    if (this.state === LinkState.HANDSHAKE) {
      this.consumeHandshake(data);
      return;
    }
    if (this.state !== LinkState.STREAMING) {
      return;
    }
    try {
      this.parser.append(data);
      this.drainFrames();
    } catch (err) {
      const e = err as Error;
      Log.e(`frame parse error: ${e.message}`);
      this.setState(LinkState.ERROR, `协议错误: ${e.message}`);
      this.closeClient('protocol error');
    }
  }

  private consumeHandshake(data: ArrayBuffer): void {
    const bytes = new Uint8Array(data);
    for (let i = 0; i < bytes.length; i++) {
      if (bytes[i] !== 0x0A) {  // accumulate until '\n'
        this.handshakeBytes.push(bytes[i]);
        continue;
      }
      const lineBytes = this.handshakeBytes;
      this.handshakeBytes = [];
      const text = this.asciiToString(lineBytes).trim();
      if (text.length > 0) {
        this.handleHandshakeLine(text);
      }
      if (this.state !== LinkState.HANDSHAKE) {
        // The Mac never pipelines binary data before "ready", but be safe: if
        // this TCP chunk still has bytes after the config newline, they are the
        // start of the binary protocol and must go straight to the frame parser.
        if (i + 1 < bytes.length) {
          const leftover = bytes.slice(i + 1);
          try {
            this.parser.append(leftover.buffer as ArrayBuffer);
            this.drainFrames();
          } catch (err) {
            const e = err as Error;
            Log.e(`early binary data parse error: ${e.message}`);
            this.setState(LinkState.ERROR, `协议错误: ${e.message}`);
            this.closeClient('protocol error');
          }
        }
        return;
      }
    }
  }

  private handleHandshakeLine(text: string): void {
    Log.i(`<- handshake: ${text}`);
    try {
      const parsed = JSON.parse(text) as CodecConfig;
      if (parsed.type === 'config') {
        const config = parsed;
        if (typeof config.width !== 'number' || typeof config.height !== 'number' ||
          !isFinite(config.width) || !isFinite(config.height) ||
          config.width <= 0 || config.height <= 0 ||
          config.width > 8192 || config.height > 8192) {
          throw new Error(`invalid video size ${config.width}x${config.height}`);
        }
        if (typeof config.fps !== 'number' || config.fps <= 0) {
          config.fps = 60;
        }
        if (typeof config.codec !== 'string' || config.codec.length === 0) {
          config.codec = 'h264';
        }
        this.config = config;
        this.frameTsEnabled = config.frameTs === true;
        Log.i(`frame timestamps ${this.frameTsEnabled ? 'enabled' : 'disabled'} (host frameTs=${config.frameTs})`);
        Log.i(`config: ${config.codec} ${config.width}x${config.height}@${config.fps} ` +
          `profile=${config.profile} keyframe=${config.keyframeInterval}s ` +
          `scale=${config.scaleMode} renderMode=${config.renderMode}`);
        this.listener.onConfig(config);
        this.startStreaming();
      } else if (text.indexOf('"type":"ping"') >= 0) {
        // tolerated
      } else {
        Log.w(`unexpected handshake line: ${text}`);
      }
    } catch (err) {
      const e = err as Error;
      Log.e(`bad config: ${e.message}`);
      this.setState(LinkState.ERROR, `config 解析失败: ${e.message}`);
      this.closeClient('bad config');
    }
  }

  private startStreaming(): void {
    if (this.config === null) {
      return;
    }
    if (this.surfaceId.length === 0) {
      Log.i('waiting for XComponent surface before streaming');
      return;
    }
    const config = this.config;
    const ret = this.decoder.init(this.surfaceId, config.width, config.height);
    if (ret !== 0) {
      this.decoderErrorReported = true;
      this.listener.onDecoderError(`解码器初始化失败 (code ${ret})`);
    }
    if (this.handshakeTimer >= 0) {
      clearTimeout(this.handshakeTimer);
      this.handshakeTimer = -1;
    }
    this.sendReady();
    this.setState(LinkState.STREAMING,
      `${config.codec.toUpperCase()} ${config.width}x${config.height} @${config.fps}`);
    this.startStatsTimer();
    // Force a fresh IDR on every (re)connect / decoder re-init.
    this.requestKeyframe(true);
  }

  private sendReady(): void {
    const ready: ReadyMessage = { type: 'ready' };
    this.sendJsonLine(ready);
    if (this.state === LinkState.HANDSHAKE) {
      this.setState(LinkState.STREAMING, 'streaming');
    }
  }

  private drainFrames(): void {
    while (true) {
      const slice = this.parser.next();
      if (slice === null) {
        return;
      }
      this.dispatchFrame(slice);
      this.parser.consume();
    }
  }

  private dispatchFrame(slice: FrameSlice): void {
    if (slice.type === FRAME_VIDEO) {
      this.rxFramesInWindow++;
      this.bytesInWindow += slice.length;
      let offset = slice.offset;
      let length = slice.length;
      let hostTsUs = 0;
      if (this.frameTsEnabled && length > 8) {
        // v1.3: [8B BE Unix-us capture timestamp][Annex-B AU].
        // Robustness: a host may advertise frameTs but still send plain Annex-B
        // (older build). Check the Annex-B start code first: stripping 8 bytes
        // from a plain AU would corrupt every frame.
        const buf = this.parser.buffer();
        const b0 = new Uint8Array(buf, offset, 4);
        const looksAnnexB = b0[0] === 0 && b0[1] === 0 && b0[2] === 0 && b0[3] === 1;
        if (looksAnnexB) {
          this.frameTsMissingCount++;
          if (this.frameTsMissingCount <= 1 || this.frameTsMissingCount % 300 === 0) {
            Log.w(`host advertises frameTs but payload starts with Annex-B start code ` +
              `(missing 8B prefix); latency recv/e2e disabled for this frame ` +
              `(count=${this.frameTsMissingCount})`);
          }
        } else {
          const view = new DataView(buf, offset, 8);
          const ts = view.getUint32(0, false) * 4294967296 + view.getUint32(4, false);
          offset += 8;
          length -= 8;
          const nowUs = Date.now() * 1000;
          const skewUs = Math.abs(nowUs - ts);
          if (ts > 0 && skewUs < 3600 * 1000 * 1000) {
            hostTsUs = ts;
          } else if (this.frameTsBadClockCount <= 1) {
            this.frameTsBadClockCount++;
            Log.w(`host frameTs clock mismatch: ts=${ts} now=${nowUs} ` +
              `skewMs=${Math.round(skewUs / 1000)}; recv/e2e disabled ` +
              `(host must use Unix epoch us)`);
          }
        }
      }
      if (length <= 0) {
        return;
      }
      if (this.decoder.isInited()) {
        const ret = this.decoder.pushFrame(this.parser.buffer(), offset, length, hostTsUs);
        if (ret !== 0) {
          if (!this.decoderErrorReported) {
            this.decoderErrorReported = true;
            Log.e(`decoder pushFrame failed: ${ret}`);
            this.listener.onDecoderError(`视频解码失败 (code ${ret})`);
          }
        }
      } else {
        // Decoder not available: ask the host for a keyframe so we can resync.
        this.requestKeyframe(false);
      }
    } else if (slice.type === FRAME_PING) {
      this.sendFrame(FRAME_PONG, null);
    } else if (slice.type === FRAME_CONTROL) {
      this.handleRemoteControl(this.parser.payloadView());
    } else if (slice.type === FRAME_PONG) {
      // nothing to do (kept for completeness)
    } else {
      throw new Error(`unknown frame type 0x${slice.type.toString(16)}`);
    }
  }

  private handleRemoteControl(payload: Uint8Array): void {
    let text = '';
    try {
      if (payload.length > 0) {
        text = new util.TextDecoder('utf-8').decodeToString(payload).trim();
      }
    } catch (err) {
      Log.w(`bad control payload: ${JSON.stringify(err)}`);
      return;
    }
    if (text.length === 0) {
      return;
    }
    Log.i(`<- control: ${text}`);
    try {
      const parsed = JSON.parse(text) as CodecConfig;
      if (parsed.type === 'config') {
        this.applyRemoteConfig(parsed);
        return;
      }
    } catch (err) {
      Log.w(`control json parse failed: ${JSON.stringify(err)}`);
    }
    if (text.indexOf('"bye"') >= 0) {
      this.closeClient('host said bye');
    }
  }

  /**
   * v1.1: the host can send a fresh `config` at any time (e.g. after our
   * `display` frame). Rebind the decoder to the new video size, then force a
   * keyframe so the first frame after the switch is a clean IDR.
   */
  private applyRemoteConfig(config: CodecConfig): void {
    const old = this.config;
    this.config = config;
    this.frameTsEnabled = config.frameTs === true;
    Log.i(`frame timestamps ${this.frameTsEnabled ? 'enabled' : 'disabled'} (host frameTs=${config.frameTs})`);
    Log.i(`re-config from host: ${config.width}x${config.height}@${config.fps}fps ` +
      `renderMode=${config.renderMode} scaleMode=${config.scaleMode} retina=${config.retina} ` +
      `logical=${config.logicalWidth}x${config.logicalHeight}`);
    this.listener.onConfig(config);
    if (this.surfaceId.length > 0) {
      this.decoder.flush();
      const ret = this.decoder.init(this.surfaceId, config.width, config.height);
      Log.i(`decoder rebind for new config: ${ret === 0 ? 'ok' : 'failed ' + ret} ` +
        `(old ${old !== null ? old.width + 'x' + old.height : '-'})`);
    }
    this.decoderErrorReported = false;
    this.requestKeyframe(true);
  }

  private startStatsTimer(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
    }
    this.lastRxTime = Date.now();
    this.statsTimer = setInterval(() => {
      this.emitStats();
    }, 1000);
  }

  private emitStats(): void {
    const snapshot: DecoderSnapshot = this.decoder.snapshot();
    this.lastDecodedFps = Math.max(0, snapshot.decodedFrames - this.lastDecodedFrames);
    this.lastDecodedFrames = snapshot.decodedFrames;
    const stalled = Date.now() - this.lastRxTime > 5000;
    // ---- v1.3 latency: validate once, use everywhere (UI + stats control).
    const recvMs = this.sanitizeMs(snapshot.recvMs, 1000);
    const decMs = this.sanitizeMs(snapshot.decMs, 500);
    const renderMs = this.sanitizeMs(snapshot.renderMs, 200);
    const e2eMs = this.sanitizeLatency(recvMs, decMs, renderMs, snapshot.e2eMs);
    const stats: StreamStats = {
      rxFps: this.rxFramesInWindow,
      decodedFps: this.lastDecodedFps,
      bytesPerSec: this.bytesInWindow,
      decodedFrames: snapshot.decodedFrames,
      droppedFrames: snapshot.droppedFrames,
      droppedNoKeyframe: snapshot.droppedNoKeyframe,
      framesIn: snapshot.framesIn,
      queueFrames: snapshot.queuedFrames,
      decodeMs: Math.round(snapshot.avgDecodeMs * 10) / 10,
      stalled: stalled,
      recvMs: recvMs,
      decMs: decMs,
      renderMs: renderMs,
      e2eMs: e2eMs,
      presentHz: this.presentHz
    };
    this.lastStats = stats;
    this.listener.onStats(stats);
    this.rxFramesInWindow = 0;
    this.bytesInWindow = 0;

    this.statsLogCounter++;
    if (this.statsLogCounter % 5 === 0) {
      Log.i(`stats: rx=${stats.rxFps}fps dec=${stats.decodedFps}fps ` +
        `mbps=${(stats.bytesPerSec * 8 / 1000000).toFixed(1)} q=${snapshot.queuedFrames} ` +
        `drop=${snapshot.droppedFrames}/${snapshot.droppedNoKeyframe} stalled=${stats.stalled}`);
      Log.i(`latency: recv=${stats.recvMs}(p95 ${this.round1(snapshot.recvP95Ms)}) ` +
        `dec=${stats.decMs}(p95 ${this.round1(snapshot.decP95Ms)}) ` +
        `render=${stats.renderMs}(p95 ${this.round1(snapshot.renderP95Ms)}) ` +
        `e2e=${stats.e2eMs}(p95 ${this.round1(snapshot.e2eP95Ms)}) ` +
        `presentHz=${this.presentHz} renderHz=${this.round1(snapshot.renderHz)} ` +
        `lowLatency=${snapshot.lowLatency} hostTs=${snapshot.hostTs} ` +
        `pairErr=${snapshot.pairErrors} invalid=${snapshot.invalidSamples} ` +
        `valid=${snapshot.validSamples} queueWait=${this.round1(snapshot.queueWaitMs)} ` +
        `bias=${this.round1(snapshot.offsetMs)}`);
    }

    const control: StatsControl = {
      type: 'stats',
      rxFps: stats.rxFps,
      decodeMs: stats.decodeMs,
      rttMs: 0,
      input: this.inputEnabled,
      recvMs: stats.recvMs,
      decMs: stats.decMs,
      renderMs: stats.renderMs,
      e2eMs: stats.e2eMs,
      presentHz: stats.presentHz
    };
    this.sendControl(control);
    if (stalled) {
      Log.w(`no video data for ${Date.now() - this.lastRxTime}ms (stalled)`);
    }
  }

  private sendJsonLine(obj: Object): void {
    const json = JSON.stringify(obj) + '\n';
    const bytes = this.encoder.encodeInto(json);
    const out = new Uint8Array(bytes.length);
    out.set(bytes);
    this.sendRaw(out.buffer as ArrayBuffer);
  }

  private sendControl(obj: Object): void {
    const json = JSON.stringify(obj);
    const bytes = this.encoder.encodeInto(json);
    this.sendFrame(FRAME_CONTROL, bytes);
  }

  private sendFrame(type: number, payload: Uint8Array | null): void {
    const frame = encodeFrame(type, payload);
    this.sendRaw(frame);
  }

  private sendRaw(frame: ArrayBuffer): void {
    const conn = this.client;
    if (conn === null) {
      return;
    }
    conn.send({ data: frame }).catch((err: BusinessError) => {
      Log.w(`send failed: ${err.code} ${err.message}`);
    });
  }

  private closeClient(reason: string): void {
    const conn = this.client;
    this.client = null;
    if (conn !== null) {
      conn.close().catch((err: BusinessError) => {
        Log.w(`close client: ${err.message}`);
      });
    }
    this.cleanupSession(reason);
  }

  /** Late socket events from a previous (already replaced) connection are ignored. */
  private handleClientGone(conn: socket.TCPSocketConnection, reason: string): void {
    if (this.client !== conn) {
      Log.i('ignoring close/error from a stale socket');
      return;
    }
    this.client = null;
    this.cleanupSession(reason);
  }

  private cleanupSession(reason: string): void {
    this.clearTimers();
    // Keep the decoder + native window alive across reconnects: the next session
    // may reuse the same surface/size. Flush stale frames so the first new IDR
    // is shown immediately.
    this.decoder.flush();
    this.parser.reset();
    this.handshakeBytes = [];
    this.config = null;
    this.decoderErrorReported = false;
    this.lastDecodedFrames = 0;
    this.lastStats = {
      rxFps: 0, decodedFps: 0, bytesPerSec: 0, decodedFrames: 0, droppedFrames: 0,
      droppedNoKeyframe: 0, framesIn: 0, queueFrames: 0, decodeMs: 0, stalled: false,
      recvMs: 0, decMs: 0, renderMs: 0, e2eMs: 0, presentHz: 0
    };
    if (this.running) {
      this.setState(LinkState.IDLE, '等待 Mac 连接…');
    } else {
      this.setState(LinkState.ERROR, reason);
    }
    Log.i(`connection finished: ${reason}`);
  }

  private clearTimers(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    if (this.handshakeTimer >= 0) {
      clearTimeout(this.handshakeTimer);
      this.handshakeTimer = -1;
    }
  }

  private asciiToString(bytes: number[]): string {
    let out = '';
    for (let i = 0; i < bytes.length; i++) {
      out += String.fromCharCode(bytes[i]);
    }
    return out;
  }
}
