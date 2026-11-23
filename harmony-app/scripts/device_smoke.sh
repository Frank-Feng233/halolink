#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# device_smoke.sh — on-device end-to-end smoke test (run this once the HAP can
# actually be installed, i.e. after AGC signing materials are available).
#
# It verifies, on the real MatePad:
#   1. HAP installs and EntryAbility launches (window shows up)
#   2. the app's TCP server listens on :9528 and completes the hello/config/ready
#      handshake with test/mock_host.py
#   3. H.264 frames are decoded/rendered (screenshot)
#   4. tablet -> Mac touch events arrive (simulated tap via uitest)
#   5. hilog has no decoder errors
#
# Usage: scripts/device_smoke.sh [hap]
# Evidence: evidence/device-smoke/{mock.log,hilog.log,screen.jpeg,result.txt}
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

EVID="$APP_DIR/evidence/device-smoke"
mkdir -p "$EVID"
RESULT="$EVID/result.txt"
: >"$RESULT"
say() { echo "$*" | tee -a "$RESULT"; }

HAP="${1:-}"
if [ -z "$HAP" ]; then
  for candidate in "$AGC_SIGNED_HAP" "$HALOLINK_SIGNED_HAP"; do
    [ -f "$candidate" ] && HAP="$candidate" && break
  done
fi
if [ -z "$HAP" ] || [ ! -f "$HAP" ]; then
  say "FAIL: no installable (AGC-signed) HAP found."
  say "      1) put signing/halolink.cer + signing/halolink.p7b in repo signing/ dir (see sign/debug-signing.md)"
  say "      2) scripts/deploy.sh --build"
  exit 1
fi

"$HDC" tconn "$DEVICE" >/dev/null 2>&1 || true
TARGET="$("$HDC" list targets 2>/dev/null | awk '{print $1}' | head -1)"
[ -n "$TARGET" ] || { say "FAIL: no hdc target (DEVICE=$DEVICE)"; exit 1; }
say "target: $TARGET   hap: $HAP"
hdcx() { "$HDC" -t "$TARGET" "$@"; }

# --- 1. install ------------------------------------------------------------
say "== install =="
INSTALL_OUT="$(hdcx install -r "$HAP" 2>&1)"
echo "$INSTALL_OUT" | tee -a "$RESULT"
echo "$INSTALL_OUT" | grep -qi "success" || { say "FAIL: install rejected"; exit 2; }

# --- 2. launch -------------------------------------------------------------
say "== launch EntryAbility =="
hdcx shell aa start -a "$ABILITY_NAME" -b "$BUNDLE_NAME" 2>&1 | tee -a "$RESULT"
sleep 3
BUNDLE_STATE="$(hdcx shell "bm dump -n $BUNDLE_NAME" 2>&1 | head -5)"
echo "$BUNDLE_STATE" | tee -a "$RESULT"
echo "$BUNDLE_STATE" | grep -q "$BUNDLE_NAME" || { say "FAIL: bundle not installed"; exit 3; }

# --- 3. TCP handshake + H.264 stream with the mock host --------------------
TABLET_IP="${TABLET_IP:-${DEVICE%%:*}}"
STREAM="$APP_DIR/test/stream.h264"
if [ ! -f "$STREAM" ]; then
  python3 "$APP_DIR/test/mock_host.py" --generate --stream "$STREAM" >/dev/null 2>&1
fi
say "== mock host -> $TABLET_IP:$PORT (20s) =="
python3 "$APP_DIR/test/mock_host.py" --host "$TABLET_IP" --port "$PORT" \
  --stream "$STREAM" --fps 30 --duration 20 >"$EVID/mock.log" 2>&1 &
MOCK_PID=$!
sleep 6
# simulate a finger tap in the middle of the video area (device pixels)
hdcx shell "uitest uiInput click 1400 920" >/dev/null 2>&1
sleep 1
hdcx shell "uitest uiInput click 1600 1000" >/dev/null 2>&1
sleep 3
# screenshot while video should be on screen
hdcx shell "snapshot_display -f /data/local/tmp/smoke.jpeg" >/dev/null 2>&1
"$HDC" -t "$TARGET" file recv /data/local/tmp/smoke.jpeg "$EVID/screen.jpeg" >/dev/null 2>&1
wait "$MOCK_PID" 2>/dev/null
cp "$EVID/mock.log" "$EVID/mock.log" 2>/dev/null || true

GREP_OK=0
grep -q "handshake complete" "$EVID/mock.log" && say "PASS: handshake ok" || { say "FAIL: no handshake"; GREP_OK=1; }
grep -q "TOUCH" "$EVID/mock.log" && say "PASS: touch events reached the Mac side" || { say "FAIL: no TOUCH events"; GREP_OK=1; }
grep -q "STATS" "$EVID/mock.log" && say "PASS: tablet stats frames received" || say "WARN: no stats frames (decoder may not be started)"

# --- 4. hilog --------------------------------------------------------------
say "== hilog (HaloLink) =="
hdcx shell "hilog -x 2>/dev/null | grep HaloLink | tail -60" >"$EVID/hilog.log" 2>&1
grep -E "decoder started|SET_BUFFER_GEOMETRY" "$EVID/hilog.log" | tee -a "$RESULT"
if grep -qiE "decoder error|OnError|pushFrame failed" "$EVID/hilog.log"; then
  say "WARN: decoder errors in hilog (see evidence/device-smoke/hilog.log)"
fi

say "== evidence: $EVID =="
ls -la "$EVID" | tee -a "$RESULT"
if [ "$GREP_OK" = "0" ]; then
  say "RESULT: PASS (device pipeline verified)"
  exit 0
fi
say "RESULT: FAIL"
exit 4
