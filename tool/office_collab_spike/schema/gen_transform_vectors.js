#!/usr/bin/env node
/*
 * Office C' - M2: transform / OT vector generator (official bundle = oracle).
 *
 * WHAT THIS IS
 *   A pure-offline differential-test vector generator. It `require()`s the
 *   Synology Office ProseMirror-fork bundle (read-only, no native module, no
 *   network) and runs the OFFICIAL `transform` module (Step / StepResult /
 *   PosMap / Mapping / Transform.cherryPick) over a fixed set of documents and
 *   step sequences. The observed results are written to a committed JSON file
 *   that the Dart side must reproduce byte-for-byte.
 *
 *   NOTHING here is guessed: every expected value is produced by running the
 *   vendor code. Re-run and compare sha256 to reproduce.
 *
 *   The `.node` native module is never loaded: a stub is installed so the
 *   bundle can be required purely offline.
 *
 * Usage:
 *   node tool/office_collab_spike/schema/gen_transform_vectors.js \
 *        [--spk /tmp/spk/export_Office] \
 *        [--out test/fixtures/office_collab/transform_vectors.json]
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
const REPO = path.resolve(__dirname, '..', '..', '..');
const SPK = arg('--spk', '/tmp/spk/export_Office');
const OUT = path.resolve(arg('--out', path.join(REPO, 'test/fixtures/office_collab/transform_vectors.json')));
const PM_BUNDLE = path.join(SPK, 'server/common/prosemirror/index.js');

/* ---- 1. load the fork bundle with a .node stub ------------------------ */
Module._extensions['.node'] = function (m) {
  m.exports = new Proxy(function () {}, { get: () => function () {} });
};
const bundleBytes = fs.readFileSync(PM_BUNDLE);
const bundleSha256 = crypto.createHash('sha256').update(bundleBytes).digest('hex');
const PM = require(PM_BUNDLE);
const schema = PM.schemaDocument.schema;
const T = PM.transform;
const F = PM.model.Fragment;

/* ---- 2. helpers -------------------------------------------------------- */
const cloned = (x) => JSON.parse(JSON.stringify(x));
const mk = (json) => schema.nodeFromJSON(cloned(json));
const canon = (x) => JSON.stringify(x);
const nodeSize = (doc) => doc.content.size;

/** Run a sequence of `Transform` operations and return the built transform. */
function build(baseDoc, fn) {
  const tr = new T.Transform(baseDoc);
  fn(tr);
  return tr;
}

/** Apply a list of StepJSON to a doc using the OFFICIAL Step.fromJSON + apply. */
function applyStepJsons(doc, stepJsons) {
  let cur = doc;
  for (const sj of stepJsons) {
    const step = T.Step.fromJSON(schema, cloned(sj));
    if (!step) throw new Error('Step.fromJSON returned null for ' + JSON.stringify(sj));
    const res = step.apply(cur);
    if (!res.succ) throw new Error('official apply failed: ' + JSON.stringify(res.failed));
    cur = res.doc;
  }
  return cur;
}

/**
 * Put a freshly parsed doc into the stable "post-transform" form the editor
 * actually holds after any edit.
 *
 * The fork runs an incremental node-state machine (`Bn._update` with
 * `trimNode: true`, driven by `schema.state_map`) inside `Node.replace`, which
 * *trims* optional attrs equal to their `empty_value` from a small region of
 * the tree. A doc straight out of `nodeFromJSON` still carries those attrs, so
 * its very first official edit changes them as a side effect (see the
 * `state_trim` bucket below). Because that machinery is a schema-driven
 * subsystem outside M2's scope, the step vectors use an already-trimmed base:
 * one official insert + delete leaves the content byte-identical and the state
 * machine settled, after which official results are pure step semantics.
 */
function stabilize(doc, pos) {
  const tr = new T.Transform(doc);
  tr.insert(pos, F.from(schema.text('Z')));
  tr.delete(pos, pos + 1);
  return tr.doc;
}

