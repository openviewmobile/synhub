// File Station 下载的**多任务列表**（W1-3）。
//
// 为什么要有这一层：原来的 `downloadFileEntry` 一次只开一个模态进度框，
// 第二个下载会把第一个的框盖住（"互相覆盖"），也没有"多任务列表"与
// "失败重试 / 完成后点开"的入口。
//
// 本层**不另造传输**：每条任务照样走既有引擎
// （`FileActionsController.download` → `FileDownloadResumer`）——
//   * 临时文件 `<name>.sydownload` + `Range: bytes=<已下>-`（官方 `DownloadTask.java`）；
//   * 断点元数据 `.resume.json`（`FileResumeStore`）；
//   * 暂停 = 取消当前 HTTP 请求但**保留临时文件**（官方 `pauseTask`），
//     继续 = 重新执行并从临时文件长度续传（官方 `resumeTask`）。
// 所以"暂停 / 继续 / 取消 / 重试"都不是假按钮：重试会**接着已下载的部分**下，
// 不会重复写文件、也不会生成第二个文件。
//
// 并发策略：**同时只跑一条**（DSM 官方桌面端默认行为，也避免移动网络下抢带宽）。
// 其余任务进 `queued`，前一条结束自动开始 —— 这就是"不静默、不互相覆盖"。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/cache_service.dart' show humanBytes;
import '../../core/system_open.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/theme/app_theme.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../../dsm/webapi.dart' show DownloadCancelledException;
import 'file_download_resume.dart';
import 'filestation_p0b_text.dart';
import 'media_store_save.dart';

/// 任务状态
enum FileDownloadTaskStatus {
  /// 排队中（前一条还在跑）
  queued,

  /// 正在传输
  running,

  /// 用户暂停（临时文件保留，可继续）
  paused,

  /// 完成（[FileDownloadTask.localPath] 可打开）
  done,

  /// 失败（[FileDownloadTask.error] 有原因；可重试）
  failed,

  /// 用户取消
  cancelled,
}

/// 跑一条下载的入口（生产 = `FileActionsController.download`；测试注入假实现）。
typedef FileDownloadRunner =
    Future<FileDownloadOutcome> Function(
      String sourcePath, {
      required FileDownloadSession session,
    });

/// 一条下载任务（进度/状态可监听）。
///
/// 进度**复用**既有 [FileDownloadSession]（`received/total/percent` 语义与
/// 原进度框完全一致），本类只加"多任务所需的状态机 + 完成/失败信息"。
class FileDownloadTask extends ChangeNotifier {
  FileDownloadTask({
    required this.id,
    required this.sourcePath,
    required this.name,
    required this.runner,
  });

  final String id;
  final String sourcePath;
  final String name;
  final FileDownloadRunner runner;

  final Completer<void> _settled = Completer<void>();

  FileDownloadSession? _session;
  FileDownloadTaskStatus _status = FileDownloadTaskStatus.queued;
  String? _error;
  String? _localPath;
  bool _fullRestart = false;
  int _resumedFrom = 0;

  FileDownloadTaskStatus get status => _status;
  String? get error => _error;
  String? get localPath => _localPath;
  bool get fullRestart => _fullRestart;
  int get resumedFrom => _resumedFrom;

  /// 任务是否还没结束（排队/传输/暂停都算"在列表里活着"）
  bool get isActive =>
      _status == FileDownloadTaskStatus.queued ||
      _status == FileDownloadTaskStatus.running ||
      _status == FileDownloadTaskStatus.paused;

  bool get isDone => _status == FileDownloadTaskStatus.done;

  /// 可以点「打开」（已完成且知道文件在哪）
  bool get canOpen => isDone && (_localPath?.isNotEmpty ?? false);

  /// 完成/失败/取消时完成（`downloadFileEntry` 等它）
  Future<void> get settled => _settled.future;

  int get received => _session?.progress.value.received ?? 0;
  int get total => _session?.progress.value.total ?? 0;
  int get percent => _session?.percent ?? 0;
  String get humanReadable => _session?.humanReadable ?? '';

  FileDownloadSession _openSession() {
    final old = _session;
    if (old != null) {
      old.removeListener(notifyListeners);
      old.dispose();
    }
    final s = FileDownloadSession(name);
    s.addListener(notifyListeners);
    _session = s;
    return s;
  }

