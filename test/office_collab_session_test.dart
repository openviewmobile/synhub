// Office C' — M1 schema + M2 OT queue + M0 client session assembly, offline.
//
// The wire is the same `FakeCollabTransport` replay harness as
// `office_collab_client_test.dart`; the document is the committed real-hardware
// `dart_fetched_doc_v1.json` (editor `fetch` v1) and the real
// `snapshot_doc_pre.json` (`@C_text/content` Import state) from M1.
//
// No network, no NAS, no device, no build.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/doc_ot_queue.dart';
import 'package:synhub/src/data/office_collab/doc_step.dart' show DocJson;
import 'package:synhub/src/data/office_collab/doc_ot_session.dart';
import 'package:synhub/src/data/office_collab/doc_schema.dart';
import 'package:synhub/src/data/office_collab/office_collab_client.dart';

import 'office_collab_client_test.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/office_collab/$name').readAsStringSync())
        as Map<String, Object?>;

/// Insert [text] at ProseMirror position [pos] - the M0 `replace` shape.
Map<String, Object?> _insertStep(int pos, String text) => <String, Object?>{
  'stepType': 'replace',
  'from': pos,
  'to': pos,
  'slice': <String, Object?>{
    'content': <Object?>[
      <String, Object?>{'type': 'text', 'text': text},
    ],
    'openLeft': 0,
    'openRight': 0,
  },
  'structure': false,
};

const String _objectId = '1028_FATHU56MD53F5ARCP55HVG877S.doc';

String _fetchAck(int version, Map<String, Object?> doc, {int templateId = 1}) =>
    '43$templateId[null,{"doc":{"version":$version,"data":'
    '${jsonEncode(doc)},"comment_store":{}}}]';

String _eventConfirmed(int version, {int templateId = 1}) =>
    '43$templateId[null,{"id":"<redacted>","version":$version,"steps":[],'
    '"clientIDs":["dart01"],"selection":null}]';

String _eventError(int status, String message, {int templateId = 1}) =>
    '43$templateId[{"status":$status},"Error: $_objectId: $message"]';

String _pollAck(
  int version,
  List<Map<String, Object?>> steps, {
  int templateId = 1,
}) =>
    '43$templateId[null,{"version":$version,"wait":true,"steps":'
    '${jsonEncode(steps)},"clientIDs":["other"],"selections":[]}]';

List<ReplayExchange> _boot() => <ReplayExchange>[
  ReplayExchange('2probe', <String>['3probe']),
  ReplayExchange('5'),
  ReplayExchange('40', <String>['40{"sid":"<redacted>"}', '42["ready"]']),
];

List<ReplayExchange> _announce() => <ReplayExchange>[
  ReplayExchange('421["say_hello"]', <String>[
    '431[{"id":"<redacted>","serverId":"f663682760b06e48"}]',
  ]),
  ReplayExchange('422["ask_peers"]', <String>[
    '432[[{"id":"<redacted>","uid":1028,"selection":null,"nickname":"",'
        '"color":"#94bf13","guest_id":null,"name":"demo_user"}]]',
  ]),
];

