// 云端客户端的**离线假传输**（不碰真 socket，更不联网）。
//
// 为什么不用 `HttpServer`：`cloud_llm_client_test.dart` 里那套回环服务器验证的是
// "真 socket + 真 SSE 分块"（值得保留）；但新增的思考/token 用例只是想验
// **解析逻辑**，用 Dio 的 `HttpClientAdapter` 直接喂字节更稳、更快，也天然离线。
//
// 用法：
//   final t = FakeCloudTransport(sse: ['{"choices":[…]}']);
//   final client = CloudLlmClient(dio: t.dio());
//   await client.stream(cfg: cfg, system: 's', user: 'u', collect: collect).toList();
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class FakeCloudTransport implements HttpClientAdapter {
  FakeCloudTransport({
    this.sse = const [],
    this.nonStream,
    this.status = 200,
    this.errorBody = '',
    this.errorBodies = const [],
  });

  /// SSE 的 `data:` 帧（**按顺序**写出去；会自动补 `data: [DONE]`）
  List<String> sse;

  /// 非流式回包（给了它就不再走 SSE）
  Object? nonStream;

  /// 非 200 时走这条：状态码
  int status;

  /// 非 200 的错误体（默认给一个 OpenAI 形状的 error）
  String errorBody;

  /// 每次调用各自的错误体（非空时优先；用完后一直用最后一条）。
  /// 用来验"参数重试"：第一次报不认 `stream_options`，第二次报别的。
  List<String> errorBodies;

  /// 收到的请求体（按顺序）
  final List<Map<String, dynamic>> bodies = [];
  final List<String> urls = [];
  final List<Map<String, String>> headers = [];
  int calls = 0;

  Dio dio() {
    final d = Dio(BaseOptions(validateStatus: (_) => true));
    d.httpClientAdapter = this;
    return d;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    urls.add(options.uri.toString());
    headers.add(options.headers.map((k, v) => MapEntry(k, '$v')));
    if (requestStream != null) {
      final raw = await utf8.decoder.bind(requestStream).join();
      if (raw.isNotEmpty) {
        try {
          bodies.add((jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', v)));
        } catch (_) {}
      }
    }
    if (status < 200 || status >= 300) {
      final body = errorBodies.isEmpty
          ? errorBody
          : errorBodies[(calls - 1).clamp(0, errorBodies.length - 1)];
      return ResponseBody.fromString(
        body.isEmpty ? '{"error":{"message":"nope"}}' : body,
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (nonStream != null) {
      return ResponseBody.fromString(
        jsonEncode(nonStream),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final buf = StringBuffer();
    for (final frame in sse) {
      buf.write('data: $frame\n\n');
    }
    buf.write('data: [DONE]\n\n');
    return ResponseBody.fromString(
      buf.toString(),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
