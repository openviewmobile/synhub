// 回归：附件异步链路在 widget 卸载后**不得**再碰 `ref` / `context`。
//
// 背景（已定性的跨用例异步泄漏）：`AttachmentList._open` 在下载/串流这类长
// 异步之后仍调用 `ref.read(cacheServiceProvider)`。全量跑测试时前一个用例的
// widget 已经卸载，回调才完成，`ref.read`（riverpod 3 的 `_assertNotDisposed`）
// 抛 `StateError`，且这个 Future 是没人 await 的（`onTap: () => _open(...)`），
// 于是错误逃逸到正在跑的下一个用例头上 —— 表现就是"随机挂名"的 flake。
//
// 收敛要点（避免"真实时钟竞态窗口"）：
//   * **直接调用 `InkWell.onTap`**（不经手势），"点没点中"不再看时钟；
//   * 缓存目录先预热，使"进入闸门之前"全是 microtask；
//   * 闸门是显式 `Completer`，卸载/放行的先后由测试代码决定；
//   * 完成信号是测试替身里的 `Completer`（touch/enforceLimit、opener），
//     等待是"交替 flush microtask / 给真实 I/O 时间，直到信号触发"的**条件等待**
//     （有上限、条件达成即走），不是"睡固定时长再看"。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/cache_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/attachment_view.dart';

import 'support/chat_harness.dart';
import 'dart:typed_data';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/chat/attachment_access.dart';

PostDto filePost(int postId, String name, {int size = 2048}) =>
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
          'type': name.contains('.') ? name.split('.').last : 'bin',
          'size': size,
          'mime_type': name.endsWith('.mp4') ? 'video/mp4' : 'application/pdf',
          'is_image': false,
        },
      ],
    });

/// 一个可以把 [AttachmentList] 从树上换掉（卸载）的宿主。
class _Host extends StatelessWidget {
  const _Host({
    required this.show,
    required this.post,
    required this.api,
    this.access,
  });

