#!/usr/bin/env python3
"""r406 小工具：dump 当前界面 → 打印 BT 搜索的 chip（含中心点）与结果行数。

**每次动作前都跑一遍，不要复用上一次的坐标**（chip 条会横向滚动 + 选中态会改宽度）。

用法：
    export ADB="adb -s <serial>"; bash tool/r298_ui.sh dump >/dev/null
    python3 tool/r406_bt_state.py [/tmp/r298_ui.xml]
"""
import re
import subprocess
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else '/tmp/r298_ui.xml'
# 服务端 getModule 的真实标题（13 条，含重复）——见 docs/evidence-r406/nas/r406a_bt_modules.log
CHIP_TITLES = {
    'All sources', '1337xxx', 'The Pirate Bay', 'EZTV', '1337x', 'Demonoid',
    'Sky torrents', 'MagnetDL', 'YTS', 'NoNaMe-Club', 'Rutor',
    'Torrent Downloads',
}
NODE = re.compile(r'^\[(\d+),(\d+)\]\[(\d+),(\d+)\]\t(\S*)\t?(.*)$')

out = subprocess.run(
    ['python3', 'tool/dump_nodes.py', SRC, '--all'],
    capture_output=True, text=True).stdout

nodes = []          # (l,t,r,b,cls,text)
cur = None
for line in out.splitlines():
    m = NODE.match(line)
    if m:
        cur = (int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)),
               m.group(5), m.group(6))
        nodes.append(cur)
    elif cur is not None and line.strip():
        # 多行文本节点：把续行并进 text（结果行就是这么来的）
        nodes[-1] = cur = cur[:5] + (cur[5] + '\n' + line,)

chips = [n for n in nodes if n[5].split('\n')[0] in CHIP_TITLES and 480 <= n[1] <= 520]
print(f'CHIPS（{len(chips)} 个；选中 = 宽 290±5，未选中 = 192±5）:')
for l, t, r, b, _cls, text in chips:
    print(f'  {text.splitlines()[0]:<18} center=({(l + r) // 2},{(t + b) // 2})  '
          f'width={r - l}')

rows = [n for n in nodes if 'Size:' in n[5] or 'Seeds:' in n[5]]
print(f'ROWS: {len(rows)}')
for l, t, r, b, _cls, text in rows:
    parts = text.split('\n')
    src = [p for p in parts if p in CHIP_TITLES and p != 'All sources']
    print(f'  src={src[0] if src else "?"}  title={parts[0][:52] if parts else ""}')
