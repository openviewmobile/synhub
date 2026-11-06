// Office C' — M0 live protocol client, ported into `lib/`.
//
// This is a faithful port of the device-proven spike
// `tool/office_collab_spike/office_collab_spike.dart` (zero third-party socket
// dependencies, hand-written engine.io + Socket.IO frame codec). The wire
// behaviour is not re-invented here: every gate below is a hard M0 fact,
// evidenced frame-by-frame in `docs/office-collab-protocol-spike.md` and in
// `test/fixtures/office_collab/replay_doc_write.json` / `replay_docneg.json`.
//
// Hard gates carried over from the real device:
//
//  1. engine.io 4 handshake `0{"sid":…,"pingInterval":25000,"pingTimeout":60000,…}`
//     -> the client may only send C→S events after `42["ready"]`; anything sent
//     earlier is **silently dropped** (no queue, no ack) because the server's
//     `onConnect` is async. [emit] enforces this and throws
//     [OfficeCollabNotReadyException] instead of losing the frame.
//  2. websocket upgrade `2probe` -> `3probe` -> `5`. Closing the probe socket
//     destroys the whole engine.io session, so a failed upgrade always triggers a
//     fresh handshake ([_openTransport]); it never reuses the poisoned session.
//  3. Socket.IO CONNECT is the bare `40` on the **default namespace `/`** - the
//     namespace is chosen by the URL path `/oo/socket.io/<ns>`, not by the frame.
//  4. Handshake query: `objectId` MUST be the Office `object_id`
//     (`1028_….doc`), `linkId` the Drive permanent_link. Swapping them yields a
//     silent `44{"message":"Permission denied"}` - [OfficeCollabTarget] rejects
//     the swap up front.
//  5. Auth is the cookie `id=<sid>`; the sid never appears in traces (it is
//     redacted by [redactSid]).
//  6. acks are socket.io *positional argument lists*: `43<id>[null, {…}]` or
//     `43<id>[{"status":402}, "Error: …"]`.
//
// The transport is injectable ([OfficeCollabTransport]) so the whole client can
// be replayed offline against the recorded device frames - no network, no NAS,
// no device.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/net/cert_policy_hook.dart';

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Base class for every client-side collaboration failure.
class OfficeCollabException implements Exception {
  OfficeCollabException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A malformed / unexpected wire frame.
class OfficeCollabProtocolException extends OfficeCollabException {
  OfficeCollabProtocolException(super.message);
}

/// The [OfficeCollabTarget] is internally inconsistent (wrong id roles, empty
/// namespace, …). Thrown at construction time, before any socket is opened.
class OfficeCollabConfigException extends OfficeCollabException {
  OfficeCollabConfigException(super.message);
}

/// [OfficeCollabClient.emit] was called before the server sent `42["ready"]`.
///
/// Sending earlier is not an error on the wire - it is *silently dropped* by the
/// server - so the client refuses locally instead of hanging for 60 s.
class OfficeCollabNotReadyException extends OfficeCollabException {
  OfficeCollabNotReadyException(this.event, this.state)
    : super(
        'cannot emit "$event" before server "ready" (state: ${state.name})',
      );

  final String event;
  final OfficeCollabState state;
}

/// The Socket.IO namespace answered `44{"message":"Permission denied"}`.
///
/// On the real device this is what a swapped `objectId`/`linkId` looks like (see
/// `docs/office-collab-protocol-spike.md` §2.5 A).
class OfficeCollabPermissionDeniedException extends OfficeCollabException {
  OfficeCollabPermissionDeniedException([String? detail])
    : super(
        'Permission denied${detail == null ? '' : ': $detail'} '
        '(the handshake objectId must be the Office object_id and linkId '
        'the Drive permanent_link)',
      );
}

/// The transport went away while acks were outstanding.
class OfficeCollabDisconnectedException extends OfficeCollabException {
  OfficeCollabDisconnectedException(super.message);
}

/// An `emit` did not get its ack in time.
class OfficeCollabTimeoutException extends OfficeCollabException {
  OfficeCollabTimeoutException(this.event, this.timeout)
    : super('no ack for "$event" within ${timeout.inSeconds}s');

