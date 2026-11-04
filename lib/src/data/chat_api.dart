// Chat 业务 API —— 在 [DsmWebApi] 之上把 SYNO.Chat.* 的调用收敛成强类型方法。
//
// 版本协商照抄 APK 的 `Api.getMaxAvailableVersion(...)`：服务器声明的区间里
// 取「不超过 maxVersion 的最大候选版本」。例如 `SYNO.Chat.Channel` 传
// (5,4,2,1)：服务器 maxVersion=5 → 5；maxVersion=3 → 2；maxVersion=1 → 1。
//
// 逆向依据：
//   data/AccountManager.java fetchChannels / fetchUsers / getFetchChannelsCompound
//   data/remote/api/ChatChannel.java / ChatUser.java
library;

import '../core/json_coerce.dart';
import 'dart:convert';

import '../core/i18n/data_text.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/archive_dto.dart';
import 'dto/channel_dto.dart';
import 'dto/server_settings_dto.dart';
import 'dto/sticker_dto.dart';
import 'dto/user_dto.dart';
import 'dto/user_preference_dto.dart';
import 'remote/compound.dart';

/// `SYNO.Chat.*` 的高层封装。**不持有传输** —— 传输由 [DsmWebApi] 管。
/// 图片墙 `Post/list` 的 `attributes`（照抄 `AccountManager.fetchImagePosts`）
const kMediaAttributes = <String>[
  'post_id',
  'file_props',
  'message',
  'thread_id',
  'channel_id',
];

/// 媒体分类（真机实测只有这三种能当 `file_type` 用）
const kMediaImage = 'image';
const kMediaVideo = 'video';
const kMediaAudio = 'audio';

/// 视频 / 音频扩展名（`file_type` 分类筛不出来时的兜底）
const kVideoExtensions = <String>{
  'mp4',
  'mov',
  'mkv',
  'avi',
  'webm',
  '3gp',
  'm4v',
  'wmv',
  'flv',
};
const kAudioExtensions = <String>{
  'mp3',
  'wav',
  'aac',
  'm4a',
  'ogg',
  'oga',
  'flac',
  'amr',
  'opus',
};

/// 搜索条件（对应原 App 的 `Query`）
class PostSearchQuery {
  const PostSearchQuery({
    this.keyword = '',
    this.fromUsers = const [],
    this.inChannels = const [],
    this.hashtags = const [],
    this.mentions = const [],
    this.has = const [],
    this.fileTypes = const [],
    this.postTypes = const [],
    this.after = 0,
    this.before = 0,
    this.offset = 0,
    this.limit = 30,
  });

  /// 正文关键词
  final String keyword;

  /// 只搜这些用户（`from`）
  final List<int> fromUsers;

  /// 只搜这些频道（`in`）
  final List<int> inChannels;

  /// hashtag（不带 `#`）
  final List<String> hashtags;

  /// 提到的用户（`mention`）
  final List<int> mentions;

  /// `has` 过滤：`star` / `url` / `reaction` / `pin`；
  /// `file` / `vote` 在 v>=3 会被自动挪到 `post_type`（照抄 `AccountManager.search`）
  final List<String> has;

  /// `post_type`：`file` / `vote`
  final List<String> postTypes;

  /// 扩展名或分类（`["image"]` / `["png"]`）
  final List<String> fileTypes;

  final int after;
  final int before;
  final int offset;
  final int limit;

  bool get isEmpty =>
      keyword.trim().isEmpty &&
      fromUsers.isEmpty &&
      inChannels.isEmpty &&
      hashtags.isEmpty &&
      mentions.isEmpty &&
      has.isEmpty &&
      postTypes.isEmpty &&
      fileTypes.isEmpty &&
      after == 0 &&
      before == 0;

  PostSearchQuery copyWith({
    String? keyword,
    List<int>? fromUsers,
    List<int>? inChannels,
    List<String>? hashtags,
    List<int>? mentions,
    List<String>? has,
    List<String>? postTypes,
    List<String>? fileTypes,
    int? after,
    int? before,
    int? offset,
    int? limit,
  }) => PostSearchQuery(
    keyword: keyword ?? this.keyword,
    fromUsers: fromUsers ?? this.fromUsers,
    inChannels: inChannels ?? this.inChannels,
    hashtags: hashtags ?? this.hashtags,
    mentions: mentions ?? this.mentions,
    has: has ?? this.has,
    postTypes: postTypes ?? this.postTypes,
    fileTypes: fileTypes ?? this.fileTypes,
    after: after ?? this.after,
    before: before ?? this.before,
    offset: offset ?? this.offset,
    limit: limit ?? this.limit,
  );

  /// 一眼能看懂的筛选摘要（UI 上显示在结果上方）
  ///
  /// 数据层拿不到 `BuildContext`、也不能碰 `AppText`（纯 Dart 探针要能加载），
  /// 所以按 docs §4.6 走 `data_text.dart` 的 [dataText]。
  List<String> get labels {
    return [
      if (keyword.trim().isNotEmpty)
        dataText(
          'chatSearchKeyword',
          '「{x}」',
        ).replaceAll('{x}', keyword),
      for (final f in has) hasLabelText(f),
      for (final p in postTypes) postTypeLabelText(p),
      for (final f in fileTypes) f,
      if (fromUsers.isNotEmpty)
        dataText(
          'chatSearchFromUsers',
          '来自 {count} 人',
        ).replaceAll('{count}', '${fromUsers.length}'),
      if (inChannels.isNotEmpty)
        dataText(
          'chatSearchInChannels',
          '在 {count} 个频道',
        ).replaceAll('{count}', '${inChannels.length}'),
      if (hashtags.isNotEmpty)
        for (final h in hashtags) '#$h',
      if (mentions.isNotEmpty)
        dataText(
          'chatSearchMentions',
          '提到 {count} 人',
        ).replaceAll('{count}', '${mentions.length}'),
      if (after > 0 || before > 0) dataText('chatSearchByTime', '按时间'),
    ];
  }
}

/// `has` 过滤器（反编译 `AdvancedSearchFragment`：v3 起是这六个）
const kHasFilters = <String>['star', 'url', 'file', 'reaction', 'pin', 'vote'];

/// `has` 过滤器的中文文案（**回落**：无 context 的地方与老测试还用得上）。
///
/// 界面请用 [hasLabelText] 按当前语言取（`lib/src/features/**` 的界面本轮
/// 不在迁移范围内，所以这张表暂时保留，见 docs §4.4 第 4 条）。
const kHasLabels = <String, String>{
  'star': '星标',
  'url': '链接',
  'file': '文件',
  'reaction': '表情回应',
  'pin': '置顶',
  'vote': '投票',
};

/// `has` 过滤器 key → ARB key；认不出的键返回 null。
String? hasLabelKey(String key) => switch (key) {
  'star' => 'chatFilterStar',
  'url' => 'chatFilterUrl',
  'file' => 'chatFilterFile',
  'reaction' => 'chatFilterReaction',
  'pin' => 'chatFilterPin',
  'vote' => 'chatFilterVote',
  _ => null,
};

/// `has` 过滤器的当前语言文案；认不出的键**原样返回**（与老 `?? f` 一致）。
///
/// 数据层不能碰 `AppText`，所以走 `data_text.dart` 的 `dataText`。
String hasLabelText(String key) {
  final arbKey = hasLabelKey(key);
  final zh = kHasLabels[key];
  if (arbKey == null || zh == null) return key;
  return dataText(arbKey, zh);
}

/// 帖子类型的中文文案（**回落**，同 [kHasLabels]）
const kPostTypeLabels = <String, String>{'file': '文件', 'vote': '投票'};

/// 帖子类型的本地化文案；认不出的键**原样返回**
///
/// 与 [hasLabelText] 共用同一批 key（同一句中文共用同一个 key，见 §4.4）。
String postTypeLabelText(String key) {
  final arbKey = switch (key) {
    'file' => 'chatFilterFile',
    'vote' => 'chatFilterVote',
    _ => null,
  };
  final zh = kPostTypeLabels[key];
  if (arbKey == null || zh == null) return key;
  return dataText(arbKey, zh);
}

/// 搜索结果
class PostSearchResult {
  const PostSearchResult({
    required this.posts,
    this.total = 0,
    this.offset = 0,
    this.limit = 0,
  });

  final List<Map<String, dynamic>> posts;

  /// 命中总数（服务端的 `total`，用于"还有多少条"）
  final int total;
  final int offset;
  final int limit;

  bool get hasMore => offset + posts.length < total;

  static const empty = PostSearchResult(posts: []);
}

/// `SYNO.SAS.Guest:stat` v1 的响应（官方 `GuestAccountVo`）。
///
/// ★ 契约来自官方 `SynologyChat 2.11.1-607` 的 smali（**最硬来源**）：
/// * `data/remote/api/SasGuest.smali`：
///   `API = "SYNO.SAS.Guest"`、`STAT = "stat"`、`VERSION_1 = 0x1`
/// * `data/vo/GuestAccountVo.smali`：`data: GuestAccountData`
/// * `data/vo/GuestAccountVo$GuestAccountData.smali`：`username: String`
/// * `data/remote/WebApiService.smali` 的 `queryGuestAccount(...)` 注解：
///   `POST webapi/{path}` + `@FormUrlEncoded`，字段
///   `api` / `method` / `version` / **`email`**
///
/// ⇒ 官方访客登录 = **提交邮箱 → 服务端回该邮箱对应的访客 `username`**。
///
/// ⚠️ `stat` 是**只读查询**（不是"以访客登录"的写操作）：
/// 官方在登录页勾选访客框（`LoginActivity.mGuestBox`）后调它拿用户名。
class GuestAccount {
  const GuestAccount({required this.username});

  final String username;

  /// 官方只有一个字段 `username` ⇒ 缺失即视为解析失败。
  static GuestAccount? fromData(Map<String, dynamic> data) {
    final inner = data['data'];
    final u = inner is Map ? inner['username'] : null;
    if (u is! String || u.isEmpty) return null;
    return GuestAccount(username: u);
  }

  @override
  String toString() => 'GuestAccount($username)';
}

class ChatApi {
  ChatApi(DsmWebApi api) : api = api.withModule(TrafficModules.chat);

  final DsmWebApi api;

  /// `SYNO.SAS.Guest:stat` v1 —— 查某个邮箱对应的**访客账号名**。
  ///
  /// ★ 官方 smali 的 `WebApiService.queryGuestAccount` 只有一个业务字段
  /// **`email`**（其余是 `api`/`method`/`version`）⇒ 这里就只发 `email`，
  /// **不加任何猜测出来的参数**。
  ///
  /// ★ 版本：官方常量 `SasGuest.VERSION_1 = 0x1` ⇒ 写死 1。
  ///
  /// ⚠️ **没有 `.lib` 佐证**：`weblib/` 里**不存在** `SYNO.SAS*.lib`，
  /// 全库 grep `SYNO.SAS` **0 命中**（第 95 轮实测）
  /// ⇒ 本方法的唯一依据就是 APK smali 的 `VERSION_1`。
  /// （我最初在这里写过"`.lib` 里也只有 v1" —— **那是没核实就写的，已删除**。）
  Future<GuestAccount?> queryGuestAccount(String email) async {
    final data = await api.call(
      'SYNO.SAS.Guest',
      'stat',
      preferredVersion: 1,
      params: {'email': email},
    );
    return GuestAccount.fromData(data);
  }

