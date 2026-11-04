// 视频**首帧缩略图**：下载头部片段 → 原生抽帧 → 落盘缓存的接线层（第 261 轮）。
//
// ## 为什么要有这一层
// 真 NAS 只读实测（`docs/thumbnail-apis.md`）证明**服务端没有视频缩略图**：
// `SYNO.FileStation.Thumb` 对视频恒 `404 + 11939B HTML`、Drive `get_thumbnail`
// 对视频恒 `400 + 0 字节`、`SYNO.Office.Video.Thumb` 也出不了图，本机又没有
// VideoStation。用户裁决：「**服务端优先，失败再自研抽帧**」。本文件就是
// "失败再自研抽帧"这一半：**结果是本机缓存的图片**，不是每次重抽。
//
// ## 四段流水线
//   ① **下载头部片段**：走 App 自己的 Dio/传输层（已按 §2.0.11 放宽自签证书），
//      `Range: bytes=0-<cap-1>`，**上限 [kVideoFrameHeadBytes]（6 MiB）**；
//      服务端不支持 Range（Drive 写死 `Accept-Ranges: none`）时退化为"整份下但设上限"
//      —— 文件比上限大、**或大小未知**，一律直接判"做不了"（见
//      [videoFrameThumbSupported]：宁可不出图，也不赌一个 4.7 GB 的 MKV）；
//   ② **写临时文件**：`<temp>/video_frame_tmp/<hash>.bin`（原生只吃本地路径）；
//   ③ **原生抽帧**：`android.media.MediaMetadataRetriever`（`VideoFrameBridge.kt`），
//      返回 **JPEG** 字节；抽完**立刻删临时文件**（finally）；
//   ④ **缓存**：内存 LRU（[kVideoFrameMemoryBytes]）+ 磁盘 LRU（[kVideoFrameDiskBytes]）
//      + 失败记忆（[kVideoFrameNegativeTtl]）+ 限流（[kVideoFrameMaxConcurrent]=2）
//      + 合流（同一键并发只下一次）+ 可取消。
//
// ## 缓存键（**必须含 mtime + size**）
//   * 文件系统：`vframe|<path>|<mtime>|<size>`（[videoFrameCacheKey]）；
//   * Drive：`vframe|id:<file_id>|<version>|<size>`。
// 不含 mtime/size 就会"同名文件被覆盖后仍用旧图"——`test/video_frame_thumb_test.dart`
// 里有一条**反向验证**用例专门钉这件事（用不含 mtime 的键 ⇒ 覆盖后命中旧图 ⇒ 失败）。
//
// ## 取消语义
// `autoDispose` provider 被回收（列表滚出去）时调 [VideoFrameThumbCache.cancel]；
// 排队中的请求在拿到并发名额后**先查取消**，取消了就**不下载**（[stats].cancelled++），
// 也**不写失败记忆**（取消不是失败）。
//
// ## 磁盘缓存目录
// `<应用缓存目录>/video_frames/`。**故意不在 `chat_cache/` 里**（那个目录是
// 聊天附件自己的作用域），但**已并进设置页「清理已下载的文件」的作用域**：
// ★ 第 425 轮（`DA83`）把它登记进了 `CacheService` 的
// `kRegenerableCacheDirs` —— 真机读数证明不登记时设置页会显示"已用 5.3 MB"
// 而 `cache/` 实际 ≈17 MB，且对话框写的是"所有…缩略图"却清不掉视频首帧。
// 现在**用量统计 / 清理 / 上限淘汰**都会连它一起算（它自己的
// `_enforceDiskLimit` 仍按 `.vframe` 总字节兜底，两者都按 mtime 最旧先删）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/media/mpv_video_frame_extractor.dart';
import '../../core/media/video_frame_bridge.dart';
import '../../core/platform/app_platform.dart'
    show
        AppCapability,
        AppHost,
        AppPlatformCapabilities,
        capabilityGateAllows;
import '../../data/dto/file_entry_dto.dart';
import '../../core/net/traffic_meter.dart';
import '../../dsm/webapi.dart' show DownloadCancelToken;
import '../servers/session_controller.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'media_cover.dart' show normalizeMediaExtension;
import 'media_source.dart' show MediaKind, MediaSource;
import 'video_frame_stage_bridge.dart';
import '../../core/media/media_key_hash.dart';

// ============================================================ 常量（容量/上限）

/// 交给原生抽帧的**文件头部字节上限**：6 MiB。
///
/// 为什么是 6 MiB：手机拍的 1080p H.264 mp4 头部 6 MiB 已覆盖 `ftyp+moov+` 好几个
/// GOP；再大只是白烧流量（每多 1 MiB 就是列表滚动里一次额外的移动网络请求）。
/// 上限同时也是"**绝不为了列表里一张缩略图把整个视频下下来**"的硬闸门。
const int kVideoFrameHeadBytes = 6 * 1024 * 1024;

/// 内存 LRU 上限：8 MiB（一张 320px JPEG 约 10–30 KB ⇒ 约 300–800 张）。
const int kVideoFrameMemoryBytes = 8 * 1024 * 1024;

/// 磁盘 LRU 上限：32 MiB（App 缓存目录，可再生；超出按"最久未用"淘汰）。
const int kVideoFrameDiskBytes = 32 * 1024 * 1024;

/// 同时在飞的任务上限：**2**（串行太慢、放开又会几十个视频一起抢解码器）。
const int kVideoFrameMaxConcurrent = 2;

/// 失败记忆时长：10 分钟（滚动列表里同一个视频别反复重下 6 MB）。
const Duration kVideoFrameNegativeTtl = Duration(minutes: 10);

/// 抽帧目标宽度（原生再按等比缩；见 `kVideoFrameDefaultMaxWidth`）。
const int kVideoFrameThumbMaxWidth = kVideoFrameDefaultMaxWidth;

/// 容器白名单：这些后缀才值得交给自己抽帧。
///
/// 覆盖 Android `MediaMetadataRetriever` 常规支持的容器；**故意不含**
/// 图片/文档后缀（那些有别的通道），也不含 `rm`/`rmvb` 之外的冷门封装。
const Set<String> kVideoFrameContainers = {
  'mp4',
  'm4v',
  'mov',
  'mkv',
  'webm',
  'avi',
  '3gp',
  '3g2',
  'ts',
  'm2ts',
  'mts',
  'flv',
  'wmv',
  'asf',
  'mpg',
  'mpeg',
  'm2v',
  'vob',
  'ogv',
  'divx',
};

// ============================================================ 失败分层（第 267 轮）
//
// ⚠️ 先读 `docs/device-verification.md §⑩.7`：真机上那条 183 MB AVI 抽不出帧，
// **不是**"没有 `idx1`"（该文件尾部有完整的 61,987 条 `idx1`），也**不是**
// "编码不支持"（`FMP4` = MPEG-4 Part 2，本机有 `c2.android.mpeg4.decoder`），
// 而是**本机平台的 `MediaExtractor` 没有 RIFF/AVI 解析器**
// （`dumpsys media.extractor` 的 12 个 extractor 里没有 AVI）。
// 所以这里的措辞一律围绕**容器**，不许写成"编码不支持"。

/// 后缀 → **平台容器家族**（本地先验，只用于日志与原因键的兜底）。
///
/// ⚠️ 这**只是先验**：真正的容器由原生按**文件头字节**嗅探
/// （[VideoFrameExtractionFailure.container]）。两者不一致时**以原生为准**
/// —— 例如后缀是 `.avi` 而文件里其实装的是 ASF。
String videoFrameContainerFamily(String extension) {
  switch (normalizeMediaExtension(extension)) {
    case 'avi':
    case 'divx':
      return 'riff-avi';
    case 'mp4':
    case 'm4v':
    case 'mov':
    case '3gp':
    case '3g2':
      return 'iso-bmff';
    case 'mkv':
    case 'webm':
      return 'ebml';
    case 'wmv':
    case 'asf':
      return 'asf';
    case 'mpg':
    case 'mpeg':
    case 'm2v':
    case 'vob':
      return 'mpeg-ps';
    case 'ts':
    case 'm2ts':
    case 'mts':
      return 'mpeg-ts';
    case 'ogv':
      return 'ogg';
    case 'flv':
      return 'flv';
    default:
      return 'other';
  }
}

