// **DOCX（OOXML）阅读视图** —— `.odoc` 的首选渲染路径（O1 重做）。
//
// 数据来源：`office_doc_ooxml.dart`（解析服务端 `Files:download` 回来的标准 DOCX）。
// 版面容器：`office_doc_paper.dart`（A4 纸 + 真实页边距 + 分页 + 双指缩放 + 适宽）。
//
// ## 与 WPS / MS Office 安卓版的对应关系（用户预期）
//   | 用户看到的东西 | 这里的来源 |
//   |---|---|
//   | A4 白纸 + 灰底 + 页间距 | `w:sectPr/w:pgSz`（11906×16838 twips）+ 纸面投影 |
//   | 左右上下真实页边距 | `w:pgMar`（1440 twips = 96px = 2.54cm） |
//   | 标题层级（字号/段前段后） | `w:pStyle` → `styles.xml` 的 `outlineLvl`/`sz`/`spacing` |
//   | 粗/斜/下划线/颜色/字体 | `w:rPr` 的 `b`/`i`/`u`/`color`/`rFonts` |
//   | 段对齐（居中/右/两端） | `w:jc` |
//   | 项目符号 ● ○ ■ / 编号 | `w:numPr` + `numbering.xml` 的 `lvlText` |
//   | 表格列宽（**不是均分**） | `w:tblGrid/w:gridCol` |
//   | 单元格边框/底色/垂直居中 | `w:tcPr` 的 `tcBorders`/`shd`/`vAlign` |
//   | 图片尺寸 | `w:drawing` 的 `wp:extent`（EMU） |
//   | 页眉页脚 | `word/header*.xml` / `footer*.xml`（印在**页边距**里） |
//   | 页码指示 + 双指缩放 + 适宽 | `OfficeDocPaperView` |
//
// **没有**"只读渲染/版式从简"这类开发者横幅：纸面本身就是最终形态。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../core/i18n/l10n.dart';

import '../../core/theme/app_tokens.dart';
import 'office_doc_ooxml.dart';
import 'office_doc_paper.dart';
import 'office_doc_style.dart' show officeDocParseColor;

/// 用 DOCX 数据渲染一份 `.odoc`。
class OfficeDocxView extends StatelessWidget {
  const OfficeDocxView({super.key, required this.doc, this.showChrome = true});

  final ODocxDocument doc;

  /// 是否显示纸面外框（灰底/页码指示/适宽）。测试里关掉可只量正文。
  final bool showChrome;

  @override
  Widget build(BuildContext context) {
    final setup = doc.pageSetup;
    final metrics = OfficeDocPaperMetrics(
      pageWidth: setup.widthPx,
      pageHeight: setup.heightPx,
      marginLeft: setup.marginLeftPx,
      marginRight: setup.marginRightPx,
      marginTop: setup.marginTopPx,
      marginBottom: setup.marginBottomPx,
      pageType: setup.isA4 ? 'a4' : 'custom',
      orientation: setup.orientation,
    );

    if (doc.isEmpty) {
      return const _EmptyDoc();
    }

    final contentWidth = metrics.contentWidth;
    final inputs = <OfficeDocHeightInput>[
      for (var i = 0; i < doc.blocks.length; i++)
        _heightInput(
          doc.blocks[i],
          forcedBreakBefore: officeDocxForcedBreakBefore(doc.blocks, i),
        ),
    ];
    final pagination = OfficeDocPaginator.paginate(
      inputs,
      contentWidth: contentWidth,
      contentHeight: metrics.contentHeight,
      gap: Gap.xl,
    );

    // ★ r132 真机（模拟器像素）缺陷 D6：一份 `.odoc` 里**两张表**时，
    //   表格/行/单元格的 key 是常量 ⇒ `Column` 的兄弟节点**重键**，
    //   Flutter 直接抛 `Duplicate keys found` 并把**整篇正文**换成红色错误屏
    //   （证据像素 `/private/tmp/r132_ios_ui_pass7/007_s090_office_odoc.png`：
    //   `5-day trip planner.odoc`、`1 / 2`，正文是 `Duplicate keys found … key
    //   [<'office-docx-table'>]`）。修法：按**表序**给 key 加后缀 ——
    //   第 1 张表保持历史 key（既有用例与外部断言依赖），第 2 张起 `-t1/-t2…`。
    final blocks = <Widget>[];
    var tableOrdinal = 0;
    for (final b in doc.blocks) {
      blocks.add(
        _block(
          b,
          contentWidth,
          doc.media,
          MediaQuery.devicePixelRatioOf(context),
          tableOrdinal: b.table == null ? null : tableOrdinal++,
        ),
      );
    }
    final header = _firstNonEmpty(doc.headers);
    final footer = _firstNonEmpty(doc.footers);

    final pages = <Widget>[
      for (var i = 0; i < pagination.pages.length; i++)
        OfficeDocPaperPage(
          metrics: metrics,
          pageIndex: i,
          headerText: header,
          footerText: footer,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final bi in pagination.pages[i].blockIndices) blocks[bi],
              ],
            ),
          ],
        ),
    ];

    return OfficeDocPaperView(
      metrics: metrics,
      pages: pages,
      pagination: pagination,
      headerText: header,
      footerText: footer,
      // ★ **只在文档真的有目录时才给目录 UI**（用户原话："没有目录的 odoc
      //   不要强行加上目录，要根据文档是否真的有目录来"）。
      //   旧实现无条件按标题层级合成 ⇒ `Restaurant menu` / `5-day trip planner`
      //   这些**文档里根本没有目录**的也被强行加上了。
      //   判据见 [officeDocxHasRealToc]（SDT 内容控件 或 目录标题段）。
      toc:
          officeDocxHasRealToc(
            doc.blocks,
            hasTocContentControl: doc.hasTocContentControl,
          )
          ? officeDocxBuildToc(doc.blocks)
          : const <OfficeDocTocEntry>[],
      // 目录点击 → 定位：块在纸面坐标里的纵向偏移 =
      // 该块所在**页**的起始偏移 + 该页内它之前那些块的估算高度之和。
      // 分页本身是估算的（见文件头），所以这是"定位到标题附近"，不是逐像素精确。
      paperOffsetOfBlock: (blockIndex) {
        final pageIndex = officeDocxPageOfBlock(pagination, blockIndex);
        if (pageIndex < 0) return 0;
        final page = pagination.pages[pageIndex];
        var offset = 0.0;
        for (var p = 0; p < pageIndex; p++) {
          offset += pagination.pages[p].estimatedHeight + Gap.xl;
        }
        for (final bi in page.blockIndices) {
          if (bi == blockIndex) return offset;
          offset +=
              OfficeDocPaginator.estimateHeight(
                inputs[bi],
                contentWidth: contentWidth,
              ) +
              OfficeDocPaginator.blockSpacing;
        }
        return offset;
      },
    );
  }

  static String _firstNonEmpty(Map<String, String> map) {
    for (final v in map.values) {
      if (v.trim().isNotEmpty) return v;
    }
    return '';
  }
}

