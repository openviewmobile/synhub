// 笔记模块的文案与小组件（列表/详情/编辑器共用）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/hud_widgets.dart';
import 'note_body.dart' show NoteThumb, listRowThumbSlotHeight;
import '../../data/dto/note_dto.dart';
import '../../dsm/webapi.dart';
import '../files/file_row.dart' show formatFileTime;
import 'note_conflict_page.dart';
import 'note_sync.dart';
import '../../core/user_facing_error.dart';

/// 列表/网格卡片里的 `brief` 预览文本（**唯一**的一处换算）。
///
/// 为什么不能直接 `note.brief.trim()`（第 178 轮 / D10 实测，有真机像素 + 原始字节）：
/// 服务端给的 `brief` 会**中间带空行**。审计那台 NAS 上确凿的一条是
/// `"l1.png\n\nnf.png"`（附件行：两个 png 附件），而 `trim()` 只去首尾空白 ⇒
/// 预览在 `maxLines: 2` 下排成两个行盒：第一行 `l1.png`、**第二行是空的**。
/// 后果有两层：
///   ① 观感：这一行的 meta 被一个**看不见的空行**顶下去，和上下几行"行距不一致"
///      （`note_10.png` 第 4 行就是这个形态）；
///   ② 信息：`maxLines: 2` 的第二个行盒被空行占掉 ⇒ **第二个附件名 `nf.png`
///      根本显示不出来**。
/// 折叠空白行（不折普通空格）之后：`l1.png nf.png` 一行放得下 ⇒ 行距与其它行一致、
/// 而且多显示了一个名字。**不动字号、不动 `maxLines`、不动间距常量**（§2.0.18）。
String listBriefOf(String brief) => brief
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .join(' ');

/// 预览文本的词元切分：把 `.` `,` `/` `·` 空白等**非字母数字**都当分隔符，
/// 于是 `l1.png / nf.png` 与 `l1.png nf.png` 切出同一组词元。
final RegExp _previewTokenSplit = RegExp(r'[^0-9a-z\u4e00-\u9fff]+');

Set<String> _previewTokens(String s) => s
    .toLowerCase()
    .split(_previewTokenSplit)
    .where((t) => t.isNotEmpty)
    .toSet();

/// 预览**不提供任何标题里没有的信息**吗？
///
/// 判据：预览切出的词元**全部**已出现在标题里（`inPreview - inTitle` 为空）。
/// 切不出词元时（非拉丁 / 非 CJK 文字，如西里尔字母）绝不乱去重 —— 只认逐字相等。
bool _previewAddsNothing(String title, String preview) {
  final inPreview = _previewTokens(preview);
  if (inPreview.isEmpty) {
    // 词元切不出来（西里尔/阿拉伯等文字）⇒ 保守：只认逐字相等，绝不乱去重
    return _whitespaceFolded(title) == _whitespaceFolded(preview);
  }
  return inPreview.difference(_previewTokens(title)).isEmpty;
}

/// 只折「空白」的规范化（用于切不出词元时的逐字比较）。
String _whitespaceFolded(String x) =>
    x.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// 列表行 / 网格卡**真正要渲染**的预览（空串 = 这一行不渲染）。
///
/// 为什么要在 [listBriefOf] 之外再加这一跳（D10 真机只读探针 `/tmp/note_brief2.log`）：
/// 真数据里那条图片附件笔记 `title = "l1.png / nf.png"`、`brief = "l1.png\n\nnf.png"`
/// （就是两个附件的文件名）⇒ 预览 `l1.png nf.png` **一个字都不比标题多**，却要占掉
/// 一个 `bodySmall` 行盒（16dp）+ 2dp 间距 = **18.0dp**，于是「有图的那条」比
/// 1–3 行（`brief` 为空/`"\n"`）高出一整行 —— 这正是真机像素上"附件行三行、
/// 普通行两行"的机械来源。折叠空行（[listBriefOf]）修不了它，那是另一个现象。
///
/// ★ **不丢信息**：只有当预览里**每一个可见词元都已经在标题里**时才返回空；
///   标题仍然完整显示两个附件名（用例断言 `l1.png` 与 `nf.png` 都还在标题上，
///   并且标题 `didExceedMaxLines == false`）。标题为空（"无标题笔记"）时预览照常渲染。
String listBriefFor(String title, String brief) {
  final preview = listBriefOf(brief);
  if (preview.isEmpty) return '';
  return _previewAddsNothing(title, preview) ? '' : preview;
}

