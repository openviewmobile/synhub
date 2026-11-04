// WebSocket 连接 —— **兜底桩**（`DA281`，r664）。
//
// 既不是 `dart:io` 也不是 `dart:js_interop` 的宿主（理论上的第三种平台）
// 会落到这里：**响亮失败**比静默假装连上诚实。
import 'socket_connector_base.dart';

export 'socket_connector_base.dart' show SocketLike;

Future<SocketLike> openSocket(
  Uri uri, {
  Map<String, String> headers = const {},
  bool allowSelfSigned = true,
  void Function(Object cert, String host)? onCertificate,
  Duration timeout = const Duration(seconds: 15),
}) async {
  throw UnsupportedError('WebSocket is not available on this platform');
}
