// ProseMirror JSON 的**结构 + 版式抽取**（纯 Dart；不 import flutter/l10n）。
//
// 证据（`docs/office-native-format-research.md` §4.1/§4.3，
// `docs/office-doc-redesign-report.md` §1 真实文件 `attrs`/`marks` 原文）：
//   - `.odoc` 的 `content.data` 是 `schemaDocument` 的 ProseMirror JSON；
//     `.oslides` 是 `schemaPresentation`；根节点 `{"type":"doc"}`；
//   - 正文文本就在 `{"type":"text","text":...}` 节点里，递归收集即可，
//     官方自己的检索器 `synoffice::fts::Parser::IndexProsemirror` 就是这么做的；
//   - 官方样本 `template/doc/*/text.json`、`template/slides/*/text.json` 用来验证。
//
// ## 本批（Office 渲染重做 O1）新增：**版式字段**（全部来自真机取证）
//
// 只读 `SYNO.Office.Snapshot:get` v4 取了 NAS 上 **5 份真实 `.odoc`**
// （`5-day trip planner` / `Product spec` / `Student report` /
// `Vacation packing list` / `Restaurant menu`），把全部 `attrs`/`marks` 的
// **键与取值原文**打进 `docs/office-doc-redesign-report.md` §1。实测存在：
//
//   节点 attrs：
//   * `doc.attrs.page_setup = {page_type:"a4", orientation:"portrait",
//     top/left/right/bottom: 2.54}`（单位 cm）；
//   * `paragraph.attrs`：`headingId` / `headingLevel` / `textAlign` /
//     `lineHeight` / `indentFirst` / `indentLeft` / `paddingTop` /
//     `paddingBottom` / `listId` / **`textMarks`（该段默认 mark 数组）** /
//     `listMarks`；
//   * `table.attrs.colgroup = [{"width":413},{"width":188}]`（px）、`synotable`；
//   * `table_row.attrs.height`；`table_cell.attrs`：12 个
//     `border{Top,Right,Bottom,Left}{Width,Style,Color}` + `colspan` +
//     `rowspan` + `verticalAlign`；
//   * `picture.attrs.config`：`file_id` / `file_alt` / `alt` / `alignment` /
//     `width` / `height` / `left` / `top` / `crop{l,t,r,b}` / `deg` /
//     `flip_h` / `flip_v` / `prst` / `stroke` / `stroke-width` / `fill` /
//     `order` / `file_type` / `customized_points` / `config`；
//   * `page_decorate.attrs`：`num-show` / `num-pos` / `num-cover` / `num-even` /
//     `place-show` / `place-cover` / `place-even`；其 `content` 恒为
//     `header×3(cover/even/normal)` + `footer×3` + `page_num`。
//
//   marks（**带值**）：
//   * `font_size.value`（num，px）；`font_family` 的
//     `value`/`eastAsia`/`complexScript`；`color.value`（`#rrggbb` 或
//     `rgb(r, g, b)`）；`background_color.value`（含 `"transparent"`）；
//   * `strong` / `em` / `underline`（无附加键的 presence mark）；
//   * `link.href`（真实取值是**文档内锚点** `#atrzFKK65v`）。
//
// **未取证（不实现成"已对齐"，报告 §6 如实登记）**：
//   * `listLevel`：真机 5 份文件的 `paragraph.attrs` 里**根本没有这个键**
//     （旧模型的 `listLevel` 是推测）。真实形态是**每个列表一个 `listId`**，
//     跨层嵌套样例为 0 → 本文件仍**容忍**读取 `listLevel`，但缺省 0，
//     且嵌套缩进**未取证**；
//   * `strikethrough` 类 mark：5 份文件里**计数 0**（只有 `underline`）。
//     渲染层对 `strike` 做了低成本支持，但标注为**未取证**；
//   * 有序列表的**起始序号**：`listMap[id].configs[0]` 实测恒为 `{}`，没有
//     `start` 字段 → 默认 1；
//   * `page` / `page_break` / `horizontal_rule` / `chart`：5 份文件计数全 0。

import 'office_json.dart';

/// 块级类型。
enum PmBlockKind {
  paragraph,
  heading,
  listItem,
  table,

  /// `page_break`（真机 5 份文件计数 0，schema 声明存在）。
  pageBreak,

  /// `horizontal_rule`（同上）。
  horizontalRule,
  other,
}

/// 一个 mark 的**名称 + 取值**（旧模型只留了名称，版式全丢）。
class PmMark {
  const PmMark(
    this.name, {
    this.value,
    this.href,
    this.eastAsia,
    this.complexScript,
  });

  /// 真实形态是 `{"_":"font_size","value":18}` —— 名称在 `_` 下，取值在同级。
  final String name;

  /// `value`（`font_size` 是 num；`color`/`background_color`/`font_family` 是 String）。
  final Object? value;

  /// `link.href`（真实取值是文档内锚点）。
  final String? href;