/// NoteStation 的错误码翻译。
///
/// ⚠️ 与聊天/文件的错误码**不完全同义**（真机实测）：
///   * `160` = 这个账号没被授予 **Note Station 应用权限**
///     （同一个账号 `session=NoteStation` 登录会被拒 402）；
///   * `402` = 应用权限被拒（登录阶段）；
///   * `120` = 参数形态不对（这些接口是 Gson 二次编码，字符串要带引号）。
String describeNoteError(Object error, [AppText? l10n]) {
  final t = l10n ?? currentText();
  if (error is DsmApiException) {
    switch (error.code) {
      case 160:
        return t.noteErrNoPermission;
      case 402:
        return t.noteErrAppDenied;
      case DsmErrorCode.requestParameterInvalid:
        return t.noteErrParam;
      case DsmErrorCode.apiNotFound:
      case DsmErrorCode.methodNotFound:
        return t.noteErrNotInstalled;
      case DsmErrorCode.notSupportedVersion:
        return t.noteErrVersion;
      case DsmErrorCode.sessionTimeout:
      case DsmErrorCode.sidNotFound:
        return t.errLoginExpired;
      default:
        return DsmErrorCode.describe(error.code, method: error.method);
    }
  }
  return userFacingError(error);
}

/// 离线 / 待同步横幅（笔记模块各页共用）。
///
/// 三种状态都要能一眼看出来：
///   * 离线（读的是缓存）：灰底 + "离线 · 显示上次同步的内容"；
///   * 有未同步的改动：橙底 + "N 条改动等联网后同步" + 立即同步；
///   * 正在同步：细进度条。
/// 双向冲突横幅：有冲突就显示一条可点的提示（点开裁决页）。
///
/// 和 [NoteOfflineBanner] 分开：离线是"状态"，冲突是"要你做个决定"，
/// 混在一起会让人以为等等就好。
class NoteConflictBanner extends ConsumerWidget {
  const NoteConflictBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final conflicts = ref.watch(noteSyncProvider).conflicts;
    if (conflicts.isEmpty) return const SizedBox.shrink();
    const accent = Color(0xFFE8A33D);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const Key('note-conflict-banner'),
        onTap: () => Navigator.of(context, rootNavigator: true).push<void>(
          MaterialPageRoute<void>(builder: (_) => const NoteConflictPage()),
        ),
        child: Container(
          width: double.infinity,
          color: accent.withValues(alpha: 0.16),
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.lg,
            vertical: Gap.sm,
          ),
          child: Row(
            children: [
              const Icon(Icons.call_split, size: 14, color: accent),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  context.t.noteConflictBanner(conflicts.length),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: hud.bg),
                ),
              ),
              const Icon(Icons.chevron_right, size: 16, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}