function reject(label, fn) {
  try {
    const v = fn();
    return { label, threw: false, value: v === undefined ? null : v };
  } catch (e) {
    return { label, threw: true, errorName: e && e.constructor ? e.constructor.name : 'Error', errorMessage: String(e && e.message) };
  }
}

/** Locate the marker text "C3SPIKE-DOC-BASE" in a canonical doc. */
function markerPos(doc) {
  let found = -1;
  doc.descendants((node, pos) => {
    if (node.isText && node.text.indexOf('C3SPIKE-DOC-BASE') >= 0) {
      found = pos;
      return false;
    }
  });
  return found;
}

/* ---- 3. canonical base documents -------------------------------------- */
const RAW_FIXTURE = JSON.parse(
  fs.readFileSync(path.join(REPO, 'test/fixtures/office_collab/dart_fetched_doc_v1.json'), 'utf8')
);
const docRaw = mk(RAW_FIXTURE);
const basePos = markerPos(docRaw); // 21
/** State-machine-settled base used by every step/map/rebase vector. */
const docBase = stabilize(docRaw, basePos);
const baseDocJson = docBase.toJSON();

/* docSplit: two paragraphs (official `split` at basePos+5). */
const trSplit = build(docBase, (tr) => tr.split(basePos + 5));
const docSplit = trSplit.doc;

/* docMarked: marker text carries strong + font_size (official addMark). */
const trMarked = build(docBase, (tr) => {
  tr.addMarks(basePos, basePos + 15, [schema.mark('strong')]);
  tr.addMarks(basePos, basePos + 15, [schema.mark('font_size', { value: 24 })]);
});
const docMarked = trMarked.doc;

const docs = {
  docBase: baseDocJson,
  docBaseRaw: docRaw.toJSON(),
  docSplit: docSplit.toJSON(),
  docMarked: docMarked.toJSON(),
};

/* sanity: official nodeFromJSON is idempotent on every canonical doc. */
for (const [k, v] of Object.entries(docs)) {
  const rt = schema.nodeFromJSON(cloned(v)).toJSON();
  if (canon(rt) !== canon(v)) throw new Error('doc ' + k + ' is not nodeFromJSON-idempotent');
}

const D = { docBase, docBaseRaw: docRaw, docSplit, docMarked };

/* ---- 4. vector buckets ------------------------------------------------- */
const vectors = { text: [], mark: [], structure: [], attrs: [], map: [], rebase: [], failure: [], state_trim: [] };
const skipped = [];

/** `apply` vector: base doc key + StepJSON list -> official result doc JSON. */
function applyVector(bucket, id, docKey, fn) {
  try {
    const tr = build(D[docKey], fn);
    const stepJsons = tr.steps.map((s) => s.toJSON());
    // cross-check: replay through Step.fromJSON must reproduce the same doc
    const replayed = applyStepJsons(D[docKey], stepJsons);
    if (canon(replayed.toJSON()) !== canon(tr.doc.toJSON())) {
      throw new Error('replay mismatch for ' + id);
    }
    vectors[bucket].push({ id, doc: docKey, steps: stepJsons, result: tr.doc.toJSON() });
    return stepJsons;
  } catch (e) {
    skipped.push({ bucket, id, error: String(e && e.message) });
    return null;
  }
}

/* ---------------- 4a. text: insert / delete / replace ------------------- */
applyVector('text', 'insert-text-mid-marker', 'docBase', (tr) => tr.insert(basePos + 5, F.from(schema.text('XYZ'))));
applyVector('text', 'insert-text-at-end', 'docBase', (tr) => tr.insert(basePos + 15, F.from(schema.text('#'))));
applyVector('text', 'insert-empty-fragment-is-noop', 'docBase', (tr) => tr.insert(basePos + 5, F.empty));
applyVector('text', 'delete-inside-marker', 'docBase', (tr) => tr.delete(basePos + 2, basePos + 6));
applyVector('text', 'delete-whole-marker', 'docBase', (tr) => tr.delete(basePos, basePos + 15));
applyVector('text', 'replace-range-with-text', 'docBase', (tr) => tr.replace(basePos + 2, basePos + 7, F.from(schema.text('HELLO'))));
applyVector('text', 'insert-two-text-nodes', 'docBase', (tr) => tr.insert(basePos + 4, F.from([schema.text('AA'), schema.text('BB')])));
applyVector('text', 'delete-then-insert-different-pos', 'docBase', (tr) => {
  tr.delete(basePos + 10, basePos + 14);
  tr.insert(basePos + 2, F.from(schema.text('!@')));
});
applyVector('text', 'insert-after-split-second-block', 'docSplit', (tr) => tr.insert(basePos + 6 + 5, F.from(schema.text('Q'))));
applyVector('text', 'delete-across-split-blocks', 'docSplit', (tr) => tr.delete(basePos + 1, basePos + 6 + 3));

