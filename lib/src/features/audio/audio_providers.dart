// Audio Station 模块的依赖注入、状态与动作（阶段二 A：Audio Station 普通用户功能）。
//
// 分层与其它模块一致：`DsmWebApi → AudioStationApi（协议）→ providers（本文件）→ 页面`。
// 接口层的事实来源是 `docs/stage2-audio-download-api.md` §2.1–§2.4（逐字对齐）。
//
// 结构照 `features/downloads/download_providers.dart`：
//   * 列表用**分页控制器**（`load`/`loadMore`/`refresh`），空态/错误态区分
//     "套件未安装 / 无权限 / 网络失败"；
//   * 详情/歌词用 `FutureProvider.family`；
//   * 写操作（评分/收藏）走 `AudioActions`，失败抛给页面提示。
//
// **只做普通用户功能**：播放列表写操作、分享、智能列表、电台/DLNA、语音通道、
// 所有 admin-only 方法都不在这里，也不在 UI 里（见 `audio_station.dart` 顶部注释）。
library;

import 'dart:async';

import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../data/audio_station.dart';
import '../../data/dto/audio_station_dto.dart';
import '../../dsm/webapi.dart';
import '../media/audio_handler.dart';
import '../files/file_thumb.dart' show looksLikeImage;
import '../media/authed_image.dart';
import '../media/media_playback_store.dart';
import '../servers/session_controller.dart';
import 'audio_album_cover.dart';
import 'audio_cover.dart';
import 'audio_offline_store.dart';
import 'audio_radio_relay.dart';
import 'audio_radio_stream.dart';

/// 音乐模块的 API 层。未连接时为 null（页面显示"未连接"而不是崩）。
final audioApiProvider = Provider<AudioStationApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : AudioStationApi(conn.api);
});

/// ★ r638（**DA230**）：音乐**列表行**封面的 URL 记忆。
///
/// `ref.watch(audioApiProvider)` ⇒ 换会话/续期时整个记忆表重建 —— 旧 `_sid`
/// 拼出来的 URL 不会被留在表里（"记住 URL"与"会话必须换来新的"两件事同时成立）。
final songRowCoverUrlProvider = Provider<SongRowCoverUrlMemo>(
  (ref) => SongRowCoverUrlMemo(ref.watch(audioApiProvider)),
);

/// **专辑封面的两级解析**（r439）：专辑级 `Cover.getcover` 不是真图时，
/// 逐首探 `Cover.getsongcover`（**最多 [AlbumCoverResolver.maxSongs] 首**，
/// 默认 1；判据与代价见 `audio_album_cover.dart` 文件头与 r427 实测）。
///
/// ★ `identity` 必须与 `AudioCoverImage` 的 `identity` 一致（默认 `album.name`）：
/// 命中时把字节按 `identity|url` 塞进 [AuthedImageCache]，随后 `AuthedImage`
/// 取的就是同一份缓存（**同一张封面一个会话只取一次**）。
final albumCoverResolverProvider = Provider<AlbumCoverResolver?>((ref) {
  final api = ref.watch(audioApiProvider);
  if (api == null) return null;
  return AlbumCoverResolver(
    probeCover: (url, cacheKey) async {
      try {
        final bytes = await api.api.getBytes(url);
        // "这算不算图"复用 files/file_thumb.dart 的**同一个**实现（§2.0.8 ④）
        if (!looksLikeImage(Uint8List.fromList(bytes))) return false;
        AuthedImageCache.put(
          cacheKey,
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        );
        return true;
      } catch (_) {
        // 404（`DsmTransportException`）/ 网络错 ⇒ 这一首没有真图
        return false;
      }
    },
    listSongs: (album, albumArtist) async {
      final page = await api.listSongs(
        album: album,
        albumArtist: albumArtist,
        limit: 1,
      );
      return page.items;
    },
    albumCoverUrl: (album, albumArtist) =>
        api.albumCoverUrl(album, albumArtist: albumArtist),
    songCoverUrl: (song) => api.songCoverUrl(song.id),
  );
});

/// `SYNO.AudioStation.Info / getinfo` v6 —— 能力探测（转码/权限位）。
///
/// 失败就给 null，不阻塞列表（与 `downloadStatisticProvider` 同款）。
final audioInfoProvider = FutureProvider<AudioInfoDto?>((ref) async {
  final api = ref.watch(audioApiProvider);
  if (api == null || !api.installed) return null;
  try {
    return await api.getInfo();
  } catch (_) {
    return null;
  }
}, retry: noRetry);

/// `SYNO.AudioStation.WebPlayer / getplaylist` v1 —— **服务端**播放队列状态。
///
/// 门控：未连接 / 未安装 / 能力表缺 `WebPlayer` → null
/// （页面据此给"不支持"空态，且**不发**注定 102 的请求）。
///
/// ⚠️ **关掉 Riverpod 3 的自动重试**（`retry: … => null`）：默认重试会让
/// 失败态在后台反复转圈、界面一直停在 loading —— 就变成"把失败渲染成空/无限转圈"。
/// 失败必须**立刻**变成可见的错误态，重试交给页面上的「重试」按钮（用户可控）。
/// ★ r405：加 `autoDispose` —— 真机实测（`docs/evidence-r405/device/r405_07*`）：
/// 同一会话内**再次进入**本页时，服务端队列已从 2 条变 1 条而页面**仍渲染 2 行**
/// （`total=1` 的宿主回读与同一刻的页面 `dump` 并存）；冷启动后同一页读到的就是
/// 1 行 ⇒ 不是"读不到"，是**会话内不再重取**。本页数据源是**外部**（DSM 网页播放器）
/// 会改的服务端队列，缓存整个会话等于让用户看旧账 ⇒ 每次进页重取。
final audioWebPlayerQueueProvider =
    FutureProvider.autoDispose<AudioWebPlayerQueueDto?>((ref) async {
      final api = ref.watch(audioApiProvider);
      if (api == null ||
          !api.installed ||
          !api.hasApi(AudioStationApi.apiWebPlayer)) {
        return null;
      }
      return api.getWebPlayerQueue();
    }, retry: (retryCount, error) => null);

