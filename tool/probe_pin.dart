// 探 `SYNO.Chat.Post/stick` 报 407(CHAT_ERR_INVALID_RECORD) 的原因。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print

Future<String> tryCall(
  DsmWebApi api,
  String method,
  Map<String, String> p,
) async {
  try {
    final d = await api.call(
      'SYNO.Chat.Post',
      method,
      preferredVersion: 2,
      params: p,
    );
    final s = jsonEncode(d);
    return 'OK ${s.length > 100 ? s.substring(0, 100) : s}';
  } catch (e) {
    return 'ERR $e';
  }
}

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(),
    ),
  );
  await api.discover();
  final sess = await api.login(
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );
  final chat = ChatApi(api);

  // 造一条测试消息（用 http 创建，不依赖 socket）
  final created = await chat.createPost(
    channelId: 1,
    message: 'flt-probe-pin',
    connId: 'probe',
  );
  final pid = (created['post_id'] as num).toInt();
  print('测试消息 post_id=$pid');
  print('lastPinAt 字段 = ${created['last_pin_at']}');

  print(
    'stick(post_id only) → ${await tryCall(api, 'stick', {'post_id': '$pid'})}',
  );
  print(
    'stick(+channel_id) → ${await tryCall(api, 'stick', {'post_id': '$pid', 'channel_id': '1'})}',
  );
  print(
    'stick(+conn_id) → ${await tryCall(api, 'stick', {'post_id': '$pid', 'conn_id': jsonEncode(sess.sid)})}',
  );
  print('unstick → ${await tryCall(api, 'unstick', {'post_id': '$pid'})}');
  print('star → ${await tryCall(api, 'star', {'post_id': '$pid'})}');
  print('unstar → ${await tryCall(api, 'unstar', {'post_id': '$pid'})}');
  print('bookmark? → ${await tryCall(api, 'bookmark', {'post_id': '$pid'})}');

  await chat.deletePost(pid);
  print('已清理 $pid');
}
