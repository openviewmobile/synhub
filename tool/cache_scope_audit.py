#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""缓存作用域审计（r435 / `DA90`）—— 把「用量看不到、清不清得掉」变成**可复算的判据**。

## 为什么有这个工具（背景，真机撞出来的）

* r425（`DA83`）：设置页只统计 `chat_cache/` 两层 ⇒ 修法 = 目录级**登记表**
  （`kRegenerableCacheDirs` / `kCacheNotRegenerable`），守卫 `test/cache_scope_guard_test.dart`。
* r434（`DA89`）：**根层**也有文件（pdfx 的 `openData` 把整份 PDF 写在 `cacheDir` 根）
  ⇒ 修法 = 根层正则登记表 `kCacheRootRegenerablePatterns`。
* r435（`DA90`）：把这件事推广到**任意深度 + 任意根层形状**：
  真机上除了 pdfx 的 `<32hex>.pdf`，还躺着 ① 在线字幕 `subtitle_*.srt`（对话框明说要**保留**）
  ② 一个 `<uuid>.jpg`（0 字节，**谁都不认识**，用量看不到、清空删不掉）。
  同一类问题在"目录档"已经解决，在"根层档"只解决了一个形状 ⇒ 本工具负责
  **"未归类 = 0"** 这条可核算判据。

## 判据（本工具的红/绿）

对设备上 `cache/` 的**每一个**路径（任意深度）都必须落进下面之一，否则**未归类**：

1. 登记目录（`kRegenerableCacheDirs`）或其**直接子文件**；
2. 白名单目录（`kCacheNotRegenerable`，整棵子树都不算我们的缓存）；
3. 根层可再生（`kCacheRootRegenerablePatterns` 正则命中）；
4. 根层明示保留（`kCacheRootKeptPatterns` 正则命中，例如在线字幕）；
5. 根层**零字节残留**（`DA90` 新增的可清档：0 字节 = 中断/失败的写入，删掉不丢任何字节）；
6. 系统/第三方自管（`WebView` 等已白名单）。

* **未归类 > 0 ⇒ exit=1**（这就是"下次别静默"的那道闸门）；
* `--json` 输出机器可读结果；`--tree <file>` 用离线快照（`find` 的输出）复算；
  不给 `--tree` 就**当场**从设备拉（`adb shell find`，只读）。

## 用法

```bash
# 真机当场（只读；不需要 root 也能列自己 App 的目录 —— 但 find 需要能读 cache，
# 本仓设备已 adb root ⇒ 用 root 更省事）
python3 tool/cache_scope_audit.py --serial AXGE022428000622

# 离线复算（证据包里存的就是这种快照）
adb shell "cd /data/data/com.openviewai.synhub/cache && find . -mindepth 1" > /tmp/tree.txt
python3 tool/cache_scope_audit.py --tree /tmp/tree.txt
```

★ 本工具**只读**：只 `find` / `ls`，不删、不改。删除只发生在 App 内的 `CacheService.clear()`。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CACHE_SERVICE = REPO / "lib" / "src" / "core" / "media" / "cache_service.dart"
PKG = "com.openviewai.synhub"
DEVICE_CACHE = f"/data/data/{PKG}/cache"


# --------------------------------------------------------------------------- #
# ① 从 Dart 源码读登记表（唯一事实来源就是它；不在这里复制一份，避免两边漂移）
# --------------------------------------------------------------------------- #
@dataclass
class Registries:
    regenerable_dirs: dict[str, str] = field(default_factory=dict)
    not_regenerable: dict[str, str] = field(default_factory=dict)
    root_regenerable: list[str] = field(default_factory=list)
    root_kept: list[str] = field(default_factory=list)
    zero_byte_rule: bool = False

    zero_byte_min_age: int = 3600  # 秒；与 Dart 的 `kCacheRootZeroByteMinAge` 对齐

    def explain(
        self, rel: str, size: int | None, mtime: int | None = None, now: int | None = None
    ) -> tuple[str, str]:
        """返回 (判定, 理由)。判定 ∈ {regenerable, kept, foreign, unclassified}。"""
        parts = rel.split("/")
        top = parts[0]

        # 1) 登记目录（含其直接子文件；更深的层由登记目录自己负责/白名单负责）
        if top in self.regenerable_dirs:
            return "regenerable", f"登记目录 {top}：{self.regenerable_dirs[top]}"
        # 2) 白名单目录：整棵子树都不算我们的缓存
        if top in self.not_regenerable:
            return "foreign", f"白名单 {top}：{self.not_regenerable[top]}"
        # 3) 根层（depth 1 = 只有一个路径片段）
        if len(parts) == 1:
            # ① 明示保留优先于一切（与 Dart 侧同序）
            for src in self.root_kept:
                if re.match(src, rel):
                    return "kept", f"根层明示保留正则 {src}"
            # ② 登记过的可再生形状
            for src in self.root_regenerable:
                if re.match(src, rel):
                    return "regenerable", f"根层可再生正则 {src}"
            # ③ 零字节残留：**必须够旧**（与 Dart 侧 `kCacheRootZeroByteMinAge` 同判据）
            if size == 0 and self.zero_byte_rule:
                if mtime is None or now is None:
                    return (
                        "regenerable",
                        "根层零字节残留（快照无 mtime ⇒ 按旧文件判；真机核对请带 mtime）",
                    )
                age = now - mtime
                if age >= self.zero_byte_min_age:
                    return (
                        "regenerable",
                        f"根层零字节残留（age={age}s ≥ {self.zero_byte_min_age}s；删掉不丢字节）",
                    )
                return (
                    "unclassified",
                    f"根层 0 字节但**刚写过**（age={age}s < {self.zero_byte_min_age}s）："
                    "可能是正在写，代码同样不碰 ⇒ 本工具也判未归类（不是缺陷）",
                )
            return "unclassified", "根层：既不在可再生表、也不在保留表，且不是够旧的零字节残留"
        return "unclassified", f"未登记目录链：{top}/…"


