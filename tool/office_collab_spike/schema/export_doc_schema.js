#!/usr/bin/env node
/*
 * Offline exporter: Synology Office `.odoc` ProseMirror(-fork) schema.
 *
 * Reads ONLY the installed Office SPK package (read-only static analysis):
 *   /tmp/spk/export_Office/server/common/prosemirror/index.js
 * which is a CommonJS webpack bundle exporting the fork's schema objects
 * (`schemaDocument.schema` = wm instance, plus `transform`, `model`,
 *  `schemaComment`, `schemaTable`, ...).
 *
 * The `.node` native module is never loaded: a stub is installed so the
 * bundle can be `require`d purely offline.
 *
 * Usage:
 *   node tool/office_collab_spike/schema/export_doc_schema.js \
 *        [--spk /tmp/spk/export_Office] [--out tool/office_collab_spike/schema/doc_schema.json]
 *
 * No network, no build, no device.
 */
'use strict';

const Module = require('module');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

/* ---- 0. args ---------------------------------------------------------- */
const argv = process.argv.slice(2);
function arg(flag, dflt) {
  const i = argv.indexOf(flag);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
}
const SPK = arg('--spk', '/tmp/spk/export_Office');
const OUT = arg('--out', path.join(__dirname, 'doc_schema.json'));
const PM_BUNDLE = path.join(SPK, 'server/common/prosemirror/index.js');

/* ---- 1. load the fork bundle with a .node stub ------------------------ */
Module._extensions['.node'] = function (m) {
  m.exports = new Proxy(function () {}, { get: () => function () {} });
};

const src = fs.readFileSync(PM_BUNDLE);
const srcText = src.toString('utf8');
const srcSha256 = crypto.createHash('sha256').update(src).digest('hex');

const PM = require(PM_BUNDLE);
const schema = PM.schemaDocument.schema;

/* ---- 2. provenance helpers -------------------------------------------- */
// Locate a byte offset of a literal in the bundle; returns {offset, snippet}.
function locate(literal, from = 0) {
  const off = srcText.indexOf(literal, from);
  if (off < 0) return null;
  return {
    bundle: 'server/common/prosemirror/index.js',
    offset: off,
    snippet: srcText.slice(off, off + 160).replace(/\s+/g, ' '),
  };
}
// Locate `class <Name>` / `class <Name> extends` declaration start.
function locateClass(name) {
  const re = new RegExp('class ' + name + '(?:\\s|extends|\\{)');
  const m = re.exec(srcText);
  if (!m) return null;
  return {
    bundle: 'server/common/prosemirror/index.js',
    offset: m.index,
    snippet: srcText.slice(m.index, m.index + 160).replace(/\s+/g, ' '),
  };
}
// Extract the minified `type:` reference used by a spec node/mark entry.
function specTypeRef(specText, key) {
  const re = new RegExp('[,\\{]' + key.replace(/[$]/g, '\\$&') + ':\\{type:([A-Za-z_$][\\w$]*)');
  const m = re.exec(specText);
  return m ? m[1] : null;
}

/* ---- 3. schema spec blocks (raw text spans in the bundle) ------------- */
const BASIC_START = srcText.indexOf('let sf={name:"",version:0,nodes:{');
const DOC_MERGE_START = srcText.indexOf('wm.mergeSpec(sf,{name:"document"');
const DOC_MERGE_END = srcText.indexOf('JA=new wm($A)');
const PRES_MERGE_START = srcText.indexOf('wm.mergeSpec(sf,{name:"presentation"');

const specBlocks = {
  basic: {
    marker: 'let sf={name:"",version:0,nodes:{',
    bundle: 'server/common/prosemirror/index.js',
    offset: BASIC_START,
    snippet: srcText.slice(BASIC_START, BASIC_START + 200).replace(/\s+/g, ' '),
    what: 'base schema spec shared by document/sheet/presentation (`sf`)',
  },
  document: {
    marker: 'wm.mergeSpec(sf,{name:"document",...})',
    bundle: 'server/common/prosemirror/index.js',
    offset: DOC_MERGE_START,
    end: DOC_MERGE_END,
    snippet: srcText.slice(DOC_MERGE_START, DOC_MERGE_START + 200).replace(/\s+/g, ' '),
    what: 'document (`.odoc`) spec delta merged onto `sf`; `JA=new wm($A)` instantiates it',
  },
  presentation: {
    marker: 'wm.mergeSpec(sf,{name:"presentation",...})',
    bundle: 'server/common/prosemirror/index.js',
    offset: PRES_MERGE_START,
    snippet: srcText.slice(PRES_MERGE_START, PRES_MERGE_START + 200).replace(/\s+/g, ' '),
    what: 'presentation (`.oslides`) spec delta — existence proof only for section D',
  },
};
const docSpecText = srcText.slice(DOC_MERGE_START, DOC_MERGE_END);
const basicSpecText = srcText.slice(BASIC_START, BASIC_START + 2000);

