// Download Station **RSS 订阅**（wave3）的状态机与依赖注入。
//
// 事实来源（**三层都对上**，见 `docs/download-api-live.md` §11 与官方前端）：
//   * 包内 `webapi/SYNO.DownloadStation2.RSS.lib`：三个 API
//     `RSS.Feed` / `RSS.Filter` / `RSS.Item`，**都只有 v1**，
//     `allowUser=["admin.local","normal.local"]`（普通用户可用）；
//   * 包内官方前端 `ui/download.js` 的 `DLM.RSS*` 调用点（逐字；线参形态见
//     `download_station.dart` 各方法注释）；
//   * 真机实测（§11）：`Feed:list`（含 `is_updating`）/ `Feed:updateall` 可用，
//     其余方法"缺参报 120"钉死参数名；`2404`/`2405` 语义**未定**。
//
// 硬约束（任务书）：
//   * `is_updating` 为真 → 按官方 `interval:5000` 轮询 `Feed:list`；
//   * 条目列表 `Item:list`（`feed_id`）+ 分页 / 空态 / 失败**三态**；
//   * 过滤器 `Filter:list`（`feed_id`）+ `Filter:add` / `test`（线参已取证）；
//   * **D 级错误码（2404/2405）走"未知错误 + 原始码"通用提示，绝不写死文案**；
//     `120` 走既有通用参数提示通道；
//   * **绝不显示 `id` / `feed_id` 等内部标识**；**未取证的成功路径不伪造**。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../../dsm/webapi.dart';
import 'download_providers.dart';

/// RSS 轮询间隔。默认 = 官方 5 秒（[DownloadStationApi.rssPollInterval]）。
/// 测试 override 成 [Duration.zero]（离线用例不等真时钟）。
final rssPollIntervalProvider = Provider<Duration>(
  (ref) => DownloadStationApi.rssPollInterval,
);

/// RSS 轮询上限。默认 = [DownloadStationApi.rssMaxPolls]。
/// 测试 override 成小值验"到顶即停"。
final rssMaxPollsProvider = Provider<int>(
  (ref) => DownloadStationApi.rssMaxPolls,
);

/// RSS 订阅列表的**中性不可用**原因（不是"加载失败"）。
enum RssBlock {
  /// 未连接会话（`downloadApiProvider == null`）。
  apiMissing,

  /// 能力表里没有 `SYNO.DownloadStation2.RSS.*` → 没装/没启用 DS2。
  notInstalled,

  /// `105`/`160`/`524`：账号没有权限。
  noPrivilege,

  /// 网络失败。
  network,
}

/// RSS 页面状态（订阅列表 + 选中源的条目 + 该源的过滤器）。
class RssState {
  const RssState({
    this.feeds = const [],
    this.total = 0,
    this.loading = false,
    this.loaded = false,
    this.polling = false,
    this.polls = 0,
    this.failure,
    this.errorText,
    this.block,
    this.selectedFeedId,
    this.items = const [],
    this.itemsTotal = 0,
    this.itemsLoading = false,
    this.itemsLoaded = false,
    this.itemsLoadingMore = false,
    this.itemsError,
    this.filters = const [],
    this.filtersLoading = false,
    this.filtersLoaded = false,
    this.filtersError,
    this.busy = false,
  });

  final List<DsRssFeed> feeds;
  final int total;

  /// 首页加载中。
  final bool loading;

  /// 至少成功加载过一次（区分"还没加载"与"加载完是空的"）。
  final bool loaded;

  /// `is_updating` 为真时正在轮询。
  final bool polling;

  /// 已轮询次数（测试断言"结束条件"）。
  final int polls;

  /// 真错误的大类（套件未安装 / 无权限 / 网络 / 其它）。
  final DsFailureKind? failure;

  /// 真错误文案（`describeDownloadRssError`）。
  final String? errorText;

  /// 中性不可用原因（非 null 时不显示"加载失败"）。
  final RssBlock? block;

  /// **内部**选中的订阅源 id（`feed_id`）——界面绝不显示。
  final String? selectedFeedId;

  final List<DsRssItem> items;
  final int itemsTotal;
  final bool itemsLoading;
  final bool itemsLoaded;
  final bool itemsLoadingMore;
  final String? itemsError;

