/**
 * HaloLink Display Protocol (HLDP v1) — wire format definitions and frame parser.
 *
 * Frame = 1 byte type + 4 byte big-endian payload length + payload.
 * Handshake = UTF-8 JSON lines ("\n" terminated) exchanged before binary mode.
 */

import { Log } from '../common/Logger';

export const PROTOCOL_NAME: string = 'halolink/1.1';
export const DEFAULT_PORT: number = 9528;
export const APP_VERSION: string = '0.1.0';

export const FRAME_VIDEO: number = 0x01;
export const FRAME_CONTROL: number = 0x02;
export const FRAME_PING: number = 0x03;
export const FRAME_PONG: number = 0x04;

export const MAX_FRAME_BYTES: number = 16 * 1024 * 1024;
export const HANDSHAKE_TIMEOUT_MS: number = 10000;

export enum LinkState {
  IDLE = 'idle',
  HANDSHAKE = 'handshake',
  STREAMING = 'streaming',
  ERROR = 'error'
}

export interface ScreenInfo {
  width: number;
  height: number;
  density: number;
  refreshRate: number;
  orientation: string;  // 'landscape' | 'portrait' (v1.1)
}

export interface HelloMessage {
  type: string;
  protocol: string;
  device: string;
  model: string;
  screen: ScreenInfo;
  features: string[];
  appVersion: string;
}

export interface CodecConfig {
  type: string;
  codec: string;
  width: number;
  height: number;
  fps: number;
  bitrate: number;
  profile: string;
  keyframeInterval: number;
  scaleMode: string;
  // ---- v1.1 optional fields (old hosts omit them) ----
  retina?: boolean;
  logicalWidth?: number;
  logicalHeight?: number;
  inputEnabled?: boolean;
  // v1.2: 'pixel1to1' = native 1:1 pixel rendering, 'scale' = HiDPI 2x + fit/fill
  renderMode?: string;
  // v1.3: host prefixes each VIDEO payload with 8-byte capture timestamp (Unix us, BE)
  frameTs?: boolean;
}

export interface ReadyMessage {
  type: string;
}

export interface TouchControl {
  type: string;
  action: string;
  x: number;
  y: number;
  pointerId: number;
}

export interface ScrollControl {
  type: string;
  dx: number;
  dy: number;
}

export interface KeyControl {
  type: string;
  action: string;
  key: string;
}

export interface TextControl {
  type: string;
  text: string;
}

export interface StatsControl {
  type: string;
  rxFps: number;
  decodeMs: number;
  rttMs: number;
  input: boolean;  // v1.1: tablet-side input (touch/key/text) enabled?
  // v1.3 latency decomposition (ms, averages over the 1s stats window)
  recvMs: number;   // video received - host capture timestamp
  decMs: number;    // decode done - received
  renderMs: number; // presented - decode done
  e2eMs: number;    // presented - host capture timestamp
  presentHz: number;// current vsync/present rate
}

/** v1.1: tablet -> Mac after a rotation / window size change. */
export interface DisplayControl {
  type: string;
  width: number;
  height: number;
  orientation: string;
  refreshRate: number;
}

export interface SimpleControl {
  type: string;
}

/** A slice of the parser buffer; valid only until the next append()/consume(). */
export interface FrameSlice {
  type: number;
  offset: number;
  length: number;
}

/**
 * Incremental length-prefixed frame parser.
 *
 * The parser keeps a growable staging buffer and never copies video payloads:
 * callers get an (offset,length) window into `buffer()` and can hand that
 * straight to the native decoder (which copies once into the codec queue).
 */
export class FrameParser {
  private data: Uint8Array;
  private writePos: number = 0;
  private readPos: number = 0;
  private pending: FrameSlice | null = null;

  constructor(initialCapacity: number = 2 * 1024 * 1024) {
    this.data = new Uint8Array(initialCapacity);
  }

  reset(): void {
    this.writePos = 0;
    this.readPos = 0;
    this.pending = null;
  }

  buffer(): ArrayBuffer {
    return this.data.buffer as ArrayBuffer;
  }

