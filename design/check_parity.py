#!/usr/bin/env python3
"""设计与代码的**一致性闸门**：同一份 spec 必须同时出现在 SVG 与 Dart 里。

判据（任一不过 → exit 1）：
  ① spec 的标题 / 每个 tab / 每条 item 标题，都出现在 design/gen/svg/<id>.svg
  ② 同样这些文案，都出现在 design/gen/flutter/<id>_page.dart
  ③ Dart 里的类名 = 'Design' + CamelCase(id) + 'Page'（前缀防与真实页面撞名）
  ④ Dart 文件里不许出现裸色值（Color(0xFF…) 只允许在 design_tokens.dart）

用法：python3 design/check_parity.py            # 校验 design/spec/*.json 全量
"""
from __future__ import annotations

import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
fail = []


def camel(s: str) -> str:
    parts = [p for p in s.replace('-', '_').split('_') if p]
    return ''.join(p[:1].upper() + p[1:] for p in parts)


specs = sorted(glob.glob(os.path.join(HERE, 'spec', '*.json')))
if not specs:
    print('[fail] design/spec 下没有 spec')
    sys.exit(1)

for sp in specs:
    spec = json.load(open(sp, encoding='utf-8'))
    sid = spec['id']
    svg_zh = os.path.join(HERE, 'gen', 'svg', sid + '.svg')
    svg_en = os.path.join(HERE, 'gen', 'svg', sid + '.dark.en.svg')
    dart_p = os.path.join(HERE, 'gen', 'flutter', sid + '_page.dart')
    for p in (svg_zh, dart_p):
        if not os.path.exists(p):
            fail.append(f'{sid}: 缺产物 {p}')
    if not (os.path.exists(svg_zh) and os.path.exists(dart_p)):
        continue

    svg = open(svg_zh, encoding='utf-8').read()
    svg_en_txt = open(svg_en, encoding='utf-8').read() if os.path.exists(svg_en) else None
    dart = open(dart_p, encoding='utf-8').read()

    # 只跳过"不是文案"的标量键；容器键（tabs/items/body/…）必须下钻
    SKIP = {'id', 'unit', 'type', 'appbar', 'actions', 'bottomNav', 'fab',
            'progress', 'count', 'numbered', 'sections', 'value', 'active',
            'lead', 'trail', 'kind', 'zh', 'en', 'tileIcon', 'rowIcon', 'icon',
            'side',
            'obscure'}
    ENUM = {'list', 'grid', 'player', 'detail', 'settings', 'unavailable',
            'switch', 'slider', 'more', 'play', 'pause', 'none', 'check',
            'icon', 'plus'}

    def walk(node, key=''):
        out = []
        if isinstance(node, dict):
            if 'zh' in node and 'en' in node:
                return [(node['zh'], node['en'])]
            for k, v in node.items():
                if k in SKIP:
                    continue
                out += walk(v, k)
        elif isinstance(node, list):
            for v in node:
                out += walk(v, key)
        elif isinstance(node, str):
            if node.startswith('#') or node in ENUM:
                return []
            return [(node, node)]
        return out

    pairs = walk(spec)

    def in_svg(text, blob):
        # SVG 里 & < > 会被 XML 转义，比对时两种形态都认
        cands = [text]
        esc = (text.replace('&', '&amp;').replace('<', '&lt;')
                   .replace('>', '&gt;').replace('"', '&quot;'))
        if esc != text:
            cands.append(esc)
        return any(c in blob for c in cands)

    for zh, en in pairs:
        if not in_svg(zh, svg):
            fail.append(f'{sid}: 中文 SVG 缺「{zh}」')
        if svg_en_txt is not None and not in_svg(en, svg_en_txt):
            fail.append(f'{sid}: 英文 SVG 缺「{en}」')
        if zh not in dart and zh.replace("'", "\\'") not in dart:
            fail.append(f'{sid}: Dart 缺中文「{zh}」')
        if en not in dart and en.replace("'", "\\'") not in dart:
            fail.append(f'{sid}: Dart 缺英文「{en}」')

    want = 'Design' + camel(sid) + 'Page'
    if f'class {want} extends' not in dart:
        fail.append(f'{sid}: Dart 类名不是 {want}')
    bare = re.findall(r'Color\(0x[0-9A-Fa-f]{8}\)', dart)
    if bare:
        fail.append(f'{sid}: Dart 里出现 {len(bare)} 处裸色值（应走 DesignPalette）')
    if 'DesignPalette.of(context)' not in dart:
        fail.append(f'{sid}: 页面没走 DesignPalette.of(context)（主题切换会失效）')

    print(f'[ok] {sid}: {len(pairs)} 组文案 ×2 语言 / SVG+Dart 双侧一致')

if fail:
    print('\n'.join('[fail] ' + f for f in fail))
    sys.exit(1)
print(f'\n✅ 一致性闸门通过（{len(specs)} 份 spec）')
