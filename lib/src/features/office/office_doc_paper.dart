// Office `.odoc` 的**纸面阅读**（A4 纸 + 页边距 + 分页 + 缩放）—— O1 重做。
//
// ## 为什么单独一个文件
// 规格（`docs/office-render-redesign.md` §3.2）要求"文档=分页纸面"：
// 白色纸面 + 灰底 + 页与页之间的间距与投影 + **真实左右页边距** + 页码指示 +
// 双指缩放 + 适宽。这些是**与 schema 渲染正交**的版式容器，渲染器
// （`office_doc_view.dart`）只管"块长什么样"，本文件管"块落在哪张纸的哪里"。
//
// ## 坐标与单位（**取证 + 算术自洽**，见 `docs/office-doc-redesign-report.md` §2）
//   * `page_setup` 的单位是 **cm**：真机 5 份 `.odoc` 全是
//     `{page_type:"a4", orientation:"portrait", top/left/right/bottom:2.54}`；
//   * 排版长度（`colgroup[].width` / `indentFirst` / `indentLeft` /
//     `paddingTop` / `table_row.height`）的单位是 **px**：
//     colgroup 之和 600/601 px ≈ A4 纵向 2.54cm 页边距下的内容宽
//     `(21 − 5.08)cm × 96/2.54 = 601.7px`；且 `paddingTop: 10.67` 恰为 8pt；
//   * `font_size` mark 的单位是 **pt**（真机读数 11/12/13/15/18/20/24/28/40/50，
//     正文 12pt），所以要 ×(96/72) 换成纸面 px。**这是推断**（由上述算术自洽
//     推出，报告 §6 登记）。
//
// ## 分页（**估算**，报告 §6 如实登记）
// 真机 5 份 `.odoc` 里 `page` / `page_break` 节点**计数全为 0** ⇒ 没有现成的
// 分页边界。因此本文件用 **TextPainter 估算每个块的排版高度**，再按内容高装页：
//   * 这是**估算**，不是逐像素还原；页面用 `minHeight` 而不是固定高度，
//     **估算偏小时页面会长高，绝不裁字**（内容正确 > 逐像素复刻）；
//   * 遇到真实 `page_break` 节点则**强制分页**（权威边界）。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/i18n/l10n.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/office_native/odoc_model.dart';
import '../../data/office_native/office_json.dart';
import 'office_doc_style.dart' show kOfficeDocPaperCanvasColor;

/// **纸面**颜色：恒为白。
///
/// ⚠️ 这是"文档自己的底色"，**与 App 主题无关**（App 在深色模式下也必须是白纸）。
/// OOXML 里"文档没有页面底色"的语义就是白（`theme1.xml` 的 `lt1`
/// `sysClr lastClr="FFFFFF"`，见 `office_doc_ooxml.dart` 的 [OOXMLThemeScheme]）。
///
/// 值只有一处定义（`office_doc_style.dart` 的 [kOfficeDocPaperCanvasColor]）——
/// OOXML 纸面路径与原生回退路径的"文档画布"必须是**同一个白**。
const Color kOfficeDocPaperColor = kOfficeDocPaperCanvasColor;

/// **纸外底色**（纸张之间的"桌面"）：固定中性灰。
///
/// ## 为什么必须是**固定**色而不是 App 主题色
/// 旧实现是 `Color(0xFF9E9E9E).withValues(alpha: 0.28)` —— **半透明**，于是它
/// 叠在 App 背景上，颜色随主题变。真机实测（`Product spec.odoc`，截图转 BMP 逐像素）：
/// * 页间"灰底" = **(51,55,63)** —— 那是 App **深色**背景 (15,18,26) 与
///   0.28 白的混合结果，**根本不是灰**；
/// * 纸面投影也是 (52,54,62)，**与灰底无法区分** ⇒ 投影等于不存在；
/// * 纸面横向**铺满全屏**（x=0 与 x=1147 都是纯白）⇒ 左右看不到纸的边界。
///
/// 改成**不透明**的固定灰之后：纸外底色不随主题变，投影与左右留边才看得见。
/// 这就是用户点名要的"页面化 / 纸张感"里"纸与纸之间的灰底"那一半。
///
/// ⚠️ 口径说明：这是**本仓选择**的"文档查看器桌面灰"，不是 OOXML 规范里的值
/// （规范只规定纸面与页边距，不规定查看器的桌面色）。
/// 像素口径：真机截图是 **Display P3** 坐标，不是 sRGB（`.oslides` 批次实测），
/// 所以下面的读数只用于**相对关系**判断，不与 sRGB 字面值逐位比对。
const Color kOfficeDocPaperBackdrop = Color(0xFF9E9E9E);

/// 纸面**左右留边**（屏上逻辑 px）：让纸不贴屏幕边缘，露出纸外底色。
const double kOfficeDocPaperSideInset = 12;

/// 纸面**上下留边**（屏上逻辑 px）。
const double kOfficeDocPaperTopInset = 20;

/// DOCX 页面设置（[OOXMLPageSetup]）之外的"查看器桌面"常量都在上面。

/// pt → 纸面 px（96 dpi）。
const double kOdocPtToPx = 96.0 / 72.0;

