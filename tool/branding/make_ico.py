#!/usr/bin/env python3
"""多尺寸 `.ico` 生成器（Windows 应用图标），只用标准库。

为什么不用 `sips -s format ico`：sips 只会写**单张** ico，Windows 在任务栏/开始菜单/
Alt-Tab 里会按 DPI 各自挑尺寸，单张会被硬拉伸变糊；而 .NET/Win32 的 ico 目录支持
"每张一个 PNG 压缩条目"（Vista 起），塞 16/32/48/64/128/256 六张最稳。

用法：`python3 tool/branding/make_ico.py in.png out.ico 16 32 48 64 128 256`
（输入用 sips 逐尺寸缩好再传进来也一样；本脚本自己调 sips 缩，省得外面写循环）
"""
import os
import struct
import subprocess
import sys
import tempfile


def scaled_png(src: str, px: int, tmpdir: str) -> str:
    out = os.path.join(tmpdir, f'ico_{px}.png')
    subprocess.run(['sips', '-z', str(px), str(px), src, '--out', out],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return out


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    sizes = [int(x) for x in sys.argv[3:]] or [16, 32, 48, 64, 128, 256]
    tmpdir = tempfile.mkdtemp()
    entries = []
    for px in sizes:
        path = scaled_png(src, px, tmpdir)
        entries.append((px, open(path, 'rb').read()))

    # ICONDIR: reserved(2) type(2)=1 count(2)
    head = struct.pack('<HHH', 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    dirs, blobs = b'', b''
    for px, data in entries:
        w = 0 if px >= 256 else px          # 0 表示 256
        h = 0 if px >= 256 else px
        dirs += struct.pack('<BBBBHHII', w, h, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    open(dst, 'wb').write(head + dirs + blobs)
    print(f'{dst}: {len(entries)} 个尺寸 {sizes}，共 {len(head + dirs + blobs)} 字节')


if __name__ == '__main__':
    main()
