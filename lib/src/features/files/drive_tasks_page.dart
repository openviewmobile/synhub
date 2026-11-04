// Drive 后台任务页（P3 尾巴）：`SYNO.SynologyDrive.Tasks/list|delete`（v1）。
//
// 与「文件」模块的 `FileTasksPage` **刻意分开**：那是 File Station 的
// `BackgroundTask`（NAS 目录的复制/压缩/上传任务），这是 **Drive 自己的异步任务**
// （Drive 上传、下载、跨空间转存）。两种任务 id、状态机、清理方式都不同，
// 合成一页只会互相搅浑；所以顶部工具栏的「后台任务」按钮按来源切页
// （NAS 文件 → FileTasksPage，我的 Drive → 这里）。
//
// 官方依据（`SynologyDrive 4.2.0-30058`）：
//   * `webapi/SYNO.SynologyDrive.lib`：`SYNO.SynologyDrive.Tasks` v1 = `list get delete`，
//     `allowUser` 含 `normal.*`（普通用户可用）；
//   * 官方 Drive 前端 `drive/synodrive_common.js`：
//     `list_tasks:{api:"SYNO.SynologyDrive.Tasks",method:"list",version:1}`，
//     遍历 `items` 时读 `status`（`finished`）/`result.action`/`result.names`/
//     `result.total_size`/`progress`/`task_id`，删任务用的是 `{task_id}`。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/theme/app_theme.dart';
import '../../data/dto/drive_task_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../drive/drive_p0_text.dart' show driveP0;
import 'drive_providers.dart';
import 'file_row.dart' show formatFileTime;

class DriveTasksPage extends ConsumerWidget {
  const DriveTasksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final tasks = ref.watch(driveTasksProvider);
    // ★ D67：进过任务页 = 已读（官方 `BackgroundTaskManager.clearUnread()`）——
    //   顶栏角标随即消失；之后再来新任务会重新出现。
    final loaded = tasks.asData?.value;
    if (loaded != null) {
      final ids = loaded.map((r) => r.deleteId).toList(growable: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          ref.read(driveTaskSeenProvider.notifier).markSeen(ids);
        }
      });
    }
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(t.wsTasks),
        actions: [
          IconButton(
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(driveTasksProvider),
          ),
        ],
      ),
      body: tasks.when(
          loading: () => const AppListSkeleton(),
          error: (e, __) => AppErrorView(
            title: t.fileTasksLoadFailed,
            detail: describeFileError(e),
            onRetry: () => ref.invalidate(driveTasksProvider),
          ),
          data: (rows) => rows.isEmpty
              ? AppEmptyState(
                  icon: Icons.sync,
                  title: t.fileNoTasks,
                  message: t.driveTasksEmptyMessage,
                )
              : RefreshIndicator(
                  onRefresh: () async => ref.invalidate(driveTasksProvider),
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xl),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: hud.dim.withValues(alpha: 0.12),
                    ),
                    itemBuilder: (context, i) => _TaskRow(task: rows[i]),
                  ),
                ),
        ),
    );
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task});

  final DriveTaskDto task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final failed = task.failed;
    final icon = failed
        ? Icons.error_outline
        : task.finished
        ? Icons.check_circle_outline
        : Icons.sync;
    final color = failed
        ? theme.colorScheme.error
        : task.finished
        ? theme.colorScheme.primary
        : hud.dim;
    final subtitle = [
      if (task.totalSize > 0) task.humanSize,
      if (task.message.isNotEmpty) task.message,
      if (task.errors.isNotEmpty) task.errors.first,
      if (!task.finished && !failed) '${task.progress.toStringAsFixed(0)}%',
    ].join(' · ');

    // 有 `onTap` 的 ListTile 要找最近的 Material 画水波纹；页面外层是
    // `FieldBackdrop` 的 ColoredBox ⇒ 不套一层透明 Material 会触发调试断言
    // （"ListTile background color or ink splashes may be invisible"）。
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-task-${task.deleteId}'),
        // ★ D53：点一行看**单条任务详情**（`Tasks/get` v1）——列表是快照，
        //   详情用服务端最新状态覆盖（官方 `TaskGetWork` 也是按需拉单条）。
        onTap: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (_) => _TaskDetailSheet(initial: task),
        ),
        leading: Icon(icon, color: color),
        title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
              ),
            if (!task.finished && !failed) ...[
              const SizedBox(height: Gap.xs),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: task.progress <= 0 ? null : task.progress / 100,
                  minHeight: 3,
                ),
              ),
            ],
          ],
        ),
        trailing: IconButton(
          key: Key('drive-task-remove-${task.deleteId}'),
          tooltip: task.finished ? t.driveTaskRemove : t.driveTaskStopAndRemove,
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => confirmDriveTaskRemove(context, ref, task),
        ),
      ),
    );
  }
}

