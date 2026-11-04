// Download Station 任务列表页（阶段二 A 的第一块，只做普通用户功能）。
//
// 接口事实来源：`docs/stage2-audio-download-api.md`
//   * 列表 = `SYNO.DownloadStation2.Task.list` v2（root `task` + `total`）；
//   * 暂停/继续 = `Task.pause`/`resume` v2；删除 = `Task.delete` v2（`force_complete=false`）；
//   * 顶部速率 = `Task.Statistic.get` v1。
//
// 页面结构对齐现有模块（见 `features/files/drive_tasks_page.dart`、
// `features/search/search_page.dart`）：分类筛选 · 触底分页 · 下拉刷新 ·
// 空态/错误态（**区分套件未安装/无权限/网络失败**）· 危险操作二次确认。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/ui/adaptive_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../admin/admin_gate.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../shell/capability_hint.dart';
import 'download_bt_search_page.dart';
import 'download_captcha_page.dart';
import 'download_completion.dart';
import 'download_create_page.dart';
import 'download_link_browser.dart';
import 'download_emule_page.dart';
import 'download_detail_page.dart';
import 'download_labels.dart';
import 'download_providers.dart';
import 'download_rss_page.dart';
import 'download_settings_page.dart';

/// `Task/edit` 的 `priority` 取值 —— 逐字照官方 `aMule.EditTaskWindow.getPriorityDS()`：
/// `low` / `normal` / `high` / `auto`（默认 `auto`）。**只有 eMule 任务会用到**。
const List<String> _dsEditPriorities = ['auto', 'normal', 'low', 'high'];

/// 「改目的地 / 优先级 / 解压密码」对话框的返回值。
///
/// `priority` / `extractPassword` 为 `null` = **不下发该字段**
/// （官方只在相应字段"被改过"时才带上；空值不许造成空写）。
class _DsEditTaskResult {
  const _DsEditTaskResult({
    required this.destination,
    this.priority,
    this.extractPassword,
  });

  final String destination;
  final String? priority;
  final String? extractPassword;
}

class DownloadPage extends ConsumerStatefulWidget {
  const DownloadPage({super.key});

  @override
  ConsumerState<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends ConsumerState<DownloadPage>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  bool _searching = false;

  /// F12：完成/失败轮询定时器（服务端没有完成事件推送，只能轮询 `Task/list`）。
  Timer? _completionTimer;

