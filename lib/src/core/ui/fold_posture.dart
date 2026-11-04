// 折叠**姿态**（铰链角）→ 折痕带（合成 `DisplayFeature`）的**唯一**入口。
//
// ═══════════════════════════════════════════════════════════════════════════
// 一、为什么要有这个文件（真机取证，不是假设）
// ═══════════════════════════════════════════════════════════════════════════
// 本仓的折痕避让只有**一个**信号源：`dart:ui` 的 `FlutterView.displayFeatures`
// （`MediaQuery.displayFeatures`）。真机 **HUAWEI Mate X2（TET-AN00）** 上逐位实测：
//
//   * `MediaQuery.displayFeatures` **恒空**（`nFeat = 0`，竖/横两个朝向都是 0）
//     ⇒ 现有的 `FoldAvoidingLayout` / `AdaptiveScaffold` 折痕分支在**这台机器上
//     空转**：半折时内容照样压在折痕上；
//   * 但**传感器真值可读**（见 `android/.../FoldPostureBridge.kt`）：
//     `android.sensor.hinge_angle(36)`（标准，API 30+）与华为私有
//     `android.sensor.posture(65573)`。实测角度（第 293 轮录制，132 行）：
//       摊平 **179.34°** / 手摆"90°" = **86.80°** / 手摆"45°" = **42.20°** /
//       完全合上 **1.2°** / 再摊平 **179.88°**。
//
// ═══════════════════════════════════════════════════════════════════════════
// 二、三态门槛（160 / 20）的依据
// ═══════════════════════════════════════════════════════════════════════════
//   * **≥ 160° ⇒ flat（展开）**：实测"摊平"停在 **179.34 / 179.88**，
//     最坏余量 19.3°。取 160 而不是 170 是为了容忍柔性屏摊平后的自然残余
//     （面板本身有约 1–2° 的常态弯曲，实测日志里摊平态一直没低于 179.3）。
//   * **20°–160° ⇒ halfOpened（半折）**：实测手摆"90°"档 = 86.80、
//     "45°"档 = 42.20，都落在这段里。
//   * **< 20° ⇒ closed（合上）**：实测完全合上 = **1.2°**，余量 18.8°。
//     20 也是"两块屏之间还站得住人眼"的下界 —— 比这更小就是合盖。
//   * 上界/合法域：`null` / 非有限值 / `< 0` / `> 360` ⇒ **unknown**
//     （AGENTS §2.0.6：拿不到就承认不知道，**绝不编一个角度**）。
//     360 是"可 360° 翻折机型"的摊平上界，按 `flat` 处理。
//
// ═══════════════════════════════════════════════════════════════════════════
// 三、合成折痕带的几何依据（**不另写一套"折痕布局"**，AGENTS §2.0.26）
// ═══════════════════════════════════════════════════════════════════════════
// 半折时**合成一个 `DisplayFeature(type: fold)`** 塞回既有的
// `MediaQuery.displayFeatures` ⇒ 后续完全走改造前就有的
// `verticalObstructingBand` / `horizontalObstructingBand` / `rectHitsBands` /
// `FoldAvoidingLayout` / `AdaptiveScaffold` 路径。**没有第二套折痕布局**。
//
// 位置依据（面板物理事实，两条独立证据）：
//   * `ro.config.hw_fold_disp = 2700,0,1160,0,2200,2480,0,0`（真机 `getprop`）
//     ⇒ 外屏 1160 宽、内屏 2200 宽 ⇒ 展开宽度 ≈ 2 × 1160，**铰链把面板的
//     "短边"对折**；
//   * `dumpsys display` 的 `mOverrideDisplayInfo real 2200 x 2480, rotation 0`
//     ⇒ 面板自然朝向短边 = 2200（= 运行时竖屏宽度 2200/3.25 = 676.923dp）。
//   ⇒ 所以折痕带**沿长边贯穿、占据短边的正中**；随窗口旋转，
//     它就是"面板短边的中间**横带**"（横屏时）或竖带（竖屏时）——
//     与窗口朝向无关的物理描述是"把短边对半分"。
//
// 厚度依据（**按 dpi 折算**）：
//   * 真机面板 **520 dpi**、`dpr = 3.25`（`dumpsys display` 与第 292 轮实测）；
//   * 取 **34 dp**：34 dp × 3.25 = **110.5 px**；110.5 px ÷ 520 dpi
//     = 0.2125 in = **5.40 mm** —— 这是水滴滴铰链折痕两侧**失去平坦度**的
//     物理宽度量级（同量级也见于"5–6 mm 折痕形变带"的公开描述）；
//   * 34 dp 同时是**本仓既有的合成折痕带宽**（`test/adaptive_layout_matrix_test.dart`
//     的 `kFoldBandWidth = 34`，"官方 Layoutlib 常见值"）⇒ 复用它，
//     避免同一语义出现两个数字（§2.0.26）。
//
// ═══════════════════════════════════════════════════════════════════════════
// 四、fail-open（**硬要求**）
// ═══════════════════════════════════════════════════════════════════════════
// `unknown`（非 Android / 测试宿主 / 传感器拿不到 / 姿态不在半折）⇒
// `foldFeaturesForPosture` **原样返回传入的列表实例**（`identical` 为真）⇒
// [FoldPostureLayout] 直接 `return child`，**连一层 `MediaQuery` 都不加**。
// 也就是说：读不到姿态时布局与"今天"逐字节一致，绝不因为"读不到"而改布局。
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../json_coerce.dart';
import '../platform/app_platform.dart';
import '../system_open.dart' show isTestEnvironment;
import 'adaptive_layout.dart';

