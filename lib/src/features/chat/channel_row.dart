// 频道行面板 —— 频道列表页（指挥台）的"一行能量槽"。
//
// 为什么单独拆一个文件：行是这一页唯一会被复制十几份的东西，它的**性能**
// 与**状态表达**决定了整页的观感与帧率，所以从页面里独立出来，便于单独演进。
//
// 设计取舍（why）：
//   * 行**不用** `BackdropFilter`（模糊）。一屏十几行毛玻璃在中低端机上必掉帧；
//     这里用"高不透明填充 + 1px 切角描边 + 未读时才加的辉光"达到同样的层次感。
//   * 状态一律"形状 + 图标 + 颜色"三重编码（`_Mark` 切角小标），不让色盲用户
//     只靠色相区分静音/加密/置顶/机器人/失败。
//   * "静息克制、交互时才炫"：已读行低对比、无辉光；未读行才亮起左侧能量条
//     与 `glowShadow`。列表滚动时绝大部分行是静息的，省电也省帧。
//   * 首字符/图标逻辑、时间文案、人数/类型文案、徽标数字全部沿用原实现，
//     本文件只改"怎么画"，不改"显示什么"。
import 'channel_type_label.dart';
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/user_dto.dart';

/// 频道行的"标题"：匿名（1:1）频道的 name 为空 —— 用对方的显示名当标题
/// （原 App 同款行为，逐行对位改造前的 `_ChannelTile._title()`）。
///
/// `synobot` 频道例外：服务端下发的 `name` 是字面量 `"synobot"`，而原版
/// `Channel.displayName()` 会把它覆盖成 `R.string.myspace`（"我的空间" /
/// "My Space"）。不覆盖的话侧栏这一行就叫 `synobot`，用户会觉得 My Space 没了。
String channelRowTitle(
  ChannelDto channel,
  Map<int, UserDto> users,
  int myUserId, {
  AppText? text,
}) {
  final t = text ?? currentText();
  if (channel.type == 'synobot') return t.chatMySpace;
  if (channel.name.isNotEmpty) return channel.name;
  if (channel.type == 'anonymous' || channel.type.isEmpty) {
    final others = channel.members.where((id) => id != myUserId).toList();
    final names = others
        .map((id) => users[id]?.displayName)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    if (names.isNotEmpty) {
      return names.join(t.chatRowNameSeparator);
    }
  }
  return '#${channel.channelId}';
}

/// 头像首字符（与原实现完全一致）。
String channelRowInitial(String name) {
  if (name.isEmpty) return '?';
  final trimmed = name.trim();
  return trimmed.characters.first.toUpperCase();
}

/// 相对时间（与原实现完全一致：文案、分档都不动）。
String channelRowRelativeTime(int millis, {AppText? text}) {
  final t = text ?? currentText();
  if (millis <= 0) return t.chatRowNoMessages;
  final diff = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(millis),
  );
  if (diff.inMinutes < 1) return t.chatRowJustNow;
  if (diff.inHours < 1) return t.chatRowMinutesAgo(diff.inMinutes);
  if (diff.inDays < 1) return t.chatRowHoursAgo(diff.inHours);
  if (diff.inDays < 30) return t.chatRowDaysAgo(diff.inDays);
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 头像底色（类型/加密决定，与原实现一致）。
Color channelRowAvatarColor(ChannelDto channel, ThemeData theme) {
  if (channel.encrypted) return Colors.teal.shade600;
  if (channel.type == 'private') return Colors.indigo.shade400;
  if (channel.type == 'anonymous') return Colors.deepPurple.shade300;
  return theme.colorScheme.primary;
}

/// 副标题：类型 / 人数 / 未读话题。
///
/// **时间不在这一行**了 —— 它挪到右侧当遥测小字（HUD 的信息排布：时间右对齐、
/// 等宽、成列，扫一眼就能比出先后）。所有原有片段（'频道'、'N 人'、
/// 'N 个未读话题'）原样保留。
String channelRowSubtitle(ChannelDto channel, {AppText? text}) {
  final t = text ?? currentText();
  // ★ r344 D55：这里原来是 `channel.type`（服务端枚举）**原样**当文案，
  //   真机逐字 `public · 3 人` ⇒ 走唯一生产者（查不到给通用名词「频道」）。
  final bits = <String>[channelTypeLabel(channel.type, t)];
  if (channel.totalMemberCount > 0) {
    bits.add(t.chatRowMembers(channel.totalMemberCount));
  }
  if (channel.unreadThread.isNotEmpty) {
    bits.add(t.chatRowUnreadThreads(channel.unreadThread.length));
  }
  return bits.join(' · ');
}

/// 一行频道。
class ChannelRow extends StatelessWidget {
  const ChannelRow({
    super.key,
    required this.channel,
    required this.users,
    required this.myUserId,
    required this.onTap,
    this.onLongPress,
    this.failed = false,
  });

  final ChannelDto channel;
  final Map<int, UserDto> users;
  final int myUserId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 这个频道里有发送失败的消息（原版 `hasFailedPost`，上游
  /// `failedPostChannelsProvider` 算出来的真实状态）
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hud = DesignPalette.of(context);
    final t = context.t;

