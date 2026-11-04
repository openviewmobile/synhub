// Android Keystore / macOS Keychain 版 [SecretKeeper]（这个文件可以引 Flutter）。
//
// 对齐原版 `util/LegacyKeystoreHelper.java` + `PreferencesHelper.setBase64KeyPair`：
// 原版把整对 `Base64ChatKeyPair`（含 privateKeyEnc）先 Gson 序列化，再用
// AndroidKeyStore 里 alias `SYNOAPP` 的 RSA-2048 分块加密，最后以 `CipherData`
// （`base64(json{long:base64(ct),short:base64(iv)})`）写进 SharedPreferences。
//
// 我们的取舍：AES-256-GCM（更现代、带认证、不用自己分块），alias
// `synhub_secrets`，串形 `v1:<base64(iv)>:<base64(ct+tag)>`，落在 Drift
// 键值表的 `e2ee_identity`。原版的 RSA/`CipherData` 私有格式不做兼容。
//
// ⚠️ Keystore 里的密钥**不随 App 数据备份**：重装/换机后解不开是正常的 ——
// 那时走既有流程从服务端取 `key_pair` + 口令解锁（`E2eeController`）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/e2ee/secret_keeper.dart';
import '../platform/linux_keyring_gate_state.dart';
import '../platform/app_platform.dart';
import '../platform/app_secure_storage.dart';
import 'linux_keyring_dbus_probe.dart';
import 'linux_keyring_probe.dart';

class KeystoreSecretKeeper implements SecretKeeper {
  const KeystoreSecretKeeper();

  static const MethodChannel _channel = MethodChannel('synhub/keystore');

  /// macOS / iOS：Keychain 存取（P0-3；iOS 第 92 轮补）。
  ///
  /// 前缀保留历史名 `macos-secure:` —— 它是**落盘格式的一部分**
  /// （`open` 按它判"这条是不是 Keychain 存的"），改名会让已有 macOS
  /// 用户存在 Drift 里的既有密文变成"解不开"。语义已扩到两家 Apple 平台，
  /// 名字不改（兼容优先于好看）。
  /// ★ 第 328 轮 D29：**不许**用 `const FlutterSecureStorage()` —— 插件的
  /// `MacOsOptions.usesDataProtectionKeychain` 默认 `true`，在 ad-hoc 签名的
  /// macOS 上写一次就抛 `-34018`（E2EE 私钥会**静默存不上**）。
  static final FlutterSecureStorage _secure = appSecureStorage();
  static const String _macPrefix = 'macos-secure:';

  /// 只有"真 Android + 真 App 进程"才去碰 channel。
  ///
  /// ⚠️ `flutter test` 里 `defaultTargetPlatform` **也是 android**，但那时没有
  /// 真的 Keystore；而且给未注册的 channel 发消息在 fake async 下会一直挂着
  /// （踩过：整套离线测试卡到 10 分钟超时）。所以用 flutter_tools 会设的
  /// `FLUTTER_TEST=true` 把测试环境挡掉。真机 integration_test 跑在 App 进程里、
  /// 没有这个环境变量 → 走真 Keystore（这正是我们要验的）。
  /// 能力门（第 79 轮，第 92 轮加 iOS，第 108 轮加 Linux，第 293 轮加 Windows）：
  /// `secureStorage` 在 Android/macOS/iOS/**Linux**/**Windows** 上 `available`，
  /// 其余宿主 `unavailable` —— **拦在碰通道之前**，不让调用点去撞
  /// `MissingPluginException`。命名成 `isSupported` 是为了让结构守卫
  /// （`test/method_channel_gate_guard_test.dart`）认出这是能力门。
  static bool get isSupported =>
      capabilityGateAllows(AppCapability.secureStorage) && _hostSupports;

