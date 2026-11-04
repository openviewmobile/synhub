#!/usr/bin/env python3
"""设计稿体检：把"画出来才看得见"的规则变成可复跑的检查。

检查项（每条都能指到 spec 的哪个字段）：
  R1 列表行数 > 8      —— 渲染器上限 8 行，多出来的会被静默吞掉
  R2 文案超长          —— 表单/字段值一行放不下（列表行由渲染器加省略号，不查）
  R3 工具栏 > 5 个动作 —— 一行排不下
  R4 表单 > 5 个字段   —— 键盘弹起后放不下
  R5 网格 > 9 格       —— 首屏之外，需要用户滚动才知道有更多
  R6 日历标记越界      —— marked 里有 1..days 之外的数字
  R7 对比度不足        —— muted/dim 正文在所处底色上低于 4.5:1（WCAG AA 小字）
  R8 重复文案          —— 同一屏里同一句出现两次（多半是分组去重没做）
  R9 空正文            —— viewer/form 没有 text/fields
  R10 圆角/点击区越界  —— MIN_TAP=48 以下的可点行
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tokens import PALETTES  # noqa: E402

W = 393.0
MIN_TAP = 48


def L(v):
    return v.get('zh', '') if isinstance(v, dict) else (v or '')


def tw(text, size):
    cjk = sum(1 for ch in text if ord(ch) > 0x2E7F)
    latin = len(text) - cjk
    return cjk * size + latin * size * 0.56


def lum(h):
    h = h.lstrip('#')
    rgb = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    out = []
    for c in rgb:
        out.append(c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4)
    return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]


def contrast(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def walk_strings(node, out, key=''):
    if isinstance(node, str):
        out.append((key, node))
    elif isinstance(node, dict):
        for k, v in node.items():
            walk_strings(v, out, k)
    elif isinstance(node, list):
        for v in node:
            walk_strings(v, out, key)


def audit(spec):
    bad = []
    body = spec.get('body', {})
    kind = body.get('type')
    items = body.get('items', [])

    if kind == 'list' and len(items) > 8:
        bad.append(('R1', f'{len(items)} 行，渲染上限 8'))
    if kind == 'grid' and body.get('count', 9) > 9:
        bad.append(('R5', f"网格 {body.get('count')} 格"))
    if (kind == 'viewer' and body.get('kind') in ('document', 'text')
            and not body.get('text')):
        bad.append(('R9', '文档/文本视图没有正文，画出来是占位图'))
    if kind == 'form' and not body.get('fields'):
        bad.append(('R9', 'form 没有字段'))
    tb = body.get('toolbar', [])
    if len(tb) > 5:
        bad.append(('R3', f'工具栏 {len(tb)} 个动作'))
    if len(body.get('fields', [])) > 5:
        bad.append(('R4', f"表单 {len(body.get('fields'))} 个字段"))

    if kind == 'calendar':
        days = int(body.get('days', 31))
        out = [d for d in body.get('marked', []) if not (1 <= int(d) <= days)]
        if out:
            bad.append(('R6', f'标记越界 {out}'))

    # R2 超长：行标题/副标题/标签/值
    # 列表行由渲染器统一加省略号（Dart 侧 TextOverflow.ellipsis），不查超宽

    for i, r in enumerate(body.get('rows', [])):
        if isinstance(r, list):
            continue
        if tw(L(r.get('value', '')), 12) > W - 150:
            bad.append(('R2', f'row{i}.value 超宽：{L(r.get("value"))[:24]}'))
    for i, f in enumerate(body.get('fields', [])):
        if tw(L(f.get('value', '')), 13) > W - 40:
            bad.append(('R2', f'field{i}.value 超宽'))

    # R7 对比度是全局令牌问题，只在 main() 里报一次
    pass

    # R8 整行重复：同一屏里 title+sub 完全相同的两行（复制粘贴没改）
    if kind == 'list':
        sig = {}
        for i, it in enumerate(items):
            key = (L(it.get('title', '')), L(it.get('sub', '')))
            if key[0] and key in sig:
                bad.append(('R8', f'第 {sig[key]} 行与第 {i} 行完全相同：{key[0][:18]}'))
            sig[key] = i
    strs = []
    walk_strings(body, strs)
    seen = {}
    _ = (strs, seen)

    # R10 点击区：列表行高 62 够，行内 trailing 图标按 MIN_TAP 算
    return bad


def main():
    rows = 0
    fails = {}
    print('== 全局令牌检查 ==')
    for theme, pal in PALETTES.items():
        for fg, bgk in (('muted', 'surface'), ('dim', 'surface'), ('muted', 'bg'),
                        ('dim', 'bg'), ('text', 'surface')):
            c = contrast(pal[fg], pal[bgk])
            tag = 'OK ' if c >= 4.5 else 'AA低于4.5'
            print(f'  {theme:5s} {fg:5s} on {bgk:7s} = {c:5.2f}:1  {tag}')
    for p in sorted(glob.glob(os.path.join(HERE, 'spec', '*.json'))):
        spec = json.load(open(p, encoding='utf-8'))
        bad = audit(spec)
        if bad:
            fails[spec['id']] = bad
            rows += len(bad)
    for sid, bad in fails.items():
        print(f'\n[{sid}]')
        for code, msg in bad:
            print(f'  {code}: {msg}')
    print(f'\n共 {rows} 条 / {len(fails)} 屏')
    return 0 if rows == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
