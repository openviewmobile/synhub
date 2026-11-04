#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""r417：总账追加 DA77 / DA78，并把 DA76 从「已修」转档为「已修+真机复验」。"""
import io

P = 'docs/defect-closure-registry.md'
s = io.open(P, encoding='utf-8').read()
assert len(s) > 40000, len(s)

# ---- DA76 转档
old = '| DA76 | 已修 | **判据钉在「口令」'
new = '| DA76 | 已修+真机复验 | **判据钉在「口令」'
assert s.count(old) == 1
s = s.replace(old, new)

old_b = '★ r417 新登记并当轮修掉（真机复验见台账 §S5）。**诚实边界**'
new_b = (
    '★ r417 新登记并当轮修掉。**真机复验**（最终包 `798e0ed2…`）：口令在、服务端 `link` 空时页面**给出**'
    '「打开外链分享」（`device/r417_22_final_share_closed.xml`）→ 打开后链接显示出来、`category=shared` 从 0 变 1'
    '（`device/r417_23_final_link_on.xml` ＋ `nas/r417_final_on.log`）→ 关掉又回 0（`nas/r417_final_off.log`）。'
    '**诚实边界**'
)
assert s.count(old_b) == 1
s = s.replace(old_b, new_b)

# ---- 计数
old_c = '| `已修+真机复验` | **69** | 见下表（r417 加 `DA75`；`DA76` 待真机复验后转档） |'
new_c = '| `已修+真机复验` | **72** | 见下表（r417 加 `DA75` / `DA76` / `DA77`） |'
assert s.count(old_c) == 1
s = s.replace(old_c, new_c)

old_d = '| **合计** | **80** | `DA1`–`DA76` 连续无缺号'
new_d = '| **合计** | **81** | `DA1`–`DA78` 连续无缺号'
assert s.count(old_d) == 1
s = s.replace(old_d, new_d)

s = s.replace(
    '# 缺陷闭合总账（`DA1`–`DA76`）· r417 上线收口',
    '# 缺陷闭合总账（`DA1`–`DA78`）· r417 上线收口',
)
s = s.replace(
    '> **这份表是 objective ② 的答案纸**：76 个原始登记缺陷（`DA1`–`DA76`）',
    '> **这份表是 objective ② 的答案纸**：78 个原始登记缺陷（`DA1`–`DA78`）',
)

DA77 = (
    '| DA77 | 已修+真机复验 | '
    '**「关闭外链分享」发错了方法 ⇒ 界面谎报、服务端没关**。真机 ＋ NAS 侧**原始读数**'
    '（`tool/probe_r417_disable_shapes.dart`，`docs/evidence-r417/nas/r417_disable_shapes.log`）：App 原来发 '
    '`Sharing.Passphrase/update {privacy_type:\'private\'}`（更早还发 '
    '`permission: json([{action:delete,member:{type:public}}])`）—— 逐个形状打同一台 NAS：'
    '① `permission:delete public` → `OK {}`、**状态一个字段都没变**（`shared=true`、`category=shared` 仍有它）；'
    '② `privacy_type:\'private\'` → 同上（`sharing_info.privacy_type` 本来就是 `private`）；③ ①+② → 同上；'
    '④ **`Sharing.Passphrase/set_shared {policy:album, album_id, enabled:false}` → `shared=false`、'
    '`sharing_link` 清空、`category=shared` 归 0** ✅。⇒ 关闭外链 = `set_shared(enabled:false)`。'
    '真机上更狠：界面弹 `Link sharing turned off`（说明**没抛错** = 服务端回了 success）而链接仍在、页签仍是 `shared`'
    '（仪器73 那一族：键名/形状错 = 成功 + 静默）。修法：`_confirmDisableLink` 改发 '
    '`setLink(enabled:false, deactivating:true)`（`lib/src/features/photos/photo_c2_sections.dart`），'
    '并给 `setLink` 加 `deactivating` 参数：真机回包会把**正在作废**的那条链接原样回给我们 ⇒ 此时**不记**回包、'
    '**清**旧缓存（`lib/src/features/photos/photo_c2_providers.dart`），否则界面继续挂着一条打不开的外链。'
    '★ 同轮把 r402 写的老用例（把发 `update privacy_type=private` 当**正确行为**）改写为钉 `set_shared` '
    '—— 老用例正是「假判据」 | '
    '**正文引用了编号**：`test/photo_album_write_test.dart` 的 '
    '`★ DA77 关闭外链分享必须真的关掉（r417）` 组 **3 条**（发的必须是 `set_shared(enabled:false)` 且 `update` 数为 0 / '
    '关掉后出现「打开外链分享」且旧链接不再显示、复制按钮变灰 / 取消则一个请求都不发）＋ '
    '`test/photo_c2_pages_test.dart` 的 `★ DA77 关闭外链` 两条（改写后的老用例）。'
    '**反向验证（注入）**：① 把 `setLink` 换回 `updateSharing(privacyType:\'private\')` ⇒ `+25 -2`（两条红）；'
    '② 摘掉 `deactivating:true`（＝关闭时仍记回包里的链接）⇒ `+26 -1`，恰好「旧链接不再显示」那条红 | '
    '`docs/evidence-r417/nas/r417_disable_shapes.log`（**决定性读数**：四个形状逐个打 ＋ 前后状态）· '
    '`docs/evidence-r417/device/r417_20_disabled_after_fix.xml` ＋ `.png`（修后：入口翻回 `Turn on link sharing`）· '
    '`docs/evidence-r417/nas/r417_final_off.log`（最终包：`shared=false` / `link=<空>` / 我共享的 0） | '
    '★ r417 新登记并当轮修掉。**这是「表面成功」的典型**：snackbar 说成功了、`update` 也回 `success`，'
    '真值只有服务端回读能给 |\n'
)