    final title = channelRowTitle(channel, users, myUserId, text: t);
    final unread = channel.unreadTotal;
    final mention = channel.unreadMention + channel.unreadMentionComment;
    final hasUnread = unread > 0 || mention > 0;
    final isBot = channel.isChatBotType || channel.type == 'synobot';

    // 未读行的"亮起"由 `DesignRowShell(selected: ...)` 统一负责
    // （主色底 + 主色描边）；这里不再自己算填充与描边 —— 那份实现
    // 已经搬进设计组件，避免同屏两种"未读态"。

    final marks = <Widget>[
      if (failed)
        _Mark(Icons.error_outline, scheme.error, semantic: t.chatRowHasFailed),
      if (channel.brokenUsers.isNotEmpty)
        _Mark(Icons.link_off, hud.danger, semantic: t.chatRowHasBrokenMembers),
      if (channel.notificationMute)
        _Mark(
          Icons.notifications_off_outlined,
          hud.dim,
          semantic: t.chatRowMuted,
        ),
      if (channel.type == 'synobot')
        _Mark(
          Icons.workspaces_outline,
          scheme.primary,
          semantic: t.chatMySpace,
        ),
      if (isBot && channel.type != 'synobot')
        _Mark(
          Icons.smart_toy_outlined,
          scheme.primary,
          semantic: t.chatRowBotChannel,
        ),
      if (channel.isStar) _Mark(Icons.star, hud.accent, semantic: t.chatPinned),
      if (channel.encrypted)
        _Mark(Icons.lock_outline, hud.dim, semantic: t.meE2ee),
    ];

    // ★ r493：切角 HUD 卡片 → 设计行卡（`DesignRowShell`）。
    //   * 未读不再靠"左侧能量条 + 辉光"表达：设计语言用**加粗标题 + 未读角标 + 主色描边**，
    //     能量条是上一版 HUD 的装饰（同屏两种语言会打架）；
    //   * 头像、时间、角标、标记（静音/机器人/星标/加密）全部保留，
    //     这些是**信息**，不是装饰。
    return DesignRowShell(
      onTap: onTap,
      onLongPress: onLongPress,
      selected: hasUnread,
      // ★ DA294（续）：边框宽度**钉死**。默认实现是"选中 1.5 / 未选中 1"，
      //   而选中态跟着 `hasUnread` 走、未读数每秒都在变 ⇒ 整行差 1dp、下面的行全跳。
      borderWidth: 1.5,
      contentPadding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          RingAvatar(
            size: 42,
            // 机器人用图标，其余沿用首字符逻辑
            icon: isBot ? Icons.smart_toy : null,
            label: isBot ? null : channelRowInitial(title),
            background: channelRowAvatarColor(channel, theme),
            ring: hasUnread ? scheme.primary : null,
            ringWidth: 1.6,
            semanticLabel: t.chatChannelSemantic(title),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: DesignType.titleSmallSize,
                          fontWeight:
                              hasUnread ? FontWeight.w700 : FontWeight.w600,
                          color: hud.text,
                        ),
                      ),
                    ),
                    if (marks.isNotEmpty) ...[
                      const SizedBox(width: Gap.xs + 2),
                      ...marks.expand(
                        (m) => [m, const SizedBox(width: 3)],
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  channelRowSubtitle(channel, text: t),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: DesignType.bodySmallSize,
                    color: hud.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // 右侧：时间 + 未读角标
          //
          // ★ DA294（续）：这里原来是 `if (hasUnread) ... CountBadge(...)` ——
          //   角标**参与布局**，所以未读一出现/一清空，这一行就长高/缩回去
          //   （实测 4dp），而同步期间未读数是**每秒都会变**的 ⇒ 侧栏整列上下抖。
          //   现在：角标槽**永远占位**（`Visibility(maintainSize: true)`），
          //   行高恒定；颜色/字重的变化仍然即时可见（那是"信息"，不是抖动）。
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                channelRowRelativeTime(channel.sortKey, text: t),
                style: TextStyle(
                  fontSize: DesignType.labelSmallSize,
                  color: hasUnread ? hud.primary : hud.dim,
                ),
              ),
              const SizedBox(height: 4),
              Visibility(
                visible: hasUnread,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: CountBadge(
                  // 隐藏时也给 1：宽度不变、高度不变，避免"占位后又缩"
                  count: mention > 0 ? mention : (unread > 0 ? unread : 1),
                  mention: mention > 0 && hasUnread,
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark(this.icon, this.color, {this.semantic});

  final IconData icon;
  final Color color;
  final String? semantic;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 17,
      height: 17,
      decoration: ShapeDecoration(
        shape: ChamferBorder(
          cut: 5,
          side: BorderSide(color: color.withValues(alpha: 0.45), width: 1),
        ),
        color: color.withValues(alpha: 0.12),
      ),
      child: Icon(icon, size: 11, color: color),
    );
    if (semantic == null) return mark;
    return Semantics(label: semantic, child: mark);
  }
}
