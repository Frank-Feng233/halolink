# HaloLink Display Protocol (HLDP v1)

扩展屏数据通道协议。**平板端是 TCP 服务端，Mac 端是 TCP 客户端。**
这样有线（USB + hdc fport）和无线（同一 Wi-Fi 直连）共用同一套逻辑：Mac 只需要一个可连接的 `host:port`。

```
┌────────────────────┐        TCP (Wi-Fi / hdc fport over USB or 无线调试)        ┌────────────────────┐
│ macOS host (client)│  ── video: H.264 Annex-B, framed ──────────────────────▶ │ HarmonyOS app (srv)│
│ 虚拟显示器+采集+编码 │  ◀── input: touch/key/scroll, framed JSON ────────────── │ 解码+全屏渲染+触摸  │
└────────────────────┘                                                          └────────────────────┘
```

## 1. 传输

- TCP，默认端口 **9528**（平板端监听 `0.0.0.0:9528`）。
- 连接建立后先做一次 **UTF-8 JSON 行握手**（以 `\n` 结尾），然后进入 **二进制帧模式**。
- 二进制帧 = `1 byte type` + `4 byte big-endian payload length` + `payload`。
  - `0x01` VIDEO：payload 为一个 H.264 access unit（Annex-B，4 字节起始码）。
  - `0x02` CONTROL：payload 为 UTF-8 JSON。
  - `0x03` PING：无 payload，Mac→平板。
  - `0x04` PONG：无 payload，平板→Mac。
- 单帧上限 16 MiB，超过视为协议错误并断开。

## 2. 握手

1. 平板（服务端）接受连接后立即发送一行：

```json
{"type":"hello","protocol":"halolink/1","device":"HUAWEI MatePad 11.5\"S","model":"TGR-W10",
 "screen":{"width":1840,"height":2800,"density":2.25,"refreshRate":144},
 "features":["touch","keyboard","h264"],"appVersion":"0.1.0"}
```

2. Mac 端回复一行（虚拟显示器已经按这个尺寸创建好，见 `width/height`）：

```json
{"type":"config","codec":"h264","width":2800,"height":1840,"fps":60,
 "bitrate":24000000,"profile":"high","keyframeInterval":2,"scaleMode":"fit"}
```

3. 平板端回复：

```json
{"type":"ready"}
```

4. Mac 端在收到 `ready` 后立刻发送 SPS/PPS（作为第一个 VIDEO 帧的 Annex-B 前缀，同时每个 IDR 前重复 SPS/PPS），随后持续推送视频帧。

握手阶段超时 10s。

## 3. 视频帧（Mac → 平板）

- 编码：H.264 High profile，`kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder`，禁用 B 帧（`AllowFrameReordering=false`），实时模式。
- 每个 access unit 前加 4 字节起始码 `00 00 00 01`；每个 IDR 前重复 SPS/PPS。
- 平板端需要能容忍：一个 VIDEO 帧里包含多个 NALU（SPS+PPS+IDR）。
- 平板端发现解码失败/花屏可重新发起 `{"type":"request_keyframe"}`（CONTROL 帧）。

## 4. 控制帧（平板 → Mac）

全部为 `0x02 CONTROL` 帧，payload 为单行 JSON：

```json
{"type":"touch","action":"down","x":0.5,"y":0.25,"pointerId":0}
{"type":"touch","action":"move","x":0.51,"y":0.26,"pointerId":0}
{"type":"touch","action":"up","x":0.51,"y":0.26,"pointerId":0}
{"type":"scroll","dx":0.0,"dy":-12.0}
{"type":"key","action":"down","key":"BACKSPACE"}      // 特殊键
{"type":"text","text":"hello"}                          // 文本输入
{"type":"stats","rxFps":60,"decodeMs":3.2,"rttMs":8}
{"type":"request_keyframe"}
{"type":"bye"}
```

