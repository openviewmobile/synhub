// `.odoc` **只读路径**上对真实 NAS 文档的容错解析。
//
// ## 为什么需要这个文件（真机 + 真夹具双重取证）
//
// 真机：`Restaurant menu.odoc` 打开后是**整页「打开失败 / 操作未能完成」**，
// logcat 原文：
// ```
// I/flutter: [office:describeError] MalformedDocNodeException:
//     malformed doc node at $content[0]: "marks" is only valid on text nodes
// ```
// 根因：M1 校验器 `lib/src/data/office_collab/doc_schema.dart` 的 `_parseNode`
// （`:593`）有这么一条：
// ```dart
// // `marks` on a non-text node is not produced by the fork; reject it.
// if (map.containsKey('marks') && map['marks'] != null) {
//   throw MalformedDocNodeException('"marks" is only valid on text nodes', path: path);
// }
// ```
// **它的前提是"官方实现不会在非 text 节点上写 `marks`"——真机数据推翻了这个前提。**
//
// 真夹具统计（`test/fixtures/office_doc_redesign/*_snapshot.json`，逐份递归数"非 text
// 节点带 marks"）：
// ```
// five_day_trip_planner_snapshot.json   nonTextMarks=0
// product_spec_snapshot.json            nonTextMarks=0
// restaurant_menu_snapshot.json         nonTextMarks=10   ← 只有这一份
// student_report_snapshot.json          nonTextMarks=0
// vacation_packing_list_snapshot.json   nonTextMarks=0
// ```
// ⇒ **这就是"为什么只有这一份打不开"的答案。**
//
// ## 为什么删掉这些 marks 是安全的（不是"能打开但内容错"）
//
// `restaurant_menu` 那 10 处 marks 的全部内容（逐条枚举）：
// ```
// 10 × font_size   {"_":"font_size","value":15}
//  5 × font_family {"_":"font_family","value":"Trebuchet MS",…}
//  5 × strong      {"_":"strong"}
//  5 × color       {"_":"color","value":"#e55d50"}
// ```
// 它们全是**字符级（run-level）文字样式**，挂在 `picture` 节点上。
//
// 而图片节点的可见形态**全部来自 `attrs.config`**，与 marks 无关：
// `office_doc_view.dart:797`「`picture`（真机形态）：引用与版式全在 `attrs.config` 里」、
// `:809` `if (type == 'picture')` 只读 `attrs`。
// ⇒ **删掉这些 marks 只损失"挂错了地方、本来就不生效"的文字样式，
//    不损失任何图片的内容或版式** ⇒ 属于"少一点样式"，不属于"内容错"。
//
// ## 边界（**只放宽这一条**）
//
// * 只删**非 text 节点**上的 `marks` 这**一个**键；`attrs` / `content` / `text`
//   以及 text 节点自己的 marks **一个字节都不动**；
// * 不碰 `doc_schema.dart`（它是 OT/M2 写路径的权威校验器，不该为一个只读显示问题
//   而全局放宽）；容错只发生在**只读解析的调用点**；
// * text 节点上的 marks **不合法时仍然抛异常**（没有被静默吞掉）；
// * 有删改就有 note（调用方把 note 显示给用户），**绝不静默**。
//
// ## 单位 / 口径
// 本文件不含任何单位换算，只做 JSON 树的结构清洗，所以没有"实测/规范推导"之分。
import '../../core/i18n/data_text.dart';
import '../../data/office_collab/doc_schema.dart'
    show DocNode, MalformedDocNodeException;

/// 清洗后的结果（**纯数据**，可离线单测）。
class OfficeDocSanitizeResult {
  const OfficeDocSanitizeResult({
    required this.json,
    required this.strippedNodes,
    required this.strippedMarks,
  });

  /// 清洗后的 JSON 树（没有任何改动时**就是原对象**，不做深拷贝）。
  final Object? json;

  /// 被删掉 `marks` 的非 text 节点数。
  final int strippedNodes;

  /// 被删掉的 mark 条目总数。
  ///
  /// 口径：`marks` 是数组时按**条目数**计；为空数组或不是数组时按 **1 条**计
  /// —— 因为校验器（`doc_schema.dart:593`）判的是"**键存在且非 null**"，
  /// 空数组**同样非法**，删掉的就是一个非法的键。
  final int strippedMarks;

  /// 是否真的改动过（**以节点数为准**：只要摘过键就一定改动过）。
  bool get changed => strippedNodes > 0;

  @override
  String toString() =>
      'OfficeDocSanitizeResult(nodes=$strippedNodes, marks=$strippedMarks)';
}

