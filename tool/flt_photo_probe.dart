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
  final table = await api.discover();
  print(
    'SYNO.Personal.Profile.Photo = ${table['SYNO.Personal.Profile.Photo']}',
  );
  for (final k in table.keys.where(
    (k) => k.contains('Profile') || k.contains('Personal'),
  )) {
    print('  $k → ${table[k]}');
  }
  exit(0);
}
