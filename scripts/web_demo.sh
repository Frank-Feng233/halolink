#!/usr/bin/env bash
# Web 免安装模式一键演示：
#   1) 后台启动 halolink-host（默认 :8080，虚拟显示器 + MJPEG）
#   2) hdc 自动连接平板，在平板浏览器打开 Mac 的 Web 客户端
#   3) 可选：自动点一下触发全屏，并把平板当前画面截图到 demo/tablet-web.png
#
# 用法: bash scripts/web_demo.sh [--no-open]
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

NO_OPEN=0
[ "${1:-}" = "--no-open" ] && NO_OPEN=1

# 找 Mac 的局域网 IP（默认路由所在接口）
MAC_IP="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -1)"
if [ -n "$MAC_IP" ]; then
  MAC_IP="$(ifconfig "$MAC_IP" 2>/dev/null | awk '/inet /{print $2}' | head -1)"
fi
[ -n "${MAC_IP:-}" ] || { error "无法确定 Mac 局域网 IP"; exit 1; }
log "Mac 局域网 IP: $MAC_IP"

if [ ! -x "$HOST_BIN" ]; then
  error "未构建 host：cd macos-host && swift build -c release && bash scripts/make_app.sh"
  exit 1
fi

LOG=/tmp/halolink-host.log
log "后台启动 host（日志 $LOG）"
nohup "$HOST_BIN" --http-port "$HTTP_PORT" >"$LOG" 2>&1 &
echo $! > /tmp/halolink-host.pid

# 等 host 就绪
ok=0
for _ in $(seq 1 30); do
  if curl -s -m 1 -o /dev/null "http://127.0.0.1:$HTTP_PORT/healthz"; then ok=1; break; fi
  sleep 1
done
[ "$ok" = 1 ] || { error "host 未就绪，日志:"; tail -30 "$LOG"; exit 2; }
log "host 就绪: http://$MAC_IP:$HTTP_PORT/"

if [ "$NO_OPEN" -eq 0 ]; then
  eval "$(bash scripts/setup_device.sh 2>/dev/null | grep -E '^TABLET_')"
  if [ -n "${TABLET_SERIAL:-}" ]; then
    bash scripts/tablet_open_url.sh "http://$MAC_IP:$HTTP_PORT/"
    sleep 4
    # 点一下画面中央触发「首次点按进入全屏」
    "$HDC" -t "$TABLET_SERIAL" shell "uitest uiInput click 1400 1000" >/dev/null 2>&1 && log "已模拟点按（全屏）"
    sleep 2
    mkdir -p demo
    "$HDC" -t "$TABLET_SERIAL" shell "snapshot_display -f /data/local/tmp/halolink_web.jpeg" >/dev/null 2>&1
    "$HDC" -t "$TABLET_SERIAL" file recv /data/local/tmp/halolink_web.jpeg "demo/tablet-web.jpeg" >/dev/null 2>&1 \
      && log "平板截图已保存: demo/tablet-web.jpeg"
  else
    warn "未发现平板（跳过自动打开）。可手动在平板浏览器打开: http://$MAC_IP:$HTTP_PORT/"
  fi
fi

log "完成。停止 host: bash scripts/stop.sh"
