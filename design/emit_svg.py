#!/usr/bin/env python3
"""spec → 设计稿（SVG + PNG），支持 **双主题 × 双语**。

用法：
  python3 design/emit_svg.py design/spec/audio_library.json                     # 暗色·中文
  python3 design/emit_svg.py design/spec/audio_library.json --theme light --locale en
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KIT_PATH = os.path.join(os.path.dirname(HERE), 'design', 'synhub_ui', 'generate.py')
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

sys.path.insert(0, HERE)
from tokens import PALETTES  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument('spec')
ap.add_argument('--theme', default='dark', choices=['dark', 'light'])
ap.add_argument('--locale', default='zh', choices=['zh', 'en'])
args = ap.parse_args()

spec = json.load(open(args.spec, encoding='utf-8'))
_loader = importlib.util.spec_from_file_location('kit', KIT_PATH)
kit = importlib.util.module_from_spec(_loader)
_loader.loader.exec_module(kit)
kit.T = dict(PALETTES[args.theme])          # ★ 主题切换就是换这一份令牌

W, H = kit.W, kit.H
LOC = args.locale


def L(v):
    """取当前语言的文案；spec 里可以是纯字符串，也可以是 {zh, en}。"""
    if isinstance(v, dict):
        return v.get(LOC) or v.get('zh') or next(iter(v.values()))
    return v


def render_player(b, y):
    o = [kit.rect(16, y, W - 32, 196, kit.T['surface'], 18, kit.T['line'])]
    o.append(kit.text(W / 2, y + 78, L(b.get('cover', '')), 11, kit.T['muted'], anchor='middle', op=0.7))
    o.append(kit.icon(W / 2, y + 138, 44, kit.IC['music'], kit.T['dim']))
    y += 216
    o.append(kit.text(16, y, b['song'], 17, kit.T['text'], 660))
    o.append(kit.text(16, y + 22, L(b['artist']), 12, kit.T['muted']))
    o.append(kit.text(16, y + 42, L(b['meta']), 11, kit.T['dim']))
    y += 62
    o.append(kit.rect(16, y, W - 32, 4, kit.T['surface2'], 3))
    o.append(kit.rect(16, y, (W - 32) * b.get('progress', 0.4), 4, kit.T['primary'], 3))
    o.append(kit.circle(16 + (W - 32) * b.get('progress', 0.4), y + 2, 6, kit.T['text']))
    o.append(kit.text(16, y + 20, b.get('left', ''), 11, kit.T['muted']))
    o.append(kit.text(W - 16, y + 20, b.get('right', ''), 11, kit.T['muted'], anchor='end'))
    cy = y + 58
    o.append(kit.icon(38, cy, 20, kit.IC['shuffle'], kit.T['muted']))
    o.append(kit.icon(100, cy, 24, kit.IC['prev'], kit.T['text']))
    o.append(kit.circle(W / 2, cy, 30, kit.T['primary']))
    o.append(kit.icon(W / 2, cy, 24, kit.IC['pause'], kit.T['onPrimary']))
    o.append(kit.icon(W - 100, cy, 24, kit.IC['next'], kit.T['text']))
    o.append(kit.icon(W - 38, cy, 20, kit.IC['repeat'], kit.T['muted']))
    y += 92
    lh = 206
    o.append(kit.rect(16, y, W - 32, lh, kit.T['surface'], 14, kit.T['line']))
    o.append(kit.text(30, y + 24, '歌词', 11.5, kit.T['muted'], 620))
    o.append(kit.text(W - 30, y + 24, 'lrclib · 带时间轴', 10.5, kit.T['dim'], anchor='end'))
    for i, ln in enumerate(b.get('lyrics', [])[:5]):
        act = ln.get('active')
        o.append(kit.text(W / 2, y + 56 + i * 30, L(ln['text']),
                          15 if act else 12.5,
                          kit.T['accent'] if act else kit.T['dim'],
                          660 if act else 400, anchor='middle'))
    y += lh + 16
    quick = b.get('quick', [])
    quick_icons = ['grid', 'cast', 'music', 'timer']
    for i, lb in enumerate(quick):
        cx = 16 + (W - 32) * (i + 0.5) / max(1, len(quick))
        o.append(kit.rect(cx - 17, y, 34, 34, kit.T['surface'], 10, kit.T['line']))
        o.append(kit.icon(cx, y + 17, 17, kit.IC[quick_icons[i % 4]], kit.T['text']))
        o.append(kit.text(cx, y + 46, L(lb), 10.5, kit.T['muted'], anchor='middle'))
    return o


def render_detail(b, y):
    o = [kit.rect(16, y, W - 32, 150, kit.T['surface'], 14, kit.T['line'])]
    o.append(kit.rect(32, y + 20, 84, 84, kit.T['surface2'], 12, kit.T['line']))
    o.append(kit.icon(74, y + 62, 26, kit.IC['music'], kit.T['muted']))
    o.append(kit.text(130, y + 40, b['title'], 15, kit.T['text'], 640))
    o.append(kit.text(130, y + 62, L(b['artist']), 11.5, kit.T['muted']))
    o.append(kit.text(130, y + 82, L(b['meta']), 10.5, kit.T['dim']))
    y += 168
    o.append(kit.rect(16, y, (W - 40) / 2 - 6, 42, kit.T['primary'], 11))
    o.append(kit.text(16 + ((W - 40) / 2 - 6) / 2, y + 27, L(b['primary']), 12.5,
                      kit.T['onPrimary'], 620, anchor='middle'))
    x2 = 16 + (W - 40) / 2 + 6
    o.append(kit.rect(x2, y, (W - 40) / 2 - 6, 42, kit.T['surface'], 11, kit.T['line']))
    o.append(kit.text(x2 + ((W - 40) / 2 - 6) / 2, y + 27, L(b['secondary']), 12.5,
                      kit.T['text'], 500, anchor='middle'))
    y += 62
    for i, it in enumerate(b.get('items', [])[:8]):
        o.append(kit.text(30, y + 24, str(i + 1), 11, kit.T['dim'], anchor='middle'))
        o.append(kit.text(48, y + 19, L(it['title']), 12.5, kit.T['text'], 500))
        o.append(kit.text(48, y + 36, L(it['sub']), 10.5, kit.T['muted']))
        o.append(kit.icon(W - 40, y + 24, 18, kit.IC['more'], kit.T['dim']))
        y += 52
    return o


def render_settings(b, y):
    """设置族统一版式：**一行一张卡片**（与 `list` 类型同语言）。

    r470 之前这里画的是"平铺行 + 分隔线"，而设置主页（`settings.json`，type=list）
    画的是卡片 —— 同一族两套皮，真机对照时一眼就能看出分裂。
    现在两边同一套几何：卡片 surface + line 边框 + 13 圆角、左右 16 / 上下 5、
    组标题 13-600 text 色；开关旋钮固定白（`onPrimary` 在暗色是深藏蓝，
    落在亮蓝轨道上像个洞）。
    """
    o = []
    RW = W - 32
    for g in b.get('groups', []):
        if g.get('title'):
            o.append(kit.text(20, y + 4, L(g['title']), 13, kit.T['text'], 620))
            y += 26
        for r in g.get('rows', []):
            rh = 62
            o.append(kit.rect(16, y, RW, rh, kit.T['surface'], 13, kit.T['line']))
            if r.get('kind') == 'switch':
                o.append(kit.text(32, y + 38, L(r['label']), 13, kit.T['text']))
                on = bool(r.get('value'))
                o.append(kit.rect(W - 76, y + 18, 46, 26,
                                  kit.T['primary'] if on else kit.T['surface2'], 13))
                o.append(kit.circle(W - 76 + (30 if on else 10), y + 31, 10, '#FFFFFF'))
            elif r.get('kind') == 'arrow':
                o.append(kit.text(32, y + 38, L(r['label']), 13, kit.T['text']))
                o.append(kit.icon(W - 34, y + 31, 18, kit.IC['chev'], kit.T['dim']))
            else:
                o.append(kit.text(32, y + 26, L(r['label']), 12, kit.T['muted']))
                v = float(r.get('value', 0.5))
                o.append(kit.rect(32, y + 44, W - 100, 4, kit.T['surface2'], 2))
                o.append(kit.rect(32, y + 44, (W - 100) * v, 4, kit.T['primary'], 2))
                o.append(kit.circle(32 + (W - 100) * v, y + 46, 6, '#FFFFFF'))
            y += rh + 10
        y += 6
    if b.get('note'):
        o.append(kit.rect(16, y + 4, W - 32, 52, kit.T['surface'], 13, kit.T['line']))
        o.append(kit.icon(38, y + 30, 16, kit.IC['warn'], kit.T['muted']))
        o.append(kit.text(60, y + 35, L(b['note']), 11.5, kit.T['muted']))
    return o


def render_unavailable(b, y):
    o = [kit.icon(W / 2, y + 70, 54, kit.IC['warn'], kit.T['dim'])]
    o.append(kit.text(W / 2, y + 130, L(b['title']), 15, kit.T['text'], 620, anchor='middle'))
    for i, ln in enumerate(b.get('body', [])):
        o.append(kit.text(W / 2, y + 160 + i * 22, L(ln), 11.5, kit.T['muted'], anchor='middle'))
    if b.get('action'):
        o.append(kit.rect(16, y + 220, W - 32, 46, kit.T['primary'], 12))
        o.append(kit.text(W / 2, y + 249, L(b['action']), 13, kit.T['onPrimary'], 620,
                          anchor='middle'))
    return o


def render_viewer(b, y):
    o = [kit.rect(0, 96, W, H - 96, kit.T['bg'])]
    kind = b.get('kind', 'image')
    top = y + 40
    if kind == 'canvas':
        area_h = H - 96 - 150
        o.append(kit.rect(12, top - 12, W - 24, area_h, kit.T['surface'], 12, kit.T['line']))
        gx, gy = 12 + 12, top
        while gy < top - 12 + area_h - 8:
            xx = gx
            while xx < W - 24:
                o.append(kit.circle(xx, gy, 1.0, kit.T['line']))
                xx += 24
            gy += 24
        o.append('<path d="M60 %d q60 -70 120 -10 t140 30" fill="none" '
                 'stroke="%s" stroke-width="2.2" stroke-linecap="round"/>'
                 % (top + 120, kit.T['primary']))
        o.append('<path d="M70 %d q90 40 170 -8" fill="none" stroke="%s" '
                 'stroke-width="1.6" stroke-linecap="round"/>'
                 % (top + 170, kit.T['muted']))
        o.append(kit.rect(W - 92, top + 6, 62, 26, kit.T['surface2'], 13))
        o.append(kit.text(W - 61, top + 23, '100%', 11, kit.T['muted'],
                          anchor='middle'))
    elif b.get('text'):
        ty = top
        for ln in b.get('text', []):
            txt = L(ln)
            if not txt:
                ty += 20
                continue
            for part in _wrap(txt, W - 48, 14):
                o.append(kit.text(24, ty, part, 14, kit.T['text'], 400))
                ty += 26
            # 折行后原文不连续；用 <title> 保留整行（也供读屏）
            o.append(f'<g><title>{kit.esc(txt)}</title></g>')
            ty += 8
    else:
        o.append(kit.rect(16, top, W - 32, 300, kit.T['surface'], 14, kit.T['line']))
        icon_name = {'document': 'doc', 'image': 'photos', 'text': 'doc',
                     'web': 'globe'}.get(kind, 'files')
        o.append(kit.icon(W / 2, top + 140, 56, kit.IC[icon_name], kit.T['dim']))
    cap_y = H - 132
    o.append(kit.text(W / 2, cap_y, L(b.get('caption', '')), 11, kit.T['muted'], anchor='middle'))
    o.append(kit.rect(0, H - 108, W, 1, kit.T['line']))
    tb = b.get('toolbar', [])
    KEYS = [('缩放', 'zoom'), ('Zoom', 'zoom'), ('旋转', 'rotate'), ('Rotate', 'rotate'),
            ('下载', 'download2'), ('Download', 'download2'), ('编辑', 'edit'),
            ('Edit', 'edit'), ('分享', 'share'), ('Share', 'share'),
            ('导出', 'export'), ('Export', 'export'), ('目录', 'list'),
            ('Contents', 'list'), ('字号', 'type'), ('Font', 'type'),
            ('书签', 'bookmark'), ('Bookmark', 'bookmark'),
            ('后退', 'back'), ('Back', 'back'), ('前进', 'chev'), ('Forward', 'chev'),
            ('刷新', 'rotate'), ('Reload', 'rotate'),
            ('下载本页链接', 'download'), ('Download links', 'download'),
            ('撤销', 'undo'), ('Undo', 'undo'), ('重做', 'redo'), ('Redo', 'redo'),
            ('查找', 'search'), ('Find', 'search'),
            ('重拍', 'camera'), ('Retake', 'camera'), ('裁切', 'crop'), ('Crop', 'crop'),
            ('加页', 'plus'), ('Add page', 'plus'),
            ('批注', 'edit'), ('Annotate', 'edit'), ('签名', 'edit'), ('Sign', 'edit'),
            ('高亮', 'bookmark'), ('Highlight', 'bookmark'),
            ('保存', 'save'), ('Save', 'save'), ('信息', 'doc'), ('Info', 'doc'),
            ('在频道中查看', 'chat'), ('In channel', 'chat'),
            ('加粗', 'type'), ('Bold', 'type'), ('列表', 'list'), ('List', 'list'),
            ('插图', 'image'), ('Image', 'image'), ('标签', 'tag'), ('Tag', 'tag'),
            ('画笔', 'edit'), ('Pen', 'edit'), ('橡皮', 'crop'), ('Eraser', 'crop'),
            ('颜色', 'type'), ('Color', 'type'),
            ('回复', 'undo'), ('Reply', 'undo'), ('转发', 'share'), ('Forward', 'share'),
            ('删除', 'close'), ('Delete', 'close'),
            ('全屏', 'zoom'), ('Fullscreen', 'zoom'),
            ('字幕', 'doc'), ('Subtitles', 'doc'),
            ('画中画', 'image'), ('PiP', 'image'),
            ('截图', 'camera'), ('Snapshot', 'camera'),
            ('对讲', 'chat'), ('Talk', 'chat'),
            ('回放', 'clock'), ('Playback', 'clock'),
            ('设置', 'settings'), ('Settings', 'settings'),
            ('播放', 'play'), ('Play', 'play')]
    for i, lb in enumerate(tb):
        cx = W * (i + 0.5) / max(1, len(tb))
        name = 'more'
        for kw, nm in KEYS:
            if kw in L(lb):
                name = nm
                break
        o.append(kit.icon(cx, H - 74, 20, kit.IC[name], kit.T['text']))
        o.append(kit.text(cx, H - 44, L(lb), 10.5, kit.T['muted'], anchor='middle'))
    return o


def render_form(b, y):
    o = []
    if b.get('captcha'):
        o.append(kit.rect(16, y, W - 32, 84, kit.T['surface'], 12, kit.T['line']))
        o.append(kit.icon(W / 2, y + 42, 30, kit.IC['image'], kit.T['dim']))
        y += 96
    for f in b.get('fields', []):
        o.append(kit.text(20, y, L(f['label']), 11, kit.T['muted'], 500))
        o.append(kit.rect(16, y + 10, W - 32, 46, kit.T['surface'], 11, kit.T['line']))
        o.append(kit.text(30, y + 39, L(f.get('value', '')), 13, kit.T['text']))
        y += 74
    sw = b.get('switch')
    if sw:
        o.append(kit.text(20, y + 22, L(sw['label']), 13, kit.T['text']))
        on = bool(sw.get('value'))
        o.append(kit.rect(W - 66, y + 10, 46, 26,
                          kit.T['primary'] if on else kit.T['surface2'], 13))
        o.append(kit.circle(W - 66 + (30 if on else 10), y + 23, 10, kit.T['text']))
        y += 52
    if b.get('submit'):
        o.append(kit.rect(16, y + 12, W - 32, 48, kit.T['primary'], 12))
        o.append(kit.text(W / 2, y + 43, L(b['submit']), 13, kit.T['onPrimary'], 620,
                          anchor='middle'))
    return o


def render_timeline(b, y):
    o = []
    for sec in b.get('sections', []):
        label = L(sec['label'])
        cnt = int(sec.get('count', 9))
        o.append(kit.text(20, y + 4, label, 13, kit.T['text'], 640))
        o.append(kit.text(W - 20, y + 4, f"{cnt} 张" if LOC == 'zh' else f"{cnt} items",
                          11, kit.T['muted'], anchor='end'))
        g, y2 = kit.grid(y + 14, min(cnt, 9), 3,
                     labels=[L(x) for x in body.get('labels', [])])
        o += g
        y = y2 + 10
    return o


def render_map(b, y):
    o = [kit.rect(16, y, W - 32, 190, kit.T['surface2'], 14, kit.T['line'])]
    for i in range(1, 4):
        o.append(kit.rect(16, y + i * 190 / 4, W - 32, 1, kit.T['line']))
    for i in range(1, 4):
        o.append(kit.rect(16 + i * (W - 32) / 4, y, 1, 190, kit.T['line']))
    o.append(kit.icon(W / 2, y + 95, 30, kit.IC['pin'], kit.T['primary']))
    o.append(kit.text(W / 2, y + 130, L(b.get('caption', '')), 10.5, kit.T['muted'],
                      anchor='middle'))
    y += 206
    for it in b.get('places', [])[:5]:
        o += kit.row(y, L(it['title']), L(it['sub']), 'cover',
                     b.get('trail', 'more'), lead_icon='photos')
        y += 70
    return o


def render_fields(b, y):
    o = [kit.rect(16, y, W - 32, 96 if b.get('progress') is not None else 70,
                  kit.T['surface'], 14, kit.T['line'])]
    o.append(kit.text(30, y + 30, L(b['title']), 14, kit.T['text'], 640))
    o.append(kit.text(30, y + 50, L(b['sub']), 11, kit.T['muted']))
    if b.get('progress') is not None:
        o.append(kit.rect(30, y + 64, W - 92, 5, kit.T['surface2'], 3))
        o.append(kit.rect(30, y + 64, (W - 92) * float(b['progress']), 5, kit.T['primary'], 3))
    y += (96 if b.get('progress') is not None else 70) + 12
    if b.get('actions'):
        acts = b['actions']
        bw = (W - 40 - 10 * (len(acts) - 1)) / len(acts)
        for i, a in enumerate(acts):
            x = 16 + i * (bw + 10)
            primary = i == 0
            o.append(kit.rect(x, y, bw, 40, kit.T['primary'] if primary else kit.T['surface'],
                              11, None if primary else kit.T['line']))
            o.append(kit.text(x + bw / 2, y + 26, L(a), 12.5,
                              kit.T['onPrimary'] if primary else kit.T['text'], 600,
                              anchor='middle'))
        y += 54
    for r in b.get('rows', [])[:8]:
        o.append(kit.text(20, y + 22, L(r['label']), 12, kit.T['muted']))
        o.append(kit.text(W - 20, y + 22, L(r['value']), 12, kit.T['text'], anchor='end'))
        o.append(kit.rect(20, y + 30, W - 40, 1, kit.T['line']))
        y += 34
    return o


def _tw(t, size):
    """估算文本宽度：CJK 1em、拉丁 0.56em。"""
    return sum(size if ord(ch) > 127 else size * 0.56 for ch in t)


def _wrap(s, maxw, size):
    """折行：拉丁按词断，CJK 按字断 —— 否则英文会被从单词中间劈开。"""
    words = s.split(' ')
    if len(words) > 1:
        lines, cur = [], ''
        for wd in words:
            cand = wd if not cur else cur + ' ' + wd
            if _tw(cand, size) <= maxw:
                cur = cand
                continue
            if cur:
                lines.append(cur)
            if _tw(wd, size) > maxw:
                part = ''
                for ch in wd:
                    if _tw(part + ch, size) > maxw and part:
                        lines.append(part)
                        part = ch
                    else:
                        part += ch
                cur = part
            else:
                cur = wd
        if cur:
            lines.append(cur)
        return lines or ['']
    lines, cur = [], ''
    for ch in s:
        if _tw(cur + ch, size) > maxw and cur:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
    if cur:
        lines.append(cur)
    return lines or ['']


def render_bubbles(b, y):
    o = []
    if b.get('pinned'):
        o.append(kit.rect(12, y, W - 24, 34, kit.T['surface'], 10, kit.T['line']))
        o.append(kit.icon(30, y + 17, 15, kit.IC['bookmark'], kit.T['accent']))
        o.append(kit.text(46, y + 22, L(b['pinned']), 11, kit.T['muted']))
        y += 46
    day = L(b.get('day', '今天'))
    o.append(kit.text(W / 2, y + 16, day, 10.5, kit.T['dim'], anchor='middle'))
    y += 32
    for m in b.get('messages', []):
        mine = m.get('side') == 'out'
        maxw = (W - 32) * 0.72
        lines = _wrap(L(m['text']), maxw - 24, 12.5)
        bh = 20 + len(lines) * 18
        if m.get('kind') == 'image':
            bh += 96
        bubble_w = min(maxw, max(_tw(x, 12.5) for x in lines) + 26)
        bubble_w = max(bubble_w, 90)
        x = W - 16 - bubble_w if mine else 54
        if not mine and m.get('name'):
            o.append(kit.circle(30, y + 14, 14, kit.T['surface2']))
            o.append(kit.text(30, y + 19, L(m['name'])[:1], 11, kit.T['muted'], 600,
                              anchor='middle'))
            o.append(kit.text(54, y + 10, L(m['name']), 10.5, kit.T['muted'], 600))
        top = y + (16 if not mine and m.get('name') else 0)
        o.append(kit.rect(x, top, bubble_w, bh,
                          kit.T['primarySoft'] if mine else kit.T['surface'], 14))
        ty = top + 26
        if m.get('kind') == 'image':
            o.append(kit.rect(x + 10, top + 12, bubble_w - 20, 76, kit.T['surface2'], 10))
            o.append(kit.icon(x + bubble_w / 2, top + 50, 26, kit.IC['image'], kit.T['muted']))
            ty = top + 108
        for i, ln in enumerate(lines):
            o.append(kit.text(x + 12, ty + i * 18, ln, 12.5,
                              kit.T['text'], anchor='start'))
        # 折行后原文不再连续；用 <title> 保留完整文案（也供读屏）
        o.append(f'<g><title>{kit.esc(L(m["text"]))}</title></g>')
        tm = m.get('time', '')
        if tm:
            o.append(kit.text(x + bubble_w - 12, top + bh + 12, tm, 10, kit.T['dim'],
                              anchor='end'))
        y = top + bh + 24
    comp = b.get('composer')
    if comp:
        cy = H - 64
        o.append(kit.rect(0, cy - 8, W, 72, kit.T['phone']))
        o.append(kit.rect(0, cy - 8, W, 1, kit.T['line']))
        o.append(kit.rect(12, cy, W - 76, 42, kit.T['surface'], 21, kit.T['line']))
        o.append(kit.text(30, cy + 26, L(comp), 12.5, kit.T['dim']))
        o.append(kit.circle(W - 34, cy + 21, 21, kit.T['primary']))
        o.append(kit.icon(W - 34, cy + 21, 18, kit.IC['send'], kit.T['onPrimary']))
    return o


def render_compare(b, y):
    o = [kit.text(20, y + 6, L(b['title']), 13.5, kit.T['text'], 640)]
    y += 26
    card_h = min(170.0, (H - 220 - 12 * (len(b['options']) - 1)) / len(b['options']))
    for op in b['options']:
        o.append(kit.rect(16, y, W - 32, card_h, kit.T['surface'], 13, kit.T['line']))
        o.append(kit.text(30, y + 24, L(op['label']), 12.5, kit.T['accent'], 600))
        yy = y + 46
        for m in op.get('meta', [])[:3]:
            o.append(kit.text(30, yy, L(m['label']), 10.5, kit.T['muted']))
            o.append(kit.text(W - 30, yy, L(m['value']), 10.5, kit.T['text'], anchor='end'))
            yy += 20
        body_txt = L(op['body'])
        body_lines = _wrap(body_txt, W - 60, 11.5)
        for i, ln in enumerate(body_lines[:4]):
            o.append(kit.text(30, yy + 14 + i * 17, ln, 11.5, kit.T['muted']))
        o.append(f'<g><title>{kit.esc(body_txt)}</title></g>')
        y += card_h + 12
    if b.get('keepBoth'):
        o.append(kit.text(W / 2, y + 16, L(b['keepBoth']), 12, kit.T['accent'], 600,
                          anchor='middle'))
    return o


def render_sheet(b, y):
    cols = b.get('columns', ['A', 'B', 'C', 'D'])
    rows = b.get('rows', [])
    left, top = 16, y + 8
    head_h, row_h = 26, 34
    num_w = 30
    cw = (W - 32 - num_w) / max(1, len(cols))
    o = [kit.rect(left, top, W - 32, head_h + row_h * len(rows), kit.T['surface'], 8,
                  kit.T['line'])]
    for i, c in enumerate(cols):
        o.append(kit.text(left + num_w + cw * (i + 0.5), top + 17, c, 10.5,
                          kit.T['muted'], 600, anchor='middle'))
    for r in range(len(rows) + 1):
        yy = top + head_h + row_h * r
        o.append(kit.rect(left, yy, W - 32, 1, kit.T['line']))
    for r, row in enumerate(rows):
        yy = top + head_h + row_h * r
        o.append(kit.text(left + num_w / 2, yy + 21, str(r + 1), 10.5,
                          kit.T['dim'], anchor='middle'))
        for i, cell in enumerate(row[:len(cols)]):
            cx = left + num_w + cw * i
            o.append(kit.rect(cx, yy, 1, row_h, kit.T['line']))
            o.append(kit.text(cx + 6, yy + 21, L(cell), 11, kit.T['text']))
    active = b.get('active')
    if active:
        cx = left + num_w + cw * active[1]
        cy = top + head_h + row_h * active[0]
        o.append(kit.rect(cx + 1, cy + 1, cw - 1, row_h - 1, 'none', 0, kit.T['primary'], 2))
    o.append(kit.rect(left + num_w, top, 1, head_h + row_h * len(rows), kit.T['line']))
    return o


def render_calendar(b, y):
    month = L(b.get('monthLabel', {'zh': '2026 年 3 月', 'en': 'March 2026'}))
    o = [kit.text(20, y + 8, month, 13.5, kit.T['text'], 640)]
    y += 24
    wk = [L(x) for x in b.get('weekdays', [
        {'zh': '一', 'en': 'M'}, {'zh': '二', 'en': 'T'}, {'zh': '三', 'en': 'W'},
        {'zh': '四', 'en': 'T'}, {'zh': '五', 'en': 'F'}, {'zh': '六', 'en': 'S'},
        {'zh': '日', 'en': 'S'}])]
    cw = (W - 32) / 7
    for i, w in enumerate(wk):
        o.append(kit.text(16 + cw * (i + 0.5), y + 12, w, 10.5, kit.T['dim'],
                          anchor='middle'))
    y += 22
    first = int(b.get('firstWeekday', 6))
    days = int(b.get('days', 31))
    cell = 40
    for i in range(first):
        pass
    for d in range(1, days + 1):
        idx = first + d - 1
        r, c = divmod(idx, 7)
        cx = 16 + cw * c + cw / 2
        cy = y + r * cell + cell / 2
        today = d == b.get('today')
        if today:
            o.append(kit.circle(cx, cy, 15, kit.T['primary']))
        o.append(kit.text(cx, cy + 5, str(d), 12,
                          kit.T['onPrimary'] if today else kit.T['text'],
                          600 if today else 400, anchor='middle'))
        if d in b.get('marked', []):
            o.append(kit.circle(cx, cy + 14, 2.2,
                                kit.T['onPrimary'] if today else kit.T['accent']))
    rows = (first + days - 1) // 7 + 1
    y += rows * cell + 8
    o.append(kit.rect(16, y, W - 32, 1, kit.T['line']))
    y += 12
    for ev in b.get('events', [])[:3]:
        o.append(kit.rect(16, y, W - 32, 56, kit.T['surface'], 11, kit.T['line']))
        o.append(kit.rect(16, y, 3, 56, kit.T['primary'], 2))
        o.append(kit.text(30, y + 22, L(ev['title']), 12, kit.T['text'], 600))
        o.append(kit.text(30, y + 40, L(ev['sub']), 10.5, kit.T['muted']))
        y += 64
    return o


def render_keypad(b, y):
    title = L(b.get('title', {'zh': '输入密码', 'en': 'Enter passcode'}))
    hint = L(b.get('hint', {'zh': '', 'en': ''}))
    o = [kit.text(W / 2, y + 28, title, 15, kit.T['text'], 600, anchor='middle')]
    if hint:
        o.append(kit.text(W / 2, y + 50, hint, 11, kit.T['muted'], anchor='middle'))
    dots_y = y + 92
    n = int(b.get('length', 4))
    filled = int(b.get('filled', 2))
    total = n * 22
    for i in range(n):
        cx = (W - total) / 2 + 11 + i * 22
        if i < filled:
            o.append(kit.circle(cx, dots_y, 6, kit.T['primary']))
        else:
            o.append(kit.circle(cx, dots_y, 6, 'none', stroke=kit.T['line']))
    keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', '<']
    kx0 = W / 2 - 92
    for i, k in enumerate(keys):
        r, c = divmod(i, 3)
        cx = kx0 + c * 92
        cy = y + 168 + r * 76
        if not k:
            continue
        o.append(kit.circle(cx, cy, 27, kit.T['surface']))
        if k == '<':
            o.append(kit.icon(cx, cy, 20, kit.IC['back'], kit.T['text']))
        else:
            o.append(kit.text(cx, cy + 7, k, 19, kit.T['text'], 500, anchor='middle'))
    return o


out_dir = os.path.join(HERE, 'gen', 'svg')
os.makedirs(out_dir, exist_ok=True)

parts = list(kit.statusbar())
parts += kit.appbar(L(spec['title']), tuple(spec.get('appbar', {}).get('actions', [])))

y = 112
if spec.get('breadcrumb'):
    parts += kit.text(20, y + 4, L(spec['breadcrumb']), 11, kit.T['muted'])
    y += 30
if spec.get('search'):
    parts += kit.searchbar(y, L(spec['search'].get('hint', '搜索')))
    y += 50

tabs = [L(t) for t in (spec.get('tabs') or [])]
if tabs:
    parts += kit.tabbar(tabs, 0, y)
    y += 50

body = spec.get('body', {})
row_icon = spec.get('rowIcon') or ('music' if '/audio/' in spec.get('unit', '') else 'files')

if spec.get('chips'):
    chip_parts, extra = kit.chips([L(c) for c in spec['chips']], 0, y)
    parts += chip_parts
    y += 46 + extra

if body.get('type') == 'list':
    last_sec = None
    for idx, it in enumerate(body.get('items', [])[:8]):
        if body.get('sections') and it.get('section'):
            sec = L(it['section'])
            if sec != last_sec:
                parts += kit.section(y + 4, sec)
                y += 26
                last_sec = sec
        sub = L(it['sub']) if it.get('sub') else None
        lead = it.get('lead')
        if body.get('numbered'):
            parts += kit.rect(16, y, W - 32, 62, kit.T['surface'], 13, kit.T['line'])
            parts += kit.text(34, y + 36, str(idx + 1), 12, kit.T['dim'], 600, anchor='middle')
            parts += kit.text(54, y + 26, L(it['title']), 13, kit.T['text'], 600)
            if sub:
                parts += kit.text(54, y + 45, sub, 11, kit.T['muted'])
            if it.get('progress') is not None:
                parts += kit.rect(54, y + 52, W - 84, 3, kit.T['surface2'], 2)
                parts += kit.rect(54, y + 52, (W - 84) * float(it['progress']), 3,
                                  kit.T['primary'], 2)
            if it.get('trail') == 'pause':
                parts += kit.icon(W - 40, y + 31, 20, kit.IC['pause'], kit.T['accent'])
            else:
                parts += kit.icon(W - 40, y + 31, 20, kit.IC['more'], kit.T['muted'])
        else:
            parts += kit.row(y, L(it['title']), sub, lead,
                             it.get('trail', 'more'),
                             lead_icon=it.get('icon') or row_icon,
                             progress=it.get('progress'))
        y += 70
elif body.get('type') == 'grid':
    g, y = kit.grid(y, body.get('count', 9), 3,
                    labels=[L(x) for x in body.get('labels', [])],
                    icon_name=body.get('tileIcon'))
    parts += g
elif body.get('type') == 'player':
    parts += render_player(body, y)
elif body.get('type') == 'detail':
    parts += render_detail(body, y)
elif body.get('type') == 'settings':
    parts += render_settings(body, y)
elif body.get('type') == 'unavailable':
    parts += render_unavailable(body, y)
elif body.get('type') == 'calendar':
    parts += render_calendar(body, y)
elif body.get('type') == 'keypad':
    parts += render_keypad(body, y)
elif body.get('type') == 'sheet':
    parts += render_sheet(body, y)
elif body.get('type') == 'compare':
    parts += render_compare(body, y)
elif body.get('type') == 'bubbles':
    parts += render_bubbles(body, y)
elif body.get('type') == 'fields':
    parts += render_fields(body, y)
elif body.get('type') == 'timeline':
    parts += render_timeline(body, y)
elif body.get('type') == 'map':
    parts += render_map(body, y)
elif body.get('type') == 'viewer':
    parts += render_viewer(body, y)
elif body.get('type') == 'form':
    parts += render_form(body, y)
elif body.get('type') == 'empty':
    parts += kit.empty(y + 60, L(body.get('title', '这里还没有内容')),
                       [L(x) for x in body.get('body', ['换个条件试试'])])

if spec.get('note'):
    ny = H - (152 if spec.get('footerAction') else 108)
    parts += kit.rect(16, ny, W - 32, 44, kit.T['surface'], 11, kit.T['line'])
    parts += kit.text(30, ny + 27, L(spec['note']), 11, kit.T['muted'])

if spec.get('footerAction'):
    parts += kit.rect(0, H - 92, W, 92, kit.T['phone'])
    parts += kit.rect(0, H - 92, W, 1, kit.T['line'])
    parts += kit.rect(16, H - 78, W - 32, 46, kit.T['primary'], 12)
    parts += kit.text(W / 2, H - 49, L(spec['footerAction']), 13, kit.T['onPrimary'], 620,
                      anchor='middle')

if spec.get('playerBar'):
    pb = spec['playerBar']
    parts += kit.playerbar(H - 78, L(pb['title']), L(pb['sub']))

nav = spec.get('bottomNav')
if nav:
    parts += kit.bottomnav(nav)
if spec.get('fab'):
    parts += kit.fab(H - 140 if nav else H - 40)

svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
       f'viewBox="0 0 {W} {H}">' + kit.rect(0, 0, W, H, kit.T['phone']) +
       ''.join(parts) + '</svg>')

# 命名：默认（暗·中）不加后缀，其它组合带后缀，便于四联对照
suffix = '' if (args.theme == 'dark' and LOC == 'zh') else f'.{args.theme}.{LOC}'
svg_path = os.path.join(out_dir, spec['id'] + suffix + '.svg')
open(svg_path, 'w', encoding='utf-8').write(svg)

png_path = os.path.join(out_dir, spec['id'] + suffix + '.png')
subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars',
                '--force-device-scale-factor=2', f'--window-size={W},{H}',
                f'--screenshot={png_path}', 'file://' + svg_path],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f'[ok] {svg_path}')
