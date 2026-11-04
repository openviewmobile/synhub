// 「我的 Drive」来源的浏览视图（P0.1 尾巴）。
//
// 和 NAS 源的观感保持一致（切角图标框、行高、时间/大小），但内容模型不同：
// Drive 的路径是 `id:<file_id>`，条目是 `DriveEntryDto`。列表本身由
// `driveListProvider` 提供（`Files/list` v3）。
//
// 打开文件复用**同一套预览页**（图片/文本/PDF 内嵌、其余交系统应用）：
// 只是把字节来源换成 `Files/download` 的直链（`FileBytesRequest.url`）。
import '../../design/kit/design_kit.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'file_upload_picker.dart';

import '../../design/design_palette.dart';
import '../../core/media/aspect_image.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/drive_entry_dto.dart';
// DA13（r371）：Drive 原生上传失败时按 `DsmApiException` 分流，才引这一处
import '../../dsm/webapi.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../../data/drive_api.dart';
import '../../data/office_api.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../drive/drive_advance_sharing_page.dart';
import '../drive/drive_c1_text.dart';
import '../drive/drive_copy_move_page.dart';
import '../drive/drive_encrypt_gate.dart';
import '../drive/drive_gaps_stores.dart';
import '../drive/drive_gaps_text.dart';
import '../drive/drive_info_sheet.dart';
import '../drive/drive_p0_text.dart';
import '../drive/drive_text_editor_page.dart';
import 'drive_labels_page.dart';
import '../drive/drive_resumable_upload.dart';
import '../drive/drive_selection.dart';
import 'drive_providers.dart';
import 'office_providers.dart';
import 'drive_revisions_page.dart';
import 'drive_share_page.dart';
import 'file_providers.dart' show fileApiProvider, showsBookCover;
import 'file_preview_page.dart';
import 'drive_download.dart';
import 'office_export.dart';
import 'office_viewer_page.dart'
    show officeNativeFileStationPath, planOfficeDownload;
// 批 D 接线：把模板库 / 主题 / 只读版本列表接到 Drive 行菜单上（见 `_DriveRow`
// 的 `canOfficeTheme` / `canOfficeVersion` 与 `_onAction` 的对应分支）。
import '../office/office_library.dart' show officeLibraryText;
import '../office/office_library_page.dart';
import '../media/authed_image.dart';
import '../drive/drive_open_entry.dart' show driveOpenEntry;
import 'file_row.dart' show formatFileTime;
import 'file_sheets.dart' show UploadProgressDialog, promptFileName;
import 'file_thumb.dart' show FileIconTile, ThumbScale, looksLikeImage;

/// Drive 条目 → 预览页要的 `FileEntryDto`（路径用 `drive:` 前缀占位，
/// 真正的字节来源由 `bytesUrl` 给出）。
FileEntryDto driveEntryAsFile(DriveEntryDto e) => FileEntryDto(
  name: e.name,
  path: 'drive:${e.fileId}',
  isDir: e.isDir,
  size: e.size,
  mtime: e.modifiedTime,
);

/// Drive 列表/网格的**底部留白**（D15 / LD-S1 修复）。
///
/// 右下角是文件页 `Scaffold.floatingActionButton` 的 `OrbButton`
/// （默认 52×52，`FloatingActionButtonLocation.endFloat` 距底 16）⇒ FAB 的
/// 竖向占位 = 16 + 52 = 68。留白必须 ≥ 这个占位，否则滚到底时 FAB 会盖住
/// **最后一行的行菜单 `⋮`**（两者点击区一起重叠；macOS 走查
/// `f25_drive_root.png` / Linux `LD-S1` 的像素证据）。
/// 取 96 与文件页 `_body()` 的 `listBottom` 同值，多出的部分是安全间距。
const double kDriveListBottomInset = 96;

/// 右下角 `+`（文件页 `Scaffold.floatingActionButton` 的 `OrbButton`）的
/// **竖向占位** = 球直径 52 + `endFloat` 距底外边距 16。
///
/// ★ D15 真机补充修复（2026-…）：上面那条 `kDriveListBottomInset` 只是
/// **内容留白**，它只在"列表能滚动到尽头"时才能把最后一行顶离 FAB
/// —— 真机 Drive 根只有 4 项 + 一条引导横幅，列表接近/完全不可滚动，
/// 留白改变不了内容的落点，FAB 依旧压在行菜单 `⋮` 上。
/// 所以这里再加一层**视口级**避让：让列表视口的下沿整体高于 FAB 顶
/// （见 `_DriveBrowseViewState.build` 里包住列表的 `Padding`）。
const double kDriveFabFootprint = 52 + 16;

class DriveBrowseView extends ConsumerStatefulWidget {
  const DriveBrowseView({
    super.key,
    this.officeOnly = false,
    this.onWideSelect,
    this.wideSelectedId,
  });

  /// 「只看 Office 文档」视图（Drive「更多」页的 Office 入口用）。
  ///
  /// 过滤规则：只留 **Office 原生文档**（`.odoc/.osheet/.oslides`，判定走既有的
  /// [isOfficeNativeName]）**以及目录**。留下目录不是漏网：目录是**导航**而不是
  /// 文档——Office 文档通常放在子文件夹里，把目录一起藏掉会让这个入口只能停在
  /// 根目录、反而用不了。非 Office 的**文件**一律不显示。
  ///
  /// 只做过滤，**不新造查看器**：点开文档仍然走既有预览路径（`_DriveRow`）。
  final bool officeOnly;

  /// ★ r284 宽屏双栏：由 [FileBrowsePage] 在 **expanded** 时传入 —— 左栏
  /// Drive 的"点行"改为"填右栏"（不 push Drive 目录栈、不推预览路由）。
  ///
  /// `null`（默认：窄屏 / shell 的独立 Drive tab / Office 页 / 更多页）
  /// ⇒ `_DriveRow.openEntry()` 与改动前逐字节相同。**这里不含任何宽度判断**
  /// （宽度门只有 `adaptive_layout.dart` 一份）。
  final ValueChanged<DriveEntryDto>? onWideSelect;

  /// ★ r673：宽屏下**右栏信息卡正在显示的那一条**（按 `fileId`），左栏要亮起来。
  /// 与多选选中是两回事：这里只在 `onWideSelect != null`（宽屏）时有值。
  final String? wideSelectedId;

