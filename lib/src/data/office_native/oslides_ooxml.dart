// **OOXML（PPTX）解析** —— `.oslides` 阅读的**首要数据源**（O3 重做）。
//
// ## 为什么有这条路径（决定性事实，见 `docs/ooxml-ground-truth.md`）
// 真机实测：`SYNO.SynologyDrive.Files:download`（`files=["id:<file_id>"]`）拿回来的
// `.oslides` **不是**专有 BSON，而是 **标准 PPTX**（`PK\x03\x04` ZIP）：
// ```
// Technology.oslides（服务器 size=317,794 → 下载 327,156 字节）
//   ppt/presentation.xml                ← 页序 + <p:sldSz cx cy>
//   ppt/slides/slide1..15.xml           ← 每页（本样本全部是占位符形状）
//   ppt/slideLayouts/slideLayout1..16.xml
//   ppt/slideMasters/slideMaster1.xml
//   ppt/notesSlides/notesSlide1..15.xml
//   ppt/theme/theme1..2.xml
//   ppt/media/image1.svg image2.jpg image3.svg image4.jpg
// ```
//
// ## ⭐ 核心：几何与文本样式**在版式/母版里**（本批要修的正是这件事）
// 实测 `ppt/slides/slide1.xml` 的形状是**占位符**：
// ```xml
// <p:sp><p:nvSpPr>…<p:nvPr><p:ph idx="0" type="title"/></p:nvPr></p:nvSpPr>
//   <p:spPr><a:prstGeom prst="rect"/><a:ln/></p:spPr>   <!-- 没有 <a:xfrm>！ -->
//   <p:txBody><a:bodyPr/><a:p>…<a:t>Social Media</a:t>…
// ```
// 也就是说 slide 上**根本没有坐标**；坐标在 `slideLayout1.xml`：
// ```xml
// <p:ph idx="0" type="title"/> → <a:off x="540000" y="2093190"/><a:ext cx="8064000" cy="1146810"/>
// 字号/颜色在 <a:lstStyle><a:lvl1pPr>…<a:defRPr sz="6400" b="1"><a:solidFill><a:srgbClr val="ffffff"/>
// 背景在 <p:bg><p:bgPr><a:solidFill><a:srgbClr val="0069e6"/>   ← 蓝底白字
// ```
// 所以本文件做**三级继承**：`slideMaster（含 txStyles）→ slideLayout → slide`。
//
// ## 单位（全部有原文支撑）
//   * 长度 EMU：914400 EMU = 1 inch → **px = emu / 9525**（96 dpi）；
//   * 本样本 `<p:sldSz cx="9144000" cy="5143500"/>` = **16:9**（也支持 12192000×6858000）；
//   * 字号 `<a:rPr sz>` / `<a:defRPr sz>` 是**百分之一磅**：`6400` → 64pt；
//   * 段前段后 `<a:spcPts val>` 是**百分之一磅**：`500` → 5pt；
//   * 行距 `<a:lnSpc><a:spcPct val="115000">` → 115%；
//   * 旋转 `<a:xfrm rot="5400000">` 是 **1/60000 度**。
//
// ## 降级（硬要求）
// 拿不到 PPTX（离线 / 老服务端 / 权限不足 / 不是 ZIP）时 [OSlidesDeck.parse]
// 返回 **null**，调用方回落到既有 OFile 路径并**明确告知用户**，**绝不静默空白**；
// 单个形状/单页解析失败也只降级那一处，并把人类可读的原因记进
// [OSlidesDeckSlide.degradations]。
//
// ## 未做到（报告里如实登记，不假装对齐）
//   * **不渲染 SVG 媒体**（`ppt/media/*.svg`）：本仓库没有 SVG 解码依赖，且
//     `pubspec.yaml` 本批禁改 → 只登记 [OSlidesDeck.unrenderableVectorCount]，
//     由阅读器一次性用用户语言说明，**不猜测图形内容**；
//   * 不做 `p:graphicFrame` 的表格/图表/SmartArt（登记为"暂不支持的对象"占位卡）；
//   * 不做动画 / 切换 / 超链接动作 / 备注母版版式；
//   * 组合（`p:grpSp`）只做**平移累加**（不做 chExt→ext 缩放），本样本没有组合；
//   * 线条（`p:cxnSp`）按"盒子上沿"的直线绘制，不做任意角度折线。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../core/i18n/data_text.dart';

/// EMU → px（96 dpi）。914400 EMU = 1 inch。
const double kPptxEmuPerPx = 9525.0;

/// PowerPoint 默认 16:9 画布（EMU）。
const double kPptxDefaultWidthEmu = 12192000;
const double kPptxDefaultHeightEmu = 6858000;

/// OOXML 文本框默认内边距（EMU）：左右 0.1 inch、上下 0.05 inch。
const double kPptxDefaultInsetLR = 91440;
const double kPptxDefaultInsetTB = 45720;

/// EMU → px。
double pptxEmuToPx(Object? emu) {
  final v = _num(emu);
  return v == null ? 0 : v / kPptxEmuPerPx;
}

/// 1/60000 度 → 度（`<a:xfrm rot="5400000">` = 90°）。
double pptxRotationToDegrees(Object? rot) {
  final v = _num(rot);
  return v == null ? 0 : v / 60000.0;
}

