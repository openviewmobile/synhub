// ignore_for_file: avoid_print
// 把 Dio 真正发出去的东西打出来，跟纯 dart:io 的成功请求逐项对比。
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

class Spy extends Interceptor {
  @override
  void onRequest(RequestOptions o, RequestInterceptorHandler h) {
    if (o.data is Map && '${o.data['api']}'.contains('Compress')) {
      print('--- 请求 uri=${o.uri}');
      print('--- method=${o.method} contentType=${o.contentType}');
      print('--- headers=${Map<String, dynamic>.from(o.headers)}');
      print('--- data=${o.data}');
    } else if (o.data is Map && '${o.data['api']}'.contains('Auth')) {
      print('--- 登录 headers=${Map<String, dynamic>.from(o.headers)}');
    }
    h.next(o);
  }

  @override
  void onResponse(Response<dynamic> r, ResponseInterceptorHandler h) {
    if (r.requestOptions.data is Map &&
        '${(r.requestOptions.data as Map)['api']}'.contains('Compress')) {
      print('--- 响应 status=${r.statusCode} body=${r.data}');
    }
    h.next(r);
  }
}

Future<void> main() async {
  final dio = DioFactory.create(allowSelfSigned: true, interceptors: [Spy()]);
  final api = DsmWebApi(
    DirectTransport.url(Platform.environment['SYNO_NAS_URL']!, dio: dio),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'FileStation',
  );
  print('token=${api.session?.synotoken}');
  try {
    final r = await api.transport.postForm('entry.cgi', {
      'api': 'SYNO.FileStation.Compress',
      'version': '3',
      'method': 'start',
      'path': '["/home/Photos"]',
      'dest_file_path': '/home/dio-test.zip',
      'level': 'normal',
      'mode': 'replace',
      'format': 'zip',
      'password': '',
      'codepage': '',
      '_sid': api.session!.sid,
    });
    print('结果 → $r');
  } catch (e) {
    print('!! $e');
  }
  try {
    await api.call(
      'SYNO.FileStation.Delete',
      'delete',
      preferredVersion: 2,
      params: {'path': '["/home/dio-test.zip"]'},
    );
  } catch (_) {}
  api.transport.close();
  exit(0);
}
