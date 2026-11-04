#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""r417：把 DA75 / DA76 追加进缺陷闭合总账（先断言、后写整个字符串）。"""
import io

P = 'docs/defect-closure-registry.md'
s = io.open(P, encoding='utf-8').read()
assert len(s) > 40000, len(s)

DA75 = (
    "| DA75 | 已修+真机复验 | "
    "**入口可达性**：共享页 `AlbumSharingDetailPage` 原来**私有**，唯一入口是"
    "「已共享相册列表里点一行」（`_SharedAlbumList.onTap`）⇒ 两个列表都空时整个共享功能进不去、"
    "**首个共享相册在 App 内建不出来**。修法 = 该类改公开"
    "（`lib/src/features/photos/photo_c2_sections.dart:303-312`，带 ★ r417 注释）＋ 相册详情页 `⋮` 加第一项「共享」"
    "（`lib/src/features/photos/photo_browse_page.dart:2662-2695`，仍只在 `editable` 的普通相册出现）＋ i18n 新键 "
    "`photoShare`（zh `共享`/en `Share`；ARB + `flutter gen-l10n`，ARB 重写后逐键比对**只多这一个键、零值改动**："
    "`app_en` 7259→7260 / `app_zh` 7445→7446）。定性证据：官方 `Android-SynologyPhotos.2.4.0-644.ww.apk` 有 "
    "`getAlbumShareIntent`/`ShareBottomSheetHelper`/`ShareCapsuleViewHolder`/`onCreateAlbumNotYetSharedDialog` 与 "
    "`Album Share Status`/`Album Not Shared`/`Share with`/`Not shared with any users yet` 资源串 ⇒ 官方**有**相册级共享入口。"
    "台账 `docs/android-ui-audit-r417.md` §S2/§S3 | "
    "**正文引用了编号**：`test/photo_album_write_test.dart` 的 `★ DA75 相册共享入口（r417）` 组 **4 条**"
    "（`⋮` 里有「共享」/ 点进共享页且发 `Browse.Album/get {id, additional:[\"sharing_info\"]}` / "
    "「生成共享链接」发 `Sharing.Passphrase/set_shared v1 {policy:album, album_id, enabled:false}` / "
    "回归：直接进共享页这条老入口仍可用）。**反向验证（注入）**：删掉 `PopupMenuItem(value:'share')` ⇒ "
    "`+9 -3`，恰好第 1/2/3 条红、回归那条**保持绿**；恢复后 `+19 All tests passed!` | "
    "`docs/evidence-r417/device/r417_06_album_menu.png` + `.xml`（真机 `⋮` 菜单 = **Share / Rename / Delete album**，"
    "修前只有后两项）· `docs/evidence-r417/device/r417_07_share_page.png` + `.xml`（点 Share 进共享页："
    "Shared link / Password protection / Members + Add member）· `docs/evidence-r417/nas/r417_after-create.log`"
    "（`r417share` = id 9 真的建在 NAS 上；同刻身份 `me{id:4, name:demo_user, is_admin:false}`） | "
    "★ r417 新登记并当轮修掉。**回读口径**：修前 `grep -rn AlbumSharingDetailPage lib/src` 只有两处 —— "
    "类定义 ＋ `_SharedAlbumList` 的 `onTap` |\n"
)

