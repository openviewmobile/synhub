// Office 文档**自渲染缩略图**（.odoc / .osheet / .oslides）：能力层 + 缓存 + 节流。
//
// ## 为什么必须自渲染（不是"我们偷懒"，是服务端没有这条通道）
//
// `docs/thumbnail-apis.md` 的真机取证（第 260 轮，逐条实测）：
//   * `SYNO.FileStation.Thumb:get` 对 `.odoc/.osheet/.oslides` 回 **404 + 11939B HTML**
//     （不是图片，是错误页）；
//   * `SYNO.SynologyDrive.Files:get_thumbnail` 对 office 三格式回 **400 + 0 字节**；
//   * `SYNO.Office.Snapshot:get` v3/v4（`link_id` 换模型）**能拿到整份文档模型**
//     （已经在 `lib/src/data/office_api.dart` 落地）。
// ⇒ 缩略图只能**自己从模型渲染**：把首页 widget 画到离屏 `RepaintBoundary`，
// `toImage(pixelRatio:)` → `ImageByteFormat.png`。
//
// ## 复用（不另写渲染器）
//
// 首页内容一律交给**阅读器同一条渲染路径**，本文件只负责"截取首页 + 出像素"：
//   * `.odoc`   → `ODocView(document:)`（`lib/src/features/files/office_viewer_page.dart`）
//   * `.osheet` → `OSheetView(workbook:)`（同上 viewer 文件；它内部就是
//     `OfficeSheetView` 的适配点，与阅读器完全同一条路径）
//   * `.oslides`→ `OSlidesView(presentation:)`（同上 viewer 文件）
// 分派顺序与 `office_viewer_page.dart` 的 `_body()` **逐字一致**（workbook → document
// → presentation），所以缩略图与阅读器**永远是同一份内容**，不会"两个入口两种渲染"。
//
// ## 三种格式的"首页"取法（各有单测）
//
// | 格式 | 首页 = | 上限 | 依据 |
// |---|---|---|---|
// | `.odoc` | 正文开头的块（`ODocView` 的第一屏） | 前 `kOfficeThumbDocBlocks` = 24 块 | 卡片档 320×427 至少显示 ~14 行正文，24 块 ≥ 一屏；同时挡住"2 万块的长文档"在缩略图里构建 2 万个 widget |
// | `.osheet` | 第一个可见工作表的**左上角** | 24 行 × 8 列（192 格） | 320px 宽 / 默认列宽 96 ⇒ 一屏只看得到 ~3.3 列，8 列已 ≥ 2 屏；240px 高 / 默认行高 22 ⇒ 一屏 ~11 行，24 行已 ≥ 2 屏。**绝不能整表渲染**：阅读器自己的上限是 `kOfficeSheetMaxRenderRows=500 × kOfficeSheetMaxRenderCols=100`（5 万格），照它渲染一张缩略图会卡死 |
// | `.oslides` | **第 1 张**幻灯片（= 阅读器初始 `_index = 0`） | 只留 `slides.first` | `OSlidesView` 是 `PageView`，首页就是第 1 页；页码栏（48dp 按钮 + 上下 4dp）用 `OverflowBox` 顶出可视区、由外层 `ClipRect` 裁掉，避免缩略图里出现翻页按钮 |
//
// ## 离线 / 可注入
//
// 模型**不由本文件获取**：`OfficeThumbModelFetcher` 由调用方注入（生产 = 父层的
// `officeNativeReadProvider`，测试 = 假模型 / 假 sections）。单测**零网络**。
//
// ## 两个档位 + 像素比
//
// `OfficeThumbSize.list`（宽 96）/ `.card`（宽 320），高按格式的长宽比算；
// 渲染时用 `pixelRatio`（生产 = `MediaQuery.devicePixelRatioOf(context)`）出**物理像素**，
// 否则 3x 屏上 96dp 会被放大成糊图。
//
// ## 超时 / 降级
//
// 整个任务（取模型 + 构建 + 光栅化）在 `kOfficeThumbRenderTimeout`（1.8s）内没完成
// ⇒ 记入失败记忆并返回 null；widget 显示**文件类型图标**（绝不空白、绝不挂住）。
// 取消是**逻辑取消**：槽位立刻释放、迟到的结果被丢弃（Flutter 没有中断光栅化的原语，
// 这一点在报告里如实写明）。
import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/theme/app_theme.dart';
import '../../data/office_native/odoc_model.dart';
import '../../data/office_native/office_native_reader.dart';
import '../../data/office_native/osheet_model.dart';
import '../../data/office_native/oslides_model.dart';
import '../../data/office_native/prosemirror_model.dart';
import '../files/office_viewer_page.dart';
import 'office_sheet_view.dart';
import 'office_thumb_cache.dart';

