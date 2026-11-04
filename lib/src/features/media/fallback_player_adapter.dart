// 「主引擎拿不动就换兜底引擎」的**选择策略层**（r655）。
//
// 主引擎 = 自研 Media3 桥（轨道/字幕/画面比例能力最全）；
// 兜底引擎 = libmpv（`mpv_player_adapter.dart`，自带完整 ffmpeg）。
//
// 什么时候换（判据只看**证据**，不猜文件后缀）：
//   ① 载入后音轨列表**非空且每一条都 `isSupported == false`**
//      —— Media3 `Tracks.Group.isTrackSupported()` 经原生桥给过来的**确定结论**；
//   ② 载入/起播后错误串被 `classifyPlayerError` 归到
//      `codecUnsupported` / `decodeFailed`（"解不了"这一类），且主引擎确实没出过画面。
//      注意：`streamRejected` / `sessionExpired` / `networkFailed` / `platformUnsupported`
//      **不换** —— 那些换引擎也没用，换了只会把"服务端拒绝"伪装成"播放失败"。
//
// 为什么不一开始就用 libmpv：主引擎能选内封字幕轨、能改画面比例、能上报
// `onCues`，而 libmpv 那条路的字幕渲染要靠 mpv 自己或者靠 `sub-text` 文本；
// 能用主引擎的场景不该付这个代价（也省一次 20MB 级 .so 的载入）。
//
// ⚠️ 本类**只在 Android 主引擎上包装**（见 `createDefaultMediaPlayerAdapter`）。
// 它总是 `is MediaPlayerFullControls`，所以包装的前提是内层主引擎也是完整控制器；
// 其它平台的 `video_player` 回退**不包装**（那里没有"轨道解码能力"这回事）。
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'media_player.dart';
import 'media_source.dart';
import 'media_tracks.dart';

/// r678 引擎切换诊断（`--dart-define=R678_TRACE=true` 才打）；不进产品行为。
const bool kMediaEngineTrace = bool.fromEnvironment('R678_TRACE');

/// 换引擎的原因（给界面说人话用；null = 没换过）
enum MediaFallbackEngineReason {
  /// 音轨全部标着"本机不支持"（Media3 的确定结论）
  audioTracksUnsupported('audio-tracks-unsupported'),

  /// 载入/起播失败的串被判成"解不了"
  decodeFailure('decode-failure');

  const MediaFallbackEngineReason(this.code);
  final String code;
}

