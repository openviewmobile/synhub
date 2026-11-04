// 「文件」模块的第二来源：Synology Drive（P0.1 尾巴）。
//
// 官方把 Drive 也放在同一个「文件」入口里（来源切换），所以这里不新开底栏位，
// 只是给 `file_browse_page` 多一个来源。协议事实见 `tool/drive_probe.dart` 与
// `docs/api-server-authoritative.md` §5.1，实现全部走 [DriveApi]（与官方逐字对齐）。
//
// 与 NAS 源的差异（有意保留，不做"看起来一样、其实是 FileStation"的假统一）：
//   * 路径是 `id:<file_id>`（官方 `Utils.getPathId`），不是文件系统路径；
//   * 条目模型是 [DriveEntryDto]（`size` / `content_type` / `capabilities`）；
//   * "我的 Drive" 只有个人空间；团队文件夹/共享/回收站/版本属于 P3。
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/media/thumb_cache.dart';
import 'book_cover.dart';
import 'pdf_cover.dart';
import '../../core/settings/app_settings.dart' show cacheServiceProvider;
import '../../data/drive_api.dart';
import '../drive/drive_selection.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/drive_file_request_dto.dart';
import '../../data/dto/drive_label_dto.dart';
import '../../data/dto/drive_notification_dto.dart';
import '../../data/dto/drive_revision_dto.dart';
import '../../data/dto/drive_search_dto.dart';
import '../../data/dto/drive_task_dto.dart';
import '../../data/dto/drive_share_dto.dart';
import '../../data/dto/drive_team_member_dto.dart';
import '../drive/drive_p0_text.dart';
import '../servers/session_controller.dart';
import 'file_thumb.dart' show ThumbScale;

/// Drive API 层。未连接时为 null（页面显示"未连接"而不是崩）。
final driveApiProvider = Provider<DriveApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : DriveApi(conn.api);
});

/// 顶部来源切换：NAS 文件 / 我的 Drive
enum FileSource { nas, drive }

final fileSourceProvider = NotifierProvider<FileSourceNotifier, FileSource>(
  FileSourceNotifier.new,
);

class FileSourceNotifier extends Notifier<FileSource> {
  @override
  FileSource build() => FileSource.nas;

  void select(FileSource source) => state = source;
}

/// Drive 的当前目录栈（根是 `/mydrive`；进入子目录压栈，面包屑点击回退）。
///
/// 与 NAS 源一样**只活在本次会话**里（官方也是回到列表就回根目录的形态）。
final driveStackProvider = NotifierProvider<DriveStackNotifier, List<String>>(
  DriveStackNotifier.new,
);

class DriveStackNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [kDriveRoot];

  String get current => state.isEmpty ? kDriveRoot : state.last;

  void push(String path) {
    if (path == current) return;
    state = [...state, path];
  }

  void popTo(int index) {
    if (index < 0 || index >= state.length) return;
    state = state.sublist(0, index + 1);
  }

  void reset() => state = const [kDriveRoot];
}

/// D19：Drive 列表的排序状态。
///
/// `by == null` = **服务端默认**（不发 `sort_by`/`sort_direction`）。默认值选
/// null 而不是 `name`：老行为就是"不排序"，不能因为加了菜单就悄悄改掉默认序。
class DriveListSort {
  const DriveListSort(this.by, {this.descending = false});

  final DriveSortBy? by;
  final bool descending;

  @override
  bool operator ==(Object other) =>
      other is DriveListSort &&
      other.by == by &&
      other.descending == descending;

  @override
  int get hashCode => Object.hash(by, descending);
}

final driveSortProvider = NotifierProvider<DriveSortNotifier, DriveListSort>(
  DriveSortNotifier.new,
);

class DriveSortNotifier extends Notifier<DriveListSort> {
  @override
  DriveListSort build() => const DriveListSort(null);

  void set(DriveSortBy? by, {bool descending = false}) =>
      state = DriveListSort(by, descending: descending);

  /// 升降序开关（没有选字段时不做事）
  void toggleDirection() {
    if (state.by == null) return;
    state = DriveListSort(state.by, descending: !state.descending);
  }
}

/// D18：Drive 列表 / 网格视图（与 NAS 源的 `FileViewMode` 分开，互不影响）
enum DriveViewMode { list, grid }

