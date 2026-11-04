// `.oslides` **合成夹具**：内存里拼一份"最小但结构完整"的 pptx。
//
// ## 为什么需要它（而不是只用真机样本）
// 三份真机样本（`technology` / `dynamic` / `celestial`）里的颜色**全部是字面
// `srgbClr`** —— 逐字统计（2026-09-22，见 `docs/oslides-display-rework-report.md`）：
//
// ```
// ppt/{slides,slideLayouts,slideMasters}/*.xml 里的出现次数
//   srgbClr 302 / 308 / 217      alpha 25 / 14 / 19
//   schemeClr 0    sysClr 0    prstClr 0
//   lumMod 0   lumOff 0   tint 0   shade 0
// ```
//
// ⇒ **引用色与修饰符演算在真样本上根本无法被观测**。要证明这段代码是活的、
// 且算得对，就必须自己造一份**含 `schemeClr`/`lumMod`/`lumOff`/`tint`/`shade`/
// `sysClr`/`prstClr`/`overrideClrMapping` 的合法 pptx**。
//
// ## 这份夹具的定位（**不许含糊**）
// * 它证明的是：**规范推导的实现**在真实解析路径（`OSlidesDeck.parse`）上
//   确实生效、且数值符合 ISO/IEC 29500-1 的原文规则；
// * 它**不**证明"真机样本因此变好看了" —— 样本里这些修饰符出现次数是 0，
//   对那些画面的效果**就是 0**。报告里分开写。
//
// ## 结构与真 pptx 同构的部分（缺一不可）
// * `ppt/presentation.xml`：`p:sldMasterIdLst` / `p:sldIdLst` / `p:sldSz`
//   （页序来自 `sldIdLst`，画布比例来自 `sldSz`）；
// * 四张关系表（presentation / master / slide / theme）+ 母版→版式、幻灯片→版式；
// * `ppt/theme/theme1.xml` 的 `a:clrScheme`（10 色）。
import 'dart:typed_data';

import 'package:archive/archive.dart';

const String _nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const String _nsP =
    'http://schemas.openxmlformats.org/presentationml/2006/main';
const String _nsR =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const String _nsRel =
    'http://schemas.openxmlformats.org/package/2006/relationships';
const String _tBase =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

/// 一份含全部 10 个主题槽位的 `clrScheme`。
///
/// 取值与三份真机样本的 `ppt/theme/theme1.xml` **逐字相同**（各槽位颜色互不
/// 相同 ⇒ 取错槽位不会假通过）：
/// ```
/// dk1 000000 (sysClr windowText)   lt1 FFFFFF (sysClr window)
/// dk2 1F497D                       lt2 EEECE1
/// accent1 4F81BD  accent2 C0504D  accent3 9BBB59
/// accent4 8064A2  accent5 4BACC6  accent6 F79646
/// hlink 0000FF    folHlink 800080
/// ```
const String syntheticClrScheme =
    '<a:clrScheme name="Theme1">'
    '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>'
    '<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>'
    '<a:dk2><a:srgbClr val="1F497D"/></a:dk2>'
    '<a:lt2><a:srgbClr val="EEECE1"/></a:lt2>'
    '<a:accent1><a:srgbClr val="4F81BD"/></a:accent1>'
    '<a:accent2><a:srgbClr val="C0504D"/></a:accent2>'
    '<a:accent3><a:srgbClr val="9BBB59"/></a:accent3>'
    '<a:accent4><a:srgbClr val="8064A2"/></a:accent4>'
    '<a:accent5><a:srgbClr val="4BACC6"/></a:accent5>'
    '<a:accent6><a:srgbClr val="F79646"/></a:accent6>'
    '<a:hlink><a:srgbClr val="0000FF"/></a:hlink>'
    '<a:folHlink><a:srgbClr val="800080"/></a:folHlink>'
    '</a:clrScheme>';

/// 母版默认 `<p:clrMap>`（与真样本逐字相同）。
const String syntheticClrMap =
    '<p:clrMap folHlink="folHlink" hlink="hlink" accent6="accent6" '
    'accent5="accent5" accent4="accent4" accent3="accent3" accent2="accent2" '
    'accent1="accent1" bg2="lt2" bg1="lt1" tx2="dk2" tx1="dk1"/>';

/// `(rId, Type 后缀, Target)` —— Target 写成**真 pptx 里的相对路径**
/// （`slideMasters/slideMaster1.xml`、`../slideLayouts/slideLayout1.xml`），
/// 好让 `_normPath` 的解析路径和真文件完全一致。
String _relXml(List<(String, String, String)> items) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="$_nsRel">'
    '${items.map((e) => '<Relationship Id="${e.$1}" Type="$_tBase${e.$2}" Target="${e.$3}"/>').join()}'
    '</Relationships>';

