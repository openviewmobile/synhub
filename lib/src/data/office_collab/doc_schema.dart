// Office C' - M1: `.odoc` ProseMirror schema as a pure-Dart data layer.
//
// This file contains the model (`DocNodeSpec` / `DocMarkSpec` / `DocAttrSpec`)
// plus the JSON <-> canonical normalisation and validation logic. It is offline
// and dependency-free (only `dart:convert`), so it can be unit-tested without a
// NAS, a device or the SPK.
//
// Authority chain:
//   server/common/prosemirror/index.js :: schemaDocument.schema   (official object)
//     -> tool/office_collab_spike/schema/doc_schema.json          (committed export)
//       -> .../schema/doc_schema_generated.dart                   (generated consts)
//         -> this file                                            (typed model + logic)
//
// Normalisation contract (see docs/office-collab-schema-export.md §A.5):
//   R1  `optional:false` attrs (and composite `deep.<field>`) are ALWAYS emitted by
//       the editor, so an absent one is filled from its declared `default`.
//   R2  `optional:true` attrs are NEVER auto-filled. (The pre-M1 "fill all declared
//       defaults" reflex fills them too and turns the 36 raw differences into 105 -
//       pinned by a test in `test/office_collab_m1_schema_test.dart`.)
//   R3  an empty `attrs` map / empty `content` list is deleted (the editor omits
//       what Office.Import explicitly writes as `{}` / `[]`).
//   R4  the BSON `@C_text/comment` section drops `format` when it is the Import
//       default (`{"data":[],"format":1}` -> `{"data":[]}`).
//   R5  comparisons use canonical JSON (recursively sorted keys, no whitespace);
//       never compare raw text, because key order differs between Import and editor.
//
// Proven byte-for-byte against two real-hardware fixtures:
//   test/fixtures/office_collab/snapshot_doc_pre.json   (Office.Import `content.data`)
//   test/fixtures/office_collab/dart_fetched_doc_v1.json (editor `fetch`)
//   `schema.nodeFromJson(import).toJson()` == fetch.
import 'dart:convert';

import 'schema/doc_schema_generated.dart';

/// Thrown when a document refers to something the official schema does not define,
/// or when the schema cannot supply a required default. Nothing is ever ignored.
abstract class DocSchemaException implements Exception {
  const DocSchemaException();

  /// Human-readable, greppable message.
  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A node `type` that is not declared by the schema.
class UnknownNodeTypeException extends DocSchemaException {
  const UnknownNodeTypeException(this.nodeType, {this.path});

  final String nodeType;
  final String? path;

  @override
  String get message =>
      'unknown node type "$nodeType"${path == null ? '' : ' at $path'} '
      '- not declared in the document schema';
}

/// A mark name that is neither an inline mark nor a registered `attr_mark`.
class UnknownMarkException extends DocSchemaException {
  const UnknownMarkException(this.markName, {this.path});

  final String markName;
  final String? path;

  @override
  String get message =>
      'unknown mark "$markName"${path == null ? '' : ' at $path'} '
      '- not declared in the document schema';
}

/// An attr key that the target node/mark type does not declare.
class UnknownAttrException extends DocSchemaException {
  const UnknownAttrException(this.ownerType, this.attrName, {this.path});

  final String ownerType;
  final String attrName;
  final String? path;

  @override
  String get message =>
      '"$ownerType" declares no attr "$attrName"${path == null ? '' : ' at $path'} '
      '- refusing to pass it through silently';
}

/// A required attr has no serialisable default in the export (its default was a
/// JS factory function), so it cannot be materialised. We refuse rather than guess.
class UnfillableRequiredDefaultException extends DocSchemaException {
  const UnfillableRequiredDefaultException(this.ownerType, this.attrPath);

  final String ownerType;
  final String attrPath;

  @override
  String get message =>
      'required attr "$ownerType.$attrPath" has no serialisable default '
      '(the SPK default is a factory function) - cannot fill it automatically';
}

/// A structurally malformed node/mark object.
class MalformedDocNodeException extends DocSchemaException {
  const MalformedDocNodeException(this.reason, {this.path});

  final String reason;
  final String? path;