  /// 候选版本里挑一个服务器真正支持的。
  ///
  /// [candidates] 从大到小排列（与原 App 的写法一致）。
  int negotiate(String apiName, List<int> candidates) {
    final entry = api.apiTable?[apiName];
    if (entry == null || candidates.isEmpty) {
      return candidates.isEmpty ? 1 : candidates.first;
    }

    final within = candidates.where(
      (c) => c >= entry.minVersion && c <= entry.maxVersion,
    );
    if (within.isNotEmpty) return within.reduce((a, b) => a > b ? a : b);

    // 服务器区间完全落在候选之外：退到服务器自己的上界/下界
    return entry.maxVersion < candidates.last
        ? entry.maxVersion
        : entry.minVersion;
  }

  /// `SYNO.Chat.Channel` 各方法的版本候选 —— 依据 **2.4.7-22203 `webapi/SYNO.Chat.lib`**：
  ///
  /// ```
  /// v1: rescue leave view hide list unstar star enter
  /// v2: + close + archive
  /// v3: 只有 list          ← ！v3/v4 上 hide/leave/star/view/enter/rescue 都不存在
  /// v4: list close hide_global get
  /// v5: 全集
  /// ```
  ///
  /// 所以**不能**整个 API 用一个协商版本：`get`/`hide_global` 只在 v4/v5；
  /// `hide`/`leave`/`star`/`unstar`/`view`/`enter`/`rescue` 只在 v1/v2/v5；
  /// `close` 在 v2/v4/v5；`archive` 在 v2/v5。原版也是分开写的
  /// （`closeChannel/archiveChannel/enterChannel` 写死 2，`starChannel` 用协商版本）。
  ///
  /// 每个列表从大到小，交给 [negotiate] 挑服务器真正支持的最大者。
  static const channelList = [5, 4, 2, 1];
  static const channelGet = [5, 4];
  static const channelHideGlobal = [5, 4];
  static const channelClose = [5, 4, 2];
  static const channelArchive = [5, 2];
  static const channelHide = [5, 2, 1];
  static const channelLeave = [5, 2, 1];
  static const channelStar = [5, 2, 1];
  static const channelView = [5, 2, 1];
  static const channelEnter = [5, 2, 1];
  static const channelRescue = [5, 2, 1];

  // ⚠️ `view`/`rescue` 的**调用点**故意仍用原版写死的版本（`view` v2、`rescue` v1）：
  // 那两条路径已有真机验证，v5 的参数/响应没实证过；上面表里给出的是"方法可用版本"，
  // 供新增的频道管理操作（hide/leave/star/archive/close/hide_global）取用。

  /// 服务器是否支持某个 API 的指定版本（原版 `ApiManager.support(api, ver)`）。
  ///
  /// `SYNO.Chat.Admin.Setting` 的 v3 = 已读回执、v4 = 可编辑任意消息。
  bool supports(String apiName, int version) {
    final entry = api.apiTable?[apiName];
    if (entry == null) return false;
    return entry.maxVersion >= version && entry.minVersion <= version;
  }

  /// `SYNO.Chat.Admin.Setting / get` —— 服务端下发的能力与限制。
  ///
  /// 原版 `AccountManager.fetchAdminSetting`：版本走 `getMaxAvailableVersion(4, 1)`。
  /// 真机实测（NAS 2.3.1，API 表 v1-5）返回 `file_size_limit`、`allow_encryption`、
  /// `allow_edit_message(+_time_within_min)`、`allow_read_status`、`notify_type` 等。
  Future<ServerSettings> fetchServerSettings() async {
    final data = await api.call(
      'SYNO.Chat.Admin.Setting',
      'get',
      preferredVersion: negotiate('SYNO.Chat.Admin.Setting', const [4, 3, 1]),
    );
    return ServerSettings.fromJson(data);
  }

  // ------------------------------------------------------------ 频道

  /// `SYNO.Chat.Channel / list`
  ///
  /// [isJoined] 取值对齐 `ChatChannel.VALUE_IS_JOINED_*`：
  /// `'true'`（已加入）、`'false'`（未加入）、`''`（全部）。
  Future<List<ChannelDto>> listChannels({String isJoined = 'true'}) async {
    final data = await api.call(
      'SYNO.Chat.Channel',
      'list',
      preferredVersion: negotiate('SYNO.Chat.Channel', channelList),
      params: {'is_joined': isJoined},
    );
    return _channelsOf(data);
  }

  /// `SYNO.Chat.Channel / get`，多个 id 用 compound 一次拿回。
  ///
  /// ⚠️ `get` 只存在于 v4/v5（v1/v2/v3 的方法表里没有，2.4.7 实测），
  /// 所以候选是 [channelGet]。服务器最高只到 v3 时这个接口**不存在** →
  /// 直接返回空表，让调用方保留本地已有数据，而不是发一个必然 103 的请求。
  Future<List<ChannelDto>> listChannelsByIds(List<int> channelIds) async {
    if (channelIds.isEmpty) return const [];
    final version = negotiate('SYNO.Chat.Channel', channelGet);
    if (!supports('SYNO.Chat.Channel', version) ||
        !channelGet.contains(version)) {
      return const [];
    }
    final results = await api.compound([
      for (final id in channelIds)
        ApiRequest(
          'SYNO.Chat.Channel',
          'get',
          version: version,
          params: {'channel_id': id},
        ),
    ]);
    final out = <ChannelDto>[];
    for (final r in results) {
      if (!r.success) continue; // 单个频道拿不到（被踢/已归档）不该拖垮整批
      final one = r.data?['channel'];
      if (one is Map) {
        out.add(ChannelDto.fromJson(Map<String, dynamic>.from(one)));
      }
    }
    return out;
  }

  // ------------------------------------------- 命名频道的创建 / 成员管理
  //
  // 全部落在 `SYNO.Chat.Channel.Named`（服务端只声明 v1）。创建加密频道的
  // **次序不能乱**（`tool/probe_make_e2ee_channel.dart` 摸出来的）：
  //   1. 客户端自己生成 32 字节频道密钥；
  //   2. `create`（`encrypted=true`）→ **只回 channel_id**，服务端此时没有任何密钥；
  //   3. `join` **必须带自己的 `channel_key_enc`**，否则
  //      `CHAT_ERR_CHANNEL_KEY_NOT_EXIST (421)`；
  //   4. `invite` 带 `user_ids` + `channel_key_encs`（每个成员各封一份）。
  // 这条链路由 [createNamedChannel]/[joinNamedChannel]/[inviteNamedChannel] 三个
  // 单独的方法暴露出来，让上层（控制器）显式按序调用 —— 顺序错了一次就废一个频道。

  static const int namedVersion = 1;

  /// `SYNO.Chat.Channel.Named / create` → 新频道 id
  Future<int> createNamedChannel({
    required String name,
    String purpose = '',
    String type = 'private',
    bool encrypted = false,
    String? channelKeyEnc,
  }) async {
    final data = await api.call(
      'SYNO.Chat.Channel.Named',
      'create',
      preferredVersion: namedVersion,
      params: {
        'name': name,
        'purpose': purpose,
        'type': type,
        'encrypted': encrypted ? 'true' : 'false',
        if (channelKeyEnc != null) 'channel_key_enc': channelKeyEnc,
      },
    );
    final id = data['channel_id'];
    return id is num ? id.toInt() : 0;
  }

  /// `SYNO.Chat.Channel.Named / join`（加密频道必须带自己的 `channel_key_enc`）
  Future<void> joinNamedChannel(int channelId, {String? channelKeyEnc}) async {
    await api.call(
      'SYNO.Chat.Channel.Named',
      'join',
      preferredVersion: namedVersion,
      params: {
        'channel_id': channelId,
        if (channelKeyEnc != null && channelKeyEnc.isNotEmpty)
          'channel_key_enc': channelKeyEnc,
      },
    );
  }

  /// `SYNO.Chat.Channel.Named / invite`
  ///
  /// [channelKeyEncs] 与 [userIds] **一一对应**（加密频道才有；
  /// 服务端按位置配对，少一个就有人进不来）。
  Future<void> inviteNamedChannel(
    int channelId, {
    required List<int> userIds,
    List<String> channelKeyEncs = const [],
  }) async {
    if (userIds.isEmpty) return;
    await api.call(
      'SYNO.Chat.Channel.Named',
      'invite',
      preferredVersion: namedVersion,
      params: {
        'channel_id': channelId,
        'user_ids': _jsonList(userIds),
        if (channelKeyEncs.isNotEmpty)
          'channel_key_encs': _jsonList(channelKeyEncs),
      },
    );
  }

  /// `SYNO.Chat.Channel.Named / kick`
  Future<void> kickNamedChannel(int channelId, int userId) async {
    await api.call(
      'SYNO.Chat.Channel.Named',
      'kick',
      preferredVersion: namedVersion,
      params: {'channel_id': channelId, 'user_id': userId},
    );
  }

  /// 一次踢多个：原版 `AccountManager.kickUsers` 走 `SYNO.Entry.Request request`
  /// v2 的 **parallel compound**，每个 user 一段 `Named/kick v1`。
  Future<void> kickNamedChannels(int channelId, List<int> userIds) async {
    if (userIds.isEmpty) return;
    final results = await api.compound([
      for (final uid in userIds)
        ApiRequest(
          'SYNO.Chat.Channel.Named',
          'kick',
          version: namedVersion,
          params: {'channel_id': channelId, 'user_id': uid},
        ),
    ]);
    // 整包成功 ≠ 每段成功，逐段检查（原版也是遍历 result 校验）
    for (final r in results) {
      r.ensureOk();
    }
  }

  /// `SYNO.Chat.Channel.Named / set`（改名/改用途）
  Future<void> setNamedChannel(
    int channelId, {
    String? name,
    String? purpose,
  }) async {
    if (name == null && purpose == null) return;
    await api.call(
      'SYNO.Chat.Channel.Named',
      'set',
      preferredVersion: namedVersion,
      params: {
        'channel_id': channelId,
        if (name != null) 'name': name,
        if (purpose != null) 'purpose': purpose,
      },
    );
  }

  /// `SYNO.Chat.Channel.Named / disjoin` —— 退出频道（服务端没有 delete/close）
  Future<void> disjoinNamedChannel(int channelId) async {
    await api.call(
      'SYNO.Chat.Channel.Named',
      'disjoin',
      preferredVersion: namedVersion,
      params: {'channel_id': channelId},
    );
  }

  // ------------------------------------------------------ 话题订阅
  //
  // `SYNO.Chat.Post.Subscribe`（v1 只有 create/delete；`view` 原版有常量但没用）。
  // 参数就一个 `post_id` —— 翻开反编译的 `WebApiService.subscribe/unsubscribe`
  // 签名确认过：`@Field("post_id")`，没有 channel_id。

  /// `SYNO.Chat.Post.Subscribe / create`
  Future<void> subscribePost(int postId) async {
    await api.call(
      'SYNO.Chat.Post.Subscribe',
      'create',
      preferredVersion: 1,
      params: {'post_id': postId},
    );
  }

  /// `SYNO.Chat.Post.Subscribe / delete`
  Future<void> unsubscribePost(int postId) async {
    await api.call(
      'SYNO.Chat.Post.Subscribe',
      'delete',
      preferredVersion: 1,
      params: {'post_id': postId},
    );
  }

