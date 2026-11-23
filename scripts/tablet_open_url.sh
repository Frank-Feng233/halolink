#!/usr/bin/env bash
# 在平板浏览器里打开一个 URL（用于 Web 免安装模式 / 调试）
#
# 用法: bash scripts/tablet_open_url.sh http://<mac-ip>:8080/
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

URL="${1:-http://127.0.0.1:$HTTP_PORT/}"
serial="${TABLET_SERIAL:-$(halolink_first_target)}"
[ -n "$serial" ] || { error "没有发现设备（先运行 scripts/setup_device.sh）"; exit 2; }

log "在平板打开: $URL"
"$HDC" -t "$serial" shell "aa start -A ohos.want.action.viewData -U '$URL'" 2>&1 | sed 's/^/  /'

# 可选：如果页面实现了「首次点按进入全屏」，静默点一下屏幕中央触发全屏
if [ "${TAP_FULLSCREEN:-0}" = "1" ]; then
  sleep 3
  "$HDC" -t "$serial" shell "uitest uiInput click 1400 1000" >/dev/null 2>&1 && log "已模拟点按（触发全屏）"
fi