  @override
  String get message =>
      'malformed doc node${path == null ? '' : ' at $path'}: $reason';
}

/// One attr (or one composite `deep` sub-field) of a node or mark.
class DocAttrSpec {
  const DocAttrSpec({
    required this.name,
    required this.optional,
    required this.defaultSource,
    required this.hasDefault,
    required this.defaultValue,
    required this.defaultUnserializable,
    required this.hasEmptyValue,
    required this.emptyValue,
    required this.deep,
  });

  /// Wire name of the attr (e.g. `page_setup`, `place-show`, `value`).
  final String name;

  /// `optional:true` => the default lives in the `empty_value` channel.
  /// `optional:false` => the default lives in the `default` channel and is always emitted.
  final bool optional;

  /// Which channel the export recorded the default in (`default` / `empty_value`).
  final String defaultSource;

  /// Whether [defaultValue] is a real, usable value.
  final bool hasDefault;

  /// The declared default (`.default` for required attrs).
  final Object? defaultValue;

  /// True when the SPK default was a JS factory function and only serialised as `<fn>`.
  final bool defaultUnserializable;

  /// Whether the `empty_value` channel was present in the export.
  final bool hasEmptyValue;

  /// The declared `empty_value` (the value the editor omits for optional attrs).
  final Object? emptyValue;

  /// Composite sub-fields (e.g. `page_setup.left` / `page_setup.orientation`).
  final Map<String, DocAttrSpec> deep;

  bool get isRequired => !optional;

  /// R1 can materialise this attr when it is absent.
  bool get canFillRequired => hasDefault && !defaultUnserializable;
}

/// A node type declared by the schema.
class DocNodeSpec {
  const DocNodeSpec({
    required this.name,
    required this.content,
    required this.groups,
    required this.isLeaf,
    required this.isText,
    required this.emptyNodeSize,
    required this.attrs,
  });

  final String name;

  /// Raw content expression (`inline<_>*`, `settings style_editor ...`), or null.
  final String? content;

  /// Groups this node belongs to (`block`, `inline`, ...).
  final List<String> groups;

  final bool isLeaf;
  final bool isText;

  /// Positions the node occupies when empty (leaf => 1, container => 2).
  final int? emptyNodeSize;

  /// Declared attrs, in the schema's declaration order.
  final Map<String, DocAttrSpec> attrs;
}

/// An inline mark or a block `attr_mark`.
class DocMarkSpec {
  const DocMarkSpec({
    required this.name,
    required this.rank,
    required this.isAttrMark,
    required this.kind,
    required this.attrs,
    required this.applicableTo,
    required this.applicabilitySource,
    required this.applicabilityCaveat,
  });

  final String name;

  /// Declaration order = priority (`font_size`=0 ... `tracking`=11; attr marks 0..3).
  final int rank;

  /// `attr_mark`s live in a separate registry (`schema.attr_marks`), not in `schema.marks`.
  final bool isAttrMark;

  final String kind;
  final Map<String, DocAttrSpec> attrs;

  /// Nodes the mark can be applied to, or null when the SPK gives no call site
  /// (`direction` / `text_indent` are `unproven`).
  final List<String>? applicableTo;
  final String? applicabilitySource;
  final String? applicabilityCaveat;
}

/// A parsed, validated, canonicalised node.
class DocNode {
  DocNode._({
    required this.type,
    required this.attrs,
    required this.content,
    required this.marks,
    required this.text,
  });

  final String type;

  /// Canonical attrs (required defaults filled, empty attrs already removed).
  final Map<String, Object?> attrs;

  /// Canonical children, or null when empty.
  final List<DocNode>? content;

  /// Marks of a text node (rank-sorted), or null.
  final List<DocMark>? marks;

  /// The text of a `text` node, or null.
  final String? text;

  bool get isText => type == 'text';

  /// Wire object, keys in the schema's order: `type, attrs, content, marks`
  /// (text nodes use the fork's real order `type, marks, text`).
  Map<String, Object?> toJson() {
    final out = <String, Object?>{'type': type};
    if (isText) {
      if (marks != null && marks!.isNotEmpty) {
        out['marks'] = marks!.map((m) => m.toJson()).toList();
      }
      out['text'] = text;
      return out;
    }
    if (attrs.isNotEmpty) {
      out['attrs'] = <String, Object?>{...attrs};
    }
    final kids = content;
    if (kids != null && kids.isNotEmpty) {
      out['content'] = kids.map((c) => c.toJson()).toList();
    }
    if (marks != null && marks!.isNotEmpty) {
      out['marks'] = marks!.map((m) => m.toJson()).toList();
    }
    return out;
  }

