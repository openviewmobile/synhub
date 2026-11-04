// Drive G4：「把下载到本地的文件交给系统」——**发送副本（D34）/ 压缩并发送（D35）/
// 打包下载（D31）** 都落在这里。
//
// 为什么复用既有通道：仓库的 Android 原生桥 `MediaOpenBridge.kt`（channel
// `synhub/media_open`）**已经有**三个正好够用的方法——
//   * `saveToDownloads {path,name,mime}` → 复制进系统公共「下载」目录
//     （API 29+ 走 MediaStore，无需权限），返回 MediaStore uri；
//   * `share {path,name,mime}` → `ACTION_SEND` + FileProvider 分享本地文件；
//   * `canShare {path,mime}` → 只问"有没有应用能接"（无副作用）。
// 所以**不需要动 `android/**`**，也不新开 channel（与
// `file_link_share.dart` 的 `shareText` 同一约定）。
//
// 测试纪律：桌面/`flutter test` 没有插件通道 → 三个方法都表现为
// "桥不可用"（`saveToDownloads` 回 null、`share`/`canShare` 回 false），
// 调用方按**明确失败**提示，绝不静默装成成功。需要断言"到底走没走桥"的
// 用例覆盖 [driveSendBridgeProvider] 换成假实现。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:synhub/src/core/platform/app_platform.dart';

/// G4 需要的"系统落盘 / 分享"能力（可注入，便于离线用例）。
abstract class DriveSendBridge {
  /// 复制进系统「下载」目录；成功回 MediaStore uri（老系统回 `file://`），
  /// 失败 / 桥不可用回 `null`。
  Future<String?> saveToDownloads({
    required String path,
    required String name,
    required String mime,
  });

  /// `ACTION_SEND` 分享本地文件；`true` = 选择器已拉起。
  Future<bool> share({
    required String path,
    required String name,
    required String mime,
  });

  /// 只问"有没有应用能接这个分享"（无副作用）。
  Future<bool> canShare({required String path, required String mime});
}

/// 走既有 `synhub/media_open` 的真实现。
class MediaOpenDriveSendBridge implements DriveSendBridge {
  const MediaOpenDriveSendBridge([
    MethodChannel channel = const MethodChannel('synhub/media_open'),
  ]) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<String?> saveToDownloads({
    required String path,
    required String name,
    required String mime,
  }) async {
    if (path.isEmpty || name.isEmpty) return null;
    if (!capabilityGateAllows(AppCapability.mediaStoreExport)) return null;
    try {
      return await _channel.invokeMethod<String>('saveToDownloads', {
        'path': path,
        'name': name,
        'mime': mime,
      });
    } on MissingPluginException {
      // 桌面 / 纯 Dart：没挂桥
      return null;
    } on PlatformException {
      // 桥侧 `save_failed` / `bad_args`
      return null;
    }
  }

  @override
  Future<bool> share({
    required String path,
    required String name,
    required String mime,
  }) async {
    if (path.isEmpty) return false;
    if (!capabilityGateAllows(AppCapability.systemShare)) return false;
    try {
      return await _channel.invokeMethod<bool>('share', {
            'path': path,
            'name': name,
            'mime': mime,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> canShare({required String path, required String mime}) async {
    if (path.isEmpty) return false;
    if (!capabilityGateAllows(AppCapability.systemShare)) return false;
    try {
      return await _channel.invokeMethod<bool>('canShare', {
            'path': path,
            'mime': mime,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

final driveSendBridgeProvider = Provider<DriveSendBridge>(
  (ref) => const MediaOpenDriveSendBridge(),
);
