// **OOXML（DOCX）解析** —— `.odoc` 阅读的**首要数据源**（O1 重做）。
//
// ## 为什么有这条路径（决定性事实，见 `docs/ooxml-ground-truth.md`）
// 真机实测：`SYNO.SynologyDrive.Files:download`（`files=["id:<file_id>"]`）拿回来的
// `.odoc` **不是**专有 BSON，而是 **标准 DOCX**（`PK\x03\x04` ZIP）：
// ```
// word/document.xml   21,449 B   ← 正文 + <w:sectPr>（页面尺寸/页边距）
// word/styles.xml      2,476 B   ← 命名样式（Heading1..N 的字号/段前段后）
// word/numbering.xml   2,565 B   ← 列表编号定义（● ○ ■ / %1.）
// word/header1..3.xml / word/footer1..3.xml
// word/media/image1.png
// ```
// 版式**本来就在这里**（不是从专有容器里"挤"出来的）：
//   * `<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar …="1440"/>` = **A4 +
//     2.54cm 页边距**（twips）；
//   * `<w:pStyle w:val="Heading1"/>` + `styles.xml` 的 `<w:outlineLvl>` /
//     `<w:sz>` / `<w:spacing w:before/after/line>` = **标题层级与段前段后**；
//   * `<w:rPr>` 的 `<w:b>/<w:i>/<w:u>/<w:strike>/<w:color>/<w:sz>/<w:rFonts>` =
//     **富文本**；
//   * `<w:numPr><w:ilvl/><w:numId/></w:numPr>` + `numbering.xml` 的
//     `<w:lvlText w:val="●"/>` = **真实项目符号/编号**；
//   * `<w:tblGrid><w:gridCol w:w>` = **每列声明的宽度**。
//
// ## 单位（全部有原文支撑）
//   * 长度 twips：1 twip = 1/1440 inch → **px = twips / 15**（96 dpi）。
//     A4 `11906×16838` twips → **793.7×1122.5 px**；`1440` twips → **96 px** = 2.54cm
//     ——与专有路径 `colgroup` 之和 601px ≈ `(21−5.08)cm×96/2.54` 完全自洽；
//   * 字号 `<w:sz w:val>` 是**半磅**（half-point）：`22` → 11pt、`48` → 24pt；
//   * 行距 `<w:spacing w:line="360" w:lineRule="auto">` → **360/240 = 1.5 倍**；
//     非 `auto` 的 `exact`/`atLeast` 按绝对 twips 高度换算（见
//     [ooxmlEffectiveLineHeight]），不再退回默认行距。
//   * 图片 `wp:extent cx/cy` 是 EMU：**px = emu / 9525**。
//
// ## 降级（硬要求）
// 拿不到 OOXML（离线 / 老服务端 / 权限不足 / 加密 / 不是 ZIP）时
// [ODocxDocument.parse] 返回 **null**，调用方回落到既有 OFile 路径并**明确告知用户**
// （见 `office_doc_page.dart` 的 `officeDocOoxmlUnavailable`），**绝不静默空白**。
//
// ## 未做到（报告 §6 如实登记）
//   * 浮动图形（`wp:anchor`）的环绕/定位只读尺寸，不做文字环绕排版；
//   * `w:drawing` 里的图表/形状（非图片）只登记不渲染；
//   * 脚注/尾注/批注/域代码（`w:fldSimple`/`w:instrText`）不渲染；
//   * 分栏（`w:cols num>1`）按单栏渲染；`w:tblpPr` 浮动表格按行内表格渲染。
//
// ## 本批（嵌套表格 / firstLine·hanging / lineRule）已做
//   * **嵌套表格**：`w:tc` 里的 `w:tbl` 递归成 [OOXMLBlock.table]，渲染层
//     按外层同一套规则画（表头加粗 / 列宽 / 边框 / 底色），宽度受父单元格约束；
//   * **首行缩进 / 悬挂缩进**：`w:ind/@w:firstLine` 与 `@w:hanging` 真正进版面
//     （此前 `firstLine` 只解析不渲染，整段左缩进近似）；
//   * **行距规则**：`w:lineRule` 的 `auto` / `exact` / `atLeast` 全部换算
//     （此前 `exact`/`atLeast` 直接返回 null ⇒ 退回默认行距）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// twips → px（96 dpi）。1 twip = 1/1440 inch。
const double kTwipsPerPx = 15.0;

/// EMU → px（96 dpi）。914400 EMU = 1 inch。
const double kEmuPerPx = 9525.0;

double twipsToPx(double? twips) => twips == null ? 0 : twips / kTwipsPerPx;

double emuToPx(double? emu) => emu == null ? 0 : emu / kEmuPerPx;

/// 半磅 → pt（`<w:sz w:val="22">` = 11pt）。
double halfPointsToPt(double? halfPoints) =>
    halfPoints == null ? 0 : halfPoints / 2;

/// 半磅 → pt，**缺席返回 null**（样式合并要区分"没写"和"写了 0"）。
double? optHalfPointsToPt(String? raw) {
  final v = _num(raw);
  return v == null ? null : halfPointsToPt(v);
}

// ---------------------------------------------------------------------------
// `word/theme/theme1.xml` 的颜色方案 + `w:themeColor` 引用解析
// ---------------------------------------------------------------------------

/// `word/theme/theme1.xml` 的 `<a:clrScheme>`（十二槽）。
///
/// ## 事实来源【实测】—— 槽位名与 XML 元素顺序
/// 本仓 3 份官方真样本（`test/fixtures/office_doc_redesign/*.docx`）里
/// `word/theme/theme1.xml` **都存在**（各 7030 B），逐字为：
/// ```xml
/// <a:clrScheme name="Theme1">
///   <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
///   <a:lt1><a:sysClr val="window"     lastClr="FFFFFF"/></a:lt1>
///   <a:dk2><a:srgbClr val="1F497D"/></a:dk2>
///   <a:lt2><a:srgbClr val="EEECE1"/></a:lt2>
///   <a:accent1><a:srgbClr val="4F81BD"/></a:accent1>
///   … accent2 C0504D / accent3 9BBB59 / accent4 8064A2 / accent5 4BACC6 /
///     accent6 F79646 / hlink 0000FF / folHlink 800080 …
/// </a:clrScheme>
/// ```
/// ⇒ `sysClr` 的**真实颜色在 `lastClr`**（`val="window"` 只是系统别名）。
///
/// ## ⚠️【实测】本仓真样本**没有任何地方引用**这套色板
/// ```console
/// $ grep -rc 'themeColor' product_spec/word/*.xml restaurant_menu/word/*.xml student_report/word/*.xml
/// （全部为 0）
/// ```
/// **⇒ 本节的解析在本仓真样本上【不可取证】**：它是**按 OOXML schema 的防御性实现**，
/// 不是"修复了真机显示问题"。报告里按这个口径登记，不许写成"修好了颜色"。
class OOXMLThemeScheme {
  const OOXMLThemeScheme(this.slots);

  /// 槽位名（`dk1`/`lt1`/`dk2`/`lt2`/`accent1..6`/`hlink`/`folHlink`）→ `RRGGBB`。
  final Map<String, String> slots;

  static const OOXMLThemeScheme empty = OOXMLThemeScheme(<String, String>{});

  bool get isEmpty => slots.isEmpty;

  /// `w:themeColor` 的取值（`ST_ThemeColor`）→ 槽位名。
  ///
  /// `dark1`/`text1` 与 `light1`/`background1` 是**别名对**（ECMA-376
  /// `ST_ThemeColor` 的枚举里同时有这两组写法）；Word 写 `dark1`，PowerPoint 系
  /// 写 `tx1`/`bg1`，这里一并认。
  static String? slotFor(String themeColor) => switch (themeColor) {
    'dark1' || 'text1' || 'tx1' => 'dk1',
    'light1' || 'background1' || 'bg1' => 'lt1',
    'dark2' || 'text2' || 'tx2' => 'dk2',
    'light2' || 'background2' || 'bg2' => 'lt2',
    'accent1' || 'accent2' || 'accent3' ||
    'accent4' || 'accent5' || 'accent6' => themeColor,
    'hyperlink' => 'hlink',
    'followedHyperlink' => 'folHlink',
    _ => null,
  };

  /// 取槽位原始色（`RRGGBB`，无 `#`）。
  String? rawOf(String themeColor) {
    final slot = slotFor(themeColor);
    return slot == null ? null : slots[slot];
  }

  /// 解析 `w:themeColor` + `w:themeTint`/`w:themeShade` → `#rrggbb`。
  ///
  /// [tint]/[shade] 是 `ST_UcharHexNumber`（**两位十六进制串**，如 `"99"`），
  /// 口径见 [ooxmlApplyThemeTint] / [ooxmlApplyThemeShade]。
  String? resolve(String themeColor, {String? tint, String? shade}) {
    final base = rawOf(themeColor);
    if (base == null || base.length != 6) return null;
    final rgb = _hexToRgb(base);
    if (rgb == null) return null;
    var out = rgb;
    final t = _ucharHex(tint);
    if (t != null) out = ooxmlApplyThemeTint(out, t);
    final s = _ucharHex(shade);
    if (s != null) out = ooxmlApplyThemeShade(out, s);
    return '#${out.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
  }

  @override
  String toString() => 'OOXMLThemeScheme(${slots.length} slots)';
}