/* ---------------- 4b. mark: addMark / removeMark ------------------------ */
applyVector('mark', 'add-strong-presence', 'docBase', (tr) => tr.addMarks(basePos, basePos + 5, [schema.mark('strong')]));
applyVector('mark', 'add-em-presence', 'docBase', (tr) => tr.addMarks(basePos + 2, basePos + 9, [schema.mark('em')]));
applyVector('mark', 'add-underline-presence', 'docBase', (tr) => tr.addMarks(basePos, basePos + 15, [schema.mark('underline')]));
applyVector('mark', 'add-font-size-valued', 'docBase', (tr) => tr.addMarks(basePos, basePos + 4, [schema.mark('font_size', { value: 24 })]));
applyVector('mark', 'add-color-valued', 'docBase', (tr) => tr.addMarks(basePos + 5, basePos + 10, [schema.mark('color', { value: '#ff0000' })]));
applyVector('mark', 'add-two-marks-at-once', 'docBase', (tr) =>
  tr.addMarks(basePos, basePos + 6, [schema.mark('strong'), schema.mark('font_size', { value: 18 })]));
applyVector('mark', 'remove-strong', 'docMarked', (tr) => tr.removeMarks(basePos, basePos + 15, [schema.mark('strong')]));
applyVector('mark', 'remove-font-size', 'docMarked', (tr) => tr.removeMarks(basePos, basePos + 15, [schema.mark('font_size')]));
applyVector('mark', 'remove-one-of-two-marks', 'docMarked', (tr) => tr.removeMarks(basePos + 3, basePos + 8, [schema.mark('strong')]));
applyVector('mark', 'remove-mark-not-present-is-noop', 'docBase', (tr) => tr.removeMarks(basePos, basePos + 5, [schema.mark('strong')]));
applyVector('mark', 'clear-all-marks', 'docMarked', (tr) => tr.clearMarks(basePos, basePos + 15));

/* ---------------- 4c. structure: split / join --------------------------- */
applyVector('structure', 'split-marker-middle', 'docBase', (tr) => tr.split(basePos + 5));
applyVector('structure', 'split-at-marker-offset-1', 'docBase', (tr) => tr.split(basePos + 1));
applyVector('structure', 'join-split-blocks', 'docSplit', (tr) => tr.join(basePos + 6));
applyVector('structure', 'split-then-join', 'docBase', (tr) => {
  tr.split(basePos + 4);
  tr.join(basePos + 5);
});
applyVector('structure', 'split-then-insert', 'docBase', (tr) => {
  tr.split(basePos + 3);
  tr.insert(basePos + 4, F.from(schema.text('Z')));
});

/* ---------------- 4d. attrs: setRootNodeAttrs / setNodeAttrs ------------ */
applyVector('attrs', 'set-root-page-setup-full', 'docBase', (tr) =>
  tr.setRootNodeAttrs({ page_setup: { left: 1, top: 2, right: 3, bottom: 4, orientation: 'landscape', page_type: 'a4' } }));
applyVector('attrs', 'set-root-page-setup-partial-orientation', 'docBase', (tr) =>
  tr.setRootNodeAttrs({ page_setup: { orientation: 'landscape' } }));
