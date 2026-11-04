// ★ **生物识别解锁的"Mock 平台通道"验证** —— ②聊天 审计行 283。
//
// ## 为什么需要这个文件（规则 B2）
// 行 283 一直卡在 🟠，理由是：
//   > 需先取证（需一台**录了指纹**的设备 + 人工按一次）；
//   > 真实指纹交互从未真机验过
// 用户 2026-09-23 新规 B2 明说：**"真机/真 NAS 无法验证的也一律通过 Mock Server 验证"**。
// `local_auth` 是一个**平台通道**（`plugins.flutter.io/local_auth`），
// 所以这里把**通道本身** mock 掉，驱动**真实的** `LocalAuthBiometricAuthenticator`
// —— 不是拿假实现糊弄（既有 `test/biometric_test.dart` 用的是假实现，
// 真实的那个类**一次都没被跑过**）。
//
// ## 证据链
// * 包内实现：`local_auth_platform_interface-1.1.0/lib/default_method_channel_platform.dart`
//   —— `MethodChannel('plugins.flutter.io/local_auth')`，方法名逐字为
//   `authenticate` / `getAvailableBiometrics` / `isDeviceSupported`；
// * `LocalAuthPlatform._instance = DefaultLocalAuthPlatform()`
//   （`local_auth_platform_interface.dart:25`）⇒ 纯 Dart 测试里默认就是通道实现；
// * `LocalAuthentication.canCheckBiometrics` → `deviceSupportsBiometrics()`
//   → 通道 `getAvailableBiometrics` 非空（`default_method_channel_platform.dart:64-68`）。
//
// ## 这个文件能证明什么 / 不能证明什么
// ✅ 能：真机上**无法自动化**的那几条分支（成功、用户失败、用户取消、
//        无硬件、无录入、通道缺失）在**真实代码路径**上行为正确；
//        `biometricOnly: true` / `sensitiveTransaction: false` **真的**传到了平台层。
// ❌ 不能：证明 `BiometricPrompt` 在我们的 Activity 里**真的弹得出来** ——
//        那是 Android 侧 `BiometricPrompt` 的事，需要真机 + 真人按。
//        **本条不声称已真机验证。**
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/security/passcode_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';

import 'support/chat_harness.dart';

/// 通道名与包内实现逐字一致（见文件头证据链）。
const _channel = MethodChannel('plugins.flutter.io/local_auth');

/// 记录**最近一次** `authenticate` 收到的参数 —— 用来钉住官方对齐的选项。
Map<Object?, Object?>? lastAuthArgs;

/// 安装一个假通道。[enrolled] 是 `getAvailableBiometrics` 的返回。
void mockChannel({
  List<String> enrolled = const [],
  bool deviceSupported = true,
  bool? authResult,
  Object? authThrow,
  bool throwOnQuery = false,
}) {
  lastAuthArgs = null;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        switch (call.method) {
          case 'getAvailableBiometrics':
            if (throwOnQuery) {
              throw PlatformException(code: 'no_activity');
            }
            return enrolled;
          case 'isDeviceSupported':
            if (throwOnQuery) {
              throw PlatformException(code: 'no_activity');
            }
            return deviceSupported;
          case 'authenticate':
            lastAuthArgs = (call.arguments as Map?)?.cast<Object?, Object?>();
            if (authThrow != null) throw authThrow;
            return authResult;
          case 'stopAuthentication':
            return true;
        }
        return null;
      });
}

void clearChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => mockChannel());
  tearDown(clearChannel);

  group('BN-1. isAvailable —— 真实实现走通道', () {
    test('★ 三关都过（有硬件 + 设备支持 + 已录入）⇒ true', () async {
      mockChannel(enrolled: ['fingerprint']);
      expect(await LocalAuthBiometricAuthenticator().isAvailable(), isTrue);
    });

    test('★ 无录入（空列表）⇒ false（这是真机上"没设指纹"的分支）', () async {
      mockChannel(enrolled: []);
      expect(await LocalAuthBiometricAuthenticator().isAvailable(), isFalse);
    });

    test('★ 设备不支持 ⇒ false（即使有录入）', () async {
      mockChannel(enrolled: ['fingerprint'], deviceSupported: false);
      expect(await LocalAuthBiometricAuthenticator().isAvailable(), isFalse);
    });

    test('★ 通道抛异常 ⇒ false 且**不把异常抛给调用方**（不炸 UI）', () async {
      mockChannel(throwOnQuery: true);
      expect(await LocalAuthBiometricAuthenticator().isAvailable(), isFalse);
    });

    test('★ 通道完全缺失（MissingPluginException）⇒ false', () async {
      clearChannel();
      expect(await LocalAuthBiometricAuthenticator().isAvailable(), isFalse);
    });
  });

  group('BN-2. kind —— 类型映射', () {
    test('face 优先', () async {
      mockChannel(enrolled: ['fingerprint', 'face']);
      expect(
        await LocalAuthBiometricAuthenticator().kind(),
        BiometricKind.face,
      );
    });

    test('fingerprint', () async {
      mockChannel(enrolled: ['fingerprint']);
      expect(
        await LocalAuthBiometricAuthenticator().kind(),
        BiometricKind.fingerprint,
      );
    });

    test('其他（iris 等）⇒ other', () async {
      mockChannel(enrolled: ['iris']);
      expect(
        await LocalAuthBiometricAuthenticator().kind(),
        BiometricKind.other,
      );
    });

    test('空 ⇒ none', () async {
      mockChannel(enrolled: []);
      expect(
        await LocalAuthBiometricAuthenticator().kind(),
        BiometricKind.none,
      );
    });

    test('★ 通道抛异常 ⇒ none（不炸）', () async {
      mockChannel(throwOnQuery: true);
      expect(
        await LocalAuthBiometricAuthenticator().kind(),
        BiometricKind.none,
      );
    });
  });

  group('BN-3. authenticate —— 成功 / 失败 / 取消', () {
    test('★ 平台回 true ⇒ 通过', () async {
      mockChannel(enrolled: ['fingerprint'], authResult: true);
      expect(
        await LocalAuthBiometricAuthenticator().authenticate(reason: '解锁'),
        isTrue,
      );
    });

    test('★ 平台回 false（指纹不匹配）⇒ false', () async {
      mockChannel(enrolled: ['fingerprint'], authResult: false);
      expect(
        await LocalAuthBiometricAuthenticator().authenticate(reason: '解锁'),
        isFalse,
      );
    });

    test('★ 用户取消（PlatformException）⇒ false，不抛给调用方', () async {
      mockChannel(
        enrolled: ['fingerprint'],
        authThrow: PlatformException(code: 'NotAvailable', message: 'cancel'),
      );
      expect(
        await LocalAuthBiometricAuthenticator().authenticate(reason: '解锁'),
        isFalse,
      );
    });

    test('★ 连续失败被锁定（LockedOut）⇒ false', () async {
      mockChannel(
        enrolled: ['fingerprint'],
        authThrow: PlatformException(code: 'LockedOut'),
      );
      expect(
        await LocalAuthBiometricAuthenticator().authenticate(reason: '解锁'),
        isFalse,
      );
    });

    test(
      '★ 传给平台的选项与官方对齐（`biometricOnly:true` + `sensitiveTransaction:false`）',
      () async {
        mockChannel(enrolled: ['fingerprint'], authResult: true);
        await LocalAuthBiometricAuthenticator().authenticate(reason: '解锁');
        expect(lastAuthArgs, isNotNull, reason: '必须真的走了通道');
        // 官方原版 `setConfirmationRequired(false)` ⇒ 指纹一过直接通过
        expect('${lastAuthArgs!['sensitiveTransaction']}', 'false');
        // 只走生物识别，不退回系统 PIN/图案（我们有自己的口令）
        expect('${lastAuthArgs!['biometricOnly']}', 'true');
        // reason 透传（`localizedReason`）
        expect('${lastAuthArgs!['localizedReason']}', '解锁');
      },
    );

    test('★ 空 reason ⇒ 被本类自己的 try/catch 吃掉，回 false（不炸 UI）', () async {
      mockChannel(enrolled: ['fingerprint'], authResult: true);
      // 包里的 `default_method_channel_platform.dart:24` 有
      // `assert(localizedReason.isNotEmpty)`。
      //
      // ⚠️ **我原本假设这个 assert 会抛出来，被自己的实验推翻了**：
      // `biometric_auth.dart:84-88` 用自己的 try/catch 把一切都兜住并回 false。
      // 那是**正确的防御行为**（宁可回 false 让口令键盘兜底，也不把
      // AssertionError 抛进 UI 线程）。所以这里钉的是**真实行为**。
      expect(
        await LocalAuthBiometricAuthenticator().authenticate(reason: ''),
        isFalse,
      );
    });
  });

  group('BN-5. ★ 端到端：真实认证器 + PasscodeService（这才是用户走的那条路）', () {
    /// 建一个 harness：装好口令、打开生物识别开关。
    Future<(PasscodeService, LocalAuthBiometricAuthenticator)> setup({
      List<String> enrolled = const ['fingerprint'],
      bool? authResult = true,
    }) async {
      mockChannel(enrolled: enrolled, authResult: authResult);
      final h = await bootChat();
      final settings = h.container.read(settingsServiceProvider);
      final svc = PasscodeService(settings);
      await svc.setPasscode('1234'); // 应用锁打开
      await settings.setFingerprintEnabled(true); // 用户打开生物识别
      return (svc, LocalAuthBiometricAuthenticator());
    }

    test('★ 全链路：开关开 + 设备有指纹 + 验证成功 ⇒ 解锁', () async {
      final (svc, bio) = await setup();
      expect(await svc.biometricCanUnlock(bio), isTrue);
      svc.lockNow();
      expect(svc.locked, isTrue);
      expect(await svc.unlockWithBiometric(bio), isTrue);
      expect(svc.locked, isFalse, reason: '成功必须真的解锁');
    });

    test('★ 验证失败 ⇒ 保持锁定（由口令键盘兜底）', () async {
      final (svc, bio) = await setup(authResult: false);
      svc.lockNow();
      expect(await svc.unlockWithBiometric(bio), isFalse);
      expect(svc.locked, isTrue, reason: '失败**不能**解锁');
    });

    test('★ 设备没录指纹 ⇒ 连弹都不弹（biometricCanUnlock 先行拦截）', () async {
      final (svc, bio) = await setup(enrolled: const []);
      expect(await svc.biometricCanUnlock(bio), isFalse);
      svc.lockNow();
      expect(await svc.unlockWithBiometric(bio), isFalse);
      expect(svc.locked, isTrue);
    });

    test('★ 用户没打开生物识别开关 ⇒ 不可用（即使设备支持）', () async {
      mockChannel(enrolled: ['fingerprint'], authResult: true);
      final h = await bootChat();
      final settings = h.container.read(settingsServiceProvider);
      final svc = PasscodeService(settings);
      await svc.setPasscode('1234');
      // 刻意**不**开 fingerprint 开关
      expect(
        await svc.biometricCanUnlock(LocalAuthBiometricAuthenticator()),
        isFalse,
      );
    });

    test('★ 传下去的 reason 带上了识别类型标签（用户看到的是"指纹"/"面容"）', () async {
      final (svc, bio) = await setup(enrolled: ['face'], authResult: true);
      svc.lockNow();
      await svc.unlockWithBiometric(bio);
      expect(lastAuthArgs, isNotNull);
      final reason = '${lastAuthArgs!['localizedReason']}';
      expect(reason, isNotEmpty);
      // 面容设备上 reason 应当提到"面容"（`BiometricKind.face.label`）
      expect(
        reason.contains('面容') || reason.contains('Face'),
        isTrue,
        reason: '实际 reason = "$reason"',
      );
    });
  });
}