// ---------------------------------------------------------------- 三态映射

/// 折叠姿态三态（`unknown` **必须**与另外三态分开 —— "不知道"不是"摊平"）。
enum FoldPosture {
  /// 拿不到 / 值不可信 ⇒ 布局 fail-open（与改造前完全一致）。
  unknown,

  /// 展开（摊平）。
  flat,

  /// 半折（可立在桌面上的"笔记本"姿态）。
  halfOpened,

  /// 完全合上。
  closed,
}

/// `>= 160°` ⇒ [FoldPosture.flat]（依据见文件头 §二）。
const double kFoldFlatMinDegrees = 160.0;

/// `< 20°` ⇒ [FoldPosture.closed]（依据见文件头 §二）。
const double kFoldClosedMaxDegrees = 20.0;

/// 纯函数：铰链角 → 三态。**不读 `context`、不碰通道**，便于单测与探针直调。
///
/// 边界（**成对**，见 `test/fold_posture_test.dart`）：
///   `160.0 ⇒ flat` / `159.9 ⇒ halfOpened` / `20.0 ⇒ halfOpened` / `19.9 ⇒ closed`；
///   `null` / `NaN` / `±Infinity` / `< 0` / `> 360` ⇒ `unknown`。
FoldPosture foldPostureForAngle(double? degrees) {
  final d = degrees;
  if (d == null || !d.isFinite || d < 0 || d > 360) return FoldPosture.unknown;
  if (d >= kFoldFlatMinDegrees) return FoldPosture.flat;
  if (d < kFoldClosedMaxDegrees) return FoldPosture.closed;
  return FoldPosture.halfOpened;
}

extension FoldPostureX on FoldPosture {
  bool get isKnown => this != FoldPosture.unknown;
  bool get isFlat => this == FoldPosture.flat;
  bool get isHalfOpened => this == FoldPosture.halfOpened;
  bool get isClosed => this == FoldPosture.closed;

  /// 是否需要折痕避让（**只有**半折要）。`flat` / `closed` / `unknown` 都不要。
  bool get needsFoldBand => this == FoldPosture.halfOpened;

  /// 诊断/日志用的稳定 ASCII 标签（不许拿中文当判据）。
  String get wireName => switch (this) {
    FoldPosture.unknown => 'unknown',
    FoldPosture.flat => 'flat',
    FoldPosture.halfOpened => 'half_opened',
    FoldPosture.closed => 'closed',
  };
}