export 'office_thumb_cache.dart';

// ---------------------------------------------------------------- 常量（有依据）

/// 单张缩略图的渲染时限：1.8s（需求给的区间是 1.5–2s）。
const Duration kOfficeThumbRenderTimeout = Duration(milliseconds: 1800);

/// **超时**失败记忆的有效期（`markFailed(..., ttl:)` 用它）。
///
/// 第 261 轮真机实测：任务里含**两跳 NAS 往返**（`Files:get` 取 `permanent_link`
/// → `Snapshot:get` 取整个文档模型）+ 解析 + 光栅化，1800ms 常常不够 ⇒ 超时被当成
/// "永久失败"记下来 ⇒ 这一行在本进程内**永远**是图标（用户看到的就是这个）。
/// 超时只是"这次慢"，30 秒后允许重试；渲染器**明确抛错**的仍是永久失败。
const Duration kOfficeThumbTimeoutRetry = Duration(seconds: 30);

/// 同时渲染的缩略图上限（渲染是重活，多了会让列表滚动掉帧）。
const int kOfficeThumbMaxConcurrent = 2;

/// `.odoc` 首页最多取多少块（依据见文件头表格）。
const int kOfficeThumbDocBlocks = 24;

/// `.osheet` 首页最多取多少行 / 列（依据见文件头表格）。
const int kOfficeThumbSheetRows = 24;
const int kOfficeThumbSheetCols = 8;

/// `.osheet` 阅读器**工具条**高度（实测 48dp：`office-sheet-toolbar` 里的
/// `IconButton` 最小点击区；用 `OverflowBox`+`Transform.translate` 顶出可视区）。
///
/// 为什么缩略图里要去掉它：工具条是**阅读器的交互 chrome**（适宽/缩放 ±），
/// 在 240dp 高的卡片缩略图里会吃掉 20% 高度，且缩略图点不动它。
const double kOfficeThumbSheetToolbarHeight = 48;

/// 幻灯片画布逻辑尺寸 —— 与阅读器 `_SlidePage.canvasWidth/canvasHeight` 一致
/// （`office_viewer_page.dart`）。缩略图按这个尺寸布局再整体缩放，**不改内层坐标系**。
const double _kOfficeSlideCanvasWidth = 960;
const double _kOfficeSlideCanvasHeight = 540;

/// `.oslides` 页码栏高度：`IconButton` 最小 48dp + 上下各 4dp（`Gap.xs`）=
/// `office_viewer_page.dart::_slidePager` 的实测高度。用 `OverflowBox` 顶出去再裁掉。
const double kOfficeThumbSlidesPagerHeight = 48 + 2 * 4;

// ---------------------------------------------------------------- 档位 / 尺寸

/// 缩略图档位：列表小图 / 卡片中图（宽度是**逻辑像素**）。
enum OfficeThumbSize {
  /// 列表里的小图（宽 96dp）。
  list(96),

  /// 卡片 / 预览里的中图（宽 320dp）。
  card(320);

  const OfficeThumbSize(this.logicalWidth);

  /// 逻辑宽度（dp）。
  final double logicalWidth;

  /// 稳定字符串（进缓存 key）。
  String get tierName => name;
}

/// 各格式的长宽比（宽 → 高）。与阅读器里的版心一致：
///   * `.odoc` 纸张 3:4（A4 竖排在卡片里的通用裁切比）；
///   * `.osheet` 4:3（网格横向）；
///   * `.oslides` 16:9（`_SlidePage.canvasWidth/Height = 960/540`）。
double officeThumbAspectHeight(OfficeNativeFormat format, double width) {
  switch (format) {
    case OfficeNativeFormat.odoc:
      return width * 4 / 3;
    case OfficeNativeFormat.osheet:
      return width * 3 / 4;
    case OfficeNativeFormat.oslides:
      return width * 9 / 16;
  }
}

