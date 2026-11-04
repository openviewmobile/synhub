// 消息正文的富文本解析：@提及 / #话题 / URL。
//
// 反编译结论（Android-SynologyChat 2.10.0 导出）：
//   * mention 的权威信息在 `PostVo.mentions`（用户 id 数组），文本里是 `@名字`。
//   * hashtag 的权威信息在 `PostVo.hashtags`（去掉 `#` 的标签数组）。
//   * emoji：APK 有一张 1787 项的 emojione 表
//     （`data/model/EmojiOne.java`，`:grinning:` → drawable），但**消息里存的
//     是 unicode 本体**，所以这里原样渲染即可；短代码兼容 + 表情面板留到 Phase 6
//     （详见 docs/phase3-protocol.md §8）。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../data/dto/user_dto.dart';
import '../../data/emoji_table.dart';

/// 正文分段
sealed class MessageSegment {
  const MessageSegment();
}

class PlainSegment extends MessageSegment {
  const PlainSegment(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is PlainSegment && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'Plain($text)';
}

class MentionSegment extends MessageSegment {
  const MentionSegment(this.text, this.userId);
  final String text;

  /// 能在 [mentions] 里对上号时填用户 id，否则为 0（纯文本高亮）
  final int userId;

  @override
  bool operator ==(Object other) =>
      other is MentionSegment && other.text == text && other.userId == userId;

  @override
  int get hashCode => Object.hash(text, userId);

  @override
  String toString() => 'Mention($text, $userId)';
}

class HashtagSegment extends MessageSegment {
  const HashtagSegment(this.text, this.tag);

  /// 原文（含 `#`）
  final String text;

  /// 去掉 `#` 的标签
  final String tag;

  @override
  bool operator ==(Object other) =>
      other is HashtagSegment && other.text == text && other.tag == tag;

  @override
  int get hashCode => Object.hash(text, tag);

  @override
  String toString() => 'Hashtag($text)';
}

class UrlSegment extends MessageSegment {
  const UrlSegment(this.url);
  final String url;

  @override
  bool operator ==(Object other) => other is UrlSegment && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'Url($url)';
}

/// URL：`http(s)://` 开头，到空白为止
final _urlRe = RegExp(r'https?://[^\s<>"]+');

/// emojione 短代码（原版 `ChatUtil.showEmojiInTextView` 会把正文里的
/// `:name:` 换成表情图；我们直接用内置 emoji 表换成字符）
final _emojiRe = RegExp(r':([a-zA-Z0-9_+\-]{1,40}):');

/// 服务端会把提及规范化成 `@u:<userId>`（原版 `ChatUtil.getImageMentionSpanStringBuilder`
/// 发出去就是这样，我们本地库收到的也是这个形态）。
///
/// 渲染前要按 `SpannableParser.parseMention` 换回可读名字：
///   * human → `@username`
///   * bot   → `@nickname`
///   * 本地没这个人 → 保持 `@u:<id>` 原文（原版也是不动）
final _uidMentionRe = RegExp(r'@u:(\d+)');

/// id → 显示名（`@u:<id>` 还原用）。规则见 [mentionNamesById]。
String mentionNameOf(UserDto u) {
  if (u.type == 'bot') {
    return u.nickname.isNotEmpty ? u.nickname : u.username;
  }
  return u.username.isNotEmpty ? u.username : u.nickname;
}

/// 用户表 → `@u:<id>` 还原用的 id → 名字表。
Map<int, String> mentionNamesById(Iterable<UserDto> users) => {
  for (final u in users)
    if (mentionNameOf(u).isNotEmpty) u.userId: mentionNameOf(u),
};

/// `@名字` / `#标签`：名字允许 CJK、字母数字、`_ . - +`，遇到空白或标点停
final _atRe = RegExp(r'@[^\s@#<>]{1,64}');
final _hashRe = RegExp(r'#[^\s@#<>]{1,64}');

/// 结尾这些标点不该算进 URL/提及里（`看这个 https://a.com/x).` 之类）
const _trailing = '.,;:!?)]}>\u3002\uff0c\uff01\uff1f\uff09\u300b\u3011"\'`';

String _trimTrailing(String s) {
  var end = s.length;
  while (end > 0 && _trailing.contains(s[end - 1])) {
    end--;
  }
  return s.substring(0, end);
}

/// 把正文切成 纯文本/@提及/#话题/URL 四类片段。
///
/// [mentions] 是 `PostVo.mentions` 里的用户 id（顺序与文本中的 `@` 出现顺序一致），
/// [usernames] 用于把 `@名字` 对上用户 id（对不上就只做高亮，不影响显示）。
List<MessageSegment> parseMessage(
  String text, {
  List<int> mentions = const [],
  Map<String, int> usernames = const {},
  Map<int, String> mentionNames = const {},
}) {
  if (text.isEmpty) return const [];

  final out = <MessageSegment>[];
  final buffer = StringBuffer();
  var mentionIndex = 0;

  void flush() {
    if (buffer.isNotEmpty) {
      out.add(PlainSegment(buffer.toString()));
      buffer.clear();
    }
  }

  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (ch == '@') {
      // 先试 `@u:<id>`（服务端的规范形态）
      final um = _uidMentionRe.matchAsPrefix(text, i);
      final uid = um == null ? null : int.tryParse(um.group(1)!);
      final name = uid == null ? null : mentionNames[uid];
      if (name != null && name.isNotEmpty) {
        flush();
        out.add(MentionSegment('@$name', uid!));
        i += um!.group(0)!.length;
        continue;
      }
    }
    if (ch == '@' || ch == '#') {
      final m = (ch == '@' ? _atRe : _hashRe).matchAsPrefix(text, i);
      if (m != null) {
        final raw = _trimTrailing(m.group(0)!);
        // 只有一个 @ 或 # 不算
        if (raw.length > 1) {
          flush();
          if (ch == '@') {
            final name = raw.substring(1);
            var uid = usernames[name] ?? 0;
            if (uid == 0 && mentionIndex < mentions.length) {
              // 文本顺序 ↔ mentions 数组顺序（原库也是按下标配的）
              uid = mentions[mentionIndex];
            }
            mentionIndex++;
            out.add(MentionSegment(raw, uid));
          } else {
            out.add(HashtagSegment(raw, raw.substring(1)));
          }
          // 被裁掉的尾部标点要补回纯文本
          if (raw.length < m.group(0)!.length) {
            buffer.write(m.group(0)!.substring(raw.length));
          }
          i += m.group(0)!.length;
          continue;
        }
      }
    } else if (ch == ':') {
      final m = _emojiRe.matchAsPrefix(text, i);
      final ch2 = m == null ? null : kEmojiShortcodes[m.group(1)!];
      if (m != null && ch2 != null) {
        flush();
        buffer.write(ch2);
        i += m.group(0)!.length;
        continue;
      }
    } else if (ch == 'h' || ch == 'H') {
      final m = _urlRe.matchAsPrefix(text, i);
      if (m != null) {
        final raw = _trimTrailing(m.group(0)!);
        if (raw.length > 8) {
          flush();
          out.add(UrlSegment(raw));
          if (raw.length < m.group(0)!.length) {
            buffer.write(m.group(0)!.substring(raw.length));
          }
          i += m.group(0)!.length;
          continue;
        }
      }
    }
    buffer.write(ch);
    i++;
  }
  flush();
  return out;
}

