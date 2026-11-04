// 应用外壳：`聊天 · 文件 · 相册 · 工作台 · 我的`（用户已确认的信息架构）。
//
// 约定：
//   * 聊天仍是**第一个也是默认**的 tab（离线/无网络时聊天可用性最高）；
//   * 每个 tab 用 `IndexedStack` 保活，切回来时滚动位置与浏览栈都还在；
//   * 底栏自绘（不用 `NavigationBar`）以贴合 HUD 设计语言，但语义标签完整，
//     测试里可以直接 `find.text('文件')`。
//
// 模块批次（详见 docs/client-station-plan.md）：
//   P0 文件（FileStation）· P1 备注（NoteStation）· P2 相册（Photos）
//   P3 Drive / Office / 日历 / 联系人 · 管理员功能不在范围内
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../widgets/widget_snapshot_host.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/local/book_store.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../chat/channel_list_page.dart';
import '../chat/chat_session_controller.dart';
import '../chat/user_avatar.dart';
import '../../data/dto/user_dto.dart';
import '../audio/audio_mini_player.dart';
import '../audio/media_notification_tap_host.dart';
import '../audio/audio_page.dart';
import '../files/book_providers.dart' show recentBooksProvider;
import '../files/book_resume.dart' show bookProgressLabel, openBookProgress;
import '../files/file_browse_page.dart';
import '../files/file_pages.dart';
import '../calendar/calendar_page.dart';
import '../contacts/contacts_page.dart';
import '../downloads/download_page.dart';
import '../mailplus/mail_page.dart';
import '../notes/notes_page.dart';
import '../photos/photo_browse_page.dart';
import '../files/file_providers.dart';
import '../files/drive_browse_view.dart';
import '../servers/server_source_label.dart';
import '../servers/session_controller.dart';
import '../surveillance/surv_page.dart';
import 'app_tab.dart';
import 'service_gate_pages.dart';
import 'workspace_providers.dart';
import 'workspace_recent.dart';

// `AppTab` / `visibleTabs` 定义在 `app_tab.dart`（纯函数可单测）；
// 这里 export 让既有 `import app_shell_page.dart` 的调用方不受影响。
export 'app_tab.dart';

/// 当前 tab（跨页面可读写，例如"从搜索跳回文件"）
final appTabProvider = NotifierProvider<AppTabNotifier, AppTab>(
  AppTabNotifier.new,
);

class AppTabNotifier extends Notifier<AppTab> {
  @override
  AppTab build() => AppTab.chat;
  void select(AppTab tab) => state = tab;
}

