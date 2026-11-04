// 频道管理入口的开关规则 —— 逐条照抄原版 `ChannelSettingFragment.showChannel()` +
// `ChannelManageFragment.showChannelAndSelf()`（2.11.1-607）。
//
// 原版把"退出 / 归档 / 关闭"放在**频道设置页**里，归档/关闭再进二级的
// `ChannelManageFragment`；我们把等价入口收进聊天页的一个底部弹窗，
// 规则完全一致（少做的只有原版的"改名 / 设为公开频道"那两个入口，
// 它们走 `Named/set`，本工程的频道创建页已能改名，故未重复做）。
//
// 原版的每类型可见性（`View.VISIBLE` 是默认值，源码里只写 `setVisibility(8)` 的）：
//
// | type        | 标题               | 改名 | 成员 | 邀请 | 退出 | 归档 | 关闭 |
// |-------------|--------------------|------|------|------|------|------|------|
// | anonymous   | 会话设置           | ✗    | ✓    | ✗    | ✗    | ✗    | ✓（关闭会话）|
//   ↳ 匿名会话还多一项「将会话转换为专用频道」（`promote_to_channel`，
//     `Channel.Anonymous / promote` v2），门控 = `ApiManager.support(API, 2)`
// | synobot     | 会话设置           | ✗    | ✗    | ✗    | ✗    | ✗    | ✗    |
// | public      | （可改名）         | ✓*   | ✓    | ✗/✓  | ✓（#1 除外）| ✗ | ✗ |
// | private     | （可改名）         | ✓*   | ✓    | ACL  | ACL  | ★    | ✓（非访客）|
// | chatbot     | 聊天机器人会话设置 | ✗    | ✗    | ✗    | ✗    | ✗    | ✗    |
//
// ★ 归档条件：`ApiManager.support("SYNO.Chat.Channel", 2)`（maxVersion ≥ 2）
//   **且** 频道里有消息（`postCount != 0`）**且** `User.ACL_CHANNEL_ARCHIVE`。
// 访客（`user.isGuest()`）看不到归档/关闭；`#1`（我的空间）连退出都没有。
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/settings/acl.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';

/// 频道管理弹窗里每一项该不该出现。
class ChannelManageRules {
  const ChannelManageRules({
    required this.channel,
    required this.isGuest,
    required this.hasAclArchive,
    required this.hasAclDisjoin,
    required this.canArchiveApi,
    required this.postCount,
    required this.canPromoteApi,
  });

  /// 频道本身（决定 type / id）
  final ChannelDto channel;

  /// 我是不是访客（`dsm`/`guest` 里的 guest，见 `User.isGuest()`）
  final bool isGuest;

  /// `User.ACL_CHANNEL_ARCHIVE`（表里没有 key 时 fail-open = true）
  final bool hasAclArchive;

  /// `User.ACL_CHANNEL_DISJOIN`
  final bool hasAclDisjoin;

  /// `ApiManager.support("SYNO.Chat.Channel", 2)`
  final bool canArchiveApi;

  /// 频道里有多少条消息（本地计数；0 → 不给归档）
  final int postCount;

  /// `ApiManager.support("SYNO.Chat.Channel.Anonymous", 2)` —— promote 只存在于 v2
  final bool canPromoteApi;

  bool get _isAnonymous => channel.type == 'anonymous';
  bool get _isChatbot => channel.type == 'chatbot';
  bool get _isSynobot => channel.type == 'synobot';
  bool get _isPublic => channel.type == 'public';
  bool get _isPrivate => channel.type == 'private';

  /// 机器人的会话没有可管理的项
  bool get _isBotLike => _isChatbot || _isSynobot;

  /// 「退出频道」
  bool get showLeave {
    if (_isBotLike || _isAnonymous || isGuest) return false;
    if (_isPublic) return channel.channelId != 1; // #1 我的空间不能退
    if (_isPrivate) return hasAclDisjoin;
    return false;
  }

  /// 「归档频道」—— 只对 private 开（public 在设置页里就藏了）
  bool get showArchive =>
      _isPrivate && !isGuest && canArchiveApi && postCount > 0 && hasAclArchive;

  /// 「关闭频道」/「关闭会话」
  bool get showClose {
    if (_isBotLike) return false;
    if (isGuest) return false; // 原版：访客统一藏掉 close
    if (_isAnonymous) return true;
    if (_isPublic) return false; // public 的 closeView 恒藏（归档/关闭在 manage 里）
    if (_isPrivate) return true; // private 非访客：manage 里给关闭
    return false;
  }

  /// 「将会话转换为专用频道」（原版 `promote_to_channel`，只对匿名会话开）
  bool get showPromote => _isAnonymous && !isGuest && canPromoteApi;

  /// 关闭按钮的标题：匿名会话叫「关闭会话」，其余叫「关闭频道」。
  ///
  /// 界面按语言取文案（传 `context.t`）；[closeLabel] 只是中文回落，
  /// 老测试和拿不到 context 的地方仍可用它。
  String get closeLabel => labelIn(currentText());

  String labelIn(AppText text) =>
      _isAnonymous ? text.chatCloseConversation : text.chatCloseChannel;

  /// 「收藏」开关（synobot 上原版对访客禁用，不禁用隐藏）
  bool get favoriteEnabled => !(isGuest && _isSynobot);

  /// 有没有任何一项要显示（没有的话就不弹菜单了）
  bool get hasAny =>
      showLeave || showArchive || showClose || showPromote || favoriteEnabled;
}

/// 从 ACL 表 + 频道 + 消息数算出规则（和原版一样 fail-open）。
ChannelManageRules channelManageRules({
  required ChannelDto channel,
  required bool isGuest,
  required bool Function(String acl) hasPrivilege,
  required bool canArchiveApi,
  required int postCount,
  bool canPromoteApi = false,
}) => ChannelManageRules(
  channel: channel,
  isGuest: isGuest,
  hasAclArchive: hasPrivilege(kAclChannelArchive),
  hasAclDisjoin: hasPrivilege(kAclChannelDisjoin),
  canArchiveApi: canArchiveApi,
  postCount: postCount,
  canPromoteApi: canPromoteApi,
);