/// 容器名**归一**：原生嗅探给的是 `riff/avi`（带斜杠，形如 `riff/<form>`），
/// 后缀先验给的是 `riff-avi`。两种写法必须收敛成**同一个原因键**，
/// 否则同一个容器会漂出两个键（日志、用例、缓存诊断都会跟着漂）。
String videoFrameContainerKey(String container) =>
    container == 'riff/avi' ? 'riff-avi' : container;

// ============================================================ 自研 AVI fallback（第 269 轮）
//
// 平台 `MediaExtractor` **没有** RIFF/AVI 解析器（真机 `dumpsys media.extractor` 逐字
// 无 AVI），但**解码器在**（`c2.android.mpeg4.decoder`）⇒ 「缺的只是容器解析」。
// 原生侧 `AviFirstFrame.kt` 自己走 RIFF、把裸 ES 喂给平台 `MediaCodec`。
// 下面这些纯函数/常量是它的**离线镜像**：把"闸门规则 / 上限 / fourcc→MIME"变成
// 不依赖设备就能钉死的契约（`test/video_frame_avi_fallback_test.dart`）。

/// ★ **自研 AVI fallback 的容器闸门**（原生 `VideoFrameBridge.AVI_CONTAINER` 的镜像）。
///
/// 只有 `riff/avi`（后缀先验的 `riff-avi` 也归一到这里）为真 ——
/// **MP4/MKV/TS/… 一律 false** ⇒ 平台能开的文件绝不会进自研路径（快路径零影响）。
bool aviFallbackApplies(String container) =>
    videoFrameContainerKey(container) == 'riff-avi';

/// 原生走查的**硬上限**（与 `AviFirstFrame.kt` 逐字对应）。
///
/// * [kAviMaxScanChunks]：RIFF 块遍历防死循环；
/// * [kAviMaxEsFrames] / [kAviMaxEsBytes]：交给解码器的视频块数/字节上限
///   （只够出第一帧，绝不把整段 GOP 灌进去）。
const int kAviMaxScanChunks = 4096;
const int kAviMaxEsFrames = 64;
const int kAviMaxEsBytes = 2 * 1024 * 1024;

/// AVI fourcc → 平台解码器 MIME（**原生那张表的离线镜像**）。
///
/// 判据是"**这个平台有没有把握解**"，不是"能不能播"：不认识就空串 ⇒ 原因键
/// `avi-codec-unsupported:<fourcc>`，**绝不猜**一个 MIME。
/// 映射为空时**不是**"容器不支持"，文案不许借用 [VideoFrameThumbFailure.containerNotSupported]。
const Map<String, String> kAviFourccMime = {
  // MPEG-4 Part 2（DivX/XviD 家族）—— 真机有 c2.android.mpeg4.decoder
  'FMP4': 'video/mp4v-es',
  'XVID': 'video/mp4v-es',
  'DIVX': 'video/mp4v-es',
  'DX50': 'video/mp4v-es',
  'MP4V': 'video/mp4v-es',
  'MP4S': 'video/mp4v-es',
  'M4S2': 'video/mp4v-es',
  '3IV2': 'video/mp4v-es',
  // Motion JPEG
  'MJPG': 'video/mjpeg',
  'MJPEG': 'video/mjpeg',
  // H.264 / AVC（AVI 里一般是 Annex-B，首块自带 SPS/PPS）
  'H264': 'video/avc',
  'X264': 'video/avc',
  'AVC1': 'video/avc',
  'H26L': 'video/avc',
  'DAVC': 'video/avc',
  // H.265 / HEVC
  'H265': 'video/hevc',
  'X265': 'video/hevc',
  'HEVC': 'video/hevc',
  'HVC1': 'video/hevc',
  'HEV1': 'video/hevc',
};

/// fourcc → MIME；大小写不敏感、两端空白容错；不认识回 `''`（纯函数）。
String aviFourccMime(String fourcc) =>
    kAviFourccMime[fourcc.trim().toUpperCase()] ?? '';

/// **关键帧是否在给到的头部窗口内**（纯函数；与原生走查同口径）。
///
/// 我们永远只下头部 ≤ [kVideoFrameHeadBytes]；关键帧落在窗口外是**合法失败**
/// （AGENTS §2.0.17 ④：不许把"只读头部 N 字节"当事实）⇒ 原生给
/// `avi-keyframe` + `keyframe-outside-window:*`，**不**要求再下整份 191 MB。
bool aviKeyframeInsideWindow({
  required int chunkOffset,
  required int chunkSize,
  int windowBytes = kVideoFrameHeadBytes,
}) =>
    chunkOffset >= 0 &&
    chunkSize > 0 &&
    chunkOffset + chunkSize <= windowBytes;

/// 按原生上限裁剪"要交给解码器的块"（纯函数，钉住 64 块 / 2 MiB 两条上限）。
///
/// 输入是各视频块的大小（按 `movi` 里的顺序），返回实际会喂给解码器的块数/字节。
({int frames, int bytes}) aviCapElementaryStream(List<int> chunkSizes) {
  var frames = 0;
  var bytes = 0;
  for (final size in chunkSizes) {
    if (frames >= kAviMaxEsFrames) break;
    if (size <= 0) continue;
    if (bytes + size > kAviMaxEsBytes) break;
    bytes += size;
    frames++;
  }
  return (frames: frames, bytes: bytes);
}

/// **请求侧**就能判定的失败原因（纯函数；平台侧结论由原生给）。
///
/// 与 `photo_widgets.photoVideoFrameFailureReason` 同口径（后者已改为委托本函数，
/// 老用例的字符串不变）。
String videoFrameRequestFailureReason({
  required String extension,
  int size = 0,
  bool rangeSupported = true,
}) {
  if (extension.isEmpty) return 'no-request';
  if (!kVideoFrameContainers.contains(normalizeMediaExtension(extension))) {
    return 'unsupported-container:${normalizeMediaExtension(extension)}';
  }
  if (!rangeSupported) {
    // 服务端不支持 Range ⇒ 只能整份下；大小未知或超上限就是"做不了"。
    if (size <= 0) return 'no-range-unknown-size';
    if (size > kVideoFrameHeadBytes) return 'no-range-too-big';
  }
  if (size <= 0) return 'unknown-size';
  // > 6 MiB ⇒ 只给了头部片段。
  if (size > kVideoFrameHeadBytes) return 'head-window:$size';
  return 'extract-failed';
}

