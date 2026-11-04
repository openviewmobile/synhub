// 机器人消息的「附件 + 按钮」渲染。
//
// 对齐原版：
//   * `AttachmentAdapter`（item_attachment.xml）：左侧 3dp 竖条 + 附件文本（16sp）
//     + 按钮区（上间距 8dp）；
//   * `ActionAdapter`（item_action.xml）：按钮最小宽 200dp / 最大 270dp，
//     圆角 14dp、1px 同色描边、按下时填充该色（文字变白）；
//     未知 style 落到 gray（`status_chatbot_button_gray`）；
//   * 点击 → `ChatBotEvent.trigger` → 服务端 `Post.Attachment / trigger`，
//     请求期间把按钮换成"转圈 + 处理中..."（`bot_attach_processing`，
//     中文包是"处理中..."），请求回来再换回来。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../design/design_palette.dart';
import '../../data/dto/chatbot_attachment_dto.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/user_dto.dart';
import 'chat_session_controller.dart';
import 'rich_text.dart';

/// 机器人按钮的**可读**文字/描边色。
///
/// ★ 第 238 轮（`DA182`，用户裁定 ③）：官方那六个品牌色是给**浅底上的图标/填充**
///   用的，直接拿来写字在亮色底上只有 **2.32–4.18:1**（真机像素：绿 `OK` = 2.41:1），
///   连 WCAG AA 都不到 —— 深底上的问题没这么明显，所以以前没被盯出来。
///   这里用设计系统的 `DesignPalette.ensureContrast` 压到 ≥4.5：
///   **只降亮度、不动色相**，"绿=确认 / 红=取消"的语义仍然一眼可辨。
Color chatbotActionColor(BuildContext context, ChatbotActionStyle style) {
  final p = DesignPalette.of(context);
  // 目标给 4.6 而不是 4.5：调色板的 `surface` 在动态取色下可能比**卡片白**略暗，
  // 按 `surface` 拟合出来的字画到卡片上会掉一档（真机：按 4.5 拟合约 4.47:1）。
  // 多 0.1 的余量，屏幕上就稳稳过 AA。
  return DesignPalette.ensureContrast(
    style.color,
    p.surface,
    min: 4.6,
    brightness: Theme.of(context).brightness,
  );
}

/// 竖条颜色（`@color/attachStarter`，浅色/夜间两套）
Color _starterColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF383C3D)
    : const Color(0xFFE8EAEC);

class ChatbotAttachmentList extends ConsumerStatefulWidget {
  const ChatbotAttachmentList({
    super.key,
    required this.channelId,
    required this.post,
    this.usernames = const {},
    this.usersById = const {},
    this.onOpenUrl,
    this.onHashtag,
    this.onMention,
  });

  final int channelId;
  final PostDto post;

  /// `@名字` → user_id（附件文本里的提及也要能点）
  final Map<String, int> usernames;
  final Map<int, UserDto> usersById;
  final void Function(String url)? onOpenUrl;
  final void Function(String tag)? onHashtag;
  final void Function(int userId, String name)? onMention;

  @override
  ConsumerState<ChatbotAttachmentList> createState() =>
      _ChatbotAttachmentListState();
}

class _ChatbotAttachmentListState extends ConsumerState<ChatbotAttachmentList> {
  /// 正在等服务的那个附件下标（原版 `mHideAttachments`）
  int? _pending;

  Future<void> _tap(int attachmentIndex, int actionIndex) async {
    final t = context.t;
    if (_pending != null) return;
    setState(() => _pending = attachmentIndex);
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .triggerChatbotAction(
          channelId: widget.channelId,
          postId: widget.post.postId,
          attachmentIndex: attachmentIndex,
          actionIndex: actionIndex,
        );
    if (!mounted) return;
    setState(() => _pending = null);
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.chatBotActionFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final attachments = widget.post.chatbotAttachments;
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < attachments.length; i++)
          _AttachmentBlock(
            attachment: attachments[i],
            pending: _pending == i,
            onTapAction: (actionIndex) => _tap(i, actionIndex),
            usernames: widget.usernames,
            usersById: widget.usersById,
            onOpenUrl: widget.onOpenUrl,
            onHashtag: widget.onHashtag,
            onMention: widget.onMention,
          ),
      ],
    );
  }
}

class _AttachmentBlock extends StatelessWidget {
  const _AttachmentBlock({
    required this.attachment,
    required this.pending,
    required this.onTapAction,
    required this.usernames,
    required this.usersById,
    this.onOpenUrl,
    this.onHashtag,
    this.onMention,
  });

  final ChatbotAttachmentDto attachment;
  final bool pending;
  final void Function(int actionIndex) onTapAction;
  final Map<String, int> usernames;
  final Map<int, UserDto> usersById;
  final void Function(String url)? onOpenUrl;
  final void Function(String tag)? onHashtag;
  final void Function(int userId, String name)? onMention;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 左侧 3dp 竖条（item_attachment.xml 的 starter）
            Container(width: 3, color: _starterColor(context)),
            const SizedBox(width: 6),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (attachment.text.isNotEmpty)
                    MessageText(
                      attachment.text,
                      mentions: const [],
                      usernames: usernames,
                      mentionNames: mentionNamesById(usersById.values),
                      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 16),
                      onUrl: onOpenUrl,
                      onHashtag: onHashtag,
                      onMention: onMention,
                    ),
                  const SizedBox(height: 8),
                  if (pending)
                    Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 14),
                        Text(
                          context.t.chatBotProcessing,
                          style: TextStyle(
                            color: ChatbotActionStyle.green.color,
                          ),
                        ),
                      ],
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var j = 0; j < attachment.actions.length; j++)
                          _ActionButton(
                            action: attachment.actions[j],
                            onPressed: () => onTapAction(j),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.onPressed});

  final ChatbotActionDto action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // 可读版本（品牌色只留语义，不直接当文字色：见 `chatbotActionColor`）
    final color = chatbotActionColor(context, action.resolvedStyle);
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color, width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
        // 原版 item_action.xml：minWidth 200dp / maxWidth 270dp
        minimumSize: const Size(200, 32),
        maximumSize: const Size(270, 48),
      ),
      child: Text(
        action.label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );
  }
}
