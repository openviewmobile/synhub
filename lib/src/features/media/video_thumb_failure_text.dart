// 抽帧失败的**界面文案**（第 267 轮）。
//
// 分工：`video_frame_thumb.dart` 只给**事实**（stage / container / fourcc /
// reasonKey），这里把事实翻成用户看得懂的一句。
//
// ## 为什么文案长这样（**不许改成"编码不支持"**）
// 真机取证（`docs/device-verification.md §⑩.7`）：那条 183 MB AVI 抽不出帧的
// 原因是 **本机平台的 `MediaExtractor` 没有 RIFF/AVI 解析器**
// （`dumpsys media.extractor` 的 12 个 extractor 里没有 AVI），
// **不是**"没有 `idx1`"（文件尾部有完整 61,987 条 `idx1`），
// **更不是**"编码不支持"（`FMP4` = MPEG-4 Part 2，本机有
// `c2.android.mpeg4.decoder`）。
// ⇒ 说"系统解码器不支持这个文件的编码"是**错的**；说"这个格式（容器）在本机
//    不支持"才是对的，而且要把**具体是哪个容器/哪个编码**一并说出来。
//
// ## ARB 策略（本批禁改 `lib/l10n/**`）
// 只**复用既有 key**（`photoFormatUnsupportedBadge` / `mediaCoverUnavailable` /
// `photoVideo`），**不新增** ARB 条目 ⇒ 零回归风险、不必 `flutter gen-l10n`。
// 容器名与 fourcc 是**数据**（`AVI/RIFF`、`FMP4`），不进翻译表。
// 若父 agent 后续要加更细的句子，把 key 加进 ARB 双语 + `dataTextMap` 即可
// （本文件是把事实翻成文案的唯一落点，改这里一处就够）。
library;

import '../../core/i18n/l10n.dart';
import 'video_frame_stage_bridge.dart';
import 'video_frame_thumb.dart';

/// 容器家族 → 给用户看的短名（**纯数据，不翻译**）。
///
/// 未知家族返回空串（宁可少说，也不编一个名字）。
String videoContainerLabel(String container) {
  switch (container) {
    case 'riff/avi':
    case 'riff-avi':
      return 'AVI/RIFF';
    case 'riff':
      return 'RIFF';
    case 'iso-bmff':
      return 'MP4/MOV';
    case 'ebml':
      return 'MKV/WebM';
    case 'asf':
      return 'ASF/WMV';
    case 'mpeg-ps':
      return 'MPEG-PS';
    case 'mpeg-ts':
      return 'MPEG-TS';
    case 'ogg':
      return 'OGG';
    case 'flv':
      return 'FLV';
    default:
      return '';
  }
}

/// 失败原因 → 一句界面文案。
class VideoThumbFailureText {
  const VideoThumbFailureText({
    required this.label,
    required this.detail,
    required this.facts,
  });

  /// 短标签（缩略图格子/列表行都能放下）
  final String label;

  /// 带**具体事实**的一句（放进 `Semantics` / tooltip / 详情行）
  final String detail;

  /// 纯数据事实（如 `AVI/RIFF · FMP4`），可能为空
  final String facts;

  @override
  String toString() => 'VideoThumbFailureText($label | $detail)';
}

/// 把失败事实翻成文案。
///
/// * `stage=open`（容器打不开）⇒ 标签「格式不支持」+ **具体容器/编码**
///   —— 这正是那条 AVI 在**平台老路径**下的情形；
/// * `stage=avi-codec`（★ 第 269 轮：自研 AVI 路径**把容器解出来了**，卡在编码）
///   ⇒ 标签「编码不支持」+ 容器/fourcc —— 这时"编码"才是正确的归因；
/// * `stage=frame`（没有视频轨 / 取不到关键帧）⇒ 标签「暂无封面」+ 事实；
/// * 其余（编码失败 / 解析失败 / 其它异常 / 平台没给分层）⇒ 只有「暂无封面」，
///   **不编原因**（机器可读的原因键在日志里，见 `[videoFrameThumb] FAIL`）。
VideoThumbFailureText videoThumbFailureText(
  AppText t,
  VideoFrameThumbFailure? failure,
) {
  final container = failure?.container ?? '';
  final label = videoContainerLabel(container);
  final fourcc = failure?.videoFourcc ?? '';
  final facts = [
    if (label.isNotEmpty) label,
    if (fourcc.isNotEmpty) fourcc,
  ].join(' · ');

  if (failure != null &&
      failure.containerNotSupported &&
      failure.stage == VideoFrameStage.open) {
    // 「格式不支持」= 这个**容器**在本机平台没有解析器（不是编码不支持）。
    final head = t.photoFormatUnsupportedBadge;
    return VideoThumbFailureText(
      label: head,
      detail: facts.isEmpty ? head : '$head · $facts',
      facts: facts,
    );
  }
  if (failure != null && failure.codecUnsupported) {
    // ★ 第 269 轮：**自研 AVI 路径把容器解出来了**，卡的是编码
    // （fourcc 不认识 / 本机没对应解码器）—— 这时说"编码不支持"才是**对的**
    // （与上面 stage=open 的情形正好相反）。两种归因不许互相借用。
    final head = t.mediaErrCodecUnsupported;
    return VideoThumbFailureText(
      label: head,
      detail: facts.isEmpty ? head : '$head · $facts',
      facts: facts,
    );
  }
  // 非"容器打不开"的失败：**只给中性标签**，不编原因。
  //
  // 这里**故意不**把容器名塞进 `detail`：`stage=frame`（没有视频轨/取不到关键帧）
  // 与容器无关，单说一个 `AVI/RIFF` 只会让用户以为"是格式的问题" —— 那又变成
  // 一次错误归因。容器/fourcc 仍然留在 `facts` 里（日志与诊断用）。
  return VideoThumbFailureText(
    label: t.mediaCoverUnavailable,
    detail: t.mediaCoverUnavailable,
    facts: facts,
  );
}
