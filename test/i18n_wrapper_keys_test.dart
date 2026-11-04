// ★ 第 121 轮：**包装器文案（具名常量 / 字面量 key）的登记守卫**。
//
// 用户报障（真机像素）：英文界面的 Settings 页里
//   `AI 美化（图生图）` / `已关闭（照片不会被发送）`
// 仍是中文。根因是模块文案写成
//
//   String photoAiEdit(String key, String zh) => dataText(key, zh);
//   abstract final class PhotoAiEditTextKeys {
//     static const settingsEntry = 'imageEditSettingsEntry';
//   }
//   photoAiEdit(PhotoAiEditTextKeys.settingsEntry, 'AI 美化（图生图）')
//
// key 是**具名常量**（或字面量），不是 `'imageEditSettingsEntry'` 直接传给
// `dataText`。既有两道守卫都漏：
//   * `i18n_coverage_test` 守卫②只认 `xxxText('literal', '…')`；
//   * `i18n_hardcoded_cjk_test` 把 `key + 中文回落` 当合法形态排除。
// ⇒ key 没进 ARB / 没进 `dataTextMap` 时，两道全绿，英文界面照样出中文。
//
// 本用例把 `lib/src/core/i18n/wrapper_key_scan.dart` 的纯函数扫描固化下来：
//   ① 真仓扫描：每个解析出的 key 必须同时存在于 zh ARB / en ARB / dataTextMap；
//   ② 防空转：调用点 > 1000、包装器 > 30、唯一 key > 1000（否则等于没扫到东西）；
//   ③ **反向验证**：给一段"有未登记 key"的合成源码，必须报告出**恰好那个 key**
//      （只断言 true == true 的负向测试毫无价值）。
//
// 与 `tool/i18n_wrapper_key_audit.dart` 共用同一套扫描逻辑，口径不会漂移。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/i18n/wrapper_key_scan.dart';

Map<String, String> _readLibSources() {
  final out = <String, String>{};
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    out[e.path] = e.readAsStringSync();
  }
  return out;
}

Set<String> _arbKeys(String lang) {
  final raw =
      jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
          as Map<String, dynamic>;
  return raw.keys.where((k) => !k.startsWith('@')).toSet();
}

