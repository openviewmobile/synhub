// r121：**静态动作覆盖守卫** —— 多选条发出的每个动作名，`_runAction` 里都必须有 `case`。
//
// 为什么需要它：`_SelectionBar` 的「更多」按钮发 `onAction('more')`，而
// `_runAction` 的 `switch` 里**没有 `case 'more'`** ⇒ 真机点按**毫无反应**
// （像素取证 `/tmp/r121_ui/files_16_more.png` → `files_17_more2.png` 前后无变化）。
// 这类缺陷单测抓不到（没人点它），UI 用例要跑到才有反应 ⇒ 补一条**静态**守卫，
// 加动作时忘了写分支会当场红。
//
// ★ 反向验证（本文件最后一条）：把**修复前**的 switch（没有 `case 'more'`）
// 喂给同一个探测器，必须真的报出 `more` 未被处理 —— 否则这条守卫就是空转。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _pagePath = 'lib/src/features/files/file_browse_page.dart';

/// 取 `class <name>` 到下一个顶层 `class ` 之间的正文（够用即可，不做完整解析）
String _classBody(String src, String name) {
  final start = src.indexOf('class $name');
  if (start < 0) return '';
  final next = src.indexOf('\nclass ', start + 1);
  return next < 0 ? src.substring(start) : src.substring(start, next);
}

/// `_SelectionBar` 里所有 `_barAction(...)` 的**最后一个字符串字面量** = 动作名，
/// 加上直接写死的 `onAction('x')`。
Set<String> emittedSelectionActions(String src) {
  final bar = _classBody(src, '_SelectionBar');
  final ids = <String>{};
  for (final m in RegExp(r"onAction\('([a-z_]+)'\)").allMatches(bar)) {
    ids.add(m.group(1)!);
  }
  var from = 0;
  while (true) {
    final i = bar.indexOf('_barAction(', from);
    if (i < 0) break;
    var depth = 0;
    var j = i + '_barAction'.length;
    for (; j < bar.length; j++) {
      final c = bar[j];
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    final call = bar.substring(i, j + 1);
    final lits = RegExp(r"'([a-z_]+)'").allMatches(call).toList();
    if (lits.isNotEmpty) ids.add(lits.last.group(1)!);
    from = j + 1;
  }
  return ids;
}

/// `_runAction` 的 switch 里出现的 `case 'x':`
///
/// ★ 必须**限定在 `_runAction` 自己这一支里**：不设边界的话，
/// `substring(indexOf('_runAction('))` 会把文件后面所有方法的 `case` 也吃进来，
/// 于是"没分支"也会被判成有分支（守卫空转）。
Set<String> handledActionCases(String src) {
  final start = src.indexOf('Future<void> _runAction(');
  if (start < 0) return <String>{};
  final rest = src.substring(start + 1);
  // 下一个同级成员（两个空格缩进的 `Future<` 或 `///` 注释）就是边界
  var end = rest.length;
  for (final marker in <String>['\n  Future<', '\n  /// ', '\n  void ']) {
    final i = rest.indexOf(marker);
    if (i >= 0 && i < end) end = i;
  }
  final body = rest.substring(0, end);
  return RegExp(r"case '([a-z_]+)'\s*:")
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  test('多选条发出的每个动作名，_runAction 都真的有 case（防空按钮）', () {
    final src = File(_pagePath).readAsStringSync();
    final emitted = emittedSelectionActions(src);
    final handled = handledActionCases(src);

    expect(
      emitted,
      containsAll(<String>{'download', 'copy', 'move', 'compress', 'delete'}),
      reason: '抽样自检：连内联动作都没解析到 ⇒ 说明探测器坏了（防空转）',
    );
    expect(emitted, contains('more'), reason: '「更多」按钮就发 more');
    expect(
      emitted.difference(handled),
      isEmpty,
      reason: '这些动作发了但 _runAction 没有分支 ⇒ 真机点按无反应（死按钮）',
    );
  });

  test('★ 反向验证：修复前的 switch（无 case more）必须被同一条守卫判红', () {
    final src = File(_pagePath).readAsStringSync();
    // 把真实源码里的 `case 'more':` 那一支**删掉**，模拟修复前的状态。
    final start = src.indexOf("        case 'more':");
    expect(start, greaterThan(0), reason: '真实源码里必须真的有 case more');
    // `case 'more'` 是 switch 的最后一支 ⇒ 用 switch 的收尾作边界
    final end = src.indexOf('\n      }\n    } catch', start);
    expect(end, greaterThan(start), reason: '用 switch 收尾作删除边界');
    final preFix = src.substring(0, start) + src.substring(end);

    final emitted = emittedSelectionActions(preFix);
    final handled = handledActionCases(preFix);
    final uncovered = emitted.difference(handled);

    expect(
      uncovered,
      contains('more'),
      reason: '反向验证失败 ⇒ 这条守卫抓不到死按钮，等于空转',
    );
    // 修复后的真实源码必须没有遗漏
    final realEmitted = emittedSelectionActions(src);
    expect(realEmitted.difference(handledActionCases(src)), isEmpty);
  });
}
