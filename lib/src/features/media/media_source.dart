// 内置媒体播放的「可播放 URL」解析（**纯逻辑层**）。
//
// 这一层**不许** import flutter / package:flutter / l10n：
// `dart run tool/*.dart` 要用纯 Dart VM 直接加载它（同 `lib/src/data/**` 的规矩，
// 见 `lib/src/core/i18n/data_text.dart` 的注释）。所以：
//   * 失败原因一律是**枚举**（[MediaUnavailableReason]），这里不拼界面文案；
//   * 需要一句兜底中文时走 [dataText]（`key + 中文原文`，Flutter 层再注入译文）。
//
// 事实来源：docs/native-media-playback-research.md
//   §3.1 FileStation `Download` **真机实测支持 HTTP Range**（`Range: bytes=0-63`
//        → `206` + `content-range` + `accept-ranges: bytes`），且鉴权只靠查询串
//        `_sid` + `SynoToken` → 原生播放器直接吃 URL 就能 seek。
//   §3.4 Drive 所有 webapi 处理器**写死 `Accept-Ranges: none`**（30 个 `.so`）
//        → Drive 里的东西拖不动进度，不能假装能拖（`supportsRange = false`）。
//   §3.3 Photos：官方对"原生 mp4/h264"走 `SYNO.Foto.Download`（`quality="raw"`，
//        R7 修正，见 docs/media-streaming-diagnosis.md §1.2），`SYNO.Foto.Streaming
//        & type=item` 只是**转码档兜底**。**Range 真机已证的是 Download**
//        （2026-09-22：`206` + `Content-Range`，见 docs/live-nas-verification.md
//        §4.3）→ Download 腿 `supportsRange = true`（可拖/可定位）；
//        `Streaming` 腿真机零字节 → 恒 false（未取证），见
//        `kFotoStreamingRangeProven`。两腿都**视频仍内嵌**播放
//        （`fallbackReason` 保持 null）。
//   §5.4 隧道传输在 `tcpPort == 0` 时 `authenticatedUrl` **返回空串**
//        （`webapi.dart` 的 `TunnelTransport.authenticatedUrl`）；
//        自签证书（`certPinned`）下 Media3 走系统信任链 → 握手失败。
library;

import '../../core/i18n/data_text.dart';
import '../../data/drive_api.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/filestation_api.dart';
import '../../data/foto_api.dart';
import '../../data/media/media_format_support.dart';
import '../../dsm/webapi.dart' show DsmApiException, DsmErrorCode;

/// Drive 条目的 path 前缀（`driveEntryAsFile` 把 `file_id` 编进 path）。
///
/// 这是预览页 / Drive 浏览页共用的约定，别在别处再写一遍字面量。
const String kDrivePathPrefix = 'drive:';

/// 从 `FileEntryDto.path` 里拆出 Drive 的 `file_id`（不是 Drive 条目 → null）
String? driveFileIdOf(String path) => path.startsWith(kDrivePathPrefix)
    ? path.substring(kDrivePathPrefix.length)
    : null;

/// 媒体类型（决定"Drive 里能不能内嵌"这类按类型分叉的规则）
enum MediaKind {
  audio('audio'),
  video('video');

  const MediaKind(this.code);
  final String code;
}

/// 取流通道
enum MediaChannel {
  fileStation('file_station'),
  drive('drive'),
  photos('photos'),
  photosTeam('photos_team'),
  chat('chat'),
  other('other');

  const MediaChannel(this.code);
  final String code;
}

/// 为什么**不能**把这条来源交给内置播放器（枚举，调用方不许拿字符串判断）
///
/// [arbKey] / [zh] 优先复用**既有** ARB key；本批只**新增了一个**待落库的 key
/// —— [MediaUnavailableReason.streamRejected] 的 `mediaErrStreamRejected`
/// （本批禁改 `lib/l10n/**`，所以先用 [zh] 回落，清单见
/// docs/media-streaming-diagnosis.md §6）。
/// 界面层用 `context.t` 取同一句（见 `media_reason_text.dart`）。
enum MediaUnavailableReason {
  /// 通道给出了空 URL（还没登录 / 服务端不给直链）
  emptyUrl('empty_url', 'fileOpenFailed', '打不开这个文件'),

  /// 隧道传输没起来（`tcpPort == 0` → `authenticatedUrl` 返回空串）
  tunnelUnavailable(
    'tunnel_unavailable',
    'apiTunnelNotStarted',
    '隧道未启动（tcpPort == 0）',
  ),

  /// 自签证书被固定：Media3（`video_player` / `just_audio`）用系统信任链，握手必失败
  certificateUntrusted(
    'certificate_untrusted',
    'chatStreamUntrustedCertTitle',
    '服务器证书不受信任',
  ),

  /// 该位置不支持 HTTP Range（Drive 写死 `Accept-Ranges: none`）
  rangeUnsupported('range_unsupported', 'fileWhyOther', '这类文件交给系统应用打开'),

  /// 还没有可用的 API（未连接 / 能力表里没有这个模块）
  notConnected('not_connected', 'srvNotConnected', '尚未连接服务器'),

  /// 这个来源没有可用的取流接口
  unsupportedSource('unsupported_source', 'fileWhyOther', '这类文件交给系统应用打开'),

  /// 播放器**运行时**报错（容器/解码器不认识这个流）
  decodeFailed('decode_failed', 'chatErrPlaybackFailed', '播放失败'),

  /// 编码/容器系统解不了（`ERROR_CODE_DECODING_FORMAT_UNSUPPORTED`、
  /// `V_THEORA is not supported`、`UnrecognizedInputFormatException` …）
  ///
  /// 与 [decodeFailed] 分开是为了**说清"为什么"**：前者是兜底，这条能明确告诉
  /// 用户"这个文件的编码系统播放器解不了"，而不是笼统的"播放失败"。
  codecUnsupported(
    'codec_unsupported',
    'mediaErrCodecUnsupported',
    '系统解码器不支持这个文件的编码',
  ),

  /// 拉流阶段的网络失败（连接超时 / 拒绝 / 主机不可达 / 登录态失效后的 403）
  networkFailed(
    'network_failed',
    'mediaErrNetworkFailed',
    '连不上文件地址（网络中断或登录已过期）',
  ),

  /// **取流 URL 缺鉴权 / 会话已失效**（DSM 回 119、401/403，或我们自己的直链
  /// 查询串里没有 `_sid` / `SynoToken`）。
  ///
  /// 为什么必须与 [codecUnsupported] 分开：服务端对"没带 `_sid`/`SynoToken` 的
  /// 下载 URL"回的是 **HTTP 200 + `{"error":{"code":119}}`**，Media3 把这段 JSON
  /// 当成"没有 extractor 能读的流"，于是**正常文件**也被报成"系统解码器不支持
  /// 这个文件的编码"（真机头号误报）。这条说的是"先重新登录 / 拿一条带鉴权的
  /// 直链"，与"文件本身解不了"是两回事。
  sessionExpired('session_expired', 'errSidNotFound', '会话不存在，请重新登录'),

