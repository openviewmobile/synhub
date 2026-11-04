import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ★ 第 258 轮：顶部工具条动作在窄屏下会**折叠进 `⋮` 菜单**
// （9 个 48dp 点击区在 420dp 里排不下 —— 这正是用户报的"按钮叠在一起/误触"）。
// 所以"点某个顶部动作"或"断言某个顶部动作在不在"都**不能**再直接
// `find.byTooltip(...)`：它可能正在菜单里。
//
// 用法：
// ```dart
// await tapHeaderAction(tester, '回收站');
// expect(await hasHeaderAction(tester, '分享链接'), isTrue);
// ```

// 行内有就点行内；没有就打开 `⋮` 再点菜单里那一项（菜单项文字 = tooltip）。
Future<void> tapHeaderAction(WidgetTester tester, String tooltip) async {
  final inline = find.byTooltip(tooltip);
  if (inline.evaluate().isNotEmpty) {
    await tester.tap(inline.first);
  } else {
    await tester.tap(find.byKey(const Key('bar-overflow')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(tooltip).last);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

// 这个顶部动作现在可达吗（行内 or `⋮` 菜单里）？查完会把菜单关掉。
Future<bool> hasHeaderAction(WidgetTester tester, String tooltip) async {
  if (find.byTooltip(tooltip).evaluate().isNotEmpty) return true;
  final overflow = find.byKey(const Key('bar-overflow'));
  if (overflow.evaluate().isEmpty) return false;
  await tester.tap(overflow);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  final found = find.text(tooltip).evaluate().isNotEmpty;
  // 关掉菜单，别把打开状态留给下一个断言
  final barrier = find.byType(ModalBarrier);
  if (barrier.evaluate().isNotEmpty) {
    await tester.tap(barrier.last, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
  return found;
}