  void _mark(
    FileDownloadTaskStatus status, {
    String? error,
    String? localPath,
    bool fullRestart = false,
    int resumedFrom = 0,
  }) {
    _status = status;
    _error = error;
    if (localPath != null) _localPath = localPath;
    _fullRestart = fullRestart;
    _resumedFrom = resumedFrom;
    if (!_settled.isCompleted) _settled.complete();
    notifyListeners();
  }

  void markRunning() {
    _status = FileDownloadTaskStatus.running;
    _error = null;
    notifyListeners();
  }

  void markPaused() {
    if (_status != FileDownloadTaskStatus.running) return;
    _status = FileDownloadTaskStatus.paused;
    notifyListeners();
  }

  void markResumed() {
    if (_status != FileDownloadTaskStatus.paused) return;
    _status = FileDownloadTaskStatus.running;
    notifyListeners();
  }

  void markDone(FileDownloadOutcome outcome) => _mark(
    FileDownloadTaskStatus.done,
    localPath: outcome.localPath,
    fullRestart: outcome.fullRestart,
    resumedFrom: outcome.resumedFrom,
  );

  void markFailed(String message) =>
      _mark(FileDownloadTaskStatus.failed, error: message);

  void markCancelled() => _mark(FileDownloadTaskStatus.cancelled);

  /// 用户点暂停（保留临时文件；`resume` 时从已下载处续）
  void pause() {
    if (_status != FileDownloadTaskStatus.running) return;
    _session?.pause();
    // 状态由运行循环在收到 `FileDownloadPausedException` 时置 paused；
    // 这里先给即时反馈（网络回调可能有延迟）。
    _status = FileDownloadTaskStatus.paused;
    notifyListeners();
  }

  /// 用户点继续
  void resume() {
    if (_status != FileDownloadTaskStatus.paused) return;
    _session?.resume();
    _status = FileDownloadTaskStatus.running;
    notifyListeners();
  }

  /// 用户点取消
  void cancel() {
    if (!isActive) return;
    _session?.cancel();
    _session?.releaseGate();
    // 运行循环收到取消后置 cancelled；这里先给即时反馈。
    if (!_settled.isCompleted) {
      _status = FileDownloadTaskStatus.cancelled;
      _settled.complete();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _session?.removeListener(notifyListeners);
    _session?.dispose();
    super.dispose();
  }
}

/// 任务列表（并发 1 + 排队）。
class FileDownloadTaskList extends ChangeNotifier {
  final List<FileDownloadTask> _tasks = [];
  int _seq = 0;
  bool _pumping = false;

  /// 任务列表的路由是否已经打开（`downloadFileEntry` 用它避免叠框）
  bool dialogOpen = false;

  List<FileDownloadTask> get tasks => List.unmodifiable(_tasks);

  bool get hasActive => _tasks.any((t) => t.isActive);

  FileDownloadTask? byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 加入一条任务并（在有空位时）开始。
  FileDownloadTask start({
    required String sourcePath,
    required String name,
    required FileDownloadRunner runner,
  }) {
    final task = FileDownloadTask(
      id: 'dl-${_seq++}',
      sourcePath: sourcePath,
      name: name,
      runner: runner,
    );
    task.addListener(notifyListeners);
    _tasks.add(task);
    notifyListeners();
    _pump();
    return task;
  }

  /// 失败任务重试（**同一个任务 id / 同一个临时文件**，接着下，不复制文件）
  void retry(String id) {
    final task = byId(id);
    if (task == null) return;
    if (task.status != FileDownloadTaskStatus.failed &&
        task.status != FileDownloadTaskStatus.cancelled) {
      return;
    }
    _requeue(task);
  }

  /// 取消（保留已下载临时文件；再次重试仍可续）
  void cancel(String id) => byId(id)?.cancel();

  void pause(String id) => byId(id)?.pause();

  void resume(String id) => byId(id)?.resume();

  void _requeue(FileDownloadTask task) {
    // 换一个"未 settled"的包装：直接复用 status=queued + 新 session。
    // `settled` 已完成的任务不能复用同一个 Future → 用一个新任务对象替换。
    final replacement = FileDownloadTask(
      id: task.id,
      sourcePath: task.sourcePath,
      name: task.name,
      runner: task.runner,
    );
    replacement.addListener(notifyListeners);
    final i = _tasks.indexWhere((t) => t.id == task.id);
    if (i >= 0) _tasks[i] = replacement;
    task.removeListener(notifyListeners);
    task.dispose();
    notifyListeners();
    _pump();
  }

