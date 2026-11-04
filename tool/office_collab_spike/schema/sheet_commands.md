# `.osheet` 协作命令词表（静态导出）

> **来源**：Synology Office SPK **3.8.0-22711 (x86_64)**，离线静态分析，未联网、未动设备。
> **生成器**：`tool/office_collab_spike/schema/mine_sheet_commands.js`
> **机器可读产物**：`tool/office_collab_spike/schema/sheet_commands.json`（含每条命令的 `文件 + 字节偏移 + 键名 + 原文片段`）
> **证据等级标记**：`SPK-JS 原文` / `SPK 束内模块` / `SPK-.so strings` / `既有真机帧` / `推断`

---

## 0. 一句话结论

**`set` 命令族的全量词表可以静态导出，不需要抓官方会话。**
`server/sheet/node_modules/@ss/core.js` + `runtime.js` 是**未混淆语义**的 webpack 束（函数/类名被压缩，但
**所有命令字符串、字段名、switch 分发器都是字面量**），因此命令词表是 `SPK-JS 原文` 级证据。
本批导出 **148** 条命令词（101 条字面量 + 141 个 server switch case label 的并集），其中 **100 条**带可用字段形状。

**缺口**：不是"词表缺"，而是**每条命令 payload 的完整 JSON schema**（尤其 `changes` / `data` / `json` 这些
嵌套结构的内部形状）以及**规则引擎（protection / 条件格式）的接受条件**。见 §6。

---

## 1. socket 层契约（`SPK-JS 原文`）

### 1.1 事件表

`server/sheet/core/client.js`（**明文、未混淆，最权威**）：

```js
t.on("init",  e => this._onInit(e));
t.on("peek",  e => this._onPeek(e));
if (this.isWritable() || this.isCommentable()) { t.on("set", (e,t) => this._onSet(e,t)); }
if (this.isWritable()) {
  t.on("peer", e => this._onPeer(e));
  t.on("query_cell_history", (...e) => this._onQueryCellHistory(...e));
  t.on("save", (e,t) => this._onSave(e,t));
}
```

| 事件 | 方向 | 谁可以发 | 载荷 | ack 形状（原文） |
| --- | --- | --- | --- | --- |
| `init` | C→S | 任意可读 | 无 | `e(t.identifier, t.rev, t.getCommands())` → `[identifier, rev, commands[]]` |
| `peek` | C→S | 任意可读 | 无 | `e(t.identifier, t.rev, this.perm.writable)` → `[identifier, rev, writable]` |
| `set` | C→S | writable **或** commentable（仅限 5 条评论命令） | `{cmd, rev, …}` | `s(revIncoming, currentRev, status[, extra])` |
| `peer` | C↔S | writable | `{cmd, …}` | 无（广播） |
| `query_cell_history` | C→S | writable | `(e,t,i,s,n)` | `n(result)` |
| `save` | C→S | writable | `{mode}` / `{}` | `ack({success, snapshot_version})` |
| `ready` | S→C | — | 无 | 实例装载完成信号（**必须等它**，与 doc 同） |
| `reload` / `kick` / `set_info` / `init_error` | S→C | — | — | `server/sheet/core/index.js` 的 `onConnect` |

> `peek` 的三参数正是前批真机纠正的那一条（`docs/office-collab-protocol-spike.md` §2.6）——本批从静态源**独立复现**该结论。

### 1.2 `set` 的 rev 乐观锁（`SPK-JS 原文`）

`server/sheet/core/client.js :: _onSet` 全文逻辑：

