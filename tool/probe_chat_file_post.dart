// ignore_for_file: avoid_print
// 只读探针（r617）：频道 #261 里那条 .epub 文件消息到底在不在 `Post/list` 的窗口里？
//
// 用法：source ~/.synhub-nas.env 之后
//   dart run tool/probe_chat_file_post.dart
//
// 只调用 `SYNO.Chat.Channel/list` 与 `SYNO.Chat.Post/list`（**读动词**）。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

class _AllowSelfSigned extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..badCertificateCallback = (_, __, ___) => true;
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
  final api = DsmWebApi(DirectTransport.url(url, dio: dio));
  await api.discover();
  await api.login(account: account, password: password, session: 'Chat');

  const channel = 261;

  Future<void> dump(String label, Map<String, dynamic> params) async {
    print('\n=== $label  params=$params');
    try {
      final r = await api.call(
        'SYNO.Chat.Post',
        'list',
        preferredVersion: 3,
        params: params,
      );
      final posts = (r['posts'] as List?) ?? const [];
      print('posts=${posts.length}');
      for (final p in posts.whereType<Map>()) {
        final att = (p['attachments'] as List?) ?? const [];
        final names = att.whereType<Map>().map((a) {
          final f = a['file'] ?? a['name'] ?? a['filename'];
          return '$f';
        }).toList();
        final t = p['create_at'] ?? p['createAt'];
        final ts = t is num
            ? DateTime.fromMillisecondsSinceEpoch((t * 1000).toInt()).toString()
            : '$t';
        print('  id=${p['post_id']} at=$ts  msg=${p['message']}  att=$names');
      }
    } catch (e) {
      print('  失败: $e');
    }
  }

  await dump('最近 60 条', {
    'channel_id': '$channel',
    'prev_count': '60',
    'next_count': '0',
    'has': jsonEncode(['thread']),
  });

  await dump('按扩展名 epub 过滤', {
    'channel_id': '$channel',
    'prev_count': '50',
    'next_count': '0',
    'has': jsonEncode(['thread']),
    'file_type': jsonEncode(['epub']),
  });

  await dump('按分类 file 过滤', {
    'channel_id': '$channel',
    'prev_count': '50',
    'next_count': '0',
    'has': jsonEncode(['thread']),
    'file_type': jsonEncode(['file']),
  });
}
