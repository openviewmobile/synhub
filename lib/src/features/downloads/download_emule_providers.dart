// ⑥下载 F1：**eMule 任务**（官方安卓端有独立的 `EmuleListFragment`）。
//
// 事实来源（全部可核）：
// * 下载列表：`SYNO.DownloadStation2.Task / list` v2，官方 aMule 面板逐字
//   `{additional:["detail","transfer"], type:["emule"]}`（**不带** `type_inverse`；
//   默认队列才带 `type_inverse:true` 把 eMule 排除掉）；
// * 上传列表：`SYNO.DownloadStation2.Task.eMule / list_upload` v1 ——
//   包内 `.lib` 的 `allowUser` **不含** normal ⇒ **管理员专属**，
//   所以它只出现在 `AdminOnly` 子树里（新规 R2/R3）；
// * 开关：`Package.Service / get` v2 的 `enable_emule`（已有的 provider）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../../core/provider_retry.dart';
import 'download_providers.dart';

/// eMule 任务列表状态（与主队列同构，但走 `emuleOnly` 参数）。
class EmuleTaskState {
  const EmuleTaskState({
    this.items = const [],
    this.total = 0,
    this.loading = false,
    this.loadingMore = false,
    this.loaded = false,
    this.errorText,
  });

  final List<DownloadTaskDto> items;
  final int total;
  final bool loading;
  final bool loadingMore;
  final bool loaded;
  final String? errorText;

  bool get hasMore => items.length < total;

  EmuleTaskState copyWith({
    List<DownloadTaskDto>? items,
    int? total,
    bool? loading,
    bool? loadingMore,
    bool? loaded,
    String? errorText,
    bool clearError = false,
  }) => EmuleTaskState(
    items: items ?? this.items,
    total: total ?? this.total,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    loaded: loaded ?? this.loaded,
    errorText: clearError ? null : (errorText ?? this.errorText),
  );
}

class EmuleTaskController extends Notifier<EmuleTaskState> {
  DownloadStationApi? get _api => ref.read(downloadApiProvider);

  @override
  EmuleTaskState build() {
    Future.microtask(load);
    return const EmuleTaskState(loading: true);
  }

  Future<void> load() async {
    final api = _api;
    if (api == null) {
      state = state.copyWith(loading: false, loaded: true);
      return;
    }
    state = state.copyWith(
      loading: true,
      items: const [],
      total: 0,
      clearError: true,
    );
    try {
      final page = await api.listTasks(
        offset: 0,
        limit: DownloadStationApi.pageSize,
        emuleOnly: true,
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
        errorText: describeDownloadError(e),
      );
    }
  }

  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    final api = _api;
    if (api == null) return;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await api.listTasks(
        offset: state.items.length,
        limit: DownloadStationApi.pageSize,
        emuleOnly: true,
      );
      state = state.copyWith(
        loadingMore: false,
        items: [...state.items, ...page.items],
        total: page.total,
      );
    } catch (e) {
      state = state.copyWith(
        loadingMore: false,
        errorText: describeDownloadError(e),
      );
    }
  }

  /// 暂停 / 继续 / 删除（复用主队列同一族方法，只换任务 id）。
  Future<void> pause(List<String> ids) => _act((a) => a.pauseTasks(ids));
  Future<void> resume(List<String> ids) => _act((a) => a.resumeTasks(ids));
  Future<void> delete(List<String> ids) => _act((a) => a.deleteTasks(ids));

  Future<void> _act(Future<void> Function(DownloadStationApi a) fn) async {
    final api = _api;
    if (api == null) return;
    try {
      await fn(api);
    } finally {
      await load();
    }
  }
}

final emuleTasksProvider =
    NotifierProvider.autoDispose<EmuleTaskController, EmuleTaskState>(
      EmuleTaskController.new,
    );

/// eMule **上传**列表（管理员）：`Task.eMule / list_upload` v1。
///
/// 只在管理员身份下被订阅（页面用 `AdminOnly` 包住），失败也不外抛 ——
/// 上传列表是附加信息，取不到就给空列表。
final emuleUploadsProvider = FutureProvider.autoDispose<List<DsEmuleUpload>>((
  ref,
) async {
  final api = ref.watch(downloadApiProvider);
  if (api == null) return const [];
  if (!api.hasApi(DownloadStationApi.apiEmuleUpload)) return const [];
  try {
    final page = await api.emuleUploads(limit: 50);
    return page.items;
  } catch (_) {
    return const [];
  }
}, retry: noRetry);
