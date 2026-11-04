// 侧栏（频道列表）的**分组与排序** —— 逐行对位原版
// `Channel.viewType()` + `NaturalOrderComparator` + `DrawerPresenter`。
//
// 原版结构（`DrawerPresenter.loadChannels`）：
//   [100 用户行] [101 搜索]
//   [102 未读]        ← 只要有一个未读频道才加这个头
//     103 未读频道
//   [104 已加星标]     ← 只要有一个"加了星且没有失败消息"的频道才加
//     105 星标频道
//   [106 频道]        ← 总是有
//     107 普通频道
//     109 synobot    ← 原版**没有给 synobot 单独加头**，它夹在频道与会话之间
//   [108 会话]        ← 有 ACL_CHANNEL_ANONYMOUS 权限才加
//     110 一对一会话
//   [111 机器人]       ← 只要有一个"没加星"的机器人频道才加
//     112 机器人频道
//
// 排序：`compare()` 先按 **viewType 升序**分组，同组内交给
// `compareSameViewTypeChannel`：
//   * 103 未读：**固定按名称**，规则 `[badge>0 降序, (有失败消息且无 badge) 升序,
//     synobot 降序, encrypted 降序]`
//   * 105 星标：`favorite_sort_by` + `[synobot 降序, encrypted 降序]`
//   * 107 频道：`channel_sort_by` + `[encrypted 降序]`
//   * 112 机器人：`chat_bot_sort_by` + `[encrypted 降序]`
//   * 109/110（synobot 与会话）：`conversation_sort_by` + `[encrypted 降序]`
//     （原版 switch 里 109 落到 else 分支，用的是**会话**的排序偏好）
//
// `orderBySortMethod`：方法是 `TIME` 就直接比 **`channel_order_time` 降序**；
// 否则先逐条比规则、最后按 `orderByAlphabetical`（大小写不敏感、跳过空格、
// 数字段按数值比）。
//
// 实测（NAS 2.4.7-22203，`tool/probe_channel_order.dart`）：`Channel/list`
// **只有 v5 + `is_joined=true` 才下发 `channel_order_time`**，且值等于该频道的
// `last_post_at`（也就是"按接收时间"= 按最近消息时间倒序）。
// 不传 `is_joined` 时字段整个消失 —— 别据此以为服务端不支持排序
// （`AccountManager.isSupportSortChannelByMethod()` 看的就是 `SYNO.Chat.Channel >= 5`）。
// 万一将来某台服务器不发这个字段（值全 0），`TIME` 会比较出 0 并保持基列表
// 顺序（= 名称序），与原版的稳定排序行为一致。
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/user_dto.dart';

/// 排序方式（原版 `sort_methods_values`：`NAME` / `TIME`）
enum ChannelSortMethod {
  name('NAME', '名称'),
  time('TIME', '接收时间');

  const ChannelSortMethod(this.rawValue, this.label);

  final String rawValue;
  final String label;

  /// 本地化文案（`label` 是中文回落；界面用 `labelIn(context.t)`）
  String labelIn(AppText t) => switch (this) {
    ChannelSortMethod.name => t.sortByName,
    ChannelSortMethod.time => t.sortByTime,
  };

  /// 认不出的（含空串）→ `TIME`（原版 `SortMethodPreferences` 的默认值）
  static ChannelSortMethod fromName(String raw) =>
      raw == 'NAME' ? ChannelSortMethod.name : ChannelSortMethod.time;
}

/// 四个分组的排序偏好（原版 `SortMethodPreferences.V2`，
/// key：`favorite_sort_by` / `channel_sort_by` / `conversation_sort_by` /
/// `chat_bot_sort_by`，默认都是 `TIME`）
class ChannelSortPrefs {
  const ChannelSortPrefs({
    this.favorite = ChannelSortMethod.time,
    this.channel = ChannelSortMethod.time,
    this.conversation = ChannelSortMethod.time,
    this.chatbot = ChannelSortMethod.time,
  });

