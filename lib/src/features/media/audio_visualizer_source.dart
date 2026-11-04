// 播放律动的**电平来源**：优先平台真频谱（`android.media.audiofx.Visualizer`），
// 拿不到就回落到由播放状态**推导**的动效。第 274 轮。
//
// ════════════════════════════════════════════════════════════════════════
// 为什么需要这一层（用户报障：「没有播放视觉特效」）
// ════════════════════════════════════════════════════════════════════════
// 第 261 轮的 `audio_visualizer.dart` 只做**推导**动效（播放位置/时长/播放态），
// 文件头当时写着"真频谱被 RECORD_AUDIO 挡住"。第 274 轮复核：
//   * 本 App 的 `AndroidManifest.xml` **本来就声明** `RECORD_AUDIO`
//     （聊天语音消息），**没有新增任何权限**；
//   * 真机 Honor LGE-AN10：`RECORD_AUDIO: granted=true`。
// ⇒ 真频谱是做得到的，只是**不能**在音频站页面**弹权限框**（那页以前从不问麦克风）。
// 所以策略是：
//   * **已经授予** → 走 `AudioVisualizerBridge`（Kotlin）要真 FFT 电平；
//   * **没授予 / 桥不可用 / attach 失败** → 回落推导动效（`derivedAudioVisualLevels`），
//     并且**如实说明**这一路不是频谱（`AudioVisualizer` 的说明句会变）。
//
// 判定逻辑集中在纯函数 [chooseAudioVisualSource] 里 —— 三个布尔量、八种组合，
// 全部可离线单测（见 `test/audio_visualizer_source_test.dart`）。
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/platform/app_platform.dart';
import '../audio/audio_player.dart';

/// 律动电平的**来源**。
enum AudioVisualSource {
  /// 平台真频谱：`android.media.audiofx.Visualizer` 的 FFT 幅值。
  platformSpectrum,

  /// 由播放位置/时长/播放态**推导**出来的动效（**不是频谱**）。
  derived,
}

/// 选哪一路电平（纯函数）。
///
/// 三条都满足才给 [AudioVisualSource.platformSpectrum]：
///   * [isAndroid]：桥只在 Android 上存在（宿主/测试环境没有平台通道）；
///   * [hasRecordAudioPermission]：`Visualizer` 的硬要求（官方文档逐字：
///     "the use of the visualizer requires the permission
///     android.permission.RECORD_AUDIO"）；
///   * [bridgeAttached]：桥探测/attach 成功（平台不支持、会话 id 拿不到时是 false）。
///
/// 任何一条不满足都**静默**回落 [AudioVisualSource.derived] —— 视觉特效降级
/// 不该打断播放，也不该弹权限框。
AudioVisualSource chooseAudioVisualSource({
  required bool isAndroid,
  required bool hasRecordAudioPermission,
  required bool bridgeAttached,
}) {
  if (!isAndroid) return AudioVisualSource.derived;
  if (!hasRecordAudioPermission) return AudioVisualSource.derived;
  if (!bridgeAttached) return AudioVisualSource.derived;
  return AudioVisualSource.platformSpectrum;
}

/// 来源的**可查询原因串**（进 logcat；`adb logcat | grep audio-visual-src` 一次捞全）。
String audioVisualSourceReason(AudioVisualSource source) => switch (source) {
  AudioVisualSource.platformSpectrum => 'audio-visual-src platform-spectrum',
  AudioVisualSource.derived => 'audio-visual-src derived',
};

/// 说明句：**真频谱**时说"真实频谱"，推导动效时只说"律动动效"。
///
/// 这一条是本次任务的硬要求：不许把推导出来的动画说成频谱。
String audioVisualizerCaptionFor(AudioVisualSource source) => switch (source) {
  AudioVisualSource.platformSpectrum => dataText(
    'audioVisualizerCaptionSpectrum',
    '真实频谱（来自本机播放输出）',
  ),
  AudioVisualSource.derived => dataText('audioVisualizerCaption', '律动动效'),
};

/// 桥的 Dart 侧客户端（唯一通道契约在这里）。
///
/// 与 `MediaPlayerBridge` / `VideoFrameBridge` 同款式：单文件 object +
/// `MainActivity` 里注册，**不新建插件工程**。
class AudioVisualizerBridgeClient {
  const AudioVisualizerBridgeClient();

  static const MethodChannel channel = MethodChannel(
    'synhub/audio_visualizer',
  );

  static const EventChannel events = EventChannel(
    'synhub/audio_visualizer/events',
  );

  /// 本机能不能出真频谱（**只读权限状态，绝不申请**）。
  ///
  /// 返回 `(available, reason)`；通道不在（宿主/测试/老构建）→ `(false, ...)`。
  ///
  /// 第 279 轮：平台判断改问 [AppPlatformCapabilities]（**不再裸看
  /// `Platform.isAndroid`**）。`mayTry` 的语义与旧的 `Platform.isAndroid` 等价
  /// —— Android 上静态结论是 `unknown` ⇒ 放过去试桥；macOS/Linux/Windows 上
  /// 是 `unavailable:not-implemented-on-host` ⇒ 连通道都不碰，原因码照实带出。
  Future<({bool available, String reason})> probe() async {
    final caps = AppPlatformCapabilities.current();
    if (!capabilityGateAllows(AppCapability.audioVisualizer)) {
      return (
        available: false,
        reason: caps.reasonOf(AppCapability.audioVisualizer),
      );
    }
    try {
      final raw = await channel.invokeMethod<Object?>('probe');
      final map = raw is Map ? raw : const <Object?, Object?>{};
      final available = map['available'] == true;
      return (
        available: available,
        reason: '${map['reason'] ?? (available ? 'ok' : 'unknown')}',
      );
    } on Object catch (e) {
      return (available: false, reason: 'channel-error:${e.runtimeType}');
    }
  }

