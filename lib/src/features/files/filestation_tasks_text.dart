// 文件模块「后台任务」新增界面文案：**key + 中文原文**。
//
// 约定与 `filestation_gaps_wave1..4_text.dart` / `filestation_p0a/p0b_text.dart`
// 一致：`.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，所以新文案一律
// `key + 中文原文`，走 `dataText`（`lib/src/core/i18n/data_text.dart`）。
// ARB 里补上同名 key 后，注入的翻译表会自动把中文原文换成当前语言译文；
// 没补上时回落中文原文（离线 widget 测试不注入 delegate 也照跑）。
//
// **中文原文出处**：官方 DS file `4.17.2-609` APK 的
// `res/values-zh-rCN/strings.xml`（逐字照抄，**不是我编的**）：
//   clear_finish            = "清除已完成"
//   clear_all               = "清除所有项目"
//   sure_to_clear_finish    = "已完成的任务会被清除。您确定要继续吗？"
//   sure_to_clear_all       = "进行中的任务会被取消。您确定要继续吗？"
// 默认（英文）资源 `res/values/strings.xml` 的对应值：
//   sure_to_clear_finish    = "Finished tasks will be cleared. Are you sure
//                              you want to continue?"
//
// ⚠️ 本文件的 key **一个都不带占位符**（`dataText` 不做参数替换）。
//
// key 清单（交给父 agent 并入 `app_zh.arb` / `app_en.arb`）：
//   * `fsTaskClearConfirmFinished` —— 已完成的任务会被清除。您确定要继续吗？
//                                    （构造体对齐官方 `sure_to_clear_finish`）
import '../../core/i18n/data_text.dart';

/// 取本批新文案的译文；[zh] 是中文原文（回落值）。
String fsTask(String key, String zh) => dataText(key, zh);

/// 本批次新增的 ARB key（下一步照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class FsTaskTextKeys {
  /// `clear_finished` 的二次确认文案。
  ///
  /// 出处：官方 APK `res/values-zh-rCN/strings.xml` 的 `sure_to_clear_finish`
  /// （英文默认资源同名的值是 "Finished tasks will be cleared. Are you sure
  /// you want to continue?"）。
  static const clearConfirmFinished = 'fsTaskClearConfirmFinished';
}
