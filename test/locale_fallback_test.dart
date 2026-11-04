// ★★★ P0-1 回归（Linux 站，第 109 轮）：**未知 / 不支持的 locale 必须回落，绝不许抛**
//
// 背景（原始证据见 `docs/platform-linux.md` §8.4 缺陷 1 与像素
// `r108-linux-locale-C-redscreen.png`）：amd64 容器 + Xvfb 里真跑起来时，
// 容器内未设 `LANG` ⇒ Flutter 从平台取到的 locale 是 **`C`** ⇒
// gen-l10n 生成的 `lookupAppText()` 对 en/zh 之外的 locale **直接抛
// `FlutterError`** ⇒ `SynologyChatApp.build` 当场炸 ⇒ **整屏红色错误页**。
//
// 本文件要钉三件事：
//   ① **反向验证**：raw `lookupAppText(Locale('c'))` **必须真抛** ——
//      证明这个 P0 不是"纸面担忧"，也证明下面那组回落不是空转；
//   ② 回落后的面（`resolveAppLocale` / `lookupAppTextSafe` / `platformText`）
//      **一个都不许抛**，且归一结果必须与 Flutter 自己的兜底一致；
//   ③ **第一屏**在 `locale=C` 下真的画得出来（不是"某页面缺翻译"，
//      是 App 起不来），且不出现 `ErrorWidget`（红屏）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/i18n/l10n.dart';