  final ChannelSortMethod favorite;
  final ChannelSortMethod channel;
  final ChannelSortMethod conversation;
  final ChannelSortMethod chatbot;

  /// synobot 与"一对一会话"共用（原版 109 落在 else 分支）
  ChannelSortMethod get synobot => conversation;

  ChannelSortPrefs copyWith({
    ChannelSortMethod? favorite,
    ChannelSortMethod? channel,
    ChannelSortMethod? conversation,
    ChannelSortMethod? chatbot,
  }) => ChannelSortPrefs(
    favorite: favorite ?? this.favorite,
    channel: channel ?? this.channel,
    conversation: conversation ?? this.conversation,
    chatbot: chatbot ?? this.chatbot,
  );

  /// 某个分组用的是哪一档（未读组固定名称序）
  ChannelSortMethod methodFor(SidebarSection s) => switch (s) {
    SidebarSection.unread => ChannelSortMethod.name,
    SidebarSection.favorite => favorite,
    SidebarSection.channel => channel,
    SidebarSection.synobot => synobot,
    SidebarSection.conversation => conversation,
    SidebarSection.chatbot => chatbot,
  };

  @override
  bool operator ==(Object other) =>
      other is ChannelSortPrefs &&
      other.favorite == favorite &&
      other.channel == channel &&
      other.conversation == conversation &&
      other.chatbot == chatbot;

  @override
  int get hashCode => Object.hash(favorite, channel, conversation, chatbot);
}

/// 分组折叠状态。
///
/// 原版侧栏的分组头是可展开的（`ExpandableHeaderItem`），折叠状态存在
/// `hideFavorite` / `hideChannel` / `hideConversation` / `hideChatBot` 四个偏好里
/// （**默认 false = 展开**；`true` 表示**收起**，名字起反了但键名得照抄）。
/// 「未读」组（102）原版没有展开箭头，synobot 组根本没有标题，都不参与折叠。
class SidebarCollapsed {
  const SidebarCollapsed({
    this.favorite = false,
    this.channel = false,
    this.conversation = false,
    this.chatbot = false,
  });

  final bool favorite;
  final bool channel;
  final bool conversation;
  final bool chatbot;

  /// 这个组能不能折叠（对应原版有展开箭头的四个头）
  static bool collapsible(SidebarSection s) => switch (s) {
    SidebarSection.unread || SidebarSection.synobot => false,
    SidebarSection.favorite ||
    SidebarSection.channel ||
    SidebarSection.conversation ||
    SidebarSection.chatbot => true,
  };

  bool isCollapsed(SidebarSection s) => switch (s) {
    SidebarSection.favorite => favorite,
    SidebarSection.channel => channel,
    SidebarSection.conversation => conversation,
    SidebarSection.chatbot => chatbot,
    _ => false,
  };

  SidebarCollapsed toggled(SidebarSection s) => switch (s) {
    SidebarSection.favorite => SidebarCollapsed(
      favorite: !favorite,
      channel: channel,
      conversation: conversation,
      chatbot: chatbot,
    ),
    SidebarSection.channel => SidebarCollapsed(
      favorite: favorite,
      channel: !channel,
      conversation: conversation,
      chatbot: chatbot,
    ),
    SidebarSection.conversation => SidebarCollapsed(
      favorite: favorite,
      channel: channel,
      conversation: !conversation,
      chatbot: chatbot,
    ),
    SidebarSection.chatbot => SidebarCollapsed(
      favorite: favorite,
      channel: channel,
      conversation: conversation,
      chatbot: !chatbot,
    ),
    _ => this,
  };

  @override
  bool operator ==(Object other) =>
      other is SidebarCollapsed &&
      other.favorite == favorite &&
      other.channel == channel &&
      other.conversation == conversation &&
      other.chatbot == chatbot;

  @override
  int get hashCode => Object.hash(favorite, channel, conversation, chatbot);
}

/// 侧栏分组 —— 取值就是原版 `Channel.viewType()` 的 mobile 值/// 侧栏分组 —— 取值就是原版 `Channel.viewType()` 的 mobile 值
enum SidebarSection {
  unread(103),
  favorite(105),
  channel(107),

