// 网络流量的**聚合分析**（纯函数，无 IO / 无 Flutter）。
//
// 输入是 `AnalyticsDatabase` 里的小时桶（`traffic_buckets`），输出是
// 「按模块排行 / 24 小时分布 / 精确-估算拆分 / 未归属占比 / 与系统 UID 对比」
// 这些可直接渲染、也可复核的统计量。
//
// 两条硬规矩（见 `docs/network-traffic-analytics.md`）：
//   1. **精确与估算绝不混**：任何"总量"都同时给出 `exact` / `estimated` 两个数，
//      以及 `unattributed`（未打模块标签的那一份）；
//   2. **总量不是"我钩到的部分"**：`wholeAppBytes` = 各模块之和（含未归属），
//      与系统 UID 的差值单独作为 `unaccountedBytes` 展示，不塞进任何模块。
import 'dart:math' as math;

import '../../core/net/traffic_meter.dart';

/// 一个已落库的小时桶（内存值对象；不依赖 drift）
class TrafficBucket {
  const TrafficBucket({
    required this.hour,
    required this.module,
    required this.direction,
    required this.tier,
    this.transport = '',
    required this.bytes,
    this.samples = 0,
  });

  final DateTime hour;
  final String module;
  final TrafficDirection direction;
  final TrafficTier tier;
  final String transport;
  final int bytes;
  final int samples;
}

/// 排行里的一行：某模块的下载 / 上传 / 合计字节
class TrafficRankEntry {
  const TrafficRankEntry({
    required this.module,
    required this.downBytes,
    required this.upBytes,
    this.exactBytes = 0,
    this.estimatedBytes = 0,
  });

  final String module;
  final int downBytes;
  final int upBytes;
  final int exactBytes;
  final int estimatedBytes;

  int get totalBytes => downBytes + upBytes;

  /// 占全 App 的百分比（0–100，保留一位小数）
  double sharePercent(int wholeAppBytes) =>
      wholeAppBytes <= 0 ? 0 : totalBytes * 100 / wholeAppBytes;

  /// 某一方向的字节（排行可切换按下载/上传排序）
  int bytesOf(TrafficDirection direction) =>
      direction == TrafficDirection.down ? downBytes : upBytes;
}

/// 一小时柱（时段的 y 值）
class TrafficHourSlice {
  const TrafficHourSlice({
    required this.hour,
    required this.downBytes,
    required this.upBytes,
  });

  /// 本地墙钟小时（0–23）
  final int hour;
  final int downBytes;
  final int upBytes;

  int get totalBytes => downBytes + upBytes;
}

/// 客流统计（一次分析的全部结果）
class TrafficStats {
  TrafficStats({
    required this.from,
    required this.to,
    required this.buckets,
    required this.byModule,
    required this.hours,
    required this.exactBytes,
    required this.estimatedBytes,
    required this.unattributedBytes,
    this.osBaselineAt,
    this.osRxBytes = 0,
    this.osTxBytes = 0,
    this.osMobileRxBytes = 0,
    this.osMobileTxBytes = 0,
  });

  final DateTime from;
  final DateTime to;
  final List<TrafficBucket> buckets;

  /// 模块 id → 排行行
  final Map<String, TrafficRankEntry> byModule;

  /// 24 个小时柱（索引 = 本地小时）
  final List<TrafficHourSlice> hours;

  /// 精确档合计（Dart HTTP 客户端实测）
  final int exactBytes;

  /// 估算档合计（原生组件，UID 会话窗口差分）
  final int estimatedBytes;

  /// 未归属合计（含精确 + 估算；`unattributed` 模块的字节）
  final int unattributedBytes;

  /// 系统 UID 基线时刻（null = 没采到；此时不做对比）
  final DateTime? osBaselineAt;

  /// 系统 UID 计数（基线 → 现在 的差分；无法读取时为 0）
  final int osRxBytes;
  final int osTxBytes;
  final int osMobileRxBytes;
  final int osMobileTxBytes;

  /// 全 App 归属总量 = 各模块（含未归属）之和
  int get attributedTotalBytes => exactBytes + estimatedBytes;

  /// 与系统 UID 的差值（未计入的部分）。系统没采到 → 0（不猜）。
  int get osTotalBytes => osRxBytes + osTxBytes;

  int get unaccountedBytes {
    if (osBaselineAt == null) return 0;
    final diff = osTotalBytes - attributedTotalBytes;
    return diff > 0 ? diff : 0;
  }

  /// 未归属占比（0–100）
  double get unattributedPercent => attributedTotalBytes <= 0
      ? 0
      : unattributedBytes * 100 / attributedTotalBytes;

  /// 精确占比（0–100）
  double get exactPercent => attributedTotalBytes <= 0
      ? 0
      : exactBytes * 100 / attributedTotalBytes;

  /// 排行榜（[direction] 指定按哪个方向排序；`null` = 合计）
  List<TrafficRankEntry> ranking({TrafficDirection? direction}) {
    final list = byModule.values.toList()
      ..sort(
        (a, b) => direction == null
            ? b.totalBytes.compareTo(a.totalBytes)
            : b.bytesOf(direction).compareTo(a.bytesOf(direction)),
      );
    return [
      for (final e in list)
        if (direction == null
            ? e.totalBytes > 0
            : e.bytesOf(direction) > 0)
          e,
    ];
  }

  bool get isEmpty => attributedTotalBytes <= 0;
}