  /// `font_family.eastAsia` / `.complexScript`（与 `value` 通常同值）。
  final String? eastAsia;
  final String? complexScript;

  @override
  String toString() => value == null && href == null
      ? name
      : '$name=${value ?? href ?? eastAsia}';
}

/// 一条单元格边框（`borderXxxWidth/Style/Color` 三件套）。
class PmBorderSide {
  const PmBorderSide({this.width, this.style, this.color});

  final double? width;
  final String? style;
  final String? color;

  static const PmBorderSide none = PmBorderSide();

  /// 是否画得出来：宽度 > 0 且样式不是 none/hidden。
  bool get visible {
    final w = width ?? 0;
    final s = (style ?? '').toLowerCase();
    return w > 0 && s != 'none' && s != 'hidden';
  }

  bool get isUnset => width == null && style == null && color == null;

  @override
  String toString() => 'PmBorderSide(w=$width,${style ?? '?'},${color ?? '?'})';
}

/// 一个单元格的四条边框（真实 42 格全带齐 12 个键）。
class PmCellBorders {
  const PmCellBorders({
    this.top = PmBorderSide.none,
    this.right = PmBorderSide.none,
    this.bottom = PmBorderSide.none,
    this.left = PmBorderSide.none,
  });

  final PmBorderSide top;
  final PmBorderSide right;
  final PmBorderSide bottom;
  final PmBorderSide left;

  static const PmCellBorders none = PmCellBorders();

  bool get hasAny =>
      top.isUnset && right.isUnset && bottom.isUnset && left.isUnset
      ? false
      : (top.visible || right.visible || bottom.visible || left.visible);

  @override
  String toString() => 'PmCellBorders($top,$right,$bottom,$left)';
}

/// 一段行内文本及其 mark（**mark 现在带值**）。
class PmSpan {
  const PmSpan(
    this.text,
    this.marks, {
    this.linkHref,
    this.markList = const [],
    this.fontSize,
    this.fontFamily,
    this.color,
    this.backgroundColor,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
  });

  final String text;

  /// mark 类型名（样本实测：`font_size`/`font_family`/`color`/`background_color`/
  /// `strong`/`em`/`underline`/`link`）。
  final Set<String> marks;

  final String? linkHref;

  /// 带值的 mark 原文（版式字段的**唯一事实来源**）。
  final List<PmMark> markList;

  // ---- 取证到的版式字段（渲染层直接用这些，不再去猜）----
  final double? fontSize;
  final String? fontFamily;
  final String? color;
  final String? backgroundColor;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;

  bool get isEmpty => text.isEmpty;

  @override
  String toString() => 'PmSpan(${marks.join('+')}: "$text")';
}

/// 表格单元格。
class PmTableCell {
  const PmTableCell(
    this.text, {
    this.rowspan = 1,
    this.colspan = 1,
    this.borders = PmCellBorders.none,
    this.backgroundColor,
    this.verticalAlign,
    this.spans = const [],
  });

  final String text;
  final int rowspan;
  final int colspan;

  /// 真机 42 格全部带齐 12 个边框键。
  final PmCellBorders borders;

  /// schema 声明的可选键；**真机 42 格里一个都没有**（存在才用，绝不编）。
  final String? backgroundColor;

  /// 真机取值 `middle`（schema 也声明 top/bottom）。
  final String? verticalAlign;

  final List<PmSpan> spans;

  bool get hasSpan => rowspan > 1 || colspan > 1;

  @override
  String toString() => 'PmTableCell($rowspan x $colspan: "$text")';
}

class PmTableRow {
  const PmTableRow(this.cells, {this.height});

  final List<PmTableCell> cells;

  /// `table_row.attrs.height`（px；真机实测 124 / 28 / 26..91）。
  final double? height;

  String get text => cells.map((c) => c.text).join('\t');
}

class PmTable {
  const PmTable(this.rows, {this.colWidths = const [], this.styleId});

  final List<PmTableRow> rows;

  /// `table.attrs.colgroup[].width`（px）—— **每一列声明的宽度**。
  /// 真机三份文档之和分别 601 / 600 / 600 px，等于 A4 纵向 2.54cm 页边距的
  /// 内容宽（≈601.7px@96dpi）→ 就是页面内容坐标系下的像素宽。
  final List<double> colWidths;

  /// `table.attrs.synotable` —— **表格样式/定义 id**（同一文档 5 个独立表格同值），
  /// 不是表格 id，也不是合并判据。
  final String? styleId;

  bool get hasColgroup => colWidths.any((w) => w > 0);
}

/// 一个块级节点（**带取证到的版式属性**）。
class PmBlock {
  const PmBlock({
    required this.kind,
    required this.text,
    this.headingLevel = 0,
    this.listLevel = 0,
    this.ordered = false,
    this.spans = const [],
    this.table,
    this.textAlign = '',
    this.indentFirst = 0,
    this.indentLeft = 0,
    this.indentRight = 0,
    this.lineHeight,
    this.paddingTop = 0,
    this.paddingBottom = 0,
    this.styleName,
    this.listId,
    this.listMarker,
    this.orderedNumber,
    this.orderedStart = 1,
    this.defaultMarks = const [],
  });

