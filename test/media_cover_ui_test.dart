// 内嵌封面的**接线层 + UI** 离线测试（假传输，不打真服务端）。
//
// 两份事：
//  1. **只按 Range 取片段**：`mediaCoverProvider` 头段走 `maxBytes`（`bytes=0-N`）、
//     尾段走 `tailBytes`（`bytes=-N`），断言假传输上记录的就是这两个片段，
//     且请求数 ≤ 2（**绝不为了封面下载整文件**）；
//  2. **有封面 / 无封面两种渲染**：`MediaCoverImage` / `FileThumb` 有封面画图，
//     没封面退回 fallback / 分类图标（不显示破图）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_thumb.dart';
import 'package:synhub/src/features/media/media_cover.dart';
import 'package:synhub/src/features/media/media_cover_provider.dart';
import 'package:synhub/src/features/media/media_cover_view.dart';
import 'package:synhub/src/features/media/media_source.dart'
    show MediaKind;

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

List<int> _ascii(String s) => s.codeUnits;
List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];
List<int> _syncsafe(int v) => [
  (v >> 21) & 0x7F,
  (v >> 14) & 0x7F,
  (v >> 7) & 0x7F,
  v & 0x7F,
];

/// 最小 MP4：`ftyp + moov>udta>meta>ilst>covr>data(PNG)`
Uint8List _mp4WithCover() {
  List<int> box(String type, List<int> body) => [
    ..._be32(body.length + 8),
    ..._ascii(type),
    ...body,
  ];
  final data = box('data', [..._be32(14), ..._be32(0), ..._png]);
  final covr = box('covr', data);
  final ilst = box('ilst', covr);
  final meta = box('meta', [..._be32(0), ...ilst]);
  final udta = box('udta', meta);
  final moov = box('moov', udta);
  final ftyp = box('ftyp', [..._ascii('isom'), ..._be32(512)]);
  return Uint8List.fromList([...ftyp, ...moov]);
}

/// 最小 MP3：ID3v2.3 + APIC(PNG)
Uint8List _mp3WithCover() {
  final apic = [0x00, ..._ascii('image/png'), 0, 0x03, 0x00, ..._png];
  final frame = [..._ascii('APIC'), ..._be32(apic.length), 0, 0, ...apic];
  return Uint8List.fromList([
    ..._ascii('ID3'),
    3,
    0,
    0,
    ..._syncsafe(frame.length),
    ...frame,
  ]);
}

FileEntryDto _entry(String name, {int size = 1024, String? path}) =>
    FileEntryDto(
      name: name,
      path: path ?? '/home/$name',
      isDir: false,
      size: size,
      mtime: 1758100000,
    );

DsmWebApi _apiWith(FakeTransport transport) => DsmWebApi(transport);

