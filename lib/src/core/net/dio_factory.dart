import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'traffic_meter.dart';
import 'trust_store.dart';
import 'web_dio_adapter.dart';

/// Dio 工厂 —— 统一处理三件 DSM/QuickConnect 必需的事：
///
/// 1. **自签证书**：NAS 用自签证书（本机 NAS 是 `CN=nas.example.com`），
///    且常常以 IP 访问，主机名校验也会失败。
///    * 传了 [trustPolicy] → 走**首连信任**：指纹已入库才放行，
///      否则记录挑战并拒绝（上层弹框后重试，见 `trust_store.dart`）；
///    * 没传 → 旧行为"一律放行"（工具脚本/探针/集成测试用）。
/// 2. **Cookie**：[CookieJarInterceptor] 让同一 Dio 内的 Set-Cookie 跨请求保留。
/// 3. **超时与状态码**：DSM 的错误也走 200 + `success:false`，所以
///    `validateStatus` 一律放行，由上层解析。
abstract final class DioFactory {
  /// 建一个可直接用于 DSM / QuickConnect 的 Dio。
  ///
  /// [allowSelfSigned] 置 false 时走系统信任链（用于有正式证书的部署）。
  /// [onCertificate] 会在收到证书时回调，可用来记录/比对指纹（**无条件调用**，
  /// 不管最后放不放行，这样上层总能拿到指纹去弹框）。
  /// [trustPolicy] 非空时由它决定放行与否。
  static Dio create({
    Duration connectTimeout = const Duration(seconds: 15),
    Duration receiveTimeout = const Duration(seconds: 30),
    bool allowSelfSigned = true,
    void Function(X509Certificate cert, String host)? onCertificate,
    TrustPolicy? trustPolicy,
    List<Interceptor> interceptors = const [],
    /// 这条 Dio 的**流量模块标签**（空 = 未归属）。连接探测类客户端
    /// 刻意留空：它们不属于任何用户功能模块。
    String module = '',
    String transport = '',
  }) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        validateStatus: (s) => s != null,
      ),
    );

    // ★ `DA280`（r664）：**Web 走浏览器适配器**。
    //   以前这里一律装 `IOHttpClientAdapter` + `HttpClient`（`dart:io`）——
    //   Flutter Web 上那是"能编译、运行期抛"的桩 ⇒ 连接探测立刻
    //   `Unsupported operation` ⇒ 界面判"所有地址不可达"（整站连不上 NAS，
    //   与 CORS 无关）。门面按 `dart.library.js_interop` 条件导入，
    //   原生侧拿到 null ⇒ 走的还是**原来那段代码，一字未改**。
    final webAdapter = createWebHttpClientAdapter();
    if (webAdapter != null) {
      // Web：证书由浏览器判（自签要用户点"继续前往"），
      // `allowSelfSigned` / 指纹固定在此**不生效**，也不假装生效。
      dio.httpClientAdapter = webAdapter;
    } else {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient()..connectionTimeout = connectTimeout;
          if (allowSelfSigned || trustPolicy != null) {
            client.badCertificateCallback = (cert, host, port) {
              onCertificate?.call(cert, host);
              if (trustPolicy != null) {
                return trustPolicy.evaluate(cert, host, port);
              }
              return true; // 没接信任策略时的旧行为：自签/域名不匹配都放行
            };
          }
          return client;
        },
      );
    }

    // 流量计量：包一层适配器（正式流量 = Dart 客户端实际传输的字节）
    attachTrafficMeter(dio);
    if (module.isNotEmpty) {
      dio.interceptors.insert(
        0,
        TrafficTagInterceptor(module, transport: transport),
      );
    }
    dio.interceptors.add(CookieJarInterceptor());
    dio.interceptors.addAll(interceptors);
    return dio;
  }
}

/// 极简内存 Cookie jar。
///
/// DSM WebAPI 主要靠 `sid` 参数鉴权，但登录过程会下发 cookie，
/// 部分入口（如 `entry.cgi`）依赖它。
class CookieJarInterceptor extends Interceptor {
  final Map<String, String> _cookies = {};

  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  void clear() => _cookies.clear();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_cookies.isNotEmpty) {
      options.headers['Cookie'] = _cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _absorb(response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final resp = err.response;
    if (resp != null) _absorb(resp);
    handler.next(err);
  }

  void _absorb(Response<dynamic> resp) {
    final raw = resp.headers['set-cookie'];
    if (raw == null) return;
    for (final line in raw) {
      final pair = line.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      if (value.isEmpty || value == 'deleted') {
        _cookies.remove(name);
      } else {
        _cookies[name] = value;
      }
    }
  }
}
