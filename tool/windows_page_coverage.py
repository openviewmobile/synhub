#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Windows 站逐页验收覆盖账 —— 可复算的核对器（只读，不碰 VM）。

为什么要有这个脚本：`docs/platform-windows.md` §20 的九模块整轮只走到
"每组的主路径"（23 张像素），**不等于**逐页验过。Linux/Android 都有
"141 个 `*_page.dart` / 163 个页面类"的逐页账，Windows 之前是空的。
本脚本把"逐页账"变成**可复算**的两件事：

  ① 枚举：从 `lib/src/features/**/*_page.dart` 里抠出全部页面类
     （与 Linux 台账同口径，别用别的过滤条件，否则数字对不上）；
  ② 裁定：读 `tool/windows_page_coverage/verdicts.json`，逐个类要一个
     `A`（Windows 上有像素/读数）或 `U`（未验）＋理由。

用法：
  python3 tool/windows_page_coverage.py --matrix     # 打印逐页矩阵
  python3 tool/windows_page_coverage.py --check      # 判定集必须与枚举集**完全相等**
  python3 tool/windows_page_coverage.py --check --doc docs/windows-page-coverage.md

判据纪律：
  * 枚举集与裁定集**集合相等**（多一个 = 凭空写字；少一个 = 漏页），
    不是"包含"；
  * `A` 必须带 `evidence`（证据路径），否则视为不合格 —— 与全仓
    "没证据不许写已验"同一条；
  * `--doc` 给的文档里出现 `A=<n>` / `U=<n>` 时，数字必须与本次复算一致
    （防止文档里抄死一个旧数字）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FEATURES = os.path.join(ROOT, "lib", "src", "features")
VERDICTS = os.path.join(ROOT, "tool", "windows_page_coverage", "verdicts.json")

# 只认 *_page.dart（Linux 台账的 141 文件 / 163 类就是这条口径）。
CLASS_RE = re.compile(r"^\s*(?:abstract\s+|final\s+|sealed\s+|base\s+)*"
                      r"class\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*"
                      r"(?:extends|with|implements|\{)", re.M)


def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return src


def enumerate_pages() -> dict[str, dict]:
    """{class: {file, module}} —— 只收 `*_page.dart` 里声明的类。"""
    out: dict[str, dict] = {}
    for dirpath, _dirs, files in os.walk(FEATURES):
        for name in sorted(files):
            if not name.endswith("_page.dart"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ROOT)
            module = os.path.relpath(dirpath, FEATURES).split(os.sep)[0]
            src = strip_comments(open(path, encoding="utf-8").read())
            for m in CLASS_RE.finditer(src):
                cls = m.group(1)
                if not cls.endswith("Page"):
                    continue
                out[cls] = {"file": rel, "module": module}
    return out


def load_verdicts() -> list[dict]:
    with open(VERDICTS, encoding="utf-8") as f:
        data = json.load(f)
    return data["verdicts"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", action="store_true", help="打印逐页矩阵")
    ap.add_argument("--check", action="store_true", help="集合相等 + 数字自洽")
    ap.add_argument("--doc", default="", help="要核对数字的台账文档")
    args = ap.parse_args()

    pages = enumerate_pages()
    verdicts = load_verdicts()
    by_class = {v["class"]: v for v in verdicts}

    enum_set, verdict_set = set(pages), set(by_class)
    missing = sorted(enum_set - verdict_set)      # 有页面但没裁定
    extra = sorted(verdict_set - enum_set)        # 裁定了但页面不存在
    dup = len(verdicts) - len(verdict_set)        # 同一个类裁了两次

    n_a = sum(1 for v in verdicts if v["status"] == "A")
    n_u = sum(1 for v in verdicts if v["status"] == "U")
    bad_status = [v["class"] for v in verdicts if v["status"] not in ("A", "U")]
    no_evidence = [v["class"] for v in verdicts
                   if v["status"] == "A" and not v["evidence"]]

    if args.matrix:
        print(f"{'status':6}  {'class':42}  {'module':12}  evidence")
        for v in sorted(verdicts, key=lambda r: (r["status"], r["module"], r["class"])):
            print(f"{v['status']:6}  {v['class']:42}  {v['module']:12}  {v['evidence']}")

    print(f"pages={len(enum_set)}  verdicts={len(verdict_set)}  A={n_a}  U={n_u}",
          file=sys.stderr if args.check else sys.stdout)

    ok = True
    if missing:
        ok = False
        print(f"❌ 没裁定的页面（{len(missing)}）：{', '.join(missing[:10])}", file=sys.stderr)
    if extra:
        ok = False
        print(f"❌ 裁定了但页面不存在（{len(extra)}）：{', '.join(extra[:10])}", file=sys.stderr)
    if dup:
        ok = False
        print(f"❌ 同一个页面类裁定了 {dup} 次", file=sys.stderr)
    if bad_status:
        ok = False
        print(f"❌ 非法状态（只允许 A/U）：{', '.join(bad_status[:10])}", file=sys.stderr)
    if no_evidence:
        ok = False
        print(f"❌ A 却没写证据：{', '.join(no_evidence[:10])}", file=sys.stderr)

    if args.doc:
        doc = open(os.path.join(ROOT, args.doc), encoding="utf-8").read()
        for key, val in (("A", n_a), ("U", n_u)):
            m = re.search(rf"\*\*{key} = (\d+)\*\*", doc)
            if not m:
                ok = False
                print(f"❌ 台账里没有 `**{key} = n**` 这一行（数字无法核对）", file=sys.stderr)
            elif int(m.group(1)) != val:
                ok = False
                print(f"❌ 台账写 {key}={m.group(1)}，复算 {key}={val}", file=sys.stderr)
        if f"**合计 = {len(enum_set)}**" not in doc:
            ok = False
            print(f"❌ 台账里没有 `**合计 = {len(enum_set)}**`", file=sys.stderr)

    if args.check:
        print("OK" if ok else "FAILED")
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
