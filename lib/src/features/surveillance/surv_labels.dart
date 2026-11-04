// Surveillance Station 的**界面层文案映射**（数据层给码，界面层给文字）。
//
// 数据层 `lib/src/data/**` 不许 import flutter，所以「状态码 → 文案」只能放在
// 界面层（与 `features/downloads/download_labels.dart` 同一套路）。
library;

import '../../core/i18n/l10n.dart';
import '../../data/dto/surveillance_dto.dart';

/// 摄像机状态 → 文案。
///
/// 取值域逐字对齐包内 `ui/sds.js` 的 `SYNO.SS.CamSts.*` 与
/// `SYNO.SS.Utils.GetCamStatusStr`。
String survStatusLabel(AppText t, SurvCameraDto cam) =>
    switch (cam.effectiveStatus) {
      SurvCamStatus.normal || SurvCamStatus.ready => t.survStatusLive,
      SurvCamStatus.disabled => t.survStatusDisabled,
      SurvCamStatus.disconnected ||
      SurvCamStatus.serverDisconnected ||
      SurvCamStatus.inaccessible ||
      SurvCamStatus.hostFailed => t.survStatusDisconnected,
      SurvCamStatus.setting || SurvCamStatus.migrating => t.survStatusSetting,
      SurvCamStatus.deleted => t.survStatusUnknown,
      SurvCamStatus.empty => t.survStatusUnknown,
      _ => t.survStatusOther(cam.effectiveStatus),
    };

/// 摄像机次要行：型号 · 分辨率/帧率 · 地址（有哪个给哪个）。
String survCameraMeta(SurvCameraDto cam) {
  final parts = <String>[];
  if (cam.model.isNotEmpty) parts.add(cam.model);
  final stream = <String>[];
  if (cam.resolution.isNotEmpty) stream.add(cam.resolution);
  if (cam.fps > 0) stream.add('${cam.fps}fps');
  if (stream.isNotEmpty) parts.add(stream.join(' · '));
  if (cam.host.isNotEmpty) parts.add(cam.host);
  return parts.join(' · ');
}

/// 录像时长 → `1h02m` / `3m20s` / `45s`（纯符号，不翻译）。
String survDurationText(int seconds) {
  if (seconds <= 0) return '—';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) return '${h}h${m.toString().padLeft(2, '0')}m';
  if (m > 0) return '${m}m${s.toString().padLeft(2, '0')}s';
  return '${s}s';
}

/// 无人值守格式的录像时间行：`MM-dd HH:mm:ss`。
String survRecordingTimeText(int unixSeconds) {
  if (unixSeconds <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:'
      '${two(d.minute)}:${two(d.second)}';
}
