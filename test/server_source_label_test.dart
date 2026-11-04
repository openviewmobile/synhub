// 连接方式标签守卫（r343 D54）—— ★ **钉生产者**，不是钉渲染点。
//
// 背景：真机 `设置 → 关于` 逐字 `https://nas.example.com:5001（direct）` ——
// `ResolvedEndpoint.source` 是**运行时内部 token**，静态文本守卫（r340/r342）看不见它
// （同 D47：旁路的第四种形态 = 运行时值 ⇒ 判据改成"把该值的全部生产者扫出来"）。
//
// 本守卫做三件事：
//   ① 从**真实生产者文件**里扫出 token 清单（`source: 'x'` 与 `add(.., 'x')`）；
//   ② 非空判据：至少 6 个 token（扫不到 = 守卫失效，不是"全绿"）；
//   ③ 逐条断言 `connectSourceLabel(token, t)` **不等于原 token** —— 也就是
//      "内部 token 不可能出现在用户文案里"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/features/servers/server_source_label.dart';

/// `source` 的全部生产者（★ 新增一处生产者就要加进这里，否则守卫会漏）。
const List<String> _producerFiles = <String>[
  'lib/src/features/servers/connection_service.dart',
  'lib/src/quickconnect/address_selector.dart',
  'lib/src/quickconnect/serv_api.dart',
];

/// 扫出 token（两种写法：`source: 'x'`、`add(host, 'x')`）。
Set<String> scanSourceTokens() {
  final out = <String>{};
  final re = RegExp(r"source:\s*'([a-z0-9_]+)'" r"|add\([^,]+,\s*'([a-z0-9_]+)'\)");
  for (final f in _producerFiles) {
    final src = File(f).readAsStringSync();
    for (final m in re.allMatches(src)) {
      final tok = m.group(1) ?? m.group(2);
      if (tok != null && tok.isNotEmpty) out.add(tok);
    }
  }
  return out;
}

void main() {
  final zh = AppTextZh();
  final en = AppTextEn();

  test('非空判据：生产者文件里能扫到 ≥6 个 token', () {
    final toks = scanSourceTokens();
    expect(toks.length, greaterThanOrEqualTo(6), reason: '扫到的 token 太少，守卫等于没生效：$toks');
    // 三个已知 token 必须扫得到（写死三条，防止正则被改坏后静默"全绿"）
    expect(toks, containsAll(<String>['direct', 'lan', 'ddns']));
  });

  test('★ 任何生产者 token 都不许原样当用户文案（zh/en 双语）', () {
    final toks = scanSourceTokens();
    for (final tok in toks) {
      expect(connectSourceLabel(tok, zh), isNot(equals(tok)), reason: 'token=$tok');
      expect(connectSourceLabel(tok, en), isNot(equals(tok)), reason: 'token=$tok');
      expect(connectSourceLabel(tok, zh).trim(), isNotEmpty);
      // 用户文案里不许出现下划线/点（内部形状）
      expect(connectSourceLabel(tok, zh).contains('_'), isFalse);
    }
  });

  test('登记表与实现一致（kServerSourceTokens 每条都要有专文）', () {
    final labels = <String>{};
    for (final tok in kServerSourceTokens) {
      final v = connectSourceLabel(tok, zh);
      expect(v, isNot(equals(tok)), reason: '登记了 token=$tok 却没有专文');
      expect(v, isNot(equals(zh.setSrcOther)), reason: 'token=$tok 落到了兜底 ⇒ 专文没接上');
      labels.add(v);
    }
    // 每条 token 一句独立的话（不许两条 token 撞同一句）
    expect(labels.length, kServerSourceTokens.length);
    // 生产者扫出来的 token 必须都在登记表里（否则就是"新 token 没命名"）
    for (final tok in scanSourceTokens()) {
      expect(kServerSourceTokens, contains(tok), reason: '$tok 未登记：要么加专文，要么明确归入其它方式');
    }
  });

  test('正向 + 反向：认得出的给专文，认不出的给「其它方式」而不是原样', () {
    expect(connectSourceLabel('direct', zh), zh.setSrcDirect);
    expect(connectSourceLabel('  LAN  ', zh), zh.setSrcLan, reason: '要去空格 + 小写归一');
    expect(connectSourceLabel('ddns', en), en.setSrcDdns);
    // 反向：真实世界里会出现我方没见过的 token（服务端/未来版本）
    expect(connectSourceLabel('weird_new_token', zh), zh.setSrcOther);
    expect(connectSourceLabel('weird_new_token', en), en.setSrcOther);
    expect(connectSourceLabel('weird_new_token', zh).contains('_'), isFalse);
    // 空值 = 真不知道（与"其它方式"必须是两句话）
    expect(connectSourceLabel('', zh), zh.setSrcUnknown);
    expect(zh.setSrcOther, isNot(equals(zh.setSrcUnknown)));
  });
}