  @override
  void dispose() {
    _completionTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    trackView(UsageModule.downloads, screen: 'list');
    WidgetsBinding.instance.addObserver(this);
    // build 里不能发请求，首帧之后再拉第一页。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 能力位降级（S2）：`Task.List` 明确缺失时不发这次注定 102 的请求。
      final canTaskList = ref
          .read(serviceAvailabilityProvider)
          .hasApi(StationService.download, kDownloadTaskListApi);
      if (canTaskList) ref.read(downloadListProvider.notifier).load();
      // F12：把"完成提醒"开关的持久化值读进来。
      ref.read(downloadNotifyProvider.notifier).preload();
    });
    // F12：按可配置间隔轮询"刚刚完成/失败"的任务。
    _completionTimer = Timer.periodic(
      ref.read(downloadCompletionPollIntervalProvider),
      (_) => _pollCompletions(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从后台回来：立刻补一次（后台期间可能已经完成）。
    if (state == AppLifecycleState.resumed) _pollCompletions();
  }

  Future<void> _pollCompletions() async {
    if (!mounted) return;
    await ref
        .read(downloadCompletionProvider.notifier)
        .poll(enabled: ref.read(downloadNotifyProvider));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    // F12：有"刚刚完成/失败"的任务 → 应用内提示（消费掉事件，不重复弹）。
    ref.listen(downloadCompletionProvider, (_, next) {
      if (next.pending.isEmpty) return;
      final events = ref.read(downloadCompletionProvider.notifier).consume();
      if (events.isEmpty || !mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      for (final e in events) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              e.failed
                  ? dataText(
                      'dsNotifyFailed',
                      '下载失败：{name}',
                    ).replaceAll('{name}', e.title)
                  : dataText(
                      'dsNotifyFinished',
                      '下载完成：{name}',
                    ).replaceAll('{name}', e.title),
            ),
          ),
        );
      }
    });
    final state = ref.watch(downloadListProvider);
    final api = ref.watch(downloadApiProvider);
    final installed = api == null || api.installed;
    // 可选能力位：`SYNO.DownloadStation2.Task.List`（任务列表轮询）。
    // 缺失时模块本身照常显示，只把任务列表换成一句原因。
    final canTaskList = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.download, kDownloadTaskListApi);
    // 需要验证码的任务数（wave5）。
    //   主判据：`Captcha:list` v2 的 `task_ids`（官方 JS 的工具栏计数同源）；
    //   兜底判据：已有任务里状态 `15 = captchaNeeded` —— 即使 `Captcha` 取不到，
    //   入口也**不会消失**（不会静默）。
    // ★★ DA81：判据只留一份 —— 与验证码页**共用** `captchaPendingIds()`
    //   （以前两处各写一遍 ⇒ 入口说"1 个任务需要验证码"、页面说"没有"）。
    final captchaIds = captchaPendingIds(
      ref.watch(downloadCaptchaProvider).value ?? const <String>[],
      state.items,
    );
    final captchaCount = captchaIds.length;
    // D9：空态里会不会出现「新建任务」按钮 —— 一个判据、两处消费
    // （`_body()` 渲染按钮 + `floatingActionButton` 决定要不要给 FAB）。
    final emptyStateHasNewTask = _emptyStateHasNewTask(
      state: state,
      api: api,
      canTaskList: canTaskList,
    );
    return DesignScaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                key: const Key('ds-search-field'),
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: dataText('dsSearchHint', '搜索任务名称'),
                  border: InputBorder.none,
                ),
                onSubmitted: (v) =>
                    ref.read(downloadListProvider.notifier).search(v),
              )
            : Text(t.dsTitle),
        // ★ r121 逐屏审计 D7①：这是**已经走过 `adaptiveActions`** 的口径
        //   （不再是手写一长串 trailing 动作），但 `reserve` 仍是默认 112dp。
        //   `AppBar` 的 actions 区实测宽 ≈ 屏宽 − leading(56)；414dp 真机上
        //   `inlineCountFor(361, reserve:112)` = 4 ⇒ 行内 4 格 + 溢出 1 格 = 5 格
        //   (240dp)，标题只剩 ~120dp ⇒ 英文 `Downloads` 被压成 `Downl...`
        //   （`dl_10.png` 逐字如此）。
        //   提到 200dp 后只 inline 3 格（search/sort/batch），标题拿到 ~169dp
        //   ⇒ 标题不再截断，其余动作照旧在 `⋮` 里可点。
        //   两个 `PopupMenuButton` 是复合控件，**不折叠**（`FoldingActions` 保证）；
        //   800x600 的测试窗口下 (800−200)/48 = 12 ≥ 动作总数 ⇒ 一格都不折，
        //   既有 `ds-sort-menu`/`ds-batch-menu`/`ds-rss-open` 的 key 断言不受影响。
        actions: adaptiveActions([
          if (_searching)
            IconButton(
              key: const Key('ds-search-close'),
              tooltip: t.actionCancel,
              icon: const Icon(Icons.close),
              onPressed: () {
                _searchController.clear();
                setState(() => _searching = false);
                ref.read(downloadListProvider.notifier).search('');
              },
            )
          else ...[
            IconButton(
              key: const Key('ds-search-open'),
              tooltip: dataText('dsSearchHint', '搜索任务名称'),
              icon: const Icon(Icons.search),
              onPressed: () => setState(() => _searching = true),
            ),
            _SortMenu(
              sortBy: state.sortBy,
              descending: state.descending,
              onSelect: (field, desc) => ref
                  .read(downloadListProvider.notifier)
                  .sort(field, descending: desc),
            ),
            _BatchMenu(
              onPauseAll: () => _runBatch(
                ScaffoldMessenger.of(context),
                () => ref.read(downloadActionsProvider).pauseAll(),
                dataText('dsPauseAll', '全部暂停'),
              ),
              onResumeAll: () => _runBatch(
                ScaffoldMessenger.of(context),
                () => ref.read(downloadActionsProvider).resumeAll(),
                dataText('dsResumeAll', '全部恢复'),
              ),
              onClearFinished: () => _confirmBatch(
                context,
                title: dataText('dsClearFinished', '清除已完成'),
                body: dataText(
                  'dsClearFinishedConfirm',
                  '已完成的任务会从下载列表中移除，此操作无法恢复。',
                ),
                done: dataText('dsClearedFinished', '已清除已完成任务'),
                run: () => ref.read(downloadActionsProvider).clearFinished(),
              ),
              onRemoveErrors: () => _confirmBatch(
                context,
                title: dataText('dsRemoveErrors', '删除错误任务'),
                body: dataText(
                  'dsRemoveErrorsConfirm',
                  '要删除所有错误任务吗？此操作无法恢复。',
                ),
                done: dataText('dsRemovedErrors', '已删除错误任务'),
                run: () => ref.read(downloadActionsProvider).removeErrors(),
              ),
            ),
          ],
          // RSS 订阅入口（wave3）—— 能力门控：`RSS.Feed` / `RSS.Filter` /
          // `RSS.Item` **任一**不在能力表里就**隐藏入口**（这台 NAS 没装/没启用
          // DS2 就不给假入口）。三个 API 都只有 v1、普通用户可用
          // （`webapi/SYNO.DownloadStation2.RSS.lib` 逐字）。
          if (api != null &&
              api.hasApi(DownloadStationApi.apiRssFeed) &&
              api.hasApi(DownloadStationApi.apiRssFilter) &&
              api.hasApi(DownloadStationApi.apiRssItem))
            IconButton(
              key: const Key('ds-rss-open'),
              tooltip: dataText('dsRssTitle', 'RSS 订阅'),
              icon: const Icon(Icons.rss_feed),
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .push<void>(
                    MaterialPageRoute(
                      builder: (_) => const DownloadRssPage(),
                    ),
                  ),
            ),
          // F10：内置链接浏览器 —— 官方安卓端有 `BrowserActivity`（WebView +
          // onDownloadStart），所以这里给入口；套件没装就不给。
          if (installed && api != null)
            IconButton(
              key: const Key('ds-browser-open'),
              tooltip: dataText('dsBrowserTitle', '下载链接浏览器'),
              icon: const Icon(Icons.public),
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .push<void>(
                    MaterialPageRoute(
                      builder: (_) => const DownloadBrowserPage(),
                    ),
                  ),
            ),
          // F1：eMule 入口 —— 门控 = 能力表里有 `Task.eMule`（v1）**且**
          // `Package.Service.get.enable_emule == true`（这台 NAS 真启用了 eMule
          // 才给入口；否则隐藏，不给假入口）。
          if (api != null &&
              api.hasApi(DownloadStationApi.apiEmuleUpload) &&
              (ref.watch(downloadPackageServiceProvider).value?.enableEmule ??
                  false))
            IconButton(
              key: const Key('ds-emule-open'),
              tooltip: dataText('dsEmuleTitle', 'eMule'),
              icon: const Icon(Icons.swap_vert_circle_outlined),
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .push<void>(
                    MaterialPageRoute(
                      builder: (_) => const DownloadEmulePage(),
                    ),
                  ),
            ),
          // BT 搜索入口（wave4）—— 门控：能力表里有**老代**
          // `DownloadStation.BTSearch`（`btsearch.cgi`，本机唯一能出结果的）
          // **或** DS2 `DownloadStation2.BTSearch`（降级/兼容）就出现；
          // 两者都没有 → **隐藏入口**（这台 NAS 没装/没启用就不给假入口）。
          if (api != null &&
              (api.hasApi(DownloadStationApi.apiBtSearchLegacy) ||
                  api.hasApi(DownloadStationApi.apiBtSearch)))
            IconButton(
              key: const Key('ds-bt-search-open'),
              tooltip: dataText('dsBtSearchTitle', 'BT 搜索'),
              icon: const Icon(Icons.travel_explore),
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .push<void>(
                    MaterialPageRoute(
                      builder: (_) => const DownloadBtSearchPage(),
                    ),
                  ),
            ),
          IconButton(
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.read(downloadListProvider.notifier).refresh();
              ref.invalidate(downloadStatisticProvider);
              ref.invalidate(downloadCaptchaProvider);
            },
          ),
          // 设置入口（F9 自动解压）—— 只在套件装了的时候出现，避免给假入口。
          if (installed && api != null)
            IconButton(
              key: const Key('ds-settings'),
              tooltip: dataText('dsSettings', '下载设置'),
              icon: const Icon(Icons.tune),
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .push<void>(
                    MaterialPageRoute(
                      builder: (_) => const DownloadSettingsPage(),
                    ),
                  ),
            ),
        ], reserve: 200),
      ),
      floatingActionButton:
          installed &&
              api != null &&
              // ★ r121 逐屏审计 D9：空态里已经有 `New task` 按钮时**不再**给 FAB
              //   （`dl_10.png` 上两者同时出现，是同一个入口的两份表示）。
              //   这一条与 `_body()` 用的是**同一个判据函数**，不另抄一遍条件。
              !emptyStateHasNewTask
          ? FloatingActionButton.extended(
              key: const Key('ds-add-task'),
              onPressed: () => _openCreate(context),
              icon: const Icon(Icons.add),
              label: Text(t.dsNewTask),
            )
          : null,
      body: Column(
        children: [
          const _StatisticBar(),
          if (!canTaskList)
            const CapabilityDegradeHint()
          else ...[
            // 验证码入口（wave5）：能力表里有 `SYNO.DownloadStation2.Captcha`
            // **且**确实有待处理任务时才出现；两者任一不满足就隐藏（不给假入口）。
            // 出现时**必须**让用户能提交 —— 服务端要求验证码而界面不提示，
            // 就是"静默失败"。
            if (api != null &&
                api.hasApi(DownloadStationApi.apiCaptcha) &&
                captchaCount > 0)
              _CaptchaBanner(
                count: captchaCount,
                onOpen: () => _openCaptcha(context),
              ),
            _CategoryBar(
              current: state.category,
              onSelect: (c) =>
                  ref.read(downloadListProvider.notifier).select(c),
            ),
            Expanded(
              child: _body(context, state, api, emptyStateHasNewTask),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    DownloadListState state,
    DownloadStationApi? api,
    bool emptyStateHasNewTask,
  ) {
    final t = context.t;
    // 1) 还没连接会话
    if (state.apiMissing || api == null) {
      return AppEmptyState(
        icon: Icons.cloud_off,
        title: t.setNotConnected,
        message: t.dsEmptyMessage,
      );
    }
    // 2) 套件未安装：给结论，不给"重试"（重试也装不上）
    if (state.failure == DsFailureKind.notInstalled) {
      return AppEmptyState(
        icon: Icons.extension_off_outlined,
        title: t.dsErrNotInstalled,
        // 注意：这里不能说"点新建任务"——没装套件时 FAB 是不出现的。
        message: t.dsNotInstalledHint,
      );
    }
    // 3) 无权限
    if (state.failure == DsFailureKind.noPrivilege && state.items.isEmpty) {
      return AppEmptyState(
        icon: Icons.lock_outline,
        title: t.dsErrNoPrivilege,
        message: t.dsNoPrivilegeHint,
      );
    }
    // 4) 首次加载
    if (state.loading && !state.loaded) return const AppListSkeleton();
    // 5) 失败（网络/其它）
    if (state.failure != null && state.items.isEmpty) {
      final network =
          state.failure == DsFailureKind.network ||
          state.failure == DsFailureKind.sessionExpired;
      return AppErrorView(
        icon: network ? Icons.wifi_off : Icons.error_outline,
        title: t.dsLoadFailed,
        detail: state.errorText,
        onRetry: () => ref.read(downloadListProvider.notifier).load(),
      );
    }
    // 6) 空态（区分"一个都没有"与"这个分类下没有"）
    if (state.items.isEmpty) {
      return AppEmptyState(
        icon: Icons.download_outlined,
        title: state.category == DownloadTaskCategory.all
            ? t.dsEmptyTitle
            : t.dsEmptyFiltered,
        message: state.category == DownloadTaskCategory.all
            ? t.dsEmptyMessage
            : null,
        // ★ D9：按钮与 FAB 二选一 —— 判据由 `_emptyStateHasNewTask()` **统一**
        //   给出（同一个布尔在 `floatingActionButton` 那里也消费），
        //   不在这里再写一遍 `category == all`。
        actionLabel: emptyStateHasNewTask ? t.dsNewTask : null,
        onAction: emptyStateHasNewTask ? () => _openCreate(context) : null,
        // 「新建任务」不是重试 ⇒ 图标显式给 `add`（共享组件默认是刷新圈）
        actionIcon: Icons.add,
      );
    }
    // 7) 列表
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(downloadCaptchaProvider);
        await ref.read(downloadListProvider.notifier).refresh();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
            ref.read(downloadListProvider.notifier).loadMore();
          }
          return false;
        },
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xxl * 2),
          itemCount: state.items.length + (state.loadingMore ? 1 : 0),
          separatorBuilder: (_, __) => Divider(
            height: 1,
            color: DesignPalette.of(context).dim.withValues(alpha: 0.12),
          ),
          itemBuilder: (context, i) {
            if (i >= state.items.length) {
              return const Padding(
                padding: EdgeInsets.all(Gap.lg),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _TaskRow(task: state.items[i]);
          },
        ),
      ),
    );
  }

  /// 打开验证码页；处理完后刷新任务列表（官方提交成功后也会重读状态）。
  Future<void> _openCaptcha(BuildContext context) async {
    final done = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<bool>(MaterialPageRoute(builder: (_) => const DownloadCaptchaPage()));
    ref.invalidate(downloadCaptchaProvider);
    if (done == true && mounted) {
      await ref.read(downloadListProvider.notifier).refresh();
      ref.invalidate(downloadStatisticProvider);
    }
  }

  Future<void> _openCreate(BuildContext context) async {
    final created = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<bool>(MaterialPageRoute(builder: (_) => const DownloadCreatePage()));
    if (created == true) {
      await ref.read(downloadListProvider.notifier).refresh();
      ref.invalidate(downloadStatisticProvider);
    }
  }

  /// 无确认的批量操作（暂停/恢复全部）—— 可逆，不需要二次确认。
  Future<void> _runBatch(
    ScaffoldMessengerState messenger,
    Future<void> Function() run,
    String doneLabel,
  ) async {
    try {
      await run();
      if (mounted) {
        await ref.read(downloadListProvider.notifier).refresh();
        ref.invalidate(downloadStatisticProvider);
      }
      messenger.showSnackBar(SnackBar(content: Text(doneLabel)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsBatchFailed',
              '操作失败：{msg}',
            ).replaceAll('{msg}', describeDownloadError(e)),
          ),
        ),
      );
    }
  }

  /// 破坏性批量操作（清除已完成/删除错误任务）—— 必须二次确认，文案写清
  /// "会删除文件"。
  Future<void> _confirmBatch(
    BuildContext context, {
    required String title,
    required String body,
    required String done,
    required Future<void> Function() run,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('ds-batch-dialog'),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(title),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _runBatch(messenger, run, done);
  }
}