/// ★ 第 56 轮 D25：**多选状态**。
///
/// ⚠️ 与上面已有的 [driveSelectionProvider] **不是一回事**：
/// 那个是"用户点开的**当前条目**"（详情面板，单个、可空）；
/// 这个是"**打包下载**选中的一批 id"（多个）。
/// 名字上刻意用 `MultiSelect` 区分，避免以后有人误接错 provider。
///
/// 按 `path` 分家：不同目录各自独立的选择，避免"在 A 目录选中的
/// 文件跟着跑到 B 目录"（那会导致打包下载里混进别的目录的文件，
/// 或直接 102 对象不存在）。
///
/// 页面在**进入新目录时**调 `clearFor(oldPath)`，见 `drive_browse_view`。
final driveMultiSelectProvider =
    NotifierProvider.family<DriveMultiSelectNotifier, DriveSelection, String>(
      DriveMultiSelectNotifier.new,
    );

class DriveMultiSelectNotifier extends Notifier<DriveSelection> {
  DriveMultiSelectNotifier(this.path);

  /// 本选择器所属的目录（family 参数）。
  final String path;

  @override
  DriveSelection build() => const DriveSelection.empty();

  void toggle(String fileId) => state = state.toggle(fileId);

  /// ★★ 第 314 轮真机缺陷（已修）：条目被**删除**后必须能把 id 摘掉。
  ///
  /// 真机取证：清理 4 个自建文件时，每次「长按 → 行 ⋮ → Delete → 确认」都成功，
  /// 但选择集合只增不减 ⇒ 界面变成「已选 3 项」而**一个勾都看不见**
  /// （3 个 id 指向的文件都已不在列表里），且这个武装态**跨页残留**
  /// （离开到搜索页再回来仍在多选模式，那时顶栏导航按钮也还能点）。
  /// 删除流程因此必须调用本方法（见 `drive_browse_view` 的 `case 'delete'`）。
  void remove(String fileId) => state = state.remove(fileId);

  void toggleAll(Iterable<String> visibleIds) =>
      state = state.toggleAll(visibleIds);

  void clear() => state = const DriveSelection.empty();
}

/// ★ 第 56 轮：**是否处于选择模式**。
///
/// 官方是长按进入选择模式；我们同样不做"常驻复选框"（那会让列表一直脏）。
/// 单独一个 provider 是因为"处于选择模式但一个都没选"是一个**真实状态**
/// （刚长按、还没点），此时工具栏要显示"已选 0 项 + 取消"，
/// 而不是直接消失。
final driveMultiSelectModeProvider =
    NotifierProvider<DriveMultiSelectModeNotifier, bool>(
      DriveMultiSelectModeNotifier.new,
    );

class DriveMultiSelectModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void enter() => state = true;

  /// 退出选择模式。
  ///
  /// ⚠️ 这里**不**清空已选：清空是**按目录**的（`driveSelectionProvider(path)`），
  /// 而本 provider 不知道当前路径。调用方退出时应同时清对应目录的选择
  /// —— 否则下次长按会带着上次的残留。
  void exit() => state = false;
}

final driveViewModeProvider =
    NotifierProvider<DriveViewModeNotifier, DriveViewMode>(
      DriveViewModeNotifier.new,
    );

class DriveViewModeNotifier extends Notifier<DriveViewMode> {
  @override
  DriveViewMode build() => DriveViewMode.list;

  void set(DriveViewMode mode) => state = mode;


  void toggle() => state = state == DriveViewMode.list
      ? DriveViewMode.grid
      : DriveViewMode.list;
}

/// 当前目录的内容
///
/// D19/D18：把排序与"网格视图要的缩略图字段"一路透传到 `Files/list`
/// （`sort_by` / `sort_direction` / `field`）。三个状态任一变化都会让
/// Riverpod 重新拉取，不需要页面手动 invalidate。
final driveListProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((
      ref,
      path,
    ) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      final sort = ref.watch(driveSortProvider);
      final mode = ref.watch(driveViewModeProvider);
      return drive.list(
        path: path,
        sortBy: sort.by,
        sortDirection: sort.descending ? 'desc' : 'asc',
        // ⚠️ 未取证：`field` 参数存在（`api-server-authoritative.md:406`），
        // 但"取缩略图"该给什么值没有真机原文；只在网格视图试发 `thumbnail`
        // （官方 Web reader 的字段名就叫 thumbnail）。服务端不给也不影响：
        // 网格缩略图会回落到既有的 `get_thumbnail` 直链。
        field: mode == DriveViewMode.grid ? 'thumbnail' : null,
      );
    }, retry: _noRetry);

