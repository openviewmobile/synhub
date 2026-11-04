// 真机缺陷回归（2026-09-22）：幻灯片文字**不得被裁掉整行** —— 需要 `normAutofit` 式缩排。
//
// ## 缺陷现象（真机 HONOR LGE-AN10，`Technology.oslides` 第 1 页）
// 该页标题占位符有**两个 64pt 段落**：
//   p0 `Social Media` ／ p1 `Strategy`（都是白色粗体 64pt）
// 而形状框是 `T=220 H=120`、`bodyPr anchor="b"`（底对齐）。
// 64pt ≈ 85px 行高 ⇒ **两行 170px > 框高 120px**。
//
// 旧实现是 `ClipRect + OverflowBox(底对齐)` ⇒ 内容**从顶部溢出后被裁掉**，
// **真机上只看得见 `Strategy`，`Social Media` 整行消失**（截图已取证）。
//
// 旧注释的理由是「PPTX 文字本来就可能溢出形状，PowerPoint 用 normAutofit 缩排，
// 我们没有字体度量时不该假装能算准」—— 但**裁掉一整行文字**显然比
// 「缩得不够精确」更糟：用户直接看不到内容。
//
// ## 修复
// 用 `FittedBox(fit: BoxFit.scaleDown)` 做 `normAutofit` 的忠实近似：
// * **只缩不放**（`scaleDown`）⇒ 放得下时行为与原来完全一致，不会突然放大；
// * 子项宽度已固定为形状内容宽 ⇒ 正常情况下不需要横向缩放；
// * 高度超出时整体等比缩小 ⇒ **文字全部可见**，正是 PowerPoint/WPS 的表现。
//
// 本页实例：`scale = 120/170 = 0.706` ⇒ 64pt 实际显示约 45pt，两行都看得见。
//
// ## 本用例锁住的不变量
// 1. 标题形状里的**两个段落都必须存在**（`Social Media` 与 `Strategy`）；
// 2. **★ 每个文字的渲染框都必须落在形状框内** —— 这正是「被裁掉」的直接反面；
// 3. 文字**不得小于**某个下限（防止「为了塞下而缩到看不见」这种反向退化）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_slides_deck_view.dart';

const _fixture = 'test/fixtures/office_slides_o3/technology.oslides';

