// Audio Station 的播放器抽象（可注入）。
//
// 与聊天模块的 `voice_message.dart` 同一套路：真实实现用 `just_audio`，
// 单测里把 provider 换成假实现（`just_audio` 在纯 widget 测试里没有平台通道）。
//
// 本批（P0-2 / P0-5）在"一条 URL"之上补齐：
//   * **播放队列**（顺序播放；上限取 `Info.getinfo.playing_queue_max`，
//     真机实测 **8192**，见 `AudioInfoDto.queueMax`）；
//   * **随机 / 单曲循环 / 循环全部**（映射 `just_audio` 的
//     `setShuffleModeEnabled` 与 `LoopMode.off/one/all`，**不引入新依赖**）；
//   * **进度 / seek**（`positionStream` + `durationStream` + `seek`；
//     AS 的直传与转码流都吃 HTTP Range，真机已证，见审计 §1.7）。
//
// 后台播放 / 通知栏 / 锁屏 / 耳机按键（P0-3，本批完成）**不在本文件**：
// 本文件只做"前台引擎"（`just_audio` 的一条队列 + 进度 + 模式）；后台化由
// `lib/src/features/media/audio_handler.dart` 的 `SynologyAudioHandler`
// （`audio_service` 的 `AudioHandler`）**包住本文件的 [AudioStationPlayer]** 完成
// —— 页面从此只与 handler 说话（见 `audio_song_page.dart` 的 `_StreamSection`）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/net/media_tls_policy.dart';
import '../../core/platform/app_platform.dart';
import '../media/media_source.dart' show MediaPlaybackUnsupportedOnHost;
import '../servers/session_controller.dart';
import 'audio_effect_fallback.dart';
import 'native_audio_station_player.dart';

/// 播放队列里的一条：流式 URL + 展示信息。
///
/// [url] 由 `AudioStationApi.streamUrl` 生成（`_sid=` 鉴权 + 可选转码档位）。
class AudioQueueEntry {
  const AudioQueueEntry({required this.id, required this.url, this.title = ''});

  final String id;
  final String url;
  final String title;
}

/// 循环形态（官方播放器的"顺序 / 单曲循环 / 循环全部"）。
enum AudioRepeatMode {
  /// 顺序播完即停。
  off,

  /// 单曲循环。
  one,

  /// 循环全部。
  all,
}

/// 按 [max] 截断播放队列，并保证当前下标 [index] 指向的条目仍在队列里。
///
/// 上限来自 `Info.getinfo.playing_queue_max`（真机 **8192**，官方旧文档的
/// 500 是错的，审计 §1.4 / §6.4）；服务端没给时用
/// `AudioInfoDto.kPlayingQueueMaxFallback`。
List<AudioQueueEntry> capPlaybackQueue(
  List<AudioQueueEntry> items,
  int index,
  int max,
) {
  if (max <= 0 || items.length <= max) return items;
  final keep = items.take(max).toList();
  if (index >= max && index < items.length) {
    keep[max - 1] = items[index];
  }
  return keep;
}

/// 一个"能播队列"的播放器（界面只关心这几件事）。
abstract class AudioStationPlayer {
  /// 播放单条 URL（单曲场景；等价于只有一条的队列）。
  Future<void> play(String url);

  /// 播放一个队列；[startIndex] 是起播下标（越界会被收敛）。
  Future<void> playQueue(List<AudioQueueEntry> entries, {int startIndex = 0});

  Future<void> pause();

  /// 从暂停处继续（不重建队列 / 不重设音源）。
  Future<void> resume();

  Future<void> stop();

  /// 下一首 / 上一首（随机开启时按随机次序走，交给底层播放器）。
  Future<void> next();
  Future<void> previous();

  /// 跳到某个位置（**秒级拖动的落点**）。
  Future<void> seek(Duration position);

  /// 随机开关。
  Future<void> setShuffle(bool enabled);

  /// 循环形态。
  Future<void> setRepeat(AudioRepeatMode mode);

  /// 是否正在播放（界面按钮状态用它，别自己维护一份可能与真实状态脱节的 bool）。
  bool get playing;

  bool get shuffleEnabled;
  AudioRepeatMode get repeatMode;

  /// 当前播放的 URL（没在播就是 null）。
  String? get currentUrl;

