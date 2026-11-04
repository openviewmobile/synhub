import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import 'app_shapes.dart';
import 'app_tokens.dart';
import 'app_typography.dart';

/// 应用主题（HUD 设计语言）。
///
/// 主色策略：**Material You 动态取色优先**，拿不到（低版本 Android / 桌面 /
/// 测试环境）时回退到原版 Synology 蓝 `#1B69C1` 的种子配色。
/// 设计系统不依赖"某个固定色相"，所以换主题色不会破坏观感 —— 识别度来自
/// 玻璃、切角、等宽遥测字与动效。
abstract final class AppTheme {
  /// 回退种子色：原版 Synology 蓝
  static const Color seed = Color(0xFF1B69C1);

  /// [dynamic] 由 `DynamicColorBuilder` 传入（Material You 的亮/暗方案）。
  static ThemeData light({ColorScheme? dynamic}) => _build(
    dynamic ?? ColorScheme.fromSeed(seedColor: seed),
    Brightness.light,
    // ★ 只有"真拿到了动态方案"才算开启动态取色；关掉时是品牌种子色，
    //   色相层不挂 ⇒ 与 154 张设计稿逐字节一致。
    dynamicHue: dynamic != null,
  );

  static ThemeData dark({ColorScheme? dynamic}) => _build(
    dynamic ??
        ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
    Brightness.dark,
    dynamicHue: dynamic != null,
  );

  static ThemeData _build(
    ColorScheme rawScheme,
    Brightness brightness, {
    bool dynamicHue = false,
  }) {
    final dp = brightness == Brightness.light
        ? DesignPalette.light
        : DesignPalette.dark;
    // ★ r518（DA160）：**中性色与语义色一律归设计令牌**，只有"色相"留给
    // 动态取色（Material You）。原因：features 里还有 332 处 `colorScheme.*`
    // —— `error` 87 处、`surfaceContainerHighest` 60 处、`outline` 34 处 ——
    // 这些在开着动态取色的机器上全是壁纸算出来的，于是"错误红/分隔线/次级底"
    // 三样最基本的东西每个用户都不一样，与 154 张设计稿对不上。
    // 主色/色相仍然跟壁纸走（那是"个性化"，不是"设计语言"）。
    // ★ 第 243 轮（`DA187`，用户裁定 ③）：**没拿到 DynamicColorBuilder 的方案时，
    //   主色也要归令牌**。以前 `scheme.primary` 走的是种子蓝 `#1B69C1` 派生色，
    //   而 `DesignPalette.primary` 是设计令牌的青蓝 —— 于是同一屏出现**两种主色**
    //   （真机 Downloads 筛选条「All」是亮蓝 `(42,77,208)`，页面其余是青蓝 `(51,99,131)`）。
    //   开着动态取色时两边都跟壁纸走（这才是个性化）；**关掉时两边都必须是令牌色**。
    final themed = dynamicHue
        ? rawScheme
        : rawScheme.copyWith(
            primary: dp.primary,
            onPrimary: dp.onPrimary,
            primaryContainer: dp.primarySoft,
            onPrimaryContainer: dp.primary,
            secondary: dp.primary,
            onSecondary: dp.onPrimary,
            secondaryContainer: dp.primarySoft,
            onSecondaryContainer: dp.primary,
            tertiary: dp.accent,
            onTertiary: dp.onPrimary,
          );
    final scheme = themed.copyWith(
      surface: dp.surface,
      onSurface: dp.text,
      error: dp.danger,
      onError: dp.onPrimary,
      outline: dp.line,
      outlineVariant: dp.line,
      surfaceContainerHighest: dp.surface2,
      surfaceContainerHigh: dp.surface2,
      onSurfaceVariant: dp.muted,
    );
    // ★ 第 232 轮（用户裁定 ③）：**Material 组件读的是 `scheme`，不是我们的令牌**
    //   —— `ChoiceChip` 的选中文字就是 `scheme.primary` on `scheme.primaryContainer`。
    //   真机实测亮色 4.42:1、暗色 4.36:1（都 < AA）。这里对 scheme 也做同样的钳制，
    //   否则"令牌达标"只是纸面达标。
    final safePrimary = DesignPalette.ensureContrast(
      DesignPalette.ensureContrast(
        scheme.primary,
        scheme.primaryContainer,
        brightness: brightness,
      ),
      scheme.surface,
      brightness: brightness,
    );
    final scheme2 = scheme.copyWith(primary: safePrimary);
    final hud = brightness == Brightness.light
        ? HudTokens.light(scheme2)
        : HudTokens.dark(scheme2);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme2,
      brightness: brightness,
    );
    // ⚠️ `AppType.textTheme()` 刻意不带颜色（各组件用 `hud.*` 自己上色），
    // 但**不能是 null**：`ThemeData` 的默认文字样式会带着这个 null 传下去，
    // 任何 `style.color!` 的第三方组件都会炸（真机：flutter_quill 的
    // `DefaultStyles.getInstance` → `baseStyle.color!` → 整个编辑区变成
    // 一块灰 ErrorBox）。这里统一补上 onSurface，组件显式指定的颜色仍然优先。
    final text = AppType.textTheme().apply(
      bodyColor: scheme2.onSurface,
      displayColor: scheme2.onSurface,
    );

