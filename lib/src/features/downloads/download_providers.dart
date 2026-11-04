// Download Station 模块的依赖注入、状态与动作（阶段二 A 的第一块）。
//
// 分层与其它模块一致：`DsmWebApi → DownloadStationApi（协议）→ providers（本文件）→ 页面`。
// 接口层的事实来源是 `docs/stage2-audio-download-api.md`（逐字对齐 api/method/版本）。
//
// **只做普通用户功能**：全局限速、Scheduler/BTSearch/RSS/FileHosting 等
// admin-only 方法不在这里，也不在 UI 里（见 `download_station.dart` 顶部注释）。
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/i18n/data_text.dart';

import '../../core/provider_retry.dart';
import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../../dsm/webapi.dart';
import '../servers/session_controller.dart';

/// 下载模块的 API 层。未连接时为 null（页面显示"未连接"而不是崩）。
final downloadApiProvider = Provider<DownloadStationApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : DownloadStationApi(conn.api);
});

/// 当前选中的分类（全部/下载中/已完成/错误）。
final downloadCategoryProvider =
    NotifierProvider<DownloadCategoryNotifier, DownloadTaskCategory>(
      DownloadCategoryNotifier.new,
    );

class DownloadCategoryNotifier extends Notifier<DownloadTaskCategory> {
  @override
  DownloadTaskCategory build() => DownloadTaskCategory.all;

  void select(DownloadTaskCategory c) => state = c;
}

/// 任务列表的本地状态（分页 + 分类 + 是否还有更多）。
class DownloadListState {
  const DownloadListState({
    this.items = const [],
    this.total = 0,
    this.category = DownloadTaskCategory.all,
    this.keyword = '',
    this.sortBy,
    this.descending = false,
    this.loading = false,
    this.loadingMore = false,
    this.loaded = false,
    this.failure,
    this.errorText,
    this.apiMissing = false,
  });

  final List<DownloadTaskDto> items;
  final int total;
  final DownloadTaskCategory category;

  /// 服务端 `keyword` 过滤（界面搜索框；原 DC-4 的"无 UI 入口"）。
  final String keyword;

  /// 排序键（[DownloadStationApi.sortFields] 的 key）；null = 服务端默认序。
  final String? sortBy;
  final bool descending;

  /// 首页加载中（骨架屏）。
  final bool loading;

  /// 触底加载下一页中。
  final bool loadingMore;

  /// 至少成功加载过一次（区分"还没加载"与"加载完是空的"）。
  final bool loaded;

  /// 失败大类（套件未安装 / 无权限 / 网络 / 其它）。
  final DsFailureKind? failure;

  /// 失败的可读文案（`describeDownloadError`）。
  final String? errorText;

  /// 还没连接会话（`downloadApiProvider == null`）。
  final bool apiMissing;

  bool get hasMore => items.length < total;

  DownloadListState copyWith({
    List<DownloadTaskDto>? items,
    int? total,
    DownloadTaskCategory? category,
    String? keyword,
    String? sortBy,
    bool clearSort = false,
    bool? descending,
    bool? loading,
    bool? loadingMore,
    bool? loaded,
    DsFailureKind? failure,
    String? errorText,
    bool? apiMissing,
    bool clearError = false,
  }) => DownloadListState(
    items: items ?? this.items,
    total: total ?? this.total,
    category: category ?? this.category,
    keyword: keyword ?? this.keyword,
    sortBy: clearSort ? null : (sortBy ?? this.sortBy),
    descending: descending ?? this.descending,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    loaded: loaded ?? this.loaded,
    failure: clearError ? null : (failure ?? this.failure),
    errorText: clearError ? null : (errorText ?? this.errorText),
    apiMissing: apiMissing ?? this.apiMissing,
  );
}

/// 列表控制器（与 `SearchController` 同一套路：显式 `load`/`loadMore`）。
class DownloadListController extends Notifier<DownloadListState> {
  @override
  DownloadListState build() {
    // 分类变化时由页面调用 `load()`；这里只给初始值，避免 build 里发请求。
    final category = ref.read(downloadCategoryProvider);
    return DownloadListState(category: category);
  }

  DownloadStationApi? get _api => ref.read(downloadApiProvider);

