// 正文里的提及编码。
//
// 原版 `ChatUtil.getImageMentionSpanStringBuilder`：输入框里的提及是**图片 chip**，
// 发出前会按服务端能力决定用哪种写法：
//
//   * `isNeedParseUid = ApiManager.support(SYNO.Chat.Post, 4) && !channel.encrypted()`
//     （`ChannelFragment.onCreatePost`）为真 → 写成 **`@u:<userId>`**（id 稳定，
//      改昵称/同名也不会错）；
//   * 为假（老服务端或加密频道）→ 保持 `@<username>` 原文。
//   * `@here` / `@channel` **永远保持原样**（它们是伪用户，服务端自己认）。
//
// 我们本地存的是明文 `@username`（与原版 chip 里的 `"@" + user.username()` 一致），
// 只在**发给服务端那一刻**换一次。
import '../../data/dto/user_dto.dart';

/// 名字里不该出现的标点（`@demo,` 要能识别出 `demo`；`@demo.com` 只认 `demo`）
const _punctuation = '.,!?;:，。！？；：、）)】」』"\'‘’“”';

bool _isDelimiter(String c) => c == ' ' || c == '\n' || c == '\t';

/// 把 `@username` 换成 `@u:<id>`；`@here` / `@channel` 与认不出的 `@xxx` 原样保留。
///
/// [byUsername] 是 username → userId（原版 chip 里存的就是 username）。
String encodeMentions(String text, {required Map<String, int> byUsername}) {
  if (text.isEmpty || !text.contains('@') || byUsername.isEmpty) return text;
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c != '@') {
      out.write(c);
      i++;
      continue;
    }
    // `@` 必须在词首：`a@demo.com` 这种邮箱不碰
    // （原版提及是 chip，压根不会被误伤；我们按文本匹配就得自己防一手）
    if (i > 0 && !_isDelimiter(text[i - 1])) {
      out.write(c);
      i++;
      continue;
    }
    // 名字 = `@` 后面第一段"非分隔符、非标点"的字符
    var j = i + 1;
    while (j < text.length &&
        !_isDelimiter(text[j]) &&
        !_punctuation.contains(text[j])) {
      j++;
    }
    final name = text.substring(i + 1, j);
    final id = byUsername[name];
    // `here` / `channel` 是伪用户，保持原样（原版也是这么分支的）
    if (id == null || name == 'here' || name == 'channel') {
      out.write(c);
      i++;
    } else {
      out.write('@u:$id');
      i = j;
    }
  }
  return out.toString();
}

/// 把用户表变成 `username → userId`（`@` 提及编码用）。
Map<String, int> mentionIdByUsername(List<UserDto> users) => {
  for (final u in users)
    if (u.username.isNotEmpty) u.username: u.userId,
};
