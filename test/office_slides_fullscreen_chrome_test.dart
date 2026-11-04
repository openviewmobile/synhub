// O3（`.oslides` 重做）—— **全屏放映工具条的显示/隐藏**用例。
//
// ## 用户报的 bug（原话）
// > "oslides 全屏之后工具条 3 秒隐藏之后再没有机会显示了，这个分析排查修复下"
//
// ## 本组要钉住的交互契约
// 1. 进入全屏 => 工具条**可见**，3 秒后**自动隐藏**；
// 2. 隐藏后，**点屏幕顶部** => 工具条**重新出现**（★ 这就是坏掉的那条）；
// 3. 可以**反复**显示/隐藏（不是只有第一次能显示）；
// 4. 点中部/底部（非顶部）=> **不**显示工具条，而是**翻页**（既有语义，不能被修坏）；
// 5. 拖动/捏合（位移 > 阈值）=> 不算点按，不切换工具条。
//
// ## 根因（先写在这里，用例在下面复现）
// `Listener` 的 `behavior` 默认是 `HitTestBehavior.deferToChild` ——
// 只有当**子节点被命中**时父 `Listener` 才收得到指针事件。
// 而"显示工具条"的热区是**屏幕顶部 12%**，那一片通常正好落在
// 幻灯片（`SlideCanvas` 居中）**之外的空白带**上，子节点没被命中
// ⇒ `onPointerUp` **根本不会被调用** ⇒ 工具条再也出不来。
// 修法：把 `Listener.behavior` 显式设为 `HitTestBehavior.opaque`。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_slides_deck_view.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_slides_o3/$name').readAsBytesSync();

late OSlidesDeck _deck;

Widget _host(Widget child) => MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));

Future<void> _openFullscreen(WidgetTester tester) async {
  await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
  await tester.pump();
  await tester.tap(find.byKey(const Key('office-slides-fullscreen')));
  await tester.pumpAndSettle();
}

Finder get _chrome => find.byKey(const Key('office-slides-fullscreen-chrome'));

/// 让自动隐藏定时器到点。
Future<void> _waitAutoHide(WidgetTester tester) async {
  await tester.pump(_OfficeSlidesFullscreenTestHooks.chromeAutoHide);
  await tester.pump();
}

