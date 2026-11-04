// 打洞**全栈回环装置**（r684）—— 不连 NAS、不连外网，全部在 127.0.0.1 上。
//
// 为什么要它：`s283` 只证了"库能加载、没有对端时如实失败"。真实链路
// （打洞交换 → UDT 建链 → 两个中继引擎 → 本地 TCP）此前只在宿主 C++
// 单测（`reimpl/tests/test_relay_client.cpp`）里跑过，**iOS 上没跑过**。
// 这里把同一套拓扑搬到 Dart：假 echo 服务器 + 假 NAS 服务端 + 两个真库实例
// （被动方 listener / 发起方 client），最后从发起方的本地 TCP 端口发 `ping`，
// 一路穿到对端再回来收 `pong`。
//
//   Dart TCP 客户端 ──► 发起方引擎(真库) ──► UDT 隧道 ──► 被动方引擎(真库)
//        ▲                                                     │
//        └────────────── "pong" ◄── 假 NAS(TCP) ◄───────────────┘
//
// 装置里有两处"假"，必须说清：① echo 服务器是假的（真货是 Synology 的
// QuickConnect 打洞服务器 + UDP echo）；② NAS 服务端是假的（真货是那台 NAS
// 的 DSM）。**打洞交换与 UDT 隧道本身跑的是真库代码**。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:synhub/src/native/punch_ffi.dart';

/// 假 echo 服务器：收 148 字节打洞命令，回一条"对端地址 = 我们指定的"。
///
/// 协议照 `reimpl/src/protocol.cpp`：`command_t` 定长 148；
/// 校验和 = f0 + code + length + option + rand_b + rand_c + rand_d + payload[0..length)，
/// 先按**主机序**求和，再以大端写回 0x0a 两个字节。
class FakePunchEcho {
  FakePunchEcho._(this._sock);

  static Future<FakePunchEcho> start() async {
    final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final echo = FakePunchEcho._(sock);
    sock.listen(echo._onEvent);
    return echo;
  }

  final RawDatagramSocket _sock;

  /// 应答里要写的"对端 UDT 端口"（被动方 prepare 之后才知道）
  int replyPort = 0;
  int get port => _sock.port;
  int requests = 0;

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _sock.receive();
    if (dg == null) return;
    final req = dg.data;
    if (req.isEmpty) return; // TTL 敲门包（0 字节）
    if (req.length != 148) return;
    requests++;
    _sock.send(buildReply(req, replyPort), dg.address, dg.port);
  }

  /// 组装 148 字节应答：`payload[0:4]=127.0.0.1`、`payload[4:6]=port`（大端）。
  static Uint8List buildReply(Uint8List req, int port) {
    final out = Uint8List(148);
    // code 原样搬（0x04..0x07），保持大端
    out[4] = req[4];
    out[5] = req[5];
    out[6] = req[6];
    out[7] = req[7];
    const len = 6;
    out[8] = 0;
    out[9] = len;
    out[12] = 1; // option = WithPayload
    out[20] = 127;
    out[21] = 0;
    out[22] = 0;
    out[23] = 1;
    out[24] = (port >> 8) & 0xff;
    out[25] = port & 0xff;
    // 主机序求和（rand 全 0，f0 = 0）
    final code = (req[4] << 24) | (req[5] << 16) | (req[6] << 8) | req[7];
    var sum = code + len + 1;
    for (var i = 20; i < 20 + len; i++) {
      sum += out[i];
    }
    final cs = sum & 0xffff;
    out[10] = (cs >> 8) & 0xff;
    out[11] = cs & 0xff;
    return out;
  }

  void close() => _sock.close();
}

/// 假 NAS：TCP 上收 `ping` 回 `pong`（被动方收到 OPEN 后会拨号到这里）。
class FakeNasServer {
  FakeNasServer._(this._server);

  static Future<FakeNasServer> start() async {
    final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final nas = FakeNasServer._(srv);
    srv.listen(nas._onConn);
    return nas;
  }

  final ServerSocket _server;
  int get port => _server.port;
  final List<String> seen = <String>[];

  void _onConn(Socket c) {
    c.listen((data) {
      final s = String.fromCharCodes(data);
      if (s.isEmpty) return;
      seen.add(s);
      if (s.contains('ping')) c.write('pong');
    }, onError: (_) {}, cancelOnError: false);
  }

