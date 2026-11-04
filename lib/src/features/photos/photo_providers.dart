// 相册模块的 provider 层（P2 · Synology Photos）。
//
// 与文件/笔记模块同一套约定：API 层从会话里取（未连接 → null），
// 数据用 `autoDispose` FutureProvider，**关掉自动重试**（见 [_noRetry]）。
//
// 缩略图/原图都是「带 `_sid` 的 URL」，直接交给 `Image.network` 走
// Flutter 自带的 ImageCache（默认上限 1000 张 / 100MB）—— 不自己写缓存。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/net/network_type.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/foto_api.dart';
import '../files/file_providers.dart' show fileDownloadDirectory;
import '../notifications/notification_service.dart'
    show networkTypeProbeProvider;
import '../servers/session_controller.dart';
import 'photo_playback_settings.dart';

/// Riverpod 3 默认对失败的 provider 做指数退避重试 → UI 停在 loading。相册一律关掉。
Duration? _noRetry(int retryCount, Object error) => null;

/// 相册 API（个人空间）。未连接时为 null。
final fotoApiProvider = Provider<FotoApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : FotoApi(conn.api);
});

/// 当前空间（个人 / 共享）
final fotoSpaceProvider = NotifierProvider<FotoSpaceNotifier, FotoSpace>(
  FotoSpaceNotifier.new,
);

class FotoSpaceNotifier extends Notifier<FotoSpace> {
  @override
  FotoSpace build() => FotoSpace.personal;

  void set(FotoSpace space) => state = space;
}

/// 当前空间的 API
///
/// P48：这里挂上**播放设置**（HTTP / 端口覆盖）—— `Download/download` 与
/// `Streaming/streaming` 两条直链会按用户设置改写成 `http://host:port/…`；
/// 缩略图不动（缩略图走应用自己的 HTTP 客户端，本来就信任自签证书）。
final fotoSpaceApiProvider = Provider<FotoApi?>((ref) {
  final api = ref.watch(fotoApiProvider);
  if (api == null) return null;
  final override = ref.watch(photoPlaybackSettingsProvider).mediaOverride;
  return api
      .inSpace(ref.watch(fotoSpaceProvider))
      .withMediaUrlOverride(override);
});