  /// **取流在 HTTP 层就被服务端拒绝 / 拿不到媒体**：HTTP 4xx-5xx
  /// （Media3 `InvalidResponseCodeException`）、`ERROR_CODE_IO_BAD_HTTP_STATUS`、
  /// `ERROR_CODE_IO_FILE_NOT_FOUND`、或"响应根本不是媒体"的容器解析失败
  /// （`ERROR_CODE_PARSING_*`；SynologyPhotos 的 `.so` 自己就会写
  /// `Status: 404 Not Found`）。
  ///
  /// 与另外两类**必须分开**（R5 真机教训，见 docs/media-streaming-diagnosis.md）：
  ///   * [codecUnsupported] = "本机解码器解不了这个编码"（真机 Theora `/ 字幕流）；
  ///   * [networkFailed] = "TCP/DNS 层连不上"（超时、拒连、主机不可达）；
  ///   * 本条 = "连上了，服务端明确拒绝了这一条取流请求" —— 处置是**改取流形态 /
  ///     换通道 / 查服务端权限**，不是"换个播放器"，也不是"等网络恢复"。
  ///
  /// ⚠️ **本条要用的 ARB key `mediaErrStreamRejected` 本批**没有**写进
  /// `lib/l10n/*.arb`**（本批不许碰 ARB）→ 界面层用 [text]（`dataText` 回落中文），
  /// 父 agent 需按 docs/media-streaming-diagnosis.md §6 的清单补 key。
  streamRejected(
    'stream_rejected',
    'mediaErrStreamRejected',
    '服务器拒绝了这一条取流请求（HTTP 4xx/5xx 或返回的不是媒体）',
  ),

  /// **格式本身系统解不了**（容器缺抽取器 / 平台缺解码器），但**存在替代路径**
  /// ——「用其他应用打开」或（音乐库内）服务端转码。
  ///
  /// 与 [codecUnsupported] 的区别（**必须分清，否则又会退回泛化"播放失败"**）：
  ///   * [codecUnsupported] = **事后**由播放器报错判出来的（`Decoder init failed`、
  ///     `V_THEORA is not supported`、`ERROR_CODE_DECODING_FORMAT_UNSUPPORTED`），
  ///     只说"解不了"；
  ///   * 本条 = **事前**按应用级能力登记
  ///     （`lib/src/data/media/media_format_support.dart`）判出来的"这个格式
  ///     已知不在本机播放栈的能力集里"，处置是**换路径**（服务端转码 /
  ///     外部应用），不是"等网络恢复"也不是"重新登录"。
  ///
  /// 判定是 **fail-open** 的：不在清单里的格式绝不会到这条；探针（
  /// [MediaCodecProbe]）说能播时也不会到这条；直链场景事后真的失败时，
  /// [refinePlayerErrorForSource] 会把兜底的 [decodeFailed] 升级成本条。
  ///
  /// ⚠️ ARB key `mediaErrFormatUnsupported` **本批没有**写进 `lib/l10n/*.arb`
  /// （本批禁改 ARB 与 `lib/src/core/i18n/**`）→ 界面层用 [text]（`dataText`
  /// 中文回落），父 agent 按 docs/audio-codec-fallback.md §6 的清单补 key
  /// 与 `dataTextMap` 条目后**自动切译文，不用再改代码**。
  formatUnsupported(
    'format_unsupported',
    'mediaErrFormatUnsupported',
    '这种格式通常不被系统解码器支持（WMA/ASF、APE、WavPack、DSD 等）',
  ),

  /// **这个宿主根本没有本地播放实现** —— 不是文件的问题，也不是网络/解码的
  /// 问题，而是"本仓在这家平台上没有引入播放插件"。
  ///
  /// 为什么必须**单独一条**（第 156 轮 Linux 站真跑发现，见
  /// `docs/platform-linux-ui-audit.md` D1/D2）：Linux 容器里点 Audio Station 的
  /// 播放键，`just_audio` 的 `init` 抛 `MissingPluginException` ⇒ 被泛化兜底成
  /// [decodeFailed]（"播放失败"）⇒ **把"平台没实现"说成了"这个文件放不了"**；
  /// 同一次运行里 `AudioPlayer()` 首次触碰平台还会抛出一个**没人接的**
  /// `disposeAllPlayers`（`just_audio` 在上游用 `try/catch` 包了返回 Future 的
  /// 调用 ⇒ 同步 catch 抓不到异步失败）。处置完全不同：用户能做的只有"换设备 /
  /// 等平台支持"，不该被引导去换格式或重新登录。
  ///
  /// ARB 复用既有的 `capReasonNotImplemented`（**两套 ARB 都已有这条**，中英
  /// 齐全）⇒ 不新增 key、不碰 `lib/l10n/**`。
  platformUnsupported(
    'platform_unsupported',
    'capReasonNotImplemented',
    '此平台尚未实现本地播放',
  ),

  /// **图形栈建不起视频画面**（r690，Linux 站）。
  ///
  /// 现场：容器里 libmpv 的**解码与时间轴都在走**（时长 4.000 s、位置 0→1.2 s），
  /// 但 `media_kit` 的纹理（mpv render context）建不起来 —— `waitUntilFirstFrame
  /// Rendered` 永不完成（llvmpipe/Xvfb 下 Impeller 的 GLES 上下文不与 mpv 共享）。
  /// 表现是**永远转圈/黑屏**，而控件与时间轴看起来都"正常"（典型的「黑屏时钟」
  /// 假绿，AGENTS §2.0.80）。
  ///
  /// 为什么不复用 [decodeFailed]：解码明明成功，说"解不了"是**假归因**；
  /// 用户能做的处置是"换有 GPU 的桌面 / 关掉软件渲染"。
  /// ARB key 走 `dataText` 回落（`mediaErrNoVideoOutput`），不新增 ARB 文件。
  videoOutputUnavailable(
    'video_output_unavailable',
    'mediaErrNoVideoOutput',
    '本机图形栈建不起视频画面（软件渲染或驱动不支持）',
  );

  const MediaUnavailableReason(this.code, this.arbKey, this.zh);

  /// 稳定标识（日志 / 探针 / 测试断言用；界面文案不许靠它判断）
  final String code;

  /// 复用的既有 ARB key
  final String arbKey;

  /// 纯 Dart 环境下的中文回落（Flutter 层用 `context.t` 取同一句）
  final String zh;

  /// 一句中文说明（装了数据层翻译器就是当前语言）
  String get text => dataText(arbKey, zh);
}

