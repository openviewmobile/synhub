// Audio Station 业务 API（**只做普通用户功能**）—— 在 [DsmWebApi] 之上把
// `SYNO.AudioStation.*`（老 CGI 代，20 个命名空间）与 `SYNO.AudioStation.Pin`
// （新 webapi5 代）收敛成强类型方法。
//
// ★ 权威事实来源：`docs/stage2-audio-download-api.md`（本项目对
//   AudioStation-x86_64-7.2.1-6006.spk 的离线取证）。本文件里的
//   **api 名 / method / 版本 / 参数名**逐字对齐该文档 §2.1–§2.4 与包内官方
//   Web 前端 `app/audio-utils.js` / `app/audio-common.js`；不要凭记忆改。
//
// 本轮实现（文档 §2.3 主表 A-1a/A-1b/A-1c/A-1d 的普通用户子集）：
//   * `Info.getinfo` v6                        —— 能力探测（决定 UI 分支）
//   * `Album.list` v3 · `Artist.list` v4 · `Composer.list` v2 ·
//     `Genre.list` v3 · `Genre.list_default_genre` **v3** —— 音乐库浏览
//   * `Folder.list` v3 · `Folder.getinfo` v3    —— 文件夹浏览
//   * `Song.list` v3 · `Song.search` v3 · `Song.getinfo` v3 —— 歌曲/搜索
//   * `Search.list` v1                          —— 全局搜索聚合
//   * `Playlist.list` v3 · `Playlist.getinfo` v3 —— 播放列表（**只读**）
//   * `Radio.list` v2                          —— 网络电台**列表**（wave2；容器/电台分开）
//   * `WebPlayer.getplaylist` v1               —— 服务端播放队列状态（wave2，只读）
//   * `Lyrics.getlyrics` v2 · `LyricsSearch.searchlyrics` v2 —— 歌词
//   * `Song.setrating` **v2**                   —— 评分/收藏（星标）
//   * `Pin.list` / `pin` / `unpin` v1           —— 收藏（锁定）
//   * `Stream.stream` / `transcode` v2          —— **只生成流式 URL**（§2.3 A-1b）
//   * `Cover.getcover` / `getsongcover` / `getfoldercover` v3 —— 封面 URL
//
// 明确**不做**（文档 §6.2 后置项与 admin-only，代码里也不留半成品）：
//   * 播放列表**写**（`create`/`delete`/`rename`/`updatesongs`/`saveplaying`/
//     `removemissing`/`copytolibrary`，依赖 `privilege.playlist_edit`）
//   * 分享（`Song.getsharing`/`setsharing`、`Playlist.editsharing`、`sharing_id`）
//   * 智能列表（`createsmart`/`updatesmart`/`savesearch`，`rules_json` 未核实 §5 U9）
//   * `Tag.*` / `Browse.Playlist.add_track`（参数未核实 §5 U5）
//   * 网络电台**播放 / 容器展开 / 增删改**（`Radio.add`/`search`/`updateradios`）——
//     wave2 只做 `Radio.list`；容器展开参数与电台 `url` 形态**未取证**
//   * DLNA（`MediaServer.*`/`RemotePlayer*`）/ `Download.download`
//   * `Proxy.*`（代理流/`getstreamid`，参数未取证）
//   * `WebPlayer.updateplaylist`（写队列；只读的 `getplaylist` 见 wave2）
//   * `VoiceAssistant.*`（Alexa 专用）
//   * 任何 admin-only（文档 §1.3：Audio Station **未发现方法级 admin 门槛**，
//     但 `Info.getinfo` 的 `privilege.*` 是应用内细分权限，UI 要据此隐藏入口）
//
// ⚠️ 数据层：**不许** import flutter / package:flutter（要能被 `dart run tool/*.dart`
// 加载）；文案走 `dataText(key, 中文原文)`（见 docs/app-identity-and-i18n.md §4.6）。
library;

import 'dart:convert';

import '../core/i18n/data_text.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/audio_station_dto.dart';
import 'media/media_format_support.dart';

/// `SYNO.AudioStation.Stream` 的三种流形态（官方 `getStreamingPlayTypeByRecord`
/// 的返回值域：`direct` / `mp3` / `wav`）。
enum AudioStreamMode {
  /// 直传原文件（`method=stream`，走 HTTP Range）。
  direct,

  /// 转码成 mp3（`method=transcode&format=mp3`）。
  mp3,

  /// 转码成 wav（`method=transcode&format=wav`）。
  wav,
}

/// 封面的 `view` 取值（官方前端用 `"default"`；其它取值未取证）。
class AudioCoverView {
  static const String normal = 'default';
  static const String large = 'large';
}

/// `SYNO.AudioStation.*` 的高层封装。**不持有传输** —— 传输由 [DsmWebApi] 管。
class AudioStationApi {
  AudioStationApi(DsmWebApi api) : api = api.withModule(TrafficModules.audio);

  final DsmWebApi api;

  // ------------------------------------------------------------ 常量（逐字）

  static const String apiInfo = 'SYNO.AudioStation.Info';
  static const String apiAlbum = 'SYNO.AudioStation.Album';
  static const String apiArtist = 'SYNO.AudioStation.Artist';
  static const String apiComposer = 'SYNO.AudioStation.Composer';
  static const String apiGenre = 'SYNO.AudioStation.Genre';
  static const String apiFolder = 'SYNO.AudioStation.Folder';
  static const String apiSong = 'SYNO.AudioStation.Song';
  static const String apiStream = 'SYNO.AudioStation.Stream';
  static const String apiPlaylist = 'SYNO.AudioStation.Playlist';
  static const String apiLyrics = 'SYNO.AudioStation.Lyrics';
  static const String apiLyricsSearch = 'SYNO.AudioStation.LyricsSearch';
  static const String apiCover = 'SYNO.AudioStation.Cover';
  static const String apiSearch = 'SYNO.AudioStation.Search';
  static const String apiRadio = 'SYNO.AudioStation.Radio';
  /// C4：远程播放器（NAS 侧发现的 DLNA 渲染器）。
  static const String apiRemotePlayer = 'SYNO.AudioStation.RemotePlayer';

  /// C4：远程播放器状态（官方优先用它，失败回落到 `RemotePlayer/getstatus`）。
  static const String apiRemotePlayerStatus =
      'SYNO.AudioStation.RemotePlayerStatus';
  static const String apiWebPlayer = 'SYNO.AudioStation.WebPlayer';
  static const String apiPin = 'SYNO.AudioStation.Pin';

  /// 在线标签查询（Discogs 代理，webapi5 代）。
  ///
  /// path 是 **`entry.cgi`**（不是 `query.cgi`），`SYNO.API.Info` 实测：
  /// `{path: entry.cgi, minVersion:1, maxVersion:1, requestFormat: JSON}`。
  static const String apiTag = 'SYNO.AudioStation.Tag';

  /// 歌曲打包下载（老 CGI 代，v1 只有 `download`）。
  static const String apiDownload = 'SYNO.AudioStation.Download';

  /// 官方分页大小（`NUM_REC_PER_PAGE`；Audio Station 前端同样是 25）。
  static const int pageSize = 25;

  /// `Pin.list` 官方传的"一次全取"（`baseParams:{offset:0,limit:-1}`）。
  static const int pinFetchAllLimit = -1;

  /// 官方 Web 前端自带的版本表（`audio-utils.js` 的
  /// `createWebAPIVersionMapping()`，逐字）。
  ///
  /// ⚠️ 它把 `Folder` 固定成 **2**，而 `AudioStation.api` 允许到 3（doc §2.1 脚注）。
  /// 本实现按文档 §2.3 主表取 **3**，并让能力表（`SYNO.API.Info`）收敛；
  /// 拿不到能力表时会话就按这里的默认值走。
  static const Map<String, int> webApiVersions = {
    apiAlbum: 3,
    apiArtist: 4,
    apiComposer: 2,
    'SYNO.AudioStation.Cover': 3,
    'SYNO.AudioStation.Download': 1,
    apiFolder: 2,
    apiGenre: 3,
    apiInfo: 6,
    apiLyrics: 2,
    apiLyricsSearch: 2,
    'SYNO.AudioStation.MediaServer': 1,
    apiPlaylist: 3,
    'SYNO.AudioStation.Proxy': 2,
    apiRadio: 2,
    'SYNO.AudioStation.RemotePlayer': 3,
    'SYNO.AudioStation.RemotePlayerStatus': 2,
    apiSearch: 1,
    apiSong: 3,
    apiStream: 2,
    apiWebPlayer: 1,
    apiPin: 1,
    apiTag: 1,
  };

  /// cgi 路径（逐字来自 `webapi/AudioStation.api` 的 `path` 字段，doc §2.1）。
  ///
  /// 只在能力表（`SYNO.API.Info`）没给 path 时兜底 —— 例如"未 discover"
  /// 或跨代聚合把 path 压成 `entry.cgi`。
  static const Map<String, String> cgiPaths = {
    apiInfo: 'AudioStation/info.cgi',
    apiAlbum: 'AudioStation/album.cgi',
    apiArtist: 'AudioStation/artist.cgi',
    apiComposer: 'AudioStation/composer.cgi',
    apiGenre: 'AudioStation/genre.cgi',
    apiFolder: 'AudioStation/folder.cgi',
    apiSong: 'AudioStation/song.cgi',
    apiStream: 'AudioStation/stream.cgi',
    'SYNO.AudioStation.Proxy': 'AudioStation/proxy.cgi',
    apiRadio: 'AudioStation/radio.cgi',
    apiPlaylist: 'AudioStation/playlist.cgi',
    'SYNO.AudioStation.RemotePlayer': 'AudioStation/remote_player.cgi',
    'SYNO.AudioStation.RemotePlayerStatus':
        'AudioStation/remote_player_status.cgi',
    apiWebPlayer: 'AudioStation/web_player.cgi',
    'SYNO.AudioStation.MediaServer': 'AudioStation/media_server.cgi',
    apiLyrics: 'AudioStation/lyrics.cgi',
    apiLyricsSearch: 'AudioStation/lyrics_search.cgi',
    apiCover: 'AudioStation/cover.cgi',
    'SYNO.AudioStation.Download': 'AudioStation/download.cgi',
    apiSearch: 'AudioStation/search.cgi',
    apiTag: 'entry.cgi',
  };

  /// `Song.getsharing` / `Song.setsharing` 的方法级版本（v1 没有，**v2 起**）。
  static const int versionSharing = 2;

  /// 方法级版本陷阱（doc §2.1）：这些方法**不能**照 `maxVersion` 取。
  static const int versionListDefaultGenre = 3;
  static const int versionSetRating = 2;
  static const int versionSavePlaying = 2;
  static const int versionRemoveMissing = 2;
  static const int versionGetLyrics = 2;

  /// `Stream.stream` / `Stream.transcode` 的版本 —— **跟随官方安卓客户端**。
  ///
  /// 官方 `ApiEnumerator.getPlayUrl` 逐字发 `version=1`
  /// （APK `ApiEnumerator.java:710-795`，审计 §1.6）；真机 v1/v2 都可用
  /// （审计 §1.7 末行），但客户端形态以官方客户端为准，取 1。
  static const int versionStream = 1;

  /// 官方转码档位（`TranscodeSetting.java`：`LOW/MEDIUM/HIGH` →
  /// `128000/192000/320000` bps，审计 §1.7 逐字）。
  ///
  /// 真机实测三档输出长度（同一曲）：2,432,000 / 3,648,000 / 6,080,000 B；
  /// 不发 `bitrate` 与 `bitrate=128000` 输出**完全相同**（服务端默认档 128 kbps）。
  static const Set<int> kTranscodeBitrates = {128000, 192000, 320000};

  /// 这个码率是不是官方三档之一。**非法档位不发**（宁可用服务端默认，
  /// 也不向服务端递一个没取过证的数值）。
  static bool isValidTranscodeBitrate(int? bps) =>
      bps != null && kTranscodeBitrates.contains(bps);

  // ------------------------------------------------------------ 能力 / 版本

  /// 候选版本里挑一个服务器真正支持的（与 `FileStationApi.negotiate` 同规则）。
  int negotiate(String apiName, List<int> candidates) {
    final entry = api.apiTable?[apiName];
    if (entry == null || candidates.isEmpty) {
      return candidates.isEmpty ? 1 : candidates.first;
    }
    final within = candidates.where(
      (c) => c >= entry.minVersion && c <= entry.maxVersion,
    );
    if (within.isNotEmpty) return within.reduce((a, b) => a > b ? a : b);
    return entry.maxVersion < candidates.last
        ? entry.maxVersion
        : entry.minVersion;
  }

