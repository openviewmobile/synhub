// Office C′ 表格（Sheet）批 1 —— **命令词表 + section/字段覆盖登记**（schema 驱动的地基）。
//
// 为什么要有这个文件：`.osheet` 没有官方 JSON Schema（`docs/office-collab-schema-export.md`
// §B.4 明确"包内不存在命令 JSON Schema"）。我们从 Synology Office SPK 3.8.0-22711
// 的**未混淆语义** webpack 束里静态导出了全部命令字面量与 server `switch(cmd)`
// 分支（`tool/office_collab_spike/schema/mine_sheet_commands.js` →
// `sheet_commands.json` / `sheet_commands.md`），本文件把那份机读产物落成 Dart：
//
//   * `kOfficeSheetCommands`（**148** 条） = 101 条 `cmd:"…"` 字面量 ∪ 141 个
//     server `switch(.cmd){case"…"}` 标签（`sheet_commands.json.counts.known_union`）；
//   * `kOfficeSheetDispatchers`（**29** 条，含 file+字节偏移+表达式+case 数）
//     —— 注意：`docs/office-collab-schema-export.md` §B.2 写的是"15 个分发器"，
//     那是**旧的、只数了服务端**的口径；`sheet_commands.json` 实际导出 29 条
//     （服务端 14 + 客户端 `ui/dist/ui.sheet.js` 15）。本文件按机读产物 **29** 条，
//     并在 `docs/office-sheet-ui-1.md` 登记该口径差异。
//   * 每条命令带 `family / inClient / inServerLiteral / inServerSwitch / fieldKeys /
//     site`（file@offset），所以"渲染器认识哪些命令"是可核对的，不是拍脑袋。
//
// 生成方式（一次性、可复现；产物即本文件，脚本只写这一个新文件、不改任何既有文件）：
//   见 `docs/office-sheet-ui-1.md` §② 的 JSON→Dart 直译脚本（对
//   `sheet_commands.json` 逐条读 `cmd/family/in_client_ui_sheet/in_server_literal/
//   in_server_switch/field_shapes[].keys/sites[0]`）。
//
// **本批只读**：命令词表在批 1 只用于"诊断/降级计数"（`init` ack 的 `commands[]`
// 不回放，但任何出现过的命令名都要能被认出来；不认识的命令**不崩、不静默**）。
// 真正的 `set`/`value` 写入在下一批。
//
// 所有名字/字段/偏移都来自 `tool/office_collab_spike/schema/sheet_commands.json`；
// 该文件未在本批改动。

/// 一条命令词的静态证据。
class OfficeSheetCommandEvidence {
  const OfficeSheetCommandEvidence(
    this.family, {
    required this.inClient,
    required this.inServerLiteral,
    required this.inServerSwitch,
    required this.fieldKeys,
    required this.site,
  });

  /// 命令族（`sheet_commands.json` 的 `family`，如 `cell/block` / `filter`）。
  final String family;

  /// `ui/dist/ui.sheet.js` 里出现过 `cmd:"…"` 字面量。
  final bool inClient;

  /// 服务端束里出现过 `cmd:"…"` 字面量。
  final bool inServerLiteral;

  /// 服务端 `switch(.cmd){case"…"}` 里出现过该标签。
  final bool inServerSwitch;

  /// 已知字段键名（来自 `{cmd:"…", …}` 字面量工厂；不含 `cmd` 本身）。
  final List<String> fieldKeys;

  /// 首个证据位置 `文件@字节偏移`（空 = 只在 switch 标签出现，无字面量形状）。
  final String site;

  @override
  String toString() =>
      'OfficeSheetCommandEvidence($family, client: $inClient, '
      'literal: $inServerLiteral, switch: $inServerSwitch, fields: $fieldKeys)';
}

/// 一个命令分发器的静态证据（`switch(<expr>.cmd)` 的位置）。
class OfficeSheetDispatcherEvidence {
  const OfficeSheetDispatcherEvidence(
    this.file,
    this.offset,
    this.expression,
    this.caseCount,
  );

  final String file;
  final int offset;
  final String expression;
  final int caseCount;