/// 姿态读数的**来源**（诊断用；判据永远只用角度）。
enum FoldPostureSource {
  /// 没有样本 / 非 Android / 桥缺失。
  unknown('unknown'),

  /// `android.sensor.hinge_angle(36)`（标准，API 30+）。
  hingeAngle('hinge_angle'),

  /// 华为私有 `android.sensor.posture(65573)`（回落路径）。
  posture('posture');

  const FoldPostureSource(this.wireName);

  final String wireName;

  static FoldPostureSource parse(Object? raw) => switch (raw) {
    'hinge_angle' => FoldPostureSource.hingeAngle,
    'posture' => FoldPostureSource.posture,
    _ => FoldPostureSource.unknown,
  };
}

/// 一次姿态读数。
///
/// ★ **没有**独立的 `posture` 字段：三态是 [angleDegrees] 的**派生 getter**
/// （AGENTS §2.0.26 —— 同一语义不许两份表示，派生 getter 不算第二份存储）。
@immutable
class FoldPostureReading {
  const FoldPostureReading({
    this.angleDegrees,
    this.postureCode,
    this.source = FoldPostureSource.unknown,
    this.subscribed = false,
  });

  /// "什么都没有"（= 桥不可用 / 非 Android 宿主 / 注销后）。
  static const FoldPostureReading none = FoldPostureReading();

  /// 铰链角度（度）；`null` = 没有样本。
  final double? angleDegrees;

  /// 华为姿态传感器的第 8 个字段（实测 0.51 / 0.26 / 0.00）。
  ///
  /// ★ **有滞后**（实测角度 87° 时它仍是 0.51）⇒ **只上报、不参与判定**，
  /// 保留原始 `double`（取整会把它变成 1/0，属于"编一个更好的值"）。
  final double? postureCode;

  final FoldPostureSource source;

  /// 此刻原生侧是否真的挂着传感器监听（**纯诊断**）。
  ///
  /// ★ 它**不**参与三态判定：`onPause` 注销时原生侧会保留最后一次已知样本
  /// （见 `FoldPostureBridge.unregister` 的理由），所以"没有监听"不等于
  /// "不知道姿态"。真正的"不知道"一律以 [angleDegrees] 为 `null` 表达。
  final bool subscribed;

  /// 三态（**派生**，唯一判据 = [angleDegrees]）。
  FoldPosture get posture => foldPostureForAngle(angleDegrees);

  factory FoldPostureReading.fromChannel(Object? raw) {
    final map = raw is Map ? raw : const <Object?, Object?>{};
    return FoldPostureReading(
      angleDegrees: jsonDouble(map['angleDegrees']),
      postureCode: jsonDouble(map['postureCode']),
      source: FoldPostureSource.parse(map['source']),
      subscribed: jsonBool(map['subscribed']) ?? false,
    );
  }

  /// 宽容解析：认不出的载荷 ⇒ `null`（**不**回落成"摊平"）。
  static FoldPostureReading? tryParse(Object? raw) {
    if (raw is! Map) return null;
    return FoldPostureReading.fromChannel(raw);
  }

  @override
  String toString() =>
      'FoldPostureReading(angle=$angleDegrees, code=$postureCode, '
      'source=${source.wireName}, subscribed=$subscribed, '
      'posture=${posture.wireName})';
}

// ---------------------------------------------------------------- 合成折痕带

/// 合成折痕带的厚度（dp）。依据（dpi 折算 + 与仓内既有值一致）见文件头 §三。
const double kSyntheticFoldBandDp = 34.0;

