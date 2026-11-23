# HaloLink · 鸿蒙平板做 macOS 扩展屏

把 **HUAWEI MatePad 11.5"S（HarmonyOS 7.0 / API 26）** 变成 Mac 的**真正扩展屏**（不是镜像）：
macOS 端创建一个虚拟显示器 → ScreenCaptureKit 采集 → VideoToolbox 硬编 H.264 → 通过 USB / Wi-Fi 推给平板；
平板上全屏硬件解码显示（触摸回传逻辑尚未完成，默认关闭，当前仅作为纯扩展屏使用）。

```
┌──────────────────────────── macOS host ────────────────────────────┐      ┌────────── HarmonyOS 平板 ──────────┐
│ CGVirtualDisplay 虚拟屏（横屏 2800×1848 / 竖屏 1840×2808，2x）        │      │  TCP :9528 服务端                   │
│   └─ ScreenCaptureKit 采集 ──▶ VideoToolbox H.264 硬编 ──▶ TCP 推流 ─┼─────▶│   └─ NAPI OH_VideoDecoder 硬解       │
│ CGEvent 注入 ◀── 触摸/键鼠事件（默认关闭）◀────────────────────────────┼─────│   └─ XComponent(SURFACE) 全屏显示    │
│ 菜单栏 App + 状态窗口；HTTP :8080 备用 Web 客户端（免安装）            │      │   └─ 官方沉浸光感 UI（API 26）       │
└────────────────────────────────────────────────────────────────────┘      └─────────────────────────────────────┘
```

## 关于这个项目（作者说明）

> **请先阅读：这是一个非专业选手的 vibe coding 玩具**
>
> - 作者**不是编程专业**，这个项目**纯属 vibe coding 的产物**（和 AI 边聊边写出来的），代码质量、架构和工程规范都很业余，请以"能跑、能用"为标准看待，不要期待企业级质量。
> - **不定期随缘更新**：有需要/有空才改，不承诺 issue、PR 的响应时间和后续维护。
> - 初衷只是解决我自己的一个具体需求：**MacBook 配鸿蒙平板当副屏**（鸿蒙上没有 Sidecar 这类官方方案）。
> - **触摸逻辑没有做**：平板触摸/键鼠回传**默认关闭、尚未完善**；这个版本只把平板当作纯扩展显示器用，虚拟鼠标/触控板式的交互留到下个版本再考虑。
> - 在我看来这类项目的一个**差异化点**是：市面上同类软件（Android/平板当副屏的方案）**没有适配 macOS 的 HiDPI/Retina 虚拟显示**；HaloLink 用标准的 2x HiDPI 模式驱动平板原生分辨率（如 2800×1840 px = 1400×920 pt），在平板上的文字与 UI 细腻度和 Mac 内建屏是一个观感等级。
>
> 以上为作者本人的主观表述，欢迎指正。

## 功能

| 功能 | 说明 |
|---|---|
| 真正的扩展屏 | macOS 侧创建系统级虚拟显示器（`HaloLink Display`），可拖窗口、可全屏，不是镜像 |
| 低延迟硬解 | H.264 硬件编码（VideoToolbox）→ 平板 `OH_VideoDecoder` 硬解 → XComponent Surface 零拷贝；实测解码 10–14ms |
| 自动旋转 | 平板横竖屏**跟随系统自动旋转**；旋转后 Mac 虚拟屏自动重建为对应方向，串流不断 |
| 分辨率自适应 | 按平板面板 2800×1840 / 刷新率 144Hz 自动配置；2x HiDPI（"视网膜"观感） |
| Retina 一致 | 可选 `--scale-match-main`：虚拟屏逻辑分辨率对齐 Mac 内置屏，平板上 UI 大小与本机一致 |
| 显示模式 | 平板端「完整显示（可能留黑边）/ 裁剪填满（可能裁掉边缘）」可切换并持久化 |
| 触摸控制 | **未完成、默认关闭**（本版仅纯显示；虚拟鼠标式触摸逻辑下版本再说） |
| 官方沉浸光感 | 鸿蒙端使用 API 26 `uiMaterial` 系统材质（`UIMaterial.state=enable` + `systemMaterial`），不再自绘半透明 |
| 双通道 | USB（hdc fport，稳定+供电）/ 同 Wi-Fi 直连 |
| 免安装兜底 | Mac 内置 HTTP :8080，平板浏览器直接打开即可看到扩展屏画面（MJPEG） |
| 一键使用 | 双击 `HaloLink.app`，自动找平板、建通道、拉起 App、开始扩展 |

