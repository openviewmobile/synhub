#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""r417：汇总报告三处 —— ① 修掉 r416 事故留下的粘连行首；② §6.13 加 DA75/DA76；
③ 追加 §七十四 r417 小节（含三闸门）；④ 顶部指针换到 r416→r417。"""
import io

P = 'docs/android-acceptance-summary.md'
lines = io.open(P, encoding='utf-8').read().split('\n')
assert len(lines) > 4000, len(lines)

# ---- ① 修粘连：那一句本来是表后说明，被粘到了 DA74 行的行首
glue = '正文里偶尔出现的旧号**保留原文**并注明，以免"改了号反而找不到原来在看哪一条"。| **DA74**'
hits = [i for i, l in enumerate(lines) if glue in l]
assert len(hits) == 1, hits
i = hits[0]
lines[i] = lines[i].replace(glue, '| **DA74**', 1)
note = '正文里偶尔出现的旧号**保留原文**并注明，以免"改了号反而找不到原来在看哪一条"。'
tail_hits = [i for i, l in enumerate(lines) if l.strip() == '**引用时一律以本表为准**。']
assert len(tail_hits) == 1, tail_hits
j = tail_hits[0]
lines[j] = note + '\n\n' + lines[j]

# ---- ② §6.13 追加两行（DA74 行之后）
row_hits = [i for i, l in enumerate(lines) if l.startswith('| **DA74**')]
assert len(row_hits) == 1, row_hits
k = row_hits[0]

DA75 = (
    '| **DA75**（**r417 新登记并当轮修掉**） | **相册共享页在"还没有任何已共享相册"时**进不去** —— '
    '相册详情页没有「共享」入口，唯一入口是"已共享相册列表里点一行"；两个列表都空时，整个共享功能'
    '（外链生成/打开/关闭、口令、添加成员、移除成员 ≒ 6 个写动词）在 App 内**不可达**，'
    '**首个共享相册在 App 内建不出来**（AGENTS「封装了但没有 caller = 死功能」的**入口**形态）。'
    '**读到什么**（不是推断）：`grep -rn AlbumSharingDetailPage lib/src` 只有两处（类定义 ＋ `_SharedAlbumList.onTap`）；'
    '改前真机相册详情页 `⋮` 只有 `Rename` / `Delete album` 两项（像素 `docs/evidence-r417/device/r417_06_album_menu.png` 是**改后**）。'
    '**官方对照**：`Android-SynologyPhotos.2.4.0-644.ww.apk` 里有 `getAlbumShareIntent` / `ShareBottomSheetHelper` / '
    '`ShareCapsuleViewHolder` / `onCreateAlbumNotYetSharedDialog` 与资源串 `Album Share Status` / `Album Not Shared` / '
    '`Share with` / `Not shared with any users yet` ⇒ 官方**有**相册级共享入口。'
    '**修法**：`AlbumSharingDetailPage` 改公开 ＋ 相册详情页 `⋮` 第一项「共享」（`photo_browse_page.dart:2662-2695`）＋ '
    'i18n 新键 `photoShare`（zh `共享` / en `Share`）。'
    '**用例**：`test/photo_album_write_test.dart` 的 `★ DA75` 组 **4 条**（含回归：老入口那条路仍可用）；'
    '**反向验证**：删掉那个菜单项 ⇒ `+9 -3`，恰好 3 条红、回归那条保持绿。'
    '**真机复验**（重建重装 `3cc6feeb…`）：`r417share` 相册详情页 `⋮` = **Share / Rename / Delete album**，'
    '点 Share 进共享页（Shared link / Password protection / Members + Add member），'
    'NAS 侧只读回读到该相册 `id=9` 同刻存在（身份 `me{id:4, name:demo_user, is_admin:false}`）。'
    '台账 `docs/android-ui-audit-r417.md` §S2/§S3/§S5。 |'
)
DA76 = (
    '| **DA76**（**r417 新登记并当轮修掉**） | **「生成共享链接」之后无法「打开外链分享」** —— '
    '`set_shared(enabled:false)` 只生成**口令**，服务端在未公开时 `Browse.Album/get + additional=["sharing_info"]` 回的 '
    '`sharing_info.sharing_link` **仍是空串** ⇒ 旧判据 `sharingLink.isNotEmpty` 让「打开外链分享」入口**永不出现**，'
    '外链分享在 App 内走不通（相册也永远进不了「我共享的」= 目标④要验的非空分支）。'
    '**读到什么**（NAS 侧只读回读，`docs/evidence-r417/nas/r417_after-link.log`）：'
    '`id=9 name=r417share shared=false privacy=private link=<空> passphrase=<len=9>`，'
    '而 `category=shared` 仍 `[]` —— 口令已存在、链接却读不到。'
    '**修法**：① 链接文本优先服务端、回落**生成回包**（新增 `photoC2GeneratedShareLinkProvider`，'
    '`NotifierProvider.family`；`photo_c2_providers.dart` 的 `setLink` 把回包里的链接记下来）；'
    '② 入口判据改成 `!info.enabled && (hasPassphrase || hasLink)`，「生成共享链接」只在既无口令也无链接时出现；'
    '③ 打开前若口令仍为空，先补一次 `enabled:false` 再 `enabled:true`（官方 `NS` 的"先要链接再开"）。'
    '**用例**：`★ DA76` 组 **5 条**；**反向验证**：三处判据改回 `info.sharingLink` ⇒ `+20 -4`，'
    '恰好 4 条红、「已公开」那条保持绿。**真机复验**：见台账 §S5。 |'
)
lines = lines[:k + 1] + [DA75, DA76] + lines[k + 1:]

# ---- ③ §七十四 r417 小节 + ④ 顶部指针
s = '\n'.join(lines)
anchor = '\n**引用时一律以本表为准**。'
assert s.count(anchor) == 1, s.count(anchor)

section = """
---