  /// 拉第一页（`offset=0`）。[silent] 为 true 时不清空旧数据（下拉刷新）。
  Future<void> load({bool silent = false}) async {
    // ★ r320（D19）：**顶部速率条与列表是同一份队列的两个视图** —— 凡"任务集合/状态变了"
    //   的路径都会重拉列表，所以统计条统一在这里一起作废。
    //   缺陷原文（像素 `docs/evidence-r320/img/08_download_deleted.png`）：
    //   删掉唯一任务后列表已经 `0 tasks`，顶部却还挂着 `Down 1 KB/s`
    //   —— 因为 `_confirmDelete`/`_toggle`/`_confirmForceComplete` 只刷了列表，
    //   而其它几处（新建/验证码/批量）各自手写了 `invalidate(downloadStatisticProvider)`。
    //   把机制收在**一个地方**，就不会再漏第四个写动词。
    _refreshStatistic();
    final category = ref.read(downloadCategoryProvider);
    final api = _api;
    if (api == null) {
      state = state.copyWith(
        category: category,
        loading: false,
        apiMissing: true,
        clearError: true,
      );
      return;
    }
    // 能力表已 discover 且里面没有这个 API → 套件未安装，直接给结论，
    // 不用发一次注定 102 的请求。
    if (!api.installed) {
      state = state.copyWith(
        category: category,
        loading: false,
        loaded: true,
        items: const [],
        total: 0,
        failure: DsFailureKind.notInstalled,
        errorText: describeDownloadError(
          DsmApiException(DsmErrorCode.apiNotFound, method: 'Task.list'),
        ),
      );
      return;
    }
    state = state.copyWith(
      category: category,
      loading: true,
      apiMissing: false,
      items: silent ? null : const [],
      total: silent ? null : 0,
      clearError: true,
    );
    try {
      final page = await api.listTasks(
        offset: 0,
        limit: DownloadStationApi.pageSize,
        category: category,
        keyword: state.keyword,
        sortBy: state.sortBy,
        descending: state.descending,
      );
      state = state.copyWith(
        loading: false,
        loaded: true,
        items: page.items,
        total: page.total,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        loaded: true,
        failure: downloadFailureKind(e),
        errorText: describeDownloadError(e),
      );
    }
  }

  /// 触底加载下一页。
  Future<void> loadMore() async {
    if (state.loadingMore || state.loading || !state.hasMore) return;
    final api = _api;
    if (api == null) return;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await api.listTasks(
        offset: state.items.length,
        limit: DownloadStationApi.pageSize,
        category: state.category,
        keyword: state.keyword,
        sortBy: state.sortBy,
        descending: state.descending,
      );
      state = state.copyWith(
        loadingMore: false,
        items: [...state.items, ...page.items],
        total: page.total,
      );
    } catch (e) {
      state = state.copyWith(
        loadingMore: false,
        failure: downloadFailureKind(e),
        errorText: describeDownloadError(e),
      );
    }
  }

  /// 换分类并立刻重拉。
  Future<void> select(DownloadTaskCategory category) async {
    if (state.category == category) return;
    ref.read(downloadCategoryProvider.notifier).select(category);
    state = state.copyWith(category: category, items: const [], total: 0);
    await load();
  }

  /// 关键字搜索（服务端 `keyword`）—— 原 DC-4 的"参数在接口、UI 无入口"。
  Future<void> search(String keyword) async {
    final k = keyword.trim();
    if (state.keyword == k) return;
    state = state.copyWith(keyword: k, items: const [], total: 0);
    await load();
  }

  /// 排序（服务端 `sort_by`/`order`）。传 null 回到服务端默认序。
  Future<void> sort(String? field, {bool descending = false}) async {
    if (state.sortBy == field && state.descending == descending) return;
    state = state.copyWith(
      sortBy: field,
      clearSort: field == null,
      descending: descending,
      items: const [],
      total: 0,
    );
    await load();
  }

  /// 下拉刷新 / 写操作后刷新。
  Future<void> refresh() => load(silent: true);

  /// 让顶部统计条跟着重算（`load()` 内部调用；`ref` 已销毁时跳过）。
  void _refreshStatistic() {
    if (ref.mounted) ref.invalidate(downloadStatisticProvider);
  }
}