/// `Setting.User/get` —— 决定共享空间要不要出现在界面上。
///
/// 真机：普通用户的 `team_space_permission` 就是 `none`（共享空间不可见）。
final fotoSettingProvider = FutureProvider.autoDispose<FotoSettingDto>((
  ref,
) async {
  final api = ref.watch(fotoApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.setting();
}, retry: _noRetry);

/// 缩略图/原图的请求键。
///
/// ⚠️ **不能用 `Image.network`**：相册 URL 指向 NAS 的自签证书 + `_sid`，
/// `Image.network` 自带的那套 `HttpClient` 既不认自签证书也不带我们的
/// Dio 配置 —— 真机上表现是"格子完全不画"（像素留在上一帧，看着像残影），
/// 因为请求一直挂在那里，`loadingBuilder` 连第一帧都没给。
/// 一律走 `api.getBytes`（Dio + `allowSelfSigned` + 鉴权），和文件模块一致。
class PhotoThumbRequest {
  const PhotoThumbRequest({
    required this.itemId,
    required this.cacheKey,
    required this.space,
    this.size = 'sm',
    this.thumbType = 'item',
  });

  final String itemId;
  final String cacheKey;
  final FotoSpace space;

  /// `sm` / `m` / `xl`（`SYNO.Foto.Thumbnail/get` 的 `size`）
  final String size;

  /// `SYNO.Foto.Thumbnail/get` 的 `type`（官方枚举
  /// `album/folder/general_tag/geocoding/item/person/unit/concept/face`）。
  /// 照片/视频用 `item`（默认）；人物/场景封面用 `person`/`concept`，
  /// 缩略对象带 `unit_id` 时用 `unit` —— 见 `photoSmartAlbumCoverRequest`。
  final String thumbType;

  /// 解码宽度上限（防止几十张原图一起解码把内存吃爆）
  int get decodeWidth => switch (size) {
    'xl' => 1600,
    'm' => 512,
    _ => 240,
  };

  @override
  bool operator ==(Object other) =>
      other is PhotoThumbRequest &&
      other.itemId == itemId &&
      other.cacheKey == cacheKey &&
      other.space == space &&
      other.size == size &&
      other.thumbType == thumbType;

  @override
  int get hashCode => Object.hash(itemId, cacheKey, space, size, thumbType);
}

/// 一个相册缩略图（字节，已鉴权）。
///
/// 失败会抛 → UI 退回占位图标（不白屏、不卡在转圈）。
final photoThumbProvider = FutureProvider.autoDispose
    .family<Uint8List, PhotoThumbRequest>((ref, req) async {
      // `FotoApi` 自己就握着 `DsmWebApi`（含鉴权 + 自签证书的 Dio），
      // 不用再去会话里捞一遍 api
      final api = ref.watch(fotoApiProvider)?.inSpace(req.space);
      if (api == null) throw StateError(currentText().setNotConnected);
      final bytes = await api.api.getBytes(
        api.thumbnailUrl(
          itemId: req.itemId,
          cacheKey: req.cacheKey,
          size: req.size,
          type: req.thumbType,
        ),
      );
      return Uint8List.fromList(bytes);
    }, retry: _noRetry);

/// 时间轴的**分页状态**。
///
/// 以前这里是 `FutureProvider<List<FotoItemDto>>` + 单次 `limit:200`：服务端
/// 只回前 200 张，界面也永远只有这 200 张（P0：超过 200 张就"加载不出来"）。
/// 现在换成"已加载 items + 游标是否到底"的状态机，触底时用 `offset` 续取，
/// 见 [PhotoTimelineNotifier.loadMore]。
class PhotoTimelineState {
  const PhotoTimelineState({
    this.items = const [],
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreError,
  });

  /// 已按服务端顺序合并、去重后的全部照片
  final List<FotoItemDto> items;

  /// 还有下一页（上一页正好取满一页 = 可能还有）
  final bool hasMore;

  /// 正在取下一页（底部显示转圈，不阻塞已加载内容）
  final bool loadingMore;

  /// 取下一页失败的原因（非空时底部显示"重试"，**不丢弃已加载的**）
  final Object? loadMoreError;

  bool get isEmpty => items.isEmpty;
}

/// 时间轴分页器（`Browse.Item/list` + 递增 `offset`）。
///
/// 游标、去重、收尾三段：
///   * **游标** = `_nextOffset`（已加载条数），每成功取一页就加"服务端返回的
///     条数"（不是"新增去重后的条数"，否则服务端给重复页时会卡住）；
///   * **去重** = 按 `item.id` 的 `Set`，重复条目直接丢弃；
///   * **收尾** = 返回不足一页（`< limit`）**或**本页零新增 → `hasMore=false`；
///     空页也停。取数失败只写 `loadMoreError`，已加载内容照常显示。
///
/// ⚠️ 这里刻意**不用** `Browse.Diff`：真机实探（`docs/photo-api-live.md` §4）
/// 确认它是"自上次同步以来的变更"的双参数同步接口（`diff_version` +
/// `version_time`），不是翻页游标；时间线翻页就是 `Browse.Item/list` 的
/// `offset`/`limit`（实调 OK）。Diff 本批不做（成功回包未取证）。
class PhotoTimelineNotifier extends AsyncNotifier<PhotoTimelineState> {
  int _nextOffset = 0;

  ({String sortBy, String sortDirection}) _sort() {
    final setting = ref.read(fotoSettingProvider).value;
    return (
      sortBy: setting?.itemSortBy ?? 'takentime',
      sortDirection: setting?.sortDirection ?? 'desc',
    );
  }

  @override
  Future<PhotoTimelineState> build() async {
    final api = ref.watch(fotoSpaceApiProvider);
    if (api == null) throw StateError(currentText().setNotConnected);
    final setting = ref.watch(fotoSettingProvider).value;
    final sortBy = setting?.itemSortBy ?? 'takentime';
    final sortDirection = setting?.sortDirection ?? 'desc';
    final page = await api.timeline(
      offset: 0,
      limit: kFotoTimelinePageSize,
      sortBy: sortBy,
      sortDirection: sortDirection,
    );
    _nextOffset = page.length;
    return PhotoTimelineState(
      items: page,
      hasMore: page.length >= kFotoTimelinePageSize,
    );
  }

  /// 触底续取下一页（幂等：正在取 / 已到底 / 还没首屏时直接返回）
  Future<void> loadMore() async {
    final cur = state.value;
    if (cur == null || cur.loadingMore || !cur.hasMore) return;
    state = AsyncData(
      PhotoTimelineState(items: cur.items, hasMore: true, loadingMore: true),
    );
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) {
      state = AsyncData(
        PhotoTimelineState(
          items: cur.items,
          hasMore: true,
          loadMoreError: StateError(currentText().setNotConnected),
        ),
      );
      return;
    }
    final s = _sort();
    try {
      final page = await api.timeline(
        offset: _nextOffset,
        limit: kFotoTimelinePageSize,
        sortBy: s.sortBy,
        sortDirection: s.sortDirection,
      );
      final seen = {for (final e in cur.items) e.id};
      final added = [
        for (final e in page)
          if (seen.add(e.id)) e,
      ];
      _nextOffset += page.length;
      state = AsyncData(
        PhotoTimelineState(
          items: [...cur.items, ...added],
          hasMore: page.length >= kFotoTimelinePageSize && added.isNotEmpty,
        ),
      );
    } catch (err) {
      // 只记这一页的错，已加载的照片**一条都不丢**
      state = AsyncData(
        PhotoTimelineState(items: cur.items, hasMore: true, loadMoreError: err),
      );
    }
  }
}

