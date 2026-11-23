/*
 * HaloLink NAPI bridge — exposes the native OH_VideoDecoder to ArkTS.
 *
 * Module name: libdecoder.so  (ArkTS: import decoder from 'libdecoder.so')
 *
 * JS surface:
 *   init(surfaceId: string, width: number, height: number): number
 *   pushFrame(data: ArrayBuffer, offset?: number, length?: number): number
 *   flush(): void
 *   release(): void
 *   isStarted(): boolean
 *   isCodecValid(): boolean
 *   getStats(): DecoderStats
 *   setOnError(callback: (code: number, message: string) => void): void
 *   version(): string
 */

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "napi/native_api.h"
#include "video_decoder.h"

#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "HaloLink"

namespace {

halolink::VideoDecoder g_decoder;
napi_threadsafe_function g_errorTsfn = nullptr;

struct ErrorPayload {
  int32_t code;
  std::string message;
};

void CallJsError(napi_env env, napi_value jsCallback, void * /*context*/, void *data) {
  ErrorPayload *payload = static_cast<ErrorPayload *>(data);
  if (payload == nullptr) {
    return;
  }
  if (env != nullptr && jsCallback != nullptr) {
    napi_value argv[2];
    napi_create_int32(env, payload->code, &argv[0]);
    napi_create_string_utf8(env, payload->message.c_str(), payload->message.size(), &argv[1]);
    napi_call_function(env, nullptr, jsCallback, 2, argv, nullptr);
  }
  delete payload;
}

void PostErrorToJs(int32_t code, const std::string &message) {
  OH_LOG_ERROR(LOG_APP, "decoder error %{public}d: %{public}s", code, message.c_str());
  if (g_errorTsfn == nullptr) {
    return;
  }
  auto *payload = new ErrorPayload{code, message};
  napi_status status =
      napi_call_threadsafe_function(g_errorTsfn, payload, napi_tsfn_nonblocking);
  if (status != napi_ok) {
    delete payload;
  }
}

void ThrowIfFailed(napi_env env, napi_status status, const char *what) {
  if (status != napi_ok) {
    napi_throw_error(env, nullptr, what);
  }
}

napi_value JsInit(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    napi_throw_type_error(env, nullptr, "init(surfaceId, width, height) requires 3 args");
    return nullptr;
  }
  char surfaceIdBuf[64] = {0};
  size_t surfaceIdLen = 0;
  napi_get_value_string_utf8(env, argv[0], surfaceIdBuf, sizeof(surfaceIdBuf), &surfaceIdLen);
  int32_t width = 0;
  int32_t height = 0;
  napi_get_value_int32(env, argv[1], &width);
  napi_get_value_int32(env, argv[2], &height);
  const uint64_t surfaceId = strtoull(surfaceIdBuf, nullptr, 10);
  const int32_t ret = g_decoder.SetSurface(surfaceId, width, height);
  OH_LOG_INFO(LOG_APP, "native init surface=%{public}s %{public}dx%{public}d -> %{public}d",
              surfaceIdBuf, width, height, ret);
  napi_value result = nullptr;
  napi_create_int32(env, ret, &result);
  return result;
}

napi_value JsPushFrame(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value argv[4] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 1) {
    napi_throw_type_error(env, nullptr, "pushFrame(data, offset?, length?, hostTsUs?) requires data");
    return nullptr;
  }
  void *raw = nullptr;
  size_t totalLength = 0;
  napi_status status = napi_get_arraybuffer_info(env, argv[0], &raw, &totalLength);
  if (status != napi_ok || raw == nullptr) {
    napi_value result = nullptr;
    napi_create_int32(env, -1, &result);
    return result;
  }
  int64_t offset = 0;
  int64_t length = static_cast<int64_t>(totalLength);
  if (argc >= 2) {
    napi_get_value_int64(env, argv[1], &offset);
  }
  if (argc >= 3) {
    napi_get_value_int64(env, argv[2], &length);
  }
  int64_t hostTsUs = 0;
  if (argc >= 4) {
    double hostTsDouble = 0.0;
    if (napi_get_value_double(env, argv[3], &hostTsDouble) == napi_ok &&
        hostTsDouble > 0.0) {
      hostTsUs = static_cast<int64_t>(hostTsDouble);
    }
  }
  if (offset < 0 || length <= 0 ||
      static_cast<size_t>(offset) + static_cast<size_t>(length) > totalLength) {
    napi_value result = nullptr;
    napi_create_int32(env, -1, &result);
    return result;
  }
  const int32_t ret = g_decoder.PushFrame(static_cast<const uint8_t *>(raw) + offset,
                                         static_cast<size_t>(length), hostTsUs);
  napi_value result = nullptr;
  napi_create_int32(env, ret, &result);
  return result;
}

napi_value JsFlush(napi_env env, napi_callback_info /*info*/) {
  g_decoder.Flush();
  return nullptr;
}

napi_value JsRelease(napi_env env, napi_callback_info /*info*/) {
  g_decoder.Release();
  OH_LOG_INFO(LOG_APP, "native decoder released");
  return nullptr;
}

napi_value JsIsStarted(napi_env env, napi_callback_info /*info*/) {
  napi_value result = nullptr;
  napi_get_boolean(env, g_decoder.IsStarted(), &result);
  return result;
}

