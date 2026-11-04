// 本仓**唯一**的 `FlutterSecureStorage` 构造点 —— 第 328 轮补（D29/D30）。
//
// ## D29：为什么必须收敛到一处（这是一条**真缺陷**的修法，不是洁癖）
// `flutter_secure_storage` 11.2.0 的 `MacOsOptions.usesDataProtectionKeychain`
// **默认是 `true`**（见 pub-cache 的 `lib/options/macos_options.dart:24`），
// 而 macOS 上这个开关 = `kSecUseDataProtectionKeychain` **数据保护钥匙串** ——
// 它要求 App **有 `keychain-access-groups` 这一族的 entitlement**。
// 本仓 macOS 构建是 **ad-hoc 签名**（没有 team ID）⇒ 每一次写/删都抛
//
//   PlatformException(-34018, "A required entitlement is not present.")
//
// 而**读**返回 null ⇒ 表现是"**静默存不上**"（写失败被各家 store 的
// `catch (_)` 吞掉），比崩溃更难查。r328 的探针读数（真 App 进程里）：
//
//   `[probe:plugin-default] write FAILED: … Code: -34018 …` / `read → null`
//   `[probe:appSecureStorage] write OK / read → hello-r328 / delete OK`
//   （原文 → `docs/evidence-r328/README.md` §4.5）
//
// 改成 `usesDataProtectionKeychain: false` 之后走**传统登录钥匙串**
// （file-based login keychain）：本地签名也能用，**不需要**任何 entitlement。
//
// ## D30：**登录钥匙串会弹授权框，会把 App 挂死** —— 所以必须加闸门
// 第 15 次走查实测：`ctl.connect()` 卡死 5 分钟直到 "did not complete"，
// Mock **一条请求都没收到**。`sample <pid>` 的原文（`docs/evidence-r328/`）：
//
//   Thread_7770664  DispatchQueue_238: flutter_secure_storage_service (serial)
//     FlutterSecureStorageDarwinPlugin.read
//       FlutterSecureStorage.read(params:)   FlutterSecureStorage.swift:574
//         SecItemCopyMatching → SecKeychainItemCopyContent   ← **停在这里**
//
// 即：**读别人（上一个构建）写的条目**时，macOS 弹
// "SynHub 想使用您钥匙串中的机密信息" 并**阻塞**那次调用（`SecurityAgent`
// 进程在位）。ad-hoc 签名**每次构建签名都变** ⇒ ACL 永远不匹配 ⇒
// 每次重编都可能弹。**弹框要人点**，无人值守/自动化下就是无限挂起。
// ⇒ 本文件给每一次 read/write/delete 套 `SecureStorageGate`：
//   * 单次等待超过 [SecureStorageGate.timeout]（默认 45 s，够人点一下）；
//   * 超时后进入 [SecureStorageGate.cooldown] 熔断窗口（默认 10 min），
//     窗口内的调用**立即**失败 —— 不再反复白等。
//   * 失败是**显式的** `SecureStorageUnavailable`（既不是"没这条"也不是
//     "空值"），调用方的 `catch (_)` 行为与 r328 之前（-34018）一致，
//     但**再也不会把 App 挂住**。
//
// ## 纪律
// * `lib/` 里除本文件外**不许**再出现 `FlutterSecureStorage` 的**构造**；
//   守卫 `test/app_secure_storage_test.dart` ① 扫全仓（并**反向验证**过：
//   把某个调用点改回去 ⇒ 红）。
// * 别的平台选项保持插件默认（Android 用 `AndroidOptions` 的
//   `encryptedSharedPreferences`；Linux libsecret；Windows DPAPI 文件）。
library;

import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'debug_secret_file.dart';
import 'linux_keyring_gate_state.dart';

/// 钥匙串**等不到授权/被熔断**（★ 与"钥匙串里没有这条"是两件事）。
///
/// 各家 store 原本就会 `catch (_)` 把它当成"取值失败"，语义与 r328 之前
/// 的 `-34018` 一致；区别是**不再无限等待**。
class SecureStorageUnavailable implements Exception {
  const SecureStorageUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'SecureStorageUnavailable($reason)';
}

/// 超时 + 熔断闸门。
///
/// 独立成类是为了**可单测**（`test/app_secure_storage_test.dart` ④–⑦ 直接
/// 拿它跑 `Completer` 永不完成的 future，不需要真钥匙串、也不需要真弹框）。
class SecureStorageGate {
  SecureStorageGate({
    this.timeout = const Duration(seconds: 45),
    this.cooldown = const Duration(minutes: 10),
  });

  /// 单次操作最多等多久（**给人留够点弹框的时间**，不是性能预算）。
  final Duration timeout;

  /// 第一次超时之后，多久之内**不再等**（直接失败）。
  final Duration cooldown;

  DateTime? _blockedUntil;

  /// 现在是否处于熔断窗口（诊断/用例用）。
  bool get blocked =>
      _blockedUntil != null && DateTime.now().isBefore(_blockedUntil!);

