#!/usr/bin/env python3
"""生成**评审用接触表**（contact sheet）：把 154 屏压进一张 PNG + 一页可点的 HTML。

为什么不用 `index.html`：那是"逐屏 4 变体大图"，往下翻要很久，评审时容易只看前几屏。
这里做的是**一屏一格**的缩略图总览（暗色中文为主），一眼能看出"配色/密度/层级"是否一致，
发现哪格不对再回 `index.html` 看大图。

用法：
    python3 design/review_sheet.py            # 生成 gen/review.html
    python3 design/review_sheet.py --png      # 另用本机 Chrome 截图成 gen/review.png
"""
from __future__ import annotations

import argparse
import glob
import io
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'gen')
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

COLS = 8
module_counts: dict[str, int] = {}
TILE_W = 150
TILE_H = 300


def build(module: str | None = None) -> str:
    specs = sorted(glob.glob(os.path.join(HERE, 'spec', '*.json')))
    tiles = []
    by_mod: dict[str, int] = {}
    for sp in specs:
        s = json.load(io.open(sp, encoding='utf-8'))
        sid = s['id']
        title = s['title']['zh'] if isinstance(s['title'], dict) else s['title']
        unit = s.get('unit', '')
        mod = unit.split('/')[3] if unit.count('/')>=3 else '—' if unit.count('/') >= 2 else '—'
        if module and mod != module:
            continue
        by_mod[mod] = by_mod.get(mod, 0) + 1
        img = f'svg/{sid}.png'
        if not os.path.exists(os.path.join(OUT, img)):
            img = f'svg/{sid}.light.zh.png'
        tiles.append(
            f'<a class="t" href="index.html#{sid}" title="{sid} · {unit}">'
            f'<img src="{img}" width="{TILE_W}" height="{TILE_H}">'
            f'<b>{title}</b><i>{mod}</i></a>'
        )

    mods = ' · '.join(f'{k} {v}' for k, v in sorted(by_mod.items(), key=lambda kv: -kv[1]))
    n_rows = (len(tiles) + COLS - 1) // COLS
    height = 150 + n_rows * (TILE_H + 34) + 40
    html = f"""<!doctype html><meta charset="utf-8">
<title>SynHub 设计评审接触表（{len(tiles)} 屏）</title>
<style>
 body{{margin:0;background:#0b1016;color:#e6ebf2;
   font:13px/1.4 -apple-system,"PingFang SC","Helvetica Neue",Arial}}
 header{{padding:18px 24px 6px}} h1{{margin:0 0 6px;font-size:20px}}
 p{{margin:4px 0;color:#93a0b1}}
 .grid{{display:grid;grid-template-columns:repeat({COLS},{TILE_W}px);
   gap:14px 14px;padding:10px 24px 30px}}
 .t{{display:block;text-decoration:none;color:#cfd8e4}}
 .t img{{display:block;border-radius:10px;border:1px solid #223040;background:#0f1720}}
 .t b{{display:block;margin-top:5px;font-size:11.5px;font-weight:600;
   white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:{TILE_W}px}}
 .t i{{display:block;font-style:normal;font-size:10.5px;color:#6f8098}}
</style>
<header>
 <h1>SynHub 全部 {len(tiles)} 屏设计稿 · 一次看完</h1>
 <p>令牌：暗/亮双主题 × 中/英双语；每屏 4 变体在 <code>index.html</code> 里。</p>
 <p>模块分布：{mods}</p>
 <p>评审怎么看：① 同一列的行卡片/图标块/字号是否一致；② 顶栏动作是否 ≤3 个 + ⋮；
    ③ 空态是否有说明与唯一入口；④ 有没有"看不见但能点"的地方。</p>
</header>
<div class="grid">{''.join(tiles)}</div>
"""
    path = os.path.join(
        OUT, f'module-{module}.html' if module else 'review.html')
    io.open(path, 'w', encoding='utf-8').write(html)
    print(f'[ok] {path}  ({len(tiles)} 屏, {n_rows} 行)')
    return path


def png(width: int, height: int, module: str | None = None) -> None:
    src = 'file://' + os.path.join(
        OUT, f'module-{module}.html' if module else 'review.html')
    dst = os.path.join(OUT, f'module-{module}.png' if module else 'review.png')
    subprocess.run(
        [CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars',
         '--force-device-scale-factor=1', f'--window-size={width},{height}',
         f'--screenshot={dst}', src],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    print(f'[ok] {dst} ({os.path.getsize(dst)} B)' if os.path.exists(dst) else '[!!] 截图失败')


def modules() -> list[str]:
    """spec 里出现的全部模块名（按屏数降序）。"""
    counts: dict[str, int] = {}
    for sp in glob.glob(os.path.join(HERE, 'spec', '*.json')):
        s = json.load(io.open(sp, encoding='utf-8'))
        unit = s.get('unit', '')
        mod = unit.split('/')[3] if unit.count('/')>=3 else '—' if unit.count('/') >= 2 else '—'
        counts[mod] = counts.get(mod, 0) + 1
    module_counts.clear()
    module_counts.update(counts)
    return sorted(counts, key=lambda m: (-counts[m], m))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--png', action='store_true')
    ap.add_argument('--width', type=int, default=1400)
    ap.add_argument('--height', type=int, default=6600)
    ap.add_argument('--module', default=None, help='只出某一个模块的接触表')
    ap.add_argument('--all-modules', action='store_true',
                    help='25 个模块各出一张接触表（PNG 需要 --png）')
    a = ap.parse_args()
    if a.all_modules:
        done = []
        for m in modules():
            build(m)
            if a.png:
                n = sum(1 for _ in io.open(os.path.join(OUT, f'module-{m}.html'),
                                           encoding='utf-8'))
                rows = max(1, (len(glob.glob(os.path.join(HERE, 'spec', '*.json'))) and 1))
                png(a.width, 420, m) if False else None
                # 按屏数算高度：每行 TILE_H+34
                cnt = module_counts[m]
                r = (cnt + COLS - 1) // COLS
                png(a.width, 150 + r * (TILE_H + 34) + 40, m)
            done.append(m)
        print(f'[ok] {len(done)} 个模块：' + ' · '.join(done))
        return
    build(a.module)
    if a.png:
        png(a.width, a.height, a.module)


if __name__ == '__main__':
    main()
