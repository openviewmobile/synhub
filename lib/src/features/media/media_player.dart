// 内置视频播放器的**适配器**：把 `video_player`（Media3 / ExoPlayer）藏在接口后面。
//
// 为什么要这层：
//   * `VideoPlayerController` 在单测里**起不来**（没有平台通道，`dart:ui` 纹理也没
//     有），页面层想测"播放/暂停/拖进度/错误态 → 文案与回退入口"就必须能注入假
//     适配器（见 test/media_player_page_test.dart）；
//   * 将来若要换 `media_kit` 兜底（AC3/DTS/APE，调研 §4），只换这一层的真实实现。
//
// 通道选择与限制见 `media_source.dart` 与 docs/native-media-playback-research.md：
//   * 本项目推荐的通道**全是查询串鉴权**（`_sid` + `SynoToken`）→ 不需要
//     `httpHeaders`，也就不需要 just_audio 那种"本地明文代理"；
//   * Range 由 ExoPlayer 的 `DefaultHttpDataSource` 自动发，seek 依赖服务端给
//     `Content-Length` / `206`（FileStation 真机实测支持）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import 'media_source.dart';
import 'media_tracks.dart';
import 'native_video_player.dart' show createDefaultMediaPlayerAdapter;

/// 播放器适配器（真实实现 = [VideoPlayerAdapter]，测试注入假实现）
abstract class MediaPlayerAdapter {
  /// 载入并初始化一个来源（抛异常 = 初始化失败，调用方转成"失败 + 回退"界面）
  Future<void> load(MediaSource source);

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(Duration position);

  /// 播放速率（1.0 = 原速）
  Future<void> setSpeed(double speed);

  Future<void> dispose();

  Duration get position;

  /// 未知时长 → null（界面上显示 `--:--`）
  Duration? get duration;

  bool get playing;

  /// 已经初始化完，可以出画面
  bool get ready;

  double get speed;

  /// 初始化/播放错误的一句话（null = 没出错）
  String? get error;

  /// 画面宽高比（未就绪时给 16/9，避免布局跳动）
  double get aspectRatio;

  /// 画面本体（真实实现里是 `VideoPlayer(controller)`）
  Widget buildSurface(BuildContext context);

  /// 位置 / 状态 / 错误变化（界面 `setState` 用）
  Stream<void> get changes;
}

/// 真实实现：`video_player` 2.14（Android 落 Media3 / ExoPlayer）
class VideoPlayerAdapter implements MediaPlayerAdapter {
  VideoPlayerController? _controller;
  final _changes = StreamController<void>.broadcast();
  double _speed = 1;

  @override
  Duration get position => _controller?.value.position ?? Duration.zero;

  @override
  Duration? get duration {
    final d = _controller?.value.duration;
    if (d == null || d == Duration.zero) return null;
    return d;
  }

  @override
  bool get playing => _controller?.value.isPlaying ?? false;

  @override
  bool get ready => _controller?.value.isInitialized ?? false;

  @override
  double get speed => _speed;

  @override
  String? get error {
    final v = _controller?.value;
    if (v == null) return null;
    return v.hasError ? (v.errorDescription ?? 'unknown') : null;
  }

