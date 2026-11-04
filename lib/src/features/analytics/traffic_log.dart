// 网络流量的**写入端**：把计量样本聚合成小时桶后落库。
//
// 与 `UsageLog` 同一套纪律：
//   * **绝不阻塞 UI / 绝不抛回业务**：`addExact` 只是往内存 map 里加数字；
//   * **批量 + 合并**：同一个 `(小时, 模块, 方向, 档位, 接入方式)` 在内存里先
//     累加，满 [kTrafficFlushKeys] 个键或 [kTrafficFlushDelay] 后一次事务写盘；
//   * **有界**：保留 [kTrafficRetentionDays] 天的小时桶，总行数封顶
//     [kMaxTrafficBuckets]（超了删最老的桶）——一次请求**不会**写一行；
//   * **只存聚合量**：表里没有 URL / host / path 列，隐私由 schema 本身保证。
//
// 估算档（原生播放器绕过 Dart 的流量）由 [recordEstimated] 写入：
// 按时间重叠摊到跨越的小时桶（见 `traffic_analysis.dart` 的
// `distributeEstimateByHour`），并单独记 `samples`（会话段数）。
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/net/traffic_meter.dart';
import '../../data/local/analytics_database.dart';
import 'traffic_analysis.dart';

/// 小时桶保留天数（比原始事件的 180 天短：流量桶是聚合量，够了）
const int kTrafficRetentionDays = 90;

/// 小时桶总行数上限（超了删最老的）。见 `docs/network-traffic-analytics.md` §4。
const int kMaxTrafficBuckets = 100000;

/// 攒够多少个不同的桶键就落库
const int kTrafficFlushKeys = 24;

/// 最长攒多久
const Duration kTrafficFlushDelay = Duration(seconds: 5);

/// 系统 UID 基线在元数据表里的键
const String kMetaTrafficOsBaseline = 'traffic_os_baseline';

/// 本地小时桶的起点（**墙钟整点**）
DateTime trafficHourBucket(DateTime at) =>
    DateTime(at.year, at.month, at.day, at.hour);

/// 小时桶的唯一键（内存聚合用）
String trafficBucketKey(
  DateTime hour,
  String module,
  String direction,
  String tier,
  String transport,
) =>
    '${hour.millisecondsSinceEpoch}|$module|$direction|$tier|$transport';

class _Delta {
  _Delta(this.hour, this.module, this.direction, this.tier, this.transport);
  final DateTime hour;
  final String module;
  final String direction;
  final String tier;
  final String transport;
  int bytes = 0;
  int samples = 0;
}

/// 网络流量写入端（实现 [TrafficSink]，可直接挂给 `traffic_meter.dart`）
class TrafficLog implements TrafficSink {
  TrafficLog(AnalyticsDatabase db) : _db = db;

  /// ★★ 第 338 轮（D36）：同 [UsageLog.disabled] —— 没有任何可用后端时的
  /// "不记账"实例（`_db` 不赋值，库访问全部在各自的 `try/catch` 里被吞掉）。
  TrafficLog.disabled() {
    enabled = false;
  }

  late final AnalyticsDatabase _db;

  AnalyticsDatabase get db => _db;

  final Map<String, _Delta> _buffer = {};
  Timer? _timer;

  /// 开关（跟随「使用分析」总开关；关了就不计量）
  bool enabled = true;

  /// 最近一次写盘失败（诊断用；写失败本身不影响业务）
  Object? lastError;

  int get pendingKeys => _buffer.length;

  /// 精确档：一次请求（或一次流式响应）的字节
  @override
  void addExact(TrafficSample sample) {
    if (!enabled) return;
    final hour = trafficHourBucket(sample.at);
    _add(
      hour: hour,
      module: sample.module,
      direction: sample.direction,
      tier: sample.tier,
      transport: sample.transport,
      bytes: sample.bytes,
      samples: 1,
    );
  }

  /// 估算档：一段**已知活动会话**窗口内的差分（按时间摊到小时桶）
  @override
  void addEstimate(TrafficEstimate estimate) {
    if (!enabled) return;
    final parts = distributeEstimateByHour(
      from: estimate.from,
      to: estimate.to,
      bytes: estimate.bytes,
    );
    for (final p in parts) {
      _add(
        hour: p.hour,
        module: estimate.module,
        direction: estimate.direction,
        tier: TrafficTier.estimated,
        transport: estimate.transport,
        bytes: p.bytes,
        samples: 1,
      );
    }
    if (parts.isEmpty && estimate.bytes > 0) {
      // 窗口不足一小时也要落一个桶（记到结束时刻那一小时）
      _add(
        hour: trafficHourBucket(estimate.to),
        module: estimate.module,
        direction: estimate.direction,
        tier: TrafficTier.estimated,
        transport: estimate.transport,
        bytes: estimate.bytes,
        samples: 1,
      );
    }
  }

  void _add({
    required DateTime hour,
    required String module,
    required TrafficDirection direction,
    required TrafficTier tier,
    required String transport,
    required int bytes,
    required int samples,
  }) {
    if (bytes <= 0) return;
    final dir = direction.id;
    final tierId = tier.id;
    final key = trafficBucketKey(hour, module, dir, tierId, transport);
    final d = _buffer.putIfAbsent(
      key,
      () => _Delta(hour, module, dir, tierId, transport),
    );
    d.bytes += bytes;
    d.samples += samples;
    if (_buffer.length >= kTrafficFlushKeys) {
      unawaited(flush());
    } else {
      _timer ??= Timer(kTrafficFlushDelay, () => unawaited(flush()));
    }
  }

