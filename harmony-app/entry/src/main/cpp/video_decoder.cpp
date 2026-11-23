/*
 * HaloLink video decoder implementation — see video_decoder.h for the threading
 * design and the OH_VideoDecoder pitfalls.
 */

#include "video_decoder.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <pthread.h>

#include <hilog/log.h>

#include "annexb_parser.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "HaloLink"

namespace halolink {

namespace {

constexpr int64_t kMaxFrameBytes = 16 * 1024 * 1024;
constexpr int32_t kRequestedMaxInputSize = 4 * 1024 * 1024;
constexpr auto kFirstFrameWait = std::chrono::milliseconds(300);

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// Wall-clock epoch microseconds: comparable with the host's capture timestamps.
int64_t EpochUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

// Fast Annex-B scan: true when the access unit contains an IDR slice or SPS,
// which is what we treat as a "keyframe" for drop/resync decisions.
bool HasKeyNal(const uint8_t *data, size_t length) {
  size_t i = 0;
  while (i + 3 <= length) {
    if (data[i] == 0x00 && data[i + 1] == 0x00) {
      if (data[i + 2] == 0x01) {
        const size_t header = i + 3;
        if (header < length) {
          const uint8_t type = data[header] & 0x1F;
          if (type == 5 || type == 7) {
            return true;
          }
        }
        i = header + 1;
        continue;
      }
      if (i + 4 <= length && data[i + 2] == 0x00 && data[i + 3] == 0x01) {
        const size_t header = i + 4;
        if (header < length) {
          const uint8_t type = data[header] & 0x1F;
          if (type == 5 || type == 7) {
            return true;
          }
        }
        i = header + 1;
        continue;
      }
    }
    ++i;
  }
  return false;
}

const char *AvErrName(OH_AVErrCode code) {
  switch (code) {
    case AV_ERR_OK:
      return "OK";
    case AV_ERR_NO_MEMORY:
      return "NO_MEMORY";
    case AV_ERR_OPERATE_NOT_PERMIT:
      return "OPERATE_NOT_PERMIT";
    case AV_ERR_INVALID_VAL:
      return "INVALID_VAL";
    case AV_ERR_IO:
      return "IO";
    case AV_ERR_TIMEOUT:
      return "TIMEOUT";
    case AV_ERR_UNKNOWN:
      return "UNKNOWN";
    case AV_ERR_SERVICE_DIED:
      return "SERVICE_DIED";
    case AV_ERR_INVALID_STATE:
      return "INVALID_STATE";
    case AV_ERR_UNSUPPORT:
      return "UNSUPPORT";
    default:
      return "OTHER";
  }
}

}  // namespace

VideoDecoder::VideoDecoder() {
  worker_ = std::thread([this]() { WorkerLoop(); });
  pthread_setname_np(worker_.native_handle(), "HaloLinkDecode");
}

VideoDecoder::~VideoDecoder() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    quit_ = true;
  }
  cv_.notify_all();
  if (worker_.joinable()) {
    worker_.join();
  }
}

void VideoDecoder::SetErrorCallback(ErrorCallback cb) {
  std::lock_guard<std::mutex> lock(mutex_);
  errorCallback_ = std::move(cb);
}

// ---------------------------------------------------------------------------
// ArkTS-facing API: enqueue only, never touches the codec, never blocks.
// ---------------------------------------------------------------------------

int32_t VideoDecoder::SetSurface(uint64_t surfaceId, int32_t width, int32_t height) {
  if (surfaceId == 0 || width <= 0 || height <= 0) {
    OH_LOG_ERROR(LOG_APP, "SetSurface invalid args id=%{public}llu %{public}dx%{public}d",
                 (unsigned long long)surfaceId, width, height);
    return -1;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // A re-init (rotation / host re-config) supersedes a pending flush: the
    // worker tears the old codec down anyway. A flush that runs *after* Start
    // would leave the fresh codec waiting for input buffers forever.
    clearQueueOnInit_ = (surfaceId_ != 0);
    flushPending_ = false;
    pendingInit_.surfaceId = surfaceId;
    pendingInit_.width = width;
    pendingInit_.height = height;
    hasPendingInit_ = true;
    surfaceId_ = surfaceId;
    width_ = width;
    height_ = height;
    stats_.width = width;
    stats_.height = height;
    needKeyframe_ = false;
  }
  cv_.notify_one();
  OH_LOG_INFO(LOG_APP, "decoder init queued surface=%{public}llu %{public}dx%{public}d",
              (unsigned long long)surfaceId, width, height);
  return 0;
}

