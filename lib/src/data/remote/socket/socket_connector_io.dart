// WebSocket 连接 —— **原生实现**（`DA281`，r664）。
//
// 行为与改动前**逐字一致**：受控 `HttpClient`（自签/主机名不匹配放行）＋
// `WebSocket.connect(..., customClient: client)`，请求头照发。
import 'dart:io';

import 'socket_connector_base.dart';

export 'socket_connector_base.dart' show SocketLike;

Future<SocketLike> openSocket(
  Uri uri, {
  Map<String, String> headers = const {},
  bool allowSelfSigned = true,
  void Function(Object cert, String host)? onCertificate,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  if (allowSelfSigned) {
    client.badCertificateCallback = (cert, host, port) {
      onCertificate?.call(cert, host);
      return true;
    };
  }
  final ws = await WebSocket.connect(
    uri.toString(),
    headers: headers.isEmpty ? null : headers,
    // 关键：把受控的 HttpClient 传进去，自签/主机名不匹配才连得上
    customClient: client,
  ).timeout(timeout);
  return _IoSocket(ws, client);
}

class _IoSocket implements SocketLike {
  _IoSocket(this._ws, this._client);

  final WebSocket _ws;
  final HttpClient _client;

  @override
  Stream<dynamic> get frames => _ws;

  @override
  void send(Object data) => _ws.add(data);

  @override
  Future<void> close() async {
    try {
      await _ws.close();
    } finally {
      _client.close(force: true);
    }
  }
}