final downloadListProvider =
    NotifierProvider<DownloadListController, DownloadListState>(
      DownloadListController.new,
    );

/// 顶部总速率（`Task.Statistic.get` v1）。失败就给 null，不阻塞列表。
final downloadStatisticProvider = FutureProvider<DownloadTaskStatistic?>((
  ref,
) async {
  final api = ref.watch(downloadApiProvider);
  if (api == null || !api.installed) return null;
  try {
    return await api.statistic();
  } catch (_) {
    return null;
  }
}, retry: noRetry);

/// 默认下载目录（`Settings.Location.get` v1，normal）—— 新建表单预填用。
final downloadDefaultDestProvider = FutureProvider<String>((ref) async {
  final api = ref.watch(downloadApiProvider);
  if (api == null || !api.installed) return '';
  try {
    return await api.defaultDestination();
  } catch (_) {
    return '';
  }
}, retry: noRetry);

/// 单个任务的详情（普通用户可读）。
final downloadTaskProvider = FutureProvider.family<DownloadTaskDto?, String>((
  ref,
  id,
) async {
  final api = ref.watch(downloadApiProvider);
  if (api == null || !api.installed) return null;
  return api.getTask(id);
}, retry: noRetry);

/// 单个 BT 任务的设置（`Task.BT.get` v2）。
final downloadBtSettingsProvider =
    FutureProvider.family<DownloadBtSettings, String>((ref, taskId) async {
      final api = ref.watch(downloadApiProvider);
      if (api == null) throw StateError('未连接');
      return api.getBtSettings(taskId);
    }, retry: noRetry);

/// BT 任务的 Tracker 列表（`Task.BT.Tracker.list` v2，**只读**）。
final downloadTrackersProvider =
    FutureProvider.family<DownloadTrackerPage, String>((ref, taskId) async {
      final api = ref.watch(downloadApiProvider);
      if (api == null) throw StateError('未连接');
      return api.listTrackers(taskId);
    }, retry: noRetry);

/// BT 任务的 Peer 列表（`Task.BT.Peer.list` v2，**只读**）。
final downloadPeersProvider =
    FutureProvider.family<DownloadPeerPage, String>((ref, taskId) async {
      final api = ref.watch(downloadApiProvider);
      if (api == null) throw StateError('未连接');
      return api.listPeers(taskId);
    }, retry: noRetry);

/// 任务内文件清单的本地状态（A6，分页 + 明确收尾态）。
///
/// 官方 store 每页 `NUM_REC_PER_PAGE = 25`（[DownloadStationApi.pageSize]），
/// `offset` 续取。**必须有收尾态**：要么 `hasMore=false`，要么服务端回空页
/// （`reachedEnd=true`）—— 界面据此停掉"加载更多"，不会无限转圈。
class DownloadFilesState {
  const DownloadFilesState({
    this.items = const [],
    this.total = 0,
    this.loading = false,
    this.loadingMore = false,
    this.loaded = false,
    this.reachedEnd = false,
    this.inactive = false,
    this.errorText,
  });

  final List<DownloadFileDto> items;
  final int total;
  final bool loading;
  final bool loadingMore;
  final bool loaded;

  /// 服务端已回空页 / 已取满 → 不再有下一页。
  final bool reachedEnd;

  /// **中性态**：任务未激活（暂停/已完成）→ 服务端回 1913，没有可读文件清单。
  ///
  /// 真机实测（`docs/download-api-live.md:98/135/137`）：这个码的开关是
  /// `is_active_torrent`，与"是不是 BT 任务"无关；**不是错误**，不该显示
  /// "加载失败"。
  final bool inactive;
  final String? errorText;

  /// 还有下一页可点（页数由 `total` 与已加载条数共同决定，且没到底）。
  bool get hasMore => !reachedEnd && items.length < total;

  DownloadFilesState copyWith({
    List<DownloadFileDto>? items,
    int? total,
    bool? loading,
    bool? loadingMore,
    bool? loaded,
    bool? reachedEnd,
    bool? inactive,
    String? errorText,
    bool clearError = false,
  }) => DownloadFilesState(
    items: items ?? this.items,
    total: total ?? this.total,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    loaded: loaded ?? this.loaded,
    reachedEnd: reachedEnd ?? this.reachedEnd,
    inactive: inactive ?? this.inactive,
    errorText: clearError ? null : (errorText ?? this.errorText),
  );
}