```js
_onSet(t, s) {
  const n = i.has(t.cmd);                       // i = new Set(["create_comment","reply_comment","edit_comment","reopen_comment","resolve_comment"])
  if (!this.perm.writable && !n) return;         // 非 writable 只放行评论命令
  const o = this.instance.getQueue();
  const c = o.rev;                               // 当前 rev
  const a = t.rev;                               // 客户端自报 rev
  if (!a || a !== c + 1) { s(a, c, 2); return; } // ★ 版本冲突 → status 2
  if (!this.instance.validateCommand(this, t)) { s(a, c, 0); return; }  // 规则拒绝 → status 0
  const [r, h] = this.instance.execCommand(t);   // [ok, extra]
  if (!r) { s(a, c, 0); return; }                 // 执行失败 → status 0
  s(a, t.rev, 1, h);                              // ★ 成功 → status 1, extra = 执行结果
  t.uid = this.uid; t.client_id = this.id;        // 服务端覆写 uid / client_id
  this.instance.writeCommand(t);                  // 入队（queue.addCommands → queue.rev++）
  this.broadcast("set", t);
  if (n) this._processComment(t);
  if (o.size() >= e.SNAPSHOT_THRESHOLD) this.instance.snapshot().catch(()=>{});
  else this.instance.scheduleSave();
  this.updateMtime();
}
```

**status 三态（这是 M3 必须实现的核心）**

| status | 语义 | 客户端应做什么（`ui/dist/ui.sheet.js` 原文） |
| --- | --- | --- |
| `1` | 应用成功 | `r = 1===i`；若 `revIncoming + remoteQueue.length === currentRev` 则 `onAfterSync()` |
| `2` | **版本过期**（`a !== c+1`） | `_resolveConflict(...)` → undo 本地未确认命令 → 重放 `remoteQueue` → redo → `_adjustRev(currentRev)` 后重发 |
| `0` | 被拒绝（规则/执行失败） | 同上走 `_resolveConflict(false)`，但**不计入** remote 冲突 |

客户端侧（`ui/dist/ui.sheet.js @3832195`）：

```js
_sendNextCommand(){ … this.rev++; let e=this.commandQueue.shift(),
    t=compact(e.toData()); t.rev=this.rev; this.setupPendingCommand(e); this._emit("set",t,this._onAck.bind(this)); }
async _onAck(e,t,i,n){ let o=this.pendingCommand; o&&this.rev===e||this.onSyncError();
    let r=1===i, a=e===t; … }
```

→ **`set` 出站载荷 = `compact(command.toData())` + `rev`**，`rev` 由客户端单调自增。
`compact` 会剥掉默认值（与 doc 侧同样的"省略默认 attrs"哲学）。

### 1.3 错误码

- `server/sheet/core/error_code.js`（**全文**）：`SNAPSHOT_ERR = {SNAPSHOTTING:1, NOT_READY:2, DEFERRED:3}` —— 这是 **HTTP/内部**快照错误，**不是** `set` 的 status。
- doc/socket 侧通用错误码在 `server/common/collab/Constants.js`（前批已列：401/402/403/404/405/406/407/408/409/410/411/500）。

---

## 2. 命令分发器地图（`SPK-JS 原文`）

命令按 `cmd` 字符串分发给多个 controller。每个 `switch(<x>.cmd)` 的 `case` 标签就是**服务端接受的词**。

