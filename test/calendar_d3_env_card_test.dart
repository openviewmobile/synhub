// D3 回归网：日历「环境信息卡」在**极端组合**下必须保持可见。
//
// 背景（见 docs/ui-audit.md §5.2 D3）：矮屏压缩策略把卡片高度封顶为
// `_DayList 可用高度 − 40 × textScale`。`360×640 / en / x2.0` 时该上限会算成
// **0** —— 天气卡彻底不可见；而 1.0 缩放下 `40` 又小于日期操作行的真实高度
// （64），卡片 + 日期行会把下面的列表挤出屏幕（实测溢出 9.6px）。
//
// 修复（见 calendar_page.dart 的 `kEnvCardMinVisible` / `kDayListFloor`）：
// 预算 = 日期行 + 卡片(≥56) + 列表(≥56)；预算不够时切「紧凑布局」：日期操作行
// 收进可滚动列表、卡片独占剩余高度，并让 `CalendarEnvCard` 换 `dense` 只画一行
// 天气。这里把三条要求钉死：
//   ① 极端组合下卡片可见（非零布局高度 + 天气文案在视口内）；
//   ② 常规组合外观零回归（卡片不被裁）；
//   ③ 日格与天气卡**同时**可见（不许修好一个挤掉另一个），且无布局异常。
//
// ★ 第 270 轮：切换器标签由 `Month view / Week view / Day view` 缩成
// `Month / Week / Day`（中文 `月/周/日`），`SegmentedButton` 从**两行收成一行**，
// 释放了一行高度（实测 360×640/x2.0 的切换器 136→68，卡片视口 63.4→131.4）。
// 因此 **360×640 不再是"预算不足"的组合**（卡片视口 131.4 > 阈值 64 ⇒ 不再 dense）；
// 「预算不足 ⇒ 必须切 dense」的不变量下移到 **360×570 / en / x2.0**
// （实测卡片视口 63，仍 < 64），并把 360×640 上**新的更好行为**（不再 dense）
// 一并钉住 —— 不删测试、不放松断言。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
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
import 'package:synhub/src/data/weather/weather_client.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/calendar/calendar_env.dart';
import 'package:synhub/src/features/calendar/calendar_env_card.dart';
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

class _NoLocation implements DeviceLocationProbe {
  @override
  Future<LocationPermission> ensurePermission({
    bool interactive = true,
  }) async => LocationPermission.unsupported;

  @override
  Future<bool> serviceEnabled() async => false;

  @override
  Future<DeviceLocation?> current() async => null;

  @override
  Future<void> clearCache() async {}
}

/// 有"真实内容"的天气：卡片高度接近真机（空天气时卡片本来就矮，压不出问题）。
WeatherBundle _weather() => WeatherBundle(
  providerId: 'open-meteo',
  now: const WeatherNow(
    providerId: 'open-meteo',
    temperatureC: 24.3,
    apparentC: 26.5,
    humidity: 71,
    code: 3,
    windKmh: 20,
    windDir: '南风',
    pressureHpa: 1013.5,
  ),
  days: [
    for (var i = 0; i < 7; i++)
      WeatherDay(
        date: DateTime(2026, 9, 19 + i),
        code: 3,
        minC: 20 + i.toDouble(),
        maxC: 28 + i.toDouble(),
        precipitationMm: 0.2,
      ),
  ],
  hours: [
    for (var i = 0; i < 24; i++)
      WeatherHour(
        time: DateTime(2026, 9, 19, i),
        temperatureC: 22 + (i % 8).toDouble(),
        code: 3,
        precipitationProbability: 20,
      ),
  ],
);

