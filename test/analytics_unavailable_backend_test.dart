// ★★ 第 338 轮（D36）回归：使用日志/流量库**没有后端**时，整条链必须"关闭但不崩"。
//
// 真机取证（`docs/evidence-r338/README.md`）：web 首屏探针里
//   `ProviderException: Tried to use a provider that is in error state.`（**两处**）
//   `Unsupported operation: 使用日志库在 web 上还没有存储后端…`
// ⇒ r334 把 web 连接写成"如实抛"之后，`usageLogProvider` 与 `trafficLogProvider`
// 都**必然停在错误态**，每个 watch 它们的 widget 在启动时都会抛一次。
//
// 本文件钉三件事：
//   ① "没有后端"的空实例 `UsageLog.disabled()` / `TrafficLog.disabled()`：
//      **构造与全链路都不抛**，且真的"关闭"（不缓冲、enabled=false）；
//   ② 反向：这些实例上的库访问**确实会抛**（`LateInitializationError`）——
//      证明"不崩"不是"其实什么都没做"；
//   ③ 两个 provider 在"磁盘库开不起来"（override 成 null）时**照常构建**。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/analytics/analytics_providers.dart';
import 'package:synhub/src/features/analytics/traffic_log.dart';
import 'package:synhub/src/features/analytics/usage_event.dart';
import 'package:synhub/src/features/analytics/usage_log.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test('① UsageLog.disabled()：全链路不抛、且真的"关闭"', () async {
    final log = UsageLog.disabled();
    addTearDown(log.dispose);

    expect(log.enabled, isFalse, reason: '没有后端 = 日志关闭（不是"悄悄开着"）');
    // ★ 反向断言：库访问**确实**会抛（同步抛 --- 这正是它能被 try/catch 吞掉的原因）
    expect(() => log.db, throwsA(anything));

    await log.load();
    log.setAccount('tester');
    log.record(
      UsageModule.files,
      UsageAction.open,
      objectType: 'file',
      detail: const {'k': 'v'},
    );
    await log.flush();
    await log.prune();
    await log.eventCount();
    await log.recent(limit: 5);
    await log.exportJson();
    await log.savedInsights();
    await log.setEnabled(false);

    expect(log.hasPending, isFalse, reason: '关闭态不该往缓冲里放东西');
  });

  test('② TrafficLog.disabled()：记账接口不抛（不记账）', () async {
    final log = TrafficLog.disabled();
    addTearDown(log.dispose);
    expect(log.enabled, isFalse);
    expect(() => log.db, throwsA(anything));

    await log.flush();
    await log.prune();
    await log.bucketCount();
    await log.range();
    await log.saveOsBaseline(const {'os': 0});
    await log.clear();
  });

  test('③ 两个 provider：磁盘库开不起来（null）时不许停错误态', () {
    final container = ProviderContainer(
      overrides: [analyticsDatabaseProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    expect(() => container.read(usageLogProvider), returnsNormally);
    expect(() => container.read(trafficLogProvider), returnsNormally);
    // 同一个 provider 读两次必须是**同一个实例**（Riverpod 缓存，不能每次新建）
    expect(
      identical(container.read(usageLogProvider), container.read(usageLogProvider)),
      isTrue,
    );

    // ★ 反向：override 真的生效了（读到的是 null，而不是"悄悄又去开真库"）
    //   —— 注意**不要**在这里真的去开真库：`test()` 里没有 binding，
    //   `path_provider` 会抛 "Binding has not yet been initialized."（本轮踩过）。
    expect(container.read(analyticsDatabaseProvider), isNull);
    //   （"没有 override 时走真库"那条反向断言**不在这里做**：`test()` 里没有
    //    binding，`path_provider` 会抛 —— 真实库那条路由别的用例覆盖。）
  });
}
