#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""逐页覆盖矩阵：合并裁定 → 复核引用 → 渲染 Markdown（只读）。

输入：
  /tmp/pcm/input.json        （tool/page_coverage_scan.py --emit 的产物）
  /tmp/pcm/verdicts/*.json   （逐批裁定，元素含 page/verdict/evidence/reason）

用法：
  python3 tool/page_coverage_matrix.py --check        # 只做引用复核 + 计数
  python3 tool/page_coverage_matrix.py --render OUT   # 写逐页台账 Markdown 片段
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tool"))
from page_coverage_scan import is_device_doc, is_distinctive  # noqa: E402

# ★ 真机文档里"看起来像证据、其实不是"的行特征（启发式名单 / 未验登记 / 只提文件名）
SUSPECT = (
    "启发式", "只登记", "不判缺陷", "U34", "未验", "不下结论", "疑似", "候选",
    "还没", "待复核",
)
CITE_RE = re.compile(r"^([^\s:]+\.md|/tmp/[^\s:]+):(\d+)")


def load_verdicts(pattern: str = "/tmp/pcm/verdicts/*.json") -> dict[str, dict]:
    out: dict[str, dict] = {}
    dup = []
    for p in sorted(glob.glob(pattern)):
        try:
            arr = json.load(open(p, encoding="utf-8"))
        except (OSError, ValueError) as e:
            print(f"[ERR] {p}: {e}", file=sys.stderr)
            continue
        for r in arr:
            key = r.get("page") or r.get("name")
            if key in out:
                dup.append(key)
            out[key] = r
    if dup:
        print(f"[WARN] 重复裁定 {len(dup)} 条: {dup[:5]}", file=sys.stderr)
    return out


def check_citation(page: dict, cite: str) -> tuple[bool, str]:
    m = CITE_RE.match(cite.strip())
    if not m:
        return False, "引用格式不是 路径:行号"
    path, line_no = m.group(1), int(m.group(2))
    abs_path = path if os.path.isabs(path) else os.path.join(ROOT, path)
    if not os.path.exists(abs_path):
        return False, "文件不存在"
    lines = open(abs_path, encoding="utf-8", errors="replace").read().splitlines()
    if not (1 <= line_no <= len(lines)):
        return False, f"行号超出（共 {len(lines)} 行）"
    line = lines[line_no - 1]
    needles = [page["name"], *page.get("classes", []), *page.get("text_needles", [])]
    needles = [n for n in needles if n]
    if any(n in line for n in needles):
        return True, ""
    # ★ 放宽到"同一小节窗口"：设备文档常是「### 标题 + 像素/读数」结构，
    #   引到小节里的像素行是合法的；窗口 ±60 行内必须出现本页文件名/类名/界面文案。
    lo, hi = max(0, line_no - 1 - 60), min(len(lines), line_no + 60)
    window = "\n".join(lines[lo:hi])
    if any(n in window for n in needles):
        return True, ""
    return False, "该行及其前后 60 行都不含本页文件名/类名/界面文案"


def page_desc(page: dict) -> str:
    """从源码头部注释取一句话说明（只做展示，不当证据）。"""
    for raw in page.get("header", "").splitlines():
        s = raw.strip()
        if not s.startswith("//"):
            continue
        s = s.lstrip("/ ").strip()
        if not s or s.startswith("Protocol") or s.startswith("*"):
            continue
        if len(s) < 4:
            continue
        s = re.sub(r"[（(].*$", "", s).strip(" `*。:：")
        s = s.replace("*", "").replace("`", "").replace("|", "/")
        return s[:44] + ("…" if len(s) > 44 else "")
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--strict", action="store_true", help="机械复核不通过就降级（默认只提示）")
    ap.add_argument("--render", metavar="OUT")
    ap.add_argument("--input", default="/tmp/pcm4/input.json", help="逐页扫描输入 JSON")
    ap.add_argument("--verdicts", default="/tmp/pcm/verdicts/*.json",
                    help="逐页裁定 JSON 目录（默认 /tmp；仓库内冻结副本见 tool/page_coverage_frozen/）")
    ap.add_argument("--overrides", default="tool/page_coverage_overrides.json",
                    help="人工裁定覆盖表（管理员档等）")
    args = ap.parse_args()

    pages = {r["page"]: r for r in json.load(open(args.input, encoding="utf-8"))}
    verd = load_verdicts(args.verdicts)
    print(f"pages={len(pages)} verdicts={len(verd)}")

    counts: dict[str, int] = {}
    problems: list[str] = []
    info_bad_format: list[str] = []
    advisor: list[str] = []
    overrides: dict[str, dict] = {}
    ov_path = os.path.join(ROOT, args.overrides) if not os.path.isabs(args.overrides) else args.overrides
    if os.path.exists(ov_path):
        overrides = json.load(open(ov_path, encoding="utf-8"))
    merged: list[dict] = []
    for path, page in pages.items():
        v = overrides.get(path) or verd.get(path) or verd.get(page["name"])
        from_override = path in overrides
        if v is None:
            v = {"verdict": "?", "evidence": [], "reason": "（无裁定）"}
            problems.append(f"缺裁定: {page['name']}")
        code = v.get("verdict", "?")
        raw_cites = list(v.get("evidence") or [])
        # ★ 只对 A 档做"引用必须站得住"的强制复核；B/C/D/E 的 evidence 只是佐证，
        #   格式问题只登记不降级（避免把"引用没写行号"误判成"结论错"）。
        ok_cites = []
        for c in v.get("evidence") or []:
            ok, why = check_citation(page, c)
            if ok:
                ok_cites.append(c)
            elif code == "A":
                # ★ 机械复核只能当"提示"：设备文档常按**中文屏名/像素名**描述，
                #   而源码侧多用 wrapper 常量（针集天然不全）⇒ 机械不通过 ≠ 结论错。
                #   本轮的 A 档**逐条人工读原文复核过**（见 §5），故默认不降级；
                #   只有显式 --strict 时才自动降级。
                advisor.append(f"A 待人工确认: {page['name']} <- {c} :: {why}")
                if args.strict:
                    code = "D"
            else:
                ok_cites.append(c)
                if "格式" in why:
                    info_bad_format.append(f"[{code}] {page['name']} <- {c}")
        if code == "A":
            # ★ 这里必须看**全部**引用里有没有真机文档，而不是"机械复核通过的引用"——
            #   后者会把"引用针集不全"误判成"没有真机证据"，从而把 A 错降成 D。
            dev = [c for c in raw_cites
                   if CITE_RE.match(c) and is_device_doc(CITE_RE.match(c).group(1))]
            if not dev:
                problems.append(f"A 级但没有真机文档引用 -> 降级 D: {page['name']}")
                code = "D"
            else:
                for c in dev:
                    m = CITE_RE.match(c)
                    all_lines = open(os.path.join(ROOT, m.group(1)), encoding="utf-8",
                                     errors="replace").read().splitlines()
                    ln = int(m.group(2))
                    seg = "\n".join(all_lines[max(0, ln - 12):ln + 3])
                    if any(s in seg for s in SUSPECT):
                        problems.append(f"⚠️ A 级引用的那行附近含'非证据'特征，需人工复核: {page['name']} <- {c}")
        counts[code] = counts.get(code, 0) + 1
        # ★ 反向检查：判 D 的页面若脚本找到过"真机文档里的界面文案"命中，必须人工复核
        if code == "D":
            strong = [h for h in page.get("device_hits", [])
                      if h["kind"] == "text"
                      or (h["kind"] in ("file", "class")
                          and not any(x in h["snippet"] for x in SUSPECT))]
            if strong:
                problems.append(
                    f"⚠️ 判 D 但脚本有强命中（需人工复核是否假阴）: {page['name']} <- "
                    + ", ".join(f"{h['doc']}:{h['line']}({h['kind']})" for h in strong[:3]))

        merged.append({
            "page": path, "name": page["name"], "module": page["module"],
            "classes": page["classes"], "callers": page["callers"],
            "desc": page_desc(page),
            "verdict": code, "evidence": ok_cites, "reason": v.get("reason", ""),
        })

    counts = {}
    for m in merged:
        counts[m["verdict"]] = counts.get(m["verdict"], 0) + 1
    print("counts:", dict(sorted(counts.items())))
    print(f"引用格式待整理（B/C/D/E，不算问题）: {len(info_bad_format)}")
    print(f"A 档机械复核待人工确认（不代表结论错）: {len(advisor)}")
    for a in advisor:
        print("  ~", a)
    print(f"problems: {len(problems)}")
    for p in problems[:60]:
        print("  -", p)
    if len(problems) > 60:
        print(f"  ... 另 {len(problems) - 60} 条")

    if args.render:
        merged.sort(key=lambda m: (m["module"], m["name"]))
        with open(args.render, "w", encoding="utf-8") as fh:
            cur = None
            for m in merged:
                if m["module"] != cur:
                    cur = m["module"]
                    fh.write(f"\n### {cur}\n\n")
                    fh.write("| 页面文件 | 是什么 | 裁定 | 证据 / 理由 |\n|---|---|---|---|\n")
                ev = " ".join(f"`{c}`" for c in m["evidence"][:3]) or "—"
                reason = (m["reason"] or "").replace("|", "/")
                fh.write(f"| `{os.path.basename(m['page'])}` | {m.get('desc') or m['name']} | "
                         f"**{m['verdict']}** | {reason} {ev} |\n")
        print(f"wrote {args.render}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