int32_t VideoDecoder::PushFrame(const uint8_t *data, size_t length, int64_t hostCaptureTsUs) {
  if (data == nullptr || length == 0 || static_cast<int64_t>(length) > kMaxFrameBytes) {
    return -1;
  }
  const bool keyframe = HasKeyNal(data, length);
  const int64_t recvUs = NowUs();
  const int64_t recvEpochUs = hostCaptureTsUs > 0 ? EpochUs() : 0;
  std::lock_guard<std::mutex> lock(mutex_);
  if (surfaceId_ == 0) {
    return -2;  // no surface bound yet
  }
  if (needKeyframe_ && !keyframe) {
    stats_.droppedNoKeyframe++;
    return 0;  // wait for the next IDR instead of feeding a broken GOP
  }
  if (keyframe) {
    needKeyframe_ = false;
  }
  if (frames_.size() >= kMaxQueuedFrames) {
    // Prefer evicting a P frame so the keyframe is preserved.
    bool evicted = false;
    for (auto it = frames_.begin(); it != frames_.end(); ++it) {
      if (!it->keyframe) {
        frames_.erase(it);
        evicted = true;
        break;
      }
    }
    if (!evicted) {
      frames_.pop_front();
    }
    stats_.droppedFrames++;
    needKeyframe_ = true;
    if (!keyframe) {
      stats_.droppedNoKeyframe++;
      stats_.queuedFrames = static_cast<int64_t>(frames_.size());
      return 0;
    }
  }
  const size_t queueBefore = frames_.size();
  const size_t pendingCount = pendingInputs_.size();
  Frame frame;
  frame.data.assign(data, data + length);
  frame.keyframe = keyframe;
  frame.recvUs = recvUs;
  frame.hostCaptureTsUs = hostCaptureTsUs;
  frame.hostRecvEpochUs = recvEpochUs;
  frames_.push_back(std::move(frame));
  stats_.framesIn++;
  stats_.bytesIn += static_cast<int64_t>(length);
  stats_.queuedFrames = static_cast<int64_t>(frames_.size());
  cv_.notify_one();
  if (pendingCount > 0 || queueBefore == 0) {
    // diagnostic: log the first frames and occasional progress
    static std::atomic<int64_t> logCounter{0};
    if (logCounter.fetch_add(1) < 5 || logCounter.load() % 300 == 0) {
      OH_LOG_INFO(LOG_APP,
                  "pushFrame key=%{public}d len=%{public}zu queued=%{public}zu pending=%{public}zu",
                  keyframe ? 1 : 0, length, queueBefore, pendingCount);
    }
  }
  return 0;
}

void VideoDecoder::Flush() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    flushPending_ = true;
  }
  cv_.notify_one();
}

void VideoDecoder::Release() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    releasePending_ = true;
    hasPendingInit_ = false;
    frames_.clear();
    pendingInputs_.clear();
    stats_.queuedFrames = 0;
  }
  cv_.notify_one();
}

bool VideoDecoder::IsStarted() {
  std::lock_guard<std::mutex> lock(mutex_);
  return started_;
}

bool VideoDecoder::IsValid() {
  // Cheap: the worker owns the codec handle; report the last known state.
  std::lock_guard<std::mutex> lock(mutex_);
  return started_ && !codecInvalid_;
}

