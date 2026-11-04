// **大 APIC（封面比预读更长）** 回归测试 —— 真机缺陷的正式用例。
//
// 背景（真机实测，别推翻）：真机 `/home/Music/CD1 - 01 - Track01.mp3` 有
// ID3v2.3 APIC，MIME 写作 `image/jpg`，图片 **2,103,578 字节**；旧逻辑只预读
// 512KB ⇒ 帧头找到了、图片被截断 ⇒ `extractMediaCoverFromHead` 返回 null
// ⇒ Files 列表只能退回音符图标。修法：**两段式**（先扫帧表，图片比预读长就
// 按图片的绝对区间再取一次），且仍然只读需要的字节。
//
// 夹具见 `support/media_cover_samples.dart`（真实 NAS 只读 Range 取回后剪裁）。
// 全部零网络、零设备：假传输 / 合成字节。
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/media/media_cover.dart';
import 'package:synhub/src/features/media/media_cover_provider.dart';
import 'package:synhub/src/features/media/media_source.dart'
    show MediaKind;

import 'support/chat_harness.dart' show FakeTransport;
import 'support/media_cover_samples.dart';

const String _uri =
    'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download'
    '&path=%2Fhome%2FCD1.mp3&_sid=SID';

DsmWebApi _apiWith(FakeTransport transport) => DsmWebApi(transport);