/// D9（r121 逐屏审计）：空态里**是否已经**给出「新建任务」按钮。
///
/// `floatingActionButton` 与 `_body()` 必须消费**同一个**判据
/// （§2.0.26：同一语义不许造两份表示），所以抽成纯函数，两处都调它。
///
/// 分支顺序与 `_body()` **逐条对齐**（它在哪一条返回，就没有空态按钮）：
/// * 能力位缺失时 `_body` 根本不渲染空态、只渲染降级提示 ⇒ 没有按钮 ⟹ false；
/// * 未连接 / 套件未装 / 无权限 / 首次加载 / 加载失败 各分支都没有按钮 ⟹ false；
/// * 只有"列表真的空、且分类是 `All`"那一条才给按钮。
bool _emptyStateHasNewTask({
  required DownloadListState state,
  required DownloadStationApi? api,
  required bool canTaskList,
}) {
  if (!canTaskList) return false;
  if (state.apiMissing || api == null) return false;
  if (state.failure == DsFailureKind.notInstalled) return false;
  if (state.failure == DsFailureKind.noPrivilege && state.items.isEmpty) {
    return false;
  }
  if (state.loading && !state.loaded) return false;
  if (state.failure != null && state.items.isEmpty) return false;
  return state.items.isEmpty && state.category == DownloadTaskCategory.all;
}

