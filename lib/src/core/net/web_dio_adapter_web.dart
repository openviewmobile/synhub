// Web 端 HTTP 适配器 —— **浏览器实现**（`DA280`，r664）。
//
// 只在 `dart.library.js_interop` 下被选进来（见 `web_dio_adapter.dart`）。
//
// ★ 语义差别（必须如实记，不是"少做了"）：
//   * **证书不再由我们判**：TLS 握手是浏览器做的，自签证书要用户在
//     浏览器里点"继续前往"（§8 的产品决策）；因此 `allowSelfSigned` /
//     证书指纹固定（pinning）在 Web 上**不生效**，也**不该**假装生效；
//   * `withCredentials = true`：让 `sid` 会话 cookie 随请求发（DSM 的
//     `entry.cgi` 依赖它）；
//   * 头部白名单由浏览器决定（CORS），这不是本仓代码能单方面解决的。
import 'package:dio/browser.dart';
import 'package:dio/dio.dart';

/// Web 上返回浏览器适配器；原生返回 `null`（走 `IOHttpClientAdapter`）。
HttpClientAdapter? createWebHttpClientAdapter() {
  final adapter = BrowserHttpClientAdapter();
  // DSM 登录/校验靠 cookie，跨源时必须允许带凭据（服务端要配
  // `Access-Control-Allow-Credentials: true`）。
  adapter.withCredentials = true;
  return adapter;
}
