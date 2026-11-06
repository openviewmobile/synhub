// 相册「后台任务」页（G6）：当前用户的相册后台任务列表。
//
// ## 协议与证据
//
// * `SYNO.Foto.BackgroundTask.Info:list_user_task` **v1**，**无必填参数**；
//   方法表与条目字段见 `data/dto/foto_g6_dto.dart` 文件头（含官方 Web 前端
//   的 `listUserTask()` 映射原文）。
// * 版本协商交给 `FotoG6Api._negotiate`（与 `SYNO.API.Info` 的区间取交集），
//   **不硬编码 maxVersion**。
// * 真机只读实测：`{"list": []}`（`docs/g6-api-probe-facts.md:38`）。
//
// ## ⚠️ 空态是本页在真机上的**唯一**表现
//
// 本账号没有任何后台任务 ⇒ 必须画人话空态，绝不是白屏。
// 用例见 `test/photo_g6_wiring_test.dart` 的「空响应 → 人话空态」。
//
// ## 纪律
//
// * `id`（任务 id）是内部 id：只进 Key，**不上屏**；
// * `operation` / `status` 是枚举串：只画认识的值，认不出的**不画**
//   （`operationLabelKey` / `statusLabelKey` 返回 null → UI 省略）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/foto_g6_dto.dart';
import '../files/file_row.dart' show formatFileTime;
import 'photo_c2_sections.dart';
import 'photo_g6_providers.dart';
import 'photo_g6_text.dart';
import 'photo_widgets.dart';

class PhotoBackgroundTasksPage extends ConsumerWidget {
  const PhotoBackgroundTasksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(photoBackgroundTasksProvider);
    return PhotoC2Scaffold(
      pageKey: const Key('photo-g6-tasks-page'),
      title: photoG6(PhotoG6TextKeys.tasksTitle, '后台任务'),
      body: PhotoAsync<List<FotoBackgroundTaskDto>>(
        value: RiverpodAsync(async),
        emptyIcon: Icons.pending_actions_outlined,
        emptyTitle: photoG6(PhotoG6TextKeys.tasksEmptyTitle, '当前没有正在进行的后台任务'),
        emptyMessage: photoG6(
          PhotoG6TextKeys.tasksEmptyBody,
          '相册里发起的复制 / 移动等操作会在这里显示进度。',
        ),
        isEmpty: (tasks) => tasks.isEmpty,
        onRetry: () => ref.invalidate(photoBackgroundTasksProvider),
        builder: (tasks) => ListView.separated(
          key: const Key('photo-g6-tasks-list'),
          padding: const EdgeInsets.all(Gap.md),
          itemCount: tasks.length,
          separatorBuilder: (_, _) => const SizedBox(height: Gap.xs),
          itemBuilder: (context, i) => _TaskRow(task: tasks[i]),
        ),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});

  final FotoBackgroundTaskDto task;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final meta = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: hud.dim);
    // 枚举串只画认识的值；认不出 → 省略（**绝不透服务端原文**）
    final opKey = task.operationLabelKey;
    final operation = switch (opKey) {
      'photoG6TaskOperationCopy' => photoG6(
        PhotoG6TextKeys.taskOperationCopy,
        '复制',
      ),
      'photoG6TaskOperationMove' => photoG6(
        PhotoG6TextKeys.taskOperationMove,
        '移动',
      ),
      _ => '',
    };
    final statusKey = task.statusLabelKey;
    final status = switch (statusKey) {
      'photoG6TaskStatusWaiting' => photoG6(
        PhotoG6TextKeys.taskStatusWaiting,
        '排队中',
      ),
      'photoG6TaskStatusProcessing' => photoG6(
        PhotoG6TextKeys.taskStatusProcessing,
        '进行中',
      ),
      'photoG6TaskStatusAborting' => photoG6(
        PhotoG6TextKeys.taskStatusAborting,
        '正在中止',
      ),
      'photoG6TaskStatusDone' => photoG6(PhotoG6TextKeys.taskStatusDone, '已完成'),
      _ => '',
    };
    final title = operation.isEmpty
        ? photoG6(PhotoG6TextKeys.taskUnknownType, '相册任务')
        : operation;
    final progress = photoG6Fill(
      PhotoG6TextKeys.taskProgress,
      '{done}/{total}',
      {'done': '${task.completion}', 'total': '${task.total}'},
    );
    final created = formatFileTime(task.createTime, t: t);
    final subtitle = [
      if (status.isNotEmpty) status,
      progress,
      if (task.hasErrors)
        photoG6Fill(PhotoG6TextKeys.taskErrors, '{count} 项失败', {
          'count': '${task.error}',
        }),
      if (created.isNotEmpty) created,
    ].join(' · ');
    return DesignRowTile(
      // ⚠️ 内部任务 id 只进 Key，**不上屏**
      key: Key('photo-g6-task-${task.id}'),
      leading: Icon(
        task.isPending ? Icons.sync : Icons.check_circle_outline,
        color: hud.dim,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle, style: meta),
          if (task.total > 0 && task.isPending) ...[
            const SizedBox(height: Gap.xxs),
            LinearProgressIndicator(value: task.ratio),
          ],
        ],
      ),
    );
  }
}