  final List<DsRssFilter> filters;
  final bool filtersLoading;
  final bool filtersLoaded;
  final String? filtersError;

  /// 增删改（add/delete/update/updateall/clear/filter 写操作）进行中。
  final bool busy;

  bool get hasMoreItems => items.length < itemsTotal;

  /// 任一订阅源在更新（顶层位或逐条位）。
  bool get anyUpdating => feeds.any((f) => f.isUpdating);

  DsRssFeed? get selectedFeed {
    final id = selectedFeedId;
    if (id == null) return null;
    for (final f in feeds) {
      if (f.id == id) return f;
    }
    return null;
  }

  RssState copyWith({
    List<DsRssFeed>? feeds,
    int? total,
    bool? loading,
    bool? loaded,
    bool? polling,
    int? polls,
    DsFailureKind? failure,
    String? errorText,
    bool clearError = false,
    RssBlock? block,
    bool clearBlock = false,
    String? selectedFeedId,
    bool clearSelection = false,
    List<DsRssItem>? items,
    int? itemsTotal,
    bool? itemsLoading,
    bool? itemsLoaded,
    bool? itemsLoadingMore,
    String? itemsError,
    bool clearItemsError = false,
    List<DsRssFilter>? filters,
    bool? filtersLoading,
    bool? filtersLoaded,
    String? filtersError,
    bool clearFiltersError = false,
    bool? busy,
  }) => RssState(
    feeds: feeds ?? this.feeds,
    total: total ?? this.total,
    loading: loading ?? this.loading,
    loaded: loaded ?? this.loaded,
    polling: polling ?? this.polling,
    polls: polls ?? this.polls,
    failure: clearError ? null : (failure ?? this.failure),
    errorText: clearError ? null : (errorText ?? this.errorText),
    block: clearBlock ? null : (block ?? this.block),
    selectedFeedId: clearSelection
        ? null
        : (selectedFeedId ?? this.selectedFeedId),
    items: items ?? this.items,
    itemsTotal: itemsTotal ?? this.itemsTotal,
    itemsLoading: itemsLoading ?? this.itemsLoading,
    itemsLoaded: itemsLoaded ?? this.itemsLoaded,
    itemsLoadingMore: itemsLoadingMore ?? this.itemsLoadingMore,
    itemsError: clearItemsError ? null : (itemsError ?? this.itemsError),
    filters: filters ?? this.filters,
    filtersLoading: filtersLoading ?? this.filtersLoading,
    filtersLoaded: filtersLoaded ?? this.filtersLoaded,
    filtersError: clearFiltersError ? null : (filtersError ?? this.filtersError),
    busy: busy ?? this.busy,
  );
}

/// RSS 控制器（`autoDispose`：**离开页面自动停轮询**，不泄漏）。
class RssController extends Notifier<RssState> {
  Completer<void>? _pollCancel;
  bool _disposed = false;

  @override
  RssState build() {
    // 页面销毁（autoDispose 无监听者）→ 打断轮询循环（服务端无会话可停，
    // RSS 是纯查询 + 显式 update，**不会**留下需要 stop 的服务端会话）。
    ref.onDispose(() {
      _disposed = true;
      final c = _pollCancel;
      if (c != null && !c.isCompleted) c.complete();
    });
    return const RssState();
  }

  // ------------------------------------------------------------ 订阅列表

  /// 拉订阅列表（`Feed:list`）。成功后：`is_updating` 为真 → 起轮询。
  ///
  /// 失败三态：能力表缺 `RSS.Feed` → [RssBlock.notInstalled]；
  /// 105/160 → [RssBlock.noPrivilege]；网络 → [RssBlock.network]；其它 → 真错误。
  Future<void> loadFeeds() async {
    final api = ref.read(downloadApiProvider);
    if (api == null) {
      state = state.copyWith(
        loading: false,
        block: RssBlock.apiMissing,
        clearError: true,
      );
      return;
    }
    if (!api.hasApi(DownloadStationApi.apiRssFeed)) {
      state = state.copyWith(
        loading: false,
        block: RssBlock.notInstalled,
        clearError: true,
      );
      return;
    }
    state = state.copyWith(loading: true, clearError: true, clearBlock: true);
    try {
      final page = await api.rssFeedList();
      state = state.copyWith(
        loading: false,
        loaded: true,
        feeds: page.items,
        total: page.total,
        clearBlock: true,
        clearError: true,
      );
      _syncPolling(page.items.any((f) => f.isUpdating));
    } catch (e) {
      final block = _blockOfError(e);
      state = state.copyWith(
        loading: false,
        block: block,
        failure: block == null ? downloadFailureKind(e) : null,
        errorText: block == null ? describeDownloadRssError(e) : null,
        clearError: block != null,
      );
    }
  }

