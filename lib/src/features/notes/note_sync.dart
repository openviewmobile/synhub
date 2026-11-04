// 笔记模块的同步与离线（P1 · local-first）。
//
// 官方 DS note（Android）的做法：`SyncPullCallable` 把 `Note/list` 的元数据
// **全量 diff** 进 SQLite（新增/更新/删除），变化的正文再用 `Note/get` 补齐；
// 本地改动由 `SyncCallable` 推回去，失败就留在库里下次再推。
//
// 我们照这个模型，但只做**普通用户**需要的部分：
//   * 拉：笔记本 + 笔记元数据 + 正文 + 待办 + 标签 → Drift；
//   * 推：离线时把新建/保存/删除/待办改动放进队列表，联网后按顺序重放；
//   * 状态：`NoteSyncStatus` 给 UI 显示"离线 / 待同步 N 条 / 上次同步时间"。
//
// 不做的事（明确记录在 gap 里）：双向冲突合并（服务端改了 + 本地又离线改了）。
// 这种情况我们保留本地内容（`dirty` 行不会被 pull 覆盖），推送时若服务端
// 版本变了就报错留在队列里，等用户看到提示后决定。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/note_dto.dart';
import '../../data/local/note_store.dart';
import '../../data/note_api.dart';
import '../../dsm/webapi.dart';
import '../chat/chat_session_controller.dart' show chatDatabaseProvider;
import '../servers/session_controller.dart' show sessionControllerProvider;
import 'note_providers.dart' show noteApiProvider;
import '../../core/i18n/data_text.dart';
import '../../core/user_facing_error.dart';

/// 本地缓存仓库
///
/// ★ N5（236 轮）：**按当前激活的 NAS 账号分库**（`accountKey`）。
/// 切换 NAS 时 provider 重算 ⇒ 界面读到的立刻是那个账号的缓存，
/// 不会把 A 的笔记当成 B 的（也不会被 B 的 `Note/list` diff 删掉）。
final noteStoreProvider = Provider<NoteStore>((ref) {
  final account = ref.watch(
    sessionControllerProvider.select((s) => s.activeNasId),
  );
  return NoteStore(ref.watch(chatDatabaseProvider), accountKey: account ?? '');
});

/// 这个异常是不是"网络不可达"（= 离线），而不是"服务端拒绝"。
///
/// `DsmApiException` 说明**服务端答了**（在线，只是不让我们干这件事），
/// 所以绝不能当成离线去写本地缓存 —— 那会造成"以为保存成功"。
bool isOfflineError(Object error) {
  if (error is DsmApiException) return false;
  // ★ DA79（r420 真机撞出并修掉）：传输层把 `DioException` 收成 `DsmTransportException`
  //   （见 `dsm/webapi.dart` 的 `post`/`postMultipart`/`download` 三处 catch）。
  //   **没有 HTTP 状态码 = 请求根本没到服务端** ⇒ 这就是"离线"，必须把用户的改动
  //   落进本地队列（`_saveOffline`），而不是报"保存失败"把改动丢掉。
  //   有状态码说明服务端答过话（5xx 等）⇒ 仍按错误处理，不冒充离线。
  if (error is DsmTransportException) return error.statusCode == null;
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.badCertificate:
        return true;
      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.unknown:
        // `unknown` 里常见的是 SocketException / HandshakeException
        return error.error is! DsmApiException && error.response == null;
    }
  }
  final text = '$error';
  return text.contains('SocketException') ||
      text.contains('Connection refused') ||
      text.contains('Failed host lookup') ||
      text.contains('timed out');
}

enum NoteSyncState { idle, syncing, offline, error }

class NoteSyncStatus {
  const NoteSyncStatus({
    this.state = NoteSyncState.idle,
    this.lastSyncedAt,
    this.pending = 0,
    this.message,
    this.conflicts = const [],
  });

  final NoteSyncState state;
  final DateTime? lastSyncedAt;
  final int pending;
  final String? message;

  /// 双向冲突（本地也改了 + 服务端也改了）。**只在内存里**：队列本身是持久的，
  /// 重启后下一次拉取会重新探测出来，不需要再开一张表。
  final List<NoteConflict> conflicts;

  bool get offline => state == NoteSyncState.offline;
  bool get syncing => state == NoteSyncState.syncing;
  bool get hasConflicts => conflicts.isNotEmpty;

