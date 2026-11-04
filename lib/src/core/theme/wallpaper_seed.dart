// 壁纸取色（第 231 轮，用户裁定：**Material You 保留默认开，而且要想办法真正取到壁纸色**）。
//
// 背景：`dynamic_color` 的 `DynamicColorBuilder` 只在**有 Material You** 的机器上给方案，
// EMUI / HarmonyOS / Android<12 / OEM 关掉的 ROM 一律回调 null ⇒ 界面永远是品牌蓝，
// 「跟随壁纸」变成假开关（r540 就是这样发现问题的）。
//
// 这里补一条不依赖 Material You 的通道（原生 `synhub/wallpaper`）：
//   ① `WallpaperColors`（系统算好的主色）→ ② 自读壁纸图按饱和度加权平均 → ③ none。
//
// ★ 只提供 **seed（色相）**，中性色/语义色仍由设计令牌决定（`DA160` 的结论：
//   `error`/`outline`/`surfaceContainerHighest` 不许跟着壁纸跑）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 取色来源（按"可信度"从高到低）。
enum WallpaperColorSource {
  /// Material You 原生方案（`DynamicColorBuilder` 给到了 scheme）。
  materialYou,

  /// 系统 `WallpaperManager.getWallpaperColors` 给的主色。
  wallpaperColors,

  /// 自己读壁纸图算出来的加权平均色。
  bitmap,

  /// 系统主题色 `system_accent*`（Android 12+；**动态壁纸**机器上唯一拿得到的取值）。
  systemAccent,

  /// 拿不到（无壁纸权限 / 纯灰度壁纸 / 平台不支持）⇒ 回退品牌蓝。
  none,
}

/// 一次取色的结果。`seed` 是 `0xRRGGBB`（不含 alpha）。
@immutable
class WallpaperSeed {
  const WallpaperSeed({
    required this.source,
    this.seed,
    this.saturation = 0,
    this.detail = '',
  });

  final WallpaperColorSource source;
  final int? seed;
  final double saturation;
  final String detail;

  /// 拿得到颜色就转成 `Color`。
  Color? get color => seed == null ? null : Color(0xFF000000 | (seed! & 0xFFFFFF));

  /// 能不能拿来当 seed：有色相，且不是"几乎灰度"（灰度壁纸取出来会发灰，
  /// 反而比品牌蓝更难看 —— 这时宁可回退）。
  bool get usable => color != null && saturation >= 0.08;

  /// 解析原生回包（原生只回 Map，类型可能不齐，这里逐字段兜住）。
  static WallpaperSeed fromMap(Object? raw) {
    if (raw is! Map) {
      return const WallpaperSeed(source: WallpaperColorSource.none, detail: 'noMap');
    }
    final src = switch ('${raw['source'] ?? 'none'}') {
      'materialYou' => WallpaperColorSource.materialYou,
      'wallpaperColors' => WallpaperColorSource.wallpaperColors,
      'bitmap' => WallpaperColorSource.bitmap,
      'systemAccent' => WallpaperColorSource.systemAccent,
      _ => WallpaperColorSource.none,
    };
    final rawSeed = raw['seed'];
    final seed = switch (rawSeed) {
      final int v => v,
      final num v => v.toInt(),
      final String v => int.tryParse(v) ?? 0,
      _ => 0,
    };
    final rawSat = raw['saturation'];
    final saturation = switch (rawSat) {
      final num v => v.toDouble(),
      final String v => double.tryParse(v) ?? 0,
      _ => 0.0,
    };
    final detail = [
      if (raw['error'] != null) 'error=${raw['error']}',
      if (raw['colorsError'] != null) 'colors=${raw['colorsError']}',
      if (raw['bitmapError'] != null) 'bitmap=${raw['bitmapError']}',
      if (raw['sdkInt'] != null) 'sdk=${raw['sdkInt']}',
    ].join(' ');
    return WallpaperSeed(
      source: src,
      seed: seed == 0 ? null : seed,
      saturation: saturation,
      detail: detail,
    );
  }

  @override
  String toString() =>
      'WallpaperSeed(${source.name}, seed=${seed == null ? '-' : seed!.toRadixString(16)}, '
      'sat=${saturation.toStringAsFixed(2)}${detail.isEmpty ? '' : ', $detail'})';
}

/// 原生通道名（与 `WallpaperBridge.kt` 对齐）。
/// gate-exempt: wallpaper-color —— 登记见 `test/method_channel_gate_guard_test.dart`：
/// 这条通道**天生允许不存在**（桌面/Web/测试没有壁纸概念），"取不到"就是设计内的
/// 正常结果，调用点已 try/catch 回 `none` 并回退品牌蓝。
const String kWallpaperChannel = 'synhub/wallpaper';

/// 读一次壁纸主色。**任何异常都不许冒泡到界面**（拿不到就是 `none`）。
Future<WallpaperSeed> readWallpaperSeed({
  MethodChannel channel = const MethodChannel(kWallpaperChannel),
}) async {
  try {
    final raw = await channel.invokeMethod<Object?>('seed');
    return WallpaperSeed.fromMap(raw);
  } catch (e) {
    return WallpaperSeed(
      source: WallpaperColorSource.none,
      detail: 'channel=${e.runtimeType}',
    );
  }
}

/// 取色结果（整个 App 生命周期读一次就够；壁纸变了重启即生效）。
final wallpaperSeedProvider = FutureProvider<WallpaperSeed>(
  (ref) => readWallpaperSeed(),
);
