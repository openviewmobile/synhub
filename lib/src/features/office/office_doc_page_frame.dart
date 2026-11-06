// Office `.odoc` 的**页眉/页脚/页码 → 页边区域**（批 B）。
//
// 取证（只读 `SYNO.Office.Snapshot:get` v4；13 份真实文档全量扫描）：
//
//   * `page_decorate.attrs = {num-pos:"br", num-show:false, num-cover:false,
//     num-even:false, place-show:false, place-cover:false, place-even:false}`
//     —— 7 个属性与 schema `doc_schema_generated.dart :: page_decorate.attrs`
//     逐字一致；`num-pos:"br"` = 页码在**页边右下方**。
//   * `page_decorate.content` 恒为：`header`×3（`type` = cover / even / normal）+
//     `footer`×3（同三种）+ `page_num`×1（`type:"normal"`，其下
//     `page_num_block → page_num_text`）。
//   * **真实样例的 header/footer 内容都是空 `paragraph`**（无可见文字）→
//     "页眉文字"本身没有真实素材，只能按已取证的**结构**渲染；测试用真实节点形状
//     + 注入文字（见 `test/fixtures/office_doc_tables/MANIFEST.json :: derived`）。
//   * 13 份样例里 `page` / `page_break` / `horizontal_rule` 节点**计数全为 0**
//     → 本阅读器是**连续流**（没有逐页内容边界，也不做逐像素分页算法）。
//
// 因此"页眉页脚印在页边区域、cover 不印在封面页"的落点是：
//   1. 装饰**不再进正文流**：渲染器把 `page_decorate` 从正文块里摘出来，
//      交给 [OfficeDocPageFrame]（页眉带在上边距、页脚带+页码在下边距）；
//   2. 装饰**按页型匹配**：连续流的正文帧 = [OfficeDocPageKind.normal]，
//      于是 `type:"cover"` / `type:"even"` 的页眉页脚**不印在正文页上**；
//      反过来 [OfficeDocPageKind.cover] 只取 `type:"cover"`。
//      跳过的装饰一律 `report.note` 登记（**不静默丢**）。
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// 一"页"的页型。真实样例只有 cover / even / normal 三种装饰；
/// 本阅读器是连续流，正文帧用 [normal]（`page`/`page_break` 样例为 0，见文件头）。
enum OfficeDocPageKind {
  cover,
  normal;

  /// 与 `header`/`footer`/`page_num` 的 `attrs.type` 对应的字符串。
  String get decorationType => this == OfficeDocPageKind.cover ? 'cover' : 'normal';
}

/// `page_decorate` 解析结果（**纯数据，可离线单测**）。
class OfficeDocDecorations {
  const OfficeDocDecorations({
    required this.headers,
    required this.footers,
    required this.pageNums,
    required this.numPosition,
    required this.notes,
  });

  /// `type` → 原文节点（`header`）。
  final Map<String, Object?> headers;

  /// `type` → 原文节点（`footer`）。
  final Map<String, Object?> footers;

  /// `type` → 原文节点（`page_num`）；`type` 缺失时键为 `''`（未取证形态）。
  final Map<String, Object?> pageNums;

  /// `attrs.num-pos`（真实 "br"）。
  final String numPosition;

  /// 解析中的如实登记（跳过的页型、缺少 type 等）。
  final List<String> notes;

  /// 解析 `page_decorate` 节点（内容不是 `page_decorate` 时返回空集合）。
  static OfficeDocDecorations parse(Object? node, {List<String>? notes}) {
    final out = <String>[];
    final headers = <String, Object?>{};
    final footers = <String, Object?>{};
    final pageNums = <String, Object?>{};
    var numPos = 'br';
    final map = node is Map ? node.cast<String, Object?>() : null;
    if (map != null && map['type'] != 'page_decorate') {
      out.add('传给页边装饰的不是 page_decorate 节点（${map['type']}）');
    }
    final attrs = map != null && map['attrs'] is Map
        ? (map['attrs']! as Map).cast<String, Object?>()
        : const <String, Object?>{};
    final rawPos = attrs['num-pos'];
    if (rawPos is String && rawPos.trim().isNotEmpty) numPos = rawPos.trim();
    // 真机模板 `num-show` / `place-show` 恒为 false，但节点确实存在（且需求要求
    // 显示真实页码）→ 本批**按节点存在**渲染，并把该观测如实登记，见
    // `docs/office-doc-render-batch-b.md`。
    if (attrs['num-show'] == false || attrs['place-show'] == false) {
      out.add(
        'page_decorate 的 num-show/place-show 为 false（真机模板默认值）：'
        '本批按装饰节点是否存在来渲染页眉页脚页码',
      );
    }
    for (final raw in (map?['content'] as List?) ?? const <Object?>[]) {
      if (raw is! Map) continue;
      final n = raw.cast<String, Object?>();
      final type = n['type'];
      if (type is! String) continue;
      final t = n['attrs'] is Map ? (n['attrs']! as Map)['type'] : null;
      final key = t is String ? t : '';
      switch (type) {
        case 'header':
          if (key.isEmpty) {
            out.add('header 缺少 attrs.type（未取证形态）→ 只登记，不印在正文页');
          }
          headers[key] = n;
        case 'footer':
          if (key.isEmpty) {
            out.add('footer 缺少 attrs.type（未取证形态）→ 只登记，不印在正文页');
          }
          footers[key] = n;
        case 'page_num':
          pageNums[key] = n;
        default:
          out.add('page_decorate 里有本批未处理的子节点：$type');
      }
    }
    if (notes != null) notes.addAll(out);
    return OfficeDocDecorations(
      headers: headers,
      footers: footers,
      pageNums: pageNums,
      numPosition: numPos,
      notes: out,
    );
  }

