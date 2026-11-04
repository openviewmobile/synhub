// 均衡器页的设计语言回归（r479，DA114）。
//
// 为什么要单独一条 widget 用例：这一页原来整页是 `SwitchListTile` +
// `ListTile` 的裸 Material 默认样式，与设置页/单曲页不是一套语言；
// 而在此之前**没有任何用例真正渲染过这一页**（只有控制器与降级守卫），
// 所以"换成设计组件"这件事**不可能被测试发现**。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/features/audio/audio_equalizer.dart';

class _FakeEq extends AudioEqualizerController {
  _FakeEq(this.seed);

  final AudioEqualizerState seed;

  @override
  AudioEqualizerState build() => seed;
}

Future<void> _pump(WidgetTester tester, AudioEqualizerState state) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        audioEqualizerProvider.overrideWith(() => _FakeEq(state)),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: const AudioEqualizerPage()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('DA114：可用时用设计组件（组标题 + 行卡 + 说明卡），不用裸 ListTile', (
    tester,
  ) async {
    await _pump(
      tester,
      const AudioEqualizerState(loaded: true, available: true, enabled: true),
    );

    // 组标题（设计组件）在，`SwitchListTile` 一个都不该有。
    expect(find.byType(DesignSectionHeader), findsWidgets);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    // 键位一个都没少（既有用例与真机走查都靠它们）。
    expect(find.byKey(const Key('as-eq-enable')), findsOneWidget);
    expect(find.byKey(const Key('as-eq-gapless-hint')), findsOneWidget);
    expect(find.byKey(const Key('as-eq-no-presets')), findsOneWidget);
    // 有预设时，预设行也是设计行卡。
    expect(find.byType(DesignRowTile), findsWidgets);
    // 页面曝光会排一个统计落盘的定时器（`usage_log` 的 flush，5s）；
    // 用例结束前放它跑完，否则会被判 "A Timer is still pending"（与断言无关）。
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('DA114：不可用时的空态与键位不变（降级不靠删入口）', (tester) async {
    await _pump(
      tester,
      const AudioEqualizerState(loaded: true, available: false),
    );
    expect(find.byKey(const Key('as-eq-unsupported')), findsOneWidget);
    expect(find.byKey(const Key('as-eq-enable')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });
}
