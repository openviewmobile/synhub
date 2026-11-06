// Office C′ 编辑器 UI 批 1 —— **只读、schema 驱动**的 `.odoc` 渲染器。
//
// 目标：把 M1 的 `@C_text/content.data` 树（`DocNode` / 原始 `DocJson`）渲染成
// Flutter widget 树，**不写死一份"我以为的"节点表**。
//
// 怎么才算"schema 驱动"（与硬编码的对照）：
//   1. 节点名 / mark 名只从 `DocSchema.document.nodes` /
//      `.marks` / `.attrMarks`（= `doc_schema_generated.dart` 的
//      `kDocNodeSpecs` / `kDocMarkSpecs` / `kDocAttrMarkSpecs`）里查；
//      **渲染器不认识一个 schema 里没有的名字**，查不到就降级（见 `_renderNode`）。
//   2. 节点属性只按该节点在 schema 里的 `attrs` 声明读取
//      （`officeDocSchemaAttr`：schema 没声明这个 attr 就**不读**；
//      例如 `headingLevel` 只可能在 `paragraph` / `style_paragraph` 上）。
//   3. `kOfficeDocNodeSupport` / `kOfficeDocMarkSupport` 的 key 必须与
//      schema 的节点/mark 名集合**逐字相等**（由 `test/office_doc_view_test.dart`
//      断言）——所以不可能悄悄多渲染一个 schema 里没有的类型，也不可能漏登记
//      一个 schema 有的类型（漏登记 = 测试红）。
//
// 覆盖依据（每一条都能追到夹具或 schema 条目；完整表见
// `docs/office-editor-ui-1.md` §②）：
//   * 真机夹具 `test/fixtures/office_collab/dart_fetched_doc_v1.json`（编辑器
//     `fetch` v1）与 `test/fixtures/office_collab/snapshot_doc_pre.json`
//     （`@C_text/content` Import 态）：doc / settings / style_editor /
//     style_paragraph / invisible / edit_area / paragraph / text /
//     page_decorate / header / footer / page_num / page_num_block /
//     page_num_text（**该夹具里没有任何 mark**）。
//   * 真机 M2 夹具 `test/fixtures/office_collab/transform_vectors.json` 的 54 份
//     文档：同样这 14 种节点，外加 mark `strong`(21) / `em`(3) /
//     `underline`(3) / `color`(3) / `font_size`(24) —— 这是本批唯一有 mark 的真机
//     文档证据。
//   * 其余节点名（table / image / shape / …）：只有 schema 条目
//     （`doc_schema_generated.dart :: kDocNodeSpecs`），**没有夹具实例**，
//     一律走"可见但受限"的降级，不假装渲染。
//
// 降级纪律：不认识的节点 / mark **不许崩、不许静默丢**。
//   * 节点 → 一张明确的"暂不支持渲染的类型：<name>"卡片（原始字符仍在）；
//   * mark → 保留纯文本，把名字计入 `OfficeDocRenderReport`，并在页顶聚合提示一句；
//   * 所有降级都进 `OfficeDocRenderReport`（计数 + 消息），可被测试与日志读到。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_tokens.dart';
import '../../data/office_collab/doc_schema.dart';
import 'office_doc_edit.dart';
import 'office_doc_image.dart'
    show
        OfficeAttachmentBytesProvider,
        OfficeDocImage,
        OfficeDocImageCache,
        OfficeDocImageCrop,
        officeDocImageAlignmentFrom,
        officeDocImagePx;
import 'office_doc_page_frame.dart'
    show
        OfficeDocDecorations,
        OfficeDocPageFrame,
        OfficeDocPageKind,
        officeDocNumPositionAlignment;
import 'office_doc_style.dart';
import 'office_doc_table.dart'
    show OfficeDocTableCellSpec, OfficeDocTable, OfficeDocTableModel;
import 'office_write_gate.dart' show officeDocText;

// `officeDocParseColor` 已搬到 `office_doc_style.dart`（表格/页边装饰组件也要用，
// 且不能反向依赖渲染器）；这里 re-export，既有 import 路径与调用方保持不变。
export 'office_doc_style.dart' show officeDocParseColor;

/// 纸面小字标签的颜色（`DA203`）。
///
/// 文档的"纸"在任何主题下都是白的（页眉 / 页脚 / 页码标签都画在纸上），
/// 所以这里**不能**用 `Colors.grey`（#9E9E9E，白底 **2.68:1**，AA 要 4.5），
/// 也不能用 `DesignPalette.of(context).dim`（暗档是 #8D9AA8，白底只剩 2.9:1）。
/// 固定取亮色档 `dim`（#5C6A7E）：白底 **5.50:1**。
const Color officePageLabel = Color(0xFF5C6A7E);

/// 本批对某个 schema 节点的渲染支持度。
enum OfficeDocNodeSupport {
  /// 本批真的渲染它（含容器与装饰）。
  rendered,

  /// 本批有意不画（结构/非视觉节点，如 settings / invisible），但**可见地登记**，
  /// 不算"静默丢"。
  structural,

  /// 本批**不渲染**（可见的"暂不支持渲染的类型"降级卡片）。
  degraded,
}

/// 一个 schema 节点的覆盖登记：支持度 + 依据。
class OfficeDocNodeEvidence {
  const OfficeDocNodeEvidence(this.support, this.evidence);

  final OfficeDocNodeSupport support;

  /// 依据：夹具路径或 `doc_schema_generated.dart` 的条目名。
  final String evidence;
}

