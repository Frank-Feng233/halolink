#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# collect_evidence.sh — capture device/install evidence for the exploit-free
# verification report (screenshots, device info, install errors, hilog root cause).
#
# Usage: scripts/collect_evidence.sh
# Writes into harmony-app/evidence/
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

EVID="$APP_DIR/evidence"
mkdir -p "$EVID"

echo "== collecting HaloLink deployment evidence =="
"$HDC" tconn "$DEVICE" >/dev/null 2>&1 || true
TARGET="$("$HDC" list targets 2>/dev/null | awk '{print $1}' | head -1)"
if [ -z "$TARGET" ]; then
  echo "ERROR: no hdc target" >&2
  exit 1
fi
echo "   target: $TARGET"

hdcx() { "$HDC" -t "$TARGET" "$@"; }

# --- 1. device information -------------------------------------------------
{
  echo "HaloLink deployment evidence — $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
  echo
  echo "## hdc"
  "$HDC" -v
  echo "target: $TARGET"
  echo
  echo "## device params"
  for key in const.ohos.apiversion const.product.software.version const.ohos.fullname \
             const.product.model const.product.devicetype const.product.name \
             const.display.manager.service; do
    printf '%-42s = %s\n' "$key" "$(hdcx shell "param get $key" 2>/dev/null | tr -d '\r')"
  done
  echo
  echo "## udid"
  hdcx shell bm get -u 2>/dev/null | tr -d '\r'
  echo
  echo "## screen"
  hdcx shell "wm size" 2>/dev/null | tr -d '\r'
} >"$EVID/device-info.txt"
echo "   wrote evidence/device-info.txt"

# --- 2. device screenshot (proves device access) ---------------------------
hdcx shell "snapshot_display -f /data/local/tmp/halolink_evidence.jpeg" >/dev/null 2>&1
"$HDC" -t "$TARGET" file recv /data/local/tmp/halolink_evidence.jpeg "$EVID/device-screen.jpeg" >/dev/null 2>&1
if [ -f "$EVID/device-screen.jpeg" ]; then
  echo "   wrote evidence/device-screen.jpeg ($(stat -f%z "$EVID/device-screen.jpeg" 2>/dev/null || echo '?') bytes)"
fi

# --- 3. unsigned install ---------------------------------------------------
if [ -f "$UNSIGNED_HAP" ]; then
  {
    echo "# hdc install -r entry-default-unsigned.hap"
    echo "# $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    hdcx install -r "$UNSIGNED_HAP" 2>&1
  } >"$EVID/install-unsigned.log"
  echo "   wrote evidence/install-unsigned.log"
fi

# --- 4. community-signed install + hilog root cause ------------------------
if [ -f "$COMMUNITY_SIGNED_HAP" ]; then
  hdcx shell "hilog -r" >/dev/null 2>&1 || true
  {
    echo "# hdc install -r entry-default-community-signed.hap"
    echo "# $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    hdcx install -r "$COMMUNITY_SIGNED_HAP" 2>&1
    echo
    echo "# hdc shell bm install -p /data/local/tmp/halolink.hap"
    "$HDC" -t "$TARGET" file send "$COMMUNITY_SIGNED_HAP" /data/local/tmp/halolink.hap >/dev/null 2>&1
    hdcx shell bm install -p /data/local/tmp/halolink.hap 2>&1
    sleep 1
    echo
    echo "# device hilog: root cause (foundation/HapVerify)"
    hdcx shell "hilog -x 2>/dev/null | grep -iE 'HapVerify|pkcs7|trusted root|BMS' | tail -20" 2>&1
  } >"$EVID/install-community-signed.log"
  echo "   wrote evidence/install-community-signed.log"
fi

# --- 5. hdc install variants attempted -------------------------------------
{
  echo "# hdc install -d (downgrade/debug flags) — variant attempts"
  hdcx install -d -r "$UNSIGNED_HAP" 2>&1 || true
  echo
  echo "# hdc install -g -r <community-signed>"
  hdcx install -g -r "$COMMUNITY_SIGNED_HAP" 2>&1 || true
  echo
  echo "# hdc install -h (supported flags on this hdc version)"
  "$HDC" install -h 2>&1 | head -20 || true
} >"$EVID/install-variants.log" 2>&1
echo "   wrote evidence/install-variants.log"

# --- 6. app process / bundle presence check --------------------------------
{
  echo "## bm dump -a | grep halolink (expect empty: never installed)"
  hdcx shell "bm dump -a | grep -i halolink" 2>&1 || true
  echo
  echo "## aa start attempt (expect failure: bundle not installed)"
  hdcx shell aa start -a EntryAbility -b com.halolink.display 2>&1 || true
} >"$EVID/launch-attempt.log" 2>&1
echo "   wrote evidence/launch-attempt.log"

echo
echo "== evidence collected in $EVID =="
ls -la "$EVID"