/// ★ D53：移除任务记录前的确认。
///
/// **为什么必须确认**：官方 `ApiSynoDriveTasks` 只有 `list/get/delete` 三个方法
/// （`setAsList/setAsGet/setAsDelete`，无暂停/重试）⇒ `Tasks/delete` **只删记录**，
/// 不会中止服务端还在跑的传输。对"进行中"的任务必须把这句话说清楚，
/// 否则用户会以为按了 X 就停了传输（官方说的是 `delete_task`，UI 文案也是删任务）。
Future<void> confirmDriveTaskRemove(
  BuildContext context,
  WidgetRef ref,
  DriveTaskDto task,
) async {
  final t = context.t;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('drive-task-remove-dialog'),
      title: Text(
        task.finished
            ? driveP0('driveTaskRemoveDoneTitle', '移除这条已完成任务？')
            : driveP0('driveTaskRemoveRunningTitle', '从列表移除这条任务？'),
      ),
      content: Text(
        task.finished
            ? driveP0(
                'driveTaskRemoveDoneBody',
                '只是把记录从任务列表里清掉（Tasks/delete），不影响已经传好的文件。',
              )
            : driveP0(
                'driveTaskRemoveRunningBody',
                '这条任务还在跑。Tasks/delete 只删记录，不会中止服务端正在进行的'
                    '传输 —— 想真正停掉，要在源端处理。',
              ),
      ),
      actions: [
        TextButton(
          key: const Key('drive-task-remove-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          key: const Key('drive-task-remove-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(t.actionOk),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(driveTaskDeleteProvider)(task.deleteId);
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(t.driveTaskDeleteFailed(describeFileError(e)))),
    );
  }
}

/// ★ D53：单条任务详情（`Tasks/get` v1）——先用列表数据渲染，再用服务端最新值覆盖。
class _TaskDetailSheet extends ConsumerWidget {
  const _TaskDetailSheet({required this.initial});

  final DriveTaskDto initial;

  static String _statusLabel(String status, bool failed) {
    if (failed) return driveP0('driveTaskStatusFailed', '失败');
    return switch (status) {
      'finished' => driveP0('driveTaskStatusFinished', '已完成'),
      'in_progress' => driveP0('driveTaskStatusRunning', '进行中'),
      'error' => driveP0('driveTaskStatusFailed', '失败'),
      _ =>
        status.isEmpty
            ? driveP0('driveTaskStatusUnknown', '未知')
            : status, // 官方对未知状态串也照样显示
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final theme = Theme.of(context);
    final async = ref.watch(driveTaskDetailProvider(initial.deleteId));
    final task = async.asData?.value ?? initial;
    final stale = !async.hasValue && async.hasError;

    Widget kv(String label, String value, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ),
          Expanded(
            child: Text(value, key: key, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );

    return SafeArea(
      key: const Key('drive-task-sheet'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (async.isLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: Gap.sm),
            kv(
              driveP0('driveTaskFieldStatus', '状态'),
              _statusLabel(task.status, task.failed),
              key: const Key('drive-task-detail-status'),
            ),
            kv(
              driveP0('driveTaskFieldProgress', '进度'),
              '${task.progress.toStringAsFixed(0)}%',
              key: const Key('drive-task-detail-progress'),
            ),
            kv(
              driveP0('driveTaskFieldSize', '大小'),
              task.humanSize,
              key: const Key('drive-task-detail-size'),
            ),
            if (task.names.isNotEmpty)
              kv(
                driveP0('driveTaskFieldFiles', '文件'),
                task.names.join('\n'),
                key: const Key('drive-task-detail-names'),
              ),
            if (task.message.isNotEmpty)
              kv(driveP0('driveTaskFieldMessage', '说明'), task.message),
            if (task.errors.isNotEmpty)
              kv(
                driveP0('driveTaskFieldErrors', '错误'),
                task.errors.join('\n'),
                key: const Key('drive-task-detail-errors'),
              ),
            if (task.createdTime != null)
              kv(
                driveP0('driveTaskFieldCreated', '创建'),
                formatFileTime(
                  task.createdTime!.millisecondsSinceEpoch ~/ 1000,
                  t: t,
                ),
              ),
            if (task.finishedTime != null)
              kv(
                driveP0('driveTaskFieldFinished', '完成'),
                formatFileTime(
                  task.finishedTime!.millisecondsSinceEpoch ~/ 1000,
                  t: t,
                ),
              ),
            kv(driveP0('driveTaskFieldId', '任务 ID'), task.deleteId),
            if (stale)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(
                  driveP0('driveTaskDetailStale', '拿不到最新状态，上面是列表里的快照'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                TextButton.icon(
                  key: const Key('drive-task-detail-refresh'),
                  onPressed: () =>
                      ref.invalidate(driveTaskDetailProvider(initial.deleteId)),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(t.photoRefresh),
                ),
                const Spacer(),
                FilledButton.tonalIcon( style: InlineButtonStyle.filled,
                  key: const Key('drive-task-detail-remove'),
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await confirmDriveTaskRemove(context, ref, task);
                    if (navigator.mounted) navigator.pop();
                  },
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(t.driveTaskRemove),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
