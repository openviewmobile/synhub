// ignore_for_file: avoid_print
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
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
  // 额外指定的频道 id（比如探针里"建了但没 join"的孤儿频道——
  // 那种频道不在任何列表里，只能按 id 试；不是成员会 401）
  for (final id
      in Platform.environment['FLT_EXTRA_IDS']
              ?.split(',')
              .map(int.tryParse)
              .whereType<int>() ??
          const <int>[]) {
    try {
      await chat.closeChannel(id, connId: 'cleanup');
      print('  关闭指定 #$id ✓');
    } catch (e) {
      print('  关闭指定 #$id 失败：$e');
    }
  }
  final all = await chat.listChannels(isJoined: '');
  final junk = all.where((c) => c.name.startsWith('flt-')).toList();
  print(
    'flt- 残留：${junk.map((c) => "#${c.channelId}(${c.name},joined=${c.isJoined})").join(' ')}',
  );
  for (final c in junk) {
    try {
      if (c.isJoined) {
        await chat.closeChannel(c.channelId, connId: 'cleanup');
      } else {
        await chat.closeChannel(c.channelId, connId: 'cleanup');
      }
      print('  关闭 #${c.channelId} ✓');
    } catch (e) {
      print('  关闭 #${c.channelId} 失败：$e');
    }
  }
  final left = (await chat.listChannels(isJoined: ''))
      .where((c) => c.name.startsWith('flt-'))
      .map((c) => '#${c.channelId}')
      .toList();
  print('剩余 flt- 频道：$left');
  final arch = await chat.listArchives();
  print(
    '归档：${arch.map((a) => "archive#${a.archiveId}→ch#${a.channel.channelId}(${a.channel.name})").join(' ')}',
  );
  await api.logout();
  exit(0);
}
