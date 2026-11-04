// 文件模块的对话框与底部面板。
//
// 拆出来是为了让页面文件只负责布局与状态；这里的函数都可以单独在 widget 测试里
// 调用（返回 Future 的结果就是用户的选择）。
import '../../design/kit/design_kit.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/cache_service.dart' show humanBytes;
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_sheet.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/dto/file_mount_dto.dart' show FileWormState;
import '../../data/dto/file_worm_dto.dart';
import '../../data/filestation_api.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../../dsm/webapi.dart' show DsmApiException;
import 'archive_volumes.dart';
import 'file_link_expiry.dart';
import 'file_link_share.dart';
import 'file_favorite_reorder.dart';
import 'file_providers.dart';
import 'file_row.dart';
import 'file_task_retry.dart';
import 'filestation_c5_text.dart';
import 'filestation_g4_text.dart';
import 'filestation_gaps_wave1_text.dart';
import 'filestation_gaps_wave2_text.dart';
import 'filestation_gaps_wave4_text.dart';
import 'filestation_gaps_wave5_text.dart';
import 'filestation_p0a_text.dart';
import 'filestation_p0b_text.dart';

/// 通用的单行文本输入框（新建文件夹 / 重命名 / 压缩包名 / 目标路径都用它）
Future<String?> promptFileName(
  BuildContext context, {
  required String title,
  required String actionLabel,
  String initial = '',
  String? hintText,
  String helperText = '',
}) {
  final controller = TextEditingController(text: initial);
  final t = context.t;
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: hintText ?? t.sortByName,
          helperText: helperText.isEmpty ? null : helperText,
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: Text(actionLabel),
        ),
      ],
    ),
  );
}

/// 危险操作确认（删除）
Future<bool> confirmDanger(
  BuildContext context, {
  required String title,
  required String message,
  String? actionLabel,
}) async {
  final t = context.t;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(actionLabel ?? t.dtoActionDelete),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 单个文件/文件夹的操作面板。
///
/// 返回值是用户选的**动作名**（`open` / `download` / …），由页面决定怎么执行 ——
/// 这样面板本身不依赖任何 provider，测试里可以直接断言返回值。
/// 文件/文件夹的操作面板。
///
/// [readOnly] 给"没有浏览上下文"的页面（收藏、搜索结果）用：只剩
/// 打开 / 下载 / 收藏 / 属性，不带重命名、复制移动、压缩解压、删除 ——
/// 那些动作需要刷新某个目录的缓存，脱开浏览页做会留下不一致的缓存。
Future<String?> showFileItemSheet(
  BuildContext context, {
  required FileEntryDto entry,
  bool isFavorite = false,
  bool readOnly = false,
  bool canShare = false,
  bool recycleBin = false,
  bool wormLocked = false,
  bool isPinned = false,
}) {
  final isDir = entry.isDir;
  final t = context.t;
  // 146（M26）：分卷包的扩展名是 `rar`（`x.part1.rar`）**或**是卷号
  // （`x.001` / `x.7z.001` → `extension == "001"`）。后者原来根本不出
  // "解压"项，用户连入口都没有 ⇒ 这里用 [detectArchiveVolume] 补上。
  final canExtract =
      !isDir &&
      (const {
            'zip',
            'rar',
            '7z',
            'tar',
            'gz',
            'bz2',
          }.contains(entry.extension) ||
          detectArchiveVolume(entry.name) != null);
  // P1-6：WORM 锁定的文件**不许改**。官方 `getBasicFileActions`
  // （`ResourceListFragment.java:2657-2682`）对锁定态（IMMUTABLE_LOCKED /
  // APPENDABLE_LOCKED / WEAK_*_LOCKED，即 `worm_state & 32`）只保留 COPY，
  // 删除/改名/移动全被拿掉；这里同样只留复制，并给一句原因。
  final locked = wormLocked;
  final lockReason = locked
      ? fsC5Fill(FsC5TextKeys.wormBlocked, '该文件已被 WriteOnce 锁定，不能{action}', {
          'action': t.dtoActionDelete,
        })
      : null;
  return showAppSheet<String>(
    context,
    title: entry.name,
    children: [
      AppSheetSection(
        label: t.fileOpen,
        children: [
          AppSheetAction(
            icon: isDir ? Icons.folder_open_outlined : Icons.open_in_new,
            label: isDir ? t.fileOpenFolder : t.fileOpen,
            onTap: () => Navigator.of(context).pop('open'),
          ),
          if (!isDir)
            AppSheetAction(
              icon: Icons.download_outlined,
              label: t.fileDownloadToDevice,
              description: entry.disableDownload
                  ? t.fileDownloadForbidden
                  : null,
              onTap: entry.disableDownload
                  ? null
                  : () => Navigator.of(context).pop('download'),
            ),
        ],
      ),
      // P1-6：锁定的文件**只剩复制**（官方对锁定态只放行 COPY），
      // 其余动作直接从面板里拿掉——不是"灰着还能点"，而是根本不出现。
      if (locked)
        AppSheetSection(
          label: fsC5(FsC5TextKeys.wormLocked, 'WORM 已锁定'),
          children: [
            AppSheetAction(
              icon: Icons.lock_outline,
              label: t.fileCopyTo,
              description: lockReason,
              onTap: () => Navigator.of(context).pop('copy'),
            ),
          ],
        ),
      if (!readOnly && !locked)
        AppSheetSection(
          label: t.fileManage,
          children: [
            // 回收站里的条目：唯一的"移出"动作是还原（官方
            // `RecycleBin.js` 的 CopyMove + restore_from_recycle_bin），
            // 不提供改名/复制/压缩这些会留在回收站里的动作。
            if (recycleBin) ...[
              AppSheetAction(
                icon: Icons.restore_from_trash_outlined,
                label: fsP0a(FsP0aTextKeys.recycleRestore, '还原'),
                onTap: () => Navigator.of(context).pop('restore'),
              ),
            ] else ...[
              AppSheetAction(
                icon: Icons.drive_file_rename_outline,
                label: t.photoRename,
                onTap: () => Navigator.of(context).pop('rename'),
              ),
              AppSheetAction(
                icon: Icons.content_copy_outlined,
                label: t.fileCopyTo,
                onTap: () => Navigator.of(context).pop('copy'),
              ),
              AppSheetAction(
                icon: Icons.drive_file_move_outline,
                label: t.fileMoveTo,
                onTap: () => Navigator.of(context).pop('move'),
              ),
              // M72：把目录钉到主屏（官方 `addShortcut()`；仅目录有意义）
              if (isDir)
                AppSheetAction(
                  icon: Icons.add_to_home_screen,
                  label: fsGap2(FsGap2TextKeys.shortcut, '创建桌面快捷方式'),
                  onTap: () => Navigator.of(context).pop('shortcut'),
                ),
              // r296（收口 D2b）：`SYNO.FileStation.DirSize` 的**能力表、API
              // （`startDirSize`）、服务层（`dirSize`）、后台任务还原
              // （`file_task_retry` 认 `DirSize`）、文案（`fileDirSizeSubmitted*`）
              // 全都在，但**没有任何地方发过 `'dirsize'`** ⇒ 这个已经做好的功能
              // 用户**根本点不到**（审计里登记的"不可达分支"）。这里补上入口。
              // 只对目录显示：文件的大小列表列里已经有了，官方 File Station
              // 的"计算大小"也只在文件夹上出现。
              if (isDir)
                AppSheetAction(
                  key: const Key('file-dirsize'),
                  icon: Icons.calculate_outlined,
                  label: t.fileDirSize,
                  onTap: () => Navigator.of(context).pop('dirsize'),
                ),
              AppSheetAction(
                icon: Icons.inventory_2_outlined,
                label: t.dtoFileTaskCompress,
                onTap: () => Navigator.of(context).pop('compress'),
              ),
              // r305：`Extract/list`（"不解压先看包里有什么"）**早就写好了 API
              // （`FileStationApi.listArchive`）、却**没有任何入口** ⇒ 用户点不到
              // （同 §2.0.42 的"登记了却不产生机制量"）。这里补上，且**排在解压之前**
              // —— 先看清楚再决定要不要解，正是这个接口存在的理由。
              if (canExtract)
                AppSheetAction(
                  key: const Key('file-action-archive-contents'),
                  icon: Icons.list_alt_outlined,
                  label: t.fileArchiveContents,
                  onTap: () => Navigator.of(context).pop('archive_list'),
                ),
              if (canExtract)
                AppSheetAction(
                  icon: Icons.unarchive_outlined,
                  label: t.fileExtractHere,
                  onTap: () => Navigator.of(context).pop('extract'),
                ),
              // G4 / 219（M67）：离线文件（纯客户端本地登记，官方 Pin 同构）
              if (!isDir)
                AppSheetAction(
                  key: const Key('file-action-offline-pin'),
                  icon: isPinned
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_download_outlined,
                  label: isPinned
                      ? fsG4(FsG4TextKeys.offlineUnpin, '移出离线文件')
                      : fsG4(FsG4TextKeys.offlinePin, '加入离线文件'),
                  onTap: () => Navigator.of(context).pop('offline_pin'),
                ),
            ],
            // P0-1：分享链接创建入口（原来刻意没有入口）
            if (canShare && !recycleBin)
              AppSheetAction(
                icon: Icons.link_outlined,
                label: fsP0a(FsP0aTextKeys.shareAdd, '创建分享链接'),
                onTap: () => Navigator.of(context).pop('share'),
              ),
            AppSheetAction(
              icon: isFavorite ? Icons.star : Icons.star_border,
              label: isFavorite ? t.photoUnfavorite : t.fileAddFavorite,
              onTap: () => Navigator.of(context).pop('favorite'),
            ),
            AppSheetAction(
              icon: Icons.info_outline,
              label: t.fileProperties,
              onTap: () => Navigator.of(context).pop('properties'),
            ),
          ],
        )
      else
        AppSheetSection(
          children: [
            AppSheetAction(
              icon: isFavorite ? Icons.star : Icons.star_border,
              label: isFavorite ? t.photoUnfavorite : t.fileAddFavorite,
              onTap: () => Navigator.of(context).pop('favorite'),
            ),
            AppSheetAction(
              icon: Icons.info_outline,
              label: t.fileProperties,
              onTap: () => Navigator.of(context).pop('properties'),
            ),
          ],
        ),
      if (!readOnly && !locked)
        AppSheetSection(
          danger: true,
          children: [
            AppSheetAction(
              icon: Icons.delete_outline,
              label: recycleBin
                  ? fsP0a(FsP0aTextKeys.deleteForever, '永久删除')
                  : t.dtoActionDelete,
              description: lockReason,
              danger: true,
              onTap: locked
                  ? null
                  : () => Navigator.of(
                      context,
                    ).pop(recycleBin ? 'delete_forever' : 'delete'),
            ),
          ],
        ),
    ],
  );
}

/// 上传同名冲突面板（P0-a）。
///
/// 官方 DS file 的 `ConflictActionSheet`（`buildActionSheet`）只有三个动作 +
/// 取消：`overwrite` / `rename` / `ignore`（跳过），文案 key 分别是
/// `R.string.overwrite` / `R.string.rename` / `R.string.ignore`。
/// 服务端 v2 不支持 rename 时（`isSupportUploadRename()`）官方会 mask 掉
/// `NO_RENAME`；这里用 [allowRename] 对应。
///
/// 返回 `null` = 用户取消（**调用方必须中止上传，不得默默覆盖**）。
Future<UploadConflictPolicy?> showUploadConflictSheet(
  BuildContext context, {
  required String fileName,
  bool allowRename = true,
}) {
  return showAppSheet<UploadConflictPolicy>(
    context,
    title: fsP0a(FsP0aTextKeys.conflictTitle, '同名文件已存在'),
    children: [
      AppSheetSection(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
            child: Text(
              fsP0aFill(FsP0aTextKeys.conflictBody, '{name} 已存在于该目录。请选择处理方式。', {
                'name': fileName,
              }),
            ),
          ),
          AppSheetAction(
            icon: Icons.swap_horiz,
            label: fsP0a(FsP0aTextKeys.conflictOverwrite, '覆盖'),
            onTap: () =>
                Navigator.of(context).pop(UploadConflictPolicy.overwrite),
          ),
          if (allowRename)
            AppSheetAction(
              icon: Icons.drive_file_rename_outline,
              label: fsP0a(FsP0aTextKeys.conflictRename, '重命名'),
              onTap: () =>
                  Navigator.of(context).pop(UploadConflictPolicy.rename),
            ),
          AppSheetAction(
            icon: Icons.skip_next,
            label: fsP0a(FsP0aTextKeys.conflictSkip, '跳过'),
            onTap: () => Navigator.of(context).pop(UploadConflictPolicy.skip),
          ),
        ],
      ),
    ],
  );
}

