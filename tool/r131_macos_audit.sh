#!/usr/bin/env bash
# r131：macOS 逐屏截图审计的**跑法**（两件事：保宿主显示器不休眠 + 跑完把 PNG 收出来）。
#
# 为什么必须 `caffeinate`：本机宿主会话常处于**锁屏/显示器休眠**；
# 一旦显示器休眠，Metal 图层就不再出帧 ⇒ `RenderRepaintBoundary.toImage()`
# 的 Future **永不完成**，整轮走查会在某一张截图上静默吊死
# （r131 实测：第 9 张卡住 5 分钟、App 进程 CPU 0%）。
#
# 用法：
#   tool/r131_macos_audit.sh                 # 全跑
#   tool/r131_macos_audit.sh files,notes     # 只跑某几组
#   AUDIT_MODE=mock tool/r131_macos_audit.sh chat   # 对 Mock 站跑（可进频道）
set -uo pipefail
export PATH="<flutter-sdk>/bin:$PATH"

ONLY="${1:-}"
MODE="${AUDIT_MODE:-real}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/r131_macos_ui"
CONTAINER="$HOME/Library/Containers/com.openviewai.synhub.macos/Data/tmp/macwalk_r131"

URL="https://nas.example.com:5001"
ACCOUNT="demo_user"
PASSWORD="${SYNO_NAS_PASSWORD:-}"  # 真实口令只从环境来，不落库
if [ "$MODE" = "mock" ]; then
  URL="http://127.0.0.1:18080"
  ACCOUNT="mockuser"
  PASSWORD="mockpass"
fi

if [ "$MODE" != "mock" ] && [ -z "$PASSWORD" ]; then
  echo "[r131] 需要 SYNO_NAS_PASSWORD：export SYNO_NAS_PASSWORD=… 后再跑" >&2
  exit 2
fi

# ① 宿主别睡：显示器 + 系统 + 声明用户活动
caffeinate -d -i -u -t 10800 >/tmp/r131_caffeinate.log 2>&1 &
CAFF=$!
echo "[r131] caffeinate pid=$CAFF"

mkdir -p "$OUT"
LOG="/tmp/r131_run_${MODE}${ONLY:+_$ONLY}.log"

# ② 跑（用例内所有 define 都有默认值，但这里显式传，避免与 mock 串台）
ARGS=(integration_test/macos_ui_audit_test.dart -d macos
  --dart-define="AUDIT_MODE=$MODE"
  --dart-define="SYNO_NAS_URL=$URL"
  --dart-define="SYNO_NAS_ACCOUNT=$ACCOUNT"
  --dart-define="SYNO_NAS_PASSWORD=$PASSWORD")
[ -n "$ONLY" ] && ARGS+=(--dart-define="AUDIT_ONLY=$ONLY")

cd "$ROOT"
flutter test "${ARGS[@]}" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
echo "[r131] flutter test rc=$RC"

# ③ 把 App 沙箱容器里的 PNG 收出来（沙箱**不许**写 /tmp，只能容器内出图再拷）
if [ -d "$CONTAINER" ]; then
  cp -f "$CONTAINER"/*.png "$OUT/" 2>/dev/null || true
  cp -f "$CONTAINER"/_ledger.json "$OUT/" 2>/dev/null || true
fi
echo "[r131] 收图：$(ls -1 "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') 张 → $OUT"
echo "[r131] 日志：$LOG"

kill "$CAFF" 2>/dev/null || true
exit "$RC"