  NoteSyncStatus copyWith({
    NoteSyncState? state,
    DateTime? lastSyncedAt,
    int? pending,
    String? message,
    List<NoteConflict>? conflicts,
    bool clearMessage = false,
  }) => NoteSyncStatus(
    state: state ?? this.state,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    pending: pending ?? this.pending,
    message: clearMessage ? null : (message ?? this.message),
    conflicts: conflicts ?? this.conflicts,
  );
}

/// 一条待用户裁决的双向冲突（比 store 层的草稿多了"服务端正文"）。
/// ★ 第 124 轮 / M5：冲突副本的标题。
///
/// 官方 `SyncPushCallable.smali:1282-1294` 是 `title` + `" "` +
/// `getString(R.string.conflict)`（`res/values/strings.xml:125` = `"Conflict"`）——
/// **空格分隔**。这里保留同样的分隔，后缀可本地化。
String conflictCopyTitle(String title, String suffix) {
  final t = title.trim();
  final s = suffix.trim();
  if (s.isEmpty) return t;
  return t.isEmpty ? s : '$t $s';
}

class NoteConflict {
  const NoteConflict({
    required this.objectId,
    required this.title,
    required this.baseVer,
    required this.serverVer,
    required this.localContent,
    this.serverContent = '',
    this.serverFetched = false,
  });

  final String objectId;
  final String title;
  final String baseVer;
  final String serverVer;

  /// 我们这边的正文（离线改的）
  final String localContent;

  /// 服务端那边的正文（拉取时顺手抓的；没抓到就是空串）
  final String serverContent;
  final bool serverFetched;

  NoteConflict copyWith({String? serverContent, bool? serverFetched}) =>
      NoteConflict(
        objectId: objectId,
        title: title,
        baseVer: baseVer,
        serverVer: serverVer,
        localContent: localContent,
        serverContent: serverContent ?? this.serverContent,
        serverFetched: serverFetched ?? this.serverFetched,
      );
}

/// 同步开关的全局状态（页面上的离线横幅读它）
final noteSyncProvider = NotifierProvider<NoteSyncNotifier, NoteSyncStatus>(
  NoteSyncNotifier.new,
);

class NoteSyncNotifier extends Notifier<NoteSyncStatus> {
  @override
  NoteSyncStatus build() {
    // 建起来时读一次待同步条数（不阻塞）
    unawaited(_refreshPending());
    return const NoteSyncStatus();
  }

  NoteStore get _store => ref.read(noteStoreProvider);
  NoteStationApi? get _api => ref.read(noteApiProvider);

  Future<void> _refreshPending() async {
    try {
      final n = await _store.pendingCount();
      state = state.copyWith(pending: n);
    } catch (_) {
      // 库还没建好（测试里没挂 db）时忽略
    }
  }

  Future<void> refreshPending() => _refreshPending();

  /// 拉一次全量（元数据 + 变化的正文），完了顺手推一次本地改动。
  ///
  /// 如果进 App 时就是离线（"离线浏览缓存"入口），这里**先静默重连**：
  /// 用户点「立即同步」的意图就是"我又有网了，把攒下的改动推上去"。
  Future<void> sync() async {
    if (_api == null) {
      state = state.copyWith(state: NoteSyncState.syncing, clearMessage: true);
      try {
        await ref.read(sessionControllerProvider.notifier).restore();
      } catch (_) {
        // 重连失败也走下面的"未连接"分支
      }
    }
    final api = _api;
    if (api == null) {
      state = state.copyWith(
        state: NoteSyncState.offline,
        message: currentText().setNotConnected,
      );
      await _refreshPending();
      return;
    }
    state = state.copyWith(state: NoteSyncState.syncing, clearMessage: true);
    try {
      final store = _store;
      final notebooks = await api.listNotebooks();
      await store.replaceNotebooks(notebooks);

      final list = await api.listNotes(limit: 500);
      final drafts = <NoteConflictDraft>[];
      final needContent = await store.mergeNoteList(
        list.notes,
        conflictsOut: drafts,
      );
      // 正文一条条补（只补变化过的，最多 30 条一轮，别把手机流量打光）
      var fetched = 0;
      for (final n in needContent) {
        if (fetched >= 30) break;
        try {
          // 加密笔记的正文也抓（缓存里是密文，解密只在内存里做）
          final full = await api.getNote(n.objectId);
          await store.putNote(full);
          fetched++;
        } on DsmApiException {
          continue; // 单条失败不影响整轮
        }
      }

      try {
        await store.replaceTodos(await api.listTodos());
      } on DsmApiException {
        // 这台 NAS 没开待办也不该让整轮失败
      }

      // 冲突：顺手把服务端正文抓下来（最多 5 条），界面上要能左右对照
      var conflicts = <NoteConflict>[];
      for (final d in drafts.take(5)) {
        var serverContent = '';
        var fetched = false;
        try {
          final full = await api.getNote(d.objectId);
          serverContent = full.content;
          fetched = true;
        } on DsmApiException {
          // 抓不到就只显示"本地内容"，用户仍然可以选"以本地为准"
        }
        conflicts.add(
          NoteConflict(
            objectId: d.objectId,
            title: d.title,
            baseVer: d.baseVer,
            serverVer: d.serverVer,
            localContent: d.localContent,
            serverContent: serverContent,
            serverFetched: fetched,
          ),
        );
      }
      if (drafts.length > 5) {
        // 多于 5 条的提醒一下（不静默吞掉）
        state = state.copyWith(
          message: currentText().noteConflictMore(drafts.length),
        );
      }

      state = state.copyWith(
        state: NoteSyncState.idle,
        lastSyncedAt: DateTime.now(),
        conflicts: conflicts,
        clearMessage: true,
      );
      await flushPending();
    } catch (e) {
      state = state.copyWith(
        state: isOfflineError(e) ? NoteSyncState.offline : NoteSyncState.error,
        message: userFacingError(e),
      );
    } finally {
      await _refreshPending();
    }
  }

