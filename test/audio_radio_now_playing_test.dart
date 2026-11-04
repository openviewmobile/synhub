// 电台页「正在播放」条（r471，用户 r468 反馈："电台页没有播放器"）——**DA106**。
//
// 为什么要有这条：起播后电台页**什么都不显示** —— 想暂停 / 关掉只能退出这一页
// 去别处找（真机当时就是这个体验）。本轮在这一页加了一条只读 `audioHandler`
// 的播放条：状态唯一来源是 `playbackState` + `mediaItem`，不自己维护 bool。
//
// 判据：
//   ① 没在播 → **不出现**（不占位、不假装）；
//   ② 起播后 → 出现，标题是当前电台，暂停按钮可暂停、关闭按钮能停；
//   ③ 反向：别的页面在播的歌也会在这里显示（这是全局播放器的真实状态，
//      不是"只认本页点过的电台"——隐藏它会变成第二条状态源）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_labels.dart'
    show asRadioStationBadge;
import 'package:synhub/src/features/audio/audio_radio_icy.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_radio_player_sheet.dart'
    show asRadioHumanDesc, asRadioPlayingStateText;
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
  ],
  'total': 1,
};

class _Player implements AudioStationPlayer {
  final List<String> played = <String>[];
  int pauses = 0;
  int stops = 0;
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
  Future<void> play(String url) => playQueue([AudioQueueEntry(id: url, url: url)]);

  @override
  Future<void> playQueue(List<AudioQueueEntry> entries, {int startIndex = 0}) async {
    if (entries.isEmpty) return;
    _queue = entries;
    _index = startIndex.clamp(0, entries.length - 1);
    _current = entries[_index].url;
    played.add(_current!);
    _playing = true;
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
    stops++;
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

/// 假探针：不碰网络，直接回一条固定歌名（r640 / DA233 的界面判据用它）。
class _FakeIcy implements IcyMetadataSource {
  _FakeIcy([this.title = 'Daft Punk - One More Time']);

  final String? title;
  int probes = 0;
  final List<String> urls = <String>[];

  @override
  Future<IcyNowPlaying?> probe(Uri streamUrl, {Duration? timeout}) async {
    probes++;
    urls.add(streamUrl.toString());
    final t = title;
    return t == null ? null : IcyNowPlaying(title: t, stationName: 'Test FM');
  }
}

Future<({_Player player, ProviderContainer c})> _pump(
  WidgetTester tester, {
  IcyMetadataSource? icy,
}) async {
  final t = FakeTransport({'$_as.Radio.list': _stations()}, {
    ...FakeTransport.table,
    ..._table(),
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final player = _Player();
  final c = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(api)),
      audioStationPlayerProvider.overrideWithValue(player),
      radioStreamRelayProvider.overrideWithValue(const NoopRadioStreamRelay()),
      if (icy != null) icyMetadataSourceProvider.overrideWithValue(icy),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const AudioRadioPage(container: 'SHOUTcast_Blues'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return (player: player, c: c);
}

void main() {
  testWidgets('① 没在播 → 播放条不出现', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('as-radio-now-playing')), findsNothing);
  });

  testWidgets('② 起播后出现；暂停按钮真暂停；关闭按钮真停', (tester) async {
    final r = await _pump(tester);
    final handler = r.c.read(audioHandlerProvider);
    await handler.startQueue([
      const AudioTrackInfo(
        id: 'radio_blues',
        url: 'http://127.0.0.1:1/r/x?u=y',
        title: 'Blues Radio',
        artist: 'MP3 (192 kbps)',
      ),
    ]);
    await tester.pumpAndSettle();

    final bar = find.byKey(const Key('as-radio-now-playing'));
    expect(bar, findsOneWidget, reason: '起播后电台页必须有播放条');
    expect(find.descendant(of: bar, matching: find.text('Blues Radio')), findsOneWidget);

    await tester.tap(find.byKey(const Key('as-radio-now-playing-toggle')));
    await tester.pumpAndSettle();
    expect(r.player.pauses, 1, reason: '暂停按钮必须真的暂停');

    await tester.tap(find.byKey(const Key('as-radio-now-playing-close')));
    await tester.pumpAndSettle();
    expect(r.player.stops, 1, reason: '关闭按钮必须真的停');
    expect(find.byKey(const Key('as-radio-now-playing')), findsNothing,
        reason: '停掉之后播放条要消失（不许留一条"在播"的假信息）');
  });

  testWidgets('③ 反向：不是本页点过的歌，只要在播也显示（全局状态，不是第二份）', (tester) async {
    final r = await _pump(tester);
    final handler = r.c.read(audioHandlerProvider);
    await handler.startQueue([
      const AudioTrackInfo(id: 'song_1', url: 'http://127.0.0.1:1/a.mp3', title: '别处点的歌'),
    ]);
    await tester.pumpAndSettle();

    final bar = find.byKey(const Key('as-radio-now-playing'));
    expect(bar, findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('别处点的歌')), findsOneWidget);
  });

