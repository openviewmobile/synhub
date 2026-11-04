// ★★★ 第 317 轮：`dataTextMap` 的**模板形态**守卫（纯函数，便于真仓 + 反向验证复用）。
//
// 背景（真机可见缺陷 D14）：`lib/src/core/i18n/l10n.dart` 的 `dataTextMap` 是数据层
// 文案表的"模板产地" —— 带参数的条目要把占位符**以 `{name}` 形态**交给调用方，
// 由调用方（`dataText(...).replaceAll('{name}', …)` / `*Fill(...)`）替换。
//
// 真机取证（LGE-AN10，第 317 轮）：播放器的「在线字幕搜索」失败时，界面逐字显示
// `source: message` —— 因为表里写成了
//
//     'mediaSubtitleFailureLine': t.mediaSubtitleFailureLine('source', 'message'),
//
// 生成 getter 把两个**字面参数**填了进去（`source: message`），调用方的
// `replaceAll('{source}', …)` 便永远匹配不上。同型的还有 18 条（另一类是
// `_kTemplateInt` **没被 `_intTemplate` 包住** ⇒ 界面出现 `-987654321`）。
//
// 为什么既有两道 i18n 守卫都漏了这一类：
//   * `i18n_placeholder_audit_test` 明确把 `dataTextMap` 当"模板产地"**排除**在扫描外，
//     只查调用点有没有 `replaceAll`；
//   * `i18n_coverage_test` / `i18n_wrapper_keys_test` 只查 key 是否登记。
// ⇒ 没有任何守卫检查**这张表自身**产出的字符串还带不带占位符。
//
// 本文件只做一件事：把"表里的值必须含 ARB 声明的每一个 `{name}`"变成可断言的纯函数。
library;

/// ARB 里声明的占位符：`key → {name, …}`（只收含 `{name}` 形态的条目）。
Map<String, Set<String>> arbPlaceholders(Map<String, dynamic> arb) {
  final out = <String, Set<String>>{};
  for (final e in arb.entries) {
    if (e.key.startsWith('@')) continue;
    final v = e.value;
    if (v is! String) continue;
    final names = RegExp(r'\{([A-Za-z0-9_]+)\}')
        .allMatches(v)
        .map((m) => m.group(1)!)
        .toSet();
    if (names.isNotEmpty) out[e.key] = names;
  }
  return out;
}

/// [map] 里"缺占位符"的条目：对 [required] 中**已在表内**的 key，
/// 逐个要求其值里出现 `{name}`（带花括号）。
///
/// 返回 `key：缺少 {name}, …` 形式的人读清单；全部达标时为空。
List<String> dataTextMapMissingPlaceholders(
  Map<String, String> map,
  Map<String, Set<String>> required,
) {
  final bad = <String>[];
  final keys = required.keys.toList()..sort();
  for (final key in keys) {
    final value = map[key];
    if (value == null) continue; // 不在表里 ⇒ 不归本守卫管（另有 key 登记守卫）
    final missing = <String>[];
    for (final name in (required[key]!.toList()..sort())) {
      if (!value.contains('{$name}')) missing.add('{$name}');
    }
    if (missing.isNotEmpty) {
      // 诊断串（只出现在测试失败信息里，不是界面文案）：**用英文**，
      // 免得被 `i18n_hardcoded_cjk_test` 当成硬编码界面文案。
      bad.add('$key: missing ${missing.join(', ')} (value `$value`)');
    }
  }
  return bad;
}