/// 拼装合成 pptx 字节。
///
/// [slideSpTree]、[layoutExtraShapes]、[masterExtraShapes] 直接写进各自的
/// `<p:spTree>`；其余参数是"可选地塞进某个部件的元素"。
Uint8List buildSyntheticPptx({
  required String slideSpTree,
  String? slideBg,
  String? layoutBg,
  String? masterBg,
  String? slideBgXml,
  String? layoutBgXml,
  String? masterBgXml,
  String? slideClrMapOvr,
  String? layoutClrMapOvr,
  String? masterClrMap,
  String? layoutExtraShapes,
  String? masterExtraShapes,
  String? clrScheme,
}) {
  final presentation =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:presentation xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP">'
      '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
      '<p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>'
      '<p:sldSz cx="9144000" cy="5143500"/>'
      '</p:presentation>';

  final master =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sldMaster xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP">'
      '${masterClrMap ?? syntheticClrMap}'
      '<p:cSld>'
      '${masterBgXml ?? '<p:bg><p:bgPr><a:solidFill><a:srgbClr val="${masterBg ?? 'FFFFFF'}"/></a:solidFill></p:bgPr></p:bg>'}'
      '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
      '</p:nvGrpSpPr><p:grpSpPr/>${masterExtraShapes ?? ''}</p:spTree>'
      '</p:cSld></p:sldMaster>';

  final layout =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sldLayout xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP">'
      '${layoutClrMapOvr ?? '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>'}'
      '<p:cSld>'
      '${layoutBgXml ?? (layoutBg == null ? '' : '<p:bg><p:bgPr><a:solidFill><a:srgbClr val="$layoutBg"/></a:solidFill></p:bgPr></p:bg>')}'
      '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
      '</p:nvGrpSpPr><p:grpSpPr/>${layoutExtraShapes ?? ''}</p:spTree>'
      '</p:cSld></p:sldLayout>';

  final slide =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sld xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP">'
      '${slideClrMapOvr == null ? '' : '<p:clrMapOvr>$slideClrMapOvr</p:clrMapOvr>'}'
      '<p:cSld>'
      '${slideBgXml ?? (slideBg == null ? '' : '<p:bg><p:bgPr><a:solidFill><a:srgbClr val="$slideBg"/></a:solidFill></p:bgPr></p:bg>')}'
      '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
      '</p:nvGrpSpPr><p:grpSpPr/>$slideSpTree</p:spTree>'
      '</p:cSld></p:sld>';

  final theme =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<a:theme xmlns:a="$_nsA" name="Office"><a:themeElements>'
      '${clrScheme ?? syntheticClrScheme}'
      '<a:fontScheme name="Office"/><a:fmtScheme name="Office"/>'
      '</a:themeElements></a:theme>';

  final archive = Archive()
    ..addFile(ArchiveFile.string('ppt/presentation.xml', presentation))
    ..addFile(
      ArchiveFile.string(
        'ppt/_rels/presentation.xml.rels',
        _relXml(const <(String, String, String)>[
          ('rId1', '/slideMaster', 'slideMasters/slideMaster1.xml'),
          ('rId2', '/slide', 'slides/slide1.xml'),
          ('rId3', '/theme', 'theme/theme1.xml'),
        ]),
      ),
    )
    ..addFile(ArchiveFile.string('ppt/theme/theme1.xml', theme))
    ..addFile(ArchiveFile.string('ppt/slideMasters/slideMaster1.xml', master))
    ..addFile(
      ArchiveFile.string(
        'ppt/slideMasters/_rels/slideMaster1.xml.rels',
        _relXml(const <(String, String, String)>[
          ('rId1', '/slideLayout', '../slideLayouts/slideLayout1.xml'),
        ]),
      ),
    )
    ..addFile(ArchiveFile.string('ppt/slideLayouts/slideLayout1.xml', layout))
    ..addFile(ArchiveFile.string('ppt/slides/slide1.xml', slide))
    ..addFile(
      ArchiveFile.string(
        'ppt/slides/_rels/slide1.xml.rels',
        _relXml(const <(String, String, String)>[
          ('rId1', '/slideLayout', '../slideLayouts/slideLayout1.xml'),
        ]),
      ),
    );
  return ZipEncoder().encodeBytes(archive);
}

/// 一个按 EMU 坐标绝对定位的矩形形状（`p:sp`），填充由 [fill] 原文给出。
///
/// [fill] 例：`<a:solidFill><a:schemeClr val="accent1"><a:lumMod val="40000"/>`
/// `<a:lumOff val="60000"/></a:schemeClr></a:solidFill>`
String syntheticRect({
  required int id,
  required String fill,
  int x = 0,
  int y = 0,
  int cx = 9525 * 100,
  int cy = 9525 * 50,
}) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="rect$id"/><p:cNvSpPr/><p:nvPr/>'
    '</p:nvSpPr><p:spPr>'
    '<a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
    '$fill<a:ln/>'
    '</p:spPr></p:sp>';

/// 便捷入口：一份只含 [fills] 各一个矩形的合成 pptx（形状沿 y 轴错开，
/// 顺序即文档顺序 ⇒ 形状下标 = fills 下标）。
Uint8List syntheticPptxWithFills(
  List<String> fills, {
  String? slideBg,
  String? layoutBg,
  String? masterBg,
  String? slideBgXml,
  String? layoutBgXml,
  String? masterBgXml,
  String? slideClrMapOvr,
  String? layoutClrMapOvr,
  String? masterClrMap,
  String? clrScheme,
}) {
  final shapes = <String>[];
  for (var i = 0; i < fills.length; i++) {
    shapes.add(
      syntheticRect(id: 2 + i, fill: fills[i], x: 0, y: 9525 * 40 * i),
    );
  }
  return buildSyntheticPptx(
    slideSpTree: shapes.join(),
    slideBg: slideBg,
    layoutBg: layoutBg,
    masterBg: masterBg,
    slideBgXml: slideBgXml,
    layoutBgXml: layoutBgXml,
    masterBgXml: masterBgXml,
    slideClrMapOvr: slideClrMapOvr,
    layoutClrMapOvr: layoutClrMapOvr,
    masterClrMap: masterClrMap,
    clrScheme: clrScheme,
  );
}
