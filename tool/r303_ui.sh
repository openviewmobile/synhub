#!/usr/bin/env bash
# r303 真机走查用的极简 helper（避免内联 python 引号地狱）
# 用法: tool/r303_ui.sh find <子串>            -> 打印 "<cx> <cy>"（找不到退出 1）
#       tool/r303_ui.sh lines <y_min> <y_max> -> 打印该纵向区间内所有 desc 行
set -euo pipefail
XML=/tmp/r298_ui.xml
cmd="${1:?cmd}"
case "$cmd" in
  find)
    needle="${2:?needle}"
    python3 - "$XML" "$needle" <<'PY'
import re,html,sys
xml=open(sys.argv[1],encoding='utf-8',errors='replace').read()
needle=sys.argv[2]
for m in re.finditer(r'<node[^>]*>',xml):
    g=m.group(0)
    d=re.search(r'content-desc="([^"]*)"',g)
    b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',g)
    c=re.search(r'clickable="(\w+)"',g)
    if not (d and b): continue
    lab=html.unescape(d.group(1))
    if needle in lab:
        cx=(int(b.group(1))+int(b.group(3)))//2
        cy=(int(b.group(2))+int(b.group(4)))//2
        clickable = c.group(1) if c else '?'
        print(f'{cx} {cy} {clickable} {lab.replace(chr(10), " | ")[:44]}')
PY
    ;;
  lines)
    lo="${2:?lo}"; hi="${3:?hi}"
    python3 - "$XML" "$lo" "$hi" <<'PY'
import re,html,sys
xml=open(sys.argv[1],encoding='utf-8',errors='replace').read()
lo,hi=int(sys.argv[2]),int(sys.argv[3])
for m in re.finditer(r'<node[^>]*>',xml):
    g=m.group(0)
    d=re.search(r'content-desc="([^"]*)"',g)
    t=re.search(r'text="([^"]*)"',g)
    b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',g)
    c=re.search(r'clickable="(\w+)"',g)
    if not b: continue
    y0,y1=int(b.group(2)),int(b.group(4))
    if not (lo<=y0<=hi): continue
    lab=html.unescape(d.group(1)) if (d and d.group(1).strip()) else (html.unescape(t.group(1)) if t else '')
    if not lab.strip(): continue
    clickable = c.group(1) if c else '?'
    print(f'y={y0}-{y1} click={clickable:5s} {lab.replace(chr(10), " | ")[:56]}')
PY
    ;;
  *) echo "unknown cmd: $cmd" >&2; exit 2;;
esac
