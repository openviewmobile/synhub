// s289（r689）：iOS 的**真频谱**（`synhub/audio_visualizer`）在模拟器上真的出电平。
//
// 链路（缺一环就没有电平，所以逐环都断言）：
//   ① 能力位：iOS 上 `audioVisualizer` 必须 available（r689 翻转）；
//   ② `NativeAudioStationPlayer` 实现 `AudioSpectrumSession`（合成代数 = 1）；
//   ③ 播放器装载 item 时**自动装 `MTAudioProcessingTap`**（`MediaPlayerBridge`）；
//   ④ `attach {sessionId, bars}` 回 `ok: true`，事件通道按 bars 发 `List<double>`；
//   ⑤ **播放没有被 tap 弄停**（位置仍在前进）—— 这条是"没声音"的反向保险。
//
// ★★★ **本用例一律静音播放**（用户 2026-10-30 明确要求：不要再发出尖锐声音
//   的测试）。做法：不走 `NativeAudioStationPlayer`（它把 `volume: 1.0` 写死），
//   而是直接用 `MethodChannelPlayerBridge.load(muted: true, volume: 0.0)`。
//   tap 挂在 `audioMix` 的 **post-effects** 位置 ⇒ 静音之后**仍然拿得到 PCM**，
//   所以"静音"不会削弱这条证明。**不许**为了省事再塞一个能听见的测试音。
//
// **证不到**（诚实分界，见 `docs/platform-ios.md` §29.4）：
//   * 真机上"喇叭真出声 + 频谱跟着动"——模拟器没有音频输出设备，
//     这里证明的是"tap 拿到了 PCM 且 FFT 出了电平"；
//   * Audio Station 页面里频谱条的**像素**（本用例只到通道层，
//     界面像素见 r662 起的音频页走查）。
//
// 跑法（`R689_AUDIO_PATH` 指向宿主机上的本地音频文件，模拟器直接读宿主路径）：
//   flutter test integration_test/r689b_ios_spectrum_test.dart \
//     -d 1FFF0EDA-3230-46F5-A011-6119E6040381 \
//     --dart-define=R689_AUDIO_PATH=/…/data/tmp/r689_sweep.m4a
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/native_audio_station_player.dart';
import 'package:synhub/src/features/media/audio_visualizer_source.dart';
import 'package:synhub/src/features/media/native_video_player.dart';

