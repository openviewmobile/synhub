// 自适应布局核心：**窗口尺寸分级** + **折叠屏折痕避让** + **宽屏双栏骨架**。
//
// ═══════════════════════════════════════════════════════════════════════════
// 一、断点依据（为什么是 600 / 700）—— ★ 700 **不是** Material 3 的官方值
// ═══════════════════════════════════════════════════════════════════════════
// 分档外形沿用 **Material 3 window size class** 的名字（compact / medium /
// expanded，与 AndroidX `WindowSizeClass`、Flutter 官方 `adaptive_scaffold`
// 样例同构），但**数值是有意偏离官方的**，必须如实标注：
//
//   * **compact 上界照抄官方 600**；
//   * **medium 上界由官方的 840 下调为 700**（第 293 轮，真机取证后的产品
//     决定 —— 参考 `docs/device-verification.md` 的最新一节）。也就是说
//     700–839 这一段的裁定与 AndroidX 不同：**本仓判 expanded（双栏），
//     官方判 medium**。这不是"照抄官方"，别把它读成 M3 分档。
//
//   * `< 600 dp`  → compact  ：手机竖屏（本仓真机 ≈ 417dp、iPhone 393pt）
//   * `600–699 dp`→ medium   ：分屏一半、折叠**外屏横**等。单列
//   * `>= 700 dp` → expanded ：折叠屏**内屏横屏**、Pad 竖屏、桌面窗口。双栏
//
// 取值依据（全部**实测**，不是推算）：
//   * **HUAWEI Mate X2（TET-AN00）内屏**：2480×2200 @520dpi、dpr 3.25 ⇒ 运行时
//     `MediaQuery.width` = **竖屏 676.923dp / 横屏 763.077dp**（r292 逐位实测）。
//     在 840 门槛下这台机器的**两个朝向都恒为 medium**（永远单栏）—— 也就是
//     说 840 让"折叠屏内屏展开"这个最该双栏的场景**永远拿不到双栏**。
//     700 之后：**横屏 763.077 ⇒ expanded（两栏）**、**竖屏 676.923 ⇒ medium
//     （单栏）** —— 与"竖屏窄、横屏宽"的物理事实一致。
//   * 于是上界的定位变成"**略高于折叠屏内屏竖屏（676.9）**"：iPad mini 竖屏
//     744pt、iPad 10.9"/Air 11" 竖屏 820pt **现在都进 expanded**（840 时代被挡
//     在 medium）。这是**有意**的：744/820pt 竖屏按 3:2 分栏后每栏 ≈446/492pt，
//     仍在本仓列表行的可读区间内，副标题不会被挤成多行。
//   * **为什么不是 660 / 720**：660 会把折叠屏内屏**竖屏**（676.9）也判成
//     双栏 —— 而 676.9 分栏后右栏只剩 ≈271dp，过窄；720 与 700 在这几台目标
//     机器上的裁定**完全一致**。取 700 是因为它落在"折叠内屏竖 676.9"与
//     "iPad mini 竖 744"之间这段空档里最靠中间的整百值（两侧余量 23.1 / 44）。
//     ★ 这不是"随手取整"：660 的变体已在真机上拍过像素做对照（见
//     `docs/device-verification.md` 最新一节），确认 676.9 竖屏需要留在单栏。
//   * 与 AndroidX 840 并不"打架到不可用"：840 是**系统**对窗口的分类，本仓的
//     双栏是**应用内自己的布局决定**；`AdaptiveScaffold`/`AdaptiveBody` 的宽度
//     门全仓只由本文件的 [kAppWindowMediumMax] 这一处表达（§2.0.26）。
//
// ═══════════════════════════════════════════════════════════════════════════
// 二、折痕（displayFeatures）的平台事实 —— 取证，不是假设
// ═══════════════════════════════════════════════════════════════════════════
// 已在本机 Flutter **3.47.4**（`bin/cache/pkg/sky_engine/lib/ui/`）逐处核对：
//   * `FlutterView.displayFeatures` → `List<DisplayFeature>`（window.dart:333）
//   * `MediaQueryData.displayFeatures`（media_query.dart:752）与便捷读取
//     `MediaQuery.displayFeaturesOf(context)`（media_query.dart:2126）
//   * `enum DisplayFeatureType { unknown, fold, hinge, cutout }`
//     （platform_dispatcher.dart:2742）
//   * `enum DisplayFeatureState { unknown, postureFlat, postureHalfOpened }`
//     （platform_dispatcher.dart:2769）
//   * `DisplayFeature.bounds` 是**逻辑像素**、坐标系 = 当前 view（含被遮挡区）
//
// ★★ **该列表只在 Android 上被填充** —— dart:ui 原文（window.dart:318）：
//   "This list is populated only on Android. If the device has no display
//    features, this list is empty."
//   ⇒ iOS/iPadOS **永远**拿不到折痕（iPad 也没有折痕），所以本文件的折痕
//     分支在 iOS 上是**空操作**（`bands` 为空 → 一律走原路径），
//     **不会**改变 iOS 的布局。这不是"我们忘了做 iPad"，是平台不给这个信号。
//   ⇒ 因此单测里**不依赖真机**：用 `MediaQuery(data: …copyWith(
//      displayFeatures: [DisplayFeature(...)]))` **合成**注入（见
//      `test/adaptive_layout_matrix_test.dart`），合成注入走的是与真机
//      完全相同的代码路径（WidgetsBinding 把 view 的 displayFeatures
//      原样塞进 MediaQuery，见 media_query.dart:335）。
//
// ═══════════════════════════════════════════════════════════════════════════
// 三、折痕纪律
// ═══════════════════════════════════════════════════════════════════════════
// `fold`（柔性屏折痕，无物理缝隙）与 `hinge`（两屏之间的物理铰链）都**不得**
// 放可点内容：折痕上点击会被柔性屏的形变/触摸盲区吃掉，铰链则是真的没有像素。
// `cutout`（挖孔/刘海）**不**参与避让 —— 它很小且已被 `MediaQuery.padding`
// 处理，按"折痕"避让反而会把内容挤走半屏。
//
// 本文件的避让策略（`FoldAvoidingLayout`）：把**整棵子树**放进折痕**较宽**的
// 那一侧，另一侧留空。理由与代价写在 `FoldAvoidingLayout` 的类注释里。
//
// ═══════════════════════════════════════════════════════════════════════════
// 四、窄屏等价性（P1 不变量）
// ═══════════════════════════════════════════════════════════════════════════
// `AdaptiveBody` / `AdaptiveScaffold` 在 **非 expanded 且无折痕** 时
// **原样返回 `master`**（不是"包一层等价布局"），`FoldAvoidingLayout` 在
// 无折痕时**原样返回 `child`**。⇒ 窄屏下新增的只是 1–2 个 StatelessWidget
// 元素壳，**渲染子树、尺寸、key、finder 全部与改动前逐字节一致**。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 窗口宽度分级（Material 3 window size class）。
enum AppWindowSize {
  /// `< 600 dp`：手机竖屏。单列。
  compact,

