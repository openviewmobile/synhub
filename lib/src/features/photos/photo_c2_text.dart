// C2（Photos 补齐）新增界面文案：**key + 中文原文**。
//
// 与 C1（Drive）同一套约定：`.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，
// 所以新文案走数据层的 `dataText.dart`（key + 中文原文；装了翻译器就出译文，
// 否则回落中文）。每一条的 key 就是要追加的 ARB key，清单见
// `docs/workspace-expansion-evaluation.md` 的「实施记录（C2 · Photos）」。
//
// 已经存在的文案（取消 / 删除 / 重试 / 加载失败 …）一律继续走 `context.t`。
import '../../core/i18n/data_text.dart';

/// 取 C2 新文案（key 见 [PhotoC2TextKeys]）
String photoC2(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{name}` / `{count}` / `{error}` …）
String photoC2Fill(String key, String zh, Map<String, String> values) {
  var out = photoC2(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批次新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class PhotoC2TextKeys {
  // 入口 / 总标题
  static const hub = 'photoC2Hub';
  static const hubTitle = 'photoC2HubTitle';
  static const hubSubtitle = 'photoC2HubSubtitle';

  // 共享相册
  static const sharing = 'photoC2Sharing';
  static const sharingEntry = 'photoC2SharingEntry';
  static const sharedWithMe = 'photoC2SharedWithMe';
  static const sharedByMe = 'photoC2SharedByMe';
  static const sharedEmpty = 'photoC2SharedEmpty';
  static const sharedByMeEmpty = 'photoC2SharedByMeEmpty';
  static const sharedFrom = 'photoC2SharedFrom';
  static const shareModifiedAt = 'photoC2ShareModifiedAt';
  static const members = 'photoC2Members';
  static const membersEmpty = 'photoC2MembersEmpty';
  static const addMember = 'photoC2AddMember';
  static const addMemberEmpty = 'photoC2AddMemberEmpty';
  static const removeMember = 'photoC2RemoveMember';
  static const removeMemberConfirm = 'photoC2RemoveMemberConfirm';
  static const removeMemberBody = 'photoC2RemoveMemberBody';
  static const memberRemoved = 'photoC2MemberRemoved';
  static const memberAdded = 'photoC2MemberAdded';
  static const roleView = 'photoC2RoleView';
  static const roleDownload = 'photoC2RoleDownload';
  static const roleUpload = 'photoC2RoleUpload';
  static const roleManage = 'photoC2RoleManage';
  static const roleUpdated = 'photoC2RoleUpdated';
  static const shareLink = 'photoC2ShareLink';
  static const shareLinkNone = 'photoC2ShareLinkNone';
  static const copyLink = 'photoC2CopyLink';
  static const linkCopied = 'photoC2LinkCopied';
  static const linkEnabled = 'photoC2LinkEnabled';
  static const disableLink = 'photoC2DisableLink';
  static const disableLinkConfirm = 'photoC2DisableLinkConfirm';
  static const disableLinkBody = 'photoC2DisableLinkBody';
  static const linkClosed = 'photoC2LinkClosed';
  static const passwordPending = 'photoC2PasswordPending';

  // 照片请求
  static const photoRequest = 'photoC2PhotoRequest';
  static const photoRequestEntry = 'photoC2PhotoRequestEntry';
  static const photoRequestCreate = 'photoC2PhotoRequestCreate';
  static const photoRequestCreateHint = 'photoC2PhotoRequestCreateHint';
  static const photoRequestEdit = 'photoC2PhotoRequestEdit';
  static const photoRequestSaved = 'photoC2PhotoRequestSaved';
  static const photoRequestEmpty = 'photoC2PhotoRequestEmpty';
  static const photoRequestDelete = 'photoC2PhotoRequestDelete';
  static const photoRequestDeleteConfirm = 'photoC2PhotoRequestDeleteConfirm';
  static const photoRequestDeleteBody = 'photoC2PhotoRequestDeleteBody';
  static const photoRequestDeleted = 'photoC2PhotoRequestDeleted';
  static const photoRequestNeverExpires = 'photoC2PhotoRequestNeverExpires';
  static const photoRequestExpires = 'photoC2PhotoRequestExpires';

  // 地点
  static const geocoding = 'photoC2Geocoding';
  static const geocodingEntry = 'photoC2GeocodingEntry';
  static const geocodingEmpty = 'photoC2GeocodingEmpty';
  static const geocodingServiceHint = 'photoC2GeocodingServiceHint';
  static const geocodingItemCount = 'photoC2GeocodingItemCount';

  // 搜索
  static const search = 'photoC2Search';
  static const searchEntry = 'photoC2SearchEntry';
  static const searchHint = 'photoC2SearchHint';
  static const searchEmpty = 'photoC2SearchEmpty';
  static const searchNoKeyword = 'photoC2SearchNoKeyword';
  static const searchResultCount = 'photoC2SearchResultCount';
  static const searchKeywordOnly = 'photoC2SearchKeywordOnly';

  // 条件相册
  static const conditionAlbum = 'photoC2ConditionAlbum';
  static const conditionAlbumEntry = 'photoC2ConditionAlbumEntry';
  static const conditionAlbumEmpty = 'photoC2ConditionAlbumEmpty';
  static const conditionAlbumDelete = 'photoC2ConditionAlbumDelete';
  static const conditionAlbumDeleteConfirm =
      'photoC2ConditionAlbumDeleteConfirm';
  static const conditionAlbumDeleteBody = 'photoC2ConditionAlbumDeleteBody';
  static const conditionAlbumDeleted = 'photoC2ConditionAlbumDeleted';
  static const conditionSummary = 'photoC2ConditionSummary';
  static const conditionNone = 'photoC2ConditionNone';
  static const conditionInvalid = 'photoC2ConditionInvalid';
  static const conditionPeek = 'photoC2ConditionPeek';
  static const conditionPeekCount = 'photoC2ConditionPeekCount';
  static const conditionKindTime = 'photoC2ConditionKindTime';
  static const conditionKindPlace = 'photoC2ConditionKindPlace';
  static const conditionKindPerson = 'photoC2ConditionKindPerson';
  static const conditionKindTag = 'photoC2ConditionKindTag';
  static const conditionKindKeyword = 'photoC2ConditionKindKeyword';
  static const conditionKindOther = 'photoC2ConditionKindOther';

  // 相似照片
  static const similar = 'photoC2Similar';
  static const similarEntry = 'photoC2SimilarEntry';
  static const similarDisabled = 'photoC2SimilarDisabled';
  static const similarDisabledHint = 'photoC2SimilarDisabledHint';
  static const similarIndexing = 'photoC2SimilarIndexing';
  static const similarIndexingHint = 'photoC2SimilarIndexingHint';
  static const similarReady = 'photoC2SimilarReady';
  static const similarEmpty = 'photoC2SimilarEmpty';

  // 可用性 / 权限
  static const noPermission = 'photoC2NoPermission';
  static const noPermissionHint = 'photoC2NoPermissionHint';
  static const sessionHint = 'photoC2SessionHint';
  static const entryHidden = 'photoC2EntryHidden';
  static const actionFailed = 'photoC2ActionFailed';
  static const notConnected = 'photoC2NotConnected';

  // 条件相册：服务端分组键（`aperture`/`camera`/…）→ 可显示标题
  static const groupAperture = 'photoC2GroupAperture';
  static const groupCamera = 'photoC2GroupCamera';
  static const groupLens = 'photoC2GroupLens';
  static const groupFlash = 'photoC2GroupFlash';
  static const groupExposureTime = 'photoC2GroupExposureTime';
  static const groupFocalLength = 'photoC2GroupFocalLength';
  static const groupGeocoding = 'photoC2GroupGeocoding';
  static const groupPerson = 'photoC2GroupPerson';
  static const groupTag = 'photoC2GroupTag';
  static const groupConcept = 'photoC2GroupConcept';
  static const groupRating = 'photoC2GroupRating';
  static const groupFavorite = 'photoC2GroupFavorite';
  static const groupTime = 'photoC2GroupTime';
  static const groupItemType = 'photoC2GroupItemType';
}
