// Socket 事件名 —— 逐一对齐 APK 的 `data/remote/SocketEvent.java`
// 以及服务端 `node/msg_server/chat_service/service.js` 的 emit 点。
//
// 这个文件刻意保持"常量表"形态：事件名写错的代价是静默丢消息，
// 有集中一处可比对的清单，出问题时能直接和服务端/APK 对照。
//
// ⚠️ 分清两件事（这里以前混在一起，导致 `hide_global` 挂错地方、真机上永远收不到）：
//   * [SocketEvent]  —— **socket 事件名**，服务端 `emit(名字, 载荷)`；
//     原版 `SocketHelper.java#provideSocket` 一共只 `.on()` 了 12 个（见 [serverEvents]）。
//   * [BroadcastType] —— `client.broadcast` 载荷里的 `data.type`
//     （`{type: "post.update", data: {...}}`），30 种通知都走这一个事件。
library;

/// 服务端 → 客户端 / 客户端 → 服务端的 **socket 事件名**。
class SocketEvent {
  // ---- 客户端 → 服务端 ----
  /// 服务端 → 客户端（发 conn_id）
  static const clientInit = 'client.init';

  /// 客户端 → 服务端（握手回执）
  static const clientInitDone = 'client.initdone';
  static const clientUserActivate = 'client.user.activate';
  static const clientUserDeactivate = 'client.user.deactivate';
  static const clientUserTyping = 'client.user.typing';
  static const clientUserClearTyping = 'client.user.clear_typing';

  // ---- 服务端 → 客户端（原版用 `.on()` 注册的那些）----
  /// `client.broadcast`：**唯一**的广播信封，具体类型看载荷里的 `type`（[BroadcastType]）
  static const clientBroadcast = 'client.broadcast';
  static const clientPostCreate = 'client.post.create';
  static const clientChannelJoin = 'client.channel.join';
  static const clientChannelDisjoin = 'client.channel.disjoin';
  static const clientChannelTyping = 'client.channel.typing';
  static const clientChannelTypingV2 = 'client.channel.typing_v2';
  static const clientChannelBrokenUser = 'client.channel.brokenuser';
  static const clientChannelHideGlobal = 'client.channel.hide_global';
  static const clientChannelUnhideGlobal = 'client.channel.unhide_global';
  static const clientUserUpdate = 'client.user.update';
  static const clientUserUpdateKey = 'client.user.updatekey';
  static const notificationCreate = 'notification.create';

  /// 原版 `SocketHelper.java#provideSocket` 注册的全部服务端事件
  /// （`client.init` 由连接层单独处理）。用来对照"哪些名字是**真** socket 事件"。
  static const serverEvents = <String>[
    clientInit,
    clientPostCreate,
    clientChannelJoin,
    clientChannelDisjoin,
    clientChannelTyping,
    clientChannelTypingV2,
    clientChannelBrokenUser,
    clientChannelHideGlobal,
    clientChannelUnhideGlobal,
    clientUserUpdate,
    clientUserUpdateKey,
    clientBroadcast,
    notificationCreate,
  ];
}

/// `client.broadcast` 载荷里的 `type`。
///
/// 全量清单来自原版 `SocketHelper.lambda$socketIO$14` 的 `switch(str2)`（30 项），
/// 加上 `PostSpan` 里单独处理的投票三项；服务端一侧的 emit 点在
/// `service.js#onBroadcastUser/onBroadcastChannel/onBroadcastAll`。
abstract final class BroadcastType {
  // ---- 用户 ----
  static const userCreate = 'user.create';
  static const userUpdate = 'user.update';
  static const userDelete = 'user.delete';

  // ---- 频道 ----
  static const channelArchive = 'channel.archive';
  static const channelClose = 'channel.close';
  static const channelHide = 'channel.hide';
  static const channelShow = 'channel.show';
  static const channelStar = 'channel.star';
  static const channelUnstar = 'channel.unstar';
  static const channelUpdate = 'channel.update';
  static const channelView = 'channel.view';
  static const channelViewComment = 'channel.view_comment';
  static const channelTyping = 'channel.typing';
  static const channelRescue = 'channel.rescue';
  static const channelRevive = 'channel.revive';
  static const channelPreference = 'channel.preference';

  // ---- 消息 ----
  static const postDelete = 'post.delete';
  static const postDeleteBatch = 'post.delete_batch';
  static const postDeleteSearchList = 'post.delete_search_list';
  static const postPin = 'post.pin';
  static const postUnpin = 'post.unpin';
  static const postStar = 'post.star';
  static const postUnstar = 'post.unstar';
  static const postSubscribe = 'post.subscribe';
  static const postUnsubscribe = 'post.unsubscribe';
  static const postUpdate = 'post.update';
  static const postReminderSet = 'post.reminder.set';
  static const postReminderDelete = 'post.reminder.delete';
  static const postScheduleSet = 'post.schedule.set';
  static const postScheduleDelete = 'post.schedule.delete';
  static const postVoteUpdate = 'post.vote.update';
  static const postVoteClose = 'post.vote.close';
  static const postVoteDelete = 'post.vote.delete';

  /// 服务端设置变更（文件大小上限 / 编辑窗口 / 加密开关…）
  static const settingUpdate = 'setting.update';

  /// 服务端会发、我们**不消费**的类型：通知广播（本地通知自管）、
  /// 频道复活（服务端内部流程，没有对应落库动作）。
  static const notificationCreate = 'notification.create';
  static const channelReviveNotUsed = 'channel.revive';

  /// 已知的广播类型全表（诊断用：收到表外的类型会打一条日志）
  static const all = <String>{
    userCreate,
    userUpdate,
    userDelete,
    channelArchive,
    channelClose,
    channelHide,
    channelShow,
    channelStar,
    channelUnstar,
    channelUpdate,
    channelView,
    channelViewComment,
    channelTyping,
    channelRescue,
    channelRevive,
    channelPreference,
    postDelete,
    postDeleteBatch,
    postDeleteSearchList,
    postPin,
    postUnpin,
    postStar,
    postUnstar,
    postSubscribe,
    postUnsubscribe,
    postUpdate,
    postReminderSet,
    postReminderDelete,
    postScheduleSet,
    postScheduleDelete,
    postVoteUpdate,
    postVoteClose,
    postVoteDelete,
    settingUpdate,
    notificationCreate,
  };
}
