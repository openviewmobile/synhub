// 系统消息文案（对齐原版 `ChannelViewBinder` 的 bind* 系列 + `strings.xml`）。
//
// 服务端把系统事件的原始信息放在**顶层** `system_props`：
//   {channel_id, effective_user_id, trigger_user_id, target_user_ids,
//    post_id, thread_id, event, extra}
// `message` 一般是空串，**文案必须在客户端按 event 拼**（原版就是这么做的）。
//
// 约定（照抄原版语义）：
//   * `trigger_user_id` = **动作发起人**（0 或 -1 表示系统/Synobot）
//   * `target_user_ids` = **被作用的人**
//   * 名字优先昵称，其次账号名；访客账号（`guest_` 前缀）显示时去掉前缀并加「访客」
//   * 模板里的 `{xxx}` 占位符原版是「可点击链接文字」，内容就是花括号里的字
//     （`SpanUtil.postSpan` 把 `{post}` 渲染成蓝色的 "post"）——这里按纯文本还原。
//
// 文案取自 `values-zh-rCN/strings.xml`，逐条对应，别自己编。
import '../../core/i18n/l10n.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/user_dto.dart';

/// 生成一条系统消息的显示文案。
///
/// [usersById] 用来把 user_id 翻成名字；[channel] 用来翻频道名。
/// [text] 是界面语言文案表；缺省走 `currentText()`（中文回落，老测试照旧）。
String systemMessageText(
  PostDto post, {
  required Map<int, UserDto> usersById,
  ChannelDto? channel,
  int myUserId = 0,
  AppText? text,
}) {
  final t = text ?? currentText();
  final sys = post.systemProps ?? const <String, dynamic>{};
  final event = post.systemEvent;

  // 兜底：服务端/其它版本把文案直接塞在 message 里（实测 `command.error` 就是）
  if (event.isEmpty) {
    return post.message.isEmpty ? t.chatSystemMessage : post.message;
  }

  final trigger = _int(sys['trigger_user_id']);
  var targets = _intList(sys['target_user_ids']);
  // 老服务器/个别事件只给 `effective_user_id`（这条系统消息"关于谁"），
  // 没有 target_user_ids 时拿它兜底，免得文案里出现"某个用户"
  if (targets.isEmpty && trigger <= 0) {
    final effective = _int(sys['effective_user_id']);
    if (effective > 0) targets = [effective];
  }
  final extra = sys['extra'] is Map
      ? Map<String, dynamic>.from(sys['extra'] as Map)
      : const <String, dynamic>{};

  // 发起人排在最前面，跟原版 `queryUsers([trigger, ...targets])` 一致
  final all = <int>[if (trigger > 0) trigger, ...targets.where((id) => id > 0)];
  final actor = trigger > 0 ? _name(usersById[trigger], trigger, t) : '';
  final affected = targets
      .where((id) => id > 0)
      .map((id) => _name(usersById[id], id, t))
      .toList();
  final channelName = _channelName(extra, channel, myUserId, t);

  switch (event) {
    // ---------- 成员进出 ----------
    case 'channel.join':
      if (trigger <= 0) return t.chatSysJoined(_join(affected, t));
      final first = targets.isNotEmpty ? usersById[targets.first] : null;
      if (first != null && _isGuest(first)) {
        final email = '${extra['email'] ?? ''}';
        return t.chatSysGuestJoined(
          actor,
          _name(first, targets.first, t),
          email.isEmpty ? '' : ' ($email)',
        );
      }
      return t.chatSysInvited(actor, _join(affected, t));
    case 'channel.disjoin':
      if (trigger <= 0) return t.chatSysLeft(_join(affected, t));
      return t.chatSysMemberRemoved(actor, _join(affected, t));
    case 'channel.kick':
      // 这条是发给「被踢的人」他自己的
      return t.chatSysYouRemoved(channelName);
    case 'channel.guest.invited':
      final email = '${extra['email'] ?? ''}';
      return t.chatSysGuestInvited(actor, email);

    // ---------- 频道本身 ----------
    case 'channel.update':
      final sb = StringBuffer();
      final infos = extra['update_info'];
      if (infos is List) {
        for (final raw in infos) {
          if (raw is! Map) continue;
          final attr = '${raw['attr']}';
          final newValue = '${raw['new'] ?? raw['new_'] ?? ''}';
          final oldValue = '${raw['old'] ?? ''}';
          final line = switch (attr) {
            'channel_name' => t.chatSysChannelRenamed(newValue),
            'purpose' => t.chatSysChannelDescChanged(newValue),
            'type' when oldValue == 'anonymous' && newValue == 'private' =>
              t.chatSysConversationPromoted,
            _ => '',
          };
          if (line.isEmpty) continue;
          if (sb.isNotEmpty) sb.write(' ');
          sb.write(line);
        }
      }
      return sb.isEmpty ? t.chatSysChannelUpdated : sb.toString();
    case 'channel.archive':
    case 'channel.archive.synobot':
      return t.chatSysChannelArchived(
        channelName,
        _archiver(trigger, actor, t),
      );
    case 'channel.close':
      final reason = _closeReason('${extra['reason']}', extra, channelName, t);
      return t.chatSysChannelClosed(channelName, reason);
    case 'channel.revive':
      return t.chatSysYouRevived(actor, channelName);
    case 'channel.rescue':
      return t.chatSysRevived(_join(affected, t), actor);
    case 'channel.guest.kicked':
      return t.chatSysGuestKicked(actor, _join(affected, t));

    // ---------- 加密 ----------
    case 'encrypt.enabled':
      return t.chatSysEncryptEnabled(platformAppName());
    case 'encrypt.disabled':
      return t.chatSysEncryptDisabled;
    case 'encrypt.notify':
      final who = actor.isEmpty
          ? _join(all.map((id) => _name(usersById[id], id, t)).toList(), t)
          : actor;
      return t.chatSysEncryptInvited(who);
    case 'user.broken':
      return '${_join(all.map((id) => _name(usersById[id], id, t)).toList(), t)} '
          '${t.chatSysUserBroken}';
    case 'user.forgot_password':
      return t.chatSysKeyReset;

    // ---------- 帖子 / 话题 / 投票 ----------
    case 'thread.create':
      return t.chatSysThreadCreated;
    case 'comment.create':
      return t.chatSysCommentCreated(actor);
    case 'post.pin':
      return t.chatSysPostPinned;
    case 'post.delete':
    case 'post.vote.delete':
      return _deletedPostText(event, extra, channel, myUserId, t);
    case 'post.vote.close':
      return t.chatSysVoteClosed;
    case 'post.vote.update':
      return t.chatSysVoteUpdated;

    // ---------- 集成（Bot） ----------
    case 'bot.add':
      return t.chatSysBotAdded(actor, _join(affected, t));
    case 'bot.delete':
      return t.chatSysBotDeleted(actor, _join(affected, t));
    case 'bot.reset':
      return t.chatSysBotReset(
        _join(all.map((id) => _name(usersById[id], id, t)).toList(), t),
      );
    case 'bot.set_disabled':
      final disabled = extra['is_disabled'] == true;
      final who = actor.isEmpty ? t.chatSysUser : actor;
      return disabled
          ? t.chatSysBotDisabled(who, _join(affected, t))
          : t.chatSysBotEnabled(_join(affected, t), who);

    // ---------- 私密空间欢迎语 ----------
    // 原版 `bindWelcome`（`ChannelViewBinder.java:1842`）：`system_props.trigger_user_id`
    // 翻成名字后套 `R.string.welcome`。查不到人就给空串（原版 `ChatUtil.displayUsersName`
    // 对 null/空列表返回 ""，不会变成「用户 N」）。
    case 'welcome.message':
      final triggerUser = usersById[trigger];
      final who = triggerUser == null
          ? ''
          : displayUserName(triggerUser, trigger, t);
      return t.chatSysWelcome(who);

    case 'command.error':
      return post.message.isEmpty ? t.chatSysCommandFailed : post.message;
    default:
      if (post.message.isNotEmpty) return post.message;
      return t.chatSystemMessageEvent(event);
  }
}

