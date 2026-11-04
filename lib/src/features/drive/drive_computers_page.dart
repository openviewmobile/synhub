// Drive「计算机」页（D21）：列出正在用 Drive 客户端同步的电脑 / 设备。
//
// 协议：`SYNO.SynologyDrive.Files / list_backup_tasks` **v3**
// （版本/分页/条目形状与真机证据见 [DriveApi.listBackupTasks] 的注释）。
//
// 入口：`drive_extras_page.dart` 的「计算机」项（**不是** `drive_more_page.dart`
// ——那个文件属并行批次，本批禁碰；`DriveExtrasPage` 本来就是"操作型入口"的
// 汇集处，语义相符）。
//
// 能力门控：按 `SYNO.SynologyDrive.Files` 能力位（Drive 的必需 API）——
// 缺失时入口直接不出现；本页只负责错误态。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../files/file_row.dart' show formatFileTime;
import 'drive_g4_providers.dart';
import 'drive_g4_text.dart';

class DriveComputersPage extends ConsumerWidget {
  const DriveComputersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveComputersProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-computers-page'),
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
                        driveG4(DriveG4TextKeys.computersTitle, '计算机'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const Key('drive-computers-refresh'),
                      tooltip: t.photoRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () => ref.invalidate(driveComputersProvider),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Text(
                  driveG4(
                    DriveG4TextKeys.computersEntrySubtitle,
                    '正在用 Drive 桌面客户端同步到这台 NAS 的电脑 / 设备',
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, __) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: driveG4(
                      DriveG4TextKeys.computersLoadFailed,
                      '暂时取不到计算机列表',
                    ),
                    message: describeFileError(e),
                    actionLabel: t.photoRetry,
                    onAction: () => ref.invalidate(driveComputersProvider),
                  ),
                  data: (page) {
                    if (page.items.isEmpty) {
                      return AppEmptyState(
                        key: const Key('drive-computers-empty'),
                        icon: Icons.computer_outlined,
                        title: driveG4(
                          DriveG4TextKeys.computersEmpty,
                          '还没有计算机在同步',
                        ),
                        message: driveG4(
                          DriveG4TextKeys.computersEmptyBody,
                          '在电脑上安装 Synology Drive Client 并连接到这台 NAS 后，'
                              '这里会列出该设备。',
                        ),
                      );
                    }
                    return ListView.separated(
                      key: const Key('drive-computers-list'),
                      padding: const EdgeInsets.all(Gap.md),
                      itemCount: page.items.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: Gap.xs),
                      itemBuilder: (context, i) =>
                          _ComputerRow(entry: page.items[i]),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _ComputerRow extends StatelessWidget {
  const _ComputerRow({required this.entry});

  final DriveEntryDto entry;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final meta = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: hud.dim);
    return DesignRowTile(
      key: Key('drive-computer-${entry.fileId}'),
      leading: const Icon(Icons.computer_outlined),
      title: Text(entry.name),
      subtitle: Text(
        [
          if (entry.owner.isNotEmpty) entry.owner,
          if (entry.modifiedTime > 0)
            formatFileTime(entry.modifiedTime, t: t),
        ].join(' · '),
        style: meta,
      ),
      trailing: entry.isDir ? const Icon(Icons.folder_outlined) : null,
    );
  }
}
