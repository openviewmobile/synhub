// 相册备份的**后台入口**（WorkManager 拉起一个 FlutterEngine 后执行这里）。
//
// 结构（官方 Synology Drive 安卓端同构：WorkManager 里跑真正的上传逻辑，
// `core/BackupWork.java:29` `class BackupWork extends CoroutineWorker`）：
//
//   Kotlin `PhotoBackupWorker`
//     → 新建 FlutterEngine + `executeDartCallback`（本文件的 entrypoint）
//     → MethodChannel `synhub/photo_backup_bg` 调 `runBackup`
//     → 这里装配**最小无 UI 依赖图**（本地库 → 上次登录 → 登录 → API）
//     → `PhotoBackupRunner.run()`（与前台页面**同一个**队列/上传器/去重）
//     → 回一个 `{ok,done,failed,skipped,total,error}` map
//
// 为什么必须复用 [PhotoBackupRunner] 而不是在这里重写上传：需求明确要求
// "复用现有上传器"；而且前台/后台两条路的行为必须一致（否则同一个文件在两条
// 路上会得到不同结果）。
//
// ⚠️ **只编译过、未真机跑**（见 `docs/photo-backup-background.md` §未验证项）。
// 已知边界：
//   * 后台 isolate **不弹权限框**（`ensurePermission(interactive: false)`）——
//     用户没给相册权限就直接失败，不会半夜弹窗；
//   * 会话靠 `SavedSessionStore` 里那套凭据静默重登（Android Keystore 封存）；
//     凭据解不开（换机/重装）→ 报告 `error`，**不**清空用户数据；
//   * 自签证书第一次连接需要用户在前台信任过（信任库已落盘），后台不再弹框。
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/net/trust_store.dart';
import '../../core/security/keystore_secret_keeper.dart';
import '../../core/settings/app_settings.dart';
import '../../data/drive_api.dart';
import '../../data/foto_api.dart';
import '../../data/local/chat_store.dart';
import '../../data/local/database.dart';
import '../../data/media/device_media_library.dart';
import '../servers/connection_service.dart';
import '../servers/saved_session.dart';
import 'photo_backup_dedup.dart';
import 'photo_backup_platform.dart';
import 'photo_backup_queue.dart';
import 'photo_backup_runner.dart';
import 'photo_backup_store.dart';
import 'photo_backup_target.dart';
import '../../core/platform/app_platform.dart';
import '../../core/user_facing_error.dart';

/// 后台 isolate 的入口。**函数名必须与
/// `PhotoBackupPlugin.registerCallback` 收到的 handle 对应**（Dart 侧用
/// `PluginUtilities.getCallbackHandle(photoBackupBackgroundMain)` 取 handle）。
@pragma('vm:entry-point')
void photoBackupBackgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kPhotoBackupBackgroundChannel);
  // 第 55 轮：后台通道只有 Android 侧注册；能力层不放行就不监听。
  if (!capabilityGateAllows(AppCapability.photoBackup)) {
    debugPrint(
      capabilityGateLog(AppCapability.photoBackup, 'photo_backup_bg.subscribe'),
    );
    return;
  }
  channel.setMethodCallHandler((call) async {
    if (call.method != 'runBackup') return null;
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    return runPhotoBackupInBackground(args);
  });
}

/// 后台跑一轮备份并返回可序列化报告。
///
/// [open] 是给用例的注入缝：默认走 [openPhotoBackupBackgroundContext]
/// （真库 + 静默重登），单测喂一套假依赖图，把"参数解析 + 报告序列化 +
/// 无会话时的错误语义"钉住，而不用真的起 isolate/连 NAS。
///
/// 充电/息屏/网络三个约束由原生 `PhotoBackupWorker.doWork()` 在**调用 Dart 之前**
/// 判定（`Result.retry()`），这里只把参数带进来做记录，不做二次判定 ——
/// 后台 isolate 没有 `PhotoBackupPlugin` 的通道，问不到电池/息屏状态。
Future<Map<String, Object?>> runPhotoBackupInBackground(
  Map<String, Object?> args, {
  Future<PhotoBackupBackgroundContext?> Function(String device)? open,
}) async {
  final destination = PhotoBackupDestination.fromId(
    args['destination'] as String?,
  );
  final device = '${args['device'] ?? ''}';
  final resolvedDevice = device.isEmpty ? 'Android' : device;
  PhotoBackupRunReport report;
  try {
    final context = await (open ?? openPhotoBackupBackgroundContext)(
      resolvedDevice,
    );
    if (context == null) {
      report = PhotoBackupRunReport(
        destination: destination,
        total: 0,
        done: 0,
        failed: 0,
        skipped: 0,
        error: 'no-saved-session',
      );
    } else {
      final snapshot = await context.store.load();
      report = await _runWith(context, snapshot);
    }
  } catch (err) {
    report = PhotoBackupRunReport(
      destination: destination,
      total: 0,
      done: 0,
      failed: 0,
      skipped: 0,
      error: userFacingError(err),
    );
  }
  return report.toMap();
}

/// 后台依赖图（可被用例替换）。
class PhotoBackupBackgroundContext {
  const PhotoBackupBackgroundContext({
    required this.store,
    required this.runner,
    required this.close,
  });

  final PhotoBackupStore store;
  final PhotoBackupRunner runner;

  /// 收尾（关数据库等）
  final Future<void> Function() close;
}

Future<PhotoBackupRunReport> _runWith(
  PhotoBackupBackgroundContext context,
  PhotoBackupSnapshot snapshot,
) async {
  try {
    return await context.runner.run(snapshot);
  } finally {
    await context.close();
  }
}

/// 装配后台那套最小依赖图；没有可用会话时回 null。
///
/// **不碰 UI、不弹框、不改用户数据**：只读本地库 + 静默重登。
Future<PhotoBackupBackgroundContext?> openPhotoBackupBackgroundContext({
  required String device,
}) async {
  final db = ChatDatabase.open();
  final chatStore = ChatStore(db);
  final settings = SettingsService(chatStore);
  final savedStore = SavedSessionStore(
    chatStore,
    keeper: const KeystoreSecretKeeper(),
  );
  final saved = await savedStore.load();
  if (saved == null || !saved.canAutoLogin) {
    await db.close();
    return null;
  }

  final trust = TrustPolicy.of(
    read: (k) => chatStore.setting(k),
    write: (k, v) => chatStore.setSetting(k, v),
    remove: (k) => chatStore.deleteSetting(k),
    all: () => chatStore.allSettings(),
  );
  await trust.load();
  final service = ConnectionService(trustPolicy: trust);
  final conn = await service.connect(saved.profile);
  await conn.api.login(
    account: saved.account,
    password: saved.password!,
    session: 'Chat',
    deviceId: saved.deviceId,
    enableDeviceToken: saved.rememberDevice,
  );

  final targets = PhotoBackupTargets(
    fotoOf: () => FotoApi(conn.api),
    driveOf: () => DriveApi(conn.api),
    deviceNameOf: () => device,
  );
  final runner = PhotoBackupRunner(
    media: MethodChannelDeviceMediaLibrary(),
    uploader: DestinationPhotoBackupUploader(targets),
    store: DriftPhotoBackupStore(settings, db),
    targets: targets,
    hasher: const FilePhotoBackupHasher(),
    maxConcurrent: 1,
  );
  return PhotoBackupBackgroundContext(
    store: DriftPhotoBackupStore(settings, db),
    runner: runner,
    close: db.close,
  );
}
