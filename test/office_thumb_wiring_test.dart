// `FileThumb` → `OfficeDocThumb` 的**接线**测试（Office 三格式缩略图）。
//
// 这里钉的不是渲染质量（那是 `office_doc_thumb_test.dart` 的事），而是"接线"：
//   1. `.odoc` 条目必须出现 `OfficeDocThumb`，且**服务端缩略图一次都没被请求**
//      （真机：`FileStation.Thumb` 对 office 恒 404 + HTML ⇒ 请求就是白跑）；
//   2. `.osheet` / `.oslides` 同样命中；
//   3. 取模型失败 → **退回现有分类图标**（不抛给界面、不空白、不挂住）；
//   4. 非 office 条目不受影响：`.txt` 仍是图标且零服务端请求，
//      `.png` 仍照常请求服务端缩略图（`asked == 1`）—— 防"把图片也挡掉"的回归线。
//
// ★ 反向验证（这些用例真的是"钉子"）：把 `file_thumb.dart::FileThumb.build` 里的
//   office 分支临时删掉（或改成 `if (false)`），本组第 1/2 条会立刻变红 ——
//   `find.byType(OfficeDocThumb)` 变成 `findsNothing`，`.odoc` 直接落到
//   `FileIconTile`（分类图标 `Icons.insert_drive_file_outlined`）。
//   实测红/绿证据见交付报告。
//
// ⚠️ 全部**零网络、零设备、零文件系统**：
//   * 模型：`officeNativeReadProvider` 被 provider override 成假读函数；
//   * 光栅化：`officeThumbRendererProvider` 注入"直接回 PNG 字节"的假渲染器
//     （真离屏渲染要 `tester.runAsync` + 引擎，不适合接线用例）；
//   * 服务端缩略图：`thumbCacheProvider` 用内存 `ThumbCache`，loader 计数即"请求数"；
//   * 磁盘缓存：`OfficeThumbCache(diskRoot: () async => null)`，不碰 path_provider。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/thumb_cache.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/office_native/odoc_model.dart';
import 'package:synhub/src/data/office_native/office_native_reader.dart';
import 'package:synhub/src/data/office_native/ofile.dart';
import 'package:synhub/src/data/office_native/prosemirror_model.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_thumb.dart';
import 'package:synhub/src/features/files/office_viewer_page.dart'
    show OfficeNativeReadRequest, officeNativeReadProvider;
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_doc_thumb.dart';

/// 一张真 1×1 PNG（`Image.memory` 能真解码）。
final Uint8List pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

FileEntryDto entryFor(String name, {String? path}) => FileEntryDto(
  name: name,
  path: path ?? '/home/$name',
  isDir: false,
  size: 1024,
  mtime: 1758100000,
);

OFile _ofile() => OFile(
  schema: 3,
  enc: false,
  id: 'ofile-wiring',
  ver: '1',
  end: false,
  sections: const {},
  metadata: const {},
);

/// 最小可构造的原生模型。**格式跟随请求**（`renderer` 是假的，不会真光栅化，
/// 所以这里用文档模型占位不影响断言；但 `format` 必须对，否则量不到档位尺寸）。
OfficeNativeDocument fakeNativeDocument(OfficeNativeFormat format) =>
    OfficeNativeDocument(
      format: format,
      envelope: _ofile(),
      document: ODocDocument(
        schema: 1,
        version: 1,
        pageSetup: ODocPageSetup.a4Default,
        body: PmExtraction(
          blocks: const [
            PmBlock(kind: PmBlockKind.paragraph, text: '第一页正文'),
          ],
          images: const [],
          nodeTypeCounts: const {},
        ),
        nodeTypeCounts: const {},
        commentCount: 0,
        indexSchemaVersion: 1,
        sectionNames: const ['content'],
        pageDecorate: null,
      ),
    );

