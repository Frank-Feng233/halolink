# 发布到 GitHub（开源）步骤

> 目标：把本仓库以 **MIT License** 开源到 GitHub。仓库里**不应包含**：签名私钥/证书、构建产物、包含个人信息的截图/日志、设备 UDID/序列号、真实内网 IP。

## 1. 一次性准备

```bash
# 安装 GitHub CLI（已有可跳过）
brew install gh
gh auth login          # 按提示在浏览器完成登录（推荐 HTTPS + 浏览器授权）
```

或者不用 gh CLI：
1. 浏览器登录 GitHub → 右上角 + → **New repository**
2. Repository name 例如 `halolink`，Public，**不要**勾选 "Add a README"（本地已有）
3. 创建后复制仓库地址 `https://github.com/<你的用户名>/halolink.git`

## 2. 本地提交（已由开发侧初始化好，可跳过）

```bash
cd ~/projects/harmony-extend-display    # 本仓库路径
git status                              # 检查 .gitignore 生效（signing/、evidence/、build/ 不应出现）
git add -A
git commit -m "HaloLink v1.3.1: macOS virtual extended display + HarmonyOS tablet client"
```

## 3. 推送到 GitHub

### 方式 A：GitHub CLI（最少步骤）

```bash
cd ~/projects/harmony-extend-display
gh repo create halolink --public --source=. --remote=origin --push
```

### 方式 B：手动创建仓库 + HTTPS（需要 Personal Access Token）

1. GitHub → Settings → Developer settings → **Personal access tokens (classic / fine-grained)** → 生成一个具备 `repo` 权限的 token
2. 本地执行：

```bash
cd ~/projects/harmony-extend-display
git remote add origin https://github.com/<你的用户名>/halolink.git
git branch -M main
git push -u origin main
# 用户名：你的 GitHub 用户名；密码：粘贴 Personal Access Token（不是登录密码）
```

### 方式 C：SSH

```bash
ssh-keygen -t ed25519 -C "your@email"
# 把 ~/.ssh/id_ed25519.pub 添加到 GitHub → Settings → SSH and GPG keys
git remote add origin git@github.com:<你的用户名>/halolink.git
git branch -M main
git push -u origin main
```

## 4. 推送后建议

- **仓库设置**：About 填写简介/主题（`macos`, `harmonyos`, `second-screen`, `sidecar`, `scrcpy`），上传一张**不含个人信息**的截图作为 social preview
- **Issues**：保留默认即可；可在 `.github/ISSUE_TEMPLATE/` 添加模板
- **安全**：不要提交 `signing/`（私钥/证书）、`evidence/`（个人截图）、`demo/`、真实 IP/设备 UDID
- **Release**：可在 GitHub Releases 上传构建好的 `HaloLink.app` 压缩包（注意：Mac App 需自签名/公证说明；HAP 需自行签名后才能被零售设备安装）

## 5. 已知的公开注意事项

- 本项目使用 Apple **私有 API**（`CGVirtualDisplay`），无法上架 Mac App Store，请勿在商业分发中隐瞒这一点
- HarmonyOS 零售设备安装 HAP 需要华为 AGC 调试证书（需开发者账号），仓库不附带任何证书
- `.gitignore` 已排除签名材料、构建产物、实验证据与媒体样本；提交前请再 `git status` 确认