  /// 队列里的当前下标（没队列/没在播是 -1）。
  int get currentIndex;

  /// 队列长度。
  int get queueLength;

  /// 队列内容（顺序同播放次序）。
  ///
  /// ★ 这里给的是**默认实现**（空列表）—— 既有的 4 个假实现
  /// （`audio_page_test`/`audio_background_playback_test`/
  /// `service_capability_degrade_test`/`audio_g2_test`）**无需改动**；
  /// 真播放器与需要它的假实现各自 `override`。
  /// 用途：C1 把**整个队列**的 song id 推到远程播放器。
  List<AudioQueueEntry> get queue => const [];

  /// 当前播放位置 / 总时长（未知时长给 null）。
  Duration get position;
  Duration? get duration;

  /// 播放状态 / 队列下标 / 模式变化。
  Stream<void> get changes;

  /// 位置变化（进度条用）。
  Stream<Duration> get positionStream;

  /// 时长变化（进度条用）。
  Stream<Duration?> get durationStream;
}

/// 引擎的**附加能力**：缓冲进度 / 播放中的异步错误 / 释放。
///
/// 为什么不直接加进 [AudioStationPlayer]：`implements` 要求实现**全部**成员
/// —— 既有假实现（`test/audio_page_test.dart`、`service_capability_degrade_test.dart`）
/// 会被迫补三个与它们无关的方法。这里沿用本项目既有取舍
/// （`media_player.dart` 的 `MediaPlayerFullControls`）：能力有没有是**运行时
/// 能否问到**决定的，用 `player is AudioEngineExtras` 判断，缺能力就不赌
/// （缓冲进度按 0 上报、没有异步错误源、释放退化成 `stop`）。
abstract class AudioEngineExtras {
  /// 已缓冲到的位置（后台通知栏/锁屏的缓冲进度要用）。
  Duration get bufferedPosition;

  /// 播放中**异步**失败（取流 119 / 解码 / 网络）——会话续期的触发源。
  Stream<Object> get errors;

  /// 释放底层引擎（关闭平台播放器 / 广播流）。
  Future<void> dispose();
}

/// 引擎的**无缝播放（gapless）能力**（B12）。
///
/// 为什么单列一个能力接口：`implements AudioStationPlayer` 的既有假实现
/// （`test/audio_page_test.dart` 等）不必被迫补一个与它们无关的方法 ——
/// 页面用 `player is AudioGaplessControls` 判断，缺能力就不调（与
/// [AudioEngineExtras] 同一取舍）。
///
/// 语义（对齐官方 `Utilities.supportGapless()` 的"播放器配置"定位）：
///   * 开 → 队列用 `setAudioSources(preload: true)`，`just_audio` 会**预载下一首**，
///     切歌无间隙；
///   * 关 → `preload: false`，逐条按需准备（会有可闻间隙，用于与 EQ 互斥的场合）。
abstract class AudioGaplessControls {
  Future<void> setGapless(bool enabled);

  bool get gaplessEnabled;
}

/// 引擎的**频谱可视化会话**能力（第 274 轮）。
///
/// 为什么单列一个能力接口（与 [AudioEngineExtras] / [AudioGaplessControls]
/// 同一取舍）：`implements AudioStationPlayer` 的既有假实现不必被迫补成员；
/// 界面/提供者用 `player is AudioSpectrumSession` 判断，缺能力就拿不到真频谱
/// （回落推导动效，见 `audio_visualizer_source.dart`）。
///
/// 语义：暴露底层平台播放器的 **audio session id**（Android 上 = ExoPlayer 的
/// 会话）。真频谱桥（`AudioVisualizerBridge`）需要它才能只采集**这一路**输出。
/// **不暴露也不新建任何播放能力** —— 播放仍然只有这一条路径。
abstract class AudioSpectrumSession {
  /// 当前 audio session id（null = 还没建 / 平台不给）。
  int? get androidAudioSessionId;

  /// session id 变化流（建会话 / 换音源时会发）。
  Stream<int?> get androidAudioSessionIdStream;
}

/// 原生均衡器的能力信息（与引擎无关的领域对象）。
class AudioEqualizerInfo {
  const AudioEqualizerInfo({
    required this.minDecibels,
    required this.maxDecibels,
    required this.centerFrequencies,
  });

