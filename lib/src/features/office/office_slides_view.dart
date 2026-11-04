// Office C′ 演示文稿（Slides）批 1 —— **只读、证据驱动**的 `.oslides` 渲染器。
//
// 数据来源（本批只读，不回放历史 step）：
//   * 只读 section 字典：`SYNO.Office.Snapshot:get v4` 的 `content`（真机 2 帧实测
//     `content.data.attrs = {cx:960, cy:540, schema:13, type:"presentation"}`，
//     `content.data.content = [settings, master_container, slide_container]`）。
//   * 模型：**复用既有** `lib/src/data/office_native/oslides_model.dart` 的
//     `OSlidesPresentation.fromSections`（本批未改该文件）：页序 = `slide_container`
//     里 `slide` 节点的文档顺序；每页 `raw` 就是原始 ProseMirror 节点，渲染器在它
//     上面做"证据驱动的读取 + 未知项降级"。
//   * schema 登记表：`office_slides_schema.dart`（由
//     `tool/office_collab_spike/schema/slides_schema.json` 直译）。
//
// 每个渲染字段的来源见 `docs/office-slides-ui-1.md` §① 的"字段 → 证据"表，关键几条：
//   * 页序/页数 → `slide_container.content` 里 `slide` 的顺序（24 份官方主题 +
//     2 帧真机都成立；`index` section **没有**页序数组）；
//   * 每页正文 → `slide.content` → `slide_content_container.content`；
//   * 演讲者备注 → `slide.content` → `note`；
//   * 文本 → `text` 节点的 `text`；字号/字体/颜色等 → 节点 `marks` + 段落 `attrs.textMarks`
//     （真实样本实测 mark 只有 `font_size/font_family/color/strong/em` 5 种，schema 声明 16 种）；
//   * 对齐/行高/缩进 → `paragraph` / `holder_paragraph` 的
//     `attrs.textAlign / lineHeight / indentLeft`。
//
// 降级纪律（与 `.odoc` / `.osheet` 渲染器同构）：**不认识的 section / 字段 / 节点 /
// mark / step 不许崩、不许静默丢** —— 一律进 [OfficeSlidesRenderReport]
// （计数 + messages），页顶给一条聚合横幅；幻灯片照渲染。
//
// 如实登记一条**真实制品里的未知字段**：`title_master_holder.type_id` /
// `*_holder_shape.shape_type`（11 个 key，见 `slides_schema.json`
// `observed.attr_keys_not_declared`）出现在 24 份模板与 2 帧真机数据里，但
// `schemaPresentation` **没有声明**它们 —— 本批按"未知字段"计数（不假装认识、
// 也不静默丢）。这是本批最有价值的降级证据之一。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/office_native/office_json.dart';
import '../../data/office_native/oslides_model.dart';
import 'office_doc_image.dart';
import 'office_slides_canvas.dart';
import 'office_slides_edit.dart';
import 'office_slides_schema.dart';

/// 取本批新文案（key + 中文原文；清单见 `docs/office-slides-ui-1.md` §⑩）。
String officeSlidesText(String key, String zh) => dataText(key, zh);