/* ---- 4. serialisation ------------------------------------------------- */
function plain(v, depth = 0) {
  if (v === undefined) return null;
  if (v === null) return null;
  if (typeof v === 'function') return '<fn>';
  if (typeof v !== 'object') return v;
  if (depth > 6) return '<deep>';
  if (Array.isArray(v)) return v.map((x) => plain(x, depth + 1));
  const o = {};
  for (const k of Object.keys(v)) o[k] = plain(v[k], depth + 1);
  return o;
}

// Attribute descriptor -> serialisable record.
//
// The fork declares an attribute default in ONE of two places, and which one it
// is exactly predicts the serialisation behaviour observed on real hardware:
//   * `optional: true`  -> default is `empty_value`; the attr is OMITTED from
//                          `toJSON()` when it equals that value.
//   * `optional: false` -> default is `default`;     the attr is ALWAYS emitted
//                          by `toJSON()` (that is the Import -> fetch delta).
// Composite attrs additionally carry a `deep` map whose per-field defaults are
// independent of the parent's `empty_value`/`default`.
function attrField(a) {
  const hasEmpty = Object.prototype.hasOwnProperty.call(a, 'empty_value');
  const hasDefault = Object.prototype.hasOwnProperty.call(a, 'default');
  const optional = a.optional === undefined ? null : a.optional;
  let def = null;
  let defSource = 'unproven';
  if (optional === false && hasDefault) {
    def = a.default;
    defSource = 'default';
  } else if (optional === true && hasEmpty) {
    def = a.empty_value;
    defSource = 'empty_value';
  } else if (hasDefault) {
    def = a.default;
    defSource = 'default';
  } else if (hasEmpty) {
    def = a.empty_value;
    defSource = 'empty_value';
  }
  // Composite attr: the parent frequently has NO scalar default — the value is
  // assembled from the per-field `.default`s of `deep`. Compose it so the
  // exported record carries a usable default (this is exactly the
  // `doc.attrs.page_setup.orientation` case).
  if (a.deep && (def === null || def === undefined)) {
    const composed = {};
    for (const f of Object.keys(a.deep)) composed[f] = a.deep[f].default;
    def = composed;
    defSource = defSource === 'unproven' ? 'composed-from-deep' : defSource;
  }
  return {
    default: plain(def),
    default_source: defSource,
    serialization:
      optional === false
        ? 'always emitted by toJSON() (required attr)'
        : optional === true
          ? 'omitted by toJSON() when equal to empty_value (optional attr)'
          : 'unproven',
    optional,
    clearable: a.clearable === undefined ? null : a.clearable,
    settable: a.settable === undefined ? null : a.settable,
    copyable: a.copyable === undefined ? null : a.copyable,
    hidden: a.hidden === undefined ? null : a.hidden,
    backward: a.backward === undefined ? null : a.backward,
    options: plain(a.options),
    deep: a.deep
      ? Object.fromEntries(
          Object.keys(a.deep).map((f) => [
            f,
            {
              default: plain(a.deep[f].default),
              default_source: Object.prototype.hasOwnProperty.call(a.deep[f], 'default') ? 'default' : 'unproven',
              optional: a.deep[f].optional === undefined ? null : a.deep[f].optional,
              normalizer: plain(a.deep[f].options && a.deep[f].options.normalizer),
            },
          ]),
        )
      : null,
  };
}
function attrsOf(typeObj) {
  const attrs = (typeObj && typeObj.attrs) || {};
  const out = {};
  for (const name of Object.keys(attrs)) out[name] = attrField(attrs[name] || {});
  return out;
}


