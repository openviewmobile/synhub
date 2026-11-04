// 音频/视频附件的"外部串流播放"（对齐原版 `VideoUtil` + `FileUtil`）。
//
// 反编译结论（Android-SynologyChat 2.11.1）：
//   * `FileUtil.isStreaming(name)`：扩展名对应的 MIME 含 `audio` 或 `video`，
//     或者文件名以 `rm`/`rmvb` 结尾 → 走串流分支（**音频也算**）。
//   * `VideoUtil.openStreaming(context, am, postId, name)`：
//     `Uri = getStreamingUrlOfPostId(postId)`（= `webapi/{Post.File.path}` +
//     `api=SYNO.Chat.Post.File&method=get&version=1&post_id=X&_sid=<cookie id>`），
//     然后 `Intent(ACTION_VIEW).setDataAndType(uri, mimeFromExtension(name))`。
//     ⚠️ **必须带 type**，否则 `.mp4` 会被浏览器接走；所以这里不能只用
//     `url_launcher`，Android 侧自己开 channel 发带 MIME 的 Intent。
//   * 没有应用能处理该 MIME → `FileUtil.showMimeTypeDialog`（"打开方式"：
//     text/* / audio/* / video/* / image/*，再回落到 `*/*`）。
//   * 三种情况**不串流、改为下载**（各自有一次性的确认框，偏好键
//     `video_encrypted` / `video_illegal_certificate`）：
//       1. 加密频道（外部播放器拿不到密钥）；
//       2. 服务器证书不受系统信任（外部播放器不认我们的固定指纹）；
//       3. 这份文件已经完整下载在缓存里（`VideoUtil.ExistInDownloadCache`）。
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../core/i18n/l10n.dart';
import '../../core/platform/app_platform.dart';
import '../../core/system_open.dart';

/// 扩展名 → MIME（Android `MimeTypeMap` 的常用子集；`isStreamingFile` 只关心
/// audio/video，其余用来给"打开方式"和 multipart 用）
const Map<String, String> kMimeByExtension = {
  // 视频
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'mov': 'video/quicktime',
  'avi': 'video/x-msvideo',
  'wmv': 'video/x-ms-wmv',
  'flv': 'video/x-flv',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  '3gp': 'video/3gpp',
  'mpg': 'video/mpeg',
  'mpeg': 'video/mpeg',
  'ts': 'video/mp2t',
  'rm': 'application/vnd.rn-realmedia',
  'rmvb': 'application/vnd.rn-realmedia-vbr',
  // 音频
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/x-wav',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'opus': 'audio/opus',
  'flac': 'audio/flac',
  'amr': 'audio/amr',
  'wma': 'audio/x-ms-wma',
  'mid': 'audio/midi',
  // 图片
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'svg': 'image/svg+xml',
  // 文本 / 文档
  'txt': 'text/plain',
  'log': 'text/plain',
  'csv': 'text/csv',
  'json': 'application/json',
  'xml': 'text/xml',
  'html': 'text/html',
  'htm': 'text/html',
  'md': 'text/markdown',
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'zip': 'application/zip',
  'rar': 'application/x-rar-compressed',
  '7z': 'application/x-7z-compressed',
  'gz': 'application/gzip',
  'apk': 'application/vnd.android.package-archive',
};

/// 取扩展名（小写，不带点）；没有扩展名返回空串
String fileExtensionOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return '';
  return name.substring(i + 1).toLowerCase();
}

/// 文件名的 MIME（认不出来给 `application/octet-stream`，和原版
/// `mimeTypeFromExtension == null` 时的兜底语义一致）
String mimeForFileName(String name) =>
    kMimeByExtension[fileExtensionOf(name)] ?? 'application/octet-stream';

/// 认不出来的扩展名返回 null（原版 `getMimeType` 就是 null）
String? mimeOrNullForFileName(String name) =>
    kMimeByExtension[fileExtensionOf(name)];

/// 原版 `FileUtil.isStreaming`：MIME 含 audio/video，或 rm/rmvb 结尾
bool isStreamingFile(String name) {
  final lower = name.toLowerCase();
  final mime = mimeOrNullForFileName(lower);
  if (mime != null && (mime.contains('audio') || mime.contains('video'))) {
    return true;
  }
  return lower.endsWith('rm') || lower.endsWith('rmvb');
}

/// "把 URL 交给外部应用"这一步做成可注入的（测试里换成假的）。
/// 返回 true = 已交给某个应用；false = 没有应用能处理这个 MIME。
typedef MediaStreamOpener = Future<bool> Function(String url, String mime);

const MethodChannel _channel = MethodChannel('synhub/media_open');

/// Android：带 MIME 的 `ACTION_VIEW`（原生 `MediaOpenBridge`）。
/// 其他平台（桌面/测试）退回 `url_launcher` 的外部打开。
Future<bool> defaultMediaStreamOpener(String url, String mime) async {
  // 第 79 轮：`Platform.isAndroid` → 能力门（同 `core/system_open.dart` 的迁移）。
  if (capabilityGateAllows(AppCapability.systemOpen)) {
    try {
      final ok = await _channel.invokeMethod<bool>('view', {
        'url': url,
        'mime': mime,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // 单测/未挂桥的环境：退回 url_launcher
      return _launchExternally(url);
    }
  }
  return _launchExternally(url);
}

Future<bool> _launchExternally(String url) async {
  // 测试环境不启动任何外部应用（mac 上会把假媒体交给 QuickTime；见
  // `core/system_open.dart` 的说明）
  if (isTestEnvironment) return false;
  try {
    return await launcher.launchUrl(
      Uri.parse(url),
      mode: launcher.LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}

/// 原版 `FileUtil.showMimeTypeDialog` 的候选项（顺序一致）。
///
/// [text] 缺省用中文（[currentText]），界面调用处传 `context.t`。
List<(String, String)> openAsChoices([AppText? text]) {
  final t = text ?? currentText();
  return [
    ('text/*', t.chatOpenAsText),
    ('audio/*', t.chatMediaAudio),
    ('video/*', t.photoVideo),
    ('image/*', t.chatMediaImage),
  ];
}
