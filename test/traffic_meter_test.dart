// 流量计量的**字节数学**（第 276 轮）。
//
// 目标：证明"按字节真的流过计量"在 buffered / streamed / gzip / chunked /
// Range(206) / redirect / retry 下都**不重复计、不凭空加**，以及模块标签与
// 未归属回落的正确性。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/traffic_meter.dart';

import 'support/traffic_test_support.dart';

Future<void> _drain(Stream<Uint8List>? s) async {
  if (s == null) return;
  await s.drain<void>();
}

void main() {
  late RecordingTrafficSink sink;

  setUp(() {
    sink = RecordingTrafficSink();
    setGlobalTrafficSink(sink);
  });

  tearDown(() => setGlobalTrafficSink(null));

  test('buffered：请求 + 响应各记一次，字节数精确', () async {
    final adapter = FakeAdapter((o, req) async {
      await _drain(req);
      return ResponseBody.fromString(
        'hello',
        200,
        headers: contentLength(5),
      );
    });
    final dio = meteredDio(adapter);
    final res = await dio.post<String>(
      'https://nas.local/webapi/x.cgi',
      data: Uint8List.fromList([1, 2, 3, 4]),
      options: Options(
        responseType: ResponseType.plain,
        extra: {kTrafficModuleKey: TrafficModules.files},
      ),
    );
    expect(res.data, 'hello');
    expect(sink.bytesOf(TrafficDirection.up), 4);
    expect(sink.bytesOf(TrafficDirection.down), 5);
    expect(sink.exact.length, 2, reason: '一次请求 = 一上一下两条样本');
    expect(sink.exact.first.module, TrafficModules.files);
    expect(sink.exact.every((s) => s.tier == TrafficTier.exact), isTrue);
  });

  test('streamed / chunked：多块只记**一条**响应样本（不重复计）', () async {
    final adapter = FakeAdapter((o, req) async {
      await _drain(req);
      return bodyOf([
        List.filled(10, 1),
        List.filled(20, 2),
        List.filled(30, 3),
      ], headers: {'transfer-encoding': ['chunked']});
    });
    final dio = meteredDio(adapter);
    await dio.get<List<int>>(
      'https://nas.local/webapi/big.bin',
      options: Options(responseType: ResponseType.bytes),
    );
    expect(sink.bytesOf(TrafficDirection.down), 60);
    final down = sink.of(TrafficDirection.down);
    expect(down.length, 1, reason: '按流累加，不是每块一行');
  });

  test('gzip：按实际流过的字节计，不叠加 content-length', () async {
    final adapter = FakeAdapter((o, req) async {
      await _drain(req);
      return bodyOf([
        List.filled(7, 9),
      ], headers: {
        'content-encoding': ['gzip'],
        ...contentLength(999),
      });
    });
    final dio = meteredDio(adapter);
    final res = await dio.get<String>(
      'https://nas.local/webapi/gz.cgi',
      options: Options(responseType: ResponseType.plain),
    );
    expect(res.data, isNotNull);
    expect(
      sink.bytesOf(TrafficDirection.down),
      7,
      reason: 'gzip 解压后是 7 字节；绝不能把 content-length(999) 再加一遍',
    );
  });

  test('Range / 206：只计真正回传的那一段', () async {
    final adapter = FakeAdapter((o, req) async {
      await _drain(req);
      return bodyOf([
        List.filled(10, 5),
      ], statusCode: 206, headers: contentLength(10));
    });
    final dio = meteredDio(adapter);
    await dio.get<List<int>>(
      'https://nas.local/webapi/part.bin',
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Range': 'bytes=0-9'},
      ),
    );
    expect(sink.bytesOf(TrafficDirection.down), 10);
    expect(adapter.calls.single.headers['Range'], 'bytes=0-9');
  });

  test('redirect：空跳转体不计数；跟随后的实体只计一次', () async {
    var fetched = 0;
    final adapter = FakeAdapter((o, req) async {
      await _drain(req);
      fetched++;
      if (fetched == 1) {
        return ResponseBody(
          const Stream<Uint8List>.empty(),
          302,
          isRedirect: true,
          headers: {
            'location': ['https://nas.local/webapi/x.cgi'],
          },
        );
      }
      return bodyOf([
        List.filled(42, 8),
      ], headers: contentLength(42));
    });
    final dio = meteredDio(adapter);
    // 第一跳：302，体为空 → 不产生 Rx 样本（0 字节不记）
    await dio.get<List<int>>(
      'https://nas.local/webapi/x.cgi',
      options: Options(responseType: ResponseType.bytes),
    );
    expect(sink.bytesOf(TrafficDirection.down), 0);
    expect(sink.of(TrafficDirection.down), isEmpty);
    // 跟随后的目标资源：只计一次
    await dio.get<List<int>>(
      'https://nas.local/webapi/x.cgi',
      options: Options(responseType: ResponseType.bytes),
    );
    expect(sink.bytesOf(TrafficDirection.down), 42);
    expect(sink.of(TrafficDirection.down).length, 1, reason: '实体只记一条，不重复');
    expect(adapter.calls.length, 2);
  });

  test('retry：重放是新的往返，各记一次（不是重复计）', () async {
    final adapter = FakeAdapter((o, req) async {
      await _drain(req);
      return ResponseBody.fromString('ok', 200, headers: contentLength(2));
    });
    final dio = meteredDio(adapter);
    for (var i = 0; i < 2; i++) {
      await dio.post<String>(
        'https://nas.local/webapi/x.cgi',
        data: Uint8List.fromList([1, 2, 3]),
        options: Options(responseType: ResponseType.plain),
      );
    }
    expect(sink.bytesOf(TrafficDirection.up), 6);
    expect(sink.bytesOf(TrafficDirection.down), 4);
    expect(sink.exact.length, 4, reason: '两次请求 = 四条样本');
  });

  test('模块归属：显式标签生效，未知/缺失回落 unattributed', () async {
    final adapter = FakeAdapter((o, req) async {
      await _drain(req);
      return ResponseBody.fromString('x', 200);
    });
    final dio = meteredDio(adapter);
    Future<void> hit(Map<String, dynamic> extra) => dio.post<String>(
      'https://nas.local/webapi/x.cgi',
      data: Uint8List.fromList([1]),
      options: Options(responseType: ResponseType.plain, extra: extra),
    );
    await hit({kTrafficModuleKey: TrafficModules.chat});
    await hit({kTrafficModuleKey: 'not_a_module'});
    await hit({});
    final modules = sink.of(TrafficDirection.up).map((s) => s.module).toList();
    expect(modules, [
      TrafficModules.chat,
      TrafficModules.unattributed,
      TrafficModules.unattributed,
    ]);
  });

  test('请求失败：Tx 仍然记（发了就是发了），Rx 不记', () async {
    final adapter = FakeAdapter((o, req) async {
      await _drain(req);
      throw DioException(requestOptions: o, message: 'boom');
    });
    final dio = meteredDio(adapter);
    await expectLater(
      dio.post<String>(
        'https://nas.local/webapi/x.cgi',
        data: Uint8List.fromList([1, 2, 3, 4, 5]),
        options: Options(responseType: ResponseType.plain),
      ),
      throwsA(isA<DioException>()),
    );
    expect(sink.bytesOf(TrafficDirection.up), 5);
    expect(sink.bytesOf(TrafficDirection.down), 0);
  });

  test('成本：包一层适配器不改变响应内容与顺序', () async {
    final chunks = [
      utf8.encode('abc'),
      utf8.encode('defg'),
    ];
    final adapter = FakeAdapter((o, req) async {
      await _drain(req);
      return bodyOf(chunks, headers: contentLength(7));
    });
    final dio = meteredDio(adapter);
    final res = await dio.get<String>(
      'https://nas.local/webapi/t.txt',
      options: Options(responseType: ResponseType.plain),
    );
    expect(res.data, 'abcdefg');
    expect(sink.bytesOf(TrafficDirection.down), 7);
  });

  test('TrafficModules 全集中必须包含 unattributed（不静默丢）', () {
    expect(TrafficModules.all, contains(TrafficModules.unattributed));
  });
}
