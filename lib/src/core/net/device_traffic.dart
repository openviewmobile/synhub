// **估算档**流量：原生组件绕过 Dart 的那部分（ExoPlayer/just_audio 播放、
// 原生抽帧桥、原生 Audio Station 流、原生下载/上传）。
//
// 为什么只能估算：Android 的 `android.net.TrafficStats` 只给**按 UID** 的
// 累计计数（`getUidRxBytes` / `getUidTxBytes`，另有 `getMobile*` / `getTotal*`），
// 它**无法拆到模块**。所以做法是：在**已知活动会话**（如"正在播放"）前后各采一次
// UID 计数，把差分归属给那个模块，并如实记成 `estimated` + 会话区间。
//
// 三条不可越界的规矩（见 `docs/network-traffic-analytics.md` §2）：
//   1. **空闲期永不归属**：没有 begin/end 就没有归属，绝不拿"这两次采样之间"
//      的差值去猜某个模块；
//   2. **不可信就丢弃**：差值太大（后台 OS 流量混进来）、会话太短（噪声）、
//      计数不可读（UNSUPPORTED）一律**丢掉**，记 `unattributed`（不是编一个数）；
//   3. **不轮询**：只在会话开始/结束各采一次，空闲不设定时器。
//
// 原生桥：`android/.../TrafficStatsBridge.kt`（**只读**，无任何权限）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
import 'traffic_meter.dart';

/// 一次 UID 计数快照（单位字节；`-1` = 平台不支持该项）
class DeviceTrafficSnapshot {
  const DeviceTrafficSnapshot({
    required this.at,
    required this.uidRx,
    required this.uidTx,
    required this.mobileRx,
    required this.mobileTx,
    required this.totalRx,
    required this.totalTx,
  });

  final DateTime at;
  final int uidRx;
  final int uidTx;
  /// 按 UID 的移动数据计数 —— Android **公开 API 没有**这一项
  /// （`TrafficStats` 只有整机的 `getMobile*`）⇒ 生产桥固定回 `-1`。
  /// 保留字段是为了将来平台补齐时不改结构；**不要**拿整机数字填进来。
  final int mobileRx;
  final int mobileTx;
  final int totalRx;
  final int totalTx;

  /// UID 计数可读吗（部分设备/低版本会给 `UNSUPPORTED = -1`）
  bool get supported => uidRx >= 0 && uidTx >= 0;

  int get uidTotal => _pos(uidRx) + _pos(uidTx);
  int get mobileTotal => _pos(mobileRx) + _pos(mobileTx);
  int get totalAll => _pos(totalRx) + _pos(totalTx);

  static int _pos(int v) => v < 0 ? 0 : v;

  factory DeviceTrafficSnapshot.fromMap(Map<Object?, Object?> m) =>
      DeviceTrafficSnapshot(
        at: DateTime.now(),
        uidRx: _int(m['uidRx']),
        uidTx: _int(m['uidTx']),
        mobileRx: _int(m['mobileRx']),
        mobileTx: _int(m['mobileTx']),
        totalRx: _int(m['totalRx']),
        totalTx: _int(m['totalTx']),
      );

  static int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : -1);

  Map<String, Object?> toJson() => {
    'at_ms': at.millisecondsSinceEpoch,
    'uid_rx': uidRx,
    'uid_tx': uidTx,
    'mobile_rx': mobileRx,
    'mobile_tx': mobileTx,
    'total_rx': totalRx,
    'total_tx': totalTx,
  };

  static DeviceTrafficSnapshot? fromJson(Map<String, Object?> j) {
    final atMs = j['at_ms'];
    if (atMs is! int) return null;
    return DeviceTrafficSnapshot(
      at: DateTime.fromMillisecondsSinceEpoch(atMs),
      uidRx: _int(j['uid_rx']),
      uidTx: _int(j['uid_tx']),
      mobileRx: _int(j['mobile_rx']),
      mobileTx: _int(j['mobile_tx']),
      totalRx: _int(j['total_rx']),
      totalTx: _int(j['total_tx']),
    );
  }
}