/// 失败 → **机器可读原因键**（日志 / 诊断 / 单测；界面文案见
/// `video_thumb_failure_text.dart`，**不要**把中文写进这个函数）。
///
/// 判据优先级：**平台实测的分层 > 请求侧先验**。
///   * `container-open-failed:<家族>` —— `stage=open`：平台解析不了这个容器
///     （AVI ⇒ `container-open-failed:riff-avi`，真机取证见文件头）；
///   * `no-video-track` / `no-frame-in-video-track` —— 容器开了但取不到帧；
///   * `encode-failed` / `platform-error` —— 后两段；
///   * 平台没给分层（老构建 / 通道缺席）⇒ 退回请求侧先验（`head-window:…` 等）。
String videoFrameFailureReasonKey({
  VideoFrameExtractionFailure? failure,
  String extension = '',
  int size = 0,
  bool rangeSupported = true,
}) {
  if (failure != null) {
    final container = videoFrameContainerKey(
      failure.container.isNotEmpty
          ? failure.container
          : videoFrameContainerFamily(extension),
    );
    switch (failure.stage) {
      case VideoFrameStage.open:
        return 'container-open-failed:$container';
      case VideoFrameStage.frame:
        return failure.hasVideo == 'yes'
            ? 'no-frame-in-video-track'
            : 'no-video-track';
      case VideoFrameStage.encode:
        return 'encode-failed';
      // ★ 第 269 轮：自研 AVI fallback 的四档（**各自独立**，别互相借用）
      case VideoFrameStage.aviParse:
        // 容器头都解不出（不是 AVI / 没有 movi / 没有视频轨）
        return 'avi-parse-failed:$container';
      case VideoFrameStage.aviKeyframe:
        // 容器解出来了，但关键帧在头部窗口外 —— 这是我们**只下头部**的必然代价，
        // 不是"文件坏了"；带上下载窗口/文件大小便于对数。
        return 'avi-keyframe-outside-window:'
            '${size > 0 ? size : kVideoFrameHeadBytes}';
      case VideoFrameStage.aviCodec:
        // **容器解出来了，卡在编码**（fourcc 不认识 / 本机没解码器）
        return failure.videoFourcc.isNotEmpty
            ? 'avi-codec-unsupported:${failure.videoFourcc}'
            : 'avi-codec-unsupported';
      case VideoFrameStage.aviDecode:
        // 解码器在，但没出帧（超时 / EOS / YUV 布局不支持）
        return 'avi-decode-failed';
      case VideoFrameStage.unexpected:
        return 'platform-error';
      case VideoFrameStage.ok:
      case VideoFrameStage.unknown:
        break;
    }
  }
  return videoFrameRequestFailureReason(
    extension: extension,
    size: size,
    rangeSupported: rangeSupported,
  );
}

/// 一次抽帧失败：**平台现场 + 原因键**（缓存里按 key 记着，UI/日志都能查）。
@immutable
class VideoFrameThumbFailure {
  const VideoFrameThumbFailure({
    required this.reasonKey,
    required this.stage,
    this.container = '',
    this.videoFourcc = '',
    this.codecMime = '',
    this.reason = '',
    this.via = '',
    this.errorClass = '',
    this.error = '',
  });

  factory VideoFrameThumbFailure.from(
    VideoFrameThumbRequest request,
    VideoFrameExtractionFailure? failure,
  ) => VideoFrameThumbFailure(
    reasonKey: videoFrameFailureReasonKey(
      failure: failure,
      extension: request.extension,
      size: request.size,
      rangeSupported: request.rangeSupported,
    ),
    stage: failure?.stage ?? VideoFrameStage.unknown,
    container: videoFrameContainerKey(
      (failure?.container.isNotEmpty ?? false)
          ? failure!.container
          : videoFrameContainerFamily(request.extension),
    ),
    videoFourcc: failure?.videoFourcc ?? '',
    codecMime: failure?.codecMime ?? '',
    reason: failure?.reason ?? '',
    via: failure?.via ?? '',
    errorClass: failure?.errorClass ?? '',
    error: failure?.error ?? '',
  );

  /// 机器可读原因键（见 [videoFrameFailureReasonKey]）
  final String reasonKey;

  /// 卡在哪一段（[VideoFrameStage.unknown] = 平台没给，不是"未知错误"）
  final VideoFrameStage stage;

  /// 容器家族（原生嗅探优先，拿不到用后缀先验）
  final String container;

  /// AVI 的视频 fourcc（`FMP4`/`XVID`/`MJPG`…）；其它容器/读不到为空
  final String videoFourcc;

  /// ★ 第 269 轮：fourcc 映射到的平台解码器 MIME（空 = 映射不出/没给）
  final String codecMime;

  /// ★ 第 269 轮：原生给的**机器可读原因**（`fourcc-unsupported:FMP4` …）
  final String reason;

  /// ★ 第 269 轮：`avi-fallback` = 自研 AVI 路径（失败时也会带上）；
  /// 空 = 平台老路径 / 平台没给。
  final String via;

  final String errorClass;
  final String error;

  /// **失败是否"这个容器本机平台就没有解析器"** —— 即 `stage=open`。
  ///
  /// 界面文案据此说"系统解析不了这个容器"，而**不是**含糊的"未知错误"、
  /// 更**不是**错误的"编码不支持"。
  bool get containerNotSupported => stage == VideoFrameStage.open;

  /// ★ 第 269 轮：**容器解出来了，卡在编码**（fourcc 不认识 / 本机没解码器）。
  /// 与 [containerNotSupported] 是**两件事**：这次说"编码不支持"是**对的**。
  bool get codecUnsupported => stage == VideoFrameStage.aviCodec;

  /// 这次失败是不是自研 AVI 路径报出来的
  bool get aviFallbackUsed => stage.aviFallbackStage || via == 'avi-fallback';

  /// 一行日志正文（Dart 侧统一格式，release 也进 logcat）。
  String get logLine =>
      'reason=$reasonKey stage=${stage.key} container=$container'
      '${videoFourcc.isEmpty ? '' : ' fourcc=$videoFourcc'}'
      '${codecMime.isEmpty ? '' : ' mime=$codecMime'}'
      '${via.isEmpty ? '' : ' via=$via'}'
      '${errorClass.isEmpty ? '' : ' err=$errorClass'}'
      '${reason.isEmpty ? '' : ' why=$reason'}';

  @override
  String toString() => 'VideoFrameThumbFailure($logLine)';
}

/// ★ 第 269 轮：这几个 stage 属于自研 AVI 路径（日志/诊断用）。
extension VideoFrameStageAvi on VideoFrameStage {
  bool get aviFallbackStage =>
      this == VideoFrameStage.aviParse ||
      this == VideoFrameStage.aviKeyframe ||
      this == VideoFrameStage.aviCodec ||
      this == VideoFrameStage.aviDecode;
}


// ============================================================ 请求身份

/// 缓存键（文件系统来源）：**路径 + mtime + size**。
///
/// `mtime` 为 null 时写成空串（列表没要 `additional=time` 的场合）—— 那时
/// `size` 仍然参与键，"内容变了但 size 恰好没变"只能靠 mtime，所以**列表层
/// 应当尽量把 mtime 带上**（`FileEntryDto.mtime`）。
String videoFrameCacheKey({
  required String path,
  int? mtime,
  int size = 0,
}) => 'vframe|$path|${mtime ?? ''}|$size';

/// 一次"要视频首帧"的请求身份。
///
/// 纯数据 + 值相等（`family` 的参数要求），**不带任何网络/平台事实**。
@immutable
class VideoFrameThumbRequest {
  const VideoFrameThumbRequest({
    required this.cacheKey,
    required this.uri,
    required this.extension,
    this.size = 0,
    this.rangeSupported = true,
  });

  /// 文件系统来源（FileStation / Photos / 聊天附件…）
  factory VideoFrameThumbRequest.forPath({
    required String path,
    required String uri,
    required String extension,
    int size = 0,
    int? mtime,
    bool rangeSupported = true,
  }) => VideoFrameThumbRequest(
    cacheKey: videoFrameCacheKey(path: path, mtime: mtime, size: size),
    uri: uri,
    extension: normalizeMediaExtension(extension),
    size: size,
    rangeSupported: rangeSupported,
  );

  /// Drive 来源：**`file_id + version`**（Drive 的 path 是 `drive:<file_id>`，
  /// 用显示路径做键会在改名/移动后串台）。
  factory VideoFrameThumbRequest.forDrive({
    required String fileId,
    required String uri,
    required String extension,
    int size = 0,
    String version = '',
    bool rangeSupported = false,
  }) => VideoFrameThumbRequest(
    cacheKey: 'vframe|id:$fileId|$version|$size',
    uri: uri,
    extension: normalizeMediaExtension(extension),
    size: size,
    rangeSupported: rangeSupported,
  );