  @override
  double get aspectRatio {
    final r = _controller?.value.aspectRatio ?? 0;
    return (r.isFinite && r > 0) ? r : 16 / 9;
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> load(MediaSource source) async {
    if (source.uri.isEmpty) {
      throw StateError('empty media url (${source.channel.code})');
    }
    final c = VideoPlayerController.networkUrl(
      Uri.parse(source.uri),
      // 鉴权全在查询串（`_sid`/`SynoToken`）→ 这里**不传自定义头**
      httpHeaders: source.headers ?? const <String, String>{},
    );
    _controller = c;
    c.addListener(_notify);
    await c.initialize();
    await c.setLooping(false);
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  @override
  Future<void> play() async {
    final c = _controller;
    if (c != null) {
      // ★ 第 295 轮修（真机缺陷：播到结尾后播放键按了没反应）：
      // `video_player` 在**播放结束态**下 `play()` 是 **no-op**，必须先 seek 回起点，
      // 否则用户看到的是"进度冻住 + 按钮永远显示 Play、点了没反应、也不报错"。
      // 真机实测：`home/Music/CD1 - 01 - Track01.mp3` 播到 01:34/07:16 后即锁死。
      final v = c.value;
      final ended = v.isCompleted ||
          (v.duration > Duration.zero && v.position >= v.duration);
      if (ended) {
        await c.seekTo(Duration.zero);
      }
      await c.play();
    }
    _notify();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
    _notify();
  }

  @override
  Future<void> seekTo(Duration position) async {
    await _controller?.seekTo(position);
    _notify();
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _controller?.setPlaybackSpeed(speed);
    _notify();
  }

  @override
  Future<void> dispose() async {
    final c = _controller;
    _controller = null;
    c?.removeListener(_notify);
    await c?.dispose();
    await _changes.close();
  }

  @override
  Widget buildSurface(BuildContext context) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return VideoPlayer(c);
  }
}

/// 适配器工厂（测试里覆盖成返回假适配器的函数）
typedef MediaPlayerAdapterFactory = MediaPlayerAdapter Function();

/// 默认播发器：**Android 走自研原生播放器**（`MediaPlayerBridge.kt`，能选轨道/
/// 音量/画面比例），其它平台（iOS/桌面/Web）以及任何原生桥缺失的场景回退到
/// `video_player`。
///
/// `video_player` 的回退实现**故意**不实现 [MediaPlayerFullControls]：能力有
/// 没有是"运行时能否问到"决定的，不是猜的 —— 界面据此显示/隐藏扩展按钮。
final mediaPlayerAdapterFactoryProvider = Provider<MediaPlayerAdapterFactory>(
  (ref) => createDefaultMediaPlayerAdapter,
);

/// ★ r678（`DA311`）：「主引擎判死 → 换兜底引擎」这段**窗口**对页面可见。
///
/// 为什么需要它：换引擎时主引擎的错误串**先到**，而兜底引擎（libmpv）往往
/// 一秒多就能出画面。页面若在那一秒里就把致命面板挂上去，用户看到的是
/// "明明能播却写着解不开" —— iOS 上 r676 之前那张 mkv 面板正是这么来的。
///
/// 页面只认这个接口（不认 `FallbackPlayerAdapter` 具体类）：假适配器不需要实现它。
abstract class MediaPlayerEngineSwitchable {
  /// 正在换引擎（这期间 [MediaPlayerAdapter.error] 会被抑制成 null）
  bool get engineSwitchPending;

  /// 已经换过引擎（当前是兜底引擎在播）
  bool get usingFallbackEngine;
}

/// ★ r678（`DA311`）：引擎**在 `load()` 期间就需要画面纹理挂上去**。
///
/// 为什么（r677 实测教训）：libmpv **没有视频输出（`vo`）时只解容器、不解码** ——
/// 判据是探针里 `duration` 有了、`videoParams` 一直是 `TIMEOUT`；一旦
/// `VideoController` ＋ `Video` 纹理挂上去，mkv/avi **都立刻解出 `w=320 h=240`**。
/// 而页面原来的载入分支只画封面/转圈（不建 surface）⇒ 兜底引擎永远等不到纹理。
///
/// 所以：实现了这个接口的引擎，页面在 `!ready` 期间也要把 surface 挂上
/// （转圈照旧盖在上面，用户看到的仍是"载入中"）。
abstract class MediaPlayerNeedsSurfaceWhileLoading {
  /// 真的需要（假适配器/测试替身可以不实现本接口）
  bool get needsSurfaceWhileLoading;
}

/// 「完整播放器控制」：只有自研原生播放器才有的能力。
///
/// 为什么单独一个接口而不是往 [MediaPlayerAdapter] 上加方法：
///   * `video_player`（Media3 封装）**不暴露**轨道选择 / 字幕 / 音量 / 画面比例 /
///     播放列表跳转，给它硬塞空实现只会让"按钮点了没反应"变得难以察觉；
///   * 界面用 `adapter is MediaPlayerFullControls` 做**能力判断**，缺能力时按钮
///     直接不出现（而不是出现了但禁用）；
///   * 已有的假适配器（`test/media_player_page_test.dart`）因此完全不用改。
abstract class MediaPlayerFullControls {
  /// 快进 / 快退：`offset` 可正可负，结果**夹在 `[0, 总时长]`**（总时长未知时
  /// 只夹下界）。
  Future<void> skipBy(Duration offset);

  /// 音量 0.0–1.0（`ExoPlayer.setVolume`，不动系统音量）
  Future<void> setVolume(double value);

  double get volume;

  /// 静音（保持 [volume] 不变，只把输出压到 0）
  Future<void> setMuted(bool value);

  bool get muted;

