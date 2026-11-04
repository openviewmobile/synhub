#!/usr/bin/env python3
"""Generate a PNG containing a random 4-digit number, using only the stdlib.

Used to test whether a chat-completions model really performs OCR/vision.
"""
import random
import struct
import sys
import zlib

FONT = {
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
}


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def render(path, digits):
    scale = 24
    pad = 30
    cw, ch = 5 * scale, 7 * scale
    gap = scale
    width = pad * 2 + len(digits) * cw + (len(digits) - 1) * gap
    height = pad * 2 + ch
    # white background
    rows = [[255] * (width * 3) for _ in range(height)]

    def put(x, y, rgb):
        if 0 <= x < width and 0 <= y < height:
            rows[y][x * 3:x * 3 + 3] = list(rgb)

    colors = [(200, 20, 20), (20, 40, 200), (10, 120, 30), (120, 20, 140)]
    for i, d in enumerate(digits):
        ox = pad + i * (cw + gap)
        for ry, line in enumerate(FONT[d]):
            for rx, bit in enumerate(line):
                if bit == "1":
                    for dy in range(scale):
                        for dx in range(scale):
                            put(ox + rx * scale + dx, pad + ry * scale + dy, colors[i % len(colors)])
    write_png(path, width, height, rows)


if __name__ == "__main__":
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(10000)
    rnd = random.Random(seed)
    digits = "".join(rnd.choice("0123456789") for _ in range(4))
    render(sys.argv[1], digits)
    print(digits)
