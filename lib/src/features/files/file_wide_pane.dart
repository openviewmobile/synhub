// 文件模块的**宽屏右栏**（Files/Drive 共用）。
//
// ★ r673 重做（用户：「左右分屏这个交互还是设计的有点奇怪，参考业界标准」）。
//
// 旧版（r284）是「左选右开」的**两级浏览器**：左栏点目录 ⇒ 右栏列出它的内容；
// 右栏再点目录 ⇒ 右栏自己再往下钻。问题不在"能不能用"，在**两套导航混在一起**：
//   ① 右栏既能"列目录"又能"再进入"，用户不知道当前停在哪一级，也没有"我在哪"的锚；
//   ② 打开文件要两跳（选中 ⇒ 再按「打开预览」）；
//   ③ 右栏一显示文件就只剩一张详情卡，回不去（r671 `DA297` 只补了头部）。
//
// 现在改成**业界标准的两栏**（Finder 列表视图 / Windows 资源管理器的
// 「内容 + 详细信息窗格」）：
//
//   * **左栏 = 唯一的导航面**：目录的双击/再次单击/Enter 都是"进入"（轨道只有一条，
//     由 `fileBrowseStackProvider` / `driveStackProvider` 负责，右栏不参与导航）；
//   * **右栏 = 选中项的信息/预览窗格**（Inspector）：不列目录、不钻目录，
//     只回答"这个东西是什么 + 怎么打开"；
//   * 单击只选中（右栏跟着换），双击/再次单击/Enter 才是打开 —— 与 Finder 一致；
//   * 右栏的「打开」按钮与双击走**同一个** `onOpen`（同一条打开路径，不新造第二种）。
//
// 保留的既有契约（用例/仪器依赖，别改名）：
//   `file-wide-master`（左栏区域）、`file-wide-region`（右栏区域）、
//   `file-wide-empty`（空态）、`file-wide-detail`（信息卡片）、
//   `file-wide-header` / `file-wide-up` / `file-wide-crumb-N`（面包屑与上一级，
//   `DA297` 的修复）、`file-wide-open`（显式打开按钮，`DA298` 的仪器会点它）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/file_entry_dto.dart';
import 'drive_browse_view.dart' show kDriveFabFootprint;
import 'file_providers.dart' show folderCacheProvider;
import 'file_row.dart' show formatFileTime;
import 'filestation_c5_text.dart';

/// 宽屏右栏的**当前选中项**（`file_browse_page.dart` 的 `_FileBrowsePageState`
/// 持有一份）。窄屏从不构造它。
///
/// * NAS 源：`drive == null`，`entry.path` 就是目录/文件路径；
/// * Drive 源：`drive != null`（**保留原始 DTO** —— 打开预览要 `file_id`，
///   只有 `FileEntryDto` 是不够的），`entry` 是 `driveEntryAsFile(drive)` 的
///   转写，供信息卡复用同一套渲染。
class WideSelection {
  const WideSelection({required this.entry, this.drive});

  final FileEntryDto entry;
  final DriveEntryDto? drive;

  bool get isDrive => drive != null;

  /// 仅 Drive 源有效（`isDrive == true` 时非空）。
  String get drivePath => drive!.displayPath;

  /// 是不是同一个条目（同源比较：NAS 用 path，Drive 用 fileId）。
  ///
  /// ★ 左栏的"选中高亮"就是靠它 —— 高亮必须和右栏显示的是**同一个对象**，
  ///   不许各用一套等价判断。
  bool sameAs(WideSelection? other) {
    if (other == null) return false;
    if (isDrive != other.isDrive) return false;
    return isDrive
        ? drive!.fileId == other.drive!.fileId
        : entry.path == other.entry.path;
  }
}

/// 右栏区域（**只在 expanded / 折痕分栏时**被 `AdaptiveScaffold` 插进树里）。
///
/// 两种形态：
///   1. 未选中 ⇒ 空态（`file-wide-empty`）；
///   2. 选中目录/文件 ⇒ **信息卡**（`_WideInspector`）：图标 / 名称 / 类型与体积 /
///      修改时间 / 路径 ＋ 一个「打开」主按钮。**这里不列目录内容**
///      —— 列内容只发生在左栏，导航只有一条轨道。
class FileWidePane extends ConsumerWidget {
  const FileWidePane({
    super.key,
    required this.selection,
    this.onSelect,
    this.onOpen,
    this.onUp,
    this.onClear,
  });

  final WideSelection? selection;

  /// 右栏面包屑里点某一段 ⇒ 把**左栏**切到那一级（右栏随之换成该目录的信息卡）。
  final ValueChanged<WideSelection>? onSelect;

