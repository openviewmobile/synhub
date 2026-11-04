// Office C' · M2 — local ProseMirror(-fork) step application.
//
// This is the Dart counterpart of the Synology Office ProseMirror fork's
// `transform` module: `Step` / `StepResult` / `Slice` / `PosMap`. It is a
// faithful port of the vendor behaviour, established by running the official
// `server/common/prosemirror/index.js` bundle as an oracle and diffing every
// vector in `test/fixtures/office_collab/transform_vectors.json`.
//
// SCOPE / KNOWN GAPS (see docs/office-collab-m2-implementation.md §8):
//   * Node content-expression matching (`NodeType.compatibleContent`,
//     `validContent`, `contentMatchAt().allowsMark()`) is NOT implemented, so
//     the fork's `Cannot join X onto Y` / `Invalid content for node X` errors
//     are not reproduced. For all *valid* inputs the ported algorithm produces
//     the same document (the checks only fire on invalid input).
//   * `MarkType.excludes` and the `backward`-attr merge in `checkJoin` are not
//     implemented (the schema exposes no `excludes`; `backward` is only set on
//     the optional `trackingEnd` attr, which this layer never edits).
//   * `Transform.wrap`/`lift` (`ReplaceAroundStep`) and node-array/table steps
//     are not ported.
//
// Everything here is pure Dart, offline, dependency-free.

import 'doc_schema.dart';

// ------------------------------------------------------------------ errors --

