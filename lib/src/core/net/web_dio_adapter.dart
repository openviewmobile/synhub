// Web 端 HTTP 适配器的**条件导入门面**（`DA280`，r664）。
//
// ## 为什么需要它
//
// `DioFactory` 以前一律装 `IOHttpClientAdapter` + `HttpClient`（`dart:io`）。
// Flutter Web 上 `dart:io` 只有**能编译、运行期抛**的桩 ⇒
// 连接探测直接 `Unsupported operation` ⇒ 界面判"所有地址不可达"
// （真机取证：`docs/evidence-r664/`；根因与判据见 `docs/platform-web.md` §13）。
//
// 拆法：门面按 `dart.library.js_interop` 选实现。
//   * Web：`BrowserHttpClientAdapter`（`package:dio/browser.dart`，基于 `fetch`）；
//   * 原生/VM：返回 `null`（调用方继续走 `IOHttpClientAdapter` + 证书回调）。
// ★ `BrowserHttpClientAdapter` 依赖 `dart:js_interop`，**不能**进 VM 产物，
//   所以必须条件导入，不能在同一个文件里 `kIsWeb ? ... : ...` 分支。
export 'web_dio_adapter_stub.dart'
    if (dart.library.js_interop) 'web_dio_adapter_web.dart';
