// 相册「最近添加」（`Browse.RecentlyAdded/list`）新增界面文案：**key + 中文原文**。
//
// 与 `photo_p0_text.dart` / `photo_c2_text.dart` / `photo_wave1_text.dart` /
// `photo_wave2_text.dart` / `photo_wave3_text.dart` 同一套约定：`.arb` 与
// `lib/l10n/gen/**` 在本批次**禁碰**，新文案走数据层的 `data_text.dart`
// （key + 中文原文；装了翻译器就出译文，否则回落中文）。每一条的 key 就是要
// 追加的 ARB key，全表见交付报告。
//
// 复用原则：能复用既有 key 的一律复用 —— 加载失败 / 重试直接复用
// `photoLoadFailed` / `photoRetry`（`PhotoAsync` 内部已走它们）。
import '../../core/i18n/data_text.dart';

/// 取「最近添加」新文案（key 见 [PhotoRecentTextKeys]）
String photoRecent(String key, String zh) => dataText(key, zh);

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class PhotoRecentTextKeys {
  /// 页面标题 = 入口标题
  static const title = 'photoRecentTitle';

  /// hub 入口副标题
  static const entry = 'photoRecentEntry';

  /// 空态标题
  static const emptyTitle = 'photoRecentEmptyTitle';

  /// 空态说明
  static const emptyMessage = 'photoRecentEmptyMessage';
}
