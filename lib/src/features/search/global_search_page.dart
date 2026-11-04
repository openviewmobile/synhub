// 全局搜索（Synology Universal Search，`SYNO.Finder.*`）—— 工作台扩容 P0-3。
//
// ---------------------------------------------------------------- 设计要点
//
// **入口显隐**（父 agent 2026-09-21 决定 + 设计 §4.3(b)）：
//   * 能力位 = `SYNO.Finder.FileIndexing.Search` 在 `SYNO.API.Info` 里的
//     **存在性**（活体探针实测存在、需会话；方法名表在 `data/finder_api.dart`）；
//   * 缺失 → 入口**隐藏**（`absent`）；`105` → 提示 + **隐藏**（`allowUser`
//     未验证时的自我保护）；`119` → **会话提示，绝不隐藏**；
//   * 还没检测过（未连接）→ `unknown`，**fail-open 显示**（与 §15 一致）。
//
// **搜索本体不猜参数**：`SYNO.Finder.FileIndexing.Search` 的请求体在官方
// JS 里**没有**可引用原文（唯一带参数的 Finder 调用是 `AppIndexing.Search`，
// 应用索引，不是文件索引）→ 本页**不发**猜测参数的 Finder 请求，而是复用
// **参数形态已有逐字证据**的各模块搜索 API：
//   * 文件：`SYNO.FileStation.Search start|list`（`filestation_api.dart:632`；
//     权威表 §FileStation）；
//   * 笔记：`SYNO.NoteStation.FTS search`（参数逐字来自官方
//     `/tmp/spk/export_NoteStation/ui/notestation_finder.js` 的
//     `{api:"SYNO.NoteStation.FTS",version:1,method:"search",keyword,offset,limit}`；
//     权限出处 `docs/api-server-authoritative.md:169` 普通用户）。
// 照片来源**不做**：`SYNO.Foto.*` 没有取到检索参数 → 如实不列该分组。
//
// 点击跳转**复用既有打开方式**（不新造查看器）：文件 → `openFilePreview`；
// 笔记 → `NoteViewPage`。
import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/dto/note_dto.dart';
import '../../data/finder_api.dart';
import '../../data/filestation_api.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../../data/note_api.dart';
import '../../dsm/webapi.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../drive/drive_open_entry.dart' show openFileUnified;
import '../files/file_providers.dart';
// ★ r395（DA42）：搜索**根**的规整与「文件」搜索页共用同一份判据 ——
//   原来这里写死 `folder_path: '/'`，正好踩上 r121/r135 已记过的真机 600。
import '../files/file_search_root.dart' show fileSearchRootFor;
import '../notes/note_providers.dart';
import '../notes/note_view_page.dart';
import '../photos/photo_c2_providers.dart';
import '../photos/photo_format_support.dart';
import '../photos/photo_viewer_page.dart';

// ---------------------------------------------------------------- 能力位门控

/// 最近一次全局搜索调用返回的 DSM 错误码（只用来做 `105` / `119` 自我保护）。
final finderCallErrorProvider = NotifierProvider<FinderCallErrorNotifier, int?>(
  FinderCallErrorNotifier.new,
);

class FinderCallErrorNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void report(int? code) {
    if (state != code) state = code;
  }
}

/// 全局搜索入口状态（纯函数 [classifyFinderGate] 的 Riverpod 封装）。
final finderGateProvider = Provider<FinderGateState>((ref) {
  final snapshot = ref.watch(serviceAvailabilityProvider);
  return classifyFinderGate(
    // `apis` 非空 = 真的拿到过 `SYNO.API.Info`（探测过）。
    probed: snapshot.apis.isNotEmpty,
    apiNames: snapshot.apis,
    errorCode: ref.watch(finderCallErrorProvider),
  );
});