坐标 `x,y` 是相对**扩展屏区域**的归一化坐标（0..1，左上为原点），Mac 端换算成虚拟显示器像素坐标并注入 CGEvent。

## 5. 连接与模式

| 模式 | 平板端 | Mac 端 |
|---|---|---|
| 无线（同 Wi-Fi 直连） | App 监听 `0.0.0.0:9528`，界面显示本机 IP | `halolink-host --connect 192.168.x.x:9528` |
| 无线调试 / 有线（hdc fport） | App 监听 `127.0.0.1:9528` | `hdc fport tcp:9528 tcp:9528` 后 `halolink-host --connect 127.0.0.1:9528` |

Mac 端也支持 `--listen 0.0.0.0:9528` 反向模式（平板主动连 Mac），仅用于调试，默认不用。

## 6. HTTP 备用通道（无需安装 App）

Mac host 进程同时提供（默认 `:8080`）：

- `GET /`：全屏 Web 客户端（MJPEG + 触摸回传）
- `GET /mjpg`：`multipart/x-mixed-replace` MJPEG 流（可加 `?w=1600&q=0.6&fps=30`）
- `POST /input`：JSON 输入事件（同第 4 节格式）
- `GET /status`：`{"width":2800,"height":1840,"fps":60,"clients":1,"displayId":37}`
- `GET /healthz`：`ok`

平板浏览器打开 `http://<Mac-IP>:8080/` 即可把平板当扩展屏用；这是原生 App 安装受限时的兜底方案，也用于联调验证。

---

# 附：v1.1 扩展（竖屏 / Retina 一致 / 输入开关 / 旋转）

> 向后兼容 v1：旧客户端不解析新字段，host 按默认值处理。

## 7.1 hello 增加屏幕方向与旋转信息

```json
{"type":"hello","protocol":"halolink/1.1", ...,
 "screen":{"width":1840,"height":2800,"density":2.5,"refreshRate":144,
           "orientation":"portrait"}}
```

- `width/height` 为**当前显示方向**下的物理像素（竖屏时宽<高）。
- `orientation`：`landscape` / `portrait`。

## 7.2 config 增加显示缩放策略与 Retina 目标

```json
{"type":"config","codec":"h264","width":2800,"height":1848,"fps":60,
 "bitrate":24000000,"profile":"main","keyframeInterval":1,
 "scaleMode":"fit",            // fit=等比留黑边 | fill=等比填满(裁切)
 "retina":true,                // host 侧虚拟屏为 2x HiDPI
 "logicalWidth":1400,"logicalHeight":924,
 "inputEnabled":false}         // 触摸/键鼠回传总开关（默认 false）
```

## 7.3 平板 → Mac：显示变化（旋转/分辨率变化）

平板 UI 尺寸变化或旋转后发送：

```json
{"type":"display","width":1840,"height":2800,"orientation":"portrait","refreshRate":144}
```

host 收到后：

1. 若宽高比变化 >5%，重建/重配虚拟显示器（同一进程内，异步）并重建 encoder/capture；
2. 重新发送 `config`；
3. 平板收到新 config 后重建解码器 surface 并请求关键帧（`request_keyframe`）。

## 7.4 输入开关（v1.1 默认关闭）

- 平板设置里「触摸控制」（以及键盘/文字）默认 **关闭**；关闭时不发送任何 `touch/scroll/key/text` 控制帧。
- host 侧同时有 `--input off|on`（默认 off）：即使收到控制帧也忽略并打印一次提示。
- 平板可在发送的 `stats` 中带 `"input":false` 供 host 展示状态。

---

# 附：v1.2 扩展（虚拟屏两种模式：原生 1:1 / HiDPI 最大化）

> 需求来源：用户要求把"虚拟屏分辨率"语义改成两种明确模式，不再用"贴合 Mac / 贴合平板"的说法。

## 8.1 config 增加渲染模式