  /// 挂上某个 audio session 的频谱采集。
  Future<({bool ok, String reason})> attach({
    required int sessionId,
    required int bars,
  }) async {
    final caps = AppPlatformCapabilities.current();
    if (!capabilityGateAllows(AppCapability.audioVisualizer)) {
      return (
        ok: false,
        reason: caps.reasonOf(AppCapability.audioVisualizer),
      );
    }
    if (sessionId <= 0) return (ok: false, reason: 'no-session-id');
    try {
      final raw = await channel.invokeMethod<Object?>('attach', <String, Object?>{
        'sessionId': sessionId,
        'bars': bars,
      });
      final map = raw is Map ? raw : const <Object?, Object?>{};
      final ok = map['ok'] == true;
      return (ok: ok, reason: '${map['reason'] ?? (ok ? 'ok' : 'unknown')}');
    } on Object catch (e) {
      return (ok: false, reason: 'channel-error:${e.runtimeType}');
    }
  }

  Future<void> detach() async {
    if (!capabilityGateAllows(AppCapability.audioVisualizer)) {
      return;
    }
    try {
      await channel.invokeMethod<Object?>('detach');
    } on Object {
      // 释放失败不阻塞（下一次 attach 会自己 release）。
    }
  }

  /// 真频谱电平（长度 = bars，每项 0..1）。**没有 attach 成功时不会发事件**。
  Stream<List<double>> get levels => events
      .receiveBroadcastStream()
      .where((e) => e is List)
      .map(
        (e) => <double>[
          for (final v in (e as List))
            if (v is num) v.toDouble().clamp(0.0, 1.0),
        ],
      );
}

/// 桥客户端（测试覆盖成假实现 → 完全不碰平台通道）。
final audioVisualizerBridgeProvider = Provider<AudioVisualizerBridgeClient>(
  (ref) => const AudioVisualizerBridgeClient(),
);

/// 真频谱电平流（`autoDispose`，按 bars 分族）。
///
/// 语义：**只在真的拿到平台频谱时才有事件**。任何一步不顺
/// （非 Android / 权限没给 / 桥不可用 / 会话 id 拿不到 / attach 失败）
/// ⇒ 流直接结束、不产生任何数据 ⇒ 界面用推导动效，并**如实换掉说明句**。
///
/// ⚠️ 反复 `attach/detach` 会打断采集，所以这里按"会话 id 变化"才重建，
/// 并在 `ref.onDispose` 里释放（与 `MediaPlayerBridge` 的生命期一致）。
final audioSpectrumLevelsProvider =
    StreamProvider.autoDispose.family<List<double>, int>((ref, bars) {
      final player = ref.watch(audioStationPlayerProvider);
      // 引擎没暴露会话 id（假实现 / 非 Android 引擎）→ 永远不会出真频谱。
      // 用 `case` 模式绑定能力接口（与 `audio_song_page` 的 gapless 同款式）。
      if (player case final AudioSpectrumSession session) {
        return _spectrumStream(ref, session, bars);
      }
      debugPrint(
        '${audioVisualSourceReason(AudioVisualSource.derived)} no-session-capability',
      );
      // 发一个**空表**而不是"什么都不发"：`StreamProvider` 在没有值时停在
      // `AsyncLoading`，而空表是明确的"这一路没有真频谱"（界面据此回落推导动效）。
      return Stream<List<double>>.value(const <double>[]);
    });

Stream<List<double>> _spectrumStream(
  Ref ref,
  AudioSpectrumSession player,
  int bars,
) {
  final client = ref.watch(audioVisualizerBridgeProvider);
  final controller = StreamController<List<double>>.broadcast();
  StreamSubscription<List<double>>? levelSub;
  StreamSubscription<int?>? sessionSub;
  var disposed = false;
  var attachedSession = 0;

  Future<void> releaseAttached() async {
    if (attachedSession == 0) return;
    attachedSession = 0;
    await levelSub?.cancel();
    levelSub = null;
    await client.detach();
  }

  sessionSub = player.androidAudioSessionIdStream.listen((id) async {
    if (disposed) return;
    if (id == null || id <= 0 || id == attachedSession) return;
    await releaseAttached();
    final probe = await client.probe();
    if (disposed) return;
    final res = await client.attach(sessionId: id, bars: bars);
    final source = chooseAudioVisualSource(
      // 第 279 轮：这里原来裸看 `Platform.isAndroid`；改成平台能力层，
      // 语义等价（Android 上是 `unknown` ⇒ 放过去试桥；桌面上是
      // `unavailable` ⇒ 直接回落推导动效，连通道都不碰）。
      isAndroid: AppPlatformCapabilities.current()
          .mayTry(AppCapability.audioVisualizer),
      hasRecordAudioPermission: probe.available,
      bridgeAttached: res.ok,
    );
    debugPrint(
      '${audioVisualSourceReason(source)} session=$id bars=$bars '
      'probe=${probe.reason} attach=${res.reason}',
    );
    if (source != AudioVisualSource.platformSpectrum) return;
    attachedSession = id;
    levelSub = client.levels.listen(
      controller.add,
      onError: (Object _) {},
    );
  });

  ref.onDispose(() {
    disposed = true;
    unawaited(sessionSub?.cancel());
    unawaited(levelSub?.cancel());
    unawaited(client.detach());
    unawaited(controller.close());
  });

  return controller.stream;
}