  /// 用整份播放列表（同一个目录的同类型文件）重新载入，并从 [index] 开始
  Future<void> setPlaylist(List<MediaSource> items, int index);

  int get playlistIndex;

  int get playlistLength;

  /// 第一个文件没有"上一个"、最后一个没有"下一个"（按钮禁用态同源）
  bool get hasPrevious;

  bool get hasNext;

  Future<void> playNext();

  Future<void> playPrevious();

  /// 音轨 / **内封**字幕轨（外挂字幕由 Dart 侧解析，见 `media_subtitles.dart`）
  List<MediaTrackInfo> get audioTracks;

  List<MediaTrackInfo> get subtitleTracks;

  String? get selectedAudioTrackId;

  /// null = 字幕关闭
  String? get selectedSubtitleTrackId;

  Future<void> selectAudioTrack(String? id);

  /// `null` = 关闭内封字幕
  Future<void> selectSubtitleTrack(String? id);

  MediaAspectMode get aspectMode;

  Future<void> setAspectMode(MediaAspectMode mode);

  /// 内封字幕当前这一帧的文本（由 Media3 `Player.Listener.onCues` 转发）
  String? get embeddedSubtitleText;
}

/// 「**自动续播**进入的条目在起播窗口内没有任何画面证据」的**非阻塞**提示能力。
///
/// 为什么是独立能力接口（与 [MediaPlayerFullControls] 同一个取舍）：
///   * 看门狗只存在于自研原生播放器（`NativeVideoPlayerAdapter`）；
///   * `video_player` 回退与既有假适配器都不实现 → 界面用 `is` 判断，缺能力就
///     不显示提示，既有实现不用改。
///
/// 为什么**不**走 `error`：R5 实测的漏报路径是"片尾自动续播到无解码器条目 →
/// 全黑且没有任何提示"。它必须给用户反馈，但不能退化成"编码不支持"的致命面板：
///   1. 用户没点选这一条；弹面板会盖住播放器（自动续播场景应保持可操作）；
///   2. 长片"位置在推进 → 抑制上报"的取舍必须保持（宁可漏报也不误伤可解码
///      文件）—— 提示是附加信息，不进 `error`，不改变回退面板的触发条件。
abstract class MediaPlayerContinuationNotice {
  /// true = 自动续播（非用户点选）进入的当前条目，在看门狗窗口内零画面证据。
  bool get hasNoPictureContinuationNotice;
}

/// 引擎**自己**画字幕（我们的浮层插不上手）。
///
/// ★ `DA269`（r655）：`media_kit/libmpv` 这条路就是如此 —— `sid=<id>` 之后 mpv
/// 把字幕烧进画面纹理，字号/背景/垂直偏移全部由 mpv 说了算。界面据此**隐藏**
/// 那几个只在自家浮层上生效的控件（宁可少给，不给"调了没反应"的假控件）。
abstract class MediaPlayerSelfRenderedSubtitles {
  bool get rendersOwnSubtitles;
}

/// 引擎**自己画字幕，但听得懂"位置/背景条"两项设置**（r656 · `DA271`）。
///
/// 与 [MediaPlayerSelfRenderedSubtitles] 的分工：
///   * 那个标记只说"字幕不是我们画的"（`DA269`）⇒ 字号这类**渲染细节**我们插不上手；
///   * 这个接口说"虽然不是我画的，但你能用我的属性调位置/底色" —— libmpv 就是
///     这种：`sub-margin-y` 抬高度、`sub-border-style=opaque-box` + `sub-back-color`
///     给背景条，全都由它自己渲染。
///
/// 为什么值得单独一个接口：`DA269` 当时一刀切把三行全藏了，用户看到的是
/// "兜底引擎上连位置都调不了"，而实际上 mpv 完全支持 —— 藏起来不是"诚实"，
/// 是**少给了一半**。现在只藏真正插不上手的那一项（字号）。
abstract class MediaPlayerSubtitleStyling {
  /// 把"垂直偏移（逻辑像素，正值向上）+ 背景条"交给引擎。
  ///
  /// 实现方**不许抛**：调样式失败不能影响播放（最多是这一项没生效）。
  Future<void> setSubtitleStyle({required int offsetPx, required bool background});
}

/// DSM `106`（`sessionTimeout`）的**错误码上下文**匹配。
///
/// 只认 `"code":106` / `code=106` / `error 106` 这类"码"的形态，避免把
/// `position=106000` 或 `size=106` 误判成会话失效。
final RegExp _dsmCode106 = RegExp(r'(code|error)[\s"=:]*106\b');

/// **带上下文的 HTTP 状态码**（`http=404` / `status: 500` / `HTTP 403`）。
///
/// 只认"码"的形态，不认裸数字：`position=404000` / `size=404` 这类位置与字节数
/// 不许被当成"服务端拒绝"（与 [_dsmCode106]、看门狗"错误串不放数字"同一个教训）。
/// 401/403 在前面已被判成 `sessionExpired`，这里主要吃 4xx/5xx 的其它码。
final RegExp _httpStatusCode = RegExp(
  r'(http|status|response)[\s"=:]*[45]\d\d\b',
);

/// 播放器给的错误 → 失败原因。
///
/// 这里**只能**按错误文本粗分类（异常消息是平台侧给的字符串，没有结构化错误码；
/// `MediaSource` 层的"空 URL / 隧道 / Range / 证书固定 / 缺鉴权"那些判断仍然是
/// **枚举**，不靠字符串）。分类只影响**显示哪句话**，不影响"要不要回退到系统应用"。
///
/// 平台侧实际会出现的串（真机 + Media3 `PlaybackException.errorCodeName`）：
///   * `119`（SID 不存在）/ `106`（会话超时）/ `_sid` / `session` / `login` /
///     `401` / `403` / `csrf` → [MediaUnavailableReason.sessionExpired]
///     （会话没了，重新登录即可）；
///   * `ERROR_CODE_IO_NETWORK_CONNECTION_FAILED` / `timeout` / `UnknownHost` →
///     [MediaUnavailableReason.networkFailed]；
///   * `ERROR_CODE_IO_BAD_HTTP_STATUS` / `IO_FILE_NOT_FOUND` /
///     `IO_INVALID_HTTP_CONTENT_TYPE` / `PARSING_CONTAINER_*` /
///     `InvalidResponseCodeException` / `http=404` / `status: 500` →
///     [MediaUnavailableReason.streamRejected]（**服务端明确拒绝取流** ——
///     与"解码器不支持"和"网络连不上"都不是一回事，处置方式也不同）；
///   * `ERROR_CODE_DECODING_FORMAT_UNSUPPORTED` / `V_THEORA is not supported` /
///     `Decoder init failed` → [MediaUnavailableReason.codecUnsupported]；
///   * `Trust anchor` / `SSL handshake` / `CertPathValidatorException` →
///     [MediaUnavailableReason.certificateUntrusted]；
///   * 其它（含 null、以及 `UnrecognizedInputFormatException` /
///     `None of the available extractors…` 这种"响应不像媒体"的兜底）→
///     [MediaUnavailableReason.decodeFailed]。
///
/// ⚠️ 为什么 `UnrecognizedInputFormatException` **不再**算
/// [MediaUnavailableReason.codecUnsupported]：服务端对"缺 `_sid`/`SynoToken` 的
/// 下载 URL"回的是 HTTP 200 + JSON `{"error":{"code":119}}`，Media3 嗅探这段
/// JSON 必然失败并抛这个异常 —— 它和"容器/编码真的解不了"**在文本上完全一样**。
/// 把这种模糊失败说成"系统解码器不支持这个文件的编码"就是真机上的头号误报；
/// 取流鉴权问题已由 `media_source.dart` 的查询串自检在**进播放器之前**拦成
/// [MediaUnavailableReason.sessionExpired]，所以这里退回中性的"播放失败"。
///
/// ⚠️ 与"网络中断"的区分就是这一层：只有本函数判成
/// [MediaUnavailableReason.sessionExpired] 的失败才会被 `shouldRenewSession`
/// 拿去**自动续期续播**；[MediaUnavailableReason.networkFailed] 仍走既有网络提示。
MediaUnavailableReason classifyPlayerError(Object? error) {
  // ★ 先按**类型**判（第 156 轮 Linux 站）：`MissingPluginException` 的文本里
  //   没有任何指向"平台未实现"的词，只按文本判必然落到兜底的 `decodeFailed`
  //   ⇒ 把平台结论说成文件结论。类型判据在文本判据**之前**，且不影响其它分支。
  if (error is MediaPlaybackUnsupportedOnHost) {
    return MediaUnavailableReason.platformUnsupported;
  }
  // ★ r690（Linux 站）：**解码成功、画面没来**（mpv 纹理建不起来）与"平台没实现"
  //   和"文件解不了"都不同 —— 前面两条都试过了才会到这里，所以按**类型**先判。
  if (error is MediaPlaybackVideoOutputUnavailable) {
    return MediaUnavailableReason.videoOutputUnavailable;
  }
  final text = '$error'.toLowerCase();
  if (text.isEmpty || text == 'null') {
    return MediaUnavailableReason.decodeFailed;
  }
  if (text.contains('cert') ||
      text.contains('ssl') ||
      text.contains('tls') ||
      text.contains('trust anchor') ||
      text.contains('handshake') ||
      text.contains('certpath')) {
    return MediaUnavailableReason.certificateUntrusted;
  }
  // 会话/鉴权：DSM 的 119（SID 不存在）/ 106（会话超时）、CSRF 缺失、或
  // HTTP 401/403。顺序在"编码"之前：这些错也可能带 `unsupported` 之类的词。
  if (text.contains('_sid') ||
      text.contains('sid not found') ||
      text.contains('sidnotfound') ||
      text.contains('session') ||
      text.contains('login') ||
      text.contains('unauthorized') ||
      text.contains('csrf') ||
      text.contains('synotoken') ||
      text.contains('119') ||
      text.contains('401') ||
      text.contains('403') ||
      // `106`（DSM `sessionTimeout`）只在**错误码上下文**里认：裸 `106` 会被
      // 位置/时长/字节数误伤（与看门狗"错误串不放数字"同一个教训）。
      _dsmCode106.hasMatch(text)) {
    return MediaUnavailableReason.sessionExpired;
  }
  // 编码/解码器：**只认真正的解码器证据**（`V_THEORA is not supported`、
  // `ERROR_CODE_DECODING_FORMAT_UNSUPPORTED`、`Decoder init failed`…）。
  // `recognizedinputformat` / `no suitable` / 泛化的 `unsupported` 不再进这里
  // —— 它们和"响应根本不是媒体"（取流被拒）无法区分，见上面的说明。
  if (text.contains('decod') ||
      text.contains('codec') ||
      text.contains('not supported') ||
      text.contains('theora') ||
      text.contains('format_unsupported') ||
      text.contains('mediacodec') ||
      // ★ r676（`DA307`）：AVFoundation 的 `AVErrorFileFormatNotRecognized`
      //   （`-11828`，iOS 上 `.mkv` 实测就是这个）。它是**格式/容器**证据，
      //   不是会话失效、也不是网络 —— 归到这里才能给"系统解码器解不了"的说明。
      text.contains('-11828') ||
      text.contains('fileformatnotrecognized')) {
    return MediaUnavailableReason.codecUnsupported;
  }
  // **取流层失败**（HTTP 明确拒绝 / 响应不是媒体）：只认**结构化的 HTTP 证据**
  // —— Media3 的 `ERROR_CODE_IO_BAD_HTTP_STATUS` / `IO_FILE_NOT_FOUND` /
  // `IO_INVALID_HTTP_CONTENT_TYPE` / `IO_NO_PERMISSION` / `PARSING_*`，以及
  // `HttpDataSource$InvalidResponseCodeException`（它 `public final int responseCode`
  // + `headerFields` + `responseBody`，原生桥会把状态码/内容类型/长度/正文种类
  // 摘要进错误串，见 `MediaPlayerBridge.describePlaybackError`）。
  //
  // ⚠️ 必须排在 [MediaUnavailableReason.networkFailed] **前面**：网络那条的
  // `io_` 子串会把 `ERROR_CODE_IO_BAD_HTTP_STATUS` 一并吃掉（真机 R5 的相册
  // 取流失败就是这一类，被说成"网络中断"会指错方向）。
  if (text.contains('bad_http_status') ||
      text.contains('invalidresponsecode') ||
      text.contains('invalid_http_content_type') ||
      text.contains('io_no_permission') ||
      text.contains('file_not_found') ||
      text.contains('parsing_container') ||
      text.contains('parsing_manifest') ||
      text.contains('stream_rejected') ||
      _httpStatusCode.hasMatch(text)) {
    return MediaUnavailableReason.streamRejected;
  }
  if (text.contains('network') ||
      text.contains('timeout') ||
      text.contains('timed out') ||
      text.contains('connect') ||
      text.contains('socket') ||
      text.contains('unreachable') ||
      text.contains('unknownhost') ||
      text.contains('host') ||
      text.contains('econnrefused') ||
      text.contains('io_') ||
      text.contains('404')) {
    return MediaUnavailableReason.networkFailed;
  }
  return MediaUnavailableReason.decodeFailed;
}
