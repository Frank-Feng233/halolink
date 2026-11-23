export interface DecoderStats {
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
  // v1.3 latency breakdown (ms; clock-offset calibrated)
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

export const init: (surfaceId: string, width: number, height: number) => number;
export const pushFrame: (data: ArrayBuffer, offset?: number, length?: number, hostTsUs?: number) => number;
export const flush: () => void;
export const release: () => void;
export const isStarted: () => boolean;
export const isCodecValid: () => boolean;
export const getStats: () => DecoderStats;
export const setOnError: (callback: (code: number, message: string) => void) => void;
export const version: () => string;
