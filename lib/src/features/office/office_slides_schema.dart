// Office C′ 演示文稿（Slides）批 1 —— **schema / step / section / 字段登记表**（证据驱动的地基）。
//
// 为什么要有这个文件：`.oslides` 与 `.odoc` 共用同一份 Synology 的 ProseMirror fork，
// 但用的是 **`schemaPresentation`** 实例（version 13，78 node /
// 12 mark / 4 attr_mark）。**没有** `cmd:"…"` 命令词表 ——
// 编辑以 ProseMirror **step** 传播，所以 `sheet_commands.json` 的对应物是
// **step JSON id 登记表**（`jsonID("<name>", <Class>)`）+ 其 dispatcher
// （`Step.stepClass` / `Step.fromJSON` 的 `s(e.stepType).fromJSON(t,e)`）。
//
// 机读来源（本文件由它**直译**，测试运行时读它并断言集合逐字相等）：
//   `tool/office_collab_spike/schema/slides_schema.json`
//   ← `tool/office_collab_spike/schema/export_slides_schema.js`
//   ← SPK 3.8.0-22711 的 `server/common/prosemirror/index.js`
//     （sha256 `eee7801664008f50…`）
//
// 证据等级（与 `doc_schema.json` / `sheet_commands.json` 同口径）：
//   * `SPK-JS 原文` / `SPK 束内模块` —— 包内束的字面量 / 加载后活对象；
//   * 真实制品 —— 24 份官方主题 `template/slides/<theme>/text.json`（section 并集
//     `content/index/comment`）+ 2 帧真机 `SYNO.Office.Snapshot:get v4`
//     （`/tmp/office_probe_evid/snap_probe_*oslides.json`，`ntype:"presentation"`，
//     `content.data.attrs = {cx:960, cy:540, schema:13, type:"presentation"}`）；
//   * `推断` —— 一律带 `disproof`（见 JSON），本文件的表里没有一条是推断。
//
// **本批只读**：登记表只用于"渲染 + 未知项计数"（未知 section / 字段 / 节点 / mark /
// step 全部进 `OfficeSlidesRenderReport`，**不崩、不静默**）。真正的 step 写入在下一批。

/// 机读产物路径（测试运行时读它并断言集合相等）。
const String kOfficeSlidesEvidencePath =
    'tool/office_collab_spike/schema/slides_schema.json';

/// schema 束（只读证据）。
const String kOfficeSlidesSchemaBundle =
    'server/common/prosemirror/index.js';

/// 束 sha256（完整值；`slides_schema.json.source.bundle_sha256`）。
const String kOfficeSlidesSchemaBundleSha256 =
    'eee7801664008f5082da34c6380dcbeb9508409865de60b7c7b5ebf76e70ee90';

/// schema 名 / 版本 / 规模（`slides_schema.json.schema`）。
const String kOfficeSlidesSchemaName = 'presentation';
const int kOfficeSlidesSchemaVersion = 13;
const String kOfficeSlidesTopNodeName = 'doc';
const String kOfficeSlidesTopNodeContent = 'settings master_container slide_container';
const int kOfficeSlidesNodeCount = 78;
const int kOfficeSlidesMarkCount = 12;
const int kOfficeSlidesAttrMarkCount = 4;
const int kOfficeSlidesStepCount = 51;

/// 本批对某个 schema 节点的渲染支持度（分类规则见 JSON `node_support[].why`）。
enum OfficeSlidesNodeSupport {
  /// 本批真的画出来（内联文本 / 文本块 / 换行 / 制表符）。
  rendered,

  /// 登记但不直接作画（容器：子节点照渲染；叶子：有意不画背景/几何）。
  structural,

  /// 本批**不渲染**（可见的"暂不支持渲染的类型"降级卡片）。
  degraded,
}

/// 一个 schema 节点的登记：内容表达式 / 组 / 属性键 / 支持度 / 依据。
class OfficeSlidesNodeSpec {
  const OfficeSlidesNodeSpec({
    required this.name,
    required this.content,
    required this.groups,
    required this.isLeaf,
    required this.isText,
    required this.attrKeys,
    required this.support,
    required this.evidence,
  });

  final String name;

  /// content 表达式（null = schema 未声明内容，叶子）。
  final String? content;

  /// schema 组名（`groups`）。
  final List<String> groups;

  final bool isLeaf;
  final bool isText;

  /// **schema 声明的**属性键（未知字段按它判定；`slides_schema.json.nodes[].attr_keys`）。
  final List<String> attrKeys;

  final OfficeSlidesNodeSupport support;

  /// 支持度规则来源（JSON `node_support`）。
  final String evidence;

  /// schema 是否声明了该属性。
  bool declaresAttr(String key) => attrKeys.contains(key);

  @override
  String toString() =>
      'OfficeSlidesNodeSpec($name, ${support.name}, ${attrKeys.length} attrs)';
}

