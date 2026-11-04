// OOXML **颜色**解析（批 O4）：`theme1.xml` 色板、`<color theme tint>` 引用色、
// `indexed` 传统调色板，以及"文档自己的底色/文字色"这套**显示基调**。
//
// 为什么单独一个文件：`.osheet` 走 OOXML（XLSX）主通道
// （`office_sheet_xlsx.dart` 文件头已取证：NAS 三份真实文件下载后都是标准 XLSX），
// 而颜色在 OOXML 里有**四种互斥写法**，必须按同一份规则解引用；解析器
// （`office_sheet_xlsx.dart`）与渲染器（`office_sheet_view.dart`）都要用，
// 放这里避免漂移。本文件**只用 `dart:ui` 的 `Color` + `xml`**，不含任何 UI 状态。
//
// ---------------------------------------------------------------------------
// 事实来源（逐条标注，区分【实测】/【规范推导】）
// ---------------------------------------------------------------------------
//
// 1) `theme1.xml` 的 `<a:clrScheme>`【实测】
//    真实样本 `test/fixtures/office_sheet_o2/annual_income_and_expenditure.xlsx`
//    的 `xl/theme/theme1.xml` 逐字为：
//      <a:clrScheme name="Theme1">
//        <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
//        <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
//        <a:dk2><a:srgbClr val="1F497D"/></a:dk2>
//        <a:lt2><a:srgbClr val="EEECE1"/></a:lt2>
//        <a:accent1><a:srgbClr val="4F81BD"/></a:accent1>
//        ... accent2 C0504D / accent3 9BBB59 / accent4 8064A2 / accent5 4BACC6 /
//            accent6 F79646 / hlink 0000FF / folHlink 800080
//      </a:clrScheme>
//    ⇒ XML 里的**元素顺序**是 dk1, lt1, dk2, lt2, accent1..6, hlink, folHlink。
//    ⇒ `sysClr` 的真实颜色在 **`lastClr`** 属性（`val="window"` 只是系统别名）。
//
// 2) `<color theme="N"/>` 的 **N 不是**上面那个顺序的下标【规范推导 + 官方实现】
//    Apache POI `org.apache.poi.xssf.model.ThemesTable` 的 `ThemeElement` 枚举
//    逐字为：
//        LT1(0), DK1(1), LT2(2), DK2(3),
//        ACCENT1(4), ACCENT2(5), ACCENT3(6),
//        ACCENT4(7), ACCENT5(8), ACCENT6(9),
//        HLINK(10), FOLHLINK(11)
//    且该文件里有一句明确的注释：
//      "Theme color references are NOT positional indices into the color scheme,
//       i.e. these keys are NOT the same as the order in which theme colors appear
//       in theme1.xml. They are keys to a mapped color."
//    ⇒ 0↔1 与 2↔3 相对 XML 顺序**互换**（背景色在文字色之前）。
//    **这是【推导】**：本批三份真实样本里 `theme=` 出现次数为 **0**（见报告），
//    所以我没有可实测的样本去交叉验证这条映射；它来自官方实现而非本机实测。
//
// 3) `tint` 演算【规范推导 + 官方实现】POI `XSSFColor.getTint()` 的 javadoc 复述了
//    ECMA-376 的算法（HLSMAX = 255，Lum 取 HLS 的亮度分量）：
//        tint < 0:  Lum' = Lum * (1.0 + tint)
//        tint > 0:  Lum' = Lum * (1.0 - tint) + (HLSMAX - HLSMAX * (1.0 - tint))
//    即 tint>0 时向 255（白）插值、tint<0 时按比例压向 0（黑）。
//    javadoc 自带算例：Lum=100, tint=0.75 → 217；Lum=200, tint=-0.5 → 100。
//    本文件用 **L∈[0,1]** 的等价写法：`L' = L*(1-t) + t`（t>0）。
//    **[推导] 非实测**：三份样本 `tint=` 出现次数同样为 0。
//
// 4) `indexed` 传统调色板【规范推导】沿用 HSSF/BIFF 的 64 色表
//    （POI `DefaultIndexedColorMap` → `HSSFColor.getIndexHash()`）。
//    样本未出现，作兜底。
//
// 5) 对比度选色【本仓自己定的规则，不是 OOXML 规范】Excel 对"自动"文字色用的是
//    黑/白二选一；本文件按 **WCAG 相对亮度**取与底色反差更大的那个（黑或白），
//    阈值即两者反差相等处（相对亮度 L ≈ 0.1791）。规范没有逐字规定阈值，
//    所以这里标注为**本仓选择**。
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import 'office_sheet_style.dart';

