#!/usr/bin/env python3
"""r429 只读像素探针（纯标准库；不依赖 PIL/piexif/ffmpeg）。

用途：把 `adb shell screencap -p` 出的 PNG **自己解**成像素，回答"某一行到底画了多高、
字有没有被裁"，而不是信 `uiautomator` 的 `bounds`（仪器94：`bounds` 会被裁到 app 窗口底边）。

用法：
    python3 tool/r429_pixel_probe.py <png> rows  <x0> <x1> <y0> <y1> [--bg 自动|r,g,b] [--tol N]
        → 逐行"墨迹"（与背景色差 > tol 的像素数），并给出首个/末个墨迹行
    python3 tool/r429_pixel_probe.py <png> bbox  <x0> <x1> <y0> <y1> [--bg ...] [--tol N]
        → 该矩形内墨迹的包围盒 + 逐列/逐行的起止
    python3 tool/r429_pixel_probe.py <png> px    <x> <y>
        → 打印单个像素

判据纪律：**背景色从图里自动估**（取该矩形四条边的众数），不许手写"白色"；
墨迹阈值默认 24（0-255 亮度差）。
"""
import sys, zlib, struct
from collections import Counter


def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
    pos, idat, w = 8, [], None
    while pos < len(data):
        ln = struct.unpack('>I', data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, bits, ctype, comp, filt, inter = struct.unpack('>IIBBBBB', body)
            assert bits == 8, 'only 8-bit'
            assert inter == 0, 'no interlace'
            ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
        elif typ == b'IDAT':
            idat.append(body)
        elif typ == b'IEND':
            break
        pos += 12 + ln
    raw = zlib.decompress(b''.join(idat))
    stride = w * ch
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, ch, bytes(out)


def px(img, x, y, w, ch, buf):
    o = (y * w + x) * ch
    if ch == 1:
        return (buf[o],) * 3
    if ch == 2:
        return (buf[o],) * 3
    return (buf[o], buf[o + 1], buf[o + 2])


def lum(c):
    return (c[0] * 299 + c[1] * 587 + c[2] * 114) // 1000


def bg_estimate(img, x0, x1, y0, y1, ch, buf):
    """四条边的众数 = 背景（不许手写白色）。"""
    cnt = Counter()
    for (sx, sy) in ((x0, y0), (x1 - 1, y0), (x0, y1 - 1), (x1 - 1, y1 - 1)):
        for k in range(0, 12):
            cnt[px(img, min(sx + k, x1 - 1), sy, img[0], ch, buf)] += 1
            cnt[px(img, sx, min(sy + k, y1 - 1), img[0], ch, buf)] += 1
    return cnt.most_common(1)[0][0]


def main():
    argv = sys.argv[1:]
    path, mode = argv[0], argv[1]
    w, h, ch, buf = read_png(path)
    img = (w, h)
    print(f'# {path}: {w}x{h} ch={ch}')

    if mode == 'px':
        x, y = int(argv[2]), int(argv[3])
        print(f'px({x},{y}) = {px(img, x, y, w, ch, buf)}')
        return

    x0, x1, y0, y1 = (int(a) for a in argv[2:6])
    rest = argv[6:]
    bg = None
    tol = 24
    if '--bg' in rest:
        v = rest[rest.index('--bg') + 1]
        bg = None if v == 'auto' else tuple(int(t) for t in v.split(','))
    if '--tol' in rest:
        tol = int(rest[rest.index('--tol') + 1])
    if bg is None:
        bg = bg_estimate(img, x0, x1, y0, y1, ch, buf)
    bl = lum(bg)
    print(f'#{mode} 区域 x[{x0},{x1}) y[{y0},{y1})  背景(自动/指定)={bg} lum={bl} tol={tol}')

    rows = []
    for y in range(y0, y1):
        n = 0
        for x in range(x0, x1):
            if abs(lum(px(img, x, y, w, ch, buf)) - bl) > tol:
                n += 1
        rows.append((y, n))
    ink = [(y, n) for y, n in rows if n > 0]
    if mode == 'rows':
        lo, hi = (ink[0][0], ink[-1][0]) if ink else (None, None)
        print(f'# 墨迹行数={len(ink)}  首个={lo}  末个={hi}')
        for y, n in rows:
            if n:
                print(f'{y}\t{n}')
        return

    if mode == 'bbox':
        cols = []
        for x in range(x0, x1):
            n = 0
            for y in range(y0, y1):
                if abs(lum(px(img, x, y, w, ch, buf)) - bl) > tol:
                    n += 1
            if n:
                cols.append(x)
        if not ink or not cols:
            print('# 空：该矩形内没有墨迹')
            return
        print(f'# bbox x[{cols[0]},{cols[-1]}] y[{ink[0][0]},{ink[-1][0]}]  '
              f'墨迹像素={sum(n for _, n in ink)}')
        return
    raise SystemExit('unknown mode ' + mode)


if __name__ == '__main__':
    main()
