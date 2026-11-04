// libmpv 属性桥的**条件导入门面**（`DA279`，r664）。
//
// ## 为什么要有这一层
//
// `media_kit` 的 `NativePlayer.getProperty/setProperty` **只存在于原生实现**：
// Web 上 `NativePlayer` 来自 `stub.dart`，**没有这两个方法**。
// 直接写 `platform is NativePlayer` 再调 `getProperty` 的后果是
// **`flutter build web` 编译不过**（dart2js：`The method 'getProperty' isn't
// defined for the type 'NativePlayer'`）—— 整个 Web 站一个产物都出不来。
//
// 拆法：门面按 `dart.library.io` 选实现。
//   * 原生：`mpv_property_bridge_io.dart`（真调 libmpv）；
//   * Web/其他：`mpv_property_bridge_stub.dart`（`forPlatform` 恒为 null）。
// 调用方只认 `MpvPropertyBridge.forPlatform(...)` —— **null 就是"这个平台没有"**，
// 与"设了没生效"分开表达（不假装设上了）。
export 'mpv_property_bridge_stub.dart'
    if (dart.library.io) 'mpv_property_bridge_io.dart';