/// 正文默认字号（pt）。真机 `font_size` 的众数是 12（42 个 run）。
const double kOdocDefaultFontPt = 12;

/// 纸面长度单位（px）→ pt 的换算基准（仅用于报告/测试说明）。
double officeDocFontSizePx(double? pt) =>
    (pt == null || pt <= 0 ? kOdocDefaultFontPt : pt) * kOdocPtToPx;

/// 纸面几何（**纯数据，可离线单测**）。
class OfficeDocPaperMetrics {
  const OfficeDocPaperMetrics({
    required this.pageWidth,
    required this.pageHeight,
    required this.marginLeft,
    required this.marginRight,
    required this.marginTop,
    required this.marginBottom,
    required this.pageType,
    required this.orientation,
  });

  /// 真机 `page_setup`（缺字段时是 A4 纵向 2.54cm）。
  factory OfficeDocPaperMetrics.fromSetup(ODocPageSetup setup) =>
      OfficeDocPaperMetrics(
        pageWidth: setup.pageWidthPx,
        pageHeight: setup.pageHeightPx,
        marginLeft: setup.marginLeftPx,
        marginRight: setup.marginRightPx,
        marginTop: setup.marginTopPx,
        marginBottom: setup.marginBottomPx,
        pageType: setup.pageType ?? 'a4',
        orientation: setup.orientation ?? 'portrait',
      );

  final double pageWidth;
  final double pageHeight;
  final double marginLeft;
  final double marginRight;
  final double marginTop;
  final double marginBottom;
  final String pageType;
  final String orientation;

  double get contentWidth {
    final w = pageWidth - marginLeft - marginRight;
    return w > 0 ? w : pageWidth;
  }

  double get contentHeight {
    final h = pageHeight - marginTop - marginBottom;
    return h > 0 ? h : pageHeight;
  }

  /// A4 的宽高比（用于用例断言"是 A4 比例纸面"）。
  double get aspectRatio => pageWidth / pageHeight;

  @override
  String toString() =>
      'OfficeDocPaperMetrics($pageType/$orientation, '
      '${pageWidth.toStringAsFixed(1)}x${pageHeight.toStringAsFixed(1)})';
}

/// 一个块参与分页的**高度输入**（纯数据；渲染层/模型层都能构造）。
class OfficeDocHeightInput {
  const OfficeDocHeightInput({
    required this.kind,
    this.text = '',
    this.fontSizePt,
    this.lineHeight,
    this.bold = false,
    this.paddingTop = 0,
    this.paddingBottom = 0,
    this.indentLeft = 0,
    this.indentRight = 0,
    this.markerWidth = 0,
    this.declaredHeight,
    this.forcedBreakBefore = false,
    this.isMetadata = false,
  });

  /// `paragraph` / `heading` / `listItem` / `table` / `image` /
  /// `pageBreak` / `horizontalRule` / `metadata`。
  final String kind;

  final String text;
  final double? fontSizePt;
  final double? lineHeight;
  final bool bold;
  final double paddingTop;
  final double paddingBottom;
  final double indentLeft;
  final double indentRight;

  /// 列表标记占的宽度（px）。
  final double markerWidth;

  /// 声明高度（表格的 `table_row.height` 之和 / 图片的 `config.height`）。
  final double? declaredHeight;

  /// 该块**之前**强制分页（真实 `page_break` 节点）。
  final bool forcedBreakBefore;

  /// 编辑器元数据（`settings` / `style_editor` / `invisible`）—— 不占纸面高度。
  final bool isMetadata;

  @override
  String toString() => 'OfficeDocHeightInput($kind, "$text")';
}

/// 一页装哪些块 + 该页的估算高度。
class OfficeDocPageSlice {
  const OfficeDocPageSlice({
    required this.blockIndices,
    required this.estimatedHeight,
  });

  /// 该页装载的**顶层块下标**（按原文顺序）。
  final List<int> blockIndices;

  /// 该页内容的**估算高度**（px；≥ 内容高才算满页）。
  final double estimatedHeight;

  @override
  String toString() => 'OfficeDocPageSlice($blockIndices, $estimatedHeight)';
}

/// 分页结果（**纯数据**）。
class OfficeDocPagination {
  const OfficeDocPagination({required this.pages, required this.gap});

  static const OfficeDocPagination empty = OfficeDocPagination(
    pages: [],
    gap: 0,
  );

  final List<OfficeDocPageSlice> pages;

  /// 页与页之间的间距（px，纸面坐标）。
  final double gap;

  int get pageCount => pages.length;

  bool get isEmpty => pages.isEmpty;

  /// 每页顶部相对内容流起点的**估算偏移**（px）。
  double offsetOfPage(int index) {
    var sum = 0.0;
    for (var i = 0; i < index && i < pages.length; i++) {
      sum += pages[i].estimatedHeight + gap;
    }
    return sum;
  }

  /// 估算的滚动位置 [offset]（px，纸面坐标）落在第几页（**0-based**）。
  int pageIndexAtOffset(double offset) {
    if (pages.isEmpty) return 0;
    var sum = 0.0;
    for (var i = 0; i < pages.length; i++) {
      sum += pages[i].estimatedHeight + gap;
      if (offset < sum) return i;
    }
    return pages.length - 1;
  }

