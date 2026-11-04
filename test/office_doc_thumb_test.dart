// Office 自渲染缩略图（`office_doc_thumb.dart`）的**离线**能力测试。
//
// 口径（对齐需求）：三类格式各一条"首页内容"用例 + 真 PNG 像素用例 + 缓存/失败记忆/
// 节流/超时 + **反向验证**（版本戳承重）。
//
// ⚠️ 全部**离线**：模型由假 fetcher 给（`ODocDocument` / `OSheetWorkbook` /
// `OSlidesPresentation` 直接构造），**零网络、零设备、零文件系统**（磁盘用例只用
// 系统临时目录）。
//
// ⚠️ 真像素用例必须放 `tester.runAsync`：`RenderRepaintBoundary.toImage()` /
// `Image.toByteData()` 是**引擎异步**，在 widget 测试的假时钟里不会完成。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/odoc_model.dart';
import 'package:synhub/src/data/office_native/office_native_reader.dart';
import 'package:synhub/src/data/office_native/ofile.dart';
import 'package:synhub/src/data/office_native/osheet_model.dart';
import 'package:synhub/src/data/office_native/oslides_model.dart';
import 'package:synhub/src/data/office_native/prosemirror_model.dart';
import 'package:synhub/src/features/files/office_viewer_page.dart';
import 'package:synhub/src/features/office/office_doc_thumb.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_sheet_view.dart';

/// 一张真 1×1 PNG（用作假渲染器的返回值；`Image.memory` 能真解码）。
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

bool _isPng(Uint8List bytes) =>
    bytes.length > 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

// ------------------------------------------------------------------ 假模型

OFile _ofile() => OFile(
  schema: 3,
  enc: false,
  id: 'ofile-test',
  ver: '1',
  end: false,
  sections: const {},
  metadata: const {},
);

ODocDocument _doc(List<String> texts) => ODocDocument(
  schema: 1,
  version: 1,
  pageSetup: ODocPageSetup.a4Default,
  body: PmExtraction(
    blocks: [
      for (final t in texts) PmBlock(kind: PmBlockKind.paragraph, text: t),
    ],
    images: const [],
    nodeTypeCounts: const {},
  ),
  nodeTypeCounts: const {},
  commentCount: 0,
  indexSchemaVersion: 1,
  sectionNames: const ['content'],
  pageDecorate: null,
);

OfficeNativeDocument _docNative(List<String> texts) => OfficeNativeDocument(
  format: OfficeNativeFormat.odoc,
  envelope: _ofile(),
  document: _doc(texts),
);

OSheetWorkbook _workbook({
  int rows = 500,
  int cols = 30,
  Map<int, Map<int, OSheetCell>>? cells,
  List<OSheetMergeRange> merges = const [],
  Map<int, double>? rowHeights,
  Map<int, double>? colWidths,
}) {
  final sheet = OSheetSheet(
    id: 'sh_1',
    title: 'Sheet1',
    rowCount: rows,
    colCount: cols,
    cells: cells ?? const {},
    raw: const {},
    rowHeights: rowHeights,
    colWidths: colWidths,
    mergedRegions: merges,
  );
  return OSheetWorkbook(
    index: OSheetIndex(
      schemaVersion: 5,
      ver: 1,
      gcVer: 1,
      maxIndex: 1,
      order: const ['sh_1'],
      sheetTitles: const {'sh_1': 'Sheet1'},
      deleted: const {},
      raw: const {},
    ),
    sheets: [sheet],
    styles: OSheetStylePool(
      styles: const [],
      fonts: const [],
      fills: const [],
      alignments: const [],
      borders: const [],
      numberFormats: const [],
      raw: const {},
    ),
    sectionNames: const ['sh_1'],
  );
}

OfficeNativeDocument _sheetNative(OSheetWorkbook workbook) =>
    OfficeNativeDocument(
      format: OfficeNativeFormat.osheet,
      envelope: _ofile(),
      workbook: workbook,
    );

