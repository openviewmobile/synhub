#!/usr/bin/env node
/*
 * Offline exporter: Synology Office `.oslides` presentation model + step vocabulary.
 *
 * Reads ONLY local, already-extracted artifacts (read-only static analysis):
 *   <SPK>/server/common/prosemirror/index.js          authoritative schema bundle
 *   <SPK>/template/slides/<theme>/text.json           official theme samples (optional)
 *   <FRAMES>/snap_probe_*.oslides.json                real-device Snapshot:get v4 (optional)
 *
 * The `.oslides` document model is the SAME ProseMirror fork as `.odoc` but the
 * `schemaPresentation` instance (78 nodes / 12 marks / 4 attr_marks, version 13).
 * There is NO `cmd:"…"` vocabulary for presentations: edits travel as ProseMirror
 * **steps**, so the analogue of `sheet_commands.json` is the step-type registry
 * (`jsonID("<name>", <Class>)`) plus the dispatcher (`Step.stepClass`).
 *
 * Usage:
 *   node tool/office_collab_spike/schema/export_slides_schema.js \
 *        [--spk /tmp/spk/export_Office] \
 *        [--frames /tmp/office_probe_evid] \
 *        [--out tool/office_collab_spike/schema/slides_schema.json]
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
const FRAMES = arg('--frames', '/tmp/office_probe_evid');
const OUT = arg('--out', path.join(__dirname, 'slides_schema.json'));
const PM_BUNDLE = path.join(SPK, 'server/common/prosemirror/index.js');

/* ---- 1. load the fork bundle with a .node stub ------------------------ */
Module._extensions['.node'] = function (m) {
  m.exports = new Proxy(function () {}, { get: () => function () {} });
};
const src = fs.readFileSync(PM_BUNDLE);
const srcText = src.toString('utf8');
const srcSha256 = crypto.createHash('sha256').update(src).digest('hex');

const PM = require(PM_BUNDLE);
const schema = PM.schemaPresentation.schema;
const rawSpec = schema.rawSpec;