class DownloadFilesController extends Notifier<DownloadFilesState> {
  DownloadFilesController(this.taskId);

  final String taskId;

  @override
  DownloadFilesState build() => const DownloadFilesState();

  DownloadStationApi? get _api => ref.read(downloadApiProvider);

  /// 拉第一页（`offset=0`）。
  Future<void> load() async {
    final api = _api;
    if (api == null) {
      state = state.copyWith(
        loaded: true,
        errorText: dataText('setNotConnected', '未连接'),
      );
      return;
    }
    state = state.copyWith(loading: true, clearError: true);
    try {
      final page = await api.listFiles(
        taskId,
        offset: 0,
        limit: DownloadStationApi.pageSize,
      );
      state = DownloadFilesState(
        items: page.items,
        total: page.total,
        loaded: true,
        // 服务端回空/已取满 → 直接到底
        reachedEnd: page.items.isEmpty || page.items.length >= page.total,
      );
    } on DsmApiException catch (e) {
      // 1913 = 任务未激活（暂停/已完成）→ **中性态**，不是"加载失败"。
      if (e.code == DownloadStationApi.errFileListInactive) {
        state = const DownloadFilesState(
          loaded: true,
          reachedEnd: true,
          inactive: true,
        );
      } else {
        state = DownloadFilesState(
          loaded: true,
          errorText: describeDownloadError(e),
        );
      }
    } catch (e) {
      state = DownloadFilesState(
        loaded: true,
        errorText: describeDownloadError(e),
      );
    }
  }

  /// 续取下一页。到底/正在跑/没得取时直接返回（幂等，不会自旋）。
  Future<void> loadMore() async {
    final api = _api;
    if (api == null || state.loading || state.loadingMore || !state.hasMore) {
      return;
    }
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      final page = await api.listFiles(
        taskId,
        offset: state.items.length,
        limit: DownloadStationApi.pageSize,
      );
      final merged = [...state.items, ...page.items];
      state = state.copyWith(
        items: merged,
        total: page.total,
        loadingMore: false,
        reachedEnd: page.items.isEmpty || merged.length >= page.total,
      );
    } catch (e) {
      state = state.copyWith(
        loadingMore: false,
        errorText: describeDownloadError(e),
      );
    }
  }
}

/// 任务内文件清单（A6）。`family` 的 key 是任务 id。
final downloadFilesProvider =
    NotifierProvider.family<DownloadFilesController, DownloadFilesState, String>(
      DownloadFilesController.new,
    );

/// BT 预览缩略图（F8，`Thumbnail.get` v2 + `Thumbnail.download` v2）。
///
/// **失败/为空一律回 null**，界面据此回落既有状态图标（任务书硬要求：
/// 不许空白、不许把内部 id 当文案显示）。缩略图是纯装饰，不阻塞任务行。
///
/// 真机边界（`docs/download-api-live.md:115/139-141`）：`Thumbnail.get` 在
/// "暂无缩略图"时回 **1911**（整片下完、5 种参数形态仍 1911）→ 按中性回落；
/// **成功回包未取证**。
final downloadThumbnailProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, taskId) async {
      final api = ref.watch(downloadApiProvider);
      if (api == null) return null;
      try {
        final list = await api.thumbnails(taskId);
        if (list.isEmpty) return null;
        final bytes = await api.thumbnailBytes(list.first.thumbnailId);
        return bytes.isEmpty ? null : Uint8List.fromList(bytes);
      } on DsmApiException catch (e) {
        // 1911 = 暂无缩略图（中性）；其它错误也回落图标（纯装饰，不打扰用户）。
        if (e.code == DownloadStationApi.errNoThumbnail) return null;
        return null;
      } catch (_) {
        return null;
      }
    }, retry: noRetry);

/// 自动解压设置（F9，`Settings.AutoExtraction.get` v1，普通用户可读）。
final downloadAutoExtractionProvider =
    FutureProvider<DownloadAutoExtractionSettings>((ref) async {
      final api = ref.watch(downloadApiProvider);
      if (api == null) throw StateError('未连接');
      return api.autoExtraction();
    }, retry: noRetry);

// ------------------------------------------------ F14：Package 能力探测