/// 还原冲突面板（P0-b）。
///
/// 官方证据：`ui/file_browser/RecycleBin.js` 的 `launchFn` —— 未开启
/// `enableautooverwrite` 时弹 `PasteConfirmDialog`，用户选"覆盖/跳过"，
/// 该布尔值原样成为 `CopyMove.start` 的 `overwrite`。
/// 返回 `true` = 覆盖，`false` = 跳过，`null` = 取消（中止还原）。
Future<bool?> showRestoreConflictSheet(
  BuildContext context, {
  required List<String> conflicts,
}) {
  return showAppSheet<bool>(
    context,
    title: fsP0b(FsP0bTextKeys.restoreConflictTitle, '目标位置已有同名项目'),
    children: [
      AppSheetSection(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
            child: Text(
              fsP0bFill(
                FsP0bTextKeys.restoreConflictBody,
                '{count} 个项目在还原目标位置已存在同名项目。请选择处理方式。',
                {'count': '${conflicts.length}'},
              ),
            ),
          ),
          AppSheetAction(
            icon: Icons.swap_horiz,
            label: fsP0b(FsP0bTextKeys.restoreOverwrite, '覆盖'),
            onTap: () => Navigator.of(context).pop(true),
          ),
          AppSheetAction(
            icon: Icons.skip_next,
            label: fsP0b(FsP0bTextKeys.restoreSkip, '跳过'),
            onTap: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    ],
  );
}

/// 压缩选项（P0-b）：目标压缩包名 + 可选密码。
///
/// 官方 `CompressFragment` 有密码开关 + 密码 + 确认（`validPassword()`：
/// 开关打开时不许为空、长度 ≤ 127、两次必须一致），发给
/// `WebApiConnectionManager` 的 `Compress(…, password)`。
/// 本面板保留同一语义；密码开关关闭时**不发** `password`。
///
/// 返回 `null` = 取消。

/// 压缩选项（P1-4 起带格式与级别）。
///
/// 取值来源分两类，**不能混用**（第 29 轮裁决）：
///
/// * `format`：APK `arrays.xml` 的 `archive_compress_format` = `zip` / `7z`；
/// * `level`：APK `arrays.xml` 的 `archive_compress_level_key`
///   = `store` / `fastest` / **`normal`** / `best`；
/// * `mode`：见 [CompressMode]（服务端 `.so` 与 APK **有分歧**，已逐条裁决）。
///
/// ⚠️ 原先 `level` 的第三档写的是 `moderate` —— 那是从 `.so` 里
/// `-mx6`（**没有名字的 flag**）反推出来的**臆测**，不是观测到的线上值。
typedef CompressDraft = ({
  String name,
  String format,
  String level,
  String mode,
  String? password,
});

/// 压缩格式（`format` 参数；服务端只认这两个 GUI 会发的值）
enum CompressFormat {
  zip('zip', 'ZIP'),
  sevenZip('7z', '7z');

  const CompressFormat(this.value, this.label);

  final String value;
  final String label;
}

/// 压缩级别（`level` 参数）—— label 走 [FsC5TextKeys] 译文，value 是**线上值**。
///
/// ## value 为什么是 `normal` 而不是 `moderate`（第 29 轮修正）
/// `SYNO.FileStation.Compress.so` 里的取值是**成对**出现的：
/// ```
///   store       -mx0
///   fastest     -mx3
///   best        -mx9
///               -mx6      ← ★ 有 flag，**没有名字**
/// ```
/// 中间档 `-mx6` 在**服务端没有名字** ⇒ 名字只能来自客户端
/// ⇒ 以官方客户端的线上值为准：
/// `.apk!/res/values/arrays.xml` → `archive_compress_level_key`
/// = `['store','fastest','normal','best']`。
///
/// 我方的 `moderate` 是从 `-mx6` **反推**的臆测（见旧版
/// `docs/api-server-authoritative.md:1194-1204` 的"依据"列）。
/// 即便服务端把不认识的名字回落到 `-mx6`（结果碰巧一样），
/// **发一个服务端没有的名字仍然是错的** —— 已改为 `normal`。
enum CompressLevel {
  store('store', FsC5TextKeys.levelStore, '仅存储'),
  fastest('fastest', FsC5TextKeys.levelFastest, '最快'),
  normal('normal', FsC5TextKeys.levelModerate, '标准'),
  best('best', FsC5TextKeys.levelBest, '最好');

  const CompressLevel(this.value, this.key, this.zh);

  final String value;
  final String key;
  final String zh;

  String label() => fsC5(key, zh);
}

/// 压缩**更新模式**（`mode` 参数 / 官方前端下拉 `archive_update_mode`）。
///
/// ## ⚠️ 服务端 `.so` 与官方 APK **有分歧**，逐条裁决（第 29 轮）
///
/// 服务端 `SYNO.FileStation.Compress.so` 认识的名字只有
/// `update` / `freshen` / `synchronize`（其余 = 默认的"添加"）：
/// ```
///   update       -up1q1r0x1y2z1w2
///   freshen      -up1q0r2x1y2z1w2
///   synchronize  （同族）
/// ```
/// 官方 APK `arrays.xml` → `archive_update_mode_key`
/// = `['replace','update','freshen','synchroize']`。
///
/// | 档 | 服务端 `.so` | 官方 APK | 本枚举采用 | 理由 |
/// |---|---|---|---|---|
/// | 添加/替换 | 无名字（默认） | `replace` | **`replace`** | 默认档名字只能来自客户端 ⇒ 以 APK 为准 |
/// | 更新 | `update` | `update` | `update` | 一致 |
/// | 刷新 | `freshen` | `freshen` | `freshen` | 一致 |
/// | 同步 | **`synchronize`** | `synchroize` | **`synchronize`** | ★ **APK 那个是拼写错误**（漏了 `n`）。服务端只认 `synchronize` ⇒ **不照抄官方的错** |
///
/// ★ 最后一条值得单独说：官方安卓端的 `synchroize` 少了个 `n`。
/// 服务端 `.so` 里只有正确的 `synchronize`。**照抄"官方"会照抄出一个 bug** ——
/// 所以这里以**服务端认识的名字**为准，并把这个分歧记在案。
enum CompressMode {
  replace('replace', FsGap2TextKeys.modeAdd, '添加（新建）'),
  update('update', FsGap2TextKeys.modeUpdate, '更新（添加并替换）'),
  freshen('freshen', FsGap2TextKeys.modeFreshen, '刷新（仅更新已有）'),
  synchronize('synchronize', FsGap2TextKeys.modeSynchronize, '同步');

  const CompressMode(this.value, this.key, this.zh);

  final String value;
  final String key;
  final String zh;

  String label() => fsGap2(key, zh);
}

Future<CompressDraft?> showCompressSheet(
  BuildContext context, {
  required String defaultName,
}) {
  return showDialog<CompressDraft>(
    context: context,
    builder: (context) => _CompressDialog(defaultName: defaultName),
  );
}

class _CompressDialog extends StatefulWidget {
  const _CompressDialog({required this.defaultName});

  final String defaultName;

  @override
  State<_CompressDialog> createState() => _CompressDialogState();
}

class _CompressDialogState extends State<_CompressDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.defaultName,
  );
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _usePassword = false;
  // P1-4：格式 / 级别下拉（原先写死 zip + moderate，用户选不了 7z 或"仅存储"）
  CompressFormat _format = CompressFormat.zip;
  CompressLevel _level = CompressLevel.normal;
  // wave2 M21：更新模式下拉（官方 `archive_update_mode`，`CompressFragment.java:81`）
  CompressMode _mode = CompressMode.replace;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    if (_usePassword) {
      if (_password.text.isEmpty) {
        setState(() => _error = fsP0b(FsP0bTextKeys.passwordEmpty, '密码不能为空'));
        return;
      }
      if (_password.text != _confirm.text) {
        setState(
          () => _error = fsP0b(FsP0bTextKeys.passwordMismatch, '两次输入的密码不一致'),
        );
        return;
      }
    }
    Navigator.of(context).pop((
      name: name,
      format: _format.value,
      level: _level.value,
      mode: _mode.value,
      password: _usePassword ? _password.text : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(t.dtoFileTaskCompress),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: t.fileArchiveNameHint,
                helperText: t.fileCreateInCurrentDir,
              ),
            ),
            const SizedBox(height: Gap.md),
            // P1-4：格式 + 级别（官方 `CompressFragment` 的两个下拉）
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<CompressFormat>(
                    isExpanded: true,
                    initialValue: _format,
                    decoration: InputDecoration(
                      labelText: fsC5(FsC5TextKeys.compressFormat, '压缩格式'),
                    ),
                    items: [
                      for (final f in CompressFormat.values)
                        DropdownMenuItem(value: f, child: Text(f.label)),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _format = v);
                    },
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: DropdownButtonFormField<CompressLevel>(
                    isExpanded: true,
                    initialValue: _level,
                    decoration: InputDecoration(
                      labelText: fsC5(FsC5TextKeys.compressLevel, '压缩级别'),
                    ),
                    items: [
                      for (final l in CompressLevel.values)
                        DropdownMenuItem(value: l, child: Text(l.label())),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _level = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),
            // wave2 M21：更新模式（官方 `archive_update_mode` 下拉）。
            // 取值照 `api-server-authoritative.md:1194-1204`，不自创。
            DropdownButtonFormField<CompressMode>(
              isExpanded: true,
              initialValue: _mode,
              key: const Key('compress-mode'),
              decoration: InputDecoration(
                labelText: fsGap2(FsGap2TextKeys.compressMode, '更新模式'),
              ),
              items: [
                for (final m in CompressMode.values)
                  DropdownMenuItem(value: m, child: Text(m.label())),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _mode = v);
              },
            ),
            const SizedBox(height: Gap.md),
            Row(
              children: [
                Expanded(
                  child: Text(
                    fsP0b(FsP0bTextKeys.compressPasswordEnable, '启用密码保护'),
                  ),
                ),
                Switch(
                  value: _usePassword,
                  onChanged: (v) => setState(() {
                    _usePassword = v;
                    _error = null;
                  }),
                ),
              ],
            ),
            if (_usePassword) ...[
              TextField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: fsP0b(FsP0bTextKeys.compressPasswordLabel, '密码'),
                ),
              ),
              TextField(
                controller: _confirm,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: fsP0b(FsP0bTextKeys.passwordConfirmLabel, '确认密码'),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Gap.sm),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(t.fileStartCompress)),
      ],
    );
  }
}

