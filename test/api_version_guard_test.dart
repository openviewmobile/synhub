// ★ 第 260 轮：**"我们发的版本里到底有没有这个方法"** —— 离线静态守卫。
//
// 为什么要有它：仓库已经被同一类缺陷咬过**两次**（AGENTS §3）——
// `Core.Service:get` 在 v2 才有、`Core.MyDSCenter:query` 在 v2 才有，
// 我们按 v1 发 ⇒ 真机 `103 方法不存在`。既有守卫
// （`test/system_admin_beep_test.dart` BC12）只覆盖**当时那 11 个 admin 方法**，
// 而且是"`sent >= 最早含它的版本`"——这**不够**：新版第 260 轮的真 NAS 只读扫描
// （`tool/read_method_sweep.dart`）实测发现，有些方法只存在于**一段区间**里
// （`Chat.Post:get_read_status` 只在 v6..v8、`Chat.Channel:archive` 只在 v2..v5），
// 发一个"比最早版本更新"的版本同样会 `103`。
//
// 本用例**静态扫** `lib/src/data/**` 的每个调用点，把候选版本解析出来，
// 再对**真机实测的存在区间**（`tool/mock_dsm/observed_method_versions.json`）断言：
// **至少有一个候选版本是"那个版本上真有这个方法"的**。
// 这样不需要发网络请求、不需要写 fixture，却能把整个数据层的 103 风险一次盖住。
//
// 判据来源的顺序（**证据优先**）：
//   ① `observed_method_versions.json` —— 真 NAS 逐版本实测（最强）；
//   ② `tool/mock_dsm/catalog.json` —— 官方包的 API/版本方法表（覆盖更全；
//      注意它对本仓这台 NAS **偏宽松**，已有 10 处区间不一致的记录）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 从 `lib/src/data/<file>.dart` 里抽出的一个调用点。
class _Site {
  _Site(this.file, this.line, this.api, this.method, this.candidates);
  final String file;
  final int line;
  final String api;
  final String method;

  /// 客户端**可能**发出去的版本（按优先级）。空 = 解析不出来（跳过）。
  final List<int> candidates;

  String get where => '$file:$line';
}

/// 解析文件里 `const List<int> _x = [3, 2];` 这类符号表。
Map<String, List<int>> _symbols(String src) {
  final out = <String, List<int>>{};
  final re = RegExp(
    r'(?:static\s+)?const\s+(?:List<int>\s+)?(\w+)\s*=\s*(?:const\s+)?\[([0-9,\s]*)\]',
  );
  for (final m in re.allMatches(src)) {
    final nums = RegExp(r'\d+')
        .allMatches(m.group(2)!)
        .map((e) => int.parse(e.group(0)!))
        .toList();
    if (nums.isNotEmpty) out[m.group(1)!] = nums;
  }
  return out;
}

/// 从 `preferredVersion:` 后面的表达式里解析出候选版本。
List<int> _versionsOf(String expr, Map<String, List<int>> sym) {
  final out = <int>[];
  // `const [3, 2, 1]` / `[3, 2]`
  for (final m in RegExp(r'\[([0-9,\s]*)\]').allMatches(expr)) {
    out.addAll(
      RegExp(r'\d+').allMatches(m.group(1)!).map((e) => int.parse(e.group(0)!)),
    );
  }
  // `_v('SYNO.X', 2)` / `negotiate('SYNO.X', 2)` / 裸数字
  final fn = RegExp(r"\w+\(\s*'[^']*'\s*,\s*(\d+)").firstMatch(expr);
  if (fn != null) out.add(int.parse(fn.group(1)!));
  final bare = RegExp(r'^\s*(\d+)\s*(?:,|\]|$)').firstMatch(expr.trim());
  if (bare != null) out.add(int.parse(bare.group(1)!));
  // 符号：`_v3` / `_shareWithMeVersions`
  for (final m in RegExp(r'\b([A-Za-z_]\w*)\b').allMatches(expr)) {
    final v = sym[m.group(1)!];
    if (v != null) out.addAll(v);
  }
  return out.toSet().toList()..sort((a, b) => b.compareTo(a)); // 高版本优先
}

