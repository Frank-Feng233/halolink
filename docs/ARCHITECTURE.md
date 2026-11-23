# HaloLink 架构设计

## 1. 总览

```
┌─────────────────────────── macOS host（HaloLink.app / halolink-host）───────────────────────────┐
│                                                                                                │
│  CGVirtualDisplay（私有 API）                 ScreenCaptureKit              VideoToolbox       │
│  ┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐   ┌────────────────┐ │
│  │ 虚拟显示器 2800×1840│──▶│ SCStream 采集(60fps)│──▶│ CVPixelBuffer NV12 │──▶│ H.264 硬编     │ │
│  │ 摆在主屏右侧       │   │ 按 displayID 精确采集│   │ 零拷贝            │   │ 无B帧/实时模式 │ │
│  └────────────────────┘   └────────────────────┘   └────────────────────┘   └───────┬────────┘ │
│                                                                                    │ Annex-B  │
│  ┌────────────────────┐    ┌──────────────────────────────────────────────┐        │ 帧分片    │
│  │ CGEvent 注入        │◀───│ 输入事件解析（touch/scroll/key/text）          │        │          │
│  │ .cghidEventTap     │    └──────────────────────────────────────────────┘        │          │
│  └────────────────────┘                     ▲                                     ▼          │
│                                             │                          ┌──────────────────┐   │
│  HTTP :8080 Web 备用（MJPEG + POST /input）─┘                          │ TCP 客户端        │   │
│                                                                        └────────┬─────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┼─────────────┘
                                                                                  │ HLDP v1
                                                    ┌─────────────────────────────▼─────────────┐
                                                    │ HarmonyOS App（com.halolink.display）       │
                                                    │  TCPSocketServer :9528（监听 0.0.0.0）      │
                                                    │   └─ NAPI C++ OH_VideoDecoder（Surface 零拷贝 + LOW_LATENCY）│
                                                    │   └─ XComponent(SURFACE) 全屏渲染            │
                                                    │   └─ onTouch / onKeyEvent → CONTROL 帧回传    │
                                                    └────────────────────────────────────────────┘
```

## 2. 数据通道（详见 `specs/PROTOCOL.md`）

- **平板是 TCP 服务端**，监听 `0.0.0.0:9528`；Mac 是客户端。这样有线（USB+hdc fport）与无线（同 Wi-Fi 直连）共用同一套逻辑。
- 握手：JSON 行（hello / config / ready）→ 二进制帧：`type(1B) + len(4B BE) + payload`。
  - `0x01` VIDEO：H.264 Annex-B access unit（每个 IDR 前重复 SPS/PPS）
  - `0x02` CONTROL：JSON（touch/scroll/key/text/stats/request_keyframe）
  - `0x03/0x04` PING/PONG
- 平板端坐标归一化 0..1，Mac 端换算到虚拟显示器全局坐标后注入 CGEvent。

## 3. macOS 端关键实现

| 模块 | 实现 | 关键点 |
|---|---|---|
| 虚拟显示器 | 私有 `CGVirtualDisplay*` 类（Objective-C 运行时代码） | 声明「物理锚点模式 + HiDPI 逻辑模式」；`sizeInMillimeters` 面积 ≥200cm²；`CGConfigureDisplayOrigin` 摆到主屏右侧并取消镜像；保持主屏仍是主屏 |
| 采集 | ScreenCaptureKit `SCStream` | 按 `displayID` 过滤；NV12 像素格式（VT 直吃）；`minimumFrameInterval` 控制帧率；SCK 是变化驱动，新客户端接入时强制 IDR |
| 编码 | VideoToolbox `VTCompressionSession` | RealTime、禁 B 帧、1s GOP、H.264 Main、显式 Rec.709 色彩；AVCC→Annex-B，IDR 前附 SPS/PPS |
| 传输 | Network.framework `NWConnection` | `noDelay=true` 关 Nagle；断线自动重连指数退避 |
| 注入 | CoreGraphics `CGEvent.post(.cghidEventTap)` | 鼠标移动/按下/抬起/拖拽、滚轮、Unicode 文本、特殊键；需辅助功能权限 |
| Web 备用 | 内置 HTTP 服务器（Network.framework） | `/` 全屏页面、`/mjpg` MJPEG、`POST /input` 触控、`/status`、`/healthz` |
| TCC | 屏幕录制 + 辅助功能 | 必须以 `.app` 运行（macOS 26+ 裸二进制不出现于权限列表）；建议稳定自签证书避免重建后重复授权 |