  /// 把队列里的离线写操作按顺序推上去。
  ///
  /// 有一条失败就**停下**（保持顺序：新建 → 改 → 删），剩下的下次再来。
  Future<void> flushPending() async {
    final api = _api;
    if (api == null) return;
    final store = _store;
    final actions = await store.pending();
    if (actions.isEmpty) return;
    for (final a in actions) {
      try {
        await _replay(api, store, a);
        await store.removePending(a.id);
      } catch (e) {
        state = state.copyWith(
          state: isOfflineError(e)
              ? NoteSyncState.offline
              : NoteSyncState.error,
          message: currentText().notePendingSyncFailed(userFacingError(e)),
        );
        await _refreshPending();
        return;
      }
    }
    await _refreshPending();
    if (state.pending == 0 && state.state != NoteSyncState.idle) {
      state = state.copyWith(state: NoteSyncState.idle);
    }
  }

  // ------------------------------------------------------------- 冲突裁决

  /// 以**本地**为准：把本地这份内容用服务端的**最新版本**重新推上去
  /// （原来那条基于旧版本的队列项扔掉，不然永远报版本错）。
  Future<void> resolveWithLocal(NoteConflict conflict) async {
    final api = _api;
    if (api == null) return;
    final store = _store;
    try {
      // 大笔记走轮询（与编辑器同一条规则，见 `note_api.dart`）
      if (NoteStationApi.needsPolling(html: conflict.localContent)) {
        await api.setNotePolling(
          objectId: conflict.objectId,
          ver: conflict.serverVer,
          title: conflict.title,
          html: conflict.localContent,
        );
      } else {
        await api.setNote(
          objectId: conflict.objectId,
          ver: conflict.serverVer,
          title: conflict.title,
          html: conflict.localContent,
        );
      }
      await store.removePendingFor(conflict.objectId);
      final local = await store.note(conflict.objectId);
      if (local != null) await store.putNote(local); // dirty=false
      _dropConflict(conflict.objectId);
      state = state.copyWith(clearMessage: true);
      await _refreshPending();
    } catch (e) {
      state = state.copyWith(
        state: isOfflineError(e) ? NoteSyncState.offline : NoteSyncState.error,
        message: currentText().noteOverwriteFailed(userFacingError(e)),
      );
    }
  }

  /// 以**服务端**为准：扔掉本地待推送的改动，把服务端正文写回缓存。
  Future<void> resolveWithServer(NoteConflict conflict) async {
    final api = _api;
    if (api == null) return;
    final store = _store;
    try {
      // 正文可能没抓到（离线/加密） → 现抓一次
      var content = conflict.serverContent;
      var fetched = conflict.serverFetched;
      if (!fetched) {
        final full = await api.getNote(conflict.objectId);
        content = full.content;
        fetched = true;
        await store.putNote(full);
      } else {
        final local = await store.note(conflict.objectId);
        if (local != null) {
          await store.putNote(
            NoteDto(
              objectId: local.objectId,
              title: conflict.title,
              parentId: local.parentId,
              content: content,
              ver: conflict.serverVer,
              brief: local.brief,
              encrypt: local.encrypt,
              hasContent: true,
              mtime: local.mtime,
            ),
          );
        }
      }
      await store.removePendingFor(conflict.objectId);
      _dropConflict(conflict.objectId);
      state = state.copyWith(clearMessage: true);
      await _refreshPending();
    } catch (e) {
      state = state.copyWith(
        state: isOfflineError(e) ? NoteSyncState.offline : NoteSyncState.error,
        message: currentText().noteDiscardFailed(userFacingError(e)),
      );
    }
  }

