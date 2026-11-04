#!/usr/bin/env python3
"""设计 → 代码 的**逐单元对账**：160 个界面单元，每一个都要能回答三件事。

1. **有设计稿吗？** —— `design/spec/*.json` 的 `unit` 字段 ↔ `design/synhub_ui/out/screens/` 的 SVG
2. **有实现吗？** —— `lib/src/**/<file>` 里定义的那个 Widget 类
3. **接上线了吗？** —— 这个类/这个文件的公开入口**在别处被构造过**（不是"写了但没人用"）

为什么需要它：设计稿与代码是两套命名（`audio_detail` ↔ `audio_detail_page.dart`），
`check_parity.py` 只对得上 spec ↔ 生成的**设计页**，从来没查过"真 App 里这一屏有没有人打开"。
于是"设计稿有 154 张、代码里也都有文件"这句话，可能是**一堆没人路由到的死页面**。

分档（`judge`）：
* `直达`   —— Widget 类在**别的文件**里被构造（路由/`MaterialPageRoute` 直接打开）
* `经入口` —— 类只在本文件里构造，但本文件的**其它公开符号**在别处被调用（如 `Xxx.open()`）
* `内部件` —— 私有 Widget（`_Xxx`），被同文件的页面使用
* `非界面` —— 没有 Widget 类（数据模型/平台抽象），必须在 `design/component-units.md` 登记

用法：
    python3 tool/design_code_conformance.py                # 打印汇总 + 异常清单
    python3 tool/design_code_conformance.py --md PATH      # 另存 markdown 表
    python3 tool/design_code_conformance.py --json PATH    # 另存冻结快照（守卫用）
"""
from __future__ import annotations

import argparse
import glob
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INVENTORY = os.path.join(ROOT, 'design/synhub_ui/inventory.json')
SPEC_DIR = os.path.join(ROOT, 'design/spec')
COMPONENT_DOC = os.path.join(ROOT, 'design/component-units.md')
SRC_GLOB = os.path.join(ROOT, 'lib/src/**/*.dart')

WIDGET_BASES = ('StatelessWidget', 'StatefulWidget', 'ConsumerWidget',
                'ConsumerStatefulWidget', 'HookWidget')
CLASS_RE = re.compile(r'class\s+(\w+)\s+extends\s+(\w+)')
PUBLIC_SYMBOL_RE = re.compile(r'^(?:class|mixin|enum)\s+([A-Z]\w*)|^(?:[\w<>, ?]+\s+)?([a-z]\w*)\s*\(', re.M)


def read(p: str) -> str:
    return io.open(p, encoding='utf-8').read()


def spec_units() -> dict[str, str]:
    """unit 路径 → spec id"""
    out = {}
    for p in glob.glob(os.path.join(SPEC_DIR, '*.json')):
        s = json.loads(read(p))
        u = s.get('unit', '')
        if u.endswith('.dart'):
            out[u] = s['id']
    return out


def component_units() -> set[str]:
    if not os.path.exists(COMPONENT_DOC):
        return set()
    rows = [l for l in read(COMPONENT_DOC).split('\n') if l.startswith('| `lib/')]
    return {re.match(r'\| `([^`]+)`', r).group(1) for r in rows}


def widget_class(src: str) -> tuple[str, str] | None:
    for m in CLASS_RE.finditer(src):
        name, base = m.group(1), m.group(2)
        if base in WIDGET_BASES:
            return name, base
    return None


def public_symbols(src: str, skip: str) -> set[str]:
    out = set()
    for m in re.finditer(r'^(?:class|mixin|enum)\s+([A-Z]\w*)', src, re.M):
        if m.group(1) != skip:
            out.add(m.group(1))
    for m in re.finditer(r'^(?:[\w<>,\[\] ?]+\s+)?([a-z]\w*)\s*\(', src, re.M):
        out.add(m.group(1))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--md')
    ap.add_argument('--json')
    args = ap.parse_args()

    inventory = json.loads(read(INVENTORY))
    units2spec = spec_units()
    comps = component_units()
    srcs = glob.glob(SRC_GLOB, recursive=True)
    texts = {p: read(p) for p in srcs}
    by_base: dict[str, list[str]] = {}
    for p in srcs:
        by_base.setdefault(os.path.basename(p), []).append(p)

    rows, missing_spec, missing_file, orphans = [], [], [], []
    counts = {'直达': 0, '经入口': 0, '内部件': 0, '非界面': 0}

    for item in inventory:
        f = item['file']
        paths = by_base.get(f, [])
        spec_id = units2spec.get(f'lib/src/features/{item["module"]}/{f}') or \
                  next((sid for u, sid in units2spec.items() if u.endswith('/' + f)), None)
        if paths:
            src = texts[paths[0]]
            wc = widget_class(src)
        else:
            src, wc = None, None

        if not paths:
            judge, note = '缺文件', '代码里没有这个文件'
            missing_file.append(f)
        elif wc is None:
            judge = '非界面'
            note = '无 Widget 类（数据模型/平台抽象）'
            if f not in {os.path.basename(c) for c in comps}:
                note += '；★ 未在 component-units.md 登记'
                missing_spec.append(f)
        else:
            name, _ = wc
            others = [p for p, t in texts.items()
                      if p != paths[0] and re.search(r'\b' + re.escape(name) + r'\s*\(', t)]
            if others:
                judge, note = '直达', f'{len(others)} 处引用'
            else:
                syms = public_symbols(src, name)
                used = []
                for p, t in texts.items():
                    if p == paths[0]:
                        continue
                    for s in syms:
                        if len(s) < 5:
                            continue
                        if re.search(r'\b' + re.escape(s) + r'\s*[.(]', t):
                            used.append(s)
                            break
                if used:
                    judge, note = '经入口', '入口 ' + used[0]
                elif name.startswith('_'):
                    judge, note = '内部件', '私有 Widget，供同文件页面使用'
                else:
                    judge, note = '未接线', '没有任何地方构造它'
                    orphans.append(f'{f} ({name})')
        if spec_id is None and judge != '非界面':
            missing_spec.append(f)
        counts[judge] = counts.get(judge, 0) + 1
        rows.append({'unit': f, 'module': item['module'], 'spec': spec_id,
                     'verdict': item['verdict'], 'judge': judge, 'note': note})

    print(f'单元 {len(rows)} · ' + ' · '.join(f'{k} {v}' for k, v in counts.items()))
    if missing_spec:
        print(f'★ 没有 spec 的单元 {len(missing_spec)}：{missing_spec}')
    if missing_file:
        print(f'★ 没有代码文件的单元 {len(missing_file)}：{missing_file}')
    if orphans:
        print(f'★ 未接线（写了没人用）{len(orphans)}：{orphans}')

    if args.md:
        lines = ['# 设计 → 代码 逐单元对账（160 个界面单元）', '',
                 '> 由 `tool/design_code_conformance.py` 生成，别手改。', '',
                 '| 单元 | 模块 | spec | 设计稿 | 代码落点 | 分档 |', '|---|---|---|---|---|---|']
        for r in rows:
            lines.append(f'| `{r["unit"]}` | {r["module"]} | {r["spec"] or "—（非界面）"} | '
                         f'{"有" if r["spec"] else "—"} | `{r["unit"]}` | {r["judge"]}（{r["note"]}） |')
        io.open(args.md, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
        print('[ok] md →', args.md)
    if args.json:
        io.open(args.json, 'w', encoding='utf-8').write(
            json.dumps({'rows': rows, 'counts': counts}, ensure_ascii=False, indent=1))
        print('[ok] json →', args.json)
    return 0


if __name__ == '__main__':
    sys.exit(main())
