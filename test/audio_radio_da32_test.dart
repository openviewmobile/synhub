// 网络电台 **DA32**（第 392 轮修法）的离线验证。
//
// 事实来源：`docs/audio-radio-playback-contract.md`（官方 Web 前端源码逐字，
// 离线可复算；SPK sha256 见该文档 §0）：
//   * 展开参数是 **`container`**（不是 `type`；`type=player_source_*` 是文案 key）；
//     取值链 `null` → `SHOUTcast` → `SHOUTcast_<genre>` / `UserDefined` / `Favorite`；
//   * 叶子层电台项 `id` 前缀 `radio_` + 非空 `url`；
//   * SHOUTcast 的 `url` 是 **`.pls` 播放列表** ⇒ 起播前要先解析。
//
// 本文件覆盖（全部**离线**，假传输 + 假引擎 + 假 HTTP 出口）：
//   ① API 层：`container` 发/不发（含反向验证）；
//   ② 播放列表解析纯函数（`.pls` / `.m3u`，含**反向验证**：解析不出就返回 null）；
//   ③ `resolveRadioStreamUrl` 的四条分支（直连 / 解析成功 / 失败三态回落）；
//   ④ 页面动作级：点容器**进下一层**（请求带 `container`、标题用 `title`）；
//   ⑤ 页面动作级：点电台**真的起播**（引擎拿到的是**解析后的**流地址 + 元数据）；
//      ★ 反向验证：容器行**不给播放入口**。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_radio_relay.dart';
import 'package:synhub/src/features/audio/audio_radio_stream.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