/// 套件版本（F14，`Package.Info.get` v2）。
///
/// 能力表里没有这个 API（老 DS 或未装）→ 返回 null，设置页不显示版本块而不是报错。
final downloadPackageInfoProvider = FutureProvider<DsPackageInfo?>((ref) async {
  final api = ref.watch(downloadApiProvider);
  if (api == null || !api.hasApi(DownloadStationApi.apiPkgInfo)) return null;
  return api.packageInfo();
}, retry: noRetry);

/// 已安装模块（F14，`Package.Module.list` v2）。
final downloadPackageModulesProvider = FutureProvider<List<DsPackageModule>>((
  ref,
) async {
  final api = ref.watch(downloadApiProvider);
  if (api == null || !api.hasApi(DownloadStationApi.apiPkgModule)) return const [];
  return api.packageModules();
}, retry: noRetry);

/// 服务/能力位（F14，`Package.Service.get` v2）。
final downloadPackageServiceProvider =
    FutureProvider<DsPackageService?>((ref) async {
      final api = ref.watch(downloadApiProvider);
      if (api == null || !api.hasApi(DownloadStationApi.apiPkgService)) {
        return null;
      }
      return api.packageService();
    }, retry: noRetry);

// ------------------------------------------------ F5/F6：NZB 日志与文件清单

/// NZB 任务的日志（F5，`Task.NZB.Log.get` v1）。
///
/// `404` 是**中性**态（任务不存在 / 不是 NZB 任务 / 还没有日志）→ 界面给空态，
/// 不是加载失败（真机只读实调：`task_id=bogus` → `404`）。
final downloadNzbLogProvider = FutureProvider.family<String, String>((
  ref,
  taskId,
) async {
  final api = ref.watch(downloadApiProvider);
  if (api == null) throw StateError('未连接');
  try {
    final log = await api.nzbLog(taskId);
    return log.log;
  } on DsmApiException catch (e) {
    if (e.code == DownloadStationApi.errNzbNotAvailable) return '';
    rethrow;
  }
}, retry: noRetry);

/// NZB 文件清单的本地状态（F6，分页 + 收尾态；`404` 是中性态）。
class DownloadNzbFilesState {
  const DownloadNzbFilesState({
    this.items = const [],
    this.total = 0,
    this.loading = false,
    this.loadingMore = false,
    this.loaded = false,
    this.reachedEnd = false,
    this.unavailable = false,
    this.errorText,
  });

  final List<DsNzbFile> items;
  final int total;
  final bool loading;
  final bool loadingMore;
  final bool loaded;
  final bool reachedEnd;

  /// `404` 中性态：任务不存在或不是 NZB 任务。
  final bool unavailable;
  final String? errorText;

  bool get hasMore => !reachedEnd && items.length < total;

  DownloadNzbFilesState copyWith({
    List<DsNzbFile>? items,
    int? total,
    bool? loading,
    bool? loadingMore,
    bool? loaded,
    bool? reachedEnd,
    bool? unavailable,
    String? errorText,
    bool clearError = false,
  }) => DownloadNzbFilesState(
    items: items ?? this.items,
    total: total ?? this.total,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    loaded: loaded ?? this.loaded,
    reachedEnd: reachedEnd ?? this.reachedEnd,
    unavailable: unavailable ?? this.unavailable,
    errorText: clearError ? null : (errorText ?? this.errorText),
  );
}

class DownloadNzbFilesController extends Notifier<DownloadNzbFilesState> {
  DownloadNzbFilesController(this.taskId);

  final String taskId;

  @override
  DownloadNzbFilesState build() => const DownloadNzbFilesState();

  DownloadStationApi? get _api => ref.read(downloadApiProvider);

  Future<void> load() async {
    final api = _api;
    if (api == null) {
      state = state.copyWith(
        loaded: true,
        errorText: dataText('setNotConnected', '未连接'),
      );
      return;
    }
    state = state.copyWith(loading: true, clearError: true);
    try {
      final page = await api.nzbFiles(
        taskId,
        offset: 0,
        limit: DownloadStationApi.pageSize,
      );
      state = DownloadNzbFilesState(
        items: page.items,
        total: page.total,
        loaded: true,
        reachedEnd: page.items.isEmpty || page.items.length >= page.total,
      );
    } on DsmApiException catch (e) {
      if (e.code == DownloadStationApi.errNzbNotAvailable) {
        state = const DownloadNzbFilesState(
          loaded: true,
          reachedEnd: true,
          unavailable: true,
        );
      } else {
        state = DownloadNzbFilesState(
          loaded: true,
          errorText: describeDownloadError(e),
        );
      }
    } catch (e) {
      state = DownloadNzbFilesState(
        loaded: true,
        errorText: describeDownloadError(e),
      );
    }
  }