// ---------------------------------------------------------------------------
// 文档显示基调（**文档自己的**底色，与 App 主题无关）
// ---------------------------------------------------------------------------

/// 工作表"纸面"底色：**默认白**。
///
/// 这是本批的核心修复之一：`.osheet` 的网格原先直接吃 App 主题的
/// `colorScheme.surface`，深色主题下整张表变黑底，而真实文件（白底黑字）
/// 应当显示为白纸。OOXML 里"工作表没有底色"的语义就是**白**（`lt1` 的默认值
/// `FFFFFF`，见上面【实测】的 `sysClr lastClr="FFFFFF"`）。
const Color kOfficeSheetPaperColor = Color(0xFFFFFFFF);

/// 文档默认文字色：**黑**（OOXML 字体无 `<color>` 时的"自动"色落在白纸上）。
const Color kOfficeSheetDefaultTextColor = Color(0xFF000000);

/// 网格线默认色（文件未声明时的兜底）。
///
/// OOXML 的默认网格线颜色由实现决定（Excel 2007+ 约为 `#D0D7DE`）；
/// 规范只说 `<sheetView colorId>` 可覆盖。**本仓选择**这个浅灰，
/// 关键是**不再用 App 主题的 `dividerColor`**（深色主题下那条线是亮的，
/// 画在白纸上像"反色表格"）。
const Color kOfficeSheetGridLineColor = Color(0xFFD0D7DE);

/// 行号列 / 列标行的底色与文字色（Excel/WPS 的浅灰表头，与纸面同理不跟 App 主题）。
const Color kOfficeSheetHeaderFillColor = Color(0xFFF5F5F5);
const Color kOfficeSheetHeaderTextColor = Color(0xFF5F6368);
const Color kOfficeSheetHeaderLineColor = Color(0xFFD0D7DE);

/// 选中单元格的描边色（UI 状态，不是文档内容）。
const Color kOfficeSheetSelectionColor = Color(0xFF1A73E8);

// ---------------------------------------------------------------------------
// 主题色板
// ---------------------------------------------------------------------------

/// `theme1.xml` `<a:clrScheme>` 的十二个槽位（**XML 里的物理顺序**）。
enum OfficeSheetThemeSlot {
  dk1,
  lt1,
  dk2,
  lt2,
  accent1,
  accent2,
  accent3,
  accent4,
  accent5,
  accent6,
  hlink,
  folHlink,
}

