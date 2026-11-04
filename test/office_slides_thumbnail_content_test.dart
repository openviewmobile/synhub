// 真机缺陷回归（2026-09-22）：缩略图**必须真的画出幻灯片内容**，不能只是纯色块。
//
// ## 缺陷现象（用户直接反馈）
// > 「oslides的缩略图不太对啊，好像没有正确生成」
//
// 真机上缩略图是**一整块纯色**（只有背景），完全看不出这一页有什么；
// 而主画布同一页却有图、有字。
//
// ## 根因（代码级）
// 旧实现对 `compact: true` 走 `_compactShape`，而它只画"有填充色的形状"：
// ```dart
// Widget _compactShape(OSlidesDeckShape shape) {
//   final fill = shape.fillArgb;
//   if (fill == null) return const SizedBox.shrink();   // ← 图片/文字直接被丢掉
//   return DecoratedBox(decoration: BoxDecoration(color: Color(fill), ...));
// }
// ```
// **图片和文本框都没有 `fillArgb`** ⇒ 全部走 `SizedBox.shrink()` ⇒ 消失。
// 只有矩形/椭圆这类**有实心填充**的形状会留下来（但那恰恰不是主要内容）。
//
// 当初这么写是为了省内存（样本里有一张 5612x3742 / 84MB 的图，
// 在缩略图里也全尺寸解码会撑爆图片缓存）。**但那个理由现在已经不成立**：
//   1. `_picture` 会按 `canvasScale` 夹取 `cacheWidth/cacheHeight`：
//      缩略图 scale ≈ 0.1 ⇒ 只解码约 30px 宽，开销可以忽略；
//   2. `normAutofit`（`FittedBox scaleDown`）保证文字在 54dp 高的缩略图里
//      等比缩小而不是溢出，不会出现红黑条纹。
//
// ## 修复
// 缩略图改为走**与主画布完全相同的渲染路径**（`_shapeContent`），
// `_compactShape` 整个删除（不留死代码）。
// `compact` 现在只用于**跳过整页空态卡片**（在 96px 宽的缩略图里那只是噪声）。
//
// ## 本用例锁住的不变量
// 1. 缩略图画布里**必须出现与主画布相同的文字**；
// 2. 缩略图画布里**必须出现与主画布相同数量的图片**；
// 3. **★ 反向确认**：若把缩略图退回"只画填充色"，第 1、2 条立刻失败。
// 4. 缩略图画布的**布局尺寸仍必须是 deck 原始坐标系**（960x540）——
//    即"内容完整"不能靠"取消缩放"换来，两者要同时成立。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_slides_deck_view.dart';

// ⚠️ 夹具选择很关键：`technology.oslides` 首页那张图是 **`image1.svg`（矢量）**，
// 而矢量图当前是**有意不渲染**的（`_picture` 对 `isVectorImage` 直接返回
// `SizedBox.shrink()` —— 不猜、不假装）。用它会让"主画布也没图"，
// 于是数量比较退化成 0 == 0 的**假通过**。
//
// `dynamic.oslides`（9,003,452 B，真 pptx）首页有**两张真位图**：
//   * `ppt/media/image1.png`（8496 B，960x8 顶部条）
//   * `ppt/media/image2.jpg`（75042 B，960x540 满幅）
// 同时还有文字 ⇒ **一个夹具同时覆盖"图 + 字"两条断言**，且不会假通过。
const _fixture = 'test/fixtures/office_slides_o3/dynamic.oslides';

