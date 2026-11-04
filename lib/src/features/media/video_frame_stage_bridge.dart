// 抽帧的**分层失败**桥（第 267 轮）。
//
// ## 为什么要在 `core/media/video_frame_bridge.dart` 之外再开一个
// 老的 `VideoFrameExtractor.extract()` 契约是「成功给图 / 失败给 null」，
// `lib/src/core/**` 那一层已经稳定（其它批次也依赖它）。但 null **说不清
// 是哪一段挂了**：容器认不出？没有视频轨？编码失败？于是真机上只能看到
// 一个"摄像机不可用"图标，工程师也只能翻 logcat。
//
// 第 267 轮在原生侧加了 `extractFrameEx`（**失败也回 Map**，带
// `stage`/`container`/`videoFourcc`/`errorClass`/`error`）。本文件是它与 Dart
// 世界之间的薄封装，**放在 `features/media/`**，不回改 `core/media` 的老契约。
//
// ## 事实来源
// 真机 `Honor LGE-AN10`（Android 12）实测的 `/home/Video/60招基础街球S01E01.AVI`
// 回包等价于：
//   `stage=open`、`container=riff/avi`、`videoFourcc=FMP4`
// （`err=IllegalArgumentException: couldn't open …`）
// 原因是**本机平台 `MediaExtractor` 没有 RIFF/AVI 解析器**（`dumpsys media.extractor`
// 的 12 个 extractor 里没有 AVI），**不是**"没有 `idx1`"、也不是"编码不支持"
// （该文件编码是 `FMP4` = MPEG-4 Part 2，本机有 `c2.android.mpeg4.decoder`）。
// 完整取证 → `docs/device-verification.md §⑩.7`、`docs/thumbnail-apis.md §7`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform/app_platform.dart';
import '../../core/media/video_frame_bridge.dart'
    show kVideoFrameChannel, kVideoFrameDefaultMaxWidth;

/// 抽帧失败发生在**哪一段**（与 `VideoFrameBridge.kt` 的 `stage=` 逐字对应）。
enum VideoFrameStage {
  /// 成功（只在 [VideoFrameStageResult.failure] 为 null 时出现）
  ok,

  /// `MediaMetadataRetriever.setDataSource` 抛了 —— **平台认不出这个容器**
  /// （真机实测 RIFF/AVI 没有解析器），或片段不完整（头部没有 `moov`）。
  open,

  /// 容器开了但取不到帧：没有视频轨 / 无关键帧 / 解码器不支持。
  frame,

  /// 帧有了但 JPEG 编码失败。
  encode,

  /// ★ 第 269 轮：自研 AVI 走查失败（不是 AVI / 没有 `movi` / 没有视频轨 / 脏 size）。
  aviParse,

  /// ★ 第 269 轮：AVI 头解出来了，但**关键帧不在给到的头部窗口里**（我们只下 6 MiB）。
  aviKeyframe,

  /// ★ 第 269 轮：AVI 容器解出来了，但 **fourcc 不认识 / 本机没有对应解码器**。
  /// 这与 [open]（容器不支持）是**两件事**，别混。
  aviCodec,

  /// ★ 第 269 轮：解码器在，但喂进去没出帧（超时 / EOS / YUV 格式不支持）。
  aviDecode,

  /// 其它异常（原生侧 `runCatching` 不再吞掉）。
  unexpected,

  /// 原生没给 / 老构建没这个方法 / 通道缺席 —— **"不知道"，不是"失败原因=unknown"**。
  unknown;

  /// 机器可读名字（日志用，**别翻译**）。
  String get key => switch (this) {
    VideoFrameStage.ok => 'ok',
    VideoFrameStage.open => 'open',
    VideoFrameStage.frame => 'frame',
    VideoFrameStage.encode => 'encode',
    VideoFrameStage.aviParse => 'avi-parse',
    VideoFrameStage.aviKeyframe => 'avi-keyframe',
    VideoFrameStage.aviCodec => 'avi-codec',
    VideoFrameStage.aviDecode => 'avi-decode',
    VideoFrameStage.unexpected => 'unexpected',
    VideoFrameStage.unknown => 'unknown',
  };

  static VideoFrameStage parse(Object? raw) => switch (raw) {
    'ok' => VideoFrameStage.ok,
    'open' => VideoFrameStage.open,
    'frame' => VideoFrameStage.frame,
    'encode' => VideoFrameStage.encode,
    'avi-parse' => VideoFrameStage.aviParse,
    'avi-keyframe' => VideoFrameStage.aviKeyframe,
    'avi-codec' => VideoFrameStage.aviCodec,
    'avi-decode' => VideoFrameStage.aviDecode,
    'unexpected' => VideoFrameStage.unexpected,
    _ => VideoFrameStage.unknown,
  };
}

