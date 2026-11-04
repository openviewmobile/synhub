// ★★★ ③Drive **D65「同步任务 / 同步设备管理」** 的界面层 —— 第 217 轮。
//
// 官方 `ShowSyncTaskActivity`（`sync/fragment/DriveSyncTaskListFragment`）：
// 任务列表 + 新建/编辑 + 每个任务的自动同步开关与冲突策略。
// 我们这一轮对齐**任务管理 + 同步差异检查**；真正的文件搬运与后台常驻服务
// （`DriveFileWatchService`）仍未实现 ⇒ 台账保持 🟠。
//
// 远端列举走**既有** `SYNO.SynologyDrive.Files.list`（Mock 可覆盖），
// 本地扫描走可注入的 `driveSyncLocalScannerProvider`（离线用例不碰真磁盘）。
import '../../design/kit/design_kit.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import 'drive_gaps_text.dart';
import '../files/drive_providers.dart';
import 'drive_file_watch.dart';
import 'drive_watch_bridge.dart';
import 'drive_sync_runner.dart';
import 'drive_sync_task.dart';

/// 任务存储（默认落在应用文档目录的 `drive_sync_tasks.json`）。
///
/// 文件路径要等 `path_provider`（异步）⇒ 用一个**首次使用时解析**的包装，
/// 免得为了一个 provider 去改启动流程。
class LazyJsonDriveSyncTaskStore implements DriveSyncTaskStore {
  DriveSyncTaskStore? _inner;

  Future<DriveSyncTaskStore> _resolve() async =>
      _inner ??= JsonDriveSyncTaskStore(await defaultDriveSyncStoreFile());

  @override
  Future<List<DriveSyncTask>> load() async => (await _resolve()).load();

  @override
  Future<void> save(List<DriveSyncTask> tasks) async =>
      (await _resolve()).save(tasks);
}

final driveSyncStoreProvider = Provider<DriveSyncTaskStore>(
  (ref) => LazyJsonDriveSyncTaskStore(),
);

/// 本地目录扫描（可注入 ⇒ 离线用例不碰真磁盘）。
typedef DriveSyncLocalScanner =
    Future<List<DriveSyncLocalEntry>> Function(String localRoot);

Future<List<DriveSyncLocalEntry>> _defaultLocalScanner(String localRoot) async {
  final root = Directory(normalizeDriveLocalRoot(localRoot));
  if (!await root.exists()) return const [];
  final out = <DriveSyncLocalEntry>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    final base = normalizeDriveLocalRoot(root.path);
    var rel = e.path.replaceAll('\\', '/');
    if (rel.startsWith('$base/')) rel = rel.substring(base.length + 1);
    if (e is Directory) {
      out.add(
        DriveSyncLocalEntry(
          path: rel,
          isDir: true,
          size: 0,
          modifiedMs: 0,
        ),
      );
      continue;
    }
    if (e is! File) continue;
    final st = await e.stat();
    out.add(
      DriveSyncLocalEntry(
        path: rel,
        isDir: false,
        size: st.size,
        modifiedMs: st.modified.millisecondsSinceEpoch,
      ),
    );
  }
  return out;
}

final driveSyncLocalScannerProvider = Provider<DriveSyncLocalScanner>(
  (ref) => _defaultLocalScanner,
);

/// 任务列表控制器（读/写 [DriveSyncTaskStore]）。
class DriveSyncTasksController extends AsyncNotifier<List<DriveSyncTask>> {
  @override
  Future<List<DriveSyncTask>> build() async {
    final store = ref.watch(driveSyncStoreProvider);
    return store.load();
  }

  List<DriveSyncTask> get _live =>
      (state.value ?? const []).where((t) => !t.deleted).toList();

  /// 新增/更新（按 id 去重）。返回校验失败的原因（成功则 null）。
  Future<String?> upsert(DriveSyncTask task) async {
    final existing = state.value ?? const <DriveSyncTask>[];
    final v = validateDriveSyncTask(task, existing);
    if (!v.ok) return v.error;
    final next = [...existing];
    final i = next.indexWhere((t) => t.id == task.id);
    if (i >= 0) {
      next[i] = task;
    } else {
      next.add(task);
    }
    await ref.read(driveSyncStoreProvider).save(next);
    state = AsyncData(next);
    return null;
  }

