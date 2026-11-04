#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""r417 记账：AGENTS.md 加 r417 两条 + 轮转三处旧行到归档；结果必须 < 62000 B。"""
import io

A = 'AGENTS.md'
H = 'docs/agents-baseline-history.md'

agents = io.open(A, encoding='utf-8').read()
hist = io.open(H, encoding='utf-8').read()
before = len(agents.encode('utf-8'))
assert 60000 < before < 64000, before
assert len(hist.encode('utf-8')) > 300000

lines = agents.split('\n')
# 定位（按内容，别按行号）
def idx(pred, what):
    hits = [i for i, l in enumerate(lines) if pred(l)]
    assert len(hits) == 1, (what, len(hits))
    return hits[0]

i416 = idx(lambda l: l.startswith('* ★★★ **第 416 轮**（台账 `docs/android-ui-audit-r416.md`'), 'r416 §2.2')
r415 = idx(lambda l: l.startswith('| `docs/android-ui-audit-r415.md`'), 'r415 §4')
r413 = idx(lambda l: l.startswith('| `docs/android-ui-audit-r413.md`'), 'r413 §4')
r412 = idx(lambda l: l.startswith('| `docs/android-ui-audit-r412.md`'), 'r412 §4')
r416 = idx(lambda l: l.startswith('| `docs/android-ui-audit-r416.md`'), 'r416 §4')

moved = {'r416-§2.2': lines[i416], 'r415-§4': lines[r415], 'r413-§4': lines[r413], 'r412-§4': lines[r412]}
kept_bytes = sum(len(v.encode('utf-8')) for v in moved.values())

hist_add = (
    '\n\n### 轮转-2.2-r417（第 416 轮的 §2.2 条目压缩 ＋ §4 三行台账索引）\n\n'
    '> 轮转原因：加完 r417 的两条记账后 AGENTS.md 会超软目标 62,000 B ⇒ 把下面四处原文**逐字**搬来，\n'
    '> AGENTS.md 只留一行指针。（r417 = ⑦相册最后两条残留＋`DA75`–`DA78`；台账 `docs/android-ui-audit-r417.md`）\n\n'
    '* 【r416 §2.2 原文】' + moved['r416-§2.2'] + '\n\n'
    '* 【r415 §4 表行原文】' + moved['r415-§4'] + '\n\n'
    '* 【r413 §4 表行原文】' + moved['r413-§4'] + '\n\n'
    '* 【r412 §4 表行原文】' + moved['r412-§4'] + '\n'
)

ptr416 = ('* ★★★ **第 416 轮**（→ 归档 §轮转-2.2-r417）：④「应用锁 · **生物识别正支**」真机闭环 ＋ '
          '**`DA74` 新登记并当轮修掉**（`BiometricPrompt` 自己的 pause/resume ⇒ 指纹过了**立刻重锁**的死循环；'
          '修后冷启动只弹 1 次）＋ **仪器88**（"改第一行" ≠ "改整个文档"）。')
ptr415 = ('| `docs/android-ui-audit-r415.md`（**行已轮转**） | **上线收口（二）**：④「音频 · 投屏」由**推断**升级为**读数**'
          '（`RemotePlayer::list` 三版成功回空 ＋ 同网段 SSDP 零渲染器）＋ 总账补齐五个带字母子号（73→**78 行**）＋ '
          '守卫加**判据⑧**；★ `lib/` 零改动 ⇒ 不重建重装 ⇒ 原文 → 归档 §轮转-2.2-r417 |')
ptr413 = ('| `docs/android-ui-audit-r413.md`（**行已轮转**） | ④「音频 · 睡眠定时」动作级收口 —— **DA31 真机到点闭环**'
          '（`state 3→2`）＋ **DA72 / DA73 新登记并当轮修掉** ＋ 矩阵 §4.4 **六行陈旧订正**；用例 +14、'
          '证据 `docs/evidence-r413/` ⇒ 原文 → 归档 §轮转-2.2-r417 |')
