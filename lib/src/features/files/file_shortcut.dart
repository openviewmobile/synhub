// M72：主屏幕快捷方式（Dart 侧抽象 + 注入点 + 失败降级）。
//
// 官方 DS file 的 `RemoteFileClickOptions.SHORTCUT(R.string.homescreen_shortcut)` +
// `ResourceListFragment.java:2268 addShortcut()`：把常用目录钉到 Android 桌面。
// 那必须是平台层（`ShortcutManager.requestPinShortcut`）才能做。
//
// 本批**只做 Dart 侧**（`android/**` 禁改，由父 agent 加 Kotlin 实现）：
//   * [ShortcutBridge] 抽象；
//   * [MethodChannelShortcutBridge] 走**仓库既有命名约定**
//     `synhub/<功能>`，通道 `synhub/shortcut`，方法 `pinShortcut`；
//   * [shortcutBridgeProvider] 注入点（测试覆盖成假桥）；
//   * **失败降级**：平台没实现（桌面 / 测试 / 未加 Kotlin）抛
//     `MissingPluginException`，或实现里回 `PlatformException`，一律 catch 成
//     `false`，**不报错、不崩**。UI 只提示"这台设备不支持"。
//
// 需要父 agent 在 Android 侧加的方法 / 权限见
// `docs/filestation-gaps-wave2.md` §7。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';

/// 把「某个目录」钉到系统主屏。返回 `true` = 已向系统发起请求。
abstract class ShortcutBridge {
  Future<bool> pinShortcut({
    required String id,
    required String label,
    required String path,
  });
}

/// 平台实现：MethodChannel。
///
/// 通道名沿用仓库约定（`synhub/media_open` / `synhub/network` /
/// `synhub/keystore`…），新通道 `synhub/shortcut`。
class MethodChannelShortcutBridge implements ShortcutBridge {
  MethodChannelShortcutBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// 父 agent 要在 Android 侧注册的同名通道。
  static const String channelName = 'synhub/shortcut';

  final MethodChannel _channel;

  /// 快捷方式在本平台的能力结论（**界面据此说明"为什么不能钉"**）。
  ///
  /// 第 55 轮：宿主（macOS/Linux/Windows）上是
  /// `unavailable:not-implemented-on-host`，界面可以显示
  /// `capabilityReasonText(status.reason)` 而不是静默无反应。
  static CapabilityStatus status() =>
      AppPlatformCapabilities.current().statusOf(AppCapability.fileShortcut);

  @override
  Future<bool> pinShortcut({
    required String id,
    required String label,
    required String path,
  }) async {
    // ★ 第 55 轮：先问能力层 —— `synhub/shortcut` 只有 Kotlin 一份，
    //   宿主上不碰通道（失败原因由 [status] 给出）。
    if (!capabilityGateAllows(AppCapability.fileShortcut)) {
      debugPrint(
        capabilityGateLog(AppCapability.fileShortcut, 'shortcut.pinShortcut'),
      );
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('pinShortcut', {
        'id': id,
        'label': label,
        'path': path,
      });
      return ok == true;
    } on MissingPluginException {
      // 平台没实现（桌面 / 测试 / Android 侧还没加）→ 安静降级
      return false;
    } on PlatformException {
      // 系统拒绝（没有权限 / 桌面不支持钉快捷方式）→ 安静降级
      return false;
    }
  }
}

/// 注入点：测试覆盖成假桥，生产用 MethodChannel。
final shortcutBridgeProvider = Provider<ShortcutBridge>(
  (ref) => MethodChannelShortcutBridge(),
);
