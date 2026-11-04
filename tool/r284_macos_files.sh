#!/usr/bin/env bash
# r284：macOS「文件 / Drive 宽屏双栏 vs 窄屏单列」真像素跑法。
#
# 三件事：
#   ① 保宿主显示器不休眠（r131 实测：显示器一睡，Metal 不再出帧 ⇒
#      `RenderRepaintBoundary.toImage()` 的 Future 永不完成）；
#   ② 按阶段把窗口设成真尺寸（`SYNHUB_WINDOW_SIZE`，见 `MainFlutterWindow.swift`）；
#   ③ 把 App 沙箱容器里的 PNG 收出来（沙箱不许写 /tmp）。
#
# 用法：tool/r284_macos_files.sh [wide,narrow]
set -uo pipefail
export PATH="<flutter-sdk>/bin:$PATH"

PHASES="${1:-wide,narrow}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/r284_macos_files"
CONTAINER="$HOME/Library/Containers/com.openviewai.synhub.macos/Data/tmp/r284_macos_files"

URL="https://nas.example.com:5001"
ACCOUNT="demo_user"
PASSWORD="${SYNO_NAS_PASSWORD:?请先 export SYNO_NAS_PASSWORD}"  # 真实口令只从环境来

mkdir -p "$OUT"
caffeinate -d -i -u -t 7200 >/tmp/r284_caffeinate.log 2>&1 &
CAFF=$!
echo "[r284] caffeinate pid=$CAFF  phases=$PHASES"

RC_ALL=0
IFS=',' read -ra LIST <<< "$PHASES"
for PHASE in "${LIST[@]}"; do
  case "$PHASE" in
    wide)   SIZE="1280x860" ;;
    narrow) SIZE="420x900" ;;
    *) echo "[r284] 未知阶段 $PHASE"; RC_ALL=1; continue ;;
  esac
  LOG="/tmp/r284_run_${PHASE}.log"
  echo "[r284] === phase=$PHASE 窗口=$SIZE ==="
  # `flutter test -d macos` 用 `open` 拉起 App ⇒ **不继承环境变量**，
  # 所以尺寸同时写进容器内的文件（Swift 侧两路都读，见 MainFlutterWindow.swift）。
  mkdir -p "$CONTAINER"
  printf '%s\n' "$SIZE" > "$HOME/Library/Containers/com.openviewai.synhub.macos/Data/tmp/synhub_window_size.txt"
  cd "$ROOT"
  SYNHUB_WINDOW_SIZE="$SIZE" flutter test \
    integration_test/r284_macos_files_panes_test.dart -d macos \
    --dart-define="R284_PHASE=$PHASE" \
    --dart-define="SYNO_NAS_URL=$URL" \
    --dart-define="SYNO_NAS_ACCOUNT=$ACCOUNT" \
    --dart-define="SYNO_NAS_PASSWORD=$PASSWORD" 2>&1 | tee "$LOG"
  RC=${PIPESTATUS[0]}
  echo "[r284] phase=$PHASE rc=$RC"
  [ "$RC" -ne 0 ] && RC_ALL=$RC
  if [ -d "$CONTAINER" ]; then
    cp -f "$CONTAINER"/*.png "$OUT/" 2>/dev/null || true
    cp -f "$CONTAINER"/*.size.txt "$OUT/" 2>/dev/null || true
  fi
  HOOK="$HOME/Library/Containers/com.openviewai.synhub.macos/Data/tmp/r284_window_hook.txt"
  if [ -f "$HOOK" ]; then echo "[r284] 窗口钩子诊断："; cat "$HOOK"; cp -f "$HOOK" "$OUT/r284_window_hook_$PHASE.txt"; fi
  rm -f "$HOME/Library/Containers/com.openviewai.synhub.macos/Data/tmp/synhub_window_size.txt"
done

echo "[r284] 收图：$(ls -1 "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') 张 → $OUT"
ls -la "$OUT" 2>/dev/null || true
kill "$CAFF" 2>/dev/null || true
exit "$RC_ALL"
