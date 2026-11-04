// **`DA230`（r638）**：音乐**列表行没有封面** —— 同一张专辑的十首歌在列表里
// 长得一模一样（都是同一个灰色音符图标），点进详情页却是真封面。
//
// 真机像素并排对比：`docs/evidence-r638/01_music_list_no_cover.png`（列表）
// 与 `02_song_detail_has_cover.png`（详情）—— 同一首 `Demo Song`。
//
// 这里钉的是**接线**（纯逻辑由 `audio_album_cover_test.dart` 覆盖）：
//   ① 有专辑名 ⇒ 主 URL 必须是**专辑级** `getcover`（真图时只取一次字节）；
//   ② 专辑级不是图 ⇒ 才逐首探 `getsongcover`（r439 那条已过真机的回退）；
//   ③ **同一张专辑的多行只取一次字节** —— 这是 `SongRowCoverUrlMemo` 的存在理由
//      （`_coverUrl` 带 `_dc=<now>`，不记忆 URL 就永远命不中 `AuthedImageCache`）；
//   ④ 没有专辑名 ⇒ 退回单曲封面；
//   ⑤ 选中态 ⇒ 打勾，不发任何封面请求（多选时不该再拉图）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_album_cover.dart';
import 'package:synhub/src/features/audio/audio_cover.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/files/file_thumb.dart' show looksLikeImage;
import 'package:synhub/src/features/media/authed_image.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 真 PNG（能真解码）
final Uint8List kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 按 URL 片段回不同字节：命中 [imageFragments] 回真 PNG，其余回 404 的 HTML
/// （r427 真机形态：专辑级没有封面时是 404 正文，不是空字节）。
class _ScriptedTransport extends FakeTransport {
  _ScriptedTransport({this.imageFragments = const <String>{'method=getcover'}});

  final Set<String> imageFragments;
  final List<String> asked = <String>[];

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    asked.add(url);
    if (imageFragments.any(url.contains)) return kPng1x1;
    return utf8.encode('<html><body><h1>404 Not Found</h1></body></html>');
  }
}

const _albumSong = AudioSongDto(
  id: 'music_1',
  title: 'Demo Song',
  album: '00s Love Songs',
  albumArtist: 'Various Artists',
  artist: 'Demo Artist',
  support: true,
);

/// 与生产同构的解析器（r439 的两级路），只是把"逐首探"接在同一个传输层上
/// —— 生产里 `listSongs` 会真的去问 NAS，测试里直接给一首。
AlbumCoverResolver _resolver(_ScriptedTransport t, AudioStationApi api) =>
    AlbumCoverResolver(
      probeCover: (url, cacheKey) async {
        try {
          final bytes = await t.getBytes(url);
          if (!looksLikeImage(Uint8List.fromList(bytes))) return false;
          AuthedImageCache.put(
            cacheKey,
            bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          );
          return true;
        } catch (_) {
          return false;
        }
      },
      listSongs: (album, albumArtist) async => <AudioSongDto>[_albumSong],
      albumCoverUrl: (album, albumArtist) => api.albumCoverUrl(
        album,
        albumArtist: albumArtist,
      ),
      songCoverUrl: (song) => api.songCoverUrl(song.id),
    );

/// 一个容器 + 一棵树（滚动场景要复用**同一个**容器，否则 URL 记忆会重建）
ProviderContainer _container(_ScriptedTransport t) {
  final api = AudioStationApi(DsmWebApi(t));
  final container = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(api),
      // 只覆盖"逐首探"的那一支；主 URL 仍走生产接线
      albumCoverResolverProvider.overrideWithValue(_resolver(t, api)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget _scope(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: Center(child: child)),
      ),
    );

Widget _host(Widget child, _ScriptedTransport t) =>
    _scope(_container(t), child);