/// The fork's `ReplaceError` (`ta`). `Step.apply` converts it into a failed
/// [StepResult]; it never escapes an `apply` call.
class DocReplaceError implements Exception {
  const DocReplaceError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The fork's `RangeError` for offsets outside `[0, doc.content.size]`.
/// Unlike [DocReplaceError] it escapes `Step.apply` unchanged (the vendor
/// `apply` only catches `ReplaceError`/promise errors).
class DocRangeError implements Exception {
  const DocRangeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Raised by [DocStep.fromJson] for an unusable step payload. The server maps
/// this to error `411 ERR_INVALID_COMMAND` (M0: `Step.fromJSON` throwing ->
/// `{"status":411},"Error: …: Invalid command"`).
class DocStepParseException implements Exception {
  const DocStepParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ------------------------------------------------------------------ helpers --

typedef DocJson = Map<String, Object?>;

final DocSchema _schema = DocSchema.document;

bool _isText(DocJson n) => n['type'] == 'text';

List<DocJson> _frag(Object? content) {
  if (content is List) {
    return content.map((e) => (e as Map).cast<String, Object?>()).toList();
  }
  return const <DocJson>[];
}

/// The fork's three `nodeSize` rules (mirrors `DocSchema.nodeSize` but on raw
/// wire maps): `text = text.length`, `isLeaf && !isText = 1`, else `sum + 2`.
int docNodeSize(DocJson node) {
  final type = node['type'] as String;
  if (type == 'text') return ((node['text'] as String?) ?? '').length;
  final spec = _schema.nodes[type];
  if (spec != null && spec.isLeaf) return 1;
  var sum = 0;
  for (final c in _frag(node['content'])) {
    sum += docNodeSize(c);
  }
  return sum + 2;
}

int _fragSize(List<DocJson> frag) {
  var sum = 0;
  for (final n in frag) {
    sum += docNodeSize(n);
  }
  return sum;
}

int _contentSize(DocJson node) => _fragSize(_frag(node['content']));

int _childCount(DocJson node) => _frag(node['content']).length;

DocJson _child(DocJson node, int index) => _frag(node['content'])[index];

DocJson? _maybeChild(DocJson node, int index) {
  final kids = _frag(node['content']);
  return index >= 0 && index < kids.length ? kids[index] : null;
}

DocJson? _firstChild(DocJson node) {
  final kids = _frag(node['content']);
  return kids.isEmpty ? null : kids.first;
}

/// `Node.copy(content, attrs)` — a shallow copy that optionally replaces the
/// child fragment and merges attrs (`null` attr values delete the key, which is
/// what `clearNodeAttrs` produces). With [attrsReplace] the supplied attrs are
/// the complete new attr set (used by the attr steps, which pre-merge via
/// [mergeSettableAttrs]).
DocJson _copyNode(
  DocJson node, {
  List<DocJson>? content,
  Map<String, Object?>? attrs,
  bool attrsReplace = false,
}) {
  final out = <String, Object?>{'type': node['type']};
  final merged = <String, Object?>{};
  final orig = node['attrs'];
  if (!attrsReplace && orig is Map) {
    for (final e in orig.entries) {
      merged['${e.key}'] = e.value;
    }
  }
  if (attrs != null) {
    for (final e in attrs.entries) {
      if (e.value == null) {
        merged.remove(e.key);
      } else {
        merged[e.key] = e.value;
      }
    }
  }
  if (merged.isNotEmpty) out['attrs'] = merged;
  if (_isText(node)) {
    final marks = node['marks'];
    if (marks is List && marks.isNotEmpty) out['marks'] = marks;
    out['text'] = node['text'];
    return out;
  }
  if (content != null && content.isNotEmpty) {
    out['content'] = content.map((c) => <String, Object?>{...c}).toList();
  } else if (content == null) {
    // `Node.copy(content, attrs)` always forwards a content fragment; a copy
    // that only changes attrs therefore keeps the original children.
    final kids = _frag(node['content']);
    if (kids.isNotEmpty) {
      out['content'] = kids.map((c) => <String, Object?>{...c}).toList();
    }
  }
  final marks = node['marks'];
  if (marks is List && marks.isNotEmpty) out['marks'] = marks;
  return out;
}

DocJson _textNode(String text, List<Object?> marks) {
  final out = <String, Object?>{'type': 'text'};
  if (marks.isNotEmpty) out['marks'] = marks;
  out['text'] = text;
  return out;
}

// --------------------------------------------------------- attribute merge --

/// `NodeType.settableAttrValues(attrs)` followed by `Node.copy(content, vals)`.
///
/// Ports the vendor `copyAttrs`/`copyAttr` pair: keys absent from [incoming]
/// keep their existing value, an explicit `null` deletes the key, and a
/// composite (`deep`) attr is merged **recursively** rather than replaced — the
/// behaviour the `page_setup` vectors pin down.
///
/// GAP: the vendor also filters through each attr spec's `settable` flag before
/// merging. M1's Dart schema does not export `settable`/`clearable`, so this
/// port assumes every addressed attr is settable (true for all vectors).
Map<String, Object?> mergeSettableAttrs(
  String typeName,
  Map<String, Object?> existing,
  Map<String, Object?> incoming,
) {
  final specs = _schema.nodes[typeName]?.attrs ?? const <String, DocAttrSpec>{};
  return _mergeAttrSpecs(specs, existing, incoming);
}

Map<String, Object?> _mergeAttrSpecs(
  Map<String, DocAttrSpec> specs,
  Map<String, Object?> existing,
  Map<String, Object?> incoming,
) {
  final out = <String, Object?>{...existing};
  incoming.forEach((key, value) {
    final spec = specs[key];
    final merged = spec == null
        ? existing[key] // unknown attr: `copyAttr(undefined, e, r)` keeps `e`
        : _mergeAttrValue(spec, existing[key], value);
    if (merged == null) {
      out.remove(key);
    } else {
      out[key] = merged;
    }
  });
  return out;
}

Object? _mergeAttrValue(DocAttrSpec spec, Object? existing, Object? incoming) {
  if (incoming == null) return null;
  if (spec.deep.isEmpty) return incoming;
  if (incoming is! Map) return null;
  final ex = existing is Map
      ? existing.cast<String, Object?>()
      : <String, Object?>{};
  return _mergeAttrSpecs(spec.deep, ex, incoming.cast<String, Object?>());
}

/// A text node with a (possibly empty) mark set, keeping the vendor key order.
DocJson _withMarks(DocJson text, List<Object?> marks) =>
    _textNode(text['text'] as String? ?? '', marks);

/// `Node.cut(from, to)` = copy with its content cut. Text nodes cut their text
/// (the fork overrides `TextNode.cut`), every other node cuts its content.
DocJson _nodeCut(DocJson node, int from, int to) {
  if (_isText(node)) {
    final text = node['text'] as String;
    return _textNode(
      text.substring(_clamp(0, from, text.length), _clamp(0, to, text.length)),
      (node['marks'] as List?) ?? const <Object?>[],
    );
  }
  return _copyNode(node, content: _fragCut(_frag(node['content']), from, to));
}

/// `Fragment.cut(from, to)` — keeps the vendor's partial-text cutting rule.
List<DocJson> _fragCut(List<DocJson> content, int from, int to) {
  if (from == 0 && to == _fragSize(content)) return content;
  final out = <DocJson>[];
  if (to > from) {
    var offset = 0;
    var idx = 0;
    while (offset < to && idx < content.length) {
      final node = content[idx];
      final end = offset + docNodeSize(node);
      if (end > from) {
        var cut = node;
        if (offset < from || end > to) {
          if (_isText(node)) {
            final text = node['text'] as String;
            cut = _textNode(
              text.substring(
                _clamp(0, from - offset, text.length),
                _clamp(0, to - offset, text.length),
              ),
              (node['marks'] as List?) ?? const <Object?>[],
            );
          } else {
            final inner = _contentSize(node);
            cut = _nodeCut(
              node,
              _clamp(0, from - offset - 1, inner),
              _clamp(0, to - offset - 1, inner),
            );
          }
        }
        out.add(cut);
      }
      offset = end;
      idx++;
    }
  }
  return out;
}

int _clamp(int lo, int v, int hi) => v < lo ? lo : (v > hi ? hi : v);

bool _sameMarkup(DocJson a, DocJson b) =>
    canonicalJson(a['marks'] ?? const <Object?>[]) ==
    canonicalJson(b['marks'] ?? const <Object?>[]);

/// `Fragment.fromArray` — notably it *merges adjacent text nodes with the same
/// markup*, which the expected documents depend on.
List<DocJson> _fromArray(List<DocJson> nodes) {
  if (nodes.isEmpty) return const <DocJson>[];
  final out = <DocJson>[];
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    if (i > 0 &&
        _isText(n) &&
        _isText(nodes[i - 1]) &&
        _sameMarkup(nodes[i - 1], n)) {
      final prev = out.removeLast();
      out.add(
        _textNode(
          ((prev['text'] as String?) ?? '') + ((n['text'] as String?) ?? ''),
          (prev['marks'] as List?) ?? const <Object?>[],
        ),
      );
    } else {
      out.add(n);
    }
  }
  return out;
}

List<DocJson> _replaceChild(List<DocJson> frag, int index, DocJson node) {
  final out = frag.toList();
  out[index] = node;
  return out;
}

// -------------------------------------------------------------------- Slice --

/// The fork's `Slice`: a node fragment plus `openLeft`/`openRight`.
///
/// NOTE: the fork's wire field names are `openLeft`/`openRight` (NOT the
/// upstream ProseMirror `openStart`/`openEnd`) — see M0 and the vectors.
class DocSlice {
  DocSlice(this.content, this.openLeft, this.openRight);

