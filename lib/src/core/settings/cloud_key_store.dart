// API Key 的存储：**不落普通偏好表**，走系统安全存储。
//
// 业界惯例（也是常识）：API Key 属于凭据，不能明文写进 SharedPreferences /
// 普通数据库 —— Android 上放 `EncryptedSharedPreferences`（Keystore 派生密钥），
// iOS 上放 Keychain。这里用 `flutter_secure_storage` 达成同一效果。
//
// 抽象出接口的意义：单测里换成内存实现，既不碰原生也不用真 key。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../platform/app_secure_storage.dart';

abstract class CloudKeyStore {
  Future<String?> read(String providerId);
  Future<void> write(String providerId, String key);
  Future<void> delete(String providerId);
}

/// 真机实现：Android = EncryptedSharedPreferences，iOS = Keychain
class SecureCloudKeyStore implements CloudKeyStore {
  SecureCloudKeyStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          appSecureStorage(
            // 11.x 起 Android 端固定走 Keystore + AES-GCM（不再有
            // `encryptedSharedPreferences` 开关），默认构造就是最安全的档
            android: const AndroidOptions(),
            ios: const IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
            // ★ macOS 由 `appSecureStorage()` 统一关掉"数据保护钥匙串"
            //   （插件的默认 `usesDataProtectionKeychain: true` 在 ad-hoc 签名下
            //   抛 -34018，见该文件头 D29）—— 这里**故意不写** mOptions。
          );

  final FlutterSecureStorage _storage;

  static String _slot(String providerId) => 'ai_cloud_key_$providerId';

  @override
  Future<String?> read(String providerId) async {
    try {
      return await _storage.read(key: _slot(providerId));
    } catch (_) {
      // 安全存储偶尔会抽风（Keystore 损坏/被重置）——不该让整个设置页崩掉
      return null;
    }
  }

  @override
  Future<void> write(String providerId, String key) async {
    try {
      if (key.isEmpty) {
        await _storage.delete(key: _slot(providerId));
        return;
      }
      await _storage.write(key: _slot(providerId), value: key);
    } catch (_) {
      // 写不进去也别抛：UI 会提示"没保存住"
    }
  }

  @override
  Future<void> delete(String providerId) async {
    try {
      await _storage.delete(key: _slot(providerId));
    } catch (_) {}
  }
}

/// 内存实现（单测 / 安全存储不可用时）
class MemoryCloudKeyStore implements CloudKeyStore {
  final Map<String, String> _keys = {};

  @override
  Future<String?> read(String providerId) async => _keys[providerId];

  @override
  Future<void> write(String providerId, String key) async {
    if (key.isEmpty) {
      _keys.remove(providerId);
    } else {
      _keys[providerId] = key;
    }
  }

  @override
  Future<void> delete(String providerId) async => _keys.remove(providerId);
}

final cloudKeyStoreProvider = Provider<CloudKeyStore>(
  (ref) => SecureCloudKeyStore(),
);
