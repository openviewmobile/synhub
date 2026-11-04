// Audio Station 的 DTO（阶段二 A：Audio Station 普通用户功能）。
//
// 字段名**逐字**取自 AudioStation-x86_64-7.2.1-6006.spk 包内官方 Web 前端
// （`app/audio-common.js` 的 `createMetadataMapping` / `createParamsMapping` /
// `createFieldConvertFunc` 与 `app/audio-utils.js`）——不要凭记忆改。
//
// 官方前端对同一首歌有两套字段路径（`createFieldConvertFunc` 逐字）：
//   * 库视图：`record.<field>` 或 `record.additional.song_tag.<field>`；
//   * 播放列表视图：`record.additional.songs.additional.song_tag.<field>`
//     （`Playlist.getinfo` 把歌嵌在 `data.playlists[0].additional.songs`）。
// 本文件的 [_SongFields] 同时认这两条路径。
//
// ⚠️ 数据层：**不许** import flutter / package:flutter（要能被 `dart run tool/*.dart`
// 加载）；文案走 `dataText(key, 中文原文)`（见 docs/app-identity-and-i18n.md §4.6）。
library;

/// `library` 参数取值（`SYNO.AudioStation.*.list`）。官方前端用
/// `Window.getBrowseLibraryType()`；`personal` = 个人音乐库、`shared` = 共享。
enum AudioLibrary {
  personal,
  shared;

  /// 线上取值（`library=personal` / `library=shared`）。
  String get wire => name;
}

/// 音乐库的浏览分类（对应 `SYNO.AudioStation.<X>.list` 的命名空间）。
enum AudioBrowseKind {
  song, // SYNO.AudioStation.Song       root data.songs
  album, // SYNO.AudioStation.Album      root data.albums
  artist, // SYNO.AudioStation.Artist    root data.artists
  composer, // SYNO.AudioStation.Composer root data.composers
  genre, // SYNO.AudioStation.Genre      root data.genres
  folder, // SYNO.AudioStation.Folder     root data.items
  playlist, // SYNO.AudioStation.Playlist root data.playlists
}

/// 播放列表类型（`Playlist.list` 记录里的 `type`）。
class AudioPlaylistType {
  static const String normal = 'normal';
  static const String smart = 'smart';
}

/// `SYNO.AudioStation.Song` 的 `additional` 子项（官方 `createParamsMapping`：
/// `"song_tag,song_audio,song_rating"`）。
const String kSongAdditional = 'song_tag,song_audio,song_rating';

/// 专辑/艺术家/作曲家/流派的 `additional` 子项（官方 `createParamsMapping`：
/// `"avg_rating"`）。
const String kAvgRatingAdditional = 'avg_rating';

// ------------------------------------------------------------------ 歌曲

/// 一首歌（`SYNO.AudioStation.Song.list/search/getinfo` 的记录）。
///
/// 所有字段都是**防御式**取值：官方前端对每个字段都写
/// `testProperty(...)?…:""`（doc §5 U8），所以缺字段是常态，不能当解析错误。
class AudioSongDto {
  const AudioSongDto({
    required this.id,
    this.path = '',
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.composer = '',
    this.genre = '',
    this.comment = '',
    this.year = 0,
    this.track = 0,
    this.disc = 0,
    this.duration = 0,
    this.filesize = 0,
    this.bitrate = 0,
    this.frequency = 0,
    this.channel = 0,
    this.rating = 0,
    this.type = '',
    this.container = '',
    this.codec = '',
    this.support = true,
    this.isVirtual = false,
  });

  /// 歌曲 id（形如 `music_<md5>`；文件夹列表里是 `file_<md5>`）。
  final String id;

  /// 服务端文件路径（**流式 URL 的扩展名由它推导**，见 `audio_station.dart`）。
  final String path;

  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final String composer;
  final String genre;
  final String comment;

  /// `additional.song_tag.year`（字符串形态在线上也出现过，统一转成 int）。
  final int year;

  /// `additional.song_tag.track` / `disc`。
  final int track;
  final int disc;

  /// `additional.song_audio.duration`（**秒**）。
  final int duration;

  /// `additional.song_audio.filesize`（字节）。
  final int filesize;

