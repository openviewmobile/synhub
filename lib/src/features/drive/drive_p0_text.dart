// Drive P0 批新增界面文案 + 统一降级判定（key + 中文原文）。
//
// 为什么不用 `context.t`：本批禁止碰 `.arb` 与 `lib/l10n/gen/**`，所以新文案
// 沿用数据层的 `dataText` 约定（key + 中文原文，语言切换由
// `setCurrentText` 注入译文，取不到就回落中文）。与
// `lib/src/features/drive/drive_c1_text.dart` 同构；每条的 key 就是要追加的
// ARB key（清单见 `docs/drive-p0-implementation.md`）。
//
// 降级语义（用户既定口径，**与 `service_registry` 的 `hidesModule` 一致**）：
//   * `105` / `160`（已安装但无权限）→ `denied`：**该入口隐藏**，但给一句原因；
//   * `102` / `103`（API/方法不存在，多为服务端版本过低）→ `unavailable`：
//     **该入口置灰/隐藏**，其余功能不受影响；
//   * `119` / `106`（会话失效/超时）→ `sessionExpired`：**绝不隐藏**，只提示重登；
//   * 其它错误（网络等）→ `available`（照常显示正常错误态，不因不确定而隐藏）。
//
// 判定只看 `DsmApiException.code`；能力表缺位（`apiMissing`）等价 `unavailable`。
import '../../core/i18n/data_text.dart';
import '../../dsm/webapi.dart';

/// 取 P0 新文案（key 见 [DriveP0TextKeys]）
String driveP0(String key, String zh) => dataText(key, zh);