OSlide _slide(int order, String text) => OSlide(
  order: order,
  id: 'slide_$order',
  masterId: 'master',
  layoutId: 'layout',
  isVisible: true,
  content: PmExtraction(
    blocks: [PmBlock(kind: PmBlockKind.paragraph, text: text)],
    images: const [],
    nodeTypeCounts: const {},
  ),
  notes: '',
  raw: const {},
);

OfficeNativeDocument _slidesNative(List<String> texts) => OfficeNativeDocument(
  format: OfficeNativeFormat.oslides,
  envelope: _ofile(),
  presentation: OSlidesPresentation(
    schema: 1,
    cx: 960,
    cy: 540,
    slides: [
      for (var i = 0; i < texts.length; i++) _slide(i, texts[i]),
    ],
    master: PmExtraction(
      blocks: const [],
      images: const [],
      nodeTypeCounts: const {},
    ),
    layoutCount: 1,
    nodeTypeCounts: const {},
    sectionNames: const [],
  ),
);

// ------------------------------------------------------------------ 假 fetcher / 假渲染器

class _FakeFetcher {
  _FakeFetcher(this.build);

  final Future<OfficeNativeDocument> Function(OfficeThumbRequest req, int call)
  build;
  int calls = 0;

  Future<OfficeNativeDocument> call(OfficeThumbRequest req) {
    calls++;
    return build(req, calls);
  }
}

class _FakeRenderer {
  Uint8List bytes = _png1x1;
  Duration? delay;
  Object? error;
  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  Future<Uint8List?> call(OfficeThumbRenderJob job) async {
    calls++;
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      if (delay != null) await Future<void>.delayed(delay!);
      if (error != null) throw error!;
      return bytes;
    } finally {
      inFlight--;
    }
  }
}

OfficeThumbRequest _req({
  String path = '/mydrive/a.odoc',
  String stamp = 'm:1',
  OfficeNativeFormat format = OfficeNativeFormat.odoc,
  OfficeThumbSize size = OfficeThumbSize.card,
}) => OfficeThumbRequest(
  sourceKey: path,
  versionStamp: stamp,
  format: format,
  size: size,
);

/// **只用内存**的缓存：单测里不碰 path_provider（避免平台通道等待）。
OfficeThumbCache _memCache([int capacity = 8]) =>
    OfficeThumbCache(memoryCapacity: capacity, diskRoot: () async => null);

Widget _host(Widget child) =>
    MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: Center(child: child)));

OfficeDocThumb _thumb({
  required _FakeFetcher fetcher,
  required _FakeRenderer renderer,
  required OfficeThumbCache cache,
  OfficeThumbScheduler? scheduler,
  OfficeThumbRequest? request,
  Duration timeout = const Duration(seconds: 5),
}) => OfficeDocThumb(
  request: request ?? _req(),
  fetchModel: fetcher.call,
  cache: cache,
  scheduler: scheduler ?? OfficeThumbScheduler(),
  renderer: renderer.call,
  timeout: timeout,
);