/// **本宿主没有本地播放实现**时，播放引擎抛出的类型化错误。
///
/// 为什么要有这个类型（而不是让 `MissingPluginException` 自己飘上来）：
/// `classifyPlayerError` 只能**按文本**认错误，而 `MissingPluginException` 的
/// 文本里没有任何能指向"平台未实现"的词 ⇒ 必然落到兜底的 [decodeFailed]
/// （"播放失败"），把平台结论说成文件结论。有了这个类型，分类器可以**先按类型**
/// 判，再退回文本判（顺序见 `classifyPlayerError` 的注释）。
/// 视频**解码成功、画面建不起来**时抛出的类型化失败（r690，Linux 站）。
///
/// 只在"播放器已经就绪/在走时间轴，但纹理始终没来"时用 —— 与
/// [MediaPlaybackUnsupportedOnHost]（这家平台压根没有实现）不是一回事。
class MediaPlaybackVideoOutputUnavailable implements Exception {
  const MediaPlaybackVideoOutputUnavailable([
    this.detail = '本机图形栈建不起视频画面（软件渲染或驱动不支持）',
  ]);

  /// 人话细节（日志 / 探针用；界面文案走 [MediaUnavailableReason.videoOutputUnavailable]）
  final String detail;

  @override
  String toString() => 'MediaPlaybackVideoOutputUnavailable: $detail';
}

class MediaPlaybackUnsupportedOnHost implements Exception {
  const MediaPlaybackUnsupportedOnHost([
    this.detail = '本平台尚未实现本地播放（本仓未引入该平台的播放插件）',
  ]);

  /// 人话细节（日志 / 探针用；界面文案走 ARB）
  final String detail;

  @override
  String toString() => 'MediaPlaybackUnsupportedOnHost: $detail';
}

/// 会话续期后续播位置的**容差**。
///
/// 语义：[MediaSource.renew] 成功后把播放项重建、再 seek 回"失效前最后已知位置"。
/// 原生播放器的位置事件是 250ms 一 tick（`MediaPlayerBridge.TICK_MS`），而 `119`
/// 往往在最后一个位置 tick **之后**才到 —— 所以"续播位置"与"失效前最后已知位置"
/// 之间允许一个明确的小偏差。取 **1500ms（≈6 个 tick）**：足够吸收上报延迟与
/// 重建播放器的耗时，又远小于人能察觉的"跳了一段"（秒级）。
const Duration kMediaSessionResumeTolerance = Duration(milliseconds: 1500);

/// 自动续期的最大尝试次数（**有界**：绝不无限循环）。
///
/// **2 次**：第一次续期在多数情况下就能成功（`119` → 既有
/// `onSessionExpired` 重登 → 重放一次）。留第二次是为了吸收**瞬时**失败
/// （重登刚发出、服务端会话尚未生效；或网络刚好抖了一下）—— 两次之间的间隔由
/// [mediaSessionRenewDelay] **指数退避**给出。
///
/// 两次都失败 → 一次**都不再自动重试**，退回既有会话失效面板（如实告知用户），
/// 并给一个**手动重试**入口（`MediaFallbackPanel.onRetry`）。这样既不会变成
/// "报错 → 续期 → 报错"的死循环，也不会静默停住。
const int kMediaSessionRenewMaxAttempts = 2;

/// 会话续期失败后**再试一次**之前的退避基准（指数退避）。
///
/// 第 n 次尝试（1-based）**之前**等 [mediaSessionRenewDelay]：第一次不等待
/// （用户已经在等画面回来），第二次等一个 base。500ms ≈ 原生位置 tick 的 2 倍
/// （`MediaPlayerBridge.TICK_MS = 250`），足够跨过"重登刚完成"的瞬时窗口，
/// 又远小于用户察觉"卡住了"的尺度；**不做长退避**是因为用户正看着黑屏。
const Duration kMediaSessionRenewBackoffBase = Duration(milliseconds: 500);

/// 第 [attempt] 次尝试（1-based）之**前**要等的时长（**指数退避**）。
///
/// attempt = 1 → `Duration.zero`（第一次立刻试）；attempt = 2 → base；
/// attempt = n → `base * 2^(n-2)`。因为上界是
/// [kMediaSessionRenewMaxAttempts]，所以这个序列**有限**、不会无限增长。
Duration mediaSessionRenewDelay(int attempt) {
  if (attempt <= 1) return Duration.zero;
  return kMediaSessionRenewBackoffBase * (1 << (attempt - 2));
}

/// 一个可以直接喂给原生播放器的来源。
///
/// [uri] 里 `_sid` / `SynoToken` **都在查询串**（`webapi.dart:638-650`）→
/// 播放器不需要任何自定义头，这也是魅族/安卓原生播放器能直接 seek 的前提。
class MediaSource {
  const MediaSource({
    required this.uri,
    required this.channel,
    required this.kind,
    required this.displayName,
    this.size = 0,
    this.supportsRange = false,
    this.headers,
    this.fallbackReason,
    this.formatGap,
    this.renew,
    this.fallback,
    this.probeSessionCode,
  });

  /// 完整鉴权 URL
  final String uri;

  final MediaChannel channel;
  final MediaKind kind;
  final String displayName;
  final int size;

  /// 服务端是否支持 HTTP Range（= 进度条能不能真的拖）
  final bool supportsRange;

  /// 少数场景才需要（本项目推荐的通道全是查询串鉴权 → 默认 null）
  final Map<String, String>? headers;

  /// 非 null = **不进**内置播放器，直接走"下载后交给系统应用"
  final MediaUnavailableReason? fallbackReason;

  /// 这条来源命中的**已知格式缺口**登记（
  /// `lib/src/data/media/media_format_support.dart`）。
  ///
  /// 用途只有一个：直链场景**探针说能播**（fail-open → 不拦）而事后真的失败时，
  /// [refinePlayerErrorForSource] 用把兜底的 [MediaUnavailableReason.decodeFailed]
  /// 升级成 [MediaUnavailableReason.formatUnsupported]，让面板说对"是格式问题、
  /// 换条路"，而不是笼统的"播放失败"。
  ///
  /// null = 这个格式不在缺口清单里（**绝大多数文件**）。
  final MediaFormatGap? formatGap;

  /// 会话续期：用**既有**会话/凭据（必要时经既有 `onSessionExpired` 重登）
  /// 重新解析出**同一个文件**、带**新** `_sid` / `SynoToken` 的直链。
  ///
  /// null = 这个来源没有"原地续期"能力（相册（未接 renewer）/ Drive /
  /// 聊天附件等来源）—— 那就**不假装能续播**，继续走既有会话失效面板
  /// （见 [shouldRenewSession]）。
  ///
  /// ⚠️ 契约：返回来源的 [kind] / [channel] / [supportsRange] 必须与原件一致，
  /// 只有查询串里的凭据是新的；[renew] 自身也要能被再次调用。凭据**只**存在于
  /// URL 查询串里，**绝不**明文写日志/文档/测试夹具（`webapi.dart:638-650`）。
  final Future<MediaSource> Function()? renew;

