// 探针：`Channel/list` 什么时候才下发 `channel_order_time`（侧栏"接收时间"排序用）。
//
// ⚠️ 2.4.7-22203 实测的坑：**只有 v5 + `is_joined=true` 才返回这个字段**；
// 不传 `is_joined`（或传 false / 空串）时字段整个消失，看着像"服务端不支持"。
// 原版客户端走的就是 v5 + is_joined=true（`AccountManager.isSupportSortChannelByMethod`
// 也是看 `SYNO.Chat.Channel` 支持不支持 5）。
//
// 用法：SYNO_NAS_* dart run tool/probe_channel_order.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final transport = DirectTransport.url(
    Platform.environment['SYNO_NAS_URL']!,
    dio: DioFactory.create(allowSelfSigned: true),
  );
  final api = DsmWebApi(transport);
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );
  final chat = ChatApi(api);
  print(
    'SYNO.Chat.Channel 版本区间 = ${api.apiTable?['SYNO.Chat.Channel']?.minVersion}'
    '..${api.apiTable?['SYNO.Chat.Channel']?.maxVersion}，'
    '协商结果=${chat.negotiate('SYNO.Chat.Channel', const [5, 4, 3, 2, 1])}',
  );

  for (final params in <Map<String, String>>[
    {'is_joined': 'true'},
    {}, // ← 陷阱：字段会消失
  ]) {
    for (final v in [5, 4]) {
      final data = await api.call(
        'SYNO.Chat.Channel',
        'list',
        preferredVersion: v,
        params: params,
      );
      final list = (data['channels'] as List).cast<Map>();
      final withField = list
          .where((c) => c.containsKey('channel_order_time'))
          .length;
      print(
        'params=$params v=$v → ${list.length} 条，含 channel_order_time $withField 条',
      );
      if (withField == 0) continue;
      for (final c in list.take(40)) {
        print(
          '  #${c['channel_id']} type=${c['type']} name="${c['name']}" '
          'order=${c['channel_order_time']} last_post=${c['last_post_at']} '
          '一致=${c['channel_order_time'] == c['last_post_at']} '
          'unread=${c['unread']}+${c['unread_comment'] ?? 0}',
        );
      }
      print('---- 原始第一条 ----');
      print(const JsonEncoder.withIndent('  ').convert(list.first));
      break;
    }
  }
  exit(0);
}
