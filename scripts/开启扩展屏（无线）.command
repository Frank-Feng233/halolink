#!/bin/bash
# 双击启动：同一 Wi-Fi 无线直连模式
cd "$(dirname "$0")/.." || exit 1
echo "=============================================="
echo " HaloLink 扩展屏 - 无线模式"
echo " 平板与 Mac 需在同一 Wi-Fi，并打开平板上的 HaloLink App"
echo "=============================================="
exec bash scripts/start.sh wifi
