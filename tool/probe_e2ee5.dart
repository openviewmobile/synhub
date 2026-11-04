// Phase 7：把上一轮弄坏（密钥丢了）的加密频道 #45 **救回来**，并跑通完整闭环。
//
// 用到的两条链路（都对应原 App 里 E2EE 的核心动作）：
//   * `SYNO.Chat.User / update_key`  ——  上传「我这个成员」的 channel_key_enc
//   * `SYNO.Chat.Channel / rescue`   ——  给「另一个成员」重新封一份 channel_key_enc
//
//   dart run -DSYNO_NAS_URL=... ... tool/probe_e2ee5.dart
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:synhub/src/core/crypto/sodium_crypto.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

String j(Object? v) => jsonEncode(v);

const me = 14;
const other = 4;
const passcode = 'flt-e2ee-pass';
const target = 45; // 上一轮 "initiate([4,14])" 建出来的加密频道

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

  print('== 1. 注册我的密钥对（本轮固定用这一对）==');
  final mine = SodiumCrypto.generateKeyPair();
  print('  我的公钥 = ${mine.publicKey}');
  final users = await api.call(
    'SYNO.Chat.User',
    'list',
    preferredVersion: 3,
    params: {'type': j('human')},
  );
  final otherPk =
      '${((((users['users'] as List).firstWhere((u) => (u as Map)['user_id'] == other) as Map)['user_props'] as Map)['key_pair'] as Map)['public_key']}';
  print('  #$other 公钥 = $otherPk');

  print('\n== 2. 给 #$target 生成一把新频道密钥，分别封给两个人 ==');
  final channelKey = base64Decode(SodiumCrypto.generateChannelKey());
  final sealedMe = SodiumCrypto.sealEncrypt(channelKey, mine.publicKey);
  final sealedOther = SodiumCrypto.sealEncrypt(channelKey, otherPk);

  final upd = await api.call(
    'SYNO.Chat.User',
    'update_key',
    preferredVersion: 2,
    params: {
      'conn_id': j(sess.sid),
      'public_key': j(mine.publicKey),
      'private_key_enc': j(
        SodiumCrypto.encryptPrivateKey(mine.privateKey, passcode),
      ),
      'channel_ids': j([target]),
      'channel_key_encs': j([sealedMe]),
      'archive_ids': j(<int>[]),
      'archive_key_encs': j(<String>[]),
    },
  );
  print('  update_key → ${j(upd)}');

  final rescue = await api.call(
    'SYNO.Chat.Channel',
    'rescue',
    preferredVersion: 1,
    params: {
      'user_id': '$other',
      'channel_id': '$target',
      'channel_key_enc': j(sealedOther),
    },
  );
  print('  rescue(#$other) → ${j(rescue)}');

  print('\n== 3. 读回频道，看服务端存了我的 channel_key_enc 没有 ==');
  final chans = await api.call(
    'SYNO.Chat.Channel',
    'list',
    preferredVersion: 5,
    params: {'member_count': j(40)},
  );
  String? serverEnc;
  for (final c in (chans['channels'] as List)) {
    final m = c as Map;
    if (m['channel_id'] == target) {
      print('  字段：${m.keys.toList()}');
      serverEnc = '${m['channel_key_enc'] ?? ''}';
      print(
        '  encrypted=${m['encrypted']} members=${j(m['members'])} '
        'channel_key_enc=${serverEnc.isEmpty ? "(空)" : "${serverEnc.substring(0, 20)}…"}',
      );
    }
  }
  if (serverEnc != null && serverEnc.isNotEmpty) {
    final got = SodiumCrypto.sealDecrypt(
      base64Decode(serverEnc),
      publicKeyBase64: mine.publicKey,
      privateKeyBase64: mine.privateKey,
    );
    print(
      '  服务端的 key_enc 解出来 == 我生成的频道密钥？ '
      '${base64Encode(got) == base64Encode(channelKey)}',
    );
  }

  print('\n== 4. 在这个频道里发加密消息 → 读回解密 ==');
  const text = 'flt-e2ee-闭环 🙂 中文 OK';
  final enc = SodiumCrypto.secretboxEncrypt(utf8.encode(text), channelKey);
  final res = await api.call(
    'SYNO.Chat.Post',
    'create',
    preferredVersion: 7,
    params: {
      'channel_id': '$target',
      'conn_id': j(sess.sid),
      'type': j('text'),
      'message': j(enc),
      'is_thread': 'false',
      'mobile_token': j('${DateTime.now().millisecondsSinceEpoch}'),
    },
  );
  final postId = (res['post'] as Map?)?['post_id'];
  print('  发出 #$postId');
  final list = await api.call(
    'SYNO.Chat.Post',
    'list',
    preferredVersion: 7,
    params: {'channel_id': '$target', 'limit': '5', 'offset': '0'},
  );
  var ok = 0;
  for (final p in (list['posts'] as List? ?? [])) {
    final m = p as Map;
    final raw = '${m['message']}';
    String dec;
    try {
      dec = utf8.decode(SodiumCrypto.secretboxDecryptRaw(raw, channelKey));
      ok++;
    } catch (e) {
      dec = '<解密失败>';
    }
    print('    #${m['post_id']} 密文与本地一致=${raw == enc} → "$dec"');
  }
  print('  能解出 $ok 条 ✓');

  print('\n== 5. 收尾：删掉测试消息 ==');
  if (postId != null) {
    try {
      await api.call(
        'SYNO.Chat.Post',
        'delete',
        preferredVersion: 3,
        params: {'post_id': '$postId', 'channel_id': '$target'},
      );
      print('  已删 #$postId');
    } catch (e) {
      print('  删失败：$e');
    }
  }
  print('\n#45 现在是「我和 #4 的可用加密频道」——功能验证留着它。');
}
