// 「另存到下载目录 / 分享」—— 对齐原版 `DownloadFragment` 的 option 1、2。
//
// 原版：
//   * `DOWNLOAD(1)`：`FileUtil.moveFileToPublicDownloadDir` 之后
//     `DownloadManager.addCompletedDownload`（进系统「下载」+ 通知栏一条记录）；
//   * `DOWNLOAD_SHARE(2)`：`FileProvider.getUriForFile` + `ACTION_SEND` 分享面板；
//   * 入口不是点附件本身 —— 点附件是 `OPEN(0)`；「下载」在消息长按面板里
//     （`ActionSheetConfiguration.isAllowDownload` = 不是投票 + 有附件 + 附件大小 > 0），
//     「分享」在图片查看器（`ImagePagerFragment.Callbacks.onShare`）。
//
// Android 侧实现见 `MediaOpenBridge.kt`：API 29+ 用 MediaStore 写公共「下载」
// 目录（不需要存储权限），分享走 `${applicationId}.fileprovider`。
import 'package:flutter/material.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/l10n.dart';
import '../../data/chat_api.dart';
import '../../data/dto/post_dto.dart';
import 'attachment_access.dart';
import 'attachment_view.dart';
import 'download_dialog.dart';
import 'media_stream.dart';

const MethodChannel _channel = MethodChannel('synhub/media_open');

///「另存到下载目录 / 分享」的原生桥。测试里覆盖成假的。
class FileActionBridge {
  const FileActionBridge();

  /// 存进系统「下载」目录；返回 MediaStore 的 uri（失败/不支持返回 null）
  Future<String?> saveToDownloads({
    required String path,
    required String name,
    required String mime,
  }) async {
    if (!capabilityGateAllows(AppCapability.mediaStoreExport)) return null;
    try {
      return await _channel.invokeMethod<String>('saveToDownloads', {
        'path': path,
        'name': name,
        'mime': mime,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 拉起分享面板；false = 没有应用能接 / 不支持
  Future<bool> share({
    required String path,
    required String name,
    required String mime,
  }) async {
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

  /// 只问"有没有应用能接这个分享"（无副作用，真机验收用）
  Future<bool> canShare({required String path, required String mime}) async {
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

  /// 删掉上面存进 MediaStore 的那一行（清场/取消另存时用）
  Future<bool> deleteSaved(String uri) async {
    if (!capabilityGateAllows(AppCapability.mediaStoreExport)) return false;
    try {
      return await _channel.invokeMethod<bool>('deleteSaved', {'uri': uri}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// 另存到「下载」的结果
class SaveOutcome {
  const SaveOutcome({this.uri, this.error, this.cancelled = false});

  /// 成功：MediaStore 的 uri（或老系统的 `file://`）
  final String? uri;

  /// 失败文案
  final String? error;

  /// 用户点了下载框的「取消」
  final bool cancelled;

  bool get ok => uri != null;
}

/// 先把附件下到缓存目录（带进度框，可取消），再让原生存进公共「下载」目录。
Future<SaveOutcome> saveAttachmentToDownloads(
  BuildContext context, {
  required ChatApi? api,
  required PostDto post,
  required AttachmentAccess? access,
  required String cachePath,
  required String name,
  FileActionBridge bridge = const FileActionBridge(),
  AppText? text,
}) async {
  final t = text ?? context.t;
  if (post.postId <= 0) {
    return SaveOutcome(error: t.chatErrNoServerPost);
  }
  final prop = post.attachments.isEmpty ? null : post.attachments.first;
  if (prop == null) return SaveOutcome(error: t.chatErrNoAttachment);
  if (!context.mounted) return SaveOutcome(error: t.chatErrPageClosed);

  final outcome = await runWithDownloadDialog(context, (task) async {
    final err = await downloadAttachment(
      api,
      post,
      prop,
      path: cachePath,
      access: access,
      task: task,
      text: t,
    );
    if (err != null) throw DownloadFailedException(err);
  }, filename: name);
  if (outcome == kDownloadCancelled) {
    return const SaveOutcome(cancelled: true);
  }
  if (outcome != null) return SaveOutcome(error: outcome);

  final uri = await bridge.saveToDownloads(
    path: cachePath,
    name: name,
    mime: mimeForFileName(name),
  );
  if (uri == null) {
    return SaveOutcome(error: t.chatErrSaveToDownloadsFailed);
  }
  return SaveOutcome(uri: uri);
}

/// 分享附件：同样先下到缓存，再让原生走 `ACTION_SEND`。
Future<String?> shareAttachment(
  BuildContext context, {
  required ChatApi? api,
  required PostDto post,
  required AttachmentAccess? access,
  required String cachePath,
  required String name,
  FileActionBridge bridge = const FileActionBridge(),
  AppText? text,
}) async {
  final t = text ?? context.t;
  if (post.postId <= 0) return t.chatErrNoServerPost;
  final prop = post.attachments.isEmpty ? null : post.attachments.first;
  if (prop == null) return t.chatErrNoAttachment;
  if (!context.mounted) return t.chatErrPageClosed;

  final outcome = await runWithDownloadDialog(context, (task) async {
    final err = await downloadAttachment(
      api,
      post,
      prop,
      path: cachePath,
      access: access,
      task: task,
      text: t,
    );
    if (err != null) throw DownloadFailedException(err);
  }, filename: name);
  if (outcome == kDownloadCancelled) return null;
  if (outcome != null) return outcome;

  final ok = await bridge.share(
    path: cachePath,
    name: name,
    mime: mimeForFileName(name),
  );
  return ok ? null : t.chatErrNoShareTarget;
}
