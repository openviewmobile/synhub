// Chromecast 投送页的设计语言回归（r480，DA115）。
//
// 这一页此前**没有任何用例渲染过 UI**（只有 C3 那组控制器/平台通道用例），
// 所以"换成设计组件"不可能被测试发现 —— 这条把它补上。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/features/audio/audio_cast.dart';
import 'package:synhub/src/features/audio/audio_cast_page.dart';

class _FakeCast extends AudioCastController {
  _FakeCast(this.seed);

  final AudioCastState seed;

  @override
  AudioCastState build() => seed;

  // 页面 `initState` 会调 `preload()` 真的去问平台通道（本机无 GMS ⇒ 会把
  // 我们塞进去的"有设备"状态覆盖掉）。这条用例只验**渲染**，所以把预载置空。
  @override
  Future<void> preload() async {}
}

Future<void> _pump(WidgetTester tester, AudioCastState state) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [audioCastProvider.overrideWith(() => _FakeCast(state))],
      child: MaterialApp(theme: AppTheme.dark(), home: const AudioCastPage()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('DA115：本机不支持 → 说明卡 + 替代路提示，键位不变', (tester) async {
    await _pump(
      tester,
      const AudioCastState(loaded: true, available: false),
    );
    expect(find.byKey(const Key('as-cast-unsupported')), findsOneWidget);
    // 设计语言的说明卡（不是裸 Text / 裸 ListTile）
    expect(find.byType(DesignNote), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
    // spec 第二句"可以改用 DLNA"必须在屏上（不是只有"不支持"三个字）
    expect(find.textContaining('DLNA'), findsWidgets);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('DA115：有设备 → 是设计行卡（不是裸 ListTile），且连接按钮在', (tester) async {
    await _pump(
      tester,
      const AudioCastState(
        loaded: true,
        available: true,
        devices: [AudioCastDevice(id: 'dev-1', name: 'Living room TV')],
      ),
    );
    expect(find.byType(DesignRowTile), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byKey(const Key('as-cast-device-0')), findsOneWidget);
    expect(find.byKey(const Key('as-cast-connect-0')), findsOneWidget);
    expect(find.byKey(const Key('as-cast-current')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });
}
