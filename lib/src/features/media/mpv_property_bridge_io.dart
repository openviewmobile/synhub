// libmpv 属性桥 —— **原生实现**（`DA279`，r664）。
//
// 只在 `dart.library.io` 下被选进来（见 `mpv_property_bridge.dart` 的门面注释）。
// Web 的 `NativePlayer` 没有 `getProperty/setProperty`，由 stub 顶掉。
import 'package:media_kit/media_kit.dart';

/// 把 `media_kit` 的 `NativePlayer` 收成"读/写 libmpv 属性"两件事。
final class MpvPropertyBridge {
  MpvPropertyBridge._(this._native);

  final NativePlayer _native;

  /// 不是 `NativePlayer`（测试替身 / 未来别的实现）⇒ 返回 **null**，
  /// 调用方据此静默跳过 —— 不假装设上了。
  static MpvPropertyBridge? forPlatform(Object? platform) =>
      platform is NativePlayer ? MpvPropertyBridge._(platform) : null;

  Future<String> get(String name) async => (await _native.getProperty(name)).trim();

  Future<void> set(String key, String value) => _native.setProperty(key, value);
}