  /// `is_updating` 为真时的**官方分页刷新**：每 5 秒 `Feed:list`，直到全部
  /// `is_updating:false` 或到 [rssMaxPollsProvider] 上限。
  void _syncPolling(bool anyUpdating) {
    final running = _pollCancel != null;
    if (anyUpdating && !running) {
      final c = Completer<void>();
      _pollCancel = c;
      unawaited(_pollLoop(c));
    } else if (!anyUpdating && running) {
      _stopPolling();
      state = state.copyWith(polling: false);
    }
  }

  void _stopPolling() {
    final c = _pollCancel;
    _pollCancel = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _pollLoop(Completer<void> cancel) async {
    final maxPolls = ref.read(rssMaxPollsProvider);
    final interval = ref.read(rssPollIntervalProvider);
    var polls = 0;
    state = state.copyWith(polling: true, polls: 0);
    while (!cancel.isCompleted && polls < maxPolls) {
      await Future.any([
        Future<void>.delayed(interval),
        cancel.future,
      ]);
      if (cancel.isCompleted) break;
      polls++;
      if (_disposed) break;
      final api = ref.read(downloadApiProvider);
      if (api == null || !api.hasApi(DownloadStationApi.apiRssFeed)) break;
      try {
        final page = await api.rssFeedList();
        if (_disposed) break;
        state = state.copyWith(
          feeds: page.items,
          total: page.total,
          polls: polls,
          loaded: true,
        );
        if (!page.items.any((f) => f.isUpdating)) break;
      } catch (_) {
        // 轮询失败不打断列表已显示的内容：静默停（用户可手动刷新）。
        break;
      }
    }
    if (identical(_pollCancel, cancel)) _pollCancel = null;
    // dispose 之后**不许**再写 state（Riverpod 会抛）。
    if (!_disposed) state = state.copyWith(polling: false);
  }

  /// 下拉刷新（重拉第一页；正在轮询时先停，再按新数据决定是否重启）。
  Future<void> refreshFeeds() async {
    _stopPolling();
    state = state.copyWith(polling: false);
    await loadFeeds();
  }

  // ------------------------------------------------------------ 写操作

  /// 添加订阅（`Feed:add`，线参 = `url` [+ `enable_auto_download`/`destination`]）。
  ///
  /// 失败**抛**出异常（界面 catch 后用 [describeDownloadRssError] 显示）——
  /// 与列表加载不同，这是用户主动动作，必须给反馈。
  Future<void> addFeed(
    String url, {
    bool enableAutoDownload = false,
    String? destination,
  }) async {
    final api = _requireFeedApi();
    state = state.copyWith(busy: true);
    try {
      await api.rssFeedAdd(
        url: url,
        enableAutoDownload: enableAutoDownload,
        destination: destination,
      );
      await refreshFeeds();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// 删除订阅（`Feed:delete`，官方多选 → `id` 数组）。
  Future<void> deleteFeeds(List<String> ids) async {
    final api = _requireFeedApi();
    state = state.copyWith(busy: true);
    try {
      await api.rssFeedDelete(ids);
      // 删掉的正是当前选中源时清空详情。
      if (ids.contains(state.selectedFeedId)) {
        state = state.copyWith(
          clearSelection: true,
          items: const [],
          itemsTotal: 0,
          itemsLoaded: false,
          filters: const [],
          filtersLoaded: false,
        );
      }
      await refreshFeeds();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// 更新选中订阅（`Feed:update`）→ 之后必然 `is_updating:true`，起轮询。
  Future<void> updateFeeds(List<String> ids) async {
    final api = _requireFeedApi();
    state = state.copyWith(busy: true);
    try {
      await api.rssFeedUpdate(ids);
      await refreshFeeds();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// 全部更新（`Feed:updateall`，无参）。
  Future<void> updateAll() async {
    final api = _requireFeedApi();
    state = state.copyWith(busy: true);
    try {
      await api.rssFeedUpdateAll();
      await refreshFeeds();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  // ------------------------------------------------------------ 条目

  /// 选中一个订阅源（**内部 id 不上屏**）→ 拉条目 + 过滤器。
  Future<void> selectFeed(String id) async {
    if (id.isEmpty) return;
    state = state.copyWith(
      selectedFeedId: id,
      items: const [],
      itemsTotal: 0,
      itemsLoaded: false,
      clearItemsError: true,
      filters: const [],
      filtersLoaded: false,
      clearFiltersError: true,
    );
    await Future.wait([loadItems(), loadFilters()]);
  }

  /// 条目第一页（`Item:list`，参数 `feed_id` + `offset`/`limit`）。
  Future<void> loadItems() async {
    final api = ref.read(downloadApiProvider);
    final feedId = state.selectedFeedId;
    if (api == null || feedId == null || feedId.isEmpty) return;
    if (!api.hasApi(DownloadStationApi.apiRssItem)) {
      state = state.copyWith(
        itemsLoading: false,
        itemsLoaded: true,
        items: const [],
        itemsTotal: 0,
      );
      return;
    }
    state = state.copyWith(
      itemsLoading: true,
      clearItemsError: true,
    );
    try {
      final page = await api.rssItemList(feedId: feedId);
      state = state.copyWith(
        itemsLoading: false,
        itemsLoaded: true,
        items: page.items,
        itemsTotal: page.total,
      );
    } catch (e) {
      state = state.copyWith(
        itemsLoading: false,
        itemsLoaded: true,
        itemsError: describeDownloadRssError(e),
      );
    }
  }

  /// 条目下一页（触底/按钮）。
  Future<void> loadMoreItems() async {
    final api = ref.read(downloadApiProvider);
    final feedId = state.selectedFeedId;
    if (api == null || feedId == null || feedId.isEmpty) return;
    if (state.itemsLoadingMore || state.itemsLoading || !state.hasMoreItems) {
      return;
    }
    state = state.copyWith(itemsLoadingMore: true, clearItemsError: true);
    try {
      final page = await api.rssItemList(
        feedId: feedId,
        offset: state.items.length,
      );
      state = state.copyWith(
        itemsLoadingMore: false,
        items: [...state.items, ...page.items],
        itemsTotal: page.total,
      );
    } catch (e) {
      state = state.copyWith(
        itemsLoadingMore: false,
        itemsError: describeDownloadRssError(e),
      );
    }
  }

  /// 清空选中源的条目（`Item:clear`，参数 `feed_id`）。
  Future<void> clearItems() async {
    final api = ref.read(downloadApiProvider);
    final feedId = state.selectedFeedId;
    if (api == null || feedId == null || feedId.isEmpty) return;
    state = state.copyWith(busy: true);
    try {
      await api.rssItemClear(feedId);
      state = state.copyWith(items: const [], itemsTotal: 0);
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  // ------------------------------------------------------------ 过滤器

  /// 过滤器列表（`Filter:list`，参数 `feed_id`）。
  Future<void> loadFilters() async {
    final api = ref.read(downloadApiProvider);
    final feedId = state.selectedFeedId;
    if (api == null || feedId == null || feedId.isEmpty) return;
    if (!api.hasApi(DownloadStationApi.apiRssFilter)) {
      state = state.copyWith(
        filtersLoading: false,
        filtersLoaded: true,
        filters: const [],
      );
      return;
    }
    state = state.copyWith(filtersLoading: true, clearFiltersError: true);
    try {
      final page = await api.rssFilterList(feedId: feedId);
      state = state.copyWith(
        filtersLoading: false,
        filtersLoaded: true,
        filters: page.items,
      );
    } catch (e) {
      state = state.copyWith(
        filtersLoading: false,
        filtersLoaded: true,
        filtersError: describeDownloadRssError(e),
      );
    }
  }

  /// 新建过滤器（`Filter:add`；**线参已从官方 JS 取证**）。
  /// 成功后 **`Filter:list` 会自己重新加载**（官方 `store.reload()`）。
  Future<void> addFilter({
    required String name,
    required String destination,
    String? match,
    String? notMatch,
    bool isRegex = false,
  }) async {
    final api = _requireFilterApi();
    final feedId = state.selectedFeedId;
    if (feedId == null || feedId.isEmpty) return;
    state = state.copyWith(busy: true);
    try {
      await api.rssFilterAdd(
        feedId: feedId,
        name: name,
        destination: destination,
        match: match,
        notMatch: notMatch,
        isRegex: isRegex,
      );
      await loadFilters();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// **修改**过滤器（`Filter:set` v1）—— E5 原先"编辑规则"误走 `addFilter`
  /// （会多出一条），这里补上真正的 `set` 分支。
  Future<void> editFilter({
    required String id,
    required String name,
    required String destination,
    String? match,
    String? notMatch,
    bool isRegex = false,
  }) async {
    final api = _requireFilterApi();
    final feedId = state.selectedFeedId;
    if (feedId == null || feedId.isEmpty) return;
    state = state.copyWith(busy: true);
    try {
      await api.rssFilterSet(
        id: id,
        feedId: feedId,
        name: name,
        destination: destination,
        match: match,
        notMatch: notMatch,
        isRegex: isRegex,
      );
      await loadFilters();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// **修改订阅**（`Feed:set` v1，改名/改地址）—— E4 缺的「修改」分支。
  Future<void> editFeed({
    required String id,
    String? title,
    String? url,
  }) async {
    final api = _requireFeedApi();
    state = state.copyWith(busy: true);
    try {
      await api.rssFeedSet(id: id, title: title, url: url);
      await refreshFeeds();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// 删除过滤器（`Filter:delete`，`id` 数组）。
  Future<void> deleteFilter(String id) async {
    final api = _requireFilterApi();
    state = state.copyWith(busy: true);
    try {
      await api.rssFilterDelete([id]);
      await loadFilters();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// 试跑过滤器（`Filter:test`，线参 = `test_string`/`match`/`not_match`/`is_regex`）。
  /// 回包取顶层 `matched` 布尔（官方 `onTestDone` 逐字）。
  Future<bool> testFilter({
    required String testString,
    String? match,
    String? notMatch,
    bool isRegex = false,
  }) async {
    final api = _requireFilterApi();
    return api.rssFilterTest(
      testString: testString,
      match: match,
      notMatch: notMatch,
      isRegex: isRegex,
    );
  }

  DownloadStationApi _requireFeedApi() {
    final api = ref.read(downloadApiProvider);
    if (api == null || !api.hasApi(DownloadStationApi.apiRssFeed)) {
      throw DsmApiException(DsmErrorCode.apiNotFound, method: 'RSS.Feed');
    }
    return api;
  }

  DownloadStationApi _requireFilterApi() {
    final api = ref.read(downloadApiProvider);
    if (api == null || !api.hasApi(DownloadStationApi.apiRssFilter)) {
      throw DsmApiException(DsmErrorCode.apiNotFound, method: 'RSS.Filter');
    }
    return api;
  }
}

final rssProvider = NotifierProvider.autoDispose<RssController, RssState>(
  RssController.new,
);

/// 异常 → 中性不可用原因（与 BTSearch 的 `_blockOfCode` 同判据）。
RssBlock? _blockOfError(Object error) {
  if (error is DsmTransportException) return RssBlock.network;
  if (error is! DsmApiException) return null;
  switch (error.code) {
    case DsmErrorCode.apiNotFound:
    case DsmErrorCode.methodNotFound:
    case DsmErrorCode.notSupportedVersion:
    case DsmErrorCode.noMatchLibEntry:
      return RssBlock.notInstalled;
    case DsmErrorCode.noPermission:
    case DsmErrorCode.noAppPrivilege:
    case 524: // SYNODL_ERR_NO_PRIVILEGE
      return RssBlock.noPrivilege;
    case 519: // SYNODL_ERR_NETWORK
      return RssBlock.network;
    default:
      return null;
  }
}
