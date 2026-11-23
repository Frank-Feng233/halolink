# HaloLink — HarmonyOS 平板扩展屏客户端

把 HUAWEI MatePad 11.5"S（HarmonyOS 7.0 / API 26）变成 macOS 的**真·扩展显示器**：
平板全屏接收 Mac 推来的 H.264 视频（TCP / Wi-Fi 或 USB `hdc fport`），触摸/键盘/滚轮回传给 Mac。

> 本目录是 **harmony-app/**：HarmonyOS 原生应用（ArkTS UI + NAPI C++ OH_VideoDecoder 硬解）。
> 协议见 `../specs/PROTOCOL.md`（v1.1：旋转/display 帧/fit·fill/输入开关），主机端（macOS）在 `../macos-host/`。

---

## 1. 功能一览

| 能力 | 实现 |
|---|---|
| 全屏沉浸横屏 + 常亮 | UIAbility `setWindowLayoutFullScreen(true)` / `setWindowSystemBarEnable([])` / `setWindowKeepScreenOn(true)`，`orientation: landscape` |
| TCP 服务端（平板=服务器） | `@ohos.net.socket` `constructTCPSocketServerInstance()`，监听 `0.0.0.0:9528`，单 Mac 客户端、JSON 行握手 + 二进制帧、心跳 PING/PONG、断线后继续监听 |
| H.264 低延迟硬解 | NAPI C++ `OH_VideoDecoder`（Surface 模式，XComponent surfaceId → `OHNativeWindow`），**钉死 `SET_BUFFER_GEOMETRY`**（1080p 底部马赛克坑）、`OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY=1`、SPS/PPS 作 codec-specific data |
| 视频上屏 | `XComponent(SURFACE)`，按视频宽高比 letterbox 居中，解码帧 `RenderOutputBuffer` 直接送显（GPU 零拷贝） |
| 触摸回传 | XComponent `onTouch`（Down/Move/Up/Cancel）→ 归一化 `x,y` → `CONTROL {"type":"touch",...}` |
| 键盘回传 | `onKeyEvent` → `CONTROL {"type":"key",...}`；中文等 IME 文本用「Aa」按钮整段注入 `{"type":"text"}` |
| 滚轮回传 | `onAxisEvent`（鼠标/触控板）→ `CONTROL {"type":"scroll",...}` |
| 竖屏 / 自动旋转（v1.1） | ability `orientation: auto_rotation` + 运行时 `setPreferredOrientation(AUTO_ROTATION)`；监听 `windowSizeChange`，旋转后重排布局并发 `{"type":"display",...}`；host 回新 config 后重建解码 surface + request_keyframe（4s 无 config 则按新窗口 fit 显示并记录） |
| Retina 一致 / fit·fill（v1.1） | 解析 config `scaleMode/retina/logicalWidth/logicalHeight`；设置面板「适应(fit)/填满(fill)」持久化（默认适应）；fill = 等比放大 + clip 裁切 |
| 触摸控制开关（v1.1） | 默认**关闭**并持久化；关闭时不发送任何 touch/scroll/key/text；等待页/标题栏显示状态，stats 带 `"input":true|false` |
| 沉浸式全屏 + 浮层（v4） | 串流时隐藏标题栏，视频铺满全屏（顶部不再被布局行占用）；状态/关键帧/退出为半透明渐变浮层，**3 秒无操作自动隐藏**，点击画面任意处唤回；右下角单个圆角「设置」按钮按安全区 padding 摆放（横/竖屏均完整可见） |
| 端到端延迟（v1.3/v1.3.1） | hello `features:["frameTs"]`；config `frameTs:true` 时每个 VIDEO payload 前置 8B BE Unix-us 采集时间戳（host 必须用 **Unix epoch µs**，uptime µs 会被识别并安全禁用）；stats 上报 `recvMs/decMs/renderMs/e2eMs/presentHz`（native 300 样本 avg+p95）：dec/render 纯本地钟、e2e=recv+dec+render、recv 用滚动窗口 min 校时偏；严格 FIFO 配对+范围保护（异常样本不入统计、HUD 不显示）；串流期间 displaySync 期望/最大帧率=面板最高（presentHz 30→120），热点日志降频、输入队列收浅、`RenderOutputBuffer` 立即调用 |
| 虚拟屏渲染模式（v1.2） | host config `renderMode`：`pixel1to1` = 原生 1:1 像素（XComponent 尺寸按「视频像素/density」，逐像素不缩放，居中裁切/补边，忽略 fit/fill）；`scale` = HiDPI 最大化（2x 虚拟屏，按 fit/fill 缩放，用户未设置时默认裁剪填满）。UI 显示「虚拟屏 2800×1840 px (1x) · 模式 原生 1:1」或「虚拟屏 2800×1840 px = 1400×920 pt (2x) · 模式 HiDPI 最大化」+ 平板物理屏/有效显示区 |
| 显示方式语义（v4） | 「完整显示（可能留黑边）」/「裁剪填满（可能裁掉边缘）」+ 说明"只影响画面缩放方式；虚拟屏分辨率由 Mac 端选择"；等待页/设置面板显示平板物理屏、当前视频分辨率、当前方式、实际有效显示区（黑边/裁切像素） |
| UI（v2，官方沉浸光感） | **不再自绘任何半透明/流光材质**：官方 Navigation 标题栏承载状态（实时 fps/解码 ms/码率）、官方菜单承载「关键帧/设置/退出」、设置面板为系统 **bindSheet**、提示为系统 Toast、日志开关为官方 **Toggle + systemMaterial(ImmersiveMaterial)**；等待页纯黑 + 标准按钮 |
| 自适应刷新率 | `displaySync` 按流帧率设置期望范围（min/expected/max），面板能力取 `supportedRefreshRates` 最大值（本机 144Hz）；hello 携带 `screen.refreshRate/density` |
| Web 兜底 | 内置 ArkWeb `Web` 组件加载 Mac 的 `http://<mac-ip>:8080/`（MJPEG+触摸回传，浏览器通道已验证） |
| 离线 | 不依赖任何网络服务/分析 SDK；只有局域网 TCP 与可选 Web 兜底 |

界面为纯黑深色，左上/右下有悬浮按钮（⟳ 请求关键帧、Aa 文本注入、⚙ 设置、✕ 退出）——**系统手势在全屏下不可靠，必须留可见退出入口**。

## 2. 架构

```
┌──────────────────────── macOS host (client) ────────────────────────┐
│ 虚拟屏 → SCK 采集 → VideoToolbox H.264 → TCP 帧(0x01 VIDEO)          │
│ CGEvent 注入 ← JSON 控制帧(0x02 CONTROL) ←                          │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ TCP (Wi-Fi 直连 或 hdc fport over USB/无线调试)
┌──────────────────────────────▼──────────────────────────────────────┐
│ HarmonyOS app (server, 0.0.0.0:9528)                                │
│  ArkTS: DisplayServer(握手/帧解析/统计)                              │
│     ├─ CONTROL/触摸/键盘/滚动 → socket.send()                        │
│     └─ VIDEO payload ──(零拷贝 offset/len)──► NAPI libdecoder.so     │
│                                                OH_VideoDecoder(AVC) │
│ XComponent(SURFACE) ◄──── RenderOutputBuffer ──┘                    │
└─────────────────────────────────────────────────────────────────────┘
```

代码结构：

```
entry/src/main/
├── ets/
│   ├── entryability/EntryAbility.ets   # 沉浸全屏/常亮/加载首页
│   ├── pages/Index.ets                 # 全部 UI：视频层/状态/设置/Web 兜底/输入
│   ├── net/Protocol.ets                # HLDP 帧格式 + 增量 FrameParser（零拷贝视图）
│   ├── net/DisplayServer.ets           # TCP 服务端、握手、帧分发、心跳、统计
│   ├── decoder/DecoderBridge.ets       # libdecoder.so 的 ArkTS 封装
│   └── common/{Logger,Settings,NetUtil}.ets
├── cpp/
│   ├── napi_init.cpp                   # NAPI 导出：init/pushFrame/flush/release/getStats/setOnError
│   ├── video_decoder.{h,cpp}           # OH_VideoDecoder Surface 模式封装
│   ├── CMakeLists.txt                  # → libdecoder.so (arm64-v8a)
│   └── types/libdecoder/               # d.ts + oh-package 声明
├── resources/base/profile/network_config.json   # 允许明文 http (Web 兜底)
└── module.json5                        # 权限/横屏/元数据
```

## 3. 构建（只用 command-line-tools，不需要 DevEco Studio）

**需要 API 26 工具链**（官方沉浸光感要求 `targetSdkVersion >= 26.0.0`）：
`~/ohos-tools-26/command-line-tools`（HarmonyOS 26.0.0 Release / SDK API 26 / hvigor 6.26.9 / node v24）。
`scripts/env.sh` 会优先自动选用它，也可 `CLT_ROOT=/path/to/command-line-tools` 覆盖；
JDK 使用 11 或 17（**JDK 25 无法运行 hap-sign-tool**）。

工程配置：`compileSdkVersion`/`targetSdkVersion` = `26.0.0`，`compatibleSdkVersion` = `6.0.0(20)`。

```bash
# 一条命令（自动导出全部环境变量）
cd harmony-app && ./scripts/build.sh --clean

# 产物
entry/build/default/outputs/default/entry-default-unsigned.hap
```

脚本内部等价于：

```bash
export DEVECO_SDK_HOME=<CLT>/sdk
export DEVECO_NODE_HOME=<CLT>/tool/node        # 自带 node 18
export JAVA_HOME=/Library/Java/JavaVirtualMachines/amazon-corretto-11.jdk/Contents/Home
cd harmony-app
<CLT>/bin/hvigorw assembleHap -p product=default --analyze=normal --parallel --incremental --daemon
```

- API 26 起 SDK 版本号改为三段式 SemVer（`"26.0.0"`），`compatibleSdkVersion` 仍可用 `"6.0.0(20)"`
  这类旧格式（hvigor 6.26.9 实测接受）。
- 模组 `entry/build-profile.json5` 的 `externalNativeOptions.abiFilters=["arm64-v8a"]` 触发
  `BuildNativeWithCmake`，交叉编译出 `libs/arm64-v8a/libdecoder.so`。
- 可用环境变量覆盖工具链路径：`OHOS_TOOLS=... DEVICE=... PORT=... scripts/xxx.sh`。

| 脚本 | 作用 |
|---|---|
| `scripts/build.sh [--clean]` | 构建未签名 HAP（全部环境变量已内置） |
| `scripts/sign-community.sh` | 用 SDK 自带 OpenHarmony 社区材料签名（**仅用于证明包结构正确，真机不可装**） |
| `scripts/sign_with_agc.sh p12 cer p7b storePass keyAlias [keyPass] [hap] [out]` | 用华为 AGC 材料签名（唯一真机可装路径），可选 `WRITE_BUILD_PROFILE=1` 写回 build-profile |
| `scripts/install.sh [hap]` | hdc 连接 + 安装 + `aa start`，失败时区分 9568320/9568257 并提示 |
| `scripts/deploy.sh [--build] [--web]` | 一键：签名（自动发现 `signing/halolink.cer|p7b`）→ 构建 → hdc tconn → `fport tcp:9528` → 安装 → 启动 |
| `scripts/run_mock.sh [args]` | 对本机/平板跑 Python mock host（自动生成测试流） |
| `scripts/verify_build.sh` | 离线验收：HAP 内容 / NAPI 符号 / module.json / 原生 Annex-B 单测 / 协议自测（18 项） |
| `test/native/run_tests.sh` | 用 Mac 本机 clang++ 编译并运行 **libdecoder.so 里同一份** Annex-B SPS/PPS 解析代码的单测（22 项断言，含真实 ffmpeg 码流） |
| `scripts/collect_evidence.sh` | 采集设备信息、截图、安装失败日志、hilog 根因到 `evidence/` |
| `scripts/device_smoke.sh` | **拿到 AGC 签名后**真机端到端冒烟（安装→启动→握手→推流→截图→uitest 点击→触摸回传验证） |

## 4. 签名与安装（重要）

零售 HarmonyOS 7 设备**只信任 Huawei AGC 签发的证书链**。本仓库的 `scripts/sign-community.sh`
用 SDK 自带的 OpenHarmony 社区材料可以签出**结构正确**的 HAP（本机 `verify-app` 通过），但真机安装会失败：

| 尝试 | 命令 | 真机结果 |
|---|---|---|
| 未签名 | `hdc install -r entry-default-unsigned.hap` | ❌ `code:9568320 error: no signature file.` |
| 社区证书签名 | `hdc install -r entry-default-community-signed.hap` | ❌ `code:9568257 error: fail to verify pkcs7 file.` |

真机 hilog 根因：

```
E C011FE/foundation/HapVerify: hap_cert_verify_openssl_utils.cpp(GetCertsChain:322)
  it do not come from trusted root, issuer: C=CN, O=OpenHarmony, OU=OpenHarmony Team,
  CN=OpenHarmony Application Root CA
```

→ 必须使用华为开发者账号的调试证书 + 绑定本机 UDID 的 profile。完整步骤（DevEco 自动签名 /
AGC 手动签名 / CLI 一条命令签名）见 **[sign/debug-signing.md](sign/debug-signing.md)**。

```bash
# 拿到 AGC 的 p12/cer/p7b 后：
./scripts/sign_with_agc.sh ~/.ohos/config/app.p12 ~/.ohos/config/app.cer \
    ~/.ohos/config/app.p7b 'StorePass' 'KeyAlias'

# 安装 + 启动 + 端口映射
./scripts/deploy.sh            # 或 ./scripts/install.sh entry-default-agc-signed.hap
```

## 5. 运行

### 5.1 Wi-Fi 直连（同一局域网）

```bash
# 平板 App：启动即自动监听 0.0.0.0:9528，界面显示本机 IP
# Mac：
halolink-host --connect <tablet-ip>:9528
```

### 5.2 USB / 无线调试（hdc fport）

```bash
hdc tconn <tablet-ip>:36659        # 无线调试；USB 直连可省略
hdc fport tcp:9528 tcp:9528          # Mac:9528 -> 设备:9528
halolink-host --connect 127.0.0.1:9528
```

### 5.3 Web 兜底（原生解码不可用时）

Mac host 提供 `http://<mac-ip>:8080/`。在 App：「设置」→ Web 回退模式 → 填地址 → 进入 Web。
（平板自带浏览器打开该地址同样可用，不依赖本 App。）

## 6. Mock host 自测（无 Mac 主机也能验证协议/解码）

`test/mock_host.py` 是按 `specs/PROTOCOL.md` 实现的 Mac 侧参考客户端（纯标准库）：

```bash
# 1) 协议自测 + 本机 loopback 端到端（不需要平板）
python3 test/mock_host.py --self-test
python3 test/mock_host.py --loopback

# 2) 生成 2800x1840@30 的 5 秒 H.264 测试流（ffmpeg）
python3 test/mock_host.py --generate

# 3) 连平板推流 + 打印平板回传的触摸/按键/滚动/文本事件
./scripts/run_mock.sh                       # 自动找平板 IP（DEVICE 环境变量）
./scripts/run_mock.sh --no-stream           # 只握手+收控制帧（调触摸用）

# v1.1：mock host 会按 hello.screen.orientation 自动选横/竖屏码流；
# 旋转后收到 {"type":"display"} 会自动重发 config 并切换码流。
python3 test/mock_host.py --no-follow-orientation   # 固定横屏 config（测 fit/fill 对比用）

# v1.2 两种虚拟屏模式（host 侧 config.renderMode）
python3 test/mock_host.py --render-mode pixel1to1 --width 2800 --height 1840   # 原生 1:1
python3 test/mock_host.py --render-mode scale --width 2800 --height 1840 --scale-mode fill  # HiDPI 2x
python3 test/mock_host.py --render-mode pixel1to1 --width 2560 --height 1600 --stream test/stream_2560x1600.h264  # 1:1 补边示例

# v1.3 延迟测量（host 侧 config 带 frameTs，每个 VIDEO 前加 8B BE Unix-us 时间戳）
python3 test/mock_host.py --frame-ts --width 2800 --height 1840   # stats 会带 recvMs/decMs/renderMs/e2eMs/presentHz
```

用 `hdc shell uitest uiInput click <x> <y>` 在设备上模拟点击时，mock host 会打印
`TOUCH down/up ...`，以此验证「平板→Mac」输入通道。

## 6.1 与 macOS 主机端的联调契约（字段级已核对 `macos-host/` 源码）

本 App 与 `macos-host` 的 `LinkTransport.swift` / `InputInjector.swift` 已逐字段对齐：

| 方向 | 内容 | 说明 |
|---|---|---|
| 握手 | 平板先发 `{"type":"hello","protocol":"halolink/1",...}\n` | Mac 收到 hello 后发 config，再等 ready |
| | Mac 发 `{"type":"config","codec":"h264","width":..,"height":..,"fps":..,"bitrate":..,"profile":..,"keyframeInterval":..,"scaleMode":"fit"}\n` | App 用 width/height 配置解码器 + XComponent 比例 |
| | 平板回 `{"type":"ready"}\n` | 之后进入二进制帧模式 |
| 视频 | Mac→平板 `0x01` + Annex-B AU | IDR 前会重复 SPS/PPS；App 首帧提取 SPS/PPS 作 codec config |
| 心跳 | Mac→平板 `0x03` PING；平板回 `0x04` PONG | App 侧 1s 统计帧同时充当活性探测 |
| 控制 | 平板→Mac `0x02` + JSON（无换行） | `touch`(down/move/up/cancel,x,y,pointerId) / `key`(action,key) / `scroll`(dx,dy) / `text`(text) / `stats`(rxFps,decodeMs,rttMs) / `request_keyframe` / `bye` |
| 关键帧 | 平板发 `{"type":"request_keyframe"}` | 解码器出错/队列溢出/每次重连都会发；Mac 侧 `HostApp` 已处理 |
| 按键名 | `A`..`Z`、`0`..`9`、`BACKSPACE`/`ENTER`/`ESCAPE`/`TAB`/`SPACE`/`UP`/`DOWN`/`LEFT`/`RIGHT`/`HOME`/`END`/`PAGEUP`/`PAGEDOWN`/`FORWARD_DELETE`/`CAPSLOCK`/`F1..F12`，标点发字面字符 `- = [ ] \ ; ' , . / \`` | 与 `InputInjector.characterKeys/specialKeys` 表一一对应 |
| 组合键 | `CTRL+SHIFT+A` 形式（App 内部跟踪修饰键状态） | Mac `handleKey` 按 `+` 拆分并合成 CGEventFlags |
| 滚轮 | `{"type":"scroll","dx":..,"dy":..}` | Mac 注入 CGEvent scroll |

> 注意：`macos-host` 在 client 模式下不会主动发 hello（只发 config），与本 App 的服务端流程完全吻合。

## 7. 权限

仅需两个 **normal** 权限（安装时自动授予，无运行时弹窗、无需 ACL/AGC 审批）：

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` | TCP 监听/连接（socket）、ArkWeb 加载 Web 兜底页 |
| `ohos.permission.GET_NETWORK_INFO` | 读取本机 IPv4 地址显示在 UI / hello 里 |

`module.json5` 另带 `metadata: ohos.net.network_security_config → $profile:network_config`
（`cleartextTrafficPermitted: true`），让 ArkWeb 能加载局域网的 `http://<mac-ip>:8080/`。
**没有**声明任何 system_core/受限权限（CAPTURE_SCREEN / INJECT_INPUT_EVENT / ACCESS_VIRTUAL_SCREEN 等三方拿不到）。

## 8. 已知限制 / 诚实说明

1. **无法在真机运行是本项目的最大遗憾**：当前没有华为 AGC 证书，零售机拒绝安装（见 §4）。
   代码已完整实现并通过编译/链接/打包验证，但「解码上屏、触摸回传」的端到端行为
   **尚未在实体 MatePad 上跑通**（等 AGC 材料到手即可 `deploy.sh` 验证）。
2. **TCP_NODELAY**：ArkTS `TCPSocketConnection` 不暴露 `setExtraOptions`，服务器侧连接无法
   显式关闭 Nagle（只在 listening socket 上设置了 `TCPNoDelay`，Linux 不保证被 accept 继承）。
   触摸小包可能被合并最多 ~40ms；若手感不够跟手，后续可改为「输入走 NAPI 原生 socket 的独立通道」。
3. 单点触摸：协议目前只有单 pointer，多点手势会只回传第一个触点。
4. 键盘仅回传按键（含修饰键），中文/IME 组合串走「Aa」文本注入通道。
5. `OH_VideoDecoder` 在部分设备上对「IDR 前内联 SPS/PPS」敏感；本项目既在 Configure 时
   把首帧 SPS/PPS 作为 `OH_MD_KEY_CODEC_CONFIG` 传入，也保留 host 在 IDR 前重复的 SPS/PPS，
   并在解码错误时发 `request_keyframe` 重新同步。
6. 视频宽高比与平板不一致时按 letterbox 居中显示，触摸坐标按视频矩形归一化。
7. 无音频通道（扩展屏不需要）。
8. **XComponent(SURFACE) 悬浮层风险**：个别 HarmonyOS 版本的 SURFACE 原生层可能盖住 ArkUI 兄弟节点，
   若真机上右上/右下的悬浮按钮不可见，把按钮移到 letterbox 黑边区域或改用 `XComponentType.TEXTURE` 即可
   （解码/送显逻辑不变）。UI 已按「视频层 + 独立 HUD 层」结构写，改动只需 1 行 type。
9. **Web 兜底地址端口**：协议默认 Mac Web 端是 `:8080`；当前演示环境 host 用的是 `:8099`
   （见 evidence 截图里的浏览器页签）。Web 模式的地址在「设置」里可任意填，不写死。
10. **v1.2 说明**：`renderMode` 由 Mac 端决定（平板只展示/执行）；`pixel1to1` 模式必须由 host
    选择与面板像素一致的虚拟屏才能逐像素铺满，否则按协议居中裁切/补边；旧 host 不发送
    `renderMode` 时默认 `scale`，行为与 v1.1 一致。
11. **v1.3 说明**：e2e/recv 需要 host 的 8B 时间戳为 **Unix epoch 微秒**（当前 host 仍发 uptime µs，
    平板已能识别并自动禁用 recv/e2e，不会影响画面）；实测稳定数据（USB fport）：
    60fps 内容 recv≈3.6ms、dec≈10.8ms、render≈0.9ms、e2e≈15.4ms（p95 9.3/14.4/1.8/23.4），
    30fps 内容 e2e≈22.4ms；加合成等待（≈1/(2×presentHz)=4.2ms）估算光子 e2e ≈19.6ms(60fps)。
    presentHz 实测 120Hz（系统实际给到，非 144）。
12. **v4 说明**：串流浮层 3 秒自动隐藏（点击画面唤回）；标题栏仅在等待页显示，串流时视频真正
    全屏。等待页/设置面板会显示“平板物理屏 / 当前视频分辨率 / 显示方式 / 有效显示区”。
11. **v1.1 真机限制**：真机物理旋转依赖系统“自动旋转”开关；开发期可用设置面板「旋转测试」
    强制横竖屏（同一套 windowSizeChange/display/re-config 路径）。fill 模式目前仅居中裁切，
    无平移/拖动；虚拟鼠标式触摸与平移留待下一版。
11. **未签名/社区签名包在真机上的验证结论**只覆盖安装环节；解码、触摸链路的真机行为仍需 AGC 签名后
    用 `scripts/device_smoke.sh` 跑一遍才能算最终验收。

## 8.0 真机验收证据（已完成）

真机（MatePad 11.5"S / API 26 / AGC 签名）已跑通：

- 截图与数据：**[evidence/ui-v6-latency/](evidence/ui-v6-latency/README.md)** — v1.3 延迟分解与优化前后数字（estimated photon e2e ≈40ms → ≈28ms，presentHz 30→120）；
- 上一轮：**[evidence/ui-v5/](evidence/ui-v5/README.md)** — v1.2 两种虚拟屏模式（原生 1:1 / HiDPI 最大化）真机截图与日志；
- 上一轮：**[evidence/ui-v4/](evidence/ui-v4/README.md)** — 沉浸式全屏视频（顶部无黑条）、自动隐藏浮层、安全区设置按钮、新显示方式文案、真实 macos-host 联动旋转；
- 上一轮：**[evidence/ui-v3/](evidence/ui-v3/README.md)** — v1.1 自动旋转竖屏/横屏等待页、串流页、设置面板、fit/fill 对比、触摸开关、旋转日志；
- 上一轮：**[evidence/ui-v2/](evidence/ui-v2/README.md)** — 官方沉浸光感 UI / 等待页 / 设置面板 / 串流页 / 断开回等待页；
- 官方沉浸光感：hilog `UIMaterial appState=1`（ENABLE）、`isImmersiveMaterialSupported=true`、`ImmersiveMaterial(THIN) created`；
- 解码链路：`SET_BUFFER_GEOMETRY(2800,1840) ret=0`、`decoder started`、`render` 持续、`stats: rx=30 dec=30 decMs=13.8mbps=14 drop=0/0`（18s 无 appfreeze）；
- 触摸回传：mock host 收到 870 个 touch 事件（点击+滑动坐标正确）；
- 协议：0 次 desync，断开均为 mock 主动 bye。

## 8.1 离线已验证 / 未验证清单

| 已验证（离线，可复现） | 证据 |
|---|---|
| HAP 构建通过（ArkTS 编译 + NDK CMake 交叉编译 + 打包） | `scripts/build.sh`、`evidence/verify-build.log` |
| libdecoder.so 为 arm64、链接全部所需 `OH_VideoDecoder_*`/`OH_NativeWindow_*` 符号 | `scripts/verify_build.sh` 14 项符号检查 |
| module.json：bundle/版本/横屏/INTERNET+GET_NETWORK_INFO/network_config 元数据 | `verify_build.sh` |
| Annex-B NAL 切分 + SPS/PPS 提取（libdecoder.so 同源代码，本机单测 22 项，含真实 ffmpeg 码流） | `test/native/run_tests.sh` |
| HLDP 协议：帧编解码、分片重组、AU 切分、handshake、loopback 端到端 | `test/mock_host.py --self-test/--loopback` |
| 与 `macos-host` 源码字段级兼容（hello/config/ready、control JSON、按键名、PING/PONG、stats） | README §6.1 |
| 社区证书签名 + `verify-app/verify-profile` + code signing（结构正确） | `scripts/sign-community.sh` |
| 真机安装被签名体系拒绝（含设备 hilog 根因） | `evidence/install-*.log` |

| 未验证（需 AGC 签名后在真机跑） | 原因 |
|---|---|
| 解码器实际 Configure/Start 与画面输出 | 装不上 App |
| `SET_BUFFER_GEOMETRY` 对 2800×1840 的实际效果 | 同上 |
| 触摸/键盘/滚动坐标映射手感、端到端延迟 | 同上 |
| Web 兜底在 App 内 ArkWeb 的加载 | 同上（平板浏览器打开同一 URL 已验证可用） |

## 9. 排障

```bash
# 日志（tag = HaloLink，domain 0x3200）
hdc shell 'hilog | grep HaloLink'

# 截图（设备侧 0.6s/帧，仅用于肉眼确认）
hdc shell snapshot_display -f /data/local/tmp/halolink.jpeg
hdc file recv /data/local/tmp/halolink.jpeg ./halolink.jpeg

# 设备/版本信息
hdc shell param get const.ohos.apiversion          # 26
hdc shell param get const.product.software.version # TGR-W10G 7.0.0.111(...)
hdc shell bm get -u                                # UDID（配 profile 用）

# 端口占用 / 播放进程
hdc shell 'aa dump -a' | grep -i halolink
```

| 现象 | 排查 |
|---|---|
| 界面一直「等待 Mac 连接」 | Mac 是否连对 IP:port；防火墙；`hdc fport` 是否建立；App 是否处于 Web 模式（Web 模式会停掉 TCP 服务） |
| 握手超时 | Mac 发的 config 是否 `\n` 结尾、`{"type":"config",...}` |
| 有画面但底部花屏/马赛克 | 确认 `SET_BUFFER_GEOMETRY` 生效（hilog 有 `SET_BUFFER_GEOMETRY(w,h) ret=0`），必要时重启 App |
| 黑屏、无解码帧 | 看 hilog `decoder started`、`decoder OnError`；点 ⟳ 请求关键帧；或切 Web 模式 |
| `bind` 失败 2303198 | 9528 被占用（另一个实例/旧进程），改端口 |

## 10. 构建/签名产物清单

| 文件 | 说明 |
|---|---|
| `entry/build/default/outputs/default/entry-default-unsigned.hap` | 未签名包（~1.7MB，含 `libdecoder.so`） |
| `entry/build/default/outputs/default/entry-default-community-signed.hap` | OpenHarmony 社区证书签名（真机不可装，仅结构验证） |
| `entry/build/default/outputs/default/entry-default-agc-signed.hap` | AGC 签名后的可安装包（需自备材料） |
