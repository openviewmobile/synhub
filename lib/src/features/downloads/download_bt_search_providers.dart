// Download Station **BT 搜索**（wave4）的状态机与依赖注入。
//
// ⚠️ **wave4 重大更正**（`docs/download-api-live.md` §12）：BT 搜索在本机
// **完全可用** —— 老一代 `SYNO.DownloadStation.BTSearch`（
// `DownloadStation/btsearch.cgi`）真机普通用户实测：
//   * `getModule` v1（无参）→ 真实且 **enabled** 的模块列表；
//   * `start` v1 `{keyword}` → `{"data":{"taskid":"…"}}`（无参 → 400）；
//   * `list` v1 `{taskid,offset,limit}` → `{"finished":…,"items":[…],"total":130}`。
// 早先"`plugins:[]` → BT 不可用"的结论是**用错 path（entry.cgi）导致的误判**。
//
// 本文件的**取数优先级**：老代优先（本机唯一能出结果的），DS2 仅在
// 「老代能力位缺失而 DS2 能力位在」时作**降级/兼容**。
//
// 契约与做法：
//   * `list` 的 `finished` 是**轮询标志**（false=还在抓，继续轮询；true=抓完）
//     → 每 5 秒轮询一次、到 [DownloadStationApi.btSearchMaxPolls] 次必停、
//     离开页面立即打断（autoDispose 的 onDispose）；
//   * `size` 是**字符串字节数** → DTO 解析成 int 后由界面 `dsHumanBytes` 格式化；
//   * 模块多选（`getModule` 的 enabled 模块）在**客户端按 `module_id` 过滤**：
//     cgi 字符串表里虽有 `module` 参数，但**真机未取证其线参形态**，
//     按任务书"别猜"的要求**不下发**（登记进未取证清单）；
//   * **r388/DA35 起：搜索结果能直接变下载任务**。`download_uri`（老代）/
//     `dlurl`（DS2）**逐字**带进 [BtSearchEntry.downloadUri]，结果行给出
//     「下载」按钮 → `Task.create type=url url=[magnet]`（官方前端同一形态的
//     `download_now`）。★ 仍未做的是官方的 `download_to`（选目录那一步）——
//     改目录走既有的「新建任务」页，理由与未验项见
//     `docs/android-ui-audit-r388.md`。
//   * 老代结果**每条都有** `download_uri`；若服务端某条没给，该行的按钮**置灰**
//     （`hasDownloadLink == false`），**不许**拿 `title` 拼磁力链糊弄。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../../dsm/webapi.dart';
import 'download_providers.dart';

/// 轮询间隔。默认 = 官方 5 秒（[DownloadStationApi.btSearchPollInterval]）。
/// 测试 override 成 [Duration.zero]（离线用例不等真时钟）。
final btSearchPollIntervalProvider = Provider<Duration>(
  (ref) => DownloadStationApi.btSearchPollInterval,
);

/// 最大轮询次数。默认 = 官方 120（[DownloadStationApi.btSearchMaxPolls]）。
/// 测试 override 成小值验"到顶即停"。
final btSearchMaxPollsProvider = Provider<int>(
  (ref) => DownloadStationApi.btSearchMaxPolls,
);

/// 搜索界面阶段。
enum BtSearchPhase {
  /// 还没搜。
  idle,

  /// 已发 `start`、等会话 id。
  starting,

  /// 会话在跑（每 5 秒轮询；老代 `finished` 仍为 false）。
  running,

  /// 收尾完成（老代 = `finished:true`；可能有结果，也可能空）。
  done,

  /// **中性不可用**：不是"加载失败"，而是这台 NAS 没开/没源/没权限。
  unavailable,
}

/// 不可用的具体原因（决定空态文案；界面据此给"说明"而不是"错误"）。
enum BtSearchBlock {
  /// 未连接会话（`downloadApiProvider == null`）。
  apiMissing,

  /// 能力表里既没有老代 `DownloadStation.BTSearch`，也没有 DS2
  /// `DownloadStation2.BTSearch` → 这台 NAS 没装/没启用 Download Station。
  notInstalled,

