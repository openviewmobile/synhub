// Office C′ 演示文稿（Slides）批 2 —— **编辑链路**（纯逻辑，可离线单测）。
//
// 本文件只做 `.oslides` 的**写侧状态机**，不做任何 UI/socket 细节：
//   * 位置算术（**必须**用 `kOfficeSlidesNodeSpecs[type].isLeaf` 判定叶子，
//     见下方"证据边界"）；
//   * 文本编辑 → `replace` step JSON（含 `from`/`to`/`slice`）；
//   * `event` 回包的三态解析（`[null,{version}]` / `[{status:402|411|408}]`）；
//   * 未确认 step 队列 + 乐观显示 + **version 过期（402）的四步重放**：
//         undo 本地未确认改动 → `poll` 远端增量并重放到 base → redo 本地改动 →
//         `_version` 对齐服务端后**重发**（绝不丢用户输入）。
//
// ## 本批最重要的**证据修正**（真机探针，见 `docs/office-slides-ui-2.md` §①）
//
// 批 1 把演示文稿的会话按 `.odoc`/`.osheet` 的"同族 `[identifier, rev, steps]`"
// 推断成 `emit('init')`，并预备按表格的 `[revIncoming, currentRev, status]` 三态
// 解析。**真机探针证明这是错的**：
//
//   * `emit('init')` **没有任何 ack**（12s 超时）；演示文稿客户端用的是
//     `fetch`（服务端 `ui.presentation.js` 的 `SYNO.SDS.Office.Prosemirror.Connection`
//     与 `.odoc` 同一个类）。
//   * `fetch` ack = `[null, {doc: {version, data:{type,attrs,content}}, comment_store:[]}]`
//     ——**直接给出权威文档树与 version**，比 `Snapshot:get` 更完整。
//   * 写入 = `emit('event', {version, steps:[...], clientId})`；`version` **必须等于
//     服务端当前 version**（不是 `current+1`）。
//   * 成功 ack = `[null, {version: <新版本>, steps: [<回显的已应用 step>], clientIDs}]`；
//     失败 ack = `[{status: N}, "Error: …"]`，`N ∈ {402 not current, 411 invalid
//     command, 408 history not avail}`。**不是**表格的 `[revIncoming, currentRev, status]`。
//   * 远端增量的通道是 **`poll {version}`** 的回包
//     `[null, {version, wait, steps, clientIDs, selections}]`，**没有**逐 step 的广播
//     事件（`onBroadcast` 在演示文稿客户端里是空函数）。
//
// 因此本文件实现的是**同一套四步语义 + doc 风格协议**：`402` 对应表格批的
// `status 2`，`poll` 对应"重放远端队列"，上限后停队首并保留输入。
//
// ## 位置算术的证据边界（伪证用例守着）
//
// 真机 phase 2b 用"没有 `content` 就是叶子"的经验规则算出第一个 slide 段落的
// 内容起点为 461，服务端回 **411 Invalid command**。改用 **slides schema 的
// `isLeaf`** 后：空 `paragraph` 是**容器**（nodeSize = 2，不是 1），同一段落起点
// 是 564、内容起点 565，`replace` 被接受（version 14→15）。
// 所以 `officeSlidesNodeSize` **只认 schema 的 `isLeaf`**，绝不用"没 content"猜。
//
// ## 关键纪律（都有伪证用例）
//
// 1. **不丢输入**：发送失败/超时/402 重放上限都不能把命令从队列丢掉；
//    只有服务端**明确**成功（`[null,{version}]`）或**明确** 411 拒绝才出队，
//    411 要回滚乐观显示并把"哪一段、为什么没生效"记进 [OfficeSlidesEditFailure]。
// 2. **不与自己未确认的改动打架**：远端增量（`poll`/广播）到达时，若本地有未确认
//    改动，只把它压进 [remoteQueue]（**不覆盖显示**）；等本地命令有结果再决定
//    （成功 → 丢弃过期远端；402 → 第 2 步整体重放）。
// 3. **本批只发 `replace`（文本）**：几何（`attrs.transform` / `img_transform`）本批
//    **不做**，原样保留在 base 里、继续走降级卡片（见报告 §⑫）。
import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../../core/i18n/data_text.dart';
import '../../data/office_collab/office_collab_client.dart';
import '../../data/office_native/office_json.dart';
import 'office_slides_schema.dart';

// ---------------------------------------------------------------------------
// 位置算术
// ---------------------------------------------------------------------------

/// 一个节点在文档里的尺寸。
///
/// **硬规则**：`text` 节点 = `text.length`；schema 说 `isLeaf` 的 = 1；
/// 其余 = `sum(children) + 2`。叶子判定**只来自** [kOfficeSlidesNodeSpecs]
/// 的 `isLeaf`（空 `paragraph` 是容器 = 2，这一点被真机 411 证伪过一次）。
int officeSlidesNodeSize(Map<String, Object?> node) {
  final type = asJsonString(node['type']) ?? '';
  if (type == 'text') return (asJsonString(node['text']) ?? '').length;
  final spec = kOfficeSlidesNodeSpecs[type];
  if (spec != null && spec.isLeaf) return 1;
  var sum = 0;
  for (final raw in asJsonList(node['content']) ?? const <Object?>[]) {
    final child = asJsonMap(raw);
    if (child == null) continue;
    sum += officeSlidesNodeSize(child);
  }
  return sum + 2;
}

/// 从根开始的子节点下标路径 → 节点绝对起点。
///
/// 偏移约定与 M1/M2 一致（`office_slides_edit` 与 `.odoc` 的位置空间同族）：
///   * **根（`doc`）的子节点从 0 开始**（根自身的 `+2` 不在位置空间里）；
///   * **非根容器的子节点从 `parentStart + 1` 开始**。
int officeSlidesNodeStart(Map<String, Object?> root, List<int> path) {
  var start = 0;
  var node = root;
  for (var depth = 0; depth < path.length; depth++) {
    final index = path[depth];
    final kids = asJsonList(node['content']);
    if (kids == null || index < 0 || index >= kids.length) {
      throw OfficeSlidesRangeError('路径 ${path.join(".")} 在节点 ${node['type']} 处越界');
    }
    var cur = start + (depth == 0 ? 0 : 1);
    for (var i = 0; i < index; i++) {
      final child = asJsonMap(kids[i]);
      if (child == null) {
        throw OfficeSlidesRangeError('路径 ${path.join(".")} 的第 $i 个子节点不是对象');
      }
      cur += officeSlidesNodeSize(child);
    }
    start = cur;
    node = asJsonMap(kids[index]) ?? node;
  }
  return start;
}