  /// `additional.song_audio.bitrate`（bps）/ `frequency`（Hz）/ `channel`（声道数）。
  final int bitrate;
  final int frequency;
  final int channel;

  /// `additional.song_rating.rating`（0–5；0 = 无评分）。
  final double rating;

  /// 记录类型（`file` / `music_track` …）。
  final String type;

  /// `additional.song_audio` 之外的容器/编码信息（`container` / `codec`），
  /// 官方 `isALAC()` 用它判断 ALAC。
  final String container;
  final String codec;

  /// 服务端认为能否直接播放（`support`；播放队列里 `false` 会标 `!`）。
  final bool support;

  /// 是否是"虚拟曲目"（CUE 分轨；官方 `isVirtualMusic()`）。
  final bool isVirtual;

  factory AudioSongDto.fromJson(Map<String, dynamic> json) {
    final tag = _tagOf(json, 'song_tag');
    final audio = _tagOf(json, 'song_audio');
    final rating = _tagOf(json, 'song_rating');
    final path = _str(json['path']);
    return AudioSongDto(
      id: _str(json['id']),
      path: path,
      title: _first([json['title'], tag['title']]),
      artist: _first([json['artist'], tag['artist']]),
      album: _first([json['album'], tag['album']]),
      albumArtist: _first([json['album_artist'], tag['album_artist']]),
      composer: _first([json['composer'], tag['composer']]),
      genre: _first([json['genre'], tag['genre']]),
      comment: _first([json['comment'], tag['comment']]),
      year: _intOf(_firstOrNull([json['year'], tag['year']])),
      track: _intOf(_firstOrNull([json['track'], tag['track']])),
      disc: _intOf(_firstOrNull([json['disc'], tag['disc']])),
      duration: _intOf(_firstOrNull([audio['duration'], json['duration']])),
      filesize: _intOf(_firstOrNull([audio['filesize'], json['filesize']])),
      bitrate: _intOf(audio['bitrate']),
      frequency: _intOf(audio['frequency']),
      channel: _intOf(audio['channel']),
      rating: _ratingOf(_firstOrNull([rating['rating'], json['song_rating']])),
      type: _str(json['type']),
      container: _str(json['container']),
      codec: _str(json['codec']),
      support: json['support'] != false,
      isVirtual: path.contains('/music_') || _str(json['type']) == 'virtual',
    );
  }

  /// 次要信息行用的"艺术家 · 专辑"（缺失时退化成单个）。
  String get subtitle {
    final parts = [if (artist.isNotEmpty) artist, if (album.isNotEmpty) album];
    return parts.join(' · ');
  }

  /// 时长 `m:ss`（`duration` 为秒；0 显示 `—`）。
  String get durationText => asDurationText(duration);

  /// 码率 kbps（0 显示空）。
  String get bitrateText =>
      bitrate > 0 ? '${(bitrate / 1000).round()} kbps' : '';
}

/// 一页歌曲（`data.songs` + `data.total`）。
class AudioSongPage {
  const AudioSongPage({
    this.items = const [],
    this.total = 0,
    this.offset = 0,
    this.limit = 0,
  });

  final List<AudioSongDto> items;
  final int total;
  final int offset;
  final int limit;
}

// ------------------------------------------------------- 专辑 / 名字型记录

/// 专辑（`SYNO.AudioStation.Album.list` 记录）。
class AudioAlbumDto {
  const AudioAlbumDto({
    this.name = '',
    this.albumArtist = '',
    this.artist = '',
    this.composer = '',
    this.genre = '',
    this.year = 0,
    this.avgRating = 0,
    this.songCount = 0,
  });

  final String name;
  final String albumArtist;
  final String artist;
  final String composer;
  final String genre;
  final int year;

  /// `additional.avg_rating`（官方 `calculateAvgRating`：非 0 评分的均值，0.5 步进）。
  final double avgRating;

  /// 记录里若有 `song_count`（未在官方 JS 里逐字证实，缺失为 0）。
  final int songCount;

