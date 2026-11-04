// 目标机性能档位 —— 决定"炫酷效果"的**默认**开关。
//
// 为什么要有这个：
//   毛玻璃（`BackdropFilter`）、HUD 网格底纹、常驻动效在高端机上很爽，
//   在 3GB/4 核的老机器上就是掉帧和耗电。一刀切（全开或全关）两边都不对，
//   所以按设备规格分三档给出**默认值**，用户随时能在设置里手动覆盖。
//
// 只做规格判定，不做运行时掉帧自适应：规格是稳定的，第一次启动就定下来，
// 用户看到的行为不会中途变来变去（想更激进可以在 `AppEffects` 上再接
// `SchedulerBinding.addTimingsCallback`，见 docs/ui-redesign.md）。
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/data_text.dart';
import '../i18n/l10n.dart';

/// 设备性能档位
enum DeviceTier {
  /// 入门机：关毛玻璃、默认减少动效、关网格底纹
  low,

  /// 中端机：有动效但没有毛玻璃
  medium,

  /// 高端机：全套座舱玻璃 + 动效
  high,
}

/// 一次探测得到的设备规格 + 由它推出的默认效果
class DeviceProfile {
  const DeviceProfile({
    required this.tier,
    required this.cores,
    required this.ramMb,
    required this.sdkInt,
  });

  final DeviceTier tier;

  /// 逻辑核数（`Platform.numberOfProcessors`，拿不到就是 0）
  final int cores;

  /// 物理内存 MB（Android/Linux 读 `/proc/meminfo` 的 MemTotal，
  /// macOS 读 `sysctl -n hw.memsize`；拿不到就是 0）
  final int ramMb;

  /// Android API level（解析不到就是 0）
  final int sdkInt;

  /// 拿不到任何规格时的兜底：当成高端（效果全开），
  /// 这也是改造前的老行为，测试/桌面端都走这一支。
  static const DeviceProfile fallback = DeviceProfile(
    tier: DeviceTier.high,
    cores: 0,
    ramMb: 0,
    sdkInt: 0,
  );

  /// 默认要不要开毛玻璃（= 性能模式的**反**）
  bool get preferBlur => tier == DeviceTier.high;

  /// 默认要不要减少动效
  bool get preferReducedMotion => tier == DeviceTier.low;

  /// 默认要不要画网格底纹
  bool get preferChatGrid => tier != DeviceTier.low;

  /// 档位文案（**中文回落**，走 dataText；界面用 [tierLabelIn]）
  String get tierLabel => switch (tier) {
    DeviceTier.low => dataText('devTierLow', '入门'),
    DeviceTier.medium => dataText('devTierMedium', '中端'),
    DeviceTier.high => dataText('devTierHigh', '高端'),
  };

  /// 本地化档位名（设置页/设计预览页用 `tierLabelIn(context.t)`）
  String tierLabelIn(AppText t) => switch (tier) {
    DeviceTier.low => t.devTierLow,
    DeviceTier.medium => t.devTierMedium,
    DeviceTier.high => t.devTierHigh,
  };

  /// 「6 核 · 7.0 GB · Android SDK 31」这样的遥测串（缺项自动省略）。
  ///
  /// 中文回落版；界面用 [specLabelIn]（英文是 `6-core · 7.0 GB · Android SDK 31`）。
  String get specLabel => specLabelIn(currentText());

  /// 本地化遥测串
  String specLabelIn(AppText t) {
    final bits = <String>[
      if (cores > 0) t.devCoresCount(cores),
      if (ramMb > 0) '${(ramMb / 1024).toStringAsFixed(1)} GB',
      if (sdkInt > 0) 'Android SDK $sdkInt',
    ];
    return bits.isEmpty ? t.devSpecUnknown : bits.join(' · ');
  }

  /// 由规格推档位（纯函数，方便单测）：
  ///
  ///   * ≤4 核 / ≤3GB / Android 8 以下 → 入门
  ///   * ≤4.5GB 内存 → 中端
  ///   * 其余（例如 6 核 + 7GB）→ 高端
  static DeviceTier classify({
    required int cores,
    required int ramMb,
    int sdkInt = 0,
  }) {
    if (cores > 0 && cores <= 4) return DeviceTier.low;
    if (ramMb > 0 && ramMb <= 3072) return DeviceTier.low;
    if (sdkInt > 0 && sdkInt < 26) return DeviceTier.low;
    if (ramMb > 0 && ramMb <= 4608) return DeviceTier.medium;
    if (cores > 0 && cores < 6) return DeviceTier.medium;
    return DeviceTier.high;
  }