| # | 文件 | 偏移 | 分发器 | case 数 | 说明 |
| --- | --- | --- | --- | --- | --- |
| 1 | `@ss/core.js` | `630760` | `Workbook.execCommand` **主分发** | 54+ | cell/row/col/style/filter/validation/cf/drawing |
| 2 | `@ss/core.js` | `702883` | 另一个 workbook 视图层 | 37 | 与 #1 大体同集，多 `create_row`/`create_col`/`move_row`/`move_col` |
| 3 | `@ss/core.js` | `636815` | 上层 mixed 分发 | 49 | #1 + 评论 + define + pivot + `worksheet.*` |
| 4 | `@ss/core.js` | `637800` | 去掉评论后 | 37 | define + pivot + `worksheet.*` |
| 5 | `@ss/core.js` | `638124` | 再去掉 define | 34 | |
| 6 | `@ss/core.js` | `638352` | 再去掉 cf | 31 | |
| 7 | `@ss/core.js` | `638636` | 只剩 pivot+worksheet | 29 | |
| 8 | `@ss/core.js` | `486697` | `extractCommand` (dp) 的预处理 switch | 14 | **命令规范化**：`font/alignment/border/compound/insert_row/insert_col/row_style/col_style/global_style` + 评论 author 注入 |
| 9 | `@ss/core.js` | `936362` | `PivotTableController` | 17 | |
| 10 | `@ss/core.js` | `941480` | `PivotController` | 19 | |
| 11 | `@ss/runtime.js` | `45943` | `RuleController.execCommand` | 19 | 条件格式规则 |
| 12 | `@ss/runtime.js` | `39149` | `WorkbookController.execCommand` | 37 | |
| 13 | `@ss/runtime.js` | `48960` | `WorkbookController` **`worksheet.` 前缀分发** | 10 | `switch(s.substring(10))` |
| 14 | `server/sheet/core/client.js` | `1423` | `_onSet` 的评论白名单 | 6 | `isCommentable` 放行集 |
| 15 | `server/sheet/core/client.js` | `1898` | `_onPeer` 的 peer 命令 | 3 | `select`/`update`/`deselect` |

> **`extractCommand` 是关键中间层**：它在命令进入模型前做规范化（例：`row_style`/`col_style`/`global_style`
> 带 `type:"font"|"alignment"|"border"` 判别式，按 `type` 分派到不同的 mark 规范化函数）。
> 自研实现若跳过这一层，等价命令会被判为非法/静默错位。

---

## 3. 命令族全表（148 词）

标记：`C` = 客户端（`ui/dist/ui.sheet.js`）出现；`S` = 服务端 switch/literal 出现。
`字段` 列来自 `{cmd:"…", …}` 字面量或 `function xx(){return {cmd:…}}` 工厂函数的键名。

### 3.1 cell / block（21）

| cmd | C | S | 字段 | 证据 |
| --- | --- | --- | --- | --- |
| `value` | ✅ | ✅ | `id, changes:[[row,col,value],…], source` | `core.js@697584` `v4(e,t,r){return{cmd:"value",id:e,changes:t.map(e=>[e[0],e[1],fp(e[2])?e[2].toJSON():e[2]]),source:r}}` |
| `note` | ✅ | ✅ | `id, changes` | `v6(e,t){return{cmd:"note",id:e,changes:t}}` |
| `format` | ✅ | ✅ | `id, changes, overwrite, source` | `yt(e,t,r,i,n){return{cmd:t.toLowerCase(),id:e,changes:r,overwrite:i,source:n}}` |
| `compound` | ✅ | ✅ | `actions:[…]` | `v5(e){return{cmd:"compound",actions:e}}` |
| `font` / `fill` / `alignment` / `border` | ✖ | ✅ | 由 `extractCommand` 按 `type` 归一化 | `@ss/core.js@486682` |
| `row_style` / `col_style` / `global_style` | 部分 | ✅ | `{…, type:"font"\|"alignment"\|"border", value, revert, rowChanges, colChanges, cellChanges}` | `global_style` 字面量在 `core.js`；`extractCommand` 按 `type` 分派 |
| `merge` / `unmerge` | `unmerge`✖ | ✅ | `id, range` | `ye(e,t,r){return{cmd:t?"merge":"unmerge",id:e,range:…}}` |
| `unmerge_overlaps` | ✅ | ✅ | `id, range` | |
| `sort` | ✅ | ✅ | `id, rowOrder, range, applyData` | |
| `group` / `ungroup` | ✅ | ✅ | `id, type, from, to` | |
| `update_group` | ✅ | ✅ | `id, type, from, levels` | |
| `set_collapse` | ✅ | ✅ | `id, type, index, collapse` | |
| `paste_autofill_data` | ✅ | ✅ | `id, range, data, expandFilter, source` | |
| `populate_autofill_data` | ✅ | ✅ | `id, range, data, direction, source` | |
| `autofill_number_format` | ✅ | ✅ | `id, range, fc, direction, source` | |

