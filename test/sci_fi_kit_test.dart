// 科幻层组件库的离线验证。
//
// 重点不是"好不好看"（那要在真机上看），而是**行为安全**：
//   1. 常驻动效在测试里必须完全不动（否则 `pumpAndSettle` 永远不返回）；
//   2. 一次性动效（光扫 / 启动自检）必须是有限的，且能跳过；
//   3. 能量核仍然是个可点、可无障碍识别的控件；
//   4. 面板的遥测/刻度/括号不能把内容挤坏（不溢出）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/core/ui/app_states.dart';
import 'package:synhub/src/core/ui/boot_sequence.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/core/ui/field_backdrop.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/ui/tech_frame.dart';

Widget _wrap(Widget child) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('测试环境里常驻动效一律禁用', () {
    expect(
      AppEffects.isFlutterTest,
      isTrue,
      reason: 'flutter test 会设 FLUTTER_TEST',
    );
    expect(
      AppEffects.ambientAllowed,
      isFalse,
      reason: '否则 pumpAndSettle 永远不返回',
    );
    // 关掉"减少动效"也一样是关
    AppEffects.reducedMotion.value = true;
    expect(AppEffects.ambientAllowed, isFalse);
    AppEffects.reducedMotion.value = false;
  });

  testWidgets('TechFrame：遥测头/角括号/刻度都在，且内容不溢出', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SizedBox(
          width: 320,
          child: TechFrame(
            label: 'ENDPOINT',
            code: '0x1F',
            child: Text('nas.example.com:5001'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ENDPOINT'), findsOneWidget);
    expect(find.text('0x1F'), findsOneWidget);
    expect(find.text('nas.example.com:5001'), findsOneWidget);
    expect(find.byType(CornerBrackets), findsOneWidget);
    expect(find.byType(EdgeTicks), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TechFrame(sweep)：光扫是一次性的，能等到停帧', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SizedBox(
          width: 300,
          height: 120,
          child: TechFrame(sweep: true, label: 'BOOT', child: Text('core')),
        ),
      ),
    );
    // 光扫最长 900ms + 120ms 延迟；pumpAndSettle 能返回就说明它是有限的
    await tester.pumpAndSettle();
    expect(find.text('core'), findsOneWidget);
  });

  testWidgets('TelemetryRow：键与值都在，点线引导不占文字空间', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SizedBox(
          width: 300,
          child: TelemetryRow(label: 'PROTO', value: 'SRM 1.3'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('PROTO'), findsOneWidget);
    expect(find.text('SRM 1.3'), findsOneWidget);
  });

  testWidgets('DataStrip：测试里静止显示全部条目（不滚动）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SizedBox(
          width: 260,
          child: DataStrip(
            prefix: 'LINK',
            items: ['nas.example.com:5001', 'SRM 1.3', 'AES-256'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('nas.example.com:5001'), findsOneWidget);
    expect(find.textContaining('AES-256'), findsOneWidget);
  });

  testWidgets('EnergyOrb：可点、显示 label 与进度、带无障碍标签', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        EnergyOrb(
          label: '连接',
          progress: 0.42,
          caption: 'nas.example.com:5001',
          semanticLabel: '连接服务器',
          onTap: () => taps++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('连接'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('nas.example.com:5001'), findsOneWidget);
    expect(find.bySemanticsLabel('连接服务器'), findsOneWidget);

    await tester.tap(find.byType(EnergyOrb));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('FieldBackdrop：测试里静止（0 帧），子内容照常可用', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const FieldBackdrop(
          child: SizedBox(width: 200, height: 200, child: Text('content')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('content'), findsOneWidget);
    // 静止时不该还有待处理的帧
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('BootSequence：测试里不播（直接显示内容），真机才播', (tester) async {
    expect(BootSequence.shouldPlay, isFalse);
    await tester.pumpWidget(_wrap(const BootSequence(child: Text('under'))));
    await tester.pumpAndSettle();
    expect(find.text('under'), findsOneWidget);
    expect(find.text('SYSTEM BOOT'), findsNothing);
  });

  testWidgets('BootSequence(enabled: true)：会播，点一下能跳过', (tester) async {
    await tester.pumpWidget(
      _wrap(const BootSequence(enabled: true, child: Text('under'))),
    );
    await tester.pump();
    expect(find.text('SYSTEM BOOT'), findsOneWidget);
    expect(find.text('TAP TO SKIP'), findsOneWidget);

    await tester.tap(find.text('SYSTEM BOOT'));
    await tester.pumpAndSettle();
    expect(find.text('SYSTEM BOOT'), findsNothing);
    expect(find.text('under'), findsOneWidget);
  });

  testWidgets('常驻动效在测试环境必须静止（不许无条件 repeat）', (tester) async {
    // 这一条是被真机逼出来的：骨架屏原来无条件 `repeat(reverse: true)`，
    // 真机上 `uiautomator` 永远等不到 idle，测试里 `pumpAndSettle` 也不收敛。
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Column(
            children: [
              AppSkeleton(width: 120),
              DataStrip(items: ['SRM 1.3', 'AES-256-GCM', '12 ms']),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(AppEffects.ambientAllowed, isFalse, reason: '测试环境必须关闭常驻动效');
    expect(tester.binding.hasScheduledFrame, isFalse, reason: '静止时不该再有下一帧');
  });
}
