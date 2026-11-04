// 应用身份 + 多语言骨架的离线验证：
//   * 应用名（星枢 / SynHub）与 `appNameIn` 的判定；
//   * 界面语言偏好（`LocaleChoice`）的默认值 / 落盘 / key 名；
//   * 没有本地化 delegate 时**回落到中文**（老测试不用改就能继续跑）；
//   * 注入 delegate + `Locale('en')` 时外壳真的变英文（导航/工作台/我的/设置）；
//   * 在设置页里切语言**当场生效**（不用重启）。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/i18n/data_text.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/notifications/reminder_scheduler.dart'
    as reminder;
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/channel_sort.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatStoreProvider;
import 'package:synhub/src/features/settings/settings_page.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';
import 'package:drift/native.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

ChatStore _store() => ChatStore(ChatDatabase(NativeDatabase.memory()));

/// 与 `app.dart` 同款的壳：locale 跟着 `localeChoiceProvider` 走。
/// 跟随系统时钉死中文，测试才有确定性（测试环境默认 en-US）。
class _Harness extends ConsumerWidget {
  const _Harness(this.child);
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(localeChoiceProvider);
    return MaterialApp(theme: AppTheme.dark(), 
      locale: choice.locale ?? const Locale('zh'),
      // 用 GlobalMaterialLocalizations.delegates（复数）：它一次带上
      // Material/Widgets/Cupertino 三家，少了 Cupertino 会在测试里直接抛
      localizationsDelegates: const [
        AppText.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppText.supportedLocales,
      home: child,
    );
  }
}

Future<void> _pump(WidgetTester tester, ProviderContainer c, Widget child) =>
    tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: _Harness(child)),
    );

