#!/usr/bin/env python3
"""方法级缺口：官方 `.lib` 方法表 × 仓库里的方法名引用。

与 `api_method_coverage.py` 的区别：那个只看"有没有提到某个 **API**"，
本脚本假设 API 已被引用，进一步看**该 API 的每个方法名**有没有在源码里出现。

用法：python3 tool/api_method_level_gaps.py [--spk /tmp/spk] [--repo .]
只读；结果打到 stdout。
"""
import argparse, glob, json, os, re, collections

# 这些方法名太通用，出现在别处不代表"实现了本方法"，故不参与判断。
GENERIC = {
    'get', 'set', 'list', 'create', 'delete', 'start', 'stop', 'status', 'edit',
    'update', 'add', 'remove', 'rename', 'copy', 'move', 'upload', 'download',
    'send', 'receive', 'cancel', 'init', 'check', 'sync', 'test', 'apply',
    'search', 'share', 'restore', 'copy', 'export', 'import', 'list_all',
    'getinfo', 'set_config', 'get_config', 'clear', 'refresh', 'pause', 'resume',
}


def official(spk):
    table = {}
    for pkg in sorted(glob.glob(os.path.join(spk, 'export_*'))):
        for p in glob.glob(os.path.join(pkg, '**', '*.lib'), recursive=True):
            try:
                j = json.load(open(p, encoding='utf-8'))
            except Exception:
                continue
            if not isinstance(j, dict):
                continue
            for api, v in j.items():
                if not isinstance(v, dict) or 'methods' not in v:
                    continue
                names = set()
                for ver, ms in v['methods'].items():
                    for m in ms:
                        if isinstance(m, dict):
                            names.update(m.keys())
                if names:
                    table.setdefault(api, set()).update(names)
    return table


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--spk', default='/tmp/spk')
    ap.add_argument('--repo', default='.')
    a = ap.parse_args()
    table = official(a.spk)
    src = []
    for p in glob.glob(os.path.join(a.repo, 'lib', '**', '*.dart'), recursive=True):
        src.append(open(p, encoding='utf-8', errors='replace').read())
    src = '\n'.join(src)
    used_apis = {api for api in table if "'%s'" % api in src}
    rows = []
    for api in sorted(used_apis):
        missing = []
        for m in sorted(table[api]):
            if m in GENERIC:
                continue
            if "'%s'" % m not in src:
                missing.append(m)
        if missing:
            rows.append((api, missing, sorted(table[api])))
    print('已被引用的官方 API：%d 个；其中**有非通用方法未出现**的：%d 个\n' % (len(used_apis), len(rows)))
    print('| API | 疑似未实现的方法（**非通用名**） | 该 API 的权威方法全集 |')
    print('|---|---|---|')
    for api, miss, allm in rows:
        print('| `%s` | %s | %s |' % (api, ', '.join('`%s`' % m for m in miss), ', '.join('`%s`' % m for m in allm)))
    total = sum(len(m) for _, m, _ in rows)
    print('\n合计疑似未实现方法 **%d** 个（跨 %d 个 API）。' % (total, len(rows)))
    print('\n> 判读：① `get/set/list/create/...` 这类**通用名被排除**（用别处出现无法判定）；')
    print('> ② 名单是**线索不是结论**——开批前仍要按本会话纪律**真机实调一次**（`allowUser` 会高估，见 `docs/api-method-coverage.md` 的 Drive 纠错节）。')


if __name__ == '__main__':
    main()
