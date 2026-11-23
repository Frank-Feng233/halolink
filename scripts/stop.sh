#!/usr/bin/env bash
# 停止 HaloLink host / 清理 hdc 端口转发
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

if [ -f /tmp/halolink-host.pid ]; then
  pid="$(cat /tmp/halolink-host.pid)"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    log "已停止 host (pid $pid)"
  fi
  rm -f /tmp/halolink-host.pid
else
  pkill -f "halolink-host" 2>/dev/null && log "已停止 halolink-host" || true
fi

if [ -n "${HDC:-}" ] && [ -x "$HDC" ]; then
  "$HDC" fport rm "tcp:$APP_PORT" >/dev/null 2>&1 || true
  log "已清理 hdc fport tcp:$APP_PORT"
fi
