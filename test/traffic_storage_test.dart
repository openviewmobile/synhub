// 流量存储：小时聚合、跨小时摊分、保留/封顶裁剪、开关、隐私 schema。
//
// 日期一律取**相对现在**的偏移：落库后有保留期裁剪（默认 90 天），
// 写死的历史日期会被立刻裁掉（这本身也是保留策略在起作用的证据）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/traffic_meter.dart';
import 'package:synhub/src/data/local/analytics_database.dart';
import 'package:synhub/src/features/analytics/traffic_log.dart';

AnalyticsDatabase _mem() => AnalyticsDatabase(NativeDatabase.memory());

TrafficSample _sample(
  DateTime at, {
  String module = TrafficModules.files,
  TrafficDirection direction = TrafficDirection.down,
  int bytes = 100,
  TrafficTier tier = TrafficTier.exact,
}) => TrafficSample(
  at: at,
  module: module,
  direction: direction,
  bytes: bytes,
  tier: tier,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AnalyticsDatabase db;
  late TrafficLog log;
  late DateTime now;

  setUp(() {
    now = DateTime.now();
    db = _mem();
    log = TrafficLog(db);
  });

  tearDown(() async {
    log.dispose();
    await db.close();
  });

  test('同一小时同一维度 → 一行，字节与样本累加', () async {
    final h = DateTime(now.year, now.month, now.day, now.hour);
    log.addExact(_sample(h.add(const Duration(minutes: 5)), bytes: 100));
    log.addExact(_sample(h.add(const Duration(minutes: 40)), bytes: 250));
    await log.flush();
    final rows = await log.range(window: const Duration(hours: 6), now: now);
    expect(rows.length, 1);
    expect(rows.single.bytes, 350);
    expect(rows.single.samples, 2);
    expect(rows.single.hour, h);
  });

  test('跨小时 → 两个桶（rollover）', () async {
    final h = DateTime(now.year, now.month, now.day, now.hour);
    log.addExact(_sample(h.subtract(const Duration(minutes: 1)), bytes: 100));
    log.addExact(_sample(h.add(const Duration(minutes: 1)), bytes: 200));
    await log.flush();
    final rows = await log.range(window: const Duration(hours: 6), now: now);
    expect(rows.length, 2);
    expect(rows[0].hour, h.subtract(const Duration(hours: 1)));
    expect(rows[1].hour, h);
    expect(rows.fold<int>(0, (a, r) => a + r.bytes), 300);
  });

  test('估算会话：按时间摊到跨越的小时桶，且总和不变', () async {
    final start = DateTime(now.year, now.month, now.day, now.hour).subtract(
      const Duration(minutes: 30),
    );
    log.addEstimate(
      TrafficEstimate(
        from: start,
        to: start.add(const Duration(hours: 2)),
        module: TrafficModules.media,
        direction: TrafficDirection.down,
        bytes: 1200,
      ),
    );
    await log.flush();
    final rows = await log.range(window: const Duration(hours: 6), now: now);
    expect(rows.length, 3, reason: '跨 3 个整点小时桶');
    expect(rows.every((r) => r.tier == TrafficTier.estimated), isTrue);
    expect(rows.fold<int>(0, (a, r) => a + r.bytes), 1200);
  });

  test('保留期裁剪：超过 90 天的小时桶被删', () async {
    log.addExact(
      _sample(now.subtract(const Duration(days: 100)), bytes: 10),
    );
    log.addExact(_sample(now.subtract(const Duration(hours: 1)), bytes: 20));
    await log.flush();
    final rows = await log.range(
      window: const Duration(days: 365),
      now: now,
    );
    expect(rows.length, 1);
    expect(rows.single.bytes, 20);
  });

  test('行数封顶：超出上限删最老的桶', () async {
    final h0 = DateTime(now.year, now.month, now.day, now.hour);
    for (var i = 0; i < 5; i++) {
      log.addExact(
        _sample(h0.subtract(Duration(hours: 4 - i)), bytes: 1 << i),
      );
    }
    await log.flush();
    expect(await log.bucketCount(), 5);
    await log.prune(now: now, maxBuckets: 2);
    final rows = await log.range(window: const Duration(days: 2), now: now);
    expect(rows.length, 2);
    expect(rows.map((r) => r.hour), [h0.subtract(const Duration(hours: 1)), h0]);
  });

  test('开关关闭时不写任何东西', () async {
    log.enabled = false;
    log.addExact(_sample(now));
    await log.flush();
    expect(await log.bucketCount(), 0);
  });

  test('clear 清空小时桶', () async {
    log.addExact(_sample(now));
    await log.flush();
    expect(await log.bucketCount(), 1);
    await log.clear();
    expect(await log.bucketCount(), 0);
  });

  test('系统 UID 基线可存可读', () async {
    expect(await log.osBaseline(), isNull);
    await log.saveOsBaseline({
      'at_ms': now.millisecondsSinceEpoch,
      'uid_rx': 1000,
      'uid_tx': 500,
      'mobile_rx': 10,
      'mobile_tx': 20,
      'total_rx': 9000,
      'total_tx': 8000,
    });
    final j = await log.osBaseline();
    expect(j, isNotNull);
    expect(j!['uid_rx'], 1000);
  });

  test('隐私 schema：流量表没有任何承载地址的列', () {
    final names = db.trafficBuckets.$columns.map((c) => c.name).toList();
    for (final bad in ['url', 'host', 'hostname', 'path', 'filename', 'name']) {
      expect(
        names.any((n) => n.toLowerCase().contains(bad)),
        isFalse,
        reason: '流量表不允许出现 $bad 类列：$names',
      );
    }
  });
}
