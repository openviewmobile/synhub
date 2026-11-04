import 'package:flutter/material.dart';

import '../design_palette.dart';

/// 设计系统积木（真源：`design/spec/*.json` 与 `design/tokens.py`）。
///
/// 这一层只做**视觉**：几何、字号、颜色、留白与设计稿一一对应；
/// 业务（点击后干什么、权限门控、i18n）仍由各页面自己决定。
/// 行高 62 / 图标块 40 / 圆角 11 / 标题 13-600 / 副标题 11.5 —— 都来自 spec。
class DesignScope extends StatelessWidget {
  const DesignScope({super.key, required this.child, this.dark});

  final Widget child;

  /// null = 跟随系统主题
  final bool? dark;

  @override
  Widget build(BuildContext context) {
    final bool isDark = dark ?? Theme.of(context).brightness == Brightness.dark;
    final DesignPalette p = isDark ? DesignPalette.dark : DesignPalette.light;
    return Theme(
      data: DesignTheme.of(p, isDark ? Brightness.dark : Brightness.light),
      child: child,
    );
  }
}

/// 页面骨架：底色 `phone`、顶栏 15-600、无阴影。
class DesignScaffold extends StatelessWidget {
  const DesignScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.bottomSheet,
    this.drawer,
    this.resizeToAvoidBottomInset,
    // 下面四个只为**兼容 HudScaffold 的调用签名**：设计稿没有 HUD 底板/网格/扫描线，
    // 传进来也一律忽略（逐页替换时不必改调用点）。
    this.field = false,
    this.intensity = 0,
    this.particles = 0,
    this.showGrid = false,
    this.showScanlines = false,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final Widget? bottomSheet;
  final Widget? drawer;
  final bool? resizeToAvoidBottomInset;
  final bool field;
  final double intensity;
  final int particles;
  final bool showGrid;
  final bool showScanlines;

  @override
  Widget build(BuildContext context) {
    final DesignPalette p = DesignPalette.of(context);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    // ★ r632（**DA214**）：内层主题必须把父级的**色相层**一起带下去。
    //   `DesignTheme.of(p, …)` 是全新 `ThemeData`，`copyWith` 不传 `extensions`
    //   ⇒ 内层 `Theme.of(context).extension<HudDynamicHue>()` 为 null。后果是真机
    //   上一个页面里**两把尺子给出两个主色**：读 `colorScheme.primary` 的地方是
    //   壁纸色相（音乐单曲页的播放键，实测深青 `(51,99,131)`），读
    //   `DesignPalette.of(context).primary` 的地方退回常量蓝（电台页/弹层，
    //   实测 `(42,77,208)`）。同一套 App 看着像两套主题。
    final HudDynamicHue? hue = Theme.of(context).extension<HudDynamicHue>();
    return Theme(
      data: DesignTheme.of(p, isDark ? Brightness.dark : Brightness.light)
          .copyWith(
            // 只带色相层：中性色/语义色仍然由 `DesignTheme.of` 按令牌钉死，
            // 别的扩展（如 HUD 的 `HudTokens`）不进设计壳，保持原有边界。
            extensions: <ThemeExtension<dynamic>>[if (hue != null) hue],
            // 顶栏必须是实色 `phone`：HUD 主题给的是半透明玻璃，
            // 换页时会把上一页的网格底纹透出来（真机第一次就是这样）。
            // 仍在用 Material `Card` 的老页面（如 OEM 保活）也要落成设计卡片：
            // 否则卡片底色 = 页面底色，在真机上根本看不出"这是一张卡"。
            cardTheme: CardThemeData(
              color: p.surface,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
                side: BorderSide(color: p.line),
              ),
            ),
            appBarTheme: AppBarTheme(
              backgroundColor: p.phone,
              surfaceTintColor: Colors.transparent,
              foregroundColor: p.text,
              elevation: 0,
              titleTextStyle: TextStyle(
                fontSize: DesignType.titleMediumSize,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
              iconTheme: IconThemeData(color: p.text),
            ),
            // ★ r517（DA159）：FAB 此前**完全没有主题** ⇒ 走 M3 默认的
            // `primaryContainer / onPrimaryContainer`，而本机开着「动态取色」，
            // 那两个色是壁纸算出来的：亮色实测底 `(216,226,252)`、字 `(45,70,115)`，
            // 与设计稿的「`primary` 实心 + `onPrimary` 图标」不是一个东西。
            // 设计稿的 FAB 只有一种配色，主题里钉死。
            floatingActionButtonTheme: FloatingActionButtonThemeData(
              backgroundColor: p.primary,
              foregroundColor: p.onPrimary,
            ),
          ),
      child: Scaffold(
        backgroundColor: p.phone,
        appBar: appBar,
        body: body,
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: bottomNavigationBar,
        bottomSheet: bottomSheet,
        drawer: drawer,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      ),
    );
  }
}

