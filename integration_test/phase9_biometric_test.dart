// Phase 9 真机验收：生物识别解锁。
//
//   flutter test integration_test/phase9_biometric_test.dart -d AXGE022428000622
//
// 真机能自动化的部分：
//   ① 走**真实插件**（local_auth → BiometricPrompt）查询可用性与类型
//      —— 这一步同时验证 `MainActivity` 已换成 `FlutterFragmentActivity`
//      （否则 local_auth 会直接报 no_fragment_activity）；
//   ② 设备不支持时，真实 `authenticate()` 必须**快速返回 false**（不是挂住/抛异常）；
//   ③ 用假验证器在真机上把 UI 链路跑完：设置页开关显隐、锁屏入口、自动验证后解锁；
//   ④ 应用锁关着时生物识别一律不可用。
//
// 真指纹/面容那一次交互需要人按，自动化会挂在系统弹窗上，
// 所以这里不驱动真实 `authenticate`（只在"设备不支持"时调，那条路径无弹窗）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/security/passcode_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/features/security/passcode_screen.dart';
import 'package:synhub/src/features/settings/settings_page.dart';

import '../test/support/chat_harness.dart';

class _FakeBiometric implements BiometricAuthenticator {
  _FakeBiometric({this.available = true, this.result = true});

  bool available;
  bool result;
  int calls = 0;
  String? lastReason;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<BiometricKind> kind() async =>
      available ? BiometricKind.fingerprint : BiometricKind.none;

