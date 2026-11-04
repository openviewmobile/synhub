#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""安卓逐页验收覆盖矩阵 —— 证据扫描器（只读，不碰设备）。

用途：对 `lib/src/features/**/*page*.dart` 的每一个页面文件，自动找出
"这个页面在验收证据文档里被提到过没有"，输出 TSV 供人工裁定。

三条证据来源（本脚本只做前两条的自动匹配，第三条靠人工读图/读文档）：
  S1 源码自述：页面文件头部注释里关于真机/未验的措辞（**是自述，不是证据**）
  S2 文档命中：`docs/**/*.md` 里出现该页的**文件名 / 类名 / 页面用到的 i18n 文案**
  S3 像素/机制量：docs 里引用的像素路径与读数（人工裁定）

用法：
  python3 tool/page_coverage_scan.py            # 打印 TSV 到 stdout
  python3 tool/page_coverage_scan.py --json     # 打印 JSON
  python3 tool/page_coverage_scan.py --page drive_collection_page

★ 判据纪律（AGENTS §2.0.30 / §2.0.31）：命中只能证明"文档里提过这个页面"，
  **不能**证明"页面被真机验收过"。所以输出里命中类型分开列：
  `file=` 命中文件名 · `class=` 命中类名 · `text=` 命中该页用到的界面文案。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FEATURES = os.path.join(ROOT, "lib", "src", "features")
DOCS = os.path.join(ROOT, "docs")
ARB_ZH = os.path.join(ROOT, "lib", "l10n", "app_zh.arb")

# 太通用的界面文案不能当判据（否则"取消/保存"会把每个页面都判成"验过"）
GENERIC = {
    "取消", "确定", "删除", "编辑", "保存", "关闭", "返回", "更多", "搜索", "完成",
    "重试", "刷新", "新建", "全部", "加载中", "暂无数据", "删除失败", "保存失败",
    "重命名", "上传", "下载", "分享", "复制", "移动", "详情", "设置", "退出",
    "Empty", "Cancel", "Delete", "Save", "Close", "Back", "More", "Search",
    "Retry", "Refresh", "New", "Done", "Edit", "Rename", "Upload", "Download",
}
MIN_CJK = 4
MIN_ASCII = 6


def is_distinctive(s: str) -> bool:
    s = s.strip()
    if s in GENERIC:
        return False
    if len(s) >= MIN_CJK and re.search(r"[\u4e00-\u9fff]", s):
        return True
    if len(s) >= MIN_ASCII and not re.search(r"[\u4e00-\u9fff]", s):
        return True
    return False


def load_corpus() -> list[tuple[str, str]]:
    """[(相对路径, 全文)] —— docs 下所有 .md（含 evidence-*/README.md 等）。"""
    out: list[tuple[str, str]] = []
    for dirpath, _dirnames, filenames in os.walk(DOCS):
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                text = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            out.append((os.path.relpath(p, ROOT), text))
    return out