/// 某档位在某格式下的**逻辑**尺寸。
Size officeThumbLogicalSize(OfficeThumbSize size, OfficeNativeFormat format) =>
    Size(size.logicalWidth, officeThumbAspectHeight(format, size.logicalWidth));

/// 文件类型图标（渲染失败时 UI 的兜底，绝不空白）。
IconData officeThumbFormatIcon(OfficeNativeFormat format) {
  switch (format) {
    case OfficeNativeFormat.odoc:
      return Icons.description_outlined;
    case OfficeNativeFormat.osheet:
      return Icons.grid_on_outlined;
    case OfficeNativeFormat.oslides:
      return Icons.slideshow_outlined;
  }
}

// ---------------------------------------------------------------- 请求 / key

/// 一次缩略图请求。
///
/// [sourceKey] = `file_id` 或 NAS 路径；[versionStamp] = 版本戳（见
/// [officeThumbVersionStamp]）。**两者都必须进缓存 key**，否则覆盖同名文档后
/// 列表里会一直显示旧图。
@immutable
class OfficeThumbRequest {
  const OfficeThumbRequest({
    required this.sourceKey,
    required this.versionStamp,
    required this.format,
    this.size = OfficeThumbSize.card,
  });

  final String sourceKey;
  final String versionStamp;
  final OfficeNativeFormat format;
  final OfficeThumbSize size;

  /// 缓存 key：`file_id/path | mtime/version | 档位`。
  String get cacheKey => officeThumbCacheKey(
    sourceKey: sourceKey,
    versionStamp: versionStamp,
    sizeTier: size.tierName,
  );

  OfficeThumbRequest copyWith({OfficeThumbSize? size}) => OfficeThumbRequest(
    sourceKey: sourceKey,
    versionStamp: versionStamp,
    format: format,
    size: size ?? this.size,
  );

  @override
  bool operator ==(Object other) =>
      other is OfficeThumbRequest &&
      other.sourceKey == sourceKey &&
      other.versionStamp == versionStamp &&
      other.format == format &&
      other.size == size;

  @override
  int get hashCode => Object.hash(sourceKey, versionStamp, format, size);

  @override
  String toString() =>
      'OfficeThumbRequest($sourceKey, $versionStamp, ${format.name}, ${size.name})';
}

/// 版本戳：优先用服务端给的 `version`，其次 `mtime`，再补 `size`。
///
/// ★ 反向验证见 `test/office_doc_thumb_test.dart`：**把 `mtime` 从 key 里去掉**，
/// 「覆盖文档后必须重新渲染」的用例会失败 ⇒ 证明这个字段是**承重**的。
String officeThumbVersionStamp({
  int? mtimeSec,
  String? version,
  int? sizeBytes,
}) {
  final parts = <String>[
    if (version != null && version.isNotEmpty) 'v:$version',
    if (mtimeSec != null) 'm:$mtimeSec',
    if (sizeBytes != null) 's:$sizeBytes',
  ];
  return parts.isEmpty ? 'static' : parts.join(',');
}

// ---------------------------------------------------------------- 首页取法（纯函数）

/// `.odoc` 首页：只保留正文开头的 [kOfficeThumbDocBlocks] 块。
///
/// 附件图（`body.images`）**不进首页**：`ODocView` 把图片放在正文最后的 `Divider`
/// 之后，首页看不到；离屏渲染里若还去解码附件，只会白等解码时间。
ODocDocument truncateOfficeDocumentForThumb(ODocDocument document) {
  final body = document.body;
  if (body.blocks.length <= kOfficeThumbDocBlocks) return document;
  return ODocDocument(
    schema: document.schema,
    version: document.version,
    pageSetup: document.pageSetup,
    pageSetupSpecified: document.pageSetupSpecified,
    body: PmExtraction(
      blocks: body.blocks.take(kOfficeThumbDocBlocks).toList(growable: false),
      images: const [],
      nodeTypeCounts: body.nodeTypeCounts,
      pageSetup: body.pageSetup,
      decorations: body.decorations,
    ),
    nodeTypeCounts: document.nodeTypeCounts,
    commentCount: document.commentCount,
    indexSchemaVersion: document.indexSchemaVersion,
    sectionNames: document.sectionNames,
    pageDecorate: document.pageDecorate,
    decorations: document.decorations,
    headingLineHeights: document.headingLineHeights,
  );
}