/// 空文档的**可行动**空状态（不是空白，也不是工程话术）。
class _EmptyDoc extends StatelessWidget {
  const _EmptyDoc();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('office-doc-empty'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.description_outlined,
              size: 40,
              color: Color(0xFF9AA0A6),
            ),
            const SizedBox(height: Gap.md),
            Text(
              context.t.officeEmptyDocTitle,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              context.t.officeEmptyDocBody,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7075)),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 分页输入
// ---------------------------------------------------------------------------

/// 段落行距 —— 把 `w:spacing` 的 `(line, lineRule)` 统一换算成 `TextStyle.height`
/// 的倍数。规则见 `office_doc_ooxml.dart` 的 [ooxmlEffectiveLineHeight]：
///   * `auto`：`w:line` 是 **240 分之一行**（`360` → 1.5 倍）；
///   * `exact`：`w:line` 是**精确 twips 高度** ⇒ 倍数 = 高度 ÷ 字号（字号变大、
///     倍数变小，**绝对行高不变**）；
///   * `atLeast`：`max(自然行高, 该值)`。
///
/// `null` = 这份文档没有声明任何行距（保持 Flutter 自然行高，与改动前一致）。
double? _effectiveLineHeight(OOXMLParagraph p) => ooxmlEffectiveLineHeight(
  rule: p.lineRule,
  linePx: p.linePx,
  autoMultiple: p.lineHeight,
  fontSizePt: p.maxFontSizePt,
);

OfficeDocHeightInput _heightInput(
  OOXMLBlock block, {
  bool forcedBreakBefore = false,
}) {
  final table = block.table;
  if (table != null) {
    final sum = _tableHeightEstimate(table);
    return OfficeDocHeightInput(
      kind: 'table',
      declaredHeight: sum > 0 ? sum : null,
      forcedBreakBefore: forcedBreakBefore,
    );
  }
  final p = block.paragraph!;
  if (p.hasImage) {
    var sum = 0.0;
    for (final r in p.runs) {
      sum += r.image?.heightPx ?? 0;
    }
    return OfficeDocHeightInput(
      kind: 'image',
      declaredHeight: sum > 0 ? sum : null,
      forcedBreakBefore: forcedBreakBefore,
    );
  }
  final hanging = _hangingOf(p);
  // 段落自己的 `w:ind/@w:hanging` 会影响首行的左边界（分页按较窄的首行宽估）。
  final left = p.indentLeftPx - (hanging > 0 ? hanging : p.hangingPx);
  return OfficeDocHeightInput(
    kind: p.headingLevel > 0
        ? 'heading'
        : (p.isListItem ? 'listItem' : 'paragraph'),
    text: p.text,
    fontSizePt: p.maxFontSizePt,
    lineHeight: _effectiveLineHeight(p),
    bold: p.runs.any((r) => r.bold),
    paddingTop: p.spacingBeforePx,
    paddingBottom: p.spacingAfterPx,
    indentLeft: left > 0 ? left : 0,
    indentRight: p.indentRightPx,
    markerWidth: p.isListItem ? hanging : 0,
    forcedBreakBefore: forcedBreakBefore,
  );
}

/// "目录"标题段的文字（多语言）。用来判定**文档里是否真的有目录**。
///
/// 判据有两条，任一成立即算"真有目录"：
///  1. **精确判据**（OOXML 独有）：`w:sdt` 的 `w:docPartGallery = "Table of Contents"`
///     —— 这就是 Word / Synology 文档"插入目录"产生的内容控件；
///  2. **文字判据**（原生 OFile 通道也能用）：文档里有一个段落，其文字是下面这些
///     "目录标题"之一。
const Set<String> kOfficeDocTocTitles = <String>{
  'table of contents',
  'contents',
  '目录',
  '目錄',
  '目录页',
  'table des matières',
  'inhalt',
  'inhaltsverzeichnis',
  'índice',
  'indice',
  '目次',
  '목차',
};

/// 这份文档里**是否真的有目录**。
///
/// ## 为什么必须有这个判定（用户原话）
/// > "没有目录的 odoc 不要强行加上目录，要根据文档是否真的有目录来"
///
/// 旧实现是**无条件按标题层级合成**目录，于是**每一份带标题的文档都会被加上目录**：
/// `Restaurant menu`（H1×5 + H2×15 + H3×15，**文档里没有任何目录**）和
/// `5-day trip planner`（真机 round 18 打开的那份，原生模型里 `Table of Contents` = **0**）
/// 都被强行显示了目录。
///
/// ## 实测（两条通道都读过，don't guess）
/// | 文档 | OOXML `docPartGallery` | 原生模型 `Table of Contents` | 结论 |
/// |---|---|---|---|
/// | `Product spec` | **1**（SDT 内 7 条目录） | **1** | **真有目录** |
/// | `Student report` | **1**（SDT 内 9 条目录） | **1** | **真有目录** |
/// | `Restaurant menu` | 0 | 0 | **无目录** |
/// | `5-day trip planner` | —（无 DOCX 缓存） | **0** | **无目录** |
/// | `Vacation packing list` | — | **0** | **无目录** |
bool officeDocxHasRealToc(
  List<OOXMLBlock> blocks, {
  bool hasTocContentControl = false,
}) {
  if (hasTocContentControl) return true;
  for (final b in blocks) {
    final raw = b.paragraph?.text;
    if (raw == null) continue;
    final t = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) continue;
    if (kOfficeDocTocTitles.contains(t)) return true;
  }
  return false;
}

