// ignore_for_file: avoid_print
// 对**真实 NAS** 的端到端联调（默认跳过）
//
//   SYNO_LIVE=1 \
//   SYNO_NAS_URL=https://nas.example.com:5001 \
//   SYNO_NAS_ACCOUNT=demo_user \
//   SYNO_NAS_PASSWORD='<在此填写你的口令>' \
//   flutter test test/dsm_live_test.dart
//
// 验证链路：SYNO.API.Info → Encryption/getinfo → CGI 加密 → Auth/login → sid 可用
//
// 注意：证书是 Synology 自签（CN=nas.example.com），这里显式放宽校验；
// 正式实现应当做证书指纹固定（get_server_info 里有 ca_fingerprints）。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/dsm/webapi.dart';

final bool liveEnabled = Platform.environment['SYNO_LIVE'] == '1';

void main() {
  final url = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'];

  if (!liveEnabled) {
    test('真实 NAS 联调（默认跳过）', () {
      print('设置 SYNO_LIVE=1 及 SYNO_NAS_* 后运行');
    }, skip: '未启用 SYNO_LIVE=1');
    return;
  }

  late DsmWebApi api;

  setUpAll(() {
    expect(url, isNotNull, reason: '需要 SYNO_NAS_URL');
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (s) => s != null,
      ),
    );
    // 自签证书
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final c = HttpClient();
        c.badCertificateCallback = (_, _, _) => true;
        return c;
      },
    );
    api = DsmWebApi(DirectTransport.url(url!, dio: dio));
  });

  tearDownAll(() async => api.logout().catchError((_) {}));

  test('① SYNO.API.Info 发现', () async {
    final table = await api.discover();
    expect(table, isNotEmpty);
    expect(table.keys, contains('SYNO.API.Auth'));
    expect(table.keys, contains('SYNO.API.Encryption'));
    print('发现 ${table.length} 个 API');
    print(
      '  SYNO.API.Auth       v${table['SYNO.API.Auth']!.minVersion}..'
      '${table['SYNO.API.Auth']!.maxVersion}  '
      'path=${table['SYNO.API.Auth']!.path}',
    );
  });

  test('② Encryption/getinfo 拿到公钥与 cipher 数据', () async {
    final info = await api.call(
      'SYNO.API.Encryption',
      'getinfo',
      preferredVersion: 1,
      requiresAuth: false,
    );
    expect(info['public_key'], isA<String>());
    expect((info['public_key'] as String).isNotEmpty, isTrue);
    print('  cipherkey   = ${info['cipherkey']}');
    print('  ciphertoken = ${info['ciphertoken']}');
    print('  server_time = ${info['server_time']}');
    print('  public_key  ${(info['public_key'] as String).length} 字符');
  });

  test('③ 登录成功并拿到 sid', () async {
    final session = await api.login(account: account!, password: password!);
    expect(session.sid, isNotEmpty);
    print('  sid = ${session.sid.substring(0, 20)}...');
    print('  did = ${session.did?.substring(0, 20)}...');
  });

  test('④ sid 可用：调一个需要鉴权的接口', () async {
    // 用 SYNO.API.Auth 的 logout 不便重复调用，这里查一个只读接口。
    // 拿不到也至少证明请求被受理（不是 119 未登录）。
    try {
      final r = await api.call('SYNO.Core.System', 'info', preferredVersion: 1);
      print('  SYNO.Core.System.info 返回 ${r.length} 个字段');
    } on DsmApiException catch (e) {
      // 非管理员账号可能无权限 —— 只要不是「未登录」就说明 sid 生效了
      expect(
        // 119 = sid 不存在、106 = 会话超时、107 = 会话中断
        [
          DsmErrorCode.sidNotFound,
          DsmErrorCode.sessionTimeout,
          DsmErrorCode.sessionInterrupt,
        ],
        isNot(contains(e.code)),
        reason: 'sid 应当有效，收到 ${e.code}',
      );
      print('  无权限但 sid 有效: ${e.code}');
    }
  });
}
