// G3 笔记高级搜索条件 + G7 排除子标签 —— **纯逻辑**（可离线单测，无网络/无 UI）。
//
// ## 接口出处（全部标注，不凭印象）
//
// * **服务端真实可用的过滤参数**（我们走服务端 FTS）：来自 2026-09-22 对
//   DSM 7.2 / 普通用户的**真机只读行为对照**（探针 `/tmp/live_probe_lib.py`，
//   GET-only）。完整证据与"被忽略的参数清单"见
//   `NoteStationApi.searchNotes` 的文档注释。要点：
//     - 真过滤：`keyword` / `title` / `tag`(标签 id) / `parent_id` /
//       `mtime_start`/`mtime_end`/`ctime_start`/`ctime_end` / `offset` / `limit`；
//     - 被静默忽略：`note_title` / `notebook` / `date_from` / `date_to` …
//   ⇒ **本文件的模型只用行为已证的名字**，不臆造。
// * **G3 的官方条件集**：官方 Android 反编译
//   `fragments/AdvancedSearchDialogFragment.java` 的
//   `newInstance(query, time, from, to, tags, notebookIds, tagAndOperator)`
//   与 `tasks/AdvancedSearchTask.java#isFiltered`（ctime/mtime 区间、标签
//   AND/OR、笔记本 `parent_id`）。
//   ⚠️ **官方 Android 的高级搜索是纯客户端**（本地 FTS 索引 + 本地过滤），
//   它**不调** `SYNO.NoteStation.FTS/search`；我们选择服务端 FTS，因为
//   那台 NAS 上的参数已用行为对照取证。
// * **G7 的官方行为**：官方 Android
//   `fragments/NoteListFragment.java`：
//     - `private enum TagMode { EXCLUSIVE, INCLUDE }`（`:151-160`）；
//     - 默认值 `PREF_TAG_MODE` 缺省 = `TagMode.EXCLUSIVE`（`:477`）；
//     - 菜单 `R.id.subtag` 在两者间切换，标题分别是
//       `R.string.tag_show_subtag` / `R.string.tag_exclude_subtag`（`:380-430`）；
//     - `INCLUDE` 时把 `Common.Filter.TAG` 换成 `Common.Filter.TAG_WITH_CHILD`
//       交给本地查询（`:935-945`）—— 即"是否把子标签的笔记也算进来"。
//   ⇒ "排除子标签"是**客户端视图语义**，服务端**没有**对应参数（真机行为对照
//     已证 `tag_exclude_subtag` / `exclude_tag` / `exclude_tags` 全部被忽略）。
// * **子标签的判定**：不是 `parent_tag_id`，而是**标题里的 `/` 分层**，
//   逐字依据与纯函数移植见 `note_tag_tree.dart`。
//   ⇒ 排除"某标签及其子标签"在客户端是**可判定**的：用 `Tag/list` 每个标签的
//     直接成员（`TagDto.itemIds`），把后代标签的成员并起来即可（见
//     [excludedNoteIdsForTags]）。不需要每条笔记的 tag 字段（`Note/list`
//     根本不回 `tag`）。
//
// ## ⚠️ 未取证 / 已知边界（如实登记，不臆断）
//
// * 本 NAS **没有子标签树**（`Tag/list` 只有 1 个标签、无 `/`），所以
//   "排除子标签"的**端到端语义无法在本机验证**；本文件只保证**纯逻辑**
//   在合成的标签树上正确（离线用例覆盖）。
// * 服务端 `Note/list` / `FTS/search` 的 `tag` 过滤**是否已包含子标签**，本机
//   同样无法验证（没有子标签）。因此 `includeSubTags == false` 的排除是
//   **客户端补做**：它只会**减少**结果（单调），不会因为服务端语义未知而
//   多出错误结果。
// * 已知边界：一条笔记若**同时**带父标签和子标签，`includeSubTags == false`
//   时它会被排除；官方本地查询（按 tag_id 精确匹配）会保留它。该差异需要
//   一条带父子标签的真机数据才能定论 ⇒ 登记为**待确认**。
library;

import 'package:flutter/foundation.dart';

import 'note_tag_tree.dart';

/// G3：笔记高级搜索的一次查询（不可变）。
///
/// 只承载**行为已取证**的条件；界面缺省值遵循官方：
/// [includeSubTags] 缺省 `false`（官方 `TagMode.EXCLUSIVE` 是缺省值）。
@immutable
class NoteAdvSearchQuery {
  const NoteAdvSearchQuery({
    this.keyword = '',
    this.title = '',
    this.tagTitles = const [],
    this.tagAndOperator = false,
    this.includeSubTags = false,
    this.excludeTagTitles = const [],
    this.parentIds = const [],
    this.mtimeFrom,
    this.mtimeTo,
    this.ctimeFrom,
    this.ctimeTo,
  });

