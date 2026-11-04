#!/usr/bin/env python3
"""r432 只读像素探针：逐段白像素**游程**（纯标准库，复用 r429 的 PNG 解码）。

为什么要它：`tool/r429_pixel_probe.py` 的 `bbox` 只给**包围盒**，看不出
"哪一段是中心方块、哪一段是整幅边框"。DA88 的判据是"中心方块被放大了多少"，
必须拿到**游程**（连续白像素段）。

用法：
    python3 tool/r432_white_runs.py <png> col|row <fixed> <lo> <hi>
        col → 固定 x，扫 y∈[lo,hi)；row → 固定 y，扫 x∈[lo,hi)
    判据：白 = R,G,B 都 > 200；长度 < 3 的段丢弃（抗锯齿）。
"""
import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    'r429poly', os.path.join(_HERE, 'r429_pixel_probe.py'))
_pp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pp)


def main(argv):
    path, axis, fixed, lo, hi = argv[1], argv[2], int(argv[3]), int(argv[4]), int(argv[5])
    w, h, ch, buf = _pp.read_png(path)

    def is_white(x, y):
        r, g, b = _pp.px(None, x, y, w, ch, buf)
        return r > 200 and g > 200 and b > 200

    runs, cur = [], None
    for t in range(lo, hi):
        x, y = (fixed, t) if axis == 'col' else (t, fixed)
        wpix = is_white(x, y)
        if wpix and cur is None:
            cur = t
        elif not wpix and cur is not None:
            runs.append((cur, t - 1))
            cur = None
    if cur is not None:
        runs.append((cur, hi - 1))
    runs = [r for r in runs if r[1] - r[0] >= 2]
    label = f'列x={fixed}' if axis == 'col' else f'行y={fixed}'
    body = ', '.join(f'[{a},{b}] len={b - a + 1}' for a, b in runs)
    print(f'{os.path.basename(path)} {label}: 白段 {body or "(无)"}')


if __name__ == '__main__':
    main(sys.argv)
