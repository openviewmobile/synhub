// 探针：`SYNO.Chat.Misc acl v1` 在这台 NAS 上返回什么（权限表）。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
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
  final chat = ChatApi(api);
  final acls = await chat.fetchAcl();
  print('ACL 条数=${acls.length}');
  final keys = acls.keys.toList()..sort();
  for (final k in keys) {
    print('  $k = ${acls[k]}');
  }
  print(
    'channel_invite=${acls['channel_invite']} '
    'channel_kick=${acls['channel_kick']} '
    'channel_create=${acls['channel_create']}',
  );
  exit(0);
}
