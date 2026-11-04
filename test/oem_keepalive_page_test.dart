// ★ 第 278 轮：厂商保活指引页的 widget 守卫（Key 契约 + 三态 + 深链行为）。
//
// 这一页的用户价值全在"**能点对地方**"：原生验真到自启动页才给按钮，
// 探不到就只给手动路径 —— 所以用例重点断言"按钮在不在"与"点了带什么参数"，
// 而不是只断言"页面画出来了"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/device/oem_compat_platform.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/features/settings/oem_keepalive_page.dart';

/// 记录调用的假平台
class _FakeOem implements OemCompatPlatform {
  _FakeOem(this._status, {this.openResult = true, this.throws = false});

  final OemCompatStatus _status;
  final bool openResult;
  final bool throws;
  final List<String> opened = <String>[];

  @override
  Future<OemCompatStatus> status() async {
    if (throws) throw StateError('boom');
    return _status;
  }

  @override
  Future<bool> openSettings(String target) async {
    opened.add(target);
    return openResult;
  }
}

OemCompatStatus _honor({bool autostart = true}) => OemCompatStatus(
  supported: true,
  oemId: 'honor',
  manufacturer: 'HONOR',
  brand: 'HONOR',
  model: 'LGE-AN10',
  sdkInt: 31,
  rom: 'MagicUI_6.0.0',
  autostartComponent: autostart
      ? 'com.hihonor.systemmanager/'
            'com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity'
      : '',
  batteryOptimizationIgnored: false,
);

Future<_FakeOem> _pump(
  WidgetTester tester,
  OemCompatStatus status, {
  bool openResult = true,
  bool throws = false,
}) async {
  final fake = _FakeOem(status, openResult: openResult, throws: throws);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [oemCompatPlatformProvider.overrideWithValue(fake)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppText.localizationsDelegates,
        supportedLocales: AppText.supportedLocales,
        home: const OemKeepalivePage(),
      ),
    ),
  );
  // FutureProvider 的异步结果
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return fake;
}