/// `.osheet` 首页：**第一个可见工作表**的左上角 ≤ 24×8 格。
///
/// 只保留**完全落在窗口内**的合并区（跨出窗口的合并区会让网格引用不存在的行列）；
/// 行高/列宽表按窗口裁剪；`fixedRowTop/Left` 夹到窗口内。
OSheetWorkbook truncateOfficeSheetForThumb(OSheetWorkbook workbook) {
  if (workbook.sheets.isEmpty) return workbook;
  final sheet = workbook.sheets.firstWhere(
    (s) => s.isVisible,
    orElse: () => workbook.sheets.first,
  );
  final rows = math.min(sheet.rowCount, kOfficeThumbSheetRows);
  final cols = math.min(sheet.colCount, kOfficeThumbSheetCols);

  final cells = <int, Map<int, OSheetCell>>{};
  for (final rowEntry in sheet.cells.entries) {
    if (rowEntry.key >= rows) continue;
    final row = <int, OSheetCell>{};
    for (final cellEntry in rowEntry.value.entries) {
      if (cellEntry.key < cols) row[cellEntry.key] = cellEntry.value;
    }
    if (row.isNotEmpty) cells[rowEntry.key] = row;
  }

  final truncated = OSheetSheet(
    id: sheet.id,
    title: sheet.title,
    rowCount: rows,
    colCount: cols,
    cells: cells,
    raw: sheet.raw,
    isVisible: sheet.isVisible,
    fixedRowTop: math.min(sheet.fixedRowTop, rows),
    fixedColumnLeft: math.min(sheet.fixedColumnLeft, cols),
    defaultRowHeight: sheet.defaultRowHeight,
    defaultColWidth: sheet.defaultColWidth,
    rowHeights: _clipSizes(sheet.rowHeights, rows),
    colWidths: _clipSizes(sheet.colWidths, cols),
    hiddenRows: sheet.hiddenRows,
    hiddenCols: sheet.hiddenCols,
    mergedRegions: sheet.mergedRegions
        .where((r) => r.row2 < rows && r.col2 < cols)
        .toList(growable: false),
  );

  if (workbook.sheets.length == 1 &&
      truncated.rowCount == sheet.rowCount &&
      truncated.colCount == sheet.colCount) {
    return workbook;
  }
  return OSheetWorkbook(
    index: workbook.index,
    sheets: [truncated],
    styles: workbook.styles,
    sectionNames: workbook.sectionNames,
  );
}

Map<int, double>? _clipSizes(Map<int, double>? sizes, int limit) {
  if (sizes == null) return null;
  final out = <int, double>{};
  for (final entry in sizes.entries) {
    if (entry.key < limit) out[entry.key] = entry.value;
  }
  return out;
}

/// `.oslides` 首页：**只留第 1 张**幻灯片（其余删掉，避免 `PageView` 预建第 2 张）。
OSlidesPresentation truncateOfficeSlidesForThumb(
  OSlidesPresentation presentation,
) {
  if (presentation.slides.length <= 1) return presentation;
  return OSlidesPresentation(
    schema: presentation.schema,
    cx: presentation.cx,
    cy: presentation.cy,
    slides: [presentation.slides.first],
    master: presentation.master,
    layoutCount: presentation.layoutCount,
    nodeTypeCounts: presentation.nodeTypeCounts,
    sectionNames: presentation.sectionNames,
  );
}