  /// ★ 第 124 轮（台账 M5）：**按官方的办法"两边都保留"**。
  ///
  /// 官方取证（`callables/SyncPushCallable.smali`）：
  ///   * `:1194` `"handle conflict create note!"`、`:1364`
  ///     `"handle conflict set note!"`；
  ///   * 冲突标题 = 原标题 + 空格 + `R.string.conflict`（`:1282-1294`
  ///     用 `StringBuilder` 拼 `title` + `" "` + `getString(R.string.conflict)`，
  ///     `res/values/strings.xml:125` = `"Conflict"`）；
  ///   * 新笔记落在 `NetUtils.getDefaultNotebookId(context)`（`:1296`）。
  /// ⇒ 官方**没有字段级合并**，也**不"二选一"**：它把**本地那一版另存成
  ///   新笔记**（`<标题> Conflict`，默认笔记本），原笔记随后走服务端版。
  ///   这样**两边都不丢**。
  ///
  /// 我们照此实现，并保留原有的"以本地/以服务端为准"两个选择（**只多不少**）。
  Future<void> keepBothOnConflict(NoteConflict conflict) async {
    final api = _api;
    if (api == null) return;
    final store = _store;
    try {
      final parentId = await _conflictCopyParentId(store);
      await api.createNote(
        title: conflictCopyTitle(
          conflict.title,
          dataText('noteConflictSuffix', 'Conflict'),
        ),
        parentId: parentId,
        html: conflict.localContent,
        brief: conflict.title,
      );
      // 副本安顿好之后，原笔记以服务端版为准（与官方同序）
      await resolveWithServer(conflict);
      state = state.copyWith(
        message: dataText(
          'noteConflictKeptBoth',
          '两边都保留了：本地那一版已另存为副本',
        ),
      );
    } catch (e) {
      state = state.copyWith(
        state: isOfflineError(e) ? NoteSyncState.offline : NoteSyncState.error,
        message: dataText(
          'noteConflictKeepBothFailed',
          '保留副本失败：{error}',
        ).replaceAll('{error}', userFacingError(e)),
      );
    }
  }

  /// 副本落到哪个笔记本：优先**冲突笔记原来所在的**笔记本（比官方
  /// `getDefaultNotebookId` 更贴近用户预期；本机没有子笔记本树时等价），
  /// 再退回默认笔记本，最后退回第一个笔记本。
  Future<String> _conflictCopyParentId(NoteStore store) async {
    try {
      final local = await store.note(state.conflicts.first.objectId);
      final parent = local?.parentId.trim() ?? '';
      if (parent.isNotEmpty) return parent;
      final notebooks = await _api?.listNotebooks() ?? const [];
      for (final nb in notebooks) {
        if (nb.preset) return nb.objectId;
      }
      if (notebooks.isNotEmpty) return notebooks.first.objectId;
    } catch (_) {
      // 拿不到就用空串（服务端会放进默认笔记本）
    }
    return '';
  }

  /// 先不动，等下次同步再说（只把它从列表里收起来）
  void dismissConflict(String objectId) => _dropConflict(objectId);

  void _dropConflict(String objectId) {
    state = state.copyWith(
      conflicts: [
        for (final c in state.conflicts)
          if (c.objectId != objectId) c,
      ],
    );
  }