## 目录结构

```
harmony-extend-display/
├── macos-host/            # macOS 端：Swift 源码、HaloLink.app、测试证据
│   └── scripts/make_app.sh
├── harmony-app/           # 鸿蒙端：ArkTS + NAPI C++ 硬解，Stage 模型工程
│   ├── scripts/           # build / deploy（AGC 签名+USB 安装）/ device_smoke 等
│   └── evidence/          # 真机验收截图与日志（ui-v3 等）
├── specs/PROTOCOL.md      # HLDP 协议（含 v1.1：竖屏/旋转、scaleMode、输入开关）
├── scripts/               # 双击启动脚本 + 设备连接/验收脚本
├── research/              # 前期技术调研（macOS / 鸿蒙，含实测与 100+ 来源链接）
└── docs/                  # 架构、部署、签名、排错
```

## 快速开始

### 0. 环境要求

- macOS 14+（测试环境：macOS 15.7.5 / Apple Silicon / 仅 Command Line Tools）
- HarmonyOS 7.0（API 26）平板，已安装 HaloLink App（或用 Web 免安装模式）
- 有线：USB 数据线；无线：平板与 Mac 在同一局域网

### 1. 构建 macOS 端（只需一次）

```bash
cd macos-host
bash scripts/make_app.sh          # 生成 HaloLink.app（含 Info.plist、稳定自签、自带 hdc）
```

首次运行需在「系统设置 → 隐私与安全性」允许 **屏幕录制**（采集必需）与 **辅助功能**（触摸注入用，触摸默认关闭时可不授权）。

### 2. 平板端安装（只需一次）

```bash
cd harmony-app
bash scripts/build.sh                            # 使用 API 26 命令行工具链构建
DEVICE=<设备序列号或 ip:port> bash scripts/deploy.sh --build   # AGC 签名 → hdc 安装 → 启动
```

> ⚠️ 零售 HarmonyOS 设备只能安装 **华为 AGC 调试证书签名** 的 HAP（需华为开发者账号，免费）。
> 详见 [docs/SIGNING.md](docs/SIGNING.md)、[harmony-app/sign/debug-signing.md](harmony-app/sign/debug-signing.md)。
> 没有签名材料时可用 **Web 免安装模式**，功能可用。

### 3. 日常使用（双击 App）

1. 平板打开 **HaloLink 扩展屏**，停在「等待 Mac 连接」页
2. Mac 上 **双击 `macos-host/HaloLink.app`**
3. App 自动连接（优先 USB；否则上次使用过的无线地址），Mac 主屏右侧出现 **HaloLink Display** 虚拟屏
4. 把任意窗口拖到右侧虚拟屏 → 平板实时显示；旋转平板可自动横竖屏切换
5. 在 App 窗口/菜单栏里：**停止**、**重新连接**、**显示模式（适应/填满）**、**触摸控制（开/关，默认关）**

也可以直接双击仓库 `scripts/` 下的小工具：

| 脚本 | 用途 |
|---|---|
| [开启扩展屏（有线）.command](scripts/开启扩展屏（有线）.command) | 插 USB 线时：自动建 hdc 通道并启动扩展屏 |
| [开启扩展屏（无线）.command](scripts/开启扩展屏（无线）.command) | 同 Wi-Fi 直连 |
| [开启扩展屏（网页免安装）.command](scripts/开启扩展屏（网页免安装）.command) | 平板浏览器打开提示地址（MJPEG） |
| [停止扩展屏.command](scripts/停止扩展屏.command) | 停止 host / 清理 hdc 转发 |

### 4. 命令行（可选，调试用）

```bash
# 有线：USB hdc 通道（Mac 本地 19528 → 平板 9528）
hdc fport tcp:19528 tcp:9528
macos-host/.build/release/halolink-host --connect 127.0.0.1:19528 --auto

# 无线：同 Wi-Fi 直连
macos-host/.build/release/halolink-host --connect <tablet-ip>:9528 --auto

# 网页免安装模式（不需要平板 App）
macos-host/.build/release/halolink-host --http-port 8080
```

常用参数：

