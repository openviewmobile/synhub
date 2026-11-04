// 相册**本地偏好**的最小 KV 存储（纯客户端，服务端 API 不适用）。
//
// 为什么需要它：P24（最近搜索）、P4（网格密度）、P48（播放设置）三项官方都是
// **本地持久化**（`photo-parity-audit.md:141/121/170`），服务端没有对应 API。
// 而本批次**不许**改 `pubspec.yaml`、**不许**改 `lib/src/core/**`，仓库里也没有
// 公开的裸 KV 写入口（`lib/src/data/local/` 只有 Drift 业务表）。
//
// 复用既有依赖 `flutter_secure_storage`（`photo_map_prefs.dart` 同款、已经是
// 直接依赖）是最短路径：值本身不是秘密，放安全存储只是"能持久化且不动 core"。
//
// 测试/纯 Dart 探针：覆盖 [photoPrefsStoreProvider] 传一个内存实现即可，
// 绝不依赖平台通道。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/platform/app_secure_storage.dart';

/// 相册本地偏好的读写口（只有字符串，JSON 由各偏好自己编解码）。
abstract interface class PhotoPrefsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);

  /// 删除（"清除历史"用）。
  Future<void> delete(String key);
}

/// 真机实现：`flutter_secure_storage`。任何异常**一律静默**（读失败当没存过、
/// 写失败当没写）——本地偏好读不出来绝不能让相册崩。
class SecurePhotoPrefsStore implements PhotoPrefsStore {
  SecurePhotoPrefsStore([FlutterSecureStorage? storage])
    : _storage =
          storage ?? appSecureStorage(android: const AndroidOptions());

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      // Keystore 损坏 / 桌面无插件 → 本次不落盘，功能照常（内存里已生效）
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }
}

/// 相册本地偏好存储（测试覆盖它）。
final photoPrefsStoreProvider = Provider<PhotoPrefsStore>(
  (ref) => SecurePhotoPrefsStore(),
);

// ---------------------------------------------------------------- 键名

/// 网格密度（列数）的落盘 key。改字符串会让用户旧选择读不回来。
const String kPhotoGridColumnsSlot = 'photo_grid_columns_v1';

/// 最近搜索历史的落盘 key。
const String kPhotoSearchHistorySlot = 'photo_search_history_v1';

/// 播放设置的落盘 key。
const String kPhotoPlaybackSettingsSlot = 'photo_playback_settings_v1';

/// 幻灯片设置的落盘 key。
const String kPhotoSlideshowSettingsSlot = 'photo_slideshow_settings_v1';
