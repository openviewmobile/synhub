// **r441** · 网络电台「关键字搜台」的离线验证（`DA95`）。
//
// 事实来源（**只读取证**，`tool/r441_radio_search_probe_test.dart` 在真 NAS 上逐条量出）：
//   * `Radio.list` **完全忽略** `keyword`（`keyword=Jazz` 与无参逐字同：3 条根层容器、total=3）；
//   * `Radio.search` **只有 v2**（v1 ⇒ `103`），参数名是 **`keyword`**（必填：无参 ⇒ `101`；
//     `text=` ⇒ `101`）；**必须显式给 `offset/limit`**（不给 ⇒ `radios: []`、`total` 照给）；
//   * `container` 被服务端忽略（同结果、更慢）⇒ 不发。
//
// 本文件覆盖（全部**离线**：假传输 + 假引擎）：
//   ① API 层：`searchRadios` 的线参／版本；`listRadios` **不再有** `keyword`（反向）；
//   ② 页面动作级：根层有搜索入口、**分类层没有**（反向）；
//   ③ 输入关键字提交 ⇒ **只发 `Radio.search`**，`list` 一次都不发；
//   ④ 空关键字 ⇒ **零请求**（服务端会 `101`，不许把"清空输入框"当成"搜全部"）；
//   ⑤ v1-only 服务器 ⇒ 如实"不支持"空态 ＋ **零请求**（不发注定 `103` 的请求）；
//   ⑥ 搜索结果行的收藏写动词仍走 `container=Favorite`（与列表页**同一条**路径）；
//   ⑦ 结构性守卫（仪器122：钉**声明**）：搜索必须经 `searchRadios`，不许再往 `list` 塞关键字。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_radio_relay.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

/// AS 能力表：`Radio` 给到 v2（真机形状）。`radioMaxVersion` 用来造 v1-only 的对照。
Map<String, Map<String, dynamic>> _table({int radioMaxVersion = 2}) => {
  'SYNO.AudioStation.Info': {
    'path': 'AudioStation/info.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
  '$_as.Radio': {
    'path': 'AudioStation/radio.cgi',
    'minVersion': 1,
    'maxVersion': radioMaxVersion,
  },
};

/// 记录真实 POST path 的假传输（`FakeTransport` 只记 params）。
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
}

