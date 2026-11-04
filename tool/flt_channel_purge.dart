// ignore_for_file: avoid_print
//
// 一次性清理：删掉测试期间自己建的聊天频道（`flt-*`，以及用户点名要删的 `#1`）。
//
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//     dart run tool/flt_channel_purge.dart          # 只列（dry-run）
//   … dart run tool/flt_channel_purge.dart --apply  # 真删
//
// 只删名单内的名字，**不碰**其它任何频道。
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 明确属于测试残留的频道名
bool isJunk(String name) {
  final n = name.trim();
  return n.startsWith('flt-') || n == '#1';
}

Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
  // 列表里看不到的 id（比如空名字的 #1）：--ids=1,2
  final byId = args
      .where((a) => a.startsWith('--ids='))
      .expand((a) => a.substring(6).split(','))
      .map(int.tryParse)
      .whereType<int>()
      .toList();
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

  final all = await chat.listChannels(isJoined: '');
  print('共 ${all.length} 个频道：');
  for (final c in all) {
    final mark = isJunk(c.name) ? '  ← 待删' : '';
    print('  #${c.channelId} ${c.name} (joined=${c.isJoined})$mark');
  }

  final junk = all.where((c) => isJunk(c.name)).toList();
  if (byId.isNotEmpty) {
    print('额外指定 id：$byId（${apply ? "将删除" : "dry-run"}）');
    if (apply) {
      for (final id in byId) {
        try {
          await chat.closeChannel(id, connId: 'purge');
          print('  关闭 ##$id ✓');
        } catch (e) {
          print('  关闭 ##$id 失败：$e');
        }
      }
    }
  }
  if (junk.isEmpty) {
    print('没有待删频道');
  } else if (!apply) {
    print(
      'dry-run：以下 ${junk.length} 个会被删除 '
      '${junk.map((c) => "#${c.channelId}").join(' ')}（加 --apply 才真删）',
    );
  } else {
    for (final c in junk) {
      try {
        await chat.closeChannel(c.channelId, connId: 'purge');
        print('  关闭 #${c.channelId}（${c.name}）✓');
      } catch (e) {
        print('  关闭 #${c.channelId}（${c.name}）失败：$e');
      }
    }
    final left = (await chat.listChannels(isJoined: ''))
        .where((c) => isJunk(c.name))
        .map((c) => '#${c.channelId}(${c.name})')
        .toList();
    print('清理后残留：${left.isEmpty ? "无" : left.join(' ')}');
  }
  await api.logout();
  exit(0);
}