  /// **通道回退**：这条来源取流失败（服务端拒绝 / 拿到的不是媒体 / 解不了）时，
  /// 下一个可以原地重试的**同文件**来源；全链路失败才给用户面板。
  ///
  /// 目前唯一的用户 = 相册视频：官方对"原生 mp4/h264"走 `SYNO.Foto.Download`
  /// （`quality="raw"`），失败才退回 `SYNO.Foto.Streaming & type=item`（转码档）。
  /// 见 [resolvePhotosSource] 与 docs/media-streaming-diagnosis.md §1.2。
  ///
  /// 契约：与主来源同 [kind] / [channel]（[supportsRange] 也保持一致）；
  /// null = 没有下一跳。
  final MediaSource? fallback;

  /// 取流失败后，用**同一鉴权字节链路**复核服务端到底回了什么
  /// （`SYNO.Foto.Download` / FileStation `Download` 等直链的应答体）。
  ///
  /// 为什么必须复核（R7-13-B 真机教训）：服务端用 **`HTTP 200` + DSM JSON 信封**
  /// 承载 `119`（SID 不存在）时，Media3 嗅探到的是"不是媒体"，只报
  /// `ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED`（`sniff failures: [NoDeclaredBrand]`）
  /// —— 错误串里**没有** `119`，`classifyPlayerError` 只能归 [streamRejected]。
  /// 用 `DsmWebApi.getBytes` 复核应答体，[DsmApiException] 会把 119/106 还原出来
  /// （`webapi.dart` 的 `_bytesOf` 已识别 200+JSON 信封）→ 归 [sessionExpired]
  /// 并触发既有自动续期。
  ///
  /// 返回 119/106（会话语义）；null = 复核不到会话语义（真·服务端拒绝 / 网络层）。
  final Future<int?> Function()? probeSessionCode;

  /// 能交给内置播放器播
  bool get playable => fallbackReason == null && uri.isNotEmpty;

  /// 能播**且**能拖进度
  bool get seekable => playable && supportsRange;

  /// 能播但**拖不动**（Drive 音频）：界面要把滑块置灰并说清原因
  bool get streamingOnly => playable && !supportsRange;

  /// 不可播时的原因（可播 → null）
  MediaUnavailableReason? get reason => playable ? null : fallbackReason;

  @override
  String toString() =>
      'MediaSource(${channel.code}/${kind.code}, range=$supportsRange, '
      'playable=$playable, formatGap=${formatGap?.extension}, '
      'fallback=${fallbackReason?.code})';
}

/// 这次播放失败**要不要**尝试"原地续期续播"。
///
/// 三个条件缺一不可：
///   * [MediaUnavailableReason.sessionExpired] —— 复用 `classifyPlayerError`
///     的**同一判定**（网络中断在那一层已经被分到
///     [MediaUnavailableReason.networkFailed]，这里不重新判）；
///   * `supportsRange == true` —— **不能 seek 就没有"原位置"可回**：Drive（写死
///     `Accept-Ranges: none`）/ 聊天附件 / 相册 `Streaming` 腿（Range 未取证）
///     一律走既有会话失效面板，**不假装能续播**（硬约束）；
///   * 有 [MediaSource.renew] —— 能拿出带新 `_sid` 的直链。FileStation 用
///     `fs.info()`，相册 Download 腿用官方播放素材请求 `Browse.Item/get`
///     （见 [resolvePhotosSource] / `_renewPhotosSource`）；Drive /
///     相册 Streaming 腿 / 聊天附件都没有 → 不假装能续播，走既有面板。
///
/// 注意 `119`（SID 不存在）属"会话失效"：这里只做**自动续期**，**绝不**改变
/// "会话失效绝不隐藏模块/tab"的语义（见 `service_registry.dart`）。
bool shouldRenewSession(MediaSource source, MediaUnavailableReason reason) =>
    reason == MediaUnavailableReason.sessionExpired &&
    source.supportsRange &&
    source.renew != null;

/// 复核应答体用的**字节取回器**（只取头一小段，绝不整段下载）。
typedef MediaProbeFetcher =
    Future<List<int>> Function(String url, {int? maxBytes});

/// 媒体取流失败后，复核服务端**应答体**里的会话语义码。
///
/// 只用 `DsmWebApi.getBytes` 这条**既有**鉴权字节链路（它不触发自动重登，
/// 所以能把原始 119 如实抛出来）：
///   * 应答体是 DSM 的 JSON 错误信封（`{"success":false,"error":{"code":119}}`，
///     常配 `HTTP 200`）→ `_bytesOf` 抛 [DsmApiException] → 返回 119/106；
///   * 真媒体字节 / 网络层异常 / 其它错误码 → 返回 null（不篡改既有分类）。
///
/// R7-13-B 真机：`--download-error=119` 的首包就是 200+JSON 信封，Media3 只报
/// `ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED`（错误串里没有 119），本复核把会话
/// 语义还原出来，上层才能归 [MediaUnavailableReason.sessionExpired] 并自动续期。
Future<int?> probeMediaSessionCode(String url, MediaProbeFetcher fetch) async {
  try {
    await fetch(url, maxBytes: 1024);
    return null;
  } on DsmApiException catch (e) {
    return e.code;
  } catch (_) {
    return null;
  }
}

/// 复核结果是不是**会话语义**（119 SID 不存在 / 106 会话超时）。
bool isMediaSessionCode(int? code) =>
    code == DsmErrorCode.sidNotFound || code == DsmErrorCode.sessionTimeout;

/// 这次运行时失败**要不要**换下一跳（[MediaSource.fallback]）。
///
/// 不换的两类：
///   * [MediaUnavailableReason.sessionExpired] —— 属会话层，先走自动续期；
///     对没有 renewer 的来源（相册）换通道也只会重复同一个会话错误；
///   * [MediaUnavailableReason.networkFailed] —— TCP/DNS 层，换 URL 不会更好。
///
/// 其余（取流被拒 / 拿到的不是媒体 / 解不了）都是"这条 URL 形态不对"的证据，
/// 正是换通道要解决的。
bool shouldTryFallbackSource(
  MediaSource source,
  MediaUnavailableReason reason,
) {
  if (source.fallback == null) return false;
  return reason != MediaUnavailableReason.sessionExpired &&
      reason != MediaUnavailableReason.networkFailed;
}

MediaSource _blocked({
  required MediaChannel channel,
  required MediaKind kind,
  required String displayName,
  required int size,
  required MediaUnavailableReason reason,
}) => MediaSource(
  uri: '',
  channel: channel,
  kind: kind,
  displayName: displayName,
  size: size,
  fallbackReason: reason,
);

/// 查询串里有没有 `_sid`（会话 id）。
///
/// 原生播放器只吃 URL：**没有 `_sid` 的 URL 一定拿不到文件**（服务端回 119），
/// 所以"交给播放器之前"必须能自查。用 `Uri.queryParameters` 而不是字符串
/// `contains`：`path` 参数里恰好出现 `_sid=` 的假阳性要排除。
bool urlHasSid(String url) => _queryValue(url, '_sid') != null;