  /// `105`/`160`/`524`：账号没有权限。
  noPrivilege,

  /// `1408 = SYNODL_ERR_BTSERACH_ID_NOT_FOUND`：BT 搜索不可用 / 会话无数据源。
  idNotFound,

  /// DS2 `list_plugin_status` 回 `plugins:[]` → 没有可用数据源。
  noPlugins,

  /// 老一代 `getModule` 取不到任何数据源（且用户没选源）。
  noSources,

  /// 网络失败。
  network,
}

/// **归一化**的一条搜索结果（老代 / DS2 两种来源共用同一展示模型）。
///
/// [moduleId] / [dedupeKey] 是**内部值**，只用于筛选与去重，界面绝不显示。
/// 显示名一律走 [moduleTitle]（老代 `module_title` / DS2 `provider`）。
class BtSearchEntry {
  const BtSearchEntry({
    required this.title,
    this.sizeBytes = 0,
    this.dateText = '',
    this.seeds,
    this.peers,
    this.moduleId = '',
    this.moduleTitle = '',
    this.dedupeKey = '',
    this.downloadUri = '',
  });

  final String title;

  /// 字节数（老代 `size` 字符串解析而来）→ 界面用 `dsHumanBytes` 格式化。
  final int sizeBytes;

  /// 展示用日期文本（老代逐字 `2012-04-20`；DS2 由 epoch 毫秒格式化）。
  final String dateText;

  /// `null` = 服务端未给出（未知），不是 0。
  final int? seeds;
  final int? peers;

  /// 内部 `module_id`（**只用于模块筛选**，绝不显示）。
  final String moduleId;

  /// 显示名（老代 `module_title`）。
  final String moduleTitle;

  /// 内部去重键。
  final String dedupeKey;

  /// 建任务用的**下载链接**（老代 `download_uri` / DS2 `dlurl`，通常是 `magnet:`）。
  ///
  /// **必须逐字**（`magnet:` 后面的大小写与 `&` 都是服务端给的），界面上屏前
  /// 一律先 [hasDownloadLink]。空 = 服务端没给 ⇒ 不给下载入口。
  final String downloadUri;

  /// 这一条**能不能**建任务（服务端给了 uri 才算）。
  bool get hasDownloadLink => downloadUri.trim().isNotEmpty;

  factory BtSearchEntry.fromLegacy(DsBtSearchLegacyResult r) => BtSearchEntry(
    title: r.title,
    sizeBytes: r.size,
    dateText: r.date,
    seeds: r.hasSeedInfo ? r.seeds : null,
    peers: r.hasPeerInfo ? r.peers : null,
    moduleId: r.moduleId,
    moduleTitle: r.moduleTitle,
    dedupeKey: r.id.isNotEmpty
        ? 'L${r.id}'
        : 'L${r.title}|${r.size}|${r.date}',
    downloadUri: r.downloadUri,
  );

  factory BtSearchEntry.fromDs2(DsBtSearchResult r) => BtSearchEntry(
    title: r.title,
    sizeBytes: r.size,
    dateText: _formatEpochDate(r.date),
    seeds: r.hasSeedInfo ? r.seeds : null,
    peers: r.hasPeerInfo ? r.peers : null,
    moduleTitle: r.provider,
    dedupeKey: r.resultId.isNotEmpty
        ? 'D${r.resultId}'
        : 'D${r.title}|${r.size}',
    downloadUri: r.dlurl,
  );
}

/// BT 搜索界面状态。
class BtSearchState {
  const BtSearchState({
    this.phase = BtSearchPhase.idle,
    this.keyword = '',
    this.searchTaskId = '',
    this.entries = const [],
    this.total = 0,
    this.limit = DownloadStationApi.btSearchPageSize,
    this.selectedModules = const <String>{},
    this.sources = const [],
    this.sourcesLoaded = false,
    this.legacy = false,
    this.finished = false,
    this.plugins,
    this.incomplete = false,
    this.polls = 0,
    this.loadingPage = false,
    this.loadingMore = false,
    this.block,
    this.errorText,
    this.categories = const [],
    this.selectedCategory,
    this.sortKey = '',
    this.sortDescending = true,
  });