  factory AudioAlbumDto.fromJson(Map<String, dynamic> json) {
    final tag = _tagOf(json, 'song_tag');
    return AudioAlbumDto(
      name: _first([json['name'], tag['album']]),
      albumArtist: _first([json['album_artist'], tag['album_artist']]),
      artist: _first([json['artist'], tag['artist']]),
      composer: _first([json['composer'], tag['composer']]),
      genre: _first([json['genre'], tag['genre']]),
      year: _intOf(_firstOrNull([json['year'], tag['year']])),
      avgRating: _ratingOf(_avgOf(json)),
      songCount: _intOf(json['song_count']),
    );
  }

  String get subtitle => [
    if (albumArtist.isNotEmpty) albumArtist,
    if (year > 0) '$year',
  ].join(' · ');
}

/// 艺术家 / 作曲家 / 流派共用的"只有名字 + 平均评分"记录
/// （官方 `metadataMapping` 里三者都是 `name` + `additional.avg_rating`）。
class AudioNameDto {
  const AudioNameDto({this.name = '', this.avgRating = 0, this.songCount = 0});

  final String name;
  final double avgRating;
  final int songCount;

  factory AudioNameDto.fromJson(Map<String, dynamic> json) => AudioNameDto(
    name: _str(json['name']),
    avgRating: _ratingOf(_avgOf(json)),
    songCount: _intOf(json['song_count']),
  );
}

/// 一页"名字型"记录（专辑/艺术家/作曲家/流派）。
class AudioNamedPage<T> {
  const AudioNamedPage({
    this.items = const [],
    this.total = 0,
    this.offset = 0,
    this.limit = 0,
  });

  final List<T> items;
  final int total;
  final int offset;
  final int limit;
}

// ------------------------------------------------------------------ 文件夹

/// 文件夹条目（`SYNO.AudioStation.Folder.list` 的 `data.items`）。
///
/// `type` 是 `folder` 或 `file`（文件即一首歌）；`id` 分别是
/// `dir_<md5>` / `music_<md5>`。
class AudioFolderItemDto {
  const AudioFolderItemDto({
    this.id = '',
    this.path = '',
    this.title = '',
    this.type = '',
    this.isFolder = false,
    this.support = true,
  });

  final String id;
  final String path;
  final String title;

  /// `folder` / `file`（官方 JS 用 `"folder"===b` 判目录）。
  final String type;
  final bool isFolder;
  final bool support;

  factory AudioFolderItemDto.fromJson(Map<String, dynamic> json) {
    final type = _str(json['type']);
    final path = _str(json['path']);
    return AudioFolderItemDto(
      id: _str(json['id']),
      path: path,
      title: _first([json['title'], path.split('/').last]),
      type: type,
      isFolder: type == 'folder',
      support: json['support'] != false,
    );
  }
}

/// 一页文件夹条目（`data.items` + `data.folder_total`）。
///
/// 官方 JS 用 `data.folder_total` 算文件的首索引（`firstSongIdx`），
/// 所以它和服务端的 `total` 不是一回事，单独留一个字段。
class AudioFolderPage {
  const AudioFolderPage({
    this.items = const [],
    this.total = 0,
    this.folderTotal = 0,
    this.offset = 0,
    this.limit = 0,
  });

  final List<AudioFolderItemDto> items;
  final int total;

  /// `data.folder_total`（目录项总数）。
  final int folderTotal;
  final int offset;
  final int limit;
}

// ---------------------------------------------------------------- 播放列表

/// 播放列表（`SYNO.AudioStation.Playlist.list` 记录）。
class AudioPlaylistDto {
  const AudioPlaylistDto({
    this.id = '',
    this.name = '',
    this.library = '',
    this.type = AudioPlaylistType.normal,
    this.sharingStatus = '',
    this.songCount = 0,
    this.songs = const [],
    this.songsTotal = 0,
  });

  final String id;
  final String name;

  /// `personal` / `shared`。
  final String library;

  /// `normal` / `smart`。
  final String type;
  final String sharingStatus;

  /// 列表歌曲数（`Playlist.list` 的 `song_count`，缺失为 0）。
  final int songCount;

  /// `Playlist.getinfo` 的 `additional.songs`（列表详情才有）。
  final List<AudioSongDto> songs;

  /// `additional.songs_total`。
  final int songsTotal;

  bool get isSmart => type == AudioPlaylistType.smart;

