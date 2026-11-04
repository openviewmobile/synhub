// 静态守卫：**上下文依赖句**（第 342 轮 D44）。
//
// ★ 为什么会有这条（r342 真机）：把「后台保活设置」页里那句
//   「**下面的**放行项建议全部打开——…」改成用户文案之后，**设置列表那一行的摘要**
//   立刻变成读不通的一句话（"下面的"在列表里指向不了任何东西）——
//   因为同一个 ARB key 被**两个渲染点**共用：
//     ① `features/settings/settings_page.dart` 的 `ListTile.subtitle`（列表摘要）
//     ② `core/device/oem_guidance.dart` 的页内 ⓘ 说明
//   ⇒ §2.0.26 同型：**一个字符串被当成两种语义用**。改成两句各自可读的文案。
//
// 判据：ARB 值以**指示代词开头**（中：下面的/以下/下方/上方的/如上/见下；
// 英：The items below / The options below / Below, / See below）时，
// 它**只许有一个渲染文件**（`lib/src/core/i18n/l10n.dart` 是生成的映射表，不算）。
//
// ★ 反向断言：本仓另有 4 条**合法**的"以下…"开头文案（各自只在一个文件里用），
//   必须**不**被误报；而真正出问题的那个 key 必须被抓到。
// ★ 已知边界：只认这几种开头；不以此开头的句子（如"下面"出现在句中）不受管；
//   也只统计"文件"粒度，同一文件里两处渲染判不出来（要靠评审）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 生成的映射表（每个 key 都在里面出现一次），不算渲染点。
const String _generatedTable = 'lib/src/core/i18n/l10n.dart';

final RegExp _deictic = RegExp(
  r'^(?:下面的|以下|下方|上方的|如上|见下'
  r'|The (?:items|options) below|Below,|See below)',
);

List<String> dartFiles() {
  final out = <String>[];
  for (final e in Directory('lib/src').listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart') && e.path != _generatedTable) {
      out.add(e.path);
    }
  }
  return out;
}

/// key → 渲染它的文件集合。
Map<String, Set<String>> renderSites() {
  final files = dartFiles();
  final src = {for (final f in files) f: File(f).readAsStringSync()};
  final byKey = <String, Set<String>>{};
  final re = RegExp(r"t\.([A-Za-z][A-Za-z0-9]*)\b|'([A-Za-z][A-Za-z0-9]*)'");
  src.forEach((f, s) {
    for (final m in re.allMatches(s)) {
      final key = m.group(1) ?? m.group(2)!;
      byKey.putIfAbsent(key, () => <String>{}).add(f);
    }
  });
  return byKey;
}

/// 返回 "key → 渲染文件数" 的违规清单。
List<String> deicticMultiSite(
  Map<String, String> zh,
  Map<String, String> en,
  Map<String, Set<String>> sites,
) {
  final bad = <String>[];
  zh.forEach((k, v) {
    final isDeictic = _deictic.hasMatch(v) || _deictic.hasMatch(en[k] ?? '');
    if (!isDeictic) return;
    final n = sites[k]?.length ?? 0;
    if (n > 1) {
      bad.add('$k（$n 个渲染文件：${(sites[k] ?? const <String>{}).join(', ')}）');
    }
  });
  return bad;
}

Map<String, String> readArb(String path) {
  final raw = File(path).readAsStringSync();
  final map = <String, String>{};
  for (final m in RegExp(r'^\s*"([^"]+)"\s*:\s*"((?:[^"\\]|\\.)*)"', multiLine: true)
      .allMatches(raw)) {
    map[m.group(1)!] = m.group(2)!;
  }
  return map;
}

void main() {
  final zh = readArb('lib/l10n/app_zh.arb');
  final en = readArb('lib/l10n/app_en.arb');
  final sites = renderSites();

  test('上下文依赖句（"下面的/以下…"开头）只许在一个渲染文件里', () {
    final bad = deicticMultiSite(zh, en, sites);
    expect(
      bad,
      isEmpty,
      reason: '这些 key 以指示代词开头（"下面的…"），却在多个渲染点共用：\n'
          '${bad.join('\n')}\n'
          '列表摘要与页内说明必须各写一句能独立读的文案，不许共用同一条串（D44）。',
    );
  });

  test('判据本身有效（反向：共用句必红、单点句不误报）', () {
    final fake = <String, Set<String>>{
      'sharedDeictic': {'a.dart', 'b.dart'},
      'singleDeictic': {'a.dart'},
      'plainShared': {'a.dart', 'b.dart'},
    };
    final z = <String, String>{
      'sharedDeictic': '下面的放行项建议全部打开',
      'singleDeictic': '以下为新消息',
      'plainShared': '同步成员状态',
    };
    expect(deicticMultiSite(z, const {}, fake), hasLength(1));
    expect(deicticMultiSite(z, const {}, fake).first, contains('sharedDeictic'));
    // 英文那侧也要认
    expect(
      deicticMultiSite(
        {'k': 'Turn everything on'},
        {'k': 'The items below are recommended'},
        {'k': {'a.dart', 'b.dart'}},
      ),
      hasLength(1),
    );
  });

  test('真仓里确实有"以下…"开头的合法文案（防空转：命中数 > 0）', () {
    final n = zh.values.where(_deictic.hasMatch).length;
    // "扫到 0 条"不是成功，是**没校验**（§1.3.0.1）。
    expect(n, greaterThanOrEqualTo(4));
  });

  test('D44 的两个渲染点各有自己的 key（不许再共用）', () {
    final page = File('lib/src/features/settings/settings_page.dart').readAsStringSync();
    expect(page.contains('t.oemKeepaliveRowSummary'), isTrue);
    expect(page.contains('t.oemKeepaliveNoFcm'), isFalse,
        reason: '设置行不许再复用页内说明那句');
    final guidance =
        File('lib/src/core/device/oem_guidance.dart').readAsStringSync();
    expect(guidance.contains("'oemKeepaliveNoFcm'"), isTrue);
  });
}
