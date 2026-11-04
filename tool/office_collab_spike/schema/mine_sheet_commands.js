#!/usr/bin/env node
/*
 * Offline miner: `.osheet` collaboration command vocabulary.
 *
 * Sources (read-only static analysis of the installed Office SPK):
 *   server/sheet/node_modules/@ss/core.js       (model + command implementations)
 *   server/sheet/node_modules/@ss/runtime.js    (WorkbookController / RuleController dispatchers)
 *   server/sheet/core/client.js                 (socket `set` handling)
 *   ui/dist/ui.sheet.js                         (what the browser client emits)
 *
 * It extracts:
 *   - every `cmd:"<literal>"` object literal + the key names in that literal
 *   - every `switch(<x>.cmd){ case"..." }` dispatcher and its case labels
 *   - the two sides (client-emitted vs server-known) so the report can separate them
 *
 * Usage:
 *   node tool/office_collab_spike/schema/mine_sheet_commands.js \
 *        [--spk /tmp/spk/export_Office] [--out tool/office_collab_spike/schema/sheet_commands.json]
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
const SPK = arg('--spk', '/tmp/spk/export_Office');
const OUT = arg('--out', path.join(__dirname, 'sheet_commands.json'));

const FILES = {
  'server/sheet/node_modules/@ss/core.js': 'server model + command implementations',
  'server/sheet/node_modules/@ss/runtime.js': 'server WorkbookController / RuleController dispatchers',
  'server/sheet/node_modules/@ss/gc.js': 'server gc',
  'server/sheet/core/client.js': 'server socket `set` handler',
  'ui/dist/ui.sheet.js': 'browser client (what the editor emits)',
};

function read(rel) {
  const p = path.join(SPK, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null;
}

/** Extract `{cmd:"x", ...}` literals and the top-level keys of the literal. */
function extractCmdLiterals(src, rel) {
  const out = new Map();
  const re = /\{[^{}]*?\bcmd:"([^"]{1,60})"[^{}]*?\}/g;
  let m;
  while ((m = re.exec(src))) {
    const cmd = m[1];
    const literal = m[0];
    const keys = [...literal.matchAll(/(?:^|[{,])\s*([A-Za-z_$][\w$]*)\s*:/g)].map((x) => x[1]);
    const value = [...literal.matchAll(/(?:^|[{,])\s*([A-Za-z_$][\w$]*)\s*:\s*([^,{}]{1,120})/g)].map(
      (x) => x[1] + ': ' + x[2].trim(),
    );
    if (!out.has(cmd)) out.set(cmd, { cmd, sites: [] });
    out.get(cmd).sites.push({
      file: rel,
      offset: m.index,
      keys,
      fields: value,
      snippet: literal.replace(/\s+/g, ' ').slice(0, 240),
    });
  }
  return out;
}

/** Extract cmd-keyed switch dispatchers and their case labels. */
function extractSwitches(src, rel) {
  const out = [];
  const re = /switch\(\s*([A-Za-z_$][\w$.]{0,20})\.cmd\s*\)/g;
  let m;
  while ((m = re.exec(src))) {
    const seg = src.slice(m.index, m.index + 6000);
    // case labels up to the end of the switch block (heuristic: first `default:`)
    const labels = [...seg.matchAll(/case"([^"]+)"/g)].map((x) => x[1]);
    const uniq = [...new Set(labels)];
    out.push({
      file: rel,
      offset: m.index,
      expression: m[1] + '.cmd',
      case_labels: uniq,
      case_count: uniq.length,
      context: src.slice(Math.max(0, m.index - 160), m.index + 160).replace(/\s+/g, ' '),
    });
  }
  return out;
}

/** Extract `case"..."` inside a `startsWith("prefix")` driven dispatcher (e.g. worksheet.*). */
function extractPrefixDispatchers(src, rel) {
  const out = [];
  const re = /startsWith\("([^"]+)"\)/g;
  let m;
  while ((m = re.exec(src))) {
    const seg = src.slice(m.index, m.index + 5000);
    const before = src.slice(Math.max(0, m.index - 300), m.index);
    // the dispatcher must key off `.cmd` either just before or just after
    if (!/\.cmd/.test(before + seg.slice(0, 300))) continue;
    const labels = [...new Set([...seg.matchAll(/case"([^"]+)"/g)].map((x) => x[1]))];
    if (labels.length < 2) continue;
    out.push({
      file: rel,
      offset: m.index,
      prefix: m[1],
      case_labels: labels,
      case_count: labels.length,
      context: src.slice(Math.max(0, m.index - 200), m.index + 240).replace(/\s+/g, ' '),
    });
  }
  return out;
}

const sources = {};
const literals = new Map();
const switches = [];
const prefixDispatchers = [];
const hashes = {};

for (const rel of Object.keys(FILES)) {
  const src = read(rel);
  if (src === null) {
    sources[rel] = { present: false };
    continue;
  }
  hashes[rel] = crypto.createHash('sha256').update(src).digest('hex');
  sources[rel] = { present: true, bytes: src.length, what: FILES[rel], sha256: hashes[rel] };
  for (const [k, v] of extractCmdLiterals(src, rel)) {
    if (!literals.has(k)) literals.set(k, v);
    else literals.get(k).sites.push(...v.sites);
  }
  switches.push(...extractSwitches(src, rel));
  prefixDispatchers.push(...extractPrefixDispatchers(src, rel));
}

/* ---- socket-level events + status codes (server/sheet/core/client.js) -- */
const clientSrc = read('server/sheet/core/client.js') || '';
const socketEvents = [];
for (const ev of ['init', 'peek', 'set', 'peer', 'query_cell_history', 'save']) {
  const re = new RegExp('on\\("' + ev + '"');
  const m = re.exec(clientSrc);
  socketEvents.push({
    event: ev,
    direction: 'C->S',
    handler_found: !!m,
    offset: m ? m.index : null,
  });
}
const commentCmds = (clientSrc.match(/new Set\(\[([^\]]*)\]\)/) || [])[1];

/* ---- classify -------------------------------------------------------- */
const clientSrcFull = read('ui/dist/ui.sheet.js') || '';
const serverSrcFull = Object.keys(FILES)
  .filter((f) => f.startsWith('server/'))
  .map((f) => read(f) || '')
  .join('\n');

const literalCmds = [...literals.keys()].sort();
const serverSwitchLabels = new Set();
for (const s of switches) if (s.file.startsWith('server/')) s.case_labels.forEach((l) => serverSwitchLabels.add(l));
for (const s of prefixDispatchers) if (s.file.startsWith('server/')) s.case_labels.forEach((l) => serverSwitchLabels.add(l));

const clientEmitted = new Set([...clientSrcFull.matchAll(/cmd:"([^"]+)"/g)].map((x) => x[1]));

const known = new Set([...literalCmds, ...serverSwitchLabels]);

const commands = [...known]
  .sort()
  .map((cmd) => {
    const rec = literals.get(cmd);
    return {
      cmd,
      in_client_ui_sheet: clientEmitted.has(cmd),
      in_server_literal: !!rec && rec.sites.some((s) => s.file.startsWith('server/')),
      in_server_switch: serverSwitchLabels.has(cmd),
      family: cmd.startsWith('worksheet.')
        ? 'worksheet lifecycle'
        : cmd.startsWith('pivot') || /pivot/.test(cmd)
          ? 'pivot table'
          : /_row$|_col$|_rows$|_cols$/.test(cmd)
            ? 'row/column'
            : /comment/.test(cmd)
              ? 'comment'
              : /filter/.test(cmd)
                ? 'filter'
                : /validation/.test(cmd)
                  ? 'data validation'
                  : /_cf$|_rule$/.test(cmd)
                    ? 'conditional formatting'
                    : /image|chart|drawing/.test(cmd)
                      ? 'drawing/chart'
                      : /define/.test(cmd)
                        ? 'defined name'
                        : /style|font|fill|border|alignment|format|value|note|merge|unmerge|collapse|group|sort/.test(cmd)
                          ? 'cell/block'
                          : 'other',
      field_shapes: rec
        ? rec.sites
            .filter((s) => s.keys.length > 1)
            .slice(0, 3)
            .map((s) => ({
              file: s.file,
              offset: s.offset,
              keys: s.keys,
              example: s.snippet,
            }))
        : [],
      sites: rec ? rec.sites.map((s) => ({ file: s.file, offset: s.offset })).slice(0, 8) : [],
    };
  });

const out = {
  generated_by: 'tool/office_collab_spike/schema/mine_sheet_commands.js',
  generated_at: new Date().toISOString(),
  sources,
  socket_events: socketEvents,
  socket_set_contract: {
    ack_shape: 'cb(incomingRev, currentRev, status[, extra])',
    status_codes: {
      0: 'rejected (invalid command / not applicable)',
      1: 'applied (extra = execCommand result)',
      2: 'version conflict (incoming rev !== current rev + 1)',
    },
    source: 'server/sheet/core/client.js :: _onSet',
  },
  client_only_comment_commands_set: commentCmds || null,
  error_codes_source: 'server/sheet/core/error_code.js (snapshot err) + server/common/collab/Constants.js (doc/socket err)',
  counts: {
    literal_cmd_literals: literalCmds.length,
    server_switch_case_labels: serverSwitchLabels.size,
    client_emitted_literals: clientEmitted.size,
    known_union: commands.length,
  },
  dispatchers: switches,
  prefix_dispatchers: prefixDispatchers,
  commands,
  all_cmd_literals: literalCmds,
  server_accepted_union: [...serverSwitchLabels].sort(),
  client_emitted_union: [...clientEmitted].sort(),
};

fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
console.log('cmd literals          :', literalCmds.length);
console.log('server switch labels  :', serverSwitchLabels.size);
console.log('client emitted        :', clientEmitted.size);
console.log('known union           :', commands.length);
console.log('wrote', OUT);
