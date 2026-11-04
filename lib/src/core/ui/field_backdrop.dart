// 全屏底色层 —— **r492 起科幻底纹退役，只剩底色**。
//
// 设计稿（`design/spec/*.json`，154 屏）的页面底色一律是平的：`bg` + 卡片。
// 透视网格 / 星尘 / 扫描线 / 辉光属于上一版 HUD 语言，与新设计同屏会互相打架
// （真机 r491 Files 页：行卡已是新圆角卡，底下还压着网格）。
//
// 所以这里保留**组件名与全部参数**（74 处调用点不必同时改），只保留两件事：
//   1. `deep` 底色（保证英雄页/聊天页的对比度基线不变）；
//   2. 一层原生 `Material`（旧实现为了不在 `ColoredBox` 与 `ListTile` 之间
//      丢水波纹，本来就垫了这层；保留它可以继续避免
//      "ListTile background color or ink splashes may be invisible"）。
//
// 旧的绘制类（网格/星尘/扫描线/面纱）已随轮次删除；需要恢复时从
// 备份 `/tmp/field_backdrop.r492.bak` 取回。动效时钟订阅仍然保留
// （`test/ambient_clock_test.dart` ④⑤ 钉的就是"可见页面占一个订阅位、
// 不可见页面不占"，与画什么无关）。
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'ambient_clock.dart';

class FieldBackdrop extends StatefulWidget {
  const FieldBackdrop({
    super.key,
    required this.child,
    this.enabled = true,
    this.showGrid = true,
    this.showParticles = true,
    this.showScanlines = true,
    this.particles = 40,
    this.horizon = 0.68,
    this.intensity = 1,
  });

  final Widget child;

  /// 总开关（关掉就是纯 `deep` 底色）
  final bool enabled;
  final bool showGrid;
  final bool showParticles;
  final bool showScanlines;
  final int particles;

  /// 地平线位置（0=顶部，1=底部）
  final double horizon;

  /// 强度倍率（0~1.4）
  final double intensity;

  @override
  State<FieldBackdrop> createState() => _FieldBackdropState();
}

class _FieldBackdropState extends State<FieldBackdrop>
    with AmbientAnimation<FieldBackdrop> {
  // ★ r287：帧源换成全应用共享的常驻动效时钟（见 `ambient_clock.dart`）。
  //   这里**不再**持有 `AnimationController..repeat()`：后者每个 vsync 都排帧，
  //   实测让静止的连接页烧掉 35–55% CPU。
  @override
  Duration get ambientPeriod => const Duration(seconds: 24);

  @override
  void initState() {
    super.initState();
    AppEffects.reducedMotion.addListener(_sync);
  }

  void _sync() {
    if (!mounted) return;
    syncAmbient();
    if (!AppEffects.ambientAllowed) ambientPhase.value = 0;
    setState(() {});
  }

  @override
  void dispose() {
    AppEffects.reducedMotion.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTokens.of(context);
    // ★ r132（iOS 逐屏像素）：本组件的 `ColoredBox(hud.deep)` 是"带底色的
    //   中间层"，而 `ListTile` 要求**水波纹/底色画在最近的 `Material`** 上 ——
    //   中间夹了带色 `ColoredBox` 时 Flutter 每帧抛
    //   `ListTile background color or ink splashes may be invisible`
    //   （debug 整屏报错；release 表现=点行没有任何反馈）。
    //   本仓已在 `drive_tasks_page` / `file_mount_page` / `file_offline_page` /
    //   `file_pages` / `webdav_page` / `drive_browse_view` **逐页**补过一次，
    //   但 iOS 逐屏走查仍然一屏几十次 ⇒ 根因在**这里**，收口修一次。
    //   `textStyle` 显式传当前 `DefaultTextStyle`，保证插入 Material 不改变任何
    //   文字的继承样式（Material 默认会塞 `textTheme.bodyMedium`）。
    final child = Material(
      type: MaterialType.transparency,
      textStyle: DefaultTextStyle.of(context).style,
      child: widget.child,
    );
    // ★★★ r492：**科幻底纹退役**。
    //
    // 设计稿（`design/spec/*.json`，154 屏）里所有页面的底色都是**平的**：
    // 只有 `bg` + 卡片。透视网格 / 星尘 / 扫描线是上一版 HUD 语言，
    // 和新设计放一起会互相打架（真机 r491 Files 页：行卡已经是新圆角卡，
    // 底下还压着网格 —— 两种语言同屏）。
    //
    // 因此这里**只保留底色这一件事**，装饰层一律不再绘制：
    //   * `enabled` / `showGrid` / `showParticles` / `showScanlines` /
    //     `particles` / `horizon` / `intensity` 全部变成**兼容参数**（保留签名，
    //     免得 41 个调用点同时炸），语义 = "要哪些装饰" → 现在都不画；
    //   * 调用点可以原样留着，后续逐模块连包裹一起删。
    //
    // 想恢复旧观感：把下面这个 `return` 换回 `Stack(...)`（旧实现的绘制类都还在，
    // 只是不再被调用；`flutter analyze` 会提示它们未使用 —— 那是预期的）。
    return ColoredBox(color: hud.deep, child: child);
  }
}

/// 带"深空座舱"底的全屏页面壳。
///
/// 用法与 `Scaffold` 一致（只暴露常用参数）；底子是 [FieldBackdrop]，
/// 所以页面自己不要再铺实色背景（Scaffold 的背景被设成透明）。
/// 需要"纯色、不要网格"的页面（例如需要极致性能的设置页）传 `field: false`。
class HudScaffold extends StatelessWidget {
  const HudScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.bottomSheet,
    this.drawer,
    this.field = true,
    this.intensity = 0.6,
    this.particles = 20,
    this.showGrid = true,
    this.showScanlines = true,
    this.resizeToAvoidBottomInset,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final Widget? bottomSheet;
  final Widget? drawer;
  final bool field;
  final double intensity;
  final int particles;
  final bool showGrid;
  final bool showScanlines;
  final bool? resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    // ★ r495：`HudScaffold` 自己把底色铺上。
    //   以前是"外面裹一层 FieldBackdrop"，r495 把所有 `FieldBackdrop(...)` 调用点
    //   都拆掉之后，这里必须自己补回来 —— 否则 `Scaffold` 是
    //   `backgroundColor: Colors.transparent` 且**没有任何底**，真机上会露黑底
    //   （`backdrop_legibility_test` 的亮色分区亮度报告当场量到 L=0.000）。
    return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: appBar,
        body: FieldBackdrop(enabled: field, child: body),
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: bottomNavigationBar,
        bottomSheet: bottomSheet,
        drawer: drawer,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      );
  }
}