  final PmBlockKind kind;
  final String text;

  /// 标题层级（1..N）；非标题为 0。样本里还出现过 `headingLevel: 0`。
  final int headingLevel;

  /// 列表缩进层级（`attrs.listLevel`）。**未取证**：真机 5 份文件无此键 →
  /// 缺省 0，嵌套缩进不做（报告 §6）。
  final int listLevel;

  /// 列表是有序（`ol`）还是无序（`ul`）。
  final bool ordered;

  final List<PmSpan> spans;
  final PmTable? table;

  // ---- 段落版式（真机取证）----
  /// `attrs.textAlign`（真机取值 `center`；schema 另有 left/right/justify）。
  final String textAlign;

  /// `attrs.indentFirst`（px）。
  final double indentFirst;

  /// `attrs.indentLeft`（px）。
  final double indentLeft;

  /// `attrs.indentRight`（px）。
  final double indentRight;

  /// `attrs.lineHeight`（倍数，真机 1.2 / 1.5）。
  final double? lineHeight;

  /// `attrs.paddingTop`（px）。
  final double paddingTop;

  /// `attrs.paddingBottom`（px）。
  final double paddingBottom;

  /// `attrs.headingId`（样式名/锚点 id）。
  final String? styleName;

  // ---- 列表（真机取证）----
  /// `attrs.listId`；`listMap[listId].type` 是 `ul`/`ol`。
  final String? listId;

  /// 渲染用的**真实标记**（无序 `•`/`◦`/`▪`，有序 `1.`/`2.`…）。
  /// 由 [extractProseMirror] 在抽取时算好，渲染层**不再自己拼字面 `-`**。
  final String? listMarker;

  /// 有序列表的**序号值**（从 [orderedStart] 起连续）。
  final int? orderedNumber;

  /// 有序列表的起始序号（`listMap[listId].configs[0].start`，真机恒缺省 → 1）。
  final int orderedStart;

  /// `attrs.textMarks` —— 该段落的**默认 mark**（真机 37 个段落带它）。
  /// 段落里的文本节点没有自己的 mark 时用它；有自己的 mark 时按名称覆盖。
  final List<PmMark> defaultMarks;

  bool get isHeading => kind == PmBlockKind.heading;

  bool get isListItem => kind == PmBlockKind.listItem;

  bool get isTable => kind == PmBlockKind.table;

  bool get isPageBreak => kind == PmBlockKind.pageBreak;

  bool get isHorizontalRule => kind == PmBlockKind.horizontalRule;

  /// 该块的**有效字号**：run 的 `font_size` 优先，其次段落 `textMarks`。
  /// 真机 5 份文件里标题字号都在 `textMarks`/run marks 上（18 / 20 / 24…），
  /// 所以"标题字号 ≥ 正文字号"可以**只靠文件数据**判断（见 O1 页面层用例）。
  double? get effectiveFontSize {
    for (final s in spans) {
      if (s.fontSize != null) return s.fontSize;
    }
    for (final m in defaultMarks) {
      if (m.name == 'font_size' && m.value is num) {
        return (m.value! as num).toDouble();
      }
    }
    return null;
  }

  /// 段落的**有效字号**取 run 里出现次数最多的那个（标题段通常只有一个字号）。
  /// 真机 `5-day trip planner` 的 `- DAY 1` 段是 18，`- DAY 2..5` 是 20。
  double? get dominantFontSize {
    final counts = <double, int>{};
    for (final s in spans) {
      final v = s.fontSize;
      if (v != null) counts[v] = (counts[v] ?? 0) + 1;
    }
    if (counts.isEmpty) return effectiveFontSize;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  PmBlock copyWith({
    String? listMarker,
    int? orderedNumber,
    List<PmSpan>? spans,
  }) => PmBlock(
    kind: kind,
    text: text,
    headingLevel: headingLevel,
    listLevel: listLevel,
    ordered: ordered,
    spans: spans ?? this.spans,
    table: table,
    textAlign: textAlign,
    indentFirst: indentFirst,
    indentLeft: indentLeft,
    indentRight: indentRight,
    lineHeight: lineHeight,
    paddingTop: paddingTop,
    paddingBottom: paddingBottom,
    styleName: styleName,
    listId: listId,
    listMarker: listMarker ?? this.listMarker,
    orderedNumber: orderedNumber ?? this.orderedNumber,
    orderedStart: orderedStart,
    defaultMarks: defaultMarks,
  );

  @override
  String toString() => '${kind.name}($text)';
}

/// 图片引用（`picture` 是 `.odoc` 的行内节点，`image` 是 `.oslides` 节点）。
class PmImageRef {
  const PmImageRef({
    required this.nodeType,
    this.fileId,
    this.alt,
    this.width,
    this.height,
    this.boxId,
    this.alignment,
    this.left,
    this.top,
    this.cropTop = 0,
    this.cropRight = 0,
    this.cropBottom = 0,
    this.cropLeft = 0,
    this.degrees = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.preset,
    this.fill,
    this.stroke,
    this.strokeWidth,
    this.fileType,
    this.order,
  });

