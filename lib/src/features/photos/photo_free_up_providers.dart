// 相册「释放手机空间」的 provider 装配。
//
// 只有一件可替换件：[photoFreeUpDeleterProvider]。它从**同一个**本机相册探针
// （[deviceMediaLibraryProvider]）上取"会动用户照片"的删除能力 —— 生产实现是
// `MethodChannelDeviceMediaLibrary`，用例里注入假实现（**绝不真的删文件**）。
//
// ⚠️ 桌面 / 纯 Dart 测试 / 没装桥时，探针**没有**删除能力 → provider 回 null，
// 页面走"这台设备不支持由应用删除"的降级路径（人话说明 + 去系统设置），
// **绝不假装删掉了**。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/media/device_media_library.dart';
import 'photo_backup_providers.dart' show deviceMediaLibraryProvider;

/// 删除本地相册文件的能力；这台设备/这个宿主没有就回 null。
final photoFreeUpDeleterProvider = Provider<DeviceMediaDeleter?>((ref) {
  final DeviceMediaLibrary media = ref.watch(deviceMediaLibraryProvider);
  // 读能力与删能力在**同一个**探针对象上；类型不同（一个只读、一个动照片），
  // 所以这里显式转一次。
  return media is DeviceMediaDeleter ? media as DeviceMediaDeleter : null;
});
