#!/usr/bin/env bash
# HaloLink 一键启动
#
# 用法:
#   bash scripts/start.sh web                # Web 免安装模式（只在本机开 HTTP 服务，平板用浏览器打开）
#   bash scripts/start.sh web --open-tablet  # 同时自动在平板浏览器打开并进入全屏
#   bash scripts/start.sh wifi               # 无线直连：hdc 找平板 IP → 平板 App 作为 TCP 服务端
#   bash scripts/start.sh usb                # 有线/USB 或无线调试：hdc fport → 平板 App
#   bash scripts/start.sh web --background   # 后台运行（日志 /tmp/halolink-host.log）
#
# 其余参数原样传给 halolink-host（如 --width 2800 --height 1840 --fps 60 --bitrate 30000000）
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

MODE="${1:-web}"; shift || true
BACKGROUND=0
OPEN_TABLET=0
PASSTHRU=()
for a in "$@"; do
  case "$a" in
    --background|-b) BACKGROUND=1 ;;
    --open-tablet) OPEN_TABLET=1 ;;
    *) PASSTHRU+=("$a") ;;
  esac
done

if [ ! -x "$HOST_BIN" ]; then
  error "未找到 $HOST_BIN，请先构建: cd macos-host && swift build -c release && bash scripts/make_app.sh"
  exit 1
fi

case "$MODE" in
  web)
    ARGS=(--http-port "$HTTP_PORT" "${PASSTHRU[@]}")
    ;;
  wifi)
    eval "$(bash scripts/setup_device.sh "${PASSTHRU[@]}" 2>/dev/null | grep -E '^TABLET_')"
    [ -n "${TABLET_IP:-}" ] || { error "无线模式需要平板 IP（先 hdc tconn 或 --tcp <ip>:<port>）"; exit 2; }
    ARGS=(--connect "$TABLET_IP:$APP_PORT" --http-port "$HTTP_PORT")
    ;;
  usb)
    eval "$(bash scripts/setup_device.sh --fport --launch 2>/dev/null | grep -E '^TABLET_|^FORWARD')"
    [ "${FORWARD_OK:-0}" = "1" ] || { error "hdc fport 失败，无法建立 USB 通道"; exit 2; }
    ARGS=(--connect "127.0.0.1:$FPORT_LOCAL" --http-port "$HTTP_PORT")
    ;;
  *)
    error "未知模式: $MODE（可选 web|wifi|usb）"; exit 1 ;;
esac

if [ "$BACKGROUND" -eq 1 ]; then
  LOG="${LOG:-/tmp/halolink-host.log}"
  log "后台启动: $HOST_BIN ${ARGS[*]}  (日志 $LOG)"
  nohup "$HOST_BIN" "${ARGS[@]}" >"$LOG" 2>&1 &
  echo $! > /tmp/halolink-host.pid
  sleep 3
  sed -n '1,30p' "$LOG"
  if [ "$MODE" = web ] && [ "$OPEN_TABLET" -eq 1 ]; then
    bash scripts/tablet_open_url.sh "http://${HOST_LAN_IP:-}" 2>/dev/null || true
  fi
else
  log "启动: $HOST_BIN ${ARGS[*]}"
  exec "$HOST_BIN" "${ARGS[@]}"
fi
