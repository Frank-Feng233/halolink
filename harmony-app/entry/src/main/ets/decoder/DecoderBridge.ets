// Default import is the documented way to load a Node-API module in ArkTS
// (the d.ts next to CMakeLists declares the exported members).
import nativeDecoder from 'libdecoder.so';
import { Log } from '../common/Logger';

/** Typed view of the libdecoder.so exports (kept local so the ArkTS compiler
 * is happy even when it loads the .so declaration as an untyped module). */
interface NativeDecoderModule {
  init(surfaceId: string, width: number, height: number): number;
  pushFrame(data: ArrayBuffer, offset?: number, length?: number, hostTsUs?: number): number;
  flush(): void;
  release(): void;
  isStarted(): boolean;
  isCodecValid(): boolean;
  getStats(): DecoderSnapshot;
  setOnError(callback: (code: number, message: string) => void): void;
  version(): string;
}

const native: NativeDecoderModule = nativeDecoder as NativeDecoderModule;

/** Decoder counters mirrored from the native layer. */
export interface DecoderSnapshot {
  decodedFrames: number;
  droppedFrames: number;
  droppedNoKeyframe: number;
  framesIn: number;
  queuedFrames: number;
  bytesIn: number;
  lastError: number;
  width: number;
  height: number;
  configMs: number;
  avgDecodeMs: number;
  lastDecodeMs: number;
  started: boolean;
  needKeyframe: boolean;
  // v1.3 latency breakdown (ms, clock-offset calibrated)
  recvMs: number;
  recvP95Ms: number;
  decMs: number;
  decP95Ms: number;
  renderMs: number;
  renderP95Ms: number;
  e2eMs: number;
  e2eP95Ms: number;
  queueWaitMs: number;
  queueWaitP95Ms: number;
  offsetMs: number;
  pairErrors: number;
  invalidSamples: number;
  validSamples: number;
  renderHz: number;
  lowLatency: boolean;
  hostTs: boolean;
}

/**
 * ArkTS wrapper around libdecoder.so (NAPI C++ OH_VideoDecoder).
 *
 * The native module only works when the XComponent surface exists; the display
 * server calls init() once both the surfaceId and the Mac's video size are known.
 */
export class DecoderBridge {
  private onErrorHandler: (code: number, message: string) => void;
  private inited: boolean = false;
  private surfaceId: string = '';
  private width: number = 0;
  private height: number = 0;
  private lastInitCode: number = 0;

  constructor(onError: (code: number, message: string) => void) {
    this.onErrorHandler = onError;
    try {
      native.setOnError((code: number, message: string) => {
        Log.e(`native decoder error ${code}: ${message}`);
        this.onErrorHandler(code, message);
      });
      const ver: string = native.version() as string;
      Log.i(`native decoder module loaded: ${ver}`);
    } catch (err) {
      Log.e(`failed to hook native decoder: ${JSON.stringify(err)}`);
    }
  }

  /** Returns the native init code: 0 = ok, negative = failure. */
  init(surfaceId: string, width: number, height: number): number {
    this.surfaceId = surfaceId;
    this.width = width;
    this.height = height;
    this.lastInitCode = native.init(surfaceId, width, height);
    this.inited = this.lastInitCode === 0;
    if (this.inited) {
      Log.i(`decoder bound surface=${surfaceId} size=${width}x${height}`);
    } else {
      Log.e(`decoder init failed code=${this.lastInitCode} surface=${surfaceId}`);
    }
    return this.lastInitCode;
  }

  /** Feeds one Annex-B access unit (zero-copy window into the TCP parser). */
  pushFrame(buffer: ArrayBuffer, offset: number, length: number, hostTsUs: number = 0): number {
    if (!this.inited) {
      return -10;
    }
    return native.pushFrame(buffer, offset, length, hostTsUs);
  }

  flush(): void {
    if (this.inited) {
      try {
        native.flush();
      } catch (err) {
        Log.w(`decoder flush failed: ${JSON.stringify(err)}`);
      }
    }
  }

  release(): void {
    if (this.inited) {
      try {
        native.release();
      } catch (err) {
        Log.w(`decoder release failed: ${JSON.stringify(err)}`);
      }
      this.inited = false;
    }
  }

  isInited(): boolean {
    return this.inited;
  }

  initCode(): number {
    return this.lastInitCode;
  }

  surface(): string {
    return this.surfaceId;
  }

  videoWidth(): number {
    return this.width;
  }

  videoHeight(): number {
    return this.height;
  }

  snapshot(): DecoderSnapshot {
    if (!this.inited) {
      const idle: DecoderSnapshot = {
        decodedFrames: 0, droppedFrames: 0, droppedNoKeyframe: 0, framesIn: 0,
        queuedFrames: 0, bytesIn: 0, lastError: 0, width: this.width, height: this.height,
        configMs: 0, avgDecodeMs: 0, lastDecodeMs: 0, started: false, needKeyframe: false,
        recvMs: 0, recvP95Ms: 0, decMs: 0, decP95Ms: 0, renderMs: 0, renderP95Ms: 0,
        e2eMs: 0, e2eP95Ms: 0, queueWaitMs: 0, queueWaitP95Ms: 0, offsetMs: 0,
        pairErrors: 0, invalidSamples: 0, validSamples: 0,
        renderHz: 0, lowLatency: false, hostTs: false
      };
      return idle;
    }
    const stats: DecoderSnapshot = native.getStats();
    const out: DecoderSnapshot = {
      decodedFrames: stats.decodedFrames,
      droppedFrames: stats.droppedFrames,
      droppedNoKeyframe: stats.droppedNoKeyframe,
      framesIn: stats.framesIn,
      queuedFrames: stats.queuedFrames,
      bytesIn: stats.bytesIn,
      lastError: stats.lastError,
      width: stats.width,
      height: stats.height,
      configMs: stats.configMs,
      avgDecodeMs: stats.avgDecodeMs,
      lastDecodeMs: stats.lastDecodeMs,
      started: stats.started,
      needKeyframe: stats.needKeyframe,
      recvMs: stats.recvMs,
      recvP95Ms: stats.recvP95Ms,
      decMs: stats.decMs,
      decP95Ms: stats.decP95Ms,
      renderMs: stats.renderMs,
      renderP95Ms: stats.renderP95Ms,
      e2eMs: stats.e2eMs,
      e2eP95Ms: stats.e2eP95Ms,
      queueWaitMs: stats.queueWaitMs,
      queueWaitP95Ms: stats.queueWaitP95Ms,
      offsetMs: stats.offsetMs,
      pairErrors: stats.pairErrors,
      invalidSamples: stats.invalidSamples,
      validSamples: stats.validSamples,
      renderHz: stats.renderHz,
      lowLatency: stats.lowLatency,
      hostTs: stats.hostTs
    };
    return out;
  }
}
