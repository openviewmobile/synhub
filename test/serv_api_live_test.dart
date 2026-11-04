// ignore_for_file: avoid_print
// 对真实 Synology 控制服务器的联调测试（默认跳过）
//
//   SYNO_LIVE=1 HTTPS_PROXY=http://127.0.0.1:7897 flutter test test/serv_api_live_test.dart
//
// 只验证发现层（Serv.php），不需要 NAS 凭据：
//   - get_echo_list  → 打洞服务器列表 + udt_tx_mss
//   - get_server_info → 伪造 QC ID 应返回 errno != 0
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/quickconnect/serv_api.dart';

final bool liveEnabled = Platform.environment['SYNO_LIVE'] == '1';

String? proxyFromEnv() {
  final raw =
      Platform.environment['HTTPS_PROXY'] ??
      Platform.environment['https_proxy'] ??
      Platform.environment['HTTP_PROXY'] ??
      Platform.environment['http_proxy'];
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return null;
  return '${uri.host}:${uri.port}';
}

ServApi liveApi() {
  final proxy = proxyFromEnv();
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  if (proxy != null) {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final c = HttpClient();
        c.findProxy = (uri) => 'PROXY $proxy';
        return c;
      },
    );
  }
  return ServApi(dio: dio);
}

void main() {
  test('get_echo_list 打真实控制服务器', () async {
    final r = await liveApi().fetchEchoList();

    print('errno=${r.errno} sites=${r.sites} udt_tx_mss=${r.udtTxMss}');

    expect(r.errno, 0);
    expect(r.sites, isNotEmpty);
    expect(r.sites.every((s) => s.port > 0), isTrue);
    // 同一响应里所有 site 共用一个 port
    expect(r.sites.map((s) => s.port).toSet().length, 1);

    // 原库把 udt_tx_mss 当作本地读的字节数上限，必须 ≤ 0x579 (1401)
    if (r.udtTxMss > 0) {
      expect(r.udtTxMss, lessThanOrEqualTo(1401));
      expect(r.udtTxMss, greaterThan(0));
    }
  }, skip: liveEnabled ? false : '需要 SYNO_LIVE=1');

  test('get_server_info 伪造 QC ID → errno != 0', () async {
    final api = liveApi();
    Object? caught;
    try {
      await api.fetchServerInfo(
        serverId: 'nonexistent-qcid-for-test-xyz',
        serviceId: 'dsm_https',
      );
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<ServApiException>());
    expect((caught! as ServApiException).errno, isNotNull);
    print('errno=${(caught as ServApiException).errno} ${caught.message}');
  }, skip: liveEnabled ? false : '需要 SYNO_LIVE=1');
}