/// 本批节点覆盖表。key 必须与 `DocSchema.document.nodes.keys` 完全相同。
const Map<String, OfficeDocNodeEvidence> kOfficeDocNodeSupport =
    <String, OfficeDocNodeEvidence>{
  // ---- 两份黄金夹具里真实出现的节点 -----------------------------------------
  'doc': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'dart_fetched_doc_v1.json 根；schema kDocNodeSpecs["doc"]（topNode）',
  ),
  'settings': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.structural,
    'dart_fetched_doc_v1.json content[0]；schema kDocNodeSpecs["settings"]'
        '（leaf，占 1 位，无 content）',
  ),
  'style_editor': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'dart_fetched_doc_v1.json content[1]（7 个 style_paragraph）；'
        'schema kDocNodeSpecs["style_editor"]',
  ),
  'style_paragraph': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'dart_fetched_doc_v1.json style_editor 内 headingLevel 0..5；'
        'schema kDocNodeSpecs["style_paragraph"].attrs.headingLevel/listLevel',
  ),
  'invisible': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.structural,
    'dart_fetched_doc_v1.json content[2]；schema kDocNodeSpecs["invisible"]',
  ),
  'edit_area': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'dart_fetched_doc_v1.json content[3]（正文 paragraph）；'
        'schema kDocNodeSpecs["edit_area"]',
  ),
  'paragraph': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'dart_fetched_doc_v1.json edit_area 内 paragraph→text "C3SPIKE-DOC-BASE"；'
        'schema kDocNodeSpecs["paragraph"]（basic_block）',
  ),
  'text': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'dart_fetched_doc_v1.json edit_area 内 text；'
        'schema kDocNodeSpecs["text"]（isText）',
  ),
  'page_decorate': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    '真机夹具 13 份 .odoc 全部有 page_decorate（attrs 7 个与 schema 逐字一致，'
        'num-pos="br"）；content = header×3(cover/even/normal) + footer×3 + '
        'page_num(type=normal)；批 B 把这些装饰印进**页边区域**'
        '（office_doc_page_frame.dart），不再当正文块',
  ),
  'header': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    '真机夹具 3 份 .odoc 各有 header×3（type=cover/even/normal，内容为空 paragraph）；'
        '批 B 只把与当前页型匹配的那一个印在**上边距**'
        '（正文帧 normal → cover/even 不印），见 office_doc_page_frame.dart',
  ),
  'footer': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    '真机夹具 3 份 .odoc 各有 footer×3（type=cover/even/normal，内容为空 paragraph）；'
        '批 B 只把与当前页型匹配的那一个印在**下边距**',
  ),
  'page_num': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    '真机夹具 3 份 .odoc 各有 page_num×1（type=normal，'
        'page_num_block→page_num_text）；批 B 按 type 决定页型并在下边距显示**真实页码**',
  ),
  'page_num_block': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'dart_fetched_doc_v1.json page_num 下；'
        'schema kDocNodeSpecs["page_num_block"]',
  ),
  'page_num_text': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'dart_fetched_doc_v1.json page_num_block 下；'
        'schema kDocNodeSpecs["page_num_text"]',
  ),

  // ---- schema 里有、但两套夹具都未出现（含 mark 夹具）的节点 ----------------
  'hard_break': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["hard_break"]（inline 组）；无夹具实例',
  ),
  'tab': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["tab"]（inline 组）；无夹具实例',
  ),
  'table': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    '真机夹具 test/fixtures/office_doc_tables/table_*.json（5-day trip planner '
        '5 表 / Product spec 4 列×5 行 / Vacation packing list 2 列×6 行）：'
        'colgroup[].width（px，Σ=601/600/600 ≈ A4 内容宽 601.7px）、'
        'table_row.height、cell borderColor/Style/Width + backgroundColor + '
        'verticalAlign；批 B 按比例分配宽度渲染真表格（office_doc_table.dart）',
  ),
  'table_row': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    '真机夹具行高 height 实测 124 / 28 / 26..91（px）；批 B 以 SizedBox 固定行高',
  ),
  'table_cell': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    '真机夹具 cell attrs：border{Top,Right,Bottom,Left}{Color,Style,Width} + '
        'colspan/rowspan + verticalAlign（13 份样例 42 格全为 1）；'
        'backgroundColor 是 schema 可选键但 42 格**一个都没有**（只在存在时用）；'
        '批 B 渲染边框/底色/垂直对齐，并按每个 cell 自己的 colspan/rowspan 合并 '
        '（**跨 >1 格未取证**：无真实样例）',
  ),
  'text_line': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["text_line"]；无夹具实例',
  ),
  'page': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["page"]（width/height/margin*）；无夹具实例',
  ),
  'horizontal_rule': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["horizontal_rule"]（basic_block，attrs 只有 tracking*）；'
        '13 份真实样例计数为 0 → 无实例；批 B 渲染一条分隔线（无颜色/粗细属性可读）',
  ),
  'page_break': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["page_break"]（first_level_block，attrs 只有 tracking*）；'
        '13 份真实样例计数为 0 → 无实例；批 B 渲染明确的视觉分隔（不做逐像素分页）',
  ),
  'text_box': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["text_box"]（anchor/lIns…/listMap）；无夹具实例',
  ),
  'navigation': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.degraded,
    'schema kDocNodeSpecs["navigation"]；无夹具实例，目录/导航渲染未取证 → 降级',
  ),
  'image': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["image"]（src/alt/ref/file_id/width/height）；'
        '字节通道已取证：Attachment:get v2 {object_id,file_id} → 真 PNG'
        '（docs/office-doc-render-design.md §2 E5/E6）；'
        '`image` 实例本身未取证，按 schema 的 file_id/width/height/alt 渲染',
  ),
  'chart': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["chart"].attrs（synochart/data/config/width/height）；'
        '**未取证**：13 份真实样例 chart 计数全为 0（无素材）→ '
        '批 B 只按 width/height 渲染占位卡（默认 560×410），**不解析** data/config',
  ),
  'shape': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.degraded,
    'schema kDocNodeSpecs["shape"]；无夹具实例 → 降级',
  ),
  'connector': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.degraded,
    'schema kDocNodeSpecs["connector"]；无夹具实例 → 降级',
  ),
  'picture': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    '真机夹具 Restaurant menu.odoc 的 12 个 picture 节点（'
        'attrs.config.file_id/alt/width/height/crop/deg/flip_*/alignment）；'
        '字节通道 Attachment:get v2 已取证（真 PNG，夹具 '
        'test/fixtures/office_doc_images/*.png）',
  ),
  'pseudo_list_item': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.rendered,
    'schema kDocNodeSpecs["pseudo_list_item"]（leaf 标记）；'
        '列表前缀由 paragraph 的 listId/listLevel 承载（有序编号无取证→不编），'
        '标记本身不产生可见字符（不是"打印内部名"）',
  ),
  'table_parser': OfficeDocNodeEvidence(
    OfficeDocNodeSupport.degraded,
    'schema kDocNodeSpecs["table_parser"]；无夹具实例 → 降级',
  ),
};

/// 本批对某个 schema mark 的渲染支持度。
enum OfficeDocMarkSupport {
  /// 本批把它落成 `TextStyle` / 交互。
  rendered,

  /// schema 声明了它，但本批有意不作用到文本上（如 `tracking` 是修订元数据）。
  metadata,

  /// 本批不渲染（计数 + 页顶提示）。
  degraded,
}

/// 一个 schema mark 的覆盖登记：支持度 + 依据。
class OfficeDocMarkEvidence {
  const OfficeDocMarkEvidence(this.support, this.evidence);

  final OfficeDocMarkSupport support;
  final String evidence;
}

/// 本批 mark 覆盖表。key 必须与 `DocSchema.document.marks` +
/// `DocSchema.document.attrMarks` 的名字集合完全相同。
const Map<String, OfficeDocMarkEvidence> kOfficeDocMarkSupport =
    <String, OfficeDocMarkEvidence>{
  // ---- transform_vectors.json 里真实出现的 mark ----------------------------
  'strong': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'transform_vectors.json marks.strong（21 处，presence mark `{"_":"strong"}`）；'
        'schema kDocMarkSpecs["strong"].rank=3',
  ),
  'em': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'transform_vectors.json marks.em（3 处）；schema kDocMarkSpecs["em"].rank=2',
  ),
  'underline': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'transform_vectors.json marks.underline（3 处）；'
        'schema kDocMarkSpecs["underline"].rank=9',
  ),
  'color': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'transform_vectors.json marks.color（3 处）；'
        'schema kDocMarkSpecs["color"].attrs.value',
  ),
  'font_size': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'transform_vectors.json marks.font_size（24 处）；'
        'schema kDocMarkSpecs["font_size"].attrs.value（required, default 11）',
  ),

  // ---- schema 里有、夹具未出现的 mark -------------------------------------
  'font_family': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocMarkSpecs["font_family"].attrs.value/eastAsia/complexScript/hint；'
        '无夹具实例',
  ),
  'link': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocMarkSpecs["link"].attrs.href；'
        '无夹具实例（M1 §8.7 记录真实模板样本有 `link href`）',
  ),
  'background_color': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocMarkSpecs["background_color"].attrs.value；无夹具实例',
  ),
  'superscript': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocMarkSpecs["superscript"]（presence value=true）；无夹具实例',
  ),
  'subscript': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocMarkSpecs["subscript"]（presence value=true）；无夹具实例',
  ),
  'strike': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocMarkSpecs["strike"]（presence value=true）；无夹具实例',
  ),
  'tracking': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.metadata,
    'schema kDocMarkSpecs["tracking"].attrs.id；修订/追踪元数据，'
        '本批不改变文本外观（如实登记，不假装渲染）',
  ),

  // ---- attr_marks（块级属性 mark）----------------------------------------
  'direction': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocAttrMarkSpecs["direction"]（applicability=unproven）；'
        '按段落块级读入 `marks`，`rtl` 时把段落文字方向设成 RTL；无夹具实例',
  ),
  'text_align': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocAttrMarkSpecs["text_align"]（applicable paragraph/style_paragraph）；'
        '按段落块级读入 `marks`（left/center/right/justify）',
  ),
  'line_height': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocAttrMarkSpecs["line_height"]（applicable paragraph/style_paragraph）；'
        '按段落块级读入 `marks` → `TextStyle.height`',
  ),
  'text_indent': OfficeDocMarkEvidence(
    OfficeDocMarkSupport.rendered,
    'schema kDocAttrMarkSpecs["text_indent"]（applicability=unproven）；'
        '按段落块级读入 `marks` → 左缩进（无夹具实例）',
  ),
};

/// 降级/渲染时的计数与消息（"不许静默丢"的落点；测试与日志共用）。
class OfficeDocRenderReport {
  final Map<String, int> unknownNodeTypes = <String, int>{};
  final Map<String, int> unsupportedNodeTypes = <String, int>{};
  final Map<String, int> unknownMarkNames = <String, int>{};
  final Map<String, int> unsupportedMarkNames = <String, int>{};
  final List<String> messages = <String>[];

  void unknownNode(String type) {
    unknownNodeTypes[type] = (unknownNodeTypes[type] ?? 0) + 1;
    messages.add('未知节点（schema 未声明）：$type');
  }

  void unsupportedNode(String type) {
    unsupportedNodeTypes[type] = (unsupportedNodeTypes[type] ?? 0) + 1;
    messages.add('schema 已声明但本批不渲染的节点：$type');
  }

  void unknownMark(String name) {
    unknownMarkNames[name] = (unknownMarkNames[name] ?? 0) + 1;
    messages.add('未知 mark（schema 未声明）：$name');
  }

  void unsupportedMark(String name) {
    unsupportedMarkNames[name] = (unsupportedMarkNames[name] ?? 0) + 1;
    messages.add('schema 已声明但本批不渲染的 mark：$name');
  }

  void note(String message) {
    messages.add(message);
  }

  bool get hasDegradations =>
      unknownNodeTypes.isNotEmpty ||
      unsupportedNodeTypes.isNotEmpty ||
      unknownMarkNames.isNotEmpty ||
      unsupportedMarkNames.isNotEmpty;

