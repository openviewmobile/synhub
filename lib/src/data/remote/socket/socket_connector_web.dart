// WebSocket 连接 —— **Web 实现**（`DA281`，r664）。
//
// 用 `package:web_socket_channel`（浏览器上就是原生 `WebSocket`）。
//
// ★ 如实记三条差异（不是"漏做"）：
//   1. **设不了请求头**：浏览器的 `WebSocket` 构造函数不接受 header，
//      `Cookie` 由浏览器自己随握手带（登录时 Set-Cookie 已经在浏览器里），
//      `SynoToken` 走**查询串**（`chat_socket.dart` 本来就放在 query 上）；
//      `headers` 参数在这里**显式忽略**。
//   2. **证书由浏览器判**：自签要用户点"继续前往"，`allowSelfSigned` 不生效。
//   3. 混合内容：HTTPS 页面里连 `ws://` 会被浏览器拦（`wss://` 才行）——
//      这是浏览器策略，不是本仓能绕的。
import 'package:web_socket_channel/web_socket_channel.dart';

import 'socket_connector_base.dart';

export 'socket_connector_base.dart' show SocketLike;

Future<SocketLike> openSocket(
  Uri uri, {
  Map<String, String> headers = const {},
  bool allowSelfSigned = true,
  void Function(Object cert, String host)? onCertificate,
  bool Function(Object cert, String host, int port)? certVerifier,
  Duration timeout = const Duration(seconds: 15),
}) async {
  // ⚠️ `headers` / `allowSelfSigned` 在浏览器上没有对应能力（见文件头）。
  final channel = WebSocketChannel.connect(uri);
  await channel.ready.timeout(timeout);
  return _WebSocket(channel);
}

class _WebSocket implements SocketLike {
  _WebSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get frames => _channel.stream;

  @override
  void send(Object data) => _channel.sink.add(data);

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {
      // 关闭失败无所谓（对端可能已经断了）
    }
  }
}