  /// 面包屑（`/` 分隔的个人空间路径；点某一节回退到那一层）
  static Widget breadcrumb(BuildContext context, WidgetRef ref) {
    final stack = ref.watch(driveStackProvider);
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    return SizedBox(
      height: 32,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: stack.length,
        itemBuilder: (context, i) {
          final isLast = i == stack.length - 1;
          final label = i == 0
              ? context.t.driveMyDrive
              : stack[i].split('/').last;
          return Row(
            children: [
              if (i > 0) Icon(Icons.chevron_right, size: 16, color: hud.dim),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                  minimumSize: const Size(0, 32),
                ),
                onPressed: isLast
                    ? null
                    : () => ref.read(driveStackProvider.notifier).popTo(i),
                child: Text(
                  label.isEmpty ? '/' : label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isLast ? theme.colorScheme.primary : hud.dim,
                    fontWeight: isLast ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  ConsumerState<DriveBrowseView> createState() => _DriveBrowseViewState();
}

class _DriveBrowseViewState extends ConsumerState<DriveBrowseView> {
  /// ★ r284：宽屏时把左栏行的"点行"交给 [DriveBrowseView.onWideSelect]；
  /// 窄屏（回调为 null）返回 null ⇒ `_DriveRow.openEntry()` 走原路径。
  ValueChanged<DriveEntryDto>? get _wideOverride {
    final cb = widget.onWideSelect;
    if (cb == null) return null;
    return cb;
  }

  @override
  void initState() {
    super.initState();
    // D81：异步读回"范围说明是否看过"。放在首帧之后，避免 build 期间改 provider
    // 状态；存储不可用时（桌面/单测无插件）`isSeen()` 返回 true，不会弹。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(driveScopeIntroProvider.notifier).preload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final drive = ref.watch(driveApiProvider);
    final path = ref.watch(driveStackProvider).last;
    if (drive == null) {
      return _Hint(
        icon: Icons.cloud_off_outlined,
        title: t.setNotConnected,
        detail: t.driveConnectHint,
        color: hud.dim,
      );
    }
    final list = ref.watch(driveListProvider(path));
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, __) {
        // ★ 第 256 轮真机缺陷修复（用户：「选了排序过滤条件之后界面出问题了，
        // 回不去了」）：
        //
        // 旧实现 error 分支**只渲染 `_Hint`**，排序工具栏整个消失 ⇒ 一旦
        // "列表失败的原因就是当前排序"，用户连改回「默认排序」的入口都没有，
        // 只能杀进程（排序是内存态，重启才复位）。
        //
        // 真机根因（只读实测，见 `docs/device-verification.md`）：
        // 「创建时间」会发 `sort_by=created_time`，而 **v3 拒这个键**
        // （`120 / sort_by / condition`），于是列表红 + 工具栏消失 = 死锁。
        // `DriveApi.list` 已改成该排序走 v2（根治）；
        // 这里再补一条"任何列表错误下都能改排序"的兜底，避免以后再出现同类死锁。
        final sort = ref.watch(driveSortProvider);
        final hint = _Hint(
          icon: Icons.error_outline,
          title: t.fileOpenDirFailed,
          detail: describeFileError(e),
          color: hud.dim,
          onRetry: () => ref.invalidate(driveListProvider(path)),
        );
        if (sort.by == null) return hint;
        return Column(
          children: [
            _DriveToolbar(mode: ref.watch(driveViewModeProvider)),
            OutlinedButton.icon(
              key: const Key('drive-sort-reset-on-error'),
              onPressed: () {
                ref.read(driveSortProvider.notifier).set(null);
                ref.invalidate(driveListProvider(path));
              },
              icon: const Icon(Icons.restart_alt),
              label: Text(
                driveC1Fill('sortResetOnError', '重置排序为「默认排序」并重试', const {}),
              ),
            ),
            Expanded(child: hint),
          ],
        );
      },
      data: (data) {
        final items = widget.officeOnly
            ? [
                for (final e in data.items)
                  if (e.isDir || isOfficeNativeName(e.name)) e,
              ]
            : data.items;
        if (items.isEmpty) {
          return _Hint(
            icon: widget.officeOnly
                ? Icons.description_outlined
                : Icons.folder_open_outlined,
            title: widget.officeOnly
                ? driveC1('officeDocsEmptyTitle', '这个目录里没有 Office 文档')
                : t.fileEmptyDir,
            detail: widget.officeOnly
                ? driveC1Fill(
                    'officeDocsEmptyDetail',
                    '「{path}」里没有 .odoc / .osheet / .oslides；可以返回上一层，或从「文件 → Drive」浏览全部内容',
                    {'path': path == kDriveRoot ? t.driveMyDrive : path},
                  )
                : (path == kDriveRoot ? t.driveEmptyPersonal : path),
            color: hud.dim,
            onRetry: () => ref.invalidate(driveListProvider(path)),
          );
        }
        final mode = ref.watch(driveViewModeProvider);
        // D81：只在个人空间**根**给一次范围说明；子目录不再打扰。
        final showScope =
            path == kDriveRoot && !ref.watch(driveScopeIntroProvider);
        return Column(
          children: [
            // ★ 第 56 轮 D25：多选模式下把排序工具栏**换成**选择工具栏。
            // 官方也是这个交互（长按进入选择模式，顶栏变为"已选 N 项"）。
            if (ref.watch(driveMultiSelectModeProvider))
              _DriveSelectionBar(path: path, items: items)
            else
              _DriveToolbar(mode: mode),
            if (showScope) const _DriveScopeCard(),
            Expanded(
              // ★ D15 真机补充修复（机制）：把**列表视口**整体抬到 FAB 之上。
              // 内容留白（`kDriveListBottomInset`）对"不可滚动的短列表"无效，
              // 只有缩小视口才能保证任何一行（含最后一行）都不会落进 FAB 的
              // 矩形里。`viewPadding.bottom` 与 `endFloat` 的抬升口径一致
              // （Scaffold 把 FAB 抬离底部安全区）。
              child: Padding(
                padding: EdgeInsets.only(
                  bottom:
                      kDriveFabFootprint +
                      MediaQuery.viewPaddingOf(context).bottom,
                ),
                child: RefreshIndicator(
                  onRefresh: () async => ref.invalidate(driveListProvider(path)),
                  child: mode == DriveViewMode.grid
                      ? GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          key: const Key('drive-grid'),
                          padding: const EdgeInsets.only(
                            bottom: kDriveListBottomInset,
                          ),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 140,
                                mainAxisSpacing: Gap.sm,
                                crossAxisSpacing: Gap.sm,
                                childAspectRatio: 0.82,
                              ),
                          itemCount: items.length,
                          itemBuilder: (context, i) => _DriveRow(
                            path: path,
                            entry: items[i],
                            grid: true,
                            selected:
                                items[i].fileId == widget.wideSelectedId ||
                                ref
                                    .watch(driveMultiSelectProvider(path))
                                    .contains(items[i].fileId),
                            selectionMode: ref.watch(
                              driveMultiSelectModeProvider,
                            ),
                            onOpenOverride: _wideOverride,
                          ),
                        )
                      : ListView.separated(
                          key: const Key('drive-list'),
                          padding: const EdgeInsets.only(
                            bottom: kDriveListBottomInset,
                          ),
                          itemCount: items.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) {
                            final sel = ref.watch(
                              driveMultiSelectProvider(path),
                            );
                            return _DriveRow(
                              path: path,
                              entry: items[i],
                              selected:
                                  items[i].fileId == widget.wideSelectedId ||
                                  sel.contains(items[i].fileId),
                              selectionMode: ref.watch(
                                driveMultiSelectModeProvider,
                              ),
                              onOpenOverride: _wideOverride,
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ------------------------------------------------------- D19 / D18 顶部工具条

/// Drive 列表顶部：排序菜单 + 列表/网格切换。
///
/// 为什么不复用 NAS 源 `file_browse_page` 的 `_Deck`：那套 `onSort`/`viewMode`
/// 绑的是 NAS 的 `fileSortProvider`/`fileViewModeProvider`，对 Drive 源不生效；
/// 本批把 Drive 的排序/视图状态独立成 `driveSortProvider`/`driveViewModeProvider`，
/// 就地放在 Drive 视图顶部（离数据更近，也不动文件模块的公共顶栏）。
/// ★ 第 56 轮 D25：**多选工具栏**（长按进入选择模式后顶替排序工具栏）。
///
/// 交互与官方一致：`已选 N 项` + 全选/取消全选 + 打包下载 + 退出。
/// 这里用 `ConsumerWidget` 而不是在父级 setState，是为了让"已选计数"
/// 只重建这一条，不整页重建。
class _DriveSelectionBar extends ConsumerWidget {
  const _DriveSelectionBar({required this.path, required this.items});

  final String path;
  final List<DriveEntryDto> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final sel = ref.watch(driveMultiSelectProvider(path));
    final allIds = [for (final e in items) e.fileId];
    // ★ 第 314 轮：判据用**当前可见**的 id 派生，不用 `sel.count`。
    // 若集合里混进了已不存在的 id（删除后未摘除的幽灵），
    // `sel.count == allIds.length` 会**永远为假** ⇒ 按钮标签错成「全选」。
    final selectedVisible = allIds.where(sel.contains).length;
    final allSelected = allIds.isNotEmpty && selectedVisible == allIds.length;
    final selectedEntries = [
      for (final e in items)
        if (sel.contains(e.fileId)) e,
    ];
    return Container(
      key: const Key('drive-selection-bar'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
      color: hud.dim.withValues(alpha: 0.06),
      child: Row(
        children: [
          IconButton(
            key: const Key('drive-selection-exit'),
            tooltip: t.actionCancel,
            icon: const Icon(Icons.close),
            onPressed: () {
              // 退出时**同时清空**该目录的选择 —— 否则下次长按会带着残留。
              ref.read(driveMultiSelectProvider(path).notifier).clear();
              ref.read(driveMultiSelectModeProvider.notifier).exit();
            },
          ),
          Text(
            // 「已选 N 项」
            driveC1Fill('selectedCount', '已选 {n} 项', {'n': '${sel.count}'}),
            key: const Key('drive-selection-count'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const Spacer(),
          TextButton(
            key: const Key('drive-selection-all'),
            onPressed: allIds.isEmpty
                ? null
                : () => ref
                      .read(driveMultiSelectProvider(path).notifier)
                      .toggleAll(allIds),
            child: Text(
              allSelected
                  ? driveC1('deselectAll', '取消全选')
                  : driveC1('selectAll', '全选'),
            ),
          ),
          IconButton(
            key: const Key('drive-selection-download'),
            tooltip: t.dtoActionDownload,
            // 一个都没选时禁用 —— 而不是让按钮消失（位置跳动会让用户误点）
            onPressed: selectedEntries.isEmpty
                ? null
                : () => driveDownloadArchive(
                    context,
                    ref,
                    entries: selectedEntries,
                    // 压缩包名取当前目录名（多文件时用）
                    folderName: path.split('/').where((e) => e.isNotEmpty).last,
                  ),
            icon: const Icon(Icons.download),
          ),
        ],
      ),
    );
  }
}

class _DriveToolbar extends ConsumerWidget {
  const _DriveToolbar({required this.mode});

  final DriveViewMode mode;

  static String _label(AppText t, DriveSortBy by) => switch (by) {
    DriveSortBy.name => driveGap(DriveGapTextKeys.sortName, '名称'),
    DriveSortBy.size => driveGap(DriveGapTextKeys.sortSize, '大小'),
    DriveSortBy.modifiedTime => driveGap(DriveGapTextKeys.sortModified, '修改时间'),
    DriveSortBy.createdTime => driveGap(DriveGapTextKeys.sortCreated, '创建时间'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final sort = ref.watch(driveSortProvider);
    final summary = sort.by == null
        ? driveGap(DriveGapTextKeys.sortDefault, '默认排序')
        : '${_label(context.t, sort.by!)}'
              '${sort.descending ? ' ↓' : ' ↑'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.xs),
      child: Row(
        children: [
          PopupMenuButton<String>(
            key: const Key('drive-sort-menu'),
            tooltip: driveGap(DriveGapTextKeys.sortTitle, '排序'),
            onSelected: (v) {
              final notifier = ref.read(driveSortProvider.notifier);
              switch (v) {
                case 'default':
                  notifier.set(null);
                case 'asc':
                  notifier.set(sort.by, descending: false);
                case 'desc':
                  notifier.set(sort.by, descending: true);
                default:
                  final by = DriveSortBy.values.firstWhere(
                    (e) => e.value == v,
                    orElse: () => DriveSortBy.name,
                  );
                  notifier.set(by, descending: sort.descending);
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                key: const Key('drive-sort-default'),
                value: 'default',
                checked: sort.by == null,
                child: Text(driveGap(DriveGapTextKeys.sortDefault, '默认排序')),
              ),
              for (final by in DriveSortBy.values)
                CheckedPopupMenuItem(
                  key: Key('drive-sort-${by.value}'),
                  value: by.value,
                  checked: sort.by == by,
                  child: Text(_label(context.t, by)),
                ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                key: const Key('drive-sort-asc'),
                value: 'asc',
                checked: sort.by != null && !sort.descending,
                child: Text(driveGap(DriveGapTextKeys.sortAscending, '升序')),
              ),
              CheckedPopupMenuItem(
                key: const Key('drive-sort-desc'),
                value: 'desc',
                checked: sort.by != null && sort.descending,
                child: Text(driveGap(DriveGapTextKeys.sortDescending, '降序')),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.sm,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort, size: 18, color: hud.dim),
                  const SizedBox(width: Gap.xs),
                  Text(
                    summary,
                    style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            key: const Key('drive-view-toggle'),
            tooltip: mode == DriveViewMode.grid
                ? driveGap(DriveGapTextKeys.viewList, '列表视图')
                : driveGap(DriveGapTextKeys.viewGrid, '网格视图'),
            icon: Icon(
              mode == DriveViewMode.grid
                  ? Icons.view_list_outlined
                  : Icons.grid_view_outlined,
              color: hud.dim,
            ),
            onPressed: () => ref.read(driveViewModeProvider.notifier).toggle(),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------- D81 首次运行范围说明

/// 首次进入个人空间时给一次的"范围说明"（我的文件 / 与我共享 / 团队文件夹）。
///
/// 看过之后落盘（见 `drive_gaps_stores.dart`），不再出现。三段各自的**入口**
/// 仍在「文件 → Drive → 更多」里，这里只解释"东西在哪"，不新造第二套导航。
class _DriveScopeCard extends ConsumerWidget {
  const _DriveScopeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    Widget line(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: hud.dim),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                children: [
                  TextSpan(
                    text: '$title ',
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: body),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return Material(
      key: const Key('drive-scope-intro'),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    driveGap(DriveGapTextKeys.scopeTitle, '这是你的「我的文件」，按范围分成三块'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                TextButton(
                  key: const Key('drive-scope-dismiss'),
                  onPressed: () =>
                      ref.read(driveScopeIntroProvider.notifier).dismiss(),
                  child: Text(driveGap(DriveGapTextKeys.scopeDismiss, '知道了')),
                ),
              ],
            ),
            Text(
              driveGap(DriveGapTextKeys.scopeIntro, '在「更多」里可以切换到另外两块范围：'),
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
            line(
              Icons.folder_outlined,
              driveGap(DriveGapTextKeys.scopeMyDriveTitle, '我的文件'),
              driveGap(DriveGapTextKeys.scopeMyDriveBody, '你自己的文件，只有你能看见。'),
            ),
            line(
              Icons.people_outline,
              driveGap(DriveGapTextKeys.scopeSharedTitle, '与我共享'),
              driveGap(DriveGapTextKeys.scopeSharedBody, '别人分享给你的单个文件或文件夹。'),
            ),
            line(
              Icons.groups_outlined,
              driveGap(DriveGapTextKeys.scopeTeamTitle, '团队文件夹'),
              driveGap(DriveGapTextKeys.scopeTeamBody, '整个团队共用的空间，成员按权限读写。'),
            ),
          ],
        ),
      ),
    );
  }
}

/// ★ r284 宽屏右栏：某个 Drive 目录的内容（`driveListProvider(path)`）。
///
/// 接入点见 `file_browse_page.dart` 的 `AdaptiveScaffold` —— **宽度门不在本
/// 类里**（本类不判窗口尺寸，断点仍只有 `adaptive_layout.dart` 一份）。
/// 它只负责：把该目录的行渲染出来，并把"点行"交给 [onSelect]（钻入/看详情）
/// 或 [onOpen]（文件 ⇒ 走既有预览入口）。**不 push Drive 目录栈**，
/// 所以右栏里点目录不会把左栏也带走。
class DriveWideFolderPane extends ConsumerWidget {
  const DriveWideFolderPane({
    super.key,
    required this.path,
    this.onSelect,
    this.onOpen,
    this.onUp,
  });

  /// Drive 的 `display_path`（与左栏 `driveStackProvider.last` 同一形态）。
  final String path;

  final ValueChanged<DriveEntryDto>? onSelect;
  final ValueChanged<DriveEntryDto>? onOpen;

  /// 右栏「上一级」——Drive 的父目录要服务端 `parentId`，右栏造不出来，
  /// 所以交给调用方用既有的 Drive 栈回退（DA291）。
  final VoidCallback? onUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveListProvider(path));
    return Column(
      children: [
        Container(
          key: const Key('file-wide-header'),
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
              onUp == null ? Gap.md : Gap.xs, Gap.xs, Gap.md, Gap.xs),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: hud.line)),
          ),
          child: Row(
            children: [
              if (onUp != null)
                IconButton(
                  key: const Key('file-wide-up'),
                  tooltip: t.fsC5Up,
                  onPressed: onUp,
                  icon: const Icon(Icons.arrow_back, size: 18),
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  padding: EdgeInsets.zero,
                ),
              Expanded(
                child: Text(
                  path.isEmpty ? t.driveMyDrive : path.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          // ★ 与左栏列表同一条机制：宽屏下 `+` 在**右栏**右下角 ⇒ 右栏列表
          //   视口也要抬到 FAB 之上（否则最后一行永远滚不进 FAB 上方）。
          child: Padding(
            padding: EdgeInsets.only(
              bottom:
                  kDriveFabFootprint +
                  MediaQuery.viewPaddingOf(context).bottom,
            ),
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, __) => _Hint(
                icon: Icons.cloud_off,
                title: t.fileWideContentsFailed,
                detail: describeFileError(e),
                color: hud.dim,
                onRetry: () => ref.invalidate(driveListProvider(path)),
              ),
              data: (data) {
                final items = data.items;
                if (items.isEmpty) {
                  return _Hint(
                    icon: Icons.folder_open_outlined,
                    title: t.fileEmptyFolder,
                    detail: path,
                    color: hud.dim,
                  );
                }
                return ListView.separated(
                  key: const Key('file-wide-drive-list'),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: hud.dim.withValues(alpha: 0.12),
                  ),
                  itemBuilder: (context, i) => _DriveRow(
                    path: path,
                    entry: items[i],
                    onOpenOverride: (d) => d.isDir
                        ? onSelect?.call(d)
                        : onOpen?.call(d),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _DriveRow extends ConsumerWidget {
  const _DriveRow({
    required this.path,
    required this.entry,
    this.grid = false,
    this.selected = false,
    this.selectionMode = false,
    this.onOpenOverride,
  });

  final DriveEntryDto entry;

  /// ★ 第 314 轮：本行所属目录的 `display_path` —— **必须**与
  /// `driveMultiSelectProvider(...)` 的 family key 一致，删除后摘除已选 id
  /// 才不会摘错目录（见 `_onAction` 的 `case 'delete'`）。
  final String path;

  /// `true` = 网格视图里的大缩略图卡片（D18）
  final bool grid;

  /// ★ 第 56 轮 D25：该行是否被多选选中。
  final bool selected;

  /// ★ 是否处于多选模式（长按进入）。
  final bool selectionMode;

  /// ★ r284 宽屏右栏（[DriveWideFolderPane]）用：把"点这一行"换成**填右栏**
  /// （不 push Drive 目录栈、也不推预览路由）；它自己在回调里决定钻入还是看详情。
  ///
  /// `null`（默认，= 左栏列表 / 独立 Drive tab / Office 页）⇒ 下面的
  /// `openEntry()` 与改动前**逐字节相同**。
  final ValueChanged<DriveEntryDto>? onOpenOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    // 能力位降级（S2）：可选 API 缺失时只隐藏对应功能，不隐藏整个模块。
    final availability = ref.watch(serviceAvailabilityProvider);
    final canShare = availability.hasApi(
      StationService.drive,
      kDriveSharingApi,
    );
    // Office 原生文档（`.odoc/.osheet/.oslides` + permanent_link）的版本历史
    // 走 `SYNO.Office.Node.Version`（见 `drive_revisions_page.dart`）；非 Office
    // 文件仍走 Drive 的 `Revisions`，不受这个能力位影响。
    final usesOfficeVersions =
        isOfficeNativeName(entry.name) && entry.permanentLink.isNotEmpty;
    final canOfficeVersion = availability.hasApi(
      StationService.office,
      kOfficeVersionApi,
    );
    // 批 D 接线（2026-09-22 裁决）：完整版本历史与只读版本列表**降级互补、
    // 任何情况下不同时出现**：
    //   * 完整页（可还原 / 命名 / 导出）只对「Office 原生文档 + permanent_link
    //     + 能力位在」出现——`drive_revisions_page.dart` 的 `_OfficeVersionsPage`
    //     分支正是按 `isOfficeNativeName && permanentLink.isNotEmpty` 进入；
    //   * 完整页不可用、而 Office 版本通道可用（`SYNO.Office.Node.Version`
    //     在能力表里）时，才显示「版本记录（只读）」作为**退化入口**：只读列表
    //     只按 `file_id` 取数、不需要 `permanent_link`，正好补上没有
    //     `permanent_link` 的 Office 文档（此前这类文档的 `revisions` 入口点了
    //     会落到 Drive 的 `Revisions` 并大概率报 1000 —— 那是坏的入口）；
    //   * 两者都不满足 → 都不显示。
    // 非 Office 文件的完整入口走 Drive `Revisions`，条件不变。
    final officeNative = isOfficeNativeName(entry.name);
    final officeFullVersions =
        officeNative && usesOfficeVersions && canOfficeVersion;
    final officeReadOnlyVersions =
        officeNative &&
        !officeFullVersions &&
        officeReadOnlyVersionsAvailable(availability);
    // 批 D 接线：「主题」入口。`Office.Theme` 不在 `service_registry` 的 Office
    // 向量里 → 走既有的**横切能力位** `apiPresent`（判定逻辑见
    // `office_library_page.dart` 的 `officeThemePickerAvailable`）。
    // 只对 `.oslides` 给入口：真机只取证过 `ntype=presentation`（17 套），
    // `.odoc/.osheet` 的 ntype 未取证 → 不给一个大概率报错的入口。
    final canOfficeTheme =
        entry.extension == 'oslides' &&
        officeThemePickerAvailable(availability);
    // C1：高级共享（匿名公开链接）与文件锁各自一个能力位；缺失 → 只隐藏
    // 对应菜单项，Drive 模块本身照常（`partial`，见 service_registry）。
    final canAdvanceSharing = availability.hasApi(
      StationService.drive,
      kDriveAdvanceSharingApi,
    );
    final canNodeLocking = availability.hasApi(
      StationService.drive,
      kDriveNodeLockingApi,
    );
    // C1：请求文件（FileRequest）——官方从**文件夹**发起（`path=id:<folder>`），
    // 所以只在目录行给入口。
    final canFileRequest = availability.hasApi(
      StationService.drive,
      kDriveFileRequestApi,
    );
    final menu = PopupMenuButton<String>(
      key: Key('drive-entry-menu-${entry.fileId}'),
      tooltip: t.photoMore,
      icon: Icon(Icons.more_vert, color: hud.dim),
      onSelected: (v) => _onAction(context, ref, v),
      itemBuilder: (_) => [
        // P0-10：文件详情/属性（官方 `Files/get` + `file_info_sheet`）
        PopupMenuItem(
          value: 'info',
          child: Text(driveP0(DriveP0TextKeys.infoTitle, '信息')),
        ),
        if (!entry.isDir)
          PopupMenuItem(value: 'download', child: Text(t.dtoActionDownload)),
        if (!entry.isDir)
          PopupMenuItem(value: 'open_with', child: Text(t.photoOpenWithOther)),
        if (entry.canWrite) ...[
          PopupMenuItem(value: 'rename', child: Text(t.photoRename)),
          PopupMenuItem(value: 'labels', child: Text(t.noteTags)),
        ],
        if (entry.canWrite)
          PopupMenuItem(
            value: 'star',
            child: Text(entry.starred ? t.driveUnstar : t.driveStar),
          ),
        if (!entry.isDir) ...[
          // Office L2（§11 第 ⑧ 项）：原生文档给"下载为 …"，
          // 能转换的上传文件给"转换为 Office 文档"（官方两种 id 白名单不同，
          // 详见 `office_export.dart` 的注释）
          if (isOfficeNativeName(entry.name))
            for (final f in officeExportFormatsFor(entry.name))
              PopupMenuItem(
                value: 'office_export_${f.code}',
                child: Text(t.driveDownloadAs(f.labelText())),
              ),
          if (isOfficeConvertibleName(entry.name))
            PopupMenuItem(
              value: 'office_convert',
              child: Text(t.driveConvertToOffice),
            ),
          // 批 D 接线：演示文稿的「主题」（`Office.Theme:list/apply`）。
          // 能力缺失（表里没有 `SYNO.Office.Theme`）→ 入口隐藏。
          if (canOfficeTheme)
            PopupMenuItem(
              value: 'office_theme',
              child: Text(officeLibraryText('officeThemeEntry', '主题')),
            ),
          // 完整版本历史：非 Office 文件照旧；Office 原生文档只在完整页真正
          // 可用时出现（见上面 `officeFullVersions` 的说明）。
          if (!officeNative || officeFullVersions)
            PopupMenuItem(
              value: 'revisions',
              child: Text(t.noteVersionHistory),
            ),
          // 批 D 接线：**退化**用的只读版本列表（`OfficeVersionListView`）。
          // 与上面的完整入口**互斥**：完整可用 → 只有完整；完整不可用而只读
          // 通道可用 → 只有只读；都不可用 → 都不显示。
          if (officeReadOnlyVersions)
            PopupMenuItem(
              value: 'office_versions_readonly',
              child: Text(
                officeLibraryText('officeVersionReadOnlyEntry', '版本记录（只读）'),
              ),
            ),
          if (canShare) PopupMenuItem(value: 'share', child: Text(t.noteShare)),
          // D59：纯文本文件（.txt/.md）的应用内编辑。
          // ★ r379（DA16）：官方**点行**就按体积分流进编辑器（≤1 MiB；
          // 逐字取证见 `kDriveTextEditorMaxBytes`）—— 菜单里这一项对**可写**
          // 文件仍然保留（>1 MiB 的 .txt 官方走阅读器，想编辑就得从这里进）。
          if (entry.canWrite && driveIsEditableText(entry.name))
            PopupMenuItem(
              value: 'edit_text',
              child: Text(driveGap(DriveGapTextKeys.editText, '编辑文本')),
            ),
        ],
        // C1：高级共享（公开链接）——文件夹也支持（官方 `path` 两种都收）
        if (canAdvanceSharing)
          PopupMenuItem(
            value: 'advance_sharing',
            child: Text(driveC1(DriveC1TextKeys.advanceSharing, '高级共享')),
          ),
        // C1：请求文件——官方入口在文件夹上（`path=id:<folder_id>`）
        if (canFileRequest && entry.isDir && entry.canWrite)
          PopupMenuItem(
            value: 'file_request',
            child: Text(driveC1(DriveC1TextKeys.newFileRequest, '请求文件')),
          ),
        // C1：文件锁——官方权限判定 `checkLockNode`：can_lock + can_write
        if (canNodeLocking &&
            entry.canLock &&
            entry.canWrite &&
            !entry.isLocked)
          PopupMenuItem(
            value: 'lock',
            child: Text(driveC1(DriveC1TextKeys.lock, '锁定')),
          ),
        if (canNodeLocking && entry.isLocked) ...[
          PopupMenuItem(
            value: 'unlock',
            child: Text(driveC1(DriveC1TextKeys.unlock, '解锁')),
          ),
          PopupMenuItem(
            value: 'request_unlock',
            child: Text(driveC1(DriveC1TextKeys.requestUnlock, '请求解锁')),
          ),
        ],
        if (entry.canWrite)
          PopupMenuItem(value: 'delete', child: Text(t.dtoActionDelete)),
        // P0-7：复制 / 移动到…（官方 `Files/copy|move` v2）。
        // 权限口径：官方要求 `can_write`（源可写/可操作）；目标目录的写权限
        // 交给服务端判（我们无法在选中前知道），失败按错误码如实提示。
        if (entry.canWrite) ...[
          PopupMenuItem(
            value: 'copy_to',
            child: Text(driveP0(DriveP0TextKeys.copyTo, '复制到…')),
          ),
          PopupMenuItem(
            value: 'move_to',
            child: Text(driveP0(DriveP0TextKeys.moveTo, '移动到…')),
          ),
        ],
      ],
    );

    void openEntry() {
      // ★ r284：宽屏右栏的行覆盖 —— 由右栏自己决定"钻入 / 看详情"，
      //   左栏列表（override == null）行为不变。
      final override = onOpenOverride;
      if (override != null) {
        override(entry);
        return;
      }
      if (entry.isDir) {
        ref.read(driveStackProvider.notifier).push(entry.displayPath);
      } else {
        _open(context, ref);
      }
    }

    // ★ 第 56 轮 D25：多选接线。
    // * 长按任意行 ⇒ 进入选择模式并**顺手选中这一行**（官方行为：
    //   长按本身就是"我要选它"，只进入模式不选会让用户以为没反应）；
    // * 选择模式下点行 ⇒ 切换选中，**不再打开/进目录**。
    final path = ref.watch(driveStackProvider).last;
    final selNotifier = ref.read(driveMultiSelectProvider(path).notifier);
    void toggleThis() {
      ref.read(driveMultiSelectModeProvider.notifier).enter();
      selNotifier.toggle(entry.fileId);
    }

    if (grid) {
      return _DriveGridTile(
        entry: entry,
        menu: menu,
        selected: selected,
        selectionMode: selectionMode,
        onTap: selectionMode ? toggleThis : openEntry,
        onLongPress: toggleThis,
      );
    }
    // ★ r131（macOS 逐屏走查，像素+框架断言取证）：这一行原来直接返回 `ListTile`。
    //   Drive 页面跑在外壳的 `FieldBackdrop` 里，而它中间夹了一层**带底色的
    //   `ColoredBox`** ⇒ Flutter 当场抛
    //   `ListTile background color or ink splashes may be invisible`
    //   （实测 `/home/Drive` 一屏 8 行 = 8 次断言；debug 下整屏报错，
    //    release 下"点了没有任何水波纹反馈"）。同一类坑本仓已在
    //   `drive_tasks_page` / `file_mount_page` / `file_offline_page` /
    //   `file_pages` / `webdav_page` 各修过一次，Drive 列表行漏了。
    //   修法固定：给 `ListTile` 补一层**透明 `Material`** 祖先。
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        onTap: selectionMode ? toggleThis : openEntry,
        onLongPress: toggleThis,
        leading: selectionMode
            ? Checkbox(
                key: Key('drive-select-${entry.fileId}'),
                value: selected,
                onChanged: (_) => toggleThis(),
              )
            : _DriveThumb(entry: entry),
        title: Text(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Text(
          [
            if (entry.isDir) t.photoFolder else entry.humanSize,
            if (entry.modifiedTime > 0)
              formatFileTime(entry.modifiedTime, t: t),
            if (entry.owner.isNotEmpty) entry.owner,
            if (entry.shared) t.photoShared,
            if (entry.starred) '★',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
        trailing: menu,
      ),
    );
  }

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    // 使用日志：Drive 行菜单里的每个动作都记一笔（`object` 只留扩展名）
    switch (action) {
      case 'info':
        // P0-10：详情面板（`Files/get` 拉最新，失败回落列表那份）
        await showDriveInfoSheet(context, ref, entry);
      case 'copy_to':
      case 'move_to':
        // P0-7：目标选择 + dry_run 冲突探测都在页内（见 drive_copy_move_page）
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) =>
                DriveCopyMovePage(entries: [entry], move: action == 'move_to'),
          ),
        );
      case 'download':
        await _download(context, ref, openAfter: false);
      case 'open_with':
        trackFile(ref, UsageModule.drive, UsageAction.openExternal, entry.name);
        await _download(context, ref, openAfter: true);
      case 'office_convert':
        await _convertOffice(context, ref, entry);
      case final a when a.startsWith('office_export_'):
        final code = a.substring('office_export_'.length);
        final format = OfficeExportFormat.values.firstWhere(
          (f) => f.code == code,
          orElse: () => OfficeExportFormat.pdf,
        );
        await _exportOffice(context, ref, entry, format);
      case 'revisions':
        // 版本历史：算"预览"的一个子场景，`detail.kind` 区分（免得动作枚举膨胀）
        trackFile(
          ref,
          UsageModule.drive,
          UsageAction.preview,
          entry.name,
          detail: {'kind': 'revisions'},
        );
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => DriveRevisionsPage(entry: entry)),
        );
      case 'office_theme':
        // 批 D 接线：主题选择 / 应用（只对 `.oslides` 出现，见 `canOfficeTheme`）
        trackFile(
          ref,
          UsageModule.drive,
          UsageAction.preview,
          entry.name,
          detail: {'kind': 'office_theme'},
        );
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => OfficeThemesPage(entry: entry),
          ),
        );
      case 'office_versions_readonly':
        // 批 D 接线：只读版本列表（`OfficeVersionListView`），复用既有版本通道
        trackFile(
          ref,
          UsageModule.drive,
          UsageAction.preview,
          entry.name,
          detail: {'kind': 'office_versions_readonly'},
        );
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => OfficeVersionsReadOnlyPage(entry: entry),
          ),
        );
      case 'share':
        trackFile(ref, UsageModule.drive, UsageAction.share, entry.name);
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => DriveSharePage(entry: entry)),
        );
      case 'edit_text':
        await _editText(context, ref);
      case 'labels':
        trackFile(ref, UsageModule.drive, UsageAction.addLabel, entry.name);
        final changed = await showDriveLabelPicker(context, ref, entry);
        if (changed) ref.invalidate(driveListProvider(kDriveRoot));
      case 'rename':
        final name = await promptFileName(
          context,
          title: t.photoRename,
          actionLabel: t.actionSave,
          initial: entry.name,
          helperText: t.driveRenameHelper,
        );
        if (name == null || name.isEmpty || name == entry.name) return;
        try {
          await drive.update(fileId: entry.fileId, name: name);
          trackFile(ref, UsageModule.drive, UsageAction.rename, entry.name);
          _refresh(ref);
          messenger.showSnackBar(SnackBar(content: Text(t.driveRenamed(name))));
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
        }
      case 'star':
        try {
          await drive.star(fileIds: [entry.fileId], starred: !entry.starred);
          trackFile(ref, UsageModule.drive, UsageAction.star, entry.name);
          _refresh(ref);
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
        }
      case 'advance_sharing':
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => DriveAdvanceSharingPage(
              path: entry.pathId,
              entryName: entry.name,
            ),
          ),
        );
      case 'lock':
      case 'unlock':
        try {
          await drive.setNodeLock(
            fileIds: [entry.fileId],
            lock: action == 'lock',
          );
          _refresh(ref);
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                action == 'lock'
                    ? driveC1(DriveC1TextKeys.locked, '已锁定')
                    : driveC1(DriveC1TextKeys.unlocked, '已解锁'),
              ),
            ),
          );
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                driveC1Fill(DriveC1TextKeys.lockFailed, '操作失败：{error}', {
                  'error': describeFileError(e),
                }),
              ),
            ),
          );
        }
      case 'request_unlock':
        try {
          await drive.requestNodeUnlock(path: entry.pathId);
          messenger.showSnackBar(
            SnackBar(
              content: Text(driveC1(DriveC1TextKeys.unlockRequested, '已请求解锁')),
            ),
          );
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                driveC1Fill(DriveC1TextKeys.lockFailed, '操作失败：{error}', {
                  'error': describeFileError(e),
                }),
              ),
            ),
          );
        }
      case 'file_request':
        // 官方 `editFileRequest()` 的 `getParams()`：title / identifier /
        // description / protect_password / due_date / has_due_date_hour
        // （drive_bundle.js:1640420）。本批收 title + identifier（D43），
        // 其余走默认（无有效期、无密码 —— 密码字段官方挂 encryption）。
        final title = await promptFileName(
          context,
          title: driveC1(DriveC1TextKeys.fileRequests, '请求文件'),
          actionLabel: t.actionSave,
          hintText: driveC1(DriveC1TextKeys.requestTitleHint, '例如：交作业'),
        );
        if (title == null || title.isEmpty) return;
        if (!context.mounted) return;
        final identifier = await _pickFileRequestIdentifier(context);
        if (identifier == null) return;
        try {
          final created = await drive.createFileRequest(
            folderId: entry.fileId,
            title: title,
            identifier: identifier,
          );
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                driveC1Fill(DriveC1TextKeys.requestCreated, '已创建请求链接：{url}', {
                  'url': created.url.isEmpty
                      ? created.sharingLink
                      : created.url,
                }),
              ),
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
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(t.driveDeleteConfirm),
            content: Text(t.driveDeleteBody(entry.name)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(t.actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(t.dtoActionDelete),
              ),
            ],
          ),
        );
        if (ok != true) return;
        try {
          await drive.delete(fileIds: [entry.fileId]);
          trackFile(ref, UsageModule.drive, UsageAction.delete, entry.name);
          // ★★ 第 314 轮真机缺陷（已修）：删掉的 id 必须**立刻从多选集合里摘掉**。
          // 只增量不清除会让界面显示「已选 N 项」而没有任何勾选（N 个 id 指向的
          // 文件都已删除），且武装态跨页残留（真机取证见 `drive_providers.dart`
          // 的 `remove()` 注释）。删除是本目录的一个**确定性事实**，所以在这里摘；
          // **不**在列表刷新时做"看不见就摘"——分页/搜索下会把合法选择误删。
          final selNotifier = ref.read(
            driveMultiSelectProvider(path).notifier,
          );
          final had = ref
              .read(driveMultiSelectProvider(path))
              .contains(entry.fileId);
          selNotifier.remove(entry.fileId);
          // 摘空之后退出选择模式：与 ✕ 的语义一致，不给用户留一个「已选 0 项」的空壳。
          if (had && ref.read(driveMultiSelectProvider(path)).isEmpty) {
            selNotifier.clear();
            ref.read(driveMultiSelectModeProvider.notifier).exit();
          }
          _refresh(ref);
          messenger.showSnackBar(
            SnackBar(content: Text(t.driveDeletedItem(entry.name))),
          );
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
        }
    }
  }

  /// D43：请求文件的"上传者目录命名策略"选择。
  ///
  /// 官方两个取值（`drive_bundle.js` 的 `identifierOptions`）：
  ///   * `create_folder_for_uploader` → `create_folder`（默认）
  ///   * `add_uploader_before_file` → `add_prefix`
  /// 返回 `null` = 用户取消（不发请求）。
  Future<String?> _pickFileRequestIdentifier(BuildContext context) async {
    final t = context.t;
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('drive-request-identifier-dialog'),
        title: Text(
          driveGap(DriveGapTextKeys.requestIdentifierTitle, '上传的文件怎么归类？'),
        ),
        children: [
          SimpleDialogOption(
            key: const Key('drive-request-identifier-create-folder'),
            onPressed: () => Navigator.of(ctx).pop('create_folder'),
            child: DesignRowTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(
                driveGap(
                  DriveGapTextKeys.requestIdentifierCreateFolder,
                  '为每个上传者建一个文件夹',
                ),
              ),
            ),
          ),
          SimpleDialogOption(
            key: const Key('drive-request-identifier-add-prefix'),
            onPressed: () => Navigator.of(ctx).pop('add_prefix'),
            child: DesignRowTile(
              leading: const Icon(Icons.label_outline),
              title: Text(
                driveGap(
                  DriveGapTextKeys.requestIdentifierAddPrefix,
                  '在文件名前加上传者名字',
                ),
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(),
            child: DesignRowTile(title: Text(t.actionCancel)),
          ),
        ],
      ),
    );
  }

  /// D59：打开纯文本编辑器，保存走 **Drive 自己的 `Files/create`**。
  ///
  /// ★★ r371（DA14）订正：原来保存借的是 **FileStation 上传**（先落临时文件，
  /// 再 `FileStation.Upload` 写回 `/home/Drive/…` 等 Drive 索引过去）。真机
  /// （r359）**2/2 都失败**：提示条原文 `Save failed: DSM 401: Account disabled`，
  /// 两个文件的字节数全程未变。同轮对照：同一个 FileStation 上传通道在
  /// 文件浏览页**成功**（新建 2/2、覆盖 1/1）⇒ 不是账号/权限问题，
  /// 而是"编辑器这条保存"的报文形态问题 ⇒ 不再借用那条通道。
  ///
  /// 现在改成与服务端 `create` 分支对齐的报文（[DriveApi.createTextFile]
  /// 里有逐字取证：参数名 `file_content` + **base64** + `conflict_action`）；
  /// 覆盖保存传 `conflict_action: 'version'` = 官方对"已存在文件"的默认策略
  /// （**新建一个版本**），这正是 Drive 的版本语义，而不是原地覆盖字节。
  /// 团队/共享空间也走同一条（`create` 认绝对路径，不依赖 FileStation 映射）。
  Future<void> _editText(
    BuildContext context,
    WidgetRef ref, {
    bool readOnly = false,
  }) async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    final url = drive.downloadUrl(fileId: entry.fileId);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DriveTextEditorPage(
          title: entry.name,
          readOnly: readOnly,
          loadText: () async {
            final bytes = await drive.api.getBytes(url);
            return utf8.decode(bytes, allowMalformed: true);
          },
          saveText: (text) async {
            await drive.createTextFile(
              path: entry.displayPath,
              textContent: text,
              conflictAction: 'version',
            );
          },
          onSaved: () => refreshDriveViews(ref),
        ),
      ),
    );
  }

  /// 「下载为 …」：`Office.Export/download`（官方 `exportNode` 那条路）
  Future<void> _exportOffice(
    BuildContext context,
    WidgetRef ref,
    DriveEntryDto entry,
    OfficeExportFormat format,
  ) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final fileName = await downloadOfficeAs(
        ref,
        fileId: entry.fileId,
        name: entry.name,
        format: format,
        t: t,
      );
      trackFile(
        ref,
        UsageModule.drive,
        UsageAction.download,
        entry.name,
        size: entry.size,
        detail: {'office_format': format.code},
      );
      messenger.showSnackBar(
        SnackBar(content: Text(t.driveExported(fileName))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.driveExportFailed(describeOfficeError(e, t)))),
      );
    }
  }

  /// 「转换为 Office 文档」：`Import/check`（可能问口令）→ `Import/convert`，
  /// 转出来的原生文档落在**同一个文件夹**（官方是弹"转换为…"选文件夹，
  /// 手机上一屏做不到那么细，先固定成同级 + `autorename` 防重名）。
  Future<void> _convertOffice(
    BuildContext context,
    WidgetRef ref,
    DriveEntryDto entry,
  ) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    var password = '';
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final converted = await convertToOfficeDocument(
          ref,
          fileId: entry.fileId,
          name: entry.name,
          parentId: entry.parentId,
          password: password,
          t: t,
        );
        refreshDriveViews(ref);
        messenger.showSnackBar(
          SnackBar(content: Text(t.driveConverted(converted))),
        );
        return;
      } on OfficeConvertException catch (e) {
        if (!e.needsPassword || attempt > 0) {
          messenger.showSnackBar(SnackBar(content: Text(e.message)));
          return;
        }
        if (!context.mounted) return;
        final input = await promptOfficePassword(context, name: entry.name);
        if (input == null) return;
        password = input;
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(t.driveConvertFailed(describeOfficeError(e, t))),
          ),
        );
        return;
      }
    }
  }

  /// 写操作后刷新当前目录（Drive 是索引型存储，删/改会有一两秒延迟）
  void _refresh(WidgetRef ref) => refreshDriveViews(ref);

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    // ⚠️ Office 原生文档（`.odoc` / `.osheet` / `.oslides`）**必须统一**走
    // `driveOpenEntry`。
    //
    // 真机缺陷（2026-09-22 截图 `/tmp/o8.png`、`/tmp/o10.png`）：本页此前直接
    // `openFilePreview`，于是**同一份文件**从「文件」tab 打开会落在
    // `office_viewer_page.dart` 里的**旧** `ODocView` / `OSheetView` /
    // `OSlidesView`（粗排版 + "只读预览"/"本批不支持编辑"/"版式从简"横幅），
    // 而从 `DriveFolderPage` / `DriveMorePage` / `DriveSearchPage` 打开却走
    // **新**的 `OfficeDocPage` / `OfficeSheetPage` / `OfficeSlidesPage`
    // （A4 纸面 / 真实网格 / 画布）。
    //
    // ⇒ **同一文件两套渲染器**，用户从「文件」tab 进 Office 文件
    //   **永远看不到新版式还原**。`driveOpenEntry` 是本函数的**超集**
    //   （三种 Office 分流到新页面，其余仍走同一个 `openFilePreview`），
    //   并且额外做官方的 `Files:access` 访问上报（`event_type:"preview"`），
    //   所以 Office 文件委托给它既修渲染器不一致，也补齐上报。
    if (isOfficeNativeName(entry.name)) {
      await driveOpenEntry(context, ref, entry);
      return;
    }
    // P0-11：Office 原生文档先探一次加密（`Office.Node.Encrypt:check`）；
    // 命中就弹官方那句提示并**不开**（我们拿不到解密凭据）。
    if (await driveWarnIfEncryptedOffice(context, ref, entry)) return;
    if (!context.mounted) return;
    // ★ r379（DA16）：`.txt`/`.md` 且 ≤1 MiB ⇒ 点行就进内建编辑器（官方
    // `openFile$lambda$5` 同款分流，逐字取证见 `kDriveTextEditorMaxBytes`）。
    // 无写权限时**仍然进编辑器**（官方也不看写权限），只是以只读打开、不给保存。
    if (driveTapOpenMode(name: entry.name, size: entry.size) ==
        DriveTapOpen.editor) {
      trackFile(ref, UsageModule.drive, UsageAction.preview, entry.name);
      await _editText(context, ref, readOnly: !entry.canWrite);
      return;
    }
    trackFile(ref, UsageModule.drive, UsageAction.preview, entry.name);
    final url = drive.downloadUrl(fileId: entry.fileId);
    openFilePreview(
      context,
      driveEntryAsFile(entry),
      bytesUrl: url,
      downloadUrl: url,
      // Office 文档的只读预览走服务端抽取正文（`Office.File.extract`
      // 只认这个 permanent_link）；它同时是 `Office.Snapshot:get` 的 `link_id`。
      officeLinkId: entry.permanentLink,
      // 取不到 permanent_link 时，Snapshot 通道按 `/mydrive/...` 现取一次
      // （**Drive API 只认 `/mydrive`**；`/home/Drive` 是 File Station 视角）。
      officeDrivePath: entry.displayPath,
      // 原生文档：优先 File Station 真实路径的原生字节（Drive 直链会转码）
      officeNativeBytesUrl: _nativeBytesUrl(ref),
    );
  }

  /// Office 原生文档的**原生字节**直链（File Station 真实路径）。
  ///
  /// 真机缺陷：Drive 的 `Files/download` 对 `.osheet` 回的是 xlsx 字节却仍叫
  /// `.osheet`。File Station 按 `home/Drive/...` 下载才是原生 OFile 字节。
  /// 拿不到真实路径（团队/共享目录映射未取证）时返回 `null`，交由调用方降级。
  String? _nativeBytesUrl(WidgetRef ref) {
    if (!isOfficeNativeName(entry.name)) return null;
    final path = officeNativeFileStationPath(
      dsmPath: entry.dsmPath,
      displayPath: entry.displayPath,
    );
    if (path == null) return null;
    return ref.read(fileApiProvider)?.downloadUrl([path]);
  }

  Future<void> _download(
    BuildContext context,
    WidgetRef ref, {
    required bool openAfter,
  }) async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    // 内容与文件名必须一致：原生文档优先走 File Station 原生字节；
    // 只能走 Drive 直链时，产物是 OOXML/PDF，文件名改成**真实扩展名**并提示。
    final nativeUrl = _nativeBytesUrl(ref);
    final plan = planOfficeDownload(
      name: entry.name,
      driveUrl: drive.downloadUrl(fileId: entry.fileId),
      nativeUrl: nativeUrl,
    );
    // ★ D26：改走**共享下载任务列表 + 断点续传引擎**（`.sydownload` + Range）。
    // 之前是 `api.getBytes(url)`：整份进内存、无进度、无暂停、断了从头再来，
    // 与官方 `ConnectionManager` 的 `Range: bytes=<已下>-` 语义不符。
    final useNative = plan.url == nativeUrl && nativeUrl != null;
    await downloadResumableWithUi(
      context,
      ref,
      // 续传 key：同一条目 + 同一条通道才算同一份下载
      // （Drive 直链与原生字节是两份不同内容，不能互相续）。
      resumeKey: useNative
          ? 'native:${entry.dsmPath}'
          : 'drive:${entry.fileId}',
      url: plan.url,
      saveName: plan.saveName,
      usageName: entry.name,
      usageSize: entry.size,
      channel: useNative
          ? DriveDownloadChannel.native
          : DriveDownloadChannel.drive,
      transcoded: plan.transcoded,
      openAfter: openAfter,
    );
  }
}