## 4. HarmonyOS 端关键实现

| 模块 | 实现 | 关键点 |
|---|---|---|
| UIAbility | Stage 模型 + 全屏沉浸 | `setWindowLayoutFullScreen(true)`、`setWindowSystemBarEnable([])`、`setWindowKeepScreenOn(true)`、横屏 orientation；浮动退出按钮（系统手势拦不住） |
| 网络 | `@ohos.net.socket` `TCPSocketServer` | 监听 9528；JSON 行握手 + 二进制帧解析；心跳；发送 touch/key 控制帧 |
| 解码 | NAPI C++ `OH_VideoDecoder` | Surface 模式（`SetSurface` 必须在 `Prepare` 前）；`OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY=1`；固定 `OH_MD_KEY_VIDEO_SET_BUFFER_GEOMETRY`（避免 1080p 底部马赛克）；`RenderOutputBuffer` 送显 |
| 渲染 | `XComponent(SURFACE)` | `getXComponentSurfaceId()` → `OH_NativeWindow_CreateNativeWindowFromSurfaceId` → 解码器输出 Surface，零拷贝 |
| 交互 | `onTouch` / `onKeyEvent` | 归一化坐标回传；文本走独立 `text` 通道（IME 组合串拿不到） |
| 降级 | ArkWeb `Web` 组件 | 解码失败时打开 Mac 的 `http://<mac-ip>:8080/` Web 客户端 |

## 5. 权限清单

**macOS**（系统设置 → 隐私与安全性）：

- 屏幕录制（ScreenCaptureKit 采集，必需）
- 辅助功能（CGEvent 注入，必需）
- 本地网络（NWListener 监听，Wi-Fi 模式首次会弹窗）

**HarmonyOS**（`module.json5`）：

- `ohos.permission.INTERNET`（必需）
- `ohos.permission.GET_WIFI_INFO`（可选，显示 IP）
- `ohos.permission.KEEP_BACKGROUND_RUNNING`（可选）
- 不需要任何屏幕采集 / 输入注入 / 虚拟屏等受限系统权限（本方向不需要）

## 6. 连接模式

| 模式 | 平板端 | Mac 端 | 现场 |
|---|---|---|---|
| 无线直连 | App 监听 `0.0.0.0:9528` | `halolink-host --connect <平板IP>:9528` | `scripts/run_wireless.sh` |
| 无线调试 hdc 转发 | App 监听（同上，含 loopback） | `hdc fport tcp:9528 tcp:9528` → `--connect 127.0.0.1:9528` | 适用于跨网段/不想暴露端口 |
| USB 有线 | 同上 | 同上（hdc over USB） | `scripts/run_usb.sh`；USB 同时供电 |
| Web 免安装 | 平板浏览器 | Host 内置 HTTP :8080 | `scripts/run_web.sh` |

## 7. 失败与降级策略

1. 虚拟屏创建失败 → 提示原因；可 `--display-mode mirror` 退化为镜像主屏（仍可用，但非扩展）。
2. 屏幕录制/辅助功能未授权 → 明确提示并打开对应系统设置面板。
3. 原生解码初始化失败（平板端）→ 显示错误 + 「打开 Web 模式」按钮。
4. HAP 无法安装（签名受限）→ 使用 Web 免安装模式（功能可用）。
5. 断连 → 平板保持监听，Mac 自动重连；重连后强制 IDR，避免花屏。