  /// 该页型应用的页眉节点。
  ///
  /// **cover 规则**：`normal` 帧**绝不**取 `type:"cover"`（反之亦然）；
  /// `even`（偶数页）在单帧连续流里没有对应页型 → 两者都不取。
  Object? headerFor(OfficeDocPageKind kind) => headers[kind.decorationType];

  /// 该页型应用的页脚节点（规则同 [headerFor]）。
  Object? footerFor(OfficeDocPageKind kind) => footers[kind.decorationType];

  /// 该页型应用的页码节点；`type` 缺失（键 `''`）时按"通用"处理。
  Object? pageNumFor(OfficeDocPageKind kind) =>
      pageNums[kind.decorationType] ?? pageNums[''];

  /// 被跳过的装饰（页型不匹配）的 `type` 列表 —— 供渲染器登记，不静默丢。
  List<String> skippedFor(OfficeDocPageKind kind) {
    final applied = kind.decorationType;
    final skipped = <String>[];
    for (final t in headers.keys) {
      if (t != applied && t.isNotEmpty) skipped.add('header($t)');
    }
    for (final t in footers.keys) {
      if (t != applied && t.isNotEmpty) skipped.add('footer($t)');
    }
    for (final t in pageNums.keys) {
      if (t.isNotEmpty && t != applied) skipped.add('page_num($t)');
    }
    return skipped;
  }
}

/// `num-pos` → 页边对齐（`t`/`b` + `l`/`c`/`r`，真实值 `"br"`）。
///
/// 认不出的写法回落右下角（真机默认）。
Alignment officeDocNumPositionAlignment(String pos) {
  final p = pos.trim().toLowerCase();
  final vertical = p.startsWith('t') ? -1.0 : 1.0;
  final h = p.length > 1 ? p[1] : 'r';
  final horizontal = switch (h) {
    'l' => -1.0,
    'c' => 0.0,
    _ => 1.0,
  };
  return Alignment(horizontal, vertical);
}

/// **页边区域**布局：页眉带（上边距）→ 正文 → 页脚带（下边距，含页码）。
///
/// 它只负责"把已经渲染好的页眉/页脚/页码放到页边"，不解析节点、不取字节。
class OfficeDocPageFrame extends StatelessWidget {
  const OfficeDocPageFrame({
    super.key,
    required this.body,
    this.header,
    this.footer,
    this.pageNumber,
    this.pageNumberAlignment = Alignment.bottomRight,
  });

  final Widget body;

  /// 页眉带内容；null = 该页型没有页眉（或不显示）。
  final Widget? header;

  /// 页脚带内容；null = 没有页脚。
  final Widget? footer;

  /// 页码；null = 该页型不显示页码。
  final Widget? pageNumber;

  /// 页码在页边区域的对齐（来自 `num-pos`，真实 "br"）。
  final Alignment pageNumberAlignment;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final hasFooterBand = footer != null || pageNumber != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null)
          Container(
            key: const Key('office-doc-page-header'),
            padding: const EdgeInsets.only(bottom: Gap.xs),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: t.colorScheme.outlineVariant),
              ),
            ),
            child: header,
          ),
        body,
        if (hasFooterBand)
          Container(
            key: const Key('office-doc-page-footer'),
            padding: const EdgeInsets.only(top: Gap.xs),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: t.colorScheme.outlineVariant),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?footer,
                if (pageNumber != null)
                  Align(
                    alignment: pageNumberAlignment,
                    child: pageNumber,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