  final String event;
  final Duration timeout;
}

// ---------------------------------------------------------------------------
// Protocol status codes (verified on device, M0)
// ---------------------------------------------------------------------------

/// `ERR_VERSION_NOT_CURRENT` - the server answers
/// `Error: OBJECT_ID: Not current version. incoming: X, current: Y`.
const int kCollabStatusNotCurrentVersion = 402;

/// `ERR_INVALID_COMMAND` - `Step.fromJSON` threw server-side.
const int kCollabStatusInvalidCommand = 411;

/// `ERR_PERM_NOT_ENOUGH`.
const int kCollabStatusPermNotEnough = 409;

/// The generic server error.
const int kCollabStatusGeneral = 500;

/// The Socket.IO CONNECT_ERROR status is not numeric - the server sends
/// `44{"message":"Permission denied"}`. Kept as a named pseudo-status so callers
/// can classify it next to 402/411.
const int kCollabStatusPermissionDenied = 44;

/// Coarse classification of a server reply, shared by the session layer.
enum OfficeCollabErrorKind {
  ok,
  notCurrentVersion,
  invalidCommand,
  permissionDenied,
  other,
}

/// Classify a decoded socket.io ack (`emit` result) or a connect-error payload.
///
/// Accepts the real M0 shapes:
///   * `[null, {…}]`                             -> [OfficeCollabErrorKind.ok]
///   * `[{"status":402}, "Error: … current: 2"]` -> `notCurrentVersion`
///   * `[{"status":411}, "Error: …"]`            -> `invalidCommand`
///   * `{"message":"Permission denied"}`         -> `permissionDenied`
///   * `[{"success":true,"snapshot_version":…}]` -> [OfficeCollabErrorKind.ok]
///     (**UI batch 2 fix**) the real `save` ack
///     (`replay_doc_write.json` seq21) puts the result object itself in the
///     first positional slot, with no `status`. Before this branch it fell
///     through to [OfficeCollabErrorKind.other], so `save` could not use the
///     shared classifier. `success:false` still classifies as `other`: the
///     failure frame shape is unproven (UI batch 1 §④), so it must not be
///     promoted to `ok`.
OfficeCollabErrorKind classifyCollabReply(Object? reply) {
  if (reply is List) {
    if (reply.isEmpty) return OfficeCollabErrorKind.other;
    final first = reply.first;
    if (first is Map) {
      final status = first['status'];
      if (status == null) {
        final success = first['success'];
        if (success is bool) return _classifySuccess(success);
      }
      return _classifyStatus(status);
    }
    return OfficeCollabErrorKind.ok;
  }
  if (reply is Map) {
    final status = reply['status'];
    if (status != null) return _classifyStatus(status);
    final success = reply['success'];
    if (success is bool) return _classifySuccess(success);
    final message = reply['message'];
    if (message is String && message.contains('Permission denied')) {
      return OfficeCollabErrorKind.permissionDenied;
    }
    return OfficeCollabErrorKind.other;
  }
  return OfficeCollabErrorKind.other;
}

OfficeCollabErrorKind _classifySuccess(bool success) =>
    success ? OfficeCollabErrorKind.ok : OfficeCollabErrorKind.other;

OfficeCollabErrorKind _classifyStatus(Object? status) {
  final code = status is num ? status.toInt() : null;
  return switch (code) {
    kCollabStatusNotCurrentVersion => OfficeCollabErrorKind.notCurrentVersion,
    kCollabStatusInvalidCommand => OfficeCollabErrorKind.invalidCommand,
    kCollabStatusPermissionDenied => OfficeCollabErrorKind.permissionDenied,
    _ => OfficeCollabErrorKind.other,
  };
}

/// The last non-null positional argument of a socket.io ack (`cb(null, data)` /
/// `cb({status}, msg)`). Returns the input unchanged when it is not a list.
Object? collabAckPayload(Object? reply) {
  if (reply is! List || reply.isEmpty) return reply;
  for (var i = reply.length - 1; i >= 0; i--) {
    if (reply[i] != null) return reply[i];
  }
  return reply.last;
}

/// Error status carried by an ack, or null when the ack is a success.
int? collabAckStatus(Object? reply) {
  if (reply is Map) {
    final s = reply['status'];
    return s is num ? s.toInt() : null;
  }
  if (reply is List && reply.isNotEmpty && reply.first is Map) {
    final s = (reply.first as Map)['status'];
    return s is num ? s.toInt() : null;
  }
  return null;
}

/// Error message carried by an ack, or null.
String? collabAckMessage(Object? reply) {
  if (reply is Map) {
    final m = reply['message'];
    return m?.toString();
  }
  if (reply is List && reply.length > 1) {
    final m = reply[1];
    if (m is String) return m;
    if (m != null) return m.toString();
  }
  return null;
}

/// Redact a session id to `first8…`, the only form the M0 evidence ever prints.
String redactSid(String sid) =>
    sid.length <= 8 ? '…' : '${sid.substring(0, 8)}…';

final RegExp _sidKeyPattern = RegExp(r'"(sid|id)"\s*:\s*"[^"]*"');

/// Redacts the engine.io / Socket.IO session ids embedded in a raw frame
/// (`"sid":"…"`, `"id":"…"`) so [OfficeCollabClient.frames] is safe to log,
/// mirroring the M0 evidence masking.
String redactFrameRaw(String raw) =>
    raw.replaceAllMapped(_sidKeyPattern, (m) => '"${m[1]}":"<redacted>"');

// ---------------------------------------------------------------------------
// Frame codec (hand-written, no third-party socket library)
// ---------------------------------------------------------------------------

/// engine.io v4 packet types.
abstract final class EioPacketType {
  static const String open = '0';
  static const String close = '1';
  static const String ping = '2';
  static const String pong = '3';
  static const String message = '4';
  static const String upgrade = '5';
  static const String noop = '6';
}

/// engine.io v4 separates records in one polling body with `\x1e`.
List<String> splitEioPayload(String body) =>
    body.split('\u001e').where((p) => p.isNotEmpty).toList(growable: false);

/// One engine.io packet: a one-character [type] plus its raw [data].
class EioPacket {
  const EioPacket(this.type, this.data);

  final String type;
  final String data;

  static EioPacket parse(String raw) {
    if (raw.isEmpty) {
      throw OfficeCollabProtocolException('empty engine.io packet');
    }
    return EioPacket(raw[0], raw.length > 1 ? raw.substring(1) : '');
  }

