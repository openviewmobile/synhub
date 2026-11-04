// 媒体失败原因的**界面文案**。
//
// 分工：`media_source.dart`（纯逻辑层）只给**枚举**，这里把枚举翻成用户看得懂的话。
// ARB 策略：本批**只新增一个待落库的 key** —— `mediaErrStreamRejected`
// （[MediaUnavailableReason.streamRejected] 用；本批禁改 `lib/l10n/**`，所以
// 先走 `dataText` 的中文回落，父 agent 补 ARB + `dataTextMap` 后自动生效）。
// 其余条目全部复用既有 key（三个并行批次都在改 ARB，新增必冲突）。
// 待补 key 的完整清单（zh/en）见 docs/media-streaming-diagnosis.md §6。
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import 'media_source.dart';

/// 一句标题 + 一句解释
class MediaReasonText {
  const MediaReasonText(this.title, this.detail);

  final String title;
  final String detail;
}

/// 失败原因 → 文案。
///
/// [kind] 只影响"交给系统应用"那句该说视频还是其它（视频那句更具体）。
MediaReasonText mediaReasonText(
  AppText t,
  MediaUnavailableReason reason,
  MediaKind kind,
) {
  final toSystem = kind == MediaKind.video ? t.fileWhyVideo : t.fileWhyOther;
  return switch (reason) {
    // 空 URL / 拿不到直链：说"打不开" + 未知原因（真正原因见支持的通道限制）
    MediaUnavailableReason.emptyUrl => MediaReasonText(
      t.fileOpenFailed,
      t.errUnknown,
    ),
    MediaUnavailableReason.tunnelUnavailable => MediaReasonText(
      t.fileOpenFailed,
      t.apiTunnelNotStarted,
    ),
    // 自签证书被固定：Media3 用系统信任链，握手必失败（调研 §5.4 第 1 条）
    MediaUnavailableReason.certificateUntrusted => MediaReasonText(
      t.chatStreamUntrustedCertTitle,
      t.chatStreamUntrustedCertHint,
    ),
    // Drive 写死 Accept-Ranges: none（调研 §3.4）→ 不能拖，交给系统应用
    MediaUnavailableReason.rangeUnsupported => MediaReasonText(
      t.fileOpenFailed,
      '$toSystem\n${t.bookDownloadHint}',
    ),
    MediaUnavailableReason.notConnected => MediaReasonText(
      t.fileOpenFailed,
      t.srvNotConnected,
    ),
    MediaUnavailableReason.unsupportedSource => MediaReasonText(
      t.fileOpenFailed,
      toSystem,
    ),
    // 运行时失败：编码/容器不支持、或没被前置拦住的 TLS 握手失败
    MediaUnavailableReason.decodeFailed => MediaReasonText(
      t.chatErrPlaybackFailed,
      toSystem,
    ),
    // 编码解不了：标题仍是"播放失败"，但解释句**具体说是编码问题**
    // （真机 Theora `.mkv` 只黑屏、没有任何提示，这一条就是补它）
    MediaUnavailableReason.codecUnsupported => MediaReasonText(
      t.chatErrPlaybackFailed,
      '${t.mediaErrCodecUnsupported}\n$toSystem',
    ),
    // 网络/登录态：说清"不是文件的锅，是连不上"
    MediaUnavailableReason.networkFailed => MediaReasonText(
      t.chatErrPlaybackFailed,
      '${t.mediaErrNetworkFailed}\n$toSystem',
    ),
    // 取流缺鉴权 / 会话失效（DSM 119）：**"重新登录"**而不是"编码不支持"
    MediaUnavailableReason.sessionExpired => MediaReasonText(
      t.chatErrPlaybackFailed,
      '${t.errSidNotFound}\n$toSystem',
    ),
    // **取流被服务端拒绝**（HTTP 4xx/5xx / 响应不是媒体）：与"编码不支持"
    // （本机解码器）和"网络中断"（连不上）都不同 —— 这三类在 R5 真机上被混成
    // 一句"播放失败"，用户和排查都会被带偏（docs/media-streaming-diagnosis.md）。
    //
    // 解释句用 `reason.text`（`dataText(key, 中文回落)`）：key
    // `mediaErrStreamRejected` 本批**还没进 ARB**（本批禁改 `lib/l10n/**`），
    // 所以现在显示中文回落；父 agent 补完 ARB 后这里自动切到译文、**不用再改代码**。
    MediaUnavailableReason.streamRejected => MediaReasonText(
      t.chatErrPlaybackFailed,
      '${reason.text}\n$toSystem',
    ),
    // **格式本身已知不被本机播放栈支持**（WMA/ASF、APE、WavPack、DSD…）：
    // 与"运行时解码失败"（[codecUnsupported]）分开 —— 这一条是**事前**按
    // 应用级能力登记判出来的，"换条路"是明确可行的处置，所以解释句必须给出
    // 出路（外部应用 / 音乐库内走服务端转码），而不是只说"解不了"。
    //
    // 解释句用 `reason.text`（`dataText(key, 中文回落)`）：key
    // `mediaErrFormatUnsupported` 本批**还没进 ARB**（禁改 `lib/l10n/**` 与
    // `lib/src/core/i18n/**`），所以现在显示中文回落；父 agent 补完 ARB +
    // `dataTextMap` 后这里自动切译文、**不用再改代码**。
    MediaUnavailableReason.formatUnsupported => MediaReasonText(
      t.chatErrPlaybackFailed,
      '${reason.text}\n$toSystem',
    ),
    // **本平台根本没有本地播放实现**（第 156 轮 Linux 站）：与"解码失败"
    // 分开说 —— 用户能做的只有换设备/等平台支持，不该被引去换格式或重登。
    MediaUnavailableReason.platformUnsupported => MediaReasonText(
      t.chatErrPlaybackFailed,
      reason.text,
    ),
    // ★ r690：解码在走、画面建不起来（软件渲染/驱动不支持纹理共享）——
    //   标题仍是"播放失败"，解释句点名**图形栈**，别让用户去换文件格式。
    MediaUnavailableReason.videoOutputUnavailable => MediaReasonText(
      t.chatErrPlaybackFailed,
      reason.text,
    ),
  };
}

