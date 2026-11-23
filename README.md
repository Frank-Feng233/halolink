# HaloLink · 鸿蒙平板做 macOS 扩展屏

在 macOS 上创建一个虚拟显示器，用 ScreenCaptureKit 采集画面，VideoToolbox 硬编 H.264，通过 USB 或 Wi-Fi 发给平板，平板全屏硬解显示。触摸回传未完成，默认关闭，当前只作扩展屏使用。

```
┌──────────────────────────── macOS host ────────────────────────────┐      ┌────────── HarmonyOS 平板 ──────────┐
│ CGVirtualDisplay 虚拟屏（横屏 2800×1840 / 竖屏 1840×2800，2x）        │      │  TCP :9528 服务端                   │
│   └─ ScreenCaptureKit 采集 ──▶ VideoToolbox H.264 硬编 ──▶ TCP 推流 ─┼─────▶│   └─ NAPI OH_VideoDecoder 硬解       │
│ CGEvent 注入 ◀── 触摸/键鼠事件，默认关闭 ◀─────────────────────────────┼─────│   └─ XComponent(SURFACE) 全屏显示    │
│ 菜单栏 App 和状态窗口；HTTP :8080 备用 Web 客户端                    │      │   └─ 官方沉浸光感 UI（API 26）       │
└────────────────────────────────────────────────────────────────────┘      └─────────────────────────────────────┘
```

## 关于这个项目

作者不是编程专业。这个项目是 vibe coding 的产物，代码质量、架构和工程规范都比较业余，以能跑、能用为标准，不要期待企业级质量。

更新不定期，有需要或有空才改，不承诺 issue 和 PR 的响应时间，也不保证后续维护。

最初是为了解决一个具体需求：MacBook 配鸿蒙平板当副屏。鸿蒙上没有 Sidecar 这类官方方案。

平板触摸和键鼠回传没有做完，默认关闭，这个版本只把平板当纯扩展显示器用。虚拟鼠标和触控板式的交互留到后面。

虚拟显示器按 2x HiDPI 驱动平板原生分辨率，例如 2800×1840 px 对应 1400×920 pt，平板上的文字和 UI 与 Mac 内建屏观感接近。

以上是作者主观表述，欢迎指正。

## 功能

| 功能 | 说明 |
|---|---|
| 扩展屏 | macOS 创建系统级虚拟显示器 HaloLink Display，可以拖窗口、可以全屏 |
| 低延迟硬解 | VideoToolbox 硬编 H.264，平板 OH_VideoDecoder 硬解，XComponent Surface 零拷贝；实测解码 10–14ms |
| 自动旋转 | 平板横竖屏跟随系统旋转，旋转后 Mac 虚拟屏切到对应方向，串流不中断 |
| 分辨率自适应 | 按平板面板 2800×1840 和 144Hz 自动配置，2x HiDPI 显示 |
| Retina 一致 | 可选 `--scale-match-main`，虚拟屏逻辑分辨率对齐 Mac 内置屏，平板上 UI 大小与本机一致 |
| 显示模式 | 平板端可以切换完整显示与裁剪填满，完整显示可能留黑边，裁剪填满可能裁掉边缘，选择会持久化 |
| 触摸控制 | 未完成，默认关闭，本版只做纯显示 |
| 官方沉浸光感 | 鸿蒙端使用 API 26 的 uiMaterial 系统材质，入口开启 UIMaterial.state 并调用 systemMaterial |
| 双通道 | USB 走 hdc fport，稳定并供电；也可同 Wi-Fi 直连 |
| 免安装兜底 | Mac 内置 HTTP :8080，平板浏览器打开就能看到扩展屏画面，格式为 MJPEG |
| 双击启动 | 双击 HaloLink.app，自动找平板、建立通道、拉起平板 App、开始扩展 |

## 目录结构