  Future<void> close() => _server.close();
}

// ---------------------------------------------------------------- 子 isolate
//
// `prepare/awaitPeer` 是**同步阻塞**的（与原库一致），所以每一侧都跑在自己的
// isolate 里；主 isolate 只做编排 + 端到端 TCP 观测。

class _Msg {
  _Msg(this.kind, {this.port = 0, this.error = ''});
  final String kind; // prepared / up / error / bye
  final int port;
  final String error;
}

Future<void> _passiveMain(List<Object?> args) async {
  final reply = args[0] as SendPort;
  final libPath = args[1] as String?;
  final echoPort = args[2] as int;
  final ctl = ReceivePort();
  reply.send(ctl.sendPort);
  final punch = libPath == null
      ? SynoPunch.load()
      : SynoPunch.load(libraryPath: libPath);
  try {
    punch
      ..serverId = 'r684-loopback'
      ..serviceType = SynoServiceType.dsmHttps
      ..punchTimeoutMs = 2000
      ..connectTimeoutMs = 8000
      ..addEchoServer('127.0.0.1', echoPort);
    var rc = punch.prepare();
    if (rc != 0) {
      reply.send(_Msg('error', error: 'prepare=$rc ${punch.lastError}'));
      return;
    }
    reply.send(_Msg('prepared', port: punch.udtPort));

    await for (final raw in ctl) {
      final m = raw as Map;
      if (m['cmd'] != 'go') {
        if (m['cmd'] == 'stop') break;
        continue;
      }
      punch.localServicePort = m['nasPort'] as int;
      rc = punch.awaitPeer();
      if (rc != 0) {
        reply.send(_Msg('error', error: 'awaitPeer=$rc ${punch.lastError}'));
        return;
      }
      rc = punch.startEngine();
      if (rc != 0) {
        reply.send(_Msg('error', error: 'startEngine=$rc ${punch.lastError}'));
        return;
      }
      reply.send(_Msg('up', port: punch.tcpPort));
      // 一直驱动事件循环（引擎没有自己的线程）
      for (;;) {
        punch.pump(timeoutMs: 5);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        if (_stopRequested) break;
      }
    }
  } catch (e) {
    reply.send(_Msg('error', error: '异常: $e'));
  } finally {
    punch.stop();
    punch.dispose();
    reply.send(_Msg('bye'));
  }
}

bool _stopRequested = false;

Future<void> _initiatorMain(List<Object?> args) async {
  final reply = args[0] as SendPort;
  final libPath = args[1] as String?;
  final echoPort = args[2] as int;
  final peerPort = args[3] as int;
  final ctl = ReceivePort();
  reply.send(ctl.sendPort);
  final punch = libPath == null
      ? SynoPunch.load()
      : SynoPunch.load(libraryPath: libPath);
  try {
    punch
      ..serverId = 'r684-loopback'
      ..serviceType = SynoServiceType.dsmHttps
      ..punchTimeoutMs = 2000
      ..connectTimeoutMs = 8000
      ..rendezvous = false // 对端是纯 listener（与 C++ 单测同口径）
      ..addEchoServer('127.0.0.1', echoPort)
      ..setCandidate('127.0.0.1', peerPort);
    var rc = punch.prepare();
    if (rc != 0) {
      reply.send(_Msg('error', error: 'prepare=$rc ${punch.lastError}'));
      return;
    }
    reply.send(_Msg('prepared', port: punch.udtPort));
    rc = punch.awaitPeer();
    if (rc != 0) {
      reply.send(_Msg('error', error: 'awaitPeer=$rc ${punch.lastError}'));
      return;
    }
    rc = punch.startEngine();
    if (rc != 0) {
      reply.send(_Msg('error', error: 'startEngine=$rc ${punch.lastError}'));
      return;
    }
    reply.send(_Msg('up', port: punch.tcpPort));
    for (;;) {
      punch.pump(timeoutMs: 5);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      if (_stopRequested) break;
    }
  } catch (e) {
    reply.send(_Msg('error', error: '异常: $e'));
  } finally {
    punch.stop();
    punch.dispose();
    reply.send(_Msg('bye'));
  }
}

class _Side {
  _Side(this.isolate, this.ctl, this.msgs, this.prepared, this.up, this.error,
      this.bye);