  void _pump() {
    if (_pumping) return;
    FileDownloadTask? next;
    for (final t in _tasks) {
      if (t.status == FileDownloadTaskStatus.queued) {
        next = t;
        break;
      }
    }
    if (next == null) return;
    final task = next;
    _pumping = true;
    unawaited(
      _run(task).whenComplete(() {
        _pumping = false;
        notifyListeners();
        _pump();
      }),
    );
  }

  Future<void> _run(FileDownloadTask task) async {
    task.markRunning();
    final session = task._openSession();
    // ignore: literal_only_boolean_expressions
    while (true) {
      session.beginRequest(); // ★ DA100：新一轮请求，清掉上一轮的暂停痕迹
      try {
        final outcome = await task.runner(task.sourcePath, session: session);
        task.markDone(outcome);
        return;
      } on FileDownloadPausedException {
        if (session.isCancelled ||
            task.status == FileDownloadTaskStatus.cancelled) {
          task.markCancelled();
          return;
        }
        // ★ DA100：**只在当前仍处于暂停**时才等「继续」。
        // 若用户已经点了「继续」（迟到的取消异常才回到这里），就当「继续下载」直接下一轮；
        // 否则会 `waitForResume()` 到一个**没人再放行**的新门上 ⇒ 任务挂死。
        if (session.isPaused) {
          // 等待「继续」；取消时 `releaseGate` 会放行
          await session.waitForResume();
          if (session.isCancelled ||
              task.status == FileDownloadTaskStatus.cancelled) {
            task.markCancelled();
            return;
          }
        }
        task.markResumed();
        continue;
      } on DownloadCancelledException {
        task.markCancelled();
        return;
      } on FileDownloadIncompleteException catch (e) {
        task.markFailed(
          fsP0bFill(FsP0bTextKeys.downloadIncomplete, '下载不完整：{detail}', {
            'detail': e.message,
          }),
        );
        return;
      } catch (e) {
        task.markFailed(describeFileError(e));
        return;
      }
    }
  }