    return base.copyWith(
      textTheme: text,
      primaryTextTheme: text,
      // 页面底色用科幻层的 `deep`（比 surface 更深一点），让玻璃/网格有层次
      scaffoldBackgroundColor: hud.deep,
      extensions: <ThemeExtension<dynamic>>[
        hud,
        // 动态取色：只借壁纸的**色相**（primary/primarySoft/accent），
        // 中性色与语义色仍在上面被令牌钉死（DA160）。
        if (dynamicHue)
          HudDynamicHue(
            primary: rawScheme.primary,
            primarySoft: rawScheme.primaryContainer,
            accent: rawScheme.tertiary,
            onPrimary: rawScheme.onPrimary,
          ),
      ],

      // ---------------------------------------------------------------- 铬
      // ★ r505：**弹层菜单（`PopupMenuButton`）此前完全没有主题** ——
      //   Material 默认给 `surfaceContainer` 色调 + 4px 圆角，亮色下是一块
      //   灰紫底（真机像素 `(239,240,244)`），与设计语言的白卡/14px 圆角/
      //   `line` 描边不是一套。这里统一：设计令牌的 surface + 1px line + 14px。
      popupMenuTheme: PopupMenuThemeData(
        color: dp.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: dp.line),
        ),
        textStyle: text.bodyMedium?.copyWith(color: dp.text),
        labelTextStyle: WidgetStatePropertyAll(
          text.bodyMedium?.copyWith(color: dp.text),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        // ★ DA189：原来这里是 `hud.glass`（surface@62–74%）——
        //   亮色下页头比页面底色**更白一档**（真机实测 (249,251,251) vs 页面
        //   (234,238,244)），看着像多了一条白卡片；设计稿里页头与页面**同底色**，
        //   只有一条 `line` 细线分隔。
        backgroundColor: dp.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 4,
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
        // ★ r493：**全 App 的 AppBar 都不再挂"仪表刻度"**。
        //
        // 原来这里是 `HudBarBorder`（主色渐隐底线 + 26 根刻度，挂
        // `AppBarTheme.shape` 上 ⇒ 一改全 App 生效）。它与新设计语言打架：
        // 设计稿的页头只有标题与动作，没有刻度尺。现在只留一条 1px 细线。
        //
        // 想恢复旧观感：把下面这行换回 `HudBarBorder(...)`（类还在）。
        //
        // ★★ DA189：只写 `BorderSide(width: 1, 不给 color)` ⇒ Flutter 默认
        //   `Color(0xFF000000)` ⇒ 全 App 页头下面是一条**纯黑色** 1px 线
        //   （真机像素实测 (0,0,0)，对白底 21.00:1）。设计稿的页头分隔线是
        //   `line` 令牌（亮色 #DFE6EF / 暗色同档），所以必须显式给色。
        shape: Border(bottom: BorderSide(width: 1, color: dp.line)),
      ),

