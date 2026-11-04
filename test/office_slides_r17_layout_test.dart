// r17 `.oslides` 显示重做 —— **画布适配 / 胶片栏 / 底部系统区 / 放映** 的回归锁。
//
// 本文件只锁 r17 新钉住的**形态不变量**，每一条都对应一个真机实测事实：
//
// ┌───┬──────────────────────────────────────────────┬──────────────────────────┐
// │ # │ 不变量                                        │ 真机事实来源              │
// ├───┼──────────────────────────────────────────────┼──────────────────────────┤
// │ 1 │ 画布在可用区内等比 contain、**精确居中**、      │ 实测画布 1098×617px、    │
// │   │ 除 `Gap.sm` 外不额外留白                       │ AR=1.7796、区域中心重合   │
// │ 2 │ 胶片栏**参与布局**，与画布零重叠               │ 浮层会盖住画面            │
// │ 3 │ 胶片栏底色**不透明** + 1dp 顶边线              │ 浮层 Δ≈4/255 ⇒ 看不出分隔 │
// │ 4 │ 底部让开 `max(viewPadding, systemGestureInsets)`│ NAVIGATION_BAR 高 0、     │
// │   │                                                │ GESTURES 高 123px        │
// │ 5 │ 当前页高亮**唯一**且随翻页移动                  │ 一像素边框在缩略图里看不清 │
// │ 6 │ 竖屏备注面板在画布**下方**且不缩小画布           │ 画布宽受限 ⇒ 竖向空间是剩的 │
// │ 7 │ 放映：点按翻页 / 左 20% 回退 / 末页点按退出 /    │ 官方放映器形态            │
// │   │ 工具条 3s 自动隐藏、顶部点按呼出                 │                          │
// └───┴──────────────────────────────────────────────┴──────────────────────────┘
//
// 夹具用**真实 NAS 样本字节**解析出来的 deck（不是手搓模型）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/features/office/office_slides_deck_view.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_slides_o3/$name').readAsBytesSync();

late OSlidesDeck _deck;

Future<void> _pump(
  WidgetTester tester, {
  OSlidesDeck? deck,
  EdgeInsets viewPadding = EdgeInsets.zero,
  EdgeInsets systemGestureInsets = EdgeInsets.zero,
  Size logical = const Size(375, 814),
}) async {
  tester.view.physicalSize = logical * 3.0;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Builder(
        builder: (context) {
          final base = MediaQuery.of(context);
          return MediaQuery(
            data: base.copyWith(
              viewPadding: viewPadding,
              padding: viewPadding,
              systemGestureInsets: systemGestureInsets,
            ),
            child: Scaffold(body: OfficeSlidesDeckView(deck: deck ?? _deck)),
          );
        },
      ),
    ),
  );
  await tester.pump();
}

/// 胶片栏上那条 1dp 顶边线（返回第一个带 border 的 `BoxDecoration`）。
BoxDecoration? _stripBorder(WidgetTester tester) {
  final containers = tester.widgetList<Container>(
    find.descendant(
      of: find.byKey(const Key('office-slides-thumbnails')),
      matching: find.byType(Container),
    ),
  );
  for (final c in containers) {
    final d = c.decoration;
    if (d is BoxDecoration && d.border != null) return d;
  }
  return null;
}

