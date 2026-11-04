#!/usr/bin/env python3
"""静态 UX 体检（第一版）—— 只做"能机检的六类反人类模式"，输出可复核的 file:line。

动机（用户 2026-10-18 原话）：
  「有的界面居然放了2个更多的菜单项；菜单里有重复功能；常用功能居然收在菜单项里，
    导致用户看不见；音乐播放器的歌词不能跟随声音同步滚动；电台没有播放器，
    无法控制暂停和关闭；有的界面元素设计的看不见，实际有按钮但没显示出来。」

本脚本不"判缺陷"，只**定位候选**（真缺陷需要人读代码/真机确认）：
  C1 一屏两个"更多"菜单     —— 同一文件里 ≥2 个 `PopupMenuButton`
  C2 菜单里重复功能         —— 同一文件里同一菜单标签出现 ≥2 次
  C3 常用功能被收进菜单     —— 菜单项里出现"高频动作"（播放/下载/删除/分享/刷新/搜索…）
  C4 看不见的按钮           —— `Colors.transparent` / `Opacity(0` / 0 尺寸 / 无字图标的点击区
  C5 点击区过小             —— IconButton 显式 iconSize/尺寸 < 24
  C6 播放器类页面缺"位置驱动" —— 页面读 `player.position` 但整个文件没有任何 *Stream/Listenable

用法：
  python3 tool/ux_audit_scan.py                    # 全仓
  python3 tool/ux_audit_scan.py --file lib/src/features/audio/audio_radio_page.dart
  python3 tool/ux_audit_scan.py --md out.md        # 另存 markdown 表
"""
from __future__ import annotations

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FEATURES = os.path.join(ROOT, 'lib', 'src', 'features')

# C3：被视为"高频动作"的标签（中文文案 / l10n key 片段 / 英文）
COMMON_ACTIONS = [
    'play', 'pause', 'next', 'previous', 'prev', 'stop',
    'download', 'upload', 'share', 'refresh', 'reload', 'search',
    'delete', 'remove', 'rename', 'move', 'copy', 'select',
    '播放', '暂停', '停止', '下一', '上一', '下载', '上传', '分享',
    '刷新', '重新加载', '搜索', '删除', '重命名', '移动', '复制', '全选',
]

MENU_BLOCK_RE = re.compile(r'PopupMenuButton<[^>]*>\(', re.S)
LABEL_RE = re.compile(r"""(?:Text\(\s*)?['"]([^'"\n]{1,40})['"]""")


def read(p: str) -> str:
    with open(p, encoding='utf-8') as f:
        return f.read()


def line_of(src: str, idx: int) -> int:
    return src.count('\n', 0, idx) + 1


def popup_menus(src: str):
    """返回 [(起始行, 块文本)]，块按括号配平截取。"""
    out = []
    for m in MENU_BLOCK_RE.finditer(src):
        i = m.end() - 1
        depth = 0
        for j in range(i, len(src)):
            c = src[j]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    out.append((line_of(src, m.start()), src[i:j + 1]))
                    break
    return out


ITEM_RE = re.compile(r'PopupMenuItem<[^>]*>\(', re.S)


def labels_in(block: str):
    """只取 `PopupMenuItem(...)` 内部的文案（菜单项标签）。

    ★ 首版把 `case 'todo':` 这类常量也数进来 ⇒ C2 假报 116 条（r458 自查）。
    现在只读菜单项自身的 Text / dataText / l10n getter。
    """
    out = []
    for m in ITEM_RE.finditer(block):
        i = m.end() - 1
        depth = 0
        for j in range(i, len(block)):
            c = block[j]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    inner = block[i:j + 1]
                    out += [x for x in LABEL_RE.findall(inner) if x.strip()]
                    out += re.findall(r"dataText\(\s*'([^']+)'", inner)
                    out += [g[1] for g in
                            re.findall(r'\b(?:l10n|loc|t)\.([A-Za-z0-9_]{2,40})', inner)]
                    break
    return out


def is_common(label: str) -> bool:
    low = label.lower()
    return any(a in low for a in COMMON_ACTIONS)