  /// [toJson] rendered as JSON text (insertion order preserved).
  String toJsonString() => jsonEncode(toJson());

  // ------------------------------------------------------- public raw bridge --
  //
  // M2 (`doc_step.dart` / `doc_ot_queue.dart`) and the session layer work on the
  // *raw* `DocJson` tree (`Map<String, Object?>`), while M1 keeps the validating,
  // private `DocNode._` constructor. These two entry points are that bridge; they
  // add no new behaviour - [fromRawJson] is exactly `DocSchema.nodeFromJson` and
  // [toRawJson] is exactly [toJson] - they only make the crossing explicit at the
  // call site instead of leaking `DocSchema.document` everywhere.
  //
  // [fromRawJson] validates and canonicalises: unknown node/mark/attr throws, and
  // absent required attrs are filled from their schema defaults (R1). Never call
  // it on the hot OT path; parse once per `fetch`, then feed the raw result to the
  // M2 queue.

  /// Parse raw `.odoc` editor/Import JSON into a validated [DocNode].
  static DocNode fromRawJson(Object? json, {List<String>? fillLog}) =>
      DocSchema.document.nodeFromJson(json, fillLog: fillLog);

  /// The raw `DocJson` form of this node (identical to [toJson]).
  Map<String, Object?> toRawJson() => toJson();

  @override
  String toString() => 'DocNode(${toJsonString()})';
}

/// A parsed, validated mark on a text node.
class DocMark {
  DocMark._(this.spec, this.attrs);

  final DocMarkSpec spec;
  final Map<String, Object?> attrs;

  String get name => spec.name;

  /// Wire object: `{"_": <name>, <attrs...>}` - the fork uses `_` for the mark
  /// type name (confirmed on 16 real `template/doc/*/text.json` samples).
  Map<String, Object?> toJson() {
    final out = <String, Object?>{'_': name};
    for (final entry in spec.attrs.entries) {
      final a = entry.value;
      if (!attrs.containsKey(entry.key)) continue;
      final v = attrs[entry.key];
      // Boolean "presence" marks (em/strong/superscript/subscript/underline/strike)
      // omit their `value` when it is true; confirmed against real template samples
      // (`{"_":"strong"}`) and the runtime schema. All other attrs are emitted.
      final presenceOmitted =
          a.isRequired &&
          a.defaultValue == true &&
          a.hasEmptyValue &&
          a.emptyValue == false &&
          v == true;
      if (presenceOmitted) continue;
      out[entry.key] = v;
    }
    return out;
  }

  @override
  String toString() => 'DocMark(${jsonEncode(toJson())})';
}

/// How a tree is rewritten before serialisation/comparison. The named presets make
/// the R1/R2/R3 rules explicit and let tests pin the wrong variants on purpose.
class DocNormalizeOptions {
  const DocNormalizeOptions({
    this.fillRequired = true,
    this.fillOptional = false,
    this.fillDeepRequired = true,
    this.dropOptionalEqualToEmptyValue = false,
    this.dropEmptyAttrs = true,
    this.dropEmptyContent = true,
  });

  /// R1 for top-level attrs.
  final bool fillRequired;

  /// The R2 violation: also fill absent optional attrs from `empty_value`.
  final bool fillOptional;

  /// R1 for composite `deep.<field>` (e.g. `page_setup.orientation`).
  final bool fillDeepRequired;

  /// Drop optional attrs whose value equals `empty_value`.
  /// Caveat: the real `toJSON()` does NOT do this for attrs that were explicitly
  /// set (`paddingTop: 0`, `listMap: {}` survive on the wire); the flag exists to
  /// reproduce the comparison algorithm of `verify_doc_normalization.js`.
  final bool dropOptionalEqualToEmptyValue;

  /// R3 for `attrs`.
  final bool dropEmptyAttrs;

  /// R3 for `content`.
  final bool dropEmptyContent;

  /// The real editor serialisation contract: R1 + R3, never fill/drop optional.
  static const DocNormalizeOptions editorSerialization = DocNormalizeOptions();

