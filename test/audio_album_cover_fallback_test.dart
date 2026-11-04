// **`DA93`（r439）**：见 `audio_album_cover_test.dart` 文件头（专辑行不探歌曲级 ⇒ 有真封面也显示图标）。
//
// r439：`AudioCoverImage` 的**两级封面跳转** —— 主 URL（专辑级）取不到图时，
// 才去问 `resolveFallback`（逐首探 `getsongcover`），并且**每张专辑只问一次**。
//
// 为什么要在 widget 层再钉一遍（纯逻辑已由 `audio_album_cover_test.dart` 覆盖）：
// 跳转的触发点是 `AuthedImage` 的**失败回调**（"跑完但没图"才算失败），
// 而"加载中"与"失败"在 `FutureBuilder` 里长得很像 —— 这一层错了会表现成
// ① 一直闪烁探测（每次重建都重探）或 ② 永远不跳（占位图标）。两条都钉在这里。
import 'dart:convert';
import 'dart:typed_data';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_album_cover.dart';
import 'package:synhub/src/features/audio/audio_cover.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/files/file_thumb.dart' show looksLikeImage;
import 'package:synhub/src/features/media/authed_image.dart';
import 'package:synhub/src/core/theme/app_theme.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 真 PNG（能真解码）
final Uint8List kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

const kAlbumUrl = 'https://nas:5001/webapi/AudioStation/cover.cgi?method=getcover';
const kSongUrl = 'https://nas:5001/webapi/AudioStation/cover.cgi?method=getsongcover';

/// 按 URL 回不同字节（专辑级 = 404 的 HTML 正文；歌曲级 = 真 PNG）。
class _ScriptedTransport extends FakeTransport {
  _ScriptedTransport({this.imageFragments = const <String>{'method=getsongcover'}});

  /// 含这些片段的 URL 回真 PNG（**按片段**匹配：界面用的主 URL 是 API 拼出来的
  /// 真 URL，不是测试里的常量，按整串比会假红）
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
    // r427 真机形态：专辑级没有封面时回 **404 ＋ 11,939 B HTML**（不是空）
    return utf8.encode('<html><body><h1>404 Not Found</h1></body></html>');
  }
}

/// 与生产同构的解析器（probe 走同一个传输层 + 同一个"是不是图"判据 + 共享缓存）
AlbumCoverResolver _resolver(
  _ScriptedTransport t,
  AudioStationApi api, {
  int maxSongs = 1,
}) => AlbumCoverResolver(
  maxSongs: maxSongs,
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
  listSongs: (album, albumArtist) async => <AudioSongDto>[
    const AudioSongDto(id: 'music_1', title: 'song 1'),
  ],
  albumCoverUrl: (album, albumArtist) => kAlbumUrl,
  songCoverUrl: (song) => kSongUrl,
);

/// 与**生产接线同构**：解析器来自 provider，行上的 `resolveFallback` 走
/// `albumCoverFallbackOf`（`audio_page.dart` / `audio_detail_page.dart` 用的同一个助手）。
Widget _albumRow(
  _ScriptedTransport t,
  AlbumCoverResolver Function(_ScriptedTransport t, AudioStationApi api) build, {
  String name = '00s Love Songs',
  String albumArtist = 'Various Artists',
}) {
  final api = AudioStationApi(DsmWebApi(t));
  final resolver = build(t, api);
  final album = AudioAlbumDto(name: name, albumArtist: albumArtist);
  return _host(
    AudioCoverImage(
      key: const Key('album-cover'),
      identity: album.name,
      url: api.albumCoverUrl(album.name, albumArtist: album.albumArtist),
      resolveFallback: albumCoverFallbackOf(resolver, album),
      fallbackIcon: Icons.album_outlined,
    ),
    t,
    resolver: resolver,
  );
}

Widget _host(
  Widget child,
  _ScriptedTransport t, {
  AlbumCoverResolver? resolver,
}) {
  final api = AudioStationApi(DsmWebApi(t));
  final container = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(api),
      albumCoverResolverProvider.overrideWithValue(
        resolver ?? _resolver(t, api),
      ),
    ],
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child)),
  );
}