/// 构建"首页"widget（**复用阅读器的渲染器**，不另写一套）。
///
/// 分派顺序与 `office_viewer_page.dart::_OfficeDocumentStage._body()` 一致。
///
/// ## 为什么"按卡片尺寸布局、再等比缩到目标档位"
///
/// 阅读器里那些 widget 天然排得下手机宽度（≥320dp），**排不下 96dp 的列表档**：
/// 本轮实测 `.osheet` 的工具条在 96dp 宽下 `RenderFlex overflowed`（横向 9px、
/// 纵向 9px）、`.oslides` 的页码栏一行需要 ~120dp。所以统一**按设计尺寸布局**
/// （卡片档 / 幻灯片画布），再用 `Transform.scale` 画到目标尺寸 ——
/// 内层坐标系不变，文字由光栅化器缩放（比在 96dp 下重新排版更好看，
/// 也不会触发第 256 轮那种"紧约束 + Transform.scale = 双重缩放"）。
Widget buildOfficeThumbFirstPage({
  required OfficeNativeDocument document,
  required OfficeThumbSize size,
  Key? key,
}) {
  final logical = officeThumbLogicalSize(size, document.format);
  final design = _officeThumbLayoutSize(document.format);
  return SizedBox(
    key: key ?? const Key('office-thumb-first-page'),
    width: logical.width,
    height: logical.height,
    child: ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: design.width,
        maxWidth: design.width,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Transform.scale(
          scale: logical.width / design.width,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: design.width,
            height: design.height,
            child: _firstPageBody(document, design),
          ),
        ),
      ),
    ),
  );
}

/// 首页 widget 的**布局尺寸**（"设计尺寸"；见 [buildOfficeThumbFirstPage] 的说明）。
///
/// * `.odoc`：卡片档（320 宽）—— 就是阅读器里的正文宽度；
/// * `.osheet`：卡片档高度 **+ 工具条 48dp**（多出来的那截给工具条，随后裁掉）；
/// * `.oslides`：阅读器画布 `960×540` **+ 页码栏 56dp**（同上）。
Size _officeThumbLayoutSize(OfficeNativeFormat format) {
  switch (format) {
    case OfficeNativeFormat.oslides:
      return const Size(
        _kOfficeSlideCanvasWidth,
        _kOfficeSlideCanvasHeight + kOfficeThumbSlidesPagerHeight,
      );
    case OfficeNativeFormat.osheet:
      final card = officeThumbLogicalSize(OfficeThumbSize.card, format);
      return Size(
        card.width,
        card.height + kOfficeThumbSheetToolbarHeight,
      );
    case OfficeNativeFormat.odoc:
      return officeThumbLogicalSize(OfficeThumbSize.card, format);
  }
}

Widget _firstPageBody(OfficeNativeDocument document, Size design) {
  final workbook = document.workbook;
  if (workbook != null) {
    return ColoredBox(
      key: const Key('office-thumb-sheet'),
      color: const Color(0xFFFFFFFF),
      // 用阅读器 O2 的**同一个**网格渲染器（`OfficeSheetView`）；
      // 外面那层旧适配器 `OSheetView` 只多加了两条"版式从简"的说明文字，
      // 那不是文档内容，缩略图里不要。
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: 0,
        maxHeight: double.infinity,
        child: SizedBox(
          height: design.height,
          // 工具条（适宽/缩放 ±，48dp）顶出可视区 ⇒ 缩略图只留网格。
          // 顺带一提：截断成单表也顺手去掉了多表时的 sheet 标签栏。
          child: Transform.translate(
            offset: const Offset(0, -kOfficeThumbSheetToolbarHeight),
            child: OfficeSheetView(
              sections: const <String, Object?>{},
              workbook: truncateOfficeSheetForThumb(workbook),
            ),
          ),
        ),
      ),
    );
  }
  final doc = document.document;
  if (doc != null) {
    return ColoredBox(
      key: const Key('office-thumb-doc'),
      color: const Color(0xFFFFFFFF),
      child: ODocView(document: truncateOfficeDocumentForThumb(doc)),
    );
  }
  final presentation = document.presentation;
  if (presentation != null) {
    return SizedBox(
      key: const Key('office-thumb-slides'),
      width: design.width,
      height: design.height,
      // 页码栏那 56dp 落在可视区之外 ⇒ 被外层 ClipRect 裁掉。
      child: OSlidesView(
        presentation: truncateOfficeSlidesForThumb(presentation),
      ),
    );
  }
  return const SizedBox.shrink();
}

// ---------------------------------------------------------------- 离屏渲染

