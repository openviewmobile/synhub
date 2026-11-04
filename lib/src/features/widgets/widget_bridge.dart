// Android 主屏小组件的 **Dart ↔ 平台通道**（契约层）。
//
// 通道沿用仓库既有命名约定（`synhub/deep_link` / `synhub/shortcut`
// / `synhub/media_open`…），新通道 **`synhub/widget`**。
//
// ## 方法（Dart → Android）
//   * `pushSnapshot({snapshot: String})` → **Bool**
//     把 `widget_snapshot.dart` 生成的 JSON 快照交给 Android 落盘
//     （`WidgetSnapshotStore`，SharedPreferences），并立刻刷新**全部**小组件实例。
//     `true` = 已落盘。落盘失败/Schema 不认识 → `false`（Dart 侧不报错）。
//   * `requestRefresh()` → **Bool**
//     按已落盘的快照重画全部小组件（不传新数据）。用户手动点"刷新"或
//     App 回到前台时用。
//   * `takePendingTarget()` → **String?**
//     取走"由小组件点击冷启动/唤起"带来的落点字符串（**取走即清**，
//     同 `ShortcutBridge.consumePendingPath` 的语义），交给
//     [parseWidgetTarget] 解析。
//
// ## 事件（Android → Dart）
//   * `onWidgetAction`（无参）
//     App **已经在前台**时又点了一次小组件（`singleTop` → `onNewIntent`）。
//     Dart 侧收到后调 `takePendingTarget()` 拿落点。
//
// ## 失败降级
// 平台没实现（桌面 / 单测 / 未装 Android 侧）→ `MissingPluginException`；
// 实现抛错 → `PlatformException`。**一律 catch**：
//   * `pushSnapshot` / `requestRefresh` 回落 `false`；
//   * `takePendingTarget` 回落 `null`。
// 小组件是锦上添花的能力，**任何情况下都不允许因为它把 App 打崩**。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';

/// 小组件平台能力。测试覆盖成假桥（见 `test/widget_bridge_test.dart`）。
abstract class WidgetBridge {
  /// 推送快照 JSON，返回"平台是否已收下"。
  Future<bool> pushSnapshot(String snapshotJson);

  /// 请求按已落盘快照重画。
  Future<bool> requestRefresh();

  /// 取走并清空"小组件点击带来的落点字符串"。
  Future<String?> takePendingTarget();

  /// 前台时再次点击小组件的事件流（每次事件都应跟一次 [takePendingTarget]）。
  Stream<void> get onAction;
}

/// MethodChannel 实现。
class MethodChannelWidgetBridge implements WidgetBridge {
  MethodChannelWidgetBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    // 第 55 轮：只在"能力层放行"时注册监听（Android 才有的桥）。
    if (!capabilityGateAllows(AppCapability.homeScreenWidgets)) return;
    _channel.setMethodCallHandler(_handle);
  }

  /// Android 侧 `SynologyWidgetBridge.CHANNEL` 必须逐字相同。
  static const String channelName = 'synhub/widget';

  final MethodChannel _channel;
  final StreamController<void> _actions = StreamController<void>.broadcast();

  /// 小组件在本平台的能力结论（**界面据此说明"为什么没有小组件"**）。
  static CapabilityStatus capabilityStatus() => AppPlatformCapabilities.current()
      .statusOf(AppCapability.homeScreenWidgets);

  /// 第 55 轮：`synhub/widget` 只有 Kotlin 一份（Android AppWidget）⇒
  /// 宿主上能力层报 `unavailable:not-implemented-on-host`，**不碰通道**。
  static bool get _allowed =>
      capabilityGateAllows(AppCapability.homeScreenWidgets);

  static void _logBlocked(String what) => debugPrint(
    capabilityGateLog(AppCapability.homeScreenWidgets, 'widget.$what'),
  );

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method == 'onWidgetAction') {
      if (!_actions.isClosed) _actions.add(null);
    }
    return null;
  }

  @override
  Stream<void> get onAction => _actions.stream;

  @override
  Future<bool> pushSnapshot(String snapshotJson) async {
    if (!_allowed) {
      _logBlocked('pushSnapshot');
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('pushSnapshot', {
        'snapshot': snapshotJson,
      });
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> requestRefresh() async {
    if (!_allowed) {
      _logBlocked('requestRefresh');
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('requestRefresh');
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> takePendingTarget() async {
    if (!_allowed) {
      _logBlocked('takePendingTarget');
      return null;
    }
    try {
      return await _channel.invokeMethod<String>('takePendingTarget');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// 注入点：测试覆盖成假桥，生产用 MethodChannel。
final widgetBridgeProvider = Provider<WidgetBridge>(
  (ref) => MethodChannelWidgetBridge(),
);
