// 相册 **G6 批次**的 provider 层：
//   * 用户后台任务 `SYNO.Foto.BackgroundTask.Info:list_user_task`（v1）；
//   * 迁移状态 `SYNO.Foto.Migration:get_status`（v1）。
//
// 与既有相册 provider 同一套约定（见 `photo_c2_providers.dart`）：
//   * API 从会话里取（未连接 → null），数据一律 `autoDispose` + **关掉自动重试**
//     （`noRetry`：Riverpod 3 的指数退避会让 UI 一直停在骨架屏）；
//   * 能力位缺失 → **只隐藏对应入口**（`partial`），**绝不隐藏 Photos 模块**；
//   * 未检测 / 未连接 → fail-open（`ServiceAvailabilitySnapshot.hasApi`）。
//
// ⚠️ 这两个 API 是**全局的**（没有 `SYNO.FotoTeam.` 对应体），所以 provider 直接
// 拿 `FotoApi.api`（[DsmWebApi]）交给 [FotoG6Api]，**不套空间前缀**。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/provider_retry.dart';
import '../../data/dto/foto_g6_dto.dart';
import '../../data/foto_g6_api.dart';
import 'photo_providers.dart' show fotoApiProvider;

/// `SYNO.Foto.BackgroundTask.Info`（真机 `SYNO.API.Info`：
/// `v1..1 path=entry.cgi`；`docs/g6-api-probe-facts.md:13`）。
///
/// 缺失 → **只隐藏"后台任务"入口**。
///
/// ⚠️ 常量**就地声明**（不进 `service_registry.dart`）：与
/// `photo_c2_providers.dart` 的 `kFotoRecentlyAddedApi` 等**同一处置**——
/// 注册表本批次不动，门控靠 `hasApi` 在 available/partial 下直接查 `apis` 集合，
/// 语义完全一致（缺失 → 隐藏且不发探测）。
const String kFotoBackgroundTaskInfoApi = 'SYNO.Foto.BackgroundTask.Info';

/// `SYNO.Foto.Migration`（真机 `SYNO.API.Info`：`v1..1 path=entry.cgi`；
/// `docs/g6-api-probe-facts.md:14`）。缺失 → **只隐藏"迁移状态"入口**。
const String kFotoMigrationApi = 'SYNO.Foto.Migration';

/// 全局相册 API 客户端（未连接 → null）。
final fotoG6ApiProvider = Provider<FotoG6Api?>((ref) {
  final foto = ref.watch(fotoApiProvider);
  return foto == null ? null : FotoG6Api(foto.api);
});

FotoG6Api _require(Ref ref) {
  final api = ref.read(fotoG6ApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api;
}

/// 当前用户的后台任务（`BackgroundTask.Info:list_user_task`）。
///
/// 真机回 `{"list": []}` ⇒ **空态是本功能在真机上的唯一表现**，
/// 页面必须画人话空态（见 `photo_background_tasks_page.dart`）。
final photoBackgroundTasksProvider =
    FutureProvider.autoDispose<List<FotoBackgroundTaskDto>>((ref) async {
      return _require(ref).listUserTasks();
    }, retry: noRetry);

/// 迁移状态（`Migration:get_status`）。
///
/// 真机回 `{"current": 2, "status": "done", "title_key": "", "total": 0}`
/// ⇒ `total == 0`（或 `status == done`）就是真机上的表现，页面必须画
/// 人话空态/"已完成"，**绝不白屏**。
final photoMigrationStatusProvider =
    FutureProvider.autoDispose<FotoMigrationStatusDto>((ref) async {
      return _require(ref).migrationStatus();
    }, retry: noRetry);