  final BtSearchPhase phase;
  final String keyword;

  /// **内部会话 id —— 界面绝不显示**（任务书硬要求）。
  final String searchTaskId;

  /// 已抓到的**全部**结果（未经模块筛选）。
  final List<BtSearchEntry> entries;

  /// 服务端 `total`。
  final int total;

  final int limit;

  /// 用户选中的模块 `module_id`（空集 = 全部数据源）。
  final Set<String> selectedModules;

  /// 老一代 `getModule` 的 **enabled** 数据源（只放 enabled 的）。
  final List<DsBtSearchModule> sources;
  final bool sourcesLoaded;

  /// 本次搜索走的是老代（true）还是 DS2 降级（false）。
  final bool legacy;

  /// 老代 `finished` 轮询标志（true = 服务端抓完）。
  final bool finished;

  /// DS2 降级时的 `list_plugin_status`（**仅用于提示，不显示条目**）。
  final DsBtSearchPluginStatus? plugins;

  /// DS2 降级时 `can_connect` 不全 true → "结果可能不完整"提示。
  final bool incomplete;

  /// 已经轮询了多少次（测试可断言"结束条件"）。
  final int polls;

  final bool loadingPage;
  final bool loadingMore;

  /// 中性不可用原因（非 null 时 [phase] 一般是 [BtSearchPhase.unavailable]）。
  final BtSearchBlock? block;

  /// **真错误**文案（网络/未知）；中性不可用**不走**这里。
  final String? errorText;

  /// D2：服务端 `list_category` 回的分类（DS2 路径；真机可能回空数组）。
  final List<String> categories;

  /// D2：当前选中的分类（null = 全部）。切换会**带 `categories` 重新取列表**。
  final String? selectedCategory;

  /// D1：排序键（空 = 服务端默认序）。界面侧的本地排序，见 [sortedEntries]。
  final String sortKey;
  final bool sortDescending;

  /// 经模块多选筛选后、真正上屏的结果（**再按 D1 的排序键排**）。
  List<BtSearchEntry> get visibleEntries => sortedEntries;

  /// D1：排序后的结果。
  ///
  /// ⚠️ 排序做在**客户端**：官方是把 store 列名当 `sort_by` 发给服务端，但
  /// `sort_by` 的**合法取值域没有穷举证据**（§5 U7）⇒ 我们**不猜**服务端字段名，
  /// 只对已抓到的条目本地排序（标题 / 大小 / 做种数 / 日期）。
  List<BtSearchEntry> get sortedEntries {
    final base = <BtSearchEntry>[
      if (!legacy || selectedModules.isEmpty)
        ...entries
      else
        for (final e in entries)
          if (selectedModules.contains(e.moduleId)) e,
    ];
    if (sortKey.isEmpty) return base;
    final out = [...base];
    int cmp(BtSearchEntry a, BtSearchEntry b) => switch (sortKey) {
      'title' => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      'size' => a.sizeBytes.compareTo(b.sizeBytes),
      'seeds' => (a.seeds ?? -1).compareTo(b.seeds ?? -1),
      'date' => a.dateText.compareTo(b.dateText),
      _ => 0,
    };
    out.sort((a, b) => sortDescending ? cmp(b, a) : cmp(a, b));
    return out;
  }

  /// 已抓到的条数（用于分页 offset）。
  int get fetched => entries.length;

  bool get hasMore => fetched < total;

  /// 是否"搜完了但一条没有"（空态，不是错误）。
  bool get isEmptyResult =>
      phase == BtSearchPhase.done && visibleEntries.isEmpty;