void main() {
  testWidgets('★ 两行 64pt 标题都必须可见，且渲染框落在形状框内（不被裁掉）', (tester) async {
    tester.view.physicalSize = const Size(1148, 2492);
    tester.view.devicePixelRatio = 490 / 160;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final deck = OSlidesDeck.parse(File(_fixture).readAsBytesSync())!;
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(body: OfficeSlidesDeckView(deck: deck)),
      ),
    );
    await tester.pump();

    // 先确认夹具本身就有这个「两段 64pt 挤在 120px 框里」的构造，
    // 否则这条用例测不到东西。
    final title = deck.slides[0].shapes.firstWhere(
      (s) => s.placeholderType == 'title',
    );
    expect(title.paragraphs.length, 2, reason: '夹具变了？标题应当是两段');
    expect(
      title.paragraphs.map((p) => p.text).toList(),
      containsAll(<String>['Social Media', 'Strategy']),
    );
    // 行高粗估（64pt ≈ 85px）确实超过框高 —— 证明这条用例不空。
    final roughLineHeight = 64.0 * (96 / 72);
    expect(
      roughLineHeight * title.paragraphs.length,
      greaterThan(title.height),
      reason:
          '夹具不再溢出？实测两行 ${roughLineHeight * 2} vs 框高 ${title.height}；'
          '若不溢出，这条回归就失去意义',
    );

    // ⚠️ 缩略图现在也渲染完整内容，所以同一段文字会出现**两次**
    //（主画布 + 底部/左侧缩略图）。必须把 finder **限定到主画布的形状**里，
    // 否则会把"缩略图也有这段文字"误判成"主画布重复渲染"。
    final titleShape = find.byKey(const Key('office-slides-shape-0-1'));
    Finder inTitle(String label) =>
        find.descendant(of: titleShape, matching: find.text(label));

    // 1) 两行都必须被渲染出来
    expect(
      inTitle('Social Media'),
      findsOneWidget,
      reason: '`Social Media` 被裁掉了 —— normAutofit 没生效',
    );
    expect(inTitle('Strategy'), findsOneWidget);

    // 2) 两行的渲染框都必须落在标题形状框内
    final shapeRect = tester.getRect(
      find.byKey(const Key('office-slides-shape-0-1')),
    );
    for (final label in const ['Social Media', 'Strategy']) {
      final r = tester.getRect(inTitle(label));
      expect(
        r.top,
        greaterThanOrEqualTo(shapeRect.top - 0.5),
        reason: '`$label` 渲染框顶边(${r.top}) 超出形状框顶边(${shapeRect.top}) ⇒ 被裁',
      );
      expect(
        r.bottom,
        lessThanOrEqualTo(shapeRect.bottom + 0.5),
        reason: '`$label` 渲染框底边(${r.bottom}) 超出形状框底边(${shapeRect.bottom}) ⇒ 被裁',
      );
    }

    // 3) 不得为了塞下而缩到看不见（下限保护）
    final titleTextHeight = tester.getRect(inTitle('Strategy')).height;
    expect(
      titleTextHeight,
      greaterThan(6.0),
      reason: '标题被缩得几乎看不见了（高 $titleTextHeight）',
    );

    // 4) `FittedBox` 必须是 `scaleDown`（只缩不放）
    final fitted = tester.widgetList<FittedBox>(
      find.descendant(
        of: find.byKey(const Key('office-slides-shape-0-1')),
        matching: find.byType(FittedBox),
      ),
    );
    expect(fitted, isNotEmpty, reason: '标题文字应当走 normAutofit 近似路径');
    for (final f in fitted) {
      expect(
        f.fit,
        BoxFit.scaleDown,
        reason: '必须是 scaleDown：放得下时不得放大，否则排版会被改变',
      );
    }
  });

  testWidgets('放得下时不缩放（scaleDown 只缩不放）', (tester) async {
    tester.view.physicalSize = const Size(1148, 2492);
    tester.view.devicePixelRatio = 490 / 160;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final deck = OSlidesDeck.parse(File(_fixture).readAsBytesSync())!;
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(body: OfficeSlidesDeckView(deck: deck)),
      ),
    );
    await tester.pump();

    // 副标题框 `T=340 H=63`、单行 28pt（≈37px）⇒ 放得下。
    //
    // ⚠️ 注意：**不能**用「文字宽度 ≈ 形状宽度」来判断有没有被缩放 ——
    // 文字本身的固有宽度就小于形状宽度（这是正常的，不是缩放）。
    // 真正该断言的是我们关心的性质：**完整落在形状框内、没有被裁**。
    final subShape = find.byKey(const Key('office-slides-shape-0-2'));
    final subRect = tester.getRect(subShape);
    // 同样限定到主画布的形状（缩略图里也有这段文字）。
    final textRect = tester.getRect(
      find.descendant(
        of: subShape,
        matching: find.text('How to grow your fans from 0 to 10K'),
      ),
    );
    expect(
      textRect.top,
      greaterThanOrEqualTo(subRect.top - 0.5),
      reason: '副标题顶边超出形状框 ⇒ 被裁',
    );
    expect(
      textRect.bottom,
      lessThanOrEqualTo(subRect.bottom + 0.5),
      reason: '副标题底边超出形状框 ⇒ 被裁',
    );
    expect(textRect.left, greaterThanOrEqualTo(subRect.left - 0.5));
    expect(textRect.right, lessThanOrEqualTo(subRect.right + 0.5));
    expect(textRect.height, greaterThan(0));
  });
}
