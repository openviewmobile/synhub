// ⑥下载 F3：**eMule 搜索**（`SYNO.DownloadStation2.eMule.Search` v1）。
//
// 官方前端 `ui/download.js` 的 aMule 搜索面板逐字：
// * `start`：`{keyword, search_type, file_type}` 恒发，其余**填了才发**；
// * 回包 `id` = 搜索会话 id；
// * `list`：`{id, sort_by, order, offset, limit}`，root `results`，
//   `search_done` 为 true 即抓完；官方还限 `maxRequestTimes = 5` 次轮询；
// * `stop`：`{id}`（0 = 全部）；
// * `download`：`{file_id:[…]}` 把结果建成下载任务（官方 `actionDownload`）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../data/download_station.dart';
import '../../dsm/webapi.dart';
import '../../data/dto/download_task_dto.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'download_providers.dart';

/// 轮询间隔 / 次数上限（测试可覆盖；官方是 3–5 秒、最多 5 次）。
final emuleSearchPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 3),
);
final emuleSearchMaxPollsProvider = Provider<int>((ref) => 5);

class EmuleSearchState {
  const EmuleSearchState({
    this.running = false,
    this.done = false,
    this.keyword = '',
    this.results = const [],
    this.total = 0,
    this.searchId = 0,
    this.polls = 0,
    this.selected = const <String>{},
    this.errorText,
  });

  final bool running;
  final bool done;
  final String keyword;
  final List<DsEmuleSearchResult> results;
  final int total;

  /// **内部会话 id**（绝不上屏）。
  final int searchId;
  final int polls;

  /// 选中的 `file_id`（用于 `download`）。
  final Set<String> selected;
  final String? errorText;

  bool get hasMore => results.length < total;

  EmuleSearchState copyWith({
    bool? running,
    bool? done,
    String? keyword,
    List<DsEmuleSearchResult>? results,
    int? total,
    int? searchId,
    int? polls,
    Set<String>? selected,
    String? errorText,
    bool clearError = false,
  }) => EmuleSearchState(
    running: running ?? this.running,
    done: done ?? this.done,
    keyword: keyword ?? this.keyword,
    results: results ?? this.results,
    total: total ?? this.total,
    searchId: searchId ?? this.searchId,
    polls: polls ?? this.polls,
    selected: selected ?? this.selected,
    errorText: clearError ? null : (errorText ?? this.errorText),
  );
}

class EmuleSearchController extends Notifier<EmuleSearchState> {
  DownloadStationApi? get _api => ref.read(downloadApiProvider);

  @override
  EmuleSearchState build() => const EmuleSearchState();

  /// 开搜：`start` → 轮询 `list`（`search_done` 或到次数上限即停）。
  Future<void> search({
    required String keyword,
    String searchType = 'local',
    String fileType = 'any',
    int? fileSizeMin,
    int? fileSizeMax,
    int? sourceNumMin,
    String? fileExtension,
  }) async {
    final api = _api;
    if (api == null) return;
    final kw = keyword.trim();
    state = EmuleSearchState(
      running: true,
      keyword: kw,
      selected: const {},
    );
    final int id;
    try {
      id = await api.emuleSearchStart(
        keyword: kw,
        searchType: searchType,
        fileType: fileType,
        fileSizeMin: fileSizeMin,
        fileSizeMax: fileSizeMax,
        sourceNumMin: sourceNumMin,
        fileExtension: fileExtension,
      );
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.search,
        objectType: 'emule',
        reason: 'search_start_failed',
        error: e,
      );
      state = state.copyWith(
        running: false,
        done: true,
        errorText: describeDownloadError(e),
      );
      return;
    }
    if (id <= 0) {
      final err = DsmApiException(
        DsmErrorCode.apiNotFound,
        method: 'eMule.Search.start',
      );
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.search,
        objectType: 'emule',
        reason: 'search_session_failed',
        error: err,
      );
      state = state.copyWith(
        running: false,
        done: true,
        errorText: describeDownloadError(err),
      );
      return;
    }
    state = state.copyWith(searchId: id);
    await _poll(api, id);
  }

  Future<void> _poll(DownloadStationApi api, int id) async {
    final maxPolls = ref.read(emuleSearchMaxPollsProvider);
    final interval = ref.read(emuleSearchPollIntervalProvider);
    var polls = 0;
    while (polls < maxPolls) {
      polls++;
      DsEmuleSearchPage page;
      try {
        page = await api.emuleSearchList(
          id: id,
          offset: state.results.length,
          limit: DownloadStationApi.pageSize,
        );
      } catch (e) {
        trackOnceFailure(
          UsageModule.downloads,
          UsageAction.search,
          objectType: 'emule',
          reason: 'search_poll_failed',
          error: e,
        );
        state = state.copyWith(
          running: false,
          polls: polls,
          errorText: describeDownloadError(e),
        );
        return;
      }
      state = state.copyWith(
        polls: polls,
        results: _merge(state.results, page.results),
        total: page.total,
      );
      if (page.searchDone) break;
      if (polls >= maxPolls) break;
      await Future<void>.delayed(interval);
    }
    state = state.copyWith(running: false, done: true, clearError: true);
  }

  static List<DsEmuleSearchResult> _merge(
    List<DsEmuleSearchResult> old,
    List<DsEmuleSearchResult> fresh,
  ) {
    final seen = {for (final r in old) r.fileId};
    final out = [...old];
    for (final r in fresh) {
      if (r.fileId.isEmpty || seen.add(r.fileId)) out.add(r);
    }
    return out;
  }

  /// 勾选/取消一条结果（按 `file_id`）。
  void toggle(String fileId) {
    if (fileId.isEmpty) return;
    final next = {...state.selected};
    if (!next.remove(fileId)) next.add(fileId);
    state = state.copyWith(selected: next);
  }

  void clearSelection() => state = state.copyWith(selected: const {});

  /// 把选中的结果建成下载任务（官方 `actionDownload` 的行为）。
  ///
  /// 返回 true = 成功。空选直接 false（**不发请求**）。
  Future<bool> downloadSelected() async {
    final api = _api;
    if (api == null || state.selected.isEmpty) return false;
    try {
      await api.emuleSearchDownload(state.selected.toList());
      return true;
    } catch (e) {
      state = state.copyWith(errorText: describeDownloadError(e));
      return false;
    }
  }

  /// 停止（`id` = 当前会话；没有会话就 `0` = 停全部），并收尾状态。
  Future<void> stop() async {
    final api = _api;
    if (api == null) return;
    final id = state.searchId;
    state = state.copyWith(running: false, done: true);
    try {
      await api.emuleSearchStop(id: id);
    } catch (_) {
      // 停止失败不影响本地状态（官方也是 Debug 记录后放过）。
    }
  }
}

final emuleSearchProvider =
    NotifierProvider.autoDispose<EmuleSearchController, EmuleSearchState>(
      EmuleSearchController.new,
    );

/// 服务端 eMule 搜索是否可用（能力门控：`SYNO.API.Info` 里有这个 API）。
final emuleSearchAvailableProvider = Provider<bool>((ref) {
  final api = ref.watch(downloadApiProvider);
  return api != null && api.hasApi(DownloadStationApi.apiEmuleSearch);
}, retry: noRetry);