class NoteOfflineBanner extends ConsumerWidget {
  const NoteOfflineBanner({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final status = ref.watch(noteSyncProvider);
    final syncing = status.syncing;
    if (!status.offline && status.pending == 0 && !syncing) {
      return const SizedBox.shrink();
    }
    final accent = status.offline ? hud.dim : const Color(0xFFE8A33D);
    final t = context.t;
    final text = status.offline
        ? (status.pending > 0
              ? t.noteOfflineCachedPending(status.pending)
              : t.noteOfflineCached)
        : (status.pending > 0
              ? t.notePendingCount(status.pending)
              : t.noteSyncing);
    return Container(
      width: double.infinity,
      color: accent.withValues(alpha: 0.14),
      padding: EdgeInsets.fromLTRB(
        Gap.lg,
        compact ? 4 : Gap.sm,
        Gap.sm,
        compact ? 4 : Gap.sm,
      ),
      child: Row(
        children: [
          Icon(
            status.offline ? Icons.cloud_off : Icons.cloud_sync,
            size: 14,
            color: accent,
          ),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: accent),
            ),
          ),
          if (syncing)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
              ),
              onPressed: () => ref.read(noteSyncProvider.notifier).sync(),
              child: Text(
                context.t.noteSyncNow,
                style: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

/// 笔记本筛选条（"全部" + 各笔记本）
class NotebookChips extends StatelessWidget {
  const NotebookChips({
    super.key,
    required this.notebooks,
    required this.selected,
    required this.onSelect,
    this.countOf,
    this.onLongPress,
  });

  final List<NotebookDto> notebooks;
  final String? selected;
  final ValueChanged<String?> onSelect;

  /// 长按某个笔记本（管理：重命名 / 删除）
  final ValueChanged<NotebookDto>? onLongPress;

  /// 笔记本 id → 条数（没有就不显示）
  final int Function(String id)? countOf;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        children: [
          _Chip(
            label: context.t.noteAll,
            selected: selected == null,
            onTap: () => onSelect(null),
          ),
          for (final nb in notebooks)
            _Chip(
              label: countOf == null || countOf!(nb.objectId) == 0
                  ? nb.displayTitle
                  : '${nb.displayTitle} ${countOf!(nb.objectId)}',
              selected: selected == nb.objectId,
              onTap: () => onSelect(nb.objectId),
              onLongPress: onLongPress == null ? null : () => onLongPress!(nb),
            ),
          if (notebooks.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: Gap.sm),
              child: Center(
                child: Text(
                  context.t.noteNoNotebooks,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: Gap.sm),
      child: Center(
        child: Material(
          // ★ `DA186`：不透明 `primarySoft`（半透明叠底会掉到 4.4:1）
          color: selected
              ? p.primarySoft
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.md,
                vertical: 6,
              ),
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: selected ? p.primary : null,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 列表里的一行笔记
class NoteRow extends StatelessWidget {
  const NoteRow({
    super.key,
    required this.note,
    this.notebookTitle,
    this.onTap,
    this.onLongPress,
    this.selectable = false,
    this.selected = false,
  });

  final NoteDto note;
  final String? notebookTitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 列表处于多选模式（A12）：左侧显示勾选框
  final bool selectable;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = [
      if (notebookTitle != null && notebookTitle!.isNotEmpty) notebookTitle!,
      if (note.mtime > 0) formatFileTime(note.mtime),
      if (note.encrypt) context.t.noteEncrypted,
    ].join(' · ');
    final thumb = note.thumb;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selectable && selected
            ? scheme.primary.withValues(alpha: 0.12)
            : null,
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.md, Gap.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selectable)
              Padding(
                padding: const EdgeInsets.only(top: 2, right: Gap.sm),
                child: Icon(
                  selected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  key: Key('note-row-check-${note.objectId}'),
                  size: 20,
                  color: selected ? scheme.primary : hud.dim,
                ),
              ),
            if (thumb != null && thumb.isImage)
              // 封面缩略图（服务端在列表里就给了 `thumb_source`）
              NoteThumb(
                objectId: note.objectId,
                thumb: thumb,
                size: 40,
                maxSlotHeight: listRowThumbSlotHeight,
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  note.encrypt
                      ? Icons.lock_outline
                      : Icons.sticky_note_2_outlined,
                  size: 20,
                  color: note.encrypt ? hud.dim : scheme.primary,
                ),
              ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (listBriefFor(note.title, note.brief).isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      listBriefFor(note.title, note.brief),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                  ],
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    TelemetryLabel(meta, size: 10, color: hud.dim),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// F9：网格视图的卡片（官方 Web `DataView.Card` / `view_by:"card"` 的等价物）。
///
/// * 官方两个视图类是 `note_snippet`（列表）与 `note_card`（网格），由工具栏
///   `btn_note_display_mode` 切换，选择只存本地用户设置 `view_by`
///   （`ui/notestation.js`）—— **没有服务端 API**。
/// * 布局是自有实现（Flutter 与 ExtJS 无从逐像素对齐），字段沿用行视图：
///   封面缩略图 / 标题 / 摘要 / 元信息；**不显示任何内部 id**。
class NoteGridCard extends StatelessWidget {
  const NoteGridCard({
    super.key,
    required this.note,
    this.notebookTitle,
    this.onTap,
    this.onLongPress,
    this.selectable = false,
    this.selected = false,
  });

  final NoteDto note;
  final String? notebookTitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selectable;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = [
      if (notebookTitle != null && notebookTitle!.isNotEmpty) notebookTitle!,
      if (note.mtime > 0) formatFileTime(note.mtime),
      if (note.encrypt) context.t.noteEncrypted,
    ].join(' · ');
    final thumb = note.thumb;
    return Card(
      key: Key('note-grid-${note.objectId}'),
      margin: EdgeInsets.zero,
      color: selectable && selected
          ? scheme.primary.withValues(alpha: 0.12)
          : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(Gap.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (thumb != null && thumb.isImage)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: NoteThumb(
                      objectId: note.objectId,
                      thumb: thumb,
                      size: 64,
                    ),
                  ),
                )
              else
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(
                      note.encrypt
                          ? Icons.lock_outline
                          : Icons.sticky_note_2_outlined,
                      size: 28,
                      color: note.encrypt ? hud.dim : scheme.primary,
                    ),
                  ),
                ),
              const SizedBox(height: Gap.xs),
              Text(
                note.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (listBriefFor(note.title, note.brief).isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  listBriefFor(note.title, note.brief),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ],
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 4),
                TelemetryLabel(meta, size: 10, color: hud.dim),
              ],
              if (selectable)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    key: Key('note-grid-check-${note.objectId}'),
                    size: 18,
                    color: selected ? scheme.primary : hud.dim,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