/// `<color theme="N"/>` 的 N → 槽位。
///
/// 逐字对应 Apache POI `ThemesTable.ThemeElement`（见文件头 §2）：
/// `LT1(0), DK1(1), LT2(2), DK2(3), ACCENT1(4)…ACCENT6(9), HLINK(10), FOLHLINK(11)`。
///
/// **注意 0/1 与 2/3 与 `officeSheetThemeSlotByName` 的顺序相反**，
/// 这不是笔误：`theme` 的下标语义是"背景1/文字1/背景2/文字2"，
/// 而 `theme1.xml` 的元素顺序是"dk1/lt1/dk2/lt2"。
const List<OfficeSheetThemeSlot> kOfficeSheetThemeSlotByIndex =
    <OfficeSheetThemeSlot>[
      OfficeSheetThemeSlot.lt1, // 0
      OfficeSheetThemeSlot.dk1, // 1
      OfficeSheetThemeSlot.lt2, // 2
      OfficeSheetThemeSlot.dk2, // 3
      OfficeSheetThemeSlot.accent1, // 4
      OfficeSheetThemeSlot.accent2, // 5
      OfficeSheetThemeSlot.accent3, // 6
      OfficeSheetThemeSlot.accent4, // 7
      OfficeSheetThemeSlot.accent5, // 8
      OfficeSheetThemeSlot.accent6, // 9
      OfficeSheetThemeSlot.hlink, // 10
      OfficeSheetThemeSlot.folHlink, // 11
    ];

/// `theme1.xml` 里的元素名 → 槽位（**物理顺序**，与上面那张表不同）。
const Map<String, OfficeSheetThemeSlot> officeSheetThemeSlotByName =
    <String, OfficeSheetThemeSlot>{
      'dk1': OfficeSheetThemeSlot.dk1,
      'lt1': OfficeSheetThemeSlot.lt1,
      'dk2': OfficeSheetThemeSlot.dk2,
      'lt2': OfficeSheetThemeSlot.lt2,
      'accent1': OfficeSheetThemeSlot.accent1,
      'accent2': OfficeSheetThemeSlot.accent2,
      'accent3': OfficeSheetThemeSlot.accent3,
      'accent4': OfficeSheetThemeSlot.accent4,
      'accent5': OfficeSheetThemeSlot.accent5,
      'accent6': OfficeSheetThemeSlot.accent6,
      'hlink': OfficeSheetThemeSlot.hlink,
      'folHlink': OfficeSheetThemeSlot.folHlink,
    };

/// 文档自身的主题色板（来自 `xl/theme/theme1.xml`）。
///
/// 解析不出来时用 [fallback]（Office 默认主题），**不抛**：缺主题不应该让
/// 整张表打不开。
class OfficeSheetThemeScheme {
  const OfficeSheetThemeScheme(this.slots);

  /// 槽位 → 颜色（缺失的槽位不在表里）。
  final Map<OfficeSheetThemeSlot, Color> slots;

  /// Office 2007 默认主题（`theme1.xml` 缺失时的兜底；取值同上面【实测】的样本）。
  static const OfficeSheetThemeScheme fallback = OfficeSheetThemeScheme(
    <OfficeSheetThemeSlot, Color>{
      OfficeSheetThemeSlot.dk1: Color(0xFF000000),
      OfficeSheetThemeSlot.lt1: Color(0xFFFFFFFF),
      OfficeSheetThemeSlot.dk2: Color(0xFF1F497D),
      OfficeSheetThemeSlot.lt2: Color(0xFFEEECE1),
      OfficeSheetThemeSlot.accent1: Color(0xFF4F81BD),
      OfficeSheetThemeSlot.accent2: Color(0xFFC0504D),
      OfficeSheetThemeSlot.accent3: Color(0xFF9BBB59),
      OfficeSheetThemeSlot.accent4: Color(0xFF8064A2),
      OfficeSheetThemeSlot.accent5: Color(0xFF4BACC6),
      OfficeSheetThemeSlot.accent6: Color(0xFFF79646),
      OfficeSheetThemeSlot.hlink: Color(0xFF0000FF),
      OfficeSheetThemeSlot.folHlink: Color(0xFF800080),
    },
  );

  bool get isEmpty => slots.isEmpty;

  Color? bySlot(OfficeSheetThemeSlot slot) => slots[slot];

  /// `<color theme="index"/>` 的 index → 颜色；越界 → `null`。
  Color? byIndex(int index) {
    if (index < 0 || index >= kOfficeSheetThemeSlotByIndex.length) return null;
    return slots[kOfficeSheetThemeSlotByIndex[index]];
  }

