// `.odoc`（Synology Office 文档）的**只读**模型（纯 Dart；不 import flutter/l10n）。
//
// 证据（`docs/office-native-format-research.md` §4.1/§9.2，官方样本 16 份
// `template/doc/*/text.json` 实测）：
//   - 顶层 section：`content` / `index` / `comment`（真实文件另有 `command` 等）；
//   - `content.data` = `{"type":"doc","attrs":{"schema":13,"type":"document",
//     "page_setup":{...}},"content":[...]}`；
//   - `content.version` 是整数（样本 `business_letter` = 111）；
//   - 正文在 `edit_area` 里；`page_decorate`（页眉/页脚/页码）是装饰层。
//
// 本批（Office 渲染重做 O1）追加：**页面尺寸/页边距**、**页眉/页脚/页码**、
// **空内容判据**（兜底文案要用）。所有字段都来自真机取证，原文见
// `docs/office-doc-redesign-report.md` §1。
//
//   * 真机 `doc.attrs.page_setup`（5 份 `.odoc` 全同）：
//     `{"page_type":"a4","orientation":"portrait",
//       "top":2.54,"bottom":2.54,"left":2.54,"right":2.54}` —— **单位 cm**
//     （A4 的 2.54cm 页边距 = 1 英寸，且与 colgroup 之和 601px 自洽：
//     (21 − 5.08) cm × 96/2.54 ≈ 601.7 px）。
//   * 真机 `page_decorate`：`header×3`（type = cover/even/normal）+ `footer×3` +
//     `page_num×1`；`attrs` = `{num-show:false, num-pos:"br", ...}`；
//     **真实样例 header/footer 内容都是空 paragraph**（无可见文字）。

import 'office_json.dart';
import 'prosemirror_model.dart';

/// 每厘米对应的像素数（96 dpi，与真机 `colgroup` 的自洽关系一致）。
const double kOdocPxPerCm = 96.0 / 2.54;

/// A4 纵向纸面尺寸（cm）。
const double kOdocA4WidthCm = 21.0;
const double kOdocA4HeightCm = 29.7;

/// `content.data.attrs.page_setup`。
///
/// 真机原文（5 份 `.odoc` 全同，单位 **cm**）：
/// ```json
/// {"page_type":"a4","orientation":"portrait",
///  "top":2.54,"bottom":2.54,"left":2.54,"right":2.54}
/// ```
class ODocPageSetup {
  const ODocPageSetup({
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.orientation,
    this.pageType,
  });

  /// 页边距（**cm**，`page_setup` 的原始单位）。
  final double? left;
  final double? top;
  final double? right;
  final double? bottom;

  /// `portrait` / `landscape`（真机 `portrait`）。
  final String? orientation;

  /// `a4`（真机 `a4`）。
  final String? pageType;

  /// A4 纵向 + 2.54cm 页边距的默认值（真机实测值），供缺字段时兜底。
  static const ODocPageSetup a4Default = ODocPageSetup(
    left: 2.54,
    top: 2.54,
    right: 2.54,
    bottom: 2.54,
    orientation: 'portrait',
    pageType: 'a4',
  );

  static ODocPageSetup fromJson(Map<String, Object?>? json) {
    return ODocPageSetup(
      left: asJsonDouble(json?['left']),
      top: asJsonDouble(json?['top']),
      right: asJsonDouble(json?['right']),
      bottom: asJsonDouble(json?['bottom']),
      orientation: asJsonString(json?['orientation']),
      pageType: asJsonString(json?['page_type']),
    );
  }

  bool get isA4 => (pageType ?? 'a4').toLowerCase() == 'a4';

  bool get isLandscape =>
      (orientation ?? 'portrait').toLowerCase() == 'landscape';

  /// 是否读到过任何 `page_setup` 字段（false = 模型里的全是默认值）。
  bool get isSpecified =>
      left != null ||
      top != null ||
      right != null ||
      bottom != null ||
      orientation != null ||
      pageType != null;

  /// 页宽（px，96 dpi）。A4 纵向 793.7 / 横向 1122.5。
  ///
  /// 非 A4 的 `page_type` 真机未取证 → 一律按 A4 尺寸呈现（报告 §6 登记），
  /// `page_type` 仍原样保留在 [pageType] 里。
  double get pageWidthPx => isLandscape
      ? kOdocA4HeightCm * kOdocPxPerCm
      : kOdocA4WidthCm * kOdocPxPerCm;

  /// 页高（px，96 dpi）。
  double get pageHeightPx => isLandscape
      ? kOdocA4WidthCm * kOdocPxPerCm
      : kOdocA4HeightCm * kOdocPxPerCm;

  double get marginLeftPx => (left ?? 2.54) * kOdocPxPerCm;
  double get marginRightPx => (right ?? 2.54) * kOdocPxPerCm;
  double get marginTopPx => (top ?? 2.54) * kOdocPxPerCm;
  double get marginBottomPx => (bottom ?? 2.54) * kOdocPxPerCm;

  /// 正文可用宽度（px）= 页宽 − 左右页边距（A4 2.54cm → ≈601.7px）。
  double get contentWidthPx {
    final w = pageWidthPx - marginLeftPx - marginRightPx;
    return w > 0 ? w : pageWidthPx;
  }