// ---------------------------------------------------------------- 列表查询

/// 歌曲列表的查询条件（官方 `Song.list` 的过滤参数 + `Song.search` 的 keyword）。
///
/// 用 record 是因为它有**结构相等**：Riverpod family 依赖 `==`/`hashCode`，
/// 这样 `audioSongListProvider(...)` 才不会每次 build 都当成新实例。
typedef SongQuery = ({
  String? album,
  String? albumArtist,
  String? artist,
  String? composer,
  String? genre,
  String? folder,
  String? playlist,
  String? keyword,
  AudioLibrary? library,
});

/// 专辑列表的查询条件（`filter` = A12 的首字母过滤，如 `'A'`）。
typedef AlbumQuery = ({
  String? artist,
  String? composer,
  String? genre,
  String? search,
  String? filter,
  AudioLibrary? library,
});

/// 艺术家/作曲家/流派的查询条件（共用一个控制器，按 [AudioBrowseKind] 分派）。
typedef NamedQuery = ({
  AudioBrowseKind kind,
  String? genre,
  String? search,
  String? filter,
  AudioLibrary? library,
});

/// 文件夹列表的查询条件（`id` 或 `path` 二选一）。
typedef FolderQuery = ({String? id, String? path, AudioLibrary? library});

/// 播放列表列表的查询条件。
typedef PlaylistQuery = ({AudioLibrary? library});

/// 网络电台列表的查询条件（`container` 是**展开容器**的键，见
/// `AudioStationApi.listRadios`；`type`/`keyword` 未取证、只在调用方给值时发）。
///
/// ★ `container` 语义（第 392 轮权威取证）：`null` = 根级容器列表；
/// `SHOUTcast` = SHOUTcast 分类层；`SHOUTcast_<genre>` / `UserDefined` /
/// `Favorite` = 可播电台项列表。
typedef RadioQuery = ({
  String? container,
  String? type,
  String? keyword,
  AudioLibrary? library,
});

// record 类型别名只是别名，不能用 `SongQuery(...)` 构造 —— 常用查询在这里
// 做成 const 值，界面直接引用（record 有结构相等，family 不会重复建实例）。
const allSongsQuery = (
  album: null,
  albumArtist: null,
  artist: null,
  composer: null,
  genre: null,
  folder: null,
  playlist: null,
  keyword: null,
  library: null,
);

const allAlbumsQuery = (
  artist: null,
  composer: null,
  genre: null,
  search: null,
  filter: null,
  library: null,
);

const allFoldersQuery = (id: null, path: null, library: null);

const allPlaylistsQuery = (library: null);

/// A11：当前浏览的**音乐库**（`personal` 个人 / `shared` 共享）。
///
/// 官方前端用 `Window.getBrowseLibraryType()` 决定 `library=`；
/// `null` = 不传该参数（服务端按默认库返回，官方"全部"语义）。
class AudioLibraryController extends Notifier<AudioLibrary?> {
  @override
  AudioLibrary? build() => null;

  void select(AudioLibrary? value) => state = value;
}

final audioLibraryProvider =
    NotifierProvider<AudioLibraryController, AudioLibrary?>(
      AudioLibraryController.new,
    );

/// 各查询的 `library` 取值（A11 切换后由页面据此重建查询）。
SongQuery songsQueryOf(AudioLibrary? library) => (
  album: null,
  albumArtist: null,
  artist: null,
  composer: null,
  genre: null,
  folder: null,
  playlist: null,
  keyword: null,
  library: library,
);

AlbumQuery albumsQueryOf(AudioLibrary? library) => (
  artist: null,
  composer: null,
  genre: null,
  search: null,
  filter: null,
  library: library,
);

FolderQuery foldersQueryOf(AudioLibrary? library) =>
    (id: null, path: null, library: library);

PlaylistQuery playlistsQueryOf(AudioLibrary? library) => (library: library);

/// 网络电台：不带 `type`/`keyword`（真机无参调用即回容器列表）。
const allRadiosQuery = (
  container: null,
  type: null,
  keyword: null,
  library: null,
);

/// 网络电台**关键字搜台**（r441 接的 UI；`Radio.search` v2）。
///
/// ★ `keyword` 非空 ⇒ [RadioListController] 走 `Radio.search`，**不是** `Radio.list`
/// —— r441 只读取证：`list` 会**静默忽略**关键字并原样回根层三个容器
/// （`DA95`）。record 形状与 [allRadiosQuery] 相同（family 键不变），
/// `container` 恒 `null`：服务端**忽略** `search` 的 `container`（实测同结果、更慢）。
const RadioQuery Function(String keyword) radioSearchQuery = _radioSearchQuery;