List<int>? _hexToRgb(String hex) {
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  if (v == null) return null;
  return <int>[(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
}

/// `ST_UcharHexNumber` → `0..255`；不是合法的两位十六进制 → `null`。
int? _ucharHex(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty || s.length > 2) return null;
  final v = int.tryParse(s, radix: 16);
  if (v == null || v < 0 || v > 255) return null;
  return v;
}

/// `w:themeTint` —— **向白插值**（变浅）。
///
/// ## 口径（**规范推导 + 与 Word 派生色板自洽核对；本仓真样本不可实测**）
/// `themeTint` 不是 Excel/DrawingML 的 `tint="±0.4"`（那是有符号小数、且走 HLS 亮度，
/// 见同仓 `.osheet` 的 `officeSheetApplyTint`）。WordprocessingML 里它是
/// **两位十六进制串**，按 `t = value / 255` 作为白插值系数：
/// ```
/// c' = floor(c + (255 − c) × t / 255)
/// ```
///
/// ### 自洽核对（推导检验，**不是**本机实测）
/// 用 `theme1.xml` 里的 `accent1 = 4F81BD`：
/// * `themeTint="66"`（t = 102 → 0.4）→ `95B3D7` = Word 内置的
///   "Accent 1, Lighter 40%"；
/// * `themeTint="99"`（t = 153 → 0.6）→ `B8CCE4` = Word 内置的
///   "Accent 1, Lighter 60%"。
/// 两处都逐通道吻合（取 `floor`；用四舍五入会各差 1）。
///
/// ⚠️ **本仓 3 份官方 `.odoc` 真样本里 `w:themeColor` 出现 0 次**，
/// 所以这个常数**没有任何真样本可以验证**，改错也不会影响本仓真样本。
/// 报告里按"规范推导"登记。
List<int> ooxmlApplyThemeTint(List<int> rgb, int tint) {
  final t = tint.clamp(0, 255) / 255.0;
  return <int>[
    for (final c in rgb) (c + (255 - c) * t).floor().clamp(0, 255),
  ];
}

/// `w:themeShade` —— **按比例压深**（变深）。
///
/// 口径（同上，**规范推导**）：
/// ```
/// c' = floor(c × s / 255)
/// ```
/// 与 [ooxmlApplyThemeTint] 一样，**不是** Excel 的 HLS 口径。
List<int> ooxmlApplyThemeShade(List<int> rgb, int shade) {
  final s = shade.clamp(0, 255) / 255.0;
  return <int>[for (final c in rgb) (c * s).floor().clamp(0, 255)];
}

/// Word 的**高亮色名**（`<w:highlight w:val="yellow"/>`）→ `#rrggbb`。
///
/// ## 事实来源【规范推导】
/// ECMA-376 的 `ST_HighlightColor` 是**固定的 16 个具名色**（不是任意颜色）：
/// black/blue/cyan/green/magenta/red/yellow/white/darkBlue/darkCyan/darkGreen/
/// darkMagenta/darkRed/darkYellow/darkGray/lightGray/none。取值即 Word 的
/// "高亮色"调色板（Word 2010 起的取值如下表）。
/// **本仓真样本 `w:highlight` 出现 0 次 ⇒ 不可实测。**
const Map<String, String> kOoxmlHighlightColors = <String, String>{
  'black': '#000000',
  'blue': '#0000FF',
  'cyan': '#00FFFF',
  'green': '#00FF00',
  'magenta': '#FF00FF',
  'red': '#FF0000',
  'yellow': '#FFFF00',
  'white': '#FFFFFF',
  'darkBlue': '#000080',
  'darkCyan': '#008080',
  'darkGreen': '#008000',
  'darkMagenta': '#800080',
  'darkRed': '#800000',
  'darkYellow': '#808000',
  'darkGray': '#808080',
  'lightGray': '#C0C0C0',
};

/// DOCX 页面设置（`<w:sectPr>`），**已换算成 px**。
class OOXMLPageSetup {
  const OOXMLPageSetup({
    required this.widthPx,
    required this.heightPx,
    required this.marginLeftPx,
    required this.marginRightPx,
    required this.marginTopPx,
    required this.marginBottomPx,
    required this.headerPx,
    required this.footerPx,
    required this.orientation,
    required this.isA4,
    required this.rawWidthTwips,
    required this.rawHeightTwips,
  });

  /// A4 纵向 + 2.54cm 页边距（`11906×16838` / `1440`）——真机实测值。
  static const OOXMLPageSetup a4Default = OOXMLPageSetup(
    widthPx: 11906 / kTwipsPerPx,
    heightPx: 16838 / kTwipsPerPx,
    marginLeftPx: 1440 / kTwipsPerPx,
    marginRightPx: 1440 / kTwipsPerPx,
    marginTopPx: 1440 / kTwipsPerPx,
    marginBottomPx: 1440 / kTwipsPerPx,
    headerPx: 720 / kTwipsPerPx,
    footerPx: 720 / kTwipsPerPx,
    orientation: 'portrait',
    isA4: true,
    rawWidthTwips: 11906,
    rawHeightTwips: 16838,
  );

  final double widthPx;
  final double heightPx;
  final double marginLeftPx;
  final double marginRightPx;
  final double marginTopPx;
  final double marginBottomPx;
  final double headerPx;
  final double footerPx;
  final String orientation;

  /// 是否 A4（`11906×16838` twips，允许 ±2 的容差）。
  final bool isA4;

  final double? rawWidthTwips;
  final double? rawHeightTwips;

  double get contentWidthPx {
    final w = widthPx - marginLeftPx - marginRightPx;
    return w > 0 ? w : widthPx;
  }

  double get contentHeightPx {
    final h = heightPx - marginTopPx - marginBottomPx;
    return h > 0 ? h : heightPx;
  }

  static OOXMLPageSetup fromSectPr(XmlElement? sectPr) {
    if (sectPr == null) return a4Default;
    final pgSz = _kid(sectPr, 'pgSz');
    final pgMar = _kid(sectPr, 'pgMar');
    final w = _num(_wAttr(pgSz, 'w'));
    final h = _num(_wAttr(pgSz, 'h'));
    final orient = _wAttr(pgSz, 'orient') ?? 'portrait';
    if (w == null || h == null) return a4Default;
    return OOXMLPageSetup(
      widthPx: twipsToPx(w),
      heightPx: twipsToPx(h),
      marginLeftPx: twipsToPx(_num(_wAttr(pgMar, 'left')) ?? 1440),
      marginRightPx: twipsToPx(_num(_wAttr(pgMar, 'right')) ?? 1440),
      marginTopPx: twipsToPx(_num(_wAttr(pgMar, 'top')) ?? 1440),
      marginBottomPx: twipsToPx(_num(_wAttr(pgMar, 'bottom')) ?? 1440),
      headerPx: twipsToPx(_num(_wAttr(pgMar, 'header')) ?? 720),
      footerPx: twipsToPx(_num(_wAttr(pgMar, 'footer')) ?? 720),
      orientation: orient,
      isA4: (w - 11906).abs() <= 2 && (h - 16838).abs() <= 2,
      rawWidthTwips: w,
      rawHeightTwips: h,
    );
  }

  @override
  String toString() =>
      'OOXMLPageSetup($orientation, ${widthPx.toStringAsFixed(1)}x'
      '${heightPx.toStringAsFixed(1)}px, margin=${marginLeftPx.toStringAsFixed(1)})';
}

/// 一段 run（`<w:r>` + `<w:rPr>`）。
class OOXMLRun {
  const OOXMLRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.sizePt,
    this.fontFamily,
    this.highlight,
    this.image,
    this.verticalAlign,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;

  /// `<w:color w:val="#4176cc">`（原文就带 `#`；也容忍 6 位裸十六进制）。
  ///
  /// 若原文用的是 `w:themeColor` 引用，这里存的是**已解析出来的** `#rrggbb`
  /// （见 [OOXMLThemeScheme.resolve]）。
  final String? color;

  /// `<w:sz w:val>`（半磅）→ pt。
  final double? sizePt;

  /// `<w:rFonts w:ascii/w:eastAsia>`。
  final String? fontFamily;

  /// run 的文字底纹（`<w:shd w:fill>` 或 `<w:highlight w:val="yellow">`）。
  final String? highlight;

  /// run 内嵌的图片（`<w:drawing>`）。
  final OOXMLImage? image;

  /// `<w:vertAlign w:val>`：`superscript` / `subscript` / `baseline`。
  ///
  /// `baseline`（或缺失）= 正常基线；存 `null` 表示正常。
  final String? verticalAlign;

  /// 上标 / 下标（渲染层要把字号缩小并抬升/下沉基线）。
  bool get isSuperscript => verticalAlign == 'superscript';

  bool get isSubscript => verticalAlign == 'subscript';

  bool get isEmpty => text.isEmpty && image == null;

  /// 同一个 run 的样式、换一段文字（悬挂缩进要按行拆分 run）。
  OOXMLRun withText(String text) => OOXMLRun(
    text: text,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    color: color,
    sizePt: sizePt,
    fontFamily: fontFamily,
    highlight: highlight,
    image: image,
    verticalAlign: verticalAlign,
  );
}

/// run 内嵌图片（`<w:drawing><wp:extent>` + `a:blip r:embed`）。
class OOXMLImage {
  const OOXMLImage({
    this.relId,
    this.mediaPath,
    required this.widthPx,
    required this.heightPx,
    this.name,
  });

  /// `a:blip r:embed="rId5"`。
  final String? relId;

  /// 已解析出的包内路径（`word/media/image1.png`）。
  final String? mediaPath;

  final double widthPx;
  final double heightPx;
  final String? name;

  @override
  String toString() => 'OOXMLImage($mediaPath, ${widthPx}x$heightPx)';
}

/// 一个段落（`<w:p>`）。
class OOXMLParagraph {
  const OOXMLParagraph({
    required this.runs,
    this.styleId,
    this.headingLevel = 0,
    this.alignment = 'left',
    this.indentLeftPx = 0,
    this.indentFirstPx = 0,
    this.indentRightPx = 0,
    this.hangingPx = 0,
    this.spacingBeforePx = 0,
    this.spacingAfterPx = 0,
    this.lineHeight,
    this.lineRule,
    this.linePx,
    this.numId,
    this.numLevel = 0,
    this.marker,
    this.ordered = false,
    this.markerIndentPx = 0,
    this.pageBreakBefore = false,
    this.pageBreakAfter = false,
    this.shading,
  });

  final List<OOXMLRun> runs;

  /// `<w:pStyle w:val="Heading1">`。
  final String? styleId;

  /// 由 `styles.xml` 的 `<w:outlineLvl>` 或 `HeadingN` 推出（1..6；0 = 正文）。
  final int headingLevel;

  /// `left` / `center` / `right` / `justify`。
  final String alignment;

  final double indentLeftPx;
  final double indentFirstPx;
  final double indentRightPx;

  /// `<w:ind w:hanging>`（列表挂起缩进）。
  final double hangingPx;

  final double spacingBeforePx;
  final double spacingAfterPx;

  /// 倍数（`<w:spacing w:line="360" w:lineRule="auto">` → 1.5）。
  ///
  /// **只在 `lineRule="auto"` 时有值**；`exact`/`atLeast` 的绝对高度在
  /// [linePx]，倍数要等渲染层知道字号才能算（见 [ooxmlEffectiveLineHeight]）。
  final double? lineHeight;

  /// `w:spacing/@w:lineRule`：`auto` / `exact` / `atLeast`。
  /// **null = 本段落（或该样式）没有声明行距**，回退到样式链。
  final String? lineRule;

  /// `w:lineRule="exact"` / `"atLeast"` 的**绝对行高（px）**。
  ///
  /// `w:line` 是 twips → `px = twips / 15`（96 dpi）。`exact` 时不随字号变。
  final double? linePx;

  /// `<w:numPr>`。
  final int? numId;
  final int numLevel;

  /// 真实标记（`●` / `1.` / `a.`…），由 `numbering.xml` + 计数器算出。
  final String? marker;
  final bool ordered;
  final double markerIndentPx;

  /// `<w:pageBreakBefore/>`（真样本 0 处）或**本段之前**被
  /// `<w:br w:type="page"/>` 切开 ⇒ 本段起新页。
  ///
  /// 由 [ODocxDocument] 的解析层把"段中分页符"拆成两段，后一段带此标记。
  final bool pageBreakBefore;

  /// **本段之后**必须换页（`<w:br w:type="page"/>` 出现在段末）。
  final bool pageBreakAfter;

  /// 段落底纹 `<w:pPr><w:shd w:fill>`（已解析主题引用）。
  final String? shading;

  String get text => runs.map((r) => r.text).join();

  bool get isEmpty => runs.every((r) => r.isEmpty);

  bool get hasImage => runs.any((r) => r.image != null);

  bool get isListItem => numId != null;

  /// 段落里出现的最大字号（pt）—— "标题字号 ≥ 正文字号"的判据。
  double? get maxFontSizePt {
    double? out;
    for (final r in runs) {
      final v = r.sizePt;
      if (v != null && (out == null || v > out)) out = v;
    }
    return out;
  }

  @override
  String toString() =>
      'OOXMLParagraph(h$headingLevel, style=$styleId, "$text")';
}

/// 一个单元格（`<w:tc>`）。
///
/// 单元格内容按 **文档顺序** 存在 [blocks] 里：段落与**嵌套表格**（`<w:tbl>`）
/// 混排 —— Word 允许一个 `w:tc` 里既有 `w:p` 又有 `w:tbl`，顺序就是显示顺序。
/// 嵌套表格按与外层完全相同的规则递归渲染（表头加粗 / 列宽 / 边框 / 底色），
/// 宽度受**父单元格**内容宽约束（见 `office_doc_ooxml_view.dart` 的 `_table`）。
class OOXMLCell {
  const OOXMLCell({
    this.blocks = const <OOXMLBlock>[],
    this.gridSpan = 1,
    this.vMergeContinue = false,
    this.vMergeRestart = false,
    this.widthPx,
    this.shading,
    this.verticalAlign = 'top',
    this.borderTop,
    this.borderRight,
    this.borderBottom,
    this.borderLeft,
  });

  /// 单元格里的块（段落 / 嵌套表格），**保持原文顺序**。
  final List<OOXMLBlock> blocks;

  /// 只取段落（既有调用方/断言用；嵌套表格在 [tables] 里）。
  List<OOXMLParagraph> get paragraphs => <OOXMLParagraph>[
    for (final b in blocks)
      if (b.paragraph != null) b.paragraph!,
  ];

  /// 单元格里直接包含的嵌套表格（`<w:tbl>` 嵌在 `w:tc` 里）。
  List<OOXMLTable> get tables => <OOXMLTable>[
    for (final b in blocks)
      if (b.table != null) b.table!,
  ];

  bool get hasNestedTable => blocks.any((b) => b.isTable);

  /// `<w:gridSpan w:val="3">`。
  final int gridSpan;

  /// `<w:vMerge/>`（继续）与 `<w:vMerge w:val="restart"/>`。
  final bool vMergeContinue;
  final bool vMergeRestart;

  final double? widthPx;
  final String? shading;
  final String verticalAlign;

  final OOXMLBorder? borderTop;
  final OOXMLBorder? borderRight;
  final OOXMLBorder? borderBottom;
  final OOXMLBorder? borderLeft;

  String get text => paragraphs.map((p) => p.text).join('\n');

  bool get hasSpan => gridSpan > 1 || vMergeContinue || vMergeRestart;
}

/// 一条边框（`<w:tcBorders>` 的一边）。
///
/// `<w:sz>` 的单位是**八分之一磅**（eighths of a point）：`6` → 0.75pt → 1px。
class OOXMLBorder {
  const OOXMLBorder({this.widthPx = 0, this.color});

  final double widthPx;
  final String? color;

  /// 画得出来吗。
  ///
  /// OOXML 语义【规范推导】：`<w:top w:val="single" w:sz="4"/>` **不写 `w:color`**
  /// 时颜色是 `auto`（实际渲染为黑），**边框照样画**。旧实现要求 `color != null`
  /// 才算可见 ⇒ "只声明了线型与粗细、没写颜色"的边框会被**整条丢掉**。
  /// 这里改成：只要 `w:val` 不是 `nil`/`none` 且 `sz > 0` 就可见，
  /// 颜色交给渲染层兜底（[OOXMLBorder.color] 为 null ⇒ 用黑色）。
  bool get visible => widthPx > 0 && color != 'nil' && color != 'none';

  static const OOXMLBorder none = OOXMLBorder();

  static OOXMLBorder fromTcBorder(
    XmlElement? e, {
    OOXMLThemeScheme theme = OOXMLThemeScheme.empty,
  }) {
    if (e == null) return none;
    final val = _wAttr(e, 'val');
    if (val == 'nil' || val == 'none') return none;
    final sz = _num(_wAttr(e, 'sz')) ?? 0;
    // 八分之一磅 → pt → px（八分之一磅 × 4/3 / 8 = /6）。
    return OOXMLBorder(
      widthPx: sz / 6.0,
      // 颜色来自 `@w:color`（可以是主题引用 `@w:themeColor`）。
      color: _resolveBorderColor(e, theme),
    );
  }

  @override
  String toString() =>
      'OOXMLBorder(${widthPx.toStringAsFixed(2)}px, ${color ?? '-'})';
}

/// 一行（`<w:tr>`）。
class OOXMLRow {
  const OOXMLRow({
    required this.cells,
    this.heightPx,
    this.isHeader = false,
  });

  final List<OOXMLCell> cells;
  final double? heightPx;
  final bool isHeader;
}

/// 一个表格（`<w:tbl>`）。
class OOXMLTable {
  const OOXMLTable({
    required this.colWidthsPx,
    required this.rows,
    this.borders = const <String, OOXMLBorder>{},
    this.cellMarginLeftPx = kOoxmlDefaultCellMarginPx,
    this.cellMarginRightPx = kOoxmlDefaultCellMarginPx,
    this.cellMarginTopPx = 0,
    this.cellMarginBottomPx = 0,
  });

  /// `<w:tblGrid><w:gridCol w:w>`（twips → px）—— **每列声明的宽度**。
  final List<double> colWidthsPx;
  final List<OOXMLRow> rows;

  /// `<w:tblPr><w:tblBorders>` 的四边（键：`top`/`left`/`bottom`/`right`
  /// /`insideH`/`insideV`）。
  ///
  /// **单元格自己的 `<w:tcBorders>` 优先**；单元格没写的那一边才落回这里
  /// （Word 的边框继承链）。**本仓真样本 `w:tblBorders` 出现 0 次** ⇒ 只能算
  /// schema 级防御性实现。
  final Map<String, OOXMLBorder> borders;

  /// `<w:tblPr><w:tblCellMar>` 的四边内边距（px）。
  ///
  /// **实测**：真样本 `product_spec.docx` 逐字为
  /// `<w:tblCellMar><w:left w:w="90"/><w:bottom w:w="0"/><w:right w:w="90"/><w:top w:w="0"/></w:tblCellMar>`
  /// （`w:type="dxa"` = twips；90 twips = 6px）。
  /// 该样本 **top/bottom = 0** —— 旧渲染层写死 4px，**从没生效过**。
  final double cellMarginLeftPx;
  final double cellMarginRightPx;
  final double cellMarginTopPx;
  final double cellMarginBottomPx;

  double get totalWidthPx => colWidthsPx.fold<double>(0, (a, b) => a + b);

  bool get hasGrid => colWidthsPx.any((w) => w > 0);

  /// 表格级边框（某一边没声明 → [OOXMLBorder.none]）。
  OOXMLBorder borderFor(String side) => borders[side] ?? OOXMLBorder.none;
}

/// 表格**没声明** `w:tblCellMar` 时的左右内边距兜底：**6px**。
///
/// ⚠️ 口径（**别把它当成 Word 的规范默认**）：
/// * 【规范推导】Word 对表格单元格左右边距的默认是 **0.19cm ≈ 108 twips = 7.2px**；
/// * 【实测】本仓唯一声明了 `w:tblCellMar` 的真样本 `product_spec.docx` 写的是
///   `w:left/w:right = 90 dxa = 6px`；
/// * 本仓渲染层**改动前**一直是写死 6px（= 恰好等于该真样本的声明值）。
///
/// 这里**保守沿用既有 6px**：只有"文档真的声明了 `w:tblCellMar`"时才用声明值
/// （真样本 product_spec 的 `top/bottom = 0` 因此**首次**生效）。
/// 若把默认改成 7.2px，所有**没声明**该元素的文档版面都会整体左右各漂 1.2px，
/// 而那点差异既无真机取证、又会推翻既有离线用例的坐标基准。
const double kOoxmlDefaultCellMarginPx = 6;

/// 上下内边距兜底：**4px**（同样是既有渲染层写死的值，口径同上）。
const double kOoxmlDefaultCellMarginVerticalPx = 4;

/// 一个顶层块（段落或表格）。
class OOXMLBlock {
  const OOXMLBlock.paragraph(this.paragraph) : table = null;
  const OOXMLBlock.table(this.table) : paragraph = null;

  final OOXMLParagraph? paragraph;
  final OOXMLTable? table;

  bool get isTable => table != null;
}

/// `styles.xml` 的解析结果：命名样式 + 默认段落样式 id + `w:docDefaults`。
///
/// `w:docDefaults` 是**全局默认字符格式**（真机 `Product spec.odoc` 实测
/// `<w:sz w:val="22"/>` = 11pt、`Arial`）——run 既没有自己的 `w:rPr` 也没有
/// 命名样式时继承它，所以"正文字号"能拿到 11pt 而不是 null。
class OOXMLStyleSheet {
  const OOXMLStyleSheet({
    this.styles = const {},
    this.defaultParagraphId,
    this.docDefaults,
  });

  final Map<String, OOXMLStyle> styles;

  /// `<w:style w:type="paragraph" w:default="1">` 的 `styleId`（真机 `Normal`）。
  final String? defaultParagraphId;

  final OOXMLStyle? docDefaults;

  OOXMLStyle? operator [](String? id) => id == null ? null : styles[id];

  /// 段落样式的解析链（**逐字段合并**）：`w:docDefaults` → 默认段落样式
  /// （`Normal`）→ 显式 `w:pStyle`。缺失字段按这个顺序回退，所以
  /// "没写 `w:sz` 的正文"能拿到 docDefaults 的 11pt，而不是 null。
  OOXMLStyle? paragraphStyle(String? styleId) => _merge(
    docDefaults,
    _merge(this[defaultParagraphId], this[styleId]),
  );

  static OOXMLStyle? _merge(OOXMLStyle? base, OOXMLStyle? over) {
    if (base == null) return over;
    if (over == null) return base;
    // ⚠️ 行距是**一个整体**（规则 + 值），不能逐字段合并：
    // 上层只要声明了 `w:lineRule`/`w:line`，就整条覆盖下层 —— 否则
    // "上层 exact、下层 auto 1.5" 会因为 exact 的倍数为 null 而错误地
    // 退回下层的 1.5（正是本次要修的缺陷）。
    final overHasLine = over.lineRule != null;
    return OOXMLStyle(
      outlineLevel: over.outlineLevel ?? base.outlineLevel,
      sizePt: over.sizePt ?? base.sizePt,
      bold: over.bold ?? base.bold,
      italic: over.italic ?? base.italic,
      spacingBeforePx: over.spacingBeforePx != 0
          ? over.spacingBeforePx
          : base.spacingBeforePx,
      spacingAfterPx: over.spacingAfterPx != 0
          ? over.spacingAfterPx
          : base.spacingAfterPx,
      lineHeight: overHasLine ? over.lineHeight : base.lineHeight,
      lineRule: overHasLine ? over.lineRule : base.lineRule,
      linePx: overHasLine ? over.linePx : base.linePx,
      fontFamily: over.fontFamily ?? base.fontFamily,
      color: over.color ?? base.color,
    );
  }

  /// run 的兜底字符格式（无命名样式时）。
  OOXMLStyle? get runFallback => docDefaults;

  static const OOXMLStyleSheet empty = OOXMLStyleSheet();
}

/// `styles.xml` 里一个段落样式解析出来的排版默认值。
class OOXMLStyle {
  const OOXMLStyle({
    this.outlineLevel,
    this.sizePt,
    this.bold,
    this.italic,
    this.spacingBeforePx = 0,
    this.spacingAfterPx = 0,
    this.lineHeight,
    this.lineRule,
    this.linePx,
    this.fontFamily,
    this.color,
  });

  final int? outlineLevel;
  final double? sizePt;
  final bool? bold;
  final bool? italic;
  final double spacingBeforePx;
  final double spacingAfterPx;

  /// `lineRule="auto"` 时的倍数（其余规则为 null）。
  final double? lineHeight;

  /// `w:spacing/@w:lineRule`（null = 该样式没声明行距）。
  final String? lineRule;

  /// `exact`/`atLeast` 的绝对行高（px）。
  final double? linePx;

  final String? fontFamily;
  final String? color;
}

/// 解析好的 DOCX 文档模型（**纯数据**）。
class ODocxDocument {
  const ODocxDocument({
    required this.pageSetup,
    required this.blocks,
    required this.headers,
    required this.footers,
    required this.media,
    required this.styles,
    required this.numbering,
    this.theme = OOXMLThemeScheme.empty,
    this.notes = const [],
    this.hasTocContentControl = false,
  });

  final OOXMLPageSetup pageSetup;
  final List<OOXMLBlock> blocks;

  /// `word/headerN.xml` 的文字（按 `type` 分：default/first/even；真机为空）。
  final Map<String, String> headers;
  final Map<String, String> footers;

  /// 包内媒体路径 → 字节（图片按 `a:blip r:embed` 取用）。
  final Map<String, Uint8List> media;

  /// `styles.xml` 的解析结果（命名样式 + 默认段落样式 + `w:docDefaults`）。
  final OOXMLStyleSheet styles;

  /// `numId → (ilvl → 级别定义)`。
  final Map<int, Map<int, OOXMLNumberLevel>> numbering;

  /// `word/theme/theme1.xml` 的颜色方案（`w:themeColor` 引用用）。
  ///
  /// **本仓真样本里引用次数为 0**，所以这是 schema 级防御性实现（见
  /// [OOXMLThemeScheme] 的口径说明）。
  final OOXMLThemeScheme theme;

  /// 文档里是否有**真正的内容控件目录**
  /// （`w:sdt` 的 `w:docPartGallery = "Table of Contents"`）。
  ///
  /// **为什么单独记这个**：官方 `.odoc` 的"目录"就是这个内容控件，它里面的
  /// `w:p` 才是**真的目录条目**（`Product spec` 7 条 / `Student report` 9 条）。
  /// 只有**真有目录**的文档才允许出现目录 UI —— 不许按标题层级强行合成
  /// （用户原话："没有目录的 odoc 不要强行加上目录，要根据文档是否真的有目录来"）。
  final bool hasTocContentControl;

  /// 解析过程中的如实登记（未做到项，不许静默）。
  final List<String> notes;

  /// 页面上所有段落（含表格单元格里的，按文档顺序）。
  Iterable<OOXMLParagraph> get allParagraphs sync* {
    for (final b in blocks) {
      yield* _blockParagraphs(b);
    }
  }

  /// 一个块（段落 / 表格）里的所有段落 —— **递归进嵌套表格**，
  /// 否则单元格里的内层表格文字会在"搜索/字数"里凭空消失。
  static Iterable<OOXMLParagraph> _blockParagraphs(OOXMLBlock b) sync* {
    final p = b.paragraph;
    if (p != null) yield p;
    final t = b.table;
    if (t != null) {
      for (final r in t.rows) {
        for (final c in r.cells) {
          for (final inner in c.blocks) {
            yield* _blockParagraphs(inner);
          }
        }
      }
    }
  }

  /// 文档里所有表格（含**嵌套表格**，深度优先、按文档顺序）。
  Iterable<OOXMLTable> get allTables sync* {
    for (final b in blocks) {
      final t = b.table;
      if (t != null) yield* _tableAndNested(t);
    }
  }

  static Iterable<OOXMLTable> _tableAndNested(OOXMLTable t) sync* {
    yield t;
    for (final r in t.rows) {
      for (final c in r.cells) {
        for (final inner in c.tables) {
          yield* _tableAndNested(inner);
        }
      }
    }
  }

  /// 纯文本（搜索/字数用）。
  String get plainText =>
      allParagraphs.map((p) => p.text).join('\n');

  int get textLength => plainText.length;

  bool get isEmpty => blocks.isEmpty && media.isEmpty;

  /// **是否像一个 DOCX**（ZIP + `word/document.xml`）。
  static bool looksLikeDocx(Uint8List bytes) {
    if (bytes.length < 4) return false;
    // `PK\x03\x04`
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
  }

  /// 解析 DOCX 字节；**不是 DOCX / 解析失败 → 返回 null**（调用方走降级路径）。
  static ODocxDocument? parse(Uint8List bytes) {
    if (!looksLikeDocx(bytes)) return null;
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: false);
    } on Object {
      return null;
    }
    final files = <String, ArchiveFile>{};
    for (final f in archive.files) {
      if (f.isFile) files[f.name] = f;
    }
    final docFile = files['word/document.xml'];
    if (docFile == null) return null;
    final String docXml;
    try {
      docXml = utf8.decode(docFile.content, allowMalformed: true);
    } on Object {
      return null;
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(docXml);
    } on Object {
      return null;
    }
    final notes = <String>[];
    final styles = _parseStyles(files['word/styles.xml'], notes);
    final numbering = _parseNumbering(files['word/numbering.xml'], notes);
    final rels = _parseRels(files['word/_rels/document.xml.rels']);
    final theme = _parseTheme(files['word/theme/theme1.xml'], notes);

    final body = doc.rootElement.childElements
        .where((e) => e.name.local == 'body')
        .firstOrNull;
    if (body == null) return null;

    final counters = <String, List<int>>{};
    // ★ 走共享收集器：它会下钻 `w:sdt`（文档自带的目录就在里面）。
    var hasTocControl = false;
    final blocks = _parseBlockChildren(
      body,
      styles: styles,
      numbering: numbering,
      counters: counters,
      rels: rels,
      theme: theme,
      notes: notes,
      onSdt: (sdt) {
        if (hasTocControl) return;
        for (final g in sdt.descendants.whereType<XmlElement>()) {
          if (g.name.local == 'docPartGallery' &&
              (_wAttr(g, 'val') ?? '').trim().toLowerCase() ==
                  'table of contents') {
            hasTocControl = true;
            return;
          }
        }
      },
    );
    // 最后一个 sectPr 也可能是 body 的直接子节点。
    final sectPr = body.childElements
        .where((e) => e.name.local == 'sectPr')
        .lastOrNull;

    final headers = <String, String>{};
    final footers = <String, String>{};
    _collectHeaderFooter(files, rels, headers, footers, notes);

    final media = <String, Uint8List>{};
    for (final e in files.entries) {
      if (e.key.startsWith('word/media/')) {
        media[e.key] = e.value.content;
      }
    }

    return ODocxDocument(
      pageSetup: OOXMLPageSetup.fromSectPr(sectPr),
      blocks: blocks,
      headers: headers,
      footers: footers,
      media: media,
      styles: styles,
      numbering: numbering,
      theme: theme,
      notes: notes,
      hasTocContentControl: hasTocControl,
    );
  }

  /// 按 `a:blip r:embed` 找到媒体字节。
  Uint8List? mediaFor(String? mediaPath) =>
      mediaPath == null ? null : media[mediaPath];
}

