#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh — full pipeline: (optional) sign -> install -> launch -> connect.
#
#   scripts/deploy.sh                 # build (if needed), install, launch
#   scripts/deploy.sh --build         # force rebuild first
#   scripts/deploy.sh --web           # also map the Web fallback port (8080)
#
# Signing: retail HarmonyOS devices only install HAPs signed with a
# Huawei-AGC-issued certificate bound to the device UDID. If you have the three
# AGC files, run scripts/sign_with_agc.sh once (or set the env vars below) and
# deploy.sh will pick up entry-default-agc-signed.hap automatically:
#   AGC_P12=/path/app.p12 AGC_CER=/path/app.cer AGC_P7B=/path/app.p7b \
#   AGC_PASS=*** AGC_ALIAS=*** scripts/deploy.sh --build
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

DO_BUILD=0
WEB_PORT=0
for arg in "$@"; do
  case "$arg" in
    --build) DO_BUILD=1 ;;
    --web) WEB_PORT=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

cd "$APP_DIR"

# --- 1. signing configuration check ---------------------------------------
SIGNED_HAP=""
if [ -f "$AGC_SIGNED_HAP" ]; then
  SIGNED_HAP="$AGC_SIGNED_HAP"
fi
if [ -z "${AGC_P12:-}" ] && [ -f "$HALOLINK_CER" ] && [ -f "$HALOLINK_P7B" ] && [ -f "$HALOLINK_P12" ]; then
  # signing/ dir at the repo root (see signing/README.md): p12 + AGC cer/p7b
  AGC_P12="$HALOLINK_P12"
  AGC_CER="$HALOLINK_CER"
  AGC_P7B="$HALOLINK_P7B"
  AGC_ALIAS="${AGC_ALIAS:-halolink-debug}"
  if [ -z "${AGC_PASS:-}" ]; then
    echo "NOTE: AGC_PASS not set; using the local dev-keystore password documented"
    echo "      in signing/README.md (HaloLink2026!) - override with AGC_PASS=..."
    AGC_PASS='HaloLink2026!'
  fi
  SIGN_DEST="$HALOLINK_SIGNED_HAP"
fi
if [ -n "${AGC_P12:-}" ] && [ -n "${AGC_CER:-}" ] && [ -n "${AGC_P7B:-}" ]; then
  echo "== signing with AGC materials =="
  if [ "$DO_BUILD" = "1" ] || [ ! -f "$UNSIGNED_HAP" ]; then
    "$HERE/build.sh"
    DO_BUILD=0
  fi
  "$HERE/sign_with_agc.sh" "$AGC_P12" "$AGC_CER" "$AGC_P7B" \
    "${AGC_PASS:-}" "${AGC_ALIAS:-}" "${AGC_KEYPASS:-${AGC_PASS:-}}" "$UNSIGNED_HAP" \
    "${SIGN_DEST:-$AGC_SIGNED_HAP}"
  SIGNED_HAP="${SIGN_DEST:-$AGC_SIGNED_HAP}"
elif [ -f "$COMMUNITY_SIGNED_HAP" ] && [ -z "$SIGNED_HAP" ]; then
  echo "WARN: only the OpenHarmony community-signed HAP is available."
  echo "      Retail HarmonyOS rejects it with 9568257 (untrusted root) - see sign/debug-signing.md"
  SIGNED_HAP="$COMMUNITY_SIGNED_HAP"
fi

# --- 2. build --------------------------------------------------------------
if [ "$DO_BUILD" = "1" ] || { [ ! -f "$UNSIGNED_HAP" ] && [ -z "$SIGNED_HAP" ]; }; then
  "$HERE/build.sh"
  if [ -z "${AGC_P12:-}" ] && [ -f "$COMMUNITY_SIGNED_HAP" ]; then
    SIGNED_HAP="$COMMUNITY_SIGNED_HAP"
  fi
fi

if [ -z "$SIGNED_HAP" ]; then
  echo "ERROR: no HAP to deploy" >&2
  exit 1
fi

# --- 3. device connection --------------------------------------------------
echo "== connecting to $DEVICE =="
"$HDC" tconn "$DEVICE" >/dev/null 2>&1 || true
TARGETS="$("$HDC" list targets -v 2>/dev/null || true)"
CONNECTED="$(echo "$TARGETS" | awk '$3=="Connected" {print $1}')"
if [ -z "$CONNECTED" ]; then
  echo "ERROR: no connected device. Connect USB or enable wireless debugging and run:" >&2
  echo "  $HDC tconn $DEVICE" >&2
  exit 3
fi
if echo "$CONNECTED" | grep -qx "$DEVICE"; then
  TARGET="$DEVICE"
else
  TARGET="$(echo "$CONNECTED" | head -1)"
  echo "WARN: $DEVICE not connected, using $TARGET"
  DEVICE="$TARGET"
fi
echo "   target: $TARGET"

# --- 4. port forward so the Mac can reach the tablet-side TCP server -------
echo "== hdc fport tcp:$PORT -> device:$PORT =="
"$HDC" -t "$TARGET" fport "tcp:$PORT" "tcp:$PORT" || \
  echo "WARN: fport failed (maybe already forwarded); continuing"
if [ "$WEB_PORT" = "1" ]; then
  echo "== hdc fport tcp:8080 -> device:8080 (Web fallback) =="
  "$HDC" -t "$TARGET" fport tcp:8080 tcp:8080 || true
fi

# --- 5. install + launch ---------------------------------------------------
"$HERE/install.sh" "$SIGNED_HAP" || {
  rc=$?
  echo "deploy failed at install step (rc=$rc)" >&2
  exit "$rc"
}

# --- 6. next steps ---------------------------------------------------------
echo
echo "== deploy finished =="
echo "  native mode : scripts/run_mock.sh --host 127.0.0.1   (uses hdc fport)"
echo "  wifi mode   : scripts/run_mock.sh --host <tablet-ip>"
echo "  logs        : $HDC -t $TARGET shell 'hilog | grep HaloLink'"
echo "  screenshot  : $HDC -t $TARGET shell 'snapshot_display -f /data/local/tmp/halolink.jpeg' && \\"
echo "                $HDC -t $TARGET file recv /data/local/tmp/halolink.jpeg ./halolink.jpeg"