  /// 「打开」按钮 ⇒ 与双击同一条路径（目录=进入，文件=预览）。
  final ValueChanged<WideSelection>? onOpen;

  /// 「上一级」（Drive 源要服务端 `parentId`，交给调用方用 Drive 栈回退）。
  final VoidCallback? onUp;

  /// 「关闭」（清掉选中，右栏回到空态）。等价于 Finder 里点空白处。
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = selection;
    if (sel == null) {
      // ★ r675（`DA302`）：横屏手机上右栏只有 ~102pt 高（实测 300×102）——
      //   大档（72 图标 + 双倍留白）会把标题和说明顶到折线外，只剩一颗圆圈。
      //   窗口矮就由**这里**（唯一知道右栏有多矮的地方）声明紧凑档。
      final short = MediaQuery.sizeOf(context).height < 480;
      // ★ r677（`DA308`）：iPhone 横屏（逻辑 874×402，右栏 300×102）时，
      //   Scaffold 的 FAB（右下 `OrbButton`，52 + 16 边距）正落在**右栏**里，
      //   把空态说明的第二行压住半行（r675 像素
      //   `docs/evidence-r675-ios/02_iphone_land_wide_root.png`：
      //   "...double-click" 被 `+` 盖掉）。判据：**空态的文字矩形不许与 FAB 相交**。
      //   修法与右栏其它列表一致 —— 让出 `kDriveFabFootprint`；短视口里
      //   这块横向让位比纵向让位更划算（102pt 高，纵向让完就没了）。
      return Padding(
        padding: EdgeInsets.only(right: short ? kDriveFabFootprint : 0),
        child: AppEmptyState(
          key: const Key('file-wide-empty'),
          icon: Icons.vertical_split_outlined,
          title: context.t.fileWideEmptyTitle,
          message: context.t.fileWideEmptyMessage,
          compact: short,
        ),
      );
    }
    return _WideInspector(
      selection: sel,
      onOpen: onOpen,
      onSelect: onSelect,
      onUp: onUp,
      onClear: onClear,
    );
  }
}

/// 选中项的信息卡（右栏）。
///
/// ★ 不承担导航：目录的"进入"和文件的"预览"都走同一个 [onOpen]
/// （与左栏双击完全同一条路径），所以右栏永远不是一个"中间页"。
/// 头部仍是 `DA297` 那一套：可点面包屑 + 「上一级」。
class _WideInspector extends ConsumerWidget {
  const _WideInspector({
    required this.selection,
    this.onOpen,
    this.onSelect,
    this.onUp,
    this.onClear,
  });

  final WideSelection selection;
  final ValueChanged<WideSelection>? onOpen;
  final ValueChanged<WideSelection>? onSelect;
  final VoidCallback? onUp;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final e = selection.entry;
    final isDir = e.isDir;

    // 父级路径由条目自己的路径推出来（NAS 源）；Drive 源的父目录要服务端
    // `parentId` ⇒ 走调用方既有的 Drive 栈回退（`onUp`）。
    final segs = e.path.split('/').where((x) => x.isNotEmpty).toList();
    final parentSegs = segs.length <= 1
        ? const <String>[]
        : segs.take(segs.length - 1).toList();
    final parentPath = parentSegs.isEmpty ? null : '/${parentSegs.join('/')}';
    final canUp = selection.isDrive ? onUp != null : parentPath != null;
    void goParent() {
      if (selection.isDrive) {
        onUp?.call();
        return;
      }
      if (parentPath == null) return;
      onSelect?.call(
        WideSelection(
          entry: FileEntryDto(
            name: parentPath.split('/').last,
            path: parentPath,
            isDir: true,
            permKnown: false,
          ),
        ),
      );
    }

    // 目录的「N 项」只读**已缓存**的目录（右栏不偷偷发起请求）。缓存里没有
    // 就只写「文件夹」，不编数字。
    var items = -1;
    if (isDir && !selection.isDrive) {
      final cached = ref.watch(folderCacheProvider(e.path)).asData?.value;
      if (cached != null) items = cached.length;
    }
    final meta = isDir
        ? [
            t.photoFolder,
            if (items >= 0) t.fileWideFolderItems(items),
            if (e.mtime > 0) formatFileTime(e.mtime, t: t),
          ].where((s) => s.trim().isNotEmpty).join(' · ')
        : [
            e.humanSize,
            if (e.mtime > 0) formatFileTime(e.mtime, t: t),
          ].join(' · ');