  BtSearchState copyWith({
    BtSearchPhase? phase,
    String? keyword,
    String? searchTaskId,
    List<BtSearchEntry>? entries,
    int? total,
    int? limit,
    Set<String>? selectedModules,
    List<DsBtSearchModule>? sources,
    bool? sourcesLoaded,
    bool? legacy,
    bool? finished,
    DsBtSearchPluginStatus? plugins,
    bool? incomplete,
    int? polls,
    bool? loadingPage,
    bool? loadingMore,
    BtSearchBlock? block,
    String? errorText,
    List<String>? categories,
    String? selectedCategory,
    String? sortKey,
    bool? sortDescending,
    bool clearBlock = false,
    bool clearError = false,
    bool clearSelectedCategory = false,
  }) => BtSearchState(
    phase: phase ?? this.phase,
    keyword: keyword ?? this.keyword,
    searchTaskId: searchTaskId ?? this.searchTaskId,
    entries: entries ?? this.entries,
    total: total ?? this.total,
    limit: limit ?? this.limit,
    selectedModules: selectedModules ?? this.selectedModules,
    sources: sources ?? this.sources,
    sourcesLoaded: sourcesLoaded ?? this.sourcesLoaded,
    legacy: legacy ?? this.legacy,
    finished: finished ?? this.finished,
    plugins: plugins ?? this.plugins,
    incomplete: incomplete ?? this.incomplete,
    polls: polls ?? this.polls,
    loadingPage: loadingPage ?? this.loadingPage,
    loadingMore: loadingMore ?? this.loadingMore,
    block: clearBlock ? null : (block ?? this.block),
    errorText: clearError ? null : (errorText ?? this.errorText),
    categories: categories ?? this.categories,
    selectedCategory: clearSelectedCategory
        ? null
        : (selectedCategory ?? this.selectedCategory),
    sortKey: sortKey ?? this.sortKey,
    sortDescending: sortDescending ?? this.sortDescending,
  );
}

/// BT 搜索控制器（`autoDispose`：**离开页面立即打断轮询**，不泄漏）。
class BtSearchController extends Notifier<BtSearchState> {
  DownloadStationApi? _api;
  String? _taskId;
  Completer<void>? _cancel;
  bool _legacy = false;

  @override
  BtSearchState build() {
    // ⚠️ 页面销毁（autoDispose 无监听者）时**必须**打断轮询循环。
    // 老代方法表**没有 `stop`**（只有 start/list/getCategory/clean/getModule，
    // 且 `clean` 真机 401 未取证 → 不做），所以老代会话只停**客户端轮询**；
    // DS2 降级路径有 `stop`，照旧收尾（少了这段就是"轮询泄漏"）。
    ref.onDispose(() {
      final c = _cancel;
      if (c != null && !c.isCompleted) c.complete();
      final api = _api;
      final id = _taskId;
      _taskId = null;
      if (!_legacy && api != null && id != null) {
        // 收尾动作不 await（dispose 里也不允许）；失败吞掉。
        unawaited(api.btSearchStop(id));
      }
    });
    return const BtSearchState();
  }

  /// 老一代 `getModule` → **enabled** 数据源。失败/为空**不报错**（可选能力）。
  Future<void> loadSources() async {
    final api = ref.read(downloadApiProvider);
    if (api == null || !api.hasApi(DownloadStationApi.apiBtSearchLegacy)) {
      state = state.copyWith(sources: const [], sourcesLoaded: true);
      return;
    }
    try {
      final mods = await api.btSearchModules();
      // ★ r406（DA58）：服务端 `getModule` **真的会返回重复项** —— 真机实测
      // 13 条里 `id=EZTV` 出现 **两次**（同 id 同名），另有
      // `the_pirate_bay` / `ThePirateBay` **两个不同 id 同一个标题**。
      // 同 id 的两条在界面上是两个 chip，而勾选是 `Set<String>` 按 id 记的 ⇒
      // ①点一个两个都亮；②点第二个把筛选**抵消**掉（等于"全部数据源"）。
      // 这里按 **id** 去重（同 id = 同一个源，去重不丢信息）；
      // 同名不同 id 的**不许合并**（服务端确实有两个源，且我们没有可上屏的
      // 区分标签 —— 内部 id 绝不上屏）。
      // 证据：`docs/evidence-r406/nas/r406a_bt_modules.log`。
      final seen = <String>{};
      final sources = <DsBtSearchModule>[];
      for (final m in mods) {
        if (!m.enabled) continue;
        if (m.id.isNotEmpty && !seen.add(m.id)) continue;
        sources.add(m);
      }
      state = state.copyWith(sources: sources, sourcesLoaded: true);
    } catch (_) {
      state = state.copyWith(sources: const [], sourcesLoaded: true);
    }
  }