RadioQuery _radioSearchQuery(String keyword) => (
  container: null,
  type: null,
  keyword: keyword,
  library: null,
);

/// 名字型列表（艺术家/作曲家/流派）的查询：按分类 + 可选过滤。
NamedQuery namedQuery(
  AudioBrowseKind kind, {
  String? genre,
  String? search,
  String? filter,
  AudioLibrary? library,
}) => (
  kind: kind,
  genre: genre,
  search: search,
  filter: filter,
  library: library,
);

/// 歌曲搜索的查询（走 `Song.search` v3）。
SongQuery songSearchQuery(String keyword) => (
  album: null,
  albumArtist: null,
  artist: null,
  composer: null,
  genre: null,
  folder: null,
  playlist: null,
  keyword: keyword,
  library: null,
);

// ---------------------------------------------------------------- 分页状态

/// 一页数据（各接口的返回页统一成这个形状）。
class AudioChunk<T> {
  const AudioChunk(this.items, this.total);

  final List<T> items;
  final int total;
}

/// 音乐库列表的本地状态（分页 + 是否还有更多 + 失败大类）。
class AudioPagedState<T> {
  const AudioPagedState({
    this.items = const [],
    this.total = 0,
    this.loading = false,
    this.loadingMore = false,
    this.loaded = false,
    this.failure,
    this.errorText,
    this.apiMissing = false,
  });

  final List<T> items;
  final int total;

  /// 首页加载中（骨架屏）。
  final bool loading;

  /// 触底加载下一页中。
  final bool loadingMore;

  /// 至少成功加载过一次（区分"还没加载"与"加载完是空的"）。
  final bool loaded;

  /// 失败大类（套件未安装 / 无权限 / 网络 / 其它）。
  final AsFailureKind? failure;

  /// 失败的可读文案（`describeAudioError`）。
  final String? errorText;

  /// 还没连接会话（`audioApiProvider == null`）。
  final bool apiMissing;

  bool get hasMore => items.length < total;

  AudioPagedState<T> copyWith({
    List<T>? items,
    int? total,
    bool? loading,
    bool? loadingMore,
    bool? loaded,
    AsFailureKind? failure,
    String? errorText,
    bool? apiMissing,
    bool clearError = false,
  }) => AudioPagedState<T>(
    items: items ?? this.items,
    total: total ?? this.total,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    loaded: loaded ?? this.loaded,
    failure: clearError ? null : (failure ?? this.failure),
    errorText: clearError ? null : (errorText ?? this.errorText),
    apiMissing: apiMissing ?? this.apiMissing,
  );
}

/// 分页控制器基类（每个分类一个子类，只实现 [fetchPage]）。
///
/// 「套件未安装」在发请求**之前**就判定（能力表里没有 `SYNO.AudioStation.Info`），
/// 避免发一次注定 102 的请求 —— 与下载模块同款，界面才能给对的空态。
abstract class AudioPagedController<T> extends Notifier<AudioPagedState<T>> {
  @override
  AudioPagedState<T> build() => AudioPagedState<T>();

  AudioStationApi? get _api => ref.read(audioApiProvider);

  /// 子类实现：拉一页（`offset`/`limit`）。
  Future<AudioChunk<T>> fetchPage(AudioStationApi api, int offset, int limit);

  /// 本列表**独有的能力位**是否缺失（默认 `false` = 只看套件级 [AudioStationApi.installed]）。
  ///
  /// 子类覆盖它，就能在"套件在、但这个分类的 API 没被 `SYNO.API.Info` 注册"时
  /// **不发注定 102 的请求**、直接给与"未安装"同一套空态 —— 门控语义统一为
  /// "缺失 → 隐藏/给未安装空态，且不发探测"（硬要求）。
  bool missingRequiredApi(AudioStationApi api) => false;

  Future<void> load({bool silent = false}) async {
    final api = _api;
    if (api == null) {
      state = state.copyWith(
        loading: false,
        apiMissing: true,
        clearError: true,
      );
      return;
    }
    if (!api.installed || missingRequiredApi(api)) {
      state = state.copyWith(
        loading: false,
        loaded: true,
        items: const [],
        total: 0,
        failure: AsFailureKind.notInstalled,
        errorText: describeAudioError(
          DsmApiException(DsmErrorCode.apiNotFound, method: 'AudioStation'),
        ),
        apiMissing: false,
      );
      return;
    }
    state = state.copyWith(
      loading: true,
      apiMissing: false,
      items: silent ? null : const [],
      total: silent ? null : 0,
      clearError: true,
    );
    try {
      final page = await fetchPage(api, 0, AudioStationApi.pageSize);
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
        failure: audioFailureKind(e),
        errorText: describeAudioError(e),
      );
    }
  }

  Future<void> loadMore() async {
    if (state.loadingMore || state.loading || !state.hasMore) return;
    final api = _api;
    if (api == null) return;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await fetchPage(
        api,
        state.items.length,
        AudioStationApi.pageSize,
      );
      state = state.copyWith(
        loadingMore: false,
        items: [...state.items, ...page.items],
        total: page.total,
      );
    } catch (e) {
      state = state.copyWith(
        loadingMore: false,
        failure: audioFailureKind(e),
        errorText: describeAudioError(e),
      );
    }
  }

  Future<void> refresh() => load(silent: true);
}

