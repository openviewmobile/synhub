import 'dart:async';
// 频道/会话列表 —— App 主界面（"指挥台"）。
//
// 数据全部来自本地库（ChatStore）的 watchChannels()，所以 socket 推来的
// 未读数变化会**自动**刷到界面上，不需要手动 setState。
//
// 这一版把"普通 Material 列表"改造成 HUD（座舱玻璃）设计语言的**科幻指挥台**，
// 只改外观 / 动效 / 信息排布，行为、数据来源、语义字符串一律不动。结构：
//
//   ① `FieldBackdrop`   整页深空底（透视网格 + 星尘 + 扫描线），内容浮在玻璃上；
//   ② `_CommandDeck`    指挥台顶栏（取代 AppBar）：头像核 + 真实链路状态 +
//                       搜索/刷新/更多 + `DataStrip` 遥测带（地址/频道数/用户数）；
//   ③ 分组量程标题      小号 `TelemetryLabel`（`PINNED · 收藏` 这种），
//                       中文组名仍是独立的 Text，保证 find.text('频道') 不变；
//   ④ `ChannelRow`      每行一块切角行面板（见 channel_row.dart）：能量条 +
//                       状态小标 + 右对齐遥测时间 + 未读角标；
//   ⑤ 右下角 `OrbButton` 新建频道球，复用原有 `AppRoutes.channelCreate`。
//
// 关键取舍（why）：
//   * 顶栏用 `TechFrame`（有模糊，属于"铬部件"）；**列表行绝对不用模糊**，
//     一屏十几行 `BackdropFilter` 必掉帧 —— 行用高不透明填充 + 切角描边 + 辉光。
//   * 常驻动效（`FieldBackdrop` / `DataStrip` / `OrbButton`）全部走
//     `AppEffects.ambientAllowed` 闸门；测试里恒为 false，`pumpAndSettle` 不会挂。
//     这里刻意**不用** `ScanSweep`（它有一段 `Future.delayed` 定时器，会让
//     只 pump 100ms 的用例在拆树时报"Timer is still pending"）。
//   * 未读行才亮（能量条 + 辉光 + 主色时间），已读行静息低对比 ——
//     "静息克制、交互时才炫"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../core/settings/acl.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/server_settings.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/debounced_status_line.dart';
import '../../core/ui/hud_widgets.dart';
import '../../core/ui/orb_button.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/user_dto.dart';
import '../servers/session_controller.dart';
import 'available_channels_page.dart';
import 'channel_manage_sheet.dart';
import 'channel_row.dart';
import 'channel_sort.dart';
import 'chat_deep_link_host.dart';
import 'chat_session_controller.dart';
import 'global_content_page.dart';
import 'share_intent_host.dart';
import '../../core/user_facing_error.dart';

class ChannelListPage extends ConsumerWidget {
  const ChannelListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final sync = ref.watch(chatSessionControllerProvider);
    final channels = ref.watch(channelsProvider);
    final users = ref.watch(usersProvider);

