#!/bin/bash
# r348 真机走查驱动：把「dump → 按 desc 点 → 截图 → 记日志」串成一条命令。
#
# 用法（每条命令都自带一次新鲜 dump，避免拿旧坐标点错元素）：
#   tool/r348_walk.sh s <名字>        # 截图到 $SHOTS/NNN_<名字>.png 并记一行日志
#   tool/r348_walk.sh t <desc 前缀>    # dump + 按 desc 前缀点中心
#   tool/r348_walk.sh tl <text>       # 按 text 前缀点（有些控件只有 text 没 desc）
#   tool/r348_walk.sh bk              # 返回键
#   tool/r348_walk.sh sw <x1> <y1> <x2> <y2>   # 滑动
#   tool/r348_walk.sh wt <秒>         # 等
#   tool/r348_walk.sh list            # 列当前可点元素（转调 r298_ui.sh）
#   tool/r348_walk.sh note <文字>      # 往日志写一行说明
#
# 环境变量：SHOTS（默认 /tmp/r348_ui）、LOG（默认 $SHOTS/walk.log）
# 纪律：复用 r298_ui.sh 的新鲜度闸门；找不到目标**报错退出**，不许静默点 (0,0)。
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="<flutter-sdk>/bin:$PATH"
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
export ADB
SHOTS=${SHOTS:-/tmp/r348_ui}
LOG=${LOG:-$SHOTS/walk.log}
UI=tool/r298_ui.sh
N=${N:-0}
mkdir -p "$SHOTS"

_step() { # 序号：按目录里已有的 SHOT 数自增（跨进程调用也不会重号）
  N=$(ls -1 "$SHOTS" 2>/dev/null | grep -cE '^[0-9]{3}_.*\.png$')
  N=$((N + 1))
  printf '%03d' "$N"
}

case "${1:-}" in
  s)
    name=${2:?需要名字}
    n=$(_step)
    f="$SHOTS/${n}_${name}.png"
    $ADB exec-out screencap -p > "$f"
    sz=$(wc -c < "$f" | tr -d ' ')
    if [ "$sz" -lt 1000 ]; then
      echo "SHOT-SUSPECT: $f 只有 ${sz}B（§2.0.37 安全输入法？）" >&2
    fi
    printf 'SHOT %s %sB\n' "$f" "$sz" | tee -a "$LOG"
    echo "$n" > "$SHOTS/.seq"
    ;;
  t)
    desc=${2:?需要 desc 前缀}
    $UI dump >/dev/null || exit 1
    xy=$($UI where "$desc" 2>/dev/null) || { echo "TAP-MISS: 树里没有 desc 以「$desc」开头的可点元素" >&2; exit 3; }
    $ADB shell input tap $xy
    printf 'TAP  %-30s @ %s\n' "$desc" "$xy" | tee -a "$LOG"
    ;;
  tl)
    txt=${2:?需要 text 前缀}
    $UI dump >/dev/null || exit 1
    xy=$(python3 - "$SHOTS/../r298_ui.xml" "$txt" <<'PY' 2>/dev/null
import re, sys, html
try:
    xml = open('/tmp/r298_ui.xml', encoding='utf-8', errors='replace').read()
except OSError:
    sys.exit(3)
want = html.unescape(sys.argv[2]); best = None
for m in re.finditer(r'<node[^>]*>', xml):
    tag = m.group(0)
    t = re.search(r'text="([^"]*)"', tag)
    d = re.search(r'content-desc="([^"]*)"', tag)
    lab = html.unescape(t.group(1)) if t else ''
    if not lab:
        lab = html.unescape(d.group(1)) if d else ''
    if not lab.startswith(want):
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if not b:
        continue
    x1, y1, x2, y2 = map(int, b.groups())
    key = (0 if 'clickable="true"' in tag else 1, (x2-x1)*(y2-y1))
    if best is None or key < best[0]:
        best = (key, (x1+x2)//2, (y1+y2)//2, lab)
if best is None:
    sys.exit(3)
print(best[1], best[2])
PY
)
    [ -n "$xy" ] || { echo "TAP-MISS: 树里没有以「$txt」开头的 text/desc" >&2; exit 3; }
    $ADB shell input tap $xy
    printf 'TAPtext %-27s @ %s\n' "$txt" "$xy" | tee -a "$LOG"
    ;;
  bk)
    $ADB shell input keyevent 4
    echo 'BACK' | tee -a "$LOG"
    ;;
  sw)
    $ADB shell input swipe "$2" "$3" "$4" "$5" "${6:-400}"
    printf 'SWIPE %s %s %s %s\n' "$2" "$3" "$4" "$5" | tee -a "$LOG"
    ;;
  wt)
    sleep "${2:-3}"
    ;;
  list)
    $UI dump >/dev/null || exit 1
    $UI list
    ;;
  note)
    printf 'NOTE %s\n' "${2:-}" | tee -a "$LOG"
    ;;
  fg)
    # 确认前台是本 App（§2.0.41：每步先确认前台）
    #
    # ★★★ 仪器⑰（r349 实测修正）：**旧实现是错的** —— 它把整份
    # `dumpsys activity activities` 拿去 grep 我们的包名，而我们的包名在这份
    # 输出里会出现在**任务历史 / 最近任务 / mLastPausedActivity** 等一堆地方，
    # 所以**无论前台是谁都会打印我们的包名**（构造性假阳性）。
    # 实测：`com.hihonor.systemmanager` 抢到前台时，本函数仍报
    # `FG com.openviewai.synhub/.MainActivity`，差点让我把**系统管理器的界面**
    # 当成我们 App 的界面来读。
    # ⇒ 只认 **resumed/top-resumed** 那一行的**真实 owner**。
    cur=$($ADB shell dumpsys activity activities 2>/dev/null \
      | grep -m1 -oE "(mResumedActivity|topResumedActivity).*" \
      | grep -oE "[a-zA-Z0-9_.]+/[A-Za-z0-9_.$]+" | head -1)
    printf 'FG %s\n' "${cur:-未知}" | tee -a "$LOG"
    case "$cur" in
      com.openviewai.synhub/*) ;;
      *) printf 'FG-WARN 前台不是本 App，禁止拿这一屏当证据\n' | tee -a "$LOG" ;;
    esac
    ;;
  *)
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