  /// 模块多选：切换一个 `module_id`（纯客户端筛选，不发网络请求）。
  void toggleModule(String moduleId) {
    if (moduleId.isEmpty) return;
    final next = {...state.selectedModules};
    if (!next.add(moduleId)) next.remove(moduleId);
    state = state.copyWith(selectedModules: next);
  }

  /// 清空模块选择（= 全部数据源）。
  void clearModules() {
    state = state.copyWith(selectedModules: const <String>{});
  }

  /// 开始搜索：**老代优先**（`start {keyword}` → 每 5 秒 `list {taskid,…}`
  /// 直到 `finished:true` 或到轮询上限）；老代能力位缺失时降级到 DS2。
  ///
  /// 返回的 Future 在**整个会话收尾后**完成（界面不 await；测试 await 它断言）。
  Future<void> search({required String keyword, String? sourceId}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;

    await _endSession();

    final api = ref.read(downloadApiProvider);
    if (api == null) {
      state = state.copyWith(
        phase: BtSearchPhase.unavailable,
        block: BtSearchBlock.apiMissing,
        clearError: true,
      );
      return;
    }
    final legacy = api.hasApi(DownloadStationApi.apiBtSearchLegacy);
    if (!legacy && !api.hasApi(DownloadStationApi.apiBtSearch)) {
      state = state.copyWith(
        phase: BtSearchPhase.unavailable,
        block: BtSearchBlock.notInstalled,
        clearError: true,
      );
      return;
    }
    _legacy = legacy;

    state = BtSearchState(
      phase: BtSearchPhase.starting,
      keyword: kw,
      limit: state.limit,
      selectedModules: state.selectedModules,
      sources: state.sources,
      sourcesLoaded: state.sourcesLoaded,
      legacy: legacy,
      // 重跑搜索时**保留筛选与排序偏好**（D1/D2）—— 否则切分类会把自己清掉
      selectedCategory: state.selectedCategory,
      categories: state.categories,
      sortKey: state.sortKey,
      sortDescending: state.sortDescending,
    );

    if (legacy) {
      await _searchLegacy(api, kw);
    } else {
      await _searchDs2(api, kw, sourceId);
    }
  }

  // ------------------------------------------------------------ 老代（主路径）

  Future<void> _searchLegacy(DownloadStationApi api, String kw) async {
    final String taskid;
    try {
      taskid = await api.btSearchLegacyStart(keyword: kw);
    } on DsmApiException catch (e) {
      final block = _blockOfCode(e.code);
      state = state.copyWith(
        phase: block == null ? BtSearchPhase.done : BtSearchPhase.unavailable,
        block: block,
        errorText: block == null ? describeDownloadError(e) : null,
        clearError: block != null,
      );
      return;
    } catch (e) {
      state = state.copyWith(
        phase: BtSearchPhase.done,
        errorText: describeDownloadError(e),
        clearBlock: true,
      );
      return;
    }

    if (taskid.isEmpty) {
      // `start` 成功却没回 taskid：按"会话建不起来"处理（中性，不伪造）。
      state = state.copyWith(
        phase: BtSearchPhase.unavailable,
        block: BtSearchBlock.idNotFound,
        clearError: true,
      );
      return;
    }

    _api = api;
    _taskId = taskid;
    final cancel = Completer<void>();
    _cancel = cancel;
    state = state.copyWith(
      phase: BtSearchPhase.running,
      searchTaskId: taskid,
      clearError: true,
      clearBlock: true,
    );
    await _legacyPollLoop(api, taskid, cancel);
  }