// ---------------------------------------------------------------- 具体列表

final audioSongListProvider =
    NotifierProvider.family<
      SongListController,
      AudioPagedState<AudioSongDto>,
      SongQuery
    >(SongListController.new);

/// 歌曲列表：有 `keyword` 走 `Song.search`，否则走 `Song.list`。
class SongListController extends AudioPagedController<AudioSongDto> {
  SongListController(this.query);

  final SongQuery query;

  @override
  Future<AudioChunk<AudioSongDto>> fetchPage(
    AudioStationApi api,
    int offset,
    int limit,
  ) async {
    final keyword = query.keyword;
    if (keyword != null && keyword.trim().isNotEmpty) {
      final page = await api.searchSongs(
        keyword: keyword.trim(),
        offset: offset,
        limit: limit,
        library: query.library,
      );
      return AudioChunk(page.items, page.total);
    }
    final page = await api.listSongs(
      offset: offset,
      limit: limit,
      library: query.library,
      album: query.album,
      albumArtist: query.albumArtist,
      artist: query.artist,
      composer: query.composer,
      genre: query.genre,
      folder: query.folder,
      playlist: query.playlist,
    );
    return AudioChunk(page.items, page.total);
  }
}

final audioAlbumListProvider =
    NotifierProvider.family<
      AlbumListController,
      AudioPagedState<AudioAlbumDto>,
      AlbumQuery
    >(AlbumListController.new);

/// 专辑列表（`Album.list` v3）。
class AlbumListController extends AudioPagedController<AudioAlbumDto> {
  AlbumListController(this.query);

  final AlbumQuery query;

  @override
  Future<AudioChunk<AudioAlbumDto>> fetchPage(
    AudioStationApi api,
    int offset,
    int limit,
  ) async {
    final page = await api.listAlbums(
      offset: offset,
      limit: limit,
      library: query.library,
      artist: query.artist,
      composer: query.composer,
      genre: query.genre,
      search: query.search,
      filter: query.filter,
    );
    return AudioChunk(page.items, page.total);
  }
}

final audioNamedListProvider =
    NotifierProvider.family<
      NamedListController,
      AudioPagedState<AudioNameDto>,
      NamedQuery
    >(NamedListController.new);

/// 艺术家（v4）/ 作曲家（v2）/ 流派（v3）列表 —— 三者返回形状相同
/// （`name` + `additional.avg_rating`），共用一个控制器。
class NamedListController extends AudioPagedController<AudioNameDto> {
  NamedListController(this.query);

  final NamedQuery query;

  @override
  Future<AudioChunk<AudioNameDto>> fetchPage(
    AudioStationApi api,
    int offset,
    int limit,
  ) async {
    switch (query.kind) {
      case AudioBrowseKind.artist:
        final page = await api.listArtists(
          offset: offset,
          limit: limit,
          library: query.library,
          genre: query.genre,
          search: query.search,
          filter: query.filter,
        );
        return AudioChunk(page.items, page.total);
      case AudioBrowseKind.composer:
        final page = await api.listComposers(
          offset: offset,
          limit: limit,
          library: query.library,
          search: query.search,
        );
        return AudioChunk(page.items, page.total);
      case AudioBrowseKind.genre:
        final page = await api.listGenres(
          offset: offset,
          limit: limit,
          library: query.library,
          search: query.search,
        );
        return AudioChunk(page.items, page.total);
      default:
        // 其余分类不走这个控制器（调用方选错了）—— 给空页而不是崩。
        return const AudioChunk([], 0);
    }
  }
}

final audioFolderListProvider =
    NotifierProvider.family<
      FolderListController,
      AudioPagedState<AudioFolderItemDto>,
      FolderQuery
    >(FolderListController.new);

/// 文件夹列表（`Folder.list` v3）。
class FolderListController extends AudioPagedController<AudioFolderItemDto> {
  FolderListController(this.query);

  final FolderQuery query;

  @override
  Future<AudioChunk<AudioFolderItemDto>> fetchPage(
    AudioStationApi api,
    int offset,
    int limit,
  ) async {
    final page = await api.listFolders(
      id: query.id,
      path: query.path,
      offset: offset,
      limit: limit,
      library: query.library,
    );
    return AudioChunk(page.items, page.total);
  }
}

final audioPlaylistListProvider =
    NotifierProvider.family<
      PlaylistListController,
      AudioPagedState<AudioPlaylistDto>,
      PlaylistQuery
    >(PlaylistListController.new);

/// 播放列表列表（`Playlist.list` v3，**只读**）。
class PlaylistListController extends AudioPagedController<AudioPlaylistDto> {
  PlaylistListController(this.query);

  final PlaylistQuery query;

  @override
  Future<AudioChunk<AudioPlaylistDto>> fetchPage(
    AudioStationApi api,
    int offset,
    int limit,
  ) async {
    final page = await api.listPlaylists(
      offset: offset,
      limit: limit,
      library: query.library,
    );
    return AudioChunk(page.items, page.total);
  }
}

/// 电台**播放列表解析**用的 HTTP 出口（`.pls`/`.m3u` → 真流地址）。
///
/// ★ 可注入：单测里换成假实现（离线、不碰网络）。生产用 `dart:io` 的
/// `HttpClient`（公网公共 CA，**不共用** NAS 的 `DioFactory` 信任链）。
/// 明文电台流的**回环中继**（Android release 档网络策略只允许回环明文；
/// ExoPlayer 走系统策略 ⇒ 明文站直接被拒。详见 `audio_radio_relay.dart`）。
///
/// ★ 可注入：单测换成 [NoopRadioStreamRelay]（不真起服务）。
final radioStreamRelayProvider = Provider<RadioStreamRelay>(
  (ref) => LoopbackRadioStreamRelay(),
);