/// 时间轴（当前空间，分页）。
final photoTimelineProvider =
    AsyncNotifierProvider.autoDispose<
      PhotoTimelineNotifier,
      PhotoTimelineState
    >(PhotoTimelineNotifier.new, retry: _noRetry);

/// 相册段当前选择的排序。
///
/// `userSelected=false` 表示"还没手动选过" → 用服务端 `get_album_list_order`
/// 的值；一旦用户点过排序菜单，就是本地权威值（并会写回服务端）。
class PhotoAlbumSort {
  const PhotoAlbumSort({
    required this.sortBy,
    required this.sortDirection,
    this.userSelected = false,
  });

  final String sortBy;
  final String sortDirection;
  final bool userSelected;

  static const defaults = PhotoAlbumSort(
    sortBy: 'create_time',
    sortDirection: 'desc',
  );

  @override
  bool operator ==(Object other) =>
      other is PhotoAlbumSort &&
      other.sortBy == sortBy &&
      other.sortDirection == sortDirection &&
      other.userSelected == userSelected;

  @override
  int get hashCode => Object.hash(sortBy, sortDirection, userSelected);
}

/// 相册排序状态（内存态；持久化由服务端 `set_album_list_order` 负责）。
final photoAlbumSortProvider =
    NotifierProvider<PhotoAlbumSortNotifier, PhotoAlbumSort>(
      PhotoAlbumSortNotifier.new,
    );

class PhotoAlbumSortNotifier extends Notifier<PhotoAlbumSort> {
  @override
  PhotoAlbumSort build() => PhotoAlbumSort.defaults;

  void set(PhotoAlbumSort sort) => state = PhotoAlbumSort(
    sortBy: sort.sortBy,
    sortDirection: sort.sortDirection,
    userSelected: true,
  );

  /// 用服务端默认排序**填充**本地态（用户没手动选过才生效）。
  ///
  /// 界面上的排序胶囊必须显示"服务端当前默认"，否则会出现"列表按 album_name
  /// 排、胶囊却写创建时间、点方向写回 create_time"的自相矛盾。
  void seed(PhotoAlbumSort sort) {
    if (state.userSelected) return;
    state = PhotoAlbumSort(
      sortBy: sort.sortBy,
      sortDirection: sort.sortDirection,
    );
  }
}

