// 文件模块 wave3「共享给我的」新增界面文案：**key + 中文原文**。
//
// 约定与 `filestation_gaps_wave1_text.dart` / `filestation_gaps_wave2_text.dart`
// 一致：`.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，所以新文案一律
// `key + 中文原文`，走 `dataText`（`lib/src/core/i18n/data_text.dart`）。
// ARB 里补上同名 key 后，注入的翻译表会自动把中文原文换成当前语言译文；
// 没补上时回落中文原文（中文回落）。
//
// ⚠️ 本文件的 key **一个都不带占位符**：`dataText` 只做 key→译文的查表，不做
// 参数替换，所以像"来自 X"这种动态串由调用点用 `'$label $value'` 拼
// （`file_pages.dart` 的 `_SharedWithMeTab`），别在 ARB 里写成 `{name}`。
//
// key 清单（交给父 agent 并入 `app_zh.arb` / `app_en.arb`）：
//   * `fsGap3ShareWithMe`          —— 共享给我的
//   * `fsGap3NoSharedWithMe`       —— 还没有人分享给你
//   * `fsGap3NoSharedWithMeMessage`—— 别人分享给你的文件会出现在这里
//   * `fsGap3SharedWithMeLoadFailed`—— 共享给我的列表加载失败
//   * `fsGap3SharedWithMeUnavailable`—— 服务器不支持"共享给我的"
//   * `fsGap3SharedBy`             —— 来自
//   * `fsGap3StatusExpired`        —— 已过期
//   * `fsGap3StatusInactive`       —— 未生效
//   * `fsGap3StatusOk`             —— 有效
//   * `fsGap3TypeSharingLinks`     —— 分享链接
//   * `fsGap3TypeRequestLink`      —— 文件请求
//   * `fsGap3TypeDocumentLink`     —— 文档链接
import '../../core/i18n/data_text.dart';

/// 取本批新文案的译文；[zh] 是中文原文（回落值）。
String fsGap3(String key, String zh) => dataText(key, zh);

/// 本批次新增的 ARB key（下一步照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class FsGap3TextKeys {
  /// 「共享给我的」分区 / Tab 标题
  static const shareWithMe = 'fsGap3ShareWithMe';

  /// 空态（真机 `links: []` 就是这个，不是错误）
  static const noSharedWithMe = 'fsGap3NoSharedWithMe';
  static const noSharedWithMeMessage = 'fsGap3NoSharedWithMeMessage';

  /// 加载失败 / 服务端不支持（103/105）
  static const loadFailed = 'fsGap3SharedWithMeLoadFailed';
  static const unavailable = 'fsGap3SharedWithMeUnavailable';

  /// "来自 {分享者}" 的前缀（调用点拼接分享者）
  static const sharedBy = 'fsGap3SharedBy';

  /// `status` 分支（官方列模型：broken / expired / inactive / 其余=ok）
  static const statusExpired = 'fsGap3StatusExpired';
  static const statusInactive = 'fsGap3StatusInactive';
  static const statusOk = 'fsGap3StatusOk';

  /// `project_name`（分享来源应用）→ 类型标签；取值见官方 `getTypeArray`
  static const typeSharingLinks = 'fsGap3TypeSharingLinks';
  static const typeRequestLink = 'fsGap3TypeRequestLink';
  static const typeDocumentLink = 'fsGap3TypeDocumentLink';
}
