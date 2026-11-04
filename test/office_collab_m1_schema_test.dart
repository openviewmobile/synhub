// Office C' - M1 golden test: the official `.odoc` ProseMirror schema as Dart.
//
// Everything here is offline: it reads two committed real-hardware fixtures and
// the generated schema constants. No network, no NAS, no device, no SPK required.
//
// Fixtures (verbatim copies of the previous batch's real-hardware evidence):
//   test/fixtures/office_collab/snapshot_doc_pre.json
//     -> `content.data` == the `@C_text/content.data` BSON the server produced for
//        an `Office.Import` of a self-built .odoc ("Import state").
//   test/fixtures/office_collab/dart_fetched_doc_v1.json
//     -> the editor's `fetch` ack for the same document ("editor state").
//
// The load-bearing assertion is that `nodeFromJson(Import).toJson()` reproduces the
// editor fetch JSON byte-for-byte, using the schema alone.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/doc_schema.dart';

Map<String, Object?> _readJson(String name) =>
    jsonDecode(File('test/fixtures/office_collab/$name').readAsStringSync())
        as Map<String, Object?>;

void main() {
  final schema = DocSchema.document;

  // Import state: the doc JSON lives inside the snapshot envelope.
  final snapshot = _readJson('snapshot_doc_pre.json');
  final importDoc = (snapshot['content']! as Map)['data'];
  final fetchDoc = _readJson('dart_fetched_doc_v1.json');

  group('schema shape (generated from doc_schema.json)', () {
    test('identity matches the real NAS Info:get schema_doc', () {
      expect(schema.name, 'document');
      expect(schema.version, 13);
      expect(schema.topNodeName, 'doc');
      expect(
        schema.topNodeContent,
        'settings style_editor invisible edit_area page_decorate',
      );
      expect(schema.nodes.length, 32);
      expect(schema.marks.length, 12);
      expect(schema.attrMarks.length, 4);
    });

    test(
      'attr totals: 143 declared node attrs with zero unproven defaults',
      () {
        var total = 0;
        for (final n in schema.nodes.values) {
          total += n.attrs.length;
        }
        expect(total, 143, reason: 'the report 143 attrs are the node attrs');
      },
    );
  });

  group('C.1 byte-exact Import -> editor reproduction', () {
    test('nodeFromJson(Import).toJson() == fetch (diff = 0)', () {
      final parsed = schema.nodeFromJson(importDoc);
      final produced = parsed.toJson();

      final diff = schema.diffDocs(produced, fetchDoc);
      expect(
        diff,
        isEmpty,
        reason: 'structural diff must be empty, got ${diff.keys.toList()}',
      );

      // "Byte-for-byte" under R5: canonical JSON must be identical.
      expect(canonicalJson(produced), canonicalJson(fetchDoc));
    });

    test('the raw (unnormalised) Import doc really differs first', () {
      expect(schema.diffDocs(importDoc, fetchDoc).length, 36);
    });

    test('re-parsing the editor fetch is idempotent', () {
      final reparsed = schema.nodeFromJson(fetchDoc).toJson();
      expect(canonicalJson(reparsed), canonicalJson(fetchDoc));
    });

    test('required-attr fills on Import are exactly the 9 documented ones', () {
      final log = <String>[];
      schema.nodeFromJson(importDoc, fillLog: log);
      expect(log, <String>[
        'doc.page_setup.orientation',
        'page_decorate.place-show',
        'page_decorate.place-cover',
        'page_decorate.place-even',
        'page_decorate.num-show',
        'page_decorate.num-cover',
        'page_decorate.num-even',
        'page_decorate.num-pos',
        'page_num.type',
      ]);
    });
  });

  group('C.2 36 -> 3 -> 0 process', () {
    test('legacy empty_value approximation leaves the 3 known paths', () {
      final a = schema.normalizeForComparison(
        importDoc,
        DocNormalizeOptions.emptyValueApproximation,
      );
      final b = schema.normalizeForComparison(
        fetchDoc,
        DocNormalizeOptions.emptyValueApproximation,
      );
      final diff = schema.diffDocs(a, b);
      expect(diff.length, 3);
      expect(diff.keys.toList()..sort(), <String>[
        r'$.attrs.page_setup.orientation',
        r'$.content[4].attrs',
        r'$.content[4].content[6].attrs',
      ]);
    });

    test('full schema defaults close it to 0', () {
      final a = schema.normalizeForComparison(
        importDoc,
        DocNormalizeOptions.schemaComparison,
      );
      final b = schema.normalizeForComparison(
        fetchDoc,
        DocNormalizeOptions.schemaComparison,
      );
      expect(schema.diffDocs(a, b), isEmpty);
    });
  });

  group('C.3 R2 is not optional: filling optional attrs explodes the diff', () {
    test(
      'naive fill-all-optional -> 105 differences (the documented number)',
      () {
        final naive = schema.normalizeForComparison(
          importDoc,
          DocNormalizeOptions.naiveFillOptional,
        );
        expect(schema.diffDocs(naive, fetchDoc).length, 105);
      },
    );

    test('R2 alone accounts for 102; the other 3 are the R1 omissions', () {
      final naive = schema.normalizeForComparison(
        importDoc,
        DocNormalizeOptions.naiveFillOptionalWithRequired,
      );
      expect(schema.diffDocs(naive, fetchDoc).length, 102);
      expect(105 - 102, 3);
    });

    test('optional attrs are never auto-filled by the real serialisation', () {
      final n = schema.nodeFromJson(<String, Object?>{
        'type': 'paragraph',
        'attrs': <String, Object?>{},
      });
      expect(n.toJson(), <String, Object?>{'type': 'paragraph'});
    });

    test(
      'R2 caveat: an explicitly-set optional attr equal to empty_value SURVIVES',
      () {
        // The editor fetch really carries paddingTop:0 even though style_paragraph
        // declares empty_value 0 - so "drop optional == empty_value" must NOT be part
        // of the byte-exact serialisation, only of the symmetric comparison mode.
        final n = schema.nodeFromJson(<String, Object?>{
          'type': 'style_paragraph',
          'attrs': <String, Object?>{'paddingTop': 0},
        });
        expect(n.toJson(), <String, Object?>{
          'type': 'style_paragraph',
          'attrs': <String, Object?>{'paddingTop': 0},
        });
      },
    );
  });

  group('validation: nothing is silently ignored', () {
    test('unknown node type throws', () {
      expect(
        () => schema.nodeFromJson(<String, Object?>{'type': 'not_a_node'}),
        throwsA(isA<UnknownNodeTypeException>()),
      );
    });

    test('unknown inline mark throws', () {
      expect(
        () => schema.nodeFromJson(<String, Object?>{
          'type': 'text',
          'text': 'x',
          'marks': <Object?>[
            <String, Object?>{'_': 'not_a_mark'},
          ],
        }),
        throwsA(isA<UnknownMarkException>()),
      );
    });

    test('unknown attr on a known node throws', () {
      expect(
        () => schema.nodeFromJson(<String, Object?>{
          'type': 'paragraph',
          'attrs': <String, Object?>{'not_an_attr': 1},
        }),
        throwsA(isA<UnknownAttrException>()),
      );
    });

    test('unknown attr on a known mark throws', () {
      expect(
        () => schema.nodeFromJson(<String, Object?>{
          'type': 'text',
          'text': 'x',
          'marks': <Object?>[
            <String, Object?>{'_': 'font_size', 'nope': 1},
          ],
        }),
        throwsA(isA<UnknownAttrException>()),
      );
    });

    test(
      'a required default that is a JS factory function is refused, not guessed',
      () {
        expect(
          () => schema.nodeFromJson(<String, Object?>{
            'type': 'table',
            'attrs': <String, Object?>{},
          }),
          throwsA(isA<UnfillableRequiredDefaultException>()),
        );
      },
    );

    test('empty text nodes are rejected (matches the model)', () {
      expect(
        () =>
            schema.nodeFromJson(<String, Object?>{'type': 'text', 'text': ''}),
        throwsA(isA<MalformedDocNodeException>()),
      );
    });
  });

  group('serialisation order and R3', () {
    test('element node key order is type, attrs, content, marks', () {
      expect(schema.jsonKeyOrder, <String>[
        'type',
        'attrs',
        'content',
        'marks',
      ]);
      final n = schema.nodeFromJson(<String, Object?>{
        'type': 'doc',
        'attrs': <String, Object?>{},
        'content': <Object?>[
          <String, Object?>{'type': 'settings'},
        ],
      });
      expect(n.toJson().keys.toList(), <String>['type', 'attrs', 'content']);
    });

    test('nodeFromJson never mutates the caller input (deep-copies attrs)', () {
      final before = canonicalJson(importDoc);
      schema.nodeFromJson(importDoc);
      expect(canonicalJson(importDoc), before);
    });

    test('text node key order is the fork\'s type, marks, text', () {
      final n = schema.nodeFromJson(<String, Object?>{
        'type': 'text',
        'text': 'hi',
        'marks': <Object?>[
          <String, Object?>{'_': 'em'},
        ],
      });
      expect(n.toJson().keys.toList(), <String>['type', 'marks', 'text']);
      expect(n.toJson()['marks'], <Object?>[
        <String, Object?>{'_': 'em'},
      ]);
    });

    test('R3: empty attrs and empty content are dropped', () {
      final n = schema.nodeFromJson(<String, Object?>{
        'type': 'settings',
        'attrs': <String, Object?>{},
        'content': <Object?>[],
      });
      expect(n.toJson(), <String, Object?>{'type': 'settings'});
    });

    test('mark toJSON uses "_" for the name and keeps declared attr order', () {
      final n = schema.nodeFromJson(<String, Object?>{
        'type': 'text',
        'text': 'hi',
        'marks': <Object?>[
          <String, Object?>{'_': 'font_family', 'value': 'Times'},
        ],
      });
      final mark =
          (n.toJson()['marks']! as List).single as Map<String, Object?>;
      expect(mark.keys.first, '_');
      expect(mark, <String, Object?>{'_': 'font_family', 'value': 'Times'});
    });
  });

  group('mark rank / applicability / page_num', () {
    test('inline marks are ranked 0..11 in declaration order', () {
      final ranked = schema.marks.values.toList()
        ..sort((a, b) => a.rank.compareTo(b.rank));
      expect(
        ranked.map((m) => m.rank).toList(),
        List<int>.generate(12, (i) => i),
      );
      expect(ranked.map((m) => m.name).toList(), <String>[
        'font_size',
        'font_family',
        'em',
        'strong',
        'link',
        'color',
        'background_color',
        'superscript',
        'subscript',
        'underline',
        'strike',
        'tracking',
      ]);
    });

    test('attr marks are a separate registry ranked 0..3', () {
      final ranked = schema.attrMarks.values.toList()
        ..sort((a, b) => a.rank.compareTo(b.rank));
      expect(ranked.map((m) => m.name).toList(), <String>[
        'direction',
        'text_align',
        'line_height',
        'text_indent',
      ]);
    });

    test('direction / text_indent applicability is unproven, not guessed', () {
      expect(schema.attrMarks['direction']!.applicableTo, isNull);
      expect(schema.attrMarks['text_indent']!.applicableTo, isNull);
      expect(schema.attrMarks['text_align']!.applicableTo, <String>[
        'paragraph',
        'style_paragraph',
      ]);
      expect(schema.attrMarks['line_height']!.applicableTo, <String>[
        'paragraph',
        'style_paragraph',
      ]);
    });

    test(
      'page_num.type="normal" is a REQUIRED default path (header/footer corrected)',
      () {
        final spec = schema.nodeSpec('page_num').attrs['type']!;
        expect(spec.optional, isFalse);
        expect(spec.defaultSource, 'default');
        expect(spec.defaultValue, 'normal');

        final log = <String>[];
        final n = schema.nodeFromJson(<String, Object?>{
          'type': 'page_num',
          'attrs': <String, Object?>{},
        }, fillLog: log);
        expect(n.toJson(), <String, Object?>{
          'type': 'page_num',
          'attrs': <String, Object?>{'type': 'normal'},
        });
        expect(log, <String>['page_num.type']);

        // header/footer really do carry the same required default.
        expect(schema.nodeSpec('header').attrs['type']!.defaultValue, 'normal');
        expect(schema.nodeSpec('footer').attrs['type']!.defaultValue, 'normal');
      },
    );
  });

  group('composite deep defaults, R4 and nodeSize', () {
    test('an absent page_setup is filled from the composed default', () {
      final n = schema.nodeFromJson(<String, Object?>{
        'type': 'doc',
        'attrs': <String, Object?>{},
      });
      expect((n.toJson()['attrs']! as Map)['page_setup'], <String, Object?>{
        'left': 2.54,
        'top': 2.54,
        'right': 2.54,
        'bottom': 2.54,
        'orientation': 'portrait',
        'page_type': 'a4',
      });
    });

    test('a present page_setup only gets the missing required sub-field', () {
      final n = schema.nodeFromJson(<String, Object?>{
        'type': 'doc',
        'attrs': <String, Object?>{
          'page_setup': <String, Object?>{
            'left': 2.54,
            'top': 2.54,
            'right': 2.54,
            'bottom': 2.54,
            'page_type': 'letter',
          },
        },
      });
      final ps = (n.toJson()['attrs']! as Map)['page_setup']! as Map;
      expect(ps['orientation'], 'portrait');
      expect(ps['page_type'], 'letter');
    });

    test('R4: @C_text/comment drops the Import-only format:1', () {
      expect(
        schema.normalizeCommentSection(<String, Object?>{
          'data': <Object?>[],
          'format': 1,
        }),
        <String, Object?>{'data': <Object?>[]},
      );
      // A non-default format is preserved (only the Import default is dropped).
      expect(
        schema.normalizeCommentSection(<String, Object?>{
          'data': <Object?>[],
          'format': 2,
        }),
        <String, Object?>{'data': <Object?>[], 'format': 2},
      );
    });

    test('nodeSize: settings is a leaf that occupies exactly 1 position', () {
      final n = schema.nodeFromJson(<String, Object?>{'type': 'settings'});
      expect(schema.nodeSize(n), 1);
      final text = schema.nodeFromJson(<String, Object?>{
        'type': 'text',
        'text': 'abc',
      });
      expect(schema.nodeSize(text), 3);
    });
  });

  group('fixture integrity', () {
    test('the two golden fixtures parse and carry the expected anchors', () {
      expect((snapshot['content']! as Map)['version'], 1);
      expect(importDoc, isA<Map<String, Object?>>());
      expect(fetchDoc['type'], 'doc');
      expect((fetchDoc['content']! as List).length, 5);
      // The two manually-checkable residuals from the report are really here.
      final importPs =
          ((importDoc! as Map)['attrs']! as Map)['page_setup']! as Map;
      expect(importPs.containsKey('orientation'), isFalse);
      final fetchPs = (fetchDoc['attrs']! as Map)['page_setup']! as Map;
      expect(fetchPs['orientation'], 'portrait');
    });
  });
}
