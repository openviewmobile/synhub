// 管理员门控用到的文案键（集中放，避免散落在各页面）。
//
// 约定与本仓其它 `*_text.dart` 一致：键常量 + 中文兜底，
// 缺 ARB 时由 `dataText(key, zh)` 回落（见 `lib/src/core/i18n/l10n.dart`）。
import '../../core/i18n/data_text.dart';

abstract final class AdminGapTextKeys {
  /// 深链/竞态下进入管理页面时的说明
  static const adminOnlyNeedsAdmin = 'adminGapNeedsAdmin';

  /// 管理工具页标题
  static const adminToolsTitle = 'adminGapToolsTitle';

  /// 设置页里的管理工具入口副标题
  static const adminToolsEntryHint = 'adminGapToolsEntryHint';

  /// Active Insight 条目
  static const activeInsightTitle = 'adminGapActiveInsightTitle';

  /// 读取中
  static const adminLoading = 'adminGapLoading';

  /// 读取失败（非权限原因）
  static const adminReadFailed = 'adminGapReadFailed';

  /// 第三/四/五批磁贴标题
  static const storageTitle = 'adminGapStorageTitle';
  static const packageTitle = 'adminGapPackageTitle';
  static const networkTitle = 'adminGapNetworkTitle';
  static const upgradeTitle = 'adminGapUpgradeTitle';
  static const serviceTitle = 'adminGapServiceTitle';
  static const emptyList = 'adminGapEmptyList';
  static const diskHealthTitle = 'adminGapDiskHealthTitle';
  static const userTitle = 'adminGapUserTitle';
  static const qcTitle = 'adminGapQcTitle';
  static const auth2faTitle = 'adminGapAuth2faTitle';
  static const hddTitle = 'adminGapHddTitle';
  static const groupTitle = 'adminGapGroupTitle';
  static const appPrivTitle = 'adminGapAppPrivTitle';
  static const pwdPolicyTitle = 'adminGapPwdPolicyTitle';

  /// 系统信息（SYNO.Core.System:info）
  static const sysInfoTitle = 'adminGapSysInfoTitle';
  static const sysInfoUnknown = 'adminGapSysInfoUnknown';

  /// FindMe（SYNO.DSM.FindMe）
  static const findMeTitle = 'adminGapFindMeTitle';
  static const findMeSupported = 'adminGapFindMeSupported';
  static const findMeUnsupported = 'adminGapFindMeUnsupported';
  static const findMeUnknown = 'adminGapFindMeUnknown';

  /// 蜂鸣（DS finder 招牌功能）
  static const beepTitle = 'adminGapBeepTitle';
  static const beepBeeping = 'adminGapBeepBeeping';
  static const beepNotBeeping = 'adminGapBeepNotBeeping';
  static const beepUnknown = 'adminGapBeepUnknown';
  static const beepStop = 'adminGapBeepStop';
  static const beepStopped = 'adminGapBeepStopped';

  /// 已启用 / 未启用
  static const adminEnabled = 'adminGapEnabled';
  static const adminDisabled = 'adminGapDisabled';

  /// 存储池行（`{vol}（{n} 个存储池）`）
  static const storagePoolsLine = 'adminGapStoragePoolsLine';

  /// 各磁贴的计数行（`{n}` 由调用方填充）
  static const authCount = 'adminGapAuthCount';
  static const hddCount = 'adminGapHddCount';
  static const userCount = 'adminGapUserCount';
  static const groupCount = 'adminGapGroupCount';
  static const appPrivCount = 'adminGapAppPrivCount';
  static const diskCount = 'adminGapDiskCount';
  static const packageCount = 'adminGapPackageCount';
  static const serviceCount = 'adminGapServiceCount';

  /// DSM 升级状态
  static const upgradeAvailable = 'adminGapUpgradeAvailable';
  static const upgradeLatest = 'adminGapUpgradeLatest';
}

String adminGap(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{vol}` / `{n}` …）。
String adminGapFill(String key, String zh, Map<String, String> values) {
  var out = adminGap(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}
