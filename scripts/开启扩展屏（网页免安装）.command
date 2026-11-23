#!/bin/bash
# 双击启动：Web 免安装模式（平板浏览器打开地址即可）
cd "$(dirname "$0")/.." || exit 1
exec bash scripts/start.sh web