  /// 组装（便于测试直接喂规格）
  factory DeviceProfile.of({
    required int cores,
    required int ramMb,
    int sdkInt = 0,
  }) => DeviceProfile(
    tier: classify(cores: cores, ramMb: ramMb, sdkInt: sdkInt),
    cores: cores,
    ramMb: ramMb,
    sdkInt: sdkInt,
  );

  /// 真的去问系统（同步读，启动时一次）
  static DeviceProfile detect() {
    // ★★ 第 336 轮（真缺陷，浏览器实测抓到）：这里**必须在最前面判 web**。
    //   `dart2js` 的 `dart:io` 是"一律抛 UnsupportedError"的桩，
    //   而下面 `Platform.isAndroid` / `Platform.operatingSystemVersion`
    //   原本**不在 try 里** ⇒ `main()` 第 17 行调用本函数时直接抛
    //   `Unsupported operation: Platform._operatingSystem`，
    //   **runApp 之前就断了 ⇒ web 首屏白屏**（截图 2.5 KB 纯色、控制台只有
    //   `Uncaught ` 空串）。设备档位对 web 宿主本来也不适用（§2.0.6③ 宿主不门控）。
    if (kIsWeb) {
      return DeviceProfile.of(cores: 0, ramMb: 0, sdkInt: 0);
    }
    var cores = 0;
    var ramMb = 0;
    var sdkInt = 0;
    try {
      cores = Platform.numberOfProcessors;
    } catch (_) {
      // 某些沙箱里会抛，忽略
    }
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        final text = File('/proc/meminfo').readAsStringSync();
        final m = RegExp(r'MemTotal:\s*(\d+)\s*kB').firstMatch(text);
        if (m != null) ramMb = (int.parse(m.group(1)!) / 1024).round();
      } else if (Platform.isMacOS) {
        // macOS 没有 `/proc/meminfo`（原实现因此 ramMb=0，档位退化到"只靠核数"）。
        // `sysctl -n hw.memsize` 回**字节数**，是
        // `ProcessInfo.processInfo.physicalMemory` 的命令行等价物；
        // 沙箱（App Sandbox）下读 sysctl 不需要额外 entitlement。
        final r = Process.runSync('/usr/sbin/sysctl', ['-n', 'hw.memsize']);
        if (r.exitCode == 0) {
          final bytes = int.tryParse('${r.stdout}'.trim());
          if (bytes != null && bytes > 0) {
            ramMb = (bytes / 1024 / 1024).round();
          }
        }
      }
    } catch (_) {
      // 读不到就算了，靠核数/API 判定
    }
    // ★ 同轮：即使非 web，这里也不许裸调 —— 与上面两段同风格包 try/catch，
    //   免得将来新增平台（或 stub）又让启动路径变成"抛在 runApp 之前"。
    try {
      if (Platform.isAndroid) {
        // Flutter 在 Android 上给的是 "12 (SDK 31)" 这种串
        final m = RegExp(
          r'SDK\s*(\d+)',
        ).firstMatch(Platform.operatingSystemVersion);
        if (m != null) sdkInt = int.parse(m.group(1)!);
      }
    } catch (_) {
      // 读不到就保持 sdkInt = 0
    }
    return DeviceProfile.of(cores: cores, ramMb: ramMb, sdkInt: sdkInt);
  }

  @override
  String toString() =>
      'DeviceProfile(${tier.name}, cores=$cores, ramMb=$ramMb, sdk=$sdkInt)';
}

/// 当前设备档位。`main()` 会用探测结果覆盖它；默认走 [DeviceProfile.fallback]
/// （= 高端，效果全开），这样离线测试与桌面端行为恒定。
final deviceProfileProvider = Provider<DeviceProfile>(
  (ref) => DeviceProfile.fallback,
);