/// 排序菜单：`Task.list` 的 `sort_by`/`order`（原 DC-4 的"参数在接口、UI 无入口"）。
class _SortMenu extends StatelessWidget {
  const _SortMenu({
    required this.sortBy,
    required this.descending,
    required this.onSelect,
  });

  final String? sortBy;
  final bool descending;
  final void Function(String? field, bool descending) onSelect;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const Key('ds-sort-menu'),
      tooltip: dataText('dsSortBy', '排序'),
      icon: const Icon(Icons.sort),
      onSelected: (v) {
        if (v == '__default__') {
          onSelect(null, false);
        } else if (v == '__asc__') {
          if (sortBy != null) onSelect(sortBy, false);
        } else if (v == '__desc__') {
          if (sortBy != null) onSelect(sortBy, true);
        } else {
          onSelect(v, descending);
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          value: '__default__',
          checked: sortBy == null,
          child: Text(dataText('dsSortDefault', '默认排序')),
        ),
        const PopupMenuDivider(),
        for (final key in DownloadStationApi.sortFields.keys)
          CheckedPopupMenuItem<String>(
            value: key,
            checked: sortBy == key,
            child: Text(dsSortLabel(key)),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<String>(
          value: '__asc__',
          checked: sortBy != null && !descending,
          child: Text(dataText('dsSortAsc', '升序')),
        ),
        CheckedPopupMenuItem<String>(
          value: '__desc__',
          checked: sortBy != null && descending,
          child: Text(dataText('dsSortDesc', '降序')),
        ),
      ],
    );
  }
}