  /// 宿主层事实（与能力位**正交**，两者都成立才碰通道）：
  /// * Android ⇒ Keystore 通道（`isTestEnvironment` / `FLUTTER_TEST` 时挡掉：
  ///   给未注册的 channel 发消息在 fake async 下会一直挂着，踩过 10 分钟超时）；
  /// * macOS / iOS ⇒ Keychain（`flutter_secure_storage` 的 darwin 插件
  ///   **同时声明了 ios 与 macos**，见 `.flutter-plugins-dependencies`）；
  /// * **Linux ⇒ libsecret**（`flutter_secure_storage_linux` 3.0.3，第 108 轮补）
  ///   —— 它**已经**在 `linux/flutter/generated_plugin_registrant.cc` 这份
  ///   **生成产物**里注册着，而这里以前不认 Linux ⇒ Linux 上凭据只能明文落盘。
  /// * **Windows ⇒ DPAPI**（`flutter_secure_storage_windows` 4.2.2，第 293 轮补）
  ///   —— 第 293 轮先在真 Windows 上把根因钉住了：`seal()` **从来没走到插件**，
  ///   因为下面这个宿主判定**根本不含 Windows**；而**同一个进程里直连**
  ///   `FlutterSecureStorage` 的 write/read 是**成功**的（DPAPI 文件成形，
  ///   见 `docs/platform-windows.md` §15）。
  ///
  /// 第 42 轮 P0-3：以前这里只认 Android ⇒ macOS 凭据明文落盘；
  /// 第 92 轮 iOS 是同一个漏（iOS 上 `_isMac` 恒 false ⇒ 会去碰
  /// Android-only 的 `synhub/keystore` 通道）；第 108 轮 Linux 是第三次；
  /// **第 293 轮 Windows 是第四次**（真机取证明文 → 修 → 五条口径验收）。
  static bool get _hostSupports =>
      secretKeeperHostSupportedFor(
        platform: defaultTargetPlatform,
        isWeb: kIsWeb,
        inFlutterTest: _inFlutterTest,
      ) &&
      // ★ r698：Linux 还要过一道**起飞前检查** —— 没有已存在的默认 keyring 就
      //   **根本不碰 libsecret**（一碰它就会请 GNOME 新建 keyring，那个模态调用
      //   **同步阻塞 GTK 主循环** ⇒ 整个 App 停帧，连 `pump()` 都不返回）。
      //   代价只是"这台机器上不记住密码"，而不是"冻在登录页"。
      //   证据与反证见 lib/src/core/security/linux_keyring_probe.dart 文件头。
      _keyringPreflight;