  /// 缓存身份（含 mtime/size 或 file_id/version）
  final String cacheKey;

  /// 带鉴权的取字节直链（`_sid`/`SynoToken` 在查询串里，`webapi.dart`）
  final String uri;

  /// 后缀（已归一化，小写、无点）
  final String extension;

  /// 文件总大小（0 = 未知）
  final int size;

  /// 服务端是否支持 HTTP Range
  final bool rangeSupported;

  @override
  bool operator ==(Object other) =>
      other is VideoFrameThumbRequest &&
      other.cacheKey == cacheKey &&
      other.uri == uri &&
      other.extension == extension &&
      other.size == size &&
      other.rangeSupported == rangeSupported;

  @override
  int get hashCode =>
      Object.hash(cacheKey, uri, extension, size, rangeSupported);

  @override
  String toString() =>
      'VideoFrameThumbRequest($cacheKey, ext=$extension, size=$size, '
      'range=$rangeSupported)';
}

/// **这个请求能不能做**（UI 拿它决定是否显示占位图标）。
///
/// 判据（**全部是"已知做不了"才 false，绝不瞎猜**）：
///   * 请求为 null / 直链为空 / 后缀不在 [kVideoFrameContainers] → false；
///   * **服务端不支持 Range**（Drive 写死 `Accept-Ranges: none`）时只能"整份下"：
///     必须**已知大小且 ≤ [kVideoFrameHeadBytes]** 才做 —— 大小未知一律 false
///     （宁可不出图，也不赌一把把一个 4.7 GB 的 MKV 拉下来）；
///   * 支持 Range（FileStation `Download` 真机实测 206）→ true，多大都行
///     （只取头部 [kVideoFrameHeadBytes]）。
bool videoFrameThumbSupported(VideoFrameThumbRequest? request) {
  if (request == null) return false;
  if (request.uri.isEmpty) return false;
  if (request.extension.isEmpty) return false;
  if (!kVideoFrameContainers.contains(request.extension)) return false;
  if (!request.rangeSupported && request.size <= 0) return false;
  if (!request.rangeSupported && request.size > kVideoFrameHeadBytes) {
    return false;
  }
  return true;
}

/// "这次要下多少"的计划（纯函数，便于单测钉"上限"）。
class VideoFrameDownloadPlan {
  const VideoFrameDownloadPlan({required this.maxBytes, required this.wholeFile});

  /// 交给传输层的 `maxBytes`（`Range: bytes=0-<maxBytes-1>`）
  final int maxBytes;

  /// true = 服务端会回**整份**（文件本身 ≤ 上限），false = 只取头部片段
  final bool wholeFile;

  @override
  bool operator ==(Object other) =>
      other is VideoFrameDownloadPlan &&
      other.maxBytes == maxBytes &&
      other.wholeFile == wholeFile;

  @override
  int get hashCode => Object.hash(maxBytes, wholeFile);

  @override
  String toString() => 'VideoFrameDownloadPlan($maxBytes, whole=$wholeFile)';
}

/// 下载计划：文件比上限小就按"整份"要（`maxBytes = size`，省得服务端
/// 在 206 之外还要额外处理），否则只要头部 [kVideoFrameHeadBytes]。
VideoFrameDownloadPlan videoFrameDownloadPlan(VideoFrameThumbRequest request) {
  final known = request.size > 0;
  if (known && request.size <= kVideoFrameHeadBytes) {
    return VideoFrameDownloadPlan(maxBytes: request.size, wholeFile: true);
  }
  return const VideoFrameDownloadPlan(
    maxBytes: kVideoFrameHeadBytes,
    wholeFile: false,
  );
}

/// 从"列表条目 + 已解析的播放来源"拼一个请求（UI 主入口）。
///
/// 返回 null = 这个条目**不该**走抽帧（目录 / 非视频来源 / 直链空）。
/// 注意 Drive 的视频来源 `playable == false`（写死 `Accept-Ranges: none`
/// ⇒ 不内嵌播），但 **`uri` 仍在** —— 所以判据是"uri 非空"，不是 `playable`。
///
/// **直链一律复用既有实现，这里一个 URL 都不拼**：[source] 来自
/// `resolveEntryMediaSource()`（FileStation 腿走
/// `FileStationApi.downloadUrl([path])` → `SYNO.FileStation.Download&method=download`
/// 的 `authenticatedUrl`，`_sid`/`SynoToken` 已在查询串里；Drive/Photos 腿各自同理）。
VideoFrameThumbRequest? videoFrameThumbRequestFor(
  FileEntryDto entry,
  MediaSource source,
) {
  // ★ 诊断（第 41 轮，临时）：每一道门都说出理由 —— 真机上曾出现
  //   "4/4 视频只有图标、无 FAIL 日志、缓存目录为空" 的静默拒绝。
  VideoFrameThumbRequest? block(String reason) {
    debugPrint(
      '[videoFrameThumb] REQ-NULL path=${entry.path} '
      'ext=${entry.extension} size=${entry.size} reason=$reason',
    );
    return null;
  }

  if (entry.isDir) return block('isDir');
  if (source.kind != MediaKind.video) return block('kind=${source.kind}');
  if (source.uri.isEmpty) return block('uri-empty');
  final ext = normalizeMediaExtension(entry.extension);
  if (!kVideoFrameContainers.contains(ext)) return block('ext-not-supported');
  final request = VideoFrameThumbRequest.forPath(
    path: entry.path,
    uri: source.uri,
    extension: ext,
    size: entry.size,
    mtime: entry.mtime,
    rangeSupported: source.supportsRange,
  );
  debugPrint(
    '[videoFrameThumb] REQ path=${entry.path} ext=$ext size=${entry.size} '
    'range=${source.supportsRange} supported=${videoFrameThumbSupported(request)}',
  );
  return request;
}

// ============================================================ 抽帧流水线（可注入）

/// "下头部 + 抽帧"的完整加载器（测试注入假实现即可绕开网络与平台）
typedef VideoFrameLoader =
    Future<Uint8List?> Function(VideoFrameThumbRequest request);

/// "取文件头部片段"的函数（生产实现走 `DsmWebApi.getBytes`；测试注入假的）
typedef VideoFrameHeadFetcher =
    Future<Uint8List> Function(
      VideoFrameThumbRequest request, {
      required int maxBytes,
    });

/// 临时文件目录（生产实现走 `path_provider` 的临时目录；测试注入 `Directory.systemTemp`）
typedef VideoFrameTempDirectory = Future<Directory> Function();

/// 带**失败分层**的完整加载器（第 267 轮；生产路径用它，测试注入假实现）。
typedef VideoFrameDetailedLoader =
    Future<VideoFrameThumbOutcome> Function(VideoFrameThumbRequest request);

/// 一次"下头部 + 抽帧"的结果：**要么有图，要么有原因**。
@immutable
class VideoFrameThumbOutcome {
  const VideoFrameThumbOutcome({
    this.bytes,
    this.failure,
    this.platformUnavailable = false,
  });

  /// 成功时的 JPEG 字节
  final Uint8List? bytes;

  /// 失败时的原因（成功时为 null）
  final VideoFrameThumbFailure? failure;

  /// ★ r132（iOS 逐屏走查）：**这台机器结构上就没有抽帧能力**（不是这个文件坏）。
  ///
  /// 与 [failure] 的区别是语义，也是行为：`failure` = "这次抽帧失败了"（界面挂失败
  /// 角标、进失败记忆、计入失败率）；`platformUnavailable` = "宿主没实现抽帧"
  /// （界面画中性视频图标、**不进失败记忆**、一个字节都不下）。
  final bool platformUnavailable;

  bool get hasBytes => bytes != null && bytes!.isNotEmpty;