final radioStreamHttpProvider = Provider<RadioStreamHttp>(
  (ref) => IoRadioStreamHttp(),
);

final audioRadioListProvider =
    NotifierProvider.family<
      RadioListController,
      AudioPagedState<AudioRadioDto>,
      RadioQuery
    >(RadioListController.new);

/// 网络电台列表：**两种通道**
///
/// * [query] 的 `keyword` 为空 ⇒ `Radio.list` v2（容器分层 / 自定义 / 收藏）；
/// * `keyword` 非空 ⇒ `Radio.search` v2（**关键字搜台**，r441）。
///
/// 门控：`Radio` API 不在能力表里 → 与"套件未安装"同一套空态，且**不发请求**
/// （见 [missingRequiredApi]）；搜台还要 **v2**（`search` 在 v1 不存在，真机 `103`）。
class RadioListController extends AudioPagedController<AudioRadioDto> {
  RadioListController(this.query);

  final RadioQuery query;

  /// 本实例是不是"搜台"通道（`keyword` 非空）。
  bool get isSearch => (query.keyword ?? '').isNotEmpty;

  /// 服务端支持搜台吗？能力表未知时不门控（同 [AudioStationApi.hasApi] 口径）。
  ///
  /// ★ 直接问**当前** api（不缓存上一次 `load()` 的结论）：搜索页在**第一次加载前**
  ///   就要拿它决定"给不给搜"——缓存值那时还是默认 `true`，会把"不支持"画成"可以搜"
  ///   （r441 用例③b 当场抓到）。
  bool get searchSupported =>
      !isSearch || (_api?.supportsRadioSearch ?? true);

  @override
  bool missingRequiredApi(AudioStationApi api) {
    // ★ 搜台需要 `Radio.search`（只有 v2）⇒ 门控**多一档**：v1-only 的服务器上
    //   直接给"不支持"空态，**不发**注定 `103` 的请求（仪器：别用注定失败的请求探能力）。
    return !api.hasApi(AudioStationApi.apiRadio) ||
        (isSearch && !api.supportsRadioSearch);
  }

  @override
  Future<AudioChunk<AudioRadioDto>> fetchPage(
    AudioStationApi api,
    int offset,
    int limit,
  ) async {
    if (isSearch) {
      final page = await api.searchRadios(
        keyword: query.keyword!,
        offset: offset,
        limit: limit,
      );
      return AudioChunk(page.items, page.total);
    }
    final page = await api.listRadios(
      offset: offset,
      limit: limit,
      container: query.container,
      type: query.type,
      library: query.library,
    );
    return AudioChunk(page.items, page.total);
  }
}

// ---------------------------------------------------------------- 详情 / 歌词

/// 失败就报错、不做指数退避（同 `file_providers`/`office_providers`）：
/// 页面统一给「加载失败 + 重试」，自动重试会让"未安装/无权限"反复打服务端。
/// 共享实现见 `core/provider_retry.dart` 的 [noRetry]。

/// 单曲详情（`Song.getinfo` v3）。找不到返回 null。
final audioSongProvider = FutureProvider.family<AudioSongDto?, String>((
  ref,
  id,
) async {
  final api = ref.watch(audioApiProvider);
  if (api == null || !api.installed) return null;
  return api.getSong(id);
}, retry: noRetry);

/// 歌词（`Lyrics.getlyrics` v2）。没歌词回空串（不是错误）。
final audioLyricsProvider = FutureProvider.family<String, String>((
  ref,
  songId,
) async {
  final api = ref.watch(audioApiProvider);
  if (api == null) throw StateError('未连接');
  return api.getLyrics(songId);
}, retry: noRetry);

/// 播放列表详情 + 曲目（`Playlist.getinfo` v3，**只读**）。
final audioPlaylistDetailProvider =
    FutureProvider.family<AudioPlaylistDto?, String>((ref, id) async {
      final api = ref.watch(audioApiProvider);
      if (api == null || !api.installed) return null;
      return api.getPlaylist(id);
    }, retry: noRetry);

/// 收藏（`Pin.list` v1，**新 API**）。
///
/// 未安装/未连接时抛出对应异常，页面用 [audioFailureKind] 归类后给对的空态。
final audioPinsProvider = FutureProvider<List<AudioPinDto>>((ref) async {
  final api = ref.watch(audioApiProvider);
  if (api == null) throw StateError('未连接');
  if (!api.installed) {
    throw DsmApiException(DsmErrorCode.apiNotFound, method: 'Pin.list');
  }
  return api.listPins();
}, retry: noRetry);

/// C4：远程播放器列表（`RemotePlayer.list` v3→v1，NAS 侧发现）。
///
/// ★ 根键形状未取证 ⇒ 数据层防御式解析（见 `listRemotePlayers`），
/// 这里原样透传 `Map`，**不由 UI 猜字段**。
final audioRemotePlayersProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(audioApiProvider);
  if (api == null) throw StateError('未连接');
  if (!api.installed) {
    throw DsmApiException(
      DsmErrorCode.apiNotFound,
      method: 'RemotePlayer.list',
    );
  }
  return api.listRemotePlayers();
}, retry: noRetry);