/// 一次离屏渲染的输入。
@immutable
class OfficeThumbRenderJob {
  const OfficeThumbRenderJob({
    required this.document,
    required this.logicalSize,
    required this.pixelRatio,
    required this.view,
    required this.widget,
  });

  final OfficeNativeDocument document;
  final Size logicalSize;
  final double pixelRatio;
  final ui.FlutterView view;

  /// 已经构建好的首页 widget（`buildOfficeThumbFirstPage` 的产物）。
  final Widget widget;
}

/// 把"首页 widget"渲染成 PNG 字节；失败返回 null。
typedef OfficeThumbPngRenderer = Future<Uint8List?> Function(
  OfficeThumbRenderJob job,
);

/// 逻辑取消标记（Flutter 没有中断光栅化的原语，只能在对齐点丢弃）。
class OfficeThumbCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// [OfficeThumbPngRenderer] 的生产实现：把首页 widget 画到**离屏**渲染树再出 PNG。
///
/// 这条路径的好处：**不需要真实帧**（自己跑 build/layout/paint），所以单测可以在
/// `tester.runAsync` 里拿真 widget 出真像素。
Future<Uint8List?> renderOfficeThumbPng({required OfficeThumbRenderJob job}) =>
    officeThumbWidgetRenderer(job);

Future<Uint8List?> officeThumbWidgetRenderer(OfficeThumbRenderJob job) async {
  final logical = job.logicalSize;
  final pixelRatio = job.pixelRatio <= 0 ? 1.0 : job.pixelRatio;

  final pipelineOwner = PipelineOwner();
  final buildOwner = BuildOwner(focusManager: FocusManager());
  final renderView = RenderView(
    view: job.view,
    configuration: ViewConfiguration(
      physicalConstraints: BoxConstraints.tight(
        Size(logical.width * pixelRatio, logical.height * pixelRatio),
      ),
      logicalConstraints: BoxConstraints.tight(logical),
      devicePixelRatio: pixelRatio,
    ),
  );
  pipelineOwner.rootNode = renderView;
  renderView.prepareInitialFrame();

  final rootElement =
      RenderObjectToWidgetAdapter<RenderBox>(
        container: renderView,
        debugShortDescription: '[office-thumb]',
        // **最外层就是 RepaintBoundary**：离屏树的根子节点只能是它，
        // 于是 `renderView.child` 直接就是我们要抓的 RenderRepaintBoundary
        // （不用 GlobalKey —— 离屏树上 `GlobalKey.currentContext` 拿不到）。
        child: RepaintBoundary(
          child: _ThumbHost(logicalSize: logical, child: job.widget),
        ),
      ).attachToRenderTree(buildOwner);

  ui.Image? image;
  try {
    buildOwner.buildScope(rootElement);
    buildOwner.finalizeTree();
    pipelineOwner.flushLayout();
    pipelineOwner.flushCompositingBits();
    pipelineOwner.flushPaint();

    final root = renderView.child;
    final boundary = root is RenderRepaintBoundary ? root : null;
    if (boundary == null) {
      debugPrint('[office-thumb] 离屏树根不是 RepaintBoundary：$root');
      return null;
    }
    image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      debugPrint('[office-thumb] toByteData 返回 null');
      return null;
    }
    return data.buffer.asUint8List();
  } on Object catch (error) {
    // 离屏渲染失败**不是致命错误**（UI 会退化成文件类型图标），但要把原因留在
    // 日志里，否则真机上只会看到"图标"而查不出为什么。
    debugPrint('[office-thumb] 离屏渲染失败：$error');
    return null;
  } finally {
    image?.dispose();
  }
}

/// 离屏树里给 widget 一套"真环境"（主题 / 方向 / MediaQuery），
/// 否则 `Theme.of`、`Directionality`、`MediaQuery.of` 会在离屏树里炸。
class _ThumbHost extends StatelessWidget {
  const _ThumbHost({required this.logicalSize, required this.child});

  final Size logicalSize;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(size: logicalSize),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: AppTheme.light(),
          // `Overlay` 是必需的：阅读器里的 `IconButton` 带 `Tooltip`
          // （如 `office-sheet-zoom-out`），没有 Overlay 祖先会在 build 期抛错。
          child: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) => Material(color: Colors.transparent, child: child),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 节流（并发 + 超时）

