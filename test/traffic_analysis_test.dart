// 流量**聚合分析**（排行 / 时段 / 精确-估算拆分 / 未归属 / 与系统对比）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/traffic_meter.dart';
import 'package:synhub/src/features/analytics/traffic_analysis.dart';

TrafficBucket _b(
  int hour,
  String module,
  TrafficDirection dir,
  int bytes, {
  TrafficTier tier = TrafficTier.exact,
  int day = 1,
}) => TrafficBucket(
  hour: DateTime(2026, 3, day, hour),
  module: module,
  direction: dir,
  tier: tier,
  bytes: bytes,
);

void main() {
  test('排行：按总量排序，含未归属；下载/上传方向各自排序', () {
    final stats = computeTrafficStats([
      _b(9, TrafficModules.files, TrafficDirection.down, 1000),
      _b(9, TrafficModules.files, TrafficDirection.up, 100),
      _b(10, TrafficModules.chat, TrafficDirection.down, 500),
      _b(11, TrafficModules.unattributed, TrafficDirection.down, 200),
    ]);
    final all = stats.ranking();
    expect(all.map((e) => e.module).toList(), [
      TrafficModules.files,
      TrafficModules.chat,
      TrafficModules.unattributed,
    ]);
    expect(all.first.totalBytes, 1100);
    expect(all.first.downBytes, 1000);
    expect(all.first.upBytes, 100);

    final byUp = stats.ranking(direction: TrafficDirection.up);
    expect(byUp.map((e) => e.module), [TrafficModules.files]);

    final share = all.first.sharePercent(stats.attributedTotalBytes);
    expect(share, closeTo(1100 / 1800 * 100, 0.001));
  });

  test('拆分：精确 / 估算 / 未归属三者互不混', () {
    final stats = computeTrafficStats([
      _b(9, TrafficModules.files, TrafficDirection.down, 100),
      _b(9, TrafficModules.media, TrafficDirection.down, 300,
          tier: TrafficTier.estimated),
      _b(9, TrafficModules.unattributed, TrafficDirection.down, 50),
      _b(9, TrafficModules.unattributed, TrafficDirection.up, 10,
          tier: TrafficTier.estimated),
    ]);
    expect(stats.exactBytes, 150);
    expect(stats.estimatedBytes, 310);
    expect(stats.unattributedBytes, 60);
    expect(stats.attributedTotalBytes, 460);
    expect(stats.unattributedPercent, closeTo(60 / 460 * 100, 0.001));
    expect(stats.exactPercent, closeTo(150 / 460 * 100, 0.001));
  });

  test('与系统对比：差值只作为未计入，不摊给任何模块', () {
    final stats = computeTrafficStats(
      [_b(9, TrafficModules.files, TrafficDirection.down, 1000)],
      osBaselineAt: DateTime(2026, 3, 1, 8),
      osRxBytes: 1500,
      osTxBytes: 500,
    );
    expect(stats.attributedTotalBytes, 1000);
    expect(stats.osTotalBytes, 2000);
    expect(stats.unaccountedBytes, 1000);
    // 没有基线 → 不猜，未计入为 0
    final noBase = computeTrafficStats([
      _b(9, TrafficModules.files, TrafficDirection.down, 1000),
    ], osRxBytes: 9999);
    expect(noBase.unaccountedBytes, 0);
  });

  test('时段分布：24 个小时柱，索引 = 本地小时', () {
    final stats = computeTrafficStats([
      _b(0, TrafficModules.files, TrafficDirection.down, 10),
      _b(23, TrafficModules.files, TrafficDirection.down, 20),
      _b(23, TrafficModules.files, TrafficDirection.up, 5),
    ]);
    expect(stats.hours.length, 24);
    expect(stats.hours[0].totalBytes, 10);
    expect(stats.hours[23].totalBytes, 25);
    expect(stats.hours[23].downBytes, 20);
    expect(stats.hours[23].upBytes, 5);
  });

  test('空数据：isEmpty，且总量为 0（不编数）', () {
    final stats = computeTrafficStats(const []);
    expect(stats.isEmpty, isTrue);
    expect(stats.attributedTotalBytes, 0);
    expect(stats.unattributedPercent, 0);
    expect(stats.ranking(), isEmpty);
  });

  test('估算摊分：跨午夜（墙钟换日）也守恒，小时是墙钟整点', () {
    final parts = distributeEstimateByHour(
      from: DateTime(2026, 3, 1, 23, 30),
      to: DateTime(2026, 3, 2, 1, 30),
      bytes: 900,
    );
    expect(parts.fold<int>(0, (a, p) => a + p.bytes), 900);
    expect(parts.map((p) => p.hour.hour).toList(), [23, 0, 1]);
    expect(parts.first.hour.day, 1);
    expect(parts.last.hour.day, 2);
  });

  test('估算摊分：不足 1 字节的舍入尾巴给最后一个桶（不丢字节）', () {
    final parts = distributeEstimateByHour(
      from: DateTime(2026, 3, 1, 10),
      to: DateTime(2026, 3, 1, 13),
      bytes: 1000,
    );
    expect(parts.fold<int>(0, (a, p) => a + p.bytes), 1000);
  });

  test('字节格式化：单位是 ASCII，不含中文', () {
    expect(formatTrafficBytes(0), '0 B');
    expect(formatTrafficBytes(512), '512 B');
    expect(formatTrafficBytes(1024), '1.00 KB');
    expect(formatTrafficBytes(1536), '1.50 KB');
    expect(formatTrafficBytes(12 * 1024 * 1024), '12.0 MB');
    expect(formatTrafficBytes(123 * 1024 * 1024), '123 MB');
    expect(formatTrafficBytes(2 * 1024 * 1024 * 1024), '2.00 GB');
    expect(formatTrafficBytes(1234567890).contains('GB'), isTrue);
    expect(formatTrafficBytes(-5), '0 B');
  });
}