  final String nodeType;

  /// 附件 id；对应 `attachment.json[].file_id` 与 `files/<file_id>`。
  final String? fileId;

  final String? alt;
  final double? width;
  final double? height;

  /// `picture.attrs.id`（节点 id，非附件 id）。
  final String? boxId;

  // ---- 版式（真机 `picture.attrs.config` 全部实测存在）----
  /// `config.alignment`（真机 `inline`；另有浮动形态 left/center/right）。
  final String? alignment;

  /// `config.left` / `config.top`（浮动定位，px）。
  final double? left;
  final double? top;

  /// `config.crop{l,t,r,b}`。
  final double cropTop;
  final double cropRight;
  final double cropBottom;
  final double cropLeft;

  /// `config.deg`（旋转角度）。
  final double degrees;
  final bool flipHorizontal;
  final bool flipVertical;

  /// `config.prst`（预设形状，真机 `rect`）。
  final String? preset;

  /// `config.fill` / `config.stroke` / `config.stroke-width`。
  final String? fill;
  final String? stroke;
  final double? strokeWidth;

  /// `config.file_type`（真机 `image`）。
  final String? fileType;

  /// `config.order`（z 序）。
  final int? order;

  bool get hasCrop =>
      cropTop != 0 || cropRight != 0 || cropBottom != 0 || cropLeft != 0;

  @override
  String toString() => 'PmImageRef($nodeType, file_id=$fileId, alt=$alt)';
}

/// 页边装饰（页眉/页脚/页码）的抽取结果。
class PmDecorations {
  const PmDecorations({
    this.headers = const {},
    this.footers = const {},
    this.pageNumberTypes = const [],
    this.showPageNumber = false,
    this.showPlacement = false,
    this.numberPosition = 'br',
  });

  /// `attrs.type`(`cover`/`even`/`normal`) → 该页眉的正文抽取。
  final Map<String, PmExtraction> headers;
  final Map<String, PmExtraction> footers;

  /// `page_num` 节点的 `attrs.type` 列表。
  final List<String> pageNumberTypes;

  /// `page_decorate.attrs.num-show` / `place-show`（真机模板恒 false）。
  final bool showPageNumber;
  final bool showPlacement;

  /// `page_decorate.attrs.num-pos`（真机 `br` = 右下角）。
  final String numberPosition;

  /// 该页型（`cover`/`normal`）的页眉文字；没有则空串。
  String headerText(String kind) => headers[kind]?.plainText.trim() ?? '';

  String footerText(String kind) => footers[kind]?.plainText.trim() ?? '';

  bool get isEmpty =>
      headers.isEmpty && footers.isEmpty && pageNumberTypes.isEmpty;

  static const PmDecorations none = PmDecorations();

  /// 从 `page_decorate` 节点抽取。
  static PmDecorations fromNode(Object? node) {
    final map = asJsonMap(node);
    if (map == null || asJsonString(map['type']) != 'page_decorate') {
      return none;
    }
    final attrs = asJsonMap(map['attrs']);
    final headers = <String, PmExtraction>{};
    final footers = <String, PmExtraction>{};
    final pageNums = <String>[];
    for (final raw in asJsonList(map['content']) ?? const []) {
      final n = asJsonMap(raw);
      if (n == null) continue;
      final type = asJsonString(n['type']);
      final kind = asJsonString(asJsonMap(n['attrs'])?['type']) ?? '';
      switch (type) {
        case 'header':
          headers[kind] = extractProseMirror(n['content']);
        case 'footer':
          footers[kind] = extractProseMirror(n['content']);
        case 'page_num':
          pageNums.add(kind);
      }
    }
    return PmDecorations(
      headers: headers,
      footers: footers,
      pageNumberTypes: pageNums,
      showPageNumber: attrs?['num-show'] == true,
      showPlacement: attrs?['place-show'] == true,
      numberPosition: asJsonString(attrs?['num-pos'])?.trim().isNotEmpty == true
          ? asJsonString(attrs?['num-pos'])!.trim()
          : 'br',
    );
  }
}

/// 一次抽取的结果。
class PmExtraction {
  PmExtraction({
    required this.blocks,
    required this.images,
    required this.nodeTypeCounts,
    this.pageSetup,
    this.decorations = PmDecorations.none,
  });

  final List<PmBlock> blocks;
  final List<PmImageRef> images;

  /// subtree 内节点类型直方图（近似枚举，用于报告结构）。
  final Map<String, int> nodeTypeCounts;

  /// `doc.attrs.page_setup` 原文（`null` = 该 subtree 没有）。
  final Map<String, Object?>? pageSetup;

  /// `page_decorate` 抽取结果（页眉/页脚/页码）。
  final PmDecorations decorations;

  String get plainText => blocks.map((b) => b.text).join('\n');