/// 列表一个级别的定义（`<w:lvl>`）。
class OOXMLNumberLevel {
  const OOXMLNumberLevel({
    required this.start,
    required this.format,
    required this.text,
    this.indentLeftPx = 0,
    this.hangingPx = 0,
  });

  final int start;

  /// `bullet` / `decimal` / `lowerLetter` / `upperRoman` / `none`。
  final String format;

  /// `<w:lvlText w:val="●">`（可能含 `%1` 占位）。
  final String text;

  final double indentLeftPx;
  final double hangingPx;

  bool get isBullet => format == 'bullet' || format == 'none';

  /// 按 [value] 渲染标记（`%1` → 序号）。
  String render(int value) {
    if (isBullet) return text;
    var out = text;
    for (var i = 1; i <= 9; i++) {
      out = out.replaceAll('%$i', _format(value, format));
    }
    if (!out.contains(RegExp(r'\d')) && _looksLikeNumbered(out) == false) {
      // lvlText 缺失时兜底成 "n."
      if (out.isEmpty) out = '${_format(value, format)}.';
    }
    return out;
  }

  static bool _looksLikeNumbered(String s) => RegExp(r'[0-9a-zA-Z]').hasMatch(s);
}

String _format(int value, String format) {
  switch (format) {
    case 'lowerLetter':
      return _letters(value).toLowerCase();
    case 'upperLetter':
      return _letters(value).toUpperCase();
    case 'lowerRoman':
      return _roman(value).toLowerCase();
    case 'upperRoman':
      return _roman(value).toUpperCase();
    case 'decimalZero':
      return value.toString().padLeft(2, '0');
    default:
      return '$value';
  }
}

