// 自研 Android 原生播放器适配器（Media3 / ExoPlayer，通道见 `MediaPlayerBridge.kt`）。
//
// 为什么要有它：`video_player`（Media3 封装）**不暴露**轨道选择 / 内封字幕 /
// 音量 / 画面比例 / 播放列表跳转，也不给 texture id —— 这些只能自研原生桥。
//
// 结构（分两层，就是为了能离线单测）：
//   * [PlayerBridge]：**只有**"往原生通道发什么、从事件流收什么"。真实实现是
//     [MethodChannelPlayerBridge]（MethodChannel `synhub/player` +
//     EventChannel `synhub/player_events`）；测试注入纯 Dart 假实现，
//     于是"参数装配"和"状态回读"都不需要真的起平台通道。
//   * [NativeVideoPlayerAdapter]：把事件摊平成 `MediaPlayerAdapter` +
//     `MediaPlayerFullControls` 的状态（边界夹取、播放列表首尾、音量/画面比例
//     回读都在这一层，可被逐条断言）。
//
// 画面：原生侧用 `TextureRegistry.SurfaceProducer` 把 ExoPlayer 的
// `Surface` 交给 Flutter 引擎当纹理，Dart 侧 `Texture(textureId:)` 直接画。
// 这样**不需要 PlatformView**，控制层（Flutter widget）叠在画面之上没有任何
// 混合合成的层级问题。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/net/media_tls_policy.dart';
import '../../core/platform/app_platform.dart';
import 'fallback_player_adapter.dart';
import 'media_player.dart';
import 'mpv_player_adapter.dart';
import 'media_source.dart';
import 'media_tracks.dart';

/// 原生播放通道（方法调用）
const String kMediaPlayerChannel = 'synhub/player';

/// 原生播放事件通道（位置 / 状态 / 轨道 / 内封字幕文本）
const String kMediaPlayerEventChannel = 'synhub/player_events';

/// 「起播无进展」看门狗窗口（Bug B）。
///
/// 真机 Theora `.mkv` 的表现：`ExoPlayerImpl Init` 之后**既没有**
/// `onPlayerError`、也**没有**首帧/视频尺寸事件 —— Media3 只是不出画面，页面
/// 于是黑屏且没有任何提示。看门狗在"请求播放"后计时，窗口内没拿到证据就报一个
/// **明确的"疑似无可用解码器"**错误，让既有 `MediaFallbackPanel` 出现。
///
/// 4–6s 是 "慢速网络起播也算够、用户又不至于等太久" 的折中，取 5s；测试用构造参数
/// [NativeVideoPlayerAdapter.watchdogTimeout] 注入短值，阈值因此**可注入/可覆盖**。
///
/// 判据（R4 之后的最终版，见 [NativeVideoPlayerAdapter._onWatchdogTimeout]）：
/// "有画面"的证据只有**首帧回调**与**有效视频尺寸**两条（都是原生
/// `onRenderedFirstFrame` / `onVideoSizeChanged` 给的，真机已证明会到 Dart）；
/// "位置在窗口内推进"**不算**有画面（真机 Theora 无解码器时时钟照样走到
/// `00:04/00:05`），它只在"文件还没放完"时用来**抑制误报**。
const Duration kMediaWatchdogTimeout = Duration(seconds: 5);

/// **自动续播提示**在判死前多给的一次「确认窗口」（R7-5 冷缓存误报修正）。
///
/// 背景（R7 真机）：可解码→可解码的自动续播 3/3 干净，但**刚上传后的冷缓存**跑次
/// 里，下一条的首帧比 5s 窗口晚到 —— 看门狗先弹了非阻塞提示，随后画面才出来
/// （截图同帧可见"已出画 + 提示条"）。这是**误报**：判据在窗口到点那一刻为真，
/// 但下一秒就被证伪。
///
/// 策略：自动续播的**非阻塞提示**（不是致命面板）判死后**再确认一轮**，只有
/// 确认窗口到点仍**零画面证据**才提示。理由：
///   * 严格**不放宽**"有画面"的判据（仍只认首帧回调 / 有效视频尺寸），所以
///     "真无解码器"（Theora：时钟走完仍无任何帧证据）在第二个窗口必然仍成立
///     → **R7-11 不回归**（只是提示晚一个窗口，从 ~5s 变 ~8s）；
///   * 冷缓存/慢首帧恰好能在这一轮里出画（`_hasVideoOutput` → 撤销），
///     消除"已出画却弹提示"的竞态；
///   * 提示前仍先 `if (_hasVideoOutput) return`（"提示前再确认一次"）。
///
/// 用户**主动**换集/初始条目的致命面板**不享受**这次宽限（R5-8 / R7-5-③ 语义不变）。
const Duration kMediaContinuationConfirmGrace = Duration(seconds: 3);

/// **用户点选的条目**在"时钟在推、但一个画面都没有"时，最多忍几个看门狗窗口
/// 才判死（`DA303`）。
///
/// 为什么需要它（r675 真机/iOS 模拟器实测）：`.mkv`（`Citizen Kane (1941).mkv`）
/// 与 `.AVI`（`60招基础街球S01E01.AVI`）在 iOS 上走 AVFoundation —— **音轨能解、
/// 视频轨解不了**：`AVPlayer` 照常 `readyToPlay`、位置一路推进（有声音），
/// 但永远没有 `onRenderedFirstFrame` / 有效视频尺寸。
///
/// 旧判据在"位置在推进且没播到结尾"时**无限**"再看一轮"（那条豁免是给 Android
/// 某些 ROM 不回调首帧用的）⇒ 用户点开一个 10 分钟的 mkv，得到的是**全黑 + 声音，
/// 没有任何提示、也没有「用其他应用打开」**（三张截图一模一样，停在上一支视频的残帧）。
///
/// 阈值分两档（都只对"用户点选的条目"生效，自动续播仍走非阻塞提示，R7-5 不变）：
///   * **位置在推进**（音频在放、画面没有）⇒ 3 个窗口（默认 15s）判死；
///   * **一直 buffering、从没进 READY**（AVPlayer 解不开容器时就是这样）⇒
///     2 倍窗口（默认 30s，慢网络起播的宽容度）后判死。
/// 判死都交给**既有** `MediaFallbackPanel`（`codecUnsupported` 文案 +
/// 用其他应用打开 / 下载），不新增枚举值/文案。
const int kNoPictureFatalWindows = 3;

/// 看门狗上报的错误串。
///
/// 必须包含 `decod`，这样既有的 `classifyPlayerError`（`media_player.dart`）会把它
/// 归到 `MediaUnavailableReason.codecUnsupported` → 复用既有 `mediaErrCodecUnsupported`
/// 文案与既有 `MediaFallbackPanel`（**零新增 ARB key / 枚举值**）。
///
/// ⚠️ 刻意**不放任何数字**：`classifyPlayerError` 里 `119` / `401` / `403` 这些子串
/// 会把"回退原因"误判成会话失效 —— 而 position/duration 恰好会产出这种数字
/// （例如 `position=119000`）。诊断细节留 `logcat`，错误串保持无数字。
const String kNoDecoderWatchdogError =
    'no-decoder: video produced no first frame within the watchdog window';

