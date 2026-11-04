// libmpv（media_kit）兜底引擎：**只在 Media3 拿不动音轨时**载入。
//
// 为什么需要它：vanilla Media3 对 AC3 / EAC3 / DTS / APE **没有**软件解码器，
// 能不能放完全取决于厂商有没有塞私有解码器（HONOR 有 `dtsaudio`，别的机器没有）。
// 用户侧的观感是"画面出来了但没声音，也没有任何解释"。
//
// libmpv 自带完整 ffmpeg（含 ac3/eac3/dts/ape 解码器），所以这条兜底能把
// "能提示但放不了"变成"能放"。
//
// 分工（**故意**这样切）：
//   * 画面/声音/解码：libmpv；
//   * 字幕**渲染**：仍由 Flutter 层（`MediaSubtitleOverlay`）画 —— 所以这里把
//     mpv 自带字幕关掉（`sid=no`），只把当前字幕**文本**经 `embeddedSubtitleText`
//     交出去。这样字号/背景/垂直偏移这几项设置对兜底引擎**同样生效**，不会出现
//     "主引擎调字号有用、兜底引擎没用"的两套行为。
//
// 与 `native_video_player.dart` 的关系：那个是主引擎（Media3，能力最全）；
// 本文件**不**替代它，只在 `fallback_player_adapter.dart` 判定"音轨全都不支持"
// 时被创建。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/net/media_tls_policy.dart';
import 'mpv_property_bridge.dart';

import 'media_player.dart';
import 'media_source.dart';
import 'media_tracks.dart';

/// 把"字幕位置 + 背景条"换算成 **libmpv 属性**（r656 · `DA271`）。
///
/// 为什么用这几项而不是自己画：
///   * `sub-margin-y`：**像素级**垂直边距（`sub-pos` 是百分比，太粗 —— 手机屏
///     3% 就是 70 多像素，四档会糊成一两档）；
///   * `sub-border-style=opaque-box`：给文字**后面**铺一块底（不是整屏黑底）；
///   * `sub-back-color`：`#AARRGGBB`，半透明黑 —— 与自家浮层的
///     `kMediaSubtitleBackgroundAlpha` 同一个观感（不透到看不清画面）；
///   * 关背景时回到 `outline-and-shadow` + 不透明黑描边（mpv 的默认观感）。
///
/// ⚠️ 纯函数、不碰 Player：真机能不能生效要靠像素验，但"换算对不对"必须能离线断言。
Map<String, String> mpvSubtitleProperties({
  required int offsetPx,
  required bool background,
  int windowHeightPx = 0,
}) {
  final y = offsetPx < 0 ? 0 : offsetPx;
  // ★ r656 真机教训（`DA271`）：这台机器上的 libmpv **不认** `sub-margin-y`
  //   （设了不报错、画面纹丝不动），它认的是 `sub-pos` —— 一个"距底部百分比"
  //   （100 = 贴底）。百分比相对**播放窗口**，所以必须知道窗口高度才能把用户
  //   选的像素换算准；不知道窗口高度（还没出画/测试）就退回 100，宁可不抬也
  //   不要乱抬。
  final double pct = windowHeightPx > 0 ? 100 - y * 100 / windowHeightPx : 100;
  final pos = pct >= 100 ? '100' : pct.clamp(0, 100).toStringAsFixed(2);
  return <String, String>{
    'sub-pos': pos,
    // 背景条：半透明黑 + 只包住文字（`background-box` 是四边留白更大的那种）。
    'sub-border-style': background ? 'opaque-box' : 'outline-and-shadow',
    'sub-back-color': background ? '#80000000' : '#FF000000',
  };
}

/// ★ r678（`DA311`）：libmpv 的 `tls-verify` 该取什么 —— **纯函数，可离线断言**。
///
/// 判据只有一个：这台主机的 TLS 政策**已经按会话下发过**（`MediaTlsPolicy.isInstalledFor`
/// —— 与 `certPinned` 媒体闸门、原生桥 `setTlsPolicy` 同一个事实），才放宽；
/// 别的源照旧严格校验。这样兜底引擎与主引擎**共用同一份事实**，不会出现
/// "主引擎能放、兜底引擎握不上手"（§2.0.11 的教训）。
String mpvTlsVerifyValue(String uri) =>
    MediaTlsPolicy.isInstalledFor(uri) ? 'no' : 'yes';

