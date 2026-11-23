# 部署与使用指南

## 1. macOS 端（host）

### 1.1 构建

```bash
cd macos-host
swift build -c release
bash scripts/make_app.sh        # 生成 HaloLink.app（TCC 权限需要 .app 身份）
```

产物：

- 可执行文件：`macos-host/.build/release/halolink-host`
- App：`macos-host/HaloLink.app`

### 1.2 权限（首次运行）

系统设置 → 隐私与安全性：

- **屏幕录制**：用于 ScreenCaptureKit 采集虚拟显示器
- **辅助功能**：用于把平板的触摸/键盘事件注入 macOS

程序启动时会检测并引导；如未授权，采集会失败并打印提示。

### 1.3 运行模式

```bash
# Web 免安装模式（只需要 host）
halolink-host --http-port 8080
# 平板浏览器打开 http://<mac-ip>:8080/

# 原生 App 模式（平板 HAP 已安装并同意授权）
halolink-host --connect <平板IP>:9528        # 无线直连
hdc fport tcp:9528 tcp:9528                   # 或 hdc 通道（有线/无线调试）
halolink-host --connect 127.0.0.1:9528
```

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--width/--height` | 2800x1848 | 虚拟显示器像素尺寸（平板 3:2；2800x1840 无法获得 2x HiDPI，见 FAQ） |
| `--fps` | 60 | 采集/编码帧率 |
| `--bitrate` | 24000000 | H.264 码率（bps） |
| `--http-port` | 8080 | Web 备用通道端口 |
| `--display-mode` | virtual | `virtual` 扩展屏；`mirror` 镜像主屏（调试用） |
| `--no-web` | - | 不启动 HTTP 通道 |
| `--seconds N` | 0（常驻） | 测试用：N 秒后自动退出 |
| `--save-frames DIR` | - | 测试用：保存采集帧 PNG |
| `--dump-h264 PATH` | - | 测试用：把 H.264 码流写文件 |
| `--list-displays` | - | 列出当前显示器 |

## 2. HarmonyOS 端（原生 App）

### 2.1 环境

- HarmonyOS 命令行工具链 6.0.1+（SDK API 21+，含 NDK），或 DevEco Studio 7（API 26）
- 本仓库脚本默认使用 `~/ohos-tools/command-line-tools`

### 2.2 构建

```bash
cd harmony-app
bash scripts/build.sh            # assembleHap（未签名）
```

### 2.3 签名（必须，零售机限制）

见 [SIGNING.md](SIGNING.md)。简要：

1. 用华为开发者账号在 DevEco Studio 里对该工程执行一次「自动签名」，生成 `~/.ohos/config/` 下的 `.p12/.cer/.p7b`；
2. 把材料路径配置进 `harmony-app/build-profile.json5` 的 `signingConfigs`，或使用
   `bash scripts/sign_with_agc.sh <p12> <cer> <p7b> <storepass> <keyalias>`；
3. `bash scripts/install.sh` 安装到平板。

> 实测：未签名 HAP 与 OpenHarmony 社区证书签名 HAP 均会被 HarmonyOS 7 零售机拒绝（详见 SIGNING.md）。

### 2.4 运行

```bash
# 平板 App 是 TCP 服务端，监听 9528
hdc shell aa start -a EntryAbility -b com.halolink.display
# Mac 连接（无线直连）
halolink-host --connect <平板IP>:9528
# Mac 连接（hdc 通道，有线 / 无线调试）
hdc fport tcp:9528 tcp:9528
halolink-host --connect 127.0.0.1:9528
```

## 3. 一键脚本

```bash
bash scripts/setup_device.sh [--tcp <ip>:<port>] [--fport] [--launch]
bash scripts/start.sh web|wifi|usb [--background] [--open-tablet]
bash scripts/web_demo.sh          # Web 免安装模式一键演示 + 平板截图
bash scripts/acceptance.sh        # 端到端验收（证据输出 demo/）
bash scripts/stop.sh
```

## 4. FAQ / 排错

**Q: 平板看不到画面？**
- Web 模式：确认 Mac 防火墙允许 8080；平板与 Mac 同一局域网；`curl http://<mac-ip>:8080/healthz` 应返回 ok。
- 原生模式：确认 App 已启动（平板屏幕显示等待连接），`hdc fport ls` 有 `tcp:9528` 记录，host 日志显示已连接。