class AppShellPage extends ConsumerWidget {
  const AppShellPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ★ 诊断（第 41 轮，临时）：真机自动化需要一个**状态闸门** ——
    //   冷启动落点不确定（频道详情页没有 tab 栏），靠固定 sleep 会点空。
    debugPrint('[route] shell tab=${ref.watch(appTabProvider)}');
    final tab = ref.watch(appTabProvider);
    final snapshot = ref.watch(serviceAvailabilityProvider);
    final showHidden = ref.watch(showHiddenServicesProvider);
    // ⚠️ index **必须由可见列表算**（不是固定 enum.index），否则隐藏后必然错位。
    final visible = visibleTabs(
      snapshot.resolvedStates,
      showHidden: showHidden,
    );
    var index = visible.indexOf(tab);
    final resolved = index >= 0 ? tab : visible.first;
    if (index < 0) {
      // 恢复态落在被隐藏的 tab → 回落到第一个可见 tab（不留空白页）。
      index = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        if (ref.read(appTabProvider) == tab) {
          ref.read(appTabProvider.notifier).select(visible.first);
        }
      });
    }

    // 主屏小组件快照的**唯一发布点**（P66 相册 / N1 笔记待办）。
    //
    // 之所以包在 shell 外层而不是各模块页面里：
    //   * 快照要在**任何** tab 下都保持最新，模块页会被 `IndexedStack` 保活/重建；
    //   * 桌面点击进来的落点（`photo:<id>` / `note:<id>`）需要一个**全局**的
    //     跳转处理者，放在 shell 才能切 tab 与压路由。
    // 副作用：`watchData` 默认 true 会让相册时间线 / 笔记 / 待办三个
    // autoDispose provider 在 shell 生命周期内常驻（提前加载）。
    // 这是一次**有意的取舍**：小组件要能显示数据就必须有人订阅，
    // 否则桌面永远停在"打开 App 登录后…"占位。
    // r653（`DA257`）：点通知栏的媒体卡要回到播放页。挂在这里而不是各页面里 ——
    // 它是**全局**的：用户可能在任意 tab / 任意深度的页面上点那张卡。
    return MediaNotificationTapHost(
      child: WidgetSnapshotHost(
        child: Scaffold(
        backgroundColor: DesignPalette.of(context).bg,
        // ★ r695（`DA336`）：`IndexedStack` 会把**所有** tab 保活，而聊天列表 /
        //   文件站 / 相册 / 笔记 / 下载各自的 `Scaffold` 都有自己的 FAB（默认 heroTag）。
        //   Hero 收集只看"当前路由子树"、不看 tab 是否可见 ⇒ 同一条路由里出现
        //   多个 `<default FloatingActionButton tag>`，**任何**一次路由转场都会在
        //   scheduler 回调里抛 "multiple heroes that share the same tag"。
        //   修法：看不见的 tab 用 `HeroMode(enabled: false)` 关掉 Hero 参与 ——
        //   这是 Flutter 给"同时活着但只有一个可见"准备的正规开关（不是加 heroTag
        //   糊过去：那样每个 tab 的 FAB 都要各自编号，漏一个就又撞）。
        body: IndexedStack(
          key: const Key('app-shell-stack'),
          index: index,
          children: [
            for (var i = 0; i < visible.length; i++)
              HeroMode(
                enabled: i == index,
                child: _pageFor(context, ref, visible[i], snapshot),
              ),
          ],
        ),
        // ★ r633：底栏之上常驻一条「正在播放」迷你条。
        //
        // 审计现场：电台在播时退回音乐列表/工作台，**整屏没有任何地方能看见它、
        // 也没有地方能暂停** —— 唯一出口是重新走回电台页。播放器类 App 都有这一条。
        // 没在播时 `AudioMiniPlayer` 返回 `SizedBox.shrink()`（零占位），
        // 所以既有页面几何与用例不受影响。
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const AudioMiniPlayer(),
              _AppDock(
                current: resolved,
                visible: visible,
                onSelect: (t) => _selectTab(ref, t),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 把一个 tab 映射成页面。
  ///
  /// 主槽服务处于 `sessionExpired` / `unreachable` / `unauthorized` 时，
  /// **直接返回可操作提示**而不是模块页 —— 既省一次构建，也避免模块页在
  /// 无权限 / 断网时闪错。
  Widget _pageFor(
    BuildContext context,
    WidgetRef ref,
    AppTab tab,
    ServiceAvailabilitySnapshot snapshot,
  ) {
    final service = serviceForTab(tab);
    if (service != null) {
      final st = snapshot.stateOf(service);
      // `sessionExpired` / `unreachable` → 所有模块 tab 统一给可操作提示；
      // `absent` / `unauthorized` 默认已被隐藏，只有安全阀放出来时才渲染模块本体。
      if (st == AvailabilityState.sessionExpired ||
          st == AvailabilityState.unreachable) {
        return ServiceStatusHint.forState(
          context,
          service,
          st,
          onAction: () => _onServiceAction(context, ref, st),
        );
      }
    }
    return _pageWidgetForTab(context, ref, tab);
  }

  /// tab → 模块页（不含可用性判断）。
  Widget _pageWidgetForTab(BuildContext context, WidgetRef ref, AppTab tab) =>
      switch (tab) {
        AppTab.chat => const ChannelListPage(),
        AppTab.files => const FileBrowsePage(),
        AppTab.photos => const _PhotosTab(),
        AppTab.workspace => const WorkspaceTab(),
        AppTab.me => const MeTab(),
        AppTab.home => RestrictedHomePage(
          onOpen: (service) => _openRestrictedService(context, ref, service),
        ),
        AppTab.note => const NotesPage(),
        AppTab.calendar => const CalendarPage(),
        AppTab.contacts => const ContactsPage(),
        AppTab.drive => const DriveBrowseTab(),
        AppTab.download => const DownloadPage(),
        AppTab.audio => const AudioPage(),
        AppTab.surveillance => const SurveillancePage(),
        AppTab.mailplus => const MailPage(),
      };

  /// 会话已过期 → 去登录页；其它（网络 / 无权限）→ 重新检测。
  void _onServiceAction(
    BuildContext context,
    WidgetRef ref,
    AvailabilityState state,
  ) {
    if (state == AvailabilityState.sessionExpired) {
      context.go(AppRoutes.login);
      return;
    }
    ref.read(serviceAvailabilityProvider.notifier).refresh();
  }

  /// 受限模式首页点"可用服务入口"：优先切到可见 tab，否则推模块页。
  void _openRestrictedService(
    BuildContext context,
    WidgetRef ref,
    StationService service,
  ) {
    final tab = kReplacementTabByService[service];
    if (tab == null) return;
    final snapshot = ref.read(serviceAvailabilityProvider);
    final visible = visibleTabs(snapshot.resolvedStates);
    if (visible.contains(tab)) {
      _selectTab(ref, tab);
      return;
    }
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (inner) => _pageWidgetForTab(inner, ref, tab),
      ),
    );
  }

  /// 切 tab = 用户**真的打开了这个模块** → 记一次工作台「最近常用」。
  ///
  /// 内容型 tab（聊天/文件/相册/顶替模块）都记；工作台/我的/首页不记。
  /// 工作台磁贴入口走 [_WorkspaceTabState._activate]。
  void _selectTab(WidgetRef ref, AppTab tab) {
    ref.read(appTabProvider.notifier).select(tab);
    if (tab.isContent) {
      unawaited(ref.read(workspaceRecentProvider.notifier).record(tab.name));
    }
  }
}

/// Drive 顶替 tab：Drive 没有独立页面，复用文件模块的 `DriveBrowseView`。
///
/// ⚠️ 这是 shell 侧**唯一**引用 `lib/src/features/files/**` 的地方（只读引用，
/// 未修改其内部渲染）。
class DriveBrowseTab extends StatelessWidget {
  const DriveBrowseTab({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: DesignPalette.of(context).bg,
    body: SafeArea(
      child: Column(
        children: [
          _TabTitle('Drive'),
          const Expanded(child: DriveBrowseView()),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------- 底栏

class _AppDock extends StatelessWidget {
  const _AppDock({
    required this.current,
    required this.visible,
    required this.onSelect,
  });

  /// 当前高亮 tab（保证一定在 [visible] 里）。
  final AppTab current;

  /// 由 [visibleTabs] 算出的可见 tab 列表 —— 底栏**只渲染它**，
  /// 不再遍历 `AppTab.values`（否则隐藏的 tab 会留下来）。
  final List<AppTab> visible;

  final ValueChanged<AppTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: DesignPalette.of(context).bg.withValues(alpha: 0.92),
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.25),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              for (final t in visible)
                Expanded(
                  child: InkWell(
                    key: Key('dock-${t.name}'),
                    onTap: () => onSelect(t),
                    child: Semantics(
                      selected: t == current,
                      button: true,
                      label: t.labelIn(context.t),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            t == current ? t.activeIcon : t.icon,
                            size: 22,
                            color: t == current ? scheme.primary : DesignPalette.of(context).dim,
                          ),
                          const SizedBox(height: 3),
                          // 底栏高度固定 58，而文字会跟随系统"字体大小"放大：
                          // 英文标签 + textScale 1.3/2.0 时这一列会纵向溢出。
                          // `Flexible` 给出剩余高度上限，`FittedBox.scaleDown`
                          // 只在放不下时等比缩小（1.0 缩放时完全不生效 → 外观不变）。
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                t.labelIn(context.t),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: t == current
                                          ? scheme.primary
                                          : DesignPalette.of(context).dim,
                                      fontWeight: t == current
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 相册

class _PhotosTab extends StatelessWidget {
  const _PhotosTab();

  @override
  Widget build(BuildContext context) => const PhotoBrowsePage();
}

// ---------------------------------------------------------------- 工作台

/// 工作台 —— **纯启动器**（用户 2026-09-19 拍板）：
///
///   * 只保留网格 launcher，**取消列表模式**（模块只会越来越多，列表迟早要滑好几屏；
///     需要"这个入口是干什么的"的说明时，进模块内部说）；
///   * 一屏放不下就**左右滑动翻屏**（PageView + 屏点指示）；
///   * **搜索吸顶常驻**：输入即筛模块，回车直接跳到文件搜索；
///   * 排序**按使用习惯学习**：用的是**时段加权**的使用频率（7 天半衰期的
///     等效次数，`workspaceUsageProvider`）＋ **25% 分档迟滞** —— 只有真的
///     比邻居高出 25% 才换位，所以点一下不会整屏乱跳；同档保持默认顺序，
///     新装时就是默认顺序。
class WorkspaceTab extends ConsumerStatefulWidget {
  const WorkspaceTab({super.key});

  @override
  ConsumerState<WorkspaceTab> createState() => _WorkspaceTabState();
}

class _WorkspaceTabState extends ConsumerState<WorkspaceTab> {
  final _search = TextEditingController();
  final _pager = PageController();
  int _page = 0;

  /// 本会话的**排序基准**（r661：图标不许在用户眼皮底下漂）
  ///
  /// 统计是"用了就更靠前"，但**点完就重排**等于把磁贴从用户手指底下抽走：
  /// 他刚点过的那格会跳到别处，下次想再点就得重新找。所以排序只在**冷启动**
  /// 定一次（`preload` 那一拍），本次运行期间打开多少次都不再换位；
  /// 下次启动时按最新的时段加权分数重排。
  Map<String, UsageStat>? _orderBasis;

  @override
  void dispose() {
    _search.dispose();
    _pager.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim();

  @override
  Widget build(BuildContext context) {
    final liveUsage = ref.watch(workspaceUsageProvider);
    // 还没 preload 完（空集）就先用默认顺序；第一次拿到非空统计就定格，
    // 之后本次运行期间不再跟着点击变（详见 [_orderBasis]）。
    if (liveUsage.isNotEmpty) _orderBasis ??= liveUsage;
    final usage = _orderBasis ?? const <String, UsageStat>{};
    final hidden = ref.watch(workspaceHiddenProvider);
    final everyEntry = _entries(context, ref);
    // 「最近常用」= 最近真的打开过的入口（倒序）；「继续阅读」= E1 落库的阅读进度
    final recentUses = ref.watch(workspaceRecentProvider);
    final recentBooks =
        ref.watch(recentBooksProvider).value ?? const <BookProgress>[];
    // 「使用分析」的结论可以一键把"从没用过的模块"收进第二屏（本地偏好，随时可还原）；
    // 搜索时不受影响，保证"藏起来的也能搜到"。
    final hiddenCount = everyEntry.where((i) => hidden.contains(i.id)).length;
    final all = hiddenCount == 0
        ? everyEntry
        : [
            for (final i in everyEntry)
              if (!hidden.contains(i.id)) i,
          ];
    final q = _query.toLowerCase();
    final items = q.isEmpty
        ? sortByUsage(all, (i) => i.id, usage)
        : [
            for (final i in everyEntry)
              if (i.matches(q)) i,
          ];
    // 搜索时不留动态分区（用户是在找模块，不是看记录）
    final recentModules = q.isEmpty
        ? _recentItems(
            recentUses,
            everyEntry,
            ref.watch(serviceAvailabilityProvider).resolvedStates,
            ref.watch(showHiddenServicesProvider),
          )
        : const <_WsItem>[];

    return Scaffold(
      backgroundColor: DesignPalette.of(context).bg,
      body: SafeArea(
          child: Column(
            children: [
              _TabTitle(context.t.navWorkspace),
              _WorkspaceSearchBar(
                controller: _search,
                onChanged: (_) => setState(() => _page = 0),
                onSubmitted: (v) => _openFileSearch(v),
                onClear: () => setState(() {
                  _search.clear();
                  _page = 0;
                }),
              ),
              if (q.isEmpty &&
                  (recentModules.isNotEmpty || recentBooks.isNotEmpty))
                _RecentSection(
                  modules: recentModules,
                  books: recentBooks,
                  onModule: _activate,
                  onBook: _openBook,
                ),
              if (q.isEmpty && hiddenCount > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
                  child: Row(
                    children: [
                      Icon(
                        Icons.visibility_off_outlined,
                        size: 16,
                        color: DesignPalette.of(context).dim,
                      ),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(
                          context.t.wsHiddenCount(hiddenCount),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: DesignPalette.of(context).dim),
                        ),
                      ),
                      TextButton(
                        onPressed: () => ref
                            .read(workspaceHiddenProvider.notifier)
                            .showAll(),
                        child: Text(context.t.wsShowAll),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: q.isNotEmpty && items.isEmpty
                    ? _NoMatch(query: _query, onSearchFiles: _openFileSearch)
                    : LayoutBuilder(
                        builder: (context, c) => _launcher(c, items),
                      ),
              ),
            ],
          ),
        ),
    );
  }

  // ------------------------------------------------------------ 分屏启动器

  Widget _launcher(BoxConstraints c, List<_WsItem> items) {
    // ★ DA292：列数原来**写死 2 列**。手机上正好，到了 macOS/Linux 的
    //   1000–1600dp 宽窗口，每格就有 450–780dp 宽、280dp 高 —— 卡片里
    //   一大半是空白（用户原话：「App 的卡片太大了，大部分都是空白」）。
    //   现在按窗口宽度算列数：单格目标 ≥260dp（再窄副标题就挤），
    //   最多 6 列；高度跟着变窄后**封顶**，不再随宽度二次放大。
    final scale0 = MediaQuery.textScalerOf(context).scale(1);
    final geo = workspaceTileGeometry(c.maxWidth, scale0);
    final cols = geo.columns;
    // 卡片比例沿用 1.55（比正方形略矮，一屏能多放一行）；但窄屏下这个比例会把
    // 副标题裁掉，所以给一个内容放得下的下限（图标 38 + 标题 + 副标题 + 内边距）。
    //
    // ⚠️ 下限必须跟随 `textScaler`：固定的 104 在 2.0 缩放下装不下"图标 +
    // 标题 + 副标题"三行（离线矩阵实测 RenderFlex overflowed）。这是 UI 审计
    // 的同一族问题（固定尺寸容器 + 跟随系统字号的文字），也是工作台此前
    // 没有被矩阵覆盖到的原因之一（`AppShellPage` 默认 tab 不是工作台）。
    // 比例 1.55（比正方形略矮）；下限保证内容放得下；**上限**保证宽窗里
    // 卡片不会长成一块空地（DA292）。三条都在 `workspaceTileGeometry()` 里。
    final tileH = geo.tileHeight;
    const dotH = 20.0;

    int rowsFor(double h) =>
        ((h + Gap.sm) / (tileH + Gap.sm)).floor().clamp(1, 99);
    var rows = rowsFor(c.maxHeight);
    var pages = (items.length / (rows * cols)).ceil().clamp(1, 99);
    // 有第二屏才给屏点留高度；留完可能少一行 → 重新算一次
    if (pages > 1) {
      rows = rowsFor(c.maxHeight - dotH);
      pages = (items.length / (rows * cols)).ceil().clamp(1, 99);
    }
    final perPage = rows * cols;

    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            key: const Key('ws-pager'),
            controller: _pager,
            itemCount: pages,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, p) {
              final start = p * perPage;
              final slice = items.sublist(
                start,
                (start + perPage).clamp(0, items.length),
              );
              return GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisExtent: tileH,
                  mainAxisSpacing: Gap.sm,
                  crossAxisSpacing: Gap.sm,
                ),
                itemCount: slice.length,
                itemBuilder: (context, i) => _WsTile(
                  key: Key('ws-tile-${slice[i].id}'),
                  item: slice[i],
                  onTap: () => _activate(slice[i]),
                ),
              );
            },
          ),
        ),
        if (pages > 1)
          _PageDots(count: pages, current: _page.clamp(0, pages - 1)),
      ],
    );
  }

  // ------------------------------------------------------------ 入口定义

  List<_WsItem> _entries(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final tasks = ref.watch(fileTasksProvider);
    final running = tasks.value?.where((t) => !t.finished).length ?? 0;
    final snapshot = ref.watch(serviceAvailabilityProvider);
    final showHidden = ref.watch(showHiddenServicesProvider);
    final states = snapshot.resolvedStates;

    // 未安装（absent）/ 无权限（unauthorized）→ 入口**隐藏**；
    // 安全阀打开时（showHidden）临时恢复可见。
    bool hidden(StationService service) =>
        !showHidden &&
        hidesModule(states[service] ?? AvailabilityState.unknown);

    // 可选能力位缺失 → 只在"确定检测过"时隐藏该功能入口
    // （unknown / unreachable / sessionExpired 一律不降级，避免误藏）。
    bool missingOptional(StationService service, String api) {
      final st = states[service] ?? AvailabilityState.unknown;
      final certain =
          st == AvailabilityState.available || st == AvailabilityState.partial;
      return certain && !hidden(service) && !snapshot.hasApi(service, api);
    }

    // 会话失效 / 网络异常 → 入口**保留但置灰** + 一句话原因（不隐藏）。
    String? reason(StationService service) =>
        entryDisabledReason(t, states[service] ?? AvailabilityState.unknown);
    VoidCallback? gate(StationService service, VoidCallback onTap) =>
        reason(service) != null ? null : onTap;

    final items = <_WsItem>[];

    void add(_WsItem item) => items.add(item);

    // ---- 文件（File Station，主槽）
    if (!hidden(StationService.file)) {
      add(
        _WsItem(
          id: 'files',
          icon: Icons.folder_outlined,
          title: t.wsFiles,
          short: reason(StationService.file) ?? 'File Station · Drive',
          onTap: gate(
            StationService.file,
            () => ref.read(appTabProvider.notifier).select(AppTab.files),
          ),
        ),
      );
    }
    // ---- 笔记
    if (!hidden(StationService.note)) {
      add(
        _WsItem(
          id: 'notes',
          icon: Icons.sticky_note_2_outlined,
          title: t.wsNotes,
          short: reason(StationService.note) ?? 'NoteStation',
          onTap: gate(
            StationService.note,
            () => _push(context, const NotesPage()),
          ),
        ),
      );
    }
    // ---- 相册（主槽）
    if (!hidden(StationService.photo)) {
      add(
        _WsItem(
          id: 'photos',
          icon: Icons.photo_library_outlined,
          title: t.wsPhotos,
          short: reason(StationService.photo) ?? 'SynologyPhotos',
          onTap: gate(
            StationService.photo,
            () => ref.read(appTabProvider.notifier).select(AppTab.photos),
          ),
        ),
      );
    }
    // ---- 联系人
    if (!hidden(StationService.contacts)) {
      add(
        _WsItem(
          id: 'contacts',
          icon: Icons.contacts_outlined,
          title: t.wsContacts,
          short: reason(StationService.contacts) ?? 'Contacts',
          onTap: gate(
            StationService.contacts,
            () => _push(context, const ContactsPage()),
          ),
        ),
      );
    }
    // ---- 日历
    if (!hidden(StationService.calendar)) {
      add(
        _WsItem(
          id: 'calendar',
          icon: Icons.event_outlined,
          title: t.wsCalendar,
          short: reason(StationService.calendar) ?? 'Calendar',
          onTap: gate(
            StationService.calendar,
            () => _push(context, const CalendarPage()),
          ),
        ),
      );
    }
    // ---- Office / Drive 不再是工作台磁贴（2026-09-22 用户拍板）
    //
    // 用户原话：「Office 的入口在 Drive 里，为啥要独立出来？官方也没有独立出来啊？」
    // 官方证据：Office 包自述 "…in Synology Drive"、带 `drive/hook/libsynoffice_drivehook.so`、
    // 前端有 `SYNO.SDS.Office.Utils.isDrivePage`——Office 的用户入口本来就在 Drive 里。
    // 现在工作台只保留 11 个入口；Office 入口移进 `DriveMorePage`
    // （`lib/src/features/files/drive_more_page.dart` 的 `drive-more-office`）。
    // ---- 后台任务（File Station.BackgroundTask 可选能力位）
    if (!hidden(StationService.file) &&
        !missingOptional(
          StationService.file,
          'SYNO.FileStation.BackgroundTask',
        )) {
      add(
        _WsItem(
          id: 'tasks',
          icon: Icons.sync,
          title: t.wsTasks,
          short:
              reason(StationService.file) ??
              (running > 0
                  ? t.wsTasksRunning(running)
                  : (tasks.value?.isEmpty ?? true
                        ? t.wsTasksNone
                        : t.wsTasksDone)),
          badge: running > 0 ? running : null,
          onTap: gate(
            StationService.file,
            () => _push(context, const FileTasksPage()),
          ),
        ),
      );
    }
    // ---- 搜索文件（File Station.Search 可选能力位；缺则入口隐藏）
    if (!hidden(StationService.file) &&
        !missingOptional(StationService.file, 'SYNO.FileStation.Search')) {
      add(
        _WsItem(
          id: 'search',
          icon: Icons.search,
          title: t.wsSearchFiles,
          // ★ DA192：这里原来用 `wsSearchFilesHint`（"Search permitted folders by
          //   file name"，36 字符）当卡片副标题 —— 整句话塞进半宽卡片，真机截成
          //   "Search permitted fold…"（§2.0.18：固定预算里改文案，不缩字号）。
          short: reason(StationService.file) ?? t.wsSearchFilesShort,
          onTap: gate(
            StationService.file,
            () => _push(context, const FileSearchPage()),
          ),
        ),
      );
    }
    // ---- Download Station
    if (!hidden(StationService.download)) {
      add(
        _WsItem(
          id: 'downloads',
          icon: Icons.download_outlined,
          title: t.dsTitle,
          short: reason(StationService.download) ?? 'DownloadStation',
          onTap: gate(
            StationService.download,
            () => _push(context, const DownloadPage()),
          ),
        ),
      );
    }
    // ---- Audio Station
    if (!hidden(StationService.audio)) {
      add(
        _WsItem(
          id: 'audio',
          icon: Icons.library_music_outlined,
          title: t.asTitle,
          short: reason(StationService.audio) ?? 'AudioStation',
          onTap: gate(
            StationService.audio,
            () => _push(context, const AudioPage()),
          ),
        ),
      );
    }
    // ---- Surveillance Station
    if (!hidden(StationService.surveillance)) {
      add(
        _WsItem(
          id: 'surveillance',
          icon: Icons.videocam_outlined,
          title: t.survTitle,
          short: reason(StationService.surveillance) ?? 'SurveillanceStation',
          onTap: gate(
            StationService.surveillance,
            () => _push(context, const SurveillancePage()),
          ),
        ),
      );
    }
    // ---- MailPlus
    if (!hidden(StationService.mailplus)) {
      add(
        _WsItem(
          id: 'mailplus',
          icon: Icons.mail_outline,
          title: t.mailTitle,
          short: reason(StationService.mailplus) ?? 'MailPlus',
          onTap: gate(
            StationService.mailplus,
            () => _push(context, const MailPage()),
          ),
        ),
      );
    }
    return items;
  }

  /// 把「最近常用」的 id 还原成可点的入口 id 还原成可点的入口（网格里有的直接用，聊天走底栏 tab）
  List<_WsItem> _recentItems(
    List<WorkspaceRecent> uses,
    List<_WsItem> all,
    Map<StationService, AvailabilityState> states,
    bool showHidden,
  ) {
    if (uses.isEmpty) return const [];
    final byId = {for (final e in all) e.id: e};
    final out = <_WsItem>[];
    for (final u in uses) {
      final item = byId[u.id] ?? _shellEntry(u.id, states, showHidden);
      if (item != null) out.add(item);
    }
    return out;
  }

  /// 「最近常用」里可能出现、但**不在工作台网格**里的入口（底栏的内容 tab）。
  ///
  /// 服务被判隐藏（未安装 / 无权限）→ 这里也一并收起（矩阵 #2 的"工作台聊天
  /// 入口消失"就是这条）；`sessionExpired` / `unreachable` 保留但置灰。
  _WsItem? _shellEntry(
    String id,
    Map<StationService, AvailabilityState> states,
    bool showHidden,
  ) {
    final t = context.t;
    switch (id) {
      case 'chat':
        final st = states[StationService.chat] ?? AvailabilityState.unknown;
        if (!showHidden && hidesModule(st)) return null;
        final reason = entryDisabledReason(t, st);
        return _WsItem(
          id: id,
          icon: Icons.forum_outlined,
          title: t.navChat,
          short: reason ?? 'SynologyChat',
          onTap: reason != null
              ? null
              : () => ref.read(appTabProvider.notifier).select(AppTab.chat),
        );
      default:
        return null;
    }
  }

  /// 点「继续阅读」：直接开阅读器（`FileBookStage` 自己恢复上次那一章）
  void _openBook(BookProgress progress) => openBookProgress(context, progress);

  /// 点入口：**先记一次使用**（排序用），再执行动作
  ///
  /// 顺手清掉搜索框：用户是"筛出这个模块然后进去"，回来时应该看到完整启动器，
  /// 而不是还停在只剩一个磁贴的筛选态。
  void _activate(_WsItem item) {
    unawaited(ref.read(workspaceUsageProvider.notifier).record(item.id));
    // 「最近常用」记的是"最近真的打开过谁"（时间倒序），与次数统计分开
    unawaited(ref.read(workspaceRecentProvider.notifier).record(item.id));
    // 使用日志：工作台入口点击（`object` 记入口 id，不记名字以外的东西）
    track(
      ref,
      UsageModule.workspace,
      UsageAction.open,
      objectType: item.id,
      detail: {'entry': item.id},
    );
    if (_search.text.isNotEmpty) {
      setState(() {
        _search.clear();
        _page = 0;
      });
    }
    item.onTap?.call();
  }

  void _openFileSearch(String keyword) {
    final k = keyword.trim();
    if (k.isEmpty) return;
    _push(context, FileSearchPage(initialQuery: k));
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

/// 屏点指示（第二屏起才显示）
class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.current});

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              key: Key('ws-dot-$i'),
              width: i == current ? 16 : 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: i == current
                    ? scheme.primary
                    : DesignPalette.of(context).dim.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}

/// 吸顶搜索条：常驻在标题下面，输入即筛模块，回车去文件搜索
class _WorkspaceSearchBar extends StatelessWidget {
  const _WorkspaceSearchBar({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
      child: TextField(
        key: const Key('ws-search'),
        controller: controller,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          hintText: context.t.wsSearchHint,
          hintStyle: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
          prefixIcon: Icon(Icons.search, size: 18, color: DesignPalette.of(context).dim),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  key: const Key('ws-search-clear'),
                  tooltip: context.t.calEnvClear,
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: onClear,
                ),
          filled: true,
          fillColor: DesignPalette.of(context).surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          // 白底 + 1px 描边：亮色下没有描边的白框在 `#E9EEF5` 上只剩一条"浅影"
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.capsule),
            borderSide: BorderSide(color: DesignPalette.of(context).line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.capsule),
            borderSide: BorderSide(color: DesignPalette.of(context).line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.capsule),
            borderSide: BorderSide(color: DesignPalette.of(context).primary),
          ),
        ),
      ),
    );
  }
}

