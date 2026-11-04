// WebSocket 连接的**条件导入门面**（`DA281`，r664）。
//
// ## 为什么需要它
//
// `Eio3Client` 以前直接 `WebSocket.connect(...)` + `HttpClient`（`dart:io`）。
// Flutter Web 上这两样都是"能编译、运行期抛"的桩 ⇒ 实时通道永远连不上，
// 界面停在 **"Realtime channel not ready"**（真机取证 `docs/evidence-r664/`）。
//
// 拆法：门面按 `dart.library.js_interop` 选实现。
//   * 原生：`socket_connector_io.dart` —— `dart:io` WebSocket + 受控 HttpClient
//     （自签证书 / 主机名不匹配照样连得上，行为与改动前一致）；
//   * Web：`socket_connector_web.dart` —— `package:web_socket_channel`
//     （浏览器 `WebSocket` 实现）。
//
// ★ Web 上**设不了请求头**（`Cookie` 由浏览器自己带、`SynoToken` 走查询串），
//   所以 `headers` 在 web 实现里被显式忽略 —— 不假装设上了。
export 'socket_connector_stub.dart'
    if (dart.library.io) 'socket_connector_io.dart'
    if (dart.library.js_interop) 'socket_connector_web.dart';
