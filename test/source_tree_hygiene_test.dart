// 静态守卫：**源码树里不许留改文件时的备份 / 冲突残留**。
//
// ★ 为什么会有这条（第 331 轮）：
//   r273/r330 打补丁时我用 `cp <file> <file>.bak.rNNN` 留备份，**13 个副本留在了 `lib/` 里**
//   （`.bak.r330` 等）。它们**不是 `.dart`** ⇒ 不编译、`flutter analyze` 不报、没人发现。
//   危害不是占空间，而是**污染静态审计**：任何"扫 `lib/` 下所有文件"的守卫/审计
//   （i18n 守、诊断串守、D32 的按钮形状守）读到备份就会把**旧代码**当现状
//   （同族见 AGENTS §2.0.48「纯文本扫描守卫会把注释数进去」）。
//
// 判据：`lib/` `test/` `integration_test/` `tool/` 下不许出现
//   `*.bak.*`（含 `*.bak.rNNN`）/ `*.orig` / `*~` / `*.rej`。
//
// ★ 反向验证：下面第二条**故意构造**一个匹配名，证明"扫得出来"——
//   否则"0 条命中"可能只是判据写错了（AGENTS §1.3.0.1「校验 0 条不是成功，是没校验」）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 备份/残留的判据（**只认这几个形状**，别用 `contains('bak')` 那种宽判据：
/// 会把 `backup_page.dart` 这类正常文件判红）。
final RegExp _leftoverRe = RegExp(r'(\.bak\.|\.bak$|\.orig$|\.rej$|~$)');

/// 只扫源码树（`build/`、`.dart_tool/` 里出现什么都不算 ⇒ 不扫它们）。
const List<String> _roots = ['lib', 'test', 'integration_test', 'tool'];

List<String> findLeftovers(List<String> roots, {RegExp? pattern}) {
  final re = pattern ?? _leftoverRe;
  final hits = <String>[];
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (re.hasMatch(name)) hits.add(e.path);
    }
  }
  hits.sort();
  return hits;
}

void main() {
  test('源码树里不许留 *.bak.* / *.orig / *.rej / *~ 残留', () {
    final hits = findLeftovers(_roots);
    expect(
      hits,
      isEmpty,
      reason: '这些是"改文件时的备份"，留在源码树里会污染静态审计；'
          '备份一律放 /tmp（AGENTS §1.6）。命中：\n  ${hits.join('\n  ')}',
    );
  });

  test('★ 反向：判据必须真的能挑出残留名（否则"0 条"是没校验）', () {
    final tmp = Directory.systemTemp.createTempSync('r331_hygiene');
    try {
      // ① 应命中的形状
      final bad = [
        'x.dart.bak.r330',
        'x.dart.bak',
        'x.arb.orig',
        'x.dart.rej',
        'x.dart~',
      ];
      for (final n in bad) {
        File('${tmp.path}/$n').writeAsStringSync('');
      }
      // ② **不该**命中的形状（宽判据会把它们误伤）
      final good = ['backup_page.dart', 'baker.dart', 'note.bak.dart'];
      for (final n in good) {
        File('${tmp.path}/$n').writeAsStringSync('');
      }
      final hits = findLeftovers([tmp.path])
          .map((p) => p.split('/').last)
          .toList();
      for (final n in bad) {
        expect(hits, contains(n), reason: '$n 必须被判为残留');
      }
      // `note.bak.dart` 里含 `.bak.` ⇒ 按判据**应该**命中（它正是"备份改名"的形状）；
      // 其余两个正常名不许误伤。
      expect(hits, isNot(contains('backup_page.dart')));
      expect(hits, isNot(contains('baker.dart')));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