/// 一次抽帧失败的**平台侧现场**。
@immutable
class VideoFrameExtractionFailure {
  const VideoFrameExtractionFailure({
    required this.stage,
    this.container = '',
    this.videoFourcc = '',
    this.errorClass = '',
    this.error = '',
    this.hasVideo = '',
    this.width = '',
    this.height = '',
    this.reason = '',
    this.codecMime = '',
    this.via = '',
    this.moviOffset = 0,
    this.chunkOffset = 0,
    this.chunkSize = 0,
    this.esFrames = 0,
    this.esBytes = 0,
    this.scannedChunks = 0,
  });

  /// 卡在哪一段
  final VideoFrameStage stage;

  /// 容器（原生**只看文件头字节**嗅探）：`riff/avi` / `iso-bmff` / `ebml` /
  /// `asf` / `ogg` / `flv` / `mpeg-ts` / `mpeg-ps` / `riff` / `unknown`
  final String container;

  /// AVI 时从 `strf.biCompression` 读出的视频 fourcc（如 `FMP4`/`XVID`/`MJPG`）
  final String videoFourcc;

  /// 异常类名 + 消息（**仅用于日志与诊断**，不进用户界面）
  final String errorClass;
  final String error;

  /// `stage=frame` 时的现场（原生 `METADATA_KEY_HAS_VIDEO` 等，原样字符串）
  final String hasVideo;
  final String width;
  final String height;

  /// ★ 第 269 轮：原生给的**机器可读原因**（`fourcc-unsupported:FMP4` /
  /// `keyframe-outside-window:scanned=..` / `decoder-unavailable:video/mjpeg` …）。
  /// 老构建 / 非 AVI 路径为空串（`''` = "平台没给"，不是"原因叫空"）。
  final String reason;

  /// ★ 第 269 轮：fourcc 映射到的平台解码器 MIME（`video/mp4v-es`…）；映射不出为空
  final String codecMime;

  /// ★ 第 269 轮：**哪条路出的结果** —— `avi-fallback` = 自研 AVI 走查 + 平台解码；
  /// 空 = 平台 `MediaMetadataRetriever` 老路径 / 平台没给。
  final String via;

  /// ★ 第 269 轮：自研 AVI 走查的现场（诊断用；非 AVI 全 0）。
  final int moviOffset;
  final int chunkOffset;
  final int chunkSize;
  final int esFrames;
  final int esBytes;
  final int scannedChunks;

  /// `stage=open` ＝ **这个容器本机平台解析不了**（AVI/RIFF 就是这一档）。
  bool get containerNotSupported => stage == VideoFrameStage.open;

  /// 自研 AVI 路径**真的被用过**（成功或失败都算；成功由
  /// [VideoFrameStageResult.via] 给出）。
  bool get aviFallbackUsed => via == 'avi-fallback';

  /// **容器解出来了，卡在编码**（fourcc 不认识 / 本机没解码器）—— 与
  /// [containerNotSupported] 是两件事，文案也不许互相借用。
  bool get codecUnsupported => stage == VideoFrameStage.aviCodec;

  static int _i(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// 把原生回包解成失败现场；**不是失败**（有图 / 不是 Map）→ null（绝不抛）。
  static VideoFrameExtractionFailure? fromPlatform(Object? raw) {
    if (raw is! Map) return null;
    final stage = VideoFrameStage.parse(raw['stage']);
    if (stage == VideoFrameStage.ok) return null;
    String s(Object? v) => v is String ? v : (v == null ? '' : '$v');
    return VideoFrameExtractionFailure(
      stage: stage,
      container: s(raw['container']),
      videoFourcc: s(raw['videoFourcc']),
      errorClass: s(raw['errorClass']),
      error: s(raw['error']),
      hasVideo: s(raw['hasVideo']),
      width: s(raw['w']),
      height: s(raw['h']),
      // 只认自研 AVI 路径那条**机器可读**原因；stage=open 的异常消息继续走
      // `error`/`errorClass`，不重复进 `reason=`（保持老日志形状干净）。
      reason: s(raw['aviReason']),
      codecMime: s(raw['codecMime']),
      via: s(raw['via']),
      moviOffset: _i(raw['aviMoviOffset']),
      chunkOffset: _i(raw['aviChunkOffset']),
      chunkSize: _i(raw['aviChunkSize']),
      esFrames: _i(raw['aviEsFrames']),
      esBytes: _i(raw['aviEsBytes']),
      scannedChunks: _i(raw['aviScannedChunks']),
    );
  }

  @override
  String toString() =>
      'VideoFrameExtractionFailure(stage=${stage.key}, container=$container, '
      'videoFourcc=$videoFourcc, mime=$codecMime, reason=$reason, '
      'err=$errorClass${error.isEmpty ? '' : ': $error'})';
}

/// 带分层的抽帧结果：**要么有图，要么有失败现场**（也可能两者都空 = 通道缺席）。
@immutable
class VideoFrameStageResult {
  const VideoFrameStageResult({
    this.bytes,
    this.mime = 'image/jpeg',
    this.width = 0,
    this.height = 0,
    this.failure,
    this.via = '',
  });

