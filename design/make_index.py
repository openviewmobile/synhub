#!/usr/bin/env python3
"""生成设计稿总览页（design/gen/index.html）：每屏 4 个变体（暗/亮 × 中/英）。"""
from __future__ import annotations

import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'gen')
INV = os.path.join(HERE, 'synhub_ui', 'inventory.json')

inv = json.load(open(INV, encoding='utf-8'))
specs = sorted(glob.glob(os.path.join(HERE, 'spec', '*.json')))
by_id = {}
for sp in specs:
    s = json.load(open(sp, encoding='utf-8'))
    by_id[s['id']] = s

unit_to_id = {s.get('unit', ''): s['id'] for s in by_id.values()}

rows = []
for sp in specs:
    s = json.load(open(sp, encoding='utf-8'))
    sid = s['id']
    variants = [('暗·中', f'svg/{sid}.png'), ('暗·英', f'svg/{sid}.dark.en.png'),
                ('亮·中', f'svg/{sid}.light.zh.png'), ('亮·英', f'svg/{sid}.light.en.png')]
    imgs = ''.join(
        f'<figure><img src="{src}"><figcaption>{lab}</figcaption></figure>'
        for lab, src in variants if os.path.exists(os.path.join(OUT, src)))
    title = s['title']['zh'] if isinstance(s['title'], dict) else s['title']
    rows.append(f'<section><h2>{title} <code>{sid}</code>'
                f'<span>{s.get("unit","")}</span></h2><div class="v">{imgs}</div></section>')

done = len(specs)
mods = {}
for it in inv:
    mods.setdefault(it['module'], [0, 0])
    mods[it['module']][1] += 1
    if it['file'].replace('.dart', '') in {k.replace('.dart', '') for k in unit_to_id}:
        mods[it['module']][0] += 1
tbl = ''.join(f'<tr><td>{m}</td><td>{a}/{b}</td></tr>' for m, (a, b) in
              sorted(mods.items(), key=lambda x: -x[1][1]))

html = f"""<!doctype html><meta charset="utf-8"><title>SynHub 设计稿总览 r459</title>
<style>
body{{margin:0;background:#0B0E12;color:#E9EDF2;font:13px -apple-system,'PingFang SC',sans-serif;padding:28px}}
h1{{font-size:20px;margin:0 0 6px}}h2{{font-size:14px;margin:0 0 10px;font-weight:600}}
h2 code{{color:#8FB8FF;font-weight:500;font-size:12px;margin-left:8px}}
h2 span{{color:#6F7B8B;font-size:11px;margin-left:10px}}
section{{margin:0 0 28px;border-bottom:1px solid #1A1F27;padding-bottom:20px}}
.v{{display:flex;gap:12px;flex-wrap:wrap}}
figure{{margin:0;width:180px}}figure img{{width:100%;display:block;border-radius:8px;border:1px solid #1A1F27}}
figcaption{{font-size:10.5px;color:#98A2AF;padding-top:4px}}
table{{border-collapse:collapse;font-size:11.5px}}td{{padding:2px 12px 2px 0;color:#98A2AF}}
</style>
<h1>SynHub · 设计稿（{done} 屏 × 4 变体）</h1>
<p style="color:#98A2AF;font-size:12px">代码即设计源 · 393×852 · 暗/亮 × 中/英 全部由 spec 生成</p>
<table>{tbl}</table>
{''.join(rows)}"""
open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8').write(html)
print(f'[ok] {os.path.join(OUT, "index.html")}  ({done} 屏)')
