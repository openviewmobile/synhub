// O3：`.oslides` **页面层**用例（16:9 画布 / 按坐标定位的形状 / 页码指示 /
// 缩略图侧栏 / 左右滑动 / 全屏放映 / 备注 / 兜底文案）。
//
// fixture 是**真实** NAS 文件字节解析出来的 [OSlidesDeck]
// （`test/fixtures/office_slides_o3/technology.oslides`，15 页真实内容）。
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

/// 画布实际渲染出来的尺寸（px）。
Size _canvasSize(WidgetTester tester, int slide) {
  final box = tester.renderObject<RenderBox>(
    find.byKey(Key('office-slides-canvas-$slide')),
  );
  return box.size;
}

/// `Positioned` 的矩形（用真实坐标定位的形状）。
Rect _positionedRect(WidgetTester tester, int slide, int z) {
  final p = tester.widget<Positioned>(
    find.byKey(Key('office-slides-shape-$slide-$z')),
  );
  return Rect.fromLTWH(p.left!, p.top!, p.width!, p.height!);
}

void main() {
  setUpAll(() {
    _deck = OSlidesDeck.parse(_fixture('technology.oslides'))!;
  });

  group('DA171：缩略图页码必须是**看得见**的文字色', () {
    // ★ r537 真机亮色读数：未选中页码用 `scheme.outline`（画边框用的色），
    // 实测 #E0E6EE on #F1F5FA = **1.15:1**，等于看不见。
    // 判据取"文字色对底色的对比度"，不取"用了哪个常量"。
    testWidgets('未选中页码与底色的对比度 ≥ 3:1，且不再用 outline', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pumpAndSettle();

      final scheme = Theme.of(tester.element(find.byType(OfficeSlidesDeckView))).colorScheme;
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => RegExp(r'^[0-9]+$').hasMatch(t.data ?? ''))
          .toList();
      expect(labels, isNotEmpty, reason: 'DA171：缩略图上应有页码文本');

      double lum(Color c) => c.computeLuminance();
      double contrast(Color a, Color b) {
        final la = lum(a), lb = lum(b);
        final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      var checked = 0;
      for (final label in labels) {
        final color = label.style?.color;
        if (color == null) continue;
        if (color == scheme.primary) continue; // 选中页，另有强调色
        checked++;
        expect(color, isNot(scheme.outline),
            reason: 'DA171：页码不许再用 outline（边框色当文字）');
        final ratio = contrast(color, scheme.surface);
        expect(ratio, greaterThanOrEqualTo(3.0),
            reason: 'DA171：未选中页码对比度只有 ${ratio.toStringAsFixed(2)}:1，看不见');
      }
      expect(checked, greaterThan(0), reason: 'DA171：至少要量到一个未选中页码');
    });
  });

  group('真实 PPTX：16:9 画布与按坐标定位', () {
    testWidgets('存在 16:9 画布 Widget', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-deck')), findsOneWidget);
      final size = _canvasSize(tester, 0);
      expect(size.width / size.height, closeTo(16 / 9, 0.02));
    });

    testWidgets('形状按 PPTX 真实 EMU 坐标绝对定位（slide1 标题）', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      // slide1 的 title 占位符几何继承自 slideLayout1：
      // x=540000 y=2093190 cx=8064000 cy=1146810 EMU → /9525 px。
      final z = _deck.slides[0].shapes.indexWhere(
        (s) => s.placeholderType == 'title',
      );
      expect(z, greaterThanOrEqualTo(0));
      final rect = _positionedRect(tester, 0, z);
      expect(rect.left, closeTo(540000 / 9525, 0.01));
      expect(rect.top, closeTo(2093190 / 9525, 0.01));
      expect(rect.width, closeTo(8064000 / 9525, 0.01));
      expect(rect.height, closeTo(1146810 / 9525, 0.01));
      // 画布是 960×540，形状落在画布内。
      final size = _canvasSize(tester, 0);
      final scale = size.width / 960;
      expect(rect.left * scale, lessThan(size.width));
      expect(rect.top * scale, lessThan(size.height));
    });

    testWidgets('slide1 文字按 64pt 加粗白字渲染在画布上', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      final finder = find.textContaining('Social Media', findRichText: true);
      expect(finder, findsWidgets);
      // 收集这一页所有 run 的样式，断言存在 64pt 加粗白字（版式继承来的）。
      final styles = <TextStyle>[];
      void walk(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style != null) styles.add(span.style!);
        for (final child in span.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }

      for (final e in finder.evaluate()) {
        final widget = e.widget;
        if (widget is! RichText) continue;
        walk(widget.text);
      }
      final white = styles.where((s) => s.color == const Color(0xFFFFFFFF));
      expect(white, isNotEmpty, reason: '版式里声明的是白色 64pt 加粗标题');
      expect(white.first.fontWeight, FontWeight.w700);
      expect(white.first.fontSize, closeTo(64 * 96 / 72, 0.01));
    });

    testWidgets('页码指示 + 底部缩略图浮层', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      expect(
        find.byKey(const Key('office-slides-page-indicator')),
        findsOneWidget,
      );
      expect(find.text('1 / 15'), findsOneWidget);
      expect(find.byKey(const Key('office-slides-thumbnails')), findsOneWidget);
      // ⚠️ 改版后缩略图是**底部横向浮层**（2026-09-22）：
      // 一屏只构建可见的约 3-4 张，所以这里断言第 1 张存在，
      // 而不是像旧的竖向侧栏那样断言第 7 张。
      expect(find.byKey(const Key('office-slides-thumb-0')), findsOneWidget);
    });

    testWidgets('★ 主画布吃满全宽（不再被左侧竖栏挤占）', (tester) async {
      tester.view.physicalSize = const Size(1148, 2492);
      tester.view.devicePixelRatio = 490 / 160;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();

      final stage = tester.getSize(
        find.byKey(const Key('office-slides-stage')),
      );
      final canvas = tester.getSize(
        find.byKey(const Key('office-slides-canvas-0')),
      );
      // 旧的 116dp 竖栏会吃掉这块宽度；改版后画布应当逼近整个 stage 宽度
      // （只留 `Gap.sm` 的内边距）。用 0.9 做宽松下界，避免被细节抖动影响。
      expect(
        canvas.width,
        greaterThan(stage.width * 0.9),
        reason: '画布宽 ${canvas.width} vs 舞台宽 ${stage.width} ⇒ 横向空间又被谁吃掉了？',
      );
    });

    testWidgets('★ 浮层可开关：点页码收起/展开', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-thumbnails')), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('office-slides-thumbnails-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-thumbnails')), findsNothing);
      await tester.tap(
        find.byKey(const Key('office-slides-thumbnails-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-thumbnails')), findsOneWidget);
    });

    testWidgets('★ 画布缩放/平移时浮层自动收起（腾出画面）', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-thumbnails')), findsOneWidget);
      // ⚠️ 必须用**真的双指捏合**：单指拖动会被 `PageView` 的横向识别器吃掉，
      // 而"缩放"的语义手势本来就是两指 —— 这样测的才是用户真实操作路径。
      final center = tester.getCenter(
        find.byKey(const Key('office-slides-zoom-0')),
      );
      final f1 = await tester.startGesture(center - const Offset(24, 0));
      final f2 = await tester.startGesture(center + const Offset(24, 0));
      await tester.pump(const Duration(milliseconds: 80));
      await f1.moveBy(const Offset(-40, 0));
      await f2.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 80));
      await f1.up();
      await f2.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-thumbnails')),
        findsNothing,
        reason: '用户在画布上缩放/平移后，浮层应当自动收起',
      );
    });

    testWidgets('左右滑动翻页 → 页码指示更新', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      await tester.fling(
        find.byKey(const Key('office-slides-pages')),
        const Offset(-400, 0),
        1200,
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 15'), findsOneWidget);
      expect(_deck.slides[1].plainText, contains('Instructions for use'));
    });

    testWidgets('点缩略图跳页', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      // ⚠️ 横向浮层只构建可见项，所以要先把目标滚进可视区。
      // 用 `scrollUntilVisible` 而不是硬写坐标，避免依赖具体像素宽度。
      await tester.scrollUntilVisible(
        find.byKey(const Key('office-slides-thumb-9')),
        120,
        scrollable: find.descendant(
          of: find.byKey(const Key('office-slides-thumbnails')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('office-slides-thumb-9')));
      await tester.pumpAndSettle();
      expect(find.text('10 / 15'), findsOneWidget);
    });

    testWidgets('点全屏 → 放映视图（含页码与关闭）', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('office-slides-fullscreen')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-fullscreen-view')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-slides-fullscreen-indicator')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-slides-fullscreen-pages')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('office-slides-fullscreen-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-fullscreen-view')),
        findsNothing,
      );
    });

    testWidgets('备注面板：这一页没有备注（真实文件备注为空）', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('office-slides-notes-toggle')));
      await tester.pump();
      expect(
        find.byKey(const Key('office-slides-notes-panel')),
        findsOneWidget,
      );
      expect(find.text('这一页没有备注'), findsOneWidget);
    });

    testWidgets('★ 只有 SVG 时【不再】出现"矢量图暂不显示"说明（SVG 已能画）', (tester) async {
      // 第 15 轮：自研 SVG 渲染器落地后，`technology.oslides` 的 2 个矢量媒体
      // **都是 SVG 且都能画**（`svgMediaCount == 2`、`unrenderableVectorCount == 0`）。
      // ⇒ 此时若仍弹"部分矢量图形暂不显示"，就是对用户**撒谎**。
      expect(_deck.svgMediaCount, 2, reason: '该样本的矢量媒体都是 SVG');
      expect(_deck.unrenderableVectorCount, 0, reason: 'SVG 已能画，无需说明');
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('office-slides-info')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-vector-note')),
        findsNothing,
        reason: '只有 SVG 时不应出现"矢量图暂不显示"的误导说明',
      );
    });

    testWidgets('真有画不出的矢量（EMF/WMF）时，说明出现且只在信息面板里一次', (tester) async {
      // 反向确认：把"画不出的矢量"数设成 1 ⇒ 说明必须出现（否则这条能力就没有出口了）。
      final deck = OSlidesDeck(
        slides: _deck.slides,
        widthPx: _deck.widthPx,
        heightPx: _deck.heightPx,
        widthEmu: _deck.widthEmu,
        heightEmu: _deck.heightEmu,
        layoutCount: _deck.layoutCount,
        masterCount: _deck.masterCount,
        media: _deck.media,
        svgMediaCount: 2,
        unrenderableVectorCount: 1,
        unsupportedObjectCount: 0,
        degradations: const <String>[],
      );
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: deck)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('office-slides-info')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-vector-note')),
        findsOneWidget,
      );
      // 只在信息面板里出现一次（页面上不重复）
      await tester.tap(find.byKey(const Key('office-slides-info')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-vector-note')), findsNothing);
    });

    testWidgets('不存在任何开发者文案', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      for (final bad in const ['版式从简', '本批', '只读预览', '不支持编辑', '从简']) {
        expect(find.textContaining(bad), findsNothing, reason: bad);
      }
    });
  });

  group('兜底：绝不静默空白', () {
    testWidgets('整页没有可绘制内容 → 明确说明', (tester) async {
      final blank = OSlidesDeck(
        slides: <OSlidesDeckSlide>[
          const OSlidesDeckSlide(
            order: 0,
            shapes: <OSlidesDeckShape>[],
            backgroundArgb: 0xFFFFFFFF,
            backgroundInherited: true,
            notes: '',
            placeholderCount: 0,
            inheritedGeometryCount: 0,
            degradations: <String>[],
          ),
        ],
        widthPx: 960,
        heightPx: 540,
        widthEmu: 9144000,
        heightEmu: 5143500,
        layoutCount: 0,
        masterCount: 0,
        media: const <String, Uint8List>{},
        unrenderableVectorCount: 0,
        unsupportedObjectCount: 0,
        degradations: const <String>[],
      );
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: blank)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-blank-0')), findsOneWidget);
      expect(find.textContaining('没有可显示的内容'), findsOneWidget);
    });

    testWidgets('暂不支持的对象 → 可读占位卡（不是空白）', (tester) async {
      final deck = OSlidesDeck(
        slides: <OSlidesDeckSlide>[
          const OSlidesDeckSlide(
            order: 0,
            shapes: <OSlidesDeckShape>[
              OSlidesDeckShape(
                id: 'frame',
                kind: OSlidesShapeKind.unsupported,
                preset: 'frame',
                left: 100,
                top: 100,
                width: 400,
                height: 200,
                rotationDegrees: 0,
                geometryInherited: false,
                unsupportedLabel: '图表',
              ),
            ],
            backgroundArgb: 0xFFFFFFFF,
            backgroundInherited: true,
            notes: '',
            placeholderCount: 0,
            inheritedGeometryCount: 0,
            degradations: <String>[],
          ),
        ],
        widthPx: 960,
        heightPx: 540,
        widthEmu: 9144000,
        heightEmu: 5143500,
        layoutCount: 0,
        masterCount: 0,
        media: const <String, Uint8List>{},
        unrenderableVectorCount: 0,
        unsupportedObjectCount: 1,
        degradations: const <String>[],
      );
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: deck)));
      await tester.pump();
      // ⚠️ 缩略图现在渲染**完整内容**（2026-09-22 修复缩略图纯色块缺陷），
      // 所以占位卡会在主画布与缩略图里各出现一次 —— 这是正确行为
      //（缩略图本就该是主画布的缩小版，真实 Office 的缩略图也带细小文字）。
      // 因此这里把 finder **限定到主画布**，断言的是"主画布没有静默空白"。
      final mainCanvas = find.byKey(const Key('office-slides-canvas-0'));
      Finder inMain(Finder f) => find.descendant(of: mainCanvas, matching: f);
      expect(inMain(find.textContaining('暂不支持的对象')), findsOneWidget);
      expect(inMain(find.textContaining('图表')), findsOneWidget);
      // 有内容 → 不显示"没有可显示的内容"（缩略图里同样不该出现）
      expect(find.textContaining('没有可显示的内容'), findsNothing);
    });

    testWidgets('空演示文稿 → 明确空态', (tester) async {
      final deck = OSlidesDeck(
        slides: const <OSlidesDeckSlide>[],
        widthPx: 960,
        heightPx: 540,
        widthEmu: 9144000,
        heightEmu: 5143500,
        layoutCount: 0,
        masterCount: 0,
        media: const <String, Uint8List>{},
        unrenderableVectorCount: 0,
        unsupportedObjectCount: 0,
        degradations: const <String>[],
      );
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: deck)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-deck-empty')), findsOneWidget);
    });
  });

  group('缩略图画布', () {
    testWidgets('缩略图用 compact 画布（不重复主画布的 key）', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();
      expect(
        find.byKey(const Key('office-slides-thumb-canvas-0')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('office-slides-canvas-0')), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 缩略图布局的**方向自适应**（2026-09-22）
  //
  // 这不是口味问题，是能用算术证明的最优解：幻灯片是 16:9 横向内容，
  // 画布缩放比 `scale = min(可用宽/960, 可用高/540)` 取**较小值**，
  // 所以只有"受限的那一边"才真正影响画布大小。
  //
  //   * 竖屏：宽受限 ⇒ 侧栏吃掉 33% 宽度，画布面积只剩 56% ⇒ 必须用底部横条
  //   * 横屏：高受限 ⇒ 侧栏**一像素都不损失画布**（宽度本来就用不完）
  //                    ⇒ 用左侧竖栏更好（同屏缩略图更多、且不遮挡画面）
  //
  // 这组用例把"哪种方向用哪种形态"钉死，防止以后有人图省事改成单一形态。
  group('缩略图布局按方向自适应', () {
    Future<void> setSize(WidgetTester tester, Size logical) async {
      tester.view.physicalSize = logical * 3.0;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('★ 竖屏 ⇒ 底部胶片栏（参与布局，不遮挡画布），且主画布吃满宽度', (tester) async {
      await setSize(tester, const Size(375, 814));
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();

      final stage = tester.getRect(
        find.byKey(const Key('office-slides-stage')),
      );
      final strip = tester.getRect(
        find.byKey(const Key('office-slides-thumbnails')),
      );
      final pager = tester.getRect(
        find.byKey(const Key('office-slides-pages')),
      );
      final canvas = tester.getRect(
        find.byKey(const Key('office-slides-canvas-0')),
      );

      // 形态：与舞台同宽、贴在**底部**、高度远小于舞台 ⇒ 是横条不是竖栏
      expect(
        strip.width,
        closeTo(stage.width, 0.5),
        reason: '竖屏胶片栏应当与舞台同宽（是底部横条）',
      );
      expect(
        strip.bottom,
        closeTo(stage.bottom, 0.5),
        reason: '竖屏胶片栏应当贴在**底部**',
      );
      expect(
        strip.height,
        lessThan(stage.height * 0.3),
        reason: '竖屏胶片栏是"条"，不该占掉三分之一以上的高度',
      );

      // ⚠️ **规格变更（2026-09-22 第三轮，r17）**：旧用例把"胶片栏是**浮层**"
      // 当规格，因此只断言它贴在底部。但浮层会**盖住画面本身**，并且因为它
      // 贴在 `bottom: 0` 而不吃底部系统区，序号正好落在**系统手势条**里
      // （真机实测 BOTTOM_MANDATORY_GESTURES 高 123px）。
      // 现在钉住真正要保证的两条不变量：
      //   ① 胶片栏与画布**互不重叠**（主画布区整个在胶片栏上方）；
      //   ② 画布横向仍然吃满（不能为了"不遮挡"而牺牲画布宽度）。
      expect(
        pager.bottom,
        lessThanOrEqualTo(strip.top + 0.5),
        reason: '胶片栏必须**参与布局**：主画布区不能被它覆盖',
      );
      expect(
        canvas.bottom,
        lessThanOrEqualTo(strip.top + 0.5),
        reason: '画布下半部分被胶片栏压住 —— 这正是"被屏幕下沿切断"的形态',
      );

      // 关键收益：画布横向几乎吃满（旧的 116dp 侧栏会让它只剩 67%）
      expect(
        canvas.width,
        greaterThan(stage.width * 0.9),
        reason:
            '竖屏画布宽 ${canvas.width} / 舞台宽 ${stage.width} '
            '⇒ 横向空间没有还给画布',
      );
    });

    testWidgets('★ 横屏 ⇒ 左侧竖栏，且不遮挡画布', (tester) async {
      await setSize(tester, const Size(814, 375));
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: _deck)));
      await tester.pump();

      final stage = tester.getRect(
        find.byKey(const Key('office-slides-stage')),
      );
      final rail = tester.getRect(
        find.byKey(const Key('office-slides-thumbnails')),
      );
      final canvas = tester.getRect(
        find.byKey(const Key('office-slides-canvas-0')),
      );

      // 竖栏：高度与舞台同高、贴在**左侧**、宽度很窄
      expect(
        rail.height,
        closeTo(stage.height, 0.5),
        reason: '横屏竖栏应当与舞台同高（是左侧竖条）',
      );
      expect(rail.left, closeTo(stage.left, 0.5), reason: '横屏竖栏应当贴在**左侧**');
      expect(
        rail.width,
        lessThan(stage.width * 0.25),
        reason: '横屏竖栏是"条"，不该占掉四分之一以上的宽度',
      );

      // 关键：横屏是**高度受限**，所以加侧栏不该缩小画布 —— 用几何证明"互不重叠"
      expect(
        canvas.left,
        greaterThanOrEqualTo(rail.right - 0.5),
        reason: '横屏画布与竖栏不应重叠（画布应在竖栏右侧）',
      );
      // 且画布应当吃满"竖栏右边剩下的高度"，说明确实是高度受限、没被挤小
      expect(
        canvas.height,
        greaterThan(stage.height * 0.75),
        reason:
            '横屏画布高 ${canvas.height} / 舞台高 ${stage.height} '
            '⇒ 画布被挤小了，横屏本应是高度受限',
      );
    });
  });
}
