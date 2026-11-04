// 电台「正在播的曲目」—— ICY 元数据旁路探针（r640 / **DA233**）。
//
// 判据落在**真的按 ICY 分块规则解字节**这件事上：用一个本机 `HttpServer`
// 造出与 SHOUTcast/Icecast 同形的响应（`icy-metaint` + 「N 字节音频 + 长度字节
// + 16×长度 元数据」），而不是 mock 解析函数。
//
// 五条：
//   ① 第一块就有 `StreamTitle` ⇒ 拿到；
//   ② 站不声明 `icy-metaint` ⇒ `null`（不硬等、不猜）；
//   ③ 首块是**空元数据**（`k=0` / `StreamTitle=''`）⇒ 继续读下一块，最终拿到；
//   ④ 非 http/https ⇒ 不发请求，直接 `null`；
//   ⑤ 反向：拿到的是**第二个**块的内容（证明不是"读了第一块就收工"）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/audio/audio_radio_icy.dart';

/// 造一个 ICY 元数据块：`[k] + 补零到 k*16`。
List<int> _metaBlock(String text) {
  final raw = utf8.encode(text);
  final k = (raw.length + 15) ~/ 16;
  final block = <int>[k, ...raw];
  while (block.length < 1 + k * 16) {
    block.add(0);
  }
  return block;
}

/// 起一个"假电台"：按给定分块顺序吐字节，然后**保持连接不关**
/// （真实电台是长连接；探针必须在读完第一块后自己收手，而不是等 EOF）。
Future<HttpServer> _serve(
  List<List<int>> blocks, {
  bool metaint = true,
  int metaInt = 4,
  void Function()? onRequest,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    onRequest?.call();
    final res = req.response;
    if (metaint) res.headers.set('icy-metaint', '$metaInt');
    res.headers.set('icy-name', 'Test FM');
    res.headers.set(HttpHeaders.contentTypeHeader, 'audio/mpeg');
    res.bufferOutput = false;
    // 一次写完（`add` 与 `flush` 交替会触发 "StreamSink is bound to a stream"）
    final body = <int>[];
    for (final b in blocks) {
      body.addAll(List<int>.filled(metaInt, 0x41));
      body.addAll(b);
    }
    res.add(body);
    // 不 close：模拟直播流（探针不能依赖 EOF）
  });
  return server;
}

void main() {
  test('① 第一块就有 StreamTitle ⇒ 拿到（artist - title 原样）', () async {
    final server = await _serve([
      _metaBlock("StreamTitle='Daft Punk - One More Time';"),
    ]);
    addTearDown(() => server.close(force: true));
    final probe = IoIcyMetadataSource();
    final got = await probe.probe(
      Uri.parse('http://127.0.0.1:${server.port}/stream'),
    );
    expect(got, isNotNull, reason: 'DA233：站点声明了 metaint 且第一块有标题');
    expect(got!.title, 'Daft Punk - One More Time');
    expect(got.stationName, 'Test FM');
  });

  test('② 不声明 icy-metaint ⇒ null（不硬等、不猜）', () async {
    final server = await _serve([
      _metaBlock("StreamTitle='x';"),
    ], metaint: false);
    addTearDown(() => server.close(force: true));
    final probe = IoIcyMetadataSource();
    final got = await probe.probe(
      Uri.parse('http://127.0.0.1:${server.port}/stream'),
    );
    expect(got, isNull, reason: 'DA233：没有 metaint 就说明这站不插元数据');
  });

  test('③ 首块是空元数据 ⇒ 继续读下一块（k=0 与空 StreamTitle 两种都覆盖）', () async {
    final server = await _serve([
      // k = 0：这一轮没有元数据
      const <int>[0],
      // StreamTitle 为空串
      _metaBlock("StreamTitle='';"),
      _metaBlock("StreamTitle='Second Block - Real Song';"),
    ]);
    addTearDown(() => server.close(force: true));
    final probe = IoIcyMetadataSource();
    final got = await probe.probe(
      Uri.parse('http://127.0.0.1:${server.port}/stream'),
    );
    expect(got?.title, 'Second Block - Real Song');
  });

  test('④ 非 http/https ⇒ 直接 null，且**不发请求**', () async {
    var hits = 0;
    final server = await _serve([
      _metaBlock("StreamTitle='x';"),
    ], onRequest: () => hits++);
    addTearDown(() => server.close(force: true));
    final probe = IoIcyMetadataSource();
    final got = await probe.probe(
      Uri.parse('file:///tmp/x.mp3'),
    );
    expect(got, isNull);
    expect(hits, 0, reason: 'DA233：只允许 http/https，别的协议不许连');
  });

  test('⑤ 只取**第一个**非空块（省流量；不是把整条流读完）', () async {
    final server = await _serve([
      _metaBlock("StreamTitle='First - Old Song';"),
      _metaBlock("StreamTitle='Second - New Song';"),
    ]);
    addTearDown(() => server.close(force: true));
    final probe = IoIcyMetadataSource();
    final got = await probe.probe(
      Uri.parse('http://127.0.0.1:${server.port}/stream'),
    );
    expect(got?.title, 'First - Old Song',
        reason: 'DA233 反向：只取第一个非空块 —— 若实现改成"读到最后"，这里会变成第二块');
  });
}
