// 探针：真机 `/webapi` 的 `SYNO.Chat.Channel / list` 原始字段（对齐 2.4.7-22203 服务端）。
//
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//     dart run tool/flt_channel_fields.dart
//
// 目的：2.4.7 的 `etc/db_schema/39.sql` 新增了 `channels.last_user_post_at`，且
// `webapi/SYNO.Chat.Channel.so` 里出现该字符串 → 确认 HTTP 响应是否真的带这个字段
// （我们的 `ChannelDto` 目前不解析它）。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );

  final data = await api.call(
    'SYNO.Chat.Channel',
    'list',
    preferredVersion: 5,
    params: {'is_joined': ''},
  );
  final channels = (data['channels'] as List).cast<Map>();
  print('channels=${channels.length}');
  for (final c in channels) {
    final map = Map<String, dynamic>.from(c);
    final ch = map['channel'] is Map
        ? Map<String, dynamic>.from(map['channel'] as Map)
        : map;
    print('\n#${ch['channel_id']} ${ch['name']}  type=${ch['type']}');
    print('  channel 键: ${(ch.keys.toList()..sort()).join(', ')}');
    final props = ch['props'];
    if (props is Map) {
      print('  props 键: ${(props.keys.toList()..sort()).join(', ')}');
    }
    for (final k in [
      'last_user_post_at',
      'post_id_since',
      'last_post_at',
      'unread',
      'unread_comment',
      'is_joined',
      'is_starred',
      'is_hidden',
      'close_at',
      'create_at',
      'update_at',
    ]) {
      if (ch.containsKey(k)) print('  $k = ${ch[k]}');
    }
    if (props is Map) {
      for (final k in ['last_user_post_at', 'post_id_since']) {
        if (props.containsKey(k)) print('  props.$k = ${props[k]}');
      }
    }
  }
  await api.logout();
  exit(0);
}