/// 采一次 UID 计数（测试可注入假实现）
abstract class DeviceTrafficProbe {
  Future<DeviceTrafficSnapshot?> snapshot();
}

/// 生产实现：MethodChannel → `TrafficStatsBridge.kt`（只读）
class MethodChannelDeviceTrafficProbe implements DeviceTrafficProbe {
  MethodChannelDeviceTrafficProbe({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('synhub/traffic');

  final MethodChannel _channel;

  @override
  Future<DeviceTrafficSnapshot?> snapshot() async {
    // ★ 第 55 轮：`synhub/traffic` 是 Android `TrafficStats` 的桥 ⇒
    //   宿主上能力层报 `unavailable:not-implemented-on-host`，不碰通道。
    if (!capabilityGateAllows(AppCapability.networkTrafficCounters)) {
      debugPrint(
        capabilityGateLog(
          AppCapability.networkTrafficCounters,
          'traffic.uidSnapshot',
        ),
      );
      return null;
    }
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'uidSnapshot',
      );
      if (raw == null) return null;
      return DeviceTrafficSnapshot.fromMap(raw);
    } catch (_) {
      // 桌面/测试/无桥：没有 UID 计数 → 估算档整体不可用（如实返回 null）
      return null;
    }
  }
}

/// 估算的**取舍规则**结果
enum EstimatedDiscardReason {
  /// 平台给不了 UID 计数（UNSUPPORTED）
  unsupported('unsupported'),

  /// 会话太短（差分基本是噪声）
  tooShort('too_short'),

  /// 差值为负 / 几乎为零（没流量或计数回绕）
  idle('idle'),

  /// 差值**离谱地大**（后台 OS 流量混进了窗口）→ 丢弃，不归属
  implausible('implausible');

  const EstimatedDiscardReason(this.id);
  final String id;
}

/// 一次估算会话的归属结果
class EstimatedAttribution {
  const EstimatedAttribution.accepted({
    required this.from,
    required this.to,
    required this.rxBytes,
    required this.txBytes,
  }) : accepted = true,
       reason = null;

  const EstimatedAttribution.discarded(this.reason, {required this.from, required this.to})
    : accepted = false,
      rxBytes = 0,
      txBytes = 0;

  final bool accepted;
  final EstimatedDiscardReason? reason;
  final DateTime from;
  final DateTime to;
  final int rxBytes;
  final int txBytes;

  int get totalBytes => rxBytes + txBytes;
}

/// **纯函数**：给定会话前后两次 UID 快照，决定归不归属。
///
/// 这是估算档的核心判据，单独抽出来是为了能离线测（含边界）。
EstimatedAttribution attributeUidDelta({
  required DeviceTrafficSnapshot? before,
  required DeviceTrafficSnapshot? after,
  required DateTime from,
  required DateTime to,
  int capBytes = kEstimatedSessionCapBytes,
  Duration minDuration = kEstimatedMinDuration,
  int minBytes = kEstimatedMinBytes,
}) {
  if (before == null || after == null || !before.supported || !after.supported) {
    return EstimatedAttribution.discarded(
      EstimatedDiscardReason.unsupported,
      from: from,
      to: to,
    );
  }
  if (to.difference(from) < minDuration) {
    return EstimatedAttribution.discarded(
      EstimatedDiscardReason.tooShort,
      from: from,
      to: to,
    );
  }
  final rx = after.uidRx - before.uidRx;
  final tx = after.uidTx - before.uidTx;
  // 负值 = 计数回绕或换了 UID → 不猜，丢弃
  if (rx < 0 || tx < 0) {
    return EstimatedAttribution.discarded(
      EstimatedDiscardReason.idle,
      from: from,
      to: to,
    );
  }
  final total = rx + tx;
  if (total < minBytes) {
    return EstimatedAttribution.discarded(
      EstimatedDiscardReason.idle,
      from: from,
      to: to,
    );
  }
  if (total > capBytes) {
    // 窗口内混进了别的东西（后台同步/系统更新）⇒ 不可信，丢弃
    return EstimatedAttribution.discarded(
      EstimatedDiscardReason.implausible,
      from: from,
      to: to,
    );
  }
  return EstimatedAttribution.accepted(
    from: from,
    to: to,
    rxBytes: rx,
    txBytes: tx,
  );
}

