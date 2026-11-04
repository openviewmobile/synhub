// r403（DA52）离线守卫：**探针的 6 s 超时不许跟一整个会话**。
//
// 真机实证（LGE-AN10，带插桩包，仪器㊷ 重建重装）：
//   `[r403] searchLyrics title="Demo Song" artist="Demo Artist" id="music_28045"`
//   `[r403] searchLyrics ERR elapsed=6013ms type=DsmTransportException`
//   `… took longer than 0:00:06.000000 to receive data. It was aborted.`
// 同一请求在宿主只读探针里 **~16 s 后 `200 {}`**（`tool/probe_r403c_lyrics_latency.dart`）
// ⇒ 服务端答得出来，是客户端 6 s 掐的。根因：`ConnectionService._probeEndpoint`
// 把**探针** Dio（`probeTimeout = 6 s`）原样塞进 `DsmConnection.dio` / transport。
//
// 本文件用**本机 HttpServer** 当假 NAS（离线、不碰真机/真 NAS）：
//   ① 选项级：探通之后 `conn.dio.options.receiveTimeout` 必须是正式超时（15/30 s）；
//   ② 行为级：一个**要 8 s 才回**的接口在会话里必须能拿到响应
//      （修前：6 s 就被 abort ⇒ `DsmTransportException`；修后：正常返回）。
//
// 运行：flutter test test/connection_session_timeout_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

/// 假 NAS：`query.cgi`（探针那条）立即回；其余路径**拖 [slowDelay] 再回**。
Future<HttpServer> _fakeNas({Duration slowDelay = Duration.zero}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final slow = !req.uri.path.endsWith('/query.cgi');
    if (slow && slowDelay > Duration.zero) {
      await Future<void>.delayed(slowDelay);
    }
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write('{"success":true,"data":{"ok":1,"path":"${req.uri.path}"}}');
    await req.response.close();
  });
  return server;
}

void main() {
  test('★ r403 DA52：探通之后的会话 Dio 用正式超时（不是探针的 6 s）', () async {
    final server = await _fakeNas();
    final service = ConnectionService();
    final conn = await service.connect(
      ServerProfile(
        kind: ServerAddressKind.direct,
        value: 'http://127.0.0.1:${server.port}',
      ),
    );

    expect(
      service.probeTimeout,
      const Duration(seconds: 6),
      reason: '前提：探针超时本来就是 6 s（本用例就是防它漏进会话）',
    );
    expect(
      conn.dio.options.receiveTimeout,
      const Duration(seconds: 30),
      reason: '会话 Dio 必须回到正式 receiveTimeout（DioFactory 缺省）',
    );
    expect(
      conn.dio.options.connectTimeout,
      const Duration(seconds: 15),
      reason: '会话 Dio 必须回到正式 connectTimeout（DioFactory 缺省）',
    );
    // 顺带钉住"探针替身"与"会话替身"不是同一把（否则等于没换）
    expect(conn.dio.options.receiveTimeout, greaterThan(service.probeTimeout));

    await conn.api.transport.close();
    await server.close(force: true);
  });

  test('★ r403 DA52：比探针超时慢的接口在会话里必须能拿到响应', () async {
    // 8 s > probeTimeout(6 s) 且 < receiveTimeout(30 s)：修前必 abort。
    final server = await _fakeNas(slowDelay: const Duration(seconds: 8));
    final conn = await ConnectionService().connect(
      ServerProfile(
        kind: ServerAddressKind.direct,
        value: 'http://127.0.0.1:${server.port}',
      ),
    );

    final sw = Stopwatch()..start();
    final body = await conn.api.transport.postForm('AudioStation/lyrics_search.cgi', {
      'api': 'SYNO.AudioStation.LyricsSearch',
      'version': '2',
      'method': 'searchlyrics',
      'title': 'Demo Song',
      'artist': 'Demo Artist',
    });
    sw.stop();

    expect(body, contains('"ok":1'));
    expect(
      sw.elapsed,
      greaterThan(const Duration(seconds: 6)),
      reason: '这条响应确实比探针超时慢 —— 证明它本来会被 abort',
    );

    await conn.api.transport.close();
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('★ r403 DA52 反向：测试注入的 Dio 保持原样（不被替换）', () async {
    // `dioBuilder` 是测试注入的假 Dio：语义由测试自己承担，不许被悄悄换掉。
    final server = await _fakeNas();
    final injected = DioFactory.create(
      connectTimeout: const Duration(seconds: 1),
      receiveTimeout: const Duration(seconds: 1),
    );
    final conn = await ConnectionService(
      dioBuilder: (_) => injected,
    ).connect(
      ServerProfile(
        kind: ServerAddressKind.direct,
        value: 'http://127.0.0.1:${server.port}',
      ),
    );
    expect(identical(conn.dio, injected), isTrue);
    await conn.api.transport.close();
    await server.close(force: true);
  });
}
