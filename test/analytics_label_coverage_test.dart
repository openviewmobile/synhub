// 静态守卫 + 纯函数用例：**埋点里的内部码不许当用户文案**（第 343 轮 D47）。
//
// ★ 为什么要有这条：D47 真机在 `设置 → 使用分析` 看到
//   `最常处理 settings（95%）`、`其次是 folder、drive。`、`其它原因：聊天·load_posts`。
//   根因是**两个**渲染点直接用内部键 / 让认不出的原因码原样返回 —— D39/D40/D43/D46 同族，
//   但这条的形状是**运行时值**（`top.key` / `reason`），既不在 ARB 里、也不是 Dart 字面量，
//   前面三条守卫（ARB / Dart 渲染点 / 原生 strings.xml）**都看不见它**。
//
// ★ 判据（钉在**生产者**上，§2.0.26「先清点该语义的全部生产者」）：
//   ① 扫 `lib/` 里所有 `objectType: '<字面量>'` —— 每个都必须**有专门文案**
//      （`UsageModule` 名 / 内部码表 / 扩展名大写），**不许**落到「其它」兜底；
//   ② 扫 `lib/` 里所有 `reason: '<字面量>'` —— 渲染出来的**用户文案里不许出现下划线**
//      （`load_posts` 这种方法名再也上不了屏）；
//   ③ 反向：新造的内部码必须落「其它」（说明判据不是"永远 true"）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/features/analytics/analytics_labels.dart';

final RegExp _objLit = RegExp(r"objectType:\s*'([^']*)'");
// ★★ r388/DA39：`objectType:` 后面**不是字面量**时的补扫 —— 只看 `objectType: 'x'`
//   会漏掉"经变量传进去"的内部码（真实漏网：`createObjectType` 的 `'magnet'`
//   从 r361 起就没有文案，会以「其它」出现在「使用分析 → 最常处理」卡上）。
//   规则：把 `objectType: <标识符>` 的标识符找回它在本文件里的赋值语句，
//   取语句里**内部码形状**（`^[a-z][a-z0-9_]{1,30}$`）的字面量。
//   ★ 为什么加形状过滤：赋值语句里还会有 `'magnet:'` 这种前缀串、以及别的说明串，
//   它们**不是** objectType 的值，直接收会把守卫变成假红。
final RegExp _objVarUse = RegExp(r"objectType:\s*([A-Za-z_]\w*)(?!\s*')");
final RegExp _codeShape = RegExp(r'^[a-z][a-z0-9_]{1,30}$');
final RegExp _strLit = RegExp(r"'([^'\n]*)'");

/// 把"经变量"的 objectType 码也收进来（同文件内解析，够用且不误伤）。
List<String> _codesViaVariable(String src, String ident) {
  final out = <String>[];
  for (final a in RegExp(r'\b' + RegExp.escape(ident) + r'\s*=(?!=)').allMatches(src)) {
    final rest = src.substring(a.end);
    final semi = rest.indexOf(';');
    final stmt = semi < 0 ? rest : rest.substring(0, semi);
    for (final l in _strLit.allMatches(stmt)) {
      final v = l.group(1)!;
      if (_codeShape.hasMatch(v)) out.add(v);
    }
  }
  return out;
}
final RegExp _reasonLit = RegExp(r"reason:\s*'([^']*)'");
final RegExp _extShape = RegExp(r'^[A-Za-z0-9]{1,5}$');

Iterable<String> _dartFiles(String dir) sync* {
  for (final e in Directory(dir).listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) yield e.path;
  }
}