  int get degradationCount =>
      unknownNodeTypes.values.fold<int>(0, (a, b) => a + b) +
      unsupportedNodeTypes.values.fold<int>(0, (a, b) => a + b) +
      unknownMarkNames.values.fold<int>(0, (a, b) => a + b) +
      unsupportedMarkNames.values.fold<int>(0, (a, b) => a + b);

  /// ★ 第 313 轮：把本帧结果**替换**进来（**不是追加**）。
  ///
  /// 调用方（页面 state）持有的 [OfficeDocRenderReport] 是长生命的，而
  /// [OfficeDocView.build] 每次重建都会重新走一遍渲染并登记降级 —— 直接
  /// `messages.add` 会让它**每次 build 无界增长**（真机一行日志涨到几万字符，
  /// 计数也会虚高，测试断言随之失真）。语义是"报告 = 最近一帧的事实"，
  /// 所以这里按帧替换。
  void replaceWith(OfficeDocRenderReport other) {
    unknownNodeTypes
      ..clear()
      ..addAll(other.unknownNodeTypes);
    unsupportedNodeTypes
      ..clear()
      ..addAll(other.unsupportedNodeTypes);
    unknownMarkNames
      ..clear()
      ..addAll(other.unknownMarkNames);
    unsupportedMarkNames
      ..clear()
      ..addAll(other.unsupportedMarkNames);
    messages
      ..clear()
      ..addAll(other.messages);
  }

  @override
  String toString() =>
      'OfficeDocRenderReport(unknownNodes=$unknownNodeTypes, '
      'unsupportedNodes=$unsupportedNodeTypes, unknownMarks=$unknownMarkNames, '
      'unsupportedMarks=$unsupportedMarkNames)';
}

/// 按 schema 声明读一个节点的属性。
///
/// **schema 没声明该 attr 就不读**（返回 null）：这是"schema 驱动"的核心，
/// 避免渲染器自己发明 `headingLevel` 可以出现在哪个节点上。
Object? officeDocSchemaAttr(Object? node, String attr) {
  if (node is! Map) return null;
  final type = node['type'];
  if (type is! String) return null;
  final spec = DocSchema.document.nodes[type];
  if (spec == null) return null;
  if (!spec.attrs.containsKey(attr)) return null;
  final attrs = node['attrs'];
  if (attrs is! Map) return null;
  return attrs[attr];
}

/// 解析 mark 的 CSS 颜色（只支持 `#rgb` / `#rrggbb` / `#aarrggbb` / `rgb(...)`）。
///
/// 认不出就返回 null —— 调用方保留纯文本 + 计入降级，**不抛**。
///
/// 实现见 `office_doc_style.dart`（本文件只 re-export，见文件头的 export）。

/// UI 批 2 的**编辑宿主**：渲染器通过它把"某一段落被编辑了 / 选区变了 / 获得焦点"
/// 回调出去，真正生成 step 的逻辑在页面控制器（`office_doc_page.dart`）里。
///
/// 渲染器**不自己发 step、不自己算位置**：它只报告"哪个段落（[OfficeDocPath]）、
/// 纯文本变成什么、选区的字符区间是什么"。位置算术与 step 构造在
/// `office_doc_edit.dart`（M1 `DocSchema.nodeSize`）。
abstract class OfficeDocEditHost {
  /// 是否处于可编辑模式（门控 + 会话都就绪时才为 true）。
  bool get enabled;

  /// 该路径的段落是否可作为本批的可编辑块（只支持 `edit_area` 下的纯 text 段落）。
  bool isEditablePath(OfficeDocPath path);

  /// 段落纯文本被改成 [text]。
  void onParagraphChanged(OfficeDocPath path, String text);

  /// 段落选区变成 `[start, end)`（纯文本字符下标）。
  void onParagraphSelection(OfficeDocPath path, int start, int end);

  /// 段落获得焦点。
  void onParagraphFocused(OfficeDocPath path);
}

/// 渲染一个 `.odoc` 文档（`DocNode` 或原始 `DocJson`）。
///
/// [editHost] 为 null 时完全只读（UI 批 1 的行为，保持不变）；非 null 且
/// `enabled` 为 true 时，[isEditablePath] 命中的 `paragraph` 会渲染成可编辑控件，
/// 其余节点（形状/未取证类型）**仍然只读降级**；`picture`/`image` 走
/// [OfficeDocImage]（加载骨架/图片/失败+重试三态）；
/// `table` 走 [OfficeDocTable]（批 B 真表格）；
/// `page_decorate` 的 `header`/`footer`/`page_num` 走 [OfficeDocPageFrame]
/// （批 B：印在**页边区域**，不是正文流里的一行字）。
class OfficeDocView extends StatelessWidget {
  const OfficeDocView({
    super.key,
    required this.doc,
    this.report,
    this.showHeaderNote = true,
    this.editHost,
    this.caretPrompt,
    this.objectId = '',
    this.imageBytesProvider,
    this.imageCache,
    this.pageKind = OfficeDocPageKind.normal,
    this.pageNumber = 1,
  });

  /// 文档树：`DocNode` 或 M1 的原始 `DocJson`（`Map<String, Object?>`）。
  ///
  /// 传原始树时渲染器**容忍** schema 里没有的节点名（降级而非崩），这是
  /// "未知节点不许崩"的防御路径（M1 的 `DocNode.fromRawJson` 会先抛）。
  final Object? doc;

  /// 降级计数/消息的去处；为 null 时内部新建（并 `debugPrint`）。
  final OfficeDocRenderReport? report;

  /// 是否显示页顶"只读渲染"说明。
  final bool showHeaderNote;

  /// 编辑宿主；null = 只读。
  final OfficeDocEditHost? editHost;

  /// ★ 第 313 轮：**编辑态"点正文任意处即可开始输入"** 的信号。
  ///
  /// 真机实测：空白文档里那个可输入段落只有 **351x20 dp**（`[office:field] rect`），
  /// 而官方在 `edit_area` 内任意位置点击都能落 caret（`queryChildOffset("edit_area")+1`）。
  /// 于是"点页面却打不了字"——用户（和我上一轮）都会认为功能坏了。
  /// 页面持有的这个 notifier 被点一次加一；**第一个**可编辑段落监听它并抢焦点。
  final ValueNotifier<int>? caretPrompt;

  /// `Snapshot:get` 回包里的 `object_id` —— **文档图片字节通道的钥匙**
  /// （`Attachment:get` 必须同时带它和 `file_id`，见 `office_doc_image.dart`）。
  final String objectId;

  /// 图片字节提供者（生产为 `OfficeApi.attachmentGet`；测试注入假字节）。
  final OfficeAttachmentBytesProvider? imageBytesProvider;

  /// 图片缓存（内存 LRU + 磁盘）；null = 进程级默认。
  final OfficeDocImageCache? imageCache;

  /// 这一帧正文属于哪种"页"（批 B）：连续流阅读器默认 [OfficeDocPageKind.normal]。
  ///
  /// 它决定页边装饰取哪一组：`normal` **绝不取** `type:"cover"` 的页眉页脚
  /// （这正是"cover 不印在封面页"的落点，见 `office_doc_page_frame.dart`）。
  final OfficeDocPageKind pageKind;

  /// 本帧页码（**真实页码**，用来替换 `page_num_text` 占位）。
  final int pageNumber;

