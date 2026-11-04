#!/usr/bin/env python3
"""r597：人工读过后，把 A 档里**引用行确实不是这一屏**的几条改到正确行。

与 `fix_evidence_citations.py` 的区别：那个是机械找名字，这个是**人读过原文**后
逐条指定的（每条都在 `tool/design_traceability_manual.json` 里写了理由）。
改完由 `tool/design_traceability.py` 重新生成台账。
"""
import glob
import io
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCH = {
    'lib/src/features/office/office_doc_page.dart':
        ['docs/android-ui-audit-r348.md:103'],
    'lib/src/features/office/office_sheet_page.dart':
        ['docs/android-ui-audit-r348.md:104'],
    'lib/src/features/office/office_slides_page.dart':
        ['docs/android-ui-audit-r348.md:105'],
    'lib/src/features/chat/channel_members_page.dart':
        ['docs/android-ui-audit-r348.md:45'],
    'lib/src/features/chat/channel_scheduled_page.dart':
        ['docs/android-ui-audit-r348.md:792', 'docs/android-ui-audit-r348.md:793'],
    'lib/src/features/chat/channel_content_page.dart':
        ['docs/android-ui-audit-r348.md:787', 'docs/android-ui-audit-r348.md:788'],
    'lib/src/features/settings/oem_keepalive_page.dart':
        ['docs/android-ui-audit-r348.md:1867'],
}


def main() -> int:
    n = 0
    for path in [os.path.join(ROOT, 'tool/page_coverage_overrides.json')] + \
            sorted(glob.glob(os.path.join(ROOT, 'tool/page_coverage_frozen/verdicts/*.json'))):
        data = json.load(io.open(path, encoding='utf-8'))
        rows = data.values() if isinstance(data, dict) else data
        for row in rows:
            if not isinstance(row, dict):
                continue
            key = row.get('page') or ''
            if key in PATCH and row.get('verdict') == 'A':
                if row.get('evidence') != PATCH[key]:
                    row['evidence'] = PATCH[key]
                    n += 1
                    print('改', os.path.basename(path), os.path.basename(key), '→', PATCH[key])
        io.open(path, 'w', encoding='utf-8').write(
            json.dumps(data, ensure_ascii=False, indent=1) + '\n')
    print('共改', n, '行')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
