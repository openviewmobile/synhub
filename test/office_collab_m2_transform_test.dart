// Office C' · M2 golden test: local step application, mapping and rebase.
//
// Every expected value below comes from RUNNING the official Synology Office
// ProseMirror-fork bundle (`server/common/prosemirror/index.js`), not from
// hand-authoring. The committed vector file is produced by:
//
//   node tool/office_collab_spike/schema/gen_transform_vectors.js
//
// and the Dart layer must reproduce it exactly. When Dart and the vectors
// disagree, the Dart code is wrong - the vectors are the oracle.
//
// Offline only: no network, no NAS, no device, no SPK required, no build.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/doc_ot_queue.dart';
import 'package:synhub/src/data/office_collab/doc_schema.dart';
import 'package:synhub/src/data/office_collab/doc_step.dart';
import 'package:synhub/src/data/office_collab/doc_transform.dart';

Map<String, Object?> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

DocJson _doc(Object? v) => (v! as Map).cast<String, Object?>();

String _canon(Object? v) => canonicalJson(v);

/// Step JSON comparison that is agnostic to the vendor's lossy `structure`
/// round trip: `ReplaceStep.toJSON` emits `structure` but `fromJSON` ignores it
/// (pinned separately in the M2.7 quirk test and the failure vectors).
Object? _forCompare(Object? json) {
  if (json is Map && json['stepType'] == 'replace') {
    final out = <String, Object?>{...json.cast<String, Object?>()};
    out.remove('structure');
    return out;
  }
  return json;
}

