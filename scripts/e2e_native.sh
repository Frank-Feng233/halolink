#!/usr/bin/env bash
# HaloLink 原生模式端到端测试（无线直连 / hdc 转发）
#
# 用法:
#   bash scripts/e2e_native.sh                 # 无线直连（自动读平板 IP）
#   bash scripts/e2e_native.sh --usb           # 有线/无线调试：hdc fport + 127.0.0.1
#   bash scripts/e2e_native.sh --duration 120  # host 运行秒数
#   bash scripts/e2e_native.sh --web-fallback  # 同时验证 Web 备用通道
#
# 前置：平板已安装 HaloLink App（com.halolink.display），hdc 已连接。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

MODE="wifi"
DURATION=120
WEB_FALLBACK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --usb) MODE="usb"; shift ;;
    --duration) DURATION="${2:-120}"; shift 2 ;;
    --web-fallback) WEB_FALLBACK=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) warn "未知参数 $1"; exit 1 ;;
  esac
done

[ -x "$HOST_BIN" ] || { error "host 未构建: $HOST_BIN"; exit 1; }
mkdir -p demo/e2e
LOG=/tmp/halolink-e2e.log
: > "$LOG"

# shellcheck source=scripts/env.sh
log "== 1. 检查设备与 App =="
serial="${TABLET_SERIAL:-$(halolink_first_target)}"
[ -n "$serial" ] || { error "未发现设备，请先开启无线调试或插 USB"; exit 2; }
log "设备: $serial"
if ! "$HDC" -t "$serial" shell "bm dump -a" 2>/dev/null | tr -d '\r' | grep -q "$BUNDLE_NAME"; then
  error "平板上未安装 $BUNDLE_NAME，请先: bash harmony-app/scripts/deploy.sh --build"
  exit 3
fi

ip="$("$HDC" -t "$serial" shell "ifconfig wlan0" 2>/dev/null | tr -d '\r' | awk '/inet addr:/{print $2}' | cut -d: -f2 | head -1)"
TABLET_IP="${TABLET_IP:-$ip}"
[ -n "$TABLET_IP" ] && log "平板 IP: $TABLET_IP"

# shellcheck source=scripts/env.sh
log "== 2. 启动平板 App =="
"$HDC" -t "$serial" shell "aa force-stop $BUNDLE_NAME" >/dev/null 2>&1 || true
"$HDC" -t "$serial" shell "aa start -a $ABILITY_NAME -b $BUNDLE_NAME" 2>&1 | sed 's/^/  /'
sleep 2

if [ "$MODE" = "usb" ]; then
  log "== 3. hdc fport tcp:$FPORT_LOCAL -> 平板:$APP_PORT =="
  "$HDC" fport rm "tcp:$FPORT_LOCAL" >/dev/null 2>&1 || true
  "$HDC" -t "$serial" fport "tcp:$FPORT_LOCAL" "tcp:$APP_PORT" 2>&1 | sed 's/^/  /'
  CONNECT="127.0.0.1:$FPORT_LOCAL"
else
  CONNECT="$TABLET_IP:$APP_PORT"
  log "== 3. 无线直连 $CONNECT =="
fi

log "== 4. 启动 macOS host（连平板，--auto，${DURATION}s）=="
"$HOST_BIN" --connect "$CONNECT" --auto --http-port "$HTTP_PORT" --seconds "$DURATION" --verbose >"$LOG" 2>&1 &
HPID=$!
trap 'kill $HPID 2>/dev/null' EXIT

ok=0
for _ in $(seq 1 45); do
  if grep -q "READY" "$LOG" 2>/dev/null; then ok=1; break; fi
  if ! kill -0 "$HPID" 2>/dev/null; then break; fi
  sleep 1
done
if [ "$ok" != 1 ]; then
  error "host 未就绪，日志:"; tail -30 "$LOG"; exit 4
fi

# 等握手、首帧、虚拟屏就绪
sleep 8
echo
echo "===== host 日志关键行 ====="
grep -E "READY|tablet|hello|config|virtual display|placed|streaming|connected|first frame|IDR|error|ERROR" "$LOG" | head -25
echo

echo "===== 虚拟显示器 ====="
"$HOST_BIN" --list-displays 2>/dev/null | tail -4

echo
echo "===== 平板截图 ====="
"$HDC" -t "$serial" shell "snapshot_display -f /data/local/tmp/e2e.jpeg" >/dev/null 2>&1
"$HDC" -t "$serial" file recv /data/local/tmp/e2e.jpeg "demo/e2e/tablet-native-$(date +%H%M%S).jpeg" 2>&1 | tail -1
ls -la demo/e2e/ | tail -3

echo
echo "===== 状态 ====="
curl -s -m 2 "http://127.0.0.1:$HTTP_PORT/status" 2>/dev/null | head -c 600; echo

echo
echo "===== 提示 ====="
echo "  - 现在可以在平板上触摸/拖动来操作 Mac（会注入鼠标事件）"
echo "  - 在 Mac 上把窗口拖到右侧 'HaloLink Display' 虚拟屏即可看到扩展效果"
echo "  - host 将在 ${DURATION}s 后自动退出；也可 Ctrl-C"
wait $HPID 2>/dev/null || true
trap - EXIT
echo
echo "===== 收尾：清理 fport ====="
"$HDC" fport rm "tcp:$FPORT_LOCAL" >/dev/null 2>&1 || true
log "完成。日志: $LOG"