Map<String, dynamic> _callOf(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

int _countOf(FakeTransport t, String api, String method) =>
    t.calls.where((c) => c['api'] == api && c['method'] == method).length;

Future<(AudioStationApi, _PathTransport)> _boot({
  Map<String, Map<String, dynamic>> responses = const {},
  int radioMaxVersion = 2,
}) async {
  final t = _PathTransport(responses, {
    ...FakeTransport.table,
    ..._table(radioMaxVersion: radioMaxVersion),
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (AudioStationApi(api), t);
}

// ─────────────────────────────────────────────────────────── 夹具（逐字取自真机）

/// 根层容器（真机 `total=3`）。
Map<String, dynamic> rootContainers() => {
  'radios': [
    {'id': 'SHOUTcast', 'title': 'SHOUTcast(TM)', 'type': 'container', 'url': ''},
    {'id': 'UserDefined', 'title': 'User Defined', 'type': 'container', 'url': ''},
    {'id': 'Favorite', 'title': 'My Favorite', 'type': 'container', 'url': ''},
  ],
  'total': 3,
};

/// 搜索命中（**逐字取自 r441 真机回包**：`id` 前缀 `radio_` ＋ `url` 有值 ＋
/// `desc` 是码率；`total` 是服务端封顶值 500）。
Map<String, dynamic> searchHits() => {
  'radios': [
    {
      'id': 'radio_BEST SMOOTH JAZZ  - UK (LONDON) HOST ROD LUCAS '
          'http://yp.shoutcast.com/sbin/tunein-station.pls?id=99426190',
      'title': 'BEST SMOOTH JAZZ  - UK (LONDON) HOST ROD LUCAS',
      'type': 'station',
      'url': 'http://yp.shoutcast.com/sbin/tunein-station.pls?id=99426190',
      'desc': 'MP3 (128 kbps)',
    },
    {
      'id': 'radio_Smooth Jazz Florida Worldwide '
          'http://yp.shoutcast.com/sbin/tunein-station.pls?id=99536742',
      'title': 'Smooth Jazz Florida Worldwide',
      'type': 'station',
      'url': 'http://yp.shoutcast.com/sbin/tunein-station.pls?id=99536742',
      'desc': 'MP3 (128 kbps)',
    },
  ],
  'total': 500,
};

// ─────────────────────────────────────────────────────────── 假引擎

class _FakePlayer implements AudioStationPlayer {
  final _changes = StreamController<void>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  List<AudioQueueEntry> _queue = const [];
  bool _playing = false;
  String? _current;

  @override
  String? get currentUrl => _current;
  @override
  bool get playing => _playing;
  @override
  int get currentIndex => _queue.isEmpty ? -1 : 0;
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
  Future<void> play(String url) async {}
  @override
  Future<void> playQueue(
    List<AudioQueueEntry> entries, {
    int startIndex = 0,
  }) async {
    _queue = entries;
    _current = entries.isEmpty ? null : entries.first.url;
    _playing = entries.isNotEmpty;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
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

/// 起一个电台页（或直接起搜索页），返回传输记录器。
Future<({_PathTransport t, ProviderContainer c})> _pumpRadio(
  WidgetTester tester, {
  required Map<String, Map<String, dynamic>> responses,
  int radioMaxVersion = 2,
  String? container,
  Widget? home,
}) async {
  final t = _PathTransport(responses, {
    ...FakeTransport.table,
    ..._table(radioMaxVersion: radioMaxVersion),
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final c = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(api)),
      audioStationPlayerProvider.overrideWithValue(_FakePlayer()),
      radioStreamRelayProvider.overrideWithValue(const NoopRadioStreamRelay()),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home:
            home ??
            AudioRadioPage(container: container, titleOverride: '电台'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c);
}

Future<void> _search(WidgetTester tester, String keyword) async {
  await tester.enterText(
    find.byKey(const Key('as-radio-search-field')),
    keyword,
  );
  await tester.tap(find.byKey(const Key('as-radio-search-go')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('r441 · API 层（Radio.search 的线参与版本）', () {
    test('① searchRadios 发 search/v2 + keyword + 显式 offset/limit；不带 container', () async {
      final (audio, t) = await _boot(
        responses: {'$_as.Radio.search': searchHits()},
      );
      final page = await audio.searchRadios(keyword: 'Jazz', offset: 0, limit: 5);

      final call = _callOf(t, '$_as.Radio', 'search');
      expect(call['version'], '2');
      expect(call['keyword'], 'Jazz');
      expect(call['offset'], 0);
      expect(call['limit'], 5);
      expect(
        call.containsKey('container'),
        isFalse,
        reason: '真机实测 container 被服务端忽略（同结果、更慢）⇒ 不许发',
      );
      expect(page.total, 500, reason: 'total 是服务端给的命中数（封顶 500）');
      expect(page.items.length, 2);
      expect(page.items.first.isStation, isTrue);
      expect(page.items.first.hasStreamUrl, isTrue);
      expect(page.items.first.desc, 'MP3 (128 kbps)');
      // 真机回包：`id` 里带 URL，但**上屏只用 `title`**；`url` 字段是独立字段。
      expect(page.items.first.url, contains('tunein-station.pls?id=99426190'));
    });

    test('② 反向：listRadios **没有** keyword 这条路（服务端忽略 ⇒ 参数已删）', () async {
      final (audio, t) = await _boot(
        responses: {'$_as.Radio.list': rootContainers()},
      );
      await audio.listRadios();
      final call = _callOf(t, '$_as.Radio', 'list');
      expect(call['version'], '2');
      expect(call.containsKey('keyword'), isFalse);
      expect(call.containsKey('text'), isFalse);
    });

    test('③ 控制器分派：keyword 非空 ⇒ 只发 search；为空 ⇒ 只发 list', () async {
      final (api, t) = await _boot(
        responses: {
          '$_as.Radio.list': rootContainers(),
          '$_as.Radio.search': searchHits(),
        },
      );
      final c = ProviderContainer(
        overrides: [audioApiProvider.overrideWithValue(api)],
      );
      addTearDown(c.dispose);

      final list = c.read(audioRadioListProvider(allRadiosQuery).notifier);
      expect(list.isSearch, isFalse);
      await list.load();
      expect(_countOf(t, '$_as.Radio', 'list'), 1);
      expect(_countOf(t, '$_as.Radio', 'search'), 0);

      final search =
          c.read(audioRadioListProvider(radioSearchQuery('Jazz')).notifier);
      expect(search.isSearch, isTrue);
      await search.load();
      expect(_countOf(t, '$_as.Radio', 'search'), 1);
      expect(_countOf(t, '$_as.Radio', 'list'), 1, reason: '搜台不该再打 list');
      expect(
        c.read(audioRadioListProvider(radioSearchQuery('Jazz'))).items.length,
        2,
      );
    });

    test('③b v1-only：搜台通道门控为"不可用"且**不发**请求（list 通道不受影响）', () async {
      final (api, t) = await _boot(
        responses: {
          '$_as.Radio.list': rootContainers(),
          '$_as.Radio.search': searchHits(),
        },
        radioMaxVersion: 1,
      );
      final c = ProviderContainer(
        overrides: [audioApiProvider.overrideWithValue(api)],
      );
      addTearDown(c.dispose);

      expect(api.supportsRadioSearch, isFalse);
      final search =
          c.read(audioRadioListProvider(radioSearchQuery('Jazz')).notifier);
      expect(search.searchSupported, isFalse);
      await search.load();
      expect(_countOf(t, '$_as.Radio', 'search'), 0);
      expect(
        c.read(audioRadioListProvider(radioSearchQuery('Jazz'))).apiMissing,
        isFalse,
      );
      // 同一台服务器上，普通列表通道照常工作。
      final list = c.read(audioRadioListProvider(allRadiosQuery).notifier);
      await list.load();
      expect(_countOf(t, '$_as.Radio', 'list'), 1);
    });
  });

  group('r441 · 页面动作级（搜台 UI）', () {
    testWidgets('④ 根层有搜索入口；★ 分类层**没有**（搜索是目录级，container 被忽略）', (tester) async {
      await _pumpRadio(
        tester,
        responses: {'$_as.Radio.list': rootContainers()},
      );
      expect(find.byKey(const Key('as-radio-search')), findsOneWidget);

      // 反向：分类层不给入口（否则用户会以为"在这一类里搜"）。
      await _pumpRadio(
        tester,
        responses: {'$_as.Radio.list': rootContainers()},
        container: 'SHOUTcast',
      );
      expect(find.byKey(const Key('as-radio-search')), findsNothing);
    });

    testWidgets('⑤ 点入口 ⇒ 搜索页；提交关键字 ⇒ **只发 search**、结果上屏', (tester) async {
      final r = await _pumpRadio(
        tester,
        responses: {
          '$_as.Radio.list': rootContainers(),
          '$_as.Radio.search': searchHits(),
        },
      );
      await tester.tap(find.byKey(const Key('as-radio-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-radio-search-field')), findsOneWidget);

      // 进页时**还没**发搜索（先给提示空态，别偷偷发一条注定 101 的空关键字）。
      expect(_countOf(r.t, '$_as.Radio', 'search'), 0);
      // ★ 基线：根页自己加载过一次 `list`（这是列表页的正常行为）；搜索页**不许**
      //   再增加 `list` 的次数（否则就是"搜了等于没搜"）。
      final listBaseline = _countOf(r.t, '$_as.Radio', 'list');

      await _search(tester, 'Jazz');
      final call = _callOf(r.t, '$_as.Radio', 'search');
      expect(call['keyword'], 'Jazz');
      expect(call['offset'], 0);
      expect(call['limit'], AudioStationApi.pageSize);
      expect(
        _countOf(r.t, '$_as.Radio', 'list'),
        listBaseline,
        reason: '搜索页不许打 Radio.list（真机证明它会忽略关键字）',
      );
      expect(find.text('Smooth Jazz Florida Worldwide'), findsOneWidget);
    });

    testWidgets('⑥ 空关键字 ⇒ **零请求**（服务端会 101，不许当成"搜全部"）', (tester) async {
      final r = await _pumpRadio(
        tester,
        responses: {
          '$_as.Radio.list': rootContainers(),
          '$_as.Radio.search': searchHits(),
        },
      );
      await tester.tap(find.byKey(const Key('as-radio-search')));
      await tester.pumpAndSettle();
      final listBaseline = _countOf(r.t, '$_as.Radio', 'list');
      await _search(tester, '   ');
      expect(_countOf(r.t, '$_as.Radio', 'search'), 0);
      expect(_countOf(r.t, '$_as.Radio', 'list'), listBaseline);
      // 仍停在"输入关键字"的提示态。
      expect(find.byKey(const Key('as-radio-search-field')), findsOneWidget);
    });

    testWidgets('⑦ v1-only 服务器 ⇒ 如实"不支持"空态 ＋ **零请求**（不发注定 103 的请求）', (tester) async {
      final r = await _pumpRadio(
        tester,
        responses: {'$_as.Radio.search': searchHits()},
        radioMaxVersion: 1,
        home: const AudioRadioSearchPage(),
      );
      await _search(tester, 'Jazz');
      expect(_countOf(r.t, '$_as.Radio', 'search'), 0);
      expect(find.text('这台 NAS 的 Audio Station 不支持关键字搜台'), findsOneWidget);
    });

    testWidgets('⑧ 搜索结果的收藏写动词仍走 container=Favorite（与列表页同一条路径）', (tester) async {
      final r = await _pumpRadio(
        tester,
        responses: {
          '$_as.Radio.search': searchHits(),
          '$_as.Radio.updateradios': const <String, dynamic>{},
        },
        home: const AudioRadioSearchPage(),
      );
      await _search(tester, 'Jazz');
      final firstId =
          'radio_BEST SMOOTH JAZZ  - UK (LONDON) HOST ROD LUCAS '
          'http://yp.shoutcast.com/sbin/tunein-station.pls?id=99426190';
      await tester.tap(find.byKey(Key('as-radio-menu-$firstId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('as-radio-fav-$firstId')));
      await tester.pumpAndSettle();

      final call = _callOf(r.t, '$_as.Radio', 'updateradios');
      expect(call['container'], 'Favorite');
      expect(call['offset'], -1);
      expect(call['limit'], 0);
      final json = call['radios_json'] as String?;
      expect(json, isNotNull);
      expect(json, contains('BEST SMOOTH JAZZ'));
      expect(json, contains('tunein-station.pls?id=99426190'));
      // 写动词只发一条：没有 id 字段（官方形状）。
      expect(json, isNot(contains('"id"')));
    });
  });

  group('r441 · 结构性守卫（仪器122：钉声明，不钉行为）', () {
    test('⑨ 生产代码：搜索必须经 `searchRadios`；`listRadios` 里不许出现 keyword', () {
      final providers = _read('lib/src/features/audio/audio_providers.dart');
      final api = _read('lib/src/data/audio_station.dart');
      final page = _read('lib/src/features/audio/audio_radio_page.dart');

      // ① 控制器：搜台通道必须调 `searchRadios(`；**`listRadios(` 的实参块里不许有 keyword**。
      expect(providers, contains('searchRadios('));
      final listCallAt = providers.indexOf('api.listRadios(');
      expect(listCallAt, greaterThan(0));
      final listCallBlock = providers.substring(listCallAt, listCallAt + 400);
      expect(
        listCallBlock.contains('keyword'),
        isFalse,
        reason: '修前就是这样把 keyword 塞给 listRadios 的（服务端忽略 ⇒ DA95）',
      );
      // 分派必须按 `isSearch` 走（不是"同一个调用换个参数"）。
      expect(providers.contains('if (isSearch)'), isTrue);
      // ② API 层：`list` 的 params 里不许再有 keyword/text。
      final listBody = api.substring(
        api.indexOf('Future<AudioRadioList> listRadios('),
        api.indexOf('Future<AudioRadioList> searchRadios('),
      );
      expect(listBody.contains("'keyword'"), isFalse);
      expect(listBody.contains("'text'"), isFalse);
      // ③ search 必须显式带 offset/limit（不给就一条不回）。
      final searchBody = api.substring(
        api.indexOf('Future<AudioRadioList> searchRadios('),
        api.indexOf('bool get supportsRadioSearch'),
      );
      expect(searchBody.contains("'offset': offset"), isTrue);
      expect(searchBody.contains("'limit': limit"), isTrue);
      expect(searchBody.contains("'keyword': keyword"), isTrue);
      // ④ 页面：入口有 key、搜索页存在。
      expect(page.contains("Key('as-radio-search')"), isTrue);
      expect(page.contains('class AudioRadioSearchPage'), isTrue);
      // ⑤ 反查：不许有人在生产代码里再调 `listRadios(` 时带 keyword。
      expect(RegExp(r'listRadios\([^)]*keyword').hasMatch(api), isFalse);
    });
  });
}

String _read(String path) => File(path).readAsStringSync();