/// 纯函数：当前窗口尺寸 ⇒ **合成折痕带**（把短边对半分的那条带）。
///
/// 横屏（`width >= height`）⇒ 横带：`Rect(0, (H-t)/2, W, t)`（= 面板短边的
/// 中间**横带**，任务书原文）；竖屏 ⇒ 竖带：`Rect((W-t)/2, 0, t, H)`。
/// 两者是**同一个物理事实**（铰链沿长边、把短边对半分）在两个朝向下
/// 的坐标表示 —— 见文件头 §三。
Rect syntheticFoldBand(Size size) {
  // 极窄窗口（尺寸小于带宽）时按短边收缩，避免出现负宽度；
  // 收缩到 0 时 `*ObstructingBand` 会因 `width/height <= 0` 主动跳过 ⇒ 不改布局。
  final t = math.min(kSyntheticFoldBandDp, math.min(size.width, size.height));
  if (size.width >= size.height) {
    return Rect.fromLTWH(0, (size.height - t) / 2, size.width, t);
  }
  return Rect.fromLTWH((size.width - t) / 2, 0, t, size.height);
}

/// 纯函数：合成 `DisplayFeature`（`type: fold`、`state: postureHalfOpened`）。
ui.DisplayFeature syntheticFoldFeature(Size size) => ui.DisplayFeature(
  bounds: syntheticFoldBand(size),
  type: ui.DisplayFeatureType.fold,
  state: ui.DisplayFeatureState.postureHalfOpened,
);

/// 纯函数：把姿态**并进**平台给的 `displayFeatures`。
///
/// 三条规则（**同一语义不许两份表示**，§2.0.26）：
///   ① 姿态不是 [FoldPosture.halfOpened] ⇒ **原样返回 `platform` 这个实例**
///      （`identical` 为真 ⇒ 上层连 `MediaQuery` 都不包）；
///   ② 平台**已经**报了可用的 `fold`/`hinge` 带（用既有的
///      `verticalObstructingBand` / `horizontalObstructingBand` 判定）
///      ⇒ 原样返回，**不叠加**第二条带；
///   ③ 合成出来的带若**过不了**既有筛选器（窗口太小之类）⇒ 也不加，
///      免得往树里塞一条谁也不认的 `DisplayFeature`。
List<ui.DisplayFeature> foldFeaturesForPosture(
  List<ui.DisplayFeature> platform,
  FoldPosture posture,
  Size size,
) {
  if (!posture.needsFoldBand) return platform;
  if (verticalObstructingBand(platform, size) != null ||
      horizontalObstructingBand(platform, size) != null) {
    return platform;
  }
  final feature = syntheticFoldFeature(size);
  final usable =
      verticalObstructingBand(<ui.DisplayFeature>[feature], size) != null ||
      horizontalObstructingBand(<ui.DisplayFeature>[feature], size) != null;
  if (!usable) return platform;
  return <ui.DisplayFeature>[...platform, feature];
}

// ---------------------------------------------------------------- 数据源

/// 姿态读数来源。**只有** [PlatformFoldPostureFeed] 会碰平台通道。
abstract class FoldPostureFeed {
  const FoldPostureFeed();

  /// 按宿主挑来源：**非 Android（含 web / 桌面 / `FLUTTER_TEST`）恒为
  /// [NullFoldPostureSource] —— 连通道对象都不建**。
  ///
  /// 为什么不用 `AppCapability` 那张表：那张表是给**跨宿主的可选能力**用的
  /// （要给界面一个可展示的降级原因）；折叠姿态在本仓是**定义域外**
  /// （非 Android 宿主没有"铰链"这个物理量），所以与 `app_paths.dart` 的
  /// `host != AppHost.android` 同一手法。
  factory FoldPostureFeed.forHost() {
    if (kIsWeb || isTestEnvironment || currentAppHost != AppHost.android) {
      return const NullFoldPostureFeed();
    }
    return PlatformFoldPostureFeed();
  }

  /// 姿态流。**永不抛**：认不出的载荷一律丢弃（Dart 侧当 unknown/保持旧值）。
  Stream<FoldPostureReading> get readings;
}

/// 非 Android 宿主：恒 `unknown`，**不建任何通道**。
class NullFoldPostureFeed extends FoldPostureFeed {
  const NullFoldPostureFeed();

  @override
  Stream<FoldPostureReading> get readings =>
      Stream<FoldPostureReading>.value(FoldPostureReading.none);
}

