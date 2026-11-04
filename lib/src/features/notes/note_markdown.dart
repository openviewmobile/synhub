// 笔记的 **Markdown 模式**：源码 ⇄ NoteStation HTML 的互转。
//
// ## 为什么需要这层
//
// NoteStation 的正文是**净化后的 HTML**（官方编辑器是 WebView + execCommand），
// 服务端没有"Markdown"这个概念。所以 Markdown 笔记要落库，必须转成 HTML 存；
// 但**转成 HTML 就丢了源码**（`**粗体**` 和 `<strong>` 已经分不出来），下次打开
// 就没法接着用 Markdown 编辑。
//
// ## 解法：HTML 注释里夹一份源码（真机验证过能存活）
//
// 正文存成 `<!--dsh-md:1:<base64 源码>--><p>渲染后的 HTML</p>`：
//   * **可见部分是渲染好的 HTML** → 官方 App / 网页端打开是正常排版的笔记，
//     不是一段看不懂的符号（这点很重要：我们的笔记是给人看的，不是只给自己读）；
//   * **注释里是源码（base64）** → 我们这边再打开时能**无损**拿回 Markdown 原文，
//     不需要做有损的 HTML→Markdown 反解；
//   * 用 base64 而不是直接塞源码，是因为源码里可能出现 `-->`，会把注释提前截断。
//
// 真机验证（2026-09-18）：`Note/create` 写入含 HTML 注释的正文 → `Note/get` 回读，
// 注释与可见正文**都原样保留**（服务端不做 HTML 净化之外的删改）。
//
// ## 兼容
//
// 不是 Markdown 的笔记（没有标记）走原来的富文本路径，两套互不影响；
// 在 Markdown 模式里打开一条富文本笔记，会**把它的 HTML 当源码**显示 —— 这是明知的
// 取舍：不做有损反解，切模式前给出明确提示（见编辑器里的确认框）。
import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

/// 标记前缀：`<!--dsh-md:1:` + base64 源码 + `-->`
const String kMarkdownMarkerPrefix = '<!--dsh-md:1:';
const String kMarkdownMarkerSuffix = '-->';

/// Markdown 源码 → NoteStation HTML（前面带源码标记）。
///
/// 用 GFM 扩展：表格 / 任务列表 / 删除线 / 围栏代码块 —— 这些在 NoteStation 的
/// 渲染子集里都有对应物（`table` / `s` / `pre`）。
String markdownToNoteHtml(String source) {
  final encoded = base64Url.encode(utf8.encode(source));
  return '$kMarkdownMarkerPrefix$encoded$kMarkdownMarkerSuffix'
      '${markdownBodyToHtml(source)}';
}

/// 纯 Markdown → HTML（不含标记；预览与保存都用它）
String markdownBodyToHtml(String source) {
  if (source.trim().isEmpty) return '';
  return md.markdownToHtml(
    source,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );
}

/// 正文里是否带了 Markdown 标记
bool isMarkdownNote(String html) => html.contains(kMarkdownMarkerPrefix);

/// 从正文里取出 Markdown 源码（没有标记 → null）。
///
/// 标记永远在最前面（我们写入时就是拼在开头），但这里仍然按"找第一个完整标记"
/// 解析，避免笔记被别的工具改过之后位置变了。
String? markdownSourceFromHtml(String html) {
  final start = html.indexOf(kMarkdownMarkerPrefix);
  if (start < 0) return null;
  final bodyStart = start + kMarkdownMarkerPrefix.length;
  final end = html.indexOf(kMarkdownMarkerSuffix, bodyStart);
  if (end < 0) return null;
  final encoded = html.substring(bodyStart, end).trim();
  try {
    return utf8.decode(base64Url.decode(encoded));
  } catch (_) {
    // base64 坏了（被人手改过）→ 当普通富文本处理，不给用户看异常
    return null;
  }
}

/// 去掉标记，只留**可见正文**（官方端看到的、以及预览要渲染的部分）
String markdownVisibleHtml(String html) {
  final start = html.indexOf(kMarkdownMarkerPrefix);
  if (start < 0) return html;
  final end = html.indexOf(kMarkdownMarkerSuffix, start);
  if (end < 0) return html;
  return html.substring(end + kMarkdownMarkerSuffix.length);
}

/// 把 Markdown 源码重新打包成"带标记的正文"（编辑保存时用）
String repackMarkdownHtml(String source) => markdownToNoteHtml(source);
