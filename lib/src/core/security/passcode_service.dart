// Phase 9：应用锁（4 位数字口令）。
//
// 原版（`sylibx/passcode/...`）：
//   * 4 位数字口令，`passcode_enable` / `passcode` / `passcode_change` /
//     `passcode_expiration`（默认 `ALWAYS`）/ `passcode_fingerprint_enable`；
//   * 口令本体用 Android Keystore 加密后存 SharedPreferences；
//   * 锁屏判定靠"退到后台的时间戳"：`mLastBackgroundTimestamp` +
//     `shouldShowPassCode()`，宽限期由 `passcode_expiration` 决定
//     （Immediately / 1 / 2 / 5 / 10 / 30 分钟）。
//
// 我们：口令**不存明文也不存可逆密文**，只存 PBKDF2-HMAC-SHA256 的散列 + 随机盐
// （原版是"加密存储"，能解回明文；散列更严，代价是没法"显示当前口令"——
// 原版也没有这个功能）。宽限期逻辑照搬原版语义。
//
// ⚠️ 这跟 E2EE 的"加密口令"（`flt-e2ee-pass` 那种，用来解私钥）**完全是两回事**，
// 不要复用命名，也不要把两套口令合并。
import 'dart:convert';
import 'dart:math';

import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/data_text.dart';
import '../i18n/l10n.dart';
import '../provider_retry.dart';
import '../settings/app_settings.dart';
import 'biometric_auth.dart';

/// 口令长度（原版固定 4 位）
const int kPasscodeLength = 4;

/// PBKDF2 迭代次数（移动端 1 万次约几十毫秒，足够挡住 4 位数字的暴力枚举）
const int kPasscodeIterations = 10000;

