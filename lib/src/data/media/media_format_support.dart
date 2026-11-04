// 「**系统解码器通常解不了**」的音视频格式：**应用级能力登记**（纯逻辑层）。
//
// 为什么需要它（用户报告「wma 这种音频格式不支持」的根因）：
//   1. `lib/src/data/audio_station.dart` 的 `defaultStreamMode` 把 `wma` 放进了
//      **直放集合**，于是音乐库里的 WMA 走 `method=stream` 直传 → Media3 里没有
//      ASF 抽取器 → 起播即失败（用户看到的就是"不支持"）；
//   2. FileStation 直链侧（不在音乐库）以前只会让 Media3 抛
//      `None of the available extractors … could read the stream`，最后落进
//      笼统的"播放失败"，用户与排查都被带偏。
//
// 本清单**只**用于两件事：
//   * AudioStation 侧：把这类格式**改走服务端转码**（官方 `method=transcode`，
//     见 docs/stage2-audio-download-api.md §2.3 A-1b）—— 这是官方正视路径；
//   * FileStation/Drive/相册直链侧：**提前**给出可理解提示 + 更优路径
//     （「用其他应用打开」），而不是事后落进泛化"播放失败"。
//
// ★ **fail-open 契约（硬要求，改本文件前先读）**：
//   * 不在本清单里的格式**一律**按"能直放"处理，**绝不**因为本清单改道；
//     清单是"已知缺口"，**不是**白名单。
//   * 判定可被 [MediaCodecProbe] **推翻**：探针给出肯定结论（`true`）时，
//     本模块一律返回 false（走直链）。探针的语义是"这个『设备 + 本 App 的播放栈』
//     被**证实**能端到端播这个扩展名"（**不是**"设备有某个解码器"——见下）。
//   * 本文件**不许** import flutter / package:flutter / dart:ui / riverpod：
//     与 `lib/src/data/**` 同一规矩，要能被 `dart run tool/*.dart` 纯 Dart 加载
//     （见 `lib/src/core/i18n/data_text.dart` 的注释）。
//
// 证据口径（每条登记都带 [MediaFormatGap.evidence] + [MediaFormatGap.detail]）：
//   本仓 release 实际解析到的 Media3 版本是 **1.9.2**（不是 build.gradle.kts 里
//   声明的 1.4.1），抽查对象是
//   `~/.gradle/caches/9.3.1/transforms/12362bfc50d106db3b788bda2413d072/transformed/media3-extractor-1.9.2-runtime.jar`
//   （455 个 class / 29 个具名 `*Extractor.class`）。命令与原文见
//   docs/audio-codec-fallback.md §1。
//
// ⚠️ **重要边界（不要把"有解码器"当成"能播"）**：Media3 **不使用** Android 平台的
// extractor 插件（`dumpsys media.extractor` 里有没有 ASF 与它无关），它只用自己的
// `androidx.media3.extractor.*`。所以「设备自带 WMA 解码器」**不足以**让内嵌播放
// 成功 —— 还差一个 ASF 抽取器（或软解 + 自研抽取）。[MediaCodecProbe] 因此被定义成
// **端到端**能力，而不是 `MediaCodecList` 里的一条。
library;

/// 一条登记的**判定依据**类型。
enum MediaFormatGapEvidence {
  /// **容器层**缺失：打包进 APK 的 Media3 抽取器里没有这个容器的 Extractor
  /// → 连 demux 都进不去；这一条**与设备解码器无关**（换机器也不会变）。
  media3NoExtractor('media3_no_extractor'),

  /// **解码层**缺失：Media3 有抽取器，但 vanilla Media3 不带软件解码器、
  /// 且 AOSP 平台通常也没有该解码器 → 多数设备上起播失败（**随设备可变**）。
  platformNoDecoder('platform_no_decoder');

  const MediaFormatGapEvidence(this.code);

  /// 稳定标识（日志 / 文档 / 测试断言用）
  final String code;
}

/// 一条"系统解码器通常解不了"的格式登记。
class MediaFormatGap {
  const MediaFormatGap({
    required this.extension,
    required this.evidence,
    required this.detail,
  });