  factory AudioPlaylistDto.fromJson(Map<String, dynamic> json) {
    final additional = json['additional'];
    final map = additional is Map
        ? Map<String, dynamic>.from(additional)
        : const <String, dynamic>{};
    final rawSongs = map['songs'];
    return AudioPlaylistDto(
      id: _str(json['id']),
      name: _str(json['name']),
      library: _str(json['library']),
      type: _str(json['type']).isEmpty
          ? AudioPlaylistType.normal
          : _str(json['type']),
      sharingStatus: _str(json['sharing_status']),
      songCount: _intOf(json['song_count']),
      songs: [
        if (rawSongs is List)
          for (final e in rawSongs)
            if (e is Map) AudioSongDto.fromJson(Map<String, dynamic>.from(e)),
      ],
      songsTotal: _intOf(map['songs_total']),
    );
  }
}

/// 一页播放列表。
class AudioPlaylistPage {
  const AudioPlaylistPage({
    this.items = const [],
    this.total = 0,
    this.offset = 0,
    this.limit = 0,
  });

  final List<AudioPlaylistDto> items;
  final int total;
  final int offset;
  final int limit;
}

// ---------------------------------------------------------------- 网络电台

/// 网络电台（`SYNO.AudioStation.Radio.list` 的 `data.radios` 记录）。
///
/// 真机逐字（`docs/audio-api-live.md` §1）：
/// `{"radios":[{"id":"SHOUTcast","title":"SHOUTcast(TM)","type":"container",
/// "url":""},{"id":"UserDefined",…}]}`。
///
/// ⚠️ **`type:"container"` 是"容器/分类"，不是可播放电台项** —— 真机首屏回的
/// 两条都是容器（`url` 为空）。官方前端把 `container` 映射成目录图标
/// （`createImgMapping`：`container:"icon_folder_96.png"`、`station:"icon_radio_96.png"`），
/// 且容器 `url` 为空 ⇒ 没有可播放地址。UI 必须把两者分开，
/// **不许**把容器当电台项渲染（否则点进去是空壳）。
///
/// ⚠️ 显示名一律用 [title]（真机容器 `id:"SHOUTcast"` 但 `title:"SHOUTcast(TM)"`）——
/// `id` 是内部值，不上屏。
///
/// ★★ **容器展开与电台项形状（第 392 轮取证，DA32 的修法依据）**：
/// 展开参数是 **`container`**（官方 `audio-common.js` 逐字：
/// `api:"SYNO.AudioStation.Radio",method:"list",container:b,offset,library,text`），
/// 取值链：`null`（根级）→ `SHOUTcast`（**分类层**）→ `SHOUTcast_<genre>`
/// （分类叶子；`isInShoutCast()` 逐字判 `container.substr(0,9)==="SHOUTcast"`）
/// 或 `UserDefined` / `Favorite`（用户自定义 / 收藏）。分类叶子与用户容器下的
/// **电台项** `id` 以 `radio_` 开头（官方 `isInetRadioItem()` 逐字判
/// `"radio_"===id.substr(0,6)`），带**非空 `url`**（分包
/// `etc/radio/shoutcast_<genre>.json` 的站字段是 `name/desc/url/bitrate/mimetype`，
/// 共 26 个分类文件 ⇒ 与 HTML 前端的分类层同源）。
///
/// ⚠️ 台标 URL 常见形态是 **`.pls` 播放列表**（SHOUTcast 目录给出的
/// `tunein-station.pls?id=…`），不是裸音频 ⇒ 播放前要先解析播放列表
/// （见 `features/audio/audio_radio_stream.dart`）。
class AudioRadioDto {
  const AudioRadioDto({
    this.id = '',
    this.title = '',
    this.type = '',
    this.url = '',
    this.desc = '',
  });

  /// 记录 id（容器是 `SHOUTcast`/`UserDefined` 这类内部标识，**不上屏**）。
  final String id;

  /// 显示名（真机 `SHOUTcast(TM)`）；为空时调用方再决定兜底。
  final String title;

  /// 记录类型。真机已知值：`container`；官方前端另有 `station` 图标分支。
  final String type;

  /// 电台流地址（容器为空串；普通电台项的形态**未取证**）。
  final String url;

