#!/usr/bin/env bash
# 发现/连接鸿蒙平板，读取平板 IP，可选建立 hdc 端口转发并拉起 HaloLink App。
#
# 用法:
#   bash scripts/setup_device.sh                    # 使用当前已连接的设备
#   bash scripts/setup_device.sh --tcp 192.168.1.10:36659   # 无线调试：先 hdc tconn
#   bash scripts/setup_device.sh --fport            # 额外建立 tcp:9528 转发（有线/无线调试模式）
#   bash scripts/setup_device.sh --launch           # 尝试拉起已安装的 HaloLink App
#
# 输出（可 eval）：TABLET_SERIAL / TABLET_IP / FORWARD_OK
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

TCP_KEY=""
DO_FPORT=0
DO_LAUNCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tcp) TCP_KEY="${2:-}"; shift 2 ;;
    --fport) DO_FPORT=1; shift ;;
    --launch) DO_LAUNCH=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) warn "未知参数: $1"; exit 1 ;;
  esac
done

[ -n "$HDC" ] && [ -x "$HDC" ] || { error "未找到 hdc，请安装 HarmonyOS 命令行工具，或设置 HDC=..."; exit 1; }

if [ -n "$TCP_KEY" ]; then
  log "hdc tconn $TCP_KEY"
  "$HDC" tconn "$TCP_KEY" 2>&1 | sed 's/^/  /'
fi

serial="$(halolink_first_target)"
if [ -z "$serial" ]; then
  error "没有发现设备。请确认："
  error "  1) 平板已开启 开发者模式 + 无线调试（设置 → 系统 → 开发者选项），或已插 USB 线"
  error "  2) 已执行: bash scripts/setup_device.sh --tcp <平板IP>:<端口>"
  exit 2
fi

case "$serial" in
  *Unauthorized*) error "设备未授权：请在平板上点「允许调试」后重试"; exit 3 ;;
  *Offline*)      error "设备 Offline：请重新 hdc tconn / 重新插拔 USB"; exit 3 ;;
esac

# 多设备时允许用 DEVICE 指定
if [ -n "${DEVICE:-}" ]; then serial="$DEVICE"; fi
TABLET_SERIAL="$serial"
log "设备: $TABLET_SERIAL"

ip="$("$HDC" -t "$TABLET_SERIAL" shell "ifconfig wlan0" 2>/dev/null | tr -d '\r' \
      | awk '/inet addr:/{print $2}' | cut -d: -f2 | head -1)"
if [ -n "$ip" ]; then
  TABLET_IP="$ip"
  log "平板 Wi-Fi IP: $TABLET_IP"
else
  warn "未能从 wlan0 读取平板 IP（可能未连 Wi-Fi）；有线/USB 模式可忽略"
fi

FORWARD_OK=0
if [ "$DO_FPORT" -eq 1 ]; then
  "$HDC" fport rm "tcp:$FPORT_LOCAL" >/dev/null 2>&1 || true
  if "$HDC" -t "$TABLET_SERIAL" fport "tcp:$FPORT_LOCAL" "tcp:$APP_PORT" 2>&1 | grep -q "OK"; then
    FORWARD_OK=1
    log "hdc fport OK: Mac 127.0.0.1:$FPORT_LOCAL -> 平板 127.0.0.1:$APP_PORT"
  else
    error "hdc fport 失败（Mac 本地端口 $FPORT_LOCAL 可能被占用，可用 FPORT_LOCAL=xxxxx 覆盖）"
  fi
fi

if [ "$DO_LAUNCH" -eq 1 ]; then
  if "$HDC" -t "$TABLET_SERIAL" shell "bm dump -a" 2>/dev/null | tr -d '\r' | grep -q "$BUNDLE_NAME"; then
    log "拉起 App: $BUNDLE_NAME/$ABILITY_NAME"
    "$HDC" -t "$TABLET_SERIAL" shell "aa start -a $ABILITY_NAME -b $BUNDLE_NAME" 2>&1 | sed 's/^/  /'
  else
    warn "平板上未安装 $BUNDLE_NAME（可先 bash scripts/install_app.sh，或使用 Web 免安装模式）"
  fi
fi

printf 'TABLET_SERIAL=%q\nTABLET_IP=%q\nFORWARD_OK=%d\nFORWARD_PORT=%q\n' "$TABLET_SERIAL" "$TABLET_IP" "$FORWARD_OK" "$FPORT_LOCAL"