ProviderContainer _container({
  required DsmWebApi api,
  MediaCoverSegmentLoader? loader,
}) {
  final c = ProviderContainer(
    overrides: [
      mediaCoverApiProvider.overrideWithValue(api),
      if (loader != null)
        mediaCoverSegmentLoaderProvider.overrideWithValue(loader),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

MediaCoverKey _key({
  int fileSize = kRealApicFileSize,
  String extension = 'mp3',
  MediaKind kind = MediaKind.audio,
  String cacheKey = 'large-apic',
}) => MediaCoverKey(
  cacheKey: cacheKey,
  uri: _uri,
  kind: kind,
  extension: extension,
  fileSize: fileSize,
);

void main() {
  setUp(clearMediaCoverCache);
  tearDown(clearMediaCoverCache);

  group('真实样本：2.1MB APIC', () {
    test('① 完整夹具（2.11MB）→ 直接解出 JPEG，字节数与真机一致', () {
      final fixture = realApicFixture();
      expect(fixture.length, kRealApicFixtureBytes);
      final cover = extractMediaCover(
        MediaCoverBytes(prefix: fixture, fileSize: kRealApicFileSize),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/jpeg');
      expect(cover.bytes.length, kRealApicImageLength);
      expect(cover.source, 'id3v2.3/APIC');
      // 合法 JFIF JPEG 头（真机实测 ff d8 ff e0）
      expect(cover.bytes.sublist(0, 4), [0xFF, 0xD8, 0xFF, 0xE0]);
      // 完整夹具一次预读就够，不需要第二段
      final scan = scanMediaCover(
        MediaCoverBytes(prefix: fixture, fileSize: kRealApicFileSize),
        MediaKind.audio,
        'mp3',
      );
      expect(scan.found, isTrue);
      expect(scan.needsRange, isFalse);
    });

    test('② 只给 512KB（旧行为的模拟）→ 不再 null，而是报出图片绝对区间', () {
      final fixture = realApicFixture();
      final prefix = Uint8List.sublistView(
        fixture,
        0,
        kMediaCoverId3HeadBytes,
      );
      final scan = scanMediaCover(
        MediaCoverBytes(prefix: prefix, fileSize: kRealApicFileSize),
        MediaKind.audio,
        'mp3',
      );
      expect(scan.cover, isNull, reason: '旧逻辑到这就是 null');
      expect(scan.needsRange, isTrue);
      final range = scan.range!;
      expect(range.start, kRealApicImageStart);
      expect(range.end, kRealApicImageEnd);
      expect(range.length, kRealApicImageLength);
      expect(range.mimeHint, 'image/jpg');
      expect(range.source, 'id3v2.3/APIC');

      // 第二段到位后收口（段字节 = 夹具里那一段真实图片）
      final cover = finishMediaCoverRange(range, realApicImage());
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/jpeg');
      expect(cover.bytes.length, kRealApicImageLength);
      expect(cover.bytes.sublist(0, 4), [0xFF, 0xD8, 0xFF, 0xE0]);
    });

    test('②-b provider：512KB 预读后，假 fetcher 收到的恰是图片区间 [549,2104127)', () async {
      final fixture = realApicFixture();
      final transport = FakeTransport(const {}, FakeTransport.table)
        ..downloadBytes = fixture;
      final requested = <String>[];
      final container = _container(
        api: _apiWith(transport),
        loader: (uri, start, end) async {
          requested.add('$uri#$start-$end');
          expect(uri, _uri);
          return Uint8List.sublistView(fixture, start, end);
        },
      );
      final cover = await container.read(
        mediaCoverProvider(_key(cacheKey: 'large-apic-b')).future,
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/jpeg');
      expect(cover.bytes.length, kRealApicImageLength);
      // 第二段索要的 Range **恰好**是图片区间（不是"把头读拉大"）
      expect(requested, [
        '$_uri#$kRealApicImageStart-$kRealApicImageEnd',
      ]);
      // 第一段仍然只读了 512KB
      expect(transport.ranges, ['$_uri#$kMediaCoverId3HeadBytes']);
      expect(transport.downloads.length, 1);
    });

    test('②-c provider 生产接线：第二次对 API 要 end（bytes=0-N），总量远小于 8.7MB', () async {
      final fixture = realApicFixture();
      final transport = FakeTransport(const {}, FakeTransport.table)
        ..downloadBytes = fixture;
      final container = _container(api: _apiWith(transport));
      final key = _key(cacheKey: 'large-apic-c');
      final cover = await container.read(mediaCoverProvider(key).future);
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/jpeg');
      expect(cover.bytes.length, kRealApicImageLength);
      // 两次请求：512KB 预读 + 读到图片尾（生产 adapter 只能 bytes=0-N）
      expect(transport.ranges, [
        '$_uri#$kMediaCoverId3HeadBytes',
        '$_uri#$kRealApicImageEnd',
      ]);
      expect(transport.downloads.length, 2);
      final totalBytes =
          kMediaCoverId3HeadBytes + kRealApicImageEnd;
      expect(totalBytes, lessThan(kRealApicFileSize));
      expect(kRealApicImageEnd, lessThanOrEqualTo(kMediaCoverRangeMaxBytes));
    });
  });

  group('小封面（≤512KB）不许变成两次请求', () {
    test('③ 合成小 APIC → 一次预读就出封面，第二段 loader 一次都没被调', () {
      final mp3 = syntheticMp3WithApic(image: kTinyPng, mime: 'image/png');
      const fileSize = 5 * 1024 * 1024;
      final plan = mediaCoverRequestFor(
        kind: MediaKind.audio,
        extension: 'mp3',
        fileSize: fileSize,
      );
      expect(plan.totalBytes, kMediaCoverId3HeadBytes);
      expect(plan.totalBytes, lessThan(fileSize));

      final scan = scanMediaCover(
        MediaCoverBytes(prefix: mp3, fileSize: fileSize),
        MediaKind.audio,
        'mp3',
      );
      expect(scan.found, isTrue);
      expect(scan.needsRange, isFalse);
      expect(scan.cover!.mime, 'image/png');
      expect(scan.cover!.bytes.length, kTinyPng.length);
    });

    test('③-b provider：小 APIC 只发一次请求', () async {
      final mp3 = syntheticMp3WithApic(image: kTinyPng, mime: 'image/png');
      final transport = FakeTransport(const {}, FakeTransport.table)
        ..downloadBytes = mp3;
      var loaderCalls = 0;
      final container = _container(
        api: _apiWith(transport),
        loader: (uri, start, end) async {
          loaderCalls++;
          return null;
        },
      );
      final cover = await container.read(
        mediaCoverProvider(
          _key(fileSize: 5 * 1024 * 1024, cacheKey: 'small-once'),
        ).future,
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/png');
      expect(loaderCalls, 0, reason: '小封面不该触发第二段');
      expect(transport.downloads.length, 1);
      expect(transport.ranges, ['$_uri#$kMediaCoverId3HeadBytes']);
    });
  });

  group('超上限 / 脏数据：一律 null，不抛，也不发第二段', () {
    test('④ 声明长度 > 4MB 上限 → 不给区间；provider 只发一次请求就退图标', () async {
      // 帧体只写一点点，但帧头声明 5MB（> kMediaCoverRangeMaxBytes）
      final mp3 = syntheticMp3WithApic(
        image: kTinyPng,
        declaredFrameSize: 5 * 1024 * 1024,
      );
      const fileSize = 40 * 1024 * 1024;
      final scan = scanMediaCover(
        MediaCoverBytes(prefix: mp3, fileSize: fileSize),
        MediaKind.audio,
        'mp3',
      );
      expect(scan.cover, isNull);
      expect(scan.needsRange, isFalse, reason: '超过 4MB 上限不许发第二段');

      final transport = FakeTransport(const {}, FakeTransport.table)
        ..downloadBytes = mp3;
      var loaderCalls = 0;
      final container = _container(
        api: _apiWith(transport),
        loader: (uri, start, end) async {
          loaderCalls++;
          return null;
        },
      );
      final cover = await container.read(
        mediaCoverProvider(
          _key(fileSize: fileSize, cacheKey: 'over-cap'),
        ).future,
      );
      expect(cover, isNull);
      expect(loaderCalls, 0);
      expect(transport.downloads.length, 1);
    });

    test('⑤ 帧长度 = 0 → null，不抛', () {
      final mp3 = syntheticMp3WithApic(image: kTinyPng, declaredFrameSize: 0);
      final scan = scanMediaCover(
        MediaCoverBytes(prefix: mp3, fileSize: 5 * 1024 * 1024),
        MediaKind.audio,
        'mp3',
      );
      expect(scan.cover, isNull);
      expect(scan.needsRange, isFalse);
      expect(
        extractMediaCoverFromHead(mp3, MediaKind.audio, 'mp3'),
        isNull,
      );
    });

    test('⑤-b 帧长度巨大到越过文件尾 → null，不给区间', () {
      final mp3 = syntheticMp3WithApic(
        image: kTinyPng,
        declaredFrameSize: 0x0FFFFFFF,
      );
      final scan = scanMediaCover(
        // 文件只有 4MB，而帧声明 268MB
        MediaCoverBytes(prefix: mp3, fileSize: 4 * 1024 * 1024),
        MediaKind.audio,
        'mp3',
      );
      expect(scan.cover, isNull);
      expect(scan.needsRange, isFalse);
    });

    test('⑤-c v2.4 帧长度 syncsafe 非法（高位 1，等价"负数"）→ null，不抛', () {
      final mp3 = syntheticMp3WithBadSyncsafeFrame();
      final scan = scanMediaCover(
        MediaCoverBytes(prefix: mp3, fileSize: 5 * 1024 * 1024),
        MediaKind.audio,
        'mp3',
      );
      expect(scan.cover, isNull);
      expect(scan.needsRange, isFalse);
      expect(extractMediaCoverFromHead(mp3, MediaKind.audio, 'mp3'), isNull);
    });

    test('⑤-d 第二段长度对不上（服务端没给够）→ null，不喂半张图', () async {
      final fixture = realApicFixture();
      final transport = FakeTransport(const {}, FakeTransport.table)
        ..downloadBytes = fixture;
      final container = _container(
        api: _apiWith(transport),
        loader: (uri, start, end) async =>
            Uint8List.sublistView(fixture, start, end - 1), // 少 1 字节
      );
      final cover = await container.read(
        mediaCoverProvider(_key(cacheKey: 'short-segment')).future,
      );
      expect(cover, isNull);
    });

    test('⑤-e 第二段取字节抛异常 / 服务端 5xx → null，不抛', () async {
      final fixture = realApicFixture();
      final transport = FakeTransport(const {}, FakeTransport.table)
        ..downloadBytes = fixture;
      // 生产 adapter 走 api.getBytes：把该 URL 的第二段打失败
      transport.failures[_uri] = 500;
      final container = _container(api: _apiWith(transport));
      // 注意：失败注入对所有该 URL 请求生效 → 第一次预读就抛 → null
      final cover = await container.read(
        mediaCoverProvider(_key(cacheKey: 'server-500')).future,
      );
      expect(cover, isNull);

      final throwingTransport = FakeTransport(const {}, FakeTransport.table)
        ..downloadBytes = fixture;
      final throwing = _container(
        api: _apiWith(throwingTransport),
        loader: (uri, start, end) async => throw StateError('boom'),
      );
      final cover2 = await throwing.read(
        mediaCoverProvider(_key(cacheKey: 'loader-throw')).future,
      );
      expect(cover2, isNull);
    });
  });

  group('FLAC / MP4 同类坑（顺手修，同样两段式）', () {
    test('FLAC：picture 块比 512KB 预读长 → 报出图片区间并解出', () {
      // 650KB 的"图片"（头几个字节是合法 JPEG magic）
      final image = Uint8List.fromList(
        realApicImage().sublist(0, 650 * 1024),
      );
      final flac = syntheticFlacWithPicture(image: image);
      final fileSize = flac.length + 1024;
      final prefix = Uint8List.sublistView(
        flac,
        0,
        kMediaCoverId3HeadBytes,
      );
      final scan = scanMediaCover(
        MediaCoverBytes(prefix: prefix, fileSize: fileSize),
        MediaKind.audio,
        'flac',
      );
      expect(scan.cover, isNull);
      expect(scan.needsRange, isTrue);
      final range = scan.range!;
      // 区间必须**逐字节**对应图片数据
      expect(listEquals(flac.sublist(range.start, range.end), image), isTrue);
      final cover = finishMediaCoverRange(
        range,
        Uint8List.fromList(flac.sublist(range.start, range.end)),
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/jpeg');
      expect(cover.bytes.length, image.length);
    });

    test('MP4：moov 在头、covr 图片比 1MB 头段长 → 报出图片区间并解出', () {
      final image = Uint8List.fromList(
        realApicImage().sublist(0, 1500 * 1024),
      );
      final mp4 = syntheticMp4WithCover(image: image);
      final fileSize = mp4.length;
      expect(fileSize, greaterThan(4 * 1024 * 1024));
      final head = Uint8List.sublistView(mp4, 0, kMediaCoverMp4HeadBytes);
      final tail = Uint8List.sublistView(mp4, fileSize - kMediaCoverMp4TailBytes);
      final scan = scanMediaCover(
        MediaCoverBytes(prefix: head, tail: tail, fileSize: fileSize),
        MediaKind.video,
        'mp4',
      );
      expect(scan.cover, isNull);
      expect(scan.needsRange, isTrue);
      final range = scan.range!;
      expect(listEquals(mp4.sublist(range.start, range.end), image), isTrue);
      expect(range.end, lessThanOrEqualTo(kMediaCoverRangeMaxBytes));
      final cover = finishMediaCoverRange(
        range,
        Uint8List.fromList(mp4.sublist(range.start, range.end)),
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/jpeg');
      expect(cover.bytes.length, image.length);
    });
  });
}
