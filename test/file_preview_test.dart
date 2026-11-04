// 文件预览页（P0.1）的离线测试。
//
// 关注三件事：**分流对不对**（哪种类型用哪种预览）、**文本只读开头**
// （真的带了 `Range`，不是嘴上说说）、**打不开时说人话**（不白屏、不崩）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart'
    show AppTextZh;
import 'package:synhub/src/core/media/thumb_cache.dart';
import 'package:synhub/src/core/ui/hud_widgets.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_pdf_view.dart';
import 'package:synhub/src/core/media/zoom_stage.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 一份合法的极小 PDF（%PDF-1.4 + 一页空内容 + xref/trailer），够 PDFium 打开。
final _pdf = utf8.encode('''
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj
xref
0 4
trailer<</Size 4/Root 1 0 R>>
startxref
0
%%EOF
''');

const _pdfEntry = FileEntryDto(
  name: '手册.pdf',
  path: '/home/手册.pdf',
  isDir: false,
  size: 2048,
  mtime: 1758100000,
);

const _fsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.Download': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

FileEntryDto _entry(String name, {int size = 1024, bool isDir = false}) =>
    FileEntryDto(
      name: name,
      path: '/home/$name',
      isDir: isDir,
      size: size,
      mtime: 1758100000,
    );

/// 挂预览页（不依赖真实会话装配：只覆盖 fileApiProvider）
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  FileEntryDto entry, {
  List<int>? bytes,
  Map<String, int> failures = const {},
  List<FileEntryDto> siblings = const [],
  ThumbCache? thumbCache,
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._fsTable});
  t.failures.addAll(failures);
  if (bytes != null) t.downloadBytes = bytes;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());

  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
      if (thumbCache != null) thumbCacheProvider.overrideWithValue(thumbCache),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: FilePreviewPage(entry: entry, siblings: siblings),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: container);
}