/// 原版 `ChatUtil.displayUserName`：昵称 → 账号名；访客去掉 `guest_` 前缀 + 「访客」
///
/// [text] 缺省走 `currentText()`（中文回落）。
String displayUserName(UserDto? user, int fallbackId, [AppText? text]) {
  final t = text ?? currentText();
  if (user == null) return t.chatUserFallback(fallbackId);
  var name = user.nickname.isEmpty ? user.username : user.nickname;
  if (name.isEmpty) return t.chatUserFallback(fallbackId);
  if (_isGuest(user)) {
    if (user.nickname.isEmpty && name.startsWith('guest_')) {
      name = name.substring(6);
    }
    name = t.chatGuestSuffix(name);
  }
  return name;
}

/// 原版 `ChatUtil.displayUsersName`：`", "` 连接
String _join(List<String> names, AppText t) {
  final list = names.where((n) => n.isNotEmpty).toList();
  return list.isEmpty ? t.chatSomeUser : list.join(', ');
}

bool _isGuest(UserDto user) =>
    user.type == 'guest' || user.username.startsWith('guest_');

String _name(UserDto? user, int id, AppText t) => displayUserName(user, id, t);

String _archiver(int trigger, String actor, AppText t) =>
    trigger == -1 || actor.isEmpty ? t.chatSysUser : actor;

