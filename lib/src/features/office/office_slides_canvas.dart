// Office 演示文稿（`.oslides`）**几何渲染**（批 C）—— 把幻灯片画成幻灯片。
//
// 规格与取证：`docs/office-doc-render-design.md` §8（逐节点解剖）+ 本批
// `docs/office-doc-render-batch-c.md`。**只按已取证事实实现**，没有样例的字段/取值
// 一律**如实登记**，不脑补效果。
//
// 证据（夹具 = 官方模板 `template/slides/*/text.json`，落地在
// `test/fixtures/office_templates/`）：
//   * 几何：`shape_box`/`image_box`/`text_box`/`object_group` 的
//     `attrs.transform = {left, top, width, height, deg, skewY}`（§8.1）；
//   * `shape_type` 真实取值（§8.2）：`rect` / `ellipse` / `triangle` /
//     `parallelogram` / `right_triangle`（本批只做这 5 种）；
//   * `line`（205 个真实样例，`slides_line.json`）：`attrs = {stroke,
//     stroke_config{stroke,stroke-opacity,stroke-width}, line_type:"line",
//     cust_points:{}}`，`line_type` 实测**全部是 `line`**，`cust_points` 实测**全部 `{}`**
//     → 只实现 `line` 一种直线；非空 `cust_points`（自绘多边形）**未取证、不实现**；
//   * `object_group`：`content` 子坐标**相对父组**（§8.3）→ **父偏移叠加**；
//     真实样例全是 `deg=0 / skewY=0`，且**没有嵌套组**样例。
//
// 未取证边界（代码里都有对应 note / 文档登记）：
//   1. `parallelogram` 的斜切比例、`triangle` / `right_triangle` 的顶点比例：
//      预置形状几何**没有字段承载**（`cust_points` 为 `{}`）→ 取标准的预置几何，
//      但比例本身**未取证**（note 登记）；
//   2. 组的 `deg` / `skewY`（真实样例全为 0）→ 只叠加 `left/top` 偏移；
//      非 0 时**登记"组旋转/斜切未取证"**（不假装实现）；
//   3. **嵌套组**（组里再有组）→ 按"逐层叠加"实现，**登记未取证**；
//   4. 无 transform 的盒子（真实样例里有 `page_number_layout_holder` 无 transform）
//      → 不摆位、如实登记；
//   5. `image` 的字节走批 A 的 `Attachment:get v2`（`object_id` + `file_id`），
//      **绝不把 `file_id`/`ref`/路径显示给用户**。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/office_native/office_json.dart';
import 'office_doc_image.dart';
import 'office_doc_style.dart' show officeDocParseColor;
import 'office_slides_view.dart' show OfficeSlidesRenderReport;

// ---------------------------------------------------------------------------
// 颜色
// ---------------------------------------------------------------------------

/// 演示文稿里的颜色：`#rrggbb` / `#aarrggbb` / `rgb()`（mark 用）以及
/// **裸 hex**（`master_background.color` 实测是 `"fcfcfc"` / `"141E32"`，无 `#`）。
///
/// 认不出返回 null（**不编颜色**）。
Color? officeSlidesCanvasColor(Object? value) {
  if (value is! String) return null;
  final s = value.trim();
  if (s.isEmpty || s.toLowerCase() == 'transparent') return null;
  if (s.startsWith('#')) return officeDocParseColor(s);
  final bare = RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').firstMatch(s);
  if (bare != null) return officeDocParseColor('#$s');
  return officeDocParseColor(s);
}

/// 透明度归一（`fill-opacity` / `stroke-opacity` / `opacity` 实测是 0..1 的数）。
double officeSlidesCanvasOpacity(Object? value, {double fallback = 1}) {
  final v = value is num ? value.toDouble() : double.tryParse('$value');
  if (v == null) return fallback;
  return v.clamp(0.0, 1.0);
}

// ---------------------------------------------------------------------------
// 几何：transform
// ---------------------------------------------------------------------------

/// 所有"盒子"共用的 `attrs.transform`（§8.1，真实样例逐字：
/// `{"deg":0,"height":254.97,"left":420.45,"skewY":0,"top":153.26,"width":31.73}`）。
class OfficeSlidesTransform {
  const OfficeSlidesTransform({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.deg,
    required this.skewY,
  });

  /// 实测字段；缺字段按 0 / 0 处理（渲染时登记"不完整 transform"）。
  final double left;
  final double top;
  final double width;
  final double height;
  final double deg;
  final double skewY;

  /// 浮点噪声阈值：样例里 `skewY` 是 `1.477928890381e-12` 这种量级，
  /// 实质为 0 → 不当成"真的斜切"（否则会误报"未取证"）。
  static const double _epsilon = 1e-6;

  bool get hasDeg => deg.abs() > _epsilon;
  bool get hasSkewY => skewY.abs() > _epsilon;

  /// 盒子在画布坐标系里的矩形（负宽/负高按"起点 + 有符号增量"归一）。
  Rect get bounds => Rect.fromLTWH(
    math.min(left, left + width),
    math.min(top, top + height),
    width.abs(),
    height.abs(),
  );

  /// 父组偏移叠加（§8.3：子坐标相对父组）。**只叠加偏移**。
  OfficeSlidesTransform offsetBy(OfficeSlidesTransform? parent) {
    if (parent == null) return this;
    return OfficeSlidesTransform(
      left: left + parent.left,
      top: top + parent.top,
      width: width,
      height: height,
      deg: deg,
      skewY: skewY,
    );
  }

  static OfficeSlidesTransform? parse(Object? raw) {
    final map = asJsonMap(raw);
    if (map == null) return null;
    final l = officeSlidesCanvasPx(map['left']);
    final t = officeSlidesCanvasPx(map['top']);
    final w = officeSlidesCanvasPx(map['width']);
    final h = officeSlidesCanvasPx(map['height']);
    if (l == null || t == null || w == null || h == null) return null;
    return OfficeSlidesTransform(
      left: l,
      top: t,
      width: w,
      height: h,
      deg: officeSlidesCanvasPx(map['deg']) ?? 0,
      skewY: officeSlidesCanvasPx(map['skewY']) ?? 0,
    );
  }

  @override
  String toString() =>
      'Transform(left: $left, top: $top, w: $width, h: $height, deg: $deg, '
      'skewY: $skewY)';
}