/// 把小时桶聚合成 [TrafficStats]。
TrafficStats computeTrafficStats(
  List<TrafficBucket> buckets, {
  DateTime? now,
  DateTime? osBaselineAt,
  int osRxBytes = 0,
  int osTxBytes = 0,
  int osMobileRxBytes = 0,
  int osMobileTxBytes = 0,
}) {
  final sorted = [...buckets]
    ..sort((a, b) => a.hour.compareTo(b.hour));

  final byModule = <String, _ModuleAcc>{};
  final hours = List.generate(
    24,
    (h) => _HourAcc(h),
    growable: false,
  );

  var exact = 0;
  var estimated = 0;
  var unattributed = 0;

  for (final b in sorted) {
    final acc = byModule.putIfAbsent(b.module, _ModuleAcc.new);
    if (b.direction == TrafficDirection.down) {
      acc.down += b.bytes;
    } else {
      acc.up += b.bytes;
    }
    if (b.tier == TrafficTier.exact) {
      acc.exact += b.bytes;
      exact += b.bytes;
    } else {
      acc.estimated += b.bytes;
      estimated += b.bytes;
    }
    if (b.module == TrafficModules.unattributed) unattributed += b.bytes;
    // 小时分布只在**本地整点**上取 hour（`TrafficBucket.hour` 本身是整点）
    final h = b.hour.hour % 24;
    if (b.direction == TrafficDirection.down) {
      hours[h].down += b.bytes;
    } else {
      hours[h].up += b.bytes;
    }
  }

  final from = sorted.isEmpty ? (now ?? DateTime.now()) : sorted.first.hour;
  final to = sorted.isEmpty ? (now ?? DateTime.now()) : sorted.last.hour;

  return TrafficStats(
    from: from,
    to: to,
    buckets: sorted,
    byModule: {
      for (final e in byModule.entries)
        e.key: TrafficRankEntry(
          module: e.key,
          downBytes: e.value.down,
          upBytes: e.value.up,
          exactBytes: e.value.exact,
          estimatedBytes: e.value.estimated,
        ),
    },
    hours: [
      for (final h in hours)
        TrafficHourSlice(
          hour: h.hour,
          downBytes: h.down,
          upBytes: h.up,
        ),
    ],
    exactBytes: exact,
    estimatedBytes: estimated,
    unattributedBytes: unattributed,
    osBaselineAt: osBaselineAt,
    osRxBytes: osRxBytes,
    osTxBytes: osTxBytes,
    osMobileRxBytes: osMobileRxBytes,
    osMobileTxBytes: osMobileTxBytes,
  );
}

class _ModuleAcc {
  int down = 0;
  int up = 0;
  int exact = 0;
  int estimated = 0;
}

class _HourAcc {
  _HourAcc(this.hour);
  final int hour;
  int down = 0;
  int up = 0;
}

/// 把一段**估算**字节按时间重叠比例摊到它跨越的小时桶里。
///
/// 为什么不用"全记到会话结束那一小时"：一部 21:00 开始、23:00 结束的电影
/// 会把两小时流量都记到 23 点，时段分析就假了。按重叠时长线性摊分是
/// 这里能做的最诚实的近似（并集不为零；不足 1 字节的尾巴舍去）。
List<({DateTime hour, int bytes})> distributeEstimateByHour({
  required DateTime from,
  required DateTime to,
  required int bytes,
}) {
  if (bytes <= 0 || !to.isAfter(from)) return const [];
  final totalMs = to.difference(from).inMilliseconds;
  if (totalMs <= 0) return const [];
  final out = <({DateTime hour, int bytes})>[];
  var cursor = _floorHour(from);
  var remaining = bytes;
  var cursorMs = from.millisecondsSinceEpoch;
  final endMs = to.millisecondsSinceEpoch;
  while (cursorMs < endMs) {
    final nextHour = DateTime(
      cursor.year,
      cursor.month,
      cursor.day,
      cursor.hour + 1,
    );
    final slotEnd = math.min(nextHour.millisecondsSinceEpoch, endMs);
    final overlap = slotEnd - cursorMs;
    var share = (bytes * overlap / totalMs).floor();
    if (share > remaining) share = remaining;
    if (share > 0) {
      out.add((hour: cursor, bytes: share));
      remaining -= share;
    }
    cursor = nextHour;
    cursorMs = slotEnd;
  }
  // 舍入的尾巴给最后一个桶，保证总和 == bytes（不凭空丢字节）
  if (remaining > 0 && out.isNotEmpty) {
    final last = out.removeLast();
    out.add((hour: last.hour, bytes: last.bytes + remaining));
  }
  return out;
}

DateTime _floorHour(DateTime t) => DateTime(t.year, t.month, t.day, t.hour);

/// 人类可读字节数（ASCII 单位；中英/葡… 都读得懂，**不含中文单位**）。
///
///   * < 1 KB  → `812 B`
///   * 1.2 MB / 12.3 MB / 123 MB（有效位随量级收敛）
///   * 千分位用 [groupSep]（zh/en 都是 `,`）
String formatTrafficBytes(int bytes, {String groupSep = ','}) {
  final n = bytes < 0 ? 0 : bytes;
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var v = n / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  final digits = v >= 100
      ? 0
      : (v >= 10 ? 1 : 2);
  final s = v.toStringAsFixed(digits);
  final dot = s.indexOf('.');
  final intPart = dot < 0 ? s : s.substring(0, dot);
  final frac = dot < 0 ? '' : s.substring(dot);
  return '${_group(intPart, groupSep)}$frac ${units[u]}';
}

String _group(String digits, String sep) {
  if (sep.isEmpty) return digits;
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(sep);
    buf.write(digits[i]);
  }
  return buf.toString();
}