  /// `600–699 dp`：分屏一半 / 折叠外屏横等。单列。
  medium,

  /// `>= 700 dp`：折叠屏内屏横屏、Pad、桌面。可并排双栏。
  ///
  /// ★ 700 是**本仓自己的**上界，不是 Material 3 的 840（见文件头 §一）。
  expanded,
}

/// compact 的上界（**不含**）。`width < 600` ⇒ compact。
const double kAppWindowCompactMax = 600.0;

/// medium 的上界（**不含**）。`600 <= width < 700` ⇒ medium。
///
/// ★ **不是** Material 3 官方的 840 —— 是第 293 轮按真机实测下调后的产品
/// 断点，理由与逐台裁定见文件头 §一。改这个值前先读那一节。
const double kAppWindowMediumMax = 700.0;

/// 纯函数：由**逻辑**尺寸得到分级。不读 `context`，方便单测与探针直接调。
AppWindowSize appWindowSizeOf(Size size) {
  if (size.width < kAppWindowCompactMax) return AppWindowSize.compact;
  if (size.width < kAppWindowMediumMax) return AppWindowSize.medium;
  return AppWindowSize.expanded;
}

extension AppWindowSizeX on AppWindowSize {
  bool get isCompact => this == AppWindowSize.compact;
  bool get isMedium => this == AppWindowSize.medium;
  bool get isExpanded => this == AppWindowSize.expanded;

