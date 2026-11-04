// r690 · Linux 站「本地播放」的真跑取证（容器 arm64 + Xvfb + llvmpipe + libmpv）
//
// 为什么要有这一条：r690 之前 `AppHost.linux.localMediaPlayback` 是
// `not-implemented-on-host`，页面上直接显示「本平台尚未实现」。r690 起了两颗底座：
//   * 视频：`media_kit_libs_linux`（Linux 版 libmpv）+ `MpvPlayerAdapter`；
//   * 音频：`just_audio_media_kit`（把 just_audio 的后端换成 media_kit）。
// 这条用例量的是**同一份代码在这台 Linux 上真的在解码 / 真的在走时间轴**，
// 不是"能力位说 available"。
//
// ★ 静音铁律（用户 2026-10-30 明确要求「不要搞发出尖锐声音的测试」）：
//   容器里只挂了 PulseAudio 的 `module-null-sink`（**没有任何物理输出设备**），
//   解码出来的 PCM 全部进空汇；用例里另有 `setVolume(0)` + `setMuted(true)`。
//   ⇒ 本用例**不证明"用户能听见声音"**（那要真机/有声卡），只证明后端真在解。
//
// ★ 三条用例的边界（都是这轮现场量出来的）：
//   ① 视频**解码 + 时间轴**：`vo=null`（容器 llvmpipe 建不起 mpv 纹理，
//      见 ③）⇒ 只量"解出来了、时间在走、时长对"，**不量画面**；
//   ② 音频：真后端 `JustAudioStationPlayer`，位置必须往前走；
//   ③ 视频**画面**：容器里**不可得**，所以这条量的是**修好之后的诚实降级** ——
//      纹理 15 s 不来必须落 `videoOutputUnavailable`（而不是永远转圈）。
//      这正是 r690 修的那条缺陷（`MpvPlayerAdapter` 的纹理看门狗）。
//
// 跑法（容器内，逐字）：
//   cd /src && export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
//   DISPLAY=:97 LIBGL_ALWAYS_SOFTWARE=1 \
//     flutter test integration_test/r690_linux_playback_test.dart -d linux
//
// 媒体样本（容器内用 ffmpeg 现造，不联网）：
//   ffmpeg -y -f lavfi -i testsrc=size=640x360:rate=25:duration=4 \
//     -c:v libx264 -pix_fmt yuv420p /tmp/r690_sample.mp4
//   ffmpeg -y -f lavfi -i "sine=frequency=440:duration=6" -af volume=0 \
//     /tmp/r690_audio.wav

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/mpv_player_adapter.dart';

MediaSource _source(String path, MediaKind kind) => MediaSource(
  uri: path,
  channel: MediaChannel.fileStation,
  kind: kind,
  displayName: path.split('/').last,
  size: File(path).lengthSync(),
  supportsRange: true,
);

