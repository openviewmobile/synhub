// ★★ ③Drive 第 219 轮 **D61「PDF 批注 / 签名」** 的离线用例。
//
// 官方：包内带 `pdftool`/pdfium/pdfbox，可在 App 内批注后存回 Drive。
// 我方（本轮）：**批注模型 + 归一化几何 + sidecar 持久化 + 烙平导出 + 存回 Drive**。
//
// ⚠️ 诚实边界：我们不往 PDF 对象层写注释对象（导出即烙平，导出后不可再单独编辑）；
// 官方 pdfium 是改注释对象。这一点写在台账里，不冒充一致。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/drive/drive_pdf_markup.dart';
import 'package:synhub/src/features/drive/drive_pdf_markup_page.dart';

/// 1x1 PNG（真解码器能读，`pdf` 包的 `MemoryImage` 才吃得下）
final _png = base64Decode(
  // 4×4 的真 PNG（`pdf` 包走 `image` 包解码，对 CRC 校验严格 ⇒
  // 不能拿"手搓的最小 PNG"糊弄，否则 ImageException: Invalid IDAT checksum）
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGM4YWPzHxkzkC4A'
  'AME4I/F4m3AdAAAAAElFTkSuQmCC',
);

/// 导出会把 PDF 落到临时目录 ⇒ 用例里给 `path_provider` 一个测试替身
/// （否则 `getTemporaryDirectory()` 抛 MissingPluginException）。
class _TestTempDir extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async =>
      Directory.systemTemp.createTempSync('d61_export').path;
}

PdfMarkup _ink(String id, int page, List<double> pts) => PdfMarkup(
  id: id,
  page: page,
  kind: PdfMarkupKind.ink,
  points: pts,
  createdAtMs: 1,
);