  /// 全文关键词（服务端 `keyword`）
  final String keyword;

  /// 标题包含（服务端 `title`；官方 res 名是 `note_title`，但那**不是**线上名）
  final String title;

  /// 选中的标签（**标题**，界面语言）。下发前按 [resolvedTagIds] 换成标签 id。
  final List<String> tagTitles;

  /// `true` = 同时包含（交集），`false` = 包含任一（并集）。
  /// 官方 `AdvancedSearchDialogFragment` 的 `tag_and_operator` 开关（仅当
  /// `NetUtils.isSupportTagAndOperator` 时可见）。
  final bool tagAndOperator;

  /// G7：`false` = **排除**所选标签的子标签（官方 `TagMode.EXCLUSIVE`）。
  final bool includeSubTags;

  /// G7：要**排除的标签**（连它的全部后代标签一起排除）。客户端行为。
  final List<String> excludeTagTitles;

  /// 限定笔记本（服务端 `parent_id`）
  final List<String> parentIds;

  final DateTime? mtimeFrom;
  final DateTime? mtimeTo;
  final DateTime? ctimeFrom;
  final DateTime? ctimeTo;

  /// 至少有一个条件才允许发起搜索（官方也是"先给条件再搜"）。
  bool get isEmpty =>
      keyword.trim().isEmpty &&
      title.trim().isEmpty &&
      tagTitles.isEmpty &&
      excludeTagTitles.isEmpty &&
      parentIds.isEmpty &&
      mtimeFrom == null &&
      mtimeTo == null &&
      ctimeFrom == null &&
      ctimeTo == null;

  bool get isNotEmpty => !isEmpty;

  /// 选中标签 → 服务端要的标签 id 列表（顺序保持；取不到的丢掉）。
  List<String> resolvedTagIds(Map<String, String> tagIdByTitle) => [
    for (final t in tagTitles)
      if ((tagIdByTitle[t] ?? '').isNotEmpty) tagIdByTitle[t]!,
  ];

  /// `mtime_start` / `mtime_end`：官方 `AdvancedSearchTask#isFiltered` 是
  /// **秒**（`getTimeInMillis()/1000`），下界取当天 0 点，上界取**次日 0 点**
  /// （官方 `setTo` 里 `add(6, 1)`）——即"上界开区间"。
  int? get mtimeFromSeconds => startOfDaySeconds(mtimeFrom);
  int? get mtimeToSeconds => nextDayStartSeconds(mtimeTo);
  int? get ctimeFromSeconds => startOfDaySeconds(ctimeFrom);
  int? get ctimeToSeconds => nextDayStartSeconds(ctimeTo);

  NoteAdvSearchQuery copyWith({
    String? keyword,
    String? title,
    List<String>? tagTitles,
    bool? tagAndOperator,
    bool? includeSubTags,
    List<String>? excludeTagTitles,
    List<String>? parentIds,
    DateTime? mtimeFrom,
    DateTime? mtimeTo,
    DateTime? ctimeFrom,
    DateTime? ctimeTo,
    bool clearMtimeFrom = false,
    bool clearMtimeTo = false,
    bool clearCtimeFrom = false,
    bool clearCtimeTo = false,
  }) => NoteAdvSearchQuery(
    keyword: keyword ?? this.keyword,
    title: title ?? this.title,
    tagTitles: tagTitles ?? this.tagTitles,
    tagAndOperator: tagAndOperator ?? this.tagAndOperator,
    includeSubTags: includeSubTags ?? this.includeSubTags,
    excludeTagTitles: excludeTagTitles ?? this.excludeTagTitles,
    parentIds: parentIds ?? this.parentIds,
    mtimeFrom: clearMtimeFrom ? null : (mtimeFrom ?? this.mtimeFrom),
    mtimeTo: clearMtimeTo ? null : (mtimeTo ?? this.mtimeTo),
    ctimeFrom: clearCtimeFrom ? null : (ctimeFrom ?? this.ctimeFrom),
    ctimeTo: clearCtimeTo ? null : (ctimeTo ?? this.ctimeTo),
  );

