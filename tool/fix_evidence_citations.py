#!/usr/bin/env python3
"""把 A 档证据引用的**行号**校准到真正写到"这一屏"的那一行。

为什么：`page_coverage_matrix.py` 只校验「引用的文件存在、行号在范围内」，
`design_traceability_test.dart` ② 也只校验「文件存在」。两者都不校验
**那一行是不是在讲这一屏**。台账文档多年来一直在长（追加行），
被引用的行号就慢慢漂走了 —— 表现为「引用合法，但打开是表头/另一节」。

做法（保守、可复核）：
1. 只为 `verdict == A` 的行校准（B/C/D/E 的证据只是佐证，不动）；
2. 命中键：单元 stem、类名（来自覆盖矩阵 input）、spec 的中/英文标题；
3. 当前行 ±2 行内已经命中 ⇒ **不动**；
4. 否则在同一文件里找命中行，取**离原行最近**的一条改写；找不到 ⇒ 记为「未定位」，不动；
5. 所有改写逐条打印（旧行号 → 新行号 + 命中键 + 该行前 60 字），便于人工抽查。

用法：python3 tool/fix_evidence_citations.py [--apply]
      不带 --apply 时只报告，不写盘。
"""
from __future__ import annotations

import glob
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OVERRIDES = os.path.join(ROOT, 'tool/page_coverage_overrides.json')
VERDICTS = os.path.join(ROOT, 'tool/page_coverage_frozen/verdicts/*.json')
INPUT = os.path.join(ROOT, 'tool/page_coverage_frozen/input.json')
SPECS = os.path.join(ROOT, 'design/spec/*.json')


def read_json(p):
    return json.loads(io.open(p, encoding='utf-8').read())


def write_json(p, data):
    io.open(p, 'w', encoding='utf-8').write(json.dumps(data, ensure_ascii=False, indent=1) + '\n')


def main() -> int:
    apply = '--apply' in sys.argv
    pages = {r['page']: r for r in read_json(INPUT)}
    specs = {}
    for p in glob.glob(SPECS):
        s = read_json(p)
        specs[s['id']] = s
    by_base = {os.path.basename(p): r for p, r in pages.items()}
    spec_by_unit = {s.get('unit'): s for s in specs.values()}

    rewrites, unresolved = [], []

    def keys_for(page_path: str) -> list[str]:
        page = pages.get(page_path, {})
        stem = os.path.basename(page_path)[:-5]
        ks = {stem, stem.replace('_', ' ')} | set(page.get('classes') or [])
        s = spec_by_unit.get('lib/src/features/%s/%s' % (page.get('module', ''), os.path.basename(page_path)))
        if s:
            for lang in ('zh', 'en'):
                v = (s.get('title') or {}).get(lang)
                if v:
                    ks.add(v)
        return [k for k in ks if k and len(k) >= 4]

    def fix(entry: dict, page_path: str, where: str) -> None:
        ev = entry.get('evidence') or []
        if not ev:
            return
        ks = keys_for(page_path)
        for idx, cite in enumerate(ev):
            path, _, ln = cite.partition(':')
            if not ln:
                continue
            first = ln.split('..')[0]
            fp = os.path.join(ROOT, path)
            if not os.path.isfile(fp):
                continue
            try:
                cur = int(first)
            except ValueError:
                continue
            lines = io.open(fp, encoding='utf-8', errors='replace').read().splitlines()

            def hits(i0: int) -> bool:
                w = '\n'.join(lines[max(0, i0 - 2):i0 + 3])
                return any(k in w for k in ks)

            if hits(cur - 1):
                continue
            # ★ 匹配优先级：单元名 > 类名 > spec 标题。
            #   只按"任何键命中"挑最近行会串台（标题常与同模块其它页共用字眼，
            #   r353 的 photo_background_tasks / photo_migration 就这样撞到同一行）。
            stem = os.path.basename(page_path)[:-5]
            tiers = [
                [stem, stem.replace('_', ' ')],
                list(pages.get(page_path, {}).get('classes') or []),
            ]
            # ★ 否定句不算证据：r357 里有一行写着「…对应的是这一页，**不是** `note_shared_page`」，
            #   若按"出现即命中"会把 note_shared_page 引到别人的行上。
            def negated(line: str) -> bool:
                for k in (stem, stem.replace('_', ' ')):
                    if re.search(r'(不是|而非|而不是|并不是)[^。；]{0,14}' + re.escape(k), line):
                        return True
                return False

            cand: list[int] = []
            for tier in tiers:
                tier = [k for k in tier if k and len(k) >= 4]
                if not tier:
                    continue
                cand = [i + 1 for i, l in enumerate(lines)
                        if any(k in l for k in tier) and not negated(l)]
                if cand:
                    break
            if not cand:
                cand = [i + 1 for i, l in enumerate(lines) if any(k in l for k in ks)]
            if not cand:
                unresolved.append(f'{where} {page_path} :: {cite}')
                continue
            best = min(cand, key=lambda i: abs(i - cur))
            new_cite = f'{path}:{best}' if '..' not in ln else f'{path}:{best}..{best + (int(ln.split("..")[1]) - cur)}'
            ev[idx] = new_cite
            rewrites.append((where, page_path, cite, new_cite, lines[best - 1][:60]))

    ov = read_json(OVERRIDES)
    for path, entry in ov.items():
        if isinstance(entry, dict) and entry.get('verdict') == 'A':
            fix(entry, path, 'overrides')

    files = sorted(glob.glob(VERDICTS))
    docs = {p: read_json(p) for p in files}
    for p, rows in docs.items():
        for row in rows:
            if row.get('verdict') != 'A':
                continue
            key = row.get('page') or row.get('name') or ''
            fix(row, key, os.path.basename(p))

    print(f'改写 {len(rewrites)} 条 · 未定位 {len(unresolved)} 条')
    for w in rewrites:
        print(f'  [{"overrides" if w[0]=="overrides" else w[0]}] {os.path.basename(w[1])}: {w[2]} → {w[3]}  | {w[4]}')
    for u in unresolved:
        print('  ★ 未定位', u)

    if apply:
        write_json(OVERRIDES, ov)
        for p, rows in docs.items():
            write_json(p, rows)
        print('[已写盘]')
    else:
        print('（未写盘；加 --apply 生效）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