    return Column(
      children: [
        _PaneHeader(
          title: e.name,
          // Drive 源的面包屑段来自 `display_path`，点它要服务端 `parentId`
          // ⇒ 只走「上一级」那一个显式入口，不摆点了会错的假面包屑。
          crumbs: selection.isDrive ? null : parentSegs,
          onCrumb: selection.isDrive || parentPath == null
              ? null
              : (i) {
                  if (i >= parentSegs.length - 1) return;
                  onSelect?.call(
                    WideSelection(
                      entry: FileEntryDto(
                        name: parentSegs[i],
                        path: '/${parentSegs.take(i + 1).join('/')}',
                        isDir: true,
                        permKnown: false,
                      ),
                    ),
                  );
                },
          onUp: canUp ? goParent : null,
          onClose: onClear,
        ),
        Expanded(
          child: Padding(
            // 与其它右栏一致：缩小**视口**（不是只给内容留白），
            // 否则视口下沿仍伸到 FAB 底下（`kDriveFabFootprint` 机制）。
            padding: EdgeInsets.only(
              bottom:
                  kDriveFabFootprint + MediaQuery.viewPaddingOf(context).bottom,
            ),
            child: ListView(
              key: const Key('file-wide-detail'),
              padding: const EdgeInsets.all(Gap.lg),
              children: [
                Row(
                  children: [
                    Icon(
                      isDir
                          ? Icons.folder_rounded
                          : Icons.insert_drive_file_outlined,
                      size: 28,
                      color: theme.colorScheme.primary,
                    ),
                    SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(
                        e.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Gap.sm),
                Text(
                  meta,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
                SizedBox(height: Gap.md),
                Text(
                  selection.isDrive ? selection.drivePath : e.path,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
                SizedBox(height: Gap.lg),
                // ★ 一条打开路径：目录=进入，文件=预览。与左栏双击/Enter 同一个
                //   `onOpen`（调用方 `_openWide`），不新造第二种打开方式。
                FilledButton.icon(
                  key: const Key('file-wide-open'),
                  onPressed: () => onOpen?.call(selection),
                  icon: Icon(isDir ? Icons.folder_open : Icons.open_in_new),
                  label: Text(
                    isDir ? t.fileWideOpenFolder : t.fileWideOpenPreview,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 右栏顶部一条目录名（右栏自己的一行，不是第二套面包屑 —— 移动/切换
/// 仍在左栏的既有面包屑上，这里只回答"右栏现在显示的是哪个目录"）。
class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.title,
    this.crumbs,
    this.onCrumb,
    this.onUp,
    this.onClose,
  });

  final String title;

  /// 右栏这一层目录的路径段（`/home/Drive/a` ⇒ `[home, Drive, a]`）。
  /// 非空时**替代**单行标题渲染成可点面包屑。
  final List<String>? crumbs;
  final ValueChanged<int>? onCrumb;

  /// 「上一级」；null ⇒ 已经在根，不摆按钮（不摆假控件）。
  final VoidCallback? onUp;

  /// 「关闭」；null ⇒ 不摆（比如窄屏/无回调）。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final segs = crumbs;
    return Container(
      key: const Key('file-wide-header'),
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        onUp == null ? Gap.md : Gap.xs,
        Gap.xs,
        Gap.xs,
        Gap.xs,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hud.line)),
      ),
      child: Row(
        children: [
          if (onUp != null)
            IconButton(
              key: const Key('file-wide-up'),
              tooltip: fsC5(FsC5TextKeys.up, '上一级'),
              onPressed: onUp,
              icon: const Icon(Icons.arrow_back, size: 18),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: EdgeInsets.zero,
            ),
          Expanded(
            child: segs == null || segs.isEmpty
                ? Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  )
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < segs.length; i++) ...[
                          if (i > 0)
                            Icon(Icons.chevron_right, size: 14, color: hud.dim),
                          InkWell(
                            key: Key('file-wide-crumb-$i'),
                            onTap: onCrumb == null ? null : () => onCrumb!(i),
                            borderRadius: BorderRadius.circular(6),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 8,
                              ),
                              child: Text(
                                _displayCrumb(context, segs[i]),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: i == segs.length - 1
                                      ? theme.colorScheme.primary
                                      : hud.dim,
                                  fontWeight: i == segs.length - 1
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          if (onClose != null)
            IconButton(
              key: const Key('file-wide-close'),
              tooltip: context.t.cancel,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }

  /// 面包屑文案：目录名原样，根层级用「根」占位（`/` 分成空串会被丢掉）。
  String _displayCrumb(BuildContext context, String seg) =>
      seg.isEmpty ? context.t.photoFolder : seg;
}
