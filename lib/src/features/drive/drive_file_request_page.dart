// Drive「请求文件」（File Request）页（C1）：列表 + 关闭 / 重开 / 删除。
//
// 协议事实（原文见 [DriveApi] 与文档实施记录）：
//   * `FileRequest/list` v1，参数 `offset`/`limit`/可选 `status`
//     （官方 ViewStore.FileRequest）；
//   * `FileRequest/update` v1：`title/identifier/description/protect_password/
//     due_date/has_due_date_hour` + `sharing_link` + `path`
//     （`id:<folder_id>` 或 `link:<permanent_link>`），关闭时补
//     `file_request_status:"inactive"`（`drive/drive_bundle.js:1640082`、
//     `drive/synodrive.js:114380`）；
//   * `FileRequest/delete` v1：`{sharing_link}`（`synodrive_common.js:578415`）。
//
// ⚠️ 新建入口在**文件夹行菜单**（`drive_browse_view.dart`，官方也是从文件夹
// 发起），本页只管已发出的链接。`verify` 无参数原文 → 未实现（待取证）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_file_request_dto.dart';
import '../files/drive_providers.dart';
import '../files/file_row.dart' show formatFileTime;
import 'drive_c1_text.dart';
import 'drive_g6_text.dart';
import 'drive_gaps_text.dart';

class DriveFileRequestPage extends ConsumerWidget {
  const DriveFileRequestPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveFileRequestsProvider(''));
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-file-request-page'),
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
                        driveC1(DriveC1TextKeys.fileRequests, '请求文件'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: t.photoRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () =>
                          ref.invalidate(driveFileRequestsProvider('')),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => AppEmptyState(
                    key: const Key('drive-file-request-error'),
                    icon: Icons.error_outline,
                    title: t.driveListOpenFailed,
                    // 1076（服务端关掉 file request）→ 人话；其余异常也走
                    // 「绝不透协议/Dart 原文」的出口（见 drive_g6_text.dart）
                    message: describeDriveG6Error(e),
                    actionLabel: t.photoRetry,
                    onAction: () =>
                        ref.invalidate(driveFileRequestsProvider('')),
                  ),
                  data: (items) => items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.file_download_outlined,
                          title: driveC1(
                            DriveC1TextKeys.fileRequestsEmpty,
                            '还没有请求文件链接',
                          ),
                          message: driveC1(
                            DriveC1TextKeys.fileRequestsEntry,
                            '管理你发出的"请求文件"链接：查看、关闭、重开、删除',
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
                              _FileRequestRow(item: items[i]),
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _FileRequestRow extends ConsumerWidget {
  const _FileRequestRow({required this.item});

  final DriveFileRequestDto item;

  /// 官方 edit 用的 `path`：优先 `link:<permanent_link>`，退回 `id:<file_id>`
  String get _pathForUpdate => item.permanentLink.isNotEmpty
      ? 'link:${item.permanentLink}'
      : 'id:${item.fileId}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final theme = Theme.of(context);
    // D43：上传者目录命名策略（官方 identifier ∈ {create_folder, add_prefix}）。
    // 只做"有则显示"：服务端没回（空串）就不显示这一行。
    final identifierLabel = switch (item.identifier) {
      'create_folder' => driveGap(
        DriveGapTextKeys.requestIdentifierCreateFolder,
        '为每个上传者建一个文件夹',
      ),
      'add_prefix' => driveGap(
        DriveGapTextKeys.requestIdentifierAddPrefix,
        '在文件名前加上传者名字',
      ),
      _ => '',
    };
    final subtitle = [
      if (item.destinationFolder.isNotEmpty) item.destinationFolder,
      if (item.createdTime > 0) formatFileTime(item.createdTime, t: t),
      item.fileRequestStatus,
      if (identifierLabel.isNotEmpty) identifierLabel,
      if (item.isExpired) t.driveDeleted,
    ].where((e) => e.isNotEmpty).join(' · ');
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-file-request-${item.sharingLink}'),
        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: Key('drive-file-request-toggle-${item.sharingLink}'),
              tooltip: item.isActive
                  ? driveC1(DriveC1TextKeys.closeRequest, '关闭')
                  : driveC1(DriveC1TextKeys.reopenRequest, '重开'),
              icon: Icon(
                item.isActive
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                size: 20,
              ),
              onPressed: () => _toggle(context, ref),
            ),
            IconButton(
              key: Key('drive-file-request-delete-${item.sharingLink}'),
              tooltip: t.dtoActionDelete,
              icon: Icon(Icons.delete_outline, size: 20, color: hud.dim),
              onPressed: () => _delete(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.updateFileRequest(
        sharingLink: item.sharingLink,
        path: _pathForUpdate,
        title: item.title,
        description: item.description,
        identifier: item.identifier,
        dueDate: item.dueDate,
        hasDueDateHour: item.hasDueDateHour,
        fileRequestStatus: item.isActive ? 'inactive' : 'active',
      );
      ref.invalidate(driveFileRequestsProvider(''));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            item.isActive
                ? driveC1(DriveC1TextKeys.requestClosed, '已关闭')
                : driveC1(DriveC1TextKeys.requestReopened, '已重开'),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(DriveC1TextKeys.actionFailed, '操作失败：{error}', {
              'error': describeDriveG6Error(e),
            }),
          ),
        ),
      );
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          driveC1(DriveC1TextKeys.requestDeleteConfirm, '删除这个请求文件链接？'),
        ),
        content: Text(
          driveC1Fill(DriveC1TextKeys.requestDeleteBody, '「{name}」的链接会失效。', {
            'name': item.title,
          }),
        ),
        actions: [
          TextButton(
            key: const Key('drive-file-request-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('drive-file-request-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.deleteFileRequest(sharingLink: item.sharingLink);
      ref.invalidate(driveFileRequestsProvider(''));
      messenger.showSnackBar(
        SnackBar(content: Text(driveC1(DriveC1TextKeys.requestDeleted, '已删除'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(DriveC1TextKeys.actionFailed, '操作失败：{error}', {
              'error': describeDriveG6Error(e),
            }),
          ),
        ),
      );
    }
  }
}
