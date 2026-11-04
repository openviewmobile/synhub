// Office C′ 编辑器 UI 批 2 —— **编辑链路的位置算术与 step 构造**（纯 Dart，可离线单测）。
//
// 本文件只做两件事：
//   1. 把 UI 里一个"逻辑目标"（某一段落的第几个字符、某个选区）翻译成 M2 的
//      step（`ReplaceStep` / `AddMarkStep` / `RemoveMarkStep` /
//      `SetNodeAttrsStep` / `SetRootNodeAttrsStep`）；
//   2. 为**本批实际会发出的 step 类型**实现逆 step（单步撤销用）。
//
// ## 位置算术（硬要求：必须用 `DocSchema.nodeSize`）
//
// 位置的唯一来源是 M1 的 `DocSchema.nodeSize(DocNode)`（`doc_schema.dart:842`，
// 三条规则 text=长度 / isLeaf&&!isText=1 / 其余=sum+2，见
// `docs/office-collab-protocol-spike.md` §2.4 真机锚点）。本文件**没有**自己
// 造一套偏移规则：`_size` 直接调 `DocSchema.document.nodeSize`，所有绝对位置都
// 由它沿"根 → 子"累加得到。落点见 `officeDocNodeStart`。
//
// ## openLeft / openRight / structure
//
// 文本编辑一律 `openLeft = openRight = 0`、`structure = false`：
//   * `structure` 在 M2 已被证明是 **write-only**（`ReplaceStep.fromJSON` 从不读它，
//     `doc_step.dart:858-869`），本批**不发** `structure`（`DocOtSession.sendStructure`
//     默认 false，`doc_ot_session.dart:309-316` 会在发送前剥掉）；
//   * `openLeft/openRight` 的非零形态只用于"拆分/合并段落"的结构编辑，本批**不做**
//     段落拆分/合并（那需要 `ReplaceAroundStep` 语义，M2 未移植，见
//     `doc_step.dart:9-19` 的 SCOPE）。
//
// ## 证据边界（每一条都要能指到向量或 schema 条目）
//
//   * 文本 `replace`：`transform_vectors.json` `.vectors.text[*]`
//     （`insert-text-mid-marker` / `replace-range-with-text` / 删除 …）。
//   * `addMark` 的 presence mark：`.vectors.mark[add-strong-presence]` /
//     `[add-em-presence]` / `[add-underline-presence]`（mark 形状就是 `{"_":"strong"}`）。
//   * `removeMark`：`.vectors.mark[remove-strong]` / `[clear-all-marks]`。
//   * `setNodeAttrs`：`.vectors.attrs[set-paragraph-text-align]` /
//     `[set-paragraph-line-height]`（`{"stepType":"setNodeAttrs","pos":20,"attrs":{…}}`）。
//   * `setRootNodeAttrs`：`.vectors.attrs[set-root-page-setup-*]`。
//   * 标题级别：schema `kDocNodeSpecs["paragraph"].attrs.headingLevel` /
//     `kAttrKeyOrder["paragraph"]`；夹具 `style_editor` 的 7 个 `style_paragraph`
//     给出 `headingLevel` 0..5 + `headingId:"_heading0..5"` 的语义。**没有**任何向量
//     写过正文 `headingLevel`（真机判据见报告 ⑫）。
//   * 列表：schema `kDocNodeSpecs["paragraph"].attrs.{listId,listLevel,listMarks}` +
//     夹具 `edit_area.listMap`（恒 `{}`）。**取值形态未取证**，本批只用"attr 名 +
//     `SetNodeAttrsStep`"这条已验证通道，`listId` 取本地生成的稳定串并在报告登记。
import '../../core/i18n/data_text.dart';
import '../../data/office_collab/doc_schema.dart';
import '../../data/office_collab/doc_step.dart';

final DocSchema _schema = DocSchema.document;

/// 一个可编辑段落在文档树里的位置：从根开始的子节点下标路径。
///
/// 例：`dart_fetched_doc_v1.json` 的正文段落是 `doc.content[3](edit_area)
/// .content[0](paragraph)` → `[3, 0]`。
class OfficeDocPath {
  const OfficeDocPath(this.indices);

  final List<int> indices;

  String get key => indices.join('.');

  @override
  bool operator ==(Object other) =>
      other is OfficeDocPath && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'OfficeDocPath($key)';
}

