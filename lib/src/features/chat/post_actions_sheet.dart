// 消息长按操作面板（对齐原 App 的长按 ActionSheet）。
//
// 动作清单与 `ActionSheetConfiguration.java` 一致：
//   回复话题 / 表情回应 / 星标 / 置顶 / 转发 / 编辑 / 复制 / 删除
// 是否可用取决于：是不是自己发的（编辑/删除）、有没有实时连接（写操作）、
// 频道是否加密（加密消息的正文操作 Phase 7 再放开）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/ui/app_sheet.dart';
import '../../core/ui/glass_pane.dart';
import '../../data/dto/post_dto.dart';
import '../../data/emoji_table.dart';
import 'emoji_picker_sheet.dart';

/// 短代码 → emoji 字符；表里没有就原样返回（可能是自定义贴纸名）
String emojiForName(String name) => kEmojiShortcodes[name] ?? name;

/// 用户在面板上选了什么
enum PostAction {
  replyThread,
  react,
  star,
  unstar,
  pin,
  unpin,
  stick,
  unstick,
  forward,
  reminder,
  clearReminder,
  addHashtag,
  removeHashtag,
  edit,
  copy,
  download,
  delete,
  readUsers,
  unreadUsers,
}

/// 「未发出去的消息」面板上选了什么（原版 `temp_operation` 三项）
enum TempPostAction { resend, edit, delete }

/// 常用回应的**短代码**（不是 emoji 字符！）。
///
/// 服务端要的是 emojione 短代码：`EmojiPresenter.setReaction` 调的是
/// `setPostReaction(postId, sticker.name(), sticker.stickerId(), …)`，
/// 直接发 unicode 字符会被拒（实测 407 `CHAT_ERR_INVALID_RECORD`）。
/// 名字↔字符的对照表见 `lib/src/data/emoji_table.dart`（从 EmojiOne.java 生成）。
const kQuickReactions = <String>[
  'thumbsup',
  'heart',
  'joy',
  'tada',
  'eyes',
  'pray',
];

/// 长按菜单「复制」的文案。
///
/// 官方 `ActionSheetConfiguration`（`:330-333`）对 `type()=="file"` 走
/// `copy_desc`（复制文件**描述**），其余走 `copy_text`（复制正文）。
/// 内容侧两边都复制 `post.message`（文件消息的 `message` 就是描述），
/// 这里按 `post.type` 切**文案**（`chatActionCopyDesc` / `chatActionCopyText`）。
String copyActionLabel(PostDto post, AppText text) =>
    post.type == 'file' ? text.chatActionCopyDesc : text.chatActionCopyText;

/// 原版 `ActionSheetConfiguration.isAllowDownload`：
/// `!post.isVote() && file != null && file.size() > 0`
/// （原版另外还要求频道输入没被禁用；我们没有该标记，见 chat_page 的注释）
bool isAllowDownload(PostDto post) =>
    post.vote == null && post.attachments.any((f) => f.size > 0);

