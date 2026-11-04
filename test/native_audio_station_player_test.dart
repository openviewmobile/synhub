// macOS 自研音频引擎的**离线**用例：把 `synhub/player` 桥换成纯 Dart 假实现，
// 断言队列 / 随机 / 循环 / 进度 / 错误全部由 Dart 侧按语义算出来。
//
// 为什么必须有它：真机的那条路（AVFoundation + scoped TLS）在宿主上跑不了；
// "桥每次只载入一条 URL、播完由 Dart 决定下一条"这套语义**必须**能在
// 没有平台通道时被逐条钉住，否则真机只会看到"随机/循环在 macOS 上乱了"。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/media_tls_policy.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/native_audio_station_player.dart';
import 'package:synhub/src/features/media/native_video_player.dart'
    show PlayerBridge;

/// 记录调用 + 可手动注入事件的假桥。
class FakePlayerBridge implements PlayerBridge {
  final _events = StreamController<Map<Object?, Object?>>.broadcast();
  final List<String> calls = <String>[];

  List<String> lastUrls = const [];
  int lastIndex = -1;
  bool lastAutoplay = false;

  @override
  Future<int> create() async {
    calls.add('create');
    return 7;
  }

  @override
  Future<void> load({
    required List<String> urls,
    required int index,
    required bool autoplay,
    required double volume,
    required bool muted,
    required double speed,
    required String aspect,
  }) async {
    calls.add('load');
    lastUrls = urls;
    lastIndex = index;
    lastAutoplay = autoplay;
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seekTo(int positionMs) async => calls.add('seek:$positionMs');

  @override
  Future<void> setSpeed(double speed) async => calls.add('speed:$speed');

  @override
  Future<void> setVolume(double volume) async => calls.add('volume:$volume');

  @override
  Future<void> setMuted(bool muted) async => calls.add('muted:$muted');

  @override
  Future<void> playNext() async => calls.add('next');

  @override
  Future<void> playPrevious() async => calls.add('previous');

  @override
  Future<void> selectTrack({required String kind, String? id}) async =>
      calls.add('selectTrack');

  @override
  Future<void> setAspectMode(String code) async => calls.add('aspect:$code');

  @override
  Future<void> dispose() async => calls.add('dispose');

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  /// 原生 `state` 事件（形状与 `MediaPlayerBridge.kt` / Swift 一致）。
  void emitState({
    int positionMs = 0,
    int durationMs = 0,
    bool playing = false,
    bool ended = false,
    String error = '',
  }) {
    _events.add({
      'kind': 'state',
      'positionMs': positionMs,
      'durationMs': durationMs,
      'playing': playing,
      'ended': ended,
      'error': error,
    });
  }

  Future<void> close() => _events.close();
}

List<AudioQueueEntry> _queue(int n) => [
  for (var i = 0; i < n; i++)
    AudioQueueEntry(id: 's$i', url: 'https://nas/stream/$i.mp3', title: 't$i'),
];

void main() {
  late FakePlayerBridge bridge;
  late NativeAudioStationPlayer player;

  setUp(() {
    bridge = FakePlayerBridge();
    player = NativeAudioStationPlayer(bridge: bridge);
  });

  tearDown(() async {
    await player.dispose();
    await bridge.close();
  });

  test('playQueue：一次只把**当前一条**交给桥（Dart 自己管随机/循环）', () async {
    await player.playQueue(_queue(3), startIndex: 1);
    expect(bridge.lastUrls, ['https://nas/stream/1.mp3']);
    expect(bridge.lastIndex, 0);
    expect(bridge.lastAutoplay, isTrue);
    expect(player.currentIndex, 1);
    expect(player.queueLength, 3);
    expect(player.currentUrl, 'https://nas/stream/1.mp3');
    expect(player.playing, isTrue);
  });

  test('state 事件 → 位置/时长/播放态', () async {
    await player.playQueue(_queue(2));
    final positions = <Duration>[];
    final sub = player.positionStream.listen(positions.add);
    bridge.emitState(positionMs: 4200, durationMs: 231000, playing: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.position, const Duration(milliseconds: 4200));
    expect(player.duration, const Duration(milliseconds: 231000));
    expect(player.playing, isTrue);
    expect(positions, contains(const Duration(milliseconds: 4200)));
    await sub.cancel();
  });

  test('顺序播完 → 自动下一条（载入下一条 URL）', () async {
    await player.playQueue(_queue(3), startIndex: 0);
    bridge.emitState(positionMs: 1000, durationMs: 1000, ended: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.currentIndex, 1);
    expect(bridge.lastUrls, ['https://nas/stream/1.mp3']);
  });

  test('循环 off 播到最后一条 → 停在原地，不越界', () async {
    await player.playQueue(_queue(2), startIndex: 1);
    bridge.emitState(positionMs: 1000, durationMs: 1000, ended: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.currentIndex, 1);
    expect(player.playing, isFalse);
    expect(bridge.lastUrls, ['https://nas/stream/1.mp3']);
  });

  test('单曲循环 → 回到 0 并重新 play（不换条目）', () async {
    await player.playQueue(_queue(3), startIndex: 1);
    await player.setRepeat(AudioRepeatMode.one);
    bridge.calls.clear();
    bridge.emitState(positionMs: 1000, durationMs: 1000, ended: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.currentIndex, 1);
    expect(bridge.calls, containsAllInOrder(['seek:0', 'play']));
    expect(bridge.lastUrls, ['https://nas/stream/1.mp3']);
  });

  test('循环全部 → 最后一条播完回到第一条', () async {
    await player.playQueue(_queue(2), startIndex: 1);
    await player.setRepeat(AudioRepeatMode.all);
    bridge.emitState(positionMs: 1000, durationMs: 1000, ended: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.currentIndex, 0);
    expect(bridge.lastUrls, ['https://nas/stream/0.mp3']);
  });

  test('随机开启 → 下一条**不是**当前这一条（反向验证）', () async {
    await player.playQueue(_queue(4), startIndex: 0);
    await player.setShuffle(true);
    var prev = player.currentIndex;
    for (var i = 0; i < 20; i++) {
      await player.next();
      expect(
        player.currentIndex,
        isNot(prev),
        reason: '★ 反向：随机下一条不得等于当前这一条',
      );
      prev = player.currentIndex;
    }
  });

  test('previous 在第一条 → 回到第一条（不越界）', () async {
    await player.playQueue(_queue(3), startIndex: 0);
    await player.previous();
    expect(player.currentIndex, 0);
  });

  test('resume 在播完态先 seek 0 再 play（与既有 r295 修复同语义）', () async {
    await player.playQueue(_queue(1), startIndex: 0);
    bridge.emitState(positionMs: 1000, durationMs: 1000, ended: true);
    await Future<void>.delayed(Duration.zero);
    bridge.calls.clear();
    await player.resume();
    expect(bridge.calls, containsAllInOrder(['seek:0', 'play']));
  });

  test('桥上报 error → 进 errors 流（会话续期的触发源）', () async {
    await player.playQueue(_queue(1));
    final errors = <Object>[];
    final sub = player.errors.listen(errors.add);
    bridge.emitState(error: 'bad_http_status http=401');
    await Future<void>.delayed(Duration.zero);
    expect(errors, hasLength(1));
    expect('${errors.single}', contains('401'));
    await sub.cancel();
  });

  test('bufferedPosition 如实回当前位置（不编一个更大的数）', () async {
    await player.playQueue(_queue(1));
    bridge.emitState(positionMs: 1500, durationMs: 9000, playing: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.bufferedPosition, const Duration(milliseconds: 1500));
  });

  test('★ r87 默认引擎：macOS + 开关开 ⇒ 自研桥', () {
    // 只断言**正向**这一支：另一支会 `new JustAudioStationPlayer()`，
    // 而 just_audio 的 `AudioPlayer()` 在 flutter test 里会碰平台通道（抛
    // `MissingPluginException`）⇒ 离线测不了"回退到 just_audio"的构造。
    // 回退分支由"开关关掉时 `nativePlayerEnabled` 为 false"这组纯逻辑断言
    // （`test/media_tls_policy_test.dart` 第 ④ 组）与 `isA<...>` 的类型判据共同保证。
    final prevPlatform = debugDefaultTargetPlatformOverride;
    final prevEnabled = MediaTlsPolicy.macosNativePlayerEnabled;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = prevPlatform;
      MediaTlsPolicy.macosNativePlayerEnabled = prevEnabled;
    });

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    MediaTlsPolicy.macosNativePlayerEnabled = true;
    expect(createDefaultAudioStationPlayer(), isA<NativeAudioStationPlayer>());

    // 开关关掉 ⇒ **不**走自研桥（这里只看判定，不构造 just_audio）
    MediaTlsPolicy.macosNativePlayerEnabled = false;
    final enabled = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.macOS &&
        MediaTlsPolicy.macosNativePlayerEnabled;
    expect(enabled, isFalse, reason: '★ 反向：开关关掉时必须回退');
  });

  // ★ 第 92 轮 iOS 迁移：音频引擎与视频同源 —— iOS 也走自研桥
  // （`synhub/player` 的单实例 AVPlayer；同一个 Swift 源码两平台共用），
  // 并且**反向验证**"开关关掉必须回退"。
  test('★ r92 iOS 默认引擎：iOS + 开关开 ⇒ 自研桥（反向关掉即回退）', () {
    final prevPlatform = debugDefaultTargetPlatformOverride;
    final prevEnabled = MediaTlsPolicy.iosNativePlayerEnabled;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = prevPlatform;
      MediaTlsPolicy.iosNativePlayerEnabled = prevEnabled;
    });

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    MediaTlsPolicy.iosNativePlayerEnabled = true;
    expect(createDefaultAudioStationPlayer(), isA<NativeAudioStationPlayer>());

    MediaTlsPolicy.iosNativePlayerEnabled = false;
    final enabled = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        MediaTlsPolicy.iosNativePlayerEnabled;
    expect(enabled, isFalse, reason: '★ 反向：开关关掉时必须回退');
  });
}