  /// 软删（官方 `deleted` 列，不物理清库）
  Future<void> remove(String id) async {
    final existing = state.value ?? const <DriveSyncTask>[];
    final next = [
      for (final t in existing)
        if (t.id == id) t.copyWith(deleted: true) else t,
    ];
    await ref.read(driveSyncStoreProvider).save(next);
    state = AsyncData(next);
  }

  /// 跑完一次检查后回写状态/游标/时间
  Future<void> markChecked(
    String id, {
    required DriveSyncStatus status,
    String? changeId,
    int? atMs,
  }) async {
    final existing = state.value ?? const <DriveSyncTask>[];
    final next = [
      for (final t in existing)
        if (t.id == id)
          t.copyWith(
            status: status,
            remoteRootChangeId: changeId ?? t.remoteRootChangeId,
            lastSyncAtMs: atMs ?? t.lastSyncAtMs,
          )
        else
          t,
    ];
    await ref.read(driveSyncStoreProvider).save(next);
    state = AsyncData(next);
  }

  /// 页面里只展示未删除的
  List<DriveSyncTask> get live => _live;
}

final driveSyncTasksProvider =
    AsyncNotifierProvider<DriveSyncTasksController, List<DriveSyncTask>>(
      DriveSyncTasksController.new,
    );

/// 新建任务时给一个稳定 id
String newDriveSyncTaskId(DateTime now) =>
    'sync_${now.millisecondsSinceEpoch}';

String _zh(String key, String zh) => driveGap(key, zh);

class DriveSyncTasksPage extends ConsumerStatefulWidget {
  const DriveSyncTasksPage({super.key, this.presetRemoteRoot});

  /// 从某个 Drive 目录进来时预填远端路径（官方从目录菜单入）
  final String? presetRemoteRoot;

  @override
  ConsumerState<DriveSyncTasksPage> createState() => _DriveSyncTasksPageState();
}

class _DriveSyncTasksPageState extends ConsumerState<DriveSyncTasksPage> {
  bool _busy = false;