DA78 = (
    '| DA78 | 已修+真机复验 | '
    '**条件相册行的摘要把服务端记账键当条件显示**：真机刚建好的「相机」条件相册读作 `Condition: Camera · Other`。'
    '**读到什么**（`docs/evidence-r417/nas/r417_after_cond_save.log`）：服务端 `condition` = '
    '`{"camera":[23],"user_id":4}`、`condition_object` = `{"camera":[{"id":23,"name":"LGE-AN10"}],"user_id":4}` '
    '⇒ 那个 Other 就是**每条都有的记账键 `user_id`**（同一个函数还把 `<type>_policy` 一并翻成「其它条件」）。'
    '修法：`_conditionSummary` 增加 `_isConditionKey()` —— 跳过 `user_id` 与所有 `*_policy` 键'
    '（`lib/src/features/photos/photo_c2_sections.dart`） | '
    '**正文引用了编号**：`test/photo_c2_pages_test.dart` 的 '
    '`★ DA78 记账键 user_id / *_policy 不许当成条件显示` **1 条**'
    '（`{camera, user_id, camera_policy}` ⇒ 只读作 `条件：相机`，`其它条件` 一个都不许有）。'
    '**反向验证（注入）**：摘掉 `_isConditionKey` 过滤 ⇒ `+37 -1`，恰好这条红 | '
    '`docs/evidence-r417/device/r417_38_condition_saved.xml`（**改前**：`Condition: Camera · Other`）→ '
    '`docs/evidence-r417/device/r417_40_condition_summary_fixed.xml` ＋ `.png`（**改后**：`Condition: Camera`）· '
    '`docs/evidence-r417/nas/r417_after_cond_save.log`（服务端原始 `condition`） | '
    '★ r417 新登记并当轮修掉（走查当场撞到；与 DA7「文案撒谎」同族：界面替服务端编了一个不存在的条件） |\n'
)

lines = s.split('\n')
last_da = max(i for i, line in enumerate(lines) if line.startswith('| DA'))
assert lines[last_da].startswith('| DA76 |'), lines[last_da][:40]
out = '\n'.join(lines[: last_da + 1]) + '\n' + DA77 + DA78 + '\n'.join(lines[last_da + 1:])

for a in ('| DA77 |', '| DA78 |', '| DA76 |', '| DA75 |', '| DA1 |'):
    assert a in out, a
assert out.startswith('# 缺陷闭合总账')
assert len(out) > len(s) + 2000, (len(out), len(s))
io.open(P, 'w', encoding='utf-8').write(out)
rows = sum(1 for line in out.split('\n') if line.startswith('| DA'))
print('registry chars=%d DA_rows=%d' % (len(out), rows))