applyVector('attrs', 'set-root-page-setup-page-type', 'docBase', (tr) =>
  tr.setRootNodeAttrs({ page_setup: { page_type: 'letter' } }));
// the paragraph that directly contains the marker text (edit_area > paragraph)
const paraPos = docBase.resolve(basePos).before(2);
applyVector('attrs', 'set-paragraph-text-align', 'docBase', (tr) =>
  tr.setNodeAttrs(paraPos, { textAlign: 'center' }));
applyVector('attrs', 'set-paragraph-line-height', 'docBase', (tr) =>
  tr.setNodeAttrs(paraPos, { lineHeight: 1.5 }));
applyVector('attrs', 'set-paragraph-then-split', 'docBase', (tr) => {
  tr.setNodeAttrs(paraPos, { textAlign: 'center' });
  tr.split(basePos + 5);
});

/* ---------------- 4e. state_trim: the fork's incremental node-state ----- */
/**
 * A doc straight out of `nodeFromJSON` carries optional attrs equal to their
 * `empty_value` (here `style_editor`'s heading4/5 `paddingTop`/`paddingBottom`
 * = 0). The fork's `Node.replace` calls `Bn.updateAndTrim` (schema-driven
 * `state_map` incremental attrs state), which drops exactly those attrs as a
 * side effect of the first edit. This is observable - the editor's serialized
 * document changes - but requires porting the whole state machine, which is
 * outside M2. Captured here so the divergence is data, not a guess; it is also
 * registered in `unsupported[]`.
 */
vectors.state_trim.push({
  id: 'first-edit-trims-empty-value-attrs',
  doc: 'docBaseRaw',
  steps: [
    { stepType: 'replace', from: basePos, to: basePos, slice: { content: [{ type: 'text', text: 'Z' }], openLeft: 0, openRight: 0 }, structure: false },
    { stepType: 'replace', from: basePos, to: basePos + 1, slice: null, structure: false },
  ],
  result: baseDocJson,
  trimmed_paths: [
    '/content/1/content/5/attrs/paddingTop',
    '/content/1/content/5/attrs/paddingBottom',
    '/content/1/content/6/attrs/paddingTop',
    '/content/1/content/6/attrs/paddingBottom',
  ],
});
{
  const got = applyStepJsons(D.docBaseRaw, vectors.state_trim[0].steps).toJSON();
  if (canon(got) !== canon(baseDocJson)) {
    throw new Error('state_trim vector does not reproduce the settled base doc');
  }
}

/* ---------------- 4f. map: official PosMap / Mapping -------------------- */
function mapVector(id, docKey, buildMapping, probes, otherStepsFn) {
  try {
    const trMap = build(D[docKey], buildMapping);
  const posMaps = trMap.steps.map((s) => s.posMap(D[docKey]));
  const mapping = new T.Mapping(posMaps, trMap.steps.map(() => null));
  const probeOut = probes.map(([pos, assoc]) => ({
    pos, assoc,
    result: mapping.map(pos, assoc),
  }));
  const out = {
    id, doc: docKey,
    mappingSteps: trMap.steps.map((s) => s.toJSON()),
    probes: probeOut,
  };
  if (otherStepsFn) {
    const trOther = build(D[docKey], otherStepsFn);
    out.otherSteps = trOther.steps.map((s) => s.toJSON());
    out.otherMapped = trOther.steps.map((s) => {
      const m = s.map(mapping);
      return m ? m.toJSON() : null;
    });
  }
  vectors.map.push(out);
  } catch (e) {
    skipped.push({ bucket: 'map', id, error: String(e && e.message) });
  }
}

const ALL_POS = [0, 1, 18, 19, 20, 21, 22, 25, 26, 36, 37, 50, 51, 69, 70];
mapVector('map-insert-in-marker', 'docBase',
  (tr) => tr.insert(basePos + 5, F.from(schema.text('XYZ'))),
  ALL_POS.flatMap((p) => [[p, -1], [p, 0], [p, 1]]),
  (tr) => tr.insert(basePos + 10, F.from(schema.text('QQ'))));

