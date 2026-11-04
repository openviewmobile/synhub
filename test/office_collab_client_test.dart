// Office C' — M0 client, offline replay test.
//
// Everything runs against `FakeCollabTransport`, which replays the **real device
// frames** recorded in `test/fixtures/office_collab/replay_doc_write.json` and
// `replay_docneg.json`. No network, no NAS, no device, no socket dependency.
//
// The harness (`ReplayScript` / `ReplayExchange` / `FakeCollabTransport`) is
// shared with `office_collab_session_test.dart`.
//
// Fixture provenance / masking (also written into each fixture):
//   * source: `/tmp/office-collab-spike/evid/dart_frames_doc_write.json` and
//     `…_docneg.json` (M0 live spike, docs/office-collab-protocol-spike.md);
//   * the document was a self-created temporary `.odoc` (body "C3SPIKE-DOC-BASE"),
//     deleted after the M0 batch (RESIDUE: []) — its content is kept;
//   * only c2s/s2c protocol frames are kept (HTTP "notice" frames, which embed the
//     sid in the URL, are dropped);
//   * every `"sid":"…"` / `"id":"…"` value is replaced with `"<redacted>"`
//     (session ids, `cECmOpww…` level).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/office_collab_client.dart';

// ---------------------------------------------------------------------------
// Replay harness (shared)
// ---------------------------------------------------------------------------

abstract final class ReplayDir {
  static const String c2s = 'c2s';
  static const String s2c = 's2c';
}

/// One recorded request/response exchange: the client frame `c2s` (template; its
/// ack id is patched to whatever id the client actually used) and the server
/// frames that followed it before the next c2s frame.
class ReplayExchange {
  ReplayExchange(this.c2s, [List<String>? s2c]) : s2c = s2c ?? <String>[];

  final String c2s;
  final List<String> s2c;

  late final String key = replayKeyOf(c2s);
}

/// The ordered exchanges of one (or more) recorded connections.
class ReplayScript {
  ReplayScript(this.exchanges, {required this.handshakeBody});

  final List<ReplayExchange> exchanges;
  final String handshakeBody;

  /// Builds the script from a `replay_*.json` fixture. Frames before the first
  /// c2s frame form the engine.io polling handshake body.
  factory ReplayScript.fromFixture(Map<String, Object?> fixture) {
    final frames = (fixture['frames']! as List).cast<Map>();
    final handshake = <String>[];
    final exchanges = <ReplayExchange>[];
    ReplayExchange? current;
    for (final f in frames) {
      final raw = f['raw']! as String;
      if (f['dir'] == ReplayDir.s2c) {
        if (current == null) {
          handshake.add(raw);
        } else {
          current.s2c.add(raw);
        }
      } else if (f['dir'] == ReplayDir.c2s) {
        current = ReplayExchange(raw);
        exchanges.add(current);
      }
    }
    return ReplayScript(exchanges, handshakeBody: handshake.join('\u001e'));
  }
}

/// Request key: engine probes verbatim, Socket.IO frames by type/event name
/// (ack ids excluded, so replay survives the client's own id numbering).
String replayKeyOf(String raw) {
  if (raw == '2probe') return 'eio:2probe';
  if (raw == '5') return 'eio:5';
  if (raw == '3') return 'eio:3';
  if (raw == '1') return 'eio:1';
  if (raw.startsWith('4')) {
    final p = SioPacket.parse(raw.substring(1));
    switch (p.type) {
      case SioPacketType.connect:
        return 'sio:connect';
      case SioPacketType.event:
        Object? decoded;
        try {
          decoded = jsonDecode(p.payload);
        } catch (_) {
          decoded = null;
        }
        final name = decoded is List && decoded.isNotEmpty
            ? decoded.first.toString()
            : '?';
        return 'ev:$name';
      default:
        return 'sio:t${p.type}';
    }
  }
  return 'raw:$raw';
}

/// The ack id the client used in a request frame, if any.
int? replayRequestAckId(String raw) {
  if (!raw.startsWith('4')) return null;
  try {
    return SioPacket.parse(raw.substring(1)).ackId;
  } on OfficeCollabProtocolException {
    return null;
  }
}

/// Rewrites `43<templateId>[…]` to carry the id the client actually used.
String patchAckId(String s2c, int? id) {
  if (id == null || !s2c.startsWith('43')) return s2c;
  final m = RegExp(r'^43\d+').firstMatch(s2c);
  if (m == null) return s2c;
  return '43$id${s2c.substring(m.end)}';
}