class PasscodeService {
  PasscodeService(this._settings, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final SettingsService _settings;
  final DateTime Function() _now;

  /// 退到后台的时刻（null = 一直在前台）
  DateTime? _backgroundAt;

  /// 上次通过验证的时刻
  DateTime? _unlockedAt;

  bool _locked = false;

  bool get locked => _locked;

  /// 启动时调：开了应用锁就从"锁定"开始（原版冷启动也要输）
  Future<void> init() async {
    _locked = await _settings.passcodeEnabled();
    _unlockedAt = null;
  }

  /// 退到后台
  void onPaused() {
    _backgroundAt = _now();
  }

  /// 回到前台：超过宽限期就重新锁上
  Future<void> onResumed() async {
    if (!await _settings.passcodeEnabled()) {
      _locked = false;
      return;
    }
    final at = _backgroundAt;
    _backgroundAt = null;
    if (at == null) return;
    // ★ DA74（r416）：**系统弹框也会让我们走 pause/resume** ——
    //   `androidx.biometric` 的 BiometricPrompt 盖在本 App 上面时，Activity 会 onPause；
    //   指纹一过弹框收起，Activity 又 onResume。若此时按"退过后台"重锁，就会变成
    //   死循环：弹框 → pause → 指纹通过 → resume → **立刻重锁** → 又自动弹框
    //   （真机实测 80 秒内弹 12 次、指纹 `accept` 计数从 4 涨到 9 却始终进不去）。
    //   判据：**在"退到后台"之后**才通过的验证（生物识别 / 口令）说明用户刚验过身份，
    //   不许再把他锁回去；真正的"人离开了再回来"里 `_unlockedAt` 必然早于 `at`，照旧重锁。
    final unlockedAt = _unlockedAt;
    if (unlockedAt != null && unlockedAt.isAfter(at)) return;
    final grace = (await _settings.passcodeExpiration()).grace;
    if (grace == Duration.zero || _now().difference(at) > grace) {
      _locked = true;
      _unlockedAt = null;
    }
  }

  /// 验证并按需解锁
  Future<bool> unlock(String code) async {
    if (!await verify(code)) return false;
    _locked = false;
    _unlockedAt = _now();
    return true;
  }

  /// 仅校验口令（不改锁状态）—— 设置页改/关口令时用
  Future<bool> verify(String code) async {
    final hash = await _settings.passcodeHash();
    final salt = await _settings.passcodeSalt();
    if (hash == null || hash.isEmpty || salt == null || salt.isEmpty) {
      return false;
    }
    return _constantTimeEquals(hash, _hash(code, salt));
  }

  /// 设置/修改口令（会同时打开应用锁）
  Future<void> setPasscode(String code) async {
    if (!isValidFormat(code)) {
      throw ArgumentError('口令必须是 $kPasscodeLength 位数字');
    }
    final salt = _randomSalt();
    await _settings.setPasscodeHash(_hash(code, salt), salt);
    await _settings.setPasscodeEnabled(true);
    if ((await _settings.passcodeExpiration()) == PasscodeExpiration.always) {
      await _settings.setPasscodeExpiration(PasscodeExpiration.always);
    }
  }

  /// 关闭应用锁（清掉口令与生物识别开关）
  Future<void> disable() async {
    await _settings.clearPasscode();
    _locked = false;
  }

  /// 能不能用生物识别解锁：应用锁开着 + 用户开了生物识别 + 设备真的支持
  Future<bool> biometricCanUnlock(BiometricAuthenticator auth) async {
    if (!await _settings.passcodeEnabled()) return false;
    if (!await _settings.fingerprintEnabled()) return false;
    return auth.isAvailable();
  }

  /// 用生物识别解锁（成功即解锁；失败一律返回 false，由口令键盘兜底）
  Future<bool> unlockWithBiometric(BiometricAuthenticator auth) async {
    if (!await biometricCanUnlock(auth)) return false;
    final kind = await auth.kind();
    final label = kind == BiometricKind.none
        ? dataText('passcodeBiometric', '生物识别')
        : kind.label;
    final t = platformText();
    final ok = await auth.authenticate(
      reason: t.unlockReason(label, platformAppName()),
    );
    if (!ok) return false;
    _locked = false;
    _unlockedAt = _now();
    return true;
  }

  /// 手动上锁（设置页"立即锁定"用）
  void lockNow() {
    _locked = true;
    _unlockedAt = null;
  }

  DateTime? get unlockedAt => _unlockedAt;

  static bool isValidFormat(String code) =>
      code.length == kPasscodeLength && RegExp(r'^\d+$').hasMatch(code);

  // ------------------------------------------------------------ 内部

  static String _hash(String code, String saltB64) {
    final salt = base64Decode(saltB64);
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, kPasscodeIterations, 32));
    final out = derivator.process(utf8.encode(code));
    return base64Encode(out);
  }

  static String _randomSalt() {
    final rnd = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
  }

  /// 定长比较（避免按字节提前返回）
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

// ---------------------------------------------------------------- providers

final passcodeServiceProvider = Provider<PasscodeService>(
  (ref) => PasscodeService(ref.watch(settingsServiceProvider)),
);

/// 生物识别解锁是否可用（设置页与锁屏都用它决定要不要显示入口）
final biometricUnlockAvailableProvider = FutureProvider<bool>((ref) async {
  final svc = ref.watch(passcodeServiceProvider);
  return svc.biometricCanUnlock(ref.watch(biometricAuthenticatorProvider));
}, retry: noRetry);

/// 锁 / 未锁（界面只关心这个）
final passcodeLockProvider = NotifierProvider<PasscodeLockNotifier, bool>(
  PasscodeLockNotifier.new,
);

class PasscodeLockNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 冷启动：按设置决定是否直接锁上
  Future<void> init() async {
    final svc = ref.read(passcodeServiceProvider);
    await svc.init();
    if (ref.mounted) state = svc.locked;
  }

  void onPaused() => ref.read(passcodeServiceProvider).onPaused();

  Future<void> onResumed() async {
    final svc = ref.read(passcodeServiceProvider);
    await svc.onResumed();
    if (ref.mounted) state = svc.locked;
  }

  /// 锁屏页验证通过后调用（服务层已经改过锁状态）
  void markUnlocked() {
    ref.read(passcodeServiceProvider);
    state = false;
  }

  void lockNow() {
    ref.read(passcodeServiceProvider).lockNow();
    state = true;
  }

  /// 设置里关掉应用锁后同步
  void markDisabled() => state = false;

  /// 生物识别解锁成功后调用
  void markBiometricUnlocked() => state = false;
}