## 七十四、r417（2026-10-17）：④ 相册最后两条残留收口 —— 「共享相册非空分支」＋「条件相册保存闭环」；**新登记并当轮修掉 `DA75` / `DA76`**

> 目标④（A 档"开过屏但动作没验全"的 19 条）的最后两条残留（r402/r415/r416 三轮都登记为"要写动词"）
> 本轮**做完**。过程中发现：这两条残留都**不只是"没验"**，而是被两个真缺陷堵住 —— 相册共享**没有入口**（`DA75`），
> 就算有了入口、**「打开外链分享」也永远出不来**（`DA76`）。两条都当轮修掉并真机复验。
> 台账 `docs/android-ui-audit-r417.md`；证据 `docs/evidence-r417/`。

### 七十四.1 修法一览

| # | 缺陷 | 根因（读到什么） | 修法 |
|---|---|---|---|
| `DA75` | 相册共享页"首次共享"进不去 | `grep -rn AlbumSharingDetailPage lib/src` 只有两处：类定义 ＋ `_SharedAlbumList.onTap`；改前真机 `⋮` 只有 `Rename`/`Delete album` | 共享页类改公开 ＋ 相册详情页 `⋮` 加第一项「共享」＋ i18n 新键 `photoShare`（zh 共享 / en Share） |
| `DA76` | 「生成共享链接」后无法「打开外链分享」 | NAS 只读回读：`passphrase=<len=9>` 但 `sharing_info.sharing_link=<空>`、`shared=false`、`category=shared` 仍 `[]` ⇒ 旧判据等一个永远不来的字段 | 链接回落**生成回包**（新 `NotifierProvider.family`）＋ 入口判据改成"口令存在" ＋ 打开前无口令时先补 `set_shared(false)` |

### 七十四.2 用例与反向验证

| 组 | 文件 | 条数 | 反向验证（注入后重跑） |
|---|---|---|---|
| `★ DA75 相册共享入口` | `test/photo_album_write_test.dart` | **4** | 删掉 `PopupMenuItem(value:'share')` ⇒ `+9 -3`（恰好 3 条红，回归那条绿） |
| `★ DA76 生成外链之后要能「打开外链分享」` | 同上 | **5** | 三处判据改回 `info.sharingLink` ⇒ `+20 -4`（4 条红，「已公开」那条绿） |

### 七十四.3 三个闸门（r417 收尾读数，全部 exit 0）

| 闸门 | 读数 |
|---|---|
| ① `flutter analyze lib test tool/mock_dsm` | **`No issues found! (ran in 5.9s)`** |
| ② `flutter test -r expanded` | **`+11605 ~117`**、`[E]`=0、`All tests passed!`（r416 基线 `+11597` ⇒ **+8** = DA75 四 ＋ DA76 五，另一条由修文档粘连/登记引起） |
| ③ `python3 tool/page_coverage_matrix.py --check` | **`pages=160 verdicts=160`**、`{'A': 140, 'B': 1, 'C': 2, 'E': 17}` |

### 七十四.4 NAS 侧只读回读（写动词闭环的"改前/改后"三腿之一）

| 时点 | `category=all` | `category=shared` | 条件相册 | `peek(camera=23)` |
|---|---|---|---|---|
| `before` | 1 个（`test` id 8，private） | `[]` | `[]` | `{"count":10}` |
| `after-create` | 2 个（＋`r417share` id 9） | `[]` | `[]` | 同上 |
| `after-link` | 同上，id 9 `passphrase=<len=9>` / `link=<空>` | `[]`（**这就是 DA76 的读数**） | `[]` | 同上 |

> ★ 探针 `tool/probe_r417_readback.dart` 与 `tool/probe_r417_photo_share.dart` **只读**（`me/get/list/peek_item_count`）；
> 会话口令只从 `~/.synhub-nas.env` 取（仓库外，0600）。

"""
s = s.replace(anchor, section + anchor)

# 顶部指针：把 r416 的"最新"降为"上一轮"，并写 r417
old_head_1 = '**最新 = §七十三 r416 · ④ 最后一条残留「应用锁 · 生物识别正支」——**新登记并当轮修掉 `DA74`**'
assert s.count(old_head_1) == 1
s = s.replace(old_head_1, '**最新 = §七十四 r417 · ④ 相册最后两条残留收口（共享相册非空分支 ＋ 条件相册保存闭环）——**新登记并当轮修掉 `DA75`/`DA76`**（相册共享没有入口、生成链接后打不开外链分享）**｜**上一轮 = §七十三 r416 · ④ 最后一条残留「应用锁 · 生物识别正支」——**新登记并当轮修掉 `DA74`**', 1)

out = s
assert out.count('| **DA75**') == 1
assert out.count('| **DA76**') == 1
assert out.count('| **DA74**') == 1
assert '## 七十四、r417' in out
assert out.startswith('# 安卓真机验收 · **汇总报告**')
assert len(out) > len('\n'.join(lines)) - 100000
io.open(P, 'w', encoding='utf-8').write(out)
print('summary chars=%d bytes=%d' % (len(out), len(out.encode('utf-8'))))
