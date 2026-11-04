// Phase 9：生物识别解锁离线验证。
//
// 覆盖：可用性判定的三个前提（应用锁开 / 用户开生物识别 / 设备支持）、
// 验证成功解锁、失败/取消退回口令、锁屏入口与自动弹一次、
// 设置页只在可用时显示开关、开启应用锁后的"建议启用"弹框。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/security/passcode_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/features/security/passcode_screen.dart';
import 'package:synhub/src/features/settings/settings_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';
import 'support/switch_rows.dart';

/// 可控的假生物识别
class FakeBiometric implements BiometricAuthenticator {
  FakeBiometric({
    this.available = true,
    this.kindValue = BiometricKind.fingerprint,
    this.result = true,
  });

  bool available;
  BiometricKind kindValue;
  bool result;

  int calls = 0;
  String? lastReason;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<BiometricKind> kind() async => kindValue;

  @override
  Future<bool> authenticate({required String reason}) async {
    calls++;
    lastReason = reason;
    return result;
  }
}

/// ★ DA74 用：把"弹框在等指纹"这件事做成可控闸门，好把 pause/成功/resume 的**次序**钉住
class _GatedBiometric extends FakeBiometric {
  final gate = Completer<bool>();

  @override
  Future<bool> authenticate({required String reason}) async {
    calls++;
    lastReason = reason;
    return gate.future;
  }
}

Future<ChatHarness> boot(FakeBiometric bio, {bool passcode = true}) async {
  final h = await bootChat(
    moreOverrides: [biometricAuthenticatorProvider.overrideWithValue(bio)],
  );
  if (passcode) {
    await PasscodeService(
      h.container.read(settingsServiceProvider),
    ).setPasscode('1234');
  }
  return h;
}