/// 批量操作菜单（全部暂停/恢复、清除已完成、删除错误任务）。
///
/// 走服务端 `Task.pause_condition` / `resume_condition` / `delete_condition` v2
/// （官方 Web UI 的 `pause_all` / `resume_all` / `clear` 路径）。
class _BatchMenu extends StatelessWidget {
  const _BatchMenu({
    required this.onPauseAll,
    required this.onResumeAll,
    required this.onClearFinished,
    required this.onRemoveErrors,
  });

  final VoidCallback onPauseAll;
  final VoidCallback onResumeAll;
  final VoidCallback onClearFinished;
  final VoidCallback onRemoveErrors;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const Key('ds-batch-menu'),
      tooltip: dataText('dsBatchActions', '批量操作'),
      // ★ r121 逐屏审计 D7②：这里原来是 `Icons.more_vert`，和 `adaptiveActions`
      //   的溢出入口 `⋮` **一模一样** ⇒ `dl_10.png` 上工具条出现两个相同的 ⋮
      //   （用户分不清哪个是"被折叠的动作"、哪个是"批量操作"）。
      //   换成语义唯一的 `checklist`（暂停/恢复全部、清除已完成、删除错误任务
      //   都是"对一批任务批处理"），工具条里就只剩**一个** ⋮（溢出）。
      icon: const Icon(Icons.checklist),
      onSelected: (v) => switch (v) {
        'pause_all' => onPauseAll(),
        'resume_all' => onResumeAll(),
        'clear_finished' => onClearFinished(),
        'remove_errors' => onRemoveErrors(),
        _ => null,
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          key: const Key('ds-batch-pause-all'),
          value: 'pause_all',
          child: Text(dataText('dsPauseAll', '全部暂停')),
        ),
        PopupMenuItem(
          key: const Key('ds-batch-resume-all'),
          value: 'resume_all',
          child: Text(dataText('dsResumeAll', '全部恢复')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          key: const Key('ds-batch-clear-finished'),
          value: 'clear_finished',
          child: Text(dataText('dsClearFinished', '清除已完成')),
        ),
        PopupMenuItem(
          key: const Key('ds-batch-remove-errors'),
          value: 'remove_errors',
          child: Text(dataText('dsRemoveErrors', '删除错误任务')),
        ),
      ],
    );
  }
}

/// 顶部统计条：总速率 + 任务数（`Task.Statistic.get` v1）。
class _StatisticBar extends ConsumerWidget {
  const _StatisticBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final stat = ref.watch(downloadStatisticProvider).value;
    final state = ref.watch(downloadListProvider);
    if (stat == null && state.total == 0) return const SizedBox.shrink();
    return Padding(
      key: const Key('ds-stat-bar'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
      // `Row` + 三个不可压缩的遥测标签：英文 / 大字号下必然横向溢出
      // （2.0 缩放在 393 宽屏上实测溢出 335px）。`Wrap` 信息一条不少，
      // 放不下时换行；1.0 缩放单行时 `spaceBetween` 与原来的观感一致。
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Gap.md,
        runSpacing: Gap.xs,
        children: [
          if (stat != null) ...[
            TelemetryLabel(t.dsTotalDown(dsHumanRate(stat.downloadRate))),
            TelemetryLabel(t.dsTotalUp(dsHumanRate(stat.uploadRate))),
          ],
          // ★ r121 逐屏审计 D7③：末尾原来是一个**裸数字**（`0`），用户看不出
          //   它是"任务总数" ⇒ 加标签（`1 task` / `共 1 个任务`）。
          //   同时英文两条速率标签由 `Total ↓ …`/`Total ↑ …` 改成
          //   `Down …`/`Up …`：同一个 `Total` 出现两次看起来就是"标签重复"。
          TelemetryLabel(t.dsTotalTasks(state.total)),
        ],
      ),
    );
  }
}

/// 验证码入口条（wave5）。
///
/// 服务端要求验证码时**必须显式提示 + 给提交入口** —— 这是"不许静默失败"
/// 的落地：只在有任务待输入时出现，[count] 是数量（**绝不是任务 id**）。
class _CaptchaBanner extends StatelessWidget {
  const _CaptchaBanner({required this.count, required this.onOpen});

  final int count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final meta = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim);
    return Padding(
      key: const Key('ds-captcha-banner'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
      child: Row(
        children: [
          Icon(Icons.verified_user_outlined, size: 16, color: DesignPalette.of(context).dim),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              dataText(
                'dsCaptchaBanner',
                '{count} 个任务需要输入验证码才能继续',
              ).replaceAll('{count}', '$count'),
              style: meta,
            ),
          ),
          TextButton(
            key: const Key('ds-captcha-open'),
            onPressed: onOpen,
            child: Text(dataText('dsCaptchaEnter', '输入验证码')),
          ),
        ],
      ),
    );
  }
}

/// 分类筛选（全部 / 下载中 / 已完成 / 错误）。
class _CategoryBar extends StatefulWidget {
  const _CategoryBar({required this.current, required this.onSelect});

  final DownloadTaskCategory current;
  final ValueChanged<DownloadTaskCategory> onSelect;

  @override
  State<_CategoryBar> createState() => _CategoryBarState();
}

class _CategoryBarState extends State<_CategoryBar> {
  final _controller = ScrollController();