ptr412 = ('| `docs/android-ui-audit-r412.md`（**行已轮转**） | ④「相册 · 标签 / 人物」动作级收口 —— 两个页类逐条定性'
          '（`PhotoTagDetailPage` **首次真机打开**、`PhotoPersonAlbumPage` = 当前配置不可达）＋ **DA70 / DA71 已修 + 真机复验**'
          '；用例 +20、**八条反向验证全红**、零 NAS 写动词 ⇒ 原文 → 归档 §轮转-2.2-r417 |')

new_222 = ('* ★★★ **第 417 轮**（台账 `docs/android-ui-audit-r417.md`；证据 `docs/evidence-r417/`）：**⑦相册最后两条残留收口** —— '
           '① 共享相册**非空分支**（真机建临时相册 → `⋮ → 共享` → 打开外链分享 → 「我共享的」非空 → 关闭 → 删；NAS `category=shared` **0→1→0**）· '
           '② 条件相册**保存闭环**（新建 ＋ Camera=`LGE-AN10` → 预览 **10** → 保存 → 删）。★ 路上修掉 **`DA75`–`DA78`**'
           '（共享没有入口 · 生成链接后打不开 · **关闭外链分享发错方法 ⇒ 界面谎报、服务端没关** · 条件相册行把 `user_id` 显示成「其它条件」）；'
           '重建重装 **5 次**（最终包 `798e0ed2…`）；三闸门 exit 0；收尾回读**与改前基线逐字相同**。')

new_row = ('| `docs/android-ui-audit-r417.md` | ★★ **r417 台账（最新）**：⑦相册最后两条残留（共享相册**非空分支** · 条件相册**保存闭环**）'
           '真机动作级收口 ＋ **`DA75`–`DA78` 四条新登记并当轮修掉**（含"关闭外链分享**根本没关**却弹已关闭"：'
           '`update privacy_type=private` 服务端**收下但一个字段都不改**，真动词是 `set_shared(enabled:false)`）＋ '
           'r402 的**假判据用例**被改写；重建重装 5 次、收尾**零残留**（回读 = 改前基线）；证据 `docs/evidence-r417/` |')

# 逐行替换（对 out 断言，不碰 s）
lines[i416] = ptr416
lines[r415] = ptr415
lines[r413] = ptr413
lines[r412] = ptr412
lines[r416] = lines[r416].replace('（最新）', '')   # 最新让给 r417 行
lines.insert(r416, new_row)          # r417 行插在 r416 行上面
out = '\n'.join(lines)

# 新 §2.2 行插在"第 414 轮"那条前面（保持倒序：最新在上）
marker = '### 轮转-2.2-r416'  # 不用；改按 §2.2 里第 414 轮那条定位
hits = [i for i, l in enumerate(out.split('\n')) if l.startswith('* ★★★ **第 414 轮**（→ 归档 §轮转-2.2-r415）')]
assert len(hits) == 1, hits
ol = out.split('\n')
ol.insert(hits[0], new_222)
out = '\n'.join(ol)

