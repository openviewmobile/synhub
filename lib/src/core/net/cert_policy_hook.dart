// 证书裁决的**进程级挂钩**（不含 `dart:io`，web 也安全）。
//
// 为什么要有它：Office 协作那条 WebSocket 走原生 `HttpClient`（不经 Dio），
// 需要和 HTTP 共用"首连信任"的裁决，但 `app.dart` 不能直接 `import 'dart:io'`
// （web 站的 `dart:io` 移植面有硬基线，见 `test/platform_web_test.dart`）。
// 于是：宿主管线（`trust_store.dart`，本来就 import `dart:io`）把
// `evaluateObject` 挂到这里，传输层只读这个挂钩。
typedef CertVerifier = bool Function(Object cert, String host, int port);

/// 由 App 启动时安装；为空 ⇒ 传输层退回"旧行为"（只有工具/测试会落到这里）。
CertVerifier? officeCollabCertVerifier;
