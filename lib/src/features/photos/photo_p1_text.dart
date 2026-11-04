// 相册 P1（人物/场景计数与详情、共享成员与链接、搜索建议、相似时间轴分页、
// 条件相册创建/编辑/预览、时间轴上传、地点浏览、照片编辑）新增界面文案：
// **key + 中文原文**。
//
// 与 `photo_p0_text.dart` / `photo_c2_text.dart` 同一套约定：`.arb` 与
// `lib/l10n/gen/**` 在本批次**禁碰**，所以新文案走数据层的 `dataText.dart`
// （key + 中文原文；装了翻译器就出译文，否则回落中文）。每一条的 key 就是要
// 追加的 ARB key，清单见 `docs/photo-p1-implementation.md` 的「ARB key 清单」。
//
// 复用原则：能复用既有 `photo*` / `photoP0*` / `photoC2*` key 的
// **一律复用**，本文件只放"确实没有的"那几条。
import '../../core/i18n/data_text.dart';

/// 取 P1 新文案（key 见 [PhotoP1TextKeys]）
String photoP1(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{count}` / `{name}` / `{error}` …）
String photoP1Fill(String key, String zh, Map<String, String> values) {
  var out = photoP1(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class PhotoP1TextKeys {
  // 人物 / 场景：计数、分页、详情头
  static const personCount = 'photoP1PersonCount';
  static const conceptCount = 'photoP1ConceptCount';
  static const loadMoreRemaining = 'photoP1LoadMoreRemaining';
  static const countUnavailable = 'photoP1CountUnavailable';
  static const detailSummary = 'photoP1DetailSummary';

  // 共享：邀请成员 / 生成链接 / 打开外链
  static const createShareLink = 'photoP1CreateShareLink';
  static const createShareLinkHint = 'photoP1CreateShareLinkHint';
  static const enableShareLink = 'photoP1EnableShareLink';
  static const enableShareLinkConfirm = 'photoP1EnableShareLinkConfirm';
  static const enableShareLinkBody = 'photoP1EnableShareLinkBody';
  static const shareLinkCreated = 'photoP1ShareLinkCreated';
  static const passwordTitle = 'photoP1PasswordTitle';
  static const passwordEnabled = 'photoP1PasswordEnabled';
  static const passwordOff = 'photoP1PasswordOff';
  static const passwordField = 'photoP1PasswordField';
  static const passwordClearHint = 'photoP1PasswordClearHint';
  static const passwordSaved = 'photoP1PasswordSaved';
  static const expirationField = 'photoP1ExpirationField';
  static const expirationNever = 'photoP1ExpirationNever';
  static const linkNeedsPassphrase = 'photoP1LinkNeedsPassphrase';
  static const inviteRole = 'photoP1InviteRole';
  static const inviteConfirm = 'photoP1InviteConfirm';
  static const inviteSelected = 'photoP1InviteSelected';
  static const memberInvited = 'photoP1MemberInvited';

  // 搜索建议
  static const searchSuggestTitle = 'photoP1SearchSuggestTitle';
  static const searchSuggestEmpty = 'photoP1SearchSuggestEmpty';

  // 相似时间轴分页
  static const similarLoadMore = 'photoP1SimilarLoadMore';

  // 条件相册：创建 / 编辑 / 预览
  static const conditionCreate = 'photoP1ConditionCreate';
  static const conditionEdit = 'photoP1ConditionEdit';
  static const conditionName = 'photoP1ConditionName';
  static const conditionNameEmpty = 'photoP1ConditionNameEmpty';
  static const conditionType = 'photoP1ConditionType';
  static const conditionValue = 'photoP1ConditionValue';
  static const conditionValueEmpty = 'photoP1ConditionValueEmpty';
  static const conditionValueSearch = 'photoP1ConditionValueSearch';
  static const conditionNoPreview = 'photoP1ConditionNoPreview';
  static const conditionPolicyAnd = 'photoP1ConditionPolicyAnd';
  static const conditionPolicyOr = 'photoP1ConditionPolicyOr';
  static const conditionPeek = 'photoP1ConditionPeek';
  static const conditionPeekResult = 'photoP1ConditionPeekResult';
  static const conditionPeekFailed = 'photoP1ConditionPeekFailed';
  static const conditionCreated = 'photoP1ConditionCreated';
  static const conditionUpdated = 'photoP1ConditionUpdated';
  static const conditionNeedOne = 'photoP1ConditionNeedOne';
  static const conditionSuggestEmpty = 'photoP1ConditionSuggestEmpty';
  static const conditionSuggestFailed = 'photoP1ConditionSuggestFailed';
  static const conditionItemType = 'photoP1ConditionItemType';
  static const conditionItemTypeAll = 'photoP1ConditionItemTypeAll';
  static const conditionItemTypePhoto = 'photoP1ConditionItemTypePhoto';
  static const conditionItemTypeVideo = 'photoP1ConditionItemTypeVideo';
  static const conditionKeyword = 'photoP1ConditionKeyword';
  static const conditionUserIdMissing = 'photoP1ConditionUserIdMissing';

  // 时间轴上传
  static const uploadToTimeline = 'photoP1UploadToTimeline';
  static const uploadPickFailed = 'photoP1UploadPickFailed';
  static const uploadDone = 'photoP1UploadDone';
  static const uploadFailed = 'photoP1UploadFailed';

  // 地点 → 按地点浏览
  static const placeItemsEmpty = 'photoP1PlaceItemsEmpty';

  // 照片编辑
  static const editorTitle = 'photoP1EditorTitle';
  static const editorRotateCw = 'photoP1EditorRotateCw';
  static const editorRotateCcw = 'photoP1EditorRotateCcw';
  static const editorRotate180 = 'photoP1EditorRotate180';
  static const editorSaved = 'photoP1EditorSaved';
}