/// 写操作（改名/删除/星标/打标签/新建/上传）之后要作废的缓存。
///
/// 一律按**当前栈顶**作废，别写死 `/mydrive`：在子目录里操作时，
/// 写死根目录会出现"操作成功但界面不动"。
void refreshDriveViews(WidgetRef ref) {
  final path = ref.read(driveStackProvider).last;
  ref.invalidate(driveListProvider(path));
  ref.invalidate(driveTrashProvider(kDriveRoot));
  ref.invalidate(driveTrashSizeProvider(kDriveRoot));
  ref.invalidate(driveStarredProvider(''));
  ref.invalidate(driveSearchProvider(''));
}

// ------------------------------------------------- 新建 / 上传（Drive 源）

/// Drive 个人空间在磁盘上的真实目录（`/mydrive/x` ↔ `/home/Drive/x`）。
///
/// 为什么用 FileStation 上传而不是 `Files/upload`：
///   * 真机里 `Files/list|get` 的 **`dsm_path` 是空的**（服务端没回这个字段），
///     所以只能靠这条**官方文档化**的映射（个人空间 = `/home/Drive`）；
///   * Drive 的 `Files/upload` 是"defer upload"两段式协议（官方 Web 端先发一个
///     空 Blob 拿 upload session，再分块 PUT），参数形态没在真机上钉死之前
///     不猜；而"放到 `/home/Drive` 等守护进程索引（1–5 秒）"这条路
///     在真机上双向验过（`tool/drive_probe.dart seed`）。
///
/// 只对**个人空间**成立：团队文件夹/共享空间在磁盘上是别的挂载点，这里明确拒绝。
String? driveDsmFolderOf(String drivePath) {
  if (drivePath == kDriveRoot) return '/home/Drive';
  if (!drivePath.startsWith('$kDriveRoot/')) return null;
  final rest = drivePath.substring(kDriveRoot.length);
  if (rest.contains('..')) return null;
  return '/home/Drive$rest';
}

