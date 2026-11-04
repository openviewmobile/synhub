// r651（`DA251`）音频舞台的 **Up Next / 播放队列**。
//
// 判据（人视角）：
//   ① 从目录点开一首歌 → 「接下来播放」就是同目录的其它音频（不是另造一份队列）；
//   ② 只有**真的有多条**才画上一首/下一首/接下来播放（单条时不许出现点了没反应的键）；
//   ③ 切歌必须真的换 URL（`play(新URL)`），并且标题/歌词跟着换；
//   ④ 自然播完 → 下一首；到队尾就停在那里（不做偷偷的"循环全部"）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/chat/voice_message.dart'
    show VoicePlaybackEnded, VoicePlayer, voicePlayerProvider;
import 'package:synhub/src/features/media/media_audio_stage.dart';
import 'package:synhub/src/features/media/media_source.dart';

class _QueuePlayer implements VoicePlayer, VoicePlaybackEnded {
  final _changes = StreamController<void>.broadcast();
  final List<String> played = [];
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration = const Duration(seconds: 180);
  @override
  bool playing = false;
  @override
  double speed = 1;
  bool _ended = false;

  @override
  bool get hasSource => played.isNotEmpty;
  @override
  String? get currentUrl => played.isEmpty ? null : played.last;
  @override
  Future<void> play(String url) async {
    played.add(url);
    position = Duration.zero;
    _ended = false;
    playing = true;
  }

  @override
  Future<void> resume() async => playing = true;
  @override
  Future<void> pause() async => playing = false;
  @override
  Future<void> stop() async => playing = false;
  @override
  Future<void> seek(Duration position) async => this.position = position;
  @override
  Future<void> setSpeed(double speed) async => this.speed = speed;
  @override
  bool get ended => _ended;
  @override
  void clearEnded() => _ended = false;

  /// 复刻 just_audio 的自然播完：先同步置 `ended`，位置已被异步复位成 0
  void naturalEnd() {
    playing = false;
    _ended = true;
    position = Duration.zero;
    _changes.add(null);
  }

  /// 只再通知一帧（`ended` 不变）—— 用来复现"换歌瞬间还留着上一首的 ended"
  void emit() => _changes.add(null);
  @override
  Stream<void> get changes => _changes.stream;
}

FileEntryDto _entryFor(String path, String name) => FileEntryDto(
  name: name,
  path: path,
  isDir: false,
  size: 4096,
  mtime: 1758100000,
);

MediaSource _audio(String name, String path) => MediaSource(
  uri: 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download&path=$path',
  channel: MediaChannel.fileStation,
  kind: MediaKind.audio,
  displayName: name,
  supportsRange: true,
);

void main() {
  group('DA251 音频 Up Next / 播放队列', () {
    Future<_QueuePlayer> pump(
      WidgetTester tester, {
      List<MediaSource>? playlist,
      int index = 0,
    }) async {
      final player = _QueuePlayer();
      final container = ProviderContainer(
        overrides: [voicePlayerProvider.overrideWithValue(player)],
      );
      addTearDown(container.dispose);
      final items =
          playlist ??
          [
            _audio('01 - a.mp3', '/music/a.mp3'),
            _audio('02 - b.mp3', '/music/b.mp3'),
          ];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: MediaAudioStage(
                entry: _entryFor('/music/a.mp3', items[index].displayName),
                source: items[index],
                playlist: items,
                playlistIndex: index,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      return player;
    }

    testWidgets('多条队列：上一首 / 下一首 / 接下来播放都出现，且点下一首真的换 URL', (tester) async {
      final player = await pump(tester);
      expect(find.byKey(const Key('audio-previous')), findsOneWidget);
      expect(find.byKey(const Key('audio-next')), findsOneWidget);
      expect(find.byKey(const Key('audio-up-next')), findsOneWidget);

      // 先播起来再切歌：切歌必须换 URL（不是 resume 同一个来源）
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.played.single, contains('/music/a.mp3'));

      await tester.tap(find.byKey(const Key('audio-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(player.played.last, contains('/music/b.mp3'), reason: '下一首必须真的换来源');
      expect(find.text('02 - b.mp3'), findsWidgets, reason: '标题要跟着换歌');
    });

    testWidgets('「接下来播放」列出队列、当前那条打勾、点第 2 条就播第 2 条', (tester) async {
      final player = await pump(
        tester,
        playlist: [
          _audio('01 - a.mp3', '/music/a.mp3'),
          _audio('02 - b.mp3', '/music/b.mp3'),
          _audio('03 - c.mp3', '/music/c.mp3'),
        ],
      );
      await tester.tap(find.byKey(const Key('audio-up-next')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-up-next-sheet')), findsOneWidget);
      expect(find.byKey(const Key('audio-up-next-count')), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('audio-up-next-2')));
      await tester.pumpAndSettle();
      expect(player.played.last, contains('/music/c.mp3'));
    });

    testWidgets('自然播完 → 下一首，且只切**一次**（真机缺陷：02 播完直接跳 04）', (tester) async {
      final player = await pump(
        tester,
        playlist: [
          _audio('01 - a.mp3', '/music/a.mp3'),
          _audio('02 - b.mp3', '/music/b.mp3'),
          _audio('03 - c.mp3', '/music/c.mp3'),
        ],
      );
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      player.naturalEnd();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(player.played.last, contains('/music/b.mp3'), reason: '播完要接下一首');

      // 换歌瞬间播放器还留着上一首的 `ended`：再通知两帧也不许再切一首
      player.emit();
      await tester.pump();
      player.emit();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        player.played.where((u) => u.contains('/music/c.mp3')),
        isEmpty,
        reason: '一次"播完"只许前进一首（认边沿，不认电平）',
      );

      // 新歌真的播起来（ended 清掉）之后，再播完才轮到第三首
      player.clearEnded();
      player.playing = true;
      player.emit();
      await tester.pump();
      player.naturalEnd();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(player.played.last, contains('/music/c.mp3'));
    });

    testWidgets('自然播完到队尾：停在那里，不偷偷绕回队首', (tester) async {
      final player = await pump(
        tester,
        playlist: [
          _audio('01 - a.mp3', '/music/a.mp3'),
          _audio('02 - b.mp3', '/music/b.mp3'),
        ],
        index: 1,
      );
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      final before = List<String>.of(player.played);
      player.naturalEnd();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(player.played, before, reason: '队尾播完不许自动绕回第一条');
    });

    testWidgets('反向：只有一条时不画上一首/下一首/接下来播放（不放点了没反应的键）', (tester) async {
      await pump(
        tester,
        playlist: [_audio('01 - a.mp3', '/music/a.mp3')],
      );
      expect(find.byKey(const Key('audio-previous')), findsNothing);
      expect(find.byKey(const Key('audio-next')), findsNothing);
      expect(find.byKey(const Key('audio-up-next')), findsNothing);
    });

    testWidgets('反向：上一首越界不动作（队首点「上一首」不许把播放器弄停）', (tester) async {
      final player = await pump(tester);
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      final before = List<String>.of(player.played);
      await tester.tap(find.byKey(const Key('audio-previous')));
      await tester.pump();
      expect(player.played, before, reason: '队首的「上一首」必须是 no-op');
    });
  });
}