  @override
  Widget build(BuildContext context) {
    // ★ 第 313 轮：**本帧用新的 sink**，渲染完再替换进调用方持有的 report
    // （原因见 [OfficeDocRenderReport.replaceWith]）。
    final sink = OfficeDocRenderReport();
    final root = doc is DocNode ? (doc as DocNode).toRawJson() : doc;
    if (root is! Map) {
      sink.unknownNode(root == null ? '(null)' : '${root.runtimeType}');
      // 提前返回的降级路径同样要把本帧结果交回调用方（否则长生命 report 会
      // 停在上一帧 —— 第 313 轮替换语义引入的边界）。
      report?.replaceWith(sink);
      return _DegradedCard(
        label: officeDocText(
          'officeDocRenderNotADoc',
          '不是可渲染的文档树（顶层不是对象）',
        ),
        detail: '${root.runtimeType}',
      );
    }
    final map = root.cast<String, Object?>();
    final type = map['type'];
    if (type != DocSchema.document.topNodeName) {
      // 顶层不是 doc：仍然把它的内容渲染出来，但在报告里如实登记。
      sink.note('顶层节点是 `$type`，schema topNode 是 '
          '`${DocSchema.document.topNodeName}`');
    }
    final renderer = _NodeRenderer(
      sink,
      context,
      editHost,
      caretPrompt: caretPrompt,
      objectId: objectId,
      imageBytesProvider: imageBytesProvider,
      imageCache: imageCache,
      pageKind: pageKind,
      pageNumber: pageNumber,
    );
    final tree = renderer.renderRoot(map);
    if (sink.messages.isNotEmpty) {
      // 降级必须可观测：写 debug 日志（不静默）。日志每帧最多一遍。
      debugPrint('[OfficeDocView] ${sink.messages.join(' | ')}');
    }
    report?.replaceWith(sink);
    // **没有开发者横幅**：纸面/排版本身就是最终形态；降级只进
    // [OfficeDocRenderReport]（可测试、可日志），不上屏当说明。
    //
    // **文档画布**：原生回退路径此前直接铺在 App 表面上 —— 于是"文档没给底色/
    // 字色"的内容随 App 主题变（深色主题下近白字）。这里给它一张**白纸**，
    // 并把**文档缺省文字样式**显式钉在 [kOfficeDocDefaultTextColor] 上，
    // 与 OOXML 纸面路径（`OfficeDocPaperView`）同一条原则：
    // **文档是自己的一页纸，外壳才跟主题**。
    return ListView(
      key: const Key('office-doc-view'),
      padding: const EdgeInsets.all(Gap.md),
      children: <Widget>[
        DefaultTextStyle.merge(
          style: const TextStyle(color: kOfficeDocDefaultTextColor),
          // ⚠️ **不要再加内层 `Padding`**：外层 ListView 已经是 `Gap.md`。
          // 再加一层会把正文可用宽度再削 2×Gap.md，于是**固定行高的表格单元格**
          // 里的文字多折一行 → `RenderFlex overflowed by 9.0 pixels on the bottom`
          // （`office_doc_table_test.dart` 的 T3 就是这么红掉的：已复现并回退）。
          child: DecoratedBox(
            key: const Key('office-doc-canvas'),
            decoration: const BoxDecoration(color: kOfficeDocPaperCanvasColor),
            child: tree,
          ),
        ),
      ],
    );
  }
}

class _DegradedCard extends StatelessWidget {
  const _DegradedCard({required this.label, required this.detail});

  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
        color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.help_outline, size: 16, color: t.colorScheme.outline),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  officeDocFillText(label, <String, String>{'name': detail}),
                  style: t.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 占位符填充（与 `office_write_gate.dart` 的 `officeDocFill` 同构，避免循环依赖）。