/// 会话窗口内的差值**封顶**（4 GiB）：超过就整段丢弃，不做"截断后归属"
/// —— 截断等于承认"我知道哪部分是真的"，而 UID 计数给不了这个信息。
const int kEstimatedSessionCapBytes = 4 * 1024 * 1024 * 1024;

/// 少于 2 秒的会话不值得估（差分基本是噪声）
const Duration kEstimatedMinDuration = Duration(seconds: 2);

/// 少于 16 KB 的差分当"没流量"
const int kEstimatedMinBytes = 16 * 1024;

/// 全局估算器：由 `app.dart` 注入（probe + sink）；未注入时 begin/end 是 no-op。
///
/// 用**单例**而不是 provider：原生播放器/后台起播的地方拿不到 `ref`，
/// 与 `usageLogProvider` → `setGlobalUsageLog` 同一套做法。
class EstimatedTrafficTracker {
  EstimatedTrafficTracker({
    required this.probe,
    required this.sink,
    this.capBytes = kEstimatedSessionCapBytes,
    this.minDuration = kEstimatedMinDuration,
    this.minBytes = kEstimatedMinBytes,
  });

  final DeviceTrafficProbe probe;
  final TrafficSink sink;
  final int capBytes;
  final Duration minDuration;
  final int minBytes;

  DeviceTrafficSnapshot? _before;
  DateTime? _startedAt;
  String? _module;
  bool _busy = false;

  /// 当前有没有正在计量的会话（诊断/测试用）
  bool get active => _startedAt != null;

  /// 会话开始：采一次基线。重复调用（同一会话）无副作用。
  Future<void> begin(String module) async {
    if (_startedAt != null || _busy) return;
    _busy = true;
    try {
      final snap = await probe.snapshot();
      _before = snap;
      _startedAt = DateTime.now();
      _module = module;
    } catch (_) {
      _before = null;
    } finally {
      _busy = false;
    }
  }

  /// 会话结束：采一次，算差分 → 可信才归属，否则丢弃。
  Future<EstimatedAttribution?> end() async {
    final from = _startedAt;
    final module = _module;
    final before = _before;
    _startedAt = null;
    _module = null;
    _before = null;
    if (from == null || module == null) return null;
    if (_busy) return null;
    _busy = true;
    try {
      final after = await probe.snapshot();
      final to = DateTime.now();
      final result = attributeUidDelta(
        before: before,
        after: after,
        from: from,
        to: to,
        capBytes: capBytes,
        minDuration: minDuration,
        minBytes: minBytes,
      );
      if (result.accepted) {
        try {
          if (result.rxBytes > 0) {
            sink.addEstimate(
              TrafficEstimate(
                from: from,
                to: to,
                module: module,
                direction: TrafficDirection.down,
                bytes: result.rxBytes,
              ),
            );
          }
          if (result.txBytes > 0) {
            sink.addEstimate(
              TrafficEstimate(
                from: from,
                to: to,
                module: module,
                direction: TrafficDirection.up,
                bytes: result.txBytes,
              ),
            );
          }
        } catch (_) {
          // 估算失败绝不影响播放
        }
      }
      return result;
    } catch (_) {
      return null;
    } finally {
      _busy = false;
    }
  }
}

EstimatedTrafficTracker? _global;

/// 启动时注入（`app.dart`）
void setGlobalEstimatedTraffic(EstimatedTrafficTracker? tracker) =>
    _global = tracker;

/// 当前全局估算器
EstimatedTrafficTracker? get globalEstimatedTraffic => _global;

/// 播放类会话的便捷入口（原生化组件用它成对 begin/end）
///
/// 未注入 / 平台不支持时是纯 no-op：调用点不需要判空。
abstract final class EstimatedTraffic {
  static Future<void> begin(String module) async {
    try {
      await _global?.begin(module);
    } catch (_) {}
  }

  static Future<void> end() async {
    try {
      await _global?.end();
    } catch (_) {}
  }
}
