// 摸 `SYNO.Chat.Channel.Anonymous / promote` 的真实契约（2.4.7-22203）。
//
// 已知结论（前几轮的探测）：
//   * 形状对：`channel_id` + `name`/`purpose` 各 **Gson 二次编码** + version=2 → 能成功；
//   * 只给 `channel_id` / 空串 → **407 CHAT_ERR_INVALID_RECORD**；
//   * 名字撞已有频道名 → **420 CHAT_ERR_DUPLICATED_CHANNEL_NAME**；
//   * 成功的会话会变成 `type=private`（`members` 列被清空，不再占"两人一条"的唯一键）；
//   * v1 没有 promote → 103。
//
// 这份脚本专门隔离"名字里到底什么字符会被判 407"：中文？空格？
//
//   dart run -DSYNO_NAS_URL=… -DSYNO_NAS_ACCOUNT=… "-DSYNO_NAS_PASSWORD=…" \
//            tool/probe_promote.dart
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

late DsmWebApi api;
late ChatApi chat;
late int myId;
final _anonChannels = <int, int>{}; // peer id -> anonymous channel id

Future<void> dumpChannel(int channelId, String label) async {
  try {
    final r = await api.call(
      'SYNO.Chat.Channel',
      'get',
      preferredVersion: 5,
      params: {'channel_id': '$channelId', 'is_joined': 'true'},
    );
    final ch = (r['channel'] ?? r) as Map;
    print(
      '  [$label] #$channelId type=${ch['type']} name=${ch['name']} '
      'purpose=${ch['purpose']} members=${ch['members']}',
    );
  } catch (e) {
    print('  [$label] 回读失败：$e');
  }
}

/// 找（或建）跟 [peer] 的一对一会话；已存在且还没升级就复用（initiate 会 117）
Future<int> ensureAnon(int peer) async {
  final existing = _anonChannels[peer];
  if (existing != null) return existing;
  final list = await chat.listChannels();
  for (final c in list) {
    if (c.type != 'anonymous' || c.encrypted) continue;
    final others = c.members.where((id) => id != myId).toList();
    if (others.length == 1 && others.single == peer) {
      print('复用已有会话 #${c.channelId}（对方 #$peer）');
      return _anonChannels[peer] = c.channelId;
    }
  }
  final init = await api.call(
    'SYNO.Chat.Channel.Anonymous',
    'initiate',
    preferredVersion: 1,
    params: {
      'user_ids': jsonEncode([peer, myId]),
      'channel_key_encs': 'null',
      'encrypted': 'false',
    },
  );
  final ch = (init['channel'] ?? init) as Map;
  final id = (ch['channel_id'] as num).toInt();
  print('新建会话 #$id（对方 #$peer）type=${ch['type']} members=${ch['members']}');
  return _anonChannels[peer] = id;
}

Future<void> tryPromote(
  String label,
  int channelId,
  String name, {
  String purpose = 'probe 描述',
}) async {
  try {
    final r = await api.call(
      'SYNO.Chat.Channel.Anonymous',
      'promote',
      preferredVersion: 2,
      params: {
        'channel_id': '$channelId',
        'name': jsonEncode(name),
        'purpose': jsonEncode(purpose),
      },
    );
    print('  [$label] "$name" → ✅ $r');
    await dumpChannel(channelId, '$label 之后');
  } catch (e) {
    final s = e.toString();
    print('  [$label] "$name" → ❌ ${s.length > 150 ? s.substring(0, 150) : s}');
  }
}

Future<void> main() async {
  api = DsmWebApi(
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
  chat = ChatApi(api);
  final mine = await chat.myUser();
  if (mine == null) {
    print('拿不到我的资料');
    return;
  }
  myId = mine.userId;
  print('我 = #$myId');

  final ts = DateTime.now().millisecondsSinceEpoch;

  // 每条变体各用一个"对方"，避免"两个用户只有一条会话"的唯一键打架
  final variants = <({int peer, String label, String name})>[
    (peer: 4, label: 'ASCII 带空格', name: 'pn two $ts'),
    (peer: 6, label: '纯中文无空格', name: '频道名字$ts'),
    (peer: 8, label: '中文 + 空格', name: '频道 名$ts'),
    (peer: 11, label: 'ASCII 无空格', name: 'pnplain$ts'),
  ];

  for (final v in variants) {
    print('\n=== ${v.label}（对方 #${v.peer}）===');
    int id;
    try {
      id = await ensureAnon(v.peer);
    } catch (e) {
      print('  拿不到会话：$e');
      continue;
    }
    await tryPromote(v.label, id, v.name);
  }
  print('\n（失败的变体会把会话留在 anonymous 状态，下次跑会复用它）');
}
