// Download Station 的**界面层文案**（数据层给状态码，界面层给文字）。
//
// 为什么单独一个文件：`lib/src/data/**` 不许 import flutter（要能被
// `dart run tool/*.dart` 加载），所以状态码 → 可读文案的映射只能放在界面层。
// 这是本项目处理"纯 Dart 文件不能引 Flutter"的通用套路
// （见 docs/app-identity-and-i18n.md §4.6）。
library;

import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../data/dto/download_task_dto.dart';

/// 任务状态码 → 文案。取值域与官方 `getStatusString` 逐条对应：
/// `1/11/12`→等待中、`4/13/14`→完成中、`7`→准备做种、`8`→做种、
/// `9`→等待文件托管、`15`→需要验证码；`>=101` 走 [dsErrorStatusLabel]。
String dsStatusLabel(AppText t, int status) => switch (status) {
  1 || 11 || 12 => t.dsStatusWaiting,
  2 => t.dsStatusDownloading,
  3 => t.dsStatusPaused,
  4 || 13 || 14 => t.dsStatusFinishing,
  5 => t.calDone,
  6 => t.dsStatusHashChecking,
  7 => t.dsStatusPreSeeding,
  8 => t.dsStatusSeeding,
  9 => t.dsStatusFilehostingWaiting,
  10 => t.dsStatusExtracting,
  15 => t.dsStatusCaptchaNeeded,
  _ =>
    status >= DsTaskStatus.error
        ? dsErrorStatusLabel(t, status)
        : t.dsStatusCode(status),
};

/// 错误态（`status >= 101`）→ 文案。认不出具体错误时给 `错误（code）`。
String dsErrorStatusLabel(AppText t, int status) => switch (status) {
  DsTaskStatus.brokenLink => t.dsStatusErrBrokenLink,
  DsTaskStatus.destNotExist => t.dsStatusErrDestNotExist,
  DsTaskStatus.destDeny => t.dsStatusErrDestDeny,
  DsTaskStatus.diskFull => t.dsStatusErrDiskFull,
  DsTaskStatus.quotaReached => t.dsStatusErrQuota,
  DsTaskStatus.timeout => t.dsStatusErrTimeout,
  DsTaskStatus.exceedMaxFsSize ||
  DsTaskStatus.exceedMaxTempFsSize ||
  DsTaskStatus.exceedMaxDestFsSize => t.dsStatusErrFileSize,
  DsTaskStatus.nameTooLong ||
  DsTaskStatus.nameTooLongEncryption => t.dsStatusErrNameTooLong,
  DsTaskStatus.torrentDuplicate => t.dsStatusErrTorrentDuplicate,
  DsTaskStatus.fileNoExist => t.dsStatusErrFileNotExist,
  DsTaskStatus.extractFail => t.dsStatusErrExtractFailed,
  DsTaskStatus.extractWrongPassword => t.dsStatusErrExtractPassword,
  DsTaskStatus.extractInvalidArchive => t.dsStatusErrExtractInvalid,
  DsTaskStatus.torrentInvalid => t.dsStatusErrTorrentInvalid,
  DsTaskStatus.requiredAccount => t.dsStatusErrRequiredAccount,
  DsTaskStatus.tryItLater => t.dsStatusErrTryLater,
  _ => t.dsStatusCode(status),
};

/// 顶栏过滤分类 → 文案。
String dsCategoryLabel(AppText t, DownloadTaskCategory c) => switch (c) {
  DownloadTaskCategory.all => t.noteAll,
  DownloadTaskCategory.active => dataText('dsCatActive', '进行中'),
  DownloadTaskCategory.downloading => t.dsStatusDownloading,
  DownloadTaskCategory.waiting => t.dsStatusWaiting,
  DownloadTaskCategory.seeding => t.dsStatusSeeding,
  DownloadTaskCategory.hashChecking => t.dsStatusHashChecking,
  DownloadTaskCategory.extracting => t.dsStatusExtracting,
  DownloadTaskCategory.paused => t.dsStatusPaused,
  DownloadTaskCategory.finished => t.calDone,
  DownloadTaskCategory.error => t.dsStatusError,
};