/// 文本选区：段落路径 + 段落**纯文本**里的字符区间 `[start, end)`。
class OfficeDocTextSelection {
  const OfficeDocTextSelection({
    required this.path,
    required this.start,
    required this.end,
  });

  final OfficeDocPath path;
  final int start;
  final int end;

  bool get isCollapsed => start == end;

  int get length => end - start;

  @override
  String toString() => 'OfficeDocTextSelection(${path.key}, $start..$end)';
}

/// 位置算术从根开始：一个节点的绝对起点。
///
/// **只用 `DocSchema.nodeSize`**（M1）算尺寸；偏移约定照 M2 已取证的
/// `DocResolvedPos`（`doc_step.dart:363-384`，与官方 ProseMirror 一致）：
///   * **根（`doc`）的子节点从 0 开始**——`doc` 自身的 `+2` 不在位置空间里，
///     所以第一个顶层子节点在位置 0；
///   * **非根容器的子节点从 `parentStart + 1` 开始**（进入容器要跨过它的
///     opening token）。
/// 两者都不是本文件发明的规则：它是 `_resolve` 的实际行为，且测试里用
/// `DocResolvedPos.resolve(...).self` 逐点交叉验证。
int officeDocNodeStart(DocNode root, OfficeDocPath path) {
  var start = 0;
  var node = root;
  for (var depth = 0; depth < path.indices.length; depth++) {
    final index = path.indices[depth];
    final kids = node.content;
    if (kids == null || index < 0 || index >= kids.length) {
      throw DocRangeError('路径 ${path.key} 在节点 ${node.type} 处越界');
    }
    var cur = start + (depth == 0 ? 0 : 1);
    for (var i = 0; i < index; i++) {
      cur += officeDocNodeSize(kids[i]);
    }
    start = cur;
    node = kids[index];
  }
  return start;
}

/// 一个容器的内容起点（根 = 0，其余 = `nodeStart + 1`）。
int officeDocContentStart(DocNode root, OfficeDocPath path) =>
    path.indices.isEmpty ? 0 : officeDocNodeStart(root, path) + 1;

/// 节点在文档里的 M1 `nodeSize`。
int officeDocNodeSize(DocNode node) => _schema.nodeSize(node);

/// 找到**恰好从 [pos] 开始**的节点（等价于 M2 `ResolvedPos.self`，但走 M1
/// `nodeSize`）。用于逆 step 读回旧属性。
///
/// 注意 `pos == 0` 时 `self` 是**第一个顶层子节点**（不是根本身）——这是
/// `DocResolvedPos.self` 的实际语义（`doc_step.dart:440`）。
DocNode? officeDocNodeAt(DocNode root, int pos) {
  var node = root;
  var start = 0;
  var isRoot = true;
  while (true) {
    final kids = node.content;
    if (kids == null || kids.isEmpty) return null;
    var cur = isRoot ? start : start + 1;
    DocNode? next;
    for (final child in kids) {
      final size = officeDocNodeSize(child);
      if (pos == cur) return child;
      if (pos < cur + size) {
        next = child;
        break;
      }
      cur += size;
    }
    if (next == null) return null;
    node = next;
    start = cur;
    isRoot = false;
  }
}

// ---------------------------------------------------------------------------
// 段落纯文本与 mark 视图
// ---------------------------------------------------------------------------

/// 一段可编辑内联内容的纯文本 + 每个字符的 mark 名集合。
class OfficeDocInlineText {
  const OfficeDocInlineText(this.text, this.markNames);

  final String text;

  /// 与 [text] 等长：第 i 个字符覆盖的 mark 名集合。
  final List<Set<String>> markNames;

  int get length => text.length;

  Set<String> marksIn(int start, int end) {
    final out = <String>{};
    if (end <= start) return out;
    for (var i = start; i < end; i++) {
      out.addAll(markNames[i]);
    }
    return out;
  }

  bool fullyMarked(int start, int end, String name) {
    if (end <= start) return false;
    for (var i = start; i < end; i++) {
      if (!markNames[i].contains(name)) return false;
    }
    return true;
  }
}