Future<void> _pumpCalendar(
  WidgetTester tester, {
  required Size size,
  required double scale,
  required String lang,
}) async {
  final transport = FakeTransport(const {}, {
    ...FakeTransport.table,
    ..._calTable,
  });
  final api = DsmWebApi(transport);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final container = ProviderContainer(
    overrides: [
      calendarApiProvider.overrideWithValue(CalendarApi(api)),
      calendarRegionProvider.overrideWith(
        (ref) async => const RegionContext(
          countryCode: 'CN',
          city: '北京',
          timezone: 'Asia/Shanghai',
          latitude: 39.9042,
          longitude: 116.4074,
          source: RegionSource.manual,
        ),
      ),
      weatherBundleProvider.overrideWith((ref) async => _weather()),
      holidayBundleProvider.overrideWith((ref) async => null),
      deviceLocationProbeProvider.overrideWithValue(_NoLocation()),
    ],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child ?? const SizedBox.shrink(),
        ),
        home: const CalendarPage(),
      ),
    ),
  );
  // 待办要多一跳：Cal/list {cal_type:"todo"} → Todo/list（见 calendar_page_test）
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 卡片视口（`CalendarEnvCard` 外层那个 `SingleChildScrollView`）的尺寸。
Rect _cardViewport(WidgetTester tester) => tester.getRect(
  find
      .ancestor(
        of: find.byKey(const Key('cal-env-card')),
        matching: find.byType(SingleChildScrollView),
      )
      .first,
);

/// 月亮网格（`_MonthPager`）的矩形。
Rect _monthGrid(WidgetTester tester) => tester.getRect(
  find
      .byWidgetPredicate((w) => w.runtimeType.toString() == '_MonthPager')
      .first,
);