def load_arb() -> dict[str, str]:
    try:
        return json.load(open(ARB_ZH, encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def page_files() -> list[str]:
    """枚举"用户界面单元"。

    ★ 判据不是文件名 —— 第一版只扫 `*page*.dart`，漏掉了
      `media/media_player_view.dart`（`class MediaPlayerPage`，就是音视频播放器本体）
      这类"类名是 Page、文件名不是"的文件。
      现在改为两条件**并集**：文件名含 page，**或**文件里声明了 `class XxxPage/Screen`。
    """
    out: set[str] = set()
    for dirpath, _dirnames, filenames in os.walk(FEATURES):
        for fn in filenames:
            if not fn.endswith(".dart"):
                continue
            p = os.path.join(dirpath, fn)
            if "page" in fn:
                out.add(p)
                continue
            try:
                t = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            # ★ CLASS_RE 已含 `Screen`：`security/passcode_screen.dart` 的
            #   `class PasscodeLockScreen` 文件名里没有 "page"，只匹配 `Page` 会漏。
            if CLASS_RE.search(t):
                out.add(p)
    return sorted(out)


CLASS_RE = re.compile(r"^class\s+([A-Za-z0-9_]+(?:Page|Screen))\b", re.M)
TKEY_RE = re.compile(r"context\.t\.([a-zA-Z0-9_]+)")
# `XxxTextKeys.foo`（wrapper 常量，见 AGENTS §2.0.24）
WKEY_RE = re.compile(r"\b([A-Za-z0-9_]+TextKeys)\.([a-z][A-Za-z0-9_]*)")
DTEXT_RE = re.compile(r"dataText\(\s*([A-Za-z0-9_]+(?:TextKeys)?(?:\.[A-Za-z0-9_]+)?)")

CLAIM_POS = ("真机验过", "真机已验", "已真机验", "真机实测", "真机取证", "真机闭环")
CLAIM_NEG = ("真机未验", "真机不可得", "本轮未验", "未验", "只在 Mock", "Mock 核实")

# ★ 只有这些文档里的读数才算"安卓真机证据"；其余 .md 是宿主侧设计/对齐文档，
#   提到文件名**不能**证明上过真机（AGENTS §2.0.30「命中不是证据」）。
DEVICE_DOCS = {
    "android-ui-audit-r348.md",
    "android-acceptance-summary.md",
    "device-verification.md",
    "android-ui-screenshot-audit.md",
    "android-widgets-report.md",
    "live-nas-verification.md",
    "launch-readiness.md",
    "android-compat-matrix.md",
    "android-platform-a.md",
    "android-wording-authority.md",
}


# ★ 逐轮真机台账本身**就是**真机文档：`docs/android-ui-audit-r<NNN>.md`
#   （r348 起每轮一份，r350 起取到 11 屏 A 档证据）。用正则纳入，
#   避免每加一轮就要手改这张表（漏改的后果见 r350：11 条 A 档被降成 D）。
DEVICE_DOC_RE = re.compile(r"^android-ui-audit-r\d+\.md$")


def is_device_doc(rel_doc: str) -> bool:
    base = rel_doc.split("/")[-1]
    return (base in DEVICE_DOCS or "/evidence-r" in rel_doc
            or bool(DEVICE_DOC_RE.match(base)))


def snippet(text: str, line_no: int, width: int = 160) -> str:
    lines = text.splitlines()
    if 1 <= line_no <= len(lines):
        s = lines[line_no - 1].strip()
        return s[:width]
    return ""


def analyse(path: str, corpus: list[tuple[str, str]], arb: dict[str, str]) -> dict:
    src = open(path, encoding="utf-8", errors="replace").read()
    rel = os.path.relpath(path, ROOT)
    head = "\n".join(src.splitlines()[:120])  # 头部注释区

    claims = []
    for kw in CLAIM_POS:
        if kw in head:
            claims.append("+" + kw)
    for kw in CLAIM_NEG:
        if kw in head:
            claims.append("-" + kw)

    classes = CLASS_RE.findall(src)
    # 引用点（谁 new 这个页面）：排除自身文件
    refs = []
    name = os.path.basename(path)[:-5]
    for dirpath, _d, filenames in os.walk(os.path.join(ROOT, "lib")):
        for fn in filenames:
            if not fn.endswith(".dart"):
                continue
            p = os.path.join(dirpath, fn)
            if p == path:
                continue
            try:
                t = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if name in t or any(c + "(" in t for c in classes):
                refs.append(os.path.relpath(p, ROOT))

    needles: list[tuple[str, str]] = [(name, "file")]
    for c in classes:
        needles.append((c, "class"))
    # 界面文案：context.t.X → ARB zh
    texts: list[str] = []
    for key in TKEY_RE.findall(src):
        v = arb.get(key)
        if v and is_distinctive(v):
            texts.append(v)
    # wrapper 常量：把 `xxxSomeKey` 也当 i18n key 试着在 ARB 里找
    for _grp, k in WKEY_RE.findall(src):
        v = arb.get(k)
        if v and is_distinctive(v):
            texts.append(v)
    # 源码里的中文字面量（很多页面走 wrapper 常量或直接写死，ARB 反查不到）
    for lit in re.findall(r"['\"]([^'\"\n]{4,40})['\"]", src):
        if re.search(r"[\u4e00-\u9fff]", lit) and is_distinctive(lit):
            texts.append(lit)
    seen = set()
    text_needles = []
    for t in texts:
        t = t.strip()
        if t and t not in seen:
            seen.add(t)
            text_needles.append(t)
    # ★ 占位符变体：`这个频道还没有{kind}内容` 这类模板串在设备文档里只会出现字面片段，
    #   把 `{...}` 去掉后取长度 ≥4 的片段当补充针（否则复核会漏判成"文档没提"）。
    variants: list[str] = []
    for t in text_needles:
        if "{" in t:
            for seg in re.split(r"\{[^}]*\}", t):
                seg = seg.strip()
                if len(seg) >= 4:
                    variants.append(seg)
    for v in variants:
        if is_distinctive(v) and v not in seen:
            seen.add(v)
            text_needles.append(v)
    text_needles = text_needles[:60]
    for t in text_needles:
        needles.append((t, "text"))

    hits: dict[str, list[str]] = {}
    device_hits: list[dict] = []
    host_hits: list[str] = []
    for needle, kind in needles:
        if not needle:
            continue
        if kind == "text" and not is_distinctive(needle):
            continue
        for rel_doc, text in corpus:
            if rel_doc.endswith("android-page-coverage-matrix.md"):
                continue
            if needle not in text:
                continue
            for i, line in enumerate(text.splitlines(), 1):
                if needle in line:
                    if is_device_doc(rel_doc):
                        device_hits.append({
                            "doc": rel_doc, "line": i, "kind": kind,
                            "needle": needle, "snippet": snippet(text, i),
                        })
                    else:
                        host_hits.append(f"{rel_doc}:{i}")
                    hits.setdefault(kind, []).append(f"{rel_doc}:{i}")
                    break
            else:
                hits.setdefault(kind, []).append(rel_doc)
    for k in hits:
        hits[k] = hits[k][:6]

    # 离线证据：test/ 与 integration_test/ 里出现过该页的类名
    offline_tests: list[str] = []
    for base in ("test", "integration_test"):
        d = os.path.join(ROOT, base)
        for dirpath, _dd, filenames in os.walk(d):
            for fn in filenames:
                if not fn.endswith(".dart"):
                    continue
                p = os.path.join(dirpath, fn)
                try:
                    t = open(p, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                if any(c in t for c in classes):
                    offline_tests.append(os.path.relpath(p, ROOT))

    return {
        "page": rel,
        "name": name,
        "module": rel.split(os.sep)[3] if len(rel.split(os.sep)) > 3 else "",
        "classes": classes,
        "callers": refs,
        "claims": claims,
        "header": head,
        "text_needles": text_needles,
        "hits": hits,
        "hit_kinds": sorted(hits.keys()),
        "device_hits": device_hits[:25],
        "host_hits": sorted(set(host_hits))[:12],
        "offline_tests": sorted(set(offline_tests))[:10],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--page")
    ap.add_argument("--emit", metavar="DIR", help="写出逐页裁定用的输入 JSON")
    args = ap.parse_args()

    corpus = load_corpus()
    arb = load_arb()
    rows = []
    for p in page_files():
        if args.page and args.page not in p:
            continue
        rows.append(analyse(p, corpus, arb))

    if args.emit:
        os.makedirs(args.emit, exist_ok=True)
        out = os.path.join(args.emit, "input.json")
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(rows, fh, ensure_ascii=False, indent=1)
        print(f"wrote {out}: {len(rows)} pages")
        return 0

    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
        return 0

    print("page\tmodule\tclasses\tcallers\tclaims\thit_kinds\tn_text\thits")
    for r in rows:
        print("\t".join([
            r["page"],
            r["module"],
            ",".join(r["classes"]),
            str(len(r["callers"])),
            ",".join(r["claims"]) or "-",
            ",".join(r["hit_kinds"]) or "NONE",
            str(len(r["text_needles"])),
            "; ".join(f"{k}={','.join(v)}" for k, v in r["hits"].items()),
        ]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