/// 服务端保存的相册列表默认排序（`Browse.Album/get_album_list_order`）。
///
/// **非 autoDispose**：`photoAlbumsProvider` 会反复重建（列表刷新、写回后
/// invalidate），如果这里也跟着 autoDispose/重启，重建瞬间会拿到 `loading`
/// （`.value == null`）而用本地默认值发一次多余的 `Album/list`，把服务端默认
/// 排序"顶掉"一次。读一次就够，留着。
final photoAlbumListOrderProvider = FutureProvider<FotoAlbumListOrder>((
  ref,
) async {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.getAlbumListOrder();
}, retry: _noRetry);

/// 相册列表（普通相册 + 条件相册），按相册段排序设置排列。
///
/// 排序值：用户手动选过 → 本地值；否则用服务端默认（读失败就退回本地默认）。
/// `Browse.Album/list` 接受 `sort_by`/`sort_direction`（官方 Android v2+ 证据）。
/// 先取 `Album/list`（已排序），再把 `NormalAlbum/list` 里没出现过的补上 ——
/// 顺序以服务端排序结果为准，不再被"普通相册在前"打乱。
final photoAlbumsProvider = FutureProvider.autoDispose<List<FotoAlbumDto>>((
  ref,
) async {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  final local = ref.watch(photoAlbumSortProvider);
  // 等**服务端默认排序**就绪再发 `Album/list`：如果只用 `.value`，首帧必然
  // 是 loading（null）→ 先用本地默认发一次多余请求，把服务端默认"顶掉"。
  FotoAlbumListOrder? remote;
  try {
    remote = await ref.watch(photoAlbumListOrderProvider.future);
  } catch (_) {
    remote = null; // 读不到就退回本地默认，不阻塞相册列表
  }
  final sort = local.userSelected || remote == null
      ? local
      : PhotoAlbumSort(
          sortBy: remote.sortBy.isEmpty ? 'create_time' : remote.sortBy,
          sortDirection: remote.sortDirection.isEmpty
              ? 'desc'
              : remote.sortDirection,
        );
  // ★ 两路请求的失败**不能都吞掉**（第 260 轮修）。
  //   原来两处都 `.catchError((_) => [])` ⇒ 两条都失败时本 provider 回**空列表**，
  //   相册页渲染的是"还没有相册"，而 `onRetry` 只在 **error 态**才出现
  //   （`photo_browse_page.dart`）⇒ 用户看到"相册是空的"且**永远没有重试入口**。
  //   语义：只失败一路仍旧故意降级（条件相册是补充），**两路都失败必须抛**。
  Object? allError;
  StackTrace? allTrace;
  List<FotoAlbumDto> all;
  try {
    all = await api.albums(
      sortBy: sort.sortBy,
      sortDirection: sort.sortDirection,
    );
  } on Object catch (e, st) {
    allError = e;
    allTrace = st;
    all = const [];
  }
  var normalFailed = false;
  List<FotoAlbumDto> normal;
  try {
    normal = await api.normalAlbums();
  } on Object {
    normalFailed = true;
    normal = const [];
  }
  if (allError != null && normalFailed) {
    Error.throwWithStackTrace(allError, allTrace ?? StackTrace.current);
  }
  final seen = <String>{};
  final out = <FotoAlbumDto>[];
  for (final a in [...all, ...normal]) {
    if (seen.add(a.id)) out.add(a);
  }
  return out;
});

/// **只有用户手建的普通相册**（新建相册/加入相册的候选）。
///
/// 为什么单独开一个：条件相册（`type != normal`）不能往里加照片，服务端会
/// 回错；界面上的"加入相册"只该列普通相册。
final photoNormalAlbumsProvider =
    FutureProvider.autoDispose<List<FotoAlbumDto>>((ref) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.normalAlbums();
    }, retry: _noRetry);

/// 相册的写操作（新建 / 改名 / 删除 / 加照片 / 移出 / 换封面）。
///
/// 与收藏同一个口径：**服务端是唯一事实来源** —— 写完就 invalidate 相关
/// provider，不做本地乐观更新（相册的封面/计数要服务端算）。
class PhotoAlbumActions {
  PhotoAlbumActions(this.ref);