void main() {
  group('可用性判定', () {
    test('应用锁没开 → 不可用（即使设备支持）', () async {
      final h = await boot(FakeBiometric(), passcode: false);
      final svc = h.container.read(passcodeServiceProvider);
      expect(await svc.biometricCanUnlock(FakeBiometric()), isFalse);
    });

    test('设备不支持 → 不可用', () async {
      final h = await boot(FakeBiometric(available: false));
      final svc = h.container.read(passcodeServiceProvider);
      expect(
        await svc.biometricCanUnlock(FakeBiometric(available: false)),
        isFalse,
      );
    });

    test('用户没开生物识别开关 → 不可用', () async {
      final h = await boot(FakeBiometric());
      final svc = h.container.read(passcodeServiceProvider);
      expect(
        await svc.biometricCanUnlock(FakeBiometric()),
        isFalse,
        reason: '默认 passcode_fingerprint_enable=false',
      );
    });

    test('三个条件都满足 → 可用', () async {
      final h = await boot(FakeBiometric());
      await h.container
          .read(settingsServiceProvider)
          .setFingerprintEnabled(true);
      final svc = h.container.read(passcodeServiceProvider);
      expect(await svc.biometricCanUnlock(FakeBiometric()), isTrue);
    });

    test('provider 默认实现是"不可用"（离线测试/后台不会碰平台通道）', () async {
      final h = await bootChat();
      final auth = h.container.read(biometricAuthenticatorProvider);
      expect(await auth.isAvailable(), isFalse);
      expect(await auth.authenticate(reason: 'x'), isFalse);
      expect(await auth.kind(), BiometricKind.none);
    });
  });

  group('解锁行为', () {
    test('验证通过 → 解锁，且理由里带类型', () async {
      final h = await boot(FakeBiometric());
      await h.container
          .read(settingsServiceProvider)
          .setFingerprintEnabled(true);
      final bio = FakeBiometric();
      final svc = h.container.read(passcodeServiceProvider);
      await svc.init();
      expect(svc.locked, isTrue);

      expect(await svc.unlockWithBiometric(bio), isTrue);
      expect(svc.locked, isFalse);
      expect(bio.calls, 1);
      expect(bio.lastReason, contains('指纹'));
    });

    test('验证失败/取消 → 仍然锁着，且不改口令状态', () async {
      final h = await boot(FakeBiometric());
      await h.container
          .read(settingsServiceProvider)
          .setFingerprintEnabled(true);
      final svc = h.container.read(passcodeServiceProvider);
      await svc.init();

      expect(
        await svc.unlockWithBiometric(FakeBiometric(result: false)),
        isFalse,
      );
      expect(svc.locked, isTrue);
      // 口令仍然能解锁（兜底）
      expect(await svc.unlock('1234'), isTrue);
    });

    test('没开生物识别时不会去起验证（calls 保持 0）', () async {
      final h = await boot(FakeBiometric());
      final bio = FakeBiometric();
      final svc = h.container.read(passcodeServiceProvider);
      expect(await svc.unlockWithBiometric(bio), isFalse);
      expect(bio.calls, 0);
    });

    test('面部设备给"面容"标签', () async {
      final h = await boot(FakeBiometric(kindValue: BiometricKind.face));
      await h.container
          .read(settingsServiceProvider)
          .setFingerprintEnabled(true);
      final bio = FakeBiometric(kindValue: BiometricKind.face);
      await h.container.read(passcodeServiceProvider).unlockWithBiometric(bio);
      expect(bio.lastReason, contains('面容'));
    });
  });

  group('锁屏入口', () {
    Future<void> showLock(WidgetTester tester, ChatHarness h) async {
      h.container.read(passcodeLockProvider.notifier).lockNow();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: PasscodeLockScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('可用时显示入口，并自动起一次验证 → 整个锁屏消失', (tester) async {
      final bio = FakeBiometric();
      final h = await boot(bio);
      await h.container
          .read(settingsServiceProvider)
          .setFingerprintEnabled(true);
      h.container.read(passcodeLockProvider.notifier).lockNow();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: PasscodeGate(child: Scaffold(body: Text('聊天内容'))),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 验证一通过锁屏就整个消失，所以这里断言的是"解锁结果"，不是入口还在
      expect(bio.calls, greaterThanOrEqualTo(1), reason: '进来应自动弹一次');
      expect(
        h.container.read(passcodeLockProvider),
        isFalse,
        reason: '验证通过就解锁',
      );
      expect(find.text('已锁定'), findsNothing);
      expect(find.text('聊天内容'), findsOneWidget);
    });

    testWidgets('验证失败时留在锁屏，提示后仍可输口令', (tester) async {
      final bio = FakeBiometric(result: false);
      final h = await boot(bio);
      await h.container
          .read(settingsServiceProvider)
          .setFingerprintEnabled(true);
      await showLock(tester, h);

      expect(find.text('已锁定'), findsOneWidget);
      expect(find.text('用指纹解锁'), findsOneWidget, reason: '失败后入口还在，可重试');
      expect(find.textContaining('生物识别未通过'), findsOneWidget);

      // 手动再点一次（不该重复触发？——用户主动点是允许的，这里验证不炸）
      await tester.tap(find.text('用指纹解锁'));
      await tester.pumpAndSettle();

      // 口令仍然可用
      for (final d in ['1', '2', '3', '4']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(h.container.read(passcodeLockProvider), isFalse);
    });

    testWidgets('不可用时不显示入口', (tester) async {
      final h = await boot(FakeBiometric(available: false));
      await h.container
          .read(settingsServiceProvider)
          .setFingerprintEnabled(true);
      await showLock(tester, h);
      expect(find.textContaining('解锁'), findsNothing);
      expect(find.text('已锁定'), findsOneWidget);
    });
  });

  group('设置页开关', () {
    Future<void> openSettings(WidgetTester tester, ChatHarness h) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 设置页很长（ListView 懒构建），断言/点击前先滚到目标
    Future<void> scrollTo(WidgetTester tester, Finder what) async {
      await tester.scrollUntilVisible(
        what,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    /// 「应用锁」那一行的开关（页面上已不止一个 Switch，别再用 `.first`）
    Finder appLockSwitch() => find.descendant(
      of: find.ancestor(
        of: find.text('应用锁'),
        matching: switchRowFinder,
      ),
      matching: find.byType(Switch),
    );

    testWidgets('设备支持 + 应用锁已开 → 显示指纹开关，可开可关', (tester) async {
      final h = await boot(FakeBiometric());
      await openSettings(tester, h);

      await scrollTo(tester, find.text('指纹解锁'));
      expect(find.text('指纹解锁'), findsOneWidget);
      final sw = find.ancestor(
        of: find.text('指纹解锁'),
        matching: switchRowFinder,
      );
      await tester.tap(find.descendant(of: sw, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(
        await h.container.read(settingsServiceProvider).fingerprintEnabled(),
        isTrue,
      );

      await tester.tap(find.descendant(of: sw, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(
        await h.container.read(settingsServiceProvider).fingerprintEnabled(),
        isFalse,
      );
    });

    testWidgets('设备不支持 → 不显示这一项', (tester) async {
      final h = await boot(FakeBiometric(available: false));
      await openSettings(tester, h);
      await scrollTo(tester, find.text('应用锁'));
      expect(find.text('指纹解锁'), findsNothing);
      expect(find.text('应用锁'), findsOneWidget);
    });

    testWidgets('应用锁没开 → 不显示这一项', (tester) async {
      final h = await boot(FakeBiometric(), passcode: false);
      await openSettings(tester, h);
      await scrollTo(tester, find.text('应用锁'));
      expect(find.text('指纹解锁'), findsNothing);
    });

    testWidgets('开应用锁后弹"启用指纹解锁？"，点启用即写入偏好', (tester) async {
      final h = await boot(FakeBiometric(), passcode: false);
      await openSettings(tester, h);

      await scrollTo(tester, find.text('应用锁'));
      await tester.tap(appLockSwitch()); // 打开应用锁
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '1234');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.text('启用指纹解锁？'), findsOneWidget, reason: '原版会主动建议');
      await tester.tap(find.text('启用'));
      await tester.pumpAndSettle();
      expect(
        await h.container.read(settingsServiceProvider).fingerprintEnabled(),
        isTrue,
      );
    });

    testWidgets('点"暂不"就不写偏好', (tester) async {
      final h = await boot(FakeBiometric(), passcode: false);
      await openSettings(tester, h);

      await scrollTo(tester, find.text('应用锁'));
      await tester.tap(appLockSwitch());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '1234');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('暂不'));
      await tester.pumpAndSettle();
      expect(
        await h.container.read(settingsServiceProvider).fingerprintEnabled(),
        isFalse,
      );
    });
  });
  // ★ r416 / DA74：生物识别弹框**自己**会让 Activity 走 pause/resume。
  //   修前在「Ask every time」（宽限期 = 0）档下会死循环：
  //   弹框 → pause → 指纹通过 → resume → **立刻重锁** → 又自动弹框
  //   （真机实测 80 秒弹 12 次、指纹 `accept` 4→9，界面始终进不去）。
  group('★ DA74 弹框引起的 pause/resume 不许重锁', () {
    test('弹框 pause →（指纹通过）→ resume：仍然解锁', () async {
      final h = await boot(FakeBiometric());
      await h.container
          .read(settingsServiceProvider)
          .setFingerprintEnabled(true);
      final svc = h.container.read(passcodeServiceProvider);
      await svc.init();
      expect(svc.locked, isTrue, reason: '冷启动就锁上');

      svc.onPaused(); // ① BiometricPrompt 盖上来 → onPause
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await svc.unlockWithBiometric(FakeBiometric()), isTrue);
      expect(svc.locked, isFalse); // ② 指纹通过（此刻我们还在"后台"）
      await svc.onResumed(); // ③ 弹框收起 → onResume
      expect(
        svc.locked,
        isFalse,
        reason: '★ DA74：弹框自己的 pause/resume 不该把刚验过的身份重新锁上',
      );
    });

    test('弹框 pause →（口令通过）→ resume：同样不重锁', () async {
      final h = await boot(FakeBiometric());
      final svc = h.container.read(passcodeServiceProvider);
      await svc.init();
      expect(svc.locked, isTrue);
      svc.onPaused();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await svc.unlock('1234'), isTrue);
      await svc.onResumed();
      expect(svc.locked, isFalse);
    });

    test('反向：先解锁、再真的退到后台 → 回来仍按宽限期重锁', () async {
      final h = await boot(FakeBiometric());
      final svc = h.container.read(passcodeServiceProvider);
      await svc.init();
      expect(await svc.unlock('1234'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      svc.onPaused(); // 人真的离开了
      await svc.onResumed();
      expect(svc.locked, isTrue, reason: '默认「Ask every time」⇒ 必须重锁');
    });

    testWidgets('界面层：验过之后锁屏消失，且不会自动弹第二次', (tester) async {
      // 用"闸门"假实现把时序对齐真机：**弹框先让 Activity pause，指纹后才通过**
      final bio = _GatedBiometric();
      final h = await boot(bio);
      await h.container
          .read(settingsServiceProvider)
          .setFingerprintEnabled(true);
      h.container.read(passcodeLockProvider.notifier).lockNow();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: PasscodeGate(child: Scaffold(body: Text('聊天内容'))),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(bio.calls, 1, reason: '进来只自动弹一次');

      // ① 弹框盖上来 → Activity onPause
      h.container.read(passcodeLockProvider.notifier).onPaused();
      // ② 指纹通过（此刻我们还在"后台"）
      bio.gate.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('聊天内容'), findsOneWidget, reason: '验证通过即解锁');
      // ③ 弹框收起 → Activity onResume
      await h.container.read(passcodeLockProvider.notifier).onResumed();
      await tester.pumpAndSettle();

      expect(
        find.text('聊天内容'),
        findsOneWidget,
        reason: '★ DA74：不许被弹框自己锁回去',
      );
      expect(find.text('已锁定'), findsNothing);
      expect(bio.calls, 1, reason: '★ DA74：不许再自动弹第二次');
    });
  });
}