    // 登录成功后自动开始同步（幂等）
    final conn = session.connection;
    // ★ r665（DA284）：`loggedIn` 与 `connection` 可能**不是同一时刻的对象**
    //   （状态里的 session 是上一次登录的，connection 是这次刚连上还没登录的）。
    //   只看 `loggedIn` 会让同步用**空 sid** 打请求 ⇒ 服务端 119、钩子还没装、
    //   三个功能静默降级。所以再钉一条：连接自己身上必须有 sid。
    final connHasSession = (conn?.api.session?.sid ?? '').isNotEmpty;
    if (session.loggedIn && conn != null && connHasSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          ref.read(chatSessionControllerProvider.notifier).start(conn);
        }
      });
    }

    final userMap = <int, UserDto>{
      for (final u in users.value ?? const <UserDto>[]) u.userId: u,
    };

    // 权限门控（原版 `User.hasPrivilege`，查不到即允许——见 `acl.dart`）：
    //   * `channel_create` → 建频道入口（`NamedChannelFragment.java:155`）
    //   * `channel_anonymous` → 一对一会话分组/入口（`DrawerPresenter.java:67`）
    final canCreate = ref.hasPrivilege(kAclChannelCreate);
    final canAnonymous = ref.hasPrivilege(kAclChannelAnonymous);
    final canJoinPublic = allowsPublicChannels(ref.hasPrivilege);

    return Scaffold(
      backgroundColor: DesignPalette.of(context).bg,
      body: ChatDeepLinkHost(
        child: ShareIntentHost(
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                _CommandDeck(
                  sync: sync,
                  endpoint: conn?.endpoint.baseUrl ?? '-',
                ),
                Expanded(
                  child: channels.when(
                    loading: () => const AppListSkeleton(),
                    error: (e, _) => AppErrorView(
                      title: context.t.photoLoadFailed,
                      detail: userFacingError(e),
                      onRetry: () {
                        ref
                            .read(chatSessionControllerProvider.notifier)
                            .refresh();
                      },
                    ),
                    data: (rawList) {
                      // 隐藏的频道不显示（原版 `Channel.hideAtSideBar()`：
                      // 来新消息会自己冒出来；有发送失败的消息也不藏）
                      final failed =
                          ref.watch(failedPostChannelsProvider).value ??
                          const <int>{};
                      // 没有 `channel_anonymous` 权限时，一对一（匿名）会话整块
                      // 不出现（原版 `DrawerPresenter` 不挂 `DrawerField(108)`）
                      final list = canAnonymous
                          ? rawList
                          : rawList
                                .where((c) => c.type != 'anonymous')
                                .toList(growable: false);
                      // 分组 + 组内排序：逐行对位原版 `Channel.viewType()` +
                      // `NaturalOrderComparator`（见 `channel_sort.dart` 的头注释）
                      final groups = buildSidebarGroups(
                        list,
                        prefs: ref.watch(channelSortPrefsProvider),
                        failedChannelIds: failed,
                        myUserId: sync.myUserId,
                        users: userMap,
                        serverDefaultNotificationType: ref
                            .watch(serverSettingsProvider)
                            .defaultNotificationType,
                      );
                      if (groups.isEmpty) {
                        return _EmptyBody(
                          sync: sync,
                          canCreate: canCreate,
                          canJoinPublic: canJoinPublic,
                        );
                      }
                      // 分组头 + 频道拼成一个扁平列表（ListView 好做懒加载）；
                      // 收起的组只留标题（原版 `ExpandableHeaderItem.isOriginExpanded`）
                      final collapsed = ref.watch(sidebarCollapsedProvider);
                      final rows = <Object>[];
                      for (final g in groups) {
                        if (g.title != null) rows.add(g);
                        if (collapsed.isCollapsed(g.section)) continue;
                        rows.addAll(g.channels);
                      }
                      return RefreshIndicator(
                        onRefresh: () => ref
                            .read(chatSessionControllerProvider.notifier)
                            .refresh(),
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          // 底部留出主行动球的高度，最后一行不会被遮住
                          padding: const EdgeInsets.only(
                            top: Gap.xs,
                            bottom: Gap.xxl * 2.4,
                          ),
                          itemCount: rows.length,
                          itemBuilder: (_, i) {
                            final row = rows[i];
                            if (row is SidebarGroup) {
                              return _SectionHeader(
                                group: row,
                                collapsed: collapsed.isCollapsed(row.section),
                                onToggle:
                                    SidebarCollapsed.collapsible(row.section)
                                    ? () => ref
                                          .read(
                                            sidebarCollapsedProvider.notifier,
                                          )
                                          .toggle(row.section)
                                    : null,
                              );
                            }
                            final channel = row as ChannelDto;
                            return ChannelRow(
                              channel: channel,
                              users: userMap,
                              myUserId: sync.myUserId,
                              failed: failed.contains(channel.channelId),
                              onTap: () =>
                                  _openChannel(context, ref, channel.channelId),
                              // 长按 = 频道管理（原版在聊天页菜单的「设置」里）
                              onLongPress: () => showChannelManageSheet(
                                context,
                                ref,
                                channel,
                                onRemoved: () {},
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      // 「玄武」主行动球：新建频道（复用原有跳转，不新造功能）。
      // 无 `channel_create` 权限时**不出现**（原版 `NamedChannelFragment.java:155`
      // 直接把整个 `create` 菜单项清空）——宁可没有入口，也不让用户点了吃 402。
      floatingActionButton: canCreate
          ? OrbButton(
              icon: Icons.add_comment_outlined,
              tooltip: context.t.chatNewChannel,
              onPressed: () => context.push(AppRoutes.channelCreate),
            )
          : null,
    );
  }

  void _openChannel(BuildContext context, WidgetRef ref, int channelId) {
    // 进消息页；已读上报交给 ChatPage（它知道用户确实看到了内容）
    ref.read(chatSessionControllerProvider.notifier).markRead(channelId);
    context.push(AppRoutes.chatOf(channelId));
  }
}

/// 指挥台顶栏（取代原来的 AppBar）。
///
/// 状态**来自真实 state**（`ChatSyncState.phase`），不是装饰：
///   ready → `实时已连接`；syncing → `重连中`；idle/degraded → `离线`；
///   error → `同步失败`。
/// 下面 `DataStrip` 滚动的是页面本来就有的真实数据（endpoint / 频道数 /
/// 用户数），并保留了原来 `_StatusBar` 的详细文案（等待同步 / 同步中… /
/// 实时已连接 · connId / 实时通道未连接（列表仍可用） / 同步失败 / 已断开）。
class _CommandDeck extends ConsumerWidget {
  const _CommandDeck({required this.sync, required this.endpoint});

  final ChatSyncState sync;
  final String endpoint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hud = DesignPalette.of(context);

    // ACL 门控（与 `_EmptyBody` / FAB 同一套判定）：
    //   `channel_create` → 菜单里的「新建频道」
    //   `channel_join` + `channel_public` → 「加入公开频道」（原版
    //   `NamedChannelFragment.java:165` 两个权限都满足才列公开频道）
    final canCreate = ref.hasPrivilege(kAclChannelCreate);
    final canJoinPublic = allowsPublicChannels(ref.hasPrivilege);

    // 紧凑链路状态（真实 state → 文案 + 颜色）
    final (stateLabel, stateColor, stateRing) = switch (sync.phase) {
      ChatSyncPhase.ready => (t.chatLinkReady, hud.ok, hud.ok),
      ChatSyncPhase.syncing => (t.chatLinkReconnecting, scheme.primary, null),
      ChatSyncPhase.idle => (t.chatLinkOffline, hud.dim, null),
      ChatSyncPhase.degraded => (t.chatLinkOffline, hud.danger, null),
      ChatSyncPhase.error => (t.chatLinkSyncFailed, scheme.error, null),
    };

    // ★ DA294：`chatLinkDisconnected` / `_statusLine` 从这里**移除**。
    //   它们随 socket 每秒抖好几次（`strip.join` 的长度跟着变 ⇒ 折行数变
    //   ⇒ 整页上下跳）。链路相位在上面的 `_DebouncedPhase`（定高单行），
    //   断开原因在连接面板（点状态点）里看。
    final strip = <String>[
      endpoint,
      t.chatChannelCount(sync.channelCount),
      t.chatUserCount(sync.userCount),
    ];

    // ★ r493：顶部"座舱面板"（TechFrame：角括号 + 刻度 + 状态灯）换成
    //   设计语言的**页头**：标题 + 一行链路状态 + 三个动作，无外框。
    //   设计稿里页头就是内容的一部分，不套容器 —— 套了会和下面第一张行卡
    //   形成"框里框外"两套层次。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              RingAvatar(
                size: 40,
                icon: Icons.forum_outlined,
                background: scheme.primary,
                ring: stateRing,
                ringWidth: 2,
                semanticLabel: t.chatChannelsTitle,
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 页面标题：语义字符串保持原样（原来是 AppBar 的 '频道'）
                    Text(
                      t.chatChannelsTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 3),
                    // ★ DA294：这行原来直接把 `sync.phase` 绑到 `Text`。
                    //   实时通道在弱网/重连时会**一秒内反复** ready↔degraded，
                    //   于是文案与状态点不停变、标题区高度也跟着变（英文/中文
                    //   文案长度不同 ⇒ 有时折成两行）⇒ 整页上下抖。
                    //   现在：先过 `_DebouncedPhase`（相位稳定 700ms 才上屏），
                    //   并且**定高单行**（省略号），高度永远不变。
                    DebouncedStatusLine(
                      status: sync.phase,
                      label: stateLabel,
                      color: stateColor,
                      fontSize: DesignType.labelSmallSize,
                    ),
                  ],
                ),
              ),
              HudIconButton(
                icon: Icons.search,
                tooltip: t.chatSearchMessages,
                onPressed: () => context.push(AppRoutes.search),
              ),
              HudIconButton(
                icon: Icons.refresh,
                tooltip: t.photoRefresh,
                onPressed: () =>
                    ref.read(chatSessionControllerProvider.notifier).refresh(),
              ),
              // 次要入口收进溢出菜单（tooltip/文案与原实现一致）
              PopupMenuButton<String>(
                tooltip: t.photoMore,
                position: PopupMenuPosition.under,
                onSelected: (value) async {
                  switch (value) {
                    case 'profile':
                      context.push(AppRoutes.profileEdit);
                    case 'create':
                      context.push(AppRoutes.channelCreate);
                    case 'join':
                      await _openAvailableChannels(context, ref);
                    case 'settings':
                      context.push(AppRoutes.settings);
                    case 'notifications':
                      context.push(AppRoutes.notifications);
                    case 'e2ee':
                      context.push(AppRoutes.e2ee);
                    case 'bots':
                      context.push(AppRoutes.bots);
                    // 跨频道内容面板（话题/书签/提醒/定时）—— 放在全局溢出菜单，
                    // 不新增底栏大 tab（见 docs/chat-p0b-implementation.md §3）
                    case 'global':
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const GlobalContentPage(),
                        ),
                      );
                    case 'archives':
                      context.push(AppRoutes.archives);
                    case 'logout':
                      // 先拆掉实时通道（socket + 订阅），再登出
                      ref.invalidate(chatSessionControllerProvider);
                      await ref
                          .read(sessionControllerProvider.notifier)
                          .logout();
                      if (context.mounted) context.go(AppRoutes.setup);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'profile',
                    child: DesignRowTile(
                      dense: true,
                      leading: const Icon(Icons.person_outline),
                      title: Text(t.meProfile),
                    ),
                  ),
                  if (canCreate)
                    PopupMenuItem(
                      value: 'create',
                      child: DesignRowTile(
                        dense: true,
                        leading: const Icon(Icons.add_comment_outlined),
                        title: Text(t.chatNewChannel),
                      ),
                    ),
                  if (canJoinPublic)
                    PopupMenuItem(
                      value: 'join',
                      child: DesignRowTile(
                        dense: true,
                        leading: const Icon(Icons.group_add_outlined),
                        title: Text(
                          dataText('chatJoinPublicChannel', '加入公开频道'),
                        ),
                      ),
                    ),
                  PopupMenuItem(
                    value: 'settings',
                    child: DesignRowTile(
                      dense: true,
                      leading: const Icon(Icons.settings_outlined),
                      title: Text(t.meSettings),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'notifications',
                    child: DesignRowTile(
                      dense: true,
                      leading: const Icon(Icons.notifications_outlined),
                      title: Text(t.setNotifications),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'e2ee',
                    child: DesignRowTile(
                      dense: true,
                      leading: const Icon(Icons.lock_outline),
                      title: Text(t.meE2ee),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'bots',
                    child: DesignRowTile(
                      dense: true,
                      leading: const Icon(Icons.smart_toy_outlined),
                      title: Text(t.botsTitle),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'archives',
                    child: DesignRowTile(
                      dense: true,
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: Text(t.meArchives),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'global',
                    child: DesignRowTile(
                      dense: true,
                      leading: const Icon(Icons.collections_bookmark_outlined),
                      title: Text(dataText('chatGlobalPanelTitle', '跨频道内容')),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'logout',
                    child: DesignRowTile(
                      dense: true,
                      leading: const Icon(Icons.logout),
                      title: Text(t.chatLogout),
                    ),
                  ),
                ],
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: Icon(
                      Icons.more_vert,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm + 2),
          // 滚动遥测带：**只放稳定事实**（地址 / 频道数 / 用户数）。
          // ★ r493：链路信息从"仪表遥测带"（等宽 + 字距 + 前缀码）改成
          //   普通的一行弱化文字。信息一个字没少，但不再是仪表盘造型。
          // ★ DA294：相位与 socket 状态**搬走了**（见标题下的 `_DebouncedPhase`
          //   与连接面板）——它们每秒会变好几次，留在这里会让 `Text` 在
          //   1↔2 行之间跳，把整页往下推。这一行现在**定高、单行**。
          SizedBox(
            height: _stripLineHeight(context),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                strip.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: DesignType.bodySmallSize,
                  color: hud.dim,
                ),
              ),
            ),
          ),
          // 错误槽**常驻定高**：出错只是"填字"，不改变布局（原来它是条件行，
          // 一出现就把整个列表往下推）。单行省略；完整原因在连接面板里。
          SizedBox(
            height: _stripLineHeight(context),
            child: sync.error == null
                ? null
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      sync.error!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ★ DA294：原 `_statusLine`（把相位翻成一句人话）已随"相位搬出遥测带"
  //   一起移除 —— 相位由标题下的 `_DebouncedPhase` 显示，断开原因在连接
  //   面板里（`chat_page` 的 `_showConnectionSheet` 自带同一套 switch）。
}

/// 分组量程标题（原版 `drawer_head` 的 `menu_title_unread` / `favorite` /
/// `channels` / `direct_message` / `chatbot`）。
///
/// 英文代号用 `TelemetryLabel`（量程），中文组名仍是**独立的 Text**：
/// 不能拼成一个字符串 —— 测试与辅助功能都靠 `find.text('频道')` 精确匹配。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.group,
    required this.collapsed,
    this.onToggle,
  });

  final SidebarGroup group;
  final bool collapsed;

  /// `null` = 这个组原版就没有展开箭头（未读 / synobot）
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    // ★ r344 D55：组头挂一个**身份** Key —— 原来用例靠 `find.text('机器人')` 找组头，
    //   而同一个词现在也会出现在「机器人」会话行的副标题上（那一行没有人数时就是
    //   一个裸的类型词）⇒ 用词找组头是**歧义判据**（§2.0.30「断言该钉机制量」）。
    // ★ r493：组头换成设计组件（`DesignSectionHeader`）。旧写法是
    //   "英文代号 + 等宽遥测字 + 渐隐量程尾线"的 HUD 仪表造型，与新行卡同屏
    //   是两种语言。这里只保留**信息**：折叠箭头、组名、条数。
    //
    //   ★ 身份 Key 必须留着（`channel-section-<group>`）：`channel_sort_test`
    //   靠它找组头，且"用词找组头"在本页是歧义判据（同一个词也会出现在行副标题）。
    return KeyedSubtree(
      key: Key('channel-section-${group.section.name}'),
      child: DesignSectionHeader(
        group.section.titleIn(context.t) ?? group.title ?? '',
        count: group.channels.length,
        collapsed: onToggle == null ? null : collapsed,
        onToggle: onToggle,
      ),
    );
  }
}

class _EmptyBody extends ConsumerWidget {
  const _EmptyBody({
    required this.sync,
    required this.canCreate,
    required this.canJoinPublic,
  });

  final ChatSyncState sync;
  final bool canCreate;
  final bool canJoinPublic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    // 建频道优先；没建频道权限但有加入公开频道权限时，给「加入公开频道」
    // （原版空列表同样只提供你**真的有权限**的那条路，不会给一个必吃 402 的按钮）
    final joinLabel = dataText('chatJoinPublicChannel', '加入公开频道');
    return AppEmptyState(
      icon: Icons.chat_bubble_outline,
      title: sync.busy ? t.chatSyncingChannels : t.chatNoChannels,
      message: sync.error,
      actionLabel: sync.busy
          ? null
          : canCreate
          ? t.chatNewChannel
          : canJoinPublic
          ? joinLabel
          : null,
      // ★ r320：这个入口的语义是"新建频道"或"加入公开频道"，**都不是重试** ⇒
      //   图标必须跟着分支走（共享组件默认的刷新圈会被读成"再同步一次"）。
      actionIcon: canCreate
          ? Icons.add
          : canJoinPublic
          ? Icons.login
          : Icons.refresh,
      onAction: sync.busy
          ? null
          : canCreate
          ? () => GoRouter.of(context).push(AppRoutes.channelCreate)
          : canJoinPublic
          ? () => _openAvailableChannels(context, ref)
          : null,
    );
  }
}

/// 打开「公开频道」完整浏览页（原版 `NamedChannelFragment`）。
///
/// 官方语义：`channel_join` **且** `channel_public` 才列出可加入的公开频道
/// （`NamedChannelFragment.java:165`）。入口按这两个键门控（见上方 `canJoinPublic`）。
///
/// 收尾遗留 3：P0-4 时这里只是一个底部弹层；现改为把完整页
/// `AvailableChannelsPage`（浏览 + 关键字过滤 + 空/错态 + 加入）推上去，
/// 弹层不再保留（审计原文自己写了"可整体替换"）。
Future<void> _openAvailableChannels(BuildContext context, WidgetRef ref) async {
  if (ref.read(chatApiProvider) == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(dataText('chatJoinPublicFailed', '加入频道失败，请稍后再试。')),
      ),
    );
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const AvailableChannelsPage()),
  );
}

/// 遥测带/错误槽的**定高**（跟随系统字号，避免 2.0 缩放下被裁掉）。
double _stripLineHeight(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return (DesignType.bodySmallSize * scale * 1.42).ceilToDouble() + 2;
}

// ★ DA294：相位的抖动抑制已抽成共享组件 `DebouncedStatusLine`
//   （`lib/src/core/ui/debounced_status_line.dart`）—— 那里有完整的三条规矩与
//   判据说明，别的"会抖的状态行"也应当复用它，而不是各自再写一套定时器。