void main() {
  Future<void> pumpPortrait(WidgetTester tester, OSlidesDeck deck) async {
    tester.view.physicalSize = const Size(1125, 2442); // 375 x 814 @3.0
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(body: OfficeSlidesDeckView(deck: deck)),
      ),
    );
    // ⚠️ 图片/媒体是**异步**装入的（`FutureBuilder` 读字节），
    // 只 `pump()` 一次时主画布和缩略图里都还一张 `Image` 都没有 ——
    // 那样"两边都是 0"会让数量比较**假通过**。必须等到图真的出现。
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('★ 缩略图必须画出与主画布相同的文字（不是纯色块）', (tester) async {
    final deck = OSlidesDeck.parse(File(_fixture).readAsBytesSync())!;
    await pumpPortrait(tester, deck);

    const thumbKey = Key('office-slides-thumb-canvas-0');
    const mainKey = Key('office-slides-canvas-0');
    expect(find.byKey(thumbKey), findsOneWidget);
    expect(find.byKey(mainKey), findsOneWidget);

    // 这一页确实有文字 —— 否则用例测不到东西。
    for (final label in const [
      'Social Media',
      'Strategy',
      'How to grow your fans from 0 to 10K',
    ]) {
      expect(
        find.descendant(of: find.byKey(mainKey), matching: find.text(label)),
        findsOneWidget,
        reason: '主画布应该有「$label」（夹具坏了？）',
      );
      expect(
        find.descendant(of: find.byKey(thumbKey), matching: find.text(label)),
        findsOneWidget,
        reason: '缩略图里看不到「$label」—— 缩略图又退化成纯色块了',
      );
    }
  });

  testWidgets('★ 缩略图必须画出与主画布相同数量的图片', (tester) async {
    final deck = OSlidesDeck.parse(File(_fixture).readAsBytesSync())!;
    await pumpPortrait(tester, deck);

    const thumbKey = Key('office-slides-thumb-canvas-0');
    const mainKey = Key('office-slides-canvas-0');

    final mainImages = find.descendant(
      of: find.byKey(mainKey),
      matching: find.byType(Image),
    );
    final thumbImages = find.descendant(
      of: find.byKey(thumbKey),
      matching: find.byType(Image),
    );

    // 这一页确实有图片（fixture 里 slide0 有一个 picture 形状）。
    final pictureCount = deck.slides[0].shapes
        .where((s) => s.kind == OSlidesShapeKind.picture)
        .length;
    expect(pictureCount, greaterThan(0), reason: '夹具的首页没有图片形状，这条用例就失去意义了');

    expect(
      thumbImages,
      findsNWidgets(tester.widgetList(mainImages).length),
      reason:
          '缩略图里的图片数量与主画布不一致 —— '
          '图片被 `_compactShape` 丢掉了',
    );
    // ★ 关键：不能只比数量 —— 两边都是 0 也会"相等"。
    // 必须钉住"确实有图"，否则这条用例会假通过。
    expect(
      thumbImages,
      findsAtLeastNWidgets(1),
      reason:
          '缩略图里一张图都没有（若主画布也没图，说明是异步没装完，'
          '而不是缩略图的问题）',
    );
    expect(
      tester.widgetList(mainImages),
      isNotEmpty,
      reason: '主画布也没图 ⇒ 是等待不够，不是缩略图缺陷',
    );
  });

  testWidgets('★ 内容完整不能靠"取消缩放"换来：缩略图坐标系仍是 960x540', (tester) async {
    final deck = OSlidesDeck.parse(File(_fixture).readAsBytesSync())!;
    await pumpPortrait(tester, deck);

    final thumbFrame = tester.getSize(
      find.byKey(const Key('office-slides-thumb-frame-0')),
    );
    expect(
      thumbFrame,
      Size(deck.widthPx, deck.heightPx),
      reason:
          '缩略图必须仍停在幻灯片原始坐标系；'
          '若它为了"能画下内容"而放大了坐标系，说明画布缩放被破坏',
    );

    final thumbCanvas = tester.getSize(
      find.byKey(const Key('office-slides-thumb-canvas-0')),
    );
    expect(
      thumbCanvas.width,
      lessThan(thumbFrame.width),
      reason: '缩略图应当是"缩小并裁剪"后的可见区',
    );
    // 缩略图条高 88dp、缩略图 54dp 高 ⇒ 画布宽约 96dp。给个宽松区间。
    expect(thumbCanvas.width, greaterThan(60));
    expect(thumbCanvas.width, lessThan(160));
  });
}