/// "建议的流派"（`Genre.list_default_genre` **v3**）。
///
/// 官方把内置类型当首页"默认类型"入口用；这里在流派标签页顶部做一条
/// 推荐带（**接线**：此前该方法只有测试引用，属死代码）。失败就回空，
/// 不影响流派列表本身（与 `audioGlobalSearchProvider` 同款）。
final audioDefaultGenresProvider = FutureProvider<List<AudioNameDto>>((
  ref,
) async {
  final api = ref.watch(audioApiProvider);
  if (api == null || !api.installed) return const [];
  try {
    return await api.listDefaultGenres();
  } catch (_) {
    return const [];
  }
}, retry: noRetry);

/// 转码音质档位（`bitrate`，bps）—— 官方三档 128000/192000/320000。
///
/// 默认 **128000**：既是有据可依的最低档，也是"不发 `bitrate` 时服务端默认"
/// 的同一输出（真机实测两者字节数完全相同，审计 §1.7），因此默认行为不变。
final audioTranscodeBitrateProvider =
    NotifierProvider<AudioTranscodeBitrateController, int>(
      AudioTranscodeBitrateController.new,
    );

/// 音质档位选择。**非法档位不发**：不在 [AudioStationApi.kTranscodeBitrates]
/// 里的值一律忽略（保持当前档）。
class AudioTranscodeBitrateController extends Notifier<int> {
  @override
  int build() => 128000;

  void select(int bps) {
    if (!AudioStationApi.isValidTranscodeBitrate(bps)) return;
    state = bps;
  }
}

/// 全局搜索的分类聚合（`Search.list` v1）。
///
/// 歌曲结果走 [audioSongListProvider]（`Song.search`，参数有逐字证据）；
/// 这里只补"专辑/艺术家/流派/作曲家"的聚合段。**失败就回空**，不影响歌曲结果
/// —— `Search.list` 的分类键取值在 doc §2.3 里只给了键名，按官方
/// `getSearchJsonObj` 补齐（见 `AudioStationApi.globalSearch`），风险留在真机。
final audioGlobalSearchProvider =
    FutureProvider.family<AudioGlobalSearchResult, String>((
      ref,
      keyword,
    ) async {
      final api = ref.watch(audioApiProvider);
      if (api == null || !api.installed) {
        return const AudioGlobalSearchResult();
      }
      try {
        return await api.globalSearch(keyword: keyword);
      } catch (_) {
        return const AudioGlobalSearchResult();
      }
    }, retry: noRetry);

// ---------------------------------------------------------------- 写操作

/// 写操作（评分 / 收藏 / 取消收藏 / 联网搜歌词）—— 页面直接用，失败抛给页面提示。
class AudioActions {
  const AudioActions(this.api);

  final AudioStationApi? api;

  /// `Song.setrating` v2（`rating` 0–5，0 = 清除评分）。
  Future<void> setRating(List<String> ids, int rating) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    await a.setRating(ids, rating);
  }

  /// `Pin.pin` v1。
  Future<void> addPin(AudioPinRequest item) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    await a.addPins([item]);
  }

  /// `Pin.unpin` v1（参数是 `items` 数组，见 `AudioStationApi.removePins` 的说明）。
  Future<void> removePin(String id) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    await a.removePins([id]);
  }

  /// `Pin.rename` v1 —— 收藏改名（接线：此前只有测试引用）。
  Future<void> renamePin(String id, String name) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    await a.renamePin(id, name);
  }

  /// `Pin.reorder` v1 —— 收藏拖动排序（接线：此前只有测试引用）。
  ///
  /// r398：载荷改成 **id 数组**（真机定案，见 `AudioStationApi.reorderPins`
  /// 的注释）—— 旧实现发"记录数组"在真机上必回 `117`。
  Future<void> reorderPins(List<AudioPinDto> pins) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    await a.reorderPins([for (final p in pins) p.id]);
  }

  /// `LyricsSearch.searchlyrics` v2 —— 联网搜歌词（手动触发）。
  Future<String> searchLyrics(String title, {String? artist}) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.searchLyrics(title: title, artist: artist);
  }

  /// D4：`Song.getsharing` v2（只读）。
  Future<AudioSharingInfo?> getSharing(String id) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.getSharing(id);
  }

  /// D4：`Song.setsharing` v2（**写操作**，受 `privilege.sharing` 门控）。
  Future<void> setSharing(String id, {required bool enable}) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    await a.setSharing(id, enable: enable);
  }

  /// D2：取 `Download.download` 的打包字节（只读）。
  Future<List<int>> downloadBytes(List<String> ids) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.downloadBytes(ids);
  }
}

final audioActionsProvider = Provider<AudioActions>(
  (ref) => AudioActions(ref.watch(audioApiProvider)),
);

// ============================================================ G2 批次新增
//
// A7 最近添加 · A8 Random100 · A10 最近/最常播放 · A12 首字母过滤（见上）
// · A14 多选（见页面）· A19 在线标签 · B6 断点续播 · B11 睡眠定时
// · B12 无缝播放 · D2 离线下载 · D4 分享。

// ------------------------------------------------------------ A7 / A8

