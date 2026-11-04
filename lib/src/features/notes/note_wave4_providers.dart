// Wave4 笔记缺口：**全文检索（FTS）** 与 **快捷方式写入** 的 provider 层。
//
// 与笔记模块同一套约定：API 从会话里取（未连接 → null），数据 `autoDispose` +
// 关掉自动重试；写操作后只 invalidate，不做乐观更新。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import 'note_providers.dart';

Duration? _noRetry(int retryCount, Object error) => null;

/// `SYNO.NoteStation.FTS : search` **v1** 的全文检索结果（G1）。
///
/// 参数/回包逐字来自官方 Universal Search 插件
/// （`/tmp/spk/export_NoteStation/ui/notestation_finder.js` 的
/// `getSearchParam`：`{api:"SYNO.NoteStation.FTS",version:1,method:"search",
///   keyword,offset,limit}`；结果数组是 root `data.matches`）。
/// 真机复测（2026-09-22）：`{keyword}` 回真实 `data.matches[]`。
///
/// 三条硬纪律（本批任务的验收点）：
///   * **空关键字不发请求** —— `trim()` 后为空直接返回空列表（`Note:list` 那套
///     本地过滤不在这里做，检索页只认服务端结果）；
///   * 结果**只取 `matches`**（由 [NoteStationApi.searchNotes] 负责解析）；
///   * 失败**如实抛出**（不吞、不静默回落），页面按错误态呈现。
final noteFtsSearchProvider = FutureProvider.autoDispose
    .family<List<NoteDto>, String>((ref, keyword) async {
      final q = keyword.trim();
      if (q.isEmpty) return const <NoteDto>[];
      final api = ref.watch(noteApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.searchNotes(keyword: q);
    }, retry: _noRetry);

/// 某个笔记是否已在快捷方式里（用于「加入/取消快捷方式」的菜单文案）。
///
/// 直接读 [noteShortcutsProvider]，按 `items` 的目标 id 判定：官方 Android
/// `GenerateShortcutsLoader.createNote` 就是拿 `items[]` 的值当对象 id 查。
final noteIsShortcutProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, objectId) async {
      if (objectId.isEmpty) return false;
      final rows = await ref.watch(noteShortcutsProvider.future);
      return rows.any((s) => s.itemIds.contains(objectId) || s.id == objectId);
    }, retry: _noRetry);

// ---------------------------------------------------------------- 快捷方式写入

NoteStationApi _require(WidgetRef ref) {
  final api = ref.read(noteApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api;
}

/// 取消一个快捷方式（`Shortcut/delete` v1）。
///
/// 参数是**目标对象 id**（不是快捷方式自己的 `id`）—— 官方 Android
/// `DeleteShortcutLoader` 把 `refObjectId`（= `items[]` 的值）当 `source` 传给
/// `DeleteShortcutOperation`，后者再映射成远端 `object_id` / `tag_id`。
/// `items` 为空时才退回用快捷方式自身的 `id`。
Future<void> deleteNoteShortcut(WidgetRef ref, ShortcutDto shortcut) async {
  final api = _require(ref);
  final target = shortcut.itemIds.isNotEmpty ? shortcut.itemIds.first : shortcut.id;
  if (shortcut.category == 'tag') {
    await api.deleteShortcut(tagId: target);
  } else {
    await api.deleteShortcut(objectId: target);
  }
  ref.invalidate(noteShortcutsProvider);
}

/// 把一条笔记加入 / 移出快捷方式（F5 的 `set` / `delete`）。
Future<void> setNoteShortcut(
  WidgetRef ref,
  String objectId, {
  required bool add,
}) async {
  final api = _require(ref);
  if (add) {
    await api.setShortcut(objectId: objectId);
  } else {
    await api.deleteShortcut(objectId: objectId);
  }
  ref.invalidate(noteShortcutsProvider);
  ref.invalidate(noteIsShortcutProvider(objectId));
}
