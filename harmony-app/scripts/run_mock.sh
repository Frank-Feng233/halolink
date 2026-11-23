#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_mock.sh — run the Python mock host against the tablet.
#
# The tablet is the TCP server (0.0.0.0:9528); this script finds the tablet IP
# (from DEVICE=ip:port), makes sure an H.264 test stream exists and streams it.
#
# Usage: scripts/run_mock.sh [extra mock_host.py args...]
#   TABLET_IP=192.168.1.10 scripts/run_mock.sh --no-stream
#   scripts/run_mock.sh --fps 60 --duration 30
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

TABLET_IP="${TABLET_IP:-${DEVICE%%:*}}"
STREAM="$APP_DIR/test/stream.h264"
MOCK="$APP_DIR/test/mock_host.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found" >&2
  exit 1
fi

if [ ! -f "$STREAM" ]; then
  echo "== generating H.264 test stream =="
  python3 "$MOCK" --generate --stream "$STREAM" --width 2800 --height 1840 --fps 30
fi

echo "== HaloLink mock host =="
echo "   tablet : $TABLET_IP:$PORT"
echo "   stream : $STREAM"
echo "   note   : for USB/wireless-debug mode run"
echo "            $HDC fport tcp:$PORT tcp:$PORT"
echo "            and pass --host 127.0.0.1 (fport maps Mac:$PORT -> device:$PORT)"
echo

exec python3 "$MOCK" --host "$TABLET_IP" --port "$PORT" --stream "$STREAM" "$@"