/// 由**标题层级**生成目录导航条目（用于浮层导航面板）。
///
/// ## 权威事实（**已按 round 19/20 的新证据纠正**）
/// 父 agent 用官方 Synology Drive 3.9.0 APK 的资源表证明官方**有**"目录"UI
/// （`string/table_of_contents` = "Table of contents"/"目录"/"目錄"，
/// `heading_1..6` = "1 级标题".."6 级标题"）。
///
/// ⚠️ 旧注释曾写"`.odoc` 里**没有**内嵌 TOC 域，官方的目录 = 由标题层级生成的
/// 大纲导航"——**这个结论是错的**，当时只数了 `TOC`/`instrText`/`fldSimple`，
/// **漏了 `w:sdt`（内容控件）这种形态**。实际：
/// `Product spec` body = 26×`w:p` + 1×`w:tbl` + **1×`w:sdt`**，
/// 该 SDT 的 `docPartGallery="Table of Contents"`，里面有 **7 个 `w:p`**
/// （`1. Introduction` … `5. To Be Discussed`，带 `w:hyperlink w:anchor="_Toc…"`）；
/// `Student report` 同理有 **9 条**。⇒ 官方目录**是文档自带的**，且已随 SDT 解析
/// 进入正文（见 `office_doc_ooxml.dart` 的 `_parseBlockChildren`）。
///
/// 所以本函数的产物**只用作浮层导航**；正文里那一份**由文档自己提供**，
/// 不再重复合成（重复会造成同一屏两份目录）。
///
/// 规则：只收 `headingLevel` 在 **1..6**（官方只有 1..6 级，没有 7/8）
/// 且**标题文字非空**的段落；顺序 = 文档顺序。
List<OfficeDocTocEntry> officeDocxBuildToc(List<OOXMLBlock> blocks) {
  final out = <OfficeDocTocEntry>[];
  for (var i = 0; i < blocks.length; i++) {
    final p = blocks[i].paragraph;
    if (p == null) continue;
    final level = p.headingLevel;
    if (level < 1 || level > 6) continue;
    final text = p.text.trim();
    if (text.isEmpty) continue;
    out.add(OfficeDocTocEntry(level: level, text: text, blockIndex: i));
  }
  return out;
}

/// 块 [blockIndex] 落在第几页（**0-based**；找不到返回 -1）。
int officeDocxPageOfBlock(OfficeDocPagination pagination, int blockIndex) {
  for (var i = 0; i < pagination.pages.length; i++) {
    if (pagination.pages[i].blockIndices.contains(blockIndex)) return i;
  }
  return -1;
}

/// 第 [i] 个块**之前**是否强制换页。
///
/// 来源有两条（都是 OOXML 的真实分页语义）：
/// * 本段的 `<w:pageBreakBefore/>`；
/// * **上一段**末尾的 `<w:br w:type="page"/>`（解析层把它拆段后落在
///   上一段的 `pageBreakAfter` 上）。
///
/// 【实测】3 份官方真样本里这两者都是 0 处 ⇒ 真样本上**不可取证**，
/// 只由构造样本覆盖。
bool officeDocxForcedBreakBefore(List<OOXMLBlock> blocks, int i) {
  if (i < 0 || i >= blocks.length) return false;
  final own = blocks[i].paragraph;
  if (own != null && own.pageBreakBefore) return true;
  if (i > 0) {
    final prev = blocks[i - 1].paragraph;
    if (prev != null && prev.pageBreakAfter) return true;
  }
  return false;
}

/// 表格的高度估算（px）—— 行声明高度之和，**加上嵌套表格的高度**
/// （内层表格会把父单元格撑高；漏算会让分页把块堆到纸面外）。
///
/// 只用于分页估算，不影响实际绘制。
double _tableHeightEstimate(OOXMLTable table) {
  var sum = 0.0;
  for (final row in table.rows) {
    var h = row.heightPx ?? OfficeDocPaginator.fallbackTableRowHeight;
    for (final c in row.cells) {
      for (final inner in c.tables) {
        h += _tableHeightEstimate(inner);
      }
    }
    sum += h;
  }
  return sum;
}

/// 列表挂起宽度（`w:ind hanging`；没有就退回 `left`）。
double _hangingOf(OOXMLParagraph p) {
  if (!p.isListItem) return 0;
  if (p.markerIndentPx > 0) return p.markerIndentPx;
  final h = p.hangingPx;
  if (h > 0) return h;
  return p.indentLeftPx > 0 ? p.indentLeftPx : 24;
}

// ---------------------------------------------------------------------------
// 块渲染
// ---------------------------------------------------------------------------

Widget _block(
  OOXMLBlock block,
  double contentWidth,
  Map<String, Uint8List> media,
  double dpr, {
  int? tableOrdinal,
}) {
  final table = block.table;
  if (table != null) {
    return _table(table, contentWidth, media, dpr, ordinal: tableOrdinal ?? 0);
  }
  return _paragraph(block.paragraph!, contentWidth, media, dpr);
}