void main() {
  setUpAll(() {
    _deck = OSlidesDeck.parse(_fixture('technology.oslides'))!;
  });

  // ── ① 画布适配：contain + 居中 + 不额外留白 ────────────────────────────────
  group('① 画布按可用区等比 contain', () {
    testWidgets('★ 宽度吃满、保持 16:9、在可用区内**精确居中**', (tester) async {
      await _pump(tester);

      final pager = tester.getRect(
        find.byKey(const Key('office-slides-pages')),
      );
      final canvas = tester.getRect(
        find.byKey(const Key('office-slides-canvas-0')),
      );

      // 幻灯片坐标系是 px（EMU/9525，96dpi），比例 = deck 自己的宽高比。
      expect(
        canvas.width / canvas.height,
        closeTo(_deck.widthPx / _deck.heightPx, 0.01),
        reason: '等比缩放：不能把 16:9 拉变形',
      );

      // 竖屏 **宽受限** ⇒ 宽度必须吃满可用区，且只让出 `Gap.sm` 内边距。
      expect(
        pager.width - canvas.width,
        lessThanOrEqualTo(Gap.sm * 2 + 0.5),
        reason:
            '画布宽 ${canvas.width} / 可用宽 ${pager.width} ⇒ '
            '除 Gap.sm 之外还有额外留白，等于没"尽量占满可用区"',
      );
      expect(canvas.center.dx, closeTo(pager.center.dx, 0.5), reason: '水平必须居中');
      expect(
        canvas.center.dy,
        closeTo(pager.center.dy, 0.5),
        reason:
            '垂直必须居中 —— 真机实测区域中心 1585 与画布中心 1585 重合；'
            '若这里偏了，说明有不可见的元素把画布挤下去了',
      );
    });

    testWidgets('★ 横屏（高受限）⇒ 高度吃满可用区', (tester) async {
      await _pump(tester, logical: const Size(814, 375));

      final pager = tester.getRect(
        find.byKey(const Key('office-slides-pages')),
      );
      final canvas = tester.getRect(
        find.byKey(const Key('office-slides-canvas-0')),
      );

      expect(
        pager.height - canvas.height,
        lessThanOrEqualTo(Gap.sm * 2 + 0.5),
        reason: '横屏是**高受限**：高度必须吃满，否则就是白白浪费了竖向空间',
      );
      expect(canvas.height, greaterThan(pager.height * 0.9));
    });
  });

  // ── ②③ 胶片栏形态 ─────────────────────────────────────────────────────
  group('②③ 胶片栏：参与布局 + 明确分隔', () {
    testWidgets('★ 与画布零重叠（画布下半部分不会被压住）', (tester) async {
      await _pump(tester);

      final strip = tester.getRect(
        find.byKey(const Key('office-slides-thumbnails')),
      );
      final pager = tester.getRect(
        find.byKey(const Key('office-slides-pages')),
      );
      final canvas = tester.getRect(
        find.byKey(const Key('office-slides-canvas-0')),
      );

      expect(
        pager.bottom,
        lessThanOrEqualTo(strip.top + 0.5),
        reason: '胶片栏必须是**参与布局**的面板（以前是贴底浮层，会盖住画面）',
      );
      expect(
        canvas.bottom,
        lessThanOrEqualTo(strip.top + 0.5),
        reason: '画布下半部分被胶片栏压住 —— "被屏幕下沿切断"的形态',
      );
    });

    testWidgets('★ 底色不透明 + 有一条实边线（与画面明确分层）', (tester) async {
      await _pump(tester);

      final material = tester.widget<Material>(
        find.byKey(const Key('office-slides-thumbnails')),
      );
      final color = material.color;
      expect(color, isNotNull);
      expect(
        color!.a,
        1.0,
        reason:
            '底色必须**不透明**：半透明会让舞台底透上来，'
            '真机实测浮层底与舞台底只差 Δ≈4/255 ⇒ 看不出分隔',
      );

      final border = _stripBorder(tester);
      expect(border, isNotNull, reason: '胶片栏必须有边线，否则与画面连成一片');
      final top = (border!.border as Border).top;
      expect(top.width, 1.0);
      final context = tester.element(
        find.byKey(const Key('office-slides-thumbnails')),
      );
      expect(
        top.color,
        Theme.of(context).colorScheme.outlineVariant,
        reason: '边线用主题的 outlineVariant（外层 chrome 可以用 App 主题色）',
      );
    });

    testWidgets('DA201 选中缩略图的页码：按**真机亮色那套底**算，必须 ≥4.5', (tester) async {
      // 真机 r609（HONOR LGE-AN10，亮色 + 动态取色）：页码 (51,99,131)
      // 画在 16% 选中底上 ⇒ 合成 (203,215,226) ⇒ **4.41:1**，差 0.09 掉出 AA。
      // 宿主里 `DesignPalette` 是静态亮色（primary #1D4ED8），**天生就过**，
      // 所以这里照 `DA199` 的做法：把真机量到的那对颜色作为夹具灌进去。
      // ⚠️ 只测"页码 vs 合成底"这条算术，不测品牌色 —— 判据钉在画出去的底上。
      const devicePrimary = Color(0xFF336383); // 真机 scheme.primary
      const deviceStrip = Color(0xFFE9EEF5); // 真机 surfaceContainerHigh
      tester.view.physicalSize = const Size(375, 814) * 3.0;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) {
              final base = Theme.of(context);
              return Theme(
                data: base.copyWith(
                  colorScheme: base.colorScheme.copyWith(
                    primary: devicePrimary,
                    surfaceContainerHigh: deviceStrip,
                  ),
                ),
                child: Scaffold(body: OfficeSlidesDeckView(deck: _deck)),
              );
            },
          ),
        ),
      );
      await tester.pump();

      final stripColor = (tester
          .widget<Material>(find.byKey(const Key('office-slides-thumbnails')))
          .color)!;
      expect(
        stripColor.toARGB32(),
        deviceStrip.toARGB32(),
        reason: '夹具没生效：胶片栏底色不是真机量到的那个',
      );

      final tile = tester.widget<Container>(
        find.byKey(const Key('office-slides-thumb-selected-0')),
      );
      final tileColor = (tile.decoration! as BoxDecoration).color!;
      final fill = Color.alphaBlend(tileColor, stripColor);

      final numText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('office-slides-thumb-selected-0')),
          matching: find.text('1'),
        ),
      );
      final fg = numText.style!.color!;
      final got = DesignPalette.contrastRatio(fg, fill);
      expect(
        got,
        greaterThanOrEqualTo(4.5),
        reason:
            '选中页码不够亮：${fg.toARGB32().toRadixString(16)} on '
            '${fill.toARGB32().toRadixString(16)} = ${got.toStringAsFixed(2)}:1'
            '（真机 r609 亮色就是 4.41 掉出去的）',
      );
    });

    testWidgets('★ 当前页高亮唯一，并且跟着翻页移动', (tester) async {
      await _pump(tester);

      expect(
        find.byKey(const Key('office-slides-thumb-selected-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-slides-thumb-selected-1')),
        findsNothing,
      );

      // ⚠️ 用**点缩略图**跳页（确定性），而不是 fling：`PageView` 的 fling
      // 在窄屏上会一次滚过好几页（实测 375dp 宽时 1 → 3），
      // 那样"高亮跟着翻页走"这条断言就依赖了物理参数。
      await tester.tap(find.byKey(const Key('office-slides-thumb-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('office-slides-thumb-selected-0')),
        findsNothing,
        reason: '翻页后旧页的高亮必须消失（同时有两个高亮 = 用户分不清在第几页）',
      );
      expect(
        find.byKey(const Key('office-slides-thumb-selected-1')),
        findsOneWidget,
      );
      // 全条**有且只有一个**高亮。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'office-slides-thumb-selected-',
              ),
        ),
        findsOneWidget,
      );
    });
  });

  // ── ④ 底部系统区 ───────────────────────────────────────────────────────
  group('④ 底部让开系统区（导航栏 / 手势区）', () {
    testWidgets('★ 只报告手势区、导航栏为 0 时（本机真机情况）也要让开手势区', (tester) async {
      // 真机实测：NAVIGATION_BAR 高 0px、BOTTOM_MANDATORY_GESTURES 高 123px。
      // 只读 viewPadding ⇒ 0 ⇒ 序号落在系统手势条上。
      await _pump(
        tester,
        systemGestureInsets: const EdgeInsets.only(bottom: 40),
      );

      final inset = tester.getSize(
        find.byKey(const Key('office-slides-bottom-inset')),
      );
      expect(inset.height, 40, reason: '系统手势区 40dp 必须被让开（否则缩略图点按会被系统抢走）');

      final deckRect = tester.getRect(
        find.byKey(const Key('office-slides-deck')),
      );
      final strip = tester.getRect(
        find.byKey(const Key('office-slides-thumbnails')),
      );
      expect(
        deckRect.bottom - strip.bottom,
        closeTo(40, 0.5),
        reason: '胶片栏（含序号）必须整个落在系统手势区**上方**',
      );
    });

    testWidgets('两种 inset 取**较大值**', (tester) async {
      await _pump(
        tester,
        viewPadding: const EdgeInsets.only(bottom: 30),
        systemGestureInsets: const EdgeInsets.only(bottom: 24),
      );
      expect(
        tester
            .getSize(find.byKey(const Key('office-slides-bottom-inset')))
            .height,
        30,
      );
    });
  });

  // ── ⑥ 竖屏备注面板：用掉留白，但不缩小画布 ──────────────────────────────
  group('⑥ 竖屏备注面板放在画布下方', () {
    testWidgets('★ 打开备注不会缩小画布（画布是宽受限的）', (tester) async {
      await _pump(tester);
      final before = tester.getSize(
        find.byKey(const Key('office-slides-canvas-0')),
      );

      await tester.tap(find.byKey(const Key('office-slides-notes-toggle')));
      await tester.pump();

      final panel = tester.getRect(
        find.byKey(const Key('office-slides-notes-panel')),
      );
      final canvas = tester.getRect(
        find.byKey(const Key('office-slides-canvas-0')),
      );
      final strip = tester.getRect(
        find.byKey(const Key('office-slides-thumbnails')),
      );

      expect(
        find.byKey(const Key('office-slides-notes-panel')),
        findsOneWidget,
      );
      expect(
        panel.top,
        greaterThanOrEqualTo(canvas.bottom - 0.5),
        reason: '竖屏备注面板必须在画布**下方**（放在上方会把画布往下推）',
      );
      expect(
        panel.bottom,
        lessThanOrEqualTo(strip.top + 0.5),
        reason: '备注面板在胶片栏上方',
      );
      expect(
        canvas.size,
        before,
        reason:
            '备注面板占用的是画布下方的**本来白扔的**竖向空间；'
            '画布宽受限，所以它一像素都不该缩',
      );
    });
  });

  // ── ⑦ 放映模式 ─────────────────────────────────────────────────────────
  group('⑦ 全屏放映：点按翻页 + 工具条自动隐藏', () {
    // ⚠️ `_pump` 把视口设成 375×814（真机逻辑尺寸），所以点按坐标必须落在
    // 这个范围内 —— 点按区的阈值也按它算：顶部 12% = 97.7dp、左 20% = 75dp。
    const center = Offset(187, 400);
    const leftZone = Offset(30, 400);
    const topZone = Offset(187, 30);

    Future<void> openFullscreen(
      WidgetTester tester, {
      OSlidesDeck? deck,
    }) async {
      await _pump(tester, deck: deck);
      await tester.tap(find.byKey(const Key('office-slides-fullscreen')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-fullscreen-view')),
        findsOneWidget,
      );
    }

    int currentPage(WidgetTester tester) {
      final text = tester
          .widget<Text>(
            find.byKey(const Key('office-slides-fullscreen-indicator')),
          )
          .data!;
      return int.parse(text.split('/').first.trim());
    }

    testWidgets('★ 点按画面（右侧/中间）⇒ 翻到下一页', (tester) async {
      await openFullscreen(tester);
      expect(currentPage(tester), 1);

      await tester.tapAt(center);
      await tester.pumpAndSettle();

      expect(currentPage(tester), 2, reason: '点按画面应当翻到下一页');
    });

    testWidgets('★ 点按最左侧 20% ⇒ 回上一页', (tester) async {
      await openFullscreen(tester);
      await tester.tapAt(center); // → 第 2 页
      await tester.pumpAndSettle();
      expect(currentPage(tester), 2);

      await tester.tapAt(leftZone);
      await tester.pumpAndSettle();
      expect(currentPage(tester), 1, reason: '左侧 20% 是"上一页"区');
    });

    testWidgets('★ 拖动不会被误判成额外的一次"点按翻页"', (tester) async {
      await openFullscreen(tester);
      final before = currentPage(tester);
      final g = await tester.startGesture(center);
      await g.moveBy(const Offset(-120, 0));
      await g.up();
      await tester.pumpAndSettle();
      // 拖动本身就是翻页手势（可能翻 1 页），但**不能**因为"位移超过了
      // slop"而被再算一次点按 ⇒ 一次拖动最多前进一页。
      expect(
        currentPage(tester) - before,
        lessThanOrEqualTo(1),
        reason: '一次拖动被算成了两次翻页（点按判定没有扣掉位移）',
      );
    });

    testWidgets('★ 工具条 3 秒后自动隐藏；点按顶部区域可以呼出', (tester) async {
      await openFullscreen(tester);
      expect(
        find.byKey(const Key('office-slides-fullscreen-chrome')),
        findsOneWidget,
        reason: '刚进放映时工具条可见（用户需要看到怎么退出）',
      );

      await tester.pump(const Duration(seconds: 4));
      expect(
        find.byKey(const Key('office-slides-fullscreen-chrome')),
        findsNothing,
        reason: '3 秒无操作后工具条必须隐藏（放映要的是整屏画面）',
      );

      await tester.tapAt(topZone);
      await tester.pump();
      expect(
        find.byKey(const Key('office-slides-fullscreen-chrome')),
        findsOneWidget,
        reason: '必须有一条"把工具条找回来"的路，否则隐藏工具条会把用户困住',
      );
    });

    testWidgets('★ 最后一页再点一次 ⇒ 退出放映', (tester) async {
      // `celestial.oslides` 只有 1 页 ⇒ 首页就是末页。
      final one = OSlidesDeck.parse(_fixture('celestial.oslides'))!;
      expect(one.slides.length, 1, reason: '夹具坏了：这份样本应当只有 1 页');

      await openFullscreen(tester, deck: one);
      await tester.tapAt(center);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('office-slides-fullscreen-view')),
        findsNothing,
        reason: '末页点按应当退出放映（官方放映器的收尾方式）',
      );
    });
  });
}
