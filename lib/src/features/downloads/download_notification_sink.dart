// ⑥下载 F12：**系统通知出口**（本地通知，不走 FCM）。
//
// `download_completion.dart` 早先就实现了完成/失败的**差分与事件流**，但当时
// 明确登记了一个能力边界：仓库的原生通知桥只有"聊天消息"专用方法，
// 没有通用本地通知 ⇒ 系统通知栏那一步做不了。
//
// 本轮补上原生侧：`android/.../DownloadNotifications.kt`
// 通道 `synhub/download_notifications`（`available` / `show`）。
// 本文件是它的 Dart 出口；逻辑（差分/开关）仍然只在 `download_completion.dart`。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';

/// 通知出口（可替换，便于用例注入假实现）。
abstract class DownloadNotificationSink {
  /// 系统是否允许发通知（Android 13+ 未授权 POST_NOTIFICATIONS 时为 false）。
  Future<bool> available();

  Future<void> show({
    required int id,
    required String title,
    required String text,
  });
}

/// 走方法通道的真实实现。
class MethodChannelDownloadNotifications implements DownloadNotificationSink {
  const MethodChannelDownloadNotifications();

  static const MethodChannel _channel = MethodChannel(
    'synhub/download_notifications',
  );

  @override
  Future<bool> available() async {
    // 第 55 轮：`synhub/download_notifications` 只有 Android 侧实现。
    if (!capabilityGateAllows(AppCapability.downloadNotifications)) {
      capabilityGateLog(
        AppCapability.downloadNotifications,
        'download_notifications.available',
      );
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // 单测/桌面环境没有这条通道 ⇒ fail-closed（不假装"发过了"）。
      return false;
    }
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String text,
  }) async {
    // 第 55 轮：同上，宿主上如实"没有这项能力"，不碰通道。
    if (!capabilityGateAllows(AppCapability.downloadNotifications)) {
      capabilityGateLog(
        AppCapability.downloadNotifications,
        'download_notifications.show',
      );
      return;
    }
    try {
      await _channel.invokeMethod<void>('show', {
        'id': id,
        'title': title,
        'text': text,
      });
    } on PlatformException {
      // 发不出去不该影响下载页（界面已有应用内提示）。
    } on MissingPluginException {
      // 同上。
    }
  }
}

final downloadNotificationSinkProvider = Provider<DownloadNotificationSink>(
  (ref) => const MethodChannelDownloadNotifications(),
);