  @override
  String toString() => '$type$data';
}

/// Socket.IO packet types (v5).
abstract final class SioPacketType {
  static const int connect = 0;
  static const int disconnect = 1;
  static const int event = 2;
  static const int ack = 3;
  static const int connectError = 4;
  static const int binaryEvent = 5;
  static const int binaryAck = 6;
}

/// One Socket.IO packet: `[namespace,]<ackId><json payload>`.
///
/// The Office server speaks the **default namespace `/`**, so a real connect is
/// the bare `40` (`SioPacket(type: 0)` on engine.io message `4`). A leading
/// `/ns,` is still parsed for completeness.
class SioPacket {
  const SioPacket({
    required this.type,
    this.namespace,
    this.ackId,
    this.payload = '',
  });

  final int type;
  final String? namespace;
  final int? ackId;
  final String payload;

  static SioPacket parse(String raw) {
    if (raw.isEmpty) {
      throw OfficeCollabProtocolException('empty socket.io packet');
    }
    final type = int.tryParse(raw[0]);
    if (type == null) {
      throw OfficeCollabProtocolException('bad socket.io packet type: $raw');
    }
    var i = 1;
    String? namespace;
    if (i < raw.length && raw[i] == '/') {
      final comma = raw.indexOf(',', i);
      if (comma != -1) {
        namespace = raw.substring(i, comma);
        i = comma + 1;
      }
    }
    final digits = StringBuffer();
    while (i < raw.length && _isDigit(raw.codeUnitAt(i))) {
      digits.write(raw[i]);
      i++;
    }
    final ackId = digits.isEmpty ? null : int.tryParse(digits.toString());
    final payload = i < raw.length ? raw.substring(i) : '';
    return SioPacket(
      type: type,
      namespace: namespace,
      ackId: ackId,
      payload: payload,
    );
  }

  /// Encodes the Socket.IO packet (engine.io message type `4` is added by the
  /// client's transport send).
  String encode() {
    final b = StringBuffer('$type');
    final ns = namespace;
    if (ns != null) b.write('$ns,');
    final id = ackId;
    if (id != null) b.write('$id');
    b.write(payload);
    return b.toString();
  }

  /// `42<ackId>["<event>",<data>?]` — the M0 EVENT+ACK frame body.
  static SioPacket event(String event, {Object? data, int? ackId}) => SioPacket(
    type: SioPacketType.event,
    ackId: ackId,
    payload: jsonEncode(<Object?>[event, ?data]),
  );

  @override
  String toString() => encode();

  static bool _isDigit(int c) => c >= 48 && c <= 57;
}

// ---------------------------------------------------------------------------
// Transport (injectable; the default uses dart:io)
// ---------------------------------------------------------------------------

/// One client-side websocket.
abstract class OfficeCollabWsChannel {
  /// Incoming text frames. Binary frames are ignored by the client.
  Stream<String> get messages;

  void send(String text);

  Future<void> close();
}

/// Everything the client needs from the network, so tests can replay recorded
/// frames offline.
abstract class OfficeCollabTransport {
  /// `GET …/?EIO=4&transport=polling&<query>` -> response body.
  Future<String> pollingGet(Uri uri, Map<String, String> headers);

  /// `POST …/?EIO=4&transport=polling&sid=<sid>` with a raw packet body.
  Future<String> pollingPost(Uri uri, Map<String, String> headers, String body);

  /// Opens the engine.io websocket (probe phase included).
  Future<OfficeCollabWsChannel> openWebSocket(
    Uri uri,
    Map<String, String> headers,
  );

  Future<void> dispose();
}

/// The real transport: `dart:io` `HttpClient` + `WebSocket`.
class IoOfficeCollabTransport implements OfficeCollabTransport {
  IoOfficeCollabTransport({
    HttpClient? httpClient,
    this.certVerifier,
    this.connectionTimeout = const Duration(seconds: 20),
    this.requestTimeout = const Duration(seconds: 60),
  }) : _http = httpClient ?? _clientFor(certVerifier) {
    _http.connectionTimeout = connectionTimeout;
  }

  /// 本条传输自己的裁决（优先于进程级挂钩）。
  final CertVerifier? certVerifier;

  static HttpClient _clientFor(
    bool Function(Object cert, String host, int port)? verifier,
  ) {
    final client = HttpClient();
    final v = verifier ?? officeCollabCertVerifier;
    client.badCertificateCallback = (cert, host, port) =>
        v == null ? true : v(cert, host, port);
    return client;
  }

  final HttpClient _http;
  final Duration connectionTimeout;
  final Duration requestTimeout;

  void _applyHeaders(HttpClientRequest req, Map<String, String> headers) {
    headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.acceptHeader, '*/*');
  }