  double get totalEstimatedHeight =>
      pages.fold<double>(0, (a, p) => a + p.estimatedHeight) +
      (pages.isEmpty ? 0 : gap * (pages.length - 1));
}

/// **分页器**：按内容高把顶层块装进 A4 页（估算，见文件头）。
abstract final class OfficeDocPaginator {
  /// 块与块之间的基础间距（px）。
  static const double blockSpacing = 4;

  /// 单行最小高度（px）——空段落也要占一行。
  static const double minLineHeight = 18;

  /// 表格行缺 `height` 时的兜底行高（px）。
  static const double fallbackTableRowHeight = 28;

  /// 元数据块（style_editor 折叠卡）的估算高度（px）。
  static const double metadataHeight = 48;

  /// 把 [inputs] 分成若干页。
  ///
  /// [contentWidth] / [contentHeight] 是**纸面坐标系**（px）下的正文区。
  static OfficeDocPagination paginate(
    List<OfficeDocHeightInput> inputs, {
    required double contentWidth,
    required double contentHeight,
    double gap = 24,
  }) {
    if (inputs.isEmpty) return OfficeDocPagination.empty;
    final heights = <double>[
      for (final input in inputs)
        estimateHeight(input, contentWidth: contentWidth),
    ];
    final pages = <OfficeDocPageSlice>[];
    var current = <int>[];
    var used = 0.0;

    void flush() {
      pages.add(
        OfficeDocPageSlice(
          blockIndices: List<int>.unmodifiable(current),
          estimatedHeight: used,
        ),
      );
      current = <int>[];
      used = 0.0;
    }

    for (var i = 0; i < inputs.length; i++) {
      final h = heights[i];
      final forced = inputs[i].forcedBreakBefore;
      if (forced && current.isNotEmpty) flush();
      final withSpacing = current.isEmpty ? h : h + (h > 0 ? blockSpacing : 0);
      if (current.isNotEmpty && used + withSpacing > contentHeight) {
        flush();
        used = h;
        current = <int>[i];
        continue;
      }
      used += withSpacing;
      current.add(i);
    }
    if (current.isNotEmpty) flush();
    if (pages.isEmpty) {
      pages.add(const OfficeDocPageSlice(blockIndices: [], estimatedHeight: 0));
    }
    return OfficeDocPagination(pages: pages, gap: gap);
  }

  /// 估算一个块的高度（px，纸面坐标）。
  static double estimateHeight(
    OfficeDocHeightInput input, {
    required double contentWidth,
  }) {
    switch (input.kind) {
      case 'pageBreak':
      case 'none':
        return 0;
      case 'metadata':
        return metadataHeight;
      case 'horizontalRule':
        return Gap.lg;
      case 'table':
      case 'image':
        return input.declaredHeight ?? 0;
      default:
        return _textHeight(input, contentWidth);
    }
  }

  static double _textHeight(OfficeDocHeightInput input, double contentWidth) {
    final fontSize = officeDocFontSizePx(input.fontSizePt);
    final lineHeight = (input.lineHeight ?? 0) > 0 ? input.lineHeight! : 1.4;
    final available =
        contentWidth - input.indentLeft - input.indentRight - input.markerWidth;
    final width = available > 8 ? available : contentWidth;
    final text = input.text.isEmpty ? ' ' : input.text;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          height: lineHeight,
          fontWeight: input.bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: width);
    final h = painter.height;
    painter.dispose();
    final lines = math.max(1, (h / (fontSize * lineHeight)).round());
    return math.max(minLineHeight, lines * fontSize * lineHeight) +
        input.paddingTop +
        input.paddingBottom;
  }
}

/// 从**真实原始节点**构造分页输入（`.odoc` 的顶层块）。
///
/// 这一步读的字段全部来自真机取证（见 `prosemirror_model.dart` 文件头）。
List<OfficeDocHeightInput> officeDocHeightInputsFromRaw(List<Object?> nodes) {
  final out = <OfficeDocHeightInput>[];
  for (final raw in nodes) {
    out.add(officeDocHeightInputForNode(raw));
  }
  return out;
}