  final List<DocJson> content;
  final int openLeft;
  final int openRight;

  static final DocSlice empty = DocSlice(const <DocJson>[], 0, 0);

  int get size => _fragSize(content) - openLeft - openRight;

  int get fragmentSize => _fragSize(content);

  /// `Slice.toJSON` -> `null` when the fragment is empty.
  Object? toJson() => _fragSize(content) != 0
      ? <String, Object?>{
          'content': content.map((n) => <String, Object?>{...n}).toList(),
          'openLeft': openLeft,
          'openRight': openRight,
        }
      : null;

  /// `Slice.fromJSON(schema, json)`; a null/absent slice is [empty].
  static DocSlice fromJson(Object? json) {
    if (json == null) return empty;
    if (json is! Map) {
      throw const DocStepParseException('slice must be an object or null');
    }
    final m = json.cast<String, Object?>();
    return DocSlice(
      _frag(m['content']),
      (m['openLeft'] as num?)?.toInt() ?? 0,
      (m['openRight'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() =>
      'DocSlice(openLeft: $openLeft, openRight: $openRight, '
      'content: ${canonicalJson(content)})';
}

// -------------------------------------------------------------- ResolvedPos --

class _Triple {
  _Triple(this.node, this.index, this.contentStart);
  final DocJson node;
  final int index;

  /// Absolute position of `node`'s content start (vendor `start(d)`), except at
  /// depth 0 where it is the child-start offset (`start(0)` is 0 by definition).
  final int contentStart;
}

/// `doc.resolve(pos)` — a port of the fork's `ResolvedPos` (`_resolve`).
class DocResolvedPos {
  DocResolvedPos._(this.root, this.pos, this._path);

  final DocJson root;
  final int pos;
  final List<_Triple> _path;

  static DocResolvedPos resolve(DocJson doc, int pos) {
    final size = _contentSize(doc);
    if (pos < 0 || pos > size) {
      throw DocRangeError('Offset $pos out of range [0, $size].');
    }
    final path = <_Triple>[];
    var node = doc;
    var start = 0;
    var offsetInNode = pos;
    while (true) {
      final fi = _findIndex(node, offsetInNode);
      final inner = offsetInNode - fi.$2;
      path.add(_Triple(node, fi.$1, start + fi.$2));
      if (inner == 0) break;
      final child = _child(node, fi.$1);
      if (_isText(child)) break;
      node = child;
      offsetInNode = inner - 1;
      start += fi.$2 + 1;
    }
    return DocResolvedPos._(doc, pos, path);
  }

  int get depth => _path.length - 1;

  DocJson node([int? d]) => _path[_resolveDepth(d)].node;

  int index([int? d]) => _path[_resolveDepth(d)].index;

  int indexAfter([int? d]) {
    final dd = _resolveDepth(d);
    return index(dd) + ((dd == depth && atNodeBoundary) ? 0 : 1);
  }

  int _resolveDepth(int? d) {
    if (d == null) return depth;
    return d < 0 ? depth + d : d;
  }

  int startAt([int? d]) {
    final dd = _resolveDepth(d);
    return dd == 0 ? 0 : _path[dd - 1].contentStart + 1;
  }

  int endAt([int? d]) => startAt(d) + _contentSize(node(d));

  int get innerOffset => pos - _path[depth].contentStart;

  bool get atNodeBoundary => innerOffset == 0;

  int get parentOffset => pos - startAt();

  /// Mirrors `ResolvedPos.indexAfter`'s sibling: the vendor's `textOffset`.
  int get textOffset {
    final p = node();
    return _isText(p) ? parentOffset : 0;
  }

  /// The node directly after the position, cut when the position is inside it.
  DocJson? get nodeAfter {
    final parent = node();
    final i = index();
    if (i == _childCount(parent)) return null;
    final child = _child(parent, i);
    final inner = innerOffset;
    return inner != 0 ? _nodeCut(child, inner, docNodeSize(child)) : child;
  }

  /// The node directly before the position, cut when the position is inside it.
  DocJson? get nodeBefore {
    final i = index();
    final inner = innerOffset;
    if (inner != 0) return _nodeCut(_child(node(), i), 0, inner);
    return i == 0 ? null : _child(node(), i - 1);
  }

  /// `ResolvedPos.self`: the node that starts exactly at this position.
  DocJson? get self => atNodeBoundary ? _maybeChild(node(), index()) : null;

  int commonDepth(DocResolvedPos other) {
    var d = 0;
    final min = depth < other.depth ? depth : other.depth;
    while (d < min && index(d) == other.index(d)) {
      d++;
    }
    return d;
  }
}

/// `Node.findIndex(pos)` with the vendor's default `round = -1`.
(int, int) _findIndex(DocJson node, int pos) {
  if (pos == 0) return (0, 0);
  final size = _contentSize(node);
  if (pos == size) return (_childCount(node), size);
  var cur = 0;
  for (var i = 0; i < _childCount(node); i++) {
    final s = docNodeSize(_child(node, i));
    if (pos < cur + s) return (i, cur);
    cur += s;
    if (pos == cur) return (i + 1, cur);
  }
  return (_childCount(node), size);
}

// ------------------------------------------------------------- doc.replace() --

/// `doc.slice(from, to)` — `Node.slice`.
DocSlice docSlice(DocJson doc, int from, int to) {
  if (from == to) return DocSlice.empty;
  final $from = DocResolvedPos.resolve(doc, from);
  final $to = DocResolvedPos.resolve(doc, to);
  final depth = $from.commonDepth($to);
  final start = $from.startAt(depth);
  final node = $from.node(depth);
  final content = _fragCut(
    _frag(node['content']),
    $from.pos - start,
    $to.pos - start,
  );
  return DocSlice(content, $from.depth - depth, $to.depth - depth);
}

/// `model.replace(doc, from, to, slice)` — the exclusive core.
///
/// Throws [DocReplaceError] for the vendor's `ReplaceError` cases and
/// [DocRangeError] for out-of-range offsets; both are observable in the
/// `failure` vectors.
DocJson replaceDoc(DocJson doc, int from, int to, DocSlice slice) {
  final $from = DocResolvedPos.resolve(doc, from);
  final $to = DocResolvedPos.resolve(doc, to);
  if (slice.openLeft > $from.depth) {
    throw const DocReplaceError(
      'Inserted content deeper than insertion position',
    );
  }
  if ($from.depth - slice.openLeft != $to.depth - slice.openRight) {
    throw const DocReplaceError('Inconsistent open depths');
  }
  return _replaceOuter($from, $to, slice, 0);
}

DocJson _replaceOuter(
  DocResolvedPos $from,
  DocResolvedPos $to,
  DocSlice slice,
  int depth,
) {
  final index = $from.index(depth);
  final node = $from.node(depth);
  if (index == $to.index(depth) && depth < $from.depth - slice.openLeft) {
    final inner = _replaceOuter($from, $to, slice, depth + 1);
    return _copyNode(
      node,
      content: _replaceChild(_frag(node['content']), index, inner),
    );
  }
  if (_fragSize(slice.content) == 0) {
    return _copyNode(node, content: _replaceTwoWay($from, $to, depth));
  }
  final prep = _prepareSliceForReplace(slice, $from);
  return _copyNode(
    node,
    content: _replaceThreeWay($from, prep.$1, prep.$2, $to, depth),
  );
}

/// `prepareSliceForReplace` — builds the synthetic tree the three-way join
/// resolves against, so slice content is spliced at the right depth.
(DocResolvedPos, DocResolvedPos) _prepareSliceForReplace(
  DocSlice slice,
  DocResolvedPos $from,
) {
  final extra = $from.depth - slice.openLeft;
  var start = _copyNode($from.node(extra), content: slice.content);
  for (var i = extra - 1; i >= 0; i--) {
    start = _copyNode($from.node(i), content: <DocJson>[start]);
  }
  final startPos = slice.openLeft + extra;
  final endPos = _contentSize(start) - slice.openRight - extra;
  return (
    DocResolvedPos.resolve(start, startPos),
    DocResolvedPos.resolve(start, endPos),
  );
}

List<DocJson> _replaceTwoWay(
  DocResolvedPos $from,
  DocResolvedPos $to,
  int depth,
) {
  final content = <DocJson>[];
  _addRange(null, $from, depth, content);
  if ($from.depth > depth) {
    final n = $from.node(depth + 1);
    content.add(_copyNode(n, content: _replaceTwoWay($from, $to, depth + 1)));
  }
  _addRange($to, null, depth, content);
  return _fromArray(content);
}

List<DocJson> _replaceThreeWay(
  DocResolvedPos $from,
  DocResolvedPos $start,
  DocResolvedPos $end,
  DocResolvedPos $to,
  int depth,
) {
  final p = $from.depth > depth ? $from.node(depth + 1) : null;
  final d = $end.depth > depth ? $end.node(depth + 1) : null;
  final content = <DocJson>[];
  _addRange(null, $from, depth, content);
  if (p != null && d != null && $start.index(depth) == $end.index(depth)) {
    content.add(
      _copyNode(
        p,
        content: _replaceThreeWay($from, $start, $end, $to, depth + 1),
      ),
    );
  } else {
    if (p != null) {
      content.add(
        _copyNode(p, content: _replaceTwoWay($from, $start, depth + 1)),
      );
    }
    _addRange($start, $end, depth, content);
    if (d != null) {
      content.add(_copyNode(d, content: _replaceTwoWay($end, $to, depth + 1)));
    }
  }
  _addRange($to, null, depth, content);
  return _fromArray(content);
}

/// `addRange($from, $to, depth, target)` — collects the children of the
/// `depth`-node that survive a replace between the two positions.
void _addRange(
  DocResolvedPos? $from,
  DocResolvedPos? $to,
  int depth,
  List<DocJson> target,
) {
  final base = ($to ?? $from)!;
  final node = base.node(depth);
  var index = 0;
  final end = $to != null ? $to.index(depth) : _childCount(node);
  if ($from != null) {
    index = $from.index(depth);
    if ($from.depth > depth) {
      index++;
    } else if (!$from.atNodeBoundary) {
      target.add($from.nodeAfter!);
      index++;
    }
  }
  for (var i = index; i < end; i++) {
    target.add(_child(node, i));
  }
  if ($to != null && $to.depth == depth && !$to.atNodeBoundary) {
    target.add($to.nodeBefore!);
  }
}

/// The fork's `contentBetween` guard used by `ReplaceStep` when `structure`
/// is true: refuses a structural replace that would overwrite content.
bool _contentBetween(DocJson doc, int from, int to) {
  final $from = DocResolvedPos.resolve(doc, from);
  var n = to - from;
  var depth = $from.depth;
  while (n > 0 &&
      depth > 0 &&
      $from.indexAfter(depth) == _childCount($from.node(depth))) {
    depth--;
    n--;
  }
  if (n > 0) {
    DocJson? t = _maybeChild($from.node(depth), $from.indexAfter(depth));
    while (n > 0) {
      if (t == null) return true;
      final spec = _schema.nodes[t['type']];
      if (spec != null && spec.isLeaf) return true;
      t = _firstChild(t);
      n--;
    }
  }
  return false;
}

// --------------------------------------------------------------- StepResult --

/// `StepResult` — the vendor shape is `{succ, doc}` (plus `commentStore`).
class StepResult {
  const StepResult._(this.succ, this.doc, this.reason);

  final bool succ;
  final DocJson? doc;
  final String? reason;

  factory StepResult.ok(DocJson doc) => StepResult._(true, doc, null);

  factory StepResult.fail(String reason) => StepResult._(false, null, reason);

  /// `StepResult.fromReplace` — a [DocReplaceError] becomes a failure, every
  /// other error propagates.
  static StepResult fromReplace(DocJson doc, int from, int to, DocSlice slice) {
    try {
      return StepResult.ok(replaceDoc(doc, from, to, slice));
    } on DocReplaceError catch (e) {
      return StepResult.fail(e.message);
    }
  }

  @override
  String toString() => succ ? 'StepResult.ok' : 'StepResult.fail($reason)';
}

// ------------------------------------------------------------------- PosMap --

/// A single mapped range result: `MapResult`.
class DocMapResult {
  const DocMapResult(this.pos, this.deleted);
  final int pos;
  final bool deleted;
  @override
  String toString() => 'DocMapResult($pos, deleted: $deleted)';
}

/// `PosMap` (`replacePos`) — the fork's mapping primitive. Wire shape:
/// `{"id":"replacePos","ranges":[pos, oldSize, newSize, …],"inverted":false}`.
class DocPosMap {
  DocPosMap(this.ranges, [this.inverted = false]);

  final List<int> ranges;
  final bool inverted;

  static final DocPosMap empty = DocPosMap(const <int>[]);

  int get length => ranges.length;

  /// `PosMap.create([pos, oldSize, newSize])`; an all-zero triple yields empty.
  factory DocPosMap.single(int pos, int oldSize, int newSize) {
    if (pos == 0 && oldSize == 0 && newSize == 0) return empty;
    return DocPosMap(<int>[pos, oldSize, newSize]);
  }

  int _normalizeAssoc(int? assoc, bool isNode, int deflt) {
    if (assoc == null) return deflt;
    if (assoc < 0) return -1;
    if (assoc > 0) return 1;
    return isNode ? 1 : 0;
  }

  int _compare(int pos, int point, int assoc, bool isNode) =>
      pos != point ? pos - point : (isNode ? assoc : 0);

  (int, bool) _run(int pos, int? assocIn, bool isNode) {
    final assoc = _normalizeAssoc(assocIn, isNode, 1);
    final r = ranges;
    final oldIndex = inverted ? 2 : 1;
    final newIndex = inverted ? 1 : 2;
    var diff = 0;
    for (var i = 0; i < r.length; i += 3) {
      final start = r[i] - (inverted ? diff : 0);
      final cmp = _compare(pos, start, assoc, isNode);
      if (cmp < 0) break;
      final oldSize = r[i + oldIndex];
      final newSize = r[i + newIndex];
      final end = start + oldSize;
      final cmpEnd = _compare(pos, end, assoc, isNode);
      if (cmpEnd <= 0) {
        final side = oldSize == 0
            ? assoc
            : (pos == start ? -1 : (pos == end ? 1 : assoc));
        final result = start + diff + (side < 0 ? 0 : newSize);
        return (result, cmp > 0 && cmpEnd < 0);
      }
      diff += newSize - oldSize;
    }
    return (pos + diff, false);
  }

  /// `PosMap.map(pos, assoc)`.
  int map(int pos, [int? assoc]) => _run(pos, assoc, false).$1;

  /// `PosMap.mapResult(pos, assoc)`.
  DocMapResult mapResult(int pos, [int? assoc]) {
    final r = _run(pos, assoc, false);
    return DocMapResult(r.$1, r.$2);
  }

  /// `PosMap.mapNodeResult(pos, assoc)` — the `node` flag changes the boundary
  /// comparison, which `SetNodeAttrsStep.mapPos` depends on.
  DocMapResult mapNodeResult(int pos, [int? assoc]) {
    final r = _run(pos, assoc, true);
    return DocMapResult(r.$1, r.$2);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': 'replacePos',
    'ranges': ranges,
    'inverted': inverted,
  };
}

/// `MapRange` — a mapped `[from, to)` interval.
class DocMapRange {
  DocMapRange(this.from, this.to, this.deleted);
  final int from;
  final int to;
  final bool deleted;
}

// ----------------------------------------------------------------- Mapping --

/// `Mapping` — an ordered list of [DocPosMap]s; `map`/`mapResult` fold over it.
///
/// [mapFrom] mirrors the vendor field used by `cherryPick`: only maps at index
/// `>= mapFrom` participate.
class DocMapping {
  DocMapping(this.posMaps, {this.mapFrom = 0});

  final List<DocPosMap> posMaps;
  final int mapFrom;

  static final DocMapping empty = DocMapping(const <DocPosMap>[]);

  int get length => posMaps.length;

  int get innerMapTo => length;

  bool get isMappable => length > mapFrom;

  DocMapping withMapFrom(int value) => DocMapping(posMaps, mapFrom: value);

  DocMapping withPosMaps(List<DocPosMap> value) =>
      DocMapping(value, mapFrom: mapFrom);

  int map(int pos, [int? assoc]) {
    var cur = pos;
    for (var i = mapFrom; i < posMaps.length; i++) {
      cur = posMaps[i].map(cur, assoc);
    }
    return cur;
  }

  /// `Mapping.mapResult` — `deleted` is the OR over every participating map.
  DocMapResult mapResult(int pos, [int? assoc]) {
    var cur = pos;
    var deleted = false;
    for (var i = mapFrom; i < posMaps.length; i++) {
      final r = posMaps[i].mapResult(cur, assoc);
      deleted = deleted || r.deleted;
      cur = r.pos;
    }
    return DocMapResult(cur, deleted);
  }

  DocMapResult mapNodeResult(int pos, [int? assoc]) {
    var cur = pos;
    var deleted = false;
    for (var i = mapFrom; i < posMaps.length; i++) {
      final r = posMaps[i].mapNodeResult(cur, assoc);
      deleted = deleted || r.deleted;
      cur = r.pos;
    }
    return DocMapResult(cur, deleted);
  }

  DocMapRange mapRange(int from, int to) {
    final a = mapResult(from, 1);
    final b = mapResult(to, -1);
    return DocMapRange(a.pos, b.pos, a.deleted && b.deleted);
  }

  /// `Mapping.invert()` — no mirror support (the vendor has no mirrors here).
  DocMapping invert() => DocMapping(<DocPosMap>[
    for (var i = posMaps.length - 1; i >= 0; i--)
      DocPosMap(posMaps[i].ranges, !posMaps[i].inverted),
  ], mapFrom: mapFrom);

  /// `Mapping.append` — appends [other]'s posMaps (mapFrom is preserved).
  DocMapping append(DocMapping other) =>
      DocMapping(<DocPosMap>[...posMaps, ...other.posMaps], mapFrom: mapFrom);
}

// -------------------------------------------------------------------- Steps --

/// Base class of the ported step family.
///
/// `jsonID`/wire shape and `map`/`posMap` behaviour match the vendor classes
/// (`ReplaceStep`, `AddMarkStep`, `RemoveMarkStep`, `SetNodeAttrsStep`,
/// `SetRootNodeAttrsStep`).
abstract class DocStep {
  const DocStep();

  String get stepType;

  /// `Step.toJSON()`.
  Map<String, Object?> toJson();

  /// `Step.apply(doc)`.
  StepResult apply(DocJson doc);

  /// `Step.map(mapping)` — null when the step is fully deleted by the mapping.
  DocStep? map(DocMapping mapping);

  /// `Step.posMap(doc)` — the vendor default is `PosMap.empty`.
  DocPosMap posMap(DocJson doc) => DocPosMap.empty;

  /// `Step.fromJSON(schema, json)`.
  ///
  /// Throws [DocStepParseException] on an unknown/malformed step (the vendor
  /// `RangeError`, which the server reports as `411 Invalid command`).
  static DocStep fromJson(Object? json) {
    if (json is! Map) {
      throw const DocStepParseException('step must be an object');
    }
    final m = json.cast<String, Object?>();
    final type = m['stepType'];
    final from = _int(m['from']);
    final to = _int(m['to']);
    switch (type) {
      case 'replace':
        // Vendor quirk (pinned by the failure vectors): `ReplaceStep.fromJSON`
        // is `new ReplaceStep(from, to, Slice.fromJSON(slice))` and NEVER reads
        // the `structure` field - only `ReplaceAroundStep.fromJSON` does. So on
        // the wire `structure` is write-only: `toJSON` emits it, `fromJSON`
        // drops it. Faithfully reproduced here.
        return ReplaceStep(
          from ?? 0,
          to ?? 0,
          DocSlice.fromJson(m['slice']),
          false,
        );
      case 'addMark':
        return AddMarkStep(from ?? 0, to ?? 0, _markFromJson(m['mark']));
      case 'removeMark':
        return RemoveMarkStep(from ?? 0, to ?? 0, _markFromJson(m['mark']));
      case 'setNodeAttrs':
        final pos = _int(m['pos']) ?? from;
        if (pos == null) {
          throw const DocStepParseException('setNodeAttrs without pos');
        }
        return SetNodeAttrsStep(pos, _attrs(m['attrs']));
      case 'setRootNodeAttrs':
        return SetRootNodeAttrsStep(_attrs(m['attrs']));
      default:
        throw DocStepParseException('No step named $type');
    }
  }

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  static Map<String, Object?> _attrs(Object? v) =>
      v is Map ? v.cast<String, Object?>() : <String, Object?>{};

  static Map<String, Object?> _markFromJson(Object? v) {
    if (v is! Map) {
      throw const DocStepParseException('mark must be an object');
    }
    final m = v.cast<String, Object?>();
    final name = m['_'] ?? m['type'];
    if (name is! String) {
      throw const DocStepParseException('mark without a name');
    }
    if (!_schema.marks.containsKey(name)) {
      throw DocStepParseException('Unknown mark type: $name');
    }
    final out = <String, Object?>{'_': name};
    for (final e in m.entries) {
      if (e.key == '_' || e.key == 'type') continue;
      out[e.key] = e.value;
    }
    return out;
  }
}

/// `replace` — the workhorse (text edits, splits, joins, attribute-free
/// structural edits). `structure=true` carries the vendor's overwrite guard.
class ReplaceStep extends DocStep {
  ReplaceStep(this.from, this.to, this.slice, this.structure);

  final int from;
  final int to;
  final DocSlice slice;
  final bool structure;

  @override
  String get stepType => 'replace';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'stepType': 'replace',
    'from': from,
    'to': to,
    'slice': slice.toJson(),
    'structure': structure,
  };

  @override
  StepResult apply(DocJson doc) {
    if (structure && _contentBetween(doc, from, to)) {
      return StepResult.fail('Structure replace would overwrite content');
    }
    try {
      return StepResult.ok(replaceDoc(doc, from, to, slice));
    } on DocReplaceError catch (e) {
      return StepResult.fail(e.message);
    }
  }

  @override
  DocPosMap posMap(DocJson doc) =>
      DocPosMap.single(from, to - from, slice.size);

  @override
  DocStep? map(DocMapping mapping) {
    final r = mapping.mapRange(from, to);
    if (r.deleted) return null;
    return ReplaceStep(r.from, r.to < r.from ? r.from : r.to, slice, structure);
  }

  @override
  String toString() =>
      'ReplaceStep($from, $to, ${slice.toString()}, '
      'structure: $structure)';
}

int _markRank(String name) => _schema.marks[name]?.rank ?? 1 << 20;

String _markName(Map<String, Object?> mark) =>
    (mark['_'] ?? mark['type']) as String? ?? '';

/// `Mark.addToSet` — dedupe, then insert by schema rank.
List<Object?> _markAddToSet(Map<String, Object?> mark, List<Object?> marks) {
  if (marks.any((m) => canonicalJson(m) == canonicalJson(mark))) return marks;
  final out = <Object?>[...marks];
  final rank = _markRank(_markName(mark));
  for (var i = 0; i < out.length; i++) {
    final other = (out[i] as Map).cast<String, Object?>();
    if (_markRank(_markName(other)) > rank) {
      out.insert(i, mark);
      return out;
    }
  }
  out.add(mark);
  return out;
}

/// `Mark.removeFromSet` — drops the first mark of the same type.
List<Object?> _markRemoveFromSet(
  Map<String, Object?> mark,
  List<Object?> marks,
) {
  final name = _markName(mark);
  for (var i = 0; i < marks.length; i++) {
    if (_markName((marks[i] as Map).cast<String, Object?>()) == name) {
      final out = <Object?>[...marks];
      out.removeAt(i);
      return out;
    }
  }
  return marks;
}

/// Applies [transform] to every text node inside a slice fragment (recursively),
/// mirroring the vendor's `mapNodesInside` walk.
List<DocJson> _mapTextNodes(
  List<DocJson> frag,
  DocJson Function(DocJson) transform,
) {
  return frag.map((node) {
    if (_isText(node)) return transform(node);
    final kids = _frag(node['content']);
    if (kids.isEmpty) return node;
    return _copyNode(node, content: _mapTextNodes(kids, transform));
  }).toList();
}

/// `addMark` — see `AddMarkStep`. Note: the vendor additionally filters by
/// `contentMatchAt(depth+1).allowsMark(markType)`; this port assumes the mark is
/// allowed at the target (all M2 vectors are, and the schema exposes no
/// per-node mark whitelist — M1 §8.2).
class AddMarkStep extends DocStep {
  AddMarkStep(this.from, this.to, this.mark);

  final int from;
  final int to;
  final Map<String, Object?> mark;

  @override
  String get stepType => 'addMark';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'stepType': 'addMark',
    'from': from,
    'to': to,
    'mark': <String, Object?>{...mark},
  };

  @override
  StepResult apply(DocJson doc) {
    final slice = docSlice(doc, from, to);
    final marked = DocSlice(
      _mapTextNodes(slice.content, (text) {
        final marks = _markAddToSet(
          mark,
          (text['marks'] as List?) ?? const <Object?>[],
        );
        return _withMarks(text, marks);
      }),
      slice.openLeft,
      slice.openRight,
    );
    return StepResult.fromReplace(doc, from, to, marked);
  }

  @override
  DocStep? map(DocMapping mapping) {
    final a = mapping.mapResult(from, 1);
    final b = mapping.mapResult(to, -1);
    if ((a.deleted && b.deleted) || a.pos >= b.pos) return null;
    return AddMarkStep(a.pos, b.pos, mark);
  }
}

/// `removeMark` — see `RemoveMarkStep`.
class RemoveMarkStep extends DocStep {
  RemoveMarkStep(this.from, this.to, this.mark);

  final int from;
  final int to;
  final Map<String, Object?> mark;

  @override
  String get stepType => 'removeMark';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'stepType': 'removeMark',
    'from': from,
    'to': to,
    'mark': <String, Object?>{...mark},
  };

  @override
  StepResult apply(DocJson doc) {
    final slice = docSlice(doc, from, to);
    final stripped = DocSlice(
      _mapTextNodes(slice.content, (text) {
        final marks = _markRemoveFromSet(
          mark,
          (text['marks'] as List?) ?? const <Object?>[],
        );
        return _withMarks(text, marks);
      }),
      slice.openLeft,
      slice.openRight,
    );
    return StepResult.fromReplace(doc, from, to, stripped);
  }

  @override
  DocStep? map(DocMapping mapping) {
    final a = mapping.mapResult(from, 1);
    final b = mapping.mapResult(to, -1);
    if ((a.deleted && b.deleted) || a.pos >= b.pos) return null;
    return RemoveMarkStep(a.pos, b.pos, mark);
  }
}

/// `setNodeAttrs` — merges attrs onto the node starting at [pos].
class SetNodeAttrsStep extends DocStep {
  SetNodeAttrsStep(this.pos, this.attrs);