DecoderStats VideoDecoder::GetStats() {
  std::lock_guard<std::mutex> lock(mutex_);
  DecoderStats out = stats_;
  out.queuedFrames = static_cast<int64_t>(frames_.size());
  out.started = started_;
  out.needKeyframe = needKeyframe_;
  out.width = width_;
  out.height = height_;
  out.decMs = decRing_.Avg();
  out.decP95Ms = decRing_.P95();
  out.renderMs = renderRing_.Avg();
  out.renderP95Ms = renderRing_.P95();
  out.queueWaitMs = queueWaitRing_.Avg();
  out.queueWaitP95Ms = queueWaitRing_.P95();
  out.recvMs = recvRing_.Avg();
  out.recvP95Ms = recvRing_.P95();
  out.e2eMs = e2eRing_.Avg();
  out.e2eP95Ms = e2eRing_.P95();
  out.pairErrors = pairErrors_;
  out.invalidSamples = invalidSamples_;
  out.validSamples = validSamples_;
  out.renderHz = renderHzEma_;
  out.lowLatency = lowLatency_;
  out.hostTs = hostTsSeen_;
  if (!recvRawWindow_.empty()) {
    double bias = recvRawWindow_.front();
    for (double v : recvRawWindow_) {
      if (v < bias) {
        bias = v;
      }
    }
    out.offsetMs = bias;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Worker thread: sole owner of the OH_VideoDecoder lifecycle.
// ---------------------------------------------------------------------------

void VideoDecoder::WorkerLoop() {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!quit_) {
    if (releasePending_) {
      releasePending_ = false;
      lock.unlock();
      HandleRelease();
      lock.lock();
      continue;
    }
    if (hasPendingInit_) {
      const InitRequest request = pendingInit_;
      hasPendingInit_ = false;
      flushPending_ = false;  // re-init supersedes flush (see SetSurface)
      lock.unlock();
      HandleInit(request);
      lock.lock();
      continue;
    }
    if (flushPending_) {
      flushPending_ = false;
      lock.unlock();
      HandleFlush();
      lock.lock();
      continue;
    }
    if (started_ && codecInvalid_) {
      // A codec error was reported: tear down so the next SetSurface() can
      // rebuild the decoder cleanly. Never loops by itself.
      lock.unlock();
      TeardownCodec();
      lock.lock();
      started_ = false;
      codecInvalid_ = false;
      stats_.started = false;
      continue;
    }
    if (started_ && !pendingInputs_.empty() && !frames_.empty()) {
      static int64_t feedLoopCount = 0;
      feedLoopCount++;
      if (feedLoopCount <= 5 || feedLoopCount % 30 == 0) {
        OH_LOG_INFO(LOG_APP, "worker feed-loop #%{public}lld pending=%{public}zu frames=%{public}zu",
                    (long long)feedLoopCount, pendingInputs_.size(), frames_.size());
      }
      PendingInput input = pendingInputs_.front();
      pendingInputs_.pop_front();
      Frame frame = std::move(frames_.front());
      frames_.pop_front();
      stats_.queuedFrames = static_cast<int64_t>(frames_.size());
      lock.unlock();
      FeedOne(input, std::move(frame));
      lock.lock();
      continue;
    }
    if (started_ && !frames_.empty() && pendingInputs_.empty()) {
      const int64_t now = NowUs();
      if (now - lastStarveLogUs_ > 2000000) {
        lastStarveLogUs_ = now;
        OH_LOG_WARN(LOG_APP,
                    "decoder starved: %{public}zu frames queued but codec requested no input buffer",
                    frames_.size());
      }
    }
    {
      static int64_t waitCount = 0;
      waitCount++;
      if (waitCount % 500 == 0) {  // ~10s
        OH_LOG_INFO(LOG_APP, "worker waiting: started=%{public}d pending=%{public}zu frames=%{public}zu",
                    started_ ? 1 : 0, pendingInputs_.size(), frames_.size());
      }
    }
    cv_.wait_for(lock, std::chrono::milliseconds(20));
  }
  lock.unlock();
  TeardownCodec();
}

void VideoDecoder::HandleInit(const InitRequest &request) {
  TeardownCodec();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (clearQueueOnInit_) {
      // Old-orientation/-resolution access units must not leak into the fresh
      // decoder: the host restarts the new stream with SPS/PPS + IDR.
      const size_t dropped = frames_.size();
      frames_.clear();
      pendingInputs_.clear();
      stats_.queuedFrames = 0;
      needKeyframe_ = false;
      clearQueueOnInit_ = false;
      if (dropped > 0) {
        OH_LOG_INFO(LOG_APP, "init: dropped %{public}zu stale AUs from previous config",
                    dropped);
      }
    }
    // New stream/session: latency samples from the previous one are not comparable.
    inFlight_.clear();
    recvRing_.Clear();
    decRing_.Clear();
    renderRing_.Clear();
    e2eRing_.Clear();
    queueWaitRing_.Clear();
    recvRawWindow_.clear();
    feedSeq_ = 0;
    pairErrors_ = 0;
    invalidSamples_ = 0;
    validSamples_ = 0;
    hostTsSeen_ = false;
    lastRenderUs_ = 0;
    renderHzEma_ = 0.0;
  }
  const int64_t begin = NowUs();

  OHNativeWindow *window = nullptr;
  const int32_t createRet =
      OH_NativeWindow_CreateNativeWindowFromSurfaceId(request.surfaceId, &window);
  if (createRet != 0 || window == nullptr) {
    OH_LOG_ERROR(LOG_APP, "CreateNativeWindowFromSurfaceId failed ret=%{public}d", createRet);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stats_.lastError = createRet;
    }
    NotifyError(createRet, "OH_NativeWindow_CreateNativeWindowFromSurfaceId failed");
    return;
  }
  // CRITICAL: pin the buffer geometry (avoids the 1080p bottom-mosaic pitfall).
  const int32_t optRet =
      OH_NativeWindow_NativeWindowHandleOpt(window, SET_BUFFER_GEOMETRY, request.width,
                                            request.height);
  OH_LOG_INFO(LOG_APP, "SET_BUFFER_GEOMETRY(%{public}d,%{public}d) ret=%{public}d",
              request.width, request.height, optRet);
  window_ = window;

  // Wait (briefly) for the first access unit so SPS/PPS can be provided as
  // codec-specific data before Prepare; fall back to in-band SPS/PPS otherwise.
  std::vector<uint8_t> codecConfig;
  {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait_for(lock, kFirstFrameWait, [this]() {
      return quit_ || releasePending_ || hasPendingInit_ || !frames_.empty();
    });
    if (!frames_.empty()) {
      ExtractCodecConfig(frames_.front().data.data(), frames_.front().data.size(), codecConfig);
    }
  }
  if (quit_ || releasePending_) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    OH_LOG_INFO(LOG_APP, "init: queued=%{public}zu frames, codec config=%{public}zu bytes",
                frames_.size(), codecConfig.size());
  }

  const int32_t startRet = CreateAndStartCodec(request.width, request.height, codecConfig);
  if (startRet != 0) {
    TeardownCodec();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stats_.lastError = startRet;
      stats_.started = false;
    }
    return;
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    started_ = true;  // CRITICAL: gates the worker feed loop
    stats_.started = true;
    stats_.configMs = (NowUs() - begin) / 1000;
    needKeyframe_ = false;
    OH_LOG_INFO(LOG_APP, "decoder started in %{public}lld ms (cfg=%{public}zu bytes)",
                (long long)stats_.configMs, codecConfig.size());
  }
  cv_.notify_one();
}

