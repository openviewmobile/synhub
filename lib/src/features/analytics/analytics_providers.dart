// 使用日志 / 分析的 Riverpod 接线。
//
//   * [analyticsDatabaseProvider] —— 懒开库；开失败返回 null（比如磁盘满），
//     所有下游都要能接受 null（日志是"可有可无"的能力，不能拖垮业务）；
//   * [usageLogProvider] —— 写入端单例（含缓冲、会话切分）；
//   * [usageStatsProvider] —— 近 90 天的聚合统计（分析页用）；
//   * [usageInsightsProvider] —— 规则层结论（读统计 → 算结论 → 落库缓存）；
//   * [analyticsEnabledProvider] —— 开关（持久化在日志库的元数据表里）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/device_traffic.dart';
import '../../core/provider_retry.dart';
import '../../data/local/analytics_database.dart';
import 'traffic_analysis.dart';
import 'traffic_log.dart';
import 'usage_analysis.dart';
import 'usage_log.dart';

/// 分析默认看多久的窗口（和裁剪保留天数一致，避免"看得到算不到"）
const Duration kAnalyticsWindow = Duration(days: 180);

/// 懒开的日志库；失败就是 null
final analyticsDatabaseProvider = Provider<AnalyticsDatabase?>((ref) {
  try {
    final db = AnalyticsDatabase.open();
    ref.onDispose(db.close);
    return db;
  } catch (_) {
    return null;
  }
});

/// 写入端（库开不起来时返回一个只进内存的实例，UI 调用点不用判空）
///
/// ★★ 第 338 轮（D36）：**内存兜底自己也可能建不起来**（web：drift 的内存库
/// 要 wasm + 异步装配）—— 那时必须退到 [AnalyticsDatabase.unavailable]
/// （"日志关闭"的空实现），**绝不允许 provider 停在错误态**：一旦停了，
/// 每个 `watch` 它的 widget 都会在启动时抛 `ProviderException`（web 实测两处）。
final usageLogProvider = Provider<UsageLog>((ref) {
  final db = ref.watch(analyticsDatabaseProvider);
  AnalyticsDatabase effective;
  if (db != null) {
    effective = db;
  } else {
    try {
      effective = AnalyticsDatabase.memory();
    } catch (_) {
      // 连内存库都建不起来（web 上没有同步内存库）⇒ "日志关闭"，
      // **绝不**让 provider 停在错误态（那会把 ProviderException 喷给每个读者）。
      final off = UsageLog.disabled();
      ref.onDispose(off.dispose);
      return off;
    }
  }
  final log = UsageLog(effective);
  ref.onDispose(log.dispose);
  return log;
});

/// 是否开启使用日志（默认开；关掉之后 `record` 直接丢弃）
final analyticsEnabledProvider =
    NotifierProvider<AnalyticsEnabledNotifier, bool>(
      AnalyticsEnabledNotifier.new,
    );

class AnalyticsEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  /// 启动时从库里读（`app.dart` preload）
  Future<void> load() async {
    final log = ref.read(usageLogProvider);
    await log.load();
    ref.read(trafficLogProvider).enabled = log.enabled;
    if (!ref.mounted) return;
    state = log.enabled;
  }

  Future<void> set(bool value) async {
    state = value;
    ref.read(trafficLogProvider).enabled = value;
    await ref.read(usageLogProvider).setEnabled(value);
  }
}

/// 近 [kAnalyticsWindow] 的聚合统计
final usageStatsProvider = FutureProvider<UsageStats>((ref) async {
  final log = ref.watch(usageLogProvider);
  final events = await log.range(window: kAnalyticsWindow);
  return computeUsageStats(events);
}, retry: noRetry);

/// 规则层结论（每次读都重算，同时把结果落库供下次首屏秒开）
final usageInsightsProvider = FutureProvider<List<UsageInsight>>((ref) async {
  final log = ref.watch(usageLogProvider);
  final events = await log.range(window: kAnalyticsWindow);
  final insights = buildInsights(computeUsageStats(events));
  await log.saveInsights(insights);
  return insights;
}, retry: noRetry);

/// 原始事件条数（"有多少数据"展示用）
final usageEventCountProvider = FutureProvider<int>((ref) async {
  ref.watch(usageInsightsProvider); // 结论刷新后条数也要跟着刷新
  return ref.watch(usageLogProvider).eventCount();
}, retry: noRetry);

// ── 网络流量（第 276 轮）─────────────────────────────────────────────────

/// 流量写入端：与使用日志**共用同一个 drift 库实例**（`analyticsDatabaseProvider`），
/// 避免同一份 sqlite 被两个 drift 实例同时打开。
final trafficLogProvider = Provider<TrafficLog>((ref) {
  final db = ref.watch(analyticsDatabaseProvider);
  if (db != null) {
    final log = TrafficLog(db);
    ref.onDispose(log.dispose);
    return log;
  }
  try {
    final mem = AnalyticsDatabase.memory();
    final log = TrafficLog(mem);
    ref.onDispose(log.dispose);
    return log;
  } catch (_) {
    // 同 [usageLogProvider]：兜底也起不来就"不记账"，不许停在错误态
    // （开关跟随「使用分析」总开关，由 load()/set() 同步）
    final off = TrafficLog.disabled();
    ref.onDispose(off.dispose);
    return off;
  }
});

/// 按 UID 采样的原生计数探针（生产实现走 `TrafficStatsBridge.kt`）
final deviceTrafficProbeProvider = Provider<DeviceTrafficProbe>(
  (ref) => MethodChannelDeviceTrafficProbe(),
);

/// 流量统计窗口（UI 的「日 / 周」切换）
final trafficWindowProvider = FutureProvider.family<TrafficStats, Duration>((
  ref,
  window,
) async {
  final log = ref.watch(trafficLogProvider);
  final buckets = await log.range(window: window + const Duration(hours: 2));
  final probe = ref.watch(deviceTrafficProbeProvider);
  final now = await probe.snapshot();
  final baseJson = await log.osBaseline();
  final base = baseJson == null
      ? null
      : DeviceTrafficSnapshot.fromJson(baseJson);

  var osRx = 0;
  var osTx = 0;
  var osMobileRx = 0;
  var osMobileTx = 0;
  DateTime? baseAt;
  if (base != null &&
      now != null &&
      base.supported &&
      now.supported &&
      now.at.isAfter(base.at)) {
    baseAt = base.at;
    osRx = _nonNeg(now.uidRx - base.uidRx);
    osTx = _nonNeg(now.uidTx - base.uidTx);
    osMobileRx = _nonNeg(now.mobileRx - base.mobileRx);
    osMobileTx = _nonNeg(now.mobileTx - base.mobileTx);
  }
  return computeTrafficStats(
    buckets,
    now: DateTime.now(),
    osBaselineAt: baseAt,
    osRxBytes: osRx,
    osTxBytes: osTx,
    osMobileRxBytes: osMobileRx,
    osMobileTxBytes: osMobileTx,
  );
}, retry: noRetry);

int _nonNeg(int v) => v < 0 ? 0 : v;
