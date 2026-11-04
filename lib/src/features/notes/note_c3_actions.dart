// C3（NoteStation 补齐）的**动作层**：导出 / 导入 / 剪藏 / 版本回滚。
//
// 页面只负责"确认 + 提示"，真正的 start→轮询→下载/上传/pdf 流程都在这里，
// 这样"取消确认 → 零请求"可以用一个动作调用点来证明。
//
// 轮询间隔/provider 都可以覆盖：[noteC3PollIntervalProvider]（官方 1200ms）、
// [noteC3DownloadDirProvider]、[noteC3SystemOpenProvider]。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../core/services/service_registry.dart'
    show
        kNoAppPrivilegeCode,
        kNoPermissionCode,
        kSessionTimeoutCode,
        kSidNotFoundCode;
import '../../core/system_open.dart';
import '../../data/dto/note_c3_dto.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import '../../dsm/webapi.dart';
import '../files/file_providers.dart' show fileDownloadDirectory;
import 'note_c3_providers.dart';
import 'note_c3_text.dart';
import 'note_providers.dart';
import 'note_wave4_text.dart';
import '../../core/user_facing_error.dart';

/// 官方轮询节奏（`Ext.defer(…,1200,this)`，`ui/notestation.js`）
final noteC3PollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 1200),
);

/// 最多轮询多少次（≈ 5 分钟；超了当失败并 `stop` 掉服务端任务）
const int noteC3MaxPolls = 250;

/// 落盘目录（做成 provider 是为了 widget 测试里覆盖成临时目录）
final noteC3DownloadDirProvider = Provider<Future<Directory> Function()>(
  (ref) => fileDownloadDirectory,
);

/// 交给系统打开（测试覆盖成假的）
final noteC3SystemOpenProvider = Provider<SystemOpenRunner>(
  (ref) => ref.watch(systemOpenProvider),
);

/// 用系统浏览器打开一个 URL（Evernote OAuth 授权页）。
///
/// **审计 §6.3 的夸大修正点**：原实现只把授权 URL 塞进 SnackBar、**从不打开
/// 浏览器**，向导因此走不完。官方是 `window.open(get_oauth_url)`，这里等价的
/// Flutter 实现就是 `launchUrl(..., externalApplication)`。
/// 做成 provider 是为了 widget 测试注入假实现（不发真实 Intent / 不联外网）。
typedef NoteUrlOpener = Future<bool> Function(Uri url);

final noteUrlOpenerProvider = Provider<NoteUrlOpener>(
  (ref) => (url) => launcher.launchUrl(url, mode: launcher.LaunchMode.externalApplication),
);

/// 导出结果写盘的方式（做成 provider 便于测试注入）。
///
/// 生产走异步写（不阻塞 UI）；widget 测试在 FakeAsync 下异步 I/O 不会在
/// `pump` 之间落地，所以测试里覆盖成 `writeAsBytesSync`。
typedef NoteC3FileWriter = Future<void> Function(File file, List<int> bytes);

final noteC3FileWriterProvider = Provider<NoteC3FileWriter>(
  (ref) =>
      (file, bytes) => file.writeAsBytes(bytes),
);

/// 导出格式（官方右键菜单两条：`export` = `.nsx`、`export_word` = Word）
enum NoteExportFormat { word, note }

/// 导入等长任务的取消令牌（页面的"取消"按钮置位，轮询循环下一拍收手）。
class NoteC3Cancel {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// 用户主动取消（不是失败）：页面据此提示"已取消"而不是报错。
class NoteC3CancelledException extends NoteC3Exception {
  NoteC3CancelledException()
    : super(noteC3(NoteC3TextKeys.importCancelled, '已取消'));
}

/// 导出/导入失败（带人话消息；页面直接显示）
class NoteC3Exception implements Exception {
  NoteC3Exception(this.message, {this.permissionDenied = false});

  final String message;

  /// `105`/`160`：页面据此**隐藏该入口**并给无权限提示
  final bool permissionDenied;

