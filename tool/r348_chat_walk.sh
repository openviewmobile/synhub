#!/bin/bash
# r348 聊天页专用的稳健走查：聊天页 `uiautomator dump` 会间歇 `could not get idle state`，
# 而底栏/菜单是**浮层**，坐标一漂就会点到背景的频道行（实测：点「邀请」进了 DM 房间）。
# 所以每一步都：**先 dump 成功 → 从树里取坐标 → 点 → 截图 → 确认回到频道页**。
#
# 用法：tool/r348_chat_walk.sh menu <y> <名字>   # 打开 ⋮ 菜单并点 y 处的条目
#       tool/r348_chat_walk.sh room             # 回到 #1 频道页（失败时报错）
#       tool/r348_chat_walk.sh fg               # 确认前台是本 App
set -uo pipefail
cd "$(dirname "$0")/.."
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
export ADB
SHOTS=${SHOTS:-/tmp/r348_ui}
UI=tool/r298_ui.sh
XML=/tmp/r298_ui.xml

dump_retry() { # 最多 8 次
  local i
  for i in $(seq 1 8); do
    if $UI dump >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

assert_fg() {
  local cur
  cur=$($ADB shell dumpsys activity activities 2>/dev/null | grep -m1 -oE 'com\.openviewai\.synhub/[A-Za-z0-9_.]+')
  [ -n "$cur" ] || { echo "FG-LOST: 前台不是本 App" >&2; exit 4; }
}

case "${1:-}" in
  room)
    # 回到频道页：树里要有「发消息」输入框或频道标题
    for i in 1 2 3 4; do
      dump_retry || true
      if grep -q '发消息\|在频道内搜索' "$XML" 2>/dev/null; then
        echo "ROOM-OK"; exit 0
      fi
      # ★ 用**应用内**返回箭头（(85,200)）而不是系统返回键：实测系统返回键在
      #   "这一页其实没被推起来"的情况下会一路退到桌面（把 App 送进后台）。
      $ADB shell input tap 85 200; sleep 2
    done
    echo "ROOM-FAIL: 4 次都没回到频道页" >&2; exit 5
    ;;
  menu)
    y=${2:?需要 y}; name=${3:?需要名字}
    assert_fg
    $ADB shell input tap 1062 200; sleep 3
    dump_retry || { echo "MENU-DUMP-FAIL: 打不开菜单或 dump 不成功" >&2; exit 6; }
    grep -q '搜索此频道' "$XML" || { echo "MENU-NOT-OPEN: 树里没有「搜索此频道」⇒ ⋮ 没开菜单" >&2; exit 7; }
    $ADB shell input tap 866 "$y"; sleep 5
    n=$(ls -1 "$SHOTS" 2>/dev/null | grep -cE '^[0-9]{3}_.*\.png$'); n=$((n+1))
    f=$(printf '%s/%03d_%s.png' "$SHOTS" "$n" "$name")
    $ADB exec-out screencap -p > "$f"
    echo "SHOT $f $(wc -c < "$f" | tr -d ' ')B"
    ;;
  fg) assert_fg && echo "FG-OK" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