  @override
  String toString() => hasBytes
      ? 'VideoFrameThumbOutcome(${bytes!.length}B)'
      : 'VideoFrameThumbOutcome(failure=${failure?.logLine})';
}

/// 下载头部 → 写临时文件 → 原生抽帧 → 删临时文件。返回 **JPEG 字节**（老契约）。
///
/// 任何一步失败 → null（**不抛**）：列表里为一张缩略图抛红没有意义。
/// **新代码请用 [loadVideoFrameThumbDetailed]**：它额外带回"卡在哪一段"。
Future<Uint8List?> loadVideoFrameThumb({
  required VideoFrameThumbRequest request,
  required VideoFrameExtractor extractor,
  required VideoFrameHeadFetcher fetchHead,
  required VideoFrameTempDirectory tempDirectory,
  int atMs = 0,
  int maxWidth = kVideoFrameThumbMaxWidth,
}) async {
  if (!videoFrameThumbSupported(request)) return null;
  File? temp;
  try {
    final plan = videoFrameDownloadPlan(request);
    final head = await fetchHead(request, maxBytes: plan.maxBytes);
    if (head.isEmpty) return null;
    final dir = await tempDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    temp = File('${dir.path}/${videoFrameTempFileName(request.cacheKey)}');
    await temp.writeAsBytes(head, flush: true);
    final frame = await extractor.extract(
      temp.path,
      atMs: atMs,
      maxWidth: maxWidth,
    );
    return frame?.bytes;
  } catch (_) {
    return null;
  } finally {
    // 临时片段**一定**要删：它是 6 MB 量级的中间物，留在盘上就是泄漏。
    if (temp != null) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 删不掉也不该影响结果（系统清缓存会回收）
      }
    }
  }
}

/// 与 [loadVideoFrameThumb] 同一条流水线，但**失败也带回原因**（第 267 轮）。
///
/// [stageExtractor] 为 null / 通道缺席（老构建、宿主测试）时，退化成
/// [loadVideoFrameThumb] 的行为：失败只有 `reasonKey`（请求侧先验，如
/// `head-window:<size>`），`stage` 记 [VideoFrameStage.unknown] —— 这**不是**
/// "未知错误"，而是"平台没给出分层"。
Future<VideoFrameThumbOutcome> loadVideoFrameThumbDetailed({
  required VideoFrameThumbRequest request,
  required VideoFrameExtractor extractor,
  required VideoFrameHeadFetcher fetchHead,
  required VideoFrameTempDirectory tempDirectory,
  VideoFrameStageExtractor? stageExtractor,
  int atMs = 0,
  int maxWidth = kVideoFrameThumbMaxWidth,
}) async {
  // 请求侧就做不了（没有直链 / 后缀不在白名单 / Range 与大小不满足）：
  // **一个字节都不下**，但原因要如实带出去（不再只是 null）。
  if (!videoFrameThumbSupported(request)) {
    return VideoFrameThumbOutcome(
      failure: VideoFrameThumbFailure.from(request, null),
    );
  }
  File? temp;
  try {
    // ★ 第 42 轮：**播放器优先**。平台解析器对部分码流回黑图而不报错
    //   （真机：AVI/MKV/大 mp4 全黑），media3 是"能播就能抽"的同一套栈。
    if (stageExtractor is VideoFramePlayerStageExtractor &&
        request.uri.isNotEmpty) {
      final playerExtractor = stageExtractor as VideoFramePlayerStageExtractor;
      final viaPlayer = await playerExtractor.extractFrameViaPlayer(
        request.uri,
        const <String, String>{},
        atMs: atMs,
        maxWidth: maxWidth,
      );
      if (viaPlayer != null && viaPlayer.hasBytes) {
        return VideoFrameThumbOutcome(bytes: viaPlayer.bytes);
      }
    }
    // ★ 第 41 轮：**先走 URL 模式**（真实数据 + 跳黑场），失败再落回"头部文件"老路径。
    //   真机实测：只喂 6 MB 头部时 AVI/MKV/238MB mp4 全是黑帧（luma 0~1），
    //   13 MB mp4 却是真帧（luma=223）——半截文件对"索引靠后/首帧靠后"的容器无解。
    if (stageExtractor is VideoFrameUrlStageExtractor &&
        request.uri.isNotEmpty) {
      final urlExtractor = stageExtractor as VideoFrameUrlStageExtractor;
      final viaUrl = await urlExtractor.extractDetailedUrl(
        request.uri,
        const <String, String>{},
        atMs: atMs,
        maxWidth: maxWidth,
      );
      if (viaUrl != null && viaUrl.hasBytes) {
        return VideoFrameThumbOutcome(bytes: viaUrl.bytes);
      }
    }
    final plan = videoFrameDownloadPlan(request);
    final head = await fetchHead(request, maxBytes: plan.maxBytes);
    if (head.isEmpty) {
      return VideoFrameThumbOutcome(
        failure: VideoFrameThumbFailure.from(request, null),
      );
    }
    final dir = await tempDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    temp = File('${dir.path}/${videoFrameTempFileName(request.cacheKey)}');
    await temp.writeAsBytes(head, flush: true);
    if (stageExtractor != null) {
      final detailed = await stageExtractor.extractDetailed(
        temp.path,
        atMs: atMs,
        maxWidth: maxWidth,
      );
      if (detailed != null) {
        if (detailed.hasBytes) {
          return VideoFrameThumbOutcome(bytes: detailed.bytes);
        }
        return VideoFrameThumbOutcome(
          failure: VideoFrameThumbFailure.from(request, detailed.failure),
        );
      }
      // 通道没答上来 ⇒ 落回老契约再试一次（老构建仍能出图）。
    }
    final frame = await extractor.extract(
      temp.path,
      atMs: atMs,
      maxWidth: maxWidth,
    );
    if (frame == null || frame.bytes.isEmpty) {
      return VideoFrameThumbOutcome(
        failure: VideoFrameThumbFailure.from(request, null),
      );
    }
    return VideoFrameThumbOutcome(bytes: frame.bytes);
  } catch (_) {
    return VideoFrameThumbOutcome(
      failure: VideoFrameThumbFailure.from(request, null),
    );
  } finally {
    if (temp != null) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 删不掉也不该影响结果（系统清缓存会回收）
      }
    }
  }
}

/// 缓存文件名：FNV-1a 64 位十六进制 + 键长度（避免不同键撞名）。
String videoFrameTempFileName(String cacheKey) =>
    '${_fnv1a(cacheKey)}_${cacheKey.length}.bin';

/// 磁盘缓存文件名（与 [videoFrameTempFileName] 同源，但后缀表明它是成品）
String videoFrameDiskFileName(String cacheKey) =>
    '${_fnv1a(cacheKey)}_${cacheKey.length}.vframe';

/// ★ 第 335 轮：唯一实现搬到 [fnv1a64Hex]（JS 上也精确的 64 位 FNV-1a）。
/// 输出与原实现逐字节相同 ⇒ 缓存名不变；顺带消掉 §2.0.26 的"两份表示"。
String _fnv1a(String key) => fnv1a64Hex(key);

// ============================================================ 缓存 + 限流 + 取消

/// 命中情况（调试面板与单测断言用）
class VideoFrameThumbStats {
  int hits = 0;
  int misses = 0;
  int loaded = 0;
  int failures = 0;
  int deduped = 0;
  int cancelled = 0;
  int diskEvictedFiles = 0;

  int get total => hits + misses;

  @override
  String toString() =>
      'VideoFrameThumbStats(命中 $hits/$total, 取回 $loaded, 失败 $failures, '
      '合流 $deduped, 取消 $cancelled, 磁盘淘汰 $diskEvictedFiles)';
}

