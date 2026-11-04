import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// App 自己声明的**系统栏口径**（DA102，第 455 轮）。
///
/// ## 为什么要有这个文件
///
/// 第 454 轮真机取证（`docs/android-ui-audit-r454.md`）查明：本仓**从来没有人
/// 声明过状态栏底色** —— 全仓 `grep SystemUiOverlayStyle` **0 命中**，
/// `android/app/src/main/res/values{,-night}/styles.xml` 也是 Flutter 模板原样
/// （没有 `android:statusBarColor`）。于是"状态栏是什么颜色"只有两个来源：
///
/// 1. `MaterialApp` 里的 Material **`AppBar`**：它按自己的亮度**自动发布**
///    `SystemUiOverlayStyle`（M3 默认 `statusBarColor: transparent`）；
/// 2. 都没有时，ROM 用它自己主题的默认值 —— 本机是 `#40000000`（**25% 黑**）
///    ⇒ 浅色页面顶部一条**灰带**（真机读数 `#b3–#b5`，`0.75×F6≈B9`）。
///
/// 而且来源 1 写的是**窗口属性、会残留**：过一遍带 AppBar 的页，值就变成透明，
/// 直到窗口被重建（冷启动）才回到灰带 —— 这就是"同一个页面有时有灰带、
/// 有时没有"的全部原因；没有 AppBar 的外壳五个 Tab / 连接页 / 登录页
/// **永远轮不到**来源 1。
///
/// ## 修法
///
/// 把 AppBar **已经发布的那一套**提到树根（[SystemBarsScope]），
/// 让没有 AppBar 的页也拿到**同一个值**。本文件逐字对齐
/// `AppBar._systemOverlayStyleForBrightness` 的 M3 口径
/// （`packages/flutter/lib/src/material/app_bar.dart` 的
/// `_systemOverlayStyleForBrightness`：取 `SystemUiOverlayStyle.light/.dark`
/// 的图标明暗 + `statusBarColor` 透明）⇒ **有 AppBar 的页行为一字不变**
/// （同一个值，谁发布都一样；且 AppBar 画得更晚，永远盖得住根上的值）。
///
/// ## ★ 只管状态栏，**不动导航栏**
///
/// M3 `AppBar` 发布的样式里 `systemNavigationBarColor` 是 `null`（它根本不碰
/// 导航栏）⇒ 跟着它走才是"口径一致"；另起一套导航栏颜色反而会和 AppBar 页
/// 打架（同一个窗口会出现两种导航栏）。所以这里也一个导航栏字段都不设。
SystemUiOverlayStyle synhubSystemBarStyle(Brightness brightness) {
  final base = brightness == Brightness.dark
      ? SystemUiOverlayStyle.light
      : SystemUiOverlayStyle.dark;
  return SystemUiOverlayStyle(
    // M3 的口径：状态栏本身透明，颜色由页面内容顶上来
    statusBarColor: const Color(0x00000000),
    // iOS 侧语义（内容浅色 ⇒ 图标深色），与 Android 的两个字段同源
    statusBarBrightness: base.statusBarBrightness,
    statusBarIconBrightness: base.statusBarIconBrightness,
    // AOSP 的状态栏对比度强制默认就是 false；显式关掉可以挡住"个别 ROM 默认开"
    // 时在透明状态栏上再画一层 scrim（本机第 454 轮实测透明、没有被强制）。
    systemStatusBarContrastEnforced: false,
  );
}

/// 把 [synhubSystemBarStyle] 挂到**整棵树**上（挂在 `MaterialApp.builder`）。
///
/// 两条腿缺一不可：
///
/// * `AnnotatedRegion` —— 与 `AppBar` 走**同一套机制**（绘制时把样式交给引擎）。
///   更深、画得更晚的 `AppBar` 会盖住它 ⇒ "有 AppBar 的页"仍旧是 AppBar 说了算，
///   本组件对它们**零影响**；
/// * 显式 `SystemChrome.setSystemUIOverlayStyle` —— 亮度档位变化时立刻下发一次，
///   不依赖"是否恰好重绘"，冷启动第一帧、以及从 AppBar 页返回时都稳。
class SystemBarsScope extends StatefulWidget {
  const SystemBarsScope({super.key, required this.child});

  final Widget child;

  @override
  State<SystemBarsScope> createState() => _SystemBarsScopeState();
}

class _SystemBarsScopeState extends State<SystemBarsScope> {
  /// 上次**显式下发**过的亮度档位（只在变化时发，不每帧发平台消息）。
  Brightness? _published;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 主题三档（跟随系统 / 浅 / 深）随时会变 ⇒ 这里必须跟着重发，
    // 否则"App 选深色而系统是浅色"时状态栏图标会是深色（在深色页上看不见）。
    final brightness = Theme.of(context).brightness;
    if (_published == brightness) return;
    _published = brightness;
    SystemChrome.setSystemUIOverlayStyle(synhubSystemBarStyle(brightness));
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: synhubSystemBarStyle(Theme.of(context).brightness),
      child: widget.child,
    );
  }
}
