#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""r428 · 把 `dumpsys SurfaceFlinger --latency <层>` 的原始输出解析成**帧间隔读数**。

为什么需要它（§4.1-2 的仪器缺口）：
  * `dumpsys gfxinfo <包名>` 对 Flutter 恒 `Total frames rendered: 0`（Flutter 不走 View 层帧计数）；
  * `dumpsys SurfaceFlinger --latency` 不带层名时拿不到 Flutter 的层；
  * 但 **带上 Flutter 的 BLAST 层名** 就能拿到 SurfaceFlinger 记账的逐帧三元组。
    本工具只做"读原始文本 → 算数字"，**不替设备说话**。

输入格式（`--latency <层>` 的输出）：
  第 1 行 = 刷新周期（ns）
  其后每行 = `desiredPresentTime  actualPresentTime  frameReadyTime`（ns 十进制）
  **`0 0 0` 的行 = 空槽**（环形缓冲还没用满），必须剔除，不能当"帧"。

判据（本仓纪律：不许用"看起来流畅"当读数）：
  * 只统计 **非空槽**；
  * 帧间隔 = 相邻两帧 `actualPresentTime` 之差；
  * jank 定义写明在输出里：`间隔 > 1.5 × 刷新周期`；
  * 同时打印 p50 / p90 / p99 / max，以及"总时长 / 帧数"推出来的平均 FPS。

★ **仪器101（本轮撞出来的一条，必须写进读数里）**：
  SurfaceFlinger 的 `--latency` 环形缓冲不是"每个刷新周期一格"，而是
  **"最近 128 个被 posted 的帧"**。所以**空闲时这 128 格里混着很久以前的帧**
  （实测空闲档的跨度能到 25 分钟 ⇒ 拿全缓冲算"平均 FPS"会得到 0.1 fps 这种**假读数**）。
  ⇒ 判据必须**按时间窗**取：只统计 `present >= newest - 窗口` 的那些帧，
  并**先打印窗口里有几帧**——窗口里帧数≈0 时，结论只能是"这段没有帧"，**不是**"帧很快"。

用法：
  python3 tool/r428_frame_latency.py <latency.txt> [--label 名称] [--window-ms 1200]
