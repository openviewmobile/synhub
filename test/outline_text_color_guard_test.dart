// ★ r538（DA172）：`outline` / `outlineVariant` 在本项目的两套主题里就是 `dp.line`
// —— 亮色 `#DFE6EF` 对白卡 **1.26:1**、暗色 `#2A3140` 对卡片 **1.27:1**。
// 它只能画**边框/分隔线**；拿来当**文字色**（含 `copyWith(color:)`）等于把字抹掉。
//
// 判据：扫 `lib/src/**/*.dart`，凡 `color: …outline…` 且上下文是文本（`Text(` /
// `copyWith(` / `textTheme`）而不是 `Border`/`Icon` ⇒ 红，并逐条点名。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 允许出现的例外（逐条给理由）；新增例外必须在 `DA172` 里记账。
const Map<String, String> _allowed = {
  // 目前一条都没有：20 处文本色在 r538 全部改成了 onSurfaceVariant。
};

class _Hit {
  _Hit(this.path, this.line, this.text);
  final String path;
  final int line;
  final String text;
  @override
  String toString() => '$path:$line  $text';
}

List<_Hit> _scan(Directory root) {
  final hits = <_Hit>[];
  final files = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
  for (final f in files) {
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      // ★ r545：先把 `Icons.lock_outline` 这类**图标名**剥掉再看 —— 早先整行
      // `contains('Icons.')` 就跳过，会把"图标颜色用 outline"整类漏掉（自己踩过）。
      final stripped = l.replaceAll(RegExp(r'Icons\.[A-Za-z0-9_]+'), '<icon>');
      if (!RegExp(r'\boutline(Variant)?\b').hasMatch(stripped)) continue;
      if (l.trimLeft().startsWith('//')) continue;
      if (!RegExp(r'color\s*:').hasMatch(stripped)) continue;
      final ctx = lines.sublist(i >= 10 ? i - 10 : 0, i + 1).join('\n');
      final isBorder = RegExp(r'BorderSide|Border\.all|Border\.fromBorderSide|Divider|decoration',
              caseSensitive: false)
          .hasMatch(ctx);
      if (isBorder) continue;
      final isIcon = RegExp(r'Icon\(|icon:|iconColor').hasMatch(ctx);
      // ★ r545（DA174）：**图标**也不许用 `outline` —— 40px 空态图标在亮色
      // 只有 1.26:1，等于看不见；图标是"有意义"的（空态/占位/信息提示），
      // 与文字同一判据。所以这里不再跳过。
      if (isIcon) {
        hits.add(_Hit(f.path, i + 1, '${l.trim()}  ← 图标用了 outline'));
        continue;
      }
      final isText =
          RegExp(r'Text\(|textTheme|DefaultTextStyle|copyWith\(').hasMatch(ctx);
      if (!isText) continue;
      final key = '${f.path}:${i + 1}';
      if (_allowed.containsKey(key)) continue;
      hits.add(_Hit(f.path, i + 1, l.trim()));
    }
  }
  return hits;
}

void main() {
  test('DA172/DA174：文字与图标都不许用 outline / outlineVariant（那是边框色）', () {
    final hits = _scan(Directory('lib/src'));
    expect(hits, isEmpty,
        reason: 'DA172/DA174：以下位置把 `outline` 当文字/图标色用了（对比度约 1.26:1）：\n'
            '${hits.join('\n')}');
  });

  test('DA172：扫描器自身有区分力（构造样本必须被抓到）', () {
    final dir = Directory.systemTemp.createTempSync('da172');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/bad.dart').writeAsStringSync('''
Widget build(BuildContext context) {
  return Text(
    'x',
    style: Theme.of(context).textTheme.bodySmall,
    color: Theme.of(context).colorScheme.outline,
  );
}
''');
    File('${dir.path}/ok_border.dart').writeAsStringSync('''
Widget build(BuildContext context) {
  return DecoratedBox(
    decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant)),
  );
}
''');
    File('${dir.path}/bad_icon.dart').writeAsStringSync("""
Widget build(BuildContext context) {
  return Column(children: [
    Icon(Icons.dashboard_outlined, size: 48, color: scheme.outline),
  ]);
}
""");
    File('${dir.path}/ok_icon.dart').writeAsStringSync("""
Widget build(BuildContext context) {
  return Icon(Icons.dashboard_outlined, size: 48, color: scheme.onSurfaceVariant);
}
""");
    File('${dir.path}/ok_text.dart').writeAsStringSync('''
Widget build(BuildContext context) {
  return Text('x', style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant));
}
''');
    final hits = _scan(dir);
    expect(hits.length, 2, reason: '该抓到 bad.dart 与 bad_icon.dart 两处：${hits.join("; ")}');
    expect(hits.map((h) => h.path).join(' '), contains('bad.dart'));
    expect(hits.map((h) => h.path).join(' '), contains('bad_icon.dart'));
  });
}