/* ---- 2. provenance helpers -------------------------------------------- */
function locate(literal, from = 0) {
  const off = srcText.indexOf(literal, from);
  if (off < 0) return null;
  return {
    bundle: 'server/common/prosemirror/index.js',
    offset: off,
    snippet: srcText.slice(off, off + 160).replace(/\s+/g, ' '),
  };
}
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
function specTypeRef(specText, key) {
  const re = new RegExp('[,\\{]' + key.replace(/[$]/g, '\\$&') + ':\\{type:([A-Za-z_$][\\w$]*)');
  const m = re.exec(specText);
  return m ? m[1] : null;
}
function plain(v, depth = 0) {
  if (v === undefined || v === null) return null;
  if (typeof v === 'function') return '<fn>';
  if (typeof v !== 'object') return v;
  if (depth > 6) return '<deep>';
  if (Array.isArray(v)) return v.map((x) => plain(x, depth + 1));
  const o = {};
  for (const k of Object.keys(v)) o[k] = plain(v[k], depth + 1);
  return o;
}
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
  if (a.deep && (def === null || def === undefined)) {
    const composed = {};
    for (const f of Object.keys(a.deep)) composed[f] = a.deep[f].default;
    def = composed;
    defSource = defSource === 'unproven' ? 'composed-from-deep' : defSource;
  }
  return {
    default: plain(def),
    default_source: defSource,
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
              default_source: Object.prototype.hasOwnProperty.call(a.deep[f], 'default')
                ? 'default'
                : 'unproven',
              optional: a.deep[f].optional === undefined ? null : a.deep[f].optional,
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

/* ---- 3. presentation spec block --------------------------------------- */
const BASIC_START = srcText.indexOf('let sf={name:"",version:0,nodes:{');
const PRES_START = srcText.indexOf('wm.mergeSpec(sf,{name:"presentation"');
const PRES_DOC = srcText.indexOf('doc:{', PRES_START);
// end of the presentation merge object: first `})` after the merge start
const PRES_END = srcText.indexOf('})', PRES_START);
const presSpecText = srcText.slice(PRES_START, PRES_END > PRES_START ? PRES_END + 2 : PRES_START + 4000);
const basicSpecText = srcText.slice(BASIC_START, BASIC_START + 2000);

/* ---- 4. nodes --------------------------------------------------------- */
const groups = rawSpec.groups || {};
const nodes = [];
for (const name of Object.keys(schema.nodes)) {
  const node = schema.nodes[name];
  const type = node.type;
  const specEntry = (rawSpec.nodes || {})[name] || {};
  const inPres = specTypeRef(presSpecText, name);
  const inBasic = specTypeRef(basicSpecText, name);
  const typeRef = inPres || inBasic;
  const isText = !!type.isText;
  const isLeaf = !!type.isLeaf;
  const content = specEntry.content === undefined ? null : specEntry.content;

  const prov = [];
  if (inPres) {
    const m = presSpecText.match(new RegExp('[,\\{]' + name + ':\\{type:[A-Za-z_$][\\w$]*[^}]*\\}'));
    prov.push({
      source: 'SPK-JS 原文',
      bundle: 'server/common/prosemirror/index.js',
      offset: PRES_START + (m ? m.index : 0),
      snippet: m ? m[0] : null,
      what: 'node entry in the presentation spec delta',
    });
  } else if (inBasic) {
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
      what: 'node resolved by merge/preset but no literal spec entry located',
      disproof: 'find a literal `' + name + ':{type:` entry in any spec block',
    });
  }
  if (typeRef) {
    const cl = locateClass(typeRef);
    if (cl) prov.push({ source: 'SPK 束内模块', ...cl, what: 'node class `' + typeRef + '`' });
  }

  nodes.push({
    name,
    content,
    content_source: specEntry.content === undefined ? 'implicit (no content expression)' : 'SPK-JS 原文',
    groups: groupsFor(name, groups),
    isLeaf,
    isText,
    attrs: attrsOf(node),
    attr_keys: Object.keys(attrsOf(node)),
    provenance: prov,
  });
}

/* ---- 5. marks / attr_marks -------------------------------------------- */
const attrMarks = {};
for (const k of Object.keys(schema.attr_marks || {})) {
  const m = schema.attr_marks[k];
  attrMarks[k] = {
    name: m.name,
    rank: m.rank,
    is_attr_mark: true,
    attrs: attrsOf(m.type || m),
    attr_keys: Object.keys(attrsOf(m.type || m)),
    provenance: [locateClass(m.constructor ? m.constructor.name : '')].filter(Boolean),
  };
}
const marks = [];
for (const name of Object.keys(schema.marks)) {
  const mark = schema.marks[name];
  const prov = [];
  const basicM = basicSpecText.match(new RegExp('\\["' + name + '",([A-Za-z_$][\\w$]*)\\]'));
  if (basicM) {
    prov.push({
      source: 'SPK-JS 原文',
      bundle: 'server/common/prosemirror/index.js',
      offset: BASIC_START + basicM.index,
      snippet: basicM[0],
      what: 'mark registration in base spec `sf`',
    });
    const cl = locateClass(basicM[1]);
    if (cl) prov.push({ source: 'SPK 束内模块', ...cl, what: 'mark class `' + basicM[1] + '`' });
  } else if (name === 'tracking') {
    const site = locate('schema.mark("tracking"');
    prov.push({
      source: 'SPK-JS 原文',
      offset: site ? site.offset : null,
      snippet: site ? site.snippet : null,
      what: 'registered by schemaComment, not by the base spec',
    });
  } else {
    prov.push({
      source: '推断',
      what: 'mark present in resolved schema but not in the base spec literal',
      disproof: 'locate the mark class + registration in the bundle',
    });
  }
  const inAttr = Object.prototype.hasOwnProperty.call(schema.attr_marks || {}, name);
  const t = mark.type;
  marks.push({
    name,
    rank: typeof mark.rank === 'number' ? mark.rank : null,
    is_attr_mark: inAttr,
    attrs: attrsOf(t),
    attr_keys: Object.keys(attrsOf(t)),
    provenance: prov,
  });
}