  final Ref ref;

  FotoApi get _api {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) throw StateError(currentText().setNotConnected);
    return api;
  }

  void _refresh() {
    ref.invalidate(photoAlbumsProvider);
    ref.invalidate(photoNormalAlbumsProvider);
    ref.invalidate(photoTimelineProvider);
    ref.invalidate(photoFavoritesProvider);
  }

  Future<FotoAlbumDto> create(
    String name, {
    List<String> itemIds = const [],
  }) async {
    final album = await _api.createAlbum(name: name, itemIds: itemIds);
    _refresh();
    return album;
  }

  Future<void> rename(String albumId, String name) async {
    await _api.renameAlbum(albumId: albumId, name: name);
    _refresh();
    ref.invalidate(photoAlbumItemsProvider);
  }

  Future<void> remove(List<String> albumIds) async {
    await _api.deleteAlbums(albumIds);
    _refresh();
  }

  /// 返回"没加进去的"照片 id（服务端 `error_list`），空表示全成功
  Future<List<String>> addItems(String albumId, List<String> itemIds) async {
    final failed = await _api.addItemsToAlbum(
      albumId: albumId,
      itemIds: itemIds,
    );
    _refresh();
    ref.invalidate(photoAlbumItemsProvider);
    return failed;
  }

  Future<void> removeItems(String albumId, List<String> itemIds) async {
    await _api.removeItemsFromAlbum(albumId: albumId, itemIds: itemIds);
    _refresh();
    ref.invalidate(photoAlbumItemsProvider);
  }

  Future<void> setCover(String albumId, String itemId) async {
    await _api.setAlbumCover(albumId: albumId, itemId: itemId);
    _refresh();
    ref.invalidate(photoAlbumItemsProvider);
  }
}

final photoAlbumActionsProvider = Provider<PhotoAlbumActions>(
  PhotoAlbumActions.new,
);

/// 文件夹的写操作（新建 / 改名 / 删除）。
///
/// 与相册写同一个口径：**服务端是唯一事实来源**，写完只 invalidate，不做乐观更新
/// （文件夹的封面、计数、层级都要服务端算）。
///
/// ⚠️ `photoSubFoldersProvider` 是 family：这里 invalidate 的是**整个 family**
/// （Riverpod 3 里 `ref.invalidate(family)` 才会连所有实参一起失效）。
class PhotoFolderActions {
  PhotoFolderActions(this.ref);

  final Ref ref;

  FotoApi get _api {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) throw StateError(currentText().setNotConnected);
    return api;
  }

  void _refresh() {
    ref.invalidate(photoFoldersProvider);
    ref.invalidate(photoSubFoldersProvider);
    ref.invalidate(photoFolderItemsProvider);
  }

  Future<FotoFolderDto> create({
    required String parentId,
    required String name,
  }) async {
    final folder = await _api.createFolder(parentId: parentId, name: name);
    _refresh();
    return folder;
  }

  Future<void> rename(String folderId, String name) async {
    await _api.renameFolder(folderId: folderId, name: name);
    _refresh();
  }

  Future<void> remove(List<String> folderIds) async {
    await _api.deleteFolders(folderIds);
    _refresh();
  }
}

final photoFolderActionsProvider = Provider<PhotoFolderActions>(
  PhotoFolderActions.new,
);

/// 文件夹（根层）
final photoFoldersProvider = FutureProvider.autoDispose<List<FotoFolderDto>>((
  ref,
) async {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.folders();
}, retry: _noRetry);

/// 收藏
final photoFavoritesProvider = FutureProvider.autoDispose<List<FotoItemDto>>((
  ref,
) async {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.favorites();
}, retry: _noRetry);

/// 最近添加（`Browse.RecentlyAdded/list`；本机 v1–6 同形，协商最大版本）。
///
/// 只读浏览：分页页大小取 [kFotoRecentlyAddedPageSize]（默认 100）。
/// 与同族 provider 一样**关掉自动重试**，失败立刻可见、由用户点重试。
final photoRecentlyAddedProvider =
    FutureProvider.autoDispose<List<FotoItemDto>>((ref) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.recentlyAdded();
    }, retry: _noRetry);