/// Drive 的"更多"视图（P3）：回收站 / 星标 / 共享给我 / 团队文件夹。
///
/// 这四个都是**只读浏览**（清空回收站是唯一的写操作，且要二次确认）。
enum DriveMoreSection {
  trash,
  starred,
  shared,
  team,
  labels,

  // ---- P0-5 / P0-6：**追加在末尾**，前五段的 index 不变（老测试按 0..4 滑页）
  recent,
  sharedByMe;

  /// 中文回落（界面侧读 [labelIn]；老测试与无 context 的地方还用得上）
  ///
  /// 枚举常量本身是 `const`，**不能**在构造器里调 `dataText` ⇒
  /// 这里改成运行时 getter，key 复用已在 `dataTextMap` 里登记的同义 key。
  String get label => switch (this) {
    DriveMoreSection.trash => driveP0('fsP0RecycleBin', '回收站'),
    DriveMoreSection.starred => driveP0(
      'driveP0SearchLocationStarred',
      '星标',
    ),
    DriveMoreSection.shared => driveP0(
      'driveP0SearchLocationSharedWithMe',
      '共享给我',
    ),
    DriveMoreSection.team => driveP0(
      'driveP0SearchLocationTeamFolders',
      '团队文件夹',
    ),
    DriveMoreSection.labels => driveP0('driveP0SearchLabel', '标签'),
    DriveMoreSection.recent => driveP0(DriveP0TextKeys.recentTitle, '最近'),
    DriveMoreSection.sharedByMe => driveP0(
      DriveP0TextKeys.sharedByMeTitle,
      '我共享的',
    ),
  };

  /// 本地化文案（界面用 `labelIn(context.t)`）
  ///
  /// 新增的两段没有 ARB key（本批禁碰 `.arb`），走 [driveP0] 的
  /// key+中文约定；其余沿用既有 `context.t`。
  String labelIn(AppText t) => switch (this) {
    DriveMoreSection.trash => t.noteRecycle,
    DriveMoreSection.starred => t.chatFilterStar,
    DriveMoreSection.shared => t.driveSharedWithMe,
    DriveMoreSection.team => t.driveTeamFolders,
    DriveMoreSection.labels => t.noteTags,
    DriveMoreSection.recent => driveP0(DriveP0TextKeys.recentTitle, '最近'),
    DriveMoreSection.sharedByMe => driveP0(
      DriveP0TextKeys.sharedByMeTitle,
      '我共享的',
    ),
  };
}

final driveMoreSectionProvider =
    NotifierProvider<DriveMoreSectionNotifier, DriveMoreSection>(
      DriveMoreSectionNotifier.new,
    );

class DriveMoreSectionNotifier extends Notifier<DriveMoreSection> {
  @override
  DriveMoreSection build() => DriveMoreSection.trash;

  void select(DriveMoreSection s) => state = s;
}

/// 回收站列表（`Trash/list`，**必须给 path 且只能用 v1**，见 §5.1）
final driveTrashProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((
      ref,
      path,
    ) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.listTrash(path: path);
    }, retry: _noRetry);

/// 回收站占用（`Trash/get_size`）
final driveTrashSizeProvider = FutureProvider.autoDispose.family<int, String>((
  ref,
  path,
) async {
  final drive = ref.watch(driveApiProvider);
  if (drive == null) throw StateError('未连接');
  return drive.trashSize(path: path);
}, retry: _noRetry);

/// 星标（`Files/list_starred`）
final driveStarredProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((ref, _) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.listStarred();
    }, retry: _noRetry);

/// 共享给我（`Files/shared_with_me`）
final driveSharedProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((ref, _) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.sharedWithMe();
    }, retry: _noRetry);

/// 团队文件夹（`TeamFolders/list`）
final driveTeamProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((ref, _) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.teamFolders();
    }, retry: _noRetry);