assert out.count('| `docs/android-ui-audit-r417.md`') == 1
assert out.count('* ★★★ **第 417 轮**') == 1
assert 'DA75' in out and 'DA78' in out
assert '§轮转-2.2-r417' in out
after = len(out.encode('utf-8'))
print('AGENTS bytes: %d → %d (Δ%+d)' % (before, after, after - before))
# ---- 再轮转四行 §4 索引，直到 < 62000 B ----
rot = [
    ('| `docs/android-ui-audit-r402` / `r404` / `r405` / `r406`（**四行已轮转**）',
     '| `docs/android-ui-audit-r402` / `r404` / `r405` / `r406`（**原文已归档**） | 相册「C2 子页」+ **DA48/49/50** · 登录/证书 + **DA56** · 播放队列非空 + **DA57** · BT 搜索多源 + **DA58** ⇒ 归档 §轮转-2.2-r408-§4表行 |'),
    ('| `docs/android-ui-audit-r398` / `r399` / `r400`（**三行已轮转**）',
     '| `docs/android-ui-audit-r398` / `r399` / `r400`（**原文已归档**） | 音频「收藏（Pins）」+ **DA45** · 自定义电台 + **DA46** · 网络电台行菜单 + **DA47** ⇒ 归档 §轮转-2.2-r407-§4表行 |'),
    ('| `docs/android-ui-audit-r410.md`（**行已轮转**）',
     '| `docs/android-ui-audit-r410.md`（**原文已归档**） | ⑥ 下载家族（五）自动解压 6 个可写字段 + **DA64/DA65 已修** ⇒ 归档 §轮转-2.2-r410-§4表行 |'),
    ('| `docs/android-ui-audit-r408.md`（**行已轮转**）',
     '| `docs/android-ui-audit-r408.md`（**原文已归档**） | ⑥ 下载家族（三）eMule + 内置链接浏览器 + **DA60/DA60b/DA61/DA63 已修** ⇒ 归档 §轮转-2.2-r410-§4表行 |'),
    ('| `docs/android-ui-audit-r403.md`（**行已轮转**）',
     '| `docs/android-ui-audit-r403.md`（**原文已归档**） | ④ 音频歌词成功态 + **DA51–DA55** + 仪器79–81 ⇒ 归档 §轮转-2.2-r410-§4表行 |'),
    ('| `docs/android-ui-audit-r361.md`',
     '| `docs/android-ui-audit-r361.md`（**原文已归档**） | `download_file_select_page` B→A（A 141）＋ 首次真服务端写动词闭环 + **DA18** + 仪器㊴ ⇒ 归档 §轮转-2.2-r357r366 |'),
    ('| `docs/android-ui-audit-r373` / `r374` / `r375` / `r378`（**四行已轮转**）',
     '| `docs/android-ui-audit-r373` / `r374` / `r375` / `r378`（**原文已归档**） | 管理员入口隐藏复核 · DA14 文本编辑器保存 · DA10c 回收站还原 · release 档隐藏临时页 ⇒ 归档 §轮转-2.2-r405-§4表行 |'),
    ('| `docs/android-acceptance-closure.md`',
     '| `docs/android-acceptance-closure.md` | ★★ **r367 · M4 结项报告**：三口径计数（甲 141/160 · 乙 135/160 且上限 137 ⇒ G3 不可达 · 丙 139/160）· A 档演进（70→141）· **19 条非 A 逐条"为什么"** · 可上线评估与发布边界 ⇒ 摘要已进 `android-acceptance-summary.md` |'),
]
rotated_extra = []
for pref, ptr in rot:
    ol = out.split('\n')
    hits = [i for i, l in enumerate(ol) if l.startswith(pref)]
    if not hits:
        continue
    assert len(hits) == 1, (pref, len(hits))
    rotated_extra.append('* 【§4 表行原文】' + ol[hits[0]])
    ol[hits[0]] = ptr
    out = '\n'.join(ol)
    after = len(out.encode('utf-8'))
    print('  rotated %-58s → %d B' % (pref[:58], after))
    if after < 62000:
        break

after = len(out.encode('utf-8'))
assert 45000 < after < 62000, after
hist_add = hist_add + ('\n\n#### 续：2026 r417 再轮转的行（同一原因）\n\n' + '\n\n'.join(rotated_extra) + '\n') if rotated_extra else hist_add

io.open(A, 'w', encoding='utf-8').write(out)
io.open(H, 'a', encoding='utf-8').write(hist_add)
print('moved out %d B of原文; archive +%d B' % (kept_bytes, len(hist_add.encode('utf-8'))))
print('final AGENTS bytes = %d' % len(io.open(A, encoding='utf-8').read().encode('utf-8')))