  /// 老代轮询：每 [btSearchPollIntervalProvider] 一次 `list {taskid,offset,limit}`，
  /// 合并（按 `id` 去重）直到 `finished:true` 或到 [btSearchMaxPollsProvider]。
  ///
  /// ⚠️ 轮询的 `offset` 固定为 0（"刷新 + 增量合并"语义）：服务端在
  /// `finished:false` 阶段会持续往里加结果，每次都从 0 拉既能拿到新条目、
  /// 又不会因结果集增长而**跳过**条目；`id` 去重保证不重复。
  /// 抓完（`finished:true`）后若 `fetched < total`，由 [loadMore] 分页补齐。
  Future<void> _legacyPollLoop(
    DownloadStationApi api,
    String taskid,
    Completer<void> cancel,
  ) async {
    final maxPolls = ref.read(btSearchMaxPollsProvider);
    final interval = ref.read(btSearchPollIntervalProvider);
    var polls = 0;
    var finished = false;

    while (polls < maxPolls && !cancel.isCompleted) {
      polls++;
      DsBtSearchLegacyPage page;
      try {
        page = await api.btSearchLegacyList(
          taskid: taskid,
          offset: 0,
          limit: state.limit,
        );
      } on DsmApiException catch (e) {
        if (cancel.isCompleted) return;
        final block = _blockOfCode(e.code);
        state = state.copyWith(
          phase: block == null ? BtSearchPhase.done : BtSearchPhase.unavailable,
          block: block,
          polls: polls,
          errorText: block == null ? describeDownloadError(e) : null,
          clearError: block != null,
        );
        return;
      } catch (e) {
        if (cancel.isCompleted) return;
        state = state.copyWith(
          phase: BtSearchPhase.done,
          polls: polls,
          errorText: describeDownloadError(e),
          clearBlock: true,
        );
        return;
      }
      if (cancel.isCompleted) return;

      state = state.copyWith(
        polls: polls,
        entries: _mergeEntries(state.entries, [
          for (final r in page.items) BtSearchEntry.fromLegacy(r),
        ]),
        total: page.total,
        finished: page.finished,
      );

      if (page.finished) {
        finished = true;
        break;
      }
      await Future.any([
        Future<void>.delayed(interval),
        cancel.future,
      ]);
    }

    if (cancel.isCompleted) return;
    // 抓完 / 到顶都收尾成 done（到顶不是错误：有结果就展示，仍可 loadMore）。
    state = state.copyWith(
      phase: BtSearchPhase.done,
      finished: finished || state.finished,
      clearBlock: true,
      clearError: true,
    );
  }

  // ------------------------------------------------------- DS2（降级/兼容）

  Future<void> _searchDs2(
    DownloadStationApi api,
    String kw,
    String? sourceId,
  ) async {
    final String taskId;
    try {
      taskId = await api.btSearchStart(keyword: kw, sourceId: sourceId);
    } on DsmApiException catch (e) {
      final block = _blockOfCode(e.code);
      state = state.copyWith(
        phase: block == null ? BtSearchPhase.done : BtSearchPhase.unavailable,
        block: block,
        errorText: block == null ? describeDownloadError(e) : null,
        clearError: block != null,
      );
      return;
    } catch (e) {
      state = state.copyWith(
        phase: BtSearchPhase.done,
        errorText: describeDownloadError(e),
        clearBlock: true,
      );
      return;
    }

    if (taskId.isEmpty) {
      state = state.copyWith(
        phase: BtSearchPhase.unavailable,
        block: BtSearchBlock.idNotFound,
        clearError: true,
      );
      return;
    }

    _api = api;
    _taskId = taskId;
    final cancel = Completer<void>();
    _cancel = cancel;
    state = state.copyWith(
      phase: BtSearchPhase.running,
      searchTaskId: taskId,
      clearError: true,
      clearBlock: true,
    );
    await _ds2PollLoop(api, taskId, cancel);
  }