mapVector('map-delete-in-marker', 'docBase',
  (tr) => tr.delete(basePos + 2, basePos + 8),
  ALL_POS.flatMap((p) => [[p, -1], [p, 1]]),
  (tr) => tr.insert(basePos + 12, F.from(schema.text('RR'))));

mapVector('map-split-marker', 'docBase',
  (tr) => tr.split(basePos + 5),
  ALL_POS.flatMap((p) => [[p, -1], [p, 0], [p, 1]]),
  (tr) => tr.insert(basePos + 8, F.from(schema.text('SS'))));

mapVector('map-add-mark', 'docBase',
  (tr) => tr.addMarks(basePos, basePos + 6, [schema.mark('strong')]),
  ALL_POS.flatMap((p) => [[p, -1], [p, 1]]),
  null);

mapVector('map-two-inserts', 'docBase',
  (tr) => {
    tr.insert(basePos + 3, F.from(schema.text('AA')));
    tr.insert(basePos + 12, F.from(schema.text('BB')));
  },
  [0, 20, 21, 25, 36, 40, 41, 51, 70].flatMap((p) => [[p, -1], [p, 0], [p, 1]]),
  null);

/* ---------------- 4f. rebase: concurrent A / B -------------------------- */
/**
 * `rebase` vector: local steps A and remote steps B both applied to the same
 * base doc. The official rebase is:
 *   mapping = Mapping(B.posMaps)
 *   for each a in A: m = a.map(mapping); if (m) trB.step(m)
 * and `Transform.cherryPick` is cross-checked to produce the same doc.
 */
function rebaseVector(id, docKey, localFn, remoteFn) {
  try {
  const trLocal = build(D[docKey], localFn);
  const trRemote = build(D[docKey], remoteFn);
  const posMapsRemote = trRemote.steps.map((s) => s.posMap(D[docKey]));
  const mapping = new T.Mapping(posMapsRemote, trRemote.steps.map(() => null));
  const mappedLocal = trLocal.steps.map((s) => {
    const m = s.map(mapping);
    return m ? m.toJSON() : null;
  });
  // official rebase result
  const trRebased = build(D[docKey], remoteFn);
  for (const s of trLocal.steps) {
    const m = s.map(mapping);
    if (m) trRebased.step(m);
  }
  // official cherryPick cross-check (must agree)
  const trCherry = build(D[docKey], remoteFn);
  trCherry.cherryPick(trLocal.steps, trLocal.steps.map((s) => s.posMap(D[docKey])), trLocal.steps.map(() => null));
  if (canon(trCherry.doc.toJSON()) !== canon(trRebased.doc.toJSON())) {
    throw new Error('cherryPick mismatch for ' + id);
  }
  vectors.rebase.push({
    id, doc: docKey,
    localSteps: trLocal.steps.map((s) => s.toJSON()),
    remoteSteps: trRemote.steps.map((s) => s.toJSON()),
    mappedLocalSteps: mappedLocal,
    remoteDoc: trRemote.doc.toJSON(),
    result: trRebased.doc.toJSON(),
  });
  } catch (e) {
    skipped.push({ bucket: 'rebase', id, error: String(e && e.message) });
  }
}

rebaseVector('rebase-two-inserts-same-pos', 'docBase',
  (tr) => tr.insert(basePos + 5, F.from(schema.text('AAA'))),
  (tr) => tr.insert(basePos + 5, F.from(schema.text('BBB'))));

rebaseVector('rebase-insert-before-remote-insert', 'docBase',
  (tr) => tr.insert(basePos + 2, F.from(schema.text('LLL'))),
  (tr) => tr.insert(basePos + 10, F.from(schema.text('RRR'))));

rebaseVector('rebase-delete-local-insert-remote', 'docBase',
  (tr) => tr.delete(basePos + 4, basePos + 9),
  (tr) => tr.insert(basePos + 1, F.from(schema.text('R'))));

rebaseVector('rebase-local-insert-remote-delete-shift', 'docBase',
  (tr) => tr.insert(basePos + 14, F.from(schema.text('L'))),
  (tr) => tr.delete(basePos, basePos + 5));