/// 把**非 text 节点**上的 `marks` 删掉（其余一切原样保留）。
///
/// 纯函数；`changed == false` 时返回的 [OfficeDocSanitizeResult.json] 与原对象
/// **相同引用**，所以对合法文档零开销、零行为变化。
OfficeDocSanitizeResult officeDocStripNonTextMarks(Object? raw) {
  var strippedNodes = 0;
  var strippedMarks = 0;

  Object? visit(Object? node) {
    if (node is List) {
      var listChanged = false;
      final out = <Object?>[];
      for (final item in node) {
        final next = visit(item);
        if (!identical(next, item)) listChanged = true;
        out.add(next);
      }
      return listChanged ? out : node;
    }
    if (node is! Map) return node;
    // `_asMap` 的等价物：JSON 解析出来就是 `Map<String, Object?>`，
    // 但内存构造的夹具可能是 `Map<Object?, Object?>`，这里统一按 String key 取。
    final type = node['type'];

    var thisChanged = false;
    Object? out = node;

    final rawContent = node['content'];
    if (rawContent is List) {
      final nextContent = visit(rawContent);
      if (!identical(nextContent, rawContent)) {
        if (identical(out, node)) out = Map<Object?, Object?>.of(node);
        (out as Map)['content'] = nextContent;
        thisChanged = true;
      }
    }

    // **只放宽这一条**：非 text 节点上的 marks。
    if (type is String && type != 'text' && node['marks'] != null) {
      final marks = node['marks'];
      strippedNodes++;
      strippedMarks += (marks is List && marks.isNotEmpty) ? marks.length : 1;
      if (identical(out, node)) out = Map<Object?, Object?>.of(node);
      (out as Map).remove('marks');
      thisChanged = true;
    }
    return thisChanged ? out : node;
  }

  final cleaned = visit(raw);
  return OfficeDocSanitizeResult(
    json: cleaned,
    strippedNodes: strippedNodes,
    strippedMarks: strippedMarks,
  );
}

/// 容错解析的结果。
class OfficeDocTolerantParseResult {
  const OfficeDocTolerantParseResult({required this.node, required this.note});

  final DocNode? node;

  /// 用户语言的如实说明；没有降级时为 null。
  ///
  /// 调用方必须把它显示出来（本项目的 `state.layoutNote` 通道），
  /// **不许静默吞掉**。
  final String? note;
}

/// 用 M1 解析原始文档 JSON，并对"非 text 节点带 marks"这一种真实写法容错。
///
/// * 文档本来就合法（真机 5 份样本里的 4 份，以及本仓全部其它夹具）
///   ⇒ 与改动前**逐字节相同**（不深拷贝、不改写、note 为 null）；
/// * 文档踩到那一种写法（`Restaurant menu.odoc`）⇒ 先清洗再解析，
///   并返回一条 note。
///
/// 清洗之后**仍然**非法时，异常照常抛出（调用方按既有失败态处理）——
/// 本函数只放宽"非 text 节点的 marks"这一条，不兜底其它畸形。
OfficeDocTolerantParseResult officeDocParseNodeTolerant(Object? raw) {
  if (raw is! Map) {
    // 顶层不是对象 ⇒ 这不是一份文档树。**明确失败**，不假装成功；
    // 也不把异常抛给调用方去猜（只读路径要能给出可读的说明）。
    return const OfficeDocTolerantParseResult(
      node: null,
      note: '这份文档的内容不是可识别的文档树（顶层不是对象），因此无法显示。',
    );
  }
  final cleaned = officeDocStripNonTextMarks(raw);
  if (!cleaned.changed) {
    return OfficeDocTolerantParseResult(
      node: DocNode.fromRawJson(raw),
      note: null,
    );
  }
  return OfficeDocTolerantParseResult(
    node: DocNode.fromRawJson(cleaned.json),
    note: dataText(
      'officeDocTolerantMarks',
      '文档里有 ${cleaned.strippedNodes} 处图片被附带了 '
          '${cleaned.strippedMarks} 条文字格式标记（marks）；'
          '这类标记写在图片上本来就不生效，已忽略，正文与图片内容完整。',
    )
        .replaceAll('{nodes}', '${cleaned.strippedNodes}')
        .replaceAll('{marks}', '${cleaned.strippedMarks}'),
  );
}

/// 清洗后再解析，**解析失败由调用方处理**（本函数只保证不外泄
/// [MalformedDocNodeException] 的路径已尽量收窄）。
bool officeDocLooksMalformed(Object error) =>
    error is MalformedDocNodeException;