/// 某个相册 / 文件夹的内容（详情页用）
final photoAlbumItemsProvider = FutureProvider.autoDispose
    .family<List<FotoItemDto>, ({FotoSpace space, String albumId})>((
      ref,
      arg,
    ) async {
      final api = ref.watch(fotoApiProvider)?.inSpace(arg.space);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.albumItems(arg.albumId);
    }, retry: _noRetry);

final photoFolderItemsProvider = FutureProvider.autoDispose
    .family<List<FotoItemDto>, ({FotoSpace space, String folderId})>((
      ref,
      arg,
    ) async {
      final api = ref.watch(fotoApiProvider)?.inSpace(arg.space);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.folderItems(arg.folderId);
    }, retry: _noRetry);

/// 子文件夹（文件夹下钻）
final photoSubFoldersProvider = FutureProvider.autoDispose
    .family<List<FotoFolderDto>, ({FotoSpace space, String parentId})>((
      ref,
      arg,
    ) async {
      final api = ref.watch(fotoApiProvider)?.inSpace(arg.space);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.folders(parentId: arg.parentId);
    }, retry: _noRetry);

/// 刷新当前空间的所有相册数据
void refreshPhotos(Ref ref) {
  ref.invalidate(photoTimelineProvider);
  ref.invalidate(photoAlbumsProvider);
  ref.invalidate(photoFoldersProvider);
  ref.invalidate(photoFavoritesProvider);
  ref.invalidate(photoPersonsProvider);
  ref.invalidate(photoConceptsProvider);
}

// ---------------------------------------------------------------- 人物 / 场景

/// 人物列表（`Browse.Person/list` **v1**）。
///
/// 官方 Web 前端在"一个人都没有"时还会拿 `show_more` 再取一次
/// （`Cf`：`count==0 && more` → 把 `show_more` 打开）—— 也就是说**空列表
/// 不等于没识别到人**，服务端会把低置信度的人折叠在 `show_more` 里。
/// 这里照抄这个回退：普通列表为空时补一次 `show_more:true`，避免误报空态。
final photoPersonsProvider = FutureProvider.autoDispose<List<FotoPersonDto>>((
  ref,
) async {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  final people = await api.persons();
  if (people.isNotEmpty) return people;
  return api.persons(showMore: true);
}, retry: _noRetry);

/// 场景 / 主题列表（`Browse.Concept/list` **v2**）。
final photoConceptsProvider = FutureProvider.autoDispose<List<FotoConceptDto>>((
  ref,
) async {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.concepts();
}, retry: _noRetry);

/// 人物总数（`Browse.Person/count` **v1**）。
///
/// 与 [photoPersonsProvider] 同一口径：普通计数为 0 时再用 `show_more:true`
/// 数一次（服务端会把低置信度的人折叠在 `show_more` 里），避免表头谎报 0。
final photoPersonCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  final normal = await api.personCount();
  if (normal > 0) return normal;
  return api.personCount(showMore: true);
}, retry: _noRetry);

/// 场景总数（`Browse.Concept/count` **v2**）。同上，空时再数一次隐藏项。
final photoConceptCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  final normal = await api.conceptCount();
  if (normal > 0) return normal;
  return api.conceptCount(showHidden: true);
}, retry: _noRetry);

/// 人物列表按**页大小**取（`Browse.Person/list` v1）—— 板块"加载更多"用。
///
/// 与 [photoPersonsProvider] 的区别只有 `limit`：首屏仍走原来那个 provider
/// （`show_more` 回退语义不变），用户点"加载更多"才切到这个 family。
final photoPersonsPageProvider = FutureProvider.autoDispose
    .family<List<FotoPersonDto>, int>((ref, limit) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.persons(limit: limit);
    }, retry: _noRetry);

