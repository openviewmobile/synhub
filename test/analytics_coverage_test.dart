// **埋点覆盖守卫**：注册表驱动，防止"新功能加了页面却忘了埋点"静默腐烂。
//
// 四条断言（每条都对应一种真实的腐烂方式）：
//   ① 模块级完整：`UsageModule` 的每个值都至少被一条 surface 覆盖；
//   ② 文件级存在：每条 surface 声明的文件存在，且**确实调用了 track***；
//   ③ 契约级具体：声明的 screen id / action 至少有一个真的出现在源码里；
//   ④ 目录级决策：`lib/src/features/<dir>/*_page.dart` 的每个目录，
//      要么登记了埋点，要么在 `kAnalyticsExcludedFeatures` 里写明"不埋"的理由。
//
// 反向验证：删掉任一 surface 文件里唯一/全部 `track*` 调用 → ② 立刻变红；
// 从注册表删掉某模块的全部 surface → ① 变红；新加一个 feature 目录不登记 → ④ 变红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/traffic_meter.dart';
import 'package:synhub/src/features/analytics/analytics_registry.dart';
import 'package:synhub/src/features/analytics/usage_event.dart';

final _trackCall = RegExp(r'\btrack[A-Za-z]*\s*\(');

/// 某些动作由专用助手隐含发出（`trackView` → `UsageAction.view`），
/// 源码里不会出现 `UsageAction.view`。这里把"助手名 → 隐含动作 id"列出来。
const Map<String, List<String>> _helperImplies = {
  'view': ['trackView('],
  'switch_view': ['trackViewMode('],
  'select': ['trackSelect('],
  'complete': ['trackComplete('],
  'start': ['trackStart('],
  'filter': ['trackFilter('],
  'sort': ['trackSort('],
};

