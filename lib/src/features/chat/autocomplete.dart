// 输入框联想（`@` 提及 / `#` 标签 / `/` 斜杠命令）。
//
// 逐条对位原版：
//   * 分词：`MsgMultiAutoCompleteTextView.SpaceTokenizer` —— 词以**空格/换行**分隔，
//     `terminateToken` 补一个空格；
//   * 过滤：`AutoCompleteFilter.filter(str)` —— `str` 是当前那个词，
//     `lower = str.substring(1).toLowerCase()`，然后
//       `#` → 标签文本 `contains(lower)`
//       `@` → 用户 username **或** nickname `contains(lower)`
//       `/` → 斜杠命令 cmd `contains(lower)`，但 `slashDisabled` 时整个不提示
//   * `slashDisabled`：`ChannelFragment` 里是
//     `setSlashCommandDisable((string.isEmpty() || string.lastIndexOf("/") == 0) ? false : true)`
//     —— 也就是"/"只能出现在整条消息的开头（正文里再打一个 `/` 就不再提示）。
//   * `@` 候选列表：`CreatePostPresenter.init` = `observeHumans()`（全部真人），
//     频道成员排前面（`ChatUtil.moveChannelMemberForward`），
//     非加密频道（且不是"两人会话/chatbot"）再在最前面插 `@channel`(-2) 与 `@here`(-1)
//     （`ChatUtil.atMention`）。
import '../../core/i18n/l10n.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/user_dto.dart';

/// 词的分隔符：只认空格与换行（原版 `SpaceTokenizer.delimiters`）
bool _isDelimiter(String c) => c == ' ' || c == '\n';

/// 取光标所在的那个词（从光标往前找到分隔符为止）。
String currentWord(String text, int cursor) {
  if (text.isEmpty) return '';
  var end = cursor.clamp(0, text.length);
  var start = end;
  while (start > 0 && !_isDelimiter(text[start - 1])) {
    start--;
  }
  while (end < text.length && !_isDelimiter(text[end])) {
    end++;
  }
  return text.substring(start, end);
}

/// `/` 联想是否被禁用（原版 `ChannelFragment` 里的 `setSlashCommandDisable`）。
bool slashAutocompleteDisabled(String text) =>
    text.isNotEmpty && text.lastIndexOf('/') != 0;

/// 联想的候选项。
sealed class AutocompleteItem {
  const AutocompleteItem();

  /// 点下去要插进输入框的文本（原版 `terminateToken` 会补一个空格）
  String get insertText;

  /// 候选列表里显示的一行字（原版 `AutocompleteAdapter.getView`）
  String get label;
}

/// `@` 提及目标：真人，或 `@channel` / `@here`
class MentionTarget extends AutocompleteItem {
  const MentionTarget({
    required this.userId,
    required this.username,
    this.user,
  });

  final int userId;

  /// 插进正文的就是 `@username`（原版 chip 里存 `user.username()`）
  final String username;
  final UserDto? user;

  /// `@channel`(-2) / `@here`(-1) 是原版的伪用户
  bool get isSpecial => userId == -1 || userId == -2;

  /// `@channel` / `@here` 的一行说明（原版 `at_channel` / `at_here`）。
  ///
  /// 界面按语言取文案；[description] 只是中文回落（无 delegate 的老测试仍走它）。
  String descriptionIn(AppText text) => switch (username) {
    'channel' when isSpecial => text.chatMentionChannelDesc,
    'here' when isSpecial => text.chatMentionHereDesc,
    _ => '',
  };

  String get description => descriptionIn(currentText());

  @override
  String get label {
    if (isSpecial) return '@$username';
    final nick = user?.nickname ?? '';
    return nick.isEmpty ? '@$username' : '@$username ($nick)';
  }

  @override
  String get insertText => '@$username ';
}

/// `#` 标签
class HashtagTarget extends AutocompleteItem {
  const HashtagTarget(this.tag);

  final String tag;

  @override
  String get label => '#$tag';

  @override
  String get insertText => '#$tag ';
}

/// `/` 斜杠命令
class SlashTarget extends AutocompleteItem {
  const SlashTarget(this.bot);

  final UserDto bot;

  @override
  String get label => '/${bot.slashCmd}';

  @override
  String get insertText => '/${bot.slashCmd} ';
}

/// `@` 候选：全部真人（成员在前）+ 非加密频道的 `@channel`/`@here`。
///
/// 对位 `ChatUtil.atMention` + `ChatUtil.moveChannelMemberForward`。
List<MentionTarget> mentionCandidates({
  required List<UserDto> users,
  ChannelDto? channel,
}) {
  final members = channel?.members ?? const <int>[];
  final memberIds = members.toSet();
  final sorted = [
    for (final u in users)
      if (memberIds.contains(u.userId)) u,
    for (final u in users)
      if (!memberIds.contains(u.userId)) u,
  ];
  final out = <MentionTarget>[
    for (final u in sorted)
      MentionTarget(userId: u.userId, username: u.username, user: u),
  ];
  // 加密频道不给 @channel/@here；两人会话/chatbot 也不给
  if (channel == null || channel.encrypted) return out;
  final small =
      (channel.isConversation || channel.isChatBotType) && members.length <= 2;
  if (small) return out;
  out.insert(0, const MentionTarget(userId: -2, username: 'channel'));
  out.insert(1, const MentionTarget(userId: -1, username: 'here'));
  return out;
}

/// 按原版 `AutoCompleteFilter.filter` 过滤。
///
/// [word] 是当前那个词（含开头的触发字符）。空词返回空（原版
/// `if (charSequence.isEmpty()) return empty`）。
List<AutocompleteItem> filterAutocomplete({
  required String word,
  required String fullText,
  required List<UserDto> slashCommands,
  required List<String> hashtags,
  required List<MentionTarget> mentions,
}) {
  if (word.isEmpty) return const [];
  final lower = word.substring(1).toLowerCase();
  if (word.startsWith('#')) {
    return [
      for (final t in hashtags)
        if (t.toLowerCase().contains(lower)) HashtagTarget(t),
    ];
  }
  if (word.startsWith('@')) {
    return [
      for (final m in mentions)
        if ((m.username.isNotEmpty &&
                m.username.toLowerCase().contains(lower)) ||
            ((m.user?.nickname ?? '').isNotEmpty &&
                m.user!.nickname.toLowerCase().contains(lower)))
          m,
    ];
  }
  if (word.startsWith('/') && !slashAutocompleteDisabled(fullText)) {
    return [
      for (final b in slashCommands)
        if (b.slashCmd.toLowerCase().contains(lower)) SlashTarget(b),
    ];
  }
  return const [];
}
