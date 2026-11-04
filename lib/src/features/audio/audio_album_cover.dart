// 专辑封面的**两级解析**（r439，用户当轮拍板「改成逐首探 `getsongcover`」）。
//
// 背景（r427 只读实测，`docs/evidence-r427/host/r427_album_cover_probe.txt`）：
// 12 张专辑里**只有 2 张**有专辑级真封面（`Cover.getcover` ⇒ 200 ＋ 真 JPEG）；
// 另外 10 张的专辑级响应是 **404 ＋ 11,939 B HTML**（不是空、也不是占位图）。
// 其中 **4 张**在**歌曲级** `Cover.getsongcover` 有真图，而且**全部在第 1 首**
// 就命中（175–242 ms）；剩下 6 张**纵深探 24–30 首也一张都没有**
// （1115–1355 ms）。⇒ 列表页"每行都深探"是纯浪费；而**只探第 1 首**
// 就能拿到这次实测里的**全部收益**。
//
// 所以这里把"要不要逐首探、探多深"做成**有界 ＋ 负缓存**的策略：
//   * [maxSongs] 默认 **1**（r427 的 4/4 命中都在第 1 首；超出 1 首的纵深
//     在实测里**收益为 0**），列表页与详情页共用同一个解析器；
//   * 结果按 `专辑 + 专辑艺术家` **会话级缓存**（含**否定**结果）⇒ 滚动回
//     同一张专辑**不再发请求**（r427 的代价表：无封面专辑 24–30 次请求）。
//
// ★ 判据的"是不是真图"与 [AuthedImage] 共用一条（[looksLikeImage] 魔数），
// 并且命中时把字节塞进 [AuthedImageCache]（同一 `identity|url` 键）⇒
// 解析器探到的那一次不会让随后的 `AuthedImage` 再取一遍。
library;

import '../../data/dto/audio_station_dto.dart';

/// 「这个 URL 回的算不算真图」——命中时实现方应把字节放进共享缓存。
typedef CoverBytesProbe = Future<bool> Function(String url, String cacheKey);

/// 见文件头。**纯逻辑**（所有 IO 都是注入进来的），所以可以宿主测试。
class AlbumCoverResolver {
  AlbumCoverResolver({
    required this.probeCover,
    required this.listSongs,
    required this.albumCoverUrl,
    required this.songCoverUrl,
    this.maxSongs = 1,
  });

  /// 探一个 URL 是不是真图（命中时把字节写进共享缓存）。
  final CoverBytesProbe probeCover;

  /// 该专辑的歌曲（实现方负责 `Song.list {album, album_artist}`）。
  final Future<List<AudioSongDto>> Function(String album, String albumArtist)
  listSongs;

  /// 专辑级封面 URL（`Cover.getcover`）。
  final String? Function(String album, String albumArtist) albumCoverUrl;

  /// 单曲封面 URL（`Cover.getsongcover`）。
  final String Function(AudioSongDto song) songCoverUrl;

  /// 最多逐首探几个（**列表页/详情页都是 1**，见文件头）。
  final int maxSongs;

  /// 会话级缓存（含否定结果：`null` 也是结论）。
  final Map<String, String?> _cache = <String, String?>{};

  /// 实测用：这一次 [resolve] 发了几次探测请求（用例断言"有界"）。
  int lastProbeCount = 0;

  /// 实测用：缓存命中次数。
  int cacheHits = 0;

  /// 解析顺序：① 专辑级真图 ⇒ 直接用（**不再探歌曲**）；
  /// ② 专辑级不是真图 ⇒ 探前 [maxSongs] 首的 `getsongcover`，第一张真图胜出；
  /// ③ 都不行 ⇒ `null`（调用方回占位图标），并**记住这个否定结论**。
  Future<String?> resolve({
    required String album,
    required String albumArtist,
    String? identity,
    bool albumAlreadyTried = false,
  }) async {
    final key = '$album\u0000$albumArtist';
    if (_cache.containsKey(key)) {
      cacheHits++;
      return _cache[key];
    }
    lastProbeCount = 0;
    final id = identity ?? 'album:$album';
    // `albumAlreadyTried`：调用方（`AudioCoverImage` 的回退钩子）**刚刚**已经取过
    // 专辑级 URL 并且失败了 ⇒ 不要再探一遍（否则同一张专辑级封面取两遍；
    // 而且两次的 `_dc` 不同、缓存键也不同，缓存救不了）。
    if (!albumAlreadyTried) {
      final albumUrl = albumCoverUrl(album, albumArtist);
      if (albumUrl != null && albumUrl.isNotEmpty) {
        lastProbeCount++;
        if (await probeCover(albumUrl, '$id|$albumUrl')) {
          return _cache[key] = albumUrl;
        }
      }
    }
    List<AudioSongDto> songs;
    try {
      songs = await listSongs(album, albumArtist);
    } catch (_) {
      // 列表拿不到 ≠ 这张专辑没有封面：**不写否定缓存**，下次还能再试。
      return null;
    }
    final probeLimit = maxSongs < 1 ? 0 : maxSongs;
    for (final song in songs.take(probeLimit)) {
      final url = songCoverUrl(song);
      if (url.isEmpty) continue;
      lastProbeCount++;
      if (await probeCover(url, '$id|$url')) {
        return _cache[key] = url;
      }
    }
    return _cache[key] = null;
  }
}
