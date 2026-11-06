// ignore_for_file: avoid_print
// Phase 2 联调探针：登录 → compound 批量 → socket.io(EIO3) 握手
//
// 用法：
//   SYNO_NAS_URL=https://nas.example.com:5001 \
//   SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//   dart run tool/probe_chat.dart
//
// 目的：在写 lib/src/data/** 之前，先把真实响应与 socket 帧格式摸清楚。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

class _AllowSelfSigned extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..badCertificateCallback = (_, _, _) => true;
}

Future<void> main() async {
  HttpOverrides.global = _AllowSelfSigned();

  final url = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'];
  if (url == null || account == null || password == null) {
    stderr.writeln('需要 SYNO_NAS_URL / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD');
    exit(2);
  }

  final dio = DioFactory.create();
  final jar = dio.interceptors.whereType<CookieJarInterceptor>().first;
  final api = DsmWebApi(DirectTransport.url(url, dio: dio));

  await api.discover();
  final session = await api.login(
    account: account,
    password: password,
    session: 'Chat',
  );
  print('sid = ${session.sid}');
  print('did = ${session.did}');
  print('jar = ${jar.cookies}');

  final fixtures = Directory('test/fixtures')..createSync(recursive: true);

  // ---------------------------------------------------------------- channels
  print('\n=== Channel.list (is_joined=true) ===');
  try {
    final r = await api.call(
      'SYNO.Chat.Channel',
      'list',
      preferredVersion: 5,
      params: {'is_joined': 'true'},
    );
    _f(
      fixtures,
      'channel_list.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(r));
    final chans = (r['channels'] as List?) ?? const [];
    print('频道数 = ${chans.length}');
    if (chans.isNotEmpty) {
      print(
        '首个频道原样 JSON:\n${const JsonEncoder.withIndent("  ").convert(chans.first)}',
      );
    }
  } catch (e) {
    print('Channel.list 失败: $e');
  }

  // ---------------------------------------------------------------- compound
  print('\n=== compound: User.list(human) + User.list(bot) ===');
  final compound = jsonEncode([
    {'api': 'SYNO.Chat.User', 'method': 'list', 'version': 2, 'type': 'human'},
    {'api': 'SYNO.Chat.User', 'method': 'list', 'version': 2, 'type': 'bot'},
  ]);
  try {
    final r = await api.call(
      'SYNO.Entry.Request',
      'request',
      preferredVersion: 2,
      params: {'compound': compound, 'mode': 'parallel'},
    );
    _f(
      fixtures,
      'compound_users.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(r));
    final results = (r['result'] as List?) ?? const [];
    print('compound 返回 ${results.length} 段');
    for (final seg in results) {
      final users = ((seg as Map)['data']?['users'] as List?) ?? const [];
      print('  段: success=${seg['success']} users=${users.length}');
    }
    if (results.isNotEmpty) {
      final users =
          ((results.first as Map)['data']?['users'] as List?) ?? const [];
      if (users.isNotEmpty) {
        print(
          '首个用户原样 JSON:\n${const JsonEncoder.withIndent("  ").convert(users.first)}',
        );
      }
    }
  } catch (e) {
    print('compound 失败: $e');
  }

  // ---------------------------------------------------------------- socket
  print('\n=== socket.io / EIO3 探测 ===');
  await _probeSocket(url, jar.cookies, session.sid, fixtures);

  await api.logout();
  await api.transport.close();
}

File _f(Directory dir, String name) => File('${dir.path}/$name');

Future<void> _probeSocket(
  String url,
  Map<String, String> cookies,
  String sid,
  Directory fixtures,
) async {
  final uri = Uri.parse(url);
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  final cookieHeader = {
    ...cookies,
    'id': sid,
  }.entries.map((e) => '${e.key}=${e.value}').join('; ');

  final wsUrl =
      '$scheme://${uri.host}:${uri.port}/sc/socket.io/?EIO=3&transport=websocket&client=mobile';
  print('连接 $wsUrl');
  try {
    final ws = await WebSocket.connect(
      wsUrl,
      headers: {'Cookie': cookieHeader},
    );
    final frames = <String>[];
    final sub = ws.listen(
      (data) {
        frames.add('$data');
        print('  ← $data');
      },
      onError: (e) => print('  ws error: $e'),
      onDone: () => print('  ws done'),
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    if (frames.any((f) => f.startsWith('0{'))) {
      print('  → 发送 socket.io connect 包 "40"');
      ws.add('40');
      await Future<void>.delayed(const Duration(seconds: 2));
      final hasInit = frames.any((f) => f.contains('client.init'));
      print('  收到 client.init? $hasInit');
      if (hasInit) {
        print('  → 发送 "42[\\"client.initdone\\"]"');
        ws.add('42${jsonEncode(['client.initdone'])}');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    await ws.close();
    await sub.cancel();
    _f(fixtures, 'socket_frames.txt').writeAsStringSync(frames.join('\n'));
  } catch (e) {
    print('socket 探测失败: $e');
  }
}