/* ---- 6. step vocabulary (the `.oslides` "command" analogue) ----------- */
const steps = [];
const stepSeen = new Set();
for (const m of srcText.matchAll(/jsonID\("([^"]+)"/g)) {
  if (stepSeen.has(m[1])) continue;
  stepSeen.add(m[1]);
  steps.push({ name: m[1], offset: m.index, registration: 'cc.jsonID("<name>", <Class>)' });
}
// `DC(<Class>,"<name>",<invertClass>?)` is a wrapper that calls `cc.jsonID(<name>, <Class>)`.
for (const m of srcText.matchAll(/DC\(([A-Za-z_$][\w$]*),\s*"([^"]+)"/g)) {
  if (stepSeen.has(m[2])) continue;
  stepSeen.add(m[2]);
  steps.push({ name: m[2], offset: m.index, registration: 'DC(<Class>,"<name>",…) -> cc.jsonID("<name>", <Class>)' });
}
steps.sort((a, b) => a.offset - b.offset);
const stepRegistryFns = {
  register: locate('static register(t,e=this)'),
  jsonID: locate('static jsonID(t,e)'),
  stepClass: locate('static stepClass(t)'),
  normalizeStepId: locate('static normalizeStepId(t)'),
  fromJSONDispatch: locate('s(e.stepType).fromJSON(t,e)'),
};
const stepContract = {
  registry: 'a module-level map `uc` keyed by the JSON id; `register()` throws on duplicates',
  dispatcher: 'Step.stepClass(name) -> class; Step.fromJSON dispatches via `stepClass(e.stepType).fromJSON(t,e)`',
  serialize: 'step.toJSON() emits `{stepType:<jsonID>, …}`; `normalizeStepId` strips a trailing `V<digits>`',
  names_with_v_suffix: steps.map((s) => s.name).filter((n) => /V\d+$/.test(n)),
  registration_forms: [...new Set(steps.map((s) => s.registration))],
};

/* ---- 7. observed evidence (optional, external artifacts) -------------- */
function mineContentKeys(content, obs) {
  if (!content || typeof content !== 'object') return;
  for (const k of Object.keys(content)) obs.content_keys.set(k, (obs.content_keys.get(k) || 0) + 1);
  const data = content.data;
  if (!data || typeof data !== 'object') return;
  for (const k of Object.keys(data)) obs.content_data_keys.set(k, (obs.content_data_keys.get(k) || 0) + 1);
  const attrs = data.attrs;
  if (attrs && typeof attrs === 'object') {
    for (const k of Object.keys(attrs)) obs.root_attr_keys.set(k, (obs.root_attr_keys.get(k) || 0) + 1);
  }
}