void main() {
  test('① 模块级完整：每个 UsageModule 至少被一条 surface 覆盖', () {
    expect(kAnalyticsSurfaces, isNotEmpty);
    for (final m in UsageModule.values) {
      if (kNonSurfaceModules.contains(m)) continue;
      expect(
        kRegisteredModules,
        contains(m),
        reason: '模块 ${m.id} 没有任何登记的功能面 —— 请加 AnalyticsSurface 或写明理由',
      );
    }
  });

  test('② 文件级存在：每条 surface 的文件存在且确实有 track* 调用', () {
    for (final s in kAnalyticsSurfaces) {
      final f = File(s.file);
      expect(f.existsSync(), isTrue, reason: '${s.id}: 文件不存在 ${s.file}');
      final src = f.readAsStringSync();
      expect(
        _trackCall.hasMatch(src),
        isTrue,
        reason: '${s.id}: ${s.file} 里没有任何 track* 调用（登记了却漏埋）',
      );
      expect(
        src.contains('UsageModule.${s.module.id}'),
        isTrue,
        reason: '${s.id}: 文件里没有 UsageModule.${s.module.id}（注册表与实现脱节）',
      );
    }
  });

  test('③ 契约级具体：声明的 screen / action 出现在源码里', () {
    for (final s in kAnalyticsSurfaces) {
      final src = File(s.file).readAsStringSync();
      for (final screen in s.screens) {
        expect(
          src.contains("'$screen'"),
          isTrue,
          reason: '${s.id}: 缺少声明的 screen id 「$screen」',
        );
      }
      for (final a in s.actions) {
        final action = UsageAction.byId(a);
        expect(action, isNotNull, reason: '${s.id}: 未知动作 id $a');
        final markers = <String>[
          'UsageAction.${action!.name}',
          ...?_helperImplies[a],
        ];
        expect(
          markers.any(src.contains),
          isTrue,
          reason: '${s.id}: 声明的动作 $a 在源码里没有对应调用',
        );
      }
    }
  });

  test('④ 目录级决策：每个有页面的 feature 目录都登记或写明不埋点理由', () {
    final root = Directory('lib/src/features');
    expect(root.existsSync(), isTrue, reason: '必须在仓库根目录跑测试');
    for (final d in root.listSync().whereType<Directory>()) {
      final name = d.path.split(Platform.pathSeparator).last;
      if (name == 'analytics') continue; // 自身，由其文件承载
      final hasPage = d
          .listSync()
          .whereType<File>()
          .any((f) => f.path.endsWith('_page.dart'));
      if (!hasPage) continue;
      final covered = kAnalyticsSurfaces.any(
        (s) => s.file.startsWith('lib/src/features/$name/'),
      );
      final excluded = kAnalyticsExcludedFeatures.containsKey(name);
      expect(
        covered || excluded,
        isTrue,
        reason:
            'feature 目录 $name 有页面，却既没登记埋点、也没在 '
            'kAnalyticsExcludedFeatures 写明理由（新增功能必须做决定）',
      );
    }
  });

  // ── 网络流量（第 276 轮）──────────────────────────────────────────────
  //
  // ⑤ 每个走 `DsmWebApi` 的 data 文件都必须给自己的请求打上模块标签；
  // ⑥ `TrafficModules` 的常量集必须与 `UsageModule` 的 id **双向相等**；
  // ⑦ 所有显式标签都必须是合法模块（写错一个字就成"未归属"，静默腐烂）；
  // ⑧ 每一处自建 Dio 都必须挂上计量适配器。
  // 反向验证：把某文件的 `withModule(...)` 删掉 → ⑤ 红；
  // 从 `TrafficModules` 里删一个常量 → ⑥ 红；把 `attachTrafficMeter` 删掉 → ⑧ 红。

  test('⑤ 每个 DsmWebApi 调用点文件都声明了流量模块', () {
    final call = RegExp(r'api\.(call|getBytes|postBytesForm|postMultipart)\(');
    // 只委托给已带标签的 `foto.api`（自身不新建作用域），不是漏标
    const delegated = {
      'lib/src/data/foto_c2_api.dart',
    };
    final root = Directory('lib/src/data');
    final offenders = <String>[];
    for (final f in root.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('.g.dart')) continue;
      final rel = f.path.replaceAll('\\', '/');
      final src = f.readAsStringSync();
      if (!call.hasMatch(src)) continue;
      if (delegated.contains(rel)) continue;
      if (!src.contains('withModule(TrafficModules.')) offenders.add(rel);
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些文件发请求却没打模块标签（会静默落进 unattributed）：$offenders',
    );
  });

  test('⑥ TrafficModules 与 UsageModule 的 id 双向相等', () {
    final ids = UsageModule.values.map((m) => m.id).toSet();
    expect(
      TrafficModules.all.difference(ids),
      isEmpty,
      reason: 'TrafficModules 里有 UsageModule 不认识的 id',
    );
    expect(
      ids.difference(TrafficModules.all),
      isEmpty,
      reason: 'UsageModule 新增了模块，TrafficModules 没跟上',
    );
  });

  test('⑦ 所有显式流量标签都是合法模块', () {
    final direct = RegExp(r'withModule\(TrafficModules\.(\w+)\)');
    final tagged = RegExp(r'TrafficModules\.(\w+)');
    var checked = 0;
    for (final f in Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('.g.dart')) continue;
      final src = f.readAsStringSync();
      final names = <String>[
        for (final m in direct.allMatches(src)) m.group(1)!,
        // `tagDioWithModule(dio ?? Dio(\n  BaseOptions(…),\n  TrafficModules.x)`
        // 会跨很多行，所以按"出现位置往后 600 字符内取第一个标签"来扫
        for (final m in RegExp(r'tagDioWithModule\(').allMatches(src))
          // 跳过函数**定义**行（`Dio tagDioWithModule(...)`），只看调用
          if (!src.substring(0, m.start).endsWith('Dio '))
          ...tagged
              .allMatches(
                src.substring(m.end, (m.end + 600).clamp(0, src.length)),
              )
              .take(1)
              .map((x) => x.group(1)!),
      ];
      for (final name in names) {
        checked++;
        expect(
          TrafficModules.all.contains(name),
          isTrue,
          reason: '${f.path}: TrafficModules.$name 不存在（写错会静默变未归属）',
        );
      }
    }
    expect(checked, greaterThan(15), reason: '标签扫描没扫到东西，守卫失效了');
  });

  test('⑧ 每一处自建 Dio 都挂了计量适配器', () {
    final offenders = <String>[];
    for (final f in Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('.g.dart')) continue;
      final src = f.readAsStringSync();
      if (!RegExp(r'\bDio\(').hasMatch(src)) continue;
      if (src.contains('attachTrafficMeter(') ||
          src.contains('tagDioWithModule(')) {
        continue;
      }
      offenders.add(f.path);
    }
    expect(offenders, isEmpty, reason: '这些 Dio 没被计量：$offenders');
  });

  test('注册表自身：id 唯一、理由非空、模块 id 合法', () {
    final ids = kAnalyticsSurfaces.map((s) => s.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'surface id 必须唯一');
    for (final e in kAnalyticsExcludedFeatures.entries) {
      expect(e.value.trim(), isNotEmpty, reason: '${e.key} 的不埋点理由不能为空');
    }
    for (final s in kAnalyticsSurfaces) {
      expect(UsageModule.byId(s.module.id), isNotNull);
    }
  });
}
