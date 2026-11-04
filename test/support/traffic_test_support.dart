// 流量计量的测试夹具：一个**记账用**的 TrafficSink + 一个可编排的假适配器。
//
// 不进 `lib/`（只是测试脚手架），让字节数学的用例能离线、确定地跑。
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:synhub/src/core/net/traffic_meter.dart';

/// 把接管到的样本原样存下来，供断言
class RecordingTrafficSink implements TrafficSink {
  final List<TrafficSample> exact = [];
  final List<TrafficEstimate> estimates = [];

  @override
  void addExact(TrafficSample sample) => exact.add(sample);

  @override
  void addEstimate(TrafficEstimate estimate) => estimates.add(estimate);

  List<TrafficSample> of(TrafficDirection d) =>
      exact.where((s) => s.direction == d).toList();

  int bytesOf(TrafficDirection d) =>
      of(d).fold<int>(0, (a, s) => a + s.bytes);

  void clear() {
    exact.clear();
    estimates.clear();
  }
}

/// 可编排的假适配器：每次 fetch 调一次 [responder]，请求流由它决定是否消费。
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.responder);

  final Future<ResponseBody> Function(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  )
  responder;

  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls.add(options);
    return responder(options, requestStream);
  }

  @override
  void close({bool force = false}) {}
}

/// 一个"计量的 Dio"：适配器被 [MeteredHttpClientAdapter] 包住
Dio meteredDio(FakeAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      validateStatus: (s) => s != null,
      followRedirects: false,
    ),
  );
  dio.httpClientAdapter = MeteredHttpClientAdapter(adapter);
  return dio;
}

/// 把若干块拼成一个响应体（chunked 用）
ResponseBody bodyOf(
  List<List<int>> chunks, {
  int statusCode = 200,
  Map<String, List<String>>? headers,
}) => ResponseBody(
  Stream.fromIterable([for (final c in chunks) Uint8List.fromList(c)]),
  statusCode,
  headers: headers,
);

/// `content-length` 头
Map<String, List<String>> contentLength(int n) => {
  Headers.contentLengthHeader: ['$n'],
};