/// 视频首帧缓存：**内存 LRU + 磁盘 LRU + 失败记忆 + 限流 + 合流 + 取消**。
///
/// 与 `ThumbCache`（文件缩略图）分开写而不是复用，原因是这里多了两件事：
///   1. **磁盘按总字节 LRU 淘汰**（`ThumbCache` 的磁盘只靠设置页统一清）；
///   2. **可取消**（滚动列表滚出去的视频不该继续抽帧）。
class VideoFrameThumbCache {
  VideoFrameThumbCache({
    required this.loader,
    this.detailedLoader,
    Future<Directory?> Function()? directory,
    this.memoryBytes = kVideoFrameMemoryBytes,
    this.diskBytes = kVideoFrameDiskBytes,
    this.maxConcurrent = kVideoFrameMaxConcurrent,
    this.negativeTtl = kVideoFrameNegativeTtl,
    DateTime Function()? now,
  }) : _directory = directory,
       _now = now ?? DateTime.now;

  /// 真正去"下载 + 抽帧"的函数（老契约；[detailedLoader] 缺席时用它）
  final VideoFrameLoader loader;

  /// 带**失败分层**的加载器（第 267 轮；生产实现见
  /// [videoFrameDetailedLoaderProvider]）。非 null 时优先于 [loader]。
  final VideoFrameDetailedLoader? detailedLoader;

  /// 磁盘缓存目录；返回 null = 只用内存（测试/无缓存目录）
  final Future<Directory?> Function()? _directory;

  /// 内存上限（字节）；0 = 不缓存内存
  final int memoryBytes;

  /// 磁盘上限（字节）；0 = 不落盘
  final int diskBytes;

  /// 同时在飞的请求上限
  final int maxConcurrent;

  /// 失败后多久内不再重试
  final Duration negativeTtl;

  final DateTime Function() _now;

  final VideoFrameThumbStats stats = VideoFrameThumbStats();

  /// LRU：`LinkedHashMap` 的插入顺序就是"最近使用"顺序
  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  int _memoryUsed = 0;

  /// 正在请求中的键（同一张图被列表重复要 → 合并成一个请求）
  final Map<String, Future<Uint8List?>> _inflight = {};

  /// 失败记忆：键 → 失败时间
  final Map<String, DateTime> _failed = {};

  /// 失败**原因**（第 267 轮）：键 → 平台侧现场 + 原因键。
  ///
  /// 与 [_failed] 分开存：[_failed] 是"别再重试"的时间戳（行为），
  /// 这张表是"为什么失败"（解释）。UI 与 `[videoFrameThumb] FAIL` 日志读它。
  final Map<String, VideoFrameThumbFailure> _failureDetails = {};

  /// 被取消的键（在 [cancel] 里登记，在拿到并发名额后消费）
  final Set<String> _cancelled = {};

  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue();

  int get memoryUsed => _memoryUsed;

  int get memoryCount => _memory.length;

  bool get isMemoryEmpty => _memory.isEmpty;

  int get failuresRemembered => _failed.length;

  bool isRememberedFailure(String cacheKey) => _failed.containsKey(cacheKey);

  /// 记过的失败原因（第 267 轮）。null = 这个键没记过失败 / 已过期。
  ///
  /// **读它之前先看 [isRememberedFailure]**：只有"确实失败"才会有原因，
  /// 且原因与失败记忆同寿命（[clearFailures] / TTL 到期一起清）。
  VideoFrameThumbFailure? failureFor(String cacheKey) =>
      _failureDetails[cacheKey];

  /// 记一次失败（时间戳 + 原因一起写）
  void _rememberFailure(String key, VideoFrameThumbFailure? failure) {
    _failed[key] = _now();
    if (failure != null) {
      _failureDetails[key] = failure;
    } else {
      _failureDetails.remove(key);
    }
  }

  /// 取一张首帧图；失败/取消 → null（调用方展示占位图标即可）。
  Future<Uint8List?> get(VideoFrameThumbRequest request) {
    final key = request.cacheKey;
    // ① 内存（命中即"最近使用"）
    final cached = _memory.remove(key);
    if (cached != null) {
      _memory[key] = cached;
      stats.hits++;
      return Future.value(cached);
    }
    // ② 失败记忆（滚动列表里别反复撞）
    final failedAt = _failed[key];
    if (failedAt != null) {
      if (_now().difference(failedAt) < negativeTtl) {
        stats.failures++;
        return Future.value(null);
      }
      _failed.remove(key);
      _failureDetails.remove(key);
    }
    // ③ 合流：同一个键正在请求 → 直接给同一个 future
    final running = _inflight[key];
    if (running != null) {
      stats.deduped++;
      return running;
    }
    stats.misses++;
    final future = _load(key, request);
    _inflight[key] = future;
    return future.whenComplete(() => _inflight.remove(key));
  }

  /// 取消一个排队中/在飞的请求（`autoDispose` provider 回收时调）。
  ///
  /// **只是"不再要这个结果"**，不打断已经在跑的 IO；排队中的请求会在拿到
  /// 并发名额后立刻返回 null，且**不写失败记忆**（取消不是失败）。
  void cancel(String cacheKey) {
    if (cacheKey.isEmpty) return;
    _cancelled.add(cacheKey);
    // 别让取消集合无限长大：它只在"有 inflight 的键"上才有意义
    if (!_inflight.containsKey(cacheKey) && _cancelled.length > 64) {
      _cancelled.remove(cacheKey);
    }
  }

  Future<Uint8List?> _load(String key, VideoFrameThumbRequest request) async {
    // ④ 磁盘
    final fromDisk = await _readDisk(key);
    if (fromDisk != null) {
      // 磁盘命中：把刚才记的那次 miss 收回，避免"命中率"被磁盘命中和错
      stats.hits++;
      stats.misses--;
      _putMemory(key, fromDisk);
      return fromDisk;
    }
    if (_cancelled.remove(key)) {
      stats.cancelled++;
      return null;
    }
    await _acquire();
    try {
      // ⑤ 拿到名额后再查一次取消：滚出去的视频**不该**再下 6 MB
      if (_cancelled.remove(key)) {
        stats.cancelled++;
        return null;
      }
      // 生产路径走 detailedLoader（带回"卡在哪一段"）；没注入就退化成老 loader。
      VideoFrameThumbFailure? failure;
      Uint8List? bytes;
      var platformUnavailable = false;
      final detailed = detailedLoader;
      if (detailed != null) {
        final outcome = await detailed(request);
        bytes = outcome.bytes;
        failure = outcome.failure;
        platformUnavailable = outcome.platformUnavailable;
      } else {
        bytes = await loader(request);
      }
      if (_cancelled.remove(key)) {
        // 下载已经跑完（IO 打不断），但结果按"已取消"处理、不入缓存
        stats.cancelled++;
        return null;
      }
      if (bytes == null || bytes.isEmpty) {
        if (platformUnavailable) {
          // ★ r132：宿主没这个能力 —— **不记失败记忆、不计数失败、不打 FAIL 日志**。
          //   记成失败会让界面把"这台机器做不了"说成"这个文件抽不出帧"
          //   （真机日志 `reason=extract-failed stage=unknown`），而且负缓存 TTL
          //   内还会阻止任何重试。
          return null;
        }
        // 第 267 轮：失败**必须留下原因**（[VideoFrameThumbFailure.from] 在
        // detailedLoader 缺席时也会给出请求侧先验，不会是空）。
        final detail = failure ?? VideoFrameThumbFailure.from(request, null);
        _rememberFailure(key, detail);
        stats.failures++;
        // 稳定枚举当原因码（`VideoFrameStage`）；绝不把 message 当原因。
        trackOnceFailure(
          UsageModule.media,
          UsageAction.preview,
          objectType: 'video_frame',
          reason: detail.stage,
        );
        return null;
      }
      stats.loaded++;
      _failed.remove(key);
      _failureDetails.remove(key);
      _putMemory(key, bytes);
      await _writeDisk(key, bytes);
      trackOnce(
        UsageModule.media,
        UsageAction.preview,
        objectType: 'video_frame',
      );
      return bytes;
    } catch (_) {
      _rememberFailure(key, VideoFrameThumbFailure.from(request, null));
      stats.failures++;
      trackOnceFailure(
        UsageModule.media,
        UsageAction.preview,
        objectType: 'video_frame',
        reason: VideoFrameStage.unknown,
      );
      return null;
    } finally {
      _release();
    }
  }