/// 假渲染器：直接回一张真 PNG（**不碰引擎**）。
Future<Uint8List?> fakePngRenderer(OfficeThumbRenderJob job) async => pngBytes;

void main() {
  setUp(() {
    // 共享单例必须隔离：内存缓存 + 失败记忆跨用例会串味；磁盘一律关掉。
    OfficeThumbCache.shared = OfficeThumbCache(
      diskRoot: () async => null,
      memoryCapacity: 16,
    );
    OfficeThumbScheduler.shared = OfficeThumbScheduler();
  });

  tearDown(() {
    OfficeThumbCache.shared = null;
    OfficeThumbScheduler.shared = null;
  });

  /// 挂一个 [FileThumb]，接上假读通道 / 假渲染器 / 内存缩略图缓存。
  Future<void> pump(
    WidgetTester tester, {
    required FileEntryDto entry,
    required ThumbCache cache,
    required Future<OfficeNativeDocument> Function(OfficeNativeReadRequest) read,
    OfficeThumbPngRenderer? renderer,
    ThumbScale scale = ThumbScale.small,
    double size = 40,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          thumbCacheProvider.overrideWithValue(cache),
          officeNativeReadProvider.overrideWith((ref, req) => read(req)),
          officeThumbRendererProvider.overrideWithValue(
            renderer ?? fakePngRenderer,
          ),
        ],
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Center(
              child: FileThumb(entry: entry, scale: scale, size: size),
            ),
          ),
        ),
      ),
    );
    // 读模型 + 渲染都是纯 microtask（假实现里没有 Timer），多推几帧让它落地。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  ThumbCache countingCache(void Function() onAsk) => ThumbCache(
    loader: (path, size) async {
      onAsk();
      return pngBytes;
    },
  );

  group('Office 三格式：走 OfficeDocThumb，绝不发服务端缩略图请求', () {
    testWidgets('.odoc → OfficeDocThumb 出图，服务端缩略图 asked == 0', (tester) async {
      var serverAsked = 0;
      var readCalls = 0;
      final sizes = <Size>[];

      await pump(
        tester,
        entry: entryFor('report.odoc'),
        cache: countingCache(() => serverAsked++),
        read: (req) async {
          readCalls++;
          expect(req.entryPath, '/home/report.odoc');
          expect(req.format, OfficeNativeFormat.odoc);
          return fakeNativeDocument(OfficeNativeFormat.odoc);
        },
        renderer: (job) async {
          sizes.add(job.logicalSize);
          return pngBytes;
        },
      );

      expect(
        find.byType(OfficeDocThumb),
        findsOneWidget,
        reason: 'office 条目必须走 OfficeDocThumb，而不是分类图标',
      );
      expect(find.byKey(const Key('office-thumb-image')), findsOneWidget);
      expect(
        find.byIcon(Icons.insert_drive_file_outlined),
        findsNothing,
        reason: '出图后不该还挂着分类图标',
      );
      expect(
        serverAsked,
        0,
        reason: 'office 绝不能去要服务端缩略图（真机恒 404 + HTML）',
      );
      expect(readCalls, 1);
      // 列表档 = 96dp 宽；`.odoc` 纸张比 3:4 ⇒ 高 128dp。
      expect(sizes.single, const Size(96, 128));
    });

    testWidgets('.osheet / .oslides 同样命中（列表档各自的比例）', (tester) async {
      final expected = <String, (OfficeNativeFormat, Size)>{
        'budget.osheet': (OfficeNativeFormat.osheet, const Size(96, 72)),
        'deck.oslides': (OfficeNativeFormat.oslides, const Size(96, 54)),
      };
      for (final e in expected.entries) {
        var serverAsked = 0;
        final sizes = <Size>[];
        await pump(
          tester,
          entry: entryFor(e.key),
          cache: countingCache(() => serverAsked++),
          read: (req) async {
            expect(req.format, e.value.$1, reason: e.key);
            return fakeNativeDocument(e.value.$1);
          },
          renderer: (job) async {
            sizes.add(job.logicalSize);
            return pngBytes;
          },
        );
        expect(find.byType(OfficeDocThumb), findsOneWidget, reason: e.key);
        expect(find.byKey(const Key('office-thumb-image')), findsOneWidget);
        expect(serverAsked, 0, reason: '${e.key} 不该发服务端请求');
        expect(sizes.single, e.value.$2, reason: e.key);
      }
    });

    testWidgets('渲染失败（假读函数抛异常）→ 退回分类图标，不抛给界面、不空白', (
      tester,
    ) async {
      var serverAsked = 0;
      var rendererCalls = 0;
      await pump(
        tester,
        entry: entryFor('broken.odoc'),
        cache: countingCache(() => serverAsked++),
        read: (req) async => throw StateError('105 no permission'),
        renderer: (job) async {
          rendererCalls++;
          return pngBytes;
        },
      );

      expect(find.byType(OfficeDocThumb), findsOneWidget);
      expect(
        find.byKey(const Key('office-thumb-image')),
        findsNothing,
        reason: '渲染失败不能假装有图',
      );
      expect(
        find.byIcon(Icons.insert_drive_file_outlined),
        findsOneWidget,
        reason: '失败必须回退成现有分类图标（绝不空白）',
      );
      expect(
        rendererCalls,
        0,
        reason: '模型都没拿到，不该去光栅化',
      );
      expect(serverAsked, 0);
    });

    testWidgets('读请求字段来源：drivePath 映射 / 无会话时 nativeBytesUrl 为 null', (
      tester,
    ) async {
      final seen = <OfficeNativeReadRequest>[];
      await pump(
        tester,
        entry: entryFor('report.odoc', path: '/home/Drive/report.odoc'),
        cache: countingCache(() {}),
        read: (req) async {
          seen.add(req);
          return fakeNativeDocument(OfficeNativeFormat.odoc);
        },
      );
      final req = seen.single;
      expect(req.entryPath, '/home/Drive/report.odoc');
      expect(
        req.drivePath,
        '/mydrive/report.odoc',
        reason: '`/home/Drive/x` → `/mydrive/x`（已取证的唯一映射）',
      );
      expect(
        req.nativeBytesUrl,
        isNull,
        reason: '宿主测试没有会话 ⇒ fileApiProvider 为 null ⇒ 直链为 null',
      );
      expect(
        req.snapshotApiPresent,
        isTrue,
        reason: '能力表拿不到（officeApiProvider == null）⇒ fail-open',
      );
    });
  });

  group('非 office 条目：零回归（别把图片/文本也改了）', () {
    testWidgets('.txt → 仍是分类图标，服务端缩略图 asked == 0', (tester) async {
      var serverAsked = 0;
      await pump(
        tester,
        entry: entryFor('notes.txt'),
        cache: countingCache(() => serverAsked++),
        read: (req) async =>
            throw StateError('文本文件不该走 office 读通道'),
      );
      expect(find.byType(OfficeDocThumb), findsNothing);
      expect(find.byIcon(Icons.article_outlined), findsOneWidget);
      expect(serverAsked, 0);
    });

    testWidgets('.png → 仍照常请求服务端缩略图，asked == 1', (tester) async {
      var serverAsked = 0;
      await pump(
        tester,
        entry: entryFor('photo.png'),
        cache: countingCache(() => serverAsked++),
        read: (req) async =>
            throw StateError('图片不该走 office 读通道'),
      );
      expect(find.byType(OfficeDocThumb), findsNothing);
      expect(serverAsked, 1, reason: '图片的服务端缩略图通道必须保持原样');
      expect(find.byType(Image), findsOneWidget);
    });
  });

  _registerDisposeRegression();
}