void main() {
  final zhKeys = _arbKeys('zh');
  final enKeys = _arbKeys('en');
  final mapKeys = dataTextMap(AppTextZh()).keys.toSet();

  group('包装器文案登记守卫', () {
    test('① 真仓：解析出的每个 key 都在两套 ARB 与 dataTextMap 里', () {
      final audit = auditWrapperKeys(
        sources: _readLibSources(),
        zhKeys: zhKeys,
        enKeys: enKeys,
        mapKeys: mapKeys,
      );

      // 防空转：扫到 0 条不是"通过"，是"没扫到"（AGENTS §1.3.0.1）。
      expect(audit.wrapperNames.length, greaterThan(30),
          reason: '只发现 ${audit.wrapperNames.length} 个包装器，扫描器可能失效');
      expect(audit.callSites.length, greaterThan(1000),
          reason: '只发现 ${audit.callSites.length} 个调用点，扫描器可能失效');
      expect(audit.uniqueKeys, greaterThan(1000),
          reason: '只解析出 ${audit.uniqueKeys} 个 key，常量解析可能失效');

      expect(audit.unresolvedRefs, isEmpty,
          reason: '以下 `XTextKeys.name` 引用解析不到常量：\n  '
              '${audit.unresolvedRefs.join('\n  ')}');

      String fmt(Map<String, String> zh) => audit.missingZh.isEmpty
          ? ''
          : zh.entries.map((e) => '  ${e.key} = ${e.value}').join('\n');
      final detail = <String>[
        if (audit.missingZh.isNotEmpty)
          '缺 zh ARB（英文兜底会漏中文）：\n${fmt(audit.keyToZh)}',
        if (audit.missingEn.isNotEmpty)
          '缺 en ARB：\n  ${audit.missingEn.toList()..sort()}',
        if (audit.missingMap.isNotEmpty)
          '缺 dataTextMap（英文模式会回落中文）：\n  '
              '${audit.missingMap.toList()..sort()}',
      ].join('\n');
      expect(audit.missingZh, isEmpty, reason: detail);
      expect(audit.missingEn, isEmpty, reason: detail);
      expect(audit.missingMap, isEmpty, reason: detail);
    });

    test('② 反向验证：合成源码里的未登记 key 必须被**恰好**报告出来', () {
      // 故意给一个"代码在用、表里没有"的 key；表里另有一个已登记的作对照。
      const good = 'zzzSyntheticKnown';
      const bad = 'zzzSyntheticMissing';
      final synthetic = '''
String zzText(String key, String zh) => dataText(key, zh);
abstract final class ZzTextKeys {
  static const known = '$good';
  static const missing = '$bad';
}
final a = zzText(ZzTextKeys.known, '已登记文案');
final b = zzText(ZzTextKeys.missing, '未登记文案');
// zzText(ZzTextKeys.missing, '注释里的调用不算');
''';
      final audit = auditWrapperKeys(
        sources: {'synthetic.dart': synthetic},
        zhKeys: {good},
        enKeys: {good},
        mapKeys: {good},
      );

      // 注释里的那次调用不能算进来。
      expect(audit.callSites.length, 2,
          reason: '应只统计 2 个真实调用点（注释里的不算）');
      expect(audit.uniqueKeys, 2);
      expect(audit.missingZh, {bad});
      expect(audit.missingEn, {bad});
      expect(audit.missingMap, {bad});
      expect(audit.hasFindings, isTrue);
      // 对照：已登记的那个 key 不应出现在任何 missing 集合里。
      expect(audit.missingZh.contains(good), isFalse);
      expect(audit.keyToZh[bad], '未登记文案');
    });

    test('③ 反向验证：未定义的 `XTextKeys.name` 会被报为 unresolved', () {
      final synthetic = '''
String zzText(String key, String zh) => dataText(key, zh);
abstract final class ZzTextKeys {
  static const known = 'zzzSyntheticKnown';
}
final a = zzText(ZzTextKeys.notDefined, '引用不存在的常量');
''';
      final audit = auditWrapperKeys(
        sources: {'synthetic.dart': synthetic},
        zhKeys: {'zzzSyntheticKnown'},
        enKeys: {'zzzSyntheticKnown'},
        mapKeys: {'zzzSyntheticKnown'},
      );
      expect(audit.unresolvedRefs.length, 1);
      expect(audit.unresolvedRefs.single, contains('ZzTextKeys.notDefined'));
      expect(audit.hasFindings, isTrue);
    });

    test('⑤ 反向验证：**顶层 const 裸标识符**形态的 key 也要被抓到（r132）', () {
      // 盲区原文（r132 真仓）：笔记把 key 写成顶层常量，首参是裸标识符而不是
      // `XTextKeys.name` ⇒ 旧扫描器看不见这次调用，英文界面回落中文而守卫全绿。
      const good = 'zzzTopKnown';
      const bad = 'zzzTopMissing';
      final synthetic = """
String zzText(String key, String zh) => dataText(key, zh);
const String kZzKnown = '$good';
const String kZzMissing = '$bad';
final a = zzText(kZzKnown, '已登记文案');
final b = zzText(kZzMissing, '未登记文案');
""";
      final audit = auditWrapperKeys(
        sources: {'synthetic.dart': synthetic},
        zhKeys: {good},
        enKeys: {good},
        mapKeys: {good},
      );
      expect(audit.callSites.length, 2,
          reason: '顶层常量的两次调用都必须被解析成调用点');
      expect(audit.missingZh, {bad});
      expect(audit.missingEn, {bad});
      expect(audit.missingMap, {bad});
      expect(audit.keyToZh[bad], '未登记文案');
      expect(audit.missingMap.contains(good), isFalse);
    });

    test('④ 相邻字符串字面量拼接要拼成一条完整回落', () {
      final synthetic = '''
String zzText(String key, String zh) => dataText(key, zh);
abstract final class ZzTextKeys {
  static const k = 'zzzSyntheticConcat';
}
final a = zzText(
  ZzTextKeys.k,
  '前半句（甲）'
      '后半句（乙）',
);
''';
      final audit = auditWrapperKeys(
        sources: {'synthetic.dart': synthetic},
        zhKeys: {'zzzSyntheticConcat'},
        enKeys: {'zzzSyntheticConcat'},
        mapKeys: {'zzzSyntheticConcat'},
      );
      expect(audit.uniqueKeys, 1);
      expect(audit.keyToZh['zzzSyntheticConcat'], '前半句（甲）后半句（乙）');
      expect(audit.missingZh, isEmpty);
    });
  });
}