  // ------------------------------------------------------------ 内存 LRU

  void _putMemory(String key, Uint8List bytes) {
    if (memoryBytes <= 0 || bytes.length > memoryBytes) return;
    final old = _memory.remove(key);
    if (old != null) _memoryUsed -= old.length;
    _memory[key] = bytes;
    _memoryUsed += bytes.length;
    while (_memoryUsed > memoryBytes && _memory.isNotEmpty) {
      final victim = _memory.keys.first;
      final removed = _memory.remove(victim);
      _memoryUsed -= removed?.length ?? 0;
    }
  }

  /// 清内存（退到后台 / 内存告急）
  void clearMemory() {
    _memory.clear();
    _memoryUsed = 0;
  }

  /// 忘掉所有失败记忆（下拉刷新时叫，让失败过的视频再试一次）
  void clearFailures() {
    _failed.clear();
    _failureDetails.clear();
  }

  /// 只读：当前内存里的键（测试/诊断）
  List<String> debugMemoryKeys() => _memory.keys.toList();

  // ------------------------------------------------------------ 磁盘 LRU

  Future<Directory?> _ensureDir() async {
    final dir = await _directory?.call();
    if (dir == null) return null;
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Uint8List?> _readDisk(String key) async {
    if (diskBytes <= 0) return null;
    try {
      final dir = await _ensureDir();
      if (dir == null) return null;
      final file = File('${dir.path}/${videoFrameDiskFileName(key)}');
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      // 命中即刷新 mtime = 标记"最近使用"（磁盘 LRU 就靠它）
      unawaited(file.setLastModified(_now()));
      return bytes;
    } catch (_) {
      return null; // 缓存读失败永远不该影响功能
    }
  }

  Future<void> _writeDisk(String key, Uint8List bytes) async {
    if (diskBytes <= 0) return;
    try {
      final dir = await _ensureDir();
      if (dir == null) return;
      await File(
        '${dir.path}/${videoFrameDiskFileName(key)}',
      ).writeAsBytes(bytes, flush: false);
      await _enforceDiskLimit(dir);
    } catch (_) {
      // 磁盘满 / 没权限都不该让缩略图瘸掉
    }
  }

  /// 磁盘按**总字节** LRU 淘汰：最久未用（mtime 最小）的先删。
  ///
  /// 只动 `.vframe` 后缀的文件 —— 同目录里别的东西（比如正在写的临时片段）
  /// 一律不碰。
  Future<int> _enforceDiskLimit(Directory dir) async {
    final entries = <({File file, int size, DateTime at})>[];
    var total = 0;
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        if (!e.path.endsWith('.vframe')) continue;
        try {
          final st = await e.stat();
          entries.add((file: e, size: st.size, at: st.modified));
          total += st.size;
        } catch (_) {}
      }
    } catch (_) {
      return 0;
    }
    if (total <= diskBytes) return 0;
    entries.sort((a, b) => a.at.compareTo(b.at)); // 最久未用在前
    var freed = 0;
    for (final e in entries) {
      if (total <= diskBytes) break;
      try {
        await e.file.delete();
        total -= e.size;
        freed += e.size;
        stats.diskEvictedFiles++;
      } catch (_) {}
    }
    return freed;
  }

  /// 清磁盘缓存，返回删掉的字节数
  Future<int> clearDisk() async {
    var freed = 0;
    try {
      final dir = await _ensureDir();
      if (dir == null) return 0;
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File || !e.path.endsWith('.vframe')) continue;
        try {
          freed += await e.length();
          await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
    return freed;
  }

  // ------------------------------------------------------------ 并发限流

  Future<void> _acquire() async {
    if (_running < maxConcurrent) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      // 直接把名额让给排队的人（避免"醒来又发现没位置"）
      _waiting.removeFirst().complete();
      return;
    }
    _running--;
  }
}

// ============================================================ Riverpod 接线

Duration? _noRetry(int retryCount, Object error) => null;

/// 抽帧桥（真机实现；测试里 override 成假实现，**不依赖 Android 运行时**）
/// 抽帧后端：**按宿主选实现**（r707）。
///
/// * Android：`synhub/video_frame` 通道（`MediaMetadataRetriever`）；
/// * Windows：`MpvVideoFrameExtractor`（libmpv 的 `screenshot-raw`，纯 Dart
///   调 mpv 命令，不建 VideoController ⇒ 不依赖窗口；
///   见 `lib/src/core/media/mpv_video_frame_extractor.dart` 文件头的三条事实）。
///
/// ★ 为什么 Windows 不能顺手也走通道：那边**没有** Kotlin 那一侧，
///   `invokeMethod` 只会 `MissingPluginException`；能力位翻了之后
///   `MethodChannelVideoFrameExtractor._isAndroid` 若只看能力门，
///   就会把 Windows 也放进去打空通道 —— 所以两处**都要钉宿主**。
final videoFrameExtractorProvider = Provider<VideoFrameExtractor>((ref) {
  if (AppPlatformCapabilities.current().host == AppHost.windows) {
    return const MpvVideoFrameExtractor();
  }
  return const MethodChannelVideoFrameExtractor();
});

/// 取头部片段的传输（生产实现 = App 自己的 Dio/传输层，**网络不交给原生**）。
///
/// `getBytes(maxBytes:)` 会带 `Range: bytes=0-<maxBytes-1>`；服务端**不支持
/// Range**（Drive 写死 `Accept-Ranges: none`）时它会把整份回给我们 —— 那正是
/// 任务书说的"退化为下载整个文件但设上限"：**上限由
/// [videoFrameThumbSupported] 兜住**（不支持 Range 时**必须已知大小且 ≤ 6 MiB**
/// 才放行），所以这条路上不可能下走一个 2 GB 视频。
///
/// 另外再加一道**防御性闸门**：万一某个服务端/代理嘴上说支持 Range 却整份回，
/// [onProgress] 一旦收到超过 `maxBytes` 的字节就**取消**这次请求
/// （宁可这张缩略图不出，也不把手机内存打爆）—— 取消后
/// `loadVideoFrameThumb` 会把它当普通失败（记入失败记忆，不会反复重试）。
final videoFrameHeadFetcherProvider = Provider<VideoFrameHeadFetcher>((ref) {
  return (request, {required int maxBytes}) async {
    final api = ref
        .read(sessionControllerProvider)
        .connection
        ?.api
        .withModule(TrafficModules.media);
    if (api == null) throw StateError('未连接');
    final cancel = DownloadCancelToken();
    final bytes = await api.getBytes(
      request.uri,
      maxBytes: maxBytes,
      cancelToken: cancel,
      onProgress: (received, total) {
        if (received > maxBytes) cancel.cancel('over_cap');
      },
    );
    return Uint8List.fromList(bytes);
  };
});

/// 临时文件目录（原生只吃**本地路径**，所以要先落一份临时片段）
final videoFrameTempDirectoryProvider = Provider<VideoFrameTempDirectory>(
  (ref) => () async {
    final base = await getTemporaryDirectory();
    return Directory('${base.path}/video_frame_tmp');
  },
);

