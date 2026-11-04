// 静态守卫：**裸 `DateTime` 不许直接字符串化进界面**（第 341 轮，D41）。
//
// ★ 为什么会有这条（r341 真机）：`设置 → 服务检测` 的「上次检测」逐字画的是
//   `2026-10-10 06:37:32.449179` —— 源码是 `'${checkedAt.toLocal()}'`，
//   即 Dart 的 `DateTime.toString()`，**微秒也一起画给用户**。
//   §2.0.44 早就立了"时间不许裸 epoch、时间字段一律走 `formatFileTime`"，
//   但那条只挡住了 **epoch 整数**；`DateTime.toString()` 是**同一个语义的第二种表示**（§2.0.26），
//   所以又要一条守卫。
//
// 判据（只认这几种**字面形状**，别写成"看见 date 就报"）：
//   R1 `'${<expr>.toLocal()}'`（含 `${x.toLocal()}` 出现在任意字符串里）
//   R2 `'${<expr>.toIso8601String()}'`
//   R3 `'${<expr>.toUtc()}'`
// 命中即红，除非该文件在下面的诊断白名单里（值对象的 `toString()` 用于日志/诊断，不是界面文案）。
//
// ★ 两条断言缺一不可：正向（有命中必红）+ 反向（构造样本必须被认出来）。
// ★ 已知边界（不许当"扫全了"）：本守卫**只**扫上面三种形状；
//   把 `DateTime` 存进变量再拼进字符串（`'$when'`）它认不出来 ——
//   那条路只能靠"时间字段一律走 `formatFileTime`"的评审纪律（`note_reminder_host.dart`
//   就是这么做的：`when` 先过 `TodoReminderPlanner.formatDueDate`）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp _rawDateTimeRe = RegExp(
  r"""\$\{[^}]*\.(toLocal|toIso8601String|toUtc)\(\)\}""",
);

/// 允许把 `DateTime.toString()` 当**诊断值**用的文件（值对象 `toString()`、日志、探针）。
const Set<String> _diagnosticAllowlist = <String>{
  // `TrafficSample.toString()` —— 只在 logcat/诊断里用，不进任何 Text。
  'lib/src/core/net/traffic_meter.dart',
};

List<String> scanFile(String path, String content) {
  final hits = <String>[];
  final lines = content.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    // 注释里的讲解不算（§2.0.48：纯文本守卫会把注释数进去）。
    if (trimmed.startsWith('//')) continue;
    if (_rawDateTimeRe.hasMatch(line)) {
      hits.add('$path:${i + 1}: ${trimmed.trim()}');
    }
  }
  return hits;
}

void main() {
  test('lib/ 下不许把 DateTime 裸字符串化进界面（诊断白名单除外）', () {
    final hits = <String>[];
    for (final e in Directory('lib').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final rel = e.path;
      if (_diagnosticAllowlist.contains(rel)) continue;
      hits.addAll(scanFile(rel, e.readAsStringSync()));
    }
    expect(
      hits,
      isEmpty,
      reason: '这些地方把裸 DateTime 画给用户（微秒/ISO 格式会原样上屏），'
          '请改成 `formatFileTime(<epoch 秒>)` 或先格式化再拼：\n${hits.join('\n')}',
    );
  });

  test('判据本身有效（反向：故意构造的样本必须被抓到）', () {
    expect(scanFile('x.dart', "Text('上次检测：\${at.toLocal()}')"), hasLength(1));
    expect(scanFile('x.dart', "Text('\${at.toIso8601String()}')"), hasLength(1));
    expect(scanFile('x.dart', "Text('\${at.toUtc()}')"), hasLength(1));
    // 正向的反向：已格式化过的、以及注释里的，不许判红。
    expect(scanFile('x.dart', "Text('上次检测：\${formatFileTime(s)}')"), isEmpty);
    expect(scanFile('x.dart', '// 曾经写成 \${at.toLocal()} 很丑'), isEmpty);
    expect(scanFile('x.dart', "Text('\$when')"), isEmpty);
  });

  test('白名单不许是空的（防空转）', () {
    // 白名单是"已知例外"，但**必须**仍能在真仓里找到它到底豁免了什么。
    expect(_diagnosticAllowlist, isNotEmpty);
    for (final p in _diagnosticAllowlist) {
      expect(File(p).existsSync(), isTrue, reason: '$p 不在仓库里，白名单已陈旧');
      expect(scanFile(p, File(p).readAsStringSync()), isNotEmpty,
          reason: '$p 已不再命中，白名单应删掉（避免守卫悄悄失效）');
    }
  });
}