### 3.2 row / column（16）

| cmd | C | S | 字段 | 证据 |
| --- | --- | --- | --- | --- |
| `insert_row` / `insert_col` | ✖ | ✅ | `id, index, amount, refIndex, data` | `v9(e,t,r,i,n,o){return{cmd:\`insert_${t}\`,id:e,index:r,amount:i,refIndex:n,data:o}}` |
| `remove_row` / `remove_col` | ✖ | ✅ | `id, index, amount, refIndex, data` | `v7`（同上模板 `remove_${t}`） |
| `resize_row` | ✅ | ✅ | `id, from, to, height` | `v8(e,t,r,i,n){return "row"===t?{cmd:"resize_row",id:e,from:r,to:i,height:n}:{cmd:"resize_col",id:e,from:r,to:i,width:n}}` |
| `resize_col` | ✅ | ✅ | `id, from, to, width` | 同上 |
| `create_row` / `create_col` | ✖ | ✅ | 无字面量 | 仅在 dispatch #2/#8 的 case 标签出现 |
| `move_row` / `move_col` | ✖ | ✅ | 无字面量 | 同上 |
| `fix_row` | ✅ | ✅ | `id, row` | |
| `fix_col` | ✅ | ✅ | `id, col` | |
| `hide_rows` / `show_rows` / `hide_cols` / `show_cols` | ✖ | ✅ | 无字面量 | |

> **注意**：`hide_rows`/`insert_row` 等在**客户端**是以 `cmd:"…"` 之外的形态组装的（`ui.sheet.js` 里
> 用模板字符串或 `Action.toData()`），所以"客户端出现=✖"**不代表客户端不发**，只代表本批没有在该束里
> 抓到字面量。见 §6 缺口表。

### 3.3 worksheet 生命周期（10）

`@ss/runtime.js@48960`（**原文**）：

```js
execCommand(e){ let t,r=!0,s=e.cmd||""; if(!s.startsWith("worksheet."))return[!0,t];
  switch(s.substring(10)){
    case"create":              r=!!(t=this.createWorksheet(this.generateNextTitle(e.titleTpl),e.pos)), …; break;
    case"create_pivot_table":  …; break;
    case"create_with_data":    r=!!(t=this.createWorksheetWithData(e.titleTpl,e.tabColor,e.pos)), t&&(Object.assign(e.content,{rewriteTitle:e.titleTpl}),Object.assign(e,t,{cmd:"worksheet.create",titleTpl:void 0})); break;
    case"dup":                 …; break;
    case"undelete":            …; break;
    case"delete":              …; break;
    case"rename":              …; break;
    case"set_order":           …; break;
    case"set_hidden":          …; break;
    case"set_color":           …;
  } return[r,t] }
```

| cmd | C | S | 字段 |
| --- | --- | --- | --- |
| `worksheet.create` | ✅ | ✅ | `titleTpl`（+ `pos`）；执行后服务端回填 `id/title/…` 并**清空 `titleTpl`** |
| `worksheet.create_with_data` | ✅ | ⚠ 只在前缀分发器（`create_with_data`） | `titleTpl, tabColor, content, rev`；**执行后被改写成 `worksheet.create`**（客户端不应期待原样回放） |
| `worksheet.create_pivot_table` | ✅ | ✅ | `pos, titleTpl, cacheJson, tableJson` |
| `worksheet.dup` | ✅ | ✅ | `id, pos, title, pivotTableIdMapping` |
| `worksheet.undelete` | ✅ | ✅ | `id, pos, info, content` |
| `worksheet.delete` | ✅ | ✅ | `id, includeSnapshotData` |
| `worksheet.rename` | ✅ | ✅ | `id, title` |
| `worksheet.set_order` | ✅ | ✅ | `order` |
| `worksheet.set_hidden` | ✅ | ✅ | `id, hidden` |
| `worksheet.set_color` | ✅ | ✅ | `id, color` |

