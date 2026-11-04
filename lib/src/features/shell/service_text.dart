// shell（服务可用性呈现层）的**新文案**助手。
//
// 约定（与 `drive_c1_text.dart` / `note_c3_text.dart` 同）：新文案一律
// `key + 中文原文`，走 `dataText`，**不碰 ARB**、不动 `lib/l10n/gen/**`。
// ARB 里补上同名 key 后，`setCurrentText` 注入的翻译表会自动把中文原文换成
// 当前语言译文；没补上时回落中文原文（见 `lib/src/core/i18n/data_text.dart`）。
//
// 现有 key 清单（交给父 agent 并入 ARB）：
//   * `serviceStateUncertain`       —— 服务检测页的状态标签
//   * `serviceStateUncertainReason` —— 状态原因（矛盾 = 信号 1 说有、信号 2 说没有）
import '../../core/i18n/data_text.dart';

/// 取 shell 层新文案的译文；[zh] 是中文原文（回落值）。
String serviceText(String key, String zh) => dataText(key, zh);