  /// 原版不给它单独加标题，夹在「频道」与「会话」之间
  synobot(109),
  conversation(110),
  chatbot(112);

  const SidebarSection(this.viewType);

  final int viewType;

  /// 分组标题（`null` = 原版没有标题）；译文见 [titleIn]。
  ///
  /// 这里**不留中文字面量**：取值直接委托 [titleIn]（走了既有 ARB key，
  /// 中文模式下得到的就是原版那几句）。
  String? get title => titleIn(currentText());

  /// 分组标题的本地化（界面用 `titleIn(context.t)`）
  ///
  /// 复用既有 key：`已加星标/频道/会话/机器人` 与「排序目标」那组同词同义。
  String? titleIn(AppText t) => switch (this) {
    SidebarSection.unread => t.chatSectionUnread,
    SidebarSection.favorite => t.sortTargetFavorite,
    SidebarSection.channel => t.sortTargetChannel,
    SidebarSection.synobot => null,
    SidebarSection.conversation => t.sortTargetConversation,
    SidebarSection.chatbot => t.sortTargetChatbot,
  };
}

/// 频道在该频道分组里"未读数"该怎么算（原版 `Channel.getBadgeNumber`）。
///
/// public/private **且未加密** 的频道只有"提到我"才算 badge；
/// 其余（anonymous / synobot / chatbot / 加密频道）算全部未读 + 未读回复。
int channelBadgeNumber(ChannelDto c) {
  final mentionOnly = c.isPublicOrPrivate && !c.encrypted;
  return mentionOnly
      ? c.unreadMention + c.unreadMentionComment
      : c.unread + c.unreadComment;
}

/// 是否要进「未读」分组（原版 `Channel.showInUnread()`）
bool showInUnreadSection(
  ChannelDto c, {
  required bool hasFailedPost,
  String serverDefaultNotificationType = '',
}) {
  if (hasFailedPost) return true;
  return !c.hideAtSideBar(
        hasFailedPost: hasFailedPost,
        serverDefaultNotificationType: serverDefaultNotificationType,
      ) &&
      c.totalUnread > 0;
}

/// 原版 `Channel.viewType()` 的分组（mobile 取值）
SidebarSection sectionOf(
  ChannelDto c, {
  required bool hasFailedPost,
  String serverDefaultNotificationType = '',
}) {
  if (showInUnreadSection(
    c,
    hasFailedPost: hasFailedPost,
    serverDefaultNotificationType: serverDefaultNotificationType,
  )) {
    return SidebarSection.unread;
  }
  if (c.isStar) return SidebarSection.favorite;
  return switch (c.type) {
    'anonymous' => SidebarSection.conversation,
    'synobot' => SidebarSection.synobot,
    'chatbot' => SidebarSection.chatbot,
    _ => SidebarSection.channel,
  };
}

/// 列表里显示的名字（原版 `Channel.displayName()` /
/// `conversationDisplayName(myUserId)`）。
String channelDisplayName(
  ChannelDto c, {
  int myUserId = 0,
  Map<int, UserDto> users = const {},
  AppText? text,
}) {
  // 原版 `Channel.displayName()`：`isSynoBot()`（`type == "synobot"`）⇒
  // `R.string.myspace`（"My Space" / "我的空间"）。服务端把这个频道的 `name`
  // 原样下发成字面量 `"synobot"` ⇒ **所有用户可见的标题都必须走这个覆盖**，
  // 否则用户看到的是一个叫 `synobot` 的机器人行，等于"My Space 缺失"。
  final t = text ?? currentText();
  if (c.type == 'synobot') return t.chatMySpace;
  if (c.name.isNotEmpty) return c.name;
  if (c.channelId == 1) return dataText('chatChannelGeneral', '常规');
  if (c.channelId == 2) return dataText('chatChannelRandom', '随机');
  if (c.isConversation) {
    // 原版 `conversationDisplayName(myUserId)`：两人会话取对方显示名
    final others = c.members.where((id) => id != myUserId).toList();
    if (others.length == 2 && myUserId == 0) {
      // members 里没有"我"（异常数据）时不要乱猜
      return c.name;
    }
    final names = others
        .map((id) => users[id])
        .whereType<UserDto>()
        .map(userDisplayName)
        .where((s) => s.isNotEmpty)
        .toList();
    if (names.isNotEmpty) return names.join(t.chatRowNameSeparator);
  }
  return c.name;
}

