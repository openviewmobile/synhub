// ★★ 第 256 轮真机缺陷回归：**幻灯片"内容被缩放两次"**（用户原话：
// 「从 NAS file 打开 office 的三种格式显示有问题」，实测表现为"整页只画出左上角一小块"）。
//
// ## 真机证据（LGE-AN10，375 dp 宽，从 NAS「文件」打开 `.oslides`）
// * `.odoc` 正常；`.oslides` 的**降级路径**（OFile 文本，拿不到 PPTX 字节）
//   只画出约 **140x78 dp** 的一小块（是整页内容被缩到 `960*0.39² ≈ 146 dp`）。
//
// ## 根因（两处同型缺陷，只修过一处）
// 外层 `SizedBox(width: 960*scale)` 给的是**紧约束**；`Transform.scale` 是
// RenderProxyBox，原样把紧约束下传 ⇒ 内层 `SizedBox/Container(960x540)` 先被
// `BoxConstraints.enforce` 压成 `960*scale`，再被 `Transform.scale` 缩一次
// ⇒ 内容实际只占 `960*scale²`。
// * ① `office_slides_deck_view.dart`（真 PPTX 路径）2026-09-22 已修并有用例；
// * ② **`office_viewer_page.dart` 的 `_SlidePage`（OFile 降级路径）漏了** ← 用户看到的；
// * ③ `office_slides_canvas.dart`（编辑视图画布）同型，2026-09-25 一并修。
//
// ## 为什么老用例抓不到
// 它们只断言**外层**尺寸/宽高比/相对位置，而外层布局尺寸一直是对的
// （`Transform.scale` 只影响绘制、不影响布局）⇒ 必须量**内层**坐标系尺寸。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/office_native/oslides_model.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/features/files/office_viewer_page.dart';
import 'package:synhub/src/features/office/office_slides_deck_view.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_slides_view.dart';

Map<String, Object?> _sections(String name) =>
    (jsonDecode(
              File('test/fixtures/office_templates/$name.json').readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

/// 真机视口：1148x2492 物理 / dpr 3.0625 ≈ 375x813 dp。
void _deviceViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1148, 2492);
  tester.view.devicePixelRatio = 3.0625;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('★★ ② 降级幻灯片（NAS 路径）：内层必须停在 960x540 坐标系', (tester) async {
    _deviceViewport(tester);
    final pres = OSlidesPresentation.fromSections(_sections('slides_group'));
    expect(pres.slides, isNotEmpty);

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          // deck: null = 没有 PPTX 字节 ⇒ 走 OFile 降级路径（NAS「文件」正是这条）
          body: OSlidesView(presentation: pres, deck: null),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final frameKey = Key('office-slides-fallback-canvas-${pres.slides.first.order}');
    expect(
      find.byKey(frameKey),
      findsOneWidget,
      reason: '降级路径的画布必须存在（否则就是空白页）',
    );
    final frame = tester.getSize(find.byKey(frameKey));
    expect(
      frame.width,
      960.0,
      reason:
          '★ 内层必须是幻灯片原始坐标系宽度 960；实测 ${frame.width} 说明'
          '内容被"压紧约束 + 再缩放一次"缩放了两遍（真机只有 ~140 dp 宽）',
    );
    expect(frame.height, 540.0, reason: '★ 同上（高度必须停在 540）');

    // 外层画布盒仍应铺满可用宽度（布局一直是对的，缺的是内层约束）
    final outer = tester.getSize(
      find
          .ancestor(of: find.byKey(frameKey), matching: find.byType(SizedBox))
          .first,
    );
    expect(
      outer.width,
      greaterThan(300.0),
      reason: '外层画布盒应当铺满视口宽度（375 dp 减内边距），实测 ${outer.width}',
    );
  });

  testWidgets('★★ ③ 编辑画布（OfficeSlidesCanvas）：内层同样停在原始坐标系', (tester) async {
    _deviceViewport(tester);
    final sections = _sections('slides_group');

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: OfficeSlidesView(sections: sections, showHeaderNote: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final frameKey = const Key('office-slide-frame-0');
    expect(find.byKey(frameKey), findsOneWidget);
    final frame = tester.getSize(find.byKey(frameKey));
    // 编辑画布的真实画布尺寸取自 scene（真机模板为 960x540）
    expect(
      frame.width,
      960.0,
      reason: '★ 内层必须停在画布原始坐标系；实测 ${frame.width} ⇒ 被缩放两次',
    );
    expect(frame.height, 540.0);
  });

  testWidgets('回归保护：deck 路径（真 PPTX）内层仍是 960x540', (tester) async {
    _deviceViewport(tester);
    final deck = OSlidesDeck.parse(
      File('test/fixtures/office_slides_o3/technology.oslides').readAsBytesSync(),
    )!;
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(body: OfficeSlidesDeckView(deck: deck)),
      ),
    );
    await tester.pump();
    final frame = tester.getSize(find.byKey(const Key('office-slides-frame-0')));
    expect(frame.width, 960.0);
    expect(frame.height, 540.0);
  });
}
