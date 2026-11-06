// 进入一个"非个人空间"的 Drive 目录并浏览（P0-3 团队文件夹 / P0-6 共享给我）。
//
// 官方行为原文：
//   * **没有** `TeamFolders/get_details` 这种"进入"接口（SPK 全量检索零命中；
//     `/tmp/spk/out/SynologyDrive.apis.txt:181-182` 只有 `list` / `list_members`）。
//   * 官方 Web 的"进入团队文件夹"= **切到 Files store**：
//     `onPathChange` 里非根路径一律用 `ViewStore.Node`
//     （`synodrive_common.js:18`），而 `ViewStore.Node.getLoadParam` 发的是
//     `SYNO.SynologyDrive.Files:list` + `path: getPathId(<节点 id>)`。
//   * APK 侧同款：`TeamFolderGetDetailsWork extends FileGetWork` →
//     `SYNO.SynologyDrive.Files:get`，`path = id:<fileId>`
//     （`ApiSynoDriveFiles.java:226-237`）；进目录后用 `Files/list` 列子项
//     （`setAsListDrive`，`:640-660`）。
//
// ⇒ 所以这里**不需要任何新 API**：`path = id:<file_id>` 直接复用 [driveListProvider]。
// 这也是"团队文件夹只能看不能进"（P0-3）的修法：给目录行一个可点的目标页。
//
// 降级：`105`/`160`（无权限）与 `102`/`103`（服务端没有该方法）只在**本页内**
// 说明原因，不隐藏 Drive 模块本身（见 `drive_p0_text.dart` 的口径）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../files/drive_browse_view.dart' show driveEntryAsFile;
import '../files/drive_providers.dart';
import '../files/file_row.dart' show formatFileTime;
import '../files/file_thumb.dart' show FileIconTile;
import 'drive_convert_office_sheet.dart';
import 'drive_p0_text.dart';
import 'drive_scan_page.dart';
import 'drive_sync_tasks_page.dart';
import 'drive_open_entry.dart';
import 'drive_wave2_providers.dart';
import 'drive_wave2_text.dart';

/// 一个可下钻的 Drive 目录页（团队文件夹 / 共享节点 / 任意 file_id 目录）
class DriveFolderPage extends ConsumerStatefulWidget {
  const DriveFolderPage({
    super.key,
    required this.rootFileId,
    required this.title,
    this.rootPathId,
  });

  /// 根目录的 `file_id`（团队文件夹 / 共享给我的那个节点）
  final String rootFileId;

  /// 标题（第一层用调用方给的名字）
  final String title;

  /// 可选的根 path id（默认 `id:<rootFileId>`）
  final String? rootPathId;

  @override
  ConsumerState<DriveFolderPage> createState() => _DriveFolderPageState();
}

class _DriveFolderPageState extends ConsumerState<DriveFolderPage> {
  /// 当前栈（第一项固定是根）
  late final List<({String id, String name})> _stack = [
    (id: widget.rootFileId, name: widget.title),
  ];

  String get _currentPathId => widget.rootPathId != null && _stack.length == 1
      ? widget.rootPathId!
      : 'id:${_stack.last.id}';

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveListProvider(_currentPathId));
    return Scaffold(
      key: const Key('drive-folder-page'),
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(
          _stack.last.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          tooltip: t.calBack,
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_stack.length > 1) {
              setState(() => _stack.removeLast());
            } else {
              Navigator.of(context).maybePop();
            }
          },
        ),
        // ★ D37 扫描件：官方从 `ShowFolderActivity` 入 `DocumentScannerActivity`
        //（manifest 级证据），输出 PDF 后上传到当前目录。
        actions: [
          // ★ D65 同步任务：官方 `ShowSyncTaskActivity`（本地目录同步引擎）。
          // 从当前目录进来时把那一条路径预填成远端根。
          IconButton(
            key: const Key('drive-folder-sync'),
            tooltip: context.t.driveSyncTasksTooltip,
            icon: const Icon(Icons.sync_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DriveSyncTasksPage(
                  // 目录栈里只有 id/name（没有完整 Drive 路径）⇒ 不预填，
                  // 对话框默认给 `/mydrive`，用户自己改。
                  presetRemoteRoot: null,
                ),
              ),
            ),
          ),
          IconButton(
            key: const Key('drive-folder-scan'),
            tooltip: t.driveScanTitle,
            icon: const Icon(Icons.document_scanner_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DriveScanPage(folderId: _stack.last.id),
              ),
            ),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) {
          final gate = driveEntryGate(e);
          final gated = gate != DriveEntryGate.available;
          return AppEmptyState(
            icon: gated ? Icons.block_outlined : Icons.error_outline,
            title: driveP0(DriveP0TextKeys.folderOpenFailed, '打不开这个文件夹'),
            message: gated ? driveGateMessage(gate) : describeFileError(e),
            actionLabel: t.photoRetry,
            onAction: () => ref.invalidate(driveListProvider(_currentPathId)),
          );
        },
        data: (data) => data.items.isEmpty
            ? AppEmptyState(
                icon: Icons.folder_open,
                title: driveP0(DriveP0TextKeys.folderEmptyTitle, '这个文件夹是空的'),
                message: driveP0(
                  DriveP0TextKeys.folderEmptyMessage,
                  '这里还没有任何文件或子文件夹',
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: Gap.xl),
                itemCount: data.items.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: hud.dim.withValues(alpha: 0.12)),
                itemBuilder: (context, i) => _row(data.items[i]),
              ),
      ),
    );
  }

  Widget _row(DriveEntryDto entry) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-folder-row-${entry.fileId}'),
        leading: SizedBox(
          width: 40,
          height: 40,
          child: FileIconTile(
            entry: driveEntryAsFile(entry),
            size: 40,
            iconSize: 20,
          ),
        ),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (entry.isDir) t.photoFolder else driveHumanSize(entry.size),
            if (entry.modifiedTime > 0)
              formatFileTime(entry.modifiedTime, t: t),
          ].join(' · '),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
        trailing: entry.isDir
            ? const Icon(Icons.chevron_right, size: 18)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // wave2：转成 Office 格式（`Files:convert_office` v1）。
                  // 能力表缺 `Files` → 该菜单项不出现（Drive 自身照常）。
                  if (driveFilesCapabilityAvailable(ref))
                    PopupMenuButton<String>(
                      key: Key('drive-folder-menu-${entry.fileId}'),
                      icon: const Icon(Icons.more_vert, size: 18),
                      tooltip: driveWave2(
                        DriveWave2TextKeys.convertEntry,
                        '转成 Office 格式',
                      ),
                      onSelected: (value) {
                        if (value == 'convert_office') {
                          showDriveConvertOfficeSheet(context, ref, entry);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem<String>(
                          key: const Key('drive-folder-convert-office'),
                          value: 'convert_office',
                          child: Text(
                            driveWave2(
                              DriveWave2TextKeys.convertEntry,
                              '转成 Office 格式',
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
        onTap: entry.isDir
            ? () => setState(
                () => _stack.add((id: entry.fileId, name: entry.name)),
              )
            : () => driveOpenEntry(context, ref, entry),
      ),
    );
  }
}