/// A7 `最近添加`：官方首页常驻分类，参数逐字为
/// `Album.list{sort_by:"time", sort_direction:"DESC", limit:50}`
/// （`ApiEnumerator.java:253-257`）。
///
/// 真机复验（本批，只读）：`total=1210`、`limit=50` 时**正好回 50 条**。
final audioRecentlyAddedProvider =
    FutureProvider<AudioNamedPage<AudioAlbumDto>>((ref) async {
      final api = ref.watch(audioApiProvider);
      if (api == null || !api.installed) {
        return const AudioNamedPage(items: [], total: 0, offset: 0, limit: 0);
      }
      return api.listAlbums(
        sortBy: 'time',
        descending: true,
        limit: audioRecentlyAddedLimit,
      );
    }, retry: noRetry);

/// 官方 `limit=50`（`ApiEnumerator.java:255`）。
const int audioRecentlyAddedLimit = 50;

/// A8 `Random100`：`Song.list{sort_by:"random", limit:100}`（
/// `ApiEnumerator.java:499-521`；官方按钮 `btn_randomize_100`）。
///
/// 真机复验（本批，只读）：回 **100 首**（`total=100`）。
final audioRandom100Provider = FutureProvider<AudioSongPage>((ref) async {
  final api = ref.watch(audioApiProvider);
  if (api == null || !api.installed) {
    return const AudioSongPage(items: [], total: 0, offset: 0, limit: 0);
  }
  return api.listSongs(sortBy: 'random', limit: audioRandom100Limit, offset: 0);
}, retry: noRetry);

/// 官方 Random100 的条数（100）。
const int audioRandom100Limit = 100;

// ------------------------------------------------------------ A19 在线标签

/// 在线标签查询的 family key（record 有结构相等）。
typedef AudioTagQuery = ({String album, String albumArtist});

/// A19：`Tag.list` v1 —— 按 `album` + `album_artist` 查在线标签（Discogs）。
///
/// **失败就回空**（在线查询失败不应把单曲页变成错误页），并靠
/// [AudioTagSearchResult.isEmpty] + `hasError` 区分"没查到"与"查失败"。
final audioTagLookupProvider =
    FutureProvider.family<AudioTagLookupState, AudioTagQuery>((
      ref,
      query,
    ) async {
      final api = ref.watch(audioApiProvider);
      if (api == null || !api.installed) {
        return const AudioTagLookupState();
      }
      if (query.album.trim().isEmpty) return const AudioTagLookupState();
      try {
        final result = await api.tagList(
          album: query.album.trim(),
          albumArtist: query.albumArtist.trim(),
        );
        return AudioTagLookupState(result: result);
      } catch (e) {
        return AudioTagLookupState(
          failed: true,
          errorText: describeAudioError(e),
        );
      }
    }, retry: noRetry);

/// 在线标签查询的结果（**区分**"没查到"与"查失败"）。
class AudioTagLookupState {
  const AudioTagLookupState({this.result, this.failed = false, this.errorText});

  final AudioTagSearchResult? result;
  final bool failed;
  final String? errorText;

  bool get isEmpty => (result?.items.isEmpty ?? true) && !failed;
}

// ------------------------------------------------------------ A10 / B6 本地收听记录

/// A10 + B6：本地收听记录（命中次数 / 上次播放时间 / 上次播放位置）。
///
/// **没有服务端 API** —— 官方安卓也是本地 SQLite（`hit_count DESC`，审计 §A10）。
final audioListenHistoryProvider =
    AsyncNotifierProvider<
      AudioListenHistoryController,
      Map<String, AudioPlayRecord>
    >(AudioListenHistoryController.new);

class AudioListenHistoryController
    extends AsyncNotifier<Map<String, AudioPlayRecord>> {
  MediaPlaybackStore get _store => ref.read(mediaPlaybackStoreProvider);

  /// 注入"现在"以便离线用例断言固定时间（生产用真实时钟）。
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<Map<String, AudioPlayRecord>> build() => _store.loadAudioHistory();

  Future<void> _put(AudioPlayRecord record) async {
    final current = state.value ?? const <String, AudioPlayRecord>{};
    final next = {...current, record.id: record};
    state = AsyncData(next);
    await _store.saveAudioHistory(next);
  }

  /// 起播一次（命中 +1、刷新时间、清掉旧断点）。
  Future<void> markPlayed(String id, {String title = ''}) async {
    // build() 可能还在飞；用最新已加载值为准（没有就当作空）。
    if (state.isLoading && !state.hasValue) {
      state = AsyncData(await _store.loadAudioHistory());
    }
    final current = state.value ?? const <String, AudioPlayRecord>{};
    await _put(
      audioMarkPlayed(current[id], id: id, title: title, nowMs: nowMs()),
    );
  }

  /// 位置上报（只更新断点，不改命中次数）。
  Future<void> markPosition(
    String id, {
    String title = '',
    required int positionMs,
    int durationMs = 0,
  }) async {
    if (state.isLoading && !state.hasValue) {
      state = AsyncData(await _store.loadAudioHistory());
    }
    final current = state.value ?? const <String, AudioPlayRecord>{};
    final prev = current[id];
    final next = audioMarkPosition(
      prev,
      id: id,
      title: title,
      positionMs: positionMs,
      durationMs: durationMs,
    );
    // 位置没变就不写盘（进度事件很密，省 IO）。
    if (prev != null &&
        prev.positionMs == next.positionMs &&
        prev.durationMs == next.durationMs) {
      return;
    }
    await _put(next);
  }

  /// B6：某曲目的续播落点（毫秒；不该续播 → 0）。
  int resumePositionMs(String id) =>
      audioResumePositionMs((state.value ?? const {})[id]);

  /// B6：确保本地记录已加载后，取续播落点（起播前调用）。
  Future<int> ensureResumePositionMs(String id) async {
    if (state.isLoading && !state.hasValue) {
      state = AsyncData(await _store.loadAudioHistory());
    }
    return resumePositionMs(id);
  }
}

