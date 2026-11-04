#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Web 站逐页验收覆盖账 —— 可复算的核对器（只读，不碰浏览器）。

为什么要有它：`docs/web-acceptance-ledger.md` 的 C1 一直是
"**79 屏 ≠ 163 个页面类**" —— 走查拍的是"场景"，账要的是"页面类"。
Windows 站已经有同一套账（`tool/windows_page_coverage.py`），Web 之前是空的。

本脚本把"逐页账"变成**可复算**的三件事：

  ① 枚举：从 `lib/src/features/**/*_page.dart` 抠出全部页面类
     （与 Linux / Windows 台账**同一口径**，否则数字对不上）；
  ② 映射：从 `integration_test/web_ui_audit_test.dart` 里抠出
     "每个 scene 体里**直接引用**了哪些 `*Page` 类"，再与
     `docs/evidence-r715-web/audit_79_scenes/*.png` 里**真拍到**的 scene 求交
     —— 只有"这场过了、且它引用了这个类"才算 `A`；
  ③ 裁定：`tool/web_page_coverage/verdicts.json` 逐类给
     `A`（web 上有像素）或 `U`（未验）＋理由。

用法：
  python3 tool/web_page_coverage.py --matrix
  python3 tool/web_page_coverage.py --check
  python3 tool/web_page_coverage.py --gen        # 重新生成 verdicts（映射规则在下面）

判据纪律（与 Windows 同）：
  * 枚举集与裁定集**集合相等**（不是包含）；
  * `A` 必须带 `evidence`（证据路径），否则不合格；
  * 映射规则写在 `MAP_RULE` 里，改规则必须重跑 `--gen` 并写进台账。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FEATURES = os.path.join(ROOT, "lib", "src", "features")
AUDIT = os.path.join(ROOT, "integration_test", "web_ui_audit_test.dart")
SHOTS = os.path.join(ROOT, "docs", "evidence-r715-web", "audit_79_scenes")
VERDICTS = os.path.join(ROOT, "tool", "web_page_coverage", "verdicts.json")

MAP_RULE = (
    "A = 该 `*Page` 类被某个 `await scene('sXXX', …)` 的**函数体**（含它调用的"
    "顶层助手 `_pushXxx()` / `_toXxx()` / `_wsTile()` 的体，递归 2 层）引用，"
    "**且**该 scene 在 r715 全量复跑里产出了像素"
    "（`docs/evidence-r715-web/audit_79_scenes/sXXX_*.png`）。"
    "其余一律 U，理由写 'web 站本轮无像素（未覆盖）'。"
    "★ 这条是「能追溯到像素」的下界，不是「页面一定被逐屏点到」——判 A 时按此读。"
)

CLASS_RE = re.compile(r"^\s*(?:abstract\s+|final\s+|sealed\s+|base\s+)*"
                      r"class\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*"
                      r"(?:extends|with|implements|\{)", re.M)
SCENE_RE = re.compile(r"await scene\('(s\d+_[a-z0-9_]+)'")


def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return src


def enumerate_pages() -> dict[str, dict]:
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


def scene_bodies() -> dict[str, str]:
    """{scene: 函数体文本}。用 `await scene('X', () async {` 到配对的 `});` 粗切。"""
    src = open(AUDIT, encoding="utf-8").read()
    out: dict[str, str] = {}
    starts = [(m.start(), m.group(1)) for m in SCENE_RE.finditer(src)]
    for i, (pos, name) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(src)
        out[name] = src[pos:end]
    return out


HELPER_RE = re.compile(
    r"^(?:void|Future<void>|Future<bool>|bool)\s+(_[a-zA-Z0-9_]+)\([^)]*\)"
    r"[^{]*\{", re.M)


def helper_bodies() -> dict[str, str]:
    """{helper: 体} —— 顶层 `_name(...) {…}`，按大括号配平粗切。"""
    src = open(AUDIT, encoding="utf-8").read()
    out: dict[str, str] = {}
    for m in HELPER_RE.finditer(src):
        name = m.group(1)
        i = src.index("{", m.start())
        depth, j = 0, i
        while j < len(src):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out[name] = src[i:j + 1]
    return out