/// 解压时的文件名编码候选（`Extract/start` 的 `codepage`）。
///
/// 线上值来自服务端自己的列表：官方 Web 端 `FileBrowserUtil.js` 的
/// `getSupportedLanguage` = `SYNO.SDS.Utils.getSupportedLanguageCodepage()`
/// **再 push 一条 `["utf8", unicode]`**；官方 DS file 的 `ExtractFragment`
/// 也是同一个语言下拉（`ExtractFragment.java:82`）。这里只列最常见的几条，
/// 标签是**语言自称**（静态数据，不进 ARB），与 `media_tracks.dart` 同一做法。
enum ExtractCodepage {
  utf8('utf8', 'UTF-8'),
  chs('chs', '简体中文 (GBK)'),
  cht('cht', '繁體中文 (Big5)'),
  jpn('jpn', '日本語 (EUC-JP)'),
  krn('krn', '한국어 (EUC-KR)'),
  enu('enu', 'English (CP1252)');

  const ExtractCodepage(this.value, this.label);

  final String value;
  final String label;
}

/// 解压选项（P0-b 密码 + P1-5 文件名编码）。
///
/// 官方 `ExtractFragment` 有密码输入框（`:138`）和语言/编码下拉（`:82`），
/// `Extract/start` 的 `password` / `codepage` 字段照发。
/// 返回 `null` = 取消；`password: null` = 无密码包；`codepage: null` = 不发。
/// 「查看压缩包内容」（`SYNO.FileStation.Extract / list`）的底部面板。
///
/// 为什么要它：`Extract/list` 是**只读**接口（不解压就能列出包里的条目），
/// 但 r305 之前仓库里只有 API、没有入口 —— 用户点不到（"死功能"）。
///
/// 交互上只需要一件事：**卖点就是"不用解压先看看"**，所以打开就自动列一次；
/// 加密包会失败，这时给一个"填密码再试"的入口，**不猜**错误码含义
/// （服务端对加密包到底回 401 还是别的码，本机没有加密包的只读取证，见文件尾注）。
Future<void> showArchiveContentsSheet(
  BuildContext context, {
  required String fileName,
  required Future<FileListResult> Function({String? password}) load,
}) {
  final t = context.t;
  final volume = detectArchiveVolume(fileName);
  return showAppSheet<void>(
    context,
    title: fileName,
    children: [
      _ArchiveContentsBody(load: load, volume: volume, t: t),
    ],
  );
}

class _ArchiveContentsBody extends StatefulWidget {
  const _ArchiveContentsBody({
    required this.load,
    required this.volume,
    required this.t,
  });

  final Future<FileListResult> Function({String? password}) load;
  final ArchiveVolume? volume;
  final AppText t;

  @override
  State<_ArchiveContentsBody> createState() => _ArchiveContentsBodyState();
}

class _ArchiveContentsBodyState extends State<_ArchiveContentsBody> {
  FileListResult? _result;
  String? _error;
  bool _loading = true;
  String? _password;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.load(password: _password);
      if (!mounted) return;
      setState(() {
        _result = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeFileError(e);
        _loading = false;
      });
    }
  }

  Future<void> _askPassword() async {
    final controller = TextEditingController(text: _password ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.t.fileArchiveContents),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            labelText: fsP0b(FsP0bTextKeys.extractPasswordLabel, '密码'),
          ),
          onSubmitted: (_) => Navigator.of(context).pop(true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(widget.t.fileArchiveContentsPasswordRetry),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _password = controller.text.isEmpty ? null : controller.text;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Gap.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      // 失败态做成**一条普通菜单项**（原因写在说明行里），不做画在底部的按钮：
      // 面板贴着屏幕底边，底部按钮在小视口/带安全区时会被挤到屏幕外点不到
      // （r305 实测：`tester.getRect` 量到按钮底 = 2292 > 屏高 2200）。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.volume != null) ...[
            _VolumeNotice(volume: widget.volume!),
            const SizedBox(height: Gap.md),
          ],
          AppSheetSection(
            label: t.fileArchiveContents,
            children: [
              // 加密包 ⇔ 需要密码：**不编错误码映射**，失败时一律给这个入口。
              AppSheetAction(
                key: const Key('archive-contents-password'),
                icon: Icons.password_outlined,
                label: t.fileArchiveContentsPasswordRetry,
                description: t.fileArchiveContentsFailed(_error!),
                onTap: _askPassword,
              ),
            ],
          ),
        ],
      );
    }
    final entries = _result?.entries ?? const <FileEntryDto>[];
    if (entries.isEmpty) {
      return TelemetryLabel(t.fileArchiveContentsEmpty);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.volume != null) ...[
          _VolumeNotice(volume: widget.volume!),
          const SizedBox(height: Gap.md),
        ],
        TelemetryLabel(t.fileArchiveContentsCount(entries.length)),
        const SizedBox(height: Gap.sm),
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Row(
              children: [
                Icon(
                  e.isDir ? Icons.folder_outlined : Icons.description_outlined,
                  size: 18,
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (!e.isDir)
                  TelemetryLabel(humanBytes(e.size), size: 11),
              ],
            ),
          ),
      ],
    );
  }
}

Future<({String? password, String? codepage})?> showExtractSheet(
  BuildContext context, {
  required String fileName,
}) {
  final controller = TextEditingController();
  final t = context.t;
  ExtractCodepage? codepage;
  // 146（M26）：分卷包提示。官方对分卷包**没有独立 UI**（服务端 `Extract/start`
  // 自己处理），但用户拿第 N 卷（N>1）来解压时服务端会失败/给出看不懂的错误；
  // 这里在**动手之前**就说清楚"该用第 1 卷"。
  final volume = detectArchiveVolume(fileName);
  return showDialog<({String? password, String? codepage})>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(t.dtoFileTaskExtract),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.fileExtractConfirmBody(fileName)),
              if (volume != null) ...[
                const SizedBox(height: Gap.md),
                _VolumeNotice(volume: volume),
              ],
              const SizedBox(height: Gap.md),
              TextField(
                controller: controller,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: fsP0b(FsP0bTextKeys.extractPasswordLabel, '密码'),
                  helperText: fsP0b(
                    FsP0bTextKeys.extractPasswordHint,
                    '加密压缩包才需要填；留空表示没有密码',
                  ),
                ),
                onSubmitted: (_) => Navigator.of(context).pop((
                  password: controller.text.isEmpty ? null : controller.text,
                  codepage: codepage?.value,
                )),
              ),
              const SizedBox(height: Gap.md),
              // P1-5：老压缩包文件名乱码时挑一个编码；默认不指定（服务端默认）
              DropdownButtonFormField<ExtractCodepage?>(
                isExpanded: true,
                initialValue: codepage,
                decoration: InputDecoration(
                  labelText: fsC5(FsC5TextKeys.extractCodepage, '文件名编码'),
                  helperText: fsC5(
                    FsC5TextKeys.extractCodepageHint,
                    '解压出来的文件名乱码时选择对应编码',
                  ),
                ),
                items: [
                  DropdownMenuItem<ExtractCodepage?>(
                    value: null,
                    child: Text(fsC5(FsC5TextKeys.extractCodepage, '文件名编码')),
                  ),
                  for (final c in ExtractCodepage.values)
                    DropdownMenuItem<ExtractCodepage?>(
                      value: c,
                      child: Text(c.label),
                    ),
                ],
                onChanged: (v) => setState(() => codepage = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop((
              password: controller.text.isEmpty ? null : controller.text,
              codepage: codepage?.value,
            )),
            child: Text(t.dtoFileTaskExtract),
          ),
        ],
      ),
    ),
  );
}

/// 创建分享链接的结果（用户填的密码 / 有效期）
typedef ShareLinkDraft = ({String? password, String? dateExpired});

/// 创建分享链接面板（P0-1）。
///
/// 官方 DS file `ShareFragment` 的字段：有效期开关 + 起止日期、
/// 密码开关 + 密码 + 确认；日期按 `yyyy-MM-dd`（`DateUtils.DATE_FORMAT_LOCALE`）
/// 发给 `date_expired`。这里保留同样的语义，但用更轻的形态：
/// 有效期 = 选项（永久 / 1 / 7 / 30 天），密码 = 开关 + 输入框。
///
/// 返回 `null` = 取消。
Future<ShareLinkDraft?> showCreateShareLinkSheet(BuildContext context) {
  return showDialog<ShareLinkDraft>(
    context: context,
    builder: (context) => const _CreateShareLinkDialog(),
  );
}

class _CreateShareLinkDialog extends StatefulWidget {
  const _CreateShareLinkDialog();

  @override
  State<_CreateShareLinkDialog> createState() => _CreateShareLinkDialogState();
}

class _CreateShareLinkDialogState extends State<_CreateShareLinkDialog> {
  final _password = TextEditingController();
  bool _usePassword = false;
  int _days = 0; // 0 = 永久

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  /// 到期时间走 [shareLinkExpiryWire]（`%Y-%m-%d %H:%M:%S`，见该函数文档）：
  /// 只发日期会被服务端静默忽略（r306 真机）。
  String? _expiryDate() => shareLinkExpiryWire(DateTime.now(), _days);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(fsP0a(FsP0aTextKeys.shareCreateTitle, '创建分享链接')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    fsP0a(FsP0aTextKeys.sharePasswordEnable, '启用密码保护'),
                  ),
                ),
                Switch(
                  value: _usePassword,
                  onChanged: (v) => setState(() => _usePassword = v),
                ),
              ],
            ),
            if (_usePassword)
              TextField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: fsP0a(FsP0aTextKeys.sharePasswordLabel, '密码'),
                ),
              ),
            const SizedBox(height: Gap.md),
            Text(fsP0a(FsP0aTextKeys.shareValidity, '有效期')),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final d in const [0, 1, 7, 30])
                  ChoiceChip(
                    label: Text(
                      d == 0
                          ? fsP0a(FsP0aTextKeys.sharePermanent, '永久')
                          : fsP0aFill(FsP0aTextKeys.shareDays, '{days} 天', {
                              'days': '$d',
                            }),
                    ),
                    selected: _days == d,
                    onSelected: (_) => setState(() => _days = d),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: () {
            if (_usePassword && _password.text.isEmpty) return;
            Navigator.of(context).pop((
              password: _usePassword ? _password.text : null,
              dateExpired: _expiryDate(),
            ));
          },
          child: Text(t.photoCreate),
        ),
      ],
    );
  }
}

