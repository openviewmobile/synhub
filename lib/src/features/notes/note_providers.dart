// 笔记模块的 provider 层（P1 · NoteStation）。
//
// 结构与文件模块一致：API 层从会话里取（未连接 → null），
// 列表/详情各一个 `autoDispose` FutureProvider，**关掉自动重试**
// （Riverpod 3 默认的指数退避会让错误页永远出不来，见 `_noRetry`）。
//
// 关于本地缓存：官方 DS note 是"全量同步进 SQLite + 本地查询"。我们照这个模型
// 做了 Drift 缓存（`note_store.dart`）+ 离线写队列（`note_sync.dart`）：
//   * 网络成功 → 列表/正文落库（下次离线可读可搜）；
//   * 网络失败 → 回落到缓存并把 `fromCache: true` 交给 UI 显示离线横幅；
//   * 离线保存/删除 → 进队列，联网后 `NoteSyncNotifier.flushPending()` 重放。

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import '../chat/chat_session_controller.dart' show chatStoreProvider;
import '../servers/session_controller.dart';
import 'note_html.dart' show kSynoFontSizes;
import 'note_sync.dart';

/// Riverpod 3 默认对失败的 provider 做指数退避重试 → UI 会一直停在 loading。
/// 笔记模块一律关掉：失败就报到界面上（可手动重试）。
///
/// 注意要返回 `null`（= 不重试）而**不是抛异常** —— 抛出去会变成
/// "provider 之外的未捕获异常"，测试里会报 `Bad state` 而且界面反而更乱。
Duration? _noRetry(int retryCount, Object error) => null;

/// 笔记列表排序（F7）。
///
/// 官方取值逐字取证（NoteStation Web `ui/notestation.js`）：
///   * `sort_info:{sort_by:"mtime", sort_direction:"desc"}`（默认）；
///   * 排序菜单 itemId：`title` / `ctime` / `mtime`，方向 `asc` / `desc`；
///   * `Note/list` 写死 `version:3` 并透传 `sort_by`/`sort_direction`。
class NoteSort {
  const NoteSort(this.by, this.direction);

  /// `title` / `ctime` / `mtime`
  final String by;

  /// `asc` / `desc`
  final String direction;

  static const NoteSort defaultValue = NoteSort('mtime', 'desc');

  bool get isAscending => direction == 'asc';

  NoteSort withBy(String value) => NoteSort(value, direction);
  NoteSort withDirection(String value) => NoteSort(by, value);

  @override
  bool operator ==(Object other) =>
      other is NoteSort && other.by == by && other.direction == direction;

  @override
  int get hashCode => Object.hash(by, direction);
}

/// 当前笔记排序（默认 `mtime desc`，与官方 Web 默认一致）。
final noteSortProvider = NotifierProvider<NoteSortNotifier, NoteSort>(
  NoteSortNotifier.new,
);

class NoteSortNotifier extends Notifier<NoteSort> {
  @override
  NoteSort build() => NoteSort.defaultValue;

  void setBy(String by) => state = state.withBy(by);
  void setDirection(String direction) => state = state.withDirection(direction);
}

/// F9：列表 / 网格视图。
///
/// ★ 取证（官方 Web `ui/notestation.js`）：
///   * 工具栏按钮 `btn_note_display_mode`（`mode:"snippet"`）与
///     `switchMode` 处理器；
///   * 两个 DataView：`note_snippet`（列表）/ `note_card`（网格）；
///   * 选择只存在**本地用户设置** `view_by`（`getUserSettings("view_by")`）
///     —— **没有任何服务端 API**。
///   官方 Android APK **无**此开关（grep 0 命中）。⇒ 纯 UI。
enum NoteViewMode {
  /// 官方 `view_by:"snippet"`（列表）
  snippet,

  /// 官方 `view_by:"card"`（网格）
  card,
}

final noteViewModeProvider =
    NotifierProvider<NoteViewModeNotifier, NoteViewMode>(
      NoteViewModeNotifier.new,
    );

class NoteViewModeNotifier extends Notifier<NoteViewMode> {
  @override
  NoteViewMode build() => NoteViewMode.snippet;

  void set(NoteViewMode mode) => state = mode;

  void toggle() => state = state == NoteViewMode.snippet
      ? NoteViewMode.card
      : NoteViewMode.snippet;
}