def _block(text: str, start_marker: str, end_marker: str) -> str:
    i = text.index(start_marker)
    j = text.index(end_marker, i)
    return text[i:j]


def load_registries(path: Path = CACHE_SERVICE) -> Registries:
    src = path.read_text(encoding="utf-8")
    reg = Registries()

    blk = _block(src, "const List<CacheDirEntry> kRegenerableCacheDirs", "/// 明确**不计入**")
    for m in re.finditer(r"CacheDirEntry\(\s*'([^']+)'\s*,\s*why:\s*'((?:[^'\\]|\\.)*)'", blk):
        reg.regenerable_dirs[m.group(1)] = m.group(2).replace("\\'", "'")

    blk = _block(src, "const Map<String, String> kCacheNotRegenerable", "/// 缓存**根层**")
    for m in re.finditer(r"'([^']+)'\s*:\s*'((?:[^'\\]|\\.)*)'", blk):
        reg.not_regenerable[m.group(1)] = m.group(2).replace("\\'", "'")

    # ★ 每张 list 用「`const List<CacheRootPattern> <名字> = [` … 首个 `\n];`」切
    #   —— 不能用"到 class CacheService 为止"：那样会把**同一区间里的下一张表**
    #   也算进来（r435 加第二张表时踩到过这个陷阱）
    for name, bucket in (
        ("kCacheRootRegenerablePatterns", "regenerable"),
        ("kCacheRootKeptPatterns", "kept"),
    ):
        m = re.search(
            r"const List<CacheRootPattern> " + name + r" = \[(.*?)\n\];",
            src,
            re.S,
        )
        if m:
            if bucket == "regenerable":
                reg.root_regenerable = _pattern_sources(m.group(1))
            else:
                reg.root_kept = _pattern_sources(m.group(1))
    # ★ 认「声明」而不是认「名字出现在文里」：符号改个名（`..._disabled`）仍会
    #   包含原子串 ⇒ 子串判断会把"已停用"误判成"还在用"（仪器㊽ 同类陷阱）
    reg.zero_byte_rule = "const String kCacheRootZeroByteRule =" in src
    return reg


def _pattern_sources(block: str) -> list[str]:
    out: list[str] = []
    for m in re.finditer(r"source:\s*r?'((?:[^'\\]|\\.)*)'", block):
        # Dart 原始字符串里的 `\.` 在 Python re 里语义相同，原样用
        out.append(m.group(1).replace("\\\\", "\\"))
    return out


# --------------------------------------------------------------------------- #
# ② 取设备树（只读）＋ 文件大小
# --------------------------------------------------------------------------- #
def fetch_tree(serial: str | None) -> tuple[list[str], dict[str, tuple[int, int]]]:
    base = ["adb"] + (["-s", serial] if serial else [])
    find_cmd = f"cd {DEVICE_CACHE} && find . -mindepth 1 | sed 's|^\\./||'"
    raw = subprocess.run(base + ["shell", find_cmd], capture_output=True, text=True, check=True)
    paths = [p for p in raw.stdout.splitlines() if p.strip()]

    # 逐个 stat 太慢 ⇒ 一次 shell 循环拿大小（只对**文件**）
    stat_cmd = (
        f"cd {DEVICE_CACHE} && find . -mindepth 1 -type f -exec stat -c '%s %Y %n' {{}} + "
        "| sed 's|^\\([0-9]* [0-9]*\\) \\./|\\1 |'"
    )
    info: dict[str, tuple[int, int]] = {}
    raw2 = subprocess.run(base + ["shell", stat_cmd], capture_output=True, text=True, check=True)
    for line in raw2.stdout.splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            info[parts[2].strip()] = (int(parts[0]), int(parts[1]))
    return paths, info


