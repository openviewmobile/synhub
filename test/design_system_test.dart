// 设计系统（HUD）的守卫测试：
//   * 主题两套都能构造，且都注册了 HudTokens；
//   * 气泡/遥测文字的对比度达到无障碍要求（≥4.5:1）—— 这是"用色必须成体系"
//     的硬约束，改配色时这条会先挡住问题；
//   * ChamferBorder 的路径落在矩形内（切角不会画飞）；
//   * 预览画廊页在亮/暗两套下都能渲染（真机上要看的就是这一页）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_shapes.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/core/theme/app_typography.dart';
import 'package:synhub/src/features/design/design_preview_page.dart';

/// 相对亮度（WCAG）
double _luminance(Color c) => c.computeLuminance();

/// WCAG 对比度
double _contrast(Color a, Color b) {
  final l1 = _luminance(a);
  final l2 = _luminance(b);
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('主题', () {
    test('亮/暗都注册了 HudTokens 且都是 M3', () {
      for (final t in [AppTheme.light(), AppTheme.dark()]) {
        expect(t.useMaterial3, isTrue);
        expect(t.extension<HudTokens>(), isNotNull);
        expect(t.extension<HudTokens>()!.bubbleMine.a, greaterThan(0.8));
      }
    });

    test('动态取色传入时沿用外部方案的主色', () {
      const seed = Color(0xFF7B1FA2);
      final scheme = ColorScheme.fromSeed(seedColor: seed);
      final t = AppTheme.light(dynamic: scheme);
      expect(t.colorScheme.primary, scheme.primary);
      // 令牌里的"我发的"气泡必须来自这个主色，而不是写死的蓝
      expect(
        t.extension<HudTokens>()!.bubbleMine.toARGB32(),
        isNot(AppTheme.light().extension<HudTokens>()!.bubbleMine.toARGB32()),
      );
    });

    test('气泡文字对比度 ≥ 4.5:1（亮/暗都查）', () {
      for (final t in [AppTheme.light(), AppTheme.dark()]) {
        final h = t.extension<HudTokens>()!;
        expect(
          _contrast(h.bubbleMine, h.bubbleMineText),
          greaterThanOrEqualTo(4.5),
          reason: '我发的气泡对比度不足',
        );
        expect(
          _contrast(h.bubbleOther, h.bubbleOtherText),
          greaterThanOrEqualTo(4.5),
          reason: '对方气泡对比度不足',
        );
        expect(
          _contrast(t.colorScheme.surface, t.colorScheme.onSurface),
          greaterThanOrEqualTo(4.5),
          reason: '正文对比度不足',
        );
      }
    });

    test('遥测字用等宽 + tabular figures', () {
      final s = AppType.telemetry();
      expect(s.fontFamily, 'monospace');
      expect(s.fontFeatures, contains(const FontFeature.tabularFigures()));
    });
  });

  group('切角形状', () {
    test('路径落在矩形内且切掉指定的角', () {
      const rect = Rect.fromLTWH(0, 0, 100, 40);
      const border = ChamferBorder(cut: 8);
      final path = border.getOuterPath(rect);
      final bounds = path.getBounds();
      expect(bounds.left, greaterThanOrEqualTo(-0.01));
      expect(bounds.right, lessThanOrEqualTo(rect.right + 0.01));
      // 右上角被切掉：点 (99, 0.5) 一定在路径外
      expect(path.contains(const Offset(99, 0.5)), isFalse);
      // 未切角的左边中部仍在路径内
      expect(path.contains(const Offset(2, 20)), isTrue);
      expect(border.dimensions, EdgeInsets.zero);
    });

    test('四角全切时是一个八边形（中心在内部、四角在外）', () {
      const rect = Rect.fromLTWH(0, 0, 60, 60);
      const border = ChamferBorder(
        cut: 10,
        corners: {
          CutCorner.topLeft,
          CutCorner.topRight,
          CutCorner.bottomRight,
          CutCorner.bottomLeft,
        },
      );
      final path = border.getOuterPath(rect);
      expect(path.contains(const Offset(30, 30)), isTrue);
      for (final corner in const [
        Offset(1, 1),
        Offset(59, 1),
        Offset(59, 59),
        Offset(1, 59),
      ]) {
        expect(path.contains(corner), isFalse);
      }
    });
  });

  group('效果开关', () {
    tearDown(() {
      AppEffects.reducedMotion.value = false;
      AppEffects.reducedBlur.value = false;
    });

    test('减少动效时时长被压到 0', () {
      AppEffects.reducedMotion.value = false;
      expect(Motion.resolve(Motion.base), Motion.base);
      AppEffects.reducedMotion.value = true;
      expect(Motion.resolve(Motion.base), Duration.zero);
      expect(Motion.resolveCurve(Motion.out), Curves.linear);
    });

    test('性能模式关掉毛玻璃', () {
      expect(AppEffects.blurAllowed, isTrue);
      AppEffects.reducedBlur.value = true;
      expect(AppEffects.blurAllowed, isFalse);
    });
  });

  group('设计预览画廊', () {
    Future<void> pump(WidgetTester tester, ThemeData theme) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: theme, home: const DesignPreviewPage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('亮色下渲染出关键积木', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pump(tester, AppTheme.light());

      expect(find.text('设计预览 · HUD'), findsOneWidget);
      // 四个开关（动态取色/性能模式/减少动效/网格底纹）
      expect(find.byType(SwitchListTile), findsNWidgets(4));
      // 其余区块在折叠线以下：ListView 只构建可见项，逐个滚过去看
      final list = find.byType(Scrollable).first;
      for (final text in const [
        '发送失败 · 重试',
        '以下为新消息',
        '产品设计组',
        '还没有消息',
        '底部操作面板',
      ]) {
        await tester.scrollUntilVisible(find.text(text), 300, scrollable: list);
        expect(find.text(text), findsOneWidget, reason: '缺少积木：$text');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('暗色下渲染不报错', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pump(tester, AppTheme.dark());

      expect(find.text('设计预览 · HUD'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('切到"暗"再切回来不会崩', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pump(tester, AppTheme.light());

      // 注意：页面里有常驻循环动画（扫描环/呼吸点），不能用 pumpAndSettle
      await tester.tap(find.text('暗'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('设计预览 · HUD'), findsOneWidget);
      await tester.tap(find.text('亮'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  });
}
