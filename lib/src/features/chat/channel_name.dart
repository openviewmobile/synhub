// 频道名 / 标签名的合法性 —— 逐行照抄原版 `ChatUtil`（2.11.1-607）。
//
// ```java
// public static final String INVALID_CHANNEL_NAME_PATTERN =
//     "[~!@{}<>`|?#$%^&*()+\\\[\]'\":;,/=]+";
// public static final String INVALID_HASHTAG_PATTERN = …同上…;
// public static boolean validateChannelName(String n) {
//     return !INVALID_CHANNEL_NAME_REGEX.containsMatchIn(n);
// }
// ```
//
// 三个输入框（`NamedCreateFragment` 新建频道、`ChannelSettingFragment` 改名、
// `PromoteChannelFragment` 会话升级）用的是**同一段判定**：
//
// ```java
// if (name.length() == 0)                         → is_required（"频道名称 不可为空。"）
// else if (!validateChannelName(name) || name.contains(" ")) → error_invalid_name
//                                                 （"不可用空格和特殊字符。"）
// else                                            → 启用 done
// ```
//
// **这里不是纯 UI 偏好**：真机实测（`tool/probe_promote.dart`）给 promote 传一个
// 带空格的名称，服务端直接回 **407 CHAT_ERR_INVALID_RECORD**（"cannot promote"），
// 不带空格的中文名则成功。所以客户端先拦一道，用户看到的是人话而不是服务端错误码。
library;

import '../../core/i18n/l10n.dart';

/// 原版 `ChatUtil.INVALID_CHANNEL_NAME_PATTERN`（`HashtagFragment` 用的是同一条）
const String kInvalidChannelNamePattern =
    r'''[~!@{}<>`|?#$%^&*()+\\\['"\]:;,/=]+''';

final RegExp _invalidName = RegExp(kInvalidChannelNamePattern);

/// 原版 `ChatUtil.validateChannelName`
bool validateChannelName(String name) => !_invalidName.hasMatch(name);

/// 原版 `ChatUtil.validateHashtag`（图案与频道名相同）
bool validateHashtag(String hashtag) => !_invalidName.hasMatch(hashtag);

/// 频道名错误文案；`null` = 合法。文案与原版 `strings.xml` 的 zh-rCN 一致：
/// `is_required` = "%1$s 不可为空。"（频道名称）、`error_invalid_name` = "不可用空格和特殊字符。"
///
/// [text] 是界面语言文案表；缺省 `currentText()`（中文回落，老测试照旧）。
String? channelNameError(String name, [AppText? text]) {
  final t = text ?? currentText();
  if (name.isEmpty) return t.chatNameRequired;
  if (!validateChannelName(name) || name.contains(' ')) {
    return t.chatNameInvalid;
  }
  return null;
}

/// 标签名错误文案；`null` = 合法。
///
/// 原版 `HashtagFragment.afterInputChanged` 与频道名同款判定，只是**空串不报错**
/// （`validateHashtag("")` 为真、也没有空格 → error 置空），所以这里也不报。
String? hashtagError(String hashtag, [AppText? text]) {
  final t = text ?? currentText();
  if (!validateHashtag(hashtag) || hashtag.contains(' ')) {
    return t.chatNameInvalid;
  }
  return null;
}
