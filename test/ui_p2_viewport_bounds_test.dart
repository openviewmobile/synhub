// D5（部分）：P2-7 ~ P2-9 的 `MediaQuery.sizeOf(...) * 系数` 现在带安全上下界。
//
// 这里证明两件事：
//   ① 边界只在极端视口生效：审计矩阵用到的宽 360/393/411/800、高
//      640/852/891/1280 上，结果与"裸系数"逐像素相同（**零外观回归**）；
//   ② 边界本身有效：极窄 / 极矮视口不再把尺寸压到趋近 0，超大视口也不会无上界。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/ui/viewport_bound.dart';

/// 审计矩阵的实际视口（与 test/ui_overflow_audit_test.dart 的 kAuditSizes 对齐）
const _auditWidths = [360.0, 393.0, 411.0, 800.0];
const _auditHeights = [640.0, 852.0, 891.0, 1280.0];

void main() {
  group('boundedViewportWidth（P2-7）', () {
    test('审计宽度上 = 裸 0.78 系数（零回归）', () {
      for (final w in _auditWidths) {
        expect(
          boundedViewportWidth(w, 0.78),
          closeTo(w * 0.78, 1e-9),
          reason: 'width=$w',
        );
      }
    });

    test('极窄视口被下界托住、超宽视口被上界夹住', () {
      expect(boundedViewportWidth(100, 0.78), 160.0);
      expect(boundedViewportWidth(0, 0.78), 160.0);
      expect(boundedViewportWidth(2000, 0.78), 900.0);
      expect(boundedViewportWidth(4000, 0.78), 900.0);
    });

    test('非递减且始终有限', () {
      double? prev;
      for (var w = 0.0; w <= 4000; w += 50) {
        final v = boundedViewportWidth(w, 0.78);
        expect(v.isFinite, isTrue);
        if (prev != null) expect(v, greaterThanOrEqualTo(prev - 1e-9));
        prev = v;
      }
    });
  });

  group('boundedViewportHeight（P2-8 / P2-9）', () {
    test('审计高度上 = 裸系数（0.86 与 0.7 都零回归）', () {
      for (final h in _auditHeights) {
        expect(boundedViewportHeight(h, 0.86), closeTo(h * 0.86, 1e-9));
        expect(boundedViewportHeight(h, 0.7), closeTo(h * 0.7, 1e-9));
      }
    });

    test('极矮视口被下界托住、超高视口被上界夹住', () {
      expect(boundedViewportHeight(100, 0.7), 180.0);
      expect(boundedViewportHeight(0, 0.86), 180.0);
      expect(boundedViewportHeight(3000, 0.7), 1200.0);
      expect(boundedViewportHeight(3000, 0.86), 1200.0);
    });

    test('非递减且始终有限', () {
      double? prev;
      for (var h = 0.0; h <= 4000; h += 50) {
        final v = boundedViewportHeight(h, 0.7);
        expect(v.isFinite, isTrue);
        if (prev != null) expect(v, greaterThanOrEqualTo(prev - 1e-9));
        prev = v;
      }
    });
  });

  group('边界不会造成溢出（外层约束仍优先）', () {
    testWidgets('父级比下界更窄/更矮时，ConstrainedBox 自动被父级夹紧', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 100,
                child: ConstrainedBox(
                  key: const Key('bound-probe'),
                  constraints: const BoxConstraints(
                    maxWidth: 160,
                    maxHeight: 180,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
      final box = tester.getSize(find.byKey(const Key('bound-probe')));
      expect(box.width, lessThanOrEqualTo(120));
      expect(box.height, lessThanOrEqualTo(100));
      expect(tester.takeException(), isNull);
    });
  });
}