Future<PostAction?> showPostActionsSheet(
  BuildContext context, {
  required PostDto post,
  required bool mine,
  required bool canWrite,
  bool isThreadReply = false,
  bool allowPin = true,

  /// **话题内置顶** `Post/stick` v2 是否可用：服务端 `SYNO.Chat.Post` ≥ v2
  /// 且没探测到 407（`ChatSyncState.supportsStick && !stickUnsupported`）。
  bool allowStick = true,
  bool allowReminder = true,

  /// 原版 `PostUtil.isPostEditable` 的判定结果（自己发的 + 时间窗口内 + 不是投票…）
  bool? allowEdit,

  /// 原版 `isAllowShowReadStatus = allowReadStatus && post.userId == 我`
  /// —— 只有自己发的消息且在服务端开了已读回执时才显示两个入口
  bool allowReadStatus = false,

  /// 原版 `isAllowDownload = !post.isVote() && file != null && file.size > 0`
  /// ——「下载」= 存进系统「下载」目录（`DownloadFragment` 的 option 1）
  bool allowDownload = false,
}) {
  final t = context.t;
  final actions = <_Action>[
    _Action(
      PostAction.replyThread,
      Icons.forum_outlined,
      t.chatActionReplyThread,
    ),
    _Action(PostAction.react, Icons.emoji_emotions_outlined, t.chatActionReact),
    if (post.isStar)
      _Action(PostAction.unstar, Icons.star, t.driveUnstar)
    else
      _Action(PostAction.star, Icons.star_border, t.driveStar),
    // 「置顶」= **消息置顶** `Post/pin` v1 → `last_pin_at`（进置顶列表/排序），
    // 状态看 `last_pin_at`。
    if (allowPin && post.lastPinAt > 0)
      _Action(PostAction.unpin, Icons.push_pin, t.chatActionUnpin)
    else if (allowPin)
      _Action(PostAction.pin, Icons.push_pin_outlined, t.chatActionPin),
    // 「话题内置顶」= `Post/stick` v2 → `is_sticky`（画成置顶卡片），
    // 状态看 `is_sticky`。与上面的消息置顶是**两套动作、两套状态**，
    // 见 docs/phase4-protocol.md §5.1。文案 key 待并入 ARB（先走 dataText 中文回落）。
    if (allowStick && post.isSticky)
      _Action(
        PostAction.unstick,
        Icons.push_pin,
        dataText('chatActionUnstickThread', '取消话题内置顶'),
      )
    else if (allowStick)
      _Action(
        PostAction.stick,
        Icons.push_pin_outlined,
        dataText('chatActionStickThread', '话题内置顶'),
      ),
    _Action(PostAction.forward, Icons.forward_to_inbox, t.chatForward),
    // 提醒（`SYNO.Chat.Post.Reminder`，加密频道和投票不支持——对齐原 App）
    if (allowReminder && post.vote == null)
      if (post.remindAt > 0)
        _Action(
          PostAction.clearReminder,
          Icons.alarm_off_outlined,
          t.chatReminderCancel,
        )
      else
        _Action(
          PostAction.reminder,
          Icons.alarm_add_outlined,
          t.chatActionRemindMe,
        ),
    // 原版把「下载」和「编辑」放在同一组，且下载在前
    if (allowDownload)
      _Action(
        PostAction.download,
        Icons.download_outlined,
        t.dtoActionDownload,
      ),
    if (mine && !isThreadReply && (allowEdit ?? true))
      _Action(PostAction.edit, Icons.edit_outlined, t.calEditLabel),
    // 标签（`SYNO.Chat.Post.Hashtag`）
    _Action(PostAction.addHashtag, Icons.tag, t.chatAddHashtag),
    if (post.hashtags.isNotEmpty)
      _Action(
        PostAction.removeHashtag,
        Icons.tag_faces_outlined,
        t.chatActionRemoveHashtag,
      ),
    _Action(PostAction.copy, Icons.copy_all_outlined, copyActionLabel(post, t)),
    // 已读/未读名单（`SYNO.Chat.Post get_read_status` v6）
    if (mine && allowReadStatus)
      _Action(PostAction.readUsers, Icons.done_all, t.chatActionReadUsers),
    if (mine && allowReadStatus)
      _Action(
        PostAction.unreadUsers,
        Icons.mark_chat_unread_outlined,
        t.chatActionUnreadUsers,
      ),
    if (mine)
      _Action(
        PostAction.delete,
        Icons.delete_outline,
        t.dtoActionDelete,
        danger: true,
      ),
  ];

  final danger = <Widget>[];
  final quick = <Widget>[];

  Widget row(_Action a) => AppSheetAction(
    icon: a.icon,
    label: a.label,
    danger: a.danger,
    // `canWrite` 不成立时只留「复制文字」（原版：频道只读时其它动作全灰）
    onTap: (canWrite || a.action == PostAction.copy)
        ? () {
            HapticFeedbackCompat.light();
            Navigator.of(context).pop(a.action);
          }
        : null,
  );

  for (final a in actions) {
    if (a.danger) {
      danger.add(row(a));
    } else if (a.action == PostAction.replyThread ||
        a.action == PostAction.react) {
      quick.add(row(a));
    }
  }
  // 已读/未读两个入口单独一组（都是"给别人看的统计"）。
  // 分组按 [PostAction] 判定，不再依赖 action 行的显示文案（文案已多语言）。
  final readRows = <Widget>[];
  final rest = <Widget>[];
  for (final a in actions) {
    if (a.action == PostAction.replyThread ||
        a.action == PostAction.react ||
        a.danger) {
      continue;
    }
    (a.action == PostAction.readUsers || a.action == PostAction.unreadUsers)
        ? readRows.add(row(a))
        : rest.add(row(a));
  }

  return showAppSheet<PostAction>(
    context,
    title: t.chatActionSheetTitle,
    children: [
      AppSheetSection(children: quick),
      if (rest.isNotEmpty) AppSheetSection(children: rest),
      if (readRows.isNotEmpty)
        AppSheetSection(label: t.chatReadStatusSection, children: readRows),
      if (danger.isNotEmpty) AppSheetSection(danger: true, children: danger),
    ],
  );
}

