// r701 · B12：Mock 侧弱网仪器（容器无 CAP_NET_ADMIN，tc/netem 用不了）。
//
// 为什么需要它：B12 原来写"弱网要靠 tc/netem（需要 CAP_NET_ADMIN，本容器没有）"——
// 但"客户端在慢网/坏网下的界面反应"（加载态、错误态、重试入口）是**能验的**，
// 只要服务端肯配合。判据钉在两条服务端事实：
//   ① `latencyMs` 真的让请求变慢（用墙钟量，不是看代码里有没有 sleep）；
//   ② `failAfter` 之后按 `failRate` 真的回 503（且**前 n 个必须正常**，
//      否则连登录都进不去，验不到页面错误态）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_dsm_server.dart';

void main() {
  Future<int> hit(
    MockDsmHttpServer mock,
    String sid, {
    String api = 'SYNO.Chat.Channel',
    String method = 'list',
  }) async {
    final http = HttpClient();
    try {
      final uri = Uri.parse(
        '${mock.baseUrl}webapi/entry.cgi'
        '?api=$api&method=$method&version=1&_sid=$sid',
      );
      final res = await (await http.getUrl(uri)).close();
      // 读干净，别让连接挂着（否则每次 tearDown 都要等 keep-alive 超时）
      await res.transform(utf8.decoder).join();
      return res.statusCode;
    } finally {
      http.close();
    }
  }

  test('① latencyMs 真的让请求变慢（墙钟 ≥ 设定值的 80%）', () async {
    final mock = await MockDsmHttpServer.start(port: 0, latencyMs: 400);
    final sid = mock.backend.login(username: 'mockuser', admin: false);
    final sw = Stopwatch()..start();
    final code = await hit(mock, sid);
    sw.stop();
    await mock.stop();
    expect(code, 200);
    expect(
      sw.elapsedMilliseconds,
      greaterThanOrEqualTo(320),
      reason: '设了 400ms 却只用了 ${sw.elapsedMilliseconds}ms ⇒ 延迟没生效',
    );
  });

  test('② failAfter: 前 n 个正常，之后按 failRate 回 503', () async {
    final mock = await MockDsmHttpServer.start(
      port: 0,
      failAfter: 1,
      failRate: 1.0,
    );
    final sid = mock.backend.login(username: 'mockuser', admin: false);
    final first = await hit(mock, sid);
    final second = await hit(mock, sid);
    final third = await hit(mock, sid);
    expect(first, 200, reason: '第 1 个请求必须正常（登录/首屏要进得去）');
    expect(second, 503, reason: '超过 failAfter 且 rate=1.0 ⇒ 必须 503');
    expect(third, 503);
    expect(mock.failedRequests, greaterThanOrEqualTo(2));
    expect(mock.servedRequests, 3);
    await mock.stop();
  });

  test('③ failRate: 0 时一个都不许失败（默认不改变既有行为）', () async {
    final mock = await MockDsmHttpServer.start(port: 0, failAfter: 0);
    final sid = mock.backend.login(username: 'mockuser', admin: false);
    for (var i = 0; i < 3; i++) {
      expect(await hit(mock, sid), 200, reason: '第 ${i + 1} 个');
    }
    expect(mock.failedRequests, 0);
    await mock.stop();
  });
}