void main() {
  final schema = DocSchema.document;
  final vectors = _readJson(
    'test/fixtures/office_collab/transform_vectors.json',
  );
  final meta = _doc(vectors['meta']);
  final docs = _doc(vectors['docs']);
  final buckets = _doc(vectors['vectors']);

  List<Object?> bucket(String name) => buckets[name]! as List<Object?>;

  final categoryPass = <String, int>{};
  final categoryTotal = <String, int>{};

  void tally(String category, bool ok) {
    categoryTotal[category] = (categoryTotal[category] ?? 0) + 1;
    if (ok) categoryPass[category] = (categoryPass[category] ?? 0) + 1;
  }

  group('M2.0 vector provenance', () {
    test('vectors were generated from the pinned official bundle', () {
      final source = _doc(meta['source']);
      expect(source['bundle'], 'server/common/prosemirror/index.js');
      expect(
        source['bundle_sha256'],
        'eee7801664008f5082da34c6380dcbeb9508409865de60b7c7b5ebf76e70ee90',
      );
      expect(source['load_method'], contains('stubbed'));
      expect(meta['counts'], isA<Map>());
      expect((meta['skipped']! as List), isEmpty);
    });

    test('every vector document round-trips through the M1 schema model', () {
      docs.forEach((key, value) {
        final parsed = schema.nodeFromJson(value);
        expect(_canon(parsed.toJson()), _canon(value), reason: key);
      });
    });
  });

  group('M2.1 apply: text (insert / delete / replace)', () {
    for (final raw in bucket('text')) {
      final v = _doc(raw);
      final id = v['id']! as String;
      test(id, () {
        var doc = _doc(docs[v['doc']]!);
        final steps = <String>[];
        for (final sj in v['steps']! as List) {
          final step = DocStep.fromJson(sj);
          // toJSON must round-trip the exact official step payload.
          expect(
            _canon(_forCompare(step.toJson())),
            _canon(_forCompare(_doc(sj))),
            reason: '$id toJSON',
          );
          final result = step.apply(doc);
          expect(result.succ, isTrue, reason: '$id apply');
          doc = result.doc!;
          steps.add('$step');
        }
        final ok = _canon(doc) == _canon(v['result']);
        tally('text', ok);
        expect(
          _canon(doc),
          _canon(v['result']),
          reason: '$id result (${steps.join(" -> ")})',
        );
      });
    }
  });

  group('M2.2 apply: marks (addMark / removeMark)', () {
    for (final raw in bucket('mark')) {
      final v = _doc(raw);
      final id = v['id']! as String;
      test(id, () {
        var doc = _doc(docs[v['doc']]!);
        for (final sj in v['steps']! as List) {
          final step = DocStep.fromJson(sj);
          expect(
            _canon(_forCompare(step.toJson())),
            _canon(_forCompare(_doc(sj))),
            reason: '$id toJSON',
          );
          final result = step.apply(doc);
          expect(result.succ, isTrue, reason: '$id apply');
          doc = result.doc!;
        }
        final ok = _canon(doc) == _canon(v['result']);
        tally('mark', ok);
        expect(_canon(doc), _canon(v['result']), reason: '$id result');
      });
    }
  });

  group(
    'M2.3 apply: structure (split / join / openLeft+openRight+structure)',
    () {
      for (final raw in bucket('structure')) {
        final v = _doc(raw);
        final id = v['id']! as String;
        test(id, () {
          var doc = _doc(docs[v['doc']]!);
          for (final sj in v['steps']! as List) {
            final step = DocStep.fromJson(sj);
            expect(
              _canon(_forCompare(step.toJson())),
              _canon(_forCompare(_doc(sj))),
              reason: '$id toJSON',
            );
            final result = step.apply(doc);
            expect(result.succ, isTrue, reason: '$id apply');
            doc = result.doc!;
          }
          final ok = _canon(doc) == _canon(v['result']);
          tally('structure', ok);
          expect(_canon(doc), _canon(v['result']), reason: '$id result');
        });
      }
    },
  );

  group('M2.4 apply: attrs (setNodeAttrs / setRootNodeAttrs)', () {
    for (final raw in bucket('attrs')) {
      final v = _doc(raw);
      final id = v['id']! as String;
      test(id, () {
        var doc = _doc(docs[v['doc']]!);
        for (final sj in v['steps']! as List) {
          final step = DocStep.fromJson(sj);
          expect(
            _canon(_forCompare(step.toJson())),
            _canon(_forCompare(_doc(sj))),
            reason: '$id toJSON',
          );
          final result = step.apply(doc);
          expect(result.succ, isTrue, reason: '$id apply');
          doc = result.doc!;
        }
        final ok = _canon(doc) == _canon(v['result']);
        tally('attrs', ok);
        expect(_canon(doc), _canon(v['result']), reason: '$id result');
      });
    }
  });

  group('M2.5 map: PosMap / Mapping', () {
    for (final raw in bucket('map')) {
      final v = _doc(raw);
      final id = v['id']! as String;
      test(id, () {
        final base = _doc(docs[v['doc']]!);
        final mappingSteps = (v['mappingSteps']! as List)
            .map(DocStep.fromJson)
            .toList();
        final posMaps = posMapsOf(base, mappingSteps);
        final mapping = DocMapping(posMaps);
        var ok = true;
        for (final probe in v['probes']! as List) {
          final p = _doc(probe);
          final got = mapping.map(
            (p['pos']! as num).toInt(),
            (p['assoc']! as num).toInt(),
          );
          if (got != (p['result']! as num).toInt()) ok = false;
          expect(
            got,
            (p['result']! as num).toInt(),
            reason: '$id map(pos=${p['pos']}, assoc=${p['assoc']})',
          );
        }
        if (v.containsKey('otherSteps')) {
          final other = (v['otherSteps']! as List)
              .map(DocStep.fromJson)
              .toList();
          final expected = v['otherMapped']! as List;
          for (var i = 0; i < other.length; i++) {
            final mapped = other[i].map(mapping);
            final gotJson = mapped?.toJson();
            if (_canon(gotJson) != _canon(expected[i])) ok = false;
            expect(
              _canon(gotJson),
              _canon(expected[i]),
              reason: '$id otherMapped[$i]',
            );
          }
        }
        tally('map', ok);
      });
    }
  });

  group('M2.6 rebase: concurrent local/remote steps', () {
    for (final raw in bucket('rebase')) {
      final v = _doc(raw);
      final id = v['id']! as String;
      test(id, () {
        final base = _doc(docs[v['doc']]!);
        final local = (v['localSteps']! as List).map(DocStep.fromJson).toList();
        final remote = (v['remoteSteps']! as List)
            .map(DocStep.fromJson)
            .toList();
        final result = rebaseSteps(
          baseDoc: base,
          remoteSteps: remote,
          localSteps: local,
        );
        final mappedJson = result.mappedLocalSteps
            .map((s) => s?.toJson())
            .toList();
        expect(
          _canon(mappedJson),
          _canon(v['mappedLocalSteps']),
          reason: '$id mappedLocalSteps',
        );
        expect(
          _canon(result.remoteDoc),
          _canon(v['remoteDoc']),
          reason: '$id remoteDoc',
        );
        final matched = _canon(result.doc) == _canon(v['result']);
        // Cross-check the vendor `Transform.cherryPick` equivalence.
        final cherry = cherryPickSteps(
          baseDoc: base,
          remoteSteps: remote,
          localSteps: local,
        );
        final ok = matched && _canon(cherry) == _canon(v['result']);
        tally('rebase', ok);
        expect(_canon(result.doc), _canon(v['result']), reason: '$id result');
        expect(
          _canon(cherry),
          _canon(v['result']),
          reason: '$id cherryPick equivalence',
        );
      });
    }
  });

  group('M2.7 replace.structure is write-only on the wire (vendor quirk)', () {
    test('toJSON emits structure, fromJSON ignores it', () {
      final parsed =
          DocStep.fromJson(<String, Object?>{
                'stepType': 'replace',
                'from': 26,
                'to': 28,
                'slice': null,
                'structure': true,
              })
              as ReplaceStep;
      expect(
        parsed.structure,
        isFalse,
        reason: 'vendor ReplaceStep.fromJSON never reads `structure`',
      );

      // A programmatically built structural step still serialises it ...
      final built = ReplaceStep(26, 28, DocSlice.empty, true);
      expect(built.toJson()['structure'], isTrue);
      // ... but re-parsing loses it again.
      expect(
        (DocStep.fromJson(built.toJson()) as ReplaceStep).structure,
        isFalse,
      );
    });
  });

  group('M2.8 failure paths (402/411 error model)', () {
    for (final raw in bucket('failure')) {
      final v = _doc(raw);
      final id = v['id']! as String;
      final kind = v['kind']! as String;
      test('$id [$kind]', () {
        var ok = true;
        switch (kind) {
          case 'fromJsonThrows':
            final expected = v['errorMessage']! as String;
            final payload = _failurePayload(id);
            try {
              DocStep.fromJson(payload);
              ok = false;
              fail('expected $id to throw');
            } on DocStepParseException catch (e) {
              expect(e.message, expected, reason: '$id message');
            }
          case 'applyThrows':
            final expected = v['errorMessage']! as String;
            final step = DocStep.fromJson(_failurePayload(id)!);
            try {
              step.apply(_doc(docs[v['doc']]!));
              ok = false;
              fail('expected $id to throw');
            } on DocRangeError catch (e) {
              expect(e.message, expected, reason: '$id message');
            }
          case 'applyFailed':
            final value = _doc(v['value']);
            final step = DocStep.fromJson(_failurePayload(id)!);
            final result = step.apply(_doc(docs[v['doc']]!));
            expect(result.succ, isFalse, reason: id);
            expect(result.reason, value['failed'], reason: '$id reason');
          case 'fromJsonOk':
            final value = _doc(v['value']);
            final step = DocStep.fromJson(_failurePayload(id)!);
            expect(
              _canon(step.toJson()),
              _canon(value['step']),
              reason: '$id step',
            );
            final result = step.apply(_doc(docs[v['doc']]!));
            expect(result.succ, value['succ'], reason: '$id succ');
          default:
            fail('unknown failure kind $kind');
        }
        tally('failure', ok);
      });
    }
  });

  group('M2.9 OT queue: version reconciliation and rebase-on-402', () {
    test('402 ack is recognised from the real M0 wire shape', () {
      // 434[{"status":402},"Error: 1028_…doc: Not current version. incoming: 7, current: 2"]
      final outcome = parseDocEventAck(<Object?>[
        <String, Object?>{'status': 402},
        'Error: 1028_x_doc: Not current version. incoming: 7, current: 2',
      ]);
      expect(outcome.kind, DocOtAckKind.versionNotCurrent);
      expect(outcome.status, 402);
      expect(outcome.message, contains('Not current version'));
    });

    test('411 ack is recognised from the real M0 wire shape', () {
      final outcome = parseDocEventAck(<Object?>[
        <String, Object?>{'status': 411},
        'Error: 1028_x_doc: Invalid command',
      ]);
      expect(outcome.kind, DocOtAckKind.invalidCommand);
      expect(outcome.status, 411);
    });

    test('434 ack confirms and drains the queue', () {
      final base = _doc(docs['docBase']!);
      final queue = DocOtQueue(doc: base, version: 1);
      final step = ReplaceStep(
        36,
        36,
        DocSlice(
          <DocJson>[
            <String, Object?>{'type': 'text', 'text': '#'},
          ],
          0,
          0,
        ),
        false,
      );
      final frame = queue.localEdit(step);
      expect(frame.version, 1);
      expect(frame.steps.length, 1);
      expect(queue.pendingCount, 1);
      final outcome = queue.onEventAck(<Object?>[
        null,
        <String, Object?>{'version': 2, 'steps': <Object?>[]},
      ]);
      expect(outcome.kind, DocOtAckKind.confirmed);
      expect(queue.version, 2);
      expect(queue.pendingCount, 0);
      expect(_canon(queue.confirmedDoc), _canon(queue.doc));
    });

    test('incoming version must equal the server current (402 semantics)', () {
      expect(() => assertIncomingVersionCurrent(1, 1), returnsNormally);
      expect(
        () => assertIncomingVersionCurrent(7, 2),
        throwsA(
          isA<DocOtException>()
              .having((e) => e.status, 'status', 402)
              .having(
                (e) => e.message,
                'message',
                contains('incoming: 7, current: 2'),
              ),
        ),
      );
    });

    test('402 -> rebaseOnto rebases unconfirmed steps onto the new version', () {
      final base = _doc(docs['docBase']!);
      final queue = DocOtQueue(doc: base, version: 1);
      final local = ReplaceStep(
        26,
        26,
        DocSlice(
          <DocJson>[
            <String, Object?>{'type': 'text', 'text': 'AAA'},
          ],
          0,
          0,
        ),
        false,
      );
      queue.localEdit(local);

      // The server already moved to version 2 with a remote insert at the same
      // position; the resend must be rebased past it.
      final remote = ReplaceStep(
        26,
        26,
        DocSlice(
          <DocJson>[
            <String, Object?>{'type': 'text', 'text': 'BBB'},
          ],
          0,
          0,
        ),
        false,
      );
      final outcome = queue.onEventAck(<Object?>[
        <String, Object?>{'status': 402},
        'Error: Not current version. incoming: 1, current: 2',
      ]);
      expect(outcome.kind, DocOtAckKind.versionNotCurrent);

      final refetch = ReplaceStep(0, 0, DocSlice.empty, false);
      // rebaseOnto takes the remote steps fetched from the server.
      final resend = queue.rebaseOnto(
        remoteSteps: <DocStep>[remote],
        remoteVersion: 2,
      );
      expect(queue.version, 2);
      expect(resend.version, 2);
      // The resend carries the local step shifted past the remote insert.
      expect(resend.steps, hasLength(1));
      final resent = resend.steps.single as ReplaceStep;
      expect(resent.from, 29, reason: 'insert at 26 shifts past BBB (len 3)');
      expect(resent.to, 29);
      expect(
        canonicalJson(resent.slice.content),
        canonicalJson(local.slice.content),
      );
      // The optimistically applied document is remote + rebased local, in order.
      final editArea = _firstOfType(queue.doc, 'edit_area');
      final text = _textOf(editArea);
      expect(text, 'C3SPIBBBAAAKE-DOC-BASE');
      expect((queue.lastRebase!.mappedLocalSteps), hasLength(1));
      // sanity: the ignored refetch step is well-formed
      expect(refetch.toJson()['stepType'], 'replace');
    });

    test('411 -> dropInvalidStep removes the offending step', () {
      final base = _doc(docs['docBase']!);
      final queue = DocOtQueue(doc: base, version: 1);
      queue.localEdit(
        ReplaceStep(
          26,
          26,
          DocSlice(
            <DocJson>[
              <String, Object?>{'type': 'text', 'text': 'X'},
            ],
            0,
            0,
          ),
          false,
        ),
      );
      final outcome = queue.onEventAck(<Object?>[
        <String, Object?>{'status': 411},
        'Error: Invalid command',
      ]);
      expect(outcome.kind, DocOtAckKind.invalidCommand);
      expect(queue.dropInvalidStep(), isNull);
      expect(queue.pendingCount, 0);
      expect(_canon(queue.doc), _canon(base));
    });
  });

  group('M2.10 documented divergence (registered, not guessed)', () {
    test('unsupported[] declares each divergence with a concrete reason', () {
      final unsupported = (vectors['unsupported']! as List).map(_doc).toList();
      expect(unsupported, hasLength(greaterThanOrEqualTo(2)));
      final join = unsupported.firstWhere(
        (u) => u['id'] == 'cannot-join-incompatible-siblings',
      );
      expect((join['official']! as Map)['succ'], isFalse);
      expect(join['reason'], contains('compatibleContent'));
      final trim = unsupported.firstWhere(
        (u) => u['id'] == 'first-edit-trims-empty-value-attrs',
      );
      expect(trim['reason'], contains('updateAndTrim'));
    });

    test('state_trim: fork trims empty_value attrs, Dart keeps them (gap)', () {
      final st = _doc((buckets['state_trim']! as List).single);
      var doc = _doc(docs[st['doc']]!);
      for (final sj in st['steps']! as List) {
        final result = DocStep.fromJson(sj).apply(doc);
        expect(result.succ, isTrue);
        doc = result.doc!;
      }
      // Official: the first edit dropped heading4/5 padding as a side effect.
      expect(_canon(doc), isNot(_canon(st['result'])));
      // Dart: insert+delete is a pure no-op, so the raw doc is unchanged.
      expect(_canon(doc), _canon(docs['docBaseRaw']));
      // The divergence is exactly the registered paths.
      expect((st['trimmed_paths']! as List), isNotEmpty);
    });
  });

  tearDownAll(() {
    // A compact pass-rate table, printed once, for the report.
    final lines = categoryTotal.keys.toList()..sort();
    for (final c in lines) {
      // ignore: avoid_print
      print(
        'M2 vector pass rate [$c]: '
        '${categoryPass[c] ?? 0}/${categoryTotal[c]}',
      );
    }
  });
}