/// 把段落的内联内容摊平成纯文本；节点含 `hard_break`/`tab` 等非 text 内联时返回
/// null（本批不支持——那会需要 span↔字符的二级映射，登记为未取证）。
OfficeDocInlineText? officeDocInlineText(DocNode paragraph) {
  final kids = paragraph.content;
  if (kids == null) return const OfficeDocInlineText('', <Set<String>>[]);
  final buffer = StringBuffer();
  final marks = <Set<String>>[];
  for (final child in kids) {
    if (!child.isText) return null;
    final text = child.text ?? '';
    final names = <String>{
      for (final m in child.marks ?? const <DocMark>[]) m.name,
    };
    buffer.write(text);
    for (var i = 0; i < text.length; i++) {
      marks.add(names);
    }
  }
  return OfficeDocInlineText(buffer.toString(), marks);
}

/// 该节点能不能作为本批的可编辑块：是 `paragraph`（或其 schema 同型的 inline 容器）
/// 且内联内容可摊平。
bool officeDocIsEditableBlock(DocNode node) =>
    node.type == 'paragraph' && officeDocInlineText(node) != null;

// ---------------------------------------------------------------------------
// step 构造
// ---------------------------------------------------------------------------

/// 文本编辑 → `ReplaceStep`（`openLeft=openRight=0`，`structure=false`）。
///
/// [charFrom]/[charTo] 是段落**纯文本**字符下标；绝对位置 =
/// `officeDocContentStart(root, path) + 字符下标`。
ReplaceStep officeDocReplaceText(
  DocNode root,
  OfficeDocPath path, {
  required int charFrom,
  required int charTo,
  required String insert,
}) {
  final inline = _requireEditable(root, path);
  if (charFrom < 0 || charTo < charFrom || charTo > inline.length) {
    throw DocRangeError('纯文本区间 $charFrom..$charTo 越界（长度 ${inline.length}）');
  }
  final base = officeDocContentStart(root, path);
  final slice = insert.isEmpty
      ? null
      : DocSlice(<DocJson>[
          <String, Object?>{'type': 'text', 'text': insert},
        ], 0, 0);
  return ReplaceStep(base + charFrom, base + charTo, slice ?? DocSlice.empty, false);
}

/// presence mark（strong/em/underline）→ `AddMarkStep`。
AddMarkStep officeDocAddPresenceMark(
  DocNode root,
  OfficeDocPath path, {
  required int charFrom,
  required int charTo,
  required String markName,
}) {
  _requireEditable(root, path);
  _requirePresenceMark(markName);
  final base = officeDocContentStart(root, path);
  return AddMarkStep(base + charFrom, base + charTo, <String, Object?>{
    '_': markName,
  });
}

/// presence mark → `RemoveMarkStep`。
RemoveMarkStep officeDocRemovePresenceMark(
  DocNode root,
  OfficeDocPath path, {
  required int charFrom,
  required int charTo,
  required String markName,
}) {
  _requireEditable(root, path);
  _requirePresenceMark(markName);
  final base = officeDocContentStart(root, path);
  return RemoveMarkStep(base + charFrom, base + charTo, <String, Object?>{
    '_': markName,
  });
}

/// 标题级别 → `SetNodeAttrsStep(pos=<段落起点>, {headingLevel: level})`。
///
/// `level == 0` = 正文（夹具 `style_paragraph` 的 `headingLevel:0` 即最外层标题样式
/// 之前的"正文"位；渲染器 `_headingStyle` 只把 1..6 当标题）。
SetNodeAttrsStep officeDocSetHeadingLevel(
  DocNode root,
  OfficeDocPath path,
  int level,
) {
  if (level < 0 || level > 9) {
    throw DocRangeError('headingLevel $level 超出 0..9');
  }
  return SetNodeAttrsStep(officeDocNodeStart(root, path), <String, Object?>{
    'headingLevel': level,
  });
}

/// 列表 → `SetNodeAttrsStep(pos=<段落起点>, {listId, listLevel, listMarks})`。
///
/// ⚠️ `listId` 的具体取值规则**未取证**（见文件头）；调用方给 [listId]。
/// `off` 时用 `null` 删除三个 attr（M2 的 `mergeSettableAttrs` 把 `null` 当删除，
/// `doc_step.dart:176-197`；schema 里三者都 `optional:true`）。
SetNodeAttrsStep officeDocSetList(
  DocNode root,
  OfficeDocPath path, {
  required bool on,
  String listId = '',
  int listLevel = 0,
}) {
  final pos = officeDocNodeStart(root, path);
  if (!on) {
    return SetNodeAttrsStep(pos, <String, Object?>{
      'listId': null,
      'listLevel': null,
      'listMarks': null,
    });
  }
  return SetNodeAttrsStep(pos, <String, Object?>{
    'listId': listId,
    'listLevel': listLevel,
    'listMarks': const <Object?>[],
  });
}

