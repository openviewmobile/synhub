#!/usr/bin/env python3
"""生成可直接拖进 Figma 的 SVG 画板（矢量 + 可编辑文本）。

为什么不是"直接操作 Figma 窗口"：本机 Figma 是 GUI 应用，我没有它的 UI 自动化通道
（AppleScript 点窗口既脆弱又要辅助功能授权）。Figma **原生支持导入 SVG**（保持矢量、
文本仍是文本对象），所以设计稿走 "生成 SVG → 你拖进 Figma 评审/改" 这条路最稳。

产物：
  design/figma/r459-audio-flow.svg          两屏画板（393×852，Figma 标准手机尺寸）
  design/figma/r459-audio-flow-preview.html 预览壳（拿浏览器截图看效果）
用法：
  python3 design/figma/gen_audio_flow.py
"""
from __future__ import annotations

import os

W, H = 393, 852
GAP = 64
PAD_TOP = 96
NOTES_W = 0  # 备注不放进 SVG（Figma 里画板要干净）；预览页另写

BG = '#0d1014'
PHONE = '#0f1216'
SURFACE = '#1a1f27'
SURFACE2 = '#243040'
LINE = '#2a3140'
TEXT = '#e9edf2'
MUTED = '#98a2af'
DIM = '#6f7b8b'
PRIMARY = '#4c8dff'
PRIMARY_SOFT = '#1d2c48'
ACCENT = '#8fb8ff'
FONT = "-apple-system, 'PingFang SC', 'Helvetica Neue', Arial, sans-serif"


def esc(s: str) -> str:
    return (s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))


parts: list[str] = []


def rect(x, y, w, h, fill, rx=0, stroke=None, sw=1, opacity=None):
    a = f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"'
    if stroke:
        a += f' stroke="{stroke}" stroke-width="{sw}"'
    if opacity is not None:
        a += f' fill-opacity="{opacity}"'
    return a + '/>'


def circle(cx, cy, r, fill, stroke=None, sw=1, opacity=None):
    a = f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}"'
    if stroke:
        a += f' stroke="{stroke}" stroke-width="{sw}"'
    if opacity is not None:
        a += f' fill-opacity="{opacity}"'
    return a + '/>'


def text(x, y, s, size=13, fill=TEXT, weight=400, anchor='start', ls=0):
    return (f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
            f'fill="{fill}" font-weight="{weight}" text-anchor="{anchor}"'
            + (f' letter-spacing="{ls}"' if ls else '') + f'>{esc(s)}</text>')


def tri(cx, cy, s, fill):
    """右向三角形（播放）。"""
    return (f'<path d="M{cx - s * 0.45} {cy - s * 0.62} L{cx + s * 0.62} {cy} '
            f'L{cx - s * 0.45} {cy + s * 0.62} Z" fill="{fill}"/>')


def pause_icon(cx, cy, s, fill):
    bw = s * 0.22
    return (rect(cx - bw * 1.6, cy - s * 0.62, bw, s * 1.24, fill, 1) +
            rect(cx + bw * 0.6, cy - s * 0.62, bw, s * 1.24, fill, 1))


def dots(cx, cy, r, fill, gap=5):
    return ''.join(circle(cx, cy + dy, r, fill) for dy in (-gap, 0, gap))