void main() {
  group('应用名', () {
    test('中文环境是「星枢」，英文环境是 SynHub', () {
      expect(appNameIn(null), '星枢');
      expect(appNameIn(const Locale('zh')), '星枢');
      expect(appNameIn(const Locale('zh', 'TW')), '星枢');
      expect(appNameIn(const Locale('en')), 'SynHub');
      expect(appNameIn(const Locale('en', 'US')), 'SynHub');
    });

    test('ARB 里的 appName 与 appNameIn 一致（别只改一处）', () {
      expect(AppTextZh().appName, appNameIn(const Locale('zh')));
      expect(AppTextEn().appName, appNameIn(const Locale('en')));
    });
  });

  group('界面语言偏好', () {
    test('默认跟随系统；写入后能读回（key = app_locale）', () async {
      final store = _store();
      final s = SettingsService(store);
      expect(await s.localeChoice(), LocaleChoice.system);

      await s.setLocaleChoice(LocaleChoice.en);
      expect(await s.localeChoice(), LocaleChoice.en);
      expect(await store.setting(kLocaleKey), 'en');

      await s.setLocaleChoice(LocaleChoice.zh);
      expect(await s.localeChoice(), LocaleChoice.zh);
      expect(await store.setting(kLocaleKey), 'zh');
    });

    test('provider：set 立刻改 state，并落盘', () async {
      final c = ProviderContainer(
        overrides: [chatStoreProvider.overrideWithValue(_store())],
      );
      addTearDown(c.dispose);
      expect(c.read(localeChoiceProvider), LocaleChoice.system);

      await c.read(localeChoiceProvider.notifier).set(LocaleChoice.en);
      expect(c.read(localeChoiceProvider), LocaleChoice.en);
      expect(
        await c.read(settingsServiceProvider).localeChoice(),
        LocaleChoice.en,
      );
    });

    test('preload 把磁盘上的值读回来', () async {
      final store = _store();
      await SettingsService(store).setLocaleChoice(LocaleChoice.zh);
      final c = ProviderContainer(
        overrides: [chatStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      await c.read(localeChoiceProvider.notifier).preload();
      expect(c.read(localeChoiceProvider), LocaleChoice.zh);
    });
  });

  group('外壳文案', () {
    testWidgets('没有 delegate 时回落到中文（老测试的兼容层）', (tester) async {
      final h = await bootChat();
      // 故意只搭 MaterialApp，不给任何本地化 delegate
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: WorkspaceTab())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('笔记'), findsOneWidget);
      expect(find.text('Notes'), findsNothing);
    });

    testWidgets('英文：工作台模块名变英文', (tester) async {
      final h = await bootChat();
      await h.container
          .read(localeChoiceProvider.notifier)
          .set(LocaleChoice.en);
      await _pump(tester, h.container, const Scaffold(body: WorkspaceTab()));
      await tester.pumpAndSettle();
      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('笔记'), findsNothing);
      expect(find.text('文件'), findsNothing);
    });

    testWidgets('英文：我的页入口变英文', (tester) async {
      final h = await bootChat();
      await h.container
          .read(localeChoiceProvider.notifier)
          .set(LocaleChoice.en);
      await _pump(tester, h.container, const Scaffold(body: MeTab()));
      await tester.pumpAndSettle();
      expect(find.text('Me'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('归档频道'), findsNothing);
    });
  });

  group('设置页', () {
    testWidgets('中文：语言入口在「外观」第一行，副标题是「跟随系统」', (tester) async {
      final h = await bootChat();
      await _pump(tester, h.container, const SettingsPage());
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('语言'), findsOneWidget);
      expect(find.text('跟随系统'), findsWidgets);
    });

    testWidgets('切到 English：整页当场变英文（不用重启）', (tester) async {
      final h = await bootChat();
      await _pump(tester, h.container, const SettingsPage());
      await tester.pumpAndSettle();

      await tester.tap(find.text('语言'));
      await tester.pumpAndSettle();
      // 语言名用本语言自称：English 在两个语言下都写 English
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget, reason: 'AppBar 标题');
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      expect(h.container.read(localeChoiceProvider), LocaleChoice.en);
      // 落盘也要有（重启后还是英文）
      expect(
        await h.container.read(settingsServiceProvider).localeChoice(),
        LocaleChoice.en,
      );
    });

    test('★★ r371（DA17）：重新认证间隔的 6 个档位都有本地化出口', () {
      expect(PasscodeExpiration.always.labelIn(AppTextEn()), 'Ask every time');
      expect(PasscodeExpiration.fiveMinutes.labelIn(AppTextEn()), 'After 5 minutes');
      // 中文回落仍在（非 widget 场合/无 delegate 时用），但**界面不许**走它
      expect(PasscodeExpiration.always.label, '每次都要求');
      for (final e in PasscodeExpiration.values) {
        expect(
          RegExp(r'[\u4E00-\u9FFF]').hasMatch(e.labelIn(AppTextEn())),
          isFalse,
          reason: '${e.name} 的英文里混进了中文',
        );
        expect(e.labelIn(AppTextZh()).isNotEmpty, isTrue);
        expect(e.labelIn(AppTextZh()), e.label);
      }
    });

    test('★★ r372（DA27）：频道排序方式的 2 个档位都有本地化出口（英文里不许混中文）', () {
      // DA17 的同族漏网：`ChannelSortMethod` 把中文成品串塞在 `enum` 里、
      // 界面若直接渲染 `.label` 就会让英文界面出现中文（r372 改成 `labelIn`）。
      expect(ChannelSortMethod.name.labelIn(AppTextEn()), 'Name');
      expect(ChannelSortMethod.time.labelIn(AppTextEn()), 'Latest message');
      // 中文回落仍在（无 delegate 的场合用），但**界面不许**走它
      expect(ChannelSortMethod.time.label, '接收时间');
      for (final e in ChannelSortMethod.values) {
        expect(
          RegExp(r'[\u4E00-\u9FFF]').hasMatch(e.labelIn(AppTextEn())),
          isFalse,
          reason: '${e.name} 的英文里混进了中文',
        );
        expect(e.labelIn(AppTextZh()).isNotEmpty, isTrue);
        expect(e.labelIn(AppTextZh()), e.label);
      }
    });

    testWidgets('★★ r371（DA17）：英文 + 应用锁已开 ⇒ 那一行副标题是英文', (tester) async {
      final h = await bootChat();
      await h.container.read(settingsServiceProvider).setPasscodeEnabled(true);
      await h.container
          .read(localeChoiceProvider.notifier)
          .set(LocaleChoice.en);
      await _pump(tester, h.container, const SettingsPage());
      await tester.pumpAndSettle();
      // 页面长，先滚到底把它构建出来（与同组上一条用例同法）
      final target = find.text('Re-authentication interval');
      for (var i = 0; i < 24 && target.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -240));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(target, findsOneWidget, reason: '应用锁行本身');
      expect(
        find.text('Ask every time'),
        findsOneWidget,
        reason: '★★ 缺陷原文：英文界面里这一行显示的是中文「每次都要求」',
      );
      expect(find.text('每次都要求'), findsNothing);
    });

    testWidgets('英文：缓存/关于几个关键行也翻了', (tester) async {
      final h = await bootChat();
      await h.container
          .read(localeChoiceProvider.notifier)
          .set(LocaleChoice.en);
      await _pump(tester, h.container, const SettingsPage());
      await tester.pumpAndSettle();
      // 页面长，下面的行要滚出来才会构建（同 settings_test 的手写滚动）
      Future<void> reveal(String label) async {
        final target = find.text(label);
        for (var i = 0; i < 24 && target.evaluate().isEmpty; i++) {
          await tester.drag(find.byType(ListView), const Offset(0, -240));
          await tester.pump(const Duration(milliseconds: 60));
        }
        expect(target, findsOneWidget, reason: label);
      }

      for (final label in const [
        'Image quality for sending',
        'Cache limit',
        'Version',
        'Server',
      ]) {
        await reveal(label);
      }
    });
  });
  group('系统级文案跟平台语言（通知栏/提醒）', () {
    test('平台语言 en → 通知标题与提醒正文都是英文', () {
      final pd =
          TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
      pd.localeTestValue = const Locale('en');
      pd.localesTestValue = const [Locale('en')];
      addTearDown(() {
        pd.clearLocaleTestValue();
        pd.clearLocalesTestValue();
      });

      final t = platformText();
      expect(t.notifyAggTitle(3), '3 new messages');
      expect(t.notifyAggTitleChannel(3, 'Team'), '3 new messages | Team');
      expect(
        reminder.reminderNotificationText('buy milk'),
        'Hi! Here\'s the reminder you asked for about “buy milk”.',
      );
    });

    test('平台语言 zh → 与老断言逐字一致（N 条新消息 / 嗨！…）', () {
      final pd =
          TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
      pd.localeTestValue = const Locale('zh');
      pd.localesTestValue = const [Locale('zh')];
      addTearDown(() {
        pd.clearLocaleTestValue();
        pd.clearLocalesTestValue();
      });

      final t = platformText();
      expect(t.notifyAggTitle(2), '2 条新消息');
      expect(t.notifyAggTitleChannel(2, '测试频道'), '2 条新消息 | 测试频道');
      expect(reminder.reminderNotificationText('买菜'), '嗨！以下是您关于「买菜」的提醒。');
    });
  });
  group('设备档位文案（设置页那行）', () {
    test('en 下档位名与规格串都是英文，zh 下与老断言一致', () {
      final zh = DeviceProfile.of(cores: 6, ramMb: 7090, sdkInt: 31);
      expect(zh.tierLabelIn(AppTextZh()), '高端');
      expect(zh.specLabelIn(AppTextZh()), '6 核 · 6.9 GB · Android SDK 31');
      expect(zh.tierLabelIn(AppTextEn()), 'High-end');
      expect(zh.specLabelIn(AppTextEn()), '6-core · 6.9 GB · Android SDK 31');
      // 中文回落字段（老测试与没有 context 的地方仍读它）
      expect(zh.tierLabel, '高端');
      expect(zh.specLabel, '6 核 · 6.9 GB · Android SDK 31');
    });
  });
  group('数据层文案（key + 中文原文，Flutter 层注入翻译）', () {
    test('setCurrentText 一切，dataText 与 DsmErrorCode 的表都跟着变', () {
      addTearDown(() => setCurrentText(AppTextZh()));
      setCurrentText(AppTextEn());
      expect(
        dataText('errLoginExpired', '登录已过期，请重新登录'),
        'Sign-in expired, please sign in again',
      );
      expect(
        DsmErrorCode.describe(DsmErrorCode.sessionTimeout),
        'Session timed out, please sign in again',
      );
      setCurrentText(AppTextZh());
      expect(dataText('errLoginExpired', '登录已过期，请重新登录'), '登录已过期，请重新登录');
      expect(DsmErrorCode.describe(DsmErrorCode.sessionTimeout), '会话超时，请重新登录');
    });
  });
}