  Future<void> loadMore() async {
    final api = _api;
    if (api == null || state.loading || state.loadingMore || !state.hasMore) {
      return;
    }
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      final page = await api.nzbFiles(
        taskId,
        offset: state.items.length,
        limit: DownloadStationApi.pageSize,
      );
      final merged = [...state.items, ...page.items];
      state = state.copyWith(
        items: merged,
        total: page.total,
        loadingMore: false,
        reachedEnd: page.items.isEmpty || merged.length >= page.total,
      );
    } catch (e) {
      state = state.copyWith(
        loadingMore: false,
        errorText: describeDownloadError(e),
      );
    }
  }
}

/// NZB 任务内文件清单（F6）。`family` 的 key 是任务 id。
final downloadNzbFilesProvider =
    NotifierProvider.family<
      DownloadNzbFilesController,
      DownloadNzbFilesState,
      String
    >(DownloadNzbFilesController.new);

/// `create_list=true` 建任务后的待选文件清单（`Task.List.get` v2）。
final downloadCreateListProvider =
    FutureProvider.family<DownloadCreateList, String>((ref, listId) async {
      final api = ref.watch(downloadApiProvider);
      if (api == null) throw StateError('未连接');
      return api.getCreateList(listId);
    }, retry: noRetry);

/// **需要输入验证码的下载任务**（`Captcha:list` v2，wave5）。
///
/// 返回的是**内部任务 id**（只进 Key / 请求参数，**绝不上屏**）。
/// 取不到（能力位缺失 / 出错）时**不抛**：验证码入口另有"任务状态
/// `15 = captchaNeeded`"这条兜底判据（见 `download_page.dart`），
/// 所以这里失败不会让入口消失（**不静默**）。
final downloadCaptchaProvider = FutureProvider<List<String>>((ref) async {
  final api = ref.watch(downloadApiProvider);
  if (api == null || !api.hasApi(DownloadStationApi.apiCaptcha)) return const [];
  try {
    return await api.captchaTaskIds();
  } catch (_) {
    return const [];
  }
}, retry: noRetry);

/// **待输入验证码的任务 id**：`Captcha:list` 优先，为空时回落到任务状态 15。
///
/// ★★ DA81（r423 真机发现）：这个判据**必须只有一份**。
/// 原来入口条（`download_page.dart`）用的是"`Captcha:list` 非空就信它，
/// 否则数任务里 `status == 15` 的条数"，而验证码页
/// （`download_captcha_page.dart`）**只读** `Captcha:list` —— 两者于是会
/// **当面互相打脸**：入口说「1 个任务需要输入验证码」，点进去说
/// 「没有需要验证码的任务」（真机复现：先建一个等待验证码的任务，
/// 而页面的 provider 在队列还是空的时候就已经取过一次、值被缓存住）。
/// ⇒ 判据抽到这里，入口与页面**共用**，谁都不许自己再写一遍。
///
/// [fromServer] 取 `downloadCaptchaProvider` 的值，[tasks] 取任务列表。
List<String> captchaPendingIds(List<String> fromServer, List<DownloadTaskDto> tasks) {
  if (fromServer.isNotEmpty) return fromServer;
  return [
    for (final t in tasks)
      if (t.status == DsTaskStatus.captchaNeeded) t.id,
  ];
}