def expand(body: str, helpers: dict[str, str], depth: int = 2) -> str:
    """把 body 里引用到的助手体拼进来（深度 depth）。"""
    if depth <= 0:
        return body
    extra = []
    for name, hbody in helpers.items():
        if re.search(rf"\b{re.escape(name)}\s*\(", body):
            extra.append(expand(hbody, helpers, depth - 1))
    return body + "\n" + "\n".join(extra)


def shot_scenes() -> dict[str, str]:
    """{scene: 证据相对路径} —— 只认真的落在磁盘上的像素。"""
    if not os.path.isdir(SHOTS):
        return {}
    out: dict[str, str] = {}
    for name in sorted(os.listdir(SHOTS)):
        if not name.endswith(".png"):
            continue
        scene = re.match(r"(s\d+_[a-z0-9_]+)", name)
        if scene:
            out[scene.group(1)] = rel(SHOTS, name)
    return out


def rel(base: str, name: str) -> str:
    return os.path.relpath(os.path.join(base, name), ROOT)


def build_verdicts() -> list[dict]:
    pages = enumerate_pages()
    bodies = scene_bodies()
    helpers = helper_bodies()
    shots = shot_scenes()
    verdicts: list[dict] = []
    for cls, meta in sorted(pages.items()):
        evidence = ""
        scene_hit = ""
        for scene, body in bodies.items():
            if scene not in shots:
                continue
            if re.search(rf"\b{re.escape(cls)}\b", expand(body, helpers)):
                evidence = shots[scene]
                scene_hit = scene
                break
        if evidence:
            verdicts.append({
                "class": cls, "module": meta["module"], "status": "A",
                "evidence": evidence, "scene": scene_hit,
                "reason": f"r715 79 场复跑：{scene_hit} 拍到像素且引用了本类",
            })
        else:
            verdicts.append({
                "class": cls, "module": meta["module"], "status": "U",
                "evidence": "", "scene": "",
                "reason": "web 站本轮无像素（未覆盖）",
            })
    return verdicts


def load_verdicts() -> list[dict]:
    with open(VERDICTS, encoding="utf-8") as f:
        return json.load(f)["verdicts"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--gen", action="store_true")
    args = ap.parse_args()

    pages = enumerate_pages()
    if args.gen:
        data = {"rule": MAP_RULE, "verdicts": build_verdicts()}
        os.makedirs(os.path.dirname(VERDICTS), exist_ok=True)
        with open(VERDICTS, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
            f.write("\n")
        n_a = sum(1 for v in data["verdicts"] if v["status"] == "A")
        print(f"生成 {VERDICTS}: pages={len(pages)} A={n_a} U={len(data['verdicts'])-n_a}")

    verdicts = load_verdicts()
    by_class = {v["class"]: v for v in verdicts}
    enum_set, verdict_set = set(pages), set(by_class)
    missing = sorted(enum_set - verdict_set)
    extra = sorted(verdict_set - enum_set)
    n_a = sum(1 for v in verdicts if v["status"] == "A")
    n_u = sum(1 for v in verdicts if v["status"] == "U")
    no_evidence = [v["class"] for v in verdicts
                   if v["status"] == "A" and not v["evidence"]]
    bad_status = [v["class"] for v in verdicts if v["status"] not in ("A", "U")]

    if args.matrix:
        print(f"{'status':6}  {'class':44}  {'module':12}  evidence")
        for v in sorted(verdicts, key=lambda r: (r["status"], r["module"], r["class"])):
            print(f"{v['status']:6}  {v['class']:44}  {v['module']:12}  {v['evidence']}")

    print(f"pages={len(enum_set)}  verdicts={len(verdict_set)}  A={n_a}  U={n_u}",
          file=sys.stderr if args.check else sys.stdout)
    ok = True
    if missing:
        ok = False
        print(f"❌ 没裁定的页面（{len(missing)}）：{', '.join(missing[:10])}", file=sys.stderr)
    if extra:
        ok = False
        print(f"❌ 裁定了但页面不存在（{len(extra)}）：{', '.join(extra[:10])}", file=sys.stderr)
    if no_evidence:
        ok = False
        print(f"❌ A 级缺证据（{len(no_evidence)}）：{', '.join(no_evidence[:10])}", file=sys.stderr)
    if bad_status:
        ok = False
        print(f"❌ 非法状态（只允许 A/U）：{', '.join(bad_status[:10])}", file=sys.stderr)
    if args.check and not ok:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