function groupsFor(name, groups) {
  const out = [];
  for (const g of Object.keys(groups || {})) {
    const list = groups[g];
    if (Array.isArray(list) && list.includes(name)) out.push(g);
  }
  return out;
}

/* ---- 5. NODES --------------------------------------------------------- */
const rawSpec = schema.rawSpec; // {name, version, nodes, groups, marks, attr_marks, parsers, preset, getInitialSelection}
const groups = rawSpec.groups || {};

const nodes = [];
for (const name of Object.keys(schema.nodes)) {
  const node = schema.nodes[name];
  const type = node.type;
  const specEntry = (rawSpec.nodes || {})[name] || {};
  const typeRef = specTypeRef(docSpecText, name) || specTypeRef(basicSpecText, name);
  const isText = !!type.isText;
  const isLeaf = !!type.isLeaf;

  // empty node size (text cannot be empty -> recorded as a rule)
  let emptyNodeSize = null;
  let nodeSizeErr = null;
  if (!isText) {
    try {
      emptyNodeSize = type.create(null, null, null).nodeSize;
    } catch (e) {
      nodeSizeErr = String(e.message || e);
    }
  }

  const prov = [];
  if (specTypeRef(docSpecText, name)) {
    const dm = docSpecText.match(new RegExp('[,\\{]' + name + ':\\{type:[A-Za-z_$][\\w$]*[^}]*\\}'));
    prov.push({
      source: 'SPK-JS 原文',
      bundle: 'server/common/prosemirror/index.js',
      offset: DOC_MERGE_START + (dm ? dm.index : 0),
      snippet: dm ? dm[0] : null,
      what: 'node entry in the document spec delta (content expression / type class)',
    });
  } else if (specTypeRef(basicSpecText, name)) {
    const m = basicSpecText.match(new RegExp('[,\\{]' + name + ':\\{type:[A-Za-z_$][\\w$]*[^}]*\\}'));
    prov.push({
      source: 'SPK-JS 原文',
      bundle: 'server/common/prosemirror/index.js',
      offset: BASIC_START + (m ? m.index : 0),
      snippet: m ? m[0] : null,
      what: 'node entry inherited from the shared base spec `sf`',
    });
  } else {
    prov.push({
      source: '推断',
      what: 'node exists in the resolved schema but no literal spec entry was located; resolved via merge/preset',
      disproof: 'find a literal `' + name + ':{type:` entry in any spec block of the bundle',
    });
  }
  // class definition (attrs live on the node class)
  if (typeRef) {
    const cl = locateClass(typeRef);
    if (cl) {
      prov.push({
        source: 'SPK 束内模块',
        bundle: 'server/common/prosemirror/index.js',
        offset: cl.offset,
        snippet: cl.snippet,
        what: 'node class `' + typeRef + '` — where `attrs` (with empty_value defaults) are declared/composed',
      });
    }
  }

  const attrRec = attrsOf(node);
  const provenAttrs = Object.values(attrRec).filter((a) => a.default_source !== 'unproven').length;

  nodes.push({
    name,
    content: specEntry.content === undefined ? null : specEntry.content,
    content_source: specEntry.content === undefined ? 'implicit (no content expression)' : 'SPK-JS 原文',
    groups: groupsFor(name, groups),
    group_runtime: Array.isArray(node.group) ? node.group.slice() : null,
    isLeaf,
    isText,
    empty_node_size: emptyNodeSize,
    empty_node_size_error: nodeSizeErr,
    attrs: attrRec,
    attr_count: Object.keys(attrRec).length,
    attrs_with_proven_default: provenAttrs,
    marks_attrs: plain(node.marksAttrs),
    default_marks_attrs: plain(node.defaultMarksAttrs),
    // css attrs are what `getBlockMarks()` turns into `text_align` / `line_height`
    // attr-marks — decisive for block-mark applicability (bundle offset 1460457).
    css_attrs: node.cssAttrs ? plain(node.cssAttrs) : null,
    default_css_attrs: node.defaultCssAttrs ? plain(node.defaultCssAttrs) : null,
    provenance: prov,
  });
}

/* ---- 5b. mark applicability ------------------------------------------- */
// Inline text marks: this fork's MarkType carries NO per-node allow-list
// (no `excludes` / `marks` field — see marks[*].provenance offsets); marks
// attach to `text` nodes inside any textblock whose content expression
// includes the `inline` group.
const textblockNodes = nodes
  .filter((n) => typeof n.content === 'string' && /(^|\s)inline</.test(n.content))
  .map((n) => n.name)
  .sort();