/// 单个原始节点 → 分页输入。
OfficeDocHeightInput officeDocHeightInputForNode(Object? raw) {
  final node = asJsonMap(raw);
  if (node == null) {
    return const OfficeDocHeightInput(kind: 'paragraph', isMetadata: true);
  }
  final type = asJsonString(node['type']) ?? '';
  final attrs = asJsonMap(node['attrs']);
  switch (type) {
    case 'page_break':
      return const OfficeDocHeightInput(
        kind: 'pageBreak',
        forcedBreakBefore: true,
      );
    case 'horizontal_rule':
      return const OfficeDocHeightInput(kind: 'horizontalRule');
    case 'settings':
    case 'invisible':
      return const OfficeDocHeightInput(kind: 'metadata', isMetadata: true);
    case 'style_editor':
      return const OfficeDocHeightInput(kind: 'metadata');
    case 'table':
      return OfficeDocHeightInput(
        kind: 'table',
        declaredHeight: _tableHeight(node),
      );
    case 'picture':
    case 'image':
      return OfficeDocHeightInput(
        kind: 'image',
        declaredHeight: _imageHeight(node),
      );
    case 'paragraph':
    case 'holder_paragraph':
      break;
    default:
      // 容器（edit_area / doc / page…）：高度由子块决定 → 记为 0，由调用方展开。
      return const OfficeDocHeightInput(kind: 'metadata', isMetadata: true);
  }
  final heading = asJsonDouble(attrs?['headingLevel']);
  final listId = asJsonString(attrs?['listId']);
  final isHeading = heading != null && heading >= 1;
  final kind = isHeading
      ? 'heading'
      : (listId != null ? 'listItem' : 'paragraph');
  final text = _textOf(node);
  return OfficeDocHeightInput(
    kind: kind,
    text: text,
    fontSizePt: _fontSizePtOf(node, attrs),
    lineHeight: asJsonDouble(attrs?['lineHeight']),
    bold: isHeading || _hasMark(node, 'strong'),
    paddingTop: asJsonDouble(attrs?['paddingTop']) ?? 0,
    paddingBottom: asJsonDouble(attrs?['paddingBottom']) ?? 0,
    indentLeft: asJsonDouble(attrs?['indentLeft']) ?? 0,
    indentRight: asJsonDouble(attrs?['indentRight']) ?? 0,
    markerWidth: listId != null ? 24 : 0,
  );
}

String _textOf(Map<String, Object?> node) {
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
    walk(map['content']);
  }

  walk(node['content']);
  return buffer.toString();
}

bool _hasMark(Map<String, Object?> node, String name) {
  for (final raw in asJsonList(node['marks']) ?? const []) {
    final map = asJsonMap(raw);
    if ((asJsonString(map?['_']) ?? asJsonString(map?['type'])) == name) {
      return true;
    }
  }
  return false;
}

/// 段落的有效字号（pt）：run 的 `font_size` 优先，其次段落 `textMarks`。
double? _fontSizePtOf(Map<String, Object?> node, Map<String, Object?>? attrs) {
  final found = <double>[];
  void collect(Object? marks) {
    for (final raw in asJsonList(marks) ?? const []) {
      final map = asJsonMap(raw);
      final name = asJsonString(map?['_']) ?? asJsonString(map?['type']);
      if (name != 'font_size') continue;
      final v = asJsonDouble(map?['value']);
      if (v != null) found.add(v);
    }
  }

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
      collect(map['marks']);
      return;
    }
    walk(map['content']);
  }

  walk(node['content']);
  if (found.isEmpty) collect(attrs?['textMarks']);
  if (found.isEmpty) return null;
  // 取最大值：标题段通常只有一个字号；混排时按最大字号留出空间更安全。
  return found.reduce(math.max);
}

double? _tableHeight(Map<String, Object?> node) {
  var sum = 0.0;
  var rows = 0;
  for (final raw in asJsonList(node['content']) ?? const []) {
    final row = asJsonMap(raw);
    if (asJsonString(row?['type']) != 'table_row') continue;
    rows++;
    final h = asJsonDouble(asJsonMap(row?['attrs'])?['height']);
    sum += (h != null && h > 0) ? h : OfficeDocPaginator.fallbackTableRowHeight;
  }
  if (rows == 0) return 0;
  if (sum <= 0) return rows * OfficeDocPaginator.fallbackTableRowHeight;
  return sum;
}

double? _imageHeight(Map<String, Object?> node) {
  final attrs = asJsonMap(node['attrs']);
  if (asJsonString(node['type']) == 'picture') {
    final config = asJsonMap(attrs?['config']);
    final h = asJsonDouble(config?['height']);
    return h != null && h > 0 ? h : null;
  }
  final transform =
      asJsonMap(attrs?['img_transform']) ?? asJsonMap(attrs?['transform']);
  final h = asJsonDouble(transform?['height']);
  return h != null && h > 0 ? h : null;
}

/// 从**模型块**构造分页输入（`OfficeDocView` 之外的路径 / 离线用例用）。
List<OfficeDocHeightInput> officeDocHeightInputsFromBlocks(
  List<PmBlockView> blocks,
) {
  return <OfficeDocHeightInput>[
    for (final b in blocks)
      OfficeDocHeightInput(
        kind: switch (b.kind) {
          'heading' => 'heading',
          'listItem' => 'listItem',
          'table' => 'table',
          'image' => 'image',
          'pageBreak' => 'pageBreak',
          'horizontalRule' => 'horizontalRule',
          _ => 'paragraph',
        },
        text: b.text,
        fontSizePt: b.fontSizePt,
        lineHeight: b.lineHeight,
        bold: b.bold,
        paddingTop: b.paddingTop,
        paddingBottom: b.paddingBottom,
        indentLeft: b.indentLeft,
        indentRight: b.indentRight,
        markerWidth: b.markerWidth,
        declaredHeight: b.declaredHeight,
        forcedBreakBefore: b.kind == 'pageBreak',
      ),
  ];
}

