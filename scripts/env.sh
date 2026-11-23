#!/usr/bin/env bash
# HaloLink 公共环境变量 / 路径
# 用法: source scripts/env.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# 工具链根目录：优先新版 CLT（API 26，沉浸光感所需），其次旧版 CLT（API 21）
if [ -d "$HOME/ohos-tools-26/command-line-tools/sdk/default/openharmony" ]; then
  export CLT_ROOT="${CLT_ROOT:-$HOME/ohos-tools-26/command-line-tools}"
elif [ -d "$HOME/ohos-tools/command-line-tools/sdk/default/openharmony" ]; then
  export CLT_ROOT="${CLT_ROOT:-$HOME/ohos-tools/command-line-tools}"
else
  export CLT_ROOT="${CLT_ROOT:-}"
fi

# hdc：优先工具链自带，其次用户目录下的独立 hdc
if [ -n "$CLT_ROOT" ] && [ -x "$CLT_ROOT/sdk/default/openharmony/toolchains/hdc" ]; then
  export HDC="$CLT_ROOT/sdk/default/openharmony/toolchains/hdc"
elif [ -x "$HOME/harmony/huawei/hdc" ]; then
  export HDC="$HOME/harmony/huawei/hdc"
  export DYLD_LIBRARY_PATH="$(dirname "$HDC")${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
else
  export HDC="$(command -v hdc || true)"
fi

export BUNDLE_NAME="${BUNDLE_NAME:-com.halolink.display}"
export ABILITY_NAME="${ABILITY_NAME:-EntryAbility}"
export APP_PORT="${APP_PORT:-9528}"
# hdc fport 的 Mac 本地端口（避开 9528 被占用的情况）
export FPORT_LOCAL="${FPORT_LOCAL:-19528}"
export HTTP_PORT="${HTTP_PORT:-8080}"

# macOS host 可执行文件（构建后）
export HOST_BIN="${HOST_BIN:-$REPO_ROOT/macos-host/.build/release/halolink-host}"
export HOST_APP="${HOST_APP:-$REPO_ROOT/macos-host/HaloLink.app}"

# 平板（由 setup_device.sh 填充）
export TABLET_SERIAL="${TABLET_SERIAL:-}"
export TABLET_IP="${TABLET_IP:-}"

log()   { printf '\033[1;36m[HaloLink]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[HaloLink]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[HaloLink]\033[0m %s\n' "$*" >&2; }

# 找到第一个可用设备：优先 USB(Connected)，其次任意非 Offline/Unauthorized 的设备
halolink_first_target() {
  local verbose
  verbose="$("$HDC" list targets -v 2>/dev/null | tr -d '\r')"
  # 1) USB 且 Connected
  local usb
  usb="$(echo "$verbose" | awk '$2=="USB" && $3=="Connected" {print $1; exit}')"
  [ -n "$usb" ] && { echo "$usb"; return; }
  # 2) 任意非 Offline / Unauthorized / Empty
  echo "$verbose" | awk 'NF>=1 && $1!="[Empty]" && $2!="Offline" && $2!="Unauthorized" {print $1; exit}'
}