  @override
  void dispose() {
    for (final t in _tasks) {
      t.removeListener(notifyListeners);
      t.dispose();
    }
    _tasks.clear();
    super.dispose();
  }
}

/// 任务列表（实现；生产用 `downloadFileEntry` 触发，测试可直接构造）。
final fileDownloadTaskListProvider = Provider<FileDownloadTaskList>((ref) {
  final list = FileDownloadTaskList();
  ref.onDispose(list.dispose);
  return list;
});

// ───────────────────────────── 文案（key + 中文回落） ─────────────────────────

String _t(String key, String zh) => dataText(key, zh);

String fileDownloadTaskListTitle() => _t('fsDownloadTaskListTitle', '下载任务');
String fileDownloadTaskEmpty() => _t('fsDownloadTaskEmpty', '还没有下载任务');
String fileDownloadTaskQueued() => _t('fsDownloadTaskQueued', '等待中');
String fileDownloadTaskDownloading() => _t('fsDownloadTaskDownloading', '下载中');
String fileDownloadTaskPaused() => _t('fsDownloadTaskPaused', '已暂停');
String fileDownloadTaskDone() => _t('fsDownloadTaskDone', '已完成');
String fileDownloadTaskFailed() => _t('fsDownloadTaskFailed', '下载失败');
String fileDownloadTaskCancelled() => _t('fsDownloadTaskCancelled', '已取消');
String fileDownloadTaskOpen() => _t('fsDownloadTaskOpen', '打开');

// ---- M68（审计行 220）：导出到系统「下载」目录 ----
String fileDownloadTaskSaveToDownloads() =>
    _t('fsDownloadTaskSaveToDownloads', '存到系统「下载」');
// ---- ★ 第 328 轮：宿主（macOS/Linux/Windows）上的对应文案 ----
// 宿主的落点由 `save_destination.dart` 的双轨裁决：用户选的目录（A）
// 或 App 容器里的 downloads（B）。两条都不是"系统「下载」目录"，
// 所以**不能**复用 Android 那三句（否则等于骗用户）。
String fileDownloadTaskSaveToLocal() =>
    _t('fsDownloadTaskSaveToLocal', '存到本机');
String fileDownloadTaskSavedToPath(String path) => _t(
  'fsDownloadTaskSavedToPath',
  '已保存到 {path}',
).replaceAll('{path}', path);
String fileDownloadTaskSaveLocalFailed() =>
    _t('fsDownloadTaskSaveLocalFailed', '保存到本机失败');
String fileDownloadTaskSaveOk() =>
    _t('fsDownloadTaskSaveOk', '已存到系统「下载」目录，可在系统「文件」App 里找到');
String fileDownloadTaskSaveUnsupported() =>
    _t('fsDownloadTaskSaveUnsupported', '这台设备不支持直接写入系统「下载」目录');
String fileDownloadTaskSaveFailed() =>
    _t('fsDownloadTaskSaveFailed', '存入系统「下载」目录失败');
String fileDownloadTaskRetry() => _t('fsDownloadTaskRetry', '重试');
String fileDownloadTaskClose() => _t('fsDownloadTaskClose', '关闭');
String fileDownloadTaskBackground() => _t('fsDownloadTaskBackground', '后台继续');
String fileDownloadTaskQueuedHint() =>
    _t('fsDownloadTaskQueuedHint', '排队中：前面的任务完成后自动开始');
String fileDownloadTaskActiveHint() =>
    _t('fsDownloadTaskActiveHint', '任务在后台继续；重新发起下载可再次打开此列表');

/// `{done}` / `{total}` 两个占位符
String fileDownloadTaskSummary(int done, int total) => _t(
  'fsDownloadTaskSummary',
  '{done}/{total} 已完成',
).replaceAll('{done}', '$done').replaceAll('{total}', '$total');

/// 顶栏常驻入口的 tooltip。`{count}` / `{percent}` 两个占位符。
///
/// 没有活跃任务时只说"下载任务"；有活跃任务时把**数量**与**整体进度**
/// 都放进来（入口本身用徽标显示数量，见 `_DownloadTasksButton`）。
String fileDownloadTaskEntryTooltip(int count, int? percent) {
  if (count <= 0) return _t('fsDownloadTaskEntry', '下载任务');
  return _t(
    'fsDownloadTaskEntryActive',
    '下载任务 · {count} 个进行中 · {percent}%',
  ).replaceAll('{count}', '$count').replaceAll('{percent}', '${percent ?? 0}');
}

/// 下载能力位缺失时，文件页顶栏就地给出的原因（入口同时隐藏）。
String fileDownloadDisabled() => _t('fsDownloadDisabled', '服务器未提供文件下载功能');

/// 打开下载任务列表（文件页顶栏的**常驻入口**用）。
///
/// 与 `downloadFileEntry` 共用 `dialogOpen` 去重：列表已经打开时不再叠一层。
/// 传 `FileDownloadTaskList` 而不是 `WidgetRef`，是为了让调用方
/// （`file_browse_page.dart` / `file_download.dart`）只关心"从哪个容器拿列表"。
void openFileDownloadTasksDialog(
  BuildContext context,
  FileDownloadTaskList controller,
) {
  if (controller.dialogOpen) return;
  controller.dialogOpen = true;
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    navigator
        .push(
          DialogRoute<void>(
            context: context,
            // 允许"后台继续"：关掉列表后任务照跑，任务栏入口可再次打开
            barrierDismissible: true,
            builder: (_) => FileDownloadTasksDialog(controller: controller),
          ),
        )
        .whenComplete(() => controller.dialogOpen = false),
  );
}

/// 单个任务行（进度 / 暂停 / 继续 / 取消 / 重试 / 打开）。
class FileDownloadTaskTile extends StatelessWidget {
  const FileDownloadTaskTile({
    super.key,
    required this.task,
    required this.controller,
    this.openHandler,
  });

  final FileDownloadTask task;
  final FileDownloadTaskList controller;

