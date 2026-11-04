// 侧栏分组与排序（原版 `Channel.viewType()` + `NaturalOrderComparator`）。
//
// 依据（`~/Downloads/Android-SynologyChat.2.11.1-607.ww-export/sources`）：
//   * `Channel.viewType()`：showInUnread → 103；isStar → 105；
//     anonymous→110 / synobot→109 / public|private→107 / chatbot→112
//   * `Channel.showInUnread()` = hasFailedPost || (!hideAtSideBar && totalUnread>0)
//   * `Channel.getBadgeNumber()`：public/private **未加密** 只算 mention
//   * `NaturalOrderComparator.compare` 按 viewType 升序分组，同组再按偏好排序
//   * `orderBySortMethod`：TIME → `channel_order_time` 降序；NAME → 规则 + 自然序
//
// 实测事实（NAS 2.4.7）：`Channel/list` **不下发 `channel_order_time`**，
// 所以 TIME 在真机上退化成"名称序"（稳定排序保持基列表顺序）—— 这条也钉在用例里。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/chat/channel_row.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/channel_sort.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/settings/settings_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

ChatStore _store() => ChatStore(ChatDatabase(NativeDatabase.memory()));

ChannelDto _ch(
  int id, {
  String name = '',
  String type = 'public',
  int unread = 0,
  int unreadMention = 0,
  int unreadComment = 0,
  int unreadMentionComment = 0,
  bool star = false,
  bool encrypted = false,
  int orderTime = 0,
  int lastPostAt = 0,
  int lastHideAt = 0,
  int hideGlobalAt = 0,
  List<int> members = const [],
}) => ChannelDto.fromJson({
  'channel_id': id,
  'name': name,
  'type': type,
  'is_joined': true,
  'is_star': star,
  'encrypted': encrypted,
  'unread': unread,
  'unread_mention': unreadMention,
  'unread_comment': unreadComment,
  'unread_mention_comment': unreadMentionComment,
  'channel_order_time': orderTime,
  'last_post_at': lastPostAt,
  'last_hide_at': lastHideAt,
  'hide_global_at': hideGlobalAt,
  'members': members,
});