  Future<void> _edit([DriveSyncTask? task]) async {
    final result = await showDialog<DriveSyncTask>(
      context: context,
      builder: (_) => _SyncTaskDialog(
        initial: task,
        presetRemoteRoot: widget.presetRemoteRoot,
      ),
    );
    if (result == null || !mounted) return;
    final err = await ref.read(driveSyncTasksProvider.notifier).upsert(result);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  /// 算一次差异（检查/执行共用）：本地扫描（可注入）+ 远端 `Files/list`。
  Future<DriveSyncDiff> _diffFor(DriveSyncTask task) async {
    final local = await ref.read(driveSyncLocalScannerProvider)(task.localRoot);
    final api = ref.read(driveApiProvider);
    if (api == null) throw StateError('未连接');
    final remote = await api.list(path: task.remoteRoot, limit: 500);
    return planDriveSync(
      local: local,
      remote: [
        for (final e in remote.items)
          DriveSyncRemoteEntry(
            path: e.name,
            isDir: e.isDir,
            size: e.size,
            modifiedMs: e.modifiedTime * 1000,
          ),
      ],
      task: task,
    );
  }

  /// ★ 224 轮 D65：**常驻监听本地变化并自动同步**（官方 `DriveFileWatchService`
  /// 的 Dart 侧对应物）。App 进程存活期间运行；页面退出时统一停掉。
  final _watchers = <String, DriveAutoSyncCoordinator>{};
  final _watchSubs = <String, StreamSubscription<DriveAutoSyncRun>>{};

  @override
  void dispose() {
    // ★ 224 轮：监听是有生命周期的 —— 页面走了必须停（否则后台空转 + 泄漏）
    for (final c in _watchers.values) {
      c.dispose();
    }
    for (final sub in _watchSubs.values) {
      sub.cancel();
    }
    _watchers.clear();
    _watchSubs.clear();
    super.dispose();
  }

  Future<void> _toggleWatch(DriveSyncTask task) async {
    final messenger = ScaffoldMessenger.of(context);
    final running = _watchers[task.id];
    if (running != null) {
      await running.dispose();
      await _watchSubs.remove(task.id)?.cancel();
      _watchers.remove(task.id);
      // ★ 228 轮：进程内监听停了，原生常驻监听（App 被杀也盯）也要撤
      if (_watchers.isEmpty) {
        try {
          await ref.read(driveWatchBridgeProvider).stop();
        } catch (_) {
          // 原生不可用（桌面/测试）忽略
        }
      }
      if (mounted) setState(() {});
      messenger.showSnackBar(
        SnackBar(content: Text(_zh('drive_sync_watch_stopped', '已停止监听'))),
      );
      return;
    }
    final api = ref.read(driveApiProvider);
    if (api == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(_zh('setNotConnected', '未连接'))),
      );
      return;
    }
    final co = DriveAutoSyncCoordinator(
      source: const IoDriveWatchSource(),
      task: task,
      diffBuilder: () => _diffFor(task),
      executor: DriveSyncExecutor(
        remote: DriveApiSyncIo(api, remoteRoot: task.remoteRoot),
        local: LocalDriveSyncIo(task.localRoot),
      ),
    );
    _watchers[task.id] = co;
    _watchSubs[task.id] = co.runs.listen((r) {
      if (!mounted) return;
      final text = r.ran
          ? '${_zh('drive_sync_watch_ran', '自动同步')}'
                '${_zh('driveGapLabelSep', '：')}'
                '${_zh('drive_sync_executed', '已执行')} ${r.executed} · '
                '${_zh('drive_sync_failed', '失败')} ${r.failed}'
          : '${_zh('drive_sync_watch_skip', '跳过')}'
                '${_zh('driveGapLabelSep', '：')}${r.skippedReason ?? ''}';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(text)));
    });
    await co.start();
    // ★ 228 轮：同时登记**原生常驻监听**（Service + FileObserver，
    // App 被杀后仍盯着；后台只记账唤醒，回来再搬文件）。
    // ★ 249 轮：把返回值当真看待 —— Android 12+ 在 App 不在前台时会**拒绝**
    // 启动常驻服务（真机实测撞到过），这时不能对用户说"已开始后台监听"。
    var nativeWatch = false;
    try {
      nativeWatch = await ref
          .read(driveWatchBridgeProvider)
          .start([task.localRoot]);
    } catch (_) {
      // 原生不可用（桌面/测试）不影响进程内监听
    }
    if (mounted) setState(() {});
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          nativeWatch
              ? _zh('drive_sync_watch_started', '已开始监听本地变化（App 在前台/后台存活期间）')
              : _zh(
                  'drive_sync_watch_no_native',
                  '已开始监听本地变化（App 存活期间）；系统未允许后台常驻监听，App 被杀后需重新开启',
                ),
        ),
      ),
    );
  }

  /// ★ 220 轮：**真的执行**（上传/下载/删本地/删远端/冲突副本）。
  Future<void> _execute(DriveSyncTask task) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(driveApiProvider);
    try {
      final diff = await _diffFor(task);
      if (api == null) throw StateError('未连接');
      final executor = DriveSyncExecutor(
        remote: DriveApiSyncIo(api, remoteRoot: task.remoteRoot),
        local: LocalDriveSyncIo(task.localRoot),
      );
      final r = await executor.run(diff);
      await ref
          .read(driveSyncTasksProvider.notifier)
          .markChecked(
            task.id,
            status: r.allOk ? DriveSyncStatus.done : DriveSyncStatus.error,
            atMs: DateTime.now().millisecondsSinceEpoch,
          );
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${_zh('drive_sync_executed', '已执行')} ${r.executed} · '
            '${_zh('drive_sync_failed', '失败')} ${r.failed}'
            '${r.failures.isEmpty ? '' : '${_zh('driveGapLabelSep', '：')}${r.failures.first.error}'}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(context.t.driveSyncFailedDetail('$e'))),
      );
    }
  }

  Future<void> _check(DriveSyncTask task) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final diff = await _diffFor(task);
      await ref
          .read(driveSyncTasksProvider.notifier)
          .markChecked(
            task.id,
            status: diff.isEmpty
                ? DriveSyncStatus.done
                : DriveSyncStatus.idle,
            atMs: DateTime.now().millisecondsSinceEpoch,
          );
      if (!mounted) return;
      setState(() => _busy = false);
      final session = ref.read(driveSyncTasksProvider.notifier);
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) {
          final hud = DesignPalette.of(ctx);
          return SafeArea(
            child: Material(
              color: hud.surface2,
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _zh('drive_sync_check_title', '同步检查结果'),
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    const SizedBox(height: Gap.sm),
                    Text(
                      '${_zh('drive_sync_upload', '待上传')} ${diff.uploads} · '
                      '${_zh('drive_sync_download', '待下载')} ${diff.downloads} · '
                      '${_zh('drive_sync_remove', '待删除')} ${diff.removes} · '
                      '${_zh('drive_sync_conflict', '冲突')} ${diff.conflicts}',
                    ),
                    const SizedBox(height: Gap.md),
                    // ⚠️ 只列前 8 条（官方的详单也在任务详情里）
                    for (final a in diff.actions.take(8))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${a.kind.label}  ${a.path}  ·  ${a.reason}',
                          style: TextStyle(fontSize: 12, color: hud.dim),
                        ),
                      ),
                    const SizedBox(height: Gap.md),
                    // 诚实边界：只做"检查"，不搬运文件（r378 去掉"本轮"这种会过期的进度话）
                    Text(
                      _zh(
                        'drive_sync_no_execute',
                        '这里只做差异检查：不会搬运文件，也没有后台常驻同步。',
                      ),
                      style: TextStyle(fontSize: 12, color: hud.dim),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
      // 会话控制器可能在 await 期间被回收
      if (!mounted) return;
      // ignore: unused_local_variable
      session;
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final failedText = context.t.driveSyncCheckFailedDetail('$e');
      await ref
          .read(driveSyncTasksProvider.notifier)
          .markChecked(task.id, status: DriveSyncStatus.error);
      messenger.showSnackBar(SnackBar(content: Text(failedText)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final async = ref.watch(driveSyncTasksProvider);
    return Scaffold(
      key: const Key('drive-sync-tasks-page'),
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(_zh('drive_sync_title', '同步任务')),
        actions: [
          IconButton(
            key: const Key('drive-sync-add'),
            tooltip: _zh('drive_sync_add', '新建同步任务'),
            icon: const Icon(Icons.add),
            onPressed: () => _edit(),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, __) => AppEmptyState(
          icon: Icons.error_outline,
          title: _zh('drive_sync_load_failed', '读不到同步任务'),
          message: '$e',
        ),
        data: (all) {
          final tasks = all.where((t) => !t.deleted).toList();
          if (tasks.isEmpty) {
            return AppEmptyState(
              icon: Icons.sync_outlined,
              title: _zh('drive_sync_title', '同步任务'),
              message: _zh(
                'drive_sync_empty',
                '还没有同步任务。新建后可以对照本地文件夹与 Drive 的差异。',
              ),
            );
          }
          return ListView.builder(
            itemCount: tasks.length,
            itemBuilder: (context, i) {
              final t = tasks[i];
              return DesignRowTile(
                key: Key('drive-sync-task-${t.id}'),
                leading: Icon(
                  t.autoSyncEnabled ? Icons.sync : Icons.sync_disabled,
                  color: t.status == DriveSyncStatus.error
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                title: Text(t.localName.isEmpty ? t.localRoot : t.localName),
                subtitle: Text(
                  '${t.remoteRoot}\n${t.status.label} · '
                  '${_zh('drive_sync_interval', '间隔')} ${t.autoSyncInterval}min · '
                  '${t.conflict.label}',
                ),
                isThreeLine: true,
                trailing: PopupMenuButton<String>(
                  key: Key('drive-sync-menu-${t.id}'),
                  onSelected: (v) {
                    switch (v) {
                      case 'check':
                        _check(t);
                      case 'execute':
                        _execute(t);
                      case 'watch':
                        _toggleWatch(t);
                      case 'edit':
                        _edit(t);
                      case 'delete':
                        ref
                            .read(driveSyncTasksProvider.notifier)
                            .remove(t.id);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'check',
                      child: Text(_zh('drive_sync_check', '立即检查')),
                    ),
                    PopupMenuItem(
                      value: 'execute',
                      child: Text(_zh('drive_sync_execute', '立即执行')),
                    ),
                    PopupMenuItem(
                      value: 'watch',
                      child: Text(
                        _watchers.containsKey(t.id)
                            ? _zh('drive_sync_watch_stop', '停止监听')
                            : _zh('drive_sync_watch_start', '监听本地变化'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(_zh('drive_sync_edit', '编辑')),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(_zh('drive_sync_delete', '删除')),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _SyncTaskDialog extends StatefulWidget {
  const _SyncTaskDialog({this.initial, this.presetRemoteRoot});

  final DriveSyncTask? initial;
  final String? presetRemoteRoot;

  @override
  State<_SyncTaskDialog> createState() => _SyncTaskDialogState();
}

class _SyncTaskDialogState extends State<_SyncTaskDialog> {
  late final TextEditingController _local = TextEditingController(
    text: widget.initial?.localRoot ?? '',
  );
  late final TextEditingController _remote = TextEditingController(
    text: widget.initial?.remoteRoot ?? widget.presetRemoteRoot ?? '/mydrive',
  );
  late bool _auto = widget.initial?.autoSyncEnabled ?? true;
  late int _interval =
      widget.initial?.autoSyncInterval ?? kDriveSyncDefaultIntervalMinutes;
  late DriveSyncConflict _conflict =
      widget.initial?.conflict ?? DriveSyncConflict.rename;
  late bool _ignoreLocalRemove = widget.initial?.ignoreLocalRemove ?? false;

  @override
  void dispose() {
    _local.dispose();
    _remote.dispose();
    super.dispose();
  }

  void _submit() {
    final base = widget.initial;
    final task = DriveSyncTask(
      id: base?.id ?? newDriveSyncTaskId(DateTime.now()),
      localRoot: normalizeDriveLocalRoot(_local.text),
      remoteRoot: normalizeDriveRemoteRoot(_remote.text),
      remoteRootChangeId: base?.remoteRootChangeId ?? '',
      status: base?.status ?? DriveSyncStatus.idle,
      autoSyncEnabled: _auto,
      autoSyncInterval: _interval,
      conflict: _conflict,
      ignoreLocalRemove: _ignoreLocalRemove,
      lastSyncAtMs: base?.lastSyncAtMs ?? 0,
    );
    Navigator.of(context).pop(task);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('drive-sync-dialog'),
      title: Text(
        widget.initial == null
            ? _zh('drive_sync_add', '新建同步任务')
            : _zh('drive_sync_edit', '编辑'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('drive-sync-local-field'),
              controller: _local,
              decoration: InputDecoration(
                labelText: _zh('drive_sync_local', '本地文件夹'),
                hintText: context.t.driveSyncLocalHint,
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              key: const Key('drive-sync-remote-field'),
              controller: _remote,
              decoration: InputDecoration(
                labelText: _zh('drive_sync_remote', '远端文件夹'),
                hintText: context.t.driveSyncRemoteHint,
              ),
            ),
            const SizedBox(height: Gap.md),
            DesignSwitchRow(
              key: const Key('drive-sync-auto'),
              contentPadding: EdgeInsets.zero,
              value: _auto,
              title: Text(_zh('drive_sync_auto', '自动同步')),
              subtitle: Text(
                _zh('drive_sync_interval', '间隔'),
              ),
              onChanged: (v) => setState(() => _auto = v),
            ),
            DropdownButtonFormField<int>(
              isExpanded: true,
              key: const Key('drive-sync-interval'),
              initialValue: _interval,
              decoration: InputDecoration(
                labelText: _zh('drive_sync_interval', '间隔'),
              ),
              items: [
                for (final m in kDriveSyncIntervalChoices)
                  DropdownMenuItem(value: m, child: Text('$m min')),
              ],
              onChanged: (v) => setState(() => _interval = v ?? _interval),
            ),
            const SizedBox(height: Gap.md),
            Text(_zh('drive_sync_conflict', '冲突处理')),
            RadioGroup<DriveSyncConflict>(
              groupValue: _conflict,
              onChanged: (v) =>
                  setState(() => _conflict = v ?? _conflict),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in DriveSyncConflict.values)
                    RadioListTile<DriveSyncConflict>(
                      key: Key('drive-sync-conflict-${c.wire}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: c,
                      title: Text(c.label),
                    ),
                ],
              ),
            ),
            DesignSwitchRow(
              key: const Key('drive-sync-ignore-remove'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _ignoreLocalRemove,
              title: Text(
                _zh('drive_sync_ignore_remove', '忽略本地删除（不删远端）'),
              ),
              onChanged: (v) => setState(() => _ignoreLocalRemove = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_zh('common_cancel', '取消')),
        ),
        FilledButton(
          key: const Key('drive-sync-save'),
          onPressed: _submit,
          child: Text(_zh('common_save', '保存')),
        ),
      ],
    );
  }
}

/// 存储落盘文件（应用文档目录）
Future<File> defaultDriveSyncStoreFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/drive_sync_tasks.json');
}