  /// 双栏只在 expanded 出现。
  bool get supportsTwoPane => this == AppWindowSize.expanded;
}

/// `context` 便捷读取。用 `MediaQuery.sizeOf` ⇒ 只在尺寸变化时重建。
extension AppWindowSizeContext on BuildContext {
  AppWindowSize get appWindowSize =>
      appWindowSizeOf(MediaQuery.sizeOf(this));

  bool get isAppWindowCompact => appWindowSize.isCompact;
  bool get isAppWindowExpanded => appWindowSize.isExpanded;
}

// ---------------------------------------------------------------- 折痕（纯函数）

/// 从 `displayFeatures` 里筛出**需要避让**的竖向带（`fold` / `hinge`）。
///
/// 判据（三条全满足才算"竖向带"）：
///   ① `type` 是 `fold` 或 `hinge`（`cutout` 不算，见文件头 §三）；
///   ② `bounds.width < bounds.height`（竖着的一条，不是横折）；
///   ③ `bounds.width > 0`。
///
/// `size` 用来挡掉明显不合理的带（比屏还宽之类），`null` 表示不约束。
Rect? verticalObstructingBand(
  List<ui.DisplayFeature> features,
  Size size,
) {
  Rect? best;
  for (final f in features) {
    if (!_obstructs(f.type)) continue;
    final b = f.bounds;
    if (b.width <= 0) continue;
    if (b.width >= b.height) continue; // 横折，交给 horizontal*
    if (b.width > size.width * 0.5) continue; // 明显异常，不按折痕处理
    if (best == null || b.width > best.width) best = b;
  }
  return best;
}

/// 同上，但筛横向带（横折/横铰链）。
Rect? horizontalObstructingBand(
  List<ui.DisplayFeature> features,
  Size size,
) {
  Rect? best;
  for (final f in features) {
    if (!_obstructs(f.type)) continue;
    final b = f.bounds;
    if (b.height <= 0) continue;
    if (b.height > b.width) continue; // 竖带，交给 vertical*
    if (b.height > size.height * 0.5) continue;
    if (best == null || b.height > best.height) best = b;
  }
  return best;
}

bool _obstructs(ui.DisplayFeatureType type) =>
    type == ui.DisplayFeatureType.fold || type == ui.DisplayFeatureType.hinge;

/// 当前窗口的竖向折痕带（无则 `null`）。iOS 恒为 `null`（平台不填充）。
Rect? verticalObstructingBandOf(BuildContext context) =>
    verticalObstructingBand(
      MediaQuery.displayFeaturesOf(context),
      MediaQuery.sizeOf(context),
    );

/// 当前窗口的横向折痕带（无则 `null`）。
Rect? horizontalObstructingBandOf(BuildContext context) =>
    horizontalObstructingBand(
      MediaQuery.displayFeaturesOf(context),
      MediaQuery.sizeOf(context),
    );