int32_t VideoDecoder::CreateAndStartCodec(int32_t width, int32_t height,
                                          const std::vector<uint8_t> &codecConfig) {
  codec_ = OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
  if (codec_ == nullptr) {
    NotifyError(-1, "OH_VideoDecoder_CreateByMime(AVC) returned null");
    return -3;
  }
  OH_AVCodecCallback callback;
  callback.onError = &VideoDecoder::OnError;
  callback.onStreamChanged = &VideoDecoder::OnStreamChanged;
  callback.onNeedInputBuffer = &VideoDecoder::OnNeedInputBuffer;
  callback.onNewOutputBuffer = &VideoDecoder::OnNewOutputBuffer;
  OH_AVErrCode ret = OH_VideoDecoder_RegisterCallback(codec_, callback, this);
  if (ret != AV_ERR_OK) {
    NotifyError(ret, "OH_VideoDecoder_RegisterCallback failed");
    return -3;
  }

  OH_AVFormat *format = OH_AVFormat_Create();
  if (format == nullptr) {
    NotifyError(-1, "OH_AVFormat_Create failed");
    return -3;
  }
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
  lowLatency_ = true;
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, kRequestedMaxInputSize);
  if (!codecConfig.empty()) {
    OH_AVFormat_SetBuffer(format, OH_MD_KEY_CODEC_CONFIG, codecConfig.data(),
                          codecConfig.size());
  }
  ret = OH_VideoDecoder_Configure(codec_, format);
  OH_AVFormat_Destroy(format);
  if (ret != AV_ERR_OK) {
    NotifyError(ret, std::string("OH_VideoDecoder_Configure failed: ") + AvErrName(ret));
    return -4;
  }
  // SetSurface must happen before Prepare (documented requirement).
  ret = OH_VideoDecoder_SetSurface(codec_, window_);
  if (ret != AV_ERR_OK) {
    NotifyError(ret, std::string("OH_VideoDecoder_SetSurface failed: ") + AvErrName(ret));
    return -5;
  }
  ret = OH_VideoDecoder_Prepare(codec_);
  if (ret != AV_ERR_OK) {
    NotifyError(ret, std::string("OH_VideoDecoder_Prepare failed: ") + AvErrName(ret));
    return -6;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    callbackEnabled_ = true;
  }
  ret = OH_VideoDecoder_Start(codec_);
  if (ret != AV_ERR_OK) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      callbackEnabled_ = false;
    }
    NotifyError(ret, std::string("OH_VideoDecoder_Start failed: ") + AvErrName(ret));
    return -7;
  }
  return 0;
}