// Block (attr) marks: `getBlockMarks()` (bundle offset ~1460457) builds a mark
// set from `attrMarkType("text_align")` + `attrMarkType("line_height")` using the
// node's cssAttrs. So these two apply exactly to nodes declaring those cssAttrs.
const cssAttrMarkOwner = {
  text_align: nodes.filter((n) => n.css_attrs && 'textAlign' in n.css_attrs).map((n) => n.name).sort(),
  line_height: nodes.filter((n) => n.css_attrs && 'lineHeight' in n.css_attrs).map((n) => n.name).sort(),
};
const ATTR_MARK_SITES = {
  text_align: locate('attrMarkType("text_align")'),
  line_height: locate('attrMarkType("line_height")'),
  direction: locate('attrMarkType("direction")'),
  text_indent: locate('attrMarkType("text_indent")'),
};
function applicability(markName, isAttrMark) {
  if (!isAttrMark) {
    return {
      applicable_to_nodes: textblockNodes,
      via: 'text nodes inside a textblock whose content expression matches `inline<…>`',
      source: 'SPK 束内模块',
      caveat:
        'the fork MarkType exports no per-node allow-list (checked own properties of every mark type: no `excludes`/`marks`); no schema-level restriction was found',
      disproof: 'find an `excludes`/`marks`/`allowedNodes` field on any MarkType in the bundle',
    };
  }
  const site = ATTR_MARK_SITES[markName];
  if (site && cssAttrMarkOwner[markName]) {
    return {
      applicable_to_nodes: cssAttrMarkOwner[markName],
      via: `getBlockMarks() -> attrMarkType("${markName}") over the node's cssAttrs`,
      source: 'SPK-JS 原文',
      site,
    };
  }
  return {
    applicable_to_nodes: null,
    via: 'none found',
    source: 'unproven',
    caveat:
      `attr mark \`${markName}\` is registered in the base spec but no attrMarkType("${markName}") call site exists in server/common/prosemirror/index.js`,
    disproof:
      `find a usage site for "${markName}" (likely in ui/dist/*.js DOM renderer, or in a .so); until then its applicable node set is unproven, not guessed`,
  };
}

/* ---- 6. MARKS --------------------------------------------------------- */
// NOTE: the fork keeps *block/attr* marks in a SEPARATE registry
// (`schema.attr_marks`), not in `schema.marks`. They are therefore not
// reported in the `marks` array below; see `attr_marks_detail`.
const attrMarks = {};
for (const k of Object.keys(schema.attr_marks || {})) {
  const m = schema.attr_marks[k];
  attrMarks[k] = {
    name: m.name,
    rank: m.rank,
    class: m.constructor ? m.constructor.name : null,
    attrs: attrsOf(m.type || m),
    applicability: applicability(k, true),
    provenance: [locateClass(m.constructor ? m.constructor.name : '')].filter(Boolean),
  };
}