/// 模型块的**分页视图**（避免 `office_doc_paper.dart` 反向依赖 feature 层，
/// 也让离线用例不必搭 widget）。
class PmBlockView {
  const PmBlockView({
    required this.kind,
    this.text = '',
    this.fontSizePt,
    this.lineHeight,
    this.bold = false,
    this.paddingTop = 0,
    this.paddingBottom = 0,
    this.indentLeft = 0,
    this.indentRight = 0,
    this.markerWidth = 0,
    this.declaredHeight,
  });

  final String kind;
  final String text;
  final double? fontSizePt;
  final double? lineHeight;
  final bool bold;
  final double paddingTop;
  final double paddingBottom;
  final double indentLeft;
  final double indentRight;
  final double markerWidth;
  final double? declaredHeight;
}

// ---------------------------------------------------------------------------
// 纸面 widget
// ---------------------------------------------------------------------------

/// **一张 A4 纸**：白底 + 投影 + 真实页边距 + 页眉/页脚/页码带。
///
/// 它按**纸面坐标系**（px）排版；外层 [OfficeDocPaperView] 负责把它缩放到屏幕宽。
class OfficeDocPaperPage extends StatelessWidget {
  const OfficeDocPaperPage({
    super.key,
    required this.metrics,
    required this.children,
    this.pageIndex = 0,
    this.headerText = '',
    this.footerText = '',
    this.pageNumber,
    this.totalPages,
    this.numberAlignment = Alignment.bottomRight,
  });

  final OfficeDocPaperMetrics metrics;
  final List<Widget> children;
  final int pageIndex;

  /// 文档自带的页眉/页脚文字（真机 5 份 `.odoc` 全为空 → 不占位）。
  final String headerText;
  final String footerText;

  /// 纸面自带的页码（真机模板 `num-show:false`，因此默认为 null 不印）。
  final int? pageNumber;
  final int? totalPages;
  final Alignment numberAlignment;