  /// 走 `flutter_secure_storage` 插件这条路（Keychain / libsecret / **DPAPI**）。
  /// `_macPrefix` 是**落盘格式**的历史名，别按名字读语义。
  /// Linux 的起飞前检查；其它平台恒 true（不改变既有行为）。
  static bool get _keyringPreflight {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.linux) return true;
    if (_cachedKeyringReady != null) return _cachedKeyringReady!;
    late final bool ok;
    try {
      ok = linuxKeyringHasDefaultCollection(
        dataHome: Platform.environment['XDG_DATA_HOME'],
        home: Platform.environment['HOME'],
        listDir: _listKeyringDir,
      );
    } catch (_) {
      ok = false;
    }
    _cachedKeyringReady = ok;
    return ok;
  }

  /// 真实列目录（`dart:io` 只在这里出现；判据本身是纯函数，见 probe 文件头）。
  static List<String> _listKeyringDir(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    return d.listSync().map((e) => e.uri.pathSegments.last).toList();
  }

  static bool? _cachedKeyringReady;

  /// 用例用：清掉起飞前检查的缓存（改了假 HOME 之后要能重算）。
  @visibleForTesting
  static void debugResetKeyringPreflightCache() => _cachedKeyringReady = null;

  /// ★ r701 · `DA340`：起飞前检查要**异步预热**一次，因为"集合是否锁定"只能问 D-Bus。
  ///
  /// 为什么不能留在同步路径里：`_keyringPreflight` 是 `bool` getter（`isSupported`
  /// 也是同步的，调用点很多）；D-Bus 调用必然是异步的。所以：
  ///   * **启动时**（`lib/main.dart`，`runApp` 之前）调这个函数，把结论缓存下来；
  ///   * 同步 getter 只读缓存；
  ///   * 没预热过（宿主单测 / 没走到 main）⇒ 回退到 r698 的**文件判据**，
  ///     行为与 r698 一致，不会把既有用例变红。
  ///
  /// 判据见 `linux_keyring_probe.dart` 的 [linuxKeyringUsable]：
  /// 文件在 **且** 至少一个 collection 未锁，才允许碰 libsecret。
  static Future<void> warmUpLinuxKeyringProbe() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.linux) return;
    if (_inFlutterTest) return;
    bool hasFile = false;
    try {
      hasFile = linuxKeyringHasDefaultCollection(
        dataHome: Platform.environment['XDG_DATA_HOME'],
        home: Platform.environment['HOME'],
        listDir: _listKeyringDir,
      );
    } catch (_) {
      hasFile = false;
    }
    bool? unlocked;
    if (hasFile) {
      try {
        unlocked = await linuxKeyringDefaultCollectionUnlocked();
      } catch (_) {
        unlocked = null; // 探测不出来 ⇒ fail-closed（见判据注释）
      }
    }
    _cachedKeyringReady = linuxKeyringUsable(
      hasCollectionFile: hasFile,
      anyUnlocked: unlocked,
    );
    // ★ 闸门装到**唯一构造点**（`app_secure_storage.dart`）：不仅是 keeper，
    //   任何直连 `appSecureStorage()` 的调用点也必须被挡（DA340 第二层）。
    linuxKeyringBlocked = !_cachedKeyringReady!;
    debugPrint(
      '[keyring] warmUp hasFile=$hasFile anyUnlocked=$unlocked '
      '⇒ usable=$_cachedKeyringReady',
    );
  }

  static bool get _usesPluginSecureStorage =>
      !kIsWeb && usesPluginSecureStorageFor(defaultTargetPlatform);

  static bool get _inFlutterTest {
    try {
      return Platform.environment['FLUTTER_TEST'] == 'true';
    } catch (_) {
      return true; // 拿不到环境（诡异平台）就当测试，别乱碰 Keystore
    }
  }

  @override
  Future<String?> seal(String plain) async {
    if (plain.isEmpty || !isSupported) return null;
    if (_usesPluginSecureStorage) {
      // 值进平台安全存储（Apple=Keychain / Linux=libsecret），
      // 只把"别名"当作 encoded 落盘（对齐 Android 的"密文落库"）。
      try {
        final alias = 'synhub_secret_${DateTime.now().microsecondsSinceEpoch}';
        await _secure.write(key: alias, value: plain);
        return '$_macPrefix$alias';
      } catch (_) {
        // 运行时没有 keyring（无头 Linux / libsecret 缺失）⇒ 如实"存不了"，
        // 不崩、也不假装存上了（redirect 上层按"没有安全存储"处理）。
        return null;
      }
    }
    try {
      return await _channel.invokeMethod<String>('seal', {'plain': plain});
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> open(String encoded) async {
    if (encoded.isEmpty || !isSupported) return null;
    if (_usesPluginSecureStorage) {
      if (!encoded.startsWith(_macPrefix)) return null;
      try {
        return await _secure.read(key: encoded.substring(_macPrefix.length));
      } catch (_) {
        return null;
      }
    }
    try {
      return await _channel.invokeMethod<String>('open', {'encoded': encoded});
    } catch (_) {
      return null;
    }
  }
}

/// 哪些宿主走 `flutter_secure_storage` 插件这条路。
///
/// * Apple 两家 → Keychain（`flutter_secure_storage_darwin`）；
/// * Linux → libsecret（`flutter_secure_storage_linux`）；
/// * **Windows → DPAPI**（`flutter_secure_storage_windows` 4.2.2；它的默认后端
///   是 `CryptProtectData` + `flutter_secure_storage.dat`，**不是** Credential
///   Manager —— 见 `docs/platform-windows.md` §15.4）。
///
/// ★ **纯函数**（只看传进来的 [TargetPlatform]）⇒ 宿主单元测试可以直接钉住
/// "Windows 在不在这个集合里"，**不必真在 Windows 上跑**（那正是第 109–290 轮
/// 做不到的事）。回归守卫与反向验证见
/// `test/secret_keeper_host_matrix_test.dart`。
///
/// ⚠️ **加平台前必须先核"那个平台的插件真的在"**（两条硬证据：
/// `.flutter-plugins-dependencies` 的平台列 +
/// `<platform>/flutter/generated_plugin_registrant.cc` 这份**生成产物**）。
/// 否则不是"修了明文落盘"，而是把"存不上"扩到新平台。
/// ⚠️ Android **不在这里**：它走自研 `synhub/keystore` 通道（Kotlin Keystore）。
@visibleForTesting
bool usesPluginSecureStorageFor(TargetPlatform platform) =>
    platform == TargetPlatform.macOS ||
    platform == TargetPlatform.iOS ||
    platform == TargetPlatform.linux ||
    platform == TargetPlatform.windows;

/// [KeystoreSecretKeeper.isSupported] 里**宿主层**那半边的纯函数版。
///
/// 三个入参就是它实际依赖的三样事实，所以宿主测试可以逐项钉：
/// * [isWeb] ⇒ 一律 false（web 上连 `dart:io` 的 `Platform` 都会抛）；
/// * [inFlutterTest] ⇒ 一律 false（给未注册的 channel 发消息在 fake async 下
///   会一直挂着 —— 第 42 轮踩过"整套离线测试卡到 10 分钟超时"）；
/// * `platform == android` ⇒ 走 `synhub/keystore` 通道；
///   其余走插件的那几家见 [usesPluginSecureStorageFor]。
///
/// ⚠️ **能力门（`capabilityGateAllows(secureStorage)`）与这里正交**，
/// 两处都必须是 true 才碰插件 —— 只改一处等于没修（第 293 轮真机取证时
/// `capAllowed=false hostSupports=false` 同时成立，正是这个原因）。
@visibleForTesting
bool secretKeeperHostSupportedFor({
  required TargetPlatform platform,
  required bool isWeb,
  required bool inFlutterTest,
}) {
  if (isWeb) return false;
  if (inFlutterTest) return false;
  return platform == TargetPlatform.android ||
      usesPluginSecureStorageFor(platform);
}
