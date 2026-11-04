// 证书问题回归测试 —— 真机上最容易翻车的一环。
//
// 背景：NAS 常见两种情况
//   1. 自签证书（`CN=nas.example.com`）
//   2. **正式证书但用 IP 访问** —— 本机 NAS 就是这种：Let's Encrypt 签的
//      `*.nas.example.com`，我们却连 `https://nas.example.com:5001`，
//      主机名必然不匹配。
//
// `dart:io` 的 `WebSocket.connect` 默认严格校验，而且它内部那个
// `static final HttpClient _httpClient` 无法用 `HttpOverrides.global` 可靠替换
// （static final，懒加载一次；实测在装 override 之后仍然握手失败）。
// 唯一可靠的口子是 `WebSocket.connect(..., customClient:)` ——
// [Eio3Client] 正是这么做的，所以这里直接用真 TLS 服务端验证：
//   ① 不传 customClient（严格）        → 必须失败（证明这个坑真实存在）
//   ② ChatSocket（内部传 customClient）→ 必须握手成功
//   ③ ChatSocket(allowSelfSigned:false) → 必须失败（策略是可关的）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';

/// 生成自签证书，CN/SAN 都不是 127.0.0.1 —— 同时模拟"不受信 + 主机名不匹配"
Future<(String cert, String key)> _makeCert(Directory dir) async {
  final cert = '${dir.path}/cert.pem';
  final key = '${dir.path}/key.pem';
  final r = await Process.run('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    key,
    '-out',
    cert,
    '-days',
    '2',
    '-subj',
    '/CN=nas.local',
    '-addext',
    'subjectAltName=DNS:nas.local',
  ]);
  if (r.exitCode != 0) {
    throw StateError('openssl 生成证书失败: ${r.stderr}');
  }
  return (cert, key);
}

/// 真的 TLS websocket 服务端，按 EIO3 协议回 open/40/client.init
class TlsFakeChatServer {
  TlsFakeChatServer(this.context);

  final SecurityContext context;
  HttpServer? _server;

  int get port => _server!.port;
  String get baseUrl => 'https://127.0.0.1:$port/';

  Future<void> start() async {
    _server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    _server!.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      ws.add(
        '0${jsonEncode({'sid': 'tls-sid', 'upgrades': <String>[], 'pingInterval': 25000, 'pingTimeout': 60000})}',
      );
      ws.add('40');
      Timer(const Duration(milliseconds: 50), () {
        try {
          ws.add(
            '42${jsonEncode([
              'client.init',
              {'id': 'tls-conn', 'version': '2.0.0'},
            ])}',
          );
        } catch (_) {}
      });
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

void main() {
  late Directory dir;
  late SecurityContext ctx;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('syno-tls-');
    final (cert, key) = await _makeCert(dir);
    ctx = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  test('① 不传 customClient 时 websocket 必然握手失败（坑真实存在）', () async {
    final server = TlsFakeChatServer(ctx);
    await server.start();
    addTearDown(server.stop);

    var error = '';
    try {
      final ws = await WebSocket.connect('wss://127.0.0.1:${server.port}/x');
      await ws.close();
      error = 'CONNECTED_WITHOUT_ERROR';
    } catch (e) {
      error = '$e';
    }

    expect(error, contains('HandshakeException'), reason: '实际: $error');
  });

  test('② ChatSocket 用 customClient → 自签+主机名不匹配也能完成握手', () async {
    final server = TlsFakeChatServer(ctx);
    await server.start();
    addTearDown(server.stop);

    final socket = ChatSocket(baseUrl: server.baseUrl, sid: 'SID');
    addTearDown(socket.dispose);
    await socket.connect();
    await socket.waitReady(timeout: const Duration(seconds: 10));

    expect(socket.connId, 'tls-conn');
    expect(socket.serverVersion, '2.0.0');
    expect(socket.status, ChatSocketStatus.ready);
  });

  test('③ allowSelfSigned=false 时确实会失败（策略可关）', () async {
    final server = TlsFakeChatServer(ctx);
    await server.start();
    addTearDown(server.stop);

    final socket = ChatSocket(
      baseUrl: server.baseUrl,
      sid: 'SID',
      autoReconnect: false,
      allowSelfSigned: false,
    );
    addTearDown(socket.dispose);

    Object? error;
    try {
      await socket.connect();
      await socket.waitReady(timeout: const Duration(seconds: 5));
    } catch (e) {
      error = e;
    }

    expect(error, isNotNull, reason: '严格模式下不该连上');
    expect('$error', contains('HandshakeException'), reason: '实际: $error');
  });

  test('④ Cookie 头按 `id=<sid>; synotoken=<t>` 拼（服务端要这个）', () async {
    final server = TlsFakeChatServer(ctx);
    await server.start();
    addTearDown(server.stop);

    final socket = ChatSocket(
      baseUrl: server.baseUrl,
      sid: 'SID123',
      synotoken: 'TOK456',
    );
    addTearDown(socket.dispose);
    await socket.connect();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(socket.cookies['id'], 'SID123');
    expect(socket.cookies['synotoken'], 'TOK456');
  });
}
