#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""r417 台账收尾：把 S4–S8 与 §5.1、闸门读数补齐（只替换骨架里的"待填"块）。"""
import io

P = 'docs/android-ui-audit-r417.md'
s = io.open(P, encoding='utf-8').read()
assert len(s) > 4000, len(s)  # 实测 4534 字符（仪器§1.6.2）

SEC_S4 = '''## S4 重建重装（仪器㊷）

**`lib/` 改了 ⇒ 必须重建 + 重装 + 真机复验。本轮一共重建了 5 次**（每修一条缺陷一次），
最后一次才是最终包。判据一律取产物 sha256（仪器㊽），**不看 Gradle 打印**：

| 次序 | 触发了什么 | 产物 sha256 | 设备上 base.apk 同哈希？ |
|---|---|---|---|
| ① | `DA75`（入口） | `3cc6feeb4e470d2d4ca353772c2806ea75700b3fee60288f226cdc6a8b59d4f8` | ✅ `r417_01_installed_sha256.txt` |
| ② | `DA76`（打不开外链） | `36079664a76d050cfdbdf0e28a6ddf0996aed69c2e9b891230242788cb5632f5` | ✅ `r417_09_installed_sha256.txt` |
| ③ | `DA77`（关不掉外链） | `2e8310db764a2b0af9bab8e134057e317b3f75b8ec5c220a317dac2d3a28d914` | ✅ `r417_17_installed_sha256.txt` |
| ④ | `DA77` 第二刀（关闭时清"回包缓存"） | `9ac326d9324c9a6a633964e9ea70a62f25f1bfc1ad7b9f1cdc40a75194b2cc94` | ✅ `r417_21_installed_sha256.txt` |
| ⑤ | `DA78`（条件相册行摘要） | `798e0ed25c70437f423a8c9667bd84875c5e2321bc26639e82e31d6b8782ba33` | ✅ `r417_39_installed_sha256.txt` |

* 构建一律走 `scripts/build_arm64_release.sh`（默认 debug 签名 ⇒ 可以 `-r` 覆盖安装、**保留登录与数据**）；
  收尾读数见各次 `/tmp/r417_build*.log` 的 `apksigner verify --print-certs`
  （`V2 Signer: certificate DN: C=US, O=Android, CN=Android Debug`）。
* ★ **我自己踩的坑（记下来免得再犯）**：第一次把 `nohup ./scripts/build_arm64_release.sh &` 放在**后台 bash 工具调用里**
  ⇒ 包装进程立刻退出（`exit 0`）、日志看着"跑完了"，而 APK 还是旧的（mtime 停在上一轮、sha 没变）。
  改法：构建**直接用后台任务**跑（不要在里面再 `&`），并用 `ps aux | grep assembleRelease` 确认真的在跑。

'''