"""
import argparse
import statistics
import sys

# INT64_MAX = SurfaceFlinger “尚未 present” 的哨兵值（仪器102）
INT64_MAX = 9223372036854775807


def parse(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [ln.strip() for ln in fh if ln.strip()]
    if not lines:
        raise SystemExit("空文件：没有读到任何内容（先确认 adb 那条命令真的输出了东西）")
    # 第 1 行是刷新周期
    period = int(lines[0])
    rows = []
    pending = 0
    for ln in lines[1:]:
        parts = ln.split()
        if len(parts) < 3:
            continue
        try:
            d, a, r = (int(parts[0]), int(parts[1]), int(parts[2]))
        except ValueError:
            continue
        # ★ 仪器102：INT64_MAX（9223372036854775807）是“**该帧还没被 present**”的哨兵，
        #   不是时间戳。当成时间戳会把跳度算成 292 年、窗口里只剩 1 帧（我第一版就踩了）。
        if INT64_MAX in (d, a, r):
            pending += 1
            continue
        rows.append((d, a, r))
    return period, rows, pending


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("latency_txt")
    ap.add_argument("--label", default="")
    ap.add_argument("--window-ms", type=int, default=1200,
                    help="只统计『最新一帧往前 window-ms』窗口内的帧（仪器101）")
    args = ap.parse_args()

    period, rows, pending = parse(args.latency_txt)
    nonempty = [(d, a, r) for (d, a, r) in rows if a != 0 or d != 0 or r != 0]
    empty = len(rows) - len(nonempty)

    print(f"== r428 帧间隔读数{' · ' + args.label if args.label else ''} ==")
    print(f"文件                : {args.latency_txt}")
    print(f"刷新周期(ns)        : {period}  ⇒ {period / 1e6:.4f} ms ≈ {1e9 / period:.1f} Hz")
    print(f"环形缓冲行数        : {len(rows) + pending}（空槽 {empty} 行 ＋ **待 present 哨兵行 {pending}**，两者都已剔除）")
    print(f"**有效帧数**        : {len(nonempty)}")

    if len(nonempty) < 2:
        print("⛔ 有效帧 < 2 ⇒ **量不出帧间隔**（这一档必须如实写“量不出”，不许拿别的数字顶）")
        return 2

    def pct(values, p):
        if not values:
            return float("nan")
        s = sorted(values)
        k = (len(s) - 1) * p / 100.0
        lo, hi = int(k), min(int(k) + 1, len(s) - 1)
        return s[lo] + (s[hi] - s[lo]) * (k - lo)

    # ---- 仪器101：按时间窗取子集（环形缓冲 = 最近 128 个 posted 帧，不是 128 个刷新周期）----
    newest = max(a for (_d, a, _r) in nonempty)
    cutoff = newest - args.window_ms * 1_000_000
    windowed = sorted(a for (_d, a, _r) in nonempty if a >= cutoff)
    print(f"窗口(ms)            : 最新一帧往前 {args.window_ms} ms")
    print(f"**窗口内帧数**      : {len(windowed)}"
          f"（{'✅ 有效' if len(windowed) >= 2 else '⛔ 小于 2 ⇒ 本窗口量不出'}）")
    if len(windowed) >= 2:
        wi = [(b - a) / 1e6 for a, b in zip(windowed, windowed[1:])]
        wjank = [v for v in wi if v * 1e6 > period * 1.5]
        print(f"窗口内 mean/p50/p90/max(ms): {statistics.fmean(wi):.2f} / "
              f"{pct(wi, 50):.2f} / {pct(wi, 90):.2f} / {max(wi):.2f}")
        print(f"窗口内 jank(> {period * 1.5 / 1e6:.2f} ms): {len(wjank)} / {len(wi)}"
              f"（{100.0 * len(wjank) / len(wi):.1f}%）")
        if wjank:
            print("  窗口内最差间隔(ms) : " + ", ".join(f"{v:.2f}" for v in sorted(wjank, reverse=True)[:5]))
    print()
    print("---- 以下是**全缓冲**口径（跨度可能很长，只作参考，不当判据）----")

    # SurfaceFlinger 环形缓冲是按写入顺序排列的；actual present 单调递增。
    present = [a for (_d, a, _r) in nonempty]
    ordered = sorted(present)
    intervals_ns = [b - a for a, b in zip(ordered, ordered[1:])]
    intervals_ms = [v / 1e6 for v in intervals_ns]

    span_ms = (ordered[-1] - ordered[0]) / 1e6
    avg_fps = (len(ordered) - 1) / (span_ms / 1000.0) if span_ms > 0 else float("nan")

    jank_threshold_ns = int(period * 1.5)
    janks = [(i, v) for i, v in enumerate(intervals_ms) if v * 1e6 > jank_threshold_ns]
    # 超过 2 个刷新周期 = 丢帧
    drops = [v for v in intervals_ns if v > 2 * period]

    print(f"观测跨度(ms)        : {span_ms:.1f}")
    print(f"平均 FPS(帧数/跨度) : {avg_fps:.1f}")
    print(f"帧间隔 mean(ms)     : {statistics.fmean(intervals_ms):.2f}")
    print(f"帧间隔 p50(ms)      : {pct(intervals_ms, 50):.2f}")
    print(f"帧间隔 p90(ms)      : {pct(intervals_ms, 90):.2f}")
    print(f"帧间隔 p99(ms)      : {pct(intervals_ms, 99):.2f}")
    print(f"帧间隔 max(ms)      : {max(intervals_ms):.2f}")
    print(f"jank 判据           : 间隔 > 1.5 × 刷新周期 = > {jank_threshold_ns / 1e6:.2f} ms")
    print(f"jank 帧数           : {len(janks)} / {len(intervals_ms)}"
          f"（{100.0 * len(janks) / len(intervals_ms):.1f}%）")
    print(f"> 2 个周期的丢帧     : {len(drops)} 次")
    if janks:
        worst = sorted(janks, key=lambda kv: -kv[1])[:5]
        print("最差的 5 个间隔(ms) : " + ", ".join(f"#{i}={v:.2f}" for i, v in worst))
    print("★ 判据来源 = SurfaceFlinger 自己的逐帧记账（Flutter 表面走 BLAST 层，不是 View 层）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