  @override
  Future<String> pollingGet(Uri uri, Map<String, String> headers) async {
    final req = await _http.getUrl(uri);
    _applyHeaders(req, headers);
    final res = await req.close().timeout(requestTimeout);
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != HttpStatus.ok) {
      throw OfficeCollabProtocolException(
        'HTTP ${res.statusCode} GET ${redactUri(uri)} -> $body',
      );
    }
    return body;
  }

  @override
  Future<String> pollingPost(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final req = await _http.postUrl(uri);
    _applyHeaders(req, headers);
    req.headers.contentType = ContentType('text', 'plain', charset: 'UTF-8');
    req.add(utf8.encode(body));
    final res = await req.close().timeout(requestTimeout);
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != HttpStatus.ok) {
      throw OfficeCollabProtocolException(
        'HTTP ${res.statusCode} POST ${redactUri(uri)} -> $text',
      );
    }
    return text;
  }

  @override
  Future<OfficeCollabWsChannel> openWebSocket(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final ws = await WebSocket.connect(
      uri.toString(),
      headers: headers,
      customClient: _http,
      compression: CompressionOptions.compressionOff,
    );
    return _IoWsChannel(ws);
  }

  @override
  Future<void> dispose() async => _http.close(force: true);

  /// Never leak the sid query parameter into logs.
  static String redactUri(Uri uri) {
    final q = <String, String>{...uri.queryParameters};
    if (q.containsKey('sid')) q['sid'] = redactSid(q['sid']!);
    return uri.replace(queryParameters: q).toString();
  }
}

class _IoWsChannel implements OfficeCollabWsChannel {
  _IoWsChannel(this._ws);

  final WebSocket _ws;

  @override
  Stream<String> get messages => _ws.where((e) => e is String).cast<String>();

  @override
  void send(String text) => _ws.add(text);

  @override
  Future<void> close() => _ws.close();
}

// ---------------------------------------------------------------------------
// Target (base URL + the two id roles + namespace)
// ---------------------------------------------------------------------------

/// A collaboration target: the NAS base URL, the Office [objectId], the Drive
/// [linkId] and the socket.io namespace (derived from the object extension).
///
/// The M0 device probe is explicit about the roles:
/// `SYNO.Office.Permission:check {object_id:"1028_….doc", link_id:"19yf…"}`
/// returns readable/writable, while `{object_id:"19yf…", link_id:"19yf…"}`
/// returns everything `false` and the socket then answers `44 Permission
/// denied`. [OfficeCollabTarget] therefore refuses a swapped pair at
/// construction time instead of failing silently 30 s later.
class OfficeCollabTarget {
  OfficeCollabTarget({
    required this.baseUrl,
    required this.objectId,
    required this.linkId,
    String? namespace,
  }) : namespace = namespace ?? _deriveNamespace(objectId) {
    _validate();
  }

  /// e.g. `https://nas.example.com:5001` (no trailing slash required).
  final Uri baseUrl;

  /// Office `object_id`, e.g. `1028_FATHU56MD53F5ARCP55HVG877S.doc`.
  final String objectId;

  /// Drive `permanent_link`, e.g. `19yfWXfe2ZGfFb5oigOvzXifW0g5LZnn`.
  final String linkId;

  /// Socket.IO namespace / URL path segment (`doc`, `sheet`, …).
  final String namespace;

  static final RegExp _objectIdPattern = RegExp(
    r'^\d+_[A-Za-z0-9]+\.[A-Za-z0-9]+$',
  );

  /// M0-evidenced: `.doc` -> `doc` (`/oo/socket.io/doc`), `.sh` -> `sheet`
  /// (`/oo/socket.io/sheet`). `.slide` is inferred (not probed in M0) and marked
  /// as such; an explicit [namespace] always wins.
  static String _deriveNamespace(String objectId) {
    final dot = objectId.lastIndexOf('.');
    final ext = dot == -1 ? '' : objectId.substring(dot + 1);
    return switch (ext) {
      'doc' => 'doc',
      'sh' => 'sheet',
      'slide' => 'presentation', // inferred, not probed in M0
      _ => ext.isEmpty ? '~' : ext,
    };
  }

  void _validate() {
    if (!_objectIdPattern.hasMatch(objectId)) {
      throw OfficeCollabConfigException(
        'objectId "$objectId" is not an Office object_id '
        '("<uid>_<hash>.<ntype>", e.g. 1028_….doc). M0 proved that passing the '
        'permanent_link as objectId yields a silent {"readable":false} and then '
        '44 Permission denied. Use objectId=Office object_id, '
        'linkId=permanent_link.',
      );
    }
    if (linkId.trim().isEmpty) {
      throw OfficeCollabConfigException('linkId must not be empty');
    }
    if (_objectIdPattern.hasMatch(linkId)) {
      throw OfficeCollabConfigException(
        'linkId "$linkId" looks like an Office object_id - objectId and linkId '
        'are swapped (objectId=Office object_id, linkId=permanent_link).',
      );
    }
    if (namespace.trim().isEmpty) {
      throw OfficeCollabConfigException('namespace must not be empty');
    }
  }

  /// M0: `path=/oo/socket.io/<ns>`.
  String get path => '/oo/socket.io/$namespace';

  @override
  String toString() =>
      'OfficeCollabTarget(${baseUrl.host}, ns=$namespace, objectId=$objectId, '
      'linkId=$linkId)';
}

// ---------------------------------------------------------------------------
// Frame trace
// ---------------------------------------------------------------------------

/// One recorded wire frame (mirrors the M0 evidence shape).
class OfficeCollabFrame {
  const OfficeCollabFrame(
    this.seq,
    this.dir,
    this.transport,
    this.raw, [
    this.note,
  ]);

