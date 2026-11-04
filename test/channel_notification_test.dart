// Phase 9：频道通知档位（`SYNO.Chat.Channel.Preference`）离线验证。
//
// 覆盖：API 参数形态（裸值、版本协商、只写 notification_mobile）、
// 响应解析、本地缓存回落、档位候选（加密频道只有 all/none）、
// 通知过滤（none/mention/mention_subscribe/all/by_admin_console）、@我 判定、UI 面板。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/server_settings_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/channel_notification_sheet.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

int _v(Map<String, dynamic> call) => int.parse('${call['version']}');

Map<String, dynamic> _lastOf(FakeTransport t, String apiDotMethod) =>
    t.calls.lastWhere(
      (c) => '${c['api']}.${c['method']}' == apiDotMethod,
      orElse: () => const {},
    );

Future<ChatApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return ChatApi(api);
}

ChannelDto _channel({
  int id = 5,
  String type = 'public',
  bool encrypted = false,
  String notificationMobile = '',
  bool mute = false,
  List<int> subscribes = const [],
}) => ChannelDto(
  channelId: id,
  name: '测试频道',
  type: type,
  encrypted: encrypted,
  notificationMobile: notificationMobile,
  notificationMute: mute,
  subscribes: subscribes,
);

PostDto _post({
  int creator = 4,
  List<int> mentions = const [],
  List<HashtagDto> hashtags = const [],
  int postId = 900,
  int threadId = 0,
}) => PostDto(
  postId: postId,
  channelId: 5,
  threadId: threadId,
  creatorId: creator,
  message: 'hi',
  mentions: mentions,
  hashtagsAdditional: hashtags,
);

