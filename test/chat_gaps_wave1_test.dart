// 聊天模块「第一波可做缺口」的离线验证（2026-09-22 批次）：
//   1. 气泡内联已读回执（108 + 142）：按 `read_users.length` 渲「已读 / 已读 N 人」，
//      能力关闭 / 接口失败 / 无已读者 → 优雅隐藏（不报错、不占位）；
//   2. composer 独立「@」按钮（160）：复用既有 autocomplete 候选面板；
//   3. `Channel.Named / set` 请求形状契约（211）；
//   4. 话题置顶 `Post/stick` v2 正向 + 失败降级（139）。
//
// 全部是离线（FakeTransport / 假 socket），没有真机/真 NAS 证据。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/post_actions_sheet.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 造一个频道：一条别人的 + 一条**我发的最后一条**（回执只画在它上面）。
Future<ChatHarness> _bootOwnPost({
  Map<String, dynamic>? readStatus,
  Map<String, dynamic>? settings,
  bool failReadStatus = false,
}) async {
  final h = await bootChat(
    extra: {
      'SYNO.Chat.Admin.Setting.get': ?settings,
      'SYNO.Chat.Post.get_read_status': ?readStatus,
    },
  );
  if (failReadStatus) {
    h.transport.failures['SYNO.Chat.Post.get_read_status'] = 103;
  }
  final store = h.container.read(chatStoreProvider);
  await store.upsertPosts(const [
    PostDto(
      postId: 60,
      channelId: 5,
      creatorId: 3,
      message: '别人的消息',
      createAt: 1000,
    ),
    PostDto(
      postId: 61,
      channelId: 5,
      creatorId: 14,
      message: '我发的消息',
      createAt: 2000,
    ),
  ]);
  return h;
}

Map<String, dynamic> _lastCall(FakeTransport t, String apiDotMethod) =>
    t.calls.lastWhere(
      (c) => '${c['api']}.${c['method']}' == apiDotMethod,
      orElse: () => const {},
    );