/// A14：笔记本列表是否**包含已归档的**。
///
/// 官方默认列表把归档的滤掉（`Notebook/list` v2 的 `filter:{"archive":false}`），
/// 归档/取消归档走 `Notebook.Polling/archive` v1（见
/// [NoteStationApi.archiveNotebook]）。这是纯本地视图开关。
final noteIncludeArchivedProvider =
    NotifierProvider<NoteIncludeArchivedNotifier, bool>(
      NoteIncludeArchivedNotifier.new,
    );

class NoteIncludeArchivedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// G4：按标签筛选时选中的标签**标题**集合（官方 `Note/list` 的 `tag:[…]`）。
final noteFilterTagsProvider =
    NotifierProvider<NoteFilterTagsNotifier, List<String>>(
      NoteFilterTagsNotifier.new,
    );

class NoteFilterTagsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void set(List<String> tags) => state = List<String>.unmodifiable(tags);

  void toggle(String title) {
    final next = [...state];
    if (!next.remove(title)) next.add(title);
    state = List<String>.unmodifiable(next);
  }

  void clear() => state = const [];
}

/// G4：`tag_operator` —— 多标签是 **AND** 还是 **OR**。
///
/// ★ 取证（官方 Web `AdvancedSearch.getSearchValues`）：
///   `a = findField("tag_operator").getValue() ? "and" : "or"` ——
///   勾选框**不勾**（默认）就是 `"or"`。取值只有这两个。
final noteTagOperatorProvider =
    NotifierProvider<NoteTagOperatorNotifier, String>(
      NoteTagOperatorNotifier.new,
    );

class NoteTagOperatorNotifier extends Notifier<String> {
  @override
  String build() => NoteStationApi.tagOperatorOr;

  void set(String value) {
    if (value != NoteStationApi.tagOperatorAnd &&
        value != NoteStationApi.tagOperatorOr) {
      return;
    }
    state = value;
  }
}

/// 编辑器默认字号（N7）。
///
/// 官方 key 逐字取证：`Common.DEFAULT_FONT_SIZE = "default_font_size"`，默认值
/// `syno-fontsize-x-small`（`PrefsSettingsFragment` / `EditorActivity` /
/// `NoteFragment` 三处一致）。取值集合就是 [kSynoFontSizes] 的 7 档。
const String kNoteDefaultFontSizeKey = 'default_font_size';
const String kNoteDefaultFontSize = 'syno-fontsize-x-small';

/// 默认字号偏好（KV 落库；打开编辑器时生效）。
final noteDefaultFontSizeProvider =
    NotifierProvider<NoteDefaultFontSizeNotifier, String>(
      NoteDefaultFontSizeNotifier.new,
    );

class NoteDefaultFontSizeNotifier extends Notifier<String> {
  @override
  String build() {
    // KV 是异步的：先给官方默认值，读到值再更新（首帧不阻塞）。
    Future<void>(() async {
      try {
        final raw = await ref
            .read(chatStoreProvider)
            .setting(kNoteDefaultFontSizeKey);
        if (raw != null && kSynoFontSizes.contains(raw) && state != raw) {
          state = raw;
        }
      } catch (_) {
        // 读不到就用默认，不打扰用户
      }
    });
    return kNoteDefaultFontSize;
  }

  Future<void> set(String value) async {
    if (!kSynoFontSizes.contains(value)) return;
    state = value;
    await ref
        .read(chatStoreProvider)
        .setSetting(kNoteDefaultFontSizeKey, value);
  }
}

/// C9/G5 附件文本搜索的本地开关 key（官方 Android
/// `PrefsSettingsFragment.PREF_ENABLE_ATTACH_SEARCH` 逐字）。
const String kNoteAttachmentSearchKey = 'enable_attachment_text_search';

/// 一次附件文本搜索最多扫多少条笔记（`Note/get` + `get_attachment_text`
/// 是逐条请求，必须设上界；官方是把附件文本同步进本地库再查，我们按需扫）。
const int kNoteAttachmentSearchMaxNotes = 30;

/// 附件文本搜索的**本地**开关值（官方 Android 本地勾选键，默认关）。
///
/// 与 [noteAttachmentSearchEnabledProvider]（本地 ∧ 服务端能力位）分开：
/// 设置项要能显示"用户本地的选择"，即使服务端能力位还没读到。
final noteAttachmentSearchPrefProvider = FutureProvider.autoDispose<bool>((
  ref,
) async {
  final raw = await ref
      .watch(chatStoreProvider)
      .setting(kNoteAttachmentSearchKey);
  return raw == 'true';
}, retry: _noRetry);

