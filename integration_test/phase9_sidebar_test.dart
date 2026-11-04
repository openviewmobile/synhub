// Phase 9 真机验收：侧栏**分组 + 排序**（原版 `Channel.viewType()` +
// `NaturalOrderComparator`）。
//
//   flutter test integration_test/phase9_sidebar_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 只有真机能回答的问题：
//   ① 2.4.7 服务端**什么时候**发 `channel_order_time` —— 实测只有
//      v5 + `is_joined=true` 才有（不传 is_joined 时字段整个消失，是个陷阱），
//      且值就等于 `last_post_at`；"接收时间"这一档因此 = 最近消息在前；
//   ② 真数据跑一遍分组：未读 / 已加星标 / 频道 / (synobot) / 会话 / 机器人
//      的顺序、未读组的 badge 规则、其余组内按 order time 倒序，
//      以及空名字的历史遗留机器人频道落在哪一组；
//   ③ 四个排序偏好在真库里的往返（SET → 读回 → 还原）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/channel_sort.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：侧栏分组/排序 + order_time 事实 + 偏好往返', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    final store = container.read(chatStoreProvider);
    final settings = SettingsService(store);
    final sync = container.read(chatSessionControllerProvider);
    final channels = await store.allChannels();
    expect(channels, isNotEmpty, reason: 'start() 该把频道同步下来');

    // ---------- ① 服务端什么时候发 channel_order_time ----------
    final chatApi = ctrl.chatApi!;
    final v = chatApi.negotiate('SYNO.Chat.Channel', const [5, 4, 3, 2, 1]);
    Future<List<Map<String, dynamic>>> list(Map<String, String> params) async {
      final raw = await chatApi.api.call('SYNO.Chat.Channel', 'list',
          preferredVersion: v, params: params);
      return (raw['channels'] as List).cast<Map<String, dynamic>>();
    }

    final wire = await list({'is_joined': 'true'});
    final noJoin = await list({});
    final withField =
        wire.where((c) => c.containsKey('channel_order_time')).length;
    final sameAsLastPost = wire
        .where((c) =>
            c['channel_order_time'] != null &&
            c['channel_order_time'] == c['last_post_at'])
        .length;
    final noJoinField =
        noJoin.where((c) => c.containsKey('channel_order_time')).length;
    debugPrint('[p9sb] v=$v is_joined=true → ${wire.length} 条，'
        '含 channel_order_time $withField 条，其中 == last_post_at 的 $sameAsLastPost 条');
    debugPrint('[p9sb] v=$v 不传 is_joined → ${noJoin.length} 条，'
        '含 channel_order_time $noJoinField 条（**陷阱**：字段会消失）');
    expect(v, 5, reason: '2.4.7 的 SYNO.Chat.Channel 最高支持 v5');
    expect(withField, wire.length, reason: 'v5 + is_joined=true 必须带排序字段');
    expect(noJoinField, 0, reason: '不传 is_joined 时服务端不下发这个字段');
    for (final c in wire) {
      expect(((c['channel_order_time'] as num?)?.toInt() ?? 0), greaterThan(0),
          reason: '#${c['channel_id']} 已加入的频道该有排序时间');
    }
    for (final c in wire.where(
        (c) => c['channel_order_time'] != c['last_post_at'])) {
      debugPrint('[p9sb] order_time ≠ last_post_at 的例子：'
          '#${c['channel_id']}「${c['name']}」order=${c['channel_order_time']} '
          'last_post=${c['last_post_at']}');
    }
    debugPrint('[p9sb] 第一条 keys=${(wire.first.keys.toList()..sort()).join(",")}');

    // ---------- ② 真数据跑分组 ----------
    final users = {for (final u in await store.allUsers()) u.userId: u};
    final prefs = await settings.channelSortPrefs();
    final groups = buildSidebarGroups(
      channels,
      prefs: prefs,
      myUserId: sync.myUserId,
      users: users,
    );
    for (final g in groups) {
      debugPrint('[p9sb] 分组「${g.title ?? "(无标题)"}」'
          '(${g.section.name}) ${g.channels.length} 个：'
          '${g.channels.map((c) => "${c.channelId}:${channelDisplayName(c, myUserId: sync.myUserId, users: users)}").join(" | ")}');
    }
    expect(groups, isNotEmpty);

    // 组序必须是 viewType 升序（未读 → 已加星标 → 频道 → synobot → 会话 → 机器人）
    final order = groups.map((g) => g.section.viewType).toList();
    expect(order, List<int>.from(order)..sort(),
        reason: '分组顺序要按 viewType 升序');
    for (var i = 1; i < groups.length; i++) {
      expect(groups[i - 1].section.viewType < groups[i].section.viewType, isTrue);
    }

    // 组内排序：默认 TIME → channel_order_time 倒序（真机上 = last_post_at 倒序）；
    // 未读组例外：固定名称序 + badge/synobot/加密规则（单测里钉细了，这里只看不崩）
    for (final g in groups) {
      if (g.section == SidebarSection.unread) {
        for (final c in g.channels) {
          expect(c.totalUnread > 0 || c.isStar, isTrue,
              reason: '未读组里的频道该有未读（或有失败消息）');
        }
        continue;
      }
      final times = g.channels.map((c) => c.channelOrderTime).toList();
      final sortedTimes = [...times]..sort((a, b) => b.compareTo(a));
      expect(times, sortedTimes,
          reason: '「${g.title ?? g.section.name}」组内该按 channel_order_time 倒序');
    }

    // 切到 NAME 之后：频道组该按名称升序（证明两档在真机上不等价）
    final byNameGroups = buildSidebarGroups(
      channels,
      prefs: const ChannelSortPrefs(
        favorite: ChannelSortMethod.name,
        channel: ChannelSortMethod.name,
        conversation: ChannelSortMethod.name,
        chatbot: ChannelSortMethod.name,
      ),
      myUserId: sync.myUserId,
      users: users,
    );
    for (final g in byNameGroups) {
      if (g.section == SidebarSection.unread) continue;
      final names = g.channels
          .map((c) => channelDisplayName(c, myUserId: sync.myUserId, users: users))
          .toList();
      expect(names, [...names]..sort(naturalCompare),
          reason: 'NAME 档「${g.title ?? g.section.name}」该按名称升序');
    }

    // 空名字的机器人频道（#43/#44/#79/#82/#83/#84/#85 之类的历史遗留）
    // 必须落在机器人群里，而不是混进频道组
    final botGroup = groups
        .where((g) => g.section == SidebarSection.chatbot)
        .firstOrNull;
    if (botGroup != null) {
      for (final c in botGroup.channels) {
        expect(c.type, 'chatbot');
      }
      debugPrint('[p9sb] 机器人群 ${botGroup.channels.length} 个：'
          '${botGroup.channels.map((c) => "#${c.channelId}").join(",")}');
    }

    // ---------- ③ 排序偏好往返（真库） ----------
    final old = await settings.channelSortPrefs();
    await settings.setChannelSortMethod(
        ChannelSortTarget.favorite, ChannelSortMethod.name);
    await settings
        .setChannelSortMethod(ChannelSortTarget.chatbot, ChannelSortMethod.name);
    var back = await settings.channelSortPrefs();
    expect(back.favorite, ChannelSortMethod.name);
    expect(back.chatbot, ChannelSortMethod.name);
    expect(back.channel, old.channel, reason: '没动的档位不该变');
    await settings.setChannelSortMethod(ChannelSortTarget.favorite, old.favorite);
    await settings.setChannelSortMethod(ChannelSortTarget.chatbot, old.chatbot);
    back = await settings.channelSortPrefs();
    expect(back, old, reason: '要能还原');
    debugPrint('[p9sb] 排序偏好往返 + 还原 ✓（默认 favorite=${old.favorite.rawValue} '
        'channel=${old.channel.rawValue} conversation=${old.conversation.rawValue} '
        'chatbot=${old.chatbot.rawValue}）');

    // ---------- ③.5 折叠状态往返（原版四个 hide* 偏好） ----------
    final oldCollapsed = await settings.sidebarCollapsed();
    await settings.setSidebarCollapsed(SidebarSection.channel, true);
    var collapsed = await settings.sidebarCollapsed();
    expect(collapsed.isCollapsed(SidebarSection.channel), isTrue);
    expect(collapsed.isCollapsed(SidebarSection.favorite),
        oldCollapsed.isCollapsed(SidebarSection.favorite));
    await settings.setSidebarCollapsed(
        SidebarSection.channel, oldCollapsed.isCollapsed(SidebarSection.channel));
    collapsed = await settings.sidebarCollapsed();
    expect(collapsed, oldCollapsed, reason: '要能还原');
    debugPrint('[p9sb] 折叠状态往返 + 还原 ✓');

    // ---------- ④ 列表页在真机上画得出来（分组头） ----------
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ChannelListPage()),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    final headerTitles = groups.map((g) => g.title).whereType<String>().toList();
    // 分组头是懒加载的：从上往下逐个滚过去看（真机一屏放不下 6+ 个频道）
    for (final t in headerTitles) {
      for (var i = 0; i < 20 && find.text(t).evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -180));
        await tester.pump();
      }
      expect(find.text(t), findsWidgets, reason: '分组头「$t」要画出来');
      debugPrint('[p9sb] 分组头「$t」已出现在屏幕上 ✓');
    }
    debugPrint('[p9sb] 列表页分组头 = $headerTitles ✓');

    debugPrint('[p9sb] ✅ 侧栏分组/排序验收完成');
  });
}
