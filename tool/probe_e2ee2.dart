// Phase 7 真机 E2EE 闭环（第二个成员 = #4 demo，实测它有公钥）。
//
// 试 `SYNO.Chat.Channel.Anonymous / initiate` 的几种参数形态，然后建真加密频道
// → 发加密消息 → 读回用频道密钥解密 → 收尾删除。
//
//   dart run -DSYNO_NAS_URL=... ... tool/probe_e2ee2.dart
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:synhub/src/core/crypto/sodium_crypto.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

String j(Object? v) => jsonEncode(v);

const me = 14;
const other = 4; // demo/demo_user：实测已注册公钥，是唯一能当加密频道成员的第二人

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

  // 我自己的密钥对：上面 probe 已经用口令 flt-e2ee-pass 注册过，这里按需重新生成
  const passcode = 'flt-e2ee-pass';
  final mine = SodiumCrypto.generateKeyPair();
  final myPrivEnc = SodiumCrypto.encryptPrivateKey(mine.privateKey, passcode);

  print('== 0. 先把我的公钥换成这次生成的（保证私钥在手）==');
  await api.call(
    'SYNO.Chat.User',
    'update_key',
    preferredVersion: 2,
    params: {
      'conn_id': j(sess.sid),
      'public_key': j(mine.publicKey),
      'private_key_enc': j(myPrivEnc),
      'channel_ids': j(<int>[]),
      'channel_key_encs': j(<String>[]),
      'archive_ids': j(<int>[]),
      'archive_key_encs': j(<String>[]),
    },
  );
  print('  ok, 公钥=${mine.publicKey}');

  print('\n== 1. 拿 #$other 的公钥 ==');
  final u = await api.call(
    'SYNO.Chat.User',
    'get',
    preferredVersion: 2,
    params: {'user_id': '$other'},
  );
  final otherPk =
      '${((u['user_props'] as Map)['key_pair'] as Map)['public_key']}';
  print('  #$other 公钥 = $otherPk');

  final channelKey = base64Decode(SodiumCrypto.generateChannelKey());
  final sealedForOther = SodiumCrypto.sealEncrypt(channelKey, otherPk);
  final sealedForMe = SodiumCrypto.sealEncrypt(channelKey, mine.publicKey);

  final variants = <String, Map<String, String>>{
    'A [other] + 1 个密钥': {
      'user_ids': j([other]),
      'channel_key_encs': j([sealedForOther]),
      'encrypted': 'true',
    },
    'B [other,me] + 2 个密钥': {
      'user_ids': j([other, me]),
      'channel_key_encs': j([sealedForOther, sealedForMe]),
      'encrypted': 'true',
    },
    'C [me,other] + 2 个密钥': {
      'user_ids': j([me, other]),
      'channel_key_encs': j([sealedForMe, sealedForOther]),
      'encrypted': 'true',
    },
    'D [other] 不带 channel_key_encs': {
      'user_ids': j([other]),
      'encrypted': 'true',
    },
    'E [other] encrypted=false（对照）': {
      'user_ids': j([other]),
      'channel_key_encs': j([sealedForOther]),
      'encrypted': 'false',
    },
    'F [other] v2': {
      'user_ids': j([other]),
      'channel_key_encs': j([sealedForOther]),
      'encrypted': 'true',
      '__version': '2',
    },
  };

  final created = <String, int>{};
  for (final e in variants.entries) {
    final params = Map<String, String>.from(e.value);
    final ver = int.parse(params.remove('__version') ?? '1');
    int? id;
    try {
      final r = await api.call(
        'SYNO.Chat.Channel.Anonymous',
        'initiate',
        preferredVersion: ver,
        params: params,
      );
      id =
          (r['channel'] as Map?)?['channel_id'] as int? ??
          r['channel_id'] as int?;
      print('  ${e.key} v$ver → #$id ${j(r).substring(0, 200)}');
    } catch (err) {
      print('  ${e.key} v$ver → ERR $err');
    }
    if (id != null) created[e.key] = id;
  }
  if (created.isEmpty) {
    print('\n都没建起来，收工');
    return;
  }

  // 用第一个建成的频道做闭环
  final entry = created.entries.first;
  final channelId = entry.value;
  print('\n== 2. 用「${entry.key}」# $channelId 做闭环 ==');
  final meta = await api.call(
    'SYNO.Chat.Channel',
    'list',
    preferredVersion: 4,
    params: {'channel_id': '$channelId'},
  );
  for (final c in (meta['channels'] as List? ?? [])) {
    final m = c as Map;
    print(
      '  #${m['channel_id']} type=${m['type']} encrypted=${m['encrypted']} '
      'key_enc=${'${m['channel_key_enc']}'.substring(0, 20)}… '
      'members=${j(m['members'])}',
    );
  }

  print('\n== 3. 发加密消息 → 读回解密 ==');
  const text = 'flt-e2ee-闭环 🙂 中文也 OK';
  final enc = SodiumCrypto.secretboxEncrypt(utf8.encode(text), channelKey);
  final res = await api.call(
    'SYNO.Chat.Post',
    'create',
    preferredVersion: 7,
    params: {
      'channel_id': '$channelId',
      'conn_id': j(sess.sid),
      'type': j('text'),
      'message': j(enc),
      'is_thread': 'false',
      'mobile_token': j('${DateTime.now().millisecondsSinceEpoch}'),
    },
  );
  final postId = (res['post'] as Map?)?['post_id'];
  print('  发出 post #$postId');

  final list = await api.call(
    'SYNO.Chat.Post',
    'list',
    preferredVersion: 7,
    params: {'channel_id': '$channelId', 'limit': '5', 'offset': '0'},
  );
  for (final p in (list['posts'] as List? ?? [])) {
    final m = p as Map;
    final raw = '${m['message']}';
    String dec;
    try {
      dec = utf8.decode(SodiumCrypto.secretboxDecryptRaw(raw, channelKey));
    } catch (e) {
      dec = '<解密失败>';
    }
    print('    #${m['post_id']} 密文=${raw.substring(0, 20)}… → "$dec"');
  }

  print('\n== 4. 收尾：删消息 + 删频道 ==');
  if (postId != null) {
    try {
      await api.call(
        'SYNO.Chat.Post',
        'delete',
        preferredVersion: 3,
        params: {'post_id': '$postId', 'channel_id': '$channelId'},
      );
      print('  消息已删');
    } catch (e) {
      print('  删消息失败：$e');
    }
  }
  for (final e in created.entries) {
    try {
      await api.call(
        'SYNO.Chat.Channel',
        'delete',
        preferredVersion: 1,
        params: {'channel_id': '${e.value}'},
      );
      print('  频道 #${e.value} 已删（${e.key}）');
    } catch (err) {
      print('  删频道 #${e.value} 失败：$err（留着）');
    }
  }
}