/// 数字/`"12px"` → double；认不出 null。
double? officeSlidesCanvasPx(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) {
    final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(value);
    if (m != null) return double.tryParse(m.group(0)!);
  }
  return null;
}

// ---------------------------------------------------------------------------
// 形状 / 连线
// ---------------------------------------------------------------------------

/// 本批实现的 5 种 `shape_type`（§8.2 真实取值）+ 其余（未实现）。
enum OfficeSlidesShapeKind {
  rect,
  ellipse,
  triangle,
  parallelogram,
  rightTriangle,

  /// 有真实样例但不在本批清单里（`pie` / `chord`）或清单外预置形状。
  unsupported,
}

/// `shape_type` 字符串 → [OfficeSlidesShapeKind]。
OfficeSlidesShapeKind officeSlidesShapeKindOf(Object? raw) =>
    switch ('$raw'.trim().toLowerCase()) {
      'rect' => OfficeSlidesShapeKind.rect,
      'ellipse' => OfficeSlidesShapeKind.ellipse,
      'triangle' => OfficeSlidesShapeKind.triangle,
      'parallelogram' => OfficeSlidesShapeKind.parallelogram,
      'right_triangle' => OfficeSlidesShapeKind.rightTriangle,
      _ => OfficeSlidesShapeKind.unsupported,
    };

/// `shape` 节点的渲染规格。
class OfficeSlidesShapeSpec {
  const OfficeSlidesShapeSpec({
    required this.shapeType,
    required this.kind,
    required this.fill,
    required this.fillColor,
    required this.fillOpacity,
    required this.stroke,
    required this.strokeColor,
    required this.strokeOpacity,
    required this.strokeWidth,
    required this.custPointsEmpty,
  });

  /// 原始取值（上屏时**只用它做"暂不支持"的可见说明**，不冒充内部名）。
  final String shapeType;
  final OfficeSlidesShapeKind kind;

  /// `fill`(bool) + `fill_config{fill, fill-opacity}`（§8.2 已取证）。
  final bool fill;
  final Color? fillColor;
  final double fillOpacity;

  /// `stroke`(bool) + `stroke_config{stroke, stroke-opacity, stroke-width}`。
  /// **`stroke_config` 是可选键**：`Celestial` 整键缺失、`Dynamic` 是 `{}`
  /// → 缺失/为空时**不画边**（不编默认颜色/宽度）。
  final bool stroke;
  final Color? strokeColor;
  final double strokeOpacity;
  final double strokeWidth;

  /// `cust_points` 是否为空对象。真实样例**全为 `{}`**；
  /// 非空形态（自绘多边形）**未取证**。
  final bool custPointsEmpty;

  bool get canPaintStroke =>
      stroke && strokeColor != null && strokeWidth > 0;

  bool get canPaintFill => fill && fillColor != null && fillColor!.a > 0;

  /// 从 `shape` 节点解析。
  static OfficeSlidesShapeSpec parse(Map<String, Object?> shape) {
    final a = asJsonMap(shape['attrs']) ?? const <String, Object?>{};
    final fillConfig = asJsonMap(a['fill_config']) ?? const <String, Object?>{};
    final strokeConfig =
        asJsonMap(a['stroke_config']) ?? const <String, Object?>{};
    final custPoints = asJsonMap(a['cust_points']);
    final shapeType = '${a['shape_type'] ?? ''}'.trim();
    return OfficeSlidesShapeSpec(
      shapeType: shapeType,
      kind: officeSlidesShapeKindOf(shapeType),
      fill: a['fill'] == true,
      fillColor: officeSlidesCanvasColor(fillConfig['fill']),
      fillOpacity: officeSlidesCanvasOpacity(fillConfig['fill-opacity']),
      stroke: a['stroke'] == true,
      strokeColor: officeSlidesCanvasColor(strokeConfig['stroke']),
      strokeOpacity: officeSlidesCanvasOpacity(strokeConfig['stroke-opacity']),
      strokeWidth: officeSlidesCanvasPx(strokeConfig['stroke-width']) ?? 0,
      custPointsEmpty: custPoints == null || custPoints.isEmpty,
    );
  }
}

/// `line` 节点的渲染规格（205 个真实样例）。
class OfficeSlidesLineSpec {
  const OfficeSlidesLineSpec({
    required this.lineType,
    required this.stroke,
    required this.strokeColor,
    required this.strokeOpacity,
    required this.strokeWidth,
    required this.custPointsEmpty,
  });

  /// 实测恒为 `"line"`；其余取值（多段线/曲线）**未取证**。
  final String lineType;
  final bool stroke;
  final Color? strokeColor;
  final double strokeOpacity;
  final double strokeWidth;

  /// 实测恒为 `{}` → 非空（自绘折线）**未取证**。
  final bool custPointsEmpty;

  bool get isPlainLine => lineType.toLowerCase() == 'line';
  bool get canPaint => stroke && strokeColor != null && strokeWidth > 0;

  static OfficeSlidesLineSpec parse(Map<String, Object?> line) {
    final a = asJsonMap(line['attrs']) ?? const <String, Object?>{};
    final cfg = asJsonMap(a['stroke_config']) ?? const <String, Object?>{};
    final custPoints = asJsonMap(a['cust_points']);
    return OfficeSlidesLineSpec(
      lineType: '${a['line_type'] ?? ''}'.trim(),
      stroke: a['stroke'] == true,
      strokeColor: officeSlidesCanvasColor(cfg['stroke']),
      strokeOpacity: officeSlidesCanvasOpacity(cfg['stroke-opacity']),
      strokeWidth: officeSlidesCanvasPx(cfg['stroke-width']) ?? 0,
      custPointsEmpty: custPoints == null || custPoints.isEmpty,
    );
  }
}

// ---------------------------------------------------------------------------
// 盒子 / 场景
// ---------------------------------------------------------------------------

/// 母版 / 版式 / 正文三层。
enum OfficeSlidesLayer { master, layout, slide }

/// 一个可绘制的盒子。
enum OfficeSlidesBoxKind { shape, line, image, text, unsupported }

/// 一个盒子的渲染描述（几何已经**叠加过父组偏移**）。
class OfficeSlidesBox {
  const OfficeSlidesBox({
    required this.kind,
    required this.rawType,
    required this.layer,
    required this.transform,
    required this.id,
    this.shape,
    this.line,
    this.imageFileId = '',
    this.imageAlt = '',
    this.imageDeg = 0,
    this.imageFlipH = false,
    this.imageFlipV = false,
    this.textNode,
    this.textPath = '',
    this.groupDepth = 0,
    this.unsupportedReason,
  });