/// 场景列表按**页大小**取（`Browse.Concept/list` v2）—— 同上。
final photoConceptsPageProvider = FutureProvider.autoDispose
    .family<List<FotoConceptDto>, int>((ref, limit) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.concepts(limit: limit);
    }, retry: _noRetry);

/// 人物详情（`Browse.Person/get` **v1**）—— 详情页头用它拿封面 / 数量 / 名字。
///
/// 取不到（id 非数字 / 空列表）回 null，界面回落到从列表带进来的标题。
final photoPersonDetailProvider = FutureProvider.autoDispose
    .family<FotoPersonDto?, String>((ref, personId) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      final list = await api.personDetails([personId]);
      return list.isEmpty ? null : list.first;
    }, retry: _noRetry);

/// 场景详情（`Browse.Concept/get` **v2**）—— 同上。
final photoConceptDetailProvider = FutureProvider.autoDispose
    .family<FotoConceptDto?, String>((ref, conceptId) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      final list = await api.conceptDetails([conceptId]);
      return list.isEmpty ? null : list.first;
    }, retry: _noRetry);

/// 人脸识别迁移进度（`Browse.Person/get_migration_status`）。
///
/// 只在人物列表命中 `901`（迁移未完成）时才需要，用来给"整理中"多一句进度。
final photoPersonMigrationProvider =
    FutureProvider.autoDispose<FotoPersonMigrationDto>((ref) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.personMigrationStatus();
    }, retry: _noRetry);

/// 某个人物名下的照片（`Browse.Item/list` + `person_id`）。
final photoPersonItemsProvider = FutureProvider.autoDispose
    .family<List<FotoItemDto>, ({FotoSpace space, String personId})>((
      ref,
      arg,
    ) async {
      final api = ref.watch(fotoApiProvider)?.inSpace(arg.space);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.personItems(arg.personId);
    }, retry: _noRetry);

/// 某个场景名下的照片（`Browse.Item/list` + `concept_id`）。
final photoConceptItemsProvider = FutureProvider.autoDispose
    .family<List<FotoItemDto>, ({FotoSpace space, String conceptId})>((
      ref,
      arg,
    ) async {
      final api = ref.watch(fotoApiProvider)?.inSpace(arg.space);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.conceptItems(arg.conceptId);
    }, retry: _noRetry);

// ---------------------------------------------------------------- 标签

/// 当前空间的全部标签（`Browse.GeneralTag/list`）。
final photoTagsProvider = FutureProvider.autoDispose<List<FotoTagDto>>((
  ref,
) async {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.generalTags();
}, retry: _noRetry);

/// 批量打标签的写操作（加 / 去 / 新建 / 联想 / 取交集）。
///
/// 与收藏、相册写同一个口径：**服务端是唯一事实来源** —— 写完只 invalidate，
/// 不做本地乐观更新；部分失败按服务端 `error_list` 返回给界面提示。
class PhotoTagActions {
  PhotoTagActions(this.ref);

  final Ref ref;

  FotoApi get _api {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) throw StateError(currentText().setNotConnected);
    return api;
  }

  /// 一批照片上的**共同标签 id**（`Browse.Item/get_tag`）
  Future<List<String>> intersection(List<String> itemIds) =>
      _api.itemTagIds(itemIds);

  /// 标签联想（`Browse.GeneralTag/suggest`）
  Future<List<FotoTagDto>> suggest(String keyword, {int limit = 20}) =>
      _api.suggestTags(keyword, limit: limit);

  /// 新建标签（`Browse.GeneralTag/create`），成功后刷新标签列表
  Future<FotoTagDto?> create(String name) async {
    final tag = await _api.createTag(name);
    ref.invalidate(photoTagsProvider);
    return tag;
  }

  /// 批量加/去标签，返回服务端 `error_list` 里的失败项（空 = 全成功）
  Future<List<String>> apply({
    required List<String> itemIds,
    List<String> addTagIds = const [],
    List<String> removeTagIds = const [],
  }) async {
    final failed = <String>{};
    if (addTagIds.isNotEmpty) {
      failed.addAll(await _api.addTags(itemIds: itemIds, tagIds: addTagIds));
    }
    if (removeTagIds.isNotEmpty) {
      failed.addAll(
        await _api.removeTags(itemIds: itemIds, tagIds: removeTagIds),
      );
    }
    _refresh();
    return failed.toList();
  }

  void _refresh() {
    ref.invalidate(photoTagsProvider);
    ref.invalidate(photoTimelineProvider);
    ref.invalidate(photoAlbumsProvider);
    ref.invalidate(photoFavoritesProvider);
    ref.invalidate(photoAlbumItemsProvider);
    ref.invalidate(photoFolderItemsProvider);
  }
}

