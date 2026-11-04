// ChatSocket 离线验证 —— 用一个**照着实测帧写的**假 EIO3 / socket.io v2 服务端。
//
// 假服务端发的帧与真实 NAS 完全一致（见 test/fixtures/socket_frames.txt）：
//   0{"sid":...}  →  40  →  42["client.init",{"id":...,"version":"2.0.0"}]
// 客户端必须回 42["client.initdone"]。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';

class FakeChatServer {
  FakeChatServer({this.connId = 'conn-123', this.version = '2.0.0'});

  final String connId;
  final String version;

  HttpServer? _server;
  WebSocket? _ws;

  /// 客户端发来的原始帧
  final List<String> received = [];

  /// 客户端请求的 URI（含 query）
  Uri? requestUri;
  Map<String, String>? requestHeaders;

  int get port => _server!.port;
  String get baseUrl => 'http://127.0.0.1:$port/';

  Future<void> start({bool sendInit = true}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      requestUri = req.uri;
      requestHeaders = {
        'cookie': req.headers.value('cookie') ?? '',
        'origin': req.headers.value('origin') ?? '',
      };
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _ws = ws;

      // ① engine.io open
      ws.add(
        jsonEncode({
          'sid': 'engine-sid',
          'upgrades': <String>[],
          'pingInterval': 25000,
          'pingTimeout': 60000,
        }).replaceFirst('{', '0{'),
      );
      // ② socket.io 命名空间 ack
      ws.add('40');

      ws.listen((data) {
        received.add('$data');
        if ('$data'.contains('client.initdone')) {
          // 握手完成后推一条真实事件（客户端可能已经断开，忽略即可）
          _safeAdd(
            ws,
            '42${jsonEncode([
              'client.post.create',
              {
                'channel_id': 7,
                'user_id': 3,
                'data': {'post_id': 99, 'channel_id': 7, 'create_at': 1700000000000},
              },
            ])}',
          );
        }
      });

      if (sendInit) {
        Timer(const Duration(milliseconds: 50), () {
          _safeAdd(
            ws,
            '42${jsonEncode([
              'client.init',
              {'id': connId, 'version': version},
            ])}',
          );
        });
      }
    });
  }

  Future<void> push(String event, Object? payload) async {
    final ws = _ws;
    if (ws != null) _safeAdd(ws, '42${jsonEncode([event, payload])}');
  }

  /// 测试结束时客户端可能已关闭连接，写一个已关闭的 sink 会抛 StreamSink is closed
  static void _safeAdd(WebSocket ws, String frame) {
    try {
      ws.add(frame);
    } catch (_) {
      // 连接已关闭：忽略
    }
  }

  Future<void> stop() async {
    await _ws?.close();
    await _server?.close(force: true);
  }
}

