#!/usr/bin/env python3
"""设计 → 代码 → 真机验收：**一条链**的逐单元台账（160 行）。

为什么还要这个：已经把三件事分别查过 ——
  * `check_parity.py`：spec ↔ `design/gen/svg` ↔ `design/gen/flutter` 三方一致
  * `tool/design_code_conformance.py`：单元 ↔ 代码落点（有没有人构造它）
  * `tool/page_coverage_matrix.py`：单元 ↔ 真机裁定（A/B/C/D/E）
但**没有人把它们串起来看**：一个单元可能"有稿、有码、裁定 A"，而裁定引用的证据
其实在讲另一页。本工具把三张表 join 成一张，逐行给出
**稿（spec / 双主题 SVG）· 码（文件 / 是否接线）· 验收（裁定 / 证据）**。

用法：
    python3 tool/design_traceability.py                     # 打印汇总
    python3 tool/design_traceability.py --md docs/design-to-device-traceability.md
    python3 tool/design_traceability.py --json tool/design_traceability_frozen.json
"""
from __future__ import annotations

import argparse
import glob
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONF = os.path.join(ROOT, 'tool/design_code_conformance_frozen.json')
MATRIX_INPUT = os.path.join(ROOT, 'tool/page_coverage_frozen/input.json')
VERDICT_GLOB = os.path.join(ROOT, 'tool/page_coverage_frozen/verdicts/*.json')
OVERRIDES = os.path.join(ROOT, 'tool/page_coverage_overrides.json')
MANUAL_PATH = os.path.join(ROOT, 'tool/design_traceability_manual.json')
GALLERY = os.path.join(ROOT, 'design/synhub_ui/out/screens')


def read_json(p):
    return json.loads(io.open(p, encoding='utf-8').read())