void VideoDecoder::TeardownCodec() {
  // Worker thread only. No mutex held here on purpose.
  if (codec_ != nullptr) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      started_ = false;
      stats_.started = false;
      callbackEnabled_ = false;
      pendingInputs_.clear();
    }
    OH_VideoDecoder_Stop(codec_);
    OH_VideoDecoder_Destroy(codec_);
    codec_ = nullptr;
  }
  if (window_ != nullptr) {
    OH_NativeWindow_DestroyNativeWindow(window_);
    window_ = nullptr;
  }
}

void VideoDecoder::HandleFlush() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    frames_.clear();
    pendingInputs_.clear();
    stats_.queuedFrames = 0;
    needKeyframe_ = true;
    codecInvalid_ = false;
  }
  if (codec_ != nullptr && started_) {
    const OH_AVErrCode ret = OH_VideoDecoder_Flush(codec_);
    OH_LOG_INFO(LOG_APP, "decoder flush ret=%{public}d", ret);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    inFlight_.clear();
    recvRing_.Clear();
    decRing_.Clear();
    renderRing_.Clear();
    e2eRing_.Clear();
    queueWaitRing_.Clear();
    recvRawWindow_.clear();
    feedSeq_ = 0;
    pairErrors_ = 0;
    invalidSamples_ = 0;
    validSamples_ = 0;
    hostTsSeen_ = false;
    lastRenderUs_ = 0;
    renderHzEma_ = 0.0;
  }

  }
}

void VideoDecoder::HandleRelease() {
  OH_LOG_INFO(LOG_APP, "decoder release");
  TeardownCodec();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    started_ = false;
    stats_.started = false;
    surfaceId_ = 0;
    frames_.clear();
    pendingInputs_.clear();
    stats_.queuedFrames = 0;
  }
}

void VideoDecoder::FeedOne(PendingInput input, Frame frame) {
  // Worker thread; no mutex held across codec calls.
  static int64_t feedEnterCount = 0;
  feedEnterCount++;
  if (feedEnterCount <= 5) {
    OH_LOG_INFO(LOG_APP, "FeedOne enter #%{public}lld codec=%{public}d started=%{public}d buf=%{public}d idx=%{public}u",
                (long long)feedEnterCount, codec_ != nullptr ? 1 : 0, started_ ? 1 : 0,
                input.buffer != nullptr ? 1 : 0, input.index);
  }
  if (codec_ == nullptr || !started_ || input.buffer == nullptr) {
    OH_LOG_WARN(LOG_APP, "FeedOne skipped: codec=%{public}d started=%{public}d buf=%{public}d",
                codec_ != nullptr ? 1 : 0, started_ ? 1 : 0, input.buffer != nullptr ? 1 : 0);
    return;
  }
  const int32_t capacity = OH_AVBuffer_GetCapacity(input.buffer);
  if (feedEnterCount <= 5) {
    OH_LOG_INFO(LOG_APP, "FeedOne capacity=%{public}d frame=%{public}zu", capacity, frame.data.size());
  }
  uint8_t *addr = OH_AVBuffer_GetAddr(input.buffer);
  if (addr == nullptr || capacity <= 0) {
    OH_LOG_WARN(LOG_APP, "input buffer invalid addr/capacity");
    return;
  }
  if (static_cast<int64_t>(frame.data.size()) > static_cast<int64_t>(capacity)) {
    // A single AU larger than the codec input buffer: drop and resync on IDR.
    std::lock_guard<std::mutex> lock(mutex_);
    stats_.droppedFrames++;
    needKeyframe_ = true;
    OH_LOG_WARN(LOG_APP, "AU %{public}zu > input capacity %{public}d, dropped",
                frame.data.size(), capacity);
    return;
  }
  memcpy(addr, frame.data.data(), frame.data.size());
  OH_AVCodecBufferAttr attr;
  attr.pts = NowUs();
  attr.size = static_cast<int32_t>(frame.data.size());
  attr.offset = 0;
  attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
  OH_AVBuffer_SetBufferAttr(input.buffer, &attr);
  if (feedEnterCount <= 5) {
    OH_LOG_INFO(LOG_APP, "FeedOne pushing idx=%{public}u size=%{public}d ...", input.index, attr.size);
  }
  const OH_AVErrCode ret = OH_VideoDecoder_PushInputBuffer(codec_, input.index);
  if (ret == AV_ERR_OK) {
    std::lock_guard<std::mutex> lock(mutex_);
    // Only successful feeds get a timing slot: output order == input order in
    // low-latency mode, so a FIFO recovers the matching frame's timestamps.
    // (Queueing on a failed push would desync the FIFO forever.)
    FrameTiming timing;
    timing.seq = feedSeq_++;
    timing.recvUs = frame.recvUs;
    timing.recvEpochUs = frame.hostRecvEpochUs;
    timing.hostCaptureTsUs = frame.hostCaptureTsUs;
    inFlight_.push_back(timing);
    // A deep in-flight queue means outputs are lagging behind inputs: pairing is
    // no longer trustworthy for latency, keep it tight and count the overflow.
    while (inFlight_.size() > 4) {
      inFlight_.pop_front();
      pairErrors_++;
    }
  }
  feedCount_++;
  if (feedCount_ <= 3 || feedCount_ % 300 == 0) {
    OH_LOG_INFO(LOG_APP, "feed #%{public}lld index=%{public}u size=%{public}zu key=%{public}d ret=%{public}d",
                (long long)feedCount_, input.index, frame.data.size(), frame.keyframe ? 1 : 0, ret);
  }
  if (ret != AV_ERR_OK) {
    std::lock_guard<std::mutex> lock(mutex_);
    stats_.lastError = ret;
    needKeyframe_ = true;
    OH_LOG_WARN(LOG_APP, "PushInputBuffer failed %{public}d (%{public}s)", ret,
                AvErrName(ret));
  }
}

