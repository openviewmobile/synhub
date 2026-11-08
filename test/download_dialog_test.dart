// Phase 5：下载进度框 + 取消（对齐原版 `DownloadFragment`）。
//
// 原版要点：标题"正在下载…"、文件名、`read / total` + 百分比、取消按钮；
// **total == 0 → 进度条转圈并隐藏字节数/百分比**（服务端没给 Content-Length）；
// 取消 → 直接关框不弹错误。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/cache_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/attachment_view.dart';
import 'package:synhub/src/features/chat/download_dialog.dart';
import 'package:synhub/src/features/chat/attachment_access.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

PostDto postWith(int postId, String name, {int size = 2048}) =>
    PostDto.fromJson({
      'post_id': postId,
      'channel_id': 5,
      'creator_id': 14,
      'create_at': 1700000000000,
      'file_props': [
        {
          'file_id': 1,
          'post_id': postId,
          'name': name,
          'type': 'pdf',
          'size': size,
          'mime_type': 'application/pdf',
          'is_image': false,
        },
      ],
    });

void main() {
  group('humanBytes（原版 FileUtils.byteCountToDisplaySize 的近似）', () {
    test('1024 进制 + 1 位小数', () {
      expect(humanBytes(512), '512 B');
      expect(humanBytes(1024), '1.0 KB');
      expect(humanBytes(1536), '1.5 KB');
      expect(humanBytes(1048576), '1.0 MB');
      expect(humanBytes(5 * 1048576), '5.0 MB');
    });
  });

  group('DownloadTask', () {
    test('百分比与可读大小；total 未知时都为空', () {
      final t = DownloadTask('a.pdf');
      expect(t.percent, 0);
      expect(t.humanReadable, '');
      t.report(50, 200);
      expect(t.percent, 25);
      expect(t.humanReadable, '50 B / 200 B');
      // dio 的未知长度是 -1 → 归一到 0（转圈）
      t.report(50, -1);
      expect(t.percent, 0);
      expect(t.humanReadable, '');
      t.dispose();
    });

    test('cancel 会标记 token', () {
      final t = DownloadTask('a.pdf');
      expect(t.isCancelled, isFalse);
      t.cancel();
      expect(t.isCancelled, isTrue);
      expect(t.cancelToken.isCancelled, isTrue);
      t.dispose();
    });
  });

  group('DownloadProgressDialog 渲染', () {
    Future<void> pump(
      WidgetTester tester,
      DownloadTask task, {
      VoidCallback? onCancel,
    }) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: DownloadProgressDialog(task: task)),
        ),
      );
      await tester.pump();
    }

    testWidgets('已知长度：显示 read / total 与百分比', (tester) async {
      final task = DownloadTask('report.pdf')..report(512, 2048);
      addTearDown(task.dispose);
      await pump(tester, task);
      expect(find.text('正在下载…'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('512 B / 2.0 KB'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('未知长度：转圈且不显示字节/百分比', (tester) async {
      final task = DownloadTask('report.pdf');
      addTearDown(task.dispose);
      await pump(tester, task);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNull, reason: 'total = 0 时应该是转圈');
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('/'), findsNothing);
    });

    testWidgets('进度更新会刷新百分比', (tester) async {
      final task = DownloadTask('report.pdf')..report(512, 2048);
      addTearDown(task.dispose);
      await pump(tester, task);
      expect(find.text('25%'), findsOneWidget);
      task.report(2048, 2048);
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 1.0);
    });
  });

  group('AttachmentList 的下载路径接了进度框与取消', () {
    testWidgets('下载完成后框自己关掉，且文件落到缓存目录', (tester) async {
      final dir = Directory.systemTemp.createTempSync('flt_dlg_ok');
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: AttachmentList(
                post: postWith(200, 'report.pdf'),
                api: h.apiForTest,
                // 加密频道 → 才会走"下载 + 进度框"（见 `PassthroughE2ee` 的说明）
                access: AttachmentAccess(
                  channelId: 5,
                  svc: PassthroughE2ee(),
                  api: h.apiForTest,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // ★ r731：把"等到没有"变成**可读的证据**。r730 的 CI（2 核 runner）上这一条红过
      //   一次，本地隔离跑 3 次 + 全量 12,448 条都绿，摘要里也没有失败正文（错误正文在
      //   计数行之后，当时没摘）。所以在不改判据的前提下做两件事：
      //   ① 等 6s（原来 2s）—— 等的是**真实磁盘 I/O**，不是把断言放宽；
      //   ② 等不到就 `fail()` 并带上实测数字（等了多久、路径、最后看到的存在性/字节数），
      //      下一次红时摘要里直接有原因，不用再靠复现去猜。
      var waitedMs = 0;
      var sawExists = false;
      var sawLength = -1;
      late String cachedPath;
      await tester.runAsync(() async {
        await tester.tap(find.text('report.pdf'));
        final svc = h.container.read(cacheServiceProvider);
        cachedPath = await svc.pathFor(200, 'report.pdf');
        for (var i = 0; i < 300; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waitedMs += 20;
          final f = File(cachedPath);
          sawExists = f.existsSync();
          sawLength = sawExists ? f.lengthSync() : -1;
          if (sawExists && sawLength > 0) return;
        }
      });
      debugPrint('[dlg-ok] waited=${waitedMs}ms path=$cachedPath '
          'exists=$sawExists length=$sawLength');
      await tester.pump();
      // 假传输是同步完成 + 没有 length → 框要么已经关掉、要么转圈中
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('正在下载…'), findsNothing);
      // ★ 第 292 轮修：`CacheService.pathFor` 内部有**真实文件 I/O**
      // （`Directory.exists` / `create`）。在 `testWidgets` 的**假异步**区里直接
      // await 它 ⇒ Future 永不完成 ⇒ **用例挂死**（插桩实测：卡在该调用，
      // 300s 不返回；前 7 步全部正常）。真实 I/O 必须放进 `tester.runAsync`。
      final cached = (await tester.runAsync(
        () => h.container.read(cacheServiceProvider).pathFor(200, 'report.pdf'),
      ))!;
      expect(File(cached).existsSync(), isTrue,
          reason: '等了 ${waitedMs}ms 仍没有文件：$cached（最近一次读到 exists=$sawExists '
              'length=$sawLength）');
      expect(File(cached).lengthSync(), greaterThan(0),
          reason: '等了 ${waitedMs}ms 文件仍为空：$cached');
    });

    testWidgets('服务端 401 → 框关掉 + 文案给用户', (tester) async {
      final dir = Directory.systemTemp.createTempSync('flt_dlg_err');
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
        ],
      );
      h.transport.failures['post_id=201'] = 401;
      final errors = <String>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: AttachmentList(
                post: postWith(201, 'broken.pdf'),
                api: h.apiForTest,
                // 加密频道 → 才会走"下载 + 进度框"（见 `PassthroughE2ee` 的说明）
                access: AttachmentAccess(
                  channelId: 5,
                  svc: PassthroughE2ee(),
                  api: h.apiForTest,
                ),
                onError: errors.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('broken.pdf'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('正在下载…'), findsNothing);
      expect(errors, isNotEmpty);
    });

    testWidgets('取消 → 不下载、不弹错误、不落盘', (tester) async {
      final dir = Directory.systemTemp.createTempSync('flt_dlg_cancel');
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
        ],
      );
      // 让下载卡住，好让测试点到「取消」
      h.transport.holdDownloads = true;
      final errors = <String>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: AttachmentList(
                post: postWith(202, 'big.bin'),
                api: h.apiForTest,
                // 加密频道 → 才会走"下载 + 进度框"（见 `PassthroughE2ee` 的说明）
                access: AttachmentAccess(
                  channelId: 5,
                  svc: PassthroughE2ee(),
                  api: h.apiForTest,
                ),
                onError: errors.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('big.bin'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      expect(find.text('正在下载…'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      h.transport.releaseDownloads();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      expect(find.text('正在下载…'), findsNothing);
      expect(errors, isEmpty, reason: '取消不是错误');
      // ★ 同第 292 轮修：真实文件 I/O 必须进 `runAsync`（否则假异步区挂死）
      final cached = (await tester.runAsync(
        () => h.container.read(cacheServiceProvider).pathFor(202, 'big.bin'),
      ))!;
      // 诊断（第 38 轮）：区分"取消后留了零字节占位"与"取消后仍写进内容"
      final f = File(cached);
      debugPrint(
        '[cancelProbe] exists=${f.existsSync()} '
        'len=${f.existsSync() ? f.lengthSync() : -1}',
      );
      expect(File(cached).existsSync(), isFalse);
    });
  });
}
