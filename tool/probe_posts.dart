// 抓真实 `SYNO.Chat.Post / list` 响应，落成 Phase 3 的测试 fixture。
//
// 用法：
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//     dart run tool/probe_posts.dart [channel_id] [prev_count]
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print

void main(List<String> args) async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;

  final api = DsmWebApi(DirectTransport.url(url, dio: DioFactory.create()));
  await api.discover();
  await api.login(account: account, password: password, session: 'Chat');
  final chat = ChatApi(api);

  var channelId = args.isNotEmpty ? int.parse(args.first) : 0;
  final prevCount = args.length > 1 ? int.parse(args[1]) : 50;
  if (channelId == 0) {
    final channels = await chat.listChannels();
    channelId = channels.first.channelId;
  }

  // 走原始 call，顺便把整个 data 结构打出来（顶层键名要确认清楚）
  final data = await api.call(
    'SYNO.Chat.Post',
    'list',
    preferredVersion: 2,
    params: {
      'channel_id': '$channelId',
      'prev_count': '$prevCount',
      'next_count': '0',
    },
  );
  print('data 顶层键: ${data.keys.toList()}');
  final posts = data['posts'];
  print(
    'posts 条数: ${posts is List ? posts.length : "非数组: ${posts.runtimeType}"}',
  );
  if (posts is List && posts.isNotEmpty) {
    print('第一条键: ${(posts.first as Map).keys.toList()}');
    print(const JsonEncoder.withIndent('  ').convert(posts.first));
  }

  final out = File('test/fixtures/post_list.json');
  out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  print('已写入 ${out.path}');

  await api.logout();
  await api.transport.close();
}