/// AS 能力表（path/版本逐字取自真机 `SYNO.API.Info`；本文件只需要 Radio）。
Map<String, Map<String, dynamic>> da32Table() => {
  'SYNO.AudioStation.Info': {
    'path': 'AudioStation/info.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
  '$_as.Radio': {
    'path': 'AudioStation/radio.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 记录"真实 POST 打到了哪个 path"的假传输（FakeTransport 只记 params）。
class _PathTransport extends FakeTransport {
  _PathTransport(super.responses, super.apiTable);

  final List<({String path, Map<String, dynamic> params})> posted = [];

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) {
    posted.add((path: path, params: params));
    return super.postForm(path, params, module: module);
  }

  String pathFor(String api) =>
      posted.lastWhere((e) => e.params['api'] == api).path;
}

Map<String, dynamic> _callOf(_PathTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

Future<(AudioStationApi, _PathTransport)> _boot({
  Map<String, Map<String, dynamic>> responses = const {},
}) async {
  final t = _PathTransport(responses, {
    ...FakeTransport.table,
    ...da32Table(),
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (AudioStationApi(api), t);
}

// ─────────────────────────────────────────────────────────── 夹具

/// 根级容器（真机 `total=3` 的形状；`id` 是内部值，`title` 才上屏）。
Map<String, dynamic> radioRootContainers() => {
  'radios': [
    {
      'id': 'SHOUTcast',
      'title': 'SHOUTcast(TM)',
      'type': 'container',
      'url': '',
    },
    {
      'id': 'UserDefined',
      'title': 'User Defined',
      'type': 'container',
      'url': '',
    },
    {
      'id': 'Favorite',
      'title': 'My Favorite',
      'type': 'container',
      'url': '',
    },
  ],
  'total': 3,
};

/// `container=SHOUTcast` → **分类层**（id 前缀 `SHOUTcast_`，与分包
/// `etc/radio/shoutcast_<genre>.json` 的 26 个分类文件同源）。
Map<String, dynamic> radioShoutcastGenres() => {
  'radios': [
    {'id': 'SHOUTcast_Rock', 'title': 'Rock', 'type': 'container', 'url': ''},
    {'id': 'SHOUTcast_Jazz', 'title': 'Jazz', 'type': 'container', 'url': ''},
  ],
  'total': 2,
};

/// `container=SHOUTcast_Rock` → **可播电台项**（`id` 前缀 `radio_`）。
///
/// 第一条 `url` 逐字来自分包 `etc/radio/shoutcast_Rock.json`（`.pls` 播放列表）；
/// 第二条是裸流地址（用来验"非播放列表不发请求"）。
Map<String, dynamic> radioShoutcastStations() => {
  'radios': [
    {
      'id': 'radio_1280356',
      'title': '.977 The Hitz Channel',
      'type': 'station',
      'url': 'http://yp.shoutcast.com/sbin/tunein-station.pls?id=1280356',
      'desc': 'MP3 (128 kbps)',
    },
    {
      'id': 'radio_1281102',
      'title': '181.fm - The Eagle',
      'type': 'station',
      'url': 'http://stream.example.com:8000/live',
      'desc': 'MP3 (128 kbps)',
    },
  ],
  'total': 2,
};

// ─────────────────────────────────────────────────────────── 假件

/// 假引擎（只记"谁被送去播了"，与 `audio_page_test` 的 `_FakePlayer` 同形）。
class _RadioFakePlayer implements AudioStationPlayer {
  final played = <String>[];
  final playedQueues = <List<AudioQueueEntry>>[];
  final _changes = StreamController<void>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  bool _playing = false;
  String? _current;
  int _index = -1;
  List<AudioQueueEntry> _queue = const [];

  @override
  String? get currentUrl => _current;
  @override
  bool get playing => _playing;
  @override
  int get currentIndex => _index;
  @override
  int get queueLength => _queue.length;
  @override
  List<AudioQueueEntry> get queue => _queue;
  @override
  bool get shuffleEnabled => false;
  @override
  AudioRepeatMode get repeatMode => AudioRepeatMode.off;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  Future<void> play(String url) =>
      playQueue([AudioQueueEntry(id: url, url: url)]);

  @override
  Future<void> playQueue(
    List<AudioQueueEntry> entries, {
    int startIndex = 0,
  }) async {
    if (entries.isEmpty) return;
    playedQueues.add(entries);
    _queue = entries;
    _index = startIndex.clamp(0, entries.length - 1);
    _current = entries[_index].url;
    played.add(_current!);
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _changes.add(null);
  }

  @override
  Future<void> resume() async {
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _current = null;
    _index = -1;
    _changes.add(null);
  }

  @override
  Future<void> next() async {}
  @override
  Future<void> previous() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setShuffle(bool enabled) async {}
  @override
  Future<void> setRepeat(AudioRepeatMode mode) async {}
}

/// 假的播放列表 HTTP 出口（离线）。
class _FakeRadioHttp implements RadioStreamHttp {
  _FakeRadioHttp(this.body, {this.statusCode = 200, this.throwIt = false});

  final String body;
  final int statusCode;
  final bool throwIt;
  final List<Uri> asked = [];

  @override
  Future<RadioStreamHttpResponse> get(Uri uri) async {
    asked.add(uri);
    if (throwIt) throw const SocketException('boom');
    return RadioStreamHttpResponse(statusCode: statusCode, body: body);
  }
}

/// 假中继：只把"要不要绕"这一层换成确定值（真中继的行为另有单测）。
///
/// ★ 为什么 widget 用例不用真中继：真中继要 `HttpServer.bind`，
///   `flutter_test` 会在用例结束后判"还有 Timer 没结束"而红（与产品无关）。
class _FakeRelay implements RadioStreamRelay {
  _FakeRelay();

  final List<String> asked = [];

  @override
  Future<String> playableUrl(String url) async {
    asked.add(url);
    if (!needsCleartextRelay(url)) return url;
    return 'http://127.0.0.1:1/r/tok?u=${Uri.encodeQueryComponent(url)}';
  }
}

/// 起一个可播的电台页（假引擎 + 可注入 HTTP 出口），返回记录器。
Future<({_PathTransport t, ProviderContainer c, _RadioFakePlayer player})>
_pumpRadioPlayable(
  WidgetTester tester, {
  required Map<String, Map<String, dynamic>> responses,
  RadioStreamHttp? http,
  RadioStreamRelay? relay,
  String? container,
  String? titleOverride,
  Map<String, dynamic>? Function(Map<String, dynamic> params)? onCall,
}) async {
  final t = _PathTransport(responses, {
    ...FakeTransport.table,
    ...da32Table(),
  });
  t.onCall = onCall;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final player = _RadioFakePlayer();
  final c = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(api)),
      audioStationPlayerProvider.overrideWithValue(player),
      if (http != null) radioStreamHttpProvider.overrideWithValue(http),
      radioStreamRelayProvider.overrideWithValue(
        relay ?? const NoopRadioStreamRelay(),
      ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: AudioRadioPage(
          container: container,
          titleOverride: titleOverride,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c, player: player);
}

void main() {
  group('DA32 · 容器展开参数是 container（不是 type）', () {
    test('listRadios(container:) 只发 container；path 仍是 radio.cgi', () async {
      final (audio, t) = await _boot(
        responses: {'$_as.Radio.list': radioShoutcastGenres()},
      );
      final page = await audio.listRadios(container: 'SHOUTcast');
      final call = _callOf(t, '$_as.Radio', 'list');
      expect(call['container'], 'SHOUTcast');
      expect(call.containsKey('type'), isFalse);
      expect(call.containsKey('keyword'), isFalse);
      expect(t.pathFor('$_as.Radio'), 'AudioStation/radio.cgi');
      expect(page.items.first.id, 'SHOUTcast_Rock');
      expect(page.items.first.isContainer, isTrue);
    });

    test('反向验证：container 为空串 → 该参数不发（不臆造默认值）', () async {
      final (audio, t) = await _boot(
        responses: {'$_as.Radio.list': radioRootContainers()},
      );
      await audio.listRadios(container: '');
      final call = _callOf(t, '$_as.Radio', 'list');
      expect(call.containsKey('container'), isFalse);
    });

    test('叶子层电台项：id 前缀 radio_ + 非空 url；容器不是电台项', () async {
      final (audio, _) = await _boot(
        responses: {'$_as.Radio.list': radioShoutcastStations()},
      );
      final page = await audio.listRadios(container: 'SHOUTcast_Rock');
      expect(page.items.length, 2);
      expect(page.items.first.isContainer, isFalse);
      expect(page.items.first.isStation, isTrue);
      expect(page.items.first.hasStreamUrl, isTrue);
      // 反向：容器（id `SHOUTcast`，无 url）绝不能被当成可播项
      final container = AudioRadioDto.fromJson(const {
        'id': 'SHOUTcast',
        'title': 'SHOUTcast(TM)',
        'type': 'container',
        'url': '',
      });
      expect(container.isStation, isFalse);
      expect(container.hasStreamUrl, isFalse);
    });
  });

  group('DA32 · 播放列表解析（.pls / .m3u）', () {
    test('isPlaylistUrl：只看路径后缀（查询串不影响）', () {
      expect(isPlaylistUrl('http://h/sbin/tunein-station.pls?id=1'), isTrue);
      expect(isPlaylistUrl('http://h/x.M3U'), isTrue);
      expect(isPlaylistUrl('http://h/a/b.m3u8'), isTrue);
      // 反向：普通流地址不是播放列表
      expect(isPlaylistUrl('http://h:8000/live'), isFalse);
      expect(isPlaylistUrl('http://h/song.mp3'), isFalse);
      expect(isPlaylistUrl(''), isFalse);
    });

    test('.pls：File1= 才是地址（Title1/NumberOfEntries 不算）', () {
      const body = '[playlist]\n'
          'NumberOfEntries=1\n'
          'File1=http://stream.example.com:8000/live\n'
          'Title1=Some Station\n'
          'Length1=-1\n'
          'Version=2\n';
      expect(
        parsePlaylistStreamUrl(body, baseUrl: 'http://yp/x.pls'),
        'http://stream.example.com:8000/live',
      );
    });

    test('.pls：键名大小写不敏感 + 引号剥掉 + 相对地址按自身解析', () {
      expect(
        parsePlaylistStreamUrl(
          'file1="/live"\n',
          baseUrl: 'http://h:8000/x.pls',
        ),
        'http://h:8000/live',
      );
      expect(
        parsePlaylistStreamUrl('File1=liveset\n', baseUrl: 'http://h:8000/x.pls'),
        'http://h:8000/liveset',
      );
    });

    test('.m3u：跳过 # 注释，取第一条裸地址（不是第二条）', () {
      const body = '#EXTM3U\n'
          '#EXTINF:-1,Jazz\n'
          'http://h:8000/jazz\n'
          'http://h:8000/alt\n';
      expect(
        parsePlaylistStreamUrl(body, baseUrl: 'http://h/x.m3u'),
        'http://h:8000/jazz',
      );
    });

    test('反向验证：解析不出可用地址 → null（不许当成能播）', () {
      expect(parsePlaylistStreamUrl('', baseUrl: 'http://h/x.pls'), isNull);
      expect(
        parsePlaylistStreamUrl(
          '[playlist]\nTitle1=only\n',
          baseUrl: 'http://h/x.pls',
        ),
        isNull,
      );
      expect(
        parsePlaylistStreamUrl(
          '#EXTM3U\n#EXTINF:-1,none\n',
          baseUrl: 'http://h/x.m3u',
        ),
        isNull,
      );
    });

    test('resolve：非播放列表 → 原样返回且一次网络都不打', () async {
      final http = _FakeRadioHttp('File1=http://x/y');
      final res = await resolveRadioStreamUrl(
        'http://h:8000/live',
        http: http,
      );
      expect(res.url, 'http://h:8000/live');
      expect(res.resolvedFromPlaylist, isFalse);
      expect(http.asked, isEmpty, reason: '非播放列表不该发请求');
    });

    test('resolve：.pls 200 → 用解析出的流地址起播', () async {
      final http = _FakeRadioHttp('File1=http://h:8000/live\n');
      final res = await resolveRadioStreamUrl('http://yp/x.pls', http: http);
      expect(res.url, 'http://h:8000/live');
      expect(res.resolvedFromPlaylist, isTrue);
      expect(http.asked.single.toString(), 'http://yp/x.pls');
    });

    test('resolve：失败三态都回落原地址并给出可读原因', () async {
      final notFound = await resolveRadioStreamUrl(
        'http://yp/x.pls',
        http: _FakeRadioHttp('nope', statusCode: 404),
      );
      expect(notFound.url, 'http://yp/x.pls');
      expect(notFound.resolvedFromPlaylist, isFalse);
      expect(notFound.note, 'http-404');

      final empty = await resolveRadioStreamUrl(
        'http://yp/x.pls',
        http: _FakeRadioHttp('[playlist]\nTitle1=x\n'),
      );
      expect(empty.url, 'http://yp/x.pls');
      expect(empty.note, 'no-stream-in-playlist');

      final boom = await resolveRadioStreamUrl(
        'http://yp/x.pls',
        http: _FakeRadioHttp('', throwIt: true),
      );
      expect(boom.url, 'http://yp/x.pls');
      expect(boom.note, 'error');
    });
  });

  group('DA32 · 页面动作级（离线）：点容器进下一层', () {
    testWidgets('点根级容器 → 请求带 container=SHOUTcast，标题用 title 不上 id', (
      tester,
    ) async {
      final r = await _pumpRadioPlayable(
        tester,
        responses: {'$_as.Radio.list': radioRootContainers()},
        onCall: (params) =>
            params['container'] == 'SHOUTcast' ? radioShoutcastGenres() : null,
      );
      expect(find.text('SHOUTcast(TM)'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('as-radio-container-tile-SHOUTcast')),
      );
      await tester.pumpAndSettle();

      final opened = r.t.calls
          .where((c) => c['container'] == 'SHOUTcast')
          .toList();
      expect(opened, isNotEmpty, reason: '进下一层必须带 container=SHOUTcast');
      // 第二页标题 = 上级的 title（不是内部 id `SHOUTcast` 裸串）
      expect(find.text('SHOUTcast(TM)'), findsOneWidget);
      expect(find.text('Rock'), findsOneWidget);
      expect(find.text('Jazz'), findsOneWidget);
    });
  });

  group('DA32 · 页面动作级（离线）：点电台真的起播', () {
    testWidgets('裸流地址：点击 → 引擎拿到同一个 URL（不发播放列表请求）', (tester) async {
      final http = _FakeRadioHttp('File1=http://should-not-be-used');
      final r = await _pumpRadioPlayable(
        tester,
        responses: {'$_as.Radio.list': radioShoutcastStations()},
        container: 'SHOUTcast_Rock',
        titleOverride: 'Rock',
        http: http,
      );
      expect(find.text('181.fm - The Eagle'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_1281102')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(r.player.played, ['http://stream.example.com:8000/live']);
      expect(http.asked, isEmpty, reason: '裸流地址不该去取播放列表');
    });

    testWidgets('.pls 电台：点击 → 先解析播放列表，再用解析出的地址起播（含元数据）', (
      tester,
    ) async {
      final http = _FakeRadioHttp('File1=http://h:8000/live\n');
      final r = await _pumpRadioPlayable(
        tester,
        responses: {'$_as.Radio.list': radioShoutcastStations()},
        container: 'SHOUTcast_Rock',
        titleOverride: 'Rock',
        http: http,
      );
      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_1280356')),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(http.asked.single.toString(),
          'http://yp.shoutcast.com/sbin/tunein-station.pls?id=1280356');
      expect(r.player.played, ['http://h:8000/live']);
      // 队列里的元数据来自电台项本身（标题/描述），不是 URL
      final entry = r.player.playedQueues.single.single;
      expect(entry.id, 'radio_1280356');
      expect(entry.title, '.977 The Hitz Channel');
    });

    testWidgets('反向验证：容器行不给播放入口（点它只会进下一层）', (tester) async {
      final r = await _pumpRadioPlayable(
        tester,
        responses: {'$_as.Radio.list': radioRootContainers()},
      );
      await tester.tap(
        find.byKey(const Key('as-radio-container-tile-UserDefined')),
      );
      await tester.pumpAndSettle();
      expect(
        r.player.played,
        isEmpty,
        reason: '容器不是电台项，绝不能被当成能播的',
      );
    });
  });

  group('DA32 · 明文流回环中继（Android release 策略下的唯一通路）', () {
    test('needsCleartextRelay：只有"明文 + 非回环"才要绕', () {
      expect(needsCleartextRelay('http://50.31.185.139/1005'), isTrue);
      // 反向：https 不绕（走系统信任链）
      expect(needsCleartextRelay('https://h/live'), isFalse);
      // 反向：回环不绕（策略本来就允许；绕了会自环）
      expect(needsCleartextRelay('http://127.0.0.1:8899/x.mp3'), isFalse);
      expect(needsCleartextRelay('http://localhost:8899/x.mp3'), isFalse);
      // 反向：不是 http 的都不绕
      expect(needsCleartextRelay('file:///sdcard/a.mp3'), isFalse);
      expect(needsCleartextRelay(''), isFalse);
    });

    test('Noop 中继：原样返回（不真起服务）', () async {
      const r = NoopRadioStreamRelay();
      expect(await r.playableUrl('http://h/live'), 'http://h/live');
    });

    test('真中继：https/回环原样返回；明文改成回环地址（带随机 token）', () async {
      final relay = LoopbackRadioStreamRelay();
      addTearDown(relay.close);
      expect(await relay.playableUrl('https://h/live'), 'https://h/live');
      final out = await relay.playableUrl('http://50.31.185.139/1005');
      expect(out.startsWith('http://127.0.0.1:${relay.port}/r/'), isTrue);
      expect(out.contains('u=http%3A%2F%2F50.31.185.139%2F1005'), isTrue);
      expect(relay.token, hasLength(32));
    });

    // ★ 安全边界（等价于"反向验证"）：token / 目标协议 / 回环目标三类都必须被拒。
    test('parseRelayRoute：错 token ⇒ notFound；非 http(s)/无 u/回环目标 ⇒ badRequest', () {
      final ok = LoopbackRadioStreamRelay.parseRelayRoute(
        path: '/r/abc123',
        query: const {'u': 'http://50.31.185.139/1005'},
        token: 'abc123',
      );
      expect(ok.target.toString(), 'http://50.31.185.139/1005');
      expect(ok.error, isEmpty);

      // ① 路径/token 不对（其它 App 猜不到 token ⇒ 404）
      for (final t in const ['', 'deadbeef', null]) {
        final r = LoopbackRadioStreamRelay.parseRelayRoute(
          path: '/r/abc123',
          query: const {'u': 'http://8.8.8.8/x'},
          token: t,
        );
        expect(r.target, isNull);
        expect(r.error, 'notFound');
      }
      final wrongPath = LoopbackRadioStreamRelay.parseRelayRoute(
        path: '/r/other',
        query: const {'u': 'http://8.8.8.8/x'},
        token: 'abc123',
      );
      expect(wrongPath.error, 'notFound');

      // ② 目标协议白名单（`file:` 不许读本机文件）与缺参
      for (final q in const [
        {'u': 'file:///etc/hosts'},
        {'u': 'ftp://8.8.8.8/x'},
        <String, String>{},
      ]) {
        final r = LoopbackRadioStreamRelay.parseRelayRoute(
          path: '/r/abc123',
          query: q,
          token: 'abc123',
        );
        expect(r.target, isNull);
        expect(r.error, 'badRequest');
      }

      // ③ 不许把回环当上游（防自环 / 防被当成读本机服务的手）
      for (final u in const ['http://127.0.0.1:8899/x', 'http://localhost/x']) {
        final r = LoopbackRadioStreamRelay.parseRelayRoute(
          path: '/r/abc123',
          query: {'u': u},
          token: 'abc123',
        );
        expect(r.target, isNull);
        expect(r.error, 'badRequest');
      }
    });

    testWidgets('页面：明文站起播时引擎拿到的是**中继后地址**，不是原始公网地址', (
      tester,
    ) async {
      final relay = _FakeRelay();
      final r = await _pumpRadioPlayable(
        tester,
        responses: {'$_as.Radio.list': radioShoutcastStations()},
        container: 'SHOUTcast_Rock',
        titleOverride: 'Rock',
        relay: relay,
        http: _FakeRadioHttp('File1=http://50.31.185.139/1005\n'),
      );
      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_1280356')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      // 解析出的明文地址**先进中继**（`relay.asked` 里是解析后的地址）
      expect(relay.asked.single, 'http://50.31.185.139/1005');
      expect(
        r.player.played.single,
        'http://127.0.0.1:1/r/tok'
        '?u=${Uri.encodeQueryComponent('http://50.31.185.139/1005')}',
      );
    });

    testWidgets('反向验证：https 站**不绕**中继（引擎拿到原地址）', (tester) async {
      final relay = _FakeRelay();
      final r = await _pumpRadioPlayable(
        tester,
        responses: {
          '$_as.Radio.list': {
            'radios': [
              {
                'id': 'radio_https',
                'title': 'Secure Station',
                'type': 'station',
                'url': 'https://secure.example.com/live',
                'desc': 'MP3',
              },
            ],
            'total': 1,
          },
        },
        container: 'SHOUTcast_Rock',
        relay: relay,
      );
      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_https')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(relay.asked, ['https://secure.example.com/live']);
      expect(r.player.played, ['https://secure.example.com/live']);
    });
  });
}