/// 查询串里有没有 `SynoToken`（DSM 7.4 的 CSRF；原生播放器发不了自定义头）。
bool urlHasSynoToken(String url) => _queryValue(url, 'SynoToken') != null;

String? _queryValue(String url, String key) {
  if (url.isEmpty) return null;
  final params = Uri.tryParse(url)?.queryParameters;
  final v = params?[key];
  return (v == null || v.isEmpty) ? null : v;
}

/// 带鉴权的直链是**我们自己拼的**才做自检（调用方直接给的 URL 不做，
/// 见 [resolveDriveSource] 的 `url` 与 [resolveOtherSource]）。
MediaSource _withUrl({
  required String url,
  required MediaChannel channel,
  required MediaKind kind,
  required String displayName,
  required int size,
  required bool supportsRange,
  bool tunnelTransport = false,
  bool certPinned = false,
  MediaUnavailableReason? videoFallback,
  Future<MediaSource> Function()? renew,
  MediaSource? fallback,
  Future<int?> Function()? probeSessionCode,
  // 下面两个是"拼 URL 的通道"的自检开关（见 `urlHasSid` / `urlHasSynoToken`）
  bool requireSid = false,
  bool requireSynoToken = false,
  // 设备能力探针（fail-open 的唯一升级口；null = 用全局探针/未知）
  MediaCodecProbe? probe,
}) {
  if (certPinned) {
    return _blocked(
      channel: channel,
      kind: kind,
      displayName: displayName,
      size: size,
      reason: MediaUnavailableReason.certificateUntrusted,
    );
  }
  if (url.isEmpty) {
    return _blocked(
      channel: channel,
      kind: kind,
      displayName: displayName,
      size: size,
      reason: tunnelTransport
          ? MediaUnavailableReason.tunnelUnavailable
          : MediaUnavailableReason.emptyUrl,
    );
  }
  // 非空但**缺鉴权**：绝不把裸 URL 交给 Media3（它只会报"没有 extractor 能读"，
  // 看起来像编码不支持）——直接说"会话过期 / 请重新登录"。
  if ((requireSid && !urlHasSid(url)) ||
      (requireSynoToken && !urlHasSynoToken(url))) {
    return _blocked(
      channel: channel,
      kind: kind,
      displayName: displayName,
      size: size,
      reason: MediaUnavailableReason.sessionExpired,
    );
  }
  // **已知格式缺口**（WMA/ASF、APE、WavPack、DSD、RM、MIDI…）：
  // 直链场景没有转码通道，提前说清"是格式问题 + 用其他应用打开"，
  // 而不是把 URL 交给 Media3 换一句笼统的"播放失败"。
  //
  // ⚠️ 顺序：排在证书/空 URL/缺鉴权**之后** —— 那三条说明"这一条根本取不到"，
  // 比"格式可能解不了"更根本。fail-open：`probe` 说能播时这里整段跳过
  // （见 `media_format_support.dart` 的契约）。
  if (mediaFormatNeedsFallback(displayName, probe: probe)) {
    return _blocked(
      channel: channel,
      kind: kind,
      displayName: displayName,
      size: size,
      reason: MediaUnavailableReason.formatUnsupported,
    );
  }
  return MediaSource(
    uri: url,
    channel: channel,
    kind: kind,
    displayName: displayName,
    size: size,
    supportsRange: supportsRange,
    renew: renew,
    fallback: fallback,
    probeSessionCode: probeSessionCode,
    // 命中的登记照实带上：事后失败时 [refinePlayerErrorForSource] 靠它升级理由
    formatGap: mediaFormatGapOf(displayName),
    // 「能播但拖不动」且是视频时，不内嵌（从头顺序缓冲 ≡ 不能拖，体验更差）
    fallbackReason: videoFallback != null && kind == MediaKind.video
        ? videoFallback
        : null,
  );
}

/// **主通道**：FileStation `SYNO.FileStation.Download` 直链。
///
/// 唯一同时满足「任意文件 + 真机实测支持 Range + 本机已装」的通道（调研 §3.1）。
///
/// 因为真机实测支持 206，这条通道**也**是唯一能"会话失效 → 原地续播"的来源：
/// 返回的 [MediaSource.renew] 先走一次轻量鉴权请求
/// （`SYNO.FileStation.Info/get`），它在 sid 失效时会被 `DsmWebApi.call` 的既有
/// `onSessionExpired` 链路**自动重登并重放**（`session_controller.dart:401`），
/// 然后用**新** sid 重新拼出流地址 —— 上层拿到新地址后重建播放项并 seek 回原位。
MediaSource resolveFileStationSource({
  required String displayName,
  required MediaKind kind,
  required FileStationApi? fs,
  required String path,
  int size = 0,
  bool certPinned = false,
  bool tunnelTransport = false,
  MediaCodecProbe? probe,
}) {
  if (fs == null) {
    return _blocked(
      channel: MediaChannel.fileStation,
      kind: kind,
      displayName: displayName,
      size: size,
      reason: MediaUnavailableReason.notConnected,
    );
  }
  final url = fs.downloadUrl([path]);
  return _withUrl(
    url: url,
    channel: MediaChannel.fileStation,
    kind: kind,
    displayName: displayName,
    size: size,
    supportsRange: true,
    certPinned: certPinned,
    tunnelTransport: tunnelTransport,
    probe: probe,
    // URL 是我们拼的 → 自查（缺 `_sid`/`SynoToken` 时不许交给播放器）
    requireSid: true,
    requireSynoToken: fs.api.hasSynoToken,
    // R7-13-B：`200 + JSON 119` 被 Media3 当成"不是媒体"时，用同一鉴权字节
    // 链路复核应答体，把会话语义还原出来（见 [probeMediaSessionCode]）。
    probeSessionCode: () => probeMediaSessionCode(
      url,
      (u, {maxBytes}) => fs.api.getBytes(u, maxBytes: maxBytes),
    ),
    renew: () => _renewFileStationSource(
      displayName: displayName,
      kind: kind,
      fs: fs,
      path: path,
      size: size,
      certPinned: certPinned,
      tunnelTransport: tunnelTransport,
      probe: probe,
    ),
  );
}