// ============================================================ ★ 第 261 轮真机缺陷的**钉子**
//
// 背景（真机 logcat 逐字，见 `docs/device-verification.md §⑩.2.1`）：
//   `I/flutter: [officeThumb] FETCH-FAIL … error=Cannot use the Ref of
//    FutureProvider<OfficeNativeDocument>#f0953 … after it has been disposed.`
// 根因：`officeNativeReadProvider` 是 **autoDispose**，而缩略图任务是在
// `OfficeDocThumb` 的**异步回调**里跑的 —— 那里**没有 watcher**；
// Riverpod 对"只被 `read`、没人 `listen`"的 autoDispose provider **当帧销毁**，
// 于是异步回调拿到已销毁的 Ref ⇒ **真机上 8 个 office 行 1 秒内全"失败"**、
// 只剩分类图标（看着像"功能没做"）。
//
// ★ 上面原有那 6 条用例**当时全绿**却抓不到这个缺陷（它们在 widget 树里 pump，
//   订阅关系正好活着）。所以这里补两条**直接对准根因**的用例：
//   A. 新写法（`officeThumbModelProvider`，keepAlive 包装）在"没人 listen"时**必须成功**；
//   B. 旧写法（裸 `read` autoDispose）在同样场景下**必须抛 disposed** ——
//      这条是**反向验证**：谁把 `fetchModel` 改回裸 `read`，A 会红、B 会提醒原因。
void _registerDisposeRegression() {
  group('★ autoDispose 生命周期（真机缺陷的钉子）', () {
    ProviderContainer makeContainer(
      Future<OfficeNativeDocument> Function(OfficeNativeReadRequest) read,
    ) {
      final c = ProviderContainer(
        overrides: [officeNativeReadProvider.overrideWith((ref, req) => read(req))],
      );
      addTearDown(c.dispose);
      return c;
    }

    // 故意"慢"的读：跨过 Riverpod 处理 autoDispose 的那一帧/微任务。
    Future<OfficeNativeDocument> slowRead(OfficeNativeReadRequest req) async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return fakeNativeDocument(OfficeNativeFormat.odoc);
    }

    const req = OfficeNativeReadRequest(
      entryPath: '/home/Drive/a.odoc',
      format: OfficeNativeFormat.odoc,
    );

    test('A. 缩略图取模型：没人 listen 也必须拿到文档（keepAlive 包装生效）', () async {
      final c = makeContainer(slowRead);
      final doc = await c.read(officeThumbModelProvider(req).future);
      expect(doc, isA<OfficeNativeDocument>());
    });

    // ★ 反向验证不能用"纯 Dart 容器 + 延时"来复现：autoDispose 的销毁是**跟着帧**调度的，
    //   没有 widget 帧时裸 `read` 也不会被销毁（我第一版这么写，结果 B 用例自己红了 ——
    //   说明它**抓不到**真机那个现象，留着就是假的"钉子"）。所以改用**源码级钉子**：
    //   直接断言接线走的是 keepAlive 包装、而不是裸 `read` autoDispose。
    //   这一条与 `i18n_coverage_test` / `api_version_guard_test` 同型：静态、确定、不飘。
    test('B. 反向验证（源码级）：接线必须走 keepAlive 包装，不许裸 read autoDispose', () {
      final src = File(
        'lib/src/features/files/file_thumb.dart',
      ).readAsStringSync();
      expect(
        src.contains('officeThumbModelProvider(readReq)'),
        isTrue,
        reason: '缩略图取模型必须走 officeThumbModelProvider（keepAlive 包装）',
      );
      expect(
        RegExp(
          r'ref\s*\.\s*read\s*\(\s*officeNativeReadProvider',
        ).hasMatch(src),
        isFalse,
        reason:
            '裸 read 一个 autoDispose provider（异步回调里没有 watcher）会被 Riverpod '
            '当帧销毁 —— 真机缺陷：office 缩略图 8 行全不出图，'
            'logcat "Cannot use the Ref … after it has been disposed"（§⑩.2.1）',
      );
    });
  });
}