  /// 跑一次钥匙串操作，带超时与熔断。
  ///
  /// ★ 这里**不用** `op().timeout(d)`：那会在当前 zone 里建一个定时器 ——
  /// 部件测试跑在 `fake_async` 的 zone 里，平台调用在测试环境**本来就不会完成**
  /// （没有插件实现），于是那个定时器成了 "pending timer"，
  /// 测试框架在收尾时直接判红：**实测 68 条用例红在
  /// "A Timer is still pending even after the widget tree was disposed"**。
  /// 改成在 **`Zone.root`** 里建定时器：
  /// * 生产的 zone 本来就是 root ⇒ 行为一模一样；
  /// * fake_async **统计不到**它 ⇒ 不再污染部件测试；
  /// * 手动 `cancel()` 保证"操作一有结果就不留定时器"。
  Future<T> run<T>(Future<T> Function() op) {
    if (blocked) {
      return Future<T>.error(
        SecureStorageUnavailable('钥匙串未授权，熔断至 $_blockedUntil'),
      );
    }
    final done = Completer<T>();
    final timer = Zone.root.createTimer(timeout, () {
      // 底下的平台调用**仍在等**（弹框还在屏上）；我们只是不再等它。
      _blockedUntil = DateTime.now().add(cooldown);
      if (!done.isCompleted) {
        done.completeError(
          SecureStorageUnavailable('等待钥匙串授权超时（${timeout.inSeconds}s）'),
        );
      }
    });
    op().then(
      (v) {
        timer.cancel();
        if (!done.isCompleted) done.complete(v);
      },
      onError: (Object e, StackTrace st) {
        timer.cancel();
        if (!done.isCompleted) done.completeError(e, st);
      },
    );
    // ★ 兜一层"没人 await"的情形：测试里那个 45 s 的 root-zone 定时器可能在
    //   用例结束**之后**才到点，此时 `done.future` 已经没人听 ⇒ `completeError`
    //   会变成 **unhandled async error**（可能把后面某条用例弄红）。
    //   挂一个"吃掉错误"的监听：对真正的调用方没有任何影响（它 await 的还是
    //   原来那个 future，错误照收），只是让 future 被视为"已处理"。
    unawaited(done.future.then((_) {}, onError: (Object _, StackTrace _) {}));
    return done.future;
  }
}

/// 生产用存储实例（macOS 关掉"数据保护钥匙串" + 每次操作过闸门）。
///
/// 传参只为单测注入不同选项/闸门；生产调用点一律 `appSecureStorage()`。
FlutterSecureStorage appSecureStorage({
  AndroidOptions? android,
  IOSOptions? ios,
  MacOsOptions? macos,
  LinuxOptions? linux,
  WindowsOptions? windows,
  WebOptions? web,
  SecureStorageGate? gate,
}) => _GuardedSecureStorage(
  aOptions: android ?? const AndroidOptions(),
  iOptions: ios ?? const IOSOptions(),
  // ★ 唯一与插件默认不同的地方：见文件头（-34018 / 无 team 的 ad-hoc 签名）
  mOptions: macos ?? const MacOsOptions(usesDataProtectionKeychain: false),
  lOptions: linux ?? const LinuxOptions(),
  wOptions: windows ?? const WindowsOptions(),
  webOptions: web ?? const WebOptions(),
  gate: gate,
);

/// 把插件实例的 `read/write/delete` 全部套上 [SecureStorageGate]。
///
/// 只覆盖本仓**实际用到**的三个方法（`grep '_storage\\.|_secure\\.'` 实测
/// 只有 `read` / `write` / `delete`）—— 覆盖没用到的方法只会增加与插件
/// 版本耦合的面。
class _GuardedSecureStorage extends FlutterSecureStorage {
  _GuardedSecureStorage({
    required super.aOptions,
    required super.iOptions,
    required super.mOptions,
    required super.lOptions,
    required super.wOptions,
    required super.webOptions,
    SecureStorageGate? gate,
  }) : _gate = gate ?? SecureStorageGate();

  final SecureStorageGate _gate;

  // ★ 第 665 轮：macOS **Debug** 档改走 App 沙箱里的 0600 文件 ——
  //   ad-hoc 签名的 macOS 构建**每次签名都变**，登录钥匙串的 ACL 因此永远不认识
  //   新构建，每次冷启动都弹「SynHub 想使用您钥匙串中的机密信息」并阻塞读取
  //   （用户当面问"为啥老提示我输入密码"）。Debug 档不碰钥匙串就不再弹框；
  //   Release/Profile 与其它平台**行为不变**。
  bool get _fileMode => debugSecretFileMode();

  /// ★ r701 · `DA340`：Linux 上钥匙串不可用/集合锁定时，**一次都不碰插件**。
  ///
  /// 语义与"钥匙串里没有这条"一致（各家 store 本来就 `catch (_)`）：
  /// * `read` ⇒ `null`；`write`/`delete` ⇒ 无声跳过。
  /// 这样即使某个调用点忘了检查，也不会弹出「Unlock Login Keyring」把主循环卡死。
  bool get _keyringBlocked => linuxKeyringBlocked;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (_keyringBlocked) return Future<String?>.value();
    if (_fileMode) return debugSecretFileRead(key);
    return _gate.run(
      () => super.read(
        key: key,
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions,
      ),
    );
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (_keyringBlocked) return Future<void>.value();
    if (_fileMode) {
      if (value == null) return debugSecretFileDelete(key);
      return debugSecretFileWrite(key, value);
    }
    return _gate.run(
      () => super.write(
        key: key,
        value: value,
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions,
      ),
    );
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (_keyringBlocked) return Future<void>.value();
    if (_fileMode) return debugSecretFileDelete(key);
    return _gate.run(
      () => super.delete(
        key: key,
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions,
      ),
    );
  }
}
