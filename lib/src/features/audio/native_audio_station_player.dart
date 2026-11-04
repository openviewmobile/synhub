// macOS 上的音频引擎：**自研原生 AVPlayer 桥**（`synhub/player`）而不是
// `just_audio`。
//
// ## 为什么需要它（r87 真机取证）
//
// Audio Station 的直传流 URL 是 `https://nas.example.com:5001/webapi/
// AudioStation/stream.cgi/0.mp3?…`。`just_audio` 在 macOS 上落到 AVFoundation，
// 用的是**平台默认 + 严格主机名**的信任校验；而真 NAS 证书是
// `CN=nas.example.com`（SAN `*.nas.example.com`）⇒ 主机名不匹配，
// 实测错误：
//
// ```
// [audio-station] play-failure song=music_28045 reason=certificateUntrusted
//   error=(-1202) The certificate for this server is invalid.
// ```
//
// `just_audio` 的 darwin 实现**不暴露**任何挂 `AVAssetResourceLoaderDelegate`
// 的口子 ⇒ 本仓已装好的 scoped TLS 政策（`MediaTlsPolicy` →
// `macos/Runner/MediaPlayerTransport.swift` 的 `MediaTrustDelegate`）没法作用到
// 它的取流路径。唯一能接上的取流路径就是自研桥（`AVURLAsset` + 自定义
// scheme + 我们自己的 `URLSession`）。
//
// ## 范围
//
// * 只实现 [AudioStationPlayer] 的**基本队列/进度/模式**与
//   [AudioEngineExtras]（缓冲进度 / 异步错误 / dispose）。
// * **不**实现 `AudioGaplessControls` / `AudioSpectrumSession` —— macOS 上
//   桥不支持无缝预载与 audio session id，界面按既有 `player is …` 能力判断
//   自然隐藏这些控件（不假装支持）。
// * 随机 / 循环在 **Dart 侧**自己算下标：桥每次只载入**一条** URL，播完由
//   桥发 `ended`，这里决定下一条（否则桥的原生自动续播会绕过循环/随机语义）。
//
// ⚠️ 已知边界（如实记载）：`synhub/player` 原生侧是**单实例**（与 Android 一致）
// ⇒ macOS 上音频与视频若同时使用会互相顶掉。桌面端正常使用下两者不会同时播，
// 这里不额外造第二实例（要造得改原生桥，属于另一批）。
import 'dart:async';
import 'dart:math';

import '../media/native_video_player.dart'
    show MethodChannelPlayerBridge, PlayerBridge;
import 'audio_player.dart';