/// 剩余时间：紧凑 HUD 写法（`1d2h` / `3m20s`）。单位是纯符号，不翻译。
String dsEtaText(int? seconds) {
  final parts = dsEtaParts(seconds);
  if (parts.isEmpty) return '—';
  final b = StringBuffer();
  for (final p in parts.take(2)) {
    b.write(p.value);
    b.write(p.unit);
  }
  return b.toString();
}

/// 下载任务类型 → 可读标识（`bt` → `BT`）。类型名是协议名，不翻译。
String dsTypeLabel(String type) {
  final t = type.trim();
  if (t.isEmpty) return '—';
  return t.toUpperCase();
}

/// 排序键（`DownloadStationApi.sortFields` 的 key）→ 文案。
String dsSortLabel(String field) => switch (field) {
  'filename' => dataText('dsSortName', '名称'),
  'total_size' => dataText('dsSortSize', '大小'),
  'current_size' => dataText('dsSortDownloaded', '已下载'),
  'status' => dataText('dsSortStatus', '状态'),
  'current_rate' => dataText('dsSortSpeedDown', '下载速度'),
  'upload_rate' => dataText('dsSortSpeedUp', '上传速度'),
  'started_time' => dataText('dsSortStarted', '添加时间'),
  _ => field,
};

/// 单任务优先级（`high`/`normal`/`low`）→ 文案。空/未知给"自动"。
String dsPriorityLabel(String priority) => switch (priority) {
  'high' => dataText('dsPriorityHigh', '高'),
  'normal' => dataText('dsPriorityNormal', '普通'),
  'low' => dataText('dsPriorityLow', '低'),
  _ => dataText('dsPriorityAuto', '自动'),
};

/// 单个任务的**次要行**：大小 · 速度 · 剩余时间（已完成的只留大小/时间）。
String dsTaskMetaLine(DownloadTaskDto task) {
  final parts = <String>[];
  if (task.size > 0) parts.add(dsHumanBytes(task.size));
  if (task.isFinished) {
    if (task.transfer.sizeUploaded > 0) {
      parts.add('↑${dsHumanBytes(task.transfer.sizeUploaded)}');
    }
  } else if (!task.isError) {
    if (task.transfer.speedDownload > 0) {
      parts.add('↓${dsHumanRate(task.transfer.speedDownload)}');
    }
    if (task.transfer.speedUpload > 0) {
      parts.add('↑${dsHumanRate(task.transfer.speedUpload)}');
    }
    if (task.etaSeconds != null) parts.add(dsEtaText(task.etaSeconds));
  }
  return parts.join(' · ');
}

/// `Settings.AutoExtraction.unzip_location` 的**服务端枚举 → 用户文案**。
///
/// ★ DA59（r407 真机撞到）：设置页原来把服务端枚举**原样**拼进界面
/// （真机 `uiautomator dump` 逐字读到 `Extract to: current_folder`）——
/// 与 r344/D55「服务端枚举当文案」同族：用户看不懂 `current_folder`。
/// 判据只能取真机像素/dump（离线用例以前没想到会有人断言这行）。
///
/// **未知值原样透传**：不许给没见过的枚举编一个"听起来对"的名字 ——
/// 那才是撒谎（§2.0.47：诊断串/枚举不当用户文案，但也不许编造）。
String dsUnzipLocationLabel(AppText t, String raw) => switch (raw) {
  'current_folder' => t.dsUnzipLocationCurrentFolder,
  // ★ DA64（r410 新登记并修掉）：官方 4.1.2 的**真值**是 `select_folder`
  //   （`ui/download.js` 逐字：`name:"unzip_location"`, `itemId:"select_folder"`,
  //   `inputValue:"select_folder"` —— 同段落里 `current_folder` 那份一模一样）。
  //   r407 我写的是 `specified_folder`：**服务端从来没有发过这个值** ⇒
  //   用户一旦选了"指定文件夹"，这一档又退回**裸枚举上屏**
  //   （DA59 当时只修到了第一档，因为取证时服务端正好是 `current_folder`）。
  //   现场回读（r410，NAS 4.1.2-5012）：`"unzip_location":"current_folder"`；
  //   把选择切成"指定文件夹"后服务端回读 = `"unzip_location":"select_folder"`。
  'select_folder' => t.dsUnzipLocationSpecifiedFolder,
  _ => raw,
};
