#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dump_nodes.py —— 可靠地读 `uiautomator dump` 出来的窗口树。

## 为什么要有这个工具（r375 血的教训）

真机验收里"某节点在不在 dump 里"是常用判据，但**手写正则会骗你**：

* `uiautomator dump` 写出的属性**引号会变**：值里含 `"` 时用**单引号**包裹
  （例：`content-desc='Recycle bin&#10;Files deleted from "My Drive" land here first;…'`），
  值里含 `'` 时用双引号；
* 只写 `re.search(r'content-desc="([^"]*)"', chunk)` 的解析器会**静默漏掉整个节点**
  ⇒ 屏幕上明明有，报告里却写成"`dump` 里没有这个节点"（r374 就犯了两处，r375 复核撤案）。

所以：**一律用 XML 解析，不要用正则抠属性**。

## 用法

    python3 tool/dump_nodes.py <dump.xml> [--grep 关键字] [--all] [--offscreen]

* 默认只列**有文本或 content-desc** 的节点，格式 `bounds  class  text | desc`；
* `--grep K` 只看含 K 的节点（子串，大小写敏感）；
* `--all` 连没有文本的节点也列（看容器/可点区域用）；
* `--offscreen` 也列出 `bounds="[0,0][0,0]"` 的节点（Flutter 预构建但屏外的行）；
* 退出码：命中至少一条 = 0；一条都没命中 = 3（方便脚本判"在不在"）。

## 判据提醒（仪器⑥/㊹）

* `bounds="[0,0][0,0]"` **≠ 不存在** —— 那是 Flutter 预构建、屏外的节点；
* 反过来，"节点在 dump 里" **≠ 肉眼能看见**（可能被遮挡）⇒ 结论帧仍要有同刻截图。
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET


def walk(elem):
    yield elem
    for child in elem:
        yield from walk(child)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="罗列 uiautomator dump 的节点（XML 解析，不受引号形态影响）")
    ap.add_argument("path")
    ap.add_argument("--grep", default=None)
    ap.add_argument("--all", action="store_true", dest="show_all")
    ap.add_argument("--offscreen", action="store_true")
    args = ap.parse_args(argv)

    try:
        root = ET.parse(args.path).getroot()
    except ET.ParseError as exc:  # dump 被截断 / 空文件
        print(f"[dump_nodes] 解析失败：{exc}（文件可能为空或被截断）", file=sys.stderr)
        return 2

    rows = []
    for node in walk(root):
        bounds = node.get("bounds", "?")
        text = node.get("text", "") or ""
        desc = node.get("content-desc", "") or ""
        if not args.offscreen and bounds == "[0,0][0,0]":
            continue
        blob = text or desc
        if not blob.strip() and not args.show_all:
            continue
        line = f"{bounds}\t{node.get('class','')}\t{blob}"
        if text and desc:
            line = f"{bounds}\t{node.get('class','')}\t{text} | {desc}"
        if args.grep and args.grep not in line:
            continue
        rows.append(line)

    for line in rows:
        print(line)
    print(f"[dump_nodes] {args.path}: 命中 {len(rows)} 个节点", file=sys.stderr)
    return 0 if rows else 3


if __name__ == "__main__":
    raise SystemExit(main())