/// 搜索没有命中任何模块时的提示（并把关键词交给文件搜索）
class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.query, required this.onSearchFiles});

  final String query;
  final ValueChanged<String> onSearchFiles;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 36, color: DesignPalette.of(context).dim),
            const SizedBox(height: Gap.md),
            Text(
              context.t.wsNoMatch,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: Gap.md),
            FilledButton.tonalIcon(
              onPressed: () => onSearchFiles(query),
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(context.t.wsSearchInFiles(query)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 工作台顶部的动态分区：**最近常用**（模块）+ **继续阅读**（书）。
///
/// 两种卡片同属一块 UI：都没有记录时整块不渲染（不留空白），
/// 有序内容横向滑动，点一下直达（模块）/ 直接进阅读器（书）。
class _RecentSection extends StatelessWidget {
  const _RecentSection({
    required this.modules,
    required this.books,
    required this.onModule,
    required this.onBook,
  });

  final List<_WsItem> modules;
  final List<BookProgress> books;
  final ValueChanged<_WsItem> onModule;
  final ValueChanged<BookProgress> onBook;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (modules.isNotEmpty) ...[
          _StripLabel(t.wsRecentTitle),
          SizedBox(
            height: 58,
            child: ListView.separated(
              key: const Key('ws-recent-list'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              itemCount: modules.length,
              separatorBuilder: (_, __) => const SizedBox(width: Gap.sm),
              itemBuilder: (_, i) => _RecentModuleTile(
                item: modules[i],
                onTap: () => onModule(modules[i]),
              ),
            ),
          ),
          const SizedBox(height: Gap.md),
        ],
        if (books.isNotEmpty) ...[
          _StripLabel(t.bookContinueTitle),
          SizedBox(
            height: 58,
            child: ListView.separated(
              key: const Key('ws-continue-list'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              itemCount: books.length,
              separatorBuilder: (_, __) => const SizedBox(width: Gap.sm),
              itemBuilder: (_, i) => _ContinueBookTile(
                book: books[i],
                onTap: () => onBook(books[i]),
              ),
            ),
          ),
          const SizedBox(height: Gap.md),
        ],
      ],
    );
  }
}

/// 动态分区的小标题（"最近常用" / "继续阅读"）
class _StripLabel extends StatelessWidget {
  const _StripLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: DesignPalette.of(context).dim,
        letterSpacing: 1,
      ),
    ),
  );
}