  Future<void> _ds2PollLoop(
    DownloadStationApi api,
    String taskId,
    Completer<void> cancel,
  ) async {
    final maxPolls = ref.read(btSearchMaxPollsProvider);
    final interval = ref.read(btSearchPollIntervalProvider);
    var polls = 0;
    while (polls < maxPolls && !cancel.isCompleted) {
      polls++;
      final res = await api.btSearchPoll(
        searchTaskId: taskId,
        start: state.fetched,
        limit: state.limit,
        // D2：分类筛选要**跟着每一次 list 走**（官方 beforeSearchPolling 同款）
        category: state.selectedCategory,
      );
      if (cancel.isCompleted) return;
      if (res.errorCode != null) {
        final block = _blockOfCode(res.errorCode!);
        state = state.copyWith(
          phase: block == null ? BtSearchPhase.done : BtSearchPhase.unavailable,
          block: block,
          polls: polls,
          errorText: block == null
              ? describeDownloadError(DsmApiException(res.errorCode!))
              : null,
          clearError: block != null,
        );
        await _stopOnServer(api, taskId);
        return;
      }
      state = state.copyWith(
        polls: polls,
        entries: _mergeEntries(state.entries, [
          for (final r in res.page.results) BtSearchEntry.fromDs2(r),
        ]),
        total: res.page.total,
        // D2：服务端 `list_category` 的分类（空数组=不覆盖已有值）
        categories: res.categories.isEmpty ? null : res.categories,
      );
      // 结束条件（官方逐字）：`is_running === false`，或轮询次数到顶。
      if (!res.page.isRunning || res.page.searchDone) break;
      if (polls >= maxPolls) break;
      await Future.any([
        Future<void>.delayed(interval),
        cancel.future,
      ]);
    }

    final cancelled = cancel.isCompleted;
    await _stopOnServer(api, taskId);
    if (cancelled) return;

    // 官方 `stopSearch(false)` → `checkPluginStatus()`：停后看插件连通性。
    try {
      final pluginStatus = await api.btSearchPluginStatus(taskId);
      state = state.copyWith(
        plugins: pluginStatus,
        incomplete: !pluginStatus.allConnected,
      );
    } catch (_) {
      // 插件状态是**附加提示**，取不到就不提示（不影响结果）。
    }

    if (state.entries.isEmpty && (state.plugins?.plugins.isEmpty ?? false)) {
      state = state.copyWith(
        phase: BtSearchPhase.unavailable,
        block: BtSearchBlock.noPlugins,
      );
      return;
    }
    state = state.copyWith(
      phase: BtSearchPhase.done,
      finished: true,
      clearBlock: true,
    );
  }

  // ------------------------------------------------------------ 会话收尾

  /// 停当前会话（幂等）。老代**没有 `stop`/可用的 `clean`** → 只打断轮询；
  /// DS2 路径照旧调 `stop`。
  Future<void> _endSession() async {
    final c = _cancel;
    if (c != null && !c.isCompleted) c.complete();
    final api = _api ?? ref.read(downloadApiProvider);
    final id = _taskId;
    _cancel = null;
    _taskId = null;
    if (!_legacy && api != null && id != null) {
      await api.btSearchStop(id);
    }
  }

  Future<void> _stopOnServer(DownloadStationApi api, String taskId) async {
    if (_taskId == null) return;
    _taskId = null;
    await api.btSearchStop(taskId);
  }

  /// 用户主动取消（返回键）—— 打断轮询并把阶段回到 idle。
  Future<void> cancelSearch() async {
    await _endSession();
    state = state.copyWith(
      phase: BtSearchPhase.idle,
      searchTaskId: '',
      clearBlock: true,
      clearError: true,
    );
  }

  /// D2：切换分类（null = 全部）。**带着 `categories` 重新取列表**（官方
  /// `beforeSearchPolling` 就是把它放进同一次 `list` 请求）。
  Future<void> selectCategory(String? name) async {
    if (state.selectedCategory == name) return;
    state = state.copyWith(
      selectedCategory: name,
      clearSelectedCategory: name == null,
    );
    // 会话还活着 → 直接按新分类重取；**会话已停（DS2 抓完即 stop）→ 重跑一次
    // 搜索**（否则会在已结束的会话上取列表，静默失败）。
    final alive = _taskId != null && (_cancel?.isCompleted == false);
    if (alive) {
      await _refetchWithFilters();
    } else if (state.keyword.trim().isNotEmpty) {
      await search(keyword: state.keyword);
    }
  }