/// 段落的可见内容（含 `w:ind` 的首行缩进 / 悬挂缩进）。
///
/// OOXML 缩进语义（`w:ind`）：
///   * `w:left` 是**除首行外**各行的左边界基准（`w:ind w:left="L"`）；
///   * `w:hanging="H"`：首行再**左移** H（`L − H`），其余行留在 `L`；
///   * `w:firstLine="F"`：首行再**右移** F（`L + F`），其余行留在 `L`；
///   * `hanging` 与 `firstLine` 互斥（解析层已按 hanging 优先归一）。
///
/// 此前这里把整段按 `L − hanging` 左缩进、`firstLine` **完全没进版面**
/// （真机上首行缩进看不见）—— 本批补齐。
Widget _paragraph(
  OOXMLParagraph p,
  double contentWidth,
  Map<String, Uint8List> media,
  double dpr, {

  /// 表头行（`w:tblHeader`）里的段落整段加粗 —— 与 WPS / Word 一致。
  bool bold = false,
}) {
  // 列表标记槽宽（`_hangingOf` 只对列表有意义，非列表一律返回 0）。
  final listHanging = _hangingOf(p);
  final isList = p.isListItem && (p.marker ?? '').isNotEmpty;
  // 段落**自己**的 `w:ind/@w:hanging`（非列表段落也要认）。
  final hanging = p.hangingPx;
  final lineHeight = _effectiveLineHeight(p);
  // 非列表段落的悬挂缩进（列表的 hanging 由下面的"标记槽"负责，两者不重复）。
  final hangingOutdent = !isList && hanging > 0;
  final firstLineIndent = (!hangingOutdent && p.indentFirstPx > 0)
      ? p.indentFirstPx
      : 0.0;
  // 列表：标记槽占 `L − H` .. `L`，文字从 `L` 开始（既有行为，不许改坏）。
  // 悬挂：首行从 `L − H` 开始，其余行从 `L` 开始（由 _HangingIndentText 补 H）。
  // 其余：整段从 `L` 开始，首行再右移 `firstLine`。
  final leftPad =
      (isList
              ? p.indentLeftPx - listHanging
              : (hangingOutdent ? p.indentLeftPx - hanging : p.indentLeftPx))
          .clamp(0.0, contentWidth < 0 ? 0.0 : contentWidth);
  final textAlign = switch (p.alignment) {
    'center' => TextAlign.center,
    'right' => TextAlign.right,
    'justify' => TextAlign.justify,
    _ => TextAlign.left,
  };

  Widget body;
  if (p.hasImage) {
    body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final r in p.runs)
          if (r.image != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
              child: _image(r.image!, media, dpr),
            )
          else if (r.text.isNotEmpty)
            _richText(<OOXMLRun>[r], textAlign, height: lineHeight, bold: bold),
      ],
    );
  } else if (p.runs.isEmpty || p.text.isEmpty) {
    // 空段落 = 一个空行（Word 里就是占一行）。
    body = const SizedBox(height: 18);
  } else if (hangingOutdent) {
    body = _HangingIndentText(
      runs: p.runs,
      align: textAlign,
      restIndent: hanging,
      // 正文可用宽度 = 块宽 − 左缩进 − 右缩进（`contentWidth` 由父级给定：
      // 纸面正文宽 / 单元格内容宽）。**右缩进由下面那层 `Padding` 统一负责**，
      // 这里不能再扣一次（否则续行会被右缩进挤两次）。
      // **不用 LayoutBuilder**：表格行外面套了 `IntrinsicHeight`，
      // 而 LayoutBuilder 不支持固有尺寸测量。
      maxWidth: contentWidth - leftPad - p.indentRightPx,
      height: lineHeight,
      bold: bold,
    );
  } else {
    body = _richText(
      p.runs,
      textAlign,
      height: lineHeight,
      firstLineIndent: firstLineIndent,
      bold: bold,
    );
  }

  final row = isList
      ? Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: listHanging,
              child: Text(
                p.marker!,
                key: const Key('office-docx-list-marker'),
                style: TextStyle(
                  fontSize: _fontSizePx(p.runs),
                  height: lineHeight ?? 1.5,
                  color: const Color(0xFF3C4043),
                ),
              ),
            ),
            Expanded(child: body),
          ],
        )
      : body;

  return Padding(
    padding: EdgeInsets.only(
      left: leftPad,
      right: p.indentRightPx,
      top: p.spacingBeforePx,
      bottom: p.spacingAfterPx,
    ),
    // 段落底纹（`<w:pPr><w:shd>`）。段前/段后距在**底纹之外**（Word 的底纹
    // 只覆盖段落行盒），所以 Padding 在外、ColoredBox 在内。
    child: _paragraphShading(p.shading, row),
  );
}

/// 段落底纹（`<w:pPr><w:shd w:fill>`）。
///
/// 【实测】真样本 `student_report.docx` 有 11 处 `<w:shd w:fill="auto"/>`
/// —— 那是"**无底纹**"（`auto` 解不出颜色），所以真样本上底纹仍是**看不见**的
/// ⇒ 本能力**不可真机取证**，由构造样本覆盖。
Widget _paragraphShading(String? fill, Widget child) {
  final color = officeDocParseColor(fill);
  if (color == null) return child;
  return ColoredBox(color: color, child: child);
}

/// **首行缩进**的占位宽度（`w:ind/@w:firstLine`）。
///
/// Flutter 的 `TextStyle` **没有** `text-indent`；把整段用 `Padding` 右推会把
/// **后续行也一起推进去**（= 改动前那种"整段左缩进近似"，真机上看不见首行缩进）。
/// 这里用一个宽 N、高可忽略的 [WidgetSpan] 顶在段首：它只占**第一行**的横向
/// 空间，换行后的行仍从段落左边界开始 —— 正是 Word / WPS 的 `firstLine` 语义。
const Key kOfficeDocxFirstLineIndentKey = Key('office-docx-first-line-indent');

