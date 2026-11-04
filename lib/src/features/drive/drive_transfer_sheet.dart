// Drive「打包 / 分享」面板（D31 压缩·打包下载、D34 发送副本、D35 压缩并发送）。
//
// 官方对照（反编译 `Android-SynologyDrive.3.9.0-1113.ww.apk`）：
//   * `FileAction.Download` —— 下载（多选时 `FileMultipleActionSheet.java:45`
//     与 `SendACopy` / `ArchiveAndSend` 并列）；
//   * `FileAction.SendACopy`（`FileActionSheet.java:84,88`；
//     `R.string.file_action_send_a_copy`）—— 下载字节后交给系统
//     `ACTION_SEND`（`drive-parity-audit.md:291` 的"系统分享面板"）；
//   * `FileAction.ArchiveAndSend`（`FileMultipleActionSheet.java:45`；
//     `R.string.file_action_archive_and_send`）—— 打包成 zip + 分享面板；
//   * 打包本身：`ArchiveHelper.archiveWithObservable` → `FileArchiveWork` →
//     `ApiSynoDriveFiles.setAsArchiveFiles`（`Files/download` v≤7，参数
//     `files` / `force_download` / `archive_name` / `decrypt`），本地落文件
//     名逐字是 `fileName + ".zip"`（`ArchiveHelper.prepareTargetFile`）。
//
// 本面板是**被 `drive_info_sheet.dart` 调用**的（那里是每条目行菜单已经能到达
// 的面板）；`drive_browse_view.dart` 的多选栏属并行批次，本批禁碰，已在报告里
// 留下"一行接线"的说明。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import 'drive_g4_providers.dart';
import 'drive_g4_text.dart';

/// 打开「打包 / 分享」面板。
///
/// [entries] = 选中的条目（1 个或多个）。面板按官方门禁裁剪项：
///   * 打包下载：非空即可（官方 `FileAction.Download` 单选/多选都在）；
///   * 压缩并发送：**多选才出**（`FileActionUtils.java:796`
///     `isEnabledArchiveAndSend = isMultiple && …`）；
///   * 发送副本：**单选才出**（原生 `share` 桥一次只发一个文件，
///     多选时要发 `ACTION_SEND_MULTIPLE`，本仓库桥没有该能力 → 不假装支持）。
Future<void> showDriveTransferSheet(
  BuildContext context,
  WidgetRef ref,
  List<DriveEntryDto> entries,
) {
  if (entries.isEmpty) return Future<void>.value();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _DriveTransferSheet(entries: entries),
  );
}

/// 打包用的基名（官方传的是**不带扩展名**的 `fileName`，落盘时再补 `.zip`）。
String driveArchiveNameFor(List<DriveEntryDto> entries) {
  if (entries.isEmpty) return 'Drive';
  if (entries.length == 1) {
    final e = entries.single;
    if (e.isDir) return e.name;
    final dot = e.name.lastIndexOf('.');
    return dot > 0 ? e.name.substring(0, dot) : e.name;
  }
  final parts = entries.first.displayPath
      .split('/')
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length >= 2) return parts[parts.length - 2];
  return 'Drive';
}

class _DriveTransferSheet extends ConsumerStatefulWidget {
  const _DriveTransferSheet({required this.entries});

  final List<DriveEntryDto> entries;

  @override
  ConsumerState<_DriveTransferSheet> createState() =>
      _DriveTransferSheetState();
}

class _DriveTransferSheetState extends ConsumerState<_DriveTransferSheet> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final single = widget.entries.length == 1;
    return SafeArea(
      key: const Key('drive-transfer-sheet'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xs),
            child: Text(
              driveG4(DriveG4TextKeys.archiveTitle, '打包与分享'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          DesignRowTile(
            key: const Key('drive-transfer-archive-download'),
            leading: const Icon(Icons.archive_outlined),
            title: Text(driveG4(DriveG4TextKeys.archiveDownload, '打包下载')),
            subtitle: Text(
              driveG4(
                DriveG4TextKeys.archiveNameLabel,
                '在服务端打成一个 zip，再存进系统「下载」目录',
              ),
            ),
            enabled: !_busy,
            onTap: () => _run(_Mode.save),
          ),
          if (!single)
            DesignRowTile(
              key: const Key('drive-transfer-archive-share'),
              leading: const Icon(Icons.ios_share),
              title: Text(
                driveG4(DriveG4TextKeys.archiveShare, '压缩并发送'),
              ),
              enabled: !_busy,
              onTap: () => _run(_Mode.shareArchive),
            ),
          if (single)
            DesignRowTile(
              key: const Key('drive-transfer-send-copy'),
              leading: const Icon(Icons.send_outlined),
              title: Text(driveG4(DriveG4TextKeys.sendCopy, '发送副本')),
              subtitle: Text(
                driveG4(
                  DriveG4TextKeys.archiveNameLabel,
                  '下载原文件后交给系统分享面板',
                ),
              ),
              enabled: !_busy,
              onTap: () => _run(_Mode.sendCopy),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(t.actionCancel),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _run(_Mode mode) async {
    final actions = ref.read(driveTransferActionsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (actions == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveG4(DriveG4TextKeys.archiveSaveFailed, '操作失败：未连接'),
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final name = driveArchiveNameFor(widget.entries);
    final fileIds = [for (final e in widget.entries) e.fileId];
    DriveTransferOutcome outcome;
    switch (mode) {
      case _Mode.save:
        outcome = await actions.saveArchive(
          fileIds: fileIds,
          archiveName: name,
        );
      case _Mode.shareArchive:
        outcome = await actions.shareArchive(
          fileIds: fileIds,
          archiveName: name,
        );
      case _Mode.sendCopy:
        outcome = await actions.sendCopy(entry: widget.entries.single);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    switch (outcome.status) {
      case DriveTransferStatus.done:
        navigator.maybePop();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              mode == _Mode.save
                  ? driveG4Fill(
                      DriveG4TextKeys.archiveSaved,
                      '已保存 {name}',
                      {'name': outcome.detail},
                    )
                  : driveG4Fill(
                      DriveG4TextKeys.sendCopySaved,
                      '已发送 {name}',
                      {'name': outcome.detail},
                    ),
            ),
          ),
        );
      case DriveTransferStatus.noHandler:
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              driveG4(
                DriveG4TextKeys.archiveNoHandler,
                '系统没有可接收该分享的应用',
              ),
            ),
          ),
        );
      case DriveTransferStatus.failed:
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              driveG4Fill(
                DriveG4TextKeys.archiveSaveFailed,
                '操作失败：{error}',
                {'error': describeFileError(outcome.detail)},
              ),
            ),
          ),
        );
    }
  }
}

enum _Mode { save, shareArchive, sendCopy }
