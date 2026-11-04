// J7「发送到邮件」—— 把一条笔记交给系统邮件应用。
//
// ## 官方证据（DSnote 1.12.0 反编译源码，`com/synology/dsnote/fragments/NoteFragment.java`）
//
// 官方笔记视图的 `menu_note` 里有一项 `email`，对应两段代码：
//
// ```java
// // 无附件 / 无行内图片时（prepareMailContent 的 else 分支 → GET_MAIL_HTML）
// private void sendMailHTML(String html) {
//     Intent intent = new Intent("android.intent.action.SENDTO", Uri.parse(MailTo.MAILTO_SCHEME));
//     intent.putExtra("android.intent.extra.SUBJECT", this.mTitle);
//     intent.putExtra("android.intent.extra.TEXT", Html.fromHtml(html));
//     startActivity(Intent.createChooser(intent, getString(R.string.email_note)));
// }
//
// // 有行内图片引用（`mRefs`）或用户勾了要下载的附件时 → GET_MAIL_TEXT
// private void sendMailText(String text, List<String> attachments) {
//     Intent intent = new Intent("android.intent.action.SEND_MULTIPLE");
//     intent.setType("*/*");
//     intent.putExtra("android.intent.extra.SUBJECT", this.mTitle);
//     intent.putExtra("android.intent.extra.TEXT", text);
//     // EXTRA_STREAM = 行内图 + 附件（FileProvider uri），再 createChooser
// }
// ```
//
// 两条路径的**选择器标题**都是 `R.string.email_note` = **"Email note"**
// （`aapt2 dump resources /tmp/DSnote.apk` 实测）。`MailTo.MAILTO_SCHEME` 就是
// `"mailto:"`，即无附件这条主路径是 **`ACTION_SENDTO` + `mailto:`**，主题 = 笔记
// 标题、正文 = 笔记 HTML 经 WebView 转出的**纯文本**（`GET_MAIL_HTML` 那条反而把
// HTML 转成 `Spanned` 塞进 `EXTRA_TEXT`）。
//
// ## 我方落地与边界
//
// * **主路径逐字对齐**：`ACTION_SENDTO` + `mailto:`（主题 = 标题、正文 = 纯文本）。
// * 邮件客户端不可用（`launchUrl` 返回 false / 抛异常）时回落**原生
//   `ACTION_SEND` 文本**（复用既有 `synhub/media_open` 的 `shareText`，
//   与文件模块 M37 的 `file_link_share.dart` 同一套路数），保证笔记仍发得出去。
// * 官方「有附件 → `ACTION_SEND_MULTIPLE` + 多个 FileProvider uri」这一支**当前
//   未实现**：现有原生桥只有单文件 `share`，多文件分享要动 `android/**`
//   （本批不可改）。已如实记入 `docs/chat-note-gaps-implementation-report.md`。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/data_text.dart';
import '../../core/system_open.dart' show isTestEnvironment;
import '../files/file_link_share.dart' show TextShareBridge;

/// 本批新增的 ARB key（模板 `lib/l10n/app_zh.arb`，append-only）。
abstract final class NoteMailTextKeys {
  /// 「发送到邮件」（官方 `menu_note` `email`）
  static const sendToEmail = 'noteMailSendToEmail';

  /// ★ r349（D72）：把**正文**交给**系统分享面板**（`ACTION_SEND`）的那个出口。
  ///   它与上面那条**不是同一件事**（一个走 `mailto:`、一个走系统分享），
  ///   但曾经**共用 `sendToEmail` 这一个 key** ⇒ 装上翻译后两条 tooltip
  ///   都变成「发送到邮件」，⋮ 菜单里出现**两条同名项**（真机实测）。
  static const shareOut = 'noteMailShareOut';

  /// 没有任何邮件/分享应用可用的提示
  static const mailUnavailable = 'noteMailUnavailable';
}

/// 取本批文案（key + 中文原文；装了翻译器出译文，否则回落中文）
String noteMailText(String key, String zh) => dataText(key, zh);

/// 「发送到邮件」的可注入签名（页面只认它；测试换成记录调用的假实现）。
///
/// [attachments] = **本地文件路径**（笔记附件下载后的落点）。官方
/// `NoteFragment.prepareMailContent` 按"有没有附件"分流：
/// 无附件 → `sendMailHTML`（`ACTION_SENDTO` + `mailto:`，HTML 正文）；
/// 有附件 → `sendMailText`（`ACTION_SEND_MULTIPLE` + 多个 FileProvider uri）。
typedef NoteMailRunner = Future<bool> Function({
  required String subject,
  required String body,
  List<String> attachments,
});

