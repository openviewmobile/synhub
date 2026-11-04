#!/usr/bin/env bash
# r283 iPad 自适应布局审计：宿主侧截图泵（**显式 UDID**，不用 `booted`）。
#
# 为什么不能用 `tool/r132_ios_shot_poller.sh`：它写死 `booted`，而本机同时
# booted 了 iPhone 16 与 iPad Pro 11"（另一个代理在用 iPhone）⇒ `booted` 会选错设备。
#
# 用法：tool/r283_ipad_shot_poller.sh <UDID> [bundleId] [outDir]
set -u
UDID="${1:?需要 UDID}"
BID="${2:-com.openviewai.synhub.ios}"
OUT="${3:-/tmp/r283_ipad}"
mkdir -p "$OUT"
echo "[r283-poller] udid=$UDID bid=$BID out=$OUT"
i=0
while true; do
  C="$(xcrun simctl get_app_container "$UDID" "$BID" data 2>/dev/null)"
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
        if xcrun simctl io "$UDID" screenshot "$OUT/${n}_${name}.png" >/dev/null 2>&1; then
          printf '%s\n' "$name" > "$ACK"
          echo "[r283-poller] ${n}_${name}.png"
        else
          echo "[r283-poller] SCREENSHOT-FAIL $name"
        fi
      fi
    fi
  fi
  sleep 0.25
done
