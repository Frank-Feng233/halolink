# 真机签名指南（HaloLink，retail HarmonyOS 7 / MatePad 11.5"S）

> **为什么需要这份文档**：零售 HarmonyOS 设备只接受 **Huawei AGC 签发**的证书链。
> 本项目已实测：未签名 HAP → `9568320 no signature file`；用 SDK 自带 OpenHarmony
> 社区材料签名（本地 `verify-app` 通过）→ 真机 `9568257 fail to verify pkcs7 file`，
> hilog 明确 `it do not come from trusted root, issuer: ... CN=OpenHarmony Application Root CA`。
> 因此必须用华为开发者账号生成调试证书 + 绑定本机 UDID 的 profile。

> ℹ️ 自 v2 UI 起工程要求 `compileSdkVersion/targetSdkVersion = 26.0.0`（官方沉浸光感
> `uiMaterial` 要求 target ≥ 26.0.0），请使用 **API 26 command-line-tools**
> （`~/ohos-tools-26/command-line-tools`，hvigor 6.26.9）构建；签名材料与流程不变
> （`signing/halolink.p12|cer|p7b` 继续有效）。

> ⚠️ 以下流程需要**你自己的 Huawei 开发者账号**（免费注册 + 实名认证）。本文档不包含、
> 也不应该包含任何真实证书/私钥/密码。`*.p12`、`*.p7b`、`*.cer` 都不要提交到 git。

---

## 0. 先取设备 UDID（签 profile 必需）

```bash
hdc tconn <tablet-ip>:36659
hdc shell bm get -u
# 输出示例：
# udid of current device is :
# YOUR_DEVICE_UDID（64 位十六进制）
```

本机设备的 UDID 为 `YOUR_DEVICE_UDID`
（签 profile 时必须包含它，否则安装会报设备不匹配）。

---

## 方式 A（推荐）：DevEco Studio 自动签名

需要 DevEco Studio 7（或 6.x，能识别 API 26 设备）+ 已登录华为账号。

1. DevEco Studio → `File > Open` 打开 `harmony-app/` 工程（它会识别 `build-profile.json5`）。
2. `File > Project Structure > Signing Configs`（旧版叫 Project Structure → Signing Configs）：
   - 勾选 **Automatically generate signature**（自动生成签名）；
   - 如提示登录：`Sign In`，用华为开发者账号登录（免费个人开发者即可）；
   - 等待自动生成 `*.p12` / `*.cer` / `*.p7b`，并自动写入 `build-profile.json5` 的
     `app.signingConfigs` + `products[0].signingConfig = "default"`。
3. 点 `Apply / OK`。此后：
   - IDE 内直接 `Run ▶` 即可安装到平板（Run 时用的是 IDE 的签名产物）；
   - 或命令行构建也会自动签名：
     ```bash
     cd harmony-app
     ./scripts/build.sh --clean
     # 产物：entry/build/default/outputs/default/entry-default-signed.hap
     ```
4. 用 CLI 部署（IDE 已登录并生成过材料后，`signingConfigs` 已在工程里）：
   ```bash
   ./scripts/install.sh entry/build/default/outputs/default/entry-default-signed.hap
   # 或
   ./scripts/deploy.sh
   ```

自动签名材料默认位置（macOS，供手动 CLI 签名复用）：

```
~/.ohos/config/openharmony/            # 自动签名生成的目录（不同 DevEco 版本可能略有差异）
  *.p12        # 密钥库
  *.cer        # 证书链
  *.p7b        # provision profile（已绑定 bundleName + UDID）
```

> 提示：自动签名生成的 profile 绑定的是「DevEco 登录账号 + 该设备 UDID」，换设备/换账号需重新生成。
> bundleName 必须是 `com.halolink.display`（工程已固定）；如果 DevEco 因 bundleName 冲突要求修改，
> 在 `AppScope/app.json5` 与 `entry/src/main/module.json5` 里同步改，并重新生成 profile。

---

## 方式 B：AGC 网站手动创建（不装 DevEco 也能签名）

适合 CI / 只拿到三件套的场景：

1. 登录 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)
   → 我的项目 → 新建项目/应用，**包名填 `com.halolink.display`**。
2. 准备签名证书：
   - `证书、APP ID 和 Profile` → `证书` → 新增证书（调试证书），按向导用 **keytool/JDK** 生成
     CSR（或在 DevEco 的 `Build > Generate Key and CSR` 生成），下载得到 `*.cer`；
   - 密钥库 `*.p12` 与 alias/密码由你自己生成并妥善保存（AGC 只收 CSR，不收私钥）。
