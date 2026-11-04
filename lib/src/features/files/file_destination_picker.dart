// M18：复制 / 移动的**目标目录选择器**。
//
// 官方 DS file 是 `fragments/DestinationSelectFragment.java` —— 一个完整的
// 浏览页，用户逐级进入目录，产出 `copy_here` / `move_here`（`:150`）。我们
// 之前是 `promptFileName(initial: _parentOf(dir))` **手打绝对路径**
// （见 `docs/filestation-parity-audit.md` M18），跨共享搬文件要用户自己敲
// `/volume1/...`，极易出错。
//
// 本页把"选目标"做回浏览式：
//   * **当前路径**（`Key('file-dest-current')`）实时显示；
//   * **上级** 按钮（`Key('file-dest-up')`）—— 已在根目录时禁用；
//   * 点目录行**进入**该目录；
//   * **选中** 按钮（`Key('file-dest-choose')`）返回当前目录路径。
//
// 复用 `List/list`（非根）/ `List/list_share`（根）—— 与浏览页同一套 API，
// **不新增服务端方法**。返回值是用户选中的目录路径；`null` = 取消。
//
// 只列**目录**（官方目标选择器里文件不可选）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import 'file_providers.dart';
import 'filestation_gaps_wave2_text.dart';
import '../../core/theme/app_theme.dart';

/// 「选一个目标目录」的浏览式页面。
///
/// [initialPath] —— 打开时停在哪（调用方给源目录的父级，与旧默认一致）。
/// [title] —— 顶栏标题（复制到… / 移动到…）。
/// [actionLabel] —— 选中按钮的文案（复制 / 移动）。
class FileDestinationPickerPage extends ConsumerStatefulWidget {
  const FileDestinationPickerPage({
    super.key,
    required this.initialPath,
    required this.title,
    required this.actionLabel,
  });

  final String initialPath;
  final String title;
  final String actionLabel;

  @override
  ConsumerState<FileDestinationPickerPage> createState() =>
      _FileDestinationPickerPageState();
}

class _FileDestinationPickerPageState
    extends ConsumerState<FileDestinationPickerPage> {
  late String _path = widget.initialPath.isEmpty
      ? kFileRoot
      : widget.initialPath;
  late Future<List<FileEntryDto>> _future = _load();

  bool get _canGoUp => _path != kFileRoot;

  Future<List<FileEntryDto>> _load() async {
    final api = ref.read(fileApiProvider);
    if (api == null) return const <FileEntryDto>[];
    final result = _path == kFileRoot
        ? await api.listShares(
            limit: 1000,
            sortBy: FileSortBy.name,
            sortDirection: FileSortDirection.asc,
          )
        : await api.listFolder(
            folderPath: _path,
            limit: 1000,
            sortBy: FileSortBy.name,
            sortDirection: FileSortDirection.asc,
          );
    // 目标选择器里**只有目录**可选（官方 `DestinationSelectFragment` 同）。
    return result.entries.where((e) => e.isDir).toList();
  }

  void _reload() => setState(() => _future = _load());

  void _enter(String path) {
    setState(() {
      _path = path;
      _future = _load();
    });
  }

  void _goUp() {
    if (!_canGoUp) return;
    _enter(_parentPath(_path));
  }

  /// `/home/a/b` → `/home/a`；`/home` 与 `/` 都回到根。
  static String _parentPath(String path) {
    if (path == kFileRoot || path.isEmpty) return kFileRoot;
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return kFileRoot;
    return path.substring(0, idx);
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            key: const Key('file-dest-choose-icon'),
            tooltip: widget.actionLabel,
            icon: const Icon(Icons.check),
            onPressed: () => Navigator.of(context).pop(_path),
          ),
        ],
      ),
      body: Column(
          children: [
            // 当前路径 + 上级
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.lg, Gap.xs),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('file-dest-up'),
                    tooltip: fsGap2(FsGap2TextKeys.up, '上一级'),
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _canGoUp ? _goUp : null,
                  ),
                  Expanded(
                    child: Text(
                      _path == kFileRoot
                          ? fsGap2(FsGap2TextKeys.root, '根目录')
                          : _path,
                      key: const Key('file-dest-current'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<FileEntryDto>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            fsGap2(
                              FsGap2TextKeys.loadFailed,
                              '目录加载失败',
                            ),
                          ),
                          const SizedBox(height: Gap.sm),
                          Text(
                            describeFileError(snap.error!),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: Gap.sm),
                          FilledButton(
                            key: const Key('file-dest-retry'),
                            onPressed: _reload,
                            child: Text(t.photoRetry),
                          ),
                        ],
                      ),
                    );
                  }
                  final dirs = snap.data ?? const <FileEntryDto>[];
                  if (dirs.isEmpty) {
                    return Center(
                      child: Text(
                        fsGap2(
                          FsGap2TextKeys.noSubfolder,
                          '此文件夹下没有子文件夹',
                        ),
                      ),
                    );
                  }
                  return Material(
                    type: MaterialType.transparency,
                    child: ListView.builder(
                      itemCount: dirs.length,
                      itemBuilder: (context, i) {
                        final dir = dirs[i];
                        return DesignRowTile(
                          key: Key('file-dest-entry-${dir.path}'),
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(dir.name),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _enter(dir.path),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _path == kFileRoot
                            ? fsGap2(FsGap2TextKeys.root, '根目录')
                            : _path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    FilledButton(
                      style: InlineButtonStyle.filled,
                      key: const Key('file-dest-choose'),
                      onPressed: () => Navigator.of(context).pop(_path),
                      child: Text(widget.actionLabel),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
    );
  }
}