  /// 描述（未在真机回包里确认，防御式取值）。
  final String desc;

  /// 容器/分类（真机 `type:"container"`）。
  static const String typeContainer = 'container';

  /// `Radio.add` 的 `container` 取值：用户自定义电台（官方
  /// `RadioEditor.USERDEFINED`）。
  static const String containerUserDefined = 'UserDefined';

  /// `Radio.add` 的 `container` 取值：收藏（官方 `RadioEditor.FAVORITE`）。
  static const String containerFavorite = 'Favorite';

  /// `Radio.list` 的 `container` 取值：SHOUTcast **分类层**（官方
  /// `_ShoutCast_ID="SHOUTcast"`）。分类叶子是 `SHOUTcast_<genre>`。
  static const String containerShoutcast = 'SHOUTcast';

  /// 是否是可播电台项（官方以 `id` 前缀 `radio_` 判定；有非空 `url` 也算）。
  bool get isStation => !isContainer && (id.startsWith('radio_') || url.isNotEmpty);

  /// 是否是容器（分类），而不是可播放的电台项。
  bool get isContainer => type == typeContainer;

  /// 是否拿到了可播放地址。**容器恒为 false**（真机 `url:""`）。
  ///
  /// ⚠️ 这只是"有没有地址"，**不等于**"我们能播它"：电台直连的鉴权/形态未取证，
  /// 本批不据此发起播放。
  bool get hasStreamUrl => !isContainer && url.isNotEmpty;

  factory AudioRadioDto.fromJson(Map<String, dynamic> json) => AudioRadioDto(
    id: _str(json['id']),
    title: _str(json['title']),
    type: _str(json['type']),
    url: _str(json['url']),
    desc: _str(json['desc']),
  );
}

/// 一页网络电台（`data.radios` + `data.total`）。
class AudioRadioList {
  const AudioRadioList({
    this.items = const [],
    this.total = 0,
    this.offset = 0,
    this.limit = 0,
  });

  final List<AudioRadioDto> items;
  final int total;
  final int offset;
  final int limit;
}

// ---------------------------------------------------------------- Web Player 队列

/// 服务端 Web Player 的**播放队列状态**（`SYNO.AudioStation.WebPlayer.getplaylist` v1）。
///
/// 真机逐字（`docs/audio-api-live.md` §6，无参调用）：
/// `{"current":0,"mode":"normal","shuffle":0,"songs":[],"timestamp":1789993283,"total":0}`。
///
/// ⚠️ 这是**服务端**队列（官方 Web Player 的队列），与本机
/// `media_playback_store` 的"本地播放队列"是两码事，UI 上不要混。
///
/// ⚠️ `songs` 里记录的**字段形状未取证**（真机回来是空数组）—— 这里用
/// [AudioSongDto.fromJson] 的防御式取值兜底，**不臆造**字段名。
/// `mode` 已知取值只有 `normal`（其余取值未取证）。
class AudioWebPlayerQueueDto {
  const AudioWebPlayerQueueDto({
    this.current = 0,
    this.mode = '',
    this.shuffle = 0,
    this.songs = const [],
    this.total = 0,
    this.timestamp = 0,
  });

  /// 当前播放序号（无队列时为 0）。
  final int current;

  /// 播放模式；真机已知 `normal`。
  final String mode;

  /// 随机播放开关（真机 `0`；非 0 视为开）。
  final int shuffle;

  final List<AudioSongDto> songs;
  final int total;

  /// 服务端时间戳（秒）。**内部值，不上屏**。
  final int timestamp;

  static const String modeNormal = 'normal';

  bool get isEmpty => songs.isEmpty;

  bool get isShuffled => shuffle != 0;

  factory AudioWebPlayerQueueDto.fromJson(Map<String, dynamic> json) {
    final raw = json['songs'];
    return AudioWebPlayerQueueDto(
      current: _intOf(json['current']),
      mode: _str(json['mode']),
      shuffle: _intOf(json['shuffle']),
      songs: [
        if (raw is List)
          for (final e in raw)
            if (e is Map) AudioSongDto.fromJson(Map<String, dynamic>.from(e)),
      ],
      total: _intOf(json['total']),
      timestamp: _intOf(json['timestamp']),
    );
  }
}

