// 探针：`User/update_key` 会不会把 `client.user.updatekey` 广播给同账号的其它会话，
// 以及载荷长什么样。顺便看 `Channel/list` 里有没有 `broken_users`。
//
//   dart run tool/flt_key_probe.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;

  Future<(DsmWebApi, ChatApi, String, String?)> login() async {
    final api = DsmWebApi(
      DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
    );
    await api.discover();
    final s = await api.login(
      account: account,
      password: password,
      session: 'Chat',
    );
    return (api, ChatApi(api), s.sid, s.synotoken);
  }

  final (apiA, chatA, sidA, tokA) = await login();
  final (_, _, sidB, tokB) = await login();

  // ① broken_users 有没有？
  final channels = await chatA.listChannels();
  for (final c in channels) {
    if (c.encrypted) print('频道 #${c.channelId} broken_users=${c.brokenUsers}');
  }

  final socketA = ChatSocket(baseUrl: url, sid: sidA, synotoken: tokA);
  final socketB = ChatSocket(baseUrl: url, sid: sidB, synotoken: tokB);
  final events = <String>[];
  socketB.events.listen((e) => events.add('${e.event} ${e.payload}'));
  await socketA.connect();
  await socketA.waitReady(timeout: const Duration(seconds: 25));
  await socketB.connect();
  await socketB.waitReady(timeout: const Duration(seconds: 25));
  print('两条连接就绪 connA=${socketA.connId} connB=${socketB.connId}');

  // ② 拿服务端当前存的密钥对（广播里的 user.update 就带）
  final me = await chatA.myUser();
  final pub = me?.publicKey ?? '';
  final priv = me?.privateKeyEnc ?? '';
  print('服务端上的公钥长度=${pub.length} 私钥密文长度=${priv.length}');
  if (pub.isEmpty) {
    print('服务端没有密钥对，跳过 update_key 探测');
    exit(0);
  }

  // ③ 原样重传一次（不改状态），看 B 收不收得到广播
  await chatA.updateKey(
    connId: socketA.connId ?? '',
    publicKey: pub,
    privateKeyEnc: priv,
  );
  await Future<void>.delayed(const Duration(seconds: 5));
  print('=== B 收到的事件 ===');
  for (final e in events) {
    print(e.length > 600 ? '${e.substring(0, 600)}…' : e);
  }
  socketA.dispose();
  socketB.dispose();
  exit(0);
}
