#!/bin/bash
# Build webhost (single Swift file + ObjC bridge header for CGVirtualDisplay private API).
set -euo pipefail
cd "$(dirname "$0")"

swiftc -O webhost.swift \
  -Xcc -fmodule-map-file=module.modulemap \
  -Xcc -I. \
  -framework ScreenCaptureKit \
  -framework VideoToolbox \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework AppKit \
  -framework ImageIO \
  -framework Network \
  -framework Foundation \
  -o webhost

echo "built: $(pwd)/webhost"
