// ignore_for_file: avoid_print
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
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
  for (final c in await chat.listChannels()) {
    final members = await chat.listChannelMembers(c.channelId);
    print(
      '频道 #${c.channelId} ${c.name} enc=${c.encrypted} joined=${c.isJoined} '
      'members=${members.userIds} broken=${members.brokenUserIds}',
    );
    if (apply && c.name.startsWith('flt-p')) {
      await chat.disjoinNamedChannel(c.channelId);
      print('  → 已退出');
    }
  }
  exit(0);
}
