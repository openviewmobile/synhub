// Phase 7 侦察 + **真机 E2EE 闭环**：密钥对上传 → 建加密频道 → 发加密消息 → 读回解密。
//
//   dart run -DSYNO_NAS_URL=... -DSYNO_NAS_ACCOUNT=... \
//            -D'SYNO_NAS_PASSWORD=...' tool/probe_e2ee.dart
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:synhub/src/core/crypto/sodium_crypto.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

String j(Object? v) => jsonEncode(v);

// 实测过：demo_user 的 chat user id 是 14（`User/list` 里 nickname 对应那条）
const myUserId = int.fromEnvironment('SYNO_MY_USER_ID', defaultValue: 14);

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
  print('我 = #$myUserId conn=${sess.sid.substring(0, 12)}…');

  print('\n== 1. NAS 上的 SYNO.Chat* API ==');
  final names =
      (api.apiTable?.keys ?? <String>[])
          .where((k) => k.startsWith('SYNO.Chat'))
          .toList()
        ..sort();
  for (final n in names) {
    print('  $n → ${api.apiTable![n]}');
  }

  print('\n== 2. 我自己的 key_pair ==');
  final me = await api.call(
    'SYNO.Chat.User',
    'get',
    preferredVersion: 2,
    params: {'user_id': '$myUserId'},
  );
  print('  user_props = ${j(me['user_props'])}');
  print('  key_pair = ${j(me['key_pair'])}');

  print('\n== 3. 生成密钥对 + update_key ==');
  final pair = SodiumCrypto.generateKeyPair();
  const passcode = 'flt-e2ee-pass';
  final privEnc = SodiumCrypto.encryptPrivateKey(pair.privateKey, passcode);
  print('  公钥 = ${pair.publicKey}');
  final upd = await api.call(
    'SYNO.Chat.User',
    'update_key',
    preferredVersion: 2,
    params: {
      'conn_id': j(sess.sid),
      'public_key': j(pair.publicKey),
      'private_key_enc': j(privEnc),
      'channel_ids': j(<int>[]),
      'channel_key_encs': j(<String>[]),
      'archive_ids': j(<int>[]),
      'archive_key_encs': j(<String>[]),
    },
  );
  print('  update_key → ${j(upd)}');

  final me2 = await api.call(
    'SYNO.Chat.User',
    'get',
    preferredVersion: 2,
    params: {'user_id': '$myUserId'},
  );
  print('  回读 key_pair = ${j(me2['key_pair'])}');

  print('\n== 4. 建加密频道（只有我自己）==');
  final channelKey = base64Decode(SodiumCrypto.generateChannelKey());
  final sealedForMe = SodiumCrypto.sealEncrypt(channelKey, pair.publicKey);
  int? channelId;
  try {
    final r = await api.call(
      'SYNO.Chat.Channel.Anonymous',
      'initiate',
      preferredVersion: 1,
      params: {
        'user_ids': j([myUserId]),
        'channel_key_encs': j([sealedForMe]),
        'encrypted': 'true',
      },
    );
    print('  initiate → ${j(r)}');
    channelId =
        (r['channel'] as Map?)?['channel_id'] as int? ??
        r['channel_id'] as int?;
  } catch (e) {
    print('  initiate → ERR $e');
  }
  if (channelId == null) {
    print('\n建不了只有自己的加密频道，收工');
    return;
  }
  print('  频道 = #$channelId');

  print('\n== 5. 读回频道元数据 ==');
  final ch = await api.call(
    'SYNO.Chat.Channel',
    'list',
    preferredVersion: 4,
    params: {'channel_id': '$channelId'},
  );
  print('  ${j(ch)}');

  print('\n== 6. 发加密消息再读回解密 ==');
  const text = 'flt-e2ee-闭环测试 🙂';
  final encrypted = SodiumCrypto.secretboxEncrypt(
    utf8.encode(text),
    channelKey,
  );
  final created = await api.call(
    'SYNO.Chat.Post',
    'create',
    preferredVersion: 7,
    params: {
      'channel_id': '$channelId',
      'conn_id': j(sess.sid),
      'type': j('text'),
      'message': j(encrypted),
      'is_thread': 'false',
      'mobile_token': j('${DateTime.now().millisecondsSinceEpoch}'),
    },
  );
  print('  create → ${j(created)}');
  final postId = (created['post'] as Map?)?['post_id'];

  final list = await api.call(
    'SYNO.Chat.Post',
    'list',
    preferredVersion: 7,
    params: {'channel_id': '$channelId', 'limit': '5', 'offset': '0'},
  );
  final posts = (list['posts'] as List?) ?? [];
  print('  读回 ${posts.length} 条');
  for (final p in posts) {
    final m = p as Map;
    final raw = '${m['message']}';
    String decoded;
    try {
      decoded = utf8.decode(SodiumCrypto.secretboxDecryptRaw(raw, channelKey));
    } catch (e) {
      decoded = '<解密失败: $e>';
    }
    print(
      '    #${m['post_id']} type=${m['type']} 密文=${raw.substring(0, 24)}… '
      '→ "$decoded"',
    );
  }

  print('\n== 7. 清理（删消息 + 删频道）==');
  if (postId != null) {
    try {
      final d = await api.call(
        'SYNO.Chat.Post',
        'delete',
        preferredVersion: 3,
        params: {'post_id': '$postId', 'channel_id': '$channelId'},
      );
      print('  Post/delete → ${j(d)}');
    } catch (e) {
      print('  Post/delete → ERR $e');
    }
  }
  try {
    final d = await api.call(
      'SYNO.Chat.Channel',
      'delete',
      preferredVersion: 1,
      params: {'channel_id': '$channelId'},
    );
    print('  Channel/delete → ${j(d)}');
  } catch (e) {
    print('  Channel/delete → ERR $e（频道会留着）');
  }
}
