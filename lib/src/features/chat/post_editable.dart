// 「这条消息能不能编辑 / 我订阅了这个话题吗」—— 逐行翻译原版
// `util/PostUtil.java`（Kotlin 反编译产物），因为它把三套历史规则叠在一起：
//
//   isPostEditable(post, editablePostId, channel):
//     if 服务器支持 SYNO.Chat.Admin.Setting v4（"可编辑任意消息"）:
//         if post.user != 我 || !allow_edit_message → false
//         if 窗口 <= 0（-1 不限） || now - post.createAt <= 窗口
//              → legacy(post, editablePostId, ignoreEditablePostId = true)
//         else → false
//     else → legacy(post, editablePostId, ignoreEditablePostId = false)
//
//   legacy(post, editablePostId, ignore):
//     if post.isVote → false
//     if !allowEncryption && channel.encrypted → false
//     if (chatbot || 匿名会话) && 所有对方都停用了 → false
//     return ignore || post.postId == editablePostId
//
// 老服务器（不支持 v4）**只有一条**消息能编辑：`Post/list_editable` 返回的那条
// （`editablePostId`）；新服务器上这个值被忽略。
import '../../data/dto/channel_dto.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/server_settings_dto.dart';

/// 一分钟多少毫秒（原版 `PostUtil.MILLISECONDS_PER_MINUTE`）
const int kMsPerMinute = 60000;

/// `PostUtil.isSubscribedPost(channel, threadId)` —— `subscribes` 里存的是话题 id
bool isSubscribedPost(ChannelDto? channel, int threadId) =>
    channel != null && threadId > 0 && channel.subscribes.contains(threadId);

/// `PostUtil.isPostEditable(...)`
///
/// [editablePostId] 来自 `Post/list_editable`（老服务器才用得上）。
/// [allUsersDisabled] 对应原版 `ChannelUtil.isAllUserDisable(channel, prefs)`：
/// 匿名会话/机器人频道里对方全把我停用了就不能编辑。
bool isPostEditable(
  PostDto post,
  ChannelDto channel, {
  required int myUserId,
  required ServerSettings settings,
  bool supportsEditAllPost = true,
  int editablePostId = 0,
  bool allUsersDisabled = false,
  int? nowMs,
}) {
  if (supportsEditAllPost) {
    if (post.creatorId != myUserId || !settings.allowEditMessage) return false;
    final window = settings.editWindowMs;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (window > 0 && now - post.createAt > window) return false;
    return _legacy(
      post,
      editablePostId: editablePostId,
      ignoreEditablePostId: true,
      channel: channel,
      settings: settings,
      allUsersDisabled: allUsersDisabled,
    );
  }
  return _legacy(
    post,
    editablePostId: editablePostId,
    ignoreEditablePostId: false,
    channel: channel,
    settings: settings,
    allUsersDisabled: allUsersDisabled,
  );
}

bool _legacy(
  PostDto post, {
  required int editablePostId,
  required bool ignoreEditablePostId,
  required ChannelDto channel,
  required ServerSettings settings,
  required bool allUsersDisabled,
}) {
  if (post.vote != null) return false;
  if (!settings.allowEncryption && channel.encrypted) return false;
  if ((channel.isConversation || channel.isChatBotType) && allUsersDisabled) {
    return false;
  }
  return ignoreEditablePostId || post.postId == editablePostId;
}

/// `ChannelUtil.isAllUserDisable`：匿名会话 / 机器人频道里，除了我以外的成员
/// 是不是全都停用了（原版查 `channel.users()` 的 disabled 标记）。
///
/// [channel] 的 `members` 只有 user id，所以停用状态由调用方从用户表带进来。
bool isAllOtherUsersDisabled(
  ChannelDto channel,
  int myUserId, {
  required bool Function(int userId) isDisabled,
}) {
  final others = channel.members.where((u) => u != myUserId).toList();
  if (others.isEmpty) return true;
  return others.every(isDisabled);
}
