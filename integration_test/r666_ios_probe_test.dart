// r666：iOS 模拟器到真 NAS 的连通性 / TLS 探针（只读 GET SYNO.API.Info）。
// 目的：把"连不上"分成三种可判定的情况 —— DNS/路由不通、TCP 不通、TLS 握手不通。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS 到真 NAS 的连通性探针', (tester) async {
    const host = 'nas.example.com';
    const port = 5001;
    final results = <String>[];

    // ① DNS / 解析（这里用字面 IP，只验证 getaddrinfo 路径）
    try {
      final r = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
      results.add('lookup ok: ${r.map((e) => e.address).join(",")}');
    } catch (e) {
      results.add('lookup FAIL: $e');
    }

    // ② TCP
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
      sw.stop();
      results.add('tcp ok ms=${sw.elapsedMilliseconds}');
      s.destroy();
    } catch (e) {
      sw.stop();
      results.add('tcp FAIL ms=${sw.elapsedMilliseconds}: $e');
    }

    // ③ TLS（故意放宽证书，只为判断握手是否通）
    final sw2 = Stopwatch()..start();
    try {
      final ctx = SecurityContext(withTrustedRoots: false);
      final s = await SecureSocket.connect(host, port,
          context: ctx,
          onBadCertificate: (_) => true,
          timeout: const Duration(seconds: 10));
      sw2.stop();
      results.add('tls ok ms=${sw2.elapsedMilliseconds}');
      s.destroy();
    } catch (e) {
      sw2.stop();
      results.add('tls FAIL ms=${sw2.elapsedMilliseconds}: $e');
    }

    // ④ 真实 API 请求（宽松证书）
    final sw3 = Stopwatch()..start();
    try {
      final c = HttpClient()..badCertificateCallback = (_, _, _) => true;
      final req = await c.getUrl(Uri.parse(
          'https://$host:$port/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query'));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final body = await resp.transform(const SystemEncoding().decoder).join();
      sw3.stop();
      results.add('api ok ms=${sw3.elapsedMilliseconds} code=${resp.statusCode} len=${body.length}');
      c.close(force: true);
    } catch (e) {
      sw3.stop();
      results.add('api FAIL ms=${sw3.elapsedMilliseconds}: $e');
    }

    // ignore: avoid_print
    for (final r in results) {
      print('[ios-probe] $r');
    }
    expect(results.length, 4);
  });
}