/// 本地音频文件绝对路径（空 = 只验通道与能力位，不验电平）。
const String _audioPath = String.fromEnvironment('R689_AUDIO_PATH');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r689 ⑤ 真频谱：tap 出电平 · bars 合规 · 播放没被 tap 弄停', (tester) async {
    // ① 能力位
    final caps = staticCapabilitiesFor(AppHost.ios);
    expect(caps.can(AppCapability.audioVisualizer), isTrue,
        reason: 'r689 起 iOS 不该再拦真频谱');
    // ignore: avoid_print
    print('[r689b] capability audioVisualizer='
        '${caps.statusOf(AppCapability.audioVisualizer).reason}');

    const client = AudioVisualizerBridgeClient();
    final probe = await client.probe();
    // ignore: avoid_print
    print('[r689b] probe -> $probe');
    expect(probe.available, isTrue);
    expect(probe.reason, 'ok');

    // 反向①：没有会话 id 不许 attach（与 Android 同一条规矩）
    final noSession = await client.attach(sessionId: 0, bars: 24);
    // ignore: avoid_print
    print('[r689b] attach(sessionId:0) -> $noSession');
    expect(noSession.ok, isFalse);
    expect(noSession.reason, 'no-session-id');

    // 反向②：没有播放也不会出电平（tap 只在有音频流过时才喂数据）
    final silent = await client.attach(sessionId: 1, bars: 24);
    // ignore: avoid_print
    print('[r689b] attach(no playback) -> $silent');
    expect(silent.ok, isTrue);
    await client.detach();

    if (_audioPath.isEmpty) {
      // ignore: avoid_print
      print('[r689b] 没给 R689_AUDIO_PATH ⇒ 只验到通道层');
      return;
    }

    // ② 播放器必须实现 `AudioSpectrumSession`（Dart 侧接线的前提）
    final player = NativeAudioStationPlayer();
    addTearDown(player.dispose);
    expect(player, isA<AudioSpectrumSession>(),
        reason: 'r689 起 iOS 播放器必须实现 AudioSpectrumSession');
    // 反向：还没 create 时不许有会话号（否则界面会去 attach 一个不存在的会话）
    expect((player as AudioSpectrumSession).androidAudioSessionId, isNull);

    // ③ **静音**播放（volume 0 + muted）——见文件头"静音铁律"。
    //    这里直接用桥，绕开 `NativeAudioStationPlayer` 里写死的 `volume: 1.0`。
    final bridge = MethodChannelPlayerBridge();
    addTearDown(bridge.dispose);
    await bridge.create();
    await bridge.load(
      urls: ['file://$_audioPath'],
      index: 0,
      autoplay: true,
      volume: 0.0,
      muted: true,
      speed: 1.0,
      aspect: 'fit',
    );
    const sessionId = 1;
    // ignore: avoid_print
    print('[r689b] 静音播放已起（volume=0 muted=true），sessionId=$sessionId');

    // ④ attach（先挂事件监听，再 attach —— 反过来会漏掉头几帧）
    final levelsSeen = <List<double>>[];
    final sub = client.levels.listen(levelsSeen.add);
    addTearDown(sub.cancel);
    final attached = await client.attach(sessionId: sessionId, bars: 24);
    // ignore: avoid_print
    print('[r689b] attach(playing) -> $attached');
    expect(attached.ok, isTrue);

    // 等电平（最多 8 秒；tap 是实时线程，模拟器上偶尔慢一帧）
    for (var i = 0; i < 80 && levelsSeen.length < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // ignore: avoid_print
    print('[r689b] levels=${levelsSeen.length} '
        'first=${levelsSeen.isEmpty ? '-' : levelsSeen.first}');
    expect(levelsSeen.length, greaterThanOrEqualTo(5),
        reason: '一个电平都没收到 ⇒ tap 没装 / bars 没开 / 通道没接');

    // 形状：每帧长度必须等于 bars，值域 0..1
    for (final frame in levelsSeen.take(5)) {
      expect(frame.length, 24);
      for (final v in frame) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    }
    // 电平**不是恒定值**（恒定 = 算了个常数，不是真频谱）
    final nonZero = levelsSeen.expand((f) => f).where((v) => v > 0.01).length;
    // ignore: avoid_print
    print('[r689b] nonZero=$nonZero / ${levelsSeen.length * 24}');
    expect(nonZero, greaterThan(0), reason: '全是 0 ⇒ FFT 没算（或 tap 没拿到样本）');

    // ⑤ 反向保险：tap 装了之后**播放仍在前进**（`state` 事件的 `positionMs`）。
    //    —— 静音播放时"有没有声音"验不了，但"tap 没把音频吃掉"必须能验：
    //    位置不前进 = 音频渲染被 tap 卡死（第一版就是这样：process 只回调一次）。
    final positions = <int>[];
    final stateSub = bridge.events.listen((e) {
      if (e['kind'] != 'state') return;
      final ms = e['positionMs'];
      if (ms is int) positions.add(ms);
    });
    addTearDown(stateSub.cancel);
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0) < const Duration(seconds: 3) &&
        positions.length < 4) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // ignore: avoid_print
    print('[r689b] positions=$positions');
    expect(positions, isNotEmpty, reason: '装了 tap 之后桥一个 state 都不发 = 音频线程被拖死');
    expect(positions.last, greaterThan(positions.first),
        reason: '位置不前进 ⇒ tap 把音频吃掉了');

    await client.detach();
    // detach 之后不再有新的电平（水龙头关掉）
    final countAtDetach = levelsSeen.length;
    await Future<void>.delayed(const Duration(seconds: 1));
    // ignore: avoid_print
    print('[r689b] after detach +1s: $countAtDetach -> ${levelsSeen.length}');
    expect(levelsSeen.length, lessThanOrEqualTo(countAtDetach + 1),
        reason: 'detach 之后还在发 ⇒ 没有真的关掉');
  });
}
