// Phase 7：处理上一轮留下的不可解密频道 #45，然后建一个**密钥正确**的加密频道
// 做完整闭环。
//
// 学到的东西：
//   * `SYNO.Chat.Channel / delete` 不存在（103）
//   * 删人走 `SYNO.Chat.Channel.Named / kick`（经 `SYNO.Entry.Request` 复合请求）
//   * `Anonymous / initiate` 对**已存在的成员组合**回 117（跟本地已有频道冲突）
//
//   dart run -DSYNO_NAS_URL=... ... tool/probe_e2ee4.dart
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

  /// `SYNO.Chat.Channel.Named / kick`，跟原 App 一样走复合请求
  Future<Map<String, dynamic>> kick(int channelId, int userId) async {
    final inner = jsonEncode({
      'api': 'SYNO.Chat.Channel.Named',
      'method': 'kick',
      'version': 1,
      'channel_id': channelId,
      'user_id': userId,
    });
    final r = await api.call(
      'SYNO.Entry.Request',
      'request',
      preferredVersion: 2,
      params: {
        'compound': jsonEncode([
          {
            'api': 'SYNO.Chat.Channel.Named',
            'method': 'kick',
            'version': 1,
            'channel_id': channelId,
            'user_id': userId,
          },
        ]),
        'mode': 'parallel',
      },
    );
    print('    kick($channelId, $userId) → ${j(r).substring(0, 160)}');
    print('    (inner=$inner)');
    return Map<String, dynamic>.from(r);
  }

  Future<List<Map<String, dynamic>>> encryptedChannels() async {
    final chans = await api.call(
      'SYNO.Chat.Channel',
      'list',
      preferredVersion: 5,
      params: {'member_count': j(40)},
    );
    return ((chans['channels'] as List?) ?? [])
        .cast<Map>()
        .where((m) => m['encrypted'] == true)
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  print('== 0. 注册我的密钥对 ==');
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

  print('\n== 1. 当前加密频道 ==');
  final before = await encryptedChannels();
  for (final c in before) {
    print('  #${c['channel_id']} members=${j(c['members'])}');
  }
  final stale = before.where((c) => c['channel_id'] == 45).toList();

  print('\n== 2. 试着把 #45 里的人踢掉（踢我自己 = 退出）==');
  for (final c in stale) {
    final id = c['channel_id'] as int;
    try {
      await kick(id, other);
    } catch (e) {
      print('    kick other → ERR $e');
    }
    try {
      await kick(id, me);
    } catch (e) {
      print('    kick me → ERR $e');
    }
  }
  print('  踢完再列一次：');
  for (final c in await encryptedChannels()) {
    print('    #${c['channel_id']} members=${j(c['members'])}');
  }

  print('\n== 3. 建新的加密频道（密钥封对收件人）==');
  final users = await api.call(
    'SYNO.Chat.User',
    'list',
    preferredVersion: 3,
    params: {'type': j('human')},
  );
  final otherPk =
      '${((((users['users'] as List).firstWhere((u) => (u as Map)['user_id'] == other) as Map)['user_props'] as Map)['key_pair'] as Map)['public_key']}';
  print('  #$other 公钥 = $otherPk');
  final channelKey = base64Decode(SodiumCrypto.generateChannelKey());
  int? channelId;
  try {
    final r = await api.call(
      'SYNO.Chat.Channel.Anonymous',
      'initiate',
      preferredVersion: 1,
      params: {
        'user_ids': j([other, me]),
        'channel_key_encs': j([
          SodiumCrypto.sealEncrypt(channelKey, otherPk),
          SodiumCrypto.sealEncrypt(channelKey, mine.publicKey),
        ]),
        'encrypted': 'true',
      },
    );
    final ch = (r['channel'] as Map?) ?? r;
    channelId = ch['channel_id'] as int?;
    final myEnc = '${ch['channel_key_enc'] ?? ''}';
    print('  → #$channelId  返回字段=${ch.keys.toList()}');
    if (myEnc.isNotEmpty) {
      final got = SodiumCrypto.sealDecrypt(
        base64Decode(myEnc),
        publicKeyBase64: mine.publicKey,
        privateKeyBase64: mine.privateKey,
      );
      print(
        '  服务端保存的 channel_key_enc 解出来 == 我生成的频道密钥？ '
        '${base64Encode(got) == base64Encode(channelKey)}',
      );
    } else {
      print('  （响应里没有 channel_key_enc，得用本地生成的钥匙）');
    }
  } catch (e) {
    print('  initiate → ERR $e');
  }
  if (channelId == null) {
    print('\n建不起来，收工');
    return;
  }

  print('\n== 4. 发加密消息 → 读回解密 ==');
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
  print('  发出 #$postId');
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
    print('    #${m['post_id']} 与本地密文一致=${raw == enc} → "$dec"');
  }

  print('\n== 5. 收尾 ==');
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
    await kick(channelId, other);
    await kick(channelId, me);
    print('  已把人踢出 #$channelId');
  } catch (e) {
    print('  踢人失败：$e');
  }
  print('  最终加密频道：');
  for (final c in await encryptedChannels()) {
    print('    #${c['channel_id']} members=${j(c['members'])}');
  }
}