  /// `verify_doc_normalization.js` "schema (full)" comparison mode.
  static const DocNormalizeOptions schemaComparison = DocNormalizeOptions(
    dropOptionalEqualToEmptyValue: true,
  );

  /// `verify_doc_normalization.js` "legacy (empty_value)" comparison mode: no R1.
  static const DocNormalizeOptions emptyValueApproximation =
      DocNormalizeOptions(
        fillRequired: false,
        fillDeepRequired: false,
        dropOptionalEqualToEmptyValue: true,
      );

  /// The naive "fill the optional defaults too" transform that the M1 report warns
  /// about. Applied to the Import side it turns 36 differences into 105.
  static const DocNormalizeOptions naiveFillOptional = DocNormalizeOptions(
    fillRequired: false,
    fillOptional: true,
    fillDeepRequired: false,
  );

  /// Like [naiveFillOptional] but with R1 already correct (102 differences).
  static const DocNormalizeOptions naiveFillOptionalWithRequired =
      DocNormalizeOptions(fillOptional: true);
}

/// The official `.odoc` schema, loaded from the generated constants.
class DocSchema {
  DocSchema._({
    required this.name,
    required this.version,
    required this.topNodeName,
    required this.topNodeContent,
    required this.jsonKeyOrder,
    required this.groups,
    required this.nodes,
    required this.marks,
    required this.attrMarks,
  });

  /// The `.odoc` schema (`document` v13).
  static final DocSchema document = DocSchema.fromGenerated();

  final String name;
  final int version;
  final String topNodeName;
  final String topNodeContent;
  final List<String> jsonKeyOrder;
  final Map<String, List<String>> groups;
  final Map<String, DocNodeSpec> nodes;
  final Map<String, DocMarkSpec> marks;
  final Map<String, DocMarkSpec> attrMarks;

  /// Build from `doc_schema_generated.dart`.
  factory DocSchema.fromGenerated() {
    final nodes = <String, DocNodeSpec>{};
    for (final raw in kDocNodeSpecs) {
      final m = _asMap(raw);
      final spec = DocNodeSpec(
        name: m['name']! as String,
        content: m['content'] as String?,
        groups: _asList(m['groups']).map((e) => e! as String).toList(),
        isLeaf: m['isLeaf']! as bool,
        isText: m['isText']! as bool,
        emptyNodeSize: m['emptyNodeSize'] as int?,
        attrs: _attrTable(_asMap(m['attrs'])),
      );
      nodes[spec.name] = spec;
    }
    final marks = <String, DocMarkSpec>{};
    for (final raw in kDocMarkSpecs) {
      final spec = _markSpec(_asMap(raw), isAttrMark: false);
      marks[spec.name] = spec;
    }
    final attrMarks = <String, DocMarkSpec>{};
    for (final raw in kDocAttrMarkSpecs) {
      final spec = _markSpec(_asMap(raw), isAttrMark: true);
      attrMarks[spec.name] = spec;
    }
    final groups = <String, List<String>>{};
    for (final entry in kDocGroups.entries) {
      groups[entry.key] = _asList(
        entry.value,
      ).map((e) => e! as String).toList();
    }
    return DocSchema._(
      name: kDocSchemaName,
      version: kDocSchemaVersion,
      topNodeName: kDocTopNodeName,
      topNodeContent: kDocTopNodeContent,
      jsonKeyOrder: kDocJsonKeyOrder.map((e) => e! as String).toList(),
      groups: groups,
      nodes: nodes,
      marks: marks,
      attrMarks: attrMarks,
    );
  }

  static DocMarkSpec _markSpec(
    Map<String, Object?> m, {
    required bool isAttrMark,
  }) {
    final applicable = m['applicableTo'];
    return DocMarkSpec(
      name: m['name']! as String,
      rank: m['rank']! as int,
      isAttrMark: isAttrMark,
      kind: m['kind']! as String,
      attrs: _attrTable(_asMap(m['attrs'])),
      applicableTo: applicable == null
          ? null
          : _asList(applicable).map((e) => e! as String).toList(),
      applicabilitySource: m['applicabilitySource'] as String?,
      applicabilityCaveat: m['applicabilityCaveat'] as String?,
    );
  }