function collectObserved(root) {
  const obs = {
    node_types: new Map(),
    marks: new Map(),
    attr_keys: new Map(),
    section_keys: new Map(),
    snapshot_data_keys: new Map(),
    content_keys: new Map(),
    content_data_keys: new Map(),
    root_attr_keys: new Map(),
    sources: [],
    slide_counts: [],
  };
  function walk(n, source) {
    if (Array.isArray(n)) {
      for (const x of n) walk(x, source);
      return;
    }
    if (n && typeof n === 'object') {
      if (typeof n.type === 'string') {
        obs.node_types.set(n.type, (obs.node_types.get(n.type) || 0) + 1);
        if (n.attrs && typeof n.attrs === 'object' && !Array.isArray(n.attrs)) {
          let st = obs.attr_keys.get(n.type);
          if (!st) {
            st = new Map();
            obs.attr_keys.set(n.type, st);
          }
          for (const k of Object.keys(n.attrs)) st.set(k, (st.get(k) || 0) + 1);
        }
        if (Array.isArray(n.marks)) {
          for (const mk of n.marks) {
            const name = mk && (mk._ || mk.type);
            if (name) obs.marks.set(name, (obs.marks.get(name) || 0) + 1);
          }
        }
      }
      walk(n.content, source);
    }
  }
  const tdir = path.join(SPK, 'template/slides');
  if (fs.existsSync(tdir)) {
    const names = fs.readdirSync(tdir).filter((d) => fs.existsSync(path.join(tdir, d, 'text.json')));
    for (const d of names.sort()) {
      const j = JSON.parse(fs.readFileSync(path.join(tdir, d, 'text.json'), 'utf8'));
      obs.sources.push({ kind: 'official-theme-template', ref: 'template/slides/' + d + '/text.json', sha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(tdir, d, 'text.json'))).digest('hex') });
      for (const k of Object.keys(j)) obs.section_keys.set(k, (obs.section_keys.get(k) || 0) + 1);
      mineContentKeys(j.content, obs);
      walk(j.content && j.content.data && j.content.data.content, 'template');
      const sc = j.content && j.content.data && j.content.data.content;
      const slides = Array.isArray(sc) ? (sc.find((x) => x && x.type === 'slide_container') || {}).content : null;
      obs.slide_counts.push({ ref: d, slides: Array.isArray(slides) ? slides.length : null });
    }
  }
  if (fs.existsSync(root)) {
    for (const f of fs.readdirSync(root).filter((f) => /oslides.*\.json$/i.test(f)).sort()) {
      let j;
      try {
        j = JSON.parse(fs.readFileSync(path.join(root, f), 'utf8'));
      } catch (e) {
        continue;
      }
      const data = j && j.get && j.get.data;
      if (!data) continue;
      const content = data.content;
      const doc = content && content.data;
      if (!doc || !Array.isArray(doc.content)) continue;
      obs.sources.push({ kind: 'real-device-snapshot-get', ref: path.join(root, f), offset: 'get.data.content.data.content' });
      // Envelope metadata is NOT a section; only @C_text/*-shaped members are.
      for (const k of Object.keys(data)) obs.snapshot_data_keys.set(k, (obs.snapshot_data_keys.get(k) || 0) + 1);
      for (const k of ['content', 'comment', 'file']) {
        if (data[k] !== undefined) obs.section_keys.set(k, (obs.section_keys.get(k) || 0) + 1);
      }
      if (content && content.version !== undefined) {
        obs.snapshot_data_keys.set('content.version', (obs.snapshot_data_keys.get('content.version') || 0) + 1);
      }
      mineContentKeys(content, obs);
      obs.slide_counts.push({
        ref: f,
        attrs: doc.attrs,
        ntype: data.ntype,
        object_id: data.object_id,
        root_content_types: doc.content.filter((x) => x && x.type).map((x) => x.type),
        version: content.version,
      });
      walk(doc.content, 'frame');
    }
  }
  if (obs.sources.length === 0) return null;
  const toObj = (m) => Object.fromEntries([...m.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1)));
  return {
    sources: obs.sources,
    slide_counts: obs.slide_counts,
    node_types: toObj(obs.node_types),
    marks: toObj(obs.marks),
    attr_keys: toObj(new Map([...obs.attr_keys.entries()].map(([k, v]) => [k, toObj(v)]))),
    section_keys: toObj(obs.section_keys),
    snapshot_data_keys: toObj(obs.snapshot_data_keys),
    content_keys: toObj(obs.content_keys),
    content_data_keys: toObj(obs.content_data_keys),
    root_attr_keys: toObj(obs.root_attr_keys),
    node_types_not_in_schema: Object.keys(toObj(obs.node_types)).filter((n) => !schema.nodes[n]),
    marks_not_in_schema: Object.keys(toObj(obs.marks)).filter(
      (n) => !schema.marks[n] && !(schema.attr_marks || {})[n],
    ),
    attr_keys_not_declared: (() => {
      const bad = [];
      for (const [t, keys] of obs.attr_keys) {
        const decl = nodes.find((n) => n.name === t);
        for (const k of keys.keys()) if (!decl || !decl.attr_keys.includes(k)) bad.push(t + '.' + k);
      }
      return bad.sort();
    })(),
  };
}
const observed = collectObserved(FRAMES);