  final int seq;
  final String dir; // c2s | s2c | notice
  final String transport; // polling | websocket | local
  final String raw;
  final String? note;

  Map<String, Object?> toJson() => <String, Object?>{
    'seq': seq,
    'dir': dir,
    'transport': transport,
    'raw': raw,
    if (note != null) 'note': note,
  };

  @override
  String toString() => '[$seq $dir/$transport] $raw';
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Lifecycle of [OfficeCollabClient].
enum OfficeCollabState {
  disconnected,
  connecting,
  connected,
  ready,
  reconnecting,
  closed,
}

/// A server-pushed Socket.IO event (`42["ready"]`, `42["reload"]`, …).
class OfficeCollabEvent {
  const OfficeCollabEvent(this.name, this.args);

  final String name;
  final List<Object?> args;

  @override
  String toString() => 'OfficeCollabEvent($name, args: $args)';
}

/// Hand-written engine.io + Socket.IO client for the Office collaboration
/// protocol (M0 facts, no third-party socket dependency).
///
/// Lifecycle:
/// ```
/// final client = OfficeCollabClient(target: t, transport: injected);
/// await client.connect();          // handshake -> upgrade -> `40` -> wait `ready`
/// final ack = await client.emit('fetch');
/// await client.close();
/// ```
/// On transport loss the client reconnects with backoff and then emits
/// [onReconnected]; the session layer listens to re-`fetch`.
class OfficeCollabClient {
  OfficeCollabClient({
    required this.target,
    OfficeCollabTransport? transport,
    this.sessionCookieId,
    this.synoToken = '',
    this.userAgent = 'DSH-OfficeCollab/0.1 (dart)',
    this.extraHeaders = const <String, String>{},
    this.ackTimeout = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 60),
    this.readyTimeout = const Duration(seconds: 90),
    this.probeTimeout = const Duration(seconds: 20),
    this.reconnectDelay = const Duration(seconds: 1),
    this.maxReconnectAttempts = 5,
    this.enableReconnect = true,
  }) : _transport = transport ?? IoOfficeCollabTransport();

  final OfficeCollabTarget target;
  final OfficeCollabTransport _transport;
  final String? sessionCookieId;
  final String synoToken;
  final String userAgent;
  final Map<String, String> extraHeaders;
  final Duration ackTimeout;
  final Duration connectTimeout;
  final Duration readyTimeout;
  final Duration probeTimeout;
  final Duration reconnectDelay;
  final int maxReconnectAttempts;
  final bool enableReconnect;

  // --- engine.io / socket.io state ---
  String? _eioSid;
  OfficeCollabWsChannel? _ws;
  StreamSubscription<String>? _wsSub;
  bool _useWs = false;
  bool _pollingLoopActive = false;

  // --- heartbeat (from the handshake `0{…}` packet) ---
  Duration pingInterval = const Duration(milliseconds: 25000);
  Duration pingTimeout = const Duration(milliseconds: 60000);
  DateTime _lastServerActivity = DateTime.now();
  Timer? _watchdog;

  // --- acks ---
  final Map<int, Completer<Object?>> _acks = <int, Completer<Object?>>{};
  int _ackSeq = 0;

  // --- connect/ready waiters ---
  Completer<String>? _connectWaiter;
  Completer<void>? _readyWaiter;
  Completer<bool>? _probeWaiter;
  bool _ready = false;

  // --- reconnect ---
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  OfficeCollabState _state = OfficeCollabState.disconnected;

  final List<OfficeCollabFrame> _frames = <OfficeCollabFrame>[];
  final StreamController<OfficeCollabEvent> _events =
      StreamController<OfficeCollabEvent>.broadcast();
  final StreamController<void> _reconnected =
      StreamController<void>.broadcast();
  bool _disposed = false;

  OfficeCollabState get state => _state;

  bool get isReady => _state == OfficeCollabState.ready || _ready;

  /// engine.io session id (only relevant for OAuth-independent polling; the
  /// cookie `id=<sid>` carries auth). Never logged in full.
  String? get eioSid => _eioSid;

  bool get usingWebSocket => _useWs;

  /// Every raw frame, in order - the offline evidence trail.
  List<OfficeCollabFrame> get frames => List.unmodifiable(_frames);

  /// Socket.IO events pushed by the server (including `ready`).
  Stream<OfficeCollabEvent> get onEvent => _events.stream;

  /// Fires after a successful reconnect (ready again). The session re-fetches.
  Stream<void> get onReconnected => _reconnected.stream;

  Map<String, String> get headers => <String, String>{
    if (sessionCookieId != null) 'Cookie': 'id=$sessionCookieId',
    'X-SYNO-TOKEN': synoToken,
    'User-Agent': userAgent,
    'Origin': target.baseUrl.toString(),
    ...extraHeaders,
  };

  // --------------------------------------------------------------- lifecycle --

  /// handshake -> websocket upgrade (or fresh re-handshake) -> `40` -> `ready`.
  Future<void> connect() async {
    await open();
    await waitReady();
  }