/// 自研桥驱动的音频引擎（macOS）。
/// ★ r689：iOS 上**真频谱**已经接上了（`MTAudioProcessingTap` + vDSP，见
/// `ios/Runner/AudioVisualizerBridge.swift`）⇒ 本引擎**实现
/// [AudioSpectrumSession]**，界面才会去 `attach` 真频谱桥。
///
/// 为什么 `androidAudioSessionId` 在 iOS 上回一个**合成本地代数**（1）：
/// iOS 拿不到 AVPlayer 的 "session id"（那是 Android/ExoPlayer 的概念）；
/// 频谱桥只需要一个**非 0** 的值当"代数"，用来让 Dart 侧的
/// `audioSpectrumLevelsProvider` 判"会话变了要重挂"。
/// 语义记在 `docs/platform-ios.md` §29。
class NativeAudioStationPlayer
    implements AudioStationPlayer, AudioEngineExtras, AudioSpectrumSession {
  NativeAudioStationPlayer({PlayerBridge? bridge})
    : _bridge = bridge ?? MethodChannelPlayerBridge();

  final PlayerBridge _bridge;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  /// r689：频谱会话代数流（`1` = 引擎已建；`null` = 已释放）。
  final StreamController<int?> _sessionIds = StreamController<int?>.broadcast();

  StreamSubscription<Map<Object?, Object?>>? _sub;
  bool _created = false;

  /// 正在处理"这一条播完 → 下一条"，防止连发的 state 事件重入。
  bool _advancing = false;

  List<AudioQueueEntry> _queue = const [];
  int _index = -1;

  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _ended = false;
  bool _shuffle = false;
  AudioRepeatMode _repeat = AudioRepeatMode.off;

  final Random _random = Random();

  // ------------------------------------------------------------ 只读状态

  @override
  bool get playing => _playing;

  @override
  bool get shuffleEnabled => _shuffle;

  @override
  AudioRepeatMode get repeatMode => _repeat;

  @override
  String? get currentUrl {
    if (_index < 0 || _index >= _queue.length) return null;
    return _queue[_index].url;
  }

  @override
  int get currentIndex => _index;

  @override
  int get queueLength => _queue.length;

  @override
  List<AudioQueueEntry> get queue => _queue;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  // ------------------------------------------------------------ AudioEngineExtras

  /// 桥按 250ms 上报总时长/缓冲状态，但不给独立的 bufferedPosition
  /// ⇒ 用当前位置如实上报（不编一个更大的数）。
  @override
  Duration get bufferedPosition => _position;

  @override
  Stream<Object> get errors => _errors.stream;

  // ------------------------------------------------------------ AudioSpectrumSession

  /// iOS/桌面没有 ExoPlayer 那种"音频会话号"；这里给一个**合成本地代数**：
  /// 引擎建好就是 `1`，释放后是 `null`。真频谱桥（`synhub/audio_visualizer`）
  /// 只拿它当"要不要重新 attach"的判据，不拿它去对任何原生对象。
  @override
  int? get androidAudioSessionId => _created ? 1 : null;

  @override
  Stream<int?> get androidAudioSessionIdStream => _sessionIds.stream;

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    try {
      if (_created) await _bridge.dispose();
    } catch (_) {
      // 通道已经没了（页面早退 / 引擎重启）不该把清理卡住
    }
    _created = false;
    if (!_sessionIds.isClosed) {
      _sessionIds.add(null);
      await _sessionIds.close();
    }
    await _changes.close();
    await _positions.close();
    await _durations.close();
    await _errors.close();
  }

  // ------------------------------------------------------------ 播放控制

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
    _index = startIndex.clamp(0, entries.length - 1);
    await _loadCurrent(autoplay: true);
  }

  @override
  Future<void> pause() async {
    await _bridge.pause();
    _playing = false;
    _notify();
  }

  @override
  Future<void> resume() async {
    if (_ended) {
      _ended = false;
      await _bridge.seekTo(0);
    }
    await _bridge.play();
    _playing = true;
    _notify();
  }

  @override
  Future<void> stop() async {
    await _bridge.pause();
    _playing = false;
    _notify();
  }

  @override
  Future<void> next() async {
    final target = _nextIndex(forward: true);
    if (target == null) return;
    _index = target;
    await _loadCurrent(autoplay: true);
  }

  @override
  Future<void> previous() async {
    final target = _nextIndex(forward: false);
    if (target == null) return;
    _index = target;
    await _loadCurrent(autoplay: true);
  }

  @override
  Future<void> seek(Duration position) async {
    _ended = false;
    await _bridge.seekTo(position.inMilliseconds);
    _position = position < Duration.zero ? Duration.zero : position;
    _positions.add(_position);
    _notify();
  }

  @override
  Future<void> setShuffle(bool enabled) async {
    _shuffle = enabled;
    _notify();
  }

  @override
  Future<void> setRepeat(AudioRepeatMode mode) async {
    _repeat = mode;
    _notify();
  }

  // ------------------------------------------------------------ 内部

  Future<void> _ensureSubscribed() async {
    if (_sub != null) return;
    _sub = _bridge.events.listen(
      _onEvent,
      onError: (Object err, StackTrace _) {
        if (!_errors.isClosed) _errors.add(err);
      },
    );
    await _bridge.create();
    _created = true;
    // r689：会话代数发出去（`audioSpectrumLevelsProvider` 据此 attach 真频谱）
    if (!_sessionIds.isClosed) _sessionIds.add(1);
  }

  Future<void> _loadCurrent({required bool autoplay}) async {
    await _ensureSubscribed();
    _ended = false;
    _position = Duration.zero;
    _duration = null;
    await _bridge.load(
      urls: [currentUrl ?? ''],
      index: 0,
      autoplay: autoplay,
      volume: 1.0,
      muted: false,
      speed: 1.0,
      aspect: 'fit',
    );
    _playing = autoplay;
    _notify();
  }

  /// 下一条下标；`null` = 队列到此为止（循环 off）。
  int? _nextIndex({required bool forward}) {
    if (_queue.isEmpty) return null;
    if (_shuffle && _queue.length > 1) {
      var candidate = _index;
      while (candidate == _index) {
        candidate = _random.nextInt(_queue.length);
      }
      return candidate;
    }
    final target = forward ? _index + 1 : _index - 1;
    if (target >= 0 && target < _queue.length) return target;
    if (_repeat == AudioRepeatMode.all) {
      return forward ? 0 : _queue.length - 1;
    }
    // 循环 off：往回是回到第一首（与 just_audio 的 seekToPrevious 语义一致），
    // 往前就是真的到头了。
    return forward ? null : 0;
  }

  void _onEvent(Map<Object?, Object?> event) {
    switch ('${event['kind']}') {
      case 'state':
        _position = Duration(
          milliseconds: _intOf(event['positionMs']) ?? 0,
        );
        final dur = _intOf(event['durationMs']) ?? 0;
        _duration = dur > 0 ? Duration(milliseconds: dur) : null;
        _playing = event['playing'] == true;
        _ended = event['ended'] == true;
        if (!_positions.isClosed) _positions.add(_position);
        if (!_durations.isClosed) _durations.add(_duration);
        _notify();
        final error = '${event['error'] ?? ''}';
        if (error.isNotEmpty && !_errors.isClosed) {
          _errors.add(StateError(error));
        }
        if (_ended) unawaited(_onEnded());
      case 'tracks':
      case 'cues':
        break;
    }
  }

  Future<void> _onEnded() async {
    if (_advancing) return;
    _advancing = true;
    try {
      if (_repeat == AudioRepeatMode.one) {
        await _bridge.seekTo(0);
        await _bridge.play();
        _playing = true;
        _notify();
        return;
      }
      final target = _nextIndex(forward: true);
      if (target == null) {
        _playing = false;
        _notify();
        return;
      }
      _index = target;
      await _loadCurrent(autoplay: true);
    } finally {
      _advancing = false;
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static int? _intOf(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }
}
