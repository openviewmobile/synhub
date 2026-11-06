// Drive「本地文件」页（D22）：浏览**本机**目录，并把文件上传到 Drive 目标目录。
//
// 官方对照：
//   * `DriveCategory.LocalFile`（`DriveCategory.java:41`）是抽屉里的一档；
//   * 真正的"本地 → Drive"拷贝动作是 `LocalFileCopyWork`（它只做**本地文件
//     拷贝**：把 `content://` 缓存文件拷到目标文件，`LocalFileCopyWork.java`
//     全文没有任何 `SYNO.*` 调用）⇒ **纯客户端**能力，服务端 API 不适用。
//
// 上传落点：走**仓库既有的、真机双向验过的** FileStation 上传通道
// （`SYNO.FileStation.Upload`，`fileApiProvider`），目标目录由 Drive 路径映射成
// 磁盘路径（`driveDsmFolderOf`：`/mydrive/x` ↔ `/home/Drive/x`）。为什么不走
// `Files/upload`：它是"defer upload"两段式协议，参数形态没在真机上钉死，
// 本批**不猜**（同 `drive_browse_view.dart:1265` 的既有结论）。
//
// 测试纪律：本机根目录来自**可注入**的 [driveLocalRootsProvider]，
// 离线用例换成临时目录；不碰 `path_provider` 的平台通道。
import '../../design/kit/design_kit.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/platform/app_paths.dart';
import '../../core/provider_retry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart' show driveHumanSize;
import '../../data/local/file_store.dart' show describeFileError;
import '../files/drive_browse_view.dart' show driveDsmFolderOf;
import '../files/file_providers.dart' show fileApiProvider;
import '../files/file_row.dart' show formatFileTime;
import 'drive_g4_text.dart';

/// 本机可浏览的根目录（可注入 → 离线可测）。
final driveLocalRootsProvider = FutureProvider.autoDispose<List<Directory>>((
  ref,
) async {
  final roots = <Directory>[];
  void add(Directory? d) {
    if (d == null) return;
    if (roots.any((e) => e.path == d.path)) return;
    if (d.existsSync()) roots.add(d);
  }

  try {
    add(await _externalStorage());
  } catch (_) {
    // 桌面 / 无外置存储 → 跳过
  }
  return roots;
}, retry: noRetry);

/// 单独的间接层：把 `path_provider` 的平台调用包起来，**默认实现**在纯 Dart
/// 环境会抛异常，被上面的 `try` 吃掉（→ 空列表 → 页面显示"不可用"）。
Future<Directory?> _externalStorage() async {
  // 第 279 轮：路径口径统一走 `AppPaths.localFileRoots()` ——
  // Android 给 `/storage/emulated/0`；macOS/Linux/Windows 给**沙箱容器内**
  // 可写的目录（不再返回 null 让整页空着），web/unknown 才给空。
  final roots = await AppPaths.localFileRoots();
  for (final r in roots) {
    if (r.exists) return Directory(r.path);
  }
  return null;
}

/// 列目录的实现（可注入）。默认走 dart:io；测试里换成"先失败、重试后成功"
/// 的假实现，用来钉住"失败态有重试入口、且重试真的重新读取"。
///
/// 为什么必须可注入：真机上"读不了"的目录（权限拒绝、坏软链、
/// `listSync` 抛 `FileSystemException`）在单元测试里很难稳定造出来，
/// 而"失败被渲染成空目录"正是本页最要命的缺陷（用户以为文件没了）。
typedef DriveLocalLister = List<FileSystemEntity> Function(Directory dir);

final driveLocalListerProvider = Provider<DriveLocalLister>(
  (ref) => _listDirectory,
);

/// 只列一层并排序；**不吞异常** —— 读不了要让调用方知道，
/// 否则失败会被渲染成"空目录"。
List<FileSystemEntity> _listDirectory(Directory dir) {
  final all = dir.listSync(followLinks: false);
  all.sort((a, b) {
    final ad = a is Directory, bd = b is Directory;
    if (ad != bd) return ad ? -1 : 1;
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });
  return all;
}

class DriveLocalFilesPage extends ConsumerStatefulWidget {
  const DriveLocalFilesPage({super.key, required this.targetDrivePath});

  /// 上传目标（Drive 侧路径，如 `/mydrive/PhotoBackup`）
  final String targetDrivePath;

  @override
  ConsumerState<DriveLocalFilesPage> createState() =>
      _DriveLocalFilesPageState();
}

