// r439：专辑封面的**两级解析**（专辑级 `Cover.getcover` → 逐首探 `getsongcover`）。
//
// **`DA93`（r439）**：专辑行只问专辑级 `getcover` ⇒ 服务端在歌曲级有真封面时仍恒显示占位图标。
//
// 这批用例钉的是**代价边界**，不是"能不能拿到 URL"：
//   * r427 只读实测（`docs/evidence-r427/host/r427_album_cover_probe.txt`）12 张专辑里
//     **4 张**靠歌曲级真图受益，**全部在第 1 首命中**；剩下 6 张**纵深 24–30 首也一张都没有**
//     （1.1–1.4 s / 每张专辑）。⇒ 列表页必须**有界**（默认只探 1 首）＋ 结论进**会话级缓存**
//     （含否定结论），否则滚动一次就把 NAS 打满。
//   * 所以本文件的红线判据是：**"探了几次"**。第 ③ 条用 30 首歌的专辑证明
//     "只探 1 首、不是 31 次"；第 ④ 条证明第二次解析**一次都不发**。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/features/audio/audio_album_cover.dart';

List<AudioSongDto> _songs(int n) => List<AudioSongDto>.generate(
  n,
  (i) => AudioSongDto(id: 'music_${i + 1}', title: 'song ${i + 1}'),
);

/// 组装一个"只有 URL 形态"的解析器；`realImages` 里的 URL 才算真图。
({
  AlbumCoverResolver resolver,
  List<String> probed,
  List<String> cacheKeys,
  List<String> listed,
})
_build({
  required Set<String> realImages,
  required List<AudioSongDto> songs,
  int maxSongs = 1,
  bool listThrows = false,
}) {
  final probed = <String>[];
  final cacheKeys = <String>[];
  final listed = <String>[];
  final resolver = AlbumCoverResolver(
    maxSongs: maxSongs,
    probeCover: (url, cacheKey) async {
      probed.add(url);
      cacheKeys.add(cacheKey);
      return realImages.contains(url);
    },
    listSongs: (album, albumArtist) async {
      listed.add('$album|$albumArtist');
      if (listThrows) throw StateError('list failed');
      return songs;
    },
    albumCoverUrl: (album, albumArtist) => 'https://nas/album?name=$album',
    songCoverUrl: (song) => 'https://nas/song?id=${song.id}',
  );
  return (
    resolver: resolver,
    probed: probed,
    cacheKeys: cacheKeys,
    listed: listed,
  );
}

void main() {
  test('① 专辑级就是真图 ⇒ 只探 1 次，**不**列歌曲（不付"逐首探"的代价）', () async {
    final b = _build(realImages: {'https://nas/album?name=A'}, songs: _songs(30));
    final url = await b.resolver.resolve(album: 'A', albumArtist: 'X');
    expect(url, 'https://nas/album?name=A');
    expect(b.probed, ['https://nas/album?name=A']);
    expect(b.listed, isEmpty, reason: '专辑级命中就**不该**去列歌曲');
    expect(b.resolver.lastProbeCount, 1);
  });

  test('② 专辑级不是真图、第 1 首是 ⇒ 探 2 次，返回歌曲 URL（r427 的 4/4 形态）', () async {
    final b = _build(
      realImages: {'https://nas/song?id=music_1'},
      songs: _songs(30),
    );
    final url = await b.resolver.resolve(
      album: '00s Love Songs',
      albumArtist: 'Various Artists',
      identity: '00s Love Songs',
    );
    expect(url, 'https://nas/song?id=music_1');
    expect(b.probed.length, 2);
    expect(b.resolver.lastProbeCount, 2);
    // 命中时的缓存键 = `identity|url`（与 `AuthedImage` 的键同式 ⇒ 只取一次）
    expect(b.cacheKeys.last, '00s Love Songs|https://nas/song?id=music_1');
  });

  test('③ 30 首歌全无真图 ⇒ **有界**：探 1 + maxSongs(1) 次，不是 31 次', () async {
    final b = _build(realImages: const {}, songs: _songs(30));
    final url = await b.resolver.resolve(album: 'Aeneid Of Virgil', albumArtist: 'X');
    expect(url, isNull);
    expect(b.resolver.lastProbeCount, 2, reason: '专辑级 1 次 + 第 1 首 1 次');
    expect(b.probed.length, 2);
    expect(b.listed.length, 1);
  });

  test('②b `albumAlreadyTried: true`（回退钩子）⇒ **不再探专辑级**，只探歌曲', () async {
    final b = _build(
      realImages: {'https://nas/song?id=music_1'},
      songs: _songs(30),
    );
    final url = await b.resolver.resolve(
      album: '00s Love Songs',
      albumArtist: 'Various Artists',
      albumAlreadyTried: true,
    );
    expect(url, 'https://nas/song?id=music_1');
    expect(b.probed, ['https://nas/song?id=music_1'], reason: '专辑级已由界面取过并失败');
    expect(b.resolver.lastProbeCount, 1);
  });

  test('③b maxSongs 是**参数**：给 3 就能探到第 3 首命中', () async {
    final b = _build(
      realImages: {'https://nas/song?id=music_3'},
      songs: _songs(30),
      maxSongs: 3,
    );
    final url = await b.resolver.resolve(album: 'A', albumArtist: 'X');
    expect(url, 'https://nas/song?id=music_3');
    expect(b.resolver.lastProbeCount, 4);
  });

  test('④ 会话级缓存：第二次解析**一次请求都不发**（否定结论也缓存）', () async {
    final b = _build(realImages: const {}, songs: _songs(30));
    expect(await b.resolver.resolve(album: 'A', albumArtist: 'X'), isNull);
    final firstProbes = b.probed.length;
    final firstListed = b.listed.length;
    expect(await b.resolver.resolve(album: 'A', albumArtist: 'X'), isNull);
    expect(b.probed.length, firstProbes, reason: '滚动回同一张专辑不许再打 NAS');
    expect(b.listed.length, firstListed);
    expect(b.resolver.cacheHits, 1);
    // 换 artist ⇒ 是不同的专辑身份 ⇒ 该重新解析
    await b.resolver.resolve(album: 'A', albumArtist: 'Y');
    expect(b.probed.length > firstProbes, isTrue);
  });

  test('⑤ `Song:list` 失败 ⇒ 返回 null 但**不写否定缓存**（下次还能再试）', () async {
    final b = _build(realImages: const {}, songs: _songs(3), listThrows: true);
    expect(await b.resolver.resolve(album: 'A', albumArtist: 'X'), isNull);
    expect(b.listed.length, 1);
    expect(await b.resolver.resolve(album: 'A', albumArtist: 'X'), isNull);
    expect(b.listed.length, 2, reason: '"拿不到列表" ≠ "这张专辑没有封面"');
    expect(b.resolver.cacheHits, 0);
  });
}