/// 搜索（官方搜索是独立页面；这里给 Drive 源内的关键词搜索用）
final driveSearchProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((
      ref,
      keyword,
    ) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      if (keyword.trim().isEmpty) {
        return (items: const <DriveEntryDto>[], total: 0);
      }
      return drive.search(keyword.trim());
    }, retry: _noRetry);

// ------------------------------------------- 最近 / 我共享的 / 搜索条件（P0）

/// 最近（`Files/recent`，P0-5）。与星标/共享同族，参数是 `offset/limit`。
final driveRecentProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((ref, _) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.recent();
    }, retry: _noRetry);

/// 我共享的（`Files/shared_with_others`，P0-6）。**与 `Sharing` 那套具名共享
/// 无关**：这里只是"我把哪些节点共享出去了"的列表。
final driveSharedByMeProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((ref, _) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.sharedWithOthers();
    }, retry: _noRetry);

/// 带筛选条件的搜索（P0-4）。条件对象已实现值相等，family 不会反复重拉。
final driveSearchQueryProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), DriveSearchQuery>((
      ref,
      query,
    ) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.searchQuery(query);
    }, retry: _noRetry);

/// 单个节点的最新详情（`Files/get`，P0-10）。详情页拿它补全字段；
/// 失败时页面回落列表行里已有的那份数据。
final driveDetailsProvider = FutureProvider.autoDispose
    .family<DriveEntryDto, String>((ref, fileId) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.get(path: 'id:$fileId');
    }, retry: _noRetry);

// ------------------------------------------------- 版本历史 / 共享 / 标签（P3）

/// 某个 Drive 文件的版本列表（`Revisions/list`）
final driveRevisionsProvider = FutureProvider.autoDispose
    .family<List<DriveRevisionDto>, String>((ref, fileId) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.listRevisions(fileId: fileId);
    }, retry: _noRetry);

/// 某个 Drive 文件共享给了谁（`Sharing/list`；公开链接不在其中）
final driveSharesProvider = FutureProvider.autoDispose
    .family<List<DriveShareDto>, String>((ref, fileId) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.listShares(fileId: fileId);
    }, retry: _noRetry);

/// 个人标签表（`Labels/list`）。写操作后 `ref.invalidate` 一下就刷新。
final driveLabelsProvider = FutureProvider.autoDispose<List<DriveLabelDto>>((
  ref,
) async {
  final drive = ref.watch(driveApiProvider);
  if (drive == null) throw StateError('未连接');
  return drive.listLabels();
}, retry: _noRetry);

/// 某个标签下的文件（`Files/list_labelled`）
final driveLabelledProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((
      ref,
      labelId,
    ) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.listLabelled(labelId: labelId);
    }, retry: _noRetry);

/// 共享成员候选（`Share.Priv/list`）：给"邀请"弹层用，按关键词搜索
final drivePrincipalsProvider = FutureProvider.autoDispose
    .family<List<({String name, String nickname, String type})>, String>((
      ref,
      query,
    ) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.searchPrincipals(query: query);
    }, retry: _noRetry);

/// 用户点开的当前条目（详情面板；`null` = 没选）
final driveSelectionProvider =
    NotifierProvider<DriveSelectionNotifier, DriveEntryDto?>(
      DriveSelectionNotifier.new,
    );

class DriveSelectionNotifier extends Notifier<DriveEntryDto?> {
  @override
  DriveEntryDto? build() => null;

  void select(DriveEntryDto? entry) => state = entry;
}

// ---------------------------------------------------------------- 缩略图

