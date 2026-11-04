// DA275（r660）：日历「天气与节假日」面板里，**没授权定位**时那行小字必须说
// "该点哪儿"，而不是承诺一件不会发生的事。
//
// 现场（真机 2026-10-25）：开关「跟随手机定位」**默认就是开的**（蓝），
// 小字却写 "Not authorized yet; you will be asked once when enabled"
// —— 从来不会再"被打开一次"，而代码里**故意不自动弹授权框**
// （`deviceLocationProvider` 用 `ensurePermission(interactive:false)`），
// 授权只能从面板里那颗「Use current location」按钮走。
// ⇒ 用户看到"开着 + 会问我一次"，实际上既不问、也永远拿不到坐标。
//
// 这条用例钉死两件事：
//   ① 文案必须点名那颗按钮（用户照着点就能授权）；
//   ② 不许再出现"will be asked / 问一次"这种不会被兑现的承诺。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/data/region/device_location.dart';
import 'package:synhub/src/data/region/region_context.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/calendar/calendar_env.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/calendar/calendar_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _calTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Cal.Cal': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Event': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Setting': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Todo': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
};

/// 权限被拒（系统里点过"不允许"）
class _DeniedLocation implements DeviceLocationProbe {
  @override
  Future<LocationPermission> ensurePermission({bool interactive = true}) async =>
      LocationPermission.denied;

  @override
  Future<bool> serviceEnabled() async => true;

  @override
  Future<DeviceLocation?> current() async => null;

  @override
  Future<void> clearCache() async {}
}

void main() {
  Future<ProviderContainer> harness(
    WidgetTester tester,
    String lang,
    DeviceLocationProbe probe,
  ) async {
    final transport = FakeTransport(const {}, {
      ...FakeTransport.table,
      ..._calTable,
    });
    final api = DsmWebApi(transport);
    await api.discover();
    await api.login(account: 'a', password: 'b');
    return ProviderContainer(
      overrides: [
        calendarApiProvider.overrideWithValue(CalendarApi(api)),
        calendarRegionProvider.overrideWith(
          (ref) async => const RegionContext(
            countryCode: 'CN',
            city: '北京',
            timezone: 'Asia/Shanghai',
            source: RegionSource.manual,
          ),
        ),
        weatherBundleProvider.overrideWith((ref) async => null),
        holidayBundleProvider.overrideWith((ref) async => null),
        deviceLocationProbeProvider.overrideWithValue(probe),
        deviceLocationProvider.overrideWith((ref) async => null),
        locationPermissionProvider.overrideWith(
          (ref) async => probe.ensurePermission(interactive: false),
        ),
      ],
    );
  }

  Future<void> pumpPage(
    WidgetTester tester,
    ProviderContainer container,
    String lang,
  ) async {
    setCurrentText(lookupAppText(Locale(lang)));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: Locale(lang),
          localizationsDelegates: const [
            AppText.delegate,
            FlutterQuillLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh'), Locale('en')],
          home: const CalendarPage(),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('DA275：没授权定位时，小字必须点名「用当前位置」那颗按钮', (tester) async {
    final container = await harness(tester, 'en', _DeniedLocation());
    addTearDown(container.dispose);
    await pumpPage(tester, container, 'en');

    await tester.tap(find.byKey(const Key('cal-env-card')));
    await tester.pumpAndSettle();

    // 面板真打开了吗
    expect(find.byKey(const Key('cal-env-autolocate')), findsOneWidget);

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(
      texts,
      contains('Use current location'),
      reason: 'DA275：小字必须指向用户能点的那颗按钮（授权只从那里走）',
    );
    expect(
      texts.toLowerCase(),
      isNot(contains('will be asked')),
      reason: 'DA275：开关默认就开着 ⇒ "打开时问一次"是永远不会兑现的承诺',
    );
    expect(texts.toLowerCase(), isNot(contains('ask you')),
        reason: 'DA275：同一类"会来问你"的说法都不许留');

    // 关掉面板：卡片上那一行也要能指引用户（原来写 "No place information yet"，
    // 既不说原因也不说该点哪儿）
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    final cardTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(
      cardTexts.toLowerCase(),
      contains('needs a location'),
      reason: 'DA275：卡片要说出"缺的是位置"并且指向可点的动作',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('DA275 反向：已授权但拿不到定点时，仍然说"没拿到位置"', (tester) async {
    final container = await harness(tester, 'en', _GrantedNoFixLocation());
    addTearDown(container.dispose);
    await pumpPage(tester, container, 'en');

    await tester.tap(find.byKey(const Key('cal-env-card')));
    await tester.pumpAndSettle();

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(texts, contains('Use current location'));
    expect(
      texts.toLowerCase(),
      contains('no location fix'),
      reason: '授权与"拿不到位置"是两件事，排除权限原因后要说清是定位本身没结果',
    );

    await tester.pumpWidget(const SizedBox());
  });
}

/// 已授权，但这台机现在拿不到定点（定位总开关关着/超时）
class _GrantedNoFixLocation implements DeviceLocationProbe {
  @override
  Future<LocationPermission> ensurePermission({bool interactive = true}) async =>
      LocationPermission.granted;

  @override
  Future<bool> serviceEnabled() async => false;

  @override
  Future<DeviceLocation?> current() async => null;

  @override
  Future<void> clearCache() async {}
}