void main() {
  test(
    'socket path 与 SocketHelper 一致：baseUrl.encodedPath() + sc/socket.io',
    () {
      expect(ChatSocket.socketPathFor('https://nas:5001/'), '/sc/socket.io');
      expect(ChatSocket.socketPathFor('https://nas:5001'), '/sc/socket.io');
      expect(
        ChatSocket.socketPathFor('https://nas:5001/chat/'),
        '/chat/sc/socket.io',
      );
    },
  );

  test('DSM 7.4 的 CSRF：socket 握手必须把 SynoToken 放**查询串**', () async {
    // 真机实测（DSM 7.4.1-90080）：不带令牌时服务端回 `44{"code":119}`
    // （sid not found，看着像会话失效），前端表现为一直"离线"；
    // 令牌放 cookie / 头部都不认，只有查询串上的 `SynoToken` 才行
    // —— 官方网页端 `SYNO.SDS.Chat.Socket.initSocket` 就是这么拼 query 的。
    final server = FakeChatServer()..start();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final socket = ChatSocket(
      baseUrl: server.baseUrl,
      sid: 'SID123',
      synotoken: 'SAN.tok-1',
    );
    addTearDown(socket.dispose);
    await socket.connect();
    await socket.waitReady(timeout: const Duration(seconds: 5));

    expect(server.requestUri!.queryParameters['client'], 'mobile');
    expect(server.requestUri!.queryParameters['SynoToken'], 'SAN.tok-1');
    // cookie 里照旧带会话（官方网页端靠 cookie 认会话）
    expect(server.requestHeaders!['cookie'], contains('id=SID123'));
    expect(server.requestHeaders!['cookie'], contains('synotoken=SAN.tok-1'));
  });

  test('没有令牌时查询串里不放 SynoToken（老 DSM 不需要它）', () async {
    final server = FakeChatServer()..start();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final socket = ChatSocket(baseUrl: server.baseUrl, sid: 'SID123');
    addTearDown(socket.dispose);
    await socket.connect();
    await socket.waitReady(timeout: const Duration(seconds: 5));

    expect(
      server.requestUri!.queryParameters.containsKey('SynoToken'),
      isFalse,
    );
  });

  test('握手：client.init → 存 conn_id → 回 client.initdone', () async {
    final server = FakeChatServer()..start();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final socket = ChatSocket(baseUrl: server.baseUrl, sid: 'SID123');
    addTearDown(socket.dispose);

    await socket.connect();
    await socket.waitReady(timeout: const Duration(seconds: 5));

    expect(socket.connId, 'conn-123');
    expect(socket.serverVersion, '2.0.0');
    expect(socket.status, ChatSocketStatus.ready);

    // 客户端回了 initdone
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.received.any((f) => f.contains('client.initdone')), isTrue);

    await server.stop();
  });

  test(
    '连接参数：transport=websocket、query 带 client=mobile、Cookie 带 id=<sid>',
    () async {
      final server = FakeChatServer()..start();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final socket = ChatSocket(
        baseUrl: server.baseUrl,
        sid: 'SID123',
        synotoken: 'TOKEN',
      );
      addTearDown(socket.dispose);
      await socket.connect();
      await socket.waitReady(timeout: const Duration(seconds: 5));

      // 库会在 path 末尾补一个 '/'；真实服务端两者都接受（探针用的是带 '/' 的形式）
      expect(server.requestUri!.path, anyOf('/sc/socket.io', '/sc/socket.io/'));
      expect(server.requestUri!.queryParameters['transport'], 'websocket');
      expect(server.requestUri!.queryParameters['client'], 'mobile');
      expect(server.requestUri!.queryParameters['EIO'], '3');

      final cookie = server.requestHeaders!['cookie'] ?? '';
      expect(cookie, contains('id=SID123'));
      expect(cookie, contains('synotoken=TOKEN'));

      await server.stop();
    },
  );

  test('握手之后的业务事件被转发到 events 流', () async {
    final server = FakeChatServer()..start();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final socket = ChatSocket(baseUrl: server.baseUrl, sid: 'SID');
    addTearDown(socket.dispose);
    final seen = <ChatSocketEvent>[];
    socket.events.listen(seen.add);

    await socket.connect();
    await socket.waitReady(timeout: const Duration(seconds: 5));

    // 服务端在收到 initdone 后推 post.create
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(seen, isNotEmpty);
    final e = seen.firstWhere((e) => e.event == 'client.post.create');
    expect(e.asMap!['channel_id'], 7);
    expect((e.asMap!['data'] as Map)['post_id'], 99);

    await server.stop();
  });

  test('服务端推 broadcast 也能收到', () async {
    final server = FakeChatServer()..start();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final socket = ChatSocket(baseUrl: server.baseUrl, sid: 'SID');
    addTearDown(socket.dispose);
    final seen = <ChatSocketEvent>[];
    socket.events.listen(seen.add);

    await socket.connect();
    await socket.waitReady(timeout: const Duration(seconds: 5));
    await server.push('client.broadcast', {
      'type': 'user.update',
      'data': {'user_id': 14, 'status': 'online'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final b = seen.firstWhere((e) => e.event == 'client.broadcast');
    expect(b.asMap!['type'], 'user.update');

    await server.stop();
  });

  test('超时未收到 client.init 时 waitReady 抛 TimeoutException', () async {
    final server = FakeChatServer()..start(sendInit: false);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final socket = ChatSocket(baseUrl: server.baseUrl, sid: 'SID');
    addTearDown(socket.dispose);
    await socket.connect();

    await expectLater(
      socket.waitReady(timeout: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );

    await server.stop();
  });
}
