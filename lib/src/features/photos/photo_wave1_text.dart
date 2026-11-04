// 相册模块 "wave1" 新增界面文案（时间轴分页 / 年视图 / 相册排序 / 移到复制到文件夹）：
// **key + 中文原文**。
//
// 与 `photo_p0_text.dart` / `photo_p1_text.dart` / `photo_c2_text.dart` 同一套
// 约定：`.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，新文案走数据层的
// `data_text.dart`（key + 中文原文；装了翻译器就出译文，否则回落中文）。
// 每一条的 key 就是要追加的 ARB key，清单见 `docs/photo-gaps-wave1.md`。
//
// 复用原则：能复用既有 `photo*` / `photoP0*` / `photoP1*` / `photoC2*` key 的
// **一律复用**，本文件只放"确实没有的"那几条。
import '../../core/i18n/data_text.dart';

/// 取 wave1 新文案（key 见 [PhotoWave1TextKeys]）
String photoWave1(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{count}` / `{error}` / `{year}` …）
String photoWave1Fill(String key, String zh, Map<String, String> values) {
  var out = photoWave1(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class PhotoWave1TextKeys {
  // 时间轴年视图（官方 `str_year_view_mode` / `str_day_view_mode` /
  // `str_month_view_mode`；官方文案分别是 `Year` / `Day` / `Month`）
  static const timelineViewDay = 'photoWave1TimelineViewDay';
  static const timelineViewMonth = 'photoWave1TimelineViewMonth';
  static const timelineViewYear = 'photoWave1TimelineViewYear';
  static const timelineViewMode = 'photoWave1TimelineViewMode';
  static const groupYear = 'photoWave1GroupYear';

  // 时间轴增量分页
  static const loadMore = 'photoWave1LoadMore';
  static const loadingMore = 'photoWave1LoadingMore';
  static const allLoaded = 'photoWave1AllLoaded';
  static const loadMoreFailed = 'photoWave1LoadMoreFailed';

  // 相册排序（官方 `str_sort_by` / `str_sorting_option_desc` / `dialog_sort_settings`）
  static const albumSort = 'photoWave1AlbumSort';
  static const albumSortBy = 'photoWave1AlbumSortBy';
  static const albumSortDirection = 'photoWave1AlbumSortDirection';
  static const albumSortName = 'photoWave1AlbumSortName';
  static const albumSortCreateTime = 'photoWave1AlbumSortCreateTime';
  static const albumSortStartTime = 'photoWave1AlbumSortStartTime';
  static const albumSortType = 'photoWave1AlbumSortType';
  static const albumSortSharingStatus = 'photoWave1AlbumSortSharingStatus';
  static const albumSortShareModTime = 'photoWave1AlbumSortShareModTime';
  static const albumSortAsc = 'photoWave1AlbumSortAsc';
  static const albumSortDesc = 'photoWave1AlbumSortDesc';
  static const albumSortSaved = 'photoWave1AlbumSortSaved';
  static const albumSortFailed = 'photoWave1AlbumSortFailed';

  // 多选：移到 / 复制到文件夹（`Browse.Item/move|copy`）
  static const moveToFolder = 'photoWave1MoveToFolder';
  static const copyToFolder = 'photoWave1CopyToFolder';
  static const moveCopyPickFolder = 'photoWave1MoveCopyPickFolder';
  static const moveCopyNoFolders = 'photoWave1MoveCopyNoFolders';
  static const movedCount = 'photoWave1MovedCount';
  static const copiedCount = 'photoWave1CopiedCount';
  static const moveCopyFailed = 'photoWave1MoveCopyFailed';
}
