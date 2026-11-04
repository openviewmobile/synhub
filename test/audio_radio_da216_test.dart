// **DA216**（r633）：电台层级页的三处「人视角」问题 ——
//
// ① 说明卡常驻且说技术黑话（`.pls` / `SHOUTcast addresses are .pls playlists`）；
// ② 每一行都挂同一句填充词副标题（`Radio category` / `Station`）；
// ③ 列表里**看不出哪一行正在播**，点当前台还会重新起播（而不是暂停）。
//
// 真机现场（r633 施工前，1148×2492）：
//   * 三层页面（根 / SHOUTcast / Blues）顶部是**同一张**技术说明卡；
//   * 26 行分类全是副标题 `Radio category`；50 行电台全是 `Station`；
//   * `Blues Radio` 正在播（底栏播放条显示 `Now playing`），列表里那一行**没有
//     任何标记**；点它 = 重新 `startQueue`（会从头再拉一次流），不是暂停。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_radio_relay.dart';
import 'package:synhub/src/features/media/audio_handler.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

Map<String, Map<String, dynamic>> _table() => {
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

Map<String, dynamic> _stations() => {
  'radios': [
    {
      'id': 'radio_blues',
      'title': 'Blues Radio',
      'type': 'station',
      'url': 'http://i4.streams.ovh:8352/stream',
      'desc': 'MP3 (192 kbps)',
    },
    {
      'id': 'radio_jazz',
      'title': 'Jazz Radio',
      'type': 'station',
      'url': 'http://i4.streams.ovh:8352/jazz',
      'desc': '深夜爵士',
    },
  ],
  'total': 2,
};

class _Player implements AudioStationPlayer {
  int pauses = 0;
  int plays = 0;
  bool _playing = false;
  String? _current;
  int _index = -1;
  List<AudioQueueEntry> _queue = const [];
  final _changes = StreamController<void>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();

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
    _queue = entries;
    _index = startIndex.clamp(0, entries.length - 1);
    _current = entries[_index].url;
    _playing = true;
    plays++;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    pauses++;
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
    _queue = const [];
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

Future<({_Player player, ProviderContainer c})> _pump(
  WidgetTester tester, {
  String? container,
}) async {
  final transport = FakeTransport({'$_as.Radio.list': _stations()}, {
    ...FakeTransport.table,
    ..._table(),
  });
  final api = DsmWebApi(transport);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final player = _Player();
  final c = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(api)),
      audioStationPlayerProvider.overrideWithValue(player),
      radioStreamRelayProvider.overrideWithValue(const NoopRadioStreamRelay()),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: AudioRadioPage(container: container),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return (player: player, c: c);
}

/// 起播一条电台（模拟"用户刚才点了这一台"）。
Future<void> _startRadio(
  WidgetTester tester,
  ProviderContainer c, {
  String id = 'radio_blues',
  String title = 'Blues Radio',
}) async {
  final handler = c.read(audioHandlerProvider);
  await handler.startQueue([
    AudioTrackInfo(
      id: id,
      url: 'http://127.0.0.1:1/x',
      title: title,
      artist: 'MP3 (192 kbps)',
      kind: AudioTrackKind.radio,
    ),
  ]);
  await tester.pumpAndSettle();
}

void main() {
  test('① DA216：说明卡不许再说 `.pls` / SHOUTcast 协议黑话（中英两份都要）',
      () {
    final zh = lookupAppTextSafe(const Locale('zh')).asRadioListNote;
    final en = lookupAppTextSafe(const Locale('en')).asRadioListNote;
    for (final pair in [( 'zh', zh), ('en', en)]) {
      final text = pair.$2;
      expect(
        text.toLowerCase().contains('.pls'),
        isFalse,
        reason: 'DA216：${pair.$1} 文案里不许出现 `.pls`（协议细节不是用户的话）',
      );
      expect(
        text.contains('SHOUTcast'),
        isFalse,
        reason: 'DA216：${pair.$1} 文案里不许点名 SHOUTcast 协议',
      );
      // 但仍然要告诉用户"起播会慢一拍"这件**人**能感知的事
      expect(
        text.contains('慢') || text.contains('moment'),
        isTrue,
        reason: 'DA216：去掉黑话不等于丢掉"起播要等一会儿"这个真实体验',
      );
    }
  });

  testWidgets('② DA216：分类/电台行不再挂填充词副标题', (tester) async {
    await _pump(tester, container: 'SHOUTcast');
    // 分类页：不再有 `Radio category`
    expect(find.text('电台分类'), findsNothing);
    expect(find.textContaining('Radio category'), findsNothing);
    // 电台页：没有 desc 的那条不再写 `Station`
    await _pump(tester);
    expect(find.text('电台'), findsNothing);
    expect(find.textContaining('Station'), findsNothing);
  });

  testWidgets('③ DA216：正在播的那一行有标记（声波图标 + 主色标题 + 状态词）', (tester) async {
    final r = await _pump(tester);
    await _startRadio(tester, r.c);

    expect(
      find.byKey(const Key('as-radio-current-radio_blues')),
      findsOneWidget,
      reason: 'DA216：列表必须标出"哪一条在响"',
    );
    // 状态词只出现在当前台那一行（另一行不许也写"正在播放"）；
    // 底部那条播放条也写"正在播放"（全局状态），所以判据必须限定在**列表行**里。
    expect(
      find.descendant(
        of: find.byKey(const Key('as-radio-station-tile-radio_blues')),
        matching: find.textContaining('正在播放'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('as-radio-station-tile-radio_jazz')),
        matching: find.textContaining('正在播放'),
      ),
      findsNothing,
    );
  });

  testWidgets('④ DA216：点当前台 = 暂停（不许重新起播）', (tester) async {
    final r = await _pump(tester);
    await _startRadio(tester, r.c);
    final before = r.player.plays;

    await tester.tap(find.byKey(const Key('as-radio-station-tile-radio_blues')));
    await tester.pumpAndSettle();

    expect(r.player.pauses, 1, reason: 'DA216：点当前台应暂停');
    expect(
      r.player.plays,
      before,
      reason: 'DA216：点当前台不许重新 startQueue（那会从头再拉一次流、还会闪一下）',
    );
  });

  testWidgets('⑤ DA216 反向：别处点的**歌**不许被画成电台', (tester) async {
    final r = await _pump(tester);
    final handler = r.c.read(audioHandlerProvider);
    // 故意给一个"看着像电台"的 id，但 kind 是歌曲
    await handler.startQueue([
      const AudioTrackInfo(
        id: 'radio_lookalike',
        url: 'http://127.0.0.1:1/song',
        title: '一首歌',
        kind: AudioTrackKind.song,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('as-radio-current-radio_blues')),
      findsNothing,
      reason: 'DA216：判据是 kind，不是 id 前缀',
    );
    // 列表行里不许出现"正在播放"（页面底部的电台播放条是全局状态，不算行标记）
    expect(
      find.descendant(
        of: find.byKey(const Key('as-radio-station-tile-radio_blues')),
        matching: find.textContaining('正在播放'),
      ),
      findsNothing,
    );
  });
}