  final double minDecibels;
  final double maxDecibels;

  /// 各频段中心频率（Hz），顺序与平台一致。
  final List<double> centerFrequencies;

  int get bands => centerFrequencies.length;
}

/// 引擎的**原生均衡器**能力（第 368 轮）。
///
/// ★ 为什么不能靠"把会话 id 透传给平台通道"：真机实测（HONOR LGE-AN10 /
/// Android 12）Dart 侧 `androidAudioSessionId` **拿不到**（同源的"真频谱"
/// 也因此一直回落推导动效；`dumpsys media.audio_flinger` 里 **0 条 effect
/// chain** 佐证），所以 `Equalizer(0, <session>)` 的入参永远是 0 ——
/// 而 `session 0`（全局混音）在本机直接 `RuntimeException … Error: -3`
/// （`AudioEffect.ERROR_NO_INIT`）。`just_audio` 的 `AudioPipeline` 由**插件
/// 自己**在会话就绪后挂 `Equalizer(0, <真会话>)`，不依赖 Dart 拿 id。
///
/// 与 [AudioSpectrumSession] 同一取舍：单列能力接口，既有假实现不必被迫补成员；
/// `player is AudioEqualizerControls` 拿不到就回落平台通道（旧路径）。
abstract class AudioEqualizerControls {
  /// 原生均衡器信息；没接线 / 平台还没接上（没起播）→ null。
  Future<AudioEqualizerInfo?> equalizerInfo();

  /// 开关原生均衡器（未接线时由插件在接上后自行恢复）。
  Future<void> setEqualizerEnabled(bool enabled);
}