void main() {
  final fetchDocV1 = _fixture('dart_fetched_doc_v1.json');
  final snapshotPre = _fixture('snapshot_doc_pre.json');
  final schema = DocSchema.document;

  DocOtSession newSession(FakeCollabTransport transport) => DocOtSession(
    client: OfficeCollabClient(
      target: OfficeCollabTarget(
        baseUrl: Uri.parse('https://nas.example.com:5001'),
        objectId: _objectId,
        linkId: '19yfWXfe2ZGfFb5oigOvzXifW0g5LZnn',
      ),
      transport: transport,
      sessionCookieId: 'test-sid-0123456789',
      reconnectDelay: const Duration(milliseconds: 5),
    ),
    schema: schema,
    clientId: 'dart01',
  );

  group('S1. M1 <-> M2 bridge and @C_text/content parsing', () {
    test(
      'DocNode.fromRawJson/toRawJson reproduces the M1 Import() == fetch() golden',
      () {
        final section = snapshotPre['content']! as Map;
        final content = OfficeCollabContent.parse(section);
        expect(content.version, 1);
        // The new public bridge is exactly the M1 golden path.
        final node = DocNode.fromRawJson(content.data);
        expect(canonicalJson(node.toRawJson()), canonicalJson(fetchDocV1));
        expect(schema.diffDocs(node.toRawJson(), fetchDocV1), isEmpty);
      },
    );

    test(
      'OfficeCollabContent.parse accepts both section and fetch wrappers',
      () {
        final section = OfficeCollabContent.parse(<String, Object?>{
          'data': fetchDocV1,
          'version': 1,
        });
        expect(section.version, 1);
        expect(canonicalJson(section.data), canonicalJson(fetchDocV1));

        final wrapped = OfficeCollabContent.parse(<String, Object?>{
          'doc': <String, Object?>{'version': 4, 'data': fetchDocV1},
        });
        expect(wrapped.version, 4);
      },
    );
  });

  // ★★ 第 310 轮：`fetch` **取不到内容**时必须能用"客户端预设"当会话基线
  // （官方 `content?.data || getDefaultDocJson()` 的协作面等价物）。
  group('S0b. r310：空文档的 fetch 与会话基线', () {
    /// `fetch` 回包里**只有 comment_store**（服务端没有文档内容）。
    const String fetchNoDoc = '431[null,{"doc":{"comment_store":{}}}]';

    DocOtSession sessionWith(FakeCollabTransport t, {DocJson? defaultDoc}) =>
        DocOtSession(
          client: OfficeCollabClient(
            target: OfficeCollabTarget(
              baseUrl: Uri.parse('https://nas.example.com:5001'),
              objectId: _objectId,
              linkId: '19yfWXfe2ZGfFb5oigOvzXifW0g5LZnn',
            ),
            transport: t,
            sessionCookieId: 'test-sid-0123456789',
          ),
          schema: schema,
          clientId: 'dart01',
          defaultDoc: defaultDoc,
        );

    FakeCollabTransport noDocTransport() => FakeCollabTransport(
      ReplayScript(
        <ReplayExchange>[
          ..._boot(),
          ..._announce(),
          ReplayExchange('423["fetch"]', <String>[fetchNoDoc]),
        ],
        handshakeBody:
            '0{"sid":"<redacted>","upgrades":["websocket"],'
            '"pingInterval":25000,"pingTimeout":60000}',
      ),
    );

    /// 与 `OfficeDocPage` 的编辑判定同址的树：`doc → edit_area → paragraph`。
    final seed = <String, Object?>{
      'type': 'doc',
      'attrs': <String, Object?>{'schema': 13},
      'content': <Object?>[
        <String, Object?>{
          'type': 'edit_area',
          'attrs': <String, Object?>{},
          'content': <Object?>[
            <String, Object?>{
              'type': 'paragraph',
              'attrs': <String, Object?>{},
              'content': <Object?>[],
            },
          ],
        },
      ],
    };

    test('★ 空 fetch + defaultDoc ⇒ 队列以预设为基线（version 0、含 edit_area）', () async {
      final session = sessionWith(noDocTransport(), defaultDoc: seed);
      addTearDown(session.close);
      await session.open();
      expect(session.doc, isNotNull, reason: '不许让会话"没有文档"');
      expect(session.version, 0, reason: '服务端还没有这一版');
      // 编辑判定（`isEditablePath`）就是在这棵树上找 `edit_area`。
      expect(session.doc.toString(), contains('edit_area'));
      expect(session.isSynced, isTrue);
    });

    test('★ 空 fetch + 没有 defaultDoc ⇒ 照旧失败（不静默伪造文档）', () async {
      final session = sessionWith(noDocTransport());
      addTearDown(session.close);
      await expectLater(
        session.open(),
        throwsA(isA<OfficeCollabException>()),
      );
    });

    test('★ 有内容的 fetch 不受 defaultDoc 影响（不许拿预设顶掉服务端文档）', () async {
      final session = sessionWith(
        FakeCollabTransport(
          ReplayScript(
            <ReplayExchange>[
              ..._boot(),
              ..._announce(),
              ReplayExchange('423["fetch"]', <String>[
                _fetchAck(7, fetchDocV1),
              ]),
            ],
            handshakeBody:
                '0{"sid":"<redacted>","upgrades":["websocket"],'
                '"pingInterval":25000,"pingTimeout":60000}',
          ),
        ),
        defaultDoc: seed,
      );
      addTearDown(session.close);
      await session.open();
      expect(session.version, 7, reason: '服务端版本不许被 0 顶掉');
      expect(session.doc.toString(), contains('_heading'), reason: '拿的是服务端那棵树');
    });
  });

  group('S2. fetch -> localEdit -> ack', () {
    test(
      'a confirmed edit drains the queue and advances the version',
      () async {
        final transport = FakeCollabTransport(
          ReplayScript(
            <ReplayExchange>[
              ..._boot(),
              ..._announce(),
              ReplayExchange('423["fetch"]', <String>[
                _fetchAck(1, fetchDocV1),
              ]),
              ReplayExchange('424["event",{}]', <String>[_eventConfirmed(2)]),
            ],
            handshakeBody:
                '0{"sid":"<redacted>","upgrades":["websocket"],'
                '"pingInterval":25000,"pingTimeout":60000}',
          ),
        );
        final session = newSession(transport);
        addTearDown(session.close);

        await session.open();
        expect(session.isSynced, isTrue);
        expect(session.version, 1);
        expect(session.pendingCount, 0);
        expect(canonicalJson(session.doc), canonicalJson(fetchDocV1));

        final outcome = await session.localEditJson(_insertStep(37, '#'));
        expect(outcome.kind, DocOtAckKind.confirmed);
        expect(session.version, 2);
        expect(session.pendingCount, 0);
        expect(session.hasUnconfirmed, isFalse);
        expect(jsonEncode(session.doc), contains('C3SPIKE-DOC-BASE#'));
        expect(session.docNode.type, 'doc');
        expect(transport.mismatch, isNull);
      },
    );

    test(
      'structure is not sent by default but is available behind the switch',
      () async {
        final transport = FakeCollabTransport(
          ReplayScript(
            <ReplayExchange>[
              ..._boot(),
              ..._announce(),
              ReplayExchange('423["fetch"]', <String>[
                _fetchAck(1, fetchDocV1),
              ]),
              ReplayExchange('424["event",{}]', <String>[_eventConfirmed(2)]),
            ],
            handshakeBody:
                '0{"sid":"<redacted>","upgrades":["websocket"],'
                '"pingInterval":25000,"pingTimeout":60000}',
          ),
        );
        final session = newSession(transport);
        addTearDown(session.close);
        await session.open();
        await session.localEditJson(_insertStep(37, '#'));

        final frame = transport.sent.firstWhere(
          (f) => replayKeyOf(f) == 'ev:event',
        );
        final data =
            (jsonDecode(SioPacket.parse(frame.substring(1)).payload) as List)[1]
                as Map;
        // Ruling ②: the server's ReplaceStep.fromJSON ignores `structure`.
        expect((data['steps']! as List).first, isNot(contains('structure')));
      },
    );
  });

  group(
    'S3. 402 Not current version -> refetch increment + rebase + resend',
    () {
      test('the resent step is rebased and the version converges', () async {
        final remote = _insertStep(30, 'R');
        final transport = FakeCollabTransport(
          ReplayScript(
            <ReplayExchange>[
              ..._boot(),
              ..._announce(),
              ReplayExchange('423["fetch"]', <String>[
                _fetchAck(1, fetchDocV1),
              ]),
              // Our local step was composed against v1; the server moved to v2.
              ReplayExchange('424["event",{}]', <String>[
                _eventError(
                  402,
                  'Not current version. incoming: 1, current: 2',
                ),
              ]),
              // Recovery: poll the increment from the confirmed version 1.
              ReplayExchange('425["poll",{}]', <String>[
                _pollAck(2, [remote]),
              ]),
              // Resend the rebased step at version 2 -> confirmed, server at 3.
              ReplayExchange('426["event",{}]', <String>[_eventConfirmed(3)]),
            ],
            handshakeBody:
                '0{"sid":"<redacted>","upgrades":["websocket"],'
                '"pingInterval":25000,"pingTimeout":60000}',
          ),
        );
        final session = newSession(transport);
        addTearDown(session.close);
        await session.open();

        final outcome = await session.localEditJson(_insertStep(37, '#'));
        expect(outcome.kind, DocOtAckKind.confirmed);
        expect(outcome.version, 3);
        expect(session.version, 3);
        expect(session.pendingCount, 0);
        expect(session.lastRebase, isNotNull);
        expect(session.lastRebase!.droppedAny, isFalse);
        expect(session.recoveryLog.join('\n'), contains('rebasing'));

        final eventFrames = transport.sent
            .where((f) => replayKeyOf(f) == 'ev:event')
            .toList();
        expect(eventFrames, hasLength(2));
        final first =
            jsonDecode(SioPacket.parse(eventFrames[0].substring(1)).payload)
                as List;
        final second =
            jsonDecode(SioPacket.parse(eventFrames[1].substring(1)).payload)
                as List;
        expect((first[1] as Map)['version'], 1);
        expect((second[1] as Map)['version'], 2);
        // The remote insert of 'R' at 30 shifted the local '#' insert 37 -> 38.
        expect(
          (((second[1] as Map)['steps']! as List).first as Map)['from'],
          38,
        );

        // Both edits are in the converged document.
        final text = jsonEncode(session.doc);
        expect(text, contains('R'));
        expect(text, contains('C3SPIKE-DROC-BASE#'));
        expect(transport.mismatch, isNull);
      });

      test(
        '402 without a poll increment falls back to a full refetch',
        () async {
          final transport = FakeCollabTransport(
            ReplayScript(
              <ReplayExchange>[
                ..._boot(),
                ..._announce(),
                ReplayExchange('423["fetch"]', <String>[
                  _fetchAck(1, fetchDocV1),
                ]),
                ReplayExchange('424["event",{}]', <String>[
                  _eventError(
                    402,
                    'Not current version. incoming: 1, current: 2',
                  ),
                ]),
                // poll returns no steps -> no usable rebase.
                ReplayExchange('425["poll",{}]', <String>[_pollAck(2, [])]),
                ReplayExchange('426["fetch"]', <String>[
                  _fetchAck(2, fetchDocV1),
                ]),
              ],
              handshakeBody:
                  '0{"sid":"<redacted>","upgrades":["websocket"],'
                  '"pingInterval":25000,"pingTimeout":60000}',
            ),
          );
          final session = newSession(transport);
          addTearDown(session.close);
          await session.open();

          final outcome = await session.localEditJson(_insertStep(37, '#'));
          expect(outcome.kind, DocOtAckKind.versionNotCurrent);
          expect(session.version, 2);
          expect(session.pendingCount, 0);
          expect(session.recoveryLog.join('\n'), contains('full refetch'));
          // The unconfirmed local edit was rolled back to the server doc.
          expect(jsonEncode(session.doc), isNot(contains('C3SPIKE-DOC-BASE#')));
        },
      );
    },
  );

  group('S4. 411 Invalid command -> dropInvalidStep', () {
    test('the offending step is dropped, confirmed state is kept', () async {
      final transport = FakeCollabTransport(
        ReplayScript(
          <ReplayExchange>[
            ..._boot(),
            ..._announce(),
            ReplayExchange('423["fetch"]', <String>[_fetchAck(1, fetchDocV1)]),
            ReplayExchange('424["event",{}]', <String>[_eventConfirmed(2)]),
            ReplayExchange('425["event",{}]', <String>[
              _eventError(411, 'Invalid command'),
            ]),
          ],
          handshakeBody:
              '0{"sid":"<redacted>","upgrades":["websocket"],'
              '"pingInterval":25000,"pingTimeout":60000}',
        ),
      );
      final session = newSession(transport);
      addTearDown(session.close);
      await session.open();

      // A: confirmed -> doc now contains '#'.
      await session.localEditJson(_insertStep(37, '#'));
      expect(session.version, 2);
      expect(session.pendingCount, 0);

      // B: rejected with 411 -> dropped, confirmed doc (with '#') survives.
      final outcome = await session.localEditJson(_insertStep(38, 'B'));
      expect(outcome.kind, DocOtAckKind.invalidCommand);
      expect(session.pendingCount, 0);
      expect(session.hasUnconfirmed, isFalse);
      expect(
        session.version,
        2,
        reason: 'a dropped step must not bump the version',
      );
      expect(jsonEncode(session.doc), contains('C3SPIKE-DOC-BASE#'));
      expect(jsonEncode(session.doc), isNot(contains('C3SPIKE-DOC-BASE#B')));
      expect(
        session.recoveryLog.join('\n'),
        contains('411: dropped invalid step'),
      );
      // No resend: the queue was empty after the drop.
      expect(
        transport.sent.where((f) => replayKeyOf(f) == 'ev:event'),
        hasLength(2),
      );
    });
  });

  group('S5. reconnect -> re-fetch', () {
    test('the session re-fetches after the client reconnects', () async {
      final script = ReplayScript(
        <ReplayExchange>[
          ..._boot(),
          ..._announce(),
          ReplayExchange('423["fetch"]', <String>[_fetchAck(1, fetchDocV1)]),
          // Second connection after the drop: no announce, just the re-fetch.
          ..._boot(),
          ReplayExchange('424["fetch"]', <String>[_fetchAck(1, fetchDocV1)]),
        ],
        handshakeBody:
            '0{"sid":"<redacted>","upgrades":["websocket"],'
            '"pingInterval":25000,"pingTimeout":60000}',
      );
      final transport = FakeCollabTransport(script);
      final session = newSession(transport);
      addTearDown(session.close);

      var fetched = 0;
      final firstFetch = Completer<void>();
      final refetched = Completer<void>();
      final sub = session.events.listen((e) {
        if (e.kind == DocOtSessionEventKind.fetched) {
          fetched++;
          if (fetched >= 1 && !firstFetch.isCompleted) firstFetch.complete();
          if (fetched >= 2 && !refetched.isCompleted) refetched.complete();
        }
      });
      addTearDown(sub.cancel);

      await session.open();
      await firstFetch.future.timeout(const Duration(seconds: 5));
      expect(fetched, 1);

      final reconnected = session.client.onReconnected.first;
      transport.dropConnection();
      await reconnected.timeout(const Duration(seconds: 5));
      await refetched.future.timeout(const Duration(seconds: 5));

      expect(fetched, 2);
      expect(session.version, 1);
      expect(transport.handshakeCount, 2);
      expect(transport.mismatch, isNull);
    });
  });
}
