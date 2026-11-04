// ★★★ 第 349 轮 D68：**"量不出来"不等于"放不下"**。
//
// 真机/桌面实测（1280×800，同一段文本、同一套样式）：
//   * 预算拿得到 → `maxWidth=1120.0` → 判"放得下" → 画出来 ✓
//   * 预算拿不到 → `maxWidth=0.0`   → **旧判据返回 false ⇒ 整行换成 `' '`** ✗
//
// 后者会把"太长就藏"退化成"**永远不显示**"：任何"还没量到"的构建帧
// （路由转场、折叠头、`Localizations` 未就绪的首帧…）都会被抹成空白。
//
// 本文件钉住三件事：
//   ① 预算未知（非有限 / ≤0）⇒ 判**放得下**（照画）；
//   ② 预算已知且**确实超出** ⇒ 判放不下（D65 的"太长就藏"没有被放松）；
//   ③ 预算已知且放得下 ⇒ 判放得下。
// ②③ 是反向验证：少了它们，"永远返回 true"也能让 ① 全绿（§2.0.29 同型）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/ui/text_fit.dart';

void main() {
  group('★ r349 D68 单行判据：只有"量到了且确实超出"才算放不下', () {
    Future<void> pump(WidgetTester tester, void Function(BuildContext) body) {
      return tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              body(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    }

    const text = '通讯录 · 标签 · CardDAV';
    final style = const TextStyle(fontSize: 11);

    testWidgets('① 预算未知（double.infinity）⇒ 判放得下（照画，不许整行消失）', (
      tester,
    ) async {
      late bool fits;
      await pump(tester, (c) {
        fits = textFitsOnOneLine(c, text, style, double.infinity);
      });
      expect(fits, isTrue, reason: '无界上下文里文本本来就不会溢出，不该被判死');
    });

    testWidgets('① 预算还没量到（0 / 负数）⇒ 判放得下（不许整行消失）', (tester) async {
      late bool zero;
      late bool neg;
      await pump(tester, (c) {
        zero = textFitsOnOneLine(c, text, style, 0);
        neg = textFitsOnOneLine(c, text, style, -5);
      });
      expect(zero, isTrue, reason: 'maxWidth=0（实测就是这一档）不许把副标题抹成空白');
      expect(neg, isTrue);
    });

    testWidgets('② ★ 反向：预算已知且确实超出 ⇒ 必须判放不下', (tester) async {
      late bool fits;
      await pump(tester, (c) {
        fits = textFitsOnOneLine(c, text, style, 40);
      });
      expect(fits, isFalse, reason: '40px 装不下这段文本，判据必须能判否');
    });

    testWidgets('③ ★ 反向：预算已知且放得下 ⇒ 必须判放得下', (tester) async {
      late bool fits;
      await pump(tester, (c) {
        fits = textFitsOnOneLine(c, text, style, 4000);
      });
      expect(fits, isTrue);
    });
  });
}
