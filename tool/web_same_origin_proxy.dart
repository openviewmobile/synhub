// r715：**同源装置**（Web 站 C2/C4 的仪器）。
//
// 为什么必须有它：Web 站的跨源代价是**浏览器语义**，不是产品缺陷 ——
//   * `/webapi` 不回 `access-control-allow-origin`；
//   * cookie 不随**跨站** WebSocket 握手发送 ⇒ 聊天 `connId` 空。
// 想证明"同源部署后就对了"，就必须让 **App 与 /webapi 处在同一个 origin**。
// `flutter drive -d web-server` 的 App origin 固定是 `localhost:<web-port>`，
// 所以这里用一个**极简 HTTP 代理**把 `/webapi`、`/sc` 转发到 Mock，
// 其余原样转发给 flutter 的 dev server —— 浏览器看到的 origin **自始至终不变**。
//
// 用法（配合 flutter drive 的 `--web-browser-flag=--proxy-server=…`）：
//     dart run tool/web_same_origin_proxy.dart --listen 18081 --app 8132 --api 18080
//
// 另一种用法（C2：`go_router` 的 URL 策略 —— 刷新深链会不会 404）：
//     dart run tool/web_same_origin_proxy.dart --listen 18082 --static build/web
//   ⇒ 把 `build/web` 当 SPA 伺服：**任何** path 都回 `index.html`（真部署就该这样）。
//
// 只用 `dart:io`（本仓无 git、不引第三方包）。
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> argv) async {
  var listen = 18081;
  final appHost = '127.0.0.1';
  var appPort = 8132;
  var apiPort = 18080;
  String? staticRoot;
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--listen':
        listen = int.parse(argv[++i]);
      case '--app':
        appPort = int.parse(argv[++i]);
      case '--api':
        apiPort = int.parse(argv[++i]);
      case '--static':
        staticRoot = argv[++i];
    }
  }

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, listen);
  stdout.writeln(staticRoot != null
      ? '[proxy] http://127.0.0.1:$listen  →  static $staticRoot（SPA fallback）'
      : '[proxy] http://127.0.0.1:$listen  /webapi|/sc → :$apiPort ，其余 → $appHost:$appPort');
  await for (final socket in server) {
    if (staticRoot != null) {
      unawaited(_serveStatic(socket, staticRoot, apiPort));
    } else {
      unawaited(_proxy(socket, appHost, appPort, apiPort));
    }
  }
}

/// 极简反向代理：攒够一个请求头 → 选上游 → 转成 origin-form → **裸管道**。
///
/// 只有第一条请求被解析/改写；之后的字节一律原样双向搬运
/// （WebSocket 升级帧、chunked 响应都在其中）。`Connection: close` 让浏览器
/// 每个请求新建连接 —— 对"逐场景导航"的走查足够，也避免自己实现管线化。
Future<void> _proxy(
    Socket down, String appHost, int appPort, int apiPort) async {
  final buf = <int>[];
  Socket? up;
  var upstreamDone = false;
  late StreamSubscription<List<int>> sub;

  Future<void> connectUpstream(int head) async {
    final raw = String.fromCharCodes(buf.sublist(0, head));
    final lines = raw.split('\r\n');
    final parts = lines.first.split(' ');
    if (parts.length < 3) {
      await down.close();
      return;
    }
    final method = parts[0];
    var path = parts[1];
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final u = Uri.parse(path);
      path = u.path.isEmpty ? '/' : u.path;
      if (u.hasQuery) path = '$path?${u.query}';
    }
    final toApi = path.startsWith('/webapi') || path.startsWith('/sc');
    final port = toApi ? apiPort : appPort;

    final fwd = <String>['$method $path ${parts[2]}'];
    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      if (line.toLowerCase().startsWith('proxy-connection:')) continue;
      fwd.add(line);
    }
    fwd.add('Connection: close');

    try {
      up = await Socket.connect(InternetAddress.loopbackIPv4, port);
    } catch (e) {
      stderr.writeln('[proxy] upstream :$port 连不上（$e）');
      await down.close();
      return;
    }
    final u = up!;
    u.add('${fwd.join('\r\n')}\r\n\r\n'.codeUnits);
    final rest = buf.sublist(head);
    if (rest.isNotEmpty) u.add(rest);
    buf.clear();

    // 上游 → 下游
    u.listen(down.add, onDone: () {
      upstreamDone = true;
      down.destroy();
    }, onError: (_) => down.destroy(), cancelOnError: true);
  }

  sub = down.listen((chunk) {
    if (up == null) {
      buf.addAll(chunk);
      final head = _headEnd(buf);
      if (head < 0) return;
      sub.pause();
      connectUpstream(head).whenComplete(() {
        if (!upstreamDone) {
          sub.resume();
        }
      });
      return;
    }
    up!.add(chunk);
  }, onDone: () {
    up?.destroy();
  }, onError: (_) {
    up?.destroy();
    down.destroy();
  });
}

