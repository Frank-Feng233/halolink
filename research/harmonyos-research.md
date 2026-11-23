# HarmonyOS 7.0 平板「macOS 扩展屏客户端」可行性调研报告

- 调研日期：2026-11-21（Asia/Shanghai）
- 目标设备：HUAWEI MatePad 11.5"S（TGR-W10），HarmonyOS 7.0，无线调试 `<tablet-ip>:36659`
- 目标应用：(a) 作为 macOS 扩展显示客户端——TCP/Wi-Fi 收 H.264、全屏最低延迟渲染、触摸/键盘回传；(b) 加分项：本机屏幕采集推流
- 标注约定：**[已实测]** = 我在设备/本机命令行亲自验证；**[文档明确]** = 官方文档明文；**[不确定]** = 证据冲突或需真机验证

---

## 0. 环境实测基线（先看这个，后面所有结论都基于它）

我通过本机 `hdc`（`/Users/yourname/harmony/huawei/hdc`，Ver 3.2.0f）连上设备并读取参数，全部为只读命令：

| 项目 | 实测值 |
|---|---|
| `const.ohos.apiversion` | **26** |
| `const.product.software.version` | `TGR-W10G 7.0.0.111(SP18C00E111R2P2)` |
| `const.ohos.fullname` | `OpenHarmony-7.0.0.111` |
| `const.product.model` / 名称 | `TGR-W10` / `HUAWEI MatePad 11.5''S` |
| `const.product.devicetype` | `tablet` |
| 屏幕 | 2800×1840，Density 2.5，当前 rotation 0；官方规格 11.5" LCD、3:2、30–144Hz 自适应 |
| 设备侧可用工具 | `/bin/uitest`（**7.0.0.1**）、`/bin/snapshot_display`、`/bin/bm`、`/bin/aa`、`/bin/hidumper` |
| 系统服务 | WindowManagerService、DisplayManagerService、RenderService、AbilityManagerService 均在 |