final photoTagActionsProvider = Provider<PhotoTagActions>(PhotoTagActions.new);

/// 相册批量/单项**删除**（`Browse.Item/delete` → DSM 回收站）。
///
/// 删完把相册各列表全部失效（时间轴/相册/收藏/文件夹/相册内页），
/// 保证界面不会留着一张已经删掉的照片。
class PhotoDeleteActions {
  PhotoDeleteActions(this.ref);

  final Ref ref;

  /// 返回失败项 id（空 = 全成功）。会话过期等异常原样抛出。
  Future<List<String>> delete(List<String> itemIds) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return const [];
    final failed = await api.deleteItems(itemIds);
    if (failed.isEmpty) _refresh();
    return failed;
  }

  void _refresh() {
    ref.invalidate(photoTimelineProvider);
    ref.invalidate(photoAlbumsProvider);
    ref.invalidate(photoFavoritesProvider);
    ref.invalidate(photoAlbumItemsProvider);
    ref.invalidate(photoFolderItemsProvider);
    ref.invalidate(photoTagsProvider);
  }
}

final photoDeleteActionsProvider = Provider<PhotoDeleteActions>(
  PhotoDeleteActions.new,
);

/// 相册**下载落盘目录**（可覆盖 → 测试不必碰 path_provider 平台通道）。
final photoDownloadDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => fileDownloadDirectory,
);

/// 视频画质偏好（官方 `play_quality`：`auto` / `quality` / `speed`）。
///
/// 只是**选档策略**，不是发给服务端的字符串；语义见
/// `chooseFotoVideoPlayback`（`foto_api.dart`）。
final fotoVideoQualityBiasProvider =
    NotifierProvider<FotoVideoQualityBiasNotifier, FotoVideoQualityBias>(
      FotoVideoQualityBiasNotifier.new,
    );

class FotoVideoQualityBiasNotifier extends Notifier<FotoVideoQualityBias> {
  @override
  FotoVideoQualityBias build() => FotoVideoQualityBias.auto;

  void set(FotoVideoQualityBias bias) => state = bias;
}

/// 某个视频该走哪条通道（Download 原文件 / Streaming 某转码档）。
///
/// 先 `Browse.Item/get` 取 `video_convert` / `video_meta`，再按当前偏好 +
/// 网络类型跑官方选档算法（[chooseFotoVideoPlayback]）。
///
/// **查不到素材 / 查不出网络类型 → 一律 Download 原文件**：这是真机唯一
/// 取证过的通道（`docs/live-nas-verification.md` §4.3），Streaming 还没跑通。
final fotoVideoPlanProvider = FutureProvider.autoDispose
    .family<FotoVideoPlaybackPlan, String>((ref, itemId) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null) return const FotoVideoPlaybackPlan.original();
      final bias = ref.watch(fotoVideoQualityBiasProvider);
      final FotoVideoInfoDto info;
      try {
        info = await api.videoPlaybackInfo(itemId);
      } catch (_) {
        return const FotoVideoPlaybackPlan.original();
      }
      final net = await ref.read(networkTypeProbeProvider).current();
      // 判不出网络类型（桌面/测试/权限缺失）→ 不冒险切到未取证的 Streaming
      if (net == NetworkType.unknown || net == NetworkType.none) {
        return const FotoVideoPlaybackPlan.original();
      }
      return chooseFotoVideoPlayback(
        info: info,
        bias: bias,
        onWifi: net.isWifi,
      );
    }, retry: _noRetry);