void main() {
  group('分组判定（Channel.viewType / showInUnread）', () {
    test('按类型落组：public/private→频道、anonymous→会话、synobot→我的空间、'
        'chatbot→机器人', () {
      SidebarSection of(ChannelDto c) => sectionOf(c, hasFailedPost: false);
      expect(of(_ch(1, name: 'a')), SidebarSection.channel);
      expect(of(_ch(2, name: 'a', type: 'private')), SidebarSection.channel);
      expect(of(_ch(3, type: 'anonymous')), SidebarSection.conversation);
      expect(of(_ch(4, type: 'synobot')), SidebarSection.synobot);
      expect(of(_ch(5, type: 'chatbot')), SidebarSection.chatbot);
    });

    test('加星 → 已加星标（优先于类型）；有未读 → 未读（优先于加星）', () {
      expect(
        sectionOf(_ch(1, name: 'a', star: true), hasFailedPost: false),
        SidebarSection.favorite,
      );
      expect(
        sectionOf(
          _ch(1, name: 'a', star: true, unread: 2),
          hasFailedPost: false,
        ),
        SidebarSection.unread,
      );
    });

    test('有发送失败消息 → 进未读（哪怕未读数是 0）', () {
      expect(
        sectionOf(
          _ch(1, name: 'a', unread: 0, lastHideAt: 1700),
          hasFailedPost: true,
        ),
        SidebarSection.unread,
      );
    });

    test('被隐藏且没有未读 → 完全不出现在列表里', () {
      final groups = buildSidebarGroups([
        _ch(1, name: '藏起来', lastHideAt: 1700000000000),
        _ch(2, name: '看得见'),
      ]);
      final names = [
        for (final g in groups)
          for (final c in g.channels) channelDisplayName(c),
      ];
      expect(names, ['看得见']);
    });

    test('隐藏的频道有未读会冒出来；通知档不是 all 时只看 mention 未读', () {
      // public 非加密、频道通知档为空（≠ all）→ 只看 @我/回复
      final plain = _ch(1, name: 'x', lastHideAt: 1700, unread: 3);
      expect(plain.hideAtSideBar(), isTrue, reason: '只有普通未读 → 仍算隐藏');
      final withMention = _ch(1, name: 'x', lastHideAt: 1700, unreadMention: 1);
      expect(withMention.hideAtSideBar(), isFalse);
      expect(
        sectionOf(withMention, hasFailedPost: false),
        SidebarSection.channel,
        reason: '进未读组要 totalUnread>0，只有 mention 未读时是 0',
      );
      // 频道通知档 = all → 任何未读都冒出来
      final all = ChannelDto(
        channelId: 1,
        name: 'x',
        type: 'public',
        lastHideAt: 1700,
        unread: 3,
        notificationMobile: 'all',
      );
      expect(all.hideAtSideBar(), isFalse);
      // by_admin_console + 服务端默认 all
      final byAdmin = ChannelDto(
        channelId: 1,
        name: 'x',
        type: 'public',
        lastHideAt: 1700,
        unread: 3,
        notificationMobile: 'by_admin_console',
      );
      expect(byAdmin.hideAtSideBar(), isTrue);
      expect(
        byAdmin.hideAtSideBar(serverDefaultNotificationType: 'all'),
        isFalse,
      );
    });

    test('badge 计算：public/private 非加密只看 mention，其余算全部未读', () {
      expect(
        channelBadgeNumber(
          _ch(1, unread: 9, unreadMention: 2, unreadMentionComment: 1),
        ),
        3,
      );
      expect(
        channelBadgeNumber(
          _ch(1, type: 'chatbot', unread: 9, unreadComment: 1),
        ),
        10,
      );
      expect(
        channelBadgeNumber(
          _ch(1, encrypted: true, unread: 9, unreadComment: 1),
        ),
        10,
      );
    });

    test('显示名：synobot→我的空间、1/2 号频道→常规/随机、会话→对方昵称', () {
      expect(channelDisplayName(_ch(9, type: 'synobot')), '我的空间');
      expect(channelDisplayName(_ch(1)), '常规');
      expect(channelDisplayName(_ch(2)), '随机');
      final users = {
        4: UserDto.fromJson({
          'user_id': 4,
          'username': 'demo',
          'nickname': '阿图',
        }),
        6: UserDto.fromJson({'user_id': 6, 'username': 'demo_admin'}),
      };
      expect(
        channelDisplayName(
          _ch(7, type: 'anonymous', members: [14, 4]),
          myUserId: 14,
          users: users,
        ),
        'demo (阿图)',
      );
      expect(
        channelDisplayName(
          _ch(7, type: 'anonymous', members: [14, 6]),
          myUserId: 14,
          users: users,
        ),
        'demo_admin',
      );
    });

    test('My Space：synobot 频道的用户可见标题必须覆盖服务端 name（双语）', () {
      // 决策证据：官方 `Channel.displayName()` 在 `isSynoBot()`（type=="synobot"）
      // 时返回 `R.string.myspace`（zh "我的空间" / en "My Space"）。
      // 服务端 `Channel/list` 把该频道 `name` 下发成字面量 `"synobot"`
      // （真 NAS 实测 channel_id 23 / name "synobot" / type "synobot"）⇒
      // 不覆盖就会显示成 "synobot"。
      final bot = _ch(23, name: 'synobot', type: 'synobot');
      expect(channelDisplayName(bot), '我的空间');
      expect(channelDisplayName(bot, text: AppTextEn()), 'My Space');
      expect(channelDisplayName(bot, text: AppTextZh()), '我的空间');
      expect(channelRowTitle(bot, const {}, 0), '我的空间');
      expect(
        channelRowTitle(bot, const {}, 0, text: AppTextEn()),
        'My Space',
      );
      // 机器人频道（chatbot）**不**被覆盖，仍用服务端 name —— 别把两件事混了。
      final botChannel = _ch(43, name: '我的机器人', type: 'chatbot');
      expect(channelRowTitle(botChannel, const {}, 0), '我的机器人');
    });
  });

  group('自然序（orderByAlphabetical / compareRight）', () {
    test('大小写不敏感、数字按数值、忽略前导空格', () {
      expect(naturalCompare('Apple', 'apple'), 0);
      expect(naturalCompare('a2', 'a10') < 0, isTrue);
      expect(naturalCompare('a10', 'a2') > 0, isTrue);
      expect(naturalCompare('b', 'a'), greaterThan(0));
      expect(naturalCompare('  Channel', 'channel'), 0);
      expect(naturalCompare('频道A', '频道B') < 0, isTrue);
    });
  });

  group('分组列表 buildSidebarGroups', () {
    test('分组顺序照 viewType：未读 → 已加星标 → 频道 → (synobot) → 会话 → 机器人，'
        '且 synobot 没有标题', () {
      final groups = buildSidebarGroups([
        _ch(10, name: 'B 频道'),
        _ch(11, name: 'A 频道'),
        _ch(12, name: '星标', star: true),
        _ch(13, type: 'anonymous', name: '会话A'),
        _ch(14, type: 'chatbot', name: '机器人A'),
        _ch(15, type: 'synobot'),
        _ch(16, name: '未读频道', unread: 3),
      ]);
      expect(groups.map((g) => g.section).toList(), [
        SidebarSection.unread,
        SidebarSection.favorite,
        SidebarSection.channel,
        SidebarSection.synobot,
        SidebarSection.conversation,
        SidebarSection.chatbot,
      ]);
      expect(groups.map((g) => g.title).toList(), [
        '未读',
        '已加星标',
        '频道',
        null,
        '会话',
        '机器人',
      ]);
      expect(channelDisplayName(groups[2].channels.first), 'A 频道');
      expect(channelDisplayName(groups[5].channels.first), '机器人A');
    });

    test('NAME：组内按名称自然序（含数字）', () {
      const prefs = ChannelSortPrefs(
        channel: ChannelSortMethod.name,
        favorite: ChannelSortMethod.name,
      );
      final groups = buildSidebarGroups([
        _ch(1, name: 'Channel 10'),
        _ch(2, name: 'channel 2'),
        _ch(3, name: 'alpha'),
      ], prefs: prefs);
      final names = groups.single.channels.map(channelDisplayName).toList();
      expect(names, ['alpha', 'channel 2', 'Channel 10']);
    });

    test('TIME：按 channel_order_time 降序（服务端有下发时）', () {
      final groups = buildSidebarGroups([
        _ch(1, name: 'old', orderTime: 100),
        _ch(2, name: 'new', orderTime: 300),
        _ch(3, name: 'mid', orderTime: 200),
      ]);
      expect(groups.single.channels.map((c) => c.name).toList(), [
        'new',
        'mid',
        'old',
      ]);
    });

    test('order time 全为 0（服务器不发这个字段）→ TIME 退化成名称序', () {
      final groups = buildSidebarGroups([
        _ch(1, name: 'zoo', lastPostAt: 999999),
        _ch(2, name: 'alpha', lastPostAt: 1),
      ]);
      expect(groups.single.channels.map((c) => c.name).toList(), [
        'alpha',
        'zoo',
      ], reason: '原版此时比较恒为 0，稳定排序保持 DB 的 name ASC');
    });

    test('真机形态：order time == last_post_at → TIME = 最近消息在前', () {
      // `tool/probe_channel_order.dart`：v5 + is_joined=true 时服务端就是
      // 把 last_post_at 当 channel_order_time 发下来的
      final groups = buildSidebarGroups([
        _ch(1, name: 'alpha', orderTime: 100, lastPostAt: 100),
        _ch(2, name: 'zoo', orderTime: 300, lastPostAt: 300),
      ]);
      expect(groups.single.channels.map((c) => c.name).toList(), [
        'zoo',
        'alpha',
      ]);
    });

    test('未读组固定名称序，但 badge>0 的排前面；badge=0 的垫底', () {
      // 进未读组看 totalUnread；badge 另算（public 非加密只看 mention）
      final groups = buildSidebarGroups([
        _ch(1, name: 'a', unread: 5), // 未读但 badge=0
        _ch(3, name: 'c', type: 'chatbot', unread: 1), // badge=1
        _ch(4, name: 'd', type: 'chatbot', unread: 2), // badge=2
      ]);
      final unread = groups.firstWhere(
        (g) => g.section == SidebarSection.unread,
      );
      expect(
        unread.channels.map((c) => c.name).toList(),
        ['c', 'd', 'a'],
        reason:
            '规则比的是"badge>0 这个布尔"（原版 Function1 返回 Boolean），'
            '同为 true 再按名称；badge=0 的最后',
      );

      // public 只被 @ 到但没有普通未读 → totalUnread==0 → 不进未读组
      final g2 = buildSidebarGroups([_ch(2, name: 'b', unreadMention: 1)]);
      expect(g2.single.section, SidebarSection.channel);
    });

    test('同名频道保持输入顺序（稳定排序，不抖）', () {
      final groups = buildSidebarGroups([
        _ch(2, name: 'same'),
        _ch(1, name: 'same'),
        _ch(3, name: 'same'),
      ]);
      expect(groups.single.channels.map((c) => c.channelId).toList(), [
        2,
        1,
        3,
      ]);
    });

    test('加密频道在同名时排前面（encrypted 降序规则）', () {
      const prefs = ChannelSortPrefs(channel: ChannelSortMethod.name);
      final groups = buildSidebarGroups([
        _ch(1, name: 'same'),
        _ch(2, name: 'same', encrypted: true),
      ], prefs: prefs);
      expect(groups.single.channels.first.channelId, 2);
    });

    test('星标频道用 favorite 的排序偏好（与 channel 分开）', () {
      const prefs = ChannelSortPrefs(
        favorite: ChannelSortMethod.name,
        channel: ChannelSortMethod.time,
      );
      final groups = buildSidebarGroups([
        _ch(1, name: 'z', star: true, orderTime: 1),
        _ch(2, name: 'a', star: true, orderTime: 999),
        _ch(3, name: 'z2', orderTime: 1),
        _ch(4, name: 'a2', orderTime: 999),
      ], prefs: prefs);
      final fav = groups.firstWhere(
        (g) => g.section == SidebarSection.favorite,
      );
      final chan = groups.firstWhere(
        (g) => g.section == SidebarSection.channel,
      );
      expect(fav.channels.map((c) => c.name).toList(), [
        'a',
        'z',
      ], reason: '星标组按名称');
      expect(chan.channels.map((c) => c.name).toList(), [
        'a2',
        'z2',
      ], reason: '频道组按 order time 降序');
    });

    test('synobot 跟会话共用 conversation 偏好（原版 109 落 else 分支）', () {
      const prefs = ChannelSortPrefs(conversation: ChannelSortMethod.time);
      final groups = buildSidebarGroups([
        _ch(1, type: 'synobot', orderTime: 100),
        _ch(2, type: 'anonymous', name: '会话', orderTime: 300),
      ], prefs: prefs);
      expect(groups.map((g) => g.section).toList(), [
        SidebarSection.synobot,
        SidebarSection.conversation,
      ]);
      expect(groups.first.channels.single.channelId, 1);
      expect(groups.last.channels.single.channelId, 2);
    });
  });

  group('排序偏好（SettingsService / provider）', () {
    test('默认四档都是 TIME；key 名照原版', () async {
      final store = _store();
      final s = SettingsService(store);
      final p = await s.channelSortPrefs();
      expect(p.favorite, ChannelSortMethod.time);
      expect(p.channel, ChannelSortMethod.time);
      expect(p.conversation, ChannelSortMethod.time);
      expect(p.chatbot, ChannelSortMethod.time);

      await s.setChannelSortMethod(
        ChannelSortTarget.favorite,
        ChannelSortMethod.name,
      );
      await s.setChannelSortMethod(
        ChannelSortTarget.chatbot,
        ChannelSortMethod.name,
      );
      final all = await store.allSettings();
      expect(all['favorite_sort_by'], 'NAME');
      expect(all['chat_bot_sort_by'], 'NAME');
      final p2 = await s.channelSortPrefs();
      expect(p2.favorite, ChannelSortMethod.name);
      expect(p2.channel, ChannelSortMethod.time);
      expect(p2.chatbot, ChannelSortMethod.name);
      expect(
        p2.synobot,
        ChannelSortMethod.time,
        reason: 'synobot 跟 conversation 共用',
      );
    });

    test('坏值回落 TIME', () async {
      final store = _store();
      await store.setSetting('channel_sort_by', 'weird');
      expect(
        (await SettingsService(store).channelSortPrefs()).channel,
        ChannelSortMethod.time,
      );
    });

    test('折叠状态：四个 key + 默认展开 + 往返', () async {
      final store = _store();
      final svc = SettingsService(store);
      expect(
        await svc.sidebarCollapsed(),
        const SidebarCollapsed(),
        reason: '默认全展开',
      );
      await svc.setSidebarCollapsed(SidebarSection.channel, true);
      await svc.setSidebarCollapsed(SidebarSection.chatbot, true);
      final all = await store.allSettings();
      expect(all['hideChannel'], 'true', reason: 'key 名照原版 camelCase');
      expect(all['hideChatBot'], 'true');
      final c = await svc.sidebarCollapsed();
      expect(c.isCollapsed(SidebarSection.channel), isTrue);
      expect(c.isCollapsed(SidebarSection.chatbot), isTrue);
      expect(c.isCollapsed(SidebarSection.favorite), isFalse);
      expect(
        c.isCollapsed(SidebarSection.unread),
        isFalse,
        reason: '未读组原版就没有折叠箭头',
      );
      // toggle 语义
      final toggled = c.toggled(SidebarSection.channel);
      expect(toggled.isCollapsed(SidebarSection.channel), isFalse);
    });

    test('provider 折叠落盘往返', () async {
      final store = _store();
      final c = ProviderContainer(
        overrides: [chatStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      await c
          .read(sidebarCollapsedProvider.notifier)
          .toggle(SidebarSection.favorite);
      expect(c.read(sidebarCollapsedProvider).favorite, isTrue);
      final c2 = ProviderContainer(
        overrides: [chatStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c2.dispose);
      await c2.read(sidebarCollapsedProvider.notifier).preload();
      expect(c2.read(sidebarCollapsedProvider).favorite, isTrue);
    });

    test('provider 落盘往返', () async {
      final store = _store();
      final c = ProviderContainer(
        overrides: [chatStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      await c
          .read(channelSortPrefsProvider.notifier)
          .set(ChannelSortTarget.conversation, ChannelSortMethod.name);

      final c2 = ProviderContainer(
        overrides: [chatStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c2.dispose);
      await c2.read(channelSortPrefsProvider.notifier).preload();
      expect(
        c2.read(channelSortPrefsProvider).conversation,
        ChannelSortMethod.name,
      );
      expect(c2.read(channelSortPrefsProvider).chatbot, ChannelSortMethod.time);
    });
  });

  group('频道列表页：分组头真的画出来了', () {
    testWidgets('未读 / 频道 / 机器人三个组头 + 组内名称序', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                ...testChannelJson,
                'channel_id': 5,
                'name': 'Zeta',
                'unread': 0,
              },
              {
                ...testChannelJson,
                'channel_id': 6,
                'name': 'Alpha',
                'unread': 0,
              },
              {
                ...testChannelJson,
                'channel_id': 7,
                'name': 'B 机器人',
                'type': 'chatbot',
                'unread': 0,
              },
            ],
          },
        },
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChannelListPage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('频道'), findsWidgets, reason: '「频道」组头');
      // ★ r344 D55：**别用词找组头** —— 「机器人」现在也会出现在「机器人」会话行的副标题上
      //   （那一行没有人数/未读时，副标题就只剩这一个类型词）。组头改按**身份 Key** 找。
      final botHeader = find.byKey(const Key('channel-section-chatbot'));
      expect(botHeader, findsOneWidget, reason: '「机器人」组头（按 Key）');
      expect(
        find.descendant(of: botHeader, matching: find.text('机器人')),
        findsOneWidget,
        reason: '组头里那行字仍是「机器人」',
      );
      // 副标题的类型词确实是本地化的（D55）：裸 `chatbot` 不许再出现
      expect(find.text('chatbot'), findsNothing, reason: '裸枚举不许当文案');
      expect(find.text('Zeta'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('B 机器人'), findsOneWidget);

      // 组内按名称：Alpha 在 Zeta 之前
      final alphaY = tester.getTopLeft(find.text('Alpha')).dy;
      final zetaY = tester.getTopLeft(find.text('Zeta')).dy;
      expect(alphaY < zetaY, isTrue, reason: '同名组内按名称升序');
      // 组头在组内条目之上
      final headerY = tester.getTopLeft(botHeader).dy;
      final botY = tester.getTopLeft(find.text('B 机器人')).dy;
      expect(headerY < botY, isTrue);

      // 设置页入口
      expect(find.text('未读'), findsNothing, reason: '没有未读就不加这个头');
    });

    testWidgets('点分组头能收起/展开（原版四个 hide* 偏好）', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                ...testChannelJson,
                'channel_id': 5,
                'name': 'Alpha',
                'unread': 0,
              },
              {
                ...testChannelJson,
                'channel_id': 6,
                'name': 'Beta',
                'unread': 0,
              },
            ],
          },
        },
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChannelListPage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Alpha'), findsOneWidget);

      final header = find.widgetWithText(InkWell, '频道');
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsNothing, reason: '收起后条目藏起来');
      expect(find.text('频道'), findsWidgets, reason: '标题还在');
      expect(
        h.container.read(sidebarCollapsedProvider).channel,
        isTrue,
        reason: '折叠状态要落库',
      );
      expect(
        await h.container.read(chatStoreProvider).setting('hideChannel'),
        'true',
      );

      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(h.container.read(sidebarCollapsedProvider).channel, isFalse);
    });

    testWidgets('设置页有「频道和对话排序方式」', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('频道和对话排序方式'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('频道和对话排序方式'), findsOneWidget);
      expect(find.text('接收时间'), findsOneWidget, reason: '默认四档都是接收时间');
    });
  });
}