```json
{"type":"config", ...,
 "width":2800,"height":1840,          // 虚拟屏像素尺寸（本模式实际值）
 "logicalWidth":2800,"logicalHeight":1840,
 "renderMode":"pixel1to1",            // pixel1to1 | scale
 "scaleMode":"fit",                   // 仅 renderMode=scale 时有效：fit|fill
 "retina":false,                      // pixel1to1 时为 false（1x）；scale 时通常 true（2x）
 "inputEnabled":false}
```

- **`pixel1to1`（原生 1:1 像素模式）**：Mac 虚拟屏为平板原生分辨率（2800×1840，1x）。
  平板端必须 **逐像素 1:1 显示**：不缩放、不重采样；视频像素与屏幕像素相等时正好铺满；
  若因系统限制略大/略小，则**居中裁切/补边**（不拉伸）。此模式忽略 scaleMode。
- **`scale`（HiDPI 最大化模式）**：Mac 虚拟屏取平板分辨率下 macOS 支持的最大 2x HiDPI 模式
  （优先逻辑 1400×920 @2x = 2800×1840；若系统不支持该精确比例，则取面板内可用的最大 2x 模式，
  允许像素尺寸略微超出面板，由平板端按 scaleMode 裁切/缩放）。
  `scaleMode=fit` 完整显示；`fill` 裁剪填满。

## 8.2 平板端行为

1. 收到 config 后比较视频像素尺寸与屏幕物理尺寸：
   - `pixel1to1`：按 1:1 渲染，居中；超出部分裁切，不足补黑边。
   - `scale`：按 fit/fill 等比缩放。
2. 两种模式下都发送 `display` 帧上报自身屏幕；host 据此重新计算虚拟屏。
3. 设置面板显示当前模式、虚拟屏像素/逻辑分辨率、平板物理分辨率、有效显示区域。

---

# 附：v1.3 扩展（端到端延迟测量）

> 目标：把"感觉上的延迟"量化到每一段（采集/编码/传输/解码/送显），再针对性优化。

## 9.1 能力协商

- hello 新增 `features` 里包含 `"frameTs"` 表示平板支持帧时间戳。
- config 新增 `"frameTs": true`：host 开启后，每个 VIDEO（0x01）帧的 payload 变成：

```
[8 bytes 采集时间戳（Unix 微秒，大端）][Annex-B access unit]
```

- 旧 host 不带帧时间戳时，平板按原格式解析（hello features 不含 frameTs 则不启用）。
- 平板收到帧时解析出 `captureTsUs`，用于延迟统计。

## 9.2 平板 stats 增加延迟分解（REQUIRED for 优化验收）

```json
{"type":"stats","rxFps":60,"decodeMs":10.5,"rttMs":8.0,
 "recvMs":6.1,"decMs":9.8,"renderMs":3.4,"e2eMs":19.3,
 "presentHz":144,"input":false}
```

- `recvMs` = 收到该帧时刻 - captureTs（传输+排队延迟）
- `decMs` = 解码完成 - 收到
- `renderMs` = 送显完成 - 解码完成
- `e2eMs` = 送显完成 - captureTs（端到端）
- `presentHz` = 当前显示刷新率（用于判断送显等待）

## 9.3 优化要求

- **平板**：串流期间把 displaySync 期望/最大帧率提到设备支持的最高值（本机 144Hz），降低送显等待；确保解码器低时延配置、输出队列尽量浅、RenderOutputBuffer 立即调用；用 e2eMs 分解验证收益。
- **Mac host**：SCK queueDepth 降到 2；VideoToolbox 开低时延码控/优先编码速度属性（可用则开）；编码后立刻发送（不攒批）；TCP_NODELAY；统计 captureMs/encodeMs/sendMs 与传输 RTT（PING/PONG）。
- **传输**：测量 USB hdc fport 的 PING/PONG RTT（当前约 9–14ms，偏高）；如可行对比其它通道（如 USB tethering）并记录；若 hdc 通道固有开销大，明确写进 README 并建议 Wi-Fi 直连/热点场景。