String _letters(int n) {
  var v = n;
  final out = StringBuffer();
  while (v > 0) {
    v -= 1;
    out.write(String.fromCharCode(97 + (v % 26)));
    v ~/= 26;
  }
  return out.toString().split('').reversed.join();
}

String _roman(int n) {
  const table = <List<Object>>[
    [1000, 'M'], [900, 'CM'], [500, 'D'], [400, 'CD'],
    [100, 'C'], [90, 'XC'], [50, 'L'], [40, 'XL'],
    [10, 'X'], [9, 'IX'], [5, 'V'], [4, 'IV'], [1, 'I'],
  ];
  var v = n;
  final out = StringBuffer();
  for (final row in table) {
    final value = row[0] as int;
    final sym = row[1] as String;
    while (v >= value) {
      out.write(sym);
      v -= value;
    }
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// 解析内部
// ---------------------------------------------------------------------------

Iterable<XmlElement> _kids(XmlElement? e, String local) => e == null
    ? const <XmlElement>[]
    : e.childElements.where((c) => c.name.local == local);

XmlElement? _kid(XmlElement? e, String local) => _kids(e, local).firstOrNull;

/// 取任意命名空间下的属性（DOCX 属性带 `w:`/`r:` 前缀，`getAttribute` 认不出）。
String? _wAttr(XmlElement? e, String local) {
  if (e == null) return null;
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

double? _num(String? s) => s == null ? null : double.tryParse(s.trim());

/// twips → px，**缺席返回 null**（用于"没写就继承"的字段）。
double? _pxOrNull(double? twips) => twips == null ? null : twipsToPx(twips);

bool _onOff(XmlElement? e, {bool defaultValue = false}) {
  if (e == null) return defaultValue;
  final v = _wAttr(e, 'val');
  if (v == null) return true;
  final t = v.trim().toLowerCase();
  return t != '0' && t != 'false' && t != 'off';
}

OOXMLStyleSheet _parseStyles(ArchiveFile? file, List<String> notes) {
  final out = <String, OOXMLStyle>{};
  if (file == null) {
    notes.add('缺 word/styles.xml → 标题层级/段前段后按内置默认（Word 习惯值）呈现');
    return OOXMLStyleSheet.empty;
  }
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
  } on Object {
    notes.add('word/styles.xml 解析失败 → 用内置默认样式');
    return OOXMLStyleSheet.empty;
  }
  // `w:docDefaults`：全局默认字符格式（真机 sz=22 → 11pt / Arial）。
  OOXMLStyle? docDefaults;
  var defaultParagraphId = 'Normal';
  for (final dd in doc.rootElement.childElements.where(
    (e) => e.name.local == 'docDefaults',
  )) {
    final rPr = _kid(_kid(dd, 'rPrDefault'), 'rPr');
    final pPr = _kid(_kid(dd, 'pPrDefault'), 'pPr');
    final spacing = _kid(pPr, 'spacing');
    final ls = _lineSpacing(spacing);
    docDefaults = OOXMLStyle(
      sizePt: optHalfPointsToPt(_wAttr(_kid(rPr, 'sz'), 'val')),
      bold: _kid(rPr, 'b') == null ? null : _onOff(_kid(rPr, 'b')),
      italic: _kid(rPr, 'i') == null ? null : _onOff(_kid(rPr, 'i')),
      fontFamily: _fontFamily(_kid(rPr, 'rFonts')),
      color: _wAttr(_kid(rPr, 'color'), 'val'),
      lineHeight: ls.height,
      lineRule: ls.rule,
      linePx: ls.px,
    );
  }
  for (final st in doc.rootElement.childElements.where(
    (e) => e.name.local == 'style',
  )) {
    final id = _wAttr(st, 'styleId');
    if (id != null && _wAttr(st, 'type') == 'paragraph' && _wAttr(st, 'default') == '1') {
      defaultParagraphId = id;
    }
    if (id == null || id.isEmpty) continue;
    final pPr = _kid(st, 'pPr');
    final rPr = _kid(st, 'rPr');
    final spacing = _kid(pPr ?? st, 'spacing');
    final ls = _lineSpacing(spacing);
    final outline = _num(_wAttr(_kid(pPr ?? st, 'outlineLvl'), 'val'));
    final fonts = _kid(rPr ?? st, 'rFonts');
    out[id] = OOXMLStyle(
      outlineLevel: outline?.toInt(),
      sizePt: optHalfPointsToPt(_wAttr(_kid(rPr ?? st, 'sz'), 'val')),
      bold: _kid(rPr ?? st, 'b') == null ? null : _onOff(_kid(rPr ?? st, 'b')),
      italic: _kid(rPr ?? st, 'i') == null ? null : _onOff(_kid(rPr ?? st, 'i')),
      spacingBeforePx: twipsToPx(_num(_wAttr(spacing, 'before'))),
      spacingAfterPx: twipsToPx(_num(_wAttr(spacing, 'after'))),
      lineHeight: ls.height,
      lineRule: ls.rule,
      linePx: ls.px,
      fontFamily: _fontFamily(fonts),
      color: _wAttr(_kid(rPr ?? st, 'color'), 'val'),
    );
  }
  return OOXMLStyleSheet(
    styles: out,
    defaultParagraphId: defaultParagraphId,
    docDefaults: docDefaults,
  );
}

/// 从一个 `w:spacing` 元素解出行距三元组（规则 + auto 倍数 + 绝对 px）。
///
/// `rule == null` 表示**这段（样式）根本没声明行距**（只有 `w:before`/`w:after`
/// 而没有 `w:line` 时会走到这里，真机 `product_spec.docx` 就有这种
/// `<w:spacing w:before="200" w:lineRule="auto"/>`）—— 这时样式链继续向下回退，
/// 不能被"空覆盖"掉。
({double? height, String? rule, double? px}) _lineSpacing(XmlElement? spacing) {
  final line = _num(_wAttr(spacing, 'line'));
  if (line == null || line <= 0) {
    return (height: null, rule: null, px: null);
  }
  final rule = _wAttr(spacing, 'lineRule') ?? 'auto';
  return (
    height: ooxmlAutoLineMultiple(line, rule),
    rule: rule,
    px: ooxmlLinePx(line, rule),
  );
}

/// pt → px（96 dpi）。1 pt = 1/72 inch = 4/3 px。
///
/// 与 `office_doc_paper.dart` 的 `kOdocPtToPx` **同值**（那个在 Flutter 侧，
/// 本文件是纯 Dart 解析层，不反向依赖 UI）。
const double kOoxmlPtToPx = 96.0 / 72.0;

/// 单倍行距的**自然行高倍数**（`lineRule="atLeast"` 的兜底下界）。
///
/// "自然行高"= 没有 `w:line` 时文字本身占的高度。本模型里 `auto` 的
/// `240` twips 就是 Word 的"单倍"，故自然倍数按 **1.0** 记 —— 与
/// `w:line="240" w:lineRule="auto"`（= 1.0 倍）自洽。
const double kOoxmlNaturalLineMultiple = 1.0;

/// `w:spacing/@w:line` 在 `auto` 规则下的倍数（`240` → 1.0；`360` → 1.5）。
///
/// 非 `auto` 规则返回 **null**（绝对高度见 [ooxmlLinePx]）。
double? ooxmlAutoLineMultiple(double? lineTwips, String? rule) {
  if ((rule ?? 'auto') != 'auto') return null;
  if (lineTwips == null || lineTwips <= 0) return null;
  return lineTwips / 240.0;
}

/// `w:spacing/@w:line` 在 `exact`/`atLeast` 规则下的**绝对行高（px）**。
///
/// `w:line` 此时是 twips（1/1440 inch）→ px = twips / 15（96 dpi）。
/// `auto` 规则返回 null。
double? ooxmlLinePx(double? lineTwips, String? rule) {
  switch (rule) {
    case 'exact':
    case 'atLeast':
      if (lineTwips == null || lineTwips <= 0) return null;
      return twipsToPx(lineTwips);
    default:
      return null;
  }
}

/// 把 `w:spacing` 的 `(line, lineRule)` **统一换算成渲染层的行高倍数**。
///
/// * `auto`：`w:line` 是 **240 分之一行**（`360` → 1.5 倍）；
/// * `exact`：`w:line` 是**精确 twips 高度**，不随字号变
///   → 倍数 = 绝对高度 / 字号高度（字号变大，倍数变小，**绝对高度不变**）；
/// * `atLeast`：取 `max(自然行高, 该值)` → 倍数 = max(自然倍数, 绝对高度/字号)；
/// * 没有任何绝对高度时回退 [autoMultiple]（样式链给的 `auto` 倍数）。
///
/// [fontSizePt] 为 0/负（拿不到字号）时按 **11pt** 兜底（真机正文实测 11pt）。
double? ooxmlEffectiveLineHeight({
  required String? rule,
  required double? linePx,
  required double? autoMultiple,
  required double? fontSizePt,
}) {
  final r = rule ?? 'auto';
  if (r == 'auto') return autoMultiple;
  final px = linePx ?? 0;
  if (px <= 0) return autoMultiple;
  final pt = (fontSizePt == null || fontSizePt <= 0) ? 11.0 : fontSizePt;
  final sizePx = pt * kOoxmlPtToPx;
  final ratio = px / sizePx;
  if (r == 'exact') return ratio;
  // atLeast：至少这么高 ⇒ 取自然行高与该值的较大者。
  final natural = autoMultiple ?? kOoxmlNaturalLineMultiple;
  return ratio > natural ? ratio : natural;
}

String? _fontFamily(XmlElement? fonts) {
  if (fonts == null) return null;
  final v = _wAttr(fonts, 'eastAsia') ??
      _wAttr(fonts, 'ascii') ??
      _wAttr(fonts, 'hAnsi') ??
      _wAttr(fonts, 'cs');
  if (v == null || v.isEmpty) return null;
  return v.replaceAll('"', '').trim();
}

/// `word/theme/theme1.xml` → `<a:clrScheme>` 十二槽。
///
/// ## 事实来源
/// * 槽位名/元素顺序/`sysClr.lastClr`：**实测**（3 份官方真样本的 theme1.xml，
///   逐字见 [OOXMLThemeScheme] 的文档注释）；
/// * `w:themeColor` 引用：**本仓真样本 0 次** ⇒ 引用解析是 schema 级防御性实现。
OOXMLThemeScheme _parseTheme(ArchiveFile? file, List<String> notes) {
  if (file == null) return OOXMLThemeScheme.empty;
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
  } on Object {
    notes.add('word/theme/theme1.xml 解析失败 → 文档引用的主题色退回字面色/默认色');
    return OOXMLThemeScheme.empty;
  }
  final slots = <String, String>{};
  // `a:clrScheme` 在 `a:themeElements` 下（契约元素，不是 `<a:theme>` 的直接子节点）。
  final scheme = <XmlElement>[
    ...doc.rootElement.descendants.whereType<XmlElement>(),
  ].where((e) => e.name.local == 'clrScheme').firstOrNull;
  if (scheme == null) return OOXMLThemeScheme.empty;
  for (final slot in scheme.childElements) {
    final name = slot.name.local;
    // `srgbClr@val` 是字面色；`sysClr@lastClr` 是系统色的**实际取值**
    // （`sysClr@val` 只是 `window`/`windowText` 这类别名，解不出十六进制）。
    final srgb = slot.childElements
        .where((e) => e.name.local == 'srgbClr')
        .firstOrNull;
    final sys = slot.childElements
        .where((e) => e.name.local == 'sysClr')
        .firstOrNull;
    final raw = (srgb == null ? null : _wAttr(srgb, 'val')) ??
        (sys == null ? null : (_wAttr(sys, 'lastClr') ?? _wAttr(sys, 'val')));
    if (raw != null && raw.length == 6) slots[name] = raw;
  }
  return OOXMLThemeScheme(slots);
}

Map<int, Map<int, OOXMLNumberLevel>> _parseNumbering(
  ArchiveFile? file,
  List<String> notes,
) {
  final abstractLevels = <int, Map<int, OOXMLNumberLevel>>{};
  final numToAbstract = <int, int>{};
  if (file == null) return {};
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
  } on Object {
    notes.add('word/numbering.xml 解析失败 → 列表标记退回默认符号/序号');
    return {};
  }
  final root = doc.rootElement;
  for (final an in root.childElements.where(
    (e) => e.name.local == 'abstractNum',
  )) {
    final id = _num(_wAttr(an, 'abstractNumId'))?.toInt();
    if (id == null) continue;
    final levels = <int, OOXMLNumberLevel>{};
    for (final lvl in _kids(an, 'lvl')) {
      final ilvl = _num(_wAttr(lvl, 'ilvl'))?.toInt() ?? 0;
      final pPr = _kid(lvl, 'pPr');
      final ind = pPr == null ? null : _kid(pPr, 'ind');
      final lvlText = _wAttr(_kid(lvl, 'lvlText'), 'val') ?? '';
      final fmt = _wAttr(_kid(lvl, 'numFmt'), 'val') ?? 'decimal';
      final start = _num(_wAttr(_kid(lvl, 'start'), 'val'))?.toInt() ?? 1;
      levels[ilvl] = OOXMLNumberLevel(
        start: start,
        format: fmt,
        text: lvlText,
        indentLeftPx: twipsToPx(_num(_wAttr(ind, 'left'))),
        hangingPx: twipsToPx(_num(_wAttr(ind, 'hanging'))),
      );
    }
    abstractLevels[id] = levels;
  }
  for (final n in root.childElements.where((e) => e.name.local == 'num')) {
    final numId = _num(_wAttr(n, 'numId'))?.toInt();
    final absId = _num(_wAttr(_kid(n, 'abstractNumId'), 'val'))?.toInt();
    if (numId != null && absId != null) numToAbstract[numId] = absId;
  }
  final out = <int, Map<int, OOXMLNumberLevel>>{};
  for (final e in numToAbstract.entries) {
    final levels = abstractLevels[e.value];
    if (levels != null) out[e.key] = levels;
  }
  return out;
}

