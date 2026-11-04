// 片尾重播"要点两次"的**自然播完**支（R5-7 / device-verification.md:3765）。
//
// 已有承重（`media_r5_followup_test.dart`）只覆盖"**拖到**末尾 + completed"：
// 那一支由 `_onDragEnd` 同步记下 `_atEnd`，所以位置/状态怎么变都进重播分支。
//
// 真机用户报的是**播到结尾**（自然播完）后要再点一次。代码级根因：
// `JustAudioVoicePlayer` 收到 `ProcessingState.completed` 时会紧接着
// `stop() + seek(0)` **异步**把位置复位成 0；而 `MediaAudioStage` 的 listener
// 是异步投递的，读到 `position` 时可能已经是 0 ⇒ 只按"位置 ≥ 时长"判定"在片尾"
// 会在真实复位顺序下**漏判**，第一次点击就走了对 `completed` 播放器无效的
// `resume()`（只归零不出声、要再点一次）。
//
// 本用例把**真实的复位顺序**建模进假播放器（同步置 `ended`，随后位置归零），
// 钉的是**机制量**（§2.0.30②）：一次点击后
//   * `seek(0)` 被调用过（调用记录里出现 `Duration.zero`）；
//   * `play`/`resume` 真的把播放器带入 playing（状态枚举），而不是"按钮可点"；
//   * 重播**不重载来源**（`play(url)` 调用次数不增，不许新建 ExoPlayer）；
//   * 播放器的 `ended`（completed）状态被清掉。
// 反向验证（报告里有红原文）：去掉 `media_audio_stage.dart` 里读
// `VoicePlaybackEnded.ended` 的那一行 ⇒ 本文件"自然播完"条当场红。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/chat/voice_message.dart'
    show VoicePlaybackEnded, VoicePlayer, voicePlayerProvider;
import 'package:synhub/src/features/media/media_audio_stage.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/media_source.dart';

/// 复刻 `JustAudioVoicePlayer` 的**真实**片尾顺序的假播放器。
///
/// 与 `media_r5_followup_test.dart` 的 `_FakeVoicePlayer` 的关键差别：
/// 后者的 `markCompleted()` **保留**末尾位置（拖到末尾那一支），本假实现的
/// [naturalEnd] 则复刻真机：`completed` 置位的同一次通知里（或之前），
/// `stop()+seek(0)` 已经把位置**冲成 0** ⇒ 只按位置判定必然漏判。
class _NaturalEndVoicePlayer implements VoicePlayer, VoicePlaybackEnded {
  final _changes = StreamController<void>.broadcast();

  final played = <String>[];
  final seeks = <Duration>[];
  int resumes = 0;
  int pauses = 0;

  Duration _position = Duration.zero;
  bool _ended = false;

  @override
  String? currentUrl;

  @override
  bool get hasSource => _hasSource;
  bool _hasSource = false;

  @override
  bool playing = false;

  @override
  double speed = 1;

  @override
  Duration? duration = const Duration(seconds: 60);

  @override
  Duration get position => _position;

  @override
  Stream<void> get changes => _changes.stream;

  // ── VoicePlaybackEnded：与位置复位无关的"已在片尾"状态 ──
  @override
  bool get ended => _ended;

  @override
  void clearEnded() => _ended = false;

  /// 自然播完：**先同步置 ended**，再把位置复位成 0（just_audio 的异步
  /// `stop()+seek(0)` 到界面 listener 跑时已经落地），最后才通知界面。
  void naturalEnd() {
    playing = false;
    _ended = true; // 真实播放器的 playerStateStream 监听里，这一步是同步的
    _position = Duration.zero; // 异步 stop()+seek(0) 已经落地
    _changes.add(null);
  }

  @override
  Future<void> play(String url) async {
    played.add(url);
    currentUrl = url;
    _hasSource = true;
    _position = Duration.zero; // setUrl = 从 0 开始
    playing = true;
    _ended = false;
    _changes.add(null);
  }