  @override
  Widget build(BuildContext context) {
    final hasFooter = footerText.isNotEmpty || pageNumber != null;
    return Container(
      key: Key('office-doc-paper-page-$pageIndex'),
      width: metrics.pageWidth,
      // **不裁剪**：估算偏小时页面长高，内容永远看得见（见文件头）。
      constraints: BoxConstraints(minHeight: metrics.pageHeight),
      decoration: const BoxDecoration(
        color: kOfficeDocPaperColor,
        boxShadow: <BoxShadow>[
          // **纸面投影**。旧值是 `Color(0x33000000)`（20% 黑），而纸外底色当时是
          // App 深色主题背景的混合结果（真机实测 (51,55,63)）⇒ 投影与底色
          // **逐像素无法区分**，纸的边界感为零（父 agent r17 截图复现）。
          // 现在底色是固定中性灰（见 [kOfficeDocPaperBackdrop]），
          // 并把投影加厚到 45% 黑 + 16px 模糊 + 3px 下移。
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 16,
            spreadRadius: 1,
            offset: Offset(0, 3),
          ),
        ],
        // 一圈极细的纸边（投影之外再给一条硬边，缩放到小尺寸时也看得见纸的边界）。
        //
        // ★★ DA289（r667）：**纸边必须画在 `foregroundDecoration`，不能画在
        //   `border`**。`Container.decoration.border` 会**吃掉子级的可用宽度**
        //   （左右各 0.5 px），而 `metrics.contentWidth` 是按 `pageWidth − 左右边距`
        //   算的、并不知道这 1 px ⇒ 正文实际拿到 `contentWidth − 1`，
        //   `_table` 按 `contentWidth` 缩放列宽 ⇒ 每一行都溢 1 px
        //   （真机读数：`A RenderFlex overflowed by 0.267 pixels on the right`，
        //    0.267 = 1.0 × FittedBox 的 0.5333 缩放；Linux 站 `16_office_odoc.png`）。
        //   `foregroundDecoration` 同样画在最上层、像素一致，但不参与布局。
      ),
      foregroundDecoration: BoxDecoration(
        border: Border.fromBorderSide(
          BorderSide(color: Color(0x1F000000), width: 0.5),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: metrics.marginLeft,
          right: metrics.marginRight,
          top: metrics.marginTop,
          bottom: metrics.marginBottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (headerText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Text(
                  headerText,
                  key: Key('office-doc-paper-header-$pageIndex'),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF8A8A8A),
                  ),
                ),
              ),
            SizedBox(
              width: metrics.contentWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
            if (hasFooter)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        footerText,
                        key: Key('office-doc-paper-footer-$pageIndex'),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF8A8A8A),
                        ),
                      ),
                    ),
                    if (pageNumber != null)
                      Align(
                        alignment: numberAlignment,
                        child: Text(
                          totalPages == null
                              ? '$pageNumber'
                              : '$pageNumber / $totalPages',
                          key: Key('office-doc-paper-pagenum-$pageIndex'),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF8A8A8A),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 目录条目（由**标题层级**生成，不是文档里内嵌的 TOC 域）。
///
/// ## 权威事实（父 agent 用官方 APK + 5 份真样本查清，本批直接引用）
/// 1. 官方 Android App **有这个 UI**（Synology Drive 3.9.0 资源表）：
///    `string/table_of_contents` = "Table of contents" / "目录" / "目錄"；
///    以及 `string/heading` = "Heading"/"标题"、`heading_1..6` = "1 级标题".."6 级标题"
///    （**只有 1..6 级，没有 7/8**）。
/// 2. `.odoc` 文件里**没有内嵌目录**：5 份真样本逐份统计 `TOC` / `instrText` /
///    `fldSimple` **全为 0**。
/// **⇒ 官方的"目录"= 由 `Heading1..6`（`w:pStyle` + `styles.xml` 的 `outlineLvl`）
/// 生成的【大纲导航面板】，不是文档里的目录块。**
///
/// 本仓现状：`office_doc_ooxml.dart` 早就解析出 `headingLevel`（1..6），
/// 缺的纯粹是 UI。
class OfficeDocTocEntry {
  const OfficeDocTocEntry({
    required this.level,
    required this.text,
    required this.blockIndex,
  });

  /// `Heading1..6` → `1..6`。
  final int level;

  /// 标题文字（`find.text` 也用它）。
  final String text;

  /// 该标题在 `ODocxDocument.blocks` 里的下标（定位用）。
  final int blockIndex;

  @override
  String toString() => 'OfficeDocTocEntry($level, "$text", #$blockIndex)';
}

/// **纸面阅读视图**：灰底 + 连续滚动的 A4 纸 + 双指缩放 + 适宽 + 页码指示
/// + **目录**（大纲导航）。
class OfficeDocPaperView extends StatefulWidget {
  const OfficeDocPaperView({
    super.key,
    required this.metrics,
    required this.pages,
    this.pagination,
    this.headerText = '',
    this.footerText = '',
    this.numberAlignment = Alignment.bottomRight,
    this.toc = const <OfficeDocTocEntry>[],
    this.paperOffsetOfBlock,
  });

  final OfficeDocPaperMetrics metrics;

  /// 每页的内容 widget（下标与 [pagination] 的页一一对应）。
  final List<Widget> pages;

  /// 分页结果（页码指示/当前页用）。
  final OfficeDocPagination? pagination;

  final String headerText;
  final String footerText;
  final Alignment numberAlignment;

  /// 目录条目（**空 ⇒ 不显示目录入口**，绝不给空面板入口）。
  final List<OfficeDocTocEntry> toc;

  /// 某个块在**纸面坐标系**里的纵向偏移（px）。
  ///
  /// 由调用方给（它才有分页输入），本视图只负责把它换算成屏幕滚动位置。
  final double Function(int blockIndex)? paperOffsetOfBlock;

  @override
  State<OfficeDocPaperView> createState() => _OfficeDocPaperViewState();
}

class _OfficeDocPaperViewState extends State<OfficeDocPaperView> {
  final TransformationController _transform = TransformationController();
  final ScrollController _scroll = ScrollController();
  bool _zoomed = false;
  int _pageIndex = 0;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransform);
    _scroll.removeListener(_onScroll);
    _transform.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onScroll() {
    final pagination = widget.pagination;
    if (pagination == null || pagination.isEmpty) return;
    final total = pagination.totalEstimatedHeight;
    final extent = _scroll.position.maxScrollExtent;
    // 把滚动位置换算到纸面坐标系（外层 FittedBox 有缩放）。
    final scale = total <= 0 || extent <= 0 ? 1.0 : (extent + 1) / total;
    final offset = _scroll.offset / (scale <= 0 ? 1.0 : scale);
    final index = pagination.pageIndexAtOffset(offset);
    if (index != _pageIndex) setState(() => _pageIndex = index);
  }

  /// 适宽：把缩放复位到 1（纸面本身已按可用宽度适配）。
  void _fitWidth() {
    _transform.value = Matrix4.identity();
    if (mounted) setState(() => _zoomed = false);
  }

  /// 纸面坐标 → 屏幕滚动位置的比例（外层 FittedBox 有缩放）。
  double get _paperToScreen {
    final pagination = widget.pagination;
    final total = pagination?.totalEstimatedHeight ?? 0;
    if (!_scroll.hasClients) return 1;
    final extent = _scroll.position.maxScrollExtent;
    if (total <= 0 || extent <= 0) return 1;
    return (extent + 1) / total;
  }

  /// 滚到某个块（目录条目点击 → 定位到该标题）。
  ///
  /// 定位目标是**该标题所在页**内、该标题块之前的累计估算高度；
  /// 分页是估算的（见文件头），所以这里也只是"定位到标题附近"，
  /// **不假装逐像素精确**。
  void _scrollToBlock(int blockIndex) {
    final offsetOf = widget.paperOffsetOfBlock;
    if (offsetOf == null || !_scroll.hasClients) return;
    final target = (offsetOf(blockIndex) * _paperToScreen).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openToc() async {
    final entry = await showModalBottomSheet<OfficeDocTocEntry>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _OfficeDocTocPanel(entries: widget.toc),
    );
    if (entry == null) return;
    // 面板先关掉再滚，否则滚动发生在被遮住的树上。
    await Future<void>.delayed(Duration.zero);
    _scrollToBlock(entry.blockIndex);
  }

  @override
  Widget build(BuildContext context) {
    final pagination = widget.pagination;
    final total = pagination?.pageCount ?? widget.pages.length;
    final current = total == 0 ? 0 : (_pageIndex + 1).clamp(1, total);
    return Stack(
      key: const Key('office-doc-paper'),
      children: [
        Positioned.fill(
          child: ColoredBox(
            // **固定中性灰**（不透明）——不随 App 主题变；见
            // [kOfficeDocPaperBackdrop] 的口径与真机像素读数。
            color: kOfficeDocPaperBackdrop,
            child: InteractiveViewer(
              key: const Key('office-doc-paper-viewer'),
              transformationController: _transform,
              minScale: 0.5,
              maxScale: 4,
              // 未缩放时把一指拖动让给纵向滚动；缩放后才由 viewer 平移。
              panEnabled: _zoomed,
              child: SingleChildScrollView(
                key: const Key('office-doc-paper-scroll'),
                controller: _scroll,
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const ClampingScrollPhysics(),
                // **上下留边**（左右留边在 `OfficeDocFitWidth` 里，见那里的说明：
                // 加到这里的横向 padding 会改变 FittedBox 拿到的可用宽度，
                // 而左右留边只应该在"纸本来就要缩放"时才吃掉宽度）。
                padding: const EdgeInsets.symmetric(
                  vertical: kOfficeDocPaperTopInset,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ⚠️ 这里**曾经**合成过一份"正文目录"（`_OfficeDocInlineToc`），
                    //    已按新证据**撤掉** —— 下面两件事我先前都判断错了：
                    //
                    //    ① **错判**："Drive 转码出来的 DOCX 把 TOC 域整个丢了"
                    //       ⇒ 错。当时只数了 `TOC`/`instrText`/`fldSimple`/`fldChar`，
                    //       **漏了 `w:sdt`（内容控件）**。实测 `Product spec` 的 body 是
                    //       `26×w:p + 1×w:tbl + 1×w:sdt`，该 SDT 的
                    //       `docPartGallery="Table of Contents"`，内含 **7 个 `w:p`**
                    //       （真实目录条目，带 `w:hyperlink w:anchor="_Toc…"`）；
                    //       `Student report` 内含 **9 个**。⇒ **文档自带目录**。
                    //    ② **错判**：块级 `w:sdt` 被解析器丢进 `default: break`
                    //       ⇒ 正文里只剩 "Table of Contents" 标题、下面**空着**。
                    //       已在 `office_doc_ooxml.dart` 的 `_parseBlockChildren`
                    //       修复（下钻 `w:sdtContent`）。
                    //
                    //    修复后**文档自己的目录就在正文里**（`Product spec` 27→34 块、
                    //    `Student report` 35→44 块）。再合成一份 = **同屏两份目录**，
                    //    反而离 WPS/Office 更远。
                    //
                    //    目录 UI 现在**只在文档真的有目录时**才出现
                    //    （`officeDocxHasRealToc()`，见 `OfficeDocxView`），
                    //    且只保留**浮层导航面板**；正文那份由文档自己提供。
                    OfficeDocFitWidth(
                      pageWidth: widget.metrics.pageWidth,
                      // `mainAxisSize.min`：FittedBox 给的是**无界高度**约束。
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          for (var i = 0; i < widget.pages.length; i++) ...[
                            if (i > 0) const SizedBox(height: Gap.xl),
                            if (widget.pages[i] is OfficeDocPaperPage)
                              widget.pages[i]
                            else
                              OfficeDocPaperPage(
                                metrics: widget.metrics,
                                pageIndex: i,
                                headerText: widget.headerText,
                                footerText: widget.footerText,
                                pageNumber: i + 1,
                                totalPages: widget.pages.length,
                                numberAlignment: widget.numberAlignment,
                                children: <Widget>[widget.pages[i]],
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: Gap.md,
          bottom: Gap.md,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 目录入口：**只有文档确有标题时才出现**（空文档不给空面板入口）。
              if (widget.toc.isNotEmpty) ...[
                Material(
                  color: Colors.black.withValues(alpha: 0.62),
                  shape: const StadiumBorder(),
                  child: InkWell(
                    key: const Key('office-doc-toc-button'),
                    customBorder: const StadiumBorder(),
                    onTap: () => unawaited(_openToc()),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Gap.sm,
                        vertical: Gap.xs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.list_alt_outlined,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: Gap.xxs),
                          Text(
                            // 官方原文：Drive 3.9.0 的 `string/table_of_contents`
                            // = "Table of contents" / "目录"（父 agent 用 aapt2 取证）。
                            dataText('officeDocTocTitle', '目录'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Gap.xs),
              ],
              Material(
                color: Colors.black.withValues(alpha: 0.62),
                shape: const StadiumBorder(),
                child: InkWell(
                  key: const Key('office-doc-fit-width'),
                  customBorder: const StadiumBorder(),
                  onTap: _fitWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Gap.sm,
                      vertical: Gap.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.fit_screen_outlined,
                          size: 14,
                          color: Colors.white,
                        ),
                        const SizedBox(width: Gap.xxs),
                        Text(
                          context.t.officeSheetFitWidth,
                          style: const TextStyle(fontSize: 12, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Gap.xs),
              Container(
                key: const Key('office-doc-page-indicator'),
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.sm,
                  vertical: Gap.xs,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(Radii.capsule),
                ),
                child: Text(
                  '$current / $total',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 把 A4 纸面**按可用宽度适配**（fit-width），不放大超过原始尺寸。
///
/// 用 [FittedBox] 而不是 `Transform.scale`：前者会**同时缩放布局尺寸**，
/// 所以多页滚动的高度天然正确（`Transform` 只改变绘制、不改布局）。
///
/// ## 左右留边（[kOfficeDocPaperSideInset]）为什么放在这里
/// 纸必须**比屏幕窄**，否则纸外底色与投影在左右两边看不到（真机实测：
/// 纸面铺满 x=0..1147，看不出纸的边界）。但留边**不能**做成滚动视图的
/// 横向 padding —— 那会直接把 FittedBox 的可用宽度减掉 2×inset，
/// 连"纸本来就装得下、不需要缩放"的窄屏场景也会被强行缩一次
/// （会把纸面坐标系里本来精确的尺寸整体缩掉 ~2.3%）。
///
/// 所以留边**只在真的要缩放时才吃掉宽度**：
/// * `available >= pageWidth`：纸装得下 ⇒ 保持 **1:1 不缩放**，居中；
/// * `available < pageWidth`：纸比视口宽 ⇒ 缩放到 `available − 2×inset`，
///   两边各留出 [kOfficeDocPaperSideInset] 的底色。
class OfficeDocFitWidth extends StatelessWidget {
  const OfficeDocFitWidth({
    super.key,
    required this.pageWidth,
    required this.child,
    this.sideInset = kOfficeDocPaperSideInset,
  });

  final double pageWidth;
  final Widget child;

  /// 纸面左右留边（屏上逻辑 px）；全屏宽度时可传 0 关掉。
  final double sideInset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : pageWidth;
        if (available >= pageWidth) {
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: pageWidth, child: child),
          );
        }
        // 纸比视口宽：缩到 `available − 2×inset`，两侧露出纸外底色。
        final target = (available - 2 * sideInset).clamp(1.0, pageWidth);
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: target,
            child: FittedBox(
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              child: SizedBox(width: pageWidth, child: child),
            ),
          ),
        );
      },
    );
  }
}

/// **目录浮层导航面板**（只读）：按 `Heading1..6` 缩进分级列出标题，点一条跳到该标题。
///
/// * 标题文字 = **文档里的标题原文**（不翻译、不改写）；
/// * **只读**：没有任何"改标题级别"的操作；
/// * **只在文档真的有目录时出现**（由 `OfficeDocxView` 用
///   `officeDocxHasRealToc()` 判定后传入；传空表 ⇒ 本控件与入口按钮都不出现）。
///
/// ## 配色口径（**踩过的坑，别再犯**）
/// 这个面板是 **App 外壳（chrome）**，不是文档画布 —— 所以它的文字色必须取
/// **面板自身主题的 `onSurface`**，**绝对不能用文档的缺省字色**。
/// 第一版把条目标题写死成文档色 `0xFF202124`，深色主题下面板底是深灰 ⇒
/// 深字压深底，几乎看不见。**文档墨色只属于纸面**。
///
/// ⚠️ 正文里**不再**合成第二份目录：文档自带的那份（`w:sdt` 内容控件）已经
/// 由解析层还原并渲染在正文里（见 `office_doc_ooxml.dart` 的 `_parseBlockChildren`），
/// 再合成一份就是**同屏两份目录**。
class _OfficeDocTocPanel extends StatelessWidget {
  const _OfficeDocTocPanel({required this.entries});

  final List<OfficeDocTocEntry> entries;

  /// 每级缩进（屏上逻辑 px）——**让 3 级标题的层级一眼看得出**。
  static const double _stepIndent = 16;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          key: const Key('office-doc-toc-panel'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xs),
              child: Text(
                dataText('officeDocTocTitle', '目录'),
                key: const Key('office-doc-toc-title'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (ctx, i) {
                  final e = entries[i];
                  final level = e.level.clamp(1, 6);
                  return InkWell(
                    key: Key('office-doc-toc-item-$i'),
                    onTap: () => Navigator.of(ctx).pop(e),
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: Gap.md + (level - 1) * _stepIndent,
                        right: Gap.md,
                        top: Gap.xs,
                        bottom: Gap.xs,
                      ),
                      child: Semantics(
                        // 官方原文：`string/heading_1..6` = "1 级标题".."6 级标题"。
                        label: dataText(
                          'officeDocTocLevel$level',
                          '$level 级标题',
                        ),
                        child: Row(
                          children: [
                            // 层级标记：数字 + 缩进，比纯缩进更"看得出来分了几级"。
                            SizedBox(
                              width: 20,
                              child: Text(
                                '$level',
                                key: Key('office-doc-toc-level-$i'),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                e.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                // **外壳配色**：跟面板主题的 onSurface 走，
                                // 不继承文档缺省色（见类注释里的真机踩坑记录）。
                                style: TextStyle(
                                  fontSize: level == 1 ? 15 : 14,
                                  fontWeight: level == 1
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
