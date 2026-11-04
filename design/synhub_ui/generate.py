#!/usr/bin/env python3
"""SynHub 全量界面设计生成器（r459）

设计工具的选择（重要）：
  * Figma 的写接口只能在 Figma 里跑插件，我无法替你点窗口 ⇒ 不用它当主工具。
  * 本文件 = 我自己能完整操作的设计工具链：**代码即设计源** → 输出**矢量 SVG**
    （可导入 Figma / Penpot / 任意矢量工具）+ PNG 预览。
  * 覆盖对象：`inventory.json` 里矩阵台账的 **160 个界面单元**，逐个出一张 393×852 画板。

产物：
  design/synhub_ui/out/tokens.svg          设计令牌
  design/synhub_ui/out/screens/<id>.svg    每个界面单元一张
  design/synhub_ui/out/index.html         总览（含每个单元的裁定与状态）
用法：
  python3 design/synhub_ui/generate.py            # 生成全部 svg + index
  python3 design/synhub_ui/generate.py --png 8    # 另把前 8 屏渲染成 png 预览
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

W, H = 393, 852
FONT = "-apple-system,'PingFang SC','Helvetica Neue',Arial,sans-serif"

# ── 设计令牌（唯一真源：design/tokens.py，双主题）────────────────────
_DESIGN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _DESIGN_DIR not in sys.path:
    sys.path.insert(0, _DESIGN_DIR)
from tokens import PALETTES  # noqa: E402

T = dict(PALETTES['dark'])


# ── 绘制原语 ──────────────────────────────────────────────────────
def esc(s: str) -> str:
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def rect(x, y, w, h, fill, r=0, stroke=None, op=None):
    a = f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{r}" fill="{fill}"'
    if stroke:
        a += f' stroke="{stroke}" stroke-width="1"'
    if op is not None:
        a += f' fill-opacity="{op}"'
    return a + '/>'


def circle(cx, cy, r, fill, stroke=None, op=None):
    a = f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{fill}"'
    if stroke:
        a += f' stroke="{stroke}" stroke-width="1"'
    if op is not None:
        a += f' fill-opacity="{op}"'
    return a + '/>'


def text(x, y, s, size=13, fill=None, weight=400, anchor='start', op=None):
    if fill is None:
        fill = T['text']
    a = (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" font-size="{size}" '
         f'fill="{fill}" font-weight="{weight}" text-anchor="{anchor}"')
    if op is not None:
        a += f' fill-opacity="{op}"'
    return a + f'>{esc(s)}</text>'


def icon(cx, cy, size, body, color):
    s = size / 24.0
    return (f'<g transform="translate({cx - size / 2:.1f},{cy - size / 2:.1f}) scale({s:.4f})" '
            f'fill="none" stroke-linecap="round" stroke-linejoin="round">{body.replace("{c}", color)}</g>')


IC = {
    'back': '<path d="M15 5 L8 12 L15 19" stroke="{c}" stroke-width="2"/>',
    'more': '<circle cx="12" cy="5" r="1.6" fill="{c}"/><circle cx="12" cy="12" r="1.6" fill="{c}"/>'
            '<circle cx="12" cy="19" r="1.6" fill="{c}"/>',
    'search': '<circle cx="11" cy="11" r="6.2" stroke="{c}" stroke-width="2"/>'
              '<path d="M16.2 16.2 L20 20" stroke="{c}" stroke-width="2"/>',
    'play': '<path d="M8 5.5 L18 12 L8 18.5 Z" fill="{c}"/>',
    'pause': '<rect x="8" y="6" width="3" height="12" rx="1" fill="{c}"/>'
             '<rect x="14" y="6" width="3" height="12" rx="1" fill="{c}"/>',
    'close': '<path d="M7 7 L17 17 M17 7 L7 17" stroke="{c}" stroke-width="2"/>',
    'chat': '<path d="M4 6h16v10H9l-5 4z" stroke="{c}" stroke-width="1.8"/>',
    'files': '<path d="M4 7h6l2 2h8v9H4z" stroke="{c}" stroke-width="1.8"/>',
    'photos': '<rect x="4" y="5" width="16" height="14" rx="2" stroke="{c}" stroke-width="1.8"/>'
              '<path d="M5 16l4-4 3 3 3-4 4 5" stroke="{c}" stroke-width="1.6"/>',
    'grid': '<rect x="4" y="4" width="7" height="7" rx="1.5" stroke="{c}" stroke-width="1.8"/>'
            '<rect x="13" y="4" width="7" height="7" rx="1.5" stroke="{c}" stroke-width="1.8"/>'
            '<rect x="4" y="13" width="7" height="7" rx="1.5" stroke="{c}" stroke-width="1.8"/>'
            '<rect x="13" y="13" width="7" height="7" rx="1.5" stroke="{c}" stroke-width="1.8"/>',
    'me': '<circle cx="12" cy="8" r="3.4" stroke="{c}" stroke-width="1.8"/>'
          '<path d="M5 20c1.6-3.4 4-5 7-5s5.4 1.6 7 5" stroke="{c}" stroke-width="1.8"/>',
    'user': '<circle cx="12" cy="8.5" r="3.6" stroke="{c}" stroke-width="1.6"/>'
            '<path d="M4.8 20c0-3.6 3.2-6 7.2-6s7.2 2.4 7.2 6" stroke="{c}" '
            'stroke-width="1.6"/>',
    'mail': '<rect x="3" y="5.5" width="18" height="13" rx="2" stroke="{c}" '
            'stroke-width="1.6"/><path d="M3.6 7l8.4 6 8.4-6" stroke="{c}" '
            'stroke-width="1.6"/>',
    'shield': '<path d="M12 3.6l7 2.6v6c0 4-3 7-7 8.2-4-1.2-7-4.2-7-8.2v-6z" '
              'stroke="{c}" stroke-width="1.6"/><path d="M9 12l2.2 2.2L15.4 10" '
              'stroke="{c}" stroke-width="1.6"/>',
    'server': '<rect x="3.5" y="4.5" width="17" height="6" rx="2" stroke="{c}" '
              'stroke-width="1.6"/><rect x="3.5" y="13.5" width="17" height="6" rx="2" '
              'stroke="{c}" stroke-width="1.6"/><circle cx="7" cy="7.5" r="1" fill="{c}"/>'
              '<circle cx="7" cy="16.5" r="1" fill="{c}"/>',
    'wifi': '<path d="M4 9.5a12 12 0 0116 0M7 12.8a7.6 7.6 0 0110 0" stroke="{c}" '
            'stroke-width="1.7" fill="none"/><circle cx="12" cy="17" r="1.8" fill="{c}"/>',
    'settings': '<circle cx="12" cy="12" r="3" stroke="{c}" stroke-width="1.6"/>'
                '<path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6.2 6.2l1.4 1.4'
                'M16.4 16.4l1.4 1.4M17.8 6.2l-1.4 1.4M7.6 16.4l-1.4 1.4" '
                'stroke="{c}" stroke-width="1.6"/>',
    'star': '<path d="M12 4l2.4 5 5.6.7-4 3.9 1 5.4-5-2.7-5 2.7 1-5.4-4-3.9 5.6-.7z" '
            'stroke="{c}" stroke-width="1.5"/>',
    'video': '<rect x="3" y="6" width="12" height="12" rx="2" stroke="{c}" stroke-width="1.6"/>'
             '<path d="M15 10l6-3v10l-6-3z" stroke="{c}" stroke-width="1.6"/>',
    'save': '<path d="M6 4h9l4 4v12H6z" stroke="{c}" stroke-width="1.7"/>'
            '<path d="M9 4v5h6V4M9 15h6" stroke="{c}" stroke-width="1.6"/>',
    'undo': '<path d="M9 7L5 11l4 4" stroke="{c}" stroke-width="1.8"/>'
            '<path d="M5 11h8a5 5 0 0 1 0 10h-2" stroke="{c}" stroke-width="1.7"/>',
    'redo': '<path d="M15 7l4 4-4 4" stroke="{c}" stroke-width="1.8"/>'
            '<path d="M19 11h-8a5 5 0 0 0 0 10h2" stroke="{c}" stroke-width="1.7"/>',
    'search': '<circle cx="11" cy="11" r="6" stroke="{c}" stroke-width="1.7"/>'
              '<path d="M16 16l4 4" stroke="{c}" stroke-width="1.8"/>',
    'camera': '<rect x="3" y="7" width="18" height="13" rx="2" stroke="{c}" stroke-width="1.6"/>'
              '<circle cx="12" cy="13.5" r="3.2" stroke="{c}" stroke-width="1.6"/>',
    'crop': '<path d="M7 3v14h14M3 7h14v14" stroke="{c}" stroke-width="1.7"/>',
    'clock': '<circle cx="12" cy="12" r="8" stroke="{c}" stroke-width="1.7"/>'
             '<path d="M12 8v4.5l3 2" stroke="{c}" stroke-width="1.7"/>',
    'chat': '<path d="M4 6h16v10H9l-5 4z" stroke="{c}" stroke-width="1.7"/>',
    'send': '<path d="M4 12l16-7-6 16-3-6-7-3z" stroke="{c}" stroke-width="1.7"/>',
    'attach': '<path d="M8 12l6-6a3 3 0 1 1 4 4l-7 7a5 5 0 0 1-7-7l6-6" stroke="{c}" stroke-width="1.7"/>',
    'download': '<path d="M12 4v10M8 11l4 4 4-4" stroke="{c}" stroke-width="1.8"/>'
                '<path d="M5 19h14" stroke="{c}" stroke-width="1.8"/>',
    'music': '<path d="M9 18V6l9-2v12" stroke="{c}" stroke-width="1.8"/>'
             '<circle cx="7" cy="18" r="2.4" stroke="{c}" stroke-width="1.8"/>'
             '<circle cx="16" cy="16" r="2.4" stroke="{c}" stroke-width="1.8"/>',
    'heart': '<path d="M12 20s-7-4.6-7-9a4 4 0 0 1 7-2.6A4 4 0 0 1 19 11c0 4.4-7 9-7 9z" '
             'stroke="{c}" stroke-width="1.8"/>',
    'plus': '<path d="M12 5v14M5 12h14" stroke="{c}" stroke-width="2"/>',
    'check': '<path d="M5 12l5 5 9-10" stroke="{c}" stroke-width="2"/>',
    'warn': '<path d="M12 4l9 16H3z" stroke="{c}" stroke-width="1.7"/>'
            '<path d="M12 10v4" stroke="{c}" stroke-width="2"/>',
    'empty': '<rect x="5" y="7" width="14" height="12" rx="2" stroke="{c}" stroke-width="1.6"/>'
             '<path d="M8 11h8M8 14h5" stroke="{c}" stroke-width="1.6"/>',
    'prev': '<rect x="6" y="6" width="2.4" height="12" rx="1" fill="{c}"/>'
            '<path d="M19 6.5L10 12 19 17.5z" fill="{c}"/>',
    'next': '<path d="M5 6.5L14 12 5 17.5z" fill="{c}"/>'
            '<rect x="16" y="6" width="2.4" height="12" rx="1" fill="{c}"/>',
    'shuffle': '<path d="M4 7h3l8 10h4M4 17h3l8-10h4" stroke="{c}" stroke-width="1.8"/>'
               '<path d="M16 4l3 3-3 3M16 14l3 3-3 3" stroke="{c}" stroke-width="1.8"/>',
    'repeat': '<path d="M6 8h9a3 3 0 0 1 3 3v1M18 16H9a3 3 0 0 1-3-3v-1" stroke="{c}" stroke-width="1.8"/>'
              '<path d="M13 5l3 3-3 3M11 19l-3-3 3-3" stroke="{c}" stroke-width="1.8"/>',
    'cast': '<rect x="3" y="5" width="18" height="12" rx="2" stroke="{c}" stroke-width="1.8"/>'
            '<path d="M12 13l4 6H8z" fill="{c}"/>',
    'zoom': '<circle cx="11" cy="11" r="6" stroke="{c}" stroke-width="1.8"/>'
            '<path d="M16 16l4 4M8.5 11h5M11 8.5v5" stroke="{c}" stroke-width="1.8"/>',
    'rotate': '<path d="M19 12a7 7 0 1 1-2.6-5.4" stroke="{c}" stroke-width="1.8"/>'
              '<path d="M20 3v4h-4" stroke="{c}" stroke-width="1.8"/>',
    'download2': '<path d="M12 5v9m-4-4l4 4 4-4M5 19h14" stroke="{c}" stroke-width="1.8"/>',
    'edit': '<path d="M5 19h3l9-9-3-3-9 9v3z" stroke="{c}" stroke-width="1.8"/>',
    'share': '<path d="M8 12l8-4M8 12l8 4" stroke="{c}" stroke-width="1.8"/>'
             '<circle cx="6" cy="12" r="2.4" stroke="{c}" stroke-width="1.8"/>'
             '<circle cx="18" cy="6.5" r="2.4" stroke="{c}" stroke-width="1.8"/>'
             '<circle cx="18" cy="17.5" r="2.4" stroke="{c}" stroke-width="1.8"/>',
    'export': '<path d="M12 15V5m-4 4l4-4 4 4M5 19h14" stroke="{c}" stroke-width="1.8"/>',
    'list': '<path d="M5 7h14M5 12h14M5 17h9" stroke="{c}" stroke-width="1.8"/>',
    'type': '<path d="M5 6h14M12 6v13" stroke="{c}" stroke-width="1.8"/>',
    'bookmark': '<path d="M7 5h10v15l-5-4-5 4z" stroke="{c}" stroke-width="1.8"/>',
    'globe': '<circle cx="12" cy="12" r="8" stroke="{c}" stroke-width="1.7"/>'
             '<path d="M4 12h16M12 4c3 3.2 3 12.8 0 16" stroke="{c}" stroke-width="1.5"/>',
    'image': '<rect x="4" y="6" width="16" height="12" rx="2" stroke="{c}" stroke-width="1.6"/>'
             '<circle cx="9" cy="11" r="1.6" fill="{c}"/>'
             '<path d="M6 17l4-4 3 3 2-2 3 3" stroke="{c}" stroke-width="1.5"/>',
    'pin': '<path d="M12 21s7-6.2 7-11a7 7 0 1 0-14 0c0 4.8 7 11 7 11z" stroke="{c}" stroke-width="1.7"/>'
           '<circle cx="12" cy="10" r="2.4" stroke="{c}" stroke-width="1.7"/>',
    'folder': '<path d="M4 7h5l2 2h9v10H4z" stroke="{c}" stroke-width="1.7"/>',
    'chev': '<path d="M9 5l7 7-7 7" stroke="{c}" stroke-width="1.8"/>',
    'tag': '<path d="M11 4H5v6l9 9 6-6-9-9z" stroke="{c}" stroke-width="1.7"/>'
           '<circle cx="8.5" cy="7.5" r="1.3" fill="{c}"/>',
    'doc': '<path d="M7 4h7l4 4v12H7z" stroke="{c}" stroke-width="1.7"/>'
           '<path d="M10 12h6M10 15h4" stroke="{c}" stroke-width="1.6"/>',
    'timer': '<circle cx="12" cy="13" r="7" stroke="{c}" stroke-width="1.8"/>'
             '<path d="M12 9v4l3 2M9 3h6" stroke="{c}" stroke-width="1.8"/>',
}


# ── 组件 ─────────────────────────────────────────────────────────
def statusbar():
    return [text(20, 26, '9:41', 11, T['muted']),
            text(W - 20, 26, '5G  ▮▮▮', 11, T['muted'], anchor='end')]


def appbar(title, actions=('search', 'more'), back=True, subtitle=None):
    o = [rect(0, 52, W, 1, T['line'])]
    if back:
        o.append(icon(30, 74, 22, IC['back'], T['text']))
    tx = 56 if back else 20
    o.append(text(tx, 74, title, 15, T['text'], 620))
    if subtitle:
        o.append(text(tx, 92, subtitle, 10.5, T['muted']))
    x = W - 28
    for a in reversed(actions):
        o.append(icon(x, 74, 21, IC[a], T['text']))
        x -= 40
    return o


def bottomnav(active='chat'):
    items = [('chat', '聊天'), ('files', '文件'), ('photos', '相册'), ('grid', '工作台'), ('me', '我的')]
    y = H - 64
    o = [rect(0, y, W, 64, T['navBar']), rect(0, y, W, 1, T['line'])]
    for i, (ic, lb) in enumerate(items):
        cx = W * (i + 0.5) / len(items)
        on = ic == active
        o.append(icon(cx, y + 22, 21, IC[ic], T['accent'] if on else T['dim']))
        o.append(text(cx, y + 45, lb, 10, T['accent'] if on else T['dim'], 600 if on else 400,
                      anchor='middle'))
    return o


def tabbar(tabs, active=0, y=104):
    o = [rect(0, y, W, 40, T['phone']), rect(0, y + 40, W, 1, T['line'])]
    x = 20
    for i, name in enumerate(tabs):
        w = 12 + len(name) * 13
        on = i == active
        o.append(text(x + w / 2, y + 25, name, 12.5, T['text'] if on else T['muted'],
                      620 if on else 400, anchor='middle'))
        if on:
            o.append(rect(x + w / 2 - 10, y + 36, 20, 2.5, T['primary'], 2))
        x += w + 18
    return o


def chips(labels, active=0, y=100):
    """分类 chips：一行放不下就换行（英文标签比中文长，硬挤会被裁掉）。"""
    o = []
    x = 16
    row_y = y
    for i, lb in enumerate(labels):
        w = min(26 + len(lb) * 12, W - 32)
        if x + w > W - 16:
            x = 16
            row_y += 40
        on = i == active
        o.append(rect(x, row_y, w, 32, T['primarySoft'] if on else T['surface'], 9,
                      '#2F4A7A' if on else None))
        o.append(text(x + w / 2, row_y + 21, lb, 12, T['accent'] if on else T['muted'],
                      600 if on else 400, anchor='middle'))
        x += w + 8
    return o, row_y - y


def _w(text, size):
    cjk = sum(1 for ch in text if ord(ch) > 0x2E7F)
    return cjk * size + (len(text) - cjk) * size * 0.56


def _fit(text, maxw, size):
    """按估算宽度截断并加省略号（与 Dart 的 TextOverflow.ellipsis 对齐）。"""
    if _w(text, size) <= maxw:
        return text
    out = ''
    for ch in text:
        if _w(out + '…', size) > maxw:
            break
        out += ch
    return out + '…'


def row(y, title, sub=None, lead=None, trail='more', h=62, on=False, lead_icon='music',
        progress=None):
    o = [rect(16, y, W - 32, h, T['surface'] if not on else T['primarySoft'], 13, T['line'])]
    tx = 78
    is_hex = isinstance(lead, str) and lead.startswith('#')
    if is_hex:
        o.append(rect(26, y + (h - 40) / 2, 40, 40, lead, 11))
        o.append(icon(46, y + h / 2, 18, IC.get(lead_icon, IC['music']), T['bg']))
    elif lead:
        # 语义值：中性图块 + 对应图标（不能用假色值，浏览器会渲染成黑块）
        o.append(rect(26, y + (h - 40) / 2, 40, 40, T['surface2'], 11))
        o.append(icon(46, y + h / 2, 18,
                      IC['plus'] if lead == 'plus' else IC.get(lead_icon, IC['music']),
                      T['muted']))
    else:
        o.append(rect(26, y + (h - 40) / 2, 40, 40, T['surface2'], 11))
        o.append(icon(46, y + h / 2, 18, IC.get(lead_icon, IC['files']), T['muted']))
    limit = W - tx - 62
    title_out = _fit(title, limit, 13)
    o.append(text(tx, y + (22 if sub else h / 2 + 4), title_out, 13, T['text'], 600))
    if title_out != title:
        # 截断后原文不连续；用 <title> 保留全文（也供读屏与校验器比对）
        o.append(f'<g><title>{esc(title)}</title></g>')
    if sub:
        sub_out = _fit(sub, limit, 11)
        o.append(text(tx, y + 42, sub_out, 11, T['muted']))
        if sub_out != sub:
            o.append(f'<g><title>{esc(sub)}</title></g>')
    if progress is not None:
        o.append(rect(66, y + h - 16, W - 66 - 24, 3, T['surface2'], 2))
        o.append(rect(66, y + h - 16, (W - 66 - 24) * float(progress), 3, T['primary'], 2))

    if trail == 'more':
        o.append(icon(W - 40, y + h / 2, 20, IC['more'], T['muted']))
    elif trail == 'play':
        o.append(circle(W - 46, y + h / 2, 20, T['surface2']))
        o.append(icon(W - 44, y + h / 2, 15, IC['play'], T['accent']))
    elif trail == 'pause':
        o.append(circle(W - 46, y + h / 2, 20, T['primary']))
        o.append(icon(W - 46, y + h / 2, 15, IC['pause'], T['onPrimary']))
    elif trail == 'check':
        o.append(icon(W - 40, y + h / 2, 20, IC['check'], T['ok']))
    elif trail == 'plus':
        o.append(icon(W - 40, y + h / 2, 20, IC['plus'], T['accent']))
    elif trail == 'chev':
        o.append(icon(W - 40, y + h / 2, 18, IC['chev'], T['dim']))
    elif trail == 'checkbox':
        o.append(rect(W - 48, y + h / 2 - 10, 20, 20, 'none', 5, T['muted']))
    elif not trail or trail == 'none':
        pass
    else:
        o.append(text(W - 40, y + h / 2 + 4, trail, 11, T['muted'], anchor='end'))
    return o


def section(y, title, action=None):
    o = [text(20, y, title, 12.5, T['text'], 620)]
    if action:
        o.append(text(W - 20, y, action, 11, T['accent'], 500, anchor='end'))
    return o


def grid(y, n=9, cols=3, size=None, labels=None, icon_name=None):
    gap = 8
    cw = (W - 32 - gap * (cols - 1)) / cols
    o = []
    for i in range(n):
        r, c = divmod(i, cols)
        x = 16 + c * (cw + gap)
        yy = y + r * (cw + gap)
        o.append(rect(x, yy, cw, cw, T['surface'], 10, T['line']))
        if icon_name:
            o.append(icon(x + cw / 2, yy + cw / 2, cw * 0.34, IC[icon_name], T['muted']))
        else:
            o.append(circle(x + cw / 2, yy + cw / 2, cw * 0.18, T['surface2']))
        if labels and i < len(labels):
            o.append(text(x + 9, yy + cw - 8, labels[i], 10.5, T['muted'], 600))
    rows = (n + cols - 1) // cols
    return o, y + rows * (cw + gap)


def empty(y, title, body, icon_name='empty'):
    o = [icon(W / 2, y + 40, 46, IC[icon_name], T['dim'])]
    o.append(text(W / 2, y + 96, title, 14, T['text'], 600, anchor='middle'))
    for i, ln in enumerate(body):
        o.append(text(W / 2, y + 120 + i * 20, ln, 11.5, T['muted'], anchor='middle'))
    return o


def searchbar(y, hint='搜索'):
    return [rect(16, y, W - 32, 38, T['surface'], 11),
            icon(38, y + 19, 18, IC['search'], T['muted']),
            text(56, y + 24, hint, 12, T['dim'])]


def formrow(y, label, value='', arrow=False, h=52):
    o = [text(20, y + h / 2 + 4, label, 13, T['text'])]
    if value:
        o.append(text(W - 20 - (18 if arrow else 0), y + h / 2 + 4, value, 12, T['muted'], anchor='end'))
    if arrow:
        o.append(icon(W - 26, y + h / 2, 16, '<path d="M9 5l7 7-7 7" stroke="{c}" stroke-width="2"/>', T['dim']))
    o.append(rect(20, y + h, W - 40, 1, T['line']))
    return o


def playerbar(y, title, sub):
    o = [rect(12, y, W - 24, 64, T['playerBar'], 16, T['line'])]
    o.append(rect(24, y + 12, 40, 40, T['surface2'], 10, T['line']))
    o.append(text(80, y + 27, title, 12.5, T['text'], 620))
    o.append(text(80, y + 45, sub, 10.5, T['muted']))
    o.append(circle(W - 84, y + 32, 17, T['primary']))
    o.append(icon(W - 84, y + 32, 14, IC['pause'], T['onPrimary']))
    o.append(icon(W - 42, y + 32, 16, IC['close'], T['muted']))
    return o


def fab(y):
    return [circle(W - 44, y, 26, T['primary']), icon(W - 44, y, 22, IC['plus'], T['onPrimary'])]


# ── 屏幕模板（按"原型"生成；内容取台账描述）──────────────────────────
def scr_list(title, subtitle, items, active_tab=None, chips_row=None, search=False, fab_=False):
    o = statusbar() + appbar(title, subtitle=subtitle)
    y = 112
    if search:
        o += searchbar(y)
        y += 50
    if chips_row:
        o += chips(chips_row, 0, y)
        y += 46
    for it in items[:5]:
        o += row(y, it[0], it[1] if len(it) > 1 else None, it[2] if len(it) > 2 else None,
                 it[3] if len(it) > 3 else 'more')
        y += 70
    if active_tab:
        o += bottomnav(active_tab)
        if fab_:
            o += fab(H - 140)
    return o


def scr_grid(title, subtitle, groups=None, active_tab='photos'):
    o = statusbar() + appbar(title, subtitle=subtitle)
    y = 112
    if groups:
        for g in groups[:3]:
            o += section(y, g)
            y += 18
            g2, y = grid(y, 6, 3)
            o += g2
            y += 10
    o += bottomnav(active_tab)
    return o


def scr_detail(title, subtitle, lines, actions=('search', 'more'), active_tab=None):
    o = statusbar() + appbar(title, actions, subtitle=subtitle)
    y = 116
    o.append(rect(16, y, W - 32, 132, T['surface'], 14, T['line']))
    o.append(circle(16 + 34, y + 40, 18, T['surface2']))
    o.append(icon(16 + 34, y + 40, 18, IC['music'], T['muted']))
    o.append(text(16 + 66, y + 36, lines[0], 14, T['text'], 620))
    for i, ln in enumerate(lines[1:4]):
        o.append(text(16 + 66, y + 58 + i * 18, ln, 11, T['muted']))
    y += 148
    o += [rect(16, y, W - 32, 1, T['line'])]
    y += 16
    for i, t in enumerate(['播放', '加入播放队列', '收藏', '下载', '分享']):
        o.append(icon(34, y + 18, 19, IC['play' if i == 0 else 'files'], T['accent'] if i == 0 else T['muted']))
        o.append(text(58, y + 23, t, 13, T['text']))
        o.append(rect(16, y + 38, W - 32, 1, T['line']))
        y += 44
    if active_tab:
        o += bottomnav(active_tab)
    return o


def scr_player(title, subtitle, lyric=True):
    o = statusbar() + appbar('正在播放', ('heart', 'more'))
    o.append(rect(16, 108, W - 32, 176, '#1B2534', 18, '#2B3648'))
    o.append(circle(W / 2, 196, 54, T['surface2'], op=0.85))
    o.append(text(W / 2, 200, title, 12, T['accent'], 600, anchor='middle'))
    o.append(text(16, 306, subtitle, 17, T['text'], 660))
    o.append(text(16, 328, 'Audio Station · 320 kbps', 12, T['muted']))
    o.append(rect(16, 352, W - 32, 4, T['surface2'], 3))
    o.append(rect(16, 352, (W - 32) * 0.38, 4, T['primary'], 3))
    o.append(circle(16 + (W - 32) * 0.38, 354, 6, '#fff'))
    o.append(text(16, 374, '1:32', 11, T['muted']))
    o.append(text(W - 16, 374, '−2:19', 11, T['muted'], anchor='end'))
    cy = 412
    o.append(icon(40, cy, 20, IC['grid'], T['muted']))
    o.append(icon(104, cy, 24, '<path d="M18 6.5L9 12l9 5.5z" fill="{c}"/><rect x="6" y="6" width="2.4" height="12" rx="1" fill="{c}"/>', T['text']))
    o.append(circle(W / 2, cy, 30, T['primary']))
    o.append(icon(W / 2 + 1, cy, 24, IC['play'], T['onPrimary']))
    o.append(icon(W - 104, cy, 24, '<path d="M6 6.5L15 12 6 17.5z" fill="{c}"/><rect x="16" y="6" width="2.4" height="12" rx="1" fill="{c}"/>', T['text']))
    o.append(icon(W - 40, cy, 20, IC['heart'], T['muted']))
    if lyric:
        o.append(rect(16, 456, W - 32, 210, T['surface'], 14, T['line']))
        o.append(text(30, 480, '歌词', 11.5, T['muted'], 620))
        o.append(text(W - 30, 480, 'lrclib · 带时间轴', 10.5, '#5C6675', anchor='end'))
        ls = [('Sample lyric line one', T['dim'], 12.5, 400, 518),
              ('Sample lyric line two', T['dim'], 12.5, 400, 548),
              ("Sample lyric line three", T['accent'], 15, 660, 584),
              ('Sample lyric line four', T['dim'], 12.5, 400, 614),
              ('Sample lyric line five', T['dim'], 12.5, 400, 644)]
        for s, c, sz, w, y in ls:
            o.append(text(W / 2, y, s, sz, c, w, anchor='middle'))
    qy = H - 52
    for i, (ic, lb) in enumerate([('grid', '播放队列'), ('download', '投送到'), ('music', '音效'), ('me', '睡眠')]):
        cx = 16 + (W - 32) * (i + 0.5) / 4
        o.append(rect(cx - 17, qy - 17, 34, 34, T['surface'], 10))
        o.append(icon(cx, qy, 18, IC[ic], T['text']))
        o.append(text(cx, qy + 27, lb, 10.5, T['muted'], anchor='middle'))
    return o


def scr_settings(title, rows, active_tab='me'):
    o = statusbar() + appbar(title, ('search', 'more'))
    y = 108
    for label, value in rows:
        o += formrow(y, label, value, arrow=True)
        y += 52
    o += bottomnav(active_tab)
    return o


def scr_form(title, fields, cta='继续'):
    o = statusbar() + appbar(title, ('more',), back=True)
    y = 118
    for i, f in enumerate(fields):
        o.append(text(20, y, f, 11.5, T['muted'], 500))
        o.append(rect(16, y + 10, W - 32, 44, T['surface'], 11, T['line']))
        o.append(text(30, y + 38, '　', 13, T['dim']))
        y += 74
    o.append(rect(16, H - 92, W - 32, 46, T['primary'], 13))
    o.append(text(W / 2, H - 62, cta, 14, T['onPrimary'], 620, anchor='middle'))
    return o


def scr_empty(title, subtitle, msg, body):
    o = statusbar() + appbar(title, subtitle=subtitle)
    o += empty(300, msg, body)
    return o


# ── 台账 → 设计稿（原型推断 + 逐单元文案）──────────────────────────
def infer_archetype(desc: str) -> str:
    d = desc
    if re.search(r'登录|连接|设置服务器|表单|输入', d):
        return 'form'
    if re.search(r'播放器|播放页|正在播放|歌词|单曲', d):
        return 'player'
    if re.search(r'相册|网格|缩略图|照片|时刻', d):
        return 'grid'
    if re.search(r'设置|开关|偏好|权限', d):
        return 'settings'
    if re.search(r'详情|文件信息|属性', d):
        return 'detail'
    if re.search(r'空态|错误|失败提示', d):
        return 'empty'
    return 'list'


def pretty(unit: str) -> str:
    s = unit.replace('.dart', '').replace('_', ' ')
    return s[:1].upper() + s[1:]


def build_screen(item) -> list[str]:
    kind = infer_archetype(item['desc'])
    title = pretty(item['file'])
    sub = item['desc'][:26]
    if kind == 'player':
        return scr_player(title, 'Demo Artist · Demo Song')
    if kind == 'grid':
        return scr_grid(title, sub, ['最近', '按日期'], 'photos')
    if kind == 'settings':
        return scr_settings(title, [('通用', ''), ('通知', '开'), ('播放', ''), ('缓存', '1.2 GB'),
                                    ('关于', 'r459')])
    if kind == 'form':
        return scr_form(title, ['服务器地址', '账号', '密码'], '登录')
    if kind == 'detail':
        return scr_detail(title, sub, ['Demo Song', 'Demo Artist · 320 kbps', '3:51 · 9.0 MB'],
                          active_tab=None)
    if kind == 'empty':
        return scr_empty(title, sub, '这里还没有内容', ['换个条件试试，或稍后刷新'])
    items = [(title, sub, None, 'more'), ('最近一项', '刚刚', None, 'more'),
             ('第二项', '昨天', None, 'more'), ('第三项', '更早', None, 'more')]
    return scr_list(title, sub, items, active_tab=None, search=True)


# ── 单元 → spec（真稿）映射 ────────────────────────────────────────────
# inventory 里的 160 个界面单元，与 `design/spec/*.json` 是两套命名
# （`audio_detail_page.dart` ↔ `audio_detail`）。以前这里是**按 desc 拼一个占位板**
# （标题 + 「最近一项/第二项/第三项」），于是"全站设计稿"有 160 张、其中 153 张是占位 ——
# 交付物名不副实。spec 里的 `unit` 字段就是权威对应关系，按它映射即可。
def _spec_index() -> dict:
    import glob as _glob
    out = {}
    for p in _glob.glob(os.path.join(HERE, '..', 'spec', '*.json')):
        s = json.load(io.open(p, encoding='utf-8'))
        u = (s.get('unit') or '').split('/')[-1]
        if u:
            out[u] = s['id']
    return out


def spec_screen(item, index: dict, theme: str = 'dark') -> str | None:
    """有 spec 的单元 → 直接吐该 spec 的**真稿 SVG**（同一份真源）。"""
    sid = index.get(item['file'])
    if not sid:
        return None
    # emit_svg 的命名规则：**默认（暗·中）不带后缀**，其它组合才带 `.theme.locale`
    base = os.path.join(HERE, '..', 'gen', 'svg')
    if theme == 'light':
        candidates = (f'{sid}.light.zh.svg', f'{sid}.svg')
    else:
        candidates = (f'{sid}.svg', f'{sid}.dark.zh.svg')
    for name in candidates:
        f = os.path.join(base, name)
        if os.path.exists(f):
            return io.open(f, encoding='utf-8').read()
    return None


# ── 7 个**非页面**单元（见 design/component-units.md）─────────────────────
# 它们不是独立屏幕：别名 / 数据模型 / 绘制部件 / 平台抽象。
# 以前它们和真实页面一样被拼成"占位板"，肉眼分不出来 ⇒ 评审时会被当成真稿。
# 现在这些板上直接写明类别与"在哪张真稿里看得见"。
COMPONENT_UNITS = {
    'home_page.dart': ('别名', 'app_shell', 'AppShellPage 的 3 行转发，无自有界面'),
    'drive_pdf_text_layer.dart': ('数据模型', 'drive_pdf_markup', 'PDF 文字框数据，不画像素'),
    'note_body.dart': ('绘制部件', 'note_editor', '笔记正文排版件，被编辑/阅读页共用'),
    'office_doc_page_frame.dart': ('绘制部件', 'office_doc', '文档页外框，画布滚动时反复调用'),
    'office_doc_paper.dart': ('绘制部件', 'office_doc', '纸张/页边距/页眉页脚'),
    'photo_c2_sections.dart': ('绘制部件', 'photo_c2', '条件相册共用外壳与分区'),
    'sleep_backup_platform.dart': ('平台抽象', 'sleep_backup', '睡眠备份通道，无界面'),
    'djvu_archive.dart': ('数据层', 'files', 'DJVU 容器层，纯 Dart 不画像素'),
}


def _component_note(item) -> list:
    meta = COMPONENT_UNITS.get(item['file'])
    if meta is None:
        return []
    cat, ref, why = meta
    o = [rect(16, 560, W - 32, 132, T['surface'], 14, T['line'])]
    o.append(text(30, 590, '组件单元 · ' + cat, 13, T['text'], 660))
    o.append(text(30, 612, why, 10.5, T['muted']))
    o.append(text(30, 640,
                  '真稿见：' + (ref if cat != '数据层' else '无（数据层，不画像素）'),
                  11, T['primary'], 600))
    o.append(text(30, 668, '本板不是页面稿，不必按屏评审', 10, T['dim']))
    return o


def svg_board(item) -> str:
    body = build_screen(item) + _component_note(item)
    head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
            f'viewBox="0 0 {W} {H}">')
    inner = ''.join(body)
    return (head + rect(0, 0, W, H, T['phone'], 0) + inner + '</svg>')


def svg_tokens() -> str:
    o = [rect(0, 0, W, H, T['bg'])]
    o.append(text(20, 34, 'SynHub 设计令牌', 16, T['text'], 660))
    o.append(text(20, 56, '全站唯一真源 · r459', 11, T['muted']))
    y = 82
    for i, (k, v) in enumerate(T.items()):
        col, rowi = i % 2, i // 2
        x = 20 + col * 180
        yy = y + rowi * 62
        o.append(rect(x, yy, 150, 34, v, 8, T['line']))
        o.append(text(x, yy + 48, k, 10.5, T['muted']))
        o.append(text(x + 76, yy + 48, v, 10, T['dim']))
    y += 8 * 62 + 20
    o.append(text(20, y, '字阶', 12, T['accent'], 620))
    y += 24
    for sz, wt, lb in [(17, 660, '标题 17/660'), (15, 620, '小节 15/620'), (13, 500, '正文 13/500'),
                       (11.5, 400, '辅助 11.5/400'), (10.5, 400, '微型 10.5/400')]:
        o.append(text(20, y, lb, sz, T['text'], wt))
        y += sz + 14
    y += 12
    o.append(text(20, y, '硬指标', 12, T['accent'], 620))
    y += 22
    for r in ['点击区 ≥ 48×48dp，图标画在 24dp 网格',
              '一屏最多一个 ⋮；行内"更多"不与顶栏同层',
              '高频动作外露：播放/暂停/下载/分享/删除/刷新/搜索',
              '任何可点元素必须有可见形态（禁透明按钮）',
              '歌词由播放位置驱动：高亮 + 居中 + 240ms',
              '圆角：卡片 13–18 / 图标底 10–11 / 画板 30']:
        o.append(text(24, y, '· ' + r, 11, T['muted']))
        y += 20
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
            f'viewBox="0 0 {W} {H}">' + ''.join(o) + '</svg>')


def build(theme: str, screens_sub: str, index_name: str, png_n: int) -> tuple:
    """按主题出一整套稿：spec 真稿 → out/<screens_sub>/，总览 → out/<index_name>。

    ★ 用户裁定 ③「亮色要与暗色同等精细」说的是**界面**，可设计稿本身此前只有暗色一套 ——
    评审时看不到亮色，就等于亮色没人评审过。所以这里把主题做成参数：
    同一份 spec，暗/亮各出一套 160 张，总览页各一份。
    """
    global T
    T = dict(PALETTES[theme])

    inventory = json.load(io.open(os.path.join(HERE, 'inventory.json'), encoding='utf-8'))
    screens_dir = os.path.join(OUT, screens_sub)
    os.makedirs(screens_dir, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)

    tokens_name = 'tokens.svg' if theme == 'dark' else 'tokens-light.svg'
    with io.open(os.path.join(OUT, tokens_name), 'w', encoding='utf-8') as f:
        f.write(svg_tokens())

    entries = []
    spec_index = _spec_index()
    real, stub = 0, 0
    for i, item in enumerate(inventory, 1):
        sid = f'{i:03d}_{item["module"]}_{item["file"].replace(".dart", "")}'
        screen = spec_screen(item, spec_index, theme)
        if screen is None:
            stub += 1
            screen = svg_board(item)
        else:
            real += 1
        with io.open(os.path.join(screens_dir, sid + '.svg'), 'w', encoding='utf-8') as f:
            f.write(screen)
        entries.append({'id': sid, 'module': item['module'], 'file': item['file'],
                        'desc': item['desc'], 'verdict': item['verdict'],
                        'arch': infer_archetype(item['desc'])})

    other = 'index-light.html' if index_name == 'index.html' else 'index.html'
    other_label = '亮色稿' if index_name == 'index.html' else '暗色稿'
    rows = []
    for e in entries:
        rows.append(
            f'<figure><a href="{screens_sub}/{e["id"]}.svg"><img loading="lazy" src="{screens_sub}/{e["id"]}.svg"></a>'
            f'<figcaption>{esc(e["file"])}<br><span>{esc(e["desc"][:34])}</span>'
            f'<br><b>{e["arch"]}</b> · {e["verdict"]}</figcaption></figure>')
    theme_label = '暗色' if theme == 'dark' else '亮色'
    html = f"""<!doctype html><meta charset="utf-8"><title>SynHub 设计稿总览 · {theme_label}</title>