void main() {
  setUp(() => setCurrentText(AppTextZh()));
  tearDown(() => setCurrentText(AppTextZh()));

  testWidgets('Honor + 验真到自启动页 ⇒ 步骤、深链按钮、手动路径、激进档提示都在', (tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, _honor());

    expect(find.byKey(const Key('oem-keepalive-page')), findsOneWidget);
    expect(find.byKey(const Key('oem-device-line')), findsOneWidget);
    expect(find.textContaining('HONOR'), findsWidgets);
    expect(find.byKey(const Key('oem-kill-level')), findsOneWidget);
    expect(find.byKey(const Key('oem-battery-state')), findsOneWidget);
    // 激进档 → 四步齐全
    expect(find.byKey(const Key('oem-step-autostart')), findsOneWidget);
    expect(find.byKey(const Key('oem-step-background-activity')), findsOneWidget);
    expect(find.byKey(const Key('oem-step-battery')), findsOneWidget);
    expect(find.byKey(const Key('oem-step-lock-recents')), findsOneWidget);
    // 验真到了 ⇒ 有可点按钮
    expect(find.byKey(const Key('oem-open-autostart')), findsOneWidget);
    // 手动路径是 Honor 专有的
    expect(find.byKey(const Key('oem-path')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('oem-path'))).data, contains('应用启动管理'));
    expect(find.byKey(const Key('oem-autostart-missing')), findsNothing);
    expect(find.byKey(const Key('oem-recheck')), findsOneWidget);
  });

  testWidgets('Honor + 探不到自启动页 ⇒ 只留步骤文字 + 诚实提示，**不给**死按钮', (tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, _honor(autostart: false));

    expect(find.byKey(const Key('oem-step-autostart')), findsOneWidget);
    expect(find.byKey(const Key('oem-autostart-missing')), findsOneWidget);
    expect(
      find.byKey(const Key('oem-open-autostart')),
      findsNothing,
      reason: '探不到却摆按钮 = 用户点了报错，比没有更糟',
    );
    // 电池那一步与平台无关，仍在
    expect(find.byKey(const Key('oem-open-battery_whitelist')), findsOneWidget);
  });

  testWidgets('点自启动按钮 → 原生收到 target=autostart', (tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final fake = await _pump(tester, _honor());
    await tester.tap(find.byKey(const Key('oem-open-autostart')));
    await tester.pump();
    expect(fake.opened, ['autostart']);
  });

  testWidgets('打不开 → 如实提示（SnackBar），不静默', (tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, _honor(), openResult: false);
    await tester.tap(find.byKey(const Key('oem-open-battery_whitelist')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(AppTextZh().oemOpenFailed), findsOneWidget);
  });

  testWidgets('google：没有自启动那一步（原生里就没有这一层白名单）', (tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      const OemCompatStatus(
        supported: true,
        oemId: 'google',
        manufacturer: 'Google',
        model: 'Pixel 8',
        sdkInt: 35,
        rom: 'AP2A',
      ),
    );
    expect(find.byKey(const Key('oem-step-autostart')), findsNothing);
    expect(find.byKey(const Key('oem-step-battery')), findsOneWidget);
    expect(find.byKey(const Key('oem-step-lock-recents')), findsNothing);
    // setUp 里装的是中文表 ⇒ 这里断言中文路径（英文那条另有专门用例）
    expect(tester.widget<Text>(find.byKey(const Key('oem-path'))).data, contains('电池'));
  });

  testWidgets('未探测到厂商（通道缺失）⇒ 三态里的第三态：通用路径，不假装知道', (tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, const OemCompatStatus());
    expect(find.byKey(const Key('oem-not-detected')), findsOneWidget);
    expect(find.byKey(const Key('oem-kill-level')), findsNothing);
    expect(find.byKey(const Key('oem-path')), findsOneWidget); // 仍有通用路径
  });

  testWidgets('探测失败也**不空页**（error 分支给通用指引）', (tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, _honor(), throws: true);
    expect(find.byKey(const Key('oem-keepalive-page')), findsOneWidget);
    expect(find.byKey(const Key('oem-path')), findsOneWidget);
    expect(find.byKey(const Key('oem-not-detected')), findsOneWidget);
  });

  // ★ 回归：这一步曾经写成 `ListTile(trailing: TextButton(...))`，在窄屏上
  // 直接抛 "Trailing widget consumes the entire tile width"（本用例就是当场
  // 抓到这个缺陷的）。320dp 是最窄的常见手机宽度，放不下就该换行而不是溢出。
  testWidgets('320dp 窄屏：4 步 + 深链按钮零溢出（回归）', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, _honor());
    // 有溢出/布局断言失败时 flutter_test 会在这里抛
    expect(tester.takeException(), isNull);
    // 4 步都在（用 ensureVisible 滚到每一行，顺带证明可滚动可达）
    for (final id in const [
      'autostart',
      'background-activity',
      'battery',
      'lock-recents',
    ]) {
      final f = find.byKey(Key('oem-step-$id'));
      await tester.scrollUntilVisible(f, 120, scrollable: find.byType(Scrollable).first);
      expect(f, findsOneWidget, reason: '$id 在窄屏不可达');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文界面下路径与步骤不含中日韩字符', (tester) async {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    setCurrentText(AppTextEn());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          oemCompatPlatformProvider.overrideWithValue(_FakeOem(_honor())),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppText.localizationsDelegates,
          supportedLocales: AppText.supportedLocales,
          home: const OemKeepalivePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final cjk = RegExp(r'[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]');
    for (final key in const ['oem-path', 'oem-note']) {
      final text = tester.widget<Text>(find.byKey(Key(key))).data ?? '';
      expect(cjk.hasMatch(text), isFalse, reason: '$key 在英文下仍是中文：$text');
    }
    expect(
      _renderedTexts(tester).where(cjk.hasMatch),
      isEmpty,
      reason: '英文模式下整页不许出现中文',
    );
  });
}

/// 页面上所有 Text 的实际内容
List<String> _renderedTexts(WidgetTester tester) => [
  for (final w in tester.widgetList<Text>(find.byType(Text)))
    if (w.data != null) w.data!,
];