/// 带 `{name}` / `{count}` 等占位符的文案填充。
String officeSlidesFill(String key, String zh, Map<String, String> values) {
  var out = officeSlidesText(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

// ---------------------------------------------------------------------------
// 渲染报告（"不许静默丢"的落点）
// ---------------------------------------------------------------------------

/// 本批的只读渲染报告：**所有**降级/未渲染项都在这里留痕（可被单测与日志读到）。
class OfficeSlidesRenderReport {
  /// section 名不在真实制品/词表里（未知 → 计数，不崩）。
  final Map<String, int> unknownSections = <String, int>{};

  /// section 已确证但本批不解释其内容。
  final Map<String, int> unsupportedSections = <String, int>{};

  /// section 已登记但本批有意只登记（`index` / `comment` / `file`）。
  final Map<String, int> registeredOnlySections = <String, int>{};

  /// 未登记的字段：key 形如 `content.data.attrs.foo` / `slide.attrs.bar`。
  final Map<String, int> unknownFields = <String, int>{};

  /// schema 未声明的节点类型。
  final Map<String, int> unknownNodeTypes = <String, int>{};

  /// schema 已声明但本批不渲染的节点类型（可见降级卡片）。
  final Map<String, int> unsupportedNodeTypes = <String, int>{};

  /// schema 未声明的 mark 名。
  final Map<String, int> unknownMarks = <String, int>{};

  /// schema 已声明但本批不作用到文本上的 mark 名。
  final Map<String, int> unsupportedMarks = <String, int>{};

  /// `init` ack 的 `commands[]` 里未登记的 step 名。
  final Map<String, int> unknownSteps = <String, int>{};

  /// 出现过的 step 名（无论认识与否）—— 本批只登记，不回放。
  final Map<String, int> seenSteps = <String, int>{};

  final List<String> messages = <String>[];

  /// `init` ack 带进来但**未回放**的增量 step 数（本批有意不回放）。
  int commandsNotReplayed = 0;

  /// `commands[]` 里连 step 名都读不出来的条目数。
  int malformedCommands = 0;

  /// 渲染计数（证据，不是装饰）。
  int slidesRendered = 0;
  int hiddenSlides = 0;
  int notesRendered = 0;
  int masterTextBlocks = 0;
  int placeholdersRendered = 0;

  // ---- 批 C：几何渲染（形状/连线/图片/分组）的如实登记 -----------------------

  /// 每页的几何登记（缺 transform / 未取证形状 / 母版版式缺失 …）。
  final List<String> slidesCanvasNotes = <String>[];

  /// 已摆位的盒子数（母版 + 版式 + 正文）。
  int slidesCanvasBoxes = 0;

  /// 真正画出来的形状 / 连线 / 图片数。
  int slidesCanvasShapes = 0;
  int slidesCanvasLines = 0;
  int slidesCanvasImages = 0;

  /// 分组数与**嵌套组**页数（嵌套组未取证）。
  int slidesCanvasGroups = 0;
  int slidesCanvasNestedGroups = 0;

  /// 清单外（未实现）的 `shape_type` → 次数（真实样例里出现过 `pie` / `chord`）。
  final Map<String, int> unsupportedSlidesShapeTypes = <String, int>{};

  void unknownSection(String name) {
    unknownSections[name] = (unknownSections[name] ?? 0) + 1;
    messages.add('未知 section（制品/词表未登记）：${officeSlidesSectionKey(name)}');
  }

  void unsupportedSection(String name) {
    unsupportedSections[name] = (unsupportedSections[name] ?? 0) + 1;
    messages.add('已确证但本批不渲染的 section：${officeSlidesSectionKey(name)}');
  }

  void registeredOnlySection(String name) {
    registeredOnlySections[name] = (registeredOnlySections[name] ?? 0) + 1;
    messages.add('已登记、本批只登记不解释的 section：${officeSlidesSectionKey(name)}');
  }

  void unknownField(String scope, String key) {
    final k = '$scope.$key';
    unknownFields[k] = (unknownFields[k] ?? 0) + 1;
    messages.add('未知字段（schema 未声明）：$k');
  }

  void unknownNode(String type) {
    unknownNodeTypes[type] = (unknownNodeTypes[type] ?? 0) + 1;
    messages.add('未知节点（schema 未声明）：$type');
  }

  void unsupportedNode(String type) {
    unsupportedNodeTypes[type] = (unsupportedNodeTypes[type] ?? 0) + 1;
    messages.add('schema 已声明但本批不渲染的节点：$type');
  }

  void unknownMark(String name) {
    unknownMarks[name] = (unknownMarks[name] ?? 0) + 1;
    messages.add('未知 mark（schema 未声明）：$name');
  }

  void unsupportedMark(String name) {
    unsupportedMarks[name] = (unsupportedMarks[name] ?? 0) + 1;
    messages.add('schema 已声明但本批不渲染的 mark：$name');
  }

  void unknownStep(String name) {
    unknownSteps[name] = (unknownSteps[name] ?? 0) + 1;
    messages.add('未知 step（$kOfficeSlidesStepCount 词表未登记）：$name');
  }

  void seenStep(String name) {
    seenSteps[name] = (seenSteps[name] ?? 0) + 1;
  }

  void note(String message) => messages.add(message);

  bool get hasDegradations =>
      unknownSections.isNotEmpty ||
      unsupportedSections.isNotEmpty ||
      unknownFields.isNotEmpty ||
      unknownNodeTypes.isNotEmpty ||
      unsupportedNodeTypes.isNotEmpty ||
      unknownMarks.isNotEmpty ||
      unsupportedMarks.isNotEmpty ||
      unknownSteps.isNotEmpty ||
      unsupportedSlidesShapeTypes.isNotEmpty ||
      malformedCommands > 0;

  int get degradationCount =>
      unknownSections.values.fold<int>(0, (a, b) => a + b) +
      unsupportedSections.values.fold<int>(0, (a, b) => a + b) +
      unknownFields.values.fold<int>(0, (a, b) => a + b) +
      unknownNodeTypes.values.fold<int>(0, (a, b) => a + b) +
      unsupportedNodeTypes.values.fold<int>(0, (a, b) => a + b) +
      unknownMarks.values.fold<int>(0, (a, b) => a + b) +
      unsupportedMarks.values.fold<int>(0, (a, b) => a + b) +
      unknownSteps.values.fold<int>(0, (a, b) => a + b) +
      unsupportedSlidesShapeTypes.values.fold<int>(0, (a, b) => a + b) +
      malformedCommands;

  @override
  String toString() =>
      'OfficeSlidesRenderReport(unknownSections=$unknownSections, '
      'unsupportedSections=$unsupportedSections, unknownFields=$unknownFields, '
      'unknownNodes=$unknownNodeTypes, unsupportedNodes=$unsupportedNodeTypes, '
      'unknownMarks=$unknownMarks, unknownSteps=$unknownSteps, '
      'commandsNotReplayed=$commandsNotReplayed, slides=$slidesRendered)';
}

// ---------------------------------------------------------------------------
// 扫描（纯函数，可离线单测；只写 report，不抛）
// ---------------------------------------------------------------------------

/// 扫 section 字典：登记未知 / 只登记 / 未知字段。
void scanOfficeSlidesSections(
  Map<String, Object?> sections,
  OfficeSlidesRenderReport report,
) {
  for (final entry in sections.entries) {
    switch (officeSlidesSectionEvidence(entry.key).support) {
      case OfficeSlidesSectionSupport.rendered:
        _scanContentSection(entry.value, report);
      case OfficeSlidesSectionSupport.structural:
        report.registeredOnlySection(entry.key);
        if (entry.key == 'index') _scanIndexSection(entry.value, report);
        if (entry.key == 'comment') _scanCommentSection(entry.value, report);
      case OfficeSlidesSectionSupport.degraded:
        report.unsupportedSection(entry.key);
      case OfficeSlidesSectionSupport.unknown:
        report.unknownSection(entry.key);
    }
  }
}

void _scanContentSection(Object? raw, OfficeSlidesRenderReport report) {
  final content = asJsonMap(raw);
  if (content == null) {
    report.note('content section 不是对象（本批按空内容处理，不崩）');
    return;
  }
  for (final key in content.keys) {
    if (!kOfficeSlidesContentKeys.contains(key)) {
      report.unknownField('content', key);
    }
  }
  final data = asJsonMap(content['data']);
  if (data == null) return;
  for (final key in data.keys) {
    if (!kOfficeSlidesContentDataKeys.contains(key)) {
      report.unknownField('content.data', key);
    }
  }
  final attrs = asJsonMap(data['attrs']);
  if (attrs != null) {
    for (final key in attrs.keys) {
      if (!kOfficeSlidesRootAttrKeys.contains(key)) {
        report.unknownField('content.data.attrs', key);
      }
    }
  }
  scanOfficeSlidesDocument(data['content'], report);
}

void _scanIndexSection(Object? raw, OfficeSlidesRenderReport report) {
  final index = asJsonMap(raw);
  if (index == null) return;
  for (final key in index.keys) {
    if (!kOfficeSlidesIndexKeys.contains(key)) {
      report.unknownField('index', key);
    }
  }
}

void _scanCommentSection(Object? raw, OfficeSlidesRenderReport report) {
  final comment = asJsonMap(raw);
  if (comment == null) return; // null / 数组都合法（帧里是 null 或 {data:[],format:1}）
  for (final key in comment.keys) {
    if (!kOfficeSlidesCommentKeys.contains(key)) {
      report.unknownField('comment', key);
    }
  }
}

/// 走一遍 ProseMirror 演示文稿树：节点类型 / 属性键 / mark 名 / 页数。
///
/// 未知节点、未声明属性、未知 mark **全部计数**（不崩）；`degraded` 节点也计数
/// （它们在页面上有一张"暂不支持渲染"的可见卡片）。
void scanOfficeSlidesDocument(
  Object? root,
  OfficeSlidesRenderReport report,
) {
  final slides = <Object?>[];
  void walk(Object? node) {
    if (node is List) {
      for (final x in node) {
        walk(x);
      }
      return;
    }
    final map = asJsonMap(node);
    if (map == null) return;
    final type = asJsonString(map['type']);
    if (type != null) {
      final spec = kOfficeSlidesNodeSpecs[type];
      if (spec == null) {
        report.unknownNode(type);
      } else {
        if (spec.support == OfficeSlidesNodeSupport.degraded) {
          report.unsupportedNode(type);
        }
        final attrs = asJsonMap(map['attrs']);
        if (attrs != null) {
          for (final key in attrs.keys) {
            if (!spec.declaresAttr(key)) report.unknownField(type, key);
          }
        }
      }
      if (type == 'slide') {
        report.slidesRendered++;
        if (asJsonMap(map['attrs'])?['is_visible'] == false) report.hiddenSlides++;
        slides.add(map);
      }
      if (type == 'note') report.notesRendered++;
      if (type == 'page_number' || type == 'date_time') {
        report.placeholdersRendered++;
      }
      if (type == 'master_container') report.masterTextBlocks++;
    }
    final marks = asJsonList(map['marks']);
    if (marks != null) {
      for (final raw in marks) {
        final mark = asJsonMap(raw);
        if (mark == null) continue;
        final name = asJsonString(mark['_']) ?? asJsonString(mark['type']);
        if (name == null) {
          report.unknownMark('(no _/type)');
          continue;
        }
        if (!isOfficeSlidesMarkKnown(name)) {
          report.unknownMark(name);
        } else if (kOfficeSlidesMarkSupport[name] !=
            OfficeSlidesMarkSupport.rendered) {
          report.unsupportedMark(name);
        }
      }
    }
    walk(map['content']);
  }

  walk(root);
  report.slidesRendered = slides.length;
}

/// 扫 `init` ack 的 `commands[]`（presentation 的"命令"就是 step）：
/// **只登记，不回放**。
void scanOfficeSlidesCommands(
  Object? commands,
  OfficeSlidesRenderReport report, {
  required String source,
}) {
  final list = asJsonList(commands);
  if (list == null || list.isEmpty) return;
  report.commandsNotReplayed += list.length;
  for (final command in list) {
    final map = asJsonMap(command);
    final name = map == null
        ? null
        : (asJsonString(map['stepType']) ??
            asJsonString(map['cmd']) ??
            asJsonString(map['type']));
    if (name == null) {
      report.malformedCommands++;
      report.messages.add('step 条目没有 stepType/cmd 字段（来源：$source）');
      continue;
    }
    report.seenStep(name);
    if (!isOfficeSlidesStepKnown(name)) report.unknownStep(name);
  }
  report.note(
    '$source 带 ${list.length} 条增量 step：本批**不回放历史 step**'
    '（基础模型从 content section 重建），step 名已全部登记。',
  );
}

// ---------------------------------------------------------------------------
// mark 支持度（key 必须与 schema 的 mark 集合逐字相等；测试断言）
// ---------------------------------------------------------------------------

/// 本批对某个 schema mark 的渲染支持度。
enum OfficeSlidesMarkSupport {
  /// 本批把它落成 `TextStyle` / 交互。
  rendered,

  /// schema 声明了它，但本批有意不作用到文本上（`tracking` 是修订元数据）。
  metadata,

  /// 本批不渲染（计数 + 页顶提示）。
  degraded,
}

/// 本批 mark 覆盖表。key 必须与 `kOfficeSlidesMarkSpecs.keys` 完全相同。
const Map<String, OfficeSlidesMarkSupport> kOfficeSlidesMarkSupport =
    <String, OfficeSlidesMarkSupport>{
  // 真实制品里出现的 5 种（slides_schema.json observed.marks）。
  'font_size': OfficeSlidesMarkSupport.rendered,
  'font_family': OfficeSlidesMarkSupport.rendered,
  'color': OfficeSlidesMarkSupport.rendered,
  'strong': OfficeSlidesMarkSupport.rendered,
  'em': OfficeSlidesMarkSupport.rendered,
  // schema 声明、制品未出现，但语义直接可渲染。
  'underline': OfficeSlidesMarkSupport.rendered,
  'strike': OfficeSlidesMarkSupport.rendered,
  'superscript': OfficeSlidesMarkSupport.rendered,
  'subscript': OfficeSlidesMarkSupport.rendered,
  'background_color': OfficeSlidesMarkSupport.rendered,
  'link': OfficeSlidesMarkSupport.rendered,
  // 修订元数据：不改变外观（如实登记）。
  'tracking': OfficeSlidesMarkSupport.metadata,
  // 块级 attr mark：本批未接入（对齐走 attrs.textAlign，行高走 attrs.lineHeight）。
  'direction': OfficeSlidesMarkSupport.degraded,
  'text_align': OfficeSlidesMarkSupport.degraded,
  'line_height': OfficeSlidesMarkSupport.degraded,
  'text_indent': OfficeSlidesMarkSupport.degraded,
};

/// 解析 mark 的 CSS 颜色（`#rgb` / `#rrggbb` / `#aarrggbb` / `rgb(...)`）。
/// 认不出返回 null —— 调用方保留纯文本，不抛。
Color? officeSlidesParseColor(Object? value) {
  if (value is! String) return null;
  final s = value.trim().toLowerCase();
  if (s.isEmpty || s == 'transparent') return null;
  if (s.startsWith('#')) {
    var hex = s.substring(1);
    if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
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
  return null;
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

/// `.oslides` 只读渲染器。
///
/// [sections] 是 `@C_text/*` 的 section 字典（至少要有 `content`），直接喂既有的
/// [OSlidesPresentation.fromSections]；[report] 非空时页面与渲染器共用同一份报告。
class OfficeSlidesView extends StatefulWidget {
  const OfficeSlidesView({
    super.key,
    required this.sections,
    this.report,
    this.showHeaderNote = true,
    this.edit,
    this.onEditBlock,
    this.objectId = '',
    this.imageBytesProvider,
    this.imageCache,
  });

  final Map<String, Object?> sections;
  final OfficeSlidesRenderReport? report;

  /// 是否显示页顶"只读渲染"说明。
  final bool showHeaderNote;

  /// 批 2 编辑层（可空 = 纯只读）。提供且 `canEdit` 时，正文文本块可点按编辑，
  /// 未确认块用**乐观文本**显示并带 pending 标记。
  final OfficeSlidesEditController? edit;

  /// 点按文本块的回调（页面提供对话框实现；view 不依赖页面）。
  final void Function(OfficeSlidesEditableBlock block)? onEditBlock;

  /// `Snapshot:get` 回包的 `object_id` —— **图片字节通道的钥匙**
  /// （批 A 的 `Attachment:get v2` 必须同时带 `object_id` + `file_id`）。
  final String objectId;

  /// 图片字节提供者（生产 = `OfficeApi.attachmentGet`；测试注入真实 PNG 字节）。
  final OfficeAttachmentBytesProvider? imageBytesProvider;

  /// 图片缓存（内存 LRU + 磁盘）；null = 进程级默认。
  final OfficeDocImageCache? imageCache;

  @override
  State<OfficeSlidesView> createState() => _OfficeSlidesViewState();
}

class _OfficeSlidesViewState extends State<OfficeSlidesView> {
  late OfficeSlidesRenderReport _report;
  late OSlidesPresentation? _presentation;
  Object? _modelError;

  /// 每页的几何场景（批 C）：在 [_prepare] 里构建一次，避免 rebuild 重复登记。
  Map<int, OfficeSlidesSlideScene> _scenes = <int, OfficeSlidesSlideScene>{};

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant OfficeSlidesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sections, widget.sections) ||
        oldWidget.report != widget.report) {
      _prepare();
    }
  }

  void _prepare() {
    final owned = widget.report == null;
    _report = widget.report ?? OfficeSlidesRenderReport();
    scanOfficeSlidesSections(widget.sections, _report);
    try {
      _presentation = OSlidesPresentation.fromSections(widget.sections);
      _modelError = null;
    } on Object catch (e) {
      _presentation = null;
      _modelError = e;
      _report.note('演示文稿模型重建失败：$e');
    }
    // 批 C：为每页构建**几何场景**（母版 + 版式 + 正文）。
    _scenes = <int, OfficeSlidesSlideScene>{};
    final presentation = _presentation;
    if (presentation != null) {
      for (final slide in presentation.slides) {
        final scene = buildOfficeSlidesSlideScene(
          sections: widget.sections,
          slideRaw: slide.raw,
          slidePathPrefix: 'p${slide.order}',
        );
        _scenes[slide.order] = scene;
        reportOfficeSlidesScene(scene, _report, slideOrder: slide.order);
      }
    }
    if (owned) {
      for (final m in _report.messages) {
        debugPrint('[OfficeSlidesView] $m');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_modelError != null || _presentation == null) {
      return _card(
        key: const Key('office-slides-error'),
        icon: Icons.error_outline,
        text: officeSlidesFill(
          'officeSlidesModelFailed',
          '无法重建演示文稿模型：{name}',
          <String, String>{'name': '$_modelError'},
        ),
      );
    }
    final presentation = _presentation!;
    if (presentation.slides.isEmpty) {
      return _card(
        key: const Key('office-slides-empty'),
        icon: Icons.slideshow_outlined,
        text: officeSlidesText('officeSlidesEmpty', '这份演示文稿里没有可显示的幻灯片'),
      );
    }
    return Column(
      key: const Key('office-slides-view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_report.hasDegradations) _partialBanner(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            // 幻灯片是**整页画布**（960×540 等比缩放），比旧的文字流高得多；
            // 给足 cacheExtent，使后续页/母版卡在未滚动到时也已构建
            // （截图与 finder 都能看到，不因懒构建而"消失"）。
            scrollCacheExtent: const ScrollCacheExtent.pixels(2400),
            children: [
              if (widget.showHeaderNote) _headerNote(presentation),
              for (final slide in presentation.slides) _slideCard(slide),
              // 母版单独成卡（不并入各页正文）。批 C 起幻灯片是**整页画布**，
              // 母版卡会在视口外 → 取阅需要向下滚动（ListView 懒构建，属正常行为）。
              _masterCard(presentation),
            ],
          ),
        ),
      ],
    );
  }

  Widget _partialBanner() {
    return Container(
      key: const Key('office-slides-partial-banner'),
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(
              officeSlidesFill(
                'officeSlidesRenderPartial',
                '这一页有部分内容没能完整显示（{count} 处）。',
                <String, String>{'count': '${_report.degradationCount}'},
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerNote(OSlidesPresentation presentation) {
    final t = Theme.of(context);
    return Column(
      key: const Key('office-slides-header-note'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Text(
              officeSlidesText('officeSlidesReadOnly', '只读渲染'),
              style: t.textTheme.labelMedium?.copyWith(
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.xxs),
        Text(
          '${officeSlidesFill('officeSlidesSlideCount', '幻灯片 {count} 页', <String, String>{'count': '${presentation.slides.length}'})}'
          ' · '
          '${officeSlidesFill('officeSlidesLayoutCount', '版式 {count} 个', <String, String>{'count': '${presentation.layoutCount}'})}'
          ' · '
          '${officeSlidesFill('officeSlidesImageCount', '图片 {count} 张', <String, String>{'count': '${presentation.imageCount}'})}',
          key: const Key('office-slides-summary'),
          style: t.textTheme.bodySmall,
        ),
        const Divider(height: Gap.lg),
      ],
    );
  }

  Widget _slideCard(OSlide slide) {
    final t = Theme.of(context);
    final body = _slideBody(slide);
    return Card(
      key: Key('office-slide-${slide.order}'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  officeSlidesFill(
                    'officeSlidesSlidePage',
                    '第 {index} 页',
                    <String, String>{'index': '${slide.pageNumber}'},
                  ),
                  key: Key('office-slide-page-${slide.order}'),
                  style: t.textTheme.labelLarge,
                ),
                if (slide.isVisible == false) ...[
                  const SizedBox(width: Gap.xs),
                  Text(
                    officeSlidesText('officeSlidesHiddenSlide', '隐藏页'),
                    key: Key('office-slide-hidden-${slide.order}'),
                    style: t.textTheme.labelSmall?.copyWith(
                      color: t.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            const Divider(height: Gap.md),
            body,
            if (slide.notes.trim().isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(
                '${officeSlidesText('officeSlidesNotes', '备注')}: ${slide.notes.trim()}',
                key: Key('office-slide-notes-${slide.order}'),
                style: t.textTheme.bodySmall?.copyWith(
                  color: t.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _slideBody(OSlide slide) {
    final container = findFirstNodeByType(
      slide.raw['content'],
      'slide_content_container',
    );
    final children = asJsonList(container?['content']);
    final scene = _scenes[slide.order];
    final hasFlow = scene != null && scene.flow.isNotEmpty;
    if ((children == null || children.isEmpty) &&
        (scene == null || (!scene.hasCanvasContent && !hasFlow))) {
      return Text(
        officeSlidesText('officeSlidesSlideEmpty', '这一页没有可显示的正文'),
        key: Key('office-slide-empty-${slide.order}'),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final parts = <Widget>[];
    if (scene != null && scene.hasCanvasContent) {
      // 批 C：把这一页当**幻灯片**画（母版 + 版式 + 正文的几何）。
      parts.add(
        OfficeSlidesCanvas(
          scene: scene,
          nodeBuilder: _block,
          objectId: widget.objectId,
          imageBytesProvider: widget.imageBytesProvider,
          imageCache: widget.imageCache,
          slideOrder: slide.order,
        ),
      );
    }
    if (scene != null) {
      // 没有几何可摆位的节点仍然**流式**渲染（不丢内容）。
      for (final item in scene.flow) {
        parts.add(_block(item.node, item.path));
      }
    } else if (children != null) {
      // 场景缺失（模型重建失败以外的兜底）→ 保持旧行为。
      for (var i = 0; i < children.length; i++) {
        parts.add(_block(children[i], 'p${slide.order}.$i'));
      }
    }
    if (parts.isEmpty) {
      return Text(
        officeSlidesText('officeSlidesSlideEmpty', '这一页没有可显示的正文'),
        key: Key('office-slide-empty-${slide.order}'),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: parts,
    );
  }

  Widget _masterCard(OSlidesPresentation presentation) {
    final t = Theme.of(context);
    final text = presentation.master.plainText.trim();
    return Card(
      key: const Key('office-slide-master'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: ExpansionTile(
        initiallyExpanded: false,
        title: Text(
          officeSlidesFill(
            'officeSlidesMaster',
            '母版内容（{count} 段）',
            <String, String>{'count': '${presentation.master.blocks.length}'},
          ),
        ),
        childrenPadding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          if (text.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Text(
                officeSlidesText('officeSlidesMasterEmpty', '母版没有文本'),
                style: t.textTheme.bodySmall,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(text, style: t.textTheme.bodySmall),
              ),
            ),
        ],
      ),
    );
  }

  // ---- 块级渲染 -------------------------------------------------------------

  Widget _block(Object? raw, String path) {
    final node = asJsonMap(raw);
    if (node == null) {
      return _degradedCard(
        key: 'office-slide-node-$path',
        labelKey: 'officeSlidesUnsupportedUnknown',
        zh: '暂不支持渲染的类型（schema 未声明）：{name}',
        name: '${raw.runtimeType}',
      );
    }
    final type = asJsonString(node['type']);
    if (type == null) {
      return _degradedCard(
        key: 'office-slide-node-$path',
        labelKey: 'officeSlidesUnsupportedUnknown',
        zh: '暂不支持渲染的类型（schema 未声明）：{name}',
        name: '(no type)',
      );
    }
    final spec = kOfficeSlidesNodeSpecs[type];
    if (spec == null) {
      // 已由 scanOfficeSlidesDocument 计数；这里给可见卡片（不静默）。
      return _degradedCard(
        key: 'office-slide-node-$path',
        labelKey: 'officeSlidesUnsupportedUnknown',
        zh: '暂不支持渲染的类型（schema 未声明）：{name}',
        name: type,
      );
    }
    if (spec.support == OfficeSlidesNodeSupport.degraded) {
      return _degradedCard(
        key: 'office-slide-node-$path',
        labelKey: 'officeSlidesUnsupportedType',
        zh: '暂不支持渲染的类型：{name}',
        name: type,
      );
    }
    switch (type) {
      case 'paragraph':
      case 'holder_paragraph':
      case 'text_block':
      case 'shape_text_block':
      case 'text_line':
        return _paragraph(node, path);
      case 'hard_break':
        return const SizedBox(height: Gap.sm);
      case 'tab':
        return const SizedBox(width: Gap.lg);
      case 'page_number':
        return _placeholder(
          key: 'office-slide-node-$path',
          zh: '页码',
          keyName: 'officeSlidesPageNumberToken',
        );
      case 'date_time':
        return _placeholder(
          key: 'office-slide-node-$path',
          zh: '日期时间',
          keyName: 'officeSlidesDateTimeToken',
        );
      case 'note':
        // 备注由 `_slideCard` 单独呈现；这里避免重复画一遍。
        return const SizedBox.shrink();
      default:
        return _children(node, path);
    }
  }

  Widget _children(Map<String, Object?> node, String path) {
    final children = asJsonList(node['content']);
    if (children == null || children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++)
          _block(children[i], '$path.$i'),
      ],
    );
  }

  Widget _paragraph(Map<String, Object?> node, String path) {
    final attrs = asJsonMap(node['attrs']);
    final align = switch (asJsonString(attrs?['textAlign'])) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' => TextAlign.justify,
      _ => TextAlign.start,
    };
    final lineHeight = asJsonDouble(attrs?['lineHeight']);
    // `indentLeft` 可能是负数（真实模板里出现过）→ Padding 不能为负，
    // 收敛到 0（不因为一个负缩进就崩掉整页渲染）。
    final indentRaw = asJsonDouble(attrs?['indentLeft']) ?? 0;
    final indentLeft = indentRaw < 0 ? 0.0 : indentRaw;
    final listLevel = asJsonInt(attrs?['listLevel']) ?? 0;
    final listId = asJsonString(attrs?['listId']);
    final base = DefaultTextStyle.of(context).style.copyWith(
      height: lineHeight,
    );
    // 段落级默认 mark（真实样本：holder_paragraph.attrs.textMarks）。
    var blockStyle = const TextStyle();
    for (final raw in asJsonList(attrs?['textMarks']) ?? const <Object?>[]) {
      blockStyle = blockStyle.merge(_markStyle(raw, path));
    }
    final prefix = listId != null && listId.isNotEmpty
        ? '${listLevel > 0 ? '  ' * listLevel : ''}•  '
        : null;
    final spans = <InlineSpan>[];
    if (prefix != null) spans.add(TextSpan(text: prefix));
    for (final raw in asJsonList(node['content']) ?? const <Object?>[]) {
      final child = asJsonMap(raw);
      final childType = asJsonString(child?['type']);
      if (childType == 'text') {
        var style = const TextStyle();
        for (final m in asJsonList(child?['marks']) ?? const <Object?>[]) {
          style = style.merge(_markStyle(m, path));
        }
        spans.add(
          TextSpan(text: '${child?['text'] ?? ''}', style: style),
        );
      } else if (childType == 'hard_break') {
        spans.add(const TextSpan(text: '\n'));
      } else if (childType == 'tab') {
        spans.add(const TextSpan(text: '\t'));
      } else if (childType != null &&
          kOfficeSlidesNodeSpecs.containsKey(childType)) {
        spans.add(WidgetSpan(child: _block(child, '$path.w')));
      } else {
        spans.add(
          TextSpan(
            text: '[${officeSlidesText('officeSlidesUnsupportedInline', '不支持的内联类型')}: $childType]',
          ),
        );
      }
    }
    final rich = Text.rich(
      TextSpan(style: base.merge(blockStyle), children: spans),
      textAlign: align,
    );
    final edit = widget.edit;
    final block = edit == null ? null : _blockForPath(path, edit);
    if (edit == null || block == null) {
      return Padding(
        key: Key('office-slide-text-$path'),
        padding: EdgeInsets.only(
          left: indentLeft + (listLevel > 0 ? Gap.lg * listLevel : 0),
          top: Gap.xxs,
          bottom: Gap.xxs,
        ),
        child: rich,
      );
    }
    // 批 2：可编辑块 → 点按进编辑；未确认块用**乐观文本**显示 + pending 标记。
    final pending = edit.isPendingBlock(block.id);
    final optimistic = edit.optimisticText(block.id);
    final display = pending && optimistic != null
        ? Text(
            optimistic,
            key: Key('office-slide-pending-text-${block.id}'),
            textAlign: align,
            style: base.merge(blockStyle),
          )
        : rich;
    return Padding(
      key: Key('office-slide-text-$path'),
      padding: EdgeInsets.only(
        left: indentLeft + (listLevel > 0 ? Gap.lg * listLevel : 0),
        top: Gap.xxs,
        bottom: Gap.xxs,
      ),
      child: GestureDetector(
        key: Key('office-slide-edit-${block.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: edit.canEdit && widget.onEditBlock != null
            ? () => widget.onEditBlock!(block)
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: display),
            if (pending)
              Padding(
                padding: const EdgeInsets.only(left: Gap.xs),
                child: Icon(
                  Icons.cloud_upload_outlined,
                  key: Key('office-slide-pending-${block.id}'),
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            if (edit.canEdit)
              Padding(
                padding: const EdgeInsets.only(left: Gap.xs),
                child: Icon(
                  Icons.edit_outlined,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 渲染路径 `p<order>.<suffix…>` → 编辑层的块（后缀配对；`w` 段不可编辑）。
  OfficeSlidesEditableBlock? _blockForPath(
    String path,
    OfficeSlidesEditController edit,
  ) {
    final match = RegExp(r'^p(\d+)\.(.+)$').firstMatch(path);
    if (match == null) return null;
    final order = int.tryParse(match.group(1)!);
    if (order == null) return null;
    final suffix = <int>[];
    for (final part in match.group(2)!.split('.')) {
      final index = int.tryParse(part);
      if (index == null) return null; // `w`（WidgetSpan）等 → 不入编辑
      suffix.add(index);
    }
    return edit.blockForRenderPath(order, suffix);
  }

  /// 一个 mark（`{_:name, …}`）→ `TextStyle`。
  TextStyle _markStyle(Object? raw, String path) {
    final mark = asJsonMap(raw);
    if (mark == null) return const TextStyle();
    final name = asJsonString(mark['_']) ?? asJsonString(mark['type']);
    if (name == null) {
      return const TextStyle();
    }
    if (!isOfficeSlidesMarkKnown(name)) {
      return const TextStyle();
    }
    if (kOfficeSlidesMarkSupport[name] != OfficeSlidesMarkSupport.rendered) {
      return const TextStyle();
    }
    switch (name) {
      case 'strong':
        return const TextStyle(fontWeight: FontWeight.bold);
      case 'em':
        return const TextStyle(fontStyle: FontStyle.italic);
      case 'underline':
        return const TextStyle(decoration: TextDecoration.underline);
      case 'strike':
        return const TextStyle(decoration: TextDecoration.lineThrough);
      case 'superscript':
        return const TextStyle(
          fontFeatures: <FontFeature>[FontFeature.superscripts()],
        );
      case 'subscript':
        return const TextStyle(
          fontFeatures: <FontFeature>[FontFeature.subscripts()],
        );
      case 'color':
        final c = officeSlidesParseColor(mark['value']);
        if (c == null) {
          _report.note('color mark 的值无法解析：${mark['value']}');
          return const TextStyle();
        }
        return TextStyle(color: c);
      case 'background_color':
        final c = officeSlidesParseColor(mark['value']);
        if (c == null) {
          _report.note('background_color mark 的值无法解析：${mark['value']}');
          return const TextStyle();
        }
        return TextStyle(backgroundColor: c);
      case 'font_size':
        final v = asJsonDouble(mark['value']);
        return TextStyle(fontSize: v);
      case 'font_family':
        final v = asJsonString(mark['value']);
        return v == null || v.isEmpty || v == 'Arial'
            ? const TextStyle()
            : TextStyle(fontFamily: v);
      case 'link':
        return TextStyle(
          color: Colors.blue.shade700,
          decoration: TextDecoration.underline,
        );
      default:
        return const TextStyle();
    }
  }

  Widget _placeholder({
    required String key,
    required String keyName,
    required String zh,
  }) {
    return Text(
      '[${officeSlidesText(keyName, zh)}]',
      key: Key(key),
      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
    );
  }

  Widget _degradedCard({
    required String key,
    required String labelKey,
    required String zh,
    required String name,
  }) {
    final t = Theme.of(context);
    return Container(
      key: Key(key),
      margin: const EdgeInsets.symmetric(vertical: Gap.xxs),
      padding: const EdgeInsets.all(Gap.xs),
      decoration: BoxDecoration(
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
        color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.help_outline, size: 16, color: t.colorScheme.outline),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(
              officeSlidesFill(labelKey, zh, <String, String>{'name': name}),
              style: t.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required Key key,
    required IconData icon,
    required String text,
  }) {
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36),
            const SizedBox(height: Gap.md),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
