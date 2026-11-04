// ignore_for_file: avoid_print
// 逐层定位：DsmWebApi.call vs 直接 transport.postForm，看 105 到底出在哪一层。
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
  final tok = api.session?.synotoken;
  print('token=$tok transport=${api.transport.synoToken}');

  Future<String> raw(String label, Map<String, dynamic> body) async {
    try {
      final r = await api.transport.postForm('entry.cgi', body);
      print('$label → ${r.length > 140 ? r.substring(0, 140) : r}');
      return r;
    } catch (e) {
      print('$label !! $e');
      return '';
    }
  }

  final common = <String, dynamic>{
    'path': '["/home/Photos"]',
    'dest_file_path': '/home/layer-test.zip',
    'level': 'normal',
    'mode': 'replace',
    'format': 'zip',
    'password': '',
    'codepage': '',
    '_sid': api.session!.sid,
  };

  // ① 走 transport（应带上 X-SYNO-TOKEN 头）
  await raw('① transport.postForm', {
    'api': 'SYNO.FileStation.Compress',
    'version': '3',
    'method': 'start',
    ...common,
  });

  // ② 走 DsmWebApi.call
  try {
    final d = await api.call(
      'SYNO.FileStation.Compress',
      'start',
      preferredVersion: 3,
      params: {
        'path': '["/home/Photos"]',
        'dest_file_path': '/home/layer-test2.zip',
        'level': 'normal',
        'mode': 'replace',
        'format': 'zip',
        'password': '',
        'codepage': '',
      },
    );
    print('② DsmWebApi.call → $d');
  } on DsmApiException catch (e) {
    print('② DsmWebApi.call !! code=${e.code} raw=${e.raw}');
  }

  // ③ List（简单接口）走 call 有没有问题
  try {
    final d = await api.call(
      'SYNO.FileStation.List',
      'list',
      preferredVersion: 2,
      params: {'folder_path': '/home', 'limit': 3},
    );
    print('③ List.call OK total=${d['total']}');
  } catch (e) {
    print('③ List.call !! $e');
  }

  for (final f in const ['layer-test.zip', 'layer-test2.zip']) {
    try {
      await api.call(
        'SYNO.FileStation.Delete',
        'delete',
        preferredVersion: 2,
        params: {'path': '["/home/$f"]'},
      );
    } catch (_) {}
  }
  print('清理完成');
  api.transport.close();
  exit(0);
}