void main() {
  setUp(AuthedImageCache.reset);

  testWidgets('r439 专辑级不是图 ⇒ 跳到逐首探到的歌曲封面（真出 Image），共 2 次取字节', (tester) async {
    final t = _ScriptedTransport();
    await tester.pumpWidget(_albumRow(t, _resolver));
    await tester.pump(); // 主 URL 落地（HTML ⇒ 非图）
    await tester.pump(); // 回退解析器（探歌曲级）落地
    await tester.pump(); // setState 后新 URL 的 future 落地
    await tester.pump();
    expect(t.asked.length, 2, reason: '只该问这两次（专辑级 1 次 + 歌曲级 1 次）');
    expect(t.asked.first, contains('method=getcover'));
    expect(t.asked.first, contains('album_name=00s+Love+Songs'));
    expect(t.asked.last, kSongUrl, reason: '第二次必须是逐首探到的歌曲封面');
    expect(find.byIcon(Icons.album_outlined), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<MemoryImage>());
  });

  testWidgets('r439 **每张专辑只探一次**：重建/再 pump 不再打 NAS', (tester) async {
    final t = _ScriptedTransport();
    Widget tree() => _albumRow(t, _resolver);
    await tester.pumpWidget(tree());
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final after = t.asked.length;
    expect(after, 2);
    await tester.pumpWidget(tree()); // 同一个 identity 重建
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(t.asked.length, after, reason: '重建不该再探（否则滚动 = 反复打 NAS）');
  });

  testWidgets('r439 主 URL 就是真图 ⇒ **不**触发回退（不多付请求）', (tester) async {
    final t = _ScriptedTransport(imageFragments: {'method=getcover'});
    await tester.pumpWidget(
      _albumRow(t, _resolver, name: '示例专辑', albumArtist: '示例歌手'),
    );
    await tester.pump();
    await tester.pump();
    expect(t.asked.length, 1, reason: '主 URL 就是真图 ⇒ 不触发回退');
    expect(t.asked.single, contains('method=getcover'));
    expect(t.asked.single, contains('album_name=11'));
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('r439 逐首探也没有真图 ⇒ 停在占位图标，且不反复重试', (tester) async {
    final t = _ScriptedTransport(imageFragments: const <String>{});
    await tester.pumpWidget(
      _albumRow(t, _resolver, name: 'Aeneid Of Virgil', albumArtist: 'X'),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(t.asked.length, 2);
    expect(t.asked.last, kSongUrl);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.album_outlined), findsOneWidget);
  });

  group('③ 结构（防"接线被拿掉"）：专辑行的两级封面必须在**生产代码**里真的接着', () {
    /// 只认**声明**（`resolveFallback: albumCoverFallbackOf(`），不认注释里的字样
    /// （仪器122：认声明，不认子串）。
    void expectWired(String path) {
      final src = File(path).readAsStringSync();
      expect(
        src.contains('resolveFallback: albumCoverFallbackOf('),
        isTrue,
        reason: '$path 的专辑行必须接上逐首探回退',
      );
      expect(
        src.contains('ref.watch(albumCoverResolverProvider)'),
        isTrue,
        reason: '$path 必须从 provider 取解析器（而不是自己 new 一个）',
      );
    }

    test('专辑列表行的接线在位', () {
      expectWired('lib/src/features/audio/audio_page.dart');
    });

    test('"相关专辑"行的接线在位（原来是一个裸 Icon）', () {
      expectWired('lib/src/features/audio/audio_detail_page.dart');
      expect(
        File('lib/src/features/audio/audio_detail_page.dart')
            .readAsStringSync()
            .contains("leading: const Icon(Icons.album_outlined)"),
        isFalse,
        reason: '裸 Icon 会让"相关专辑"永远没有封面',
      );
    });
  });

  testWidgets('r439 没有解析器（未接线处）⇒ 行为与改前一致：图标 + 只问主 URL', (tester) async {
    final t = _ScriptedTransport();
    await tester.pumpWidget(
      _host(
        const AudioCoverImage(
          key: Key('album-cover'),
          identity: 'legacy',
          url: kAlbumUrl,
        ),
        t,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(t.asked.length, 1, reason: '没有解析器 ⇒ 行为与改前一致');
    expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
  });
}
