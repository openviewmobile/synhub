// 文件模块 wave4（WriteOnce / WORM）新增界面文案：**key + 中文原文**。
//
// 约定与 `filestation_gaps_wave1..3_text.dart` 一致：`.arb` 与 `lib/l10n/gen/**`
// 在本批次**禁碰**，所以新文案一律 `key + 中文原文`，走 `dataText`
// （`lib/src/core/i18n/data_text.dart`）。ARB 里补上同名 key 后，注入的翻译表
// 会自动把中文原文换成当前语言译文；没补上时回落中文原文。
//
// **中文原文出处**：官方 FileStation Web 端的语言包
// `ui/file_browser/texts/chs/strings` 的 `[worm_info]` / `[common]` 段
// （逐字照抄，**不是我编的**）：
//   lock_state="锁定状态" retention="锁定期间" lock_wait_time="自动锁定时间设置"
//   share_auto_lock="自动锁定" worm_share_mode="模式" forever="永久锁定"
//   worm_state_open="开放" worm_state_locked="锁定" worm_state_immutable="不可变"
//   worm_state_appendonly="可附加" worm_state_expired="已过期" unknown="未知"
//   day="天" hour="小时" minute="分" second="秒" year="年"
//
// ⚠️ `subvol_mode` 的 Enterprise / Compliance 两个名字在 FileStation 的语言包里
// **查不到**（官方 `FileProperty.js` 用的是 `_T("share","share_worm_mode_*")`，
// 属于**控制面板**的语言文件，不在本 SPK 的 `ui/` 里）⇒ 这四个模式名一律用官方
// 枚举的字面英文名（`Normal`/`Enterprise`/`Compliance`/`Normal+`，前两个是 JS
// 里直接硬编码的字符串），**不臆造中文译名**。
//
// ⚠️ 本文件的 key **一个都不带占位符**（`dataText` 不做参数替换）。
//
// key 清单（交给父 agent 并入 `app_zh.arb` / `app_en.arb`）：
//   * `fsGap4WormSection`          —— WriteOnce（分区标题；官方 tab 标题就是这个字面量）
//   * `fsGap4WormMode`             —— 模式
//   * `fsGap4WormAutoLock`         —— 自动锁定
//   * `fsGap4WormEnabled`          —— 已启用
//   * `fsGap4WormNotEnabled`       —— 未启用
//   * `fsGap4WormLockWaitTime`     —— 自动锁定时间设置
//   * `fsGap4WormRetention`        —— 锁定期间
//   * `fsGap4WormLockState`        —— 锁定状态
//   * `fsGap4WormForever`          —— 永久锁定
//   * `fsGap4WormUnset`            —— —
//   * `fsGap4WormSubvolNormal`         —— Normal
//   * `fsGap4WormSubvolEnterprise`     —— Enterprise
//   * `fsGap4WormSubvolCompliance`     —— Compliance
//   * `fsGap4WormSubvolNormalPlus`     —— Normal+
//   * `fsGap4WormStateOpen`            —— 开放
//   * `fsGap4WormStateLocked`          —— 锁定
//   * `fsGap4WormStateImmutable`       —— 不可变
//   * `fsGap4WormStateAppendOnly`      —— 可附加
//   * `fsGap4WormStateExpired`         —— 已过期
//   * `fsGap4WormStateUnknown`         —— 未知
//   * `fsGap4WormUnitYear`             —— 年
//   * `fsGap4WormUnitDay`              —— 天
//   * `fsGap4WormUnitHour`             —— 小时
//   * `fsGap4WormUnitMinute`           —— 分
//   * `fsGap4WormUnitSecond`           —— 秒
import '../../core/i18n/data_text.dart';

/// 取本批新文案的译文；[zh] 是中文原文（回落值）。
String fsGap4(String key, String zh) => dataText(key, zh);

/// 本批次新增的 ARB key（下一步照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class FsGap4TextKeys {
  /// WriteOnce 分区标题（官方 FileProperty.js 里的 tab 标题字面量）
  static const wormSection = 'fsGap4WormSection';

  /// 共享 WriteOnce 配置（`get_share_info`）
  static const wormMode = 'fsGap4WormMode';
  static const wormAutoLock = 'fsGap4WormAutoLock';
  static const wormEnabled = 'fsGap4WormEnabled';
  static const wormNotEnabled = 'fsGap4WormNotEnabled';
  static const wormLockWaitTime = 'fsGap4WormLockWaitTime';
  static const wormRetention = 'fsGap4WormRetention';

  /// 逐文件锁定状态（`Worm:get`）
  static const wormLockState = 'fsGap4WormLockState';
  static const wormForever = 'fsGap4WormForever';
  static const wormUnset = 'fsGap4WormUnset';

  /// `subvol_mode` 模式名（官方枚举字面名，不臆造译名）
  static const subvolNormal = 'fsGap4WormSubvolNormal';
  static const subvolEnterprise = 'fsGap4WormSubvolEnterprise';
  static const subvolCompliance = 'fsGap4WormSubvolCompliance';
  static const subvolNormalPlus = 'fsGap4WormSubvolNormalPlus';

  /// `worm_state` 状态名（官方 `[worm_info]` 原文）
  static const stateOpen = 'fsGap4WormStateOpen';
  static const stateLocked = 'fsGap4WormStateLocked';
  static const stateImmutable = 'fsGap4WormStateImmutable';
  static const stateAppendOnly = 'fsGap4WormStateAppendOnly';
  static const stateExpired = 'fsGap4WormStateExpired';
  static const stateUnknown = 'fsGap4WormStateUnknown';

  /// 时间单位（官方 `[worm_info]` 原文）
  static const unitYear = 'fsGap4WormUnitYear';
  static const unitDay = 'fsGap4WormUnitDay';
  static const unitHour = 'fsGap4WormUnitHour';
  static const unitMinute = 'fsGap4WormUnitMinute';
  static const unitSecond = 'fsGap4WormUnitSecond';
}