/// M36：编辑已有分享链接的结果。
///
/// * [password] 非空 = 设成这个新密码；`null` + `clearPassword=false` = 保持原样；
/// * [clearPassword] = 移除密码（第 251 轮已取证：`edit` 发
///   **`protect_type:"none"` + `password:""`**，逐字来自官方 DS file 4.17.2-609
///   `WebApiConnectionManager.editShareLinkV3`）；
/// * [dateExpired] 非空 = 新的到期日；`null` = **不动**原到期时间；
/// * [clearExpiry] = 用户选了「永久」。⚠️ **官方 edit 路径没有"取消有效期"的报文**
///   （APK 在日期为空时直接省略该字段；服务端 `webapi/SYNO.FileStation.Sharing.so`
///   只认 `%Y-%m-%d` 形式、空串很可能报错），所以它**只影响界面提示**，
///   线上行为 = 不改动原到期时间。
typedef ShareLinkEdit = ({
  String? password,
  bool clearPassword,
  String? dateExpired,
  bool clearExpiry,
});

/// 编辑分享链接面板（M36）—— 与创建面板**同一形状**，只是预填当前状态。
///
/// 入口在「分享链接」管理页（`FileShareLinksPage`）。返回 `null` = 取消。
Future<ShareLinkEdit?> showEditShareLinkSheet(
  BuildContext context, {
  required ShareLinkDto link,
}) {
  return showDialog<ShareLinkEdit>(
    context: context,
    builder: (context) => _EditShareLinkDialog(link: link),
  );
}

class _EditShareLinkDialog extends StatefulWidget {
  const _EditShareLinkDialog({required this.link});

  final ShareLinkDto link;

  @override
  State<_EditShareLinkDialog> createState() => _EditShareLinkDialogState();
}

class _EditShareLinkDialogState extends State<_EditShareLinkDialog> {
  final _password = TextEditingController();

  /// 默认跟着当前状态：原本有密码 → 开关打开（留空 = 保持原密码）
  late bool _usePassword = widget.link.hasPassword;

  /// -1 = 保持当前有效期；0 = 永久；>0 = 从今天起的 N 天
  int _days = -1;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  String? _expiryDate() => shareLinkExpiryWire(DateTime.now(), _days);

  /// 原链接没密码时，打开开关必须真的填一个；原本有密码时留空 = 保持。
  bool get _canSave =>
      !(_usePassword && !widget.link.hasPassword && _password.text.isEmpty);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hadPassword = widget.link.hasPassword;
    return AlertDialog(
      title: Text(fsGap(FsGapTextKeys.editShareLink, '编辑分享链接')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.link.name.isEmpty ? widget.link.path : widget.link.name,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.md),
            Row(
              children: [
                Expanded(
                  child: Text(
                    fsP0a(FsP0aTextKeys.sharePasswordEnable, '启用密码保护'),
                  ),
                ),
                Switch(
                  value: _usePassword,
                  onChanged: (v) => setState(() => _usePassword = v),
                ),
              ],
            ),
            if (_usePassword) ...[
              if (hadPassword)
                Text(
                  fsGap(FsGapTextKeys.sharePasswordKeep, '留空 = 保持当前密码'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              TextField(
                controller: _password,
                obscureText: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: hadPassword
                      ? fsGap(FsGapTextKeys.shareNewPassword, '新密码')
                      : fsP0a(FsP0aTextKeys.sharePasswordLabel, '密码'),
                ),
              ),
            ] else if (hadPassword)
              Text(
                fsGap(FsGapTextKeys.sharePasswordRemove, '保存后将移除密码'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: Gap.md),
            Text(fsP0a(FsP0aTextKeys.shareValidity, '有效期')),
            Wrap(
              spacing: Gap.sm,
              children: [
                ChoiceChip(
                  label: Text(fsGap(FsGapTextKeys.shareValidityKeep, '保持当前')),
                  selected: _days == -1,
                  onSelected: (_) => setState(() => _days = -1),
                ),
                for (final d in const [0, 1, 7, 30])
                  ChoiceChip(
                    label: Text(
                      d == 0
                          ? fsP0a(FsP0aTextKeys.sharePermanent, '永久')
                          : fsP0aFill(FsP0aTextKeys.shareDays, '{days} 天', {
                              'days': '$d',
                            }),
                    ),
                    selected: _days == d,
                    onSelected: (_) => setState(() => _days = d),
                  ),
              ],
            ),
            // ★ 第 251 轮：**如实说明**官方 edit 路径不能取消既有有效期
            //   （APK `editShareLinkV3` 在日期为空时直接省略 `date_expired`；
            //    服务端 `.so` 只认 `%Y-%m-%d`，所以我们也不发明空串）。
            if (_days == 0 && widget.link.dateExpired.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(
                  fsGap(
                    FsGapTextKeys.sharePermanentEditNote,
                    '官方端编辑时不发送"取消到期"字段（该链接现有到期时间会被保留）；'
                        '如需真正不过期，请删除后重新创建',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: _canSave
              ? () {
                  final typed = _password.text;
                  Navigator.of(context).pop((
                    password: _usePassword && typed.isNotEmpty ? typed : null,
                    clearPassword: !_usePassword && hadPassword,
                    dateExpired: _expiryDate(),
                    clearExpiry: _days == 0,
                  ));
                }
              : null,
          child: Text(t.actionSave),
        ),
      ],
    );
  }
}

/// M36：分享链接**详情**面板 —— `SYNO.FileStation.Sharing / getinfo`（只读）。
///
/// ★ 为什么要做这一条：`FileStationApi.shareLinkInfo`（`getinfo`，`id` 发**裸串**）
/// 早就封好了却**全仓 0 个调用方** —— 按 §2.0.45「封装了但没有 caller = 死功能」，
/// 要么接入口要么删。这里接成"点开一行看服务端此刻的真相"：列表的 `list` 回包
/// 只是快照，用户想知道"到底还有没有密码 / 到哪天为止"，得问 `getinfo`。
///
/// 面板先立刻呈现**列表快照**（不等网络），`getinfo` 回来后再换成服务端读数；
/// 取不到就**原样说原因**并给「重试」，**不拿快照冒充服务端真相**。
///
/// 返回 `'edit'` / `'delete'` = 用户点了对应动作（由页面去执行，面板里**不复制**
/// 一份编辑/删除逻辑）；`null` = 只是看看。
Future<String?> showShareLinkDetailSheet(
  BuildContext context, {
  required ShareLinkDto link,
  required Future<List<ShareLinkDto>> Function() load,
}) {
  return showAppSheet<String>(
    context,
    title: context.t.fileLinkDetail,
    children: [_ShareLinkDetailBody(link: link, load: load)],
  );
}

/// `data:image/…;base64,<payload>` → PNG/JPEG 字节；不是这种 URI 就返回 `null`。
///
/// 抽成顶层纯函数是为了能单测（真机 `Sharing/getinfo` 的 `qrcode` 就是这种 URI）。
Uint8List? qrImageBytes(String uri) {
  const marker = 'base64,';
  if (!uri.startsWith('data:image/')) return null;
  final at = uri.indexOf(marker);
  if (at < 0) return null;
  try {
    return base64Decode(uri.substring(at + marker.length));
  } on FormatException {
    return null;
  }
}

class _ShareLinkDetailBody extends StatefulWidget {
  const _ShareLinkDetailBody({required this.link, required this.load});

  final ShareLinkDto link;
  final Future<List<ShareLinkDto>> Function() load;

  @override
  State<_ShareLinkDetailBody> createState() => _ShareLinkDetailBodyState();
}

class _ShareLinkDetailBodyState extends State<_ShareLinkDetailBody> {
  /// `getinfo` 的读数；拿到前先用列表快照垫着（界面不空窗）。
  ShareLinkDto? _detail;
  String? _error;
  bool _loading = true;
  bool _missing = false;

  ShareLinkDto get _shown => _detail ?? widget.link;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _missing = false;
    });
    try {
      final rows = await widget.load();
      if (!mounted) return;
      setState(() {
        _detail = rows.isEmpty ? null : rows.first;
        // 服务端"成功但没这条"是**第三种态**：既不是详情、也不是错误 ——
        // 不许把列表快照当成服务端已经确认过（那又是编结论）。
        _missing = rows.isEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeFileError(e);
        _loading = false;
      });
    }
  }

  Future<void> _copy(BuildContext context) async {
    final t = context.t;
    await Clipboard.setData(ClipboardData(text: _shown.url));
    if (!context.mounted) return;
    Navigator.of(context).pop();
    AppSnack.show(context, t.fileLinkCopied);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final link = _shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          AppSheetSection(
            children: [
              AppSheetAction(
                key: const Key('share-link-detail-retry'),
                icon: Icons.refresh,
                label: t.fileLinkDetailRetry,
                description: t.fileLinkDetailFailed(_error!),
                onTap: _load,
              ),
            ],
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(Gap.lg),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        if (_missing)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            // ★ r533（DA170）：整句说明，1 行会被省略号截半句 ⇒ 允许 2 行。
            child: TelemetryLabel(
              t.fileLinkDetailMissing,
              size: 11,
              maxLines: 2,
            ),
          ),
        AppSheetSection(
          label: t.fileLinkDetailServer,
          children: [
            _PropRow(
              t.fileLinkStatus,
              link.isValid ? t.fileLinkValid : t.fileLinkInvalid,
            ),
            _PropRow(
              t.fileLinkHasPassword,
              // 缺键 ⇒ "服务端没说"，**不许**显示成"没有密码"（那是在编结论）
              !link.passwordKnown
                  ? t.fileLinkFieldUnknown
                  : (link.hasPassword ? t.fileLinkYes : t.fileLinkNo),
            ),
            // 起止时间在服务端就是**人读的日期串**（`2026-10-09`），
            // 不套 `formatFileTime`（那个收 epoch 秒，喂错类型只会得到空串）。
            if (link.dateAvailable.isNotEmpty)
              _PropRow(t.fileLinkStartAt, link.dateAvailable),
            _PropRow(
              t.fileLinkExpiryLabel,
              // ★ r306 真机教训：建链接时明明选了「7 天」，而回包里的
              //   `date_expired` **没了** ⇒ 旧代码把它显示成「永久」，
              //   等于替服务端下了结论（用户会以为链接永不过期）。
              //   现在分三态：有日期 → 日期；键在但空 → 永久；**缺键 → 未返回**。
              link.dateExpired.isNotEmpty
                  ? t.fileLinkExpiresAt(link.dateExpired)
                  : (link.expiryKnown
                        ? fsP0a(FsP0aTextKeys.sharePermanent, '永久')
                        : t.fileLinkFieldUnknown),
            ),
            _PropRow(
              link.isFolder ? t.fileLinkKindFolder : t.fileLinkKindFile,
              link.name.isEmpty ? link.path : link.name,
            ),
            if (link.linkOwner.isNotEmpty)
              _PropRow(t.fileLinkOwner, link.linkOwner),
            // ID 是排障用的：官方的分享链接操作（edit/delete/getinfo）全都要它
            _PropRow(t.fileLinkId, link.id),
          ],
        ),
        if (link.qrcode.isNotEmpty)
          AppSheetSection(
            label: t.fileLinkQrcode,
            children: [
              // ★ 真机实证：`qrcode` 是 `data:image/png;base64,…`（约 2 KB 的
              //   整段 base64）。当文本铺上去会把整屏吃掉 ⇒ 解成图片显示；
              //   解不出来才退回原文（**不假装有图**）。
              if (qrImageBytes(link.qrcode) case final bytes?)
                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Center(
                    child: Image.memory(
                      bytes,
                      key: const Key('share-link-detail-qr'),
                      width: 160,
                      height: 160,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) =>
                          TelemetryLabel(t.fileLinkQrcode, size: 11),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
                  child: TelemetryLabel(link.qrcode, size: 11),
                ),
            ],
          ),
        if (link.url.isNotEmpty)
          AppSheetSection(
            children: [
              AppSheetAction(
                key: const Key('share-link-detail-copy'),
                icon: Icons.content_copy_outlined,
                label: t.fileLinkCopyLink,
                description: link.url,
                onTap: () => _copy(context),
              ),
            ],
          ),
        AppSheetSection(
          children: [
            AppSheetAction(
              key: const Key('share-link-detail-edit'),
              icon: Icons.edit_outlined,
              label: fsGap(FsGapTextKeys.editShareLink, '编辑分享链接'),
              onTap: () => Navigator.of(context).pop('edit'),
            ),
            AppSheetAction(
              key: const Key('share-link-detail-delete'),
              icon: Icons.delete_outline,
              label: t.fileDeleteLink,
              danger: true,
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ],
    );
  }
}

