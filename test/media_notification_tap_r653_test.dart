// r653（`DA257`）：**点通知栏的媒体卡要回到"正在播放"那一屏**。
//
// 真机现场：用户在 Chat 里 → 点通知栏卡片 → 回来还停在 Chat
// （`docs/evidence-r653/07_tap_notification_from_chat.png`）。
// 真机日志证明了这次点击**是可区分的**：
// `ActivityTaskManager: START u0 {act=com.ryanheise.audioservice.NOTIFICATION_CLICK
//  cmp=com.openviewai.synhub/.MainActivity}` —— 系统发的是
// `audio_service` 自己的 contentIntent，而点桌面图标是 `ACTION_MAIN`。
// 所以修法不是"猜用户想干什么"，而是**把已经到手的信号用起来**：
// 原生认 action → 通道 `synhub/media_notification_tap` → 这里决定落点。
//
// 判据（每条都要能红）：
//   ① 歌曲在播 + 点通知 → 压出**单曲页**；
//   ② 电台在播 + 点通知 → 打开**电台面板**（不是单曲页）；
//   ③ 没在播（idle / 没有 `mediaItem`）→ 什么都不打开（不凭空给一个空播放页）；
//   ④ 冷启动：`getPending == true` → 也跳；且与"事件"重复到达时**只跳一次**
//      （原生两条路都可能发，Dart 侧必须幂等）。
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/audio/audio_now_playing_route.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';
import 'package:synhub/src/features/audio/media_notification_tap_host.dart';
import 'package:synhub/src/features/media/audio_handler.dart';

import 'support/fake_audio_player.dart';

const MethodChannel _channel = MethodChannel(kMediaNotificationTapChannel);
const StandardMethodCodec _codec = StandardMethodCodec();

Future<ProviderContainer> _pump(WidgetTester tester) async {
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
        home: const MediaNotificationTapHost(
          child: Scaffold(body: Text('shell')),
        ),
      ),
    ),
  );
  await tester.pump();
  return c;
}

Future<void> _start(
  WidgetTester tester,
  ProviderContainer c, {
  required String id,
  required String title,
  AudioTrackKind kind = AudioTrackKind.song,
}) async {
  final handler = c.read(audioHandlerProvider);
  await handler.startQueue([
    AudioTrackInfo(
      id: id,
      url: 'http://127.0.0.1:1/x',
      title: title,
      kind: kind,
    ),
  ]);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 模拟"原生侧点了一下媒体通知"（`onMediaNotificationTap` 事件）。
Future<void> _tapNotification(WidgetTester tester) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        kMediaNotificationTapChannel,
        _codec.encodeMethodCall(const MethodCall('onMediaNotificationTap')),
        (_) {},
      );
  // 落点是异步的（有界等待 + push），给足帧
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('① 歌曲在播 → 点通知压出单曲页', (tester) async {
    final c = await _pump(tester);
    await _start(tester, c, id: 'music_46683', title: 'Best In Me');
    expect(find.byType(AudioSongDetailPage), findsNothing);

    await _tapNotification(tester);

    expect(find.byType(AudioSongDetailPage), findsOneWidget);
    expect(
      tester.widget<AudioSongDetailPage>(find.byType(AudioSongDetailPage)).title,
      'Best In Me',
    );
  });

  testWidgets('② 电台在播 → 打开电台面板（不是单曲页）', (tester) async {
    final c = await _pump(tester);
    await _start(
      tester,
      c,
      id: 'radio_blues',
      title: 'Blues Radio',
      kind: AudioTrackKind.radio,
    );

    await _tapNotification(tester);

    expect(find.byKey(const Key('as-radio-sheet')), findsOneWidget);
    expect(find.byType(AudioSongDetailPage), findsNothing);
  });

  testWidgets('③ 没在播 → 什么都不打开（有界等待后放弃）', (tester) async {
    await _pump(tester);

    await _tapNotification(tester);
    // 顺序等满"等音频服务连上"的窗口（20 × 150ms = 3s），仍不该开页
    // ★ 必须**等满**：不等满就会留下一个未触发的 Timer（用例会红"Timer still pending"）
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(find.byType(AudioSongDetailPage), findsNothing);
    expect(find.byKey(const Key('as-radio-sheet')), findsNothing);
  });

  testWidgets('④ 冷启动 getPending=true 也跳；与事件重复到达只跳一次', (tester) async {
    final player = FakeAudioStationPlayer();
    final c = ProviderContainer(
      overrides: [audioStationPlayerProvider.overrideWithValue(player)],
    );
    addTearDown(c.dispose);

    // 原生侧"冷启动时带着 NOTIFICATION_CLICK 的 intent"
    var pending = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'getPending') {
            final v = pending;
            pending = false;
            return v;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    // 冷启动：先装壳（`mediaItem` 还没到位）—— host 会等
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const MediaNotificationTapHost(
            child: Scaffold(body: Text('shell')),
          ),
        ),
      ),
    );
    await tester.pump();
    await _start(tester, c, id: 'music_cold', title: 'Cold Start Song');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AudioSongDetailPage), findsOneWidget);

    // 同一次点击的"事件"再补一遍 —— 不许再压第二页
    await _tapNotification(tester);
    expect(find.byType(AudioSongDetailPage), findsOneWidget);
  });

  test('⑤ 落点判据是 kind（缺失时回落歌曲，不按 id 前缀猜）', () {
    final radio = MediaItem(
      id: 'music_looks_like_song',
      title: 'x',
      extras: const <String, Object>{'kind': 'radio'},
    );
    final song = MediaItem(id: 'radio_looks_like_radio', title: 'y');
    expect(nowPlayingIsRadio(radio), isTrue);
    expect(nowPlayingIsRadio(song), isFalse);
  });
}