  @override
  String toString() =>
      'OfficeSheetDispatcherEvidence($file@$offset, $expression, $caseCount)';
}

/// `.osheet` 服务端 `set` 事件的 ack 形状（`server/sheet/core/client.js :: _onSet`）。
///
/// `s(revIncoming, currentRev, status[, extra])`：
///   * `1` = 成功；`2` = **版本过期**（`!rev || rev !== currentRev + 1`）；`0` = 拒绝。
/// 批 1 不发 `set`，但下一批的写侧必须照这个三态对账。
const String kOfficeSheetSetAckShape = '(revIncoming, currentRev, status)';

/// `status` 三态（来源同上）。
const int kOfficeSheetSetStatusOk = 1;
const int kOfficeSheetSetStatusStaleRev = 2;
const int kOfficeSheetSetStatusRejected = 0;

/// `commentable` 用户也能发的 5 条评论命令白名单（`server/sheet/core/client.js` 原文）。
const Set<String> kOfficeSheetCommentOnlyCommands = <String>{
  'create_comment',
  'reply_comment',
  'edit_comment',
  'reopen_comment',
  'resolve_comment',
};

/// section ↔ BSON 字段名：`"@C_text/" + <section>`（`libsynoffice.so` 的
/// `std::string k = std::string("@C_") + key;`，见 `office-collab-schema-export.md` §C.3）。
///
/// 批 1 用它把 section 名写成**可核对的 BSON key**（降级消息里出现的就是这个形态）。
String officeSheetSectionKey(String section) => '@C_text/$section';

/// `.osheet` 的 section 覆盖登记（本批是只读渲染，登记 "画不画"）。
enum OfficeSheetSectionSupport {
  /// 本批真的用来渲染网格（`index` / `style` / `sh_N`）。
  rendered,

  /// 登记但不进网格（名称/评论/透视/语言包/外部链接等，本批不画）。
  structural,

  /// 名称已确证但本批不解释其内容（可见降级）。
  degraded,

  /// schema/词表都没有的 section 名 → 未知，计数但**不崩**。
  unknown,
}

/// section 名 → 覆盖登记。
class OfficeSheetSectionEvidence {
  const OfficeSheetSectionEvidence(this.support, this.evidence);

  final OfficeSheetSectionSupport support;
  final String evidence;
}

/// 固定 section 名的覆盖表。`sh_<n>` 走 [isOfficeSheetWorksheetSection]。
///
/// 依据：`office-collab-schema-export.md` §C（真实模板样本 `template/sheet/*/text.json`）
/// + 真机 `snapshot_sheet_pre.json`（本批夹具）。
const Map<String, OfficeSheetSectionEvidence>
kOfficeSheetSections = <String, OfficeSheetSectionEvidence>{
  // ---- 网格渲染真正用到的三个 ------------------------------------------------
  'index': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.rendered,
    '真机 snapshot_sheet_pre.json content.index（本批夹具）；'
    'office-collab-schema-export.md §C.3 表（gcVer/maxIndex/order/schemaVersion=5/'
    'sheets/ver）',
  ),
  'style': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.rendered,
    '真机 snapshot_sheet_pre.json content.style；§C.3 表（styles/fonts/fills/'
    'alignments/borders/numberFormats）',
  ),
  // ---- 登记但不进网格 --------------------------------------------------------
  'define': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.structural,
    '§C.3 表 getDefine()（defined names）；真机样本为空 {}',
  ),
  'comment': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.structural,
    '§C.3 表 getCommentStore()；真机样本为空 []',
  ),
  'protection': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.structural,
    '§C.3 表（RuleStore；非空或已存在才出现）',
  ),
  'externals': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.structural,
    '§C.3 表（ExternalManager；有外链才出现）',
  ),
  'pivotCaches': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.structural,
    '§C.3 表（serializeCaches；真机样本为空 []）',
  ),
  'pivotTables': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.structural,
    '§C.3 表（serializeTables；真机样本为空 []）',
  ),
  'file': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.structural,
    '§C.3 表 getFileList()；**唯一不加密的 section 之一**'
    '（仅 insert/remove_image 后出现）',
  ),
  'locale': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.structural,
    '§C.3 表；**唯一不加密的 section 之一**；真机样本 "en_US"',
  ),
  'locale_info': OfficeSheetSectionEvidence(
    OfficeSheetSectionSupport.structural,
    '§C.3 表（读侧 require(locale/data/<r>.json)）；真机样本带 pivot_table 文案表',
  ),
};