/// 字节是不是一个 OOXML/ZIP 包（`PK\x03\x04`）。
bool isPptxZipBytes(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4B &&
    bytes[2] == 0x03 &&
    bytes[3] == 0x04;

/// 图片包内路径是不是本批**渲染不出**的矢量格式。
/// 该媒体是不是 SVG（**本渲染器能画**的那一类矢量图）。
///
/// 与 `office_svg_painter.dart` 的 `isSvgMediaPart` 语义一致，
/// 但**故意在这里内联**：`data/` 不该反向依赖 `features/`。
/// `.svgz` **不算**（需要先 gunzip，渲染器尚未支持）。
bool _isSvgMediaPart(String? part) {
  if (part == null) return false;
  return part.toLowerCase().endsWith('.svg');
}

bool isVectorMediaPart(String? part) {
  if (part == null) return false;
  final p = part.toLowerCase();
  return p.endsWith('.svg') ||
      p.endsWith('.svgz') ||
      p.endsWith('.emf') ||
      p.endsWith('.wmf');
}

// ---------------------------------------------------------------- 形状/文本模型

/// 形状类型（渲染器据此选 widget；`unsupported` 走可读降级卡）。
enum OSlidesShapeKind {
  /// 纯文本框。
  text,

  /// `prst="rect"`。
  rectangle,

  /// `prst="roundRect"`。
  roundRect,

  /// `prst="ellipse"` / `prst="circle"`。
  ellipse,

  /// `prst="triangle"` 等简单多边形。
  triangle,

  /// 直线 / 连接符（`p:cxnSp`）。
  line,

  /// `<p:pic>`。
  picture,

  /// 表格 / 图表 / SmartArt / OLE 等本批不渲染的对象。
  unsupported,
}

/// 一条文本 run（`<a:r>`）的**已解析**样式。
class OSlidesDeckRun {
  const OSlidesDeckRun({
    required this.text,
    this.fontFamily,
    this.sizePt,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.colorArgb,
  });

  final String text;
  final String? fontFamily;
  final double? sizePt;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;

  /// 0xAARRGGBB；null = 未声明（渲染器取默认前景色）。
  final int? colorArgb;

  OSlidesDeckRun copyWith({String? text}) => OSlidesDeckRun(
    text: text ?? this.text,
    fontFamily: fontFamily,
    sizePt: sizePt,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    colorArgb: colorArgb,
  );
}

/// 一个段落（`<a:p>`）。
class OSlidesDeckParagraph {
  const OSlidesDeckParagraph({
    required this.runs,
    required this.level,
    this.align,
    this.bullet,
    this.leftInsetPx = 0,
    this.lineSpacingPct,
    this.spaceBeforePt,
    this.spaceAfterPt,
  });

  final List<OSlidesDeckRun> runs;

  /// 0 基层级（`<a:pPr lvl="1">` → 1）。
  final int level;

  /// `l` / `ctr` / `r` / `just`。
  final String? align;

  /// 已渲染成文本的项目符号（`●`、`1.`、`a.` …）；null = 无项目符号。
  final String? bullet;

  /// 段落左缩进（px，= `marL` + `indent`）。
  final double leftInsetPx;

  final double? lineSpacingPct;
  final double? spaceBeforePt;
  final double? spaceAfterPt;

  String get text => runs.map((r) => r.text).join();
}

/// 一个可绘制形状（几何**已按母版/版式继承解析完毕**，单位 px）。
class OSlidesDeckShape {
  const OSlidesDeckShape({
    required this.id,
    required this.kind,
    required this.preset,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.rotationDegrees,
    required this.geometryInherited,
    this.placeholderIndex,
    this.placeholderType,
    this.fillArgb,
    this.lineArgb,
    this.lineWidthPx = 0,
    this.paragraphs = const <OSlidesDeckParagraph>[],
    this.anchor,
    this.wrap = true,
    this.insetLeftPx = 0,
    this.insetTopPx = 0,
    this.insetRightPx = 0,
    this.insetBottomPx = 0,
    this.imagePart,
    this.imageAlt,
    this.unsupportedLabel,
  });

  final String id;
  final OSlidesShapeKind kind;

  /// `<a:prstGeom prst>` 原文（`rect` / `ellipse` / `roundRect` / `line` …）。
  final String preset;

  final double left;
  final double top;
  final double width;
  final double height;
  final double rotationDegrees;

  /// **几何是否来自母版/版式继承**（本批要证明的关键点）。
  final bool geometryInherited;

  final int? placeholderIndex;
  final String? placeholderType;

  /// 填充色 0xAARRGGBB；null = 透明。
  final int? fillArgb;

  /// 边框色 0xAARRGGBB；null = 无边框。
  final int? lineArgb;
  final double lineWidthPx;

  final List<OSlidesDeckParagraph> paragraphs;

  /// `<a:bodyPr anchor>`：`t` / `ctr` / `b`。
  final String? anchor;

  /// `<a:bodyPr wrap="none">` → false。
  final bool wrap;

  final double insetLeftPx;
  final double insetTopPx;
  final double insetRightPx;
  final double insetBottomPx;

  /// 图片形状的包内路径（`ppt/media/image2.jpg`）。
  final String? imagePart;
  final String? imageAlt;

  /// [OSlidesShapeKind.unsupported] 的对象名（表格/图表/…）。
  final String? unsupportedLabel;

  String get text => paragraphs.map((p) => p.text).join('\n').trim();

  bool get hasText => paragraphs.any((p) => p.text.trim().isNotEmpty);

  bool get isVectorImage => isVectorMediaPart(imagePart);
}

/// 一页幻灯片（形状按 z 序：先母版装饰 → 版式装饰 → 本页形状）。
class OSlidesDeckSlide {
  const OSlidesDeckSlide({
    required this.order,
    required this.shapes,
    required this.backgroundArgb,
    required this.backgroundInherited,
    required this.notes,
    required this.placeholderCount,
    required this.inheritedGeometryCount,
    required this.degradations,
  });

  /// 0 基页序。
  final int order;

  final List<OSlidesDeckShape> shapes;

  /// 已解析的背景色 0xAARRGGBB（默认白）。
  final int backgroundArgb;

  /// 背景是否来自版式/母版。
  final bool backgroundInherited;

  /// 演讲者备注（`notesSlides/notesSlideN.xml`）。
  final String notes;

  final int placeholderCount;

  /// 本页**经版式/母版继承**才拿到几何的形状数。
  final int inheritedGeometryCount;

  /// 人类可读的降级原因（渲染器只用来决定是否提示，不上屏工程措辞）。
  final List<String> degradations;

  /// 1 基页码。
  int get pageNumber => order + 1;

  /// 真正会被画出来的形状数。
  int get drawableShapeCount =>
      shapes.where((s) => s.width > 0 && s.height > 0).length;

  int get unsupportedCount =>
      shapes.where((s) => s.kind == OSlidesShapeKind.unsupported).length;

  String get plainText =>
      shapes.map((s) => s.text).where((t) => t.isNotEmpty).join('\n').trim();

  /// 这一页有没有任何可见内容（画布空白判定，兜底用）。
  bool get isBlank =>
      drawableShapeCount == 0 && unsupportedCount == 0 && notes.trim().isEmpty;
}

/// 一份**已解析**的 `.oslides`（PPTX）演示文稿。
class OSlidesDeck {
  const OSlidesDeck({
    required this.slides,
    required this.widthPx,
    required this.heightPx,
    required this.widthEmu,
    required this.heightEmu,
    required this.layoutCount,
    required this.masterCount,
    required this.media,
    this.svgMediaCount = 0,
    required this.unrenderableVectorCount,
    required this.unsupportedObjectCount,
    required this.degradations,
  });

  final List<OSlidesDeckSlide> slides;

  /// 画布尺寸（px，96 dpi）。
  final double widthPx;
  final double heightPx;

  /// `ppt/presentation.xml` 的 `<p:sldSz>` 原文（EMU）。
  final int widthEmu;
  final int heightEmu;

  final int layoutCount;
  final int masterCount;

  /// 包内媒体：`ppt/media/image2.jpg` → 字节。
  final Map<String, Uint8List> media;

  /// 包内的 SVG 数量。
  ///
  /// **SVG 现在【能画】**（自研解析器 + `CustomPainter`，见
  /// `office_svg_painter.dart` / `docs/office-svg-renderer-report.md`），
  /// 所以它**不计入** [unrenderableVectorCount] —— 单列出来只为保留事实。
  final int svgMediaCount;

  /// 解析到但**渲染器画不出**的矢量图数量。
  ///
  /// = 矢量媒体总数 − SVG 数，即 `*.emf` / `*.wmf` / `*.svgz`。
  /// **⚠️ 不含 SVG**：SVG 已由自研渲染器绘制，若把它算进来，
  /// 真机上会弹出"部分矢量图形暂不显示"的**过时且误导**的说明
  /// （`technology.oslides` 正好有 2 个 SVG 且没有 EMF/WMF）。
  final int unrenderableVectorCount;

  /// 表格 / 图表 / SmartArt 等暂不支持的对象总数。
  final int unsupportedObjectCount;

  final List<String> degradations;

  bool get isEmpty => slides.isEmpty;

  int get shapeCount => slides.fold(0, (sum, s) => sum + s.shapes.length);

  int get inheritedGeometryCount =>
      slides.fold(0, (sum, s) => sum + s.inheritedGeometryCount);

  /// 是否 16:9（本批默认幻灯画布比例）。
  bool get isWidescreen {
    if (heightPx <= 0 || widthPx <= 0) return false;
    return ((widthPx / heightPx) - 16 / 9).abs() < 0.02;
  }

  /// 是否 4:3。
  bool get isStandard {
    if (heightPx <= 0 || widthPx <= 0) return false;
    return ((widthPx / heightPx) - 4 / 3).abs() < 0.02;
  }

  /// 解析字节；不是 PPTX / 损坏 / 缺 `presentation.xml` → **null**（调用方回落）。
  static OSlidesDeck? parse(List<int> bytes) {
    if (!isPptxZipBytes(bytes)) return null;
    try {
      return _PptxParser(bytes).run();
    } catch (_) {
      return null;
    }
  }
}

// ------------------------------------------------------------------ XML 小工具

num? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v;
  return num.tryParse(v.toString().trim());
}

double? _dbl(Object? v) => _num(v)?.toDouble();

int? _int(Object? v) => _num(v)?.toInt();

bool _flag(Object? v, {bool whenAbsent = false}) {
  if (v == null) return whenAbsent;
  final s = v.toString().trim().toLowerCase();
  return s == '1' || s == 'true' || s == 'on';
}

/// 子元素（按**局部名**匹配：不依赖 `p:`/`a:` 前缀写法）。
Iterable<XmlElement> _kids(XmlElement? e, String local) sync* {
  if (e == null) return;
  for (final c in e.childElements) {
    if (c.name.local == local) yield c;
  }
}

XmlElement? _kid(XmlElement? e, String local) {
  for (final c in _kids(e, local)) {
    return c;
  }
  return null;
}