  static Map<String, DocAttrSpec> _attrTable(Map<String, Object?> raw) {
    final out = <String, DocAttrSpec>{};
    for (final entry in raw.entries) {
      out[entry.key] = _attrSpec(entry.key, _asMap(entry.value));
    }
    return out;
  }

  static DocAttrSpec _attrSpec(String name, Map<String, Object?> m) {
    final rawDeep = m['deep'];
    final deep = <String, DocAttrSpec>{};
    if (rawDeep != null) {
      for (final entry in _asMap(rawDeep).entries) {
        deep[entry.key] = _attrSpec(entry.key, _asMap(entry.value));
      }
    }
    return DocAttrSpec(
      name: name,
      optional: m['optional']! as bool,
      defaultSource: m['defaultSource']! as String,
      hasDefault: m['hasDefault']! as bool,
      defaultValue: m['default'],
      defaultUnserializable: m['defaultUnserializable']! as bool,
      hasEmptyValue: m['hasEmptyValue']! as bool,
      emptyValue: m['emptyValue'],
      deep: deep,
    );
  }

  /// Lookup an inline mark or an `attr_mark` by name.
  DocMarkSpec? markSpecOrNull(String markName) =>
      marks[markName] ?? attrMarks[markName];

  /// Lookup a node type by name, or throw [UnknownNodeTypeException].
  DocNodeSpec nodeSpec(String nodeType, {String? path}) =>
      nodes[nodeType] ?? (throw UnknownNodeTypeException(nodeType, path: path));

  /// Lookup a mark by name, or throw [UnknownMarkException].
  DocMarkSpec markSpec(String markName, {String? path}) =>
      markSpecOrNull(markName) ??
      (throw UnknownMarkException(markName, path: path));

  // ---------------------------------------------------------------- parsing --

  /// `schema.nodeFromJSON(x)` equivalent: validate, fill R1 defaults, canonicalise.
  ///
  /// Throws [UnknownNodeTypeException] / [UnknownMarkException] /
  /// [UnknownAttrException] / [UnfillableRequiredDefaultException] /
  /// [MalformedDocNodeException]. Nothing is silently ignored.
  ///
  /// When [fillLog] is supplied, every required default that had to be materialised
  /// is appended as `<node>.<attr>` / `<node>.<attr>.<deepField>`.
  DocNode nodeFromJson(Object? json, {List<String>? fillLog}) {
    return _parseNode(
      json,
      DocNormalizeOptions.editorSerialization,
      fillLog,
      r'$',
    );
  }

  /// Import-state (`@C_text/content.data`, produced by `Office.Import`) -> editor state.
  DocNode normalizeFromImport(Object? importJson, {List<String>? fillLog}) =>
      nodeFromJson(importJson, fillLog: fillLog);

  DocNode _parseNode(
    Object? json,
    DocNormalizeOptions opts,
    List<String>? fillLog,
    String path,
  ) {
    if (json is! Map) {
      throw MalformedDocNodeException(
        'expected an object, got ${json.runtimeType}',
        path: path,
      );
    }
    final map = _asMap(json);
    final type = map['type'];
    if (type is! String) {
      throw MalformedDocNodeException('missing/invalid "type"', path: path);
    }
    for (final key in map.keys) {
      if (!const {'type', 'attrs', 'content', 'marks', 'text'}.contains(key)) {
        throw MalformedDocNodeException('unexpected key "$key"', path: path);
      }
    }
    if (type == 'text') {
      return _parseTextNode(map, path);
    }

    final spec = nodeSpec(type, path: path);
    final attrs = <String, Object?>{};
    final rawAttrs = map['attrs'];
    if (rawAttrs != null) {
      if (rawAttrs is! Map) {
        throw MalformedDocNodeException(
          '"attrs" must be an object',
          path: path,
        );
      }
      for (final entry in _asMap(rawAttrs).entries) {
        if (!spec.attrs.containsKey(entry.key)) {
          throw UnknownAttrException(type, entry.key, path: path);
        }
        // Deep-copy so that R1 filling never mutates the caller's input tree.
        attrs[entry.key] = _deepCopy(entry.value);
      }
    }
    _applyAttrDefaults(spec.attrs, attrs, type, fillLog);

    List<DocNode>? content;
    final rawContent = map['content'];
    if (rawContent != null) {
      if (rawContent is! List) {
        throw MalformedDocNodeException(
          '"content" must be an array',
          path: path,
        );
      }
      final kids = <DocNode>[];
      for (var i = 0; i < rawContent.length; i++) {
        kids.add(_parseNode(rawContent[i], opts, fillLog, '\$content[$i]'));
      }
      content = kids;
    }
    // `marks` on a non-text node is not produced by the fork; reject it.
    if (map.containsKey('marks') && map['marks'] != null) {
      throw MalformedDocNodeException(
        '"marks" is only valid on text nodes',
        path: path,
      );
    }
    return _canonicalise(
      type: type,
      attrs: attrs,
      content: content,
      marks: null,
      text: null,
      opts: opts,
    );
  }