  /// 解析 `xl/theme/theme1.xml` 的文本；不是合法 XML / 没有 `clrScheme` → `null`。
  static OfficeSheetThemeScheme? parse(String? xmlText) {
    if (xmlText == null || xmlText.trim().isEmpty) return null;
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlText);
    } on Object {
      return null;
    }
    return fromDocument(doc);
  }

  /// 从已解析的 XML 文档取 `<a:clrScheme>`。
  static OfficeSheetThemeScheme? fromDocument(XmlDocument doc) {
    final scheme = _firstDescendant(doc.rootElement, 'clrScheme');
    if (scheme == null) return null;

    final slots = <OfficeSheetThemeSlot, Color>{};
    for (final child in scheme.childElements) {
      final slot = officeSheetThemeSlotByName[child.localName];
      if (slot == null) continue;
      final color = _colorOfThemeEntry(child);
      if (color != null) slots[slot] = color;
    }
    if (slots.isEmpty) return null;
    return OfficeSheetThemeScheme(slots);
  }
}

/// `<a:dk1>` 这类条目的颜色：优先 `srgbClr@val`，其次 `sysClr@lastClr`。
///
/// `sysClr` 的 `val` 只是系统别名（`window` / `windowText`），**真实值在
/// `lastClr`**（见文件头【实测】原文）。
Color? _colorOfThemeEntry(XmlElement entry) {
  final srgb = _firstDescendant(entry, 'srgbClr');
  if (srgb != null) {
    final c = officeSheetParseColor(srgb.getAttribute('val'));
    if (c != null) return c;
  }
  final sys = _firstDescendant(entry, 'sysClr');
  if (sys != null) {
    final last = officeSheetParseColor(sys.getAttribute('lastClr'));
    if (last != null) return last;
    // 只有别名时按已知的系统色兜底（`windowText` 黑 / `window` 白）。
    final val = (sys.getAttribute('val') ?? '').trim().toLowerCase();
    if (val == 'windowtext') return const Color(0xFF000000);
    if (val == 'window') return const Color(0xFFFFFFFF);
  }
  return null;
}

/// 颜色 → `AARRGGBB` 十六进制串（**无 `#`**，大写）。
///
/// 这是 `OSheetStylePool` 里 `fonts[].c` / `fills[].bg` / `borders[].b` 的既有
/// 存储形态（真实样本原文就是 `FF6153A6` 这种 8 位无 `#` 串，见
/// `test/office_sheet_o2_xlsx_test.dart` 的断言），解析回来的入口同样是
/// [officeSheetParseColor]。**解析层与渲染层共用这一个编码器**，避免两处漂移。
String officeSheetColorToHex(Color color) =>
    color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();

/// 解引用一个 `<color>` 元素并直接编码成存储串；解不出 → `null`（= 自动）。
String? officeSheetColorHexFromElement(
  XmlElement? element,
  OfficeSheetThemeScheme? theme,
) {
  final color = officeSheetColorFromElement(element, theme);
  return color == null ? null : officeSheetColorToHex(color);
}

// ---------------------------------------------------------------------------
// tint / shade
// ---------------------------------------------------------------------------