/// Drive 缩略图缓存（复用 NAS 那套 [ThumbCache]：内存 LRU + 磁盘 + 合流 + 负缓存）
final driveThumbCacheProvider = Provider<ThumbCache>((ref) {
  final cache = ThumbCache(
    loader: (key, size) async {
      final drive = ref.read(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      final api = drive.api;
      // key = "<file_id>|<version_id>"
      final parts = key.split('|');
      final bytes = await api.getBytes(
        drive.thumbnailUrl(
          fileId: parts.first,
          size: size,
          versionId: parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null,
        ),
      );
      return Uint8List.fromList(bytes);
    },
    // 与 NAS 缩略图共用 `file_thumbs/` 目录：key 前缀是 `drive|…`，
    // 不会和 FileStation 的 `<size>|<path>` 撞
    directory: () async => ref.read(cacheServiceProvider).fileThumbsDirectory(),
  );
  ref.onDispose(cache.clearMemory);
  return cache;
});

/// Drive 电子书封面缓存（同样复用 [ThumbCache]）
///
/// loader 的第二个槽位（"path"）在这里编码成 `fileId|ext`：既要下载直链
/// （fileId），又要按后缀决定"解析包"还是"渲第一页"。版本号只进缓存 key
/// （Drive 改了文件要换封面），下载直链本身不需要它。
final driveBookCoverCacheProvider = Provider<ThumbCache>((ref) {
  final cache = ThumbCache(
    loader: (key, size) async {
      final drive = ref.read(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      // 传进来的是 `fileId|ext`（版本号只进缓存 key，见上面的注释）
      final parts = key.split('|');
      final fileId = parts.first;
      final ext = parts.length > 1 ? parts[1].toLowerCase() : '';
      final bytes = Uint8List.fromList(
        await drive.api.getBytes(
          drive.downloadUrl(fileId: fileId, isPreview: false),
        ),
      );
      if (ext == 'pdf') {
        final cover = await ref.read(pdfCoverRendererProvider)(bytes);
        if (cover == null) throw StateError('PDF 封面渲染失败');
        return cover;
      }
      final cover = bookCoverBytes(ext, bytes);
      if (cover == null) throw StateError('这本书里没有封面');
      return cover;
    },
    directory: () async => ref.read(cacheServiceProvider).fileThumbsDirectory(),
  );
  ref.onDispose(cache.clearMemory);
  return cache;
});

/// Drive 电子书封面：`fileId + 版本 + 后缀` 做 key
final driveBookCoverProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({String fileId, String versionId, String extension})>((
      ref,
      req,
    ) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) return null;
      final ext = req.extension.toLowerCase();
      final cache = ref.read(driveBookCoverCacheProvider);
      return cache.get(
        'drivebook|${req.fileId}|${req.versionId}|$ext',
        // 第二个参数只给 loader 用：`fileId|后缀`
        '${req.fileId}|$ext',
        size: ext,
      );
    }, retry: _noRetry);

/// Drive 缩略图：[fileId] + 版本号做 key（修改后自动换图）
final driveThumbProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({String fileId, String versionId, ThumbScale scale})>((
      ref,
      req,
    ) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) return null;
      final size = switch (req.scale) {
        ThumbScale.small => 'small',
        ThumbScale.medium => 'medium',
        ThumbScale.large => 'large',
      };
      // `ThumbCache` 的 key 负责去重/失效，第二个参数（"path"）只是给 loader 用的
      return ref
          .read(driveThumbCacheProvider)
          .get(
            'drive|${req.fileId}|${req.versionId}|$size',
            '${req.fileId}|${req.versionId}',
            size: size,
          );
    }, retry: _noRetry);

// ------------------------------------------------- 后台任务（Drive 侧，P3 尾巴）

/// Drive 自己的异步任务列表（`Tasks/list` v1）。
///
/// ⚠️ 和 File Station 的 `BackgroundTask` 是两套（那个在 `file_providers.dart`）：
/// NAS 目录的复制/压缩归文件模块，Drive 的上传/下载/转存归这里。
final driveTasksProvider = FutureProvider.autoDispose<List<DriveTaskDto>>((
  ref,
) async {
  final drive = ref.watch(driveApiProvider);
  if (drive == null) throw StateError('未连接');
  return drive.listTasks();
}, retry: _noRetry);

/// ★ D67（212 轮）：Drive 后台任务的**角标计数**。
///
/// 官方判据逐字（`BackgroundTaskManager.getBadgeDisplayCount()`，
/// `smali_classes4/com/synology/dsdrive/model/manager/BackgroundTaskManager.smali:1387` 起）：
/// 遍历 `getTasks()`，**跳过** `status.isFinished() && exceptions.isEmpty()`，
/// 其余**每个任务 +1** ⇒ 角标 = **进行中任务 + 有异常的（失败）任务**。
/// 官方 `clearUnread()`（`:4341`）把计数清 0 并在任务数变化时重新算；
/// 我们用「已看过的任务 id 集合」实现同一语义：看过就消失，
/// 再来**新任务**（id 不在集合里）就重新出现。
int driveTaskBadgeCount(Iterable<DriveTaskDto> tasks) =>
    tasks.where((t) => !t.finished || t.errors.isNotEmpty).length;