/// P1-8：后台任务详情（官方 `BackgroundTaskFragment` 的 `DETAIL` 动作）。
///
/// 官方 DS file 的任务页对每个任务给 `DETAIL` / `RELOAD` / `retry`
/// （`BackgroundTaskFragment.java:825-851`）。我们这里先把**只读的详情**
/// 补上：服务端 `BackgroundTask.list` 每条任务本来就带 `api` / `method` /
/// `version` / `params` / `progress` / `errors`，展示它们是零风险纯客户端。
///
/// ⚠️ `retry`（M58，wave2 已补）：注册表里 `BackgroundTask` 只有 `list` /
/// `clear_finished`，没有重试方法；"重试"在官方是客户端**重新发**原任务
/// （用 `api`/`method`/`params` 再调一次），见 [showFileTaskDetailSheet] 的
/// `onRetry` 与 `file_task_retry.dart` 的 `fileTaskRetryPlan`。
/// P1-7：收藏条目的操作面板（**和普通文件面板分开**）。
///
/// 收藏行点开时官方给的是"打开 / 重命名 / 移除 / 属性"这一组
/// （`SYNO.FileStation.Favorite` 的 `edit` / `delete` 两个方法，见
/// `FileBrowser.js` 的收藏重命名对话框与 `del_favorite` 确认框）；
/// 它不该复用文件面板里的压缩/解压/分享那一堆（那些作用于**路径**，
/// 而收藏是 DSM 自己的一条记录）。
Future<String?> showFavoriteItemSheet(
  BuildContext context, {
  required FileEntryDto entry,
}) {
  final t = context.t;
  return showAppSheet<String>(
    context,
    title: entry.name,
    children: [
      AppSheetSection(
        children: [
          AppSheetAction(
            icon: Icons.folder_open_outlined,
            label: t.fileOpen,
            onTap: () => Navigator.of(context).pop('open'),
          ),
          AppSheetAction(
            icon: Icons.drive_file_rename_outline,
            label: fsC5(FsC5TextKeys.favoriteRename, '重命名收藏'),
            onTap: () => Navigator.of(context).pop('rename'),
          ),
          AppSheetAction(
            icon: Icons.star_border,
            label: t.photoUnfavorite,
            onTap: () => Navigator.of(context).pop('unfavorite'),
          ),
          AppSheetAction(
            icon: Icons.info_outline,
            label: t.fileProperties,
            onTap: () => Navigator.of(context).pop('properties'),
          ),
        ],
      ),
    ],
  );
}

/// M50：收藏**重排**对话框（纯客户端排序编辑）。
///
/// 官方 DS file 的 `Favorite` 有 `replace_all`（`api-server-authoritative.md:103`），
/// DSM 网页端的收藏重排就是"整体覆盖顺序"。这里只改本地顺序；真正的
/// `replace_all` 参数形态**尚未取证**，见
/// `FileStationApi.replaceAllFavorites` 与 `docs/filestation-gaps-wave2.md` §4。
///
/// 返回新顺序（`null` = 取消）。
Future<List<FileEntryDto>?> showFavoriteReorderSheet(
  BuildContext context, {
  required List<FileEntryDto> entries,
}) {
  return showDialog<List<FileEntryDto>>(
    context: context,
    builder: (context) => _FavoriteReorderDialog(entries: entries),
  );
}

class _FavoriteReorderDialog extends StatefulWidget {
  const _FavoriteReorderDialog({required this.entries});

  final List<FileEntryDto> entries;

  @override
  State<_FavoriteReorderDialog> createState() => _FavoriteReorderDialogState();
}

class _FavoriteReorderDialogState extends State<_FavoriteReorderDialog> {
  late List<FileEntryDto> _order = List<FileEntryDto>.from(widget.entries);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      key: const Key('favorite-reorder-dialog'),
      title: Text(fsGap2(FsGap2TextKeys.favoriteReorder, '重排收藏')),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _order.length,
          itemBuilder: (context, i) {
            final e = _order[i];
            return DesignRowTile(
              dense: true,
              leading: const Icon(Icons.drag_handle),
              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: Key('favorite-up-$i'),
                    tooltip: fsGap2(FsGap2TextKeys.moveUp, '上移'),
                    icon: const Icon(Icons.keyboard_arrow_up),
                    onPressed: i == 0
                        ? null
                        : () => setState(
                            () => _order = moveFavoriteUp(_order, i),
                          ),
                  ),
                  IconButton(
                    key: Key('favorite-down-$i'),
                    tooltip: fsGap2(FsGap2TextKeys.moveDown, '下移'),
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: i == _order.length - 1
                        ? null
                        : () => setState(
                            () => _order = moveFavoriteDown(_order, i),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          key: const Key('favorite-reorder-save'),
          onPressed: () => Navigator.of(context).pop(_order),
          child: Text(fsGap2(FsGap2TextKeys.favoriteReorderSave, '保存顺序')),
        ),
      ],
    );
  }
}

