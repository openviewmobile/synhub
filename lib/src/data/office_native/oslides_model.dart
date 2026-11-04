// `.oslides`（Synology Office 演示文稿）的**只读**模型（纯 Dart；不 import flutter/l10n）。
//
// 证据（`docs/office-native-format-research.md` §4.3/§9.2，官方样本 24 份
// `template/slides/*/text.json` 实测）：
//   - section 集合与 `.odoc` 一致：`content` / `index` / `comment`；
//   - 根 `content.data.attrs` = `{"schema":13,"type":"presentation","cx":960,"cy":540}`；
//   - 结构：`master_container`（母版）→ `layout_container`（版式）→
//     `slide_container` → `slide`（**正文页**）；
//   - `slide.attrs` 实测 `{master_id, layout_id, id, is_visible}`；
//   - `slide.content` = `[slide_background, slide_content_container, note]`，
//     文本在 `slide_content_container` 里（`holder_paragraph` / `paragraph` 等），
//     演讲者备注在 `note` 里；
//   - 幻灯片**顺序 = `slide_container.content` 的文档顺序**（样本 `index` 只有
//     `schemaVersion`，没有页序数组）。
//
// ⚠️ 本批范围与限制（如实说明，不做过度承诺）：
//   - **不做**版式还原、坐标/几何计算（`attrs.transform` 原样保留在 JSON 里）；
//   - **不做**母版/版式继承合并：母版文本单独放在 [OSlidesPresentation.master]，
//     **不**拼进每页正文（否则每页都会重复整套主题文案）；
//   - **不做**动画/切换/图表（`chart` 节点）还原——未取证，仅计入节点直方图。

import 'office_json.dart';
import 'prosemirror_model.dart';

/// 一页幻灯片（`slide` 节点）。
class OSlide {
  OSlide({
    required this.order,
    required this.id,
    required this.masterId,
    required this.layoutId,
    required this.isVisible,
    required this.content,
    required this.notes,
    required this.raw,
  });

  /// 在 `slide_container` 里的顺序（0 基）。
  final int order;

  /// `attrs.id`。
  final String? id;

  /// `attrs.master_id`（**不做**母版继承，只记录引用）。
  final String? masterId;

  /// `attrs.layout_id`（**不做**版式继承，只记录引用）。
  final String? layoutId;

  /// `attrs.is_visible`。
  final bool? isVisible;

  /// 页面正文抽取（`slide_content_container`）。
  final PmExtraction content;

  /// 演讲者备注文本（`note` section）；样本里多为空段落。
  final String notes;

  final Map<String, Object?> raw;

  /// 1 基页码，便于展示。
  int get pageNumber => order + 1;

  List<PmBlock> get blocks => content.blocks;

  List<PmImageRef> get images => content.images;

  String get plainText => content.plainText;

  int get textLength => content.textLength;

  /// 标题：首个标题块；没有标题块就取第一个非空块。
  String get title {
    for (final b in content.blocks) {
      if (b.isHeading && b.text.trim().isNotEmpty) return b.text.trim();
    }
    for (final b in content.blocks) {
      if (b.text.trim().isNotEmpty) return b.text.trim();
    }
    return '';
  }

  @override
  String toString() => 'OSlide($pageNumber, id=$id, ${blocks.length} blocks)';
}

/// 演示文稿只读模型。
class OSlidesPresentation {
  OSlidesPresentation({
    required this.schema,
    required this.cx,
    required this.cy,
    required this.slides,
    required this.master,
    required this.layoutCount,
    required this.nodeTypeCounts,
    required this.sectionNames,
  });

  /// 根 `attrs.schema`（样本实测 13）。
  final int? schema;

  /// 画布宽（样本实测 960）。
  final double? cx;

  /// 画布高（样本实测 540，16:9）。
  final double? cy;

  /// 按文档顺序的幻灯片。
  final List<OSlide> slides;

  /// 母版容器抽取（**不**并入各页正文；见文件头）。
  final PmExtraction master;

  /// `layout` 节点个数（版式模板数）。
  final int layoutCount;

  final Map<String, int> nodeTypeCounts;
  final List<String> sectionNames;

  int get textLength => slides.fold(0, (sum, s) => sum + s.textLength);

  int get imageCount => slides.fold(0, (sum, s) => sum + s.images.length);

  String get plainText =>
      slides.map((s) => s.plainText).where((t) => t.isNotEmpty).join('\n\n');

  static OSlidesPresentation fromSections(Map<String, Object?> sections) {
    final content = asJsonMap(sections['content']) ?? const {};
    final data = asJsonMap(content['data']) ?? const {};
    final attrs = asJsonMap(data['attrs']) ?? const {};
    final root = data['content'];

    final slideContainer = findFirstNodeByType(root, 'slide_container');
    final slides = <OSlide>[];
    var order = 0;
    for (final slideNode in findNodesByType(
      slideContainer?['content'],
      'slide',
    )) {
      final slideAttrs = asJsonMap(slideNode['attrs']);
      final contentContainer = findFirstNodeByType(
        slideNode['content'],
        'slide_content_container',
      );
      final listMap = asJsonMap(
        asJsonMap(contentContainer?['attrs'])?['listMap'],
      );
      final note = findFirstNodeByType(slideNode['content'], 'note');
      slides.add(
        OSlide(
          order: order++,
          id: asJsonString(slideAttrs?['id']),
          masterId: asJsonString(slideAttrs?['master_id']),
          layoutId: asJsonString(slideAttrs?['layout_id']),
          isVisible: slideAttrs?['is_visible'] is bool
              ? slideAttrs!['is_visible'] as bool
              : null,
          content: extractProseMirror(
            contentContainer?['content'],
            listMap: listMap,
          ),
          notes: proseMirrorTextOnly(note?['content']),
          raw: slideNode,
        ),
      );
    }

    final masterContainer = findFirstNodeByType(root, 'master_container');
    final master = extractProseMirror(masterContainer?['content']);

    final counts = <String, int>{};
    countNodeTypes(root, counts);

    return OSlidesPresentation(
      schema: asJsonInt(attrs['schema']),
      cx: asJsonDouble(attrs['cx']),
      cy: asJsonDouble(attrs['cy']),
      slides: slides,
      master: master,
      layoutCount: findNodesByType(root, 'layout').length,
      nodeTypeCounts: counts,
      sectionNames: sections.keys.toList(growable: false),
    );
  }
}
