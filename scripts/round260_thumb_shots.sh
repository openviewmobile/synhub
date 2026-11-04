#!/usr/bin/env bash
# 第 260 轮：缩略图/封面 真机取证脚本（**只读**）
#
# 用途：把"修复前/修复后"的同一批界面用**同样的角度**拍下来做像素对照
#       （AGENTS §5：布局断言证明不了渲染，要看像素；§1.6 的"before/after 同口径"）。
#
# 只做三件事：adb shell input（点击/滑动/返回键）、screencap 抓图、打印落盘路径。
# **不会**：装/卸 App（§2.0.1）、跑 integration_test、对 NAS 发任何写动词。
#
# 用法：
#   scripts/round260_thumb_shots.sh <前缀>        # 例如 before / after
#   例：scripts/round260_thumb_shots.sh after     # → /tmp/after_1_files_root.png …
#
# 前置：真机已连（`adb devices` 有 device）、App 已登录、屏幕已点亮。
# 注意：本脚本里的坐标取自 1148x2492 的 Honor LGE-AN10；换机要重新量（见文件末"坐标怎么量"）。
set -uo pipefail

PREFIX="${1:-shot}"
SERIAL="${2:-}"
ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")
OUT=/tmp

die() { echo "✗ $*" >&2; exit 1; }

"${ADB[@]}" get-state >/dev/null 2>&1 || die "设备未连接（先 adb devices）"

# 唤醒 + 回桌面再进 App，保证每次都从同一状态开始
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP >/dev/null
sleep 1
"${ADB[@]}" shell am force-stop com.openviewai.synhub >/dev/null
"${ADB[@]}" shell am start -n com.openviewai.synhub/.MainActivity >/dev/null 2>&1
sleep 6

shot() {  # shot <名字>
  local f="$OUT/${PREFIX}_$1.png"
  "${ADB[@]}" exec-out screencap -p > "$f" || die "抓图失败 $f"
  echo "  → $f ($(wc -c < "$f") B)"
}
tap() { "${ADB[@]}" shell input tap "$1" "$2"; sleep "${3:-3}"; }
scroll_down() { "${ADB[@]}" shell input swipe 600 1900 600 900 300; sleep 3; }
back() { "${ADB[@]}" shell input keyevent KEYCODE_BACK; sleep 3; }

echo "[$PREFIX] ① Files 根（子目录入口 + 文件工具中文残留对照）"
tap 344 2385 4            # 底部导航 Files
shot 1_files_root

echo "[$PREFIX] ② home 目录（文件夹封面：Photos/ebooktest/pictest 有拼图，Music/Drive 待验）"
tap 300 1044 4            # 共享目录第二行 = home
shot 2_home

echo "[$PREFIX] ③ home/Drive（office 三类文档缩略图）"
tap 300 1180 6            # home 第三行 = Drive
shot 3_drive_office
back

echo "[$PREFIX] ④ home/Music（音频内嵌封面）"
tap 300 1530 6            # home 第五行 = Music（17 个 mp3）
shot 4_music_audio
back

echo "[$PREFIX] ⑤ home/Video（视频抽帧缩略图；含 4.4GB MKV 与 AVI）"
scroll_down
tap 300 1540 10           # 滚动后 Video 行（给大文件抽帧留时间）
shot 5_video
back

echo "[$PREFIX] ⑥ Photos（相册封面 + 其中的视频缩略图）"
tap 586 2385 6            # 底部导航 Photos
shot 6_photos

echo "[$PREFIX] 完成。判定要**逐像素**看，别只看文件存在：视频行应是首帧、"
echo "        office 行应是首页渲染/预览图、Music 行应是专辑封面、无封面时必须是图标。"
echo
echo "坐标怎么量（换机/改版后）："
echo "  1) adb exec-out screencap -p > /tmp/x.png  2) 读图看目标行的 y 中心"
echo "  3) 本机 1148x2492 的参考值：底部导航 y≈2385（Chat 100/Files 344/Photos 700/"
echo "     Workspace 802/Me 1043）；共享目录行 docker y≈868、home y≈1044；"
echo "     home 内 Books 830 / Download 1005 / Drive 1180 / ebooktest 1355 / Music 1530；"
echo "     滚动一屏后 Video y≈1540。"