def frame(x0: int, y0: int, kind: str) -> list[str]:
    """画一屏；坐标相对画板左上角。"""
    o: list[str] = []
    o.append(rect(x0, y0, W, H, PHONE, 30, LINE))
    # 状态栏
    o.append(text(x0 + 20, y0 + 30, '9:41', 11, MUTED))
    o.append(text(x0 + W - 24, y0 + 30, '⌁ ▮▮▮', 11, MUTED, anchor='end'))
    # 顶栏
    o.append(rect(x0 + 1, y0 + 44, W - 2, 1, LINE))
    o.append(text(x0 + 22, y0 + 78, '‹', 20, TEXT))
    title = '正在播放' if kind == 'player' else '网络电台'
    o.append(text(x0 + 52, y0 + 79, title, 15, TEXT, 600))
    if kind == 'player':
        o.append(text(x0 + W - 78, y0 + 78, '♡', 17, TEXT))
        o.append(dots(x0 + W - 36, y0 + 72, 2.4, TEXT))
    else:
        o.append(text(x0 + W - 78, y0 + 78, '⌕', 16, TEXT))
        o.append(dots(x0 + W - 36, y0 + 72, 2.4, TEXT))

    if kind == 'player':
        # 封面
        o.append(rect(x0 + 16, y0 + 108, W - 32, 176, '#1b2534', 18, '#2b3648'))
        o.append(circle(x0 + W / 2, y0 + 196, 54, '#2a3a55', opacity=0.55))
        o.append(text(x0 + W / 2, y0 + 200, '封面 / 主色律动', 11, '#94a9c7', anchor='middle', ls=1))
        # 曲目
        o.append(text(x0 + 16, y0 + 316, 'Demo Song', 17, TEXT, 640))
        o.append(text(x0 + 16, y0 + 337, 'Demo Artist · 320 kbps · 无损直连', 12, MUTED))
        # 进度
        o.append(rect(x0 + 16, y0 + 362, W - 32, 4, '#242b36', 3))
        o.append(rect(x0 + 16, y0 + 362, (W - 32) * 0.38, 4, PRIMARY, 3))
        o.append(circle(x0 + 16 + (W - 32) * 0.38, y0 + 364, 6, '#ffffff'))
        o.append(text(x0 + 16, y0 + 385, '1:32', 11, MUTED))
        o.append(text(x0 + W - 16, y0 + 385, '−2:19', 11, MUTED, anchor='end'))
        # 传输控制
        cy = y0 + 424
        o.append(text(x0 + 34, cy + 5, '⤨', 15, MUTED, anchor='middle'))
        o.append(text(x0 + 104, cy + 5, '◀◀', 13, TEXT, anchor='middle'))
        o.append(circle(x0 + W / 2, cy, 30, PRIMARY))
        o.append(tri(x0 + W / 2 + 2, cy, 15, '#08111f'))
        o.append(text(x0 + W - 104, cy + 5, '▶▶', 13, TEXT, anchor='middle'))
        o.append(text(x0 + W - 34, cy + 5, '↻', 14, MUTED, anchor='middle'))
        # 歌词
        lx, ly, lw = x0 + 16, y0 + 466, W - 32
        lh = 214
        o.append(rect(lx, ly, lw, lh, SURFACE, 14, LINE))
        o.append(text(lx + 14, ly + 24, '歌词', 11.5, MUTED, 600, ls=0.4))
        o.append(text(lx + lw - 14, ly + 24, 'lrclib · 带时间轴', 10.5, '#5c6675', anchor='end'))
        lines = [
            (ly + 62, 'Sample lyric line one', DIM, 12.5, 400),
            (ly + 92, 'Sample lyric line two', DIM, 12.5, 400),
            (ly + 128, "Sample lyric line three", ACCENT, 15, 650),
            (ly + 158, 'Sample lyric line four', DIM, 12.5, 400),
            (ly + 188, 'Sample lyric line five', DIM, 12.5, 400),
        ]
        for yy, s, c, sz, w in lines:
            o.append(text(lx + lw / 2, yy, s, sz, c, w, anchor='middle'))
        # 底部快捷
        qy = y0 + H - 74
        labels = [('≡', '播放队列'), ('⇄', '投送到'), ('♩', '音效'), ('⏱', '睡眠定时')]
        for i, (ic, lb) in enumerate(labels):
            cx = x0 + 16 + (W - 32) * (i + 0.5) / 4
            o.append(rect(cx - 17, qy - 17, 34, 34, SURFACE, 10))
            o.append(text(cx, qy + 5, ic, 14, TEXT, anchor='middle'))
            o.append(text(cx, qy + 34, lb, 10.5, MUTED, anchor='middle'))
        return o

    # ---- 电台 ----
    o.append(rect(x0 + 1, y0 + 96, W - 2, 0, LINE))
    chips = [('全部', True), ('收藏', False), ('最近播放', False), ('我的电台', False)]
    cx = x0 + 16
    for lb, on in chips:
        cw = 12 + len(lb) * 12 + 14
        if on:
            o.append(rect(cx, y0 + 104, cw, 32, PRIMARY_SOFT, 9, '#2f4a7a'))
            o.append(text(cx + cw / 2, y0 + 125, lb, 12, ACCENT, 600, anchor='middle'))
        else:
            o.append(rect(cx, y0 + 104, cw, 32, SURFACE, 9))
            o.append(text(cx + cw / 2, y0 + 125, lb, 12, MUTED, anchor='middle'))
        cx += cw + 8
    rows = [
        ('BBC Radio 1', 'Shoutcast · 128 kbps', '#8fb8ff', True),
        ('Radio Paradise', 'MP3 · 320 kbps', '#ffd28f', False),
        ('Jazz24', 'AAC · 96 kbps', '#a6e3c5', False),
        ('Classic FM', 'HLS · 128 kbps', '#f0a8c8', False),
    ]
    ry = y0 + 152
    for name, meta, col, playing in rows:
        o.append(rect(x0 + 16, ry, W - 32, 62, SURFACE, 13))
        o.append(rect(x0 + 26, ry + 11, 40, 40, col, 11, opacity=0.9))
        o.append(text(x0 + 46, ry + 37, '♫', 14, '#0b121e', 700, anchor='middle'))
        o.append(text(x0 + 78, ry + 29, name, 13, TEXT, 600))
        o.append(text(x0 + 78, ry + 47, meta, 11, MUTED))
        bx = x0 + W - 46
        if playing:
            o.append(circle(bx, ry + 31, 20, PRIMARY))
            o.append(pause_icon(bx, ry + 31, 11, '#08111f'))
        else:
            o.append(circle(bx, ry + 31, 20, SURFACE2))
            o.append(tri(bx + 2, ry + 31, 12, ACCENT))
        ry += 70
    # 添加自定义
    o.append(rect(x0 + 16, ry, W - 32, 56, SURFACE, 13, opacity=0.55))
    o.append(rect(x0 + 26, ry + 8, 40, 40, '#2a3341', 11))
    o.append(text(x0 + 46, ry + 34, '＋', 15, MUTED, anchor='middle'))
    o.append(text(x0 + 78, ry + 26, '添加自定义电台', 13, '#b9c3d0', 600))
    o.append(text(x0 + 78, ry + 44, '粘贴播放列表或直链', 11, MUTED))
    # 迷你播放器
    my = y0 + H - 88
    o.append(rect(x0 + 12, my, W - 24, 64, '#1d2531', 16, '#2c3646'))
    o.append(rect(x0 + 24, my + 12, 40, 40, '#22314a', 10, '#2b3648'))
    o.append(text(x0 + 80, my + 27, 'BBC Radio 1', 12.5, TEXT, 600))
    o.append(text(x0 + 80, my + 45, '正在播放 · 网络电台', 10.5, MUTED))
    o.append(circle(x0 + W - 84, my + 32, 17, PRIMARY))
    o.append(pause_icon(x0 + W - 84, my + 32, 9.5, '#08111f'))
    o.append(text(x0 + W - 42, my + 37, '✕', 14, MUTED, anchor='middle'))
    return o