SEC_S5 = '''## S5 真机：共享相册「非空分支」闭环（含 `DA76` / `DA77` 的真机复验）

**这一格原来登记的理由是"要造一条非空 ⇒ 要写动词"。本轮用"自建临时相册 + 三腿读数"把它做完了，
并把挡在路上的两个真缺陷一起修掉。**

### S5.1 三腿读数（宿主只读基线 → 真机写 → 宿主只读回读）

| 时点 | `category=all` | `category=shared`（我共享的） | 界面 | 证据 |
|---|---|---|---|---|
| `before` | 1 个（`test` id 8，private） | `[]` | `No one has shared an album with you yet` | `nas/r417_before.log` · `device/r417_13_shared_albums.xml` |
| 真机建相册（`r417share`） | 2 个（＋ id 9） | `[]` | 相册段出现 `r417share` | `nas/r417_after-create.log` · `device/r417_04_album_created.xml` |
| 生成共享链接（`set_shared(enabled:false)`） | id 9 `passphrase=<len=9>`、**`link=<空>`**、`shared=false` | `[]` | 页内「Password protection」从"先生成链接"变成「No password set」 | `nas/r417_after-link.log` ← **`DA76` 的决定性读数** |
| **打开外链分享**（`set_shared(enabled:true)`） | id 9 `shared=true`、`link=<len=55>` | **1 个** ✅ | 「我共享的」= `r417share · 0 items · shared` | `nas/r417_final_on.log` · `device/r417_24_final_shared_by_me.png` |
| 点该行回共享页 | 同上 | 同上 | 外链可复制 / 口令 / 成员 / `Turn off link sharing` | `device/r417_15_shared_row_open.xml` |
| **关闭外链分享** | id 9 `shared=false`、`link=<空>` | **0 个** ✅ | 入口翻回 `Turn on link sharing`、旧链接不再显示 | `nas/r417_final_off.log` · `device/r417_20_disabled_after_fix.xml` |

### S5.2 `DA76`（生成链接后**打不开**外链分享）

* **改前**（修 `DA75` 后的包）：共享页只有 `Shared link: No link yet` / `Create share link` / `Password protection` / `Members`
  ⇒ **点不着"打开外链分享"**（`device/r417_07_share_page.xml`）。
* **读到什么**：`set_shared(enabled:false)` 之后服务端 `sharing_info.sharing_link` 仍是**空串**
  （`passphrase=<len=9>`、`shared=false`、`category=shared` 仍 `[]`，`nas/r417_after-link.log`）
  ⇒ 旧判据 `sharingLink.isNotEmpty` 等的是一个**永远不来的字段**。
* **修后**（`device/r417_10_share_page_after_fix.xml`）：口令在就给「Turn on link sharing」；点它 → 二次确认
  （`device` 内 `Turn on link sharing?` / `Anyone with the link can browse this album unless a password is set.`）
  → 链接立刻显示出来（`https://nas.example.com:5001/mo/sharing/j5vXSOMqP`）。

### S5.3 `DA77`（关闭外链分享**根本没关**，却弹"已关闭"）

* **改前真机**：点 `Turn off link sharing` → 确认（按钮逐字是 `Delete`）→ snackbar **`Link sharing turned off`**
  （⇒ 说明**没抛错**、服务端回了 success），但**同刻**：链接还在、`Turn off link sharing` 还在、
  NAS 侧 `shared=true`、`category=shared` 仍有它（`/tmp/r417_snack.png`）+ 两次回读都如此。
* **读到什么**：`tool/probe_r417_disable_shapes.dart` 把四个形状逐个打同一台 NAS
  （`nas/r417_disable_shapes.log`）：① `update {permission:delete public}` → `OK {}`、状态**没变**；
  ② `update {privacy_type:'private'}` → `OK {}`、**没变**（该字段本来就是 `private`）；③ ①+② → **没变**；
  ④ **`set_shared {policy:album, album_id, enabled:false}` → `shared=false`、`sharing_link` 清空、`category=shared` 0** ✅
  ⇒ 关闭外链 = `set_shared(enabled:false)`；原来那条是"**被接受但什么都不改**"（仪器73 那一族）。
* **修后**：同一条路径 ⇒ UI 翻回 `Turn on link sharing`、不再显示旧链接；NAS `shared=false` / `link=<空>` / 我共享的 0。
* ★ **附带发现**：关闭时 `set_shared(false)` 的**回包**会把**正在作废**的那条链接原样回给我们
  ⇒ 只看回包非空就缓存，界面会继续挂着一条打不开的外链。所以加了 `deactivating` 参数：关闭时**不记回包、清缓存**
  （反向验证：摘掉它 ⇒ 恰好"旧链接不再显示"那条红，`+26 -1`）。
* ★ **老用例是假判据**：`test/photo_c2_pages_test.dart` 里 r402 写的
  `⑤ 关闭外链：点"确定" → update privacy_type=private` 把**错误行为**断言成了正确行为 ⇒ 本轮改写为钉 `set_shared`。

'''

SEC_S6 = '''## S6 真机：条件相册「保存闭环」（含 `DA78` 的真机复验）

**这一格原来登记的是"保存闭环（写动词 `create`/`set_condition`）"。本轮完整走了一遍，
并当场撞到 `DA78`。**

| 步骤 | 真机读数 | 证据 |
|---|---|---|
| 入口 | `更多相册功能` 滚到底 → `Condition albums`（`Auto-built albums from time, place, people or tags`）→ `No condition albums yet` | `device/r417_28_condition_list.xml` |
| 编辑器 | 名称框 / 媒体类型（`All`·`Photos`·`Videos`）/ 关键词 / 六个类型行（People·Scenes·Tags·Place·Camera·Lens，每行 `+` 与 `Match all`）/ `Preview matching photos` / `Save` | `device/r417_29_condition_editor.xml` |
| 选值 | `Camera` 行 `+` → 面板列出 **`LGE-AN10`** → 勾选 → `OK` ⇒ 行变 **`1 selected`** | `device/r417_31_camera_sheet.xml` · `r417_35_camera_selected.xml` |
| 预览 | `Matching photos: 10` | `device/r417_37_preview.xml` ＋ `.png` |
| 保存 | 回到列表：`r417cond` + `Condition: Camera`（改后） | `device/r417_38_condition_saved.xml`（改前）· `r417_40_condition_summary_fixed.xml`（改后） |
| **NAS 侧回读** | `id=10 name=r417cond item_count=10 type=condition`、`condition={"camera":[23],"user_id":4}`、`condition_object={"camera":[{"id":23,"name":"LGE-AN10"}],"user_id":4}` | `nas/r417_after_cond_save.log` |
| **三处同源** | 界面预览 **10** ＝ `peek_item_count` **10** ＝ 相册 `item_count` **10** | 同上 ＋ `device/r417_37_preview.png` |
| 删除还原 | 列表回 `No condition albums yet`；NAS `条件相册 共 0 个` | `device/r417_41_condition_deleted.xml` · `nas/r417_after_cond_delete.log` |

### S6.1 `DA78`（条件相册行把服务端记账键显示成"其它条件"）

* **改前**：列表行逐字 `Condition: Camera · Other`（`device/r417_38_condition_saved.xml`）。
* **读到什么**：服务端 `condition={"camera":[23],"user_id":4}` —— 那个 `Other` 就是**每条都有的记账键 `user_id`**
  （同一个映射还会把 `<type>_policy` 翻成"其它条件"）。
* **修后**：`Condition: Camera`（`device/r417_40_condition_summary_fixed.png`）。

'''

