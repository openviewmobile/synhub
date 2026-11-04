// 文件列表的一行。
//
// 与聊天列表同样的纪律：**行内不用 `BackdropFilter`**（几十行一起模糊会掉帧），
// 动效一律走 `AppEffects` 闸门。
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/i18n/l10n.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/file_entry_dto.dart';
import 'file_thumb.dart';
import 'filestation_c5_text.dart';
import 'filestation_gaps_wave1_text.dart';

/// 行尾/格子上的锁角标要说什么（M12）。
///
/// * 管理员禁了下载 → 「禁止下载」；
/// * 有 `perm` 且 `write=false`：共享根（`mount_point_type=shared_folder`）
///   说「只读共享」，普通条目说「只读」。
///
/// 证据：真机 `list_share` 回 `perm.acl`（`/home canWrite=true`、
/// `/docker=false`，`docs/device-verification.md:58-59`）；字段名 `perm.acl.write`
/// 已在 `FileEntryDto.fromJson` 解析，**不是猜的**。
String fileLockTooltip(BuildContext context, FileEntryDto entry) {
  final t = context.t;
  if (entry.disableDownload) return t.fileDownloadForbidden;
  if (entry.isMountPoint) return fsGap(FsGapTextKeys.readOnlyShare, '只读共享');
  return fsC5(FsC5TextKeys.readOnly, '只读');
}

