// 笔记的**后台同步入口**（第 114 轮 M3；官方 `SyncService` 的对应物）。
//
// 官方机制（反编译取证，见 `docs/admin-parity-requirement.md` §49）：
//   * `AndroidManifest.xml:113`：`SyncService` 是
//     `foregroundServiceType="dataSync"` 的常驻服务；
//   * `Utils.resumeSyncService()/pauseSyncService()` 由界面动作驱动启停；
//   * WorkManager **只**用于 `FullTextSearchWorker`，**没有** PeriodicWorkRequest。
//
// 我方在本机 Android 的约束下（不能像官方那样长期常驻 dataSync 服务）用
// **WorkManager 周期任务 + 一次性的短任务**实现同一件事：
//
//   Kotlin `NoteSyncWorker`
//     → 新建 headless FlutterEngine + `executeDartCallback`（本文件的 entrypoint）
//     → MethodChannel `synhub/note_sync_bg` 调 `runSync`
//     → 这里装配**最小无 UI 依赖图**（本地库 → 恢复会话 → NoteStationApi）
//     → 复用**同一个** `NoteSyncNotifier`（前台/后台行为必须一致）
//     → 回一个可序列化报告给原生（用于日志/通知）
//
// ⚠️ **只编译过 + 单测覆盖，未真机跑后台唤醒**（与照片备份同一约定，
// 见 `docs/photo-backup-background.md` 的"未验证项"口径）。
// 已定边界：后台**不弹任何框**；会话靠本地已存凭据静默恢复，
// 恢复不了就回 `no-saved-session`（**不清用户数据**）。
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/user_facing_error.dart';
import '../../data/local/database.dart';
import '../chat/chat_session_controller.dart' show chatDatabaseProvider;
import '../servers/session_controller.dart';
import 'note_providers.dart' show noteApiProvider;
import 'note_sync.dart';

/// 后台通道名（Kotlin `NoteSyncPlugin` 用它调 Dart）。
const String kNoteSyncBackgroundChannel = 'synhub/note_sync_bg';

/// 后台 isolate 入口。**函数名必须与原生收到的 handle 对应**
/// （Dart 侧用 `PluginUtilities.getCallbackHandle(noteBackgroundSyncMain)` 取）。
@pragma('vm:entry-point')
void noteBackgroundSyncMain() {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kNoteSyncBackgroundChannel);
  // 第 55 轮：后台通道只有 Android 侧注册；能力层不放行就不监听。
  if (!capabilityGateAllows(AppCapability.scheduledNoteSync)) {
    debugPrint(
      capabilityGateLog(AppCapability.scheduledNoteSync, 'note_sync_bg.subscribe'),
    );
    return;
  }
  channel.setMethodCallHandler((call) async {
    if (call.method != 'runSync') return null;
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    return runNoteSyncInBackground(args);
  });
}

/// 后台跑一轮同步并返回可序列化报告。
///
/// [open] 是用例的注入缝：默认走 [openNoteSyncBackgroundContext]（真库 +
/// 静默恢复会话），单测喂假依赖图，把"参数解析 + 报告序列化 + 无会话语义"
/// 钉住，不必真的起 isolate / 连 NAS。
Future<Map<String, Object?>> runNoteSyncInBackground(
  Map<String, Object?> args, {
  Future<NoteSyncBackgroundContext?> Function()? open,
}) async {
  final reason = '${args['reason'] ?? 'periodic'}';
  NoteSyncBackgroundReport report;
  try {
    final context = await (open ?? openNoteSyncBackgroundContext)();
    if (context == null) {
      report = NoteSyncBackgroundReport(
        reason: reason,
        ok: false,
        error: 'no-saved-session',
      );
    } else {
      report = await _runWith(context, reason);
    }
  } catch (err) {
    report = NoteSyncBackgroundReport(
      reason: reason,
      ok: false,
      error: userFacingError(err),
    );
  }
  return report.toMap();
}

/// 后台依赖图（可被用例替换）。
class NoteSyncBackgroundContext {
  const NoteSyncBackgroundContext({
    required this.runSync,
    required this.close,
  });

  /// 跑一轮同步（真实现里是 `NoteSyncNotifier.sync()`）。
  final Future<NoteSyncStatus> Function() runSync;

  /// 收尾（关数据库等）。
  final Future<void> Function() close;
}

Future<NoteSyncBackgroundReport> _runWith(
  NoteSyncBackgroundContext context,
  String reason,
) async {
  try {
    final status = await context.runSync();
    return NoteSyncBackgroundReport(
      reason: reason,
      ok: !status.offline && status.state != NoteSyncState.error,
      pending: status.pending,
      conflicts: status.conflicts.length,
      error: status.offline ? 'offline' : status.message,
    );
  } finally {
    await context.close();
  }
}

/// 后台同步的可序列化报告（原生只读它，用于日志/失败重试判定）。
class NoteSyncBackgroundReport {
  const NoteSyncBackgroundReport({
    required this.reason,
    required this.ok,
    this.pending = 0,
    this.conflicts = 0,
    this.error,
  });

  final String reason;
  final bool ok;
  final int pending;
  final int conflicts;
  final String? error;

  Map<String, Object?> toMap() => {
    'reason': reason,
    'ok': ok,
    'pending': pending,
    'conflicts': conflicts,
    'error': error,
  };
}

/// 装配后台那套最小依赖图；没有可用会话时回 null。
///
/// **不碰 UI、不弹框、不改用户数据**：只开本地库 + 静默恢复会话。
Future<NoteSyncBackgroundContext?> openNoteSyncBackgroundContext() async {
  final db = ChatDatabase.open();
  final container = ProviderContainer(
    overrides: [chatDatabaseProvider.overrideWithValue(db)],
  );
  var closeOnce = false;
  Future<void> close() async {
    if (closeOnce) return;
    closeOnce = true;
    container.dispose();
    await db.close();
  }

  try {
    // 静默恢复会话：恢复不成功就没必要跑（**不**清数据、**不**弹登录）
    await container.read(sessionControllerProvider.notifier).restore();
    if (container.read(noteApiProvider) == null) {
      await close();
      return null;
    }
    return NoteSyncBackgroundContext(
      runSync: () => container.read(noteSyncProvider.notifier).sync().then(
        (_) => container.read(noteSyncProvider),
      ),
      close: close,
    );
  } catch (_) {
    await close();
    return null;
  }
}
