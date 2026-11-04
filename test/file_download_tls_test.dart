// 302 轮：下载取数口**必须继承会话 Dio 的 TLS 策略**。
//
// 真机逐字（NAS = `https://nas.example.com:5001` + 自签 `CN=nas.example.com`）：
// ```
// 已登记，但缓存失败：DioException [unknown]: null
// Error: HandshakeException: Handshake error in client (OS Error:
//   CERTIFICATE_VERIFY_FAILED: IP address mismatch(handshake.cc:320))
// ```
// 老代码的 `rangeByteFetcherProvider` 兜底是裸 `DioRangeByteFetcher()` ——
// 它新建一个**默认 TLS** 的 `HttpClient`，主机名与 IP 不匹配就直接握手失败。
// 受害者不止离线缓存：**「下载到本机」走同一条取数口**。
//
// 这里钉三个机制量：
//   ① 会话那条 Dio 被**原样复用**（identity，不是"再建一条像的"）；
//   ② 那条 Dio 的 `HttpClient.badCertificateCallback` **真的在**
//      （反向验证：裸 `Dio()` 上它是 null ⇒ 断言能区分）；
//   ③ 长下载不被会话的 30s 接收超时掐断（请求级覆盖，用本机 HTTP 服务实测）。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_download_resume.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

/// 会话已连上、且连接里带着一条"配过 TLS 的 Dio"。
class _Connected extends SessionController {
  _Connected(this.conn);
  final DsmConnection conn;

  @override
  SessionState build() =>
      SessionState(connection: conn, session: const DsmSession(sid: 'SID'));
}

DsmConnection _connection(Dio dio) => DsmConnection(
  api: DsmWebApi(DirectTransport.url('https://192.0.2.9:5001', dio: dio)),
  endpoint: const ResolvedEndpoint(
    baseUrl: 'https://192.0.2.9:5001',
    source: 'lan',
  ),
  profile: const ServerProfile(kind: ServerAddressKind.direct, value: '192.0.2.9'),
  dio: dio,
);

void main() {
  group('302 下载取数口的 TLS 策略', () {
    test('① 兜底那条取数口复用**会话 Dio**（不是另建一条）', () {
      final dio = DioFactory.create();
      final c = ProviderContainer(
        overrides: [sessionControllerProvider.overrideWith(() => _Connected(_connection(dio)))],
      );
      addTearDown(c.dispose);

      final fetcher = c.read(rangeByteFetcherProvider);
      expect(fetcher, isA<DioRangeByteFetcher>());
      expect(
        identical((fetcher as DioRangeByteFetcher).dio, dio),
        isTrue,
        reason: '必须是会话那条 Dio，TLS 配置（自签/IP 不匹配放行）才继承得过来',
      );
    });

    // ② 用**真 TLS 握手**验：会话那条 Dio 放行自签证书，裸 Dio 握手失败。
    //    证书是 mock NAS 的自签证书；真机上那句错误还叠加了 `IP address
    //    mismatch`（NAS 用 IP 访问、证书 CN 是 `nas.example.com`），
    //    两条都由同一个 `badCertificateCallback` 放行 —— 这里用 127.0.0.1
    //    复现同类失败（自签不受系统信任），机制相同。
    test('② 会话 Dio 放行自签证书；裸 Dio 握手失败（反向验证）', () async {
      final ctx = SecurityContext()
        ..useCertificateChain('tool/mock_nas/mock_nas_cert.pem')
        ..usePrivateKey('tool/mock_nas/mock_nas_key.pem');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        ctx,
      );
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.headers.contentLength = 6;
        req.response.add([1, 2, 3, 4, 5, 6]);
        await req.response.close();
      });

      final url = 'https://127.0.0.1:${server.port}/x';
      final tmp = Directory.systemTemp.createTempSync('r302tls_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      // 会话那条（DioFactory.create，badCertificateCallback 已装）→ 能取到字节
      final okSink = File('${tmp.path}/ok.bin').openWrite();
      final ok = await DioRangeByteFetcher(
        dio: DioFactory.create(),
      ).fetchRange(url, start: 0, sink: okSink);
      await okSink.close();
      expect(ok.statusCode, 200, reason: '会话 Dio 必须放行自签证书');
      expect(File('${tmp.path}/ok.bin').lengthSync(), 6);

      // 裸 Dio（= 修好之前那个兜底）→ 握手失败，这正是真机日志
      final badSink = File('${tmp.path}/bad.bin').openWrite();
      await expectLater(
        DioRangeByteFetcher(
          dio: Dio(),
        ).fetchRange(url, start: 0, sink: badSink),
        throwsA(
          predicate(
            (e) => '$e'.contains('Handshake') || '$e'.contains('CERTIFICATE'),
            '应当是握手/证书失败（真机逐字 CERTIFICATE_VERIFY_FAILED）',
          ),
        ),
      );
      await badSink.close();
    });

    test('③ 长下载：分块之间停顿超过会话接收超时也不被掐断', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.headers.contentLength = 6;
        req.response.add([1, 2, 3]);
        await req.response.flush();
        // 停顿远大于会话的接收超时
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        req.response.add([4, 5, 6]);
        await req.response.close();
      });

      // 会话那条 Dio：接收超时只有 300ms（模拟传输层的 30s，缩短到可测）
      final session = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(milliseconds: 300),
          validateStatus: (_) => true,
        ),
      );
      final tmp = Directory.systemTemp.createTempSync('r302dl_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final target = File('${tmp.path}/x.bin');
      final sink = target.openWrite();

      final outcome = await DioRangeByteFetcher(dio: session).fetchRange(
        'http://127.0.0.1:${server.port}/x',
        start: 0,
        sink: sink,
      );
      await sink.close();

      expect(outcome.statusCode, 200);
      expect(
        target.lengthSync(),
        6,
        reason: '请求级 receiveTimeout 必须覆盖会话的短超时（否则大文件分块一慢就断）',
      );
    });
  });
}