<style>
body{{margin:0;background:{T['bg']};color:{T['text']};font:13px {FONT};padding:28px}}
h1{{font-size:18px;margin:0 0 6px}}p.sub{{color:{T['muted']};margin:0 0 22px;font-size:12px}}
.wrap{{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:20px}}
figure{{margin:0;background:{T['phone']};border:1px solid {T['line']};border-radius:12px;overflow:hidden}}
figure img{{width:100%;display:block}}
figcaption{{padding:8px 10px;font-size:11px;line-height:1.5;color:{T['text']}}}
figcaption span{{color:{T['muted']}}} figcaption b{{color:{T['accent']};font-weight:600}}
</style>
<h1>SynHub · 全部界面设计稿（{len(entries)} 个界面单元 · {theme_label}）</h1>
<p class="sub">代码即设计源（design/synhub_ui）· 画板 393×852 · 点击任意缩略图看单页 SVG ·
令牌页 <a href="{tokens_name}" style="color:{T['accent']}">{tokens_name}</a> ·
主题切换 <a href="{other}" style="color:{T['accent']}">{other_label}</a></p>
<div class="wrap">{''.join(rows)}</div>"""
    with io.open(os.path.join(OUT, index_name), 'w', encoding='utf-8') as f:
        f.write(html)

    print(f'[ok] {theme_label} {len(entries)} 屏 → {screens_sub}（真稿 {real} / 组件占位 {stub}）')
    print(f'[ok] {theme_label}总览 {os.path.join(OUT, index_name)}')

    if png_n:
        for e in entries[:png_n]:
            src = os.path.join(screens_dir, e['id'] + '.svg')
            dst = os.path.join(OUT, e['id'] + '.png' if theme == 'dark'
                               else os.path.join('light', e['id'] + '.png'))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars',
                            '--force-device-scale-factor=2', f'--window-size={W},{H}',
                            f'--screenshot={dst}', 'file://' + src],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f'[ok] {theme_label} png {min(png_n, len(entries))} 张')
    return real, stub


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--png', type=int, default=0, help='暗色：把前 N 屏渲染成 png')
    ap.add_argument('--png-light', type=int, default=0, help='亮色：把前 N 屏渲染成 png')
    ap.add_argument('--theme', choices=['dark', 'light', 'both'], default='both')
    args = ap.parse_args()

    if args.theme in ('dark', 'both'):
        build('dark', 'screens', 'index.html', args.png)
    if args.theme in ('light', 'both'):
        build('light', 'screens-light', 'index-light.html', args.png_light)


if __name__ == '__main__':
    main()
