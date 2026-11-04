#!/usr/bin/env bash
# r132 iOS 逐屏审计：宿主侧截图泵。
#
# 装置：模拟器上跑的 integration_test 在每个"界面"写好 req.txt（界面名），
# 宿主脚本看到 req 就把**设备帧缓冲**截下来（`xcrun simctl io booted screenshot`，
# 与宿主锁屏无关），再写 ack.txt 放行下一步 ⇒ 1:1 确定性映射，不靠 sleep 猜。
#
# 用法：tool/r132_ios_shot_poller.sh [bundleId] [outDir]
set -u
BID="${1:-com.openviewai.synhub.ios}"
OUT="${2:-/private/tmp/r132_ios_ui}"
mkdir -p "$OUT"
echo "[poller] watching $BID -> $OUT"
i=0
while true; do
  C="$(xcrun simctl get_app_container booted "$BID" data 2>/dev/null)"
  if [ -z "${C:-}" ]; then sleep 0.5; continue; fi
  REQ="$C/tmp/r132_ios_ui/req.txt"
  ACK="$C/tmp/r132_ios_ui/ack.txt"
  if [ -f "$REQ" ]; then
    name="$(tr -d '\r\n' < "$REQ" 2>/dev/null || true)"
    if [ -n "$name" ]; then
      ack=""
      [ -f "$ACK" ] && ack="$(tr -d '\r\n' < "$ACK" 2>/dev/null || true)"
      if [ "$ack" != "$name" ]; then
        i=$((i + 1))
        n="$(printf '%03d' "$i")"
        sleep 0.35
        if xcrun simctl io booted screenshot "$OUT/${n}_${name}.png" >/dev/null 2>&1; then
          printf '%s\n' "$name" > "$ACK"
          echo "[poller] ${n}_${name}.png"
        else
          echo "[poller] SCREENSHOT-FAIL $name"
        fi
      fi
    fi
  fi
  sleep 0.25
done
