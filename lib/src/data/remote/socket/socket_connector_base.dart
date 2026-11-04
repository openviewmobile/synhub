// WebSocket 抽象的**共用声明**（`DA281`，r664）。
//
// 两个平台实现（`socket_connector_io.dart` / `socket_connector_web.dart`）
// 都实现这里的 [SocketLike]，调用方（`Eio3Client`）只认这个接口 ——
// 这样它就不用再 `import 'dart:io'`。
//
// ★ 不在这里声明 `openSocket` 的函数类型：函数类型写不了"默认值"，
//   而两个实现都要有默认值 ⇒ 由门面（`socket_connector.dart`）条件导出
//   **同名顶层函数**，签名逐字一致（`openSocket(Uri, {headers, …})`）。
import 'dart:async';

/// 一条已打开的 WebSocket 连接（只暴露 EIO3 用得到的三件事）。
abstract class SocketLike {
  /// 收到的帧：`String`（文本帧）或 `List<int>`（二进制帧）。
  Stream<dynamic> get frames;

  void send(Object data);

  Future<void> close();
}
