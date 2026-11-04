// 文件模块「剩余可做缺口 wave1」新增界面文案：**key + 中文原文**。
//
// 约定与 `filestation_p0a_text.dart` / `filestation_p0b_text.dart` 一致：
// `.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，所以新文案一律 `key + 中文原文`，
// 走 `dataText`（`lib/src/core/i18n/data_text.dart`）。ARB 里补上同名 key 后，
// 注入的翻译表会自动把中文原文换成当前语言译文；没补上时回落中文原文。
//
// 本批覆盖：
//   * M04 目录分页的触底/收尾三态（`fsGapNoMore` / `fsGapLoadingMore` / …）
//   * M36 分享链接编辑（`fsGapEditShareLink` / `fsGapShareEdited` / …）
//   * M37 分享链接发送（`fsGapShareSend` / `fsGapShareSendFailed`）
//   * M12 只读共享标识（`fsGapReadOnlyShare`）
//
// 现有 key 清单（交给父 agent 并入 `app_zh.arb` / `app_en.arb`）：
//   * `fsGapNoMore`            —— 没有更多了
//   * `fsGapLoadingMore`       —— 正在加载更多…
//   * `fsGapLoadMoreFailed`    —— 加载更多失败
//   * `fsGapRetry`             —— 重试
//   * `fsGapEditShareLink`     —— 编辑分享链接
//   * `fsGapShareNewPassword`  —— 新密码
//   * `fsGapSharePasswordKeep` —— 保持当前密码
//   * `fsGapSharePasswordRemove` —— 移除密码（**未取证**：服务端空串语义）
//   * `fsGapShareValidityKeep` —— 保持当前有效期
//   * `fsGapShareEdited`       —— 分享链接已更新
//   * `fsGapShareSend`         —— 发送
//   * `fsGapShareSendFailed`   —— 发送失败（没有可用的应用）
//   * `fsGapReadOnlyShare`     —— 只读共享
import '../../core/i18n/data_text.dart';

/// 取本批新文案的译文；[zh] 是中文原文（回落值）。
String fsGap(String key, String zh) => dataText(key, zh);

/// 本批次新增的 ARB key（下一步照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class FsGapTextKeys {
  // M04 分页
  static const noMore = 'fsGapNoMore';
  static const loadingMore = 'fsGapLoadingMore';
  static const loadMoreFailed = 'fsGapLoadMoreFailed';
  static const retry = 'fsGapRetry';

  // M36 分享链接编辑
  static const editShareLink = 'fsGapEditShareLink';
  static const shareNewPassword = 'fsGapShareNewPassword';
  static const sharePasswordKeep = 'fsGapSharePasswordKeep';
  static const sharePasswordRemove = 'fsGapSharePasswordRemove';
  static const shareValidityKeep = 'fsGapShareValidityKeep';
  static const shareEdited = 'fsGapShareEdited';
  // 第 251 轮：官方 edit 路径**不能取消**既有有效期（APK 省略 date_expired；
  // 服务端 .so 只认 %Y-%m-%d 形式，空串很可能直接报错），界面如实说明。
  static const sharePermanentEditNote = 'fsGapSharePermanentEditNote';

  // M37 分享链接发送
  static const shareSend = 'fsGapShareSend';
  static const shareSendFailed = 'fsGapShareSendFailed';

  // M12 只读共享标识
  static const readOnlyShare = 'fsGapReadOnlyShare';
}