/// 分组标题（设计稿：12-600、`muted`、上 20 / 下 6）。
class DesignSectionHeader extends StatelessWidget {
  const DesignSectionHeader(
    this.text, {
    super.key,
    this.count,
    this.collapsed,
    this.onToggle,
  });

  final String text;

  /// 右侧计数（`null` = 不显示）
  final int? count;

  /// 分组折叠态；`null` = 这一组没有折叠箭头
  final bool? collapsed;

  /// 点整行折叠/展开
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final DesignPalette p = DesignPalette.of(context);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Row(
        children: <Widget>[
          if (collapsed != null) ...<Widget>[
            Icon(
              collapsed! ? Icons.expand_more : Icons.expand_less,
              size: 16,
              color: p.dim,
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: DesignType.titleSmallSize,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
          ),
          if (count != null) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              '$count',
              style: TextStyle(
                fontSize: DesignType.labelSmallSize,
                color: p.dim,
              ),
            ),
          ],
        ],
      ),
    );
    if (onToggle == null) return row;
    return InkWell(onTap: onToggle, child: row);
  }
}

/// 行卡外壳 —— **设计语言里"一行"的唯一定义**。
///
/// `DesignRowTile`、文件行、聊天行、以及任何要"长得像一行"的自定义行
/// 都应该套这个壳，否则同屏会出现两种圆角/两种内外边距（r492 之前的实况）。
class DesignRowShell extends StatelessWidget {
  const DesignRowShell({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.dense = false,
    this.selected = false,
    this.contentPadding,
    this.tileColor,
    this.radius = 13,
    this.borderWidth,
  });

  final Widget child;
  final GestureTapCallback? onTap;
  final GestureLongPressCallback? onLongPress;

  final bool enabled;
  final bool dense;
  final bool selected;
  final EdgeInsetsGeometry? contentPadding;
  final Color? tileColor;
  final double radius;

  /// 边框宽度。`null` = 原来那套（选中 1.5 / 未选中 1）—— 它**参与布局**，
  /// 所以选中态一改整行差 1dp。需要"行高绝对不跳"的列表（聊天侧栏，未读数
  /// 每秒都在变）传固定值，几何就与选中态无关。
  final double? borderWidth;

  @override
  Widget build(BuildContext context) {
    final DesignPalette p = DesignPalette.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 2 : 5),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Material(
          // DA199：选中底色要保证行内每种灰都读得到（动态取色会把它染得太浅）。
          color:
              tileColor ??
              (selected ? DesignPalette.selectedRowFill(p) : p.surface),
          borderRadius: BorderRadius.circular(radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            onLongPress: enabled ? onLongPress : null,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: selected ? p.primary : p.line,
                  width: borderWidth ?? (selected ? 1.5 : 1),
                ),
              ),
              constraints: BoxConstraints(minHeight: dense ? 48 : 62),
              padding:
                  contentPadding ??
                  EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: dense ? 6 : 10,
                  ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 列表行 —— **API 与 [ListTile] 同名同义**，方便逐页替换。
class DesignRowTile extends StatelessWidget {
  const DesignRowTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.dense = false,
    this.selected = false,
    this.contentPadding,
    this.autofocus = false,
    this.focusNode,
    this.isThreeLine = false,
    this.mouseCursor,
    this.shape,
    this.tileColor,
    this.titleTextStyle,
    this.subtitleTextStyle,
  });

  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final GestureTapCallback? onTap;
  final GestureLongPressCallback? onLongPress;
  final bool enabled;
  final bool dense;
  final bool selected;
  final EdgeInsetsGeometry? contentPadding;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool isThreeLine;
  final MouseCursor? mouseCursor;
  final ShapeBorder? shape;
  final Color? tileColor;
  final TextStyle? titleTextStyle;
  final TextStyle? subtitleTextStyle;

  /// 副标题样式：选中行要按**选中底色**校正对比度（DA199）。
  TextStyle _subtitleStyleFor(DesignPalette p) {
    final base =
        subtitleTextStyle ??
        TextStyle(fontSize: DesignType.bodySmallSize, color: p.muted);
    if (!selected) return base;
    final fg = base.color ?? p.muted;
    return base.copyWith(
      color: DesignPalette.ensureContrast(
        fg,
        p.primarySoft,
        min: 4.6,
        // 调色板没有 brightness 字段：按 `bg` 的亮度判深浅（深色底往亮推）。
        brightness: p.bg.computeLuminance() < 0.5
            ? Brightness.dark
            : Brightness.light,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DesignPalette p = DesignPalette.of(context);
    return DesignRowShell(
      onTap: onTap,
      onLongPress: onLongPress,
      enabled: enabled,
      dense: dense,
      selected: selected,
      contentPadding: contentPadding,
      tileColor: tileColor,
      child: Row(
        children: <Widget>[
          if (leading != null) ...<Widget>[
            _LeadingTile(p: p, child: leading!),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (title != null)
                  DefaultTextStyle.merge(
                    style:
                        titleTextStyle ??
                        TextStyle(
                          fontSize: DesignType.titleSmallSize,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                    child: title!,
                  ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 3),
                  DefaultTextStyle.merge(
                    // ★ DA199（真机 2026-10-22，播放队列选中行）：副标题的灰色是
                    //   按 `surface`（白）挑的，而选中行底色换成 `primarySoft`
                    //   （动态取色下真机是 203,230,252）⇒ 实测只有 **4.24:1**
                    //   （未达 AA）。选中态按实际底色把颜色推到 ≥4.6。
                    style: _subtitleStyleFor(p),
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 10),
            trailing!,
          ] else if (onTap != null)
            Icon(Icons.chevron_right, size: 18, color: p.dim),
        ],
      ),
    );
  }
}

/// 行首图标块：40×40、圆角 11、`surface2` 底（设计稿几何）。
/// 传进来的若是普通 Icon，自动上底色；传入自定义 widget（头像/色块）则原样居中。
class _LeadingTile extends StatelessWidget {
  const _LeadingTile({required this.p, required this.child});

  final DesignPalette p;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Widget icon = child;
    if (icon is Icon) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: p.primarySoft,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon.icon, size: 18, color: icon.color ?? p.primary),
      );
    }
    // ★ r491：**非图标的前导内容不再被压成 40×40**。
    //   日历事件行的时间列是 52 宽（时间 + 竖色条），旧写法把它塞进 40 宽里
    //   ⇒ 真机上横向溢出 4px（`calendar_page.dart` 2028 行的 Row）。
    //   现在只给"最小 40×40"的下限，宽度由内容决定；右侧留 12 让位给标题。
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Center(child: child),
      ),
    );
  }
}

