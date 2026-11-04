// 探针：把 `SYNO.NoteStation.Tag/list` 的**原始返回**打出来，核对字段名。
// 排查"标签页一直显示 0 条笔记"用。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
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
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'NoteStation',
  );
  for (final v in const [2, 1]) {
    try {
      final raw = await api.call(
        'SYNO.NoteStation.Tag',
        'list',
        preferredVersion: v,
        params: {'filter': '{}'},
      );
      print('v$v raw=$raw');
    } catch (e) {
      print('v$v 失败：$e');
    }
  }
  await api.logout();
  exit(0);
}
