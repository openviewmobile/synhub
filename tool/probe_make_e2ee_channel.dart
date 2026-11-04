// 造一个 E2EE 验证频道（真机用例需要它当固定装置；#45 已经没了）。
//
// 摸清的**加密 Named 频道创建流程**（原版 `Channel.Named` + `ChatSodiumUtil`）：
//   1. 客户端自己**生成 32 字节频道密钥**；
//   2. `SYNO.Chat.Channel.Named create`（name/purpose/type/encrypted=true）→ channel_id；
//   3. `SYNO.Chat.Channel.Named join` 带上 `channel_key_enc`（用**自己公钥**封的频道密钥）
//      —— 不传就是 `CHAT_ERR_CHANNEL_KEY_NOT_EXIST(421)`；
//   4. `SYNO.Chat.Channel.Named invite` 带 `user_ids` + `channel_key_encs`
//      （每个成员各用其公钥封一份）。
//
//   dart run -DSYNO_NAS_URL=… -DSYNO_NAS_ACCOUNT=… "-DSYNO_NAS_PASSWORD=…" \
//            tool/probe_make_e2ee_channel.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:math';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/dsm/webapi.dart';

const inviteeUserId = 4;
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
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  final chat = ChatApi(api);

  final mine = await chat.myUser();
  if (mine == null || mine.publicKey.isEmpty) {
    print('服务端没有我的 key_pair，先跑一次 E2EE setup');
    return;
  }
  final svc = E2eeService(_MemoryStore());
  await svc.adoptServerIdentity(
    E2eeIdentity(publicKey: mine.publicKey, privateKeyEnc: mine.privateKeyEnc),
  );
  await svc.unlock(passcode);
  print('我的公钥 = ${mine.publicKey.substring(0, 24)}…（私钥已解锁）');

  // 1. 生成频道密钥
  final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));

  // 2. create
  final name = 'flt-e2ee-${DateTime.now().millisecondsSinceEpoch % 100000}';
  final created = await api.call(
    'SYNO.Chat.Channel.Named',
    'create',
    preferredVersion: 1,
    params: {
      'name': name,
      'purpose': 'Flutter 重写用的 E2EE 验证频道',
      'type': 'private',
      'encrypted': 'true',
    },
  );
  final channelId = (created['channel_id'] as num).toInt();
  print('create → #$channelId ($name)');

  // 3. join（必须自带自己的 channel_key_enc）
  svc.putChannelKey(channelId, key);
  await api.call(
    'SYNO.Chat.Channel.Named',
    'join',
    preferredVersion: 1,
    params: {
      'channel_id': '$channelId',
      'channel_key_enc': svc.sealChannelKey(channelId, mine.publicKey),
    },
  );
  print('join → 成功（已带上自己那把 channel_key_enc）');

  // 4. 邀请对方
  final others = await chat.listUsersByIds([inviteeUserId]);
  if (others.isEmpty || others.first.publicKey.isEmpty) {
    print('拿不到 #$inviteeUserId 的公钥，频道是 1 人频道');
  } else {
    final invite = await api.call(
      'SYNO.Chat.Channel.Named',
      'invite',
      preferredVersion: 1,
      params: {
        'channel_id': '$channelId',
        'user_ids': jsonEncode([inviteeUserId]),
        'channel_key_encs': jsonEncode([
          svc.sealChannelKey(channelId, others.first.publicKey),
        ]),
      },
    );
    print('invite → #$inviteeUserId ${jsonEncode(invite)}');
  }

  final check = await chat.listChannelsByIds([channelId]);
  final c = check.isEmpty ? null : check.first;
  print(
    '\n核对：enc=${c?.encrypted} members=${c?.members} '
    'keyEnc=${c?.channelKeyEnc.length} 字节',
  );
  print('✅ 加密验证频道 = #$channelId');
}