  DocNode _parseTextNode(Map<String, Object?> map, String path) {
    final text = map['text'];
    if (text is! String) {
      throw MalformedDocNodeException(
        'text node without a string "text"',
        path: path,
      );
    }
    if (text.isEmpty) {
      throw MalformedDocNodeException(
        'empty text nodes are rejected by the model',
        path: path,
      );
    }
    final rawAttrs = map['attrs'];
    if (rawAttrs is Map && rawAttrs.isNotEmpty) {
      final first = _asMap(rawAttrs).keys.first;
      throw UnknownAttrException('text', first, path: path);
    }
    List<DocMark>? marks;
    final rawMarks = map['marks'];
    if (rawMarks != null) {
      if (rawMarks is! List) {
        throw MalformedDocNodeException('"marks" must be an array', path: path);
      }
      final parsed = <DocMark>[];
      for (var i = 0; i < rawMarks.length; i++) {
        parsed.add(_parseMark(rawMarks[i], '\$marks[$i]'));
      }
      parsed.sort((a, b) => a.spec.rank.compareTo(b.spec.rank));
      marks = parsed;
    }
    return DocNode._(
      type: 'text',
      attrs: const {},
      content: null,
      marks: marks,
      text: text,
    );
  }

  DocMark _parseMark(Object? json, String path) {
    if (json is! Map) {
      throw MalformedDocNodeException('mark must be an object', path: path);
    }
    final map = _asMap(json);
    final name = (map['_'] ?? map['type']);
    if (name is! String) {
      throw MalformedDocNodeException(
        'mark without a name ("_" or "type")',
        path: path,
      );
    }
    final spec = markSpec(name, path: path);
    final attrs = <String, Object?>{};
    for (final entry in map.entries) {
      if (entry.key == '_' || entry.key == 'type') continue;
      if (!spec.attrs.containsKey(entry.key)) {
        throw UnknownAttrException(name, entry.key, path: path);
      }
      attrs[entry.key] = _deepCopy(entry.value);
    }
    _applyAttrDefaults(spec.attrs, attrs, name, null);
    return DocMark._(spec, attrs);
  }

  /// R1: materialise absent required attrs (and required `deep` sub-fields).
  /// R2 is the deliberate absence of anything here for `optional:true` attrs.
  void _applyAttrDefaults(
    Map<String, DocAttrSpec> table,
    Map<String, Object?> attrs,
    String owner,
    List<String>? fillLog,
  ) {
    for (final entry in table.entries) {
      final a = entry.value;
      if (a.isRequired && !attrs.containsKey(entry.key)) {
        if (!a.canFillRequired) {
          throw UnfillableRequiredDefaultException(owner, entry.key);
        }
        attrs[entry.key] = _deepCopy(a.defaultValue);
        fillLog?.add('$owner.${entry.key}');
      }
      if (a.deep.isEmpty) continue;
      final v = attrs[entry.key];
      if (v is! Map) continue;
      final sub = _asMap(v);
      for (final d in a.deep.entries) {
        if (!d.value.isRequired || sub.containsKey(d.key)) continue;
        if (!d.value.canFillRequired) {
          throw UnfillableRequiredDefaultException(
            owner,
            '${entry.key}.${d.key}',
          );
        }
        sub[d.key] = _deepCopy(d.value.defaultValue);
        fillLog?.add('$owner.${entry.key}.${d.key}');
      }
      attrs[entry.key] = sub;
    }
  }