const marks = [];
for (const name of Object.keys(schema.marks)) {
  const mark = schema.marks[name];
  const type = mark.type;
  const prov = [];
  const basicM = basicSpecText.match(new RegExp('\\["' + name + '",([A-Za-z_$][\\w$]*)\\]'));
  if (basicM) {
    const cl = locateClass(basicM[1]);
    prov.push({
      source: 'SPK-JS 原文',
      bundle: 'server/common/prosemirror/index.js',
      offset: BASIC_START + basicM.index,
      snippet: basicM[0],
      what: 'mark registration `["' + name + '", <class>]` in base spec `sf` (order = priority)',
    });
    if (cl) {
      prov.push({
        source: 'SPK 束内模块',
        bundle: 'server/common/prosemirror/index.js',
        offset: cl.offset,
        snippet: cl.snippet,
        what: 'mark class `' + basicM[1] + '` — attrs with empty_value defaults',
      });
    }
  } else if (name === 'tracking') {
    const site = locate('schema.mark("tracking"');
    prov.push({
      source: 'SPK-JS 原文',
      bundle: 'server/common/prosemirror/index.js',
      offset: site ? site.offset : null,
      snippet: site ? site.snippet : null,
      what:
        '`tracking` is NOT in the base spec `sf`; it is registered by the comment schema (schemaComment) — `createTrackingMark(){ return schema.mark("tracking",{id}) }`',
    });
    const norm = locate('let t=["link","tracking"]');
    if (norm) {
      prov.push({
        source: 'SPK-JS 原文',
        bundle: 'server/common/prosemirror/index.js',
        offset: norm.offset,
        snippet: norm.snippet,
        what:
          'marks normalizer excludes `link` and `tracking` from the block `textMarks` attr — i.e. these two are not persisted via `textMarks`',
      });
    }
  } else {
    prov.push({
      source: '推断',
      what: 'mark present in resolved schema but not in the base spec literal',
      disproof: 'locate the mark class + registration in the bundle',
    });
  }
  const inAttrMarks = Object.prototype.hasOwnProperty.call(schema.attr_marks || {}, name);
  marks.push({
    name,
    rank: typeof mark.rank === 'number' ? mark.rank : null,
    is_attr_mark: inAttrMarks,
    kind: inAttrMarks ? 'block/attr mark' : 'inline text mark',
    attrs: attrsOf(type),
    attr_count: Object.keys(attrsOf(type)).length,
    default_mark: type.defaultMark === undefined ? null : plain(type.defaultMark),
    preset_mark: type.presetMark === undefined ? null : plain(type.presetMark),
    applicability: applicability(name, inAttrMarks),
    provenance: prov,
  });
}

/* ---- 7. computed isLeaf / nodeSize rule table ------------------------- */
const leafNodes = nodes.filter((n) => n.isLeaf && !n.isText).map((n) => n.name).sort();
const textNodes = nodes.filter((n) => n.isText).map((n) => n.name).sort();
const containerNodes = nodes.filter((n) => !n.isLeaf).map((n) => n.name).sort();

/* ---- 8. normalisation (Import-state -> fetch-state) ------------------- */
// Derived from the schema's own attr declaration, then cross-checked against
// the real-hardware delta (docs/office-collab-protocol-spike.md §3:
// Import content.data vs editor fetch doc.data = 36 raw diffs -> 3 normalised).
//
// Decisive rule discovered by re-loading the bundle (see report):
//   optional:true  -> default in `empty_value`; toJSON() OMITS it when unset
//   optional:false -> default in `default`;     toJSON() ALWAYS emits it
// The 3 residual Import-vs-fetch differences are exactly the required-attrs
// cases: `doc.attrs.page_setup` (deep, required), `page_decorate` place-*/num-*
// (required), `header|footer.type` (required).
const requiredAttrDefaults = [];
for (const n of nodes) {
  for (const [k, a] of Object.entries(n.attrs)) {
    if (a.optional === false) {
      requiredAttrDefaults.push({ node: n.name, attr: k, default: a.default, default_source: a.default_source });
    }
    if (a.deep) {
      for (const [f, d] of Object.entries(a.deep)) {
        if (d.optional === false) {
          requiredAttrDefaults.push({
            node: n.name,
            attr: k + '.' + f,
            default: d.default,
            default_source: d.default_source,
          });
        }
      }
    }
  }
}
const docNodeRec = nodes.find((n) => n.name === 'doc');
const pageDecorateRec = nodes.find((n) => n.name === 'page_decorate');
const psDefault =
  docNodeRec && docNodeRec.attrs.page_setup ? docNodeRec.attrs.page_setup.default : null;