  /// D1：选择排序键（`''` = 默认序；`title`/`size`/`seeds`/`date`）。
  void setSort(String key, {bool? descending}) {
    state = state.copyWith(
      sortKey: key,
      sortDescending: descending ?? state.sortDescending,
    );
  }

  void toggleSortDirection() =>
      state = state.copyWith(sortDescending: !state.sortDescending);

  /// 用当前分类重取第一页（DS2 路径才有 `categories` 参数）。
  Future<void> _refetchWithFilters() async {
    final api = _api;
    // ⚠️ 轮询结束后 `_taskId` 已被清掉，但**服务端会话还在**
    // （`state.searchTaskId` 一直留着）⇒ 用状态里的 id，否则"切分类"会静默失效。
    final id = _taskId ?? (state.searchTaskId.isEmpty ? null : state.searchTaskId);
    if (api == null || id == null || _legacy) return;
    try {
      final page = await api.btSearchList(
        searchTaskId: id,
        start: 0,
        limit: state.limit,
        category: state.selectedCategory,
      );
      state = state.copyWith(
        entries: [
          for (final r in page.results) BtSearchEntry.fromDs2(r),
        ],
        total: page.total,
      );
    } catch (e) {
      state = state.copyWith(errorText: describeDownloadError(e));
    }
  }

  /// 分页补齐：老代用 `offset`（= 已抓条数），DS2 降级用 `start`。
  Future<void> loadMore() async {
    final api = _api;
    final id = _taskId;
    if (api == null || id == null) return;
    if (state.loadingMore || state.loadingPage || !state.hasMore) return;
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      if (_legacy) {
        final page = await api.btSearchLegacyList(
          taskid: id,
          offset: state.fetched,
          limit: state.limit,
        );
        state = state.copyWith(
          loadingMore: false,
          entries: _mergeEntries(state.entries, [
            for (final r in page.items) BtSearchEntry.fromLegacy(r),
          ]),
          total: page.total,
        );
      } else {
        final page = await api.btSearchList(
          searchTaskId: id,
          start: state.fetched,
          limit: state.limit,
          category: state.selectedCategory,
        );
        state = state.copyWith(
          loadingMore: false,
          entries: _mergeEntries(state.entries, [
            for (final r in page.results) BtSearchEntry.fromDs2(r),
          ]),
          total: page.total,
        );
      }
    } catch (e) {
      state = state.copyWith(
        loadingMore: false,
        errorText: describeDownloadError(e),
      );
    }
  }
}

final btSearchProvider =
    NotifierProvider.autoDispose<BtSearchController, BtSearchState>(
      BtSearchController.new,
    );

BtSearchBlock? _blockOfCode(int code) {
  switch (code) {
    case DownloadStationApi.errBtSearchIdNotFound: // 1408
      return BtSearchBlock.idNotFound;
    case DsmErrorCode.noPermission: // 105
    case DsmErrorCode.noAppPrivilege: // 160
    case 524: // SYNODL_ERR_NO_PRIVILEGE
      return BtSearchBlock.noPrivilege;
    case DsmErrorCode.apiNotFound: // 102
    case DsmErrorCode.methodNotFound: // 103
    case DsmErrorCode.notSupportedVersion: // 104
    case DsmErrorCode.noMatchLibEntry: // 121
      return BtSearchBlock.notInstalled;
    case 519: // SYNODL_ERR_NETWORK
      return BtSearchBlock.network;
    default:
      return null;
  }
}

/// 结果合并：按 [BtSearchEntry.dedupeKey] 去重（老代轮询会重复回同一页）。
List<BtSearchEntry> _mergeEntries(
  List<BtSearchEntry> existing,
  List<BtSearchEntry> incoming,
) {
  if (incoming.isEmpty) return existing;
  if (existing.isEmpty) return incoming;
  final seen = {for (final r in existing) r.dedupeKey};
  return [
    ...existing,
    for (final r in incoming)
      if (seen.add(r.dedupeKey)) r,
  ];
}

/// epoch 毫秒 → `yyyy-MM-dd`（DS2 降级路径的 `date` 是毫秒；老代是字符串）。
String _formatEpochDate(int millis) {
  if (millis <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