/// 文档根属性 → `SetRootNodeAttrsStep`（`attrs` 调用方给，形状照
/// `.vectors.attrs[set-root-*]`）。
SetRootNodeAttrsStep officeDocSetRootAttrs(Map<String, Object?> attrs) =>
    SetRootNodeAttrsStep(attrs);

OfficeDocInlineText _requireEditable(DocNode root, OfficeDocPath path) {
  final start = officeDocNodeStart(root, path);
  final node = officeDocNodeAt(root, start);
  if (node == null) {
    throw DocRangeError('路径 ${path.key} 指向的位置 $start 上没有节点');
  }
  final inline = officeDocInlineText(node);
  if (inline == null) {
    throw DocRangeError('节点 ${node.type} 含非 text 内联内容，本批不支持编辑');
  }
  return inline;
}

const Set<String> kOfficeDocPresenceMarks = <String>{
  'strong',
  'em',
  'underline',
};

void _requirePresenceMark(String markName) {
  if (!kOfficeDocPresenceMarks.contains(markName)) {
    throw DocRangeError('本批只支持 presence mark $kOfficeDocPresenceMarks，'
        '收到 $markName');
  }
}

// ---------------------------------------------------------------------------
// 逆 step（单步撤销）—— 只覆盖本批实际发出的 step 类型
// ---------------------------------------------------------------------------

/// 逆 step 的**纯函数**实现：给定 step 作用**之前**的文档 [beforeDoc]（原始
/// `DocJson`），返回能把 step 的效果还原的逆 step；不支持的类型返回 null
/// （调用方必须据此**禁用**撤销，不许假装成功）。
///
/// 覆盖：`ReplaceStep` / `AddMarkStep` / `RemoveMarkStep` / `SetNodeAttrsStep` /
/// `SetRootNodeAttrsStep`。这与 M2 `DocStep` 家族一一对应——M2 **没有** invert
/// （见批 2 报告 ④），所以逆 step 由本层实现，不在 `office_collab/**` 里加。
DocStep? officeDocInvertStep(DocStep step, DocJson beforeDoc) {
  final before = DocNode.fromRawJson(beforeDoc);
  switch (step) {
    case ReplaceStep():
      // 本批只发出 `openLeft==openRight==0` 的文本 replace；非零 open 深度的
      // 结构编辑（拆分/合并）本批不做，逆 step 也**不假装**支持。
      if (step.slice.openLeft != 0 || step.slice.openRight != 0) return null;
      // ProseMirror 的 `ReplaceStep.invert`: 用 before 里被删掉的那段 slice
      // 覆盖掉刚插入的范围 `[from, from + slice.size)`。
      final from = step.from;
      final to = from + step.slice.size;
      final removed = docSlice(beforeDoc, step.from, step.to);
      return ReplaceStep(from, to, removed, false);
    case AddMarkStep():
      return RemoveMarkStep(step.from, step.to, <String, Object?>{...step.mark});
    case RemoveMarkStep():
      return AddMarkStep(step.from, step.to, <String, Object?>{...step.mark});
    case SetNodeAttrsStep():
      final node = officeDocNodeAt(before, step.pos);
      if (node == null) return null;
      final specs = _schema.nodes[node.type]?.attrs ??
          const <String, DocAttrSpec>{};
      return SetNodeAttrsStep(
        step.pos,
        _invertAttrs(node.attrs, step.attrs, specs),
      );
    case SetRootNodeAttrsStep():
      final specs = _schema.nodes[before.type]?.attrs ??
          const <String, DocAttrSpec>{};
      return SetRootNodeAttrsStep(_invertAttrs(before.attrs, step.attrs, specs));
    default:
      return null;
  }
}