  /// 某 API 的首选版本（[webApiVersions] 的表值，缺省 1）。
  int versionOf(String apiName) => webApiVersions[apiName] ?? 1;

  /// 服务器是否声明了某 API（`SYNO.API.Info` 实测表）。
  ///
  /// 表为空（未 discover）时按"未知"处理，返回 true —— 交给调用时的错误兜底。
  bool hasApi(String apiName) {
    final table = api.apiTable;
    if (table == null) return true;
    return table.containsKey(apiName);
  }

  /// **套件未安装**的强判据：能力表里没有 `SYNO.AudioStation.Info`。
  ///
  /// 与"有 API 但没权限（160/105）"和"网络不通"区分开，界面才能给对的空态
  /// （任务书硬要求：不要一律"加载失败"）。
  bool get installed => hasApi(apiInfo);

  /// 服务器是否支持某 API 的某版本（`minVersion <= v <= maxVersion`）。
  bool supports(String apiName, int version) {
    final entry = api.apiTable?[apiName];
    if (entry == null) return false;
    return version >= entry.minVersion && version <= entry.maxVersion;
  }

  /// 真正用于拼 URL 的 cgi 路径：能力表优先，[cgiPaths] 兜底。
  String cgiPath(String apiName) {
    final fromTable = api.apiTable?[apiName]?.path;
    if (fromTable != null && fromTable.isNotEmpty) {
      return fromTable.startsWith('/') ? fromTable.substring(1) : fromTable;
    }
    return cgiPaths[apiName] ?? api.apiPath(apiName);
  }

  // ------------------------------------------------------------ 能力探测

  /// `SYNO.AudioStation.Info / getinfo`（v6）。
  Future<AudioInfoDto> getInfo() async {
    final data = await api.call(
      apiInfo,
      'getinfo',
      preferredVersion: negotiate(apiInfo, const [6, 5, 4, 3, 2, 1]),
    );
    return AudioInfoDto.fromJson(data);
  }

  // ------------------------------------------------------------ 歌曲 / 搜索

  /// `SYNO.AudioStation.Song / list`（v3）。
  ///
  /// 参数逐字对齐 doc §2.3 A-1a 第 9 行与官方 `createParamsMapping`：
  /// `additional="song_tag,song_audio,song_rating"`，可选过滤 `album` /
  /// `album_artist` / `artist` / `composer` / `genre` / `genre_filter` /
  /// `playlist` / `folder` / `song_rating_meq` / `song_rating_leq` 等。
  /// 返回 root 是 **`data.songs`**、total 是 **`data.total`**。
  Future<AudioSongPage> listSongs({
    int offset = 0,
    int limit = pageSize,
    AudioLibrary? library,
    String? album,
    String? albumArtist,
    String? artist,
    String? composer,
    String? genre,
    String? genreFilter,
    String? playlist,
    String? folder,
    bool? recursive,
    int? ratingMeq,
    int? ratingLeq,
    String? sortBy,
    bool descending = false,
  }) async {
    final data = await api.call(
      apiSong,
      'list',
      preferredVersion: negotiate(apiSong, const [3, 2, 1]),
      params: {
        'additional': kSongAdditional,
        'offset': offset,
        'limit': limit,
        if (library != null) 'library': library.wire,
        if (_notEmpty(album)) 'album': album,
        if (_notEmpty(albumArtist)) 'album_artist': albumArtist,
        if (_notEmpty(artist)) 'artist': artist,
        if (_notEmpty(composer)) 'composer': composer,
        if (_notEmpty(genre)) 'genre': genre,
        if (_notEmpty(genreFilter)) 'genre_filter': genreFilter,
        if (_notEmpty(playlist)) 'playlist': playlist,
        if (_notEmpty(folder)) 'folder': folder,
        if (recursive != null) 'recursive': recursive,
        if (ratingMeq != null) 'song_rating_meq': ratingMeq,
        if (ratingLeq != null) 'song_rating_leq': ratingLeq,
        if (_notEmpty(sortBy)) ...{
          'sort_by': sortBy,
          'sort_direction': descending ? 'DESC' : 'ASC',
        },
      },
    );
    return _songsOf(data, offset: offset, limit: limit);
  }

  /// `SYNO.AudioStation.Song / search`（v3）。
  ///
  /// 官方前端把 `keyword` 放在 Song.search 上（`SEC_CFG` 的
  /// `class_music_allmusic` 搜索路径），返回 root 与 `list` 相同。
  Future<AudioSongPage> searchSongs({
    required String keyword,
    int offset = 0,
    int limit = pageSize,
    AudioLibrary? library,
    String? sortBy,
    bool descending = false,
  }) async {
    final data = await api.call(
      apiSong,
      'search',
      preferredVersion: negotiate(apiSong, const [3, 2, 1]),
      params: {
        'keyword': keyword,
        'additional': kSongAdditional,
        'offset': offset,
        'limit': limit,
        if (library != null) 'library': library.wire,
        if (_notEmpty(sortBy)) ...{
          'sort_by': sortBy,
          'sort_direction': descending ? 'DESC' : 'ASC',
        },
      },
    );
    return _songsOf(data, offset: offset, limit: limit);
  }

  /// `SYNO.AudioStation.Song / getinfo`（v3）—— 单曲记录。
  ///
  /// ⚠️ 服务器把单曲放在哪一层没有逐字证据（doc §5 U8）：这里同时认
  /// `data.songs[0]`（与 `list` 同根）与 `data`（直接就是记录）两种。
  Future<AudioSongDto?> getSong(String id) async {
    final data = await api.call(
      apiSong,
      'getinfo',
      preferredVersion: negotiate(apiSong, const [3, 2, 1]),
      params: {'id': id, 'additional': kSongAdditional},
    );
    final songs = data['songs'];
    if (songs is List && songs.isNotEmpty && songs.first is Map) {
      return AudioSongDto.fromJson(
        Map<String, dynamic>.from(songs.first as Map),
      );
    }
    if (data['id'] != null) return AudioSongDto.fromJson(data);
    return null;
  }

  /// `SYNO.AudioStation.Search / list`（v1）—— 全局搜索的分类聚合。
  ///
  /// 官方 `getSearchJsonObj("all", kw)`（逐字）把五个分类键**都设成同一个
  /// 关键字**：`{album:kw, artist:kw, composer:kw, genre:kw, title:kw}`；
  /// doc §2.3 第 12 行只给了键名没给取值，这里按该函数补齐。
  /// 返回 root `data`，各分类（`songs`/`albums`/`artists`/…）都是可选的。
  ///
  /// **分页（2026-09-22 真机取证）**：`docs/audio-api-live.md` §1 ——
  /// `Search:list` 传 `{offset,limit}` 时回 `{"albumTotal":1210,"albums":[…],…}`，
  /// 即**每个分类各有自己的 `*Total` 计数**（不是单一的 `total`）。
  /// 本批把 `offset`/`limit` 真正发出去并把五个 `*Total` 解出来
  /// （见 [AudioGlobalSearchResult.albumsTotal] 等），供分页判断用。
  Future<AudioGlobalSearchResult> globalSearch({
    required String keyword,
    int offset = 0,
    int limit = pageSize,
    AudioLibrary? library,
  }) async {
    final kw = keyword.trim();
    final data = await api.call(
      apiSearch,
      'list',
      preferredVersion: negotiate(apiSearch, const [1]),
      params: {
        'keyword': kw,
        // 逐字：`getSearchJsonObj("all", a)` → `e.album=a; e.artist=a;
        // e.composer=a; e.genre=a; e.title=a`。
        'album': kw,
        'artist': kw,
        'composer': kw,
        'genre': kw,
        'title': kw,
        'additional': kSongAdditional,
        'offset': offset,
        'limit': limit,
        if (library != null) 'library': library.wire,
      },
    );
    return AudioGlobalSearchResult.fromJson(data);
  }

  // ------------------------------------------- 专辑 / 艺术家 / 作曲家 / 流派

  /// `SYNO.AudioStation.Album / list`（v3）。
  Future<AudioNamedPage<AudioAlbumDto>> listAlbums({
    int offset = 0,
    int limit = pageSize,
    AudioLibrary? library,
    String? artist,
    String? composer,
    String? genre,
    String? genreFilter,
    String? search,
    String? filter,
    String? sortBy,
    bool descending = false,
  }) async {
    final data = await api.call(
      apiAlbum,
      'list',
      preferredVersion: negotiate(apiAlbum, const [3, 2, 1]),
      params: {
        'additional': kAvgRatingAdditional,
        'offset': offset,
        'limit': limit,
        if (library != null) 'library': library.wire,
        if (_notEmpty(artist)) 'artist': artist,
        if (_notEmpty(composer)) 'composer': composer,
        if (_notEmpty(genre)) 'genre': genre,
        if (_notEmpty(genreFilter)) 'genre_filter': genreFilter,
        if (_notEmpty(search)) 'search': search,
        // A12：官方首字母跳转用 **`filter=<字母>`**（`ApiEnumerator.java:325,334`）。
        // 真机 `Album.list {filter:'A'}` → 200 / total 940（本批复验）。
        if (_notEmpty(filter)) 'filter': filter,
        if (_notEmpty(sortBy)) ...{
          'sort_by': sortBy,
          'sort_direction': descending ? 'DESC' : 'ASC',
        },
      },
    );
    return _namedPageOf(
      data,
      'albums',
      AudioAlbumDto.fromJson,
      offset: offset,
      limit: limit,
    );
  }

  /// `SYNO.AudioStation.Artist / list`（v4）。
  Future<AudioNamedPage<AudioNameDto>> listArtists({
    int offset = 0,
    int limit = pageSize,
    AudioLibrary? library,
    String? genre,
    String? genreFilter,
    String? search,
    String? filter,
    String? sortBy,
    bool descending = false,
  }) => _listNamed(
    apiArtist,
    'artists',
    const [4, 3, 2, 1],
    offset: offset,
    limit: limit,
    library: library,
    genre: genre,
    genreFilter: genreFilter,
    search: search,
    filter: filter,
    sortBy: sortBy,
    descending: descending,
  );

  /// `SYNO.AudioStation.Composer / list`（v2）。
  Future<AudioNamedPage<AudioNameDto>> listComposers({
    int offset = 0,
    int limit = pageSize,
    AudioLibrary? library,
    String? search,
    String? sortBy,
    bool descending = false,
  }) => _listNamed(
    apiComposer,
    'composers',
    const [2, 1],
    offset: offset,
    limit: limit,
    library: library,
    search: search,
    sortBy: sortBy,
    descending: descending,
  );

  /// `SYNO.AudioStation.Genre / list`（v3）。
  Future<AudioNamedPage<AudioNameDto>> listGenres({
    int offset = 0,
    int limit = pageSize,
    AudioLibrary? library,
    String? search,
    String? sortBy,
    bool descending = false,
  }) => _listNamed(
    apiGenre,
    'genres',
    const [3, 2, 1],
    offset: offset,
    limit: limit,
    library: library,
    search: search,
    sortBy: sortBy,
    descending: descending,
  );

