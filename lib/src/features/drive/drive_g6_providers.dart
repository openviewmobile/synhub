// Drive **G6 批次**的 provider 层：已连接的客户端 / 设备
// （`SYNO.SynologyDrive.Connection:list`，**v2 优先，回退 v1**）。
//
// 与既有 Drive provider 同一套约定（见 `drive_g4_providers.dart`）：
// API 从会话里取（未连接 → null），数据一律 `autoDispose` + **关掉自动重试**
// （Riverpod 3 默认对失败的 provider 指数退避重试 → UI 会一直停在 loading）。
//
// 能力门控：入口按 `SYNO.SynologyDrive.Connection` 能力位隐藏
// （`drive_extras_page.dart` 的 `has(kDriveConnectionApi)`）。
// ⚠️ 该常量**就地声明**（不进 `service_registry.dart`）：与
// `photo_c2_providers.dart` 的 `kFotoGeneralTagApi` 等**同一处置**，
// 避免动注册表把 photo/drive 的模块级状态从 `available` 打成 `partial`
// （`hasApi` 在 available/partial 下都直接查 `apis` 集合，门控语义不变）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../data/dto/drive_connection_dto.dart';
import '../files/drive_providers.dart' show driveApiProvider;

/// `SYNO.SynologyDrive.Connection`（真机 `SYNO.API.Info` 里存在，
/// `v1..2 path=entry.cgi`；见 `docs/g6-api-probe-facts.md:12`）。
///
/// 缺失 → **只隐藏"已连接设备"这一个入口**，Drive 模块照常（`partial`）。
const String kDriveConnectionApi = 'SYNO.SynologyDrive.Connection';

/// 已连接的客户端 / 设备列表。
///
/// 真机这台 NAS 上回的是 `{"items": [], "total": 0}` ⇒ **空态就是它在真机上的
/// 唯一表现**，页面必须画人话空态（见 `drive_connections_page.dart`）。
final driveConnectionsProvider =
    FutureProvider.autoDispose<DriveConnectionListDto>((ref) async {
      final api = ref.watch(driveApiProvider);
      if (api == null) {
        throw StateError('not connected');
      }
      return api.listConnections();
    }, retry: noRetry);