/// 逆属性：对 [incoming] 里每一个 key，取 [existing] 里**同一层级**的原值
/// （缺省 = null = 删除）。composite（`deep`）attr 递归处理，和 M2
/// `mergeSettableAttrs` 的递归合并对称。
Map<String, Object?> _invertAttrs(
  Map<String, Object?> existing,
  Map<String, Object?> incoming,
  Map<String, DocAttrSpec> specs,
) {
  final out = <String, Object?>{};
  incoming.forEach((key, value) {
    final spec = specs[key];
    final had = existing.containsKey(key);
    if (value is Map && spec != null && spec.deep.isNotEmpty) {
      final ex = existing[key];
      out[key] = _invertAttrs(
        ex is Map ? ex.cast<String, Object?>() : <String, Object?>{},
        value.cast<String, Object?>(),
        spec.deep,
      );
    } else {
      out[key] = had ? existing[key] : null;
    }
  });
  return out;
}

// ---------------------------------------------------------------------------
// 便于 UI/按钮态判断与 411 文案
// ---------------------------------------------------------------------------

/// 选区是否**整段**都已带上某个 presence mark（决定工具栏点一下是加还是取消）。
bool officeDocSelectionFullyMarked(
  DocNode root,
  OfficeDocTextSelection selection,
  String markName,
) {
  final node = officeDocNodeAt(root, officeDocNodeStart(root, selection.path));
  if (node == null) return false;
  final inline = officeDocInlineText(node);
  if (inline == null) return false;
  return inline.fullyMarked(selection.start, selection.end, markName);
}

/// 411（`Invalid command`）时告诉用户"哪一步没生效"的文案。
String officeDocDescribeStep(DocStep step) {
  switch (step) {
    case ReplaceStep():
      if (step.from == step.to && step.slice.size == 0) {
        return dataText('officeDocStepEmptyEdit', '空编辑');
      }
      if (step.slice.size == 0) {
        return dataText(
          'officeDocStepDeleteText',
          '删除文本（位置 ${step.from}..${step.to}）',
        )
            .replaceAll('{from}', '${step.from}')
            .replaceAll('{to}', '${step.to}');
      }
      final inserted = _firstText(step.slice) ?? '';
      if (step.from == step.to) {
        return dataText('officeDocStepInsertText', '插入文本“$inserted”')
            .replaceAll('{text}', inserted);
      }
      return dataText('officeDocStepReplaceText', '替换文本为“$inserted”')
          .replaceAll('{text}', inserted);
    case AddMarkStep():
      return dataText(
        'officeDocStepAddMark',
        '添加格式 ${_markLabel(step.mark)}',
      ).replaceAll('{mark}', _markLabel(step.mark));
    case RemoveMarkStep():
      return dataText(
        'officeDocStepRemoveMark',
        '取消格式 ${_markLabel(step.mark)}',
      ).replaceAll('{mark}', _markLabel(step.mark));
    case SetNodeAttrsStep():
      if (step.attrs.containsKey('headingLevel')) {
        return dataText(
          'officeDocStepSetHeading',
          '设置标题级别 ${step.attrs['headingLevel']}',
        ).replaceAll('{level}', '${step.attrs['headingLevel']}');
      }
      if (step.attrs.containsKey('listId')) {
        return dataText('officeDocStepSetList', '设置列表');
      }
      final attrs = step.attrs.keys.join(dataText('listSeparator', '、'));
      return dataText('officeDocStepSetParagraphAttrs', '设置段落属性 $attrs')
          .replaceAll('{attrs}', attrs);
    case SetRootNodeAttrsStep():
      final attrs = step.attrs.keys.join(dataText('listSeparator', '、'));
      return dataText('officeDocStepSetDocAttrs', '设置文档属性 $attrs')
          .replaceAll('{attrs}', attrs);
    default:
      return dataText('officeDocStepEdit', '编辑（${step.stepType}）')
          .replaceAll('{type}', step.stepType);
  }
}

String? _firstText(DocSlice slice) {
  for (final node in slice.content) {
    if (node['type'] == 'text') return node['text'] as String?;
  }
  return null;
}

final Map<String, String> _markLabels = <String, String>{
  'strong': dataText('officeDocBold', '加粗'),
  'em': dataText('officeDocItalic', '斜体'),
  'underline': dataText('officeDocUnderline', '下划线'),
};

String _markLabel(Map<String, Object?> mark) {
  final name = '${mark['_'] ?? mark['type'] ?? ''}';
  return _markLabels[name] ?? name;
}