  final Isolate isolate;
  final SendPort ctl;
  final ReceivePort msgs;
  final Completer<int> prepared;
  final Completer<int> up;
  final Completer<String> error;
  final Completer<void> bye;

  void send(Map<String, Object?> m) => ctl.send(m);

  void dispose() {
    try {
      ctl.send(<String, Object?>{'cmd': 'stop'});
    } catch (_) {}
    isolate.kill(priority: Isolate.immediate);
    msgs.close();
  }
}

Future<_Side> _spawn(
  Future<void> Function(List<Object?>) entry,
  List<Object?> args,
) async {
  final msgs = ReceivePort();
  final prepared = Completer<int>();
  final up = Completer<int>();
  final error = Completer<String>();
  final bye = Completer<void>();
  final ready = Completer<SendPort>();
  msgs.listen((raw) {
    if (raw is SendPort) {
      ready.complete(raw);
      return;
    }
    if (raw is _Msg) {
      switch (raw.kind) {
        case 'error':
          if (!error.isCompleted) error.complete(raw.error);
        case 'bye':
          if (!bye.isCompleted) bye.complete();
        case 'prepared':
          if (!prepared.isCompleted) prepared.complete(raw.port);
        case 'up':
          if (!up.isCompleted) up.complete(raw.port);
      }
    }
  });
  final iso = await Isolate.spawn(entry, <Object?>[msgs.sendPort, ...args]);
  final ctlPort = await ready.future.timeout(const Duration(seconds: 10));
  return _Side(iso, ctlPort, msgs, prepared, up, error, bye);
}

/// 装置跑完的读数（给用例打印/断言）
class PunchLoopbackReading {
  PunchLoopbackReading({
    required this.udtPort,
    required this.initiatorTcpPort,
    required this.passiveTcpPort,
    required this.echoRequests,
    required this.nasSeen,
    required this.reply,
  });

  final int udtPort;
  final int initiatorTcpPort;
  final int passiveTcpPort;
  final int echoRequests;
  final List<String> nasSeen;
  final String reply;

  bool get ok => reply.contains('pong');
}

/// 把整套拓扑跑一遍：返回读数（失败抛 `StateError`，带原始错误名）。
Future<PunchLoopbackReading> runPunchLoopback({String? libraryPath}) async {
  final echo = await FakePunchEcho.start();
  final nas = await FakeNasServer.start();
  _Side? passive;
  _Side? initiator;
  try {
    // ---- 被动方：先 prepare 拿 UDT 端口，再告诉假 echo ----
    passive = await _spawn(_passiveMain, <Object?>[libraryPath, echo.port]);
    final udtPort = await Future.any<int>([
      passive.prepared.future,
      passive.error.future.then<int>((e) => throw StateError('被动方: $e')),
    ]).timeout(const Duration(seconds: 15));
    echo.replyPort = udtPort;

    // ---- 起点：告诉被动方开始接入（它收到 OPEN 会拨到假 NAS）----
    passive.send(<String, Object?>{'cmd': 'go', 'nasPort': nas.port});

    // ---- 发起方：候选地址 = 被动方 UDT 端口 ----
    initiator = await _spawn(_initiatorMain, <Object?>[
      libraryPath,
      echo.port,
      udtPort,
    ]);
    final initTcp = await Future.any<int>([
      initiator.up.future,
      initiator.error.future.then<int>((e) => throw StateError('发起方: $e')),
    ]).timeout(const Duration(seconds: 20));
    final passiveTcp = await Future.any<int>([
      passive.up.future,
      passive.error.future.then<int>((e) => throw StateError('被动方: $e')),
    ]).timeout(const Duration(seconds: 20));

    // ---- 真数据：本地 TCP 客户端 → 隧道 → 假 NAS → 回来 ----
    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      initTcp,
      timeout: const Duration(seconds: 5),
    );
    final buf = StringBuffer();
    client.listen((d) => buf.write(String.fromCharCodes(d)));
    client.write('ping');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!buf.toString().contains('pong') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    client.destroy();

    return PunchLoopbackReading(
      udtPort: udtPort,
      initiatorTcpPort: initTcp,
      passiveTcpPort: passiveTcp,
      echoRequests: echo.requests,
      nasSeen: List<String>.unmodifiable(nas.seen),
      reply: buf.toString(),
    );
  } finally {
    _stopRequested = true;
    initiator?.dispose();
    passive?.dispose();
    await nas.close();
    echo.close();
  }
}
