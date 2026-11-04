// libsynochatpunch 的 Dart FFI 绑定 —— **门面**（web 站需要条件导入）。
//
// 为什么要有这一层（第 334 轮）：
//   `dart:ffi` 在 web 上**不存在** ⇒ 只要 `main.dart` 的可达图里出现
//   `import 'dart:ffi'`，`flutter build web` 就 `Target dart2js failed`（第 130 轮起
//   一直是这个 P0）。而打洞在 web 上**本来就没有实现**（没有动态库、没有
//   `dart:io Process`）⇒ 正确做法不是"移植 FFI"，而是**把实现按平台条件导入**：
//     * `punch_ffi_io.dart`  —— 真实实现（Android/iOS/macOS/Linux/Windows，原样保留）；
//     * `punch_ffi_stub.dart` —— web 桩：**同一套 API 表面**，用到就抛
//       `UnsupportedError`（"做不到"要**说出来**，不许静默假成功，§2.0.42/§2.0.45）。
//
// 选择条件用 `dart.library.io`（不是 `dart.library.ffi`）：真实实现同时依赖
// `dart:io` 的 `Platform`/`DynamicLibrary`，用 io 这个超集条件更稳。
// 两个实现文件都**不许**再被别的文件直接 import —— 一律经本门面。
export 'punch_ffi_stub.dart' if (dart.library.io) 'punch_ffi_io.dart';