String _channelName(
  Map<String, dynamic> extra,
  ChannelDto? channel,
  int myUserId,
  AppText t,
) {
  final raw = extra['channel'];
  if (raw is Map) {
    final name = '${raw['name'] ?? ''}';
    if (name.isNotEmpty) return name;
    final type = '${raw['type'] ?? ''}';
    final members = raw['members'];
    if (type == 'anonymous' && members is List) {
      return t.chatConversationMembers(members.length);
    }
  }
  if (channel != null) {
    if (channel.name.isNotEmpty) return channel.name;
    return t.chatChannelHash(channel.channelId);
  }
  return t.chatThisChannel;
}

String _closeReason(
  String reason,
  Map<String, dynamic> extra,
  String channelName,
  AppText t,
) {
  final username = '${extra['username'] ?? ''}';
  return switch (reason) {
    'all_user_broken' => t.chatSysCloseAllUserBroken,
    'user_deleted' => t.chatSysCloseUserDeleted(
      username.isEmpty ? t.chatSysUser : username,
    ),
    'admin_toggle' => t.chatSysCloseAdminToggle,
    _ => t.chatSysCloseByUser(username.isEmpty ? t.chatSysUser : username),
  };
}

/// `post.delete` / `post.vote.delete`：消息 / 投票 / 文件三种措辞
String _deletedPostText(
  String event,
  Map<String, dynamic> extra,
  ChannelDto? channel,
  int myUserId,
  AppText t,
) {
  final post = extra['post'];
  final channelName = _channelName(extra, channel, myUserId, t);
  final username = '${extra['username'] ?? ''}';
  final who = username.isEmpty ? t.chatSysUser : username;
  var subject = t.chatSubjectMessage;
  var what = post is Map ? '${post['message'] ?? ''}' : '';
  if (event == 'post.vote.delete') {
    subject = t.chatFilterVote;
  } else if (post is Map && post['file_props'] != null) {
    subject = t.chatFilterFile;
    final fp = post['file_props'];
    if (fp is Map) what = '${fp['name'] ?? what}';
  }
  return t.chatSysPostDeleted(who, channelName, subject, what);
}

int _int(Object? v) {
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

List<int> _intList(Object? raw) {
  if (raw is List) {
    return raw.map(_int).where((v) => v > 0).toList();
  }
  if (raw is String && raw.isNotEmpty) {
    final parsed = int.tryParse(raw);
    if (parsed != null) return [parsed];
  }
  return const [];
}
