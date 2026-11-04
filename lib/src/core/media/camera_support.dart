import 'package:flutter/foundation.dart';

/// **本机有没有"拍照"这条路**（`image_picker` 的 `ImageSource.camera`）。
///
/// 为什么要有这个开关（`DA293`，用户 macOS 手测报障）：
/// 「Profile 里 take photo 点了没反应」。根因不是按钮坏了，而是
/// `image_picker` 在 **macOS / Windows / Linux** 上压根没有相机实现
/// （`image_picker_macos` 只是 `file_selector` 的一层壳，只支持图库；
/// 传 `ImageSource.camera` 会在插件内部抛 `UnimplementedError`）。
/// 原来的调用点**没有 try/catch**，异常落进异步缝隙 ⇒ 界面零反馈，
/// 用户看到的就是"点了没反应"。
///
/// 三条规矩：
///   ① **没相机就不摆"拍照"按钮**（假控件比没控件更坏）；
///   ② 真机（Android/iOS）保持原样；
///   ③ 所有挑图调用都要 `try/catch` + 给一句人话原因 —— 以后再出别的原因
///      也不会变成"点了没反应"。
bool get kCameraCaptureSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);