class _Rels {
  _Rels(this._byId, this._typeTargets);

  final Map<String, String> _byId;
  final Map<String, List<String>> _typeTargets;

  String? target(String? id) => id == null ? null : _byId[id];

  List<String> refsByType(String typeSuffix) =>
      _typeTargets[typeSuffix] ?? const <String>[];

  /// `rId` → 包内路径（`media/image1.png` → `word/media/image1.png`）。
  String? mediaPath(String? id) {
    final resolved = target(id);
    if (resolved == null) return null;
    if (resolved.startsWith('/')) return resolved.substring(1);
    return 'word/$resolved';
  }

  static final _Rels empty = _Rels(const {}, const {});
}

_Rels _parseRels(ArchiveFile? file) {
  if (file == null) return _Rels.empty;
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
  } on Object {
    return _Rels.empty;
  }
  final byId = <String, String>{};
  final byType = <String, List<String>>{};
  for (final r in doc.rootElement.childElements.where(
    (e) => e.name.local == 'Relationship',
  )) {
    final id = r.getAttribute('Id');
    final target = r.getAttribute('Target');
    final type = r.getAttribute('Type') ?? '';
    if (id == null || target == null) continue;
    byId[id] = target;
    for (final suffix in const ['header', 'footer', 'image']) {
      if (type.toLowerCase().endsWith('/$suffix')) {
        byType.putIfAbsent(suffix, () => <String>[]).add(id);
        break;
      }
    }
  }
  return _Rels(byId, byType);
}