/// 附件文本搜索是否可用：**本地开关 + 服务端能力位**都为真。
///
///   * 本地：KV `enable_attachment_text_search`（官方 Android 的本地勾选键）；
///   * 服务端：`Setting/get` v2 的 `search_attachment`
///     （官方 Web 通用设置面板同名字段；Android `SettingVo.search_attachment`）；
///   * `Note` 必须到 **v4** 才有 `get_attachment_text`。
///
/// 任一不满足 → **false**（不搜、不报错、入口可不显示）。
final noteAttachmentSearchEnabledProvider =
    FutureProvider.autoDispose<bool>((ref) async {
      final api = ref.watch(noteApiProvider);
      if (api == null || !api.supportsAttachmentText()) return false;
      final local = await ref
          .watch(chatStoreProvider)
          .setting(kNoteAttachmentSearchKey);
      if (local != 'true') return false;
      return api.searchAttachmentEnabled();
    }, retry: _noRetry);

/// 附件文本命中的笔记 id 集合（关键词 → ids）。
///
/// ★ 服务端落点**真机取证**（本批 NAS 实调）：
///   `SYNO.NoteStation.FTS:search` v1 **存在且可用**，回包
///   `{matches:[...], offset:int}`；`Note:search` / `SYNO.NoteStation.Search`
///   都**不存在**（103/102）——所以附件/全文搜索只能走 FTS。
///   ⚠️ `matches[]` 的**条目字段名本次未取证**（本机匹配为空），因此一律走
///   [NoteStationApi.searchNotes] 的容错解析，**不编字段**、缺了就当没匹配。
///
/// 官方 Android 还有一条"同步期把 `get_attachment_text` 落本地再查"的路径；
/// 这里作为 FTS 无结果时的**有界兜底**：对当前列表前
/// [kNoteAttachmentSearchMaxNotes] 条笔记取附件表、逐个非图片附件调
/// `Note/get_attachment_text` v4 本地匹配。单条失败只跳过它。
final noteAttachmentSearchMatchesProvider = FutureProvider.autoDispose
    .family<Set<String>, String>((ref, keyword) async {
      final q = keyword.trim();
      if (q.isEmpty) return const <String>{};
      final enabled = await ref.watch(
        noteAttachmentSearchEnabledProvider.future,
      );
      if (!enabled) return const <String>{};
      final api = ref.watch(noteApiProvider);
      if (api == null) return const <String>{};

      // ① 服务端 FTS（真机取证的方法；附件文本命中由服务端能力位决定）
      final hits = <String>{};
      try {
        final matches = await api.searchNotes(keyword: q, limit: 50);
        for (final m in matches) {
          if (m.objectId.isNotEmpty) hits.add(m.objectId);
        }
      } catch (_) {
        // FTS 失败（老服务端 / 网络）→ 走本地兜底，不报错
      }
      if (hits.isNotEmpty) return hits;

      // ② 有界本地兜底：`Note/get` 拿附件表 + `get_attachment_text` 取文本
      final needle = q.toLowerCase();
      final notes = (await ref.watch(noteListProvider.future)).notes
          .where((n) => !n.recycle)
          .take(kNoteAttachmentSearchMaxNotes);
      for (final n in notes) {
        try {
          final detail = await api.getNote(n.objectId);
          for (final a in detail.attachments.values) {
            if (a.isImage) continue;
            final text = await api.attachmentText(n.objectId, a.fileId);
            if (text.toLowerCase().contains(needle)) {
              hits.add(n.objectId);
              break;
            }
          }
        } catch (_) {
          // 单条失败（附件不可读 / 无权限）不影响其它笔记
        }
      }
      return hits;
    }, retry: _noRetry);


/// 笔记模块的 API 层。未连接时为 null。
final noteApiProvider = Provider<NoteStationApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : NoteStationApi(conn.api);
});