  // ───────────────────────────── r631：电台播放条（人话）＋ 播放器面板

  testWidgets('④ r631 副标题不说技术参数：`MP3 (192 kbps)` ⇒ 只写"正在播放"', (tester) async {
    final r = await _pump(tester);
    final handler = r.c.read(audioHandlerProvider);
    await handler.startQueue([
      const AudioTrackInfo(
        id: 'radio_blues',
        url: 'http://127.0.0.1:1/r/x?u=y',
        title: 'Blues Radio',
        artist: 'MP3 (192 kbps)',
      ),
    ]);
    await tester.pumpAndSettle();
    final subtitle = tester.widget<Text>(
      find.byKey(const Key('as-radio-now-playing-subtitle')),
    );
    expect(subtitle.data, contains('正在播放'));
    expect(
      subtitle.data,
      isNot(contains('kbps')),
      reason: 'r631：码率不许画在播放条上（用户要求技术参数收进菜单）',
    );
  });

  testWidgets('⑤ r631 人话描述保留：`深夜蓝调` ⇒ 状态 + 描述', (tester) async {
    final r = await _pump(tester);
    final handler = r.c.read(audioHandlerProvider);
    await handler.startQueue([
      const AudioTrackInfo(
        id: 'radio_blues',
        url: 'http://127.0.0.1:1/r/x?u=y',
        title: 'Blues Radio',
        artist: '深夜蓝调',
      ),
    ]);
    await tester.pumpAndSettle();
    final subtitle = tester.widget<Text>(
      find.byKey(const Key('as-radio-now-playing-subtitle')),
    );
    expect(subtitle.data, contains('深夜蓝调'));
  });

  testWidgets('⑦ r631 列表行副标题不许再画编码/码率（`MP3 (192 kbps)` ⇒ 类别占位）', (tester) async {
    await _pump(tester);
    // 夹具里的电台 desc 就是 `MP3 (192 kbps)`（SHOUTcast 目录真实形态）
    expect(
      find.textContaining('kbps'),
      findsNothing,
      reason: 'r631：技术参数不许出现在电台列表行上',
    );
    // ★ r633（DA216）订正：r631 在这一行的"没人话"分支上回落到 `Station`，
    //   结果整页每一行的副标题都是同一个词 —— 等于没写。现在**不挂副标题**。
    expect(
      find.text(asRadioStationBadge),
      findsNothing,
      reason: 'DA216：没人话就不写副标题（`Station` 这种填充词不许再上屏）',
    );
  });

  // ★ r653（**DA258**）：通知栏/面板的副标题不许「正在播放 · 正在播放」。
  test('DA258 纯函数：已经是状态文案时不再重复拼接', () {
    final state = asRadioPlayingStateText(playing: true, desc: '');
    expect(asRadioPlayingStateText(playing: true, desc: 'MP3 (192 kbps)'), state);
    // 把清洗后的副标题（= 状态文案本身）再喂回去，仍然只有一句
    expect(asRadioPlayingStateText(playing: true, desc: state), state);
    // 反向：有人话时必须拼上，别把信息吞掉
    expect(
      asRadioPlayingStateText(playing: true, desc: 'Jazz 24/7 · MP3 (192 kbps)'),
      contains('Jazz 24/7'),
    );
  });

  test('纯函数：asRadioHumanDesc 摘技术、留人话', () {
    expect(asRadioHumanDesc('MP3 (192 kbps)'), '');
    expect(asRadioHumanDesc('AAC (96 kbps)'), '');
    expect(asRadioHumanDesc('深夜蓝调'), '深夜蓝调');
    expect(asRadioHumanDesc('Jazz 24/7 · MP3 (320 kbps)'), 'Jazz 24/7');
    expect(asRadioHumanDesc(''), '');
  });