> **`worksheet.create_with_data` 的独立取证**：`server/sheet/worker_task/new_snapshot.js`（**原文**）：
> ```js
> const f={cmd:"worksheet.create",uid:y,id:"sh_1",pos:0,title:i,tabColor:l,content:u};
> ```
> → **新建 `.osheet` 的第一张表 section 固定叫 `sh_1`**，与导入态一致（§C）。

### 3.4 comment（12）

| cmd | C | S | 字段 | 备注 |
| --- | --- | --- | --- | --- |
| `create_comment` / `reply_comment` / `reopen_comment` / `resolve_comment` / `edit_comment` | ✅ | ✅ | `json`（`create_comment`/`edit_comment` 用 `json.id`；`reply_comment` 用 `json.target`；`edit_comment` 用 `json.threadId`） | 服务端 `extractCommand` 注入 `e.json.author = e.uid` |
| `*_local` 5 条 | 部分 | ✅ | `create_comment_local:{author, config}`、`reply_comment_local:{author, config}`、`edit_comment_local:{author, threadId, replyId, text}` | 由 `_processComment` 从公共命令派生，用于"公开评论"广播 |
| `paste_comment` | ✅ | ✅ | `jsonArray` | |
| `clear_comment` | ✅ | ✅ | `jsonArray` | |

**评论命令白名单**（`server/sheet/core/client.js`，**原文**）：
```js
const i = new Set(["create_comment","reply_comment","edit_comment","reopen_comment","resolve_comment"]);
if (!this.perm.writable && !n) return;   // commentable 用户只能发这 5 条
```

### 3.5 pivot table（20）

`create_pivot_table` / `delete_pivot_table` / `update_pivot_table` / `move_pivot_table` /
`set_pivot_table_caption` / `move_pivot_axis_field` / `insert_pivot_data_field` / `move_pivot_data_field` /
`remove_pivot_data_field` / `set_pivot_field_attr` / `set_pivot_data_field_attr` /
`set_pivot_field_item_order` / `_folded` / `_hidden` / `_caption` /
`group_pivot_field_item` / `ungroup_pivot_field_item` /
`set_pivot_field_number_group` / `set_pivot_field_datetime_group` / `pivot_compound{actions}`。

字段样例（`SPK-JS 原文`）：
```
create_pivot_table        : {cmd, table, cache}
update_pivot_table        : {cmd, table, cache}
delete_pivot_table        : {cmd, tableId}
move_pivot_table          : {cmd, tableId, sheetId, coord}
set_pivot_table_caption   : {cmd, tableId, key, value}
move_pivot_axis_field     : {cmd, tableId, fieldId, axis, position, coordShift, filterUpdate}
move_pivot_data_field     : {cmd, tableId, dataFieldId, position}
insert_pivot_data_field   : {cmd, tableId, fieldId, position, json}
remove_pivot_data_field   : {cmd, tableId, dataFieldId}
set_pivot_field_attr      : {cmd, tableId, fieldId, changes}
set_pivot_data_field_attr : {cmd, tableId, dataFieldId, changes}
set_pivot_field_number_group   : {cmd, tableId, fieldId, changes, itemsInfo}
set_pivot_field_datetime_group : {cmd, tableId, fieldId, changes, positions, autoFold, itemsInfo}
group_pivot_field_item    : {cmd, tableId, changes}
ungroup_pivot_field_item  : {cmd, tableId, changes}
pivot_compound            : {cmd, actions:[…]}   ← 服务端支持**逆序 undo 回滚**（core.js@941227）
```

### 3.6 filter（13）

`create_filter{id,filterId,range}` / `enable_filter` / `disable_filter` / `set_filter` / `update_filter_range` /
`create_filter_view{id,filterId,range,name,isPrivate}` / `enable_filter_view` / `disable_filter_view` /
`set_filter_view_condition` / `update_filter_view_name{id,filterId,name}` / `update_filter_view_range` /
`expand_filter_range{id,range}` / `set_active_filter_view{id,filterId}`。