  /// `SYNO.AudioStation.Genre / list_default_genre`（**v3**，v1/v2 没有）。
  ///
  /// 返回内置类型；官方前端把它当"默认类型"列表用。
  Future<List<AudioNameDto>> listDefaultGenres({AudioLibrary? library}) async {
    final data = await api.call(
      apiGenre,
      'list_default_genre',
      preferredVersion: negotiate(apiGenre, const [versionListDefaultGenre]),
      params: {if (library != null) 'library': library.wire},
    );
    final raw = data['genres'];
    return [
      if (raw is List)
        for (final e in raw)
          if (e is Map) AudioNameDto.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  Future<AudioNamedPage<AudioNameDto>> _listNamed(
    String apiName,
    String root,
    List<int> versions, {
    required int offset,
    required int limit,
    AudioLibrary? library,
    String? genre,
    String? genreFilter,
    String? search,
    String? filter,
    String? sortBy,
    required bool descending,
  }) async {
    final data = await api.call(
      apiName,
      'list',
      preferredVersion: negotiate(apiName, versions),
      params: {
        'additional': kAvgRatingAdditional,
        'offset': offset,
        'limit': limit,
        if (library != null) 'library': library.wire,
        if (_notEmpty(genre)) 'genre': genre,
        if (_notEmpty(genreFilter)) 'genre_filter': genreFilter,
        if (_notEmpty(search)) 'search': search,
        // A12：首字母过滤（官方 `filter=<字母>`；真机 Artist filter=A → 627）。
        if (_notEmpty(filter)) 'filter': filter,
        if (_notEmpty(sortBy)) ...{
          'sort_by': sortBy,
          'sort_direction': descending ? 'DESC' : 'ASC',
        },
      },
    );
    return _namedPageOf(
      data,
      root,
      AudioNameDto.fromJson,
      offset: offset,
      limit: limit,
    );
  }

  // ------------------------------------------------------------ 文件夹

  /// `SYNO.AudioStation.Folder / list`（v3）。
  ///
  /// 必需参数是 `id` **或** `path`（doc §2.3 A-1a 第 7 行）。
  /// 返回 root **`data.items`**，另有 `data.folder_total`。
  Future<AudioFolderPage> listFolders({
    String? id,
    String? path,
    int offset = 0,
    int limit = pageSize,
    AudioLibrary? library,
    String? additional,
    bool? recursive,
    bool? isPersonal,
    String? sortBy,
    bool descending = false,
  }) async {
    final data = await api.call(
      apiFolder,
      'list',
      preferredVersion: negotiate(apiFolder, const [3, 2, 1]),
      params: {
        'additional': additional ?? kSongAdditional,
        'offset': offset,
        'limit': limit,
        if (_notEmpty(id)) 'id': id,
        if (_notEmpty(path)) 'path': path,
        if (library != null) 'library': library.wire,
        if (recursive != null) 'recursive': recursive,
        if (isPersonal != null) 'is_personal': isPersonal,
        if (_notEmpty(sortBy)) ...{
          'sort_by': sortBy,
          'sort_direction': descending ? 'DESC' : 'ASC',
        },
      },
    );
    final raw = data['items'];
    final items = <AudioFolderItemDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map)
            AudioFolderItemDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return AudioFolderPage(
      items: items,
      total: _intOf(data['total'], items.length),
      folderTotal: _intOf(data['folder_total'], 0),
      offset: offset,
      limit: limit,
    );
  }

  // ------------------------------------------------------------ 网络电台

  /// `SYNO.AudioStation.Radio / list`（v2；v1 也有 `list`，用 `[2,1]` 协商）。
  ///
  /// path `AudioStation/radio.cgi`（来自 `SYNO.API.Info`，见 [cgiPaths] 兜底）。
  /// 真机逐字（`docs/audio-api-live.md` §1）：
  /// `{"radios":[{"id":"SHOUTcast","title":"SHOUTcast(TM)","type":"container",
  /// "url":""},{"id":"UserDefined",…}]}` —— **首屏回的是容器，不是电台项**。
  ///
  /// ★★ **容器展开（DA32 的修法）——参数是 `container`，不是 `type`**。
  ///
  /// 权威取证（第 392 轮，官方 Web 前端源码，**离线可复算**）：
  /// `AudioStation-x86_64-7.2.1-6006.spk`（sha256
  /// `89d7e94207508d47bec7ed70541353b1b78ac8eff21fa7da4cc2065d2dc030c4`）
  /// 内的 `app/audio-common.js` 逐字：
  /// ```
  /// api:"SYNO.AudioStation.Radio",method:"list",container:b,offset:f,
  /// library:this._getWindow().getBrowseLibraryType(),text:e
  /// ```
  /// 同一账本另一处逐字（`audio-utils.js`）把 `container` 的**三个根级取值**
  /// 与导航项绑死：`_ShoutCast_ID="SHOUTcast"` / `_Userdefined_ID="UserDefined"`
  /// / `_MyFavorite_ID="Favorite"`；`isInShoutCast()` 逐字判
  /// `container.substr(0,9)==="SHOUTcast"` ⇒ **分类层 id 形如
  /// `SHOUTcast_<genre>`**（分包内 `etc/radio/shoutcast_<genre>.json` 共 **26**
  /// 个，每条 `stations[]` 的字段是 `bitrate/desc/mimetype/name/url`）。
  /// 服务端符号同名互证：`lib/libradio.so` 有 `RadioGetGenres` /
  /// `RadioGetGenreData` / `RadioGetStationData` / `RadioReloadStationArray`
  /// 与字符串 `/shoutcast_`。
  ///
  /// ⚠️ **就地订正**（第 392 轮）：本函数此前的注释与本仓
  /// `docs/stage2-audio-download-api.md` / `docs/station-audio-download-research.md`
  /// 把展开参数写成 `type=player_source_shoutcast|player_source_userdefined|
  /// def_radio_station` —— 那是**本地化文案的 key**（`ajax_handler.cgi` 与
  /// `audio-utils.js` 里都是 `_AST("player","player_source_shoutcast")` 的取值），
  /// **不是请求参数值**。官方前端从不发 `type`。`type`/`keyword` 保留为
  /// **未取证的可选参数**（只在调用方给值时才发），**不得**再当成展开手段。
  ///
  /// 返回 root **`data.radios`**，total **`data.total`**；无参调用回**根级容器**
  /// （真机 `total=3`：`SHOUTcast(TM)` / `User-defined radio` / `My favorite radio`），
  /// `container=SHOUTcast` 回**分类容器**，`container=SHOUTcast_<genre>` 或
  /// `UserDefined` / `Favorite` 回**可播电台项**（`id` 以 `radio_` 开头，
  /// 官方 `isInetRadioItem()` 逐字判 `"radio_"===id.substr(0,6)`）。
  /// ★★ r441（`DA95`，只读取证）：**`list` 没有"关键字过滤"这回事**。
  ///
  /// 修前这里有一个 `keyword` 参数、原样塞进 `Radio.list` 的 `params` —— 而真机
  /// （同一天同一台 NAS，只读探针 `tool/r441_radio_search_probe_test.dart`）读数逐字：
  /// `list` ＋ `keyword=Jazz` / `keyword=rock` / `keyword=news` / `keyword=SHOUTcast`
  /// **四条全部**回 `3 条（`SHOUTcast`/`UserDefined`/`Favorite` 三个根层容器）、
  /// `total=3`、36–43 ms` —— 与**无参**调用逐字相同；换 `text=` 也一样。
  /// 也就是说：**这个参数在服务端被完全忽略**，接上 UI 就是"搜了等于没搜"
  /// （而且不报错、不回落，静默给出"全部容器"当搜索结果）。
  /// ⇒ 参数**删掉**，搜索只走 [searchRadios]；想过滤列表就用容器分层。
  Future<AudioRadioList> listRadios({
    int offset = 0,
    int limit = pageSize,
    String? container,
    String? type,
    AudioLibrary? library,
    String? sortBy,
    bool descending = false,
  }) async {
    final data = await api.call(
      apiRadio,
      'list',
      preferredVersion: negotiate(apiRadio, const [2, 1]),
      params: {
        'offset': offset,
        'limit': limit,
        if (_notEmpty(container)) 'container': container,
        if (_notEmpty(type)) 'type': type,
        if (library != null) 'library': library.wire,
        if (_notEmpty(sortBy)) ...{
          'sort_by': sortBy,
          'sort_direction': descending ? 'DESC' : 'ASC',
        },
      },
    );
    final raw = data['radios'];
    final items = <AudioRadioDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) AudioRadioDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return AudioRadioList(
      items: items,
      total: _intOf(data['total'], items.length),
      offset: offset,
      limit: limit,
    );
  }