  /// 点「打开」的动作（null = 用系统默认打开）
  final Future<void> Function(String path)? openHandler;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) {
        final unknown = task.total <= 0;
        return Padding(
          key: ValueKey('download-task-${task.id}'),
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      task.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Text(
                    _statusLabel(task.status),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: task.status == FileDownloadTaskStatus.failed
                          ? theme.colorScheme.error
                          : hud.dim,
                    ),
                  ),
                ],
              ),
              if (task.status == FileDownloadTaskStatus.running ||
                  task.status == FileDownloadTaskStatus.paused) ...[
                const SizedBox(height: Gap.xs),
                LinearProgressIndicator(
                  key: ValueKey('download-task-bar-${task.id}'),
                  value: unknown ? null : task.percent / 100,
                ),
                if (!unknown)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Text(
                      '${task.humanReadable} · ${task.percent}%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                  ),
              ],
              if (task.status == FileDownloadTaskStatus.queued)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    fileDownloadTaskQueuedHint(),
                    style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
                ),
              if (task.status == FileDownloadTaskStatus.failed &&
                  (task.error?.isNotEmpty ?? false))
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    task.error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (task.status == FileDownloadTaskStatus.done &&
                  task.fullRestart)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    fsP0b(
                      FsP0bTextKeys.downloadRestarted,
                      '服务端不支持断点续传，已重新完整下载。',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
                ),
              if (task.status == FileDownloadTaskStatus.done &&
                  task.resumedFrom > 0 &&
                  !task.fullRestart)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    fsP0bFill(
                      FsP0bTextKeys.downloadResumed,
                      '已从 {size} 处继续下载。',
                      {'size': humanBytes(task.resumedFrom)},
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
                ),
              const SizedBox(height: Gap.xs),
              Wrap(
                spacing: Gap.sm,
                children: [
                  if (task.status == FileDownloadTaskStatus.running)
                    TextButton(
                      key: ValueKey('download-task-pause-${task.id}'),
                      onPressed: () => controller.pause(task.id),
                      child: Text(fsP0b(FsP0bTextKeys.downloadPause, '暂停')),
                    ),
                  if (task.status == FileDownloadTaskStatus.paused)
                    TextButton(
                      key: ValueKey('download-task-resume-${task.id}'),
                      onPressed: () => controller.resume(task.id),
                      child: Text(fsP0b(FsP0bTextKeys.downloadResume, '继续')),
                    ),
                  if (task.status == FileDownloadTaskStatus.failed ||
                      task.status == FileDownloadTaskStatus.cancelled)
                    FilledButton.tonal( style: InlineButtonStyle.filled,
                      key: ValueKey('download-task-retry-${task.id}'),
                      onPressed: () => controller.retry(task.id),
                      child: Text(fileDownloadTaskRetry()),
                    ),
                  if (task.canOpen)
                    FilledButton.icon( style: InlineButtonStyle.filled,
                      key: ValueKey('download-task-open-${task.id}'),
                      onPressed: () {
                        final path = task.localPath;
                        if (path == null) return;
                        final handler = openHandler ?? defaultSystemOpen;
                        unawaited(handler(path));
                      },
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(fileDownloadTaskOpen()),
                    ),
                  // M68（审计行 220）：下载完的文件在**应用私有目录**里，
                  // 系统「文件」App 看不到 ⇒ 给一个"存到系统「下载」目录"的出口。
                  if (task.canOpen && task.localPath != null)
                    _SaveToDownloadsButton(
                      taskId: task.id,
                      localPath: task.localPath!,
                      fileName: task.name,
                    ),
                  if (task.isActive)
                    TextButton(
                      key: ValueKey('download-task-cancel-${task.id}'),
                      onPressed: () => controller.cancel(task.id),
                      child: Text(context.t.actionCancel),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _statusLabel(FileDownloadTaskStatus status) => switch (status) {
    FileDownloadTaskStatus.queued => fileDownloadTaskQueued(),
    FileDownloadTaskStatus.running => fileDownloadTaskDownloading(),
    FileDownloadTaskStatus.paused => fileDownloadTaskPaused(),
    FileDownloadTaskStatus.done => fileDownloadTaskDone(),
    FileDownloadTaskStatus.failed => fileDownloadTaskFailed(),
    FileDownloadTaskStatus.cancelled => fileDownloadTaskCancelled(),
  };
}

/// 多任务下载列表对话框（所有任务一个列表，互不覆盖）。
class FileDownloadTasksDialog extends StatelessWidget {
  const FileDownloadTasksDialog({
    super.key,
    required this.controller,
    this.openHandler,
    this.onClose,
  });

  final FileDownloadTaskList controller;

  /// 点「打开」的动作（测试注入；null = 系统默认打开）
  final Future<void> Function(String path)? openHandler;

  /// 点「后台继续 / 关闭」的动作（默认 `Navigator.pop`）
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final tasks = controller.tasks;
        final done = tasks.where((t) => t.isDone).length;
        return AlertDialog(
          key: const Key('download-tasks-dialog'),
          title: Row(
            children: [
              Expanded(child: Text(fileDownloadTaskListTitle())),
              if (tasks.length > 1)
                Text(
                  fileDownloadTaskSummary(done, tasks.length),
                  key: const Key('download-tasks-summary'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          content: tasks.isEmpty
              // 常驻入口随时可打开 → 没有任务时必须是**空态**，不是空白弹层
              ? SizedBox(
                  height: 168,
                  child: AppEmptyState(
                    key: const Key('download-tasks-empty'),
                    icon: Icons.download_done_outlined,
                    title: fileDownloadTaskEmpty(),
                    compact: true,
                  ),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (controller.hasActive)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Gap.sm),
                            child: Text(
                              fileDownloadTaskActiveNotice(),
                              key: const Key('download-tasks-active-hint'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        for (final task in tasks)
                          FileDownloadTaskTile(
                            task: task,
                            controller: controller,
                            openHandler: openHandler,
                          ),
                      ],
                    ),
                  ),
                ),
          actions: [
            TextButton(
              key: const Key('download-tasks-close'),
              onPressed: () {
                if (onClose != null) {
                  onClose!();
                } else {
                  Navigator.of(context).pop();
                }
              },
              child: Text(
                controller.hasActive
                    ? fileDownloadTaskBackground()
                    : fileDownloadTaskClose(),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 「任务在后台继续」的一句说明（关闭后重新发起下载可再次打开列表）。
String fileDownloadTaskActiveNotice() => fileDownloadTaskActiveHint();

/// M68：把已完成任务的本地文件**导出到系统「下载」目录**。
///
/// 为什么单独抽一个 `ConsumerWidget`：这个按钮要拿
/// [mediaStoreSaverProvider]（测试里覆盖成假桥），而外层的
/// [FileDownloadTaskTile] 是 `StatelessWidget`。
class _SaveToDownloadsButton extends ConsumerStatefulWidget {
  const _SaveToDownloadsButton({
    required this.taskId,
    required this.localPath,
    required this.fileName,
  });

  final String taskId;
  final String localPath;
  final String fileName;

  @override
  ConsumerState<_SaveToDownloadsButton> createState() =>
      _SaveToDownloadsButtonState();
}

class _SaveToDownloadsButtonState
    extends ConsumerState<_SaveToDownloadsButton> {
  bool _busy = false;

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final saver = ref.read(mediaStoreSaverProvider);
      final result = await saver.saveToDownloads(
        sourcePath: widget.localPath,
        name: widget.fileName,
        mimeType: mediaStoreMimeForName(widget.fileName),
      );
      if (!mounted) return;
      // ★ 第 328 轮：宿主（macOS/Linux/Windows）上的落点是**本机文件系统路径**，
      //   不是 Android 的「下载」目录 ⇒ 文案与**路径**都得跟着换：
      //   B 轨（容器目录）用户根本猜不到在哪，只说"已保存"等于没说。
      // ★ 只认**结果**里的位（`hostTrack`），不认"当前宿主"：
      //   文案守卫必须与"跑用例的机器"无关（否则 Android 文案的用例
      //   在桌面上必红 —— 本用例第一版就是这么红的）。
      final hostLocal = result.hostTrack;
      final savedPath = result.uri ?? '';
      final text = result.ok
          ? (result.hostTrack && savedPath.isNotEmpty
                ? fileDownloadTaskSavedToPath(savedPath)
                : fileDownloadTaskSaveOk())
          : (hostLocal
                ? fileDownloadTaskSaveLocalFailed()
                : (result.unsupported
                      ? fileDownloadTaskSaveUnsupported()
                      : fileDownloadTaskSaveFailed()));
      messenger?.showSnackBar(SnackBar(content: Text(text)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: ValueKey('download-task-save-${widget.taskId}'),
      onPressed: _busy ? null : _save,
      icon: const Icon(Icons.save_alt, size: 16),
      // 桌面上不是"系统「下载」目录"，而是用户选的目录 / 容器目录 ⇒ 换文案。
      label: Text(
        fileExportUsesLocalFilesystem()
            ? fileDownloadTaskSaveToLocal()
            : fileDownloadTaskSaveToDownloads(),
      ),
    );
  }
}