void _collectHeaderFooter(
  Map<String, ArchiveFile> files,
  _Rels rels,
  Map<String, String> headers,
  Map<String, String> footers,
  List<String> notes,
) {
  for (final kind in const ['header', 'footer']) {
    final ids = rels.refsByType(kind);
    for (var i = 0; i < ids.length; i++) {
      final target = rels.target(ids[i]);
      if (target == null) continue;
      final name = target.startsWith('/') ? target.substring(1) : 'word/$target';
      final f = files[name];
      if (f == null) continue;
      final XmlDocument doc;
      try {
        doc = XmlDocument.parse(utf8.decode(f.content, allowMalformed: true));
      } on Object {
        continue;
      }
      final text = doc.rootElement.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 't')
          .map((e) => e.innerText)
          .join();
      // 真机 3 个 header/footer 都是空段落；用序号当 key（default/first/even
      // 的真实语义在 `w:sectPr` 的 headerReference type 里，见下）。
      final key = '$kind${i + 1}';
      if (kind == 'header') {
        headers[key] = text;
      } else {
        footers[key] = text;
      }
    }
  }
  if (headers.values.every((t) => t.trim().isEmpty) &&
      footers.values.every((t) => t.trim().isEmpty) &&
      (headers.isNotEmpty || footers.isNotEmpty)) {
    notes.add('页眉/页脚存在但内容为空（真机 5 份 .odoc 实测同）→ 不在纸面上占位');
  }
}

/// 解析一个 `<w:p>`，返回**一个或多个** [OOXMLParagraph]。
///
/// ## 为什么要返回多个
/// 段中/段末的 `<w:br w:type="page"/>` 在 Word 里是**真分页符**：它把这一段的
/// 后续内容推到新的一页。本模型里"分页"是**块级**属性（`pageBreakBefore` /
/// `pageBreakAfter`），所以这里把它**拆成两段**，后一段带 `pageBreakBefore`。
///
/// 真样本情况【实测】：
/// * `w:pageBreakBefore`：3 份官方样本 **0 处**；
/// * `<w:br>`：只有 `student_report.docx` 有 **1 处**，且是**无名 `<w:br/>`**
///   （= 软换行，不是分页）⇒ 真样本里**没有**分页符，本能力**不可真机取证**。
/// 把容器（`w:body` / `w:sdtContent` / `w:tc`）的直接子元素按**文档顺序**收成块。
///
/// ★★ **关键：`w:sdt`（内容控件）必须下钻 `w:sdtContent` 再收。**
/// 真实 `.odoc` 的"目录"就是一个 `w:sdt`（`w:docPartGallery = "Table of Contents"`），
/// 里面 7/9 个 `w:p` 是**真正的目录条目**（`w:hyperlink w:anchor="_Toc…"`）。
/// 旧实现只认 `p`/`tbl`，`w:sdt` 落进 `default: break` ⇒
/// **文档自带的目录被整个丢掉**，正文里只剩 "Table of Contents" 标题、下面空着。
/// （真机取证：`Product spec` body = 26×`w:p` + 1×`w:tbl` + **1×`w:sdt`**，
/// 解析结果却只有 27 块，目录 7 条一条都不在。）
List<OOXMLBlock> _parseBlockChildren(
  XmlElement container, {
  required OOXMLStyleSheet styles,
  required Map<int, Map<int, OOXMLNumberLevel>> numbering,
  required Map<String, List<int>> counters,
  required _Rels rels,
  required OOXMLThemeScheme theme,
  required List<String> notes,
  void Function(XmlElement sdt)? onSdt,
}) {
  final out = <OOXMLBlock>[];
  void walk(XmlElement parent) {
    for (final el in parent.childElements) {
      switch (el.name.local) {
        case 'p':
          out.addAll(
            _parseParagraphBlocks(
              el,
              styles: styles,
              numbering: numbering,
              counters: counters,
              rels: rels,
              theme: theme,
              notes: notes,
            ).map(OOXMLBlock.paragraph),
          );
        case 'tbl':
          out.add(
            OOXMLBlock.table(
              _parseTable(el, styles, numbering, rels, theme, notes),
            ),
          );
        case 'sdt':
          onSdt?.call(el);
          final content = _kid(el, 'sdtContent');
          if (content != null) walk(content);
        case 'sdtContent':
          walk(el);
        default:
          break;
      }
    }
  }
  walk(container);
  return out;
}