  /// `Radio / search`（**v2 才有**）—— SHOUTcast 目录的**关键字搜台**。
  ///
  /// ★★ 权威参数名 = 官方 Web 前端（`docs/stage2-audio-download-api.md` §2.3 第 49 行：
  /// `search`(v2) 只有 `keyword`），r441 用只读探针在真机上**逐条复核**过：
  ///
  /// | 调用 | 真机读数 |
  /// |---|---|
  /// | `search` v1 `keyword=Jazz` | **`103` 方法不存在** ⇒ 必须 v2 |
  /// | `search` v2 **无参** | **`101` 请求无效** ⇒ `keyword` 是**必填** |
  /// | `search` v2 `text=Jazz` | **`101` 请求无效** ⇒ 参数名就是 `keyword`，不是 `text` |
  /// | `search` v2 `keyword=Jazz`（不给 offset/limit） | `radios: []` ＋ **`total=500`** ⇒ **必须显式给 `offset`/`limit`**，否则一条都不回 |
  /// | `search` v2 `keyword=Jazz&offset=0&limit=5` | **5 条 `type=station`**（`id=radio_<title> <url>`、`url` 有值、`desc` 是码率）＋ `total=500` |
  /// | 同一条 ＋ `container=SHOUTcast` | 结果与**不带** `container` 相同、耗时更长（1.4–4.5 s） ⇒ `container` **被忽略**，不发 |
  ///
  /// 字段与 [listRadios] 同一套（root `data.radios` ＋ `total`），所以直接复用
  /// [AudioRadioList]；`total` 是服务端给的**命中总数**（上限 500 = 服务端封顶）。
  ///
  /// ⚠️ 慢：真机 0.8–10.3 s/次（服务端要去问 SHOUTcast 目录），界面必须给加载态
  /// （`AudioPagedBody` 已有）；**不做**自动重试（同 [listRadios] 的口径）。
  Future<AudioRadioList> searchRadios({
    required String keyword,
    int offset = 0,
    int limit = pageSize,
  }) async {
    final data = await api.call(
      apiRadio,
      'search',
      preferredVersion: negotiate(apiRadio, const [2]),
      params: {'keyword': keyword, 'offset': offset, 'limit': limit},
    );
    final raw = data['radios'];
    final items = <AudioRadioDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) AudioRadioDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return AudioRadioList(
      items: items,
      total: _intOf(data['total'], items.length),
      offset: offset,
      limit: limit,
    );
  }

  /// 本服务器是否支持关键字搜台（`Radio.search` 只在 **v2**）。
  ///
  /// ★ 口径与 [hasApi] 一致：能力表**未知**时**不门控**（表缺失 = "不知道"，
  /// 不是"不支持"）—— 否则离线/Mock 场景会被静默判成"这台 NAS 不支持"。
  bool get supportsRadioSearch =>
      api.apiTable == null || supports(apiRadio, 2);

  /// `Radio / add`（v1+）—— 新建网络电台。
  ///
  /// 官方 `RadioEditor.doAddRadio`（反编译 `RadioEditor.java:69-89`）逐字：
  /// `{container, title, url, desc}`；`container` 取值见
  /// [AudioRadioDto.containerUserDefined] / [AudioRadioDto.containerFavorite]
  /// （官方常量 `USERDEFINED="UserDefined"`、`FAVORITE="Favorite"`）。
  Future<void> addRadio({
    required String container,
    required String title,
    required String url,
    String desc = '',
  }) async {
    await api.call(
      apiRadio,
      'add',
      preferredVersion: negotiate(apiRadio, const [2, 1]),
      params: {'container': container, 'title': title, 'url': url, 'desc': desc},
    );
  }

  /// `Radio / updateradios`（v1+）—— **段替换**：用 [radiosJson] 替换
  /// `[offset, offset + limit)` 这一段电台。
  ///
  /// ★★ 权威契约 = 官方 **Web 前端**（`app/audio-common.js`，离线可复算，
  /// SPK `AudioStation-x86_64-7.2.1-6006.spk` sha256
  /// `89d7e94207508d47bec7ed70541353b1b78ac8eff21fa7da4cc2065d2dc030c4`）：
  /// * 改名逐字：`{method:"updateradios", offset:<页偏移+行号>, limit:1,
  ///   radios_json:'[{"title":…,"desc":…,"url":…}]'}`；
  /// * 删除逐字：`{container, offset:<页偏移+首行号>, limit:<末-首+1>,
  ///   radios_json:<该段内**保留下来的**记录>}`；
  /// * 记录里**只有 `title/desc/url`，没有 `id`**。
  ///
  /// ⚠️⚠️ **第 399 轮真机取证（DA46；仪器71 形状对照 + 仪器72）**：
  /// 本函数此前照官方**安卓** `RadioEditor.java:91-107` 发 **`radio_json`**
  /// （含 `id` 的整段列表 + `offset 0 / limit -1`）。在真 NAS 上**只改一处**：
  ///
  /// | 发出的形状 | 回包 | 服务端读数 |
  /// |---|---|---|
  /// | `radio_json` + `offset 0 / limit 1` | `{}`（**不报错**） | 该段被**清空** |
  /// | `radios_json` + 其余逐字相同 | `{}` | 标题**真的改了** |
  /// | App 当时形状：`radio_json` + `0 / -1` + 带 `id` 整段 | `{}` | **整个自定义列表被清空**（`total 2 → 0`） |
  ///
  /// ⇒ 服务端**只认 `radios_json`**；键名不认识时**不报错、直接按"空段"替换**
  /// ⇒ 改名会**静默删掉电台**（数据丢失），而不是给用户一个错误。
  /// 这也解释了为什么"Mock 全绿 + 真机全错"能同时成立：旧用例锁的正是错形状。
  Future<void> updateRadios({
    required String container,
    required List<Map<String, dynamic>> radiosJson,
    int offset = 0,
    int limit = 1,
  }) async {
    await api.call(
      apiRadio,
      'updateradios',
      preferredVersion: negotiate(apiRadio, const [2, 1]),
      params: {
        'container': container,
        'offset': offset,
        'limit': limit,
        'radios_json': jsonEncode(radiosJson),
      },
    );
  }

  // ---------------------------------------------------- RemotePlayer（远程播放器，C4）

  /// `RemotePlayer / list`（v1+）—— NAS 侧发现的远程播放器（DLNA 渲染器等）。
  ///
  /// 事实来源：`weblib/AudioStation/AudioStation.api`
  /// （`SYNO.AudioStation.RemotePlayer`，path `AudioStation/remote_player.cgi`，
  /// v1..3）与官方 APK `ApiRemoteController.java:37-56`。
  /// ★ 根键形状**未取证** ⇒ 防御式取 `players`/`items`/`renderers` 任一存在的数组，
  ///   拿不到就返回空列表（**不臆造**字段）。
  Future<List<Map<String, dynamic>>> listRemotePlayers() async {
    final data = await api.call(
      apiRemotePlayer,
      'list',
      preferredVersion: negotiate(apiRemotePlayer, const [3, 2, 1]),
    );
    for (final key in const ['players', 'items', 'renderers']) {
      final raw = data[key];
      if (raw is List) {
        return [
          for (final e in raw)
            if (e is Map) Map<String, dynamic>.from(e),
        ];
      }
    }
    return const [];
  }

  /// `RemotePlayer / getstatus`（v1+）—— 远程播放器当前状态。
  ///
  /// 官方 `ApiRemoteController.java:320-360` 会**先试 `RemotePlayerStatus`，
  /// 失败再回落到 `RemotePlayer`/`getstatus`**；这里照做（版本 v2→v1）。
  Future<Map<String, dynamic>> getRemoteStatus({String? id}) async {
    final params = <String, dynamic>{if (id != null) 'id': id};
    try {
      final data = await api.call(
        apiRemotePlayerStatus,
        'getstatus',
        preferredVersion: negotiate(apiRemotePlayerStatus, const [2, 1]),
        params: params,
      );
      return data;
    } catch (_) {
      return api.call(
        apiRemotePlayer,
        'getstatus',
        preferredVersion: negotiate(apiRemotePlayer, const [3, 2, 1]),
        params: params,
      );
    }
  }

  /// `RemotePlayer / control`（v1+）—— 官方参数是
  /// `{id, action, [value], [subplayer_id]}`（`ApiRemoteController.java:186-216`）。
  ///
  /// `action` 取值：`play`/`pause`/`stop`/`prev`/`next`/`seek`/
  /// `set_volume`/`set_shuffle`/`set_repeat`（官方常量逐字）。
  Future<void> controlRemote({
    required String id,
    required String action,
    String? value,
    String? subplayerId,
  }) async {
    await api.call(
      apiRemotePlayer,
      'control',
      preferredVersion: negotiate(apiRemotePlayer, const [3, 2, 1]),
      params: {
        'id': id,
        'action': action,
        if (value != null) 'value': value,
        if (subplayerId != null) 'subplayer_id': subplayerId,
      },
    );
  }

  /// `RemotePlayer / updateplaylist`（v1+）—— 改远端队列（**推队列**）。
  ///
  /// ★ **144 轮修正错误假设**：官方 `ApiRemoteController.java:227-281` 的
  /// `control_clearQueue`/`control_removeTracks`/`control_updateTracks`/
  /// `control_enqueue` 全部带 **`updated_index`**（值为新的当前曲序号，清空/
  /// 整段替换用 `-1`），`PLAY_NOW` 还会带 `keep_shuffle_order`（`"false"`）。
  /// 138 轮我只写了 `{id, offset, limit, songs}` —— **漏了 `updated_index`**，
  /// 服务端无法确定新的当前曲目。此处补齐为官方形态。
  Future<void> updateRemotePlaylist({
    required String id,
    required List<String> songIds,
    int offset = 0,
    int limit = -1,
    int updatedIndex = -1,
    bool? keepShuffleOrder,
  }) async {
    await api.call(
      apiRemotePlayer,
      'updateplaylist',
      preferredVersion: negotiate(apiRemotePlayer, const [3, 2, 1]),
      params: {
        'id': id,
        'offset': offset,
        'limit': limit,
        'songs': songIds.join(','),
        'updated_index': updatedIndex,
        if (keepShuffleOrder != null)
          'keep_shuffle_order': keepShuffleOrder ? 'true' : 'false',
      },
    );
  }

  /// `RemotePlayer / setpassword`（v1+）。
  Future<void> setRemotePassword({required String id, required String password}) async {
    await api.call(
      apiRemotePlayer,
      'setpassword',
      preferredVersion: negotiate(apiRemotePlayer, const [3, 2, 1]),
      params: {'id': id, 'password': password},
    );
  }

  // ------------------------------------------------------------ Web Player 队列

  /// `SYNO.AudioStation.WebPlayer / getplaylist`（**v1，无参**）。
  ///
  /// path `AudioStation/web_player.cgi`（来自 `SYNO.API.Info`；静态兜底见 [cgiPaths]）。
  ///
  /// ✅ **2026-09-22 真机取证**（`docs/audio-api-live.md` §6，无参）：
  /// `{"current":0,"mode":"normal","shuffle":0,"songs":[],"timestamp":1789993283,
  /// "total":0}` —— 服务端 Web Player 的**播放队列状态**。
  /// ⚠️ 早先报的 `WebPlayer:get` = `103` 是**方法名猜错**，真名是 **`getplaylist`**。
  ///
  /// 这是**服务端**队列，与本机 `media_playback_store` 的本地队列不同。
  /// `songs` 的记录字段形状未取证（真机为空数组）→ 用 [AudioSongDto] 防御式解析。
  Future<AudioWebPlayerQueueDto> getWebPlayerQueue() async {
    final data = await api.call(
      apiWebPlayer,
      'getplaylist',
      preferredVersion: negotiate(apiWebPlayer, const [1]),
    );
    return AudioWebPlayerQueueDto.fromJson(data);
  }

  // ------------------------------------------------------------ 播放列表

  /// `SYNO.AudioStation.Playlist / list`（v3）。
  ///
  /// 返回 root **`data.playlists`**，total **`data.total`**；
  /// 记录 `id,name,library,type(normal/smart),sharing_status`。
  Future<AudioPlaylistPage> listPlaylists({
    int offset = 0,
    int limit = pageSize,
    AudioLibrary? library,
    String? sortBy,
    bool descending = false,
  }) async {
    final data = await api.call(
      apiPlaylist,
      'list',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {
        'offset': offset,
        'limit': limit,
        if (library != null) 'library': library.wire,
        if (_notEmpty(sortBy)) ...{
          'sort_by': sortBy,
          'sort_direction': descending ? 'DESC' : 'ASC',
        },
      },
    );
    final raw = data['playlists'];
    final items = <AudioPlaylistDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) AudioPlaylistDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return AudioPlaylistPage(
      items: items,
      total: _intOf(data['total'], items.length),
      offset: offset,
      limit: limit,
    );
  }

  /// `SYNO.AudioStation.Playlist / getinfo`（v3）—— 列表详情 + 曲目。
  ///
  /// 参数逐字对齐官方前端：
  /// `{id, additional:"songs_song_tag,songs_song_audio,songs_song_rating,sharing_info"}`。
  /// 返回 root **`data.playlists[0]`**，曲目在 **`additional.songs`**，
  /// 总数在 **`additional.songs_total`**（doc §2.3 A-1c 第 20 行）。
  Future<AudioPlaylistDto?> getPlaylist(
    String id, {
    int songsOffset = 0,
    int songsLimit = pageSize,
  }) async {
    final data = await api.call(
      apiPlaylist,
      'getinfo',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {
        'id': id,
        'offset': 0,
        'limit': 1,
        'songs_offset': songsOffset,
        'songs_limit': songsLimit,
        // 逐字：官方 `changeMetadata`/`prepareGotoNextParam` 的 additional。
        'additional':
            'songs_song_tag,songs_song_audio,songs_song_rating,sharing_info',
      },
    );
    final raw = data['playlists'];
    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return AudioPlaylistDto.fromJson(
        Map<String, dynamic>.from(raw.first as Map),
      );
    }
    return null;
  }

  // ------------------------------------------------------------ 歌词

  // ------------------------------------------------- C6 播放列表**写**操作
  //
  // 参数**逐字**来自官方 APK 反编译（`/tmp/dsaudio_jadx/sources/`）：
  //   * `ApiEnumerator.doCreatePlaylist`（:1069）
  //     → `Playlist/create` + `{name, library, songs}`（`songs` 是 id 串）
  //   * `PlaylistEditor.doRenameNormalPlaylist`（:79）
  //     → `Playlist/rename` + `{id, new_name}`
  //   * `PlaylistEditor` DELETE（:169）→ `Playlist/delete` + `{id}`
  //   * `PlaylistEditor.doUpdatePlaylist`（:222）
  //     → `Playlist/updatesongs` + `{id, offset, limit, songs}`
  //   * `PlaylistEditor` COPYTOLIBRARY（:154）→ `Playlist/copytolibrary` + `{id, library}`
  //   * 智能列表：`updatesmart`（:110）→ `{id, new_name, library, conj_rule, rules_json}`
  //
  // 版本：`create/delete/rename/updatesongs` v1 起；`copytolibrary` v1 起；
  // `updatesmart` 官方传 **maxVersion**（`knownAPI.getMaxVersion()`）。

  /// `Playlist / create`（v1+）—— 新建播放列表（可选带初始曲目）。
  ///
  /// 回包官方取 `data.playlists[0].id`（`ApiCreatePlaylistResponseVo`）。
  /// 返回新列表 id（回包没给就返回空串，调用方按"刷新列表"处理）。
  Future<String> createPlaylist({
    required String name,
    required List<String> songIds,
    AudioLibrary? library,
  }) async {
    final data = await api.call(
      apiPlaylist,
      'create',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {
        'name': name,
        'library': (library ?? AudioLibrary.personal).wire,
        'songs': songIds.join(','),
      },
    );
    return _firstPlaylistId(data);
  }

  /// `Playlist / rename`（v1+）—— 改名（普通列表；智能列表走 [updateSmartPlaylist]）。
  Future<void> renamePlaylist(String id, String newName) async {
    await api.call(
      apiPlaylist,
      'rename',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {'id': id, 'new_name': newName},
    );
  }

  /// `Playlist / delete`（v1+）—— 删除播放列表。
  Future<void> deletePlaylist(String id) async {
    await api.call(
      apiPlaylist,
      'delete',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {'id': id},
    );
  }

  /// `Playlist / updatesongs`（v1+）—— 覆盖式写入曲目。
  Future<void> updatePlaylistSongs({
    required String id,
    required List<String> songIds,
    int offset = 0,
    int limit = -1,
  }) async {
    await api.call(
      apiPlaylist,
      'updatesongs',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {
        'id': id,
        'offset': offset,
        'limit': limit,
        'songs': songIds.join(','),
      },
    );
  }

  /// `Playlist / updatesongs` 的**追加**用法（官方"把歌曲加入播放列表"）。
  ///
  /// 官方 APK `PlaylistEditor.doUpdatePlaylist`（:222）传 `{id, offset, limit, songs}`，
  /// 语义是**段替换**：`offset` 是"这段从第几首开始"。**加歌** = 把 `offset` 放到
  /// **已有曲数**、`limit` 给 `0`。
  ///
  /// ★★★ **r442 真机实测**（`tool/r442_playlist_songs_probe_test.dart`，有界写：
  /// 只动自己建的临时列表，收尾删净、残留 0）：
  ///   * `offset = 已有曲数, limit = 0` ⇒ **追加成功**（1→2、2→3；空表 0→1 也成功）；
  ///   * **一次调用可加多首**（3→5，`songs` 是逗号串）；
  ///   * `offset` 给成"已有 + 5"**越界** ⇒ 服务端**钳到末尾**（仍追加，不报错）；
  ///   * **重复加同一首** ⇒ 服务端拒绝，回 **411**（`AUDIO_ERR_DUPLICATE_SONGS`）；
  ///   * `getinfo` 带 `songs_limit=1` 时 `additional.songs_total` **仍是全量**
  ///     ⇒ 算 `offset` **不必**先拉全部曲目（本方法就靠这一条）。
  ///
  /// ⚠️ `offset` 是**相对这个播放列表**的（仪器74：行号是相对容器的）—— 所以
  /// `id` 必须与"用户看到的那个列表"一致，且**不能用** `Playlist.list` 的
  /// `song_count` 来算（探针里共享库那几条 `song_count=0`，与 `getinfo` 不一致）。
  Future<void> addSongsToPlaylist({
    required String id,
    required List<String> songIds,
  }) async {
    if (id.isEmpty || songIds.isEmpty) return;
    final p = await getPlaylist(id, songsLimit: 1);
    if (p == null) {
      // 列表不存在：与 `describeAudioError` 的 407 同义（别让调用方把 null 当成功）。
      throw DsmApiException(
        DsmErrorCode.audioPlaylistNotExists,
        method: '$apiPlaylist.getinfo',
      );
    }
    // ★ `songs_total` 是权威计数（`song_count` 不可信，见方法注释）。
    final offset = p.songsTotal > 0 ? p.songsTotal : p.songs.length;
    await updatePlaylistSongs(
      id: id,
      songIds: songIds,
      offset: offset,
      limit: 0,
    );
  }

  /// `Playlist / copytolibrary`（v1+）—— 把列表复制到另一个库（个人 ↔ 共享）。
  Future<void> copyPlaylistToLibrary(String id, AudioLibrary library) async {
    await api.call(
      apiPlaylist,
      'copytolibrary',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {'id': id, 'library': library.wire},
    );
  }

  /// `Playlist / createsmart`（v1+）—— 新建智能列表（`rules_json` 是规则数组）。
  Future<String> createSmartPlaylist({
    required String name,
    required String conjunction,
    required List<Map<String, dynamic>> rules,
    AudioLibrary? library,
  }) async {
    final data = await api.call(
      apiPlaylist,
      'createsmart',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {
        'name': name,
        'library': (library ?? AudioLibrary.personal).wire,
        'conj_rule': conjunction,
        'rules_json': jsonEncode(rules),
      },
    );
    return _firstPlaylistId(data);
  }

  /// `Playlist / updatesmart`（v2+，官方传 maxVersion）—— 改智能列表。
  Future<void> updateSmartPlaylist({
    required String id,
    required String newName,
    required String conjunction,
    required List<Map<String, dynamic>> rules,
    AudioLibrary? library,
  }) async {
    await api.call(
      apiPlaylist,
      'updatesmart',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {
        'id': id,
        'new_name': newName,
        'library': (library ?? AudioLibrary.personal).wire,
        'conj_rule': conjunction,
        'rules_json': jsonEncode(rules),
      },
    );
  }

  /// `Playlist / saveplaying`（v2+）—— 把当前播放队列另存为播放列表。
  Future<String> savePlayingQueue({
    required String name,
    required List<String> songIds,
    AudioLibrary? library,
  }) async {
    final data = await api.call(
      apiPlaylist,
      'saveplaying',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {
        'name': name,
        'library': (library ?? AudioLibrary.personal).wire,
        'songs': songIds.join(','),
      },
    );
    return _firstPlaylistId(data);
  }

  /// 从各写方法的回包里取新列表 id（官方 `data.playlists[0].id`）。
  String _firstPlaylistId(Map<String, dynamic> data) {
    final raw = data['playlists'];
    if (raw is List && raw.isNotEmpty) {
      final first = raw.first;
      if (first is Map) return _str(first['id']);
    }
    return _str(data['id']);
  }

  /// `Playlist / getinfo`（v1+，`additional=rules`）—— 取**智能列表**的规则。
  ///
  /// 官方 `PlaylistEditor.getSmartPlaylistRules`（反编译 `PlaylistEditor.java:117`）：
  /// 参数 `{id, additional:"rules", library}`，回包读
  /// `data.playlists[0].additional.{rules_conjunction, rules}`。
  /// ★ 官方 **Android 端没有"创建智能列表"**（全工程 grep 无 `createsmart`），
  /// 只有**改名**：改名时必须把原规则**原样回传**给 `updatesmart`，
  /// 否则规则会丢。这里照做。
  Future<({String conjunction, List<Map<String, dynamic>> rules})?>
  getPlaylistRules({required String id, AudioLibrary? library}) async {
    final data = await api.call(
      apiPlaylist,
      'getinfo',
      preferredVersion: negotiate(apiPlaylist, const [3, 2, 1]),
      params: {
        'id': id,
        'additional': 'rules',
        if (library != null) 'library': library.wire,
      },
    );
    final playlists = data['playlists'];
    if (playlists is! List || playlists.isEmpty) return null;
    final first = playlists.first;
    if (first is! Map) return null;
    final additional = first['additional'];
    if (additional is! Map) return null;
    final conj = '${additional['rules_conjunction'] ?? ''}';
    final rawRules = additional['rules'];
    if (conj.isEmpty || rawRules is! List) return null;
    return (
      conjunction: conj,
      rules: rawRules
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    );
  }

  /// `SYNO.AudioStation.Lyrics / getlyrics`（v2；v1 也可）。
  ///
  /// 官方前端用 **POST** 到 `lyrics.cgi`，参数 `{api, method:"getlyrics", id}`，
  /// 回包取 **`data.lyrics`**（逐字：`testProperty(l,"data.lyrics")`）。
  ///
  /// ✅ **2026-09-22 真机取证**（`docs/audio-api-live.md` §1/§1.2）：
  /// path `AudioStation/lyrics.cgi`、方法名 **`getlyrics`**、参数 **`{id}`** →
  /// `{"data":{"lyrics":"<第一行>\r\n<第二行>\r\n…"}}`（整首歌词）。
  /// ⚠️ **`get` / `list` / `getinfo` 全是 `103`（方法不存在）** —— 不要改用它们。
  /// 没歌词时回空串（不是错误）。
  Future<String> getLyrics(String id) async {
    final data = await api.call(
      apiLyrics,
      'getlyrics',
      preferredVersion: negotiate(apiLyrics, const [versionGetLyrics]),
      params: {'id': id},
    );
    return _str(data['lyrics']);
  }

  /// `SYNO.AudioStation.LyricsSearch / searchlyrics`（v2）—— 联网搜歌词。
  ///
  /// 官方前端参数逐字：`{title, artist, limit:1, additional:"full_lyrics"}`；
  /// 回包同样是 `data.lyrics`（`additional="full_lyrics"` 时才回正文）。
  ///
  /// ⚠️ doc §5 U9 提到 `keyword` 也是 token；本实现按官方前端只发
  /// `title`/`artist`（有逐字证据的那条路径），避免猜。
  Future<String> searchLyrics({
    required String title,
    String? artist,
    int limit = 1,
    AudioLibrary? library,
  }) async {
    final data = await api.call(
      apiLyricsSearch,
      'searchlyrics',
      preferredVersion: negotiate(apiLyricsSearch, const [2, 1]),
      params: {
        'title': title,
        if (_notEmpty(artist)) 'artist': artist,
        'limit': limit,
        'additional': 'full_lyrics',
        if (library != null) 'library': library.wire,
      },
    );
    return _str(data['lyrics']);
  }

  // ------------------------------------------------------------ 评分 / 收藏

  /// `SYNO.AudioStation.Song / setrating`（**v2**）—— 评分（0–5）。
  ///
  /// 官方前端逐字：`Ext.Ajax.request({method:"POST", url:"song.cgi",
  /// params:{api, method:"setrating", id:a.join(","), rating:b}})` ——
  /// **`id` 是逗号串**（可一次设多首），`rating=0` 表示清除评分。
  Future<void> setRating(List<String> ids, int rating) async {
    if (ids.isEmpty) return;
    await api.call(
      apiSong,
      'setrating',
      preferredVersion: negotiate(apiSong, const [versionSetRating]),
      params: {'id': ids.join(','), 'rating': rating.clamp(0, 5)},
    );
  }

  /// `SYNO.AudioStation.Pin / list`（v1）—— 收藏（"我的锁定"）。
  ///
  /// 官方 `JsonStore` 的 `baseParams:{offset:0,limit:-1}`、root `items`、
  /// total `total`（逐字）。
  Future<List<AudioPinDto>> listPins() async {
    final data = await api.call(
      apiPin,
      'list',
      preferredVersion: negotiate(apiPin, const [1]),
      params: {'offset': 0, 'limit': pinFetchAllLimit},
    );
    final raw = data['items'] ?? data['pins'];
    return [
      if (raw is List)
        for (final e in raw)
          if (e is Map) AudioPinDto.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// `SYNO.AudioStation.Pin / pin`（v1）—— 收藏。
  ///
  /// 官方逐字：`params:{items:a}`，`a` 是 `[{type, criteria, name}, …]`。
  /// `criteria` 的结构由 `getPinArgumentsFromRecord` 动态拼（doc §5 U13），
  /// 本实现原样透传调用方给的结构，不做解释。
  Future<void> addPins(List<AudioPinRequest> items) async {
    if (items.isEmpty) return;
    await api.call(
      apiPin,
      'pin',
      preferredVersion: negotiate(apiPin, const [1]),
      params: {
        'items': jsonEncode([for (final i in items) i.toJson()]),
      },
    );
  }

  /// `SYNO.AudioStation.Pin / unpin`（v1）—— 取消收藏。
  ///
  /// ⚠️ **与文档的一处偏差（以包内 JS 为准）**：doc §2.3 第 42 行写的是参数
  /// `id`；包内官方前端 `sendUnpinRequest` 逐字是
  /// `SYNO.API.Request({api:"SYNO.AudioStation.Pin",method:"unpin",version:"1",
  /// params:{items:a}})`，`a` 是 **id 数组**。本实现发 `items`（JSON 数组）。
  Future<void> removePins(List<String> ids) async {
    if (ids.isEmpty) return;
    await api.call(
      apiPin,
      'unpin',
      preferredVersion: negotiate(apiPin, const [1]),
      params: {'items': jsonEncode(ids)},
    );
  }

  /// `SYNO.AudioStation.Pin / rename`（v1）。
  Future<void> renamePin(String id, String name) async {
    await api.call(
      apiPin,
      'rename',
      preferredVersion: negotiate(apiPin, const [1]),
      params: {'id': id, 'name': name},
    );
  }

  /// `SYNO.AudioStation.Pin / reorder`（v1）—— 拖动排序。
  ///
  /// ★★★ 2026-10-14（r398）**真机定案：载荷是 id 数组，不是"记录数组"**。
  /// 修前这个动作**在真机上必定失败**（服务端 `117`），三档证据：
  ///   * 官方安卓客户端 `DSaudio.apk` → `ApiEnumerator.reorder` 逐字：
  ///     `items = Gson(idList)`（`List<String>`）、`offset = 0`、`limit = -1`；
  ///   * 现场实测（本 NAS，两条本轮自建收藏）：
  ///     `[{type,criteria,name}]` → **117**；带 `id` 的记录 → **117**；
  ///     id 数组**但缺** `offset/limit` → **1005**；id 数组 + `offset/limit`
  ///     → **`{}`**，且 `Pin.list` 次序**真的翻转**（`[1,2] → [2,1]`）；
  ///   * `docs/stage2-audio-download-api.md` §2.3 第 271 行"`items`（重排后的
  ///     记录数组）"是**错的**（只抄了 Web 前端的字段名）⇒ 已就地订正。
  Future<void> reorderPins(List<String> ids) async {
    if (ids.isEmpty) return;
    await api.call(
      apiPin,
      'reorder',
      preferredVersion: negotiate(apiPin, const [1]),
      params: {
        'items': jsonEncode(ids),
        'offset': 0,
        'limit': pinFetchAllLimit,
      },
    );
  }

  // ------------------------------------------------- 在线标签（Tag，A19）

  /// `SYNO.AudioStation.Tag / list`（**v1**）—— 在线标签查询（Discogs 代理）。
  ///
  /// ✅ **2026-09-22 真机取证 + 二进制反汇编定案参数**（本批）：
  /// 必需参数是 **`album` + `album_artist`**（Tag.so 的 `TagHandler::List`
  /// 依次 `hasParam("album")`、`hasParam("album_artist")`，缺任一 → `101`；
  /// 只传其一会一直 101，此前判"参数未完全定案"即因漏了 `album_artist`）。
  ///
  /// 真机请求（GET `entry.cgi`，只读）：
  /// `?api=SYNO.AudioStation.Tag&version=1&method=list&album=Best+In+Me&album_artist=My+Love&_sid=…`
  /// 真机响应（原文节选）：
  /// `{"data":{"items":[{"album":"You're The Best Thing In My Life…",
  /// "album_artist":"Frederick Knight","cover":"https://i.discogs.com/…",
  /// "genre":["Funk / Soul"],"release_url":"https://api.discogs.com/releases/4476561",
  /// "year":"1982"}],"total":…},"success":true}`
  ///
  /// ⚠️ `year` 服务端给的是**字符串**（`"1982"`），这里保持字符串不转数字
  /// （转错了就是把"未知年份"编成假年份）。
  Future<AudioTagSearchResult> tagList({
    required String album,
    required String albumArtist,
  }) async {
    final data = await api.call(
      apiTag,
      'list',
      preferredVersion: negotiate(apiTag, const [1]),
      params: {'album': album, 'album_artist': albumArtist},
    );
    return AudioTagSearchResult.fromJson(data);
  }

  /// `SYNO.AudioStation.Tag / getinfo`（**v1**）—— 单条在线标签详情。
  ///
  /// 参数同样是 **必需 `type` + `id`**（`Tag.so` 的 `TagHandler::GetInfo`
  /// 先 `hasParam("type")`）。但本机（DSM 7.2.1 / AS 7.2.1-6006）对任意
  /// `type`/`id` 组合都回 **`1100`**（业务错；`list` 能通说明网络与 Discogs
  /// 代理是活的）→ **`getinfo` 的 `id` 语义未定案**，故只作为接口保留、
  /// 不接 UI，也不谎称可用。
  Future<AudioTagDetail?> tagInfo({
    required String type,
    required String id,
  }) async {
    try {
      final data = await api.call(
        apiTag,
        'getinfo',
        preferredVersion: negotiate(apiTag, const [1]),
        params: {'type': type, 'id': id},
      );
      return AudioTagDetail.fromJson(data);
    } on DsmApiException {
      // `1100` 等业务错 → 如实"查不到"，不是崩溃。
      return null;
    }
  }

  // ------------------------------------------------- 分享（D4）

  /// `SYNO.AudioStation.Song / getsharing`（**v2**，v1 没有）。
  ///
  /// 只读。真机（本批）对本曲库任意 `id` 回 **`405`** —— 与本机
  /// `Info.getinfo.privilege.sharing=false` 一致（服务端拒绝，不是参数错）。
  /// 响应形状仍按 doc §2.3 A-2 第 38 行取 `enable_sharing` + `url` 两份。
  Future<AudioSharingInfo?> getSharing(String id) async {
    try {
      final data = await api.call(
        apiSong,
        'getsharing',
        // 分享是 **v2** 引入的；不要往上要 v3（v3 的方法面未必还是这个）。
        preferredVersion: negotiate(apiSong, const [versionSharing]),
        params: {'id': id},
      );
      return AudioSharingInfo.fromJson(data);
    } on DsmApiException {
      // `405`（未开启共享 / 无权限）→ null，界面给"服务端未开启"空态。
      return null;
    }
  }

  /// `SYNO.AudioStation.Song / setsharing`（**v2**）—— 生成/关闭分享链接。
  ///
  /// ⚠️ **写操作**：受 `privilege.sharing` 门控；本机该位为 false（真机 405）。
  /// 本批**未对真机调用**（合规：含 `set` 变更动词），只在离线用例里断言请求形态。
  Future<void> setSharing(String id, {required bool enable}) async {
    await api.call(
      apiSong,
      'setsharing',
      preferredVersion: negotiate(apiSong, const [versionSharing]),
      params: {'id': id, 'enable_sharing': enable},
    );
  }

  // ------------------------------------------------- 打包下载（D2）

  /// `SYNO.AudioStation.Download / download`（**v1**）的直链。
  ///
  /// doc §2.3 A-2 第 48 行：`audio_enable_download` 必须开。
  /// 真机（本批）`settings.enable_download=false`，且
  /// `GET download.cgi?api=…&method=download&version=1&id=<song>` 回
  /// **`{"success": true}`（17 字节，无 zip 载荷）** —— 服务端把请求当成功但
  /// **不产出任何字节**（对照：不带 `id` 回 `101`）。所以这里只生成 URL，
  /// 由调用方按能力位决定要不要下载。
  String downloadUrl(List<String> ids, {DateTime? now}) {
    final params = <String, String>{
      ..._authParams(),
      'api': apiDownload,
      'version': '1',
      'method': 'download',
      'id': ids.join(','),
      '_dc': '${(now ?? DateTime.now()).millisecondsSinceEpoch}',
    };
    return '${_webapiUrl(apiDownload)}?${_query(params)}';
  }

  /// 真正取打包字节（走 `DsmWebApi.getBytes`，与封面/缩略图同一条只读通道）。
  ///
  /// ⚠️ 不判断内容是否为桩 —— 由离线层用 `looksLikeServerStub` 判，
  /// 数据层只负责"把服务端给的东西拿回来"。
  Future<List<int>> downloadBytes(List<String> ids, {DateTime? now}) =>
      api.getBytes(downloadUrl(ids, now: now));

  // ------------------------------------------------- 流式播放 / 封面（URL）

  /// **流式播放 URL**，逐字对齐**官方安卓客户端**
  /// `ApiEnumerator.getPlayUrl`（APK `ApiEnumerator.java:710-795`，
  /// 见 `docs/audio-parity-audit.md` §1.6）：
  ///
  /// ```
  /// {webapi}/AudioStation/stream.cgi/0.<ext>?_sid=<sid>&api=SYNO.AudioStation.Stream
  ///   &version=1&method=stream&id=<songId>&_dc=<ts>
  /// {webapi}/AudioStation/stream.cgi/0.mp3?...&method=transcode&id=…&format=mp3
  ///   &bitrate=<128000|192000|320000>&_dc=<ts>
  /// {webapi}/AudioStation/stream.cgi/0.wav?...&method=transcode&id=…&format=wav&_dc=<ts>
  /// ```
  ///
  /// * 路径里的 `/<0>.<ext>` path-info 决定返回 MIME（官方用
  ///   `getFileExtensionName(path)` 推导；转码时扩展名换成 `mp3`/`wav`）；
  /// * **鉴权必须用查询参数 `_sid=`，不是 `sid=`** —— 2026-09-21 真机只读实测
  ///   （审计 §1.6）：`stream.cgi?…&sid=<sid>` → `{"error":{"code":105}}`；
  ///   `…&_sid=<sid>` → HTTP 206 + `audio/x-ms-wma` / `audio/mpeg`。
  ///   官方 Web 前端（`audio-core.js` 的 `st()`）用 `sid=` 能工作，是因为浏览器里
  ///   还带 DSM 会话 cookie；**本 App 没有 cookie**，只能走官方客户端的 `_sid=`。
  /// * `version=1`（[versionStream]）：官方客户端逐字如此；
  /// * `bitrate` **只在服务端转码且目标为 mp3 时发**，且只认官方三档
  ///   （[kTranscodeBitrates]）。直传发的是原文件、`format=wav` 是无损容器，
  ///   官方两条路径都不带 `bitrate`；**非法档位一律不发**。
  /// * `position`（秒）**只表示"按偏移取流"**：官方普通播放不发它
  ///   （只在 Chromecast 时发 `position=0`，审计 §1.7 结论 4），
  ///   所以 `position<=0` 时省略。客户端拖进度条用播放器自身的 HTTP Range
  ///   定位，真机已证转码流也吃 Range（审计 §1.7 末段）。
  /// * `_dc=<ts>` 是官方防缓存时间戳。
  ///
  /// [mode] 为 [AudioStreamMode.direct] 时走 `method=stream`（HTTP Range 直传）；
  /// 否则走 `method=transcode`。
  String streamUrl(
    AudioSongDto song, {
    AudioStreamMode mode = AudioStreamMode.direct,
    int position = 0,
    int? bitrate,
    DateTime? now,
  }) {
    final originalExt = fileExtension(song.path);
    final ext = switch (mode) {
      AudioStreamMode.direct => originalExt.isEmpty ? 'mp3' : originalExt,
      AudioStreamMode.mp3 => 'mp3',
      AudioStreamMode.wav => 'wav',
    };
    final transcode = mode != AudioStreamMode.direct;
    final params = <String, String>{
      ..._authParams(),
      'api': apiStream,
      'version': '$versionStream',
      'method': transcode ? 'transcode' : 'stream',
      'id': song.id,
      if (transcode) 'format': mode == AudioStreamMode.mp3 ? 'mp3' : 'wav',
      if (transcode &&
          mode == AudioStreamMode.mp3 &&
          isValidTranscodeBitrate(bitrate))
        'bitrate': '$bitrate',
      if (position > 0) 'position': '$position',
      '_dc': '${(now ?? DateTime.now()).millisecondsSinceEpoch}',
    };
    return '${_webapiUrl(apiStream)}/0.$ext?${_query(params)}';
  }

  /// 专辑封面（`Cover.getcover` v3）。
  ///
  /// 参数逐字对齐官方 `getCgiImgMapping`（`export_AudioStation/app/audio-utils.js`，
  /// 见 `docs/audio-api-live.md` §1.1）：
  /// `output_default=true` + `is_hr`（`0`/`1`）+ `view` + 维度键
  /// （`album_name` + `album_artist_name`）。
  ///
  /// ⚠️ **必需 `album_name` + `album_artist_name` + `view`；用 `id` 会 404**
  /// （2026-09-22 真机用 `{id}`/`{id,size}`/三种版本全 404）。
  /// `album_artist_name` **即使为空也要在场**（官方模板 `{3}` 恒拼进去，
  /// 缺参会让服务端拿不到专辑身份），所以这里不再按空串省略。
  ///
  /// ⚠️ **本机实测（r427 复核，12 张专辑逐条，`docs/evidence-r427/`）**：
  /// * **有真封面**：`200` + 真 JPEG（如「示例专辑」**49,719 B**、
  ///   「99情人」**29,123 B**）—— 2/12 张；
  /// * **没封面**：`404` + **11,939 B HTML 正文**（不是空、也不是图）——
  ///   10/12 张。所以这里默认**不发** `output_default`：**不**把通用占位图
  ///   （`output_default=true` 时 8 张专辑逐字节相同的 7,101 B PNG，
  ///   `docs/thumbnail-apis.md` §1.7）冒充成专辑封面。
  /// * 旧注释写的"恒为占位图 / 无封面时 404 是因为…"两处已过时：
  ///   `output_default=false` **能**拿到真封面；404 的正文是 HTML
  ///   （端侧靠 `AuthedImage` 的 `errorBuilder`/空字节兜底，见下）。
  ///
  /// ★ 要做到"没专辑封面的专辑也能显示真封面"，路线是取该专辑**任一有内嵌
  /// 封面的歌曲 id** 走 [songCoverUrl]；但服务端不提供"这首歌有没有封面"的
  /// 字段（`kSongAdditional` 里没有），只能逐首探 `getsongcover`：
  /// r427 实测每张专辑 = **1 次 `Song:list` + 最多 30 次 `getsongcover`**，
  /// 命中在第 1 首（4/12 张能受益，**全部第 1 首命中**，≈175–242 ms），
  /// 全无封面时最坏 **1.1–1.4 s / 30 次请求**。
  ///
  /// ★ **r439 已落地**（用户当轮拍板"改成逐首探"）：专辑封面走
  /// `AlbumCoverResolver`（`features/audio/audio_album_cover.dart`）——
  /// **有界**（`maxSongs` 默认 **1**：r427 的 4/4 命中都在第 1 首，纵深探到
  /// 24–30 首在实测里**收益为 0**）＋ **会话级缓存含否定结论**（滚动回同一张
  /// 专辑零请求）⇒ 列表页逐行探测的代价从"最坏 30 次/张"降到 **1 次/张**。
  /// 界面侧只在**专辑级取图失败之后**才触发（`AudioCoverImage.resolveFallback`），
  /// 且**不重复探专辑级**（`albumAlreadyTried`）。
  ///
  /// ⚠️ **DA86（r427）**：这两个 URL 方法本身没问题，但**封面图在 r427 之前
  /// 真机上一张都显示不出来** —— 界面侧用的是 `Image.network`，而设备按 **IP**
  /// 连 NAS、证书 SAN 只覆盖 `*.nas.example.com` ⇒ 主机名不匹配 ⇒ 握手
  /// 失败 ⇒ 静默退图标。现改走 `api.getBytes` + `Image.memory`。
  String albumCoverUrl(
    String albumName, {
    String albumArtist = '',
    String view = AudioCoverView.normal,
    bool hiRes = true,
    bool outputDefault = false,
    DateTime? now,
  }) => _coverUrl(
    {
      'method': 'getcover',
      'view': view,
      'album_name': albumName,
      'album_artist_name': albumArtist,
    },
    hiRes: hiRes,
    outputDefault: outputDefault,
    now: now,
  );

  /// 艺术家封面（`Cover.getcover` v3，`artist_name`）。
  String artistCoverUrl(
    String artistName, {
    String view = AudioCoverView.normal,
    bool hiRes = true,
    bool outputDefault = false,
    DateTime? now,
  }) => _coverUrl(
    {'method': 'getcover', 'view': view, 'artist_name': artistName},
    hiRes: hiRes,
    outputDefault: outputDefault,
    now: now,
  );

  /// 流派封面（`Cover.getcover` v3，`genre_name`）。
  ///
  /// 真机实测流派 `getcover` **可能**回真封面（`genre_name=Pop` → 与某首歌的
  /// 内嵌封面同字节，`docs/thumbnail-apis.md` §1.7）⇒ 保留该方法；
  /// 默认不发 `output_default`，没有时 404 → 界面回退图标。
  String genreCoverUrl(
    String genreName, {
    String view = AudioCoverView.normal,
    bool hiRes = true,
    bool outputDefault = false,
    DateTime? now,
  }) => _coverUrl(
    {'method': 'getcover', 'view': view, 'genre_name': genreName},
    hiRes: hiRes,
    outputDefault: outputDefault,
    now: now,
  );

  /// 作曲家封面（`Cover.getcover` v3，`composer_name`）。
  ///
  /// 逐字来自官方 `getCgiImgMapping`（`export_AudioStation/app/audio-utils.js`）：
  /// `case"composer": … return b+"&method=getcover&view={1}&composer_name={2}"`。
  /// 与 album/artist/genre 同构（都用 `getcover`，**不是** `getsongcover`）。
  String composerCoverUrl(
    String composerName, {
    String view = AudioCoverView.normal,
    bool hiRes = true,
    bool outputDefault = false,
    DateTime? now,
  }) => _coverUrl(
    {'method': 'getcover', 'view': view, 'composer_name': composerName},
    hiRes: hiRes,
    outputDefault: outputDefault,
    now: now,
  );

  /// 歌曲封面（`Cover.getsongcover` v3，`id`）。
  ///
  /// **唯一可靠的真封面来源**（文件内嵌图）：真机 `id=music_28045` →
  /// 200 `image/jpeg` 55253B。默认不发 `output_default` ⇒ 无内嵌封面时
  /// **404**（而不是 200 占位 PNG）→ UI 明确画"无封面"。
  String songCoverUrl(
    String id, {
    String view = AudioCoverView.normal,
    bool hiRes = true,
    bool outputDefault = false,
    DateTime? now,
  }) => _coverUrl(
    {'method': 'getsongcover', 'view': view, 'id': id},
    hiRes: hiRes,
    outputDefault: outputDefault,
    now: now,
  );

  /// 文件夹封面（`Cover.getfoldercover` v3，`id`）。
  ///
  /// 真机 `getfoldercover id=music_28045` → 404（`docs/thumbnail-apis.md` §1.7
  /// 末行）⇒ 本机拿不到文件夹封面；默认不发 `output_default`，
  /// 失败由 UI 回退图标。保留方法以对齐官方 `.api` 的方法表。
  String folderCoverUrl(
    String id, {
    String view = AudioCoverView.normal,
    bool hiRes = true,
    bool outputDefault = false,
    DateTime? now,
  }) => _coverUrl(
    {'method': 'getfoldercover', 'view': view, 'id': id},
    hiRes: hiRes,
    outputDefault: outputDefault,
    now: now,
  );

  /// 封面 URL 的公共拼装。
  ///
  /// ⚠️ **鉴权是 `_sid=`，不是 `sid=`** —— 真机只读实测（审计 §1.6）：
  /// `cover.cgi?method=getsongcover&sid=<sid>` → HTTP 200 但
  /// `{"error":{"code":105}}`；`…&_sid=<sid>` → HTTP 200 `image/jpeg` 55253 B。
  /// 封面通道与流式通道同一条规矩。
  ///
  /// ⚠️ **默认不发 `output_default`**（旧实现恒发 `output_default=true`）。
  /// 真机取证（`docs/thumbnail-apis.md` §1.7）：
  ///   * 无封面 + `output_default=true` → 200 **固定占位 PNG**（4815B，四首不同
  ///     专辑与不存在 id 的字节完全相同）⇒ "没封面"与"有封面"在 UI 上不可分；
  ///   * 无封面 + **不发** `output_default` → **404**（HTML）⇒ `Image.network`
  ///     的 `errorBuilder` 回退成本地图标，这才是诚实的"无封面"。
  /// 需要占位图时才显式 `outputDefault: true`。
  ///
  /// ⚠️ **这条通道返回的是二进制图片，不是 JSON** —— 2026-09-22 真机
  /// `Cover:getcover` → `HTTP 200`、`Content-Type: image/jpeg`、
  /// 字节头 `\xff\xd8\xff\xe0…JFIF`（`docs/audio-api-live.md` §1/§1.1）。
  /// 因此只产出 URL，消费方走图片/字节通道（`AudioCoverImage` 用 `Image.network`），
  /// **绝不**把它塞进 `DsmWebApi.call` 的 JSON 解析路径。
  String _coverUrl(
    Map<String, String> extra, {
    required bool hiRes,
    bool outputDefault = false,
    DateTime? now,
  }) {
    final params = <String, String>{
      ..._authParams(),
      'api': apiCover,
      if (outputDefault) 'output_default': 'true',
      'is_hr': hiRes ? '1' : '0',
      'version': '${negotiate(apiCover, const [3, 2, 1])}',
      '_dc': '${(now ?? DateTime.now()).millisecondsSinceEpoch}',
      ...extra,
    };
    return '${_webapiUrl(apiCover)}?${_query(params)}';
  }

  /// `SYNO.AudioStation.Stream` 的默认形态（官方
  /// `getStreamingPlayTypeByRecord` / `getStreamingPlayTypeByExt` 的**客户端**版）。
  ///
  /// 官方按浏览器能力（`soundManager.canPlayURL('.wma')` 等）逐扩展名判"直放还是
  /// 转码"（`audio-utils.js` 的 `createStreamingModeSupportList`：能放 → `direct`；
  /// 不能放且 `transcode_to_mp3` 为真 → `mp3`，否则 → `wav`）。客户端的
  /// "能不能放"就是 `media_format_support.dart` 的**应用级能力登记** ——
  /// 正是 `mediaFormatNeedsFallback`。
  ///
  /// ★ 本批修的根因：**`wma` 原先被写进下面的 `directPlayable` 集合** → 音乐库里
  /// 的 WMA 走 `method=stream` 直传 → Media3 1.9.2 没有 ASF 抽取器 → 起播即失败
  /// （用户报告「wma 这种音频格式不支持」）。现在它由登记判成"需要替代路径"，
  /// 自动改走 `method=transcode`（官方正视路径，参数见 [streamUrl]）。
  ///
  /// [probe] 是 fail-open 的唯一升级口：探针说这台设备**端到端**能播 WMA 时，
  /// 直接按官方 `canPlayURL` 语义走直传（见 `media_format_support.dart` 的契约）。
  static AudioStreamMode defaultStreamMode(
    AudioSongDto song, {
    AudioInfoDto? info,
    MediaCodecProbe? probe,
  }) {
    final ext = fileExtension(song.path).toLowerCase();
    // ① 命中**已知格式缺口**登记（WMA/ASF、APE、WavPack、DSD、RM、MIDI…）：
    //    默认走服务端转码；**只有**探针证实"这个设备的本 App 播放栈端到端能播"
    //    才改回直传（fail-open 契约，见 media_format_support.dart）。
    //    ⚠️ 这里必须**显式**给 direct —— 这些扩展名不在下面的 `directPlayable`
    //    集合里，若只判断转码就会把探针的 `true` 又吞掉。
    if (mediaFormatGapOf(song.path) != null) {
      return mediaFormatNeedsFallback(song.path, probe: probe)
          ? _transcodeMode(info)
          : AudioStreamMode.direct;
    }
    // ② DSD 的**双保险**（登记里已有 dsf/dff；官方 `POWER_DECODE_LIST` 逐字含它们。
    //    登记一旦被改动，这一条仍保证"D​SD 永远转码"）
    if (ext == 'dsf' || ext == 'dff') return _transcodeMode(info);
    // ③ 其余"已知能直放"的集合（**不含 `wma`** —— 见上）
    const directPlayable = {
      'mp1', 'mp2', 'mp3', 'mpa', 'm4a', 'm4b', 'm4p', 'aac', //
      'ogg', 'wav', 'flac', 'aiff', 'aif',
    };
    if (directPlayable.contains(ext)) return AudioStreamMode.direct;
    // ④ 既不在直放集合、也不在缺口登记里（例如 `mka`/`amr`/`.opus`/未知扩展名）：
    //    与改动前一致，保守走转码；官方也是"只对 TRANSCODE_TYPE_LIST 里的扩展名
    //    逐个问浏览器能力"，不在表里的本来就没有直传形态。
    return _transcodeMode(info);
  }

  /// 这次播放是不是**走服务端转码**（界面据此给"已改用服务端转码"的提示）。
  static bool usesServerTranscode(AudioStreamMode mode) =>
      mode != AudioStreamMode.direct;

  static AudioStreamMode _transcodeMode(AudioInfoDto? info) =>
      (info?.transcodeToMp3 ?? false)
      ? AudioStreamMode.mp3
      : AudioStreamMode.wav;

  /// 路径里的扩展名（官方 `getFileExtensionName` 同规则：`.*\.(.+)$`）。
  static String fileExtension(String path) {
    final clean = path.split('?').first;
    final dot = clean.lastIndexOf('.');
    final slash = clean.lastIndexOf('/');
    if (dot <= slash || dot < 0) return '';
    return clean.substring(dot + 1);
  }

  String get _sid => api.session?.sid ?? '';

  /// 这个会话的 DSM CSRF 令牌是否可用（`SynoToken`）。
  ///
  /// 与 `DsmWebApi.hasSynoToken` 同一口径：有令牌就**必须**出现在**查询串**里。
  bool get hasSynoToken => api.hasSynoToken;

  /// 交给原生播放器/下载器的**会话鉴权查询串参数**：`_sid` **和** `SynoToken`。
  ///
  /// ★★★ 第 274 轮真机缺陷（用户报「Audio Station 播放音频一直是失败的」的根因）
  /// ════════════════════════════════════════════════════════════════════════
  /// 这些 URL 是**直接交给原生播放器**的（`just_audio` → Android
  /// Media3/ExoPlayer，见 `features/audio/audio_player.dart`）。原生组件
  /// **发不了自定义请求头**，所以 DSM 7.4 的 CSRF 令牌 `SynoToken` 只能进
  /// **查询串**。只带 `_sid` 时服务端回的是：
  ///
  /// ```
  /// HTTP/1.1 200 OK
  /// Content-Type: text/plain; charset="UTF-8"
  ///
  /// {"error":{"code":105},"success":false}
  /// ```
  ///
  /// —— **HTTP 200 + JSON**，Media3 嗅探这段 JSON 必然失败，抛的是
  /// `None of the available extractors (…) could read the stream`
  /// （`UnrecognizedInputFormatException`），真机上看起来像"容器/编码不支持"，
  /// 其实是**取流鉴权没过**。
  ///
  /// 真机 A/B（Honor LGE-AN10 / DSM 7.4.1 / 同一个 App 进程 / 同一个 just_audio，
  /// 2026-09-26 第 274 轮）：
  ///   * 文件页 `/home/Music/CD1 - 01 - Track01.mp3`（FileStation 下载腿，
  ///     URL 由 `DsmWebApi.authenticatedUrl` 拼，`_sid` + `SynoToken` 都在查询串）
  ///     → **正常播放**：`ExoPlayerImpl: Init` → `MediaCodec::start()` →
  ///     `AudioTrack … state:started`；
  ///   * 音频站同一批 mp3（本函数拼的 `stream.cgi` URL，**只有 `_sid`**）
  ///     → `E ExoPlayerImplInternal: Caused by: … None of the available extractors
  ///     (sg1, nl0, …) could read the stream. {contentIsMalformed=false, dataType=1}`。
  ///
  /// 结论：这不是 TLS、不是解码器、也不是会话失效 —— 是**这一条取流腿漏了
  /// CSRF 令牌**。本仓的 FileStation / Drive / Photos 取流腿都从
  /// `DsmWebApi.authenticatedUrl` 拼（还带 `requireSynoToken` 前置自检），
  /// 只有 Audio Station 这一条腿是手拼的、漏了令牌，所以出现"同一台 NAS、
  /// 同一个播放器，文件页能播、音频站不能播"。
  Map<String, String> _authParams() => <String, String>{
    if (_sid.isNotEmpty) '_sid': _sid,
    if (hasSynoToken) 'SynoToken': api.transport.synoToken!,
  };

  /// 当前 DSM 会话 id（无会话时为空串）。
  ///
  /// 暴露它是为了让**界面层**能把它并进 URL 缓存键：流式/封面 URL 都带
  /// `_sid=`，换个会话后同一条曲目的 URL 必须失效，否则缓存键一样、
  /// URL 却还是旧会话的（连点两次会拿 105）。数据层内部拼 URL 仍走 [_sid]。
  String get sid => _sid;

  /// 完整 URL：`{base}webapi/{cgiPath}`（`baseUrl` 末尾带 `/`）。
  String _webapiUrl(String apiName) {
    final base = api.baseUrl.endsWith('/')
        ? api.baseUrl.substring(0, api.baseUrl.length - 1)
        : api.baseUrl;
    return '$base/webapi/${cgiPath(apiName)}';
  }

  static String _query(Map<String, String> params) => params.entries
      .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  // ------------------------------------------------------------------ 工具

  AudioSongPage _songsOf(
    Map<String, dynamic> data, {
    required int offset,
    required int limit,
  }) {
    final raw = data['songs'];
    final items = <AudioSongDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) AudioSongDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return AudioSongPage(
      items: items,
      total: _intOf(data['total'], items.length),
      offset: offset,
      limit: limit,
    );
  }

  static AudioNamedPage<T> _namedPageOf<T>(
    Map<String, dynamic> data,
    String root,
    T Function(Map<String, dynamic>) fromJson, {
    required int offset,
    required int limit,
  }) {
    final raw = data[root];
    final items = <T>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) fromJson(Map<String, dynamic>.from(e)),
    ];
    return AudioNamedPage<T>(
      items: items,
      total: _intOf(data['total'], items.length),
      offset: offset,
      limit: limit,
    );
  }
}