  @override
  Future<void> resume() async {
    if (!_hasSource) return;
    resumes++;
    // just_audio 在 completed 上的 play() 是 no-op（真机"点了没反应"的直接原因）
    if (_ended) return;
    playing = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _position = position;
    if (position < (duration ?? Duration.zero)) _ended = false;
    _changes.add(null);
  }

  @override
  Future<void> stop() async {
    playing = false;
    _hasSource = false;
    _changes.add(null);
  }

  @override
  Future<void> setSpeed(double value) async => speed = value;
}

MediaSource _audio() => MediaSource(
  uri: 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=S',
  channel: MediaChannel.fileStation,
  kind: MediaKind.audio,
  displayName: 'audiotone.wav',
  supportsRange: true,
);

FileEntryDto _entry() => FileEntryDto(
  name: 'audiotone.wav',
  path: '/home/audiotone.wav',
  isDir: false,
  size: 4096,
  mtime: 1758100000,
);

Future<void> _pumpStage(WidgetTester tester, _NaturalEndVoicePlayer player) async {
  final container = ProviderContainer(
    overrides: [voicePlayerProvider.overrideWithValue(player)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: MediaAudioStage(entry: _entry(), source: _audio()),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('自然播完（位置已被异步复位）：一次点击就 seek(0) 并真正起播', (tester) async {
    final player = _NaturalEndVoicePlayer();
    await _pumpStage(tester, player);

    // 起播（载入来源）
    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump();
    expect(player.played, hasLength(1), reason: '前提：先载入唯一的来源');
    expect(player.playing, isTrue);

    // ★ 真机顺序：completed 置位的同时/之前，位置已经回到 0
    player.naturalEnd();
    await tester.pump();
    expect(player.ended, isTrue, reason: '机制量：播放器处于"已在片尾"状态');
    expect(player.position, Duration.zero, reason: '机制量：位置已被异步复位');

    // **第一次**（也是唯一一次）点击播放
    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump();
    await tester.pump();

    // ---- 机制量断言（§2.0.30②）----
    expect(
      player.seeks.where((s) => s == Duration.zero),
      isNotEmpty,
      reason: '片尾一次点击必须 seek(0)；没有它就是对 completed 播放器的 resume()（no-op）',
    );
    expect(
      player.playing,
      isTrue,
      reason: 'R5-7：第一次点击就要真正起播，不能"只归零不出声"',
    );
    expect(player.resumes, 1, reason: '只点了一次，resume 只该被调用一次');
    expect(
      player.played,
      hasLength(1),
      reason: '末尾重播不许重载来源（不许新建 ExoPlayer）',
    );
    expect(
      player.ended,
      isFalse,
      reason: '重播成功后必须离开 completed 状态（否则下一次点击又被误判）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('重播成功后位置从 0 推进（不是停在末尾的假象）', (tester) async {
    final player = _NaturalEndVoicePlayer();
    await _pumpStage(tester, player);
    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump();
    player.naturalEnd();
    await tester.pump();

    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump();
    // 播放推进（真实实现由 positionStream 上报；这里直接摆布位置再通知）
    await player.seek(const Duration(seconds: 3));
    await tester.pump();

    expect(player.position, const Duration(seconds: 3));
    expect(player.playing, isTrue, reason: '重播后仍在播（不是"归零即停"）');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('半途暂停后续播：不许被误判成重播（既有行为不回归）', (tester) async {
    final player = _NaturalEndVoicePlayer();
    await _pumpStage(tester, player);
    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump();

    await player.seek(const Duration(seconds: 30));
    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump();
    expect(player.pauses, greaterThanOrEqualTo(1));

    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump();
    expect(
      player.seeks.where((s) => s == Duration.zero),
      isEmpty,
      reason: '半途续播不许 seek(0)（只有片尾重播才有）',
    );
    expect(player.position, const Duration(seconds: 30));

    await tester.pumpWidget(const SizedBox());
  });
}
