// 文件（File Station）浏览页 —— 「文件」Tab 的主体。
//
// 分层与聊天一致：数据来自 `folderCacheProvider`（Drift 缓存，local-first），
// 网络刷新由 `folderSyncProvider` 负责，回来后再推一次缓存 → UI 自动更新。
//
// 根目录走 `List.list_share`（普通用户直接 `list` 根会 401，真机实测），
// 子目录走 `List.list`；方法/版本口径见 docs/api-server-authoritative.md §2。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../design/design_palette.dart';
import '../../core/ui/adaptive_actions.dart';
import '../../core/ui/adaptive_layout.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/section_pager.dart';
import '../../core/ui/hud_widgets.dart';
import '../../core/ui/orb_button.dart';
import '../../core/ui/app_sheet.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/filestation_api.dart' show UploadConflictPolicy;
import '../../data/media/device_media_library.dart';
import '../photos/photo_backup_providers.dart' show deviceMediaLibraryProvider;
import 'file_local_photos_pick.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../drive/drive_search_page.dart';
import '../../data/local/file_store.dart';
import 'file_providers.dart';
import 'file_upload_picker.dart';
import 'file_destination_picker.dart';
import 'file_shortcut.dart';
import 'drive_browse_view.dart';
import 'drive_more_page.dart';
import 'drive_tasks_page.dart';
import 'drive_providers.dart';
import 'file_row.dart';
import 'file_download.dart';
import 'file_download_tasks.dart';
import 'file_sheets.dart';
import 'file_offline_pin.dart';
import 'file_tools_sheet.dart';
import 'file_pages.dart';
import '../drive/drive_open_entry.dart' show driveOpenEntry, openFileUnified;
import 'file_wide_pane.dart' show FileWidePane, WideSelection;
import 'file_preview_page.dart';
import 'file_mount.dart';
import 'file_mount_page.dart';
import 'filestation_c5_text.dart';
import 'filestation_g4_text.dart';
import 'filestation_gaps_wave1_text.dart';
import 'filestation_gaps_wave2_text.dart';
import 'filestation_p0a_text.dart';

class FileBrowsePage extends ConsumerStatefulWidget {
  const FileBrowsePage({super.key, this.initialPath});

  /// 从收藏 / 搜索结果跳进来时直接落到这个目录（不传就是上次的位置）。
  final String? initialPath;

  @override
  ConsumerState<FileBrowsePage> createState() => _FileBrowsePageState();
}

class _FileBrowsePageState extends ConsumerState<FileBrowsePage> {
  /// 多选模式：非空即选中态
  final Set<String> _selected = {};

  /// P1-1：目录内过滤框（官方 `AbsResourceFragment.java:697-699` 的 Filter）。
  /// 纯客户端 —— 只筛当前已缓存的这一页，不发新请求。
  final TextEditingController _filter = TextEditingController();
  bool _filtering = false;

  /// M04：目录列表的滚动位置 —— 离底 ~320px 时触发下一页。
  final ScrollController _scroll = ScrollController();

  /// ★ r284 宽屏双栏：右栏当前选中项（`null` = 空态）。
  ///
  /// 窄屏**从不写它**（窄屏走原来的 `Navigator.push`）；宽屏（`expanded`）
  /// 点行只 `setState` 它 ⇒ **不推路由**。判据是**窗口宽度分级**
  /// （`appWindowSizeOf`），不是"右栏 widget 在不在树里"（§2.0.30②）。
  WideSelection? _wide;

  @override
  void dispose() {
    _filter.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// 触底续取（M04）：只在 NAS 来源、且分页状态说"还有且不忙"时才发请求。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels > 320) return;
    _maybeLoadMore();
  }

  void _maybeLoadMore() {
    if (ref.read(fileSourceProvider) != FileSource.nas) return;
    final paging = ref.read(folderPagingProvider(_current));
    if (!paging.canLoadMore) return;
    ref.read(folderPagingProvider(_current).notifier).loadMore();
  }

  /// 当前过滤词（小写，去首尾空白）
  String get _filterQuery => _filter.text.trim().toLowerCase();