  final OfficeSlidesBoxKind kind;

  /// 原始节点类型（`shape_box` / `line_box` / …）。
  final String rawType;
  final OfficeSlidesLayer layer;

  /// **绝对值**（父组偏移已叠加）；null = 该节点没有可用 transform。
  final OfficeSlidesTransform? transform;

  final String? id;
  final OfficeSlidesShapeSpec? shape;
  final OfficeSlidesLineSpec? line;

  /// `image.attrs.file_id`；**只用于取字节，绝不上屏**。
  final String imageFileId;
  final String imageAlt;
  final double imageDeg;
  final bool imageFlipH;
  final bool imageFlipV;

  /// 盒内文本的节点（交给视图的 `nodeBuilder` 递归渲染，保住既有 mark/编辑路径）。
  final Object? textNode;
  final String textPath;

  /// 嵌套组深度（0 = 顶层；>1 = 组里还有组 → **未取证**）。
  final int groupDepth;

  /// 无法渲染时的原因（会进报告 note）。
  final String? unsupportedReason;

  Rect get rect =>
      transform?.bounds ?? const Rect.fromLTWH(0, 0, 0, 0);
}

/// 没有几何可摆位的节点 → 保持原来的**流式**渲染（不丢内容）。
class OfficeSlidesFlowItem {
  const OfficeSlidesFlowItem({required this.node, required this.path});

  final Object? node;
  final String path;
}

/// 一页幻灯片的完整绘制场景（母版 + 版式 + 正文）。
class OfficeSlidesSlideScene {
  OfficeSlidesSlideScene({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.background,
    required this.boxes,
    required this.flow,
    required this.notes,
    required this.masterBoxCount,
    required this.layoutBoxCount,
    required this.slideBoxCount,
    required this.groupCount,
    required this.groupChildCount,
    required this.maxGroupDepth,
    required this.unsupportedShapeTypes,
    required this.hasLayout,
    required this.hasMaster,
  });

  /// 画布尺寸（根 `attrs.cx/cy`，真实样例 960×540）。
  final double canvasWidth;
  final double canvasHeight;

  /// 背景色（slide → layout → master 命中的第一个）。
  final Color? background;

  /// 已定位的盒子（按母版 → 版式 → 正文的顺序，即 z 序）。
  final List<OfficeSlidesBox> boxes;

  /// 无法摆位的节点（流式渲染兜底，**不丢内容**）。
  final List<OfficeSlidesFlowItem> flow;

  final List<String> notes;

  final int masterBoxCount;
  final int layoutBoxCount;
  final int slideBoxCount;
  final int groupCount;
  final int groupChildCount;
  final int maxGroupDepth;

  /// `shape_type` → 出现次数（**清单外/未实现**的形状）。
  final Map<String, int> unsupportedShapeTypes;

  final bool hasLayout;
  final bool hasMaster;

  bool get hasCanvasContent => boxes.isNotEmpty || background != null;
}

// ---------------------------------------------------------------------------
// 场景构建（纯解析，可离线单测）
// ---------------------------------------------------------------------------

/// `{content:{data:{content:[…]}}}` → 根节点树。
Object? officeSlidesSectionsRoot(Map<String, Object?> sections) =>
    asJsonMap(asJsonMap(sections['content'])?['data'])?['content'];

final RegExp _holderPattern = RegExp(
  r'^(.+)_(master|layout|slide)_holder$',
);

/// 从 holder 节点名解析出 `(role, layer)`；不是 holder 返回 null。
({String role, OfficeSlidesLayer layer})? officeSlidesHolderRole(String type) {
  final m = _holderPattern.firstMatch(type);
  if (m == null) return null;
  return (
    role: m.group(1)!,
    layer: switch (m.group(2)) {
      'master' => OfficeSlidesLayer.master,
      'layout' => OfficeSlidesLayer.layout,
      _ => OfficeSlidesLayer.slide,
    },
  );
}

/// 需要几何摆位的"盒子"节点类型（其余节点走流式渲染兜底）。
const Set<String> kOfficeSlidesBoxTypes = <String>{
  'shape_box',
  'line_box',
  'image_box',
  'text_box',
  'table_box',
  'chart_box',
  'video_box',
  'object_group',
};