  /// 正文可用高度（px）= 页高 − 上下页边距。
  double get contentHeightPx {
    final h = pageHeightPx - marginTopPx - marginBottomPx;
    return h > 0 ? h : pageHeightPx;
  }

  @override
  String toString() =>
      'ODocPageSetup(${pageType ?? 'a4'}/${orientation ?? 'portrait'}, '
      'margin=${left ?? 2.54}cm)';
}

/// 文档只读模型。
class ODocDocument {
  ODocDocument({
    required this.schema,
    required this.version,
    required this.pageSetup,
    required this.body,
    required this.nodeTypeCounts,
    required this.commentCount,
    required this.indexSchemaVersion,
    required this.sectionNames,
    required this.pageDecorate,
    this.decorations = PmDecorations.none,
    this.headingLineHeights = const {},
    this.pageSetupSpecified = false,
  });

  /// 根 `attrs.schema`（样本实测 13）。
  final int? schema;

  /// `content.version`（协同快照版本，样本实测为整数）。
  final int? version;

  final ODocPageSetup pageSetup;

  /// 正文（`edit_area`）抽取结果。
  final PmExtraction body;

  /// 整篇文档的节点类型直方图（含装饰层；用 `_countTypes` 全量统计）。
  final Map<String, int> nodeTypeCounts;

  /// `comment.data` 条数（官方样本均为 0 条）。
  final int commentCount;

  /// `index.schemaVersion`。
  final int? indexSchemaVersion;

  final List<String> sectionNames;

  /// `page_decorate` 原始 JSON（页眉/页脚/页码）。
  final Map<String, Object?>? pageDecorate;

  /// `page_decorate` 抽出来的页眉/页脚/页码（本批：装饰进页边区域）。
  final PmDecorations decorations;

  /// `style_editor → style_paragraph` 的 `headingId → lineHeight`
  /// （真机 `_heading0..5` 全是 1.5）。
  final Map<String, double> headingLineHeights;

  /// 是否真的读到过 `page_setup`（false 时 [pageSetup] 是 A4 默认值）。
  final bool pageSetupSpecified;

  List<PmBlock> get blocks => body.blocks;

  List<PmBlock> get headings => body.headings;

  List<PmBlock> get listItems => body.listItems;

  List<PmBlock> get tables => body.tables;

  List<PmImageRef> get images => body.images;

  String get plainText => body.plainText;

  int get textLength => body.textLength;

  /// **没有任何可显示内容**（兜底文案的判据，见规格 §五）。
  bool get isEmpty => body.isEmptyContent;

  /// 该页型（`cover`/`normal`）的页眉文字（真机为空串）。
  String headerText(String kind) => decorations.headerText(kind);

  String footerText(String kind) => decorations.footerText(kind);

  /// 从 `.odoc` 解密后的 section 字典构造。
  static ODocDocument fromSections(Map<String, Object?> sections) {
    final content = asJsonMap(sections['content']) ?? const {};
    final data = asJsonMap(content['data']) ?? const {};
    final attrs = asJsonMap(data['attrs']) ?? const {};
    final rootContent = data['content'];

    final editArea = findFirstNodeByType(rootContent, 'edit_area');
    final listMap = asJsonMap(asJsonMap(editArea?['attrs'])?['listMap']);

    final body = extractProseMirror(
      editArea?['content'] ?? rootContent,
      listMap: listMap,
    );

    final counts = <String, int>{};
    countNodeTypes(rootContent, counts);

    final comment = asJsonMap(sections['comment']);
    final index = asJsonMap(sections['index']);

    final setupMap = asJsonMap(attrs['page_setup']);
    final setup = ODocPageSetup.fromJson(setupMap);

    final decorate = findFirstNodeByType(rootContent, 'page_decorate');

    return ODocDocument(
      schema: asJsonInt(attrs['schema']),
      version: asJsonInt(content['version']),
      pageSetup: setup.isSpecified ? setup : ODocPageSetup.a4Default,
      pageSetupSpecified: setup.isSpecified,
      body: body,
      nodeTypeCounts: counts,
      commentCount: (asJsonList(comment?['data']) ?? const []).length,
      indexSchemaVersion: asJsonInt(index?['schemaVersion']),
      sectionNames: sections.keys.toList(growable: false),
      pageDecorate: decorate,
      decorations: PmDecorations.fromNode(decorate),
      headingLineHeights: _headingLineHeights(rootContent),
    );
  }

  /// `style_editor → style_paragraph` 的标题层级行高（真机 `_heading0..5` = 1.5）。
  static Map<String, double> _headingLineHeights(Object? rootContent) {
    final out = <String, double>{};
    final styleEditor = findFirstNodeByType(rootContent, 'style_editor');
    for (final raw in asJsonList(styleEditor?['content']) ?? const []) {
      final node = asJsonMap(raw);
      if (asJsonString(node?['type']) != 'style_paragraph') continue;
      final attrs = asJsonMap(node?['attrs']);
      final id = asJsonString(attrs?['headingId']);
      final lh = asJsonDouble(attrs?['lineHeight']);
      if (id != null && lh != null) out[id] = lh;
    }
    return out;
  }
}
