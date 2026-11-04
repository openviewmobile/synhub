#!/usr/bin/env bash
# tool/device_ui.sh —— 真机 UI 驱动：**坐标自动换算 + 到位再走下一步**
#
# ★ 第 41 轮教训（血的）：本机 `wm size` 报
#     Physical size: 1312x2848      ← `input tap` 按**物理**空间注入事件
#     Override size: 1148x2492      ← `screencap` 给的是**override**空间
#   ⇒ 直接拿截图坐标去 tap 会**系统性偏移**（比例 1.1429）：点 `home` 行(y=855)
#     实际落在 override 的 y=752 = `docker` 行。此前连续 4 次"导航失败"的真因。
#   本脚本把换算收口在这里，**调用方永远只用截图坐标**。
#
# 用法：
#   tool/device_ui.sh ratio                 # 打印换算比例（自证用）
#   tool/device_ui.sh tap 515 855           # 截图坐标
#   tool/device_ui.sh swipe 656 1800 656 900 300
#   tool/device_ui.sh shot /tmp/x.png
#   tool/device_ui.sh waitlog 'fileThumb' 20   # 等到日志出现（秒），超时非零退出
#   tool/device_ui.sh settle 6              # 单纯等待
set -euo pipefail

ADB=(adb ${ANDROID_SERIAL:+-s "$ANDROID_SERIAL"})

_ratio() {
  local phys ovr
  phys=$("${ADB[@]}" shell wm size | awk '/Physical size/{print $3}')
  ovr=$("${ADB[@]}" shell wm size | awk '/Override size/{print $3}')
  [ -n "${ovr:-}" ] || ovr="$phys"
  python3 - "$phys" "$ovr" <<'PY'
import sys
p = sys.argv[1].split('x'); o = (sys.argv[2] or sys.argv[1]).split('x')
print(float(p[0]) / float(o[0]))
PY
}
# ★★ 结论修正（第 41 轮实测，血的教训）：
#   `input tap` 用的是**与 `screencap` 相同的显示空间**（override 1148x2492）
#   ⇒ **直接用截图坐标，不要换算**。
#   我一度按 `Physical/Override = 1.1429` 去换算，结果底栏 tab（截图 y=2380）
#   被我点到物理 y=2720（已经在 tab 栏下方）⇒ "怎么点都不中"，我误判成"坐标问题"。
#   实测反证：`input tap 574 2380`（原始坐标）→ `[route] shell tab=AppTab.photos` ✓。
#   只有确认某个 ROM 真的按物理空间注入时，才用 `DEVICE_UI_SCALE=<factor>` 覆盖。
R="${DEVICE_UI_SCALE:-1}"
_c() { python3 -c "print(int(round($1*$R)))"; }

case "${1:-}" in
  ratio) echo "$R" ;;
  tap)
    x=$(_c "$2"); y=$(_c "$3")
    echo "tap 截图($2,$3) → 物理($x,$y)"
    "${ADB[@]}" shell input tap "$x" "$y" ;;
  swipe)
    x1=$(_c "$2"); y1=$(_c "$3"); x2=$(_c "$4"); y2=$(_c "$5")
    echo "swipe 截图($2,$3)→($4,$5) 物理($x1,$y1)→($x2,$y2)"
    "${ADB[@]}" shell input swipe "$x1" "$y1" "$x2" "$y2" "${6:-300}" ;;
  shot) "${ADB[@]}" exec-out screencap -p > "$2"; ls -l "$2" | awk '{print $5, $9}' ;;
  settle) sleep "${2:-2}" ;;
  waitlog)
    pat="${2:?pattern}"; timeout="${3:-20}"; i=0
    while [ "$i" -lt "$timeout" ]; do
      if "${ADB[@]}" logcat -d 2>/dev/null | grep -qE "$pat"; then echo "✓ 等到：$pat"; exit 0; fi
      sleep 1; i=$((i+1))
    done
    echo "✗ 超时未见：$pat"; exit 3 ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
