import 'package:flutter/material.dart';

/// 单行文本"放得下吗"的唯一口径。
///
/// ## 为什么要有这个函数（第 349 轮，从 `calendar_page.dart` 提取）
///
/// 头部副标题这类**装饰性**文案只有一行预算（实测手机上是
/// **105～232px**，被返回键 + 工具条按钮吃掉大半）。CJK 文本**可以在任意两字之间折行**
/// ⇒ 直接丢个 `Text` 进去，真机上会看到 `… · 标` / `签 · …` 这种**把词劈成两半**的排版
/// （r349 真机截图：联系人页 `SYNOLOGY CONTACTS · 通讯录 / 标` + `签 / CardDAV`）。
///
/// 第 262 轮在日历页定的口径是：**放得下就完整画，放不下就整行不画** ——
/// 宁可少一行装饰，也不要一行被劈开或吃掉半截的（那是用户看得到的缺陷）。
/// 第 349 轮把它提成公共函数，联系人页复用**同一份**判据（同一问题只能有一份实现）。
///
/// ★ 判据是**机制量**：`TextPainter` 按当前 `textScaler` / `locale` 真实排版后比宽度，
/// 不是"数中文字符个数"那种估算（估算在 2.0 缩放下必错）。
bool textFitsOnOneLine(
  BuildContext context,
  String text,
  TextStyle? style,
  double maxWidth,
) {
  // ★★★ D68（r349 实测出来的）：**"量不出来"不等于"放不下"**。
  //
  // 实测读数（1280×800 桌面窗口，同一段文本、同一套样式）：
  //   * 预算拿得到时 `maxWidth=1120.0` ⇒ 判"放得下" ⇒ 画出来 ✓
  //   * 预算拿不到时 `maxWidth=0.0`   ⇒ **旧判据返回 false ⇒ 整行换成 `' '`** ✗
  // 后者会在**任何"还没量到"的构建帧**里把副标题**整行抹掉**（路由转场、
  // 折叠头、首帧…），于是"D65 的『太长就藏』"退化成"**永远不显示**"。
  //
  // 正确口径：**只有"量到了确切的预算且确实超出"才藏**；
  // 预算未知（非有限）或还没量到（≤0）时**照画** ——
  //   ① 无界上下文里文本按自然宽排，本来就不会溢出；
  //   ② 真·0 宽上下文里 `Text` 自己按 `ellipsis` 裁掉，不出 overflow 报错；
  //   ③ 一旦量到真预算，下一帧就会给出正确结果，**不会先闪一下空白**。
  if (!maxWidth.isFinite || maxWidth <= 0) return true;
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
    locale: Localizations.maybeLocaleOf(context),
  )..layout();
  final fits = tp.width <= maxWidth;
  tp.dispose();
  return fits;
}

/// 装饰性单行副标题：**放得下就画，放不下就退化成空格**（保住行高，不抖动下方布局）。
///
/// * [textKey] 挂在这个 `Text` 上，用例按它取 `RenderParagraph.didExceedMaxLines`
///   与 `toPlainText()` —— **布局断言证明不了"有没有被截断"**，必须问排版结果。
/// * 退化成 `' '` 而不是 `''`：空串的段落高度可能为 0，会让头部忽高忽低。
class FittedSubtitle extends StatelessWidget {
  const FittedSubtitle({
    super.key,
    required this.text,
    required this.style,
    this.textKey,
  });

  final String text;
  final TextStyle? style;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final keep = textFitsOnOneLine(context, text, style, box.maxWidth);
        return Text(
          keep ? text : ' ',
          key: textKey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }
}
