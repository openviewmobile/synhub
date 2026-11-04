// `DA306`（r676）：**单例桥 + 每页句柄**下的"上一代事件晚到"。
//
// 现场（r675 iOS 模拟器，`/tmp/r675_video13.log`）：
//   * 点 `.mkv` / `.AVI` 后播放器页只显示**上一支 mp4** 的标题与 `00:03/10:12`；
//   * 30 秒内**没有任何兜底面板**，画面永远黑。
//
// 机制（本文件把时间序钉死）：
//   1. 桥是进程内单例（一个 `sink`、一个 EventChannel）；
//   2. 新页面订阅 ⇒ 桥 `onListen` 立刻把**当前播放器**（= 上一条视频）的快照推出去；
//   3. Dart 侧 `create()` 之后拿到的是新播放器，但那条快照**晚于** `create()` 才被
//      处理 ⇒ 原来"`_created` 之前的事件全丢"根本挡不住；
//   4. 快照里带着上一支 mp4 的 `videoWidth/videoHeight/firstFrame=true` ⇒
//      `_hasVideoOutput` 成立 ⇒ `_applyState` **撤掉看门狗** ⇒ 一个真正的
//      "无解码器"条目再也等不到判死 ⇒ 黑屏且永不兜底。
//
// 修法：桥给每个播放器实例一个**单调递增的代数**（`create()` 时 +1），事件带
// `generation`；适配器记下"我这一代"，**代数不符的事件无条件丢弃**。判据是事件
// 自己的身份，不是到达时间。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/native_video_player.dart';

/// 会记"代数"的假桥（对应 `MediaPlayerBridge.swift` / Kotlin 桥的新能力）。
class _GenBridge implements PlayerBridge, GenerationAwarePlayerBridge {
  _GenBridge();

  int _generation = 0;
  int created = 0;
  final List<Map<String, Object?>> loads = [];

  final _events = StreamController<Map<Object?, Object?>>.broadcast();

  /// 当前代数（测试里用来伪造"新播放器"的事件）
  int get currentGeneration => _generation;

  @override
  Future<int> create() async {
    created++;
    _generation += 1;
    return 7;
  }

  @override
  Future<int?> generation() async => _generation;

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
    loads.add({'urls': urls, 'index': index});
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(int positionMs) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> playNext() async {}

  @override
  Future<void> playPrevious() async {}

  @override
  Future<void> selectTrack({required String kind, String? id}) async {}

  @override
  Future<void> setAspectMode(String code) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  void emit(Map<String, Object?> event) => _events.add(event);

  void close() => _events.close();
}

MediaSource _video(String name) => MediaSource(
  uri: 'https://nas/webapi/entry.cgi?path=${Uri.encodeComponent(name)}',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: name,
  supportsRange: true,
);

/// 上一支 mp4 的典型快照（有画面证据：1920×1080 + 真的出过首帧）
Map<String, Object?> _staleSnapshot(int generation) => {
  'kind': 'state',
  'generation': generation,
  'index': 0,
  'count': 4,
  'positionMs': 3120,
  'durationMs': 612000, // 10:12
  'playing': true,
  'ready': true,
  'buffering': false,
  'ended': false,
  'videoWidth': 1920,
  'videoHeight': 1080,
  'firstFrame': true,
};

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('上一代的快照在新播放器建立之后才到 → 不许当成"我这条"的画面证据', () async {
    final bridge = _GenBridge();
    addTearDown(bridge.close);
    final adapter = NativeVideoPlayerAdapter(
      bridge: bridge,
      watchdogTimeout: const Duration(milliseconds: 40),
    );
    addTearDown(adapter.dispose);

    // 目录里 4 条、这次点的是第 3 条（index 2）—— 与 iOS 现场同构
    await adapter.setPlaylist([
      _video('01_1.mp4'),
      _video('60招基础街球S01E01.AVI'),
      _video('Citizen Kane (1941).mkv'),
      _video('U01M01.mp4'),
    ], 2);
    await adapter.play();
    // 上一代（gen 0）的快照 —— 与 iOS 现场同序：**create 之后**才投递。
    // 它还带着 `index: 0`：旧代码会把 `_index` 从 2 改回 0，并顺手打开
    // `_continuation`（"自动续播"语义）⇒ 看门狗**永远走非阻塞提示**
    // ⇒ 致命面板永远不出现（r675 的黑屏就是这么来的）。
    bridge.emit(_staleSnapshot(0));
    await _flush();

    // 旧行为：视频尺寸/首帧被算到 mkv 头上 ⇒ 看门狗被撤 ⇒ 永远黑屏不兜底
    expect(
      adapter.videoWidth,
      0,
      reason: '上一代的 1920 宽不是这一条的证据（DA306）',
    );
    expect(
      adapter.hasNoPictureContinuationNotice,
      isFalse,
      reason: '上一代的 index 不许把"用户点选的条目"降级成自动续播（DA306）',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      adapter.error,
      isNotNull,
      reason: '这条真的没有解码器 ⇒ 看门狗必须到点，交既有回退面板',
    );
  });

  test('反向：**当前代**的画面证据照样生效（过滤不许把所有事件都吞掉）', () async {
    final bridge = _GenBridge();
    addTearDown(bridge.close);
    final adapter = NativeVideoPlayerAdapter(
      bridge: bridge,
      watchdogTimeout: const Duration(milliseconds: 40),
    );
    addTearDown(adapter.dispose);

    await adapter.load(_video('clip-h264.mp4'));
    await adapter.play();
    bridge.emit(_staleSnapshot(bridge.currentGeneration));
    await _flush();

    expect(adapter.videoWidth, 1920);
    expect(adapter.videoHeight, 1080);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(adapter.error, isNull, reason: '真出画面 ⇒ 看门狗必须被撤掉');
  });

  test('桥不支持代数（没有 generation 字段）时行为不变', () async {
    final bridge = _GenBridge();
    addTearDown(bridge.close);
    final adapter = NativeVideoPlayerAdapter(
      bridge: bridge,
      watchdogTimeout: const Duration(milliseconds: 40),
    );
    addTearDown(adapter.dispose);

    await adapter.load(_video('a.mp4'));
    await adapter.play();
    final legacy = Map<String, Object?>.from(_staleSnapshot(0))
      ..remove('generation');
    bridge.emit(legacy);
    await _flush();

    expect(adapter.videoWidth, 1920, reason: '旧桥事件照旧全部处理（兼容）');
  });
}
