// 真机缺陷回归（2026-09-22）：幻灯片内容**不得被缩放两次**。
//
// ## 缺陷现象（真机 HONOR LGE-AN10，`Dynamic.oslides`）
// 主画布只画出一小块内容（实测内容包围盒 **62x35 dp**），其余是脚手架底色；
// 缩略图栏里也只有很小的图能看见。
//
// ## 根因（已确证，非猜测）
// `SlideCanvas.build` 的结构是：
// ```dart
// SizedBox(width: w*scale, height: h*scale,          // ← 外层：紧约束
//   child: ClipRect(child: Transform.scale(scale: scale,
//     child: SizedBox(width: w, height: h,           // ← 内层：本该 960x540
//       child: Stack(...)))))
// ```
// 外层 `SizedBox` 给出的是**紧约束**（`w*scale x h*scale`，真机上是 243x137），
// 而 `Transform.scale` 是 `RenderProxyBox`，**原样把紧约束下传**。
// 于是内层 `SizedBox(width: w, height: h)` 的尺寸被 `BoxConstraints.enforce`
// **压成 243x137**，紧接着 `Transform.scale(0.253)` **又把它缩一次**
// ⇒ 内容只占 `w*scale^2`：
// ```
// 960 * 0.25298^2 = 61.43 dp     ← 与真机实测 62 dp 吻合
// ```
//
// ## 为什么之前的用例没抓到
// `Transform.scale` **只影响绘制、不影响布局**，所以外层 `SizedBox(243x137)` 一直是对的。
// 既有的 `office_slides_fit_regression_test.dart` 断言的正是**外层**尺寸
// ⇒ 它一直是绿的，却放过了这个"内容被缩放两次"的真缺陷。
//
// **⚠️ 教训：只断言容器尺寸，断言不到内容。必须断言"内容自己的坐标系"。**
//
// ## 本用例锁住的不变量
// 1. `office-slides-frame-<n>`（幻灯片自己的坐标系）尺寸**必须等于 `deck` 原始尺寸**
//    （960x540），而不是缩放后的外层尺寸；
// 2. **★ 反向确认**：该 frame 必须**严格大于**外层画布 ——
//    这正是"缩放发生在绘制而不是布局"的证据；
//    如果哪天有人把 `OverflowBox` 删掉，frame 会塌成外层尺寸，这条立刻失败；
// 3. 缩略图（compact）走同一条路径，同样要满足。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_slides_deck_view.dart';

const _fixture = 'test/fixtures/office_slides_o3/dynamic.oslides';

void main() {
  final file = File(_fixture);

  group('幻灯片内容不得被缩放两次（真机主画布只画一小块）', () {
    testWidgets('★ 主画布的逻辑坐标系必须等于 deck 原始尺寸，而不是缩放后的外层尺寸', (tester) async {
      // 真机精确参数：override 1148x2492，density 490 → DPR 3.0625
      tester.view.physicalSize = const Size(1148, 2492);
      tester.view.devicePixelRatio = 490 / 160;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final deck = OSlidesDeck.parse(file.readAsBytesSync())!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeSlidesDeckView(deck: deck)),
        ),
      );
      await tester.pump();

      final canvas = tester.getSize(
        find.byKey(const Key('office-slides-canvas-0')),
      );
      final frame = tester.getSize(
        find.byKey(const Key('office-slides-frame-0')),
      );

      // 1) 幻灯片自己的坐标系 = deck 原始尺寸
      expect(
        frame,
        Size(deck.widthPx, deck.heightPx),
        reason:
            'office-slides-frame-0 必须停留在幻灯片原始坐标系 '
            '(${deck.widthPx}x${deck.heightPx})；'
            '若它塌成外层画布尺寸，就说明内容被缩放两次（真机缺陷）',
      );

      // 2) 外层画布是被「缩放并裁剪」后的可见区，必须更小
      expect(
        canvas.width,
        lessThan(frame.width),
        reason:
            '外层画布($canvas)应当小于原始坐标系($frame) —— '
            '缩放应发生在绘制（Transform）而不是布局（约束被压扁）',
      );
      expect(canvas.height, lessThan(frame.height));

      // 3) 画布严格保持 16:9（外层尺寸没被算错）
      expect(
        canvas.width / canvas.height,
        closeTo(deck.widthPx / deck.heightPx, 0.01),
      );
      // 4) 且画布不超过可用区（沿用既有 fit 用例的意图）
      final pager = tester.getSize(
        find.byKey(const Key('office-slides-pages')),
      );
      expect(canvas.width, lessThanOrEqualTo(pager.width));
    });

    testWidgets('缩略图（compact）也必须停留在原始坐标系', (tester) async {
      tester.view.physicalSize = const Size(1148, 2492);
      tester.view.devicePixelRatio = 490 / 160;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final deck = OSlidesDeck.parse(file.readAsBytesSync())!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeSlidesDeckView(deck: deck)),
        ),
      );
      await tester.pump();

      final thumbCanvas = tester.getSize(
        find.byKey(const Key('office-slides-thumb-canvas-0')),
      );
      final thumbFrame = tester.getSize(
        find.byKey(const Key('office-slides-thumb-frame-0')),
      );
      expect(
        thumbFrame,
        Size(deck.widthPx, deck.heightPx),
        reason: '缩略图共用同一条渲染路径，同样必须停在原始坐标系',
      );
      expect(thumbCanvas.width, lessThan(thumbFrame.width));
    });

    testWidgets('多种屏宽下 frame 始终等于 deck 原始尺寸', (tester) async {
      final deck = OSlidesDeck.parse(file.readAsBytesSync())!;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final s in const [
        Size(800, 1600),
        Size(1080, 1920),
        Size(1440, 2880),
      ]) {
        tester.view.physicalSize = s;
        tester.view.devicePixelRatio = 3.0;
        await tester.pumpWidget(
          MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: OfficeSlidesDeckView(deck: deck)),
          ),
        );
        await tester.pump();
        expect(
          tester.getSize(find.byKey(const Key('office-slides-frame-0'))),
          Size(deck.widthPx, deck.heightPx),
          reason: '屏 $s 下 frame 必须仍是原始坐标系',
        );
      }
    });
  });
}
