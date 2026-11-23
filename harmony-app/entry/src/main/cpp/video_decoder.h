/*
 * HaloLink video decoder (NAPI C++) — thread-safe, non-blocking design.
 *
 * Why this file has a worker thread
 * ---------------------------------
 * The ArkTS socket "message" callback runs on the UI thread. The first version
 * called OH_VideoDecoder_* directly from it, holding a mutex that the codec
 * callback threads also need. On the real device that deadlocked the UI thread
 * (THREAD_BLOCK_3S/6S appfreeze). Now:
 *
 *   ArkTS UI thread  ->  SetSurface()/PushFrame()/Flush()/Release()
 *                        = short mutex + memcpy into a bounded frame queue only.
 *   decoder worker    ->  owns the OH_VideoDecoder lifecycle: create/configure/
 *   (C++ thread)         prepare/start/stop/destroy and ALL input feeding.
 *   codec callbacks   ->  OnNeedInputBuffer publishes buffer slots, OnNewOutputBuffer
 *   (codec threads)      renders and counts. They only touch a short mutex.
 *
 * No mutex is ever held across an OH_VideoDecoder_* call, so codec callbacks can
 * never deadlock the UI thread.
 *
 * Latency / anti-artifact notes (see research/harmonyos-research.md):
 *  - SET_BUFFER_GEOMETRY is pinned on the native window; without it a 1080p
 *    surface shows a permanently mosaic bottom band.
 *  - OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY=1 makes the decoder emit decode order.
 *  - SetSurface() MUST be called before Prepare().
 *  - The first access unit's SPS/PPS are fed as OH_MD_KEY_CODEC_CONFIG; the
 *    host repeats SPS/PPS before every IDR, which is tolerated.
 *
 * Backpressure: frames are dropped instead of blocking. P frames are dropped
 * until the next IDR (needKeyframe state), keyframes are never dropped while a
 * non-key frame can be evicted instead.
 */

#ifndef HALOLINK_VIDEO_DECODER_H
#define HALOLINK_VIDEO_DECODER_H

#include <algorithm>
#include <array>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <native_window/external_window.h>

namespace halolink {

/** Small ring buffer used for avg/p95 latency reporting. */
class PerfRing {
 public:
  void Add(double value) {
    buf_[next_] = value;
    next_ = (next_ + 1) % kCap;
    if (count_ < kCap) {
      count_++;
    }
  }
  double Avg() const {
    if (count_ == 0) return 0.0;
    double sum = 0.0;
    for (size_t i = 0; i < count_; i++) {
      sum += buf_[i];
    }
    return sum / static_cast<double>(count_);
  }
  /** Nearest-rank p95 over the samples currently stored. */
  double P95() const {
    if (count_ == 0) return 0.0;
    std::array<double, kCap> sorted = buf_;
    std::sort(sorted.begin(), sorted.begin() + static_cast<long>(count_));
    size_t idx = static_cast<size_t>(static_cast<double>(count_) * 0.95);
    if (idx >= count_) idx = count_ - 1;
    return sorted[idx];
  }
  void Clear() {
    count_ = 0;
    next_ = 0;
  }

 private:
  static constexpr size_t kCap = 300;
  std::array<double, kCap> buf_{};
  size_t count_ = 0;
  size_t next_ = 0;
};

struct DecoderStats {
  int64_t decodedFrames = 0;
  int64_t droppedFrames = 0;       // dropped because the queue was full
  int64_t droppedNoKeyframe = 0;   // P frames dropped while waiting for an IDR
  int64_t framesIn = 0;            // access units accepted from ArkTS
  int64_t queuedFrames = 0;
  int64_t bytesIn = 0;
  int32_t lastError = 0;
  int32_t width = 0;
  int32_t height = 0;
  bool started = false;
  bool needKeyframe = false;
  int64_t configMs = 0;            // create/configure/prepare/start duration
  double avgDecodeMs = 0.0;        // input pts -> rendered frame, EMA
  double lastDecodeMs = 0.0;
  int64_t lastPtsUs = 0;
  // ---- v1.3 latency decomposition, local clock domain only.
  //      recv = (localRecvEpoch - hostCaptureTs) - min(window)   [single trip]
  //      dec  = localDecodeDone - localRecvEpoch                 [local]
  //      render = localRenderDone - localDecodeDone              [local]
  //      e2e  = recv + dec + render (never mixes clock domains)
  //      All values are averages / nearest-rank p95 of VALID samples only.
  double recvMs = 0.0;
  double recvP95Ms = 0.0;
  double decMs = 0.0;
  double decP95Ms = 0.0;
  double renderMs = 0.0;
  double renderP95Ms = 0.0;
  double e2eMs = 0.0;
  double e2eP95Ms = 0.0;
  double queueWaitMs = 0.0;        // diagnostics: decodeDone - recv (queue + decode)
  double queueWaitP95Ms = 0.0;
  double offsetMs = 0.0;           // estimated clock offset = min window recv raw
  int64_t pairErrors = 0;          // outputs without a matching timing sample
  int64_t invalidSamples = 0;      // samples dropped by the sanity guards
  int64_t validSamples = 0;        // samples contributing to the rings
  double renderHz = 0.0;           // actual presented frames per second
  bool lowLatency = false;         // OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY applied
  bool hostTs = false;             // host sent frame timestamps in this session
};

class VideoDecoder {
 public:
  using ErrorCallback = std::function<void(int32_t errorCode, const std::string &message)>;

