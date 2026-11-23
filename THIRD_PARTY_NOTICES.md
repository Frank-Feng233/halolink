# Third-Party Notices / 第三方声明

HaloLink 的实现参考并受益于以下开源项目与公开资料。仅列出与本项目代码/文档直接相关的部分。

## 1. macOS 虚拟显示器（CGVirtualDisplay 私有 API）

`macos-host/Sources/CVirtualDisplay/` 中的 Objective-C 声明与调用方式参考了：

- **KhaosT/CGVirtualDisplay** — Apache-2.0
  https://github.com/KhaosT/CGVirtualDisplay
  （最早公开的 `CGVirtualDisplayPrivate.h` 逆向声明）
- **BetterDummy / BetterDisplay**（waydabber）— 社区项目中公开的 CGVirtualDisplay 使用经验
- **hidpify**（raeseoklee）— Apache-2.0：虚拟屏 sleep/wake、排列恢复等工程实践
- **OpenDisplay**（peetzweg）— GPL-3.0：仅参考架构与 macOS 版本兼容思路，未复制代码
- **SideScreen**（tranvuongquocdat）— MIT：Android 平板 → Mac 扩展屏的同类架构参考

> CGVirtualDisplay 是 Apple 的**私有 API**（无公开文档），仅逆向声明/运行时调用；相关代码不包含 Apple 源码。使用私有 API 的应用无法上架 Mac App Store，仅适合个人/内部使用。

## 2. HarmonyOS / OpenHarmony 端

- HarmonyOS SDK / Command Line Tools — 华为开发者联盟许可
  https://developer.huawei.com/consumer/cn/download/command-line-tools-for-hmos
  （本项目不提交 SDK 与工具链本体，仅引用其构建产物接口）
- OpenHarmony 文档与示例（`OH_VideoDecoder`、`XComponent`、`@ohos.net.socket`、`displaySync` 等）
  https://github.com/openharmony/docs
- 鸿镜 / ohos-scrcpy-app（MIT）— 设备端 H.264 推流、hdc fport 通道设计的架构参考
  https://github.com/guoxiucai/ohos-scrcpy-app

## 3. 调研与设计参考

- Genymobile/scrcpy（Apache-2.0）："设备端服务 + 桌面客户端"整体架构
  https://github.com/Genymobile/scrcpy
- meDisplay（zanjie1999）：macOS 屏幕 → 浏览器 MJPEG 的 Web 回退形态参考
  https://github.com/zanjie1999/meDisplay
- 详细调研报告与链接见 `research/` 目录（其中的第三方内容版权归原作者）。

## 4. 字体与图标

- 项目未内置第三方字体/图标资源；HarmonyOS 应用图标为占位图（可自行替换）。

## 5. 免责声明

本项目按 MIT License 提供，不提供任何担保。使用 Apple 私有 API、HarmonyOS 调试签名与设备调试能力均可能因系统升级而失效，请自行评估风险并遵守所在地法律与设备厂商条款。
