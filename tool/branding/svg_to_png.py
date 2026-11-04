#!/usr/bin/env python3
"""SVG → **带真 alpha** 的 PNG（macOS 上用 qlmanage 栅格化）。

为什么需要它：`qlmanage` 能把 SVG 栅格化，但它总是把结果**合成到不透明白底**
（连 alpha 通道都是 255），于是"自适应图标的前景层"会变成一块白板，把背景层
整个盖住（真机上图标只剩白色底 + 图形 —— 踩过）。

做法：同一个 SVG 渲染两次 —— 一次原样（合成到白底），一次在图形后面垫一块
纯黑矩形（合成到黑底）—— 再按标准公式反解出直通 alpha：

    A = 1 - (C_white - C_black) / 255
    C = C_black / A            （A == 0 时颜色无意义，写 0）

用法：`python3 tool/branding/svg_to_png.py in.svg out.png [像素边长]`
"""
import os
import re
import struct
import subprocess
import sys
import tempfile
import zlib


def render(svg: str, size: int, out: str) -> None:
    d = tempfile.mkdtemp()
    subprocess.run(['qlmanage', '-t', '-s', str(size), '-o', d, svg],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    produced = os.path.join(d, os.path.basename(svg) + '.png')
    os.replace(produced, out)


def decode(path: str):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', path
    i, idat = 8, b''
    w = h = ct = None
    while i < len(d):
        ln = struct.unpack('>I', d[i:i + 4])[0]
        typ = d[i + 4:i + 8]
        data = d[i + 8:i + 8 + ln]
        i += 12 + ln
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', data[:10])
            assert bd == 8, '只支持 8bit'
        elif typ == b'IDAT':
            idat += data
        elif typ == b'IEND':
            break
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
    raw = zlib.decompress(idat)
    stride = w * ch
    out, prev, p = bytearray(), bytearray(stride), 0
    for _ in range(h):
        f = raw[p]
        p += 1
        cur = bytearray(raw[p:p + stride])
        p += stride
        for x in range(stride):
            a = cur[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1:
                cur[x] = (cur[x] + a) & 255
            elif f == 2:
                cur[x] = (cur[x] + b) & 255
            elif f == 3:
                cur[x] = (cur[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[x] = (cur[x] + pr) & 255
        out += cur
        prev = cur
    return w, h, ch, out


def write_png(path: str, w: int, h: int, rgba: bytearray) -> None:
    raw = b''.join(b'\x00' + bytes(rgba[y * w * 4:(y + 1) * w * 4]) for y in range(h))

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

    open(path, 'wb').write(
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw, 9))
        + chunk(b'IEND', b''))


def with_black_backing(svg_path: str) -> str:
    """把 SVG 的根节点后面插一块纯黑满幅矩形 → 得到"合成到黑底"的版本。"""
    src = open(svg_path, encoding='utf-8').read()
    m = re.search(r'<svg[^>]*>', src)
    assert m, 'SVG 根节点没找到'
    head, body = src[:m.end()], src[m.end():]
    vb = re.search(r'viewBox="([\d.\s]+)"', m.group(0))
    w, h = (vb.group(1).split()[2:] if vb else ('108', '108'))
    out = os.path.join(tempfile.mkdtemp(), 'black_' + os.path.basename(svg_path))
    open(out, 'w', encoding='utf-8').write(
        head + f'<rect x="0" y="0" width="{w}" height="{h}" fill="#000000"/>' + body)
    return out


def main() -> None:
    svg, out = sys.argv[1], sys.argv[2]
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 1024
    tmp = tempfile.mkdtemp()
    white_png, black_png = os.path.join(tmp, 'w.png'), os.path.join(tmp, 'b.png')
    render(svg, size, white_png)
    render(with_black_backing(svg), size, black_png)

    w, h, ch, W = decode(white_png)
    w2, h2, ch2, B = decode(black_png)
    assert (w, h) == (w2, h2), '两张渲染尺寸不一致'

    rgba = bytearray(w * h * 4)
    for i in range(w * h):
        wo, bo, oo = i * ch, i * ch2, i * 4
        if ch == 4:
            wr, wg, wb = W[wo], W[wo + 1], W[wo + 2]
        else:
            wr = wg = wb = W[wo]
        if ch2 == 4:
            br, bg, bb = B[bo], B[bo + 1], B[bo + 2]
        else:
            br = bg = bb = B[bo]
        # 三个通道各算一次 alpha，取平均（抗锯齿像素更平滑）
        a = 1.0 - ((wr - br) + (wg - bg) + (wb - bb)) / (3 * 255.0)
        a = min(1.0, max(0.0, a))
        if a <= 0.002:
            rgba[oo] = rgba[oo + 1] = rgba[oo + 2] = 0
            rgba[oo + 3] = 0
        else:
            rgba[oo] = min(255, round(br / a))
            rgba[oo + 1] = min(255, round(bg / a))
            rgba[oo + 2] = min(255, round(bb / a))
            rgba[oo + 3] = round(a * 255)
    write_png(out, w, h, rgba)
    print(f'{out}: {w}x{h}（真 alpha）')


if __name__ == '__main__':
    main()