/// 缩略图渲染调度器：**最多 [maxConcurrent] 个同时跑**，其余排队。
///
/// 生产建议做成单例 / provider（不要在 `autoDispose` 里重建），这样才能跨列表项限流。
class OfficeThumbScheduler {
  OfficeThumbScheduler({this.maxConcurrent = kOfficeThumbMaxConcurrent})
    : assert(maxConcurrent > 0, 'maxConcurrent 必须 ≥ 1');

  /// 进程内默认调度器（父层也可以自建一个注入）。
  static OfficeThumbScheduler? shared;

  /// 默认共享实例（懒创建）。
  static OfficeThumbScheduler get instance =>
      shared ??= OfficeThumbScheduler();

  final int maxConcurrent;

  final Queue<Completer<void>> _queue = Queue<Completer<void>>();
  int _active = 0;

  /// 已经开跑的任务数（单测断言"没有重复渲染"）。
  int startedCount = 0;

  /// 观测到的最大并发（单测断言限流真的生效）。
  int maxObservedConcurrent = 0;

  /// 当前在跑的数量。
  int get activeCount => _active;

  /// 排队等待的数量。
  int get pendingCount => _queue.length;

  /// 排队 → 执行 → 释放。[timeout] 到了就**立刻释放槽位**并调用 [onTimeout]。
  ///
  /// 超时用 `try/catch TimeoutException` 而不是 `Future.timeout(onTimeout:)`：
  /// 后者在 `T` 可空时 onTimeout 的返回类型会把 `null` 顶成 `FutureOr<T>` 的类型错误
  /// （本轮实测：`type '() => Null' is not a subtype of '(() => FutureOr<int>)?'`）。
  Future<T?> run<T>(
    Future<T> Function() task, {
    Duration? timeout,
    void Function(Object error)? onTimeout,
  }) async {
    await _acquire();
    startedCount++;
    if (_active > maxObservedConcurrent) maxObservedConcurrent = _active;
    try {
      if (timeout == null) return await task();
      try {
        return await task().timeout(timeout);
      } on TimeoutException catch (error) {
        // 槽位在 finally 里立刻释放 —— 这就是"取消"的全部：**逻辑取消**。
        // 底层光栅化没有中断原语（Flutter 没给），所以迟到的结果由调用方丢弃。
        onTimeout?.call(error);
        return null;
      }
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _queue.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    } else {
      _active--;
    }
  }
}

// ---------------------------------------------------------------- Widget

/// 模型获取函数（**注入**：生产 = `officeNativeReadProvider`，测试 = 假模型）。
typedef OfficeThumbModelFetcher =
    Future<OfficeNativeDocument> Function(OfficeThumbRequest request);

/// 一个自渲染缩略图：
///   缓存命中 → 直接显示；未命中 → 排队渲染（限流 + 超时）→ PNG；
///   失败 / 超时 → **文件类型图标**（绝不空白、绝不挂住）。
///
/// 想要什么尺寸就传 `request.size`（列表 = `OfficeThumbSize.list`，
/// 卡片 = `.card`）；**渲染按物理像素**，`pixelRatio` 缺省取
/// `MediaQuery.devicePixelRatioOf(context)`。
class OfficeDocThumb extends StatefulWidget {
  const OfficeDocThumb({
    super.key,
    required this.request,
    required this.fetchModel,
    this.cache,
    this.scheduler,
    this.renderer,
    this.timeout = kOfficeThumbRenderTimeout,
    this.pixelRatio,
    this.fallback,
    this.placeholder,
  });

  final OfficeThumbRequest request;
  final OfficeThumbModelFetcher fetchModel;
  final OfficeThumbCache? cache;
  final OfficeThumbScheduler? scheduler;

  /// 渲染器（测试注入假实现；null = [officeThumbWidgetRenderer]）。
  final OfficeThumbPngRenderer? renderer;

  /// 整个任务（取模型 + 构建 + 光栅化）的时限。
  final Duration timeout;

  /// 物理像素比；null = `MediaQuery.devicePixelRatioOf(context)`。
  final double? pixelRatio;