  testWidgets('⑥ r631 展开 ⇒ 播放器面板：大播放键真的暂停；技术参数默认收起', (tester) async {
    final r = await _pump(tester);
    final handler = r.c.read(audioHandlerProvider);
    await handler.startQueue([
      const AudioTrackInfo(
        id: 'radio_blues',
        url: 'http://127.0.0.1:1/r/x?u=y',
        title: 'Blues Radio',
        artist: 'MP3 (192 kbps)',
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('as-radio-now-playing-expand')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('as-radio-sheet')), findsOneWidget);
    expect(find.byKey(const Key('as-radio-sheet-title')), findsOneWidget);

    // 主控键的点击区必须 ≥ 48dp（AGENTS §2.0.10）
    final toggle = tester.getSize(find.byKey(const Key('as-radio-sheet-toggle')));
    expect(toggle.width, greaterThanOrEqualTo(48));
    expect(toggle.height, greaterThanOrEqualTo(48));

    // 技术参数默认不在屏上（"收在菜单里"）
    expect(find.byKey(const Key('as-radio-tech-desc')), findsNothing);
    await tester.tap(find.byKey(const Key('as-radio-sheet-tech-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('as-radio-tech-desc')), findsOneWidget);

    await tester.tap(find.byKey(const Key('as-radio-sheet-toggle')));
    await tester.pumpAndSettle();
    expect(r.player.pauses, 1, reason: '面板里的大播放键必须真的暂停');
  });

  // ★ r640（**DA233**）：电台弹层里的「正在播的曲目」。
  //   判据两端都要有：拿得到就显示；**不是这一条在播**就绝不显示（防串台）。
  group('r640 · DA233 电台「正在播的曲目」', () {
    testWidgets('① 探针拿到标题 ⇒ 弹层显示；且探的是**已解析的流地址**', (tester) async {
      final icy = _FakeIcy('Bee Gees - Stayin Alive');
      final r = await _pump(tester, icy: icy);
      final handler = r.c.read(audioHandlerProvider);
      await handler.startQueue([
        const AudioTrackInfo(
          id: 'radio_blues',
          url: 'http://127.0.0.1:1/r/x?u=y',
          title: 'Blues Radio',
          artist: 'MP3 (192 kbps)',
          kind: AudioTrackKind.radio,
        ),
      ]);
      await tester.pumpAndSettle();

      r.c.read(radioNowPlayingProvider.notifier).start(
            'radio_blues',
            'http://i4.streams.ovh:8352/stream',
          );
      await tester.pump();
      expect(
        icy.probes,
        0,
        reason: 'DA233：起播时**不**连网（看不见的信息不为它耗流量）',
      );

      await tester.tap(find.byKey(const Key('as-radio-now-playing-open')));
      await tester.pumpAndSettle();
      expect(icy.probes, 1, reason: 'DA233：面板一打开就探一次');
      expect(icy.urls.single, 'http://i4.streams.ovh:8352/stream');
      expect(find.byKey(const Key('as-radio-sheet')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('as-radio-sheet-track'))).data,
        'Bee Gees - Stayin Alive',
        reason: 'DA233：弹层里要让用户看见"这一首在播什么"',
      );
      // 轮询定时器必须收掉（否则用例结束时报 pending timer）
      r.c.read(radioNowPlayingProvider.notifier).stop();
    });

    testWidgets('② 反向：在播的是别的条目 ⇒ 不显示这一行，探针也不再跑', (tester) async {
      final icy = _FakeIcy();
      final r = await _pump(tester, icy: icy);
      final handler = r.c.read(audioHandlerProvider);
      await handler.startQueue([
        const AudioTrackInfo(
          id: 'radio_blues',
          url: 'http://127.0.0.1:1/r/x?u=y',
          title: 'Blues Radio',
          artist: 'MP3 (192 kbps)',
          kind: AudioTrackKind.radio,
        ),
      ]);
      await tester.pumpAndSettle();

      // 给"上一个电台"起过探针，但当前在播的已经是这条（id 不匹配）
      r.c.read(radioNowPlayingProvider.notifier).start(
            'radio_other',
            'http://example.invalid/other',
          );
      await tester.tap(find.byKey(const Key('as-radio-now-playing-open')));
      await tester.pumpAndSettle();
      expect(icy.probes, 0, reason: 'DA233：不是当前这条 ⇒ 一次都不探');
      expect(find.byKey(const Key('as-radio-sheet')), findsOneWidget);
      expect(
        find.byKey(const Key('as-radio-sheet-track')),
        findsNothing,
        reason: 'DA233 反向：拿不到 / 不是这条 ⇒ 整行不出现，不摆"未知"占位',
      );
      r.c.read(radioNowPlayingProvider.notifier).stop();
    });

    testWidgets('③ r641：面板**先**开、起播成功**后**才 `start()` ⇒ 立刻补起轮询', (
      tester,
    ) async {
      // 真机路径：离线点台 → 失败 → 打开面板（此时还没 start）→ 恢复网络 →
      // 面板里点重试 → 成功。旧实现里轮询只在 `resumePolling()` 且已有 `_url`
      // 时才起 ⇒ 面板开着却要关掉再开才显示曲目。
      final icy = _FakeIcy('Counting Crows - Round Here');
      final r = await _pump(tester, icy: icy);
      final handler = r.c.read(audioHandlerProvider);
      await handler.startQueue([
        const AudioTrackInfo(
          id: 'radio_blues',
          url: 'http://127.0.0.1:1/r/x?u=y',
          title: 'Blues Radio',
          artist: 'MP3 (192 kbps)',
          kind: AudioTrackKind.radio,
        ),
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('as-radio-now-playing-open')));
      await tester.pumpAndSettle();
      expect(icy.probes, 0, reason: '还没 start ⇒ 没有可探的流地址');

      r.c.read(radioNowPlayingProvider.notifier).start(
            'radio_blues',
            'http://i4.streams.ovh:8352/stream',
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(icy.probes, 1, reason: 'r641：面板在看着 ⇒ start 后立刻补一次');
      expect(
        tester.widget<Text>(find.byKey(const Key('as-radio-sheet-track'))).data,
        'Counting Crows - Round Here',
      );
      r.c.read(radioNowPlayingProvider.notifier).stop();
    });

  });

}