  VideoDecoder();
  ~VideoDecoder();

  VideoDecoder(const VideoDecoder &) = delete;
  VideoDecoder &operator=(const VideoDecoder &) = delete;

  // All four are asynchronous: they only enqueue work and return immediately.
  // ArkTS runs on the UI thread, so these must never touch the codec.
  int32_t SetSurface(uint64_t surfaceId, int32_t width, int32_t height);
  // hostCaptureTsUs: v1.3 Unix-us capture timestamp from the host (0 if absent).
  int32_t PushFrame(const uint8_t *data, size_t length, int64_t hostCaptureTsUs = 0);
  void Flush();
  void Release();

  bool IsStarted();
  bool IsValid();
  DecoderStats GetStats();
  void SetErrorCallback(ErrorCallback cb);

 private:
  struct Frame {
    std::vector<uint8_t> data;
    bool keyframe = false;
    int64_t recvUs = 0;          // steady clock: for decode / render decomposition
    int64_t hostCaptureTsUs = 0; // Unix epoch us from the host (0 if none)
    int64_t hostRecvEpochUs = 0; // our epoch clock when this AU was received
  };
  struct FrameTiming {
    int64_t seq = 0;
    int64_t recvUs = 0;          // steady clock
    int64_t recvEpochUs = 0;     // epoch clock, only for host timestamp diff
    int64_t hostCaptureTsUs = 0; // host epoch us (0 if unsupported)
  };
  struct PendingInput {
    uint32_t index = 0;
    OH_AVBuffer *buffer = nullptr;
  };
  struct InitRequest {
    uint64_t surfaceId = 0;
    int32_t width = 0;
    int32_t height = 0;
  };

  static void OnError(OH_AVCodec *codec, int32_t errorCode, void *userData);
  static void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData);
  static void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer,
                                void *userData);
  static void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer,
                                void *userData);

  // ---- worker-thread only helpers (never called from ArkTS / callbacks) ----
  void WorkerLoop();
  void HandleInit(const InitRequest &request);
  void HandleFlush();
  void HandleRelease();
  void TeardownCodec();
  int32_t CreateAndStartCodec(int32_t width, int32_t height,
                              const std::vector<uint8_t> &codecConfig);
  void FeedOne(PendingInput input, Frame frame);
  void NotifyError(int32_t code, const std::string &message);

  // ---- shared state (guarded by mutex_) ----
  std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<Frame> frames_;
  std::deque<PendingInput> pendingInputs_;
  InitRequest pendingInit_;
  bool hasPendingInit_ = false;
  bool flushPending_ = false;
  bool releasePending_ = false;
  bool quit_ = false;
  bool started_ = false;
  bool codecInvalid_ = false;
  bool lowLatency_ = false;
  std::deque<FrameTiming> inFlight_;   // feed order -> output order (low latency)
  PerfRing recvRing_;
  PerfRing decRing_;
  PerfRing renderRing_;
  PerfRing e2eRing_;
  PerfRing queueWaitRing_;
  std::deque<double> recvRawWindow_;   // rolling window of raw recv diffs (ms)
  int64_t feedSeq_ = 0;
  int64_t pairErrors_ = 0;
  int64_t invalidSamples_ = 0;
  int64_t validSamples_ = 0;
  double renderHzEma_ = 0.0;
  bool hostTsSeen_ = false;
  bool callbackEnabled_ = false;
  bool needKeyframe_ = false;  // drop P frames until the next IDR
  bool clearQueueOnInit_ = false;  // re-init after rotation/resolution change
  uint64_t surfaceId_ = 0;
  int32_t width_ = 0;
  int32_t height_ = 0;
  DecoderStats stats_;
  ErrorCallback errorCallback_;

  // ---- worker-thread-only state ----
  std::thread worker_;
  OH_AVCodec *codec_ = nullptr;
  OHNativeWindow *window_ = nullptr;
  int64_t lastRenderUs_ = 0;
  // diagnostics counters (worker / callback threads, no mutex needed for logs)
  int64_t needInputCount_ = 0;
  int64_t feedCount_ = 0;
  int64_t outputCount_ = 0;
  int64_t lastStarveLogUs_ = 0;

  // Latency over robustness: keep the input queue very shallow (v1.3).
  static constexpr size_t kMaxQueuedFrames = 4;
  static constexpr int64_t kMaxFrameBytes = 16 * 1024 * 1024;
};

}  // namespace halolink

#endif  // HALOLINK_VIDEO_DECODER_H
