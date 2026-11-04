// 文件详情 / 属性（P0-10）。
//
// 官方原文：
//   * 请求 = `SYNO.SynologyDrive.Files:get`，**只带 `path`**
//     （官方 Web `getNode` 白名单 `"path"`，`synodrive_common.js:20`；
//     描述符 `get_file:{api:"SYNO.SynologyDrive.Files",method:"get",version:3}`
//     `:18`）。APK 侧 `FileGetWork` → `setAsGet`（`ApiSynoDriveFiles.java:226-237`
//     用 `path=id:<file_id>` + `case_sensitive=false`）。
//   * 展示字段 = 官方 `res/layout/file_info_sheet.xml`（文件图标、名称、
//     **创建时间 / 修改时间 / 拥有者 / 大小 / 位置 / 标签**），中文串表在
//     `res/values-zh-rCN/strings.xml:781-791` 与 `:994`（`info_title` = "信息"）。
//
// 本页**不新造字段**：`DriveEntryDto` 已经把上述字段都解析好了（`Files/get`
// 和 `Files/list` 同一套 entries 形状），打开时再 `get` 一次只为拿**最新**值；
// 取不到就回落列表里那份（fail-soft，不弹错误页 —— 官方也是先渲染再用回包补）。
//
// 额外补的两块（都在既有 DTO 里，属"权限/状态"而非新字段）：共享状态、锁定人。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../files/drive_providers.dart';
import '../files/file_row.dart' show formatFileTime;
import 'drive_convert_office_sheet.dart';
import 'drive_g4_text.dart';
import 'drive_p0_text.dart';
import 'drive_transfer_sheet.dart';
import 'drive_wave2_providers.dart';
import 'drive_wave2_text.dart';

/// 打开"信息"底部面板
Future<void> showDriveInfoSheet(
  BuildContext context,
  WidgetRef ref,
  DriveEntryDto entry,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => DriveInfoSheet(entry: entry),
);

class DriveInfoSheet extends ConsumerWidget {
  const DriveInfoSheet({super.key, required this.entry});

