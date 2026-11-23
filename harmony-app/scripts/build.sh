#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build.sh — build the HaloLink HAP with the command-line-tools only
# (no DevEco Studio required). Produces an UNSIGNED HAP; use
# scripts/sign_with_agc.sh or DevEco auto-signing to sign it for a retail
# HarmonyOS device.
#
# Usage: scripts/build.sh [--clean] [--release]
# Output: entry/build/default/outputs/default/entry-default-unsigned.hap
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

CLEAN=0
MODE="--incremental"
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --release) MODE="--incremental" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

cd "$APP_DIR"

echo "== HaloLink build =="
echo "   OHOS_TOOLS : $OHOS_TOOLS"
echo "   SDK        : $DEVECO_SDK_HOME"
echo "   NODE       : $($DEVECO_NODE_HOME/bin/node -v 2>/dev/null || echo '?')"
echo "   JAVA_HOME  : ${JAVA_HOME:-<unset>}"
echo "   APP_DIR    : $APP_DIR"

if [ "$CLEAN" = "1" ]; then
  "$OHOS_TOOLS/bin/hvigorw" clean -p product=default
fi

"$OHOS_TOOLS/bin/hvigorw" assembleHap -p product=default \
  --analyze=normal --parallel "$MODE" --daemon

if [ -f "$UNSIGNED_HAP" ]; then
  echo
  echo "BUILD OK  ->  $UNSIGNED_HAP"
  echo "next: scripts/install.sh            (unsigned / dev, will be rejected by retail device)"
  echo "      scripts/sign_with_agc.sh ...  (sign with Huawei AGC materials)"
else
  echo "BUILD FAILED: $UNSIGNED_HAP not found" >&2
  exit 1
fi
