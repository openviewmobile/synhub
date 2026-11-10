#!/usr/bin/env python3
"""打印 CHANGELOG.md 里某个版本的小节正文（无则退出码 1）。

发布说明必须回答"这一版改了什么"。以前 release 正文是一段固定模板，
用户只能自己去看 CHANGELOG 或翻 commit —— 那等于没写。
"""
import io
import re
import sys


def section(text: str, version: str) -> str | None:
    """返回 `## [version]` 到下一个 `## [` 之间的正文。"""
    # ★ 标题行可能带日期：`## [0.2.8] - 2026-11-10`
    start = re.search(rf"^## \[{re.escape(version)}\][^\n]*$", text, re.M)
    if not start:
        return None
    rest = text[start.end():]
    end = re.search(r"^## \[", rest, re.M)
    body = rest[: end.start()] if end else rest
    body = body.strip("\n")
    # 去掉链接引用块（形如 `[0.2.8]: https://…`），那属于文件末尾的脚注
    body = "\n".join(
        line for line in body.split("\n") if not re.match(r"^\[[^\]]+\]:\s", line)
    ).strip()
    return body or None


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: changelog_section.py <版本，例如 0.2.8>", file=sys.stderr)
        return 2
    path = "CHANGELOG.md"
    try:
        text = io.open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"读不到 {path}: {e}", file=sys.stderr)
        return 1
    body = section(text, sys.argv[1])
    if body is None:
        print(f"CHANGELOG.md 里没有 [{sys.argv[1]}] 这一节", file=sys.stderr)
        return 1
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