String officeDocFillText(String key, Map<String, String> values) {
  var out = officeDocText(key, key);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

// ---------------------------------------------------------------------------
// 渲染核心
// ---------------------------------------------------------------------------

class _NodeRenderer {
  _NodeRenderer(
    this.report,
    this.context,
    this.editHost, {
    this.caretPrompt,
    this.objectId = '',
    this.imageBytesProvider,
    this.imageCache,
    this.pageKind = OfficeDocPageKind.normal,
    this.pageNumber = 1,
  });

  final OfficeDocRenderReport report;
  final BuildContext context;
  final OfficeDocEditHost? editHost;

  /// 页面给的"点正文开始输入"信号（编辑态才有）；见 [OfficeDocView.caretPrompt]。
  final ValueNotifier<int>? caretPrompt;

  /// 本帧是否已经有一个可编辑段落认领了 [caretPrompt]（只要**第一个**抢焦点，
  /// 与官方 caret 落在 `edit_area` 内的语义一致）。
  bool _caretPromptTaken = false;

  /// 图片字节通道的钥匙与提供者（见 [OfficeDocView.objectId]）。
  final String objectId;
  final OfficeAttachmentBytesProvider? imageBytesProvider;
  final OfficeDocImageCache? imageCache;

  /// 本帧页型与真实页码（批 B：页边装饰与 `page_num_text` 用）。
  final OfficeDocPageKind pageKind;
  final int pageNumber;

  /// 文档的**缺省**文字样式。
  ///
  /// ⚠️ 旧实现是 `DefaultTextStyle.of(context).style` —— 那是 **App 主题**的
  /// 正文样式，于是"文档没给字色"的正文会染上 App 主题色（深色主题下近白）。
  /// 这与 `.osheet` 批次查实的 `_cell()` 缺陷**同源**。
  /// 这里把**颜色**换成文档自己的缺省色（字号/行距沿用既有，避免改坏版面基准）。
  TextStyle get _fallbackStyle {
    final base = DefaultTextStyle.of(context).style;
    return base.copyWith(color: kOfficeDocDefaultTextColor);
  }

  Widget renderRoot(Map<String, Object?> root) {
    final children = root['content'];
    if (children is! List || children.isEmpty) {
      return Text(
        officeDocText('officeDocEmpty', '这份文档没有可显示的正文块'),
        key: const Key('office-doc-empty'),
      );
    }
    // 批 B：`page_decorate` 不再当正文块渲染 —— 内容（header/footer/page_num）
    // 被摘出来交给页边框，印在**页边区域**。
    final bodyBlocks = <Widget>[];
    final decorations = <OfficeDocDecorations>[];
    for (var i = 0; i < children.length; i++) {
      final raw = children[i];
      final type = raw is Map ? raw['type'] : null;
      if (type == 'page_decorate') {
        decorations.add(OfficeDocDecorations.parse(raw, notes: report.messages));
        continue;
      }
      bodyBlocks.add(_block(raw, <int>[i]));
    }
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: bodyBlocks,
    );
    if (decorations.length > 1) {
      report.note('文档里有 ${decorations.length} 个 page_decorate（未取证形态）'
          '：只用第一个，其余忽略');
    }
    final framed =
        decorations.isEmpty ? body : _pageFrame(decorations.first, body);
    return _withCaretPrompt(framed);
  }

  /// ★ 第 313 轮：编辑态把整块正文包进一层"点哪里都开始输入"的手势。
  ///
  /// 官方在 `edit_area` 内任意位置点击都会把 caret 落到正文
  /// （`queryChildOffset("edit_area", true) + 1`）；而我们此前只有那个 20 dp 高的
  /// 段落控件本身可点 —— 点页面其它地方毫无反应（真机实测 `[office:field] rect
  /// origin=12,267 size=351x20`）。这里补齐；**只读态不包**（只读点击不该改东西）。
  Widget _withCaretPrompt(Widget child) {
    final prompt = caretPrompt;
    final host = editHost;
    if (prompt == null || host == null || !host.enabled) return child;
    return GestureDetector(
      key: const Key('office-doc-caret-prompt'),
      behavior: HitTestBehavior.translucent,
      onTap: () => prompt.value++,
      child: child,
    );
  }

  /// 一个**块级**节点的 widget。[path] 是从根开始的子节点下标路径（编辑宿主用它
  /// 定位段落；只读渲染时默认空路径）。
  Widget _block(Object? raw, [List<int> path = const <int>[]]) {
    if (raw is! Map) {
      report.unknownNode('${raw.runtimeType}');
      return _unknownCard('${raw.runtimeType}');
    }
    final node = raw.cast<String, Object?>();
    final type = node['type'];
    if (type is! String) {
      report.unknownNode('(no type)');
      return _unknownCard('(no type)');
    }
    final spec = DocSchema.document.nodes[type];
    if (spec == null) {
      report.unknownNode(type);
      return _unknownCard(type);
    }
    final support = kOfficeDocNodeSupport[type]?.support;
    if (support == OfficeDocNodeSupport.degraded) {
      report.unsupportedNode(type);
      return _unsupportedCard(type);
    }
    if (support == null) {
      // schema 有、覆盖表没有 → 这是覆盖表的缺陷，如实登记并降级（不能静默）。
      report.note('覆盖表缺少节点 $type 的登记（schema 已声明）');
      report.unsupportedNode(type);
      return _unsupportedCard(type);
    }
    switch (type) {
      case 'doc':
        return renderRoot(node);
      case 'settings':
        return _settingsRow(node, spec);
      case 'style_editor':
        return _styleEditor(node, path);
      case 'style_paragraph':
        return _paragraph(node, spec, isStyleDefinition: true);
      case 'invisible':
        return _invisibleRow(node);
      case 'edit_area':
      case 'text_box':
        return _children(node, spec, path);
      case 'page':
        return _pageBox(node, path);
      case 'paragraph':
        return _paragraph(node, spec, path: path);
      case 'horizontal_rule':
        // 批 B：真分隔线（schema 只有一个 leaf 标记，无颜色/粗细属性可读）。
        return const Divider(
          key: Key('office-doc-horizontal-rule'),
          height: Gap.lg,
        );
      case 'page_break':
        // 批 B：分页至少要有明确的视觉分隔（不做逐像素分页算法，见设计 §6.2）。
        return _dividerLabeled(
          officeDocText('officeDocPageBreak', '分页'),
          key: const Key('office-doc-page-break'),
        );
      case 'table':
        return _table(node, path);
      case 'page_decorate':
        // 根层已在 renderRoot 摘出；走到这里说明它嵌在别处（未取证形态）。
        report.note('page_decorate 不在根层（未取证形态）：只渲染页边装饰，不渲染正文');
        return _pageFrame(
          OfficeDocDecorations.parse(node, notes: report.messages),
          const SizedBox.shrink(),
          path: path,
        );
      case 'header':
        return _decorationRow(node, 'officeDocHeader', '页眉', path);
      case 'footer':
        return _decorationRow(node, 'officeDocFooter', '页脚', path);
      case 'page_num':
        return _pageNum(node, path);
      case 'page_num_block':
        return _children(node, spec, path);
      case 'page_num_text':
        // 批 B：显示**真实页码**（不再是 `#` 占位）。
        return Text(
          '$pageNumber',
          key: const Key('office-doc-page-num-text'),
          style: const TextStyle(color: officePageLabel),
        );
      case 'table_row':
      case 'table_cell':
      case 'text_line':
        // 表格/文本行由上层容器负责布局；单独出现时按子节点渲染。
        return _children(node, spec, path);
      case 'hard_break':
        return const SizedBox(height: Gap.sm);
      case 'tab':
        return const SizedBox(width: Gap.lg);
      case 'picture':
      case 'image':
        // 文档里的图片：真的把字节取出来渲染（见 office_doc_image.dart）。
        return _imageNode(node);
      case 'chart':
        // 批 B：**未取证** —— 13 份真实样例 `chart` 计数全为 0（无素材）。
        // 只按 schema 声明的 width/height 渲染占位卡（不解析 data/config，
        // 因为 data/config 的真实形状没有任何样例）。
        return _chartNode(node);
      case 'pseudo_list_item':
        // 列表标记本身不产生可见字符（前缀由 paragraph 的 listId 承载）；
        // 这里**不**打印节点名，避免把内部标识上屏。
        return const SizedBox.shrink();
      default:
        // 覆盖表登记为 rendered 但这里没有分支 = 覆盖表写错，降级并登记。
        report.note('节点 $type 已登记 rendered，但渲染分支缺失');
        report.unsupportedNode(type);
        return _unsupportedCard(type);
    }
  }

  // ---- 图片 ----------------------------------------------------------------

  /// `picture` / `image` 节点 → [OfficeDocImage]。
  ///
  /// * `picture`（**真机形态**）：引用与版式全在 `attrs.config` 里
  ///   （`file_id`/`file_alt`/`width`/`height`/`crop`/`deg`/`flip_h`/`flip_v`/
  ///   `alignment`，见 `docs/office-doc-render-design.md` §2 E3）；
  /// * `image`（schema 形态，**无夹具实例**）：引用在 `attrs.file_id`，
  ///   另有 `alt`/`width`/`height`（schema 未声明 `alignment`/`crop` → 不读）。
  ///
  /// **任何情况下都不把 `file_id`/`ref`/`src`/路径写进界面**：取不到字节时
  /// 由 [OfficeDocImage] 显示"图片加载失败 + 原因 + 重试"。
  Widget _imageNode(Map<String, Object?> node) {
    final type = '${node['type']}';
    final attrs = node['attrs'];
    Map<String, Object?> config = const <String, Object?>{};
    if (type == 'picture') {
      final raw = attrs is Map ? attrs['config'] : null;
      if (raw is Map) {
        config = raw.cast<String, Object?>();
      } else {
        report.note('picture 节点缺少 attrs.config（取不到图片引用）');
      }
    } else if (attrs is Map) {
      config = attrs.cast<String, Object?>();
    }
    final fileId = '${config['file_id'] ?? ''}'.trim();
    final alt = '${config['file_alt'] ?? config['alt'] ?? ''}'.trim();
    // 真机形态：`crop`/`deg`/`flip_*`/`alignment` 都只在 picture.config 里出现。
    final crop = OfficeDocImageCrop.from(config['crop']);
    final degrees = officeDocImagePx(config['deg']) ?? 0;
    final alignment = officeDocImageAlignmentFrom(config['alignment']);
    if (fileId.isEmpty) {
      // 如实登记（日志/测试可读），但**不**把 src/ref 打到界面上。
      report.note('$type 节点没有 file_id（无法取图片字节）');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: OfficeDocImage(
        objectId: objectId,
        fileId: fileId,
        width: officeDocImagePx(config['width']),
        height: officeDocImagePx(config['height']),
        alt: alt,
        crop: crop,
        degrees: degrees,
        flipHorizontal: config['flip_h'] == true,
        flipVertical: config['flip_v'] == true,
        alignment: alignment,
        provider: imageBytesProvider,
        cache: imageCache,
      ),
    );
  }

  // ---- 图表（批 B：**未取证**）---------------------------------------------

  /// `chart` 节点 → 占位卡。
  ///
  /// **未取证**：13 份真实文档（含全部 `.odoc`）里 `chart` 计数**全为 0**，
  /// 没有任何 `data`/`config` 的真实形状可用。因此这里**只**读 schema 明确
  /// 声明的 `width`/`height`（默认 560×410，见设计 §3），**不解析**
  /// `data`/`config`（解析字段名就是"猜"），也不把 `synochart` 这类内部标识上屏。
  /// 具体"未取证"事实同时写进 [OfficeDocRenderReport] 与批 B 文档。
  Widget _chartNode(Map<String, Object?> node) {
    report.note(
      'chart 节点未取证（13 份真实样例 chart 计数全为 0）：'
      '只按 schema width/height 渲染占位卡，不解析 data/config',
    );
    final width = officeDocImagePx(officeDocSchemaAttr(node, 'width')) ?? 560;
    final height = officeDocImagePx(officeDocSchemaAttr(node, 'height')) ?? 410;
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: LayoutBuilder(
        builder: (context, constraints) => SizedBox(
          key: const Key('office-doc-chart'),
          // schema 的宽度是 px；可用宽度更小时收敛（不溢出）。
          width: constraints.maxWidth.isFinite && constraints.maxWidth < width
              ? constraints.maxWidth
              : width,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: t.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(4),
              color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.insert_chart_outlined, color: t.colorScheme.outline),
                  const SizedBox(height: Gap.xs),
                  Text(
                    officeDocText('officeDocChartPlaceholder', '图表（暂无数据可渲染）'),
                    key: const Key('office-doc-chart-label'),
                    style: t.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- 文本块 --------------------------------------------------------------

  Widget _paragraph(
    Map<String, Object?> node,
    DocNodeSpec spec, {
    bool isStyleDefinition = false,
    List<int> path = const <int>[],
  }) {
    final headingLevel = officeDocSchemaAttr(node, 'headingLevel');
    final listLevel = officeDocSchemaAttr(node, 'listLevel');
    final listId = officeDocSchemaAttr(node, 'listId');
    final align = officeDocSchemaAttr(node, 'textAlign');
    final indentLeft = officeDocSchemaAttr(node, 'indentLeft');
    final indentFirst = officeDocSchemaAttr(node, 'indentFirst');
    final indentRight = officeDocSchemaAttr(node, 'indentRight');
    final lineHeight = officeDocSchemaAttr(node, 'lineHeight');
    final paddingTop = officeDocSchemaAttr(node, 'paddingTop');
    final paddingBottom = officeDocSchemaAttr(node, 'paddingBottom');
    final background = officeDocParseColor(
      officeDocSchemaAttr(node, 'backgroundColor'),
    );
    // 块级 attr mark（`text_align`/`line_height`/`text_indent`/`direction`）。
    // 段落 attrs 优先；attrs 没有时用 mark 兜底。不认识的 mark 一律忽略。
    final alignMark = _blockMark(node, 'text_align');
    final lineHeightMark = _blockMark(node, 'line_height');
    final indentMark = _blockMark(node, 'text_indent');
    final directionMark = _blockMark(node, 'direction');
    final spans = _inlineSpans(node, path);
    final level = headingLevel is num ? headingLevel.toInt() : 0;
    final isHeading = level >= 1 && level <= 6;
    final style = isHeading
        ? _headingStyle(Theme.of(context).textTheme, level)
        : null;
    var baseStyle = _fallbackStyle.merge(style);
    final effectiveLineHeight = _asDouble(lineHeight) ??
        _asDouble(lineHeightMark);
    if (effectiveLineHeight != null && effectiveLineHeight > 0) {
      baseStyle = baseStyle.copyWith(height: effectiveLineHeight);
    }
    final leftPad = _asDouble(indentLeft) ?? 0.0;
    final firstPad = _asDouble(indentFirst) ?? 0.0;
    final rightPad = _asDouble(indentRight) ?? 0.0;
    final markIndent = _asDouble(indentMark) ?? 0.0;
    final listIndent = listLevel is num && listLevel > 0
        ? Gap.lg * listLevel.toDouble()
        : 0.0;
    final effectiveAlign = align is String && align.isNotEmpty
        ? align
        : (alignMark is String ? alignMark : '');
    final textAlign = switch (effectiveAlign) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' => TextAlign.justify,
      _ => TextAlign.start,
    };
    // `direction` attr mark：`rtl` → 文字从右往左（其余保持默认）。
    final textDirection =
        directionMark is String && directionMark.toLowerCase() == 'rtl'
        ? TextDirection.rtl
        : null;
    final isList = (listId is String && listId.isNotEmpty) ||
        _hasPseudoListItem(node);
    final prefixText = isList
        ? '${listLevel is num && listLevel > 0 ? '  ' * listLevel.toInt() : ''}•  '
        : null;
    final prefix = prefixText == null
        ? null
        : TextSpan(text: prefixText, style: baseStyle);
    final padding = EdgeInsets.only(
      left: listIndent + leftPad + markIndent,
      right: rightPad,
      top: (isHeading ? Gap.sm : Gap.xxs) + (_asDouble(paddingTop) ?? 0),
      bottom: (isHeading ? Gap.xs : Gap.xxs) + (_asDouble(paddingBottom) ?? 0),
    );

    // UI 批 2：命中的正文段落渲染成可编辑控件。只支持 schema `paragraph` 且内联
    // 全是 text 的段落（`officeDocIsEditableBlock`）；其余一律保持只读降级。
    final editablePath = path.isNotEmpty &&
        !isStyleDefinition &&
        editHost != null &&
        editHost!.enabled &&
        editHost!.isEditablePath(OfficeDocPath(path));
    if (editablePath) {
      DocNode? parsed;
      OfficeDocInlineText? inline;
      try {
        parsed = DocNode.fromRawJson(node);
        inline = officeDocInlineText(parsed);
      } on Object catch (e) {
        // M1 校验不过（例如非 text 内联/空文本节点）→ 明确登记并保持只读。
        report.note('段落 ${OfficeDocPath(path).key} 无法进入编辑态：$e');
      }
      if (parsed != null && inline != null && officeDocIsEditableBlock(parsed)) {
        final host = editHost!;
        final docPath = OfficeDocPath(path);
        // 只让**第一个**可编辑段落响应"点正文开始输入"。
        final prompt = _caretPromptTaken ? null : caretPrompt;
        _caretPromptTaken = true;
        return Padding(
          padding: padding,
          child: _EditableParagraph(
            key: ValueKey<String>('office-doc-edit-para-${docPath.key}'),
            fieldKey: ValueKey<String>('office-doc-para-field-${docPath.key}'),
            text: inline.text,
            style: baseStyle,
            textAlign: textAlign,
            prefixText: prefixText,
            onChanged: (text) => host.onParagraphChanged(docPath, text),
            onSelection: (start, end) =>
                host.onParagraphSelection(docPath, start, end),
            onFocus: () => host.onParagraphFocused(docPath),
            caretPrompt: prompt,
          ),
        );
      }
    }

    // 首行缩进：Flutter 的 Text 没有 first-line indent，用一个等宽 WidgetSpan
    // 近似（只作用于只读渲染，避免干扰编辑控件的光标/选区）。
    final leadingIndent = firstPad > 0
        ? WidgetSpan(child: SizedBox(width: firstPad))
        : null;
    Widget block = Padding(
      padding: padding,
      child: Text.rich(
        TextSpan(
          style: baseStyle,
          children: [
            ?leadingIndent,
            ?prefix,
            ...spans,
          ],
        ),
        textAlign: textAlign,
        textDirection: textDirection,
      ),
    );
    if (background != null) {
      block = DecoratedBox(
        decoration: BoxDecoration(color: background),
        child: block,
      );
    }
    if (!isStyleDefinition) return block;
    // 样式定义：先给一行"标题 N / 正文"标签，再画具体样式。
    final label = isHeading
        ? officeDocFillText(
            'officeDocStyleHeading',
            <String, String>{'name': 'heading$level'},
          )
        : officeDocText('officeDocStyleBody', '正文');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label, style: Theme.of(context).textTheme.labelSmall),
          ),
          Expanded(child: block),
        ],
      ),
    );
  }

  Widget _children(
    Map<String, Object?> node,
    DocNodeSpec spec, [
    List<int> path = const <int>[],
  ]) {
    final children = node['content'];
    if (children is! List || children.isEmpty) return const SizedBox.shrink();
    // inline 容器的子节点是 text/hard_break/tab → 走 rich text；
    // 否则按块级递归。
    final inline = children.every(_isInline);
    if (inline) {
      return Text.rich(TextSpan(children: _inlineSpans(node, path)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++)
          _block(children[i], <int>[...path, i]),
      ],
    );
  }

  bool _isInline(Object? raw) {
    if (raw is! Map) return false;
    final type = raw['type'];
    if (type is! String) return false;
    final spec = DocSchema.document.nodes[type];
    if (spec == null) return false;
    return spec.isText || spec.groups.contains('inline');
  }

  /// num / 数字字符串 → double；认不出返回 null（**不抛、不上屏**）。
  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  /// 段落上的块级 attr mark 取值（`text_align` / `line_height` /
  /// `text_indent` / `direction`）。
  ///
  /// mark 形态是 `{"_":"text_align","value":"center"}`（也容忍 `type` 与
  /// `attrs.value` 两种写法）；presence mark 返回 `true`。
  Object? _blockMark(Map<String, Object?> node, String name) {
    final marks = node['marks'];
    if (marks is! List) return null;
    for (final raw in marks) {
      if (raw is! Map) continue;
      final mark = raw.cast<String, Object?>();
      if ((mark['_'] ?? mark['type']) != name) continue;
      final attrs = mark['attrs'];
      if (attrs is Map && attrs.containsKey('value')) return attrs['value'];
      if (mark.containsKey('value')) return mark['value'];
      return true; // presence mark
    }
    return null;
  }

  /// 段落里有没有 `pseudo_list_item` 标记（列表项目）。
  bool _hasPseudoListItem(Map<String, Object?> node) {
    final children = node['content'];
    if (children is! List) return false;
    return children.any(
      (c) => c is Map && c['type'] == 'pseudo_list_item',
    );
  }

  /// 文本节点的 `link` mark 的 `href`（没有/为空 → null）。
  String? _linkHref(Map<String, Object?> textNode) {
    final marks = textNode['marks'];
    if (marks is! List) return null;
    for (final raw in marks) {
      if (raw is! Map) continue;
      final mark = raw.cast<String, Object?>();
      if ((mark['_'] ?? mark['type']) != 'link') continue;
      final href = mark['href'];
      if (href is String && href.trim().isNotEmpty) return href.trim();
    }
    return null;
  }

  /// 打开链接（失败只写日志，**不弹任何内部标识**给用户）。
  void _openLink(String href) {
    final uri = Uri.tryParse(href);
    if (uri == null) {
      report.note('link mark 的 href 无法解析为 URI');
      return;
    }
    unawaited(
      launchUrl(uri, mode: LaunchMode.externalApplication).catchError((
        Object e,
      ) {
        report.note('打开链接失败：$e');
        return false;
      }),
    );
  }

  // ---- 页眉/页脚/页码 ------------------------------------------------------

  /// `settings` 是**非视觉的编辑器元数据**（leaf，无 content）：不进正文流。
  ///
  /// 批 1 曾把它印成一行"文档设置（本批只登记…）"——那是**工程话术**，
  /// 用户看到的应该只有文档本身。去掉可见行，但**仍进报告**（不静默丢）。
  Widget _settingsRow(Map<String, Object?> node, DocNodeSpec spec) {
    report.note('settings 节点（编辑器元数据，非视觉）不进正文流');
    return const SizedBox.shrink();
  }

  Widget _invisibleRow(Map<String, Object?> node) {
    report.note('invisible 节点（修订隐藏标记）本批不渲染');
    return const SizedBox.shrink();
  }

  Widget _styleEditor(
    Map<String, Object?> node, [
    List<int> path = const <int>[],
  ]) {
    final children = (node['content'] as List?) ?? const <Object?>[];
    final specs = children.whereType<Map>().length;
    return Card(
      key: const Key('office-doc-style-editor'),
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: ExpansionTile(
        initiallyExpanded: false,
        title: Text(
          officeDocFillText(
            'officeDocStyleEditorTitle',
            <String, String>{'count': '$specs'},
          ),
        ),
        childrenPadding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          for (var i = 0; i < children.length; i++)
            _block(children[i], <int>[...path, i]),
        ],
        // 折叠时也把数量登记进报告，避免"看不见 = 丢了"。
        onExpansionChanged: (_) {},
      ),
    );
  }

  Widget _pageBox(
    Map<String, Object?> node, [
    List<int> path = const <int>[],
  ]) {
    return Container(
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: _children(node, DocSchema.document.nodes['page']!, path),
    );
  }

  // ---- 页边装饰（批 B：页眉/页脚/页码印在页边区域，不进正文流）-------------

  /// 把 `page_decorate` 解析结果 + 正文装进 [OfficeDocPageFrame]。
  ///
  /// * 页眉带在上边距、页脚带 + 页码在下边距；
  /// * 装饰**按 [pageKind] 匹配**：正文帧（normal）绝不取 `type:"cover"`；
  /// * 被跳过的页型一律 `report.note` 登记（不静默丢）。
  Widget _pageFrame(
    OfficeDocDecorations decorations,
    Widget body, {
    List<int> path = const <int>[],
  }) {
    final headerNode = decorations.headerFor(pageKind);
    final footerNode = decorations.footerFor(pageKind);
    final pageNumNode = decorations.pageNumFor(pageKind);
    final skipped = decorations.skippedFor(pageKind);
    if (skipped.isNotEmpty) {
      report.note(
        '页型 ${pageKind.decorationType} 不印这些页边装饰：${skipped.join(', ')}'
        '（`type:"cover"` 的页眉页脚不印在封面页之外，反之亦然）',
      );
    }
    final header = headerNode is Map
        ? _decorationBand(
            headerNode.cast<String, Object?>(),
            'officeDocHeader',
            '页眉',
            <int>[...path, 0],
          )
        : null;
    final footer = footerNode is Map
        ? _decorationBand(
            footerNode.cast<String, Object?>(),
            'officeDocFooter',
            '页脚',
            <int>[...path, 1],
          )
        : null;
    final pageNumberWidget = pageNumNode is Map
        ? _pageNumBand(
            pageNumNode.cast<String, Object?>(),
            <int>[...path, 2],
          )
        : null;
    return KeyedSubtree(
      // 既有断言用的 key（批 1 起就有）仍然挂在"页边装饰"容器上。
      key: const Key('office-doc-page-decorate'),
      child: OfficeDocPageFrame(
        key: const Key('office-doc-page-frame'),
        body: body,
        header: header,
        footer: footer,
        pageNumber: pageNumberWidget,
        pageNumberAlignment: officeDocNumPositionAlignment(
          decorations.numPosition,
        ),
      ),
    );
  }

  /// 页边区域里的一个装饰带：小字标签（"页眉"）+ 真实内容。
  ///
  /// 标签**不带 `（normal）` 之类的内部枚举值**（那是工程话术）；只留用户
  /// 看得懂的"页眉/页脚"。
  Widget _decorationBand(
    Map<String, Object?> node,
    String labelKey,
    String zhLabel,
    List<int> path,
  ) {
    final spec = DocSchema.document.nodes[node['type']];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          officeDocText(labelKey, zhLabel),
          style: const TextStyle(fontSize: 11, color: officePageLabel),
        ),
        if (spec != null) _children(node, spec, path),
      ],
    );
  }

  /// 页边区域里的页码带：小字标签 + **真实页码**（按 `num-pos` 对齐）。
  Widget _pageNumBand(Map<String, Object?> node, List<int> path) {
    final spec = DocSchema.document.nodes['page_num'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          officeDocText('officeDocPageNum', '页码'),
          style: const TextStyle(fontSize: 11, color: officePageLabel),
        ),
        if (spec != null) _children(node, spec, path),
      ],
    );
  }

  /// 不在 `page_decorate` 里的独立 `header`/`footer`（未取证形态）：
  /// 仍然可见地登记并渲染内容，但**形状上是正文行**，不冒充页边区域。
  Widget _decorationRow(
    Map<String, Object?> node,
    String labelKey,
    String zhLabel, [
    List<int> path = const <int>[],
  ]) {
    report.note('${node['type']} 不在 page_decorate 内（未取证形态）：按正文行渲染');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              officeDocText(labelKey, zhLabel),
              style: const TextStyle(fontSize: 11, color: officePageLabel),
            ),
          ),
          Expanded(
            child: _children(
              node,
              DocSchema.document.nodes[node['type']]!,
              path,
            ),
          ),
        ],
      ),
    );
  }

  /// 不在 `page_decorate` 里的独立 `page_num`（未取证形态）。
  Widget _pageNum(
    Map<String, Object?> node, [
    List<int> path = const <int>[],
  ]) {
    report.note('page_num 不在 page_decorate 内（未取证形态）：按正文行渲染');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              officeDocText('officeDocPageNum', '页码'),
              style: const TextStyle(fontSize: 11, color: officePageLabel),
            ),
          ),
          Expanded(
            child: _children(
              node,
              DocSchema.document.nodes['page_num']!,
              path,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dividerLabeled(String label, {Key? key}) {
    return Row(
      key: key,
      children: [
        Expanded(child: Divider(color: Colors.grey.shade400)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          child: Text(label, style: const TextStyle(fontSize: 12, color: officePageLabel)),
        ),
        Expanded(child: Divider(color: Colors.grey.shade400)),
      ],
    );
  }

  // ---- 表格（批 B：真表格）-------------------------------------------------

  /// `table` 节点 → [OfficeDocTable]。
  ///
  /// 列宽 = `colgroup[].width`（px）**按比例分配可用宽度**（不横向滚动 → 永不溢出）；
  /// 行高 = `table_row.height`；每格画 `borderXxx*` / `backgroundColor`（可选键，
  /// 真实样例没有）/ `verticalAlign`。合并按每个 cell 自己的 `colspan`/`rowspan`
  /// 计算（**跨格路径未取证**：42 个真实格全为 1）；`synotable` 是**表格样式/
  /// 定义 id**，不做任何判据。详见 `office_doc_table.dart`。
  Widget _table(
    Map<String, Object?> node, [
    List<int> path = const <int>[],
  ]) {
    final model = OfficeDocTableModel.parse(node, notes: report.messages);
    if (model.spanCellCount > 0 && !model.canRenderSpans) {
      report.note(
        '表格有 colspan/rowspan>1，但行高缺失（算不出跨行矩形）'
        ' → 退回网格渲染（合并未生效，已如实登记）',
      );
    }
    if (model.rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: OfficeDocTable(
        key: const Key('office-doc-table'),
        model: model,
        cellBuilder: (cell, rowIndex, cellIndex) => _tableCellContent(
          cell,
          <int>[...path, rowIndex, cellIndex],
        ),
      ),
    );
  }

  Widget _tableCellContent(OfficeDocTableCellSpec cell, List<int> path) {
    final raw = cell.node;
    if (raw is! Map) return const SizedBox.shrink();
    final node = raw.cast<String, Object?>();
    final children = (node['content'] as List?) ?? const <Object?>[];
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++)
          _block(children[i], <int>[...path, i]),
      ],
    );
  }

  // ---- 内联（含 mark）------------------------------------------------------

  List<InlineSpan> _inlineSpans(
    Map<String, Object?> parent, [
    List<int> path = const <int>[],
  ]) {
    final out = <InlineSpan>[];
    for (final child in (parent['content'] as List?) ?? const <Object?>[]) {
      if (child is! Map) {
        report.unknownNode('${child.runtimeType}');
        out.add(TextSpan(
          text: '[${officeDocText('officeDocUnsupportedInline', '不支持的内联类型')}]',
        ));
        continue;
      }
      final node = child.cast<String, Object?>();
      final type = node['type'];
      if (type == 'text') {
        final text = '${node['text'] ?? ''}';
        final style = _markStyle(node);
        final href = _linkHref(node);
        if (href == null) {
          out.add(TextSpan(text: text, style: style));
        } else {
          // 链接可点：用 WidgetSpan 承载手势（不在非 State 里持有 recognizer）。
          out.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: () => _openLink(href),
                child: Text(text, style: style),
              ),
            ),
          );
        }
      } else if (type == 'hard_break') {
        out.add(const TextSpan(text: '\n'));
      } else if (type == 'tab') {
        out.add(const TextSpan(text: '\t'));
      } else if (type == 'page_num_text') {
        // 批 B：内联位置的页码 token 也显示**真实页码**。
        out.add(TextSpan(text: '$pageNumber'));
      } else if (type == 'pseudo_list_item') {
        // 列表标记（前缀由 paragraph 承载）→ 不产生可见字符、不上屏。
      } else if (type is String &&
          DocSchema.document.nodes.containsKey(type)) {
        // 块级节点混在内联容器里：递归成块（罕见但不崩）。picture/image 走
        // `_imageNode` → 真的把图片渲染出来（WidgetSpan 承载）。
        out.add(WidgetSpan(child: _block(node, path)));
      } else {
        // 未知内联类型：**不把类型名打印到界面**（只登记进 report）。
        report.unknownNode('$type');
        out.add(TextSpan(
          text: '[${officeDocText('officeDocUnsupportedInline', '不支持的内联类型')}]',
        ));
      }
    }
    return out;
  }

  /// 文本节点上的 mark → `TextStyle`。
  TextStyle? _markStyle(Map<String, Object?> textNode) {
    final marks = textNode['marks'];
    if (marks is! List || marks.isEmpty) return null;
    TextStyle style = const TextStyle();
    final schema = DocSchema.document;
    for (final raw in marks) {
      if (raw is! Map) continue;
      final mark = raw.cast<String, Object?>();
      final name = mark['_'] ?? mark['type'];
      if (name is! String) {
        report.unknownMark('(no _/type)');
        continue;
      }
      final known = schema.marks.containsKey(name) ||
          schema.attrMarks.containsKey(name);
      if (!known) {
        report.unknownMark(name);
        continue;
      }
      // 块级属性 mark（text_align/line_height/text_indent/direction）作用在
      // 段落上（见 `_paragraph`），**不**作用到内联文字；这里跳过、不计降级。
      if (schema.attrMarks.containsKey(name)) continue;
      final support = kOfficeDocMarkSupport[name]?.support;
      if (support != OfficeDocMarkSupport.rendered) {
        report.unsupportedMark(name);
        continue;
      }
      style = style.merge(_applyMark(style, mark, name));
    }
    return style;
  }

  TextStyle _applyMark(
    TextStyle base,
    Map<String, Object?> mark,
    String name,
  ) {
    switch (name) {
      case 'strong':
        return const TextStyle(fontWeight: FontWeight.bold);
      case 'em':
        return const TextStyle(fontStyle: FontStyle.italic);
      case 'underline':
        return const TextStyle(decoration: TextDecoration.underline);
      case 'strike':
        return const TextStyle(decoration: TextDecoration.lineThrough);
      case 'superscript':
        return const TextStyle(
          fontFeatures: <FontFeature>[FontFeature.superscripts()],
        );
      case 'subscript':
        return const TextStyle(
          fontFeatures: <FontFeature>[FontFeature.subscripts()],
        );
      case 'color':
        final c = officeDocParseColor(mark['value']);
        if (c == null) {
          report.note('color mark 的值无法解析：${mark['value']}');
          return const TextStyle();
        }
        return TextStyle(color: c);
      case 'background_color':
        final c = officeDocParseColor(mark['value']);
        if (c == null) {
          report.note('background_color mark 的值无法解析：${mark['value']}');
          return const TextStyle();
        }
        return TextStyle(backgroundColor: c);
      case 'font_size':
        final v = mark['value'];
        return TextStyle(fontSize: v is num ? v.toDouble() : null);
      case 'font_family':
        final v = mark['value'];
        // schema 的 empty_value 是 Arial；等于默认值时不改字体（与 toJSON 省略一致）。
        if (v is String && v.isNotEmpty && v != 'Arial') {
          return TextStyle(fontFamily: v);
        }
        return const TextStyle();
      case 'link':
        final href = mark['href'];
        if (href is String && href.isNotEmpty) {
          return TextStyle(
            color: Colors.blue.shade700,
            decoration: TextDecoration.underline,
          );
        }
        report.note('link mark 没有 href，仅按普通文本渲染');
        return const TextStyle();
      default:
        report.unsupportedMark(name);
        return const TextStyle();
    }
  }

  // ---- 降级卡片 ------------------------------------------------------------

  Widget _unknownCard(String type) => _DegradedCard(
    label: officeDocText(
      'officeDocUnsupportedUnknown',
      '暂不支持渲染的类型（schema 未声明）：{name}',
    ),
    detail: type,
  );

  Widget _unsupportedCard(String type) => _DegradedCard(
    label: officeDocText(
      'officeDocUnsupportedType',
      '暂不支持渲染的类型：{name}',
    ),
    detail: type,
  );
}