/// 吸顶搜索框 / 文件搜索页里的「全局搜索」入口。
///
/// * `absent` / `noPermission`（105）→ 整体不渲染（隐藏）；
/// * `sessionExpired`（119）→ 保留但置灰 + 一句话原因（**不隐藏**）；
/// * 其它 → 可点，进入 [GlobalSearchPage]。
class GlobalSearchEntry extends ConsumerWidget {
  const GlobalSearchEntry({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gate = ref.watch(finderGateProvider);
    if (hidesFinderEntry(gate)) return const SizedBox.shrink();
    final t = context.t;
    final disabled = gate == FinderGateState.sessionExpired;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
      child: Material(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.pane),
        child: DesignRowTile(
          key: const Key('global-search-entry'),
          leading: Icon(
            Icons.travel_explore,
            color: disabled
                ? DesignPalette.of(context).dim
                : Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            disabled ? t.serviceEntrySessionExpired : t.globalSearchEntry,
          ),
          subtitle: Text(
            // ★★ r348 D60：这里原是**硬编码英文**且带内部接口名 `SYNO.Finder`
            //   （真机逐字 `Universal Search · SYNO.Finder`）。i18n 守卫只扫 ARB、
            //   只查 CJK 硬编码 ⇒ 纯 ASCII 的硬编码从两条路上都漏掉。改走 ARB。
            t.globalSearchEngine,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
          ),
          enabled: !disabled,
          onTap: disabled
              ? null
              : () => Navigator.of(context, rootNavigator: true).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        GlobalSearchPage(initialQuery: initialQuery),
                  ),
                ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 页面

class GlobalSearchPage extends ConsumerStatefulWidget {
  const GlobalSearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  ConsumerState<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends ConsumerState<GlobalSearchPage> {
  final _controller = TextEditingController();
  List<FileEntryDto> _files = const [];
  List<NoteDto> _notes = const [];

  /// P25：全局搜索里的**照片分组**（`SYNO.Foto.Search.Search/list_item` v7）。
  ///
  /// 以前这里明确"不列照片分组"，因为当时没取到 `SYNO.Foto.*` 的检索参数；
  /// 现在参数的逐字证据在 `foto_c2_api.dart` 的 `searchItems`（服务端 `.so`
  /// rodata 的 filter 白名单 + 官方前端 `Zo(e,t)` 原文），所以补上。
  List<FotoItemDto> _photos = const [];

  /// 照片分组自己的失败原因（**不**复用 [_error]：照片搜不了不该把文件/笔记的
  /// 结果一起吞掉，也不该触发 `finderCallErrorProvider` 去隐藏全局搜索入口）。
  String? _photoError;
  bool _busy = false;
  bool _done = false;
  String? _error;
  String _keyword = '';

  /// 服务端异步文件搜索的任务 id（离开时停掉）。
  String _taskId = '';
  FileStationApi? _fileApi;

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery.trim();
    if (q.isNotEmpty) {
      _controller.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_search(q));
      });
    }
  }

  @override
  void dispose() {
    final api = _fileApi;
    if (_taskId.isNotEmpty && api != null) {
      api.stopSearch(_taskId).catchError((Object _) {});
      api.cleanSearch(_taskId).catchError((Object _) {});
    }
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String raw) async {
    final keyword = raw.trim();
    if (keyword.isEmpty) return;
    final t = context.t;
    setState(() {
      _keyword = keyword;
      _busy = true;
      _error = null;
      _files = const [];
      _notes = const [];
      _photos = const [];
      _photoError = null;
      _done = false;
    });

    final snapshot = ref.read(serviceAvailabilityProvider);
    final jobs = <Future<void>>[];
    final fileApi = ref.read(fileApiProvider);
    final noteApi = ref.read(noteApiProvider);
    final fotoApi = ref.read(fotoC2ApiProvider);

    final canFiles =
        fileApi != null &&
        !hidesModule(snapshot.stateOf(StationService.file)) &&
        snapshot.hasApi(StationService.file, 'SYNO.FileStation.Search');
    final canNotes =
        noteApi != null && !hidesModule(snapshot.stateOf(StationService.note));
    // P25：照片走 `SYNO.Foto.Search.Search`（普通用户；真机已证 v1–7 注册）。
    // 能力位缺失 → 不列该分组（fail-open：未探测过时仍然尝试，与既有口径一致）。
    final canPhotos =
        fotoApi != null &&
        !hidesModule(snapshot.stateOf(StationService.photo)) &&
        snapshot.hasApi(StationService.photo, 'SYNO.Foto.Search.Search');

    if (canFiles) jobs.add(_searchFiles(fileApi, keyword));
    if (canNotes) jobs.add(_searchNotes(noteApi, keyword));
    if (canPhotos) jobs.add(_searchPhotos(keyword));

    if (jobs.isEmpty) {
      setState(() {
        _busy = false;
        _done = true;
        _error = t.setNotConnected;
      });
      return;
    }
    await Future.wait(jobs);
    if (!mounted) return;
    track(
      ref,
      UsageModule.search,
      UsageAction.search,
      value: _files.length + _notes.length + _photos.length,
      detail: {'scope': 'global', 'tried': 1},
    );
    setState(() {
      _busy = false;
      _done = true;
    });
  }