/* ---- 8. node render-support classification (auditable rule) ----------- */
// The classification is a RULE over schema facts, not a hand-list; the Dart
// registry is generated from it and the test asserts key-set equality with the
// schema node set so nothing can be silently dropped.
const RENDER_TEXT = new Set(['text', 'paragraph', 'holder_paragraph', 'text_block', 'shape_text_block']);
const RENDER_INLINE = new Set(['hard_break', 'tab']);
const RENDER_VISUAL_DEGRADED = new Set(['image', 'chart', 'video', 'shape', 'line', 'text_shape']);
function supportOf(n) {
  if (n.isText) return { support: 'rendered', why: 'schema isText node — rendered as inline text' };
  if (RENDER_TEXT.has(n.name)) return { support: 'rendered', why: 'text-bearing block rendered by this batch' };
  if (RENDER_INLINE.has(n.name)) return { support: 'rendered', why: 'inline atom rendered as break/tab' };
  if (RENDER_VISUAL_DEGRADED.has(n.name))
    return { support: 'degraded', why: 'visual node; geometry/image bytes channel not taken in this batch -> visible degraded card' };
  if (typeof n.content === 'string')
    return { support: 'structural', why: 'container: registered, children rendered' };
  return { support: 'structural', why: 'leaf without text content: registered, not painted' };
}
for (const n of nodes) Object.assign(n, supportOf(n));

/* ---- 9. assemble ------------------------------------------------------ */
const out = {
  $schema_note:
    'Machine-readable export of the `.oslides` ProseMirror-fork presentation schema + step vocabulary ' +
    'as implemented by Synology Office (SPK 3.8.0-22711). Generated offline from local artifacts only.',
  generated_by: 'tool/office_collab_spike/schema/export_slides_schema.js',
  generated_at: new Date().toISOString(),
  source: {
    package: 'Synology Office SPK 3.8.0-22711 (x86_64)',
    export_dir: SPK,
    bundle: 'server/common/prosemirror/index.js',
    bundle_bytes: src.length,
    bundle_sha256: srcSha256,
    load_method: 'require() with Module._extensions[".node"] stubbed (no native module, no network)',
    exports: Object.keys(PM),
    frame_dir: FRAMES,
  },
  schema: {
    name: rawSpec.name,
    version: rawSpec.version,
    topNode: 'doc',
    topNode_content: (rawSpec.nodes || {}).doc ? rawSpec.nodes.doc.content : null,
    node_count: nodes.length,
    mark_count: marks.length,
    attr_mark_count: Object.keys(attrMarks).length,
  },
  groups,
  nodes,
  marks,
  attr_marks: attrMarks,
  node_support: Object.fromEntries(nodes.map((n) => [n.name, { support: n.support, why: n.why }])),
  steps: {
    contract: stepContract,
    registry_functions: stepRegistryFns,
    count: steps.length,
    entries: steps,
    dispatcher_note:
      'there is no `switch(cmd)` dispatcher for presentations: step JSON ids are looked up by ' +
      '`Step.stepClass(e.stepType)`; the registry is the analogue of the sheet command table',
  },
  observed,
  provenance_spec_blocks: {
    basic: {
      marker: 'let sf={name:"",version:0,nodes:{',
      offset: BASIC_START,
      snippet: srcText.slice(BASIC_START, BASIC_START + 200).replace(/\s+/g, ' '),
    },
    presentation: {
      marker: 'wm.mergeSpec(sf,{name:"presentation",...})',
      offset: PRES_START,
      end: PRES_END,
      snippet: srcText.slice(PRES_START, PRES_START + 200).replace(/\s+/g, ' '),
    },
  },
};

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
process.stderr.write(
  `wrote ${OUT}\n  nodes=${nodes.length} marks=${marks.length} attr_marks=${Object.keys(attrMarks).length} ` +
    `steps=${steps.length}\n  observed=${observed ? 'yes' : 'no'} bundle sha256=${srcSha256.slice(0, 16)}…\n`,
);