// ------------------------------------------------------------------ 收藏（Pin）

/// `SYNO.AudioStation.Pin.list` 的一条记录。
///
/// ⚠️ 参数/字段结构未 100% 取证（doc §5 U13）：`criteria` 由官方
/// `getPinArgumentsFromRecord` 动态拼，这里原样保留成 map，不做解释。
class AudioPinDto {
  const AudioPinDto({
    this.id = '',
    this.type = '',
    this.name = '',
    this.criteria = const {},
  });

  /// pin 记录 id（`Pin.unpin` / `Pin.rename` 用它）。
  final String id;

  /// `folder` / `album` / `artist` / `composer` / `genre` / `playlist` /
  /// `random_100` / `recently_added`。
  final String type;
  final String name;
  final Map<String, dynamic> criteria;

  factory AudioPinDto.fromJson(Map<String, dynamic> json) {
    final criteria = json['criteria'];
    return AudioPinDto(
      id: _str(json['id']),
      type: _str(json['type']),
      name: _str(json['name']),
      criteria: criteria is Map
          ? Map<String, dynamic>.from(criteria)
          : const <String, dynamic>{},
    );
  }
}

// ---------------------------------------------------------------- 在线标签（A19）

/// `SYNO.AudioStation.Tag.list` 的一条在线标签结果（Discogs 代理）。
///
/// 字段逐字来自 2026-09-22 真机响应：`album` / `album_artist` / `cover` /
/// `genre`（**数组**）/ `release_url` / `year`（**字符串**）。
class AudioTagItemDto {
  const AudioTagItemDto({
    this.album = '',
    this.albumArtist = '',
    this.cover = '',
    this.genres = const [],
    this.releaseUrl = '',
    this.year = '',
  });

  final String album;
  final String albumArtist;
  final String cover;

  /// 服务端给的是数组（如 `["Funk / Soul"]`）。
  final List<String> genres;

  final String releaseUrl;

  /// ⚠️ **字符串**（真机 `"1982"`）；空串表示服务端没给，不编成数字。
  final String year;

  factory AudioTagItemDto.fromJson(Map<String, dynamic> json) {
    final raw = json['genre'];
    return AudioTagItemDto(
      album: _str(json['album']),
      albumArtist: _str(json['album_artist']),
      cover: _str(json['cover']),
      genres: [
        if (raw is List)
          for (final e in raw)
            if (e is String && e.isNotEmpty) e,
        if (raw is String && raw.isNotEmpty) raw,
      ],
      releaseUrl: _str(json['release_url']),
      year: _str(json['year']),
    );
  }
}

/// `Tag.list` 的整页结果（root `data`：`items` + `total`）。
class AudioTagSearchResult {
  const AudioTagSearchResult({this.items = const [], this.total = 0});

  final List<AudioTagItemDto> items;
  final int total;

  bool get isEmpty => items.isEmpty;

  factory AudioTagSearchResult.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    final items = <AudioTagItemDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) AudioTagItemDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    final total = _intOf(json['total']);
    return AudioTagSearchResult(
      items: items,
      total: total > 0 ? total : items.length,
    );
  }
}

/// `Tag.getinfo` 的详情（字段形状未定案：本机恒回 `1100`）。
///
/// 这里只做**防御式**解析：认得出什么就保留什么，不臆造结构。
class AudioTagDetail {
  const AudioTagDetail({
    this.title = '',
    this.album = '',
    this.albumArtist = '',
    this.year = '',
    this.tracklist = const [],
  });

  final String title;
  final String album;
  final String albumArtist;
  final String year;
  final List<AudioTagItemDto> tracklist;

  bool get isEmpty =>
      title.isEmpty &&
      album.isEmpty &&
      albumArtist.isEmpty &&
      tracklist.isEmpty;

  factory AudioTagDetail.fromJson(Map<String, dynamic> json) {
    final raw = json['tracklist'];
    return AudioTagDetail(
      title: _str(json['title']),
      album: _str(json['album']),
      albumArtist: _str(json['album_artist']),
      year: _str(json['year']),
      tracklist: [
        if (raw is List)
          for (final e in raw)
            if (e is Map)
              AudioTagItemDto.fromJson(Map<String, dynamic>.from(e)),
      ],
    );
  }
}