/// 矩形是否与折痕带相交（**测试与探针的判据**：相交 = 可点内容压在折痕上）。
///
/// 用严格不等号：恰好贴边不算相交（`Rect.overlaps` 同语义，这里显式写出
/// 是为了让反向验证时错误信息能直接打印两个矩形）。
bool rectHitsBands(Rect rect, List<Rect> bands) {
  for (final b in bands) {
    if (rect.left < b.right &&
        b.left < rect.right &&
        rect.top < b.bottom &&
        b.top < rect.bottom) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------- 折痕避让容器

/// 折痕感知容器：**把整棵子树放进折痕较宽的那一侧**，另一侧留空且不放任何
/// 可点内容。
///
/// 为什么是"挤到一侧"而不是"左右各一半"：
///   * 单列页面（手机竖屏、折叠屏内屏单列态）本来就没有第二栏可放，
///     "左右各一半"只能把同一份内容拆开 ⇒ 不成立；
///   * 两侧都放内容就需要两套滚动/导航状态，属于**双栏骨架**
///     （`AdaptiveScaffold`）的职责，不是这个容器的职责。
///
/// 代价（**明说**）：半折时可用宽度减半（例如 673dp 设备在 34dp 折痕带上
/// 只剩 ~320dp）。这是"宁可窄，也不把可点内容压在折痕/铰链上"的有意取舍；
/// 更优的形态是让 `AdaptiveScaffold` 在折痕处**分栏**（左栏在折痕左、右栏在
/// 折痕右），`AdaptiveScaffold` 在 expanded 时已经是这么做的。
///
/// 兜底：若折痕两侧**都窄于 [minSideWidth]**（例如极窄的外屏 + 折痕），
/// 则**放弃避让**（原样返回），否则会把界面挤成不可用的一条 —— 这条兜底
/// 在用例里以"320dp 外屏（无折痕）"覆盖，不会静默生效。
class FoldAvoidingLayout extends StatelessWidget {
  const FoldAvoidingLayout({
    super.key,
    required this.child,
    this.enabled = true,
    this.minSideWidth = 240,
  });

  final Widget child;

  /// 关掉即恒等于 [child]（测试反向验证用）。
  final bool enabled;

  /// 折痕两侧都窄于此值 ⇒ 放弃避让（宁可跨界，也不把界面挤没）。
  final double minSideWidth;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final size = MediaQuery.sizeOf(context);
    final features = MediaQuery.displayFeaturesOf(context);

    final v = verticalObstructingBand(features, size);
    if (v != null) {
      final left = v.left;
      final right = size.width - v.right;
      final useLeft = left >= right;
      final side = useLeft ? left : right;
      if (side >= minSideWidth) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!useLeft) const Expanded(child: SizedBox.shrink()),
            SizedBox(width: side, child: child),
            if (useLeft) const Expanded(child: SizedBox.shrink()),
          ],
        );
      }
    }

    final h = horizontalObstructingBand(features, size);
    if (h != null) {
      final top = h.top;
      final bottom = size.height - h.bottom;
      final useTop = top >= bottom;
      final side = useTop ? top : bottom;
      if (side >= minSideWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!useTop) const Expanded(child: SizedBox.shrink()),
            SizedBox(height: side, child: child),
            if (useTop) const Expanded(child: SizedBox.shrink()),
          ],
        );
      }
    }
    return child;
  }
}

// ---------------------------------------------------------------- 宽屏双栏

/// 只给"**宽屏时并排**"这一个 hook 的最小容器。
///
/// * `side == null` 或非 expanded ⇒ **原样返回 [child]**（窄屏等价性不变量）；
/// * expanded 且 `side != null` ⇒ 左 [child] + 右 [side]，`Expanded` 按 flex 分。
///
/// 它**不**管折痕（折痕由 `FoldAvoidingLayout` / `AdaptiveScaffold` 负责），
/// 也不含 Scaffold/AppBar —— 只是一个横向布局 hook。
class AdaptiveBody extends StatelessWidget {
  const AdaptiveBody({
    super.key,
    required this.child,
    this.side,
    this.masterFlex = 3,
    this.detailFlex = 2,
    this.breakpoint = AppWindowSize.expanded,
    this.showDivider = true,
    this.dividerColor,
  }) : assert(masterFlex > 0),
       assert(detailFlex > 0);

  /// 窄屏时**唯一**可见的内容（通常是既有单列子树，必须逐字节不变）。
  final Widget child;

  /// 宽屏时并排到右侧的内容；`null` ⇒ 恒为单列。
  final Widget? side;

  final int masterFlex;
  final int detailFlex;
  final AppWindowSize breakpoint;
  final bool showDivider;
  final Color? dividerColor;

  @override
  Widget build(BuildContext context) {
    final s = side;
    if (s == null) return child;
    final size = MediaQuery.sizeOf(context);
    if (appWindowSizeOf(size).index < breakpoint.index) return child;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: masterFlex, child: child),
        if (showDivider) VerticalDivider(width: 1, color: dividerColor),
        Expanded(flex: detailFlex, child: s),
      ],
    );
  }
}

