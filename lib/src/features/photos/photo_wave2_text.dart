// 相册模块 "wave2" 新增界面文案（搜索筛选面板 / 标签浏览 / 人物人脸）：
// **key + 中文原文**。
//
// 与 `photo_p0_text.dart` / `photo_p1_text.dart` / `photo_c2_text.dart` /
// `photo_wave1_text.dart` 同一套约定：`.arb` 与 `lib/l10n/gen/**` 在本批次
// **禁碰**，新文案走数据层的 `data_text.dart`（key + 中文原文；装了翻译器就出
// 译文，否则回落中文）。每一条的 key 就是要追加的 ARB key，清单见
// `docs/photo-gaps-wave2.md` §5。
//
// 复用原则：分页（加载更多 / 到底 / 失败重试）**直接复用 wave1 的
// `photoWave1*` key**；人物空态 / 迁移进度复用既有 `photo*` / `photoP0*` key，
// 本文件只放"确实没有的"那几条。
import '../../core/i18n/data_text.dart';

/// 取 wave2 新文案（key 见 [PhotoWave2TextKeys]）
String photoWave2(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{count}` / `{group}` …）
String photoWave2Fill(String key, String zh, Map<String, String> values) {
  var out = photoWave2(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class PhotoWave2TextKeys {
  // ---- 搜索筛选面板（`Search.Filter/list` v4）
  static const searchFilter = 'photoWave2SearchFilter';
  static const searchFilterTitle = 'photoWave2SearchFilterTitle';
  static const searchFilterApply = 'photoWave2SearchFilterApply';
  static const searchFilterClear = 'photoWave2SearchFilterClear';
  static const searchFilterUnavailable = 'photoWave2SearchFilterUnavailable';
  static const searchFilterActive = 'photoWave2SearchFilterActive';

  // ---- 标签浏览（`Browse.GeneralTag/list|get|count` + `Browse.Item/list_with_filter`）
  static const tags = 'photoWave2Tags';
  static const tagsEntry = 'photoWave2TagsEntry';
  static const tagsEmpty = 'photoWave2TagsEmpty';
  static const tagItemCount = 'photoWave2TagItemCount';
  static const tagPhotosEmpty = 'photoWave2TagPhotosEmpty';
  static const tagTotal = 'photoWave2TagTotal';
  /// 标签详情页**拿不到真总数**时的表头（已加载 N 张，不冒充总数）。
  static const tagLoaded = 'photoWave2TagLoaded';
  /// 服务端标签列表为空、列表来自本机记忆时的**来源说明**（不静默）。
  static const tagsLocalNote = 'photoWave2TagsLocalNote';

  // ---- 人物 / 人脸（`Browse.Person/list|count|get|suggest|list_face`）
  static const persons = 'photoWave2Persons';
  static const personsEntry = 'photoWave2PersonsEntry';
  static const personSearchHint = 'photoWave2PersonSearchHint';
  static const personSuggestEmpty = 'photoWave2PersonSuggestEmpty';
  static const personFaces = 'photoWave2PersonFaces';
  static const personFacesFailed = 'photoWave2PersonFacesFailed';

  /// 通用"某一小块内容取不到"的提示（计数 / 次要信息），**不是**空结果。
  static const partialUnavailable = 'photoWave2PartialUnavailable';
}
