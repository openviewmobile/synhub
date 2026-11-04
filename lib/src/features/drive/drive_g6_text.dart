// Drive **G6 批次**（`SYNO.SynologyDrive.Connection:list` 已连接设备；
// `FileRequest` 的 `1076` 用户语言）新增界面文案：
// **key + 中文原文**，与 `drive_c1_text.dart` / `drive_g4_text.dart` /
// `drive_wave2_text.dart` 同构。
//
// 为什么不用 `context.t`：这些 key 已**同步追加进** `lib/l10n/app_zh.arb` /
// `app_en.arb`，`setCurrentText` 注入的翻译表会把中文原文换成当前语言译文；
// 取不到就回落中文（`data_text.dart` 的约定）。带 `{...}` 的一律走
// [driveG6Fill]，绝不把占位符当字面量送进 UI。
import '../../core/i18n/data_text.dart';
import '../../core/user_facing_error.dart';
import '../../data/drive_api.dart' show kDriveFileRequestDisabledCode;
import '../../data/local/file_store.dart' show describeFileError;
import '../../dsm/webapi.dart';

/// 取 G6 新文案（key 见 [DriveG6TextKeys]）
String driveG6(String key, String zh) => dataText(key, zh);

/// 带 `{...}` 占位符的文案填充
String driveG6Fill(String key, String zh, Map<String, String> values) {
  var out = driveG6(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// G6 新增的 ARB key（已同步进 `app_zh.arb` / `app_en.arb`）
abstract final class DriveG6TextKeys {
  // ---- 已连接的客户端 / 设备（`Connection:list` v2，回退 v1）
  static const connectionsTitle = 'driveG6ConnectionsTitle';
  static const connectionsEntry = 'driveG6ConnectionsEntry';
  static const connectionsEntryHint = 'driveG6ConnectionsEntryHint';
  static const connectionsSubtitle = 'driveG6ConnectionsSubtitle';
  static const connectionsEmptyTitle = 'driveG6ConnectionsEmptyTitle';
  static const connectionsEmptyBody = 'driveG6ConnectionsEmptyBody';
  static const connectionsLoadFailed = 'driveG6ConnectionsLoadFailed';
  static const connectionStatusConnected = 'driveG6ConnectionStatusConnected';
  static const connectionStatusOffline = 'driveG6ConnectionStatusOffline';
  static const connectionUnknownDevice = 'driveG6ConnectionUnknownDevice';

  // ---- `FileRequest` 的 `1076`（服务端开关；**绝不透协议原文**）
  static const fileRequestDisabled = 'driveG6FileRequestDisabled';

  // ---- 通用动作失败（带 `{error}`，走 [driveG6Fill]）+ 兜底人话
  static const actionFailed = 'driveG6ActionFailed';
  static const genericFailure = 'driveG6GenericFailure';
}

/// 把 Drive G6 页面上的任意异常翻成**能给用户看的一行话**。
///
/// 本函数是 Drive G6 批次**唯一**的异常出口，两条硬规则都在这里兜住：
///
/// 1. **`1076` → 人话**（`kDriveFileRequestDisabledCode`）：
///    真机实测该码的 `error.errors.message` 是
///    `protocol error, reason = 'file request is disabled'`
///    —— **原始协议报文，绝不许进界面**（`docs/g6-api-probe-facts.md:44-55`）；
/// 2. **其余异常不丢原文也不透原文**：`DsmApiException` 走既有
///    [describeFileError]（保留 DSM 码值，用户报障靠它），
///    非 `DsmApiException` 走全仓唯一出口 [userFacingError]
///    （`lib/src/core/user_facing_error.dart`）—— 以前「请求文件」页直接落到
///    `'$error'`，会把 Dart/三方库类型名甩给用户。
///
/// ⚠️ 本函数**不读** `DsmApiException.raw` / `error.errors.*`：报文永不进 UI。
String describeDriveG6Error(Object error) {
  if (error is DsmApiException) {
    if (error.code == kDriveFileRequestDisabledCode) {
      return driveG6(
        DriveG6TextKeys.fileRequestDisabled,
        '这台 NAS 没有开启「文件请求」功能，请在 DSM 的 Drive 管理控制台中启用后重试。',
      );
    }
    return describeFileError(error);
  }
  return userFacingError(
    error,
    fallback: driveG6(DriveG6TextKeys.genericFailure, '操作失败，请稍后重试'),
  );
}