void main() {
  setUp(clearMediaCoverCache);
  tearDown(clearMediaCoverCache);

  group('只按 Range 取片段（请求装配）', () {
    test('MP4：一次头段 + 一次尾段，绝不下载整文件', () async {
      final transport = FakeTransport(const {}, FakeTransport.table);
      transport.downloadBytes = _mp4WithCover();
      final api = _apiWith(transport);
      final uri =
          'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download'
          '&path=%2Fhome%2Fclip.mp4&_sid=SID';
      const fileSize = 10 * 1024 * 1024; // 10MB：片段必须远小于它
      final plan = mediaCoverRequestFor(
        kind: MediaKind.video,
        extension: 'mp4',
        fileSize: fileSize,
      );
      final container = ProviderContainer(
        overrides: [mediaCoverApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final key = MediaCoverKey(
        cacheKey: 'cover-test-mp4',
        uri: uri,
        kind: MediaKind.video,
        extension: 'mp4',
        fileSize: fileSize,
      );
      final cover = await container.read(mediaCoverProvider(key).future);
      expect(cover, isNotNull);
      // 头段用的就是建议的头读字节数；尾段用的就是建议的尾读字节数
      expect(transport.ranges, contains('$uri#${plan.prefixBytes}'));
      expect(transport.ranges, contains('$uri#tail=${plan.tailBytes}'));
      expect(transport.downloads.length, 2);
      expect(plan.totalBytes, lessThan(fileSize));
    });

    test('MP3：只发一次头段请求（不需要尾部）', () async {
      final transport = FakeTransport(const {}, FakeTransport.table);
      transport.downloadBytes = _mp3WithCover();
      final api = _apiWith(transport);
      const uri = 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download';
      const fileSize = 5 * 1024 * 1024;
      final plan = mediaCoverRequestFor(
        kind: MediaKind.audio,
        extension: 'mp3',
        fileSize: fileSize,
      );
      final container = ProviderContainer(
        overrides: [mediaCoverApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final key = MediaCoverKey(
        cacheKey: 'cover-test-mp3',
        uri: uri,
        kind: MediaKind.audio,
        extension: 'mp3',
        fileSize: fileSize,
      );
      final cover = await container.read(mediaCoverProvider(key).future);
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/png');
      expect(transport.ranges, ['$uri#${plan.prefixBytes}']);
      expect(transport.downloads.length, 1);
    });

    test('Drive（不支持 Range）→ 不取，连请求都不发', () async {
      final transport = FakeTransport(const {}, FakeTransport.table);
      transport.downloadBytes = _mp4WithCover();
      final api = _apiWith(transport);
      final container = ProviderContainer(
        overrides: [mediaCoverApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final key = const MediaCoverKey(
        cacheKey: 'cover-test-drive',
        uri: 'https://nas/webapi/entry.cgi?api=SYNO.SynologyDrive.Files',
        kind: MediaKind.audio,
        extension: 'mp3',
        rangeSupported: false,
      );
      final cover = await container.read(mediaCoverProvider(key).future);
      expect(cover, isNull);
      expect(transport.downloads, isEmpty);
    });

    test('缓存命中 → 不再发请求', () async {
      final transport = FakeTransport(const {}, FakeTransport.table);
      transport.downloadBytes = _mp3WithCover();
      final api = _apiWith(transport);
      final container = ProviderContainer(
        overrides: [mediaCoverApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      const key = MediaCoverKey(
        cacheKey: 'cover-cached',
        uri: 'https://nas/webapi/entry.cgi',
        kind: MediaKind.audio,
        extension: 'mp3',
      );
      mediaCoverCachePut(
        key.cacheKey,
        MediaCover(bytes: _png, mime: 'image/png', source: 'test'),
      );
      final cover = await container.read(mediaCoverProvider(key).future);
      expect(cover, isNotNull);
      expect(transport.downloads, isEmpty);
    });
  });

  group('MediaCoverImage：有封面 / 无封面', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('缓存里有封面 → 显示 Image，不显示 fallback', (tester) async {
      const key = MediaCoverKey(
        cacheKey: 'ui-cover',
        uri: 'https://nas/webapi/entry.cgi',
        kind: MediaKind.audio,
        extension: 'mp3',
      );
      mediaCoverCachePut(
        key.cacheKey,
        MediaCover(bytes: _png, mime: 'image/png', source: 'test'),
      );
      await pump(
        tester,
        const MediaCoverImage(
          request: key,
          width: 120,
          height: 120,
          fallback: Text('NO-COVER'),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('NO-COVER'), findsNothing);
    });

    testWidgets('没有封面 → 画 fallback，不留空白/破图', (tester) async {
      const key = MediaCoverKey(
        cacheKey: 'ui-no-cover',
        uri: 'https://nas/webapi/entry.cgi',
        kind: MediaKind.audio,
        extension: 'mp3',
      );
      // 没有覆盖 mediaCoverApiProvider：默认拿不到 API → null → fallback
      await pump(
        tester,
        const MediaCoverImage(
          request: key,
          width: 120,
          height: 120,
          fallback: Text('NO-COVER'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('NO-COVER'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('request 为 null（容器不支持）→ 直接 fallback', (tester) async {
      await pump(
        tester,
        const MediaCoverImage(request: null, fallback: Text('NO-COVER')),
      );
      expect(find.text('NO-COVER'), findsOneWidget);
    });

    testWidgets('MediaCoverBackdrop：无封面用黑底 fallback', (tester) async {
      await pump(
        tester,
        const MediaCoverBackdrop(
          request: null,
          fallback: ColoredBox(
            key: Key('poster-fallback'),
            color: Colors.black,
          ),
        ),
      );
      expect(find.byKey(const Key('poster-fallback')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('FileThumb：列表缩略图优先内嵌封面', () {
    Future<void> pumpThumb(
      WidgetTester tester,
      FileEntryDto entry, {
      required List<int> downloadBytes,
    }) async {
      final transport = FakeTransport(const {}, FakeTransport.table);
      transport.downloadBytes = downloadBytes;
      final api = _apiWith(transport);
      final container = ProviderContainer(
        overrides: [
          fileApiProvider.overrideWithValue(FileStationApi(api)),
          mediaCoverApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      // 无网速/无磁盘：FileThumb 对音频只用封面这条路
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Center(child: FileThumb(entry: entry, size: 40)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    testWidgets('mp3 有内嵌封面 → 显示封面图', (tester) async {
      await pumpThumb(
        tester,
        _entry('song.mp3'),
        downloadBytes: _mp3WithCover(),
      );
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('mp3 没有内嵌封面 → 退回分类图标（不显示破图）', (tester) async {
      await pumpThumb(
        tester,
        _entry('song.mp3'),
        downloadBytes: utf8.encode('not media at all'),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byType(Icon), findsWidgets);
    });
  });
}