/// 开关行 —— **API 与 [SwitchListTile] 同名同义**。
class DesignSwitchRow extends StatelessWidget {
  const DesignSwitchRow({
    super.key,
    this.value = false,
    required this.onChanged,
    this.secondary,
    this.title,
    this.subtitle,
    this.activeColor,
    this.contentPadding,
    this.dense = false,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? secondary;
  final Widget? title;
  final Widget? subtitle;
  final Color? activeColor;
  final EdgeInsetsGeometry? contentPadding;
  final bool dense;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final DesignPalette p = DesignPalette.of(context);
    return DesignRowTile(
      leading: secondary,
      title: title,
      subtitle: subtitle,
      contentPadding: contentPadding,
      enabled: enabled,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        // 旋钮在**两套主题里都是白**：`onPrimary` 在暗色是深藏蓝，
        // 落在亮蓝轨道上像个洞（真机第一次就是这样）⇒ 这里用固定白。
        activeThumbColor: Colors.white,
        activeTrackColor: activeColor ?? p.primary,
        inactiveThumbColor: p.muted,
        inactiveTrackColor: p.surface2,
      ),
    );
  }
}

/// 复选行（`CheckboxListTile` 的设计版）—— 与 `DesignSwitchRow` 同一套外框，
/// 圆角方框由 `Checkbox` 自己画（`p.primary` 填充 + 白勾）。
class DesignCheckRow extends StatelessWidget {
  const DesignCheckRow({
    super.key,
    this.value = false,
    required this.onChanged,
    this.secondary,
    this.title,
    this.subtitle,
    this.activeColor,
    this.contentPadding,
    this.dense = false,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? secondary;
  final Widget? title;
  final Widget? subtitle;
  final Color? activeColor;
  final EdgeInsetsGeometry? contentPadding;
  final bool dense;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final DesignPalette p = DesignPalette.of(context);
    return DesignRowTile(
      leading: secondary,
      title: title,
      subtitle: subtitle,
      contentPadding: contentPadding,
      enabled: enabled,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Checkbox(
        value: value,
        onChanged: enabled && onChanged != null
            ? (v) => onChanged!(v ?? false)
            : null,
        activeColor: activeColor ?? p.primary,
        checkColor: Colors.white,
        // ★ r514（DA157）：**不传 `side`**。r506 已经把"未选描边 = `dim`"写进
        // `checkboxTheme`，这里再显式传 `p.line` 会把它盖掉 —— 同一个控件
        // 在 Drive 选择模式（主题那条路）和这里（本组件那条路）颜色不一致，
        // 真机上一处看得见、一处几乎看不见。主题说了算。
      ),
    );
  }
}

/// 说明条（设计稿：`surface` 卡片 + `line` 边框 + warn 图标 + 11.5 文案）。
class DesignNote extends StatelessWidget {
  const DesignNote(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final DesignPalette p = DesignPalette.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: p.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon ?? Icons.info_outline, size: 16, color: p.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: DesignType.bodySmallSize,
                height: 1.45,
                color: p.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 贴底主按钮（设计稿：高度 48、圆角 26、`primary` 底、`onPrimary` 字）。
class DesignPrimaryButton extends StatelessWidget {
  const DesignPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.secondary = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    final DesignPalette p = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: secondary ? p.surface : p.primary,
            foregroundColor: secondary ? p.text : p.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
              side: secondary ? BorderSide(color: p.line) : BorderSide.none,
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: DesignType.titleSmallSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
