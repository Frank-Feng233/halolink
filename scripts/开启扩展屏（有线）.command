#!/bin/bash
# 双击启动：USB 有线模式（平板插着 USB 线）
cd "$(dirname "$0")/.." || exit 1
echo "=============================================="
echo " HaloLink 扩展屏 - 有线模式"
echo " 平板请先用 USB 线连到 Mac，并打开平板上的 HaloLink App"
echo "=============================================="
exec bash scripts/start.sh usb