  /// handshake -> upgrade -> Socket.IO CONNECT, **without** waiting for `ready`.
  ///
  /// Split out so callers/tests can observe the ready gate explicitly; use
  /// [connect] for the normal path.
  Future<void> open() async {
    if (_state == OfficeCollabState.closed) {
      throw OfficeCollabException('client is closed');
    }
    _ready = false;
    _state = OfficeCollabState.connecting;
    await _openTransport();
    await _socketIoConnect();
    _state = OfficeCollabState.connected;
  }

  /// Waits for the server's `42["ready"]` (the M0 gate B). Idempotent.
  Future<void> waitReady() async {
    if (_ready) {
      _state = OfficeCollabState.ready;
      return;
    }
    final waiter = _readyWaiter ??= Completer<void>();
    try {
      await waiter.future.timeout(readyTimeout);
    } on TimeoutException {
      _readyWaiter = null;
      throw OfficeCollabTimeoutException('ready', readyTimeout);
    }
    _state = OfficeCollabState.ready;
  }

  Future<void> close() async {
    if (_state == OfficeCollabState.closed) return;
    _state = OfficeCollabState.closed;
    _watchdog?.cancel();
    _reconnectTimer?.cancel();
    _pollingLoopActive = false;
    _failPendingAcks(OfficeCollabDisconnectedException('client closed'));
    try {
      _ws?.send('41');
    } catch (_) {
      // best effort
    }
    await _teardownWs();
    if (!_disposed) {
      _disposed = true;
      await _events.close();
      await _reconnected.close();
      await _transport.dispose();
    }
  }

  // ------------------------------------------------------------ emit / ack --

  /// Sends a Socket.IO EVENT and awaits its ack (decoded positional payload).
  ///
  /// Throws [OfficeCollabNotReadyException] when `ready` has not arrived - an
  /// event sent earlier is silently dropped by the server (M0 gate B).
  Future<Object?> emit(String event, [Object? data]) async {
    if (!isReady || _state != OfficeCollabState.ready) {
      throw OfficeCollabNotReadyException(event, _state);
    }
    final id = ++_ackSeq;
    final completer = Completer<Object?>();
    _acks[id] = completer;
    _sendSio(
      SioPacket.event(event, data: data, ackId: id),
      note: 'socket.io EVENT+ACK $event',
    );
    try {
      return await completer.future.timeout(ackTimeout);
    } on TimeoutException {
      _acks.remove(id);
      throw OfficeCollabTimeoutException(event, ackTimeout);
    }
  }

  /// Emits and classifies the reply into the M0 error model in one call.
  Future<OfficeCollabErrorKind> emitChecked(
    String event, [
    Object? data,
  ]) async => classifyCollabReply(await emit(event, data));

  // ------------------------------------------------------- transport setup --

  Future<void> _openTransport() async {
    await _handshake();
    final upgraded = await _tryUpgrade();
    if (!upgraded) {
      // M0 gate C: a failed probe close() destroys the engine.io session, so the
      // only safe move is a brand-new handshake - never reuse the old sid.
      _trace(
        'notice',
        'local',
        'websocket upgrade unavailable/failed -> fresh engine.io handshake',
      );
      await _handshake();
      _startPollingLoop();
    }
  }

  Future<void> _handshake() async {
    _eioSid = null;
    _useWs = false;
    final body = await _transport.pollingGet(
      _pollingUri(transport: 'polling'),
      headers,
    );
    EioPacket? open;
    for (final raw in splitEioPayload(body)) {
      final packet = EioPacket.parse(raw);
      _trace('s2c', 'polling', raw, 'engine.io packet');
      if (packet.type == EioPacketType.open) open = packet;
    }
    if (open == null) {
      throw OfficeCollabProtocolException(
        'engine.io handshake failed (no open packet): $body',
      );
    }
    final handshake = jsonDecode(open.data);
    if (handshake is! Map) {
      throw OfficeCollabProtocolException(
        'bad engine.io open packet: ${open.data}',
      );
    }
    _eioSid = handshake['sid'] as String?;
    if (_eioSid == null) {
      throw OfficeCollabProtocolException('engine.io open without sid');
    }
    final pi = handshake['pingInterval'];
    final pt = handshake['pingTimeout'];
    if (pi is num) pingInterval = Duration(milliseconds: pi.toInt());
    if (pt is num) pingTimeout = Duration(milliseconds: pt.toInt());
    _lastServerActivity = DateTime.now();
    _startWatchdog();
  }

  Future<bool> _tryUpgrade() async {
    if (_eioSid == null) return false;
    OfficeCollabWsChannel channel;
    try {
      channel = await _transport.openWebSocket(_wsUri(), headers);
    } catch (e) {
      _trace('notice', 'websocket', 'ws connect failed: $e');
      return false;
    }
    _ws = channel;
    _trace(
      'notice',
      'websocket',
      'WS upgraded ${IoOfficeCollabTransport.redactUri(_wsUri())}',
    );
    _probeWaiter = Completer<bool>();
    _wsSub = channel.messages.listen(
      (msg) => _onEnginePacket(msg, 'websocket'),
      onError: (Object e) {
        _trace('notice', 'websocket', 'WS error: $e');
        _onTransportLost('websocket error: $e');
      },
      onDone: () {
        _trace('notice', 'websocket', 'WS closed');
        if (_useWs) _onTransportLost('websocket closed');
      },
    );
    channel.send('${EioPacketType.ping}probe');
    _trace('c2s', 'websocket', '2probe', 'engine.io probe');
    final probeOk = await _probeWaiter!.future.timeout(
      probeTimeout,
      onTimeout: () => false,
    );
    _probeWaiter = null;
    if (!probeOk) {
      _trace(
        'notice',
        'websocket',
        'no 3probe within ${probeTimeout.inSeconds}s; abandoning websocket',
      );
      await _teardownWs();
      return false;
    }
    _ws!.send(EioPacketType.upgrade);
    _trace('c2s', 'websocket', '5', 'engine.io UPGRADE');
    _useWs = true;
    _pollingLoopActive = false;
    return true;
  }