Future<void> showFileTaskDetailSheet(
  BuildContext context,
  FileTaskDto task, {
  Future<bool> Function()? onRetry,
}) {
  final t = context.t;
  // M58：只有"失败（服务端回了 errors）"且参数齐全的任务才给重试。
  // 参数是否齐全由 `fileTaskRetryPlan` 判定（它是纯函数，能重试才出按钮）。
  final canRetry = task.errors.isNotEmpty && fileTaskRetryPlan(task) != null;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // C5 遗留的 `fsC5TaskDetail`（"后台任务详情"）接在这里：这就是
            // 官方 DETAIL 对应的弹层（`BackgroundTaskFragment.java:825-851`），
            // 此前只有任务自己的 `label` 当标题，没有"这是详情"的说明。
            TelemetryLabel(
              fsC5(FsC5TextKeys.taskDetail, '后台任务详情'),
              key: const Key('file-task-detail-title'),
              color: DesignPalette.of(context).dim,
            ),
            const SizedBox(height: Gap.xxs),
            Text(task.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            // ⚠️ **内部 id 不上屏**（规程 §4.3：`async_task_id` 一类只允许出现在
            // Key / 请求 / 断言里）。`taskid` 只用于 `stop` / 重试的线参；
            // 官方 DETAIL（`BackgroundTaskFragment.smali:1748` 起）展示的是
            // `TransferItem.getTitle()` / `getTipMaster()` 这类**人读**信息，
            // **不显示 taskid**。所以这里不列 `taskid`。
            _PropRow('API', task.api),
            _PropRow('method', task.method),
            _PropRow('version', '${task.version}'),
            if (task.path.isNotEmpty) _PropRow('path', task.path),
            if (task.processingPath.isNotEmpty)
              _PropRow('processing', task.processingPath),
            // `crtime` 是服务端下发的 **epoch 秒**（真机读数 `1791397298`）。
            // 直接上屏既不人读、也和文件列表那套相对时间（`今天 01:39`）不一致；能解析
            // 就按同一套格式渲染，解析不了（字段异常）就退回原文 —— 宁可难看，不可编造。
            if (task.createdTime.isNotEmpty)
              _PropRow('crtime', _taskCrtimeLabel(task.createdTime)),
            _PropRow(
              'status',
              task.finished
                  ? t.calEnvDone
                  : '${(task.progress * 100).round()}%',
            ),
            if (task.params.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text(
                fsC5(FsC5TextKeys.taskDetailParams, '任务参数'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              // ★ 第 303 轮：口令类参数**打码显示**。真机实测服务端会把
              // `password` 原样回在 `BackgroundTask.list` 的 `params` 快照里
              // （任务详情页照原样渲染 ⇒ 屏幕上出现明文密码）。
              // 只改**显示**：重试计划仍用快照里的原值。
              for (final e in task.params.entries)
                _PropRow(
                  e.key,
                  isSecretTaskParamKey(e.key, value: '${e.value}')
                      ? fsGap2(
                          FsGap2TextKeys.taskParamSecretMasked,
                          '已隐藏（口令类参数不显示明文）',
                        )
                      : '${e.value}',
                ),
            ],
            const SizedBox(height: Gap.sm),
            Text(
              fsC5(FsC5TextKeys.taskDetailErrors, '任务错误'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (task.errors.isEmpty)
              _PropRow('', fsC5(FsC5TextKeys.taskNoError, '没有错误'))
            else
              for (final err in task.errors) _PropRow('${err.code}', err.path),
            // M58：官方 `BackgroundTaskFragment.java:849-851` 的 `retry`
            if (canRetry && onRetry != null) ...[
              const SizedBox(height: Gap.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('file-task-retry'),
                  icon: const Icon(Icons.refresh),
                  label: Text(fsGap2(FsGap2TextKeys.taskRetry, '重试')),
                  onPressed: () async {
                    Navigator.of(context).pop();
                    final ok = await onRetry();
                    if (!context.mounted) return;
                    AppSnack.show(
                      context,
                      ok
                          ? fsGap2(FsGap2TextKeys.taskRetrySubmitted, '已重新提交任务')
                          : fsGap2(
                              FsGap2TextKeys.taskRetryNoPlan,
                              '该任务缺少参数快照，无法重试',
                            ),
                      error: !ok,
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// 分享链接创建成功后展示链接（可复制 / **发送**）。
///
/// M37：官方 `ResourceListFragment.java:2095-2098` 创建后会把链接用
/// `EXTRA_SUBJECT` + chooser 发出去；这里补上「发送」（当前实现是邮件，
/// 见 `file_link_share.dart` 的说明与 `docs/filestation-gaps-wave1.md`）。
Future<void> showShareLinkCreatedSheet(
  BuildContext context,
  String url, {
  String subject = '',
}) {
  final t = context.t;
  return showDialog<void>(
    context: context,
    builder: (context) => Consumer(
      builder: (context, ref, _) => AlertDialog(
        title: Text(fsP0a(FsP0aTextKeys.shareCreatedTitle, '已创建分享链接')),
        content: SelectableText(url),
        actions: [
          TextButton(
            key: const Key('share-link-send'),
            onPressed: () async {
              final ok = await ref.read(linkShareProvider)(
                url: url,
                subject: subject,
              );
              if (!context.mounted) return;
              if (ok) {
                Navigator.of(context).pop();
              } else {
                AppSnack.show(
                  context,
                  fsGap(FsGapTextKeys.shareSendFailed, '发送失败（没有可用的应用）'),
                  error: true,
                );
              }
            },
            child: Text(fsGap(FsGapTextKeys.shareSend, '发送')),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(fsP0a(FsP0aTextKeys.shareCopyUrl, '复制链接')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.actionOk),
          ),
        ],
      ),
    ),
  );
}

/// 属性面板（大小 / 时间 / 属主 / 权限 / 真实路径）
Future<void> showFilePropertiesSheet(BuildContext context, FileEntryDto entry) {
  final t = context.t;
  String yesNo(bool v) => v ? t.photoYes : t.photoNo;
  return showAppSheet<void>(
    context,
    title: t.fileProperties,
    children: [
      AppSheetSection(
        label: entry.name,
        children: [
          _PropRow(
            t.photoKind,
            entry.isDir
                ? t.photoFolder
                : (entry.extension.isEmpty
                      ? t.chatFilterFile
                      : t.fileExtFile(entry.extension.toUpperCase())),
          ),
          _PropRow(t.filePropPath, entry.path),
          if (entry.size > 0)
            _PropRow(
              t.photoFileSize,
              t.filePropSizeWithBytes(entry.humanSize, '${entry.size}'),
            ),
          if (entry.mtime > 0)
            _PropRow(t.filePropModified, formatFileTime(entry.mtime, t: t)),
          if (entry.crtime > 0)
            _PropRow(t.filePropCreated, formatFileTime(entry.crtime, t: t)),
          if (entry.owner != null && entry.owner!.isNotEmpty)
            _PropRow(t.filePropOwner, entry.owner!),
          if (entry.group != null && entry.group!.isNotEmpty)
            _PropRow(t.filePropGroup, entry.group!),
          if (entry.mountPointType != null)
            _PropRow(t.filePropMountType, entry.mountPointType!),
          if (entry.realPath != null)
            _PropRow(t.filePropRealPath, entry.realPath!),
          _PropRow(
            t.filePropPerm,
            '${yesNo(entry.canRead)} / ${yesNo(entry.canWrite)}',
          ),
          _PropRow(t.filePropNoDownload, yesNo(entry.disableDownload)),
          if (entry.isWormShare) _PropRow('WORM', t.fileWormProtected),
        ],
      ),
      // WriteOnce / WORM（`SYNO.FileStation.Worm` v1，只读）。
      // 服务端没有这个 API / 未连接时**整块不出现**（门控在 provider 里）。
      FileWormPanel(entry: entry),
      // 图片的 EXIF / IPTC / XMP（`SYNO.FileStation.ThumbInfo / get`，只读）。
      // 不是图片 / API 缺失 / 未连接 / 取数失败 → 整块不出现。
      FileThumbInfoPanel(entry: entry),
      if (!entry.isDir)
        AppSheetSection(
          label: t.fileServerProbe,
          children: [
            FilePropertyExtras(entry: entry),
            FileMd5Panel(entry: entry),
          ],
        ),
    ],
  );
}

/// 属性面板里"要额外问服务端"的三行：占盘大小 / 真实修改时间 / 所有者。
///
/// 三项各自独立加载（`fileExtraPropsProvider` 里逐项 try），拿不到的只少一行，
/// 不会把整个面板变成错误页。
class FilePropertyExtras extends ConsumerWidget {
  const FilePropertyExtras({super.key, required this.entry});
  final FileEntryDto entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Property.* 只认真实路径（/volume1/...），虚拟路径会被服务端拒掉；
    // 列表里没带 real_path 时由 provider 自己 getinfo 补一次。
    final async = ref.watch(
      fileExtraPropsProvider((path: entry.path, realPath: entry.realPath)),
    );
    final extra = async.value;
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (async.isLoading && extra == null)
          _PropRow(t.filePropDiskSize, t.fileLoading),
        if (extra?.diskSize != null && extra!.diskSize! > 0)
          _PropRow(
            t.filePropDiskSize,
            t.filePropSizeWithBytes(
              formatSize(extra.diskSize!),
              '${extra.diskSize}',
            ),
          ),
        if (extra?.mtime != null && extra!.mtime! > 0)
          _PropRow(t.filePropRealModified, formatFileTime(extra.mtime!, t: t)),
        if (extra != null &&
            extra.realPath.isNotEmpty &&
            entry.realPath == null)
          _PropRow(t.filePropRealPath, extra.realPath),
        if (extra?.owner != null)
          _PropRow(t.filePropOwnerName, extra!.owner!.label)
        else if (extra?.ownerError != null)
          _PropRow(
            t.filePropOwnerName,
            t.fileOwnerUnavailable(extra!.ownerError!),
          ),
      ],
    );
  }
}

/// 图片的 EXIF / IPTC / XMP 元数据（属性面板用）。
///
/// ## 数据来源与门控
/// `SYNO.FileStation.ThumbInfo / get`（**只读**，真机实测 `{path:"/home"}` →
/// `{"exif":null,"iptc":null,"xmp":null}`，见 `filestation_api.dart` 的
/// [FileStationApi.thumbInfo]）。门控在 `fileThumbInfoProvider`：
///   * API 不在能力表 / 未连接 / 请求失败 → `null` ⇒ **整块不出现**；
///   * 服务端成功但三块都是 `null` → `isEmpty` ⇒ **明说**"不含元数据"（空态）。
///
/// ⇒ 这里绝不把"请求失败"渲染成"没有元数据"。
///
/// ## 为什么只对图片显示
/// 对 `.txt` / `.zip` 这类文件，元数据永远为空，天天在属性面板里挂一行
/// "不含 EXIF" 只是噪音；所以只在可能出现元数据的文件上出现
/// （位图 + RAW 相机格式，见 [showsThumbInfo]）。
class FileThumbInfoPanel extends ConsumerWidget {
  const FileThumbInfoPanel({super.key, required this.entry});

  final FileEntryDto entry;

  static String _s(String key, String zh) => fsGap5(key, zh);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!showsThumbInfo(entry)) return const SizedBox.shrink();
    // 先看能力位：API 缺失时**连 loading 行都不出现**，也不发请求
    final api = ref.watch(fileApiProvider);
    if (api == null || !api.canThumbInfo) return const SizedBox.shrink();

    final section = _s(FsGap5TextKeys.thumbInfoSection, '照片元数据');
    final async = ref.watch(fileThumbInfoProvider(entry.path));
    final info = async.value;

    if (info == null) {
      // 还在读 → 一行"正在读取"；读失败 → 整块消失（不冒充"没有元数据"）
      if (!async.isLoading) return const SizedBox.shrink();
      return AppSheetSection(
        label: section,
        children: [
          _PropRow('', _s(FsGap5TextKeys.thumbInfoLoading, '正在读取元数据…')),
        ],
      );
    }

    return AppSheetSection(
      label: section,
      children: [
        if (info.isEmpty)
          _PropRow(
            '',
            _s(FsGap5TextKeys.thumbInfoEmpty, '该文件不含 EXIF / IPTC / XMP 元数据'),
          )
        else
          for (final block in info.blocks)
            if (block.rows.isNotEmpty) ...[
              _ThumbBlockHeader(label: _blockLabel(block.kind)),
              for (final row in block.rows)
                _PropRow(
                  row.key.isEmpty ? '' : thumbInfoLabel(row.key).label(row.key),
                  row.value,
                ),
            ],
      ],
    );
  }

  static String _blockLabel(ThumbInfoKind kind) => switch (kind) {
    ThumbInfoKind.exif => _s(FsGap5TextKeys.blockExif, 'EXIF'),
    ThumbInfoKind.iptc => _s(FsGap5TextKeys.blockIptc, 'IPTC'),
    ThumbInfoKind.xmp => _s(FsGap5TextKeys.blockXmp, 'XMP'),
  };
}

/// 可能出现 EXIF / IPTC / XMP 的文件：位图白名单 ∪ **RAW 相机格式**。
///
/// `entry.showsThumbnail` 只认位图（`kImageExtensions`，不含 RAW），
/// 而 RAW 恰恰最常带完整 EXIF ⇒ 这里补上相机原始格式，避免"最该看到的看不到"。
const Set<String> kThumbInfoRawExtensions = {
  'cr2',
  'cr3',
  'nef',
  'nrw',
  'arw',
  'srf',
  'sr2',
  'dng',
  'raf',
  'rw2',
  'orf',
  'pef',
  'srw',
};

/// 属性面板要不要为这个条目显示元数据块。
bool showsThumbInfo(FileEntryDto e) =>
    !e.isDir &&
    (e.showsThumbnail || kThumbInfoRawExtensions.contains(e.extension));

/// 认得的标准元数据键 → 中文标签。
///
/// 键名同时收 **Exiv2 全名**（`Exif.Photo.FNumber` —— 服务端链接的是 Exiv2，
/// 见 `libwebfm.so` 的 `Exiv2::ExifData` 符号）与**常见短名**（`FNumber`），
/// 两种都认得；表里没有的键**原样显示原始键名**（不猜中文、不吞信息）。
class ThumbInfoLabel {
  const ThumbInfoLabel(this.key, this.zh);

  /// 文案 key（本批 [FsGap5TextKeys]）
  final String key;

  /// 中文原文（回落值）
  final String zh;

  /// 显示用的标签：认得就用本批文案，认不出就把 [raw] 原样返回。
  String label(String raw) {
    final t = fsGap5(key, zh);
    return t.isEmpty ? raw : t;
  }
}

const Map<String, ThumbInfoLabel> kThumbInfoLabels = {
  'Exif.Image.Make': ThumbInfoLabel('fsGap5ThumbInfoMake', '相机制造商'),
  'Make': ThumbInfoLabel('fsGap5ThumbInfoMake', '相机制造商'),
  'Exif.Image.Model': ThumbInfoLabel('fsGap5ThumbInfoCamera', '相机型号'),
  'Model': ThumbInfoLabel('fsGap5ThumbInfoCamera', '相机型号'),
  'Exif.Photo.LensModel': ThumbInfoLabel('fsGap5ThumbInfoLens', '镜头'),
  'LensModel': ThumbInfoLabel('fsGap5ThumbInfoLens', '镜头'),
  'Lens': ThumbInfoLabel('fsGap5ThumbInfoLens', '镜头'),
  'Exif.Photo.DateTimeOriginal': ThumbInfoLabel(
    'fsGap5ThumbInfoTakenAt',
    '拍摄时间',
  ),
  'Exif.Image.DateTime': ThumbInfoLabel('fsGap5ThumbInfoTakenAt', '拍摄时间'),
  'DateTimeOriginal': ThumbInfoLabel('fsGap5ThumbInfoTakenAt', '拍摄时间'),
  'DateTime': ThumbInfoLabel('fsGap5ThumbInfoTakenAt', '拍摄时间'),
  'Exif.Photo.FNumber': ThumbInfoLabel('fsGap5ThumbInfoAperture', '光圈'),
  'FNumber': ThumbInfoLabel('fsGap5ThumbInfoAperture', '光圈'),
  'ApertureValue': ThumbInfoLabel('fsGap5ThumbInfoAperture', '光圈'),
  'Exif.Photo.ISOSpeedRatings': ThumbInfoLabel('fsGap5ThumbInfoIso', 'ISO'),
  'Exif.Photo.PhotographicSensitivity': ThumbInfoLabel(
    'fsGap5ThumbInfoIso',
    'ISO',
  ),
  'ISOSpeedRatings': ThumbInfoLabel('fsGap5ThumbInfoIso', 'ISO'),
  'ISO': ThumbInfoLabel('fsGap5ThumbInfoIso', 'ISO'),
  'Exif.Photo.ExposureTime': ThumbInfoLabel('fsGap5ThumbInfoExposure', '曝光时间'),
  'ExposureTime': ThumbInfoLabel('fsGap5ThumbInfoExposure', '曝光时间'),
  'Exif.Photo.FocalLength': ThumbInfoLabel('fsGap5ThumbInfoFocalLength', '焦距'),
  'FocalLength': ThumbInfoLabel('fsGap5ThumbInfoFocalLength', '焦距'),
  'Exif.Image.Software': ThumbInfoLabel('fsGap5ThumbInfoSoftware', '软件'),
  'Software': ThumbInfoLabel('fsGap5ThumbInfoSoftware', '软件'),
  'Exif.Image.Orientation': ThumbInfoLabel('fsGap5ThumbInfoOrientation', '方向'),
  'Orientation': ThumbInfoLabel('fsGap5ThumbInfoOrientation', '方向'),
  'Exif.GPSInfo.GPSLatitude': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'Exif.GPSInfo.GPSLongitude': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'Exif.GPSInfo.GPSAltitude': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'Exif.GPSInfo.GPSLatitudeRef': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'Exif.GPSInfo.GPSLongitudeRef': ThumbInfoLabel(
    'fsGap5ThumbInfoGps',
    'GPS 位置',
  ),
  'GPSLatitude': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'GPSLongitude': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),

  // ---------------------------------------------------------------- 真机原文
  //
  // 下面是 2026-09-22 真机实测 `/home/Photos/手机备份/IMG_20260920_171030.jpg`
  // 时 `exif` 数组里**实际出现的 `name`**（截图
  // `docs/evidence-r17/06-file-thumbinfo-data-exif.png`）。
  //
  // ⚠️ 服务端给的 `name` 是**人话英文**（不是 `Exif.Photo.FNumber` 这种
  // Exiv2 全名），所以上面那批 Exiv2 键名在本机**其实命中不了**；真正要认的是
  // 这一批。两边都留着：别的机型/别的 DSM 版本回哪一种都接得住。
  //
  // 只映射**指名要的**那几项（相机型号 / 拍摄时间 / 光圈 / ISO / GPS / 焦距 /
  // 软件 / 方向 / 镜头 / 制造商）；其余（`Image Width`、`Exposure Program`、
  // `Metering Mode`、`Flash`…）**原样显示服务端的英文名** —— 不为了"全中文"
  // 去发明翻译，也不新增 ARB key。
  'Date and Time': ThumbInfoLabel('fsGap5ThumbInfoTakenAt', '拍摄时间'),
  'Date and Time (original)': ThumbInfoLabel('fsGap5ThumbInfoTakenAt', '拍摄时间'),
  'Exposure Time': ThumbInfoLabel('fsGap5ThumbInfoExposure', '曝光时间'),
  'Aperture': ThumbInfoLabel('fsGap5ThumbInfoAperture', '光圈'),
  'ISO Speed Ratings': ThumbInfoLabel('fsGap5ThumbInfoIso', 'ISO'),
  'Focal Length': ThumbInfoLabel('fsGap5ThumbInfoFocalLength', '焦距'),
  'GPS Latitude': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'GPS Longitude': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'GPS Altitude': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'GPS Latitude Reference': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'GPS Longitude Reference': ThumbInfoLabel('fsGap5ThumbInfoGps', 'GPS 位置'),
  'Lens Model': ThumbInfoLabel('fsGap5ThumbInfoLens', '镜头'),
};

/// 取某个原始键的标签；表里没有 → 原样返回键名本身。
ThumbInfoLabel thumbInfoLabel(String raw) =>
    kThumbInfoLabels[raw] ?? const ThumbInfoLabel('', '');

/// 元数据块的标题行（EXIF / IPTC / XMP）——`_PropRow` 的标签列太窄，单独一行。
class _ThumbBlockHeader extends StatelessWidget {
  const _ThumbBlockHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: hud.dim,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// WriteOnce / WORM 分区（属性面板用）。
///
/// 数据来自 `SYNO.FileStation.Worm` 的 `get_share_info`（共享级）+ `get`（逐路径），
/// **两个都是只读**。官方 Web 端在 `FileProperty.js` 里也是为属性面板加一个
/// "WriteOnce" tab（`WormPage`），只有 `is_worm_share` / `in_worm_share` 才出现。
///
/// ## 本实现的三条硬规则
/// 1. **没有 WORM ≠ 错误**：共享回 `def_lock_mode` ∈ {Manual, Normal} 时显示
///    **未启用**（官方 `setWormShareInfo` 的 disable 分支），**不显示任何错误文案**；
/// 2. **API 缺失就整块隐藏、不发探测**（门控在 [fileWormInfoProvider]）；
/// 3. **内部 path / pid 一律不上屏**：分区里只有模式名、启用态、时长与状态名。
class FileWormPanel extends ConsumerWidget {
  const FileWormPanel({super.key, required this.entry});
  final FileEntryDto entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(fileWormInfoProvider(entry.path)).value;
    if (info == null) return const SizedBox.shrink();
    String worm(String key, String zh) => fsGap4(key, zh);

    final share = info.share;
    final mode = _wormSubvolLabel(worm, share?.subvolMode);
    // "未启用" 只由官方判定（def_lock_mode ∈ {Immutable, Appendable}）得出，
    // 绝不由"请求失败"推出 —— 失败在 provider 里已经被吞成"未启用"的**显示**，
    // 而不是把错误当成结论。
    final enabled = info.autoLockEnabled;
    final state = _wormStateLabel(worm, info.pathStatus);

    return AppSheetSection(
      label: worm(FsGap4TextKeys.wormSection, 'WriteOnce'),
      children: [
        if (mode != null) _PropRow(worm(FsGap4TextKeys.wormMode, '模式'), mode),
        _PropRow(
          worm(FsGap4TextKeys.wormAutoLock, '自动锁定'),
          enabled
              ? worm(FsGap4TextKeys.wormEnabled, '已启用')
              : worm(FsGap4TextKeys.wormNotEnabled, '未启用'),
        ),
        if (enabled && share != null) ...[
          _PropRow(
            worm(FsGap4TextKeys.wormLockWaitTime, '自动锁定时间设置'),
            _wormInterval(worm, share.lockWaitTime),
          ),
          _PropRow(
            worm(FsGap4TextKeys.wormRetention, '锁定期间'),
            _wormInterval(worm, share.defLockDuration),
          ),
        ],
        if (state != null)
          _PropRow(worm(FsGap4TextKeys.wormLockState, '锁定状态'), state),
      ],
    );
  }
}

/// `subvol_mode` → 显示名。
///
/// ⚠️ Enterprise / Compliance **不臆造中文译名**：官方 JS 对这两个用的是
/// `_T("share","share_worm_mode_*")`（控制面板语言包，本 SPK 的 `ui/` 里没有），
/// 所以这里用官方枚举的字面英文名。未知值返回 null（**不显示这一行**，而不是瞎猜）。
String? _wormSubvolLabel(String Function(String, String) worm, int? mode) {
  switch (mode) {
    case FileWormSubVolMode.normal:
      return worm(FsGap4TextKeys.subvolNormal, 'Normal');
    case FileWormSubVolMode.enterprise:
      return worm(FsGap4TextKeys.subvolEnterprise, 'Enterprise');
    case FileWormSubVolMode.compliance:
      return worm(FsGap4TextKeys.subvolCompliance, 'Compliance');
    case FileWormSubVolMode.normalPlus:
      return worm(FsGap4TextKeys.subvolNormalPlus, 'Normal+');
    default:
      return null;
  }
}

/// `worm_state`（线上下标 0..9）→ 显示名 —— 组合方式照抄官方
/// `WormFieldset.getStateStr`（`锁定 (不可变)` 这种）。
///
/// 下标 `1`（NOT_IN_WORM_SHARE）/ `2`（CANNOT_BE_LOCKED）**不渲染**
/// —— 它们等价于"没有 WORM 状态"，上面那行"未启用"已经说清楚了。
String? _wormStateLabel(
  String Function(String, String) worm,
  FileWormPathStatus? status,
) {
  final wire = status?.state;
  if (wire == null) return null;
  String locked() => worm(FsGap4TextKeys.stateLocked, '锁定');
  String expired() => worm(FsGap4TextKeys.stateExpired, '已过期');
  final immutable = worm(FsGap4TextKeys.stateImmutable, '不可变');
  final appendOnly = worm(FsGap4TextKeys.stateAppendOnly, '可附加');
  switch (wire) {
    case FileWormState.wireUnknown:
      return worm(FsGap4TextKeys.stateUnknown, '未知');
    case FileWormState.wireOpen:
      return worm(FsGap4TextKeys.stateOpen, '开放');
    case FileWormState.wireImmutableLocked:
    case FileWormState.wireWeakImmutableLocked:
      return '${locked()} ($immutable)';
    case FileWormState.wireAppendableLocked:
    case FileWormState.wireWeakAppendableLocked:
      return '${locked()} ($appendOnly)';
    case FileWormState.wireImmutableExpired:
      return '${expired()} ($immutable)';
    case FileWormState.wireAppendableExpired:
      return '${expired()} ($appendOnly)';
    default:
      return null;
  }
}

/// 秒 → 人类可读区间。**分支结构逐条照抄官方**
/// `SYNO.webfm.utils.getWormIntervalStr`（`FileBrowserUtil.js`）：
/// `<60` 秒 · `<3600` 分 · `<86400` `H 小时 M 分` · `<3 天` `D 天 H 小时` ·
/// `<365 天` `D 天` · 其余 `Y 年 D 天`。
///
/// 负数（真机未设置时 `lock_wait_time` / `def_lock_duration` 回 **-1**）显示 `—`。
String _wormInterval(String Function(String, String) worm, int seconds) {
  if (seconds < 0) return worm(FsGap4TextKeys.wormUnset, '—');
  String unit(int n, String zh) => n <= 0 ? '' : '$n $zh';
  final sec = worm(FsGap4TextKeys.unitSecond, '秒');
  final min = worm(FsGap4TextKeys.unitMinute, '分');
  final hour = worm(FsGap4TextKeys.unitHour, '小时');
  final day = worm(FsGap4TextKeys.unitDay, '天');
  final year = worm(FsGap4TextKeys.unitYear, '年');
  if (seconds < 60) return unit(seconds, sec);
  final minutes = seconds ~/ 60;
  if (minutes < 60) return unit(minutes, min);
  final hours = minutes ~/ 60;
  if (hours < 24) {
    return '${unit(hours, hour)} ${unit(minutes - 60 * hours, min)}'.trim();
  }
  final days = hours ~/ 24;
  if (days < 3) {
    return '${unit(days, day)} ${unit(hours - 24 * days, hour)}'.trim();
  }
  if (days < 365) return unit(days, day);
  final years = days ~/ 365;
  return '${unit(years, year)} ${unit(days - 365 * years, day)}'.trim();
}

/// MD5 校验：**服务端算**（官方 Web 端同款：`start` → `status` → `stop`）。
///
/// ⚠️ 真机踩出来的关键事实（DSM 7.4 / DS923+，FileStation 1.5.1-2410）：
/// **MD5 任务的存活窗口只有几十毫秒** —— `start` 之后 25ms 查得到结果，
/// 50ms 之后就稳定回 `599`（任务已被回收）。官方 Web 端"每秒轮询"在这台机器上
/// 永远只能拿到 N/A；能用的姿势是：
///   `start` → **立刻** `status`（0ms，成功就结束）
///           → 没过就 20/50/100ms 再试
///           → 还是 599 就**整对重来**（最多 3 轮）
/// 所以这里不用 Timer.periodic，而是一串很短的立即重试。
class FileMd5Panel extends ConsumerStatefulWidget {
  const FileMd5Panel({super.key, required this.entry});
  final FileEntryDto entry;

  @override
  ConsumerState<FileMd5Panel> createState() => _FileMd5PanelState();
}

class _FileMd5PanelState extends ConsumerState<FileMd5Panel> {
  /// 关面板/销毁时还在算的任务号（仅用于 `stop`）
  String _pendingStop = '';

  /// `dispose()` 里不能再碰 `ref`（Riverpod 会直接抛），所以开始算的时候
  /// 把 API 存一份，销毁时用它去 `stop`。
  FileStationApi? _api;

  /// 复制成功后的短暂反馈（面板是模态的，SnackBar 会被挡在下面看不见，
  /// 所以直接把图标改成对勾）
  bool _copied = false;
  Timer? _copiedTimer;

  String _value = '';
  String? _error;
  bool _running = false;
  bool _disposed = false;

  /// 这个 NAS 上结果只活几十毫秒（实测 25ms 能查到、50ms 就被回收）。
  /// 所以：**先连着立刻查几拍**（手机首包/无线唤醒经常要几十毫秒，
  /// 前三拍常常只是"热身"），再逐步拉长间隔。
  static const List<int> _retryDelaysMs = [0, 0, 0, 5, 10, 20];

  @override
  void dispose() {
    _disposed = true;
    _copiedTimer?.cancel();
    final id = _pendingStop;
    _pendingStop = '';
    if (id.isNotEmpty) {
      unawaited(_api?.stopMd5(id).catchError((_) {}));
    }
    super.dispose();
  }

  bool _setStateSafe(VoidCallback fn) {
    if (_disposed || !mounted) return false;
    setState(fn);
    return true;
  }

  Future<void> _start() async {
    final t = context.t;
    final api = ref.read(fileApiProvider);
    _api = api;
    if (api == null) {
      setState(() => _error = t.setNotConnected);
      return;
    }
    setState(() {
      _running = true;
      _value = '';
      _error = null;
    });
    // 最多 4 轮"start + 立刻查"：任务被回收时整对重来
    for (var round = 0; round < 4; round++) {
      // 轮与轮之间稍等一下：任务被回收多半是"这一拍的往返刚好超过窗口"，
      // 连着打反而容易一起踩空；100ms 让无线/服务端那一侧换个节拍。
      if (round > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (_disposed) return;
      }
      String id;
      try {
        id = await api.startMd5([widget.entry.path]);
      } catch (err) {
        _setStateSafe(() {
          _running = false;
          _error = describeFileError(err);
        });
        return;
      }
      _pendingStop = id;
      if (id.isEmpty) continue;
      for (final delay in _retryDelaysMs) {
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
        if (_disposed) return;
        try {
          final st = await api.md5Status(id);
          _pendingStop = '';
          if (st.finished && st.md5.isNotEmpty) {
            _setStateSafe(() {
              _running = false;
              _value = st.md5;
            });
            return;
          }
          if (st.failed) {
            _setStateSafe(() {
              _running = false;
              _error = t.fileMd5FailedSome;
            });
            return;
          }
        } catch (err) {
          // 599 = 任务已被服务端回收 → 这一轮作废，整对重来
          if (err is DsmApiException && err.code == 599) break;
          _setStateSafe(() {
            _running = false;
            _error = describeFileError(err);
          });
          return;
        }
      }
    }
    _setStateSafe(() {
      _running = false;
      _error = t.fileMd5LostResult;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: TelemetryLabel('MD5', size: 11, color: hud.dim),
          ),
          Expanded(
            child: _running
                ? Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(
                          t.fileCalculating,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_value.isNotEmpty)
                        Row(
                          children: [
                            Expanded(
                              child: SelectableText(
                                _value,
                                key: const Key('file-md5-value'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                            IconButton(
                              key: const Key('file-md5-copy'),
                              tooltip: _copied ? t.fileCopied : t.dtoActionCopy,
                              iconSize: 18,
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: _value),
                                );
                                if (_disposed || !mounted) return;
                                setState(() => _copied = true);
                                _copiedTimer?.cancel();
                                _copiedTimer = Timer(
                                  const Duration(milliseconds: 1500),
                                  () {
                                    if (!_disposed && mounted) {
                                      setState(() => _copied = false);
                                    }
                                  },
                                );
                              },
                              icon: Icon(
                                _copied
                                    ? Icons.check_circle_outline
                                    : Icons.copy_outlined,
                              ),
                            ),
                          ],
                        )
                      else
                        Text(
                          _error ?? t.fileMd5Hint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _error == null ? hud.dim : hud.danger,
                          ),
                        ),
                      if (_value.isEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: const Key('file-md5-start'),
                            onPressed: _start,
                            child: Text(
                              _error == null ? t.fileCalculate : t.photoRetry,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 属性行
class _PropRow extends StatelessWidget {
  const _PropRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ★ 第 303 轮：参数名原来钉死 88dp（`TelemetryLabel` 是 maxLines:1 +
          // 省略号）⇒ 真机上 `dest_folder_path` 显示成 `dest_folder_p…`，而
          // 「任务参数」这一块的全部信息量就在键名上。改成**按比例分栏**：
          // 键占 4/10、值占 6/10（值可换行），宽屏键名不再被截。
          Flexible(
            flex: 4,
            child: TelemetryLabel(label, size: 11, color: hud.dim),
          ),
          const SizedBox(width: Gap.md),
          Flexible(
            flex: 6,
            child: Text(value, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// 上传进度框（与下载框同款，只是文案不同）
class UploadProgressDialog extends StatelessWidget {
  const UploadProgressDialog({
    super.key,
    required this.fileName,
    required this.progress,
  });

  final String fileName;
  final ValueNotifier<({int sent, int total})> progress;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t.fileUploading),
      content: ValueListenableBuilder<({int sent, int total})>(
        valueListenable: progress,
        builder: (context, p, _) {
          final unknown = p.total <= 0;
          final percent = unknown ? 0 : (p.sent * 100) ~/ p.total;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: Gap.lg),
              LinearProgressIndicator(value: unknown ? null : percent / 100),
              if (!unknown) ...[
                const SizedBox(height: Gap.sm),
                Text('$percent%', style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t.fileContinueInBackground),
        ),
      ],
    );
  }
}

/// 146（M26）：分卷压缩包提示条。
///
/// 纯展示 + 纯客户端识别（[detectArchiveVolume]），**不发任何请求**。
/// 第 1 卷 → 告诉用户"可以继续，服务端会读其余卷"；
/// 第 N>1 卷 → 明确让用户改选第 1 卷（并给出第 1 卷的文件名）。
class _VolumeNotice extends StatelessWidget {
  const _VolumeNotice({required this.volume});

  final ArchiveVolume volume;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final kind = switch (volume.kind) {
      ArchiveVolumeKind.rarPart => fsG4(
        FsG4TextKeys.volumeKindRarPart,
        'RAR 分卷（.partN.rar）',
      ),
      ArchiveVolumeKind.rarOld => fsG4(
        FsG4TextKeys.volumeKindRarOld,
        'RAR 老式分卷（.rNN）',
      ),
      ArchiveVolumeKind.numeric => fsG4(
        FsG4TextKeys.volumeKindNumeric,
        '数字分卷（.001/.002…）',
      ),
      ArchiveVolumeKind.zip => fsG4(
        FsG4TextKeys.volumeKindZip,
        'ZIP 分卷（.z01/.z02…）',
      ),
    };
    final title = volume.isFirst
        ? fsG4(FsG4TextKeys.volumeFirstTitle, '这是分卷压缩包的第 1 卷')
        : fsG4Fill(FsG4TextKeys.volumeLaterTitle, '这是第 {n} 卷，不能单独解压', {
            'n': '${volume.index}',
          });
    final body = volume.isFirst
        ? fsG4Fill(FsG4TextKeys.volumeFirstBody, '{kind}：NAS 会自动读取同目录下的其余分卷。', {
            'kind': kind,
          })
        : fsG4Fill(
            FsG4TextKeys.volumeLaterBody,
            '{kind}：请改选第 1 卷 “{first}” 再解压。',
            {'kind': kind, 'first': volume.firstVolumeName},
          );
    return Container(
      key: Key(
        volume.isFirst ? 'fs-extract-volume-first' : 'fs-extract-volume-later',
      ),
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: hud.surface,
        borderRadius: BorderRadius.circular(Gap.xs),
        border: Border.all(color: hud.dim.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.layers_outlined, size: 18, color: hud.dim),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `crtime`（服务端下发的是 **epoch 秒**）→ 与文件列表同一套相对时间
/// （`今天 01:39` / `昨天` / `09-18`）。
///
/// 真机（第 303 轮）读数：详情页原来直接把 `1791397298` 这种裸数字上屏 ——
/// 既不人读，也和同一 App 里文件列表的时间格式不一致。解析不了（字段异常）
/// 就**退回原文**：宁可难看，不可编造。
String _taskCrtimeLabel(String raw) {
  final seconds = int.tryParse(raw.trim());
  if (seconds == null) return raw;
  final label = formatFileTime(seconds);
  return label.isEmpty ? raw : label;
}
