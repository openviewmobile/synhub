// 无障碍 / 对比度 / 触控目标的"硬指标"测试。
//
// 这一层不靠眼睛看，靠算：
//   1. **对比度**：小字（遥测/正文）≥ 4.5:1，大字或非文字语义色 ≥ 3:1，
//      纯装饰（刻度/网格）只要"看得见"（≥ 1.4:1）。亮暗两套主题都要过 ——
//      新增的科幻层在暗色下最容易被"炫"过头而牺牲可读性。
//   2. **触控目标**：可点控件不得小于 48×48（Material 最小可点区域），
//      视觉可以更小，但命中区不能小。
//   3. **语义**：装饰性铬部件（面板代号、滚动数据带）不进无障碍树，
//      真正承载信息的控件必须有 label。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/core/ui/glass_text_field.dart';
import 'package:synhub/src/core/ui/orb_button.dart';
import 'package:synhub/src/core/ui/tech_frame.dart';

/// WCAG 相对亮度
double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// 把 [fg]（可能带透明度）叠在 [bg] 上（bg 假定不透明）
Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

double contrast(Color fg, Color bg) {
  final a = _lum(_over(fg, bg)), b = _lum(bg);
  final hi = math.max(a, b), lo = math.min(a, b);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final entry in {
    '亮色': HudTokens.light(
      ColorScheme.fromSeed(
        seedColor: AppTheme.seed,
        brightness: Brightness.light,
      ),
    ),
    '暗色': HudTokens.dark(
      ColorScheme.fromSeed(
        seedColor: AppTheme.seed,
        brightness: Brightness.dark,
      ),
    ),
  }.entries) {
    final name = entry.key;
    final hud = entry.value;
    final scheme = name == '亮色'
        ? ColorScheme.fromSeed(
            seedColor: AppTheme.seed,
            brightness: Brightness.light,
          )
        : ColorScheme.fromSeed(
            seedColor: AppTheme.seed,
            brightness: Brightness.dark,
          );

    group('$name 主题的对比度', () {
      test('遥测小字 / 正文（≥4.5:1）', () {
        expect(
          contrast(hud.meta, hud.glassStrong),
          greaterThanOrEqualTo(4.5),
          reason: '遥测小字在玻璃面板上',
        );
        expect(
          contrast(scheme.onSurface, hud.deep),
          greaterThanOrEqualTo(4.5),
          reason: '正文在深空底上',
        );
        expect(
          contrast(scheme.onSurfaceVariant, hud.deep),
          greaterThanOrEqualTo(4.5),
          reason: '次级文字在深空底上',
        );
      });

      test('消息气泡（≥4.5:1）', () {
        expect(
          contrast(hud.bubbleMineText, hud.bubbleMine),
          greaterThanOrEqualTo(4.5),
          reason: '我发的气泡文字',
        );
        expect(
          contrast(hud.bubbleOtherText, hud.bubbleOther),
          greaterThanOrEqualTo(4.5),
          reason: '对方气泡文字',
        );
      });

      test('语义色（≥3:1，且不靠色相单独编码）', () {
        for (final c in [hud.online, hud.warning, hud.star]) {
          expect(contrast(c, hud.deep), greaterThanOrEqualTo(3.0));
        }
        expect(contrast(hud.scan, hud.deep), greaterThanOrEqualTo(3.0));
      });

      test('装饰层只要看得见（≥1.4:1）', () {
        expect(
          contrast(hud.tick, hud.deep),
          greaterThanOrEqualTo(1.4),
          reason: '边缘刻度',
        );
        expect(
          contrast(hud.bracket, hud.deep),
          greaterThanOrEqualTo(1.4),
          reason: '角括号',
        );
        expect(
          contrast(hud.horizon, hud.deep),
          greaterThanOrEqualTo(1.4),
          reason: '透视网格地平线',
        );
        expect(
          contrast(hud.grid, hud.deep),
          greaterThanOrEqualTo(1.2),
          reason: '聊天页网格底纹（可以很淡）',
        );
        expect(
          contrast(hud.particle, hud.deep),
          greaterThanOrEqualTo(1.5),
          reason: '星尘粒子',
        );
      });

      test('深空底不是纯黑/纯白（给玻璃与渐晕留余地）', () {
        final l = _lum(hud.deep);
        expect(l, greaterThan(0.005), reason: '暗色也别压成 #000');
        expect(l, lessThan(0.95), reason: '亮色也别压成 #fff');
      });
    });
  }

  group('触控目标', () {
    testWidgets('HudIconButton 视觉 40 但命中区 ≥48', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: HudIconButton(
                icon: Icons.search,
                tooltip: '搜索',
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final box = tester.getSize(find.byType(HudIconButton));
      expect(box.width, greaterThanOrEqualTo(48));
      expect(box.height, greaterThanOrEqualTo(48));
    });

    testWidgets('OrbButton 默认尺寸 ≥48，且带无障碍标签', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: OrbButton(
                icon: Icons.arrow_downward,
                tooltip: '回到最新',
                semanticLabel: '回到最新',
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final box = tester.getSize(find.byType(OrbButton));
      expect(box.width, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel('回到最新'), findsWidgets);
    });
  });

  group('语义树', () {
    testWidgets('面板代号 / 刻度 / 数据带不进无障碍树，内容与标题仍在', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: TechFrame(
                  label: 'ENDPOINT',
                  code: '0x1F',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TelemetryRow(label: 'HOST', value: 'nas.example.com'),
                      DataStrip(items: ['SRM 1.3', 'AES-256']),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tree = tester.binding.rootElement!
          .findRenderObject()!
          .debugSemantics!
          .toStringDeep();
      // 装饰性的面板代号与滚动带：不出现
      expect(tree.contains('ENDPOINT'), isFalse, reason: '面板代号是装饰');
      expect(tree.contains('0x1F'), isFalse, reason: '仪器编号是装饰');
      expect(tree.contains('AES-256'), isFalse, reason: '滚动数据带是装饰');
      // 真正的信息：保留
      expect(tree.contains('nas.example.com'), isTrue, reason: '遥测行是信息');
      handle.dispose();
    });
  });

  group('窄屏文本预算', () {
    // 这一条是被真实 bug 逼出来的：TelemetryRow 以前只有中间的点线是
    // Expanded，label/value 不设上限 —— 真实 QuickConnect ID / conn_id 一长，
    // 320dp 上必然 RenderFlex 溢出（诊断页当时只能自己写截断规避）。
    testWidgets('TelemetryRow 超长 label/value 在 320dp 下不溢出且保留完整值', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const longId =
          'demo_admin-qq-very-long-quickconnect-id-0123456789-abcdefghijkl';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 304,
                  child: TelemetryRow(label: 'TARGET', value: longId),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 省略号只是渲染层的事，语义/查找里仍是完整值
      expect(find.text(longId), findsOneWidget);
    });

    testWidgets('GlassTextField 聚焦不溢出且是可编辑语义节点', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      final c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 288,
                child: GlassTextField(
                  controller: c,
                  labelText: 'QuickConnect ID',
                  helperText: '例如 demo_admin-qq',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final tree = tester.binding.rootElement!
          .findRenderObject()!
          .debugSemantics!
          .toStringDeep();
      expect(
        tree.contains('QuickConnect ID'),
        isTrue,
        reason: 'label 必须在无障碍树里',
      );
      handle.dispose();
    });
  });
}
