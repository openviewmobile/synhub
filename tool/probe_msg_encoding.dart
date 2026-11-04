// 探 `Post/create` 的 `message` 到底要不要 JSON 编码一次（表单 vs multipart）。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      const String.fromEnvironment('SYNO_NAS_URL'),
      dio: DioFactory.create(),
    ),
  );
  await api.discover();
  final sess = await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  final chat = ChatApi(api);
  final created = <int>[];
  try {
    // 表单：JSON 编码
    var r = await api.call(
      'SYNO.Chat.Post',
      'create',
      preferredVersion: 7,
      params: {
        'channel_id': '1',
        'conn_id': jsonEncode(sess.sid),
        'type': jsonEncode('normal'),
        'message': jsonEncode('flt-probe-form-quoted'),
        'is_thread': 'false',
        'mobile_token': jsonEncode(''),
      },
    );
    var id = ((r['post'] ?? r) as Map)['post_id'] as int;
    created.add(id);
    print('表单+JSON → 存成 ${((r['post'] ?? r) as Map)['message']}');

    await Future<void>.delayed(const Duration(seconds: 3));
    // 表单：裸文本
    r = await api.call(
      'SYNO.Chat.Post',
      'create',
      preferredVersion: 7,
      params: {
        'channel_id': '1',
        'conn_id': jsonEncode(sess.sid),
        'type': jsonEncode('normal'),
        'message': 'flt-probe-form-raw',
        'is_thread': 'false',
        'mobile_token': jsonEncode(''),
      },
    );
    id = ((r['post'] ?? r) as Map)['post_id'] as int;
    created.add(id);
    print('表单+裸文本 → 存成 ${((r['post'] ?? r) as Map)['message']}');

    // multipart：JSON 编码 / 裸文本
    final dir = Directory.systemTemp.createTempSync('p5m');
    final f = File('${dir.path}/flt-probe-m.txt')..writeAsStringSync('x');
    for (final enc in [true, false]) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final raw = await chat.uploadPost(
        channelId: 1,
        connId: sess.sid,
        filePath: f.path,
        fileName: 'flt-probe-m.txt',
        message: enc
            ? jsonEncode('flt-probe-multi-quoted')
            : 'flt-probe-multi-raw',
      );
      created.add((raw['post_id'] as num).toInt());
      print('multipart ${enc ? 'JSON' : '裸文本'} → 存成 ${raw['message']}');
    }
    dir.deleteSync(recursive: true);
  } finally {
    for (final id in created) {
      try {
        await chat.deletePost(id);
      } catch (_) {}
    }
    print('已清理 ${created.length} 条');
  }
}