def load_verdicts(pattern: str) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for p in sorted(glob.glob(pattern)):
        for row in read_json(p):
            if not isinstance(row, dict):
                continue
            key = row.get('page') or row.get('name')
            if key:
                out[key] = row
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--md')
    ap.add_argument('--json')
    args = ap.parse_args()

    conf = read_json(CONF)
    pages = {r['page']: r for r in read_json(MATRIX_INPUT)}
    verd = load_verdicts(VERDICT_GLOB)
    overrides = read_json(OVERRIDES) if os.path.exists(OVERRIDES) else {}
    MANUAL = read_json(MANUAL_PATH) if os.path.exists(MANUAL_PATH) else {}
    MANUAL.pop('_comment', None)

    rows, problems = [], []
    counts: dict[str, int] = {}
    for r in conf['rows']:
        unit = r['unit']
        module = r['module']
        page_path = next((p for p in pages if os.path.basename(p) == unit), None)
        page = pages.get(page_path, {})
        v = overrides.get(page_path) or verd.get(page_path) or verd.get(page.get('name', ''))
        code = (v or {}).get('verdict', '?')
        evidence = list((v or {}).get('evidence') or [])
        counts[code] = counts.get(code, 0) + 1
        if code == '?':
            problems.append(f'缺裁定: {unit}')
        if code == 'A' and not evidence:
            problems.append(f'A 级没有证据引用: {unit}')
        spec = r.get('spec')
        gallery = None
        if spec:
            hit = glob.glob(os.path.join(GALLERY, f'*_{module}_*.svg'))
            gallery = next((h for h in hit if os.path.basename(h).endswith(f'_{unit[:-5]}.svg')), None)
        # ★ 引用行锚定：文件在 ≠ 那一行在讲这一屏（行号会随台账增行漂移）。
        #   'line' = 引用行 ±2 行内出现了本屏的单元名/类名；'file' = 只有文件在；
        #   'none' = 没有引用。
        spec_row = {}
        spec_files = glob.glob(os.path.join(ROOT, 'design/spec/*.json'))
        if spec:
            for sf in spec_files:
                if os.path.basename(sf) == spec + '.json':
                    spec_row = read_json(sf)
                    break
        page_cls = set(page.get('classes') or [])
        stem = unit[:-5]
        tier = {stem, stem.replace('_', ' ')} | page_cls
        anchor = 'none'
        if evidence:
            anchor = 'file'
            for cite in evidence:
                path, _, ln = cite.partition(':')
                first = ln.split('..')[0]
                fp = os.path.join(ROOT, path)
                if not os.path.isfile(fp):
                    continue
                try:
                    i = int(first) - 1
                except ValueError:
                    continue
                lines = io.open(fp, encoding='utf-8', errors='replace').read().splitlines()
                window = '\n'.join(lines[max(0, i - 2):i + 3])
                if any(k and k in window for k in tier):
                    anchor = 'line'
                    break
            # ★ 第二档：拿 spec 的**屏幕标题**再找一遍（±3 行）。
            #   比类名弱 —— 像 "More" / "Trash" / "下载" 这种标题本身很泛，
            #   所以台账里单独标成「标题命中」，不并进「行内命中」的基线。
            if anchor == 'file' and spec:
                titles = [v for v in ((spec_row.get('title') or {}).get('zh'),
                                      (spec_row.get('title') or {}).get('en')) if v]
                for cite in evidence:
                    path, _, ln = cite.partition(':')
                    first = ln.split('..')[0]
                    fp = os.path.join(ROOT, path)
                    if not os.path.isfile(fp):
                        continue
                    try:
                        i = int(first) - 1
                    except ValueError:
                        continue
                    lines = io.open(fp, encoding='utf-8', errors='replace').read().splitlines()
                    window = '\n'.join(lines[max(0, i - 3):i + 4])
                    if any(t in window for t in titles):
                        anchor = 'title'
                        break
        # ★ 第三档之后：人工判定。机械判据靠名字/标题，遇到「文档里按像素文件名记账」
        #   或「屏名带真实计数（成员 3 / 成员 12）」就必然认不出；这类只能人读，
        #   但**必须留下理由**（tool/design_traceability_manual.json），否则不算锚定。
        manual_note = MANUAL.get(unit)
        if manual_note and anchor in ('file', 'title'):
            anchor = 'manual'
        rows.append({
            'unit': unit, 'module': module, 'spec': spec, 'cite_anchor': anchor,
            'manual_note': manual_note,
            'design_svg': os.path.relpath(gallery, ROOT) if gallery else None,
            'code_file': page_path or '', 'judge': r['judge'],
            'code_note': r['note'], 'verdict': code,
            'evidence': evidence,
        })

    print(f"单元 {len(rows)} · " + ' · '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    anchors: dict[str, int] = {}
    for r in rows:
        anchors[r['cite_anchor']] = anchors.get(r['cite_anchor'], 0) + 1
    print('引用行锚定:', anchors)
    for p in problems:
        print('★', p)

    if args.md:
        lines = ['# 设计 → 代码 → 真机验收（160 个界面单元的一条链）', '',
                 '> 由 `tool/design_traceability.py` 生成，别手改。',
                 '> 三列分别来自：spec（设计源）· `lib/src`（实现）· 覆盖矩阵（真机裁定）。', '',
                 '| 单元 | 模块 | 设计稿 spec | 设计 SVG | 代码落点 | 接线 | 真机裁定 | 引用行锚定 | 证据 |',
                 '|---|---|---|---|---|---|---|---|---|']
        for r in sorted(rows, key=lambda x: (x['module'], x['unit'])):
            ev = '<br>'.join(f'`{e}`' for e in r['evidence'][:2]) or '—'
            lines.append(
                f"| `{r['unit']}` | {r['module']} | {r['spec'] or '—（非页面）'} | "
                f"{('`' + r['design_svg'] + '`') if r['design_svg'] else '—'} | "
                f"`{r['code_file']}` | {r['judge']} | **{r['verdict']}** | "
                f"{ {'line': '行内命中', 'title': '标题命中', 'manual': '人工判定', 'file': '仅文件在', 'none': '无引用'}[r['cite_anchor']] } | {ev} |")
        io.open(args.md, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
        print('[ok] md →', args.md)
    if args.json:
        io.open(args.json, 'w', encoding='utf-8').write(
            json.dumps({'rows': rows, 'counts': counts}, ensure_ascii=False, indent=1))
        print('[ok] json →', args.json)
    return 0


if __name__ == '__main__':
    sys.exit(main())