class FallbackPlayerAdapter
    implements
        MediaPlayerAdapter,
        MediaPlayerEngineSwitchable,
        MediaPlayerFullControls,
        MediaPlayerContinuationNotice,
        MediaPlayerSelfRenderedSubtitles,
        MediaPlayerSubtitleStyling {
  FallbackPlayerAdapter({
    required MediaPlayerAdapter primary,
    required MediaPlayerAdapter Function() createFallback,
    bool enabled = true,
  })  : _active = primary,
        _createFallback = createFallback,
        _enabled = enabled {
    // ★ `DA268`：**一开始就**订上内层事件 —— 页面在"有播放列表"时走
    //   `setPlaylist()`，`load()` 根本不会被调用；只在 `load()` 里 `_bind()`
    //   等于这条路没有监听者（晚到的 tracks 事件没人接）。
    _bind();
  }

  MediaPlayerAdapter _active;
  final MediaPlayerAdapter Function() _createFallback;
  final bool _enabled;

  final _changes = StreamController<void>.broadcast();
  StreamSubscription<void>? _activeSub;

  bool _switched = false;
  bool _switching = false;
  MediaSource? _source;
  List<MediaSource>? _playlist;

  /// 用户当前的字幕样式（r656 · `DA271`）—— 换引擎时要**带给新引擎**。
  int _subOffsetPx = 0;
  bool _subBackground = false;
  int _playlistIndex = 0;
  MediaFallbackEngineReason? _reason;

  /// 换过引擎之后是"兜底引擎在播"（界面用来解释为什么音轨那条"不支持"消失了）
  @override
  bool get usingFallbackEngine => _switched;

  /// ★ r678（`DA311`）：**正在换引擎**（dispose 主引擎 → 新建兜底 → 重新 load）。
  ///
  /// 页面判"播不了"必须让开这个窗口：主引擎的错误串会先到，而兜底引擎往往
  /// 一秒内就能出画面 —— 若页面在这一秒里就把致命面板挂上去，用户看到的是
  /// "明明能播却写着解不开"（r676 的兜底面板在 iOS 上就是这么来的）。
  @override
  bool get engineSwitchPending => _switching && !_engineSettled;

  /// 换引擎这道闩**已经过完**（成功或失败都算），页面可以正常判死了。
  bool _engineSettled = true;

  MediaFallbackEngineReason? get fallbackEngineReason => _reason;

  MediaPlayerAdapter get activeAdapter => _active;

  /// 当前引擎是不是"自己画字幕"（`DA269`）。换引擎后**跟着变** —— 界面据此
  /// 隐藏字幕位置/背景条/字号那几行。
  @override
  bool get rendersOwnSubtitles {
    final a = _active;
    return a is MediaPlayerSelfRenderedSubtitles &&
        (a as MediaPlayerSelfRenderedSubtitles).rendersOwnSubtitles;
  }

  /// r656 · `DA271`：把样式交给**当前**引擎（能听懂的那个）。
  ///
  /// 主引擎（Media3 桥）不实现 [MediaPlayerSubtitleStyling] —— 它的字幕是
  /// 我们自己的浮层画的，样式天然生效；所以这里"没有接收方"是**正常**的，
  /// 不是失败，也就不要假装设上了。
  @override
  Future<void> setSubtitleStyle({
    required int offsetPx,
    required bool background,
  }) async {
    _subOffsetPx = offsetPx;
    _subBackground = background;
    await _pushSubtitleStyle();
  }

  Future<void> _pushSubtitleStyle() async {
    final a = _active;
    if (a is MediaPlayerSubtitleStyling) {
      try {
        await (a as MediaPlayerSubtitleStyling)
            .setSubtitleStyle(offsetPx: _subOffsetPx, background: _subBackground);
      } catch (_) {
        // 调样式失败不许影响播放（最多这一项没生效）
      }
    }
  }

  void _bind() {
    _activeSub?.cancel();
    _activeSub = _active.changes.listen((_) {
      unawaited(_recheck());
      _notify();
    });
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ── MediaPlayerAdapter ────────────────────────────────────────────────────

  @override
  Future<void> load(MediaSource source) async {
    // ignore: avoid_print
    print('[r655probe] FallbackPlayerAdapter.load ${source.uri}');
    debugPrint('[r678engine] load ${source.displayName} enabled=$_enabled');
    _bind();
    await _active.load(source);
    if (!_enabled || _switched) {
      _notify();
      return;
    }
    _source = source;
    _error = null;
    if (await _recheck()) return;
    _notify();
  }

  /// 主引擎"播不了"的判定 —— **不是只在 `load()` 之后看一眼**。
  ///
  /// ★★★ `DA266`（r655 真机）：`load()` 返回的时候 Media3 的 `tracks` 往往还是空的
  /// （轨道要等 `onTracksChanged` 才来），于是 `_audioAllUnsupported()` 看到
  /// 空列表就返回 `false`，**永远不会换引擎**。改成在 `changes` 事件里反复问，
  /// 一旦"这条轨道确实本机没有解码器"再换（`_switched` 是闩，只会换一次）。
  Future<bool> _recheck() async {
    if (!_enabled || _switched || _switching) return false;
    final source = _source;
    if (source == null) return false;
    try {
      if (_audioAllUnsupported()) {
        await _switchTo(source, MediaFallbackEngineReason.audioTracksUnsupported);
        return true;
      }
      if (kMediaEngineTrace) {
        debugPrint('[r678engine] recheck err=${_active.error} '
            'reason=${classifyPlayerError(_active.error ?? '').code}');
      }
      if (_looksUndecodable(_active.error)) {
        await _switchTo(source, MediaFallbackEngineReason.decodeFailure);
        return true;
      }
      return false;
    } finally {
      // 兜底引擎自己 `load` 抛异常时，把闩解开，下一帧还能再试一次。
      _switching = false;
      _engineSettled = true;
    }
  }

  bool _audioAllUnsupported() {
    // ★ 两个接口互不相交 ⇒ `is` 不能把 `MediaPlayerAdapter` **提升**成
    // `MediaPlayerFullControls`（提升只对子类型生效），必须显式转型。
    final a = _active;
    if (a is! MediaPlayerFullControls) return false;
    final tracks = (a as MediaPlayerFullControls).audioTracks;
    if (tracks.isEmpty) return false;
    return tracks.every((t) => !t.isSupported);
  }

  bool _looksUndecodable(String? error) {
    if (error == null || error.isEmpty) return false;
    final r = classifyPlayerError(error);
    return r == MediaUnavailableReason.codecUnsupported ||
        r == MediaUnavailableReason.decodeFailed;
  }

  /// 换引擎：**保住用户的位置与播放意图**（位置回填 + 原来在播就继续播）。
  Future<void> _switchTo(MediaSource source, MediaFallbackEngineReason reason) async {
    final pos = _active.position;
    final wasPlaying = _active.playing || _active.error == null;
    debugPrint('[r678engine] switch -> ${reason.code}');
    _switched = true;
    _switching = true;
    _engineSettled = false;
    _reason = reason;
    try {
      await _active.dispose();
    } catch (_) {
      // 主引擎已经在错误态时 dispose 可能再抛一次；不让它阻断兜底。
    }
    // ★ r678（`DA311`）：兜底引擎**建不起来**（缺 `Mpv.framework`、`MediaKit`
    //   没初始化…）不许把整页抛崩 —— 那是"环境不完整"，不是"这个文件播不了"。
    //   这里的退路 = 保留一个**说明清楚**的错误串，页面照常给回退面板。
    try {
      _active = _createFallback();
    } catch (e, st) {
      debugPrint('[r678engine] fallback create failed: $e');
      debugPrintStack(stackTrace: st, maxFrames: 8);
      _switched = false;
      _switching = false;
      _engineSettled = true;
      _error = '[engine-unavailable] $e';
      _notify();
      return;
    }
    _bind();
    // 兜底引擎只装**当前这一条**：media_kit 的 `Playlist` 模式下真机上拿不到
    // 完整轨道表（读数：音轨面板 "Nothing to choose"），而"能选音轨"正是这条
    // 兜底存在的理由。播放列表改由本类记账（见下面的 `playlistIndex`/`playNext`）。
    await _active.load(source);
    debugPrint('[r678engine] fallback loaded ready=${_active.ready} '
        'err=${_active.error} aspect=${_active.aspectRatio}');
    if (pos > Duration.zero) {
      try {
        await _active.seekTo(pos);
      } catch (_) {
        // 位置回填是"尽力而为"：失败也不该让兜底播放整体失败。
      }
    }
    if (wasPlaying) {
      try {
        await _active.play();
      } catch (_) {
        // 同上：播放意图尽力而为。
      }
    }
    // ★ r656（`DA271`）：新引擎是"新开的一个播放器"，它不知道用户调过位置/背景 ——
    //   换过去的同一秒就要把样式交过去，否则会出现"一换引擎字幕就跳回底部"。
    await _pushSubtitleStyle();
    _switching = false;
    _engineSettled = true;
    _notify();
  }

  @override
  Duration get position => _active.position;

  @override
  Duration? get duration => _active.duration;

  @override
  bool get playing => _active.playing;

  @override
  bool get ready => _active.ready;

  @override
  double get speed => _active.speed;

  /// ★ r678（`DA311`）：换引擎的**那一段**里不报错。
  ///
  /// 主引擎的 `-11828` 是"这一代不行"的证据，不是"兜底也不行"的结论；
  /// 这窗口里把它报给页面，页面就会在兜底成功前把致命面板挂上去。
  /// 换引擎自身失败（兜底引擎建不起来）时的错误串；null = 没发生
  String? _error;

  @override
  String? get error => _switching ? null : (_error ?? _active.error);

  @override
  double get aspectRatio => _active.aspectRatio;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> play() => _active.play();

  @override
  Future<void> pause() => _active.pause();

  @override
  Future<void> seekTo(Duration position) => _active.seekTo(position);

  @override
  Future<void> setSpeed(double speed) => _active.setSpeed(speed);

  @override
  Future<void> dispose() async {
    await _activeSub?.cancel();
    await _active.dispose();
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Widget buildSurface(BuildContext context) => _active.buildSurface(context);

  // ── MediaPlayerContinuationNotice ─────────────────────────────────────────

  @override
  bool get hasNoPictureContinuationNotice {
    final a = _active;
    return a is MediaPlayerContinuationNotice
        ? (a as MediaPlayerContinuationNotice).hasNoPictureContinuationNotice
        : false;
  }

  // ── MediaPlayerFullControls（全部转发给当前引擎）─────────────────────────

  MediaPlayerFullControls get _full {
    final a = _active;
    if (a is MediaPlayerFullControls) return a as MediaPlayerFullControls;
    throw StateError('active adapter has no full controls');
  }

  @override
  Future<void> skipBy(Duration offset) => _full.skipBy(offset);

  @override
  Future<void> setVolume(double value) => _full.setVolume(value);

  @override
  double get volume => _full.volume;

  @override
  Future<void> setMuted(bool value) => _full.setMuted(value);

  @override
  bool get muted => _full.muted;

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {
    _bind();
    // ★★★ `DA268`（r655 真机）：页面在**有播放列表**时走的是
    //   `setPlaylist(...)` 而不是 `load(...)`（文件页给了同目录的兄弟条目）。
    //   本类原先只在 `load()` 里"看一眼音轨"，于是这条路上的兜底**永远不会触发**
    //   —— 真机表现：AC3 文件有画面、零声音、零提示（`FallbackPlayerAdapter.load`
    //   的探针一次都没打印，而内层原生桥的 tracks 事件明明来了）。
    //   所以两个入口都要接上：先记下来源，再交给内层，然后重新判一次。
    _playlist = List<MediaSource>.unmodifiable(items);
    _playlistIndex = index;
    if (index >= 0 && index < items.length) _source = items[index];
    await _full.setPlaylist(items, index);
    if (await _recheck()) return;
    _notify();
  }

  /// ★ 换过引擎后，列表由**本类**记账（内层引擎手里只有当前这一条）：
  ///   否则"下一集"会当场消失（`playlistLength` 从 N 变 1）。
  bool get _ownsPlaylistBookkeeping => _switched && _playlist != null;

  @override
  int get playlistIndex =>
      _ownsPlaylistBookkeeping ? _playlistIndex : _full.playlistIndex;

  @override
  int get playlistLength =>
      _ownsPlaylistBookkeeping ? _playlist!.length : _full.playlistLength;

  @override
  bool get hasPrevious => _ownsPlaylistBookkeeping
      ? playlistIndex > 0
      : _full.hasPrevious;

  @override
  bool get hasNext =>
      _ownsPlaylistBookkeeping ? playlistIndex + 1 < playlistLength : _full.hasNext;

  @override
  Future<void> playNext() async {
    if (!_ownsPlaylistBookkeeping) return _full.playNext();
    if (!hasNext) return;
    await _playIndex(playlistIndex + 1);
  }

  @override
  Future<void> playPrevious() async {
    if (!_ownsPlaylistBookkeeping) return _full.playPrevious();
    if (playlistIndex <= 0) return;
    await _playIndex(playlistIndex - 1);
  }

  /// 换过引擎后自己换集：记账 + 让当前（兜底）引擎装这一条。
  Future<void> _playIndex(int index) async {
    final items = _playlist;
    if (items == null || index < 0 || index >= items.length) return;
    _playlistIndex = index;
    _source = items[index];
    await _active.load(_source!);
    await _recheck();
    _notify();
  }

  @override
  List<MediaTrackInfo> get audioTracks => _full.audioTracks;

  @override
  List<MediaTrackInfo> get subtitleTracks => _full.subtitleTracks;

  @override
  String? get selectedAudioTrackId => _full.selectedAudioTrackId;

  @override
  String? get selectedSubtitleTrackId => _full.selectedSubtitleTrackId;

  @override
  Future<void> selectAudioTrack(String? id) => _full.selectAudioTrack(id);

  @override
  Future<void> selectSubtitleTrack(String? id) => _full.selectSubtitleTrack(id);

  @override
  MediaAspectMode get aspectMode => _full.aspectMode;

  @override
  Future<void> setAspectMode(MediaAspectMode mode) => _full.setAspectMode(mode);

  @override
  String? get embeddedSubtitleText => _full.embeddedSubtitleText;
}