void main() {
  // ================================================================ 纯函数 / 首页取法
  group('尺寸档位', () {
    test('list = 96 宽、card = 320 宽；高度按格式比例', () {
      expect(officeThumbLogicalSize(
        OfficeThumbSize.list,
        OfficeNativeFormat.odoc,
      ), const Size(96, 128));
      expect(officeThumbLogicalSize(
        OfficeThumbSize.card,
        OfficeNativeFormat.odoc,
      ), const Size(320, 320 * 4 / 3));
      expect(officeThumbLogicalSize(
        OfficeThumbSize.card,
        OfficeNativeFormat.osheet,
      ), const Size(320, 240));
      expect(officeThumbLogicalSize(
        OfficeThumbSize.list,
        OfficeNativeFormat.oslides,
      ), const Size(96, 54));
    });

    test('★ 缓存 key = 路径 + 版本戳 + 档位（三者都参与）', () {
      final base = _req();
      expect(base.cacheKey, '/mydrive/a.odoc|m:1|card');
      expect(base.cacheKey, isNot(_req(stamp: 'm:2').cacheKey));
      expect(base.cacheKey, isNot(_req(path: '/mydrive/b.odoc').cacheKey));
      expect(base.cacheKey, isNot(_req(size: OfficeThumbSize.list).cacheKey));
    });

    test('★ 反向验证：版本戳必须含 mtime —— 去掉它就该"认不出改动"', () {
      // 生产版本戳：mtime 变了 ⇒ 戳变了 ⇒ key 变了。
      final a = officeThumbVersionStamp(mtimeSec: 100, sizeBytes: 10);
      final b = officeThumbVersionStamp(mtimeSec: 200, sizeBytes: 10);
      expect(a, 'm:100,s:10');
      expect(b, 'm:200,s:10');
      expect(a, isNot(b));

      // 若像"只按路径/大小"那样把 mtime 拿掉 ⇒ 两个戳**相等**，
      // 于是 `_req(stamp:)` 会指向同一张缓存图（这就是必须写进用例的失效场景）。
      final noMtime = officeThumbVersionStamp(sizeBytes: 10);
      final noMtime2 = officeThumbVersionStamp(sizeBytes: 10);
      expect(noMtime, noMtime2);
      expect(
        _req(stamp: noMtime).cacheKey,
        _req(stamp: noMtime2).cacheKey,
        reason: '去掉 mtime 后 key 相同 —— 用例靠这个断言证明版本戳是承重的',
      );
    });
  });

  group('首页取法（纯函数）', () {
    test('odoc：只取前 24 块、丢掉附件图、其余字段保持', () {
      final long = _doc([for (var i = 0; i < 60; i++) 'P$i']);
      final cut = truncateOfficeDocumentForThumb(long);
      expect(cut.blocks.length, kOfficeThumbDocBlocks);
      expect(cut.blocks.first.text, 'P0');
      expect(cut.blocks.last.text, 'P${kOfficeThumbDocBlocks - 1}');
      expect(cut.images, isEmpty);
      expect(cut.schema, long.schema);
      expect(cut.sectionNames, long.sectionNames);
      expect(cut.pageSetup, long.pageSetup);

      // 短文档**不重建**（同一个对象），避免无谓开销。
      final short = _doc(['A', 'B']);
      expect(identical(truncateOfficeDocumentForThumb(short), short), isTrue);
    });

    test('osheet：500×30 → 24×8，窗口外单元格被丢掉', () {
      final wb = _workbook(
        cells: {
          0: {
            0: const OSheetCell(row: 0, col: 0, value: 'A1'),
            7: const OSheetCell(row: 0, col: 7, value: 'H1'),
            8: const OSheetCell(row: 0, col: 8, value: 'I1'),
          },
          23: {0: const OSheetCell(row: 23, col: 0, value: 'A24')},
          24: {0: const OSheetCell(row: 24, col: 0, value: 'A25')},
        },
        rowHeights: {0: 30, 5: 40, 100: 50},
        colWidths: {0: 120, 20: 200},
      );
      expect(wb.sheets, hasLength(1));

      final sheet = truncateOfficeSheetForThumb(wb).sheets.single;
      expect(sheet.rowCount, kOfficeThumbSheetRows);
      expect(sheet.colCount, kOfficeThumbSheetCols);
      expect(sheet.cells.keys, containsAll(<int>[0, 23]));
      expect(sheet.cells.containsKey(24), isFalse, reason: '第 25 行在窗口外');
      expect(sheet.cells[0]!.keys, containsAll(<int>[0, 7]));
      expect(sheet.cells[0]!.containsKey(8), isFalse, reason: '第 9 列在窗口外');
      expect(sheet.rowHeights, {0: 30, 5: 40});
      expect(sheet.colWidths, {0: 120});
      // 单元格总数被夹住 ⇒ 缩略图不会去构建 5 万格。
      final rendered = sheet.cells.values.fold<int>(0, (n, r) => n + r.length);
      expect(rendered, lessThanOrEqualTo(kOfficeThumbSheetRows * kOfficeThumbSheetCols));
    });

    test('osheet：跨出窗口的合并区被丢弃（不引用不存在的行列）', () {
      final wb = _workbook(
        merges: const [
          OSheetMergeRange(0, 0, 1, 3), // 窗口内 → 保留
          OSheetMergeRange(20, 0, 30, 2), // 行越界 → 丢弃
          OSheetMergeRange(0, 6, 1, 9), // 列越界 → 丢弃
        ],
      );
      final sheet = truncateOfficeSheetForThumb(wb).sheets.single;
      expect(sheet.mergedRegions, hasLength(1));
      expect(sheet.mergedRegions.single.row2, 1);
      expect(sheet.mergedRegions.single.col2, 3);
    });

    test('oslides：3 张 → 只留第 1 张', () {
      final presentation = _slidesNative(const ['S1', 'S2', 'S3']).presentation!;
      final cut = truncateOfficeSlidesForThumb(presentation);
      expect(cut.slides, hasLength(1));
      expect(cut.slides.single.plainText, 'S1');
      expect(cut.cx, presentation.cx);
      expect(cut.cy, presentation.cy);
      final single = _slidesNative(const ['S1']).presentation!;
      expect(identical(truncateOfficeSlidesForThumb(single), single), isTrue);
    });
  });

  // ================================================================ 首页 widget（内容特征）
  group('首页 widget 用的是阅读器的渲染器', () {
    testWidgets('odoc 首页 = ODocView，且喂进去的是截断后的正文', (tester) async {
      final doc = _docNative([for (var i = 0; i < 40; i++) 'DOC$i']);
      await tester.pumpWidget(
        _host(buildOfficeThumbFirstPage(document: doc, size: OfficeThumbSize.card)),
      );
      expect(find.byType(ODocView), findsOneWidget);
      final view = tester.widget<ODocView>(find.byType(ODocView));
      expect(view.document.blocks, hasLength(kOfficeThumbDocBlocks));
      expect(find.text('DOC0'), findsOneWidget);
      expect(find.text('DOC$kOfficeThumbDocBlocks'), findsNothing);
      // 内层坐标系 = 卡片档宽度（列表档靠缩放，不重排版）。
      expect(
        tester.getSize(find.byKey(const Key('office-doc-blocks'))).width,
        OfficeThumbSize.card.logicalWidth,
      );
    });

    testWidgets('osheet 首页 = 阅读器的 OfficeSheetView，且 workbook 已截断', (tester) async {
      final workbook = _workbook(
        cells: {
          0: {0: const OSheetCell(row: 0, col: 0, value: 'SHEET-A1')},
        },
      );
      await tester.pumpWidget(
        _host(
          buildOfficeThumbFirstPage(
            document: _sheetNative(workbook),
            size: OfficeThumbSize.card,
          ),
        ),
      );
      // 用的是阅读器 O2 的同一个网格渲染器。
      expect(find.byType(OfficeSheetView), findsOneWidget);
      final view = tester.widget<OfficeSheetView>(find.byType(OfficeSheetView));
      expect(view.workbook!.sheets.single.rowCount, kOfficeThumbSheetRows);
      expect(view.workbook!.sheets.single.colCount, kOfficeThumbSheetCols);
      expect(find.text('SHEET-A1'), findsOneWidget);

      // 内层仍是 320dp 的阅读器布局（缩放只影响绘制）——量内层才防得住"双重缩放"。
      expect(
        tester.getSize(find.byKey(const Key('office-sheet-view'))).width,
        OfficeThumbSize.card.logicalWidth,
      );
      // 工具条（阅读器的交互 chrome）被顶到可视区**上方** ⇒ 缩略图里只有网格。
      final box = tester.getRect(find.byKey(const Key('office-thumb-first-page')));
      final toolbar = tester.getRect(find.byKey(const Key('office-sheet-toolbar')));
      expect(toolbar.bottom, lessThanOrEqualTo(box.top + 1));
    });

    testWidgets('oslides 首页 = OSlidesView 且只有第 1 张；页码栏被裁到可视区外', (tester) async {
      final doc = _slidesNative(const ['SLIDE-FIRST', 'SLIDE-SECOND']);
      await tester.pumpWidget(
        _host(buildOfficeThumbFirstPage(document: doc, size: OfficeThumbSize.card)),
      );
      expect(find.byType(OSlidesView), findsOneWidget);
      final view = tester.widget<OSlidesView>(find.byType(OSlidesView));
      expect(view.presentation.slides, hasLength(1));
      expect(view.presentation.slides.single.plainText, 'SLIDE-FIRST');
      expect(find.text('SLIDE-SECOND'), findsNothing);
      expect(find.text('SLIDE-FIRST'), findsOneWidget);

      // 内层仍是阅读器的 960dp 画布（`Transform.scale` 只缩放绘制、不改布局）——
      // 这条断言就是第 256 轮"双重缩放"的守门人：量内层，不量外层。
      expect(
        tester.getSize(find.byKey(const Key('office-slides-pages'))).width,
        960,
      );
      // 页码栏确实存在（复用了阅读器的完整路径）……
      // ……但它的矩形**完全落在**缩略图可视区下方（会被外层 ClipRect 裁掉）。
      final box = tester.getRect(find.byKey(const Key('office-thumb-first-page')));
      final pager = tester.getRect(
        find.byKey(const Key('office-slides-page-indicator')),
      );
      expect(pager.top, greaterThanOrEqualTo(box.bottom - 1));
    });
  });

  // ================================================================ 真像素（引擎异步）
  group('★ 真渲染：真 widget → 真 PNG', () {
    testWidgets('三种格式各自出真 PNG（89 50 4E 47）', (tester) async {
      final docs = <String, OfficeNativeDocument>{
        'odoc': _docNative([for (var i = 0; i < 40; i++) 'P$i']),
        'osheet': _sheetNative(
          _workbook(cells: {0: {0: const OSheetCell(row: 0, col: 0, value: 'X')}}),
        ),
        'oslides': _slidesNative(const ['ONE', 'TWO']),
      };
      for (final entry in docs.entries) {
        final bytes = await tester.runAsync(
          () => renderOfficeThumbPng(
            job: OfficeThumbRenderJob(
              document: entry.value,
              logicalSize: officeThumbLogicalSize(
                OfficeThumbSize.list,
                entry.value.format,
              ),
              pixelRatio: 1,
              view: tester.view,
              widget: buildOfficeThumbFirstPage(
                document: entry.value,
                size: OfficeThumbSize.list,
              ),
            ),
          ),
        );
        expect(bytes, isNotNull, reason: '${entry.key} 必须渲染出字节');
        expect(
          _isPng(bytes!),
          isTrue,
          reason: '${entry.key} 必须是 PNG（前 4 字节 89 50 4E 47）',
        );
        expect(bytes.length, greaterThan(100), reason: '不可能是空图');
      }
    });

    testWidgets('★ 按 pixelRatio 出物理像素（不靠放大糊图）', (tester) async {
      final doc = _docNative([for (var i = 0; i < 10; i++) 'P$i']);
      Future<Size> renderAt(double dpr, OfficeThumbSize size) async {
        final bytes = await tester.runAsync(
          () => renderOfficeThumbPng(
            job: OfficeThumbRenderJob(
              document: doc,
              logicalSize: officeThumbLogicalSize(size, doc.format),
              pixelRatio: dpr,
              view: tester.view,
              widget: buildOfficeThumbFirstPage(document: doc, size: size),
            ),
          ),
        );
        expect(bytes, isNotNull);
        final decoded = await tester.runAsync(() async {
          final codec = await ui.instantiateImageCodec(bytes!);
          final frame = await codec.getNextFrame();
          final image = frame.image;
          final out = Size(image.width.toDouble(), image.height.toDouble());
          image.dispose();
          codec.dispose();
          return out;
        });
        return decoded!;
      }

      // 列表档 96×128 逻辑像素 @3x ⇒ 288×384 物理像素。
      expect(
        await renderAt(3, OfficeThumbSize.list),
        const Size(96 * 3.0, 128 * 3.0),
      );
      // 卡片档 320×426.67 @2x ⇒ 640×853.33。
      final card = await renderAt(2, OfficeThumbSize.card);
      expect(card.width, 320 * 2.0);
      expect(card.height, closeTo(320 * 4 / 3 * 2, 1));
    });
  });

  // ================================================================ Widget：缓存 / 失败记忆 / 超时
  group('缓存与降级（widget）', () {
    testWidgets('缓存命中 ⇒ 不重新取模型、不重渲染', (tester) async {
      final cache = _memCache(4);
      final fetcher = _FakeFetcher((req, _) async => _docNative(const ['A']));
      final renderer = _FakeRenderer();

      await tester.pumpWidget(
        _host(_thumb(fetcher: fetcher, renderer: renderer, cache: cache)),
      );
      await tester.pump();
      await tester.pump();
      expect(fetcher.calls, 1);
      expect(renderer.calls, 1);
      expect(find.byKey(const Key('office-thumb-image')), findsOneWidget);

      // 第二个同 key 的实例（模拟列表滚动回来）⇒ 直接命中内存。
      await tester.pumpWidget(
        _host(
          _thumb(
            fetcher: fetcher,
            renderer: renderer,
            cache: cache,
            request: _req(),
          ),
        ),
      );
      await tester.pump();
      expect(fetcher.calls, 1, reason: '命中缓存不许再取模型');
      expect(renderer.calls, 1, reason: '命中缓存不许再渲染');
      expect(find.byKey(const Key('office-thumb-image')), findsOneWidget);
    });

    testWidgets('★ 反向验证：mtime 变了必须重新渲染（旧图不许复用）', (tester) async {
      final cache = _memCache(4);
      final fetcher = _FakeFetcher((req, _) async => _docNative(const ['A']));
      final renderer = _FakeRenderer();

      await tester.pumpWidget(
        _host(
          _thumb(
            fetcher: fetcher,
            renderer: renderer,
            cache: cache,
            request: _req(stamp: 'm:100'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(renderer.calls, 1);
      final oldBytes = cache.memoryGet(_req(stamp: 'm:100').cacheKey);
      expect(oldBytes, isNotNull);

      // 同名文档被覆盖 ⇒ mtime 变化 ⇒ 新 key ⇒ **重新取模型 + 重新渲染**。
      await tester.pumpWidget(
        _host(
          _thumb(
            fetcher: fetcher,
            renderer: renderer,
            cache: cache,
            request: _req(stamp: 'm:200'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(fetcher.calls, 2, reason: 'mtime 变了必须重新取模型');
      expect(renderer.calls, 2, reason: 'mtime 变了必须重新渲染（否则显示旧图）');
      expect(find.byKey(const Key('office-thumb-image')), findsOneWidget);
    });

    testWidgets('失败记忆：同一 key 第二次直接显示类型图标，不再重试', (tester) async {
      final cache = _memCache(4);
      final fetcher = _FakeFetcher(
        (req, _) async => throw StateError('模型拿不到'),
      );
      final renderer = _FakeRenderer();

      await tester.pumpWidget(
        _host(_thumb(fetcher: fetcher, renderer: renderer, cache: cache)),
      );
      await tester.pump();
      await tester.pump();
      expect(fetcher.calls, 1);
      expect(find.byKey(const Key('office-thumb-fallback')), findsOneWidget);
      expect(find.byIcon(officeThumbFormatIcon(OfficeNativeFormat.odoc)), findsOneWidget);
      expect(cache.hasFailed(_req().cacheKey), isTrue);

      await tester.pumpWidget(
        _host(
          _thumb(
            fetcher: fetcher,
            renderer: renderer,
            cache: cache,
            request: _req(),
          ),
        ),
      );
      await tester.pump();
      expect(fetcher.calls, 1, reason: '失败记忆命中后不许再取模型');
      expect(renderer.calls, 0);
      expect(find.byKey(const Key('office-thumb-fallback')), findsOneWidget);
    });

    testWidgets('★ 超时降级：1.8s 内没完成 ⇒ 图标兜底 + 记住失败 + 立刻释放槽位', (tester) async {
      final cache = _memCache(4);
      final scheduler = OfficeThumbScheduler(maxConcurrent: 1);
      final never = Completer<OfficeNativeDocument>();
      final fetcher = _FakeFetcher((req, _) => never.future);
      final renderer = _FakeRenderer();

      await tester.pumpWidget(
        _host(
          _thumb(
            fetcher: fetcher,
            renderer: renderer,
            cache: cache,
            scheduler: scheduler,
            timeout: const Duration(milliseconds: 200),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('office-thumb-loading')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byKey(const Key('office-thumb-fallback')), findsOneWidget);
      expect(find.byKey(const Key('office-thumb-image')), findsNothing);
      expect(cache.hasFailed(_req().cacheKey), isTrue);
      expect(
        cache.failureReason(_req().cacheKey),
        isA<TimeoutException>(),
        reason: '失败原因要能分辨"超时"',
      );
      expect(scheduler.activeCount, 0, reason: '超时后槽位必须立刻释放（不能占着）');
      expect(renderer.calls, 0);
    });
  });

  // ================================================================ 节流 / 去重 / 磁盘（纯 Dart）
  group('节流 / 并发去重 / 磁盘', () {
    test('★ 限流：5 个请求最多 2 个同时跑，其余排队', () async {
      final scheduler = OfficeThumbScheduler(
        maxConcurrent: kOfficeThumbMaxConcurrent,
      );
      var inFlight = 0;
      var maxInFlight = 0;
      final gates = List.generate(5, (_) => Completer<void>());
      final futures = <Future<int?>>[];
      for (var i = 0; i < 5; i++) {
        final index = i;
        futures.add(
          scheduler.run<int>(() async {
            inFlight++;
            maxInFlight = math.max(maxInFlight, inFlight);
            await gates[index].future;
            inFlight--;
            return index;
          }),
        );
      }
      for (var i = 0; i < 8; i++) {
        await Future<void>.microtask(() {});
      }
      expect(scheduler.startedCount, kOfficeThumbMaxConcurrent);
      expect(scheduler.activeCount, kOfficeThumbMaxConcurrent);
      expect(scheduler.pendingCount, 3);
      expect(maxInFlight, lessThanOrEqualTo(kOfficeThumbMaxConcurrent));

      for (final gate in gates) {
        gate.complete();
      }
      await Future.wait(futures);
      expect(scheduler.startedCount, 5);
      expect(maxInFlight, lessThanOrEqualTo(kOfficeThumbMaxConcurrent));
      expect(scheduler.maxObservedConcurrent, kOfficeThumbMaxConcurrent);
      expect(scheduler.activeCount, 0);
      expect(scheduler.pendingCount, 0);
    });

    test('超时也是"逻辑取消"：立刻放掉槽位，迟到的结果不许覆盖失败记忆', () async {
      final scheduler = OfficeThumbScheduler(maxConcurrent: 1);
      final never = Completer<int>();
      Object? timedOut;
      final result = await scheduler.run<int>(
        () async {
          await never.future;
          return 1;
        },
        timeout: const Duration(milliseconds: 30),
        onTimeout: (error) => timedOut = error,
      );
      expect(result, isNull);
      expect(timedOut, isA<TimeoutException>());
      expect(scheduler.activeCount, 0);
      expect(scheduler.pendingCount, 0);
    });

    test('同一 key 并发请求只渲染一次（inflight 去重）', () async {
      final cache = _memCache(2);
      var calls = 0;
      final gate = Completer<Uint8List?>();
      Future<Uint8List?> task() {
        calls++;
        return gate.future;
      }

      final first = cache.inflight('k', task);
      final second = cache.inflight('k', task);
      expect(identical(first, second), isTrue);
      gate.complete(_png1x1);
      // ★ 这条 `await` 曾经**永久挂起**：`inflight` 早期实现用
      // `task().whenComplete(() => _inflight.remove(key))`，而
      // `Map<String, Future<...>>.remove` 返回的正是那个 future 本身 ⇒
      // `whenComplete` 等它 = 自己等自己。用例当场抓住。
      final done = await Future.wait([first, second]);
      expect(calls, 1);
      expect(done.first, _png1x1);
    });

    test('磁盘缓存：换一个"进程"（新 cache 实例）仍然命中，不用重渲染', () async {
      final dir = Directory.systemTemp.createTempSync('office_thumb_test');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final key = _req().cacheKey;

      final first = OfficeThumbCache(diskRoot: () async => dir);
      await first.put(key, _png1x1);
      // put 的磁盘写是 unawaited 的（内存命中即返回）⇒ 等它落盘。
      await first.flushDisk();

      final second = OfficeThumbCache(diskRoot: () async => dir);
      expect(second.memoryGet(key), isNull, reason: '新实例内存是空的');
      final fromDisk = await second.diskGet(key);
      expect(fromDisk, isNotNull);
      expect(_isPng(fromDisk!), isTrue);
      expect(fromDisk, _png1x1);
    });

    test('内存 LRU 有上限（容量到了就淘汰最久未用）', () async {
      final cache = _memCache(2);
      await cache.put('a', _png1x1);
      await cache.put('b', _png1x1);
      cache.memoryGet('a'); // a 变成最近使用
      await cache.put('c', _png1x1);
      expect(cache.memoryKeys, containsAll(<String>['a', 'c']));
      expect(cache.memoryKeys.contains('b'), isFalse);
    });
  });

  // ================================================================ 接线
  group('接线', () {
    testWidgets('缺省渲染器 = 生产离屏渲染器（不是假实现）', (tester) async {
      final widget = OfficeDocThumb(
        request: _req(),
        fetchModel: _FakeFetcher((req, _) async => _docNative(const ['A'])).call,
      );
      expect(widget.resolveRenderer(), same(officeThumbWidgetRenderer));
      expect(widget.renderer, isNull);
    });

    testWidgets('widget 自身尺寸跟随档位（list 96 宽 / card 320 宽）', (tester) async {
      final cache = _memCache(4);
      final fetcher = _FakeFetcher((req, _) async => _docNative(const ['A']));
      final renderer = _FakeRenderer();

      await tester.pumpWidget(
        _host(
          _thumb(
            fetcher: fetcher,
            renderer: renderer,
            cache: cache,
            request: _req(size: OfficeThumbSize.list),
          ),
        ),
      );
      await tester.pump();
      var size = tester.getSize(find.byType(OfficeDocThumb));
      expect(size.width, OfficeThumbSize.list.logicalWidth);

      await tester.pumpWidget(
        _host(
          _thumb(
            fetcher: fetcher,
            renderer: renderer,
            cache: cache,
            request: _req(size: OfficeThumbSize.card),
          ),
        ),
      );
      await tester.pump();
      size = tester.getSize(find.byType(OfficeDocThumb));
      expect(size.width, OfficeThumbSize.card.logicalWidth);
      // 档位不同 ⇒ 两个 key ⇒ 真的渲染了两张。
      expect(renderer.calls, 2);
    });
  });
}