/// 已经"看过"的任务 id（进过 `DriveTasksPage` 就算看过）。
///
/// 只活在本次会话（与官方一致：`unreadCount` 是内存字段，不做持久化）。
final driveTaskSeenProvider =
    NotifierProvider<DriveTaskSeenNotifier, Set<String>>(
      DriveTaskSeenNotifier.new,
    );

class DriveTaskSeenNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// 标记看过的任务；**没有新增就什么都不做**（避免每次 build 都通知一次）。
  void markSeen(Iterable<String> ids) {
    final missing = ids.where((id) => id.isNotEmpty && !state.contains(id));
    if (missing.isEmpty) return;
    state = {...state, ...missing};
  }
}

/// 顶栏"后台任务"按钮上的未读角标（Drive 源才看它）。
///
/// 拿不到任务列表（没连上/103）⇒ 0，**绝不为了显示角标去编数字**。
final driveTaskBadgeProvider = FutureProvider.autoDispose<int>((ref) async {
  final drive = ref.watch(driveApiProvider);
  if (drive == null) return 0;
  final seen = ref.watch(driveTaskSeenProvider);
  final tasks = await drive.listTasks();
  return tasks
      .where((t) => (!t.finished || t.errors.isNotEmpty) && !seen.contains(t.deleteId))
      .length;
}, retry: _noRetry);

/// 单条 Drive 任务的详情（`Tasks/get` v1）。
///
/// **用途**：`DriveTasksPage` 点一行时先拿列表里的数据立刻渲染，再用它去
/// 服务端取一次**最新**状态（列表可能是几秒前的快照；官方 `TaskGetWork`
/// 也是这么按需拉单条的）。
final driveTaskDetailProvider = FutureProvider.autoDispose
    .family<DriveTaskDto, String>((ref, taskId) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      // 既有 `DriveApi.getTask`（`Tasks/get` v1，官方 `getTaskStatus` 同款）
      // 回包不可判读时回 null ⇒ 详情页据此**显示列表快照**，不编状态。
      final task = await drive.getTask(taskId);
      if (task == null) throw StateError('任务详情不可判读');
      return task;
    }, retry: _noRetry);

/// 删掉一条 Drive 任务记录（`Tasks/delete` v1）——官方也只对已完成任务用
final driveTaskDeleteProvider = Provider<Future<void> Function(String)>((ref) {
  return (String taskId) async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) throw StateError('未连接');
    await drive.deleteTask(taskId);
    ref.invalidate(driveTasksProvider);
  };
});

// ------------------------------------------------- C1（Drive 补齐）新增只读取数

/// 某个条目的公开链接（`AdvanceSharing/get` v1）。没开过时服务端回 `1036`，
/// 页面把错误当"还没有链接"处理（官方前端同款）。
final driveAdvanceSharingProvider = FutureProvider.autoDispose
    .family<DriveAdvanceSharingDto, String>((ref, path) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.getAdvanceSharing(path: path);
    }, retry: _noRetry);

/// 我发出的"请求文件"链接（`FileRequest/list` v1）
final driveFileRequestsProvider = FutureProvider.autoDispose
    .family<List<DriveFileRequestDto>, String>((ref, _) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return (await drive.listFileRequests()).items;
    }, retry: _noRetry);

/// Drive 通知列表（`Notifications/list` v1）
final driveNotificationsProvider =
    FutureProvider.autoDispose<List<DriveNotificationDto>>((ref) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.listNotifications();
    }, retry: _noRetry);

/// 一个团队文件夹的成员（`TeamFolders/list_members` v1）
final driveTeamMembersProvider = FutureProvider.autoDispose
    .family<List<DriveTeamMemberDto>, String>((ref, teamId) async {
      final drive = ref.watch(driveApiProvider);
      if (drive == null) throw StateError('未连接');
      return drive.listTeamFolderMembers(teamId: teamId);
    }, retry: _noRetry);

/// Riverpod 3：`retry` 回调返回 null 表示"失败不重试"（抛异常会变成未捕获异常）
Duration? _noRetry(int retryCount, Object error) => null;