SEC_S7 = '''## S7 收尾

### S7.1 三个闸门（全部 exit 0）

| 闸门 | 读数 |
|---|---|
| ① `flutter analyze lib test tool/mock_dsm` | **`No issues found! (ran in 7.0s)`** |
| ② `flutter test -r expanded` | **`+11608 ~117`**、`[E]` = 0、`All tests passed!`（r416 基线 `+11597` ⇒ **+11** = `DA75` 4 ＋ `DA76` 5 ＋ `DA77` 3 ＋ `DA78` 1，另有 2 条老用例被**改写**） |
| ③ `python3 tool/page_coverage_matrix.py --check` | **`pages=160 verdicts=160`**、`{'A': 140, 'B': 1, 'C': 2, 'E': 17}` |

### S7.2 收工还原（零残留，仪器㉒/仪器51）

* 临时相册 `r417share`（id 9）**已删**、条件相册 `r417cond`（id 10）**已删**；
* 收尾回读与**改前基线归一化后逐字相同**（`nas/r417_restore_diff.txt`：7 行 `diff` 为空）；
* 唯一"留下"的是 `test`（id 8）—— 它本来就在，全程 `item_count=2`、`private`、`shared=false` 未动。

### S7.3 记账

* `docs/defect-closure-registry.md`：`DA1`–`DA78`（**81 行**，含 5 个带字母子号）逐条 状态/修法/用例/真机复验；
  守卫 `test/defect_closure_test.dart` **8 条判据**全绿。
* `docs/android-acceptance-summary.md` §6.13 加 `DA75`/`DA76`/`DA77`/`DA78` 四行 ＋ §七十四 小节。
* `docs/android-page-coverage-matrix.md`：`photos/photo_c2_sections.dart` 那两格"剩余缺口"**划掉**（改为 r417 已做 ＋ 读数）。

'''

SEC_S8 = '''## S8 未验清单与边界（诚实）

| # | 项 | 为什么没验 | 什么时候能验 |
|---|---|---|---|
| 1 | **邀请成员 / 移除成员**（`Sharing.Passphrase/update` 的成员分支） | 会**通知第三方账号**（`list_user_group` 里只有真实用户 `demo_admin`/`demo_user`/`richinfo`）。想造一个"成员"就得动别人账号，本轮**不做** | 用户明确同意"可以邀请某个测试账号"时 |
| 2 | **`与我共享`（withMe）非空分支** | 需要**另一个账号**主动共享给本账号 ⇒ 同上 | 同上 |
| 3 | 口令保护（`Passphrase/update {password}`）写动词 | 会往相册上留一个真口令；本轮先把"打开/关闭外链"闭环做完，口令分支已有离线用例 | 下一轮（同一套三腿做法） |
| 4 | 条件相册的**编辑**（`set_condition`） | 本轮验的是"新建 → 保存 → 删除"闭环；编辑走同一个编辑器 + 同一保存调用 | 下一轮（增量一格） |
| 5 | 条件相册里 People/Scenes/Tags 的**非空**取值 | 该 NAS `enable_person:false`、`Person/count=0`（r412 已定性"当前配置不可达"）；Tags 取值 r412 已有读数 | 已有定性的不重复验 |

★ **一条口径说明**：本轮为验"非空分支"而**真的往 NAS 上写了东西**（建/删临时相册、外链开关、条件相册），
但**当轮全部还原**，收尾回读与改前基线逐字相同 —— 这是"写动词闭环"的标准做法（AGENTS §2.0.54 同款），不是残留。

'''