  final ValueNotifier<bool> show;
  final PostDto post;
  final ChatApi? api;
  final AttachmentAccess? access;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(theme: AppTheme.dark(), 
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: show,
          builder: (_, visible, _) => visible
              ? AttachmentList(post: post, api: api, access: access)
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// `pathFor` 可选地被闸门挡住；`touch` / `enforceLimit` 是"异步续体跑完"的
/// 确定性信号（`_open` 尾部只有走到这里才算没在 await 之后碰 `ref`）。
class _SignalingCacheService extends CacheService {
  _SignalingCacheService({super.root, this.gate});

  final Future<void> Function()? gate;
  final bookkeepingDone = Completer<void>();
  int pathForCalls = 0;

  @override
  Future<String> pathFor(
    int postId,
    String fileName, {
    bool thumbnail = false,
  }) async {
    pathForCalls++;
    final g = gate;
    if (g != null) await g();
    return super.pathFor(postId, fileName, thumbnail: thumbnail);
  }

  @override
  Future<void> touch(String path) async {
    await super.touch(path);
    if (!bookkeepingDone.isCompleted) bookkeepingDone.complete();
  }

  @override
  Future<int> enforceLimit(
    int limitBytes, {
    Set<String> protect = const {},
  }) async {
    final freed = await super.enforceLimit(limitBytes, protect: protect);
    if (!bookkeepingDone.isCompleted) bookkeepingDone.complete();
    return freed;
  }
}

/// 直通式 E2EE 桩：文件名原样、字节原样。
///
/// 为什么需要它：§2.0.8④ 之后**普通文件**在 `_open` 里被"内置阅读器"分支
/// （`attachment_view.dart:387-400`）提前 `return`，**根本不走下载**；想测
/// "下载进行中卸载"这条链，只能让附件变成**加密频道**（`access != null`
/// ⇒ `encrypted = true` ⇒ 跳过 3.5 落到第 4 分支"下载后打开"）。
class _PassthroughE2ee implements E2eeService {
  @override
  String? tryDecryptFileName(int channelId, String encodedName) => encodedName;

  @override
  Uint8List? tryDecryptFileBytes(int channelId, List<int> raw) =>
      raw is Uint8List ? raw : Uint8List.fromList(raw);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 直接触发文件名气泡的 `onTap`（不走手势）。
void _tapFile(WidgetTester tester, String label) {
  final inkWell = tester.widget<InkWell>(
    find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first,
  );
  inkWell.onTap!();
}

/// 交替 flush microtask（`pump`）与给真实 I/O 时间（`runAsync`），直到 [done]。
/// 真实文件 I/O 只能在 `runAsync` 窗口里推进；`pump` 用来 flush 假时钟 zone 里
/// 排队的续体。条件达成即返回，**上限只是在"用例本应失败"时兜底**。
Future<void> _settle(
  WidgetTester tester,
  bool Function() done, {
  int maxRounds = 300,
  Duration realStep = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < maxRounds && !done(); i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(realStep));
  }
  await tester.pump();
}

void main() {
  group('附件异步链路：卸载后完成不得再碰 ref/context', () {
    testWidgets('下载进行中卸载 → 下载完成后无异常、缓存账仍记上', (tester) async {
      final dir = Directory.systemTemp.createTempSync('flt_unmount_dl');
      final cache = _SignalingCacheService(root: dir);
      final h = await bootChat(
        moreOverrides: [cacheServiceProvider.overrideWithValue(cache)],
      );
      // 加密频道 → 强制走下载分支（见 `_PassthroughE2ee` 的说明）
      final access = AttachmentAccess(
        channelId: 5,
        svc: _PassthroughE2ee(),
        api: h.apiForTest,
      );
      // 预热缓存目录（唯一一次真实 I/O）：之后 `_open` 走到下载闸门全是 microtask。
      final cached = (await tester.runAsync(() async {
        await cache.directory();
        return cache.pathFor(700, 'leak.pdf');
      }))!;
      final show = ValueNotifier<bool>(true);
      addTearDown(show.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: _Host(
            show: show,
            post: filePost(700, 'leak.pdf'),
            api: h.apiForTest,
            access: access,
          ),
        ),
      );
      await tester.pump();

      // 让下载悬在半空：`_open` 已经取完 cachePath，正卡在 openAttachment 的 await。
      h.transport.holdDownloads = true;
      _tapFile(tester, 'leak.pdf');
      // `_open` 是 async：它**先 push 下载框**，框建好之后才发起下载 ⇒
      // 只 pump 一帧时下载还没出门（§2.0.9「多推几帧」，别用 pumpAndSettle：
      // 下载框带常驻进度动画，settle 永远不返回）。推到"下载已发出"为止。
      for (var i = 0; i < 5 && h.transport.downloads.isEmpty; i++) {
        await tester.pump();
      }
      expect(
        h.transport.downloads,
        isNotEmpty,
        reason: '下载已发出并卡在闸门上（= _open 正停在 openAttachment 的 await）',
      );

      // 卸载（保留 Navigator，让下载框的 finally 能正常关框）。
      show.value = false;
      await tester.pump();
      expect(find.byType(AttachmentList), findsNothing, reason: 'widget 已卸载');

      // 现在才放行：续体在卸载之后运行 → 原实现在 405 行 ref.read 处抛异常。
      h.transport.releaseDownloads();
      await _settle(tester, () => cache.bookkeepingDone.isCompleted);

      expect(
        tester.takeException(),
        isNull,
        reason: '卸载后异步续体不得抛 ref-after-dispose / setState after dispose',
      );
      expect(
        cache.bookkeepingDone.isCompleted,
        isTrue,
        reason: '缓存账（touch + enforceLimit）仍应记上',
      );
      expect(File(cached).existsSync(), isTrue, reason: '卸载不该阻止已经完成的下载落盘');
    });

    testWidgets('串流路径卡在缓存查询时卸载 → 续体无异常，opener 用的是取好的引用', (tester) async {
      final dir = Directory.systemTemp.createTempSync('flt_unmount_stream');
      final gate = Completer<void>();
      final cache = _SignalingCacheService(root: dir, gate: () => gate.future);
      final streamed = <String>[];
      final opened = Completer<void>();
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(cache),
          mediaStreamOpenerProvider.overrideWithValue((url, mime) async {
            streamed.add(url);
            if (!opened.isCompleted) opened.complete();
            return true;
          }),
        ],
      );
      // 预热目录：让放行闸门后的 `super.pathFor` 不再需要真实 I/O。
      await tester.runAsync(() => cache.directory());
      final show = ValueNotifier<bool>(true);
      addTearDown(show.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: _Host(
            show: show,
            post: filePost(702, 'clip.mp4'),
            api: h.apiForTest,
          ),
        ),
      );
      await tester.pump();

      // 普通频道的 mp4 → 走串流分支；branch 1 的缓存查询进入即卡住。
      _tapFile(tester, 'clip.mp4');
      await tester.pump();
      expect(cache.pathForCalls, 1, reason: '_open 应已进入缓存查询并卡住');

      show.value = false;
      await tester.pump();
      expect(find.byType(AttachmentList), findsNothing, reason: 'widget 已卸载');

      // 放行缓存查询：续体继续走到 branch 3 的 ref.read(mediaStreamOpenerProvider)
      //（原实现在卸载后读 → 抛异常）。
      gate.complete();
      await _settle(tester, () => opened.isCompleted);

      expect(
        tester.takeException(),
        isNull,
        reason: '卸载后不得再 ref.read / 用已卸载的 context 弹框',
      );
      expect(
        streamed,
        hasLength(1),
        reason: 'opener 应在 await 之前取好，卸载后仍能正确完成串流决策',
      );
    });
  });
}