### 3.7 data validation / conditional formatting / defined name（12）

- validation：`add_validation_range{id,validId,range}` / `create_validation` / `remove_validation` / `remove_all_validation`
- conditional formatting：`create_cf{id,cf,index}` / `remove_cf` / `update_cf_ranges` / `create_rule` / `update_rule` / `remove_rule`
- defined name：`create_define` / `modify_define` / `remove_define`

### 3.8 drawing / chart（11）

`insert_image` / `remove_image` / `resize_image` / `insert_chart` / `remove_chart` / `resize_chart` /
`adjust_chart{id,chartId,chartObj}` / `set_chart_config` /
`modify_drawings_by_insert` / `modify_drawings_by_move` / `modify_drawings_by_remove`（**仅客户端出现**）。

> `server/sheet/worker_task/snapshot.js`（**原文**）：
> ```js
> const m = new Set(["insert_image","remove_image"]);
> function d(e){ for(const t of e){ if(t.cmd==="compound"&&d(t.actions)||m.has(t.cmd)) return true } }
> … if(d(t)) { S.file = w.getFileList() }
> ```
> → **只有**当增量命令里出现 `insert_image`/`remove_image`（含嵌套在 `compound` 内）时，快照才写 `file` section。这是"何时出现 `@C_text/file`"的判定式。

### 3.9 其他（含非命令）

`compound`、`set_worksheet_rtl`、`move_formula_range`、`remove_formula_range`、
`add_internal_link` / `update_internal_link` / `remove_internal_link`、
`update_external_links` / `remove_external_links`、
`clear_range_data` / `clear_range_related` / `move_range` / `quotePrefix|quoteprefix`。

**非命令字面量（客户端 UI 状态，不要当命令）**：`+`、`-`、`=`、`edit`、`select`、`update`、`deselect`、`online`、`offline`。
其中 `select`/`update`/`deselect`/`online`/`offline` 是 **`peer` 事件的 cmd**（`server/sheet/core/client.js :: _onPeer`），
`+`/`-`/`=`/`edit` 是 `ui.sheet.js` 里公式编辑器的内部标记。**这些不是 `set` 命令。**

---

## 4. `peer` 命令（`SPK-JS 原文`）

```js
_onPeer(e){ e.client_id=this.id;
  switch(e.cmd){
    case"select": case"update": this.selection={row:e.row,col:e.col,img:e.img,id:e.id}; break;
    case"deselect": this.selection=null; break;
  }
  this.broadcast("peer", e); }
```
外加 `onSayHello` 广播 `{cmd:"online", …peerInfo}`、`sayBye` 广播 `{cmd:"offline", client_id}`。

---

## 5. 客户端发出的词（`ui/dist/ui.sheet.js`，99 条字面量）

`client_emitted_union`（`sheet_commands.json`）——与 §3 的服务端集**基本重合**，差异是：

- **仅客户端**（本批未在 server 束抓到对应字面量）：`+`, `-`, `=`, `edit`, `move_range`, `clear_range_data`,
  `clear_range_related`, `create_comment_local` 等 `*_local` 的组装点, `unmerge_overlaps`, `write` 类。
- **仅服务端**（客户端以非字面量形态发送，或由服务端内部派生）：`create_row`, `create_col`, `move_row`,
  `move_col`, `hide_rows`, `show_rows`, `hide_cols`, `show_cols`, `insert_row`, `insert_col`, `remove_row`,
  `remove_col`, `font`, `fill`, `alignment`, `border`, `row_style`, `col_style`, `set_filter`,
  `update_filter_range`, `update_filter_view_range`, `set_filter_view_condition`, `enable/disable_filter*`,
  `set_pivot_field_item_*`, `merge`, `unmerge`, 以及全部 `*_local`。

> **解释**：客户端大量命令是**先构造 Action 对象再 `toData()`**（`ui.sheet.js` 里的
> `class extends I4 { … _toData(){ return {cmd:"create_filter", …} } }`），
> 另一些直接调 `sendCommand({cmd:…})`。因此"字面量集合"只是**下界**。

