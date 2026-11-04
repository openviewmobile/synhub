#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""r417 收尾：汇总报告 §6.13 加 `DA77`/`DA78`，§七十四 补 ④ 收口读数与闸门。"""
import io

P = 'docs/android-acceptance-summary.md'
s = io.open(P, encoding='utf-8').read()
assert len(s) > 290000, len(s)  # 实测 299990 字符（仪器§1.6.2：阈值先量再设）

DA77 = (
    '| **DA77**（**r417 新登记并当轮修掉**） | '
    '**「关闭外链分享」发送了改不动任何东西的调用 ⇒ 界面谎报已关闭、服务端仍是公开的**。'
    '**读到什么**（真机 ＋ `tool/probe_r417_disable_shapes.dart` 逐个形状打同一台 NAS，'
    '`docs/evidence-r417/nas/r417_disable_shapes.log`）：App 原来发 '
    '`Sharing.Passphrase/update {privacy_type:\'private\'}`（更早还发 `permission: json([{action:delete,member:{type:public}}])`）——'
    '① `permission:delete public` → `OK {}`、`shared` 仍 `true`、`category=shared` 仍有它；'
    '② `privacy_type:\'private\'` → 一样（服务端 `sharing_info.privacy_type` 本来就是 `private`）；'
    '③ ①+② → 一样；④ **`set_shared {policy:album, album_id, enabled:false}` → `shared=false`、`sharing_link` 清空、'
    '`category=shared` 归 0** ✅。真机上界面还弹了 `Link sharing turned off`（= 服务端回了 success）。'
    '**修法**：`_confirmDisableLink` 改发 `setLink(enabled:false, deactivating:true)`；`setLink` 新增 `deactivating` —— '
    '真机回包会把**正在作废**的链接原样回给我们 ⇒ 此时不记回包、清旧缓存（否则界面挂着一条打不开的外链）。'
    '★ 同轮改写 r402 的老用例（它把发 `update` 当**正确行为** = 假判据）。'
    '**用例**：`test/photo_album_write_test.dart` 的 `★ DA77` 组 **3 条** ＋ `test/photo_c2_pages_test.dart` 两条；'
    '**反向验证**：换回 `update` ⇒ `+25 -2`；摘掉 `deactivating` ⇒ `+26 -1`（恰好"旧链接不再显示"那条红）。'
    '**真机复验**（最终包 `798e0ed2…`）：`device/r417_20_disabled_after_fix.xml` 入口翻回 `Turn on link sharing`、'
    '`nas/r417_final_off.log` = `shared=false` / `link=<空>` / 我共享的 **0**。 |'
)

DA78 = (
    '| **DA78**（**r417 新登记并当轮修掉**） | '
    '**条件相册行的摘要把服务端记账键当成条件显示**：真机刚建好的「相机」条件相册读作 `Condition: Camera · Other`。'
    '**读到什么**（`docs/evidence-r417/nas/r417_after_cond_save.log`）：服务端 `condition` = `{"camera":[23],"user_id":4}`、'
    '`condition_object` = `{"camera":[{"id":23,"name":"LGE-AN10"}],"user_id":4}` ⇒ 那个 Other 就是**每条都有的记账键 `user_id`**'
    '（同一个函数还把 `<type>_policy` 一并翻成「其它条件」）。'
    '**修法**：`_conditionSummary` 增加 `_isConditionKey()` —— 跳过 `user_id` 与所有 `*_policy` 键。'
    '**用例**：`test/photo_c2_pages_test.dart` 的 `★ DA78` **1 条**；**反向验证**：摘掉过滤 ⇒ `+37 -1`（恰好这条红）。'
    '**真机复验**：`device/r417_38_condition_saved.xml`（改前 `Condition: Camera · Other`）→ '
    '`device/r417_40_condition_summary_fixed.xml`（改后 `Condition: Camera`）。 |'
)

row_anchor = [i for i, l in enumerate(s.split('\n')) if l.startswith('| **DA76**')]
assert len(row_anchor) == 1, row_anchor
lines = s.split('\n')
i = row_anchor[0]
lines = lines[: i + 1] + [DA77, DA78] + lines[i + 1 :]

# §七十四 小节：把两条残留的**结果**与新增缺陷补上
old_sec = '### 七十四.3 三个闸门（r417 收尾读数，全部 exit 0）'
new_sec = '''### 七十四.2.1 目标④ 最后两条残留 —— 收口结果（真机动作级）

| 残留（r402/r415/r416 登记） | 这一轮怎么验的 | 结果（服务端回读为准） |
|---|---|---|
| 相册「共享相册**非空分支**」 | 真机建临时相册 `r417share` → 相册 `⋮ → 共享` → 生成链接 → **打开外链分享** → 回「更多相册功能 → 共享相册 → 我共享的」看**非空** → 点行回共享页 → 关闭外链 | `category=shared` **0 → 1 → 0**；`shared` **false → true → false**；`link` 空 → 55 字符 → 空；界面「我共享的」从 `No one has shared…` 变 `r417share · 0 items · shared`（`r417_24_final_shared_by_me.png`） |
| 条件相册「保存闭环」 | 真机：条件相册 → 新建 → 名称 `r417cond` ＋ Camera = `LGE-AN10` → 预览 → 保存 → 看列表行 → 删除 | NAS：`id=10 name=r417cond item_count=10 type=condition`、`condition={"camera":[23],"user_id":4}`、`condition_object.camera[0]={id:23,name:LGE-AN10}`；界面预览 **10** 张 = `peek_item_count` **10** = 相册 `item_count` **10**（三处同源） |
| 收工还原（仪器㉒/仪器51） | 删条件相册 → 删临时相册 → 再回读一次 | **与改前基线逐字相同**（`nas/r417_restore_diff.txt`：7 行归一化后 `diff` 为空）：`category=all` = 1 个（`test`）、我共享的 0、与我共享 0、条件相册 0 |

> ★ 顺带挖出并当轮修掉的两个真缺陷：`DA76`（生成链接后**打不开**外链分享）、`DA77`（**关闭外链分享根本没关**，
> 却弹「已关闭」）、`DA78`（条件相册行把 `user_id` 显示成「其它条件」）。
> ★ 一条**诚实边界**：`我共享的` 非空分支走的是**外链公开**这条路（不惊动其它账号）；
> **邀请成员**（`Sharing.Passphrase/update` 的成员增删）这一轮**仍未真机验**，见 §S8。

### 七十四.3 三个闸门（r417 收尾读数，全部 exit 0）'''
assert s.count(old_sec) == 1
s = '\n'.join(lines)
s = s.replace(old_sec, new_sec)

# 顶部指针再补一句（DA77/DA78）
old_top = '**新登记并当轮修掉 `DA75`/`DA76`**（相册共享没有入口、生成链接后打不开外链分享）**'
new_top = '**新登记并当轮修掉 `DA75`/`DA76`/`DA77`/`DA78`**（相册共享没有入口、生成链接后打不开外链分享、关闭外链分享关不掉、条件相册行把 `user_id` 显示成「其它条件」）**'
assert s.count(old_top) == 1
s = s.replace(old_top, new_top)

for a in ('| **DA77**', '| **DA78**', '| **DA76**', '| **DA1**'):
    assert s.count(a) >= 1, a
assert s.startswith('# 安卓真机验收 · **汇总报告**')
assert len(s) > len(s) - 1
io.open(P, 'w', encoding='utf-8').write(s)
print('summary chars=%d bytes=%d' % (len(s), len(s.encode('utf-8'))))