class _DriveLocalFilesPageState extends ConsumerState<DriveLocalFilesPage> {
  /// 当前目录栈（空 = 根列表）
  final List<Directory> _stack = [];
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final current = _stack.isEmpty ? null : _stack.last;
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-local-files-page'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('drive-local-up'),
                      tooltip: t.calBack,
                      icon: Icon(
                        _stack.isEmpty ? Icons.arrow_back : Icons.arrow_upward,
                      ),
                      onPressed: () {
                        if (_stack.isEmpty) {
                          Navigator.of(context).maybePop();
                        } else {
                          setState(_stack.removeLast);
                        }
                      },
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            driveG4(DriveG4TextKeys.localFilesTitle, '本地文件'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            driveG4Fill(
                              DriveG4TextKeys.localFilesTarget,
                              '上传到 {path}',
                              {'path': widget.targetDrivePath},
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.labelSmall?.copyWith(color: hud.dim),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: current == null
                    ? _roots(context)
                    : _directory(context, current),
              ),
            ],
          ),
        ),
    );
  }

  Widget _roots(BuildContext context) {
    final async = ref.watch(driveLocalRootsProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => AppErrorView(
        key: const Key('drive-local-roots-error'),
        icon: Icons.folder_off_outlined,
        title: driveG4(DriveG4TextKeys.localFilesUnavailable, '本机目录不可用'),
        detail: describeFileError(e),
        onRetry: () => ref.invalidate(driveLocalRootsProvider),
      ),
      data: (roots) {
        if (roots.isEmpty) {
          return AppEmptyState(
            key: const Key('drive-local-unavailable'),
            icon: Icons.folder_off_outlined,
            title: driveG4(DriveG4TextKeys.localFilesUnavailable, '本机目录不可用'),
            message: driveG4(
              DriveG4TextKeys.localFilesUnavailableBody,
              '当前平台没有可浏览的外置存储（桌面 / 无权限时如此）。',
            ),
          );
        }
        // ListTile 的底色/水波纹画在**最近的 Material** 上，而本页的
        // `FieldBackdrop` 中间夹了 ColoredBox → debug 下会直接断言
        // （"ListTile background color or ink splashes may be invisible"）。
        // 仓库既有写法：补一层透明 Material 把链路接回去。
        return Material(
          type: MaterialType.transparency,
          child: ListView(
            key: const Key('drive-local-roots'),
            children: [
              for (var i = 0; i < roots.length; i++)
                DesignRowTile(
                  key: Key('drive-local-root-$i'),
                  leading: const Icon(Icons.sd_storage_outlined),
                  title: Text(roots[i].path),
                  onTap: () => setState(() => _stack.add(roots[i])),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _directory(BuildContext context, Directory dir) {
    // ★ 失败必须与"空目录"分开：读不了（权限/坏软链/IO）时原来 `_list`
    //   把异常吞掉返回 `[]` ⇒ 界面显示"这个目录是空的"，用户以为文件没了，
    //   而且没有任何重试入口。现在如实报错 + 可点重试（重试会真的再读一次）。
    final List<FileSystemEntity> entries;
    try {
      entries = ref.read(driveLocalListerProvider)(dir);
    } catch (e) {
      return AppErrorView(
        key: const Key('drive-local-list-error'),
        icon: Icons.folder_off_outlined,
        title: driveG4(DriveG4TextKeys.localFilesListFailed, '目录读取失败'),
        detail: describeFileError(e),
        onRetry: () => setState(() {}),
      );
    }
    if (entries.isEmpty) {
      return AppEmptyState(
        key: const Key('drive-local-empty'),
        icon: Icons.folder_open,
        title: driveG4(DriveG4TextKeys.localFilesEmpty, '这个目录是空的'),
        message: driveG4(
          DriveG4TextKeys.localFilesEmptyBody,
          '换一个目录，或把文件放进本机存储后再来。',
        ),
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: ListView.separated(
        key: const Key('drive-local-list'),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final entity = entries[i];
          final isDir = entity is Directory;
          final name = entity.path.split('/').where((e) => e.isNotEmpty).last;
          final stat = isDir ? null : entity.statSync();
          return DesignRowTile(
            key: Key('drive-local-entry-$name'),
            leading: Icon(
              isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
            ),
            title: Text(name),
            subtitle: Text(
              isDir
                  ? driveG4(DriveG4TextKeys.computersDevice, '文件夹')
                  : '${driveHumanSize(stat!.size)} · '
                        '${formatFileTime(stat.modified.millisecondsSinceEpoch ~/ 1000, t: context.t)}',
            ),
            trailing: isDir
                ? null
                : TextButton(
                    key: Key('drive-local-upload-$name'),
                    onPressed: _busy ? null : () => _upload(entity),
                    child: Text(
                      driveG4(DriveG4TextKeys.localFilesUpload, '上传'),
                    ),
                  ),
            onTap: isDir ? () => setState(() => _stack.add(entity)) : null,
          );
        },
      ),
    );
  }

  Future<void> _upload(FileSystemEntity entity) async {
    final fs = ref.read(fileApiProvider);
    final messenger = ScaffoldMessenger.of(context);
    final name = entity.path.split('/').where((e) => e.isNotEmpty).last;
    final dsmFolder = driveDsmFolderOf(widget.targetDrivePath);
    if (fs == null || dsmFolder == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveG4(
              DriveG4TextKeys.localFilesNotConnected,
              '未连接，或该 Drive 位置不支持上传',
            ),
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await fs.upload(
        folderPath: dsmFolder,
        filePath: entity.path,
        fileName: name,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveG4Fill(DriveG4TextKeys.localFilesUploaded, '已上传 {name}', {
              'name': name,
            }),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveG4Fill(
              DriveG4TextKeys.localFilesUploadFailed,
              '上传失败：{error}',
              {'error': describeFileError(e)},
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