/// 看门狗窗口内"位置有没有推进"的判定阈值。
///
/// 原生每 250ms 发一次 state（`MediaPlayerBridge.TICK_MS`），取 300ms 让
/// 两个 tick 之间的正常抖动不算"没动"，而真正停滞的播放器一定小于它。
const Duration kMediaPositionAdvanceEpsilon = Duration(milliseconds: 300);

/// "文件已经放完"的容差：位置落在 `时长 - kMediaEndSlack` 之后即算播完。
///
/// 为什么需要它（真机 R4 证据）：无解码器的 Theora `.mkv` 里 ExoPlayer **照常推进
/// 时钟**（截图 `theora.mkv` 停在 `00:04/00:05`、按钮是"暂停"），所以"位置在走"
/// 本身**不能**证明有画面；但"整段都走完了却一帧尺寸/首帧都没有"可以证明
/// —— 那正是"没有可用解码器"。
///
/// 取 2s 而不是几百 ms：真机上"请求播放"到"时钟开始走"之间有取流/起播延迟
/// （R4 截图：`play()` 后 ~5s 才走到 `00:04/00:05`），容差太小会让 Theora 这类
/// 5s 素材在第一轮窗口里被当成"还没放完"而漏报。
const Duration kMediaEndSlack = Duration(seconds: 2);

/// `--dart-define=SYNHUB_PLAYER_TRACE=true` 时把播放器事件/看门狗的判定打出来。
///
/// ★ r676（`DA306`）：`flutter test integration_test/...` 里 `debugPrint` 会进宿主日志，
/// 这是唯一能在模拟器上看见"这一拍事件被收下还是被丢掉"的手段。
const bool kPlayerEventTrace =
    bool.fromEnvironment('SYNHUB_PLAYER_TRACE');

/// ★ r676（`DA306`）：**可选**能力 —— 桥能说出"当前播放器是第几代"。
///
/// 单例桥（iOS/macOS 的 `MediaPlayerBridge.swift`、Android 的 Kotlin 桥）里，
/// "订阅那一刻的快照"属于**上一条视频**；而 Dart 侧"`create()` 返回前的事件全丢"
/// 只能挡住**先到**的那一批，挡不住"晚到"的同一批（投递顺序不保证）。
/// 有了代数，判据变成**事件自己的身份**：`generation != 我这一代` 就丢。
///
/// 单独开一个接口而不是往 [PlayerBridge] 加方法：既有假桥（离线用例、
/// 其它平台的实现）**一个都不用改**，不支持就自动退化成"没有代际过滤"。
abstract class GenerationAwarePlayerBridge {
  /// 本播放器实例的代数（原生 `create()` 每调一次 +1）
  Future<int?> generation();
}

/// 原生通道的薄封装（**便于离线单测**，见文件头注释）。
abstract class PlayerBridge {
  /// 建一个纹理 + 播放器实例，回 Flutter 侧要用的 texture id
  Future<int> create();

  /// 载入播放列表（[urls] 里每一条都是**带鉴权的完整 URL**），从 [index] 开始。
  /// 鉴权全在查询串（`_sid` + `SynoToken`）→ 不需要自定义头。
  Future<void> load({
    required List<String> urls,
    required int index,
    required bool autoplay,
    required double volume,
    required bool muted,
    required double speed,
    required String aspect,
  });

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(int positionMs);

  Future<void> setSpeed(double speed);

  Future<void> setVolume(double volume);

  Future<void> setMuted(bool muted);

  Future<void> playNext();

  Future<void> playPrevious();

  /// `kind` = `audio` / `subtitle`；[id] 为 null = 该类型全部关闭
  Future<void> selectTrack({required String kind, String? id});

  Future<void> setAspectMode(String code);

  Future<void> dispose();

  /// 原生事件（`Map` 形状见 `MediaPlayerBridge.kt`）
  Stream<Map<Object?, Object?>> get events;
}

/// 真实实现：MethodChannel + EventChannel
class MethodChannelPlayerBridge
    implements PlayerBridge, GenerationAwarePlayerBridge {
  MethodChannelPlayerBridge({MethodChannel? method, EventChannel? events})
    : _method = method ?? const MethodChannel(kMediaPlayerChannel),
      _events = events ?? const EventChannel(kMediaPlayerEventChannel);

  final MethodChannel _method;
  final EventChannel _events;

  /// 第 79 轮：所有出站调用统一从这里过**能力门**。
  ///
  /// `synhub/player` 是 Kotlin 一份实现；`localMediaPlayback` 在 Android/macOS
  /// 上 `available`、Linux/Windows 上 `unavailable` ⇒ 宿主上不回
  /// `MissingPluginException`，而是明确降级成 `null`。
  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) {
    if (!capabilityGateAllows(AppCapability.localMediaPlayback)) {
      return Future<T?>.value(null);
    }
    return args == null
        ? _method.invokeMethod<T>(method)
        : _method.invokeMethod<T>(method, args);
  }

  @override
  Future<int?> generation() => _invoke<int>('generation');

  @override
  Future<int> create() async {
    final id = await _invoke<int>('create');
    if (id == null || id < 0) {
      throw StateError('原生播放器没有给出 texture id');
    }
    return id;
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
  }) => _invoke<void>('load', <String, Object?>{
    'urls': urls,
    'index': index,
    'autoplay': autoplay,
    'volume': volume,
    'muted': muted,
    'speed': speed,
    'aspect': aspect,
  });

  @override
  Future<void> play() => _invoke<void>('play');

  @override
  Future<void> pause() => _invoke<void>('pause');

  @override
  Future<void> seekTo(int positionMs) => _invoke<void>(
    'seekTo',
    <String, Object?>{'positionMs': positionMs},
  );

  @override
  Future<void> setSpeed(double speed) =>
      _invoke<void>('setSpeed', <String, Object?>{'speed': speed});

  @override
  Future<void> setVolume(double volume) => _invoke<void>(
    'setVolume',
    <String, Object?>{'volume': volume},
  );

  @override
  Future<void> setMuted(bool muted) =>
      _invoke<void>('setMuted', <String, Object?>{'muted': muted});

  @override
  Future<void> playNext() => _invoke<void>('next');

  @override
  Future<void> playPrevious() => _invoke<void>('previous');

  @override
  Future<void> selectTrack({required String kind, String? id}) =>
      _invoke<void>('selectTrack', <String, Object?>{
        'kind': kind,
        'id': id,
      });

  @override
  Future<void> setAspectMode(String code) => _invoke<void>(
    'setAspectMode',
    <String, Object?>{'aspect': code},
  );

  @override
  Future<void> dispose() => _invoke<void>('dispose');

  @override
  Stream<Map<Object?, Object?>> get events async* {
    await for (final event in _events.receiveBroadcastStream()) {
      if (event is Map) {
        yield Map<Object?, Object?>.from(event);
      }
    }
  }
}