  Future<void> _socketIoConnect() async {
    _connectWaiter = Completer<String>();
    _sendSio(
      const SioPacket(type: SioPacketType.connect),
      note: 'socket.io CONNECT (default namespace)',
    );
    final waiter = _connectWaiter!;
    try {
      await waiter.future.timeout(connectTimeout);
    } on TimeoutException {
      _connectWaiter = null;
      throw OfficeCollabTimeoutException('connect(40)', connectTimeout);
    }
    _connectWaiter = null;
  }

  void _startPollingLoop() {
    if (_pollingLoopActive) return;
    _pollingLoopActive = true;
    unawaited(_pollingLoop());
  }

  Future<void> _pollingLoop() async {
    while (_state != OfficeCollabState.closed &&
        !_useWs &&
        _eioSid != null &&
        _pollingLoopActive) {
      try {
        final body = await _transport.pollingGet(
          _pollingUri(transport: 'polling', sid: _eioSid),
          headers,
        );
        _ingest(body, 'polling');
      } catch (e) {
        if (_state != OfficeCollabState.closed && _pollingLoopActive) {
          _onTransportLost('polling loop: $e');
        }
        return;
      }
    }
  }

  // ------------------------------------------------------- packet handling --

  void _ingest(String body, String transport) {
    for (final raw in splitEioPayload(body)) {
      _onEnginePacket(raw, transport);
    }
  }

  void _onEnginePacket(String packet, String transport) {
    if (packet.isEmpty) return;
    _lastServerActivity = DateTime.now();
    _trace('s2c', transport, packet, 'engine.io packet');
    final type = packet[0];
    final data = packet.length > 1 ? packet.substring(1) : '';
    switch (type) {
      case EioPacketType.open:
        break;
      case EioPacketType.close:
        _onTransportLost('engine.io CLOSE');
        break;
      case EioPacketType.ping:
        // engine.io v4: server pings (`2`), client pongs (`3`).
        _sendEio(EioPacketType.pong);
        _trace('c2s', transport, EioPacketType.pong, 'engine.io pong');
        break;
      case EioPacketType.pong:
        // `3probe` is the upgrade probe acknowledgement.
        if (data == 'probe') {
          final waiter = _probeWaiter;
          if (waiter != null && !waiter.isCompleted) waiter.complete(true);
        }
        break;
      case EioPacketType.message:
        if (data.isNotEmpty) _onSioPacket(SioPacket.parse(data));
        break;
      case EioPacketType.upgrade:
        break;
      case EioPacketType.noop:
        break;
      default:
        _trace('notice', transport, 'unhandled engine.io packet type "$type"');
        break;
    }
  }