// ---------------------------------------------------------------- 分享（D4）

/// `SYNO.AudioStation.Song.getsharing` v2 的结果。
///
/// doc §2.3 A-2 第 38 行：字段 `enable_sharing`、`url`。
class AudioSharingInfo {
  const AudioSharingInfo({this.enableSharing = false, this.url = ''});

  final bool enableSharing;
  final String url;

  factory AudioSharingInfo.fromJson(Map<String, dynamic> json) =>
      AudioSharingInfo(
        // 服务端可能给 bool，也可能给 0/1；两种都认。
        enableSharing:
            json['enable_sharing'] == true ||
            json['enable_sharing'] == 1 ||
            json['enable_sharing'] == '1',
        url: _str(json['url']),
      );
}

// ---------------------------------------------------------------- 能力（getinfo）

/// `SYNO.AudioStation.Info.getinfo` v6 的关键字段。
///
/// 字段名逐字对齐 doc §2.3 A-1a 第 1 行（来源 `info.cgi`）。
class AudioInfoDto {
  const AudioInfoDto({
    this.versionString = '',
    this.build = 0,
    this.isManager = false,
    this.playlistEdit = false,
    this.sharing = false,
    this.tagEdit = false,
    this.upnpBrowse = false,
    this.remotePlayerPrivilege,
    this.disableUpnp,
    this.enablePersonalLibrary = false,
    this.enableUserHome = false,
    this.playingQueueMax = 0,
    this.supportDsdDecode = false,
    this.transcodeToMp3 = false,
    this.hasAac = false,
    this.audioEnableDownload = false,
    this.enableEqualizer = false,
  });

  final String versionString;
  final int build;

  /// `is_manager`（**只**用于用户管理对话框，不是"仅管理员可用"）。
  final bool isManager;

  /// `privilege.playlist_edit` / `sharing` / `tag_edit` / `upnp_browse`。
  final bool playlistEdit;
  final bool sharing;
  final bool tagEdit;
  final bool upnpBrowse;

  /// `privilege.remote_player` —— Audio Station 的**远程播放（DLNA 渲染器）**权限位。
  ///
  /// ★ 与 [upnpBrowse] 不是一回事：`upnp_browse` 管的是"浏览 DLNA **媒体服务器**"
  /// （官方 Web 前端用它隐藏左侧的媒体服务器树），`remote_player` 管的是
  /// "把本机播放推给远程渲染器" —— 官方 Web 前端里这两处是同一条判据的两半
  /// （`setMediaServerVisible(!settings.disable_upnp && privilege.upnp_browse)`）。
  ///
  /// ★ **三态**：服务端给了才转成 `true`/`false`；**键不存在 = `null` = 不知道**，
  /// 界面不许据此断言"没权限"（AGENTS §2.0.7 第③条）。
  final bool? remotePlayerPrivilege;

  /// `settings.disable_upnp` —— **服务端**那颗"禁用 UPnP"总开关（Audio Station →
  /// 设置 → 高级 → DLNA）。开着的时候 NAS 不会去发现播放设备，列表注定为空，
  /// 与客户端实现无关。键不存在 = `null` = 不知道。
  final bool? disableUpnp;

  final bool enablePersonalLibrary;
  final bool enableUserHome;
  final int playingQueueMax;
  final bool supportDsdDecode;

  /// 播放队列上限的**兜底值**。
  ///
  /// 真机 `Info.getinfo` 实测 `playing_queue_max = 8192`（审计 §1.4 / §6.4），
  /// 官方旧文档写的 500 是**错的**。服务端没给这个键时才用 8192 兜底，
  /// 给了就用服务端的值。
  static const int kPlayingQueueMaxFallback = 8192;

  /// 实际生效的队列上限（0/缺失 → [kPlayingQueueMaxFallback]）。
  int get queueMax =>
      playingQueueMax > 0 ? playingQueueMax : kPlayingQueueMaxFallback;

  /// `transcode_to_mp3`：决定转码流的默认格式（官方
  /// `createStreamingModeSupportList` 用它）。
  final bool transcodeToMp3;
  final bool hasAac;
  final bool audioEnableDownload;
  final bool enableEqualizer;

