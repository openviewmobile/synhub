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
    session: 'SynologyDrive',
  );
  Future<Object?> t(
    String a,
    String m,
    int v, [
    Map<String, dynamic> p = const {},
  ]) async {
    try {
      return await api.call(a, m, preferredVersion: v, params: p);
    } catch (e) {
      return e;
    }
  }

  print('Labels/list v3 → ${await t('SYNO.SynologyDrive.Labels', 'list', 3)}');
  print(
    'Labels/list v1 {type:"label"} → '
    '${await t('SYNO.SynologyDrive.Labels', 'list', 1, {'type': '"label"'})}',
  );
  for (final enc in ['"1"', '1']) {
    print(
      'list_labelled v11 label_id=$enc → '
      '${await t('SYNO.SynologyDrive.Files', 'list_labelled', 11, {'label_id': enc, 'offset': '0', 'limit': '20'})}',
    );
  }
  print(
    'list_labelled v3 label_id="1" → '
    '${await t('SYNO.SynologyDrive.Files', 'list_labelled', 3, {'label_id': '"1"', 'offset': '0', 'limit': '20'})}',
  );
  // 清场：删掉探针标签
  for (final enc in ['"1"', '1']) {
    print(
      'Labels/delete label_id=$enc → '
      '${await t('SYNO.SynologyDrive.Labels', 'delete', 1, {'label_id': enc})}',
    );
  }
  print('清场后 Labels/list → ${await t('SYNO.SynologyDrive.Labels', 'list', 3)}');
  await api.logout();
  exit(0);
}
