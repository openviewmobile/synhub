// macOS **Debug** 档的安全存储后端选择（第 665 轮）。
//
// ## 为什么要这个文件（用户当面问的："为啥老提示我输入密码？"）
//
// 本仓 macOS 构建是 **ad-hoc 签名**（没有 team ID、没有开发者证书），
// 而 ad-hoc 签名**每次构建都变** ⇒ 登录钥匙串里那些
// `flutter_secure_storage_service` 条目的 ACL **永远不认识新构建**。
// 于是每次冷启动读凭据，macOS 都会弹
//
//   "SynHub 想使用您钥匙串中储存的机密信息"
//
// 并**阻塞**那次读（r328 的 D30 已经把"阻塞"用超时+熔断挡住，但**弹框还在**）。
// 用户的直接感受就是：一跑 App 就要输一次登录密码。
//
// ## 取舍
//
// * **只影响 Debug**：`kDebugMode`；Release/Profile 一律走钥匙串（用户拿到的包不变）。
// * **只影响 macOS**：Linux 是 libsecret、Windows 是 DPAPI、Android 是 Keystore，
//   它们不会这样弹框（各自用同一套签名）。
// * 落盘位置在 App 沙箱的 Application Support 下，权限 `0600`，
//   内容与钥匙串里等价的明文（**仅本机开发档**）。
// * 想显式验证钥匙串那条路：`SYNHUB_KEYCHAIN=1` 环境变量（探针/取证用）。
//
// ## 为什么是条件导入
//
// `dart:io` 在 Web 上不存在 —— 这个文件被 `app_secure_storage.dart` 引用，
// 而那条链是会编进 Web 包的。所以用 façade：Web 侧永远 `false`。
export 'debug_secret_file_stub.dart'
    if (dart.library.io) 'debug_secret_file_io.dart';