/// FileStation 的**会话续期**：先确保会话有效，再用新 `_sid` 重拼直链。
///
/// 1. `fs.info()` 是一次轻量鉴权请求。若当前 `_sid` 已失效，`DsmWebApi.call`
///    会走**既有**的"119 → `onSessionExpired` 重登 → 重放一次"链路
///    （105 已不再触发，见 `DsmErrorCode.retryLoginCodes` 的 R6 说明）；
///    重登失败（没有凭据 / 密码已失效）会抛出，
///    于是上层退回既有会话失效面板 —— 这正是要求的"续期失败才提示重新登录"。
/// 2. `authenticatedUrl` 每次都读**当前** session（`webapi.dart:1499-1500`），
///    所以第 2 步重新解析出的直链带的是重登后的新 `_sid` / `SynoToken`。
///
/// ⚠️ `_sid` / `SynoToken` 只出现在 URL 查询串里，**不**打印、**不**落盘。
Future<MediaSource> _renewFileStationSource({
  required String displayName,
  required MediaKind kind,
  required FileStationApi fs,
  required String path,
  required int size,
  required bool certPinned,
  required bool tunnelTransport,
  MediaCodecProbe? probe,
}) async {
  await fs.info();
  return resolveFileStationSource(
    displayName: displayName,
    kind: kind,
    fs: fs,
    path: path,
    size: size,
    certPinned: certPinned,
    tunnelTransport: tunnelTransport,
    probe: probe,
  );
}

/// Drive 通道：**明确不支持 Range**（调研 §3.4，30 个 `.so` 全写死 `none`）。
///
/// 所以：音频仍然内嵌播（能听），但 `supportsRange = false`、滑块必须置灰；
/// 视频不内嵌（顺序缓冲等于不能拖），降级为"下载后交给系统应用"。
MediaSource resolveDriveSource({
  required String displayName,
  required MediaKind kind,
  String fileId = '',
  String? url,
  DriveApi? drive,
  int size = 0,
  bool certPinned = false,
  bool tunnelTransport = false,
  MediaCodecProbe? probe,
}) {
  final builtByUs = url == null || url.isEmpty;
  final built = builtByUs
      ? (drive == null || fileId.isEmpty
            ? ''
            : drive.downloadUrl(fileId: fileId))
      : url;
  if (built.isEmpty && drive == null && (url == null || url.isEmpty)) {
    return _blocked(
      channel: MediaChannel.drive,
      kind: kind,
      displayName: displayName,
      size: size,
      reason: MediaUnavailableReason.notConnected,
    );
  }
  return _withUrl(
    url: built,
    channel: MediaChannel.drive,
    kind: kind,
    displayName: displayName,
    size: size,
    supportsRange: false,
    certPinned: certPinned,
    tunnelTransport: tunnelTransport,
    probe: probe,
    videoFallback: MediaUnavailableReason.rangeUnsupported,
    // 只有"我们自己拼的"才自检；调用方给的直链（`url`）由调用方负责
    requireSid: builtByUs,
    requireSynoToken: builtByUs && (drive?.api.hasSynoToken ?? false),
    // 与 FileStation 同源的会话语义复核（`200 + JSON 119` 被当成"不是媒体"时）
    probeSessionCode: !builtByUs || drive == null
        ? null
        : () => probeMediaSessionCode(
            built,
            (u, {maxBytes}) => drive.api.getBytes(u, maxBytes: maxBytes),
          ),
  );
}