/// 非列表段落的**悬挂缩进**：首行在 `left − hanging`，其余行在 `left`。
///
/// Flutter 既没有 text-indent，也不能只给"第二行起"加缩进，所以用
/// [TextPainter] 在与首行**相同的可用宽度**下求出第一行断点，把段落拆成
/// "首行 / 其余"两个 `Text` 分别定位。只有真的写了 `w:hanging` 的
/// **非列表**段落才会走到这里（列表走标记槽，不受影响）。
class _HangingIndentText extends StatelessWidget {
  const _HangingIndentText({
    required this.runs,
    required this.align,
    required this.restIndent,
    required this.maxWidth,
    required this.height,
    this.bold = false,
  });

  final List<OOXMLRun> runs;
  final TextAlign align;

  /// 续行相对**首行**的额外左缩进（= `w:ind/@w:hanging`）。
  final double restIndent;

  /// 本段正文的可用宽度（首行在其中占满宽度；右缩进已由外层 `Padding` 扣掉）。
  final double maxWidth;
  final double? height;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final full = runs.map((r) => r.text).join();
    if (full.isEmpty || !maxWidth.isFinite || maxWidth <= 0) {
      // 宽度未知（不该发生）→ 退回不拆分的整段渲染，宁可少一个缩进也不丢字。
      return _richText(runs, align, height: height, bold: bold);
    }
    // 首行的可用宽度 = 本段正文宽（续行还要再让出 `restIndent`）。
    final span = _inlineSpan(runs, height: height, bold: bold);
    final painter = TextPainter(
      text: span,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textAlign: TextAlign.left,
      maxLines: 1,
    )..layout(maxWidth: maxWidth.clamp(1.0, double.infinity));
    final cut = painter
        .getLineBoundary(const TextPosition(offset: 0))
        .end
        .clamp(1, full.length);
    final head = _sliceRuns(runs, 0, cut);
    final tail = _sliceRuns(runs, cut, full.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          key: const Key('office-docx-hanging-first'),
          padding: EdgeInsets.zero,
          child: _richText(head, align, height: height, bold: bold),
        ),
        if (tail.isNotEmpty)
          Padding(
            key: const Key('office-docx-hanging-rest'),
            padding: EdgeInsets.only(left: restIndent),
            child: _richText(tail, align, height: height, bold: bold),
          ),
      ],
    );
  }
}

/// 按字符区间切 `runs`（悬挂缩进的按行拆分用）。
List<OOXMLRun> _sliceRuns(List<OOXMLRun> runs, int start, int end) {
  final out = <OOXMLRun>[];
  var cursor = 0;
  for (final r in runs) {
    final len = r.text.length;
    final s = (start - cursor).clamp(0, len);
    final e = (end - cursor).clamp(0, len);
    if (e > s) out.add(r.withText(r.text.substring(s, e)));
    cursor += len;
  }
  return out;
}

double _fontSizePx(List<OOXMLRun> runs) {
  double? max;
  for (final r in runs) {
    final v = r.sizePt;
    if (v != null && (max == null || v > max)) max = v;
  }
  return _ptToPx(max ?? 11);
}

double _ptToPx(double pt) => pt * kOdocPtToPx;

/// 段落文字。
///
/// **能塌成纯文本就塌**（`Text` 而不是 `Text.rich`）：Word 里绝大多数段落只有
/// 一个 run，塌成 `Text` 之后 `find.text` / 无障碍朗读 / 文本选择都自然可用。
Widget _richText(
  List<OOXMLRun> runs,
  TextAlign align, {
  double? height,
  double firstLineIndent = 0,
  bool bold = false,
}) {
  if (runs.isEmpty) return const SizedBox(height: 18);
  final span = _inlineSpan(runs, height: height, bold: bold);
  if (firstLineIndent > 0) {
    // 首行缩进：占位 span 必须**在**文字之前，只影响第一行。
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              key: kOfficeDocxFirstLineIndentKey,
              width: firstLineIndent,
              height: 1,
            ),
          ),
          span,
        ],
      ),
      textAlign: align,
    );
  }
  if (span.children == null) {
    return Text(span.text ?? '', textAlign: align, style: span.style);
  }
  return Text.rich(span, textAlign: align);
}

/// 段落的行内内容（样式只在 run 之间不同时才上 `Text.rich`）。
TextSpan _inlineSpan(List<OOXMLRun> runs, {double? height, bool bold = false}) {
  if (runs.any((r) => r.isSuperscript || r.isSubscript)) {
    return _spanWithVerticalAlign(runs, height: height, bold: bold);
  }
  if (runs.length == 1) {
    final r = runs.first;
    return TextSpan(
      text: r.text,
      style: _runStyle(r, height: height, bold: bold),
    );
  }
  final key = _styleKey(runs.first);
  if (runs.every((r) => _styleKey(r) == key)) {
    return TextSpan(
      text: runs.map((r) => r.text).join(),
      style: _runStyle(runs.first, height: height, bold: bold),
    );
  }
  final base = runs.firstWhere(
    (r) => r.sizePt != null,
    orElse: () => runs.first,
  );
  return TextSpan(
    children: <InlineSpan>[
      for (final r in runs)
        TextSpan(
          text: r.text,
          style: _runStyle(r, height: height, bold: bold),
        ),
    ],
    style: _runStyle(
      OOXMLRun(
        text: '',
        sizePt: base.sizePt ?? 11,
        fontFamily: _firstFamily(runs),
      ),
      height: height,
      bold: bold,
    ),
  );
}