  final Uint8List? bytes;
  final String mime;
  final int width;
  final int height;

  /// null = 这一路没给出失败现场（老契约路径 / 通道缺席）
  final VideoFrameExtractionFailure? failure;

  /// ★ 第 269 轮：`avi-fallback` = 这一帧是**自研 AVI 走查 + 平台解码**出的；
  /// 空 = 平台 `MediaMetadataRetriever` 老路径 / 原生没给。
  final String via;

  bool get hasBytes => bytes != null && bytes!.isNotEmpty;

  /// 这一帧是否来自自研 AVI 路径
  bool get viaAviFallback => via == 'avi-fallback';

  static VideoFrameStageResult? fromPlatform(Object? raw) {
    if (raw is! Map) return null;
    final bytes = raw['bytes'];
    final mime = raw['mime'];
    final width = raw['width'];
    final height = raw['height'];
    final via = raw['via'];
    final ok = bytes is Uint8List && bytes.isNotEmpty;
    return VideoFrameStageResult(
      bytes: ok ? bytes : null,
      mime: (mime is String && mime.isNotEmpty) ? mime : 'image/jpeg',
      width: width is int ? width : 0,
      height: height is int ? height : 0,
      via: (via is String) ? via : '',
      failure: ok ? null : VideoFrameExtractionFailure.fromPlatform(raw),
    );
  }

  @override
  String toString() => hasBytes
      ? 'VideoFrameStageResult(${bytes!.length}B, ${width}x$height'
            '${via.isEmpty ? '' : ', via=$via'})'
      : 'VideoFrameStageResult(failure=$failure)';
}

/// 分层抽帧能力（**接口注入**：测试不许依赖 Android 运行时）。
abstract class VideoFrameStageExtractor {
  /// 抽一帧并带上失败分层。
  ///
  /// 返回 null = **这条路问不出来**（非 Android / 通道缺席 / 老构建）——
  /// 与"问了、失败了"（返回带 [VideoFrameStageResult.failure] 的结果）**必须区分**。
  Future<VideoFrameStageResult?> extractDetailed(
    String localPath, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  });

  /// 本机有没有这个桥。
  Future<bool> isSupported();
}

/// ★ 第 41 轮：**URL 模式**抽帧（本地回环代理把 Range 转发到 NAS）。
///
/// 为什么需要它：原来只把 **6 MB 头部**写成本地文件喂解析器，真机实测
/// `AVI/MKV/238MB mp4` 都只能解出**黑场**（luma=0/1，帧只有 1.4–2 KB），
/// 而 13 MB mp4 是 25 KB 的真帧（luma=223）。半截文件对"索引在尾部/首帧数据靠后"
/// 的容器天然无解 ⇒ 改成让原生按需发 Range 取**真实数据**。
///
/// 单独一个接口（而不是塞进 [VideoFrameStageExtractor]）是为了
/// **不破坏既有测试桩**：`implements` 不继承默认实现，加成员会让老桩编译不过。
abstract class VideoFrameUrlStageExtractor {
  /// 抽一帧（失败也回分层原因）。返回 null = 这条路问不出来。
  Future<VideoFrameStageResult?> extractDetailedUrl(
    String url,
    Map<String, String> headers, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  });
}

/// ★ 第 42 轮：**media3 离屏播放器**抽帧（`extractFramePlayer`）。
///
/// 为什么还要这一条：平台 `MediaMetadataRetriever` 对部分码流**回黑图而不是报错**
/// （真机实测：AVI 1415B/luma=1、4.4GB MKV 1990B/luma=0、238MB mp4 5018B/luma=1）；
/// 而 media3 是 App **播放**用的同一套栈 ⇒ "能播就能抽"。真机对照：
/// AVI luma 1→103、4.4GB MKV luma 0→59（都是真帧）。
abstract class VideoFramePlayerStageExtractor {
  Future<VideoFrameStageResult?> extractFrameViaPlayer(
    String url,
    Map<String, String> headers, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
    bool skipBlack = true,
  });
}