def main() -> None:
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)))
    total_w = W * 2 + GAP
    total_h = H + PAD_TOP
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{total_w}" height="{total_h}" '
           f'viewBox="0 0 {total_w} {total_h}">',
           rect(0, 0, total_w, total_h, BG)]
    # 标题
    svg.append(text(8, 34, 'r459 · 音频流程设计稿（第 1 版）', 18, TEXT, 650))
    svg.append(text(8, 56, '① 现在播放：歌词由播放位置驱动、全屏只有一个 ⋮    '
                           '② 网络电台：行内可直接播放 + 底部常驻迷你播放器（暂停 / 关闭）', 11.5, MUTED))
    svg += frame(0, PAD_TOP, 'player')
    svg += frame(W + GAP, PAD_TOP, 'radio')
    # 画板名（Figma 导入后按图层名分帧）
    svg.append(f'<g id="frame-now-playing">')
    svg.append('</g>')
    svg.append('</svg>')

    svg_path = os.path.join(out_dir, 'r459-audio-flow.svg')
    with open(svg_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(svg))

    html = f"""<!doctype html><meta charset="utf-8">
<body style="margin:0;background:{BG};display:grid;place-items:center;min-height:100vh">
<img src="r459-audio-flow.svg" width="{total_w}" style="display:block">
</body>"""
    with open(os.path.join(out_dir, 'r459-audio-flow-preview.html'), 'w', encoding='utf-8') as f:
        f.write(html)
    print(f'[ok] {svg_path}  ({total_w}x{total_h})')


if __name__ == '__main__':
    main()
