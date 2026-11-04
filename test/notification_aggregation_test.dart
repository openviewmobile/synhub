// 通知聚合（Phase 8/9 对齐）：原版把通知**按 (频道, 话题) 合成一条**，
// 大标题是「N 条新消息 | 频道名」，明细最多 5 行（InboxStyle）；
// 通知 id/tag 来自 `NotificationTag`（Apache HashCodeBuilder(17,31) + Gson 串）。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/native/background_service.dart';

import 'support/chat_harness.dart';
import 'support/fake_background.dart';

PostDto _post({
  int id = 1001,
  int channelId = 5,
  int threadId = 0,
  int creatorId = 4,
  String message = '在吗',
}) => PostDto.fromJson({
  'post_id': id,
  'channel_id': channelId,
  'thread_id': threadId,
  'creator_id': creatorId,
  'create_at': 9000,
  'type': 'normal',
  'message': message,
});

ChannelDto _channel({int id = 5, String name = '测试频道'}) =>
    ChannelDto.fromJson({'channel_id': id, 'name': name, 'type': 'public'});

Future<({FakeBackground bg, NotificationService service})> _env() async {
  final h = await bootChat();
  final bg = FakeBackground();
  final service = NotificationService(
    h.container.read(notificationServiceProvider).ref,
    background: bg,
  );
  service.appInForeground = false; // 后台才弹
  return (bg: bg, service: service);
}

