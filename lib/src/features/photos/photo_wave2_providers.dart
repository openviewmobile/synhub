// 相册 wave2（搜索筛选 / 标签浏览 / 人物人脸）的 provider 层。
//
// 与既有相册模块同一套约定：
//   * API 从会话里取（未连接 → null），数据一律 `autoDispose` + **关掉自动重试**
//     （失败要显式给"重试"，绝不让"接口失败"伪装成"空结果"）；
//   * 写操作后只 invalidate，不做乐观更新（服务端是唯一事实来源）；
//   * 能力强弱由 `photo_c2_providers.dart` 的 `PhotoC2Availability` 统一门控。
//
// ★ 事实来源：`docs/photo-api-live.md` §5（官方 `SYNO.Foto.lib` 方法表）+
//   `docs/p2-photos-backup-research.md` §3.2/§4.2（官方 Web 前端的真实调用形态）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/foto_c2_dto.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/foto_api.dart';
import '../../data/foto_c2_api.dart';
import 'photo_c2_providers.dart';
import 'photo_providers.dart';

Duration? _noRetry(int retryCount, Object error) => null;

FotoApi _requireFoto(Ref ref) {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api;
}

FotoC2Api _requireC2(Ref ref) {
  final api = ref.read(fotoC2ApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api;
}

// ================================================================ 标签

/// 标签总数（`Browse.GeneralTag/count` v2）。
final photoTagCountProvider = FutureProvider.autoDispose<int>(
  (ref) async => _requireFoto(ref).generalTagCount(),
  retry: _noRetry,
);

/// 单个标签的详情 / 计数（`Browse.GeneralTag/get` v2 `{id:[数字]}`）。
///
/// 官方 Web 前端原文：`bS(n.get, {id:e})`（`ui/react_bundle.js` 的 `TX(e)`）。
/// 标签详情页用它拿"共 N 张照片"；读不到就回 null（界面回落成"当前已加载张数"）。
final photoTagDetailProvider = FutureProvider.autoDispose
    .family<FotoTagDto?, String>((ref, tagId) async {
      final list = await _requireFoto(ref).tagDetails([tagId]);
      return list.isEmpty ? null : list.first;
    }, retry: _noRetry);

/// 标签详情页的**分页状态**（`Browse.Item/list_with_filter` + 递增 `offset`）。
class PhotoTagItemsState {
  const PhotoTagItemsState({
    this.items = const [],
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<FotoItemDto> items;
  final bool hasMore;
  final bool loadingMore;
  final Object? loadMoreError;

  bool get isEmpty => items.isEmpty;
}

/// 某个标签名下的照片，游标 = 已加载条数（与 `PhotoTimelineNotifier` 同口径：
/// 加的是**服务端返回条数**、按 `item.id` 去重、失败只记 `loadMoreError`）。
class PhotoTagItemsNotifier extends AsyncNotifier<PhotoTagItemsState> {
  PhotoTagItemsNotifier(this.tagId);

  final String tagId;

  int _nextOffset = 0;

  @override
  Future<PhotoTagItemsState> build() async {
    final api = ref.watch(fotoSpaceApiProvider);
    if (api == null) throw StateError(currentText().setNotConnected);
    final page = await api.tagItems(
      tagId,
      offset: 0,
      limit: kFotoTagItemsPageSize,
    );
    _nextOffset = page.length;
    return PhotoTagItemsState(
      items: page,
      hasMore: page.length >= kFotoTagItemsPageSize,
    );
  }

  Future<void> loadMore() async {
    final cur = state.value;
    if (cur == null || cur.loadingMore || !cur.hasMore) return;
    state = AsyncData(
      PhotoTagItemsState(items: cur.items, hasMore: true, loadingMore: true),
    );
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) {
      state = AsyncData(
        PhotoTagItemsState(
          items: cur.items,
          hasMore: true,
          loadMoreError: StateError(currentText().setNotConnected),
        ),
      );
      return;
    }
    try {
      final page = await api.tagItems(
        tagId,
        offset: _nextOffset,
        limit: kFotoTagItemsPageSize,
      );
      final seen = {for (final e in cur.items) e.id};
      final added = [
        for (final e in page)
          if (seen.add(e.id)) e,
      ];
      _nextOffset += page.length;
      state = AsyncData(
        PhotoTagItemsState(
          items: [...cur.items, ...added],
          hasMore: page.length >= kFotoTagItemsPageSize && added.isNotEmpty,
        ),
      );
    } catch (err) {
      state = AsyncData(
        PhotoTagItemsState(items: cur.items, hasMore: true, loadMoreError: err),
      );
    }
  }
}

final photoTagItemsProvider = AsyncNotifierProvider.autoDispose
    .family<PhotoTagItemsNotifier, PhotoTagItemsState, String>(
      PhotoTagItemsNotifier.new,
      retry: _noRetry,
    );

// ================================================================ 人物 / 人脸

/// 人物名字建议（`Browse.Person/suggest` **v3** `{name_prefix, limit}`）。
///
/// 官方 `PERSON_SUGGESTION_LIMIT = 10`；空前缀**不发请求**（返回空）。
final photoPersonSuggestProvider = FutureProvider.autoDispose
    .family<List<FotoPersonDto>, String>((ref, prefix) async {
      final q = prefix.trim();
      if (q.isEmpty) return const [];
      return _requireFoto(ref).personSuggest(q);
    }, retry: _noRetry);

/// 某人物在一组照片上的**人脸检测条数**（`Browse.Person/list_face` **v1**）。
///
/// 官方形态 `bs(listFace, {person_id, item_id})`；这里只取**条数**做只读展示
/// ——人脸对象的字段（`face_id` / 裁切图 URL）**未取证**，所以不猜、不渲染
/// 内部 id（见报告「未取证清单」）。
///
/// family 的 key 只用标量：`itemIdsKey` = 逗号拼接的 item id（record 里带
/// `List` 会走同一性比较，导致每次 rebuild 都算新 provider）。
final photoPersonFacesProvider = FutureProvider.autoDispose
    .family<int, ({String personId, String itemIdsKey})>((ref, arg) async {
      final ids = [
        for (final part in arg.itemIdsKey.split(','))
          if (part.trim().isNotEmpty) part.trim(),
      ];
      if (ids.isEmpty) return 0;
      final faces = await _requireFoto(
        ref,
      ).personFaces(arg.personId, itemIds: ids);
      return faces.length;
    }, retry: _noRetry);

// ================================================================ 搜索（分页 + 筛选）

/// 搜索筛选面板的可用分组（`Search.Filter/list` v4）。
///
/// 回包是"组名 → 选项数组"的顶层 Map（证据见
/// `FotoSearchFilterGroupDto.parse` 的注释）。**认不出任何可显示项**时回空列表
/// ——界面据此显示"筛选项暂时不可用"，**不当成空结果**。
final photoSearchFiltersProvider =
    FutureProvider.autoDispose<List<FotoSearchFilterGroupDto>>((ref) async {
      final raw = await _requireC2(ref).searchFilters(const {});
      return FotoSearchFilterGroupDto.parse(raw);
    }, retry: _noRetry);

/// 搜索结果的**分页状态**（`Search.Search/list_item` **v7** + `offset`/`limit`）。
class PhotoSearchState {
  const PhotoSearchState({
    this.keyword = '',
    this.items = const [],
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final String keyword;
  final List<FotoItemDto> items;
  final bool hasMore;
  final bool loadingMore;
  final Object? loadMoreError;

  bool get isEmpty => items.isEmpty;
}

/// 搜索分页器：每次 `search()` 重置游标，`loadMore()` 用递增 `offset` 续取。
///
/// 分页口径与 `PhotoTimelineNotifier` 完全一致（游标 = 服务端返回条数、按
/// `item.id` 去重、不足一页或本页零新增就收尾）；失败时 `state` 变 `AsyncError`
/// ——**界面必须给失败提示**，绝不能显示成"没有匹配的照片"。
class PhotoSearchNotifier extends AsyncNotifier<PhotoSearchState> {
  String _keyword = '';
  Map<String, dynamic> _filter = const {};
  int _nextOffset = 0;

  @override
  Future<PhotoSearchState> build() async => const PhotoSearchState();

  Map<String, dynamic> get _requestFilter => {
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    ..._filter,
  };

  /// 发起一次新搜索（关键词 + 筛选面板选的组）。空条件 → 清空结果。
  Future<void> search({
    required String keyword,
    Map<String, dynamic> filter = const {},
  }) async {
    _keyword = keyword.trim();
    _filter = filter;
    _nextOffset = 0;
    if (_keyword.isEmpty && filter.isEmpty) {
      state = const AsyncData(PhotoSearchState());
      return;
    }
    final api = ref.read(fotoC2ApiProvider);
    if (api == null) {
      state = AsyncError(
        StateError(currentText().setNotConnected),
        StackTrace.current,
      );
      return;
    }
    state = const AsyncLoading();
    try {
      final page = await api.searchItems(
        _requestFilter,
        offset: 0,
        limit: kFotoSearchPageSize,
      );
      _nextOffset = page.length;
      state = AsyncData(
        PhotoSearchState(
          keyword: _keyword,
          items: page,
          hasMore: page.length >= kFotoSearchPageSize,
        ),
      );
    } catch (err, st) {
      state = AsyncError(err, st);
    }
  }

  /// 重试当前查询（页面层"失败 → 重试"用；保留关键词与筛选条件）。
  Future<void> retry() => search(keyword: _keyword, filter: _filter);

  Future<void> loadMore() async {
    final cur = state.value;
    if (cur == null || cur.loadingMore || !cur.hasMore) return;
    final api = ref.read(fotoC2ApiProvider);
    if (api == null) return;
    state = AsyncData(
      PhotoSearchState(
        keyword: cur.keyword,
        items: cur.items,
        hasMore: true,
        loadingMore: true,
      ),
    );
    try {
      final page = await api.searchItems(
        _requestFilter,
        offset: _nextOffset,
        limit: kFotoSearchPageSize,
      );
      final seen = {for (final e in cur.items) e.id};
      final added = [
        for (final e in page)
          if (seen.add(e.id)) e,
      ];
      _nextOffset += page.length;
      state = AsyncData(
        PhotoSearchState(
          keyword: cur.keyword,
          items: [...cur.items, ...added],
          hasMore: page.length >= kFotoSearchPageSize && added.isNotEmpty,
        ),
      );
    } catch (err) {
      state = AsyncData(
        PhotoSearchState(
          keyword: cur.keyword,
          items: cur.items,
          hasMore: true,
          loadMoreError: err,
        ),
      );
    }
  }
}

/// 搜索结果分页器。**故意不 autoDispose**：搜索页只在"有关键词 / 筛选"时才渲染
/// 结果区，之前没有任何 listener；autoDispose 会让 `ref.read(...notifier)` 建出来的
/// provider 在下一页帧前就被回收，导致 in-flight 的 `search()` 触碰已 dispose 的
/// `ref`（`UnmountedRefException`）并把结果丢掉。状态留在会话里也更符合搜索页
/// "返回再进来还能看到上次结果"的预期。
final photoSearchResultsProvider =
    AsyncNotifierProvider<PhotoSearchNotifier, PhotoSearchState>(
      PhotoSearchNotifier.new,
      retry: _noRetry,
    );