  /// 右边还有没被看到的 chip ⇒ 在右缘叠一层渐隐，把"可以横向滚"画出来。
  ///
  /// r121 逐屏审计 D8：414dp 真机上最后一个 `Seeding` 被右边缘**齐边裁掉**
  /// （`dl_10.png`），看上去像"内容就这么多、只是被切了"。这里**保留滚动**
  /// （横向 `ListView`，**不加省略号**、也不缩字号），只是把可滚动这一事实
  /// 变成可见的：有内容在右边时渐隐、滚到底自动消失。
  bool _hasMoreRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncHint);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncHint() {
    if (!mounted || !_controller.hasClients) return;
    final p = _controller.position;
    // 1px 容差：`pixels`/`maxScrollExtent` 都是浮点，滚到底时差 0.x 很正常。
    final more = p.maxScrollExtent > 0 && p.pixels < p.maxScrollExtent - 1;
    if (more != _hasMoreRight) setState(() => _hasMoreRight = more);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // 首帧之后才量得到 `maxScrollExtent`（build 阶段 position 还没 attach）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncHint());
    final list = ListView(
      // key 是给用例量"最后一个 chip 可达"用的可观测点。
      key: const Key('ds-category-list'),
      controller: _controller,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: Gap.md,
        vertical: Gap.xs,
      ),
      children: [
        for (final c in DownloadTaskCategory.values)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xxs),
            child: _CategoryChip(
              key: Key('ds-cat-${c.name}'),
              label: dsCategoryLabel(t, c),
              selected: c == widget.current,
              onTap: () => widget.onSelect(c),
            ),
          ),
        // 末尾留一格：滚到底时最后一个 chip 不贴着屏幕边缘。
        const SizedBox(width: Gap.sm),
      ],
    );
    return SizedBox(
      height: 48,
      child: Stack(
        children: [
          // ★ 这一层的位置与类型**不随 `_hasMoreRight` 变化**（框在 `Stack` 的
          //   第 0 个孩子上）。这一点是必须的：如果渐隐层是"有/没有"地包在外面，
          //   滚到右端的那一帧整棵 `ListView` 会被**重建**，`ScrollController`
          //   的偏移随之归零 ⇒ 用户一滚到底就被弹回开头（本文件的用例量到过
          //   `pixels=0.0 / maxScrollExtent=370.8` 正是这个现象）。
          ShaderMask(
            // `dstIn` 只作用于**子树已画出的像素**，所以不像"盖一块纯色"那样
            // 在 `FieldBackdrop` 上糊出方框。没内容可渐隐时颜色全白 = 恒等。
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: _hasMoreRight
                  ? const [Colors.white, Colors.white, Colors.transparent]
                  : const [Colors.white, Colors.white, Colors.white],
              stops: const [0, 0.86, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: list,
          ),
          if (_hasMoreRight)
            // 纯标记：真正画渐隐的是上面那层 `ShaderMask`，这里只是把
            // "右侧还有内容"这个状态做成可观测点（用例据此断言提示的出现/消失）。
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: Gap.xl,
              child: IgnorePointer(
                child: SizedBox(key: const Key('ds-category-fade')),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.capsule),
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.capsule),
            // ★ `DA186`：不透明 `primarySoft`（半透明叠底只有 4.4:1）
            color: selected
                ? DesignPalette.of(context).primarySoft
                : DesignPalette.of(context).surface,
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.5)
                  : DesignPalette.of(context).line.withValues(alpha: 0.25),
            ),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: selected
                  ? DesignPalette.of(context).primary
                  : DesignPalette.of(context).dim,
            ),
          ),
        ),
      ),
    );
  }
}