  Future<void> _searchFiles(FileStationApi api, String keyword) async {
    _fileApi = api;
    try {
      // ★ r395 修（DA42）：原来这里**写死 `folder_path: '/'`** ——
      //   真机对根 `/` 的搜索任务会回 **600**（官方文案
      //   `search/no_search_cache`「暂时无法访问搜索结果。请再试一次。」），
      //   而 r121/r135 早就为同一个 `'/'` 在「文件」搜索页做过回落。
      //   现在两处共用 [fileSearchRootFor]（`/`、空串 → `/home`）。
      //   r395 逐字对照（`docs/evidence-r395/r395_da42_limit_matrix.txt`）：
      //   根 `/`：`has_not_index_share:true`、结果为空；根 `/home`：直接成功 + 命中。
      final start = await api.startSearch(
        folderPath: fileSearchRootFor('/'),
        pattern: keyword,
      );
      _taskId = start.taskId;
      var entries = const <FileEntryDto>[];
      for (var i = 0; i < 8; i++) {
        // ★ r395：用**容忍瞬时 600** 的包装取结果（600 = 服务端"结果缓存还没
        //   准备好"，官方文案就是"请再试一次"）。旧代码一遇异常就 `_onError`，
        //   把一条**瞬时**状态判成了整页失败（真机 `Search failed`）。
        //   其它码（105/119/400/408…）仍原样抛出。
        final result = await api.searchResultsRetrying(
          taskId: _taskId,
          limit: 200,
        );
        entries = result.entries;
        if (entries.isNotEmpty || i >= 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (!mounted) return;
      setState(() => _files = entries);
    } catch (e) {
      _onError(e);
    }
  }

  Future<void> _searchNotes(NoteStationApi api, String keyword) async {
    try {
      final notes = await api.searchNotes(keyword: keyword, limit: 50);
      if (!mounted) return;
      setState(() => _notes = notes);
    } catch (e) {
      _onError(e);
    }
  }

  /// 照片分组：`SYNO.Foto.Search.Search/list_item` **v7**（P25）。
  ///
  /// 只发有逐字参数的 `keyword`（`foto_c2_api.dart` 的 `searchItems` 注释里有
  /// 服务端 `.so` rodata 白名单 + 官方前端 `Zo(e,t)` 原文）。
  ///
  /// ⚠️ 失败**不**走 [_onError]：那会把整个 Finder 入口按"无权限"隐藏，
  /// 也会把文件/笔记的结果一起换成错误页。照片这一组自己给一行原因即可。
  Future<void> _searchPhotos(String keyword) async {
    final c2 = ref.read(fotoC2ApiProvider);
    if (c2 == null) return;
    try {
      final items = await c2.searchItems({'keyword': keyword}, limit: 30);
      if (!mounted) return;
      setState(() => _photos = items);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _photoError = photoG1Fill(
          PhotoG1TextKeys.globalSearchFailed,
          '照片搜索失败：{reason}',
          {'reason': describeFileError(e)},
        );
      });
    }
  }

