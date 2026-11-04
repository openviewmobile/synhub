// Drive「收藏集 / 收藏夹」（D8，官方 `DriveCategory.Collection`）的 provider 层。
//
// 协议事实见 `data/dto/drive_collection_dto.dart` 与 `data/drive_api.dart`：
// 收藏集整个建在 `SYNO.SynologyDrive.Labels` 上（`type` 区分为
// `photo_album` / `document_folder` / `audio_playlist` / `video_playlist`）；
// 成员关系走 `Files/label`（`action: add|delete`）。
//
// 与既有 Drive provider 同一套约定（`drive_g6_providers.dart`）：
// API 从会话里取（未连接 → null），数据一律 `autoDispose` + **关掉自动重试**
// （Riverpod 3 默认对失败的 provider 指数退避重试 → UI 会一直停在 loading）。
//
// 能力门控常量**就地声明**（不进 `service_registry.dart`，理由同
// `drive_g6_providers.dart` 的 `kDriveConnectionApi`）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../data/dto/drive_collection_dto.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../files/drive_providers.dart' show driveApiProvider;

/// `SYNO.SynologyDrive.Labels`（真机 `SYNO.API.Info`：`minVersion 1,
/// maxVersion 3, path=entry.cgi`；普通的个人标签页已在用同一个 API）。
///
/// ⚠️ 收藏集**从 v2 起才有**（官方 `VERSION_SUPPORT_COLLECTION = 2`），
/// 但 `serviceAvailability` 只记 API 是否存在、不记版本；老包（只到 v1）下
/// 入口仍显示，`Labels/list?type=photo_album` 会由服务端自行处理。
/// 这是**有意为之的 fail-open**：用"服务端行为"决定，而不是我们本地猜版本。
const String kDriveLabelsApi = 'SYNO.SynologyDrive.Labels';

/// 收藏集列表。`type == null` 时不带 `type`（只作兜底；正常都按类型筛）。
///
/// 真机这台 NAS 上四个类型都回 `{"items": [], "total": 0}` ⇒ **空态是它在
/// 真机上的唯一表现**，页面必须画人话空态（见 `drive_collection_page.dart`）。
final driveCollectionsProvider = FutureProvider.autoDispose
    .family<List<DriveCollectionDto>, DriveCollectionType?>((ref, type) async {
      final api = ref.watch(driveApiProvider);
      if (api == null) {
        throw StateError('not connected');
      }
      return api.listCollections(type: type);
    }, retry: noRetry);

/// 某个收藏集里的文件（`Files/list_labelled` v2）。
///
/// 收藏集与标签共用存储，所以和标签页走的是同一个只读接口。
final driveCollectionFilesProvider = FutureProvider.autoDispose
    .family<({List<DriveEntryDto> items, int total}), String>((
      ref,
      collectionId,
    ) async {
      final api = ref.watch(driveApiProvider);
      if (api == null) {
        throw StateError('not connected');
      }
      return api.listCollectionFiles(collectionId: collectionId);
    }, retry: noRetry);
