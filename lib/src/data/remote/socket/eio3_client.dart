// 极简 Engine.IO v3 / socket.io v2 客户端（只走 websocket）。
//
// 为什么不用 socket_io_client 1.0.2：
//   1. 它内部调 `WebSocket.connect(uri, protocols:, headers:)`，**不传 customClient**，
//      而自签/主机名不匹配的 NAS 证书必须靠 `customClient`（`HttpClient
//      ..badCertificateCallback`）才能连上。实测 `HttpOverrides.global` 对
//      `dart:io` 的 websocket 不可靠：`_WebSocketImpl._httpClient` 是 static final，
//      一旦在装 override 之前被创建过就不再受控（见 test/self_signed_ws_test.dart）。
//   2. 它在 VM 上只有 websocket 一种实现（io_transports.dart），本来也用不到 polling。
//   3. 我们自己实现后，cookie / 认证头 / 证书策略全部显式可控、可离线测试。
//
// 协议（全部来自真实抓包，见 test/fixtures/socket_frames.txt）：
//   → GET /sc/socket.io/?EIO=3&transport=websocket&client=mobile   （升级为 websocket）
//   ← 0{"sid":"…","upgrades":[],"pingInterval":25000,"pingTimeout":60000}
//   → 40                       socket.io 连接到命名空间 "/"
//   ← 40                       命名空间连接成功
//   ← 42["event",payload]      业务事件
//   → 42["event",payload]      我们发的事件
//   ← 2 / → 3                  engine.io ping/pong（服务端 ping，客户端 pong）
library;

import 'dart:async';
import 'dart:convert';

import '../../../core/i18n/data_text.dart';
import 'socket_connector.dart';

/// 服务端推来 / 我们收到的一条 socket.io 事件。
class Eio3Event {
  const Eio3Event(this.name, this.payload);

  final String name;
  final Object? payload;

  @override
  String toString() => 'Eio3Event($name, $payload)';
}

class Eio3Exception implements Exception {
  Eio3Exception(this.message);
  final String message;
  @override
  String toString() => 'Eio3Exception($message)';
}

class Eio3Client {
  Eio3Client({
    required this.baseUrl,
    this.path = '/sc/socket.io',
    this.query = const {'client': 'mobile'},
    this.headers = const {},
    this.allowSelfSigned = true,
    this.onCertificate,
    this.certVerifier,
    this.connectTimeout = const Duration(seconds: 15),
  });

  final String baseUrl;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final bool allowSelfSigned;
  /// 自签证书回调（**只对原生侧有意义**；Web 侧浏览器自己判证书）。
  final void Function(Object cert, String host)? onCertificate;

  /// 证书裁决（生产由首连信任库提供；空 = 旧行为，见 `openSocket`）。
  final bool Function(Object cert, String host, int port)? certVerifier;
  final Duration connectTimeout;

  /// ★ `DA281`（r664）：连接对象走条件导入门面（`socket_connector.dart`）——
  /// 以前这里直接 `WebSocket.connect` + `HttpClient`（`dart:io`），
  /// Flutter Web 上那是运行期抛的桩 ⇒ 实时通道永远连不上
  /// （界面停在 "Realtime channel not ready"）。
  SocketLike? _ws;
  StreamSubscription<dynamic>? _sub;

  final _events = StreamController<Eio3Event>.broadcast();
  final _done = Completer<void>();

  bool _opened = false;

  Timer? _pingTimer;
  Duration? _pingInterval;

  String? _engineSid;

  /// engine.io 会话 id（open 包里的 sid）
  String? get engineSid => _engineSid;

  bool get isOpen => _opened && !_done.isCompleted;

  Stream<Eio3Event> get events => _events.stream;

  /// 连接关闭后完成（正常关闭，不带错误 —— 错误统一走 [onError]，
  /// 免得没人 await 时变成 unhandled async error）
  Future<void> get closed => _done.future;

  void Function(Object error)? onError;
  void Function()? onDisconnected;