// ---------------------------------------------------------------------------
// Codec callbacks (codec-owned threads). Only short mutex sections + notify.
// ---------------------------------------------------------------------------

void VideoDecoder::OnError(OH_AVCodec *codec, int32_t errorCode, void *userData) {
  auto *self = static_cast<VideoDecoder *>(userData);
  if (self == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(self->mutex_);
    self->stats_.lastError = errorCode;
    self->codecInvalid_ = true;
    self->needKeyframe_ = true;
  }
  self->cv_.notify_one();
  OH_LOG_ERROR(LOG_APP, "decoder OnError %{public}d", errorCode);
  self->NotifyError(errorCode, "OH_VideoDecoder error");
}

void VideoDecoder::OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData) {
  int32_t width = 0;
  int32_t height = 0;
  if (format != nullptr) {
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &width);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &height);
  }
  OH_LOG_INFO(LOG_APP, "decoder stream changed %{public}dx%{public}d", width, height);
}

void VideoDecoder::OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer,
                                     void *userData) {
  auto *self = static_cast<VideoDecoder *>(userData);
  if (self == nullptr) {
    return;
  }
  bool queued = false;
  {
    std::lock_guard<std::mutex> lock(self->mutex_);
    if (!self->callbackEnabled_ || self->quit_) {
      return;
    }
    PendingInput input;
    input.index = index;
    input.buffer = buffer;
    self->pendingInputs_.push_back(input);
    self->needInputCount_++;
    if (self->needInputCount_ <= 3 || self->needInputCount_ % 600 == 0) {
      OH_LOG_INFO(LOG_APP, "OnNeedInputBuffer #%{public}lld index=%{public}u pending=%{public}zu",
                  (long long)self->needInputCount_, index, self->pendingInputs_.size());
    }
    queued = true;
  }
  if (queued) {
    self->cv_.notify_one();
  }
}