  /// 统一错误处理：`105` / `119` 记进 [finderCallErrorProvider]，让入口
  /// 自禁用（105）或保留但提示会话失效（119）。
  void _onError(Object error) {
    if (error is DsmApiException) {
      ref.read(finderCallErrorProvider.notifier).report(error.code);
      if (error.code == kNoPermissionCode ||
          error.code == kNoAppPrivilegeCode) {
        if (mounted) setState(() => _error = context.t.errNoAppPrivilege);
        return;
      }
      if (error.code == kSidNotFoundCode || error.code == kSessionTimeoutCode) {
        if (mounted) {
          setState(() => _error = context.t.serviceEntrySessionExpired);
        }
        return;
      }
    }
    if (mounted) setState(() => _error = describeFileError(error));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    return Scaffold(
      key: const Key('global-search-page'),
      backgroundColor: hud.bg,
      appBar: AppBar(title: Text(t.globalSearchTitle)),
      body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: TextField(
                key: const Key('global-search-field'),
                controller: _controller,
                textInputAction: TextInputAction.search,
                onSubmitted: _search,
                decoration: InputDecoration(
                  hintText: t.wsSearchHint,
                  prefixIcon: const Icon(Icons.travel_explore),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: () => _search(_controller.text),
                  ),
                ),
              ),
            ),
            Expanded(child: _body(t)),
          ],
        ),
    );
  }

  Widget _body(AppText t) {
    if (_busy) return const AppListSkeleton();
    if (_error != null) {
      return AppErrorView(
        title: t.fileSearchFailed,
        detail: _error,
        onRetry: () => _search(_keyword),
      );
    }
    if (_files.isEmpty &&
        _notes.isEmpty &&
        _photos.isEmpty &&
        _photoError == null) {
      return AppEmptyState(
        icon: Icons.travel_explore,
        title: _done ? t.fileNoMatches : t.searchPrompt,
        message: _done ? _keyword : null,
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        children: [
          if (_files.isNotEmpty) ...[
            _groupTitle(t.navFiles, Key('global-search-group-files')),
            for (final e in _files)
              DesignRowTile(
                key: Key('global-search-file-${e.path}'),
                leading: Icon(e.isDir ? Icons.folder : Icons.insert_drive_file),
                title: Text(e.name),
                subtitle: Text(
                  e.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // ★ 用户 2026-09-25 裁决：Office 原生三种格式走「我的 Drive」同一个阅读器
                onTap: () => openFileUnified(context, ref, e),
              ),
          ],
          if (_notes.isNotEmpty) ...[
            _groupTitle(t.wsNotes, Key('global-search-group-notes')),
            for (final n in _notes)
              DesignRowTile(
                key: Key('global-search-note-${n.objectId}'),
                leading: const Icon(Icons.sticky_note_2_outlined),
                title: Text(n.title.isEmpty ? t.dtoNoteUntitled : n.title),
                subtitle: n.brief.isEmpty
                    ? null
                    : Text(
                        n.brief,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () =>
                    Navigator.of(context, rootNavigator: true).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => NoteViewPage(note: n),
                      ),
                    ),
              ),
          ],
          // P25：照片分组（`SYNO.Foto.Search.Search/list_item` v7）
          if (_photos.isNotEmpty) ...[
            _groupTitle(t.navPhotos, Key('global-search-group-photos')),
            for (final p in _photos)
              DesignRowTile(
                key: Key('global-search-photo-${p.id}'),
                leading: Icon(
                  p.isVideo ? Icons.videocam_outlined : Icons.photo_outlined,
                ),
                title: Text(p.filename),
                subtitle: Text(
                  '${p.takenAt.year}-'
                  '${p.takenAt.month.toString().padLeft(2, '0')}-'
                  '${p.takenAt.day.toString().padLeft(2, '0')}',
                ),
                onTap: () =>
                    Navigator.of(context, rootNavigator: true).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => PhotoViewerPage(
                          items: _photos,
                          index: _photos.indexOf(p),
                        ),
                      ),
                    ),
              ),
          ] else if (_photoError != null) ...[
            _groupTitle(t.navPhotos, Key('global-search-group-photos')),
            Padding(
              key: const Key('global-search-photos-error'),
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.md,
                vertical: Gap.xs,
              ),
              child: Text(
                _photoError!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _groupTitle(String text, Key key) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(color: DesignPalette.of(context).dim),
    ),
  );
}