  final DriveEntryDto entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    // `Files/get` 拿最新值；失败/加载中都用列表里那份（fail-soft）
    final fresh = ref.watch(driveDetailsProvider(entry.fileId));
    final e = fresh.value ?? entry;
    // 目录条目数（`Files:count_files` v11）：只有"目录 + 有展示路径 + 能力位在
    // + 服务器 v11"时才发请求；不支持就不显示这一行（不是失败）。
    final canCount =
        e.isDir &&
        e.displayPath.isNotEmpty &&
        driveFilesCapabilityAvailable(ref) &&
        (ref.watch(driveApiProvider)?.supportsFilesV11 ?? false);
    final folderCount = canCount
        ? ref.watch(driveFolderCountProvider(e.displayPath))
        : null;
    final rows = <(String, String)>[
      (driveP0(DriveP0TextKeys.infoType, '文件类型'), _typeLabel(e)),
      if (e.displayPath.isNotEmpty)
        (driveP0(DriveP0TextKeys.infoLocation, '位置'), e.displayPath),
      if (e.isDir)
        (driveP0(DriveP0TextKeys.infoSize, '大小'), t.photoFolder)
      else
        (driveP0(DriveP0TextKeys.infoSize, '大小'), driveHumanSize(e.size)),
      // 目录条目数（`Files:count_files` v11）—— **只显示这一个目录的数字**，
      // 绝不把 `{path: count}` 原始映射丢上屏。失败明确显示"暂时取不到"。
      if (folderCount != null)
        (
          driveWave2(DriveWave2TextKeys.folderItemCount, '包含条目'),
          switch (folderCount) {
            AsyncError<int?>() => driveWave2(
              DriveWave2TextKeys.folderItemCountUnavailable,
              '暂时取不到',
            ),
            AsyncData<int?>(:final value) when value != null => driveWave2Fill(
              DriveWave2TextKeys.folderItemCountValue,
              '{count} 项',
              {'count': '$value'},
            ),
            _ => '…',
          },
        ),
      if (e.createdTime > 0)
        (
          driveP0(DriveP0TextKeys.infoCreated, '创建时间'),
          formatFileTime(e.createdTime, t: t),
        ),
      if (e.modifiedTime > 0)
        (
          driveP0(DriveP0TextKeys.infoModified, '修改时间'),
          formatFileTime(e.modifiedTime, t: t),
        ),
      if (e.owner.isNotEmpty)
        (driveP0(DriveP0TextKeys.infoOwner, '拥有者'), e.owner),
      if (e.labels.isNotEmpty)
        (
          driveP0(DriveP0TextKeys.infoLabels, '标签'),
          e.labels.map((l) => l.name).join(t.listSeparator),
        ),
      (
        driveP0(DriveP0TextKeys.infoPermission, '权限'),
        [
          if (e.canDownload) driveP0(DriveP0TextKeys.infoCanDownload, '可下载'),
          if (e.canPreview) driveP0(DriveP0TextKeys.infoCanPreview, '可预览'),
          if (e.canWrite) driveP0(DriveP0TextKeys.infoCanWrite, '可编辑'),
          if (!e.canDownload && !e.canPreview && !e.canWrite)
            driveP0(DriveP0TextKeys.infoNone, '无'),
        ].join(' · '),
      ),
      if (e.shared || e.starred || e.isLocked)
        (
          driveP0(DriveP0TextKeys.infoPermission, '权限'),
          [
            if (e.shared) driveP0(DriveP0TextKeys.infoShared, '已共享'),
            if (e.starred) driveP0(DriveP0TextKeys.infoStarred, '已加星标'),
            if (e.isLocked)
              e.lockUserName.isEmpty
                  ? driveP0(DriveP0TextKeys.infoLocked, '已锁定')
                  : driveP0Fill(DriveP0TextKeys.infoLockedBy, '被 {name} 锁定', {
                      'name': e.lockUserDisplayName.isEmpty
                          ? e.lockUserName
                          : e.lockUserDisplayName,
                    }),
          ].join(' · '),
        ),
    ];
    return SafeArea(
      key: const Key('drive-info-sheet'),
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
                    driveP0(DriveP0TextKeys.infoTitle, '信息'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              e.name,
              key: const Key('drive-info-name'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: Gap.sm),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (label, value) in rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 88,
                              child: Text(
                                label,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: hud.dim,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                value,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (fresh.hasError)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.sm),
                        child: Text(
                          // 详情请求失败不挡查看：列表里的字段照常展示
                          describeFileError(fresh.error!),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // wave2：转成 Office 格式（`Files:convert_office` v1）。
                  // 目录无意义 → 不出现；能力表缺 `Files` → 不出现。
                  if (!e.isDir && driveFilesCapabilityAvailable(ref))
                    TextButton(
                      key: const Key('drive-info-convert-office'),
                      onPressed: () {
                        Navigator.of(context).maybePop();
                        showDriveConvertOfficeSheet(context, ref, e);
                      },
                      child: Text(
                        driveWave2(
                          DriveWave2TextKeys.convertEntry,
                          '转成 Office 格式',
                        ),
                      ),
                    ),
                  // 本批：申请访问权（`Files:request_access` v11，**写操作**）。
                  // 只在"列表里显示这个条目、但三种权限一个都没有"时出现；
                  // 点击要过确认框，成功/失败都有明确提示。
                  if (driveRequestAccessAvailable(ref) && _needsAccess(e))
                    TextButton(
                      key: const Key('drive-info-request-access'),
                      onPressed: () => _requestDriveAccess(context, ref, e),
                      child: Text(
                        driveWave2(DriveWave2TextKeys.requestAccess, '申请访问权'),
                      ),
                    ),
                  // G4：打包下载 / 发送副本（D31/D34；多选时还会多出"压缩并发送"
                  // ——见 `showDriveTransferSheet` 的门禁）。入口放在"信息"面板里，
                  // 是因为 `drive_browse_view.dart` 的行菜单属并行批次、本批禁碰。
                  TextButton(
                    key: const Key('drive-info-transfer'),
                    onPressed: () {
                      Navigator.of(context).maybePop();
                      showDriveTransferSheet(context, ref, [e]);
                    },
                    child: Text(
                      driveG4(DriveG4TextKeys.archiveTitle, '打包与分享'),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(driveP0(DriveP0TextKeys.infoClose, '关闭')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 类型那一栏：官方 `ntype` 是"目录/Office 文档/扩展名"的映射
  /// （`synodrive_common.js:7` `updateData` 里 `dir`→目录、`office` 家族→名、
  /// 其余取扩展名）。这里用既有 `contentType`，缺了就回落扩展名。
  String _typeLabel(DriveEntryDto e) {
    if (e.isDir) return driveP0(DriveP0TextKeys.infoFolder, '文件夹');
    if (e.contentType.isNotEmpty) return e.contentType;
    return e.extension.isEmpty
        ? driveP0(DriveP0TextKeys.infoTypeFile, '文件')
        : e.extension.toUpperCase();
  }
}

/// 这个条目是否"三种权限一个都没有" → 才给"申请访问权"入口。
///
/// 官方语义：`request_access` 是"我没有权限、请拥有者给我"的写操作；
/// 已经有任何一种访问能力时**不该出现**这个按钮。
bool _needsAccess(DriveEntryDto e) =>
    !e.canDownload && !e.canPreview && !e.canWrite;

/// 申请访问权：**先确认、再调用**；成功 / 失败都给明确提示（不许静默）。
///
/// ⚠️ 这是**写操作**。参数契约只由只读 120 oracle 取证（`path` 标量字符串），
/// 成功路径本批**未实调**（见交付报告「未做」清单）。
Future<void> _requestDriveAccess(
  BuildContext context,
  WidgetRef ref,
  DriveEntryDto e,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        driveWave2(DriveWave2TextKeys.requestAccessConfirmTitle, '申请访问权'),
      ),
      content: Text(
        driveWave2(
          DriveWave2TextKeys.requestAccessConfirmMessage,
          '向该条目的拥有者发送访问权申请？',
        ),
      ),
      actions: [
        TextButton(
          key: const Key('drive-request-access-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(driveWave2(DriveWave2TextKeys.requestAccessCancel, '取消')),
        ),
        FilledButton(
          key: const Key('drive-request-access-confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            driveWave2(DriveWave2TextKeys.requestAccessConfirm, '发送申请'),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await ref.read(driveRequestAccessActionProvider).request(e);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          driveWave2(DriveWave2TextKeys.requestAccessSent, '已发送访问权申请'),
        ),
      ),
    );
  } catch (err) {
    // 写操作失败**必须明确提示**，绝不静默、绝不装成成功。
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          driveWave2Fill(
            DriveWave2TextKeys.requestAccessFailed,
            '申请失败：{error}',
            {'error': describeFileError(err)},
          ),
        ),
      ),
    );
  }
}
