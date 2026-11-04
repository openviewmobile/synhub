// libmpv 属性桥 —— **Web / 非原生实现**（`DA279`，r664）。
//
// 存在的唯一理由：Web 上 `media_kit` 的 `NativePlayer` 是 `stub.dart`，
// **没有** `getProperty/setProperty`。若把这些调用留在共用代码里，
// `flutter build web` 直接编译失败（整站零产物）。
//
// 语义：`forPlatform` 恒为 null ⇒ 调用方当作"这个平台没有 libmpv 属性"，
// 静默跳过（界面上字幕位置/背景条本来也不会摆给 Web —— 见 `DA271` 的口径）。
final class MpvPropertyBridge {
  MpvPropertyBridge._();

  static MpvPropertyBridge? forPlatform(Object? platform) => null;

  Future<String> get(String name) async =>
      throw UnsupportedError('libmpv properties are not available on this platform');

  Future<void> set(String key, String value) async =>
      throw UnsupportedError('libmpv properties are not available on this platform');
}
