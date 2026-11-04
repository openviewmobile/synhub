#!/usr/bin/env python3
"""把 PNG 的真 alpha **合成到一个纯色底**上（用于 iOS 图标这类"不许带 alpha"的场景）。

为什么需要它：Apple 的 App Store 会**拒绝带 alpha 通道的图标**，而我们的品牌图
`assets/branding/icon.svg` 是"圆角矩形 + 圆角外透明"——直接缩放给 iOS，透明角
在装机后会被系统填黑（或直接审核不过）。macOS 反过来：Dock 希望**保留** alpha
（系统自己套圆角遮罩）。所以两端要两种产物，这个脚本负责 iOS 那一种。

用法：`python3 tool/branding/flatten_alpha.py in.png out.png R G B`

★ 不引入 Pillow：`svg_to_png.py` 里已经有 PNG 解码/编码器，直接复用。
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from svg_to_png import decode  # noqa: E402


def write_rgb_png(path: str, w: int, h: int, rgb: bytearray) -> None:
    """写**真正的 RGB** PNG（colorType=2，没有 alpha 通道）。

    为什么不能只把 alpha 全填 255：Apple 判的是"文件里**有没有** alpha 通道"，
    colorType=6 的 255-alpha 图一样会被 App Store Connect 判成"带 alpha"。
    """
    raw = b''.join(b'\x00' + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(t, d):
        return (struct.pack('>I', len(d)) + t + d +
                struct.pack('>I', zlib.crc32(t + d) & 0xffffffff))

    open(path, 'wb').write(
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw, 9))
        + chunk(b'IEND', b''))


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    r, g, b = (int(x) for x in sys.argv[3:6])
    w, h, ch, buf = decode(src)
    assert ch in (3, 4), f'期望 RGB/RGBA，实际通道数={ch}'
    out = bytearray(w * h * 3)
    for i in range(w * h):
        o = i * ch
        if ch == 4:
            a = buf[o + 3]
            if a == 255:
                out[i * 3:i * 3 + 3] = bytes((buf[o], buf[o + 1], buf[o + 2]))
                continue
            # 直通 alpha 合成：C = C_src * a + C_bg * (1 - a)
            ia = 255 - a
            out[i * 3] = (buf[o] * a + r * ia) // 255
            out[i * 3 + 1] = (buf[o + 1] * a + g * ia) // 255
            out[i * 3 + 2] = (buf[o + 2] * a + b * ia) // 255
        else:
            out[i * 3:i * 3 + 3] = bytes((buf[o], buf[o + 1], buf[o + 2]))
    write_rgb_png(dst, w, h, out)
    print(f'{dst}: {w}x{h}（已合成为不透明 #{r:02X}{g:02X}{b:02X}）')


if __name__ == '__main__':
    main()
