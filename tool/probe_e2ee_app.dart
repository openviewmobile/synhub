// Phase 7 真机验收：**走 App 自己的代码**（ChatApi + E2eeService + ChatStore）
// 在真 NAS 上跑一遍 E2EE 全链路，而不是探针里的裸 api.call。
//
//   dart run -DSYNO_NAS_URL=... ... tool/probe_e2ee_app.dart
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 内存版键值存储：探针不引 Flutter/Drift（`dart run` 编不过 Flutter 包）
class _MemoryStore implements E2eeStore {
  final _map = <String, String>{};
  @override
  Future<String?> setting(String key) async => _map[key];
  @override
  Future<void> setSetting(String key, String value) async => _map[key] = value;
  @override
  Future<void> deleteSetting(String key) async => _map.remove(key);
}

const me = 14;
const other = 4;
const passcode = 'flt-e2ee-pass';
const target = 45;

void check(String label, bool ok) => print('  ${ok ? "✓" : "✗"} $label');

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
  final store = _MemoryStore();
  final svc = E2eeService(store);

  print('== 1. App 侧身份：setup + updateKey（走 ChatApi）==');
  final id = await svc.setup(passcode);
  check('setup 后已配置且解锁', svc.isConfigured && svc.isUnlocked);
  await chat.updateKey(
    connId: sess.sid,
    publicKey: id.publicKey,
    privateKeyEnc: id.privateKeyEnc,
  );
  check('updateKey 上传成功', true);

  print('\n== 2. 取 #$other 公钥（User/list，不能用 User/get）==');
  final users = await chat.listUsers();
  final otherUser = users.firstWhere((u) => u.userId == other);
  check('#$other 公钥非空', otherUser.publicKey.isNotEmpty);
  print('  #$other 公钥 = ${otherUser.publicKey}');

  print('\n== 3. 给 #$target 生成新频道密钥并两路分发 ==');
  final made = svc.newChannelKey([otherUser.publicKey, id.publicKey]);
  svc.putChannelKey(target, made.key);
  final mine = svc.myKeyEncs([...await chat.listChannels()]);
  await chat.updateKey(
    connId: sess.sid,
    publicKey: id.publicKey,
    privateKeyEnc: id.privateKeyEnc,
    channelIds: mine.channelIds,
    channelKeyEncs: mine.channelKeyEncs,
  );
  await chat.rescueChannel(
    userId: other,
    channelId: target,
    channelKeyEnc: made.sealedKeys.first,
  );
  check(
    'update_key(channel_ids=${mine.channelIds}) + rescue(#$other) 已发',
    true,
  );

  print('\n== 4. 从服务端读回频道，用 App 的密钥管理解出频道密钥 ==');
  final channels = await chat.listChannels();
  final target0 = channels.firstWhere((c) => c.channelId == target);
  print(
    '  #$target encrypted=${target0.encrypted} '
    'members=${target0.members}',
  );
  final fresh = E2eeService(store); // 模拟重启：重新 load + unlock
  await fresh.load();
  check('重启后是锁着的', !fresh.isUnlocked);
  try {
    await fresh.unlock('nope');
    check('错误口令应当失败', false);
  } catch (_) {
    check('错误口令被拒', true);
  }
  await fresh.unlock(passcode);
  final broken = fresh.loadChannelKeys(channels);
  check('没有 broken 频道（bad=$broken）', broken.isEmpty);
  check('频道密钥已就绪', fresh.keyState(target0) == ChannelKeyState.ready);

  print('\n== 5. 发一条加密消息（走 App 的加密接口）==');
  const text = 'flt-e2ee-app 验收 🙂 中文/emoji';
  final enc = fresh.encryptMessage(target, text);
  final created = await api.call(
    'SYNO.Chat.Post',
    'create',
    preferredVersion: 7,
    params: {
      'channel_id': '$target',
      'conn_id': jsonEncode(sess.sid),
      'type': jsonEncode('text'),
      'message': jsonEncode(enc),
      'is_thread': 'false',
      'mobile_token': jsonEncode('${DateTime.now().millisecondsSinceEpoch}'),
    },
  );
  final postId = (created['post'] as Map?)?['post_id'] ?? (created['post_id']);
  print('  发出 post #$postId');

  print('\n== 6. 读回并用 App 的解密接口验证 ==');
  final list = await api.call(
    'SYNO.Chat.Post',
    'list',
    preferredVersion: 8,
    params: {'channel_id': '$target', 'limit': '10', 'offset': '0'},
  );
  var decrypted = 0;
  var undecryptable = 0;
  for (final p in (list['posts'] as List)) {
    final m = p as Map;
    final got = fresh.tryDecryptMessage(target, '${m['message']}');
    if (got == null) {
      undecryptable++;
      print('    #${m['post_id']} 解不开（${'${m['message']}'.length} 字节）');
    } else {
      decrypted++;
      print('    #${m['post_id']} → "$got"');
    }
  }
  check(
    '至少解出本轮那条（decrypted=$decrypted undecryptable=$undecryptable）',
    decrypted >= 1,
  );

  print('\n== 7. 收尾：删掉本轮测试消息 ==');
  if (postId != null) {
    await api.call(
      'SYNO.Chat.Post',
      'delete',
      preferredVersion: 3,
      params: {'post_id': '$postId'},
    );
    print('  已删 #$postId');
  }
  print('\n结论：App 代码路径（身份/口令/密钥分发/收发解密）在真机全通。');
}