class _FakeWs implements OfficeCollabWsChannel {
  final StreamController<String> _controller = StreamController<String>();
  void Function(String)? onSend;
  bool isClosed = false;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  void send(String text) {
    if (!isClosed) onSend?.call(text);
  }

  void deliver(String frame) {
    if (!_controller.isClosed) _controller.add(frame);
  }

  void drop() {
    isClosed = true;
    if (!_controller.isClosed) unawaited(_controller.close());
  }

  @override
  Future<void> close() async {
    isClosed = true;
    if (!_controller.isClosed) await _controller.close();
  }
}

/// An injectable transport that replays a [ReplayScript] and records every c2s
/// frame the client sent.
class FakeCollabTransport implements OfficeCollabTransport {
  FakeCollabTransport(this.script, {this.withholdReady = false});

  final ReplayScript script;

  /// When true, `42["ready"]` is not delivered until [releaseReady] is called,
  /// so the ready gate can be observed from the outside.
  bool withholdReady;

  /// Every raw frame the client sent, in order.
  final List<String> sent = <String>[];
  final List<Uri> wsUris = <Uri>[];

  int handshakeCount = 0;
  String? mismatch;
  final List<String> skipped = <String>[];

  _FakeWs? _ws;
  final List<String> _withheld = <String>[];
  final List<String> deliveredS2c = <String>[];
  int _cursor = 0;

  @override
  Future<String> pollingGet(Uri uri, Map<String, String> headers) async {
    if (!uri.queryParameters.containsKey('sid')) {
      handshakeCount++;
      return script.handshakeBody;
    }
    return '';
  }

  @override
  Future<String> pollingPost(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    sent.add(body);
    _respond(body);
    return 'ok';
  }

  @override
  Future<OfficeCollabWsChannel> openWebSocket(
    Uri uri,
    Map<String, String> headers,
  ) async {
    wsUris.add(uri);
    final ws = _FakeWs();
    _ws = ws;
    ws.onSend = (text) {
      sent.add(text);
      _respond(text);
    };
    return ws;
  }

  @override
  Future<void> dispose() async {}

  void _respond(String raw) {
    final exchange = _take(replayKeyOf(raw));
    if (exchange == null) {
      mismatch ??= 'unexpected c2s frame: $raw';
      return;
    }
    final id = replayRequestAckId(raw);
    for (final template in exchange.s2c) {
      final frame = patchAckId(template, id);
      if (withholdReady && frame == '42["ready"]') {
        _withheld.add(frame);
        continue;
      }
      _deliver(frame);
    }
  }

  ReplayExchange? _take(String key) {
    if (_cursor < script.exchanges.length &&
        script.exchanges[_cursor].key == key) {
      return script.exchanges[_cursor++];
    }
    for (var i = _cursor; i < script.exchanges.length; i++) {
      if (script.exchanges[i].key == key) {
        for (var j = _cursor; j < i; j++) {
          skipped.add(script.exchanges[j].c2s);
        }
        final e = script.exchanges[i];
        _cursor = i + 1;
        return e;
      }
    }
    return null;
  }

  void _deliver(String frame) {
    final ws = _ws;
    if (ws == null || ws.isClosed) return;
    deliveredS2c.add(frame);
    ws.deliver(frame);
  }

  /// Injects a server frame out of band (e.g. the engine.io ping `2`).
  void inject(String frame) => _deliver(frame);

  /// Delivers the withheld `42["ready"]`.
  void releaseReady() {
    final frames = List<String>.of(_withheld);
    _withheld.clear();
    for (final frame in frames) {
      _deliver(frame);
    }
  }

  /// Simulates the socket dying so the client has to reconnect.
  void dropConnection() => _ws?.drop();
}

// ---------------------------------------------------------------------------
// Fixtures / helpers
// ---------------------------------------------------------------------------

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/office_collab/$name').readAsStringSync())
        as Map<String, Object?>;

List<Map> _frames(Map<String, Object?> fixture) =>
    (fixture['frames']! as List).cast<Map>();

List<String> _framesWithDir(Map<String, Object?> fixture, String dir) =>
    _frames(
      fixture,
    ).where((f) => f['dir'] == dir).map((f) => f['raw']! as String).toList();