| 参数 | 说明 |
|---|---|
| `--auto` | 按平板 hello 的分辨率/方向/刷新率自动配置虚拟屏（默认开） |
| `--scale-tablet` / `--scale-match-main` | 虚拟屏逻辑分辨率 = 平板原生 / Mac 内置屏（"跟本机屏幕显示效果一致"） |
| `--fps` / `--bitrate` | 帧率（默认 min(60, 刷新率)）/ 码率（默认 24Mbps） |
| `--input off` | 触摸注入总开关（默认 **off**） |
| `--display-mode virtual\|mirror` | 扩展屏 / 镜像主屏（调试） |
| `--http-port` / `--no-web` | Web 备用通道端口 / 关闭 |
| `--seconds N` / `--save-frames DIR` / `--dump-h264 PATH` | 测试用 |

## 技术要点（实测结论）

- macOS `CGVirtualDisplay` 私有 API 在 macOS 15 上**零 entitlement、零 SIP 改动**即可创建真正的扩展显示器；`CGConfigureDisplayOrigin` 精确摆位，`CGEvent` 注入误差 0.0pt。macOS 对 35:23（2800×1840）只提供 1x 模式，故横屏默认 2800×1848@2x（逻辑 1400×924）。
- `ScreenCaptureKit` 按 `displayID` 精确采集；`VTCompressionSession`（RealTime / 无 B 帧 / 1s GOP）可低延迟编码。
- 鸿蒙 **ArkTS 没有 VideoDecoder**，低延迟硬解必须 NAPI C++（`OH_VideoDecoder` + `OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY=1` + `XComponent` SURFACE 零拷贝 + `SET_BUFFER_GEOMETRY` 固定）。
- 平板显示客户端**不需要任何系统权限**；官方沉浸光感需 `targetSdkVersion ≥ 26.0.0`（入口 `module.json5` 的 `metadata: ohos.arkui.UIMaterial.state=enable`，组件级 `.systemMaterial(new uiMaterial.ImmersiveMaterial(...))`）。
- 自动旋转：`orientation: auto_rotation` + `window.on('windowSizeChange')`，旋转后通过协议 `display` 帧让 host 重建对应方向的虚拟屏。
- Web 备用通道 MJPEG（`multipart/x-mixed-replace`），实测 25fps、触控回传可用。

详细调研与全部来源见 [research/macos-research.md](research/macos-research.md)、[research/harmonyos-research.md](research/harmonyos-research.md)。

## 已参考的开源项目

| 项目 | 许可 | 参考点 |
|---|---|---|
| [SideScreen](https://github.com/tranvuongquocdat/SideScreen) | MIT | 最接近的同款架构：Android 平板 → Mac 扩展屏（虚拟屏/编码/触摸/USB/主屏保护） |
| [OpenDisplay](https://github.com/peetzweg/opendisplay) | GPL-3.0 | 虚拟屏生命周期、Bonjour、macOS 26 兼容（仅思路） |
| [hidpify](https://github.com/raeseoklee/hidpify) | Apache-2.0 | 虚拟屏 sleep/wake、排列恢复 |
| [KhaosT/CGVirtualDisplay](https://github.com/KhaosT/CGVirtualDisplay) | Apache-2.0 | 私有 CGVirtualDisplay 头文件 |
| [ohos-scrcpy-app / 鸿镜](https://github.com/guoxiucai/ohos-scrcpy-app) | MIT | OpenHarmony H.264 推流 + hdc fport 通道设计 |
| [zanjie1999/meDisplay](https://github.com/zanjie1999/meDisplay) | 自定义 | macOS 屏 → 浏览器 MJPEG 思路 |
| [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) | Apache-2.0 | 设备端服务 + 桌面客户端架构与协议思路 |

## 当前限制 / 下一版

- 触摸为**绝对坐标直接注入**（本版默认关闭）；下一版改为远控软件式**虚拟鼠标/触控板逻辑**（相对移动、点击、滚轮、双指手势）。
- 平板端「填满」模式目前只做居中裁切，无画面平移。
- 虚拟显示器使用 Apple 私有 API，**不能上架 App Store**，仅个人/内部分发。
- 首次运行需授予屏幕录制/辅助功能；重建 ad-hoc 签名可能需重新授权（已用稳定自签缓解）。
- 无音频、无剪贴板同步、暂不支持多平板同时扩展。
- HarmonyOS 零售机安装第三方 HAP 受签名策略限制（需 AGC 调试证书）；Web 模式不受影响。

## License

代码 MIT（第三方借鉴部分保留原许可声明）；`research/` 下的链接与引用归原作者。