  int get textLength => plainText.length;

  int get nonEmptyBlockCount =>
      blocks.where((b) => b.text.trim().isNotEmpty).length;

  List<PmBlock> get headings => blocks.where((b) => b.isHeading).toList();

  List<PmBlock> get listItems => blocks.where((b) => b.isListItem).toList();

  List<PmBlock> get tables =>
      blocks.where((b) => b.kind == PmBlockKind.table).toList();

  /// 解析结果是否**没有任何可显示内容**（兜底文案的判据，见规格 §五）。
  bool get isEmptyContent =>
      blocks.every((b) => b.text.trim().isEmpty) && images.isEmpty;
}

/// 这些类型是编辑器元数据，不是正文。
const Set<String> _kPmMetadataTypes = {
  'settings',
  'style_editor',
  'style_paragraph',
  'invisible',
};

/// 有序列表的默认起始序号（真机 `configs[0]` 恒为 `{}`，无 `start`）。
const int kPmOrderedListDefaultStart = 1;

/// 无序列表标记（按层级）。
const List<String> kPmBulletMarkers = ['•', '◦', '▪'];

/// 从 [root]（一般是 `edit_area` 或某个 slide 的 `slide_content_container`）
/// 抽取块级结构与文本 + **版式**。
///
/// [listMap] 来自 `edit_area.attrs.listMap`：`{listId: {"type":"ul"|"ol",...}}`。
PmExtraction extractProseMirror(Object? root, {Map<String, Object?>? listMap}) {
  final counts = <String, int>{};
  countNodeTypes(root, counts);
  final blocks = <PmBlock>[];
  final images = <PmImageRef>[];
  _walk(root, listMap, blocks, images);
  _assignListMarkers(blocks, listMap);
  return PmExtraction(
    blocks: blocks,
    images: images,
    nodeTypeCounts: counts,
    pageSetup: _findPageSetup(root),
  );
}

/// 统计 ProseMirror subtree 里各 `type` 的出现次数（只看 `content`）。
void countNodeTypes(Object? node, Map<String, int> counts) {
  if (node is List) {
    for (final n in node) {
      countNodeTypes(n, counts);
    }
    return;
  }
  if (node is! Map) return;
  final type = asJsonString(node['type']);
  if (type != null) counts[type] = (counts[type] ?? 0) + 1;
  countNodeTypes(node['content'], counts);
}

/// 递归找 `doc.attrs.page_setup`（`.odoc` 根节点上）。
Map<String, Object?>? _findPageSetup(Object? node) {
  if (node is List) {
    for (final n in node) {
      final hit = _findPageSetup(n);
      if (hit != null) return hit;
    }
    return null;
  }
  final map = asJsonMap(node);
  if (map == null) return null;
  final attrs = asJsonMap(map['attrs']);
  final setup = asJsonMap(attrs?['page_setup']);
  if (setup != null && setup.isNotEmpty) return setup;
  return _findPageSetup(map['content']);
}

void _walk(
  Object? node,
  Map<String, Object?>? listMap,
  List<PmBlock> blocks,
  List<PmImageRef> images,
) {
  if (node is List) {
    for (final n in node) {
      _walk(n, listMap, blocks, images);
    }
    return;
  }
  if (node is! Map) return;
  final map = node.cast<String, Object?>();
  final type = asJsonString(map['type']);
  if (type != null && _kPmMetadataTypes.contains(type)) return;
  if (type == 'paragraph' || type == 'holder_paragraph') {
    _collectParagraph(map, listMap, blocks, images);
  } else if (type == 'table') {
    _collectTable(map, blocks, images);
  } else if (type == 'picture') {
    _collectPicture(map, images);
  } else if (type == 'image') {
    _collectSlideImage(map, images);
  } else if (type == 'page_break') {
    blocks.add(const PmBlock(kind: PmBlockKind.pageBreak, text: ''));
  } else if (type == 'horizontal_rule') {
    blocks.add(const PmBlock(kind: PmBlockKind.horizontalRule, text: ''));
  } else if (type != null) {
    _walk(map['content'], listMap, blocks, images);
  }
}

void _collectParagraph(
  Map<String, Object?> node,
  Map<String, Object?>? listMap,
  List<PmBlock> blocks,
  List<PmImageRef> images,
) {
  final attrs = asJsonMap(node['attrs']);
  final spans = <PmSpan>[];
  final buffer = StringBuffer();

  /// 段落级默认 mark（真机 `attrs.textMarks`）：run 没有自己的 mark 时继承。
  final defaultMarks = _parseMarkList(attrs?['textMarks']);

  void inline(Object? n) {
    if (n is List) {
      for (final x in n) {
        inline(x);
      }
      return;
    }
    final map = asJsonMap(n);
    if (map == null) return;
    final type = asJsonString(map['type']);
    if (type == 'text') {
      final text = asJsonString(map['text']) ?? '';
      if (text.isEmpty) return;
      buffer.write(text);
      final own = _parseMarkList(map['marks']);
      // 语义（**推断**，见文件头）：段落 `textMarks` 是默认，run 的 mark 同名覆盖。
      final effective = <String, PmMark>{
        for (final m in defaultMarks) m.name: m,
        for (final m in own) m.name: m,
      };
      spans.add(_spanFrom(text, effective.values.toList(growable: false)));
    } else if (type == 'hard_break') {
      buffer.write('\n');
    } else if (type == 'picture') {
      _collectPicture(map, images);
    } else if (type == 'image') {
      _collectSlideImage(map, images);
    } else {
      inline(map['content']);
    }
  }

  inline(node['content']);

  final headingLevel = asJsonInt(attrs?['headingLevel']);
  final listId = asJsonString(attrs?['listId']);
  final listLevel = asJsonInt(attrs?['listLevel']) ?? 0;
  var ordered = false;
  var orderedStart = kPmOrderedListDefaultStart;
  if (listId != null) {
    final def = asJsonMap(listMap?[listId]);
    ordered = asJsonString(def?['type']) == 'ol';
    final configs = asJsonList(def?['configs']);
    // 真机 `configs[0]` 恒为 `{}` —— `start` 未取证，读到才用。
    final first = configs == null || configs.isEmpty
        ? null
        : asJsonMap(configs.first);
    orderedStart = asJsonInt(first?['start']) ?? kPmOrderedListDefaultStart;
  }

  final kind = headingLevel != null
      ? PmBlockKind.heading
      : (listId != null ? PmBlockKind.listItem : PmBlockKind.paragraph);

  blocks.add(
    PmBlock(
      kind: kind,
      text: buffer.toString(),
      headingLevel: headingLevel ?? 0,
      listLevel: listLevel,
      ordered: ordered,
      spans: spans,
      textAlign: asJsonString(attrs?['textAlign']) ?? '',
      indentFirst: asJsonDouble(attrs?['indentFirst']) ?? 0,
      indentLeft: asJsonDouble(attrs?['indentLeft']) ?? 0,
      indentRight: asJsonDouble(attrs?['indentRight']) ?? 0,
      lineHeight: asJsonDouble(attrs?['lineHeight']),
      paddingTop: asJsonDouble(attrs?['paddingTop']) ?? 0,
      paddingBottom: asJsonDouble(attrs?['paddingBottom']) ?? 0,
      styleName: asJsonString(attrs?['headingId']),
      listId: listId,
      orderedStart: orderedStart,
      defaultMarks: defaultMarks,
    ),
  );
}

/// 一个 mark 列表 → 带值的 [PmMark]（真机形态 `{"_":"font_size","value":18}`；
/// 也容忍 `type` 与 `attrs.value` 两种写法）。
List<PmMark> _parseMarkList(Object? marks) {
  final out = <PmMark>[];
  for (final raw in asJsonList(marks) ?? const []) {
    final map = asJsonMap(raw);
    if (map == null) continue;
    final name = asJsonString(map['_']) ?? asJsonString(map['type']);
    if (name == null || name.isEmpty) continue;
    final nested = asJsonMap(map['attrs']);
    Object? value = map['value'] ?? nested?['value'];
    // `link` 的真实取值在 `href`（真机 `#atrzFKK65v`）；`url`/`value` 是
    // **未取证**的容错写法（研究文档 §8.1 第 7 条）。
    final href = name == 'link'
        ? (asJsonString(map['href']) ??
              asJsonString(nested?['href']) ??
              asJsonString(map['url']) ??
              asJsonString(nested?['url']) ??
              asJsonString(map['value']) ??
              asJsonString(nested?['value']))
        : null;
    out.add(
      PmMark(
        name,
        value: value,
        href: href,
        eastAsia: asJsonString(map['eastAsia']),
        complexScript: asJsonString(map['complexScript']),
      ),
    );
  }
  return out;
}

/// 带值 mark 列表 → [PmSpan]（版式字段在这里一次性落好）。
PmSpan _spanFrom(String text, List<PmMark> marks) {
  double? fontSize;
  String? fontFamily;
  String? color;
  String? backgroundColor;
  String? href;
  var bold = false;
  var italic = false;
  var underline = false;
  var strike = false;
  final names = <String>{};
  for (final m in marks) {
    names.add(m.name);
    switch (m.name) {
      case 'font_size':
        fontSize = _asDouble(m.value) ?? fontSize;
      case 'font_family':
        fontFamily = _cleanFontName(m.value) ?? fontFamily;
      case 'color':
        color = asJsonString(m.value) ?? color;
      case 'background_color':
        backgroundColor = asJsonString(m.value) ?? backgroundColor;
      case 'strong':
        bold = true;
      case 'em':
        italic = true;
      case 'underline':
        underline = true;
      case 'strike':
      case 'strikethrough':
      case 'line_through':
        // **未取证**：真机 5 份文件里删除线 mark 计数 0；低成本支持，报告 §6。
        strike = true;
      case 'link':
        href = m.href ?? href;
    }
  }
  return PmSpan(
    text,
    names,
    linkHref: href,
    markList: marks,
    fontSize: fontSize,
    fontFamily: fontFamily,
    color: color,
    backgroundColor: backgroundColor,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
  );
}

/// 去掉 `font_family` 值外面的引号（真机原文 `"\"Trebuchet MS\""`）。
String? _cleanFontName(Object? value) {
  final s = asJsonString(value);
  if (s == null) return null;
  final t = s.trim().replaceAll('"', '').replaceAll("'", '').trim();
  return t.isEmpty ? null : t;
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// 给列表块补**真实标记**（无序 `•`/`◦`/`▪`；有序 `1.`/`2.`…）。
///
/// * 编号按 **`listId` 连续**计数：同一个 `listId` 的项依次 1、2、3…；
///   换 `listId`（真机一份文档有 21 个）或遇到非列表块则重置；
/// * 无序列表标记按 `listLevel` 取 [kPmBulletMarkers]（缺省 0 = `•`）。
///
/// **绝不再产出字面 `-`**：真机 `5-day trip planner.odoc` 里的 `- DAY 1` 是
/// 文档正文里**真实的 text 节点**（不是列表标记），所以它由文本渲染，
/// 而不是由本函数生成。
void _assignListMarkers(List<PmBlock> blocks, Map<String, Object?>? listMap) {
  String? currentListId;
  var counter = 1;
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    if (!b.isListItem) {
      currentListId = null;
      counter = 1;
      continue;
    }
    if (b.listId != currentListId) {
      currentListId = b.listId;
      counter = b.orderedStart;
    }
    if (b.ordered) {
      blocks[i] = b.copyWith(listMarker: '$counter.', orderedNumber: counter);
      counter++;
    } else {
      final level = b.listLevel < 0
          ? 0
          : (b.listLevel >= kPmBulletMarkers.length
                ? kPmBulletMarkers.length - 1
                : b.listLevel);
      blocks[i] = b.copyWith(listMarker: kPmBulletMarkers[level]);
    }
  }
}

void _collectTable(
  Map<String, Object?> node,
  List<PmBlock> blocks,
  List<PmImageRef> images,
) {
  final attrs = asJsonMap(node['attrs']);
  final rows = <PmTableRow>[];
  final rawRows = asJsonList(node['content']) ?? const [];
  for (final rawRow in rawRows) {
    final row = asJsonMap(rawRow);
    if (asJsonString(row?['type']) != 'table_row') continue;
    final rowAttrs = asJsonMap(row?['attrs']);
    final cells = <PmTableCell>[];
    for (final rawCell in asJsonList(row?['content']) ?? const []) {
      final cell = asJsonMap(rawCell);
      if (asJsonString(cell?['type']) != 'table_cell') continue;
      final cellAttrs = asJsonMap(cell?['attrs']);
      cells.add(
        PmTableCell(
          proseMirrorTextOnly(cell?['content']),
          rowspan: asJsonInt(cellAttrs?['rowspan']) ?? 1,
          colspan: asJsonInt(cellAttrs?['colspan']) ?? 1,
          borders: _parseBorders(cellAttrs),
          backgroundColor: asJsonString(cellAttrs?['backgroundColor']),
          verticalAlign: asJsonString(cellAttrs?['verticalAlign']),
          spans: _inlineSpansOf(cell?['content']),
        ),
      );
      // 真实文件实测（5-day trip planner.odoc）：图片可以嵌在**表格单元格**里，
      // `proseMirrorTextOnly` 只取文字，必须另行收集，否则 [ODocDocument.images]
      // 会漏掉 5/10 张。
      _collectImagesIn(cell?['content'], images);
    }
    rows.add(PmTableRow(cells, height: asJsonDouble(rowAttrs?['height'])));
  }
  final table = PmTable(
    rows,
    colWidths: _parseColgroup(attrs?['colgroup']),
    styleId: asJsonString(attrs?['synotable']),
  );
  blocks.add(
    PmBlock(
      kind: PmBlockKind.table,
      text: rows.map((r) => r.text).join('\n'),
      table: table,
    ),
  );
}

/// `attrs.colgroup = [{"width":413},{"width":188}]`（px）。
List<double> _parseColgroup(Object? raw) {
  final out = <double>[];
  for (final item in asJsonList(raw) ?? const []) {
    final map = asJsonMap(item);
    out.add(asJsonDouble(map?['width']) ?? 0);
  }
  return out;
}

PmCellBorders _parseBorders(Map<String, Object?>? attrs) {
  PmBorderSide side(String name) => PmBorderSide(
    width: asJsonDouble(attrs?['border${name}Width']),
    style: asJsonString(attrs?['border${name}Style']),
    color: asJsonString(attrs?['border${name}Color']),
  );
  return PmCellBorders(
    top: side('Top'),
    right: side('Right'),
    bottom: side('Bottom'),
    left: side('Left'),
  );
}

/// 一个内联容器里的 text/marks → [PmSpan]（**不改文本**，只带版式）。
List<PmSpan> _inlineSpansOf(Object? content) {
  final out = <PmSpan>[];
  void walk(Object? n) {
    if (n is List) {
      for (final x in n) {
        walk(x);
      }
      return;
    }
    final map = asJsonMap(n);
    if (map == null) return;
    if (asJsonString(map['type']) == 'text') {
      final text = asJsonString(map['text']) ?? '';
      if (text.isNotEmpty) {
        out.add(_spanFrom(text, _parseMarkList(map['marks'])));
      }
      return;
    }
    walk(map['content']);
  }

  walk(content);
  return out;
}

/// 递归收集子树里的 `picture` / `image` 节点（不产出块）。
void _collectImagesIn(Object? node, List<PmImageRef> images) {
  if (node is List) {
    for (final n in node) {
      _collectImagesIn(n, images);
    }
    return;
  }
  final map = asJsonMap(node);
  if (map == null) return;
  final type = asJsonString(map['type']);
  if (type == 'picture') {
    _collectPicture(map, images);
    return;
  }
  if (type == 'image') {
    _collectSlideImage(map, images);
    return;
  }
  _collectImagesIn(map['content'], images);
}

/// 只取文本（不做块拆分），段落之间补 `\n`。用于表格单元格 / 演讲者备注。
String proseMirrorTextOnly(Object? node) {
  final buffer = StringBuffer();

  void walk(Object? n) {
    if (n is List) {
      for (final x in n) {
        walk(x);
      }
      return;
    }
    final map = asJsonMap(n);
    if (map == null) return;
    final type = asJsonString(map['type']);
    if (type == 'text') {
      buffer.write(asJsonString(map['text']) ?? '');
      return;
    }
    if (type == 'hard_break') {
      buffer.write('\n');
      return;
    }
    final content = map['content'];
    walk(content);
    if (type == 'paragraph' || type == 'holder_paragraph') {
      buffer.write('\n');
    }
  }

  walk(node);
  // 只去掉我们自己补的段落分隔换行；**不**做 `trimRight()`，
  // 否则会吃掉正文里的 U+00A0 等空白（project_task_checklist 里就有）。
  var text = buffer.toString();
  while (text.endsWith('\n')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

void _collectPicture(Map<String, Object?> node, List<PmImageRef> images) {
  final attrs = asJsonMap(node['attrs']);
  final config = asJsonMap(attrs?['config']);
  final crop = asJsonMap(config?['crop']);
  images.add(
    PmImageRef(
      nodeType: 'picture',
      fileId: asJsonString(config?['file_id']),
      alt: asJsonString(config?['file_alt']) ?? asJsonString(config?['alt']),
      width: asJsonDouble(config?['width']),
      height: asJsonDouble(config?['height']),
      boxId: asJsonString(attrs?['id']),
      alignment: asJsonString(config?['alignment']),
      left: asJsonDouble(config?['left']),
      top: asJsonDouble(config?['top']),
      cropTop: asJsonDouble(crop?['t']) ?? 0,
      cropRight: asJsonDouble(crop?['r']) ?? 0,
      cropBottom: asJsonDouble(crop?['b']) ?? 0,
      cropLeft: asJsonDouble(crop?['l']) ?? 0,
      degrees: asJsonDouble(config?['deg']) ?? 0,
      flipHorizontal: config?['flip_h'] == true,
      flipVertical: config?['flip_v'] == true,
      preset: asJsonString(config?['prst']),
      fill: asJsonString(config?['fill']),
      stroke: asJsonString(config?['stroke']),
      strokeWidth: asJsonDouble(config?['stroke-width']),
      fileType: asJsonString(config?['file_type']),
      order: asJsonInt(config?['order']),
    ),
  );
}

void _collectSlideImage(Map<String, Object?> node, List<PmImageRef> images) {
  final attrs = asJsonMap(node['attrs']);
  final transform =
      asJsonMap(attrs?['img_transform']) ?? asJsonMap(attrs?['transform']);
  final crop = asJsonMap(transform?['crop']);
  images.add(
    PmImageRef(
      nodeType: 'image',
      fileId: asJsonString(attrs?['file_id']),
      alt: asJsonString(attrs?['alt']),
      width: asJsonDouble(transform?['width']),
      height: asJsonDouble(transform?['height']),
      boxId: asJsonString(attrs?['id']),
      alignment: asJsonString(attrs?['alignment']),
      left: asJsonDouble(transform?['left']) ?? asJsonDouble(transform?['x']),
      top: asJsonDouble(transform?['top']) ?? asJsonDouble(transform?['y']),
      cropTop: asJsonDouble(crop?['t']) ?? 0,
      cropRight: asJsonDouble(crop?['r']) ?? 0,
      cropBottom: asJsonDouble(crop?['b']) ?? 0,
      cropLeft: asJsonDouble(crop?['l']) ?? 0,
      degrees: asJsonDouble(transform?['deg']) ?? 0,
    ),
  );
}