int _headEnd(List<int> buf) {
  for (var i = 3; i < buf.length; i++) {
    if (buf[i] == 10 &&
        buf[i - 1] == 13 &&
        buf[i - 2] == 10 &&
        buf[i - 3] == 13) {
      return i + 1;
    }
  }
  return -1;
}

/// SPA 伺服：目录内文件优先，找不到就回 `index.html`（真部署同款）。
///
/// ★ `--static` 与 `--api` 同时给时就是**单端口同源**：`/webapi`、`/sc`
/// 原样转发给 Mock（同 origin），其余当文件伺服 —— Web C4 的判据就是这条。
Future<void> _serveStatic(Socket down, String root, int apiPort) async {
  final buf = <int>[];
  Socket? up;
  late StreamSubscription<List<int>> sub;

  Future<void> handleHead(int head) async {
    final raw = String.fromCharCodes(buf.sublist(0, head));
    final lines = raw.split('\r\n');
    final parts = lines.first.split(' ');
    var path = parts.length > 1 ? parts[1] : '/';
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final u = Uri.parse(path);
      path = u.path.isEmpty ? '/' : u.path;
      if (u.hasQuery) path = '$path?${u.query}';
    }
    final apiPath = path;
    final filePath = path.split('?').first;

    if (apiPath.startsWith('/webapi') || apiPath.startsWith('/sc')) {
      try {
        up = await Socket.connect(InternetAddress.loopbackIPv4, apiPort);
      } catch (e) {
        stderr.writeln('[static] upstream :$apiPort 连不上（$e）');
        await down.close();
        return;
      }
      final u = up!;
      final fwd = <String>['${parts[0]} $apiPath ${parts.length > 2 ? parts[2] : 'HTTP/1.1'}'];
      for (final line in lines.skip(1)) {
        if (line.isEmpty) continue;
        if (line.toLowerCase().startsWith('proxy-connection:')) continue;
        fwd.add(line);
      }
      fwd.add('Connection: close');
      u.add('${fwd.join('\r\n')}\r\n\r\n'.codeUnits);
      final rest = buf.sublist(head);
      if (rest.isNotEmpty) u.add(rest);
      u.listen(down.add, onDone: down.destroy, onError: (_) => down.destroy(),
          cancelOnError: true);
      return;
    }

    var rel = filePath == '/' ? '/index.html' : filePath;
    var file = File('$root$rel');
    if (!file.existsSync()) {
      file = File('$root/index.html');
      rel = '/index.html';
    }
    if (!file.existsSync()) {
      down.add('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
          .codeUnits);
      await down.flush();
      await down.close();
      return;
    }
    final body = file.readAsBytesSync();
    down.add('HTTP/1.1 200 OK\r\n'
            'Content-Type: ${_mime(rel)}\r\n'
            'Content-Length: ${body.length}\r\n'
            'Cache-Control: no-store\r\n'
            'Connection: close\r\n\r\n'
        .codeUnits);
    down.add(body);
    await down.flush();
    await down.close();
  }

  sub = down.listen((chunk) {
    if (up != null) {
      up!.add(chunk);
      return;
    }
    buf.addAll(chunk);
    final head = _headEnd(buf);
    if (head < 0) {
      if (buf.length > 64 * 1024) down.destroy();
      return;
    }
    sub.pause();
    handleHead(head).whenComplete(() {
      if (up == null) {
        buf.clear();
      } else {
        sub.resume();
      }
    });
  }, onDone: () => up?.destroy(), onError: (_) {
    up?.destroy();
    down.destroy();
  });
}

String _mime(String path) {
  if (path.endsWith('.html')) return 'text/html; charset=utf-8';
  if (path.endsWith('.js')) return 'application/javascript';
  if (path.endsWith('.json')) return 'application/json';
  if (path.endsWith('.wasm')) return 'application/wasm';
  if (path.endsWith('.css')) return 'text/css';
  if (path.endsWith('.png')) return 'image/png';
  if (path.endsWith('.svg')) return 'image/svg+xml';
  if (path.endsWith('.ttf')) return 'font/ttf';
  if (path.endsWith('.otf')) return 'font/otf';
  return 'application/octet-stream';
}