/// 容器内容起点：根 = 0，其余 = `nodeStart + 1`。
int officeSlidesContentStart(Map<String, Object?> root, List<int> path) =>
    path.isEmpty ? 0 : officeSlidesNodeStart(root, path) + 1;

/// 按绝对起点（`ResolvedPos.self` 语义）找到节点。
Map<String, Object?>? officeSlidesNodeAt(Map<String, Object?> root, int pos) {
  var node = root;
  var start = 0;
  var isRoot = true;
  while (true) {
    final kids = asJsonList(node['content']);
    if (kids == null || kids.isEmpty) return null;
    var cur = isRoot ? start : start + 1;
    Map<String, Object?>? next;
    for (final raw in kids) {
      final child = asJsonMap(raw);
      if (child == null) return null;
      final size = officeSlidesNodeSize(child);
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

/// 定位绝对位置 [pos] 所在的可编辑文本块：返回块的下标路径 + 相对内容起点的
/// 字符偏移。找不到（越界 / 落在非文本块上）返回 null。
({List<int> path, int offset})? officeSlidesLocateTextBlock(
  Map<String, Object?> root,
  int pos,
) {
  ({List<int> path, int offset})? walk(
    Map<String, Object?> node,
    List<int> path,
    int start,
    bool isRoot,
  ) {
    final type = asJsonString(node['type']) ?? '';
    final spec = kOfficeSlidesNodeSpecs[type];
    final isLeaf = spec != null && spec.isLeaf;
    final kids = asJsonList(node['content']);
    final size = officeSlidesNodeSize(node);
    final contentStart = isRoot ? start : start + 1;
    final contentEnd = start + size - 1;
    if (spec == null || isLeaf) return null;
    if (pos < contentStart || pos > contentEnd) return null;
    if (_isTextBlock(type)) {
      return (path: path, offset: pos - contentStart);
    }
    var cur = contentStart;
    for (var i = 0; i < (kids?.length ?? 0); i++) {
      final child = asJsonMap(kids![i]);
      if (child == null) return null;
      final childSize = officeSlidesNodeSize(child);
      if (pos <= cur + childSize) {
        return walk(child, [...path, i], cur, false);
      }
      cur += childSize;
    }
    return null;
  }

  // 根的子节点从 0 开始。
  final kids = asJsonList(root['content']);
  if (kids == null) return null;
  var cur = 0;
  for (var i = 0; i < kids.length; i++) {
    final child = asJsonMap(kids[i]);
    if (child == null) return null;
    final childSize = officeSlidesNodeSize(child);
    if (pos <= cur + childSize) return walk(child, <int>[i], cur, false);
    cur += childSize;
  }
  return null;
}

/// 本批可编辑的文本块节点类型（与渲染侧 `_paragraph` 的判定一致）。
const Set<String> kOfficeSlidesTextBlockTypes = <String>{
  'paragraph',
  'holder_paragraph',
  'text_block',
  'shape_text_block',
  'text_line',
};

bool _isTextBlock(String type) => kOfficeSlidesTextBlockTypes.contains(type);

// ---------------------------------------------------------------------------
// 可编辑文本块
// ---------------------------------------------------------------------------

/// 一个内联片段：文本 + 该片段的 mark 列表（保持原样）。
class OfficeSlidesTextRun {
  const OfficeSlidesTextRun(this.text, this.marks);

  final String text;
  final List<Object?> marks;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'text',
        'text': text,
        if (marks.isNotEmpty) 'marks': <Object?>[...marks],
      };
}

/// 文档里一个可编辑的文本块（一段/一行文本）。
class OfficeSlidesEditableBlock {
  const OfficeSlidesEditableBlock({
    required this.path,
    required this.slideOrder,
    required this.nodeType,
    required this.contentStart,
    required this.runs,
    required this.hasAtoms,
  });

  final List<int> path;

  /// 所属幻灯片顺序（`slide_container` 里的 0 基序）；顶层文稿内容为 -1。
  final int slideOrder;
  final String nodeType;

  /// 块内容的绝对起点。
  final int contentStart;

  /// 内联文本片段（只含 `text` 节点；`hard_break`/`tab`/原子会让 [hasAtoms] 为真）。
  final List<OfficeSlidesTextRun> runs;

  /// 含非文本内联（`hard_break`/`tab`/图片等）→ 本批**不编辑**（登记不猜）。
  final bool hasAtoms;

  /// 稳定 id（下标路径），与渲染侧的路径无关，纯位置无关的块身份。
  String get id => path.join('.');

  /// 纯文本（`hard_break` → `\n`、`tab` → `\t`，仅用于展示）。
  String get text => runs.map((r) => r.text).join();

  int get length => text.length;

  /// 能否编辑：不含原子，且每段都能被文本 `replace` 表达。
  bool get editable => !hasAtoms;

  @override
  String toString() =>
      'OfficeSlidesEditableBlock($id, slide $slideOrder, "$text")';
}

/// 把一段内联内容摊成 runs；遇到非 `text` 内联时记 [hasAtoms]。
({List<OfficeSlidesTextRun> runs, bool hasAtoms}) officeSlidesReadInline(
  Map<String, Object?> block,
) {
  final runs = <OfficeSlidesTextRun>[];
  var atoms = false;
  for (final raw in asJsonList(block['content']) ?? const <Object?>[]) {
    final child = asJsonMap(raw);
    if (child == null) {
      atoms = true;
      continue;
    }
    final type = asJsonString(child['type']);
    if (type == 'text') {
      runs.add(
        OfficeSlidesTextRun(
          asJsonString(child['text']) ?? '',
          asJsonList(child['marks']) ?? const <Object?>[],
        ),
      );
    } else if (type == 'hard_break') {
      runs.add(const OfficeSlidesTextRun('\n', <Object?>[]));
      atoms = true;
    } else if (type == 'tab') {
      runs.add(const OfficeSlidesTextRun('\t', <Object?>[]));
      atoms = true;
    } else {
      atoms = true;
    }
  }
  return (runs: runs, hasAtoms: atoms);
}

/// 扫描文档里所有可编辑文本块（**幻灯片正文**，按文档顺序）。
///
/// 遍历顺序**刻意与渲染侧 `_block`/`_children` 一致**（paragraph 家族就地成块、
/// `note` 跳过、其余容器递归），这样 UI 可以用"第 n 个块"配对。
List<OfficeSlidesEditableBlock> officeSlidesEditableBlocks(
  Map<String, Object?> root,
) {
  final out = <OfficeSlidesEditableBlock>[];
  final slideContainerIndex = _indexOfType(root, 'slide_container');
  if (slideContainerIndex == null) return out;
  final rootKids = asJsonList(root['content']);
  if (rootKids == null) return out;
  final slideContainer = asJsonMap(rootKids[slideContainerIndex]);
  final slides = asJsonList(slideContainer?['content']);
  if (slides == null) return out;
  for (var order = 0; order < slides.length; order++) {
    final slide = asJsonMap(slides[order]);
    if (slide == null || asJsonString(slide['type']) != 'slide') continue;
    final contentIndex = _indexOfType(slide, 'slide_content_container');
    final content = contentIndex == null
        ? null
        : asJsonMap(asJsonList(slide['content'])![contentIndex]);
    final children = asJsonList(content?['content']);
    if (children == null) continue;
    for (var i = 0; i < children.length; i++) {
      final child = asJsonMap(children[i]);
      if (child == null) continue;
      _walkBlocks(
        child,
        <int>[slideContainerIndex, order, contentIndex!, i],
        order,
        out,
      );
    }
  }
  return out;
}

void _walkBlocks(
  Map<String, Object?> node,
  List<int> path,
  int slideOrder,
  List<OfficeSlidesEditableBlock> out,
) {
  final type = asJsonString(node['type']) ?? '';
  if (_isTextBlock(type)) {
    final inline = officeSlidesReadInline(node);
    out.add(
      OfficeSlidesEditableBlock(
        path: path,
        slideOrder: slideOrder,
        nodeType: type,
        // 绝对位置在 `officeSlidesBlocksWithRoot` 里用根文档回填。
        contentStart: 0,
        runs: inline.runs,
        hasAtoms: inline.hasAtoms,
      ),
    );
    return;
  }
  if (type == 'note') return;
  final kids = asJsonList(node['content']);
  if (kids == null) return;
  for (var i = 0; i < kids.length; i++) {
    final child = asJsonMap(kids[i]);
    if (child == null) continue;
    _walkBlocks(child, [...path, i], slideOrder, out);
  }
}

/// 带**绝对位置**的可编辑块（需要根文档）。
List<OfficeSlidesEditableBlock> officeSlidesBlocksWithRoot(
  Map<String, Object?> root,
) {
  final blocks = officeSlidesEditableBlocks(root);
  return <OfficeSlidesEditableBlock>[
    for (final b in blocks)
      OfficeSlidesEditableBlock(
        path: b.path,
        slideOrder: b.slideOrder,
        nodeType: b.nodeType,
        contentStart: officeSlidesContentStart(root, b.path),
        runs: b.runs,
        hasAtoms: b.hasAtoms,
      ),
  ];
}

int? _indexOfType(Map<String, Object?> node, String type) {
  final kids = asJsonList(node['content']);
  if (kids == null) return null;
  for (var i = 0; i < kids.length; i++) {
    final child = asJsonMap(kids[i]);
    if (child != null && asJsonString(child['type']) == type) return i;
  }
  return null;
}

/// 按 id 在 [blocks] 里找块。
OfficeSlidesEditableBlock? officeSlidesBlockById(
  List<OfficeSlidesEditableBlock> blocks,
  String id,
) {
  for (final b in blocks) {
    if (b.id == id) return b;
  }
  return null;
}

// ---------------------------------------------------------------------------
// step 构造
// ---------------------------------------------------------------------------

/// 文本编辑 → `replace` step JSON。形状与真机帧逐字一致：
/// `{stepType:"replace", from, to, slice:{content:[{type:"text",text}],openLeft:0,openRight:0}}`
/// （清空时 `slice` 为 `null`，与 M2 的 `delete-inside-marker` 向量同形）。
Map<String, Object?> officeSlidesReplaceStep({
  required int from,
  required int to,
  required String text,
}) =>
    <String, Object?>{
      'stepType': 'replace',
      'from': from,
      'to': to,
      'slice': text.isEmpty
          ? null
          : <String, Object?>{
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': text},
              ],
              'openLeft': 0,
              'openRight': 0,
            },
    };

/// 把"整块文本改成 [text]"表达成一个 `replace`：替换 `[contentStart,
/// contentStart + block.length)`。这是本批**唯一**发出的形状。
Map<String, Object?> officeSlidesReplaceBlockStep(
  OfficeSlidesEditableBlock block,
  String text,
) =>
    officeSlidesReplaceStep(
      from: block.contentStart,
      to: block.contentStart + block.length,
      text: text,
    );

/// `event` 帧：`{version, steps, clientId[, selection]}`。
///
/// `version` **必须**是服务端当前 version（真机 `_onEvent` 乐观锁；
/// `incoming != current` → `[{status:402}]`，缺字段 → `incoming: undefined`）。
Map<String, Object?> officeSlidesEventFrame({
  required int version,
  required List<Map<String, Object?>> steps,
  required String clientId,
  Object? selection,
}) {
  if (steps.isEmpty) {
    throw ArgumentError('event 帧至少要有一个 step');
  }
  return <String, Object?>{
    'version': version,
    'steps': steps,
    'clientId': clientId,
    if (selection != null) 'selection': selection,
  };
}

// ---------------------------------------------------------------------------
// ack 解析
// ---------------------------------------------------------------------------

/// `event` 回包的四类结果（真机帧，见文件头）。
enum OfficeSlidesAckKind {
  /// `[null, {version, steps, clientIDs}]`。
  ok,

  /// `[{status:402}]`：`version` 与服务端当前不符（含缺 `version` 字段）。
  versionNotCurrent,

  /// `[{status:411}]`：服务端拒绝这个 step（非法位置 / 未知 stepType）。
  invalidCommand,

  /// `[{status:408}]`：历史不可用（`poll` 的版本太旧）。
  historyNotAvail,

  /// 其它明确错误码。
  otherError,

  /// 形状对不上（不是列表 / 空列表）——结果未知，**不丢输入**。
  malformed,
}

/// 解析后的 `event`/`poll` 回包。
class OfficeSlidesAck {
  const OfficeSlidesAck({
    required this.kind,
    this.statusCode,
    this.version,
    this.steps = const <Map<String, Object?>>[],
    this.clientIds = const <String>[],
    this.message,
    this.raw,
  });

  final OfficeSlidesAckKind kind;
  final int? statusCode;

  /// 成功时的**服务端新版本**（`event`）或增量版本（`poll`）。
  final int? version;

  /// 成功时服务端回显/返回的 step 列表（`uid`/`clientID` 已由服务端覆写）。
  final List<Map<String, Object?>> steps;
  final List<String> clientIds;
  final String? message;
  final Object? raw;

  bool get isOk => kind == OfficeSlidesAckKind.ok;

  @override
  String toString() => 'OfficeSlidesAck(${kind.name}, status: $statusCode, '
      'version: $version, steps: ${steps.length}'
      '${message == null ? '' : ', "$message"'})';
}

/// 真实服务端的错误串形如
/// `Error: 1028_….slide: Not current version. incoming: 113, current: 13`；
/// 从中取权威的 `current`。取不到返回 null。
int? officeSlidesParseCurrentVersion(String? message) {
  if (message == null) return null;
  final m = RegExp(r'current:\s*(\d+)').firstMatch(message);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// 把 `emit('event', …)` / `emit('poll', …)` 的回包解析成 [OfficeSlidesAck]。
/// **纯函数，不抛。**
OfficeSlidesAck officeSlidesAck(Object? ack) {
  var list = asJsonList(ack);
  // 少数服务端把回调参数再包一层；只在单元素列表里剥一次。
  if (list != null && list.length == 1) {
    final inner = asJsonList(list.first);
    if (inner != null) list = inner;
  }
  if (list == null || list.isEmpty) {
    return OfficeSlidesAck(
      kind: OfficeSlidesAckKind.malformed,
      raw: ack,
    );
  }
  final first = list.first;
  if (first == null) {
    final payload = list.length > 1 ? asJsonMap(list[1]) : null;
    final rawSteps = asJsonList(payload?['steps']) ?? const <Object?>[];
    return OfficeSlidesAck(
      kind: OfficeSlidesAckKind.ok,
      version: asJsonInt(payload?['version']),
      steps: <Map<String, Object?>>[
        for (final s in rawSteps)
          if (asJsonMap(s) != null) asJsonMap(s)!,
      ],
      clientIds: <String>[
        for (final c in asJsonList(payload?['clientIDs']) ?? const <Object?>[])
          if (asJsonString(c) != null) asJsonString(c)!,
      ],
      raw: ack,
    );
  }
  final error = asJsonMap(first);
  final status = asJsonInt(error?['status']);
  final kind = switch (status) {
    kOfficeSlidesErrVersionNotCurrent => OfficeSlidesAckKind.versionNotCurrent,
    kOfficeSlidesErrInvalidCommand => OfficeSlidesAckKind.invalidCommand,
    kOfficeSlidesErrHistoryNotAvail => OfficeSlidesAckKind.historyNotAvail,
    _ => OfficeSlidesAckKind.otherError,
  };
  return OfficeSlidesAck(
    kind: kind,
    statusCode: status,
    message: list.length > 1 ? '${list[1]}' : null,
    raw: ack,
  );
}

// `kOfficeSlidesErr*` 与真机 status 码同源（server `Connection.ERR_*`）。
const int kOfficeSlidesErrInvalidVersion = 401;
const int kOfficeSlidesErrVersionNotCurrent = 402;
const int kOfficeSlidesErrInitFail = 403;
const int kOfficeSlidesErrHistoryNotAvail = 408;
const int kOfficeSlidesErrPermNotEnough = 409;
const int kOfficeSlidesErrOldOfficeVersion = 410;
const int kOfficeSlidesErrInvalidCommand = 411;

// ---------------------------------------------------------------------------
// 未确认队列 / 失败记录
// ---------------------------------------------------------------------------

/// 一条**未确认**的本地编辑（乐观显示 + 待重发）。
class OfficeSlidesPendingEdit {
  OfficeSlidesPendingEdit({
    required this.steps,
    this.blockId,
    this.text,
  });

  final List<Map<String, Object?>> steps;

  /// 这一批编辑对应的文本块（失败时**点名位置**用）。
  final String? blockId;
  final String? text;

  /// 已发出去过几次（402/超时会加）。
  int attempts = 0;

  @override
  String toString() =>
      'OfficeSlidesPendingEdit(${steps.length} step(s), block: $blockId, '
      'attempts: $attempts)';
}

/// 一次失败/拒绝的**可解释**记录：哪一段 + 为什么没生效。
enum OfficeSlidesEditFailureKind {
  /// 411：服务端拒绝这个 step（位置非法 / 未知 stepType）。
  rejected,

  /// 402 重放超过上限：服务端 version 一直在变，改动**仍保留在队列**。
  staleBlocked,

  /// 408：历史不可用（`poll` 失败），改动**仍保留在队列**。
  historyNotAvail,

  /// 发送超时 / 通道异常（结果未知，改动**仍保留在队列**）。
  transport,

  /// ack 形状对不上（结果未知，改动**仍保留在队列**）。
  malformedAck,
}

class OfficeSlidesEditFailure {
  const OfficeSlidesEditFailure({
    required this.kind,
    required this.detail,
    this.blockId,
    this.text,
    this.attempts = 1,
  });

  final OfficeSlidesEditFailureKind kind;
  final String? blockId;
  final String? text;
  final String detail;
  final int attempts;

  /// 可读的位置标签（作为 `officeSlidesEditFailedBlock` 的 `{block}` 占位值上屏，
  /// 所以必须走 `dataText`，不能是裸中文）。
  String get label => blockId == null
      ? dataText('officeSlidesBlockUnknown', '(未知位置)')
      : dataText('officeSlidesBlockLabel', '块 $blockId')
          .replaceAll('{block}', '$blockId');

  @override
  String toString() =>
      'OfficeSlidesEditFailure(${kind.name}, $label, $detail)';
}

/// 编辑层依赖的**发送通道**（生产 = `OfficeSlidesSession`，测试 = 假实现）。
abstract class OfficeSlidesCommandSink {
  /// `emit('event', frame)`（返回原始回包，由 `officeSlidesAck` 解析）。
  Future<Object?> sendEvent(Map<String, Object?> frame);

  /// `emit('poll', {version})`：取服务端自 [version] 以来的增量。
  Future<Object?> poll(int version);

  /// 服务端推送的事件（`broadcast`/`set`/`reload` 等；**无 ack**）。
  Stream<OfficeCollabEvent> get incoming;
}

/// `402` 允许的重放次数上限（防止服务端 version 一直变时无限重发）。
const int kOfficeSlidesMaxStaleReplays = 3;

/// `.oslides` 编辑状态机：乐观显示 + 未确认队列 + ack 三态 + `402` 四步重放。
class OfficeSlidesEditController extends ChangeNotifier {
  OfficeSlidesEditController({
    required this.sink,
    required Map<String, Object?> base,
    required int initialVersion,
    this.clientId = 'dsh-slides-mobile',
  })  : _base = _deepCopy(base),
        _version = initialVersion < 0 ? 0 : initialVersion {
    _recomputeBlocks();
    _sub = sink.incoming.listen(handleEvent);
  }

  final OfficeSlidesCommandSink sink;
  final String clientId;

  Map<String, Object?> _base;
  int _version;

  /// 可编辑块（从**乐观文档**计算，位置与显示都最新）。
  List<OfficeSlidesEditableBlock> _blocks = const <OfficeSlidesEditableBlock>[];

  /// 远端增量里"命中本地未确认"而**暂缓**应用的部分（402 第 2 步整体重放）。
  final List<Map<String, Object?>> _remoteQueue = <Map<String, Object?>>[];

  /// 未确认队列（FIFO）；队首可能正在飞。
  final List<OfficeSlidesPendingEdit> _pending = <OfficeSlidesPendingEdit>[];
  OfficeSlidesPendingEdit? _inFlight;

  /// 是否显示本地乐观覆盖（402 第一步 "undo" 会把它关掉）。
  bool _overlayVisible = true;

  int _staleReplays = 0;
  int _undoCount = 0;
  int _remoteReplayed = 0;
  int _confirmed = 0;
  int _unappliedRemoteSteps = 0;
  int _malformedRemoteIncrements = 0;
  String? _sendError;
  bool _disposed = false;

  StreamSubscription<OfficeCollabEvent>? _sub;

  /// 门控：只有 `gate.editable` 才允许编辑（页面设置；默认 false = 只读）。
  bool editable = false;

  /// 最近的失败/拒绝（可解释；页面据此渲染"哪一段、为什么"）。
  final List<OfficeSlidesEditFailure> failures = <OfficeSlidesEditFailure>[];

  /// 降级/诊断登记（不认识的东西不静默丢）。
  final Map<String, int> ignoredRemoteEvents = <String, int>{};
  final Map<String, int> ignoredRemoteStepTypes = <String, int>{};

  int get version => _version;
  List<OfficeSlidesEditableBlock> get blocks => List.unmodifiable(_blocks);
  int get pendingCount => _pending.length + (_inFlight == null ? 0 : 1);
  int get inFlightCount => _inFlight == null ? 0 : 1;
  int get pendingBlockCount {
    final ids = <String>{};
    for (final p in _pending) {
      if (p.blockId != null) ids.add(p.blockId!);
    }
    final flying = _inFlight;
    if (flying?.blockId != null) ids.add(flying!.blockId!);
    return ids.length;
  }

  int get staleReplays => _staleReplays;
  int get undoCount => _undoCount;
  int get remoteReplayed => _remoteReplayed;
  int get confirmedCount => _confirmed;
  int get remoteQueueLength => _remoteQueue.length;
  int get unappliedRemoteSteps => _unappliedRemoteSteps;
  int get malformedRemoteIncrements => _malformedRemoteIncrements;

  /// 通道错误（超时/异常/上限）——有值时**停止自动重发**，改动仍在队列里。
  String? get sendError => _sendError;

  bool get canEdit => editable && !_disposed;

  /// 乐观文档 = base + 未确认 step（`_overlayVisible` 时）。
  Map<String, Object?> get optimisticDoc =>
      _overlayVisible ? _overlayDoc() : _base;

  /// 文本块乐观文本；找不到块返回 null。
  String? optimisticText(String blockId) {
    final b = officeSlidesBlockById(_blocks, blockId);
    return b?.text;
  }

  /// 某块是否有未确认改动。
  bool isPendingBlock(String blockId) {
    if (_overlayVisible &&
        _pending.any((p) => p.blockId == blockId)) {
      return true;
    }
    return _inFlight?.blockId == blockId;
  }

  /// 按幻灯片顺序取可编辑块（渲染侧配对用）。
  List<OfficeSlidesEditableBlock> blocksForSlide(int slideOrder) =>
      <OfficeSlidesEditableBlock>[
        for (final b in _blocks)
          if (b.slideOrder == slideOrder) b,
      ];

  /// 渲染路径 `p<order>.<suffix…>` 的 **suffix** → 块。
  ///
  /// 运行期渲染路径是幻灯片相对下标（`p0.1.0.0`），而块的 `path` 是从根起的
  /// 绝对下标；两者的**尾部**相同，所以按后缀配对（唯一且与遍历顺序无关）。
  OfficeSlidesEditableBlock? blockForRenderPath(
    int slideOrder,
    List<int> suffix,
  ) {
    if (suffix.isEmpty) return null;
    for (final b in _blocks) {
      if (b.slideOrder != slideOrder) continue;
      if (b.path.length < suffix.length) continue;
      final tail = b.path.sublist(b.path.length - suffix.length);
      var same = true;
      for (var i = 0; i < suffix.length; i++) {
        if (tail[i] != suffix[i]) {
          same = false;
          break;
        }
      }
      if (same) return b;
    }
    return null;
  }

  // ---------------------------------------------------------------- 本地编辑

  /// 把某一段的文本改成 [text]（**乐观显示立刻生效**，step 进入未确认队列）。
  Future<void> editBlockText(String blockId, String text) async {
    if (!canEdit) return;
    final block = officeSlidesBlockById(_blocks, blockId);
    if (block == null || !block.editable) return;
    if (block.text == text) return; // 空写不发
    final step = officeSlidesReplaceBlockStep(block, text);
    await stage(
      OfficeSlidesPendingEdit(
        steps: <Map<String, Object?>>[step],
        blockId: blockId,
        text: text,
      ),
    );
  }

  /// 提交一批 step（内部用；测试可直接调用）。
  Future<void> stage(OfficeSlidesPendingEdit edit) async {
    if (!canEdit || edit.steps.isEmpty || _disposed) return;
    _sendError = null;
    _overlayVisible = true;
    _pending.add(edit);
    _recomputeBlocks();
    // 乐观显示立刻可见。
    notifyListeners();
    _pump();
  }

  /// 通道出错后用户显式重试（把整条队列继续推下去）。
  Future<void> retryPending() async {
    if (_disposed || _pending.isEmpty) return;
    _sendError = null;
    notifyListeners();
    _pump();
  }

  void _pump() {
    if (_disposed || _sendError != null) return;
    if (_inFlight != null || _pending.isEmpty) return;
    final next = _pending.removeAt(0);
    _inFlight = next;
    next.attempts++;
    final frame = officeSlidesEventFrame(
      version: _version,
      steps: next.steps,
      clientId: clientId,
    );
    _recomputeBlocks();
    notifyListeners();
    unawaited(_send(next, _version, frame));
  }

  Future<void> _send(
    OfficeSlidesPendingEdit pending,
    int sentVersion,
    Map<String, Object?> frame,
  ) async {
    Object? raw;
    try {
      raw = await sink.sendEvent(frame);
    } on Object catch (e) {
      if (_disposed) return;
      // **绝不丢用户输入**：命令回到队首，等显式重试。
      _inFlight = null;
      _pending.insert(0, pending);
      _sendError = '$e';
      failures.add(
        OfficeSlidesEditFailure(
          kind: OfficeSlidesEditFailureKind.transport,
          blockId: pending.blockId,
          text: pending.text,
          detail: '$e',
          attempts: pending.attempts,
        ),
      );
      _recomputeBlocks();
      notifyListeners();
      return;
    }
    if (_disposed) return;
    final ack = officeSlidesAck(raw);
    switch (ack.kind) {
      case OfficeSlidesAckKind.ok:
        _inFlight = null;
        _confirmed++;
        _version = ack.version ?? (sentVersion + 1);
        _commit(pending.steps);
        // 本地写入已被服务端接受：此前压住的远端增量已被我们的写入覆盖，丢弃。
        _dropDeferredFor(pending);
        _recomputeBlocks();
        notifyListeners();
        _pump();
      case OfficeSlidesAckKind.invalidCommand:
        _inFlight = null;
        _replayDeferredFor(pending);
        failures.add(
          OfficeSlidesEditFailure(
            kind: OfficeSlidesEditFailureKind.rejected,
            blockId: pending.blockId,
            text: pending.text,
            detail: 'status ${ack.statusCode ?? 411}'
                '${ack.message == null ? '' : '：${ack.message}'}',
            attempts: pending.attempts,
          ),
        );
        _recomputeBlocks();
        notifyListeners();
        _pump();
      case OfficeSlidesAckKind.versionNotCurrent:
        await _resolveStale(pending, ack);
      case OfficeSlidesAckKind.historyNotAvail:
        _inFlight = null;
        _pending.insert(0, pending);
        _sendError = 'status ${ack.statusCode ?? 408}：历史不可用';
        failures.add(
          OfficeSlidesEditFailure(
            kind: OfficeSlidesEditFailureKind.historyNotAvail,
            blockId: pending.blockId,
            text: pending.text,
            detail: 'status ${ack.statusCode ?? 408}',
            attempts: pending.attempts,
          ),
        );
        _recomputeBlocks();
        notifyListeners();
      case OfficeSlidesAckKind.otherError:
        _inFlight = null;
        _pending.insert(0, pending);
        _sendError = '服务端错误 ${ack.statusCode}';
        failures.add(
          OfficeSlidesEditFailure(
            kind: OfficeSlidesEditFailureKind.malformedAck,
            blockId: pending.blockId,
            text: pending.text,
            detail: 'status ${ack.statusCode} ${ack.message ?? ''}'.trim(),
            attempts: pending.attempts,
          ),
        );
        _recomputeBlocks();
        notifyListeners();
      case OfficeSlidesAckKind.malformed:
        _inFlight = null;
        _pending.insert(0, pending);
        _sendError = 'ack=${_short(raw)}';
        failures.add(
          OfficeSlidesEditFailure(
            kind: OfficeSlidesEditFailureKind.malformedAck,
            blockId: pending.blockId,
            text: pending.text,
            detail: 'ack=${_short(raw)}',
            attempts: pending.attempts,
          ),
        );
        _recomputeBlocks();
        notifyListeners();
    }
  }

  /// **402 的四步流程**（对应表格批 status 2 的 undo/replay/redo/resend）：
  /// undo 本地未确认 → `poll` 远端增量并重放到 base → redo 本地 → 对齐 version 重发。
  Future<void> _resolveStale(
    OfficeSlidesPendingEdit pending,
    OfficeSlidesAck ack,
  ) async {
    // 1) undo：把本地未确认的乐观覆盖藏起来（显示回到 base）。
    _overlayVisible = false;
    _undoCount++;
    _recomputeBlocks();
    notifyListeners();

    // 2) 重放远端增量：从**服务端权威 current**（或已知 version）起 poll。
    final from = officeSlidesParseCurrentVersion(ack.message) ?? _version;
    Object? pollRaw;
    try {
      pollRaw = await sink.poll(from);
    } on Object catch (e) {
      if (_disposed) return;
      _inFlight = null;
      _overlayVisible = true;
      _pending.insert(0, pending);
      _sendError = 'poll 失败：$e';
      failures.add(
        OfficeSlidesEditFailure(
          kind: OfficeSlidesEditFailureKind.historyNotAvail,
          blockId: pending.blockId,
          text: pending.text,
          detail: '$e',
          attempts: pending.attempts,
        ),
      );
      _recomputeBlocks();
      notifyListeners();
      return;
    }
    if (_disposed) return;
    final pollAck = officeSlidesAck(pollRaw);
    if (!pollAck.isOk) {
      _inFlight = null;
      _overlayVisible = true;
      _pending.insert(0, pending);
      _sendError = 'poll status ${pollAck.statusCode}';
      failures.add(
        OfficeSlidesEditFailure(
          kind: OfficeSlidesEditFailureKind.historyNotAvail,
          blockId: pending.blockId,
          text: pending.text,
          detail: 'poll status ${pollAck.statusCode}',
          attempts: pending.attempts,
        ),
      );
      _recomputeBlocks();
      notifyListeners();
      return;
    }
    _applyRemoteIncrement(pollAck.steps, pollAck.version);
    _replayRemoteQueue();

    // 3) redo：本地未确认改动重新覆盖显示。
    _overlayVisible = true;
    _inFlight = null;

    // 4) 对齐服务端 version 后重发（同一条 step，绝不丢）。
    if (pollAck.version != null) _version = pollAck.version!;
    if (pending.attempts >= kOfficeSlidesMaxStaleReplays) {
      _pending.insert(0, pending);
      _sendError = 'version 重放 ${pending.attempts} 次仍过期';
      failures.add(
        OfficeSlidesEditFailure(
          kind: OfficeSlidesEditFailureKind.staleBlocked,
          blockId: pending.blockId,
          text: pending.text,
          detail: 'status ${ack.statusCode ?? 402}'
              '${ack.message == null ? '' : '：${ack.message}'}',
          attempts: pending.attempts,
        ),
      );
      _recomputeBlocks();
      notifyListeners();
      return;
    }
    _staleReplays++;
    _pending.insert(0, pending);
    _recomputeBlocks();
    notifyListeners();
    _pump();
  }

  // ---------------------------------------------------------------- 远端

  /// 服务端推送事件。演示文稿的远端增量走 **`poll`**（没有逐 step 广播），
  /// 但若服务端推了带 `steps` 的 `broadcast`/`set`/`event`，也按增量处理。
  void handleEvent(OfficeCollabEvent event) {
    if (event.args.isEmpty) {
      ignoredRemoteEvents[event.name] = (ignoredRemoteEvents[event.name] ?? 0) + 1;
      return;
    }
    final arg = asJsonMap(event.args.first);
    final steps = asJsonList(arg?['steps']);
    if (steps == null) {
      ignoredRemoteEvents[event.name] =
          (ignoredRemoteEvents[event.name] ?? 0) + 1;
      return;
    }
    _applyRemoteIncrement(
      <Map<String, Object?>>[
        for (final s in steps)
          if (asJsonMap(s) != null) asJsonMap(s)!,
      ],
      asJsonInt(arg?['version']),
    );
  }

  /// 应用一批远端增量。**本地有未确认改动 → 暂缓（remoteQueue），绝不覆盖显示。**
  void _applyRemoteIncrement(
    List<Map<String, Object?>> steps,
    int? remoteVersion,
  ) {
    if (_disposed) return;
    var changed = false;
    final locallyEditing = _pending.isNotEmpty || _inFlight != null;
    for (final step in steps) {
      if (locallyEditing) {
        _remoteQueue.add(step);
        changed = true;
        continue;
      }
      if (_applyStep(step)) {
        changed = true;
      } else {
        final type = asJsonString(step['stepType']) ?? '(no stepType)';
        ignoredRemoteStepTypes[type] = (ignoredRemoteStepTypes[type] ?? 0) + 1;
        _unappliedRemoteSteps++;
        changed = true;
      }
    }
    if (!locallyEditing && remoteVersion != null) _version = remoteVersion;
    if (changed) {
      _recomputeBlocks();
      notifyListeners();
    }
  }

  /// 主动拉一次远端增量（页面在合适时机调用；也是"peer 不覆盖本地"的入口）。
  Future<void> pollRemote() async {
    if (_disposed) return;
    Object? raw;
    try {
      raw = await sink.poll(_version);
    } on Object catch (_) {
      _malformedRemoteIncrements++;
      return;
    }
    if (_disposed) return;
    final ack = officeSlidesAck(raw);
    if (!ack.isOk) {
      _malformedRemoteIncrements++;
      notifyListeners();
      return;
    }
    _applyRemoteIncrement(ack.steps, ack.version);
  }

  /// 把 remoteQueue 整体应用（402 第 2 步）。
  void _replayRemoteQueue() {
    for (final step in _remoteQueue) {
      if (_applyStep(step)) {
        _remoteReplayed++;
      } else {
        final type = asJsonString(step['stepType']) ?? '(no stepType)';
        ignoredRemoteStepTypes[type] = (ignoredRemoteStepTypes[type] ?? 0) + 1;
        _unappliedRemoteSteps++;
      }
    }
    _remoteQueue.clear();
  }

  /// 本地命令被拒绝：把此前为它压住的远端值显形。
  void _replayDeferredFor(OfficeSlidesPendingEdit pending) {
    if (_remoteQueue.isEmpty) return;
    // 演示文稿的 step 是位置型，无法按"格"精确归属；保守地把整条远端队列
    // 重放到 base（我们的写入从未发生），并如实登记。
    _replayRemoteQueue();
    _recomputeBlocks();
  }

  /// 本地命令被确认：丢弃此前压住的远端增量。
  void _dropDeferredFor(OfficeSlidesPendingEdit pending) {
    if (_remoteQueue.isEmpty) return;
    _remoteQueue.clear();
  }

  void _commit(List<Map<String, Object?>> steps) {
    for (final step in steps) {
      if (!_applyStep(step)) {
        final type = asJsonString(step['stepType']) ?? '(no stepType)';
        ignoredRemoteStepTypes[type] = (ignoredRemoteStepTypes[type] ?? 0) + 1;
        _unappliedRemoteSteps++;
      }
    }
  }

  void _recomputeBlocks() {
    _blocks = officeSlidesBlocksWithRoot(_overlayDoc());
  }

  Map<String, Object?> _overlayDoc() {
    if (!_overlayVisible) return _base;
    var doc = _base;
    for (final p in _pending) {
      for (final step in p.steps) {
        doc = _applyStepTo(doc, step) ?? doc;
      }
    }
    final flying = _inFlight;
    if (flying != null) {
      for (final step in flying.steps) {
        doc = _applyStepTo(doc, step) ?? doc;
      }
    }
    return doc;
  }

  bool _applyStep(Map<String, Object?> step) {
    final next = _applyStepTo(_base, step);
    if (next == null) return false;
    _base = next;
    return true;
  }

  static String _short(Object? v) {
    final s = '$v';
    return s.length <= 60 ? s : '${s.substring(0, 60)}…';
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    _sub = null;
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 本地 step 应用（只覆盖本批发出 / 常见远端形状）
// ---------------------------------------------------------------------------

/// 把一条 step 作用到 [doc]（不改原树）；不认识的形状返回 null
/// （调用方必须**登记**，不许假装成功）。
Map<String, Object?>? officeSlidesApplyStep(
  Map<String, Object?> doc,
  Map<String, Object?> step,
) =>
    _applyStepTo(doc, step);

Map<String, Object?>? _applyStepTo(
  Map<String, Object?> doc,
  Map<String, Object?> step,
) {
  final type = asJsonString(step['stepType']);
  switch (type) {
    case 'replace':
      return _applyReplace(doc, step);
    case 'setRootNodeAttrs':
      return _mergeAttrs(doc, asJsonMap(step['attrs']) ?? const {});
    case 'setNodeAttrs':
      final pos = asJsonInt(step['pos']);
      if (pos == null) return null;
      final located = officeSlidesLocateNode(doc, pos);
      if (located == null) return null;
      final attrs = asJsonMap(step['attrs']) ?? const <String, Object?>{};
      return _replaceNodeAt(
        doc,
        located.path,
        _mergeAttrs(located.node, attrs),
      );
    default:
      return null;
  }
}

/// 找到**恰好从 [pos] 开始**的节点及其路径。
({List<int> path, Map<String, Object?> node})? officeSlidesLocateNode(
  Map<String, Object?> root,
  int pos,
) {
  ({List<int> path, Map<String, Object?> node})? walk(
    Map<String, Object?> node,
    List<int> path,
    int start,
    bool isRoot,
  ) {
    final kids = asJsonList(node['content']);
    if (kids == null || kids.isEmpty) return null;
    var cur = isRoot ? start : start + 1;
    for (var i = 0; i < kids.length; i++) {
      final child = asJsonMap(kids[i]);
      if (child == null) return null;
      final size = officeSlidesNodeSize(child);
      if (pos == cur) return (path: [...path, i], node: child);
      if (pos < cur + size) {
        return walk(child, [...path, i], cur, false);
      }
      cur += size;
    }
    return null;
  }

  return walk(root, const <int>[], 0, true);
}

Map<String, Object?>? _applyReplace(
  Map<String, Object?> doc,
  Map<String, Object?> step,
) {
  final from = asJsonInt(step['from']);
  final to = asJsonInt(step['to']);
  if (from == null || to == null || to < from) return null;
  final slice = asJsonMap(step['slice']);
  final insertNodes = asJsonList(slice?['content']) ?? const <Object?>[];
  // 本批只应用"纯文本 slice"（本批发出的形状）；含非 text 节点则登记不应用。
  final inserted = StringBuffer();
  for (final raw in insertNodes) {
    final node = asJsonMap(raw);
    if (node == null || asJsonString(node['type']) != 'text') return null;
    inserted.write(asJsonString(node['text']) ?? '');
  }
  if (from == to && inserted.isEmpty) return null; // 空编辑 = no-op
  final located = officeSlidesLocateTextBlock(doc, from);
  final endLocated = officeSlidesLocateTextBlock(doc, to);
  if (located == null || endLocated == null) return null;
  if (!_samePath(located.path, endLocated.path)) return null;
  final block = officeSlidesNodeAtPath(doc, located.path);
  if (block == null) return null;
  final inline = officeSlidesReadInline(block);
  if (inline.hasAtoms) return null; // 含非 text 内联 → 登记不应用，不猜
  final runs = inline.runs;
  final text = runs.map((r) => r.text).join();
  if (located.offset < 0 ||
      endLocated.offset > text.length ||
      endLocated.offset < located.offset) {
    return null;
  }
  final next = _spliceRuns(
    runs,
    located.offset,
    endLocated.offset,
    inserted.toString(),
  );
  final newBlock = <String, Object?>{
    ...block,
    if (next.isEmpty)
      ...<String, Object?>{'content': <Object?>[]}
    else
      'content': <Object?>[for (final run in next) run.toJson()],
  };
  return _replaceNodeAt(doc, located.path, newBlock);
}

/// 按字符区间 `[from, to)` 替换文本，插入文本继承其**前一个字符**的 marks。
List<OfficeSlidesTextRun> _spliceRuns(
  List<OfficeSlidesTextRun> runs,
  int from,
  int to,
  String insert,
) {
  final marksAtFrom = _marksAt(runs, from);
  final out = <OfficeSlidesTextRun>[];
  var cursor = 0;
  var inserted = false;
  for (final run in runs) {
    final start = cursor;
    final end = cursor + run.text.length;
    cursor = end;
    if (end <= from) {
      out.add(run);
      continue;
    }
    if (start >= to) {
      if (!inserted) {
        out.add(OfficeSlidesTextRun(insert, marksAtFrom));
        inserted = true;
      }
      out.add(run);
      continue;
    }
    if (start < from) {
      out.add(OfficeSlidesTextRun(run.text.substring(0, from - start), run.marks));
    }
    if (!inserted) {
      out.add(OfficeSlidesTextRun(insert, marksAtFrom));
      inserted = true;
    }
    if (end > to) {
      out.add(OfficeSlidesTextRun(run.text.substring(to - start), run.marks));
    }
  }
  if (!inserted) out.add(OfficeSlidesTextRun(insert, marksAtFrom));
  return <OfficeSlidesTextRun>[
    for (final r in out)
      if (r.text.isNotEmpty) r,
  ];
}

List<Object?> _marksAt(List<OfficeSlidesTextRun> runs, int offset) {
  var cursor = 0;
  for (final run in runs) {
    if (offset < cursor + run.text.length) return run.marks;
    cursor += run.text.length;
  }
  return runs.isEmpty ? const <Object?>[] : runs.last.marks;
}

Map<String, Object?>? officeSlidesNodeAtPath(
  Map<String, Object?> root,
  List<int> path,
) {
  var node = root;
  for (final index in path) {
    final kids = asJsonList(node['content']);
    if (kids == null || index < 0 || index >= kids.length) return null;
    final child = asJsonMap(kids[index]);
    if (child == null) return null;
    node = child;
  }
  return node;
}

Map<String, Object?> _replaceNodeAt(
  Map<String, Object?> root,
  List<int> path,
  Map<String, Object?> replacement,
) {
  if (path.isEmpty) return replacement;
  final copy = _deepCopy(root);
  var node = copy;
  for (var i = 0; i < path.length - 1; i++) {
    final kids = asJsonList(node['content']);
    if (kids == null || path[i] >= kids.length) return copy;
    node = asJsonMap(kids[path[i]])!;
  }
  final kids = asJsonList(node['content']);
  if (kids == null || path.last >= kids.length) return copy;
  kids[path.last] = _deepCopy(replacement);
  return copy;
}

Map<String, Object?> _mergeAttrs(
  Map<String, Object?> node,
  Map<String, Object?> incoming,
) {
  final attrs = <String, Object?>{
    ...(asJsonMap(node['attrs']) ?? const <String, Object?>{}),
  };
  incoming.forEach((key, value) {
    if (value == null) {
      attrs.remove(key);
    } else {
      attrs[key] = value;
    }
  });
  return <String, Object?>{...node, 'attrs': attrs};
}

bool _samePath(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<String, Object?> _deepCopy(Map<String, Object?> node) =>
    asJsonMap(_deepCopyValue(node))!;

Object? _deepCopyValue(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final e in value.entries) '${e.key}': _deepCopyValue(e.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final v in value) _deepCopyValue(v)];
  }
  return value;
}

// ---------------------------------------------------------------------------
// 诊断串
// ---------------------------------------------------------------------------

/// 编辑失败 → 诊断串（开发者可读；UI 文案由页面走 `dataText`）。
String officeSlidesDescribeFailure(OfficeSlidesEditFailure failure) {
  switch (failure.kind) {
    case OfficeSlidesEditFailureKind.rejected:
      return '${failure.label} 被服务端拒绝（${failure.detail}）';
    case OfficeSlidesEditFailureKind.staleBlocked:
      return '${failure.label} version 一直过期，改动仍保留在待确认队列'
          '（${failure.detail}，重放 ${failure.attempts} 次）';
    case OfficeSlidesEditFailureKind.historyNotAvail:
      return '${failure.label} 拉取远端增量失败（${failure.detail}，改动仍在待确认队列）';
    case OfficeSlidesEditFailureKind.transport:
      return '${failure.label} 发送失败：${failure.detail}（改动仍在待确认队列）';
    case OfficeSlidesEditFailureKind.malformedAck:
      return '${failure.label} 的服务端结果无法确认：${failure.detail}'
          '（改动仍在待确认队列）';
  }
}

/// 位置越界（构造 step 时的明确失败；**不静默**）。
class OfficeSlidesRangeError implements Exception {
  const OfficeSlidesRangeError(this.message);

  final String message;

  @override
  String toString() => 'OfficeSlidesRangeError: $message';
}