/// 含**上标/下标**（`<w:vertAlign>`）的段落行内内容。
///
/// ## 为什么用 `WidgetSpan` + `Transform.translate`
/// Flutter 的 `TextStyle` **没有基线位移**（没有 `superscript`/`baselineShift`），
/// 所以"缩小字号 + 抬升/下沉基线"只能用 `WidgetSpan` 的
/// `PlaceholderAlignment.baseline` 定位后再平移实现。
///
/// **代价（如实登记）**：含上下标的段落会拆成多个 `Text`，该段的
/// `find.text('<整段>')` 不再命中（单个 run 的 `find.text(run.text)` 仍然命中）。
/// 只有**真的写了** `w:vertAlign` 的段落才会走这条路；
/// 真样本 3 份里 `w:vertAlign` 出现 0 次 ⇒ 本仓真样本**不受影响**。
TextSpan _spanWithVerticalAlign(
  List<OOXMLRun> runs, {
  double? height,
  bool bold = false,
}) {
  final base = runs.firstWhere(
    (r) => r.sizePt != null,
    orElse: () => runs.first,
  );
  return TextSpan(
    style: _runStyle(
      OOXMLRun(
        text: '',
        sizePt: base.sizePt ?? 11,
        fontFamily: _firstFamily(runs),
      ),
      height: height,
      bold: bold,
    ),
    children: <InlineSpan>[
      for (final r in runs)
        if (r.isSuperscript || r.isSubscript)
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Transform.translate(
              offset: Offset(0, _verticalShiftPx(r)),
              child: Text(
                r.text,
                key: const Key('office-docx-vertical-align'),
                style: _runStyle(r, bold: bold),
              ),
            ),
          )
        else
          TextSpan(
            text: r.text,
            style: _runStyle(r, height: height, bold: bold),
          ),
    ],
  );
}

/// run 的可见样式指纹（**只比会影响排版的字段**）。
String _styleKey(OOXMLRun r) => [
  r.bold,
  r.italic,
  r.underline,
  r.strike,
  r.color,
  r.sizePt,
  r.fontFamily,
  r.highlight,
  r.verticalAlign,
].join('|');

String? _firstFamily(List<OOXMLRun> runs) {
  for (final r in runs) {
    final f = r.fontFamily;
    if (f != null && f.isNotEmpty) return f;
  }
  return null;
}

/// 上下标（`<w:vertAlign>`）的**字号比例**与**基线位移比例**。
///
/// 【规范推导】Word 的上/下标默认是正文的约 **65%** 且基线上下移约
/// **三分之一字号**（Word 内置的 `vertAlign` 呈现，规范未给数字）。
/// 规范只规定语义（`superscript`/`subscript` 相对基线抬升/下沉），
/// 具体比例**由实现决定** ⇒ 这两个常数是**本仓选择**，不是规范原文。
/// 【实测】3 份官方真样本 `w:vertAlign` 出现 **0 次** ⇒ 不可真机取证。
const double kOoxmlSuperSubScale = 0.65;
const double kOoxmlSuperSubShift = 0.34;

/// run 的样式；[verticalAlign] 非空时按上下标缩放。
TextStyle _runStyle(OOXMLRun run, {double? height, bool bold = false}) {
  final decorations = <TextDecoration>[
    if (run.underline) TextDecoration.underline,
    if (run.strike) TextDecoration.lineThrough,
  ];
  final isSuper = run.isSuperscript;
  final isSub = run.isSubscript;
  final sizePx =
      _ptToPx(run.sizePt ?? 11) *
      ((isSuper || isSub) ? kOoxmlSuperSubScale : 1.0);
  return TextStyle(
    fontSize: sizePx,
    fontFamily: run.fontFamily,
    fontWeight: (run.bold || bold) ? FontWeight.w700 : FontWeight.w400,
    fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
    decoration: decorations.isEmpty
        ? TextDecoration.none
        : TextDecoration.combine(decorations),
    color: officeDocParseColor(run.color) ?? const Color(0xFF202124),
    backgroundColor: officeDocParseColor(run.highlight),
    // `w:spacing/@w:line` + `@lineRule` 的真实行距（exact/atLeast 已换算）。
    // 上下标是例外：它们的行盒由宿主行决定，不能再套整段行距。
    height: (isSuper || isSub) ? null : height,
  );
}

/// 上下标的**基线位移**（px，正数 = 向下）。
double _verticalShiftPx(OOXMLRun run) {
  if (!run.isSuperscript && !run.isSubscript) return 0;
  final size = _ptToPx(run.sizePt ?? 11);
  final shift = size * kOoxmlSuperSubShift;
  return run.isSuperscript ? -shift : shift;
}

Widget _image(OOXMLImage image, Map<String, Uint8List> media, double dpr) {
  final bytes = image.mediaPath == null ? null : media[image.mediaPath!];
  final w = image.widthPx > 0 ? image.widthPx : 320.0;
  final h = image.heightPx > 0 ? image.heightPx : 200.0;
  // 尺寸来自 `w:drawing/wp:extent`；字节直接来自 DOCX 包内 `word/media/`。
  return SizedBox(
    key: const Key('office-docx-image'),
    width: w,
    height: h,
    child: bytes == null
        ? const Center(child: Icon(Icons.image_outlined, size: 28))
        // ⚠️ **必须按显示尺寸解码**（与 `.oslides` 真机缺陷同源，2026-09-22）。
        //
        // `.oslides` 上实测到：不设 `cacheWidth`/`cacheHeight` 时 `Image.memory`
        // 按**原始分辨率**解码 —— 该样本里有一张 5612x3742 的图，ARGB 达 **84 MB**，
        // 既超过常见 Android GPU 的最大纹理边长 4096，单张也能塞满 Flutter
        // 默认 100 MB 的 `ImageCache` ⇒ **真机上主画布空白，而离线测试全绿**。
        //
        // DOCX 里的图片同理：`w:extent` 给的显示尺寸（w x h）往往远小于原图像素，
        // 按原始分辨率解码是纯浪费且有失败风险。
        // 这里按 `显示逻辑尺寸 x devicePixelRatio` 取，硬性夹在 1..2048。
        : Image.memory(
            bytes,
            fit: BoxFit.contain,
            cacheWidth: (w * dpr).ceil().clamp(1, 2048),
            cacheHeight: (h * dpr).ceil().clamp(1, 2048),
          ),
  );
}

// ---------------------------------------------------------------------------
// 表格：**按 `w:tblGrid` 的真实列宽**排，不拉满屏、不均分
// ---------------------------------------------------------------------------