/// 容器/最小 Linux 上 `LANG` 未设置时引擎给的那种 locale。
/// 大小写两种都造一份：`LANG=C` 与 `LANG=POSIX` 经过不同平台层可能给
/// `c` / `C`，回落逻辑对两者都必须成立。
const _cLocaleLower = Locale('c');
const _cLocaleUpper = Locale('C');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P0-1 反向验证：raw 生成代码对未知 locale 真的会抛', () {
    test('lookupAppText(Locale("c")) 抛 FlutterError（这就是红屏的根因）', () {
      expect(
        () => lookupAppText(_cLocaleLower),
        throwsA(isA<FlutterError>()),
        reason: 'raw lookupAppText 不该被放宽 —— 它是"坑还在"的证据；'
            '放宽的是 lookupAppTextSafe / resolveAppLocale 这一层',
      );
    });

    test('lookupAppText(Locale("C")) 同样抛（大小写都挡不住）', () {
      expect(() => lookupAppText(_cLocaleUpper), throwsA(isA<FlutterError>()));
    });

    test('isSupportedAppLocale 对 C / 空 / null 都是 false', () {
      expect(isSupportedAppLocale(_cLocaleLower), isFalse);
      expect(isSupportedAppLocale(_cLocaleUpper), isFalse);
      expect(isSupportedAppLocale(null), isFalse);
    });
  });

  group('P0-1 回落面：只回落不抛，且与 Flutter 兜底一致', () {
    test('回落目标 = supportedLocales.first（否则界面层与数据层会串台）', () {
      expect(
        AppText.supportedLocales.first.languageCode,
        kFallbackAppLocale.languageCode,
        reason: 'basicLocaleListResolution 匹配不上时返回 supportedLocales.first；'
            'kFallbackAppLocale 必须与它相同，否则界面( delegate )与数据层'
            '( setCurrentText )会是两种语言 ⇒ 中英混排',
      );
      expect(isSupportedAppLocale(kFallbackAppLocale), isTrue);
    });

    test('resolveAppLocale：认识的原样归一，不认识的一律回落', () {
      expect(resolveAppLocale(const Locale('zh')), const Locale('zh'));
      expect(resolveAppLocale(const Locale('zh', 'TW')), const Locale('zh'));
      expect(resolveAppLocale(const Locale('en')), const Locale('en'));
      expect(resolveAppLocale(const Locale('en', 'US')), const Locale('en'));
      expect(resolveAppLocale(_cLocaleLower), kFallbackAppLocale);
      expect(resolveAppLocale(_cLocaleUpper), kFallbackAppLocale);
      expect(resolveAppLocale(const Locale('fr')), kFallbackAppLocale);
      expect(resolveAppLocale(null), kFallbackAppLocale);
      // ★ r677（环境矩阵 ja / zh-Hant 两档）：**没有** ja / zh-Hant 的 ARB（只有 en/zh），
      //   所以这两档必须"有界回落"，不许抛、不许中英混排：
      //   * `ja`（语言码不认识）⇒ en（= `kFallbackAppLocale`，与 Flutter 自己的兜底一致）；
      //   * `zh-Hant-TW` 只按 `languageCode` 匹配 ⇒ **zh（简体）**。这是有意的：
      //     简体对繁体用户仍远好于英文，且**绝不**出现中英混排（界面层与数据层同一个
      //     `resolveAppLocale` ⇒ 不会一个说英文一个说中文）。
      expect(resolveAppLocale(const Locale('ja')), kFallbackAppLocale);
      expect(resolveAppLocale(const Locale('ja', 'JP')), kFallbackAppLocale);
      expect(
        resolveAppLocale(
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'TW',
          ),
        ),
        const Locale('zh'),
        reason: 'zh-Hant 落到 zh（简体）：有界、可解释，不是"漏翻"',
      );
      expect(
        resolveAppLocale(const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')),
        const Locale('zh'),
      );
    });

    test('lookupAppTextSafe：未知 locale 不抛，返回受支持语言的文案表', () {
      late AppText t;
      expect(() => t = lookupAppTextSafe(_cLocaleLower), returnsNormally);
      // 不抛之外还要"真的是某一种语言"，不能是半成品
      expect(t.appName, isNotEmpty);
      expect(lookupAppTextSafe(const Locale('zh')), isA<AppTextZh>());
      expect(lookupAppTextSafe(const Locale('en')), isA<AppTextEn>());
    });

    test('platformText() 在 LANG=C 场景不抛（通知/后台服务同根因）', () {
      final pd = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher;
      pd.localeTestValue = _cLocaleLower;
      pd.localesTestValue = const [_cLocaleLower];
      addTearDown(() {
        pd.clearLocaleTestValue();
        pd.clearLocalesTestValue();
      });

      late AppText t;
      expect(() => t = platformText(), returnsNormally);
      expect(t.appName, isNotEmpty);
    });
  });

  group('P0-1 第一屏：locale=C 下不许红屏', () {
    setUp(() {
      final pd = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher;
      pd.localeTestValue = _cLocaleLower;
      pd.localesTestValue = const [_cLocaleLower];
    });
    tearDown(() {
      final pd = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher;
      pd.clearLocaleTestValue();
      pd.clearLocalesTestValue();
    });

    testWidgets('App 外壳在 locale=C 下照常落在「添加服务器」页', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: SynologyChatApp()));
      await tester.pumpAndSettle();

      // ① 没有异常、没有红屏（修复前这里是 FlutterError + ErrorWidget）
      expect(tester.takeException(), isNull);
      expect(
        find.byType(ErrorWidget),
        findsNothing,
        reason: 'ErrorWidget 就是那块红屏（r108-linux-locale-C-redscreen.png）',
      );

      // ② 第一屏真的画出来了（登录页的关键元素）
      expect(find.text('QuickConnect ID'), findsWidgets);

      // ③ 语言是回落后的那一门，不是"没语言"
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.title, appNameIn(kFallbackAppLocale));
      expect(app.locale, isNull, reason: '跟随系统时不该钉死 locale');
    });

    testWidgets('未知 locale 经 localeResolutionCallback 归一（不落到 delegate 抛）',
        (tester) async {
      // 直接量"MaterialApp 实际协商出来的 locale"，而不是只看画没画出来：
      // 修复前 delegate 会收到 C；修复后必须收到 en。
      late Locale negotiated;
      await tester.pumpWidget(
        MaterialApp(
          localeResolutionCallback: (locale, supported) =>
              resolveAppLocale(locale),
          supportedLocales: AppText.supportedLocales,
          localizationsDelegates: const [AppText.delegate],
          home: Builder(
            builder: (c) {
              negotiated = Localizations.localeOf(c);
              return Text(AppText.of(c)?.appName ?? 'NONE');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(negotiated.languageCode, kFallbackAppLocale.languageCode);
      expect(find.text('NONE'), findsNothing);
    });
  });
}