/// The `data` argument of the fixture c2s event frame with [seq].
Object? _eventData(Map<String, Object?> fixture, int seq) {
  final raw =
      _frames(fixture).firstWhere(
            (f) => f['seq'] == seq && f['dir'] == ReplayDir.c2s,
          )['raw']!
          as String;
  final packet = SioPacket.parse(raw.substring(1));
  final list = jsonDecode(packet.payload) as List;
  return list.length > 1 ? list[1] : null;
}

OfficeCollabTarget _target() => OfficeCollabTarget(
  baseUrl: Uri.parse('https://nas.example.com:5001'),
  objectId: '1028_FATHU56MD53F5ARCP55HVG877S.doc',
  linkId: '19yfWXfe2ZGfFb5oigOvzXifW0g5LZnn',
);

OfficeCollabClient _client(FakeCollabTransport transport) => OfficeCollabClient(
  target: _target(),
  transport: transport,
  sessionCookieId: 'test-sid-0123456789',
  reconnectDelay: const Duration(milliseconds: 5),
);

const String _handshakeBody =
    '0{"sid":"<redacted>","upgrades":["websocket"],"pingInterval":25000,'
    '"pingTimeout":60000,"maxPayload":100000000}';

void main() {
  final writeFixture = _fixture('replay_doc_write.json');
  final negFixture = _fixture('replay_docneg.json');

  group('A. offline replay of the real M0 doc write frames', () {
    test('c2s frames are byte-identical to the device spike', () async {
      final transport = FakeCollabTransport(
        ReplayScript.fromFixture(writeFixture),
      );
      final client = _client(transport);
      addTearDown(client.close);

      await client.connect();
      expect(client.state, OfficeCollabState.ready);
      expect(client.usingWebSocket, isTrue);
      expect(transport.handshakeCount, 1);

      await client.emit('say_hello');
      await client.emit('ask_peers');
      await client.emit('fetch');
      await client.emit('event', _eventData(writeFixture, 18));
      await client.emit('save', <String, Object?>{});
      await client.emit('poll', <String, Object?>{'version': 1});

      expect(transport.mismatch, isNull);
      expect(transport.skipped, isEmpty);
      // The strongest assertion: every frame we put on the wire is exactly the
      // frame the M0 spike put on the wire.
      expect(transport.sent, _framesWithDir(writeFixture, ReplayDir.c2s));
    });

    test('fetch/event/save/poll acks route to the right callers', () async {
      final transport = FakeCollabTransport(
        ReplayScript.fromFixture(writeFixture),
      );
      final client = _client(transport);
      addTearDown(client.close);
      await client.connect();

      final hello = await client.emit('say_hello');
      expect(collabAckPayload(hello), isA<Map>());
      expect((collabAckPayload(hello)! as Map)['serverId'], 'f663682760b06e48');

      final peers = await client.emit('ask_peers');
      final peerList = collabAckPayload(peers);
      expect(peerList, isA<List>());
      expect((peerList! as List).first, isA<Map>());

      final fetch = await client.emit('fetch');
      expect(classifyCollabReply(fetch), OfficeCollabErrorKind.ok);
      final doc = (collabAckPayload(fetch)! as Map)['doc']! as Map;
      expect(doc['version'], 1);
      expect((doc['data']! as Map)['type'], 'doc');

      final event = await client.emit('event', _eventData(writeFixture, 18));
      expect(classifyCollabReply(event), OfficeCollabErrorKind.ok);
      final eventDoc = collabAckPayload(event)! as Map;
      expect(eventDoc['version'], 2);
      expect((eventDoc['clientIDs']! as List), contains('spikedart01'));

      final save = await client.emit('save', <String, Object?>{});
      final savePayload = collabAckPayload(save)! as Map;
      expect(savePayload['success'], isTrue);
      expect(
        savePayload['snapshot_version'],
        '6346a6c1b3848e9a2d712225ca75095dc1e47f09',
      );

      final poll = await client.emit('poll', <String, Object?>{'version': 1});
      expect((collabAckPayload(poll)! as Map)['version'], 2);
    });

    test('no sid survives into the client frame trace', () async {
      final transport = FakeCollabTransport(
        ReplayScript.fromFixture(writeFixture),
      );
      final client = _client(transport);
      addTearDown(client.close);
      await client.connect();
      await client.emit('say_hello');

      final raw = client.frames.map((f) => f.raw).join('\n');
      // The real fixture ids before masking were 0-FLZ_2taHUi8pUsAAAp and
      // 4Ppx9Zak-kN6CrSvAAAq; neither may appear anywhere.
      expect(raw, isNot(contains('0-FLZ_2taHUi8pUsAAAp')));
      expect(raw, isNot(contains('4Ppx9Zak-kN6CrSvAAAq')));
      expect(raw, contains('<redacted>'));
    });
  });

  group('B. ready gate (M0 gate B)', () {
    test('emit before 42["ready"] is refused and nothing is sent', () async {
      final transport = FakeCollabTransport(
        ReplayScript.fromFixture(writeFixture),
        withholdReady: true,
      );
      final client = _client(transport);
      addTearDown(client.close);

      await client.open();
      expect(client.state, OfficeCollabState.connected);
      expect(client.isReady, isFalse);
      final before = List<String>.of(transport.sent);

      await expectLater(
        client.emit('fetch'),
        throwsA(isA<OfficeCollabNotReadyException>()),
      );
      // The gate is local: no fetch frame reached the transport.
      expect(transport.sent, before);
      expect(
        transport.sent.where((f) => replayKeyOf(f) == 'ev:fetch'),
        isEmpty,
      );

      transport.releaseReady();
      await client.waitReady();
      expect(client.state, OfficeCollabState.ready);
      final hello = await client.emit('say_hello');
      expect(collabAckPayload(hello), isNotNull);
    });
  });

  group('C. error model (402 / 411 / 44)', () {
    test(
      '402 and 411 are classified from the real negative-probe frames',
      () async {
        final transport = FakeCollabTransport(
          ReplayScript.fromFixture(negFixture),
        );
        final client = _client(transport);
        addTearDown(client.close);
        await client.connect();

        await client.emit('say_hello');
        await client.emit('ask_peers');
        final fetch = await client.emit('fetch');
        expect((collabAckPayload(fetch)! as Map)['doc'], isA<Map>());
        expect(
          ((collabAckPayload(fetch)! as Map)['doc']! as Map)['version'],
          2,
        );

        final notCurrent = await client.emit(
          'event',
          _eventData(negFixture, 17),
        );
        expect(
          classifyCollabReply(notCurrent),
          OfficeCollabErrorKind.notCurrentVersion,
        );
        expect(collabAckStatus(notCurrent), 402);
        expect(
          collabAckMessage(notCurrent),
          contains('Not current version. incoming: 7, current: 2'),
        );

        final invalid = await client.emit('event', _eventData(negFixture, 19));
        expect(
          classifyCollabReply(invalid),
          OfficeCollabErrorKind.invalidCommand,
        );
        expect(collabAckStatus(invalid), 411);
        expect(collabAckMessage(invalid), contains('Invalid command'));

        // Both negative probes left the server state untouched: version stays 2.
        final refetch = await client.emit('fetch');
        expect(
          ((collabAckPayload(refetch)! as Map)['doc']! as Map)['version'],
          2,
        );
        expect(transport.sent, _framesWithDir(negFixture, ReplayDir.c2s));
        expect(transport.mismatch, isNull);
      },
    );

    test('44 Permission denied maps to a typed exception', () async {
      final script = ReplayScript(<ReplayExchange>[
        ReplayExchange('2probe', <String>['3probe']),
        ReplayExchange('5'),
        ReplayExchange('40', <String>['44{"message":"Permission denied"}']),
      ], handshakeBody: _handshakeBody);
      final transport = FakeCollabTransport(script);
      final client = _client(transport);
      addTearDown(client.close);

      await expectLater(
        client.connect(),
        throwsA(isA<OfficeCollabPermissionDeniedException>()),
      );
      expect(
        classifyCollabReply(<String, Object?>{'message': 'Permission denied'}),
        OfficeCollabErrorKind.permissionDenied,
      );
    });

    test('objectId/linkId swap is rejected before any socket is opened', () {
      final linkId = '19yfWXfe2ZGfFb5oigOvzXifW0g5LZnn';
      final objectId = '1028_FATHU56MD53F5ARCP55HVG877S.doc';
      final base = Uri.parse('https://nas.example.com:5001');

      // objectId = permanent_link (exactly the M0 mistake).
      expect(
        () =>
            OfficeCollabTarget(baseUrl: base, objectId: linkId, linkId: linkId),
        throwsA(isA<OfficeCollabConfigException>()),
      );
      // linkId = object_id.
      expect(
        () => OfficeCollabTarget(
          baseUrl: base,
          objectId: objectId,
          linkId: objectId,
        ),
        throwsA(isA<OfficeCollabConfigException>()),
      );
      // The valid pair derives the M0 namespace.
      final ok = OfficeCollabTarget(
        baseUrl: base,
        objectId: objectId,
        linkId: linkId,
      );
      expect(ok.namespace, 'doc');
      expect(ok.path, '/oo/socket.io/doc');
    });
  });

  group('D. heartbeat and reconnect', () {
    test(
      'handshake intervals are honoured and a server ping gets a pong',
      () async {
        final transport = FakeCollabTransport(
          ReplayScript.fromFixture(writeFixture),
        );
        final client = _client(transport);
        addTearDown(client.close);
        await client.connect();

        expect(client.pingInterval, const Duration(milliseconds: 25000));
        expect(client.pingTimeout, const Duration(milliseconds: 60000));

        transport.inject('2');
        await Future<void>.delayed(Duration.zero);
        expect(transport.sent, contains('3'));
      },
    );

    test('a dropped socket reconnects and re-runs the handshake', () async {
      final script = ReplayScript(<ReplayExchange>[
        ReplayExchange('2probe', <String>['3probe']),
        ReplayExchange('5'),
        ReplayExchange('40', <String>['40{"sid":"<redacted>"}', '42["ready"]']),
        ReplayExchange('421["say_hello"]', <String>[
          '431[{"id":"<redacted>","serverId":"f663682760b06e48"}]',
        ]),
        // Second connection, after the drop.
        ReplayExchange('2probe', <String>['3probe']),
        ReplayExchange('5'),
        ReplayExchange('40', <String>['40{"sid":"<redacted>"}', '42["ready"]']),
      ], handshakeBody: _handshakeBody);
      final transport = FakeCollabTransport(script);
      final client = _client(transport);
      addTearDown(client.close);
      await client.connect();
      await client.emit('say_hello');

      final reconnected = client.onReconnected.first;
      transport.dropConnection();
      await reconnected.timeout(const Duration(seconds: 5));

      expect(client.state, OfficeCollabState.ready);
      expect(transport.handshakeCount, 2);
      expect(transport.wsUris, hasLength(2));
      expect(transport.mismatch, isNull);
    });
  });

  group('E. classifyCollabReply sees the real save ack (UI batch 2 fix)', () {
    /// The exact device frame `replay_doc_write.json` seq21, decoded to the ack
    /// list the session/UI receives.
    List<Object?> realSaveAck() {
      final raw =
          _frames(writeFixture).firstWhere(
                (f) => f['seq'] == 21 && f['dir'] == ReplayDir.s2c,
              )['raw']!
              as String;
      final packet = SioPacket.parse(raw.substring(1));
      return (jsonDecode(packet.payload) as List).cast<Object?>();
    }

    test('真机 save 成功帧 → ok（修复前落到 other，UI 无法走统一分类）', () {
      final reply = realSaveAck();
      // 首元素就是结果对象，没有 `status` —— 这正是旧实现误判的原因。
      expect(reply, hasLength(1));
      expect((reply.first as Map).containsKey('status'), isFalse);
      expect(classifyCollabReply(reply), OfficeCollabErrorKind.ok);
      expect(
        (collabAckPayload(reply)! as Map)['snapshot_version'],
        '6346a6c1b3848e9a2d712225ca75095dc1e47f09',
      );
    });

    test('success:false 仍是 other：失败帧未取证，不提升为 ok', () {
      expect(
        classifyCollabReply(jsonDecode('[{"success":false,"code":500}]')),
        OfficeCollabErrorKind.other,
      );
    });

    test('既有语义不回归：ok / 402 / 411 / permission denied / 未知', () {
      expect(
        classifyCollabReply(jsonDecode('[null,{"version":2}]')),
        OfficeCollabErrorKind.ok,
      );
      expect(
        classifyCollabReply(
          jsonDecode('[{"status":402},"Error: Not current version"]'),
        ),
        OfficeCollabErrorKind.notCurrentVersion,
      );
      expect(
        classifyCollabReply(jsonDecode('[{"status":411},"Error: Invalid"]')),
        OfficeCollabErrorKind.invalidCommand,
      );
      expect(
        classifyCollabReply(jsonDecode('{"message":"Permission denied"}')),
        OfficeCollabErrorKind.permissionDenied,
      );
      // 没有 status、也没有 success 的 Map 仍然是 other。
      expect(
        classifyCollabReply(jsonDecode('[{"foo":1}]')),
        OfficeCollabErrorKind.other,
      );
      expect(classifyCollabReply('nope'), OfficeCollabErrorKind.other);
    });
  });
}