/// ★ r678（`DA311`）：libmpv 的**非致命**警告 —— 不许当成"这个文件播不了"。
///
/// 现场（iOS 模拟器 · `.mkv`）：兜底引擎把画面解出来了（`ready=true`、
/// `aspectRatio=1.778`），但 mpv 同时吐了一条
/// `Could not open/initialize audio device -> no sound.`（模拟器没有音频设备）。
/// 我们原来把 `stream.error` 里**任何**字符串都当致命错误上报 ⇒ 页面判
/// `decode_failed` ⇒ 明明是"能看、没声音"，用户看到的是"播放失败"。
///
/// 判据只放这几类**确认过是环境性**的串（其余一律照旧致命，宁可不放宽）：
///   * `audio device` / `no sound`：没有音频输出（模拟器/无声卡/被独占）；
///   * `cannot init audio`：mpv 的另一种措辞。
bool isMpvNonFatalError(String text) {
  final t = text.toLowerCase();
  if (t.isEmpty) return false;
  if (t.contains('audio device')) return true;
  if (t.contains('no sound')) return true;
  if (t.contains('cannot init audio')) return true;
  return false;
}

/// libmpv 兜底适配器。
///
/// 说明：**不要**在 `main()` 之前构造它 —— `MediaKit.ensureInitialized()` 必须先跑
/// （见 `main.dart`）。
class MpvPlayerAdapter
    implements
        MediaPlayerAdapter,
        MediaPlayerNeedsSurfaceWhileLoading,
        MediaPlayerFullControls,
        MediaPlayerSelfRenderedSubtitles,
        MediaPlayerSubtitleStyling {
  MpvPlayerAdapter({Player? player}) : _player = player ?? Player() {
    _bindStreams();
  }

  /// r690：**纹理迟迟不来就报错**的超时。
  ///
  /// 为什么是 15 s：正常桌面起播的纹理在 <1 s 内到（r678 iOS 实测），
  /// 慢机器也就 2–3 s；留 5 倍余量，既不会把"慢慢来"误判成故障，
  /// 又不至于让用户对着转圈等上一分钟。
  static const Duration kVideoSurfaceTimeout = Duration(seconds: 15);

  Timer? _surfaceWatchdog;
  bool _surfaceWatchdogBound = false;

  final Player _player;

  /// ★ r690：**视频输出改成按需创建**（第一次要画面时才建）。
  ///
  /// 两个原因，都是这轮现场量出来的：
  ///   ① 在 llvmpipe/软件 GL 的 Linux 上，`VideoController` 一构造就把
  ///      `VideoOutputManager.Create` 挂上去，**连 `Player` 的属性调用都会被卡住**
  ///      （`setVolume` 永不返回）—— 明明是"只要声音/只要解码"的场合也被拖死；
  ///   ② 纯音频页面根本不需要视频输出，白建一个 render context 是浪费。
  VideoController? _videoController;

  VideoController _ensureVideoController() => _videoController ??=
      VideoController(_player, configuration: _videoConfiguration());

  /// ★ r690（Linux 站现场）：`hwdec` 必须用 **`auto-safe`**，不能用 media_kit
  /// 的默认 `auto`。
  ///
  /// 现场读数：容器里默认 `auto` 会让 mpv 先试 VAAPI/VDPAU，失败后**直接报
  /// `Could not open codec.` 并停止播放**（画面纹理其实已经建好了，尺寸也
  /// resize 到 640×360 —— 却被判成"文件解不了"）。`auto-safe` 只试
  /// 官方"安全"的硬解，失败**自动回落软件解码**，这才是用户期望的行为。
  ///
  /// 其它平台保持 media_kit 默认（r655/r678 已在真机验过，不动）。
  VideoControllerConfiguration _videoConfiguration() {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return const VideoControllerConfiguration(hwdec: 'auto-safe');
    }
    return const VideoControllerConfiguration();
  }

  /// ★ r678（`DA311`）：libmpv **没有 `vo` 就不解码** ⇒ 载入期间也要纹理。
  @override
  bool get needsSurfaceWhileLoading => true;

  /// 当前的"位置/背景条"（r656 · `DA271`）。默认 = 原样、无背景。
  int _subOffsetPx = 0;
  bool _subBackground = false;

  final _changes = StreamController<void>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];

  double _speed = 1;
  double _volume = 1;
  bool _muted = false;
  MediaAspectMode _aspect = MediaAspectMode.fit;

  String? _error;
  bool _ready = false;

  /// 当前内封字幕的文本（多行用 `\n` 拼；空 = 这一帧没有字幕）
  String? _subtitleText;

  List<MediaSource> _playlist = const [];
  int _playlistIndex = 0;

  List<MediaTrackInfo> _audioTracks = const [];
  List<MediaTrackInfo> _subtitleTracks = const [];
  String? _selectedAudioId;
  String? _selectedSubtitleId;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// r690（Linux 站现场）：`VideoController` 建得起来、属性也设得进去，
  /// 但**mpv 的纹理永远不来**（llvmpipe/Xvfb 下 Impeller 的 GLES 上下文不与
  /// mpv 共享）⇒ 界面一直是"转圈 + 00:00"，没有任何失败提示（AGENTS §2.0.80
  /// 的「黑屏时钟」假绿）。这里给一个**有界的等待**：到点仍没有纹理 id，
  /// 就落一条 [MediaPlaybackVideoOutputUnavailable]，让播放器页按"本机图形栈
  /// 建不起画面"给处置（换有 GPU 的桌面 / 关软件渲染），而不是无限等。
  ///
  /// 只在 Linux 生效：其它平台的纹理路径已经真机验过（r678 iOS / 安卓 r655），
  /// 不该因为某台慢机器被误判。
  void _bindSurfaceWatchdog() {
    _ensureVideoController().id.addListener(() {
      if (_videoController?.id.value == null) return;
      // 纹理来了：撤计时器；如果之前已经判过"画面建不起来"，把那条撤掉
      // （迟到的首帧仍是首帧 —— 别让用户对着一个已经恢复的画面看失败面板）。
      _surfaceWatchdog?.cancel();
      if (_error == _videoOutputUnavailableMessage) {
        _error = null;
        _notify();
      }
    });
  }

  /// 判"建不起来"时 `_error` 里放的**稳定串**（比对它才知道能不能撤）。
  static final String _videoOutputUnavailableMessage =
      const MediaPlaybackVideoOutputUnavailable().toString();

  /// r690：看门狗**在第一次要画面时才武装**。
  ///
  /// 为什么不挂在构造函数上：`MpvPlayerAdapter` 也用在"只听声音"的场合
  /// （`vo=null` 的解码探针 / 音频优先的页面），那里**本来就没有纹理**，
  /// 挂上必然误报。判据应当是"这个页面要画面吗"，而"要画面"的唯一证据
  /// 就是它真的调了 [buildSurface]。
  void _armSurfaceWatchdog() {
    if (_disposed) return;
    final controller = _ensureVideoController();
    if (!_surfaceWatchdogBound) {
      _surfaceWatchdogBound = true;
      _bindSurfaceWatchdog();
    }
    if (defaultTargetPlatform != TargetPlatform.linux) return;
    if (_surfaceWatchdog != null) return; // 只武装一次
    if (controller.id.value != null) return;
    _surfaceWatchdog = Timer(kVideoSurfaceTimeout, () {
      if (_disposed) return;
      if (_videoController?.id.value != null) return;
      if (_error != null) return;
      debugPrint('[r690mpv] 视频纹理 ${kVideoSurfaceTimeout.inSeconds}s 未到 '
          '=> videoOutputUnavailable');
      _error = _videoOutputUnavailableMessage;
      _notify();
    });
  }

  bool _disposed = false;

  void _bindStreams() {
    void sub<T>(Stream<T> s, void Function(T) onData) {
      _subs.add(s.listen(onData));
    }

    sub(_player.stream.duration, (_) => _notify());
    sub(_player.stream.position, (_) => _notify());
    sub(_player.stream.playing, (_) => _notify());
    sub(_player.stream.buffering, (_) => _notify());
    sub(_player.stream.width, (_) => _notify());
    sub(_player.stream.height, (_) => _notify());
    sub(_player.stream.tracks, (t) {
      _applyTracks(t);
      _notify();
    });
    sub(_player.stream.subtitle, (lines) {
      final text = lines.map((e) => e.trim()).where((e) => e.isNotEmpty).join('\n');
      final next = text.isEmpty ? null : text;
      if (next != _subtitleText) {
        _subtitleText = next;
        _notify();
      }
    });
    sub(_player.stream.error, (e) {
      // libmpv 的错误串里**没有**数字型诊断（"Failed to open …"），
      // `classifyPlayerError` 会按文本归类；这里只原样上报。
      //
      // ★ r678（`DA311`）：**环境性警告不算播不了** —— 没有音频设备时
      //   mpv 会报 `Could not open/initialize audio device -> no sound.`，
      //   但画面照常解（iOS 模拟器实测 `ready=true` / `aspectRatio=1.778`）。
      //   把它当致命错误 = 把"能看、没声音"说成"播放失败"。
      if (e.isNotEmpty && isMpvNonFatalError(e)) {
        debugPrint('[r678mpv] non-fatal: $e');
        return;
      }
      _error = e.isEmpty ? null : e;
      _notify();
    });
  }

  /// r679（`DA312`）：换音轨后 mpv 会**先**发一次"没有音轨"的 `tracks` 事件
  /// （重开解码器过程中的中间态），随后才是真表 —— 但中间态那一次足够把界面
  /// 打成「没有可选项」，而页面只在该事件后刷一次。
  ///
  /// 规矩：**丢过一次真表的适配器不许被空表覆盖**（`load()` 会把表清空，
  /// 所以"这个文件本来就没有音轨"仍然表达得出来 —— 那是换文件，不是中间态）。
  /// 纯函数，便于用例守。
  static List<T> keepLastNonEmptyTracks<T>(
    List<T> previous,
    List<T> incoming,
  ) => incoming.isEmpty && previous.isNotEmpty ? previous : incoming;

  void _applyTracks(Tracks t) {
    // ★ mpv 的轨道表里混着两条**伪轨**（`auto` / `no`）：那是"自动选"和"关掉"，
    //   不是文件里的音轨。真机读数：AC3 样本在兜底引擎下被列成 3 条
    //   （`/true`、`/true`、`ac3/true`）—— 前两条就是伪轨，界面会多出两个
    //   空名字入口。同一份文件在 Media3 下只有 1 条，换引擎不该变多。
    final realAudio = t.audio.where((a) => a.id != 'auto' && a.id != 'no');
    final realSubtitle = t.subtitle.where((s) => s.id != 'auto' && s.id != 'no');
    final nextAudio = keepLastNonEmptyTracks<MediaTrackInfo>(_audioTracks, [
      for (final a in realAudio)
        MediaTrackInfo(
          id: a.id,
          kind: MediaTrackKind.audio,
          label: a.title ?? a.language ?? '',
          language: a.language ?? '',
          codec: a.codec ?? '',
          channels: a.channelscount ?? 0,
          isDefault: a.isDefault ?? false,
          // ★ libmpv 自带解码器 ⇒ 它列出来的音轨**一律**可解；
          //   主引擎那些"本机不支持"的标记到这里就该消失（这正是兜底的意义）。
          isSupported: true,
        ),
    ]);
    if (!identical(nextAudio, _audioTracks)) _audioTracks = nextAudio;
    final nextSubtitle = keepLastNonEmptyTracks<MediaTrackInfo>(
      _subtitleTracks,
      [
      for (final s in realSubtitle)
        MediaTrackInfo(
          id: s.id,
          kind: MediaTrackKind.subtitle,
          label: s.title ?? s.language ?? '',
          language: s.language ?? '',
          codec: s.codec ?? '',
          isDefault: s.isDefault ?? false,
        ),
      ],
    );
    if (!identical(nextSubtitle, _subtitleTracks)) {
      _subtitleTracks = nextSubtitle;
    }
    _selectedAudioId ??=
        _audioTracks.isEmpty ? null : _audioTracks.first.id;
  }

  @override
  Duration get position => _player.state.position;

  @override
  Duration? get duration {
    final d = _player.state.duration;
    return d > Duration.zero ? d : null;
  }

  @override
  bool get playing => _player.state.playing;

  @override
  bool get ready => _ready;

  @override
  double get speed => _speed;

  @override
  String? get error => _error;

  @override
  double get aspectRatio {
    final w = _player.state.width ?? 0;
    final h = _player.state.height ?? 0;
    if (w <= 0 || h <= 0) return 16 / 9;
    final r = w / h;
    return r.isFinite && r > 0 ? r : 16 / 9;
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> load(MediaSource source) async {
    if (source.uri.isEmpty) {
      throw StateError('empty media url (${source.channel.code})');
    }
    _error = null;
    _ready = false;
    _subtitleText = null;
    _audioTracks = const [];
    _subtitleTracks = const [];
    _selectedAudioId = null;
    _selectedSubtitleId = null;
    // 字幕交给我们自己的浮层画 ⇒ mpv 侧一律关掉，避免双份字幕。
    await _player.setSubtitleTrack(SubtitleTrack.no());
    // ★ r678（`DA311`）：**把 TLS 政策翻译成 mpv 的开关**。
    //
    //   `MediaTlsPolicy` 下发给原生栈走的是 `synhub/player` 通道 —— 那条通道的
    //   另一头是 **AVFoundation 桥**（`MediaPlayerBridge.swift`），libmpv
    //   **收不到**。同 §2.0.11 的教训（原生组件的 TLS 政策必须与 Dart 侧一致），
    //   否则真 NAS（`https://nas.example.com:5001`，`CN=nas.example.com`）
    //   在兜底引擎上会重新变成"能播本地、播不了 NAS"。
    //
    //   判定复用同一个事实（`MediaTlsPolicy.isInstalledFor`）：**只放当前会话那台
    //   主机**，别的源照旧严格校验（`tls-verify=yes`）。
    try {
      // 走既有的属性桥（`MpvPropertyBridge`，`DA279`）：它按平台给 `null`
      // ⇒ 非原生/测试替身时**静默跳过**，不假装设上了。
      await MpvPropertyBridge.forPlatform(
        _player.platform,
      )?.set('tls-verify', mpvTlsVerifyValue(source.uri));
    } catch (_) {
      // 老版本 libmpv 不认这个属性 ⇒ 只是这条不生效，不要打断播放
    }
    await _player.open(
      Media(source.uri, httpHeaders: source.headers),
      play: true,
    );
    _ready = true;
    _playlist = const [];
    _playlistIndex = 0;
    // ★ r656（`DA271`）：`load()` 会把 mpv 属性带回默认 ⇒ 换片后**必须重放**
    //   一次用户的位置/背景条设置，否则"第一部片子调好的位置，第二部又贴回去"。
    await _applySubtitleStyle();
    _notify();
  }

  @override
  Future<void> play() async {
    // 与主引擎同一个坑：播完再按播放键必须回到起点（`video_player` 那次修法的
    // mpv 版本 —— `player.play()` 在 EOF 后同样是 no-op）。
    final d = duration;
    if (d != null && position >= d) {
      await _player.seek(Duration.zero);
    }
    await _player.play();
    _notify();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _notify();
  }

  @override
  Future<void> seekTo(Duration position) async {
    await _player.seek(position);
    _notify();
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _player.setRate(speed);
    _notify();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _surfaceWatchdog?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _player.dispose();
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Widget buildSurface(BuildContext context) {
    _armSurfaceWatchdog();
    // ★ r678（`DA311`）：给"这一帧是 libmpv 画的"一个**可断言的身份**
    //   （验收装置用）。为什么必要：iOS 上 `.AVI` 在 AVFoundation 下是
    //   "标题对、进度在涨、画面全黑"——只看进度会**假绿**（r676 `DA306` 同款）。
    //   `media-engine-mpv` 在 ⇒ 出画的这个引擎是 libmpv，不是主引擎的残帧。
    final v = KeyedSubtree(
      key: const Key('media-engine-mpv'),
      child: Video(controller: _ensureVideoController()),
    );
    if (_aspect == MediaAspectMode.fit) return v;
    // 与主引擎同一套手势语义：fill=cover、zoom=cover×1.25、stretch=铺满变形。
    final fit = switch (_aspect) {
      MediaAspectMode.fill || MediaAspectMode.zoom => BoxFit.cover,
      MediaAspectMode.stretch => BoxFit.fill,
      MediaAspectMode.fit => BoxFit.contain,
    };
    return FittedBox(
      fit: fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: 1,
        height: 1,
        child: Transform.scale(
          scale: _aspect == MediaAspectMode.zoom ? kMediaZoomScale : 1,
          child: v,
        ),
      ),
    );
  }

  // ── MediaPlayerFullControls ───────────────────────────────────────────────

  @override
  Future<void> skipBy(Duration offset) async {
    final target = position + offset;
    var next = target < Duration.zero ? Duration.zero : target;
    final d = duration;
    if (d != null && next > d) next = d;
    await seekTo(next);
  }

  @override
  Future<void> setVolume(double value) async {
    _volume = value.clamp(0, 1);
    await _player.setVolume(_muted ? 0 : _volume * 100);
    _notify();
  }

  @override
  double get volume => _volume;

  @override
  Future<void> setMuted(bool value) async {
    _muted = value;
    await _player.setVolume(_muted ? 0 : _volume * 100);
    _notify();
  }

  @override
  bool get muted => _muted;

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {
    if (items.isEmpty) return;
    _playlist = List.unmodifiable(items);
    _playlistIndex = index.clamp(0, items.length - 1);
    await _player.open(
      Playlist(
        [
          for (final it in _playlist)
            Media(it.uri, httpHeaders: it.headers),
        ],
        index: _playlistIndex,
      ),
      play: true,
    );
    _ready = true;
    _notify();
  }

  @override
  int get playlistIndex => _player.state.playlist.index;

  @override
  int get playlistLength => _player.state.playlist.medias.length;

  @override
  bool get hasPrevious => playlistIndex > 0;

  @override
  bool get hasNext => playlistIndex >= 0 && playlistIndex < playlistLength - 1;

  @override
  Future<void> playNext() async {
    if (!hasNext) return;
    await _player.next();
    _notify();
  }

  @override
  Future<void> playPrevious() async {
    if (!hasPrevious) return;
    await _player.previous();
    _notify();
  }

  @override
  List<MediaTrackInfo> get audioTracks => _audioTracks;

  @override
  List<MediaTrackInfo> get subtitleTracks => _subtitleTracks;

  @override
  String? get selectedAudioTrackId => _selectedAudioId;

  @override
  String? get selectedSubtitleTrackId => _selectedSubtitleId;

  @override
  Future<void> selectAudioTrack(String? id) async {
    if (id == null) return;
    final t = _audioTracks.where((e) => e.id == id).firstOrNull;
    if (t == null) return;
    _selectedAudioId = id;
    await _player.setAudioTrack(
      AudioTrack(id, t.label.isEmpty ? null : t.label,
          t.language.isEmpty ? null : t.language),
    );
    _notify();
  }

  @override
  Future<void> selectSubtitleTrack(String? id) async {
    _selectedSubtitleId = id;
    if (id == null) {
      _subtitleText = null;
      // ★ 只有"关字幕"时才动 mpv 侧（本来就是 no）；选中内封字幕时也保持 no ——
      //   文本走 `stream.subtitle`，画面由我们的浮层统一画。
      await _player.setSubtitleTrack(SubtitleTrack.no());
      _notify();
      return;
    }
    final t = _subtitleTracks.where((e) => e.id == id).firstOrNull;
    if (t == null) return;
    // `SubtitleTrack.no()` 之后要让 mpv **解码**该字幕轨才能拿到文本，
    // `SubtitleTrack.auto()` 会挑默认轨；指定轨用 id 构造。
    await _player.setSubtitleTrack(
      SubtitleTrack(id, t.label.isEmpty ? null : t.label,
          t.language.isEmpty ? null : t.language),
    );
    // ★ r656（`DA271`）：`sid=<id>` 之后字幕才真正开始画 —— 这时再推一遍属性，
    //   免得"先调位置、后选字幕"的顺序下用户看到的是默认位置。
    await _applySubtitleStyle();
    _notify();
  }

  @override
  MediaAspectMode get aspectMode => _aspect;

  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {
    _aspect = mode;
    _notify();
  }

  @override
  String? get embeddedSubtitleText => null;

  /// 兜底引擎的字幕是 **mpv 自己画的**（`sid=<id>` 之后 mpv 就把字幕烧进画面纹理）。
  ///
  /// ★★★ `DA269`（r655 真机）：这一点跟本文件开头写的设想**相反** ——
  ///   原以为"`sid=no` + 只交文本"能让我们自己的浮层接管，实测选了字幕之后
  ///   mpv 会重新打开渲染，于是画面里那行字是 mpv 画的，**我们的字号/背景/垂直
  ///   偏移全部无效**，而行首还在（界面在骗人）。
  ///   现在的口径：**兜底引擎上承认是它画的** —— [rendersOwnSubtitles] 为 true，
  ///   界面据此隐藏那三个只在自家浮层上生效的控件（宁可少给，不给假控件）。
  @override
  bool get rendersOwnSubtitles => true;

  /// r656 · `DA271`：mpv 自己画字幕，但**位置/背景条它听得懂**。
  ///
  /// 实现走 [MpvPropertyBridge]（media_kit 的 libmpv 属性桥；**Web 上没有**，门面返回 null）。三处会重放：
  /// ① 用户改设置时；② 每次 `load()` 之后（换片时 mpv 会回到默认属性）；
  /// ③ 选中字幕轨之后（有轨才画，但属性先设好没坏处）。
  @override
  Future<void> setSubtitleStyle({
    required int offsetPx,
    required bool background,
  }) async {
    _subOffsetPx = offsetPx;
    _subBackground = background;
    await _applySubtitleStyle();
  }

  /// 把当前样式推给 libmpv（**永不抛**：调样式失败不能影响播放）。
  Future<void> _applySubtitleStyle() async {
    // ★ `DA279`（r664）：属性读/写只能走条件导入的门面。
    //   直接 `platform is NativePlayer` + `getProperty` 会让 **Web 编译不过**
    //   （Web 的 NativePlayer 来自 stub.dart，没有这两个方法）。
    //   null = 这个平台没有 libmpv 属性 ⇒ 静默跳过（不假装设上了）。
    final bridge = MpvPropertyBridge.forPlatform(_player.platform);
    if (bridge == null) return;
    // 窗口高度：`sub-pos` 是百分比，得按真实播放窗口换算成"抬多少像素"。
    var windowHeight = 0;
    try {
      windowHeight = int.tryParse(await bridge.get('osd-dimensions/h')) ?? 0;
    } catch (_) {
      windowHeight = 0; // 还没出第一帧 ⇒ 这一轮按"不抬"处理，下一次事件会重放
    }
    for (final e
        in mpvSubtitleProperties(
          offsetPx: _subOffsetPx,
          background: _subBackground,
          windowHeightPx: windowHeight,
        ).entries) {
      try {
        await bridge.set(e.key, e.value);
      } catch (_) {
        // 老版本 mpv 没这个属性也不该把播放打断 —— 这一项没生效而已。
      }
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