void main() {
  final t = currentText();
  final objLits = <String, List<String>>{}; // 字面量 → 出现文件
  final reasonLits = <String, List<String>>{};
  for (final f in _dartFiles('lib/src')) {
    final src = File(f).readAsStringSync();
    for (final m in _objLit.allMatches(src)) {
      objLits.putIfAbsent(m.group(1)!, () => []).add(f);
    }
    for (final m in _objVarUse.allMatches(src)) {
      final seen = <String>{};
      for (final code in _codesViaVariable(src, m.group(1)!)) {
        final where = '$f（经变量 ${m.group(1)}）';
        if (!seen.add(code)) continue; // 同一文件同一变量只记一次
        final list = objLits.putIfAbsent(code, () => []);
        if (!list.contains(where)) list.add(where);
      }
    }
    for (final m in _reasonLit.allMatches(src)) {
      reasonLits.putIfAbsent(m.group(1)!, () => []).add(f);
    }
  }

  test('每个 objectType 字面量都有专门文案（不许落「其它」兜底）', () {
    // 防空转：扫到 0 条不是"干净"，是判据坏了（§1.3.0.1）
    expect(objLits.length, greaterThanOrEqualTo(30),
        reason: '扫到的 objectType 字面量太少 ⇒ 判据/扫描器坏了');
    final bad = <String>[];
    objLits.forEach((id, files) {
      final label = objectTypeLabel(id, t);
      if (_extShape.hasMatch(id)) {
        // 扩展名形状（`heic`/`pdf`）：允许"原样大写"，但**不许**等于原码
        if (label == id) bad.add('$id（未大写）← ${files.join(' / ')}');
      } else if (label == t.usageObjOther || label == id) {
        // ★ 出处**列全**（r388）：同一码可能既出现在字面量处、也经变量传进来，
        //   只印 `files.first` 会让人以为"只有那一处"，从而漏掉变量那条通道。
        bad.add('$id（无专文）← ${files.join(' / ')}');
      }
    });
    expect(bad, isEmpty,
        reason: '这些 objectType 会以内部码/「其它」出现在用户界面上：\n${bad.join('\n')}\n'
            '请在 analytics_labels.dart 的 _objectKindLabels 里给文案（或复用 UsageModule）。');
  });

  test('失败原因：渲染出的用户文案里不许出现下划线（方法名不许上屏）', () {
    expect(reasonLits.length, greaterThanOrEqualTo(20),
        reason: '扫到的 reason 字面量太少 ⇒ 判据/扫描器坏了');
    final bad = <String>[];
    reasonLits.forEach((code, files) {
      final text = usageFailureReasonLabel(code, t);
      if (text.contains('_') || text == code && !_extShape.hasMatch(code)) {
        bad.add('$code → "$text" ← ${files.first}');
      }
    });
    expect(bad, isEmpty,
        reason: '这些失败原因码会把内部码印给用户：\n${bad.join('\n')}');
  });

  test('变量补扫真的扫到了码（否则 DA39 的补扫是空转）', () {
    final viaVar = objLits.entries
        .where((e) => e.value.any((s) => s.contains('经变量')))
        .map((e) => e.key)
        .toList()
      ..sort();
    // 真实存在的四个：url / bt / file / magnet（download_create_page 的 createObjectType）
    expect(viaVar, containsAll(<String>['bt', 'file', 'magnet', 'url']));
  });

  test('反向：没写文案的内部码必须落「其它」（判据不是永远 true）', () {
    expect(objectTypeLabel('weird_internal_code', t), t.usageObjOther);
    expect(objectTypeLabel('', t), t.usageObjOther);
    expect(usageFailureReasonLabel('load_posts', t), t.usageFailOther);
    expect(usageFailureReasonLabel('load_posts', t).contains('_'), isFalse);
    // ★ 「不知道」与「有码但没专文」必须是**两句话**（§2.0.26）
    expect(t.usageFailOther, isNot(t.usageFailUnknown));
  });

  test('正面：模块名走同一口径；扩展名去点大写；内部码有译文', () {
    // 与「最常用」卡同一口径（同一个语义不许两份表示）
    expect(objectTypeLabel('settings', t), '设置');
    expect(objectTypeLabel('drive', t), 'Synology Drive');
    // 真扩展名
    expect(objectTypeLabel('.pdf', t), 'PDF');
    expect(objectTypeLabel('.jpg', t), 'JPG');
    // 内部对象码
    expect(objectTypeLabel('folder', t), '文件夹');
    expect(objectTypeLabel('task', t), '任务');
    expect(objectTypeLabel('snooze_schedule', t), '暂停计划');
    expect(objectTypeLabel('video_frame', t), '视频帧');
  });
}