/// 一行任务：状态 · 进度 · 大小/速度/ETA · 行内暂停/继续/删除。
class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task});

  final DownloadTaskDto task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = context.t;
    final statusColor = task.isError
        ? theme.colorScheme.error
        : task.isFinished
        ? theme.colorScheme.primary
        : DesignPalette.of(context).dim;
    final meta = dsTaskMetaLine(task);
    final progress = task.progress;

    return DesignRowTile(
      key: Key('ds-task-${task.id}'),
      onTap: () => Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(builder: (_) => DownloadDetailPage(taskId: task.id)),
      ),
      leading: _PreviewThumb(task: task, color: statusColor),
      title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: Gap.xxs),
          Row(
            children: [
              TelemetryLabel(
                dsStatusLabel(t, task.status),
                size: 11,
                color: statusColor,
              ),
              if (meta.isNotEmpty) ...[
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: TelemetryLabel(
                    meta,
                    size: 11,
                    color: DesignPalette.of(context).dim,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ],
          ),
          if (progress > 0 && !task.isFinished) ...[
            const SizedBox(height: Gap.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress >= 1 ? 1 : progress,
                minHeight: 3,
              ),
            ),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!task.isFinished && !task.isError)
            IconButton(
              key: Key('ds-toggle-${task.id}'),
              tooltip: task.isPaused ? t.dsResume : t.dsPause,
              icon: Icon(
                task.isPaused ? Icons.play_arrow : Icons.pause,
                size: 20,
              ),
              onPressed: () => _toggle(context, ref),
            ),
          // ★ r323：这个 ⋮ 是**两种动作的共用入口**，所以它的**出现条件也必须
          //   是两者的并集**：
          //   * 「改目的地」（`Task.edit`）—— 只有**还没结束**的任务能改
          //     （已完成/错误的任务目的地已定）；
          //   * 「结束任务」（`str_force_complete`，`Task.delete force_complete=true`）
          //     —— 官方 quick action 只给"文件已经落地了"的状态
          //     （错误 / 暂停 / 已完成的 BT）。
          //   ⚠️ 第 322 轮我就是因为只看到"结束任务"这一层条件、又拿着**下载中**
          //      的任务去点，差点把它当"功能缺失"（D22）。加动作时**先看入口条件**。
          if (_canEdit || _canForceComplete)
            PopupMenuButton<String>(
              key: Key('ds-more-${task.id}'),
              tooltip: dataText('dsMoreActions', '更多操作'),
              icon: const Icon(Icons.more_horiz, size: 20),
              onSelected: (v) {
                if (v == 'force_complete') _confirmForceComplete(context, ref);
                if (v == 'edit_destination') {
                  _editTask(context, ref);
                }
              },
              itemBuilder: (context) => [
                if (_canEdit)
                  PopupMenuItem(
                    key: Key('ds-edit-dest-${task.id}'),
                    value: 'edit_destination',
                    child: Text(dataText('dsEditDestination', '改目的地')),
                  ),
                if (_canForceComplete)
                  PopupMenuItem(
                    key: Key('ds-force-complete-${task.id}'),
                    value: 'force_complete',
                    child: Text(dataText('dsForceComplete', '结束任务')),
                  ),
              ],
            ),
          IconButton(
            key: Key('ds-delete-${task.id}'),
            tooltip: t.dtoActionDelete,
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
    );
  }

  /// 「改目的地」能不能给：**只有还没结束的任务**能改（`Task.edit`）。
  ///
  /// 已完成(5)/错误(101+)/做种 的任务目的地已经定下来了 —— 官方前端也不给
  /// 这些状态编辑（编辑表单只在 `QueueDownloading`/`QueueStopped` 的行上出现）。
  bool get _canEdit => !task.isFinished && !task.isError;

  /// 「结束任务」能不能给：官方 quick action `str_force_complete`
  /// —— 错误 / 暂停 / 已完成的 BT（"文件已经落地了"的那些状态）。
  bool get _canForceComplete =>
      task.isError || task.isPaused || (task.isFinished && task.isBt);

  /// 改**目的地 / 优先级 / 解压密码**（`Task/edit` v1–v2）。
  ///
  /// 字段与门控**逐字照官方 `ui/download.js`**（第 328 轮按官方前端重做）：
  ///
  /// * **常规任务** = `DLM.QueueEditBtDialog.saveDestination()`：
  ///   只发 `{id, destination}`；`extract_password` **仅在密码框被改过时**才带上
  ///   （官方 `handlePassword()` 里那个 `isDirty()` 是这条的依据）；
  /// * **eMule 任务** = `aMule.EditTaskWindow.applyHandler()`：
  ///   `{id, priority, destination}`，`priority ∈ {low, normal, high, auto}`，
  ///   默认 `auto` —— ★ **官方只有 eMule 模块给「优先级」**，
  ///   常规下载/BT 的编辑窗口里**没有**这个字段（`saveDestination` 的 params 只有 destination）；
  /// * **解压密码框**只在 unzip 服务开着时才出现
  ///   （官方 `DLM.Util.isUnzipServiceOn()` = `is_admin ? enable_unzip
  ///   : is_unzip_service_enable && enable_unzip`）。
  ///
  /// 目的地为空时**禁用保存**（官方 `error_bad_field`：`saveDestination` 要求非空）。
  /// 客户端 `editTask` 里"两个可改字段都空 ⇒ 抛 114 不发请求"的守卫仍在。
  Future<void> _editTask(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final destCtrl = TextEditingController(text: task.detail.destination.trim());
    final pwCtrl = TextEditingController();
    final showPriority = task.isEmule;
    // 官方 isUnzipServiceOn()：管理员看 `enable_unzip`，普通用户还要服务端支持。
    // ⚠️ 必须 **await** 能力位：`showDialog` 弹出后就与调用方脱离，
    //    之后 provider 就绪不会重建对话框（本用例第一版就栽在这里 —— 字段恒不出现）。
    DsPackageService? svc;
    try {
      svc = await ref.read(downloadPackageServiceProvider.future);
    } catch (_) {
      svc = null; // 能力取不到 ⇒ 与"服务关"同处置（官方也是取不到就不显示）
    }
    final showUnzip =
        svc != null &&
        svc.enableUnzip &&
        // 身份未知按**非管理员**算（fail-closed，与 `admin_gate.dart` 同一方向）。
        ((ref.read(isAdminProvider).value ?? false) || svc.isUnzipServiceEnable);
    var priority = _dsEditPriorities.contains(task.detail.priority)
        ? task.detail.priority
        : 'auto';
    // 上面 `await` 过能力位 ⇒ 用它之前必须先确认还挂着（否则 lint
    // `use_build_context_synchronously` 会红；分析必须 "No issues found!"）。
    if (!context.mounted) return;
    final result = await showDialog<_DsEditTaskResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          key: const Key('ds-edit-dest-dialog'),
          title: Text(dataText('dsEditDestination', '改目的地')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 官方 `aMule.EditTaskWindow` 的第一行就是优先级（只有 eMule 有）。
                if (showPriority) ...[
                  DropdownButtonFormField<String>(
                    key: const Key('ds-edit-task-priority'),
                    initialValue: priority,
                    decoration: InputDecoration(
                      labelText: dataText('dsPriority', '优先级'),
                    ),
                    items: [
                      for (final p in _dsEditPriorities)
                        DropdownMenuItem(
                          value: p,
                          child: Text(dsPriorityLabel(p)),
                        ),
                    ],
                    onChanged: (v) =>
                        setLocal(() => priority = v ?? priority),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  key: const Key('ds-edit-dest-field'),
                  controller: destCtrl,
                  autofocus: !showPriority,
                  onChanged: (_) => setLocal(() {}),
                  decoration: InputDecoration(
                    labelText: dataText('dsDestination', '目标文件夹'),
                    hintText: '/volume1/downloads',
                  ),
                ),
                if (showUnzip) ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('ds-edit-task-unzip'),
                    controller: pwCtrl,
                    decoration: InputDecoration(
                      // ⚠️ 用 `dataText` 就必须把 key 登记进 `dataTextMap`
                      // （i18n 守卫 ② 会红；本用例第一版漏登记，全量 -3 里有它）。
                      // 这里**不**用 `ctx.t`：`context` 在 `showDialog` 之前
                      // 已经跨过 `await`（拿能力位），会触发
                      // `use_build_context_synchronously`。
                      labelText: dataText('dsExtractPassword', '解压密码'),
                      helperText: dataText(
                        'dsExtractPasswordHint',
                        '可选；加密压缩包需要',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(context.t.actionCancel),
            ),
            FilledButton(
              key: const Key('ds-edit-dest-submit'),
              onPressed: destCtrl.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop(
                      _DsEditTaskResult(
                        destination: destCtrl.text.trim(),
                        priority: showPriority ? priority : null,
                        extractPassword: pwCtrl.text.isEmpty
                            ? null
                            : pwCtrl.text,
                      ),
                    ),
              child: Text(dataText('dsSave', '保存')),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    try {
      await ref.read(downloadActionsProvider).editDestination(
        [task.id],
        destination: result.destination,
        priority: result.priority,
        extractPassword: result.extractPassword,
      );
      trackOnce(
        UsageModule.downloads,
        UsageAction.edit,
        objectType: 'task',
      );
      messenger.showSnackBar(
        // ★ 复用**已有** key `dsDestinationSaved`（别为同一语义造第二个 key；
        //   英文模式的登记表在 `lib/src/core/i18n/l10n.dart`，漏登记会回落中文）。
        SnackBar(content: Text(dataText('dsDestinationSaved', '目的地已保存'))),
      );
      await ref.read(downloadListProvider.notifier).refresh();
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.edit,
        objectType: 'task',
        reason: 'edit_destination_failed',
        error: e,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsBatchFailed',
              '操作失败：{msg}',
            ).replaceAll('{msg}', describeDownloadError(e)),
          ),
        ),
      );
    }
  }

  /// 结束任务（`force_complete=true`）：**不删文件**，只是无法再续传。
  ///
  /// 文案必须与服务端行为一致 —— 官方 `str_force_complete_confirm`
  /// = "You cannot resume a download task after its files are moved to another
  /// folder."（任务文件的归属会变、无法恢复下载），而不是"连带删除文件"。
  Future<void> _confirmForceComplete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('ds-force-complete-dialog'),
        title: Text(dataText('dsForceComplete', '结束任务')),
        content: Text(
          dataText(
            'dsForceCompleteConfirm',
            '结束后无法再恢复下载，已下载的文件会保留在目标文件夹。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(dataText('dsForceComplete', '结束任务')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(downloadActionsProvider).forceComplete([task.id]);
      trackOnce(UsageModule.downloads, UsageAction.delete, objectType: 'task');
      messenger.showSnackBar(
        SnackBar(content: Text(dataText('dsForceCompleted', '已结束任务'))),
      );
      await ref.read(downloadListProvider.notifier).refresh();
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.delete,
        objectType: 'task',
        reason: 'force_complete_failed',
        error: e,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsBatchFailed',
              '操作失败：{msg}',
            ).replaceAll('{msg}', describeDownloadError(e)),
          ),
        ),
      );
    }
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(downloadActionsProvider);
    try {
      if (task.isPaused) {
        await actions.resume([task.id]);
      } else {
        await actions.pause([task.id]);
      }
      await ref.read(downloadListProvider.notifier).refresh();
      trackOnce(
        UsageModule.downloads,
        task.isPaused ? UsageAction.resume : UsageAction.pause,
        objectType: 'task',
      );
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        task.isPaused ? UsageAction.resume : UsageAction.pause,
        objectType: 'task',
        reason: 'toggle_failed',
        error: e,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            task.isPaused
                ? t.dsResumeFailed(describeDownloadError(e))
                : t.dsPauseFailed(describeDownloadError(e)),
          ),
        ),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('ds-delete-dialog'),
        title: Text(t.dsDeleteTitle),
        content: Text(t.dsDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(downloadActionsProvider).delete([task.id]);
      messenger.showSnackBar(SnackBar(content: Text(t.dsDeleted)));
      await ref.read(downloadListProvider.notifier).refresh();
      trackOnce(UsageModule.downloads, UsageAction.delete, objectType: 'task');
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.delete,
        objectType: 'task',
        reason: 'delete_failed',
        error: e,
      );
      messenger.showSnackBar(
        SnackBar(content: Text(t.dsDeleteFailed(describeDownloadError(e)))),
      );
    }
  }
}

/// 任务行缩略图（F8，`Thumbnail.get`/`download` v2）。
///
/// **失败/为空/非 BT 一律回落既有状态图标**（任务书：不许空白、不许把内部
/// id 当文案显示）。字节走 `getBytes`（鉴权 + 自签证书），不用
/// `Image.network`（与 `features/photos/*` 同一理由）。
class _PreviewThumb extends ConsumerWidget {
  const _PreviewThumb({required this.task, required this.color});

  final DownloadTaskDto task;
  final Color color;

  IconData get _fallbackIcon => task.isError
      ? Icons.error_outline
      : task.isFinished
      ? Icons.check_circle_outline
      : task.isPaused
      ? Icons.pause_circle_outline
      : Icons.downloading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!task.isBt) return Icon(_fallbackIcon, color: color);
    final bytes = ref.watch(downloadThumbnailProvider(task.id)).value;
    if (bytes == null || bytes.isEmpty) {
      return Icon(_fallbackIcon, color: color);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        bytes,
        key: Key('ds-thumb-${task.id}'),
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Icon(_fallbackIcon, color: color),
      ),
    );
  }
}
