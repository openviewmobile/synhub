// 清掉 #45 里遗留的加密测试消息（前几轮探针发的）。
// ignore_for_file: avoid_print
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

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
  final list = await api.call(
    'SYNO.Chat.Post',
    'list',
    preferredVersion: 8,
    params: {'channel_id': '45', 'limit': '100', 'offset': '0'},
  );
  for (final p in (list['posts'] as List)) {
    final m = p as Map;
    print(
      '  #${m['post_id']} type=${m['type']} user=${m['user_id']} '
      'msg=${'${m['message']}'}',
    );
  }
  for (final p in (list['posts'] as List)) {
    final m = p as Map;
    try {
      await api.call(
        'SYNO.Chat.Post',
        'delete',
        preferredVersion: 3,
        params: {'post_id': '${m['post_id']}'},
      );
      print('  已删 #${m['post_id']}');
    } catch (e) {
      print('  删 #${m['post_id']} 失败：$e');
    }
  }
  final after = await api.call(
    'SYNO.Chat.Post',
    'list',
    preferredVersion: 8,
    params: {'channel_id': '45', 'limit': '100', 'offset': '0'},
  );
  print('剩余 ${(after['posts'] as List).length} 条');
}