List<OOXMLParagraph> _parseParagraphBlocks(
  XmlElement p, {
  required OOXMLStyleSheet styles,
  required Map<int, Map<int, OOXMLNumberLevel>> numbering,
  required Map<String, List<int>> counters,
  required _Rels rels,
  required OOXMLThemeScheme theme,
  required List<String> notes,
}) {
  final pPr = _kid(p, 'pPr');
  final styleId = _wAttr(pPr == null ? null : _kid(pPr, 'pStyle'), 'val');
  final style = styles.paragraphStyle(styleId);
  final runFallback = style ?? styles.runFallback;

  // `w:jc`
  final jc = _wAttr(pPr == null ? null : _kid(pPr, 'jc'), 'val');
  final alignment = switch (jc) {
    'center' => 'center',
    'right' || 'end' => 'right',
    'both' || 'distribute' => 'justify',
    _ => 'left',
  };

  final ind = pPr == null ? null : _kid(pPr, 'ind');
  final spacing = pPr == null ? null : _kid(pPr, 'spacing');

  // `w:pageBreakBefore`（本段之前强制分页）。
  final breakBefore = pPr != null && _kid(pPr, 'pageBreakBefore') != null
      ? _onOff(_kid(pPr, 'pageBreakBefore'), defaultValue: true)
      : false;

  // `w:pPr/w:shd`（段落底纹，与 run 的 `w:shd` 不是同一件事）。
  final paragraphShading = _resolveFill(_kid(pPr, 'shd'), theme);

  // `w:numPr`
  final numPr = pPr == null ? null : _kid(pPr, 'numPr');
  final numId = numPr == null
      ? null
      : _num(_wAttr(_kid(numPr, 'numId'), 'val'))?.toInt();
  final ilvl = numPr == null
      ? 0
      : (_num(_wAttr(_kid(numPr, 'ilvl'), 'val'))?.toInt() ?? 0);

  String? marker;
  var ordered = false;
  var markerIndentPx = 0.0;
  OOXMLNumberLevel? numLevelDef;
  if (numId != null) {
    final levels = numbering[numId];
    final level = levels?[ilvl];
    numLevelDef = level;
    if (level == null) {
      notes.add('numId=$numId ilvl=$ilvl 在 numbering.xml 里找不到 → 标记按默认');
      marker = ilvl == 0 ? '•' : '◦';
    } else {
      final counterKey = '$numId:$ilvl';
      final list = counters.putIfAbsent(
        counterKey,
        () => List<int>.filled(9, 0),
      );
      // 更深的层级重置子层计数（Word 语义）。
      for (var i = ilvl + 1; i < list.length; i++) {
        list[i] = 0;
      }
      final value = list[ilvl] == 0
          ? (level.start == 0 ? 1 : level.start)
          : list[ilvl] + 1;
      list[ilvl] = value;
      marker = level.render(value);
      ordered = !level.isBullet;
      markerIndentPx = level.hangingPx > 0
          ? level.hangingPx
          : level.indentLeftPx * 0.2;
    }
  } else {
    // 列表结束 → 清掉所有计数器（编号重新从 1 开始）。
    counters.clear();
  }

  // ---- 收集 run，并记下 `<w:br w:type="page"/>` 的位置 ----
  final flat = <OOXMLRun>[];
  // 分页符出现在 flat 的该下标**之前**（`flat.length` = 段末）。
  final breakPositions = <int>[];

  void addRun(_ParsedRun pr) {
    if (!pr.run.isEmpty) flat.add(pr.run);
    for (var i = 0; i < pr.pageBreaks; i++) {
      breakPositions.add(flat.length);
    }
  }

  for (final el in p.childElements) {
    switch (el.name.local) {
      case 'r':
        addRun(_parseRun(el, runFallback, rels, theme, notes));
      case 'hyperlink':
        for (final r in _kids(el, 'r')) {
          addRun(_parseRun(r, runFallback, rels, theme, notes));
        }
      case 'ins':
        for (final r in el.childElements.where((e) => e.name.local == 'r')) {
          addRun(_parseRun(r, runFallback, rels, theme, notes));
        }
      case 'smartTag':
      case 'sdt':
      case 'sdtContent':
        for (final r in el.descendants.whereType<XmlElement>()) {
          if (r.name.local == 'r') {
            addRun(_parseRun(r, runFallback, rels, theme, notes));
          }
        }
      default:
        break;
    }
  }

  // 段落级 rPr 作为 run 的兜底（Word 里 `<w:pPr><w:rPr>` 是段落默认字符格式）。
  final paraRPr = pPr == null ? null : _kid(pPr, 'rPr');
  final paraStyle = paraRPr == null
      ? null
      : _parseStyleFromRPr(paraRPr, style, theme);

  final headingLevel = _headingLevel(styleId, style);

  // `w:hanging` 与 `w:firstLine` 在 OOXML 里**互斥**（同时出现时以 hanging 为准，
  // 首行额外缩进视为 0）。列表标记用的就是 hanging，不能被 firstLine 干扰。
  final hangingTw = _num(_wAttr(ind, 'hanging'));
  final firstLineTw = (hangingTw != null && hangingTw > 0)
      ? null
      : _num(_wAttr(ind, 'firstLine'));
  final ls = _lineSpacing(spacing);

  // 段前/段后：**段落自己声明就覆盖样式**（Word 语义）。
  // 旧实现是 `本段 + 样式` 相加 ⇒ 例如 `product_spec.docx` 的
  // `<w:spacing w:before="200"/>` 会变成 200 + Heading1 样式的 300 = 500 twips
  // （33px，实际只需 13px），标题上方被撑开一大截。
  final beforeTw = _num(_wAttr(spacing, 'before'));
  final afterTw = _num(_wAttr(spacing, 'after'));

  // ---- 按分页符切段 ----
  final segments = <List<OOXMLRun>>[];
  final segmentBreakBefore = <bool>[];
  var start = 0;
  var pendingBreak = breakBefore;
  for (final pos in breakPositions) {
    if (pos < start) continue;
    segments.add(flat.sublist(start, pos));
    segmentBreakBefore.add(pendingBreak);
    pendingBreak = true;
    start = pos;
  }
  // 末尾还有分页符 ⇒ 最后一段**之后**换页（不额外造一个空段）。
  final trailingBreak =
      pendingBreak && segments.isNotEmpty && start >= flat.length;
  if (start < flat.length || segments.isEmpty) {
    segments.add(flat.sublist(start));
    segmentBreakBefore.add(pendingBreak);
  }

  OOXMLParagraph build(List<OOXMLRun> seg, bool pb, bool pa) => OOXMLParagraph(
    runs: _applyParagraphDefaults(seg, paraStyle),
    styleId: styleId,
    headingLevel: headingLevel,
    alignment: alignment,
    // 段落没写 `w:ind` 时，缩进来自 **numbering.xml 的层级定义**
    // （Word 语义：`<w:lvl><w:pPr><w:ind w:left="450" w:hanging="450"/>`）。
    indentLeftPx:
        _pxOrNull(_num(_wAttr(ind, 'left'))) ??
        (numLevelDef?.indentLeftPx ?? 0),
    indentFirstPx: twipsToPx(firstLineTw),
    indentRightPx: twipsToPx(_num(_wAttr(ind, 'right'))),
    hangingPx: _pxOrNull(hangingTw) ?? (numLevelDef?.hangingPx ?? 0),
    spacingBeforePx: beforeTw != null
        ? twipsToPx(beforeTw)
        : (style?.spacingBeforePx ?? 0),
    spacingAfterPx: afterTw != null
        ? twipsToPx(afterTw)
        : (style?.spacingAfterPx ?? 0),
    // 行距：本段声明优先；本段只声明了 `auto` 倍数就沿用；本段没声明才回退样式。
    lineHeight: ls.height ?? style?.lineHeight,
    lineRule: ls.rule ?? style?.lineRule,
    linePx: ls.rule != null ? ls.px : style?.linePx,
    numId: numId,
    numLevel: ilvl,
    marker: marker,
    ordered: ordered,
    markerIndentPx: markerIndentPx,
    pageBreakBefore: pb,
    pageBreakAfter: pa,
    shading: paragraphShading,
  );

  final out = <OOXMLParagraph>[];
  for (var i = 0; i < segments.length; i++) {
    out.add(
      build(
        segments[i],
        segmentBreakBefore[i],
        trailingBreak && i == segments.length - 1,
      ),
    );
  }
  return out;
}

int _headingLevel(String? styleId, OOXMLStyle? style) {
  final outline = style?.outlineLevel;
  if (outline != null) return (outline + 1).clamp(0, 9);
  final id = styleId ?? '';
  final m = RegExp(r'(?:heading|Heading|标题)\s*(\d+)').firstMatch(id);
  if (m != null) return int.tryParse(m.group(1)!) ?? 0;
  return 0;
}

/// 段落默认字符格式（`<w:pPr><w:rPr>`）——run 没写就继承。
OOXMLRun? _parseStyleFromRPr(
  XmlElement rPr,
  OOXMLStyle? style,
  OOXMLThemeScheme theme,
) {
  final sz = halfPointsToPt(_num(_wAttr(_kid(rPr, 'sz'), 'val')));
  final vertAlign = _wAttr(_kid(rPr, 'vertAlign'), 'val');
  return OOXMLRun(
    text: '',
    bold: _kid(rPr, 'b') != null ? _onOff(_kid(rPr, 'b')) : (style?.bold ?? false),
    italic:
        _kid(rPr, 'i') != null ? _onOff(_kid(rPr, 'i')) : (style?.italic ?? false),
    underline: _kid(rPr, 'u') != null && _onOff(_kid(rPr, 'u'), defaultValue: true),
    strike: _kid(rPr, 'strike') != null,
    color: _resolveColorElement(_kid(rPr, 'color'), theme) ?? style?.color,
    sizePt: sz > 0 ? sz : style?.sizePt,
    fontFamily: _fontFamily(_kid(rPr, 'rFonts')) ?? style?.fontFamily,
    highlight: _resolveHighlight(rPr, theme),
    verticalAlign: (vertAlign == null || vertAlign == 'baseline')
        ? null
        : vertAlign,
  );
}

List<OOXMLRun> _applyParagraphDefaults(
  List<OOXMLRun> runs,
  OOXMLRun? paraStyle,
) {
  if (paraStyle == null) return runs;
  return <OOXMLRun>[
    for (final r in runs)
      OOXMLRun(
        text: r.text,
        bold: r.bold || paraStyle.bold,
        italic: r.italic || paraStyle.italic,
        underline: r.underline || paraStyle.underline,
        strike: r.strike || paraStyle.strike,
        color: r.color ?? paraStyle.color,
        sizePt: r.sizePt ?? paraStyle.sizePt,
        fontFamily: r.fontFamily ?? paraStyle.fontFamily,
        highlight: r.highlight ?? paraStyle.highlight,
        image: r.image,
        // 上下标是 run 自己的属性；段落级 rPr 里的 vertAlign 作为兜底。
        verticalAlign: r.verticalAlign ?? paraStyle.verticalAlign,
      ),
  ];
}

/// 一个 run 的解析结果：run 本身 + 它里面的**分页符个数**。
///
/// `<w:br w:type="page"/>` 是分页符（`w:type` 缺省/`textWrapping` 才是软换行），
/// 必须与软换行区分开：软换行写进文本（`\n`），分页符交给段拆分逻辑。
class _ParsedRun {
  const _ParsedRun(this.run, {this.pageBreaks = 0});

  final OOXMLRun run;
  final int pageBreaks;
}

/// 把 `w:color` / `w:shd` 的**主题引用**解成字面 `#rrggbb`。
///
/// 优先级（OOXML 语义）：`w:themeColor` 引用优先；解不出（缺 `theme1.xml`）
/// → 返回 null，调用方退回自己的默认色（**不编颜色**）。
/// 没有主题引用时返回原文的 `w:val`（原有行为，逐字节不变）。
String? _resolveColorElement(XmlElement? el, OOXMLThemeScheme theme) {
  if (el == null) return null;
  final themeColor = _wAttr(el, 'themeColor');
  if (themeColor != null && themeColor != 'none') {
    return theme.resolve(
      themeColor,
      tint: _wAttr(el, 'themeTint'),
      shade: _wAttr(el, 'themeShade'),
    );
  }
  return _wAttr(el, 'val');
}

/// 边框的颜色：`@w:color`（不是 `@w:val`，`w:val` 是**线型** `single`/`double`）。
///
/// `@w:themeColor` 引用优先（其余同 [_resolveColorElement]）。
String? _resolveBorderColor(XmlElement? el, OOXMLThemeScheme theme) {
  if (el == null) return null;
  final themeColor = _wAttr(el, 'themeColor');
  if (themeColor != null && themeColor != 'none') {
    final resolved = theme.resolve(
      themeColor,
      tint: _wAttr(el, 'themeTint'),
      shade: _wAttr(el, 'themeShade'),
    );
    if (resolved != null) return resolved;
  }
  return _wAttr(el, 'color');
}