/// **自动续播**进入的条目"窗口内没有任何画面证据"的**非阻塞**提示（R5 真实漏报路径）。
///
/// 为什么不是 [mediaReasonText]：那条链路最终会走 [MediaFallbackPanel]（致命、盖住
/// 播放器、文案断言"系统解码器不支持这个文件的编码"）。自动续播的条目**用户没点选**、
/// 而且可能是"某 ROM 不回调首帧"的可解码文件，不能用致命面板误伤 —— 所以这里只给
/// 一行提示，播放器与控制条保持可用。
///
/// ARB 策略与 `streamRejected` 一致：key `mediaAutoContinueNoPicture` **本批没有**
/// 写进 `lib/l10n/*.arb`（禁改 ARB）→ 用 [dataText] 的中文回落；父 agent 补完
/// ARB + `dataTextMap` 后自动切译文，**不用再改代码**。占位符 `{name}` = 当前条目名。
String mediaAutoContinueNotice(String name) {
  final template = dataText(
    'mediaAutoContinueNoPicture',
    '已自动播放到下一集「{name}」：当前条目无法内嵌播放，可切换到系统播放器打开',
  );
  return template.replaceAll('{name}', name);
}

/// **会话续期成功**后的**非阻塞**提示（条 / toast）：不弹窗、不打断播放。
///
/// 为什么必须有这一条：续期是**我们**的事，用户点过一次播放就该继续看完
/// （再来一个弹窗等于要用户为我们的会话过期点第二次）；但完全**静默**恢复
/// 也不行 —— 画面黑一下又回来，用户不知道发生了什么。所以给一行会自动消失的说明。
///
/// ARB 策略与 [mediaAutoContinueNotice] 一致：key `mediaSessionReconnected`
/// **本批没有**写进 `lib/l10n/*.arb`（禁改 ARB）→ [dataText] 中文回落；
/// 父 agent 补 ARB + `dataTextMap` 后自动切译文，**不用再改代码**。
String mediaSessionReconnectedNotice() =>
    dataText('mediaSessionReconnected', '已重新连接，从原位置继续播放');

/// 有界重试**用尽**后，会话失效面板上的补充说明（明确"自动恢复失败 + 可手动重试"）。
///
/// 只在这条来源**真的有**手动重试入口（`MediaSource.renew != null` 且可 seek）时
/// 显示 —— 否则不给假希望。
///
/// ARB 策略同上：key `mediaSessionResumeFailed` 待父 agent 落库，先用中文回落。
String mediaSessionResumeFailedHint() => dataText(
  'mediaSessionResumeFailed',
  '会话已过期，自动续播失败；可点「重试」重新连接',
);