/// 渲染一条消息的正文。点击 @提及 / #话题 / URL 走各自回调。
class MessageText extends StatefulWidget {
  const MessageText(
    this.text, {
    super.key,
    this.mentions = const [],
    this.usernames = const {},
    this.mentionNames = const {},
    this.style,
    this.onMention,
    this.onHashtag,
    this.onUrl,
  });

  final String text;
  final List<int> mentions;
  final Map<String, int> usernames;

  /// `@u:<id>` → 显示名（见 [mentionNamesById]）
  final Map<int, String> mentionNames;
  final TextStyle? style;
  final void Function(int userId, String name)? onMention;
  final void Function(String tag)? onHashtag;
  final void Function(String url)? onUrl;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _tap(void Function() fn) {
    final r = TapGestureRecognizer()..onTap = fn;
    _recognizers.add(r);
    return r;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final segments = parseMessage(
      widget.text,
      mentions: widget.mentions,
      usernames: widget.usernames,
      mentionNames: widget.mentionNames,
    );

    final spans = <InlineSpan>[];
    for (final seg in segments) {
      switch (seg) {
        case PlainSegment(:final text):
          spans.add(TextSpan(text: text));
        case MentionSegment(:final text, :final userId):
          final hasCallback = widget.onMention != null;
          final uid = userId;
          spans.add(
            TextSpan(
              text: text,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
                backgroundColor: theme.colorScheme.primary.withValues(
                  alpha: .10,
                ),
              ),
              recognizer: hasCallback
                  ? _tap(() => widget.onMention!(uid, text.substring(1)))
                  : null,
            ),
          );
        case HashtagSegment(:final text, :final tag):
          spans.add(
            TextSpan(
              text: text,
              style: TextStyle(
                color: theme.colorScheme.tertiary,
                fontWeight: FontWeight.w600,
              ),
              recognizer: widget.onHashtag == null
                  ? null
                  : _tap(() => widget.onHashtag!(tag)),
            ),
          );
        case UrlSegment(:final url):
          spans.add(
            TextSpan(
              text: url,
              style: TextStyle(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: theme.colorScheme.primary,
              ),
              recognizer: widget.onUrl == null
                  ? null
                  : _tap(() => widget.onUrl!(url)),
            ),
          );
      }
    }

    return Text.rich(
      TextSpan(style: widget.style, children: spans),
      softWrap: true,
    );
  }
}