  factory AudioInfoDto.fromJson(Map<String, dynamic> json) {
    final p = json['privilege'];
    final priv = p is Map
        ? Map<String, dynamic>.from(p)
        : const <String, dynamic>{};
    // 真机（DSM 7.2.1 / AS 7.2.1-6006）把下载开关放在 **`settings.enable_download`**
    // 而不是顶层 `audio_enable_download`。两处都读（顶层优先；老固件只有顶层）。
    final s = json['settings'];
    final settings = s is Map
        ? Map<String, dynamic>.from(s)
        : const <String, dynamic>{};
    return AudioInfoDto(
      versionString: _str(json['version_string']),
      build: _intOf(json['build']),
      isManager: json['is_manager'] == true,
      playlistEdit: priv['playlist_edit'] == true,
      sharing: priv['sharing'] == true,
      tagEdit: priv['tag_edit'] == true,
      upnpBrowse: priv['upnp_browse'] == true,
      // ★ 只认**服务端真的下发了这个键**（`containsKey`）—— 缺键 ≠ false。
      remotePlayerPrivilege: priv.containsKey('remote_player')
          ? priv['remote_player'] == true
          : null,
      disableUpnp: settings.containsKey('disable_upnp')
          ? settings['disable_upnp'] == true
          : null,
      enablePersonalLibrary: json['enable_personal_library'] == true,
      enableUserHome: json['enable_user_home'] == true,
      playingQueueMax: _intOf(json['playing_queue_max']),
      supportDsdDecode: json['support_dsd_decode'] == true,
      transcodeToMp3: json['transcode_to_mp3'] == true,
      hasAac: json['has_aac'] == true,
      audioEnableDownload:
          json['audio_enable_download'] == true ||
          settings['enable_download'] == true,
      enableEqualizer: json['enable_equalizer'] == true,
    );
  }
}

// ------------------------------------------------------------------ 工具

/// 纯 Dart 字节数（`1.5 GB`）。单位符号不翻译。
String asHumanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 100 ? 0 : 1);
  return '$s ${units[i]}';
}

/// 秒 → `m:ss` / `h:mm:ss`（<=0 或未知回 `—`）。纯符号，不翻译。
String asDurationText(int seconds) {
  if (seconds <= 0) return '—';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return '${h > 0 ? '$h:' : ''}$mm:${s.toString().padLeft(2, '0')}';
}

/// 从 `additional` 里取子对象（`song_tag` / `song_audio` / `song_rating`）。
///
/// 同时认官方前端的两条路径（`createFieldConvertFunc` 逐字）：
///   * `record.additional.<name>.<field>`（库视图）；
///   * `record.additional.songs.additional.<name>.<field>`（播放列表视图）。
Map<String, dynamic> _tagOf(Map<String, dynamic> json, String name) {
  final additional = json['additional'];
  if (additional is! Map) return const {};
  final a = Map<String, dynamic>.from(additional);
  final direct = a[name];
  if (direct is Map && direct.isNotEmpty) {
    return Map<String, dynamic>.from(direct);
  }
  final songs = a['songs'];
  if (songs is Map) {
    final inner = songs['additional'];
    if (inner is Map) {
      final nested = inner[name];
      if (nested is Map) return Map<String, dynamic>.from(nested);
    }
  }
  return const {};
}

/// `avg_rating` 可能在顶层或 `additional` 里。
Object? _avgOf(Map<String, dynamic> json) {
  final additional = json['additional'];
  if (additional is Map && additional['avg_rating'] != null) {
    return additional['avg_rating'];
  }
  return json['avg_rating'];
}

String _str(Object? v) => v == null ? '' : '$v';

String _first(List<Object?> values) {
  for (final v in values) {
    final s = _str(v);
    if (s.isNotEmpty) return s;
  }
  return '';
}

Object? _firstOrNull(List<Object?> values) {
  for (final v in values) {
    if (v == null) continue;
    final s = _str(v);
    if (s.isNotEmpty && s != '0') return v;
    if (s == '0') return v;
  }
  return null;
}

int _intOf(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// 评分（0–5）；服务端可能给 `"0"` / `"3.5"` / `4` / `""`。
double _ratingOf(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}
