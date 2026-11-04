// Phase 5：另存到「下载」/ 分享（原版 `DownloadFragment` 的 option 1、2）。
//
// 原版对照：
//   * 「下载」入口 = 消息长按面板，条件是 `!isVote && file != null && size > 0`；
//     `FileUtil.moveFileToPublicDownloadDir` + `DownloadManager.addCompletedDownload`；
//   * 「分享」入口 = 图片查看器（`ImagePagerFragment.Callbacks.onShare`）→
//     `ACTION_SEND` + FileProvider；
//   * 两者都先跑同一个下载框（可取消），完成后再交给系统。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/cache_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/file_actions.dart';
import 'package:synhub/src/features/chat/post_actions_sheet.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

PostDto filePost(
  int postId,
  String name, {
  int size = 1024,
  bool vote = false,
}) => PostDto.fromJson({
  'post_id': postId,
  'channel_id': 5,
  'creator_id': 14,
  'create_at': 1700000000000,
  if (vote)
    'props': {
      'vote': {'vote_id': 1, 'question': 'q', 'choices': []},
    },
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

/// 记录调用的假桥
class FakeBridge extends FileActionBridge {
  FakeBridge({this.saveUri = 'content://downloads/1', this.shareOk = true});

  final String? saveUri;
  final bool shareOk;
  final List<Map<String, String>> saves = [];
  final List<Map<String, String>> shares = [];
  final List<String> deleted = [];

  @override
  Future<String?> saveToDownloads({
    required String path,
    required String name,
    required String mime,
  }) async {
    saves.add({'path': path, 'name': name, 'mime': mime});
    return File(path).existsSync() ? saveUri : null;
  }

  @override
  Future<bool> share({
    required String path,
    required String name,
    required String mime,
  }) async {
    shares.add({'path': path, 'name': name, 'mime': mime});
    return shareOk;
  }

  @override
  Future<bool> deleteSaved(String uri) async {
    deleted.add(uri);
    return true;
  }
}

void main() {
  group('长按面板的「下载」入口', () {
    Future<void> pumpSheet(
      WidgetTester tester,
      PostDto post, {
      required bool allowDownload,
    }) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPostActionsSheet(
                  context,
                  post: post,
                  mine: false,
                  canWrite: true,
                  allowDownload: allowDownload,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('有非空附件 → 显示「下载」，位置在「编辑」之前', (tester) async {
      await pumpSheet(tester, filePost(310, 'a.pdf'), allowDownload: true);
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('编辑'), findsNothing, reason: '不是自己发的消息');
    });

    testWidgets('allowDownload = false → 不显示', (tester) async {
      await pumpSheet(tester, filePost(311, 'a.pdf'), allowDownload: false);
      expect(find.text('下载'), findsNothing);
    });

    test('isAllowDownload 的判定（原版 isAllowDownload）', () {
      expect(isAllowDownload(filePost(1, 'a.pdf')), isTrue);
      expect(isAllowDownload(filePost(2, 'a.pdf', vote: true)), isFalse);
      expect(isAllowDownload(filePost(3, 'a.pdf', size: 0)), isFalse);
      expect(
        isAllowDownload(
          PostDto.fromJson({
            'post_id': 4,
            'channel_id': 5,
            'creator_id': 14,
            'create_at': 1,
          }),
        ),
        isFalse,
      );
    });
  });

  group('saveAttachmentToDownloads / shareAttachment 的完整链路', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('flt_actions'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<BuildContext> host(WidgetTester tester, ProviderContainer c) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Builder(
                builder: (x) {
                  ctx = x;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      return ctx;
    }

    testWidgets('保存：下载后调用桥，路径=缓存路径、名字/MIME 正确', (tester) async {
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
        ],
      );
      final bridge = FakeBridge();
      final ctx = await host(tester, h.container);
      // pathFor 里有真实文件 IO，必须在 runAsync 里跑
      final path = (await tester.runAsync(
        () => CacheService(root: dir).pathFor(320, 'report.pdf'),
      ))!;

      final outcome = await tester.runAsync(
        () => saveAttachmentToDownloads(
          ctx,
          api: h.apiForTest,
          post: filePost(320, 'report.pdf'),
          access: null,
          cachePath: path,
          name: 'report.pdf',
          bridge: bridge,
        ),
      );
      expect(outcome!.ok, isTrue);
      expect(outcome.uri, 'content://downloads/1');
      expect(bridge.saves.single['path'], path);
      expect(bridge.saves.single['name'], 'report.pdf');
      expect(bridge.saves.single['mime'], 'application/pdf');
      expect(File(path).existsSync(), isTrue, reason: '应该先落缓存');
    });

    testWidgets('分享：下载后调用桥；没有应用能接 → 返回文案', (tester) async {
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
        ],
      );
      final bridge = FakeBridge(shareOk: false);
      final ctx = await host(tester, h.container);
      final path = (await tester.runAsync(
        () => CacheService(root: dir).pathFor(321, 'clip.mp4'),
      ))!;

      final err = await tester.runAsync(
        () => shareAttachment(
          ctx,
          api: h.apiForTest,
          post: filePost(321, 'clip.mp4'),
          access: null,
          cachePath: path,
          name: 'clip.mp4',
          bridge: bridge,
        ),
      );
      expect(err, '没有能接收分享的应用');
      expect(bridge.shares.single['mime'], 'video/mp4');
    });

    testWidgets('下载失败 → 不调用桥，返回错误文案', (tester) async {
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
        ],
      );
      h.transport.failures['post_id=322'] = 500;
      final bridge = FakeBridge();
      final ctx = await host(tester, h.container);
      final path = (await tester.runAsync(
        () => CacheService(root: dir).pathFor(322, 'bad.pdf'),
      ))!;

      final outcome = await tester.runAsync(
        () => saveAttachmentToDownloads(
          ctx,
          api: h.apiForTest,
          post: filePost(322, 'bad.pdf'),
          access: null,
          cachePath: path,
          name: 'bad.pdf',
          bridge: bridge,
        ),
      );
      expect(outcome!.ok, isFalse);
      expect(outcome.error, isNotNull);
      expect(bridge.saves, isEmpty);
    });

    testWidgets('取消下载 → cancelled 且不调用桥', (tester) async {
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
        ],
      );
      h.transport.holdDownloads = true;
      final bridge = FakeBridge();
      final ctx = await host(tester, h.container);
      final path = (await tester.runAsync(
        () => CacheService(root: dir).pathFor(323, 'big.pdf'),
      ))!;

      late Future<SaveOutcome> future;
      // 下载被卡住 → 框会一直开着，好让测试点「取消」
      await tester.runAsync(() async {
        future = saveAttachmentToDownloads(
          ctx,
          api: h.apiForTest,
          post: filePost(323, 'big.pdf'),
          access: null,
          cachePath: path,
          name: 'big.pdf',
          bridge: bridge,
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('正在下载…'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      h.transport.releaseDownloads();
      final outcome = await tester.runAsync(() => future);
      expect(outcome!.cancelled, isTrue);
      expect(bridge.saves, isEmpty);
      expect(File(path).existsSync(), isFalse);
    });

    testWidgets('没有附件 → 直接报错', (tester) async {
      final h = await bootChat();
      final ctx = await host(tester, h.container);
      final post = PostDto.fromJson({
        'post_id': 330,
        'channel_id': 5,
        'creator_id': 14,
        'create_at': 1700000000000,
      });
      final outcome = await saveAttachmentToDownloads(
        ctx,
        api: h.apiForTest,
        post: post,
        access: null,
        cachePath: '${dir.path}/x',
        name: 'x',
        bridge: FakeBridge(),
      );
      expect(outcome.error, '这条消息没有附件');
    });
  });
}