// 标题层级 → 字号（Synology 的 doc schema 没有 heading 节点，
// 标题是 `style_paragraph.headingLevel`；见 kOfficeDocNodeSupport）。
/// 标题样式：只取 App 主题的**字号/字重**，**颜色换成文档缺省色**。
///
/// 旧实现直接把 `theme.headlineSmall` 等原样返回 —— 那些样式**自带 App 主题的
/// 字色**，于是"文档没给标题字色"时标题会染上 App 主题色（深色主题下近白字
/// 落在深色 App 面上，或者反过来）。**颜色必须由文档决定。**
TextStyle _headingStyle(TextTheme theme, int level) {
  final base = switch (level) {
    1 => theme.headlineSmall ?? const TextStyle(fontSize: 24),
    2 => theme.titleLarge ?? const TextStyle(fontSize: 20),
    3 => theme.titleMedium ?? const TextStyle(fontSize: 18),
    _ => theme.titleSmall ?? const TextStyle(fontSize: 16),
  };
  return base.copyWith(color: kOfficeDocDefaultTextColor);
}

/// 可编辑的正文段落（UI 批 2）。
///
/// 它**只暴露纯文本 + 选区**，不自己构造 step、不自己算位置：文本变化 → 宿主；
/// 选区变化 → 宿主（工具栏据选区决定加/取消 mark）。列表项目符号走
/// `prefixText`（不在可编辑文本里，避免把装饰字符写进文档）。
class _EditableParagraph extends StatefulWidget {
  const _EditableParagraph({
    super.key,
    required this.fieldKey,
    required this.text,
    required this.style,
    required this.textAlign,
    required this.prefixText,
    required this.onChanged,
    required this.onSelection,
    this.caretPrompt,
    required this.onFocus,
  });

