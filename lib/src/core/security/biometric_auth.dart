// Phase 9：生物识别（指纹 / 面容）解锁。
//
// 原版（`sylibx/passcode`）：
//   * 偏好 `passcode_fingerprint_enable`（`PassCodeSettings.KEY_FINGERPRINT_ENABLE`）；
//   * 用 `androidx.biometric.BiometricPrompt` 起验证，
//     PromptInfo 标题 = `passcode_biometric_unlock`，取消键 = `passcode_use_password`，
//     `setConfirmationRequired(false)`（指纹识别成功就直接通过，不再点确认）；
//   * 设置页只在 **应用锁已开 且 设备支持生物识别** 时才显示这一项
//     （`PassCodePreferenceFragment.setFingerprintPreferences`），
//     且开启应用锁后会**主动弹框建议**开启生物识别（`promoteBiometricUnlock`）。
//
// 我们：`local_auth` 是对 `BiometricPrompt` 的封装，语义一致。
// ⚠️ 生物识别只是**便捷解锁**，口令永远是兜底 —— 验证失败/取消都退回口令键盘。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../i18n/data_text.dart';

/// 设备上可用的生物识别类型（只区分我们关心的三类）
enum BiometricKind { none, fingerprint, face, other }

extension BiometricKindLabel on BiometricKind {
  /// 生物识别类型文案（**中文回落**，走 dataText；界面也可用 `AppText` 同名 key）
  String get label => switch (this) {
    BiometricKind.fingerprint => dataText('passcodeFingerprint', '指纹'),
    BiometricKind.face => dataText('passcodeFace', '面容'),
    BiometricKind.other => dataText('passcodeBiometric', '生物识别'),
    BiometricKind.none => '',
  };
}

/// 抽象出来是为了能在离线测试里注入假实现（`local_auth` 是平台通道）
abstract interface class BiometricAuthenticator {
  /// 硬件支持且**已录入**（原版的 `isSupportBiometric()`）
  Future<bool> isAvailable();

  Future<BiometricKind> kind();

  /// 起一次验证；用户取消/失败都返回 false（不抛异常）
  Future<bool> authenticate({required String reason});
}

class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      // canCheckBiometrics：有硬件；getAvailableBiometrics：且有已录入的
      if (!await _auth.canCheckBiometrics) return false;
      if (!await _auth.isDeviceSupported()) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (e) {
      debugPrint('[bio] 查询生物识别失败：$e');
      return false;
    }
  }

  @override
  Future<BiometricKind> kind() async {
    try {
      final list = await _auth.getAvailableBiometrics();
      if (list.contains(BiometricType.face)) return BiometricKind.face;
      if (list.contains(BiometricType.fingerprint)) {
        return BiometricKind.fingerprint;
      }
      if (list.isNotEmpty) return BiometricKind.other;
    } catch (_) {}
    return BiometricKind.none;
  }

  @override
  Future<bool> authenticate({required String reason}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // 原版 setConfirmationRequired(false)：指纹一过就直接通过
        sensitiveTransaction: false,
        // 只走生物识别，不要退回系统 PIN/图案（我们有自己的口令）
        biometricOnly: true,
        persistAcrossBackgrounding: false,
      );
    } catch (e) {
      // 用户取消、锁定、硬件错误都走这里 —— 退回口令键盘即可
      debugPrint('[bio] 验证未通过：$e');
      return false;
    }
  }
}

/// 未被 App 覆盖时用一个"永远不可用"的实现（保证测试/后台不会真弹系统框）
class UnavailableBiometricAuthenticator implements BiometricAuthenticator {
  const UnavailableBiometricAuthenticator();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<BiometricKind> kind() async => BiometricKind.none;

  @override
  Future<bool> authenticate({required String reason}) async => false;
}

final biometricAuthenticatorProvider = Provider<BiometricAuthenticator>(
  (ref) => const UnavailableBiometricAuthenticator(),
);