  pendingBytes(): number {
    return this.writePos - this.readPos;
  }

  private ensureSpace(extra: number): void {
    if (this.data.length - this.writePos >= extra) {
      return;
    }
    const pendingBytes = this.writePos - this.readPos;
    if (this.readPos > 0) {
      this.data.copyWithin(0, this.readPos, this.writePos);
      this.writePos = pendingBytes;
      this.readPos = 0;
    }
    if (this.data.length - this.writePos >= extra) {
      return;
    }
    let capacity = this.data.length;
    while (capacity - this.writePos < extra) {
      capacity = capacity * 2;
    }
    const grown = new Uint8Array(capacity);
    grown.set(this.data.subarray(0, this.writePos));
    this.data = grown;
  }

  append(chunk: ArrayBuffer): void {
    const src = new Uint8Array(chunk);
    this.ensureSpace(src.length);
    this.data.set(src, this.writePos);
    this.writePos += src.length;
  }

  /** Hex dump of the next few staging bytes (for protocol diagnostics). */
  describe(): string {
    const out: string[] = [];
    const end = Math.min(this.writePos, this.readPos + 12);
    for (let i = this.readPos; i < end; i++) {
      out.push(this.data[i].toString(16).padStart(2, '0'));
    }
    return `r=${this.readPos} w=${this.writePos} avail=${this.writePos - this.readPos} ` +
      `bytes=[${out.join(' ')}]`;
  }

  /** Returns the next complete frame (without consuming it), or null. */
  next(): FrameSlice | null {
    if (this.pending !== null) {
      return this.pending;
    }
    let resyncs = 0;
    while (resyncs <= 64) {
      const available = this.writePos - this.readPos;
      if (available < 5) {
        return null;
      }
      const base = this.readPos;
      const type = this.data[base];
      const length = ((this.data[base + 1] << 24) >>> 0) + (this.data[base + 2] << 16) +
        (this.data[base + 3] << 8) + this.data[base + 4];
      const typeValid = type === FRAME_VIDEO || type === FRAME_CONTROL ||
        type === FRAME_PING || type === FRAME_PONG;
      if (!typeValid || length > MAX_FRAME_BYTES) {
        // Never kill a session on a stray byte: skip one byte and rescan. The
        // video stream keeps flowing and the decoder resyncs on the next IDR.
        Log.w(`HLDP desync @${base}: type=0x${type.toString(16)} len=${length} ` +
          `${this.describe()}`);
        this.readPos++;
        if (this.readPos === this.writePos) {
          this.readPos = 0;
          this.writePos = 0;
        }
        resyncs++;
        continue;
      }
      if (available < 5 + length) {
        return null;
      }
      const slice: FrameSlice = { type: type, offset: base + 5, length: length };
      this.pending = slice;
      return slice;
    }
    throw new Error(`HLDP unrecoverable after ${resyncs} resync attempts`);
  }

  /** Consumes the frame most recently returned by next(). */
  consume(): void {
    if (this.pending === null) {
      return;
    }
    this.readPos += 5 + this.pending.length;
    this.pending = null;
    if (this.readPos === this.writePos) {
      this.readPos = 0;
      this.writePos = 0;
    }
  }

  /** Reads the pending frame payload as a Uint8Array view (no copy). */
  payloadView(): Uint8Array {
    const slice = this.pending;
    if (slice === null) {
      return new Uint8Array(0);
    }
    return this.data.subarray(slice.offset, slice.offset + slice.length);
  }
}

/** Encodes one HLDP frame into a single ArrayBuffer ready for socket.send(). */
export function encodeFrame(type: number, payload: Uint8Array | null): ArrayBuffer {
  const length = payload === null ? 0 : payload.length;
  const out = new Uint8Array(5 + length);
  out[0] = type;
  out[1] = (length >>> 24) & 0xFF;
  out[2] = (length >>> 16) & 0xFF;
  out[3] = (length >>> 8) & 0xFF;
  out[4] = length & 0xFF;
  if (payload !== null && length > 0) {
    out.set(payload, 5);
  }
  return out.buffer as ArrayBuffer;
}
