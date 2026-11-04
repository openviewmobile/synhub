// 整页天气动画背景（虚化）的测试。
//
// 用户要求："整块日历的背景是否可以展示当天天气的动画作为背景，不过这个背景需要
// 虚化，避免遮挡前面的日历文字" —— 所以这里钉三件事：
//   1. WMO 天气码 → 场景的归类；
//   2. 每个场景都画得出来（不抛异常、不无限重绘 → `pumpAndSettle` 能停）；
//   3. 内容永远在动画**上面**（文字不被虚化/遮挡），关掉开关时整层消失。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/calendar/weather_backdrop.dart';

Future<void> _pump(
  WidgetTester tester, {
  required WeatherScene scene,
  bool enabled = true,
}) async {
  tester.view.physicalSize = const Size(1148, 2492);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: WeatherBackdrop(
          scene: scene,
          enabled: enabled,
          child: const Center(child: Text('日历文字')),
        ),
      ),
    ),
  );
  // 常驻动效在测试里是关的（`AppEffects.ambientAllowed`），所以一次就停
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  test('日出日落解析：ISO 串和 HH:mm 都要认（真机 ISO 踩过坑）', () {
    // Open-Meteo 真机格式
    expect(clockMinutes('2026-09-23T05:48'), 5 * 60 + 48);
    expect(clockText('2026-09-23T05:48'), '05:48');
    expect(clockText('2026-09-23T17:55'), '17:55');
    // 另一种源的短格式
    expect(clockMinutes('05:48'), 5 * 60 + 48);
    expect(clockText('5:48'), '05:48');
    // 解析不出来 → null / 空串（UI 不显示这一行，而不是显示脏串）
    expect(clockMinutes(''), isNull);
    expect(clockText('—'), '');
    expect(clockText('2026-09-23'), '');
  });

  test('白天/夜里判定：日出前、日落后算夜里', () {
    const sunrise = '2026-09-23T05:48';
    const sunset = '2026-09-23T17:55';
    DateTime at(int h, int m) => DateTime(2026, 9, 23, h, m);
    expect(isNightNow(sunrise: sunrise, sunset: sunset, now: at(3, 0)), isTrue);
    expect(
      isNightNow(sunrise: sunrise, sunset: sunset, now: at(5, 47)),
      isTrue,
    );
    expect(
      isNightNow(sunrise: sunrise, sunset: sunset, now: at(5, 48)),
      isFalse,
      reason: '正好日出算白天',
    );
    expect(
      isNightNow(sunrise: sunrise, sunset: sunset, now: at(12, 0)),
      isFalse,
    );
    expect(
      isNightNow(sunrise: sunrise, sunset: sunset, now: at(17, 55)),
      isTrue,
      reason: '正好日落算夜里',
    );
    // 缺数据 → 保守当白天（宁可显示日光，也别在中午画星星）
    expect(isNightNow(sunrise: '', sunset: '', now: at(23, 0)), isFalse);
  });

  test('天气码归类：晴/云/雾/雨/雪/雷都认', () {
    expect(weatherSceneForCode(0), WeatherScene.clearDay);
    expect(weatherSceneForCode(1), WeatherScene.clearDay);
    expect(weatherSceneForCode(2), WeatherScene.cloudy);
    expect(weatherSceneForCode(3), WeatherScene.cloudy);
    expect(weatherSceneForCode(45), WeatherScene.fog);
    expect(weatherSceneForCode(48), WeatherScene.fog);
    expect(weatherSceneForCode(51), WeatherScene.rain);
    expect(weatherSceneForCode(61), WeatherScene.rain);
    expect(weatherSceneForCode(67), WeatherScene.rain);
    expect(weatherSceneForCode(71), WeatherScene.snow);
    expect(weatherSceneForCode(75), WeatherScene.snow);
    expect(weatherSceneForCode(86), WeatherScene.snow);
    expect(weatherSceneForCode(80), WeatherScene.rain);
    expect(weatherSceneForCode(82), WeatherScene.rain);
    expect(weatherSceneForCode(95), WeatherScene.thunder);
    expect(weatherSceneForCode(99), WeatherScene.thunder);
    // 没拿到天气码 → 中性多云（不抢眼）
    expect(weatherSceneForCode(null), WeatherScene.cloudy);
    // 未知码也不崩
    expect(weatherSceneForCode(1234), WeatherScene.cloudy);
  });

  testWidgets('七种场景都画得出来，且文字在动画上面', (tester) async {
    for (final scene in WeatherScene.values) {
      await _pump(tester, scene: scene);
      expect(find.text('日历文字'), findsOneWidget, reason: '${scene.label}：内容必须在');
      // 粒子层 + 色晕都画了
      expect(
        find.byKey(const Key('weather-backdrop-wash')),
        findsOneWidget,
        reason: '${scene.label}：色晕层',
      );
      expect(
        find.byKey(const Key('weather-backdrop-particles')),
        findsOneWidget,
        reason: '${scene.label}: 粒子层',
      );
      // 内容是这个 Stack 的最后一个孩子 → 后画 = 在上面（不会被虚化盖住）
      final stack = tester.widget<Stack>(find.byType(Stack).first);
      expect(stack.children.last, isA<Positioned>(), reason: scene.label);
      final last = stack.children.last as Positioned;
      expect(last.child, isNotNull, reason: '${scene.label}: 最后一个孩子是内容层');
      expect(tester.takeException(), isNull, reason: scene.label);
    }
  });

  testWidgets('关掉开关 → 动画层整层消失（只剩内容）', (tester) async {
    await _pump(tester, scene: WeatherScene.rain, enabled: false);
    expect(find.text('日历文字'), findsOneWidget);
    // 关掉时直接返回 child：两层背景都不在
    expect(find.byKey(const Key('weather-backdrop-wash')), findsNothing);
    expect(find.byKey(const Key('weather-backdrop-particles')), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('虚化开着时用 ImageFiltered 包住粒子层', (tester) async {
    await _pump(tester, scene: WeatherScene.snow);
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('不同场景的主色不一样（雨偏蓝、雪偏白、晴偏暖）', (tester) async {
    final rain = WeatherScene.rain.tint(Brightness.dark);
    final snow = WeatherScene.snow.tint(Brightness.dark);
    final sun = WeatherScene.clearDay.tint(Brightness.dark);
    expect(rain, isNot(snow));
    expect(snow, isNot(sun));
    // 亮的要更亮：雪 > 雨
    expect(snow.computeLuminance(), greaterThan(rain.computeLuminance()));
  });
}