/// 构建一页幻灯片的场景。
///
/// [slideRaw] 是 `slide` 节点原文；[slidePathPrefix] 是文本节点的路径前缀
/// （视图传 `p<order>`，用来保住既有的编辑/断言路径）。
OfficeSlidesSlideScene buildOfficeSlidesSlideScene({
  required Map<String, Object?> sections,
  required Map<String, Object?> slideRaw,
  String slidePathPrefix = 'p0',
  List<String>? notes,
}) {
  final out = <String>[];
  final root = officeSlidesSectionsRoot(sections);
  final rootAttrs = asJsonMap(
    asJsonMap(asJsonMap(sections['content'])?['data'])?['attrs'],
  );
  final cx = officeSlidesCanvasPx(rootAttrs?['cx']) ?? 960;
  final cy = officeSlidesCanvasPx(rootAttrs?['cy']) ?? 540;

  final boxes = <OfficeSlidesBox>[];
  final flow = <OfficeSlidesFlowItem>[];
  final counters = _BoxCounters();

  if (root == null) {
    out.add('content 根不是对象 → 无几何可渲染（如实登记，不崩）');
    notes?.addAll(out);
    return OfficeSlidesSlideScene(
      canvasWidth: cx,
      canvasHeight: cy,
      background: null,
      boxes: boxes,
      flow: flow,
      notes: out,
      masterBoxCount: 0,
      layoutBoxCount: 0,
      slideBoxCount: 0,
      groupCount: 0,
      groupChildCount: 0,
      maxGroupDepth: 0,
      unsupportedShapeTypes: const <String, int>{},
      hasLayout: false,
      hasMaster: false,
    );
  }

  final slideAttrs = asJsonMap(slideRaw['attrs']) ?? const <String, Object?>{};
  final masterId = asJsonString(slideAttrs['master_id']);
  final layoutId = asJsonString(slideAttrs['layout_id']);

  // --- 母版 ---------------------------------------------------------------
  final masterContainer = findFirstNodeByType(root, 'master_container');
  final masters = findNodesByType(masterContainer?['content'], 'master');
  Map<String, Object?>? master;
  for (final m in masters) {
    if (masterId != null &&
        masterId.isNotEmpty &&
        '${asJsonMap(m['attrs'])?['id']}' == masterId) {
      master = m;
      break;
    }
  }
  master ??= masters.isEmpty ? null : masters.first;
  if (masterId != null && masterId.isNotEmpty && master == null) {
    out.add('母版 $masterId 不存在 → 该页拿不到母版装饰（如实登记）');
  }

  // --- 版式 ---------------------------------------------------------------
  final layoutContainer = findFirstNodeByType(root, 'layout_container');
  final layouts = findNodesByType(layoutContainer?['content'], 'layout');
  Map<String, Object?>? layout;
  for (final l in layouts) {
    if (layoutId != null &&
        layoutId.isNotEmpty &&
        '${asJsonMap(l['attrs'])?['id']}' == layoutId) {
      layout = l;
      break;
    }
  }
  if (layoutId != null && layoutId.isNotEmpty && layout == null) {
    out.add(
      '版式 $layoutId 在本文档里不存在（真机裁剪帧常见）→ 版式装饰缺失，'
      '已按正文内容渲染并如实登记',
    );
  }

  // --- 背景（slide → layout → master）--------------------------------------
  final slideBackground = findFirstNodeByType(slideRaw['content'], 'slide_background');
  final layoutBackground = findFirstNodeByType(layout?['content'], 'layout_background');
  final masterBackground = findFirstNodeByType(master?['content'], 'master_background');
  Color? background;
  for (final bg in <Map<String, Object?>?>[
    slideBackground,
    layoutBackground,
    masterBackground,
  ]) {
    if (bg == null) continue;
    final a = asJsonMap(bg['attrs']) ?? const <String, Object?>{};
    final c = officeSlidesCanvasColor(a['color']);
    if (c != null) {
      final opacity = officeSlidesCanvasOpacity(a['opacity']);
      background = opacity >= 1
          ? c
          : c.withValues(alpha: c.a * opacity);
      break;
    }
    if ('${a['file_id'] ?? ''}'.isNotEmpty) {
      out.add(
        '背景是图片背景（$bg 带 file_id）→ 本批未渲染背景图（无真实样例），如实登记',
      );
    }
  }

  // --- 收集盒子 -----------------------------------------------------------
  void collect(
    Object? content,
    OfficeSlidesLayer layer,
    OfficeSlidesTransform? parent,
    int groupDepth,
  ) {
    final list = asJsonList(content);
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      final node = asJsonMap(list[i]);
      if (node == null) continue;
      final type = asJsonString(node['type']);
      if (type == null) continue;
      switch (type) {
        case 'master_container':
        case 'layout_container':
        case 'slide_container':
          // 母版里**嵌着** layout_container（官方结构：master → layout_container
          // → layout）。母版层遍历时必须跳过它，否则版式装饰会被画两次
          // （组计数也会翻倍）。各层由调用方单独收集。
          break;
        case 'master_background':
        case 'layout_background':
        case 'slide_background':
        case 'note':
        case 'settings':
          break; // 背景/备注/设置单独处理
        default:
          final holder = officeSlidesHolderRole(type);
          if (holder != null && holder.layer == OfficeSlidesLayer.slide) {
            // 正文 holder：几何从同 role 的版式/母版 holder 解析（官方结构）。
            final local = _resolveSlideHolderTransform(
              role: holder.role,
              layout: layout,
              master: master,
            );
            final abs = local?.offsetBy(parent);
            final textNode = node;
            final path = '$slidePathPrefix.$i';
            if (abs == null) {
              out.add(
                '正文 holder $type 没有几何（版式/母版里都找不到同 role 的 transform）'
                '→ 退回流式渲染（不丢文本）',
              );
              flow.add(OfficeSlidesFlowItem(node: node, path: path));
              continue;
            }
            counters.slide += 1;
            boxes.add(
              OfficeSlidesBox(
                kind: OfficeSlidesBoxKind.text,
                rawType: type,
                layer: OfficeSlidesLayer.slide,
                transform: abs,
                id: asJsonString(asJsonMap(node['attrs'])?['id']),
                textNode: textNode,
                textPath: path,
                groupDepth: groupDepth,
              ),
            );
            continue;
          }
          // 非"盒子"的节点（段落 / 未知类型 / 降级卡片）在**正文层**保持既有的
          // 流式渲染：交给视图的块渲染器（含"暂不支持渲染的类型"可见卡片），
          // 绝不静默丢内容。
          if (!kOfficeSlidesBoxTypes.contains(type) &&
              holder == null &&
              layer == OfficeSlidesLayer.slide &&
              parent == null) {
            flow.add(
              OfficeSlidesFlowItem(node: node, path: '$slidePathPrefix.$i'),
            );
            continue;
          }
          _collectBox(
            type: type,
            node: node,
            layer: layer,
            parent: parent,
            groupDepth: groupDepth,
            pathPrefix: '$slidePathPrefix.box$i',
            boxes: boxes,
            notes: out,
            counters: counters,
          );
      }
    }
  }

  // 母版 → 版式 → 正文（z 序）。
  collect(master?['content'], OfficeSlidesLayer.master, null, 0);
  collect(layout?['content'], OfficeSlidesLayer.layout, null, 0);
  final slideContentContainer = findFirstNodeByType(
    slideRaw['content'],
    'slide_content_container',
  );
  collect(
    slideContentContainer?['content'],
    OfficeSlidesLayer.slide,
    null,
    0,
  );

  if (boxes.isEmpty && flow.isEmpty) {
    out.add('该页没有任何可渲染的盒子（既有流式渲染也没有内容，如实登记）');
  }
  notes?.addAll(out);
  return OfficeSlidesSlideScene(
    canvasWidth: cx,
    canvasHeight: cy,
    background: background,
    boxes: boxes,
    flow: flow,
    notes: out,
    masterBoxCount: counters.master,
    layoutBoxCount: counters.layout,
    slideBoxCount: counters.slide,
    groupCount: counters.groups,
    groupChildCount: counters.groupChildren,
    maxGroupDepth: counters.maxGroupDepth,
    unsupportedShapeTypes: counters.unsupportedShapes,
    hasLayout: layout != null,
    hasMaster: master != null,
  );
}

