// ★★★ 第 316 轮真机缺陷守卫：NoteStation 的时间字段**一律 epoch 秒**。
//
// 真机自证：新建一条笔记 → 列表里它的日期显示 **1985-04-10**（本应是今天）。
// 数值链：我们发 `DateTime.now().millisecondsSinceEpoch` = 1791483240000（13 位）
//   → 服务端按 **32 位整型** 截断 = 1791483240000 % 2^32 = 481877568
//   → 回读时按 **秒** 渲染 = 1985-04-09T22:52Z →（UTC+8）1985-04-10 ✓ 与像素一致。
// 显示侧（`formatFileTime(int seconds)`）与高级搜索（官方
// `AdvancedSearchTask#getTimeInMillis()/1000`）都按秒 ⇒ 写入侧必须同口径。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';

void main() {
  group('★★★ r316 NoteStation 时间口径 = epoch 秒', () {
    test('noteEpochSeconds() 给的是 10 位秒，不是 13 位毫秒', () {
      final at = DateTime(2026, 10, 9, 2, 14, 41);
      final s = noteEpochSeconds(at);
      expect(s, at.millisecondsSinceEpoch ~/ 1000);
      expect('$s'.length, 10, reason: '秒必须是 10 位；13 位就是毫秒（服务端会截断）');
    });

    test('noteEpochSecondsNormalize：毫秒归一到秒，秒原样通过', () {
      // 真机上那条被截断的毫秒值
      expect(noteEpochSecondsNormalize(1791483240000), 1791483240);
      // 秒值不许被再除一次
      expect(noteEpochSecondsNormalize(1791483240), 1791483240);
      // 边界：2026 年的秒 ≈ 1.79e9（10 位），毫秒 ≈ 1.79e12（13 位）
      expect(noteEpochSecondsNormalize(99999999999), 99999999999);
      expect(noteEpochSecondsNormalize(100000000001), 100000000); // 100000000001 ~/ 1000
    });

    test('★ 归一后一定能被 formatFileTime 渲染成"人读的今天/日期"（不是 1985）', () {
      final at = DateTime(2026, 10, 9, 2, 14, 41);
      final ms = at.millisecondsSinceEpoch;
      expect(noteEpochSecondsNormalize(ms), at.millisecondsSinceEpoch ~/ 1000);
      // 反向：不做归一会落到 1985（服务端截断后的读数）—— 证明这条守卫有意义
      const truncatedByServer = 481877568;
      expect(DateTime.fromMillisecondsSinceEpoch(truncatedByServer * 1000).year, 1985);
    });

    test('★★ 静态守卫：笔记写入侧不许再把 millisecondsSinceEpoch 当 ctime/mtime', () {
      // 这四处都曾经踩过（写入 + 本地回落 + 智能笔记本筛选）
      const files = [
        'lib/src/data/note_api.dart',
        'lib/src/features/notes/note_editor_page.dart',
        'lib/src/features/notes/note_sync.dart',
        'lib/src/features/notes/note_smart_page.dart',
      ];
      final offenders = <String>[];
      for (final f in files) {
        final src = File(f).readAsStringSync();
        // `ctime:` / `mtime:` / `mtimeStart:` 之后 160 字符内出现 millisecondsSinceEpoch
        final re = RegExp(
          r"(ctime|mtime|mtimeStart|mtimeEnd)\s*[:=][^;]{0,160}millisecondsSinceEpoch",
          dotAll: true,
        );
        for (final m in re.allMatches(src)) {
          final line = src.substring(0, m.start).split('\n').length;
          offenders.add('$f:$line');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '★ NoteStation 时间字段是 epoch 秒：请用 noteEpochSeconds()/'
            'noteEpochSecondsNormalize()（毫秒会被服务端 32 位截断 ⇒ 显示 1985）',
      );
    });

    test('★★ 静态守卫：note_api 的每个时间字段都过归一函数', () {
      final src = File('lib/src/data/note_api.dart').readAsStringSync();
      // 所有 js(...) 出口：ctime/mtime 必须包一层 Normalize
      for (final m in RegExp(r"'(c|m)time':\s*js\(([^)]*)\)").allMatches(src)) {
        final expr = m.group(2)!;
        expect(
          expr.contains('noteEpochSecondsNormalize') ||
              expr.contains('noteEpochSeconds('),
          isTrue,
          reason: "'${m.group(1)}time' 的写入表达式必须过秒归一：$expr",
        );
      }
    });
  });
}
