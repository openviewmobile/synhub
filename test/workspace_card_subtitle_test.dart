// DA192：Workspace 模块卡是**两列半宽卡**，副标题一行 —— 不许塞整句。
//
// 真机来路（r592，亮色，Workspace 第二页）：搜索卡副标题显示成
// **"Search permitted fold…"** —— 它用的是 `wsSearchFilesHint`
// （"Search permitted folders by file name"，36 字符），本来是**搜索框里的提示语**。
// 半宽卡（≈174dp、`labelSmall`）实测只有 ~19 字符的预算。
// AGENTS §2.0.18：固定预算里的截断只能改文案，不能缩字号。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _budget = 19; // 真机实测：21 字符（含省略号）刚好被截

List<String> _values(String arb, List<String> keys) {
  final src = File('lib/l10n/$arb').readAsStringSync();
  return [
    for (final k in keys)
      RegExp('"$k"\\s*:\\s*"([^"]*)"').firstMatch(src)?.group(1) ?? '★缺键 $k',
  ];
}

const _subtitleKeys = [
  'wsSearchFilesShort',
  'wsTasksNone',
  'wsTasksDone',
];

void main() {
  test('① 搜索卡用短副标题，不再用搜索框提示语', () {
    final src =
        File('lib/src/features/shell/app_shell_page.dart').readAsStringSync();
    expect(src.contains('?? t.wsSearchFilesShort'), isTrue,
        reason: 'DA192：搜索卡副标题没有改用 wsSearchFilesShort');
    expect(src.contains('?? t.wsSearchFilesHint,'), isFalse,
        reason: 'DA192：搜索卡又把整句提示语塞回来了');
  });

  test('② 这些副标题在 zh/en 下都 ≤ $_budget 字符', () {
    for (final arb in ['app_en.arb', 'app_zh.arb']) {
      final vals = _values(arb, _subtitleKeys);
      final tooLong = <String>[];
      for (var i = 0; i < vals.length; i++) {
        if (vals[i].length > _budget) {
          tooLong.add('${_subtitleKeys[i]} = "${vals[i]}"（${vals[i].length}）');
        }
      }
      expect(tooLong, isEmpty, reason: '$arb 这些副标题会溢出半宽卡：$tooLong');
    }
  });

  test('③ 反证：旧提示语（36 字符）必然超预算', () {
    final hint = _values('app_en.arb', ['wsSearchFilesHint']).single;
    expect(hint.length, greaterThan(_budget),
        reason: '反证失效：旧提示语居然不超预算，说明判据量错了对象');
  });
}
