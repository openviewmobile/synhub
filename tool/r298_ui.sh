#!/bin/bash
# r298 真机 UI 助手：用 uiautomator 无障碍树精确定位 Flutter 元素（不再猜坐标）。
# 用法：
#   tool/r298_ui.sh dump                 # 重新抓一份树到 /tmp/r298_ui.xml
#   tool/r298_ui.sh list                 # 列出可点击元素(desc + 中心点)
#   tool/r298_ui.sh tap "<desc 前缀>"     # 按 desc 前缀点它的中心
#   tool/r298_ui.sh where "<desc 前缀>"   # 打印中心点
#   tool/r298_ui.sh text ""              # 列出非空 text（配 dump）
# 判据：找不到目标必须**报错退出**，不许静默点 (0,0)。
#
# ★★ 第 299 轮修的两个坑（都是"假绿"）：
# ① 旧版是 `uiautomator dump ... || true` 再 `[ -s "$XML" ]` ——
#    而 `[ -s ]` 判的是**本地**文件！真机 dump 失败时（实测
#    `ERROR: could not get idle state.`，**根本不写 sdcard 文件**）
#    本地还留着 22:35 的旧树 ⇒ 探针连续一小时喂我"确认关闭「flt-p7m…」"的幽灵弹层，
#    我据此白绕了好几轮。**现在：先删本地和远端 → dump → 必须远端文件存在且拉回非空 →
#    才认，且写时间戳**；失败重试 3 次后**报错退出**。
# ② `list`/`where`/`tap` 复用旧树会点到错元素 ⇒ 加 **60s 新鲜度闸门**。
set -uo pipefail

XML=/tmp/r298_ui.xml
STAMP=$XML.stamp
ADB=${ADB:-adb}
FRESH_MAX=${FRESH_MAX:-60}   # 秒；老于它就拒绝复用

dump() {
  local i out
  rm -f "$XML"
  for i in 1 2 3; do
    $ADB shell rm -f /sdcard/ui.xml >/dev/null 2>&1
    out=$($ADB shell uiautomator dump /sdcard/ui.xml 2>&1)
    if ! $ADB shell ls /sdcard/ui.xml >/dev/null 2>&1; then
      echo "DUMP-FAIL(第 $i/3 次): ${out##*$'\n'}" >&2
      sleep 1
      continue
    fi
    if ! $ADB pull /sdcard/ui.xml "$XML" >/dev/null 2>&1 || [ ! -s "$XML" ]; then
      echo "DUMP-FAIL(第 $i/3 次): 拉回来的树为空" >&2
      sleep 1
      continue
    fi
    date +%s > "$STAMP"
    return 0
  done
  rm -f "$XML" "$STAMP"
  {
    echo "DUMP-FAIL: 3 次都没拿到无障碍树。"
    echo "  最常见原因 'could not get idle state'：界面一直在动，uiautomator 等不到静止。"
    echo "  处置：① 先切到静止页面（别停在有动画/实时流的页面）再 dump；"
    echo "        ② 或放弃 dump，改用 \`screencap\` + 物理像素坐标（screencap 不受影响）。"
  } >&2
  exit 1
}

require_fresh() {
  [ -s "$XML" ] || dump
  local now age
  now=$(date +%s)
  age=$(( now - $(cat "$STAMP" 2>/dev/null || echo 0) ))
  if [ "$age" -gt "$FRESH_MAX" ]; then
    echo "STALE: $XML 是 ${age}s 前的树（> ${FRESH_MAX}s），拒绝复用旧坐标 —— 先跑 dump" >&2
    exit 1
  fi
}

center_of() {
  # 入参：desc 前缀。输出 "X Y"
  python3 - "$XML" "$1" <<'PY'
import re, sys, html
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
want = html.unescape(sys.argv[2])
best = None
for m in re.finditer(r'<node[^>]*>', xml):
    tag = m.group(0)
    d = re.search(r'content-desc="([^"]*)"', tag)
    if not d:
        continue
    desc = html.unescape(d.group(1))
    if not desc.startswith(want):
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if not b:
        continue
    x1, y1, x2, y2 = map(int, b.groups())
    # ★ 优先 clickable=true：对话框的**标题**与**按钮**常常同名，只按面积会点错
    #   （第 298 轮实测：点"重命名"命中了 y=554 的标题节点，对话框纹丝不动）。
    clickable = 'clickable="true"' in tag
    key = (0 if clickable else 1, (x2 - x1) * (y2 - y1))
    if best is None or key < best[0]:
        best = (key, (x1 + x2) // 2, (y1 + y2) // 2, desc)
if best is None:
    sys.exit(3)
print(best[1], best[2])
PY
}

case "${1:-}" in
  dump) dump; echo "dumped $XML ($(wc -c < "$XML") B)" ;;
  list)
    require_fresh
    python3 - "$XML" <<'PY'
import re, sys, html
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
for m in re.finditer(r'<node[^>]*clickable="true"[^>]*>', xml):
    tag = m.group(0)
    d = re.search(r'content-desc="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    t = re.search(r'text="([^"]*)"', tag)
    if not b:
        continue
    x1, y1, x2, y2 = map(int, b.groups())
    desc = html.unescape(d.group(1)) if d else ''
    txt = html.unescape(t.group(1)) if t else ''
    if (x2 - x1) >= 2100 and (y2 - y1) >= 2300:
        continue  # 跳过整屏容器
    label = (desc or txt).replace('\n', ' | ')[:44]
    print(f'{label:<46} ({(x1+x2)//2},{(y1+y2)//2})  [{x1},{y1}][{x2},{y2}]')
PY
    ;;
  where)
    require_fresh
    center_of "$2" || { echo "NOT-FOUND: $2"; exit 1; } ;;
  text)
    # ★★★ r349：头部注释里一直写着 `text ""`，但 case 里**从来没有这个分支**
    #   ⇒ 敲 `text` 会掉进 `*)` 打出帮助，看起来"像没输出"。
    #   补上：列出树里所有非空 `text=`（配 `--desc` 可改列 `content-desc=`）。
    #   参数：`text [--desc] [子串过滤]`
    require_fresh
    if [ "${2:-}" = "--desc" ]; then
      WANT_DESC=1; FILTER="${3:-}"
    else
      WANT_DESC=0; FILTER="${2:-}"
    fi
    if [ "$WANT_DESC" = "1" ]; then
      grep -oE 'content-desc="[^"]+"' "$XML" | sed 's/content-desc=//'
    else
      grep -oE 'text="[^"]+"' "$XML" | sed 's/text=//'
    fi | { if [ -n "$FILTER" ]; then grep -F -- "$FILTER"; else cat; fi; } ;;
  tap)
    require_fresh
    P=$(center_of "$2") || { echo "NOT-FOUND: $2"; exit 1; }
    echo "tap '$2' -> $P"
    $ADB shell input tap $P ;;
  *) sed -n '2,12p' "$0" ;;
esac