List<_Site> _scan() {
  final sites = <_Site>[];
  for (final f in Directory('lib/src/data').listSync()) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final src = f.readAsStringSync();
    final sym = _symbols(src);
    final name = f.path.split('/').last;
    final re = RegExp(
      r"(?:api\.)?call\(\s*'([A-Za-z0-9_.]+)'\s*,\s*\n?\s*'([A-Za-z0-9_]+)'",
    );
    for (final m in re.allMatches(src)) {
      final window = src.substring(
        m.start,
        m.start + 1200 > src.length ? src.length : m.start + 1200,
      );
      final pv = RegExp(r'preferredVersion:\s*').firstMatch(window);
      List<int> cands;
      if (pv == null) {
        // 不给 preferredVersion ⇒ `call()` 默认 v1
        cands = const [1];
      } else {
        var expr = window.substring(pv.end);
        // 截到 `params:` 或同层逗号/换行前的 `,`
        final cut = expr.indexOf('params:');
        if (cut >= 0) expr = expr.substring(0, cut);
        expr = expr.split('\n').take(6).join(' ');
        cands = _versionsOf(expr, sym);
      }
      sites.add(
        _Site(
          name,
          src.substring(0, m.start).split('\n').length,
          m.group(1)!,
          m.group(2)!,
          cands,
        ),
      );
    }
  }
  return sites;
}

