// Phase 7 真机 E2EE 闭环（修正版）：
//   1. 从 `User/list` 取 #4 的**真**公钥（`User/get` 的 user_id 参数其实被忽略，
//      返回的是自己——上一轮踩过）
//   2. 删掉上一轮误建的 #45（封错了收件人）
//   3. `Anonymous/initiate([4,14], channel_key_encs=[封给4, 封给我], encrypted=true)`
//   4. 发加密消息 → 读回解密 → 删消息 + 删频道
//
//   dart run -DSYNO_NAS_URL=... ... tool/probe_e2ee3.dart
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:synhub/src/core/crypto/sodium_crypto.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

String j(Object? v) => jsonEncode(v);

const me = 14;
const other = 4;
const passcode = 'flt-e2ee-pass';

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

  print('== 1. 注册我的密钥对（私钥在手才能解密）==');
  final mine = SodiumCrypto.generateKeyPair();
  await api.call(
    'SYNO.Chat.User',
    'update_key',
    preferredVersion: 2,
    params: {
      'conn_id': j(sess.sid),
      'public_key': j(mine.publicKey),
      'private_key_enc': j(
        SodiumCrypto.encryptPrivateKey(mine.privateKey, passcode),
      ),
      'channel_ids': j(<int>[]),
      'channel_key_encs': j(<String>[]),
      'archive_ids': j(<int>[]),
      'archive_key_encs': j(<String>[]),
    },
  );
  print('  我的公钥 = ${mine.publicKey}');

  print('\n== 2. 取 #$other 真公钥（User/list）==');
  final users = await api.call(
    'SYNO.Chat.User',
    'list',
    preferredVersion: 3,
    params: {'type': j('human')},
  );
  String? otherPk;
  for (final u in (users['users'] as List)) {
    final m = u as Map;
    if (m['user_id'] == other) {
      otherPk =
          '${((m['user_props'] as Map)['key_pair'] as Map)['public_key']}';
    }
  }
  print('  #$other 公钥 = $otherPk');
  if (otherPk == null || otherPk.isEmpty) {
    print('  #$other 没有公钥，没法当加密频道成员');
    return;
  }

  print('\n== 3. 清掉上一轮误建的加密频道 ==');
  final chans = await api.call(
    'SYNO.Chat.Channel',
    'list',
    preferredVersion: 5,
    params: {
      'member_count': j(40),
      'additional': j(['encrypted']),
    },
  );
  for (final c in (chans['channels'] as List? ?? [])) {
    final m = c as Map;
    if (m['encrypted'] == true) {
      print('  发现加密频道 #${m['channel_id']} members=${j(m['members'])}');
      try {
        await api.call(
          'SYNO.Chat.Channel',
          'delete',
          preferredVersion: 1,
          params: {'channel_id': '${m['channel_id']}'},
        );
        print('    已删 #${m['channel_id']}');
      } catch (e) {
        print('    删不了 #${m['channel_id']}：$e');
      }
    }
  }

  print('\n== 4. 建加密频道 ==');
  final channelKey = base64Decode(SodiumCrypto.generateChannelKey());
  final sealedOther = SodiumCrypto.sealEncrypt(channelKey, otherPk);
  final sealedMe = SodiumCrypto.sealEncrypt(channelKey, mine.publicKey);
  final r = await api.call(
    'SYNO.Chat.Channel.Anonymous',
    'initiate',
    preferredVersion: 1,
    params: {
      'user_ids': j([other, me]),
      'channel_key_encs': j([sealedOther, sealedMe]),
      'encrypted': 'true',
    },
  );
  final channelId = (r['channel'] as Map?)?['channel_id'] as int?;
  print('  → #$channelId');
  print(
    '  我的 channel_key_enc = ${'${r['channel']?['channel_key_enc'] ?? r['channel_key_enc']}'.substring(0, 24)}…',
  );
  print('  raw keys in resp = ${(r['channel'] as Map? ?? r).keys.toList()}');

  print('\n== 5. 验证我自己的 channel_key_enc 能解出频道密钥 ==');
  final myEnc =
      '${(r['channel'] as Map?)?['channel_key_enc'] ?? r['channel_key_enc'] ?? ''}';
  if (myEnc.isNotEmpty) {
    final got = SodiumCrypto.sealDecrypt(
      base64Decode(myEnc),
      publicKeyBase64: mine.publicKey,
      privateKeyBase64: mine.privateKey,
    );
    print(
      '  解出来 == 生成的频道密钥？ ${utf8.decode(got, allowMalformed: true) == base64Encode(channelKey) || base64Encode(got) == base64Encode(channelKey)}',
    );
    if (base64Encode(got) != base64Encode(channelKey)) {
      print('  解出 = ${base64Encode(got)}  期望 = ${base64Encode(channelKey)}');
    }
  }

  print('\n== 6. 发加密消息 → 读回解密 ==');
  const text = 'flt-e2ee-闭环 🙂 中文 OK';
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
  print('  发出 #$postId，密文 = ${enc.substring(0, 24)}…');

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
    print('    #${m['post_id']} → "$dec"');
    print('    密文与本地一致？ ${raw == enc}');
  }

  print('\n== 7. 收尾 ==');
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
  try {
    await api.call(
      'SYNO.Chat.Channel',
      'delete',
      preferredVersion: 1,
      params: {'channel_id': '$channelId'},
    );
    print('  频道 #$channelId 已删');
  } catch (e) {
    print('  删频道失败：$e（留着 #$channelId）');
  }
}