rebaseVector('rebase-split-local-insert-remote', 'docBase',
  (tr) => tr.split(basePos + 5),
  (tr) => tr.insert(basePos + 12, F.from(schema.text('R'))));

rebaseVector('rebase-mark-local-insert-remote', 'docBase',
  (tr) => tr.addMarks(basePos, basePos + 15, [schema.mark('strong')]),
  (tr) => tr.insert(basePos + 7, F.from(schema.text('R'))));

rebaseVector('rebase-attr-local-insert-remote', 'docBase',
  (tr) => tr.setRootNodeAttrs({ page_setup: { orientation: 'landscape' } }),
  (tr) => tr.insert(basePos + 3, F.from(schema.text('R'))));

rebaseVector('rebase-two-splits', 'docBase',
  (tr) => tr.split(basePos + 4),
  (tr) => tr.split(basePos + 9));

/* ---------------- 4g. failure paths ------------------------------------ */
function failureVector(id, docKey, kind, payload) {
  vectors.failure.push({ id, doc: docKey, kind, ...payload });
}

// Step.fromJSON throws on an unknown stepType (server -> 411 Invalid command).
failureVector('fromjson-unknown-step-type', 'docBase', 'fromJsonThrows',
  reject('unknown', () => T.Step.fromJSON(schema, { stepType: 'dsh_bogus_step', from: 0, to: 0 })));
// Step.fromJSON throws on an out-of-range offset at apply time
failureVector('apply-out-of-range-to', 'docBase', 'applyThrows',
  reject('oor', () => {
    const s = T.Step.fromJSON(schema, { stepType: 'replace', from: 0, to: 999, slice: null, structure: false });
    return s.apply(docBase);
  }));
failureVector('apply-negative-from', 'docBase', 'applyThrows',
  reject('neg', () => {
    const s = T.Step.fromJSON(schema, { stepType: 'replace', from: -1, to: 0, slice: null, structure: false });
    return s.apply(docBase);
  }));
// inconsistent open depths -> ReplaceError -> StepResult.fail
failureVector('apply-inconsistent-open-depths', 'docBase', 'applyFailed',
  reject('depths', () => {
    const s = T.Step.fromJSON(schema, {
      stepType: 'replace', from: 20, to: 36, slice: null, structure: true,
    });
    const r = s.apply(docBase);
    return { succ: r.succ, failed: r.failed || null, reason: r.reason || null };
  }));
// slice open depth deeper than the insertion position -> ReplaceError -> fail
failureVector('apply-open-left-deeper-than-position', 'docBase', 'applyFailed',
  reject('deeper', () => {
    const s = T.Step.fromJSON(schema, {
      stepType: 'replace', from: basePos, to: basePos,
      slice: { content: [{ type: 'paragraph' }], openLeft: 3, openRight: 3 },
      structure: false,
    });
    const r = s.apply(docBase);
    return { succ: r.succ, failed: r.failed || null, reason: r.reason || null };
  }));
// unknown mark type in an addMark step -> RangeError from Step.fromJSON (411)
failureVector('fromjson-unknown-mark-type', 'docBase', 'fromJsonThrows',
  reject('mark', () => T.Step.fromJSON(schema, { stepType: 'addMark', from: basePos, to: basePos + 5, mark: { _: 'dsh_bogus_mark' } })));
// a step offset beyond the doc is also rejected by Step.fromJSON/apply
failureVector('apply-insert-beyond-doc', 'docBase', 'applyThrows',
  reject('beyond', () => {
    const s = T.Step.fromJSON(schema, {
      stepType: 'replace', from: 71, to: 71,
      slice: { content: [{ type: 'text', text: 'x' }], openLeft: 0, openRight: 0 },
      structure: false,
    });
    return s.apply(docBase);
  }));
