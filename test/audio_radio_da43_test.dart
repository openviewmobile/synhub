// 网络电台 **DA43**（第 393 轮修法）的离线验证：**起播失败不许静默**。
//
// 缺陷出处（真机，可复算）：`docs/evidence-r392/r392_113fm_gap.txt`
//   —— 点 `113.fm Blues Town`（`http://50.31.185.139/1005`，经回环中继）后
//   ExoPlayer `None of the available extractors could read the stream … sniff failures`，
//   而**页面上没有任何提示**（无错误条、无重试入口）。
//
// 代码侧根因（离线可读）：`SynologyAudioHandler._onEngineError` 对**不归续期管**的
// 失败直接 `return` —— 没有第二个读者，所以页面永远不知道引擎失败了。
//
// 本文件覆盖（全部**离线**，假传输 + 假引擎）：
//   ① handler：不可续期的引擎失败 → `engineFailures` 一定发（带曲目 id / 原文）；
//      ★ 反向：**会话过期**那类错误走续期（`renewNotices`），**不发** `engineFailures`；
//   ② 页面动作级：点电台 → 引擎失败 → **上屏可读提示 + 重试动作**；
//   ③ 页面动作级：点"重试" → **真的再起播一次**（引擎收到两次 playQueue）；
//   ④ ★ 反向验证：**别的曲目**的失败不上当前页（陈旧提示 = 假信息）；
//   ⑤ ★ 反向验证：没有失败时页面**安静**（不许凭空冒提示）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_labels.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_radio_icy.dart';
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

/// 叶子层：一条**裸流**电台（不起播放列表请求，把用例聚焦在"失败怎么上屏"）。
Map<String, dynamic> _stations() => {
  'radios': [
    {
      'id': 'radio_113fm',
      'title': '113.fm Blues Town',
      'type': 'station',
      'url': 'http://50.31.185.139/1005',
      'desc': 'MP3 (128 kbps)',
    },
    {
      'id': 'radio_blues',
      'title': 'Blues Radio',
      'type': 'station',
      'url': 'http://i4.streams.ovh:8352/stream',
      'desc': 'MP3 (192 kbps)',
    },
  ],
  'total': 2,
};

/// 假引擎：**带**附加能力（有异步错误源），用来复现"引擎报错"这条路。
class _FailingPlayer implements AudioStationPlayer, AudioEngineExtras {
  final played = <String>[];
  final _changes = StreamController<void>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  bool _playing = false;
  String? _current;
  int _index = -1;
  List<AudioQueueEntry> _queue = const [];
  bool disposed = false;

  /// `true` ⇒ `playQueue` **直接抛**（复现 just_audio `load()` 取流失败时
  /// 那个"几秒后才以异常结束"的 future；真机读到的是通用兜底文案）。
  bool throwOnPlay = false;

  /// 让用例把引擎错误推上来（真机上是原生 `onPlayerError` → `state.error`）。
  void emitEngineError(Object error) => _errors.add(error);

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

  // AudioEngineExtras
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  Stream<Object> get errors => _errors.stream;
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<void> play(String url) =>
      playQueue([AudioQueueEntry(id: url, url: url)]);