void main() {
  final observed = jsonDecode(
    File('tool/mock_dsm/observed_method_versions.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final obsApis = observed['apis'] as Map<String, dynamic>;
  final catalog =
      jsonDecode(File('tool/mock_dsm/catalog.json').readAsStringSync())
          as Map<String, dynamic>;
  final catApis = (catalog['apis'] ?? catalog) as Map<String, dynamic>;

  /// 方法在某个版本上**确实存在**吗？证据优先：真机实测 → 官方目录。
  bool exists(String api, String method, int version) {
    final obs = (obsApis[api] as Map?)?[method] as Map?;
    if (obs != null) {
      // ★ 判不了（传输层失败）≠ 不存在 —— 别拿它报假缺陷
      if (obs['judged'] == false) return true;
      if (obs['exists'] == false) return false;
      return version >= (obs['min'] as int) && version <= (obs['max'] as int);
    }
    final e = catApis[api] as Map?;
    if (e == null) return true; // 目录里都没有 ⇒ 不是本用例能判的
    final methods = (e['methods'] ?? const {}) as Map;
    // ★ `methods` 为空 = 目录只知道"这个 API 存在"（live 查询不回方法表），
    //   **不知道**它有哪些方法 ⇒ 判不了，别报假缺陷。
    //   （实测：`SYNO.Personal.Profile.Photo` 的目录项就是 `methods: {}`，
    //   而官方 Chat APK 里确实有 `SYNO.Personal.Profile.Photo` 这个串。）
    if (methods.isEmpty) return true;
    final list = methods['$version'];
    if (list == null) return false;
    return (list as List).contains(method);
  }

  test('① 每个调用点的候选版本里，至少有一个是"该版本真有此方法"的', () {
    final sites = _scan();
    expect(sites.length, greaterThan(100), reason: '扫到的调用点太少，扫描器坏了');
    final bad = <String>[];
    var checked = 0;
    var judgedByNas = 0;
    var judgedByCatalog = 0;
    for (final s in sites) {
      if (s.candidates.isEmpty) continue;
      checked++;
      // 证据分档：真机实测 > 官方目录方法表 > 判不了
      final obs = (obsApis[s.api] as Map?)?[s.method] as Map?;
      final cat = (catApis[s.api] as Map?)?['methods'] as Map?;
      if (obs != null && obs['judged'] != false) {
        judgedByNas++;
      } else if (obs == null && cat != null && cat.isNotEmpty) {
        judgedByCatalog++;
      }
      if (s.candidates.any((v) => exists(s.api, s.method, v))) continue;
      bad.add(
        '★★★ ${s.api}:${s.method}  (${s.where})\n'
        '      只会发 v${s.candidates} —— 这些版本上**都没有**这个方法 ⇒ 真机 103',
      );
    }
    expect(checked, greaterThan(100), reason: '能解析出版本的调用点太少');
    // ★ 防空转：这条守卫必须**真的判过东西**，否则"全绿"毫无意义。
    //   同时把"有证据覆盖"与"判不了"分开报数 —— 判不了的不许算进覆盖率。
    expect(judgedByNas, greaterThanOrEqualTo(100),
        reason: '真机实测覆盖的调用点只有 $judgedByNas 个');
    //   第 260 轮实测覆盖：真机 130 + 目录 108 = **238**（其余是
    //   `methods: {}` 的 API 或解析不出候选版本的调用点）。
    //   这个下限是"不许倒退"的护栏，不是目标值 —— 想提高只能补证据。
    expect(judgedByNas + judgedByCatalog, greaterThanOrEqualTo(238),
        reason: '有证据判定的调用点太少：真机 $judgedByNas + 目录 $judgedByCatalog');
    // 用 `debugPrint` 而不是 `print`（`avoid_print` 会让 analyze 不是
    // "No issues found"）；这行是覆盖率的**自证**，故意留着。
    debugPrint('ℹ 调用点总共 $checked：真机实测判定 $judgedByNas、'
        '官方目录判定 $judgedByCatalog、判不了 ${checked - judgedByNas - judgedByCatalog}');
    expect(
      bad,
      isEmpty,
      reason: '以下调用点会把版本协商落到"不含该方法"的版本上'
          '（判据来自真 NAS 逐版本实测）：\n${bad.join('\n')}',
    );
  });

  test('② 真机实测表要覆盖到"区间比 API 声明窄"的方法（否则守卫形同虚设）', () {
    final narrow = <String>[];
    obsApis.forEach((api, methods) {
      (methods as Map).forEach((method, info) {
        final m = info as Map;
        if (m['judged'] == false || m['exists'] == false) return;
        final declared = '${m['declared'] ?? ''}';
        if (declared.isEmpty) return;
        final parts = declared.split('..');
        if (parts.length != 2) return;
        final min = int.tryParse(parts[0]);
        final max = int.tryParse(parts[1]);
        final omin = m['min'] as int?;
        final omax = m['max'] as int?;
        if (min == null || max == null || omin == null || omax == null) return;
        if (omin != min || omax != max) {
          narrow.add('$api:$method 声明 $declared，实测只有 v$omin..v$omax');
        }
      });
    });
    expect(
      narrow.length,
      greaterThanOrEqualTo(8),
      reason: '第 260 轮实测到 11 处"区间比声明窄"，这份表至少要留住这些证据：\n'
          '${narrow.join('\n')}',
    );
  });

  test('③ 反向验证：这条守卫真的能抓到"发错版本"（否则等于没守）', () {
    // 真机实测：`Chat.Channel:archive` 只在 v2..v5。
    expect(exists('SYNO.Chat.Channel', 'archive', 3), isTrue);
    expect(exists('SYNO.Chat.Channel', 'archive', 1), isFalse,
        reason: 'v1 上真机没有 archive ⇒ 发 v1 会 103');
    expect(exists('SYNO.Chat.Channel', 'archive', 6), isFalse,
        reason: 'v6 上真机也没有 archive ⇒ 只判"≥ 最早版本"是不够的');
    // 我方现状：显式发 v2，落在区间内
    final site = _scan().firstWhere(
      (s) => s.api == 'SYNO.Chat.Channel' && s.method == 'archive',
    );
    expect(site.candidates, contains(2));
  });
}
