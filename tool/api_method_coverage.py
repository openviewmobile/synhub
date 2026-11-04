#!/usr/bin/env python3
"""官方包 `.lib` 权威方法表 × 本仓库实现 → API 级覆盖缺口报告。

用法：python3 tool/api_method_coverage.py [--spk /tmp/spk] [--repo .] > docs/api-method-coverage.md
只读：不联网、不改任何文件（除 stdout）。
"""
import argparse, glob, json, os, re, sys

ADMIN_HINTS = ('.Admin', 'Setting.Admin', 'Development.Admin', 'Cluster.Locker',
               'Index', 'DBUsage', 'Migration', 'Udc', 'Shard', 'Metrics', 'Log',
               'Notification.subscribe', 'RegeneratePreview')
INTERNAL = ('Shard', 'Udc', 'Cluster.', 'Metrics', 'UserStatistics')


def official_methods(spk):
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
                mv = str(v.get('maxVersion', 1))
                ms = v['methods'].get(mv) or (list(v['methods'].values())[-1] if v['methods'] else [])
                names = set()
                for m in ms:
                    if isinstance(m, dict):
                        names.update(m.keys())
                if names:
                    table.setdefault(api, set()).update(names)
    return table


def repo_source(repo):
    out = []
    for p in glob.glob(os.path.join(repo, 'lib', '**', '*.dart'), recursive=True):
        out.append(open(p, encoding='utf-8', errors='replace').read())
    return '\n'.join(out)


def classify(api):
    if api.startswith('SYNO.FotoTeam'):
        return 'team'
    if any(h in api for h in ADMIN_HINTS):
        return 'admin?'
    if any(h in api for h in INTERNAL):
        return 'internal?'
    return 'normal'


MODULES = [
    ('相册', 'Foto'), ('Drive', 'SynologyDrive'), ('文件', 'FileStation'),
    ('笔记', 'NoteStation'), ('音频', 'AudioStation'), ('下载', 'DownloadStation'),
    ('日历', 'Cal'), ('联系人', 'Contacts'), ('Office', 'Office'),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--spk', default='/tmp/spk')
    ap.add_argument('--repo', default='.')
    a = ap.parse_args()
    table = official_methods(a.spk)
    src = repo_source(a.repo)
    print('# 官方 `.lib` 权威方法表 × 本仓库实现：**API 级覆盖缺口报告**\n')
    print('> 生成方式（**可复跑、只读**）：`python3 tool/api_method_coverage.py --spk /tmp/spk > docs/api-method-coverage.md`\n')
    print('> 事实源：各官方 SPK 解包后的 `**/*.lib`（**纯 JSON**，含 `methods` 表）。**方法名以此为准**——\n'
          '> 本会话多次出现的 `103`（方法不存在）多因**方法名猜错**，而非功能缺失。\n')
    print('> ⚠️ 判读注意：① 本报告按**字符串引用**判断"我方有没有提到该 API"，'
          '若代码用**动态拼接**的 api 名会**误报为缺失**；\n'
          '> ② `team` = 团队空间（NAS 未启用则不可用）；`admin?`/`internal?` 是**启发式**标记，**需人工复核**后才能判"不做"。\n')
    print('| 模块 | 官方 API 数 | 我方未提及 | 其中 normal | 其中 team | 其中 admin?/internal? |')
    print('|---|---|---|---|---|---|')
    detail = []
    for label, key in MODULES:
        miss = [api for api in sorted(table) if key in api and ("'%s'" % api) not in src]
        c = {k: 0 for k in ('normal', 'team', 'admin?', 'internal?')}
        for api in miss:
            c[classify(api)] += 1
        total = len([api for api in table if key in api])
        print('| %s | %d | **%d** | %d | %d | %d |' % (label, total, len(miss), c['normal'], c['team'], c['admin?'] + c['internal?']))
        detail.append((label, miss))
    print()
    for label, miss in detail:
        if not miss:
            continue
        print('## %s：我们**没有提到**的官方 API\n' % label)
        print('| API | 方法（权威表） | 归类 |')
        print('|---|---|---|')
        for api in miss:
            print('| `%s` | %s | %s |' % (api, ', '.join('`%s`' % m for m in sorted(table[api])), classify(api)))
        print()
    print('---\n\n## 结论口径\n')
    print('- 本表**只回答"有没有碰到这个 API"**，不回答"做得好不好"；行级功能状态请看 `docs/master-parity-table.md`。\n'
          '- `normal` 行是**下一步 backlog 的候选池**；每项开批前仍需**真机 120 缺参探测**钉参数名（本会话已多次证明必要性）。\n'
          '- `team` 行需先确认 NAS 是否启用团队空间；`admin?`/`internal?` 行**不得**直接进 backlog。\n')


if __name__ == '__main__':
    main()