/// `Pin.pin` / `Pin.reorder` 的一条记录（官方 `{type, criteria, name}`）。
class AudioPinRequest {
  const AudioPinRequest({
    required this.type,
    required this.criteria,
    this.name = '',
  });

  /// `folder` / `album` / `artist` / `composer` / `genre` / `playlist` /
  /// `random_100` / `recently_added`（`getPinArgumentsFromRecord` 的值域）。
  final String type;

  /// 对应服务端 `criteria` 对象（如 `{album, album_artist}` / `{folder}` …）。
  final Map<String, dynamic> criteria;
  final String name;

  Map<String, dynamic> toJson() => {
    'type': type,
    'criteria': criteria,
    'name': name,
  };
}

/// `SYNO.AudioStation.Search / list` 的分类聚合结果（root `data`）。
///
/// 每个分类都是**可选**的：服务端只回有命中的分类（官方前端逐类判空）。
class AudioGlobalSearchResult {
  const AudioGlobalSearchResult({
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.composers = const [],
    this.genres = const [],
    this.songsTotal = 0,
    this.albumsTotal = 0,
    this.artistsTotal = 0,
    this.composersTotal = 0,
    this.genresTotal = 0,
  });

  final List<AudioSongDto> songs;
  final List<AudioAlbumDto> albums;
  final List<AudioNameDto> artists;
  final List<AudioNameDto> composers;
  final List<AudioNameDto> genres;

