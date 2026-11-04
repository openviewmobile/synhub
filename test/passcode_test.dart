// Phase 9：应用锁（4 位数字口令）离线验证。
//
// 覆盖：散列不落地明文、格式校验、宽限期（`passcode_expiration`）语义、
// 锁屏 UI 的输入/错误/解锁、设置页开关。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/security/passcode_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/security/passcode_screen.dart';
import 'package:synhub/src/features/settings/settings_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';
import 'support/switch_rows.dart';

void main() {
  group('PasscodeService', () {
    test('设置口令：只落散列 + 盐，库里有不开明文', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      final svc = PasscodeService(SettingsService(store));

      await svc.setPasscode('1234');
      final all = await store.allSettings();
      expect(all['passcode_enable'], 'true');
      expect(all['passcode_hash'], isNotEmpty);
      expect(all['passcode_hash'], isNot(contains('1234')));
      expect(all['passcode_salt'], isNotEmpty);
      expect(
        all.containsKey('passcode'),
        isFalse,
        reason: '我们连可逆密文都不存，比原版的 KeyStore 加密更严',
      );

      expect(await svc.verify('1234'), isTrue);
      expect(await svc.verify('1235'), isFalse);
      expect(await svc.verify('123'), isFalse);
      expect(await svc.verify(''), isFalse);
    });

    test('格式校验：必须 4 位数字', () async {
      final h = await bootChat();
      final svc = PasscodeService(
        SettingsService(h.container.read(chatStoreProvider)),
      );
      expect(PasscodeService.isValidFormat('0000'), isTrue);
      expect(PasscodeService.isValidFormat('123'), isFalse);
      expect(PasscodeService.isValidFormat('12345'), isFalse);
      expect(PasscodeService.isValidFormat('12a4'), isFalse);
      await expectLater(svc.setPasscode('12a4'), throwsArgumentError);
    });

    test('同一口令两次设置散列不同（盐随机）', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      final svc = PasscodeService(SettingsService(store));
      await svc.setPasscode('1234');
      final h1 = (await store.allSettings())['passcode_hash'];
      await svc.setPasscode('1234');
      final h2 = (await store.allSettings())['passcode_hash'];
      expect(h1, isNot(h2));
      expect(await svc.verify('1234'), isTrue);
    });

    test('disable 清掉口令与开关', () async {
      final h = await bootChat();
      final svc = PasscodeService(
        SettingsService(h.container.read(chatStoreProvider)),
      );
      await svc.setPasscode('1234');
      expect(await svc.verify('1234'), isTrue);
      await svc.disable();
      expect(await svc.verify('1234'), isFalse);
      expect(
        await SettingsService(
          h.container.read(chatStoreProvider),
        ).passcodeEnabled(),
        isFalse,
      );
    });

    test('宽限期：ALWAYS 立刻重锁，5 分钟档宽限内不锁', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      var now = DateTime(2026, 1, 1, 12);
      final svc = PasscodeService(SettingsService(store), now: () => now);
      await svc.setPasscode('1234');

      // 默认 ALWAYS：退后台再回来就要重输
      await svc.init();
      expect(svc.locked, isTrue);
      expect(await svc.unlock('1234'), isTrue);
      expect(svc.locked, isFalse);
      svc.onPaused();
      await svc.onResumed();
      expect(svc.locked, isTrue, reason: 'ALWAYS = 每次都要求');

      // 切到 5 分钟：2 分钟内回来不锁，6 分钟后锁
      await store.setSetting('passcode_expiration', 'MIN_5');
      expect(await svc.unlock('1234'), isTrue);
      svc.onPaused();
      now = now.add(const Duration(minutes: 2));
      await svc.onResumed();
      expect(svc.locked, isFalse, reason: '2 分钟 < 5 分钟宽限');

      svc.onPaused();
      now = now.add(const Duration(minutes: 6));
      await svc.onResumed();
      expect(svc.locked, isTrue, reason: '6 分钟 > 5 分钟宽限');
    });

    test('没开应用锁时，退到后台再回来不锁', () async {
      final h = await bootChat();
      final svc = PasscodeService(
        SettingsService(h.container.read(chatStoreProvider)),
      );
      await svc.init();
      expect(svc.locked, isFalse);
      svc.onPaused();
      await svc.onResumed();
      expect(svc.locked, isFalse);
    });
  });

  group('锁屏界面', () {
    Future<void> boot(
      WidgetTester tester,
      Widget child,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), home: child),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('输错提示，输对解锁', (tester) async {
      final h = await bootChat();
      final svc = PasscodeService(
        SettingsService(h.container.read(chatStoreProvider)),
      );
      await svc.setPasscode('1234');

      await boot(tester, const PasscodeLockScreen(), h.container);
      expect(find.text('已锁定'), findsOneWidget);

      // 输错
      for (final d in ['9', '9', '9', '9']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('口令不对'), findsOneWidget);
      expect(h.container.read(passcodeLockProvider), isFalse);

      // 输对（含一次退格）
      for (final d in ['1', '2', '3', '5']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();
      await tester.tap(find.text('4'));
      await tester.pumpAndSettle();
      expect(find.text('口令不对'), findsNothing);
    });

    testWidgets('PasscodeGate 在锁上时盖住子界面', (tester) async {
      final h = await bootChat();
      final svc = PasscodeService(
        SettingsService(h.container.read(chatStoreProvider)),
      );
      await svc.setPasscode('1234');
      h.container.read(passcodeLockProvider.notifier).lockNow();

      await boot(
        tester,
        const PasscodeGate(child: Scaffold(body: Text('聊天内容'))),
        h.container,
      );
      expect(find.text('聊天内容'), findsOneWidget, reason: '仍在树里');
      expect(find.text('已锁定'), findsOneWidget, reason: '但被锁屏盖住');
    });
  });

  group('设置页的应用锁开关', () {
    testWidgets('打开开关 → 设置口令 → 显示重认证间隔', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 设置页变长了（本轮新增"预加载消息/回车发送"），先滚到应用锁那一行；
      // 页面上也不止一个 Switch 了，要精确定位到「应用锁」这一行里的那个
      await tester.scrollUntilVisible(
        find.text('应用锁'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('应用锁'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('应用锁'),
            matching: switchRowFinder,
          ),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();

      // 两次输入 1234
      await tester.enterText(find.byType(TextField).at(0), '1234');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(
        await SettingsService(
          h.container.read(chatStoreProvider),
        ).passcodeEnabled(),
        isTrue,
      );
      expect(find.text('重新认证间隔'), findsOneWidget);
      expect(find.text('立即锁定'), findsOneWidget);
    });
  });
}