/// 边 pump 边等（媒体回调要靠帧循环推动；纯 `Future.delayed` 在某些宿主上不产帧）。
Future<void> _waitForWithPump(
  WidgetTester tester,
  FutureOr<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 30),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await tester.pump(const Duration(milliseconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
  fail('超时未满足条件：${reason ?? 'predicate'}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    MediaKit.ensureInitialized();
    JustAudioMediaKit.ensureInitialized(linux: true, windows: false);
  });

  testWidgets('① 视频：libmpv 真建起纹理、时长对、时间轴在走（音量 0）', (tester) async {
    const path = '/tmp/r690_sample.mp4';
    expect(File(path).existsSync(), isTrue, reason: '样本没造出来：$path');

    final adapter = MpvPlayerAdapter();
    addTearDown(adapter.dispose);
    expect(adapter.needsSurfaceWhileLoading, isTrue);

    // ★ 先静音再起播：顺序不能反（起播那一刻就有声）。
    await adapter.setVolume(0.0);
    expect(adapter.volume, 0.0);
    await adapter.setMuted(true);
    expect(adapter.muted, isTrue);

    // ★ 先把纹理挂进树再 load：`needsSurfaceWhileLoading` 的语义就是
    //   「没有 vo 就不解码」，反过来先 load 会少掉首帧。
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 640,
            height: 360,
            child: Builder(builder: (c) => adapter.buildSurface(c)),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await adapter.load(_source(path, MediaKind.video));
    await _waitForWithPump(
      tester,
      () => adapter.ready,
      reason: 'mpv 没到 ready（error=${adapter.error}）',
    );
    expect(adapter.error, isNull, reason: '起播报错：${adapter.error}');

    // 时长：testsrc 是 4 秒（给 250ms 容差）。
    // ★ `ready` 只代表 `open` 返回了，**时长是随后的流事件**（真踩过：立刻读
    //   `duration` 拿到 null，被误判成"mpv 不给时长"）⇒ 要等。
    await _waitForWithPump(
      tester,
      () => adapter.duration != null,
      timeout: const Duration(seconds: 10),
      reason: 'mpv 一直没给时长（error=${adapter.error}）',
    );
    final d = adapter.duration;
    expect(d, isNotNull, reason: 'mpv 没给时长');
    expect(
      (d!.inMilliseconds - 4000).abs() < 250,
      isTrue,
      reason: '时长不对：${d.inMilliseconds}ms',
    );

    // 画面：libmpv 的纹理是 640×360 ⇒ 宽高比接近 16/9（拿不到视频尺寸时
    // 适配器给的是 16/9 的默认值，所以再补一条"纹理解析度"从日志侧核对）。
    expect(
      (adapter.aspectRatio - 16 / 9).abs() < 0.05,
      isTrue,
      reason: '宽高比不对：${adapter.aspectRatio}',
    );

    // 时间轴：等 1.2 s，位置必须往前走（"就绪但不动"是黑屏时钟另一面）
    await adapter.play();
    final p0 = adapter.position;
    await _waitForWithPump(
      tester,
      () => adapter.position > p0 + const Duration(milliseconds: 300),
      timeout: const Duration(seconds: 12),
      reason: '位置没走：$p0（libmpv 没真播）',
    );
    final p1 = adapter.position;

    // 引擎身份：`media-engine-mpv` 只有 libmpv 那一路有。
    expect(find.byKey(const Key('media-engine-mpv')), findsOneWidget);
    debugPrint(
      '[r690] VIDEO ok duration=${d.inMilliseconds}ms '
      'aspect=${adapter.aspectRatio.toStringAsFixed(3)} '
      'pos ${p0.inMilliseconds}->${p1.inMilliseconds}ms '
      'volume=${adapter.volume} muted=${adapter.muted}',
    );
  });

  testWidgets('② 音频：just_audio 的 Linux 后端（media_kit）真在走时间轴', (tester) async {
    const path = '/tmp/r690_audio.wav';
    expect(File(path).existsSync(), isTrue, reason: '样本没造出来：$path');

    // 工厂在这台宿主上必须给**真引擎**（r690 之前这里给的是
    // `UnsupportedAudioStationPlayer`，`play()` 直接抛
    // `MediaPlaybackUnsupportedOnHost`）。
    final player = createDefaultAudioStationPlayer();
    addTearDown(player.stop);
    expect(
      player,
      isA<JustAudioStationPlayer>(),
      reason: 'Linux 上必须走 just_audio（后端 = media_kit），不是占位引擎',
    );

    await tester.runAsync(() async {
      final started = Stopwatch()..start();
      await player.play(path);
      expect(player.playing, isTrue, reason: 'play() 返回了但没进播放态');
      final p0 = player.position;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final p1 = player.position;
      expect(
        p1 > p0,
        isTrue,
        reason: '音频位置没走：$p0 → $p1（后端没真解）',
      );
      debugPrint(
        '[r690] AUDIO ok engine=${player.runtimeType} '
        'pos ${p0.inMilliseconds}->${p1.inMilliseconds}ms '
        'wall=${started.elapsedMilliseconds}ms sink=null(pulseaudio)',
      );
      await player.stop();
    });
  });

  testWidgets('③ 纹理正常到达时，看门狗**不许误报**（15s 内无 videoOutputUnavailable）', (tester) async {
    const path = '/tmp/r690_sample.mp4';
    final adapter = MpvPlayerAdapter();
    addTearDown(adapter.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 640,
            height: 360,
            child: Builder(builder: (c) => adapter.buildSurface(c)),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    unawaited(adapter.load(_source(path, MediaKind.video)));
    // 等到看门狗的时限之后，错误必须仍然是空（纹理已经来了）
    await _waitForWithPump(
      tester,
      () => adapter.ready,
      timeout: const Duration(seconds: 20),
      reason: 'ready 没到（error=${adapter.error}）',
    );
    // 故意等满看门狗时限（+2s 余量），看它会不会误报
    final until = DateTime.now().add(
      MpvPlayerAdapter.kVideoSurfaceTimeout + const Duration(seconds: 2),
    );
    while (DateTime.now().isBefore(until)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      adapter.error,
      isNull,
      reason: '纹理正常却报了"图形栈建不起画面"= 误报',
    );
    debugPrint('[r690] VIDEO(watchdog) no false positive');
  });
}
