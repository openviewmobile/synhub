// 相册「手机自动备份」的 provider 装配。
//
// 可替换件（离线测试里全部覆盖成假的）：
//   * [deviceMediaLibraryProvider]   —— 本机相册（生产走 `synhub/media`）
//   * [photoBackupStoreProvider]     —— **每落点**账本/全局开关（生产走 Drift：
//                                      选项在键值表、游标在 v12 新表）
//   * [photoBackupUploaderProvider]  —— 按落点分派的上传器
//   * [photoBackupTargetsProvider]   —— 两个落点的目标目录/去重清单
//   * [photoBackupPlatformProvider]  —— WorkManager 排程/状态（原生桥）
//   * [photoBackupRunnerProvider]    —— 前台与后台**共用**的编排器
import 'dart:ui' show PluginUtilities;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/app_settings.dart';
import '../../data/media/device_media_library.dart';
import '../chat/chat_session_controller.dart' show chatDatabaseProvider;
import '../files/drive_providers.dart' show driveApiProvider;
import 'photo_backup_background.dart' show photoBackupBackgroundMain;
import 'photo_backup_dedup.dart';
import 'photo_backup_platform.dart';
import 'photo_backup_queue.dart';
import 'photo_backup_runner.dart';
import 'photo_backup_store.dart';
import 'photo_backup_target.dart';
import 'photo_providers.dart';

/// 本机相册读取（测试里覆盖成 `FakeDeviceMediaLibrary`）
final deviceMediaLibraryProvider = Provider<DeviceMediaLibrary>(
  (ref) => MethodChannelDeviceMediaLibrary(),
);

/// **每落点**账本 + 全局开关：选项走既有键值 JSON，游标走 v12 新表。
final photoBackupStoreProvider = Provider<PhotoBackupStore>(
  (ref) => DriftPhotoBackupStore(
    ref.watch(settingsServiceProvider),
    ref.watch(chatDatabaseProvider),
  ),
);

/// 两个落点的操作集。三个回调在**调用时**取当前连接（会话重连/换空间不会
/// 拿到过期 API），设备名问原生（`Build.MODEL`），拿不到回 `Android`。
final photoBackupTargetsProvider = Provider<PhotoBackupTargets>((ref) {
  return PhotoBackupTargets(
    // 三个回调都在**调用时**取当前连接：会话重连/换空间不会拿到过期 API
    // （与既有 `FotoBackupUploaderAdapter` 同一套路）。
    fotoOf: () => ref.read(fotoSpaceApiProvider),
    driveOf: () => ref.read(driveApiProvider),
    // 设备名来自原生 `status()`（`Build.MODEL`），没探过就回 `Android`
    deviceNameOf: () => _cachedDeviceName ?? 'Android',
  );
});

/// 最近一次 `status()` 里的设备名（原生 `Build.MODEL`）。没探过就回 `Android`。
String? _cachedDeviceName;

/// 把原生 `status()` 里的设备名记下来（由 [photoBackupPlatformStatusProvider] 填）
void cachePhotoBackupDeviceName(String name) {
  if (name.isNotEmpty) _cachedDeviceName = name;
}

/// 内容哈希（抽样 MD5 + 全文件 MD4）
final photoBackupHasherProvider = Provider<PhotoBackupHasher>(
  (ref) => const FilePhotoBackupHasher(),
);

/// 按落点分派的上传器（Photos → `FotoApi.uploadToFolder`；
/// Drive → `DriveApi.uploadPhotoForBackup`）
final photoBackupUploaderProvider = Provider<PhotoBackupUploader>(
  (ref) =>
      DestinationPhotoBackupUploader(ref.watch(photoBackupTargetsProvider)),
);

/// WorkManager / 状态 / 互斥标志的原生桥。
final photoBackupPlatformProvider = Provider<PhotoBackupPlatform>(
  (ref) => MethodChannelPhotoBackupPlatform(),
);

/// 把后台 entrypoint 的 handle 交给原生（WorkManager 起 FlutterEngine 要用）。
///
/// 纯本地操作，幂等；平台不支持时返回 false（**不抛**，界面按"仅前台备份"降级）。
Future<bool> ensurePhotoBackupCallbackRegistered(
  PhotoBackupPlatform platform,
) async {
  try {
    final handle = PluginUtilities.getCallbackHandle(photoBackupBackgroundMain);
    if (handle == null) return false;
    return await platform.registerCallback(handle.toRawHandle());
  } catch (_) {
    return false;
  }
}

/// 前台与后台共用的编排器。
///
/// `maxConcurrent: 1` 是**官方同构**（`PhotoBackupManager.java:493` 单线程池 +
/// `BackupExecutor.java` 串行），不是随手写的默认值。
final photoBackupRunnerProvider = Provider<PhotoBackupRunner>((ref) {
  return PhotoBackupRunner(
    media: ref.watch(deviceMediaLibraryProvider),
    uploader: ref.watch(photoBackupUploaderProvider),
    store: ref.watch(photoBackupStoreProvider),
    targets: ref.watch(photoBackupTargetsProvider),
    hasher: ref.watch(photoBackupHasherProvider),
    maxConcurrent: 1,
  );
});