      // ★ r517（DA159）：**应用级**主题也要钉 FAB 配色。`notes_page` 这类
      // 直接用 `Scaffold` 的页面不经过 `DesignScaffold` 的 `DesignTheme`，
      // 缺这一项就落回 M3 的 `primaryContainer/onPrimaryContainer`，
      // 而本机开着「动态取色」⇒ 亮色实测底 (216,226,252)、字 (45,70,115)，
      // 与设计稿的「`primary` 实心 + `onPrimary` 图标」不是一个东西。
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: dp.primary,
        foregroundColor: dp.onPrimary,
      ),
      // 底部面板：大圆角 + 玻璃 + 拖拽手柄（统一在 AppSheet 里也用这套）
      // ★ 第 233 轮（`DA177`，用户裁定 ③「亮色与暗色同等精细」）：
      //   弹层底色原本是 `glassStrong`（surface @93%/88%）—— 亮色下**下层文字会
      //   透上来**（真机像素：主题选择弹层能看见"Set manually to on…""Messages & media"
      //   这些被盖住的字），读起来像渲染故障，而不是"玻璃感"。
      //   弹层是**信息层**，改成不透明 `surface`；玻璃质感留给真正做了模糊的地方。
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surface,
        showDragHandle: true,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Radii.sheet),
          ),
        ),
        clipBehavior: Clip.antiAlias,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: hud.glassStrong,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.pane),
        ),
        titleTextStyle: text.titleMedium,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        insetPadding: const EdgeInsets.all(Gap.lg),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.pane),
        ),
      ),

      // ---------------------------------------------------------------- 列表
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.pane),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.md),
        minVerticalPadding: Gap.md,
        iconColor: scheme.onSurfaceVariant,
      ),
      dividerTheme: DividerThemeData(
        // 老式全宽分割线是"土"的主要来源之一：改成极淡、内缩的细线
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        thickness: 0.6,
        space: 0.6,
      ),

      cardTheme: CardThemeData(
        color: hud.glass,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.pane),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        side: BorderSide(color: hud.edge, width: 0.6),
        labelStyle: text.labelMedium,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 0),
      ),

      // ---------------------------------------------------------------- 表单
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pane),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pane),
          borderSide: BorderSide(color: hud.edge, width: 0.6),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pane),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pane),
          borderSide: BorderSide(color: scheme.error, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Gap.lg,
          vertical: Gap.md,
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: const ChamferBorder(cut: Radii.cut, side: BorderSide.none),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: hud.edge),
          shape: const StadiumBorder(),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: text.labelLarge,
          minimumSize: const Size(0, 40),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          highlightColor: scheme.primary.withValues(alpha: 0.08),
        ),
      ),

      // ---------------------------------------------------------------- 导航
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: hud.glass,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.label,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: dp.primary,
        linearTrackColor: dp.primary.withValues(alpha: 0.16),
        circularTrackColor: dp.primary.withValues(alpha: 0.16),
      ),

      // ---------------------------------------------------------------- 控件家族
      // ★ r506：**按"组件家族"对表**补齐（r505 是漏了 `popupMenuTheme`）。
      //   这些控件此前全部走 Material You 的种子色（与设计令牌是两套蓝），
      //   真机上"开关/滑杆/分段按钮"的蓝比设计令牌更艳，暗色下尤其明显。
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? dp.onPrimary
              : dp.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? dp.primary
              : dp.line,
        ),
        trackOutlineColor: WidgetStatePropertyAll(dp.line),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? dp.primary
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(dp.onPrimary),
        side: BorderSide(color: dp.dim, width: 1.4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? dp.primary
              : dp.dim,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: dp.primary,
        inactiveTrackColor: dp.line,
        thumbColor: dp.primary,
        overlayColor: dp.primary.withValues(alpha: 0.12),
        valueIndicatorColor: dp.primary,
        valueIndicatorTextStyle: text.labelLarge?.copyWith(
          color: dp.onPrimary,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? dp.primarySoft
                : dp.surface,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? dp.primary
                : dp.muted,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: dp.line)),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
          ),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dp.surface,
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          border: Border.all(color: dp.line),
        ),
        textStyle: text.bodySmall?.copyWith(color: dp.text),
      ),

      splashFactory: InkSparkle.splashFactory,
    );
  }
}

/// ★★★ 放进 `Row`（或任何**横向无界**父节点）的实心/描边按钮专用 style。
///
/// **为什么必须有它**：全局主题把 `FilledButton`/`OutlinedButton` 的
/// `minimumSize` 设成 `Size.fromHeight(48)`（= `Size(double.infinity, 48)`）。
/// `Row` 布局**非 flex 子项**时传下去的是 `maxWidth: infinity` ⇒ 按钮自己的
/// `minWidth: infinity` 与无限上界相乘 ⇒ 框架断言
/// `BoxConstraints forces an infinite width`（第 r131 轮 macOS 走查在
/// `download_bt_search_page` 的 `ds-bt-submit` 上真拍到，并按
/// `RenderBox was not laid out: …` 连锁报错）。
///
/// **规矩**：按钮要进 `Row`，就带 `style: InlineButtonStyle.filled`（或 `.outlined`）。
/// 静态守卫 `test/inline_button_row_guard_test.dart` 会扫全仓，漏一个就红。
/// 需要"占满整行"的按钮请放进 `Column`（`crossAxisAlignment: stretch`）或
/// `SizedBox(width: double.infinity)`，**不要**靠主题的 `Size.fromHeight`。
abstract final class InlineButtonStyle {
  /// 实心按钮：内容宽 + 48 最小高（与主题视觉一致，只是宽度不再无限）。
  static final ButtonStyle filled = FilledButton.styleFrom(
    minimumSize: const Size(0, 48),
    shape: const ChamferBorder(cut: Radii.cut, side: BorderSide.none),
  );

  /// 描边按钮：同 [filled]，形状用主题里的 `StadiumBorder`。
  static final ButtonStyle outlined = OutlinedButton.styleFrom(
    minimumSize: const Size(0, 48),
    shape: const StadiumBorder(),
  );

  /// 文字按钮本来就是有限宽度（主题 `Size(0, 40)`），这里只为语义统一。
  static final ButtonStyle text = TextButton.styleFrom(
    minimumSize: const Size(0, 40),
  );
}
