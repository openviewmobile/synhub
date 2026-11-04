// ★ r677（`DA310`）：**模板 ARB（`app_zh.arb`）里的 `err*` family 有 14 条是英文**。
//
// 背景：本仓 `l10n.yaml` 的 `template-arb-file` = `app_zh.arb`（中文当模板），
// 设计意图写得明白：「漏翻一条时用户看到的还是中文，不会突然冒出英文」。
// 但通用错误 family（`errGenericFailed` / `errConnectTimeout` /
// `errCannotReachServer` / … 共 14 条）的模板值是**整句英文** ⇒
// 中文界面的错误提示是英文（`iOS` 模拟器 `zh-Hant-TW` 那一档的现场）。
//
// 本用例是**字典守卫**：模板里 `err*` 的每个值都必须含汉字
// （允许极少数"只有占位符/纯代号"的例外，必须显式登记在 [_allowNoCjk]）。
//
// 为什么钉"字典"而不是钉某个界面：这类漏翻在 100+ 个调用点里都可能显示，
// 逐屏断言永远追不上；字典是唯一收口。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// 允许"没有汉字"的例外（**加一条就要写清理由**）。
const _allowNoCjk = <String>{
  // 只有"代号 + 占位符"，没有自然语言可翻（值 = `DSM {code}：{detail}`）。
  'errDsmCodeWithDetail',
};

final _cjk = RegExp(r'[\u4e00-\u9fff]');

void main() {
  test('DA310：模板 ARB 的 err* 每条都必须有中文（不许整句英文）', () {
    final zh = _arb('lib/l10n/app_zh.arb');
    final missing = <String>[];
    zh.forEach((key, value) {
      if (!key.startsWith('err') || key.startsWith('@')) return;
      if (value is! String || value.isEmpty) return;
      if (_allowNoCjk.contains(key)) return;
      if (!_cjk.hasMatch(value)) missing.add(key);
    });
    expect(
      missing,
      isEmpty,
      reason: '这些 err* 在中文模板里仍是英文 ⇒ 中文界面会显示英文：'
          '${missing.join(", ")}',
    );
  });

  test('DA310：英文 ARB 必须覆盖模板里的每一个 err* key（且值非空）', () {
    final zh = _arb('lib/l10n/app_zh.arb');
    final en = _arb('lib/l10n/app_en.arb');
    final errKeys = zh.keys
        .where((k) => k.startsWith('err') && !k.startsWith('@'))
        .toList();
    expect(errKeys, isNotEmpty);
    for (final k in errKeys) {
      expect(en.containsKey(k), isTrue, reason: '英文 ARB 缺 key: $k');
      expect('${en[k]}'.trim(), isNotEmpty, reason: '英文 ARB 的 $k 为空');
    }
  });

  test('DA309：errConnectFailed 在中英文里都登记了，且是两句话', () {
    final zh = _arb('lib/l10n/app_zh.arb');
    final en = _arb('lib/l10n/app_en.arb');
    expect(zh['errConnectFailed'], isNotNull);
    expect(en['errConnectFailed'], isNotNull);
    expect(_cjk.hasMatch(zh['errConnectFailed'] as String), isTrue,
        reason: '中文模板里 errConnectFailed 必须是中文');
    expect(_cjk.hasMatch(en['errConnectFailed'] as String), isFalse,
        reason: '英文 ARB 里 errConnectFailed 不许有汉字');
    // LINK LOG 一行放得下的既有判据（≤60 字符）
    expect((en['errConnectFailed'] as String).length, lessThanOrEqualTo(60));
  });
}