/// The exact step payloads used to build the `failure` vectors; kept next to
/// the assertions so the Dart side is not reading a re-serialised oracle.
Object? _failurePayload(String id) {
  switch (id) {
    case 'fromjson-unknown-step-type':
      return <String, Object?>{
        'stepType': 'dsh_bogus_step',
        'from': 0,
        'to': 0,
      };
    case 'apply-out-of-range-to':
      return <String, Object?>{
        'stepType': 'replace',
        'from': 0,
        'to': 999,
        'slice': null,
        'structure': false,
      };
    case 'apply-negative-from':
      return <String, Object?>{
        'stepType': 'replace',
        'from': -1,
        'to': 0,
        'slice': null,
        'structure': false,
      };
    case 'apply-inconsistent-open-depths':
      return <String, Object?>{
        'stepType': 'replace',
        'from': 20,
        'to': 36,
        'slice': null,
        'structure': true,
      };
    case 'apply-open-left-deeper-than-position':
      return <String, Object?>{
        'stepType': 'replace',
        'from': 21,
        'to': 21,
        'slice': <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'paragraph'},
          ],
          'openLeft': 3,
          'openRight': 3,
        },
        'structure': false,
      };
    case 'fromjson-unknown-mark-type':
      return <String, Object?>{
        'stepType': 'addMark',
        'from': 21,
        'to': 26,
        'mark': <String, Object?>{'_': 'dsh_bogus_mark'},
      };
    case 'apply-insert-beyond-doc':
      return <String, Object?>{
        'stepType': 'replace',
        'from': 71,
        'to': 71,
        'slice': <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'x'},
          ],
          'openLeft': 0,
          'openRight': 0,
        },
        'structure': false,
      };
    case 'fromjson-missing-optional-fields':
      return <String, Object?>{'stepType': 'replace', 'from': 26, 'to': 26};
    default:
      return null;
  }
}

DocJson _firstOfType(DocJson node, String type) {
  if (node['type'] == type) return node;
  for (final raw in (node['content'] as List?) ?? const <Object?>[]) {
    final child = (raw! as Map).cast<String, Object?>();
    final found = _firstOfType(child, type);
    if (found.isNotEmpty) return found;
  }
  return <String, Object?>{};
}

String _textOf(DocJson node) {
  if (node['type'] == 'text') return node['text'] as String? ?? '';
  final buffer = StringBuffer();
  for (final raw in (node['content'] as List?) ?? const <Object?>[]) {
    buffer.write(_textOf((raw! as Map).cast<String, Object?>()));
  }
  return buffer.toString();
}
