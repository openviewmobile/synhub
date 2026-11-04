// 文件模块「剩余可做缺口 wave2」新增界面文案：**key + 中文原文**。
//
// 约定与 `filestation_gaps_wave1_text.dart` / `filestation_p0a_text.dart` 一致：
// `.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，所以新文案一律 `key + 中文原文`，
// 走 `dataText`（`lib/src/core/i18n/data_text.dart`）。ARB 里补上同名 key 后，
// 注入的翻译表会自动把中文原文换成当前语言译文；没补上时回落中文原文。
//
// 本批覆盖：
//   * M18 目标目录选择器（`fsGap2PickFolder` / `fsGap2Up` / …）
//   * M21 压缩更新模式（`fsGap2CompressMode` / `fsGap2Mode*`）
//   * M50 收藏重排（`fsGap2FavoriteReorder*` / `fsGap2MoveUp` / `fsGap2MoveDown`）
//   * M51 个人文件夹固定入口（`fsGap2PersonalFolder`）
//   * M58 后台任务重试（`fsGap2TaskRetry*`）
//   * M72 主屏快捷方式（`fsGap2Shortcut*`）
//
// key 清单（交给父 agent 并入 `app_zh.arb` / `app_en.arb`）见
// `docs/filestation-gaps-wave2.md` §5。
import '../../core/i18n/data_text.dart';

/// 取本批新文案的译文；[zh] 是中文原文（回落值）。
String fsGap2(String key, String zh) => dataText(key, zh);

/// 带 `{name}` 占位符的文案填充（与 `driveP0Fill` 同构）。
String fsGap2Fill(String key, String zh, Map<String, String> values) {
  var out = fsGap2(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批次新增的 ARB key（下一步照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class FsGap2TextKeys {
  // M18 目标目录选择器
  static const pickFolder = 'fsGap2PickFolder';
  static const up = 'fsGap2Up';
  static const noSubfolder = 'fsGap2NoSubfolder';
  static const loadFailed = 'fsGap2LoadFailed';
  static const root = 'fsGap2Root';

  // M21 压缩更新模式（取值照 `api-server-authoritative.md:1194-1204` 的官方表）
  static const compressMode = 'fsGap2CompressMode';
  static const modeAdd = 'fsGap2ModeAdd';
  static const modeUpdate = 'fsGap2ModeUpdate';
  static const modeFreshen = 'fsGap2ModeFreshen';
  static const modeSynchronize = 'fsGap2ModeSynchronize';

  // M50 收藏重排（`Favorite/replace_all`，参数形态已真机取证 2026-09-22）
  // ★ r378：占位文案 `fsGap2FavoriteReorderPending` 已**三处一并删除**
  //   （ARB en/zh + l10n 映射 + 本常量）—— 它自述"取证后不再使用"，留着就是一条会撒谎的死串。
  static const favoriteReorder = 'fsGap2FavoriteReorder';
  static const favoriteReorderSave = 'fsGap2FavoriteReorderSave';
  static const favoriteReordered = 'fsGap2FavoriteReordered';
  static const favoriteReorderFailed = 'fsGap2FavoriteReorderFailed';
  static const favoriteReorderRejected = 'fsGap2FavoriteReorderRejected';

  /// `{head}（{detail}）` —— 中英括号/间距不同，走模板而不是手拼全角括号。
  static const favoriteReorderRejectedDetail =
      'fsGap2FavoriteReorderRejectedDetail';

  /// `收藏顺序保存失败：<原因>` 里的全角冒号（英文用 `: `）
  static const errorDetailSeparator = 'fsGap2ErrorDetailSeparator';
  static const moveUp = 'fsGap2MoveUp';
  static const moveDown = 'fsGap2MoveDown';

  // M51 个人文件夹固定入口
  static const personalFolder = 'fsGap2PersonalFolder';

  // M58 后台任务重试
  static const taskRetry = 'fsGap2TaskRetry';
  static const taskRetryNoPlan = 'fsGap2TaskRetryNoPlan';
  static const taskRetrySubmitted = 'fsGap2TaskRetrySubmitted';
  /// ★303：任务详情里的口令类参数打码后的显示文案
  static const taskParamSecretMasked = 'fsGap2TaskParamSecretMasked';

  // M72 主屏快捷方式
  static const shortcut = 'fsGap2Shortcut';
  static const shortcutDone = 'fsGap2ShortcutDone';
  static const shortcutFailed = 'fsGap2ShortcutFailed';
}