/// 对 [base] 施加 OOXML `tint`（**HLS 亮度插值**）。
///
/// 见文件头 §3（POI `XSSFColor.getTint()` javadoc 复述的 ECMA-376 算法）：
/// `tint < 0` 压向黑、`tint > 0` 插值向白。`tint == 0` 原样返回。
Color officeSheetApplyTint(Color base, double tint) {
  if (tint == 0) return base;
  final t = tint < -1.0 ? -1.0 : (tint > 1.0 ? 1.0 : tint);

  final r = base.r; // Flutter 3.27+ 的 0..1 分量
  final g = base.g;
  final b = base.b;

  final maxV = <double>[r, g, b].reduce((a, c) => a > c ? a : c);
  final minV = <double>[r, g, b].reduce((a, c) => a < c ? a : c);
  final l = (maxV + minV) / 2.0;

  final double newL;
  if (t < 0) {
    newL = l * (1.0 + t);
  } else {
    newL = l * (1.0 - t) + t;
  }
  if (newL == l) return base;

  // 只有亮度变，色相/饱和度不变：直接缩放 RGB 到目标亮度。
  //（等价于 HLS 往返，但不引入 H/S 的往返量化误差。）
  if (maxV == minV) {
    return Color.fromARGB(
      (base.a * 255).round(),
      (newL * 255).round(),
      (newL * 255).round(),
      (newL * 255).round(),
    );
  }
  final d = maxV - minV;
  final s = l > 0.5 ? d / (2.0 - maxV - minV) : d / (maxV + minV);
  return _hslToColor(base.a, _hueOf(r, g, b, maxV, minV, d), s, newL);
}

double _hueOf(double r, double g, double b, double maxV, double minV, double d) {
  if (d == 0) return 0;
  final double h;
  if (maxV == r) {
    h = ((g - b) / d) % 6.0;
  } else if (maxV == g) {
    h = (b - r) / d + 2.0;
  } else {
    h = (r - g) / d + 4.0;
  }
  return (h / 6.0) % 1.0;
}

Color _hslToColor(double a, double h, double s, double l) {
  if (s == 0) {
    final v = (l * 255).round();
    return Color.fromARGB((a * 255).round(), v, v, v);
  }
  final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  int ch(double t) {
    var tt = t;
    if (tt < 0) tt += 1;
    if (tt > 1) tt -= 1;
    final double v;
    if (tt < 1 / 6) {
      v = p + (q - p) * 6 * tt;
    } else if (tt < 1 / 2) {
      v = q;
    } else if (tt < 2 / 3) {
      v = p + (q - p) * (2 / 3 - tt) * 6;
    } else {
      v = p;
    }
    return (v * 255).round();
  }

  return Color.fromARGB(
    (a * 255).round(),
    ch(h + 1 / 3),
    ch(h),
    ch(h - 1 / 3),
  );
}

// ---------------------------------------------------------------------------
// indexed 传统调色板
// ---------------------------------------------------------------------------

/// `indexed="N"` 的传统调色板（HSSF/BIFF 64 色；POI `DefaultIndexedColorMap`）。
///
/// `64` / `65` 是"系统前景/背景"，语义为自动 → `null`（由调用方按对比度选）。
const List<int> kOfficeSheetIndexedColors = <int>[
  0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
  0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
  0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
  0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
  0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
  0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
  0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
  0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
];

/// `indexed="N"` → 颜色；越界 / 系统色（64、65）→ `null`。
Color? officeSheetIndexedColor(int index) {
  if (index < 0 || index >= kOfficeSheetIndexedColors.length) return null;
  return Color(0xFF000000 | kOfficeSheetIndexedColors[index]);
}

// ---------------------------------------------------------------------------
// `<color …/>` 元素的统一解引用
// ---------------------------------------------------------------------------