const normalization = {
  evidence:
    '既有真机帧 (docs/office-collab-protocol-spike.md §3: Import content.data vs editor fetch doc.data, 36 raw diffs -> 3 normalised) + SPK 束内模块 (schema round-trip is byte-exact, see normalization_verification.json)',
  direction:
    'Office.Import (OOXML -> .odoc) omits attributes that equal the schema default; the editor toJSON() always emits REQUIRED attrs and omits OPTIONAL attrs equal to their empty_value. Canonicalise by applying the schema rule below, not by guessing.',
  rules: [
    {
      id: 'R1-required-attr-fill',
      applies_to: 'every node attr declared with `optional:false` (default in `.default`)',
      rule:
        'if the attr (or a composite sub-field) is absent, insert its `.default`; these attrs are ALWAYS present in the editor fetch JSON',
      status: 'schema-backed (SPK 束内模块) — proven by byte-exact round-trip',
      examples: [
        { path: 'doc.attrs.page_setup.orientation', import_state: 'absent', fetch_state: '"portrait"', schema_default: psDefault && psDefault.orientation },
        { path: 'doc.attrs.page_setup.page_type', import_state: 'absent', fetch_state: 'truthy (e.g. "letter"/"a4")', schema_default: psDefault && psDefault.page_type },
        ...(pageDecorateRec
          ? Object.entries(pageDecorateRec.attrs).map(([k, a]) => ({
              path: 'page_decorate.attrs.' + k,
              import_state: 'absent',
              fetch_state: JSON.stringify(a.default),
              schema_default: a.default,
            }))
          : []),
      ],
    },
    {
      id: 'R2-optional-attr-omission',
      applies_to: 'every node attr declared with `optional:true` (default in `.empty_value`)',
      rule:
        'do NOT insert these when absent; and when comparing against editor output, drop them if they equal `empty_value`. Inserting them (as a naive "fill all defaults" pass does) CREATES diffs instead of removing them.',
      status: 'schema-backed (SPK 束内模块) — the naive fill-all-defaults variant produced 105 diffs, see normalization_verification.json',
    },
    {
      id: 'R3-empty-attrs-content-omission',
      applies_to: 'every node',
      rule:
        'Import emits `attrs:{}` / `content:[]` explicitly; the editor omits them. Drop `attrs` when it ends up empty and `content` when it is [].',
      status: '既有真机帧 + schema-backed',
    },
    {
      id: 'R4-comment-section-format',
      applies_to: '`@C_text/comment` BSON section (not part of the doc JSON)',
      rule: 'Import writes `{"data":[],"format":1}`; the editor snapshot writes `{"data":[]}` (runner.js omits `format`).',
      status: '既有真机帧 (docs/office-collab-protocol-spike.md §3 note)',
    },
  ],
  required_attr_defaults: requiredAttrDefaults,
  required_attr_default_count: requiredAttrDefaults.length,
  canonicalisation_algorithm: [
    '1. parse the doc JSON (from BSON @C_text/content.data or from the `fetch` ack)',
    '2. for every node, look up its node type in doc_schema.json',
    '3. for each attr (and composite `deep` sub-field) with optional:false, if absent set it to `.default`',
    '4. drop attrs whose optional:true value equals `empty_value`; drop `attrs` if it becomes empty',
    '5. drop `content` when it is an empty array',
    '6. serialise with sorted keys + no whitespace, then sha256',
    'NOTE: the strongest correctness check is not this algorithm but `schema.nodeFromJSON(x).toJSON()` — that is byte-exact (see normalization_verification.json)',
  ],
  minimal_verification: {
    tool: 'tool/office_collab_spike/schema/verify_doc_normalization.js',
    command:
      'node tool/office_collab_spike/schema/verify_doc_normalization.js --evid /tmp/office-collab-spike/evid',
    inputs: [
      '/tmp/office-collab-spike/evid/snapshot_doc_pre.json :: content.data  (Import state, BSON)',
      '/tmp/office-collab-spike/evid/dart_fetched_doc_v1.json              (editor fetch of the same doc)',
    ],
    manual_cross_check:
      'open the two JSON files side by side at `$.content[0].attrs` and `$.attrs.page_setup`: the Import copy has `{}` / no `orientation`, the fetch copy has all six page_setup fields including `"orientation":"portrait"`.',
    expected: {
      raw_diff_count: 36,
      schema_round_trip_diff_count: 0,
      save_materialised_diff_count: 0,
    },
  },
};