SEC_51 = '''## §5.1 本轮变更动词声明

**调用了变更动词 —— 且分三类，逐类写清；全部当轮还原。**

| 类别 | 具体动作 | 目标 | 还原 |
|---|---|---|---|
| ① **真机 UI 写**（App 自己的代码路径，`adb` 只在屏幕上点） | `Browse.Album/create`（建 `r417share`）· `Sharing.Passphrase/set_shared` 打开/关闭外链（×3 轮）· `Browse.ConditionAlbum/create`（建 `r417cond`）· `Browse.Album/delete`（删两个临时相册，含条件相册走 `delete`） | 真 NAS 上的**临时**相册 id 9 / id 10 | ✅ 收尾回读 = 改前基线（`nas/r417_restore_diff.txt`） |
| ② **宿主写探针**（只有一次，为了定性 `DA77`） | `tool/probe_r417_disable_shapes.dart` 打四种 `Sharing.Passphrase/update` / `set_shared` 形状 | 只碰临时相册 id 9 | ✅ 同上（相册已删） |
| ③ **宿主只读探针**（每腿都跑） | `me` / `Browse.Album list+get` / `Sharing.Misc list*` / `Browse.ConditionAlbum list` / `peek_item_count` / `Sharing.Passphrase get` | — | 零写入 |

* **没碰**：用户既有相册 `test`（id 8）的**任何**字段（全程 `item_count=2`、`private`、`shared=false` 未变）；
  没邀请任何账号、没改任何服务端偏好、没动 `Setting.*`。
* **密钥卫生**：会话口令只从 `~/.synhub-nas.env`（仓库外，0600）取；共享口令在日志里**只打长度**
  （`<len=9>`），`Passphrase/get` 的回包也做了 `replaceAll(secret,'<redacted>')`。
* **代码侧**：`lib/` 改了 4 个文件（`photo_c2_sections.dart` / `photo_c2_providers.dart` /
  `photo_browse_page.dart` / `app_{zh,en}.arb` ＋ gen-l10n 产物），每改一次都重建重装并真机复验（S4 表）。

'''

# 逐块替换骨架里的"待填"
pairs = [
    ('## S4 重建重装（仪器㊷）\n\n**待填**（`lib/` 改了就必须重建 + 重装 + 真机复验）。\n', SEC_S4),
    ('## S5 真机：共享相册「非空分支」闭环\n\n**待填**\n', SEC_S5),
    ('## S6 真机：条件相册「保存闭环」\n\n**待填**\n', SEC_S6),
    ('## S7 收尾\n\n**待填**\n', SEC_S7),
    ('## S8 未验清单与边界（诚实）\n\n**待填**\n', SEC_S8),
    ('## §5.1 本轮变更动词声明\n\n**待填**\n', SEC_51),
]
for old, new in pairs:
    assert s.count(old) == 1, old[:40]
    s = s.replace(old, new)

# 头部三条闸门读数 + DA 编号补齐
old_head = ('> 本轮把它们**做完**，并顺手挖出并当轮修掉一个真缺陷 **`DA75`**：')
new_head = ('> 本轮把它们**做完**。过程中挡路的是**四个**真缺陷，全部当轮修掉：'
            '**`DA75`**（相册共享没有入口）· **`DA76`**（生成链接后打不开外链分享）· '
            '**`DA77`**（关闭外链分享发错了方法 ⇒ 界面谎报、服务端没关）· '
            '**`DA78`**（条件相册行把服务端记账键 `user_id` 显示成「其它条件」）：')
assert s.count(old_head) == 1
s = s.replace(old_head, new_head)

old_gates = ('> 三闸门：`flutter analyze` = **`No issues found! (ran in 6.5s)`** ·\n'
             '> `flutter test -r expanded` = **待填** · `page_coverage_matrix.py --check` = **待填**。')
new_gates = ('> 三闸门（收尾读数，全部 exit 0）：`flutter analyze lib test tool/mock_dsm` = '
             '**`No issues found! (ran in 7.0s)`** ·\n'
             '> `flutter test -r expanded` = **`+11608 ~117`**（`[E]`=0）· '
             '`python3 tool/page_coverage_matrix.py --check` = **`pages=160 verdicts=160`**、'
             "`{'A': 140, 'B': 1, 'C': 2, 'E': 17}`。")
assert s.count(old_gates) == 1
s = s.replace(old_gates, new_gates)

assert '待填' not in s, '还有没填的块'
assert s.count('## S4') == 1 and s.count('## §5.1') == 1
assert len(s) > 12000, len(s)
io.open(P, 'w', encoding='utf-8').write(s)
print('ledger chars=%d bytes=%d' % (len(s), len(s.encode('utf-8'))))
