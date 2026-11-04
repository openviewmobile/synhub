// Drive wave2（普通用户级功能）的 provider 与运行时编排。
//
// 三项：配额/用量（`Info:quota` v2）、访问事件上报（`Files:access` v1）、
// 转 Office 格式（`Files:convert_office` v1）。
//
// 本文件刻意放在 `features/drive/`（而不是 `features/files/drive_providers.dart`）：
// 后者属于并行批次，本批**禁改**；这里只**只读引用**它的 `driveApiProvider`。
//
// 能力门控一律走仓库既有的统一机制 [ServiceAvailabilitySnapshot.hasApi]
// （fail-open：未检测 / 网络失败 / 会话问题都不隐藏；只有能力表明确缺失才隐藏）。
// `service_registry.dart` 也属禁改，所以这两个 API 名在本文件里就地声明。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../data/drive_api.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/drive_quota_dto.dart';
import '../../data/dto/drive_task_dto.dart';
import '../files/drive_providers.dart' show driveApiProvider;

/// `SYNO.SynologyDrive.Files`（驱动 `access` / `convert_office`；
/// 它是 Drive 的**必需** API，Drive 可用即存在）。
const String kDriveFilesApiName = 'SYNO.SynologyDrive.Files';

/// `SYNO.SynologyDrive.Info`（驱动 `quota`；**只有 v2 才有该方法**）。
const String kDriveInfoApiName = 'SYNO.SynologyDrive.Info';

/// `convert_office` 的目标格式默认值。
///
/// **只放真机取证过的那一个值**（`"docx"`）；`xlsx` / `pptx` 等其它取值
/// **未取证**，故不提供选择、也不猜测（见交付报告的"未取证"清单）。
const String kDriveConvertDefaultFormat = 'docx';

/// 配额/用量是否可用。
///
/// 统一门控语义（与 `service_registry.hidesModule` 一致）：
///   * `absent` / `unauthorized`（= 明确缺失，含 **105/160**）→ **隐藏**；
///   * 能力表明确缺 `SYNO.SynologyDrive.Info` → **隐藏**；
///   * `119`/`106`（`sessionExpired`）**不隐藏**（入口保留，调用失败时提示重登）；
///   * `unknown` / `uncertain` / `unreachable` → fail-open（不隐藏）。
bool driveQuotaAvailable(WidgetRef ref) {
  final snap = ref.watch(serviceAvailabilityProvider);
  if (hidesModule(snap.stateOf(StationService.drive))) return false;
  return snap.hasApi(StationService.drive, kDriveInfoApiName);
}

/// `Files:access` / `Files:convert_office` 是否可用（门控语义同 [driveQuotaAvailable]）。
bool driveFilesCapabilityAvailable(WidgetRef ref) {
  final snap = ref.watch(serviceAvailabilityProvider);
  if (hidesModule(snap.stateOf(StationService.drive))) return false;
  return snap.hasApi(StationService.drive, kDriveFilesApiName);
}

/// 配额/用量（`Info:quota` v2）。
final driveQuotaProvider = FutureProvider.autoDispose<DriveQuotaDto>((
  ref,
) async {
  final api = ref.watch(driveApiProvider);
  if (api == null) {
    throw StateError('not connected');
  }
  return api.quota();
}, retry: noRetry);

// ---------------------------------------------------------- 访问事件上报

/// 上报一次"预览"访问事件（官方 `event_type` 唯一核到的值）。
///
/// 官方语义：查看器切换条目时上报（`drive/synodrive.js` 的
/// `accessFile({params:{path:"id:"+file_id,event_type:"preview"}})`）。
///
/// 纪律：
///   * **绝不阻塞打开**（调用方 fire-and-forget，失败静默）；
///   * **能力门控**：`Files` 能力位缺失 → 不上报；
///   * 未连接 / 拿不到 path → 不上报；
///   * 不把任何 id 放进 UI（`path` 只进请求体）。
Future<void> reportDriveAccess(
  WidgetRef ref,
  DriveEntryDto entry, {
  String eventType = DriveApi.kAccessEventPreview,
}) async {
  if (!driveFilesCapabilityAvailable(ref)) return;
  if (entry.fileId.isEmpty) return;
  final api = ref.read(driveApiProvider);
  if (api == null) return;
  try {
    await api.reportAccess(eventType: eventType, path: entry.pathId);
  } catch (_) {
    // 访问上报是"尽力而为"的遥测，失败不影响用户操作，也不显示错误。
  }
}

// ------------------------------------------------------- 转成 Office 格式

/// 一次转换尝试的结果。
///
/// **`pending` 不等于成功**：只表示"已提交/仍在后台"，界面文案必须区别对待。
enum DriveConvertOutcome { finished, failed, pending }

/// [DriveConvertOfficeRunner.run] 的返回值：结果 + 失败时的原始异常
/// （UI 用它按错误码做门控：105/160 → 无权限，119/106 → 会话提示）。
class DriveConvertResult {
  const DriveConvertResult(this.outcome, [this.error]);

  final DriveConvertOutcome outcome;
  final Object? error;
}

/// `convert_office` 的运行时编排：提交 → 有界轮询 → 结果判定。
///
/// **绝不谎报成功**：只有轮询到 `status == "finished"`（且有回包）才返回
/// [DriveConvertOutcome.finished]；轮询通道失败/超时/形状不认识一律
/// [DriveConvertOutcome.pending]（= 已提交）。
///
/// 轮询用的是 `Tasks:get`（官方前端源码级证据，**真机未验证**）；参数与超时
/// 可注入，便于离线测试。
class DriveConvertOfficeRunner {
  DriveConvertOfficeRunner({
    required this.api,
    this.pollInterval = const Duration(seconds: 2),
    this.maxPolls = 5,
    this.onSubmitted,
  });

