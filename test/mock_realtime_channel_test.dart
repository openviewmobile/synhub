// Mock 的 **Chat 实时通道（Engine.IO v3 / socket.io v2）** 回归锁。
//
// 为什么要有这条用例（第 282 轮定性）：
//   第 280 轮 macOS 上 Chat 显示 `Sync failed · 0 channels`，一度怀疑"macOS 特有"。
//   真因是 **Mock 根本没有 socket 通道**（`GET /sc/socket.io` 被当业务请求处理），
//   于是**任何平台**对 Mock 的实时通道都必然失败 ⇒ 那是 Mock 缺口。
//   本用例把"Mock 必须支持实时通道"钉住，顺带把"仓库自己的客户端连得上"也钉住
//   （客户端只走 websocket，见 `lib/src/data/remote/socket/eio3_client.dart` 头注释）。
//
// 口径：这是**传输层**契约（升级 + open 包 + `40` 命名空间握手 + polling 握手），
// **不**覆盖业务事件（频道/消息推送那层 Mock 还没实现，见 docs/platform-macos.md §3.5.3）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/remote/socket/eio3_client.dart';

import '../tool/mock_dsm/mock_dsm_server.dart';

void main() {
  late MockDsmHttpServer mock;

  setUpAll(() async {
    mock = await MockDsmHttpServer.start(port: 0);
  });

  tearDownAll(() async => mock.stop());

  test('① 仓库自己的 Eio3Client 能连上 Mock 的实时通道（不再 MissingPlugin/连不上）', () async {
    final client = Eio3Client(baseUrl: mock.baseUrl);
    final errors = <Object>[];
    client.onError = errors.add;
    await client.connect(); // 连不上会抛 Eio3Exception
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(errors, isEmpty, reason: '连接过程不应报错：$errors');
    await client.close();
  });

  test('② polling 握手回 Engine.IO open 包（手动 curl / 其它客户端可读）', () async {
    final http = HttpClient();
    final req = await http.getUrl(
      Uri.parse('${mock.baseUrl}sc/socket.io/?EIO=3&transport=polling'),
    );
    final res = await req.close();
    final body = await res.transform(const SystemEncoding().decoder).join();
    http.close();
    expect(res.statusCode, 200);
    expect(body.startsWith('0{'), isTrue, reason: 'open 包应以 0 开头：$body');
    expect(body, contains('sid'));
  });

  test('③ 非升级请求却要 websocket ⇒ 400（诚实报错，不假装成功）', () async {
    final http = HttpClient();
    final req = await http.getUrl(
      Uri.parse('${mock.baseUrl}sc/socket.io/?EIO=3&transport=websocket'),
    );
    final res = await req.close();
    await res.drain<void>();
    http.close();
    expect(res.statusCode, HttpStatus.badRequest);
  });
}