/// 「新建 / 上传」面板（Drive 源）：新建文件夹 / 上传文件
Future<void> showDriveCreateSheet(
  BuildContext context,
  WidgetRef ref,
  String path,
) async {
  final t = context.t;
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final hud = DesignPalette.of(ctx);
      return SafeArea(
        // 弹层的背景/描边交给 `Material`（ListTile 的 ink 需要 Material 祖先；
        // 有颜色的 DecoratedBox 夹在中间会让 ink 不可见，debug 下直接报错）
        child: Material(
          color: hud.surface2,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            side: BorderSide(color: hud.line, width: 1),
          ),
          // ★★ 第 64 轮：改成**可滚动**。
          // 加到 5 项后（含两个 Office 项），小屏 / 大字号下 `Column` 会
          // RenderFlex overflow —— 这是加本轮入口时被 widget 用例当场抓到的
          // （溢出 55px）。`shrinkWrap` 让内容少时仍只占自然高度。
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DesignRowTile(
                  key: const Key('drive-create-folder'),
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: Text(t.fileNewFolder),
                  subtitle: Text(t.fileNewFolderHint),
                  onTap: () => Navigator.of(ctx).pop('folder'),
                ),
                // D60：新建空文本文件（官方 `CreateAction.AddTextFile`）
                DesignRowTile(
                  key: const Key('drive-create-text'),
                  leading: const Icon(Icons.description_outlined),
                  title: Text(driveGap(DriveGapTextKeys.newTextFile, '文本文件')),
                  subtitle: Text(
                    driveGap(
                      DriveGapTextKeys.newTextFileHint,
                      '纯文本（.txt），可直接编辑',
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('text'),
                ),
                // ★ 第 257 轮：官方 Web 客户端的「新建」菜单（`ui.doc.js` /
                // `ui.drive.js` 的 `genCreateMenu`）是**三种类型** +
                // 「从模板」+「加密新建」两个子菜单，这里照同一套：
                //   `createNode({ntype:"doc"|"sheet"|"presentation"})`
                //   `openTplDialog({defaultType:"all"})`
                //   `create_encrypt` → `Encrypt.Window({ntype: …})` 四种（含模板）
                DesignRowTile(
                  key: const Key('drive-create-doc'),
                  leading: const Icon(Icons.article_outlined),
                  title: Text(
                    driveGap(
                      DriveGapTextKeys.newOfficeDoc,
                      'Synology Office 文档',
                    ),
                  ),
                  subtitle: Text(
                    driveGap(
                      DriveGapTextKeys.newOfficeDocHint,
                      '在线文档，可在任何设备继续编辑',
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('doc'),
                ),
                DesignRowTile(
                  key: const Key('drive-create-sheet'),
                  leading: const Icon(Icons.table_chart_outlined),
                  title: Text(
                    driveGap(
                      DriveGapTextKeys.newOfficeSheet,
                      'Synology Office 电子表格',
                    ),
                  ),
                  subtitle: Text(
                    driveGap(
                      DriveGapTextKeys.newOfficeSheetHint,
                      '在线表格，支持公式与协作',
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('sheet'),
                ),
                // ★ 演示文稿此前**没有入口**（旧判断"服务端只能 doc/sheet"是错的）
                DesignRowTile(
                  key: const Key('drive-create-slides'),
                  leading: const Icon(Icons.slideshow_outlined),
                  title: Text(
                    driveGap(
                      DriveGapTextKeys.newOfficeSlides,
                      'Synology Office 演示文稿',
                    ),
                  ),
                  subtitle: Text(
                    driveGap(
                      DriveGapTextKeys.newOfficeSlidesHint,
                      '在线幻灯片，支持演示与协作',
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('slides'),
                ),
                DesignRowTile(
                  key: const Key('drive-create-template'),
                  leading: const Icon(Icons.dashboard_customize_outlined),
                  title: Text(
                    driveGap(DriveGapTextKeys.newFromTemplate, '从模板新建…'),
                  ),
                  subtitle: Text(
                    driveGap(
                      DriveGapTextKeys.newFromTemplateHint,
                      '从官方模板库开始',
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('template'),
                ),
                DesignRowTile(
                  key: const Key('drive-create-encrypted'),
                  leading: const Icon(Icons.lock_outline),
                  title: Text(driveGap(DriveGapTextKeys.newEncrypted, '加密新建…')),
                  subtitle: Text(
                    driveGap(
                      DriveGapTextKeys.newEncryptedHint,
                      '文档 / 表格 / 演示文稿 / 模板 · 需设口令',
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('encrypted'),
                ),
                DesignRowTile(
                  key: const Key('drive-create-upload'),
                  leading: const Icon(Icons.upload_file_outlined),
                  title: Text(t.driveUploadFileTitle),
                  subtitle: Text(t.driveUploadSheetSubtitle),
                  onTap: () => Navigator.of(ctx).pop('upload'),
                ),
                const SizedBox(height: Gap.sm),
              ],
            ),
          ),
        ),
      );
    },
  );
  if (!context.mounted || action == null) return;
  final messenger = ScaffoldMessenger.of(context);
  switch (action) {
    case 'folder':
      final name = await promptFileName(
        context,
        title: t.fileNewFolder,
        actionLabel: t.photoCreate,
        helperText: t.driveCreateInPath(path),
      );
      if (name == null || name.isEmpty) return;
      final drive = ref.read(driveApiProvider);
      if (drive == null) return;
      try {
        await drive.createFolder(path: '$path/$name');
        track(ref, UsageModule.drive, UsageAction.create, objectType: 'folder');
        refreshDriveViews(ref);
        messenger.showSnackBar(SnackBar(content: Text(t.driveCreated(name))));
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
      }
    case 'upload':
      await driveUploadToCurrent(context, ref, path);
    case 'doc':
    case 'sheet':
    case 'slides':
      await _createOfficeNode(context, ref, path, switch (action) {
        'doc' => OfficeNodeType.doc,
        'sheet' => OfficeNodeType.sheet,
        _ => OfficeNodeType.presentation,
      });
    case 'template':
      await _createOfficeFromTemplate(context, ref, path);
    case 'encrypted':
      // 官方是「加密」子菜单（`create_encrypt`）里再选类型；手机上用一个
      // 二级面板，四选一后**先设口令**再建（官方也是先 `Encrypt.Window`）。
      final enc = await showDriveEncryptedCreateSheet(context);
      if (enc == null || !context.mounted) return;
      final pwd = await askOfficeEncryptPassword(context);
      if (pwd == null || !context.mounted) return;
      if (enc == 'template') {
        await _createOfficeFromTemplate(
          context,
          ref,
          path,
          encrypt: true,
          password: pwd,
        );
      } else {
        await _createOfficeNode(
          context,
          ref,
          path,
          switch (enc) {
            'doc' => OfficeNodeType.doc,
            'sheet' => OfficeNodeType.sheet,
            _ => OfficeNodeType.presentation,
          },
          encrypt: true,
          password: pwd,
        );
      }
    case 'text':
      // D60 + ★★ r371（DA12）：官方"新建文本文件"**不先建空文件**。
      // 官方 APK（3.9.0-1113）`BaseFileFragment.handleCreateAction` 里
      // `CreateAction.AddTextFile` → `checkDraftExist()`
      // （`smali_classes4/com/synology/dsdrive/fragment/BaseFileFragment.smali:1525`）
      // = 开一个**未保存的草稿编辑器**，文件在保存时才落盘。
      // 我们照此办理：问文件名 → 进编辑器（空内容草稿）→ 保存时
      // `Files/create`（`file_content` base64）真正建文件。
      // 于是"新建"与"编辑保存"落到**同一条**已取证的报文上。
      var name = await promptFileName(
        context,
        title: driveGap(DriveGapTextKeys.newTextFile, '文本文件'),
        actionLabel: t.photoCreate,
        helperText: t.driveCreateInPath(path),
      );
      if (name == null || name.isEmpty) return;
      if (!driveIsEditableText(name)) name = '$name.txt';
      final drive = ref.read(driveApiProvider);
      if (drive == null) return;
      final newTextPath = '$path/$name';
      final createdName = name;
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => DriveTextEditorPage(
            title: createdName,
            // 草稿：模型里没有内容，用户写完按保存才落盘
            loadText: () async => '',
            saveText: (text) async {
              await drive.createTextFile(
                path: newTextPath,
                textContent: text,
                // 新建用官方 Web 端建节点那条的冲突策略（`autorename`）
                conflictAction: 'autorename',
              );
            },
            onSaved: () {
              track(ref, UsageModule.drive, UsageAction.create, objectType: 'text');
              refreshDriveViews(ref);
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    driveGapFill(
                      DriveGapTextKeys.textCreated,
                      '已创建「{name}」',
                      {'name': createdName},
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
  }
}

/// 加密新建的**二级类型面板** —— 官方 `create_encrypt` 子菜单的四种类型的
/// 移动端形态（`ui.doc.js`：文档 / 表格 / 演示文稿 / 模板，四个都进
/// `SYNO.SDS.Office.Encrypt.Window`）。
Future<String?> showDriveEncryptedCreateSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final hud = DesignPalette.of(ctx);
      return SafeArea(
        child: Material(
          color: hud.surface2,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            side: BorderSide(color: hud.line, width: 1),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DesignRowTile(
                  key: const Key('drive-create-encrypted-doc'),
                  leading: const Icon(Icons.article_outlined),
                  title: Text(driveGap(DriveGapTextKeys.encryptedDoc, '加密的文档')),
                  onTap: () => Navigator.of(ctx).pop('doc'),
                ),
                DesignRowTile(
                  key: const Key('drive-create-encrypted-sheet'),
                  leading: const Icon(Icons.table_chart_outlined),
                  title: Text(
                    driveGap(DriveGapTextKeys.encryptedSheet, '加密的电子表格'),
                  ),
                  onTap: () => Navigator.of(ctx).pop('sheet'),
                ),
                DesignRowTile(
                  key: const Key('drive-create-encrypted-slides'),
                  leading: const Icon(Icons.slideshow_outlined),
                  title: Text(
                    driveGap(DriveGapTextKeys.encryptedSlides, '加密的演示文稿'),
                  ),
                  onTap: () => Navigator.of(ctx).pop('slides'),
                ),
                DesignRowTile(
                  key: const Key('drive-create-encrypted-template'),
                  leading: const Icon(Icons.dashboard_customize_outlined),
                  title: Text(
                    driveGap(DriveGapTextKeys.encryptedTemplate, '从模板新建（加密）'),
                  ),
                  onTap: () => Navigator.of(ctx).pop('template'),
                ),
                const SizedBox(height: Gap.sm),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 加密新建的**口令设置对话框** —— 逐字对齐官方
/// `SYNO.SDS.Office.Encrypt.Window`（`ui.doc.js` 的 `getEncryptFormPanel`）：
///
/// * 两个字段：`password` + `confirm_password`；
/// * 两个字段都是 `maxlength:32`（官方表单里的硬上限）；
/// * `allowBlank:false` ⇒ **空口令不放行**（本地先挡住，别让服务端报个
///   看不懂的码）。
///
/// 返回用户输入的口令；取消返回 `null`。
Future<String?> askOfficeEncryptPassword(BuildContext context) {
  final t = context.t;
  final pwd = TextEditingController();
  final confirm = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final hud = DesignPalette.of(ctx);
        return AlertDialog(
          key: const Key('drive-encrypt-password-dialog'),
          title: Text(
            driveGap(DriveGapTextKeys.encryptedPasswordTitle, '设置文档口令'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('drive-encrypt-password'),
                controller: pwd,
                autofocus: true,
                obscureText: true,
                maxLength: 32,
                decoration: InputDecoration(
                  labelText: driveGap(DriveGapTextKeys.encryptedPassword, '口令'),
                ),
                onChanged: (_) {
                  if (error != null) setLocal(() => error = null);
                },
              ),
              TextField(
                key: const Key('drive-encrypt-password-confirm'),
                controller: confirm,
                obscureText: true,
                maxLength: 32,
                decoration: InputDecoration(
                  labelText: driveGap(
                    DriveGapTextKeys.encryptedPasswordConfirm,
                    '确认口令',
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Text(
                    error!,
                    key: const Key('drive-encrypt-password-error'),
                    style: TextStyle(color: hud.danger),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t.actionCancel),
            ),
            FilledButton(
              key: const Key('drive-encrypt-password-ok'),
              onPressed: () {
                final value = pwd.text;
                if (value.isEmpty) {
                  setLocal(
                    () => error = driveGap(
                      DriveGapTextKeys.encryptedPasswordEmpty,
                      '口令不能为空',
                    ),
                  );
                  return;
                }
                if (value != confirm.text) {
                  setLocal(
                    () => error = driveGap(
                      DriveGapTextKeys.encryptedPasswordMismatch,
                      '两次输入的口令不一致',
                    ),
                  );
                  return;
                }
                Navigator.of(ctx).pop(value);
              },
              child: Text(t.photoCreate),
            ),
          ],
        );
      },
    ),
  );
}

/// 从模板新建（官方 `Office.Template:make`）。
///
/// * [encrypt]/[password]：官方 `makeTemplate` 的白名单里就有
///   `object_id,title,default_title,password,encrypt,parent_id,ver`
///   （`ui.doc.js`），所以"加密模板"与"普通模板"是**同一个方法**；
/// * `parent_id` 用**当前目录的 Drive 路径**（与真机取证过的 `/mydrive`
///   同一种形态；团队文件夹路径未在真机取证，失败会如实报错，不静默改道）。
Future<void> _createOfficeFromTemplate(
  BuildContext context,
  WidgetRef ref,
  String path, {
  bool encrypt = false,
  String password = '',
}) async {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  // ★ 第 258 轮：对齐官方的 `parent_id` 形态。
  //
  // 官方 `prepareMakeTemplate` 用的是 `getPathId(lastPathId)` = **`id:<file_id>`**
  // （与 `Office.Node/create` 同源）；本仓此前直接发**人类可读路径**。
  // 第 258 轮真 NAS 写探针把**两种形态都打了一遍**（都成功），
  // 所以这里换成官方形态**不是**在赌没验过的行为；好处是团队文件夹/共享目录
  // 这些"路径形态没取证过"的场景跟着一起稳。
  var parentId = kOfficeTemplateMakeParentId;
  if (path.isNotEmpty) {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      parentId = (await drive.get(path: path)).pathId;
      if (parentId.length <= 3) {
        // `'id:'` = 解析失败。宁可当场说清楚，也不发一个坏 parent_id
        //（服务端多半回 102/1000，用户看不懂）。
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              driveGap(
                DriveGapTextKeys.templateParentUnresolved,
                '无法定位当前文件夹，模板创建已取消',
              ),
            ),
          ),
        );
        return;
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
      return;
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => OfficeTemplateLibraryPage(
        parentId: parentId,
        encrypt: encrypt,
        password: password,
      ),
    ),
  );
}

/// ★ 第 64 轮 D56 / 第 257 轮扩到三种类型：在 [path] 目录下新建**空白**
/// Synology Office 文档 / 表格 / 演示文稿。
///
/// ## 为什么不能只传 `path`
/// `Office.Node/create` 的 `path` 要的是**父文件夹的 `id:<file_id>`**
/// （官方 `OfficeNodeCreateWork.byFileId` → `computePathById`），
/// 而我们这里是人类可读的 `/mydrive/…` ⇒ 必须先 `Files/get` 解析一次。
/// 解析拿不到（空/`'id:'`）时**直接报错，不要硬发** ——
/// 发一个坏 path 服务端多半回 102/1000，错误信息对用户毫无帮助。
///
/// ## 为什么显式走 v1
/// 服务端 `.lib` 里 `Office.Node` 的 **v2 没有 `create`**
/// （v2 = `touch`/`copy`）⇒ 照 `maxVersion` 协商必撞 103。
/// 详见 [OfficeApi.createNode] 与差距表附录 AZ。
///
/// ## 加密（[encrypt] / [password]）
/// 官方 Web 客户端把 `encrypt` 与 `password` 与 `ntype` 放进**同一个**
/// `create` 请求（白名单逐字见 [OfficeApi.createNode] 的注释）；
/// 安卓 APK 只做了非加密的两个类型，所以这条是**照 Web 客户端对齐**的。
Future<void> _createOfficeNode(
  BuildContext context,
  WidgetRef ref,
  String path,
  OfficeNodeType type, {
  bool encrypt = false,
  String password = '',
}) async {
  final label = switch (type) {
    OfficeNodeType.doc => driveC1('driveOfficeCreateDoc', 'Synology Office 文档'),
    OfficeNodeType.sheet => driveC1(
      'driveOfficeCreateSheet',
      'Synology Office 电子表格',
    ),
    OfficeNodeType.presentation => driveC1(
      'driveOfficeCreateSlides',
      'Synology Office 演示文稿',
    ),
  };
  final messenger = ScaffoldMessenger.of(context);
  final t = context.t;
  final title = await promptFileName(
    context,
    title: label,
    actionLabel: t.photoCreate,
    helperText: t.driveCreateInPath(path),
  );
  if (title == null || title.isEmpty) return;

  final drive = ref.read(driveApiProvider);
  final office = ref.read(officeApiProvider);
  if (drive == null || office == null) return;
  try {
    final folderId = (await drive.get(path: path)).pathId;
    if (folderId.length <= 3) {
      // `'id:'` 就是解析失败，别硬发：“引动不了目录”和“建文档失败”
      // 是两件事，分开报才知道该看哪里。
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveGap(DriveGapTextKeys.officeNodeNoFolderId, '无法解析当前目录，新建未执行'),
          ),
        ),
      );
      return;
    }
    await office.createNode(
      parentId: folderId,
      type: type,
      title: title,
      encrypt: encrypt,
      password: password,
    );
    track(ref, UsageModule.drive, UsageAction.create, objectType: type.value);
    refreshDriveViews(ref);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          driveGapFill(DriveGapTextKeys.officeNodeCreated, '已创建「{name}」', {
            'name': title,
          }),
        ),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
  }
}

/// ★ 第 56 轮 D25：**打包下载选中的一批文件**。
///
/// 与单文件 [driveEntryDownload] 的区别：
/// * 直链走 [DriveApi.downloadArchiveUrl]（多 id + `archive_name`，
///   官方 `min(7,max)` 那条分支，见附录 AR 的规格）；
/// * 名字由 [driveArchiveName] 推导并**清洗**（`/`、`:`、`?` 等
///   会进 `Content-Disposition`，不清洗就存不下来且**服务端不报错**）。
///
/// 选中的可以是文件夹：官方对文件夹同样按 id 打包，无需客户端递归。
Future<void> driveDownloadArchive(
  BuildContext context,
  WidgetRef ref, {
  required List<DriveEntryDto> entries,
  required String folderName,
}) async {
  final drive = ref.read(driveApiProvider);
  if (drive == null || entries.isEmpty) return;

  final name = driveArchiveName(
    selectedNames: [for (final e in entries) e.name],
    folderName: folderName,
  );
  final url = drive.downloadArchiveUrl(
    fileIds: [for (final e in entries) e.fileId],
    // 单文件时官方观感是"就是那个文件"，`archive_name` 反而不该乱起名；
    // 多文件才需要显式给压缩包名。
    archiveName: entries.length > 1 ? name : null,
  );
  var total = 0;
  for (final e in entries) {
    total += e.size;
  }
  // ★ D26：打包下载同样走**断点续传引擎**（`ConnectionManager` 对任何
  // `DownloadResponseVo` 都这么干）—— 压缩包动辄几百 MB，整份进内存既爆内存
  // 又断了从头来。续传 key 用"被选中的 id 列表"，同一批可续、换了批次不串。
  await downloadResumableWithUi(
    context,
    ref,
    resumeKey: 'archive:${[for (final e in entries) e.fileId].join(',')}',
    url: url,
    saveName: name,
    usageName: name,
    usageSize: total,
    openAfter: false,
  );
}

/// 上传手机本地文件到当前 Drive 目录。
///
/// ## ★ 第 53 轮：主路径切到 **Drive 自己的 `Files/upload`**
///
/// 旧实现走 FileStation（`fs.upload`），那**不是**官方做法（官方
/// `ApiSynoDriveFiles.java:43,84` 用的是 `SYNO.SynologyDrive.Files/upload`），
/// 而且有两个硬伤：**传不进团队文件夹**（旧代码对非个人空间直接提示
/// "不是个人空间"）、**大文件不能断点续传**。
///
/// 现在：先用 `Files/get` 解析当前目录的 `id:<file_id>`（`DriveEntryDto.pathId`），
/// 再交给 [driveResumableUpload] —— 它按官方两步流程决定走
/// 分片续传（大文件且 `Files.maxVersion >= 9`）还是整文件（版本 `min(8,max)`）。
///
/// ## 为什么"团队文件夹"跟着一起好了
/// Drive 上传的 `path` 是 `id:<folderId>/<name>`，**与目录在哪个产品域无关**
/// —— 只要能浏览到它、能拿到它的 file_id，就能往里传。旧实现是因为
/// `driveDsmFolderOf` 只能映射 `/mydrive/**` 才传不进去的。
///
/// ## 回退策略（不静默）
/// 解析目录 id 失败（例如老服务端 / 目录已被删）时，**退回旧的 FileStation 路径**
/// 并保持原有提示，而不是让上传直接失败。
Future<void> driveUploadToCurrent(
  BuildContext context,
  WidgetRef ref,
  String path,
) async {
  final t = context.t;
  final dsmFolder = driveDsmFolderOf(path);
  final fs = ref.read(fileApiProvider);
  final drive = ref.read(driveApiProvider);
  if ((dsmFolder == null && drive == null) || fs == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t.driveUploadNotPersonal)));
    return;
  }
  // ★ r371（DA13）：选择器改走 `fileUploadPickerProvider`（r319 给 Files 页
  //   抽的同一条缝）——**默认实现逐字就是原来的 `FilePicker.pickFile()`**，
  //   生产行为不变；抽缝的目的是让"Drive 原生上传失败 ⇒ 退回 FileStation"
  //   这条整链能在 Mock 里被真的跑一遍（原生面板在自动化里点不到）。
  final picked = await ref.read(fileUploadPickerProvider)();
  final localPath = picked?.path;
  if (picked == null || localPath == null || !context.mounted) return;

  final progress = ValueNotifier<({int sent, int total})>((
    sent: 0,
    total: picked.size ?? 0,
  ));
  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        UploadProgressDialog(fileName: picked.name, progress: progress),
  );
  // ★ 先试 Drive 原生上传（官方做法，支持团队文件夹 + 大文件续传）；
  // 目录 id 解析不了再退回 FileStation。
  String? folderId;
  if (drive != null) {
    try {
      final resolved = (await drive.get(path: path)).pathId;
      // ★ 必须校验非空：`DriveEntryDto.pathId` 是 `'id:$fileId'`，
      // 回包缺 `file_id` 时会得到 `'id:'` —— 拿它去上传只会得到
      // `id:/<name>` 这种无意义落点并失败。宁可退回 FileStation。
      if (resolved.length > 3) folderId = resolved;
    } catch (_) {
      folderId = null;
    }
  }
  // ★★ r371（DA13）：真正发出去的是哪条通道 —— 记进埋点 detail，
  //   别让"看起来成功了"掩盖"走的不是 Drive 原生通道"。
  var via = folderId != null ? 'drive' : 'filestation';
  try {
    if (drive != null && folderId != null) {
      try {
        await driveResumableUpload(
          drive,
          folderId: folderId,
          filePath: localPath,
          fileName: picked.name,
          // 任务 id 用「时间戳 + 文件名」：官方是服务端驱动的 taskId，
          // 我们这边只需**同一次上传的探测与续传用同一个值**。
          taskId: '${DateTime.now().microsecondsSinceEpoch}-${picked.name}',
          onProgress: (sent, total) =>
              progress.value = (sent: sent, total: total < 0 ? 0 : total),
        );
      } on DsmApiException catch (e) {
        // ★★ DA13（r359 真机）：Drive 自己的 `Files/upload` 通道**必失败**
        //   （提示条原文 = 裸码 `Error code 1003`），根因本轮仍未在服务端侧
        //   钉死；而同一账号 / 同一目标走 FileStation 上传是**真机验过**的
        //   （新建 2/2、覆盖 1/1，Drive 秒级索引到 `/mydrive/…`）。
        //   ⇒ 个人空间（能映射出 `/home/Drive/…`）一律**退回那条可用通道**，
        //   并把 Drive 的原始错误码带进埋点 detail（`via`）；
        //   团队/共享空间映射不出 DSM 路径时**不假装能用**，照原样抛错。
        if (dsmFolder == null) rethrow;
        via = 'filestation-fallback(drive:${e.code})';
        await fs.upload(
          folderPath: dsmFolder,
          filePath: localPath,
          fileName: picked.name,
          onProgress: (sent, total) =>
              progress.value = (sent: sent, total: total < 0 ? 0 : total),
        );
      }
    } else {
      if (dsmFolder == null) {
        // 原来这里是 `dsmFolder!`：路径映射不出来时会在上传中途崩成
        // "Unexpected null value"（既不是错误码也不是人话）⇒ 改成显式报错。
        throw DsmApiException(
          DsmErrorCode.requestParameterInvalid,
          method: 'SYNO.SynologyDrive.Files.upload',
          raw: {'reason': 'no_dsm_path', 'path': path},
        );
      }
      await fs.upload(
        folderPath: dsmFolder,
        filePath: localPath,
        fileName: picked.name,
        onProgress: (sent, total) =>
            progress.value = (sent: sent, total: total < 0 ? 0 : total),
      );
    }
    navigator.pop();
    trackFile(
      ref,
      UsageModule.drive,
      UsageAction.upload,
      picked.name,
      size: picked.size ?? 0,
      detail: {'via': via},
    );
    refreshDriveViews(ref);
    messenger.showSnackBar(
      SnackBar(content: Text(t.driveUploadedIndexing(picked.name))),
    );
  } catch (e) {
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
  }
}