  Future<void> _replay(
    NoteStationApi api,
    NoteStore store,
    NotePendingAction a,
  ) async {
    final p = a.payload;
    String text(Object? v) => v == null ? '' : '$v';
    switch (a.kind) {
      case NotePendingKind.create:
        final created = await api.createNote(
          title: text(p['title']),
          parentId: text(p['parent_id']),
          html: text(p['content']),
          encrypt: p['encrypt'] == true,
        );
        await store.removeNote(a.objectId); // 本地临时 id 行
        await store.putNote(
          NoteDto(
            objectId: created.objectId,
            title: text(p['title']),
            parentId: text(p['parent_id']),
            content: text(p['content']),
            ver: created.ver,
            encrypt: p['encrypt'] == true,
            hasContent: true,
            mtime: noteEpochSeconds(),
          ),
        );
      case NotePendingKind.set:
        final html = text(p['content']);
        final encrypt = p['encrypt'] == true;
        final parentId = p['parent_id'] == null ? null : text(p['parent_id']);
        final brief = p['brief'] == null ? null : text(p['brief']);
        if (NoteStationApi.needsPolling(html: html, encrypt: encrypt)) {
          await api.setNotePolling(
            objectId: a.objectId,
            ver: text(p['ver']),
            title: text(p['title']),
            html: html,
            parentId: parentId,
            encrypt: encrypt ? true : null,
            brief: brief,
            mtime: noteEpochSeconds(),
          );
        } else {
          await api.setNote(
            objectId: a.objectId,
            ver: text(p['ver']),
            title: text(p['title']),
            html: html,
            parentId: parentId,
            encrypt: encrypt ? true : null,
            brief: brief,
            mtime: noteEpochSeconds(),
          );
        }
        // 推上去了 → dirty 清掉（putNote 默认 dirty=false）
        final local = await store.note(a.objectId);
        if (local != null) await store.putNote(local);
      case NotePendingKind.delete:
        await api.deleteNote(a.objectId, recycle: p['recycle'] == true);
        await store.removeNote(a.objectId);
      case NotePendingKind.todoCreate:
        final created = await api.createTodo(
          title: text(p['title']),
          comment: text(p['comment']),
          done: p['done'] == true,
          star: p['star'] == true,
          priority: (p['priority'] as num?)?.toInt() ?? -1,
          dueDate: (p['due_date'] as num?)?.toInt() ?? -1,
        );
        await store.removeTodo(a.objectId);
        await store.putTodo(created);
      case NotePendingKind.todoSet:
        await api.updateTodo(
          objectId: a.objectId,
          title: text(p['title']),
          comment: text(p['comment']),
          done: p['done'] == true,
          star: p['star'] == true,
          priority: (p['priority'] as num?)?.toInt() ?? -1,
          dueDate: (p['due_date'] as num?)?.toInt() ?? -1,
        );
        final todo = (await store.todos())
            .where((t) => t.objectId == a.objectId)
            .firstOrNull;
        if (todo != null) await store.putTodo(todo, dirty: false);
      case NotePendingKind.todoDelete:
        await api.deleteTodos([a.objectId]);
        await store.removeTodo(a.objectId);
    }
  }
}

/// 离线时的写法：先落本地 + 入队，联网后由 [NoteSyncNotifier.flushPending] 推。
///
/// 返回本地临时 id（以 `local_` 开头），页面上可以立刻显示。
Future<String> saveOffline(
  NoteStore store,
  NoteSyncNotifier sync, {
  required String? objectId,
  required String title,
  required String? parentId,
  required String html,
  required String ver,
  bool encrypt = false,
  String? brief,
}) async {
  // ★ DA80（r421 真机撞出并修掉）：本地行的 `mtime` 必须与**全模块同口径 = epoch 秒**。
  //   本函数原来写的是 `DateTime.now().millisecondsSinceEpoch`，而 `NoteDto.mtime`
  //   在别处一律是秒（服务端契约；`formatFileTime(int seconds)` 也按秒解释，
  //   见 `features/files/file_row.dart:89`）⇒ 详情页把毫秒当秒画成
  //   `Modified 58759-12-05`。同模块早已有 `noteEpochSeconds()` /
  //   `noteEpochSecondsNormalize()`（`data/dto/note_dto.dart:477/484`），
  //   只有这条本地写入路径没跟上 —— **修因**：这里改回同一个助手。
  //   ⚠️ 本地临时 id 仍用**毫秒**：同一秒内两次"离线新建"必须落成两条不同 id，
  //   秒级会撞车把前一条覆盖掉。
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final id = objectId ?? 'local_$nowMs';
  final note = NoteDto(
    objectId: id,
    title: title,
    parentId: parentId ?? '',
    content: html,
    ver: ver,
    encrypt: encrypt,
    brief: brief ?? '',
    hasContent: true,
    mtime: noteEpochSeconds(),
  );
  await store.putDirty(note);
  await store.enqueue(
    objectId == null ? NotePendingKind.create : NotePendingKind.set,
    id,
    {
      'title': title,
      'parent_id': parentId,
      'content': html,
      'ver': ver,
      if (encrypt) 'encrypt': true,
      if (brief != null) 'brief': brief,
    },
  );
  await sync.refreshPending();
  return id;
}

/// 离线删除：本地抹掉 + 入队
Future<void> deleteOffline(
  NoteStore store,
  NoteSyncNotifier sync,
  String objectId, {
  bool recycle = false,
}) async {
  await store.removeNote(objectId);
  await store.enqueue(NotePendingKind.delete, objectId, {'recycle': recycle});
  await sync.refreshPending();
}