  /// 小写扩展名（不含点）。
  final String extension;

  /// 判定依据类型
  final MediaFormatGapEvidence evidence;

  /// 判定依据**原文**（引到具体证据，不许写"一般来说"）
  final String detail;

  @override
  String toString() => 'MediaFormatGap($extension, ${evidence.code})';
}

/// 已知缺口的格式清单。
///
/// 顺序只为可读性；查找走 [kMediaFormatGapByExtension]。
const List<MediaFormatGap> kMediaFormatGaps = [
  // ---------------------------------------------------------------- WMA / ASF
  MediaFormatGap(
    extension: 'wma',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        'ASF 容器（WMA v1/v2/Pro/Lossless 共用同一个 ASF 容器）。'
        'media3-extractor-1.9.2 的 29 个具名 Extractor 类里没有任何 asf/wmv/wma '
        '抽取器（无 AsfExtractor；`unzip -l` 里 `grep -i asf` 零命中）。'
        '音频编码是 v1/v2/Pro/Lossless 都改变不了这一点：抽取器缺的是**容器**。',
  ),
  MediaFormatGap(
    extension: 'asf',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        '同 wma：ASF 容器本身在 Media3 1.9.2 里没有抽取器'
        '（`DefaultExtractorsFactory` 只注册 mp4/mkv/ogg/ts/wav/flac/mp3/amr/avi/'
        'flv/avif/heif/jpeg/png/bmp/webp/subtitle 这些）。',
  ),
  MediaFormatGap(
    extension: 'wmv',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        'WMV = 视频放在 ASF 容器里；容器层缺失（同上）。'
        '注意：WMV 的**视频编码**（VC-1/WMV3）是不是硬解得到是另一回事，'
        '容器先过不去。',
  ),

  // ---------------------------------------------------------------- 无损音频
  MediaFormatGap(
    extension: 'ape',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        "Monkey's Audio：Media3 1.9.2 无 ape 抽取器；AOSP 也没有 Monkey's Audio "
        '解码器。AudioStation 官方同样把它算进"重格式"转码'
        '（`getStreamingPlayTypeByRecord` 的 TRANSCODE_TYPE_LIST 含 `ape`，'
        '官方前端 `audio-utils.js`）。',
  ),
  MediaFormatGap(
    extension: 'wv',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        'WavPack：Media3 1.9.2 无 wavpack 抽取器；AOSP 无 WavPack 解码器。'
        '官方 AudioStation 的 TRANSCODE_TYPE_LIST **不含** `wv`（只覆盖到 ape），'
        '所以音乐库里的 `.wv` 走我们自己的缺口清单转码，而不是照抄官方判断。',
  ),

  // ---------------------------------------------------------------- DSD
  MediaFormatGap(
    extension: 'dsf',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        'DSD（DSF）：Media3 1.9.2 无 dsf 抽取器，Android 无 DSD 解码器。'
        '官方把它放进 `POWER_DECODE_LIST:["dsf","dff"]` → **必转码**'
        '（`audio-utils.js`，逐字）。',
  ),
  MediaFormatGap(
    extension: 'dff',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        'DSD（DFF/DIFF）：同 dsf —— Media3 1.9.2 无 dff 抽取器、Android 无 DSD '
        '解码器；官方 `POWER_DECODE_LIST:["dsf","dff"]` 逐字必转码。',
  ),

  // ---------------------------------------------------------------- 视频容器
  MediaFormatGap(
    extension: 'rm',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        'RealMedia：Media3 1.9.2 无 rm/realmedia 抽取器。'
        '`.rmvb` 是同一个容器的变体。',
  ),
  MediaFormatGap(
    extension: 'rmvb',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        '同 rm：RealMedia 容器（`.rmvb` 是它的可变码率变体）在 Media3 1.9.2 的 '
        '29 个具名 Extractor 类里没有任何对应实现；`kVideoExtensions` 收它，'
        '但播放器 demux 不了。',
  ),

  // ---------------------------------------------------------------- MIDI
  MediaFormatGap(
    extension: 'mid',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        'MIDI：Media3 1.9.2 无 mid/midi 抽取器（也没有合成器）。'
        '`media_playlist.dart` 的 `kAudioExtensions` 收它，但播放器读不了。',
  ),
  MediaFormatGap(
    extension: 'midi',
    evidence: MediaFormatGapEvidence.media3NoExtractor,
    detail:
        '同 mid：MIDI 是"事件序列 + 合成器"而不是 PCM 采样流，Media3 既没有 '
        '`.midi` 抽取器也没有合成器；官方 AudioStation 的 TRANSCODE_TYPE_LIST '
        '同样不含它。',
  ),
];

