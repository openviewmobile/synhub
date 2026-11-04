// 把加密频道 #45 **按服务端现存的那对密钥**重新分发一遍（不改身份）。
//
// 场景：新设备（本机 App）第一次 setup 会重新生成密钥对并把服务端记录顶掉，
// 旧频道密钥就没人能解了。这个脚本用「服务端记录里的公钥 + 口令解出的私钥」
// 重新生成一把频道密钥，分别登记给我自己（`update_key`）和另一位成员
// （`rescue`），频道就恢复可用，而且**设备端能用口令解锁后解开**。
//
//   dart run -DSYNO_NAS_URL=... ... tool/probe_e2ee_rekey.dart
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/dsm/webapi.dart';

const me = 14;
const other = 4;
const channelId = 45;
const passcode = 'flt-e2ee-pass';

class _MemoryStore implements E2eeStore {
  final _map = <String, String>{};
  @override
  Future<String?> setting(String key) async => _map[key];
  @override
  Future<void> setSetting(String key, String value) async => _map[key] = value;
  @override
  Future<void> deleteSetting(String key) async => _map.remove(key);
}

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
  final chat = ChatApi(api);

  print('== 1. 取服务端登记的身份（我）==');
  final mine = await chat.myUser();
  if (mine == null || mine.publicKey.isEmpty) {
    print('  服务端没有我的 key_pair，先跑一次 setup 再说');
    return;
  }
  print('  公钥 = ${mine.publicKey}');

  print('\n== 2. 用口令解出私钥 ==');
  final svc = E2eeService(_MemoryStore());
  await svc.adoptServerIdentity(
    E2eeIdentity(publicKey: mine.publicKey, privateKeyEnc: mine.privateKeyEnc),
  );
  try {
    await svc.unlock(passcode);
    print('  ✓ 私钥已解锁');
  } catch (e) {
    print('  ✗ 口令解不开（$e）——换口令或重新分发都无从下手了');
    return;
  }

  print('\n== 3. 取 #$other 公钥 ==');
  final users = await chat.listUsers();
  final otherUser = users.firstWhere((u) => u.userId == other);
  print('  #$other 公钥 = ${otherUser.publicKey}');
  if (otherUser.publicKey.isEmpty) {
    print('  对方没公钥，救不了');
    return;
  }

  print('\n== 4. 生成新频道密钥并两路分发 ==');
  final made = svc.newChannelKey([otherUser.publicKey, mine.publicKey]);
  svc.putChannelKey(channelId, made.key);
  await chat.updateKey(
    connId: sess.sid,
    publicKey: mine.publicKey,
    privateKeyEnc: mine.privateKeyEnc,
    channelIds: [channelId],
    channelKeyEncs: [made.sealedKeys[1]],
  );
  await chat.rescueChannel(
    userId: other,
    channelId: channelId,
    channelKeyEnc: made.sealedKeys[0],
  );
  print('  update_key + rescue 已发');

  print('\n== 5. 读回验证 ==');
  final channels = await chat.listChannels();
  final target = channels.firstWhere((c) => c.channelId == channelId);
  print(
    '  #$channelId encrypted=${target.encrypted} members=${target.members}',
  );
  final fresh = E2eeService(_MemoryStore());
  await fresh.adoptServerIdentity(
    E2eeIdentity(publicKey: mine.publicKey, privateKeyEnc: mine.privateKeyEnc),
  );
  await fresh.unlock(passcode);
  final broken = fresh.loadChannelKeys(channels);
  print('  broken=$broken keyState=${fresh.keyState(target)}');

  print('\n== 6. 发一条密文再读回解密 ==');
  const text = 'flt-p7-rekey 校验 🙂';
  final enc = fresh.encryptMessage(channelId, text);
  final created = await api.call(
    'SYNO.Chat.Post',
    'create',
    preferredVersion: 7,
    params: {
      'channel_id': '$channelId',
      'conn_id': jsonEncode(sess.sid),
      'type': jsonEncode('text'),
      'message': jsonEncode(enc),
      'is_thread': 'false',
      'mobile_token': jsonEncode('${DateTime.now().millisecondsSinceEpoch}'),
    },
  );
  final postId = (created['post'] as Map?)?['post_id'];
  final list = await api.call(
    'SYNO.Chat.Post',
    'list',
    preferredVersion: 8,
    params: {'channel_id': '$channelId', 'limit': '5', 'offset': '0'},
  );
  var ok = false;
  for (final p in (list['posts'] as List)) {
    final m = p as Map;
    if (fresh.tryDecryptMessage(channelId, '${m['message']}') == text)
      ok = true;
  }
  print('  读回并解密：${ok ? "✓" : "✗"}');
  if (postId != null) {
    await api.call(
      'SYNO.Chat.Post',
      'delete',
      preferredVersion: 3,
      params: {'post_id': '$postId'},
    );
    print('  已删 #$postId');
  }
  print('\n频道 #$channelId 现在对新设备（口令 $passcode）可用。');
}