/// Drive 缩略图（没有缩略图的类型直接用分类图标，与 NAS 源一致）
class _DriveThumb extends ConsumerWidget {
  const _DriveThumb({
    required this.entry,
    this.scale = ThumbScale.small,
    this.size = 40,
  });

  final DriveEntryDto entry;

  /// D18：列表用 small，网格用 large（官方三档 small/medium/large）
  final ThumbScale scale;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = driveEntryAsFile(entry);
    final fallback = FileIconTile(
      entry: file,
      size: size,
      iconSize: size * 0.5,
      // ★ r494：网格缩略图也去切角（与行首图标块同族：圆角 11）
      chamfer: false,
      radius: 11,
    );
    // D18：服务端若在 `Files/list` 里直接回了 `thumbnail` 直链就用它
    // （官方 Web reader 的 `thumbnail` 字段）。语义**未取证**，所以只在它看起来
    // 是一条 http(s) URL 时才用，否则一律回落到既有的 `get_thumbnail` 直链。
    // 网格视图（大图）也走这条：先大图，失败再退回分类图标。
    // ★ DA86（r427）：这条直链原来走 `Image.network` ⇒ 在"按 IP 连 NAS、
    // 证书 SAN 只覆盖域名"的环境里握手失败、恒退图标。改走同一个鉴权字节
    // 通道（`AuthedImage` + `api.getBytes`）。
    final driveApi = ref.watch(driveApiProvider);
    if (!entry.isDir &&
        entry.thumbnail.startsWith('http') &&
        driveApi != null) {
      return ClipPath(
        clipper: const ShapeBorderClipper(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(11)),
          ),
        ),
        child: SizedBox(
          width: size,
          height: size,
          child: AuthedImage(
            url: entry.thumbnail,
            identity: 'drive-thumb-url:${entry.fileId}',
            load: driveApi.api.getBytes,
            fit: BoxFit.cover,
            fallback: fallback,
          ),
        ),
      );
    }
    // 电子书/PDF：Drive 的 `get_thumbnail` 同样不给（服务端只管图片/视频），
    // 封面由客户端出（解析包 / 渲第一页）——与 NAS 源同一套降级策略
    final isBook = showsBookCover(file);
    if (entry.isDir || (!isBook && !_hasThumb)) return fallback;
    final bytes = isBook && scale == ThumbScale.small
        ? ref
              .watch(
                driveBookCoverProvider((
                  fileId: entry.fileId,
                  versionId: entry.capabilities['version_id']?.toString() ?? '',
                  extension: entry.extension,
                )),
              )
              .value
        : ref
              .watch(
                driveThumbProvider((
                  fileId: entry.fileId,
                  versionId: entry.capabilities['version_id']?.toString() ?? '',
                  scale: scale,
                )),
              )
              .value;
    if (bytes == null || !looksLikeImage(bytes)) return fallback;
    // 与 NAS 文件列表同一条规则：按真实比例摆，不裁切
    final aspect = aspectOfImageBytes(bytes);
    return ClipPath(
      clipper: const ShapeBorderClipper(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(11)),
        ),
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: AspectImage(
          aspect: aspect,
          child: Image.memory(
            bytes,
            fit: aspect == null ? BoxFit.contain : BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => fallback,
          ),
        ),
      ),
    );
  }

  /// 与服务端会给缩略图的类型保持一致（**图片/视频**；PDF 服务端回 404，
  /// 见 `file_thumb.dart` 的说明，走 [showsBookCover] 那条客户端路径）
  bool get _hasThumb => switch (entry.extension) {
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'heic' ||
    'heif' ||
    'mp4' ||
    'mov' ||
    'mkv' ||
    'avi' ||
    'webm' ||
    'm4v' => true,
    _ => false,
  };
}

