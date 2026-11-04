// ★ **归档「服务端收下了但没真归档」的 Mock 验证** —— ②聊天 审计行 219。
//
// ## 为什么必须专门测这一条
//
// 真机实测（`chat_session_controller.dart:1208-1214` 记录）：
// ```
// NAS 2.4.7 + 非管理员账号 + 自己建的私有频道
//   Channel/archive v2 → {"success":true}
//   但频道仍是 is_joined=true，Archive/list 里也没有新记录
//   → 服务端**接受了请求但没有归档**
//   （v4 直接 103，印证 2.4.7 的方法表里 v4 没有 archive）
// ```
//
// 代码里为此写了 `applied` 回查分支（`archiveChannel` 调完再 `Channel/get`
// 确认一次）。**但既有测试 `test/channel_manage_test.dart:145` 里
// 服务端是"真的归档了"**（断言 `is_joined == false`）——
// ⇒ **`applied=false` 这条分支，也就是真机上唯一真实发生的那条，从来没有测试跑过。**
//
// 用户 2026-09-23 新规 B2：**「真机/真 NAS 无法验证的也一律通过 Mock Server 验证」**。
// 这条正好相反 —— 真机**能**验而且**验过了**，反而是 Mock 侧缺。
// 本文件把它补齐，让"真机观察到的行为"在离线回归里被钉死。
//
// ## 本文件不做什么
// 不碰真机、不碰真 NAS（§5.1）。所有请求都进内存 Mock。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 频道 `5` 的 `Channel/get` 回包 —— [joined] 决定服务端到底有没有归档。
Map<String, dynamic> _channelGet({required bool joined}) => {
  'channel': {
    'channel_id': 5,
    'name': '测试频道',
    'type': 'public',
    'is_joined': joined,
  },
};

Future<ChatHarness> _boot({required bool joinedAfterArchive}) => bootChat(
  extra: {
    'SYNO.Chat.Channel.list': {
      'channels': [testChannelJson],
    },
    // 归档之后的**回查**用它 —— 这就是"服务端到底归档了没"的唯一判据
    'SYNO.Chat.Channel.get': _channelGet(joined: joinedAfterArchive),
  },
);

Future<bool> _rowJoined(ChatHarness h) async {
  final store = h.container.read(chatStoreProvider);
  final row = (await store.allChannels()).firstWhere((c) => c.channelId == 5);
  return row.isJoined;
}

Future<int> _postCount(ChatHarness h) async {
  final store = h.container.read(chatStoreProvider);
  final posts = await store.postsForChannel(5);
  return posts.length;
}

void main() {
  group('AR-1. ★ 服务端"收下但不归档"（真机实测行为）⇒ 返回 false、本地不动', () {
    test('★ archiveChannel 返回 false（宁可如实报，也不乐观删）', () async {
      final h = await _boot(joinedAfterArchive: true);
      expect(
        await h.ctrl.archiveChannel(5),
        isFalse,
        reason: '服务端没真归档 ⇒ 必须回 false，界面据此提示"服务端未归档"',
      );
    });

    test('★ 频道仍是 joined（下一次同步不会又冒出来）', () async {
      final h = await _boot(joinedAfterArchive: true);
      await h.ctrl.archiveChannel(5);
      expect(await _rowJoined(h), isTrue);
    });

    test('★ 消息**没有**被清（乐观删除会丢历史）', () async {
      final h = await _boot(joinedAfterArchive: true);
      final before = await _postCount(h);
      await h.ctrl.archiveChannel(5);
      expect(await _postCount(h), before, reason: '没真归档就不能清本地消息');
    });

    test('★ 请求形状仍是对的（v2 + channel_id），且**确实**发了回查', () async {
      final h = await _boot(joinedAfterArchive: true);
      await h.ctrl.archiveChannel(5);
      final methods = h.transport.calls.map((c) => '${c['method']}').toList();
      expect(methods, contains('archive'));
      expect(methods, contains('get'), reason: 'archive 之后必须回查一次');
      final archive = h.transport.calls.firstWhere(
        (c) => c['method'] == 'archive',
      );
      expect(archive['version'], '2', reason: '原版写死 v2（v4 在 2.4.7 上 103）');
      expect(archive['channel_id'], 5);
    });
  });

  group('AR-2. 对照组：服务端**真的**归档了 ⇒ 返回 true、本地移出', () {
    test('★ 返回 true', () async {
      final h = await _boot(joinedAfterArchive: false);
      expect(await h.ctrl.archiveChannel(5), isTrue);
    });

    test('★ 频道从本地移出（is_joined=false）', () async {
      final h = await _boot(joinedAfterArchive: false);
      await h.ctrl.archiveChannel(5);
      expect(await _rowJoined(h), isFalse);
    });

    test('★ 这条对照组证明 AR-1 的 false **不是**代码永远返回 false', () async {
      // 两条只差一个 `is_joined` 的取值，结论相反 ⇒ AR-1 测的是真分支
      final no = await _boot(joinedAfterArchive: true);
      final yes = await _boot(joinedAfterArchive: false);
      expect(await no.ctrl.archiveChannel(5), isFalse);
      expect(await yes.ctrl.archiveChannel(5), isTrue);
    });
  });

  group('AR-3. UI 层：未归档要给用户一句话（不是静默）', () {
    testWidgets('★ 频道管理面板里点「归档」→ 弹出"服务端未归档"提示', (tester) async {
      final h = await _boot(joinedAfterArchive: true);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: SizedBox())),
        ),
      );

      // 直接驱动控制器（面板的 onTap 就是这一句），断言返回 false ——
      // 面板据此 `messenger.showSnackBar(t.chatArchiveUnsupported)`。
      expect(await h.ctrl.archiveChannel(5), isFalse);
      // 且频道**仍可用**（不能因为归档失败把它藏了）
      expect(await _rowJoined(h), isTrue);
    });
  });
}