void main() {
  group('DA169：图片手势提示不许冲出屏幕', () {
    // ★ r532：真机亮色下英文提示 "... · pinch to zoom" 有一截被屏幕右边缘裁掉，
    // 而且**没有省略号**（`Positioned` 只给 left/bottom ⇒ 文本宽度无界，
    // `ellipsis` 永远不触发）。判据取几何：提示文本的右边界必须在屏内。
    testWidgets('提示条宽度受约束（右边界在屏内，且不报溢出）', (tester) async {
      await _pump(tester, _entry('hint.png'), bytes: _png);
      // 按**组件**找，不按文案找：用例默认 locale 是中文（`app_localizations_zh`），
      // 写死英文串会一条都找不到（第一版就是这么红的）。
      final hint = find.byWidgetPredicate(
        (w) => w is TelemetryLabel && w.maxLines == 2,
      );
      expect(hint, findsOneWidget);
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final rect = tester.getRect(hint);
      expect(rect.right, lessThanOrEqualTo(size.width - 8),
          reason: 'DA169：提示文本冲出屏幕右边缘（无界宽度 ⇒ 裁字且无省略号）');
      expect(tester.takeException(), isNull);

      // ★ 上面那条几何断言在本用例环境里**不具区分力**（实测：去掉 `right` 也绿 ——
      // 用例是中文 locale、800 宽，中文提示本来就短，挤不出屏幕）。
      // 真正会红的是这条**源码契约**：提示的 `Positioned` 必须同时给 left 和 right。
      final src = File(
        'lib/src/features/files/file_preview_page.dart',
      ).readAsStringSync();
      final i = src.indexOf('fileImageGestureHint');
      expect(i, greaterThan(0));
      final block = src.substring(i - 700, i + 300);
      expect(block.contains('right: Gap.md'), isTrue,
          reason: 'DA169：提示条必须给 right 约束，否则宽度无界 ⇒ 真机英文被裁');
      expect(block.contains('maxLines: 2'), isTrue,
          reason: 'DA169：长句提示要允许 2 行');
    });
  });

  group('同级文件左右滑动（手势）', () {
    testWidgets('图片：左滑到下一张、右滑回上一张，标题里的计数跟着变', (tester) async {
      final a = _entry('a.png');
      final b = _entry('b.png');
      final c = _entry('c.png');
      await _pump(tester, b, bytes: _png, siblings: [a, b, c]);
      expect(find.text('b.png'), findsOneWidget);
      expect(find.textContaining('2/3'), findsOneWidget);

      final pager = find.byKey(const Key('preview-file-pager'));
      await tester.fling(pager, const Offset(-600, 0), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('c.png'), findsOneWidget);
      expect(find.textContaining('3/3'), findsOneWidget);

      await tester.fling(pager, const Offset(600, 0), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('b.png'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('PDF：同级 PDF 之间也能滑（不用退出重进）', (tester) async {
      final one = _entry('一.pdf', size: 2048);
      final two = _entry('二.pdf', size: 2048);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._fsTable});
      t.downloadBytes = _pdf;
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fileApiProvider.overrideWithValue(FileStationApi(api)),
          filePdfViewerProvider.overrideWithValue(
            (context, e, bytes) => Center(child: Text('PDF:${e.name}')),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: FilePreviewPage(entry: one, siblings: [one, two]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('PDF:一.pdf'), findsOneWidget);
      expect(find.textContaining('1/2'), findsOneWidget);

      await tester.fling(
        find.byKey(const Key('preview-file-pager')),
        const Offset(-600, 0),
        1200,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('PDF:二.pdf'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('电子书不参与"翻文件"：它自己要用左右滑翻章（不出现文件分页）', (tester) async {
      final book = _entry('书.epub', size: 4096);
      final text = _entry('note.txt');
      await _pump(tester, book, bytes: _png, siblings: [text, book]);
      expect(find.byKey(const Key('preview-file-pager')), findsNothing);
    });

    testWidgets('单个文件（没有同级）不套分页容器', (tester) async {
      await _pump(tester, _entry('only.png'), bytes: _png);
      expect(find.byKey(const Key('preview-file-pager')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('PDF 内嵌（P0.1 尾巴）', () {
    testWidgets('PDF 走内嵌渲染器：先鉴权取字节，再交给渲染器', (tester) async {
      late Uint8List got;
      final entry = _entry('手册.pdf', size: 2048);
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._fsTable});
      t.downloadBytes = _pdf;
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final db = ChatDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fileApiProvider.overrideWithValue(FileStationApi(api)),
          // PDFium 在单测里加载不了 → 注入假渲染器，只验"选对了路 + 字节对了"
          filePdfViewerProvider.overrideWithValue((context, e, bytes) {
            got = bytes;
            return const Center(child: Text('FAKE-PDF-VIEWER'));
          }),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), home: FilePreviewPage(entry: entry)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('FAKE-PDF-VIEWER'), findsOneWidget);
      expect(got.length, _pdf.length);
      // 字节必须走带鉴权的下载接口（`_sid` 在 URL 里），不是裸 HTTP
      expect(t.downloads.single, contains('_sid='));
      // 路径是 JSON 数组编码（`path=["/home/手册.pdf"]`）→ 百分号编码后是 %5B%22…
      expect(t.downloads.single, contains('path=%5B%22%2Fhome%2F'));
    });

    testWidgets('取不到字节 → 说人话 + 可重试（不白屏）', (tester) async {
      final container = ProviderContainer(overrides: []);
      addTearDown(container.dispose);
      // 直接测舞台在错误态的表现
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._fsTable});
      t.failures['SYNO.FileStation.Download'] = 408;
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fileApiProvider.overrideWithValue(FileStationApi(api)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: FilePdfStage(entry: _pdfEntry)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('打不开这个 PDF'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('类型分流（纯函数）', () {
    test('图片/文本/音频/视频/PDF/Office/压缩包各归各家', () {
      expect(filePreviewKind(_entry('a.png')), FilePreviewKind.image);
      expect(filePreviewKind(_entry('a.heic')), FilePreviewKind.image);
      // 本批起 .txt/.md/.rtf/.docx/.odt 都走内嵌阅读器（能出目录/进度/搜索/TTS）
      expect(filePreviewKind(_entry('notes.md')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.txt')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('main.dart')), FilePreviewKind.text);
      expect(filePreviewKind(_entry('a.mp3')), FilePreviewKind.audio);
      expect(filePreviewKind(_entry('a.mkv')), FilePreviewKind.video);
      expect(filePreviewKind(_entry('a.pdf')), FilePreviewKind.pdf);
      expect(filePreviewKind(_entry('a.docx')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.odt')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.rtf')), FilePreviewKind.book);
      // ★ 第 67 轮 D62：`.xlsx` 改走内嵌网格
expect(filePreviewKind(_entry('a.xlsx')), FilePreviewKind.officeSheet);
      // ★ 215 轮 D62：`.pptx` 改走内置只读查看器（按页抽结构）；`.ppt` 仍在 office
      expect(filePreviewKind(_entry('a.pptx')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.ppt')), FilePreviewKind.office);
      // Synology Office 自家三种格式也要走 Office 只读（安卓上没有别的东西能打开）
      expect(filePreviewKind(_entry('Untitled.odoc')), FilePreviewKind.office);
      expect(
        filePreviewKind(_entry('Untitled.osheet')),
        FilePreviewKind.office,
      );
      expect(
        filePreviewKind(_entry('Untitled.oslides')),
        FilePreviewKind.office,
      );
      expect(filePreviewKind(_entry('a.7z')), FilePreviewKind.archive);
      expect(filePreviewKind(_entry('a.unknownext')), FilePreviewKind.other);
      expect(
        filePreviewKind(_entry('dir', isDir: true)),
        FilePreviewKind.other,
      );
    });

    test('内嵌与否：图片/文本/音频/PDF 可以，视频/Office 交给系统', () {
      expect(canPreviewInline(_entry('a.png')), isTrue);
      expect(canPreviewInline(_entry('a.txt')), isTrue);
      expect(canPreviewInline(_entry('a.mp3')), isTrue);
      // P0.1 尾巴：PDF 现在内嵌翻页（官方 App 也是在内看）
      expect(canPreviewInline(_entry('a.pdf')), isTrue);
      expect(canPreviewInline(_entry('a.mp4')), isFalse);
      expect(canPreviewInline(_entry('a.docx')), isTrue);
      // ★ 第 67 轮 D62：`.xlsx` 现在**可以**内嵌预览了
      expect(canPreviewInline(_entry('a.xlsx')), isTrue);
      // 超大 PDF 还是交系统（不要为了"能内嵌"把 200MB 读进内存）
      expect(canPreviewInline(_entry('big.pdf', size: 41 << 20)), isFalse);
    });

    test('超大图片不内嵌（别把几千万像素读进内存）', () {
      expect(canPreviewInline(_entry('big.png', size: 41 << 20)), isFalse);
      expect(canPreviewInline(_entry('ok.png', size: 5 << 20)), isTrue);
    });
  });

  group('文本头部解码', () {
    test('去过 BOM、容错非法 UTF-8、按长度判断截断', () {
      final bom = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('hello')];
      expect(decodeTextHead(bom).text, 'hello');
      expect(decodeTextHead(bom).truncated, isFalse);

      // 半个汉字（被 Range 切断）不该抛异常
      final broken = [...utf8.encode('中文'), 0xE4, 0xB8];
      final decoded = decodeTextHead(broken);
      expect(decoded.text, startsWith('中文'));
      expect(decoded.truncated, isFalse);

      // 请求满 64KB → 视为可能被截断
      final big = List<int>.filled(kTextHeadBytes, 0x61);
      expect(decodeTextHead(big).truncated, isTrue);
    });
  });

  group('预览页', () {
    testWidgets('文本：只读开头一段（真的带 Range），并提示被截断', (tester) async {
      final body = utf8.encode('line1\nline2\nline3\n');
      final boot = await _pump(tester, _entry('log.log'), bytes: body);

      expect(find.textContaining('line1'), findsOneWidget);
      expect(find.textContaining('line2'), findsOneWidget);
      // 小文件不该提示截断
      expect(find.textContaining('只显示开头'), findsNothing);

      final dl = boot.t.downloads.single;
      expect(dl, contains('SYNO.FileStation.Download'));
      expect(dl, contains('mode=download'));
      expect(boot.t.ranges, isNotEmpty, reason: '文本预览必须带 Range');
      expect(boot.t.ranges.single, endsWith('#$kTextHeadBytes'));
    });

    testWidgets('文本：超过 64KB 时提示只显示开头', (tester) async {
      // 假服务端按 maxBytes 截断，正好等于上限 → 页面认为还有更多
      final body = List<int>.filled(kTextHeadBytes + 5000, 0x61);
      await _pump(tester, _entry('huge.log', size: 5 << 20), bytes: body);
      expect(find.textContaining('只显示开头 64 KB'), findsOneWidget);
    });

    testWidgets('图片：原图 + 可缩放（InteractiveViewer）', (tester) async {
      final boot = await _pump(tester, _entry('a.png'), bytes: _png);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      expect(boot.t.ranges, isEmpty, reason: '图片要整张，不该带 Range');
    });

    testWidgets('图片：双击放大后可缩放，放大时不再横滑翻页（再双击复位）', (tester) async {
      final a = _entry('a.png');
      final b = _entry('b.png');
      // ⚠️ siblings 里必须**包含 entry 自己**，否则 `_swipeable` 为空、根本不套分页容器
      await _pump(tester, a, bytes: _png, siblings: [a, b]);
      expect(find.byType(ZoomStage), findsWidgets);

      PageView pager() =>
          tester.widget<PageView>(find.byKey(const Key('preview-file-pager')));
      expect(pager().physics, isA<PageScrollPhysics>());

      final center = tester.getCenter(find.byType(ZoomStage).first);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(
        pager().physics,
        isA<NeverScrollableScrollPhysics>(),
        reason: '放大后横滑归平移',
      );

      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(pager().physics, isA<PageScrollPhysics>(), reason: '复位后恢复翻页');
    });

    testWidgets('图片：大图不内嵌，改为引导下载/外部打开', (tester) async {
      final boot = await _pump(
        tester,
        _entry('big.png', size: 60 << 20),
        bytes: _png,
      );
      expect(find.textContaining('太大了不内嵌显示'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(boot.t.downloads, isEmpty, reason: '不该偷偷把大图拉下来');
    });

    testWidgets('Office（NAS 源、没有 Drive link id）：不内嵌，讲清原因 + 给两个按钮', (
      tester,
    ) async {
      // ★ 第 67 轮 D62：`.xlsx` 已改走**内嵌网格**；215 轮起 `.pptx` 也走内置
      // 查看器 ⇒ 这里换成仍在 `office` 那条路上的**老二进制** `.ppt`。
      await _pump(tester, _entry('report.ppt'));
      // NAS 目录里的文档不在 Drive 索引里 → `Office.File.extract` 抽不了正文，
      // 页面要**说清这一点**并给系统打开的出路（有 link id 的路径见
      // test/office_preview_test.dart）
      expect(find.textContaining('把文件放进「我的 Drive」'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('超大 PDF：仍交系统应用（不为"能内嵌"把 200MB 读进内存）', (tester) async {
      final boot = await _pump(tester, _entry('big.pdf', size: 60 << 20));
      expect(find.textContaining('PDF 交给系统'), findsOneWidget);
      expect(find.byType(FilePdfStage), findsNothing);
      expect(boot.t.downloads, isEmpty, reason: '太大不该偷偷拉下来');
    });

    testWidgets('打不开（服务端 404/HTML）→ 说人话 + 可以重试，不白屏', (tester) async {
      final boot = await _pump(
        tester,
        _entry('gone.png'),
        failures: {'SYNO.FileStation.Download': 404},
      );
      expect(find.text('打不开这个文件'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(boot.t.downloads, isNotEmpty);
    });

    testWidgets('空文件 → 明确说"这个文件是空的"', (tester) async {
      await _pump(tester, _entry('empty.txt'), bytes: const []);
      expect(find.text('这个文件是空的'), findsOneWidget);
    });
  });

  // HEIC/HEIF 收敛：`filePreviewKind` 把它声明成"可预览图片"，但 Flutter 的
  // `Image.memory` 解不了 HEIC → 预览必须改走**服务端缩略图**（回 JPEG），
  // 而不是把原图整份下载下来喂解码器。
  group('HEIC 内嵌预览（收敛）', () {
    final heic = Uint8List.fromList([
      0x00, 0x00, 0x00, 0x18, //
      0x66, 0x74, 0x79, 0x70, // 'ftyp'
      0x68, 0x65, 0x69, 0x63, // 'heic'
      0x00, 0x00, 0x00, 0x00,
      0x6D, 0x69, 0x66, 0x31, // 'mif1'
    ]);

    testWidgets('HEIC：走服务端缩略图（Thumb），不下载原图字节', (tester) async {
      var thumbAsked = 0;
      final boot = await _pump(
        tester,
        _entry('photo.heic', size: 2048),
        thumbCache: ThumbCache(
          loader: (path, size) async {
            thumbAsked++;
            expect(path, '/home/photo.heic');
            return _png; // 服务端 `Thumb.get` 回的是转好的 JPEG
          },
        ),
      );
      expect(thumbAsked, 1, reason: 'HEIC 必须走服务端缩略图这条路');
      expect(
        boot.t.downloads.any((u) => u.contains('SYNO.FileStation.Download')),
        isFalse,
        reason: '绝不能把 HEIC 原图整份下载下来喂 Image.memory',
      );
      expect(find.byType(Image), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('HEIC：服务端给不出可用图 → 明确占位 + 一句话原因（不假装解码成功）', (tester) async {
      final boot = await _pump(
        tester,
        _entry('raw.heic', size: 2048),
        // 服务端原样回 HEIC 字节（与"回 HTML 错误页"同类：都不是能喂解码器的图）
        thumbCache: ThumbCache(loader: (path, size) async => heic),
      );
      expect(
        find.byKey(const Key('file-thumb-server-required')),
        findsOneWidget,
      );
      expect(find.text(AppTextZh().fileImageDecodeFailed), findsOneWidget);
      expect(
        boot.t.downloads.any((u) => u.contains('SYNO.FileStation.Download')),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