/// D59：可以在应用内编辑的纯文本后缀。
///
/// 官方 `FileTypeInterpreter.smali` 的 `TXTExtensions = [".txt", ".md"]`
/// （`.line 272`/`.line 407` 逐字；判定入口 `isTXTByFileName`，`.line 1215`）。
/// ★ r379 订正：旧注释引的 `OpenFileHelper.java:292-300` 是**行号对不上的
/// 二手转述**；真正的分流判据是 `OpenFileHelper.smali` 的 `openFile$lambda$5`
/// —— 见 `kDriveTextEditorMaxBytes` 的逐字引用。
bool driveIsEditableText(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0) return false;
  final ext = name.substring(i + 1).toLowerCase();
  return ext == 'txt' || ext == 'md';
}

/// 官方 `.txt`/`.md` 走**内建编辑器**的体积上限：**1 MiB**。
///
/// ★ r379（DA16）逐字取证 —— 官方 Drive 3.9.0-1113 反编译
/// `com/synology/dsdrive/util/OpenFileHelper.smali` 的
/// `openFile$lambda$5`（`.line 188` 起）：
///
/// ```smali
/// invoke-virtual {p0}, …FileInfo;->getSize()J
/// const-wide/32 v2, 0x100000
/// cmp-long p0, v0, v2
/// if-lez p0, :cond_0                       # size <= 1 MiB ⇒ cond_0
///   ShowUVFragment（通用阅读器）            # > 1 MiB
/// :cond_0
///   ShowTextEditorFragment（Markor 编辑器） # ≤ 1 MiB
/// ```
///
/// 这个分支的**选中条件**（`OpenFileHelper.smali` `.line 183-196`）是
/// `isTXTByFileName(name)` 为真、且 `p8 || getOpenTxtByDrive()`；
/// 而 `PreferenceUtilities.getDefaultAppTxt()` 的默认值逐字就是 `"drive"`
/// （`PreferenceUtilities.smali:.line 397`，`getString("default_app_txt","drive")`）
/// ⇒ **开箱即走应用内编辑器**，不是"用户改过设置才会"。
const int kDriveTextEditorMaxBytes = 1024 * 1024;

