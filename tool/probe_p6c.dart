// Phase 6 剩余项探针 2：机器人列表 / 斜杠命令用户 / 发起机器人会话 / 归档相关。
import 'dart:convert';
import 'package:synhub/src/core/net/dio_factory.dart';
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
  await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  String j(Object v) => jsonEncode(v);

  Future<void> tryCall(
    String label,
    String name,
    String method,
    Map<String, dynamic> params, {
    int version = 1,
  }) async {
    try {
      final r = await api.call(
        name,
        method,
        preferredVersion: version,
        params: params,
      );
      final s = jsonEncode(r);
      print('$label → ${s.length > 1500 ? '${s.substring(0, 1500)}…' : s}');
    } catch (e) {
      print('$label → ERR $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  print('== User/list 全量（看 type / slash_props / is_bot）==');
  await tryCall('User/list v1', 'SYNO.Chat.User', 'list', {}, version: 1);
  print('\n== User/list type=bot（JSON 与裸串都试）==');
  await tryCall('type="bot"', 'SYNO.Chat.User', 'list', {'type': j('bot')});
  await tryCall('type=bot', 'SYNO.Chat.User', 'list', {'type': 'bot'});
  await tryCall('type="all"', 'SYNO.Chat.User', 'list', {'type': j('all')});
  print('\n== 机器人会话 ==');
  await tryCall(
    'Chatbot/list_blocked',
    'SYNO.Chat.Channel.Chatbot',
    'list_blocked',
    {},
  );
  print('\n== Bot API ==');
  await tryCall('Bot/list?', 'SYNO.Chat.Bot', 'list', {});
}