  final DriveApi api;

  /// 两次轮询之间的间隔（测试传 [Duration.zero]）。
  final Duration pollInterval;

  /// 最多轮询几次（防死循环）。
  final int maxPolls;

  /// 提交成功回调：**只给内部/测试**（`taskId` 绝不进 UI）。
  final void Function(String taskId)? onSubmitted;

  Future<DriveConvertResult> run({
    required String fileId,
    String format = 'docx',
  }) async {
    final String taskId;
    try {
      taskId = await api.convertOffice(fileId: fileId, format: format);
    } catch (e) {
      return DriveConvertResult(DriveConvertOutcome.failed, e);
    }
    // 提交已经成功：即使没有 task id / 轮询不可用，也只能说"已提交"。
    onSubmitted?.call(taskId);
    if (taskId.isEmpty) {
      return const DriveConvertResult(DriveConvertOutcome.pending);
    }

    for (var i = 0; i < maxPolls; i++) {
      if (pollInterval > Duration.zero) {
        await Future<void>.delayed(pollInterval);
      }
      final DriveTaskDto? task;
      try {
        task = await api.getTask(taskId);
      } catch (_) {
        // 轮询通道不可用 → 停在"已提交"，不谎报成功。
        return const DriveConvertResult(DriveConvertOutcome.pending);
      }
      if (task == null) {
        return const DriveConvertResult(DriveConvertOutcome.pending);
      }
      if (task.failed) {
        return const DriveConvertResult(DriveConvertOutcome.failed);
      }
      if (task.finished) {
        return const DriveConvertResult(DriveConvertOutcome.finished);
      }
      // 其它状态（in_progress / 未知）→ 继续轮询
    }
    return const DriveConvertResult(DriveConvertOutcome.pending);
  }
}

/// 转换编排器（未连接 → null）。测试可 `overrideWithValue` 注入零间隔实例。
final driveConvertOfficeRunnerProvider = Provider<DriveConvertOfficeRunner?>((
  ref,
) {
  final api = ref.watch(driveApiProvider);
  return api == null ? null : DriveConvertOfficeRunner(api: api);
});

// ------------------------------------------------------------- 文件计数

/// 一个目录的**条目数**（`Files:count_files` **v11** → `path → 数量` 映射）。
///
/// 传进去的 [path] 与回包 key 逐字对应（真机：`/mydrive` → 14、
/// `/mydrive/PhotoBackup` → 4）。这里只取**当前目录那一个 key**，
/// **不把原始 `{path: count}` 映射丢上屏**。
///
/// 返回 null 的三种情形（都不发请求）：
///   * 路径为空（拿不到可数的 path）；
///   * 能力位缺失 / Drive 明确不可用（统一门控）；
///   * 服务器 `Files` maxVersion < 11（APK `VERSION_SUPPORT_FILE_COUNT_QUERY = 0xb`）。
///
/// 失败**不静默**：`AsyncError` 由 UI 显示"暂时取不到"（见 `drive_info_sheet.dart`）。
final driveFolderCountProvider = FutureProvider.autoDispose
    .family<int?, String>((ref, path) async {
      if (path.isEmpty) return null;
      final snap = ref.watch(serviceAvailabilityProvider);
      if (hidesModule(snap.stateOf(StationService.drive))) return null;
      if (!snap.hasApi(StationService.drive, kDriveFilesApiName)) return null;
      final api = ref.watch(driveApiProvider);
      if (api == null || !api.supportsFilesV11) return null;
      final counts = await api.countFiles([path]);
      return counts[path];
    }, retry: noRetry);

// --------------------------------------------------------- 请求访问权

/// `Files:request_access`（**v11**）是否可用。
///
/// **写操作**的门控更保守：没连上（`api == null`）→ 不显示按钮；
/// 服务器 `Files` 低于 v11 → 不显示（官方 App 那一代没有这个能力）。
bool driveRequestAccessAvailable(WidgetRef ref) {
  final snap = ref.watch(serviceAvailabilityProvider);
  if (hidesModule(snap.stateOf(StationService.drive))) return false;
  if (!snap.hasApi(StationService.drive, kDriveFilesApiName)) return false;
  return ref.watch(driveApiProvider)?.supportsFilesV11 ?? false;
}

/// 申请访问权（`Files:request_access` v11）的写操作封装。
///
/// ⚠️ 调用方**必须先弹确认框**（写操作）；失败**原样抛出**，由 UI 明确提示。
class DriveRequestAccessAction {
  DriveRequestAccessAction(this.ref);

  final Ref ref;

  /// `path` 优先用展示路径（`/mydrive/...`，与 `count_files` 真机取证的 path
  /// 形态一致），为空才回落 `id:<file_id>`。
  Future<void> request(DriveEntryDto entry) async {
    final api = ref.read(driveApiProvider);
    if (api == null) throw StateError('not connected');
    final path = entry.displayPath.isNotEmpty
        ? entry.displayPath
        : entry.pathId;
    await api.requestAccess(path: path);
  }
}

final driveRequestAccessActionProvider = Provider<DriveRequestAccessAction>(
  DriveRequestAccessAction.new,
);