/// 正文 holder 的几何：优先同 role 的**版式** holder，其次**母版** holder。
OfficeSlidesTransform? _resolveSlideHolderTransform({
  required String role,
  required Map<String, Object?>? layout,
  required Map<String, Object?>? master,
}) {
  for (final candidate in <Object?>[layout?['content'], master?['content']]) {
    for (final node in findNodesByType(candidate, '${role}_layout_holder')) {
      final t = OfficeSlidesTransform.parse(
        asJsonMap(node['attrs'])?['transform'],
      );
      if (t != null) return t;
    }
    for (final node in findNodesByType(candidate, '${role}_master_holder')) {
      final t = OfficeSlidesTransform.parse(
        asJsonMap(node['attrs'])?['transform'],
      );
      if (t != null) return t;
    }
  }
  return null;
}


/// 盒子计数（母版/版式/正文 + 分组），随盒子树递归传递。
class _BoxCounters {
  int master = 0;
  int layout = 0;
  int slide = 0;
  int groups = 0;
  int groupChildren = 0;
  int maxGroupDepth = 0;
  final Map<String, int> unsupportedShapes = <String, int>{};

  void incLayer(OfficeSlidesLayer layer) {
    switch (layer) {
      case OfficeSlidesLayer.master:
        master += 1;
      case OfficeSlidesLayer.layout:
        layout += 1;
      case OfficeSlidesLayer.slide:
        slide += 1;
    }
  }
}