/// Photos 通道：**优先官方"原文件"端点 `SYNO.Foto.Download`（`quality="raw"`）**，
/// 失败才回退到转码档端点 `SYNO.Foto.Streaming & type=item`（R7 修正）。
///
/// ### 为什么 Download 优先（官方 JS 逐字证据，见 docs/media-streaming-diagnosis.md §1.2）
/// 官方视频播放器的 URL 选择器（`ui/react_bundle.js` 偏移 2626646）在
/// `"raw"===quality` 时调用的就是 `Download`（`u9`，偏移 2544763），而
/// `QT`/`p`（偏移 2205966）对"`mp4` + `h264` + 支持的音轨"直接给 `"raw"`
/// —— R7 真机那个 `clip-h264.mp4` 正是这种。`Streaming` 的 `quality` 白名单
/// 每一项都是 `video_convert` 里的**转码产物**，"原文件"没有对应档位。
/// R7 真机也印证了：`Streaming&type=item` 在 131 ms 内被服务端拒绝
/// （`ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED` + `NoDeclaredBrand`），
/// 而同一编码的文件通道能播 ⇒ 是**通道选择**问题，不是编码问题。
///
/// ### 回退链与顺序理由
/// 1. `Download`（官方"raw"路线，最可能是原文件）；
/// 2. 失败 → `Streaming & type=item`（官方转码档路线的兜底；`type` 必填，
///    见 §1.1。不猜 `quality`：猜一个不存在的档只会 404）；
/// 3. 再失败 → 用户面板（既有 [MediaUnavailableReason] 分类）。
///
/// ⚠️ **第二跳的真机状态：未取证 / 很可能不可用**（2026-09-22，
/// `docs/live-nas-verification.md` §4.4）。`Streaming:streaming` 必填
/// `quality` 字符串枚举，真机 14 个候选值全被拒（`120 reason:"condition"`）；
/// 不带 `quality` 直接 `120 reason:"required"` → 本仓库这条第二跳在真机上
/// **拿不到流**。我们**仍然保留它**（等 `quality` 枚举取证后再定），但在
/// 文案上必须说成"**服务端拒绝了这一条取流请求**"（[streamRejected]）——
/// **不许**说成"格式不支持/编码解不了/文件损坏"，也**不许**暗示"服务端没这个
/// 功能"（功能在，档位未解）。这是"通道未取证"，不是"文件的问题"。
///
/// 顺序有理由：先把**官方对原生格式实际使用**的端点放第一跳；`Streaming` 只在
/// 官方明知有某档转码产物时才用，作为"Download 被拒"的兜底而非首选。
/// 回退由 `MediaPlayerView` 在**同一页面原地**执行（[MediaSource.fallback]），
/// 不重新走用户点击，也不改变内嵌产品定位。
///
/// ### Range（**真机已证，但只是 Download 那条腿**）
/// 2026-09-22 真机（`docs/live-nas-verification.md` §4.3）：`Download:download`
/// + `Range: bytes=0-1023` → **`206` + `Content-Range: bytes 0-1023/1876693`**，
/// 4 种 Range 形态全 `206`、越界 `416 + bytes */len` —— 满足任务书"只有拿到
/// 206 + 正确 Content-Range 才可记 true"的判据。
/// 所以 [downloadRangeProven] **默认 true**（[MediaSource.supportsRange] →
/// 可拖/可定位）。
///
/// `Streaming` 那条腿**没有**任何真机字节证据 → 恒为
/// [kFotoStreamingRangeProven]（false），**绝不**跟着 Download 一起打开。
///
/// [itemId] 是 `Browse.Item/list` / `Browse.Item/get` 的 **item id**。官方 `u9`
/// 对 Item 种类发的是 **`item_id=[…]`**（不是 `unit_id`），本方法照此构造。
MediaSource resolvePhotosSource({
  required String displayName,
  required MediaKind kind,
  required String itemId,
  FotoApi? foto,
  bool team = false,
  int size = 0,
  bool certPinned = false,
  bool tunnelTransport = false,
  /// 相册 **Download 主源**的 Range 证据。
  ///
  /// 默认 **true**：2026-09-22 真机已拿到 `206` + 正确 `Content-Range`
  /// （`docs/live-nas-verification.md` §4.3）。传 false 只用于回归/对照。
  bool downloadRangeProven = true,
  /// 相册视频**画质档**（`Streaming` 的 `quality` 参数）。
  ///
  /// 来源必须是该 unit `video_convert` 里**真实存在**的档位短名
  /// （`chooseFotoVideoPlayback` 的输出）。**绝不传 `raw`/`original`** ——
  /// 官方的"原文件"分支走 Download，根本不经 Streaming（见
  /// `docs/photo-p0-implementation.md`）。
  String? streamingQuality,
  /// true → **Streaming 主源**（官方 HIGHEST/LOWEST 转码档）/ Download 兜底；
  /// false（默认）→ Download 主源 / Streaming 兜底。
  bool streamingPrimary = false,
  MediaCodecProbe? probe,
}) {
  final channel = team ? MediaChannel.photosTeam : MediaChannel.photos;
  if (foto == null || itemId.isEmpty) {
    return _blocked(
      channel: channel,
      kind: kind,
      displayName: displayName,
      size: size,
      reason: foto == null
          ? MediaUnavailableReason.notConnected
          : MediaUnavailableReason.unsupportedSource,
    );
  }
  final fotoApi = foto.inSpace(team ? FotoSpace.team : FotoSpace.personal);
  final downloadUrl = fotoApi.downloadUrl(itemId: itemId);
  // `quality` 只可能是 `video_convert` 里真实存在的档（且永不为 raw/original）
  final streamingUrl = fotoApi.streamingUrl(
    itemId: itemId,
    quality: streamingQuality,
  );

  /// 相册的**会话续期**：轻量鉴权 ping + 用新 `_sid` 重拼直链。
  ///
  /// 只有**可 seek 的腿**（Download，`supportsRange = downloadRangeProven`）会拿它；
  /// Streaming 腿恒 `supportsRange = false` → `shouldRenewSession` 永为 false，
  /// 所以那条腿**不接** renewer（接了也不会被调用，属于死代码）。
  Future<MediaSource> renewPhotos() => _renewPhotosSource(
    displayName: displayName,
    kind: kind,
    itemId: itemId,
    foto: foto,
    team: team,
    size: size,
    certPinned: certPinned,
    tunnelTransport: tunnelTransport,
    downloadRangeProven: downloadRangeProven,
    streamingQuality: streamingQuality,
    streamingPrimary: streamingPrimary,
    probe: probe,
  );

  MediaSource buildStreaming() => _withUrl(
    url: streamingUrl,
    channel: channel,
    kind: kind,
    displayName: displayName,
    size: size,
    // ⚠️ Streaming 通道 Range **未取证**（真机零字节）→ 恒 false
    supportsRange: kFotoStreamingRangeProven,
    certPinned: certPinned,
    tunnelTransport: tunnelTransport,
    probe: probe,
    requireSid: true,
    requireSynoToken: foto.api.hasSynoToken,
    probeSessionCode: () => probeMediaSessionCode(
      streamingUrl,
      (u, {maxBytes}) => foto.api.getBytes(u, maxBytes: maxBytes),
    ),
  );

  MediaSource buildDownload() => _withUrl(
    url: downloadUrl,
    channel: channel,
    kind: kind,
    displayName: displayName,
    size: size,
    // Range 真机已证（206 + Content-Range）→ 可拖动 / 可定位
    supportsRange: downloadRangeProven,
    certPinned: certPinned,
    tunnelTransport: tunnelTransport,
    probe: probe,
    requireSid: true,
    requireSynoToken: foto.api.hasSynoToken,
    probeSessionCode: () => probeMediaSessionCode(
      downloadUrl,
      (u, {maxBytes}) => foto.api.getBytes(u, maxBytes: maxBytes),
    ),
    // 可 seek → 会话失效时能原地续期续播（见 [shouldRenewSession]）
    renew: renewPhotos,
  );

  if (streamingPrimary && streamingQuality != null) {
    // 速度优先 / 自动(非 Wi-Fi)：官方选的是**转码档** → Streaming 主源，
    // Download（原文件）兜底。
    final download = buildDownload();
    return _withUrl(
      url: streamingUrl,
      channel: channel,
      kind: kind,
      displayName: displayName,
      size: size,
      supportsRange: kFotoStreamingRangeProven,
      certPinned: certPinned,
      tunnelTransport: tunnelTransport,
      probe: probe,
      requireSid: true,
      requireSynoToken: foto.api.hasSynoToken,
      probeSessionCode: () => probeMediaSessionCode(
        streamingUrl,
        (u, {maxBytes}) => foto.api.getBytes(u, maxBytes: maxBytes),
      ),
      fallback: download.playable ? download : null,
    );
  }

  final fallback = buildStreaming();
  return _withUrl(
    url: downloadUrl,
    channel: channel,
    kind: kind,
    displayName: displayName,
    size: size,
    // Range 真机已证（206 + Content-Range）→ 可拖动 / 可定位
    supportsRange: downloadRangeProven,
    certPinned: certPinned,
    tunnelTransport: tunnelTransport,
    probe: probe,
    requireSid: true,
    requireSynoToken: foto.api.hasSynoToken,
    probeSessionCode: () => probeMediaSessionCode(
      downloadUrl,
      (u, {maxBytes}) => foto.api.getBytes(u, maxBytes: maxBytes),
    ),
    // 可 seek → 会话失效时能原地续期续播（见 [shouldRenewSession]）
    renew: renewPhotos,
    // ② 失败 → Streaming（官方转码档兜底，`type=item`；真机未取证/很可能不可用）
    fallback: fallback.playable ? fallback : null,
    // ⚠️ Download 腿**已接** renewer（上面那行）：Range 真机已证（可 seek），
    // 所以"会话失效 → 重登 → 重拼直链 → seek 回原位"这条链路成立。
    // Streaming 腿（`supportsRange = false`）**不接** —— 不能 seek 就没有
    // "原位置"可回，硬约束见 [shouldRenewSession]。
  );
}