  @override
  Future<void> playQueue(
    List<AudioQueueEntry> entries, {
    int startIndex = 0,
  }) async {
    if (entries.isEmpty) return;
    if (throwOnPlay) throw StateError('load failed: source error');
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

/// 假探针：不连网、永远"没有曲目"（本文件只判失败态，不判曲目）。
class _NoopIcy implements IcyMetadataSource {
  @override
  Future<IcyNowPlaying?> probe(Uri streamUrl, {Duration? timeout}) async => null;
}

/// 起一个电台页（假引擎 = 带错误源的 `_FailingPlayer`）。
Future<({_FailingPlayer player, ProviderContainer c})> _pumpRadio(
  WidgetTester tester,
) async {
  final t = FakeTransport({'$_as.Radio.list': _stations()}, {
    ...FakeTransport.table,
    ..._table(),
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final player = _FailingPlayer();
  final c = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(api)),
      audioStationPlayerProvider.overrideWithValue(player),
      radioStreamRelayProvider.overrideWithValue(const NoopRadioStreamRelay()),
      // r641：播放条/面板会去问"正在播哪一首"（ICY 旁路）⇒ 宿主用例不许真连网
      icyMetadataSourceProvider.overrideWithValue(_NoopIcy()),
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
  group('DA43 · handler：不可续期的引擎失败必须报出去', () {
    test('引擎报"读不出流" → engineFailures 收到带 id 与原文的事件', () async {
      final player = _FailingPlayer();
      final handler = SynologyAudioHandler(player: player);
      addTearDown(handler.dispose);
      final failures = <AudioEngineFailure>[];
      final sub = handler.engineFailures.listen(failures.add);
      addTearDown(sub.cancel);

      await handler.startQueue([
        const AudioTrackInfo(
          id: 'radio_113fm',
          url: 'http://127.0.0.1:1/r/tok?u=x',
          title: '113.fm Blues Town',
        ),
      ]);
      player.emitEngineError(
        StateError('None of the available extractors could read the stream'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(failures, hasLength(1));
      expect(failures.single.mediaId, 'radio_113fm');
      expect(failures.single.message, contains('extractors'));
    });

    test('★ 反向：会话过期走续期（renewNotices），**不**发 engineFailures', () async {
      final player = _FailingPlayer();
      final handler = SynologyAudioHandler(player: player);
      addTearDown(handler.dispose);
      final failures = <AudioEngineFailure>[];
      final notices = <AudioRenewNotice>[];
      final s1 = handler.engineFailures.listen(failures.add);
      final s2 = handler.renewNotices.listen(notices.add);
      addTearDown(s1.cancel);
      addTearDown(s2.cancel);

      await handler.startQueue([
        const AudioTrackInfo(
          id: 'radio_113fm',
          url: 'http://h/stream',
          title: 'x',
        ),
      ]);
      // 会话过期：`119 / _sid` 文本 ⇒ 归 sessionExpired ⇒ 走续期那条路
      // （没有注入 freshUrlFetcher ⇒ 如实"暂停 + 续期失败"提示）。
      player.emitEngineError(StateError('DsmApiException: 119 sid not found'));
      await Future<void>.delayed(Duration.zero);

      expect(failures, isEmpty, reason: '续期那类失败不该走通用失败通道');
      expect(
        notices.map((n) => n.kind),
        contains(AudioRenewNoticeKind.failedPaused),
        reason: '续期失败必须留下"已暂停"提示，不能被新通道吞掉',
      );
    });
  });

  group('DA43 · 页面动作级（离线）：失败了要说话，还要能重试', () {
    testWidgets('点电台 → 引擎失败 → 上屏可读提示 + 重试动作', (tester) async {
      final r = await _pumpRadio(tester);
      expect(find.text('113.fm Blues Town'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_113fm')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(r.player.played, hasLength(1));
      expect(
        find.byKey(const Key('as-radio-play-failed')),
        findsNothing,
        reason: '还没失败，不许凭空冒提示',
      );

      r.player.emitEngineError(
        StateError('None of the available extractors could read the stream'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('as-radio-play-failed')), findsOneWidget);
      expect(find.text(asRadioPlayFailed), findsOneWidget);
      expect(find.text(asRadioPlayRetry), findsOneWidget);
      // ★ 引擎诊断串**不许**上屏（上了屏就是"诊断串当用户文案"）
      expect(
        find.textContaining('extractors'),
        findsNothing,
        reason: '引擎原文只进日志，不进 UI',
      );
    });

    testWidgets('点"重试" → 真的再起播一次', (tester) async {
      final r = await _pumpRadio(tester);
      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_113fm')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      r.player.emitEngineError(StateError('boom'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.player.played, hasLength(1));

      await tester.tap(find.text(asRadioPlayRetry));
      await tester.pump(const Duration(milliseconds: 200));

      expect(r.player.played, hasLength(2), reason: '重试必须真的再起播');
      expect(r.player.played.last, contains('50.31.185.139'));
    });

    testWidgets('★ 反向验证：**没点过任何电台**时，引擎失败不上屏；陈旧失败也不会补冒', (
      tester,
    ) async {
      final r = await _pumpRadio(tester);
      // 页面还是"只看不点"的状态：handler 的失败事件照发（下面断言），
      // 但页面**没有**"我请求过的那条"，不许凭这条提示冤枉任何电台。
      final handler = r.c.read(audioHandlerProvider);
      final seen = <AudioEngineFailure>[];
      final sub = handler.engineFailures.listen(seen.add);
      addTearDown(sub.cancel);
      await handler.startQueue([
        const AudioTrackInfo(
          id: 'radio_113fm',
          url: 'http://50.31.185.139/1005',
          title: '113.fm Blues Town',
        ),
      ]);
      r.player.emitEngineError(StateError('boom'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(seen, hasLength(1), reason: 'handler 照发（这是全 App 的通道）');
      expect(
        find.byKey(const Key('as-radio-play-failed')),
        findsNothing,
        reason: '页面没请求过任何电台 ⇒ 不许替用户报"这个电台没能播"',
      );

      // 之后真的点一条：**之前**那条陈旧失败不许跟着冒出来。
      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_blues')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('as-radio-play-failed')), findsNothing);
      expect(r.player.played, hasLength(2));
    });
  });

  group('DA43 · 换了电台：上一条失败提示必须收掉', () {
    testWidgets('失败提示挂着时点另一个电台 → 提示立刻消失（不许"边说没播边出声"）', (
      tester,
    ) async {
      final r = await _pumpRadio(tester);
      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_113fm')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      r.player.emitEngineError(StateError('boom'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('as-radio-play-failed')), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_blues')),
      );
      // `hideCurrentSnackBar` 是**带动画**收掉（真机 ~250ms）⇒ 等动画走完再判
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('as-radio-play-failed')),
        findsNothing,
        reason: '新电台已经在播，旧提示不许留在屏幕上',
      );
      expect(r.player.played.last, contains('i4.streams.ovh'));
    });
  });

  group('DA43 · 起播异常兜底：不许只弹通用"操作未完成"', () {
    testWidgets('起播直接抛异常 → 仍然是"这个电台没能开始播放"+ 重试（只一句）', (
      tester,
    ) async {
      final r = await _pumpRadio(tester);
      r.player.throwOnPlay = true;

      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_113fm')),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SnackBar), findsOneWidget, reason: '只该有一句提示');
      expect(find.text(asRadioPlayFailed), findsOneWidget);
      expect(find.text(asRadioPlayRetry), findsOneWidget);
      expect(
        find.textContaining('operation could not be completed'),
        findsNothing,
        reason: '通用兜底（"某件事没成功"）不算提示',
      );
      // 引擎此刻并没有报错（异常来自 startQueue）⇒ 验证的正是 catch 那条路
      expect(r.player.played, isEmpty);
    });

    testWidgets('★ 反向：异常 + 引擎错误**同时**来 → 仍然只显示同一句', (
      tester,
    ) async {
      final r = await _pumpRadio(tester);
      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_113fm')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(r.player.played, hasLength(1));

      // 引擎先报错，紧接着 startQueue 的 await 也抛（真机上的真实时序）。
      r.player.emitEngineError(StateError('None of the available extractors'));
      await tester.pump();
      r.player.throwOnPlay = true;
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(asRadioPlayFailed), findsOneWidget);
    });
  });

  // ★★★ r641（**DA234**）：起播失败**不能只有一条会消失的提示条**。
  //
  // 真机证据（2026-10-23，飞行模式）：提示条 `[0,2296][1148,2377]` 与播放条
  // `[77,2293]…` **完全重叠** —— 三个键被盖住；提示条 4 s 后自己消失，播放条
  // 只剩一句「已暂停」，没有解释、没有重试入口。面板（弹层）里更是什么都没有。
  group('r641 · DA234 起播失败：条上要有持久态，面板里要有重试', () {
    Future<({_FailingPlayer player, ProviderContainer c})> failOnce(
      WidgetTester tester,
    ) async {
      final r = await _pumpRadio(tester);
      await tester.tap(
        find.byKey(const Key('as-radio-station-tile-radio_113fm')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      r.player.emitEngineError(StateError('boom'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return r;
    }

    testWidgets('① 失败后播放条自己说「没能播放」，并给一个重试键', (tester) async {
      final r = await failOnce(tester);
      expect(r.player.played, hasLength(1));

      final bar = find.byKey(const Key('as-radio-now-playing'));
      expect(bar, findsOneWidget);
      expect(
        tester.widget<Text>(
          find.byKey(const Key('as-radio-now-playing-subtitle')),
        ).data,
        asRadioPlayFailedShort,
        reason: 'DA234：不许只剩一句"已暂停"',
      );
      expect(
        find.byKey(const Key('as-radio-now-playing-retry')),
        findsOneWidget,
      );
    });

    testWidgets('② 点条上的重试 → 真的再起播一次；成功失败态随即消失', (tester) async {
      final r = await failOnce(tester);
      await tester.tap(find.byKey(const Key('as-radio-now-playing-retry')));
      await tester.pump(const Duration(milliseconds: 300));

      expect(r.player.played, hasLength(2), reason: '重试必须真的再起播');
      expect(
        find.byKey(const Key('as-radio-now-playing-retry')),
        findsNothing,
        reason: '新的起播请求 ⇒ 旧失败态立刻作废',
      );
    });

    testWidgets('③ 提示条浮起来并让出播放条高度（不压住三个键）', (tester) async {
      await failOnce(tester);
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.behavior, SnackBarBehavior.floating,
          reason: 'DA234：固定贴底会与播放条重叠');
      final margin = snack.margin;
      expect(margin, isNotNull);
      expect(
        (margin! as EdgeInsets).bottom,
        greaterThanOrEqualTo(60),
        reason: 'DA234：至少让出一条播放条的高度（~56dp）+ 间距',
      );
    });

    testWidgets('④ 面板里也有失败态与**当场能按**的重试', (tester) async {
      final r = await failOnce(tester);
      await tester.tap(find.byKey(const Key('as-radio-now-playing-open')));
      await tester.pumpAndSettle();

      // 面板打开这一帧还不知道失败（失败发生在打开之前）⇒ 再报一次
      r.player.emitEngineError(StateError('boom again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('as-radio-sheet')), findsOneWidget);
      expect(
        find.byKey(const Key('as-radio-sheet-failed')),
        findsOneWidget,
        reason: 'DA234：提示条在面板下面，面板必须自己说一次',
      );
      expect(find.text(asRadioPlayFailed), findsWidgets);

      await tester.tap(find.byKey(const Key('as-radio-sheet-retry')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.player.played, hasLength(2),
          reason: 'DA234：面板里的重试必须真的重播（走页面回调）');
      expect(
        find.byKey(const Key('as-radio-sheet-failed')),
        findsNothing,
        reason: '重试后失败块立刻收掉',
      );
    });

    testWidgets('⑤ 失败**之后**才打开面板 ⇒ 面板里仍是失败态（不用再报一次）', (
      tester,
    ) async {
      final r = await failOnce(tester);
      await tester.tap(find.byKey(const Key('as-radio-now-playing-open')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('as-radio-sheet-failed')),
        findsOneWidget,
        reason: 'DA234：真机路径就是"失败了 → 再点开面板"，面板必须知道',
      );
      await tester.tap(find.byKey(const Key('as-radio-sheet-retry')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.player.played, hasLength(2));
    });
  });

}