/// 解引用一个 SpreadsheetML `<color>` / `<fgColor>` / `<bgColor>` / 边框
/// `<color>` 元素。四种互斥写法按 OOXML 优先级认：
///
/// 1. `rgb="AARRGGBB"` —— 字面色，**以文件为准**；
/// 2. `theme="N"`（+ 可选 `tint="±x"`）—— 查 [theme] 色板再做 tint；
/// 3. `indexed="N"` —— 查传统调色板；
/// 4. `auto="1"` / 什么都没有 —— **返回 `null`**（= OOXML 的"自动"），
///    由渲染层按底色对比度决定（**不与"显式给了色"混淆**）。
///
/// [theme] 为 `null` 时退回 [OfficeSheetThemeScheme.fallback]（Office 默认主题），
/// 这样 `<color theme="4"/>` 至少不会变成透明。
Color? officeSheetColorFromElement(
  XmlElement? element,
  OfficeSheetThemeScheme? theme,
) {
  if (element == null) return null;

  final rgb = element.getAttribute('rgb');
  if (rgb != null && rgb.trim().isNotEmpty) {
    return officeSheetParseColor(rgb);
  }

  final themeAttr = element.getAttribute('theme');
  if (themeAttr != null) {
    final index = int.tryParse(themeAttr.trim());
    if (index != null) {
      final scheme = (theme == null || theme.isEmpty)
          ? OfficeSheetThemeScheme.fallback
          : theme;
      final base = scheme.byIndex(index);
      if (base != null) {
        final tint = double.tryParse(element.getAttribute('tint') ?? '');
        return tint == null ? base : officeSheetApplyTint(base, tint);
      }
    }
  }

  final indexedAttr = element.getAttribute('indexed');
  if (indexedAttr != null) {
    final index = int.tryParse(indexedAttr.trim());
    if (index != null) {
      final c = officeSheetIndexedColor(index);
      if (c != null) {
        final tint = double.tryParse(element.getAttribute('tint') ?? '');
        return tint == null ? c : officeSheetApplyTint(c, tint);
      }
    }
  }

  // `auto="1"` 或空元素 → "自动"，交给对比度判定。
  return null;
}

/// 直接按 `theme` 索引 + tint 取色（少数地方只有下标、没有元素，例如
/// `<sheetView colorId>` 走的是 indexed，这个函数留给主题引用）。
Color? officeSheetThemeColor(
  int index, {
  OfficeSheetThemeScheme? theme,
  double? tint,
}) {
  final scheme = (theme == null || theme.isEmpty)
      ? OfficeSheetThemeScheme.fallback
      : theme;
  final base = scheme.byIndex(index);
  if (base == null) return null;
  return tint == null ? base : officeSheetApplyTint(base, tint);
}

// ---------------------------------------------------------------------------
// 对比度：OOXML "自动"文字色
// ---------------------------------------------------------------------------

/// WCAG 相对亮度（sRGB → 线性）。
///
/// 直接复用 Flutter 的 [Color.computeLuminance]（其实现就是 WCAG 的
/// `0.2126R + 0.7152G + 0.0722B`，通道先做 sRGB 线性化）——与
/// `office_slides_deck_view.dart` / `hud_widgets.dart` 已有的做法一致，
/// 不自己再写一份以免漂移。
double officeSheetRelativeLuminance(Color color) => color.computeLuminance();

/// "自动"文字色：底色亮 → 黑字；底色暗 → 白字。
///
/// 规则见文件头 §5（**本仓选择**，非规范逐字）：取黑/白中与 [fill] 反差更大者。
/// 两者反差相等处为相对亮度 `L ≈ 0.1791`。
/// [fill] 为 `null`（无填充）→ 纸面为白 → 黑字。
Color officeSheetAutomaticTextColor(Color? fill) {
  if (fill == null) return kOfficeSheetDefaultTextColor;
  // 半透明填充按叠在白纸上算（OOXML 填充基本不透明；这里只是防御）。
  final opaque = fill.a >= 1.0
      ? fill
      : Color.alphaBlend(fill, kOfficeSheetPaperColor);
  final l = officeSheetRelativeLuminance(opaque);
  const threshold = 0.1791;
  return l > threshold ? kOfficeSheetDefaultTextColor : const Color(0xFFFFFFFF);
}

/// 该底色上"自动"文字色的对比度（供报告/调试用）。
double officeSheetContrastRatio(Color a, Color b) {
  final la = officeSheetRelativeLuminance(a);
  final lb = officeSheetRelativeLuminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

XmlElement? _firstDescendant(XmlElement root, String localName) {
  for (final el in root.descendantElements) {
    if (el.localName == localName) return el;
  }
  return null;
}
