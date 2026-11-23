#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# env.sh — shared environment for every HaloLink harmony-app script.
# Source this file, do not execute it.
#
# Every value can be overridden from the outside, e.g.:
#   OHOS_TOOLS=/opt/command-line-tools DEVICE=192.168.1.5:12345 ./scripts/build.sh
# ---------------------------------------------------------------------------
set -a

# HarmonyOS command-line-tools root (contains bin/hvigorw, sdk/, tool/node/).
#
# Prefer the API 26 toolchain (HarmonyOS 26.0.0 Release, hvigor 6.26.9) because
# targetSdkVersion >= 26.0.0 is required for the official immersive material
# (uiMaterial). Fall back to the older 6.0.1(21) toolchain when it is missing.
# Override with CLT_ROOT=/path/to/command-line-tools or OHOS_TOOLS=...
_halolink_pick_clt() {
  if [ -n "${CLT_ROOT:-}" ]; then printf '%s' "$CLT_ROOT"; return; fi
  for candidate in "$HOME/ohos-tools-26/command-line-tools" "$HOME/ohos-tools/command-line-tools"; do
    if [ -x "$candidate/bin/hvigorw" ]; then printf '%s' "$candidate"; return; fi
  done
  printf '%s' "$HOME/ohos-tools/command-line-tools"
}
OHOS_TOOLS="${OHOS_TOOLS:-$(_halolink_pick_clt)}"
export CLT_ROOT="${CLT_ROOT:-$OHOS_TOOLS}"

# Project root of this app (harmony-app/).
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- SDK / node -----------------------------------------------------------
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$OHOS_TOOLS/sdk}"
export DEVECO_NODE_HOME="${DEVECO_NODE_HOME:-$OHOS_TOOLS/tool/node}"
export NODE_HOME="${NODE_HOME:-$DEVECO_NODE_HOME}"
export PATH="$OHOS_TOOLS/bin:$DEVECO_NODE_HOME/bin:$OHOS_TOOLS/sdk/default/openharmony/toolchains:$PATH"

# --- JDK (hap-sign-tool needs JDK 8/11/17; JDK 21+ fails) ------------------
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME}/bin/java" ]; then
  for candidate in \
    /Library/Java/JavaVirtualMachines/amazon-corretto-11.jdk/Contents/Home \
    /Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home \
    /Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home \
    /Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home; do
    if [ -x "$candidate/bin/java" ]; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi

# --- device / app ---------------------------------------------------------
export HDC="${HDC:-$OHOS_TOOLS/sdk/default/openharmony/toolchains/hdc}"
# Wireless-debug target of the MatePad 11.5"S; override with DEVICE=...
export DEVICE="${DEVICE:-192.168.1.10:36659}"
export BUNDLE_NAME="${BUNDLE_NAME:-com.halolink.display}"
export ABILITY_NAME="${ABILITY_NAME:-EntryAbility}"
export PORT="${PORT:-9528}"

# --- build outputs --------------------------------------------------------
export BUILD_OUT="$APP_DIR/entry/build/default/outputs/default"
export UNSIGNED_HAP="$BUILD_OUT/entry-default-unsigned.hap"
export COMMUNITY_SIGNED_HAP="$BUILD_OUT/entry-default-community-signed.hap"
export AGC_SIGNED_HAP="$BUILD_OUT/entry-default-agc-signed.hap"
# Optional signing/ dir at repo root (p12 + AGC-issued cer/p7b). Drop the two
# AGC files there and scripts/deploy.sh signs automatically.
export SIGNING_DIR="${SIGNING_DIR:-$(cd "$APP_DIR/.." && pwd)/signing}"
export HALOLINK_P12="$SIGNING_DIR/halolink.p12"
export HALOLINK_CER="$SIGNING_DIR/halolink.cer"
export HALOLINK_P7B="$SIGNING_DIR/halolink.p7b"
export HALOLINK_SIGNED_HAP="$BUILD_OUT/entry-default-halolink-signed.hap"

set +a
