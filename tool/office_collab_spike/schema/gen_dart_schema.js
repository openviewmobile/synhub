#!/usr/bin/env node
/*
 * Office C' - M1: generate the Dart `.odoc` schema constants from the
 * authoritative, machine-readable export `doc_schema.json`.
 *
 * WHY A GENERATOR (and not a hand-copied table):
 *   `doc_schema.json` is byte-for-byte derived from the server package's own
 *   ProseMirror bundle (`server/common/prosemirror/index.js`, `schemaDocument.schema`).
 *   Hand-transcribing 32 nodes / 12 marks / 4 attr_marks / 143 attrs would silently
 *   drift. This generator is deterministic and committed, so the Dart constants are a
 *   pure function of the committed JSON.
 *
 * WHAT IT EMITS (structured Dart const data, NOT a JSON blob - no asset mechanism):
 *   lib/src/data/office_collab/schema/doc_schema_generated.dart
 *
 * The generated file is consumed by `lib/src/data/office_collab/doc_schema.dart`,
 * which turns these raw maps into typed `DocNodeSpec` / `DocMarkSpec` / `DocAttrSpec`.
 *
 * Default-value fidelity notes:
 *   - `optional:false`  -> serialization default lives in `.default`;
 *   - `optional:true`   -> serialization default lives in `options.empty_value`
 *                          (`.default` mirrors it in the export);
 *   - a handful of required defaults are JS factory functions and could only be
 *     serialized as the sentinel string "<fn>". Those become
 *     `hasDefault:false, defaultUnserializable:true` so the Dart layer refuses to
 *     silently invent a value (it raises instead).
 *
 * Usage:
 *   node tool/office_collab_spike/schema/gen_dart_schema.js \
 *        [--schema tool/office_collab_spike/schema/doc_schema.json] \
 *        [--out lib/src/data/office_collab/schema/doc_schema_generated.dart]
 */
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const argv = process.argv.slice(2);
function arg(f, d) {
  const i = argv.indexOf(f);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
}

const REPO = path.resolve(__dirname, '..', '..', '..');
const SCHEMA = path.resolve(arg('--schema', path.join(__dirname, 'doc_schema.json')));
const OUT = path.resolve(arg('--out', path.join(REPO, 'lib/src/data/office_collab/schema/doc_schema_generated.dart')));

const FN_SENTINEL = '<fn>';

/* ---------------------------------------------------------------- literals -- */

function dartString(s) {
  // JSON escaping is a valid superset of Dart string escaping for our alphabet
  // (we only ever emit ASCII-safe schema text here).
  return JSON.stringify(s);
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function dartLiteral(v, indent) {
  const pad = '  '.repeat(indent);
  const padIn = '  '.repeat(indent + 1);
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) throw new Error('non-finite number in schema: ' + v);
    return String(v);
  }
  if (typeof v === 'string') return dartString(v);
  if (Array.isArray(v)) {
    if (v.length === 0) return '<Object?>[]';
    const items = v.map((x) => padIn + dartLiteral(x, indent + 1));
    return '<Object?>[\n' + items.join(',\n') + ',\n' + pad + ']';
  }
  if (isPlainObject(v)) {
    const keys = Object.keys(v);
    if (keys.length === 0) return '<String, Object?>{}';
    const items = keys.map(
      (k) => padIn + dartString(k) + ': ' + dartLiteral(v[k], indent + 1),
    );
    return '<String, Object?>{\n' + items.join(',\n') + ',\n' + pad + '}';
  }
  throw new Error('cannot serialise value of type ' + typeof v);
}

/* ------------------------------------------------------------- attr specs -- */

// The raw export mixes two default channels. Normalise each attr to an explicit,
// channel-tagged record so the Dart layer never has to re-derive the rule.
function attrSpec(name, a) {
  const opts = isPlainObject(a.options) ? a.options : {};
  const rawDefault = Object.prototype.hasOwnProperty.call(a, 'default') ? a.default : undefined;
  const rawEmpty = Object.prototype.hasOwnProperty.call(opts, 'empty_value') ? opts.empty_value : undefined;
  const unserializable = rawDefault === FN_SENTINEL;

  const spec = {
    optional: a.optional === true,
    defaultSource: a.default_source || (a.optional === true ? 'empty_value' : 'default'),
    hasDefault: !unserializable && rawDefault !== undefined,
    default: unserializable || rawDefault === undefined ? null : rawDefault,
    defaultUnserializable: unserializable,
    hasEmptyValue: rawEmpty !== undefined,
    emptyValue: rawEmpty === undefined ? null : rawEmpty,
    deep: null,
  };

  if (isPlainObject(a.deep) && Object.keys(a.deep).length > 0) {
    const deep = {};
    for (const f of Object.keys(a.deep)) {
      const d = a.deep[f];
      const fd = Object.prototype.hasOwnProperty.call(d, 'default') ? d.default : undefined;
      const funs = fd === FN_SENTINEL;
      deep[f] = {
        optional: d.optional === true,
        defaultSource: d.default_source || (d.optional === true ? 'empty_value' : 'default'),
        hasDefault: !funs && fd !== undefined,
        default: funs || fd === undefined ? null : fd,
        defaultUnserializable: funs,
        hasEmptyValue: false,
        emptyValue: null,
        deep: null,
      };
    }
    spec.deep = deep;
  }
  return { name, spec };
}

