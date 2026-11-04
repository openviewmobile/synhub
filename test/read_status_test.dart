// 已读/未读名单（Phase 9 收尾）：`SYNO.Chat.Post / get_read_status` v6 +
// 长按面板入口门控 + 名单页渲染。
//
// 反编译依据（`ActionSheetConfiguration`）：入口条件是
//   `isAllowShowReadStatus = prefs.allowReadStatus() && post.user().userId == 我`
// 另外频道整体禁用（`mIsChannelDisable`）时不显示。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/server_settings_dto.dart';
import 'package:synhub/src/features/chat/post_actions_sheet.dart';
import 'package:synhub/src/features/chat/read_status_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

const _post = {
  'post_id': 4294967300,
  'channel_id': 5,
  'creator_id': 14,
  'create_at': 2000,
  'type': 'normal',
  'message': '我发的消息',
  'props': {'encrypted': false},
};

void main() {
  group('get_read_status', () {
    test('v6 + post_id，解析 read_users / unread_users', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.get_read_status': {
            'read_users': [4, 6],
            'unread_users': [8],
          },
        },
      );
      final r = await h.apiForTest.fetchReadStatus(4294967300);
      expect(r.readUsers, [4, 6]);
      expect(r.unreadUsers, [8]);
      final call = h.transport.calls.lastWhere(
        (c) => c['method'] == 'get_read_status',
      );
      // 表单值都是字符串（服务端也是这么收的）
      expect('${call['version']}', '6');
      expect('${call['post_id']}', '4294967300');
      expect(call['api'], 'SYNO.Chat.Post');
    });

    test('两段缺失时是空名单（老服务器/没人读）', () async {
      final h = await bootChat(
        extra: {'SYNO.Chat.Post.get_read_status': const {}},
      );
      final r = await h.apiForTest.fetchReadStatus(1);
      expect(r.readUsers, isEmpty);
      expect(r.unreadUsers, isEmpty);
    });
  });

  group('长按面板入口', () {
    Future<List<String>> actions(
      WidgetTester tester, {
      required bool mine,
      required bool allowRead,
    }) async {
      final picked = <String>[];
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final a = await showPostActionsSheet(
                      context,
                      post: PostDto.fromJson(_post),
                      mine: mine,
                      canWrite: true,
                      allowReadStatus: allowRead,
                    );
                    if (a != null) picked.add(a.name);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('自己发的 + 服务端允许 → 有「已读成员」「未读成员」', (tester) async {
      await actions(tester, mine: true, allowRead: true);
      expect(find.text('已读成员'), findsOneWidget);
      expect(find.text('未读成员'), findsOneWidget);
    });

    testWidgets('别人的消息 → 没有这两个入口', (tester) async {
      await actions(tester, mine: false, allowRead: true);
      expect(find.text('已读成员'), findsNothing);
      expect(find.text('未读成员'), findsNothing);
    });

    testWidgets('服务端关掉已读回执 → 没有这两个入口', (tester) async {
      await actions(tester, mine: true, allowRead: false);
      expect(find.text('已读成员'), findsNothing);
      expect(find.text('未读成员'), findsNothing);
    });
  });

  group('名单页', () {
    Widget wrap(ProviderContainer c, {bool readUsers = true}) =>
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: ReadStatusPage(postId: 4294967300, readUsers: readUsers),
          ),
        );

    testWidgets('已读名单：渲染成员 + 人数', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.get_read_status': {
            'read_users': [4, 6],
            'unread_users': [8],
          },
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 4,
                'username': 'demo',
                'nickname': 'demo',
                'type': 'human',
              },
              {
                'user_id': 6,
                'username': 'tt',
                'nickname': '婷婷',
                'type': 'human',
              },
              {'user_id': 8, 'username': 'nokey', 'type': 'human'},
            ],
          },
        },
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();
      expect(find.text('已读成员'), findsOneWidget);
      expect(find.text('已读 2 人'), findsOneWidget);
      expect(find.text('婷婷'), findsOneWidget);
      expect(find.text('nokey'), findsNothing);
    });

    testWidgets('未读名单：换另一组', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.get_read_status': {
            'read_users': [4],
            'unread_users': [8],
          },
          'SYNO.Chat.User.list': {
            'users': [
              {'user_id': 4, 'username': 'demo', 'type': 'human'},
              {'user_id': 8, 'username': 'nokey', 'type': 'human'},
            ],
          },
        },
      );
      await tester.pumpWidget(wrap(h.container, readUsers: false));
      await tester.pumpAndSettle();
      expect(find.text('未读成员'), findsOneWidget);
      expect(find.text('未读 1 人'), findsOneWidget);
      expect(find.text('nokey'), findsOneWidget);
      expect(find.text('demo'), findsNothing);
    });

    testWidgets('空名单给明确空状态', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.get_read_status': {
            'read_users': <int>[],
            'unread_users': [8],
          },
        },
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();
      expect(find.text('还没有人读过'), findsOneWidget);
    });

    testWidgets('接口失败 → 有错误提示和重试', (tester) async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.get_read_status'] = 103;
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();
      expect(find.textContaining('查不到已读状态'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('服务端设置门控', () {
    test('allow_read_status 默认开着（老服务器不带这个字段）', () {
      expect(const ServerSettings().allowReadStatus, isTrue);
      expect(
        ServerSettings.fromJson(const {
          'allow_read_status': false,
        }).allowReadStatus,
        isFalse,
      );
      expect(
        const ServerSettings().allowEncryption,
        isTrue,
        reason: '同一套"默认宽松"原则',
      );
    });
  });
}
