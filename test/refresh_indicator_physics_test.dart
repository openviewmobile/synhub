// DA87 · 静态守卫：`RefreshIndicator` 里的可滚动组件必须**始终可滚**。
//
// 为什么需要这条守卫（r430 真机 A/B 定性的根因）：
//   `RefreshIndicator` 只有在**下拉产生 overscroll** 时才会回调 `onRefresh`；
//   若里面的 `CustomScrollView`/`ListView`/`GridView` 用默认 physics，内容比视口矮时
//   **滚不动 ⇒ 下拉手势根本到不了回调** ⇒ 用户看到"下拉刷新没反应"、数据停在旧值。
//   r430 之前全仓 **24 个 `RefreshIndicator` 里有 23 个**没写 physics（唯一写对的是
//   `audio_web_queue_page.dart`）——所以这不是文件页一处的笔误，而是一族。
//
// 判据（扫源码，不靠人记）：
//   ① 每个 `RefreshIndicator(` 之后**第一次出现的**可滚动组件，其参数表里必须有
//      `physics:`,且值必须是 `AlwaysScrollableScrollPhysics`；
//   ② 找不到可滚动组件的站点也要点名（可能是把刷新挂在了不可滚动的东西上）。
//
// ★ 反向验证（r430 实测）：把 `file_browse_page.dart` 的那行 physics 删掉 ⇒ 本守卫与
//   `file_browse_ui_test.dart` 的 `DA87` 行为用例**同时红**，恢复即绿。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一个站点：`RefreshIndicator(` 所在文件/行号 + 紧随其后的可滚动组件。
class _Site {
  _Site(this.file, this.line, this.widget, this.physics);

  final String file;
  final int line;

  /// 紧随 `RefreshIndicator(` 之后第一次出现的可滚动组件名（含 `.builder` 等后缀）
  final String? widget;

  /// 该组件参数表里 `physics:` 的值（没有则 null）
  final String? physics;

  @override
  String toString() =>
      '$file:$line  ${widget ?? "（找不到可滚动组件）"}  '
      'physics=${physics ?? "（没写）"}';
}

final RegExp _scrollRe = RegExp(
  r'\b(CustomScrollView|ListView|GridView|SingleChildScrollView|PageView'
  r'|ReorderableListView|ListWheelScrollView)(\.[a-zA-Z]+)?\(',
);
final RegExp _physicsRe = RegExp(r'\bphysics\s*:\s*([^,\n]+)');

/// 扫 `lib/` 下所有 `RefreshIndicator` 站点。
List<_Site> _scanSites() {
  final sites = <_Site>[];
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final s = f.readAsStringSync();
    if (!s.contains('RefreshIndicator(')) continue;
    for (final m in RegExp(r'RefreshIndicator\(').allMatches(s)) {
      final lineNo = '\n'.allMatches(s.substring(0, m.start)).length + 1;
      final tailEnd = m.end + 1200 < s.length ? m.end + 1200 : s.length;
      final tail = s.substring(m.end, tailEnd);
      final sc = _scrollRe.firstMatch(tail);
      if (sc == null) {
        sites.add(_Site(f.path, lineNo, null, null));
        continue;
      }
      // 取该组件参数表的平衡括号范围，只在**它自己**的参数里找 physics
      final start = m.end + sc.end;
      var i = start;
      var depth = 1;
      while (i < s.length && depth > 0) {
        if (s[i] == '(') {
          depth++;
        } else if (s[i] == ')') {
          depth--;
        }
        i++;
      }
      final args = s.substring(start, i - 1);
      final ph = _physicsRe.firstMatch(args);
      sites.add(
        _Site(f.path, lineNo, sc.group(0)!.substring(0, sc.group(0)!.length - 1),
            ph?.group(1)?.trim()),
      );
    }
  }
  return sites;
}

void main() {
  test('DA87：RefreshIndicator 里的滚动组件一律 AlwaysScrollableScrollPhysics', () {
    final sites = _scanSites();
    // 站点数不是成功指标，但为 0 一定是扫描坏了（假绿）
    expect(sites, isNotEmpty, reason: '一个站点都没扫到 ⇒ 扫描器坏了，不是"全都合规"');

    final bad = sites
        .where((s) => s.physics == null || !s.physics!.contains('AlwaysScrollable'))
        .toList();
    expect(
      bad,
      isEmpty,
      reason:
          'DA87：下面这些 RefreshIndicator 的滚动组件没写 AlwaysScrollableScrollPhysics\n'
          '⇒ 内容不足一屏时下拉刷新**收不到回调**（真机 A/B：大列表能刷 / 短列表恒旧值）。\n'
          '修法：给紧随其后的滚动组件加 `physics: const AlwaysScrollableScrollPhysics(),`\n'
          '${bad.map((s) => '  · $s').join('\n')}',
    );
  });

  test('DA87：站点数与文件分布（防止"扫了个空目录"式假绿）', () {
    final sites = _scanSites();
    final files = sites.map((s) => s.file).toSet();
    // r430 实测：24 个站点、分布在 23 个文件里
    expect(sites.length, greaterThanOrEqualTo(24));
    expect(files.length, greaterThanOrEqualTo(20));
    expect(
      sites.where((s) => s.widget == null),
      isEmpty,
      reason: '`RefreshIndicator` 后面必须真有一个可滚动组件（否则刷新根本没法触发）',
    );
  });
}
