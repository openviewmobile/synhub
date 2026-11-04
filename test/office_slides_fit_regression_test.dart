// 真机缺陷回归：**主画布必须"适配视口"，不能按 1:1 原生像素画**。
//
// ## 真机现象（2026-09-22，HONOR LGE-AN10，Dynamic.oslides）
// * 缩略图栏里每页**有真实内容**（渐变图 / 深蓝底+红条+白形状）；
// * 右侧**主画布一片空白**，用户"打开 PPT 只能看到一排小图"。
//
// ## 假设（本用例去证实/否证）
// 缩略图栏用 `SlideCanvas(compact: true)`，**外面没有** `InteractiveViewer`；
// 主画布被 `Center(child: InteractiveViewer(child: SlideCanvas(...)))` 包着。
// 若 `InteractiveViewer` 给子节点的是**无界约束**，`SlideCanvas` 的
// `LayoutBuilder` 会走 `availW = w` 兜底（= 幻灯片原生 px，1280×720），
// 于是 `scale = 1` ⇒ 画布按 **1:1** 绘制 ⇒ 在 ~600px 宽的视口里
// 只能看到左上角一块 ⇒ **看起来像空白**。
//
// ## 为什么 O3 的 43 条用例没抓到
// 它们对画布只断言**宽高比**（`closeTo(16/9)`）与**相对位置**，
// 一个 1280×720 的 1:1 画布**完全能通过**。
//
// ## 本用例的不变量
// **主画布尺寸必须 ≤ 它所在视口的尺寸**（即真的"适配"，而不是被裁掉）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_slides_deck_view.dart';

void main() {
  late OSlidesDeck deck;

  setUpAll(() {
    deck = OSlidesDeck.parse(
      File(
        'test/fixtures/office_slides_o3/technology.oslides',
      ).readAsBytesSync(),
    )!;
  });

  testWidgets('★ 主画布必须适配视口（不得按 1:1 原生像素画后被裁掉）', (tester) async {
    // 模拟手机竖屏：360dp 宽 × 640dp 高（与 ui_overflow_audit 同规格）。
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: OfficeSlidesDeckView(deck: deck, showThumbnails: true),
        ),
      ),
    );
    await tester.pump();

    final canvas = tester.renderObject<RenderBox>(
      find.byKey(const Key('office-slides-canvas-0')),
    );
    final pager = tester.renderObject<RenderBox>(
      find.byKey(const Key('office-slides-pages')),
    );

    // 屏宽 360dp；缩略图栏占一部分，主画布区必定更窄。
    expect(pager.size.width, lessThanOrEqualTo(360.0));

    // ★ 核心断言：画布宽度不得超过主画布区宽度。
    expect(
      canvas.size.width,
      lessThanOrEqualTo(pager.size.width + 0.5),
      reason:
          '主画布宽 ${canvas.size.width} 超过主画布区宽 ${pager.size.width} '
          '⇒ 画布按 1:1 原生像素绘制、被裁掉，真机上表现为"空白"',
    );
    expect(
      canvas.size.height,
      lessThanOrEqualTo(pager.size.height + 0.5),
      reason: '主画布高 ${canvas.size.height} 超过主画布区高 ${pager.size.height}',
    );
  });
}
