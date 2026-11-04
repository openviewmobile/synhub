// 设置模块本轮新增界面文案：**key + 中文原文**。
//
// 约定与 `features/files/filestation_gaps_wave*_text.dart` 、
// `features/photos/photo_media_text.dart` 完全一致：本批次**禁碰**
// `lib/l10n/*.arb`、`lib/l10n/gen/**` 与 `lib/src/core/i18n/l10n.dart`
// （ARB 与编排器所有），所以新文案一律走数据层的 `dataText.dart`
// （key + 中文原文；装了翻译器就出译文，否则回落中文）。
//
// **key 前缀沿用设置模块既有前缀 `set`** —— 设置页在 `l10n` 里的 key 全是
// `setXxx` / `meXxx`（如 `setMyAccount` / `meNotLoggedIn`）。为便于编排者统一
// 并入 ARB，这里统一用 `setGap*`（`gap` = 本批「已确认用户功能缺口补做批次」）。
//
// ## 中文原文出处
// 三个字段名来自 DSM 官方 Web 语言包里的原词
// （`SYNO.Personal.Profile` 的消费方就是 DSM 桌面的账号面板）：
//   nickname="昵称"  email="电子邮件"  account_type="账号类型"
// 本文件截图取证受限（详见 `docs/user-gap-closure-report.md`），所以**只**保留
// 这些能对上官方词条的中文，其余（如"访客账号"）用服务端布尔字段 `isGuest`
// 的字面语义直译，不臆造。
//
// ⚠️ 本文件的 key 里**没有**占位符（`dataText` 不做参数替换）。
import '../../core/i18n/data_text.dart';

/// 取本批新文案的译文；[zh] 是中文原文（回落值）。
String settingsGap(String key, String zh) => dataText(key, zh);

/// 本批次新增的 ARB key（下一步照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class SettingsGapTextKeys {
  /// 设置页入口
  static const profileEntry = 'setGapProfileEntry';
  static const profileEntryHint = 'setGapProfileEntryHint';

  /// 账号信息页
  static const profileTitle = 'setGapProfileTitle';
  static const profileNickname = 'setGapProfileNickname';
  static const profileEmail = 'setGapProfileEmail';
  static const profileOtherEmails = 'setGapProfileOtherEmails';
  static const profileAccountType = 'setGapProfileAccountType';
  static const profileGuest = 'setGapProfileGuest';
  static const profileMember = 'setGapProfileMember';

  /// 空值与加载
  static const profileUnset = 'setGapProfileUnset';
  static const profileNoEmail = 'setGapProfileNoEmail';
  static const profileLoadFailed = 'setGapProfileLoadFailed';
  static const profileRetry = 'setGapProfileRetry';
  static const profileNotLoggedIn = 'setGapProfileNotLoggedIn';

  /// 访客账号的如实说明（不猜能力，只说明这是访客账号）
  static const profileGuestHint = 'setGapProfileGuestHint';

  /// 当前服务器标签（`{base}（{source}）`；`{source}` 是连接方式）
  static const serverLabel = 'setGapServerLabel';
}