/// 自研原生播放器适配器（Android）
class NativeVideoPlayerAdapter
    implements
        MediaPlayerAdapter,
        MediaPlayerFullControls,
        MediaPlayerContinuationNotice {
  NativeVideoPlayerAdapter({
    PlayerBridge? bridge,
    this.watchdogTimeout = kMediaWatchdogTimeout,
    this.continuationConfirmGrace = kMediaContinuationConfirmGrace,
  }) : _bridge = bridge ?? MethodChannelPlayerBridge();

  final PlayerBridge _bridge;

  /// 「起播无进展」看门狗窗口（测试注入短值 → 确定性离线断言）
  final Duration watchdogTimeout;

  /// 自动续播提示判死前的**确认窗口**（见 [kMediaContinuationConfirmGrace]）
  final Duration continuationConfirmGrace;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<Map<Object?, Object?>>? _sub;
  Timer? _watchdog;

  List<String> _urls = const [];
  int _index = 0;
  int _count = 0;

  /// 当前这条是不是**视频**来源（音频-only 不装看门狗：本来就没有"首帧"）
  bool _expectsVideo = false;

  /// 用户请求过播放且**还没 pause**（看门狗不能用 `_playing`：真机上"没有可渲染
  /// 轨道"时 Media3 的 `isPlaying` 可能一直是 false，那样看门狗永远不会触发）。
  bool _playRequested = false;

  /// 播放中曾出现过 `buffering == false`（用来把"慢速网络起播"与"没解码器"分开：
  /// 前者从头到尾都在缓冲，后者至少进过一次 READY）。不看 `_playing`：真机
  /// "没有可渲染轨道"时 Media3 的 `isPlaying` 可能一直是 false。
  bool _sawNonBuffering = false;

  /// 视频渲染器真的出过第一帧（原生 `onRenderedFirstFrame` → `firstFrame`）
  bool _firstFrameRendered = false;

  /// ★ r437 `DA91`：画面证据的**归属下标**（原生 `firstFrameIndex` / `sizeIndex`）。
  ///
  /// 证据是**条目级**的事实，不是全局布尔：旧条目晚到的一拍不许当成新条目的证据
  /// （否则新条目真没解码器也不提示 ⇒ 黑屏漏报）。`< 0` = 旧桥/旧事件流没带下标，
  /// 按"当前条目"兼容处理。
  int _firstFrameIndex = -1;
  int _sizeIndex = -1;

  /// ★ r437 `DA91`：原生状态事件序号（`seq`）。
  ///
  /// 原生 `send()` 在非主线程走 `handler.post` ⇒ 事件可能**乱序到达**；
  /// 只认"更新的那一拍"，否则旧条目的事件会把当前下标改回去、把看门狗的证据顶掉。
  int _lastSeq = -1;

  /// ★ r438 `DA92`：原生 tracks 明说"**本条没有视频轨**"（`videoCount = 0`）时，
  /// 记下这条的**条目下标**。这是"永远不会出画面"的**确定事实**，与"还没等到首帧"
  /// 不是一回事 ⇒ 看门狗不许拿"时钟在推"当借口再等一轮（否则只有音轨的条目要
  /// 播到结尾才提示：用户一直看着上一条的残帧、以为播错了东西）。
  /// `null` = 不知道（旧桥不发 / 本条有视频轨）。
  int? _noVideoTrackIndex;

  /// 原生 `Player.STATE_ENDED`：这一条**完整播完**了（哪怕一帧画面都没有）
  bool _ended = false;

  /// 每条来源的类型（自动续播到不同的类型时要更新 [_expectsVideo]；
  /// 音频-only 不装看门狗，见下）
  List<MediaKind> _kinds = const [];

  /// 当前这一条是**自动续播**进来的（用户没点选）：看门狗到点时给**非阻塞**
  /// 提示而不是致命 `error`（R5 的真实漏报路径，见 [MediaPlayerContinuationNotice]）。
  bool _continuation = false;

  /// 自动续播的条目已经确认"窗口内零画面证据"（界面据此显示顶栏一行提示）
  bool _noPictureNotice = false;

  /// `DA303`：用户点选条目"时钟在推但零画面"已经连续几个窗口了（见
  /// [kNoPictureFatalWindows]）。`_armWatchdog(resetProgress: true)` 归零。
  int _noPictureWindows = 0;

  /// 自动续播提示已经进入**确认窗口**（第一次窗口到点后，再多给一轮；
  /// 见 [kMediaContinuationConfirmGrace]）。致命面板不用这个。
  bool _continuationConfirming = false;

  /// 用户刚点了"上一个/下一个"：下一个 index 变化算**用户主动**换集（保留致命
  /// `error` 语义），不是自动续播。
  bool _userSwitching = false;

  /// "播放器确实在推进"的基线位置（毫秒）：**只在用户动作**（play / 拖动 /
  /// 上一个 / 下一个）装表时重置，看门狗自己因为缓冲/推进而重开窗口时**不动它**。
  ///
  /// 为什么要"不重置"：位置推进的判定必须跨窗口累计。若每轮都拿当前 tick 当基线，
  /// 一个"只推进了一次就停住"的坏文件会在第二轮被当成"没推进"而误报。
  Duration? _progressBaseline;

  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _ready = false;
  bool _buffering = false;
  double _speed = 1;
  double _volume = 1;
  bool _muted = false;

  /// 上一次**能听见**的音量（r649 / `DA249`）：静音键在「音量为 0」时不许是
  /// 死键 —— 解除静音要能真把声音叫回来，所以必须记住一个可恢复的档位。
  double _lastAudibleVolume = 1.0;
  MediaAspectMode _aspect = MediaAspectMode.fit;
  int _videoWidth = 0;
  int _videoHeight = 0;
  String? _error;
  String? _subtitleText;
  List<MediaTrackInfo> _audioTracks = const [];
  List<MediaTrackInfo> _subtitleTracks = const [];

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  bool get playing => _playing;

  @override
  bool get ready => _ready;

  /// 缓冲中（原生 `Player.STATE_BUFFERING`）—— 界面据此显示转圈，不算"未就绪"
  bool get buffering => _buffering;

  /// 自动续播进入的当前条目"窗口内零画面证据"（界面显示非阻塞顶栏提示）
  @override
  bool get hasNoPictureContinuationNotice => _noPictureNotice;

  @override
  double get speed => _speed;

  @override
  String? get error => _error;

  @override
  double get aspectRatio {
    if (_videoWidth > 0 && _videoHeight > 0) {
      return _videoWidth / _videoHeight;
    }
    return 16 / 9;
  }

  /// 视频像素宽（0 = 还不知道；画面比例选择在界面侧用 [aspectRatio]）
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;

  @override
  Stream<void> get changes => _changes.stream;

  // ------------------------------------------------------------ 载入 / 播放

  /// 只在 `load` / `setPlaylist` 里调一次：原生侧"先建纹理，再载入"。
  Future<void> _ensureSubscribed() async {
    if (_sub != null) return;
    _sub = _bridge.events.listen(
      _onEvent,
      onError: (Object err, StackTrace _) {
        // ⚠️ 这里**必须**留原文：`_error` 是给 `classifyPlayerError`
        // （`media_player.dart`）做**分类**用的诊断通道，不是直接显示的文案；
        // 界面展示的是分类结果 `MediaUnavailableReason` 的本地化说法。
        // 改成用户文案会让"网络失败"被误判成"解码失败"。
        _error = '$err';
        _notify();
      },
    );
    final id = await _bridge.create();
    _textureId = id;
    // ★ r676（`DA306`）：取"我这一代"。判据是**事件自己的身份**，不是到达时间 ——
    //   上一代的快照即使晚到也不会被当成"我这条"的证据（见 [_resetForNewPlayer]）。
    _generation = _bridge is GenerationAwarePlayerBridge
        ? await (_bridge as GenerationAwarePlayerBridge).generation()
        : null;
    _resetForNewPlayer();
    _created = true;
    if (kPlayerEventTrace) {
      debugPrint('[player] SUBSCRIBED texture=$id generation=$_generation');
    }
  }

  /// 新的原生播放器 = **一张白纸**：上一条视频的进度/时长/画面证据一条都不许留。
  ///
  /// ★ r676（`DA306`）：`_applyState` 里"有画面证据就撤看门狗"（`_hasVideoOutput`）
  /// 是正确设计，但它无法分辨证据属于谁 —— 所以"换播放器"这一侧必须**先归零**。
  /// 否则上一条 mp4 的 `videoWidth=1920 / firstFrame=true` 一旦被算到 `.mkv` 头上，
  /// 看门狗就永远不会到点（正是 r675 的黑屏现场）。
  void _resetForNewPlayer() {
    _position = Duration.zero;
    _duration = null;
    _playing = false;
    _ready = false;
    _buffering = false;
    _ended = false;
    _error = null;
    _firstFrameRendered = false;
    _videoWidth = 0;
    _videoHeight = 0;
    _firstFrameIndex = -1;
    _sizeIndex = -1;
    _lastSeq = -1;
    _noVideoTrackIndex = null;
    _noPictureWindows = 0;
    _sawNonBuffering = false;
    _continuation = false;
    _continuationConfirming = false;
    _noPictureNotice = false;
    _progressBaseline = null;
    _subtitleText = null;
    _audioTracks = const [];
    _subtitleTracks = const [];
  }

  int? _textureId;
  bool _created = false;

  /// ★ r676（`DA306`）：**我这一代**播放器的代数（桥不支持时为 null ⇒ 不做代际过滤）。
  ///
  /// 单例桥里"订阅那一刻推来的快照"属于上一条视频，而它可能**晚于** `create()`
  /// 才被处理 —— 只靠 `_created` 时间窗挡不住（r675 iOS `.mkv` 黑屏且永不兜底的根因）。
  int? _generation;

  /// 原生侧 texture id（还没建 → null）
  int? get textureId => _textureId;

  @override
  Future<void> load(MediaSource source) async {
    if (source.uri.isEmpty) {
      throw StateError('empty media url (${source.channel.code})');
    }
    _urls = [source.uri];
    _index = 0;
    _count = 1;
    _kinds = [source.kind];
    _expectsVideo = source.kind == MediaKind.video;
    _continuation = false;
    await _sendLoad(autoplay: false);
  }

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {
    final playable = [
      for (final item in items)
        if (item.uri.isNotEmpty) item,
    ];
    if (playable.isEmpty) {
      throw StateError('empty playlist');
    }
    _urls = [for (final item in playable) item.uri];
    _index = index.clamp(0, playable.length - 1);
    _count = playable.length;
    _kinds = [for (final item in playable) item.kind];
    _expectsVideo = playable[_index].kind == MediaKind.video;
    _continuation = false;
    await _sendLoad(autoplay: false);
  }

  Future<void> _sendLoad({required bool autoplay}) async {
    await _ensureSubscribed();
    _error = null;
    _resetVideoOutput();
    _cancelWatchdog();
    await _bridge.load(
      urls: _urls,
      index: _index,
      autoplay: autoplay,
      volume: _volume,
      muted: _muted,
      speed: _speed,
      aspect: _aspect.code,
    );
    // 原生 `load` 返回时播放器已经准备好接收 play/seek（`prepare()` 已调），
    // 画面尺寸/时长随后由事件补上。
    _ready = true;
    _notify();
  }

  @override
  Future<void> play() async {
    // ★ 第 295 轮：与 `video_player` 适配器同一毛病 —— 播放**结束后**再 `play()`
    // 在 ExoPlayer 上是 no-op ⇒ 按钮点了没反应。结束态先回到起点（真机实测：
    // `home/Music/CD1 - 01 - Track01.mp3` 播到 01:34/07:16 后锁死）。
    if (_ended) {
      _ended = false;
      await _bridge.seekTo(0);
    }
    await _bridge.play();
    _playing = true;
    _playRequested = true;
    _armWatchdog();
    _notify();
  }

  @override
  Future<void> pause() async {
    await _bridge.pause();
    _playing = false;
    // 暂停 = 用户主动停：立刻解除看门狗（暂停状态不许被判成"没解码器"）
    _playRequested = false;
    _cancelWatchdog();
    _notify();
  }

  @override
  Future<void> seekTo(Duration position) async {
    final target = _clampPosition(position);
    _position = target;
    await _bridge.seekTo(target.inMilliseconds);
    // 用户主动拖动 = 起播窗口重新开始（拖动过程中的"暂时没画面"不许误报）
    if (_playRequested) _armWatchdog();
    _notify();
  }

  /// 位置夹取：**不越界 0 / 总时长**（总时长未知时只夹下界）
  Duration _clampPosition(Duration value) {
    var target = value;
    if (target < Duration.zero) target = Duration.zero;
    final total = _duration;
    if (total != null && total > Duration.zero && target > total) {
      target = total;
    }
    return target;
  }

  @override
  Future<void> skipBy(Duration offset) => seekTo(_position + offset);

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _bridge.setSpeed(speed);
    _notify();
  }

  // ------------------------------------------------------------ 音量

  @override
  double get volume => _volume;

  @override
  bool get muted => _muted;

  @override
  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped > 0.001) _lastAudibleVolume = clamped;
    _volume = clamped;
    // 用户主动调音量 → 顺手解除静音（否则"拖了滑杆还是没声音"）
    if (clamped > 0 && _muted) {
      _muted = false;
      await _bridge.setMuted(false);
    }
    await _bridge.setVolume(clamped);
    _notify();
  }

  @override
  Future<void> setMuted(bool value) async {
    // 解除静音时如果音量本身就是 0，光把 `muted` 置 false 仍然一点声音都没有
    // （真机现象：静音键按下去像"没反应"）⇒ 恢复到上一次能听见的音量。
    if (!value && _volume <= 0.001) {
      final restore = _lastAudibleVolume.clamp(0.0, 1.0);
      _volume = restore > 0 ? restore : 1.0;
      _muted = false;
      await _bridge.setMuted(false);
      await _bridge.setVolume(_volume);
      _notify();
      return;
    }
    _muted = value;
    await _bridge.setMuted(value);
    _notify();
  }

  // ------------------------------------------------------------ 播放列表

  @override
  int get playlistIndex => _index;

  @override
  int get playlistLength => _count;

  @override
  bool get hasPrevious => _count > 1 && _index > 0;

  @override
  bool get hasNext => _count > 1 && _index < _count - 1;

  @override
  Future<void> playNext() async {
    if (!hasNext) return;
    // 先立旗：随后的 index 变化算"用户主动换集"，不是自动续播（R4 的 P0 区分）
    _userSwitching = true;
    await _bridge.playNext();
    _restartAfterUserSwitch();
  }

  @override
  Future<void> playPrevious() async {
    if (!hasPrevious) return;
    _userSwitching = true;
    await _bridge.playPrevious();
    _restartAfterUserSwitch();
  }

  /// **用户主动**换集（上一个/下一个）：丢掉上一条的画面证据并重开起播窗口。
  ///
  /// 与"播放列表自动播下一条"的区别是本案的关键（R4 的 P0 回归 + R5 的 P0 漏报）：
  ///   * 用户主动换集 → 保留既有取舍：窗口内零画面证据报**致命** `error`
  ///     （「编码不支持」面板，R5-8 已通过）；
  ///   * 自动续播 → 同样装表，但结果降级成**非阻塞**提示
  ///     （[MediaPlayerContinuationNotice]；R5 真实漏报路径）；
  ///   * 两边的**证据判据保持一致**：长片"位置在推进 → 抑制上报"照旧。
  /// 真机证据见 docs/native-media-playback-research.md §10.3。
  void _restartAfterUserSwitch() {
    _continuation = false;
    _resetVideoOutput();
    if (_playRequested) _armWatchdog();
    _notify();
  }

  // ------------------------------------------------------------ 轨道

  @override
  List<MediaTrackInfo> get audioTracks => _audioTracks;

  @override
  List<MediaTrackInfo> get subtitleTracks => _subtitleTracks;

  @override
  String? get selectedAudioTrackId => _selectedId(_audioTracks);

  @override
  String? get selectedSubtitleTrackId => _selectedId(_subtitleTracks);

  static String? _selectedId(List<MediaTrackInfo> tracks) {
    for (final track in tracks) {
      if (track.isSelected) return track.id;
    }
    return null;
  }

  @override
  Future<void> selectAudioTrack(String? id) async {
    await _bridge.selectTrack(kind: MediaTrackKind.audio.code, id: id);
    _audioTracks = _markSelected(_audioTracks, id);
    _notify();
  }

  @override
  Future<void> selectSubtitleTrack(String? id) async {
    await _bridge.selectTrack(kind: MediaTrackKind.subtitle.code, id: id);
    _subtitleTracks = _markSelected(_subtitleTracks, id);
    if (id == null) _subtitleText = null;
    _notify();
  }

  static List<MediaTrackInfo> _markSelected(
    List<MediaTrackInfo> tracks,
    String? id,
  ) => [for (final t in tracks) t.copyWith(isSelected: t.id == id)];

  @override
  String? get embeddedSubtitleText => _subtitleText;

  // ------------------------------------------------------------ 画面比例

  @override
  MediaAspectMode get aspectMode => _aspect;

  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {
    _aspect = mode;
    await _bridge.setAspectMode(mode.code);
    _notify();
  }

  // ---------------------------------------------------- 起播看门狗（Bug B）

  /// 已拿到"画面确实能出"的证据：出过首帧，或拿到了有效的视频尺寸。
  ///
  /// ★ r437 `DA91`：两条证据都必须**属于当前条目**（下标相同）才算 —— 证据带的是
  /// 哪一条的号码，就只对哪一条生效（旧条目残留的尺寸/首帧不许解除新条目的看门狗）。
  bool get _hasVideoOutput {
    final firstFrame = _firstFrameRendered &&
        (_firstFrameIndex < 0 || _firstFrameIndex == _index);
    final size = _videoWidth > 0 &&
        _videoHeight > 0 &&
        (_sizeIndex < 0 || _sizeIndex == _index);
    return firstFrame || size;
  }

  /// 换文件/换集时清掉上一条的画面状态（否则上一集的尺寸会被当成"本集已出画面"）
  void _resetVideoOutput() {
    // ★ r438 `DA92`：轨道判据也是**条目级**的，换条目就要一起清。
    _noVideoTrackIndex = null;
    _videoWidth = 0;
    _videoHeight = 0;
    _firstFrameRendered = false;
    _firstFrameIndex = -1;
    _sizeIndex = -1;
    _sawNonBuffering = false;
    _ended = false;
    // 换了条目，"上一条零画面证据"的提示也必须跟着清（要重新取证）
    _noPictureNotice = false;
    _continuationConfirming = false;
  }

  /// 重新开始一个起播窗口（`play` / 用户拖动 `seekTo` / 用户换集都调）。
  ///
  /// 只对**视频**来源生效，且必须在"已请求播放"状态下 —— 音频-only / 暂停态
  /// 从头到尾都不装。
  ///
  /// [resetProgress] = false 用于看门狗**自己**重开窗口（缓冲 / 位置还在推进）：
  /// 那两种情况不改变"这条从哪个位置开始播"的事实。
  ///
  /// [timeout] = 这一次窗口的长度（默认 [watchdogTimeout]；自动续播的
  /// **确认窗口**传 [continuationConfirmGrace]，见 [kMediaContinuationConfirmGrace]）。
  void _armWatchdog({bool resetProgress = true, Duration? timeout}) {
    _watchdog?.cancel();
    _watchdog = null;
    _sawNonBuffering = false;
    if (resetProgress) {
      _progressBaseline = _position;
      _noPictureWindows = 0;
    }
    if (!_expectsVideo || !_playRequested) return;
    _watchdog = Timer(timeout ?? watchdogTimeout, _onWatchdogTimeout);
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// 播放位置有没有真的往前推（超过 [kMediaPositionAdvanceEpsilon]）。
  ///
  /// ⚠️ 它**不是**"有画面"的证据（真机 Theora 无解码器时时钟照样走到 `00:04/00:05`），
  /// 只是"播放器在动"的证据 —— 用来在"文件还没播到结尾"时**宁可漏报也不误伤**。
  bool get _positionAdvanced {
    final start = _progressBaseline;
    if (start == null) return false;
    return _position > start + kMediaPositionAdvanceEpsilon;
  }

  /// 当前这条是不是已经播到（或非常接近）结尾。
  ///
  /// 判据取 `ended` 状态或"位置落在 `时长 - 容差` 之后"：看门狗到点与最后几个
  /// tick 是并发竞态，单看某一个 state 载荷会误判。
  bool get _reachedEnd {
    if (_ended) return true;
    final total = _duration;
    if (total == null || total <= Duration.zero) return false;
    return _position >= total - kMediaEndSlack;
  }

  /// 窗口到点：拿不到"能出画面"的证据就上报"疑似无可用解码器"。
  ///
  /// 只有以下**全部**成立才上报：
  ///   * 视频来源且用户请求了播放；
  ///   * 没有真实错误（`onPlayerError` 已经给了原因，别覆盖它）；
  ///   * 没出首帧、也没有有效视频尺寸（**这两条是唯一可靠的"有画面"证据**，
  ///     真机 R4 已由 `clip-h264.mp4` 渲染成 4:3（160×120）证明尺寸信号真的到了
  ///     Dart 且真的解除了看门狗）；
  ///   * 不是"位置还在推进、而且文件还没播到结尾"（那种情况可能是某 ROM
  ///     不回调 `onRenderedFirstFrame`/`onVideoSizeChanged`，宁可再看一轮）；
  ///   * 不是"从头到尾一直 buffering"（慢速网络起播）。
  ///
  /// 换句话说：**"在走时钟但一帧画面证据都没有，并且已经走到结尾"才判死**。
  /// 这条既能让真机 Theora（`00:04/00:05`，时钟走完仍无画面）照常出面板，
  /// 又不会把"能出画面的文件"误伤成编码不支持。
  ///
  /// 上报**形态**取决于条目是怎么进来的（证据判据完全相同）：
  ///   * 用户点选 / 初始条目 → 致命 `error`（既有「编码不支持」回退面板）；
  ///   * 自动续播（[_continuation]）→ **非阻塞**提示
  ///     （[MediaPlayerContinuationNotice]；R5 真实漏报路径）。
  void _onWatchdogTimeout() {
    _watchdog = null;
    if (kPlayerEventTrace) {
      debugPrint('[player] WATCHDOG expectsVideo=$_expectsVideo '
          'playRequested=$_playRequested error=$_error output=$_hasVideoOutput '
          'buffering=$_buffering sawNonBuffering=$_sawNonBuffering '
          'pos=$_position windows=$_noPictureWindows '
          'continuation=$_continuation');
    }
    if (!_expectsVideo || !_playRequested) return;
    if (_error != null) return;
    if (_hasVideoOutput) return;
    // ★ r438 `DA92`：本条**没有视频轨**是确定事实 ⇒ 下面两个"再等一轮"的借口都不成立
    // （那条路是留给"可能还有画面"的条目的：慢起播 / 某 ROM 不回调首帧、尺寸）。
    final noVideoTrack =
        _noVideoTrackIndex != null && _noVideoTrackIndex == _index;
    if (!noVideoTrack) {
      if (_buffering && !_sawNonBuffering) {
        // 慢速网络：这一轮不算，再看一轮（真正没解码器的情形至少会进一次 READY，
        // 那时 `_sawNonBuffering` 为真，下一次窗口就会上报）。
        //
        // ★ r675（`DA303`）：**这条豁免也必须是有界的** —— iOS 上 `.mkv`/`.AVI`
        //   走 AVPlayer 时是"一直 buffering、永远不出 READY、也永远不报错"，
        //   无限再看一轮 ⇒ 用户得到一屏**残帧 + 什么都没有**（三张截图一模一样）。
        //   慢网络起播一般 1–2 个窗口内出 READY，给 2 倍窗口（默认 10s）仍无进展
        //   就判死，交给既有回退面板（原因 + 用其他应用打开 / 下载）。
        if (!_continuation) {
          _noPictureWindows++;
          if (_noPictureWindows >= kNoPictureFatalWindows * 2) {
            _fatalNoDecoder('buffering-never-ready');
            return;
          }
        }
        _armWatchdog(resetProgress: false);
        return;
      }
      if (_positionAdvanced && !_reachedEnd) {
        // 时钟在推、文件还没到结尾：无法区分"某 ROM 不回调首帧/尺寸"与"真没解码器"
        // → 不判死，再看一轮（位置推进的基线跨窗口保留；等它走到结尾仍无画面证据
        // 才上报，真机 Theora 就是这种形态）。
        //
        // ★ r675（`DA303`）：**但"再看一轮"必须有界** —— iOS 上 mkv/avi 是
        //   "音频在放、画面永远没有"，位置会一路推进到 10 分钟开外，无限豁免
        //   等于让用户对着黑屏+声音等到片尾。用户点选的条目超过
        //   [kNoPictureFatalWindows] 个窗口就判死（走既有回退面板）；
        //   自动续播仍走下面的非阻塞提示（R7-5 不变）。
        if (!_continuation) {
          _noPictureWindows++;
          if (_noPictureWindows >= kNoPictureFatalWindows) {
            _fatalNoDecoder('position-advancing-no-picture');
            return;
          }
        }
        _armWatchdog(resetProgress: false);
        return;
      }
    }
    if (_continuation) {
      // 自动续播（用户没点选）+ 零画面证据 → **非阻塞**提示（不设 error、
      // 不弹回退面板）：R5 的"片尾自动续播到无解码器条目 → 全黑无提示"。
      // 判据与致命面板**完全相同**，所以长片"位置在推进 → 抑制上报"的取舍保持。
      //
      // R7 冷缓存修正：先给一轮**确认窗口**（见 [kMediaContinuationConfirmGrace]）。
      // 冷缓存的下一条首帧常比 5s 窗口晚到；不确认就会"已出画却弹提示"。
      // 真无解码器在确认窗口到点后仍零画面证据 → 照常提示（R7-11 不回归）。
      if (!_continuationConfirming) {
        _continuationConfirming = true;
        _armWatchdog(resetProgress: false, timeout: continuationConfirmGrace);
        return;
      }
      if (!_noPictureNotice) {
        _noPictureNotice = true;
        _notify();
      }
      return;
    }
    _fatalNoDecoder('no-picture-no-progress');
  }

  /// 判死：上报"疑似无可用解码器"（走既有回退面板），并留一条可核对的日志。
  void _fatalNoDecoder(String why) {
    _error = kNoDecoderWatchdogError;
    if (kPlayerEventTrace) {
      debugPrint('[player] FATAL no-decoder ($why) index=$_index '
          'pos=$_position dur=$_duration windows=$_noPictureWindows');
    }
    _notify();
  }

  // ------------------------------------------------------------ 事件

  void _onEvent(Map<Object?, Object?> event) {
    if (!_created) {
      if (kPlayerEventTrace) {
        debugPrint('[player] DROP pre-create ${_traceBrief(event)}');
      }
      return;
    }
    // ★ r676（`DA306`）：**代际过滤**。单例桥的一个 sink 服务所有页面，上一代的
    //   状态事件（尤其 `onListen` 那条快照）可能在新页面 `create()` **之后**才到；
    //   它带着上一代才有的 `videoWidth/firstFrame` ⇒ 会把新条目的看门狗判据顶掉。
    final gen = _num(event['generation']);
    if (gen != null && _generation != null && gen != _generation) {
      if (kPlayerEventTrace) {
        debugPrint('[player] DROP stale gen=$gen mine=$_generation '
            '${_traceBrief(event)}');
      }
      return;
    }
    // ★ r675（`DA305`）：**自己还没建播放器时收到的事件全是上一条的**。
    //   iOS/macOS 桥是进程内单例（`MediaPlayerBridge.shared` + 一个 EventChannel），
    //   `create()` 会 `releasePlayer()` 换新播放器 —— 而在 `create()` 之前
    //   `onListen` 就先把**上一个播放器**的状态（`index`/`position`/`duration`）
    //   推过来了。旧代码照单全收：新页面的 `_index` 被改成 0，顶栏显示上一支
    //   视频的名字、进度也按上一支走（r675 真机三张截图一模一样）。
    //   判据很硬：没有自己的播放器 ⇒ 这些事件与"我这条"无关，一条都不许用。
    switch ('${event['kind'] ?? 'state'}') {
      case 'tracks':
        _audioTracks = parseTrackList(event['audio']);
        _subtitleTracks = parseTrackList(event['subtitle']);
        // ★ r438 `DA92`：`videoCount == 0` ⇒ 本条**确定**没有视频轨（正证据）；
        // `> 0` ⇒ 撤销该判据（本条有视频轨，"还没出帧"仍走既有的再看一轮）。
        // 缺字段（旧桥/旧事件流）⇒ 不动，保持既有行为。
        final videoCount = _num(event['videoCount']);
        if (videoCount != null) {
          _noVideoTrackIndex = videoCount <= 0
              ? (_num(event['index']) ?? _index)
              : null;
        }
      case 'cues':
        final text = event['text'];
        _subtitleText = (text is String && text.trim().isNotEmpty)
            ? text.trim()
            : null;
      case 'error':
        _error = '${event['message'] ?? ''}';
      default:
        _applyState(event);
    }
    _notify();
  }

  void _applyState(Map<Object?, Object?> s) {
    if (!_created) return;
    // ★ r437 `DA91`：只认"更新的那一拍"。乱序到达的旧事件会把 `index` 改回去、
    // 把旧条目的尺寸/首帧当成当前条目的证据 ⇒ 两个方向都会错。
    // 没有 `seq` 的旧桥/旧事件流照旧全部处理（兼容，不改变既有行为）。
    if (kPlayerEventTrace) {
      debugPrint('[player] STATE gen=${s['generation']} idx=${s['index']} '
          'pos=${s['positionMs']} dur=${s['durationMs']} ready=${s['ready']} '
          'w=${s['videoWidth']} firstFrame=${s['firstFrame']} '
          'err=${(s['error'] ?? '')}');
    }
    final seq = _num(s['seq']);
    if (seq != null && seq >= 0) {
      if (seq <= _lastSeq) return;
      _lastSeq = seq;
    }
    final ms = _num(s['positionMs']);
    if (ms != null) _position = Duration(milliseconds: ms);
    final total = _num(s['durationMs']);
    _duration = (total == null || total <= 0)
        ? null
        : Duration(milliseconds: total);
    if (s['playing'] is bool) _playing = s['playing'] as bool;
    if (s['ready'] is bool) _ready = (s['ready'] as bool) || _ready;
    if (s['buffering'] is bool) _buffering = s['buffering'] as bool;
    if (s['ended'] is bool) _ended = s['ended'] as bool;
    final volume = _num(s['volume']);
    if (volume != null) _volume = (volume / 100).clamp(0.0, 1.0).toDouble();
    if (s['muted'] is bool) _muted = s['muted'] as bool;
    final speed = _num(s['speed']);
    if (speed != null && speed > 0) _speed = speed.toDouble();
    final index = _num(s['index']);
    if (index != null && index >= 0 && index != _index) {
      // 换集：上一条的画面状态（尺寸/首帧）必须丢掉，否则会拿旧尺寸当成
      // "本集已经出画面"，看门狗对新集完全失效。
      //
      // ⚠️ 用户主动换集与自动续播的**结果不同**（R4 的 P0 + R5 的 P0）：
      //   * `playNext`/`playPrevious` 已经 `_restartAfterUserSwitch()` 装了
      //     "致命 error"表，这里只更新下标并清画面状态；
      //   * 否则就是 Media3 的**自动续播**（片尾自动播下一条）—— 也要装表取证，
      //     但结果降级成**非阻塞提示**（`_continuation = true`），不弹面板：
      //     下一条可能没有解码器，用户看到的是全黑；报成"上一条编码不支持"
      //     会误伤（R4），而完全静默又是 R5 的漏报。
      final userSwitched = _userSwitching;
      _userSwitching = false;
      _index = index;
      if (index < _kinds.length) {
        _expectsVideo = _kinds[index] == MediaKind.video;
      }
      _resetVideoOutput();
      _continuation = !userSwitched;
      if (_continuation && _playRequested) {
        _armWatchdog();
      }
    }
    final count = _num(s['count']);
    if (count != null && count > 0) _count = count;
    final width = _num(s['videoWidth']);
    final sizeIndex = _num(s['sizeIndex']);
    if (width != null && width > 0) {
      _videoWidth = width;
      _sizeIndex = sizeIndex ?? _index; // 缺下标 = 旧桥 ⇒ 按当前条目兼容
    }
    final height = _num(s['videoHeight']);
    if (height != null && height > 0) {
      _videoHeight = height;
      _sizeIndex = sizeIndex ?? _index;
    }
    // 原生 `onRenderedFirstFrame` → 真的出帧了（格式已知 ≠ 出帧）
    if (s['firstFrame'] is bool && (s['firstFrame'] as bool)) {
      _firstFrameRendered = true;
      _firstFrameIndex = _num(s['firstFrameIndex']) ?? _index; // 同上兼容
    }
    // 只要有任意一条"画面能出"的证据，本轮起播就算成功（自动续播的提示也撤销）
    if (_hasVideoOutput) {
      _cancelWatchdog();
      _noPictureNotice = false;
    }
    // 曾进过非缓冲状态 → 网络不是瓶颈（据此区分慢速起播与没解码器）
    if (_playRequested && !_buffering) _sawNonBuffering = true;
    final aspect = s['aspect'];
    if (aspect is String && aspect.isNotEmpty) {
      _aspect = MediaAspectMode.fromCode(aspect);
    }
    final err = s['error'];
    if (err is String && err.isNotEmpty) _error = err;
  }

  /// 追踪用：把一条事件压缩成一行（只在 `SYNHUB_PLAYER_TRACE` 时调用）
  String _traceBrief(Map<Object?, Object?> e) =>
      'kind=${e['kind'] ?? 'state'} gen=${e['generation']} '
      'idx=${e['index']} pos=${e['positionMs']} w=${e['videoWidth']} '
      'ff=${e['firstFrame']}';

  static int? _num(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return null;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> dispose() async {
    _created = false;
    _textureId = null;
    _playRequested = false;
    // 页面早退时必须停表：留着会让"已销毁的适配器"在窗口到点后改状态
    _cancelWatchdog();
    debugPrint('R647 ad cancel start');
    await _sub?.cancel();
    debugPrint('R647 ad cancel done');
    _sub = null;
    try {
      debugPrint('R647 ad bridge start');
      await _bridge.dispose();
      debugPrint('R647 ad bridge done');
    } catch (_) {
      // 通道已经没了（页面早退 / 引擎重启）：不该因为清理失败把页面卡住
    }
    debugPrint('R647 ad close start');
    await _changes.close();
    debugPrint('R647 ad close done');
  }

  @override
  Widget buildSurface(BuildContext context) {
    final id = _textureId;
    if (!_created || id == null) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    return Texture(textureId: id);
  }
}

/// 平台默认适配器：Android 用自研原生播放器；iOS/macOS 走**同一份**
/// AVPlayer 桥（`macos/Runner/MediaPlayerBridge.swift`，两边同源）；其余平台回退插件。
///
/// 为什么 Apple 两家要用自研桥：
///   * `macos/Runner/MediaPlayerBridge.swift`（AVPlayer + 自定义
///     scheme 的 `AVAssetResourceLoaderDelegate` + `URLSession` 的
///     `serverTrust` 放行）**已经实现并随包**，它是 Apple 平台唯一能播
///     "证书链合法但主机名不匹配"那条真 NAS 流的实现；
///   * 第 296 轮曾默认关（没在真 NAS 上验证播放前不启用）；**r87 已在真 NAS
///     上验证通过** ⇒ macOS 默认翻 true（`docs/platform-macos.md` §3.7.7）；
///     第 92 轮把同一份源码接进 iOS target（registrar 差异用 `#if os(macOS)`
///     收口）⇒ iOS 也默认走它（`MediaTlsPolicy.iosNativePlayerEnabled`，
///     或 `--dart-define=SYNHUB_IOS_NATIVE_PLAYER=false` 退回插件）。
///
/// ⚠️ 这里判 `defaultTargetPlatform`（不是 `dart:io Platform`）：它是
/// Flutter 的"界面平台"，也正是本函数要选的那一列。单测里它的默认值是
/// `android`，所以既有用例的前提**一字不变**（都走 Android 自研桥分支，
/// 且页面测试普遍覆盖 `mediaPlayerAdapterFactoryProvider`）。
MediaPlayerAdapter createDefaultMediaPlayerAdapter() {
  if (kIsWeb) return VideoPlayerAdapter();
  // Android：既有自研桥（默认，行为**不变**；flutter_test 里
  // `defaultTargetPlatform` 也是 android，所以既有用例的前提不被改动）。
  if (defaultTargetPlatform == TargetPlatform.android) {
    // ★ r655：AC3/EAC3/DTS/APE 的软解兜底 —— Media3 判"音轨全都不支持"或
    //   起播被判成"解不了"时，**换 libmpv 重开同一个文件**（位置与播放意图保留）。
    //   为什么在这里包装而不是在页面里：页面只认 [MediaPlayerAdapter]，
    //   换引擎不该让页面知道两套状态机（也保证所有入口同一套行为）。
    return FallbackPlayerAdapter(
      primary: NativeVideoPlayerAdapter(),
      createFallback: MpvPlayerAdapter.new,
    );
  }
  // iOS：与 macOS 共用同一份 Swift 桥（`#if os(macOS)` 只收口 registrar 形态）。
  //
  // ★ r678：**iOS 也包一层 libmpv 兜底**（`DA311`）。动机不是"音轨不支持"
  //   （Android 那条），而是**容器本身**：AVFoundation 认不出 Matroska
  //   （`-11828`）、`.AVI` 能 ready 但零画面 —— r676 只能给兜底面板。
  //   r677 已实测 `media_kit_libs_ios_video` 能在模拟器里编过、链上 `Mpv.framework`
  //   并对 mkv/avi 解出 `w/h`，所以这里与 Android 用**同一套**策略：
  //   主引擎先试（mp4/H.264 那条更省、能力更全），判死成
  //   `codecUnsupported`/`decodeFailed` 再换 libmpv 重开同一个文件。
  //   代价：设备包 +≈20MB（`Mpv.framework` device slice）。
  if (defaultTargetPlatform == TargetPlatform.iOS &&
      MediaTlsPolicy.iosNativePlayerEnabled) {
    debugPrint('[r678engine] iOS factory -> FallbackPlayerAdapter(mpv)');
    return FallbackPlayerAdapter(
      primary: NativeVideoPlayerAdapter(),
      createFallback: MpvPlayerAdapter.new,
    );
  }
  // Linux（r690）：`video_player` 在 Linux 上没有实现（插件列里没有它）⇒ 直接用
  // libmpv。`media_kit_libs_linux` 随包带 Linux 版 libmpv，`MpvPlayerAdapter` 就是
  // 安卓/iOS 那条兜底引擎，**同一套状态机**（不再有第二套 Linux 专用实现）。
  if (defaultTargetPlatform == TargetPlatform.linux) {
    debugPrint('[r690engine] Linux factory -> MpvPlayerAdapter(libmpv)');
    return MpvPlayerAdapter();
  }
  // Windows（r703）：与 Linux **同一型** —— `video_player` 在 Windows 上没有实现
  // （插件列里没有 `video_player_windows`），`media_kit_libs_windows_video` 随包
  // 带 libmpv（CMake 构建期校验 MD5 后解包）⇒ 直接用同一条 libmpv 引擎。
  // 判据不是"猜 Windows 能跑"：guest 真机上量到进度真的在走、视频出真帧
  // （读数见 `docs/windows-page-coverage.md` §4.5）。
  if (defaultTargetPlatform == TargetPlatform.windows) {
    debugPrint('[r703engine] Windows factory -> MpvPlayerAdapter(libmpv)');
    return MpvPlayerAdapter();
  }
  // macOS：r87 起默认走自研 AVPlayer 桥（真 NAS 已验证播放）。
  if (defaultTargetPlatform == TargetPlatform.macOS &&
      MediaTlsPolicy.macosNativePlayerEnabled) {
    return NativeVideoPlayerAdapter();
  }
  return VideoPlayerAdapter();
}