---

## 6. 缺口清单 + 最省取证路径

| # | 缺口 | 影响 | 最省取证路径 |
| --- | --- | --- | --- |
| 1 | **`changes` / `data` / `json` 的内部 schema**（如 `value.changes` 的 `[row,col,value]` 三元组里 `value` 的变体：`fp(e[2])` 说明可以是带 `toJSON()` 的富对象；`format.changes` 的形状未导出） | 中高。`value` 已够改一个格 | ① 纯静态：在 `core.js` 里搜 `_execCommand` 对 `case"value"` 的消费点；② 受控探测：对自建 `.osheet` 发 1 条 `set{cmd:"value",rev:1,id:"sh_1",changes:[[r,c,42]]}` 看 status |
| 2 | **`style.styles` 索引语义**（`cells[r][c].s` 指向 `style.styles[i]`，而 `styles[i]` 再指向 `fonts/fills/alignments/borders/numberFormats` 的下标） | 中。读单元格文本不受影响，写格式受影响 | 静态：`core.js` 里 `getStyleManager().toJSON()` 与 `StyleManager` 的 `addXf` 逻辑；已有真实样本 `template/sheet/*/text.json` 可做对照 |
| 3 | **`RuleController.validateCommand` 的接受条件**（`server/sheet/node_modules/@ss/runtime.js@45943`，条件格式/保护规则） | 中。只影响被保护的表 | 静态：`RuleController` 的 `validateCommand` 实现就在同一束；本批只导出了它的 case 词表 |
| 4 | **`cmd` 的完整 payload schema 无官方 schema 文件** | 中 | 本批已给 100 条字段形状；余下 48 条多在 §3 表中标注"无字面量" |
| 5 | **`getCommands()`（`init` ack 的增量队列）里 command 是否含服务端回填字段** | 低 | 真机 `init` 已在 22711/22592 观测：`rev=0, commands=[]`（空表）。要非空需自建带增量的文件 |
| 6 | **`set` 的 `extra`（status=1 的第三参数）语义** | 低 | 静态：`execCommand` 的 `[t,s]` 第二分量即 `s`；逐命令追即可 |
| 7 | **`commentable` 用户发评论后的 `_processComment` 派生命令是否也要落盘** | 低 | 静态：`writeCommand(t)` 落的是**原命令**，`_processComment` 只发通知 |

**最省的总路径（推荐）**：**不需要抓官方会话**。M3 只需：
1. 读 §3.1 的 `value` 命令形状（已确证）；
2. 用本批 `sheet_commands.json` 的 `dispatchers` 定位 `case"value"` 的消费点，确认 `changes` 三元组语义；
3. 对**自建** `.osheet` 发 1 条 `set`，用 `status` 三态验证（与 doc 侧 M1 同法）。
   真机 `init`/`peek` 闭环前批已验证（`docs/office-collab-protocol-spike.md` §2.6），**零新增风险面**。

**明确挖不出来的**：命令 payload 的**官方 JSON Schema** 不存在于包内（没有 `.json` schema 文件、
`@ss/core.js` 里也没有 `ajv`/`jsonschema` 校验器）。任何"命令 schema"都只能从**实现代码**反推，
本文件的做法（导出字面量 + 字段键名 + 分发器偏移）已经是从静态源能拿到的**上限**。

---

## 7. 复现命令

```bash
node tool/office_collab_spike/schema/mine_sheet_commands.js
# -> tool/office_collab_spike/schema/sheet_commands.json
#    (sources / socket_events / dispatchers / commands[*].field_shapes / *_union)
```

逐条核对某命令原文（示例 `value`）：

```bash
python3 - <<'PY'
d=open('/tmp/spk/export_Office/server/sheet/node_modules/@ss/core.js',encoding='utf8').read()
i=d.find('cmd:"value"'); print(i); print(d[i-500:i+500])
PY
```