/// 「最近常用」里的一张小卡（图标 + 模块名）
class _RecentModuleTile extends StatelessWidget {
  const _RecentModuleTile({required this.item, required this.onTap});

  final _WsItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: Key('ws-recent-${item.id}'),
      // ★ r498：`surfaceContainerHigh @0.4` 在亮色下几乎等于底色（卡片"看不见"）。
      //   设计语言的卡片是 **surface 底 + 1px line 描边 + 圆角 13**，照它写。
      color: DesignPalette.of(context).surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: BorderSide(color: DesignPalette.of(context).line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pane),
        child: SizedBox(
          width: 126,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Row(
              children: [
                Icon(item.icon, size: 18, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「继续阅读」里的一张小卡（书名 + 第几章 / 百分比）
class _ContinueBookTile extends StatelessWidget {
  const _ContinueBookTile({required this.book, required this.onTap});

  final BookProgress book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final title = book.title.trim().isEmpty
        ? context.t.bookUntitled
        : book.title.trim();
    return Material(
      key: Key('ws-continue-${book.bookKey}'),
      // ★ r498：`surfaceContainerHigh @0.4` 在亮色下几乎等于底色（卡片"看不见"）。
      //   设计语言的卡片是 **surface 底 + 1px line 描边 + 圆角 13**，照它写。
      color: DesignPalette.of(context).surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: BorderSide(color: DesignPalette.of(context).line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pane),
        child: SizedBox(
          width: 196,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Row(
              children: [
                Icon(Icons.menu_book_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        bookProgressLabel(context.t, book),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: DesignPalette.of(context).dim,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 工作台的一个入口（纯启动器磁贴）
class _WsItem {
  const _WsItem({
    required this.id,
    required this.icon,
    required this.title,
    required this.short,
    this.badge,
    this.onTap,
  });

  /// 使用统计用的稳定 id（排序靠它，改文案不影响计数）
  final String id;

  final IconData icon;
  final String title;

  /// 磁贴下面的一句话（模块名或状态）
  final String short;

  /// 右上角数字角标（比如"3 个后台任务"）
  final int? badge;

  /// null = 还没接入 / 无权限：置灰且点不动
  final VoidCallback? onTap;

  bool get enabled => onTap != null;

  /// 搜索命中（标题或副标题里有这个词，大小写不敏感）
  bool matches(String query) =>
      title.toLowerCase().contains(query) ||
      short.toLowerCase().contains(query) ||
      id.contains(query);
}

/// 网格里的一个模块磁贴
class _WsTile extends StatelessWidget {
  const _WsTile({super.key, required this.item, this.onTap});

  final _WsItem item;

  /// 由父层传入：先记一次使用统计，再执行入口动作
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Opacity(
      opacity: item.enabled ? 1 : 0.45,
      child: Material(
        color: DesignPalette.of(context).surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(color: DesignPalette.of(context).line),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.pane),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 图标放在一个圆角方块里 —— 启动器的"图标位"
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(Radii.pane * 0.6),
                      ),
                      child: Icon(item.icon, size: 21, color: scheme.primary),
                    ),
                    const Spacer(),
                    if (item.badge != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          '${item.badge}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.short,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 我的

/// 「我的」—— 账号信息 + 原有设置入口（不再重复实现设置页）
class MeTab extends ConsumerWidget {
  const MeTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionControllerProvider);
    final account = state.session?.account ?? '';
    // 显示实际连上的地址（QuickConnect 打洞后可能是内网 IP，也可能是域名）
    final endpoint = state.connection?.endpoint;
    final host = endpoint == null
        ? ''
        // ★ r343 D54：`source` 是内部 token ⇒ 走唯一的标签生产者。
        : '${endpoint.baseUrl} · ${connectSourceLabel(endpoint.source, context.t)}';
    // 自己的 Chat user（头像/昵称）—— `User/set` 后 avatar_version 变了会自
    // 动重新取图（见 `user_avatar.dart` 的缓存键）
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    final myUserId = ref.watch(chatSessionControllerProvider).myUserId;
    UserDto? me;
    for (final u in users) {
      if (u.userId == myUserId) {
        me = u;
        break;
      }
    }

    return Scaffold(
      backgroundColor: DesignPalette.of(context).bg,
      body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _TabTitle(context.t.navMe),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                child: Row(
                  children: [
                    UserAvatar(
                      size: 52,
                      user: me,
                      fallbackLabel: account,
                      background: me == null
                          ? null
                          : userAvatarColor(me, Theme.of(context)),
                      semanticLabel: account.isEmpty ? null : account,
                    ),
                    const SizedBox(width: Gap.md),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account.isEmpty ? context.t.meNotLoggedIn : account,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        // ★ r497：NAS 地址是**信息**不是装饰 —— 保留，但改用设计令牌
                        //   （原来是等宽遥测小字 `TelemetryLabel`）。
                        if (host.isNotEmpty)
                          Text(
                            host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: DesignType.bodySmallSize,
                              color: DesignPalette.of(context).muted,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.lg),
              _SectionLabel(context.t.meAccount),
              _Card(
                icon: Icons.badge_outlined,
                title: context.t.meProfile,
                subtitle: context.t.meProfileHint,
                onTap: () => context.push(AppRoutes.profileEdit),
              ),
              _Card(
                icon: Icons.notifications_none,
                title: context.t.meNotifications,
                subtitle: context.t.meNotificationsHint,
                onTap: () => context.push(AppRoutes.snooze),
              ),
              _Card(
                icon: Icons.lock_outline,
                title: context.t.meE2ee,
                subtitle: context.t.meE2eeHint,
                onTap: () => context.push(AppRoutes.e2ee),
              ),
              _SectionLabel(context.t.meApp),
              _Card(
                icon: Icons.settings_outlined,
                title: context.t.meSettings,
                subtitle: context.t.meSettingsHint,
                onTap: () => context.push(AppRoutes.settings),
              ),
              _Card(
                icon: Icons.verified_user_outlined,
                title: context.t.meCertificates,
                subtitle: context.t.meCertificatesHint,
                onTap: () => context.push(AppRoutes.certificates),
              ),
              _Card(
                icon: Icons.storage_outlined,
                title: context.t.meArchives,
                subtitle: context.t.meArchivesHint,
                onTap: () => context.push(AppRoutes.archives),
              ),
            ],
          ),
        ),
    );
  }
}

// ---------------------------------------------------------------- 小件

class _TabTitle extends StatelessWidget {
  // ★ r497：**右侧那个遥测代号（`DRIVE` / `WORKSPACE` / `PROFILE`）删掉了**。
  //   它是 HUD 的"仪表编号"装饰，与新设计语言的页头（只有标题）打架，
  //   真机上 Me 页右上角那串等宽大写字母就是它。
  const _TabTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.md),
      // ★ 撑满宽度：`Column` 的默认 `crossAxisAlignment` 是 center，
      //   不撑满时标题会**居中**（Workspace 页真机就是居中的，与 Files/Chat 页
      //   的左对齐不一致）。设计语言里页头一律左对齐。
      child: SizedBox(
        width: double.infinity,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// 分区标题（Me 页的 Account / App）—— 直接用设计组件，
/// 不再自己写"labelMedium + 1.0 字距"的 HUD 造型。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => DesignSectionHeader(text);
}

class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Material(
          color: DesignPalette.of(context).surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
            side: BorderSide(color: DesignPalette.of(context).line),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.pane),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: scheme.primary),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: DesignPalette.of(context).dim),
                        ),
                      ],
                    ),
                  ),
                  if (enabled)
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: DesignPalette.of(context).dim,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 工作台磁贴几何（DA292）——**纯函数**，好让宿主用例按任意窗口宽验算。
///
/// * 列数 = 可用宽度 / (最小格宽 260 + 间距)，夹在 2..6；
/// * 卡片高度 = 宽/1.55，并**夹在** `104*scale .. 200*scale`（宽窗里不许长成空地）；
/// * `textScale` 参与下限：2.0 缩放下三行文字要放得下。
class WorkspaceTileGeometry {
  const WorkspaceTileGeometry({
    required this.columns,
    required this.tileWidth,
    required this.tileHeight,
  });

  final int columns;
  final double tileWidth;
  final double tileHeight;
}

WorkspaceTileGeometry workspaceTileGeometry(
  double maxWidth,
  double textScale, {
  double gapLg = Gap.lg,
  double gapSm = Gap.sm,
}) {
  final usable = maxWidth - gapLg * 2;
  const minTileW = 260.0;
  final cols = (usable / (minTileW + gapSm)).floor().clamp(2, 6);
  final tileW = (usable - gapSm * (cols - 1)) / cols;
  final tileH = math
      .max(tileW / 1.55, 104.0 * textScale)
      .clamp(104.0 * textScale, 200.0 * textScale)
      .toDouble();
  return WorkspaceTileGeometry(
    columns: cols,
    tileWidth: tileW,
    tileHeight: tileH,
  );
}
