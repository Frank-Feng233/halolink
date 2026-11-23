#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_tests.sh — host-compile and run the native Annex-B parser tests.
#
# The tested translation unit (entry/src/main/cpp/annexb_parser.cpp) is the exact
# code that ships inside libdecoder.so on the tablet, so this is a real unit test
# of the SPS/PPS extraction that OH_MD_KEY_CODEC_CONFIG depends on.
#
# Usage: test/native/run_tests.sh [stream.h264]
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/../.." && pwd)"
cd "$APP_DIR"

CXX="${CXX:-$(command -v clang++ || command -v g++ || true)}"
[ -n "$CXX" ] || { echo "no host C++ compiler found (clang++/g++)" >&2; exit 1; }

OUT_DIR="$APP_DIR/test/native/build"
mkdir -p "$OUT_DIR"
BIN="$OUT_DIR/test_annexb"
STREAM="${1:-$APP_DIR/test/stream.h264}"

echo "== compiling native annexb tests with $CXX =="
"$CXX" -std=c++17 -O2 -Wall -Wextra \
  -I "$APP_DIR/entry/src/main/cpp" \
  "$APP_DIR/test/native/test_annexb.cpp" \
  "$APP_DIR/entry/src/main/cpp/annexb_parser.cpp" \
  -o "$BIN"

echo "== running =="
if [ -f "$STREAM" ]; then
  "$BIN" "$STREAM"
else
  echo "NOTE: no H.264 stream at $STREAM (real-stream checks will be skipped)"
  "$BIN" "/nonexistent"
fi