**版本对应关系（关键）**：HarmonyOS 7.0 = **API 26**（26.0.0 / 26.0.1）。从 API 26.0.0 起华为改用语义化版本 `X.Y.Z`，取代旧的 `X.Y.Z(N)` 写法；`compatibleSdkVersion` 要写三段式 `"26.0.0"`。历史对照：5.1.1=19、6.0.0=20、6.0.1=21、6.0.2=22、7.0=26。
- 证据：[HarmonyOS 7 正式发布通知](https://developer.huawei.com.cn/consumer/cn/notice/detail/?id=9002210958618976001)、[版本号格式调整说明](https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/version-number-26)、[API 26 语义化版本说明](https://developer.huawei.com/consumer/cn/blog/topic/03229256051709189)
- 机型支持：MatePad 11.5"S 2024 / 2025 系列均在 HarmonyOS 7 公测转正式名单内（[名单](https://m.163.com/dy/article/LB574GNQ0511B8LM.html)）
- 设备规格参考：[HUAWEI MatePad 11.5"S specs](https://consumer.huawei.com/es/tablets/matepad-11-5-s/specs/)

> 注意：调研中途设备一度 `Offline`（无线调试空闲掉线），重新 `hdc tconn` 后恢复。做长任务时要写重连逻辑。

---

## 1. HarmonyOS NEXT 屏幕采集（AVScreenCapture / 权限 / 虚拟屏）

### 1.1 三条不同的 API 线，能力与权限完全不同

| 路径 | 形态 | 权限 | 三方可用性 | 输出 |
|---|---|---|---|---|
| `media.createAVScreenCaptureRecorder()`（ArkTS） | `@kit.MediaKit` → `media.AVScreenCaptureRecorder` | **无权限要求**（仅麦克风时需 `ohos.permission.MICROPHONE`） | ✅ 可用 | **只能写 MP4 文件**（传 fd），不是原始帧 |
| `OH_AVScreenCapture_*`（C API） | `libnative_avscreen_capture.so`，API 10+ | 头文件**未标注任何权限要求**；指南只提麦克风/PC 场景权限 | **[不确定]** 隐藏系统权限门槛 | 原始码流 buffer，或 `StartScreenCaptureWithSurface` 直送 Surface |
| `OH_NativeDisplayManager_CaptureScreenPixelmap`（C API） | `libnative_display_manager.so`，API 14+ | **`ohos.permission.CUSTOM_SCREEN_CAPTURE`**（normal / user_grant / Tablet 支持） | ✅ 明确可用 | 单帧全屏 `OH_PixelmapNative` |
| `display.createVirtualScreen`（ArkTS） | API 16+ | `ohos.permission.ACCESS_VIRTUAL_SCREEN`（system_basic，**受限**，仅车机场景可申请） | ❌ 不可用 | 虚拟屏 |
| `ohos.permission.CAPTURE_SCREEN` | 系统权限 | **system_core / system_grant**，定义在「系统应用权限」列表 | ❌ 三方不可用 | — |

### 1.2 权限的精确事实（这是最重要的一条）

- `ohos.permission.CUSTOM_SCREEN_CAPTURE`：**normal 级别、user_grant、支持 PC/2in1 | Tablet | Phone、起始 API 14**（API 14–20 仅平板/PC，API 21 起手机也支持）。属于「所有应用可申请的用户授权权限」，**不需要 AGC 审批**，只需运行时 `requestPermissionsFromUser` 弹窗。
  来源：[permissions-for-all-user.md](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/permissions-for-all-user.md)
- `ohos.permission.CAPTURE_SCREEN`：**system_core / system_grant**，出现在「系统应用权限」列表 → 普通签名的三方 HAP 声明了也不会被授予（除非 ACL + 系统信任证书）。
  来源：[permissions-for-system-apps.md](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/permissions-for-system-apps.md)
- `ohos.permission.CUSTOM_SCREEN_RECORDING`（免隐私弹窗）、`EXEMPT_CAPTURE_SCREEN_AUTHORIZE`（免每次授权）、`ACCESS_VIRTUAL_SCREEN`：都在「受限开放权限」清单里，需 AGC 按场景审批（`CUSTOM_SCREEN_RECORDING` 明确仅 PC/2in1）。
  来源：[restricted-permissions.md](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/restricted-permissions.md)
- 与"输入/桌面共享"相关的受限权限：`INPUT_MONITORING`（录屏显示触摸效果/共享桌面，system_basic，API 12 起向普通应用开放但仍是受限申请）、`INTERCEPT_INPUT_EVENT`（云桌面/远程登录客户端，**仅 PC/2in1**）。

**结论**：三方 HAP 想拿"屏幕图像"，唯一无争议、无需审批的权限是 `CUSTOM_SCREEN_CAPTURE` → 对应 API 是 `OH_NativeDisplayManager_CaptureScreenPixelmap`（单帧截屏）。想拿"实时原始码流"，文档层面 `OH_AVScreenCapture` 没有写权限要求，但 `CAPTURE_SCREEN` 这个 system_core 权限的存在、以及所有系统级投屏项目（HOScrcpy/hongjing/OpenHarmony_Scrcpy）都走系统签名 + ACL 的事实，说明**大概率存在未写进文档的门槛**，必须写真机冒烟程序验证。

### 1.3 ArkTS 录屏（写文件）官方代码

`AVScreenCaptureRecorder` 首批接口 API 12+；`skipPrivacyMode`、`setMicEnabled`、`on('stateChange')` 也都是 12+；`setPickerMode`/`excludePickerWindows`/`presentPicker` 是 **API 22+**；`pauseRecording`/`resumeRecording` 文档标注**起始版本 26.0.0**（说明当前文档已是 API 26 线）。

```ts
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import fileIo from '@ohos.file.fs';

let recorder: media.AVScreenCaptureRecorder | undefined;

// 1) 创建
media.createAVScreenCaptureRecorder().then((r: media.AVScreenCaptureRecorder) => {
  recorder = r;
  // 2) 状态回调：用户在系统弹窗里点“允许/拒绝”都会回调
  r.on('stateChange', (state: media.AVScreenCaptureStateCode) => {
    console.info('capture state -> ' + state); // STARTED / CANCELED / STOPPED_BY_USER ...
  });
  r.on('error', (err: BusinessError) => {
    console.error(`capture error ${err.code} ${err.message}`);
  });

  // 3) 目标文件（MP4），把 fd 交给录屏器
  const file = fileIo.openSync('/data/storage/el2/base/haps/screen.mp4',
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
  const cfg: media.AVScreenCaptureRecordConfig = { fd: file.fd, frameWidth: 2800, frameHeight: 1840 };

  // 4) init -> start：start 时系统弹出录屏隐私弹窗 / 屏幕-窗口 Picker
  return r.init(cfg).then(() => r.startRecording());
}).catch((e: BusinessError) => console.error(`init/start failed ${e.code} ${e.message}`));

// 5) 结束：stopRecording() -> release()
```

文档：[Interface (AVScreenCaptureRecorder)](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-media-kit/arkts-apis-media-AVScreenCaptureRecorder.md)、[createAVScreenCaptureRecorder](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-media-kit/arkts-apis-media-f.md)

**这条路的硬伤**：输出是 MP4 文件，不是帧。要"边录边取帧"只能读文件尾部做解析，延迟 = 编码 GOP + 文件系统刷写，实测意义不大。所以"采集并推流"必须走 C API。

### 1.4 C API 原始码流 / Surface 采集（推荐给加分项）

能力清单（`native_avscreen_capture.h`，我逐条解析过）：

- `OH_AVScreenCapture_Create/Init/StartScreenCapture/StopScreenCapture/Release`
- **`OH_AVScreenCapture_StartScreenCaptureWithSurface(capture, OHNativeWindow*)`（API 12+）** —— 屏幕数据直接进 Surface，可**零拷贝直连视频编码器输入 Surface**
- `OH_AVScreenCapture_SetMaxVideoFrameRate(capture, fps)`（API 14+，上限 60fps）
- `OH_AVScreenCapture_SetDisplayCallback` / `SetSelectionCallback` / `GetCaptureTypeSelected` / `GetDisplayIdSelected` —— 用户选择"整屏 or 某窗口"、选了哪个 displayId
- `OH_AVScreenCapture_CreateCaptureStrategy` / `SetCaptureStrategy`（API 20+）、`StrategyForBFramesEncoding`、`SetCaptureArea`、`SetCaptureContentChangedCallback`
- `OH_MultiDisplayCapability`（**API 24**）：多屏联合录制能力（宽/高/是否支持）
- 音频侧：`AcquireAudioBuffer`、`SetMicrophoneEnabled`；隐私：`SkipPrivacyMode`

官方 C 流程骨架（摘自 [avscreencapture-c-basic-process.md](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/media/media/avscreencapture-c-basic-process.md)）：

```cpp
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
// CMake: libnative_avscreen_capture.so libnative_buffer.so libnative_media_core.so

OH_AVScreenCapture* capture = OH_AVScreenCapture_Create();

// 视频参数：2800x1840 需按设备能力取，通常用 display 信息换算
OH_VideoCaptureInfo videoInfo = {
  .displayId = 0,            // 或 -1 由系统弹 Picker 让用户选
  .videoFrameWidth = 2800,
  .videoFrameHeight = 1840,
  .videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA
};
OH_VideoEncInfo videoEncInfo = {
  .videoCodec = OH_H264, .videoBitrate = 20000000, .videoFrameRate = 60
};
OH_AudioCaptureInfo innerCapInfo = { .audioSampleRate = 48000, .audioChannels = 2,
                                     .audioSource = OH_ALL_PLAYBACK };
OH_AudioEncInfo audioEncInfo = { .audioBitrate = 48000, .audioSampleRate = 48000,
                                 .audioChannels = 2 };
OH_AVScreenCaptureConfig cfg = {
  .captureMode = OH_CAPTURE_HOME_SCREEN,   // 另有 OH_CAPTURE_SPECIFIED_SCREEN / OH_CAPTURE_SPECIFIED_WINDOW
  .dataType = OH_ORIGINAL_STREAM,          // 关键：取码流而不是存文件
  .audioInfo = { .micCapInfo = {}, .innerCapInfo = innerCapInfo, .audioEncInfo = audioEncInfo },
  .videoInfo = { .videoCapInfo = videoInfo, .videoEncInfo = videoEncInfo }
};

OH_AVScreenCapture_Init(capture, cfg);
OH_AVScreenCapture_SetDataCallback(capture, OnBufferAvailable, /*userData*/nullptr);
OH_AVScreenCapture_SetStateCallback(capture, OnStateChange, nullptr);   // 用户允许/拒绝/被打断
OH_AVScreenCapture_StartScreenCapture(capture);

// Surface 模式（更低延迟，接编码器）：
//   OH_VideoEncoder_GetSurface(enc, &encSurface);
//   OH_AVScreenCapture_StartScreenCaptureWithSurface(capture, encSurface);
//   OH_AVScreenCapture_SetMaxVideoFrameRate(capture, 60);
```

Buffer 回调里拿 `OH_AVBuffer` → `OH_AVBuffer_GetNativeBuffer()`（`OH_SCREEN_CAPTURE_BUFFERTYPE_VIDEO`）→ 转 `OHNativeWindow`/EGL 纹理或直接喂编码器。

**用户授权流程**：`StartScreenCapture` 时系统弹隐私保护弹窗（含"屏幕隐私保护"勾选项，勾选后横幅通知/控制中心等被屏蔽），并通过 `OH_AVScreenCapture_OnStateChange` 上报 `OH_SCREEN_CAPTURE_STATE_STARTED` / `CANCELED` / `STOPPED_BY_USER` / `INTERRUPTED_BY_OTHER` 等状态。详见 [系统录屏授权允许/禁止回调](https://developer.huawei.com/consumer/cn/doc/architecture-guides/common-v1_26-ts_390-0000002506427360)。
注意：**没有** `AVScreenCaptureStrategy` 这个 ArkTS 类；策略是 C 结构体 `OH_AVScreenCapture_CaptureStrategy`（API 20+）与 `OH_AVScreenCapture_SetCaptureStrategy`。

### 1.5 虚拟屏 / 第二屏（结论：三方拿不到）

```ts
// display.createVirtualScreen (API 16+)
import { display } from '@kit.ArkUI';
// 需要权限：ohos.permission.ACCESS_VIRTUAL_SCREEN
let screenId: number = await display.createVirtualScreen({
  name: 'screen01', width: 1920, height: 1080, density: 2, surfaceId: '', supportsFocus: false
});
```
`ACCESS_VIRTUAL_SCREEN` 是 system_basic **受限**权限，"可申请的特殊场景：连接车机播放视频/导航"，普通 HAP 走 AGC 也不会批。→ **不能靠虚拟屏做扩展桌面**。参考 [js-apis-display.md](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/js-apis-display.md)。

### 1.6 实测：hdc `snapshot_display` 兜底方案的性能（重要负面结论）

```
hdc shell "snapshot_display -f /data/local/tmp/probe_1.jpeg"
→ success: snapshot display 0, write to ... as jpeg, width: 2800, height: 1840
real 0.65 / 0.61 / 0.63 秒（3 次，含 hdc 往返）
文件 189 KB
```
即 **≈1.6 fps**。作为"偶尔截图"可用，作为投屏兜底**完全不可行**。命令见 [DevEco 截屏文档](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hmos-screenshot)。

---

## 2. H.264 硬件编解码（ArkTS / AVCodec）与低延迟渲染

### 2.1 最重要结论：ArkTS 层**没有**公开的 VideoDecoder / VideoEncoder

我逐一核对了 API 26 文档的 Kit 索引：
- Media Kit ArkTS API 只有 `@ohos.multimedia.media` 下的 AVPlayer / AVRecorder / AVTranscoder / AVImageGenerator / AVMetadataExtractor / **AVScreenCaptureRecorder** / MediaSource 等，**没有 VideoDecoder / VideoEncoder**（`VideoPlayer` 已标记废弃）。
  索引：[apis-media-kit Readme-CN.md](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-media-kit/Readme-CN.md)
- AVCodec Kit **只有 C API**（`OH_VideoDecoder_*` / `OH_VideoEncoder_*` / `OH_AVDemuxer` / `OH_AVMuxer`），无 ArkTS 接口。
  索引：[apis-avcodec-kit Readme-CN.md](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-avcodec-kit/Readme-CN.md)

→ **低延迟 H.264 硬解必须是 C++（NAPI）+ `OH_VideoDecoder`**，没有纯 ArkTS 路线。这是本项目最大的工程量与风险来源。

### 2.2 解码：Surface 模式直送 XComponent（延迟最低）

关键点：
- `OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC)`
- Surface 模式：`OH_VideoDecoder_SetSurface(codec, nativeWindow)` **必须在 `Prepare` 之前**
- **低时延开关**：`OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1)` —— 平台支持时解码器**按解码序输出帧**（不等重排），这是低延迟直播的关键
- 送显：`OH_VideoDecoder_RenderOutputBuffer(codec, index)` 或 `RenderOutputBufferAtTime`（可控显示时刻）
- H.264 裸流需先喂 **SPS/PPS**（codec-specific data），配置键 `OH_MD_KEY_CODEC_CONFIG`；否则部分解码器起不来

```cpp
// 配置（节选自官方 video-decoding.md 的 Surface 模式）
OH_AVFormat *format = OH_AVFormat_Create();
OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, 2800);
OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, 1840);
OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
// 可选，配置低时延解码：使能后按解码序输出帧
OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
// H.264: 把 SPS/PPS 作为 codec config 送进去
// OH_AVFormat_SetBuffer(format, OH_MD_KEY_CODEC_CONFIG, spsPps, spsPpsLen);

OH_VideoDecoder_Configure(videoDec, format);
OH_VideoDecoder_SetSurface(videoDec, nativeWindow);   // 来自 XComponent
OH_VideoDecoder_Prepare(videoDec);
OH_VideoDecoder_Start(videoDec);
// OnNeedInputBuffer -> OH_VideoDecoder_PushInputBuffer
// OnNewOutputBuffer -> OH_VideoDecoder_RenderOutputBuffer（送显并释放）
```
文档：[视频解码](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/media/avcodec/video-decoding.md)

### 2.3 编码（加分项）：Surface 输入 = 采集 Surface 直连，零拷贝

- `OH_VideoEncoder_GetSurface(enc, &nativeWindow)`（**必须在 Prepare 前**）
- 把该 Surface 交给 `OH_AVScreenCapture_StartScreenCaptureWithSurface` → 屏幕帧不进 CPU
- `OH_AVCODEC_MIMETYPE_VIDEO_AVC` + `OH_AVCodec_GetCapabilityByCategory(..., HARDWARE)` 确认硬编
- 低延迟编码建议：**关闭 B 帧**（`OH_AVScreenCapture_StrategyForBFramesEncoding` / 编码器 GOP 设小、强制 IDR 按需）、`OH_MD_KEY_I_FRAME_INTERVAL` 小、`OH_MD_KEY_PROFILE` = baseline/main
文档：[视频编码](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/media/avcodec/video-encoding.md)

### 2.4 渲染：XComponent(SURFACE) + surfaceId

```ts
// ArkTS 侧
XComponent({ id: 'player', type: XComponentType.SURFACE, controller: this.xc })
  .onLoad(() => {
    // SURFACE 类型：拿到 surfaceId 交给 native
    this.surfaceId = this.xc.getXComponentSurfaceId();   // string
    nativeRender.setSurfaceId(BigInt(this.surfaceId));   // NAPI 传给 C++
  })
  .width('100%').height('100%')
```
native 侧用 `OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &nativeWindow)` 拿到 `OHNativeWindow*` 交给解码器。参考 [XComponent 自定义渲染](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/ui/napi-xcomponent-guidelines.md)。

### 2.5 传输：ArkTS TCP 客户端（够用，但没 TCP_NODELAY）

```ts
import { socket } from '@kit.NetworkKit';

let tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
await tcp.bind({ address: '0.0.0.0', port: 0, family: 1 });
await tcp.connect({ address: { address: '192.168.1.x', family: 1 }, port: 9000,
                    timeout: 6000 });
tcp.on('message', (info: socket.SocketMessageInfo) => {
  const buf = info.message;                    // ArrayBuffer，喂给 NAPI 解码
  nativeDecoder.push(buf);
});
await tcp.setExtraOptions({ socketTimeout: 0, keepAlive: true, reuseAddress: true });
await tcp.send({ data: inputPacket });         // 回传触摸/键盘
```
`TCPExtraOptions` 只有 `keepAlive / reuseAddress / socketTimeout / bufferSize` 等，**没有 `tcpNoDelay`**（无 `TCP_NODELAY` 开关）→ 小包输入回传可能被 Nagle 合并，敏感的话输入通道用 C socket 自己设 `TCP_NODELAY`。文档：[js-apis-socket.md](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-network-kit/js-apis-socket.md)

### 2.6 纯 ArkTS 备选（备用方案，延迟未验证）

`AVPlayer` + 自实现数据源 `MediaSource` / `MediaSourceLoadingRequest`（API 12+，`SetMediaSource` 可从 socket 喂数据），由系统 demux+解码+送 XComponent。优点：纯 ArkTS、工作量小；缺点：播放器有缓冲策略，延迟通常 200ms~1s，且无法精细控制。**[不确定]** 是否满足"最低延迟"要求，建议只作 POC 兜底。

---

## 3. 已有开源项目（能否复用）

| 项目 | 地址 / 许可 | 采集方式 | 输入注入 | 可否复用 |
|---|---|---|---|---|
| **鸿镜 ohos-scrcpy-app** | [github.com/guoxiucai/ohos-scrcpy-app](https://github.com/guoxiucai/ohos-scrcpy-app) · **MIT** | `OH_AVScreenCapture` + H.264 VideoEncoder(Surface)，H.264 失败降级 JPEG | `INJECT_INPUT_EVENT` | 架构/协议/Flutter 解码端（VideoToolbox/MediaFoundation）**可参考**；设备端需 **Full SDK + 系统签名 + ACL**（`CAPTURE_SCREEN`/`EXEMPT_CAPTURE_SCREEN_AUTHORIZE`/`INJECT_INPUT_EVENT`）→ **不能直接装到零售机** |
| **HOScrcpy** | [gitcode.com/OpenHarmonyToolkitsPlaza/HOScrcpy](https://gitcode.com/OpenHarmonyToolkitsPlaza/HOScrcpy) | 华为官方工具集，Java SDK + 设备端 agent（hdc 通道），"帧率基本持平真机" | 有 | 设备端 `hosScrcpy jar` **华为版权、无再分发授权**；仅个人研究 |
| **hnscrcpy** | [github.com/taxiao213/hnscrcpy](https://github.com/taxiao213/hnscrcpy) · 自有代码 Apache-2.0，**内置 hosScrcpy jar 归华为** | 消费 HOScrcpy 的 H.264 流（gRPC over `hdc fport`） | 触摸/键鼠/中文注入 | 客户端实现（JavaFX+FFmpeg）**可参考**；明确"禁止商用" |
| **OpenHarmony_Scrcpy (OHScrcpy)** | [gitcode.com/luodh0157/OpenHarmony_Scrcpy](https://gitcode.com/luodh0157/OpenHarmony_Scrcpy) | 设备端 C-API 服务 + Python 客户端 | 点击/滑动/按键 | 需 **root 版本**设备 + 系统权限 → 不可用 |
| **dsh-hos-scrcpy** | [github.com/ns-zzj/dsh-hos-scrcpy](https://github.com/ns-zzj/dsh-hos-scrcpy) | 纯 hdc（`fport`/`snapshot`/`uitest`） | 鼠标点按/文字注入 | "零售设备可用、不需 root"的 hdc 方案参考 |
| **DevEco Testing 投屏通道** | 论坛实证：[链接](https://developer.huawei.com.cn/consumer/cn/forum/topic/0201223813276681052) | `uitest` 进程内 `xdevice_scrcpy`，**创建虚拟镜像屏 displayId=1004** | 有 | 非公开 API，**不可依赖** |

**关键判断**：没有任何项目提供"普通签名三方 HAP 作为显示客户端"的完整可复用代码——因为"显示客户端"本身不需要任何系统权限（解码 + XComponent + socket 全是公开 API），真正需要自己写的就是 **NAPI 解码层**；而"采集推流"端的所有现成实现都依赖系统权限或 hdc/uitest 通道。

**hdc 兜底能力（已实测/文档明确）**
- `hdc shell snapshot_display -f /data/local/tmp/x.jpeg` → **实测 1.6fps**，只能截图
- `hdc shell uitest uiInput click 100 100 / doubleClick / longClick / text "xxx"`，uitest **7.0.0.1** 起支持"指定屏幕注入"（设备侧正是 7.0.0.1）——反向控制可用，适合调试，不适合产品
- `hdc fport tcp:<PC端口> tcp:<设备端口>`（正向）、`hdc rport`（反向）：把设备端口映射到 Mac，HOScrcpy 系列都靠这个

---

## 4. macOS 构建 / 签名 / 部署链路

### 4.1 工具链

- DevEco Studio 7（对应 API 26）。macOS 要求：**macOS(ARM) 12/13/14/15/26**（x86 11+），内存 16GB+，磁盘 100GB+。
  下载/安装：[官方文档](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-software-install)，下载页 [developer.huawei.com/consumer/cn/deveco-studio](https://developer.huawei.com/consumer/cn/deveco-studio/)
- 从 6.0.0(20) 起 DevEco 已预置对应 HarmonyOS SDK，装完即可编译。
- SDK/工具路径（macOS）：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`、`.../tools/hvigor/bin/hvigorw.js`、`.../tools/node/bin/node`、`.../jbr`(JAVA_HOME)
- **命令行构建（不打开 IDE，hongjing README 实测可用）**：

```bash
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk

/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  clean --mode module -p product=default assembleHap \
  --analyze=normal --parallel --incremental --daemon

# 产物：entry/build/default/outputs/default/entry-default-signed.hap（或 -unsigned.hap）
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.your.bundle
```
参考：[hvigorw 命令行](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-hvigor-commandline)、[命令行构建流水线](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hmos-command-line-building-app)

### 4.2 hdc 命令清单（本项目够用）

```bash
hdc -v                                  # 3.2.0f（本机实测）
hdc list targets [-v]                   # 设备列表；本机实测返回 <tablet-ip>:36659
hdc tconn <tablet-ip>:36659           # 连无线调试；断开加 -remove
hdc -t <tablet-ip>:36659 shell "..."  # 指定设备执行
hdc install [-r] x.hap                  # 安装（-r 覆盖）
hdc uninstall com.your.bundle
hdc file send <local> <device>          # 推文件
hdc file recv <device> <local>          # 拉文件
hdc fport tcp:1234 tcp:53535            # 正向：Mac:1234 -> 设备:53535
hdc rport tcp:9000 tcp:9000             # 反向：设备:9000 -> Mac:9000
hdc fport ls / fport rm tcp:1234
hdc shell aa start -a EntryAbility -b com.your.bundle
hdc shell bm dump -a | bm dump -n <bundle>
hdc shell param get const.ohos.apiversion                 # 设备 API 级别（实测 26）
hdc shell param get const.product.software.version        # 系统版本串
hdc shell snapshot_display -f /data/local/tmp/x.jpeg      # 截屏
hdc shell uitest uiInput click 100 100                    # 注入点击
```
文档：[hdc 使用指导](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/dfx/hdc.md)、[hdc 命令列表](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V3/ide-command-line-hdc-0000001237908229-V3)、API 版本查询 [FAQ](https://developer.huawei.com/consumer/cn/doc/harmonyOS-Faqs/faqs-app-debugging-22)

### 4.3 签名：无华为账号到底行不行？（**本报告最大不确定项**）

事实：
1. DevEco「自动签名」= 登录华为账号 → 自动生成 `.p12/.cer/.p7b` 到 `~/.ohos/config/`，并写入 `build-profile.json5` 的 `signingConfigs`。**必须华为账号**（免费个人账号 + 实名）。
2. 手动签名（`hap-sign-tool.jar`，SDK 自带 `sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar`）能生成/校验材料，但 **debug Profile 必须由 AGC 按账号签发**（含设备 UDID、bundleName 绑定）→ 仍然要账号。
3. 无账号的绕道：
   - **未签名 HAP 直接装**：证据冲突
     - 支持：`hdc install entry-default-unsigned.hap` 在 **API 26 真机"通常可装"（HMOS-17/18/22 多轮实测）**，失败报 `no signature file`(9568320) —— [hap-signing-cli.md](https://raw.gitcode.com/Garvis/ohos_qt-skills/raw/main/procedural/hap-signing-cli.md)
     - 反对：早期结论是"未签名 hap 在鸿蒙真机无法直接安装，安装服务会校验签名" —— [掘金](https://juejin.cn/post/7705974459644559414)、[bm 工具错误码 9568320](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/tools/bm-tool.md)
   - 模拟器可以拖拽装未签名包，但模拟器≠真机。
   - OpenHarmony 开源仓库里的默认调试证书**不被 HarmonyOS 零售机的信任链接受**。
4. 结论：**[不确定]**。建议实测顺序：① 先构建 unsigned HAP，`hdc install` 试装；② 失败则注册免费华为账号走 DevEco 自动签名；③ 再不行才考虑企业/受邀路径。预期 ①②之间就能解决，成本 = 一个实名华为账号（免费）。
5. 工程配置注意：API 26 的 `compatibleSdkVersion` 必须写 `"26.0.0"` 三段式；`targetSdkVersion >= 26.0.0` 会触发 HarmonyOS 7 的新行为变更（如"沉浸光感"生效约束）。

### 4.4 `module.json5` 权限声明（本方案需要的）

```json5
{
  "module": {
    "requestPermissions": [
      { "name": "ohos.permission.INTERNET" },
      { "name": "ohos.permission.GET_WIFI_INFO" },
      { "name": "ohos.permission.KEEP_BACKGROUND_RUNNING" },
      // 加分项：屏幕采集（normal/user_grant，运行时弹窗）
      { "name": "ohos.permission.CUSTOM_SCREEN_CAPTURE",
        "reason": "$string:reason_capture", "usedScene": { "abilities": ["EntryAbility"], "when": "inuse" } },
      { "name": "ohos.permission.MICROPHONE" }   // 仅在需要麦克风时
      // 下面这些三方签名拿不到，别声明：
      // ohos.permission.CAPTURE_SCREEN (system_core)
      // ohos.permission.INJECT_INPUT_EVENT / ACCESS_VIRTUAL_SCREEN / EXEMPT_* (受限)
    ]
  }
}
```
运行时申请：`abilityAccessCtrl.createAtManager().requestPermissionsFromUser(ctx, ['ohos.permission.CUSTOM_SCREEN_CAPTURE'])`。
参考：[申请受限权限/ACL](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/declare-permissions-in-acl.md)、[DevEco 签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing)

---

## 5. HarmonyOS 7.0 具体差异与「扩展屏」现实

- **API 26 = HarmonyOS 7.0**；26.0.0 Release、26.0.1 增量 Beta；版本号自 API 26 起改为 SemVer（[说明](https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/version-number-26)）。
- ArkUI：API 26 新增一批**状态管理 V2 组件**（ChipV2/ChipGroupV2/CounterV2/PopupV2/SwipeRefresherV2/TreeViewV2），V1→V2 可渐进迁移（[介绍](https://bbs.huaweicloud.com/blogs/524387)）；折叠屏/平板/PC 断点体系重构（可自定义 xl/xxl 断点）。
- 行为变更：`targetSdkVersion >= 26.0.0` 才生效的变更（如"沉浸光感新增生效约束"），升级 targetSdk 要预留适配窗口。
- 多媒体相关：`AVScreenCaptureRecorder` 在 26.0.0 新增 `pauseRecording/resumeRecording`；采集侧 `OH_MultiDisplayCapability` API 24、`CaptureStrategy` API 20、`TIMEOUT_SCREENOFF_DISABLE_LOCK`/`CUSTOM_SCREEN_RECORDING` API 22（仅 PC/2in1）。
- **「屏幕扩展 / 有线外接显示」**：
  - 系统级"电脑模式/桌面模式"由系统桌面进程提供，**不开放给三方应用**；USB 视频输出/DP Alt Mode 属系统底层，**没有开放给普通 HAP 的 ArkTS API**。
  - 官方给三方的替代方案是 **AVSession 扩展屏投播**：先由**系统**发起有线/无线投屏，应用再用 `getAllCastDisplays()` 拿到可用屏幕，然后 `startAbility({...}, { displayId })` 把自己的另一个 UIAbility 显示到大屏（`ExtendedScreenCasting` 官方样例）。
  - 对我们的场景：**Mac 是"扩展屏主机"、平板是客户端**，与 HarmonyOS 的投屏方向相反，因此不受上述限制 —— 我们只需要"全屏显示一路视频 + 收触摸"，全是公开能力。
  - 参考：[USB 外接显示器桌面模式问答](https://developer.huawei.com.cn/consumer/cn/forum/topic/0204227283015656135)、[扩展屏投播样例](https://gitcode.com/openharmony/applications_app_samples/tree/master/code/DocsSample/Media/AVSession/ExtendedScreenCasting)

---

## 6. 触摸 / 键盘事件捕获（全屏 App）

ArkUI 通用事件（都是公开、无权限）：

| 需求 | API | 说明 |
|---|---|---|
| 触摸 | `.onTouch((e: TouchEvent) => {})` | `e.type`: `TouchType.Down/Move/Up/Cancel`；`e.touches[]`（器件刷新率全量点）、`e.changedTouches[]`（按屏幕刷新率重采样）；`e.getHistoricalPoints()` **API 10+** 取同帧历史点（做高精度笔迹/拖拽很有用） |
| 鼠标/触控板 | `.onMouse()` / `.onHover()` / `.onAxisEvent()`（滚轮） | 平板接鼠标时可用 |
| 键盘 | `.onKeyEvent((e: KeyEvent) => {})` | `e.type`: `KeyType.Down/Up`；`e.keyCode`（见 `KeyCode` 枚举）；`.onKeyEventDispatch()` API 15+ 可先拦截；`.keyboardShortcut()` 做组合键 |
| 修饰键 | `e.getModifierKeyState(['Ctrl','Shift','Alt'])` **API 12+** | 回传 Mac 的 ⌘/⇧/⌥ 组合 |
| 组件需获焦 | `.focusable(true)` / `.defaultFocus(true)` | 键盘事件只在获焦组件上触发；文本输入用 `TextInput` + 系统输入法 |

全屏沉浸 + 常亮：

```ts
import { window } from '@kit.ArkUI';

const win = await window.getLastWindow(getContext(this));
await win.setWindowLayoutFullScreen(true);                 // 布局延伸到状态栏/导航栏下
await win.setWindowSystemBarEnable([]);                    // 同时隐藏 status + navigation
await win.setSpecificSystemBarEnabled('navigation', false); // API 11+ 单独控制
await win.setWindowKeepScreenOn(true);                     // 投屏期间常亮（关键）
win.setWindowSystemBarProperties({ navigationBarColor: '#000000', statusBarColor: '#000000' });
```
文档：[Window API](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkts-apis-window-Window.md)（`setWindowLayoutFullScreen` 9+ / `setWindowSystemBarEnable` 9+ / `setWindowKeepScreenOn` 9+）、[触摸事件](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-events-touch.md)、[按键事件](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-events-key.md)

**坑**：
- 返回/上滑 Home 等**系统手势普通应用拦不住**（全局手势优先），全屏投屏必须留可见的"退出"入口，否则用户退不出。
- 2800×1840 (3:2) ↔ Mac 常见 16:10/16:9：要做**等比 letterbox + 坐标反变换**，并把 Mac 端逻辑分辨率、缩放、Retina 因子一起传过来。
- 键盘输入：若目标是"把平板的物理键盘/软键盘输入回传 Mac"，`onKeyEvent` 能拿按键，但**中文等 IME 组合输入**拿不到可靠字符流；HOScrcpy/hnscrcpy 的做法是专门开一条"文本注入"通道（客户端发 UTF-8 整段文本），建议照抄这个设计。

---

## 7. 建议架构（据此可直接开工）

```
[macOS host]                                    [MatePad 11.5"S / HarmonyOS 7 (API 26)]
 ScreenCaptureKit 抓屏                            ArkTS UIAbility (全屏沉浸 + 常亮)
   └ VideoToolbox H.264 硬编 (低延迟, 无B帧)        ├ XComponent(SURFACE) ← surfaceId
   └ TCP :9000  (长度前缀帧, 关键帧可请求)   ──►   ├ NAPI (C++) OH_VideoDecoder (LOW_LATENCY=1)
                                                   ├ ArkTS TCPSocket 收流/发输入
   ◄── 触摸/键盘/滚轮 (JSON 或二进制)  ────────────  └ onTouch/onKeyEvent 采集 → 发送
```
- 采集/推流（加分项）：`OH_AVScreenCapture_StartScreenCaptureWithSurface` → `OH_VideoEncoder`(Surface, AVC) → TCP 推给 Mac。**先验证第 4 节的权限/签名风险再投入**。
- 若不想写 C++：先做 **AVPlayer + MediaSourceLoadingRequest** 的 POC 验证延迟（能接受再上），否则老老实实写 NAPI 解码器（约 300–600 行 C++）。

**冒烟验证清单（按顺序，1 天内可跑完）**
1. `hdc shell param get const.ohos.apiversion` → 应为 26（已确认）
2. 建空工程 + `hvigorw assembleHap` 出 unsigned HAP → `hdc install` 试装（判定签名路线）
3. 全屏沉浸 + XComponent + TCP 收 1 帧 H.264 → 验证解码链路与 surface 送显
4. 写最小 NAPI 调 `OH_AVScreenCapture_Create/Init/StartScreenCapture(dataType=OH_ORIGINAL_STREAM)`，看是否弹窗、是否返回 `AV_SCREEN_CAPTURE_ERR_OPERATE_NOT_PERMIT`（**一次实验就能定性采集可行性**）
5. 再试 `OH_AVScreenCapture_StartScreenCaptureWithSurface`（零拷贝编码）

---

## 8. 关键结论 / 风险清单

**已确认（可直接依赖）**
1. 设备是 **HarmonyOS 7.0.0.111 / API 26**，tablet，2800×1840，144Hz；`uitest 7.0.0.1`、`snapshot_display`、`bm/aa` 齐全 [已实测]。
2. **三方应用做"显示客户端"没有任何权限障碍**：TCP socket、XComponent、H.264 硬解都是公开 API。
3. **ArkTS 层没有 VideoDecoder/Encoder** → 低延迟硬解必须 NAPI C++（`OH_VideoDecoder` + `OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY`）。这是本项目最大工作量。
4. **全屏采集对三方"部分可用"**：`CUSTOM_SCREEN_CAPTURE` 是 normal/user_grant（Tablet 支持，API 14+），可拿单帧全屏 PixelMap；`CAPTURE_SCREEN` 是 system_core，三方拿不到。
5. **虚拟屏（第二屏）三方不可用**：`ACCESS_VIRTUAL_SCREEN` 属受限权限（仅车机场景）。但我们的方向不需要它。
6. **hdc 截图兜底不可行**：`snapshot_display` 实测 0.61–0.65s/帧 ≈ **1.6fps**。
7. **签名**：自动签名要华为账号（免费）；**unsigned HAP 在 API 26 真机可能可装**（一手实测报告说"通常可装"，另一派说零售机必须签名）—— **[不确定]，第一优先实测**。
8. **无 ArkTS 采集原始帧的公开接口**：`AVScreenCaptureRecorder` 只能写 MP4；要码流必须 C API（`OH_ORIGINAL_STREAM` / `StartScreenCaptureWithSurface`）。

**风险 / 未决**
- 🔴 **R1 [不确定] 三方能否拿到 AVScreenCapture 原始码流**：头文件未标权限，但 `CAPTURE_SCREEN`(system_core) 的存在 + 所有系统级项目都要 ACL，暗示有隐藏门槛。必须做 §7-4 的一次性实验；若返回 `OPERATE_NOT_PERMIT/201`，加分项只能退化为"低帧率截屏轮询"（`CaptureScreenPixelmap`，估计 5–15fps）。
- 🔴 **R2 unsigned 安装是否可行**：证据冲突。失败码 `no signature file (9568320)` → 转华为账号自动签名。
- 🟠 **R3 延迟预算**：Wi-Fi 传输 5–20ms + 解码 8–20ms + 送显 1–2 帧(60Hz≈16–33ms)，端到端现实目标 **40–80ms**；144Hz 屏不受益（编码/解码常见上限 60fps，`SetMaxVideoFrameRate` 硬顶 60）。
- 🟠 **R4 触摸手感**：输入回传走 TCP 无 `TCP_NODELAY`（ArkTS socket 不暴露），小包可能被 Nagle 合并 → 建议输入通道用原生 socket 设 `TCP_NODELAY`，或输入/视频分离双通道。
- 🟠 **R5 隐私弹窗打断**：采集开始必有系统隐私弹窗/Picker，用户可随时 `CANCELED`/`STOPPED_BY_USER`；"沉浸式投屏"必须处理这些状态（否则黑屏无提示）。
- 🟡 **R6 键盘/中文输入**：`onKeyEvent` 拿不到 IME 组合串，需单独"文本注入"通道（参考 hnscrcpy 设计）。
- 🟡 **R7 系统手势**：返回/Home 手势拦截不了，全屏必须有显式退出 UI。
- 🟡 **R8 版本号/配置格式**：API 26 起 `compatibleSdkVersion: "26.0.0"` 三段式；`targetSdkVersion>=26.0.0` 触发新行为变更。
- 🟡 **R9 许可证**：HOScrcpy 的 `hosScrcpy jar` 为华为版权、**无再分发授权**（hnscrcpy 明确"禁止商用"）；鸿镜是 MIT 但设备端强依赖系统签名。自研时不要直接内置这些二进制。

---

## 9. 参考链接汇总

**官方文档（OpenHarmony 文档仓，API 26 线，可直接 raw 拉取）**
- AVScreenCaptureRecorder（ArkTS）：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-media-kit/arkts-apis-media-AVScreenCaptureRecorder.md
- AVScreenCapture C 基础流程：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/media/media/avscreencapture-c-basic-process.md
- AVScreenCapture 自定义场景：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/media/media/avscreencapture-c-custom-scenarios.md
- AVScreenCapture C 头文件（全部接口）：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-media-kit/capi-native-avscreen-capture-h.md
- 截屏 C API（CaptureScreenPixelmap）：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/capi-oh-display-capture-h.md
- display（虚拟屏/VirtualScreenConfig）：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/js-apis-display.md
- 视频解码（低时延键值）：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/media/avcodec/video-decoding.md
- 视频编码（Surface 模式）：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/media/avcodec/video-encoding.md
- XComponent 自定义渲染：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/ui/napi-xcomponent-guidelines.md
- ArkTS Socket：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-network-kit/js-apis-socket.md
- 触摸事件：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-events-touch.md
- 按键事件：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-events-key.md
- Window（全屏/常亮）：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkts-apis-window-Window.md
- hdc 使用指导：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/dfx/hdc.md
- 权限清单（三方 user_grant）：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/permissions-for-all-user.md
- 权限清单（系统应用）：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/permissions-for-system-apps.md
- 受限开放权限：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/restricted-permissions.md
- ACL 申请：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/declare-permissions-in-acl.md

**华为开发者站（JS 渲染页，需浏览器打开）**
- AVScreenCapture 录屏写文件（C/C++）：https://developer.huawei.com/consumer/cn/doc/harmonyOS-guides/using-avscreencapture-for-file
- 窗口级录屏（C/C++）：https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/using-avscreencapture-for-file-with-window
- 视频解码指南：https://developer.huawei.com/consumer/cn/doc/harmonyOS-guides/video-decoding
- DevEco Studio 下载安装：https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-software-install
- DevEco 命令行构建：https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hmos-command-line-building-app
- DevEco 签名：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing
- hvigorw 命令行：https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-hvigor-commandline
- DevEco 截屏（snapshot_display）：https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hmos-screenshot
- API 版本查询 FAQ：https://developer.huawei.com/consumer/cn/doc/harmonyOS-Faqs/faqs-app-debugging-22
- 系统录屏授权回调：https://developer.huawei.com/consumer/cn/doc/architecture-guides/common-v1_26-ts_390-0000002506427360
- HarmonyOS 7 发布说明：https://developer.huawei.com.cn/consumer/cn/notice/detail/?id=9002210958618976001
- 版本号格式调整：https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/version-number-26

**社区 / 实证**
- API 26 语义化版本与升级坑：https://developer.huawei.com/consumer/cn/blog/topic/03229256051709189
- API 26 六个 V2 组件：https://bbs.huaweicloud.com/blogs/524387
- HarmonyOS 7 支持机型名单：https://m.163.com/dy/article/LB574GNQ0511B8LM.html
- MatePad 11.5"S 规格：https://consumer.huawei.com/es/tablets/matepad-11-5-s/specs/
- USB 外接显示器/桌面模式（三方边界）：https://developer.huawei.com.cn/consumer/cn/forum/topic/0204227283015656135
- DevEco Testing 投屏走 uitest/xdevice_scrcpy、displayId=1004：https://developer.huawei.com.cn/consumer/cn/forum/topic/0201223813276681052
- 未签名 HAP 安装实测（API 26 可装说法）：https://raw.gitcode.com/Garvis/ohos_qt-skills/raw/main/procedural/hap-signing-cli.md
- 未签名 HAP 不可装说法：https://juejin.cn/post/7705974459644559414
- bm 工具 9568320：https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/tools/bm-tool.md

**开源项目**
- 鸿镜 ohos-scrcpy-app（MIT）：https://github.com/guoxiucai/ohos-scrcpy-app
- HOScrcpy（华为官方工具集）：https://gitcode.com/OpenHarmonyToolkitsPlaza/HOScrcpy
- hnscrcpy（Apache-2.0 自有代码）：https://github.com/taxiao213/hnscrcpy
- OpenHarmony_Scrcpy：https://gitcode.com/luodh0157/OpenHarmony_Scrcpy
- dsh-hos-scrcpy：https://github.com/ns-zzj/dsh-hos-scrcpy
- 扩展屏投播样例：https://gitcode.com/openharmony/applications_app_samples/tree/master/code/DocsSample/Media/AVSession/ExtendedScreenCasting
- uitest（uiInput 注入，7.0.0.1 多屏注入）：https://gitcode.com/openharmony/testfwk_arkxtest