/// 是否是每张表的 section（`sh_1` / `sh_2` …）。
///
/// 依据：`server/sheet/worker_task/new_snapshot.js` 写死第一张表 `id:"sh_1"`，
/// 且 `snapshot.js :: generateSnapshot` 对每个 worksheet 写一个同名 section。
bool isOfficeSheetWorksheetSection(String name) => name.startsWith('sh_');

/// 查 section 覆盖度；`sh_N` 一律按 rendered，其它查表，查不到 = unknown。
OfficeSheetSectionEvidence officeSheetSectionEvidence(String name) {
  if (isOfficeSheetWorksheetSection(name)) {
    return const OfficeSheetSectionEvidence(
      OfficeSheetSectionSupport.rendered,
      '每张表一个 section（snapshot.js forAll → S[sheet]=getWorksheetGenerator；'
      '第一张固定 sh_1）',
    );
  }
  return kOfficeSheetSections[name] ??
      const OfficeSheetSectionEvidence(
        OfficeSheetSectionSupport.unknown,
        '词表/schema 导出里没有这个 section 名（未知 → 计数，不崩）',
      );
}

/// `index` section 的已知键（§C.3 表 + 真机样本）。
const Set<String> kOfficeSheetIndexKeys = <String>{
  'gcVer',
  'maxIndex',
  'order',
  'schemaVersion',
  'sheets',
  'ver',
  'maxPivotIndex',
};

/// `index.sheets[id]` 的已知键。
const Set<String> kOfficeSheetIndexSheetKeys = <String>{
  'deleted',
  'title',
  'tabColor',
  'hidden',
};

/// `sh_<n>` section 的已知键（§C.3 的 `getWorksheet` 原文 + 13 份真实样本）。
const Set<String> kOfficeSheetWorksheetKeys = <String>{
  'cells',
  'cfs',
  'colCount',
  'colSpans',
  'cols',
  'drawing',
  'filter',
  'fixedColumnLeft',
  'fixedRowTop',
  'global',
  'hyperlinks',
  'mergeCells',
  'notes',
  'rightToLeft',
  'rowCount',
  'rows',
  'validation',
};

/// 单元格的已知键（真实样本只有 `s`/`v`；`f` 是**推测**的旧字段名，仍登记）。
const Set<String> kOfficeSheetCellKeys = <String>{'s', 'v', 'f'};

/// `style` section 的已知键。
const Set<String> kOfficeSheetStyleKeys = <String>{
  'styles',
  'fonts',
  'fills',
  'alignments',
  'borders',
  'numberFormats',
};

/// `sh_N.rows[<r>]` 的已知键。
const Set<String> kOfficeSheetRowKeys = <String>{
  'hidden',
  's',
  'h',
  'outlineLevel',
  'collapse',
};

/// `sh_N.cols[<c>]` 的已知键。
const Set<String> kOfficeSheetColKeys = <String>{'w', 'hidden', 'outlineLevel'};

/// `sh_N.global` 的已知键。
const Set<String> kOfficeSheetGlobalKeys = <String>{'h', 'w'};

/// `style.alignments[]` 的已知键（`h` 水平 / `v` 垂直 / `w` 换行）。
const Set<String> kOfficeSheetAlignmentKeys = <String>{'h', 'v', 'w'};

/// 服务端 `worksheet.` 前缀分发器的 case 标签（`@ss/runtime.js@48960` 原文）。
const Set<String> kOfficeSheetWorksheetPrefixCases = <String>{
  'create',
  'create_pivot_table',
  'create_with_data',
  'dup',
  'undelete',
  'delete',
  'rename',
  'set_order',
  'set_hidden',
  'set_color',
};