```
harmony-extend-display/
├── macos-host/            # macOS 端：Swift 源码、HaloLink.app、测试证据
│   └── scripts/make_app.sh
├── harmony-app/           # 鸿蒙端：ArkTS + NAPI C++ 硬解，Stage 模型工程
│   ├── scripts/           # build / deploy（AGC 签名+USB 安装）/ device_smoke 等
│   └── evidence/          # 真机验收截图与日志
├── specs/PROTOCOL.md      # HLDP 协议文档
├── scripts/               # 双击启动脚本、设备连接与验收脚本
├── research/              # 前期技术调研，含实测与来源链接
└── docs/                  # 架构、部署、签名、排错
```

## 快速开始

### 环境要求

- macOS 14 及以上，测试环境为 macOS 15.7.5、Apple Silicon、只装 Command Line Tools
- HarmonyOS 7.0（API 26）平板，已安装 HaloLink App，或者用 Web 免安装模式
- 平板上开启开发者模式：设置 → 关于本机 → 连续点击软件版本，按提示输入锁屏密码；再到 设置 → 系统和更新 → 开发者选项，打开 USB 调试。USB 连接时平板会弹出调试授权，点允许
- 有线需要 USB 数据线；无线需要平板和 Mac 在同一个局域网

### 构建 macOS 端

```bash
cd macos-host
bash scripts/make_app.sh          # 生成 HaloLink.app，包含 Info.plist、稳定自签和自带 hdc
```

首次运行要在系统设置 → 隐私与安全性里允许屏幕录制。触摸注入需要辅助功能权限，触摸默认关闭时可以不授权。

### 安装平板端

```bash
cd harmony-app
bash scripts/build.sh                                          # 用 API 26 命令行工具链构建
DEVICE=<设备序列号或 ip:port> bash scripts/deploy.sh --build    # AGC 签名 → hdc 安装 → 启动
```

零售 HarmonyOS 设备只能安装华为 AGC 调试证书签名的 HAP，需要华为开发者账号，注册免费。签名步骤见 [docs/SIGNING.md](docs/SIGNING.md) 和 [harmony-app/sign/debug-signing.md](harmony-app/sign/debug-signing.md)。没有签名材料时可以用 Web 免安装模式。

### 日常使用

1. 平板打开 HaloLink 扩展屏，停在等待 Mac 连接的页面
2. Mac 上双击 `macos-host/HaloLink.app`
3. App 自动连接，优先 USB，其次上次使用过的无线地址；Mac 主屏右侧出现 HaloLink Display 虚拟屏
4. 把窗口拖到右侧虚拟屏，平板实时显示；旋转平板会自动切换横竖屏
5. App 窗口和菜单栏里可以停止、重新连接、切换显示模式、打开或关闭触摸控制

也可以直接双击仓库 `scripts/` 下的脚本：

| 脚本 | 用途 |
|---|---|
| [开启扩展屏（有线）.command](scripts/开启扩展屏（有线）.command) | 插 USB 线时自动建立 hdc 通道并启动扩展屏 |
| [开启扩展屏（无线）.command](scripts/开启扩展屏（无线）.command) | 同 Wi-Fi 直连 |
| [开启扩展屏（网页免安装）.command](scripts/开启扩展屏（网页免安装）.command) | 平板浏览器打开提示地址，走 MJPEG |
| [停止扩展屏.command](scripts/停止扩展屏.command) | 停止 host，清理 hdc 转发 |

### 命令行（可选，调试用）

```bash
# 有线：USB hdc 通道，Mac 本地 19528 转发到平板 9528
hdc fport tcp:19528 tcp:9528
macos-host/.build/release/halolink-host --connect 127.0.0.1:19528 --auto

# 无线：同 Wi-Fi 直连
macos-host/.build/release/halolink-host --connect <tablet-ip>:9528 --auto

# 网页免安装模式，不需要平板 App
macos-host/.build/release/halolink-host --http-port 8080
```

常用参数：