class _Action {
  const _Action(this.action, this.icon, this.label, {this.danger = false});
  final PostAction action;
  final IconData icon;
  final String label;
  final bool danger;
}

/// 「未发出去的消息」（`state == 2` 失败 / `state == 3` 已过期）长按面板。
///
/// 逐行对位原版 `ChannelAdapter.showTempOption`：这类消息不给普通操作面板，
/// 只给 `R.array.temp_operation` = 重新发送 / 编辑 / 删除
/// （贴纸是 `R.array.temp_sticker_operation` = 重新发送 / 删除，不能改文字）。
Future<TempPostAction?> showTempPostActionsSheet(
  BuildContext context, {
  required PostDto post,
}) {
  final canEdit = post.type != 'sticker';
  return showModalBottomSheet<TempPostAction>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DesignRowTile(
            leading: const Icon(Icons.send_outlined),
            title: Text(context.t.chatTempResend),
            onTap: () => Navigator.of(context).pop(TempPostAction.resend),
          ),
          if (canEdit)
            DesignRowTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(context.t.calEditLabel),
              onTap: () => Navigator.of(context).pop(TempPostAction.edit),
            ),
          DesignRowTile(
            leading: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              context.t.dtoActionDelete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => Navigator.of(context).pop(TempPostAction.delete),
          ),
        ],
      ),
    ),
  );
}

/// 回应选择器：返回选中的**短代码**（服务端只认它；取消返回 null）。
///
/// 六个常用表情不够用（用户 2026-10-25 报「emoji 不全，很多没有展示」）——
/// 右下角给一个「全部表情」，打开内置八组的完整面板（`emoji_picker_sheet.dart`），
/// 选完照样返回短代码。
Future<String?> showReactionPicker(BuildContext context) async {
  final picked = await showModalBottomSheet<_ReactionChoice>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                for (final name in kQuickReactions)
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.of(sheetContext).pop(
                        _ReactionChoice(name),
                      ),
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        height: 48,
                        child: Center(
                          child: Text(
                            emojiForName(name),
                            style: const TextStyle(fontSize: 26),
                          ),
                        ),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: sheetContext.t.chatEmojiAll,
                  icon: const Icon(Icons.expand_more),
                  onPressed: () => Navigator.of(sheetContext).pop(
                    const _ReactionChoice.more(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return null;
  if (!picked.more) return picked.name;
  // 「全部表情」：只给表情（贴纸不能当回应发出去）
  final full = await showEmojiPicker(context, reactionsOnly: true);
  return full?.shortcode;
}

/// 回应选择器的返回值：点了某个短代码，或"要更多"
class _ReactionChoice {
  const _ReactionChoice(this.name) : more = false;
  const _ReactionChoice.more() : name = null, more = true;

  final String? name;
  final bool more;
}

/// 复制消息正文（原 App 也是纯文本复制）
Future<void> copyPostMessage(BuildContext context, String message) async {
  await Clipboard.setData(ClipboardData(text: message));
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(context.t.fileCopied)));
}

/// 编辑消息的对话框；确认返回新文本，取消返回 null
Future<String?> showEditPostDialog(BuildContext context, String current) async {
  final controller = TextEditingController(text: current);
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t.chatEditMessageTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              Navigator.of(context).pop(text.isEmpty ? null : text);
            },
            child: Text(context.t.actionSave),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}