  void _toggleFilter() {
    setState(() {
      _filtering = !_filtering;
      if (!_filtering) _filter.clear();
    });
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // G4 / 219：把落盘的离线清单读回内存（读完 provider 自己刷新行标）
    Future<void>.microtask(
      () => ref.read(offlinePinProvider.notifier).preload(),
    );
    final target = widget.initialPath;
    if (target != null && target.isNotEmpty) {
      // 放到首帧之后：initState 里直接改 provider 状态会撞上"构建期间改状态"
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(fileBrowseStackProvider.notifier).openPath(target);
        }
      });
    }
  }

  String get _current => ref.read(fileBrowseStackProvider).last;

  /// 埋点用的模块：左滑到 Drive 源时算 Drive，其余算文件
  UsageModule get _usageModule =>
      ref.read(fileSourceProvider) == FileSource.drive
      ? UsageModule.drive
      : UsageModule.files;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final source = ref.watch(fileSourceProvider);
    final stack = ref.watch(fileBrowseStackProvider);
    final path = stack.last;
    final cached = ref.watch(folderCacheProvider(path));
    final sync = ref.watch(folderSyncProvider(path));
    final caps = ref.watch(fileCapabilitiesProvider);

    // 选中项在新目录里可能已经不存在了 —— 进入新目录就清空选择
    ref.listen(fileBrowseStackProvider, (prev, next) {
      if (prev != null && prev.last != next.last) {
        if (_selected.isNotEmpty) setState(_selected.clear);
        // 过滤词也是"当前目录的"——换目录就重置，避免新目录看着是空的
        if (_filter.text.isNotEmpty) setState(_filter.clear);
        // ★ r284：左栏换了位置 ⇒ 右栏的选中项已经不属于当前上下文，清掉
        if (_wide != null) setState(() => _wide = null);
      }
    });

    // P0-2：当前是不是在共享文件夹根的 `#recycle` 里
    final inRecycle =
        source == FileSource.nas && RecyclePath.isInRecycleBin(path);
    final recycleRoot =
        source == FileSource.nas && RecyclePath.isRecycleRoot(path);
    // 清空回收站是 admin-only（SYNO.Core.RecycleBin）→ 非管理员不给入口
    final isManager = ref.watch(fileIsManagerProvider).value ?? false;
    // ★ D27（第 327 轮真机）：`#recycle` 入口必须是**服务端列表里真有这个条目**
    //   时才给。本 NAS 实测：`/home`、`/docker` 的列表里都没有 `#recycle`
    //   （直接 `List/list('/home/#recycle')` → **408**，见
    //   `docs/device-readonly-verification-evidence-r16.md` §10），
    //   而**无条件**入口点进去只有 "Target location not found"（错误页 + Retry）
    //   ⇒ 是个**假入口**。官方 DS file 也是按**列表条目**给回收站图标
    //   （`ResourceItemFactory.isRecycleBin()` 判 `name == "#recycle"`），
    //   即"回收站就是服务端列出来的普通目录"；我们照此：**列表里有才给入口**，
    //   列表里没有（或列表还没回来）就不给 —— 宁可少一个快捷方式，
    //   也不给一个必然报错的入口。
    final hasRecycleBin = (cached.value ?? const <FileEntryDto>[]).any(
      (e) => e.name == RecyclePath.segment,
    );
    final shareRoot =
        source == FileSource.nas &&
        !inRecycle &&
        isShareRootPath(path) &&
        hasRecycleBin;

    // C5：远程挂载入口。服务器注册表里没有 Mount/Mount.List 就**不显示**；
    // 曾经被 105/160 拒过也不再显示（点一次就够，不留会失败的入口）。
    final mountCap = ref.watch(fileMountCapabilityProvider);
    final mountDenied = ref.watch(fileMountPermissionDeniedProvider);

    // W1-3 收尾：下载任务的**常驻入口**。任务列表是 `ChangeNotifier`，
    // 数量/进度由 `_DownloadTasksButton` 自己 listen（不用整页重建）。
    final downloadTasks = ref.watch(fileDownloadTaskListProvider);

    return PopScope(
      // ★ 第 259 轮真机缺陷：NAS 源在子目录里按系统返回键**直接退出整个 App**
      // （这一层是 tab 内的状态，不是路由）。现在：在子目录先逐级返回，
      // 到了根才允许系统退出；Drive 源交给 `DriveBrowseView` 自己的栈。
      canPop: source == FileSource.drive || stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (source == FileSource.nas && stack.length > 1) {
          ref.read(fileBrowseStackProvider.notifier).up();
        }
      },
      child: Scaffold(
        backgroundColor: hud.bg,
        body: SafeArea(
          bottom: false,
          // ★★ r675（`DA301`）：iPad/桌面式硬件键盘在宽屏文件站上**什么都不认** ——
          //   Enter 不打开、Esc 不关信息窗格。iPad 加个妙控键盘就是"桌面电脑"，
          //   用户的第一反应必然是这两个键（Finder 里也是这两个）。
          //   只在 **expanded** 生效：窄屏 Enter 属于"提交表单"，Esc 属于"退出App"，
          //   都不是本条语义；筛选框开着时不抢键（那时 Enter 该提交筛选）。
          child: _WideKeys(
            enabled:
                appWindowSizeOf(MediaQuery.sizeOf(context)).isExpanded &&
                !_filtering,
            onOpen: () {
              final sel = _wide;
              if (sel == null) return;
              _openWide(sel);
            },
            onClear: () {
              if (_wide == null) return;
              setState(() => _wide = null);
            },
            child: Column(
            children: [
              _Deck(
                path: path,
                selecting: _selected.isNotEmpty,
                selectedCount: _selected.length,
                caps: caps,
                source: source,
                onSource: (s) {
                  track(
                    ref,
                    UsageModule.files,
                    UsageAction.switchSection,
                    objectType: s == FileSource.drive ? 'drive' : 'nas',
                  );
                  ref.read(fileSourceProvider.notifier).select(s);
                  if (s == FileSource.drive) {
                    ref.read(driveStackProvider.notifier).reset();
                  }
                },
                onCancelSelection: () => setState(_selected.clear),
                // ★ 第 259 轮：子目录才显示「上一级」（根目录不显示）
                onUp: source == FileSource.nas && stack.length > 1
                    ? () => ref.read(fileBrowseStackProvider.notifier).up()
                    : null,
                onSort: _showSortSheet,
                // P0-4：Drive 源走官方 `SYNO.SynologyDrive.Files:search`
                // （带 location/type/owner/size/date 筛选），NAS 源不变。
                onSearch: () => _push(
                  source == FileSource.drive
                      ? const DriveSearchPage()
                      // r121：把**当前目录**带进去当搜索根（原来恒 `/`）
                      : FileSearchPage(folderPath: _current),
                ),
                onFavorites: () => _push(const FileFavoritesPage()),
                onShareLinks: caps.canShare
                    ? () => _push(const FileShareLinksPage())
                    : null,
                // 共享文件夹根的「回收站」入口（P0-2）：进 `#recycle` 视图
                onRecycleBin: shareRoot
                    ? () => ref
                          .read(fileBrowseStackProvider.notifier)
                          .openPath('$path/${RecyclePath.segment}')
                    : null,
                onEmptyRecycle: recycleRoot && isManager ? _emptyRecycle : null,
                // 两个来源的任务是两套（File Station BackgroundTask vs
                // SynologyDrive.Tasks），所以按来源进不同的页面，别混
                onTasks: () => _push(
                  source == FileSource.drive
                      ? const DriveTasksPage()
                      : const FileTasksPage(),
                ),
                // ★ D67：Drive 后台任务未读角标（官方
                //   `BackgroundTaskManager.getBadgeDisplayCount()` = 进行中+失败任务数；
                //   进过任务页就算看过）。NAS 源是另一套任务，不看它。
                tasksBadge: source == FileSource.drive
                    ? (ref.watch(driveTaskBadgeProvider).asData?.value ?? 0)
                    : 0,
                onMounts:
                    source == FileSource.nas &&
                        mountCap.canManage &&
                        !mountDenied
                    ? _openMounts
                    : null,
                onFilter: _toggleFilter,
                onTools: source == FileSource.nas
                    ? () => showFileToolsSheet(context)
                    : null,
                downloadTasks: downloadTasks,
                viewMode: ref.watch(fileViewModeProvider),
                onToggleView: () =>
                    ref.read(fileViewModeProvider.notifier).toggle(),
              ),
              if (source == FileSource.drive)
                DriveBrowseView.breadcrumb(context, ref)
              else
                _Breadcrumb(
                  stack: stack,
                  onJump: (i) =>
                      ref.read(fileBrowseStackProvider.notifier).jumpTo(i),
                  // ★ DA291：`file-up` 会折进 `⋮`（宽/窄屏都可能），而且
                  //   一个向上的箭头在图标堆里不像"回父目录"。面包屑这一行
                  //   现在自带一个**带字的**「上一级」，48dp 点击区。
                  onUp: source == FileSource.nas && stack.length > 1
                      ? () => ref.read(fileBrowseStackProvider.notifier).up()
                      : null,
                ),
              // P1-1：目录内过滤框（官方 `AbsResourceFragment` 的 Filter）
              if (_filtering && source == FileSource.nas)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, 0),
                  child: TextField(
                    controller: _filter,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: fsC5(FsC5TextKeys.filterHint, '在目录内筛选'),
                      prefixIcon: const Icon(
                        Icons.filter_alt_outlined,
                        size: 18,
                      ),
                      suffixIcon: _filter.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: fsC5(FsC5TextKeys.filterClear, '清除筛选'),
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => setState(_filter.clear),
                            ),
                    ),
                  ),
                ),
              if (source == FileSource.nas && _selected.isNotEmpty)
                _SelectionBar(
                  count: _selected.length,
                  recycleBin: inRecycle,
                  onAction: _onSelectionAction,
                ),
              // NAS ⇄ Drive：顶部分段控件之外**还能左右滑动切换来源**
              //
              // 用 `SectionPager`（懒构建）：不滑到 Drive 就不会去拉 Drive 的
              // 目录，保持原来的请求行为。
              // ★★ r284 宽屏双栏（Files / Drive）——**全仓唯一的文件模块接入点**。
              //
              // 断点**复用** `adaptive_layout.dart`（`AppWindowSize` /
              // `AdaptiveScaffold`），本页不写任何宽度常量、不写 `if (width > …)`
              // （§2.0.26："同一语义不许两份表示"）。
              // 窄屏等价性：非 expanded 且无折痕时 `AdaptiveScaffold` **原样
              // 返回 `master`** ⇒ 下面的 `SectionPager`（连同 NAS 的单列列表与
              // `DriveBrowseView`）与改动前逐字节一致，唯一的差别是外面多了
              // 一个零布局的 `KeyedSubtree`（`file-wide-master`，用例量矩形用）。
              //
              // 为什么 master 只包住 SectionPager（而不是像 notes_page 那样包
              // 整个 Scaffold）：本页的 FAB 属于**整页**右下角，包进左栏会让它
              // 跑到两栏中间的缝里；顶栏/面包屑横跨两栏是正确的。
              Expanded(
                child: AdaptiveScaffold(
                  master: KeyedSubtree(
                    key: const Key('file-wide-master'),
                    child: SectionPager(
                      pagerKey: const Key('file-source-pager'),
                      index: source.index,
                      itemCount: FileSource.values.length,
                      onIndex: (i) {
                        final s = FileSource.values[i];
                        track(
                          ref,
                          UsageModule.files,
                          UsageAction.switchSection,
                          objectType: s == FileSource.drive ? 'drive' : 'nas',
                        );
                        ref.read(fileSourceProvider.notifier).select(s);
                        if (s == FileSource.drive) {
                          ref.read(driveStackProvider.notifier).reset();
                        }
                      },
                      itemBuilder: (context, i) =>
                          FileSource.values[i] == FileSource.drive
                          // 宽屏：Drive 左栏的"点行"改由本页填右栏（不 push
                          // 目录栈、不推预览路由）；窄屏传 null ⇒ `_DriveRow`
                          // 的 `openEntry()` 与改动前逐字节相同。
                          ? DriveBrowseView(
                              // ★ r673：右栏正在显示的那一条，左栏要亮起来
                              //   （与 NAS 源同一口径，见 `_body` 里的 `wideShown`）。
                              wideSelectedId: _wide?.drive?.fileId,
                              onWideSelect:
                                  appWindowSizeOf(
                                    MediaQuery.sizeOf(context),
                                  ).isExpanded
                                  ? _onWideDriveSelect
                                  : null,
                            )
                          : cached.when(
                              loading: () => const AppListSkeleton(),
                              error: (e, _) => AppErrorView(
                                title: context.t.fileCacheReadFailed,
                                detail: describeFileError(e),
                                onRetry: () =>
                                    ref.invalidate(folderCacheProvider(path)),
                              ),
                              data: (rows) => _body(rows, sync),
                            ),
                    ),
                  ),
                  dividerColor: hud.line,
                  // 右栏区域 key 与"选中/未选中"无关（用例量的是**区域矩形**）。
                  detail: SizedBox.expand(
                    key: const Key('file-wide-region'),
                    child: FileWidePane(
                      selection: _wide,
                      onSelect: (s) => setState(() => _wide = s),
                      onOpen: _openWide,
                      // ★ r673：右栏的「✕」= 清掉选中（Finder 里点空白处的等价动作），
                      //   回到空态而不是留一张过期的信息卡。
                      onClear: () => setState(() => _wide = null),
                      // ★ DA291：Drive 的父目录要服务端 `parentId`，右栏
                      //   自己造不出来 ⇒ 用既有的 Drive 栈回退一级，并把
                      //   右栏清空（左栏这时已经停在父目录）。
                      onUp: () {
                        final stack = ref.read(driveStackProvider);
                        if (stack.length > 1) {
                          ref
                              .read(driveStackProvider.notifier)
                              .popTo(stack.length - 2);
                        }
                        setState(() => _wide = null);
                      },
                    ),
                  ),
                ),
              ),
              ],
            ),
          ),
        ),
        floatingActionButton: _selected.isEmpty
            ? OrbButton(
                icon: Icons.add,
                tooltip: context.t.fileNewUpload,
                semanticLabel: context.t.fileNewUploadSemantic,
                // Drive 源有自己的「新建文件夹/上传」面板（走 Drive 的 API 形态，
                // 不是 FileStation 的参数）——别让两套混在一起
                onPressed: source == FileSource.drive
                    ? () => showDriveCreateSheet(
                        context,
                        ref,
                        ref.read(driveStackProvider).last,
                      )
                    : _showCreateSheet,
              )
            : null,
      ),
    );
  }

  Widget _body(List<FileEntryDto> rawRows, AsyncValue<FolderSyncResult> sync) {
    final t = context.t;
    final refreshing = sync.isLoading;
    final error = sync.hasError ? sync.error : null;
    // G4 / 219：离线登记路径集合（一次 watch，逐行 O(1) 查）
    final pinnedPaths = ref.watch(offlinePinnedPathsProvider);
    // 缓存里的行序是插入序，要按用户选的排序重排（目录恒在前）
    final sorted = sortFileEntries(rawRows, ref.watch(fileSortProvider));
    // P1-1：目录内过滤（纯客户端，只筛这一页缓存；大小写不敏感）
    final query = _filterQuery;
    final rows = query.isEmpty
        ? sorted
        : sorted.where((e) => e.name.toLowerCase().contains(query)).toList();

    // 缓存为空时，加载/失败应该占满整屏（而不是"空文件夹"）
    if (sorted.isEmpty) {
      if (refreshing) return const AppListSkeleton();
      if (error != null) {
        return AppErrorView(
          title: t.fileOpenLocationFailed,
          detail: describeFileError(error),
          onRetry: _refresh,
        );
      }
      return AppEmptyState(
        icon: Icons.folder_open,
        title: _current == kFileRoot
            ? t.fileNoSharedFolders
            : t.fileEmptyFolder,
        message: _current == kFileRoot ? t.fileNoSharedFoldersMessage : null,
        actionLabel: t.photoRefresh,
        onAction: _refresh,
      );
    }

    // 有内容但被过滤光了：给一个能一键清除的提示（别看起来像空目录）
    if (rows.isEmpty) {
      return AppEmptyState(
        icon: Icons.search_off,
        title: fsC5(FsC5TextKeys.filterNoMatch, '没有匹配项'),
        message: fsC5(FsC5TextKeys.filterHint, '在目录内筛选'),
        actionLabel: fsC5(FsC5TextKeys.filterClear, '清除筛选'),
        onAction: () => setState(_filter.clear),
        // 「清除筛选」不是重试 ⇒ 显式给"关掉筛选"的图标（共享组件默认刷新圈）
        actionIcon: Icons.filter_alt_off,
      );
    }

    final grid = ref.watch(fileViewModeProvider) == FileViewMode.grid;
    // M04：分页三态。`loadingMore` 转圈 / `error` 重试 / `reachedEnd` 收尾。
    final paging = ref.watch(folderPagingProvider(_current));
    final footer = _pagingFooter(paging);
    // 有 footer 时列表底部留小间距，footer 自己带 96（给 FAB 让位）
    final listBottom = footer == null ? 96.0 : Gap.md;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        controller: _scroll,
        slivers: [
          if (error != null)
            SliverToBoxAdapter(
              child: _StaleBanner(detail: describeFileError(error)),
            ),
          if (grid)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, listBottom),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 148,
                  mainAxisSpacing: Gap.sm,
                  crossAxisSpacing: Gap.sm,
                  childAspectRatio: 0.74,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final e = rows[index];
                  return FileGridTile(
                    entry: e,
                    selecting: _selected.isNotEmpty,
                    selected: _selected.contains(e.path),
                    onTap: () => _onTap(e),
                    onLongPress: () => setState(() => _selected.add(e.path)),
                    onMenu: () => _onMenu(e),
                  );
                }, childCount: rows.length),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.only(bottom: listBottom),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final e = rows[index];
                  final favorites =
                      ref.watch(fileFavoritesProvider).value ??
                      const <String>[];
                  // ★ r673：宽屏下**右栏正在显示的那一条**必须在左栏亮起来 ——
                  //   旧版点了目录，右栏换了内容而左栏毫无反馈，用户不知道
                  //   "现在这一屏是哪个东西的"。高亮判据与右栏同一个对象判定
                  //   （`WideSelection.sameAs`），不另写一套等价判断。
                  final wideShown =
                      _wide != null &&
                      !_wide!.isDrive &&
                      _wide!.entry.path == e.path;
                  return FileRow(
                    entry: e,
                    selecting: _selected.isNotEmpty,
                    selected: wideShown || _selected.contains(e.path),
                    isFavorite: favorites.contains(e.path),
                    // G4 / 219：离线登记标记（一次 watch 的集合，逐行查）
                    pinned: pinnedPaths.contains(e.path),
                    onToggleFavorite: () => _toggleFavorite(e),
                    onTap: () => _onTap(e),
                    onLongPress: () => setState(() => _selected.add(e.path)),
                    onMenu: () => _onMenu(e),
                  );
                }, childCount: rows.length),
              ),
            ),
          if (footer != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 96),
                child: footer,
              ),
            ),
        ],
      ),
    );
  }

  /// 列表底部的分页收尾态（M04）。
  ///
  /// **到底就不再发请求**：`reachedEnd` 时这里只画一行文案，不会转圈；
  /// 失败时不自动重撞，只给一个「重试」按钮。
  Widget? _pagingFooter(FolderPagingState paging) {
    if (paging.loadingMore) {
      return Padding(
        key: const Key('file-page-loading'),
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: Gap.sm),
            Text(
              fsGap(FsGapTextKeys.loadingMore, '正在加载更多…'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    if (paging.error != null) {
      return Padding(
        key: const Key('file-page-error'),
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                '${fsGap(FsGapTextKeys.loadMoreFailed, '加载更多失败')}'
                ' · ${describeFileError(paging.error!)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () =>
                  ref.read(folderPagingProvider(_current).notifier).loadMore(),
              child: Text(fsGap(FsGapTextKeys.retry, '重试')),
            ),
          ],
        ),
      );
    }
    if (paging.reachedEnd) {
      return Padding(
        key: const Key('file-no-more'),
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        child: Center(
          child: Text(
            fsGap(FsGapTextKeys.noMore, '没有更多了'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return null;
  }

  void _push(Widget page) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _refresh() async {
    ref.invalidate(folderSyncProvider(_current));
    await ref
        .read(folderSyncProvider(_current).future)
        .catchError((Object _) => const FolderSyncResult(offline: true));
  }

  // ------------------------------------------------------------ 交互

  /// ★ r671（`DA298`）：上一次点击的条目与时刻 —— 宽屏用"时间窗"判双击。
  String? _lastTapPath;
  DateTime? _lastTapAt;

  void _onTap(FileEntryDto e) {
    if (_selected.isNotEmpty) {
      setState(() {
        if (!_selected.remove(e.path)) _selected.add(e.path);
      });
      return;
    }
    // ★ r284 宽屏双栏：expanded 时**点项就地填右栏**，不推路由也不换左栏目录。
    //   判据是窗口宽度分级（`appWindowSizeOf`），与 `AdaptiveScaffold` 的
    //   宽度门**同源**（`kAppWindowCompactMax/kAppWindowMediumMax` 一份）。
    //   窄屏那一支（下面几行）与本轮改动前**逐字节相同**。
    if (appWindowSizeOf(MediaQuery.sizeOf(context)).isExpanded) {
      // ★ r671（`DA298`）：**同一条目 500ms 内第二次点 = 直接打开**。
      //   为什么不用 `InkWell.onDoubleTap`：真机走查实测它在本页不生效
      //   （`InkWell` 同时挂 `onTap`+`onDoubleTap` 时第一次抬手会把单击赢走，
      //   第二下就只剩"又一次单击"；widget 用例里能量到 `doubles=1`，真机 800×600
      //   上却怎么点都不打开）。改成**在单击回调里量时间差**：单击照旧选中、
      //   第二下打开 —— 判据是"是不是同一个条目、够不够快"，不依赖手势竞技场。
      final now = DateTime.now();
      final quickSecondTap =
          _lastTapPath == e.path &&
          _lastTapAt != null &&
          now.difference(_lastTapAt!) <= const Duration(milliseconds: 500);
      // 再点一次**右栏正在显示的那一条** = 打开。为什么除时间窗之外还要这一条：
      // ① 真机走查的 `tester.tap` 两下之间实测 ≈3 s（每一下自带一帧往返），时间窗
      //    在仪器里根本量不到 ⇒ 只靠时间窗就成"widget 用例绿、真机判不了"；
      // ② 用户视角它就是"这个我已经选中了，再点一下就是打开"（Finder/资源管理器同感）。
      final alreadyShown = _wide?.entry.path == e.path;
      _lastTapPath = e.path;
      _lastTapAt = now;
      if (quickSecondTap || alreadyShown) {
        _lastTapPath = null;
        _lastTapAt = null;
        _onDoubleTap(e);
        return;
      }
      if (e.isDir) {
        track(ref, _usageModule, UsageAction.open, objectType: 'folder');
      } else {
        trackFile(ref, _usageModule, UsageAction.preview, e.name);
      }
      setState(() => _wide = WideSelection(entry: e));
      return;
    }
    if (e.isDir) {
      ref.read(fileBrowseStackProvider.notifier).open(e.path);
      track(ref, _usageModule, UsageAction.open, objectType: 'folder');
      return;
    }
    // 点文件 = 打开预览（与原版 DS file 一致）；批量操作在「⋮」菜单里
    _preview(e);
  }

  /// ★ r671（`DA298`）：宽屏**双击直接打开**。
  ///
  /// 用户 2026-10-28："打开文件不能直接打开，会出现一个中间页面，这个页面
  /// 无返回到上级父目录"。两条都是宽屏「左选右开」的副作用：
  ///   ① 单击只把条目填进右栏（= 中间页面），要再点一次「打开预览」才真的打开；
  ///   ② 那个中间页面（详情卡）**没有回父目录的入口**（r671 已给它补头）。
  /// 双击是桌面惯性动作 ⇒ 单击仍然是"选中/看详情"，双击直接走窄屏同一条
  /// 打开路径（目录进目录、文件开预览），不做第二套打开实现。
  void _onDoubleTap(FileEntryDto e) {
    if (_selected.isNotEmpty) return; // 多选态下双击不打开（避免误操作）
    if (e.isDir) {
      ref.read(fileBrowseStackProvider.notifier).open(e.path);
      track(ref, _usageModule, UsageAction.open, objectType: 'folder');
      return;
    }
    _preview(e);
  }

  /// ★ r284：右栏里点「打开预览」。NAS 条目走既有 `_preview`（与窄屏同一
  /// 条路径）；Drive 条目走既有 `driveOpenEntry`（**不新造第二套预览入口**）。
  void _openWide(WideSelection s) {
    final d = s.drive;
    if (d != null) {
      // ★ r673：右栏的「打开」现在对**目录**也成立（= 进入）。目录与文件
      //   走两条既有路径（Drive 栈 / 文件预览），这里只是把"目录"补上，
      //   不新造导航实现。
      if (d.isDir) {
        ref.read(driveStackProvider.notifier).push(d.displayPath);
        track(ref, _usageModule, UsageAction.open, objectType: 'folder');
        return;
      }
      driveOpenEntry(context, ref, d);
      return;
    }
    if (s.entry.isDir) {
      ref.read(fileBrowseStackProvider.notifier).open(s.entry.path);
      track(ref, _usageModule, UsageAction.open, objectType: 'folder');
      return;
    }
    _preview(s.entry);
  }

  /// ★ r284：左栏 Drive 行在**宽屏**下的落点（由 `DriveBrowseView` 回调上来）。
  ///
  /// ★ r671（`DA298`）：**Drive 源是另一套左栏**（`DriveBrowseView` 的 `DriveEntryDto`），
  ///   所以 NAS 那边 `_onTap` 的"再点一次就打开"必须在这里同样写一遍 ——
  ///   否则 `/mydrive`（Office 走查用的就是它）点两下也只是选中（真机实测
  ///   `detail=true preview=false`，两轮假红就是这么来的）。
  void _onWideDriveSelect(DriveEntryDto d) {
    final now = DateTime.now();
    final quickSecondTap =
        _lastTapPath == d.fileId &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) <= const Duration(milliseconds: 500);
    final alreadyShown = _wide?.drive?.fileId == d.fileId;
    _lastTapPath = d.fileId;
    _lastTapAt = now;
    if (quickSecondTap || alreadyShown) {
      _lastTapPath = null;
      _lastTapAt = null;
      final sel = WideSelection(entry: driveEntryAsFile(d), drive: d);
      if (d.isDir) {
        ref.read(driveStackProvider.notifier).push(d.displayPath);
        track(ref, _usageModule, UsageAction.open, objectType: 'folder');
        return;
      }
      _openWide(sel);
      return;
    }
    trackFile(ref, UsageModule.drive, UsageAction.preview, d.name);
    setState(() => _wide = WideSelection(entry: driveEntryAsFile(d), drive: d));
  }

  /// 打开预览页：带上同目录里"可以左右滑着看"的文件（图片/文本/可内嵌 PDF）。
  ///
  /// ⚠️ 这里的筛选规则必须和预览页内部**同一份**（`previewSwipeSiblings`）：
  /// 以前这里硬编码"只要图片"，导致预览页里扩了可滑类型也白扩。
  void _preview(FileEntryDto e) {
    trackFile(ref, _usageModule, UsageAction.preview, e.name);
    final siblings = previewSwipeSiblings(
      ref.read(folderCacheProvider(_current)).value ?? const [],
    );
    // ★ 用户 2026-09-25 裁决：Office 原生三种格式走「我的 Drive」同一个阅读器
    openFileUnified(context, ref, e, siblings: siblings);
  }

  Future<void> _onMenu(FileEntryDto e) async {
    final favorites = ref.read(fileFavoritesProvider).value ?? const [];
    final caps = ref.read(fileCapabilitiesProvider);
    final action = await showFileItemSheet(
      context,
      entry: e,
      isFavorite: favorites.contains(e.path),
      canShare: caps.canShare,
      recycleBin: RecyclePath.isInRecycleBin(e.path),
      wormLocked: e.wormLocked,
      // G4 / 219：离线登记状态（纯本地清单）
      isPinned: ref.read(offlinePinProvider.notifier).isPinned(e.path),
    );
    if (action == null || !mounted) return;
    await _runAction(action, [e]);
  }

  /// 点行尾的星 = 取消收藏（收藏入口仍在操作菜单里，见 [FileRow] 的说明）
  Future<void> _toggleFavorite(FileEntryDto e) async {
    final t = context.t;
    try {
      await ref.read(fileActionsProvider).setFavorite(e.path, favorite: false);
      ref.invalidate(fileFavoritesProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t.photoUnfavorited)));
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(describeFileError(err))));
      }
    }
  }

  /// C5：打开「远程挂载」页。
  ///
  /// **先探一次** `Mount.List/get`：服务器回 105/160 就地把入口标记为禁用 +
  /// 弹明确原因，**不推一个只能看错误的页面**；其余错误原样提示；成功才进页。
  Future<void> _openMounts() async {
    try {
      final snap = await ref.read(fileMountsProvider.future);
      if (!mounted) return;
      if (snap.permissionDenied) {
        ref.read(fileMountPermissionDeniedProvider.notifier).mark();
        AppSnack.show(
          context,
          fsC5(
            FsC5TextKeys.mountPermissionDenied,
            '这个账号没有挂载/卸载远程卷的权限（DSM → 控制面板 → 应用程序权限 → File Station）',
          ),
          error: true,
        );
        return;
      }
      _push(const FileMountPage());
    } catch (e) {
      if (!mounted) return;
      AppSnack.show(context, describeFileError(e), error: true);
    }
  }

  Future<void> _onSelectionAction(String action) async {
    final stack = ref.read(fileBrowseStackProvider);
    final dir = stack.last;
    final selected = (ref.read(folderCacheProvider(dir)).value ?? const [])
        .where((e) => _selected.contains(e.path))
        .toList();
    if (selected.isEmpty) return;
    await _runAction(action, selected);
  }

  /// 所有动作的唯一入口：面板只返回动作名，这里决定怎么执行
  Future<void> _runAction(String action, List<FileEntryDto> entries) async {
    final t = context.t;
    final actions = ref.read(fileActionsProvider);
    final dir = _current;
    final single = entries.length == 1 ? entries.first : null;

    // P1-6 兜底：WORM 锁定的条目即使被别的入口（多选工具条 / 长按菜单）
    // 递过来，也**不许**改名/移动/删除/压缩 —— 官方对锁定态只放行 COPY。
    const mutating = {'rename', 'move', 'delete', 'delete_forever', 'compress'};
    if (mutating.contains(action)) {
      final locked = entries.where((e) => e.wormLocked).toList();
      if (locked.isNotEmpty) {
        AppSnack.show(
          context,
          fsC5Fill(FsC5TextKeys.wormBlocked, '该文件已被 WriteOnce 锁定，不能{action}', {
            'action': locked.first.name,
          }),
          error: true,
        );
        return;
      }
    }

    try {
      switch (action) {
        case 'open':
          if (single == null) return;
          if (single.isDir) {
            ref.read(fileBrowseStackProvider.notifier).open(single.path);
            return;
          }
          await _download(single, openAfter: true);

        case 'download':
          if (entries.length > 1) {
            final ok = await confirmDanger(
              context,
              title: t.fileDownloadCount(entries.length),
              message: t.fileDownloadCountMessage,
              actionLabel: t.fileStartDownload,
            );
            if (!ok) return;
          }
          for (final e in entries) {
            await _download(e, openAfter: false);
          }

        case 'rename':
          if (single == null) return;
          final name = await promptFileName(
            context,
            title: t.photoRename,
            actionLabel: t.photoRename,
            initial: single.name,
            helperText: t.fileRenameHelper,
          );
          if (name == null || name.isEmpty || name == single.name) return;
          await actions.rename(path: single.path, name: name);
          _snack(t.driveRenamed(name));

        case 'copy':
        case 'move':
          final move = action == 'move';
          // M18：目标目录改成**浏览式选择器**（官方 `DestinationSelectFragment`），
          // 不再手打绝对路径。初始位置沿用旧默认（源目录的父级），用户可逐级进出。
          final dest = await Navigator.of(context).push<String>(
            MaterialPageRoute(
              builder: (_) => FileDestinationPickerPage(
                initialPath: _parentOf(dir),
                title: move ? t.fileMoveTo : t.fileCopyTo,
                actionLabel: move ? t.dtoActionMove : t.dtoActionCopy,
              ),
            ),
          );
          if (dest == null || dest.isEmpty) return;
          final ids = await actions.copyMove(
            paths: entries.map((e) => e.path).toList(),
            destFolderPath: dest,
            move: move,
          );
          _snack(
            ids.isEmpty ? t.fileTaskSubmitted : t.fileTaskSubmittedWithTip,
          );
          if (move) setState(_selected.clear);

        case 'compress':
          final base = single?.name ?? t.fileArchiveDefaultName;
          final draft = await showCompressSheet(
            context,
            defaultName: base.contains('.')
                ? '${base.split('.').first}.zip'
                : '$base.zip',
          );
          if (draft == null || draft.name.isEmpty) return;
          await actions.compress(
            paths: entries.map((e) => e.path).toList(),
            destFilePath: '${_trimSlash(dir)}/${draft.name}',
            format: draft.format,
            level: draft.level,
            mode: draft.mode,
            password: draft.password,
          );
          _snack(t.fileCompressSubmitted);
          if (_selected.isNotEmpty) setState(_selected.clear);

        // r305：`Extract/list` —— 不解压先看包里有什么（只读，不刷新目录）
        case 'archive_list':
          if (single == null) return;
          await showArchiveContentsSheet(
            context,
            fileName: single.name,
            load: ({String? password}) =>
                actions.listArchive(filePath: single.path, password: password),
          );

        case 'extract':
          if (single == null) return;
          final draft = await showExtractSheet(context, fileName: single.name);
          if (draft == null) return;
          await actions.extract(
            filePath: single.path,
            destFolderPath: dir,
            password: draft.password,
            codepage: draft.codepage,
          );
          _snack(t.fileExtractSubmitted);

        case 'favorite':
          if (single == null) return;
          final favorites = ref.read(fileFavoritesProvider).value ?? const [];
          final isFav = favorites.contains(single.path);
          await actions.setFavorite(single.path, favorite: !isFav);
          ref.invalidate(fileFavoritesProvider);
          _snack(isFav ? t.photoUnfavorited : t.photoFavorited);

        // G4 / 219（M67）：离线文件登记 / 取消登记 + ★302 **真把字节放到本机**
        //
        // 登记是纯客户端（秒回、不联网）；缓存走与「下载到本机」同一套引擎
        // （`FileDownloadResumer` + Range），落到 `<Documents>/offline_cache/`，
        // 完成后把 `localPath` 回填 → 清单显示"已缓存"、SAF 索引（系统「文件」）
        // 才真的有东西可列。缓存失败**不回滚登记**，如实提示原因。
        case 'offline_pin':
          if (single == null) return;
          final pins = ref.read(offlinePinProvider.notifier);
          final entry = OfflinePinEntry(
            path: single.path,
            name: single.name,
            size: single.size,
            pinnedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          );
          final nowPinned = await pins.toggle(entry);
          if (!nowPinned) {
            _snack(fsG4(FsG4TextKeys.offlineUnpinned, '已移出离线文件'));
            return;
          }
          _snack(fsG4(FsG4TextKeys.offlinePinned, '已加入离线文件，正在缓存到本机…'));
          // 目录只登记不缓存（官方也没有"把整个目录塞进本机"的离线语义）。
          if (single.isDir) return;
          final cached = await ref
              .read(offlineCacherProvider)
              .cache(path: entry.path, name: entry.name);
          if (!cached.ok) {
            _snack(
              fsG4Fill(FsG4TextKeys.offlineCacheFailed, '已登记，但缓存失败：{reason}', {
                'reason': cached.error ?? '未知原因',
              }),
              error: true,
            );
            return;
          }
          await pins.setLocalPath(single.path, cached.localPath);
          _snack(
            fsG4Fill(FsG4TextKeys.offlineCached, '已缓存到本机（{size}）', {
              'size': driveHumanSize(cached.bytes),
            }),
          );

        case 'properties':
          if (single == null) return;
          await showFilePropertiesSheet(context, single);

        // ------------------------------------------------ wave2 M72
        case 'shortcut':
          if (single == null || !single.isDir) return;
          final ok = await ref
              .read(shortcutBridgeProvider)
              .pinShortcut(
                id: 'fs-${single.path}',
                label: single.name,
                path: single.path,
              );
          _snack(
            ok
                ? fsGap2(FsGap2TextKeys.shortcutDone, '已请求创建快捷方式')
                : fsGap2(FsGap2TextKeys.shortcutFailed, '这台设备不支持创建快捷方式'),
            error: !ok,
          );

        case 'dirsize':
          final id = await actions.dirSize(entries.map((e) => e.path).toList());
          _snack(
            id.isEmpty ? t.fileDirSizeSubmitted : t.fileDirSizeSubmittedId(id),
          );

        case 'delete':
          final ok = await confirmDanger(
            context,
            title: t.fileDeleteCount(entries.length),
            message: entries.length == 1
                ? t.fileDeleteOneConfirm(entries.first.name)
                : t.fileDeleteManyConfirm(entries.length),
          );
          if (!ok) return;
          await actions.delete(entries.map((e) => e.path).toList());
          if (mounted) setState(_selected.clear);
          _snack(t.fileDeleted);

        // ---------------------------------------------------------- P0-a
        case 'restore':
          await _restoreFromRecycle(entries);

        case 'delete_forever':
          await _deleteForever(entries);

        case 'empty_recycle':
          await _emptyRecycle();

        case 'share':
          await _createShareLink(entries);

        // r121：多选条上的「More」原来**没有任何分支** ⇒ 点按毫无反应
        // （死按钮；真机像素取证 `files_16_more.png` → `files_17_more2.png`
        // 前后无变化）。单选时直接复用行菜单（与行尾 ⋮ 同一套动作、同一口径）；
        // 多选时列出**能批量执行**的动作，不摆会静默失败的项。
        case 'more':
          if (single != null) {
            final favorites = ref.read(fileFavoritesProvider).value ?? const [];
            final caps = ref.read(fileCapabilitiesProvider);
            final picked = await showFileItemSheet(
              context,
              entry: single,
              isFavorite: favorites.contains(single.path),
              canShare: caps.canShare,
              recycleBin: RecyclePath.isInRecycleBin(single.path),
              wormLocked: single.wormLocked,
              isPinned: ref
                  .read(offlinePinProvider.notifier)
                  .isPinned(single.path),
            );
            if (picked == null || picked.isEmpty || picked == 'more') return;
            if (!mounted) return;
            await _runAction(picked, entries);
            return;
          }
          final canShare = ref.read(fileCapabilitiesProvider).canShare;
          final batchPicked = await showModalBottomSheet<String>(
            context: context,
            showDragHandle: true,
            builder: (sheetContext) => SafeArea(
              child: SingleChildScrollView(
                child: AppSheetSection(
                  label: t.fileSelectedCount(entries.length),
                  children: [
                    AppSheetAction(
                      key: const Key('file-more-download'),
                      icon: Icons.download_outlined,
                      label: t.dtoActionDownload,
                      onTap: () => Navigator.of(sheetContext).pop('download'),
                    ),
                    AppSheetAction(
                      key: const Key('file-more-copy'),
                      icon: Icons.content_copy_outlined,
                      label: t.dtoActionCopy,
                      onTap: () => Navigator.of(sheetContext).pop('copy'),
                    ),
                    AppSheetAction(
                      key: const Key('file-more-move'),
                      icon: Icons.drive_file_move_outline,
                      label: t.dtoActionMove,
                      onTap: () => Navigator.of(sheetContext).pop('move'),
                    ),
                    AppSheetAction(
                      key: const Key('file-more-compress'),
                      icon: Icons.inventory_2_outlined,
                      label: t.dtoFileTaskCompress,
                      onTap: () => Navigator.of(sheetContext).pop('compress'),
                    ),
                    // r296（收口 D2b，与单条目面板同一处口径）：多选里**全是目录**时
                    // 才给"计算文件夹大小"；`SYNO.FileStation.DirSize.start` 收的就是
                    // 路径数组，多个目录一次提交本来也支持。
                    if (entries.every((e) => e.isDir))
                      AppSheetAction(
                        key: const Key('file-more-dirsize'),
                        icon: Icons.calculate_outlined,
                        label: t.fileDirSize,
                        onTap: () => Navigator.of(sheetContext).pop('dirsize'),
                      ),
                    AppSheetAction(
                      key: const Key('file-more-delete'),
                      icon: Icons.delete_outline,
                      label: t.dtoActionDelete,
                      onTap: () => Navigator.of(sheetContext).pop('delete'),
                    ),
                    if (canShare)
                      AppSheetAction(
                        key: const Key('file-more-share'),
                        icon: Icons.link_outlined,
                        label: fsP0a(FsP0aTextKeys.shareAdd, '创建分享链接'),
                        onTap: () => Navigator.of(sheetContext).pop('share'),
                      ),
                  ],
                ),
              ),
            ),
          );
          if (batchPicked == null) return;
          if (!mounted) return;
          await _runAction(batchPicked, entries);
      }
    } catch (e) {
      if (mounted) _snack(describeFileError(e), error: true);
    } finally {
      if (mounted) ref.invalidate(fileTasksProvider);
    }
  }

  /// 还原回收站条目（P0-2 / P0-b）：先探测目标位置同名冲突 → 用户选
  /// 覆盖/跳过（无冲突则普通二次确认）→ `CopyMove.start` +
  /// `restore_from_recycle_bin`，`overwrite` 用用户的选择（**不再硬编码**）。
  Future<void> _restoreFromRecycle(List<FileEntryDto> entries) async {
    final actions = ref.read(fileActionsProvider);
    final paths = entries.map((e) => e.path).toList();
    List<String> conflicts;
    try {
      conflicts = await actions.recycleRestoreConflicts(paths);
    } catch (_) {
      conflicts = const [];
    }
    if (!mounted) return;
    var overwrite = false;
    if (conflicts.isNotEmpty) {
      final choice = await showRestoreConflictSheet(
        context,
        conflicts: conflicts,
      );
      if (choice == null) return; // 取消 → 中止还原
      overwrite = choice;
    } else {
      final ok = await confirmDanger(
        context,
        title: fsP0a(FsP0aTextKeys.recycleRestore, '还原'),
        message: fsP0a(FsP0aTextKeys.recycleRestoreConfirm, '将所选项目还原到原位置？'),
        actionLabel: fsP0a(FsP0aTextKeys.recycleRestore, '还原'),
      );
      if (!ok) return;
    }
    await actions.restoreFromRecycle(paths, overwrite: overwrite);
    if (mounted) setState(_selected.clear);
    _snack(fsP0a(FsP0aTextKeys.recycleRestored, '已还原'));
  }

  /// 回收站内永久删除：**必须二次确认**（不可恢复）。
  Future<void> _deleteForever(List<FileEntryDto> entries) async {
    final t = context.t;
    final ok = await confirmDanger(
      context,
      title: fsP0a(FsP0aTextKeys.deleteForever, '永久删除'),
      message: fsP0a(
        FsP0aTextKeys.deleteForeverConfirm,
        '此操作将永久删除所选项目，无法恢复。是否继续？',
      ),
      actionLabel: fsP0a(FsP0aTextKeys.deleteForever, '永久删除'),
    );
    if (!ok) return;
    await ref
        .read(fileActionsProvider)
        .deleteForever(entries.map((e) => e.path).toList());
    if (mounted) setState(_selected.clear);
    _snack(t.fileDeleted);
  }

  /// 清空共享文件夹的回收站（P0-2）：**必须二次确认且文案说明不可恢复**。
  Future<void> _emptyRecycle() async {
    final share = RecyclePath.shareOf(_current);
    if (share == null) return;
    final ok = await confirmDanger(
      context,
      title: fsP0a(FsP0aTextKeys.recycleEmpty, '清空回收站'),
      message: fsP0a(
        FsP0aTextKeys.recycleEmptyConfirm,
        '回收站中的全部内容将被永久删除且不可恢复。是否确定继续？',
      ),
      actionLabel: fsP0a(FsP0aTextKeys.recycleEmpty, '清空回收站'),
    );
    if (!ok) return;
    await ref.read(fileActionsProvider).purgeRecycleBin(share);
    _snack(fsP0a(FsP0aTextKeys.recycleEmptyDone, '回收站已清空'));
  }

  /// 创建分享链接（P0-1）：填密码/有效期 → `Sharing.create` → 展示 URL。
  Future<void> _createShareLink(List<FileEntryDto> entries) async {
    final draft = await showCreateShareLinkSheet(context);
    if (draft == null || !mounted) return;
    final links = await ref
        .read(fileActionsProvider)
        .createShareLink(
          paths: entries.map((e) => e.path).toList(),
          password: draft.password,
          dateExpired: draft.dateExpired,
        );
    if (!mounted) return;
    final url = links.isEmpty ? '' : links.first.url;
    if (url.isEmpty) {
      _snack(fsP0a(FsP0aTextKeys.shareCreateFailed, '创建分享链接失败'), error: true);
      return;
    }
    await showShareLinkCreatedSheet(
      context,
      url,
      // 官方把文件名当 `EXTRA_SUBJECT`（`ResourceListFragment.java:2095-2098`）
      subject: entries.isEmpty ? '' : entries.first.name,
    );
  }

  /// 下载（可带"下完就打开"）。进度框复用聊天的那一个，逻辑在 file_download.dart。
  Future<void> _download(FileEntryDto e, {required bool openAfter}) async {
    final t = context.t;
    final result = await downloadFileEntry(
      context,
      e,
      actions: ref.read(fileActionsProvider),
      openAfter: openAfter,
    );
    if (!mounted) return;
    switch (result.status) {
      case FileDownloadStatus.cancelled:
        return;
      case FileDownloadStatus.failed:
        _snack(result.message ?? t.apiDownloadFailed, error: true);
      case FileDownloadStatus.ok:
        if (!openAfter) _snack(t.fileDownloadedToDownloads);
    }
  }

  Future<void> _showCreateSheet() async {
    final t = context.t;
    final action = await showAppSheet<String>(
      context,
      title: t.fileNewUpload,
      children: [
        AppSheetSection(
          children: [
            AppSheetAction(
              icon: Icons.create_new_folder_outlined,
              label: t.fileNewFolder,
              onTap: () => Navigator.of(context).pop('folder'),
            ),
            AppSheetAction(
              icon: Icons.upload_file_outlined,
              label: t.driveUploadFileTitle,
              description: t.fileUploadFromDevice(_displayName(_current, t)),
              onTap: () => Navigator.of(context).pop('upload'),
            ),
            // M73（审计行 225）：官方文件抽屉的 "Instant Upload" / PBUploadManager。
            // 定位**刻意收窄**成"一次性、手动、传进当前目录"，
            // 与相册侧的自动备份不重叠（见 file_local_photos_pick.dart 顶部）。
            AppSheetAction(
              key: const Key('file-upload-local-photo'),
              icon: Icons.add_photo_alternate_outlined,
              label: localPhotosSheetTitle(),
              // ★ r371（DA15）：这一行原来和上面「上传文件」**共用同一句副标题**
              //   （两行说的都是"挑一个文件传上去"）⇒ 用户看不出差别。
              //   照片那条走自己的一句（说的是"从相册选照片"）。
              description: t.fileUploadLocalPhotoFromDevice(
                _displayName(_current, t),
              ),
              onTap: () => Navigator.of(context).pop('uploadPhoto'),
            ),
          ],
        ),
        AppSheetSection(
          children: [
            AppSheetAction(
              icon: Icons.refresh,
              label: t.photoRefresh,
              onTap: () => Navigator.of(context).pop('refresh'),
            ),
          ],
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'folder':
        final name = await promptFileName(
          context,
          title: t.fileNewFolder,
          actionLabel: t.photoCreate,
          helperText: t.driveCreateInPath(_displayName(_current, t)),
        );
        if (name == null || name.isEmpty) return;
        try {
          await ref
              .read(fileActionsProvider)
              .createFolder(folderPath: _current, name: name);
          _snack(t.driveCreated(name));
        } catch (e) {
          _snack(describeFileError(e), error: true);
        }
      case 'upload':
        await _pickAndUpload();
      case 'uploadPhoto':
        await _pickAndUploadLocalPhoto();
      case 'refresh':
        await _refresh();
    }
  }

  /// M73：挑一张本机照片 → `PhotoUpload` 传进当前目录。
  ///
  /// 权限被拒 / 没有照片 / 选择器报错 —— 三种情况**分别给不同提示**，
  /// 不笼统报"上传失败"。
  Future<void> _pickAndUploadLocalPhoto() async {
    List<DeviceMediaAsset> assets;
    try {
      assets = await ref.read(localPhotosProvider.future);
    } on DeviceMediaPermissionDenied {
      if (mounted) _snack(localPhotosNeedPermission(), error: true);
      return;
    } catch (_) {
      if (mounted) _snack(localPhotosPickFailed(), error: true);
      return;
    }
    if (!mounted) return;

    final picked = await showLocalPhotosSheet(context, assets: assets);
    if (picked.isEmpty || !mounted) return;
    final asset = picked.first;

    final lib = ref.read(deviceMediaLibraryProvider);
    String? localPath;
    try {
      localPath = await lib.materialize(asset);
    } catch (_) {
      localPath = null;
    }
    if (localPath == null || localPath.isEmpty) {
      if (mounted) _snack(localPhotosPickFailed(), error: true);
      return;
    }
    if (!mounted) return;

    final actions = ref.read(fileActionsProvider);
    final caps = ref.read(fileCapabilitiesProvider);

    // 与普通上传**同一套**冲突策略：默认绝不静默覆盖。
    var fileName = asset.displayName;
    final hasConflict = await actions.uploadConflictExists(
      folderPath: _current,
      fileName: fileName,
    );
    UploadConflictPolicy? conflict;
    if (hasConflict == true) {
      if (!mounted) return;
      final choice = await showUploadConflictSheet(
        context,
        fileName: fileName,
        allowRename: caps.canUploadRename,
      );
      if (choice == null || !mounted) return;
      conflict = choice;
      if (choice == UploadConflictPolicy.rename) {
        fileName = await actions.suggestUploadName(
          folderPath: _current,
          fileName: fileName,
        );
      }
    } else if (hasConflict == null) {
      conflict = UploadConflictPolicy.skip;
    }
    if (!mounted) return;

    final progress = ValueNotifier<({int sent, int total})>((
      sent: 0,
      total: asset.size,
    ));
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          UploadProgressDialog(fileName: fileName, progress: progress),
    );
    try {
      await actions.uploadPhoto(
        folderPath: _current,
        localPath: localPath,
        fileName: fileName,
        conflict: conflict,
        onProgress: (sent, total) =>
            progress.value = (sent: sent, total: total < 0 ? 0 : total),
      );
      if (mounted) navigator.pop();
      _snack(localPhotosUploaded(fileName));
    } catch (e) {
      if (mounted) navigator.pop();
      _snack(describeFileError(e), error: true);
    } finally {
      progress.dispose();
    }
  }

  Future<void> _pickAndUpload() async {
    // file_picker 13 起是静态 API（`FilePicker.platform` 没了），
    // 多选参数也随 12.0 的联邦化重写取消 —— 这里逐个传，进度更直观。
    //
    // r319：选择器走 `fileUploadPickerProvider`（默认实现 = 原来的 `FilePicker.pickFile()`，
    // 生产行为逐字不变）。抽这层缝**只为让"上传"这条写动词能被自动化验到整链** ——
    // 原生选择器（NSOpenPanel / SAF）在自动化里点不到。见 `file_upload_picker.dart`。
    final t = context.t;
    final picked = await ref.read(fileUploadPickerProvider)();
    final path = picked?.path;
    if (picked == null || path == null || !mounted) return;

    final actions = ref.read(fileActionsProvider);
    final caps = ref.read(fileCapabilitiesProvider);

    // ---- P0-a：上传前冲突检测 + 冲突面板（**默认绝不静默覆盖**）----
    //
    // 官方 DS file `AbsBasicFragment.uploadSelect` → `hasCommonFilename()`：
    // 先列目标目录、按文件名判断有没有同名，有才弹 `ConflictActionSheet`；
    // 没有冲突时用 `OverWriteMode.NONE`（**不发 overwrite 字段**）。
    var fileName = picked.name;
    final hasConflict = await actions.uploadConflictExists(
      folderPath: _current,
      fileName: fileName,
    );
    UploadConflictPolicy? conflict;
    if (hasConflict == true) {
      if (!mounted) return;
      final choice = await showUploadConflictSheet(
        context,
        fileName: fileName,
        allowRename: caps.canUploadRename,
      );
      // 取消 = 中止上传；**不能**退回成覆盖
      if (choice == null || !mounted) return;
      conflict = choice;
      if (choice == UploadConflictPolicy.rename) {
        fileName = await actions.suggestUploadName(
          folderPath: _current,
          fileName: fileName,
        );
      }
    } else if (hasConflict == null) {
      // 检测失败（离线/无权限）：无法确知是否冲突 → 发 `skip` 兜底，
      // 宁可这次不覆盖，也不默认覆盖。
      conflict = UploadConflictPolicy.skip;
    }

    if (!mounted) return;
    final progress = ValueNotifier<({int sent, int total})>((
      sent: 0,
      total: picked.size ?? 0,
    ));
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          UploadProgressDialog(fileName: fileName, progress: progress),
    );

    try {
      await actions.upload(
        folderPath: _current,
        localPath: path,
        fileName: fileName,
        conflict: conflict,
        onProgress: (sent, total) =>
            progress.value = (sent: sent, total: total < 0 ? 0 : total),
      );
      if (mounted) navigator.pop();
      trackFile(
        ref,
        _usageModule,
        UsageAction.upload,
        fileName,
        size: picked.size ?? 0,
        detail: {'source': _usageModule.id},
      );
      _snack(
        conflict == UploadConflictPolicy.rename && fileName != picked.name
            ? fsP0aFill(FsP0aTextKeys.uploadRenamed, '已重命名为 {name}', {
                'name': fileName,
              })
            : t.fileUploaded(fileName),
      );
    } catch (e) {
      if (mounted) navigator.pop();
      // 失败要能回答"为什么失败"：原因码 + 错误类型（不留 message）
      trackOnceFailure(
        _usageModule,
        UsageAction.upload,
        reason: UsageFailureReason.unknown,
        error: e,
      );
      _snack(describeFileError(e), error: true);
    } finally {
      progress.dispose();
    }
  }

  Future<void> _showSortSheet() async {
    final t = context.t;
    final current = ref.read(fileSortProvider);
    final chosen = await showAppSheet<FileSortBy>(
      context,
      title: t.fileSortTitle,
      children: [
        AppSheetSection(
          children: [
            for (final by in FileSortBy.values)
              AppSheetAction(
                icon: _sortIcon(by),
                label: _sortLabel(by, t),
                selected: current.sortBy == by,
                trailing: current.sortBy == by
                    ? Icon(
                        current.sortDirection == FileSortDirection.asc
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 16,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(by),
              ),
          ],
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    // `folderSyncProvider` watch 了排序状态 → 这里只要改状态，重新请求自动发生
    ref.read(fileSortProvider.notifier).setSortBy(chosen);
    // 排序偏好（name/size/modified_time/type）——只记稳定枚举名
    trackSort(_usageModule, chosen.name);
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    AppSnack.show(context, message, error: error);
  }
}

// ---------------------------------------------------------------- 顶部

class _Deck extends StatelessWidget {
  const _Deck({
    required this.path,
    required this.selecting,
    required this.selectedCount,
    required this.caps,
    required this.source,
    required this.onSource,
    required this.onCancelSelection,
    required this.onUp,
    required this.onSort,
    required this.onSearch,
    required this.onFavorites,
    required this.onShareLinks,
    required this.onRecycleBin,
    required this.onEmptyRecycle,
    required this.onTasks,
    this.tasksBadge = 0,
    required this.onMounts,
    required this.onFilter,
    this.onTools,
    required this.downloadTasks,
    required this.viewMode,
    required this.onToggleView,
  });

  final String path;
  final bool selecting;
  final int selectedCount;
  final FileCapabilities caps;
  final FileSource source;
  final ValueChanged<FileSource> onSource;
  final VoidCallback onCancelSelection;

  /// ★ 第 259 轮：**返回上一级**。
  ///
  /// 真机上暴露的严重可用性缺陷：NAS 源进到子目录后**没有任何"上一级"入口**
  /// （`FileBrowseStackNotifier.up()` 写好了却没人调），面包屑那行又只有
  /// 30dp 高、点不准；再按系统返回键**直接退出整个 App**
  /// （`_Deck` 是 tab 内的一层状态，不是路由）⇒ 用户进了深层目录就"回不去"。
  /// 现在：进到子目录时头部常驻一个「上一级」，系统返回键也先逐级返回。
  final VoidCallback? onUp;
  final VoidCallback onSort;
  final VoidCallback onSearch;
  final VoidCallback onFavorites;
  final VoidCallback? onShareLinks;

  /// 共享文件夹根 → 进入 `#recycle` 视图（P0-2）
  final VoidCallback? onRecycleBin;

  /// 回收站根 + 管理员 → 清空回收站（P0-2）
  final VoidCallback? onEmptyRecycle;
  final VoidCallback onTasks;

  /// ★ D67：后台未读角标数（0 = 不显示角标）
  final int tasksBadge;

  /// C5：远程挂载管理入口（服务器没有 Mount/Mount.List 时为 null → 不渲染）
  final VoidCallback? onMounts;

  /// P1-1：目录内过滤开关（官方 `AbsResourceFragment` 的 Filter）
  final VoidCallback? onFilter;

  /// G4：文件工具（223 外接设备 / 219 离线文件；Drive 源不渲染）
  final VoidCallback? onTools;

  /// W1-3 收尾：下载任务列表（顶栏常驻入口；能力位缺失时不渲染）
  final FileDownloadTaskList downloadTasks;

  /// 列表 / 网格
  final FileViewMode viewMode;
  final VoidCallback onToggleView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final t = context.t;

    if (selecting) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.md, Gap.sm),
        child: Row(
          children: [
            Text(
              t.fileSelectedCount(selectedCount),
              style: theme.textTheme.titleMedium,
            ),
            const Spacer(),
            IconButton(
              // ★★ r348 D59：真机 dump 逐字「全选/取消」，可图标是 **✕**(`Icons.close`)、
              //   回调是 `onCancelSelection`（**只退出多选**，并没有"全选"这个动作）。
              //   三处自相矛盾：**标签承诺了一个不存在的功能**，读屏用户听到「全选/取消」
              //   却点出一个"退出"。改成与动作一致的「取消全选」/「Deselect all」
              //   （与 `drive_browse_view.dart` 的同一语义用词对齐，不新增 ARB 键）。
              tooltip: t.deselectAll,
              onPressed: onCancelSelection,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ⚠️ 真机（360dp 宽的 LG 手机）在这行溢出过 20px：标题 + 装饰标签 +
          // 5 个 IconButton 挤不下。所以标题可省略号、装饰标签只在够宽时出现。
          LayoutBuilder(
            builder: (context, c) {
              // 又加了一个「列表/网格」按钮 → 装饰标签的门槛跟着抬高，
              // 360dp 的机器上一行要放得下 6 个图标 + 标题（真机溢出过）
              final wide = c.maxWidth >= 520;
              // ★ 第 258 轮：动作数会随能力位/回收站/任务/视图变化（最多 9 个
              // IconButton）。原来它们全在 `Row` 尾部 + `Spacer()`，真机上
              // **直接冲出右边界**（最后一个图标被裁掉，点不到）。
              // 现在：动作条夹在"总宽 - 标题预留"里，放不下就横向滚动；
              // `spaceBetween` 把动作条钉在右侧，中间空白留给标题。
              final stripMax = (c.maxWidth - 200).clamp(96.0, c.maxWidth);
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      t.wsFiles,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (wide) ...[
                    const SizedBox(width: Gap.sm),
                    TelemetryLabel('FILE STATION', size: 10, decorative: true),
                  ],
                  FoldingActions(
                    width: stripMax,
                    reserve: 0,
                    children: [
                      // ★ 第 259 轮：进到子目录才出现（根目录不出现，避免无意义按钮）
                      if (onUp != null)
                        IconButton(
                          key: const Key('file-up'),
                          tooltip: fsC5(FsC5TextKeys.up, '上一级'),
                          onPressed: onUp,
                          icon: const Icon(Icons.arrow_upward),
                        ),
                      IconButton(
                        tooltip: t.fileSearchTitle,
                        onPressed: onSearch,
                        icon: const Icon(Icons.search),
                      ),
                      IconButton(
                        tooltip: t.photoSectionFavorites,
                        onPressed: onFavorites,
                        icon: const Icon(Icons.star_border),
                      ),
                      if (onShareLinks != null)
                        IconButton(
                          tooltip: t.fileShareLinksTitle,
                          onPressed: onShareLinks,
                          icon: const Icon(Icons.link),
                        ),
                      // P0-2：共享文件夹根的回收站入口 / 回收站根的清空入口
                      if (onRecycleBin != null)
                        IconButton(
                          tooltip: fsP0a(FsP0aTextKeys.recycleBin, '回收站'),
                          onPressed: onRecycleBin,
                          icon: const Icon(Icons.delete_outline),
                        ),
                      if (onEmptyRecycle != null)
                        IconButton(
                          tooltip: fsP0a(FsP0aTextKeys.recycleEmpty, '清空回收站'),
                          onPressed: onEmptyRecycle,
                          icon: const Icon(Icons.delete_sweep_outlined),
                        ),
                      // W1-3 收尾：下载任务的常驻入口（有活跃任务时带数量徽标）。
                      // 能力位缺失 → 入口**不渲染**，原因在同行的尾随提示里给出。
                      if (caps.canDownload)
                        _DownloadTasksButton(
                          tasks: downloadTasks,
                          onPressed: () => openFileDownloadTasksDialog(
                            context,
                            downloadTasks,
                          ),
                        ),
                      if (tasksBadge > 0)
                        Badge(
                          key: const Key('file-drive-tasks-badge'),
                          label: Text('$tasksBadge'),
                          child: IconButton(
                            tooltip: t.wsTasks,
                            onPressed: onTasks,
                            icon: const Icon(Icons.sync),
                          ),
                        )
                      else
                        IconButton(
                          tooltip: t.wsTasks,
                          onPressed: onTasks,
                          icon: const Icon(Icons.sync),
                        ),
                      IconButton(
                        tooltip: viewMode == FileViewMode.grid
                            ? t.fileGridViewSwitch
                            : t.fileListViewSwitch,
                        onPressed: onToggleView,
                        icon: Icon(
                          viewMode == FileViewMode.grid
                              ? Icons.view_list_rounded
                              : Icons.grid_view_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: t.fileSortTooltip,
                        onPressed: onSort,
                        icon: const Icon(Icons.sort),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: Gap.sm),
          Row(
            children: [
              // 两个来源胶囊也必须有界：`Row` 给非 flex 子项的是**无界**宽度，
              // 2.0 缩放下两个胶囊本身的文案就够撑爆这一行（实测最多 131px）。
              Flexible(
                child: FileSourceChip(
                  label: t.fileSourceNas,
                  selected: source == FileSource.nas,
                  onTap: () =>
                      onSource(FileSource.nas), // 埋点在 _SourceSwitch 回调里
                ),
              ),
              const SizedBox(width: Gap.sm),
              Flexible(
                child: FileSourceChip(
                  label: t.driveMyDrive,
                  selected: source == FileSource.drive,
                  onTap: () => onSource(FileSource.drive),
                ),
              ),
              // 尾随动作/状态：必须**有界 + 可省略**，否则英文或大字号下
              // 这一行会横向溢出（2.0 缩放在 360 宽屏实测溢出 131px）。
              // 用一个右对齐的内部 `Row` + `Flexible`（**不要**再放 `Spacer`：
              // 那会让 Flexible 只拿到一半剩余宽度）：1.0 缩放时仍然贴右、
              // 外观不变；放不下时标签省略而不是溢出。
              Flexible(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Drive 源专有：回收站/星标/共享给我/团队文件夹（P3）
                    if (source == FileSource.drive)
                      Flexible(
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Gap.sm,
                            ),
                            minimumSize: const Size(0, 32),
                          ),
                          onPressed: () => Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => const DriveMorePage(),
                            ),
                          ),
                          icon: const Icon(Icons.more_horiz, size: 16),
                          label: Text(
                            t.photoMore,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                    else ...[
                      // P1-1：目录内筛选（纯客户端，只筛已缓存的行）
                      if (onFilter != null)
                        Flexible(
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Gap.sm,
                              ),
                              minimumSize: const Size(0, 32),
                            ),
                            onPressed: onFilter,
                            icon: const Icon(
                              Icons.filter_alt_outlined,
                              size: 16,
                            ),
                            // ★ D17：这里原来用长标签（`Filter in folder`），
                            //   360dp / 窄窗口下被 ellipsis 截成 `Filter in fol…`
                            //   ⇒ 改用短标签，长文案进 tooltip（§2.0.18：不许改字号）。
                            label: Tooltip(
                              message: fsC5(FsC5TextKeys.filterHint, '在目录内筛选'),
                              child: Text(
                                fsC5(FsC5TextKeys.filterChip, '筛选'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      // C5：远程挂载 / 虚拟卷管理（只在服务器提供该 API
                      // 且没被拒过权限时渲染）
                      if (onMounts != null)
                        Flexible(
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Gap.sm,
                              ),
                              minimumSize: const Size(0, 32),
                            ),
                            onPressed: onMounts,
                            icon: const Icon(Icons.cloud_outlined, size: 16),
                            // ★ D17：同上（原来被截成 `Remote mo…`）。
                            label: Tooltip(
                              message: fsC5(FsC5TextKeys.mountTitle, '远程挂载'),
                              child: Text(
                                fsC5(FsC5TextKeys.mountChip, '挂载'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      // G4：文件工具（223 外接设备 / 219 离线文件）入口
                      // **不在这里**渲染：这一行在 360dp 已经"刚好放得下"，
                      // 再加一个 `TextButton.icon` 会把筛选/挂载两个按钮
                      // 挤到溢出 3.6px（`file_mount_ui_test` 的 360dp 用例
                      // 会红）。它独占下面一行（有界宽度，任何宽度都不溢出）。
                      if (!caps.canShare)
                        Flexible(
                          child: TelemetryLabel(
                            t.fileShareDisabled,
                            size: 10,
                            color: hud.dim,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          // G4：文件工具（223 外接设备 / 219 离线文件）—— **单独一行**。
          //
          // 为什么不塞进上面任一行：第二行（来源胶囊 + 筛选 + 挂载）在 360dp
          // 已经"刚好放得下"，再加一个 `TextButton.icon`（内部 Row 最小宽度
          // = 图标 16 + 间距 8 = 24px）会把同行的筛选/挂载挤到**溢出 3.6px**
          // ——`file_mount_ui_test` 的 360dp 用例正是守这条线，实测会红。
          // 单独一行是有界宽度（整行 360dp 给一个 24px 起的按钮），任何宽度
          // 都不会溢出。只在 NAS 源出现（Drive 源的工具在 DriveMore 里）。
          if (onTools != null) ...[
            const SizedBox(height: Gap.xs),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('file-tools-entry'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                  minimumSize: const Size(0, 32),
                ),
                onPressed: onTools,
                icon: const Icon(Icons.build_outlined, size: 16),
                label: Text(
                  fsG4(FsG4TextKeys.toolsTitle, '文件工具'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          // 下载能力位缺失 → 下载任务入口不渲染，原因单独占一行给出。
          //
          // 为什么不塞进上面任一行：360dp + 6 个 56dp IconButton 时第一行已经
          // 没有余量（加一个固定 `SizedBox` 就溢出 8px），第二行的两个来源
          // 胶囊也不肯被压到"图标 + 内边距"以下（实测溢出 3.6px）。单独一行
          // 是**有界宽度**，`TelemetryLabel` 自己省略号，任何宽度都不会溢出。
          if (!caps.canDownload) ...[
            const SizedBox(height: Gap.xs),
            TelemetryLabel(
              fileDownloadDisabled(),
              key: const Key('file-download-disabled-reason'),
              size: 10,
              color: hud.dim,
            ),
          ],
        ],
      ),
    );
  }
}

/// 顶栏「下载任务」的常驻入口：有活跃任务时显示数量徽标 + 进度 tooltip。
///
/// 只算 **排队 / 传输 / 暂停** 为活跃（完成 / 失败 / 取消不再计数）；
/// 徽标是纯覆盖层（`Badge`），不占额外宽度 —— 360dp 窄屏不会再溢出。
class _DownloadTasksButton extends StatelessWidget {
  const _DownloadTasksButton({required this.tasks, required this.onPressed});

  final FileDownloadTaskList tasks;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tasks,
      builder: (context, _) {
        final active = tasks.tasks.where((t) => t.isActive).toList();
        final running = active
            .where((t) => t.status == FileDownloadTaskStatus.running)
            .toList();
        final percent = running.isEmpty ? null : running.first.percent;
        final icon = IconButton(
          key: const Key('file-download-tasks-entry'),
          tooltip: fileDownloadTaskEntryTooltip(active.length, percent),
          onPressed: onPressed,
          icon: const Icon(Icons.download_outlined),
        );
        if (active.isEmpty) return icon;
        return Badge(
          key: const Key('file-download-tasks-badge'),
          label: Text('${active.length}'),
          child: icon,
        );
      },
    );
  }
}

/// 文件来源胶囊（`NAS files` / `My Drive`）。
///
/// ★ 第 239 轮（`DA183`，用户裁定 ③）：选中态原来是
///   `scheme.primary` 文字 + `scheme.primary.withValues(alpha: 0.18)` 底，
///   透到页面底色上合成出来只有 **4.28:1**（真机亮色实测，低于 AA）。
///   与 `DA176` 的 `PhotoSegment` 同一类问题 —— 现在统一用**不透明** `primarySoft`
///   底 + `primary` 字（5.00:1）。同时把容器圆角与 InkWell 圆角对齐（原来 11 vs 胶囊）。
class FileSourceChip extends StatelessWidget {
  const FileSourceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = DesignPalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.capsule),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
        decoration: ShapeDecoration(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.capsule)),
          ),
          // 选中：**不透明** primarySoft（叠在页面底上的半透明会掉对比度）
          color: selected
              ? p.primarySoft
              : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected ? p.primary : null,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 面包屑（点第几段就跳到第几段）
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.stack, required this.onJump, this.onUp});

  final List<String> stack;
  final ValueChanged<int> onJump;

  /// 「上一级」（根目录为 null ⇒ 不摆）。★ DA291：用户报"进了子目录不知道
  /// 怎么返回父目录" —— 原来唯一的入口是折进 `⋮` 的 `file-up` 图标。
  final VoidCallback? onUp;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    // ★ 高度 30 → 44：原来是"30dp 高、只有小字能点"，手指/鼠标都难点准
    //   （48dp 是最小点击区，44 + 上下留白已接近，且不挤压列表）。
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          if (onUp != null)
            Padding(
              padding: const EdgeInsets.only(left: Gap.md - 4),
              child: TextButton.icon(
                key: const Key('file-breadcrumb-up'),
                onPressed: onUp,
                icon: const Icon(Icons.arrow_back, size: 16),
                label: Text(fsC5(FsC5TextKeys.up, '上一级')),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 40),
                  textStyle: theme.textTheme.bodySmall,
                ),
              ),
            ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              itemCount: stack.length,
              separatorBuilder: (_, _) =>
                  Icon(Icons.chevron_right, size: 14, color: hud.dim),
              itemBuilder: (context, i) {
                final isLast = i == stack.length - 1;
                return InkWell(
                  key: Key('file-crumb-$i'),
                  onTap: () => onJump(i),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 12,
                    ),
                    child: Text(
                      _displayName(stack[i], context.t),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isLast ? theme.colorScheme.primary : hud.dim,
                        fontWeight: isLast ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 多选模式下的底部工具条
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onAction,
    this.recycleBin = false,
  });

  final int count;
  final ValueChanged<String> onAction;

  /// 回收站视图：动作换成 还原 / 永久删除（P0-2）
  final bool recycleBin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = context.t;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: ShapeDecoration(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(11)),
        ),
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
      ),
      child: Row(
        children: [
          _barAction(
            context,
            Icons.download_outlined,
            t.dtoActionDownload,
            'download',
          ),
          if (recycleBin) ...[
            _barAction(
              context,
              Icons.restore_from_trash_outlined,
              fsP0a(FsP0aTextKeys.recycleRestore, '还原'),
              'restore',
            ),
            _barAction(
              context,
              Icons.delete_forever_outlined,
              fsP0a(FsP0aTextKeys.deleteForever, '永久删除'),
              'delete_forever',
              danger: true,
            ),
          ] else ...[
            _barAction(
              context,
              Icons.content_copy_outlined,
              t.dtoActionCopy,
              'copy',
            ),
            _barAction(
              context,
              Icons.drive_file_move_outline,
              t.dtoActionMove,
              'move',
            ),
            _barAction(
              context,
              Icons.inventory_2_outlined,
              t.dtoFileTaskCompress,
              'compress',
            ),
            _barAction(
              context,
              Icons.delete_outline,
              t.dtoActionDelete,
              'delete',
              danger: true,
            ),
          ],
          const Spacer(),
          TextButton(
            onPressed: () => onAction('more'),
            child: Text(t.photoMore),
          ),
        ],
      ),
    );
  }

  Widget _barAction(
    BuildContext context,
    IconData icon,
    String label,
    String action, {
    bool danger = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: label,
      onPressed: () => onAction(action == 'more' ? 'more' : action),
      icon: Icon(icon, color: danger ? scheme.error : null),
    );
  }
}

/// 网络刷新失败、但本地还有缓存时的提示条（不要用整屏错误页打断浏览）
class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.detail});
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: ShapeDecoration(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(11)),
        ),
        color: scheme.errorContainer.withValues(alpha: 0.35),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 16, color: scheme.error),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              context.t.fileStaleCache(detail),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 小工具

String _trimSlash(String path) => path.endsWith('/') && path.length > 1
    ? path.substring(0, path.length - 1)
    : path;

String _parentOf(String path) {
  final p = _trimSlash(path);
  final i = p.lastIndexOf('/');
  if (i <= 0) return '/';
  return p.substring(0, i);
}

String _displayName(String path, [AppText? t]) {
  if (path == kFileRoot) return (t ?? currentText()).fileSharedFoldersRoot;
  final p = _trimSlash(path);
  final i = p.lastIndexOf('/');
  final name = i < 0 ? p : p.substring(i + 1);
  // `#recycle` 在界面上显示成「回收站」，不暴露内部段名
  if (name == RecyclePath.segment) {
    return fsP0a(FsP0aTextKeys.recycleBin, '回收站');
  }
  return name;
}

/// `/share` 这种"共享文件夹根"（只有 1 段路径、且不是根 `/`）——
/// 回收站入口挂在这一层。
bool isShareRootPath(String path) {
  if (path.isEmpty || path == kFileRoot) return false;
  final segs = path.split('/').where((s) => s.isNotEmpty);
  return segs.length == 1;
}

IconData _sortIcon(FileSortBy by) => switch (by) {
  FileSortBy.name => Icons.sort_by_alpha,
  FileSortBy.size => Icons.data_usage,
  FileSortBy.mtime => Icons.schedule,
  FileSortBy.user => Icons.person_outline,
  FileSortBy.group => Icons.groups_outlined,
  FileSortBy.type => Icons.category_outlined,
  FileSortBy.crtime => Icons.fiber_new_outlined,
};

String _sortLabel(FileSortBy by, AppText t) => switch (by) {
  FileSortBy.name => t.sortByName,
  FileSortBy.size => t.sortBySize,
  FileSortBy.mtime => t.sortByModified,
  FileSortBy.user => t.sortByOwner,
  FileSortBy.group => t.sortByGroup,
  FileSortBy.type => t.sortByType,
  FileSortBy.crtime => t.sortByCreated,
};

/// 宽屏文件站的**硬件键盘**快捷键（`DA301`）。
///
/// 只在 `expanded` 且筛选框没开时生效 —— 其它情形**一个字节都不多包**，
/// 这样窄屏（Enter=提交表单、Esc=退出 App）的行为与改动前逐字节一致。
///
/// 键位取 Finder 的两个：
/// * `Enter` / `小键盘 Enter` ⇒ 打开当前选中项（与双击、右栏「打开」**同一条**
///   `_openWide` 路径，不新造第二种打开方式）；
/// * `Esc` ⇒ 关掉右栏信息卡（等价于点「✕ / 空白处」）。
class _WideKeys extends StatefulWidget {
  const _WideKeys({
    required this.enabled,
    required this.onOpen,
    required this.onClear,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onClear;
  final Widget child;

  @override
  State<_WideKeys> createState() => _WideKeysState();
}

class _WideKeysState extends State<_WideKeys> {
  /// `skipTraversal`：别把 Tab 顺序从列表行手里抢走（这一层只做"兜底收键"）。
  final FocusNode _node = FocusNode(
    debugLabel: 'file-wide-keys',
    skipTraversal: true,
  );

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Focus(
      focusNode: _node,
      autofocus: true,
      onKeyEvent: (node, event) {
        // 只认"按下"：`KeyRepeatEvent` 也认（长按 Enter 连续开目录是 Finder 的行为，
        // 但这里每开一级列表都会重建，重复事件不会累积 —— 认它更符合手感）。
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) {
          widget.onOpen();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.escape) {
          widget.onClear();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: widget.child,
    );
  }
}