  /// 客户端要排除的笔记 id 集合：把 [excludeTagTitles] 展开成"标签 + 全部后代"
  /// 后取并集；若 [includeSubTags] 为 `false`，再把 [tagTitles] 的**后代**
  /// （不含自身）并进来。
  ///
  /// [tags] 是 `Tag/list` 的投影：标题 + 该标签**直接**挂的笔记 id。
  Set<String> clientExcludedNoteIds(
    Iterable<({String title, List<String> itemIds})> tags,
  ) {
    final all = tags.toList(growable: false);
    final excluded = <String>{};
    excluded.addAll(
      excludedNoteIdsForTags(all, excludeTagTitles, includeRoot: true),
    );
    if (!includeSubTags && tagTitles.isNotEmpty) {
      excluded.addAll(
        excludedNoteIdsForTags(all, tagTitles, includeRoot: false),
      );
    }
    return excluded;
  }

  @override
  bool operator ==(Object other) =>
      other is NoteAdvSearchQuery &&
      other.keyword == keyword &&
      other.title == title &&
      _listEq(other.tagTitles, tagTitles) &&
      other.tagAndOperator == tagAndOperator &&
      other.includeSubTags == includeSubTags &&
      _listEq(other.excludeTagTitles, excludeTagTitles) &&
      _listEq(other.parentIds, parentIds) &&
      other.mtimeFrom == mtimeFrom &&
      other.mtimeTo == mtimeTo &&
      other.ctimeFrom == ctimeFrom &&
      other.ctimeTo == ctimeTo;

  @override
  int get hashCode => Object.hash(
    keyword,
    title,
    Object.hashAll(tagTitles),
    tagAndOperator,
    includeSubTags,
    Object.hashAll(excludeTagTitles),
    Object.hashAll(parentIds),
    mtimeFrom,
    mtimeTo,
    ctimeFrom,
    ctimeTo,
  );

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 校验：给 [start] / [end] 两个日期，返回错误文案 key（无错返回 `null`）。
///
/// 与官方一致：起始晚于结束是非法输入（官方日期选择器也按区间用）。
String? noteAdvSearchDateOrderError(DateTime? start, DateTime? end) {
  if (start == null || end == null) return null;
  final s = DateTime(start.year, start.month, start.day);
  final e = DateTime(end.year, end.month, end.day);
  return e.isBefore(s) ? 'noteAdvSearchDateInvalid' : null;
}

/// 当天的 0 点（本地时区）→ epoch 秒。
int? startOfDaySeconds(DateTime? d) {
  if (d == null) return null;
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;
}

/// **次日** 0 点（本地时区）→ epoch 秒（官方 `setTo` 的 `add(6, 1)` 语义）。
int? nextDayStartSeconds(DateTime? d) {
  if (d == null) return null;
  return DateTime(d.year, d.month, d.day + 1).millisecondsSinceEpoch ~/ 1000;
}

/// G7：把 [root] 自身（[includeRoot] 为真时）与它的**全部后代标签标题**
/// 展开出来。后代判定走 [noteTagIsDescendant]（官方 `checkTagIsParent` 移植）。
///
/// [allTitles] 是当前已知的全部标签标题（扁平表）。
List<String> noteTagSubtreeTitles(
  Iterable<String> allTitles,
  String root, {
  bool includeRoot = true,
}) {
  if (root.isEmpty) return const [];
  final known = allTitles.toSet();
  final out = <String>[
    if (includeRoot && known.contains(root)) root,
    for (final t in known)
      if (t != root && noteTagIsDescendant(root, t)) t,
  ];
  return out;
}

/// G7：算出要排除的**笔记 id** 集合。
///
/// 对 [roots] 里的每个标签，展开成"标签 + 后代"（[includeRoot] 控制是否含自身），
/// 再把这些标签在 [tags] 里的**直接成员**（`Tag/list` 的 `items`）并起来。
Set<String> excludedNoteIdsForTags(
  Iterable<({String title, List<String> itemIds})> tags,
  Iterable<String> roots, {
  bool includeRoot = true,
}) {
  final all = tags.toList(growable: false);
  final allTitles = all.map((t) => t.title);
  final members = <String, List<String>>{
    for (final t in all) t.title: t.itemIds,
  };
  final excluded = <String>{};
  for (final root in roots) {
    for (final title in noteTagSubtreeTitles(
      allTitles,
      root,
      includeRoot: includeRoot,
    )) {
      excluded.addAll(members[title] ?? const []);
    }
  }
  return excluded;
}

/// 按 id 集合过滤一条结果列表（保持原顺序）。
List<T> applyNoteIdExclusions<T>(
  List<T> notes,
  String Function(T) idOf,
  Set<String> excluded,
) {
  if (excluded.isEmpty) return notes;
  return [for (final n in notes) if (!excluded.contains(idOf(n))) n];
}