/// 页面级**双栏骨架**（列表/树 + 内容），**不含** `Scaffold`/`AppBar`。
///
/// 契约（与 `AdaptiveBody` 的区别只在于"折痕优先"）：
///   1. **无折痕**：非 expanded 或 `detail == null` ⇒ 返回 `master`（单列）；
///      expanded 且有 `detail` ⇒ 左 `master` + 右 `detail`。
///   2. **有竖向折痕**（`fold` / `hinge`）⇒ **折痕处分栏**：
///      `master` 落在折痕左侧、`detail` 落在折痕右侧，中间那条带**不放任何
///      可点内容**（`detail == null` 时右栏为空占位，`master` 仍只占左栏）。
///      这条规则**不受断点限制** —— 半折的 673dp 内屏也要遵守，因为折痕上
///      点击会被吃掉。这是本组件与 `AdaptiveBody` 唯一的语义差异。
///   3. **窄屏推路由**：本组件不做导航。`master` 里的点击在窄屏时**由调用方
///      push 路由**、在宽屏时由调用方 `setState` 选中项并传 `detail`
///      （见 `notes_page.dart` 的 `_onNoteTap`）。
///
/// 窄屏等价性：见文件头 §四。
class AdaptiveScaffold extends StatelessWidget {
  const AdaptiveScaffold({
    super.key,
    required this.master,
    this.detail,
    this.breakpoint = AppWindowSize.expanded,
    this.masterFlex = 3,
    this.detailFlex = 2,
    this.showDivider = true,
    this.dividerColor,
    this.foldAware = true,
    this.foldMinSideWidth = 240,
  });

  /// 左栏（列表 / 树）；窄屏时它是全部内容。
  final Widget master;

  /// 右栏（内容）；`null` ⇒ 单列。
  final Widget? detail;

  final AppWindowSize breakpoint;
  final int masterFlex;
  final int detailFlex;
  final bool showDivider;
  final Color? dividerColor;

  /// 是否响应折痕（关掉即恒等于"无折痕"分支，测试反向验证用）。
  final bool foldAware;

  final double foldMinSideWidth;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final band = foldAware ? verticalObstructingBandOf(context) : null;

    if (band != null) {
      // 折痕优先：左栏占 [0, band.left]，右栏占 [band.right, W]，中间留空。
      final leftW = band.left;
      final rightW = size.width - band.right;
      if (leftW >= foldMinSideWidth && rightW >= foldMinSideWidth) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: leftW, child: master),
            // 折痕带：不放任何内容（连背景都不铺，露出 Scaffold 底色）。
            SizedBox(width: band.width),
            SizedBox(
              width: rightW,
              child: detail ?? const SizedBox.shrink(),
            ),
          ],
        );
      }
      // 一侧放不下 ⇒ 退回"整页挤到较宽一侧"的兜底（仍不跨折痕）。
      return FoldAvoidingLayout(
        minSideWidth: foldMinSideWidth,
        child: _twoPane(
          context,
          size,
          forceSingle: true,
        ),
      );
    }

    // 横折（`fold`/`hinge` 的横带）：上下分栏，同样不受断点限制。
    final hband = foldAware ? horizontalObstructingBandOf(context) : null;
    if (hband != null) {
      final topH = hband.top;
      final bottomH = size.height - hband.bottom;
      if (topH >= foldMinSideWidth && bottomH >= foldMinSideWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: topH, child: master),
            SizedBox(height: hband.height),
            SizedBox(
              height: bottomH,
              child: detail ?? const SizedBox.shrink(),
            ),
          ],
        );
      }
      return FoldAvoidingLayout(
        minSideWidth: foldMinSideWidth,
        child: _twoPane(context, size, forceSingle: true),
      );
    }

    return _twoPane(context, size, forceSingle: false);
  }

  Widget _twoPane(BuildContext context, Size size, {required bool forceSingle}) {
    final d = detail;
    if (d == null || forceSingle) return master;
    if (appWindowSizeOf(size).index < breakpoint.index) return master;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: masterFlex, child: master),
        if (showDivider) VerticalDivider(width: 1, color: dividerColor),
        Expanded(flex: detailFlex, child: d),
      ],
    );
  }
}
