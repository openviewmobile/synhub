// 视频播放器的**画中画**（Picture-in-Picture）控制。
//
// 为什么要单独一层：
//   * PiP 是 Activity 级能力（`enterPictureInPictureMode` + Manifest 里的
//     `supportsPictureInPicture`），Flutter 拿不到 Activity，只能走通道；
//   * 播放器要**同时**处理两条进入路径：自己按按钮（Dart 发起）与系统手势
//     （Home / 上滑，Dart 是被通知的一方）—— 只有把两者收在同一个
//     `ValueNotifier` 里，界面才不会"手动进去收起了控件、手势进去却还画着"；
//   * 不支持 PiP 的机器（API < 26 或 ROM 裁掉了该特性）**不许摆假按钮**：
//     [probe] 只问一次并缓存结果。
//
// 与其它原生桥一致：通道名常量只在这里出现一次；所有调用都 `try/catch`
// 兜 `MissingPluginException`（非 Android 宿主 = 定义域外）。
//
// 判据（真机 r654）：点按钮 ⇒ 小窗；点小窗放大 ⇒ 回全屏且播放不中断；
// 播放中点 Home ⇒ 系统自动缩窗（Android 12+）。Dart 侧只暴露"现在是/不是"。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生通道（Kotlin: `VideoPipBridge.CHANNEL`，两处逐字相同）
const String kVideoPipChannel = 'synhub/video_pip';

/// 画中画控制器的抽象（测试注入假实现；真实实现见 [SystemVideoPip]）
abstract class VideoPipController {
  /// 这台设备是否支持 PiP（只问一次，结果缓存）
  Future<bool> supported();

  /// 进入小窗；`aspectRatio` 是画面宽高比（0/非法 ⇒ 16:9）
  Future<bool> enter(double aspectRatio);

  /// 播放中开/关"系统手势自动进入小窗"（Android 12+；低版本无效果）
  Future<void> setAutoEnter(bool enabled);

  /// 现在是否在小窗里（系统手势进入时由原生回传）
  ValueListenable<bool> get inPictureInPicture;

  /// 释放（页面销毁时调用；不会主动退出小窗 —— 退出由系统/用户决定）
  Future<void> dispose();
}

/// **全 App 共用一份**（同一时刻只有一个 Activity、一个小窗）。
///
/// 为什么不做成每个播放器各一份：全屏页会**再建一个** `MediaPlayerView`
/// （借同一个适配器），两份控制器都会 `setMethodCallHandler` 同一个通道 ——
/// 谁后销毁就把另一份的 handler 清成 null，小窗事件静默丢失。
/// PiP 状态本来就是**进程级**的，共享一份才是对的；用例照旧注入假实现。
VideoPipController? _shared;

VideoPipController systemVideoPip() => _shared ??= SystemVideoPip();

/// 真实实现：`MethodChannel` + 原生事件。
class SystemVideoPip implements VideoPipController {
  SystemVideoPip({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kVideoPipChannel) {
    // gate-exempt: video-pip —— 见 test/method_channel_gate_guard_test.dart 的
    // `kGateExemptChannels['video-pip']`：画中画是 Android 专属窗口能力，
    // 非 Android 宿主上不存在这个概念；`supported()` 为 false 时按钮不渲染。
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final ValueNotifier<bool> _inPip = ValueNotifier<bool>(false);
  bool? _supported;

  @override
  ValueListenable<bool> get inPictureInPicture => _inPip;

  @override
  Future<bool> supported() async {
    final cached = _supported;
    if (cached != null) return cached;
    // gate-exempt: video-pip —— PiP 是 Android 专属能力；非 Android 宿主没有
    // 这条通道（MissingPluginException ⇒ false），按钮因此不渲染，属定义域外。
    try {
      final value = await _channel.invokeMethod<bool>('supported') ?? false;
      _supported = value;
      return value;
    } on MissingPluginException {
      _supported = false;
      return false;
    } on PlatformException {
      _supported = false;
      return false;
    }
  }

  @override
  Future<bool> enter(double aspectRatio) async {
    if (!await supported()) return false;
    final (width, height) = _ratioOf(aspectRatio);
    // gate-exempt: video-pip —— 同 supported()：Android 专属，非 Android 宿主
    // 在 supported() 那一步已经返回 false，走不到这里。
    try {
      return await _channel.invokeMethod<bool>('enter', {
            'width': width,
            'height': height,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> setAutoEnter(bool enabled) async {
    if (!await supported()) return;
    // gate-exempt: video-pip —— 同上（Android 专属能力，已在 supported() 处门控）
    try {
      await _channel.invokeMethod<bool>('setAutoEnter', {'enabled': enabled});
    } on MissingPluginException {
      // 老包/非 Android：自动进入本来就不存在，静默忽略
    } on PlatformException {
      // 系统此刻不接受参数（例如 Activity 正在切后台）—— 预期失败不崩
    }
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method == 'onPipModeChanged') {
      _inPip.value = call.arguments == true;
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    _inPip.dispose();
  }

  /// 宽高比 → 原生要的整数宽高（用较小的整数对，避免 3840x2160 这种噪声）
  static (int, int) _ratioOf(double aspectRatio) {
    if (!aspectRatio.isFinite || aspectRatio <= 0) return (16, 9);
    // 常见比例直接给精确对，其余按千分比取整
    if ((aspectRatio - 16 / 9).abs() < 0.01) return (16, 9);
    if ((aspectRatio - 4 / 3).abs() < 0.01) return (4, 3);
    if ((aspectRatio - 21 / 9).abs() < 0.02) return (21, 9);
    if (aspectRatio >= 1) return ((aspectRatio * 1000).round(), 1000);
    return (1000, (1000 / aspectRatio).round());
  }
}