/// 等一个条件成立（`_loadServerSettings` 是 unawaited 的，能力位要等它落地）
Future<void> _waitFor(bool Function() cond) async {
  for (var i = 0; i < 100; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('气泡已读回执（108 + 142）', () {
    testWidgets('有已读者（部分读完）→ 「已读 N 人」', (tester) async {
      final h = await _bootOwnPost(
        readStatus: {
          'read_users': [4, 6],
          'unread_users': [8],
        },
      );
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      expect(find.text('我发的消息'), findsOneWidget);
      expect(find.text('已读 2 人'), findsOneWidget);
      // 部分读完不是 ✓✓，是普通 ✓
      expect(find.byIcon(Icons.done_all), findsNothing);
    });

    testWidgets('已读者 + 全部读完 → 「已读」+ ✓✓', (tester) async {
      final h = await _bootOwnPost(
        readStatus: {
          'read_users': [4, 6],
          'unread_users': <int>[],
        },
      );
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      expect(find.text('已读'), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsOneWidget);
      // 全部读完时不该再画「已读 N 人」（避免两个说法并存）
      expect(find.text('已读 2 人'), findsNothing);
    });

    testWidgets('无已读者 → 不画已读标记，只留普通 ✓', (tester) async {
      final h = await _bootOwnPost(
        readStatus: {
          'read_users': <int>[],
          'unread_users': [8],
        },
      );
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      expect(find.textContaining('已读'), findsNothing);
      expect(find.byIcon(Icons.done_all), findsNothing);
      expect(find.byIcon(Icons.done), findsOneWidget);
      // 页面本身没坏
      expect(find.text('我发的消息'), findsOneWidget);
    });

    testWidgets('接口失败 → 优雅隐藏（无标记、无报错、不空白）', (tester) async {
      final h = await _bootOwnPost(
        readStatus: {
          'read_users': [4, 6],
          'unread_users': <int>[],
        },
        failReadStatus: true,
      );
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      expect(find.textContaining('已读'), findsNothing);
      expect(find.textContaining('查不到'), findsNothing);
      expect(find.text('我发的消息'), findsOneWidget);
      // 仍然有"已发送"的 ✓ —— 不是空白占位
      expect(find.byIcon(Icons.done), findsOneWidget);

      // 卸掉页面让 provider 自动 dispose（Riverpod 3 对失败的 FutureProvider
      // 会排一个重试 Timer，页面还在时它不会自己消失，测试框架会判"Timer 未清"）
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('能力关闭（allow_read_status=false）→ 隐藏，且根本不请求接口', (tester) async {
      final h = await _bootOwnPost(
        readStatus: {
          'read_users': [4, 6],
          'unread_users': <int>[],
        },
        settings: {'allow_read_status': false},
      );
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      expect(find.textContaining('已读'), findsNothing);
      expect(find.byIcon(Icons.done), findsOneWidget);
      expect(
        h.transport.calls.any(
          (c) =>
              '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.get_read_status',
        ),
        isFalse,
        reason: '能力关掉时不该再打已读名单接口',
      );
    });
  });

  group('composer「@」按钮（160）', () {
    testWidgets('点「@」→ 插入 @ 并弹出既有候选面板（@真人 / @channel / @here）', (tester) async {
      final h = await bootChat(
        extra: {
          // 只有 me 的默认表补一个真人；成员在频道里排前面
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 14,
                'username': 'me',
                'type': 'human',
                'status': 'online',
              },
              {
                'user_id': 3,
                'username': 'bob',
                'type': 'human',
                'status': 'online',
              },
            ],
          },
        },
      );
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      await tester.tap(find.byTooltip('提及某人'));
      await _settle(tester);

      // 复用 autocomplete：候选标题就是 `AutocompleteItem.label`
      expect(find.text('@bob'), findsOneWidget);
      expect(find.text('@channel'), findsOneWidget);
      expect(find.text('@here'), findsOneWidget);
      // `@` 已经插进输入框（触发词）
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '@',
      );
    });

    testWidgets('点候选 → 把触发词替换成 `@username `', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 14,
                'username': 'me',
                'type': 'human',
                'status': 'online',
              },
              {
                'user_id': 3,
                'username': 'bob',
                'type': 'human',
                'status': 'online',
              },
            ],
          },
        },
      );
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      await tester.tap(find.byTooltip('提及某人'));
      await _settle(tester);
      await tester.tap(find.text('@bob'));
      await _settle(tester);

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '@bob ',
      );
    });
  });

  group('Channel.Named/set 请求形状（211）', () {
    test('v1 + channel_id / name / purpose；只改一项时不带另一项', () async {
      final h = await bootChat();
      await h.apiForTest.setNamedChannel(9, name: '新名字', purpose: '新主题');

      final call = _lastCall(h.transport, 'SYNO.Chat.Channel.Named.set');
      expect('${call['version']}', '1');
      expect('${call['channel_id']}', '9');
      expect(call['name'], '新名字');
      expect(call['purpose'], '新主题');

      await h.apiForTest.setNamedChannel(9, name: '只改名');
      final call2 = _lastCall(h.transport, 'SYNO.Chat.Channel.Named.set');
      expect(call2['name'], '只改名');
      expect(call2.containsKey('purpose'), isFalse, reason: 'null 参数不发');
      expect('${call2['channel_id']}', '9');
    });

    test('两项都为 null → 一个请求都不发', () async {
      final h = await bootChat();
      final before = h.transport.calls.length;
      await h.apiForTest.setNamedChannel(9);
      expect(h.transport.calls.length, before);
    });
  });

  group('话题置顶 stick（139）', () {
    test('正向：stick / unstick 走 v2 并落本地 is_sticky（真机不可验）', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts(const [
        PostDto(postId: 70, channelId: 5, message: 'm', createAt: 1),
      ]);

      expect(await h.ctrl.setStick(5, 70, stick: true), isTrue);
      expect((await store.postById(5, 70))!.isSticky, isTrue);
      final stick = _lastCall(h.transport, 'SYNO.Chat.Post.stick');
      expect('${stick['version']}', '2');
      expect('${stick['post_id']}', '70');

      expect(await h.ctrl.setStick(5, 70, stick: false), isTrue);
      expect((await store.postById(5, 70))!.isSticky, isFalse);
      final unstick = _lastCall(h.transport, 'SYNO.Chat.Post.unstick');
      expect('${unstick['version']}', '2');
      expect('${unstick['post_id']}', '70');
    });

    test('降级：407 → 返回 false、本地不动、置位 stickUnsupported（入口隐藏）', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.stick'] = 407;
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts(const [
        PostDto(postId: 71, channelId: 5, message: 'm', createAt: 1),
      ]);

      expect(await h.ctrl.setStick(5, 71, stick: true), isFalse);
      expect((await store.postById(5, 71))!.isSticky, isFalse);
      expect(
        h.container.read(chatSessionControllerProvider).stickUnsupported,
        isTrue,
        reason: '407 = 话题置顶没开',
      );
      // 置位后再点也不该再打接口（UI 已隐藏，控制器也短路）
      final callsBefore = h.transport.calls
          .where((c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.stick')
          .length;
      expect(await h.ctrl.setStick(5, 71, stick: true), isFalse);
      final callsAfter = h.transport.calls
          .where((c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.stick')
          .length;
      expect(callsAfter, callsBefore, reason: '已知不支持后不再发请求');
    });

    test('其它错误码不触发 stickUnsupported（只是失败）', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.stick'] = 403;
      await h.container.read(chatStoreProvider).upsertPosts(const [
        PostDto(postId: 72, channelId: 5, message: 'm', createAt: 1),
      ]);

      expect(await h.ctrl.setStick(5, 72, stick: true), isFalse);
      expect(
        h.container.read(chatSessionControllerProvider).stickUnsupported,
        isFalse,
      );
    });

    test('能力关闭（Post < v2）→ 不发请求，直接 false', () async {
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.Post': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      await _waitFor(
        () => !h.container.read(chatSessionControllerProvider).supportsStick,
      );
      expect(
        h.container.read(chatSessionControllerProvider).supportsStick,
        isFalse,
        reason: 'Post maxVersion=1 < stick 需要的 v2',
      );
      await h.container.read(chatStoreProvider).upsertPosts(const [
        PostDto(postId: 73, channelId: 5, message: 'm', createAt: 1),
      ]);
      final before = h.transport.calls.length;
      expect(await h.ctrl.setStick(5, 73, stick: true), isFalse);
      expect(h.transport.calls.length, before, reason: '能力关闭时不发请求');
    });

    Future<void> openSheet(
      WidgetTester tester,
      PostDto post, {
      bool allowStick = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showPostActionsSheet(
                    context,
                    post: post,
                    mine: true,
                    canWrite: true,
                    allowStick: allowStick,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('长按菜单：is_sticky（话题）与 last_pin_at（消息）两套状态分开', (tester) async {
      await openSheet(
        tester,
        const PostDto(
          postId: 1,
          channelId: 5,
          creatorId: 14,
          message: 'm',
          createAt: 1,
          isSticky: true,
        ),
      );
      expect(find.text('取消话题内置顶'), findsOneWidget);
      expect(
        find.text('置顶'),
        findsOneWidget,
        reason: 'is_sticky 不影响消息置顶动作（看 last_pin_at）',
      );
    });

    testWidgets('长按菜单：last_pin_at>0 → 消息置顶显示「取消置顶」', (tester) async {
      await openSheet(
        tester,
        const PostDto(
          postId: 2,
          channelId: 5,
          creatorId: 14,
          message: 'm',
          createAt: 1,
          lastPinAt: 12345,
        ),
      );
      expect(find.text('取消置顶'), findsOneWidget);
      expect(find.text('话题内置顶'), findsOneWidget, reason: 'is_sticky=false');
    });

    testWidgets('长按菜单：能力关闭 / 已 407 → 只剩消息置顶', (tester) async {
      await openSheet(
        tester,
        const PostDto(
          postId: 3,
          channelId: 5,
          creatorId: 14,
          message: 'm',
          createAt: 1,
        ),
        allowStick: false,
      );
      expect(find.text('话题内置顶'), findsNothing);
      expect(find.text('取消话题内置顶'), findsNothing);
      expect(find.text('置顶'), findsOneWidget);
    });
  });
}