def read_tree(path: Path) -> tuple[list[str], dict[str, tuple[int, int]]]:
    txt = path.read_text(encoding="utf-8", errors="replace")
    paths: list[str] = []
    info: dict[str, tuple[int, int]] = {}
    for line in txt.splitlines():
        line = line.strip()
        if not line:
            continue
        # 支持三种快照：纯路径 / `<size> <path>` / `<size> <mtime> <path>`
        # ★ mtime 用"9~10 位整数（epoch 秒）"判，**不能**像早先那样用
        #   "路径里有没有 `.`" 当判据 —— `WebView/hws_webview/index` 没有点，
        #   会把整行（含大小前缀）当成路径，静默把 12 个文件判成"未登记目录链"
        #   （r435 当场踩到：同一份快照前后两次读数不一致）
        m = re.match(r"^(\d+)\s+(\d{9,10})\s+\.?/?(.+)$", line)
        if m:
            path = re.sub(r"^\./", "", m.group(3))
            info[path] = (int(m.group(1)), int(m.group(2)))
            paths.append(path)
            continue
        m = re.match(r"^(\d+)\s+\.?/?([^\s].*)$", line)
        if m:
            path = re.sub(r"^\./", "", m.group(2))
            info[path] = (int(m.group(1)), 0)
            paths.append(path)
            continue
        paths.append(re.sub(r"^\./", "", line))
    return paths, info


# --------------------------------------------------------------------------- #
# ③ 审计
# --------------------------------------------------------------------------- #
def audit(paths: list[str], info: dict[str, tuple[int, int]], reg: Registries) -> dict:
    import time as _time

    now = int(_time.time())
    per_class: dict[str, list[dict]] = {"regenerable": [], "kept": [], "foreign": [], "unclassified": []}
    for rel in paths:
        if rel.endswith("/") or rel == ".":
            continue
        size, mtime = info.get(rel, (None, None))
        cls, why = reg.explain(rel, size, mtime, now)
        per_class[cls].append({"path": rel, "size": size, "mtime": mtime, "why": why})

    def total(cls: str) -> tuple[int, int]:
        fs = [e for e in per_class[cls] if e["size"] is not None]
        return len(fs), sum(e["size"] or 0 for e in fs)

    n_regen, b_regen = total("regenerable")
    n_kept, b_kept = total("kept")
    n_foreign, b_foreign = total("foreign")
    return {
        "registries": {
            "regenerable_dirs": reg.regenerable_dirs,
            "not_regenerable": reg.not_regenerable,
            "root_regenerable": reg.root_regenerable,
            "root_kept": reg.root_kept,
            "zero_byte_rule": reg.zero_byte_rule,
        },
        "per_class": per_class,
        "counts": {
            "regenerable_files": n_regen,
            "regenerable_bytes": b_regen,
            "kept_files": n_kept,
            "kept_bytes": b_kept,
            "foreign_files": n_foreign,
            "foreign_bytes": b_foreign,
            "unclassified": len(per_class["unclassified"]),
            "paths_seen": len(paths),
        },
        "verdict": "OK" if not per_class["unclassified"] else "UNCLASSIFIED",
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="缓存作用域审计（只读）")
    ap.add_argument("--serial", help="adb 设备序列号（不给就用唯一在线设备）")
    ap.add_argument("--tree", type=Path, help="离线快照（find 输出）")
    ap.add_argument(
        "--dart",
        type=Path,
        default=CACHE_SERVICE,
        help="登记表的唯一事实来源（默认 lib/src/core/media/cache_service.dart）。"
        "★ 传一份「改动前」的副本 ⇒ 可以**复算改动前**的判定（本工具这样先红后绿）",
    )
    ap.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    args = ap.parse_args()

    reg = load_registries(args.dart)
    if args.tree:
        paths, info = read_tree(args.tree)
    else:
        paths, info = fetch_tree(args.serial)

    res = audit(paths, info, reg)
    if args.json:
        print(json.dumps(res, ensure_ascii=False, indent=2))
    else:
        c = res["counts"]
        print(f"paths_seen={c['paths_seen']}")
        print(
            "可清理（计入用量/清空）: {f} 个 / {b} B".format(
                f=c["regenerable_files"], b=c["regenerable_bytes"]
            )
        )
        print(f"明示保留（不删，但要登记）: {c['kept_files']} 个 / {c['kept_bytes']} B")
        print(f"白名单（不许动）: {c['foreign_files']} 个 / {c['foreign_bytes']} B")
        print(f"★ 未归类 = {c['unclassified']}  ⇒ {res['verdict']}")
        for e in res["per_class"]["unclassified"]:
            print(f"  ✗ {e['path']}  size={e['size']}  ({e['why']})")
        for e in res["per_class"]["kept"]:
            print(f"  · 保留 {e['path']}  size={e['size']}  ({e['why']})")
    return 0 if res["verdict"] == "OK" else 1


if __name__ == "__main__":
    sys.exit(main())