/// 按扩展名给图标（DSM 的观感：文件夹 / 图片 / 视频 / 音频 / 压缩包 / 文档 / 表格 / 幻灯片）
IconData fileIconFor(FileEntryDto e) {
  // `#recycle` 就是**服务端列出来的普通目录名**（`#recycle` 在界面上显示成
  // 「回收站」，见 `_displayName`）；官方 `ResourceItemFactory.isRecycleBin()`
  // 也按这个名字换成回收站图标 ⇒ 这里对齐（第 327 轮 D27 一起补的）。
  if (e.name == RecyclePath.segment) return Icons.delete_outline;
  if (e.isDir) return Icons.folder_rounded;
  return switch (e.extension) {
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'heic' ||
    'heif' => Icons.image_outlined,
    'mp4' || 'mov' || 'mkv' || 'avi' || 'webm' || 'm4v' => Icons.movie_outlined,
    'mp3' ||
    'wav' ||
    'aac' ||
    'm4a' ||
    'ogg' ||
    'flac' => Icons.music_note_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    'zip' ||
    'rar' ||
    '7z' ||
    'tar' ||
    'gz' ||
    'bz2' => Icons.folder_zip_outlined,
    'doc' || 'docx' || 'odt' || 'rtf' => Icons.description_outlined,
    'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_outlined,
    'ppt' || 'pptx' || 'odp' => Icons.slideshow_outlined,
    'txt' ||
    'md' ||
    'log' ||
    'json' ||
    'xml' ||
    'yaml' ||
    'yml' => Icons.article_outlined,
    'dart' ||
    'java' ||
    'kt' ||
    'py' ||
    'js' ||
    'ts' ||
    'c' ||
    'cpp' ||
    'go' ||
    'rs' ||
    'sh' => Icons.code_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// 相对时间（`今天 10:50` / `昨天` / `09-18` / `2025-09-18`），与服务端 `time.mtime` 一致
///
/// 无 context 的调用方可以不传 [t]，缺省走 [currentText]（当前应用语言）。
String formatFileTime(int seconds, {DateTime? now, AppText? t}) {
  if (seconds <= 0) return '';
  final text = t ?? currentText();
  // ★ r716（`D22`）：不同套件的 epoch 单位不统一（文件站按**秒**，
  //   笔记/待办按**毫秒**下发）。这里按量级归一，避免"毫秒当秒再 ×1000"
  //   把时间画成 `2065-11-02`（未来 40 年）。
  //   只动**显示边界**：DTO 里的原值保持原样（待办回写 `due_date` 仍按毫秒）。
  final when = DateTime.fromMillisecondsSinceEpoch(
    seconds.abs() >= 100000000000 ? seconds : seconds * 1000,
  );
  final ref = now ?? DateTime.now();
  final today = DateTime(ref.year, ref.month, ref.day);
  final day = DateTime(when.year, when.month, when.day);
  final diff = today.difference(day).inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  if (diff == 0) {
    return text.fileTodayAt('${two(when.hour)}:${two(when.minute)}');
  }
  if (diff == 1) return text.fileYesterday;
  if (when.year == ref.year) {
    return '${two(when.month)}-${two(when.day)}';
  }
  return '${when.year}-${two(when.month)}-${two(when.day)}';
}

/// 网格视图里的一格：缩略图 + 文件名 + 一行元信息。
///
/// 与 [FileRow] 共用同一套交互（点/长按/菜单），只是把"行"换成"格"。
class FileGridTile extends StatelessWidget {
  const FileGridTile({
    super.key,
    required this.entry,
    this.onTap,
    this.onLongPress,
    this.onMenu,
    this.selecting = false,
    this.selected = false,
  });

  final FileEntryDto entry;
  final VoidCallback? onTap;

  /// ★ r671（`DA298`）：宽屏「双击直接打开」（窄屏不传：单击就是打开）。
  final VoidCallback? onLongPress;
  final VoidCallback? onMenu;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onMenu,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: LayoutBuilder(
                        builder: (context, c) => FileThumb(
                          entry: entry,
                          scale: ThumbScale.medium,
                          size: c.maxWidth,
                          iconSize: 34,
                          radius: 12,
                        ),
                      ),
                    ),
                    if (selecting && selected)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Icon(
                          Icons.check_circle_rounded,
                          size: 20,
                          color: scheme.primary,
                        ),
                      ),
                    // M12：只读 / 禁止下载也要在**网格视图**看得到（列表行有，
                    // 网格以前没有 —— 审计：用户在只读共享里看不出来）。
                    if (entry.isReadOnly || entry.disableDownload)
                      Positioned(
                        left: 4,
                        top: 4,
                        child: Tooltip(
                          message: fileLockTooltip(context, entry),
                          child: Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: hud.dim,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                entry.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!entry.isDir && entry.humanSize.isNotEmpty)
                TelemetryLabel(entry.humanSize, size: 10, color: hud.dim),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一行文件/文件夹。
class FileRow extends StatelessWidget {
  const FileRow({
    super.key,
    required this.entry,
    this.onTap,
    this.onLongPress,
    this.onMenu,
    this.selecting = false,
    this.selected = false,
    this.showThumbnail = true,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.pinned = false,
  });

  final FileEntryDto entry;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onMenu;

  /// 多选模式
  final bool selecting;
  final bool selected;

  /// 是否显示缩略图（网格视图自己做缩略图，列表行才用得到）
  final bool showThumbnail;

  /// 已收藏 → 行尾显示实心星；点了就是**取消收藏**（[onToggleFavorite] 非空时）。
  /// 未收藏时**不显示**空心星：一屏几十行都挂一颗星太吵，收藏入口留在操作菜单里
  /// （用户问过"已加入收藏的怎么删"，所以这里给出一个一眼可见、一点即删的入口）。
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;

  /// G4 / 219：已加入「离线文件」→ 行尾显示一枚小云标（一屏几十行都亮着
  /// 离线标会更吵，所以只用一枚 14px 图标，不加文字）。
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = DesignPalette.of(context);
    final text = context.t;
    final subtitle = _subtitle(text);

    return DesignRowShell(
      onTap: onTap,
      onLongPress: onLongPress,
      selected: selected,
      // 文件行的行尾有"体积 + 锁 + 离线 + 星 + ⋮"最多五件，比普通行挤；
      // 内边距按 16 收（普通行是 20），否则 360dp 窄屏会横向溢出。
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (selecting)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? scheme.primary : hud.dim,
              ),
            ),
          // 图片/视频/PDF 显示真缩略图，其余退回分类图标（见 `FileThumb`）
          if (showThumbnail)
            FileThumb(entry: entry)
          else
            FileIconTile(entry: entry, chamfer: false, radius: 11),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: DesignType.titleSmallSize,
                    fontWeight: FontWeight.w600,
                    color: hud.text,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: DesignType.bodySmallSize,
                      color: hud.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // ★ r492：行尾**不再重复体积** —— `_subtitle` 已经把「体积 · 时间 · 所有者」
          //   拼在一行了。旧写法在行尾再画一遍体积，窄屏上就是这 17–41px 的溢出源。
          if (entry.disableDownload || entry.isReadOnly)
            Padding(
              padding: const EdgeInsets.only(left: Gap.xs),
              child: Tooltip(
                message: fileLockTooltip(context, entry),
                child: Icon(Icons.lock_outline, size: 14, color: hud.dim),
              ),
            ),
          if (pinned)
            Padding(
              padding: const EdgeInsets.only(left: Gap.xs),
              child: Icon(
                Icons.cloud_done_outlined,
                key: const Key('file-row-offline-pinned'),
                size: 14,
                color: hud.dim,
              ),
            ),
          if (!selecting && isFavorite)
            IconButton(
              onPressed: onToggleFavorite,
              tooltip: onToggleFavorite == null
                  ? text.fileFavorited
                  : text.photoUnfavorite,
              iconSize: 18,
              color: scheme.primary,
              icon: const Icon(Icons.star_rounded),
            ),
          if (!selecting && onMenu != null)
            IconButton(
              onPressed: onMenu,
              tooltip: text.fileMoreActions,
              iconSize: 20,
              color: hud.dim,
              icon: const Icon(Icons.more_vert),
            )
          else if (!selecting && entry.isDir)
            Icon(Icons.chevron_right, size: 18, color: hud.dim),
        ],
      ),
    );
  }

  String _subtitle(AppText text) {
    final parts = <String>[];
    if (entry.isDir) {
      if (entry.isMountPoint) parts.add(text.fileSharedFolder);
    } else if (entry.humanSize.isNotEmpty) {
      parts.add(entry.humanSize);
    }
    final time = formatFileTime(entry.mtime, t: text);
    if (time.isNotEmpty) parts.add(time);
    if (entry.owner != null && entry.owner!.isNotEmpty) parts.add(entry.owner!);
    return parts.join(' · ');
  }
}
