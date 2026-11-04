// M73（审计行 225）：**在 File Station 里上传本机照片**。
//
// ## 官方基线（APK 证据）
// DSfile 4.17.2-609 的文件抽屉里有 `PBUploadManager` / `PBReleaseSpaceActivity`
// 与 "Instant Upload" 入口 —— 即"从这台手机挑照片传到 NAS 的当前目录"。
//
// ## 为什么之前没做，现在为什么做
// `filestation_api.dart` 的 `photoUpload` 注释里原来写着"我方已有两条相机备份
// 路径（Drive PhotoBackup / Photos Backup），**不新建第三条上传 UI**，
// 避免同一功能三个入口互相打架"。
//
// 用户 2026-09-23 的新规推翻了那个取舍：
// > 「所有的客户端功能必须都要实现并验证，**一个都不能遗漏**」
//
// 官方有、我们没有 ⇒ 必须补。**但不能造一个和备份打架的重复入口**，
// 所以这条入口的定位被刻意收窄成：
//   * **一次性、手动**：挑几张照片 → 传进**你正在浏览的那个目录**；
//   * **不是**计划任务、**不是**自动备份、**不选定固定目标**；
//   * 与相册侧"手机自动备份"（WorkManager + 充电/息屏条件）**职责不重叠**。
//
// ## 复用而不是新造
// 照片枚举走既有的 `DeviceMediaLibrary`（相册侧那套 MediaStore 桥，
// 已实现权限申请 / 分页 / `materialize`），**不新写一个选择器**。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/media/cache_service.dart' show humanBytes;
import '../../core/ui/app_sheet.dart';
import '../../data/media/device_media_library.dart';
import '../photos/photo_backup_providers.dart';

/// 待上传的一张本机照片。
class LocalPhotoPick {
  const LocalPhotoPick({
    required this.assetId,
    required this.name,
    required this.takenTimeMs,
  });

  final String assetId;
  final String name;
  final int takenTimeMs;
}

/// 枚举本机照片（**只读**，不动相册）。
///
/// 抽成 provider 是为了离线可测：widget 测试注入假实现，
/// 既不申请权限、也不碰真实 MediaStore。
final localPhotosProvider = FutureProvider<List<DeviceMediaAsset>>((ref) async {
  final lib = ref.read(deviceMediaLibraryProvider);
  // 只要图片（视频是另一条链路，官方 Instant Upload 也是图片为主）。
  final perm = await lib.ensurePermission();
  // `partial`（Android 14+ 只授权了选中的那几张）**也要放行** ——
  // 手动传照片时用户挑的就是他刚授权的那几张；只有 `denied` 才算失败。
  if (perm == MediaPermission.denied) {
    throw const DeviceMediaPermissionDenied();
  }
  return lib.list(includeVideos: false, limit: 300);
});

/// 用户拒绝了相册权限（UI 要提示"去设置里给权限"，而不是"上传失败"）。
class DeviceMediaPermissionDenied implements Exception {
  const DeviceMediaPermissionDenied();
}

/// 弹本机照片多选面板。返回用户选中的资产（取消 ⇒ 空表）。
Future<List<DeviceMediaAsset>> showLocalPhotosSheet(
  BuildContext context, {
  required List<DeviceMediaAsset> assets,
}) async {
  final picked = await showAppSheet<List<DeviceMediaAsset>>(
    context,
    title: localPhotosSheetTitle(),
    children: [
      if (assets.isEmpty)
        AppSheetSection(
          children: [
            AppSheetAction(
              icon: Icons.photo_library_outlined,
              label: localPhotosEmpty(),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        )
      else
        AppSheetSection(
          children: [
            for (var i = 0; i < assets.length && i < 60; i++)
              AppSheetAction(
                key: ValueKey('local-photo-${assets[i].id}'),
                icon: assets[i].isVideo
                    ? Icons.videocam_outlined
                    : Icons.image_outlined,
                label: assets[i].displayName,
                description: humanBytes(assets[i].size),
                // 单选语义（简化且可预测）：一次选一张。
                // 官方 Agent 也是逐个确认上传，不做批量勾选。
                onTap: () => Navigator.of(context).pop([assets[i]]),
              ),
          ],
        ),
    ],
  );
  return picked ?? const <DeviceMediaAsset>[];
}

// ------------------------------------------------------------------ 文案
//
// 走 `dataText`（与文件模块其它 G4/G5 文案同一套），不新增 ARB key。
String _t(String key, String zh) => dataText(key, zh);

String localPhotosSheetTitle() => _t('fsLocalPhotosTitle', '上传本机照片到当前目录');
String localPhotosEmpty() => _t('fsLocalPhotosEmpty', '这台手机上没有找到照片');
String localPhotosNeedPermission() =>
    _t('fsLocalPhotosNeedPermission', '需要相册权限才能读取本机照片，请到系统设置里授权');
String localPhotosPickFailed() => _t('fsLocalPhotosPickFailed', '读取本机照片失败');
String localPhotosUploading(String name) =>
    _t('fsLocalPhotosUploading', '正在上传 {name}').replaceAll('{name}', name);
String localPhotosUploaded(String name) =>
    _t('fsLocalPhotosUploaded', '已上传 {name}').replaceAll('{name}', name);