Widget _table(
  OOXMLTable table,
  double contentWidth,
  Map<String, Uint8List> media,
  double dpr, {

  /// Widget key 前缀：顶层表格沿用 `office-docx-*`（既有用例依赖），
  /// 嵌套表格用 `office-docx-nested-*`，这样父子两层可以被分别断言。
  String keyPrefix = 'office-docx',

  /// **本页第几张表**（0 起）。0 沿用历史 key；≥1 追加 `-t<n>` 后缀。
  /// 不加后缀时，同一 `Column` 里两张表会**重键** ⇒ Flutter 抛
  /// `Duplicate keys found` 且整篇正文变红屏（r132 D6，像素见调用点注释）。
  int ordinal = 0,
}) {
  final keySuffix = ordinal == 0 ? '' : '-t$ordinal';
  // 行/单元格 key 用**同一后缀**（原来它们也是常量 ⇒ 两张表时同样重键）。
  final childPrefix = '$keyPrefix$keySuffix';
  final declared = table.colWidthsPx.where((w) => w > 0).toList();
  final total = declared.isEmpty
      ? contentWidth
      : declared.fold<double>(0, (a, b) => a + b);
  // 声明总宽比正文区宽才缩放；**比正文区窄就按声明宽度显示**（WPS 行为）。
  //
  // [contentWidth] 是**父级给定的可用宽度**：顶层是纸面正文宽，嵌套表格是
  // 父单元格的内容宽 —— 所以内层表格永远不会撑破外层（内层只会被等比缩小）。
  final scale = (total > contentWidth && total > 0)
      ? contentWidth / total
      : 1.0;
  final widths = declared.isEmpty
      ? List<double>.filled(
          table.rows.isEmpty ? 1 : _maxCells(table),
          contentWidth / (table.rows.isEmpty ? 1 : _maxCells(table)),
        )
      : declared.map((w) => w * scale).toList();

  final merge = _resolveVMerge(table);

  return Padding(
    key: Key('$childPrefix-table'),
    padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var r = 0; r < table.rows.length; r++)
          _tableRow(
            table.rows[r],
            widths,
            r,
            media,
            dpr,
            childPrefix,
            table: table,
            mergeContinue: merge.continueFlags[r],
            mergeHasBelow: merge.restartHasBelow[r],
          ),
      ],
    ),
  );
}

/// `w:vMerge` 的解析结果（**每个单元格**两个布尔）。
class _VMergeInfo {
  const _VMergeInfo(this.continueFlags, this.restartHasBelow);

  /// 该格是竖直合并的**延续格**（内容在上面的起始格里）。
  final List<List<bool>> continueFlags;

  /// 该格是**起始格**且下方还有延续格 ⇒ 去掉内部横线。
  final List<List<bool>> restartHasBelow;
}

/// 沿行遍历 `w:vMerge` 状态。
///
/// ## 能力与**边界**（如实登记）
/// * 做到：延续格**不重复内容**、**内部横线断开**（`vMergeRestart:false/true`
///   的语义在视觉上成立，单元格连成一块、底色连续）；
/// * **没做到**：起始格的文字**跨行竖直居中**。Flutter 没有 rowspan，
///   在 `IntrinsicHeight` + `Row` 这套布局里做不到"一个 Widget 纵向跨多行"
///   （需要先量出各行高度再绝对定位）。所以合并格里的文字仍**停在第 1 行**、
///   只是那几行的分割线不再画 —— 报告 §未完成 已登记。
/// * 真样本情况【实测】：3 份官方 `.docx` 的 `w:vMerge` 出现 **0 次**
///   ⇒ 本能力**不可真机取证**，只由构造样本覆盖。
_VMergeInfo _resolveVMerge(OOXMLTable table) {
  final continueFlags = <List<bool>>[
    for (final row in table.rows) List<bool>.filled(row.cells.length, false),
  ];
  final restartHasBelow = <List<bool>>[
    for (final row in table.rows) List<bool>.filled(row.cells.length, false),
  ];
  // gridCol → 最近一个 **restart** 格的 (rowIndex, cellIndex)。
  final starters = <int, List<int>>{};
  for (var r = 0; r < table.rows.length; r++) {
    final row = table.rows[r];
    var col = 0;
    for (var c = 0; c < row.cells.length; c++) {
      final cell = row.cells[c];
      final span = cell.gridSpan < 1 ? 1 : cell.gridSpan;
      final cols = <int>[for (var i = 0; i < span; i++) col + i];
      col += span;
      if (cell.vMergeContinue) {
        continueFlags[r][c] = true;
        // 延续格：起始格仍在上面，且**延续格也有下方**时起始格继续不断线。
        for (final gc in cols) {
          final s = starters[gc];
          if (s != null) restartHasBelow[s[0]][s[1]] = true;
        }
        continue;
      }
      // 非延续格：结束了上面所有竖直合并。
      for (final gc in cols) {
        starters.remove(gc);
      }
      if (cell.vMergeRestart) {
        for (final gc in cols) {
          starters[gc] = <int>[r, c];
        }
      }
    }
  }
  return _VMergeInfo(continueFlags, restartHasBelow);
}

int _maxCells(OOXMLTable table) {
  var max = 1;
  for (final r in table.rows) {
    var n = 0;
    for (final c in r.cells) {
      n += c.gridSpan;
    }
    if (n > max) max = n;
  }
  return max;
}