napi_value JsIsCodecValid(napi_env env, napi_callback_info /*info*/) {
  napi_value result = nullptr;
  napi_get_boolean(env, g_decoder.IsValid(), &result);
  return result;
}

napi_value JsGetStats(napi_env env, napi_callback_info /*info*/) {
  const halolink::DecoderStats stats = g_decoder.GetStats();
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  auto setNumber = [env, &obj](const char *name, double value) {
    napi_value v = nullptr;
    napi_create_double(env, value, &v);
    napi_set_named_property(env, obj, name, v);
  };
  setNumber("decodedFrames", static_cast<double>(stats.decodedFrames));
  setNumber("droppedFrames", static_cast<double>(stats.droppedFrames));
  setNumber("droppedNoKeyframe", static_cast<double>(stats.droppedNoKeyframe));
  setNumber("framesIn", static_cast<double>(stats.framesIn));
  setNumber("queuedFrames", static_cast<double>(stats.queuedFrames));
  setNumber("bytesIn", static_cast<double>(stats.bytesIn));
  setNumber("lastError", static_cast<double>(stats.lastError));
  setNumber("width", static_cast<double>(stats.width));
  setNumber("height", static_cast<double>(stats.height));
  setNumber("configMs", static_cast<double>(stats.configMs));
  setNumber("avgDecodeMs", stats.avgDecodeMs);
  setNumber("lastDecodeMs", stats.lastDecodeMs);
  napi_value started = nullptr;
  napi_get_boolean(env, stats.started, &started);
  napi_set_named_property(env, obj, "started", started);
  napi_value needKeyframe = nullptr;
  napi_get_boolean(env, stats.needKeyframe, &needKeyframe);
  napi_set_named_property(env, obj, "needKeyframe", needKeyframe);
  // v1.3 latency breakdown
  setNumber("recvMs", stats.recvMs);
  setNumber("recvP95Ms", stats.recvP95Ms);
  setNumber("decMs", stats.decMs);
  setNumber("decP95Ms", stats.decP95Ms);
  setNumber("renderMs", stats.renderMs);
  setNumber("renderP95Ms", stats.renderP95Ms);
  setNumber("e2eMs", stats.e2eMs);
  setNumber("e2eP95Ms", stats.e2eP95Ms);
  setNumber("queueWaitMs", stats.queueWaitMs);
  setNumber("queueWaitP95Ms", stats.queueWaitP95Ms);
  setNumber("offsetMs", stats.offsetMs);
  setNumber("pairErrors", static_cast<double>(stats.pairErrors));
  setNumber("invalidSamples", static_cast<double>(stats.invalidSamples));
  setNumber("validSamples", static_cast<double>(stats.validSamples));
  setNumber("renderHz", stats.renderHz);
  napi_value lowLatency = nullptr;
  napi_get_boolean(env, stats.lowLatency, &lowLatency);
  napi_set_named_property(env, obj, "lowLatency", lowLatency);
  napi_value hostTs = nullptr;
  napi_get_boolean(env, stats.hostTs, &hostTs);
  napi_set_named_property(env, obj, "hostTs", hostTs);
  return obj;
}

napi_value JsSetOnError(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 1) {
    napi_throw_type_error(env, nullptr, "setOnError(callback) requires a function");
    return nullptr;
  }
  napi_valuetype type = napi_undefined;
  napi_typeof(env, argv[0], &type);
  if (type != napi_function) {
    napi_throw_type_error(env, nullptr, "setOnError callback must be a function");
    return nullptr;
  }
  napi_value name = nullptr;
  napi_create_string_utf8(env, "HaloLinkDecoderError", NAPI_AUTO_LENGTH, &name);
  if (g_errorTsfn != nullptr) {
    napi_release_threadsafe_function(g_errorTsfn, napi_tsfn_abort);
    g_errorTsfn = nullptr;
  }
  napi_status status = napi_create_threadsafe_function(
      env, argv[0], nullptr, name, 0, 1, nullptr, nullptr, nullptr, CallJsError, &g_errorTsfn);
  if (status != napi_ok) {
    g_errorTsfn = nullptr;
    napi_throw_error(env, nullptr, "failed to create threadsafe function");
    return nullptr;
  }
  napi_unref_threadsafe_function(env, g_errorTsfn);
  g_decoder.SetErrorCallback(PostErrorToJs);
  return nullptr;
}

napi_value JsVersion(napi_env env, napi_callback_info /*info*/) {
  napi_value result = nullptr;
  napi_create_string_utf8(env, "halolink-decoder/0.1.0", NAPI_AUTO_LENGTH, &result);
  return result;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"init", nullptr, JsInit, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"pushFrame", nullptr, JsPushFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"flush", nullptr, JsFlush, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"release", nullptr, JsRelease, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"isStarted", nullptr, JsIsStarted, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"isCodecValid", nullptr, JsIsCodecValid, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getStats", nullptr, JsGetStats, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setOnError", nullptr, JsSetOnError, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"version", nullptr, JsVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

napi_module g_decoderModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "decoder",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterHaloLinkDecoderModule() {
  napi_module_register(&g_decoderModule);
}