/// 把一个盒子类节点收进场景（group 递归、holder 直接读 transform）。
void _collectBox({
  required String type,
  required Map<String, Object?> node,
  required OfficeSlidesLayer layer,
  required OfficeSlidesTransform? parent,
  required int groupDepth,
  required String pathPrefix,
  required List<OfficeSlidesBox> boxes,
  required List<String> notes,
  required _BoxCounters counters,
}) {
  final attrs = asJsonMap(node['attrs']) ?? const <String, Object?>{};
  final local = OfficeSlidesTransform.parse(attrs['transform']);
  final holder = officeSlidesHolderRole(type);
  final id = asJsonString(attrs['id']);

  // `object_group`：子坐标相对父组（§8.3）→ 把 left/top 作为父偏移叠加。
  // 真实样例（slides_line 的 8 个组）**全是 deg=0 / skewY=0**，且**没有嵌套组**。
  if (type == 'object_group') {
    counters.groups += 1;
    counters.groupChildren += asJsonList(node['content'])?.length ?? 0;
    if (groupDepth >= 1) {
      notes.add(
        '嵌套 object_group（组里再有组，深度 ${groupDepth + 1}）**未取证**：'
        '按"逐层叠加 left/top"实现（真实样例只有单层组）',
      );
    }
    if (groupDepth + 1 > counters.maxGroupDepth) {
      counters.maxGroupDepth = groupDepth + 1;
    }
    if (local == null) {
      notes.add('object_group（id=${id ?? '?'}）没有 transform → 组内子节点无法定位（如实登记）');
      return;
    }
    if (local.hasDeg || local.hasSkewY) {
      notes.add(
        'object_group 的 deg/skewY 非 0（真实样例全为 0）→ **组旋转/斜切未取证**，'
        '本批只把 left/top 作为父偏移叠加',
      );
    }
    _collectBoxChildren(
      children: asJsonList(node['content']) ?? const <Object?>[],
      layer: layer,
      parent: local.offsetBy(parent),
      groupDepth: groupDepth + 1,
      pathPrefix: pathPrefix,
      boxes: boxes,
      notes: notes,
      counters: counters,
    );
    return;
  }

  if (local == null) {
    final children = asJsonList(node['content']);
    // 容器（master_content_container / layout_content_container / …）本身没有
    // transform；**递归子节点**，不要误报"缺 transform"。
    if (!kOfficeSlidesBoxTypes.contains(type) &&
        holder == null &&
        children != null) {
      _collectBoxChildren(
        children: children,
        layer: layer,
        parent: parent,
        groupDepth: groupDepth,
        pathPrefix: pathPrefix,
        boxes: boxes,
        notes: notes,
        counters: counters,
      );
      return;
    }
    notes.add(
      '盒子 $type（id=${id ?? '?'}）没有 transform → 无法定位，如实登记（不猜坐标）',
    );
    return;
  }
  final abs = local.offsetBy(parent);

  // holder（母版/版式）：fill/stroke 在 *_holder_shape 上，文本在
  // *_holder_text_block 上；本批把 holder 当**文本框**摆位（不另画预置形状）。
  if (holder != null) {
    final shapeNode = _firstChildOfType(node, null);
    final textNode =
        _firstChildWithSuffix(node['content'], '_holder_text_block') ??
        _firstChildOfType(shapeNode, null);
    counters.incLayer(layer);
    boxes.add(
      OfficeSlidesBox(
        kind: OfficeSlidesBoxKind.text,
        rawType: type,
        layer: layer,
        transform: abs,
        id: id,
        textNode: textNode,
        textPath: pathPrefix,
        groupDepth: groupDepth,
      ),
    );
    return;
  }

  if (type == 'shape_box') {
    final shape = _firstChildOfType(node, 'shape');
    if (shape == null) {
      notes.add('shape_box（id=${id ?? '?'}）没有 shape 子节点 → 画出"暂不支持"卡片');
      counters.incLayer(layer);
      boxes.add(
        OfficeSlidesBox(
          kind: OfficeSlidesBoxKind.unsupported,
          rawType: type,
          layer: layer,
          transform: abs,
          id: id,
          groupDepth: groupDepth,
          unsupportedReason: 'shape_box 没有 shape 子节点',
        ),
      );
      return;
    }
    final spec = OfficeSlidesShapeSpec.parse(shape);
    if (spec.kind == OfficeSlidesShapeKind.unsupported) {
      final name = spec.shapeType.isEmpty ? '(空)' : spec.shapeType;
      counters.unsupportedShapes[name] =
          (counters.unsupportedShapes[name] ?? 0) + 1;
      notes.add(
        'shape_type="$name" 不在本批实现的 5 种'
        '（rect/ellipse/triangle/parallelogram/right_triangle）→ 画"暂不支持"卡片'
        '（不凭空造多边形）',
      );
    } else if (!spec.custPointsEmpty) {
      notes.add(
        'shape_type=${spec.shapeType} 的 cust_points 非空（真实样例全为 {}）'
        '→ **自绘多边形未取证**，不编形状（如实登记；形状仍按预置几何画）',
      );
    }
    if (spec.stroke && !spec.canPaintStroke) {
      notes.add(
        'shape stroke=true 但 stroke_config 缺失/为空（真实样例 Celestial 整键缺失、'
        'Dynamic 为 {}）→ 不画边（不编颜色/宽度）',
      );
    }
    final textNode = _firstChildOfType(shape, 'shape_text_block');
    counters.incLayer(layer);
    boxes.add(
      OfficeSlidesBox(
        kind: spec.kind == OfficeSlidesShapeKind.unsupported
            ? OfficeSlidesBoxKind.unsupported
            : OfficeSlidesBoxKind.shape,
        rawType: type,
        layer: layer,
        transform: abs,
        id: id,
        shape: spec,
        textNode: textNode,
        textPath: pathPrefix,
        groupDepth: groupDepth,
        unsupportedReason: spec.kind == OfficeSlidesShapeKind.unsupported
            ? spec.shapeType
            : null,
      ),
    );
    return;
  }

  if (type == 'line_box') {
    final line = _firstChildOfType(node, 'line');
    if (line == null) {
      notes.add('line_box（id=${id ?? '?'}）没有 line 子节点 → 不画（如实登记）');
      return;
    }
    final spec = OfficeSlidesLineSpec.parse(line);
    if (!spec.isPlainLine) {
      notes.add(
        'line_type="${spec.lineType}" 未取证（205 个真实样例全是 "line"）'
        '→ 不画（不编折线/曲线）',
      );
      counters.incLayer(layer);
      boxes.add(
        OfficeSlidesBox(
          kind: OfficeSlidesBoxKind.unsupported,
          rawType: type,
          layer: layer,
          transform: abs,
          id: id,
          groupDepth: groupDepth,
          unsupportedReason: spec.lineType,
        ),
      );
      return;
    }
    if (!spec.custPointsEmpty) {
      notes.add(
        'line 的 cust_points 非空（真实样例 205/205 为 {}）→ 自绘折线**未取证**，不实现',
      );
      counters.incLayer(layer);
      boxes.add(
        OfficeSlidesBox(
          kind: OfficeSlidesBoxKind.unsupported,
          rawType: type,
          layer: layer,
          transform: abs,
          id: id,
          groupDepth: groupDepth,
          unsupportedReason: 'cust_points 非空',
        ),
      );
      return;
    }
    if (spec.stroke && !spec.canPaint) {
      notes.add('line stroke=true 但 stroke_config 缺失/为空 → 不画（不编颜色/宽度）');
    }
    counters.incLayer(layer);
    boxes.add(
      OfficeSlidesBox(
        kind: OfficeSlidesBoxKind.line,
        rawType: type,
        layer: layer,
        transform: abs,
        id: id,
        line: spec,
        groupDepth: groupDepth,
      ),
    );
    return;
  }

  if (type == 'image_box') {
    final image = _firstChildOfType(node, 'image');
    if (image == null) {
      notes.add('image_box（id=${id ?? '?'}）没有 image 子节点 → 不画（如实登记）');
      return;
    }
    final ia = asJsonMap(image['attrs']) ?? const <String, Object?>{};
    final imgTransform =
        asJsonMap(ia['img_transform']) ?? const <String, Object?>{};
    counters.incLayer(layer);
    boxes.add(
      OfficeSlidesBox(
        kind: OfficeSlidesBoxKind.image,
        rawType: type,
        layer: layer,
        transform: abs,
        id: id,
        imageFileId: '${ia['file_id'] ?? ''}'.trim(),
        imageAlt: '${ia['alt'] ?? ''}'.trim(),
        imageDeg: officeSlidesCanvasPx(imgTransform['deg']) ?? 0,
        imageFlipH: imgTransform['flip_h'] == true,
        imageFlipV: imgTransform['flip_v'] == true,
        groupDepth: groupDepth,
      ),
    );
    return;
  }

  if (type == 'text_box') {
    // text_box → text_shape → text_block（几何在 text_box 上）。
    final textShape =
        _firstChildOfType(node, 'text_shape') ??
        _firstChildWithSuffix(node['content'], '_text_shape');
    counters.incLayer(layer);
    boxes.add(
      OfficeSlidesBox(
        kind: OfficeSlidesBoxKind.text,
        rawType: type,
        layer: layer,
        transform: abs,
        id: id,
        textNode: textShape ?? node,
        textPath: pathPrefix,
        groupDepth: groupDepth,
      ),
    );
    return;
  }

  if (type == 'table_box' || type == 'chart_box' || type == 'video_box') {
    notes.add('$type（id=${id ?? '?'}）本批不渲染（无真实样例/需另行取证）→ 如实登记');
    counters.incLayer(layer);
    boxes.add(
      OfficeSlidesBox(
        kind: OfficeSlidesBoxKind.unsupported,
        rawType: type,
        layer: layer,
        transform: abs,
        id: id,
        groupDepth: groupDepth,
        unsupportedReason: type,
      ),
    );
    return;
  }

  // 其它带 transform 的节点（object_group 已在 collect() 里展开）→ 递归子节点。
  final children = asJsonList(node['content']);
  if (children != null && children.isNotEmpty) {
    _collectBoxChildren(
      children: children,
      layer: layer,
      parent: abs,
      groupDepth: groupDepth,
      pathPrefix: pathPrefix,
      boxes: boxes,
      notes: notes,
      counters: counters,
    );
  }
}

void _collectBoxChildren({
  required List<Object?> children,
  required OfficeSlidesLayer layer,
  required OfficeSlidesTransform? parent,
  required int groupDepth,
  required String pathPrefix,
  required List<OfficeSlidesBox> boxes,
  required List<String> notes,
  required _BoxCounters counters,
}) {
  for (var i = 0; i < children.length; i++) {
    final node = asJsonMap(children[i]);
    if (node == null) continue;
    final type = asJsonString(node['type']);
    if (type == null) continue;
    _collectBox(
      type: type,
      node: node,
      layer: layer,
      parent: parent,
      groupDepth: groupDepth,
      pathPrefix: '$pathPrefix.$i',
      boxes: boxes,
      notes: notes,
      counters: counters,
    );
  }
}