/// 相册的**会话续期**：轻量鉴权 ping + 用新 `_sid` 重拼直链。
///
/// 1. `videoPlaybackInfo()` 是**既有**的官方播放素材请求
///    （`SYNO.Foto.Browse.Item/get`，`photo_providers.dart` 选画质时已在用）。
///    这里借它走一遍**同一条鉴权链路**：当前 `_sid` 失效时，`DsmWebApi.call`
///    会走既有的"119 → `onSessionExpired` 重登 → 重放一次"
///    （`session_controller` 安装的那条）；重登失败（没有凭据 / 口令失效）抛出
///    → 上层退回既有会话失效面板。
/// 2. 重登成功后重新 [resolvePhotosSource]：`authenticatedUrl` 每次都读**当前**
///    session（`webapi.dart` 的 `TunnelTransport` / `DsmWebApi`）→ 重拼出的
///    Download 直链带**新** `_sid` / `SynoToken`。
///
/// 契约与 FileStation 的 [MediaSource.renew] 一致：返回来源的
/// `kind` / `channel` / `supportsRange` 与原来源相同，只有凭据是新的；
/// 幂等、可被再次调用（重试时就是这么用的）。
///
/// ⚠️ `_sid` / `SynoToken` 只出现在 URL 查询串里，**不**打印、**不**落盘。
/// ⚠️ `itemId` 不是数字时 `videoPlaybackInfo` 走既有早退分支（不发请求）→
/// 拿不到新会话 → 有界重试后如实退回面板（**不**假装续播成功）。
Future<MediaSource> _renewPhotosSource({
  required String displayName,
  required MediaKind kind,
  required String itemId,
  required FotoApi foto,
  required bool team,
  required int size,
  required bool certPinned,
  required bool tunnelTransport,
  required bool downloadRangeProven,
  required String? streamingQuality,
  required bool streamingPrimary,
  required MediaCodecProbe? probe,
}) async {
  // 与 [resolvePhotosSource] 内部同一空间（个人 / 团队）
  await foto
      .inSpace(team ? FotoSpace.team : FotoSpace.personal)
      .videoPlaybackInfo(itemId);
  return resolvePhotosSource(
    displayName: displayName,
    kind: kind,
    itemId: itemId,
    foto: foto,
    team: team,
    size: size,
    certPinned: certPinned,
    tunnelTransport: tunnelTransport,
    downloadRangeProven: downloadRangeProven,
    streamingQuality: streamingQuality,
    streamingPrimary: streamingPrimary,
    probe: probe,
  );
}

/// 其它来源（聊天附件等）：调用方已经拿到一条直链，但 Range **未知**
/// → 不假装能拖。
MediaSource resolveOtherSource({
  required String displayName,
  required MediaKind kind,
  required String? url,
  MediaChannel channel = MediaChannel.chat,
  int size = 0,
  bool certPinned = false,
  bool tunnelTransport = false,
  MediaCodecProbe? probe,
}) => _withUrl(
  url: url ?? '',
  channel: channel,
  kind: kind,
  displayName: displayName,
  size: size,
  supportsRange: false,
  certPinned: certPinned,
  tunnelTransport: tunnelTransport,
  probe: probe,
  videoFallback: MediaUnavailableReason.rangeUnsupported,
);

/// 文件预览页的统一入口：按 `path` / 直链判断该走哪条通道。
///
/// * `drive:<file_id>` → Drive（`supportsRange = false`）；
/// * 给了 [bytesUrl]（非 FileStation 来源已经拼好的直链）→ 其它通道；
/// * 其余 → FileStation `Download` 直链（**主通道**，可拖）。
MediaSource resolveEntryMediaSource({
  required FileEntryDto entry,
  required MediaKind kind,
  FileStationApi? fs,
  DriveApi? drive,
  String? bytesUrl,
  bool certPinned = false,
  bool tunnelTransport = false,
  MediaCodecProbe? probe,
}) {
  final driveId = driveFileIdOf(entry.path);
  if (driveId != null) {
    return resolveDriveSource(
      displayName: entry.name,
      kind: kind,
      fileId: driveId,
      url: bytesUrl,
      drive: drive,
      size: entry.size,
      certPinned: certPinned,
      tunnelTransport: tunnelTransport,
      probe: probe,
    );
  }
  if (bytesUrl != null && bytesUrl.isNotEmpty) {
    return resolveOtherSource(
      displayName: entry.name,
      kind: kind,
      url: bytesUrl,
      channel: MediaChannel.other,
      size: entry.size,
      certPinned: certPinned,
      tunnelTransport: tunnelTransport,
      probe: probe,
    );
  }
  return resolveFileStationSource(
    displayName: entry.name,
    kind: kind,
    fs: fs,
    path: entry.path,
    size: entry.size,
    certPinned: certPinned,
    tunnelTransport: tunnelTransport,
    probe: probe,
  );
}

/// **事后**修正播放器给的失败原因：这条来源命中了[已知格式缺口]
/// （[MediaSource.formatGap]）、但播放器只给了**笼统的兜底**
/// [MediaUnavailableReason.decodeFailed] 时，升级成
/// [MediaUnavailableReason.formatUnsupported]。
///
/// 为什么需要它（fail-open 的另一半）：探针说"能播"时我们**不拦**直链，
/// 但如果真播不了，Media3 对 ASF 之类只会说
/// `None of the available extractors … could read the stream` —— 那串文本与
/// "响应根本不是媒体"（取流被拒）**无法区分**，`classifyPlayerError` 因此只能
/// 退回中性的 `decodeFailed`。带上 [MediaSource.formatGap] 这一条**结构化**事实
/// 之后，面板就能说"是格式问题、换条路"，而不是"播放失败"。
///
/// **只升级 `decodeFailed`**：会话失效 / 网络中断 / 服务端拒绝这三类更具体，
/// 必须原样保留（否则又会把取流问题说成格式问题 —— 那是 R5 的头号误报）。
MediaUnavailableReason refinePlayerErrorForSource(
  MediaSource source,
  MediaUnavailableReason reason,
) {
  if (source.formatGap == null) return reason;
  return reason == MediaUnavailableReason.decodeFailed
      ? MediaUnavailableReason.formatUnsupported
      : reason;
}

/// 传输是不是"隧道"（`TunnelTransport.authenticatedUrl` 在 `tcpPort == 0` 返回空串）
///
/// 只用来把"空 URL"翻译成更准确的原因（§5.4 第 2 条）；判断依据是传输自己的
/// `describeKind`，不是猜 URL 形状。
/// ★ r645（**DA244**）：给人看的"名字"，去掉**容器格式**那截扩展名。
///
/// 为什么放在这里：顶栏、播放器标题、投屏描述都会用到同一份名字，
/// 三处各写一遍 `split('.')` 迟早不一致（DA232 那类"同一件事两处两种读数"）。
///
/// 规则（都很保守，宁可不删也不乱删）：
///   * 只在**最后一段点**后面是"像扩展名"的东西（1–5 个字母数字）时才去掉；
///   * 以点开头的隐藏文件（`.nomedia`）、没有点的名字、`第1.5集` 这种
///     **最后一段是纯数字**的，一律原样返回 —— 数字不是扩展名。
String mediaNameWithoutExtension(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return name;
  final ext = name.substring(i + 1);
  if (ext.length > 5) return name;
  final looksLikeExt = RegExp(r'^[A-Za-z][A-Za-z0-9]{0,4}$').hasMatch(ext);
  return looksLikeExt ? name.substring(0, i) : name;
}

bool isTunnelTransport(String describeKind) =>
    describeKind.startsWith('tunnel(');