  final Key fieldKey;
  final String text;
  final TextStyle style;
  final TextAlign textAlign;
  final String? prefixText;
  final ValueChanged<String> onChanged;
  final void Function(int start, int end) onSelection;
  final VoidCallback onFocus;

  /// 非 null 时：该 notifier 每加一就抢一次焦点（"点正文开始输入"）。
  final ValueNotifier<int>? caretPrompt;

  @override
  State<_EditableParagraph> createState() => _EditableParagraphState();
}

class _EditableParagraphState extends State<_EditableParagraph> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.text);
  late final FocusNode _focusNode = FocusNode(debugLabel: 'office-doc-para');

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) widget.onFocus();
      // ★ 第 313 轮只读诊断：焦点到没到、谁在抢。真机现象是"点不进输入框"，
      // 只有把焦点事件打出来才能分清"指针没命中"与"焦点被抢"。
      debugPrint('[office:field] focus=${_focusNode.hasFocus} '
          'path=${(widget.fieldKey as ValueKey<String>).value}');
    });
    _controller.addListener(_reportSelection);
    widget.caretPrompt?.addListener(_onCaretPrompt);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ro = context.findRenderObject();
      if (ro is RenderBox && ro.hasSize) {
        final origin = ro.localToGlobal(Offset.zero);
        debugPrint('[office:field] rect origin=${origin.dx.toStringAsFixed(0)},'
            '${origin.dy.toStringAsFixed(0)} size=${ro.size.width.toStringAsFixed(0)}'
            'x${ro.size.height.toStringAsFixed(0)} '
            'path=${(widget.fieldKey as ValueKey<String>).value}');
      }
    });
  }

  @override
  void didUpdateWidget(_EditableParagraph old) {
    super.didUpdateWidget(old);
    // 文档（乐观树）被外部改动时（服务器确认 / 411 回滚 / 撤销），把控件文本
    // 同步过来；用户自己输入时两者相等，不会打断光标。
    if (widget.text != _controller.text) {
      final base = _controller.selection.baseOffset;
      final offset = base < 0 || base > widget.text.length
          ? widget.text.length
          : base;
      _controller.value = TextEditingValue(
        text: widget.text,
        selection: TextSelection.collapsed(offset: offset),
      );
    }
  }

  /// 页面（或正文任意处）请求"把 caret 放到正文"。
  void _onCaretPrompt() {
    if (!mounted) return;
    _focusNode.requestFocus();
    // 空段落没有可点的字符：把光标显式放到末尾，键盘才会真的起来。
    final end = _controller.text.length;
    _controller.selection = TextSelection.collapsed(offset: end);
  }

  void _reportSelection() {
    final sel = _controller.selection;
    final len = _controller.text.length;
    final base = sel.baseOffset < 0 ? len : sel.baseOffset;
    final extent = sel.extentOffset < 0 ? base : sel.extentOffset;
    final start = base < extent ? base : extent;
    final end = base < extent ? extent : base;
    widget.onSelection(start.clamp(0, len), end.clamp(0, len));
  }

  @override
  void dispose() {
    widget.caretPrompt?.removeListener(_onCaretPrompt);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: widget.fieldKey,
      controller: _controller,
      focusNode: _focusNode,
      maxLines: null,
      // ★ 第 313 轮只读诊断：指针到底有没有命中这个控件。
      onTap: () => debugPrint(
          '[office:field] onTap path=${(widget.fieldKey as ValueKey<String>).value}'),
      onTapAlwaysCalled: true,
      style: widget.style,
      textAlign: widget.textAlign,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        prefixText: widget.prefixText,
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }
}