/// 全部已知命令名（148；`kOfficeSheetCommands` 的 key 集合）。
Set<String> get kOfficeSheetCommandNames => kOfficeSheetCommands.keys.toSet();

/// 命令词表覆盖表：`cmd` → 证据。key 必须**逐字等于** `sheet_commands.json` 的
/// `counts.known_union`（由 `test/office_sheet_view_test.dart` S1 断言）。
const Map<String, OfficeSheetCommandEvidence> kOfficeSheetCommands =
    <String, OfficeSheetCommandEvidence>{
      '+': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: false,
        fieldKeys: <String>['idx'],
        site: 'ui/dist/ui.sheet.js@1005570',
      ),
      '-': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: false,
        fieldKeys: <String>['idx'],
        site: 'ui/dist/ui.sheet.js@1005669',
      ),
      '=': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: false,
        fieldKeys: <String>['idx', 'idx1'],
        site: 'ui/dist/ui.sheet.js@1005617',
      ),
      'add_internal_link': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'json'],
        site: 'server/sheet/node_modules/@ss/core.js@895881',
      ),
      'add_validation_range': OfficeSheetCommandEvidence(
        'data validation',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'validId', 'range'],
        site: 'ui/dist/ui.sheet.js@3523726',
      ),
      'adjust_chart': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'chartId', 'chartObj'],
        site: 'server/sheet/node_modules/@ss/core.js@699461',
      ),
      'alignment': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'autofill_number_format': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'range', 'fc', 'direction', 'source'],
        site: 'ui/dist/ui.sheet.js@3522635',
      ),
      'border': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'clear_comment': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['jsonArray'],
        site: 'server/sheet/node_modules/@ss/core.js@894442',
      ),
      'clear_range_data': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'range', 'source'],
        site: 'ui/dist/ui.sheet.js@3525386',
      ),
      'clear_range_related': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'range', 'source', 'clearMerge'],
        site: 'ui/dist/ui.sheet.js@3525470',
      ),
      'col_style': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'compound': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['actions'],
        site: 'server/sheet/node_modules/@ss/core.js@697531',
      ),
      'create': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'create_cf': OfficeSheetCommandEvidence(
        'conditional formatting',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'cf', 'index'],
        site: 'server/sheet/node_modules/@ss/core.js@893337',
      ),
      'create_col': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'create_comment': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['json'],
        site: 'server/sheet/node_modules/@ss/core.js@915495',
      ),
      'create_comment_local': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['author', 'config'],
        site: 'ui/dist/ui.sheet.js@3526331',
      ),
      'create_define': OfficeSheetCommandEvidence(
        'defined name',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['name', 'value', 'scope'],
        site: 'server/sheet/node_modules/@ss/core.js@894912',
      ),
      'create_filter': OfficeSheetCommandEvidence(
        'filter',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'filterId', 'range'],
        site: 'server/sheet/node_modules/@ss/core.js@907751',
      ),
      'create_filter_view': OfficeSheetCommandEvidence(
        'filter',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'filterId', 'range', 'name', 'isPrivate'],
        site: 'server/sheet/node_modules/@ss/core.js@909966',
      ),
      'create_pivot_table': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['table', 'cache'],
        site: 'server/sheet/node_modules/@ss/core.js@700498',
      ),
      'create_row': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'create_rule': OfficeSheetCommandEvidence(
        'conditional formatting',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['rule'],
        site: 'server/sheet/node_modules/@ss/core.js@896568',
      ),
      'create_validation': OfficeSheetCommandEvidence(
        'data validation',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'validation', 'range'],
        site: 'server/sheet/node_modules/@ss/core.js@892989',
      ),
      'create_with_data': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'delete': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'delete_pivot_table': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId'],
        site: 'server/sheet/node_modules/@ss/core.js@700562',
      ),
      'deselect': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id'],
        site: 'ui/dist/ui.sheet.js@3830904',
      ),
      'disable_filter': OfficeSheetCommandEvidence(
        'filter',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'disable_filter_view': OfficeSheetCommandEvidence(
        'filter',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'dup': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'edit': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: false,
        fieldKeys: <String>['client_id'],
        site: 'ui/dist/ui.sheet.js@2467891',
      ),
      'edit_comment': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['json'],
        site: 'server/sheet/node_modules/@ss/core.js@916513',
      ),
      'edit_comment_local': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['author', 'threadId', 'replyId', 'text'],
        site: 'server/sheet/node_modules/@ss/core.js@700226',
      ),
      'enable_filter': OfficeSheetCommandEvidence(
        'filter',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'enable_filter_view': OfficeSheetCommandEvidence(
        'filter',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'expand_filter_range': OfficeSheetCommandEvidence(
        'filter',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'range'],
        site: 'ui/dist/ui.sheet.js@3523582',
      ),
      'fill': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'fix_col': OfficeSheetCommandEvidence(
        'row/column',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'col'],
        site: 'server/sheet/node_modules/@ss/core.js@698531',
      ),
      'fix_row': OfficeSheetCommandEvidence(
        'row/column',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'row'],
        site: 'server/sheet/node_modules/@ss/core.js@698504',
      ),
      'font': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'format': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'changes', 'overwrite', 'source'],
        site: 'ui/dist/ui.sheet.js@3521979',
      ),
      'global_style': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>[
          'id',
          'type',
          'value',
          'revert',
          'rowChanges',
          'colChanges',
          'cellChanges',
        ],
        site: 'server/sheet/node_modules/@ss/core.js@698365',
      ),
      'group': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'type', 'from', 'to'],
        site: 'server/sheet/node_modules/@ss/core.js@896128',
      ),
      'group_pivot_field_item': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'changes'],
        site: 'server/sheet/node_modules/@ss/core.js@902558',
      ),
      'hide_cols': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'hide_rows': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'insert_chart': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'chartId', 'position', 'chartObj'],
        site: 'server/sheet/node_modules/@ss/core.js@894049',
      ),
      'insert_col': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'insert_image': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'imageId', 'position'],
        site: 'server/sheet/node_modules/@ss/core.js@893659',
      ),
      'insert_pivot_data_field': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'fieldId', 'position', 'json'],
        site: 'server/sheet/node_modules/@ss/core.js@700978',
      ),
      'insert_row': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'merge': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'modify_define': OfficeSheetCommandEvidence(
        'defined name',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['name', 'scope', 'change'],
        site: 'server/sheet/node_modules/@ss/core.js@700315',
      ),
      'modify_drawings_by_insert': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'type', 'index', 'amount'],
        site: 'ui/dist/ui.sheet.js@3524879',
      ),
      'modify_drawings_by_move': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[
          'id',
          'type',
          'start',
          'amount1',
          'amount2',
          'isBackward',
        ],
        site: 'ui/dist/ui.sheet.js@3525063',
      ),
      'modify_drawings_by_remove': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'type', 'index', 'amount'],
        site: 'ui/dist/ui.sheet.js@3524969',
      ),
      'move_col': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'move_formula_range': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>[
          'id',
          'srcRange',
          'targetSheetId',
          'targetRange',
          'keepMovingPart',
          'applyData',
        ],
        site: 'server/sheet/node_modules/@ss/core.js@699724',
      ),
      'move_pivot_axis_field': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>[
          'tableId',
          'fieldId',
          'axis',
          'position',
          'coordShift',
          'filterUpdate',
        ],
        site: 'server/sheet/node_modules/@ss/core.js@700855',
      ),
      'move_pivot_data_field': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'dataFieldId', 'position'],
        site: 'server/sheet/node_modules/@ss/core.js@701073',
      ),
      'move_pivot_table': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'sheetId', 'coord'],
        site: 'server/sheet/node_modules/@ss/core.js@700690',
      ),
      'move_range': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'srcRange', 'targetRange', 'clearMerge'],
        site: 'ui/dist/ui.sheet.js@3525279',
      ),
      'move_row': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'note': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'changes'],
        site: 'server/sheet/node_modules/@ss/core.js@697692',
      ),
      'offline': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: true,
        inServerSwitch: false,
        fieldKeys: <String>['client_id'],
        site: 'server/sheet/core/client.js@2382',
      ),
      'online': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: true,
        inServerSwitch: false,
        fieldKeys: <String>[],
        site: 'server/sheet/core/client.js@2313',
      ),
      'paste_autofill_data': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'range', 'data', 'expandFilter', 'source'],
        site: 'ui/dist/ui.sheet.js@3522520',
      ),
      'paste_comment': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['jsonArray'],
        site: 'server/sheet/node_modules/@ss/core.js@894513',
      ),
      'pivot_compound': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['actions'],
        site: 'server/sheet/node_modules/@ss/core.js@700442',
      ),
      'populate_autofill_data': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'range', 'data', 'direction', 'source'],
        site: 'ui/dist/ui.sheet.js@3522405',
      ),
      'quotePrefix': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'quoteprefix': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'remove_all_validation': OfficeSheetCommandEvidence(
        'data validation',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'range'],
        site: 'ui/dist/ui.sheet.js@3523962',
      ),
      'remove_cf': OfficeSheetCommandEvidence(
        'conditional formatting',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'cfId'],
        site: 'server/sheet/node_modules/@ss/core.js@893233',
      ),
      'remove_chart': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'chartId'],
        site: 'server/sheet/node_modules/@ss/core.js@893919',
      ),
      'remove_col': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'remove_define': OfficeSheetCommandEvidence(
        'defined name',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['name', 'scope'],
        site: 'server/sheet/node_modules/@ss/core.js@894805',
      ),
      'remove_external_links': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['linkIds'],
        site: 'server/sheet/node_modules/@ss/core.js@923665',
      ),
      'remove_formula_range': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'srcRange', 'applyData'],
        site: 'server/sheet/node_modules/@ss/core.js@699859',
      ),
      'remove_image': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'imageId'],
        site: 'server/sheet/node_modules/@ss/core.js@893552',
      ),
      'remove_internal_link': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'linkId'],
        site: 'server/sheet/node_modules/@ss/core.js@895785',
      ),
      'remove_pivot_data_field': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'dataFieldId'],
        site: 'server/sheet/node_modules/@ss/core.js@701161',
      ),
      'remove_row': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'remove_rule': OfficeSheetCommandEvidence(
        'conditional formatting',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['ruleId'],
        site: 'server/sheet/node_modules/@ss/core.js@896492',
      ),
      'remove_validation': OfficeSheetCommandEvidence(
        'data validation',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'validId', 'range'],
        site: 'server/sheet/node_modules/@ss/core.js@892845',
      ),
      'rename': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'reopen_comment': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['json'],
        site: 'server/sheet/node_modules/@ss/core.js@915865',
      ),
      'reopen_comment_local': OfficeSheetCommandEvidence(
        'comment',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'reply_comment': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['json'],
        site: 'server/sheet/node_modules/@ss/core.js@915699',
      ),
      'reply_comment_local': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['author', 'config'],
        site: 'ui/dist/ui.sheet.js@3526401',
      ),
      'resize_chart': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'chartId', 'position'],
        site: 'server/sheet/node_modules/@ss/core.js@699389',
      ),
      'resize_col': OfficeSheetCommandEvidence(
        'row/column',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'from', 'to', 'width'],
        site: 'server/sheet/node_modules/@ss/core.js@697804',
      ),
      'resize_image': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'imageId', 'position'],
        site: 'server/sheet/node_modules/@ss/core.js@699317',
      ),
      'resize_row': OfficeSheetCommandEvidence(
        'row/column',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'from', 'to', 'height'],
        site: 'server/sheet/node_modules/@ss/core.js@697759',
      ),
      'resolve_comment': OfficeSheetCommandEvidence(
        'comment',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['json'],
        site: 'server/sheet/node_modules/@ss/core.js@916033',
      ),
      'resolve_comment_local': OfficeSheetCommandEvidence(
        'comment',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'row_style': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'select': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_active_filter_view': OfficeSheetCommandEvidence(
        'filter',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'filterId'],
        site: 'server/sheet/node_modules/@ss/core.js@699094',
      ),
      'set_chart_config': OfficeSheetCommandEvidence(
        'drawing/chart',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'chartId', 'name', 'args'],
        site: 'server/sheet/node_modules/@ss/core.js@699535',
      ),
      'set_collapse': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'type', 'index', 'collapse'],
        site: 'server/sheet/node_modules/@ss/core.js@700087',
      ),
      'set_color': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_filter': OfficeSheetCommandEvidence(
        'filter',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_filter_view_condition': OfficeSheetCommandEvidence(
        'filter',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_hidden': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_order': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_pivot_data_field_attr': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'dataFieldId', 'changes'],
        site: 'server/sheet/node_modules/@ss/core.js@701326',
      ),
      'set_pivot_field_attr': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'fieldId', 'changes'],
        site: 'server/sheet/node_modules/@ss/core.js@701242',
      ),
      'set_pivot_field_datetime_group': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>[
          'tableId',
          'fieldId',
          'changes',
          'positions',
          'autoFold',
          'itemsInfo',
        ],
        site: 'server/sheet/node_modules/@ss/core.js@701625',
      ),
      'set_pivot_field_item_caption': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_pivot_field_item_folded': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_pivot_field_item_hidden': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_pivot_field_item_order': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'set_pivot_field_number_group': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'fieldId', 'changes', 'itemsInfo'],
        site: 'server/sheet/node_modules/@ss/core.js@701512',
      ),
      'set_pivot_table_caption': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'key', 'value'],
        site: 'server/sheet/node_modules/@ss/core.js@700768',
      ),
      'set_worksheet_rtl': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'rtl'],
        site: 'server/sheet/node_modules/@ss/core.js@700162',
      ),
      'show_cols': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'show_rows': OfficeSheetCommandEvidence(
        'row/column',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'sort': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'rowOrder', 'range', 'applyData'],
        site: 'server/sheet/node_modules/@ss/core.js@699239',
      ),
      'undelete': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'ungroup': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'type', 'from', 'to'],
        site: 'server/sheet/node_modules/@ss/core.js@896245',
      ),
      'ungroup_pivot_field_item': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['tableId', 'changes'],
        site: 'server/sheet/node_modules/@ss/core.js@902733',
      ),
      'unmerge': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'unmerge_overlaps': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'range'],
        site: 'ui/dist/ui.sheet.js@3521904',
      ),
      'update': OfficeSheetCommandEvidence(
        'other',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'update_cf_ranges': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'cfId', 'ranges'],
        site: 'server/sheet/node_modules/@ss/core.js@699166',
      ),
      'update_external_links': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['entry'],
        site: 'server/sheet/node_modules/@ss/core.js@923470',
      ),
      'update_filter_range': OfficeSheetCommandEvidence(
        'filter',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'update_filter_view_name': OfficeSheetCommandEvidence(
        'filter',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'filterId', 'name'],
        site: 'server/sheet/node_modules/@ss/core.js@699016',
      ),
      'update_filter_view_range': OfficeSheetCommandEvidence(
        'filter',
        inClient: false,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[],
        site: '',
      ),
      'update_group': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'type', 'from', 'levels'],
        site: 'server/sheet/node_modules/@ss/core.js@700011',
      ),
      'update_internal_link': OfficeSheetCommandEvidence(
        'other',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'json'],
        site: 'server/sheet/node_modules/@ss/core.js@699943',
      ),
      'update_pivot_table': OfficeSheetCommandEvidence(
        'pivot table',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['table', 'cache'],
        site: 'server/sheet/node_modules/@ss/core.js@700622',
      ),
      'update_rule': OfficeSheetCommandEvidence(
        'conditional formatting',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['ruleId', 'props'],
        site: 'server/sheet/node_modules/@ss/core.js@700384',
      ),
      'value': OfficeSheetCommandEvidence(
        'cell/block',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'changes', 'source', 'nfRefs', 'nfs'],
        site: 'server/sheet/node_modules/@ss/core.js@697583',
      ),
      'worksheet.create': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: true,
        inServerSwitch: true,
        fieldKeys: <String>[
          'titleTpl',
          'pos',
          'id',
          'title',
          'tabColor',
          'content',
        ],
        site: 'server/sheet/node_modules/@ss/runtime.js@49543',
      ),
      'worksheet.create_pivot_table': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['pos', 'titleTpl', 'cacheJson', 'tableJson'],
        site: 'ui/dist/ui.sheet.js@3529191',
      ),
      'worksheet.create_with_data': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: false,
        fieldKeys: <String>['titleTpl', 'tabColor', 'content', 'rev', 'pos'],
        site: 'ui/dist/ui.sheet.js@2488609',
      ),
      'worksheet.delete': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'includeSnapshotData'],
        site: 'ui/dist/ui.sheet.js@3529758',
      ),
      'worksheet.dup': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>[
          'id',
          'pos',
          'title',
          'pivotTableIdMapping',
          'newId',
        ],
        site: 'ui/dist/ui.sheet.js@3529490',
      ),
      'worksheet.rename': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'title'],
        site: 'ui/dist/ui.sheet.js@3529833',
      ),
      'worksheet.set_color': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'color'],
        site: 'ui/dist/ui.sheet.js@3530017',
      ),
      'worksheet.set_hidden': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'hidden'],
        site: 'ui/dist/ui.sheet.js@3529951',
      ),
      'worksheet.set_order': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['order'],
        site: 'ui/dist/ui.sheet.js@3529892',
      ),
      'worksheet.undelete': OfficeSheetCommandEvidence(
        'worksheet lifecycle',
        inClient: true,
        inServerLiteral: false,
        inServerSwitch: true,
        fieldKeys: <String>['id', 'pos', 'info', 'content'],
        site: 'ui/dist/ui.sheet.js@3529680',
      ),
    };