/// 「发送到邮件」走哪条通道 —— 官方两条支路的**纯决策**（第 111 轮）。
enum NoteMailTransport {
  /// 无附件：`mailto:`（官方 `sendMailHTML`）。
  mailto,

  /// 有附件：`ACTION_SEND_MULTIPLE`（官方 `sendMailText`）——
  /// `mailto:` 本体**带不了附件**，必须走隐式意图 + FileProvider。
  attachments,
}

/// 纯函数：按附件数量选通道（便于离线断言官方分流规则）。
NoteMailTransport noteMailTransportFor(List<String> attachments) =>
    attachments.isEmpty ? NoteMailTransport.mailto : NoteMailTransport.attachments;

/// `Uri.encodeQueryComponent` 把空格编成 `+`（form 编码），`mailto:` 的
/// subject/body 里应是 `%20` —— 自己编（与 `file_link_share.dart` 同一处理）。
String _encodePair(String key, String value) =>
    '${Uri.encodeComponent(key)}=${Uri.encodeComponent(value)}';

/// 构造「把笔记发到邮件」的 `mailto:` URI（纯函数，便于离线断言）。
///
/// * 无收件人：官方 `MAILTO_SCHEME` 就是空收件人的 `mailto:`，由用户在邮件应用里填；
/// * `subject` / `body` 为空时**不写该参数**（空串参数会让个别邮件客户端出现
///   「主题:」空行）；
/// * 两者都空 → 裸 `mailto:`（仍然拉起邮件应用，与官方 `createChooser` 同效）。
Uri noteMailUri({required String subject, required String body}) {
  final parts = <String>[];
  if (subject.isNotEmpty) parts.add(_encodePair('subject', subject));
  if (body.isNotEmpty) parts.add(_encodePair('body', body));
  return Uri(scheme: 'mailto', query: parts.isEmpty ? null : parts.join('&'));
}

/// 默认实现：`ACTION_SENDTO` + `mailto:`（官方主路径），失败回落原生分享文本。
///
/// 测试环境直接返回 true（不拉起任何外部应用，与 `defaultLinkShare` 同一约定）。
Future<bool> defaultNoteMail({
  required String subject,
  required String body,
  List<String> attachments = const [],
}) =>
    const NoteMailSender()(
      subject: subject,
      body: body,
      attachments: attachments,
    );

/// 「发送到邮件」的实现（可注入桥 + 可关测试闸门，便于单测两条支路）。
class NoteMailSender {
  const NoteMailSender({
    TextShareBridge bridge = const TextShareBridge(),
    this.platformTouching,
  }) : _bridge = bridge;

  final TextShareBridge _bridge;

  /// null = 按 [isTestEnvironment] 判定；测试里显式给 true 才真走桥。
  final bool? platformTouching;

  Future<bool> call({
    required String subject,
    required String body,
    List<String> attachments = const [],
  }) async {
    final touchPlatform = platformTouching ?? !isTestEnvironment;
    // 有附件 → 官方 sendMailText（SEND_MULTIPLE + FileProvider）
    if (noteMailTransportFor(attachments) == NoteMailTransport.attachments) {
      if (!touchPlatform) return true;
      final ok = await _bridge.shareFiles(
        paths: attachments,
        text: body,
        subject: subject,
      );
      if (ok) return true;
      // 附件全建不出 content:// / 没有应用能接 ⇒ 退回纯文本，
      // 别把笔记堵死在 App 里（官方没有这条回落，属我方加固）
    }
    if (!touchPlatform) return true;
    if (await _launchMailto(noteMailUri(subject: subject, body: body))) {
      return true;
    }
    // 邮件客户端缺失：退回系统分享面板（任意能收文本的 App），别把笔记堵在 App 里
    return _bridge.shareText(text: body, subject: subject);
  }
}

Future<bool> _launchMailto(Uri uri) async {
  if (!Platform.isAndroid && !Platform.isIOS) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('[notes] mailto 拉起失败：$e');
    return false;
  }
}

/// 发送到邮件的可注入 provider（默认 [defaultNoteMail]）。
final noteMailProvider = Provider<NoteMailRunner>((ref) => defaultNoteMail);