/// `w:shd` 的填充色：`w:themeFill`(+`themeFillTint`/`themeFillShade`) 优先，
/// 否则 `w:fill`。
String? _resolveFill(XmlElement? shd, OOXMLThemeScheme theme) {
  if (shd == null) return null;
  final themeFill = _wAttr(shd, 'themeFill');
  if (themeFill != null && themeFill != 'none') {
    final resolved = theme.resolve(
      themeFill,
      tint: _wAttr(shd, 'themeFillTint'),
      shade: _wAttr(shd, 'themeFillShade'),
    );
    if (resolved != null) return resolved;
  }
  return _wAttr(shd, 'fill');
}

/// run 的文字底纹：`<w:highlight w:val="yellow"/>`（具名色）优先于
/// `<w:shd w:fill>`（字面/主题色）。
///
/// `w:highlight` 的取值是固定的具名色板（[kOoxmlHighlightColors]），
/// `val="none"` = 没有高亮。
String? _resolveHighlight(XmlElement? rPr, OOXMLThemeScheme theme) {
  if (rPr == null) return null;
  final highlight = _kid(rPr, 'highlight');
  if (highlight != null) {
    final name = _wAttr(highlight, 'val');
    if (name == null || name == 'none') return null;
    final hex = kOoxmlHighlightColors[name] ??
        kOoxmlHighlightColors[name.toLowerCase()];
    if (hex != null) return hex;
  }
  return _resolveFill(_kid(rPr, 'shd'), theme);
}

_ParsedRun _parseRun(
  XmlElement r,
  OOXMLStyle? style,
  _Rels rels,
  OOXMLThemeScheme theme,
  List<String> notes,
) {
  final rPr = _kid(r, 'rPr');
  final rPrOrR = rPr ?? r;
  final sz = halfPointsToPt(_num(_wAttr(_kid(rPrOrR, 'sz'), 'val')));
  final color = _resolveColorElement(_kid(rPrOrR, 'color'), theme);
  final fonts = _kid(rPrOrR, 'rFonts');
  final vertAlign = _wAttr(_kid(rPrOrR, 'vertAlign'), 'val');

  final buffer = StringBuffer();
  OOXMLImage? image;
  var pageBreaks = 0;
  for (final el in r.childElements) {
    switch (el.name.local) {
      case 't':
        buffer.write(el.innerText);
      case 'tab':
        buffer.write('\t');
      case 'br':
        // `<w:br w:type="page">` = **分页符**；`<w:br/>`（缺省 type）与
        // `w:type="textWrapping"` = 软换行。真样本 `student_report.docx` 里那 1 处
        // `<w:br/>` 就是软换行 ⇒ 这里不能把两者混为一谈。
        if (_wAttr(el, 'type') == 'page') {
          pageBreaks++;
        } else {
          buffer.write('\n');
        }
      case 'noBreakHyphen':
        buffer.write('-');
      case 'drawing':
        image = _parseDrawing(el, rels, notes) ?? image;
      case 'pict':
        image = _parseDrawing(el, rels, notes) ?? image;
      default:
        break;
    }
  }
  return _ParsedRun(
    OOXMLRun(
      text: buffer.toString(),
      bold: _kid(rPrOrR, 'b') != null
          ? _onOff(_kid(rPrOrR, 'b'))
          : (style?.bold ?? false),
      italic: _kid(rPrOrR, 'i') != null
          ? _onOff(_kid(rPrOrR, 'i'))
          : (style?.italic ?? false),
      underline:
          _kid(rPrOrR, 'u') != null &&
          _onOff(_kid(rPrOrR, 'u'), defaultValue: true),
      strike:
          _kid(rPrOrR, 'strike') != null || _kid(rPrOrR, 'dstrike') != null,
      color: color ?? style?.color,
      sizePt: sz > 0 ? sz : style?.sizePt,
      fontFamily: _fontFamily(fonts) ?? style?.fontFamily,
      highlight: _resolveHighlight(rPr, theme),
      image: image,
      verticalAlign: (vertAlign == null || vertAlign == 'baseline')
          ? null
          : vertAlign,
    ),
    pageBreaks: pageBreaks,
  );
}

OOXMLImage? _parseDrawing(
  XmlElement drawing,
  _Rels rels,
  List<String> notes,
) {
  final blip = drawing.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'blip')
      .firstOrNull;
  final extent = drawing.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'extent')
      .firstOrNull;
  if (blip == null && extent == null) {
    notes.add('文档里有 drawing 但没有图片引用/尺寸（形状或图表？）→ 只登记，不渲染');
    return null;
  }
  final cx = _num(_wAttr(extent, 'cx'));
  final cy = _num(_wAttr(extent, 'cy'));
  final embed = _wAttr(blip, 'embed') ?? _wAttr(blip, 'link');
  return OOXMLImage(
    relId: embed,
    mediaPath: rels.mediaPath(embed),
    widthPx: emuToPx(cx),
    heightPx: emuToPx(cy),
    name: _wAttr(drawing, 'name'),
  );
}

OOXMLTable _parseTable(
  XmlElement tbl,
  OOXMLStyleSheet styles,
  Map<int, Map<int, OOXMLNumberLevel>> numbering,
  _Rels rels,
  OOXMLThemeScheme theme,
  List<String> notes,
) {
  final grid = _kid(tbl, 'tblGrid');
  final cols = <double>[];
  if (grid != null) {
    for (final c in _kids(grid, 'gridCol')) {
      cols.add(twipsToPx(_num(_wAttr(c, 'w'))));
    }
  }

  // `w:tblPr` 的表格级边框与单元格内边距。
  //
  // * **实测**：真样本 `product_spec.docx` 的 `w:tblPr` 里有 `w:tblCellMar`
  //   （left/right 90 dxa、top/bottom 0），此前被整段忽略 ⇒ 单元格上下内边距
  //   用的是渲染层写死的 4px（与文档声明的 **0** 不符）。
  // * `w:tblBorders`：**本仓真样本 0 处** ⇒ schema 级防御性实现；
  //   单元格自己的 `w:tcBorders` 优先，缺的那一边才落回表级。
  final tblPr = _kid(tbl, 'tblPr');
  final tableBorders = <String, OOXMLBorder>{};
  final tblBorders = _kid(tblPr, 'tblBorders');
  if (tblBorders != null) {
    for (final side in const <String>[
      'top',
      'left',
      'bottom',
      'right',
      'insideH',
      'insideV',
    ]) {
      final el = _kid(tblBorders, side);
      if (el != null) {
        tableBorders[side] = OOXMLBorder.fromTcBorder(el, theme: theme);
      }
    }
  }
  final tblCellMar = _kid(tblPr, 'tblCellMar');
  double cellMar(String side, double fallback) {
    final el = _kid(tblCellMar, side);
    if (el == null) return fallback;
    // `w:type` 绝大多数是 `dxa`（twips）；`nil` 表示 0。
    final type = _wAttr(el, 'type');
    final w = _num(_wAttr(el, 'w'));
    if (type == 'nil') return 0;
    if (w == null) return fallback;
    return type == 'pct' ? fallback : twipsToPx(w);
  }

  final rows = <OOXMLRow>[];
  for (final tr in _kids(tbl, 'tr')) {
    final trPr = _kid(tr, 'trPr');
    final height = twipsToPx(
      _num(_wAttr(_kid(trPr, 'trHeight'), 'val')),
    );
    final isHeader =
        trPr != null &&
        _kids(trPr, 'tblHeader').isNotEmpty;
    final cells = <OOXMLCell>[];
    for (final tc in _kids(tr, 'tc')) {
      final tcPr = _kid(tc, 'tcPr');
      final gridSpan = _num(_wAttr(_kid(tcPr, 'gridSpan'), 'val'))?.toInt() ?? 1;
      final vMerge = tcPr == null ? null : _kid(tcPr, 'vMerge');
      // 单元格内容按**文档顺序**收：`w:p` 是段落，`w:tbl` 是**嵌套表格**，
      // 两者都用与外层同一套 [OOXMLBlock] / [_parseTable] 递归解析
      // （列宽来自内层 `w:tblGrid`、边框/底色来自内层 `w:tcPr`、表头来自内层 `w:tblHeader`）。
      final counters = <String, List<int>>{};
      // ★ 同样下钻 `w:sdt`（单元格里也可能有内容控件）。
      final blocks = _parseBlockChildren(
        tc,
        styles: styles,
        numbering: numbering,
        counters: counters,
        rels: rels,
        theme: theme,
        notes: notes,
      );
      final nested = blocks.where((b) => b.isTable).length;
      if (nested > 0) {
        notes.add('单元格里有 $nested 个嵌套表格 → 已按外层同一规则递归渲染（宽度受父单元格约束）');
      }
      final tcW = _num(_wAttr(_kid(tcPr, 'tcW'), 'w'));
      final shd = _resolveFill(_kid(tcPr, 'shd'), theme);
      final borders = _kid(tcPr, 'tcBorders');
      // 单元格边框优先；本单元格没声明的那一边落回**表级** `w:tblBorders`。
      OOXMLBorder border(String side) {
        final own = _kid(borders, side);
        if (own != null) return OOXMLBorder.fromTcBorder(own, theme: theme);
        return tableBorders[side] ?? OOXMLBorder.none;
      }

      cells.add(
        OOXMLCell(
          blocks: blocks,
          gridSpan: gridSpan < 1 ? 1 : gridSpan,
          vMergeContinue: vMerge != null && _wAttr(vMerge, 'val') == null,
          vMergeRestart: _wAttr(vMerge, 'val') == 'restart',
          widthPx: tcW == null ? null : twipsToPx(tcW),
          shading: shd,
          verticalAlign: _wAttr(_kid(tcPr, 'vAlign'), 'val') ?? 'top',
          borderTop: border('top'),
          borderRight: border('right'),
          borderBottom: border('bottom'),
          borderLeft: border('left'),
        ),
      );
    }
    rows.add(
      OOXMLRow(
        cells: cells,
        heightPx: height > 0 ? height : null,
        isHeader: isHeader,
      ),
    );
  }
  if (cols.isEmpty) {
    notes.add('表格缺 w:tblGrid → 列宽按单元格数等分（并已登记）');
  }
  return OOXMLTable(
    colWidthsPx: cols,
    rows: rows,
    borders: tableBorders,
    cellMarginLeftPx: cellMar('left', kOoxmlDefaultCellMarginPx),
    cellMarginRightPx: cellMar('right', kOoxmlDefaultCellMarginPx),
    cellMarginTopPx: cellMar('top', kOoxmlDefaultCellMarginVerticalPx),
    cellMarginBottomPx: cellMar('bottom', kOoxmlDefaultCellMarginVerticalPx),
  );
}