**Q: 虚拟显示器不出现？**
- 查看 host 日志；确认 macOS 版本支持（13+，本项目在 15.7.5 实测）。
- 若想用 2x HiDPI，请用 `--height 1848`（2800x1840 的 35:23 比例在 macOS 15.7.5 上只有 1x 模式，这是系统限制）。

**Q: 平板画面是镜像而不是扩展屏？**
- 默认 `--display-mode virtual`；检查系统设置→显示器里是否出现 "HaloLink" 显示器并被设置为扩展（而非镜像）。

**Q: 触摸映射位置不对？**
- host 注入用运行时 `CGDisplayBounds(虚拟屏)`；如果手动拖动过显示器排列/缩放，重启 host 让其重新读取。

**Q: hdc 设备 Offline / Unauthorized？**
- 无线调试空闲会掉线，重新 `hdc tconn <ip>:<port>`；平板上点「允许调试」；
- 重新执行 `bash scripts/setup_device.sh --tcp <ip>:<port>`。

**Q: macOS 26+ 上裸二进制申请不到屏幕录制权限？**
- 必须用 `.app`（`bash macos-host/scripts/make_app.sh` 生成），并建议使用稳定自签证书签名（脚本已尽量处理）。

---

# v1.1 更新（自动旋转 / Retina / 触摸开关 / 双击 App）

## 1. 双击使用 HaloLink.app

```bash
cd macos-host && bash scripts/make_app.sh      # 生成 HaloLink.app（内置 hdc）
open HaloLink.app                               # 或 Finder 双击
```

- App 自动连接：优先 USB（自动 hdc fport + 拉起平板 App），否则用上次成功的无线地址（可手填）
- 窗口/菜单栏提供：开启/停止、重新连接、显示模式（适应/填满）、触摸控制（默认关闭）、退出
- 首次运行需授权：系统设置 → 隐私与安全性 → 屏幕录制（必需）、辅助功能（仅触摸注入需要）
- 有 Gatekeeper 拦截时右键 → 打开；日志在 `~/Library/Logs/HaloLink/halolink-host.log`

## 2. 自动旋转（平板侧）

- App 跟随系统「自动旋转」；横竖屏切换后会自动上报 `display` 帧，Mac 端重建对应方向虚拟屏（横 2800×1848 / 竖 1840×2808），串流自动恢复
- 若旋转后 4s 内未收到新 config（旧 host），App 先按新尺寸 fit 显示

## 3. Retina 一致（可选）

```bash
# 虚拟屏逻辑分辨率对齐 Mac 内置屏（平板上 UI 观感与本机一致）
halolink-host --connect ... --scale-match-main
# 默认：虚拟屏 = 平板原生 2800×1848@2x
```

平板端「设置 → 显示模式」可选 **适应（黑边）/ 填满（裁切）**，持久化。

## 4. 触摸控制

- 平板「设置 → 触摸控制」默认**关闭**；关闭时不发送任何触摸/键鼠事件
- Mac 端 `--input off`（默认 off）为第二道保险；打开后恢复绝对坐标注入
- 下一版将改为远控软件式虚拟鼠标/触控板逻辑

## 5. 协议

见 `specs/PROTOCOL.md` 末尾「v1.1 扩展」：hello 增加 `screen.orientation`；config 增加 `scaleMode/retina/logicalWidth/Height/inputEnabled`；平板旋转时发送 `display` 控制帧（host 需用二进制 CONTROL 帧回新 config）。