/// 真机实现：`synhub/video_frame` 通道的 `extractFrameEx`。
class MethodChannelVideoFrameStageExtractor
    implements
        VideoFrameStageExtractor,
        VideoFrameUrlStageExtractor,
        VideoFramePlayerStageExtractor {
  const MethodChannelVideoFrameStageExtractor({
    this.channel = const MethodChannel(kVideoFrameChannel),
  });

  final MethodChannel channel;

  /// 单测里把"是否 Android"这一关打开（宿主上跑不了真平台通道）。
  @visibleForTesting
  static bool debugForceAndroid = false;

  /// 与 `core/media/video_frame_bridge.dart` **同一口径**：宿主上直接返回 null，
  /// 不去打一个注定 `MissingPluginException` 的通道。
  ///
  /// ★★ **能力门必须用 `capabilityGateAllows`，不能用 `canUse`**（第 76 轮真机回归）：
  /// `canUse` = `capabilities.can` = **只有 `available` 才为 true**；Android 上
  /// `videoFrameExtraction` 的静态结论是 `unknown`（桥在不在要问了才知道），
  /// 且 `AppPlatformCapabilities.current()` 是**工厂**（每次按宿主重算静态表、
  /// 不读任何探测结果）⇒ 真机上该判定**恒为 false** ⇒ 三条抽帧路
  /// （`extractDetailed` / `extractDetailedUrl` / `extractFrameViaPlayer`）
  /// **连通道都不碰**就返回 null ⇒ 视频行只剩图标、`cache/video_frames/` 永远空。
  /// 根因/取证与姊妹文件一致，见 `core/media/video_frame_bridge.dart` 的同名注释。
  ///
  /// `capabilityGateAllows` = `mayTry`：**只有"确定不能"才拦**，`unknown` 与
  /// `available` 都放行 ⇒ Android 去试桥；macOS/iOS/Linux/Windows
  /// （静态 `unavailable:not-implemented-on-host`）照旧不碰通道。
  /// ★ r707：与 `video_frame_bridge.dart` 同款 —— **宿主也要钉 Android**，
  /// 否则 Windows 能力位翻开后会把 `extractFrameEx` 打到不存在的 Kotlin 通道上。
  static bool get _isAndroid =>
      debugForceAndroid ||
      (AppPlatformCapabilities.current().host == AppHost.android &&
          capabilityGateAllows(AppCapability.videoFrameExtraction));

  @override
  Future<bool> isSupported() async {
    if (!_isAndroid) return false;
    try {
      return await channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<VideoFrameStageResult?> extractDetailed(
    String localPath, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  }) async {
    if (!_isAndroid) return null;
    if (localPath.isEmpty) return null;
    try {
      final raw = await channel.invokeMethod<Object?>('extractFrameEx', {
        'path': localPath,
        'atMs': atMs,
        'maxWidth': maxWidth,
      });
      return VideoFrameStageResult.fromPlatform(raw);
    } on PlatformException {
      // 老构建没注册 `extractFrameEx` ⇒ 问不出来（**不是**"失败原因是 unknown"）
      return null;
    } catch (_) {
      return null;
    }
  }
  /// ★ 第 41 轮：URL 模式（同一条 `extractFrameEx`，多传 `url`/`headers`）。
  @override
  Future<VideoFrameStageResult?> extractDetailedUrl(
    String url,
    Map<String, String> headers, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  }) async {
    if (!_isAndroid) return null;
    if (url.isEmpty) return null;
    try {
      final raw = await channel.invokeMethod<Object?>('extractFrameEx', {
        'url': url,
        'headers': headers,
        'atMs': atMs,
        'maxWidth': maxWidth,
      });
      return VideoFrameStageResult.fromPlatform(raw);
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// ★ 第 42 轮：media3 离屏播放器抽帧（数据源走本地回环代理，不碰 TLS）。
  @override
  Future<VideoFrameStageResult?> extractFrameViaPlayer(
    String url,
    Map<String, String> headers, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
    bool skipBlack = true,
  }) async {
    if (!_isAndroid) return null;
    if (url.isEmpty) return null;
    try {
      final raw = await channel.invokeMethod<Object?>('extractFramePlayer', {
        'url': url,
        'headers': headers,
        'atMs': atMs,
        'maxWidth': maxWidth,
        'skipBlack': skipBlack,
      });
      return VideoFrameStageResult.fromPlatform(raw);
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

}
