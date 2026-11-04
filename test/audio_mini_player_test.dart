// 全局「正在播放」迷你条（r633）——**DA215**。
//
// 审计现场（真机）：电台在播 → 退回音乐列表/工作台 ⇒ 整屏**没有任何地方**
// 能看见它、也没有地方能暂停；唯一出口是重新走进电台页（`_RadioNowPlayingBar`
// 只挂在 `audio_radio_page.dart` 里，`lib/src/features/shell/app_shell_page.dart`
// 之前**没有**任何播放条）。
//
// 判据（每条都要能红）：
//   ① 没在播 → 不出现、零占位（`SizedBox.shrink`）；
//   ② 电台在播 → 出现；标题对；副标题说人话（不许出现 `kbps`）；
//      点播放/暂停**真的**打到引擎；
//   ③ 音乐在播 → 副标题是「歌手 · 专辑」；
//   ④ 反向：`kind` 说了算 —— id 长得像电台、`kind` 是歌曲时，
//      点开必须是单曲页（**不许**按 id 前缀猜，否则自定义电台与歌曲会互相走错页）；
//   ⑤ 停播（idle）→ 条消失，不留"在播"的假信息。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/audio/audio_mini_player.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';
import 'package:synhub/src/features/media/audio_handler.dart';

import 'support/fake_audio_player.dart';

Future<FakeAudioStationPlayer> _pump(WidgetTester tester) async {
  final player = FakeAudioStationPlayer();
  final c = ProviderContainer(
    overrides: [audioStationPlayerProvider.overrideWithValue(player)],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Column(
            children: <Widget>[
              Spacer(),
              AudioMiniPlayer(),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return player;
}

Future<void> _start(
  WidgetTester tester,
  ProviderContainer c, {
  required String id,
  required String title,
  String artist = '',
  String album = '',
  AudioTrackKind kind = AudioTrackKind.song,
}) async {
  final handler = c.read(audioHandlerProvider);
  await handler.startQueue([
    AudioTrackInfo(
      id: id,
      url: 'http://127.0.0.1:1/x',
      title: title,
      artist: artist,
      album: album,
      kind: kind,
    ),
  ]);
  await tester.pumpAndSettle();
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(AudioMiniPlayer)));

void main() {
  testWidgets('① 没在播 → 迷你条不出现（零占位，不假装）', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('audio-mini-player')), findsNothing);
  });

  testWidgets('② 电台在播 → 出现；副标题说人话；暂停键真的暂停', (tester) async {
    await _pump(tester);
    final c = _containerOf(tester);
    await _start(
      tester,
      c,
      id: 'radio_blues',
      title: 'Blues Radio',
      artist: 'MP3 (192 kbps)',
      kind: AudioTrackKind.radio,
    );

    expect(find.byKey(const Key('audio-mini-player')), findsOneWidget);
    expect(find.text('Blues Radio'), findsOneWidget);
    // 人话：状态词在，码率不许上屏（r631/DA214 同一口径）
    final subtitle = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('audio-mini-player')),
        matching: find.byType(Text),
      ).last,
    );
    expect(subtitle.data, contains('正在播放'));
    expect(subtitle.data, isNot(contains('kbps')));

    await tester.tap(find.byKey(const Key('audio-mini-toggle')));
    await tester.pumpAndSettle();
    final player = c.read(audioStationPlayerProvider) as FakeAudioStationPlayer;
    expect(player.pauses, 1, reason: '迷你条的暂停键必须真的打到引擎');
  });

  testWidgets('③ 音乐在播 → 副标题是「歌手 · 专辑」', (tester) async {
    await _pump(tester);
    final c = _containerOf(tester);
    await _start(
      tester,
      c,
      id: 'music_abc',
      title: 'Demo Song',
      artist: 'Demo Artist',
      album: '00s Love Songs',
    );
    final bar = find.byKey(const Key('audio-mini-player'));
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.text('Demo Artist · 00s Love Songs')),
      findsOneWidget,
    );
  });

  testWidgets('④ 反向：判据是 kind 不是 id 前缀（id 像电台但 kind=歌曲 ⇒ 单曲页）',
      (tester) async {
    await _pump(tester);
    final c = _containerOf(tester);
    await _start(tester, c, id: 'radio_lookalike', title: '其实是一首歌');

    await tester.tap(find.byKey(const Key('audio-mini-open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byType(AudioSongDetailPage),
      findsOneWidget,
      reason: 'r633：歌曲条目点开必须进单曲页（按 id 前缀猜会把它当电台）',
    );
    expect(find.byKey(const Key('as-radio-sheet')), findsNothing);
  });

  test('⑥ 挂载点：外壳底栏 + 音乐模块页**两处**都要有（真机补修）', () {
    // 真机现场：从「Workspace → Music」进来是**独立路由**（盖住外壳），
    // 只在 `app_shell_page` 挂迷你条 ⇒ 播放中回到音乐列表时屏幕底部空的
    // （`docs/evidence-r633/device/24_music_list_no_mini.png`）。
    final shell = File(
      'lib/src/features/shell/app_shell_page.dart',
    ).readAsStringSync();
    final audioPage = File(
      'lib/src/features/audio/audio_page.dart',
    ).readAsStringSync();
    expect(shell.contains('const AudioMiniPlayer()'), isTrue,
        reason: 'DA215：外壳（Chat/Files/Photos/Workspace/Me）要有迷你条');
    expect(audioPage.contains('bottomNavigationBar: const AudioMiniPlayer()'),
        isTrue,
        reason: 'DA215：音乐模块页是独立路由，也必须有迷你条');
  });

  testWidgets('⑤ 停播 → 条消失，不留"在播"的假信息', (tester) async {
    await _pump(tester);
    final c = _containerOf(tester);
    await _start(tester, c, id: 'radio_blues', title: 'Blues Radio',
        kind: AudioTrackKind.radio);
    expect(find.byKey(const Key('audio-mini-player')), findsOneWidget);

    await c.read(audioHandlerProvider).stop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-mini-player')), findsNothing);
  });
}