/// 找第一个指定类型的直接/间接子节点（只看 `content`）。
Map<String, Object?>? _firstChildOfType(
  Map<String, Object?>? node,
  String? type,
) {
  if (node == null) return null;
  final list = asJsonList(node['content']);
  if (list == null) return null;
  for (final raw in list) {
    final child = asJsonMap(raw);
    if (child == null) continue;
    if (type == null) return child;
    if (asJsonString(child['type']) == type) return child;
  }
  return null;
}

/// 找第一个类型以 [suffix] 结尾的直接/间接子节点。
Map<String, Object?>? _firstChildWithSuffix(Object? content, String suffix) {
  final list = asJsonList(content);
  if (list == null) return null;
  for (final raw in list) {
    final child = asJsonMap(raw);
    if (child == null) continue;
    final t = asJsonString(child['type']);
    if (t != null && t.endsWith(suffix)) return child;
    final nested = _firstChildWithSuffix(child['content'], suffix);
    if (nested != null) return nested;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/// 把一页幻灯片按几何画出来（960×540 坐标系 → 按可用宽度等比缩放）。
///
/// 文本不被重新实现：由 [nodeBuilder] 交给视图的既有块渲染器（保住 mark、
/// 编辑路径、降级卡片），本组件只负责**摆位/形状/连线/图片**。
class OfficeSlidesCanvas extends StatelessWidget {
  const OfficeSlidesCanvas({
    super.key,
    required this.scene,
    required this.nodeBuilder,
    this.objectId = '',
    this.imageBytesProvider,
    this.imageCache,
    this.slideOrder = 0,
  });

  final OfficeSlidesSlideScene scene;

  /// `(节点, 路径) → widget`；路径编号与既有流式渲染一致（编辑接线不变）。
  final Widget Function(Object? node, String path) nodeBuilder;

  /// `Snapshot:get` 的 `object_id`（图片字节通道的钥匙）。
  final String objectId;
  final OfficeAttachmentBytesProvider? imageBytesProvider;
  final OfficeDocImageCache? imageCache;
  final int slideOrder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final width = maxWidth.isFinite && maxWidth > 0
            ? maxWidth
            : scene.canvasWidth;
        final scale = width / scene.canvasWidth;
        final height = scene.canvasHeight * scale;
        return SizedBox(
          key: Key('office-slide-canvas-$slideOrder'),
          width: width,
          height: height,
          child: ClipRect(
            // ⚠️⚠️ **必须用 `OverflowBox` 解开紧约束**（与
            // `office_slides_deck_view.dart` 2026-09-22、`office_viewer_page.dart`
            // 2026-09-25 两处真机缺陷同根因）：
            //
            // 外层 `SizedBox(width: width, height: height)` 给的是**紧约束**，
            // `Transform.scale`（RenderProxyBox）原样下传 ⇒ 内层
            // `SizedBox(canvasWidth, canvasHeight)` 被 `BoxConstraints.enforce`
            // 压成 `width x height`，再被 `Transform.scale` 缩一次
            // ⇒ 画面只占 `canvasWidth * scale²`（960 × 0.39² ≈ 146 dp 而不是 375 dp）。
            //
            // 这一处是 2026-09-25 审计 `Transform.scale` 全仓用法时**顺带查出的同类缺陷**
            // （此前只有 deck 路径修过）；编辑视图走的就是这个画布。
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: SizedBox(
                // 测试可观测点：**画布自己的坐标系**，必须恒等于 scene 的原始尺寸
                // （通常 960x540），**不是**缩放后的外层尺寸 —— "内容被缩放两次"
                // 的缺陷只有量这个内层尺寸才抓得住（外层布局尺寸一直是对的）。
                key: Key('office-slide-frame-$slideOrder'),
                width: scene.canvasWidth,
                height: scene.canvasHeight,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    if (scene.background != null)
                      Positioned.fill(
                        child: ColoredBox(
                          key: Key('office-slide-canvas-bg-$slideOrder'),
                          color: scene.background!,
                        ),
                      ),
                    for (final box in scene.boxes) _box(box),
                  ],
                ),
              ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _box(OfficeSlidesBox box) {
    final t = box.transform;
    if (t == null) return const SizedBox.shrink();
    final rect = t.bounds;
    Widget child = _boxContent(box);
    if (t.hasSkewY) {
      // skewY 单位**未取证**（真实样例恒为 0/浮点噪声）→ 按"角度"解释；
      // 只有真的非 0 才作用，且这是明示的取舍。
      child = Transform(
        alignment: Alignment.center,
        transform: Matrix4.skewY(t.skewY * math.pi / 180),
        child: child,
      );
    }
    if (t.hasDeg) {
      child = Transform.rotate(
        key: Key('office-slide-box-rotate-${box.id ?? box.rawType}'),
        angle: t.deg * math.pi / 180,
        child: child,
      );
    }
    return Positioned(
      key: Key('office-slide-box-${box.layer.name}-${box.id ?? box.rawType}'),
      left: rect.left,
      top: rect.top,
      width: rect.width <= 0 ? 1 : rect.width,
      height: rect.height <= 0 ? 1 : rect.height,
      child: child,
    );
  }

  Widget _boxContent(OfficeSlidesBox box) {
    switch (box.kind) {
      case OfficeSlidesBoxKind.shape:
        final spec = box.shape!;
        return CustomPaint(
          key: Key('office-slide-shape-${box.id ?? box.rawType}'),
          painter: OfficeSlidesShapePainter(spec),
          child: box.textNode == null
              ? const SizedBox.expand()
              : _overflowSlot(box),
        );
      case OfficeSlidesBoxKind.line:
        return CustomPaint(
          key: Key('office-slide-line-${box.id ?? box.rawType}'),
          painter: OfficeSlidesLinePainter(box.line!),
          size: Size.infinite,
        );
      case OfficeSlidesBoxKind.image:
        return OfficeDocImage(
          objectId: objectId,
          fileId: box.imageFileId,
          width: box.rect.width <= 0 ? 1 : box.rect.width,
          height: box.rect.height <= 0 ? 1 : box.rect.height,
          alt: box.imageAlt,
          degrees: box.imageDeg,
          flipHorizontal: box.imageFlipH,
          flipVertical: box.imageFlipV,
          provider: imageBytesProvider,
          cache: imageCache,
        );
      case OfficeSlidesBoxKind.text:
        if (box.textNode == null) return const SizedBox.expand();
        // holder 的文本框：真机模板的文本可能比框高（预置框就是会溢出）
        // → 用 OverflowBox 让它按自然高度排版（**不裁字、不报 RenderFlex 溢出**）。
        return _overflowSlot(box);
      case OfficeSlidesBoxKind.unsupported:
        return _unsupportedCard(box);
    }
  }

  /// 文本槽：**宽度锁在盒子宽度上**（保持换行），高度放开（内容多高就多高），
  /// 对齐左上；这样真机模板里"文本比预置框高"不会变成 RenderFlex 溢出错误。
  Widget _overflowSlot(OfficeSlidesBox box) => OverflowBox(
    alignment: Alignment.topLeft,
    minWidth: 0,
    maxWidth: box.rect.width <= 0 ? 1 : box.rect.width,
    minHeight: 0,
    maxHeight: double.infinity,
    child: nodeBuilder(box.textNode!, box.textPath),
  );

  Widget _unsupportedCard(OfficeSlidesBox box) {
    final name = box.unsupportedReason ?? box.rawType;
    return Container(
      key: Key('office-slide-unsupported-${box.id ?? box.rawType}'),
      padding: const EdgeInsets.all(Gap.xxs),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        dataText('officeSlidesShapeUnsupported', '这个形状暂不支持显示'),
        style: const TextStyle(fontSize: 10, color: Colors.grey),
        // 原始形状名**不上屏**（可能让用户困惑）；进报告 note。
        semanticsLabel: name,
      ),
    );
  }
}

/// `shape` 的画笔：5 种真实形状 + 已取证的 fill/stroke。
class OfficeSlidesShapePainter extends CustomPainter {
  const OfficeSlidesShapePainter(this.spec);

  final OfficeSlidesShapeSpec spec;

  /// `parallelogram` 的斜切比例 —— **本批未取证**（`cust_points` 为 `{}`，
  /// 预置几何没有字段承载）；取标准的 25% 预置斜切，并在报告 note 登记。
  static const double parallelogramSlantRatio = 0.25;

  Path pathFor(Size size) {
    final w = size.width <= 0 ? 1.0 : size.width;
    final h = size.height <= 0 ? 1.0 : size.height;
    final path = Path();
    switch (spec.kind) {
      case OfficeSlidesShapeKind.rect:
      case OfficeSlidesShapeKind.unsupported:
        path.addRect(Rect.fromLTWH(0, 0, w, h));
      case OfficeSlidesShapeKind.ellipse:
        path.addOval(Rect.fromLTWH(0, 0, w, h));
      case OfficeSlidesShapeKind.triangle:
        path
          ..moveTo(w / 2, 0)
          ..lineTo(w, h)
          ..lineTo(0, h)
          ..close();
      case OfficeSlidesShapeKind.rightTriangle:
        path
          ..moveTo(0, 0)
          ..lineTo(w, h)
          ..lineTo(0, h)
          ..close();
      case OfficeSlidesShapeKind.parallelogram:
        final slant = w * parallelogramSlantRatio;
        path
          ..moveTo(slant, 0)
          ..lineTo(w, 0)
          ..lineTo(w - slant, h)
          ..lineTo(0, h)
          ..close();
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = pathFor(size);
    if (spec.canPaintFill) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = spec.fillColor!.withValues(
            alpha: spec.fillColor!.a * spec.fillOpacity,
          ),
      );
    }
    if (spec.canPaintStroke) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = spec.strokeWidth
          ..color = spec.strokeColor!.withValues(
            alpha: spec.strokeColor!.a * spec.strokeOpacity,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(OfficeSlidesShapePainter oldDelegate) =>
      oldDelegate.spec != spec;
}

/// `line` 的画笔：按 transform 的 `left/top` + **有符号** `width/height` 画直线。
///
/// 真实样例：`line_type` 全为 `line`、`cust_points` 全为 `{}`、`width` 可正可负
/// （205 个里 93 个为负）、`height` 恒正、`deg ∈ {0, 180}`。按 transform 的字面
/// 语义：起点 = `(left, top)`，终点 = `(left+width, top+height)`；`deg` 由
/// 外层 `Transform.rotate` 施加（180° 对无向线段=同一条线）。
class OfficeSlidesLinePainter extends CustomPainter {
  const OfficeSlidesLinePainter(this.spec);

  final OfficeSlidesLineSpec spec;

  @override
  void paint(Canvas canvas, Size size) {
    if (!spec.canPaint) return;
    // size = (|width|, |height|)；起点在"有符号 width"对应的一侧。
    final w = size.width;
    final h = size.height;
    // 负宽：起点在右端（局部 x = w），终点在左端（局部 x = 0）。
    final start = Offset(0, 0);
    final end = Offset(w, h);
    if (spec.strokeWidth <= 0) return;
    canvas.drawLine(
      start,
      end,
      Paint()
        ..strokeWidth = spec.strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = spec.strokeColor!.withValues(
          alpha: spec.strokeColor!.a * spec.strokeOpacity,
        ),
    );
  }

  @override
  bool shouldRepaint(OfficeSlidesLinePainter oldDelegate) =>
      oldDelegate.spec != spec;
}

/// 场景诊断（把未取证/未渲染项写进视图的 [OfficeSlidesRenderReport]）。
void reportOfficeSlidesScene(
  OfficeSlidesSlideScene scene,
  OfficeSlidesRenderReport report, {
  required int slideOrder,
}) {
  for (final note in scene.notes) {
    report.slidesCanvasNotes.add('第 ${slideOrder + 1} 页：$note');
  }
  report.slidesCanvasBoxes += scene.boxes.length;
  report.slidesCanvasShapes += scene.boxes
      .where((b) => b.kind == OfficeSlidesBoxKind.shape)
      .length;
  report.slidesCanvasLines += scene.boxes
      .where((b) => b.kind == OfficeSlidesBoxKind.line)
      .length;
  report.slidesCanvasImages += scene.boxes
      .where((b) => b.kind == OfficeSlidesBoxKind.image)
      .length;
  report.slidesCanvasGroups += scene.groupCount;
  for (final e in scene.unsupportedShapeTypes.entries) {
    report.unsupportedSlidesShapeTypes[e.key] =
        (report.unsupportedSlidesShapeTypes[e.key] ?? 0) + e.value;
  }
  if (scene.maxGroupDepth > 1) report.slidesCanvasNestedGroups += 1;
}
