// Drive **D8 收藏集**新增界面文案：**key + 中文原文**，与
// `drive_c1_text.dart` / `drive_g4_text.dart` / `drive_g6_text.dart` /
// `drive_wave2_text.dart` 同构。
//
// 为什么不用 `context.t`：这些 key 的 ARB 尚未补齐（`lib/l10n/*.arb` 与
// `lib/l10n/gen/**` 由别的批次负责），这里沿用 `data_text.dart` 的约定
// （key + 中文原文，语言切换时由 `setCurrentText` 注入译文，取不到就回落中文）。
// 每一条的 key 就是要追加进 ARB 的 key（见报告"未完成清单"）。
import '../../core/i18n/data_text.dart';
import '../../data/dto/drive_collection_dto.dart';

/// 取 D8 新文案（key 见 [DriveCollectionTextKeys]）
String driveCollection(String key, String zh) => dataText(key, zh);

/// 带 `{...}` 占位符的文案填充（绝不把占位符当字面量送进 UI）
String driveCollectionFill(
  String key,
  String zh,
  Map<String, String> values,
) {
  var out = driveCollection(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 收藏集类型的界面名（服务端类型串 → 人话）。
///
/// 原文依据：`LabelImpl.TYPE_COLLECTION_*` 四个串（见
/// `drive_collection_dto.dart`）。**未知类型不硬套**，回退到通用文案。
String driveCollectionTypeLabel(DriveCollectionType type) => switch (type) {
  DriveCollectionType.photo => driveCollection(
    DriveCollectionTextKeys.typePhoto,
    '照片收藏集',
  ),
  DriveCollectionType.document => driveCollection(
    DriveCollectionTextKeys.typeDocument,
    '文档收藏集',
  ),
  DriveCollectionType.audio => driveCollection(
    DriveCollectionTextKeys.typeAudio,
    '音乐收藏集',
  ),
  DriveCollectionType.video => driveCollection(
    DriveCollectionTextKeys.typeVideo,
    '视频收藏集',
  ),
};

/// 本批次新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class DriveCollectionTextKeys {
  // 入口 / 总标题
  static const title = 'driveD8CollectionTitle';
  static const entry = 'driveD8CollectionEntry';
  static const entryHint = 'driveD8CollectionEntryHint';
  static const all = 'driveD8CollectionAll';
  static const emptyTitle = 'driveD8CollectionEmptyTitle';
  static const emptyBody = 'driveD8CollectionEmptyBody';
  static const loadFailed = 'driveD8CollectionLoadFailed';
  static const count = 'driveD8CollectionCount';

  // 四个类型
  static const typePhoto = 'driveD8CollectionTypePhoto';
  static const typeDocument = 'driveD8CollectionTypeDocument';
  static const typeAudio = 'driveD8CollectionTypeAudio';
  static const typeVideo = 'driveD8CollectionTypeVideo';

  // 建 / 改名 / 删（写方法：只走代码，未真机调）
  static const create = 'driveD8CollectionCreate';
  static const createTitle = 'driveD8CollectionCreateTitle';
  static const nameHint = 'driveD8CollectionNameHint';
  static const rename = 'driveD8CollectionRename';
  static const renameTitle = 'driveD8CollectionRenameTitle';
  static const delete = 'driveD8CollectionDelete';
  static const deleteConfirm = 'driveD8CollectionDeleteConfirm';
  static const deleteBody = 'driveD8CollectionDeleteBody';
  static const created = 'driveD8CollectionCreated';
  static const renamed = 'driveD8CollectionRenamed';
  static const deleted = 'driveD8CollectionDeleted';

  // 成员（加入 / 移出；`Files/label`）
  static const removeFromCollection = 'driveD8CollectionRemoveFromCollection';
  static const removeConfirm = 'driveD8CollectionRemoveConfirm';
  static const removeBody = 'driveD8CollectionRemoveBody';
  static const removed = 'driveD8CollectionRemoved';
  static const addToCollection = 'driveD8CollectionAddToCollection';

  // 收藏集内的文件
  static const filesEmptyTitle = 'driveD8CollectionFilesEmptyTitle';
  static const filesEmptyBody = 'driveD8CollectionFilesEmptyBody';
  static const filesLoadFailed = 'driveD8CollectionFilesLoadFailed';

  // 失败
  static const actionFailed = 'driveD8CollectionActionFailed';
}