/// "下头部 + 抽帧"的完整加载器（测试里 override 它就能绕开网络与平台）
/// 本宿主**有没有可能**抽出视频帧（第 132 轮 iOS 逐屏走查）。
///
/// `capabilityGateAllows` = `mayTry`：Android 的静态结论是 `unknown` ⇒ 放行去试桥；
/// iOS/macOS/Linux/Windows 是 `unavailable:not-implemented-on-host` ⇒ 返回 false。
/// 两个 `debugForceAndroid` 与抽帧桥**同一口径**（测试用它把"宿主不能"这一关打开）。
///
/// 单测里用 [debugForceVideoFrameExtractionPossible] 把"宿主不能抽帧"这一关打开
/// （与两个桥的 `debugForceAndroid` 同一个套路，但**不跨库引用**它们的
/// `@visibleForTesting` 成员 —— 那会触发 `invalid_use_of_visible_for_testing_member`）。
@visibleForTesting
bool debugForceVideoFrameExtractionPossible = false;

bool videoFrameExtractionPossibleOnThisHost() =>
    debugForceVideoFrameExtractionPossible ||
    capabilityGateAllows(AppCapability.videoFrameExtraction);

final videoFrameLoaderProvider = Provider<VideoFrameLoader>((ref) {
  // ★ r132（iOS 逐屏走查）：宿主结构上抽不了帧时**连头片段都不下**。
  //   第一版照旧走完整流水线 ⇒ 相册里每个视频格真下 6 MiB 头片段 + 写临时文件，
  //   最后记一条 `[photoVideoThumb] FAIL key=… reason=extract-failed stage=unknown`
  //   （iOS 真机日志逐字），界面还挂"提取失败"。Android 不受影响。
  if (!videoFrameExtractionPossibleOnThisHost()) {
    return (request) async => null;
  }
  final extractor = ref.watch(videoFrameExtractorProvider);
  final fetchHead = ref.watch(videoFrameHeadFetcherProvider);
  final tempDirectory = ref.watch(videoFrameTempDirectoryProvider);
  return (request) => loadVideoFrameThumb(
    request: request,
    extractor: extractor,
    fetchHead: fetchHead,
    tempDirectory: tempDirectory,
  );
});

/// 分层抽帧桥（第 267 轮）：`extractFrameEx`。宿主/测试上是 no-op（返回 null）。
final videoFrameStageExtractorProvider = Provider<VideoFrameStageExtractor>(
  (ref) => const MethodChannelVideoFrameStageExtractor(),
);

/// 带**失败分层**的加载器（生产缓存用它；测试 override 它就绕开网络与平台）。
final videoFrameDetailedLoaderProvider = Provider<VideoFrameDetailedLoader>((ref) {
  // 同 [videoFrameLoaderProvider]：宿主没这个能力 ⇒ 空结果 + `platformUnavailable`
  // （**不**记失败、不下字节），界面按"做不了"画中性图标。
  if (!videoFrameExtractionPossibleOnThisHost()) {
    return (request) async => const VideoFrameThumbOutcome(
      platformUnavailable: true,
    );
  }
  final extractor = ref.watch(videoFrameExtractorProvider);
  final stageExtractor = ref.watch(videoFrameStageExtractorProvider);
  final fetchHead = ref.watch(videoFrameHeadFetcherProvider);
  final tempDirectory = ref.watch(videoFrameTempDirectoryProvider);
  return (request) => loadVideoFrameThumbDetailed(
    request: request,
    extractor: extractor,
    stageExtractor: stageExtractor,
    fetchHead: fetchHead,
    tempDirectory: tempDirectory,
  );
});

/// 视频首帧缓存（跨页面存活：滚动出去再滚回来不该重抽）
final videoFrameThumbCacheProvider = Provider<VideoFrameThumbCache>((ref) {
  final cache = VideoFrameThumbCache(
    loader: ref.watch(videoFrameLoaderProvider),
    // 生产路径走"能说出原因"的那条；测试 override
    // `videoFrameDetailedLoaderProvider`（或直接建 cache）即可。
    detailedLoader: ref.watch(videoFrameDetailedLoaderProvider),
    directory: () async {
      final base = await getApplicationCacheDirectory();
      return Directory('${base.path}/video_frames');
    },
  );
  ref.onDispose(cache.clearMemory);
  return cache;
});

/// 取一张视频首帧（UI 主入口）。
///
/// `autoDispose`：滚出屏幕就**取消**这一次抽帧（[VideoFrameThumbCache.cancel]）；
/// 已经抽到的图在缓存里还留着，滚回来直接命中。
final videoFrameThumbProvider = FutureProvider.autoDispose
    .family<Uint8List?, VideoFrameThumbRequest>((ref, request) async {
      if (!videoFrameThumbSupported(request)) return null;
      final cache = ref.watch(videoFrameThumbCacheProvider);
      ref.onDispose(() => cache.cancel(request.cacheKey));
      return cache.get(request);
    }, retry: _noRetry);

/// UI 判定："这个请求值得显示占位图标吗"（false ⇒ 直接画视频图标，别发请求）
final videoFrameThumbSupportedProvider = Provider.family<bool, VideoFrameThumbRequest>(
  (ref, request) => videoFrameThumbSupported(request),
);

/// 这个请求**为什么**抽不出帧（第 267 轮）。
///
/// 读的是失败记忆里的原因（[VideoFrameThumbCache.failureFor]）：null = 没失败过
/// / 已过期 / 成功了。与 [videoFrameThumbProvider] 一样在 provider 解析后重读，
/// **不要**把它当成"会在失败那一刻自动重建"的信号源（失败记忆不是可监听状态，
/// 与既有 `isRememberedFailure` 同款语义）。
final videoFrameThumbFailureProvider =
    Provider.family<VideoFrameThumbFailure?, VideoFrameThumbRequest>(
      (ref, request) =>
          ref.watch(videoFrameThumbCacheProvider).failureFor(request.cacheKey),
    );

// ------------------------------------------------------------ 失败日志
//
// ★ 第 267 轮补的**缺口**：相册侧有 `[photoVideoThumb] FAIL`，但 **Files 列表
// 一条 Dart 日志都没有** —— 真机上只能靠原生 `stage=` 行反推。这里给**共用**
// 的一行日志（release 也进 logcat，tag `flutter`），两条渲染路都走它：
// 相册传 `tag: 'photoVideoThumb'`（**老格式逐字不变**，老用例仍绿），
// Files 走默认的 `videoFrameThumb`。
//
// 一个 key 只打一次（日志集有界 64 条），避免滚动列表刷屏。

final Set<String> _loggedVideoFrameFailures = <String>{};

/// 打一行失败日志（同一个 key 只打一次）。返回是否真的打了。
///
/// 格式固定：`[<tag>] FAIL key=… ext=… size=… range=… reason=… stage=… container=… [fourcc=…] [err=…]`
/// 「原因键」见 [videoFrameFailureReasonKey]：`container-open-failed:riff-avi` ＝
/// **本机平台没有 AVI/RIFF 解析器**（真机取证），不是"编码不支持"。
bool logVideoFrameThumbFailure(
  VideoFrameThumbRequest request,
  VideoFrameThumbFailure? failure, {
  String tag = 'videoFrameThumb',
}) {
  final key = request.cacheKey;
  if (key.isEmpty) return false;
  if (_loggedVideoFrameFailures.contains(key)) return false;
  if (_loggedVideoFrameFailures.length >= 64) {
    _loggedVideoFrameFailures.remove(_loggedVideoFrameFailures.first);
  }
  _loggedVideoFrameFailures.add(key);
  final f = failure ?? VideoFrameThumbFailure.from(request, null);
  debugPrint(
    '[$tag] FAIL key=$key ext=${request.extension} '
    'size=${request.size} range=${request.rangeSupported} ${f.logLine}',
  );
  return true;
}

/// 只读：已经打过失败日志的键（测试/诊断）
@visibleForTesting
List<String> debugLoggedVideoFrameFailures() =>
    _loggedVideoFrameFailures.toList();

/// 清空失败日志记忆（测试之间用）
@visibleForTesting
void debugClearLoggedVideoFrameFailures() => _loggedVideoFrameFailures.clear();