  /// 各分类的服务端总量（真机键名是 `albumTotal` / `songsTotal` …，
  /// **不是**单一的 `total` —— `docs/audio-api-live.md` §1 逐字：
  /// `{"albumTotal":1210,"albums":[…],…}`）。
  ///
  /// 缺失时回落到本次收到的条数（防御式；服务端没给就不撒谎说"还有更多"）。
  final int songsTotal;
  final int albumsTotal;
  final int artistsTotal;
  final int composersTotal;
  final int genresTotal;

  bool get isEmpty =>
      songs.isEmpty &&
      albums.isEmpty &&
      artists.isEmpty &&
      composers.isEmpty &&
      genres.isEmpty;

  factory AudioGlobalSearchResult.fromJson(Map<String, dynamic> data) {
    List<T> parse<T>(Object? raw, T Function(Map<String, dynamic>) fromJson) =>
        [
          if (raw is List)
            for (final e in raw)
              if (e is Map) fromJson(Map<String, dynamic>.from(e)),
        ];
    final songs = parse(data['songs'], AudioSongDto.fromJson);
    final albums = parse(data['albums'], AudioAlbumDto.fromJson);
    final artists = parse(data['artists'], AudioNameDto.fromJson);
    final composers = parse(data['composers'], AudioNameDto.fromJson);
    final genres = parse(data['genres'], AudioNameDto.fromJson);
    return AudioGlobalSearchResult(
      songs: songs,
      albums: albums,
      artists: artists,
      composers: composers,
      genres: genres,
      songsTotal: _intOf(data['songsTotal'], songs.length),
      albumsTotal: _intOf(data['albumTotal'], albums.length),
      artistsTotal: _intOf(data['artistTotal'], artists.length),
      composersTotal: _intOf(data['composerTotal'], composers.length),
      genresTotal: _intOf(data['genreTotal'], genres.length),
    );
  }
}