Widget _tableRow(
  OOXMLRow row,
  List<double> widths,
  int rowIndex,
  Map<String, Uint8List> media,
  double dpr,
  String keyPrefix, {
  OOXMLTable? table,
  List<bool>? mergeContinue,
  List<bool>? mergeHasBelow,
}) {
  var col = 0;
  final children = <Widget>[];
  for (var c = 0; c < row.cells.length; c++) {
    final cell = row.cells[c];
    var width = 0.0;
    for (var i = 0; i < cell.gridSpan; i++) {
      final index = col + i;
      width += index < widths.length
          ? widths[index]
          : (widths.isEmpty ? 80 : widths.last);
    }
    col += cell.gridSpan;
    children.add(
      SizedBox(
        width: width,
        child: _cell(
          cell,
          rowIndex,
          c,
          width,
          row.isHeader,
          media,
          dpr,
          keyPrefix,
          table: table,
          mergeContinue: mergeContinue != null && c < mergeContinue.length
              ? mergeContinue[c]
              : false,
          mergeHasBelow: mergeHasBelow != null && c < mergeHasBelow.length
              ? mergeHasBelow[c]
              : false,
        ),
      ),
    );
  }
  // `IntrinsicHeight`：让同一行的单元格等高（`stretch` 需要**有界**高度；
  // 纸面在 FittedBox 里高度是无界的，所以先问一次固有高度）。
  return IntrinsicHeight(
    child: Row(
      key: Key('$keyPrefix-table-row-$rowIndex'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// 单元格**内容区**宽度（去掉左右内边距与边框）。
///
/// 内边距现在来自 **文档自己的 `w:tblCellMar`**（`OOXMLTable.cellMargin*`），
/// 不再写死 6+6。
///
/// 嵌套表格拿它当 `contentWidth`，因此内层列宽按父单元格等比收缩，
/// **不会撑破外层**。
double _cellInnerWidth(OOXMLCell cell, double cellWidth, {OOXMLTable? table}) {
  final border = _side(cell.borderLeft).width + _side(cell.borderRight).width;
  final padding =
      (table?.cellMarginLeftPx ?? 6) + (table?.cellMarginRightPx ?? 6);
  final inner = cellWidth - padding - border;
  return inner > 0 ? inner : 0;
}

Widget _cell(
  OOXMLCell cell,
  int rowIndex,
  int cellIndex,
  double cellWidth,
  bool headerRow,
  Map<String, Uint8List> media,
  double dpr,
  String keyPrefix, {
  OOXMLTable? table,

  /// 竖直合并（`w:vMerge`）：本格是**延续格**（内容在上面的起始格里）。
  bool mergeContinue = false,

  /// 本格是**起始格**且下面还有延续格 ⇒ 去掉内部横线（视觉上连成一格）。
  bool mergeHasBelow = false,
}) {
  final border = Border(
    // 延续格不画上边框（内部横线要断开）；起始格下方还有延续格时同理。
    top: mergeContinue ? BorderSide.none : _side(cell.borderTop),
    right: _side(cell.borderRight),
    bottom: mergeHasBelow ? BorderSide.none : _side(cell.borderBottom),
    left: _side(cell.borderLeft),
  );
  // ⚠️ `w:tcPr/w:vAlign` 是**竖直**对齐（top/center/bottom），不是水平对齐。
  //
  // 旧实现把它接到 `Column.crossAxisAlignment` —— 那是**水平**轴，于是
  // `vAlign=center` 的单元格里的段落被**水平居中**。真机 `5-day trip planner.odoc`
  // 上肉眼可见：正文被挤成中间一窄列、左侧一大片空白（父 agent 的 r17 截图复现）。
  // `verticalAlign: "middle"`（原生 JSON 口径）与 `"center"`（OOXML 口径）同义。
  final main = switch (cell.verticalAlign) {
    'center' || 'middle' => MainAxisAlignment.center,
    'bottom' => MainAxisAlignment.end,
    _ => MainAxisAlignment.start,
  };
  final innerWidth = _cellInnerWidth(cell, cellWidth, table: table);
  return Container(
    key: Key('$keyPrefix-cell-$rowIndex-$cellIndex'),
    constraints: const BoxConstraints(minHeight: 20),
    decoration: BoxDecoration(
      border: border,
      color: officeDocParseColor(cell.shading),
    ),
    padding: EdgeInsets.only(
      left: table?.cellMarginLeftPx ?? 6,
      right: table?.cellMarginRightPx ?? 6,
      top: table?.cellMarginTopPx ?? 4,
      bottom: table?.cellMarginBottomPx ?? 4,
    ),
    child: Column(
      // `stretch`：段落铺满单元格宽，**段内**对齐由 `w:jc` 决定
      // （`w:vAlign` 只管竖直，见上面的 `main`）。
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: main,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 单元格内容按**文档顺序**排：段落 + 嵌套表格，都用与外层同一套规则
        // （表头行加粗、列宽来自 `w:tblGrid`、边框/底色来自 `w:tcPr`）。
        for (var bi = 0, nested = 0; bi < cell.blocks.length; bi++)
          if (cell.blocks[bi].paragraph != null)
            _paragraph(
              cell.blocks[bi].paragraph!,
              innerWidth,
              media,
              dpr,
              bold: headerRow,
            )
          else if (cell.blocks[bi].table != null)
            // 嵌套表格：同一套渲染规则，宽度换成父单元格的内容宽。
            // ★ 同一个单元格里**两张嵌套表**时同样会重键 ⇒ 按格内表序编号。
            _table(
              cell.blocks[bi].table!,
              innerWidth,
              media,
              dpr,
              keyPrefix: 'office-docx-nested',
              ordinal: nested++,
            ),
        if (cell.blocks.isEmpty)
          _paragraph(
            const OOXMLParagraph(runs: <OOXMLRun>[]),
            innerWidth,
            media,
            dpr,
          ),
      ],
    ),
  );
}

BorderSide _side(OOXMLBorder? b) {
  if (b == null || !b.visible) return BorderSide.none;
  return BorderSide(
    width: b.widthPx,
    // `w:color` 缺失 = OOXML 的 `auto`（实际是黑）。旧实现在这里退回 `0xFFAAAAAA`
    // 灰，把"没写颜色的边框"画成灰色；文档的默认边框色是黑。
    color: officeDocParseColor(b.color) ?? const Color(0xFF000000),
  );
}

/// 供调用方判定的字节类型（避免误把原生 OFile 当 DOCX）。
bool looksLikeDocxBytes(Uint8List bytes) => ODocxDocument.looksLikeDocx(bytes);