  @override
  String toString() => message;
}

String _sessionText() => noteC3(NoteC3TextKeys.sessionHint, '会话已过期，请重新登录');

/// 「文案（错误码）」：错误码是服务端数字，只有括号/分隔符要走翻译。
String _withCode(String message, int code) => '$message'
    '${noteC3Fill(NoteC3TextKeys.errorCodeSuffix, '（{code}）', {'code': '$code'})}';

/// 把异常翻译成 C3 文案（`105`/`160` / `119`/`106` / 其它）
String describeNoteC3Error(Object error) {
  if (error is NoteC3Exception) return error.message;
  if (error is DsmApiException) {
    switch (error.code) {
      case kNoPermissionCode:
      case kNoAppPrivilegeCode:
        return _withCode(
          noteC3(NoteC3TextKeys.noPermission, '没有权限使用这个功能'),
          error.code,
        );
      case kSidNotFoundCode:
      case kSessionTimeoutCode:
        return _withCode(_sessionText(), error.code);
    }
    return _withCode(
      noteC3(NoteC3TextKeys.actionFailed, '操作失败'),
      error.code,
    );
  }
  return userFacingError(error);
}

/// 这个错误是不是"没有权限"（用于隐藏入口）
bool isNoteC3Denied(Object error) {
  if (error is NoteC3Exception) return error.permissionDenied;
  if (error is DsmApiException) {
    return error.code == kNoPermissionCode || error.code == kNoAppPrivilegeCode;
  }
  return false;
}

/// 导出失败的**如实**描述。
///
/// 真机复测（2026-09-22）：`Export.{Note,Word}:status {task_id}` 恒定回 **114**，
/// 错误体里带 `errors.synodrive` —— 这是**导出子系统**报错（导出产物要落到用户
/// Synology Drive 的 `NoteStation_Output*`），**不是参数名写错**；同一 NAS 上
/// `start` 是成功的。这里把它翻译成中性人话，其它错误仍走 [describeNoteC3Error]。
///
/// 判别依据是**读错误体全文**（`DsmApiException.raw`），不是只看 `code`。
String describeNoteExportError(Object error) {
  if (error is DsmApiException && error.code == 114) {
    final err = error.raw?['error'];
    final bodyErrors = error.raw?['errors'];
    final nested = err is Map ? err['errors'] : null;
    final hasSubsystemError =
        (bodyErrors is Map && bodyErrors.isNotEmpty) ||
        (nested is Map && nested.isNotEmpty);
    if (hasSubsystemError) {
      return _withCode(
        noteWave4(
          NoteWave4TextKeys.exportSubsystem,
          '这台 NAS 的导出子系统报错（导出产物依赖 Synology Drive）',
        ),
        error.code,
      );
    }
  }
  return describeNoteC3Error(error);
}

NoteStationApi _api(WidgetRef ref) {
  final api = ref.read(noteApiProvider);
  if (api == null) {
    throw NoteC3Exception(noteC3(NoteC3TextKeys.notConnected, '尚未连接到 NAS'));
  }
  return api;
}

// ---------------------------------------------------------------- 导出

/// 导出单条笔记：`start` → 轮询 `status` → `download` 落盘（可选交给系统打开）。
///
/// 返回落盘后的**文件名**（服务端 `status.filename` 为准）。失败抛
/// [NoteC3Exception]。官方流程见 `note_api.dart` 顶部注释。
Future<String> exportNoteFile(
  WidgetRef ref, {
  required NoteDto note,
  required NoteExportFormat format,
  String? token,
  bool openAfter = false,
  void Function(int poll)? onPoll,
}) async {
  final api = _api(ref);
  final interval = ref.read(noteC3PollIntervalProvider);
  final downloadDir = ref.read(noteC3DownloadDirProvider);
  final systemOpen = ref.read(noteC3SystemOpenProvider);
  final isWord = format == NoteExportFormat.word;

  final taskId = isWord
      ? await api.startWordExport(note.objectId, token: token)
      : await api.startNoteExport(note.objectId, token: token);
  if (taskId.isEmpty) {
    throw NoteC3Exception(
      noteC3Fill(NoteC3TextKeys.exportFailed, '导出失败：{error}', {
        'error': 'no task',
      }),
    );
  }

  NoteExportTaskDto status = NoteExportTaskDto(taskId: taskId);
  var polls = 0;
  try {
    while (true) {
      if (polls > 0) await Future<void>.delayed(interval);
      onPoll?.call(polls);
      status = isWord
          ? await api.wordExportStatus(taskId)
          : await api.noteExportStatus(taskId);
      polls++;
      if (status.finish) break;
      if (polls >= noteC3MaxPolls) {
        throw NoteC3Exception(
          noteC3Fill(NoteC3TextKeys.exportFailed, '导出失败：{error}', {
            'error': 'timeout',
          }),
        );
      }
    }
  } catch (e) {
    // 失败/超时：把服务端任务停掉（官方 download 会 remove，但我们没走到）
    try {
      if (isWord) {
        await api.stopWordExport(taskId);
      } else {
        await api.stopNoteExport(taskId);
      }
    } catch (_) {
      // stop 失败不该盖住原始错误
    }
    rethrow;
  }

  final url = isWord ? api.wordExportUrl(taskId) : api.noteExportUrl(taskId);
  final bytes = await api.api.getBytes(url);
  if (bytes.isEmpty) {
    throw NoteC3Exception(noteC3(NoteC3TextKeys.exportEmpty, '导出结果为空文件'));
  }
  final dir = await downloadDir();
  final fileName = status.filename.isNotEmpty
      ? status.filename
      : _fallbackExportName(note, isWord);
  final file = File('${dir.path}/$fileName');
  await ref.read(noteC3FileWriterProvider)(file, bytes);
  if (openAfter) await systemOpen(file.path);
  return fileName;
}

String _fallbackExportName(NoteDto note, bool isWord) {
  final base = note.displayTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return '$base.${isWord ? 'docx' : 'nsx'}';
}

/// 把笔记本导出到 NAS 上的目录（`Export.Notebook`，**服务端写 `dest`，不由客户端下载**）。
///
/// 三个参数都有原文依据（见 `note_api.dart` 的 `startNotebookExport`）；不确定的
/// 是 `dest` 的**路径写法**（官方向导用 FileChooser 选共享文件夹，`choosed_share_path`）
/// —— 所以界面上让用户显式填路径，填错由服务端报错（待取证，见实现文档）。
Future<void> exportNotebookToNas(
  WidgetRef ref, {
  required String notebookId,
  required String dest,
  bool saveConfig = false,
  bool exportTodo = false,
  void Function(NoteImportStatusDto status)? onProgress,
}) async {
  if (dest.trim().isEmpty) {
    throw NoteC3Exception(noteC3(NoteC3TextKeys.exportDest, '目标目录不能为空'));
  }
  final api = _api(ref);
  final interval = ref.read(noteC3PollIntervalProvider);
  await api.startNotebookExport(
    notebookId: notebookId,
    dest: dest.trim(),
    saveConfig: saveConfig,
    exportTodo: exportTodo,
  );
  // 官方这条**没有 task_id**：`status` 是全局的（见 note_api.dart 的注释）
  NoteImportStatusDto status = const NoteImportStatusDto();
  for (var i = 0; i < noteC3MaxPolls; i++) {
    if (i > 0) await Future<void>.delayed(interval);
    status = await api.notebookExportStatus();
    onProgress?.call(status);
    if (status.finish) break;
  }
  if (!status.finish) {
    try {
      await api.stopNotebookExport();
    } catch (_) {
      // 同上：stop 失败不盖原始错误
    }
    throw NoteC3Exception(
      noteC3Fill(NoteC3TextKeys.exportFailed, '导出失败：{error}', {
        'error': 'timeout',
      }),
    );
  }
}

// ---------------------------------------------------------------- 导入

/// 导入的来源类型
enum NoteImportKind {
  /// `.enex`（Evernote 导出文件）—— `SYNO.NoteStation.Import.Enex`
  enex('SYNO.NoteStation.Import.Enex'),