/// 节点登记表。key 必须**逐字等于** `slides_schema.json.nodes[].name` 的集合
/// （由 `test/office_slides_view_test.dart` 现场读 JSON 断言）。
const Map<String, OfficeSlidesNodeSpec> kOfficeSlidesNodeSpecs =
    <String, OfficeSlidesNodeSpec>{
      'paragraph': OfficeSlidesNodeSpec(
        name: 'paragraph',
        content: 'inline<_>*',
        groups: <String>['basic_block', 'block'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['tabStops', 'textMarks', 'textAlign', 'lineHeight', 'paddingTop', 'paddingBottom', 'indentFirst', 'indentLeft', 'indentRight', 'listId', 'listLevel', 'listMarks', 'trackingSelf', 'trackingStart', 'trackingEnd'],
        support: OfficeSlidesNodeSupport.rendered,
        evidence: 'text-bearing block rendered by this batch',
      ),
      'text': OfficeSlidesNodeSpec(
        name: 'text',
        content: null,
        groups: <String>['inline'],
        isLeaf: true,
        isText: true,
        attrKeys: <String>[],
        support: OfficeSlidesNodeSupport.rendered,
        evidence: 'schema isText node — rendered as inline text',
      ),
      'hard_break': OfficeSlidesNodeSpec(
        name: 'hard_break',
        content: null,
        groups: <String>['inline'],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['trackingSelf'],
        support: OfficeSlidesNodeSupport.rendered,
        evidence: 'inline atom rendered as break/tab',
      ),
      'tab': OfficeSlidesNodeSpec(
        name: 'tab',
        content: null,
        groups: <String>['inline'],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['trackingSelf'],
        support: OfficeSlidesNodeSupport.rendered,
        evidence: 'inline atom rendered as break/tab',
      ),
      'table': OfficeSlidesNodeSpec(
        name: 'table',
        content: 'table_row+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['synotable', 'colgroup', 'parsed_width', 'parsed_height', 'trackingSelf', 'trackingStart', 'trackingEnd'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'table_row': OfficeSlidesNodeSpec(
        name: 'table_row',
        content: 'table_cell+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['parsed_empty', 'height', 'trackingSelf', 'trackingStart', 'trackingEnd'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'table_cell': OfficeSlidesNodeSpec(
        name: 'table_cell',
        content: 'basic_block block*',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['verticalAlign', 'backgroundColor', 'rowspan', 'colspan', 'borderLeftWidth', 'borderLeftStyle', 'borderLeftColor', 'borderTopWidth', 'borderTopStyle', 'borderTopColor', 'borderRightWidth', 'borderRightStyle', 'borderRightColor', 'borderBottomWidth', 'borderBottomStyle', 'borderBottomColor', 'codeBlock', 'trackingSelf', 'trackingStart', 'trackingEnd'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'text_line': OfficeSlidesNodeSpec(
        name: 'text_line',
        content: 'inline<_>*',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['trackingSelf', 'trackingStart', 'trackingEnd'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'table_parser': OfficeSlidesNodeSpec(
        name: 'table_parser',
        content: 'basic_block* table basic_block*',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>[],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'pseudo_list_item': OfficeSlidesNodeSpec(
        name: 'pseudo_list_item',
        content: null,
        groups: <String>[],
        isLeaf: true,
        isText: false,
        attrKeys: <String>[],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'leaf without text content: registered, not painted',
      ),
      'doc': OfficeSlidesNodeSpec(
        name: 'doc',
        content: 'settings master_container slide_container',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['schema', 'type', 'cx', 'cy'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'settings': OfficeSlidesNodeSpec(
        name: 'settings',
        content: null,
        groups: <String>[],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['sections'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'leaf without text content: registered, not painted',
      ),
      'master_container': OfficeSlidesNodeSpec(
        name: 'master_container',
        content: 'master+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>[],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'layout_container': OfficeSlidesNodeSpec(
        name: 'layout_container',
        content: 'layout+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>[],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'slide_container': OfficeSlidesNodeSpec(
        name: 'slide_container',
        content: 'slide*',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['page_num_enabled', 'date_time_enabled', 'page_num_skip_title', 'transition'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'master': OfficeSlidesNodeSpec(
        name: 'master',
        content: 'master_background master_content_container layout_container',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['trackingSelf', 'id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'layout': OfficeSlidesNodeSpec(
        name: 'layout',
        content: 'layout_background layout_content_container',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['trackingSelf', 'id', 'layout_name'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'slide': OfficeSlidesNodeSpec(
        name: 'slide',
        content: 'slide_background slide_content_container note',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['trackingSelf', 'master_id', 'layout_id', 'id', 'is_visible', 'transition', 'animations'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'master_background': OfficeSlidesNodeSpec(
        name: 'master_background',
        content: null,
        groups: <String>[],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['color', 'opacity', 'file_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'leaf without text content: registered, not painted',
      ),
      'layout_background': OfficeSlidesNodeSpec(
        name: 'layout_background',
        content: null,
        groups: <String>[],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['color', 'opacity', 'file_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'leaf without text content: registered, not painted',
      ),
      'slide_background': OfficeSlidesNodeSpec(
        name: 'slide_background',
        content: null,
        groups: <String>[],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['color', 'opacity', 'file_id', 'ref'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'leaf without text content: registered, not painted',
      ),
      'note': OfficeSlidesNodeSpec(
        name: 'note',
        content: 'basic_block+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'master_content_container': OfficeSlidesNodeSpec(
        name: 'master_content_container',
        content: '(content_object | master_content_object)*',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>[],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'layout_content_container': OfficeSlidesNodeSpec(
        name: 'layout_content_container',
        content: '(content_object | layout_content_object)*',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>[],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'slide_content_container': OfficeSlidesNodeSpec(
        name: 'slide_content_container',
        content: '(content_object | slide_content_object)*',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>[],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'title_master_holder': OfficeSlidesNodeSpec(
        name: 'title_master_holder',
        content: 'title_master_holder_shape',
        groups: <String>['master_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'sub_title_master_holder': OfficeSlidesNodeSpec(
        name: 'sub_title_master_holder',
        content: 'title_master_holder_shape',
        groups: <String>['master_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'body_master_holder': OfficeSlidesNodeSpec(
        name: 'body_master_holder',
        content: 'body_master_holder_shape',
        groups: <String>['master_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'page_number_master_holder': OfficeSlidesNodeSpec(
        name: 'page_number_master_holder',
        content: 'title_master_holder_shape',
        groups: <String>['master_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'date_time_master_holder': OfficeSlidesNodeSpec(
        name: 'date_time_master_holder',
        content: 'title_master_holder_shape',
        groups: <String>['master_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'title_master_holder_shape': OfficeSlidesNodeSpec(
        name: 'title_master_holder_shape',
        content: 'title_master_holder_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'body_master_holder_shape': OfficeSlidesNodeSpec(
        name: 'body_master_holder_shape',
        content: 'body_master_holder_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'title_master_holder_text_block': OfficeSlidesNodeSpec(
        name: 'title_master_holder_text_block',
        content: 'holder_paragraph',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding', 'placeholderText'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'body_master_holder_text_block': OfficeSlidesNodeSpec(
        name: 'body_master_holder_text_block',
        content: 'holder_paragraph[listId="_",listLevel=0] holder_paragraph[listId="_",listLevel=1] holder_paragraph[listId="_",listLevel=2] holder_paragraph[listId="_",listLevel=3] holder_paragraph[listId="_",listLevel=4] holder_paragraph[listId="_",listLevel=5] holder_paragraph[listId="_",listLevel=6] holder_paragraph[listId="_",listLevel=7] holder_paragraph[listId="_",listLevel=8]',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding', 'placeholderText'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'title_layout_holder': OfficeSlidesNodeSpec(
        name: 'title_layout_holder',
        content: 'title_layout_holder_shape',
        groups: <String>['layout_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'sub_title_layout_holder': OfficeSlidesNodeSpec(
        name: 'sub_title_layout_holder',
        content: 'title_layout_holder_shape',
        groups: <String>['layout_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'body_layout_holder': OfficeSlidesNodeSpec(
        name: 'body_layout_holder',
        content: 'body_layout_holder_shape',
        groups: <String>['layout_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'page_number_layout_holder': OfficeSlidesNodeSpec(
        name: 'page_number_layout_holder',
        content: 'title_layout_holder_shape',
        groups: <String>['layout_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'date_time_layout_holder': OfficeSlidesNodeSpec(
        name: 'date_time_layout_holder',
        content: 'title_layout_holder_shape',
        groups: <String>['layout_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'title_layout_holder_shape': OfficeSlidesNodeSpec(
        name: 'title_layout_holder_shape',
        content: 'title_layout_holder_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'body_layout_holder_shape': OfficeSlidesNodeSpec(
        name: 'body_layout_holder_shape',
        content: 'body_layout_holder_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'title_layout_holder_text_block': OfficeSlidesNodeSpec(
        name: 'title_layout_holder_text_block',
        content: 'holder_paragraph',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding', 'placeholderText'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'body_layout_holder_text_block': OfficeSlidesNodeSpec(
        name: 'body_layout_holder_text_block',
        content: 'holder_paragraph[listId="_",listLevel=0] holder_paragraph[listId="_",listLevel=1] holder_paragraph[listId="_",listLevel=2] holder_paragraph[listId="_",listLevel=3] holder_paragraph[listId="_",listLevel=4] holder_paragraph[listId="_",listLevel=5] holder_paragraph[listId="_",listLevel=6] holder_paragraph[listId="_",listLevel=7] holder_paragraph[listId="_",listLevel=8]',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding', 'placeholderText'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'text_box': OfficeSlidesNodeSpec(
        name: 'text_box',
        content: 'text_shape',
        groups: <String>['groupable_object', 'content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'table_box': OfficeSlidesNodeSpec(
        name: 'table_box',
        content: 'table_block',
        groups: <String>['content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'shape_box': OfficeSlidesNodeSpec(
        name: 'shape_box',
        content: 'shape',
        groups: <String>['groupable_object', 'content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'line_box': OfficeSlidesNodeSpec(
        name: 'line_box',
        content: 'line',
        groups: <String>['groupable_object', 'content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'image_box': OfficeSlidesNodeSpec(
        name: 'image_box',
        content: 'image',
        groups: <String>['groupable_object', 'content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'chart_box': OfficeSlidesNodeSpec(
        name: 'chart_box',
        content: 'chart',
        groups: <String>['groupable_object', 'content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'video_box': OfficeSlidesNodeSpec(
        name: 'video_box',
        content: 'video',
        groups: <String>['content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'text_shape': OfficeSlidesNodeSpec(
        name: 'text_shape',
        content: 'text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.degraded,
        evidence: 'visual node; geometry/image bytes channel not taken in this batch -> visible degraded card',
      ),
      'shape': OfficeSlidesNodeSpec(
        name: 'shape',
        content: 'shape_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config', 'shape_type', 'cust_points', 'custGeomDefinition'],
        support: OfficeSlidesNodeSupport.degraded,
        evidence: 'visual node; geometry/image bytes channel not taken in this batch -> visible degraded card',
      ),
      'line': OfficeSlidesNodeSpec(
        name: 'line',
        content: null,
        groups: <String>[],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'cxn_start_id', 'cxn_start_index', 'cxn_end_id', 'cxn_end_index', 'arrow_start', 'arrow_end', 'line_type', 'cust_points'],
        support: OfficeSlidesNodeSupport.degraded,
        evidence: 'visual node; geometry/image bytes channel not taken in this batch -> visible degraded card',
      ),
      'image': OfficeSlidesNodeSpec(
        name: 'image',
        content: null,
        groups: <String>[],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'file_id', 'alt', 'ref', 'opacity', 'shape_type', 'img_transform', 'cust_points'],
        support: OfficeSlidesNodeSupport.degraded,
        evidence: 'visual node; geometry/image bytes channel not taken in this batch -> visible degraded card',
      ),
      'chart': OfficeSlidesNodeSpec(
        name: 'chart',
        content: null,
        groups: <String>[],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'data', 'config'],
        support: OfficeSlidesNodeSupport.degraded,
        evidence: 'visual node; geometry/image bytes channel not taken in this batch -> visible degraded card',
      ),
      'video': OfficeSlidesNodeSpec(
        name: 'video',
        content: null,
        groups: <String>[],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'permanent_link', 'autoplay', 'muted', 'format', 'youtube_url'],
        support: OfficeSlidesNodeSupport.degraded,
        evidence: 'visual node; geometry/image bytes channel not taken in this batch -> visible degraded card',
      ),
      'text_block': OfficeSlidesNodeSpec(
        name: 'text_block',
        content: 'basic_block+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding'],
        support: OfficeSlidesNodeSupport.rendered,
        evidence: 'text-bearing block rendered by this batch',
      ),
      'table_block': OfficeSlidesNodeSpec(
        name: 'table_block',
        content: 'table',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'shape_text_block': OfficeSlidesNodeSpec(
        name: 'shape_text_block',
        content: 'basic_block+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding'],
        support: OfficeSlidesNodeSupport.rendered,
        evidence: 'text-bearing block rendered by this batch',
      ),
      'object_group': OfficeSlidesNodeSpec(
        name: 'object_group',
        content: 'groupable_object{2,}',
        groups: <String>['groupable_object', 'content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'title_slide_holder': OfficeSlidesNodeSpec(
        name: 'title_slide_holder',
        content: 'title_slide_holder_shape',
        groups: <String>['slide_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'sub_title_slide_holder': OfficeSlidesNodeSpec(
        name: 'sub_title_slide_holder',
        content: 'sub_title_slide_holder_shape',
        groups: <String>['slide_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'body_slide_holder': OfficeSlidesNodeSpec(
        name: 'body_slide_holder',
        content: 'body_slide_holder_shape',
        groups: <String>['slide_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'page_number_slide_holder': OfficeSlidesNodeSpec(
        name: 'page_number_slide_holder',
        content: 'page_number_slide_holder_shape',
        groups: <String>['slide_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'date_time_slide_holder': OfficeSlidesNodeSpec(
        name: 'date_time_slide_holder',
        content: 'date_time_slide_holder_shape',
        groups: <String>['slide_content_object'],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['id', 'transform', 'trackingSelf', 'synolink', 'type_id'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'title_slide_holder_shape': OfficeSlidesNodeSpec(
        name: 'title_slide_holder_shape',
        content: 'title_slide_holder_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'sub_title_slide_holder_shape': OfficeSlidesNodeSpec(
        name: 'sub_title_slide_holder_shape',
        content: 'sub_title_slide_holder_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'body_slide_holder_shape': OfficeSlidesNodeSpec(
        name: 'body_slide_holder_shape',
        content: 'body_slide_holder_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'page_number_slide_holder_shape': OfficeSlidesNodeSpec(
        name: 'page_number_slide_holder_shape',
        content: 'page_number_slide_holder_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'date_time_slide_holder_shape': OfficeSlidesNodeSpec(
        name: 'date_time_slide_holder_shape',
        content: 'date_time_slide_holder_text_block',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['stroke', 'stroke_config', 'fill', 'fill_config'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'title_slide_holder_text_block': OfficeSlidesNodeSpec(
        name: 'title_slide_holder_text_block',
        content: 'basic_block+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding', 'placeholderText'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'sub_title_slide_holder_text_block': OfficeSlidesNodeSpec(
        name: 'sub_title_slide_holder_text_block',
        content: 'basic_block+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding', 'placeholderText'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'body_slide_holder_text_block': OfficeSlidesNodeSpec(
        name: 'body_slide_holder_text_block',
        content: 'basic_block+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding', 'placeholderText'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'page_number_slide_holder_text_block': OfficeSlidesNodeSpec(
        name: 'page_number_slide_holder_text_block',
        content: 'basic_block+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding', 'placeholderText'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'date_time_slide_holder_text_block': OfficeSlidesNodeSpec(
        name: 'date_time_slide_holder_text_block',
        content: 'basic_block+',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['listMap', 'vertical_align', 'padding', 'placeholderText'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'container: registered, children rendered',
      ),
      'holder_paragraph': OfficeSlidesNodeSpec(
        name: 'holder_paragraph',
        content: 'inline<_>*',
        groups: <String>[],
        isLeaf: false,
        isText: false,
        attrKeys: <String>['tabStops', 'textMarks', 'textAlign', 'lineHeight', 'paddingTop', 'paddingBottom', 'indentFirst', 'indentLeft', 'indentRight', 'listId', 'listLevel', 'listMarks', 'placeholderText', 'trackingSelf', 'trackingStart', 'trackingEnd'],
        support: OfficeSlidesNodeSupport.rendered,
        evidence: 'text-bearing block rendered by this batch',
      ),
      'page_number': OfficeSlidesNodeSpec(
        name: 'page_number',
        content: null,
        groups: <String>['inline'],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['trackingSelf'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'leaf without text content: registered, not painted',
      ),
      'date_time': OfficeSlidesNodeSpec(
        name: 'date_time',
        content: null,
        groups: <String>['inline'],
        isLeaf: true,
        isText: false,
        attrKeys: <String>['fieldType', 'trackingSelf'],
        support: OfficeSlidesNodeSupport.structural,
        evidence: 'leaf without text content: registered, not painted',
      ),
    };

/// 全部 schema 节点名。
Set<String> get kOfficeSlidesNodeNames => kOfficeSlidesNodeSpecs.keys.toSet();

/// 查一个节点类型是否在 schema 里。
bool isOfficeSlidesNodeKnown(String name) => kOfficeSlidesNodeSpecs.containsKey(name);

/// schema 声明的属性键（未声明 → 未知字段，计数不崩）。
List<String> officeSlidesNodeAttrKeys(String nodeType) =>
    kOfficeSlidesNodeSpecs[nodeType]?.attrKeys ?? const <String>[];

/// 一个 mark（inline 或 block/attr）的登记。
class OfficeSlidesMarkSpec {
  const OfficeSlidesMarkSpec({
    required this.name,
    required this.rank,
    required this.isAttrMark,
    required this.attrKeys,
  });

  final String name;
  final int? rank;

  /// true = block/attr mark（`schema.attr_marks`，不在 `schema.marks` 里）。
  final bool isAttrMark;

  final List<String> attrKeys;

  @override
  String toString() => 'OfficeSlidesMarkSpec($name, rank: $rank, attr: $isAttrMark)';
}

/// mark 登记表。key 必须**逐字等于** `slides_schema.json` 的
/// `marks[].name ∪ attr_marks.*.name`（测试断言）。
const Map<String, OfficeSlidesMarkSpec> kOfficeSlidesMarkSpecs =
    <String, OfficeSlidesMarkSpec>{
      'font_size': OfficeSlidesMarkSpec(
        name: 'font_size',
        rank: 0,
        isAttrMark: false,
        attrKeys: <String>['value'],
      ),
      'font_family': OfficeSlidesMarkSpec(
        name: 'font_family',
        rank: 1,
        isAttrMark: false,
        attrKeys: <String>['value', 'eastAsia', 'complexScript', 'hint'],
      ),
      'em': OfficeSlidesMarkSpec(
        name: 'em',
        rank: 2,
        isAttrMark: false,
        attrKeys: <String>['value'],
      ),
      'strong': OfficeSlidesMarkSpec(
        name: 'strong',
        rank: 3,
        isAttrMark: false,
        attrKeys: <String>['value'],
      ),
      'link': OfficeSlidesMarkSpec(
        name: 'link',
        rank: 4,
        isAttrMark: false,
        attrKeys: <String>['href'],
      ),
      'color': OfficeSlidesMarkSpec(
        name: 'color',
        rank: 5,
        isAttrMark: false,
        attrKeys: <String>['value'],
      ),
      'background_color': OfficeSlidesMarkSpec(
        name: 'background_color',
        rank: 6,
        isAttrMark: false,
        attrKeys: <String>['value'],
      ),
      'superscript': OfficeSlidesMarkSpec(
        name: 'superscript',
        rank: 7,
        isAttrMark: false,
        attrKeys: <String>['value'],
      ),
      'subscript': OfficeSlidesMarkSpec(
        name: 'subscript',
        rank: 8,
        isAttrMark: false,
        attrKeys: <String>['value'],
      ),
      'underline': OfficeSlidesMarkSpec(
        name: 'underline',
        rank: 9,
        isAttrMark: false,
        attrKeys: <String>['value'],
      ),
      'strike': OfficeSlidesMarkSpec(
        name: 'strike',
        rank: 10,
        isAttrMark: false,
        attrKeys: <String>['value'],
      ),
      'tracking': OfficeSlidesMarkSpec(
        name: 'tracking',
        rank: 11,
        isAttrMark: false,
        attrKeys: <String>['id'],
      ),
      'direction': OfficeSlidesMarkSpec(
        name: 'direction',
        rank: 0,
        isAttrMark: true,
        attrKeys: <String>['value'],
      ),
      'line_height': OfficeSlidesMarkSpec(
        name: 'line_height',
        rank: 2,
        isAttrMark: true,
        attrKeys: <String>['value'],
      ),
      'text_align': OfficeSlidesMarkSpec(
        name: 'text_align',
        rank: 1,
        isAttrMark: true,
        attrKeys: <String>['value'],
      ),
      'text_indent': OfficeSlidesMarkSpec(
        name: 'text_indent',
        rank: 3,
        isAttrMark: true,
        attrKeys: <String>['value'],
      ),
    };

/// 全部 mark 名（inline + block/attr）。
Set<String> get kOfficeSlidesMarkNames => kOfficeSlidesMarkSpecs.keys.toSet();

/// 查一个 mark 名是否在 schema 里。
bool isOfficeSlidesMarkKnown(String name) => kOfficeSlidesMarkSpecs.containsKey(name);

/// 一条 step 词的静态证据（`jsonID("<name>", <Class>)` 的字节偏移）。
class OfficeSlidesStepSpec {
  const OfficeSlidesStepSpec(this.name, this.file, this.offset);

  final String name;
  final String file;
  final int offset;

  /// `文件@字节偏移`（与 `sheet_commands.json` 的 site 同口径）。
  String get site => '$file@$offset';

  @override
  String toString() => 'OfficeSlidesStepSpec($name, $site)';
}

/// step 词表（**`.oslides` 的"命令"对应物**：$steps.count 条）。
/// key 必须**逐字等于** `slides_schema.json.steps.entries[].name`。
const List<OfficeSlidesStepSpec> kOfficeSlidesStepSpecs = <OfficeSlidesStepSpec>[
  OfficeSlidesStepSpec('setNodeAttrs', kOfficeSlidesSchemaBundle, 1322764),
  OfficeSlidesStepSpec('addMark', kOfficeSlidesSchemaBundle, 1325591),
  OfficeSlidesStepSpec('removeMark', kOfficeSlidesSchemaBundle, 1326443),
  OfficeSlidesStepSpec('setRootNodeAttrs', kOfficeSlidesSchemaBundle, 1331062),
  OfficeSlidesStepSpec('orderNode', kOfficeSlidesSchemaBundle, 1334744),
  OfficeSlidesStepSpec('setChartConfig', kOfficeSlidesSchemaBundle, 1399113),
  OfficeSlidesStepSpec('setChartDataValue', kOfficeSlidesSchemaBundle, 1400172),
  OfficeSlidesStepSpec('insertTableRowV2', kOfficeSlidesSchemaBundle, 1445488),
  OfficeSlidesStepSpec('removeTableRowV2', kOfficeSlidesSchemaBundle, 1446496),
  OfficeSlidesStepSpec('insertTableRow', kOfficeSlidesSchemaBundle, 1446529),
  OfficeSlidesStepSpec('removeTableRow', kOfficeSlidesSchemaBundle, 1446672),
  OfficeSlidesStepSpec('insertTableColV2', kOfficeSlidesSchemaBundle, 1448352),
  OfficeSlidesStepSpec('removeTableColV2', kOfficeSlidesSchemaBundle, 1449371),
  OfficeSlidesStepSpec('insertTableCol', kOfficeSlidesSchemaBundle, 1449404),
  OfficeSlidesStepSpec('removeTableCol', kOfficeSlidesSchemaBundle, 1449571),
  OfficeSlidesStepSpec('addListMap', kOfficeSlidesSchemaBundle, 1499625),
  OfficeSlidesStepSpec('trimListMap', kOfficeSlidesSchemaBundle, 1500255),
  OfficeSlidesStepSpec('setListInfo', kOfficeSlidesSchemaBundle, 1501061),
  OfficeSlidesStepSpec('setListConfigs', kOfficeSlidesSchemaBundle, 1501856),
  OfficeSlidesStepSpec('createComment', kOfficeSlidesSchemaBundle, 1514817),
  OfficeSlidesStepSpec('removeComment', kOfficeSlidesSchemaBundle, 1514906),
  OfficeSlidesStepSpec('resolveComment', kOfficeSlidesSchemaBundle, 1514995),
  OfficeSlidesStepSpec('reopenComment', kOfficeSlidesSchemaBundle, 1515120),
  OfficeSlidesStepSpec('addCommentTracking', kOfficeSlidesSchemaBundle, 1529714),
  OfficeSlidesStepSpec('removeCommentTracking', kOfficeSlidesSchemaBundle, 1530365),
  OfficeSlidesStepSpec('renameTextMarks', kOfficeSlidesSchemaBundle, 1549298),
  OfficeSlidesStepSpec('refineTextblock', kOfficeSlidesSchemaBundle, 1550986),
  OfficeSlidesStepSpec('fillEmptyTableRow', kOfficeSlidesSchemaBundle, 1552043),
  OfficeSlidesStepSpec('flattenNode', kOfficeSlidesSchemaBundle, 1553333),
  OfficeSlidesStepSpec('flattenList', kOfficeSlidesSchemaBundle, 1555258),
  OfficeSlidesStepSpec('eraseMark', kOfficeSlidesSchemaBundle, 1555750),
  OfficeSlidesStepSpec('separateLinkStyle', kOfficeSlidesSchemaBundle, 1556078),
  OfficeSlidesStepSpec('flattenComment', kOfficeSlidesSchemaBundle, 1559351),
  OfficeSlidesStepSpec('inheritCustomStyle', kOfficeSlidesSchemaBundle, 1656445),
  OfficeSlidesStepSpec('documentPrependBasicBlock', kOfficeSlidesSchemaBundle, 1656639),
  OfficeSlidesStepSpec('transformFloating', kOfficeSlidesSchemaBundle, 1806011),
  OfficeSlidesStepSpec('fixGroup', kOfficeSlidesSchemaBundle, 1806045),
  OfficeSlidesStepSpec('groupFloating', kOfficeSlidesSchemaBundle, 1806086),
  OfficeSlidesStepSpec('groupFloatingV2', kOfficeSlidesSchemaBundle, 1808646),
  OfficeSlidesStepSpec('ungroupFloating', kOfficeSlidesSchemaBundle, 1809882),
  OfficeSlidesStepSpec('insertFloating', kOfficeSlidesSchemaBundle, 1810859),
  OfficeSlidesStepSpec('liftDownFloating', kOfficeSlidesSchemaBundle, 1812558),
  OfficeSlidesStepSpec('deleteFloating', kOfficeSlidesSchemaBundle, 1815086),
  OfficeSlidesStepSpec('insertSlideAnimation', kOfficeSlidesSchemaBundle, 1815474),
  OfficeSlidesStepSpec('removeSlideAnimation', kOfficeSlidesSchemaBundle, 1815507),
  OfficeSlidesStepSpec('reorderSlideAnimation', kOfficeSlidesSchemaBundle, 1815540),
  OfficeSlidesStepSpec('modifySlideAnimation', kOfficeSlidesSchemaBundle, 1815571),
  OfficeSlidesStepSpec('setSlideAnimation', kOfficeSlidesSchemaBundle, 1815601),
  OfficeSlidesStepSpec('presentationRefineTextblock', kOfficeSlidesSchemaBundle, 1818408),
  OfficeSlidesStepSpec('presentationFlattenList', kOfficeSlidesSchemaBundle, 1818622),
  OfficeSlidesStepSpec('presentationPrependBasicBlock', kOfficeSlidesSchemaBundle, 1818774),
];

/// 全部 step 名。
Set<String> get kOfficeSlidesStepNames =>
    kOfficeSlidesStepSpecs.map((s) => s.name).toSet();

/// 查一个 step 名是否登记（`Step.stepClass` 只认这些；不认识 = 未知，计数不崩）。
bool isOfficeSlidesStepKnown(String name) =>
    kOfficeSlidesStepNames.contains(name);

/// `V<digits>` 后缀的 step 名（`Step.normalizeStepId` 会把后缀去掉）。
const Set<String> kOfficeSlidesVersionedStepNames = <String>{
  'insertTableRowV2',
  'removeTableRowV2',
  'insertTableColV2',
  'removeTableColV2',
  'groupFloatingV2',
};

/// step registry / dispatcher 的函数位置（`文件@偏移`；来自 JSON
/// `steps.registry_functions`）。测试与 JSON 逐条比对。
class OfficeSlidesStepRegistryFn {
  const OfficeSlidesStepRegistryFn(this.name, this.offset, this.evidence);

  final String name;
  final int offset;
  final String evidence;

  String get site => '$kOfficeSlidesSchemaBundle@$offset';

  @override
  String toString() => 'OfficeSlidesStepRegistryFn($name, $site)';
}

const List<OfficeSlidesStepRegistryFn> kOfficeSlidesStepRegistryFns =
    <OfficeSlidesStepRegistryFn>[
  OfficeSlidesStepRegistryFn('register', 1309200, 'static register(t,e=this){if(t in uc)throw RangeError(`Duplicate use of step JSON ID \\`\${t}\\`.`);uc[t]=e,e.stepType=t,e.prototype.jsonID=t}static jsonID(t,e){re'),
  OfficeSlidesStepRegistryFn('jsonID', 1309339, 'static jsonID(t,e){return this.register(t,e),e}static stepClass(t){let e=uc[t];if(!e)throw RangeError(`No step named \${t}`);return e}static normalizeStepId(t){r'),
  OfficeSlidesStepRegistryFn('stepClass', 1309386, 'static stepClass(t){let e=uc[t];if(!e)throw RangeError(`No step named \${t}`);return e}static normalizeStepId(t){return t.replace(/V\\d+\$/i,"")}}cc.prototype.json'),
  OfficeSlidesStepRegistryFn('normalizeStepId', 1309472, 'static normalizeStepId(t){return t.replace(/V\\d+\$/i,"")}}cc.prototype.jsonID="";class pc extends cc{doApply(t,e){return t}static fromJSON(t,e){return new this}}'),
  OfficeSlidesStepRegistryFn('fromJSONDispatch', 1309130, 's(e.stepType).fromJSON(t,e)}static create(...t){return new this(...t)}static register(t,e=this){if(t in uc)throw RangeError(`Duplicate use of step JSON ID \\`\${t'),
];

/// step 协议的已确证契约（原文见 `slides_schema.json.steps.contract`）：
///   * registry  = 一个以 JSON id 为键的表；重复 id 直接抛错；
///   * dispatcher= `Step.stepClass(e.stepType).fromJSON(t,e)`；
///   * 序列化     = `toJSON() → {stepType:<jsonID>, …}`，`normalizeStepId` 去 `V\d+` 后缀。
const String kOfficeSlidesStepRegistry = 'a module-level map `uc` keyed by the JSON id; `register()` throws on duplicates';
const String kOfficeSlidesStepDispatcher = 'Step.stepClass(name) -> class; Step.fromJSON dispatches via `stepClass(e.stepType).fromJSON(t,e)`';
const String kOfficeSlidesStepSerialization = 'step.toJSON() emits `{stepType:<jsonID>, …}`; `normalizeStepId` strips a trailing `V<digits>`';
const String kOfficeSlidesStepDispatcherNote = 'there is no `switch(cmd)` dispatcher for presentations: step JSON ids are looked up by `Step.stepClass(e.stepType)`; the registry is the analogue of the sheet command table';

// ---------------------------------------------------------------------------
// section / 字段登记（真实制品证据）
// ---------------------------------------------------------------------------

/// section ↔ BSON 字段名：`"@C_text/" + <section>`（与 `.odoc`/`.osheet` 同一命名）。
String officeSlidesSectionKey(String section) => '@C_text/$section';

/// `.oslides` 的 section 覆盖登记。
enum OfficeSlidesSectionSupport {
  /// 本批真的用它渲染幻灯片（`content`）。
  rendered,

  /// 确证存在、本批只登记不解释其内容（`index` / `comment` / `file`）。
  structural,

  /// 名称已确证但本批不渲染。
  degraded,

  /// 词表/制品都没有这个 section 名 → 未知，计数但**不崩**。
  unknown,
}

/// section 的登记：支持度 + 依据。
class OfficeSlidesSectionEvidence {
  const OfficeSlidesSectionEvidence(this.support, this.evidence);

  final OfficeSlidesSectionSupport support;
  final String evidence;

  @override
  String toString() => 'OfficeSlidesSectionEvidence(${support.name})';
}

/// 固定 section 名的覆盖表。key 必须**逐字等于** `slides_schema.json`
/// `observed.section_keys`（测试现场读 JSON 断言）。
const Map<String, OfficeSlidesSectionEvidence> kOfficeSlidesSections =
    <String, OfficeSlidesSectionEvidence>{
  'comment': OfficeSlidesSectionEvidence(
    OfficeSlidesSectionSupport.structural,
    'observed.section_keys.comment（26/26）；帧里为 null 或 {data:[],format:1}',
  ),
  'content': OfficeSlidesSectionEvidence(
    OfficeSlidesSectionSupport.rendered,
    'observed.section_keys.content（26/26 份样本：24 份官方主题 template/slides/<theme>/text.json + 2 帧真机 Snapshot:get v4）；office-collab-schema-export.md §C \'oslides = index/content/comment\'',
  ),
  'file': OfficeSlidesSectionEvidence(
    OfficeSlidesSectionSupport.structural,
    'observed.section_keys.file（2/2 真机 Snapshot:get v4；内容为内嵌图片引用）',
  ),
  'index': OfficeSlidesSectionEvidence(
    OfficeSlidesSectionSupport.structural,
    'observed.section_keys.index（24/24 份官方主题样本；真机 Snapshot:get v4 不回 index —— 见 observed.snapshot_data_keys）',
  ),
};

/// 查 section 覆盖度；查不到 = `unknown`（可见降级）。
OfficeSlidesSectionEvidence officeSlidesSectionEvidence(String name) =>
    kOfficeSlidesSections[name] ??
    const OfficeSlidesSectionEvidence(
      OfficeSlidesSectionSupport.unknown,
      '真实制品/词表里没有这个 section 名（未知 → 计数，不崩）',
    );

/// `content` section 的已知键（observed.content_keys；26/26 份样本）。
const Set<String> kOfficeSlidesContentKeys = <String>{'data', 'version'};

/// `content.data` 的已知键（observed.content_data_keys；26/26：
/// `attrs` / `content` / `type` —— 注意 `data.type` 是 ProseMirror 节点名
/// （`"doc"`），与根 `attrs.type`（`"presentation"`）不是一回事）。
const Set<String> kOfficeSlidesContentDataKeys = <String>{'attrs', 'content', 'type'};

/// 根 `attrs` 的已知键（observed.root_attr_keys；26/26 实测 `{cx,cy,schema,type}`）。
const Set<String> kOfficeSlidesRootAttrKeys = <String>{'cx', 'cy', 'schema', 'type'};

/// `index` section 的已知键（24/24 份模板只有 `schemaVersion`）。
const Set<String> kOfficeSlidesIndexKeys = <String>{'schemaVersion'};

/// `comment` section 的已知键（帧里 `null` 或 `{data:[], format:1}`；
/// 模板里 `{data:[]}`）。
const Set<String> kOfficeSlidesCommentKeys = <String>{'data', 'format'};

/// `SYNO.Office.Snapshot:get v4` 回包 `data` 的信封键（2/2 帧实测）。
const Set<String> kOfficeSlidesSnapshotDataKeys = <String>{
  'comment',
  'content',
  'file',
  'ntype',
  'object_id',
};

/// 真实制品证据规模（`observed`）：24 份官方主题模板 + 2 帧真机 Snapshot:get；节点类型 52 种、mark 5 种，**没有一种**落在 schema 之外（`node_types_not_in_schema` / `marks_not_in_schema` 都为空）；另有 11 个真实属性键**未被 schema 声明**（`attr_keys_not_declared`）——它们必须走"未知字段"可见计数，不许静默丢。
