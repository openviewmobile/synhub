// ignore_for_file: avoid_print
// 看看服务端到底认不认这个账号的压缩权限：DSM 版本 + 桌面 initdata 里的权限表。
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
    session: 'FileStation',
  );

  final keys =
      (api.apiTable ?? const {}).keys
          .where(
            (k) =>
                k.startsWith('SYNO.FileStation') ||
                k.contains('Desktop') ||
                k.contains('AppPriv'),
          )
          .toList()
        ..sort();
  print('相关 API: $keys');

  for (final spec in [
    ['SYNO.DSM.Info', 'getinfo', 2],
    ['SYNO.Core.Desktop.Initdata', 'getjs', 1],
    ['SYNO.Core.Desktop.SessionData', 'get', 1],
    ['SYNO.Core.Desktop.SessionData', 'getjs', 1],
    ['SYNO.Core.AppPriv', 'get', 1],
  ]) {
    try {
      final r = await api.call(
        spec[0] as String,
        spec[1] as String,
        preferredVersion: spec[2] as int,
        params: const {},
      );
      final txt = r.toString();
      // 只挑和权限/文件站有关的部分打印，别刷屏
      final hits = <String>[];
      for (final kw in [
        'compress',
        'Compress',
        'FileStation3',
        'privilege',
        'version',
        'version_string',
        'majorversion',
      ]) {
        var i = txt.indexOf(kw);
        var n = 0;
        while (i >= 0 && n < 3) {
          hits.add(
            txt.substring(
              i < 60 ? 0 : i - 60,
              (i + 120) > txt.length ? txt.length : i + 120,
            ),
          );
          i = txt.indexOf(kw, i + 1);
          n++;
        }
      }
      print('\n=== ${spec[0]}.${spec[1]} (len=${txt.length})');
      for (final h in hits.take(8)) {
        print('  …${h.replaceAll('\n', ' ')}…');
      }
    } catch (e) {
      print('\n=== ${spec[0]}.${spec[1]} !! $e');
    }
  }
  api.transport.close();
  exit(0);
}