/// 原版 `User.displayName()`：有昵称就 `username (nickname)`
String userDisplayName(UserDto u) =>
    u.nickname.isEmpty ? u.username : '${u.username} (${u.nickname})';

// ---------------------------------------------------------------- 比较器

/// 原版 `SortOrder`：`Ascending.compareOrder(a,b) = a<=>b`
int _compareOrder(int a, int b) => a.compareTo(b);

/// 布尔规则：`desc` = true 时"真"在前（原版 `SortOrder.Descending`）
int _compareRule(bool left, bool right, {required bool desc}) {
  if (left == right) return 0;
  final ascending = left ? 1 : -1; // false < true
  return desc ? -ascending : ascending;
}

/// 自然序比较（原版 `orderByAlphabetical` + `compareRight`）：
/// 全小写、跳过空格、连续数字按数值比。
int naturalCompare(String a, String b) {
  final left = a.toLowerCase();
  final right = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (true) {
    var ca = _charAt(left, i);
    var cb = _charAt(right, j);
    while (_isSpaceChar(ca)) {
      i++;
      ca = _charAt(left, i);
    }
    while (_isSpaceChar(cb)) {
      j++;
      cb = _charAt(right, j);
    }
    if (_isDigit(ca) && _isDigit(cb)) {
      final r = _compareRight(left.substring(i), right.substring(j));
      if (r != 0) return r;
    }
    if (ca == 0 && cb == 0) return 0;
    if (ca != cb) return ca < cb ? -1 : 1;
    i++;
    j++;
  }
}

/// 两个字符串开头的数字段谁大（原版 `compareRight`）
int _compareRight(String a, String b) {
  var bias = 0;
  var i = 0;
  var j = 0;
  while (true) {
    final ca = _charAt(a, i);
    final cb = _charAt(b, j);
    if (!_isDigit(ca) && !_isDigit(cb)) return bias;
    if (!_isDigit(ca)) return -1;
    if (!_isDigit(cb)) return 1;
    if (ca < cb) {
      if (bias == 0) bias = -1;
    } else if (ca > cb) {
      if (bias == 0) bias = 1;
    }
    i++;
    j++;
  }
}

int _charAt(String s, int i) => i >= s.length ? 0 : s.codeUnitAt(i);

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isSpaceChar(int c) =>
    c == 0x20 ||
    c == 0xA0 ||
    (c >= 0x2000 && c <= 0x200B) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// 原版 `orderBySortMethod`：`method == TIME` 直接比 `channel_order_time` 降序；
/// 否则跑规则、最后自然序。
int _orderBySortMethod(
  ChannelDto left,
  ChannelDto right,
  ChannelSortMethod method,
  List<({bool Function(ChannelDto) rule, bool desc})> rules,
  String Function(ChannelDto) nameOf,
) {
  if (method == ChannelSortMethod.time) {
    return _compareOrder(left.channelOrderTime, right.channelOrderTime) * -1;
  }
  for (final r in rules) {
    final c = _compareRule(r.rule(left), r.rule(right), desc: r.desc);
    if (c != 0) return c;
  }
  return naturalCompare(nameOf(left), nameOf(right));
}

