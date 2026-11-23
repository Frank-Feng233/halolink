#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install.sh — install the HAP on the tablet and launch EntryAbility.
#
# Usage: scripts/install.sh [hap-file]
#   default hap: entry-default-agc-signed.hap, else -community-signed.hap,
#                else -unsigned.hap (retail device rejects unsigned: 9568320).
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

HAP="${1:-}"
if [ -z "$HAP" ]; then
  if [ -f "$AGC_SIGNED_HAP" ]; then
    HAP="$AGC_SIGNED_HAP"
  elif [ -f "$HALOLINK_SIGNED_HAP" ]; then
    HAP="$HALOLINK_SIGNED_HAP"
  elif [ -f "$COMMUNITY_SIGNED_HAP" ]; then
    HAP="$COMMUNITY_SIGNED_HAP"
  elif [ -f "$UNSIGNED_HAP" ]; then
    HAP="$UNSIGNED_HAP"
  else
    echo "no HAP found; run scripts/build.sh first" >&2
    exit 1
  fi
fi

echo "== HaloLink install =="
echo "   device: $DEVICE"
echo "   hap   : $HAP"

# Re-connect if the wireless-debug session went idle.
"$HDC" tconn "$DEVICE" >/dev/null 2>&1 || true
TARGETS="$("$HDC" list targets -v 2>/dev/null || true)"
CONNECTED="$(echo "$TARGETS" | awk '$3=="Connected" {print $1}')"
if [ -z "$CONNECTED" ]; then
  echo "ERROR: no connected hdc target (check USB / wireless debugging / DEVICE=...)" >&2
  echo "$TARGETS" >&2
  exit 3
fi
# Prefer the requested DEVICE (e.g. USB serial), else the first connected one.
if echo "$CONNECTED" | grep -qx "$DEVICE"; then
  TARGET="$DEVICE"
else
  TARGET="$(echo "$CONNECTED" | head -1)"
  echo "WARN: $DEVICE not connected, using $TARGET"
fi

set +e
INSTALL_OUT="$("$HDC" -t "$TARGET" install -r "$HAP" 2>&1)"
INSTALL_RC=$?
set -e
echo "$INSTALL_OUT"

if echo "$INSTALL_OUT" | grep -q "success"; then
  echo "INSTALL OK"
else
  echo
  echo "INSTALL FAILED (rc=$INSTALL_RC)."
  echo "  code:9568320 'no signature file'        -> HAP is unsigned; sign it (sign/debug-signing.md)"
  echo "  code:9568257 'fail to verify pkcs7'     -> signing cert not trusted by the retail device"
  echo "  -> retail HarmonyOS only accepts Huawei-AGC-issued certificates bound to this device UDID."
  exit 4
fi

echo "== launching $BUNDLE_NAME/$ABILITY_NAME =="
"$HDC" -t "$TARGET" shell aa start -a "$ABILITY_NAME" -b "$BUNDLE_NAME" || {
  echo "aa start failed" >&2
  exit 5
}
echo "launched. useful commands:"
echo "  $HDC -t $TARGET shell 'hilog | grep HaloLink'"
echo "  $HDC -t $TARGET shell 'snapshot_display -f /data/local/tmp/halolink.jpeg'"
