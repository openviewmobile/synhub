// 内嵌封面**失败负缓存 + TTL** 的机制量回归（§2.0.30②：只数"发起了几次请求"）。
//
// 语义先例：`video_frame_thumb.dart` 的 `kVideoFrameNegativeTtl` / `_rememberFailure`。
// 分野（r132）：负缓存只记"**这个文件抓不出来**"（发过请求、解析不出/网络失败）；
// "**这台机器/这条路做不了**"（无会话 api / kind 不支持 / Drive 无 Range）
// 在发起请求前返回，**不进**失败表 ⇒ 行为不变。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/media/media_cover.dart';
import 'package:synhub/src/features/media/media_cover_provider.dart';
import 'package:synhub/src/features/media/media_source.dart' show MediaKind;

import 'support/chat_harness.dart' show FakeTransport;

const String _uri =
    'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download';
const int _fileSize = 5 * 1024 * 1024;

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

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 最小 MP3：ID3v2.3 + APIC(PNG) —— 抓得出来
List<int> _mp3WithCover() {
  final apic = [0x00, ..._ascii('image/png'), 0, 0x03, 0x00, ..._png];
  final frame = [..._ascii('APIC'), ..._be32(apic.length), 0, 0, ...apic];
  return [
    ..._ascii('ID3'),
    3,
    0,
    0,
    ..._syncsafe(frame.length),
    ...frame,
  ];
}

/// 明确不是图片 ⇒ 单文件抓不出来（不是能力不足）
final _notAnImage = utf8.encode('this-is-not-an-image-payload-0123456789');

MediaCoverKey _key(String id) => MediaCoverKey(
  cacheKey: 'neg-$id',
  uri: _uri,
  kind: MediaKind.audio,
  extension: 'mp3',
  fileSize: _fileSize,
);

/// 一个"重建周期" = 全新容器（上一帧 autoDispose 已回收、本帧重新构建）。
Future<MediaCover?> _rebuild(
  FakeTransport t,
  MediaCoverKey key, {
  bool apiAvailable = true,
}) async {
  final c = ProviderContainer(
    overrides: [
      mediaCoverApiProvider.overrideWithValue(
        apiAvailable ? DsmWebApi(t) : null,
      ),
    ],
  );
  try {
    return await c.read(mediaCoverProvider(key).future);
  } finally {
    c.dispose();
  }
}

void main() {
  var now = DateTime.utc(2026, 1, 1);

  setUp(() {
    clearMediaCoverCache();
    mediaCoverNow = () => now;
  });
  tearDown(() {
    mediaCoverNow = DateTime.now;
    clearMediaCoverCache();
  });

  test('① 失败后 TTL 内 5 次重建 ⇒ 只发起 1 次请求', () async {
    final t = FakeTransport(const {}, FakeTransport.table)
      ..downloadBytes = _notAnImage;
    final key = _key('a');

    MediaCover? last;
    for (var i = 0; i < 5; i++) {
      last = await _rebuild(t, key);
    }
    expect(last, isNull);
    // 机制量：请求发起次数 —— 5 次重建只应留下第一次的 1 次
    expect(t.downloads.length, 1);
    expect(mediaCoverFailureRemembered(key.cacheKey), isTrue);
  });

  test('② TTL 过后 ⇒ 允许重试（请求数 +1）', () async {
    final t = FakeTransport(const {}, FakeTransport.table)
      ..downloadBytes = _notAnImage;
    final key = _key('b');

    await _rebuild(t, key);
    expect(t.downloads.length, 1);
    // TTL 内：不再发
    await _rebuild(t, key);
    expect(t.downloads.length, 1);
    // 越过 TTL：允许重试
    now = now.add(kMediaCoverNegativeTtl + const Duration(seconds: 1));
    await _rebuild(t, key);
    expect(t.downloads.length, 2);
    expect(mediaCoverFailureRemembered(key.cacheKey), isTrue);
  });

  test('③ 成功路径行为不变：成功命中后 4 次重建 ⇒ 0 次新请求', () async {
    final t = FakeTransport(const {}, FakeTransport.table)
      ..downloadBytes = _mp3WithCover();
    final key = _key('c');

    final first = await _rebuild(t, key);
    expect(first, isNotNull);
    expect(t.downloads.length, 1);
    for (var i = 0; i < 4; i++) {
      final again = await _rebuild(t, key);
      expect(again, isNotNull);
    }
    // 成功缓存照旧生效：仍是第一次那 1 次，没有新请求
    expect(t.downloads.length, 1);
    expect(mediaCoverFailureRemembered(key.cacheKey), isFalse);
  });

  test('④ 通路不可用（Drive 无 Range）⇒ 0 请求且不进失败表（r132 分野）', () async {
    final t = FakeTransport(const {}, FakeTransport.table)
      ..downloadBytes = _notAnImage;
    const key = MediaCoverKey(
      cacheKey: 'neg-drive',
      uri: _uri,
      kind: MediaKind.audio,
      extension: 'mp3',
      fileSize: _fileSize,
      rangeSupported: false,
    );
    for (var i = 0; i < 5; i++) {
      expect(await _rebuild(t, key), isNull);
    }
    expect(t.downloads, isEmpty);
    // "这条路做不了"不记失败
    expect(debugMediaCoverFailureKeys(), isEmpty);
  });

  test('⑤ 无会话 api（能力不可用）⇒ 0 请求且不进失败表', () async {
    final t = FakeTransport(const {}, FakeTransport.table);
    final key = _key('e');
    for (var i = 0; i < 5; i++) {
      expect(await _rebuild(t, key, apiAvailable: false), isNull);
    }
    expect(t.downloads, isEmpty);
    expect(debugMediaCoverFailureKeys(), isEmpty);
  });

  test('⑥ 清缓存/登出同时清负缓存', () async {
    final t = FakeTransport(const {}, FakeTransport.table)
      ..downloadBytes = _notAnImage;
    final key = _key('f');
    await _rebuild(t, key);
    expect(mediaCoverFailureRemembered(key.cacheKey), isTrue);
    clearMediaCoverCache();
    expect(mediaCoverFailureRemembered(key.cacheKey), isFalse);
    expect(debugMediaCoverFailureKeys(), isEmpty);
  });
}