void main() {
  setUpAll(() {
    _deck = OSlidesDeck.parse(_fixture('technology.oslides'))!;
  });

  testWidgets('F1. 进全屏工具条可见；3 秒后自动隐藏', (tester) async {
    await _openFullscreen(tester);
    expect(_chrome, findsOneWidget, reason: '刚进全屏必须能看到工具条');
    await _waitAutoHide(tester);
    expect(_chrome, findsNothing, reason: '3 秒后必须自动隐藏');
  });

  testWidgets('F2. ★ 用户报的 bug：隐藏后**点顶部**必须能够重新显示工具条', (tester) async {
    await _openFullscreen(tester);
    await _waitAutoHide(tester);
    expect(_chrome, findsNothing, reason: '前置条件：已经自动隐藏了');

    // 屏幕**顶部**（12% 热区内）。这里用真实几何算，不硬写数字。
    final view = tester.getRect(
      find.byKey(const Key('office-slides-fullscreen-view')),
    );
    final topTap = Offset(view.center.dx, view.top + view.height * 0.05);
    await tester.tapAt(topTap);
    await tester.pump();

    expect(
      _chrome,
      findsOneWidget,
      reason:
          '点顶部必须把工具条叫回来（这就是用户报的那条）。'
          '点的是 $topTap，视图矩形 $view',
    );
  });

  testWidgets('F3. 可以**反复**显示/隐藏（不是只有第一次能叫回来）', (tester) async {
    await _openFullscreen(tester);
    final view = tester.getRect(
      find.byKey(const Key('office-slides-fullscreen-view')),
    );
    final topTap = Offset(view.center.dx, view.top + view.height * 0.05);

    for (var round = 0; round < 3; round++) {
      await _waitAutoHide(tester);
      expect(_chrome, findsNothing, reason: '第 $round 轮：应已自动隐藏');
      await tester.tapAt(topTap);
      await tester.pump();
      expect(_chrome, findsOneWidget, reason: '第 $round 轮：点顶部应能叫回');
    }
  });

  testWidgets('F4. 点中部是**翻页**，不是切换工具条（既有语义不能被修坏）', (tester) async {
    await _openFullscreen(tester);
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('office-slides-fullscreen-indicator')),
          )
          .data,
      '1 / ${_deck.slides.length}',
    );
    final view = tester.getRect(
      find.byKey(const Key('office-slides-fullscreen-view')),
    );
    // 中部（远离顶部 12% 热区）。
    await tester.tapAt(Offset(view.center.dx, view.center.dy));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('office-slides-fullscreen-indicator')),
          )
          .data,
      '2 / ${_deck.slides.length}',
      reason: '点中部应翻到下一页',
    );
    expect(_chrome, findsOneWidget, reason: '翻页顺带把工具条留着（不应消失）');
  });

  testWidgets('F2b. 真机几何（375×814 竖屏，dpr 3.0625）下点顶部也必须能叫回', (tester) async {
    tester.view.physicalSize = const Size(1148, 2492);
    tester.view.devicePixelRatio = 490 / 160;
    addTearDown(tester.view.reset);
    await _openFullscreen(tester);
    await _waitAutoHide(tester);
    expect(_chrome, findsNothing);

    final view = tester.getRect(
      find.byKey(const Key('office-slides-fullscreen-view')),
    );
    // ignore: avoid_print
    print('PROBE view=$view  hot=${view.top + view.height * 0.12}');
    final canvas = tester.getRect(
      find.byKey(const Key('office-slides-canvas-0')),
    );
    // ignore: avoid_print
    print('PROBE canvas=$canvas');

    // 紧贴 safe area 下方 15px 处点一下（真机上就是"最顶部能点的位置"）。
    await tester.tapAt(Offset(view.center.dx, view.top + 15));
    await tester.pump();
    // ignore: avoid_print
    print('PROBE after-tap-chrome=${_chrome.evaluate().length}');
    expect(_chrome, findsOneWidget, reason: '真机几何下点最顶部也必须能叫回工具条');
  });

  testWidgets('F6. ★ 隐藏状态下点**任意位置**都唤回工具条，且**不翻页**（真机踩的坑）', (tester) async {
    await _openFullscreen(tester);
    final view = tester.getRect(
      find.byKey(const Key('office-slides-fullscreen-view')),
    );
    String indicator() => tester
        .widget<Text>(
          find.byKey(const Key('office-slides-fullscreen-indicator')),
        )
        .data!;

    // 真机上用户的本能位置：屏幕中部 / 下部 / 上部偏中。
    for (final f in <double>[0.5, 0.8, 0.35]) {
      // 前置：先把工具条弄成隐藏态（可见时点顶部 12% 即隐藏）。
      if (_chrome.evaluate().isNotEmpty) {
        await tester.tapAt(
          Offset(view.center.dx, view.top + view.height * 0.05),
        );
        await tester.pump();
      }
      expect(_chrome, findsNothing, reason: '前置：应为隐藏态');
      final before = _pageIndex(tester);
      await tester.tapAt(Offset(view.center.dx, view.top + view.height * f));
      await tester.pump();
      expect(
        _chrome,
        findsOneWidget,
        reason: '点 ${(f * 100).round()}% 高度处必须唤回工具条（这就是用户报的那条）',
      );
      expect(_pageIndex(tester), before, reason: '唤回工具条的那一下**不许同时翻页**');
    }
    expect(indicator(), '1 / ${_deck.slides.length}', reason: '整段过程不应翻页');
  });

  testWidgets('F5. 拖动（位移 > 阈值）不算点按 ⇒ 不切换工具条', (tester) async {
    await _openFullscreen(tester);
    await _waitAutoHide(tester);
    expect(_chrome, findsNothing);
    final view = tester.getRect(
      find.byKey(const Key('office-slides-fullscreen-view')),
    );
    final start = Offset(view.center.dx, view.top + view.height * 0.06);
    await tester.dragFrom(start, const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(_chrome, findsNothing, reason: '拖动过阈值 ⇒ 不是点按，工具条不该被叫出来');
  });
}

/// 当前页索引（0-based），直接读 `PageView` 的控制器（与工具条是否可见无关）。
int _pageIndex(WidgetTester tester) {
  final pv = tester.widget<PageView>(
    find.byKey(const Key('office-slides-fullscreen-pages')),
  );
  return (pv.controller as PageController).page?.round() ?? 0;
}

/// 把被测常量引到这里，避免用例里出现"魔法数字"（改常量时用例自动跟随）。
class _OfficeSlidesFullscreenTestHooks {
  static Duration get chromeAutoHide =>
      OfficeSlidesFullscreenView.chromeAutoHide;
}