// ---------------------------------------------------------------- 错误文案

/// 失败的**大类**：界面据此给出不同的空态/图标/标题。
///
/// 任务书硬要求："区分套件未安装 / 无权限 / 网络失败，不要一律加载失败"。
enum AsFailureKind {
  /// 这台 NAS 没装（或没启用）Audio Station（能力表里没有该 API）。
  notInstalled,

  /// 装了，但这账号没有该应用权限（`audiostation.auth` 的 `allow_user`
  /// 是 `admin/local/ldap/domain`；DSM 侧仍需授予
  /// `SYNO.SDS.AudioStation.Application`）。
  noPrivilege,

  /// 会话过期，需要重新登录。
  sessionExpired,

  /// 连不上（断网/隧道未起/证书问题）。
  network,

  /// 其它（业务错误、参数错误……）。
  other,
}

/// 把异常归到 [AsFailureKind]（判据与 [describeAudioError] 一致）。
AsFailureKind audioFailureKind(Object error) {
  if (error is DsmTransportException) return AsFailureKind.network;
  if (error is! DsmApiException) return AsFailureKind.other;
  switch (error.code) {
    case DsmErrorCode.apiNotFound:
    case DsmErrorCode.methodNotFound:
    case DsmErrorCode.notSupportedVersion:
    case DsmErrorCode.noMatchLibEntry:
      return AsFailureKind.notInstalled;
    case DsmErrorCode.noPermission:
    case DsmErrorCode.noAppPrivilege:
      return AsFailureKind.noPrivilege;
    case DsmErrorCode.sessionTimeout:
    case DsmErrorCode.sidNotFound:
      return AsFailureKind.sessionExpired;
    default:
      return AsFailureKind.other;
  }
}