void VideoDecoder::OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer,
                                     void *userData) {
  auto *self = static_cast<VideoDecoder *>(userData);
  if (self == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(self->mutex_);
    if (!self->callbackEnabled_ || self->quit_) {
      return;
    }
  }
  const int64_t decodeDoneUs = NowUs();
  int64_t inputPts = 0;
  if (buffer != nullptr) {
    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK) {
      inputPts = attr.pts;
    }
  }
  FrameTiming timing;
  bool paired = false;
  {
    std::lock_guard<std::mutex> lock(self->mutex_);
    if (!self->inFlight_.empty()) {
      timing = self->inFlight_.front();
      self->inFlight_.pop_front();
      paired = true;
    } else {
      self->pairErrors_++;
    }
  }
  // RenderOutputBuffer releases the buffer back to the codec and displays it.
  const OH_AVErrCode ret = OH_VideoDecoder_RenderOutputBuffer(codec, index);
  const int64_t renderDoneUs = NowUs();
  std::lock_guard<std::mutex> lock(self->mutex_);
  self->outputCount_++;
  if (self->outputCount_ <= 3 || self->outputCount_ % 300 == 0) {
    OH_LOG_INFO(LOG_APP, "render #%{public}lld index=%{public}u pts=%{public}lld ret=%{public}d",
                (long long)self->outputCount_, index, (long long)inputPts, ret);
  }
  if (ret == AV_ERR_OK) {
    self->stats_.decodedFrames++;
    if (inputPts > 0 && decodeDoneUs > inputPts) {
      const double latencyMs = static_cast<double>(decodeDoneUs - inputPts) / 1000.0;
      if (latencyMs >= 0.0 && latencyMs < 2000.0) {
        self->stats_.lastDecodeMs = latencyMs;
        self->stats_.avgDecodeMs = self->stats_.avgDecodeMs == 0.0
                                       ? latencyMs
                                       : self->stats_.avgDecodeMs * 0.9 + latencyMs * 0.1;
      }
    }
    const bool warm = self->stats_.decodedFrames <= 30;
    if (!warm && paired && timing.recvUs > 0 && timing.seq >= 0) {
      // ---- everything below is LOCAL clock domain for dec/render ----
      const double dec = static_cast<double>(decodeDoneUs - timing.recvUs) / 1000.0;
      const double render = static_cast<double>(renderDoneUs - decodeDoneUs) / 1000.0;
      if (dec >= 0.0 && dec < 500.0 && render >= 0.0 && render < 200.0) {
        self->decRing_.Add(dec);
        self->renderRing_.Add(render);
        self->queueWaitRing_.Add(dec);
        // ---- single-trip recv: local epoch - host epoch, bias = min of window ----
        double recv = 0.0;
        bool recvValid = false;
        if (timing.hostCaptureTsUs > 0 && timing.recvEpochUs > 0) {
          const double raw = static_cast<double>(timing.recvEpochUs -
                                                 timing.hostCaptureTsUs) / 1000.0;
          if (raw > -1000.0 && raw < 1000.0) {
            self->recvRawWindow_.push_back(raw);
            while (self->recvRawWindow_.size() > 300) {
              self->recvRawWindow_.pop_front();
            }
            double bias = self->recvRawWindow_.front();
            for (double v : self->recvRawWindow_) {
              if (v < bias) {
                bias = v;
              }
            }
            recv = raw - bias;
            recvValid = true;
            self->hostTsSeen_ = true;
          }
        }
        if (recvValid) {
          // e2e is built from the three LOCAL components, never by mixing clocks.
          const double e2e = recv + dec + render;
          if (recv >= -5.0 && recv < 1000.0 && e2e >= 0.0 && e2e < 1000.0) {
            self->recvRing_.Add(recv);
            self->e2eRing_.Add(e2e);
            self->validSamples_++;
          } else {
            self->invalidSamples_++;
          }
        } else if (timing.hostCaptureTsUs > 0) {
          // Host supports timestamps but the sample is out of sane range.
          self->invalidSamples_++;
        }
      } else {
        self->invalidSamples_++;
      }
    } else if (!paired) {
      self->invalidSamples_++;
    }
    if (self->lastRenderUs_ > 0 && renderDoneUs > self->lastRenderUs_) {
      const double hz = 1e6 / static_cast<double>(renderDoneUs - self->lastRenderUs_);
      if (hz > 1.0 && hz < 1000.0) {
        self->renderHzEma_ = self->renderHzEma_ == 0.0
                                 ? hz
                                 : self->renderHzEma_ * 0.9 + hz * 0.1;
      }
    }
    self->lastRenderUs_ = renderDoneUs;
  } else {
    self->stats_.lastError = ret;
    OH_LOG_WARN(LOG_APP, "RenderOutputBuffer failed %{public}d", ret);
  }
}

void VideoDecoder::NotifyError(int32_t code, const std::string &message) {
  ErrorCallback callback;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    callback = errorCallback_;
  }
  if (callback) {
    callback(code, message);
  }
}

}  // namespace halolink