3. 注册设备：`设备` → 添加设备 → 填 UDID（见第 0 节）。
4. 创建 **调试 Profile**（`Profile` → 添加 → 类型 Debug）：
   - 绑定上面创建的证书 + `com.halolink.display` + 设备 UDID；
   - 下载得到 `*.p7b`。
5. 用本仓库脚本一条命令签名 + 校验：
   ```bash
   cd harmony-app
   ./scripts/build.sh --clean
   ./scripts/sign_with_agc.sh \
       /path/to/app.p12 /path/to/app.cer /path/to/app.p7b \
       'StorePassword' 'KeyAlias' 'KeyPassword'
   # -> entry/build/default/outputs/default/entry-default-agc-signed.hap
   ```
6. 安装并启动：
   ```bash
   ./scripts/install.sh entry/build/default/outputs/default/entry-default-agc-signed.hap
   ```

（可选）把签名配置写进 `build-profile.json5`，让 `hvigorw assembleHap` 每次自动签名：

```bash
WRITE_BUILD_PROFILE=1 ./scripts/sign_with_agc.sh p12 cer p7b pass alias pass
```

写进去的格式（schema 来自 hvigor 6.21.1）：

```json5
"signingConfigs": [{
  "name": "default",
  "type": "HarmonyOS",
  "material": {
    "storeFile": "/abs/path/app.p12",
    "storePassword": "******",
    "keyAlias": "your-alias",
    "keyPassword": "******",
    "certpath": "/abs/path/app.cer",
    "profile": "/abs/path/app.p7b",
    "signAlg": "SHA256withECDSA"
  }
}],
"products": [{ "name": "default", "signingConfig": "default", ... }]
```

> 注意：DevEco 写入的密码通常是 **加密后**的字符串；明文密码在部分 hvigor 版本可被接受，
> 若 `assembleHap` 报签名失败，就退回方式 B 第 5 步的「直接 hap-sign-tool 签名」路径（一定可用）。

---

## 方式 C：签名已有 HAP（手工 hap-sign-tool，等价于脚本）

```bash
CLT=/Users/yourname/ohos-tools/command-line-tools
SIGN_LIB=$CLT/sdk/default/openharmony/toolchains/lib
JAVA=/Library/Java/JavaVirtualMachines/amazon-corretto-11.jdk/Contents/Home/bin/java   # JDK 8/11/17
HAP=harmony-app/entry/build/default/outputs/default/entry-default-unsigned.hap

$JAVA -jar $SIGN_LIB/hap-sign-tool.jar sign-app \
  -mode localSign \
  -keyAlias <alias> -keyPwd <keypass> \
  -appCertFile <app.cer> \
  -profileFile <app.p7b> \
  -inFile "$HAP" \
  -signAlg SHA256withECDSA \
  -keystoreFile <app.p12> -keystorePwd <storepass> \
  -outFile harmony-app/entry/build/default/outputs/default/entry-default-agc-signed.hap \
  -compatibleVersion 21 -signCode 1

# 校验
$JAVA -jar $SIGN_LIB/hap-sign-tool.jar verify-app \
  -inFile entry-default-agc-signed.hap \
  -outCertChain /tmp/chain.cer -outProfile /tmp/profile.p7b
```

---

## 常见错误码

| 错误 | 含义 | 处理 |
|---|---|---|
| `9568320 no signature file` | HAP 未签名 | 用方式 A/B/C 签名 |
| `9568257 fail to verify pkcs7 file` | 证书链不被设备信任（社区证书/证书链不完整） | 用 AGC 签发的证书；确认 `appCertFile` 是「叶子+中间 CA」完整链 |
| `verify-app failed` | 本地签名材料不匹配（key/cert/profile 三者不对应） | 确认 p12 alias 与 cer 公钥匹配、profile 是该 bundleName 的 |
| 安装提示设备不匹配 / 无权限 | profile 未包含本机 UDID 或 bundleName 不一致 | AGC 设备列表加 UDID，重新生成 p7b |
| `hdc install` 后 `AppMod finish` 但没装上 | 零售机常见：签名被拒（见上） | 查 `hdc shell 'hilog \| grep HapVerify'` |

## 安全

- 不要把 `*.p12 / *.p7b / *.cer / 密码` 提交到仓库；`.gitignore` 已忽略 `harmony-app/sign/out/`、`harmony-app/sign/agc/`。
- 密码优先用环境变量传入（`AGC_P12/AGC_CER/AGC_P7B/AGC_PASS/AGC_ALIAS`），避免进入 shell 历史。