/// 一次取字节 + 回退探测都要落地（`AuthedImage` 的 FutureBuilder 需要几帧）
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  setUp(AuthedImageCache.reset);

  testWidgets('DA230 ① 有专辑名 ⇒ 主 URL 是专辑级封面，真图只取一次字节', (tester) async {
    final t = _ScriptedTransport();
    await tester.pumpWidget(
      _host(SongRowCover(song: _albumSong, key: const Key('row')), t),
    );
    await _settle(tester);

    expect(t.asked.length, 1, reason: '专辑级就是真图 ⇒ 不该再有第二次请求');
    expect(t.asked.single, contains('method=getcover'));
    expect(t.asked.single, contains('album_name=00s+Love+Songs'));
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.music_note_outlined), findsNothing);
  });

  testWidgets('DA230 ② 专辑级不是图 ⇒ 才逐首探 getsongcover（共 2 次）', (tester) async {
    final t = _ScriptedTransport(imageFragments: const {'method=getsongcover'});
    await tester.pumpWidget(
      _host(SongRowCover(song: _albumSong, key: const Key('row')), t),
    );
    await _settle(tester);

    expect(t.asked.length, 2, reason: '专辑级 1 次 + 歌曲级 1 次，不多问');
    expect(t.asked.first, contains('method=getcover'));
    expect(t.asked.last, contains('method=getsongcover'));
    expect(find.byType(Image), findsOneWidget, reason: '回退到歌曲封面后要真出图');
  });

  testWidgets('DA230 ③ 同专辑的后续行命中缓存：滚动一屏只取一次字节', (tester) async {
    final t = _ScriptedTransport();
    const other = AudioSongDto(
      id: 'music_2',
      title: 'Best In Me',
      album: '00s Love Songs',
      albumArtist: 'Various Artists',
      support: true,
    );
    final container = _container(t);
    // ① 第一行（滚到列表顶部时先出现的那一行）
    await tester.pumpWidget(
      _scope(
        container,
        SongRowCover(song: _albumSong, key: const Key('row-1')),
      ),
    );
    await _settle(tester);
    expect(t.asked.length, 1);

    // ② 同专辑的第二行出现（滚动）；URL 记忆 ⇒ 同一条 URL ⇒ 直接命缓存
    await tester.pumpWidget(
      _scope(
        container,
        Column(
          children: [
            SongRowCover(song: _albumSong, key: const Key('row-1')),
            SongRowCover(song: other, key: const Key('row-2')),
          ],
        ),
      ),
    );
    await _settle(tester);
    expect(t.asked.length, 1, reason: '同专辑 10 行不该打 10 次 NAS（URL 必须一样）');
    expect(t.asked.single, contains('album_name=00s+Love+Songs'));
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('DA230 ④ 没有专辑名 ⇒ 退回单曲封面', (tester) async {
    final t = _ScriptedTransport(imageFragments: const {'method=getsongcover'});
    const loose = AudioSongDto(
      id: 'music_9',
      title: 'Untitled',
      support: true,
    );
    await tester.pumpWidget(
      _host(SongRowCover(song: loose, key: const Key('row')), t),
    );
    await _settle(tester);

    expect(t.asked.single, contains('method=getsongcover'));
    expect(t.asked.single, contains('id=music_9'));
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('DA230 ⑤ 列表行接上了封面；选中态只打勾、不拉图', (tester) async {
    final t = _ScriptedTransport();
    await tester.pumpWidget(
      _host(
        AudioSongTile(song: _albumSong, onTap: () {}),
        t,
      ),
    );
    await _settle(tester);
    expect(
      find.byType(SongRowCover),
      findsOneWidget,
      reason: '单曲行的 leading 必须是封面（以前是同一个音符图标）',
    );
    expect(find.byType(Image), findsOneWidget);

    final before = t.asked.length;
    await tester.pumpWidget(
      _host(
        AudioSongTile(song: _albumSong, selected: true, onTap: () {}),
        t,
      ),
    );
    await _settle(tester);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byType(SongRowCover), findsNothing);
    expect(t.asked.length, before, reason: '多选态不该继续拉封面');
  });
}