/// 单个任务的**验证码图片**（`Captcha:download` v2，直链取字节）。
///
/// [cacheBuster] 变化 → provider family key 变化 → 重新取图（提交错一次后
/// 官方会换一张新图，界面据此刷新）。
/// 取不到（真机是 **HTTP 404 + HTML**）一律回落 `null`，由界面显示"验证码图片
/// 加载失败，请重试"的**明确提示**（不是空白）。
final downloadCaptchaImageProvider = FutureProvider.autoDispose
    .family<Uint8List?, (String, String)>((ref, key) async {
      final api = ref.watch(downloadApiProvider);
      if (api == null) return null;
      try {
        final bytes = await api.captchaImageBytes(key.$1, cacheBuster: key.$2);
        return bytes.isEmpty ? null : Uint8List.fromList(bytes);
      } catch (_) {
        return null;
      }
    }, retry: noRetry);

/// 写操作（暂停/继续/删除/建任务/BT 限速/批量条件操作）—— 页面直接用，
/// 失败抛给页面提示。
class DownloadActions {
  const DownloadActions(this.api);

  final DownloadStationApi? api;

  Future<void> pause(List<String> ids) async => api?.pauseTasks(ids);

  Future<void> resume(List<String> ids) async => api?.resumeTasks(ids);

  Future<void> delete(List<String> ids) async => api?.deleteTasks(ids);

  /// 结束/强制完成（官方 `str_force_complete`）：`force_complete=true`。
  ///
  /// 原 DC-3：`deleteTasks(forceComplete:true)` 参数存在但 UI 从不传 —— 这里接线。
  Future<void> forceComplete(List<String> ids) async =>
      api?.deleteTasks(ids, forceComplete: true);

  /// 全部暂停（`Task.pause_condition` v2）。
  Future<void> pauseAll() async => api?.pauseAll();

  /// 全部恢复（`Task.resume_condition` v2）。
  Future<void> resumeAll() async => api?.resumeAll();

  /// 清除已完成（`Task.delete_condition` v2，`status:[5]`）。
  Future<void> clearFinished() async =>
      api?.deleteCondition(statuses: const [DsTaskStatus.finished]);

  /// 删除错误任务（`Task.delete_condition` v2，`status` = 错误态全表）。
  Future<void> removeErrors() async =>
      api?.deleteCondition(statuses: DsTaskStatus.errorGroup);

