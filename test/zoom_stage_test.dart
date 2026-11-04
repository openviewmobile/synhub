// 可缩放舞台（ZoomStage）的行为契约：
//   * 双指捏合 / 双击都能缩放，再双击复位
//   * 放大后单指横滑**不翻页**（交给平移），未放大时横滑翻页
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/media/zoom_stage.dart';

Widget _host({ValueChanged<bool>? onZoom, int resetSignal = 0}) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: PageView.builder(
      itemCount: 3,
      itemBuilder: (_, i) => ZoomStage(
        onZoomChanged: onZoom,
        resetSignal: resetSignal,
        child: Center(
          child: Container(
            key: Key('pic$i'),
            width: 100,
            height: 100,
            color: Colors.blue,
          ),
        ),
      ),
    ),
  ),
);

Future<void> _pinch(WidgetTester t, {required bool out}) async {
  final c = t.getCenter(find.byType(ZoomStage).first);
  final a = await t.startGesture(c - const Offset(20, 0));
  final b = await t.startGesture(c + const Offset(20, 0));
  // 捏开：a 往左、b 往右（写反了就是捏合，两端会互相越过、净缩放仍是 1）
  final d = out ? const Offset(-60, 0) : const Offset(15, 0);
  await a.moveBy(d);
  await b.moveBy(-d);
  await t.pump();
  await a.up();
  await b.up();
  await t.pumpAndSettle();
}

void main() {
  testWidgets('双指捏合放大，双击复位', (tester) async {
    final zoomEvents = <bool>[];
    await tester.pumpWidget(_host(onZoom: zoomEvents.add));
    await _pinch(tester, out: true);
    expect(zoomEvents, [true], reason: '捏合放大要报一次已放大');
  });

  testWidgets('未放大时横滑能翻页', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.byKey(const Key('pic0')), findsOneWidget);
    await tester.fling(
      find.byType(ZoomStage).first,
      const Offset(-400, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pic1')), findsOneWidget, reason: '未放大时横滑应该翻页');
  });

  testWidgets('双击放大 → 再双击复位，且放大状态各报一次', (tester) async {
    final events = <bool>[];
    await tester.pumpWidget(_host(onZoom: events.add));
    final center = tester.getCenter(find.byKey(const Key('pic0')));

    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(events, [true], reason: '双击放大要报"已放大"');

    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(events, [true, false], reason: '再双击要报"已复位"');
  });

  testWidgets('resetSignal 变化（翻页）后缩放清掉', (tester) async {
    final events = <bool>[];
    await tester.pumpWidget(_host(onZoom: events.add));
    await _pinch(tester, out: true);
    expect(events, [true], reason: '先捏开放大');

    // 翻页：外层把 resetSignal +1 → 缩放应当自己清回原始大小并报"已复位"
    await tester.pumpWidget(_host(onZoom: events.add, resetSignal: 1));
    await tester.pumpAndSettle();
    expect(events, [true, false], reason: '复位后要报"已复位"');

    await tester.fling(
      find.byType(ZoomStage).first,
      const Offset(-400, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pic1')), findsOneWidget, reason: '复位后可翻页');
  });
}