def scan_file(path: str):
    src = read(path)
    rel = os.path.relpath(path, ROOT)
    lines = src.split('\n')
    hits = {f'C{i}': [] for i in range(1, 7)}

    # ---- C1 两个菜单 ----
    menus = popup_menus(src)
    if len(menus) >= 2:
        hits['C1'].append(
            f'{len(menus)} 个 PopupMenuButton（行 {", ".join(str(m[0]) for m in menus)}）')

    # ---- C2 菜单内重复标签 / C3 高频动作进菜单 ----
    for start, block in menus:
        lbs = labels_in(block)
        seen = {}
        for lb in lbs:
            seen[lb] = seen.get(lb, 0) + 1
        for lb, n in seen.items():
            if n >= 2:
                hits['C2'].append(f'菜单@{start} 标签「{lb}」出现 {n} 次')
        common = [lb for lb in lbs if is_common(lb)]
        if common:
            hits['C3'].append(f'菜单@{start}: ' + ' / '.join(sorted(set(common))))

    # ---- C4 看不见的按钮 ----
    for i, ln in enumerate(lines, 1):
        if 'Colors.transparent' in ln and not ln.strip().startswith('//'):
            hits['C4'].append(f'{i}: {ln.strip()[:110]}')
        elif re.search(r'Opacity\(\s*opacity:\s*0(\.0)?\s*[,)]', ln):
            hits['C4'].append(f'{i}: {ln.strip()[:110]}')
        elif re.search(r'(width|height):\s*0(\.0)?\s*,', ln) and 'SizedBox' not in ln:
            hits['C4'].append(f'{i}: {ln.strip()[:110]}')

    # ---- C5 点击区过小 ----
    for i, ln in enumerate(lines, 1):
        m = re.search(r'iconSize:\s*([0-9.]+)', ln)
        if m and float(m.group(1)) < 24:
            hits['C5'].append(f'{i}: iconSize={m.group(1)}')
        elif re.search(r'constraints:\s*BoxConstraints\(\s*(min|max)\w*:\s*(1[0-9]|2[0-3])\b', ln):
            hits['C5'].append(f'{i}: {ln.strip()[:100]}')

    # ---- C6 播放器页缺位置驱动 ----
    if re.search(r'player\.position|\bposition:\s*\w*player', src):
        driven = re.search(
            r'StreamBuilder|ListenableBuilder|AnimatedBuilder|ValueListenableBuilder'
            r'|positionStream|addListener\(|Timer\.periodic|Ticker', src)
        if not driven:
            hits['C6'].append('读 player.position 但全文件无 StreamBuilder/Listenable/Timer/Ticker')

    return rel, hits, len(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', action='append', help='只扫这些文件（可重复）')
    ap.add_argument('--md', help='把结果写成 markdown')
    args = ap.parse_args()

    if args.file:
        files = [os.path.abspath(f) for f in args.file]
    else:
        files = []
        for root, _dirs, names in os.walk(FEATURES):
            for n in sorted(names):
                if n.endswith('.dart') and ('page' in n or 'view' in n or 'stage' in n):
                    files.append(os.path.join(root, n))

    rows = []
    totals = {f'C{i}': 0 for i in range(1, 7)}
    for f in files:
        rel, hits, nlines = scan_file(f)
        counts = {k: len(v) for k, v in hits.items()}
        for k, v in counts.items():
            totals[k] += v
        if any(counts.values()):
            rows.append((rel, nlines, hits, counts))

    rows.sort(key=lambda r: -sum(r[3].values()))
    names = {
        'C1': '一屏两个「更多」菜单',
        'C2': '菜单里重复功能',
        'C3': '常用功能被收进菜单',
        'C4': '看不见的按钮（无视觉的点击区）',
        'C5': '点击区过小（<24dp）',
        'C6': '播放器缺位置驱动（歌词/进度不跟声音）',
    }
    out = []
    out.append(f'# UX 静态体检（{len(files)} 个页面/视图文件）\n')
    out.append('| 类 | 命中数 | 说明 |')
    out.append('|---|---:|---|')
    for k in ['C1', 'C2', 'C3', 'C4', 'C5', 'C6']:
        out.append(f'| {k} | {totals[k]} | {names[k]} |')
    out.append('')
    out.append('## 命中明细（按命中数降序）\n')
    for rel, nlines, hits, counts in rows:
        flag = ' '.join(f'{k}×{n}' for k, n in counts.items() if n)
        out.append(f'### `{rel}`（{nlines} 行）— {flag}')
        for k in ['C1', 'C2', 'C3', 'C4', 'C5', 'C6']:
            for h in hits[k][:6]:
                out.append(f'- **{k}** {h}')
            if len(hits[k]) > 6:
                out.append(f'- **{k}** … 另有 {len(hits[k]) - 6} 条')
        out.append('')
    text = '\n'.join(out)
    print(text)
    if args.md:
        with open(args.md, 'w', encoding='utf-8') as f:
            f.write(text)
        print(f'\n[写入] {args.md}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