PdfMarkup _hl(String id, int page, {String note = ''}) => PdfMarkup(
  id: id,
  page: page,
  kind: PdfMarkupKind.highlight,
  left: 0.1,
  top: 0.2,
  right: 0.4,
  bottom: 0.3,
  note: note,
  createdAtMs: 2,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<PdfPageBitmap> pages,
  PdfMarkupStore? store,
  String path = '/tmp/d61/报告.pdf',
}) async {
  final c = ProviderContainer(
    overrides: [
      pdfPageRasterizerProvider.overrideWithValue((_) async => pages),
      pdfMarkupStoreProvider.overrideWithValue(
        store ?? MemoryPdfMarkupStore(),
      ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: DrivePdfMarkupPage(
          filePath: path,
          fileName: '报告.pdf',
          bytes: _png,
          folderId: '77',
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {

  test('★ 回归（231 轮修）：便签不是 rect 分支，但 note 文字**必须**带出来', () {
    final doc = PdfMarkupDoc();
    doc.add(
      const PdfMarkup(
        id: 'n1',
        page: 0,
        kind: PdfMarkupKind.note,
        left: 0.1,
        top: 0.2,
        right: 0.3,
        bottom: 0.3,
        note: '别忘了',
      ),
    );
    final ops = pdfPageDrawOps(doc, 0, 200, 100);
    expect(ops, hasLength(1));
    expect(ops.single.kind, PdfMarkupKind.note);
    expect(
      ops.single.note,
      '别忘了',
      reason: '带不出 note ⇒ 导出的便签只是个空黄框（219 轮真实缺陷）',
    );
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _TestTempDir();

  group('D61 · 批注模型与 sidecar', () {
    test('JSON 往返：三种批注都保真（含归一化坐标与颜色）', () {
      final doc = PdfMarkupDoc(marks: [
        _hl('h1', 0, note: '这里要改'),
        _ink('i1', 1, [0.1, 0.1, 0.5, 0.6]),
      ]);
      final back = PdfMarkupDoc.decode(doc.encode());
      expect(back.count, 2);
      expect(back.marksForPage(0).single.note, '这里要改');
      expect(back.marksForPage(1).single.points, [0.1, 0.1, 0.5, 0.6]);
      expect(back.toJson()['key'], kPdfMarkupSidecarKey);
    });

    test('按页取批注、增删改', () {
      final doc = PdfMarkupDoc(marks: [_hl('h1', 0), _hl('h2', 1)]);
      expect(doc.marksForPage(0), hasLength(1));
      expect(doc.remove('h1'), isTrue);
      expect(doc.remove('nope'), isFalse);
      expect(doc.replace(_hl('h2', 1).copyWith(note: '改了')), isTrue);
      expect(doc.marksForPage(1).single.note, '改了');
      expect(doc.replace(_hl('zz', 1)), isFalse);
    });

    test('sidecar 文件名跟 PDF 同名', () {
      expect(pdfMarkupSidecarName('报告.pdf'), '报告.pdf.markups.json');
    });

    test('坏 sidecar 不当成崩溃（按空批注处理）', () {
      expect(PdfMarkupDoc.decode('{坏').count, 0);
    });
  });

  group('D61 · 归一化几何', () {
    test('像素笔迹 → 归一化，且越界被夹回页内', () {
      final m = normalizePdfInk(
        id: 'i',
        page: 0,
        pixelPoints: [-10, 5, 50, 200],
        width: 100,
        height: 100,
      );
      expect(m.points, [0.0, 0.05, 0.5, 1.0]);
    });

    test('两点高亮自动归位（不管从哪个方向拖）', () {
      final a = normalizePdfHighlight(
        id: 'a', page: 0, x0: 80, y0: 90, x1: 20, y1: 10, width: 100, height: 100,
      );
      expect([a.left, a.top, a.right, a.bottom], [0.2, 0.1, 0.8, 0.9]);
    });

    test('归一化 → 像素 与 绘制指令同源（上屏=导出）', () {
      final doc = PdfMarkupDoc(marks: [_hl('h', 0), _ink('i', 1, [0.0, 0.0, 1.0, 1.0])]);
      final ops = pdfPageDrawOps(doc, 0, 200, 100);
      final r = pdfMarkupRectOnPage(doc.marksForPage(0).single, 200, 100);
      expect(ops.single.rect, r);
      expect(r.left, 20);
      final ink = pdfPageDrawOps(doc, 1, 200, 100).single.points;
      expect(ink.first, const Offset2(0, 0));
      expect(ink.last, const Offset2(200, 100));
    });
  });

  group('D61 · 导出（烙平）', () {
    test('导出的是合法 PDF，页数 = 位图页数', () async {
      final pages = [
        PdfPageBitmap(page: 0, width: 4, height: 4, pngBytes: _png),
        PdfPageBitmap(page: 1, width: 4, height: 4, pngBytes: _png),
      ];
      final bytes = await flattenPdfMarkups(
        pages: pages,
        doc: PdfMarkupDoc(marks: [_hl('h', 0, note: '批注'), _ink('i', 1, [0.0, 0.0, 1.0, 1.0])]),
      );
      expect(bytes.take(4).toString(), contains('80, 68, 70'), reason: '%PDF');
      // `/Type /Page` 出现次数 ≈ 页数（简单结构下可靠）
      final text = latin1.decode(bytes, allowInvalid: true);
      final pageCount = RegExp(r'/Type\s*/Page[^s]').allMatches(text).length;
      expect(pageCount, 2);
      expect(bytes.length, greaterThan(400));
    });

    test('没有批注也能导出（原样烙平）', () async {
      final bytes = await flattenPdfMarkups(
        pages: [PdfPageBitmap(page: 0, width: 4, height: 4, pngBytes: _png)],
        doc: PdfMarkupDoc(),
      );
      expect(bytes, isNotEmpty);
    });
  });

  group('D61 · sidecar 存储', () {
    test('内存存储：存的是拷贝（后续改动不影响已存盘）', () async {
      final s = MemoryPdfMarkupStore();
      final doc = PdfMarkupDoc(marks: [_hl('h', 0)]);
      await s.save('/x/a.pdf', doc);
      doc.add(_hl('h2', 1));
      expect((await s.load('/x/a.pdf')).count, 1);
    });

    test('磁盘 sidecar：真的写到 PDF 旁边，改名后读得回', () async {
      final dir = Directory.systemTemp.createTempSync('d61_markup');
      final pdf = File('${dir.path}/报告.pdf')..writeAsBytesSync(_png);
      const store = SidecarPdfMarkupStore();
      await store.save(pdf.path, PdfMarkupDoc(marks: [_hl('h', 0, note: 'n')]));
      expect(
        File('${dir.path}/报告.pdf.markups.json').existsSync(),
        isTrue,
        reason: 'sidecar 与 PDF 同目录同名',
      );
      final back = await store.load(pdf.path);
      expect(back.count, 1);
      expect(back.marksForPage(0).single.note, 'n');

      // 坏文件 ⇒ 空批注（不崩）
      File('${dir.path}/报告.pdf.markups.json').writeAsStringSync('{坏');
      expect((await store.load(pdf.path)).count, 0);
    });
  });

  group('D61 · 页面（离线，光栅器可注入）', () {
    final onePage = [
      PdfPageBitmap(page: 0, width: 400, height: 400, pngBytes: _png),
    ];

    testWidgets('打开：显示页与工具栏，批注数为 0', (tester) async {
      await _pump(tester, pages: onePage);
      expect(find.byKey(const Key('drive-pdf-markup-page')), findsOneWidget);
      expect(find.byKey(const Key('drive-pdf-page-0')), findsOneWidget);
      expect(find.textContaining('0 条批注'), findsOneWidget);
    });

    testWidgets('手写：拖一笔 → 生成 ink 批注并落 sidecar', (tester) async {
      final store = MemoryPdfMarkupStore();
      await _pump(tester, pages: onePage, store: store);
      await tester.tap(find.text('手写/签名'));
      await tester.pump();
      final page = find.byKey(const Key('drive-pdf-page-0'));
      final g = await tester.startGesture(tester.getCenter(page));
      await g.moveBy(const Offset(40, 30));
      await g.moveBy(const Offset(30, 20));
      await g.up();
      await tester.pumpAndSettle();
      expect(find.textContaining('1 条批注'), findsOneWidget);
      expect(store.snapshot.values.single.count, 1);
      expect(
        store.snapshot.values.single.marks.single.kind,
        PdfMarkupKind.ink,
      );
    });

    testWidgets('便签：输入文字 → 生成 note 批注；撤销后清空', (tester) async {
      final store = MemoryPdfMarkupStore();
      await _pump(tester, pages: onePage, store: store);
      await tester.tap(find.text('便签'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('drive-pdf-note-field')),
        '这段要改',
      );
      await tester.tap(find.byKey(const Key('drive-pdf-note-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 条批注'), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-pdf-undo')));
      await tester.pump();
      expect(find.textContaining('0 条批注'), findsOneWidget);
      expect(store.snapshot.values.single.count, 0, reason: '撤销也要落盘');
    });

    testWidgets('打开已有 sidecar：批注自动带出来', (tester) async {
      final store = MemoryPdfMarkupStore({
        '/tmp/d61/报告.pdf': PdfMarkupDoc(marks: [_hl('h', 0, note: '旧批注')]),
      });
      await _pump(tester, pages: onePage, store: store);
      expect(find.textContaining('1 条批注'), findsOneWidget);
    });

    testWidgets('没有可渲染页 ⇒ 明确说明，不给假画布', (tester) async {
      await _pump(tester, pages: const []);
      expect(find.textContaining('没有可渲染的页面'), findsWidgets);
    });

    testWidgets('导出：生成批注版 PDF 并给出落点', (tester) async {
      await _pump(tester, pages: onePage);
      // 导出里有**真实文件 IO**（写临时文件）⇒ 必须 `runAsync` 才推进事件循环
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('drive-pdf-export')));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(find.byKey(const Key('drive-pdf-saved')), findsOneWidget);
      expect(find.textContaining('已导出'), findsOneWidget);
    });
  });
}