/// A10：最近播放（本地）。
final audioRecentlyPlayedProvider = Provider<List<AudioPlayRecord>>((ref) {
  final all = ref.watch(audioListenHistoryProvider).value ?? const {};
  return audioRecentlyPlayed(all.values);
});

/// A10：最常播放（本地，官方 `hit_count DESC` 同语义）。
final audioMostPlayedProvider = Provider<List<AudioPlayRecord>>((ref) {
  final all = ref.watch(audioListenHistoryProvider).value ?? const {};
  return audioMostPlayed(all.values);
});

// ------------------------------------------------------------ B11 睡眠定时

/// B11：睡眠定时（官方 `widget/SleepTimer`，**纯客户端**）。
///
/// `state == null` → 未启动；`Duration.zero` → 到点（页面据此暂停并提示）。
final audioSleepTimerProvider =
    NotifierProvider<AudioSleepTimerController, Duration?>(
      AudioSleepTimerController.new,
    );

class AudioSleepTimerController extends Notifier<Duration?> {
  Timer? _timer;

  /// ★ r633（**DA221**）：用户选的**档位**（分钟）。
  ///
  /// `state` 是倒计时剩余量（每秒递减），不能拿来当"当前选的是哪一档"——
  /// 菜单需要的是一个**稳定的**选中标记（15/30/60/90）。
  int? _chosenMinutes;
  int? get chosenMinutes => _chosenMinutes;

  @override
  Duration? build() {
    ref.onDispose(_cancelTimer);
    return null;
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// 启动 / 重设倒计时（必须为正；非正直接忽略）。
  void start(Duration duration) {
    if (duration <= Duration.zero) return;
    _cancelTimer();
    _chosenMinutes = duration.inMinutes;
    state = duration;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = state;
      if (current == null) return;
      final next = current - const Duration(seconds: 1);
      if (next <= Duration.zero) {
        _cancelTimer();
        _chosenMinutes = null;
        state = Duration.zero;
        // ★ DA31（r386 **真机**撞到 / 同轮修）：到点必须**在这里自己暂停**。
        // 原来只有播放页 `_StreamSectionState` 的 `ref.listen` 会暂停 ——
        // 那条监听随页面销毁而消失，而本 provider 是**常驻**的：
        // 用户离开播放页后定时器照走，到点却没人暂停。
        // 真机读数（HONOR LGE-AN10 / 12:47:26→12:48:17，定时器 12:47:30 到点）：
        // `media_session` 一直 `state=3`、`position` 从 129308 ms 继续涨到
        // 181095 ms，`AudioTrack state:started` 一直在 ⇒ **播放根本没停**。
        // 现在由本控制器直接读音频 handler 暂停；页面那侧只负责"到点提示"
        // （`as-sleep-done`），挂载时两者都跑，暂停是幂等的。
        if (ref.mounted) unawaited(ref.read(audioHandlerProvider).pause());
      } else {
        state = next;
      }
    });
  }

  void cancel() {
    _cancelTimer();
    _chosenMinutes = null;
    state = null;
  }
}

// ------------------------------------------------------------ B12 无缝播放

/// B12：无缝播放（gapless）。
///
/// 官方 `Utilities.supportGapless() = !EqualizerSettings.enableEqualizer()`
/// （APK `Utilities.java:139`）—— **纯客户端播放器配置**，与服务端能力位无关。
/// 本机 `enable_equalizer=false`（真机）→ 官方语义下 gapless 为真。
///
/// 本实现把它作为**可切换的播放器配置**：开 → `just_audio` 预载下一首
/// （`setAudioSources(preload: true)`，即无缝）；关 → 逐条按需准备（会有间隙）。
final audioGaplessProvider = NotifierProvider<AudioGaplessController, bool>(
  AudioGaplessController.new,
);

class AudioGaplessController extends Notifier<bool> {
  @override
  bool build() => true;

  void setEnabled(bool enabled) => state = enabled;
}

// ------------------------------------------------------------ D2 离线下载

/// D2：已下载（离线缓存）的曲目 id 集合。
final audioOfflineIdsProvider =
    NotifierProvider<AudioOfflineIdsController, Set<String>>(
      AudioOfflineIdsController.new,
    );

class AudioOfflineIdsController extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    // 异步补一次真实列表；失败保持空集（不阻塞页面）。
    unawaited(_hydrate());
    return const {};
  }

  Future<void> _hydrate() async {
    try {
      final ids = await ref.read(audioOfflineStoreProvider).ids();
      if (!ref.mounted) return;
      if (ids.isNotEmpty) state = ids;
    } catch (_) {
      // 拿不到本地缓存列表不影响任何播放/浏览功能。
    }
  }

  Future<void> reload() async {
    final ids = await ref.read(audioOfflineStoreProvider).ids();
    if (!ref.mounted) return;
    state = ids;
  }
}