/// 点一行文件时的打开方式。
///
/// ★ r379（DA16）：本仓原来对 `.txt`/`.md` **一律**进只读阅读器（`Chapter 1/1`
/// + `Reading tools`），编辑器只能从行 `⋮` → `Edit text` 进 ⇒ 与上面的官方分流
/// 不一致。此枚举把"该进哪个"变成一个**可单测的纯函数**，路由处只做转发。
enum DriveTapOpen { editor, reader }

/// 纯函数：按官方规则决定点行的落点（编辑器 / 阅读器）。
///
/// 只看后缀与体积 —— **不看写权限**（官方也不看：只读共享的文件官方同样交给
/// Markor 打开；我们的编辑器用 `readOnly` 打开，不给保存按钮）。
DriveTapOpen driveTapOpenMode({required String name, required int size}) {
  if (driveIsEditableText(name) && size <= kDriveTextEditorMaxBytes) {
    return DriveTapOpen.editor;
  }
  return DriveTapOpen.reader;
}

/// D18：网格视图里的大缩略图卡片（列表视图仍由 `_DriveRow` 的 ListTile 承担）。
class _DriveGridTile extends StatelessWidget {
  const _DriveGridTile({
    required this.entry,
    required this.menu,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
  });

  final DriveEntryDto entry;
  final Widget menu;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// ★ 第 56 轮 D25：多选状态。
  final bool selected;
  final bool selectionMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final isImage =
        entry.extension == 'jpg' ||
        entry.extension == 'jpeg' ||
        entry.extension == 'png' ||
        entry.extension == 'gif' ||
        entry.extension == 'webp';
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: Key('drive-grid-tile-${entry.fileId}'),
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(Radii.embed),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Center(
                    child: _DriveThumb(
                      entry: entry,
                      scale: isImage ? ThumbScale.large : ThumbScale.small,
                      size: 96,
                    ),
                  ),
                  // ★ 选择模式下把右上角的"⋯"菜单换成复选框 ——
                  // 与官方一致（选择模式里菜单没有意义，还会误触）
                  if (selectionMode)
                    Positioned(
                      top: 0,
                      left: 0,
                      child: Checkbox(
                        key: Key('drive-select-${entry.fileId}'),
                        value: selected,
                        onChanged: (_) => onTap(),
                      ),
                    )
                  else
                    Positioned(
                      top: 0,
                      right: 0,
                      child: SizedBox(width: 36, height: 36, child: menu),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              entry.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            if (entry.owner.isNotEmpty)
              Text(
                entry.owner,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
              ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.title,
    required this.detail,
    required this.color,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color color;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(height: Gap.md),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(context.t.photoRetry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
