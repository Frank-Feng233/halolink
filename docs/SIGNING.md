# 签名与安装说明（HarmonyOS 零售机）

> 结论先行：**HarmonyOS 零售机（如 MatePad 11.5"S / HarmonyOS 7.0）只能安装由华为签名体系签发的 HAP。**
> 未签名 HAP、OpenHarmony 开源社区证书签名的 HAP **都不会被系统安装服务信任**（`hdc install` 报签名相关错误）。
> 因此原生 App 的安装需要一次性的「华为开发者账号 + DevEco Studio 自动签名」步骤；**Web 免安装模式不需要任何签名**。

## 1. 为什么需要签名

HarmonyOS 的应用安装服务 `bm` 在安装 HAP 时会校验：

1. HAP 内的 `signature`（PKCS#7 签名块）是否完整；
2. 签名证书链是否被设备信任；
3. Profile（`.p7b`）中的 `bundleName`、`distribution-type`、设备 UDID（debug profile）等是否匹配。

调试（debug）Profile 由华为 AGC 针对**你的华为开发者账号 + 指定设备 UDID** 签发，所以：

- 拿别人的 debug 证书没用（UDID/bundleName 不匹配）；
- OpenHarmony 社区证书（SDK 自带 `OpenHarmony.p12`）只能用于 OpenHarmony 设备/模拟器；
- 纯未签名包在部分旧版本/开发板上可能可装，但在 HarmonyOS NEXT/7 零售机通常被拒绝（`error: no signature file` / `9568320`）。

## 2. 推荐路径：DevEco Studio 自动签名（一次配置，长期可用）

1. 在 Mac 上安装 **DevEco Studio 7**（对应 HarmonyOS 7.0 / API 26；从[华为开发者官网下载](https://developer.huawei.com/consumer/cn/deveco-studio/)，需要登录华为账号，安装包数 GB）。
2. 打开 DevEco Studio → 右上角头像登录**华为开发者账号**（免费个人开发者即可，需实名认证）。
3. 「File → Open」打开本仓库的 `harmony-app/` 工程。
4. 「File → Project Structure → Signing Configs」→ 勾选 **Automatically generate signature** → 登录后等待自动生成。
   成功后会在 `~/.ohos/config/` 生成 `.p12 / .cer / .p7b`，并写入 `harmony-app/build-profile.json5` 的 `signingConfigs`。
5. 设备用 USB 连上（或无线调试），点 Run 即可安装运行；也可以继续用命令行：

```bash
cd harmony-app
# 用 DevEco 生成的签名配置构建（build-profile.json5 会被自动改写）
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  clean assembleHap --mode module -p product=default
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

> 本仓库的 `scripts/build.sh` 支持通过环境变量 `DEVECO_SDK_HOME` / `HVIGORW` 指向 DevEco 内置工具链，也可直接用 DevEco 打开工程构建。

## 3. 无华为账号时的替代方案

| 方案 | 是否需要签名 | 说明 |
|---|---|---|
| **Web 免安装模式** | 否 | 平板浏览器打开 `http://<mac-ip>:8080/`，功能等同（MJPEG 视频 + 触控回传），已验证可用 |
| 已有 DevEco 签名材料 | 是 | 把 `~/.ohos/config/` 下的签名配置拷到本机，替换 `build-profile.json5` 的 `signingConfigs` 后 `hdc install` |
| 借用他人 debug 证书 | 否 | 不可行：debug profile 绑定 UDID/bundleName |

## 4. 实测记录（本项目环境）

- 环境：macOS 15.7.5 / HarmonyOS 命令行工具链 6.0.1（SDK API 21）/ hdc 3.2.0f
- 设备：HUAWEI MatePad 11.5"S（TGR-W10），HarmonyOS 7.0.0.111（API 26），开发者模式 + 无线调试
- 设备 UDID（示例，用于生成 debug profile 时需要）：
  `YOUR_DEVICE_UDID`

## 5. 实测结果（2026-11-21）

| 包 | 安装命令 | 结果 |
|---|---|---|
| 未签名 HAP（`entry-default-unsigned.hap`） | `hdc install -r ...` | ❌ `error: failed to install bundle. code:9568320 error: no signature file.` |
| OpenHarmony 社区证书签名 HAP（`hap-sign-tool.jar` + SDK 自带 `OpenHarmony.p12` + 自建 debug profile） | `hdc install -r ...` / `bm install -p ...` | ❌ `code:9568257 error: fail to verify pkcs7 file.`，设备 hilog（HapVerify）给出根因：<br>`it do not come from trusted root, issuer: C=CN, O=OpenHarmony, OU=OpenHarmony Team, CN=OpenHarmony Application Root CA` |

结论：

1. 本地 `hap-sign-tool verify-app / verify-profile` 均通过 → 包本身格式正确；
2. 零售 HarmonyOS 7 **不信任 OpenHarmony 社区根证书**，且 `bm` 没有跳过验签的选项（`param ls` 中无相关开关）；
3. 因此在这台设备上安装原生 HAP **只能使用华为 AGC 签发的开发者证书 + 绑定该 UDID 的 debug profile**。
   获取方式：DevEco Studio 登录华为账号 → 自动签名（生成 `~/.ohos/config/*.p12|*.cer|*.p7b`）。
4. 在此之前，**Web 免安装模式功能完整可用**（MJPEG 视频 + 触控回传），不影响把平板当扩展屏使用。
