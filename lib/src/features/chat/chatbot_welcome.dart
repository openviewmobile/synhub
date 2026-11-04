// 聊天机器人会话开头的「欢迎语」卡片。
//
// 反编译事实（`ChannelPresenter.java:698 addChatBotWelcomeMessageToList`）：
// 进聊天机器人会话时，客户端**自己造**一条 `type=welcome_message` 的消息塞在列表
// 最前面（`createAt=0`、`state=0`，post_id 都没有），内容取**机器人成员里第一个
// 不是我的人**的 `chatbot_props.welcome_note`；如果那个机器人已被停用/删除，
// 就换成 `R.string.bot_hello_msg_default`（「这是您与 [_SUBST_1_] 之间进行的一对
// 一会话。」，`[_SUBST_1_]` 换成机器人名字）。
//
// 渲染是独立的视图类型（`Post.viewType()==112` → `item_post_welcome_message`）：
// 卡片背景 + 一行加粗的欢迎标题 + 下面 16sp 的正文；标题行右边挂 `synobot_mini`
// 图标（我们没复用它的 drawable，换成 Material 的机器人图标）。
//
// 所以这不是服务端消息类型 —— 别去 `Post/list` 里找 `welcome_message`
// （服务端不会发），是本地补的一条"假消息"。
import '../../core/i18n/l10n.dart';
import '../../data/dto/user_dto.dart';
import 'system_message.dart';

/// 卡片第一行的固定标题。
///
/// ⚠️ 原版这行字是**写死在布局 XML 里**的（`item_post_welcome_message.xml`
/// 的 `android:text="Hello there!"`），所以中文界面上也是英文 —— 照抄。
const String kChatbotWelcomeTitle = 'Hello there!';

/// 机器人被停用/删除时的兜底欢迎语（`bot_hello_msg_default`）。
///
/// [text] 缺省 `currentText()`（中文回落，老测试照旧）。
String botHelloDefaultText(String botName, {AppText? text}) {
  final t = text ?? currentText();
  return t.chatBotWelcomeDefault(
    botName.isEmpty ? t.chatBotFallbackName : botName,
  );
}

/// 这条机器人会话该显示的欢迎语。
///
/// 对齐 `addChatBotWelcomeMessageToList`：停用/删除 → 兜底文案；否则用
/// `welcome_note`（可能是空串，原版就是空着，卡片只剩标题行）。
String chatbotWelcomeText(UserDto bot, {AppText? text}) {
  final t = text ?? currentText();
  if (bot.isDisabled || bot.isDeleted) {
    return botHelloDefaultText(displayUserName(bot, bot.userId, t), text: t);
  }
  return bot.chatbotWelcomeNote;
}

/// 会话里的那个机器人（原版取「频道成员里第一个不是我的人」）。
///
/// 真机上 `channels.members` 经常是 null（见 `docs/phase6-protocol.md`），
/// 所以再退一步：用户表里可见的机器人（机器人会话里只有一个）。
UserDto? chatbotOf(
  String channelType,
  List<int> members,
  Map<int, UserDto> usersById,
  int myUserId,
) {
  if (channelType != 'chatbot') return null;
  for (final id in members) {
    if (id == myUserId) continue;
    final u = usersById[id];
    if (u != null && u.isBot) return u;
  }
  for (final u in usersById.values) {
    if (u.isBot && u.userId != myUserId) return u;
  }
  return null;
}