/// 同组内比较（原版 `compareSameViewTypeChannel`）
int compareInSection(
  SidebarSection section,
  ChannelDto left,
  ChannelDto right, {
  required ChannelSortPrefs prefs,
  required String Function(ChannelDto) nameOf,
  bool Function(ChannelDto)? failed,
}) {
  final isFailed = failed ?? (_) => false;
  final method = prefs.methodFor(section);
  switch (section) {
    case SidebarSection.unread:
      // 固定名称序，规则看 badge / 失败消息 / synobot / 加密
      return _orderBySortMethod(left, right, ChannelSortMethod.name, [
        (rule: (c) => channelBadgeNumber(c) > 0, desc: true),
        (rule: (c) => isFailed(c) && channelBadgeNumber(c) == 0, desc: false),
        (rule: (c) => c.type == 'synobot', desc: true),
        (rule: (c) => c.encrypted, desc: true),
      ], nameOf);
    case SidebarSection.favorite:
      return _orderBySortMethod(left, right, method, [
        (rule: (c) => c.type == 'synobot', desc: true),
        (rule: (c) => c.encrypted, desc: true),
      ], nameOf);
    case SidebarSection.channel:
      return _orderBySortMethod(left, right, method, [
        (rule: (c) => c.encrypted, desc: true),
      ], nameOf);
    case SidebarSection.chatbot:
      return _orderBySortMethod(left, right, method, [
        (rule: (c) => c.encrypted, desc: true),
      ], nameOf);
    case SidebarSection.synobot:
    case SidebarSection.conversation:
      // 原版 109 落在 switch 的 else 分支 → 用会话的排序偏好
      return _orderBySortMethod(left, right, method, [
        (rule: (c) => c.encrypted, desc: true),
      ], nameOf);
  }
}

/// 稳定排序（`List.sort` 不稳定，比较结果为 0 时按下标保持原顺序）
void _stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final r = compare(a.$2, b.$2);
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}

/// 一个分组（标题 + 频道）
class SidebarGroup {
  const SidebarGroup(this.section, this.channels);

  final SidebarSection section;
  final List<ChannelDto> channels;

  String? get title => section.title;
}

/// 把频道列表切成"侧栏分组"。
///
/// [failedChannelIds] = 有发送失败消息的频道（原版 `hasFailedPost`，
/// 它既影响分组也影响是否隐藏）。
///
/// 基列表先按 `名称升序` 排好（原版 DB 的
/// `ORDER BY ..., name ASC`），这样 `TIME` 在 `channel_order_time` 全为 0
/// （2.4.7 就是）时，稳定排序的结果与官方客户端一致。
List<SidebarGroup> buildSidebarGroups(
  List<ChannelDto> channels, {
  ChannelSortPrefs prefs = const ChannelSortPrefs(),
  Set<int> failedChannelIds = const {},
  int myUserId = 0,
  Map<int, UserDto> users = const {},
  String serverDefaultNotificationType = '',
}) {
  String nameOf(ChannelDto c) =>
      channelDisplayName(c, myUserId: myUserId, users: users);
  bool isFailed(ChannelDto c) => failedChannelIds.contains(c.channelId);
  final visible = channels
      .where(
        (c) => !c.hideAtSideBar(
          hasFailedPost: isFailed(c),
          serverDefaultNotificationType: serverDefaultNotificationType,
        ),
      )
      .toList();
  // 基序：名称升序（这就是原版 DB SQL 的 `..., name ASC`）。
  // Dart 的 `List.sort` 不稳定，所以自己补一个"下标兜底"，保证同名频道
  // 保持输入顺序、每次渲染结果一致。
  _stableSort(visible, (a, b) => naturalCompare(nameOf(a), nameOf(b)));

  final buckets = <SidebarSection, List<ChannelDto>>{};
  for (final c in visible) {
    final s = sectionOf(
      c,
      hasFailedPost: isFailed(c),
      serverDefaultNotificationType: serverDefaultNotificationType,
    );
    buckets.putIfAbsent(s, () => <ChannelDto>[]).add(c);
  }

  final groups = <SidebarGroup>[];
  for (final s in SidebarSection.values) {
    final list = buckets[s];
    if (list == null || list.isEmpty) continue;
    _stableSort(
      list,
      (a, b) => compareInSection(
        s,
        a,
        b,
        prefs: prefs,
        nameOf: nameOf,
        failed: isFailed,
      ),
    );
    groups.add(SidebarGroup(s, list));
  }
  return groups;
}