void main() {
  group('D3 环境卡可见性', () {
    // ① 审计点名的极端组合：矮屏 + 英文 + 2.0 缩放
    // ★ 第 270 轮：切换器收成一行后，360×640 已不再"预算不足"。这条用例
    // 下移到 360×570（实测卡片视口 63 < 阈值 64，真的必须 dense），
    // 「预算不足 ⇒ 必须切 dense + 卡片至少 kEnvCardMinVisible 高」的
    // 原始覆盖一条不少地保留；360×640 的新行为另有一条用例（下方 ①'）。
    testWidgets('360×570 / en / x2.0：预算不足 ⇒ 必须切 dense 且天气卡仍有非零可见高度', (
      tester,
    ) async {
      await _pumpCalendar(
        tester,
        size: const Size(360, 570),
        scale: 2.0,
        lang: 'en',
      );
      expect(tester.takeException(), isNull, reason: '极端组合不应再有布局异常');

      final viewport = _cardViewport(tester);
      expect(
        viewport.height,
        greaterThanOrEqualTo(kEnvCardMinVisible),
        reason: '旧算法在这里把卡片上限算成 0 —— 卡片必须至少 $kEnvCardMinVisible 高',
      );

      // 极端组合下应切到 dense：一行天气，整行都在卡片视口内
      final card = tester.widget<CalendarEnvCard>(find.byType(CalendarEnvCard));
      expect(card.dense, isTrue, reason: '预算不足时必须切换到 dense 紧凑卡片');
      expect(
        viewport.height,
        lessThan(kEnvCardDenseThreshold),
        reason: '这一组合必须真的低于 dense 阈值，否则用例没测到想测的分支',
      );
      final weather = tester.getRect(find.byKey(const Key('cal-env-weather')));
      expect(weather.height, greaterThan(0));
      expect(
        weather.top,
        greaterThanOrEqualTo(viewport.top - 0.5),
        reason: '天气行必须落在卡片视口内（顶部）',
      );
      expect(
        weather.bottom,
        lessThanOrEqualTo(viewport.bottom + 0.5),
        reason: '天气行必须完整可见，不能被卡片视口裁掉',
      );
    });

    // ①' 第 270 轮的新行为：同样 360×640 / en / x2.0，但切换器已收成一行，
    // 释放的高度让卡片视口涨到 131.4（> 阈值 64）⇒ **不再被强制 dense**。
    // 这条把"改动带来的改善"钉住，防止将来无意中又把它压回 dense。
    testWidgets('360×640 / en / x2.0：切换器收成一行后卡片不再 dense、天气行完整可见', (
      tester,
    ) async {
      await _pumpCalendar(
        tester,
        size: const Size(360, 640),
        scale: 2.0,
        lang: 'en',
      );
      expect(tester.takeException(), isNull, reason: '极端组合不应再有布局异常');

      final viewport = _cardViewport(tester);
      expect(
        viewport.height,
        greaterThanOrEqualTo(kEnvCardMinVisible),
        reason: '卡片必须至少 $kEnvCardMinVisible 高（保留 D3 原始不变量）',
      );
      final card = tester.widget<CalendarEnvCard>(find.byType(CalendarEnvCard));
      expect(card.dense, isFalse, reason: '切换器收成一行后释放了一行高度，卡片视口已超过 dense 阈值');
      expect(
        viewport.height,
        greaterThanOrEqualTo(kEnvCardDenseThreshold),
        reason: '不再 dense 的理由必须是"视口已过阈值"，不是别处把逻辑弄错',
      );
      // 天气块（卡片存在的理由）必须从视口内开始画。
      // ⚠️ 这里**不**断言"整张卡内容都在视口内"：360×640/x2.0 下卡片的自然高度
      // 约 537（含 7 天/逐小时趋势条），而卡片视口只有 131 —— 趋势条本来就该
      // 在卡内滚动（第 262 轮的既定口径）。本轮真正被钉住的改善是
      // "卡片不再被迫 dense、视口涨过阈值、天气数据从视口内开始可见"。
      final weather = tester.getRect(find.byKey(const Key('cal-env-weather')));
      expect(weather.height, greaterThan(0));
      expect(
        weather.top,
        greaterThanOrEqualTo(viewport.top - 0.5),
        reason: '天气块不能被视口上沿切掉',
      );
      expect(
        weather.top,
        lessThanOrEqualTo(viewport.bottom + 0.5),
        reason: '天气块必须从视口内开始画（不能被推到视口以下）',
      );
    });

    // ③ 日格与天气卡同时可见（同一极端组合）
    testWidgets('360×640 / en / x2.0：月网格与天气卡同时可见、互不遮挡', (tester) async {
      await _pumpCalendar(
        tester,
        size: const Size(360, 640),
        scale: 2.0,
        lang: 'en',
      );
      final grid = _monthGrid(tester);
      final viewport = _cardViewport(tester);
      expect(grid.height, greaterThan(0), reason: '月网格必须有高度');
      expect(grid.bottom, lessThanOrEqualTo(640), reason: '月网格不能被挤出屏幕');
      expect(viewport.height, greaterThan(0), reason: '天气卡必须有高度');
      expect(
        viewport.top,
        greaterThanOrEqualTo(grid.bottom - 0.5),
        reason: '天气卡不能压在月网格上',
      );
      expect(
        viewport.bottom,
        lessThanOrEqualTo(640 + 0.5),
        reason: '天气卡不能溢出屏幕底部',
      );
      // 日期操作行仍然可达（紧凑布局下它收进滚动列表，不是消失）
      await tester.pump();
      expect(find.byKey(const Key('cal-new-on-day')), findsOneWidget);
    });

    // ② 常规组合外观零回归：卡片自然高度 ≤ 预算时**不能被裁**
    for (final c in [
      (tag: '393x852/x1.0', size: const Size(393, 852), scale: 1.0),
      (tag: '800x1280/x1.0', size: const Size(800, 1280), scale: 1.0),
      (tag: '800x1280/x1.3', size: const Size(800, 1280), scale: 1.3),
    ]) {
      testWidgets('${c.tag}：常规组合下环境卡不被裁剪（外观零回归）', (tester) async {
        await _pumpCalendar(tester, size: c.size, scale: c.scale, lang: 'en');
        expect(tester.takeException(), isNull);
        final card = tester.widget<CalendarEnvCard>(
          find.byType(CalendarEnvCard),
        );
        expect(card.dense, isFalse, reason: '空间充足时不应触发 dense');
        final viewport = _cardViewport(tester);
        final natural = tester.getRect(
          find
              .ancestor(
                of: find.byKey(const Key('cal-env-card')),
                matching: find.byType(CalendarEnvCard),
              )
              .first,
        );
        expect(
          natural.height,
          lessThanOrEqualTo(viewport.height + 0.5),
          reason:
              '卡片内容应完整可见（viewport=${viewport.height}, '
              'natural=${natural.height}）',
        );
        // 日期操作行仍在卡片上方（常规布局未被紧凑布局替换）
        final header = tester.getRect(find.byKey(const Key('cal-new-on-day')));
        expect(header.bottom, lessThanOrEqualTo(viewport.top + 0.5));
      });
    }

    // 矩阵四尺寸 × 三缩放 × 两语言：卡片始终有非零可见高度
    for (final size in const [
      Size(360, 640),
      Size(393, 852),
      Size(411, 891),
      Size(800, 1280),
    ]) {
      for (final scale in const [1.0, 1.3, 2.0]) {
        for (final lang in const ['zh', 'en']) {
          testWidgets(
            '${size.width.toInt()}x${size.height.toInt()} / $lang / x$scale：'
            '环境卡可见高度 > 0 且无布局异常',
            (tester) async {
              await _pumpCalendar(tester, size: size, scale: scale, lang: lang);
              expect(tester.takeException(), isNull);
              final viewport = _cardViewport(tester);
              expect(
                viewport.height,
                greaterThan(0),
                reason: '任何组合下天气卡都不允许被压成 0 高',
              );
              expect(find.byKey(const Key('cal-env-weather')), findsOneWidget);
            },
          );
        }
      }
    }
  });

  // ---- 第 262 轮：这两处是**用户报的截断**，上面的断言管不到 --------------
  //
  // 上面那些用例只保证"天气行在视口内"；卡片视口是固定预算
  // （`ConstrainedBox(maxHeight: cardMax)`），内容比它高时**底部**会被切 ——
  // 而"数据出处行"原来正好在最底部，于是被切掉半行。方向：把出处行上移到
  // 天气行下面（数据紧贴它的出处），dense 模式也补上；副标题则靠**改短文案**
  // 解决（不许用 `FittedBox`，理由见 calendar_page.dart 里那段注释）。
  group('第 262 轮：出处行 / 头部副标题不再被截断', () {
    testWidgets('常规手机 393×852/x1.0：出处行完整落在卡片视口内', (tester) async {
      await _pumpCalendar(
        tester,
        size: const Size(393, 852),
        scale: 1.0,
        lang: 'en',
      );
      expect(tester.takeException(), isNull);
      final viewport = _cardViewport(tester);
      final src = tester.getRect(find.byKey(const Key('cal-env-source')));
      expect(src.height, greaterThan(0));
      expect(
        src.top,
        greaterThanOrEqualTo(viewport.top - 0.5),
        reason: '出处行顶部不能被卡片视口切掉',
      );
      expect(
        src.bottom,
        lessThanOrEqualTo(viewport.bottom + 0.5),
        reason: '出处行底部不能被卡片视口切掉（原文案在最底部时就是这样被裁的）',
      );
    });

    // ★ 第 270 轮：同样下移到 360×570（切换器收成一行后 360×640 已不 dense）。
    testWidgets('极端 360×570 / en / x2.0（dense）：出处行仍完整可见', (tester) async {
      await _pumpCalendar(
        tester,
        size: const Size(360, 570),
        scale: 2.0,
        lang: 'en',
      );
      expect(tester.takeException(), isNull);
      final card = tester.widget<CalendarEnvCard>(find.byType(CalendarEnvCard));
      expect(card.dense, isTrue, reason: '这一组合必须走 dense，否则用例没测到想测的分支');
      final viewport = _cardViewport(tester);
      final src = tester.getRect(find.byKey(const Key('cal-env-source')));
      expect(
        src.top,
        greaterThanOrEqualTo(viewport.top - 0.5),
        reason: 'dense 下出处行顶部也不能被切',
      );
      expect(
        src.bottom,
        lessThanOrEqualTo(viewport.bottom + 0.5),
        reason: 'dense 下出处行必须完整可见（它下面没有任何内容可以再让位）',
      );
    });

    // 实测（第 262 轮）：头部那行里，副标题能拿到的宽度只有 **105～137px**
    // （返回键 48 + 忙碌圈 + 「今天」按钮吃掉剩下的），而
    // `SYNOLOGY CALENDAR` 在 1.0 缩放下就要 **207px** ⇒ 手机上**必然**被省略号截断，
    // 这不是"文案再短一点"能解决的（用户报的就是这个）。
    // 所以口径改为：**放得下就完整画，放不下就整行不画**，任何情况下都不许出现
    // 被截断的半截文案；宽屏（平板）上仍然能完整看到。
    for (final lang in const ['zh', 'en']) {
      testWidgets('副标题在手机 393×852 / $lang / x1.0：宁可整行不画，也不截断', (
        tester,
      ) async {
        await _pumpCalendar(
          tester,
          size: const Size(393, 852),
          scale: 1.0,
          lang: lang,
        );
        final para = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('cal-subtitle')),
        );
        expect(para.didExceedMaxLines, isFalse, reason: '副标题被省略号截断了');
        expect(
          para.text.toPlainText().trim(),
          '',
          reason: '手机宽度放不下（实测可用 105～137px < 文案 207px）⇒ 整行不画',
        );
      });

      testWidgets('副标题在宽屏 800×1280 / $lang / x1.0：完整显示（功能没被删掉）', (
        tester,
      ) async {
        await _pumpCalendar(
          tester,
          size: const Size(800, 1280),
          scale: 1.0,
          lang: lang,
        );
        final para = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('cal-subtitle')),
        );
        expect(para.didExceedMaxLines, isFalse);
        expect(
          para.text.toPlainText(),
          'Synology Calendar',
          reason: '宽屏上副标题必须真的画出来（文案长度也不许再长回去）',
        );
      });

      testWidgets('副标题在 360×640 / $lang / x2.0 也不许被截断', (tester) async {
        await _pumpCalendar(
          tester,
          size: const Size(360, 640),
          scale: 2.0,
          lang: lang,
        );
        final para = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('cal-subtitle')),
        );
        expect(
          para.didExceedMaxLines,
          isFalse,
          reason: '副标题又被省略号截断了：放不下就该整行不画',
        );
        expect(para.text.toPlainText().trim(), '');
      });
    }
  });

      // ★ r520（DA161，真机像素）：紧凑布局下这块列表只剩 ~24–56 逻辑高，
      // 塞 `AppEmptyState`（图标 56 + 标题 + 副文案 ≈ 120）只会露出半截标题，
      // 右边还被悬浮的「日程」FAB 压住。紧凑布局必须改画**一行**提示。
      // ★ r520（DA161，真机像素）：日历页下半区在真机上只有 ~374 逻辑高，
      // 整块 `AppEmptyState` 会被下边缘截断、右边被悬浮的「日程」FAB 压住。
      // 判据：不够高（<640）⇒ 画一行提示并给 FAB 让位；够高 ⇒ 仍是整块空态。
      testWidgets('DA161：不够高时画一行提示并给 FAB 让位', (tester) async {
        await _pumpCalendar(
          tester,
          size: const Size(390, 814),
          scale: 1.0,
          lang: 'en',
        );
        final hint = find.byKey(const Key('cal-day-empty-hint'));
        expect(hint, findsOneWidget,
            reason: 'DA161：真机尺寸下应改画一行提示');
        final pad = tester.widget<Padding>(hint).padding as EdgeInsets;
        expect(pad.right, greaterThanOrEqualTo(96),
            reason: 'DA161：没有给 FAB 让出右边距，文字会钻到按钮底下');
        expect(find.text(lookupAppText(const Locale('en')).calDayNoEventsTitle),
            findsOneWidget,
            reason: 'DA161：一行提示的文案必须是"这一天没有日程"');
      });

      testWidgets('DA161 反向：够高（≥640）时仍画整块空态', (tester) async {
        await _pumpCalendar(
          tester,
          size: const Size(1200, 1600),
          scale: 1.0,
          lang: 'en',
        );
        expect(find.byKey(const Key('cal-day-empty-hint')), findsNothing,
            reason: 'DA161：大屏不该退化成一行');
      });

}
