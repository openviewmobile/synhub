// Office 文档渲染的**共享样式解析**（批 B 抽出，批 A 的 `_NodeRenderer` 与
// 新的表格/页眉页脚组件都要用同一份，避免各写一份而漂移）。
//
// 为什么单独一个文件：`office_doc_table.dart` / `office_doc_page_frame.dart`
// 需要解析 `#rrggbb` 这类颜色，而颜色解析原本长在 `office_doc_view.dart` 里；
// 若让它们反向 import 渲染器就会形成循环依赖。这里只放**纯解析函数**（无状态、
// 不 import office 其它文件），渲染器再 `export` 出去保持既有 import 路径可用。
import 'package:flutter/material.dart';

/// **文档画布**颜色：恒为白，**与 App 主题无关**。
///
/// 原则（本批贯穿全部 Office 查看器）：**文档的底色与文字色由文档决定，
/// 绝不继承 App 主题**；App 主题只配给"文档之外的外壳"（工具栏/横幅/页码条）。
const Color kOfficeDocPaperCanvasColor = Color(0xFFFFFFFF);

/// **文档的缺省文字色**：深灰近黑。
///
/// 文档里**没有**给字色时用它，**不许**落到 `Theme.textTheme.*`。
///
/// 这条口径来自 `.osheet` 批次的独立取证：`_cell()` 的文字 base 是
/// `theme.textTheme.bodySmall`，于是"文件没给字色"的单元格在深色主题下
/// 变成近白字 —— 表现为"只有部分行坏掉"。修后实测坏行 Δ亮度 15→242，
/// 而**文件显式给色的行逐位不变**。
///
/// OOXML 侧 `office_doc_ooxml_view.dart` 的 `_runStyle` 用的是同一个值。
const Color kOfficeDocDefaultTextColor = Color(0xFF202124);

/// 解析 mark / 单元格颜色。
///
/// 支持四种写法：
/// * `#rgb` / `#rrggbb` / `#aarrggbb` —— **Synology 的 `.odoc`→DOCX 生产者
///   实际写出来的形式**（【实测】真样本 `product_spec.docx` 有 19 处
///   `<w:color w:val="#4176cc"/>` 这类、`restaurant_menu.docx` 有 72 处）；
/// * `rgb(r, g, b)` —— 同一生产者也会写（【实测】`restaurant_menu.docx`
///   有 28 处 `<w:color w:val="rgb(46, 92, 115)"/>`）；
/// * **裸 `rrggbb`（无 `#`）** —— OOXML 规范里 `ST_HexColor` 的**标准**写法
///   （Word 自己产出的 DOCX 就是裸十六进制）。本仓生产者不写这种，
///   【实测】3 份真样本 **0 处**，所以这条属于**规范推导**的兼容分支：
///   只有整串都是合法十六进制、且长度恰为 6 时才认，`auto`/`middle`/`bottom`
///   这类 4~6 字符的**枚举值**不会被误当颜色。
///
/// 认不出就返回 null —— 调用方保留纯文本 + 计入降级，**不抛**。
Color? officeDocParseColor(Object? value) {
  if (value is! String) return null;
  final s = value.trim().toLowerCase();
  if (s.isEmpty || s == 'transparent') return null;
  if (s.startsWith('#')) {
    var hex = s.substring(1);
    if (hex.length == 3) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length == 6) hex = 'ff$hex';
    if (hex.length != 8) return null;
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(v);
  }
  final m = RegExp(r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)').firstMatch(s);
  if (m != null) {
    final r = int.tryParse(m.group(1)!);
    final g = int.tryParse(m.group(2)!);
    final b = int.tryParse(m.group(3)!);
    if (r == null || g == null || b == null) return null;
    return Color.fromARGB(255, r, g, b);
  }
  // 裸 `rrggbb`（`ST_HexColor` 的标准写法）。**必须**整串是十六进制且长度 6，
  // 否则 `bottom`（6 字符）/`middle`（6 字符）这类枚举会走进来。
  if (s.length == 6) {
    final v = int.tryParse(s, radix: 16);
    if (v != null) return Color(0xff000000 | v);
  }
  return null;
}