/// 带 `{name}` / `{count}` 等占位符的文案填充
String driveP0Fill(String key, String zh, Map<String, String> values) {
  var out = driveP0(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 一个可选入口的降级状态
enum DriveEntryGate {
  /// 照常显示（含普通错误，交给错误态）
  available,

  /// 105 / 160：无权限 → 隐藏 + 原因
  denied,

  /// 102 / 103（或能力表缺位）：服务端没有这个能力 → 置灰/隐藏
  unavailable,

  /// 119 / 106：会话失效 → 保留入口但提示重登
  sessionExpired,
}

/// 由错误对象判降级状态；[apiMissing] 来自能力表（`hasApi`）。
///
/// 纪律：**只有明确知道的**才降级；认不出来的错误一律 `available`。
DriveEntryGate driveEntryGate(Object? error, {bool apiMissing = false}) {
  if (apiMissing) return DriveEntryGate.unavailable;
  if (error is DsmApiException) {
    switch (error.code) {
      case DsmErrorCode.noPermission:
      case DsmErrorCode.noAppPrivilege:
        return DriveEntryGate.denied;
      case DsmErrorCode.apiNotFound:
      case DsmErrorCode.methodNotFound:
        return DriveEntryGate.unavailable;
      case DsmErrorCode.sessionTimeout:
      case DsmErrorCode.sidNotFound:
        return DriveEntryGate.sessionExpired;
    }
  }
  return DriveEntryGate.available;
}

/// 降级状态对应的一句话（`available` 不该被调用，回落空串）
String driveGateMessage(DriveEntryGate gate) => switch (gate) {
  DriveEntryGate.denied => driveP0(
    DriveP0TextKeys.entryDenied,
    '这个账号没有访问该功能的权限（入口已隐藏）',
  ),
  DriveEntryGate.unavailable => driveP0(
    DriveP0TextKeys.entryUnavailable,
    '这台 NAS 没有提供该功能（Synology Drive Server 版本可能过低）',
  ),
  DriveEntryGate.sessionExpired => driveP0(
    DriveP0TextKeys.entrySessionExpired,
    '登录已过期，请重新登录',
  ),
  DriveEntryGate.available => '',
};

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class DriveP0TextKeys {
  // ---- 通用降级
  static const entryDenied = 'driveP0EntryDenied';
  static const entryUnavailable = 'driveP0EntryUnavailable';
  static const entrySessionExpired = 'driveP0EntrySessionExpired';

  // ---- 最近
  static const recentTitle = 'driveP0RecentTitle';
  static const recentEmptyTitle = 'driveP0RecentEmptyTitle';
  static const recentEmptyMessage = 'driveP0RecentEmptyMessage';

  // ---- 我共享的
  static const sharedByMeTitle = 'driveP0SharedByMeTitle';
  static const sharedByMeEmptyTitle = 'driveP0SharedByMeEmptyTitle';
  static const sharedByMeEmptyMessage = 'driveP0SharedByMeEmptyMessage';

  // ---- 浏览子文件夹（团队 / 共享）
  static const folderEmptyTitle = 'driveP0FolderEmptyTitle';
  static const folderEmptyMessage = 'driveP0FolderEmptyMessage';
  static const folderOpenFailed = 'driveP0FolderOpenFailed';

  // ---- 搜索
  static const searchTitle = 'driveP0SearchTitle';
  static const searchHint = 'driveP0SearchHint';
  static const searchEmptyTitle = 'driveP0SearchEmptyTitle';
  static const searchEmptyMessage = 'driveP0SearchEmptyMessage';
  static const searchFailed = 'driveP0SearchFailed';
  static const searchNeedCondition = 'driveP0SearchNeedCondition';
  static const searchLocation = 'driveP0SearchLocation';
  static const searchLocationAny = 'driveP0SearchLocationAny';
  static const searchLocationMyDrive = 'driveP0SearchLocationMyDrive';
  static const searchLocationTeamFolders = 'driveP0SearchLocationTeamFolders';
  static const searchLocationSharedWithMe = 'driveP0SearchLocationSharedWithMe';
  static const searchLocationSharedByMe = 'driveP0SearchLocationSharedByMe';
  static const searchLocationStarred = 'driveP0SearchLocationStarred';
  static const searchLocationCurrent = 'driveP0SearchLocationCurrent';
  static const searchType = 'driveP0SearchType';
  static const searchTypeAny = 'driveP0SearchTypeAny';
  static const searchTypeFolder = 'driveP0SearchTypeFolder';
  static const searchTypeFile = 'driveP0SearchTypeFile';
  static const searchTypeOdoc = 'driveP0SearchTypeOdoc';
  static const searchTypeOsheet = 'driveP0SearchTypeOsheet';
  static const searchTypeOslide = 'driveP0SearchTypeOslide';
  static const searchTypeDocument = 'driveP0SearchTypeDocument';
  static const searchTypeImage = 'driveP0SearchTypeImage';
  static const searchTypeAudio = 'driveP0SearchTypeAudio';
  static const searchTypeVideo = 'driveP0SearchTypeVideo';
  static const searchOwner = 'driveP0SearchOwner';
  static const searchOwnerAny = 'driveP0SearchOwnerAny';
  static const searchOwnerMe = 'driveP0SearchOwnerMe';
  static const searchOwnerNotMe = 'driveP0SearchOwnerNotMe';
  static const searchSize = 'driveP0SearchSize';
  static const searchSizeAny = 'driveP0SearchSizeAny';
  static const searchSizeGreater = 'driveP0SearchSizeGreater';
  static const searchSizeLess = 'driveP0SearchSizeLess';
  static const searchSizeEqual = 'driveP0SearchSizeEqual';
  static const searchSizeUnit = 'driveP0SearchSizeUnit';
  static const searchDate = 'driveP0SearchDate';
  static const searchDateAny = 'driveP0SearchDateAny';
  static const searchDateModified = 'driveP0SearchDateModified';
  static const searchDateCreated = 'driveP0SearchDateCreated';
  static const searchLabel = 'driveP0SearchLabel';

  // ---- 复制 / 移动
  static const copyTo = 'driveP0CopyTo';
  static const moveTo = 'driveP0MoveTo';
  static const copyMovePick = 'driveP0CopyMovePick';
  static const copyHere = 'driveP0CopyHere';
  static const moveHere = 'driveP0MoveHere';
  static const copyMoveSameFolder = 'driveP0CopyMoveSameFolder';
  static const copyMoveConflictTitle = 'driveP0CopyMoveConflictTitle';
  static const copyMoveConflictBody = 'driveP0CopyMoveConflictBody';
  static const conflictAutorename = 'driveP0ConflictAutorename';
  static const conflictOverwrite = 'driveP0ConflictOverwrite';
  static const conflictStop = 'driveP0ConflictStop';
  static const copyMoveDone = 'driveP0CopyMoveDone';
  static const copyMoveFailed = 'driveP0CopyMoveFailed';

  // ---- 文件详情 / 属性
  static const infoTitle = 'driveP0InfoTitle';
  static const infoType = 'driveP0InfoType';
  static const infoTypeFile = 'driveP0InfoTypeFile';
  static const infoFolder = 'driveP0InfoFolder';
  static const infoLocation = 'driveP0InfoLocation';
  static const infoCreated = 'driveP0InfoCreated';
  static const infoModified = 'driveP0InfoModified';
  static const infoOwner = 'driveP0InfoOwner';
  static const infoSize = 'driveP0InfoSize';
  static const infoLabels = 'driveP0InfoLabels';
  static const infoPermission = 'driveP0InfoPermission';
  static const infoCanDownload = 'driveP0InfoCanDownload';
  static const infoCanWrite = 'driveP0InfoCanWrite';
  static const infoCanPreview = 'driveP0InfoCanPreview';
  static const infoShared = 'driveP0InfoShared';
  static const infoStarred = 'driveP0InfoStarred';
  static const infoLocked = 'driveP0InfoLocked';
  static const infoLockedBy = 'driveP0InfoLockedBy';
  static const infoNone = 'driveP0InfoNone';
  static const infoClose = 'driveP0InfoClose';

  // ---- 加密 Office 文档
  static const encryptedTitle = 'driveP0EncryptedTitle';
  static const encryptedOfficeBody = 'driveP0EncryptedOfficeBody';
  // D58（第 65 轮）：加密 Office 的密码输入
  static const passwordLabel = 'driveP0PasswordLabel';
  static const passwordWrong = 'driveP0PasswordWrong';
  static const passwordSubmit = 'driveP0PasswordSubmit';
}