DA76 = (
    "| DA76 | 已修 | "
    "**判据钉在「口令」而不是「服务端回的链接」**：`set_shared(enabled:false)` 只生成**口令**，服务端在未公开时 "
    "`Browse.Album/get` + `additional=[\"sharing_info\"]` 回的 `sharing_info.sharing_link` **仍是空串**"
    "（真机读数：`privacy_type=private`、`passphrase=<len=9>`、`link=<空>`）⇒ 旧判据 `sharingLink.isNotEmpty` 让"
    "「打开外链分享」入口**永不出现**，外链分享在 App 内走不通（相册也永远进不了「我共享的」＝ 目标④要验的非空分支）。"
    "修法三处：① 链接文本优先服务端、回落**生成回包**（新增 `photoC2GeneratedShareLinkProvider`，"
    "`NotifierProvider.family` —— Riverpod 3.x 已无 `StateProvider`）"
    "`lib/src/features/photos/photo_c2_providers.dart:397-421` ＋ `setLink` 回包非空就记住；"
    "② 入口判据 `canEnable = !info.enabled && (hasPassphrase 或 hasLink)`，"
    "「生成共享链接」改成只在既无口令也无链接时出现 `lib/src/features/photos/photo_c2_sections.dart:337-372`；"
    "③ 打开前若口令仍为空，先补一次 `enabled:false` 再 `enabled:true`（官方 `NS` 的「先要链接再开」）——同文件 `_confirmEnableLink` | "
    "**正文引用了编号**：`test/photo_album_write_test.dart` 的 `★ DA76 生成外链之后要能「打开外链分享」（r417）` 组 **5 条**"
    "（只有口令时入口必须在 / 生成后用**回包**里的链接显示 / 打开时先 `false` 再 `true` 且不重复 / "
    "防御分支：服务端还没回口令时先补一次 `false` / 回归：已公开则不显示「打开」而显示「关闭外链分享」）。"
    "**反向验证（注入）**：把三处判据改回 `info.sharingLink` ⇒ `+20 -4`，恰好这 4 条红、"
    "「已公开」那条**保持绿**；恢复后 `+24 All tests passed!` | "
    "`docs/evidence-r417/nas/r417_after-link.log`（**决定性读数**：album 9 `passphrase=<len=9>` 但 `link=<空>`、"
    "`shared=false`、`privacy=private`、`category=shared` 仍 `[]`）· `docs/evidence-r417/nas/r417_before.log`"
    "（同口径改前基线）· 真机像素 `docs/evidence-r417/device/r417_07_share_page.png`（该页当时只有 "
    "Create share link / Password protection / Members） | "
    "★ r417 新登记并当轮修掉（真机复验见台账 §S5）。**诚实边界**：「我共享的」非空分支本轮走**外链公开**这条路验"
    "（不惊动其它账号）；**邀请成员**那条（`Sharing.Passphrase/update`）仍未真机验 ⇒ 台账 §S8 |\n"
)

# 总账在**文件末尾**（计数块在它前面）⇒ DA75/DA76 追加到最后一行 DA 行之后
lines = s.split('\n')
last_da = max(i for i, line in enumerate(lines) if line.startswith('| DA'))
assert lines[last_da].startswith('| DA74 |'), lines[last_da][:40]
out = '\n'.join(lines[:last_da + 1]) + '\n' + DA75 + DA76 + '\n'.join(lines[last_da + 1:])

reps = [
    ('# 缺陷闭合总账（`DA1`–`DA74`）· r416 上线收口',
     '# 缺陷闭合总账（`DA1`–`DA76`）· r417 上线收口'),
    ('> **这份表是 objective ② 的答案纸**：74 个原始登记缺陷（`DA1`–`DA74`）',
     '> **这份表是 objective ② 的答案纸**：76 个原始登记缺陷（`DA1`–`DA76`）'),
    ('## 计数（r416 收尾）', '## 计数（r417 收尾）'),
    ('| `已修+真机复验` | **68** | 见下表（r416 加 `DA74`） |',
     '| `已修+真机复验` | **69** | 见下表（r417 加 `DA75`；`DA76` 待真机复验后转档） |'),
    ('| **合计** | **79** | `DA1`–`DA74` 连续无缺号',
     '| **合计** | **80** | `DA1`–`DA76` 连续无缺号'),
]
for a, b in reps:
    assert out.count(a) == 1, a
    out = out.replace(a, b)

# 断言要写出去的那个对象
assert out.count('| DA75 |') == 1
assert out.count('| DA76 |') == 1
assert out.count('| DA74 |') == 1
assert out.count('| DA1 |') == 1
assert out.startswith('# 缺陷闭合总账')
assert len(out) > len(s) + 2000, (len(out), len(s))
io.open(P, 'w', encoding='utf-8').write(out)
rows = sum(1 for line in out.split('\n') if line.startswith('| DA'))
print('registry written chars=%d DA_rows=%d' % (len(out), rows))