// missing `structure` field defaults to false; missing `slice` defaults to empty
// (official Step.fromJSON tolerates both) - captured as an apply, not a failure.
failureVector('fromjson-missing-optional-fields', 'docBase', 'fromJsonOk',
  reject('missing', () => {
    const s = T.Step.fromJSON(schema, { stepType: 'replace', from: basePos + 5, to: basePos + 5 });
    const r = s.apply(docBase);
    return { succ: r.succ, step: s.toJSON(), failed: r.failed || null };
  }));

/* ---- 4h. officially observable but NOT reproduced by the Dart layer ---- */
/**
 * These are captured so the gap is documented (not silently dropped): they
 * require the node-type content-expression matcher (`NodeType.compatibleContent`
 * -> `ContentExpr.compatible` / `validContent`), which M1 deliberately did not
 * export into Dart. The Dart `apply` therefore does not raise `Cannot join ...`.
 * Included as data only; the Dart test asserts we produce a doc (i.e. that the
 * divergence is known and intentional).
 */
const unsupported = [];
function unsupportedVector(id, docKey, stepJson, expected) {
  const s = T.Step.fromJSON(schema, stepJson);
  const r = s.apply(D[docKey]);
  unsupported.push({
    id, doc: docKey, step: stepJson,
    official: { succ: r.succ, failed: r.failed || null },
    reason: expected,
  });
}
unsupportedVector('cannot-join-incompatible-siblings', 'docBase',
  { stepType: 'replace', from: 18, to: 38, slice: { content: [{ type: 'paragraph' }], openLeft: 1, openRight: 1 }, structure: true },
  'NodeType.compatibleContent / ContentExpr matcher not implemented in Dart (M1 scope decision); apply does not reproduce this ReplaceError.');

/**
 * The fork's first-edit trim (see the `state_trim` bucket): official drops
 * `empty_value`-equal optional attrs as a side effect of `Node.replace`. The
 * Dart `apply` is a pure functional replace and intentionally keeps them; the
 * step vectors therefore use the already-settled base. Registered here so the
 * divergence is explicit.
 */
unsupported.push({
  id: 'first-edit-trims-empty-value-attrs',
  doc: 'docBaseRaw',
  step: vectors.state_trim[0].steps[0],
  official: { succ: true, result: baseDocJson },
  reason: 'Fork incremental node state (`schema.state_map` / Bn.updateAndTrim) trims empty_value-equal optional attrs on the first edit; not ported in M2 (state machine subsystem). Step vectors use the pre-settled `docBase`.',
});

/* ---- 5. write --------------------------------------------------------- */
const out = {
  meta: {
    generator: 'tool/office_collab_spike/schema/gen_transform_vectors.js',
    generated_at: null, // deterministic output: no timestamp
    source: {
      package: 'Synology Office SPK 3.8.0-22711 (x86_64)',
      bundle: 'server/common/prosemirror/index.js',
      bundle_sha256: bundleSha256,
      bundle_bytes: bundleBytes.length,
      load_method: 'require() with Module._extensions[".node"] stubbed (offline)',
    },
    schema: { name: 'document', version: schema.version, top_node: schema.topNodeType ? schema.topNodeType.name : 'doc' },
    doc_keys: Object.keys(docs),
    counts: Object.fromEntries(Object.entries(vectors).map(([k, v]) => [k, v.length])),
    skipped,
  },
  docs,
  vectors,
  unsupported,
};

const text = JSON.stringify(out, null, 1) + '\n';
fs.writeFileSync(OUT, text);
const sha = crypto.createHash('sha256').update(Buffer.from(text, 'utf8')).digest('hex');

console.log('bundle  : ' + PM_BUNDLE);
console.log('bundle  : ' + bundleSha256);
console.log('wrote   : ' + OUT);
console.log('sha256  : ' + sha);
console.log('docs    : ' + Object.keys(docs).join(', '));
console.log('counts  : ' + JSON.stringify(out.meta.counts));
if (skipped.length) {
  console.log('skipped : ' + skipped.length);
  for (const s of skipped) console.log('  - ' + s.bucket + '/' + s.id + ' :: ' + s.error);
} else {
  console.log('skipped : 0');
}
