// ignore_for_file: avoid_print
import 'dart:convert';
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
  print(
    'User.Preference maxVersion=${api.apiTable?['SYNO.Chat.User.Preference']?.maxVersion} '
    'User maxVersion=${api.apiTable?['SYNO.Chat.User']?.maxVersion}',
  );
  for (final v in [4, 3, 2, 1]) {
    try {
      final d = await api.call(
        'SYNO.Chat.User.Preference',
        'get',
        preferredVersion: v,
      );
      print('pref get v$v → ${jsonEncode(d)}');
      break;
    } catch (e) {
      print('pref get v$v → $e');
    }
  }
  final me = await chat.myUser();
  print('myUser: id=${me?.userId}');
  for (final v in [3, 2, 1]) {
    try {
      final d = await api.call(
        'SYNO.Chat.User.Preference',
        'get',
        preferredVersion: v,
      );
      print('pref get v$v → ${jsonEncode(d)}');
    } catch (e) {
      print('pref get v$v → $e');
    }
  }
  try {
    final r = await api.call(
      'SYNO.Chat.User',
      'list',
      preferredVersion: 3,
      params: {'type': 'human', 'user_ids': '[14]'},
    );
    final u = ((r['users'] as List).first) as Map;
    print('User/list v3 我 → keys=${u.keys.toList()}');
    print('  user_props=${jsonEncode(u['user_props'])}');
  } catch (e) {
    print('User/list v3 → $e');
  }
  try {
    final r = await api.call(
      'SYNO.Chat.Channel.Member',
      'get',
      preferredVersion: 1,
      params: {'channel_id': '1'},
    );
    final ms = (r['members'] as List);
    for (final m in ms) {
      final mm = m as Map;
      if (mm['user_id'] == 14 || (mm['user'] as Map?)?['user_id'] == 14) {
        print('Member/get 我 → ${jsonEncode(mm)}');
      }
    }
  } catch (e) {
    print('Member/get → $e');
  }
  try {
    final r = await api.call(
      'SYNO.Chat.User',
      'get',
      preferredVersion: 3,
      params: {'user_id': '14'},
    );
    print('User/get v3 raw keys=${(r['user'] ?? r).keys.toList()}');
    final u = (r['user'] ?? r) as Map;
    print(
      '  timezone=${u['timezone']} timezone_utc=${u['timezone_utc']} '
      'preference=${jsonEncode(u['preference'])}',
    );
  } catch (e) {
    print('User/get v3 → $e');
  }
  await api.logout();
  exit(0);
}