/// NoteStation 自检（用户名 / 版本 / 是否允许共享）
final noteInfoProvider = FutureProvider.autoDispose<NoteInfoDto?>((ref) async {
  final api = ref.watch(noteApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.info();
}, retry: _noRetry);

/// 笔记本列表（网络优先，失败回落缓存）
final notebooksProvider = FutureProvider.autoDispose<List<NotebookDto>>((
  ref,
) async {
  final api = ref.watch(noteApiProvider);
  final store = ref.watch(noteStoreProvider);
  // A14：归档笔记本默认不出现在列表里（`filter:{"archive":false}`）
  final includeArchived = ref.watch(noteIncludeArchivedProvider);
  if (api == null) {
    final cached = await store.notebooks();
    if (cached.isEmpty) throw StateError(currentText().setNotConnected);
    return includeArchived
        ? cached
        : cached.where((n) => !n.archive).toList(growable: false);
  }
  try {
    final list = await api.listNotebooks(includeArchived: includeArchived);
    await store.replaceNotebooks(list);
    return list;
  } catch (e) {
    final cached = await store.notebooks();
    if (cached.isEmpty) rethrow;
    return includeArchived
        ? cached
        : cached.where((n) => !n.archive).toList(growable: false);
  }
}, retry: _noRetry);

/// 笔记列表（一次拉回标题/摘要/时间；正文打开时再取）
class NoteListResult {
  const NoteListResult(this.notes, {this.total = 0, this.fromCache = false});

  final List<NoteDto> notes;
  final int total;

  /// true = 这次的数据来自本地缓存（内存/磁盘），网络没成功
  final bool fromCache;
}

final noteListProvider = FutureProvider.autoDispose<NoteListResult>((
  ref,
) async {
  final api = ref.watch(noteApiProvider);
  final store = ref.watch(noteStoreProvider);
  final sort = ref.watch(noteSortProvider);
  if (api == null) {
    final cached = await store.notes();
    if (cached.isEmpty) throw StateError(currentText().setNotConnected);
    return NoteListResult(cached, total: cached.length, fromCache: true);
  }
  try {
    // F7：排序参数**透传**给 `Note/list`（官方 Web 也是 `sort_by`/`sort_direction`）
    final r = await api.listNotes(
      sortBy: sort.by,
      sortDirection: sort.direction,
    );
    await store.mergeNoteList(r.notes);
    // 顺手读一次缓存里的记录条数（离线横幅显示用）
    return NoteListResult(r.notes, total: r.total);
  } catch (e) {
    final cached = await store.notes();
    if (cached.isEmpty) rethrow;
    return NoteListResult(cached, total: cached.length, fromCache: true);
  }
}, retry: _noRetry);

/// G4：带标签过滤的笔记列表。
///
/// ★ 走**服务端**过滤（这才是 G4 的取证点）：官方 Web `Note/list` 的
///   `query_params` 就带 `tag:[…]` + `tag_operator:"and"|"or"`
///   （`AdvancedSearch.getSearchParams` / `getFilterParams`）。选中标签后
///   这里把两个参数透传给 [NoteStationApi.listNotes]；没选标签时直接复用
///   [noteListProvider]（不多发一次请求）。
///
/// 失败时回落本地缓存并按同一套 AND/OR 语义过滤（离线可用）。
final noteTagFilteredListProvider = FutureProvider.autoDispose<NoteListResult>((
  ref,
) async {
  final tags = ref.watch(noteFilterTagsProvider);
  if (tags.isEmpty) return ref.watch(noteListProvider.future);
  final operator = ref.watch(noteTagOperatorProvider);
  final api = ref.watch(noteApiProvider);
  final store = ref.watch(noteStoreProvider);
  final sort = ref.watch(noteSortProvider);
  if (api != null) {
    try {
      final r = await api.listNotes(
        sortBy: sort.by,
        sortDirection: sort.direction,
        tags: tags,
        tagOperator: operator,
      );
      await store.mergeNoteList(r.notes);
      return NoteListResult(r.notes, total: r.total);
    } catch (_) {
      // 落到下面的本地过滤
    }
  }
  final cached = await store.notes();
  return NoteListResult(
    filterNotesByTags(cached, tags, operator),
    total: cached.length,
    fromCache: true,
  );
}, retry: _noRetry);

/// G4 的本地兜底：AND = 全含；OR = 含其一。也用于离线缓存。
List<NoteDto> filterNotesByTags(
  List<NoteDto> notes,
  List<String> tags,
  String operator,
) {
  if (tags.isEmpty) return notes;
  final wanted = tags.map((t) => t.toLowerCase()).toSet();
  return notes.where((n) {
    final own = n.tags.map((t) => t.toLowerCase()).toSet();
    if (operator == NoteStationApi.tagOperatorAnd) {
      return wanted.every(own.contains);
    }
    return wanted.any(own.contains);
  }).toList();
}

/// 单条笔记的完整内容（含正文 HTML）
class NoteDetail {
  const NoteDetail(this.note, {this.fromCache = false});

  final NoteDto note;

  /// true = 网络没取到，这是磁盘上的那份
  final bool fromCache;
}

/// 可分享的 DSM 账号/群组（`Share.Priv/list` v2，官方 Note Station 用它当
/// 共享对话框的候选列表：`{query:""}` → `list[]`）
final noteSharePrincipalsProvider = FutureProvider.autoDispose
    .family<List<({String name, String type})>, String>((ref, query) async {
      final api = ref.watch(noteApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.sharePrincipals(query: query);
    }, retry: _noRetry);

final noteDetailProvider = FutureProvider.autoDispose
    .family<NoteDetail, String>((ref, objectId) async {
      final api = ref.watch(noteApiProvider);
      final store = ref.watch(noteStoreProvider);
      if (api == null) {
        final cached = await store.note(objectId);
        if (cached == null || !cached.hasContent) {
          throw StateError(currentText().setNotConnected);
        }
        return NoteDetail(cached, fromCache: true);
      }
      try {
        final note = await api.getNote(objectId);
        await store.putNote(note);
        return NoteDetail(note);
      } catch (e) {
        final cached = await store.note(objectId);
        if (cached == null || !cached.hasContent) rethrow;
        return NoteDetail(cached, fromCache: true);
      }
    }, retry: _noRetry);

// ------------------------------------------------------------ 附件（图片）

/// 一次笔记图片请求：笔记 id + 附件 file_id（+ 要不要缩略图）
class NoteImageRequest {
  const NoteImageRequest(this.objectId, this.fileId, {this.thumb = false});

  final String objectId;
  final String fileId;
  final bool thumb;

  @override
  bool operator ==(Object other) =>
      other is NoteImageRequest &&
      other.objectId == objectId &&
      other.fileId == fileId &&
      other.thumb == thumb;

  @override
  int get hashCode => Object.hash(objectId, fileId, thumb);
}

/// 笔记图片字节。
///
/// 走 `Note/download`（`object_id` + `file_id` + `format=raw` + `thumb`），
/// **用 API 层取字节**而不是 `Image.network`：下载要带 `_sid` 与 CSRF 头，
/// 交给传输层最稳（与文件模块的缩略图同思路）。
final noteImageProvider = FutureProvider.autoDispose
    .family<Uint8List, NoteImageRequest>((ref, req) async {
      final api = ref.watch(noteApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      final bytes = await api.api.getBytes(
        api.attachmentUrl(req.objectId, req.fileId, thumb: req.thumb),
      );
      return Uint8List.fromList(bytes);
    }, retry: _noRetry);

/// 回收站里的笔记（`Note/list` 会把回收站里的也返回，按 `recycle` 过滤）
final noteRecycleProvider = FutureProvider.autoDispose<List<NoteDto>>((
  ref,
) async {
  final api = ref.watch(noteApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  final r = await api.listNotes(limit: 200);
  return r.notes.where((n) => n.recycle).toList();
}, retry: _noRetry);

/// 标签表（`Tag/list`）
final noteTagsProvider = FutureProvider.autoDispose<List<TagDto>>((ref) async {
  final api = ref.watch(noteApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.listTags();
}, retry: _noRetry);

/// ★★★ r131（D18）：**「有哪些标签」只能有一份表示**（§2.0.26 第 2 条）。
///
/// 真机像素（`n16_note_tag_filter.png`，见 `docs/platform-macos-ui-audit.md` §3 D18）：
/// 筛选入口报 `No tags yet`，而**同一条笔记**在正文页带标签 `test`（`n11`）、
/// 信息页写 `Tags / test`（`n12`）⇒ 界面与自己渲染的数据互相打架。
/// 根因是这里曾有两份来源：**筛选**读服务端 `Tag:list`，**渲染**读笔记自身的 `tags`；
/// 服务端那份为空或失败时（`noteTagsProvider.value ?? []` 把错误也吞成"空"），
/// 筛选就说"没有标签"。
///
/// 现在统一在这里派生：**服务端标签 ∪ 已加载笔记自带的标签**（去重 + 排序）。
/// ★ 两件不许做错的事：
///   ① **`No tagsYet` 不许删** —— 两处都没有标签时它照样出现（§2.0.29①）；
///   ② **"取不到"不许说成"没有"** —— 服务端那份**失败**时 `serverFailed` 为真，
///      界面据此换一句"可能有标签没显示出来"（§"空态必须与请求失败分开"）。
final noteAllTagsProvider =
    FutureProvider.autoDispose<({List<String> tags, bool serverFailed})>((
      ref,
    ) async {
      // ★★ 所有 `ref.watch` 必须在**第一个 `await` 之前**同步做完。
      //   本轮实测（r131）：这个 autoDispose provider 是被界面回调里的
      //   `ref.read(...future)` 拉起来的（那一刻没有 watcher），
      //   一旦在 `await` 之后再碰 `ref`，Riverpod 抛
      //   `UnmountedRefException: Cannot use the Ref of FutureProvider<…> after it has been disposed`
      //   —— 与 AGENTS §2.0.17 记的 `officeNativeReadProvider` 是同一个坑。
      final serverTags = ref.watch(noteTagsProvider.future);
      final notesFuture = ref.watch(noteListProvider.future);
      final set = <String>{};
      var serverFailed = false;
      try {
        for (final tag in await serverTags) {
          final title = tag.title.trim();
          if (title.isNotEmpty) set.add(title);
        }
      } catch (_) {
        // 服务端标签列表不可得 ⇒ 只用笔记自带的那份，但**记住"没取到"**
        serverFailed = true;
      }
      // ★ 与正文页渲染标签**同一份数据**：笔记 DTO 自己的 `tags`
      //   （NAS 回包里的键是单数 `tag`，见 `NoteDto.fromJson`）。
      //   列表本身就失败时这里的 `await` 会把错误抛给调用方（不静默成"空"）。
      for (final note in (await notesFuture).notes) {
        for (final tag in note.tags) {
          final title = tag.trim();
          if (title.isNotEmpty) set.add(title);
        }
      }
      return (tags: set.toList()..sort(), serverFailed: serverFailed);
    });

/// 待办表的筛选（null = 全部）
final todoFilterProvider = NotifierProvider<TodoFilterNotifier, bool?>(
  TodoFilterNotifier.new,
);

class TodoFilterNotifier extends Notifier<bool?> {
  @override
  bool? build() => null;

  void set(bool? done) => state = done;
}

/// 待办列表（`Todo/list`；网络优先，失败回落缓存）
final noteTodosProvider = FutureProvider.autoDispose<List<TodoDto>>((
  ref,
) async {
  final api = ref.watch(noteApiProvider);
  final store = ref.watch(noteStoreProvider);
  final done = ref.watch(todoFilterProvider);
  if (api == null) {
    final cached = await store.todos();
    if (cached.isEmpty) throw StateError(currentText().setNotConnected);
    return done == null ? cached : cached.where((t) => t.done == done).toList();
  }
  try {
    final list = await api.listTodos(done: done);
    await store.replaceTodos(list);
    return list;
  } catch (e) {
    // ⚠️ 待办列表是按 done 过滤拉的，缓存里是"全部"，这里自己筛
    final cached = await store.todos();
    final filtered = done == null
        ? cached
        : cached.where((t) => t.done == done).toList();
    if (filtered.isEmpty) rethrow;
    return filtered;
  }
}, retry: _noRetry);

/// 「只看已超时」开关（待办页的筛选模式之一）。
///
/// 打开时列表来源切到 [noteTimeoutTodosProvider]（服务端 `list_timeout`），
/// 而不是前端按 `due_date` 自己算 —— 口径完全跟服务端一致。
final todoTimeoutOnlyProvider =
    NotifierProvider<TodoTimeoutOnlyNotifier, bool>(TodoTimeoutOnlyNotifier.new);

class TodoTimeoutOnlyNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// 已超时待办（`SYNO.NoteStation.Todo / list_timeout`，v1/v2 都有）。
///
/// 空回包原本就没有 `todos`（真机 `{count:0,offset:0,total:0}`），所以这里
/// 不做缓存回落，失败照实报（`_noRetry`）——超时汇总宁可空也不要假数据。
final noteTimeoutTodosProvider = FutureProvider.autoDispose<NoteTimeoutTodos>((
  ref,
) async {
  final api = ref.watch(noteApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.listTimeoutTodos();
}, retry: _noRetry);

/// 快捷方式（`SYNO.NoteStation.Shortcut/list` v1；官方审计 F5 对齐项）。
///
/// 与 Todo 一样是"服务端算好的列表"，本地不猜：空回包没有 `shortcuts` 键。
final noteShortcutsProvider = FutureProvider.autoDispose<List<ShortcutDto>>((
  ref,
) async {
  final api = ref.watch(noteApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.listShortcuts();
}, retry: _noRetry);

/// 版本历史
final noteVersionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, objectId) async {
      final api = ref.watch(noteApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      return api.listVersions(objectId);
    }, retry: _noRetry);

/// 当前选中的笔记本（null = 全部）
final selectedNotebookProvider =
    NotifierProvider<SelectedNotebookNotifier, String?>(
      SelectedNotebookNotifier.new,
    );

class SelectedNotebookNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? notebookId) => state = notebookId;
}

/// 笔记搜索关键词（本地过滤，与官方 App 的"全量拉本地筛"一致）
final noteKeywordProvider = NotifierProvider<NoteKeywordNotifier, String>(
  NoteKeywordNotifier.new,
);

class NoteKeywordNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

/// 按"笔记本 + 关键词"过滤后的列表（派生 provider，避免页面里重复算）
final visibleNotesProvider = FutureProvider.autoDispose<List<NoteDto>>((
  ref,
) async {
  final all = await ref.watch(noteTagFilteredListProvider.future);
  final notebook = ref.watch(selectedNotebookProvider);
  final keyword = ref.watch(noteKeywordProvider).trim().toLowerCase();
  final sort = ref.watch(noteSortProvider);
  var notes = all.notes.where((n) => !n.recycle).toList();
  if (notebook != null) {
    notes = notes.where((n) => n.parentId == notebook).toList();
  }
  if (keyword.isNotEmpty) {
    final direct = notes
        .where(
          (n) =>
              n.title.toLowerCase().contains(keyword) ||
              n.brief.toLowerCase().contains(keyword) ||
              n.tags.any((t) => t.toLowerCase().contains(keyword)),
        )
        .toList();
    // C9/G5：附件文本搜索（能力位关闭时返回空集，且**不发任何请求**）
    final attachmentIds = keyword.isEmpty
        ? const <String>{}
        : await ref.watch(
            noteAttachmentSearchMatchesProvider(keyword).future,
          );
    final merged = <NoteDto>[...direct];
    for (final n in notes) {
      if (attachmentIds.contains(n.objectId) &&
          !merged.any((d) => d.objectId == n.objectId)) {
        merged.add(n);
      }
    }
    notes = merged;
  }
  // F7：本地兜底排序（与服务端相同的 key/方向；离线缓存也复用）
  notes.sort((a, b) => _compareNotes(a, b, sort));
  return notes;
}, retry: _noRetry);

/// 列表排序比较：`title`（不分大小写）/ `ctime` / `mtime`，方向 `asc`/`desc`。
int _compareNotes(NoteDto a, NoteDto b, NoteSort sort) {
  final int r = switch (sort.by) {
    'title' => a.displayTitle.toLowerCase().compareTo(
      b.displayTitle.toLowerCase(),
    ),
    'ctime' => a.ctime.compareTo(b.ctime),
    _ => a.mtime.compareTo(b.mtime),
  };
  return sort.isAscending ? r : -r;
}

/// 某个笔记本下的笔记条数（笔记本卡片上显示）
int noteCountOf(List<NoteDto> notes, String notebookId) =>
    notes.where((n) => n.parentId == notebookId && !n.recycle).length;

// ------------------------------------------------------- 智能 / 条件笔记本（F6）

/// 智能笔记本列表（`SYNO.NoteStation.Smart/list` v1）
final smartNotebooksProvider = FutureProvider.autoDispose<List<SmartNotebookDto>>(
  (ref) async {
    final api = ref.watch(noteApiProvider);
    if (api == null) throw StateError(currentText().setNotConnected);
    return api.listSmartNotebooks();
  },
  retry: _noRetry,
);

/// 一个智能笔记本命中的笔记（**本地筛**，与官方把 query 存本地再查一致）
final smartNotesProvider = FutureProvider.autoDispose
    .family<List<NoteDto>, NoteSmartQuery>((ref, query) async {
      final all = await ref.watch(noteListProvider.future);
      final rows = all.notes
          .where((n) => !n.recycle && query.matches(n))
          .toList();
      rows.sort((a, b) => b.mtime.compareTo(a.mtime));
      return rows;
    }, retry: _noRetry);

// ------------------------------------------------------- 共享给我 / 加入的（J5）

/// 「共享给我」的聚合：别人分享来的笔记本 + 单条笔记。
class NoteJoinedResult {
  const NoteJoinedResult({required this.notebooks, required this.notes});

  final List<NotebookDto> notebooks;
  final List<NoteDto> notes;

  bool get isEmpty => notebooks.isEmpty && notes.isEmpty;
}

/// 官方 `JoinedListFragment` 的数据来源就是本地库里的"owner 不是我"的记录
/// （`GenerateJoinedsLoader` 按 `owner != linkedUID` 分组）。我们照做：
/// 笔记本看 `individual_shared` / `owner`，笔记看 `individual_joined/shared`。
final noteJoinedProvider = FutureProvider.autoDispose<NoteJoinedResult>((
  ref,
) async {
  final me = await ref.watch(noteInfoProvider.future);
  final myName = me?.username;
  final notebooks = await ref.watch(notebooksProvider.future);
  final all = await ref.watch(noteListProvider.future);
  final joinedNotebooks = notebooks
      .where((nb) => isJoinedNotebook(nb, myName))
      .toList();
  final joinedNotes = all.notes
      .where((n) => !n.recycle && isJoinedNote(n, myName))
      .toList();
  return NoteJoinedResult(notebooks: joinedNotebooks, notes: joinedNotes);
}, retry: _noRetry);

/// 笔记本是不是"**我分享出去的**"。
///
/// ★ 第 117 轮 / 台账 J11：官方 `all_shared_notes`（= "Shared Notes"）
/// 与 `all_joined_notes`（= "Joined Notes"）是**两个**伪集合
/// （取证：`res/values/strings.xml:39/41`，使用点
/// `NotebookListAppWidgetAdapter`）。我方此前只做了"共享给我"那一半。
///
/// 判定规则与"加入"镜像：`individual_shared` 为真，且
/// **所有人是我**（`ownerName` 为空时按"我的"处理 —— 服务端对自有内容
/// 可能不带 owner）。
bool isSharedNotebook(NotebookDto nb, String? myName) {
  if (!nb.individualShared) return false;
  final owner = nb.ownerName;
  if (owner == null || owner.isEmpty) return true;
  return myName == null || owner == myName;
}

/// 笔记是不是"**我分享出去的**"（与 [isJoinedNote] 同一套字段，方向相反）。
bool isSharedNote(NoteDto note, String? myName) {
  if (!note.individualShared) return false;
  final owner = note.ownerName;
  if (owner == null || owner.isEmpty) return true;
  return myName == null || owner == myName;
}

/// **我分享出去的**笔记本与笔记（官方 "Shared Notes" 伪集合）。
final noteSharedProvider = FutureProvider.autoDispose<NoteSharedResult>((
  ref,
) async {
  final info = await ref.watch(noteInfoProvider.future);
  final myName = info?.username;
  final notebooks = await ref.watch(notebooksProvider.future);
  final all = await ref.watch(noteListProvider.future);
  return NoteSharedResult(
    notebooks: notebooks.where((nb) => isSharedNotebook(nb, myName)).toList(),
    notes: all.notes
        .where((n) => !n.recycle && isSharedNote(n, myName))
        .toList(),
  );
}, retry: _noRetry);

/// "我分享出去的"结果集（与 [NoteJoinedResult] 镜像）。
class NoteSharedResult {
  const NoteSharedResult({required this.notebooks, required this.notes});

  final List<NotebookDto> notebooks;
  final List<NoteDto> notes;

  bool get isEmpty => notebooks.isEmpty && notes.isEmpty;
}

/// 笔记本是不是"**别人**分享给我的"（= 官方 "Joined Notebooks"）。
///
/// ★ 第 117 轮修正：原实现只看 `individual_shared` 就判为"加入"，
/// 结果**我自己分享出去的笔记本也会出现在"共享给我"里**（两个伪集合重叠）。
/// 现在按 owner 判方向：
///   * owner 为空 ⇒ **不算**（"加入"必须有 owner，官方的 Joined 列表也是
///     按 owner 分组的）；
///   * owner == 我 ⇒ **不算**（那是"我分享的"，见 [isSharedNotebook]）；
///   * 其余 ⇒ 算（服务端把分享给我的本带 `individual_shared`/`individual_joined`）。
bool isJoinedNotebook(NotebookDto nb, String? myName) {
  final owner = nb.ownerName;
  // owner == 我 ⇒ 那是"我分享出去的"，不属于"共享给我"（117 轮修正）
  if (owner != null && owner.isNotEmpty && myName != null && owner == myName) {
    return false;
  }
  if (nb.individualShared) return true;
  if (owner == null || owner.isEmpty) return false;
  return myName != null && owner != myName;
}

/// 笔记是不是"**别人**分享给我的"（= 官方 "Joined Notes"）。
///
/// ★ 第 117 轮修正（同 [isJoinedNotebook]）：owner == 我的不算"加入"。
/// 单条笔记上服务端会给 `individual_joined`（别人直接分享给我的这篇），
/// 所以 owner 缺失时**仍认这个显式标记**；但 owner == 我 ⇒ 不算。
bool isJoinedNote(NoteDto note, String? myName) {
  final owner = note.ownerName;
  // owner == 我 ⇒ "我分享出去的"，不属于"共享给我"（117 轮修正）
  if (owner != null && owner.isNotEmpty && myName != null && owner == myName) {
    return false;
  }
  if (note.individualJoined || note.individualShared) return true;
  if (owner == null || owner.isEmpty) return false;
  return myName != null && owner != myName;
}