void main() {
  group('ChannelPreference 解析', () {
    test('完整字段', () {
      final p = ChannelPreference.fromJson(const {
        'notification_desktop': 'mention',
        'notification_mobile': 'none',
        'notification_mute': true,
      });
      expect(p.notificationDesktop, 'mention');
      expect(p.notificationMobile, 'none');
      expect(p.notificationMute, isTrue);
      expect(p.isMuted, isTrue);
    });

    test('缺字段/空响应不炸', () {
      final p = ChannelPreference.fromJson(const {});
      expect(p.notificationMobile, '');
      expect(p.notificationMute, isFalse);
      expect(p.isMuted, isFalse);
    });

    test('notification_mobile=none 也算静音', () {
      expect(
        const ChannelPreference(notificationMobile: 'none').isMuted,
        isTrue,
      );
      expect(
        const ChannelPreference(notificationMobile: 'all').isMuted,
        isFalse,
      );
    });
  });

  group('API 形态（离线参数校验）', () {
    test('get：channel_id 裸值、协商到 v2、解析 preferences', () async {
      final t = FakeTransport({
        'SYNO.Chat.Channel.Preference.get': {
          'preferences': {
            'notification_desktop': 'all',
            'notification_mobile': 'mention',
            'notification_mute': false,
          },
        },
      });
      final api = await _api(t);

      final pref = await api.channelPreference(5);
      final call = _lastOf(t, 'SYNO.Chat.Channel.Preference.get');
      expect(_v(call), 2);
      expect(call['channel_id'], '5', reason: '裸值，不是 JSON 串');
      expect(call.containsKey('notification_mobile'), isFalse);
      expect(pref.notificationMobile, 'mention');
    });

    test('set：只发 channel_id + notification_mobile，协商到 v3', () async {
      final t = FakeTransport();
      final api = await _api(t);

      await api.setChannelNotification(5, 'none');
      final call = _lastOf(t, 'SYNO.Chat.Channel.Preference.set');
      expect(_v(call), 3);
      expect(call['channel_id'], '5');
      expect(call['notification_mobile'], 'none');
      // 原版只写手机端档位；RSA/登录等噪声字段不算，业务参数就这两个
      final business = call.keys.where(
        (k) => !const {'api', 'method', 'version', '_sid', 'sid'}.contains(k),
      );
      expect(business.toSet(), {'channel_id', 'notification_mobile'});
    });

    test('档位候选：公开/私有非加密 4 档，加密与群聊 2 档', () {
      expect(ChatApi.notificationOptionsFor(_channel()), const [
        'all',
        'mention_subscribe',
        'mention',
        'none',
      ]);
      expect(
        ChatApi.notificationOptionsFor(_channel(type: 'private')),
        contains('mention'),
      );
      expect(ChatApi.notificationOptionsFor(_channel(encrypted: true)), const [
        'all',
        'none',
      ]);
      expect(ChatApi.notificationOptionsFor(_channel(type: 'group')), const [
        'all',
        'none',
      ]);
    });
  });

  group('控制器：读/写都落本地缓存', () {
    test('set 成功后本地档位与 mute 一起更新', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Preference.get': {
            'preferences': {'notification_mobile': 'all'},
          },
        },
      );
      final store = h.container.read(chatStoreProvider);
      await store.upsertChannels([_channel()]);

      expect(await h.ctrl.setChannelNotification(5, 'none'), isTrue);
      expect(_v(_lastOf(h.transport, 'SYNO.Chat.Channel.Preference.set')), 3);
      var ch = (await store.allChannels()).single;
      expect(ch.notificationMobile, 'none');
      // 只写档位：`notification_mute` 是服务端桌面端的独立字段，不能本地派生
      expect(ch.notificationMute, isFalse);

      expect(await h.ctrl.setChannelNotification(5, 'all'), isTrue);
      ch = (await store.allChannels()).single;
      expect(ch.notificationMobile, 'all');
    });

    test('set 失败（服务端报错）时不动本地', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Channel.Preference.set'] = 105;
      final store = h.container.read(chatStoreProvider);
      await store.upsertChannels([_channel(notificationMobile: 'mention')]);

      expect(await h.ctrl.setChannelNotification(5, 'none'), isFalse);
      expect((await store.allChannels()).single.notificationMobile, 'mention');
    });

    test('get 失败回落到本地缓存，成功时以服务端为准并写回', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Channel.Preference.get'] = 106;
      final store = h.container.read(chatStoreProvider);
      await store.upsertChannels([_channel(notificationMobile: 'mention')]);

      expect(
        await h.ctrl.loadChannelNotification(5),
        'mention',
        reason: '服务端报错就用本地缓存',
      );

      h.transport.failures.remove('SYNO.Chat.Channel.Preference.get');
      h.transport.responses['SYNO.Chat.Channel.Preference.get'] = {
        'preferences': {'notification_mobile': 'none'},
      };
      expect(await h.ctrl.loadChannelNotification(5), 'none');
      final ch = (await store.allChannels()).single;
      expect(ch.notificationMobile, 'none');
    });

    test('读档位不会把频道其他字段冲掉', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Preference.get': {
            'preferences': {'notification_mobile': 'mention'},
          },
        },
      );
      final store = h.container.read(chatStoreProvider);
      await store.upsertChannels([_channel()]);
      final before = (await store.allChannels()).single;

      await h.ctrl.loadChannelNotification(5);
      final after = (await store.allChannels()).single;
      expect(after.name, before.name);
      expect(after.type, before.type);
      expect(after.isJoined, before.isJoined);
    });
  });

  group('通知过滤（频道档位）', () {
    test('none 不弹；all 弹', () {
      final other = _post();
      expect(
        NotificationService.allowsNotificationForTest(
          _channel(notificationMobile: 'none'),
          other,
          14,
        ),
        isFalse,
      );
      expect(
        NotificationService.allowsNotificationForTest(
          _channel(notificationMobile: 'all'),
          other,
          14,
        ),
        isTrue,
      );
      expect(
        NotificationService.allowsNotificationForTest(
          _channel(notificationMobile: 'all'),
          other,
          14,
        ),
        isTrue,
      );
    });

    test('空 / by_admin_console 跟随服务端默认档位（Setting/get 的 notify_type）', () {
      final other = _post();
      // 服务端默认 mention_subscribe：没点我、没订阅 → 不弹
      final srv = ServerSettings.fromJson(const {
        'notify_type': 'mention_subscribe',
      });
      expect(
        NotificationService.allowsNotificationForTest(
          _channel(notificationMobile: 'by_admin_console'),
          other,
          14,
          settings: srv,
        ),
        isFalse,
      );
      expect(
        NotificationService.allowsNotificationForTest(
          _channel(notificationMobile: ''),
          other,
          14,
          settings: srv,
        ),
        isFalse,
      );
      // 点我就弹
      expect(
        NotificationService.allowsNotificationForTest(
          _channel(notificationMobile: 'by_admin_console'),
          _post(mentions: const [14]),
          14,
          settings: srv,
        ),
        isTrue,
      );
      // 服务端默认 all → 弹；默认 none → 静音
      final all = ServerSettings.fromJson(const {'notify_type': 'all'});
      expect(
        NotificationService.allowsNotificationForTest(
          _channel(notificationMobile: 'by_admin_console'),
          other,
          14,
          settings: all,
        ),
        isTrue,
      );
      final none = ServerSettings.fromJson(const {'notify_type': 'none'});
      expect(
        NotificationService.allowsNotificationForTest(
          _channel(notificationMobile: 'by_admin_console'),
          other,
          14,
          settings: none,
        ),
        isFalse,
      );
      // 没拿到设置（还没登录完）→ 保持 fail-open
      expect(
        NotificationService.allowsNotificationForTest(
          _channel(notificationMobile: 'by_admin_console'),
          other,
          14,
        ),
        isTrue,
      );
    });

    test('mention 档位只有 @我 才弹', () {
      final ch = _channel(notificationMobile: 'mention');
      expect(
        NotificationService.allowsNotificationForTest(ch, _post(), 14),
        isFalse,
        reason: '没点我',
      );
      expect(
        NotificationService.allowsNotificationForTest(
          ch,
          _post(mentions: const [14]),
          14,
        ),
        isTrue,
      );
      expect(
        NotificationService.allowsNotificationForTest(
          ch,
          _post(mentions: const [4, 6]),
          14,
        ),
        isFalse,
        reason: '点的是别人',
      );
    });

    test('mention_subscribe = @我 或「我订阅的话题」', () {
      final ch = _channel(notificationMobile: 'mention_subscribe');
      expect(
        NotificationService.allowsNotificationForTest(ch, _post(), 14),
        isFalse,
        reason: '既没点我也没订阅',
      );
      expect(
        NotificationService.allowsNotificationForTest(
          ch,
          _post(mentions: const [14]),
          14,
        ),
        isTrue,
      );

      // 我订阅了话题 900 → 这个话题**下**的回复也要弹
      final subscribed = _channel(
        notificationMobile: 'mention_subscribe',
        subscribes: const [900],
      );
      expect(
        NotificationService.allowsNotificationForTest(
          subscribed,
          _post(postId: 901, threadId: 900),
          14,
        ),
        isTrue,
        reason: '订阅的正是这条回复所属的话题',
      );
      expect(
        NotificationService.allowsNotificationForTest(
          subscribed,
          _post(postId: 900, threadId: 0),
          14,
        ),
        isTrue,
        reason: '主消息本身就是话题',
      );
      expect(
        NotificationService.allowsNotificationForTest(
          subscribed,
          _post(postId: 902, threadId: 0),
          14,
        ),
        isFalse,
        reason: '别的频道消息不该弹',
      );
    });

    test('老版本用 hashtags_additional 带 user_id 表示 @我', () {
      final ch = _channel(notificationMobile: 'mention');
      final post = _post(
        hashtags: const [HashtagDto(hashtag: 'demo_user', userId: 14)],
      );
      expect(
        NotificationService.allowsNotificationForTest(ch, post, 14),
        isTrue,
      );
    });

    test('服务器返回的 notification_mute（桌面端设的）同样静音', () {
      final ch = _channel(notificationMobile: 'all', mute: true);
      expect(
        NotificationService.allowsNotificationForTest(ch, _post(), 14),
        isFalse,
      );
    });

    test('未登录（myUserId=0）不会误判 @我', () {
      expect(
        NotificationService.mentionsMe(_post(mentions: const [14]), 0),
        isFalse,
      );
      expect(NotificationService.mentionsMe(_post(), 14), isFalse);
    });
  });

  group('通知设置面板', () {
    Future<void> openSheet(
      WidgetTester tester,
      ChatHarness h,
      ChannelDto channel,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () =>
                      showChannelNotificationSheet(context, ref, channel),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('显示当前档位，选中后调 set 并提示', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Preference.get': {
            'preferences': {'notification_mobile': 'mention'},
          },
        },
      );
      final store = h.container.read(chatStoreProvider);
      await store.upsertChannels([_channel()]);

      await openSheet(tester, h, _channel());

      expect(find.text('通知设置'), findsOneWidget);
      expect(find.text('只有 @我'), findsOneWidget);
      expect(find.text('@我，以及我订阅的话题'), findsOneWidget);
      expect(find.text('不提醒'), findsOneWidget);

      await tester.tap(find.text('不提醒'));
      await tester.pumpAndSettle();

      final call = _lastOf(h.transport, 'SYNO.Chat.Channel.Preference.set');
      expect(call['notification_mobile'], 'none');
      final ch = (await store.allChannels()).single;
      expect(ch.notificationMobile, 'none');
      expect(find.textContaining('通知已改为'), findsOneWidget);
    });

    testWidgets('加密频道只给两档', (tester) async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertChannels([_channel(encrypted: true)]);

      await openSheet(tester, h, (await store.allChannels()).single);
      expect(find.text('全部消息'), findsOneWidget);
      expect(find.text('不提醒'), findsOneWidget);
      expect(find.text('只有 @我'), findsNothing);
      expect(find.text('@我，以及我订阅的话题'), findsNothing);
    });
  });
}
