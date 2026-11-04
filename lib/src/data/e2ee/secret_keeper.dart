// 静态机密的"外面再包一层"：接口定义（**这个文件不许引 Flutter**）。
//
// 为什么单独放一份：`e2ee_service.dart` 是能被 `dart run tool/*.dart` 直接加载的
// 文件（探针都在用），一旦它 transitively 引到 `package:flutter/*`，纯 Dart VM
// 就编不过了（`dart:ui` 不存在）。所以：
//   * 接口 + no-op + 假实现放这里（零依赖）；
//   * 真正用 Android Keystore 的实现在
//     `lib/src/core/security/keystore_secret_keeper.dart`（可引 Flutter），
//     由 `e2eeServiceProvider` 注入；探针/单测不注入 → 退回 no-op，
//     行为与"改造前"完全一致。
//
import 'dart:convert';

// 语义：`seal` 返回 null = **本环境不支持**（明文落盘）；`open` 返回 null =
// 解不开（Keystore 密钥丢了 / 密文被改过），上层必须当成"本机没有身份"。

/// 能"封/开"一段文本的不透明加密器
abstract class SecretKeeper {
  /// 封。返回 null 表示本环境不支持（调用方退回明文保存）。
  Future<String?> seal(String plain);

  /// 开。返回 null 表示解不开。
  Future<String?> open(String encoded);
}

/// 什么都不做：`seal` 永远 null（= 不支持），`open` 永远 null。
class NoopSecretKeeper implements SecretKeeper {
  const NoopSecretKeeper();

  @override
  Future<String?> seal(String plain) async => null;

  @override
  Future<String?> open(String encoded) async => null;
}

/// 测试用假 Keystore：内存里"封/开"，可以模拟"没有 Keystore"「密钥丢了」。
class InMemorySecretKeeper implements SecretKeeper {
  InMemorySecretKeeper({this.available = true, this.failOpen = false});

  /// false = 模拟本环境没有 Keystore（seal 返回 null → 走明文分支）
  bool available;

  /// true = 模拟 Keystore 里的密钥丢了（open 返回 null）
  bool failOpen;

  final Map<String, String> _vault = {};

  /// 被调用了几次 seal（断言"升级旧格式时确实重新封装了"）
  int seals = 0;

  @override
  Future<String?> seal(String plain) async {
    if (!available) return null;
    seals++;
    final encoded = 'fake:${base64Encode(utf8.encode(plain))}';
    _vault[encoded] = plain;
    return encoded;
  }

  @override
  Future<String?> open(String encoded) async {
    if (!available || failOpen) return null;
    return _vault[encoded];
  }
}