  final int pos;
  final Map<String, Object?> attrs;

  @override
  String get stepType => 'setNodeAttrs';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'stepType': 'setNodeAttrs',
    'pos': pos,
    'attrs': <String, Object?>{...attrs},
  };

  @override
  StepResult apply(DocJson doc) {
    final $pos = DocResolvedPos.resolve(doc, pos);
    final self = $pos.self;
    if (self == null) {
      throw DocReplaceError('No valid node at position $pos.');
    }
    final updated = _copyNode(
      self,
      content: _frag(self['content']),
      attrs: mergeSettableAttrs(
        self['type']! as String,
        (self['attrs'] as Map?)?.cast<String, Object?>() ?? const {},
        attrs,
      ),
      attrsReplace: true,
    );
    return StepResult.fromReplace(
      doc,
      pos,
      pos + docNodeSize(self),
      DocSlice(<DocJson>[updated], 0, 0),
    );
  }

  @override
  DocPosMap posMap(DocJson doc) => DocPosMap.empty;

  @override
  DocStep? map(DocMapping mapping) {
    final r = mapping.mapNodeResult(pos, 1);
    if (r.deleted) return null;
    return SetNodeAttrsStep(r.pos, attrs);
  }
}

/// `setRootNodeAttrs` — merges attrs onto the document root. Never mapped.
class SetRootNodeAttrsStep extends DocStep {
  SetRootNodeAttrsStep(this.attrs);

  final Map<String, Object?> attrs;

  @override
  String get stepType => 'setRootNodeAttrs';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'stepType': 'setRootNodeAttrs',
    'attrs': <String, Object?>{...attrs},
  };

  @override
  StepResult apply(DocJson doc) => StepResult.ok(
    _copyNode(
      doc,
      content: _frag(doc['content']),
      attrs: mergeSettableAttrs(
        doc['type']! as String,
        (doc['attrs'] as Map?)?.cast<String, Object?>() ?? const {},
        attrs,
      ),
      attrsReplace: true,
    ),
  );

  @override
  DocStep? map(DocMapping mapping) => this;
}
