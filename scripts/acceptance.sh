#!/usr/bin/env bash
# HaloLink 端到端验收脚本（Web 免安装模式）
#   1. 启动 host（虚拟显示器 + MJPEG :8080）
#   2. 检查虚拟显示器是否作为扩展屏上线
#   3. 检查 /status、/mjpg 帧流
#   4. 在平板浏览器打开 Web 客户端并全屏
#   5. 平板截图、模拟触摸、检查 host 是否收到输入
# 证据输出到 demo/
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/env.sh
mkdir -p demo

HOST_BIN="${HOST_BIN:-$PWD/macos-host/.build/release/halolink-host}"
[ -x "$HOST_BIN" ] || { error "host 未构建: $HOST_BIN"; exit 1; }

MAC_IP="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -1)"
MAC_IP="$(ifconfig "$MAC_IP" 2>/dev/null | awk '/inet /{print $2}' | head -1)"
[ -n "${MAC_IP:-}" ] || { error "无法确定 Mac 局域网 IP"; exit 1; }
log "Mac IP: $MAC_IP"

LOG=/tmp/halolink-acceptance-host.log
: > "$LOG"
log "启动 host（--seconds 90）"
"$HOST_BIN" --http-port "$HTTP_PORT" --seconds 90 --verbose >"$LOG" 2>&1 &
HPID=$!
cleanup() { kill "$HPID" 2>/dev/null; }
trap cleanup EXIT

# 等待 READY
ok=0
for _ in $(seq 1 40); do
  if grep -q "READY" "$LOG" 2>/dev/null && curl -s -m 1 -o /dev/null "http://127.0.0.1:$HTTP_PORT/healthz"; then ok=1; break; fi
  if ! kill -0 "$HPID" 2>/dev/null; then error "host 提前退出:"; tail -30 "$LOG"; exit 2; fi
  sleep 1
done
[ "$ok" = 1 ] || { error "host 未就绪:"; tail -40 "$LOG"; exit 2; }
log "host READY，日志:"; grep -E "READY|display|http" "$LOG" | head -10

# 显示器数量（虚拟屏应该让显示器数量 +1）
echo "--- 当前显示器 ---" | tee demo/acceptance-displays.txt
"$HOST_BIN" --list-displays 2>/dev/null | tee -a demo/acceptance-displays.txt || true

# /status
echo "--- /status ---" | tee demo/acceptance-status.json
curl -s -m 3 "http://127.0.0.1:$HTTP_PORT/status" | tee -a demo/acceptance-status.json; echo

# /mjpg 抓 2 秒
log "抓取 MJPEG 流 2s ..."
curl -s -m 2 "http://127.0.0.1:$HTTP_PORT/mjpg" -o /tmp/acc_mjpg.bin 2>/dev/null
python3 - <<'EOF'
d=open('/tmp/acc_mjpg.bin','rb').read()
n=d.count(b'\xff\xd8\xff')
print(f"mjpg bytes={len(d)} jpeg_frames={n}")
open('demo/acceptance-mjpg-stats.txt','w').write(f"bytes={len(d)} jpeg_frames={n}\n")
assert n>10, "MJPEG 帧数过少"
EOF

# 平板端
eval "$(bash scripts/setup_device.sh 2>/dev/null | grep -E '^TABLET_')"
if [ -n "${TABLET_SERIAL:-}" ]; then
  log "在平板打开: http://$MAC_IP:$HTTP_PORT/"
  bash scripts/tablet_open_url.sh "http://$MAC_IP:$HTTP_PORT/"
  sleep 4
  # 首次点按：进入全屏 + 产生 touch 事件
  "$HDC" -t "$TABLET_SERIAL" shell "uitest uiInput click 1400 1000" >/dev/null 2>&1 || true
  sleep 3
  "$HDC" -t "$TABLET_SERIAL" shell "snapshot_display -f /data/local/tmp/acceptance.jpeg" >/dev/null 2>&1
  "$HDC" -t "$TABLET_SERIAL" file recv /data/local/tmp/acceptance.jpeg demo/tablet-web.jpeg >/dev/null 2>&1 \
    && log "平板截图: demo/tablet-web.jpeg"
  # 再点两下/拖动，验证输入到达 host
  "$HDC" -t "$TABLET_SERIAL" shell "uitest uiInput swipe 1200 900 1600 1200 400" >/dev/null 2>&1 || true
  sleep 1
  echo "--- host 日志中的输入事件 ---"
  grep -iE "touch|input|inject" "$LOG" | tail -10 | tee demo/acceptance-input.txt
  if grep -qiE "input|touch" "$LOG"; then log "✅ 平板触摸事件已到达 Mac host"; else warn "⚠️ host 日志未见输入事件"; fi
else
  warn "未发现平板，跳过平板端验收"
fi

log "验收完成。证据目录: demo/"
ls -la demo/ 2>/dev/null | head