  /// `SYNO.Chat.User / set`（v1）—— 改自己的资料。
  ///
  /// ⚠️ 有**两条路**，语义不同（原版就是两个重载）：
  ///   * 带新头像 → **multipart**（`AccountManager#setUser(nickname, desc, email, File)`），
  ///     `api/method/version` 在查询串，字段在 body，头像字段名 `avatar`、文件名 `blob`；
  ///   * **移除头像** → 先 `SYNO.Personal.Profile.Photo / delete`，再走
  ///     **form-urlencoded** 的 `User/set`（`remove_avatar=true`，
  ///     nickname/description/email 走 `gson.toJson` 即**带引号**）。
  /// 响应都是 `{data: <user>}`。
  ///
  /// 字段编码**两条路确实不同**，这是官方实现（不是笔误）—— 已对照 APK 反编译
  /// `AccountManager.java`（`/tmp/syno_apk/jadx_out`）：
  ///   * multipart 分支（`setUser(String,String,String,File)`，约 :2597）：
  ///     `new SyMultipartBody.Builder()...addFormDataPart("nickname", str)
  ///      .addFormDataPart("description", str2).addFormDataPart("email", str3)`
  ///     → **裸值**（没有 `gson.toJson`）；
  ///   * form 分支（`removeAvatar(...)`，约 :2676）：
  ///     `webApiService.setUser(..., gson.toJson(str), gson.toJson(str2),
  ///      gson.toJson(str3), z)` → **带引号**。
  /// 所以本函数 multipart 传裸值、form 传 `jsonEncode` 都是对的。
  Future<Map<String, dynamic>> setUserProfile({
    required String nickname,
    String description = '',
    String email = '',
    String? avatarPath,
    bool removeAvatar = false,
    void Function(int sent, int total)? onProgress,
  }) async {
    Map<String, dynamic> data;
    if (removeAvatar) {
      data = await api.call(
        'SYNO.Chat.User',
        'set',
        preferredVersion: 1,
        params: {
          'nickname': jsonEncode(nickname),
          'description': jsonEncode(description),
          'email': jsonEncode(email),
          'remove_avatar': 'true',
        },
      );
    } else {
      final body = await api.postMultipart(
        api.apiPath('SYNO.Chat.User'),
        query: {'api': 'SYNO.Chat.User', 'method': 'set', 'version': '1'},
        fields: {
          'nickname': nickname,
          'description': description,
          'email': email,
        },
        fileField: avatarPath == null ? null : 'avatar',
        filePath: avatarPath,
        fileName: avatarPath == null ? null : 'blob',
        mimeType: avatarPath == null ? null : 'application/octet-stream',
        onProgress: onProgress,
      );
      data = api.decodeData(body, 'SYNO.Chat.User.set');
    }
    final user = data['data'] ?? data;
    return user is Map ? Map<String, dynamic>.from(user) : data;
  }

  /// 删除自己的头像 —— `SYNO.Personal.Profile.Photo / delete`（v1）。
  ///
  /// 逆向依据 `AccountManager#removeAvatar`：先删头像，再用 `User/set`
  /// 提交一次资料（原版就是这么两步）。真机实测这台 NAS 上该 API 存在（v1-2）。
  Future<void> deleteProfilePhoto() async {
    await api.call(
      'SYNO.Personal.Profile.Photo',
      'delete',
      preferredVersion: 1,
      params: const {},
    );
  }

  /// 取某个用户的头像字节 —— `SYNO.Chat.User.Avatar / get`（v1）。
  ///
  /// 官方事实来源（两处交叉验证）：
  ///   * Chat 服务端包 `Chat-x86_64-2.4.7-22203`（`/tmp/spk` 解包，脚本见
  ///     `synology-spk` skill）：`SYNO.Chat.User.Avatar maxVersion=1`，
  ///     方法表 **v1 只有 `get`**；
  ///   * APK 反编译 `data/remote/StreamService.java:24`：
  ///     `@FormUrlEncoded @POST("webapi/{path}") getAvatar(path, api, method,
  ///     version, user_id, type, v)` —— 三个业务字段是
  ///     **`user_id` / `type`(S|M|L) / `v`**（`v` = `UserVo.avatar_version`，
  ///     `AccountManager.fetchAvatar(userId, type, version)` 原样发）。
  ///
  /// 注意是 **POST 表单**（不是 GET 查询串），所以走 [DsmWebApi.postBytesForm]
  /// —— 参数在 body、`_sid` 由传输层补、CSRF 走头。
  ///
  /// 返回 `[]` 表示服务端认为没有头像（或这个 API 不存在），调用方回退到
  /// `avatar_color` + 首字母（对齐原版 `AvatarLoader` 的 `avatar_version<=0`
  /// 分支）。
  Future<List<int>> fetchUserAvatar({
    required int userId,
    required int version,
    String type = 'S',
  }) => api.postBytesForm(api.apiPath('SYNO.Chat.User.Avatar'), {
    'api': 'SYNO.Chat.User.Avatar',
    'method': 'get',
    'version': '1',
    'user_id': '$userId',
    'type': type,
    'v': '$version',
  });

  /// `SYNO.Chat.Post / get_read_status`（**v6**）—— 一条消息谁读了 / 谁没读。
  ///
  /// 反编译依据：`AccountManager.fetchReadUsers` 固定用 `ChatPost.API` 的
  /// **version 6** + `post_id`；响应 `ReadStatusVo.data = {read_users, unread_users}`。
  /// 只有**自己发的**消息才允许查（原版 ActionSheet 的
  /// `isAllowShowReadStatus = allowReadStatus && post.user().userId == myUserId`）。
  Future<({List<int> readUsers, List<int> unreadUsers})> fetchReadStatus(
    int postId,
  ) async {
    final data = await api.call(
      'SYNO.Chat.Post',
      'get_read_status',
      preferredVersion: 6,
      params: {'post_id': postId},
    );
    List<int> ids(Object? raw) => raw is List
        ? raw
              .map((e) => e is num ? e.toInt() : int.tryParse('$e') ?? 0)
              .where((e) => e > 0)
              .toList()
        : const <int>[];
    return (
      readUsers: ids(data['read_users']),
      unreadUsers: ids(data['unread_users']),
    );
  }

  /// `SYNO.Chat.Channel.Member / get`（v1）—— 频道成员。
  ///
  /// 注意：**`Channel/get` 不带成员**（真机实测 `members: []`），成员要单独问这个 API；
  /// `broken_user_ids` 是"加入过但拿不到频道密钥"的人（E2EE 频道才有）。
  Future<({List<int> userIds, List<int> brokenUserIds})> listChannelMembers(
    int channelId,
  ) async {
    final data = await api.call(
      'SYNO.Chat.Channel.Member',
      'get',
      preferredVersion: 1,
      params: {'channel_id': channelId},
    );
    List<int> ids(Object? raw) => raw is List
        ? raw
              .map((e) => e is num ? e.toInt() : int.tryParse('$e') ?? 0)
              .where((e) => e > 0)
              .toList()
        : const <int>[];
    return (
      userIds: ids(data['user_ids']),
      brokenUserIds: ids(data['broken_user_ids']),
    );
  }