  DocNode _canonicalise({
    required String type,
    required Map<String, Object?> attrs,
    required List<DocNode>? content,
    required List<DocMark>? marks,
    required String? text,
    required DocNormalizeOptions opts,
  }) {
    final finalAttrs = <String, Object?>{};
    for (final entry in attrs.entries) {
      final spec = nodes[type]?.attrs[entry.key];
      if (spec != null &&
          opts.dropOptionalEqualToEmptyValue &&
          spec.optional &&
          spec.hasEmptyValue &&
          _jsonEquals(entry.value, spec.emptyValue)) {
        continue;
      }
      finalAttrs[entry.key] = entry.value;
    }
    final keepAttrs = opts.dropEmptyAttrs ? finalAttrs.isNotEmpty : true;
    final kids = content;
    final keepContent = opts.dropEmptyContent
        ? (kids != null && kids.isNotEmpty)
        : kids != null;
    return DocNode._(
      type: type,
      attrs: keepAttrs ? finalAttrs : const {},
      content: keepContent ? kids : null,
      marks: marks,
      text: text,
    );
  }

  // ------------------------------------------------- comparison / diffing --

  /// Rewrite a raw node tree with [opts] (used to reproduce the historical
  /// 36 -> 3 -> 0 measurement). Unlike [nodeFromJson] this tolerates unknown
  /// types (it is a comparison tool, not a validator) and works on plain maps.
  Map<String, Object?> normalizeForComparison(
    Object? node,
    DocNormalizeOptions opts, {
    List<String>? fillLog,
  }) {
    final map = _asMap(node);
    final type = map['type'];
    if (type is! String) {
      throw MalformedDocNodeException('missing/invalid "type"');
    }
    if (type == 'text') {
      final out = <String, Object?>{'type': 'text'};
      if (map['marks'] != null) out['marks'] = map['marks'];
      out['text'] = map['text'];
      return out;
    }
    final spec = nodes[type];
    final attrs = <String, Object?>{
      for (final e in _asMap(map['attrs'] ?? const <String, Object?>{}).entries)
        e.key: _deepCopy(e.value),
    };
    if (spec != null) {
      for (final entry in spec.attrs.entries) {
        final a = entry.value;
        final fill =
            (a.isRequired && opts.fillRequired) ||
            (a.optional && opts.fillOptional);
        if (fill && !attrs.containsKey(entry.key)) {
          // R2's naive variant fills optional attrs from `empty_value`.
          final value = a.isRequired ? a.defaultValue : a.emptyValue;
          attrs[entry.key] = _deepCopy(value);
          fillLog?.add('$type.${entry.key}');
        }
        if (a.deep.isNotEmpty && attrs[entry.key] is Map) {
          final sub = _asMap(attrs[entry.key]);
          for (final d in a.deep.entries) {
            // Deep sub-fields are only ever auto-filled when required (mirrors
            // `verify_doc_normalization.js`; optional sub-fields are left alone).
            if (d.value.isRequired &&
                opts.fillDeepRequired &&
                !sub.containsKey(d.key)) {
              sub[d.key] = _deepCopy(d.value.defaultValue);
              fillLog?.add('$type.${entry.key}.${d.key}');
            }
          }
          attrs[entry.key] = sub;
        }
        if (opts.dropOptionalEqualToEmptyValue &&
            a.optional &&
            a.hasEmptyValue &&
            attrs.containsKey(entry.key) &&
            _jsonEquals(attrs[entry.key], a.emptyValue)) {
          attrs.remove(entry.key);
        }
      }
    }
    final out = <String, Object?>{'type': type};
    if (!opts.dropEmptyAttrs || attrs.isNotEmpty) out['attrs'] = attrs;
    final rawContent = map['content'];
    if (rawContent is List) {
      final kids = rawContent
          .map((c) => normalizeForComparison(c, opts, fillLog: fillLog))
          .toList();
      if (!opts.dropEmptyContent || kids.isNotEmpty) out['content'] = kids;
    }
    return out;
  }

  /// Structural diff of two trees: path -> `[left, right]` (`'<absent>'` marker).
  Map<String, List<Object?>> diffDocs(Object? a, Object? b) {
    final out = <String, List<Object?>>{};
    _diff(a, b, r'$', out);
    return out;
  }