  /// 拼出握手 URL。`path` 与 query 都要与 SocketHelper 保持一致。
  Uri buildUri() {
    final base = Uri.parse(baseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final prefix = path.endsWith('/') ? path : '$path/';
    return Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: prefix,
      queryParameters: {'EIO': '3', 'transport': 'websocket', ...query},
    );
  }

  Future<void> connect() async {
    final uri = buildUri();
    try {
      final ws = await openSocket(
        uri,
        headers: headers,
        allowSelfSigned: allowSelfSigned,
        onCertificate: onCertificate,
        certVerifier: certVerifier,
        timeout: connectTimeout,
      );
      _ws = ws;

      _sub = ws.frames.listen(
        _onFrame,
        onError: (Object e) {
          onError?.call(e);
          _finish();
        },
        onDone: _finish,
        cancelOnError: false,
      );
    } catch (e) {
      onError?.call(e);
      rethrow;
    }
  }

  void _onFrame(dynamic data) {
    final frame = data is String ? data : utf8.decode(data as List<int>);
    if (frame.isEmpty) return;

    switch (frame[0]) {
      case '0': // engine.io open
        final body = frame.substring(1);
        if (body.isNotEmpty) {
          try {
            final map = jsonDecode(body) as Map<String, dynamic>;
            _engineSid = map['sid'] as String?;
            final interval = map['pingInterval'];
            if (interval is num) {
              _pingInterval = Duration(milliseconds: interval.toInt());
              _armPingWatchdog();
            }
          } catch (_) {
            // open 包解析失败也要继续：socket.io 层还能用
          }
        }
        _opened = true;
        send('40'); // 连接 socket.io 命名空间 "/"

      case '2': // engine.io ping → 必须回 pong
        send('3');
        _armPingWatchdog();

      case '3': // pong
        _armPingWatchdog();

      case '4': // socket.io 消息
        _onSocketIoFrame(frame.substring(1));

      default:
        break;
    }
  }

  void _onSocketIoFrame(String body) {
    if (body.isEmpty) return;
    switch (body[0]) {
      case '0': // 40：命名空间连接成功
      case '1': // 41：命名空间断开
        break;
      case '2': // 42：事件
        final payload = body.substring(1);
        if (payload.isEmpty) return;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is List && decoded.isNotEmpty) {
            final name = decoded.first;
            if (name is String) {
              _events.add(
                Eio3Event(name, decoded.length > 1 ? decoded[1] : null),
              );
            }
          }
        } catch (_) {
          // 坏帧忽略，不要因为一条脏数据断掉整条通道
        }
      default:
        break;
    }
  }

  /// 发一条 socket.io 事件（`42["name",payload]`）
  void send(String frame) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.send(frame);
    } catch (e) {
      onError?.call(e);
    }
  }

  void emit(String name, [Object? payload]) {
    final list = payload == null ? [name] : [name, payload];
    send('42${jsonEncode(list)}');
  }

  void _armPingWatchdog() {
    _pingTimer?.cancel();
    final interval = _pingInterval;
    if (interval == null) return;
    // 服务端按 interval 发 ping；超过两倍没动静就认为连接死了
    _pingTimer = Timer(interval * 2, () {
      onError?.call(
        Eio3Exception(
          dataText(
            'apiPingTimeout',
            'ping 超时（{duration} 未收到 ping/pong）',
          ).replaceAll('{duration}', '${interval * 2}'),
        ),
      );
      close();
    });
  }

  void _finish() {
    _pingTimer?.cancel();
    if (!_done.isCompleted) _done.complete();
    onDisconnected?.call();
  }

  Future<void> close() async {
    _pingTimer?.cancel();
    await _sub?.cancel();
    _sub = null;
    try {
      await _ws?.close();
    } catch (_) {
      // 关闭失败无所谓
    }
    _ws = null;
    _finish();
  }

  void dispose() {
    close();
    if (!_events.isClosed) _events.close();
  }
}