| 参数 | 说明 |
|---|---|
| `--auto` | 按平板 hello 里的分辨率、方向和刷新率配置虚拟屏，默认开启 |
| `--scale-tablet` / `--scale-match-main` | 虚拟屏逻辑分辨率对齐平板原生分辨率或 Mac 内置屏 |
| `--fps` / `--bitrate` | 帧率，默认 min(60, 刷新率)；码率，默认 24Mbps |
| `--input off` | 触摸注入总开关，默认 off |
| `--display-mode virtual\|mirror` | 扩展屏或镜像主屏，调试用 |
| `--http-port` / `--no-web` | Web 备用通道端口，或关闭 Web 通道 |
| `--seconds N` / `--save-frames DIR` / `--dump-h264 PATH` | 测试用 |

## 技术要点

- macOS 的 CGVirtualDisplay 私有 API 在 macOS 15 上不需要 entitlement，也不需要改 SIP，就能创建扩展显示器。CGConfigureDisplayOrigin 负责摆位，CGEvent 注入误差 0.0pt。macOS 对 35:23 比例只给 1x 模式，所以横屏用 2800×1848 像素、2x 逻辑 1400×924 的模式族，启动后会选中 2800×1840@2x、逻辑 1400×920。
- ScreenCaptureKit 按 displayID 精确采集。VTCompressionSession 用 RealTime、无 B 帧、1s GOP，可以低延迟编码。
- 鸿蒙 ArkTS 没有 VideoDecoder，低延迟硬解用 NAPI C++ 实现，涉及 OH_VideoDecoder、低延迟开关、XComponent SURFACE 零拷贝和固定 buffer 几何。
- 平板显示端不需要系统权限。官方沉浸光感要求 targetSdkVersion 不低于 26.0.0，在 module.json5 里开启 UIMaterial.state，组件上调用 systemMaterial 并传入 ImmersiveMaterial。
- 自动旋转用 orientation: auto_rotation 和 window.on('windowSizeChange') 实现，旋转后通过协议里的 display 帧让 host 重建对应方向的虚拟屏。
- Web 备用通道用 MJPEG，multipart/x-mixed-replace 格式，实测 25fps。

调研过程和来源见 [research/macos-research.md](research/macos-research.md) 与 [research/harmonyos-research.md](research/harmonyos-research.md)。

## 已参考的开源项目

| 项目 | 许可 | 参考点 |
|---|---|---|
| [SideScreen](https://github.com/tranvuongquocdat/SideScreen) | MIT | Android 平板做 Mac 扩展屏的同架构实现 |
| [OpenDisplay](https://github.com/peetzweg/opendisplay) | GPL-3.0 | 虚拟屏生命周期、Bonjour、macOS 26 兼容思路 |
| [hidpify](https://github.com/raeseoklee/hidpify) | Apache-2.0 | 虚拟屏睡眠唤醒和排列恢复 |
| [KhaosT/CGVirtualDisplay](https://github.com/KhaosT/CGVirtualDisplay) | Apache-2.0 | 私有 CGVirtualDisplay 头文件 |
| [ohos-scrcpy-app / 鸿镜](https://github.com/guoxiucai/ohos-scrcpy-app) | MIT | OpenHarmony H.264 推流和 hdc fport 通道设计 |
| [zanjie1999/meDisplay](https://github.com/zanjie1999/meDisplay) | 自定义 | macOS 屏幕到浏览器的 MJPEG 实现 |
| [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) | Apache-2.0 | 设备端服务加桌面客户端的架构与协议 |

## 当前限制

- 触摸回传未完成，默认关闭。后续会做虚拟鼠标和触控板逻辑，支持相对移动、点击、滚轮和双指手势。
- 平板端裁剪填满只做居中裁切，不能平移画面。
- 虚拟显示器使用 Apple 私有 API，不能上架 App Store，只适合个人使用和内部使用。
- 首次运行要授权屏幕录制和辅助功能。重新签名后可能需要重新授权，稳定自签可以缓解。
- 没有音频和剪贴板同步，暂不支持多台平板同时扩展。
- 零售 HarmonyOS 设备安装第三方 HAP 需要 AGC 调试证书，Web 模式不受影响。

## License

代码使用 MIT License，第三方参考内容保留原许可声明。第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，发布步骤见 [PUBLISHING.md](PUBLISHING.md)。