/// Android 真机：`synhub/fold_posture`（拉）+ `synhub/fold_posture/events`（流）。
///
/// 通道对象在**构造时**才建（`forHost()` 已经挡掉非 Android），
/// 所以宿主测试里根本不会出现这两个通道。
///
/// gate-exempt: fold-posture-hinge —— 登记见 `test/method_channel_gate_guard_test.dart`
/// 的 `kGateExemptChannels`。理由：**铰链角是 Android 折叠屏的物理量，非 Android
/// 宿主上这个量根本不存在**（定义域外，不是"能力缺失"），所以不进
/// `AppCapability` 表；调用点由构造点 `forHost()` 保证只有 Android 才建通道，
/// 非 Android 走 `NullFoldPostureFeed`（一个通道都不建）。
class PlatformFoldPostureFeed extends FoldPostureFeed {
  PlatformFoldPostureFeed();

  static const MethodChannel _channel = MethodChannel('synhub/fold_posture');
  static const EventChannel _events = EventChannel('synhub/fold_posture/events');

  /// 零延迟拉取"最后一次样本"（桥没数据时回 `unknown`，不编角度）。
  Future<FoldPostureReading?> read() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('read');
      return FoldPostureReading.tryParse(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on Object {
      return null;
    }
  }

  @override
  Stream<FoldPostureReading> get readings async* {
    // 快路径：拉一次（拉了才有值就省掉"等第一个事件"的延迟）。
    final first = await read();
    if (first != null && first.angleDegrees != null) yield first;
    yield* _events
        .receiveBroadcastStream()
        .map<FoldPostureReading?>(FoldPostureReading.tryParse)
        .where((r) => r != null)
        .cast<FoldPostureReading>()
        .handleError((Object e) {
          // 桥断了不是崩溃：当作"再没有事件"（上层按 unknown 处理，fail-open）
          debugPrint('[foldPosture] channel error: ${e.runtimeType}');
        });
  }
}

/// 姿态来源（测试里覆盖成假实现 ⇒ 完全不碰平台通道）。
final foldPostureFeedProvider = Provider<FoldPostureFeed>(
  (ref) => FoldPostureFeed.forHost(),
);

/// 当前姿态读数流。
///
/// 语义：**拿不到就是 `FoldPostureReading.none`（unknown）**，绝不假装摊平。
final foldPostureProvider = StreamProvider<FoldPostureReading>(
  (ref) => ref.watch(foldPostureFeedProvider).readings,
);

// ---------------------------------------------------------------- 接进既有避让

/// 把合成折痕带**喂给既有的折痕避让路径**的唯一容器。
///
/// 它只做一件事：`MediaQuery.displayFeatures` 换成"平台原值 +
/// 姿态合成的 `fold` 带"，然后原样放行 [child]。
/// 下游的 `FoldAvoidingLayout` / `AdaptiveScaffold` / `rectHitsBands`
/// **一行都不用改**（§2.0.26：不另写一套折痕布局）。
///
/// fail-open：姿态 `unknown` / 摊平 / 合上 ⇒ 合成函数原样返回平台那份列表
/// （同一实例）⇒ 这里 `return child`，**零新增 render object**。
class FoldPostureLayout extends ConsumerWidget {
  const FoldPostureLayout({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// 关掉即恒等于 [child]（测试反向验证用）。
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!enabled) return child;
    final size = MediaQuery.sizeOf(context);
    final platform = MediaQuery.displayFeaturesOf(context);
    // 只看三态：角度每 100ms 变一次，不必让整棵树跟着重算。
    final posture = ref.watch(
      foldPostureProvider.select((v) => v.value?.posture ?? FoldPosture.unknown),
    );
    final merged = foldFeaturesForPosture(platform, posture, size);
    // ★ 机制量：没加任何带 ⇒ 连 `MediaQuery` 都不包（与改造前逐字节一致）。
    if (identical(merged, platform)) return child;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(displayFeatures: merged),
      child: child,
    );
  }
}
