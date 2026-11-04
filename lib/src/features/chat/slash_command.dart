// 斜杠命令解析（照抄原版 `SlashUtil`）。
//
// 原版只在**发消息那一刻**判断：正文以 `/jumpchat` 或 `/jitsi` 开头、且频道**未加密**时，
// 不算普通消息，而是走 `SYNO.Chat.Webhook.Slash / execute`
// （`ChannelFragment.onCreatePost` → `ChannelPresenter.createConferenceSlashCommand`）。
//
// 这条命令的机器人在服务端下发（`User.slash_props`，`bot_type = "slash"`），
// 客户端拿 `slash_cmd` 跟正文第一个词比对，`user_id` 就是要传给服务端的那一个。
import '../../data/dto/user_dto.dart';

/// `/jumpchat` 与 `/jitsi` 两个前缀（原版写死，服务端必须有对应的斜杠机器人）
const List<String> kConferenceSlashPrefixes = ['/jumpchat', '/jitsi'];

/// 是不是"起会议"的斜杠命令（原版 `SlashUtil.isConferenceSlashFormat`）
bool isConferenceSlashFormat(String text) {
  if (text.isEmpty || !text.startsWith('/')) return false;
  // 原版是 `startsWith`，不要求后面跟空格（`/jitsiXXX` 也算）
  return kConferenceSlashPrefixes.any(text.startsWith);
}

/// 取出命令名（去掉开头的 `/`，取第一个空白分隔的词）。
/// 原版 `SlashUtil.parseSlashCommandFromMessage`：没有空格分隔时取整段。
String parseSlashCommandFromMessage(String text) {
  if (text.isEmpty || !text.startsWith('/')) return '';
  final first = text.split(' ').first;
  return first.length <= 1 ? '' : first.substring(1);
}

/// 在用户表里找跟这条正文匹配的斜杠机器人（原版按 `slash_cmd` 全等过滤）
UserDto? findSlashBot(List<UserDto> users, String text) {
  final cmd = parseSlashCommandFromMessage(text);
  if (cmd.isEmpty) return null;
  for (final u in users) {
    if (u.isSlashBot && u.slashCmd == cmd) return u;
  }
  return null;
}