  Future<DsCreateResult> createUrl({
    required List<String> urls,
    String? destination,
    String? username,
    String? password,
    String? extractPassword,
    bool createList = false,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.createUrlTask(
      urls: urls,
      destination: destination,
      username: username,
      password: password,
      extractPassword: extractPassword,
      createList: createList,
    );
  }

  Future<DsCreateResult> createFile({
    required String filePath,
    required String fileName,
    String? destination,
    String? extractPassword,
    bool createList = false,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.createFileTask(
      filePath: filePath,
      fileName: fileName,
      destination: destination,
      extractPassword: extractPassword,
      createList: createList,
    );
  }

  /// 消费 `create_list` 返回的 `listId`：用选中的文件下标开始下载。
  Future<String> downloadCreateList({
    required String listId,
    String? destination,
    List<int>? selected,
    bool createSubfolder = true,
    String? extractPassword,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.downloadCreateList(
      listId: listId,
      destination: destination,
      selected: selected,
      createSubfolder: createSubfolder,
      extractPassword: extractPassword,
    );
  }

  /// 放弃选择时清掉服务端临时清单（`Task.List.delete` v2）。
  Future<void> discardCreateList(String listId) async =>
      api?.deleteCreateList(listId);

  /// 开始下载清单里的文件 —— **优先官方 Web UI 的轮询路径**
  /// `Task.List.Polling.download`（v2，回 `task_id` 可看进度）；
  /// 该能力位缺失（老 NAS 只有 `Task.List` v1–v2）时降级到
  /// `Task.List.download`（真机钉死要 `list_id` + **`destination`**）。
  ///
  /// 降级时若表单没给目录，先读 `Settings.Location.get` 的默认目录
  /// （读操作）；连默认目录都没有 → 抛 `406 = NO_DEFAULT_DEST`，
  /// 界面给"还没设置默认下载目录"的明确提示（不是静默失败）。
  Future<String> startCreateList({
    required String listId,
    String? destination,
    List<int>? selected,
    bool createSubfolder = true,
    String? extractPassword,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    if (a.hasApi(DownloadStationApi.apiTaskListPolling)) {
      return a.downloadCreateList(
        listId: listId,
        destination: destination,
        selected: selected,
        createSubfolder: createSubfolder,
        extractPassword: extractPassword,
      );
    }
    var dest = destination ?? '';
    if (dest.isEmpty) dest = await a.defaultDestination();
    if (dest.isEmpty) {
      throw DsmApiException(
        406,
        method: '${DownloadStationApi.apiTaskList}.download',
      );
    }
    return a.taskListDownload(
      listId: listId,
      destination: dest,
      selected: selected,
      createSubfolder: createSubfolder,
      extractPassword: extractPassword,
    );
  }

  /// 提交某个下载任务的验证码（`Captcha.set` v2，`{task_id, code}`）。
  ///
  /// 失败**必须**让调用方看到（`2301` = 验证码不正确，由
  /// [`describeDownloadError`] 翻成中文），不许吞。
  Future<void> submitCaptcha({
    required String taskId,
    required String code,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.setCaptcha(taskId: taskId, code: code);
  }

  Future<void> saveBtSettings(String taskId, DownloadBtSettings s) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.setBtSettings(taskId, s);
  }

  /// 自动解压设置（F9，`Settings.AutoExtraction.set` v1）—— **写操作**。
  ///
  /// ★ r410（G-r408-01）：设置页现在暴露**全部 6 个可写字段**，所以在
  /// 这里把 6 个都透传下去（null = 这个字段本轮没改，**不下发**）。
  Future<void> setAutoExtraction({
    bool? enableUnzip,
    bool? unzipLocationToCurrentFolder,
    String? unzipToPath,
    bool? createSubfolder,
    bool? deleteArchive,
    bool? unzipOverwrite,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.setAutoExtraction(
      enableUnzip: enableUnzip,
      unzipLocationToCurrentFolder: unzipLocationToCurrentFolder,
      unzipToPath: unzipToPath,
      createSubfolder: createSubfolder,
      deleteArchive: deleteArchive,
      unzipOverwrite: unzipOverwrite,
    );
  }

  /// 改任务目的地（B8，`Task.edit` v1–v2）—— **写操作**。
  Future<void> editDestination(
    List<String> ids, {
    String? destination,
    String? priority,
    String? extractPassword,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.editTask(
      ids,
      destination: destination,
      priority: priority,
      extractPassword: extractPassword,
    );
  }

  /// 把任务内文件复制到别的目录（B10，`Task.BT.File.copy` v2）—— **写操作**。
  Future<void> copyFileTo({
    required String taskId,
    required List<int> indexes,
    required String destination,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.copyTaskFile(
      taskId: taskId,
      indexes: indexes,
      destination: destination,
    );
  }

  /// 任务内文件优先级 / 跳过（A6，`Task.BT.File.set` v2）—— **写操作**。
  ///
  /// `priority` 取官方菜单的 `high|normal|low`；`wanted:false` = 跳过该文件
  /// （官方 `skipHandler`）。两者不同时下发（官方也是两次独立调用）。
  Future<void> setFileOptions({
    required String taskId,
    required List<int> indexes,
    String? priority,
    bool? wanted,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.setTaskFiles(
      taskId: taskId,
      indexes: indexes,
      priority: priority,
      wanted: wanted,
    );
  }

  /// 新建任务后的"立即开始/排队 + 限速"（C12）。
  ///
  /// 先按**创建前**的 id 快照找出新任务，再应用选项。找不到新任务时返回 false
  /// （**不代表创建失败**，只是选项没生效）。
  Future<bool> applyCreateOptionsToNewest({
    required Set<String> knownIds,
    bool startImmediately = true,
    int? maxDownloadRate,
    int? maxUploadRate,
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    final id = await a.newestTaskId(knownIds);
    if (id == null) return false;
    return a.applyCreateOptions(
      taskId: id,
      startImmediately: startImmediately,
      maxDownloadRate: maxDownloadRate,
      maxUploadRate: maxUploadRate,
    );
  }

  /// 创建前的任务 id 快照（C12 用；只读）。
  Future<Set<String>> taskIdSnapshot() async {
    final a = api;
    if (a == null) return const <String>{};
    final page = await a.listTasks(
      offset: 0,
      limit: DownloadStationApi.pageSize,
    );
    return {for (final t in page.items) t.id};
  }
}

final downloadActionsProvider = Provider<DownloadActions>(
  (ref) => DownloadActions(ref.watch(downloadApiProvider)),
);