void main() {
  // 平台语言钉成中文：这两条通知文案走 `platformText()`（系统级跟平台语言），
  // 测试环境默认是 en-US，不钉住的话断言中文会红（见 docs/app-identity-and-i18n.md §4.6）。
  setUp(() {
    // `locale` 与 `locales` 都要钉：语言协商读的是 `locales`
    final pd = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
    pd.localeTestValue = const Locale('zh');
    pd.localesTestValue = const [Locale('zh')];
  });
  tearDown(() {
    final pd = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
    pd.clearLocaleTestValue();
    pd.clearLocalesTestValue();
  });
  group('NotificationTag 对齐（原版 NotificationTag）', () {
    test('id = HashCodeBuilder(17,31).append(channelId).append(threadId)', () {
      // 参考值用 Java 语义（int 溢出到 32 位）手算
      expect(notificationIdFor(5, 0), 16492);
      expect(notificationIdFor(5, 7), 16499);
      expect(notificationIdFor(23, 0), 17050);
      expect(notificationIdFor(45, 0), 17732);
      expect(notificationIdFor(1, 2), 16370);
      // channelId 超过 int 范围时按低 32 位截断
      expect(notificationIdFor(98784247818, 0), 16647);
      // threadId 是 long：先 v ^ (v >>> 32) 再截断
      expect(notificationIdFor(2147483647, 4294967301), -2147467338);
    });

    test('tag = Gson 序列化的 {"channel_id":…,"thread_id":…}', () {
      expect(notificationTagFor(5, 0), '{"channel_id":5,"thread_id":0}');
      expect(notificationTagFor(45, 7), '{"channel_id":45,"thread_id":7}');
    });

    test('MessageNotification 自动带上 id/tag', () {
      const n = MessageNotification(
        channelId: 5,
        postId: 99,
        title: 't',
        text: 'x',
        threadId: 7,
      );
      expect(n.notificationId, 16499);
      expect(n.tag, '{"channel_id":5,"thread_id":7}');
      final map = n.toMap();
      expect(map['notificationId'], 16499);
      expect(map['tag'], '{"channel_id":5,"thread_id":7}');
      expect(map['threadId'], 7);
      expect(map['lines'], isEmpty);
    });
  });

  group('同一 (频道, 话题) 聚合成一条', () {
    test('第 1 条用普通标题，第 2 条起变「N 条新消息 | 频道名」+ 明细', () async {
      final e = await _env();
      await e.service.maybeNotify(
        _post(id: 1, message: '第一条'),
        channel: _channel(),
      );
      expect(e.bg.shown[0].title, contains('测试频道'));
      expect(e.bg.shown[0].lines, hasLength(1));

      await e.service.maybeNotify(
        _post(id: 2, message: '第二条'),
        channel: _channel(),
      );
      final second = e.bg.shown[1];
      expect(second.title, '2 条新消息 | 测试频道');
      expect(second.lines, ['第一条', '第二条']);
      expect(second.text, '第二条', reason: '正文始终是最新一条');

      await e.service.maybeNotify(
        _post(id: 3, message: '第三条'),
        channel: _channel(),
      );
      final third = e.bg.shown[2];
      expect(third.title, '3 条新消息 | 测试频道');
      expect(third.lines, ['第一条', '第二条', '第三条']);
      expect(e.bg.shown, hasLength(3), reason: '每来一条都要重新挂（原地更新）');
    });

    test('三次通知的 notificationId 相同 → 系统里只有一条', () async {
      final e = await _env();
      for (var i = 1; i <= 3; i++) {
        await e.service.maybeNotify(
          _post(id: i, message: 'm$i'),
          channel: _channel(),
        );
      }
      final ids = e.bg.shown.map((n) => n.notificationId).toSet();
      expect(ids, hasLength(1));
      expect(ids.single, notificationIdFor(5, 0));
    });

    test('明细最多保留最新 5 条，但计数继续涨', () async {
      final e = await _env();
      for (var i = 1; i <= 8; i++) {
        await e.service.maybeNotify(
          _post(id: i, message: 'm$i'),
          channel: _channel(),
        );
      }
      final last = e.bg.shown.last;
      expect(last.lines, hasLength(kMaxNotificationLines));
      expect(last.lines, ['m4', 'm5', 'm6', 'm7', 'm8'], reason: '旧→新，砍掉最老的');
      expect(last.title, '8 条新消息 | 测试频道');
      final agg = e.service.aggregateFor(5);
      expect(agg!.count, 8);
    });

    test('不同话题 / 不同频道各自一条', () async {
      final e = await _env();
      await e.service.maybeNotify(
        _post(id: 1, threadId: 0, message: '话题0'),
        channel: _channel(),
      );
      await e.service.maybeNotify(
        _post(id: 2, threadId: 7, message: '话题7'),
        channel: _channel(),
      );
      await e.service.maybeNotify(
        _post(id: 3, channelId: 9, message: '别的频道'),
        channel: _channel(id: 9, name: '另一个'),
      );
      final ids = e.bg.shown.map((n) => n.notificationId).toList();
      expect(ids.toSet(), hasLength(3));
      expect(ids, [
        notificationIdFor(5, 0),
        notificationIdFor(5, 7),
        notificationIdFor(9, 0),
      ]);
      // 话题 7 的那条自己是「第 1 条」，标题不带计数
      expect(e.bg.shown[1].title, contains('测试频道'));
      expect(e.bg.shown[1].lines, hasLength(1));
      expect(e.service.aggregateFor(5, threadId: 7)!.count, 1);
    });
  });

  group('已读要撤掉聚合', () {
    test('markRead → cancelChannel 且计数归零（下一条重新从 1 开始）', () async {
      final e = await _env();
      await e.service.maybeNotify(
        _post(id: 1, message: 'a'),
        channel: _channel(),
      );
      await e.service.maybeNotify(
        _post(id: 2, message: 'b'),
        channel: _channel(),
      );
      expect(e.service.aggregateFor(5)!.count, 2);

      await e.service.clearChannel(5);
      expect(e.bg.cancelledChannels, contains(5));
      expect(e.service.aggregateFor(5), isNull);
      expect(e.bg.shown, hasLength(2), reason: '这里只是撤，不再弹');

      await e.service.maybeNotify(
        _post(id: 3, message: 'c'),
        channel: _channel(),
      );
      final again = e.bg.shown.last;
      expect(again.lines, ['c']);
      expect(again.title, contains('测试频道'), reason: '重新从第 1 条开始');
    });

    test('已读动作走 handleAction 也会撤频道通知', () async {
      final e = await _env();
      await e.service.maybeNotify(_post(id: 1), channel: _channel());
      await e.service.handleAction(
        const NotificationAction(
          action: NotificationAction.markRead,
          channelId: 5,
          postId: 1,
        ),
      );
      expect(e.bg.cancelledChannels, contains(5));
    });

    test('reset 清掉聚合状态', () async {
      final e = await _env();
      await e.service.maybeNotify(_post(id: 1), channel: _channel());
      expect(e.service.aggregateFor(5), isNotNull);
      e.service.reset();
      expect(e.service.aggregateFor(5), isNull);
    });
  });

  group('聚合摘要标题', () {
    test('频道名为空时只显示条数', () async {
      final e = await _env();
      await e.service.maybeNotify(
        _post(id: 1, message: 'x'),
        channel: _channel(name: ''),
      );
      await e.service.maybeNotify(
        _post(id: 2, message: 'y'),
        channel: _channel(name: ''),
      );
      expect(e.bg.shown.last.title, '2 条新消息');
    });

    test('加密频道锁着时聚合照旧，但不能回复', () async {
      final e = await _env();
      final enc = ChannelDto.fromJson({
        'channel_id': 5,
        'name': '加密',
        'type': 'private',
        'encrypted': true,
        'channel_key_enc': 'SEALED',
      });
      await e.service.maybeNotify(
        _post(id: 1, message: 'CIPHER'),
        channel: enc,
      );
      await e.service.maybeNotify(
        _post(id: 2, message: 'CIPHER'),
        channel: enc,
      );
      expect(e.bg.shown.last.lines, hasLength(2));
      expect(e.bg.shown.last.canReply, isFalse);
    });
  });
}