  /// `.nsx`（NoteStation 归档）—— `SYNO.NoteStation.Import.Notebook`
  notebook('SYNO.NoteStation.Import.Notebook');

  const NoteImportKind(this.apiName);
  final String apiName;
}

/// 从本地文件导入（multipart 上传 → 轮询 `status` → 完成）。
///
/// 返回最终状态。失败抛 [NoteC3Exception]；调用方负责二次确认与提示。
/// 官方证据：上传字段形态见 `note_api.dart` 的 `_startImportUpload`。
Future<NoteImportStatusDto> importNoteArchive(
  WidgetRef ref, {
  required NoteImportKind kind,
  required String path,
  required String fileName,
  NoteC3Cancel? cancel,
  void Function(NoteImportStatusDto status)? onProgress,
}) async {
  final api = _api(ref);
  final interval = ref.read(noteC3PollIntervalProvider);
  final file = File(path);
  if (!file.existsSync()) {
    throw NoteC3Exception(
      noteC3(NoteC3TextKeys.importFileMissing, '找不到要导入的文件'),
    );
  }
  final taskId = kind == NoteImportKind.enex
      ? await api.startEnexImport(path: path, fileName: fileName)
      : await api.startNotebookImport(path: path, fileName: fileName);
  if (taskId.isEmpty) {
    throw NoteC3Exception(
      noteC3Fill(NoteC3TextKeys.importFailed, '导入失败：{error}', {
        'error': 'no task',
      }),
    );
  }

  NoteImportStatusDto status = const NoteImportStatusDto();
  var polls = 0;
  try {
    while (true) {
      if (cancel?.cancelled ?? false) throw NoteC3CancelledException();
      if (polls > 0) await Future<void>.delayed(interval);
      status = kind == NoteImportKind.enex
          ? await api.enexImportStatus()
          : await api.notebookImportStatus();
      onProgress?.call(status);
      polls++;
      if (status.finish) break;
      if (polls >= noteC3MaxPolls) {
        throw NoteC3Exception(
          noteC3Fill(NoteC3TextKeys.importFailed, '导入失败：{error}', {
            'error': 'timeout',
          }),
        );
      }
    }
  } catch (e) {
    try {
      if (kind == NoteImportKind.enex) {
        await api.stopEnexImport();
      } else {
        await api.stopNotebookImport();
      }
    } catch (_) {
      // 同上
    }
    rethrow;
  }

  if (!status.success) {
    throw NoteC3Exception(
      noteC3Fill(NoteC3TextKeys.importFailed, '导入失败：{error}', {
        'error': '${status.errorCode}',
      }),
    );
  }
  ref.invalidate(noteListProvider);
  ref.invalidate(notebooksProvider);
  return status;
}

// ---------------------------------------------------------------- 网页剪藏

/// 官方服务端接受的剪藏 URL 判定：必须以 `http` 开头
/// （`SYNO.NoteStation.Note.so` 偏移 304680 `strClipUrl.substr(0,4) != "http"`；
/// 同 .so 偏移 301375/301383 是 `http://` / `https://` 字面量）。
bool isValidClipUrl(String url) {
  final u = url.trim().toLowerCase();
  return u.startsWith('http://') || u.startsWith('https://');
}

/// 把网页剪藏成一条新笔记 —— **逐条照官方 `ClipperService.createNoteByURL`**：
///
///   1. 优先 `SYNO.NoteStation.Note.Ghost/create` v2；服务端不支持时回退
///      `Note/create` **v2**（[E2] `ClipperService.java` 的 `supportApi` 分支）；
///   2. 发 `clipper_url` / `title` / `clipper_mode` / `parent_id` /
///      `commit_msg{device}` / `clipper_user_agent`；
///   3. `clipper_mode` 由 [retrieveType]（官方设置键 `clipper_retrieve_type`，
///      `simplified` / `whole`）映射：`whole → fullpage`，其余 → `simplepage`；
///   4. **不发 `source_url`**（官方 Android 剪藏路径没有这个字段，审计 U8）。
///
/// 返回新笔记 id；Ghost 路径回包没有 `object_id`（官方要等一次 sync 才看到），
/// 此时返回空串，调用方只提示"已提交、稍后同步"。
Future<String> clipWebPage(
  WidgetRef ref, {
  required String url,
  required String title,
  required String notebookId,
  String retrieveType = 'simplified',
  String? clipperMode,
  List<String> tags = const [],
}) async {
  if (!isValidClipUrl(url)) {
    throw NoteC3Exception(
      noteC3(NoteC3TextKeys.clipInvalidUrl, '请输入以 http:// 或 https:// 开头的网址'),
    );
  }
  if (notebookId.isEmpty) {
    throw NoteC3Exception(noteC3(NoteC3TextKeys.clipNotebook, '请选择笔记本'));
  }
  final api = _api(ref);
  final mode = (clipperMode == null || clipperMode.isEmpty)
      ? NoteStationApi.clipperModeFor(retrieveType)
      : clipperMode;
  final clipTitle = title.trim();
  if (api.supportsGhostCreate()) {
    // 官方优先路径：服务端按 clipper_url 抓正文，回包无 object_id
    await api.createGhostNote(
      url: url.trim(),
      title: clipTitle,
      parentId: notebookId,
      clipperMode: mode,
      tags: tags,
    );
    ref.invalidate(noteListProvider);
    // 官方在 Ghost 创建 5s 后触发一次 PULL sync；这里立刻拉一次列表，
    // 拉不到也没关系（服务端抓取是异步的）
    return '';
  }
  final created = await api.createClipperNote(
    url: url.trim(),
    title: clipTitle,
    parentId: notebookId,
    clipperMode: mode,
    tags: tags,
  );
  ref.invalidate(noteListProvider);
  return created;
}

// ---------------------------------------------------------------- 版本

/// 回滚到某个历史版本（`Note.Version/restore` v2，参数名是 `ver`）。
///
/// 危险操作：调用方**必须先二次确认**（确认框取消时不能走到这里）。
Future<void> restoreNoteVersion(
  WidgetRef ref, {
  required String objectId,
  required String ver,
}) async {
  final api = _api(ref);
  await api.restoreVersion(
    objectId,
    ver,
    permFrom: noteVersionPermFrom,
    smartId: noteVersionSmartId,
  );
  ref.invalidate(noteDetailProvider(objectId));
  ref.invalidate(noteVersionsTypedProvider(objectId));
  ref.invalidate(noteListProvider);
}

/// 把某个历史版本复制成一条新笔记（官方「复制为新笔记」，
/// `Note/copy {object_id,title,parent_id,ver}`）。
Future<String> copyVersionToNewNote(
  WidgetRef ref, {
  required NoteDto note,
  required String ver,
  required String title,
}) async {
  final api = _api(ref);
  final newId = await api.copyNote(
    note.objectId,
    parentId: note.parentId,
    title: title,
    ver: ver,
  );
  ref.invalidate(noteListProvider);
  return newId;
}

/// 版本历史里的"设备名/作者"一行（官方历史表格列：
/// `mtime` / `author` / `commit_msg.device`）。
String noteVersionSubtitle(NoteVersionDto v) {
  final parts = <String>[];
  if (v.author.isNotEmpty) parts.add(v.author);
  if (v.device.isNotEmpty) parts.add(v.device);
  return parts.join(' · ');
}

/// 会话失效文案
String noteC3SessionText() => noteC3(NoteC3TextKeys.sessionHint, '会话已过期，请重新登录');

/// 无权限文案
String noteC3NoPermissionText() =>
    noteC3(NoteC3TextKeys.noPermission, '没有权限使用这个功能');

/// 无权限补充说明
String noteC3NoPermissionHintText() =>
    noteC3(NoteC3TextKeys.noPermissionHint, '当前账号没有这个功能的权限');
