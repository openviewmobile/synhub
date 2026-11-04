// r675 · `DA302`：**矮视口里的空态**必须把标题留在屏幕内。
//
// 发现场景：iPhone 横屏（874×402）走宽屏文件站时，右栏空态区只有 ≈180pt，
// 原来 72pt 图标 + `Gap.xl` 留白 + 标题 + 两行说明 ⇒ 标题被顶到折线外：
// 用户只看到一个圆圈图标（"右栏啥也没有"）。修法：由**调用方**声明
// `compact: true`（矮栏 / 弹层）降到紧凑档（36 图标 + 横排）。
// ★ 第一版用 `LayoutBuilder` 按高度自动降档，在 `AlertDialog`（`IntrinsicWidth`）
//   里直接建不出子树 ⇒ 全量用例 `file_browse_ui_test.dart` 当场抓到，已改。
//
// 判据是**几何**（标题矩形必须落在给定高度内），不是"看起来舒服"。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/ui/app_states.dart';

/// 返回 (标题矩形, 空态盒子矩形) —— 判据一律用**相对**位置：
/// 绝对坐标还带着测试窗口的偏移（第一版就是把这个偏移算进去了 ⇒ 假红）。
Future<(Rect, Rect)> _pumpInHeight(
  WidgetTester tester,
  double height, {
  bool compact = false,
}) async {
  const title = 'Nothing selected yet';
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            height: height,
            child: AppEmptyState(
              icon: Icons.vertical_split_outlined,
              title: title,
              message: 'Click to select on the left.\nDetails show here.',
              compact: compact,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
  return (
    tester.getRect(find.text(title)),
    tester.getRect(find.byType(SingleChildScrollView)),
  );
}

void main() {
  testWidgets('DA302 ①：150pt 高的空态里**标题与说明都在屏幕内**', (tester) async {
    final (title, box) = await _pumpInHeight(tester, 150, compact: true);
    expect(box.height, closeTo(150, 0.5), reason: '前提：被测盒子就是 150pt 高');
    // 标题必须**整体**落在盒子内（含 1px 容差）
    expect(
      title.bottom,
      lessThanOrEqualTo(box.bottom + 1),
      reason: '★ DA302：矮视口里标题矩形底部 ${title.bottom.toStringAsFixed(1)} '
          '超出了盒子底边 ${box.bottom.toStringAsFixed(1)}',
    );
    expect(title.top, greaterThanOrEqualTo(box.top - 1));
    expect(find.text('Nothing selected yet').hitTestable(), findsOneWidget,
        reason: '★ 标题必须能点到（在折线内）');
    // ★ 关键判据：**说明那两行也得看得见** —— iPhone 横屏右栏只有 ≈150pt，
    //   原来只把标题露出来、说明被顶到折线外，用户看到的就是"一个图标"。
    expect(
      find.textContaining('Details show here').hitTestable(),
      findsOneWidget,
      reason: '★ DA302：说明文字被顶出折线（用户只看到图标）',
    );
  });

  testWidgets('DA302 ③：102pt（iPhone 横屏右栏真机读数）里标题必须可见', (tester) async {
    final (title, box) = await _pumpInHeight(tester, 102, compact: true);
    expect(title.top, greaterThanOrEqualTo(box.top - 1));
    expect(title.bottom, lessThanOrEqualTo(box.bottom + 1),
        reason: '★ DA302：102pt 里标题也被顶出去了（真机就这样只剩一个图标）');
    expect(find.text('Nothing selected yet').hitTestable(), findsOneWidget);
    // 横排档连说明也放得下（否则用户只拿到一句"没选中"，不知道点哪儿）
    expect(find.textContaining('Details show here').hitTestable(), findsOneWidget,
        reason: '★ DA302：横排档应能同时放下标题与说明');
  });

  testWidgets('DA302 ②：高视口仍用大图标档（不许把正常尺寸也压小）', (tester) async {
    final (title, box) = await _pumpInHeight(tester, 560);
    // 大档：72 图标 + `Gap.lg` ⇒ 标题顶边距盒子顶边 > 100（紧凑档只有 ≈70）
    expect(title.top - box.top, greaterThan(100),
        reason: '正常高度的空态应保持原来的留白节奏');
  });
}