/// 扩展名 → 登记（构建一次；清单本身是 const，改清单不用改这里）。
final Map<String, MediaFormatGap> kMediaFormatGapByExtension = {
  for (final g in kMediaFormatGaps) g.extension: g,
};

/// 设备能力探针：给定**小写扩展名**，返回
///
/// * `true`  —— **已证实**这台设备的**本 App 播放栈**能端到端播这个扩展名；
/// * `false` —— 已证实**不能**；
/// * `null`  —— 未知（按登记的保守结论处理）。
///
/// ⚠️ 语义是**端到端**，不是"设备有某个解码器"：Media3 不用平台 extractor，
/// 所以"`dumpsys media.codec` 里有 `audio/x-ms-wma`"并不等于内嵌播放能成功
/// —— 见文件头注释。设备侧的确切探针命令见 docs/audio-codec-fallback.md §2。
typedef MediaCodecProbe = bool? Function(String extension);

MediaCodecProbe? _deviceProbe;

/// 安装（或卸载，传 null）运行时设备能力探针。
///
/// 这是 fail-open 的**唯一升级口**：探针说 `true` 就不再改道。
/// 生产默认**不装**（未知 → 走保守路径）；父 agent 若在 R7 之后拿到端到端
/// 证据（或补上自研 ASF 抽取器），在这里注入即可，**不需要改本文件**。
void setMediaCodecProbe(MediaCodecProbe? probe) => _deviceProbe = probe;

/// 当前已装的探针（没装就是 null）
MediaCodecProbe? get mediaCodecProbe => _deviceProbe;

/// 取扩展名（小写、不含点；去掉查询串与目录）。
///
/// 与 `AudioStationApi.fileExtension` / `media_playlist.fileNameExtension` 同规则，
/// 但这里**同时**接"路径"与"纯文件名"：先切掉 `?` 之后，再取最后一个 `.`。
String mediaFormatExtensionOf(String pathOrName) {
  final clean = pathOrName.split('?').first;
  final dot = clean.lastIndexOf('.');
  final slash = clean.lastIndexOf('/');
  if (dot < 0 || dot <= slash || dot == clean.length - 1) return '';
  return clean.substring(dot + 1).toLowerCase();
}

/// 这条路径/文件名命中的登记（没有 → null）
MediaFormatGap? mediaFormatGapOf(String pathOrName) =>
    kMediaFormatGapByExtension[mediaFormatExtensionOf(pathOrName)];

/// 这个格式是否**需要**替代路径（服务端转码 / 外部应用）。
///
/// 判定顺序（fail-open）：
///   1. 没有扩展名 → `false`（不猜）；
///   2. 不在清单里 → `false`（**直放**，绝不因为清单改道）；
///   3. 探针明确说 `true` → `false`（**走直链**）；
///   4. 其余 → `true`（保守走替代路径）。
bool mediaFormatNeedsFallback(String pathOrName, {MediaCodecProbe? probe}) {
  final ext = mediaFormatExtensionOf(pathOrName);
  if (ext.isEmpty) return false;
  final gap = kMediaFormatGapByExtension[ext];
  if (gap == null) return false;
  final answer = (probe ?? _deviceProbe)?.call(ext);
  return answer != true;
}

/// 反向问法（读起来更顺的调用点用它）：能不能按"直传原文件"处理。
bool mediaFormatDirectPlayable(String pathOrName, {MediaCodecProbe? probe}) =>
    !mediaFormatNeedsFallback(pathOrName, probe: probe);
