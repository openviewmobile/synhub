// Drive「团队文件夹回收站」（D12，官方 `DriveCategory.TeamFolderInRecycleBin`）
// 的 provider 层。
//
// 协议事实见 `data/drive_api.dart` 的 `listFolderTrash`：
// 官方团队文件夹回收站走 `Trash/list`（读），`path` 是
// `UtilsForApi.computePathById(folderId)` = `id:<folder_id>`。
// 真机只读实测（本批）：`Trash/list v2 {"path":"id:<folder_id>"}` → success。
//
// 与既有 Drive provider 同一套约定（`drive_g6_providers.dart`）：
// API 从会话里取（未连接 → null），数据一律 `autoDispose` + **关掉自动重试**。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../files/drive_providers.dart' show driveApiProvider;

/// 某个文件夹（团队文件夹根）的回收站列表。
///
/// 只读。**不要**把它接到"清空"：官方 `DataSource.generateInstanceForEmptyRecycleBin`
/// 在 `rootDataSource.isForTeamFolders()` 时**直接 `return null`**
/// （`DataSource.java:575-583`）⇒ **官方对团队文件夹根本没有"清空回收站"入口**，
/// 我们也不做（做了就是超出官方语义的破坏性操作）。
final driveFolderTrashProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((
      ref,
      folderId,
    ) async {
      final api = ref.watch(driveApiProvider);
      if (api == null) {
        throw StateError('not connected');
      }
      return api.listFolderTrash(folderId: folderId);
    }, retry: noRetry);
