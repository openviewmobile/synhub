// Drive 通知页（C1）：列表 + 清空全部。
//
// 协议事实（原文见 [DriveApi] 与文档实施记录）：
//   * `Notifications/list` v1，参数 `{limit}`（官方轮询用 100），回包
//     `{items:[{notification_id,type,time,content,sender,recipient,extra_info}]}`
//     （`drive/synodrive_common.js:331025` + `getStore` 的 fields）；
//   * `Notifications/delete` v1，官方"全部清除"传**空参数**
//     （`drive/synodrive_common.js:329203`）。
//
// ⚠️ `create`（`{content,type}`）在官方只由上传任务内部调用
// （`synodrive_common.js:635884`），本仓库没有 Drive 上传链路，故 UI 不提供
// "写通知"；数据层方法 + 用例仍在（协议已实现）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_notification_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../files/drive_providers.dart';
import '../files/file_row.dart' show formatFileTime;
import 'drive_c1_text.dart';

class DriveNotificationsPage extends ConsumerWidget {
  const DriveNotificationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveNotificationsProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-notifications-page'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        driveC1(DriveC1TextKeys.notifications, '通知'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: t.photoRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () =>
                          ref.invalidate(driveNotificationsProvider),
                    ),
                    IconButton(
                      key: const Key('drive-notifications-clear'),
                      tooltip: driveC1(
                        DriveC1TextKeys.clearNotifications,
                        '清空通知',
                      ),
                      icon: const Icon(Icons.clear_all),
                      onPressed: () => _confirmClear(context, ref),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: t.driveListOpenFailed,
                    message: describeFileError(e),
                    actionLabel: t.photoRetry,
                    onAction: () => ref.invalidate(driveNotificationsProvider),
                  ),
                  data: (items) => items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.notifications_none,
                          title: driveC1(
                            DriveC1TextKeys.notificationsEmpty,
                            '没有通知',
                          ),
                          message: driveC1(
                            DriveC1TextKeys.notificationsEntry,
                            'Drive 的上传/同步事件通知',
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: items.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) =>
                              _NotificationRow(item: items[i]),
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          driveC1(DriveC1TextKeys.clearNotificationsConfirm, '清空全部通知？'),
        ),
        actions: [
          TextButton(
            key: const Key('drive-notifications-clear-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('drive-notifications-clear-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(driveC1(DriveC1TextKeys.clearNotifications, '清空通知')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.clearNotifications();
      ref.invalidate(driveNotificationsProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(driveC1(DriveC1TextKeys.notificationsCleared, '已清空通知')),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(DriveC1TextKeys.actionFailed, '操作失败：{error}', {
              'error': describeFileError(e),
            }),
          ),
        ),
      );
    }
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.item});

  final DriveNotificationDto item;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-notification-${item.notificationId}'),
        leading: Icon(Icons.notifications_none, color: hud.dim),
        title: Text(
          _contentLabel(item),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          item.time > 0 ? formatFileTime(item.time, t: t) : '',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
      ),
    );
  }

  /// 通知正文。
  ///
  /// 三种官方形态，逐一对齐：
  /// * `drive#upload_task` / `drive#background_task`：`content` 是
  ///   `{action, names, errors, success}`（`synodrive_common.js:635808`）
  ///   ⇒「上传 · a.txt」；
  /// * **`drive#comment` / `drive#comment_reply` / `drive#mention`**：
  ///   官方 `NotificationVo$ContentVo.comment` 才是正文
  ///   ⇒「评论 · a.docx · 这句话得改改」——**官方 Drive Android 没有评论
  ///   编辑器，评论只以这种通知形式到达客户端**，所以这里必须把它显示出来，
  ///   否则用户只能看到裸的 `drive#comment` 类型串；
  /// * `drive#share_with_me` / `drive#request(_unlock|_office_template)` /
  ///   `drive#shared_label*`：只有 `content.name`（文件名）
  ///   ⇒「分享给我 · b.pdf」。
  static String _contentLabel(DriveNotificationDto item) {
    final content = item.content;
    if (content is Map) {
      final names = item.names;
      final file = item.fileName.isNotEmpty
          ? item.fileName
          : (names.isEmpty ? '' : names.first);
      final comment = item.commentText;
      // 评论/回复/@提到：正文是评论文本，前面补文件名（官方也是这么摆的）
      if (comment.isNotEmpty) {
        // 官方标题=类型标签+文件名，正文另有评论文本；我们一行显示就三者都带上
        return [
          item.typeLabel,
          if (file.isNotEmpty) file,
          comment,
        ].join(' · ');
      }
      final action = '${content['action'] ?? ''}';
      // 上传/后台任务：有 action（或多项）时"动作 · 文件名"
      if (action.isNotEmpty || names.length > 1) {
        return [
          if (action.isNotEmpty) action,
          if (file.isNotEmpty) file,
          if (names.length > 1) '+${names.length - 1}',
        ].join(' · ');
      }
      // 只有文件名的那种（分享给我 / 请求解锁…）：带上类型标签，别只显示文件名
      if (file.isNotEmpty) return '${item.typeLabel} · $file';
    }
    if (content is String && content.isNotEmpty) return content;
    return item.typeLabel;
  }
}
