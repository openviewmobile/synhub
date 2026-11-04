// ★★★ ④笔记 **J9「把笔记分享出去（系统 ACTION_SEND）」** —— 第 235 轮。
//
// 官方 Note Station 的"分享"能把**笔记正文**交给系统分享面板（
// 原版 `NoteFragment` 的分享：`ACTION_SEND` + `EXTRA_SUBJECT` / `EXTRA_TEXT`）。
// 我方此前只有**入站**（`note_share_clip.dart` = 从别的 App 剪藏进来）
// 和**附件**分享（`note_attachment_actions.dart` 走 `shareFiles`），
// **正文出去**这一支没有 ⇒ 台账 J9 一直挂 🟠。
//
// 本文件补上：
//   * [noteShareSubject] / [noteShareBody]：**纯函数**构造分享载荷
//     （正文过长按**行边界**截断并加省略号，绝不把半个字/半行甩出去）；
//   * [NoteShareOutBridge]：通道 `synhub/share_text`，
//     方法 `shareText {subject, text}` → 原生 `Intent.ACTION_SEND` + chooser；
//   * [shareNoteOut]：组装 + 调用（可注入 bridge 便于离线断言）。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform/app_platform.dart';

/// 分享通道名（Kotlin `ShareTextBridge.CHANNEL`）
const String kNoteShareOutChannel = 'synhub/share_text';

/// 分享正文上限（字符）。官方正文可以很长，系统分享面板对超长文本不友好，
/// 这里按**行边界**截断。
const int kNoteShareBodyMaxChars = 2000;

/// 分享标题：优先用笔记标题；空标题用官方兜底文案。
String noteShareSubject({required String title}) {
  final t = title.trim();
  return t.isEmpty ? 'Synology Note' : t;
}

/// 分享正文：正文为空时用空串（**不编造内容**）；
/// 超过 [kNoteShareBodyMaxChars] 时在**行边界**截断并加 `…`。
String noteShareBody({required String body, int maxChars = kNoteShareBodyMaxChars}) {
  final b = body.replaceAll('\r\n', '\n');
  if (b.length <= maxChars) return b;
  final head = b.substring(0, maxChars);
  final cut = head.lastIndexOf('\n');
  final kept = (cut > maxChars ~/ 2 ? head.substring(0, cut) : head);
  return '$kept…';
}

abstract class NoteShareOutBridge {
  Future<bool> shareText({required String subject, required String text});
}

class MethodChannelNoteShareOutBridge implements NoteShareOutBridge {
  const MethodChannelNoteShareOutBridge();

  static const MethodChannel _channel = MethodChannel(kNoteShareOutChannel);

  @override
  Future<bool> shareText({
    required String subject,
    required String text,
  }) async {
    // ★ 第 55 轮：`synhub/share_text` 是 Android `ACTION_SEND` chooser 的桥，
    //   宿主上能力层报 `unavailable:not-implemented-on-host` ⇒ 不碰通道，
    //   如实回 false（调用方按"没分享出去"处理），原因进日志。
    if (!capabilityGateAllows(AppCapability.systemShare)) {
      debugPrint(
        capabilityGateLog(AppCapability.systemShare, 'share_text.shareText'),
      );
      return false;
    }
    return await _channel.invokeMethod<bool>('shareText', {
          'subject': subject,
          'text': text,
        }) ??
        false;
  }
}

class RecordingNoteShareOutBridge implements NoteShareOutBridge {
  final calls = <({String subject, String text})>[];
  bool result = true;

  @override
  Future<bool> shareText({
    required String subject,
    required String text,
  }) async {
    calls.add((subject: subject, text: text));
    return result;
  }
}

/// 把一条笔记交给系统分享面板。返回原生是否成功接管（false = 没装任何可接收的 App / 通道不可用）。
Future<bool> shareNoteOut({
  required String title,
  required String body,
  NoteShareOutBridge? bridge,
}) async {
  final b = bridge ?? const MethodChannelNoteShareOutBridge();
  try {
    return await b.shareText(
      subject: noteShareSubject(title: title),
      text: noteShareBody(body: body),
    );
  } catch (_) {
    // 通道不可用（桌面/测试/旧包）⇒ 如实 false，不假装分享成功
    return false;
  }
}