  void _diff(
    Object? a,
    Object? b,
    String path,
    Map<String, List<Object?>> out,
  ) {
    if (canonicalJson(a) == canonicalJson(b)) return;
    final aObj = a is Map || a is List;
    final bObj = b is Map || b is List;
    if (!aObj || !bObj || (a is List) != (b is List)) {
      out[path] = <Object?>[a, b];
      return;
    }
    if (a is List && b is List) {
      if (a.length != b.length) {
        out['$path.length'] = <Object?>[a.length, b.length];
      }
      final n = a.length > b.length ? a.length : b.length;
      for (var i = 0; i < n; i++) {
        _diff(
          i < a.length ? a[i] : null,
          i < b.length ? b[i] : null,
          '$path[$i]',
          out,
        );
      }
      return;
    }
    final am = _asMap(a);
    final bm = _asMap(b);
    final keys = <String>{...am.keys, ...bm.keys}.toList()..sort();
    for (final k in keys) {
      if (!am.containsKey(k)) {
        out['$path.$k'] = <Object?>['<absent>', bm[k]];
      } else if (!bm.containsKey(k)) {
        out['$path.$k'] = <Object?>[am[k], '<absent>'];
      } else {
        _diff(am[k], bm[k], '$path.$k', out);
      }
    }
  }

  // ------------------------------------------------------------- R4 / node size --

  /// R4: the `@C_text/comment` BSON section. `Office.Import` writes
  /// `{"data":[],"format":1}`; the editor snapshot omits `format`.
  Map<String, Object?> normalizeCommentSection(Map<String, Object?> section) {
    final out = <String, Object?>{...section};
    if (out['format'] == 1) out.remove('format');
    return out;
  }

  /// The fork's three `nodeSize` rules (docs/office-collab-schema-export.md §A.2).
  int nodeSize(DocNode node) {
    if (node.isText) return (node.text ?? '').length;
    final spec = nodes[node.type];
    if (spec != null && spec.isLeaf) return 1;
    var sum = 0;
    for (final child in node.content ?? const <DocNode>[]) {
      sum += nodeSize(child);
    }
    return sum + 2;
  }
}

// ------------------------------------------------------------------ helpers --

Map<String, Object?> _asMap(Object? v) {
  if (v is Map<String, Object?>) return v;
  if (v is Map) {
    return <String, Object?>{
      for (final e in v.entries) e.key as String: e.value,
    };
  }
  throw MalformedDocNodeException('expected an object, got ${v.runtimeType}');
}

List<Object?> _asList(Object? v) => v is List ? v : const <Object?>[];

/// Deep copy so that schema defaults (shared const data) never leak mutations.
Object? _deepCopy(Object? v) {
  if (v is Map) {
    return <String, Object?>{
      for (final e in _asMap(v).entries) e.key: _deepCopy(e.value),
    };
  }
  if (v is List) return v.map(_deepCopy).toList();
  return v;
}

/// R5: canonical JSON - recursively sorted keys, no whitespace.
String canonicalJson(Object? v) {
  final b = StringBuffer();
  _writeCanonical(v, b);
  return b.toString();
}

void _writeCanonical(Object? v, StringBuffer b) {
  if (v == null) {
    b.write('null');
  } else if (v is bool) {
    b.write(v ? 'true' : 'false');
  } else if (v is int) {
    b.write(v.toString());
  } else if (v is double) {
    if (!v.isFinite) {
      b.write('null');
    } else if (v == v.roundToDouble()) {
      b.write(v.toInt().toString());
    } else {
      b.write(v.toString());
    }
  } else if (v is String) {
    b.write(jsonEncode(v));
  } else if (v is List) {
    b.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) b.write(',');
      _writeCanonical(v[i], b);
    }
    b.write(']');
  } else if (v is Map) {
    final keys = _asMap(v).keys.toList()..sort();
    b.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) b.write(',');
      b.write(jsonEncode(keys[i]));
      b.write(':');
      _writeCanonical(_asMap(v)[keys[i]], b);
    }
    b.write('}');
  } else {
    throw MalformedDocNodeException('cannot canonicalise ${v.runtimeType}');
  }
}

/// Structural JSON equality (canonical form), matching `JSON.stringify` semantics.
bool _jsonEquals(Object? a, Object? b) => canonicalJson(a) == canonicalJson(b);
