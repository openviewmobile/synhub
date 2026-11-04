// 分享链接「发送」（M37）—— 把创建好的公开链接交给外部应用。
//
// 官方 DS file（`ResourceListFragment.java:2095-2098`）的做法是
// `email_link_context` + `Intent.createChooser`，即 **ACTION_SEND 文本**
// （`EXTRA_TEXT` = 链接、`EXTRA_SUBJECT` = 文件名）。
//
// 这一层**优先走原生桥**：复用既有 `MediaOpenBridge` 的既有 channel
// `synhub/media_open`，调 `shareText`（ACTION_SEND + `EXTRA_TEXT`/
// `EXTRA_SUBJECT` + `createChooser`，任意能收 `text/plain` 的 App 都可选）；
// **不新造平台通道**。
//
// 桥不可用时（没挂桥的桌面/纯 Dart、老包、没有任何 App 能接）才回落
// **邮件**（既有 `url_launcher` 的 `mailto:`，本批之前唯一可用的路径）。
// 组合逻辑 [shareLinkWithFallback] 是纯函数，离线用例直接喂假桥/假 mailto。
import 'dart:io';
import 'package:synhub/src/core/platform/app_platform.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/system_open.dart' show isTestEnvironment;

/// 「把链接发出去」的可注入签名（页面只认它；测试换成记录调用的假实现）。
typedef LinkShareRunner =
    Future<bool> Function({required String url, required String subject});

/// 邮件兜底的签名。
typedef MailtoLauncher =
    Future<bool> Function({required String url, required String subject});

const String _mediaOpenChannel = 'synhub/media_open';

/// 原生 ACTION_SEND 文本桥（**既有** `synhub/media_open` 的 `shareText`）。
///
/// `true` = 选择器已拉起；`false` = 没有 App 能接 / 通道不可用 / 参数非法。
class TextShareBridge {
  const TextShareBridge([
    MethodChannel channel = const MethodChannel(_mediaOpenChannel),
  ]) : _channel = channel;

  final MethodChannel _channel;

  /// ★ 第 111 轮：**多附件**分享（官方 DSnote `sendMailText` 的
  /// `ACTION_SEND_MULTIPLE`）。`mailto:` 带不了附件，所以官方在
  /// "笔记有附件"时改走隐式 `SEND_MULTIPLE` 选择器。
  ///
  /// 返回 false = 没有应用能接 / 全部附件都建不出 `content://`。
  Future<bool> shareFiles({
    required List<String> paths,
    String text = '',
    String subject = '',
    String mime = '*/*',
  }) async {
    if (paths.isEmpty) return false;
    if (!capabilityGateAllows(AppCapability.systemShare)) return false;
    try {
      return await _channel.invokeMethod<bool>('shareFiles', {
            'paths': paths,
            'text': text,
            'subject': subject,
            'mime': mime,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// ★ 第 120 轮：把已落盘的文件**保存到系统"下载"目录**。
  ///
  /// 与 `shareFiles`（选择器）不同，这是**落一份到共享存储**：
  /// 用户能在文件管理器里找到它（官方 DSnote 的 "Copy file to download"
  /// 就是这个语义 —— smali 里两条分支：legacy 拷贝 / SAF）。
  /// 返回 false = 平台桥不可用或写失败（**不假装成功**）。
  Future<bool> saveToDownloads({
    required String path,
    required String name,
    String mime = '*/*',
  }) async {
    if (path.isEmpty) return false;
    if (!capabilityGateAllows(AppCapability.mediaStoreExport)) return false;
    try {
      return await _channel.invokeMethod<bool>('saveToDownloads', {
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

  Future<bool> shareText({required String text, required String subject}) async {
    // 空文本不发：桥侧也会判 `bad_args`，先在 Dart 短路（少一次无谓往返）
    if (text.isEmpty) return false;
    if (!capabilityGateAllows(AppCapability.systemShare)) return false;
    try {
      return await _channel.invokeMethod<bool>('shareText', {
            'text': text,
            'subject': subject,
          }) ??
          false;
    } on MissingPluginException {
      // 桌面 / 纯 Dart：没挂桥 → 交给调用方回落
      return false;
    } on PlatformException {
      // 桥自己失败（含 `bad_args`）→ 同样回落
      return false;
    }
  }
}

/// 原生文本分享桥 provider（测试里可覆盖成假桥）。
final textShareBridgeProvider = Provider<TextShareBridge>(
  (ref) => const TextShareBridge(),
);

/// 构造「邮件发送分享链接」的 `mailto:` URI（纯函数，便于离线断言）。
Uri shareLinkMailtoUri({required String url, required String subject}) {
  final params = <String, String>{'body': url};
  if (subject.isNotEmpty) params['subject'] = subject;
  return Uri(scheme: 'mailto', query: _encodeQuery(params));
}

/// `Uri.encodeQueryComponent` 会把空格编成 `+`（form 编码），`mailto:` 的
/// body/subject 里应是 `%20` —— 用 `Uri.encodeComponent` 自己编。
String _encodeQuery(Map<String, String> params) => params.entries
    .map(
      (e) => '${Uri.encodeComponent(e.key)}='
          '${Uri.encodeComponent(e.value)}',
    )
    .join('&');

/// 优先原生 `shareText`，失败/通道不可用再回落邮件（**纯组合逻辑，可测**）。
///
/// * [url] 为空 → `false`，**不碰桥也不碰 mailto**；
/// * 桥返回 `true` → 直接用原生选择器，**不再发邮件**；
/// * 桥返回 `false` → 回落 [mailto]。
Future<bool> shareLinkWithFallback({
  required String url,
  required String subject,
  required TextShareBridge bridge,
  required MailtoLauncher mailto,
}) async {
  if (url.isEmpty) return false;
  if (await bridge.shareText(text: url, subject: subject)) return true;
  return mailto(url: url, subject: subject);
}

/// 默认邮件兜底：用系统默认邮件应用发链接。
///
/// 桌面平台没有 `mailto:` 语义 → 返回 false（调用方提示"没有可用应用"）。
Future<bool> defaultMailtoLauncher({
  required String url,
  required String subject,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) return false;
  try {
    return await launchUrl(
      shareLinkMailtoUri(url: url, subject: subject),
      mode: LaunchMode.externalApplication,
    );
  } catch (e) {
    debugPrint('[files] 分享链接邮件发送失败：$e');
    return false;
  }
}

/// 默认实现：原生 `shareText` → 邮件兜底。
///
/// 测试环境直接返回 true（不启动任何外部应用，与 `defaultSystemOpen` 同一约定）；
/// 需要验证组合逻辑的用例走 [shareLinkWithFallback] + 假桥。
Future<bool> defaultLinkShare({
  required String url,
  required String subject,
}) async {
  if (isTestEnvironment) return true;
  return shareLinkWithFallback(
    url: url,
    subject: subject,
    bridge: const TextShareBridge(),
    mailto: defaultMailtoLauncher,
  );
}

/// 发送分享链接的可注入 provider（默认 [defaultLinkShare]）。
final linkShareProvider = Provider<LinkShareRunner>((ref) => defaultLinkShare);