function attrsBlock(attrs) {
  const out = {};
  for (const k of Object.keys(attrs || {})) out[k] = attrSpec(k, attrs[k]).spec;
  return out;
}

/* --------------------------------------------------------------- assembly -- */

const raw = JSON.parse(fs.readFileSync(SCHEMA, 'utf8'));
const sha256 = crypto.createHash('sha256').update(fs.readFileSync(SCHEMA)).digest('hex');

const nodes = raw.nodes.map((n) => ({
  name: n.name,
  content: n.content === undefined || n.content === null ? null : n.content,
  groups: Array.isArray(n.groups) ? n.groups.slice() : [],
  isLeaf: n.isLeaf === true,
  isText: n.isText === true,
  emptyNodeSize: typeof n.empty_node_size === 'number' ? n.empty_node_size : null,
  attrs: attrsBlock(n.attrs),
}));

const marks = raw.marks.map((m) => ({
  name: m.name,
  rank: m.rank,
  isAttrMark: false,
  kind: m.kind || 'inline text mark',
  attrs: attrsBlock(m.attrs),
  applicableTo: (m.applicability && m.applicability.applicable_to_nodes) || null,
  applicabilitySource: (m.applicability && m.applicability.source) || null,
  applicabilityCaveat: (m.applicability && m.applicability.caveat) || null,
}));

const attrMarks = Object.keys(raw.attr_marks).map((k) => {
  const m = raw.attr_marks[k];
  return {
    name: m.name,
    rank: m.rank,
    isAttrMark: true,
    kind: 'block attr mark',
    attrs: attrsBlock(m.attrs),
    applicableTo: (m.applicability && m.applicability.applicable_to_nodes) || null,
    applicabilitySource: (m.applicability && m.applicability.source) || null,
    applicabilityCaveat: (m.applicability && m.applicability.caveat) || null,
  };
});

const groups = {};
for (const g of Object.keys(raw.groups)) groups[g] = raw.groups[g].slice();

const attrKeyOrder = {};
for (const n of raw.nodes) attrKeyOrder[n.name] = Object.keys(n.attrs || {});

const jsonKeyOrder = raw.serialization.json_key_order;

/* ------------------------------------------------------------------- emit -- */

const L = [];
L.push('// GENERATED FILE - DO NOT EDIT BY HAND.');
L.push('//');
L.push('// Source:   tool/office_collab_spike/schema/doc_schema.json');
L.push('// Generator: tool/office_collab_spike/schema/gen_dart_schema.js');
L.push('// Schema:   ' + raw.schema.name + ' v' + raw.schema.version + ' (' + raw.schema.topNode + ')');
L.push('//');
L.push('// Reproduce with:');
L.push('//   node tool/office_collab_spike/schema/gen_dart_schema.js');
L.push('//');
L.push('// `doc_schema.json` is itself the machine-readable export of the server package\'s');
L.push('// own ProseMirror schema (`server/common/prosemirror/index.js` :: schemaDocument.schema),');
L.push('// so these constants are the official schema - not an approximate rewrite.');
L.push('//');
L.push('// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables');
L.push('');
L.push("/// sha256 of the `doc_schema.json` this file was generated from.");
L.push('const String kDocSchemaSourceSha256 = ' + dartString(sha256) + ';');
L.push('');
L.push('/// Schema identity (matches the NAS `Info:get` `schema_doc` value).');
L.push('const String kDocSchemaName = ' + dartString(raw.schema.name) + ';');
L.push('const int kDocSchemaVersion = ' + raw.schema.version + ';');
L.push('const String kDocTopNodeName = ' + dartString(raw.schema.topNode) + ';');
L.push('const String kDocTopNodeContent = ' + dartString(raw.schema.topNode_content) + ';');
L.push('');
// The generated literals carry explicit `<String, Object?>` / `<Object?>`
// type arguments so that every nested container can be `as`-cast without
// tripping generic invariance on the Dart side.
L.push('/// Canonical key order of an element node object on the wire.');
L.push('const List<Object?> kDocJsonKeyOrder = ' + dartLiteral(jsonKeyOrder, 0) + ';');
L.push('');
L.push('/// Group name -> member node type names.');
L.push('const Map<String, Object?> kDocGroups = ' + dartLiteral(groups, 0) + ';');
L.push('');
L.push('/// Per-node declared attr key order (the order the editor emits them).');
L.push('const Map<String, Object?> kDocAttrKeyOrder = ' + dartLiteral(attrKeyOrder, 0) + ';');
L.push('');
L.push('/// Node specs, in schema declaration order.');
L.push('const List<Object?> kDocNodeSpecs = ' + dartLiteral(nodes, 0) + ';');
L.push('');
L.push('/// Inline text mark specs (rank = declaration order = priority).');
L.push('const List<Object?> kDocMarkSpecs = ' + dartLiteral(marks, 0) + ';');
L.push('');
L.push('/// Block `attr_mark` specs (registered separately from `schema.marks`).');
L.push('const List<Object?> kDocAttrMarkSpecs = ' + dartLiteral(attrMarks, 0) + ';');
L.push('');

const out = L.join('\n');
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, out);

const outSha = crypto.createHash('sha256').update(out).digest('hex');
console.log('schema  :', SCHEMA, sha256);
console.log('nodes   :', nodes.length, 'marks:', marks.length, 'attr_marks:', attrMarks.length);
console.log('wrote   :', OUT);
console.log('sha256  :', outSha);