/// 真实实现（`just_audio`）。
///
/// Audio Station 的 `Stream.stream` / `transcode` 都支持 HTTP Range
/// （审计 §1.7：直传带 `Accept-Ranges: bytes`；转码流带 `Range:` 仍回
/// 206 + `Content-Range`），`just_audio` 的 seek 正需要服务端支持 Range。
class JustAudioStationPlayer
    implements
        AudioStationPlayer,
        AudioEngineExtras,
        AudioGaplessControls,
        AudioSpectrumSession,
        AudioEqualizerControls {
  JustAudioStationPlayer() {
    _player = _buildPlayer();
  }

  final _equalizer = AndroidEqualizer();

  /// ★ 368：把原生均衡器**挂进播放管道** —— 效果由插件在真会话上建，
  /// 不依赖 Dart 拿到 `androidAudioSessionId`。非 Android 平台不挂。
  static bool get _nativeEqAllowed =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// ★ r413（DA72）：本机效果链建不起来 ⇒ **摘掉均衡器**再播（见
  /// `audio_effect_fallback.dart` 的现场与根因）。一旦置位**不再回挂**：
  /// 每次起播都重建平台，重挂只会再犯一次同样的错。
  bool _equalizerDisabled = false;

  /// 建播放器 + 接线（★ 可重建：降级时要换一个**不带效果**的实例）。
  AudioPlayer _buildPlayer() {
    final player = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: [
          if (_nativeEqAllowed && !_equalizerDisabled) _equalizer,
        ],
      ),
    );
    player.playerStateStream.listen((state) {
      _changes.add(null);
      if (state.processingState == ProcessingState.completed) {
        // 顺序播完：停在末尾并复位（循环由 `LoopMode` 负责，到不了这里）。
        unawaited(player.pause());
        unawaited(player.seek(Duration.zero));
      }
    });
    player.currentIndexStream.listen((_) => _changes.add(null));
    player.shuffleModeEnabledStream.listen((_) => _changes.add(null));
    player.loopModeStream.listen((_) => _changes.add(null));
    return player;
  }

  final _changes = StreamController<void>.broadcast();

  late AudioPlayer _player;

  List<AudioQueueEntry> _queue = const [];

  /// B12：无缝播放开关（开 = 预载下一首）。默认开 —— 官方语义下
  /// 未开 EQ 时 `supportGapless()` 为真。
  bool _gapless = true;

  @override
  bool get gaplessEnabled => _gapless;

  /// 只改下一次 `playQueue` 的行为，**不打断当前播放**。
  @override
  Future<void> setGapless(bool enabled) async {
    _gapless = enabled;
    _changes.add(null);
  }

  @override
  String? get currentUrl {
    final i = currentIndex;
    return i < 0 || i >= _queue.length ? null : _queue[i].url;
  }

  @override
  bool get playing => _player.playing;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  /// 平台 audio session id（真频谱桥要用它；见 [AudioSpectrumSession]）。
  @override
  int? get androidAudioSessionId => _player.androidAudioSessionId;

  @override
  Stream<int?> get androidAudioSessionIdStream =>
      _player.androidAudioSessionIdStream;

  /// ★ 368：原生均衡器信息（`just_audio` 的 `AndroidEqualizer`）。
  ///
  /// 平台的 `parameters` 只在播放器**接上平台之后**才回来 —— 没起播时会一直
  /// 挂着，所以调用方（`AudioEqualizerController`）必须自己加超时，
  /// 本方法不吞也不造数据。
  @override
  Future<AudioEqualizerInfo?> equalizerInfo() async {
    // ★ r413：已降级 ⇒ **立刻**如实回"不可用"（不假装、也不让调用方等超时）。
    if (_equalizerDisabled) return null;
    try {
      final params = await _equalizer.parameters;
      return AudioEqualizerInfo(
        minDecibels: params.minDecibels,
        maxDecibels: params.maxDecibels,
        centerFrequencies: [
          for (final b in params.bands) b.centerFrequency,
        ],
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setEqualizerEnabled(bool enabled) async {
    // ★ r413：降级后没有可写对象 —— 静默 return（界面已按 `available=false`
    // 显示"本机不可用"，这里再抛错只会把真相说成"设置失败"）。
    if (_equalizerDisabled) return;
    await _equalizer.setEnabled(enabled);
  }

  /// 通知栏/锁屏的缓冲进度（`just_audio` 的 `bufferedPosition`）。
  @override
  Duration get bufferedPosition => _player.bufferedPosition;

  /// 播放中的异步失败（`just_audio` 的 `errorStream`）——会话过期自动续期的触发源。
  @override
  Stream<Object> get errors => _player.errorStream;

  @override
  Future<void> dispose() async {
    await _player.dispose();
    await _changes.close();
  }

  @override
  Duration get position => _player.position;

  @override
  Duration? get duration => _player.duration;

  @override
  int get currentIndex => _player.currentIndex ?? (_queue.isEmpty ? -1 : 0);

  @override
  int get queueLength => _queue.length;

  @override
  List<AudioQueueEntry> get queue => _queue;

  @override
  bool get shuffleEnabled => _player.shuffleModeEnabled;

  @override
  AudioRepeatMode get repeatMode => switch (_player.loopMode) {
    LoopMode.one => AudioRepeatMode.one,
    LoopMode.all => AudioRepeatMode.all,
    LoopMode.off => AudioRepeatMode.off,
  };

  @override
  Future<void> play(String url) =>
      playQueue([AudioQueueEntry(id: url, url: url)]);

  @override
  Future<void> playQueue(
    List<AudioQueueEntry> entries, {
    int startIndex = 0,
  }) async {
    if (entries.isEmpty) return;
    _queue = List.unmodifiable(entries);
    final start = startIndex.clamp(0, entries.length - 1);
    List<AudioSource> sources() => [
      for (final e in entries) AudioSource.uri(Uri.parse(e.url), tag: e.title),
    ];
    try {
      await _player.setAudioSources(
        sources(),
        initialIndex: start,
        // B12：gapless 开 → 预载下一首（切歌无间隙）；关 → 按需准备。
        preload: _gapless,
      );
    } catch (e) {
      // ★ r413（DA72）：效果链建不起来时**别把主功能带死** —— 摘掉均衡器
      // 重建播放器再试一次（**只一次**；别的错误原样抛给页面分类提示）。
      if (!shouldFallbackToNoEqualizer(e, alreadyDegraded: _equalizerDisabled)) {
        rethrow;
      }
      debugPrint(
        '[audio-station] eq-unavailable → retry without equalizer: $e',
      );
      await _degradeWithoutEqualizer();
      await _player.setAudioSources(
        sources(),
        initialIndex: start,
        preload: _gapless,
      );
    }
    unawaited(_player.play());
  }

  /// 摘掉均衡器：换一个**不带 `androidAudioEffects`** 的播放器实例。
  ///
  /// 为什么必须换实例：`just_audio` 的 `AudioPipeline` 在 `AudioPlayer`
  /// 构造期绑定，效果列表在那次 `_setPlatformActive()` 里就已经发给平台了。
  Future<void> _degradeWithoutEqualizer() async {
    _equalizerDisabled = true;
    final old = _player;
    _player = _buildPlayer();
    try {
      await old.dispose();
    } catch (_) {
      // 旧实例已经在失败路径上，销毁失败不阻塞"能不能出声"
    }
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() async {
    // ★ 片尾重播一次点击（与 `R5-7` 同源）：`completed` 态下 just_audio 的
    //   `play()` 是 no-op。上面 `playerStateStream` 的监听虽会异步
    //   `pause()+seek(0)`，但那与用户点击是竞争关系 —— 第一次点击若落在复位
    //   之前就"只归零不出声、要再点一次"。与 `VideoPlayerAdapter.play`
    //   （media_player.dart）/ `MediaPlayerBridge.kt` 的 `STATE_ENDED → seekTo(0)`
    //   用同一条修法：结束态先回到起点再播。
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    await _player.play();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
  }

  @override
  Future<void> next() => _player.seekToNext();

  @override
  Future<void> previous() => _player.seekToPrevious();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setShuffle(bool enabled) =>
      _player.setShuffleModeEnabled(enabled);

  @override
  Future<void> setRepeat(AudioRepeatMode mode) => _player.setLoopMode(
    switch (mode) {
      AudioRepeatMode.off => LoopMode.off,
      AudioRepeatMode.one => LoopMode.one,
      AudioRepeatMode.all => LoopMode.all,
    },
  );
}

/// **本宿主没有本地播放实现**时的占位引擎（第 156 轮 Linux 站走查发现）。
///
/// 为什么不复用 [JustAudioStationPlayer] 再"就让它报错"：后者的构造函数就会
/// `AudioPlayer()`，而 `just_audio` 在第一次触碰平台时这样写：
///
/// ```dart
/// try { pluginPlatform.disposeAllPlayers(DisposeAllPlayersRequest()); } catch (e) {}
/// ```
///
/// `disposeAllPlayers` **返回 Future** ⇒ `MissingPluginException` 是**异步**
/// 完成的，这个同步 `catch` 抓不到 ⇒ 真跑里出现一个**没人接的**异步异常
/// （原始证据 `/private/tmp/r134_walk3.log`：
/// `MissingPluginException(No implementation found for method disposeAllPlayers
/// on channel com.ryanheise.just_audio.methods)`，整轮测试因此 `-1`）。
///
/// 语义：**不假装能播，也不偷偷降级成别的原因**。浏览/搜索/歌单/曲目元数据照旧
/// （那是 API 能力，本平台可用）；只有"起播"这一步诚实地抛
/// [MediaPlaybackUnsupportedOnHost] ⇒ 页面按既有 `classifyPlayerError` 显示
/// [MediaUnavailableReason.platformUnsupported]（"此平台尚未实现"），
/// 而不是把平台结论说成"这个文件播放失败"。
class UnsupportedAudioStationPlayer
    implements AudioStationPlayer, AudioEngineExtras {
  UnsupportedAudioStationPlayer();

  final _changes = StreamController<void>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  Never _unsupported() => throw const MediaPlaybackUnsupportedOnHost();

  @override
  Future<void> play(String url) async => _unsupported();

  /// 空队列是"什么都不用播"（`AudioHandler.startQueue` 对空队列本来就早退），
  /// 不算失败；真给了曲目才抛"平台未实现"。
  @override
  Future<void> playQueue(List<AudioQueueEntry> entries, {int startIndex = 0}) async {
    if (entries.isEmpty) return;
    _unsupported();
  }

  @override
  Future<void> resume() async => _unsupported();

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

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

  @override
  bool get playing => false;

  @override
  bool get shuffleEnabled => false;

  @override
  AudioRepeatMode get repeatMode => AudioRepeatMode.off;

  @override
  String? get currentUrl => null;

  @override
  int get currentIndex => -1;

  @override
  int get queueLength => 0;

  @override
  List<AudioQueueEntry> get queue => const [];

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  Duration get bufferedPosition => Duration.zero;

  /// 起播失败走**抛异常**（页面 catch → `classifyPlayerError`），这条流只用于
  /// "播起来之后才出的异步失败" ⇒ 这里永远不发声。
  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Future<void> dispose() async {
    await _changes.close();
    await _positions.close();
    await _durations.close();
    await _errors.close();
  }
}

/// 默认音频引擎。
///
/// * **iOS / macOS + 自研原生播放器开启** ⇒ [NativeAudioStationPlayer]
///   （`synhub/player` 的 AVPlayer 桥，两家 Apple 平台共用同一份 Swift 源码）。
///   理由见该文件头：`just_audio` 的 darwin 实现对真 NAS
///   "证书链合法但主机名不匹配"的流**握不上手**
///   （r87 实测 `-1202 NSURLErrorServerCertificateUntrusted`），而它是唯一
///   接了 scoped TLS 政策的取流路径；
/// * 其余平台 ⇒ [JustAudioStationPlayer]（**行为一字不改**；`flutter_test` 里
///   `defaultTargetPlatform` 是 android，所以既有用例走不到新分支）。
///
/// ★ 第 92 轮补 iOS：判定走 `defaultTargetPlatform`（界面平台，正是这里要选的
/// 那一列），**不是** `dart:io Platform.isMacOS/isIOS` —— 后者在测试宿主上
/// 也为真，会悄悄改变既有用例的前提（AGENTS §2.0.11 第 2 条）。
AudioStationPlayer createDefaultAudioStationPlayer() {
  if (kIsWeb) return JustAudioStationPlayer();
  if (defaultTargetPlatform == TargetPlatform.iOS &&
      MediaTlsPolicy.iosNativePlayerEnabled) {
    return NativeAudioStationPlayer();
  }
  if (defaultTargetPlatform == TargetPlatform.macOS &&
      MediaTlsPolicy.macosNativePlayerEnabled) {
    return NativeAudioStationPlayer();
  }
  // ★ 第 156 轮（Linux 站逐屏走查真跑发现）：**这家平台没有本地播放实现**时，
  //   不许再构造 [JustAudioStationPlayer] —— 它的构造函数就会 `AudioPlayer()`
  //   ⇒ 撞 `MissingPluginException`（`init` 被页面 catch 成"播放失败"，
  //   `disposeAllPlayers` 更是**没人接**的异步异常，见
  //   [UnsupportedAudioStationPlayer] 的文档）。
  //
  //   判定**只认"本宿主确实没有实现"的那几家**（不按能力位一刀切）：
  //   `localMediaPlayback` 在 web 上也被 fail-closed 写成 `unavailable`
  //   （AGENTS §2.0.25 的纪律），而 web 上 `just_audio_web` **确实存在**
  //   ⇒ 拿能力位当判据会把 web 一起改坏。
  //
  //   ★ r295：**Windows 并入 Linux 这一支**。原注释写"Windows 同型但本轮不动
  //   （没有 Windows 宿主）"—— 这个前提在本轮**已经消失**：真 Windows VM 上
  //   实测到同一缺陷（`MissingPluginException(init / disposeAllPlayers on
  //   com.ryanheise.just_audio.methods)`），且能力矩阵里
  //   `AppHost.windows.localMediaPlayback = not-implemented-on-host`
  //   （`app_platform.dart` 的 `case AppHost.windows:`）⇒ 两家判据一致。
  //   证据：`docs/platform-windows.md` §16.2。
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows) &&
      !capabilityGateAllows(AppCapability.localMediaPlayback)) {
    return UnsupportedAudioStationPlayer();
  }
  return JustAudioStationPlayer();
}

/// 播放器（测试里覆盖成假实现）。
final audioStationPlayerProvider = Provider<AudioStationPlayer>((ref) {
  final p = createDefaultAudioStationPlayer();
  ref.onDispose(p.stop);
  // 多 NAS：切换 / 登出后，正在播的队列直链里还带着**上一个 NAS 的 sid**。
  // 会话一换就把播放停下来，别让旧凭据继续被使用（也不让用户以为听到的是
  // 新 NAS 的歌）。
  ref.listen<String?>(sessionControllerProvider.select((s) => s.activeNasId), (
    prev,
    next,
  ) {
    if (prev != next) unawaited(p.stop());
  });
  return p;
});