/* ---- 9. assemble ------------------------------------------------------ */
const out = {
  $schema_note:
    'Machine-readable export of the `.odoc` ProseMirror-fork schema as implemented by Synology Office (SPK 3.8.0-22711). Generated offline from the installed package only.',
  generated_by: 'tool/office_collab_spike/schema/export_doc_schema.js',
  generated_at: new Date().toISOString(),
  source: {
    package: 'Synology Office SPK 3.8.0-22711 (x86_64)',
    export_dir: SPK,
    bundle: 'server/common/prosemirror/index.js',
    bundle_bytes: src.length,
    bundle_sha256: srcSha256,
    bundle_format: 'single-line webpack CommonJS bundle',
    load_method: 'require() with Module._extensions[".node"] stubbed (no native module, no network)',
    exports: Object.keys(PM),
  },
  schema: {
    name: rawSpec.name,
    version: rawSpec.version,
    topNode: 'doc',
    topNode_content: (rawSpec.nodes || {}).doc ? rawSpec.nodes.doc.content : null,
    node_count: nodes.length,
    mark_count: marks.length,
    attr_mark_count: Object.keys(attrMarks).length,
    nodeSize_rule: {
      text: 'text node -> its string length',
      leaf: 'isLeaf && !isText -> 1',
      container: 'otherwise -> sum(children) + 2',
      note: 'differs from standard ProseMirror only in that `settings` has no content expression yet isLeaf=true and still occupies 1 position',
    },
  },
  groups,
  serialization: {
    json_key_order: ['type', 'attrs', 'content', 'marks'],
    note:
      'key order inside a node object is `type, attrs, content, marks` in both the Import JSON and the editor toJSON() (verified by inspecting the real-hardware evidence files); canonical comparison should sort keys anyway',
    mark_order: marks.map((m) => ({ name: m.name, rank: m.rank })).sort((a, b) => a.rank - b.rank),
    mark_order_note:
      '`schema.marks` is compiled in declaration order; `rank` is the assigned priority (font_size=0 … strike=10, comment tracking=11). Both the Import JSON and the editor JSON list the em/strong marks of the sample doc in this rank order.',
    node_declaration_order: Object.keys(schema.nodes),
    node_declaration_order_note:
      'the order in which the spec declares node types; it is NOT the document child order (which is pinned by content expressions) and carries no wire meaning by itself',
    attr_key_order: Object.fromEntries(
      nodes.map((n) => [n.name, Object.keys(n.attrs)]),
    ),
    attr_key_order_note:
      'attr key order as resolved by the schema; the editor emits attrs in this order, Import may differ -> compare canonicalised (sorted-key) JSON',
  },
  attr_marks: attrMarks,
  nodes,
  marks,
  node_size_classes: {
    leaf_size_1: leafNodes,
    text: textNodes,
    containers_size_sum_plus_2: containerNodes,
  },
  node_size_exceptions: [
    {
      node: 'text',
      note: 'isLeaf=true and isText=true; nodeSize = string length; an empty text node is rejected by the model ("Empty text nodes are not allowed")',
      source: 'SPK 束内模块',
    },
    {
      node: 'page',
      note:
        'empty-node construction throws "No value in attribute." — `page` declares required attrs (width/height/margins) with no empty_value, so it cannot be instantiated without attrs',
      source: 'SPK 束内模块 (reproduced in /tmp/office-collab-spike/evid/schema_table.json)',
    },
    {
      node: 'settings',
      note:
        'no content expression (isLeaf=true) yet occupies 1 position; standard ProseMirror reasoning would mis-position edits that follow it',
      source: '既有真机帧 + SPK 束内模块 (docs/office-collab-protocol-spike.md §2.4)',
    },
  ],
  marks_applicability: {
    inline_text_marks: marks.filter((m) => !m.is_attr_mark).map((m) => m.name),
    inline_text_marks_applicable_to: textblockNodes,
    block_attr_marks: marks.filter((m) => m.is_attr_mark).map((m) => m.name),
    block_attr_mark_owners: cssAttrMarkOwner,
    attr_mark_call_sites: ATTR_MARK_SITES,
  },
  normalization,
  evidence_grades: {
    'SPK-JS 原文': 'literal text in a plain .js file inside the package (server/common/prosemirror/index.js)',
    'SPK 束内模块': 'value obtained by loading the package bundle in node and reading the live object',
    'SPK-.so strings': 'string extracted from a native .so',
    '既有真机帧': 'frame captured from the real NAS by the previous batch (/tmp/office-collab-spike/evid)',
    推断: 'inference; each such entry carries a `disproof` field stating what evidence would overturn it',
  },
  provenance_spec_blocks: specBlocks,
};

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
process.stderr.write(
  `wrote ${OUT}\n  nodes=${nodes.length} marks=${marks.length} attr_marks=${Object.keys(attrMarks).length}\n` +
    `  bundle sha256=${srcSha256.slice(0, 16)}…\n`,
);