  void _onSioPacket(SioPacket packet) {
    switch (packet.type) {
      case SioPacketType.connect:
        final waiter = _connectWaiter;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(packet.payload);
        }
        break;
      case SioPacketType.disconnect:
        _onTransportLost('socket.io DISCONNECT');
        break;
      case SioPacketType.event:
        _onServerEvent(packet.payload);
        break;
      case SioPacketType.ack:
        _completeAck(packet.ackId, packet.payload);
        break;
      case SioPacketType.connectError:
        _onConnectError(packet.payload);
        break;
      default:
        _trace(
          'notice',
          'websocket',
          'unhandled socket.io packet type ${packet.type}',
        );
        break;
    }
  }

  void _onServerEvent(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      decoded = null;
    }
    String name = '';
    List<Object?> args = const <Object?>[];
    if (decoded is List && decoded.isNotEmpty) {
      name = decoded.first?.toString() ?? '';
      args = decoded.sublist(1);
    }
    if (name == 'ready') {
      _ready = true;
      final waiter = _readyWaiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }
    if (!_events.isClosed) _events.add(OfficeCollabEvent(name, args));
  }

  void _onConnectError(String payload) {
    OfficeCollabException error;
    if (payload.contains('Permission denied')) {
      error = OfficeCollabPermissionDeniedException(payload);
    } else {
      error = OfficeCollabProtocolException(
        'socket.io CONNECT_ERROR $kCollabStatusPermissionDenied: $payload',
      );
    }
    _trace('notice', 'websocket', 'socket.io CONNECT_ERROR: $payload');
    final waiter = _connectWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.completeError(error);
  }

  void _completeAck(int? id, String payload) {
    if (id == null) return;
    final completer = _acks.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (payload.isEmpty) {
      completer.complete(null);
      return;
    }
    try {
      completer.complete(jsonDecode(payload));
    } catch (_) {
      completer.completeError(
        OfficeCollabProtocolException('bad ack payload for $id: $payload'),
      );
    }
  }

  // ----------------------------------------------------------- reconnect ----

  void _onTransportLost(String reason) {
    if (_state == OfficeCollabState.closed ||
        _state == OfficeCollabState.reconnecting) {
      return;
    }
    _trace('notice', 'local', 'transport lost: $reason');
    _ready = false;
    _state = OfficeCollabState.reconnecting;
    _failPendingAcks(OfficeCollabDisconnectedException(reason));
    _connectWaiter = null;
    _readyWaiter = null;
    _probeWaiter = null;
    _pollingLoopActive = false;
    unawaited(_teardownWs());
    if (!enableReconnect) {
      _state = OfficeCollabState.disconnected;
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_reconnectAttempts >= maxReconnectAttempts) {
      _trace(
        'notice',
        'local',
        'giving up after $maxReconnectAttempts reconnect attempts',
      );
      _state = OfficeCollabState.disconnected;
      if (!_reconnected.isClosed) {
        _reconnected.addError(
          OfficeCollabDisconnectedException(
            'reconnect gave up after $maxReconnectAttempts attempts',
          ),
        );
      }
      return;
    }
    _reconnectAttempts++;
    _reconnectTimer = Timer(reconnectDelay, () {
      unawaited(_attemptReconnect());
    });
  }

  Future<void> _attemptReconnect() async {
    if (_state != OfficeCollabState.reconnecting) return;
    try {
      _trace(
        'notice',
        'local',
        'reconnect attempt $_reconnectAttempts/$maxReconnectAttempts',
      );
      await _openTransport();
      await _socketIoConnect();
      await waitReady();
      _reconnectAttempts = 0;
      _state = OfficeCollabState.ready;
      if (!_reconnected.isClosed) _reconnected.add(null);
    } catch (e) {
      _trace('notice', 'local', 'reconnect attempt failed: $e');
      _scheduleReconnect();
    }
  }

  void _failPendingAcks(OfficeCollabException error) {
    final pending = List<Completer<Object?>>.of(_acks.values);
    _acks.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  // -------------------------------------------------------------- heartbeat --

  void _startWatchdog() {
    _watchdog?.cancel();
    final half = pingInterval.inMilliseconds ~/ 2;
    final period = Duration(milliseconds: half < 1000 ? 1000 : half);
    _watchdog = Timer.periodic(period, (_) {
      if (_state == OfficeCollabState.closed ||
          _state == OfficeCollabState.reconnecting) {
        return;
      }
      final idle = DateTime.now().difference(_lastServerActivity);
      if (idle > pingInterval + pingTimeout) {
        _onTransportLost(
          'heartbeat timeout '
          '(pingInterval=${pingInterval.inMilliseconds}ms, '
          'pingTimeout=${pingTimeout.inMilliseconds}ms, idle=${idle.inMilliseconds}ms)',
        );
      }
    });
  }

  // ------------------------------------------------------------------ wire --

  String get _queryString => <String>[
    'objectId=${Uri.encodeQueryComponent(target.objectId)}',
    'linkId=${Uri.encodeQueryComponent(target.linkId)}',
  ].join('&');

  String get _pathPrefix => target.path.endsWith('/')
      ? target.path.substring(0, target.path.length - 1)
      : target.path;

  Uri _pollingUri({required String transport, String? sid}) {
    final q = StringBuffer('EIO=4&transport=$transport');
    if (sid != null) q.write('&sid=${Uri.encodeQueryComponent(sid)}');
    q.write('&$_queryString');
    return Uri.parse(
      '${target.baseUrl.scheme}://${target.baseUrl.authority}$_pathPrefix/?$q',
    );
  }

  Uri _wsUri() {
    final scheme = target.baseUrl.scheme == 'https' ? 'wss' : 'ws';
    return Uri.parse(
      '$scheme://${target.baseUrl.authority}$_pathPrefix/?EIO=4&transport=websocket'
      '&sid=${Uri.encodeQueryComponent(_eioSid!)}&$_queryString',
    );
  }

  void _sendEio(String frame) {
    if (_useWs && _ws != null) {
      _ws!.send(frame);
    } else {
      final uri = _pollingUri(transport: 'polling', sid: _eioSid);
      unawaited(
        _transport.pollingPost(uri, headers, frame).catchError((Object e) {
          if (_state != OfficeCollabState.closed) {
            _trace('notice', 'polling', 'polling POST failed: $e');
          }
          return '';
        }),
      );
    }
  }

  void _sendSio(SioPacket packet, {String? note}) {
    final frame = '${EioPacketType.message}${packet.encode()}';
    _trace('c2s', _useWs ? 'websocket' : 'polling', frame, note);
    _sendEio(frame);
  }

  Future<void> _teardownWs() async {
    final ws = _ws;
    _ws = null;
    _useWs = false;
    final sub = _wsSub;
    _wsSub = null;
    if (ws != null) {
      try {
        await ws.close();
      } catch (_) {
        // best effort
      }
    }
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {
        // best effort
      }
    }
  }

  void _trace(String dir, String transport, String raw, [String? note]) {
    _frames.add(
      OfficeCollabFrame(
        _frames.length + 1,
        dir,
        transport,
        redactFrameRaw(raw),
        note,
      ),
    );
  }
}