  @override
  Future<bool> authenticate({required String reason}) async {
    calls++;
    lastReason = reason;
    return result;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ★ 真机 `integration_test` 的"常驻动效"陷阱（第 45 轮定位）：
  //   `FieldBackdrop` 在 `AppEffects.ambientAllowed` 为真时会
  //   `AnimationController.repeat()`（`lib/src/core/ui/field_backdrop.dart:104`），
  //   而 `ambientAllowed = Motion.enabled && !AppEffects.isFlutterTest`
  //   （`lib/src/core/theme/app_tokens.dart:109`）；`isFlutterTest` 只认
  //   `Platform.environment.containsKey('FLUTTER_TEST')`（`:99`）—— 这个环境变量
  //   **只有宿主 `flutter test` 才有，真机 App 进程里永远没有** ⇒ 生产路径的常驻
  //   动效照常在跑 ⇒ 含 `FieldBackdrop` 的页面（设置页就是）上的 `pumpAndSettle()`
  //   永远等不到停帧：默认 10 分钟超时，整目标先被套件看门狗杀掉，日志里连一条
  //   `Expected/Actual` 都看不到。
  //   这里按仓库既有约定（AGENTS §2.0.9「有常驻动画时 pumpAndSettle 不可用」）
  //   显式打开**用户可见的**「减少动效」开关把常驻动效停掉：
  //   不改产品行为、不放宽任何产品断言。
  AppEffects.reducedMotion.value = true;

  testWidgets('Phase 9 真机：生物识别（真实可用性 + 设置页/锁屏链路）', (tester) async {
    // ---------- ① 真实插件查询 ----------
    final real = LocalAuthBiometricAuthenticator();
    final available = await real.isAvailable();
    final kind = await real.kind();
    debugPrint('[p9b] local_auth 可用=$available 类型='
        '${kind == BiometricKind.none ? '无' : kind.label}');
    debugPrint('[p9b] MainActivity=FlutterFragmentActivity（否则这一步会报 '
        'no_fragment_activity）✓');

    // ---------- ② 设备不支持时，真实调用要快速安全失败 ----------
    if (!available) {
      final ok = await real.authenticate(reason: 'flt-p9 探活');
      expect(ok, isFalse, reason: '设备不支持/未录入时必须是 false，不能抛异常');
      debugPrint('[p9b] 设备不支持 → 真实 authenticate 安全返回 false ✓');
    }

    // ---------- ③ 应用锁 + 生物识别的可用性前提 ----------
    final bio = _FakeBiometric();
    final h = await bootChat(moreOverrides: [
      biometricAuthenticatorProvider.overrideWithValue(bio),
    ]);
    final settings = h.container.read(settingsServiceProvider);
    final svc = h.container.read(passcodeServiceProvider);

    expect(await svc.biometricCanUnlock(bio), isFalse);
    debugPrint('[p9b] 应用锁未开 → 生物识别不可用 ✓');

    await svc.setPasscode('2468');
    expect(await svc.biometricCanUnlock(bio), isFalse,
        reason: '口令开了但生物识别开关没开 → 仍不可用');
    await settings.setFingerprintEnabled(true);
    expect(await svc.biometricCanUnlock(bio), isTrue);
    debugPrint('[p9b] 口令 + 生物识别开关都开 → 可用 ✓');

    // 设备不支持时（假验证器也可模拟）→ 不可用
    final off = _FakeBiometric(available: false);
    expect(await svc.biometricCanUnlock(off), isFalse);
    debugPrint('[p9b] 设备不支持 → 不可用 ✓');

    // ---------- ④ 真机上跑设置页：开关显隐与写入 ----------
    Future<void> openSettings() async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(home: SettingsPage()),
      ));
      await tester.pumpAndSettle();
      // 【同步更新】设置页是**懒构建**的长列表：`应用锁` / `生物识别` 这一段在
      // 首屏之下（本机 393×853 逻辑像素），不滚过去它根本不会被 build，
      // `find.text('指纹解锁')` 自然是 0 个。用 scrollUntilVisible 滚到它为止。
      await tester.scrollUntilVisible(
        find.text('指纹解锁'),
        240,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
      await tester.pumpAndSettle();
    }

    await openSettings();
    expect(find.text('指纹解锁'), findsOneWidget,
        reason: '假设备支持 + 应用锁已开 → 必须显示');
    final tile = find.ancestor(
      of: find.text('指纹解锁'),
      matching: find.byType(SwitchListTile),
    );
    // 设置页很长，这一项可能在屏幕外（真机 374×813 上 y≈848）——先滚到可见处，
    // 否则 tap() 会打空（"would not hit test"），后面的断言会莫名其妙地失败。
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    final sw = find.descendant(of: tile, matching: find.byType(Switch));
    await tester.tap(sw, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(await settings.fingerprintEnabled(), isFalse, reason: '关掉了');
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(sw, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(await settings.fingerprintEnabled(), isTrue, reason: '又开回来');
    debugPrint('[p9b] 设置页生物识别开关显隐 + 读写 ✓');

    // ---------- ⑤ 真机上跑锁屏：自动验证 → 锁屏消失 ----------
    h.container.read(passcodeLockProvider.notifier).lockNow();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: const MaterialApp(
        home: PasscodeGate(child: Scaffold(body: Text('聊天内容'))),
      ),
    ));
    await tester.pumpAndSettle();

    expect(bio.calls, greaterThanOrEqualTo(1), reason: '进来要自动起一次验证');
    expect(bio.lastReason, contains('指纹'));
    expect(h.container.read(passcodeLockProvider), isFalse);
    expect(find.text('聊天内容'), findsOneWidget);
    expect(find.text('已锁定'), findsNothing);
    debugPrint('[p9b] 锁屏：自动验证 → 解锁（理由=${bio.lastReason}）✓');

    // ---------- ⑥ 验证失败要退回口令 ----------
    final failing = _FakeBiometric(result: false);
    final h2 = await bootChat(moreOverrides: [
      biometricAuthenticatorProvider.overrideWithValue(failing),
    ]);
    await PasscodeService(h2.container.read(settingsServiceProvider))
        .setPasscode('1357');
    await h2.container.read(settingsServiceProvider).setFingerprintEnabled(true);
    h2.container.read(passcodeLockProvider.notifier).lockNow();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: h2.container,
      child: const MaterialApp(home: PasscodeLockScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('已锁定'), findsOneWidget);
    expect(find.text('用指纹解锁'), findsOneWidget, reason: '失败后入口还在');
    expect(find.textContaining('生物识别未通过'), findsOneWidget);
    for (final d in ['1', '3', '5', '7']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(h2.container.read(passcodeLockProvider), isFalse);
    debugPrint('[p9b] 生物识别失败 → 口令兜底解锁 ✓');

    // 收尾：两个容器都清掉应用锁，别影响后续手测
    await PasscodeService(h.container.read(settingsServiceProvider)).disable();
    await PasscodeService(h2.container.read(settingsServiceProvider)).disable();
    debugPrint('[p9b] 清理完成 ✓');
  });
}