  /// 失败时的兜底 widget；null = 按格式显示 [officeThumbFormatIcon]。
  final Widget? fallback;

  /// 渲染中的占位；null = 骨架底色。
  final Widget? placeholder;

  /// 实际使用的渲染器（生产 = 离屏渲染器）。
  OfficeThumbPngRenderer resolveRenderer() =>
      renderer ?? officeThumbWidgetRenderer;

  @override
  State<OfficeDocThumb> createState() => _OfficeDocThumbState();
}

class _OfficeDocThumbState extends State<OfficeDocThumb> {
  OfficeThumbCache get _cache => widget.cache ?? OfficeThumbCache.instance;

  OfficeThumbScheduler get _scheduler =>
      widget.scheduler ?? OfficeThumbScheduler.instance;

  Uint8List? _bytes;
  Object? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _start();
  }

  @override
  void didUpdateWidget(covariant OfficeDocThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request) {
      _bytes = null;
      _error = null;
      _start();
    }
  }

  void _start() {
    final key = widget.request.cacheKey;
    final cached = _cache.memoryGet(key);
    if (cached != null) {
      _bytes = cached;
      return;
    }
    final reason = _cache.failureReason(key);
    if (reason != null) {
      _error = reason;
      return;
    }
    unawaited(_load(key));
  }

  Future<void> _load(String key) async {
    final bytes = await _cache.inflight(key, () => _renderOnce(key));
    if (!mounted) return;
    final reason = bytes == null
        ? (_cache.failureReason(key) ?? 'render failed')
        : null;
    // 诊断（第 261 轮真机排查）：office 缩略图真机上"秒失败"，但界面只有图标，
    // 原因完全不可见。release 包里 `debugPrint` 照样进 logcat（tag `flutter`），
    // 所以把原因打出来。**定位完成后可去掉**（或用 const 开关关掉）。
    if (reason != null) {
      debugPrint('[officeThumb] FAIL key=$key reason=$reason');
    }
    setState(() {
      _bytes = bytes;
      _error = reason;
    });
  }

  Future<Uint8List?> _renderOnce(String key) {
    final renderer = widget.resolveRenderer();
    return _scheduler
        .run<Uint8List?>(
          () async {
            if (!mounted) return null;
            final request = widget.request;
            final document = await widget.fetchModel(request);
            if (!mounted) return null;
            final logical = officeThumbLogicalSize(
              request.size,
              document.format,
            );
            final pixelRatio =
                widget.pixelRatio ?? MediaQuery.devicePixelRatioOf(context);
            final job = OfficeThumbRenderJob(
              document: document,
              logicalSize: logical,
              pixelRatio: pixelRatio,
              view: View.of(context),
              widget: buildOfficeThumbFirstPage(
                document: document,
                size: request.size,
              ),
            );
            final bytes = await renderer(job);
            if (bytes == null || bytes.isEmpty) {
              throw StateError('office thumb renderer returned no bytes');
            }
            // 超时后迟到的结果**不许**进缓存（否则失败记忆会被抹掉）。
            if (!_cache.hasFailed(key)) await _cache.put(key, bytes);
            return bytes;
          },
          timeout: widget.timeout,
          onTimeout: (error) => _cache.markFailed(
            key,
            error,
            ttl: kOfficeThumbTimeoutRetry,
          ),
        )
        .catchError((Object error, StackTrace st) {
          debugPrint('[officeThumb] THROW key=$key error=$error');
          debugPrint('$st');
          _cache.markFailed(key, error);
          return null;
        });
  }

  @override
  Widget build(BuildContext context) {
    final size = officeThumbLogicalSize(
      widget.request.size,
      widget.request.format,
    );
    return SizedBox(width: size.width, height: size.height, child: _body());
  }

  Widget _body() {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        key: const Key('office-thumb-image'),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
      );
    }
    if (_error != null) {
      return widget.fallback ??
          Center(
            key: const Key('office-thumb-fallback'),
            child: Icon(
              officeThumbFormatIcon(widget.request.format),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
    }
    return widget.placeholder ??
        const ColoredBox(
          key: Key('office-thumb-loading'),
          color: Color(0xFFE9EDF2),
        );
  }
}