/// 已确证的 29 个命令分发器（file / 字节偏移 / 表达式 / case 数）。
const List<OfficeSheetDispatcherEvidence>
kOfficeSheetDispatchers = <OfficeSheetDispatcherEvidence>[
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    486697,
    'e.cmd',
    14,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    630760,
    'e.cmd',
    76,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    636815,
    'e.cmd',
    49,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    637800,
    'e.cmd',
    37,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    638124,
    'e.cmd',
    34,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    638352,
    'e.cmd',
    31,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    638636,
    'e.cmd',
    29,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    702883,
    't.cmd',
    37,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    936362,
    'r.cmd',
    19,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/core.js',
    941480,
    'e.cmd',
    19,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/runtime.js',
    39149,
    't.cmd',
    37,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/node_modules/@ss/runtime.js',
    45943,
    'e.cmd',
    19,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/core/client.js',
    1423,
    'e.cmd',
    6,
  ),
  OfficeSheetDispatcherEvidence(
    'server/sheet/core/client.js',
    1898,
    'e.cmd',
    3,
  ),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 1005794, 'x.cmd', 3),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 2467976, 'e.cmd', 6),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3462926, 'e.cmd', 76),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3469016, 'e.cmd', 49),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3470001, 'e.cmd', 37),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3470325, 'e.cmd', 34),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3470553, 'e.cmd', 31),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3470837, 'e.cmd', 29),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3531201, 't.cmd', 37),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3712637, 'i.cmd', 19),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3717677, 'e.cmd', 19),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 3892368, 't.cmd', 19),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 4099031, 'e.cmd', 12),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 4387179, 't.cmd', 14),
  OfficeSheetDispatcherEvidence('ui/dist/ui.sheet.js', 4387727, 't.cmd', 14),
];

/// 命令名是否在导出的 148 词表里。
bool isOfficeSheetCommandKnown(String cmd) =>
    kOfficeSheetCommands.containsKey(cmd);

/// `init` ack 里的 `commands[]` 命令名（不认识的返回 null）。
String? officeSheetCommandNameOf(Object? command) {
  if (command is Map) {
    final cmd = command['cmd'];
    if (cmd is String) return cmd;
  }
  return null;
}

/// 已确证的服务端 / 客户端命令词表并集大小（自证常量，防手改漏）。
const int kOfficeSheetCommandWordCount = 148;

/// 已确证的分发器条数（`sheet_commands.json.dispatchers`）。
const int kOfficeSheetDispatcherCount = 29;
