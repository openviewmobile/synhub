// 探 `SYNO.Chat.Channel.Preference/set` 的正确参数形态。
// 真机集成测试里 v3 set 失败（ChannelPreference 只写 notification_mobile），
// 这里用直连把各种组合都试一遍，看服务端接受哪种。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print

Future<String> trySet(
  DsmWebApi api,
  int version,
  int channelId,
  Map<String, String> extra,
) async {
  try {
    final d = await api.call(
      'SYNO.Chat.Channel.Preference',
      'set',
      preferredVersion: version,
      params: {'channel_id': '$channelId', ...extra},
    );
    return 'OK ${jsonEncode(d)}';
  } catch (e) {
    return 'ERR $e';
  }
}

Future<String> tryGet(DsmWebApi api, int channelId) async {
  try {
    final d = await api.call(
      'SYNO.Chat.Channel.Preference',
      'get',
      preferredVersion: 2,
      params: {'channel_id': '$channelId'},
    );
    return 'OK ${jsonEncode(d)}';
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
  await api.login(
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );

  const cid = 23;
  print('get(#23)          → ${await tryGet(api, cid)}');

  print(
    'v3 {mobile=mention,none} bare    → '
    '${await trySet(api, 3, cid, {'notification_mobile': 'mention'})}',
  );
  print('get               → ${await tryGet(api, cid)}');

  print(
    'v3 mobile=JSON("none")           → '
    '${await trySet(api, 3, cid, {'notification_mobile': jsonEncode('none')})}',
  );
  print(
    'v3 +desktop=all                  → '
    '${await trySet(api, 3, cid, {'notification_mobile': 'all', 'notification_desktop': 'all'})}',
  );
  print(
    'v3 +mute=false                   → '
    '${await trySet(api, 3, cid, {'notification_mobile': 'all', 'notification_mute': 'false'})}',
  );
  print(
    'v2 mobile=none                   → '
    '${await trySet(api, 2, cid, {'notification_mobile': 'none'})}',
  );
  print(
    'v1 mobile=none                   → '
    '${await trySet(api, 1, cid, {'notification_mobile': 'none'})}',
  );
  print('final get         → ${await tryGet(api, cid)}');

  // 用 ChatApi 的正规路径再确认一次
  final chat = ChatApi(api);
  try {
    await chat.setChannelNotification(cid, 'all');
    print('ChatApi.setChannelNotification(all) → OK');
  } catch (e) {
    print('ChatApi.setChannelNotification(all) → ERR $e');
  }
  print('ChatApi.channelPreference → ${await chat.channelPreference(cid)}');
}
