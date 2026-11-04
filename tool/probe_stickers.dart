import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print
void main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );
  final data = await api.call(
    'SYNO.Chat.Sticker',
    'list',
    preferredVersion: 2,
    params: {},
  );
  final cats = (data['categories'] as List).cast<Map>();
  for (final c in cats) {
    final sts = (c['stickers'] as List).cast<Map>();
    print(
      'category ${c['category_id']} name=${c['name']} is_emoji=${c['is_emoji']} count=${sts.length}',
    );
    if (c['is_emoji'] == true) {
      final sample = sts
          .take(12)
          .map((s) => '${s['sticker_id']}:${s['name']}')
          .join(' ');
      print('  前 12 个: $sample');
    }
  }
}