/// Audio Station 错误 → 可读文案。
///
/// 与 `describeDownloadError` 同一套路，但**按 AS 的语义**解释：
///   * `102` = 这台 NAS 没装/没启用 Audio Station（能力表里没这个 API）；
///   * `160` / `105` = 账号没有该应用权限；
///   * `DsmTransportException` = 网络失败；
///   * 业务码用包内官方前端 `audio-utils.js` 的 `getErrCodeMapping`（逐字，
///     doc §5 U9 之外的额外取证）解释。
///
/// 数据层只认 key + 中文原文；英文由 Flutter 层注入（§4.6）。
String describeAudioError(Object error) {
  if (error is DsmTransportException) {
    return dataText('asErrNetwork', '网络连接失败，请检查网络后重试');
  }
  if (error is! DsmApiException) return '$error';
  switch (error.code) {
    // 通用 WebAPI 码
    case DsmErrorCode.apiNotFound: // 102
    case DsmErrorCode.methodNotFound: // 103
    case DsmErrorCode.notSupportedVersion: // 104
    case DsmErrorCode.noMatchLibEntry: // 121
      return dataText('asErrNotInstalled', '这台 NAS 没有安装 Audio Station');
    case DsmErrorCode.noPermission: // 105
    case DsmErrorCode.noAppPrivilege: // 160
      return dataText('asErrNoPrivilege', '这个账号没有使用 Audio Station 的权限');
    case DsmErrorCode.sessionTimeout: // 106
    case DsmErrorCode.sidNotFound: // 119
      return dataText('errLoginExpired', '登录已过期，请重新登录');
    // 业务码（官方 `getErrCodeMapping`，逐字）
    case 101: // AUDIO_ERR_INVALID_PLAYLIST_NAME / AUDIO_ERR_COMMON_ERR
      return dataText('asErrPlaylistNameInvalid', '播放列表名称不被接受');
    case 406: // AUDIO_ERR_FILE_EXISTS
      return dataText('asErrFileExists', '同名文件已存在');
    case 409: // AUDIO_ERR_TOO_MANY_SONGS
      return dataText('asErrTooManySongs', '歌曲数量已达上限');
    case 411: // AUDIO_ERR_DUPLICATE_SONGS
    case 1201:
      return dataText('asErrDuplicateSongs', '有重复的歌曲');
    case 407: // AUDIO_ERR_PLAYLIST_NOT_EXISTS
    case 412:
    case 1202:
      return dataText('asErrPlaylistNotExists', '播放列表不存在（DSM 可能正在重建索引）');
    case 410: // AUDIO_ERR_SHARED_PLAYLIST_CONTAINS_SONG_RATING
      return dataText('asErrSharedPlaylistRating', '共享列表里不能复制带评分规则的歌曲');
    case 1006: // AUDIO_ERR_PIN_EXIST
      return dataText('asErrPinExists', '这个项目已经收藏过了');
    case 1007: // AUDIO_ERR_PIN_NOT_EXIST
      return dataText('asErrPinNotExists', '这个收藏不存在');
    case 1010: // AUDIO_ERR_PIN_TARGET_NOT_EXIST
    case 1011:
      return dataText('asErrPinTargetNotExists', '要收藏的内容不存在');
    case 501: // AUDIO_ERR_INVALID_PASSWORD（AirPlay 投送，后置）
      return dataText('asErrInvalidPassword', '密码不正确');
    default:
      return dataText(
        'asErrUnknown',
        '未知错误（{code}）',
      ).replaceAll('{code}', '${error.code}');
  }
}

bool _notEmpty(String? s) => s != null && s.trim().isNotEmpty;

String _str(Object? v) => v == null ? '' : '$v';

int _intOf(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

// ────────────────────────────────────────────────── 取流鉴权前置自检（纯函数）

/// "我们自己拼的媒体直链"缺了哪种凭据。
enum AudioMediaAuthProblem {
  /// 查询串里 `_sid` 与 `SynoToken` 都齐（或这个会话本来不需要令牌）。
  none,

  /// 缺 `_sid`（没有会话 / 会话已清）。
  missingSid,

  /// 会话有 `SynoToken`，但 URL 的查询串里没有 —— DSM 会回
  /// `200 {"error":{"code":105}}`，Media3 报"没有 extractor 能读这个流"。
  missingSynoToken,
}

/// 在把 URL 交给原生播放器**之前**做一次鉴权自检（纯函数，可离线单测）。
///
/// 为什么要有这一层：服务端对"缺令牌的直链"回的是 **HTTP 200 + JSON**，
/// 原生播放器只报"没有 extractor 能读"，看不出是鉴权问题（真机第 274 轮）。
/// 在这里先判一次，就能在**进播放器之前**给出可归因的失败原因，
/// 而不是让用户看到一句含糊的"播放失败"。
///
/// [sessionHasSid] / [sessionHasSynoToken] 是**当前会话**的能力
/// （`AudioStationApi.sid` 非空 / [AudioStationApi.hasSynoToken]）：
/// 会话本来就没有令牌时，URL 里没有 `SynoToken` 是正常的，不算问题。
AudioMediaAuthProblem audioMediaAuthProblem(
  String url, {
  required bool sessionHasSid,
  required bool sessionHasSynoToken,
}) {
  final query = Uri.tryParse(url)?.queryParameters ?? const <String, String>{};
  final hasSid = (query['_sid'] ?? '').isNotEmpty;
  final hasToken = (query['SynoToken'] ?? '').isNotEmpty;
  if (sessionHasSid && !hasSid) return AudioMediaAuthProblem.missingSid;
  if (sessionHasSynoToken && !hasToken) {
    return AudioMediaAuthProblem.missingSynoToken;
  }
  return AudioMediaAuthProblem.none;
}

/// 自检问题的**可查询原因串**（进 logcat；也是单测的断言点）。
///
/// 一律带 `as-url-auth` 前缀，便于 `adb logcat | grep as-url-auth` 一次捞全。
String audioMediaAuthProblemReason(
  AudioMediaAuthProblem problem, {
  required bool sessionHasSynoToken,
}) => switch (problem) {
  AudioMediaAuthProblem.none => 'as-url-auth ok',
  AudioMediaAuthProblem.missingSid => 'as-url-auth FAIL missing-sid',
  AudioMediaAuthProblem.missingSynoToken =>
    'as-url-auth FAIL missing-synotoken (session has token=$sessionHasSynoToken)',
};