  /// 写盘任务链（串行，保证前一轮写完再写这一轮）
  Future<void> _pending = Future<void>.value();

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _pending = _pending.then((_) => _drain());
    return _pending;
  }

  Future<void> _drain() async {
    if (_buffer.isEmpty) return;
    final batch = Map<String, _Delta>.of(_buffer);
    _buffer.clear();
    try {
      await db.transaction(() async {
        for (final d in batch.values) {
          await _upsert(d);
        }
      });
      await prune();
    } catch (e) {
      // 写失败就当这批丢了（流量统计不该影响业务），但把原因留下来可查
      lastError = e;
    }
  }

  Future<void> _upsert(_Delta d) async {
    final existing =
        await (db.select(db.trafficBuckets)..where(
              (t) =>
                  t.hourMs.equals(d.hour.millisecondsSinceEpoch) &
                  t.module.equals(d.module) &
                  t.direction.equals(d.direction) &
                  t.tier.equals(d.tier) &
                  t.transport.equals(d.transport),
            ))
            .getSingleOrNull();
    if (existing == null) {
      await db
          .into(db.trafficBuckets)
          .insert(
            TrafficBucketsCompanion.insert(
              hourMs: d.hour.millisecondsSinceEpoch,
              module: d.module,
              direction: d.direction,
              tier: d.tier,
              transport: Value(d.transport),
              bytes: Value(d.bytes),
              samples: Value(d.samples),
            ),
          );
    } else {
      await (db.update(
        db.trafficBuckets,
      )..where((t) => t.id.equals(existing.id))).write(
        TrafficBucketsCompanion(
          bytes: Value(existing.bytes + d.bytes),
          samples: Value(existing.samples + d.samples),
        ),
      );
    }
  }

  /// 裁剪：按天数 + 行数上限
  Future<void> prune({DateTime? now, int? maxBuckets}) async {
    final cap = maxBuckets ?? kMaxTrafficBuckets;
    try {
      final cutoff = (now ?? DateTime.now())
          .subtract(const Duration(days: kTrafficRetentionDays))
          .millisecondsSinceEpoch;
      await (db.delete(
        db.trafficBuckets,
      )..where((t) => t.hourMs.isSmallerThanValue(cutoff))).go();
      final count = await bucketCount();
      if (count > cap) {
        final keepFrom =
            await (db.selectOnly(db.trafficBuckets)
                  ..addColumns([db.trafficBuckets.hourMs])
                  ..orderBy([OrderingTerm.desc(db.trafficBuckets.hourMs)])
                  ..limit(1, offset: cap - 1))
                .map((r) => r.read(db.trafficBuckets.hourMs))
                .getSingleOrNull();
        if (keepFrom != null) {
          await (db.delete(
            db.trafficBuckets,
          )..where((t) => t.hourMs.isSmallerThanValue(keepFrom))).go();
        }
      }
    } catch (_) {}
  }

  Future<int> bucketCount() async {
    var out = 0;
    try {
      final c = db.trafficBuckets.id.count();
      final row = await (db.selectOnly(
        db.trafficBuckets,
      )..addColumns([c])).getSingle();
      out = row.read(c) ?? 0;
    } catch (_) {
      out = 0;
    }
    return out;
  }

  /// 读一段时间窗内的小时桶（升序）
  Future<List<TrafficBucket>> range({
    Duration window = const Duration(days: 7),
    DateTime? now,
  }) async {
    try {
      final from = (now ?? DateTime.now())
          .subtract(window)
          .millisecondsSinceEpoch;
      final rows =
          await (db.select(db.trafficBuckets)
                ..where((t) => t.hourMs.isBiggerOrEqualValue(from))
                ..orderBy([(t) => OrderingTerm.asc(t.hourMs)]))
              .get();
      return [for (final r in rows) _toBucket(r)];
    } catch (_) {
      return const [];
    }
  }

  static TrafficBucket _toBucket(TrafficBucketRow r) => TrafficBucket(
    hour: DateTime.fromMillisecondsSinceEpoch(r.hourMs),
    module: r.module,
    direction:
        TrafficDirection.byId(r.direction) ?? TrafficDirection.down,
    tier: TrafficTier.byId(r.tier) ?? TrafficTier.exact,
    transport: r.transport,
    bytes: r.bytes,
    samples: r.samples,
  );

  /// 清空（设置页"清空"时与事件一起清）
  Future<void> clear() async {
    try {
      await db.delete(db.trafficBuckets).go();
      await _putMeta(kMetaTrafficOsBaseline, '');
    } catch (_) {}
  }

  /// 存系统 UID 基线（本轮"App 启动以来"的对比基准）
  Future<void> saveOsBaseline(Map<String, Object?> json) async {
    try {
      await _putMeta(kMetaTrafficOsBaseline, jsonEncode(json));
    } catch (_) {}
  }

  /// 读系统 UID 基线；没有/坏了 → null
  Future<Map<String, Object?>?> osBaseline() async {
    try {
      final rows = await (db.select(
        db.analyticsMetaRows,
      )..where((r) => r.key.equals(kMetaTrafficOsBaseline))).get();
      if (rows.isEmpty || rows.first.value.isEmpty) return null;
      final decoded = jsonDecode(rows.first.value);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _putMeta(String key, String value) async {
    try {
      await db
          .into(db.analyticsMetaRows)
          .insertOnConflictUpdate(
            AnalyticsMetaRowsCompanion.insert(key: key, value: Value(value)),
          );
    } catch (_) {}
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