  /// `SYNO.Chat.Misc / acl`（v1）—— 我这个账号的权限表。
  ///
  /// 原版 `AccountManager.fetchAcl`：`{acls: [{acl_name, allow}]}`，
  /// 存到**自己**的用户行上，之后 `User.hasPrivilege(name)` 用它判，
  /// **表里没有的 key 默认允许**（`hasPrivilege` 查不到就 return true）。
  Future<Map<String, bool>> fetchAcl() async {
    final data = await api.call('SYNO.Chat.Misc', 'acl', preferredVersion: 1);
    final out = <String, bool>{};
    final list = data['acls'];
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map) continue;
        final name = '${raw['acl_name'] ?? ''}';
        if (name.isEmpty) continue;
        out[name] = raw['allow'] == true;
      }
    }
    return out;
  }

  /// `SYNO.Chat.Channel / star` / `unstar` —— 收藏频道。
  ///
  /// 逆向依据 `AccountManager.starChannel`：
  /// `new Channel.Builder().channelId(i).build(star ? "star" : "unstar", api.requestFormat)`
  /// → 版本**写死 1**（`Channel.build(method, String)` 内部是 `build(method, 1, ...)`），
  /// 参数只有 `channel_id`。第二个参数是 `@RequestFormat`（服务端下发的 "JSON"），
  /// 只影响 `@Param` 字段是否再 JSON 编码一次；`channel_id` 是 int，编码前后字节相同，
  /// 所以我们按普通表单发即可（真机已验证）。
  Future<void> starChannel(int channelId, {bool star = true}) async {
    await api.call(
      'SYNO.Chat.Channel',
      star ? 'star' : 'unstar',
      preferredVersion: 1,
      params: {'channel_id': channelId},
    );
  }

  /// `SYNO.Chat.Channel / enter` —— 告诉服务端"这条 socket 连接正在看这个频道"。
  ///
  /// 逆向依据 `AccountManager.enterChannel`：
  /// `enterChannel(path, api, "enter", api.getMaxAvailableVersion(2, 1), channel_id,
  ///  gson.toJson(connId))` —— **版本写死 2**（和 `view`/`close` 一样不是 5），
  /// `conn_id` 是 **Gson 编码过的字符串**（带引号）。原版在
  /// `ChannelFragment.enterChannel()` 里每次进频道页都会调，成功后紧接着
  /// `fetchChannelHashtag`；`MainPresenter.enterChosenChannel` 在深链回跳时也会调。
  ///
  /// 没有 conn_id 时原版直接报 `emptyConnId`（不发请求），这里保持一致。
  Future<void> enterChannel(int channelId, String connId) async {
    if (connId.isEmpty) {
      // 原版 `ApiException.emptyConnId` → code 101（badRequest）
      throw DsmApiException(
        DsmErrorCode.badRequest,
        method: 'SYNO.Chat.Channel/enter',
      );
    }
    await api.call(
      'SYNO.Chat.Channel',
      'enter',
      preferredVersion: negotiate('SYNO.Chat.Channel', const [2, 1]),
      params: {'channel_id': '$channelId', 'conn_id': _jsonString(connId)},
    );
  }

  /// `SYNO.Chat.Channel / hide`（服务端记 `last_hide_at`，来新消息会自己冒回来）。
  ///
  /// ⚠️ 原版 Android 客户端**从不**调用它（`hide` 只存在于服务端方法表和
  /// web/desktop 客户端）：Android 侧只被动接收 `client.channel.hide_global` /
  /// `unhide_global`，靠 `hideAtSideBar()` 过滤。这里保留实现但 UI 不暴露。
  Future<void> hideChannel(int channelId) async {
    await api.call(
      'SYNO.Chat.Channel',
      'hide',
      preferredVersion: negotiate('SYNO.Chat.Channel', channelHide),
      params: {'channel_id': channelId},
    );
  }

  /// `SYNO.Chat.Channel / archive` —— 归档频道。
  ///
  /// 逆向依据 `AccountManager.archiveChannel`：**要求 `maxVersion >= 2`**，
  /// 而且**版本写死 2**（不是协商版本），参数 `channel_id`。
  /// （归档后频道从"已加入"列表消失，在 `Archive/list` 里能看到。）
  Future<void> archiveChannel(int channelId) async {
    if (!supports('SYNO.Chat.Channel', 2)) {
      throw DsmApiException(
        DsmErrorCode.notSupportedVersion,
        method: 'SYNO.Chat.Channel/archive',
      );
    }
    await api.call(
      'SYNO.Chat.Channel',
      'archive',
      preferredVersion: 2,
      params: {'channel_id': channelId},
    );
  }

  /// `SYNO.Chat.Channel / close` —— 关闭频道/会话（不可逆，服务端会删数据）。
  ///
  /// 逆向依据 `AccountManager.closeChannel`：要求 `maxVersion >= 2`、版本写死 2，
  /// 参数 `channel_id` + **`conn_id`**（服务端要靠它把在线端踢下线）。
  Future<void> closeChannel(int channelId, {required String connId}) async {
    if (!supports('SYNO.Chat.Channel', 2)) {
      throw DsmApiException(
        DsmErrorCode.notSupportedVersion,
        method: 'SYNO.Chat.Channel/close',
      );
    }
    await api.call(
      'SYNO.Chat.Channel',
      'close',
      preferredVersion: 2,
      params: {'channel_id': channelId, 'conn_id': _jsonString(connId)},
    );
  }

  // ------------------------------------------------------------ 用户

  /// `SYNO.Chat.User / list` —— human 与 bot 各一次，compound 并发。
  Future<List<UserDto>> listUsers() async {
    final version = negotiate('SYNO.Chat.User', const [2, 1]);
    final results = await api.compound([
      ApiRequest(
        'SYNO.Chat.User',
        'list',
        version: version,
        params: {'type': 'human'},
      ),
      ApiRequest(
        'SYNO.Chat.User',
        'list',
        version: version,
        params: {'type': 'bot'},
      ),
    ]);
    final out = <UserDto>[];
    for (final r in results) {
      if (!r.success) continue;
      out.addAll(_usersOf(r.data));
    }
    return out;
  }

  /// `SYNO.Chat.User / list`，指定 user_id 列表（`user_ids` 是 JSON 数组字符串）
  Future<List<UserDto>> listUsersByIds(List<int> userIds) async {
    if (userIds.isEmpty) return const [];
    final data = await api.call(
      'SYNO.Chat.User',
      'list',
      preferredVersion: negotiate('SYNO.Chat.User', const [2, 1]),
      params: {'type': 'human', 'user_ids': _jsonList(userIds)},
    );
    return _usersOf(data);
  }

  /// `SYNO.Chat.User / login`（v1）—— 登录后的**第一步**。
  ///
  /// 原版 `LoginPresenter` 的链路是 `Auth/login → SYNO.Chat.User/login → 列表 →
  /// socket`，这一步拿三样东西：
  ///   * `current_time`：和服务端校时（消息时间戳/已读时间都按它算）；
  ///   * `db_uuid`：服务端数据库标识，变了说明服务端重装过，本地缓存要清；
  ///   * `user.user_id` / `user.is_admin`：我是谁、是不是管理员。
  Future<ChatUserLogin> userLogin() async {
    final data = await api.call(
      'SYNO.Chat.User',
      'login',
      preferredVersion: negotiate('SYNO.Chat.User', const [1]),
    );
    return ChatUserLogin.fromJson(data);
  }

  /// `SYNO.Chat.User / get` —— 自己
  Future<UserDto?> myUser() async {
    final data = await api.call(
      'SYNO.Chat.User',
      'get',
      preferredVersion: negotiate('SYNO.Chat.User', const [3, 2, 1]),
    );
    final me = data['user'] ?? data;
    if (me is Map) return UserDto.fromJson(Map<String, dynamic>.from(me));
    return null;
  }

  // ------------------------------------------------------- 用户偏好（免打扰）

  /// 通知"没设口令"的成员 `SYNO.Chat.User / notify_encrypt` v1。
  ///
  /// 原版 `AccountManager.notifyEncrypt`：把**因为没配端到端加密口令而被移出**
  /// 加密频道邀请列表的 userId 列表发上去（`user_ids` 是 Gson 序列化的 **JSON 数组**，
  /// 例如 `[15,16]`），服务端再去提醒这些人去设置口令
  /// （`NamedCreateFragment.removeNoPassphraseUsers` → `notifyHolder.notifyBox`）。
  ///
  /// 版本 v1；失败也不影响邀请本身（原版订阅里只有日志）。
  Future<void> notifyEncrypt(List<int> userIds) async {
    if (userIds.isEmpty) return;
    await api.call(
      'SYNO.Chat.User',
      'notify_encrypt',
      preferredVersion: 1,
      params: {'user_ids': _jsonList(userIds)},
    );
  }

  /// `SYNO.Chat.User.Preference / get` —— 免打扰（snooze）等用户级偏好。
  ///
  /// 版本：原版 `AccountManager.getSnooze` 用 `maxAvailableVersion(3, 1)`
  /// （最多 v3、最少 v1），我们照抄；真机这台 maxVersion=4，v1~v4 返回同一份
  /// preferences（v4 多几个字段），所以锁 3 不会有信息损失。
  Future<UserPreferenceDto> userPreferenceGet() async {
    final data = await api.call(
      'SYNO.Chat.User.Preference',
      'get',
      preferredVersion: negotiate('SYNO.Chat.User.Preference', const [3, 2, 1]),
    );
    return UserPreferenceDto.fromJson(data);
  }

  /// `SYNO.Chat.User.Preference / set`（**v1**）—— 只写 `snooze`。
  ///
  /// `epochMillis` 必须是**服务端时钟**的绝对毫秒（原版
  /// `setSnooze = System.currentTimeMillis() + timeDiff + duration`），0 = 取消免打扰。
  /// 版本锁 v1 是照抄原版：免打扰这条路它一直用 v1，v2/v3 的 set 是给定时免打扰用的。
  Future<void> setUserSnooze(int epochMillis) async {
    await api.call(
      'SYNO.Chat.User.Preference',
      'set',
      preferredVersion: negotiate('SYNO.Chat.User.Preference', const [1]),
      params: {'snooze': epochMillis},
    );
  }

  /// `SYNO.Chat.User.Preference / set`（**v3**）—— 定时免打扰。
  ///
  /// `startSecond` / `endSecond` 是**当天秒数**（原版 `ScheduleSnoozeFragment`
  /// 的 `mStartTimeSecond`）。原版要求 `api.maxVersion >= 3`，不支持就报版本错
  /// （`ApiException.apiVersionNotSupport`）—— 老服务端上界面也不显示这一项。
  Future<void> setUserSnoozeSchedule({
    required bool enable,
    required int startSecond,
    required int endSecond,
  }) async {
    if (!supports('SYNO.Chat.User.Preference', 3)) {
      throw DsmApiException(
        DsmErrorCode.notSupportedVersion,
        method: 'SYNO.Chat.User.Preference.set',
      );
    }
    await api.call(
      'SYNO.Chat.User.Preference',
      'set',
      preferredVersion: 3,
      params: {
        'snooze_schedule_enable': enable,
        'snooze_schedule_start': startSecond,
        'snooze_schedule_end': endSecond,
      },
    );
  }

  // ------------------------------------------------------------ 发消息

  /// `SYNO.Chat.Post / create`
  ///
  /// 参数形态照抄 `AccountManager.createServerPost`：
  /// `conn_id` / `message` / `type` / `mobile_token` 都要**再 JSON 序列化一次**，
  /// `thread_id` 为 null 时整个字段不发（对应 Retrofit 的可空 @Field）。
  ///
  /// 注意：未加密频道 message 可以是裸字符串；E2EE 频道的密文封装在 Phase 7 接。
  Future<Map<String, dynamic>> createPost({
    required int channelId,
    required String message,
    required String connId,
    int? threadId,
    bool isThread = false,
    // 原库 ChatPost.NORMAL = "normal"；传别的值服务端会当成 "system"
    String type = 'normal',
    String? mobileToken,
  }) async {
    final params = <String, String>{
      'channel_id': '$channelId',
      'conn_id': _jsonString(connId),
      // ⚠️ `type` 是**裸值**：原版 `AccountManager.createServerPost` 直接传
      // `post.type()`，只有 conn_id / message 走 Gson（见 2.11.1 源码）。
      // 之前发的是 `"normal"`（带引号），服务端容错才没暴露。
      'type': type,
      'message': _jsonString(message),
      'is_thread': isThread ? 'true' : 'false',
      'mobile_token': _jsonString(mobileToken ?? ''),
    };
    if (threadId != null && threadId != 0) {
      params['thread_id'] = '$threadId';
    }
    final data = await api.call(
      'SYNO.Chat.Post',
      'create',
      preferredVersion: negotiate('SYNO.Chat.Post', const [7, 4, 1]),
      params: params,
    );
    final post = data['post'] ?? data;
    return post is Map ? Map<String, dynamic>.from(post) : data;
  }

  /// `SYNO.Chat.Post / create` 的**上传分支** —— 带附件的消息。
  ///
  /// 逆向依据 `AccountManager.createPost()` 的重载：元数据全部拼在**查询串**上
  /// （`api`/`method`/`version`/`channel_id`/`thread_id`/`is_thread`/
  /// `voice_msg_length`），multipart body 里是
  /// `conn_id` + `type=file` + `message` + `file`。
  /// 注意 body 里的 `type` 是**普通表单字段**（值为 `file`），
  /// 跟 `Post/create` 的 `type` 参数（`normal`）不是一回事。
  Future<Map<String, dynamic>> uploadPost({
    required int channelId,
    required String connId,
    required String filePath,
    required String fileName,
    String message = '',
    String? mimeType,
    int? threadId,
    bool isThread = false,
    int? voiceMsgLength,
    void Function(int sent, int total)? onProgress,
  }) async {
    final query = <String, dynamic>{
      'api': 'SYNO.Chat.Post',
      'method': 'create',
      'version': '${negotiate('SYNO.Chat.Post', const [7, 4, 1])}',
      'channel_id': '$channelId',
      if (threadId != null && threadId != 0) 'thread_id': '$threadId',
      if (isThread) 'is_thread': 'true',
      if (voiceMsgLength != null && voiceMsgLength > 0)
        'voice_msg_length': '$voiceMsgLength',
    };
    final body = await api.postMultipart(
      api.apiPath('SYNO.Chat.Post'),
      query: query,
      fields: {
        'conn_id': connId,
        'type': 'file',
        // ⚠️ multipart 这条路上服务端**不做 JSON 解码**，会把你发的字符串原样存下来。
        // 实测：发 `"\"hi\""` 存成 `"\"hi\""`（带引号），发裸 `hi` 才存成 `hi`。
        // 表单那条路相反（发 JSON 编码的，服务端会剥引号）——
        // 两条路行为不一致，见 docs/phase5-protocol.md §4。
        'message': message,
      },
      fileField: 'file',
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType ?? 'application/octet-stream',
      onProgress: onProgress,
    );
    final data = api.decodeData(body, 'SYNO.Chat.Post.create');
    final post = data['post'] ?? data;
    return post is Map ? Map<String, dynamic>.from(post) : data;
  }

  /// 附件下载 / 缩略图的**带鉴权 URL**（`_sid` 挂在查询串上）。
  ///
  /// 逆向依据 `AccountManager.getStreamingUrlOfPostId` / `fetchThumbnail`：
  ///   * 原图走 `method=get`（v1），只带 `post_id` + `_sid`；
  ///   * `method=thumbnail`（v1）的 `type` 是**尺寸串**，不是 MIME：
  ///     `S` 小图标 / `M` 列表 / `L` 气泡大图 / `XL` 原图级 —— Android 端
  ///     `CommonViewBinder` 传 "S"、`DownloadFragment` 传 "XL"，服务端自己的
  ///     Web 客户端也是这四个值（`ui/synochat-common.js` 里 `getImageUrl(id,"M")`）。
  String fileUrl(int postId, {bool thumbnail = false, String? size}) {
    final params = <String, String>{
      'api': 'SYNO.Chat.Post.File',
      'method': thumbnail ? 'thumbnail' : 'get',
      'version': '1',
      'post_id': '$postId',
      if (thumbnail && size != null && size.isNotEmpty) 'type': size,
    };
    return api.authenticatedUrl(api.apiPath('SYNO.Chat.Post.File'), params);
  }

  /// 缩略图尺寸串（原版取值）
  static const String thumbSmall = 'S';
  static const String thumbMedium = 'M';
  static const String thumbLarge = 'L';
  static const String thumbOriginal = 'XL';

  /// 下载附件字节（"另存为/打开"用）
  Future<List<int>> downloadPostFile(
    int postId, {
    bool thumbnail = false,
    String? size,
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
  }) => api.getBytes(
    fileUrl(postId, thumbnail: thumbnail, size: size),
    onProgress: onProgress,
    cancelToken: cancelToken,
  );

  /// 链接预览图/站点的**带鉴权 URL** —— 走服务端的 OG 代理。
  ///
  /// 逆向依据 `AccountManager#fetchOG`（`Post.File / og` v1）+ `OGLoader`：
  /// `image` 和 `favicon` 都是**外链**，原版一律经这个代理取（不直连外网）。
  /// `url` 要**再 JSON 序列化一次**（`gson.toJson(url)`）—— 真机实测：
  /// 少这对引号服务端会 400。
  ///
  /// 真机验证（2.4.6 NAS）：GET + 查询串 + `_sid` 就能拿到 PNG 字节
  /// （`Post.File / og` 同时支持 POST，我们用现成的 `getBytes` 走 GET）。
  String ogImageUrl(int postId, String url) =>
      api.authenticatedUrl(api.apiPath('SYNO.Chat.Post.File'), {
        'api': 'SYNO.Chat.Post.File',
        'method': 'og',
        'version': '1',
        'post_id': '$postId',
        'url': jsonEncode(url),
      });

  /// 取链接预览图/站点图标的字节（服务端代理抓的）
  Future<List<int>> downloadOgImage(
    int postId,
    String url, {
    void Function(int received, int total)? onProgress,
  }) => api.getBytes(ogImageUrl(postId, url), onProgress: onProgress);

  // ---------------------------------------------------------------- 贴纸
  //
  // 反编译依据 `AccountManager.fetchStickers/fetchSticker` + `StreamService`：
  //   * `SYNO.Chat.Sticker / list` **v1**（原版写死 1，v2 才带 emoji 分类）
  //   * 图片：`GET {base}sc/stickers/{sticker_id}/{size}`，size ∈ 1x|2x|4x
  //     ⚠️ 真机实测：这条**不能挂 `_sid`**（挂了回 HTML），只能靠 cookie。

  /// 符号目录（`list` v1）。服务端没有这个 API 时抛 [DsmApiException]
  Future<StickerCatalog> fetchStickers() async {
    final data = await api.call(
      'SYNO.Chat.Sticker',
      'list',
      preferredVersion: 1,
      params: const {},
    );
    return StickerCatalog.parse(data);
  }

  bool get supportsStickers => supports('SYNO.Chat.Sticker', 1);

  /// 贴纸图片直链。**不带 `_sid`**：静态资源只认 cookie，
  /// 挂了 `_sid` 服务端会回 HTML（真机实测，见 `docs/phase5-protocol.md` §13）。
  String stickerImageUrl(int stickerId, {String size = '2x'}) =>
      '${api.baseUrl}sc/stickers/$stickerId/$size';

  /// 取贴纸图片字节（走 cookie，不带 `_sid`）
  Future<List<int>> downloadSticker(
    int stickerId, {
    String size = '2x',
    void Function(int received, int total)? onProgress,
  }) => api.getBytes(
    stickerImageUrl(stickerId, size: size),
    onProgress: onProgress,
  );

  /// `SYNO.Chat.Post / delete`
  Future<void> deletePost(int postId) async {
    await api.call(
      'SYNO.Chat.Post',
      'delete',
      preferredVersion: negotiate('SYNO.Chat.Post', const [8, 1]),
      params: {'post_id': '$postId'},
    );
  }

  /// `SYNO.Chat.Post / set` —— 编辑消息
  ///
  /// 逆向依据 `AccountManager.editPost`：版本 `getMaxAvailableVersion(8, 4, 1)`，
  /// `message` 再 JSON 序列化一次；加密频道要先 sodium 加密（Phase 7）。
  Future<void> editPost({
    required int postId,
    required String message,
    required int channelId,
    int? threadId,
  }) async {
    final params = <String, String>{
      'channel_id': '$channelId',
      'post_id': '$postId',
      'message': _jsonString(message),
    };
    if (threadId != null && threadId != 0) params['thread_id'] = '$threadId';
    await api.call(
      'SYNO.Chat.Post',
      'set',
      preferredVersion: negotiate('SYNO.Chat.Post', const [8, 4, 1]),
      params: params,
    );
  }

  /// `SYNO.Chat.Post / star` / `unstar`（收藏）
  Future<void> starPost(int postId, {bool star = true}) async {
    await api.call(
      'SYNO.Chat.Post',
      star ? 'star' : 'unstar',
      preferredVersion: negotiate('SYNO.Chat.Post', const [1]),
      params: {'post_id': '$postId'},
    );
  }

  /// `SYNO.Chat.Post / pin` / `unpin`（消息置顶）—— **v1**。
  ///
  /// 原版 `AccountManager.pinPost` 走的就是这两个方法（v1），成功后本地写的是
  /// `last_pin_at`；它和话题的 `stick`（v2，写 `is_sticky`）是**两回事**：
  /// 我们之前把 stick 当成置顶用，服务端回 407，于是误判"置顶不支持"。
  Future<void> pinPost(int postId, {bool pin = true}) async {
    await api.call(
      'SYNO.Chat.Post',
      pin ? 'pin' : 'unpin',
      preferredVersion: negotiate('SYNO.Chat.Post', const [1]),
      params: {'post_id': '$postId'},
    );
  }

  /// `SYNO.Chat.Post / stick` / `unstick`（**话题**置顶）—— 要求 Post API ≥ v2
  Future<void> stickPost(int postId, {bool stick = true}) async {
    await api.call(
      'SYNO.Chat.Post',
      stick ? 'stick' : 'unstick',
      preferredVersion: negotiate('SYNO.Chat.Post', const [2]),
      params: {'post_id': '$postId'},
    );
  }

  /// `SYNO.Chat.Post.Reaction / set` —— 表情回应
  ///
  /// 两个重载对应两种入参：内置表情用 `sticker_id`，自定义贴纸用 `sticker_name`。
  Future<void> setReaction({
    required int postId,
    int? stickerId,
    String? stickerName,
  }) async {
    final params = <String, String>{'post_id': '$postId'};
    if (stickerId != null && stickerId != 0) {
      params['sticker_id'] = '$stickerId';
    } else if (stickerName != null && stickerName.isNotEmpty) {
      params['sticker_name'] = stickerName;
    } else {
      throw ArgumentError(
        dataText(
          'apiSetReactionNeedsSticker',
          'setReaction 需要 stickerId 或 stickerName',
        ),
      );
    }
    await api.call(
      'SYNO.Chat.Post.Reaction',
      'set',
      preferredVersion: negotiate('SYNO.Chat.Post.Reaction', const [1]),
      params: params,
    );
  }

  /// `SYNO.Chat.Post.Reaction / delete` —— 取消回应
  ///
  /// 与 [setReaction] 一样是**两个重载二选一**（`WebApiService.java:134/138`：
  /// 一个 `@Field("sticker_id")`、一个 `@Field("sticker_name")`）——
  /// 两个都不给是**客户端 bug**，直接抛而不是发一条只有 `post_id` 的废请求。
  Future<void> deleteReaction({
    required int postId,
    int? stickerId,
    String? stickerName,
  }) async {
    final params = <String, String>{'post_id': '$postId'};
    if (stickerId != null && stickerId != 0) {
      params['sticker_id'] = '$stickerId';
    } else if (stickerName != null && stickerName.isNotEmpty) {
      params['sticker_name'] = stickerName;
    } else {
      throw ArgumentError(
        dataText(
          'apiDeleteReactionNeedsSticker',
          'deleteReaction 需要 stickerId 或 stickerName',
        ),
      );
    }
    await api.call(
      'SYNO.Chat.Post.Reaction',
      'delete',
      preferredVersion: negotiate('SYNO.Chat.Post.Reaction', const [1]),
      params: params,
    );
  }

  /// `SYNO.Chat.Post / forward` —— 转发到若干频道（`channel_ids` 是 JSON 数组串）
  Future<void> forwardPost({
    required int postId,
    required List<int> channelIds,
  }) async {
    await api.call(
      'SYNO.Chat.Post',
      'forward',
      preferredVersion: negotiate('SYNO.Chat.Post', const [3]),
      params: {'post_id': '$postId', 'channel_ids': _jsonList(channelIds)},
    );
  }

  /// `SYNO.Chat.Post / thread_list` —— 频道里的话题列表（v5）
  ///
  /// `offset` / `limit` / `related_comment_count` 都是**再 JSON 序列化一次**的
  /// 标量字符串，对齐 `AccountManager.fetchThreadList`。
  ///
  /// **响应形状**（`AccountManager.lambda$fetchThreadList$63` 原文）：服务端按
  /// `SearchVo` 回包 —— 话题父贴在同 `Post/search` 一模一样的
  /// **`search_results`** 里，`related_comment_count` 要来的"每条话题最新回复"
  /// 在 **`related_posts`** 里。原版把两者一起写进库。
  /// （`threads` / `posts` 两个键留着兼容假服务端/未来变体。）
  Future<List<Map<String, dynamic>>> listThreads({
    required int channelId,
    int offset = -1,
    int limit = 0,
    int relatedCommentCount = 0,
  }) async {
    final params = <String, String>{'channel_id': '$channelId'};
    if (offset >= 0) params['offset'] = _jsonNumber(offset);
    if (limit > 0) params['limit'] = _jsonNumber(limit);
    if (relatedCommentCount > 0) {
      params['related_comment_count'] = _jsonNumber(relatedCommentCount);
    }
    final data = await api.call(
      'SYNO.Chat.Post',
      'thread_list',
      preferredVersion: negotiate('SYNO.Chat.Post', const [5]),
      params: params,
    );
    final seen = <int>{};
    final out = <Map<String, dynamic>>[];
    for (final raw in [
      ..._asMapList(data['search_results'] ?? const []),
      ..._asMapList(data['related_posts'] ?? const []),
      ..._asMapList(data['threads'] ?? data['posts'] ?? const []),
    ]) {
      final id = _int(raw['post_id']) ?? 0;
      if (id > 0 && !seen.add(id)) continue;
      out.add(raw);
    }
    return out;
  }

  /// `SYNO.Chat.Post / list_editable`（不带 thread_id）—— 服务端给出"还能编辑的
  /// 那条消息 id"。
  ///
  /// 只在服务器**不支持** `SYNO.Chat.Admin.Setting v4`（没有"可编辑任意消息"）
  /// 时才有意义：那时只有 `post_id == 这个值` 的消息能编辑（原版
  /// `PostUtil.isPostEditableLegacy` 的 `ignoreEditablePostId=false` 分支）。
  /// 真机实测（v5 服务器，窗口 -1）返回 0。
  Future<int> listEditable(int channelId) async {
    final data = await api.call(
      'SYNO.Chat.Post',
      'list_editable',
      preferredVersion: negotiate('SYNO.Chat.Post', const [1]),
      params: {'channel_id': '$channelId'},
    );
    // ★ 第 259 轮：服务端字段类型不保证（可能是字符串数字）⇒ 走宽松解析，
    // 别裸 `as num?`（第 257 轮 `ver` 就是这么把整页打崩的）。
    return jsonInt(data['post_id']) ?? 0;
  }

  /// `SYNO.Chat.Post / list_editable`（话题里可编辑的回复，编辑话题回复时用）
  Future<List<Map<String, dynamic>>> listEditablePosts({
    required int channelId,
    required int threadId,
  }) async {
    final data = await api.call(
      'SYNO.Chat.Post',
      'list_editable',
      preferredVersion: negotiate('SYNO.Chat.Post', const [1]),
      params: {'channel_id': '$channelId', 'thread_id': '$threadId'},
    );
    return _asMapList(data['posts'] ?? const []);
  }

  /// `SYNO.Chat.Post.Subscribe / view` —— 话题已读上报
  ///
  /// `thread_id` 为空表示"整个频道的话题都看了"（原库两个重载对应两种入参）。
  /// 返回服务端给的 `last_view_comment_at`（没有就返回 0）。
  Future<int> viewChannelThreads({
    required int channelId,
    required String connId,
    int? threadId,
  }) async {
    final params = <String, String>{
      'channel_id': '$channelId',
      'conn_id': _jsonString(connId),
    };
    if (threadId != null && threadId != 0) params['thread_id'] = '$threadId';
    final data = await api.call(
      'SYNO.Chat.Post.Subscribe',
      'view',
      preferredVersion: negotiate(
        'SYNO.Chat.Post.Subscribe',
        threadId == null || threadId == 0 ? const [1] : const [2],
      ),
      params: params,
    );
    return _int(data['last_view_comment_at']) ?? 0;
  }

  /// 频道通知偏好取值（原版 `Common.java:142-146`）
  static const notificationAll = 'all';
  static const notificationMention = 'mention';
  static const notificationMentionSubscribe = 'mention_subscribe';
  static const notificationNone = 'none';

  /// 服务端用这个值表示"跟随全局默认"（原版 web UI 会把它替换成 `notify_type`）
  static const notificationByAdminConsole = 'by_admin_console';

  /// 频道的通知档位候选（跟原版 UI 一致）：
  /// 公开/私有且**非加密**频道支持 @我 相关档位，其余（加密、群聊）只有 全开/关闭。
  static List<String> notificationOptionsFor(ChannelDto channel) {
    final mentionable =
        !channel.encrypted &&
        (channel.type == 'public' || channel.type == 'private');
    return mentionable
        ? const [
            notificationAll,
            notificationMentionSubscribe,
            notificationMention,
            notificationNone,
          ]
        : const [notificationAll, notificationNone];
  }

  /// `SYNO.Chat.Channel.Preference / get`（v2）
  ///
  /// 逆向依据 `AccountManager.fetchChannelPreference`：只传 `channel_id`（裸值，非 JSON），
  /// 响应 `data.preferences` = `{notification_desktop, notification_mobile, notification_mute}`。
  Future<ChannelPreference> channelPreference(int channelId) async {
    final data = await api.call(
      'SYNO.Chat.Channel.Preference',
      'get',
      preferredVersion: negotiate('SYNO.Chat.Channel.Preference', const [2, 1]),
      params: {'channel_id': '$channelId'},
    );
    final prefs = data['preferences'];
    return ChannelPreference.fromJson(
      prefs is Map ? prefs.cast<String, dynamic>() : const {},
    );
  }

  /// `SYNO.Chat.Channel.Preference / set`（v3）
  ///
  /// 逆向依据 `AccountManager.setChannelPreference`：**只写 `notification_mobile`**
  /// （桌面档位由 web/desktop 端负责），两个参数都是裸值。
  Future<void> setChannelNotification(
    int channelId,
    String notificationMobile,
  ) async {
    await api.call(
      'SYNO.Chat.Channel.Preference',
      'set',
      preferredVersion: negotiate('SYNO.Chat.Channel.Preference', const [
        3,
        2,
        1,
      ]),
      params: {
        'channel_id': '$channelId',
        'notification_mobile': notificationMobile,
      },
    );
  }

  /// `SYNO.Chat.Post / list`
  ///
  /// 逆向依据 `AccountManager.internalFetchServerPosts`：版本取 (2,1)，`prev_count`
  /// 是向前的条数，`next_count` 向后。
  ///
  /// `has` 是**重复字段**（原库 Retrofit 的 `List<String>`），
  /// 例如 `has=["thread"]` → `has=thread`；不传时服务端只给精简字段。
  Future<List<Map<String, dynamic>>> listPosts({
    required int channelId,
    int? postId,
    int? threadId,
    int prevCount = 50,
    int nextCount = 0,
    List<String> has = const [],
  }) async {
    final params = <String, dynamic>{
      'channel_id': '$channelId',
      'prev_count': '$prevCount',
      'next_count': '$nextCount',
    };
    if (postId != null && postId > 0) params['post_id'] = '$postId';
    if (threadId != null && threadId > 0) params['thread_id'] = '$threadId';
    if (has.isNotEmpty) params['has'] = has;

    final data = await api.call(
      'SYNO.Chat.Post',
      'list',
      preferredVersion: negotiate('SYNO.Chat.Post', const [2, 1]),
      params: params,
    );
    final posts = data['posts'];
    if (posts is! List) return const [];
    return posts
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  // --------------------------------------------------- 斜杠命令（Webhook.Slash）

  /// 执行斜杠命令 `SYNO.Chat.Webhook.Slash / execute` v1。
  ///
  /// ⚠️ 这里 `message` 是**裸文本**（原版 `@Field("message")` 直接传用户输入，
  /// 不是 Gson 串），`user_id` 是那条斜杠命令对应的机器人（`User.slash_props`
  /// 里 `bot_type="slash"`，`slash_cmd` 跟正文第一个词相同）。
  ///
  /// 原版只在**未加密**频道、且正文以 `/jumpchat` 或 `/jitsi` 开头时才走这条路
  /// （`ChannelFragment.onCreatePost`）。
  Future<void> executeSlashCommand({
    required int channelId,
    required String message,
    required int userId,
  }) async {
    await api.call(
      'SYNO.Chat.Webhook.Slash',
      'execute',
      preferredVersion: 1,
      params: {
        'channel_id': '$channelId',
        'message': message,
        'user_id': '$userId',
      },
    );
  }

  // ------------------------------------------------------------ 投票（Phase 6）

  /// 建投票 `SYNO.Chat.Post.Vote / create` v1，返回新消息（投票在 `props.vote`）。
  ///
  /// ⚠️ `options` 的字段名是 **`add_option` / `expire_at`**（Gson 的
  /// `@SerializedName`），写成驼峰会得到 `101 参数无效`（真机实测过）。
  Future<Map<String, dynamic>> createVote({
    required int channelId,
    required String message,
    required List<String> choices,
    bool multiple = false,
    bool anonymous = false,
    bool addOption = false,
    int expireAt = 0,
    String? filePath,
    String fileName = '',
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final params = <String, dynamic>{
      'channel_id': '$channelId',
      'message': _jsonString(message),
      'choices': jsonEncode([
        for (final c in choices)
          if (c.trim().isNotEmpty) {'text': c.trim()},
      ]),
      'options': jsonEncode({
        'add_option': addOption,
        'anonymous': anonymous,
        'expire_at': expireAt,
        'multiple': multiple,
      }),
    };
    if (filePath != null && filePath.isNotEmpty) {
      // 带附件的投票：multipart，元数据还是在查询串上
      final text = await api.postMultipart(
        api.apiPath('SYNO.Chat.Post.Vote'),
        query: {
          'api': 'SYNO.Chat.Post.Vote',
          'method': 'create',
          'version': '1',
          ...params,
        },
        fields: {'type': 'file'},
        fileField: 'file',
        filePath: filePath,
        fileName: fileName.isEmpty ? filePath.split('/').last : fileName,
        mimeType: mimeType,
        onProgress: onProgress,
      );
      return api.decodeData(text, 'SYNO.Chat.Post.Vote.create');
    }
    return api.call(
      'SYNO.Chat.Post.Vote',
      'create',
      preferredVersion: 1,
      params: params,
    );
  }

  /// 投票 `SYNO.Chat.Post.Vote / vote` v1
  ///
  /// `choice_ids` 是 JSON 数组（真机实测：发出去以后
  /// `get_choices` 的 `count`/`voters` 立刻变；连发多次会被服务端忽略，
  /// 所以界面要防抖）。
  Future<void> castVote({
    required int postId,
    required List<String> choiceIds,
  }) => api.call(
    'SYNO.Chat.Post.Vote',
    'vote',
    preferredVersion: 1,
    params: {'post_id': '$postId', 'choice_ids': _jsonList(choiceIds)},
  );

  /// 选项与票数 `SYNO.Chat.Post.Vote / get_choices` v1
  Future<List<Map<String, dynamic>>> voteChoices(int postId) async {
    final data = await api.call(
      'SYNO.Chat.Post.Vote',
      'get_choices',
      preferredVersion: 1,
      params: {'post_id': '$postId'},
    );
    return _asMapList(data['choices'] ?? const []);
  }

  /// 结束投票 `SYNO.Chat.Post.Vote / close` v1
  Future<void> closeVote(int postId) => api.call(
    'SYNO.Chat.Post.Vote',
    'close',
    preferredVersion: 1,
    params: {'post_id': '$postId'},
  );

  /// 追加选项 `SYNO.Chat.Post.Vote / create_option` v1
  Future<void> createVoteOption({required int postId, required String text}) =>
      api.call(
        'SYNO.Chat.Post.Vote',
        'create_option',
        preferredVersion: 1,
        params: {'post_id': '$postId', 'text': _jsonString(text)},
      );

  /// 删投票 `SYNO.Chat.Post.Vote / delete` v1
  Future<void> deleteVote(int postId) => api.call(
    'SYNO.Chat.Post.Vote',
    'delete',
    preferredVersion: 1,
    params: {'post_id': '$postId'},
  );

  /// 编辑投票 `SYNO.Chat.Post.Vote / set` v1（原版 `AccountManager.editVote`）
  ///
  /// 两个形态，由服务端/客户端一起约定：
  ///   * **还没人投票**（原版 `editable = 总票数 == 0`）：带 `message`（JSON 字符串）、
  ///     `choices`（JSON 数组，既有选项要带原 `id`）、`options`；
  ///   * **已经有人投票**：**只带 `options`**（原版另一个重载），问题/选项/多选/匿名
  ///     都不许改 —— 服务端也只认 options。
  ///
  /// `options` 的字段名同样是下划线 `add_option` / `expire_at`（与 `create` 一致）。
  Future<void> setVote({
    required int channelId,
    required int postId,
    String? message,
    List<({String id, String text})>? choices,
    required bool multiple,
    required bool anonymous,
    required bool addOption,
    required int expireAt,
  }) async {
    final options = jsonEncode({
      'add_option': addOption,
      'anonymous': anonymous,
      'expire_at': expireAt,
      'multiple': multiple,
    });
    final params = <String, dynamic>{
      'channel_id': '$channelId',
      'post_id': '$postId',
      'options': options,
    };
    // 有人投过票时只发 options（原版 options-only 重载）
    if (message != null) params['message'] = _jsonString(message);
    if (choices != null) {
      params['choices'] = jsonEncode([
        for (final c in choices)
          // 原版 `VoteChoice` 用 Gson 序列化，`count` 是 int 永远在（null 的
          // voters 被跳过），服务端忽略它；这里照样带上以免服务端挑字段
          {'count': 0, 'id': c.id, 'text': c.text},
      ]);
    }
    await api.call(
      'SYNO.Chat.Post.Vote',
      'set',
      preferredVersion: 1,
      params: params,
    );
  }

  // ------------------------------------------------------------ 提醒（Phase 6）

  /// 设置/修改提醒 `SYNO.Chat.Post.Reminder / set` v1
  /// （真机实测返回 `{}`，之后 `props.remind_at` 就是新值）
  Future<void> setReminder({required int postId, required int remindAt}) =>
      api.call(
        'SYNO.Chat.Post.Reminder',
        'set',
        preferredVersion: 1,
        params: {'post_id': '$postId', 'remind_at': '$remindAt'},
      );

  /// 读某条消息的提醒 `SYNO.Chat.Post.Reminder / get` v1
  Future<int> reminderAt(int postId) async {
    final data = await api.call(
      'SYNO.Chat.Post.Reminder',
      'get',
      preferredVersion: 1,
      params: {'post_id': '$postId'},
    );
    return _int(data['remind_at']) ?? 0;
  }

  // ------------------------------------------------ 机器人消息按钮（Phase 9）

  /// 点机器人消息里的按钮 `SYNO.Chat.Post.Attachment / trigger` v1。
  ///
  /// 服务端（2.4.7 `webapi/SYNO.Chat.Post.Attachment.so`，方法表只有 `trigger`）
  /// 收到后会把动作转给机器人的 outgoing URL（文档 `chat_integration.html`
  /// "To receive interactive data triggered by users"）：
  ///
  ///   payload = {"actions": [...], "callback_id": "...", "post_id": ..., "token": ...,
  ///              "user": {"user_id": ..., "username": ...}}
  ///
  /// 我们发上去的 `payload` 照抄 APK（`AccountManager#triggerChatBotAttachment` →
  /// `AttachmentTmp` + 一个 `ActionTmp`）：
  ///
  ///   {"callback_id": "...", "idx": <附件下标>,
  ///    "actions": [{"idx": <按钮下标>, "name": ..., "type": ..., "value": ...}]}
  ///
  /// ⚠️ `payload` 是 **`gson.toJson()` 之后当普通表单字段发**（和 `message` 一样
  /// 不是二次编码，服务端只剥一层）；`idx` 是数组下标，服务端靠它定位点击的是
  /// 第几个附件/第几个按钮。
  Future<void> triggerChatbotAction({
    required int postId,
    required int attachmentIndex,
    required int actionIndex,
    required String callbackId,
    required String name,
    required String type,
    required String value,
  }) => api.call(
    'SYNO.Chat.Post.Attachment',
    'trigger',
    preferredVersion: 1,
    params: {
      'post_id': '$postId',
      'payload': jsonEncode({
        'callback_id': callbackId,
        'idx': attachmentIndex,
        'actions': [
          {'idx': actionIndex, 'name': name, 'type': type, 'value': value},
        ],
      }),
    },
  );

  /// 取消提醒 `SYNO.Chat.Post.Reminder / delete` v1
  Future<void> deleteReminder(int postId) => api.call(
    'SYNO.Chat.Post.Reminder',
    'delete',
    preferredVersion: 1,
    params: {'post_id': '$postId'},
  );

  /// 频道的提醒列表 `SYNO.Chat.Post.Reminder / list` v1
  /// （返回 `{posts:[...]}`，提醒时间在每条 `props.remind_at` 里）
  Future<List<Map<String, dynamic>>> listReminders(int channelId) async {
    final data = await api.call(
      'SYNO.Chat.Post.Reminder',
      'list',
      preferredVersion: 1,
      params: {'channel_id': '$channelId'},
    );
    return _asMapList(data['posts'] ?? const []);
  }

  // ------------------------------------------------------------ 定时消息（Phase 6）

  /// 建定时消息 `SYNO.Chat.Post.Schedule / create` v1 → `{cronjob_id}`
  /// （真机实测：`message` 发 JSON 编码，服务端会剥掉引号）
  Future<int> createScheduledPost({
    required int channelId,
    required String message,
    required int sendAt,
  }) async {
    final data = await api.call(
      'SYNO.Chat.Post.Schedule',
      'create',
      preferredVersion: 1,
      params: {
        'channel_id': '$channelId',
        'message': _jsonString(message),
        'send_at': '$sendAt',
      },
    );
    return _int(data['cronjob_id']) ?? 0;
  }

  /// 改定时消息 `SYNO.Chat.Post.Schedule / set` v1
  Future<void> updateScheduledPost({
    required int cronjobId,
    required String message,
    required int sendAt,
  }) => api.call(
    'SYNO.Chat.Post.Schedule',
    'set',
    preferredVersion: 1,
    params: {
      'cronjob_id': '$cronjobId',
      'message': _jsonString(message),
      'send_at': '$sendAt',
    },
  );

  /// 删定时消息 `SYNO.Chat.Post.Schedule / delete` v1
  Future<void> deleteScheduledPost(int cronjobId) => api.call(
    'SYNO.Chat.Post.Schedule',
    'delete',
    preferredVersion: 1,
    params: {'cronjob_id': '$cronjobId'},
  );

  /// 定时消息列表 `SYNO.Chat.Post.Schedule / list` v1 → `{schedule_posts:[...]}`
  Future<List<Map<String, dynamic>>> listScheduledPosts(int channelId) async {
    final data = await api.call(
      'SYNO.Chat.Post.Schedule',
      'list',
      preferredVersion: 1,
      params: {'channel_id': '$channelId'},
    );
    return _asMapList(data['schedule_posts'] ?? const []);
  }

  // ------------------------------------------------------------ 标签（Phase 6）

  /// 频道里用过的标签 `SYNO.Chat.Channel.Hashtag / list` v1 → `{hashtags:[str]}`
  Future<List<String>> channelHashtags(int channelId) async {
    final data = await api.call(
      'SYNO.Chat.Channel.Hashtag',
      'list',
      preferredVersion: 1,
      params: {'channel_id': '$channelId'},
    );
    return (data['hashtags'] as List? ?? const [])
        .map((e) => '$e')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 给消息加标签 `SYNO.Chat.Post.Hashtag / set` v1
  /// （`hashtag` 是 JSON 编码的字符串；真机实测返回 `{}`，
  /// 之后 `Channel.Hashtag/list` 里就能看到）
  Future<void> setPostHashtag({required int postId, required String hashtag}) =>
      api.call(
        'SYNO.Chat.Post.Hashtag',
        'set',
        preferredVersion: 1,
        params: {'post_id': '$postId', 'hashtag': _jsonString(hashtag)},
      );

  /// 去掉消息上的标签 `SYNO.Chat.Post.Hashtag / delete` v1
  Future<void> deletePostHashtag({
    required int postId,
    required String hashtag,
  }) => api.call(
    'SYNO.Chat.Post.Hashtag',
    'delete',
    preferredVersion: 1,
    params: {'post_id': '$postId', 'hashtag': _jsonString(hashtag)},
  );

  // ------------------------------------------------------------ 归档（Phase 6/7）

  /// 归档频道列表 `SYNO.Chat.Archive / list` v1。
  ///
  /// 真机实测：`type` **只接受 `"encrypted"`**（JSON 编码），其他值回 101
  /// 参数无效；返回 `{archives:[...]}`（这台 NAS 是空的）。
  /// E2EE 归档频道要在 Phase 7 才能真正解开，这里先把接口和解析打通。
  Future<List<ArchiveDto>> listArchives({String type = 'encrypted'}) async {
    final data = await api.call(
      'SYNO.Chat.Archive',
      'list',
      preferredVersion: 1,
      params: {'type': _jsonString(type)},
    );
    return ArchiveDto.parseList(data['archives']);
  }

  // ------------------------------------------------------------ E2EE（Phase 7）

  /// 登记/更新我的 E2EE 密钥 `SYNO.Chat.User / update_key` v2。
  ///
  /// 反编译 `AccountManager.renewKey()`：
  ///   * `conn_id` / `public_key` / `private_key_enc` 都是 Gson 再编码一次；
  ///   * `channel_ids` 与 `channel_key_encs` **顺序一一对应**（后者是用我的公钥
  ///     seal 过的频道密钥）；
  ///   * `archive_ids` / `archive_key_encs` 同理（归档频道）。
  ///
  /// 真机实测：上传后 `User/list` 的 `user_props.key_pair` 立刻能读回，
  /// 空列表也接受（首次设置时就是全空）。
  Future<void> updateKey({
    required String connId,
    required String publicKey,
    required String privateKeyEnc,
    List<int> channelIds = const [],
    List<String> channelKeyEncs = const [],
    List<int> archiveIds = const [],
    List<String> archiveKeyEncs = const [],
  }) async {
    await api.call(
      'SYNO.Chat.User',
      'update_key',
      preferredVersion: negotiate('SYNO.Chat.User', const [2]),
      params: {
        'conn_id': _jsonString(connId),
        'public_key': _jsonString(publicKey),
        'private_key_enc': _jsonString(privateKeyEnc),
        'channel_ids': _jsonList(channelIds),
        'channel_key_encs': _jsonList(channelKeyEncs),
        'archive_ids': _jsonList(archiveIds),
        'archive_key_encs': _jsonList(archiveKeyEncs),
      },
    );
  }

  /// 建加密的一对一（匿名）频道 `SYNO.Chat.Channel.Anonymous / initiate` v1。
  ///
  /// 真机实测（`tool/probe_e2ee*.dart`，非常反直觉，别乱改）：
  ///   * `user_ids` 必须是 **`[对方, 我]`**：`[4,14]` 成功、`[14,4]` 回 117、
  ///     `[4]` 或 `[14]` 回 400 `CHAT_ERR_NO_SUCH_USER`；
  ///   * `channel_key_encs` 与 `user_ids` 顺序对应，缺了会走不到成功分支；
  ///   * **同两个人再建一次回 117**，所以发起前必须先查本地已有频道；
  ///   * 返回的就是**频道对象本身**（不包 `channel`），带 `channel_key_enc`
  ///     （我那一条）。
  /// [channelKeyEncs] 传 `null` 时发的是 **Gson 的 `null` 字面量**（原版
  /// `initiateAnonymous(list, false)` 就是 `gson.toJson(null)` = `"null"`），
  /// 这是"非加密会话"那条路（`ProfileFragment` 的「发消息」）。
  Future<ChannelDto> initiateAnonymous({
    required List<int> userIds,
    List<String>? channelKeyEncs,
    bool encrypted = true,
  }) async {
    // 版本固定 1：反编译里 `initiateAnonymous` 就是写死 1（v2 语义没见过，
    // 这台 NAS 的 API 表虽然写 v1..2，但别拿没验证过的版本去赌）
    final data = await api.call(
      'SYNO.Chat.Channel.Anonymous',
      'initiate',
      preferredVersion: 1,
      params: {
        'user_ids': _jsonList(userIds),
        'channel_key_encs': channelKeyEncs == null
            ? 'null'
            : _jsonList(channelKeyEncs),
        'encrypted': '$encrypted',
      },
    );
    final channel = data['channel'] is Map ? data['channel'] : data;
    return ChannelDto.fromJson(Map<String, dynamic>.from(channel as Map));
  }

  /// 把一对一（匿名）会话升级成**专用频道**
  /// `SYNO.Chat.Channel.Anonymous / promote` v2（原版
  /// `AccountManager.promoteChannel` + `PromoteChannelFragment`）。
  ///
  /// 反编译事实（`WebApiService.promoteChannel`）：
  ///   * 只有 v2 有这个方法（服务端方法表：v1 只有 `initiate`）→ **必须**按方法
  ///     选版本，照 `maxVersion` 协商会在老服务器上吃 103；
  ///   * 三个参数 `channel_id` / `name` / `purpose`，其中 `name` 与 `purpose`
  ///     是 `gson.toJson(str)` —— **Gson 二次编码**（和 `message`/`conn_id` 一样）；
  ///   * 原版 UI 的门控是 `ApiManager.support(ChatChannelAnonymous, 2)`。
  Future<Map<String, dynamic>> promoteAnonymous({
    required int channelId,
    required String name,
    required String purpose,
  }) async {
    final version = negotiate('SYNO.Chat.Channel.Anonymous', const [2]);
    if (!supports('SYNO.Chat.Channel.Anonymous', 2)) {
      throw StateError(
        dataText(
          'apiAnonymousPromoteUnsupported',
          '这台服务器的 SYNO.Chat.Channel.Anonymous 不支持 promote',
        ),
      );
    }
    final data = await api.call(
      'SYNO.Chat.Channel.Anonymous',
      'promote',
      preferredVersion: version,
      params: {
        'channel_id': '$channelId',
        'name': _jsonString(name),
        'purpose': _jsonString(purpose),
      },
    );
    final channel = data['channel'] is Map ? data['channel'] : data;
    return Map<String, dynamic>.from(channel as Map);
  }

  /// 给某个成员重封一份频道密钥 `SYNO.Chat.Channel / rescue` v1。
  ///
  /// 用在「对方的密钥对换了 / 对方那边解不开」时，是原 App 的修复频道入口。
  /// 真机实测：配 `update_key`（我自己那份）能把一个坏掉的加密频道救回来。
  Future<void> rescueChannel({
    required int userId,
    required int channelId,
    required String channelKeyEnc,
  }) async {
    await api.call(
      'SYNO.Chat.Channel',
      'rescue',
      preferredVersion: negotiate('SYNO.Chat.Channel', const [1]),
      params: {
        'user_id': '$userId',
        'channel_id': '$channelId',
        'channel_key_enc': _jsonString(channelKeyEnc),
      },
    );
  }

  // ------------------------------------------------------------ 机器人（Phase 6）

  /// 被屏蔽的机器人 `SYNO.Chat.Channel.Chatbot / list_blocked` v1
  /// → `{blocked_user_ids:[int]}`
  Future<List<int>> blockedBots() async {
    final data = await api.call(
      'SYNO.Chat.Channel.Chatbot',
      'list_blocked',
      preferredVersion: 1,
      params: const {},
    );
    return (data['blocked_user_ids'] as List? ?? const [])
        .map((e) => _int(e) ?? 0)
        .where((e) => e > 0)
        .toList();
  }

  /// 跟机器人开始一对一对话 `SYNO.Chat.Channel.Chatbot / initiate` v1。
  ///
  /// `user_id` 反编译里是 String 字段（Gson 编码）；真机上两种写法都试过：
  /// 裸 JSON 字符串给 `101 参数无效`，JSON 数组给 `117`（这台 NAS 上
  /// synobot / Synology_Drive 都已经有频道了，服务端不让再 initiate）。
  /// 所以 [asList] 让调用方可以兜底重试。
  Future<Map<String, dynamic>> initiateChatbot(
    int userId, {
    bool asList = false,
  }) => api.call(
    'SYNO.Chat.Channel.Chatbot',
    'initiate',
    preferredVersion: 1,
    params: {
      'user_id': asList ? _jsonList([userId]) : _jsonString('$userId'),
    },
  );

  /// 高级搜索 `SYNO.Chat.Post / search`（Phase 6）。
  ///
  /// 逆向依据 `AccountManager.search(...)`：版本候选 `[5,3,2]`，
  /// **所有值都再 JSON 序列化一次**（Gson.toJson），并且 v>=3 时把 `has` 里的
  /// `file` / `vote` 挪到 `post_type`（否则服务端会**静默忽略**这两个值）。
  ///
  /// 真机实测（`tool/probe_search.dart`）：
  ///   * 返回形状是 `{limit, offset, total, search_results:[...]}`，
  ///     结果在 **`search_results`** 里（不是 `posts`）；
  ///   * `has` 里不认识的词**不报错也不过滤**（返回全部）；
  ///   * `has=[thread]`（旧版的值）在 v5 下同样是"不过滤"；
  ///   * `after` / `before` 是**毫秒时间戳**，生效；
  ///   * `offset` 传非数字会被忽略（不报错）；
  ///   * `search_results` 里单条带 `url_props` / `hashtags` / `mentions` /
  ///     `reactions` / `is_star` / `comment_count`，足够直接渲染。
  Future<PostSearchResult> searchPosts(
    PostSearchQuery query, {
    List<int>? versionCandidates,
  }) async {
    final version = negotiate(
      'SYNO.Chat.Post',
      versionCandidates ?? const [5, 3, 2],
    );
    var has = [...query.has];
    final postTypes = [...query.postTypes];
    if (version >= 3) {
      // 原库就是这么搬的：has 里的 file/vote 归 post_type
      if (has.remove('file')) postTypes.add('file');
      if (has.remove('vote')) postTypes.add('vote');
    }

    final params = <String, dynamic>{};
    if (query.fromUsers.isNotEmpty) params['from'] = _jsonList(query.fromUsers);
    if (query.inChannels.isNotEmpty) params['in'] = _jsonList(query.inChannels);
    if (query.after > 0) params['after'] = _jsonNumber(query.after);
    if (query.before > 0) params['before'] = _jsonNumber(query.before);
    final keyword = query.keyword.trim();
    if (keyword.isNotEmpty) params['keyword'] = _jsonString(keyword);
    if (query.hashtags.isNotEmpty) {
      params['hashtag'] = _jsonList(query.hashtags);
    }
    if (query.mentions.isNotEmpty) {
      params['mention'] = _jsonList(query.mentions);
    }
    if (has.isNotEmpty) params['has'] = _jsonList(has);
    if (postTypes.isNotEmpty) params['post_type'] = _jsonList(postTypes);
    if (query.fileTypes.isNotEmpty) {
      params['file_type'] = _jsonList(query.fileTypes);
    }
    params['offset'] = _jsonNumber(query.offset);
    params['limit'] = _jsonNumber(query.limit);

    final data = await api.call(
      'SYNO.Chat.Post',
      'search',
      preferredVersion: version,
      params: params,
    );
    final list = data['search_results'];
    return PostSearchResult(
      posts: list is List ? _asMapList(list) : const [],
      total: _int(data['total']) ?? 0,
      offset: _int(data['offset']) ?? query.offset,
      limit: _int(data['limit']) ?? query.limit,
    );
  }

  /// 图片墙 / 媒体列表用的 `Post/list`（v3）。
  ///
  /// 逆向依据 `AccountManager.fetchImagePosts`：
  /// `Post/list` v3 + **JSON 编码**的 `file_type` + `attributes`。
  ///
  /// 真机实测（`tool/probe_image_gallery.dart`）：
  ///   * `file_type` 是**分类**或**扩展名**的 JSON 数组：
  ///     `["image"]` 能筛出服务端判定为图片的消息（pixel 太小的空图
  ///     服务端会判 `is_image=false`，就筛不出来），`["png"]`/`["txt"]`
  ///     这类扩展名同样有效；
  ///   * `["video"]` / `["audio"]` 是分类；`["file"]` / `["document"]` /
  ///     `["other"]` **不是**（真机上筛不出来），文件列表得自己按扩展名过滤；
  ///   * `attributes` 可以不带（带了就只回这些字段 + 必要的元信息）。
  Future<List<Map<String, dynamic>>> listPostsByType({
    required int channelId,
    int? postId,
    int? threadId,
    List<String> fileTypes = const [],
    List<String> attributes = kMediaAttributes,
    int prevCount = 50,
    int nextCount = 0,
  }) async {
    final params = <String, dynamic>{
      'channel_id': '$channelId',
      'prev_count': '$prevCount',
      'next_count': '$nextCount',
      'has': const ['thread'],
    };
    if (postId != null && postId > 0) params['post_id'] = '$postId';
    if (threadId != null && threadId > 0) params['thread_id'] = '$threadId';
    if (fileTypes.isNotEmpty) params['file_type'] = _jsonList(fileTypes);
    if (attributes.isNotEmpty) params['attributes'] = _jsonList(attributes);

    final data = await api.call(
      'SYNO.Chat.Post',
      'list',
      preferredVersion: negotiate('SYNO.Chat.Post', const [3, 2, 1]),
      params: params,
    );
    final posts = data['posts'];
    if (posts is! List) return const [];
    return posts
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  // ------------------------------------------------------------ 已读 / 进入

  /// `SYNO.Chat.Channel / view` —— 标记频道已读。
  ///
  /// 逆向依据 `AccountManager.viewChannel`：版本 `getMaxAvailableVersion(2, 1)`
  /// （**不是** Channel 的 5），参数 `channel_id` + `conn_id`。
  /// 响应 `data.last_view_at` 才是服务端认可的已读时间点，本地用它做 `last_view_at`。
  Future<int> viewChannel(int channelId, String connId) async {
    final data = await api.call(
      'SYNO.Chat.Channel',
      'view',
      preferredVersion: negotiate('SYNO.Chat.Channel', const [2, 1]),
      params: {'channel_id': '$channelId', 'conn_id': _jsonString(connId)},
    );
    final lastViewAt = data['last_view_at'];
    if (lastViewAt is num) return lastViewAt.toInt();
    if (lastViewAt is String) return int.tryParse(lastViewAt) ?? 0;
    return 0;
  }

  // ------------------------------------------------------------ 内部

  static List<ChannelDto> _channelsOf(Map<String, dynamic>? data) {
    final list = data?['channels'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => ChannelDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static List<UserDto> _usersOf(Map<String, dynamic>? data) {
    final list = data?['users'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => UserDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

List<Map<String, dynamic>> _asMapList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

int? _int(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// 原库很多参数都是「把值再 JSON 序列化一次」的字符串（Gson.toJson）
String _jsonList(List<Object> values) =>
    jsonEncode([for (final v in values) v is int ? v : '$v']);

/// 标量的 JSON 形式（数字就是它自己）
String _jsonNumber(int value) => '$value';

String _jsonString(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// `SYNO.Chat.User/login` 的返回（`UserLoginVo`）
class ChatUserLogin {
  const ChatUserLogin({
    this.currentTime = 0,
    this.dbUuid = '',
    this.firstTime = false,
    this.userId = 0,
    this.isAdmin = false,
  });

  /// 服务端当前时间（毫秒）
  final int currentTime;

  /// 服务端数据库标识；与本地记录不一致 = 服务端重装过
  final String dbUuid;

  final bool firstTime;
  final int userId;
  final bool isAdmin;

  /// 本机相对服务端的时差（毫秒）。消息时间戳要用 `DateTime.now() + skew`。
  int skewMillis() => currentTime <= 0
      ? 0
      : currentTime - DateTime.now().millisecondsSinceEpoch;

  factory ChatUserLogin.fromJson(Map<String, dynamic> json) {
    final u = json['user'];
    final user = u is Map
        ? Map<String, dynamic>.from(u)
        : const <String, dynamic>{};
    return ChatUserLogin(
      currentTime: _intOf(json['current_time']),
      dbUuid: json['db_uuid'] is String ? json['db_uuid'] as String : '',
      firstTime: json['first_time'] == true,
      userId: _intOf(user['user_id']),
      isAdmin: user['is_admin'] == true,
    );
  }
}

int _intOf(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