/// 属性（按**局部名**匹配，兼容 `r:embed` / `r:id` 这类前缀写法）。
String? _attr(XmlElement? e, String local) {
  if (e == null) return null;
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

String _dirOf(String part) {
  final i = part.lastIndexOf('/');
  return i < 0 ? '' : part.substring(0, i);
}

String _baseOf(String part) {
  final i = part.lastIndexOf('/');
  return i < 0 ? part : part.substring(i + 1);
}

String _normPath(String basePart, String target) {
  if (target.startsWith('/')) return target.substring(1);
  final out = <String>[];
  for (final seg in '${_dirOf(basePart)}/$target'.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return out.join('/');
}

// -------------------------------------------------------------------- 样式解析

/// 一个 run 的**可继承**文本属性（null = 未声明 → 交给下一优先级）。
class _RunStyle {
  const _RunStyle({
    this.sizePt,
    this.bold,
    this.italic,
    this.underline,
    this.strike,
    this.colorArgb,
    this.typeface,
  });

  final double? sizePt;
  final bool? bold;
  final bool? italic;
  final bool? underline;
  final bool? strike;
  final int? colorArgb;
  final String? typeface;

  static const _RunStyle empty = _RunStyle();

  /// [child] 覆盖 [this]（高优先级在后）。
  _RunStyle merge(_RunStyle? child) {
    if (child == null) return this;
    return _RunStyle(
      sizePt: child.sizePt ?? sizePt,
      bold: child.bold ?? bold,
      italic: child.italic ?? italic,
      underline: child.underline ?? underline,
      strike: child.strike ?? strike,
      colorArgb: child.colorArgb ?? colorArgb,
      typeface: child.typeface ?? typeface,
    );
  }

  OSlidesDeckRun toRun(String text) => OSlidesDeckRun(
    text: text,
    fontFamily: typeface,
    sizePt: sizePt,
    bold: bold ?? false,
    italic: italic ?? false,
    underline: underline ?? false,
    strike: strike ?? false,
    colorArgb: colorArgb,
  );
}

/// 一个段落级别的可继承属性（`<a:lvlNpPr>` / `<a:pPr>`）。
class _ParStyle {
  const _ParStyle({
    this.run,
    this.align,
    this.marLEmu,
    this.indentEmu,
    this.bulletChar,
    this.bulletNone,
    this.bulletAutoNumType,
    this.bulletAutoNumStart,
    this.lineSpacingPct,
    this.spaceBeforePt,
    this.spaceAfterPt,
  });

  final _RunStyle? run;
  final String? align;
  final double? marLEmu;
  final double? indentEmu;

  /// `<a:buChar char="●">`。
  final String? bulletChar;
  final bool? bulletNone;

  /// `<a:buAutoNum type="arabicPeriod" startAt="1">`。
  final String? bulletAutoNumType;
  final int? bulletAutoNumStart;

  final double? lineSpacingPct;
  final double? spaceBeforePt;
  final double? spaceAfterPt;

  static const _ParStyle empty = _ParStyle();

  _ParStyle merge(_ParStyle? child) {
    if (child == null) return this;
    return _ParStyle(
      run: (run ?? _RunStyle.empty).merge(child.run),
      align: child.align ?? align,
      marLEmu: child.marLEmu ?? marLEmu,
      indentEmu: child.indentEmu ?? indentEmu,
      bulletChar: child.bulletChar ?? bulletChar,
      bulletNone: child.bulletNone ?? bulletNone,
      bulletAutoNumType: child.bulletAutoNumType ?? bulletAutoNumType,
      bulletAutoNumStart: child.bulletAutoNumStart ?? bulletAutoNumStart,
      lineSpacingPct: child.lineSpacingPct ?? lineSpacingPct,
      spaceBeforePt: child.spaceBeforePt ?? spaceBeforePt,
      spaceAfterPt: child.spaceAfterPt ?? spaceAfterPt,
    );
  }
}

/// 9 个层级的段落样式（`defPPr` 已并进每一级）。
class _LevelStyles {
  const _LevelStyles(this.levels);

  final List<_ParStyle> levels;

  static const _LevelStyles empty = _LevelStyles(<_ParStyle>[
    _ParStyle.empty,
    _ParStyle.empty,
    _ParStyle.empty,
    _ParStyle.empty,
    _ParStyle.empty,
    _ParStyle.empty,
    _ParStyle.empty,
    _ParStyle.empty,
    _ParStyle.empty,
  ]);

  _ParStyle at(int level) => levels[level.clamp(0, 8)];

  _LevelStyles merge(_LevelStyles? child) {
    if (child == null) return this;
    return _LevelStyles(<_ParStyle>[
      for (var i = 0; i < 9; i++) levels[i].merge(child.levels[i]),
    ]);
  }

  /// 从 `<a:lstStyle>` 或 `<p:txBody>` 解析（`defPPr` + `lvl1pPr..lvl9pPr`）。
  static _LevelStyles parse(XmlElement? container, _PptxParser theme) {
    if (container == null) return empty;
    final lst = container.name.local == 'lstStyle'
        ? container
        : _kid(container, 'lstStyle');
    if (lst == null) return empty;
    final base = _parStyle(_kid(lst, 'defPPr'), theme);
    return _LevelStyles(<_ParStyle>[
      for (var i = 1; i <= 9; i++)
        base.merge(_parStyle(_kid(lst, 'lvl${i}pPr'), theme)),
    ]);
  }

  /// `<a:pPr>` / `<a:lvlNpPr>`。
  static _ParStyle _parStyle(XmlElement? e, _PptxParser theme) {
    if (e == null) return _ParStyle.empty;
    final pct = _dbl(_attr(_kid(_kid(e, 'lnSpc'), 'spcPct'), 'val'));
    final before = _dbl(_attr(_kid(_kid(e, 'spcBef'), 'spcPts'), 'val'));
    final after = _dbl(_attr(_kid(_kid(e, 'spcAft'), 'spcPts'), 'val'));
    return _ParStyle(
      run: runStyle(_kid(e, 'defRPr'), theme),
      align: _attr(e, 'algn'),
      marLEmu: _dbl(_attr(e, 'marL')),
      indentEmu: _dbl(_attr(e, 'indent')),
      bulletChar: _attr(_kid(e, 'buChar'), 'char'),
      bulletNone: _kid(e, 'buNone') == null ? null : true,
      bulletAutoNumType: _attr(_kid(e, 'buAutoNum'), 'type'),
      bulletAutoNumStart: _int(_attr(_kid(e, 'buAutoNum'), 'startAt')),
      lineSpacingPct: pct == null ? null : pct / 1000.0,
      spaceBeforePt: before == null ? null : before / 100.0,
      spaceAfterPt: after == null ? null : after / 100.0,
    );
  }

  /// `<a:rPr>` / `<a:defRPr>` / `<a:endParaRPr>`。
  static _RunStyle? runStyle(XmlElement? e, _PptxParser theme) {
    if (e == null) return null;
    final sz = _dbl(_attr(e, 'sz'));
    final u = _attr(e, 'u');
    final strike = _attr(e, 'strike');
    return _RunStyle(
      // sz 是百分之一磅：6400 → 64pt。
      sizePt: sz == null ? null : sz / 100.0,
      bold: _attr(e, 'b') == null ? null : _flag(_attr(e, 'b')),
      italic: _attr(e, 'i') == null ? null : _flag(_attr(e, 'i')),
      underline: u == null ? null : u != 'none',
      strike: strike == null ? null : strike != 'noStrike',
      colorArgb: theme.fillColor(e),
      typeface: _attr(_kid(e, 'latin'), 'typeface'),
    );
  }
}

// ---------------------------------------------------------------------- 解析器

/// 一个包内关系（`_rels/*.rels`）。
class _Rel {
  const _Rel(this.type, this.target);

  final String type;
  final String target;
}

/// 已解析的占位符条目（几何 + 文本样式 + 文本框属性）。
class _Placeholder {
  const _Placeholder({
    required this.index,
    required this.type,
    required this.xfrm,
    required this.styles,
    required this.anchor,
    required this.wrap,
    required this.insets,
  });

  final int? index;
  final String? type;
  final _Xfrm? xfrm;
  final _LevelStyles styles;
  final String? anchor;
  final bool wrap;

  /// l/t/r/b（EMU）。
  final List<double> insets;
}

/// `<a:xfrm>`（EMU + 1/60000 度）。
class _Xfrm {
  const _Xfrm({
    required this.offX,
    required this.offY,
    required this.extCx,
    required this.extCy,
    required this.rot,
  });

  final double offX;
  final double offY;
  final double extCx;
  final double extCy;
  final double rot;

  bool get isUsable => extCx > 0 && extCy > 0;

  _Xfrm shifted(double dx, double dy) => _Xfrm(
    offX: offX + dx,
    offY: offY + dy,
    extCx: extCx,
    extCy: extCy,
    rot: rot,
  );

  static _Xfrm? parse(XmlElement? spPr) {
    final xfrm = _kid(spPr, 'xfrm');
    if (xfrm == null) return null;
    final off = _kid(xfrm, 'off');
    final ext = _kid(xfrm, 'ext');
    if (off == null && ext == null) return null;
    return _Xfrm(
      offX: _dbl(_attr(off, 'x')) ?? 0,
      offY: _dbl(_attr(off, 'y')) ?? 0,
      extCx: _dbl(_attr(ext, 'cx')) ?? 0,
      extCy: _dbl(_attr(ext, 'cy')) ?? 0,
      rot: _dbl(_attr(xfrm, 'rot')) ?? 0,
    );
  }
}

/// 形状元素 + 组合累积位移（`p:grpSp` 只做平移累加）。
class _FlatShape {
  const _FlatShape(this.element, this.dx, this.dy);

  final XmlElement element;
  final double dx;
  final double dy;
}

/// 幻灯片母版解析结果。
class _Master {
  _Master(this.part);

  final String part;

  final Map<String, _Placeholder> byType = <String, _Placeholder>{};
  final Map<int, _Placeholder> byIndex = <int, _Placeholder>{};

  /// 母版 spTree（非占位符装饰形状用）。
  XmlElement? spTree;

  _LevelStyles titleStyle = _LevelStyles.empty;
  _LevelStyles bodyStyle = _LevelStyles.empty;
  _LevelStyles otherStyle = _LevelStyles.empty;

  int? backgroundArgb;

  /// `<p:clrMap bg1="lt1" tx1="dk1" …>`。
  Map<String, String> clrMap = const <String, String>{};

  _Placeholder? findPh({int? index, String? type}) {
    if (index != null) {
      final hit = byIndex[index];
      if (hit != null && (type == null || hit.type == type)) return hit;
    }
    if (type != null) {
      final hit = byType[type];
      if (hit != null) return hit;
      for (final cand in roleTypes(type)) {
        final r = byType[cand];
        if (r != null) return r;
      }
    }
    return null;
  }

  /// 该占位符类型对应的母版文本样式（`titleStyle` / `bodyStyle` / `otherStyle`）。
  _LevelStyles styleFor(String? type) {
    switch (type) {
      case 'title':
      case 'ctrTitle':
        return titleStyle;
      case 'body':
      case 'subTitle':
      case 'obj':
      case 'content':
        return bodyStyle;
      default:
        return otherStyle;
    }
  }
}

/// 幻灯片版式（`slideLayoutN.xml`）解析结果。
class _Layout {
  _Layout(this.part, this.masterPart);

  final String part;
  final String masterPart;

  final Map<String, _Placeholder> byType = <String, _Placeholder>{};
  final Map<int, _Placeholder> byIndex = <int, _Placeholder>{};

  /// 非占位符装饰（版式上的图片/色块/圆点，**视觉上很关键**）。
  final List<_FlatShape> decor = <_FlatShape>[];

  /// 版式自己的 `<p:clrMapOvr><a:overrideClrMapping …>`（没有 ⇒ null ⇒ 用母版的）。
  Map<String, String>? clrMap;

  int? backgroundArgb;

  _Placeholder? findPh({int? index, String? type}) {
    if (index != null) {
      final hit = byIndex[index];
      if (hit != null && (type == null || hit.type == type)) return hit;
    }
    if (type != null) {
      final hit = byType[type];
      if (hit != null) return hit;
      for (final cand in roleTypes(type)) {
        final r = byType[cand];
        if (r != null) return r;
      }
    }
    return null;
  }
}

/// 同"角色"的占位符类型（母版/版式找不到**同名**类型时的兜底）。
List<String> roleTypes(String type) {
  switch (type) {
    case 'title':
    case 'ctrTitle':
      return const <String>['title', 'ctrTitle'];
    case 'body':
    case 'subTitle':
    case 'obj':
    case 'content':
      return const <String>['body', 'subTitle', 'obj', 'content'];
    default:
      return const <String>[];
  }
}

class _PptxParser {
  _PptxParser(this.bytes);

  final List<int> bytes;

  final Map<String, Uint8List> _parts = <String, Uint8List>{};
  final Map<String, XmlDocument> _xml = <String, XmlDocument>{};
  final Map<String, Map<String, _Rel>> _rels = <String, Map<String, _Rel>>{};

  /// 主题色表（`clrScheme` 的 `val` → 6 位 hex）。
  final Map<String, String> scheme = <String, String>{};

  /// 当前生效的 `clrMap`（`schemeClr val="tx1"` → `dk1`）。
  Map<String, String> clrMap = const <String, String>{};

  final List<String> degradations = <String>[];

  // ------------------------------------------------------------- 颜色/单位

  /// `<a:solidFill>` → 0xAARRGGBB。
  int? fillColor(XmlElement? container) {
    if (container == null) return null;
    return colorElement(_kid(container, hereSolidFill));
  }

  static const String hereSolidFill = 'solidFill';

  /// 描边色（`<a:ln><a:solidFill>`）；`<a:noFill>` → null。
  int? lineColor(XmlElement? spPr) {
    final ln = _kid(spPr, 'ln');
    if (ln == null) return null;
    if (_kid(ln, 'noFill') != null) return null;
    return fillColor(ln);
  }

  double lineWidthPx(XmlElement? spPr) {
    final ln = _kid(spPr, 'ln');
    if (ln == null) return 0;
    final w = _dbl(_attr(ln, 'w'));
    // 未声明宽度时 OOXML 默认 0.75pt。
    if (w == null) return 0.75 * 96 / 72;
    return w / kPptxEmuPerPx;
  }

  int? colorElement(XmlElement? fill) {
    if (fill == null) return null;
    final srgb = _kid(fill, 'srgbClr');
    if (srgb != null) {
      return _applyColorTransforms(_hex(_attr(srgb, 'val')), srgb);
    }
    final schemeEl = _kid(fill, 'schemeClr');
    if (schemeEl != null) {
      final v = _attr(schemeEl, 'val') ?? '';
      // 引用色两步走：① `clrMap` 把**逻辑名**映射到主题槽位（`tx1`→`dk1`、
      // `bg1`→`lt1` …，来自母版 `<p:clrMap>`）；② 再去 `clrScheme` 查色。
      // 主题里缺该槽位时退回原名（不静默丢色）。
      final mapped = clrMap[v] ?? v;
      return _applyColorTransforms(_hex(scheme[mapped] ?? scheme[v]), schemeEl);
    }
    final sys = _kid(fill, 'sysClr');
    if (sys != null) {
      // `sysClr` 的真实颜色在 **`lastClr`**（`val="window"` 只是系统别名）。
      return _applyColorTransforms(
        _hex(_attr(sys, 'lastClr')) ?? _hex(_attr(sys, 'val')),
        sys,
      );
    }
    final prst = _kid(fill, 'prstClr');
    if (prst != null) {
      return _applyColorTransforms(_prstHex(_attr(prst, 'val')), prst);
    }
    // ⚠️ 已知缺口（**未实现，不假装**）：`<a:scrgbClr>`（百分比 RGB）与
    // `<a:hslClr>`。三份真机样本里出现次数均为 0；遇到它们**返回 null**
    // （形状按"无填充"降级，不会画成错误的颜色）。
    return null;
  }

  /// DrawingML 颜色修饰符演算（ISO/IEC 29500-1 第 1 版 §20.1.2.3）。
  ///
  /// 修饰符是**颜色元素自己的子元素**，在 schema 里是一个**有序**序列
  /// （`EG_ColorTransform`）⇒ **必须按文档顺序逐个作用**。
  /// 主题里最常见的组合是 `<a:lumMod val="40000"/><a:lumOff val="60000"/>`
  /// （"变浅 40%"），先 mod 后 off 才等于 PowerPoint 的结果。
  ///
  /// 逐条规则 —— **规范原文**（2026-09-22 从 learn.microsoft.com 转载的
  /// ISO/IEC 29500-1 文本逐字核对，非推测）：
  ///
  /// | 元素 | 规范原文 | 落到公式 |
  /// |---|---|---|
  /// | `tint` | "a lighter version of its input color. A 10% tint is 10% of the input color combined with 90% **white**." | `C' = C*t + 255*(1-t)`，`t=val/100000` |
  /// | `shade` | "a darker version of its input color. A 10% shade is 10% of the input color combined with 90% **black**." | `C' = C*s`，`s=val/100000` |
  /// | `lumMod` | "the input color with its luminance modulated by the given percentage. A 50% luminance modulate reduces the luminance by half." | `L' = L*v` |
  /// | `lumOff` | "the input color with its luminance shifted, but with its **hue and saturation unchanged**." | `L' = L + v` |
  /// | `alpha` | 不透明度百分比 | `A' = v*255` |
  ///
  /// ⚠️ **口径区分（用户专门提醒过）**：这里的 `tint/shade` 是 **DrawingML**
  /// 的**逐通道**线性插值；`.osheet` 那套是 **Excel** 的 `tint`，走的是
  /// **HLS 亮度**插值（见 `office_sheet_ooxml_color.dart` 的 POI 口径）。
  /// **两者不可互相套用**，所以本文件把规则连规范原文一起抄下来做对照。
  int? _applyColorTransforms(int? argb, XmlElement holder) {
    if (argb == null) return null;
    // ⚠️ **工作色用浮点，中途不量化成 8 位**。
    // 逐修饰符取整会累积误差：`4F81BD` 走 lumMod 40000 + lumOff 60000 时，
    // 如果在 lumMod 之后截断一次，结果会变成 `B7CCE4`，而**官方调色板是
    // `B8CCE4`**（见 [_q]）。⇒ 只在最后量化一次。
    var a = ((argb >> 24) & 0xFF).toDouble();
    var r = ((argb >> 16) & 0xFF).toDouble();
    var g = ((argb >> 8) & 0xFF).toDouble();
    var b = (argb & 0xFF).toDouble();
    var touched = false;
    for (final e in holder.childElements) {
      final val = _dbl(_attr(e, 'val'));
      if (val == null) continue;
      final f = val / 100000.0;
      switch (e.name.local) {
        case 'alpha':
          touched = true;
          a = f * 255;
        case 'tint':
          touched = true;
          final t = f.clamp(0.0, 1.0);
          r = r * t + 255 * (1 - t);
          g = g * t + 255 * (1 - t);
          b = b * t + 255 * (1 - t);
        case 'shade':
          touched = true;
          final s = f.clamp(0.0, 1.0);
          r = r * s;
          g = g * s;
          b = b * s;
        case 'lumMod':
        case 'lumOff':
          touched = true;
          final hsl = _rgbToHsl(r, g, b);
          final l = e.name.local == 'lumMod' ? hsl[2] * f : hsl[2] + f;
          final out = _hslToRgb(hsl[0], hsl[1], l.clamp(0.0, 1.0));
          r = out[0];
          g = out[1];
          b = out[2];
        default:
          // 未实现的修饰符（`satMod`/`hueMod`/`comp`/`inv`/`gamma`/`gray` …）
          // **不改色、不假装认识**：静默跳过，按"未施加该效果"处理。
          break;
      }
    }
    if (!touched) return argb;
    return (_q(a) << 24) | (_q(r) << 16) | (_q(g) << 8) | _q(b);
  }

  /// 唯一一次量化：**截断**（不是四舍五入）。
  ///
  /// 依据是**官方主题调色板**这个外部真值（不是自证）：Office 主题
  /// `accent1 = 4F81BD` 的公开派生色
  /// ```text
  ///   Lighter 40% (lumMod 40000 + lumOff 60000) 官方 = B8CCE4
  ///   Darker  25% (lumMod 75000)                官方 = 366092
  /// ```
  /// 本文件的演算 + **最后截断一次** 可逐通道复现这两个值；
  /// 换成四舍五入会得到 `B9CDE5` / `376092`（**每个通道都 +1**）。
  static int _q(double v) => v.clamp(0.0, 255.0).toInt();

  /// RGB（`0..255` 浮点）→ HSL（H/S/L 均归一化到 `[0,1]`）。
  ///
  /// `lumMod`/`lumOff` 作用在 **HSL 的 L** 上：规范原文说 `lumOff`
  /// "shifts the luminance, but with its **hue and saturation unchanged**"
  /// ⇒ 只有 HSL 这个色彩模型能同时表达"H/S 不变、只动 L"。
  static List<double> _rgbToHsl(double r255, double g255, double b255) {
    final r = r255 / 255.0;
    final g = g255 / 255.0;
    final b = b255 / 255.0;
    final maxV = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final minV = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final l = (maxV + minV) / 2;
    if (maxV == minV) return <double>[0, 0, l];
    final d = maxV - minV;
    final s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV);
    double h;
    if (maxV == r) {
      h = (g - b) / d + (g < b ? 6 : 0);
    } else if (maxV == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    return <double>[h / 6, s, l];
  }

  /// HSL（`[0,1]`）→ RGB（`0..255` 浮点，**不量化**）。
  static List<double> _hslToRgb(double h, double s, double l) {
    double channel(double p, double q, double t) {
      var tt = t;
      if (tt < 0) tt += 1;
      if (tt > 1) tt -= 1;
      if (tt < 1 / 6) return p + (q - p) * 6 * tt;
      if (tt < 1 / 2) return q;
      if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6;
      return p;
    }

    if (s <= 0) {
      final v = l * 255;
      return <double>[v, v, v];
    }
    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    return <double>[
      channel(p, q, h + 1 / 3) * 255,
      channel(p, q, h) * 255,
      channel(p, q, h - 1 / 3) * 255,
    ];
  }

  int? _hex(String? v) {
    if (v == null) return null;
    var s = v.trim().replaceAll('#', '');
    if (s.length == 3) s = s.split('').map((c) => '$c$c').join();
    if (s.length != 6) return null;
    final rgb = int.tryParse(s, radix: 16);
    return rgb == null ? null : 0xFF000000 | rgb;
  }

  int? _prstHex(String? name) {
    const preset = <String, int>{
      'black': 0x000000,
      'white': 0xFFFFFF,
      'red': 0xFF0000,
      'green': 0x008000,
      'blue': 0x0000FF,
      'yellow': 0xFFFF00,
      'gray': 0x808080,
      'grey': 0x808080,
      'ltGray': 0xC0C0C0,
      'dkGray': 0x404040,
      'orange': 0xFFA500,
    };
    final rgb = preset[name];
    return rgb == null ? null : 0xFF000000 | rgb;
  }

  // --------------------------------------------------------------- 包/关系

  XmlDocument? xml(String name) {
    if (_xml.containsKey(name)) return _xml[name];
    final data = _parts[name];
    if (data == null) return null;
    try {
      final doc = XmlDocument.parse(utf8.decode(data, allowMalformed: true));
      _xml[name] = doc;
      return doc;
    } catch (_) {
      return null;
    }
  }

  XmlElement? root(String name) {
    final doc = xml(name);
    if (doc == null) return null;
    for (final e in doc.childElements) {
      return e;
    }
    return null;
  }

  /// 关系表：`部件路径` → `{rId: _Rel}`（Target 已解析成绝对包内路径）。
  Map<String, _Rel> relsOf(String partName) {
    final cached = _rels[partName];
    if (cached != null) return cached;
    final dir = _dirOf(partName);
    final base = _baseOf(partName);
    final relsPart = dir.isEmpty ? '_rels/$base.rels' : '$dir/_rels/$base.rels';
    final out = <String, _Rel>{};
    final relRoot = root(relsPart);
    for (final rel in _kids(relRoot, 'Relationship')) {
      final id = _attr(rel, 'Id');
      final target = _attr(rel, 'Target');
      if (id == null || target == null) continue;
      if (_attr(rel, 'TargetMode') == 'External') continue;
      out[id] = _Rel(_attr(rel, 'Type') ?? '', _normPath(partName, target));
    }
    _rels[partName] = out;
    return out;
  }

  String? relTarget(String partName, String? rId, {String? typeSuffix}) {
    if (rId == null) return null;
    final rel = relsOf(partName)[rId];
    if (rel == null) return null;
    if (typeSuffix != null && !rel.type.endsWith(typeSuffix)) return null;
    return rel.target;
  }

  String? relOfType(String partName, String typeSuffix) {
    for (final rel in relsOf(partName).values) {
      if (rel.type.endsWith(typeSuffix)) return rel.target;
    }
    return null;
  }

  List<String> relsOfType(String partName, String typeSuffix) {
    final out = <String>[];
    for (final rel in relsOf(partName).values) {
      if (rel.type.endsWith(typeSuffix)) out.add(rel.target);
    }
    return out;
  }

  // ------------------------------------------------------------------ 入口

  OSlidesDeck run() {
    _unpack();

    final pres = root('ppt/presentation.xml');
    if (pres == null) throw StateError('缺 ppt/presentation.xml');

    _loadTheme(
      relOfType('ppt/presentation.xml', '/theme') ?? 'ppt/theme/theme1.xml',
    );

    final masters = <String, _Master>{
      for (final p in relsOfType('ppt/presentation.xml', '/slideMaster'))
        p: _parseMaster(p),
    };

    final layouts = <String, _Layout>{};
    var layoutCount = 0;
    for (final entry in masters.entries) {
      for (final lp in relsOfType(entry.key, '/slideLayout')) {
        layouts[lp] = _parseLayout(lp, entry.key);
        layoutCount++;
      }
    }

    // 页序：`p:sldIdLst` 是**权威页序**（不能按文件名排）。
    final order = <String>[];
    for (final sldId in _kids(_kid(pres, 'sldIdLst'), 'sldId')) {
      final target = relTarget(
        'ppt/presentation.xml',
        _attr(sldId, 'id'),
        typeSuffix: '/slide',
      );
      if (target != null) order.add(target);
    }
    if (order.isEmpty) {
      final names =
          _parts.keys
              .where((k) => RegExp(r'^ppt/slides/[^/]+\.xml$').hasMatch(k))
              .toList()
            ..sort(
              (a, b) => (_int(_numIn(a)) ?? 0).compareTo(_int(_numIn(b)) ?? 0),
            );
      order.addAll(names);
      if (names.isNotEmpty) {
        degradations.add('presentation.xml 缺 p:sldIdLst，按文件名推定页序');
      }
    }

    final sldSz = _kid(pres, 'sldSz');
    final wEmu = (_dbl(_attr(sldSz, 'cx')) ?? kPptxDefaultWidthEmu);
    final hEmu = (_dbl(_attr(sldSz, 'cy')) ?? kPptxDefaultHeightEmu);

    // 默认文本样式（最低优先级）。
    final defaults = _LevelStyles.parse(_kid(pres, 'defaultTextStyle'), this);

    final slides = <OSlidesDeckSlide>[];
    for (var i = 0; i < order.length; i++) {
      try {
        slides.add(
          _parseSlide(
            order[i],
            order: i,
            defaults: defaults,
            masters: masters,
            layouts: layouts,
          ),
        );
      } catch (e) {
        degradations.add('第 ${i + 1} 页解析失败：$e');
        slides.add(
          OSlidesDeckSlide(
            order: i,
            shapes: const <OSlidesDeckShape>[],
            backgroundArgb: 0xFFFFFFFF,
            backgroundInherited: true,
            notes: '',
            placeholderCount: 0,
            inheritedGeometryCount: 0,
            degradations: <String>['这一页的内容没能解析出来'],
          ),
        );
      }
    }

    final media = <String, Uint8List>{};
    var vectorCount = 0;
    // SVG 已由**自研渲染器**绘制（`office_svg_painter.dart`），所以它**不再**算"画不出的矢量"。
    // 详见 `docs/office-svg-renderer-report.md`。
    var svgCount = 0;
    for (final entry in _parts.entries) {
      if (!entry.key.startsWith('ppt/media/')) continue;
      media[entry.key] = entry.value;
      if (isVectorMediaPart(entry.key)) {
        vectorCount++;
        if (_isSvgMediaPart(entry.key)) svgCount++;
      }
    }

    var unsupported = 0;
    for (final s in slides) {
      unsupported += s.unsupportedCount;
    }

    return OSlidesDeck(
      slides: slides,
      widthPx: wEmu / kPptxEmuPerPx,
      heightPx: hEmu / kPptxEmuPerPx,
      widthEmu: wEmu.round(),
      heightEmu: hEmu.round(),
      layoutCount: layoutCount,
      masterCount: masters.length,
      media: media,
      svgMediaCount: svgCount,
      unrenderableVectorCount: vectorCount - svgCount,
      unsupportedObjectCount: unsupported,
      degradations: List<String>.unmodifiable(degradations),
    );
  }

  String? _numIn(String path) =>
      RegExp(r'(\d+)').firstMatch(_baseOf(path))?.group(1);

  void _unpack() {
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    for (final f in archive.files) {
      if (!f.isFile) continue;
      _parts[f.name] = Uint8List.fromList(f.content as List<int>);
    }
  }

  void _loadTheme(String part) {
    final rootEl = root(part);
    if (rootEl == null) return;
    final themeElements = _kid(rootEl, 'themeElements') ?? rootEl;
    XmlElement? clrScheme = _kid(themeElements, 'clrScheme');
    if (clrScheme == null) {
      for (final d in themeElements.descendantElements) {
        if (d.name.local == 'clrScheme') {
          clrScheme = d;
          break;
        }
      }
    }
    if (clrScheme == null) return;
    for (final c in clrScheme.childElements) {
      final name = c.name.local; // dk1/lt1/dk2/lt2/accent1..6/hlink/folHlink
      for (final inner in c.childElements) {
        if (inner.name.local == 'srgbClr') {
          final v = _attr(inner, 'val');
          if (v != null) scheme[name] = v;
        } else if (inner.name.local == 'sysClr') {
          final v = _attr(inner, 'lastClr') ?? _attr(inner, 'val');
          if (v != null) scheme[name] = v;
        }
      }
    }
  }

  // ------------------------------------------------------------ 母版/版式

  /// `<p:clrMapOvr>` 里的**覆盖色映射**。
  ///
  /// OOXML 的两种写法（ISO/IEC 29500-1 §19.3.1.6 / §19.3.1.7）：
  ///   * `<a:masterClrMapping/>`   —— **继承母版**的映射（本文件的 `null`）；
  ///   * `<a:overrideClrMapping bg1="dk1" tx1="lt1" …/>` —— **本部件自己**的映射。
  ///
  /// ⇒ 返回 `null` 一律表示"继续往上继承"，不要把它当成"空映射"。
  Map<String, String>? _clrMapOverride(XmlElement? rootEl) {
    final override = _kid(_kid(rootEl, 'clrMapOvr'), 'overrideClrMapping');
    if (override == null) return null;
    final out = <String, String>{};
    for (final a in override.attributes) {
      out[a.name.local] = a.value;
    }
    return out.isEmpty ? null : out;
  }

  int? _backgroundArgb(XmlElement? rootEl) {
    // `<p:bg>` 挂在 `<p:cSld>` 下（不是直接在 `<p:sld>`/`<p:sldLayout>` 下）。
    final cSld = _kid(rootEl, 'cSld') ?? rootEl;
    final bgPr = _kid(_kid(cSld, 'bg'), 'bgPr');
    if (bgPr == null) return null;
    if (_kid(bgPr, 'noFill') != null) return null;
    return fillColor(bgPr);
  }

  _Master _parseMaster(String part) {
    final master = _Master(part);
    final rootEl = root(part);
    if (rootEl == null) return master;

    final mapEl = _kid(rootEl, 'clrMap');
    if (mapEl != null) {
      final m = <String, String>{};
      for (final a in mapEl.attributes) {
        m[a.name.local] = a.value;
      }
      master.clrMap = m;
    }
    clrMap = master.clrMap;

    master.backgroundArgb = _backgroundArgb(rootEl);

    final txStyles = _kid(rootEl, 'txStyles');
    if (txStyles != null) {
      master.titleStyle = _LevelStyles.parse(
        _kid(txStyles, 'titleStyle'),
        this,
      );
      master.bodyStyle = _LevelStyles.parse(_kid(txStyles, 'bodyStyle'), this);
      master.otherStyle = _LevelStyles.parse(
        _kid(txStyles, 'otherStyle'),
        this,
      );
    }

    final spTree = _kid(_kid(rootEl, 'cSld'), 'spTree');
    master.spTree = spTree;
    if (spTree != null) {
      for (final ph in _placeholders(spTree, part)) {
        if (ph.index != null) master.byIndex[ph.index!] = ph;
        if (ph.type != null) master.byType[ph.type!] = ph;
      }
    }
    return master;
  }

  _Layout _parseLayout(String part, String masterPart) {
    final layout = _Layout(part, masterPart);
    final rootEl = root(part);
    if (rootEl == null) return layout;
    // ⚠️ 解析**版式自己的** `<a:defRPr>` 颜色时必须已经切到版式生效的色映射，
    // 否则版式里的引用色会拿母版的映射去查（见 [_clrMapOverride]）。
    layout.clrMap = _clrMapOverride(rootEl);
    if (layout.clrMap != null) clrMap = layout.clrMap!;
    layout.backgroundArgb = _backgroundArgb(rootEl);
    final spTree = _kid(_kid(rootEl, 'cSld'), 'spTree');
    if (spTree == null) return layout;
    for (final ph in _placeholders(spTree, part)) {
      if (ph.index != null) layout.byIndex[ph.index!] = ph;
      if (ph.type != null) layout.byType[ph.type!] = ph;
    }
    for (final flat in _flatShapes(spTree, part)) {
      if (_placeholderOf(flat.element) != null) continue;
      layout.decor.add(flat);
    }
    return layout;
  }

  /// 收集一个 spTree 里的占位符（几何 + 样式 + bodyPr）。
  List<_Placeholder> _placeholders(XmlElement spTree, String part) {
    final out = <_Placeholder>[];
    for (final e in _shapeElements(spTree)) {
      final ph = _placeholderOf(e);
      if (ph == null) continue;
      final txBody = _kid(e, 'txBody');
      final bodyPr = _kid(txBody, 'bodyPr');
      out.add(
        _Placeholder(
          index: ph.$1,
          type: ph.$2,
          xfrm: _Xfrm.parse(_kid(e, 'spPr')),
          styles: _LevelStyles.parse(txBody, this),
          anchor: _attr(bodyPr, 'anchor'),
          wrap: _attr(bodyPr, 'wrap') != 'none',
          insets: _insetsOf(bodyPr),
        ),
      );
    }
    return out;
  }

  List<double> _insetsOf(XmlElement? bodyPr) {
    double emu(String local, double fallbackEmu) =>
        _dbl(_attr(bodyPr, local)) ?? fallbackEmu;
    return <double>[
      emu('lIns', kPptxDefaultInsetLR),
      emu('tIns', kPptxDefaultInsetTB),
      emu('rIns', kPptxDefaultInsetLR),
      emu('bIns', kPptxDefaultInsetTB),
    ];
  }

  /// 形状元素（文档顺序 = z 序），并展开组合的平移。
  Iterable<XmlElement> _shapeElements(XmlElement spTree) sync* {
    for (final c in spTree.childElements) {
      switch (c.name.local) {
        case 'sp':
        case 'pic':
        case 'graphicFrame':
        case 'cxnSp':
        case 'grpSp':
          yield c;
      }
    }
  }

  List<_FlatShape> _flatShapes(XmlElement spTree, String part) {
    final out = <_FlatShape>[];
    void walk(XmlElement tree, double dx, double dy) {
      for (final c in _shapeElements(tree)) {
        if (c.name.local == 'grpSp') {
          final g = _Xfrm.parse(_kid(c, 'grpSpPr'));
          final chOff = _kid(_kid(c, 'grpSpPr'), 'xfrm');
          final chOffEl = _kid(chOff, 'chOff');
          final nx =
              dx + (g == null ? 0 : g.offX) - (_dbl(_attr(chOffEl, 'x')) ?? 0);
          final ny =
              dy + (g == null ? 0 : g.offY) - (_dbl(_attr(chOffEl, 'y')) ?? 0);
          walk(c, nx, ny);
          continue;
        }
        out.add(_FlatShape(c, dx, dy));
      }
    }

    walk(spTree, 0, 0);
    return out;
  }

  /// `<p:nvPr><p:ph idx="0" type="title"/>` → `(idx, type)`；非占位符 → null。
  (int?, String?)? _placeholderOf(XmlElement shape) {
    for (final nv in _nvPrContainers(shape)) {
      final ph = _kid(nv, 'ph');
      if (ph != null) {
        // 无 type 的 `<p:ph/>` 是 body 占位符（OOXML 默认 obj/body）。
        return (_int(_attr(ph, 'idx')), _attr(ph, 'type') ?? 'body');
      }
    }
    return null;
  }

  Iterable<XmlElement> _nvPrContainers(XmlElement shape) sync* {
    const holders = <String>[
      'nvSpPr',
      'nvPicPr',
      'nvGraphicFramePr',
      'nvCxnSpPr',
      'nvGrpSpPr',
    ];
    for (final holder in holders) {
      final c = _kid(shape, holder);
      if (c == null) continue;
      final nv = _kid(c, 'nvPr');
      if (nv != null) yield nv;
    }
  }

  // ------------------------------------------------------------------ 单页

  OSlidesDeckSlide _parseSlide(
    String part, {
    required int order,
    required _LevelStyles defaults,
    required Map<String, _Master> masters,
    required Map<String, _Layout> layouts,
  }) {
    final layoutPart = relOfType(part, '/slideLayout');
    final layout = layoutPart == null ? null : layouts[layoutPart];
    final master = layout != null
        ? masters[layout.masterPart]
        : (masters.isEmpty ? null : masters.values.first);

    final rootEl = root(part);
    final spTree = _kid(_kid(rootEl, 'cSld'), 'spTree');

    final shapes = <OSlidesDeckShape>[];
    final problems = <String>[];
    final notesText = <String>[];
    var placeholders = 0;
    var inherited = 0;

    // ⚠️ **色映射（`clrMap`）的继承链是有顺序的**（2026-09-22 补）：
    //   本页 `<p:clrMapOvr><a:overrideClrMapping/>` ＞ 版式 `clrMapOvr`
    //   ＞ 母版 `<p:clrMap>` ＞ 空（原名直查主题）。
    // `<a:masterClrMapping/>` 的语义是"用母版的"，所以它 ⇒ null ⇒ 继续往下取。
    //
    // 而且**三段各自用自己的映射**去解引用：母版装饰用母版的、版式装饰用版式的、
    // 本页形状用本页的 —— 以前整页共用母版那一份，版式/本页的 `overrideClrMapping`
    // 会被忽略（三份真样本里都只写了 `<a:masterClrMapping/>`，所以没暴露）。
    final masterMap = master?.clrMap ?? const <String, String>{};
    final layoutMap = layout?.clrMap ?? masterMap;
    final slideMap = _clrMapOverride(rootEl) ?? layoutMap;

    // ① 母版装饰（非占位符；母版占位符是版式的模板，不直接画）。
    clrMap = masterMap;
    if (master?.spTree != null) {
      for (final flat in _flatShapes(master!.spTree!, master.part)) {
        if (_placeholderOf(flat.element) != null) continue;
        final s = _decorShape(flat, master.part, problems);
        if (s != null) shapes.add(s);
      }
    }

    // ② 版式装饰（版式上的图片/色块 —— 没有它们幻灯片就成了白纸）。
    clrMap = layoutMap;
    if (layout != null) {
      for (final flat in layout.decor) {
        final s = _decorShape(flat, layout.part, problems);
        if (s != null) shapes.add(s);
      }
    }

    // ③ 本页形状（占位符做三级继承）。
    clrMap = slideMap;
    if (spTree != null) {
      for (final flat in _flatShapes(spTree, part)) {
        final el = flat.element;
        final ph = _placeholderOf(el);
        if (ph != null) {
          placeholders++;
          final lp = layout?.findPh(index: ph.$1, type: ph.$2);
          final mp = master?.findPh(index: ph.$1, type: ph.$2);
          final built = _placeholderShape(
            flat,
            ph,
            lp,
            mp,
            defaults,
            master,
            problems,
          );
          if (built == null) continue;
          shapes.add(built);
          if (built.geometryInherited) inherited++;
          continue;
        }
        final s = _decorShape(flat, part, problems);
        if (s != null) shapes.add(s);
      }
    }

    // 备注（`notesSlides/notesSlideN.xml`）。
    final notesPart = relOfType(part, '/notesSlide');
    final notesRoot = notesPart == null ? null : root(notesPart);
    final notesTree = notesRoot == null
        ? null
        : _kid(_kid(notesRoot, 'cSld'), 'spTree');
    if (notesPart != null && notesTree != null) {
      for (final flat in _flatShapes(notesTree, notesPart)) {
        final body = _kid(flat.element, 'txBody');
        for (final p in _kids(body, 'p')) {
          final t = _runs(
            p,
            _LevelStyles.empty.at(0),
            0,
          ).$1.map((r) => r.text).join().trim();
          if (t.isNotEmpty) notesText.add(t);
        }
      }
    }

    // 背景：本页 → 版式 → 母版 → 白。
    final ownBg = _backgroundArgb(rootEl);
    final bg = ownBg ?? layout?.backgroundArgb ?? master?.backgroundArgb;
    final backgroundInherited = ownBg == null;

    return OSlidesDeckSlide(
      order: order,
      shapes: List<OSlidesDeckShape>.unmodifiable(shapes),
      backgroundArgb: bg ?? 0xFFFFFFFF,
      backgroundInherited: backgroundInherited,
      notes: notesText.join('\n'),
      placeholderCount: placeholders,
      inheritedGeometryCount: inherited,
      degradations: List<String>.unmodifiable(problems),
    );
  }

  /// 占位符形状：几何 + 文本样式的**母版/版式继承**。
  OSlidesDeckShape? _placeholderShape(
    _FlatShape flat,
    (int?, String?) ph,
    _Placeholder? layoutPh,
    _Placeholder? masterPh,
    _LevelStyles defaults,
    _Master? master,
    List<String> notes,
  ) {
    final el = flat.element;
    final spPr = _kid(el, 'spPr');
    final own = _Xfrm.parse(spPr)?.shifted(flat.dx, flat.dy);

    // ⭐ 继承：本页没有可用 xfrm 时，依次取版式 → 母版同名占位符的几何。
    var xfrm = own;
    var inheritedGeometry = false;
    if (xfrm == null || !xfrm.isUsable) {
      final lp = layoutPh?.xfrm;
      final mp = masterPh?.xfrm;
      final source = (lp != null && lp.isUsable)
          ? lp
          : ((mp != null && mp.isUsable) ? mp : null);
      if (source == null) {
        // `sldNum` / `dt` / `ftr` 这类占位符文件里本就为空，静默跳过。
        if (!_isSilentPlaceholder(ph.$2)) {
          notes.add('占位符 ${ph.$2 ?? '(无类型)'} 在母版/版式里都没有几何');
        }
        return null;
      }
      xfrm = _Xfrm(
        offX: source.offX,
        offY: source.offY,
        extCx: source.extCx,
        extCy: source.extCy,
        rot: own?.rot ?? source.rot,
      );
      inheritedGeometry = true;
    }

    // 文本样式：默认 → 母版 txStyles → 母版占位符 → 版式占位符 → 本页占位符。
    var styles = defaults;
    styles = styles.merge(master?.styleFor(ph.$2));
    styles = styles.merge(masterPh?.styles);
    styles = styles.merge(layoutPh?.styles);
    final txBody = _kid(el, 'txBody');
    styles = styles.merge(_LevelStyles.parse(txBody, this));

    final bodyPr = _kid(txBody, 'bodyPr');
    final insets = _insetsOf(bodyPr);
    final paragraphs = _paragraphs(txBody, styles);

    final fill = fillColor(spPr);
    final line = lineColor(spPr);
    final preset = _attr(_kid(spPr, 'prstGeom'), 'prst') ?? 'rect';
    final kind = (fill != null || line != null)
        ? _kindForPreset(preset)
        : OSlidesShapeKind.text;

    return OSlidesDeckShape(
      id: 'ph-${ph.$1}-${ph.$2}',
      kind: kind,
      preset: preset,
      left: pptxEmuToPx(xfrm.offX),
      top: pptxEmuToPx(xfrm.offY),
      width: pptxEmuToPx(xfrm.extCx),
      height: pptxEmuToPx(xfrm.extCy),
      rotationDegrees: pptxRotationToDegrees(xfrm.rot),
      geometryInherited: inheritedGeometry,
      placeholderIndex: ph.$1,
      placeholderType: ph.$2,
      fillArgb: fill,
      lineArgb: line,
      lineWidthPx: lineWidthPx(spPr),
      paragraphs: paragraphs,
      anchor: _attr(bodyPr, 'anchor') ?? layoutPh?.anchor ?? masterPh?.anchor,
      wrap: _attr(bodyPr, 'wrap') != 'none',
      insetLeftPx: pptxEmuToPx(insets[0]),
      insetTopPx: pptxEmuToPx(insets[1]),
      insetRightPx: pptxEmuToPx(insets[2]),
      insetBottomPx: pptxEmuToPx(insets[3]),
    );
  }

  /// 非占位符形状（图片 / 自动图形 / 线条 / 暂不支持对象）。
  OSlidesDeckShape? _decorShape(
    _FlatShape flat,
    String part,
    List<String> notes,
  ) {
    final el = flat.element;
    final tag = el.name.local;
    final spPr = _kid(el, 'spPr');
    final own = _Xfrm.parse(spPr)?.shifted(flat.dx, flat.dy);
    // `<p:pic>` 的 xfrm 也放在 `<p:spPr>`；`graphicFrame` 用 `<p:xfrm>`。
    final xfrm = own ?? _Xfrm.parse(el)?.shifted(flat.dx, flat.dy);

    final isPic = tag == 'pic';
    final isFrame = tag == 'graphicFrame';
    final isLine =
        tag == 'cxnSp' ||
        const <String>{
          'line',
          'straightConnector1',
          'bentConnector2',
          'bentConnector3',
          'curvedConnector3',
        }.contains(_attr(_kid(spPr, 'prstGeom'), 'prst'));

    if (xfrm == null || !xfrm.isUsable) {
      if (isFrame) {
        notes.add('暂不支持的对象（无几何）');
        return null;
      }
      // 装饰图形没有几何 → 不猜坐标，静默跳过（不影响正文）。
      return null;
    }

    if (isFrame) {
      return OSlidesDeckShape(
        id: 'frame-${flat.dx.toInt()}-${flat.dy.toInt()}',
        kind: OSlidesShapeKind.unsupported,
        preset: 'frame',
        left: pptxEmuToPx(xfrm.offX),
        top: pptxEmuToPx(xfrm.offY),
        width: pptxEmuToPx(xfrm.extCx),
        height: pptxEmuToPx(xfrm.extCy),
        rotationDegrees: pptxRotationToDegrees(xfrm.rot),
        geometryInherited: false,
        unsupportedLabel: _graphicFrameLabel(el),
      );
    }

    if (isPic) {
      final blip = _kid(_kid(el, 'blipFill'), 'blip');
      final imagePart = relTarget(
        part,
        _attr(blip, 'embed'),
        typeSuffix: '/image',
      );
      if (imagePart == null || !_parts.containsKey(imagePart)) {
        notes.add('图片引用失效（包内找不到媒体）');
        return null;
      }
      final cNvPr = _kid(_kid(el, 'nvPicPr'), 'cNvPr');
      return OSlidesDeckShape(
        id: 'pic-${flat.dx.toInt()}-${flat.dy.toInt()}',
        kind: OSlidesShapeKind.picture,
        preset: 'rect',
        left: pptxEmuToPx(xfrm.offX),
        top: pptxEmuToPx(xfrm.offY),
        width: pptxEmuToPx(xfrm.extCx),
        height: pptxEmuToPx(xfrm.extCy),
        rotationDegrees: pptxRotationToDegrees(xfrm.rot),
        geometryInherited: false,
        imagePart: imagePart,
        imageAlt: _attr(cNvPr, 'descr') ?? _attr(cNvPr, 'name'),
        lineArgb: lineColor(spPr),
        lineWidthPx: lineWidthPx(spPr),
      );
    }

    final preset = _attr(_kid(spPr, 'prstGeom'), 'prst') ?? 'rect';
    final fill = fillColor(spPr);
    final line = lineColor(spPr);
    final txBody = _kid(el, 'txBody');
    final paragraphs = _paragraphs(txBody, _LevelStyles.empty);
    final bodyPr = _kid(txBody, 'bodyPr');
    final insets = _insetsOf(bodyPr);
    final hasText = paragraphs.any((p) => p.text.trim().isNotEmpty);

    var kind = OSlidesShapeKind.text;
    if (isLine) {
      kind = OSlidesShapeKind.line;
    } else if (fill != null || line != null) {
      kind = _kindForPreset(preset);
    } else if (!hasText) {
      // 透明又没有文字的形状 = 不可见；不占位（避免遮挡）。
      return null;
    }

    return OSlidesDeckShape(
      id: 'sp-${flat.dx.toInt()}-${flat.dy.toInt()}',
      kind: kind,
      preset: preset,
      left: pptxEmuToPx(xfrm.offX),
      top: pptxEmuToPx(xfrm.offY),
      width: pptxEmuToPx(xfrm.extCx),
      height: pptxEmuToPx(xfrm.extCy),
      rotationDegrees: pptxRotationToDegrees(xfrm.rot),
      geometryInherited: false,
      fillArgb: fill,
      lineArgb: line,
      lineWidthPx: lineWidthPx(spPr),
      paragraphs: paragraphs,
      anchor: _attr(bodyPr, 'anchor'),
      wrap: _attr(bodyPr, 'wrap') != 'none',
      insetLeftPx: pptxEmuToPx(insets[0]),
      insetTopPx: pptxEmuToPx(insets[1]),
      insetRightPx: pptxEmuToPx(insets[2]),
      insetBottomPx: pptxEmuToPx(insets[3]),
    );
  }

  String _graphicFrameLabel(XmlElement el) {
    final graphicData = _kid(el, 'graphicData');
    final uri = _attr(graphicData, 'uri') ?? '';
    if (uri.contains('chart')) {
      return dataText('officeSlidesGraphicChart', '图表');
    }
    if (uri.contains('diagram')) {
      return dataText('officeSlidesGraphicDiagram', 'SmartArt 图示');
    }
    if (uri.contains('table')) {
      return dataText('officeSlidesGraphicTable', '表格');
    }
    if (uri.contains('ole')) {
      return dataText('officeSlidesGraphicOle', '嵌入对象');
    }
    return dataText('officeSlidesGraphicObject', '对象');
  }

  OSlidesShapeKind _kindForPreset(String preset) {
    switch (preset) {
      case 'ellipse':
      case 'circle':
        return OSlidesShapeKind.ellipse;
      case 'roundRect':
      case 'round2SameRect':
      case 'round2DiagRect':
      case 'snipRoundRect':
        return OSlidesShapeKind.roundRect;
      case 'triangle':
      case 'rtTriangle':
      case 'diamond':
        return OSlidesShapeKind.triangle;
      case 'line':
      case 'straightConnector1':
      case 'bentConnector2':
        return OSlidesShapeKind.line;
      default:
        return OSlidesShapeKind.rectangle;
    }
  }

  /// `sldNum` / `dt` / `ftr` 这类占位符文件里通常为空，**静默跳过**不算降级。
  bool _isSilentPlaceholder(String? type) =>
      type == 'sldNum' || type == 'dt' || type == 'ftr';

  /// 解析 `<p:txBody>` 的全部段落。
  List<OSlidesDeckParagraph> _paragraphs(
    XmlElement? txBody,
    _LevelStyles levels,
  ) {
    final out = <OSlidesDeckParagraph>[];
    final counters = <int, int>{};
    for (final p in _kids(txBody, 'p')) {
      final pPr = _kid(p, 'pPr');
      final level = (_int(_attr(pPr, 'lvl')) ?? 0).clamp(0, 8);
      final merged = levels.at(level).merge(_LevelStyles._parStyle(pPr, this));
      final (runs, hasContent) = _runs(p, merged, level);
      final bullet = _bulletFor(merged, level, counters);
      if (!hasContent && bullet == null) {
        out.add(
          OSlidesDeckParagraph(
            runs: const <OSlidesDeckRun>[],
            level: level,
            align: merged.align,
            leftInsetPx: pptxEmuToPx(
              (merged.marLEmu ?? 0) + (merged.indentEmu ?? 0),
            ),
            lineSpacingPct: merged.lineSpacingPct,
            spaceBeforePt: merged.spaceBeforePt,
            spaceAfterPt: merged.spaceAfterPt,
          ),
        );
        continue;
      }
      out.add(
        OSlidesDeckParagraph(
          runs: runs,
          level: level,
          align: merged.align,
          bullet: bullet,
          leftInsetPx: pptxEmuToPx(
            (merged.marLEmu ?? 0) + (merged.indentEmu ?? 0),
          ),
          lineSpacingPct: merged.lineSpacingPct,
          spaceBeforePt: merged.spaceBeforePt,
          spaceAfterPt: merged.spaceAfterPt,
        ),
      );
    }
    return out;
  }

  /// 一个段落里的 run 列表；返回 `(runs, 是否有内容)`。
  (List<OSlidesDeckRun>, bool) _runs(XmlElement p, _ParStyle style, int level) {
    final runs = <OSlidesDeckRun>[];
    var hasContent = false;
    for (final child in p.childElements) {
      switch (child.name.local) {
        case 'r':
          final rPr = _LevelStyles.runStyle(_kid(child, 'rPr'), this);
          final text = _kids(child, 't').map((t) => t.innerText).join();
          runs.add((style.run ?? _RunStyle.empty).merge(rPr).toRun(text));
          if (text.trim().isNotEmpty) hasContent = true;
        case 'br':
          runs.add((style.run ?? _RunStyle.empty).toRun('\n'));
        case 'fld':
          final text = _kids(child, 't').map((t) => t.innerText).join();
          runs.add(
            (style.run ?? _RunStyle.empty)
                .merge(_LevelStyles.runStyle(_kid(child, 'rPr'), this))
                .toRun(text),
          );
          if (text.trim().isNotEmpty) hasContent = true;
      }
    }
    return (runs, hasContent);
  }

  /// 项目符号文本；`buNone` → null；自动编号按层级计数。
  String? _bulletFor(_ParStyle style, int level, Map<int, int> counters) {
    if (style.bulletNone == true) return null;
    if (style.bulletChar != null) return style.bulletChar;
    final type = style.bulletAutoNumType;
    if (type == null) return null;
    final start = style.bulletAutoNumStart ?? 1;
    final n = (counters[level] ?? (start - 1)) + 1;
    counters[level] = n;
    if (type.startsWith('alpha')) {
      final letter = String.fromCharCode(96 + ((n - 1) % 26) + 1);
      return type.startsWith('alphaUc')
          ? '${letter.toUpperCase()}.'
          : '$letter.';
    }
    if (type.startsWith('roman')) {
      final r = _roman(n);
      return type.startsWith('romanUc') ? '${r.toUpperCase()}.' : '$r.';
    }
    return '$n.';
  }

  String _roman(int n) {
    const table = <List<Object>>[
      [1000, 'm'],
      [900, 'cm'],
      [500, 'd'],
      [400, 'cd'],
      [100, 'c'],
      [90, 'xc'],
      [50, 'l'],
      [40, 'xl'],
      [10, 'x'],
      [9, 'ix'],
      [5, 'v'],
      [4, 'iv'],
      [1, 'i'],
    ];
    var v = n.clamp(1, 3999);
    final out = StringBuffer();
    for (final row in table) {
      final value = row[0] as int;
      while (v >= value) {
        out.write(row[1] as String);
        v -= value;
      }
    }
    return out.toString();
  }
}
