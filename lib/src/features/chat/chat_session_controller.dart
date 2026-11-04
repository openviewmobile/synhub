// Phase 2 的主控：登录成功之后把「频道/用户/实时事件」串起来。
//
// 数据流（与 APK 的 AccountManager + SocketHelper + DatabaseHelper 对应）：
//
//   ChatApi.listUsers()   ──┐
//   ChatApi.myUser()      ──┤→ ChatStore（Drift）→ watchChannels() → UI
//   ChatApi.listChannels()──┘
//   ChatSocket.events     ──→ 按事件类型增量更新 ChatStore
//
// 设计取舍：REST 同步失败 = 真失败（进 error）；socket 连不上 = **降级**，
// 列表依然可用，只是不实时（对齐原 App：socket 断了会显示"连接中"但仍能看历史）。
library;

import '../../core/i18n/l10n.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


import '../../data/chat_api.dart';
import '../../data/dto/archive_dto.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/user_dto.dart';
import '../../data/dto/vote_dto.dart';
import '../../core/security/keystore_secret_keeper.dart';
import '../../data/local/chat_store.dart';
import '../../data/local/database.dart';
import 'attachment_access.dart';
import 'mentions.dart';
import 'channel_hashtags_page.dart';
import 'voice_message.dart';
import '../../data/remote/socket/chat_socket.dart';
import '../../data/remote/socket/socket_events.dart';
import '../../dsm/webapi.dart';

import '../../native/background_service.dart';
import '../../core/media/image_prepare.dart';
import '../../core/settings/acl.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/server_settings.dart';
import '../settings/snooze_controller.dart';
import 'vote_editor.dart';
import '../../data/dto/server_settings_dto.dart';
import '../notifications/notification_service.dart';
import '../notifications/reminder_scheduler.dart';
import '../servers/connection_service.dart';
import '../../data/e2ee/e2ee_service.dart';
import 'channel_scheduled_page.dart' show scheduleRevisionProvider;
import 'post_editable.dart';
import 'typing_notifier.dart';
import '../../core/user_facing_error.dart';
import '../../core/net/media_tls_policy.dart';

/// 本地记住的**服务端** `db_uuid`（`SYNO.Chat.User/login` 下发的那个）。
///
/// 变了 = 服务端重装/换库 ⇒ `clearAllData()` 把本地频道/用户/消息全部作废。
/// ★ r326（D24）：此前只放在内存 state 里，冷启动永远为空 ⇒ 机制形同不存在。
const String _kServerDbUuidKey = 'chat_server_db_uuid';

// ---------------------------------------------------------------- provider

/// 本地库。测试里用 `overrideWithValue` 换成内存库。
final chatDatabaseProvider = Provider<ChatDatabase>((ref) {
  final db = ChatDatabase.open();
  ref.onDispose(db.close);
  return db;
});

final chatStoreProvider = Provider<ChatStore>(
  (ref) => ChatStore(ref.watch(chatDatabaseProvider)),
);

/// 频道列表（含未读），按 channel_order_time/last_post_at 倒序。
/// E2EE 服务的单例（跟本地库同一个生命周期）。
///
/// 放在这里而不是 `features/settings/e2ee_controller.dart`：消息发送路径
/// （本文件）就要用它，反过来引会绕成循环依赖。
final e2eeServiceProvider = Provider<E2eeService>(
  // E2EE 身份落盘时用 Android Keystore 再包一层（对齐原版
  // `PreferencesHelper.setBase64KeyPair`），见 core/security/keystore_secret_keeper.dart
  (ref) => E2eeService(
    ref.watch(chatStoreProvider),
    keeper: const KeystoreSecretKeeper(),
  ),
);

final channelsProvider = StreamProvider<List<ChannelDto>>(
  (ref) => ref.watch(chatStoreProvider).watchChannels(),
);

/// 有发送失败消息的频道（列表过滤用：这类频道不能因为"隐藏"就看不见）
final failedPostChannelsProvider = StreamProvider<Set<int>>(
  (ref) => ref.watch(chatStoreProvider).watchChannelsWithFailedPosts(),
);

/// 用户表快照。同步完成后由控制器 invalidate。
final usersProvider = FutureProvider<List<UserDto>>(
  (ref) => ref.watch(chatStoreProvider).allUsers(),
);

/// 某频道的消息（新的在前）。local-first：先出本地，翻页/实时事件再补齐。
final postsProvider = StreamProvider.family<List<PostDto>, int>(
  (ref, channelId) =>
      ref.watch(chatStoreProvider).watchPosts(channelId, limit: 400),
);

/// 按 id 取单个频道（聊天页标题用）
final channelProvider = Provider.family<ChannelDto?, int>((ref, channelId) {
  final list = ref.watch(channelsProvider).value;
  if (list == null) return null;
  for (final c in list) {
    if (c.channelId == channelId) return c;
  }
  return null;
});

/// 老服务器（不支持 `SYNO.Chat.Admin.Setting` v4）的"还能编辑的那条消息 id"。
///
/// 走 `SYNO.Chat.Post/list_editable`（v1）；新服务器上这个值会被忽略，直接返回 0
/// 不再多发一次请求。
final channelEditableProvider = FutureProvider.family<int, int>((
  ref,
  channelId,
) {
  final sync = ref.watch(chatSessionControllerProvider);
  if (sync.supportsEditAllPost) return Future.value(0);
  final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
  if (api == null) return Future.value(0);
  return api.listEditable(channelId);
});

/// 实时通道工厂 —— 测试可以注入假的 [ChatSocket]，
/// 从而离线验证"收事件 → 落库 → 发消息"整条链路。
final chatSocketFactoryProvider =
    Provider<
      ChatSocket Function(String baseUrl, String sid, String? synotoken)
    >(
      (ref) =>
          (baseUrl, sid, synotoken) =>
              ChatSocket(baseUrl: baseUrl, sid: sid, synotoken: synotoken),
    );

/// 当前连接上的 ChatApi（未登录时为 null）
final chatApiProvider = Provider<ChatApi?>((ref) {
  ref.watch(chatSessionControllerProvider);
  return ref.read(chatSessionControllerProvider.notifier).chatApi;
});

// ---------------------------------------------------------------- state

enum ChatSyncPhase {
  idle,
  syncing,

  /// 列表已就绪且实时通道可用
  ready,

  /// 列表可用，但实时通道断了
  degraded,

  error,
}

/// `Post/list` 的 `has` 参数。
///
/// 反编译依据：`AccountManager.internalFetchServerPosts` / `fetchAllPosts`
/// 都只传 `["thread"]`；支持 `Post.Subscribe` 时列表页传 `["pin"]`
/// （`PostPresenter.getHas()`）。Retrofit 签名里 `Post/list` 只有 `has`
/// 这一个"附加信息"参数（`file_type`/`attributes` 属于图片墙那个接口）。
/// 附件是随普通列表一起下发的，不需要额外开关 —— 已用真机确认，
/// 见 docs/phase5-protocol.md §3。
const kPostHas = <String>['thread'];

class ChatSyncState {
  const ChatSyncState({
    this.phase = ChatSyncPhase.idle,
    this.error,
    this.channelCount = 0,
    this.userCount = 0,
    this.connId,
    this.socketStatus = ChatSocketStatus.idle,
    this.myUserId = 0,
    this.isAdmin = false,
    this.clockSkewMillis = 0,
    this.dbUuid = '',
    this.pinUnsupported = false,
    this.stickUnsupported = false,
    this.pendingFiles = const {},
    this.supportsEditAllPost = true,
    this.supportsReadStatus = true,
    this.supportsStick = true,
    this.supportsUserV3 = true,
    this.baseUrl = '',
    this.supportsSubscribeApi = true,
    this.certUntrusted = false,
    this.adminDeletedSeq = 0,
  });

  final ChatSyncPhase phase;
  final String? error;
  final int channelCount;
  final int userCount;

  /// `client.init` 下发的 conn_id（写消息要用）
  final String? connId;
  final ChatSocketStatus socketStatus;
  final int myUserId;

  /// `SYNO.Chat.User/login` 告诉我们是不是管理员（决定能不能删别人的消息等）
  final bool isAdmin;

  /// 与服务端的时差（毫秒）：`本地时间 + skew = 服务端时间`
  final int clockSkewMillis;

  /// 服务端数据库标识；变了说明服务端重装过，本地缓存该清
  final String dbUuid;

  /// 服务端不接受**消息置顶**（`Post/pin` v1 回 407 CHAT_ERR_INVALID_RECORD，见
  /// docs/phase4-protocol.md §7）—— 探测到之后就隐藏「置顶」入口。
  ///
  /// ⚠️ 这是 `Post/pin` v1（写 `last_pin_at`）；**话题内置顶** `Post/stick` v2
  /// （写 `is_sticky`）是另一套，见 [stickUnsupported]。
  final bool pinUnsupported;

  /// 服务端不接受**话题内置顶**（`Post/stick` v2 回 407 CHAT_ERR_INVALID_RECORD，
  /// 见 docs/phase4-protocol.md §5.1）—— 探测到之后就隐藏「话题内置顶」入口。
  final bool stickUnsupported;

  /// 正在上传的附件：本地临时 post id → 本地文件路径。
  /// 上传期间界面拿它先预览本地图片（服务端确认后换成缩略图）。
  final Map<int, String> pendingFiles;

  /// ★ **管理员批量删除通知**的触发计数（第 40 轮）。
  ///
  /// 官方 `str_post_delete_by_admin` =
  /// 「部分帖子已被管理员删除。此页面将在一分钟后刷新。」
  /// （EN: "Some posts have been deleted by admin. This page will be refreshed
  /// in a minute."）。收到 `post.delete_batch` / `post.delete_search_list` 后
  /// **必须告诉用户**，否则消息会**无声消失**。
  ///
  /// 用**计数**而不是 bool：连着来两次要弹两次（bool 第二次不会变，UI 收不到通知）。
  final int adminDeletedSeq;

  /// 服务端支持"可编辑任意消息"（`SYNO.Chat.Admin.Setting` v4）
  final bool supportsEditAllPost;

  /// 服务端支持"已读回执"（同 v3）
  final bool supportsReadStatus;

  /// 服务端 `SYNO.Chat.Post` ≥ v2 —— `Post/stick|unstick`（**话题内置顶**）可用。
  /// 不支持时 UI 不暴露入口、控制器也不发请求（`setStick` 直接返回 false）。
  final bool supportsStick;

  /// 服务端 `SYNO.Chat.User` 支持 v3 —— 原版 `isSupportExemptSpecialCharacter()`，
  /// 为真时昵称免除特殊字符限制且上限 255
  final bool supportsUserV3;

  /// 服务器基地址（`https://host:port/`）—— 判断链接是不是"指向本机服务器"
  /// （频道链接要跳 App 内，外链才丢浏览器，见 `url_actions.dart`）
  final String baseUrl;

  /// 服务端有 `SYNO.Chat.Post.Subscribe`（= 支持订阅/置顶，原版
  /// `isSupportSubscribeApi()`）。决定频道内容页的"置顶"用 `has:["pin"]`
  /// 还是退回 `has:["thread"]`（原版 `PostPresenter.getHas`）
  final bool supportsSubscribeApi;

  /// 服务器证书没过系统 CA 校验、只有我们的固定指纹信任它
  /// （= 原版 `!CertificateStorageManager.isLegalCertificate()`）。
  /// 音频/视频附件因此不能串流给外部播放器，只能先下载。
  final bool certUntrusted;

  bool get realtime => socketStatus == ChatSocketStatus.ready;
  bool get busy => phase == ChatSyncPhase.syncing;

  ChatSyncState copyWith({
    ChatSyncPhase? phase,
    String? error,
    int? channelCount,
    int? userCount,
    String? connId,
    ChatSocketStatus? socketStatus,
    int? myUserId,
    bool? isAdmin,
    int? clockSkewMillis,
    String? dbUuid,
    bool? pinUnsupported,
    bool? stickUnsupported,
    Map<int, String>? pendingFiles,
    bool? supportsEditAllPost,
    bool? supportsReadStatus,
    bool? supportsStick,
    bool? supportsUserV3,
    String? baseUrl,
    bool? supportsSubscribeApi,
    bool? certUntrusted,
    int? adminDeletedSeq,
    bool clearError = false,
  }) {
    return ChatSyncState(
      phase: phase ?? this.phase,
      error: clearError ? null : (error ?? this.error),
      channelCount: channelCount ?? this.channelCount,
      userCount: userCount ?? this.userCount,
      connId: connId ?? this.connId,
      socketStatus: socketStatus ?? this.socketStatus,
      myUserId: myUserId ?? this.myUserId,
      isAdmin: isAdmin ?? this.isAdmin,
      clockSkewMillis: clockSkewMillis ?? this.clockSkewMillis,
      dbUuid: dbUuid ?? this.dbUuid,
      pinUnsupported: pinUnsupported ?? this.pinUnsupported,
      stickUnsupported: stickUnsupported ?? this.stickUnsupported,
      pendingFiles: pendingFiles ?? this.pendingFiles,
      supportsEditAllPost: supportsEditAllPost ?? this.supportsEditAllPost,
      supportsReadStatus: supportsReadStatus ?? this.supportsReadStatus,
      supportsStick: supportsStick ?? this.supportsStick,
      supportsUserV3: supportsUserV3 ?? this.supportsUserV3,
      baseUrl: baseUrl ?? this.baseUrl,
      supportsSubscribeApi: supportsSubscribeApi ?? this.supportsSubscribeApi,
      certUntrusted: certUntrusted ?? this.certUntrusted,
      adminDeletedSeq: adminDeletedSeq ?? this.adminDeletedSeq,
    );
  }
}

// ---------------------------------------------------------------- controller

class ChatSessionController extends Notifier<ChatSyncState> {
  DsmConnection? _conn;
  ChatApi? _api;
  ChatSocket? _socket;
  StreamSubscription<ChatSocketEvent>? _events;
  StreamSubscription<ChatSocketStatus>? _statuses;

  /// 原版 `mTyping`：true = 已经告诉服务端"我在输入"
  bool _typingSent = false;
  Timer? _typingClearTimer;

  /// 一条 typing 事件的有效窗口（原版 `clearTyping(10, SECONDS)`）
  static const Duration _typingWindow = Duration(seconds: 10);

  /// 供消息层（发送/翻页）复用同一个已登录连接
  ChatApi? get chatApi => _api;

  /// 已经打过日志的"没见过的"事件 / 广播类型。
  ///
  /// 协议漂移（服务端加了新 type、或我们名字写错）原来是**静默丢消息**，
  /// 很难发现；这里各打一次就够，避免刷屏。
  final Set<String> _loggedUnknownEvents = {};
  final Set<String> _loggedUnknownBroadcasts = {};

  /// [isPostEditable] 的控制器版本（拿得到本地库时的入口）
  bool _canEdit(PostDto post, ChannelDto channel) {
    return isPostEditable(
      post,
      channel,
      myUserId: state.myUserId,
      settings: ref.read(serverSettingsProvider),
      supportsEditAllPost: state.supportsEditAllPost,
    );
  }

  bool get hasRealtime {
    final id = state.connId;
    return id != null && id.isNotEmpty;
  }

  /// `ref.invalidate` 的安全版：销毁之后不再碰 provider（见 `_disposed`）。
  ///
  /// 参数用 `dynamic` 是因为 `ProviderOrFamily` 没有从 `flutter_riverpod` 导出，
  /// 而这里只是转发一次、不需要静态类型。
  void _safeInvalidate(dynamic provider) {
    if (_disposed) return;
    ref.invalidate(provider);
  }

  /// provider 已经销毁了吗（真机上"应用退出 / 登出 / 测试 teardown"时，
  /// socket 事件可能还在飞 —— 再 `ref.read` 就会炸 "Cannot use the Ref … after
  /// it has been disposed"，日志很吵，真机验收里还会被误判成用例失败）
  bool _disposed = false;

  @override
  ChatSyncState build() {
    ref.onDispose(() {
      _disposed = true;
      _typingClearTimer?.cancel();
      for (final t in _ogRefreshTimers) {
        t.cancel();
      }
      _ogRefreshTimers.clear();
      _events?.cancel();
      _statuses?.cancel();
      _socket?.dispose();
    });
    return const ChatSyncState();
  }

  /// 幂等：同一个连接重复调用不会重复同步。
  Future<void> start(DsmConnection conn) async {
    if (identical(_conn, conn) &&
        (state.phase == ChatSyncPhase.syncing ||
            state.phase == ChatSyncPhase.ready ||
            state.phase == ChatSyncPhase.degraded)) {
      return;
    }
    // ★ r665（DA284）：`session.loggedIn` 读的是**状态里那个 session**，它可以属于
    //   与 `conn` 不同的连接对象（冷启动恢复/多 NAS 切换的空隙里就是这样）——
    //   于是同步会拿一条**还没有 sid** 的连接去打 Chat 接口，服务端一律回 119，
    //   而且这时候自动重登钩子还没装（`_installRelogin` 在登录成功之后才装）⇒
    //   `设置/权限/免打扰` 三个功能静默降级成默认值，界面上还挂着「登录已过期」。
    //   判据钉在**连接自己的会话**上：没有 sid 就不许开始同步。
    final sid = conn.api.session?.sid ?? '';
    if (sid.isEmpty) {
      debugPrint('[chat] 跳过同步：这条连接还没有 sid（等登录完成再来）');
      return;
    }
    _conn = conn;
    _api = ChatApi(conn.api);
    await _syncLists();
    // 服务端设置（能力/限制）：登录后拉一次，之后靠 `setting.update` 增量更新
    unawaited(_loadServerSettings());
    unawaited(_loadAcl());
    // 免打扰（`User.Preference`）：原版在 `SyncWorker.fetchData` 里每次同步都拉
    unawaited(ref.read(snoozeControllerProvider.notifier).refresh());
    await _connectSocket(conn);
  }

  /// 拉一次 `SYNO.Chat.Admin.Setting`（失败不影响登录 —— 原版也是 best effort）
  Future<void> _loadServerSettings() async {
    final api = _api;
    if (api == null) return;
    try {
      final settings = await api.fetchServerSettings();
      await ref.read(serverSettingsProvider.notifier).apply(settings);
      final editAll = api.supports('SYNO.Chat.Admin.Setting', 4);
      // r319：异步空隙之后不许裸写 state（provider 可能已销毁）
      if (!ref.mounted) return;
      state = state.copyWith(
        supportsEditAllPost: editAll,
        supportsReadStatus: api.supports('SYNO.Chat.Admin.Setting', 3),
        supportsUserV3: api.supports('SYNO.Chat.User', 3),
        // 原版 `isSupportSubscribeApi()`：API 表里有 `SYNO.Chat.Post.Subscribe` 即算支持
        supportsSubscribeApi: api.supports('SYNO.Chat.Post.Subscribe', 1),
        // `Post/stick|unstick` 要 v2（v1 回 103「方法不存在」，见
        // docs/phase4-protocol.md §7）
        supportsStick: api.supports('SYNO.Chat.Post', 2),
      );
      debugPrint('[settings] 服务端设置：$settings (可编辑任意消息=$editAll)');
    } catch (e) {
      debugPrint('[settings] 拉服务端设置失败（用默认值）：$e');
    }
  }

  /// 拉一次权限表（`SYNO.Chat.Misc acl` v1）。原版在登录同步阶段做；
  /// 拿不到就保持"查不到即允许"的默认语义，界面不会因此变灰。
  Future<void> _loadAcl() async {
    final api = _api;
    if (api == null) return;
    try {
      final acls = await api.fetchAcl();
      await ref.read(myAclProvider.notifier).apply(acls);
      debugPrint('[acl] 权限表：$acls');
    } catch (e) {
      debugPrint('[acl] 拉权限表失败（按默认允许处理）：$e');
    }
  }

  /// 重新拉一次列表（下拉刷新 / 断线重连后）
  Future<void> refresh() async {
    final conn = _conn;
    if (conn == null) return;
    _api ??= ChatApi(conn.api);
    await _syncLists();
  }

  Future<void> _syncLists() async {
    final api = _api;
    if (api == null) return;

    // r319：异步空隙之后不许裸写 state（provider 可能已销毁）
    if (!ref.mounted) return;
    state = state.copyWith(phase: ChatSyncPhase.syncing, clearError: true);
    final store = ref.read(chatStoreProvider);
    try {
      // ① 原版登录链的第一步：`SYNO.Chat.User/login`（校时 + db_uuid + 我是谁）
      ChatUserLogin? login;
      try {
        login = await api.userLogin();
      } catch (_) {
        // 老服务端没有这个方法也不该挡住登录
      }
      // ★★ r326（D24）：`db_uuid` 原来**只存在内存里的 `state.dbUuid`** ⇒
      //   判据里那个 `state.dbUuid.isNotEmpty` 在**冷启动时永远为假**
      //   （进程刚起来 state 就是空串），于是"服务端换库 ⇒ 本地缓存作废"这条
      //   机制**跨启动永远不会触发** —— 属于 §2.0.45 的"封装了但没有 caller /
      //   前提不可达"family。走查实测：Mock 重启换了 `db_uuid`，屏上仍是上一轮
      //   （甚至上一台服务器）遗留的旧频道与旧消息。
      //   正解：把服务端的 `db_uuid` 记在本地键值表里（`clearAllData()` **不动**
      //   键值表 —— 见 `ChatStore.clearAllData` 的注释），冷启动也有得比。
      final localDbUuid = await store.setting(_kServerDbUuidKey);
      if (login != null &&
          login.dbUuid.isNotEmpty &&
          localDbUuid != null &&
          localDbUuid.isNotEmpty &&
          login.dbUuid != localDbUuid) {
        // 服务端换库了：本地缓存全部作废（原版 DbUuidException 会清库重登）
        await store.clearAllData();
      }
      if (login != null && login.dbUuid.isNotEmpty) {
        await store.setSetting(_kServerDbUuidKey, login.dbUuid);
      }

      final users = await api.listUsers();
      await store.upsertUsers(users);

      final me = await api.myUser();
      // login 里没有 user 段（老服务端/精简响应）时退回 `User/get`
      final loginId = login?.userId ?? 0;
      final myId = loginId > 0 ? loginId : (me?.userId ?? 0);

      final channels = await api.listChannels();
      // `removeMissing: true` = 剪掉服务端这次**全量**列表里没有的频道行，
      // 逐行对位官方 `DatabaseHelper.setChannels(channels, true)`
      // （`DatabaseHelper.java:703-727`：本地行不在传入列表里就
      // `delete("ChatChannel", "channel_id = ?")`）。
      //
      // 安全前提（已取证）：`SYNO.Chat.Channel/list` 在这条链路上是**全量**
      // 语义——官方 `AccountManager.fetchChannels` 的线参只有 `is_joined`
      // （`AccountManager.java:569-577`，无 offset/limit/since），且官方
      // `SyncWorker.fetchData` 传的就是 `"true"`；复合请求那条路官方显式传
      // false（`AccountManager.java:621`）因为复合只回部分结果，我们这条不是。
      // 我们的 `listChannels()` 默认 `is_joined='true'`，与官方逐字一致。
      //
      // 空列表 / 有失败消息的频道 / E2EE 本地设置三重保护在 store 层，见
      // `ChatStore.upsertChannels` 的注释。
      await store.upsertChannels(channels, removeMissing: true);

      _safeInvalidate(usersProvider);
      // r319：异步空隙之后不许裸写 state（provider 可能已销毁）
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: state.realtime ? ChatSyncPhase.ready : ChatSyncPhase.syncing,
        channelCount: channels.length,
        userCount: users.length,
        myUserId: myId,
        isAdmin: login?.isAdmin ?? state.isAdmin,
        clockSkewMillis: login?.skewMillis() ?? state.clockSkewMillis,
        dbUuid: login?.dbUuid.isNotEmpty == true
            ? login!.dbUuid
            : (localDbUuid ?? state.dbUuid),
      );
      // 同步成功 = "服务端现在能用" → 放开预加载节流
      // （原版 `SyncWorker` 成功时 `setSkipPostPreview(false)`）
      _clearPostPreviewSkip();
    } catch (e) {
      // ★ r670：**catch 里也必须挡**。r319 只给成功路径加了 `ref.mounted`，
      //   失败路径照旧裸写 ⇒ provider 已销毁时 `AnyNotifier.state` 抛
      //   `UnmountedRefException`，而它是**在用例跑完之后**冒出来的
      //   （Windows 站真机实测：整轮 16s 全绿后被打成 failed）。
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: ChatSyncPhase.error,
        error: userFacingError(e),
      );
    }
  }

  /// 通知侧「预加载消息」的节流位（原版 `skip_post_preview_mode`）：
  /// 登录/同步成功就清掉，让下一次通知重新尝试预加载。
  void _clearPostPreviewSkip() {
    try {
      ref.read(notificationServiceProvider).clearSkipPostPreview();
    } catch (_) {
      // 没有通知服务（离线测试）时忽略
    }
  }

  Future<void> _connectSocket(DsmConnection conn) async {
    final session = conn.session;
    if (session == null) {
      state = state.copyWith(
        phase: ChatSyncPhase.degraded,
        error: currentText().chatErrNotLoggedIn,
      );
      return;
    }

    _events?.cancel();
    _statuses?.cancel();
    _socket?.dispose();

    state = state.copyWith(
      baseUrl: conn.endpoint.baseUrl,
      certUntrusted:
          conn.certPinned &&
              !MediaTlsPolicy.isInstalledFor(conn.endpoint.baseUrl),
    );
    final socket = ref.read(chatSocketFactoryProvider)(
      conn.endpoint.baseUrl,
      session.sid,
      session.synotoken,
    );
    _socket = socket;

    _statuses = socket.statuses.listen((s) {
      state = state.copyWith(
        socketStatus: s,
        phase: s == ChatSocketStatus.ready
            ? ChatSyncPhase.ready
            : (state.phase == ChatSyncPhase.error
                  ? ChatSyncPhase.error
                  : ChatSyncPhase.degraded),
      );
    });
    // 事件处理里到处 `await`，而 provider 可能在等待期间被销毁（真机 teardown
    // 时炸过 `UnmountedRefException`）。已销毁就把在飞的这张事件直接丢掉，
    // 否则异常会从 listen 里冒出来把 socket 的监听链打断。
    _events = socket.events.listen((e) {
      handleEvent(e).catchError((Object err, StackTrace st) {
        if (_disposed || !ref.mounted) return;
        debugPrint('[socket] 事件处理失败 ${e.event}：$err');
      });
    });

    try {
      await socket.connect();
      await socket.waitReady(timeout: const Duration(seconds: 20));
      // ★ r319：**异步空隙之后必须查 `ref.mounted`**。
      //   真机/桌面走查里抓到 `UnmountedRefException`（"Cannot use the Ref of
      //   NotifierProvider<ChatSessionController…> after it has been disposed"）：
      //   退出会话/关掉页面时 socket 还连在路上，回来写 `state` 就炸。
      //   修法照 Riverpod 自己给的口径（"check ref.mounted after async gaps"）。
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: ChatSyncPhase.ready,
        connId: socket.connId,
        socketStatus: ChatSocketStatus.ready,
        clearError: true,
      );
      // Phase 8：实时通道通了就拉前台常驻服务，退到后台也不被回收
      unawaited(_startForegroundService(conn));
    } catch (e) {
      // 降级：列表可用，只是不实时
      // （同上的异步空隙守卫：连接失败也可能发生在会话已经被销毁之后）
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: state.phase == ChatSyncPhase.error
            ? ChatSyncPhase.error
            : ChatSyncPhase.degraded,
        error: currentText().chatErrRealtimeNotReady(userFacingError(e)),
      );
    }
  }

  /// 会话过期自动重登之后，用**新 sid** 重建实时通道。
  ///
  /// 旧 socket 是拿着旧 sid 连的，服务端那边会话已经失效 → 不重建的话会一直
  /// 卡在重连失败。这里只重连实时通道，不动已经同步好的列表数据。
  Future<void> restartRealtime(DsmSession renewed) async {
    final conn = _conn;
    if (conn == null) return;
    debugPrint('[chat] 用新 sid 重建实时通道');
    await _connectSocket(conn);
  }

  /// Phase 8：拉起前台常驻服务（失败不影响使用）
  Future<void> _startForegroundService(DsmConnection conn) async {
    try {
      final bg = ref.read(backgroundServiceProvider);
      // Android 13+ 需要通知权限，没有权限前台服务通知不显示（服务仍可跑）
      await bg.requestNotificationPermission();
      if (!ref.mounted) return; // 等待期间可能已经登出/析构
      await bg.start(
        title: conn.profile.value.isEmpty
            ? platformAppName()
            : conn.profile.value,
        text: platformText().keepAliveText,
      );
      // ★ r342 D45：这里**不再写会话快照** —— 界面一律走实时查询 provider
      //   （`foregroundServiceRunningProvider`），否则"服务在跑"会有两份表示（§2.0.26），
      //   两份不一致时界面就说谎（真机实证过）。
      await bg.isRunning();
    } catch (e) {
      debugPrint('[p8] 前台服务启动失败：$e');
    }
  }

  /// Phase 8：登出/断开时收掉前台服务
  Future<void> stopBackgroundService() async {
    try {
      await ref.read(backgroundServiceProvider).stop();
    } catch (_) {}
  }

  // ------------------------------------------------------------ 事件分发

  /// 处理一条服务端事件。**public** 是为了让离线测试能直接喂真实形状的载荷
  /// （见 test/chat_events_test.dart），不必先起一个 websocket。
  Future<void> handleEvent(ChatSocketEvent e) async {
    // 销毁之后还在飞的广播直接丢掉（见 `_disposed` 的说明）
    if (_disposed) return;
    final store = ref.read(chatStoreProvider);
    final payload = e.asMap;

    switch (e.event) {
      case SocketEvent.clientPostCreate:
        if (payload == null) return;
        final channelId = _int(payload['channel_id']);
        final data = payload['data'];
        final post = data is Map ? Map<String, dynamic>.from(data) : const {};
        final postId = _int(post['post_id']);
        final createAt = _int(post['create_at']);
        // 实测：作者在 data.creator_id（顶层 user_id 也在）
        final creatorId = _int(post['creator_id']) > 0
            ? _int(post['creator_id'])
            : _int(payload['user_id']);

        if (creatorId != 0 && creatorId == state.myUserId) {
          // 同账号的**另一台设备**发的：不算未读，只更新排序时间
          await store.touchChannelOnOwnPost(channelId: channelId, at: createAt);
        } else {
          await store.applyPostCreate(channelId: channelId, createAt: createAt);
        }
        // 话题回复：父消息的回复数 +1，频道的话题未读 +1（自己发的不算）
        final threadId = _int(post['thread_id']);
        if (threadId > 0) {
          await store.bumpCommentCount(channelId, threadId, at: createAt);
          if (creatorId == 0 || creatorId != state.myUserId) {
            await store.applyCommentCreate(
              channelId: channelId,
              threadId: threadId,
            );
          }
        }
        // 事件里只有精简 PostVo（没有 message），正文得回服务端捞
        await _fetchPostIfMissing(channelId, postId);

      case SocketEvent.clientChannelJoin:
        if (payload == null) return;
        final dto = ChannelDto.fromJson(payload).copyWith(isJoined: true);
        await store.upsertChannels([dto]);

      // `client.channel.disjoin` 的载荷是 DisjoinVo `{channel_id, is_close}`：
      // `is_close == true` 表示频道被**关闭**（不是单纯退出）→ 原版
      // `SocketHelper.lambda$disjoinChannel$50` 走 `databaseHelper.closeChannel(id)`
      // 删掉频道行；否则只把 `is_joined` 置 false。
      case SocketEvent.clientChannelDisjoin:
        if (payload == null) return;
        final dcId = _int(payload['channel_id']);
        if (dcId <= 0) return;
        if (payload['is_close'] == true) {
          await store.deleteChannel(dcId);
          _safeInvalidate(postsProvider(dcId));
        } else {
          await store.setJoined(dcId, joined: false);
        }

      // 顶层事件（不是 `client.broadcast` 里的类型，原版用 `.on(...)` 注册）
      // `client.channel.brokenuser`：某个成员在这个加密频道解不开
      // （原版 `addChannelBrokenUsers`，去重追加；界面靠它给成员标 ⚠）
      case SocketEvent.clientChannelBrokenUser:
        if (payload == null) return;
        final bCid = _int(payload['channel_id']);
        final bUid = _int(payload['user_id']);
        if (bCid > 0 && bUid > 0) {
          // 自己：本地能解开这个频道就说明这条广播是"重传密钥"流程的中间态
          // （真机实测 `update_key` 本身就会触发一次 brokenuser），别给自己挂 ⚠
          if (bUid == state.myUserId) {
            final ch = await _channelById(store, bCid);
            final svc = ref.read(e2eeServiceProvider);
            if (ch != null && svc.keyState(ch) == ChannelKeyState.ready) {
              return;
            }
          }
          await store.addChannelBrokenUsers(bCid, [bUid]);
        }

      // `client.user.updatekey`：某人换了密钥对
      //   ① 载荷带的频道密钥（`channels: [{channel_id, channel_key_enc}]`）逐个更新；
      //   ② 是我自己 → 采纳新的密钥对（本地缓存 + 内存身份）；
      //   ③ 用户表里的 `public_key` 跟着更新。
      case SocketEvent.clientUserUpdateKey:
        if (payload == null) return;
        final uUid = _int(payload['user_id']);
        final channels = payload['channels'];
        if (channels is List) {
          for (final raw in channels) {
            if (raw is! Map) continue;
            final cid = _int(raw['channel_id']);
            if (cid <= 0) continue;
            final keyEnc = '${raw['channel_key_enc'] ?? ''}';
            final existing = await _channelById(store, cid);
            if (existing == null || keyEnc.isEmpty) continue;
            await store.upsertChannels([
              existing.copyWith(channelKeyEnc: keyEnc),
            ]);
          }
        }
        final newPublic = '${payload['public_key'] ?? ''}';
        final newPrivateEnc = '${payload['private_key_enc'] ?? ''}';
        if (uUid > 0 && (newPublic.isNotEmpty || newPrivateEnc.isNotEmpty)) {
          await store.setUserPublicKey(
            uUid,
            publicKey: newPublic.isEmpty ? null : newPublic,
            privateKeyEnc: newPrivateEnc.isEmpty ? null : newPrivateEnc,
          );
        }
        if (uUid > 0 && uUid == state.myUserId && newPublic.isNotEmpty) {
          // 自己换密钥对（另一台设备改的 / 服务端重置）：本机身份跟着换，
          // 原版同时发 `PasscodeEvent.keyUpdate()` 让界面刷新
          final svc = ref.read(e2eeServiceProvider);
          final current = svc.identity;
          if (current == null || current.publicKey != newPublic) {
            await svc.adoptServerIdentity(
              E2eeIdentity(
                publicKey: newPublic,
                privateKeyEnc: newPrivateEnc.isEmpty
                    ? (current?.privateKeyEnc ?? '')
                    : newPrivateEnc,
              ),
            );
            // E2EE 页下次 `load()` 就会读到新身份（这里不引
            // features/settings 的 provider —— 那两个文件互相 import 会绕环）
            debugPrint('[keypair] 采纳服务端下发的新密钥对（另一台设备改的）');
          }
        }

      // `client.user.update` 是**顶层**事件（原版注册了它）；
      // `user.create` / `user.update` 正常走 `client.broadcast`，这里顺手也认顶层，
      // 老服务端换个信封也不会漏（类型名就是 [BroadcastType] 里的那两个）。
      case SocketEvent.clientUserUpdate:
      case BroadcastType.userCreate:
      case BroadcastType.userUpdate:
        if (payload == null) return;
        await store.upsertUserFromEvent(payload);
        _safeInvalidate(usersProvider);

      // 管理员全局隐藏 / 取消。
      //
      // ⚠️ 这两个是**顶层 socket 事件**，不走 `client.broadcast` ——
      // 2.4.7 服务端 `chat_service/service.js` 的 `onCloseChannel` 里是
      // `n = "client.channel.hide_global"; this.io.to(room).emit(n, e)`，
      // 也就是说事件名直接就是它，载荷是
      // `{channel_id, channel_close_type}`（**没有时间戳**，`channel` 已被 delete）。
      // 原版 APK 的 `ChannelGlobalHideVo` 也只解析 `channel_id`，处理时
      // `hideGlobalAt = System.currentTimeMillis()`（unhide 置 0）。
      // （早先这里错放在 `_onBroadcast` 的类型分支里，真机上永远收不到；
      //   下面 `_onBroadcast` 里也留了一份兜底，防老服务端换个壳发。）
      case SocketEvent.clientChannelHideGlobal:
        await _applyHideGlobal(payload, store, hide: true);

      case SocketEvent.clientChannelUnhideGlobal:
        await _applyHideGlobal(payload, store, hide: false);

      case SocketEvent.clientChannelTypingV2:
        if (payload != null) {
          ref
              .read(typingProvider.notifier)
              .applyV2(payload, myUserId: state.myUserId);
        }

      case SocketEvent.clientChannelTyping:
        if (payload != null) {
          ref
              .read(typingProvider.notifier)
              .applyV1(payload, myUserId: state.myUserId);
        }

      case SocketEvent.clientBroadcast:
        await _onBroadcast(payload, store);

      default:
        // 表外的顶层事件：只记一次，便于发现协议漂移
        if (_loggedUnknownEvents.add(e.event)) {
          debugPrint('[socket] 未处理的顶层事件：${e.event}');
        }
    }
  }

  /// 全局隐藏 / 取消：`hide=true` 记本地当前时间，`hide=false` 清零。
  ///
  /// 只在 `channel_id` 有效时动手（服务端会把 `channel` 字段删掉，别的地方没得取）。
  Future<void> _applyHideGlobal(
    Map<String, dynamic>? payload,
    ChatStore store, {
    required bool hide,
  }) async {
    if (payload == null) return;
    final cid = _int(payload['channel_id']);
    if (cid <= 0) return;
    await store.setHideGlobalAt(
      cid,
      at: hide ? DateTime.now().millisecondsSinceEpoch : 0,
    );
  }

  Future<void> _onBroadcast(
    Map<String, dynamic>? payload,
    ChatStore store,
  ) async {
    if (_disposed || payload == null) return;
    // 注意：`_disposed` 只在 dispose 时置位，而广播处理里到处 `await`，
    // 等回来时 provider 可能已经被销毁（真机 teardown 时炸过 UnmountedRefException）
    // —— 每个"再碰 ref"的地方都得重新确认一次。
    final type = payload['type'];
    final data = payload['data'];
    if (type is! String || data is! Map) return;
    final map = Map<String, dynamic>.from(data);

    switch (type) {
      case BroadcastType.userUpdate:
      case BroadcastType.userCreate:
        await store.upsertUserFromEvent(map);
        _safeInvalidate(usersProvider);

      case BroadcastType.channelUpdate:
        await store.upsertChannels([ChannelDto.fromJson(map)]);

      case BroadcastType.postDelete:
        // 实测载荷：{channel_id, post_id, lazy_delete, disable_system_post}
        final cid = _int(map['channel_id']);
        final pid = _int(map['post_id']);
        if (cid > 0 && pid > 0) await store.deletePost(cid, pid);

      case BroadcastType.postStar:
      case BroadcastType.postUnstar:
        // 载荷是**完整 PostVo**（SocketHelper.starPost）
        final dto = PostDto.fromJson(map);
        if (dto.channelId > 0 && dto.postId > 0) {
          await store.applyPostPatch(
            dto.channelId,
            dto.postId,
            isStar: type == BroadcastType.postStar,
          );
        }

      case BroadcastType.postPin:
      case BroadcastType.postUnpin:
        // 载荷是精简的 {channel_id, post_id, last_pin_at, user_id}（无 post_id 全文）。
        //
        // 对齐原版 `PostHelper.pinPost(postId, lastPinAt)`：**只写
        // `last_pin_at`，不动 `is_sticky`**。`is_sticky` 是另一套 ——
        // `Post/stick` v2 的"置顶卡片"（只有它才画图钉、才给"置顶/取消置顶"菜单），
        // 别把两件事混在一起。
        //
        // 真机实测（`tool/probe_pin2.dart`，2.4.7）：
        //   `Post/pin` v1 → 服务端把 `last_pin_at` 写上、`is_sticky` 保持 false，
        //                    并且 `Post/list has=['pin']` 能列出它（按 last_pin_at 过滤）；
        //   `Post/unpin` → `last_pin_at` 归零。
        final cid = _int(map['channel_id']);
        final pid = _int(map['post_id']);
        if (cid > 0 && pid > 0) {
          await store.applyPostPatch(
            cid,
            pid,
            lastPinAt: type == BroadcastType.postUnpin
                ? 0
                : _int(map['last_pin_at']),
          );
        }

      // 投票变更（发起人结束投票 / 有人投票 / 删投票）：
      // 广播里带的是新的 vote 结构（有时只有 channel_id + post_id + vote），
      // 最省事又不会写错的解法就是整条覆盖或补丁式写回 props.vote。
      case BroadcastType.postVoteUpdate:
      case BroadcastType.postVoteClose:
      case BroadcastType.postVoteDelete:
        final cid = _int(map['channel_id']);
        final pid = _int(map['post_id']);
        final vote =
            map['vote'] ??
            (map['props'] is Map ? (map['props'] as Map)['vote'] : null);
        if (pid > 0) {
          final channel = cid > 0 ? cid : await store.findPostChannel(pid);
          if (channel != null) {
            final existing = await store.postById(channel, pid);
            if (existing != null) {
              await store.upsertPosts([
                existing.copyWith(props: {...existing.props, 'vote': vote}),
              ]);
            }
          }
        }

      // 提醒变更：`{channel_id, post_id, remind_at}`
      case BroadcastType.postReminderSet:
      case BroadcastType.postReminderDelete:
        final cid = _int(map['channel_id']);
        final pid = _int(map['post_id']);
        if (pid > 0) {
          final channel = cid > 0 ? cid : await store.findPostChannel(pid);
          if (channel != null) {
            final at = _int(map['remind_at']);
            if (type == BroadcastType.postReminderSet && at > 0) {
              await store.applyPostPatch(
                channel,
                pid,
                props: {'remind_at': at},
              );
              // 到点弹通知的账本（原版靠 FCM 推送，我们走本地通知）
              await ref
                  .read(reminderSchedulerProvider)
                  .arm(postId: pid, channelId: channel, remindAt: at);
            } else {
              await store.applyPostPatch(
                channel,
                pid,
                clearProps: const ['remind_at'],
              );
              if (ref.mounted) {
                await ref.read(reminderSchedulerProvider).disarm(pid);
              }
            }
          }
        }

      case BroadcastType.postUpdate:
        // 载荷是完整 PostVo：整条覆盖（正文/星标/回应都可能变）
        final dto = PostDto.fromJson(map);
        final cid = dto.channelId;
        final pid = dto.postId;
        if (pid > 0) {
          if (cid > 0) {
            await store.upsertPosts([dto]);
          } else {
            // 广播偶尔不带 channel_id —— 用本地已有那条的频道补上
            final hit = await store.findPostChannel(pid);
            if (hit != null) {
              await store.applyPostPatch(
                hit,
                pid,
                message: dto.message,
                isStar: dto.isStar,
                isSticky: dto.isSticky,
                updateAt: dto.updateAt,
                reactions: dto.reactions,
              );
            }
          }
        }

      case BroadcastType.postDeleteBatch:
      case BroadcastType.postDeleteSearchList:
        // 真实形状是 `{channel_id_list: [..]}`（管理员批量清空频道）——
        // 原版 `SocketHelper.deletePostByAdmin` 就是这么读的；我们之前猜成
        // `{channel_id, post_ids}` 并喂自造载荷测试，属自证自话。
        final ids = map['channel_id_list'];
        if (ids is List) {
          var purged = 0;
          for (final raw in ids) {
            final cid = _int(raw);
            if (cid > 0) {
              await store.purgeChannelPosts(cid);
              purged++;
            }
          }
          // ★ 第 40 轮：官方 `str_post_delete_by_admin` 会**告诉用户**
          // 「部分帖子已被管理员删除。此页面将在一分钟后刷新。」
          // 我们之前是**静默清空** —— 消息无声消失对用户是 bug。
          if (purged > 0) {
            // r319：异步空隙之后不许裸写 state（provider 可能已销毁）
            if (!ref.mounted) return;
            state = state.copyWith(adminDeletedSeq: state.adminDeletedSeq + 1);
          }
        }

      case BroadcastType.channelViewComment:
        // {channel_id, last_view_comment_at, user_id, thread_id?} —— 只处理自己的
        final cid = _int(map['channel_id']);
        final uid = _int(map['user_id']);
        if (cid > 0 && (uid == 0 || uid == state.myUserId)) {
          final tid = _int(map['thread_id']);
          await store.resetThreadUnread(
            cid,
            threadId: tid > 0 ? tid : null,
            lastViewCommentAt: _int(map['last_view_comment_at']),
          );
        }

      // `channel.view` —— 我的**另一台设备**把这个频道读掉了（载荷
      // `{channel_id, last_view_at, user_id}`）。原版不看 user_id，但如果服务端
      // 真把它广播给所有成员，照抄就会把别人的已读当成我的 —— 加一道
      // `user_id == 自己` 的闸，实测服务端只发给本人，两者行为一致。
      case BroadcastType.channelView:
        final cid = _int(map['channel_id']);
        final uid = _int(map['user_id']);
        if (cid > 0 && (uid == 0 || uid == state.myUserId)) {
          await store.applyChannelView(
            cid,
            lastViewAt: _int(map['last_view_at']),
          );
        }

      // `channel.hide` / `channel.show`：`{channel_id, last_hide_at, user_id}`
      case BroadcastType.channelHide:
        final cid = _int(map['channel_id']);
        if (cid > 0) {
          await store.setLastHideAt(cid, lastHideAt: _int(map['last_hide_at']));
        }

      case BroadcastType.channelShow:
        final cid = _int(map['channel_id']);
        if (cid > 0) await store.setLastHideAt(cid, lastHideAt: 0);

      // 话题订阅：**只认自己的**订阅关系（原版先比对 user_id 再落库）
      case BroadcastType.postSubscribe:
      case BroadcastType.postUnsubscribe:
        final uid = _int(map['user_id']);
        if (uid != 0 && uid != state.myUserId) break;
        final pid = _int(map['post_id']);
        if (pid > 0) {
          final cid = _int(map['channel_id']) > 0
              ? _int(map['channel_id'])
              : await store.findPostChannel(pid) ?? 0;
          if (cid > 0) {
            await store.setSubscribed(
              cid,
              pid,
              subscribed: type == BroadcastType.postSubscribe,
              channelOrderTime: _int(map['channel_order_time']) > 0
                  ? _int(map['channel_order_time'])
                  : null,
            );
          }
        }

      // `user.delete`：载荷就一个 `{user_id}`（原版 `deleteUser` → 标 disabled）
      case BroadcastType.userDelete:
        final uid = _int(map['user_id']);
        if (uid > 0) {
          await store.markUserDeleted(uid, deleteAt: _int(map['delete_at']));
          _safeInvalidate(usersProvider);
        }

      // `channel.rescue`：有人把某个成员"救回来"了 —— 载荷是 ChannelVo
      // （`{channel_id, user_id, channel_key_enc, …}`）。原版先把这个 user 从
      // broken 列表摘掉，再用载荷里的频道密钥覆盖本地。
      case BroadcastType.channelRescue:
        final rCid = _int(map['channel_id']);
        final rUid = _int(map['user_id']);
        if (rCid > 0) {
          if (rUid > 0) await store.removeChannelBrokenUsers(rCid, [rUid]);
          final keyEnc = '${map['channel_key_enc'] ?? ''}';
          final existing = await _channelById(store, rCid);
          if (existing != null) {
            await store.upsertChannels([
              existing.copyWith(
                channelKeyEnc: keyEnc.isEmpty ? existing.channelKeyEnc : keyEnc,
              ),
            ]);
          }
          _safeInvalidate(postsProvider(rCid));
        }

      // `channel.archive`：频道被归档 → 本地把这个频道的消息清掉
      // （原版 `databaseHelper.deleteChannelPosts(channelId)`）
      // 载荷是 ChannelVo（`{channel_id, ...}`），不是 `{type, data}` 包一层。
      case BroadcastType.channelArchive:
        final archived = _int(map['channel_id']);
        if (archived > 0) {
          await store.purgeChannelPosts(archived);
          _safeInvalidate(postsProvider(archived));
        }

      // `channel.preference`：别的设备改了通知档位
      // 载荷 `{channel_id, preferences: ChannelPreferenceVo}`
      case BroadcastType.channelPreference:
        final cid = _int(map['channel_id']);
        final pref = map['preferences'];
        if (cid > 0 && pref is Map) {
          final parsed = ChannelPreference.fromJson(
            Map<String, dynamic>.from(pref),
          );
          await store.applyChannelPreference(
            cid,
            notificationDesktop: parsed.notificationDesktop,
            notificationMobile: parsed.notificationMobile,
            notificationMute: parsed.notificationMute,
          );
        }

      // `post.schedule.set` / `delete`：定时消息增删 → 让定时列表重新拉
      // （原版是发 EventBus 给界面，我们自己按需重取）
      case BroadcastType.postScheduleSet:
      case BroadcastType.postScheduleDelete:
        final sid = _int(map['channel_id']);
        if (sid > 0) {
          ref.read(scheduleRevisionProvider(sid).notifier).bump();
        }

      // 兜底：万一某个版本把 hide/unhide 包进 `client.broadcast` 发
      // （type 还是那两个 socket 事件名，服务端只是换了信封）
      case SocketEvent.clientChannelHideGlobal:
        await _applyHideGlobal(map, store, hide: true);

      case SocketEvent.clientChannelUnhideGlobal:
        await _applyHideGlobal(map, store, hide: false);

      case BroadcastType.settingUpdate:
        // 管理员改了服务端设置（文件大小上限 / 编辑窗口 / 加密开关…）
        await ref
            .read(serverSettingsProvider.notifier)
            .apply(ServerSettings.fromJson(map), merge: true);

      case BroadcastType.channelStar:
      case BroadcastType.channelUnstar:
        final id = _int(map['channel_id']);
        if (id == 0) return;
        final existing = await _channelById(store, id);
        if (existing != null) {
          await store.upsertChannels([
            existing.copyWith(isStar: type == BroadcastType.channelStar),
          ]);
        }

      default:
        // 表外的广播类型：只记一次（原版遇到未知 type 直接丢弃）
        if (_loggedUnknownBroadcasts.add(type)) {
          debugPrint('[socket] 未处理的广播类型：$type');
        }
    }
  }

  /// 加密频道的附件访问器（文件名解码 + 内容解密）；非加密频道返回 null。
  AttachmentAccess? attachmentAccessFor(ChannelDto? channel) {
    final api = _api;
    if (channel == null || !channel.encrypted || api == null) return null;
    final svc = ref.read(e2eeServiceProvider);
    if (!svc.isConfigured) return null;
    return AttachmentAccess(channelId: channel.channelId, svc: svc, api: api);
  }

  Future<ChannelDto?> _channelById(ChatStore store, int id) async {
    final all = await store.allChannels();
    for (final c in all) {
      if (c.channelId == id) return c;
    }
    return null;
  }

  // ------------------------------------------------------------ 频道管理
  //
  // 原版把这些放在「频道设置页」(`ChannelSettingFragment`) + 二级的
  // `ChannelManageFragment`；这里做成聊天页的一个底部弹窗，规则见
  // `channel_manage_rules.dart`。

  /// 收藏 / 取消收藏频道（`SYNO.Chat.Channel / star|unstar`，v1）。
  ///
  /// 原版 `ChannelSettingPresenter.save()` → `AccountManager.starChannel`，
  /// 成功后本地直接改 `is_star`（服务端也会广播 `channel.star/unstar`，
  /// 我们两个路径都落同一次本地写，重复无害）。
  Future<void> setChannelStar(int channelId, {required bool star}) async {
    final api = _api;
    if (api == null) return;
    await api.starChannel(channelId, star: star);
    final store = ref.read(chatStoreProvider);
    final existing = await _channelById(store, channelId);
    if (existing != null) {
      await store.upsertChannels([existing.copyWith(isStar: star)]);
    }
  }

  /// 退出频道（`SYNO.Chat.Channel.Named / disjoin` v1）。
  ///
  /// 成功后本地先按"非关闭"处理（`is_joined = false`），不等
  /// `client.channel.disjoin` 广播，界面立刻消失。
  Future<void> leaveChannel(int channelId) async {
    final api = _api;
    if (api == null) return;
    await api.disjoinNamedChannel(channelId);
    final store = ref.read(chatStoreProvider);
    await store.setJoined(channelId, joined: false);
  }

  /// 归档频道（`SYNO.Chat.Channel / archive` v2）。
  ///
  /// ⚠️ **真机实测（NAS 2.4.7 + 非管理员账号 + 自己建的私有频道）**：
  /// `archive` v2 返回 `{"success":true}`，但频道仍是 `is_joined=true`、
  /// `Archive/list` 里也没有新记录 —— 即服务端**接受了请求但没有归档**
  /// （v4 直接 103，印证 2.4.7 的方法表里 v4 没有 archive）。
  /// 所以这里调用后**回查一次**：服务端真归档了才把它从本地移出，
  /// 否则保持原样并把 `false` 返回给界面（界面提示"服务端未归档"），
  /// 避免乐观删掉后下一次同步又冒出来。
  ///
  /// 返回 true = 服务端已归档（本地已移出列表 + 清消息）。
  Future<bool> archiveChannel(int channelId) async {
    final api = _api;
    if (api == null) return false;
    await api.archiveChannel(channelId);
    final store = ref.read(chatStoreProvider);
    var applied = false;
    try {
      final got = await api.listChannelsByIds([channelId]);
      applied = got.isEmpty || !got.single.isJoined;
    } catch (_) {
      applied = true; // 拿不到 = 已经不在我的列表里
    }
    if (!applied) return false;
    await store.setJoined(channelId, joined: false);
    await store.purgeChannelPosts(channelId);
    _safeInvalidate(postsProvider(channelId));
    return true;
  }

  /// 关闭频道 / 会话（`SYNO.Chat.Channel / close` v2，必须带当前 `conn_id`）。
  ///
  /// 不可逆：服务端删除频道数据，本地整条删掉（对齐原版
  /// `DatabaseHelper.closeChannel`）。
  Future<void> closeChannel(int channelId) async {
    final api = _api;
    final connId = state.connId;
    if (api == null) return;
    if (connId == null || connId.isEmpty) {
      throw StateError(currentText().chatErrNoConnId);
    }
    await api.closeChannel(channelId, connId: connId);
    final store = ref.read(chatStoreProvider);
    await store.deleteChannel(channelId);
    _safeInvalidate(postsProvider(channelId));
  }

  /// 服务端是否支持 `SYNO.Chat.Channel` v2（归档/关闭的前提，原版
  /// `ApiManager.support("SYNO.Chat.Channel", 2)`）。
  bool get supportsChannelV2 => _api?.supports('SYNO.Chat.Channel', 2) ?? false;

  /// 服务端是否支持「会话转专用频道」（原版
  /// `ApiManager.support(ChatChannelAnonymous, 2)`，只有 v2 有 `promote`）。
  bool get supportsPromoteAnonymous =>
      _api?.supports('SYNO.Chat.Channel.Anonymous', 2) ?? false;

  /// 把一对一（匿名）会话升级成专用频道
  /// （`SYNO.Chat.Channel.Anonymous / promote` v2）。
  ///
  /// 成功后把返回的频道对象合并进本地（类型从 anonymous 变成服务端给的类型），
  /// 再拉一次频道列表把服务端状态对齐 —— 原版成功后只是 `dismiss()`，
  /// 靠 `channel.set` / `channel.create` 广播回来，我们两条都做（广播丢了也不怕）。
  Future<ChannelDto?> promoteChannel(
    int channelId, {
    required String name,
    required String purpose,
  }) async {
    final api = _api;
    if (api == null) return null;
    await api.promoteAnonymous(
      channelId: channelId,
      name: name,
      purpose: purpose,
    );
    // ⚠️ promote 的响应是 `BasicVo`：真机实测成功也只回 `{}`，**没有 channel 对象**。
    // 升级后的类型/名字只能回拉 —— 先 refresh，再从本地权威行读回来
    // （原版也是靠 `channel.*` 广播刷新，只是它不关心返回值）。
    await refresh();
    _safeInvalidate(postsProvider(channelId));
    return _channelById(ref.read(chatStoreProvider), channelId);
  }

  /// 频道本地消息数（归档条件"频道里得有消息"用；原版拿列表 itemCount）。
  Future<int> postCountOf(int channelId) =>
      ref.read(chatStoreProvider).countPosts(channelId);

  /// 告诉服务端"这条连接正在看这个频道"（`Channel / enter`）。
  ///
  /// 对位原版 `ChannelFragment.enterChannel()` → `ChannelPresenter.enterChannel`：
  /// 每次进频道页都会调，成功后紧接着刷 `Channel.Hashtag/list`（我们由标签页自己拉）。
  /// 没有 conn_id 时原版直接不发请求 —— 这里也跳过（返回 false）。
  Future<bool> enterChannel(int channelId) async {
    // 原版 `ChannelFragment.enterChannel()` 的顺序是：
    //   enterChannel → checkEncrypt → **updateDBAllOutDatedPosts** → queryDBPosts
    // 也就是说"进频道"顺手把本地没发成功的消息标成"已过期"（state=3），
    // 长按它们才会出现"重新发送/编辑/删除"。这一步纯本地，没 conn_id 也要做。
    unawaited(markOutdatedPosts(channelId));
    final api = _api;
    final connId = state.connId;
    if (api == null || connId == null || connId.isEmpty) {
      debugPrint('[enter] 还没有 conn_id，跳过 #$channelId 的 enter');
      return false;
    }
    try {
      await api.enterChannel(channelId, connId);
      debugPrint('[enter] #$channelId 已进入');
      // 原版 enter 之后紧接着 `fetchChannelHashtag` → `setChannelHashtags`，
      // 输入框的 `#` 联想就读这一列；标签列表也会顺带刷新。
      unawaited(_refreshChannelHashtags(channelId));
      return true;
    } catch (e) {
      // 进频道失败不该影响读消息（原版也只是 log）
      debugPrint('[enter] enter 失败（不影响阅读）：$e');
      return false;
    }
  }

  /// 拉一次频道的标签并落库（原版 `AccountManager.fetchChannelHashtag`）。
  Future<void> _refreshChannelHashtags(int channelId) async {
    final api = _api;
    if (api == null) return;
    try {
      final tags = await api.channelHashtags(channelId);
      await ref.read(chatStoreProvider).updateChannelHashtags(channelId, tags);
      _safeInvalidate(channelHashtagsProvider(channelId));
    } catch (e) {
      debugPrint('[tags] 刷新频道 #$channelId 标签失败（不影响阅读）：$e');
    }
  }

  /// 本地缓存的频道标签（输入框 `#` 联想用；空表示还没同步过）。
  Future<List<String>> cachedChannelHashtags(int channelId) =>
      ref.read(chatStoreProvider).channelHashtags(channelId);

  /// 主动标记频道已读；返回写入本地的 `last_view_at`。
  Future<int> markRead(int channelId) async {
    final conn = _conn;
    final api = _api;
    if (conn == null || api == null) return 0;
    var lastViewAt = 0;
    final connId = state.connId;
    if (connId != null && connId.isNotEmpty) {
      try {
        // 服务端返回的 last_view_at 才是权威时间点，本地照它写
        lastViewAt = await api.viewChannel(channelId, connId);
      } catch (_) {
        // 已读上报失败不该影响本地状态
      }
    }
    final at = lastViewAt > 0
        ? lastViewAt
        : DateTime.now().millisecondsSinceEpoch;
    await ref.read(chatStoreProvider).markRead(channelId, nowMillis: at);
    return at;
  }

  // ------------------------------------------------------------ 消息

  /// 收到通知后**预加载**该频道的一窗消息（原版 `PostPreviewWorker`）。
  ///
  /// 逐行对位原版：`fetchServerPostsAndReset(-1, channelId, 40, 40)` →
  /// `Post/list`（`channel_id` + `prev_count=40` + `next_count=40` + `has=[thread]`）
  /// → **`resetPosts`（替换而不是合并）**，这样用户点通知进来时上下都有 40 条。
  ///
  /// 返回拉到的条数；失败返回 -1（调用方据此节流，原版是 `skip_post_preview`）。
  Future<int> prefetchChannelPosts(int channelId, {int count = 40}) async {
    if (channelId <= 0) return -1;
    final api = _api;
    if (api == null) return -1;
    try {
      final raw = await api.listPosts(
        channelId: channelId,
        prevCount: count,
        nextCount: count,
        has: kPostHas,
      );
      final posts = _parsePosts(raw, channelId);
      if (posts.isEmpty) return 0;
      await ref.read(chatStoreProvider).replaceChannelPosts(channelId, posts);
      return posts.length;
    } catch (e) {
      debugPrint('[p9] 预加载频道 #$channelId 消息失败：$e');
      return -1;
    }
  }

  /// 打开频道时拉第一页（**幂等**：本地已有消息就不重复拉，除非 force）。
  Future<int> loadPosts(
    int channelId, {
    bool force = false,
    int limit = 50,
    int aroundPostId = 0,
  }) async {
    final api = _api;
    if (api == null) return 0;
    final store = ref.read(chatStoreProvider);
    if (!force && aroundPostId == 0) {
      final cached = await store.postsForChannel(channelId, limit: 1);
      if (cached.isNotEmpty) return 0;
    }
    // aroundPostId：从搜索结果跳过来，拉"这条周围的一窗"
    final raw = await api.listPosts(
      channelId: channelId,
      postId: aroundPostId > 0 ? aroundPostId : null,
      prevCount: aroundPostId > 0 ? limit ~/ 2 : limit,
      nextCount: aroundPostId > 0 ? limit ~/ 2 : 0,
      has: kPostHas,
    );
    final posts = _parsePosts(raw, channelId);
    await store.upsertPosts(posts);
    return posts.length;
  }

  /// 向上翻页：以本地最旧那条的 post_id 作游标。
  /// 返回 false 表示没有更多了。
  Future<bool> loadOlderPosts(int channelId, {int limit = 50}) async {
    final api = _api;
    if (api == null) return false;
    final store = ref.read(chatStoreProvider);
    final cached = await store.postsForChannel(channelId, limit: 1);
    if (cached.isEmpty) {
      final n = await loadPosts(channelId, force: true, limit: limit);
      return n >= limit;
    }
    final oldest = cached.last.postId; // postsForChannel 新的在前
    final raw = await api.listPosts(
      channelId: channelId,
      postId: oldest,
      prevCount: limit,
      nextCount: 0,
      has: kPostHas,
    );
    final posts = _parsePosts(
      raw,
      channelId,
    ).where((p) => p.postId != oldest).toList();
    if (posts.isEmpty) return false;
    await store.upsertPosts(posts);
    return posts.length >= limit;
  }

  /// 发消息：本地先插一条"发送中"，成功用服务端 PostVo 替换，失败标记 state=2。
  ///
  /// `mobile_token` 传本地临时 id —— 原库也是这么做的
  /// （`createServerPost` 里 `gson.toJson(String.valueOf(tmpPostId))`），
  /// 服务端会原样回带，多设备场景可用它对账。
  /// **本进程正在发**的本地消息（tmp id）。`markOutdatedPosts` 要跳过它们，
  /// 免得"发送中"被标成"已过期"（原版那一步只在刚进频道时跑，没有在途发送）。
  final Set<int> _activeTemps = <int>{};

  Future<bool> sendMessage(
    int channelId,
    String text, {
    String type = 'normal',
  }) async {
    final api = _api;
    final connId = state.connId;
    final body = text.trim();
    if (api == null || connId == null || connId.isEmpty || body.isEmpty) {
      return false;
    }
    final store = ref.read(chatStoreProvider);
    // 加密频道：服务端只收密文，本地留明文（跟原 App 一致，搜索/通知都要用）
    final channel = await _channelById(store, channelId);
    // 明文频道：提及按服务端能力写成 `@u:<id>`（原版 `getMessageInEditText` 里
    // 的 `isNeedParseUid = Post v4 && !encrypted`）；加密频道走密文，保持原文。
    final wire = (channel != null && channel.encrypted)
        ? ref.read(e2eeServiceProvider).encryptMessage(channelId, body)
        : (api.supports('SYNO.Chat.Post', 4)
              ? encodeMentions(
                  body,
                  byUsername: mentionIdByUsername(
                    await ref.read(chatStoreProvider).allUsers(),
                  ),
                )
              : body);
    final now = DateTime.now().millisecondsSinceEpoch;
    final tmp = await store.insertPendingPost(
      channelId: channelId,
      creatorId: state.myUserId,
      message: body,
      nowMillis: now,
      type: type,
    );
    _activeTemps.add(tmp);
    try {
      final raw = await api.createPost(
        channelId: channelId,
        message: wire,
        connId: connId,
        type: type,
        mobileToken: '$tmp',
      );
      var confirmed = PostDto.fromJson(raw);
      if (channel != null && channel.encrypted) {
        // 服务端回的 PostVo 里是密文，本地要存明文
        confirmed = confirmed.copyWith(message: body, encrypted: true);
      }
      _activeTemps.remove(tmp);
      await store.confirmPendingPost(
        channelId: channelId,
        tmpPostId: tmp,
        server: confirmed.postId > 0
            ? confirmed
            : PostDto(
                postId: 0,
                channelId: channelId,
                creatorId: state.myUserId,
                message: body,
                createAt: now,
                tmpPostId: tmp,
                state: 1,
              ),
      );
      await store.touchChannelOnOwnPost(
        channelId: channelId,
        at: confirmed.createAt > 0 ? confirmed.createAt : now,
      );
      // 正文里有链接 → 服务端要几秒后才把 `url_props`（OG 预览）补上，
      // 而且**不会**推广播（真机实测：只有 client.post.create，没有 post.update）。
      // 所以这里安排两次"晚点再刷一遍列表"，让预览卡片自己冒出来。
      if (_hasUrl(body)) _scheduleOgRefresh(channelId);
      return true;
    } catch (e, st) {
      // ★ r326：这里原来是**静默** catch ⇒ 真机上出现"界面说发送失败、
      //   服务端却已经收到"时**完全无法诊断**（走查里就撞上了）。失败必须留痕。
      debugPrint('[chat] 发消息失败 channel=$channelId tmp=$tmp：$e');
      debugPrint('[chat] $st');
      _activeTemps.remove(tmp);
      await store.failPendingPost(channelId, tmp);
      return false;
    }
  }

  /// 发一张贴纸：原版 `ChannelFragment.createSticker` → 非 emoji 分类点一下
  /// 就发一条 `type=sticker`、正文 `:<name>:` 的消息（emoji 分类是插进输入框）。
  Future<bool> sendSticker(int channelId, String stickerName) {
    final name = stickerName.trim();
    if (name.isEmpty) return Future.value(false);
    return sendMessage(channelId, ':$name:', type: 'sticker');
  }

  /// 进频道时把本地没发成功的消息标成「已过期」（原版 `updateAllOutdatedPosts`）。
  ///
  /// 只动本地库；失败消息在侧栏的例外判定（不藏频道）也吃 `state IN (2,3)`。
  Future<void> markOutdatedPosts(int channelId) async {
    if (channelId <= 0) return;
    try {
      await ref
          .read(chatStoreProvider)
          .markOutdatedPosts(
            channelId,
            nowMillis: DateTime.now().millisecondsSinceEpoch,
            excludeTmpIds: _activeTemps,
          );
    } catch (e) {
      debugPrint('[temp] 标记过期消息失败（不影响阅读）：$e');
    }
  }

  /// 重新发送一条本地「失败/过期」消息（原版 `ChannelPresenter.resendPost`
  /// → `AccountManager.createServerPost` → 成功后删掉本地 temp 行）。
  ///
  /// * 正文消息：拿原文重发一次；
  /// * 附件（`type == 'file'`）：本地文件还在 `pendingFiles` 里就重传，
  ///   文件没了就返回 false（原版同样重传不了，只能改文字）。
  Future<bool> resendPost(PostDto post) async {
    final store = ref.read(chatStoreProvider);
    final localPath = state.pendingFiles[post.tmpPostId];
    var ok = false;
    if (post.type == 'file' || localPath != null) {
      if (localPath == null) {
        debugPrint('[temp] #${post.postId} 的原文件已不在本地，无法重发附件');
        return false;
      }
      ok = await sendAttachment(
        channelId: post.channelId,
        filePath: localPath,
        fileName: localPath.split('/').last,
        message: post.message,
        threadId: post.threadId,
      );
    } else if (post.threadId > 0) {
      // 话题里的回复：重发也得挂回原话题
      ok = await sendThreadReply(post.channelId, post.threadId, post.message);
    } else {
      ok = await sendMessage(
        post.channelId,
        post.message,
        type: post.type.isEmpty ? 'normal' : post.type,
      );
    }
    if (ok) {
      // 重发成功 → 本地那条 temp 行作废（服务端真消息已经作为新行落下）
      _clearPendingFile(post.tmpPostId);
      if (post.tmpPostId != 0) {
        await store.deletePendingPost(post.channelId, post.tmpPostId);
      }
    }
    return ok;
  }

  /// 删掉一条本地「失败/过期」消息（原版 `deleteTemp`：只删本地）。
  Future<void> deleteTempPost(PostDto post) async {
    _clearPendingFile(post.tmpPostId);
    if (post.tmpPostId != 0) {
      await ref
          .read(chatStoreProvider)
          .deletePendingPost(post.channelId, post.tmpPostId);
    }
  }

  /// 编辑一条本地 temp 消息：先改本地正文，再走重发。
  Future<bool> editTempPost(PostDto post, String text) async {
    final body = text.trim();
    if (body.isEmpty) return false;
    await ref
        .read(chatStoreProvider)
        .updatePendingMessage(post.channelId, post.tmpPostId, body);
    return resendPost(post.copyWith(message: body));
  }

  /// 正文里有没有 URL（要不要等服务端补 OG 预览）
  static bool _hasUrl(String text) {
    final lower = text.toLowerCase();
    return lower.contains('http://') || lower.contains('https://');
  }

  final List<Timer> _ogRefreshTimers = [];

  /// 发完带链接的消息后补刷列表：服务端抓 OG 是异步的（真机约 3-10 秒），
  /// 抓完**不发广播**，只能靠再拉一次 `Post/list` 才能看到预览。
  void _scheduleOgRefresh(int channelId) {
    for (final delay in const [Duration(seconds: 4), Duration(seconds: 12)]) {
      late final Timer timer;
      timer = Timer(delay, () async {
        _ogRefreshTimers.remove(timer);
        try {
          await loadPosts(channelId, force: true);
        } catch (_) {
          // 预览拿不到不影响消息本身
        }
      });
      _ogRefreshTimers.add(timer);
    }
  }

  /// 归档频道列表（`SYNO.Chat.Archive / list`，只认 `type="encrypted"`）。
  /// Phase 7 的 E2EE 归档频道要靠它拿 `archive_key_enc` 才能解密。
  Future<List<ArchiveDto>> listArchives() async {
    final api = _api;
    if (api == null) return const [];
    return api.listArchives();
  }

  // ------------------------------------------------------------ 标签（Phase 6）

  /// 频道里用过的标签
  Future<List<String>> channelHashtags(int channelId) async {
    final api = _api;
    if (api == null) return const [];
    return api.channelHashtags(channelId);
  }

  /// 给消息加标签（服务端 `Post.Hashtag/set`，成功后本地也更新）
  Future<bool> setPostHashtag({
    required int channelId,
    required PostDto post,
    required String hashtag,
  }) async {
    final api = _api;
    final tag = hashtag.trim().replaceAll('#', '');
    if (api == null || tag.isEmpty) return false;
    try {
      await api.setPostHashtag(postId: post.postId, hashtag: tag);
    } catch (_) {
      return false;
    }
    if (!post.hashtags.contains(tag)) {
      await ref.read(chatStoreProvider).upsertPosts([
        post.copyWith(hashtags: [...post.hashtags, tag]),
      ]);
    }
    return true;
  }

  /// 去掉消息上的标签
  Future<bool> deletePostHashtag({
    required int channelId,
    required PostDto post,
    required String hashtag,
  }) async {
    final api = _api;
    if (api == null) return false;
    try {
      await api.deletePostHashtag(postId: post.postId, hashtag: hashtag);
    } catch (_) {
      return false;
    }
    final next = [...post.hashtags]..remove(hashtag);
    await ref.read(chatStoreProvider).upsertPosts([
      post.copyWith(hashtags: next),
    ]);
    return true;
  }

  // ------------------------------------------------------------ 机器人（Phase 6）

  /// 被屏蔽的机器人 id（`Chatbot/list_blocked`）
  Future<List<int>> blockedBots() async {
    final api = _api;
    if (api == null) return const [];
    try {
      return await api.blockedBots();
    } catch (_) {
      return const [];
    }
  }

  /// 跟某个用户开始一对一（匿名）会话，返回频道 id（0 = 失败）。
  ///
  /// 逐行对位原版 `AccountManager.initiateAnonymous(int userId)`（由用户资料页
  /// `ProfileFragment` 的「发消息」触发）：
  ///   * `user_ids` = **`[对方, 我]`**（顺序反了服务端回 117，真机实测过）；
  ///   * 这条路是**非加密**的（`initiateAnonymous(list, false)`）→
  ///     `channel_key_encs` 发 Gson 的 `null`、`encrypted=false`；
  ///   * 先查本地有没有"同两个人 + 同样加密与否"的匿名频道（原版
  ///     `queryChannel(list, z)`），有就直接返回，别再 initiate（服务端会回 117）。
  Future<int> startAnonymousConversation(int userId) async {
    final store = ref.read(chatStoreProvider);
    final me = state.myUserId;
    if (userId <= 0 || userId == me) return 0;
    for (final c in await store.allChannels()) {
      if (c.type != 'anonymous' || c.encrypted) continue;
      final others = c.members.where((id) => id != me).toList();
      if (others.length == 1 && others.single == userId) return c.channelId;
    }
    final api = _api;
    if (api == null) return 0;
    ChannelDto dto;
    try {
      dto = await api.initiateAnonymous(
        userIds: [userId, me],
        channelKeyEncs: null,
        encrypted: false,
      );
    } catch (e) {
      // 服务端对"两个人已经有匿名会话"回 117（错误文案是笼统的"服务端内部错误"）。
      // 本地没有、但服务端有（比如在别的设备上建的）时会走到这 —— 重拉一次列表，
      // 找到就复用。原版没有这一步（它会直接报错），这是我们多做的兜底。
      debugPrint('[anon] initiate 失败，回查一次已有会话：$e');
      await refresh();
      for (final c in await store.allChannels()) {
        if (c.type != 'anonymous') continue;
        final others = c.members.where((id) => id != me).toList();
        if (others.length == 1 && others.single == userId) return c.channelId;
      }
      rethrow;
    }
    if (dto.channelId <= 0) return 0;
    await store.upsertChannels([dto]);
    await refresh();
    return dto.channelId;
  }

  /// 跟机器人开始对话，返回频道 id（0 = 失败）。
  ///
  /// 跟反编译的 `AccountManager.initiateChatBot` 一致：**先查本地**——
  /// 机器人的直聊频道 `type` 是 `chatbot`（synobot 是 `synobot`），
  /// 已经有就直接用，不再打接口。查不到才调 `Chatbot/initiate`
  /// （真机上已存在的机器人会被拒，所以先查本地才不会白跑）。
  Future<int> initiateChatbot(int userId) async {
    final store = ref.read(chatStoreProvider);
    final users = await store.allUsers();
    UserDto? bot;
    for (final u in users) {
      if (u.userId == userId) bot = u;
    }
    final name = bot?.displayName ?? '';
    for (final c in await store.allChannels()) {
      final isBotChannel = c.type == 'chatbot' || c.type == 'synobot';
      if (!isBotChannel) continue;
      if (c.members.contains(userId)) return c.channelId;
      if (name.isNotEmpty && c.name == name) return c.channelId;
    }

    final api = _api;
    if (api == null) return 0;
    for (final asList in [false, true]) {
      try {
        final data = await api.initiateChatbot(userId, asList: asList);
        // 返回的可能是完整频道对象，也可能只有 channel_id
        final raw = data['channel'] is Map ? data['channel'] : data;
        final dto = ChannelDto.fromJson(Map<String, dynamic>.from(raw as Map));
        if (dto.channelId <= 0) continue;
        // ⚠️ 必须走 `upsertLocallyCreatedChannel`：紧接着的 `refresh()` 会按
        // 服务端列表剪掉"名单外"的频道，而这个刚建好的频道**列表里还没有**
        // （服务端滞后 / 最终一致）⇒ 走普通 upsert 会被自己的剪枝删掉，
        // 用户看到"建完就消失"（真回归，`test/phase6_test.dart` 覆盖）。
        await store.upsertLocallyCreatedChannel(dto);
        await refresh();
        return dto.channelId;
      } catch (_) {
        // 换下一种写法再试
      }
    }
    return 0;
  }

  /// 通知"没设口令"的成员（`User / notify_encrypt`）。
  ///
  /// 语义：邀请进**加密频道**时，没配端到端加密口令的人会被移出邀请列表，
  /// 如果用户在弹窗里勾了「通知他们」，就把这些人报给服务端去提醒。
  /// 原版对结果只有日志（`Actions.empty()`），所以这里也是 best effort。
  Future<bool> notifyEncrypt(List<int> userIds) async {
    final api = _api;
    if (api == null || userIds.isEmpty) return false;
    try {
      await api.notifyEncrypt(userIds);
      debugPrint('[e2ee] 已通知 ${userIds.length} 个没有口令的成员');
      return true;
    } catch (e) {
      debugPrint('[e2ee] notify_encrypt 失败（不影响邀请）：$e');
      return false;
    }
  }

  // -------------------------------------------------- 斜杠命令（Webhook.Slash）

  /// 执行"起会议"型斜杠命令（`Webhook.Slash / execute`）。
  ///
  /// 原版在 `ChannelFragment.onCreatePost` 里分流：文本以 `/jumpchat`/`/jitsi`
  /// 开头且频道**未加密** → 不发普通消息，改调这个接口（机器人再去发会议卡片）。
  Future<bool> executeSlashCommand({
    required int channelId,
    required String message,
    required int botUserId,
  }) async {
    final api = _api;
    if (api == null) return false;
    try {
      await api.executeSlashCommand(
        channelId: channelId,
        message: message,
        userId: botUserId,
      );
      return true;
    } catch (e) {
      debugPrint('[slash] 执行斜杠命令失败：$e');
      return false;
    }
  }

  // ------------------------------------------------------------ 投票（Phase 6）

  /// 建投票；成功后把返回的消息写进本地库（服务端也会广播）
  Future<bool> createVote({
    required int channelId,
    required String message,
    required List<String> choices,
    bool multiple = false,
    bool anonymous = false,
    bool addOption = false,
    int expireAt = 0,
    int? threadId,
    String? filePath,
    String fileName = '',
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final api = _api;
    if (api == null) return false;
    try {
      final raw = await api.createVote(
        channelId: channelId,
        message: message,
        choices: choices,
        multiple: multiple,
        anonymous: anonymous,
        addOption: addOption,
        expireAt: expireAt,
        filePath: filePath,
        fileName: fileName,
        mimeType: mimeType,
        onProgress: onProgress,
      );
      final post = PostDto.fromJson(raw);
      if (post.postId > 0) {
        await ref.read(chatStoreProvider).upsertPosts([post]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 投票（本地先把 `voters` 改掉，跟原 App 的 `Vote.voteFor` 一致）
  Future<bool> castVote({
    required int channelId,
    required PostDto post,
    required List<String> choiceIds,
  }) async {
    final api = _api;
    if (api == null) return false;
    final vote = post.vote;
    if (vote == null) return false;
    try {
      await api.castVote(postId: post.postId, choiceIds: choiceIds);
    } catch (_) {
      return false;
    }
    // 本地乐观更新：单选要先把我在其它选项上的票去掉
    final me = state.myUserId;
    final next = <VoteChoiceDto>[
      for (final c in vote.choices)
        if (choiceIds.contains(c.id))
          VoteChoiceDto(
            id: c.id,
            text: c.text,
            count: c.votedBy(me) ? c.count : c.count + 1,
            voters: c.votedBy(me) ? c.voters : [...c.voters, me],
          )
        else if (!vote.multiple && c.votedBy(me))
          VoteChoiceDto(
            id: c.id,
            text: c.text,
            count: c.count > 0 ? c.count - 1 : 0,
            voters: [...c.voters]..remove(me),
          )
        else
          c,
    ];
    await ref.read(chatStoreProvider).upsertPosts([
      post.copyWith(
        props: {...post.props, 'vote': vote.withChoices(next).toJson()},
      ),
    ]);
    return true;
  }

  /// 拉最新票数（`Vote/get_choices`），写回本地
  /// 拉一次投票结果（`Vote/get_choices`：每个选项带 `count` 与 `voters`），
  /// **写回本地库并返回解析后的选项**。
  ///
  /// 单个实现两处用（§2.0.8 ④）：投票动作后的刷新 + 「看结果」面板。
  Future<List<VoteChoiceDto>> loadVoteChoices(PostDto post) async {
    final api = _api;
    final vote = post.vote;
    if (api == null || vote == null) return const [];
    final choices = await api.voteChoices(post.postId);
    final parsed = [for (final c in choices) VoteChoiceDto.fromJson(c)];
    await ref.read(chatStoreProvider).upsertPosts([
      post.copyWith(
        props: {...post.props, 'vote': vote.withChoices(parsed).toJson()},
      ),
    ]);
    return parsed;
  }

  Future<void> refreshVoteChoices({
    required int channelId,
    required PostDto post,
  }) => loadVoteChoices(post);

  /// 编辑投票（`Post.Vote / set`，原版 `EditVoteFragment` + `AccountManager.editVote`）。
  ///
  /// 可编辑性照抄原版：`editable = 总票数 == 0`。有人投过票时只把 `options`
  /// 发给服务端（问题/选项/多选/匿名都不动）。
  Future<bool> editVote({
    required int channelId,
    required PostDto post,
    required String message,
    required List<VoteChoiceDraft> choices,
    required bool multiple,
    required bool anonymous,
    required bool addOption,
    required int expireAt,
  }) async {
    final api = _api;
    final vote = post.vote;
    if (api == null || vote == null) return false;
    final editable = vote.totalVotes == 0;
    try {
      await api.setVote(
        channelId: channelId,
        postId: post.postId,
        message: editable ? message : null,
        choices: editable
            ? [for (final c in choices) (id: c.id, text: c.text.trim())]
            : null,
        multiple: multiple,
        anonymous: anonymous,
        addOption: addOption,
        expireAt: expireAt,
      );
    } catch (_) {
      return false;
    }
    // 本地先按提交的内容更新（服务端随后会用 `post.vote_update` 广播覆盖成真值）
    final next = VoteDto(
      choices: editable
          ? [
              for (final c in choices)
                VoteChoiceDto(id: c.id, text: c.text.trim()),
            ]
          : vote.choices,
      multiple: multiple,
      anonymous: anonymous,
      addOption: addOption,
      expireAt: expireAt,
      state: vote.state,
      cronjobId: vote.cronjobId,
    );
    await ref.read(chatStoreProvider).upsertPosts([
      post.copyWith(
        message: editable ? message : post.message,
        props: {...post.props, 'vote': next.toJson()},
      ),
    ]);
    return true;
  }

  /// 删投票（`Post.Vote / delete`）—— **只删投票，消息本身还在**，
  /// 卡片变成「投票已删除」（原版 `Vote.isDelete()` + `voteDeleted` 视图）。
  Future<bool> deleteVote({
    required int channelId,
    required PostDto post,
  }) async {
    final api = _api;
    final vote = post.vote;
    if (api == null || vote == null) return false;
    try {
      await api.deleteVote(post.postId);
    } catch (_) {
      return false;
    }
    final deleted = VoteDto(
      choices: vote.choices,
      multiple: vote.multiple,
      anonymous: vote.anonymous,
      addOption: vote.addOption,
      expireAt: vote.expireAt,
      state: VoteState.deleted,
      cronjobId: vote.cronjobId,
    );
    await ref.read(chatStoreProvider).upsertPosts([
      post.copyWith(props: {...post.props, 'vote': deleted.toJson()}),
    ]);
    return true;
  }

  /// 结束投票
  Future<bool> closeVote({
    required int channelId,
    required PostDto post,
  }) async {
    final api = _api;
    final vote = post.vote;
    if (api == null || vote == null) return false;
    try {
      await api.closeVote(post.postId);
    } catch (_) {
      return false;
    }
    final closed = VoteDto(
      choices: vote.choices,
      multiple: vote.multiple,
      anonymous: vote.anonymous,
      addOption: vote.addOption,
      expireAt: vote.expireAt,
      state: VoteState.closed,
      cronjobId: vote.cronjobId,
    );
    await ref.read(chatStoreProvider).upsertPosts([
      post.copyWith(props: {...post.props, 'vote': closed.toJson()}),
    ]);
    return true;
  }

  /// 追加投票选项
  Future<bool> addVoteOption({
    required int channelId,
    required PostDto post,
    required String text,
  }) async {
    final api = _api;
    if (api == null || text.trim().isEmpty) return false;
    try {
      await api.createVoteOption(postId: post.postId, text: text.trim());
    } catch (_) {
      return false;
    }
    await refreshVoteChoices(channelId: channelId, post: post);
    return true;
  }

  // ------------------------------------------------------------ 提醒（Phase 6）

  /// 频道里**我订阅的话题**列表（官方 `CommentsFragment` → `CommentsPresenter
  /// .fetchAllSubscribedPosts`）。
  ///
  /// 主路径是 `SYNO.Chat.Post / thread_list` v5（`AccountManager.fetchThreadList`，
  /// 参数 `channel_id` + `offset`/`limit`/`related_comment_count`）；
  /// 服务端不支持 v5 或调用失败时**降级**到官方同款后备路径
  /// `Post/search` + `in:[channelId]` + `has:["subscribe"]`
  /// （`CommentsPresenter.fetchAllSubscribedPosts` 的 `onErrorReturn`，
  /// 服务端 `SearchControl::HandleSubscribe` 认这个值）。
  ///
  /// 只回**父贴**（订阅列表就是话题本身，回复挂在父贴下）。
  Future<List<PostDto>> listSubscribedThreads(int channelId) async {
    final api = _api;
    if (api == null) return const [];
    List<Map<String, dynamic>> raw;
    if (api.supports('SYNO.Chat.Post', 5)) {
      try {
        raw = await api.listThreads(
          channelId: channelId,
          offset: 0,
          limit: 30,
          relatedCommentCount: 1,
        );
      } catch (_) {
        raw = await _searchSubscribedThreads(api, channelId);
      }
    } else {
      raw = await _searchSubscribedThreads(api, channelId);
    }
    final posts = _parsePosts(
      raw,
      channelId,
    ).where((p) => p.postId > 0 && !p.isThreadReply).toList();
    if (posts.isNotEmpty) {
      await ref.read(chatStoreProvider).upsertPosts(posts);
    }
    return posts;
  }

  Future<List<Map<String, dynamic>>> _searchSubscribedThreads(
    ChatApi api,
    int channelId,
  ) async {
    final result = await api.searchPosts(
      PostSearchQuery(
        inChannels: [channelId],
        has: const ['subscribe'],
        limit: 30,
      ),
    );
    return result.posts;
  }

  Future<bool> setReminder({
    required int channelId,
    required PostDto post,
    required int remindAt,
  }) async {
    final api = _api;
    if (api == null) return false;
    try {
      await api.setReminder(postId: post.postId, remindAt: remindAt);
    } catch (_) {
      return false;
    }
    await ref.read(chatStoreProvider).upsertPosts([
      post.copyWith(props: {...post.props, 'remind_at': remindAt}),
    ]);
    // 排上本地通知（详情见 `ReminderScheduler`）
    await ref
        .read(reminderSchedulerProvider)
        .arm(postId: post.postId, channelId: channelId, remindAt: remindAt);
    return true;
  }

  Future<bool> clearReminder({
    required int channelId,
    required PostDto post,
  }) async {
    final api = _api;
    if (api == null) return false;
    try {
      await api.deleteReminder(post.postId);
    } catch (_) {
      return false;
    }
    final props = {...post.props}..remove('remind_at');
    await ref.read(chatStoreProvider).upsertPosts([
      post.copyWith(props: props),
    ]);
    await ref.read(reminderSchedulerProvider).disarm(post.postId);
    return true;
  }

  /// 频道的提醒列表（按时间排序）
  Future<List<PostDto>> listReminders(int channelId) async {
    final api = _api;
    if (api == null) return const [];
    final raw = await api.listReminders(channelId);
    final posts = _parsePosts(raw, channelId);
    await ref.read(chatStoreProvider).upsertPosts(posts);
    // 服务端这份是"我的提醒"的权威来源 → 校准本地账本（含别的设备设的）
    await ref
        .read(reminderSchedulerProvider)
        .reconcileChannel(channelId, posts);
    final sorted = [...posts]..sort((a, b) => a.remindAt.compareTo(b.remindAt));
    return sorted;
  }

  // ------------------------------------------------------------ 定时消息（Phase 6）

  Future<int> createScheduledPost({
    required int channelId,
    required String message,
    required int sendAt,
  }) async {
    final api = _api;
    if (api == null) return 0;
    return api.createScheduledPost(
      channelId: channelId,
      message: message,
      sendAt: sendAt,
    );
  }

  Future<void> deleteScheduledPost(int cronjobId) async {
    final api = _api;
    if (api == null) return;
    await api.deleteScheduledPost(cronjobId);
  }

  Future<List<ScheduledPostDto>> listScheduledPosts(int channelId) async {
    final api = _api;
    if (api == null) return const [];
    final raw = await api.listScheduledPosts(channelId);
    return [for (final e in raw) ScheduledPostDto.fromJson(e)];
  }

  // ------------------------------------------------------------ 媒体 / 文件列表（Phase 5）

  /// 拉某个频道的一段"媒体/文件"消息（图片墙、文件列表用）。
  ///
  /// 走 `Post/list` v3 + `file_type`（见 `ChatApi.listPostsByType`），
  /// 结果照常落本地库 —— 于是 [mediaPostsProvider] 会自动刷新，
  /// 而且这些消息之后在频道里也能看到（和原 App 一致）。
  Future<int> loadMedia({
    required int channelId,
    List<String> fileTypes = const [],
    int prevCount = 50,
    int olderThanPostId = 0,
  }) async {
    final api = _api;
    if (api == null) return 0;
    final store = ref.read(chatStoreProvider);
    // 出错就往上抛：媒体页要能显示"加载失败 + 重试"，而不是装作没有内容
    final raw = await api.listPostsByType(
      channelId: channelId,
      fileTypes: fileTypes,
      prevCount: prevCount,
      postId: olderThanPostId > 0 ? olderThanPostId : null,
    );
    final posts = _parsePosts(raw, channelId)
        .where((p) => olderThanPostId == 0 || p.postId != olderThanPostId)
        .toList();
    await store.upsertPosts(posts);
    return posts.length;
  }

  /// 发送附件（图片 / 文件 / 语音）。
  ///
  /// 走 `Post/create` 的 multipart 分支（见 `ChatApi.uploadPost`）：
  /// 上传期间本地先插一条"发送中"的占位（图片会用本地文件先预览），
  /// 服务端回整条 Post 后换成真身（这时才有 `file_props`，能取缩略图）。
  ///
  /// ⚠️ 服务端对 `Post/create` 有频率限制（实测连发会回 411
  /// `CHAT_ERR_SEND_TOO_FREQUENTLY`），失败时占位行会被标成失败态。
  /// 发语音消息（Phase 5）。
  ///
  /// 文件名必须是 `voiceMessage*.aac`（服务端据此认定是语音并读
  /// `voice_msg_length`），见 `AccountManager.createPost` 的 file 分支。
  Future<bool> sendVoiceMessage({
    required int channelId,
    required String filePath,
    required int seconds,
    int? threadId,
  }) async {
    final ok = await sendAttachment(
      channelId: channelId,
      filePath: filePath,
      fileName: voiceFileName(),
      message: '',
      mimeType: 'audio/aac',
      threadId: threadId,
      voiceMsgLength: seconds,
    );
    // 录音临时文件跟消息一起用完就删（原 App 也是用的临时文件）
    try {
      final f = File(filePath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    return ok;
  }

  Future<bool> sendAttachment({
    required int channelId,
    required String filePath,
    required String fileName,
    String message = '',
    String? mimeType,
    int? threadId,
    int? voiceMsgLength,
    void Function(int sent, int total)? onProgress,
  }) async {
    final api = _api;
    final connId = state.connId;
    if (api == null || connId == null || connId.isEmpty) return false;
    final store = ref.read(chatStoreProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    final caption = message.trim();
    final tmp = await store.insertPendingPost(
      channelId: channelId,
      creatorId: state.myUserId,
      message: caption.isEmpty ? fileName : caption,
      nowMillis: now,
      threadId: threadId ?? 0,
      // 标成 file：失败之后要看得出"这是附件"，重发才能走上传那条路
      type: 'file',
    );
    _activeTemps.add(tmp);
    // 让界面在上传期间就能看到本地图片
    // r319：`await store.insertPendingPost(...)` 是异步空隙 ⇒ 写 state 前先查销毁
    if (!ref.mounted) return false;
    state = state.copyWith(
      pendingFiles: <int, String>{...state.pendingFiles, tmp: filePath},
    );
    // 加密频道：文件名 hex 加密 + 内容流加密（密文另存一个临时文件再上传）
    final channel = await _channelById(store, channelId);
    var wireName = fileName;
    var wireCaption = caption;
    var uploadPath = filePath;
    var wireMime = mimeType;
    String? cipherTmp;
    final e2ee = channel != null && channel.encrypted
        ? ref.read(e2eeServiceProvider)
        : null;

    // Phase 9：图片质量（原版 `upload_quality`）。标准质量 = 长边 1280 + JPEG 90；
    // 原图 = 一个字节都不动。只在**非加密**频道做预处理（加密频道直接加密原文件，
    // 与原版一致：原版的重编码也发生在上传前、与加密无关，但改尺寸会改动密文大小
    // 上限校验，故保持现状）。
    String? qualityTmp;
    if (e2ee == null && voiceMsgLength == null) {
      try {
        final quality = ref.read(imageQualityProvider);
        if (quality == ImageQuality.standard) {
          final plain = await File(filePath).readAsBytes();
          final prepared = prepareImageUpload(
            bytes: plain,
            fileName: fileName,
            quality: quality,
          );
          if (prepared.changed) {
            qualityTmp =
                '${Directory.systemTemp.path}/q_'
                '${DateTime.now().microsecondsSinceEpoch}_${prepared.bytes.length}';
            await File(qualityTmp).writeAsBytes(prepared.bytes);
            uploadPath = qualityTmp;
            wireName = prepared.fileName;
            wireMime = prepared.mimeType;
          }
        }
      } catch (e) {
        // 预处理失败就老老实实传原图，别让发图这事黄掉
        debugPrint('[p9] 图片预处理失败，按原图上传：$e');
      }
    }
    try {
      if (e2ee != null) {
        wireName = e2ee.encryptFileName(channelId, fileName);
        if (caption.isNotEmpty) {
          wireCaption = e2ee.encryptMessage(channelId, caption);
        }
        final plain = await File(filePath).readAsBytes();
        // secretbox 的入参上限是文件大小；附件一般几 MB，直接整份处理
        final sealed = e2ee.encryptFileBytes(channelId, plain);
        cipherTmp =
            '${Directory.systemTemp.path}/e2ee_'
            '${DateTime.now().microsecondsSinceEpoch}_${plain.length}';
        await File(cipherTmp).writeAsBytes(sealed);
        uploadPath = cipherTmp;
      }
    } catch (e) {
      _clearPendingFile(tmp);
      _activeTemps.remove(tmp);
      await store.failPendingPost(channelId, tmp);
      // r319：异步空隙之后不许裸写 state（provider 可能已销毁）
      if (!ref.mounted) return false;
      state = state.copyWith(
        error: currentText().chatErrEncryptAttachmentFailed(userFacingError(e)),
      );
      return false;
    }
    Future<void> cleanupTemps() async {
      for (final p in [cipherTmp, qualityTmp]) {
        if (p == null) continue;
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }

    try {
      final raw = await api.uploadPost(
        channelId: channelId,
        connId: connId,
        filePath: uploadPath,
        fileName: wireName,
        // multipart 这条路上服务端不做 JSON 解码，密文原样存
        message: wireCaption,
        mimeType: wireMime,
        threadId: threadId,
        voiceMsgLength: voiceMsgLength,
        onProgress: onProgress,
      );
      final confirmed = PostDto.fromJson(raw);
      final local = e2ee != null && confirmed.postId > 0
          ? confirmed.copyWith(message: caption, encrypted: true)
          : confirmed;
      _activeTemps.remove(tmp);
      await store.confirmPendingPost(
        channelId: channelId,
        tmpPostId: tmp,
        server: confirmed.postId > 0
            ? local
            : PostDto(
                postId: 0,
                channelId: channelId,
                creatorId: state.myUserId,
                message: caption,
                createAt: now,
                tmpPostId: tmp,
                threadId: threadId ?? 0,
                state: 1,
              ),
      );
      await store.touchChannelOnOwnPost(
        channelId: channelId,
        at: confirmed.createAt > 0 ? confirmed.createAt : now,
      );
      _clearPendingFile(tmp);
      await cleanupTemps();
      return true;
    } catch (e) {
      _activeTemps.remove(tmp);
      await store.failPendingPost(channelId, tmp);
      _clearPendingFile(tmp);
      await cleanupTemps();
      return false;
    }
  }

  void _clearPendingFile(int tmp) {
    if (!state.pendingFiles.containsKey(tmp)) return;
    final next = <int, String>{...state.pendingFiles}..remove(tmp);
    // r319：异步空隙之后不许裸写 state（provider 可能已销毁）
    if (!ref.mounted) return;
    state = state.copyWith(pendingFiles: next);
  }

  /// 下载附件到临时目录（供"打开/另存"用），返回本地路径
  Future<String?> downloadPostFile(
    PostDto post, {
    required String fileName,
    bool thumbnail = false,
  }) async {
    final api = _api;
    if (api == null || post.postId <= 0) return null;
    final store = ref.read(chatStoreProvider);
    final channel = await _channelById(store, post.channelId);
    final e2ee = channel != null && channel.encrypted
        ? ref.read(e2eeServiceProvider)
        : null;
    // 加密频道里服务端存的是 hex 密文名，落盘要用解出来的真名
    final shownName = e2ee == null
        ? fileName
        : e2ee.tryDecryptFileName(post.channelId, fileName) ?? fileName;
    // Phase 9：落进受容量上限管理的缓存目录（原版 DownloadCache）
    final cache = ref.read(cacheServiceProvider);
    final path = await cache.pathFor(
      post.postId,
      shownName,
      thumbnail: thumbnail,
    );
    final file = File(path);
    if (await file.exists() && await file.length() > 0) {
      await cache.touch(path); // 命中缓存：刷新 LRU
      return path;
    }
    try {
      var bytes = await api.downloadPostFile(
        post.postId,
        // E2EE 频道没法用服务端缩略图（它没有频道密钥），一律整份下载
        thumbnail: e2ee == null && thumbnail,
        // 尺寸串（原版取值 S/M/L/XL），不是 MIME
        size: e2ee == null && thumbnail ? ChatApi.thumbLarge : null,
      );
      if (e2ee != null) {
        final plain = e2ee.tryDecryptFileBytes(post.channelId, bytes);
        if (plain == null) return null; // 密钥没解锁 / 解不开
        bytes = plain;
      }
      await file.writeAsBytes(bytes);
      // 写完就按设置里的上限淘汰最久未用的（0 = 不限制）
      await cache.enforceLimit(ref.read(cacheLimitProvider), protect: {path});
      return path;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ 消息操作（Phase 4）

  /// 编辑消息（`Post/set`）。成功后本地就地改文本。
  Future<bool> editMessage(
    int channelId,
    int postId,
    String newText, {
    int? threadId,
  }) async {
    final api = _api;
    final body = newText.trim();
    if (api == null || postId <= 0 || body.isEmpty) return false;
    // 编辑窗口/权限：界面已经隐藏了"编辑"，这里再兜一层（原版
    // `PostUtil.isPostEditable` 的同一套判断）
    try {
      final store = ref.read(chatStoreProvider);
      final channel = await _channelById(store, channelId);
      if (channel != null) {
        final posts = await store.postsForChannel(
          channelId,
          threadId: threadId ?? 0,
        );
        final target = posts.where((p) => p.postId == postId).firstOrNull;
        if (target != null && !_canEdit(target, channel)) {
          debugPrint('[edit] 这条消息已过可编辑窗口');
          return false;
        }
      }
    } catch (_) {
      // 本地查不到就交给服务端判
    }
    try {
      await api.editPost(
        postId: postId,
        message: body,
        channelId: channelId,
        threadId: threadId,
      );
      await ref
          .read(chatStoreProvider)
          .applyPostPatch(
            channelId,
            postId,
            message: body,
            updateAt: DateTime.now().millisecondsSinceEpoch,
          );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 删除消息（服务端 `Post/delete`，本地等 `post.delete` 广播或直接删）
  Future<bool> deleteMessage(int channelId, int postId) async {
    final api = _api;
    if (api == null || postId <= 0) return false;
    try {
      await api.deletePost(postId);
      await ref.read(chatStoreProvider).deletePost(channelId, postId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 星标（收藏）/ 取消
  Future<bool> setStar(int channelId, int postId, {required bool star}) =>
      _patchFlag(
        channelId,
        postId,
        () => _api!.starPost(postId, star: star),
        (store) => store.applyPostPatch(channelId, postId, isStar: star),
      );

  /// 消息置顶 / 取消（`Post/pin` v1，本地落 `last_pin_at`）。
  ///
  /// 之前这里错调了话题的 `stick`（v2），服务端回 407，于是误以为服务端不支持
  /// 置顶、还把入口隐藏了。现在按原版走 pin/unpin。
  Future<bool> setPin(int channelId, int postId, {required bool pin}) async {
    final api = _api;
    if (api == null || postId <= 0) return false;
    try {
      await api.pinPost(postId, pin: pin);
    } on DsmApiException catch (e) {
      if (e.code == 407) {
        // r319：异步空隙之后不许裸写 state（provider 可能已销毁）
        if (!ref.mounted) return false;
        state = state.copyWith(pinUnsupported: true);
      }
      return false;
    } catch (_) {
      return false;
    }
    await ref
        .read(chatStoreProvider)
        .applyPostPatch(
          channelId,
          postId,
          lastPinAt: pin ? DateTime.now().millisecondsSinceEpoch : 0,
        );
    return true;
  }

  /// 话题置顶 / 取消（`Post/stick` v2，本地落 `is_sticky`）。
  ///
  /// 与 [setPin]（**消息置顶** `Post/pin` v1 → `last_pin_at`）是**两套东西**，
  /// 见 docs/phase4-protocol.md §5.1。
  ///
  /// 降级（对齐 [setPin] 的做法）：
  ///   * 服务端 `SYNO.Chat.Post` < v2 / 已知不支持 → **不发请求**，返回 false；
  ///   * 407 `CHAT_ERR_INVALID_RECORD` → 置位 [ChatSyncState.stickUnsupported]，
  ///     UI 据此隐藏入口；
  ///   * 其它错误码不置位（只返回 false，由调用方给提示，不静默失败）。
  Future<bool> setStick(
    int channelId,
    int postId, {
    required bool stick,
  }) async {
    final api = _api;
    if (api == null || postId <= 0) return false;
    if (!state.supportsStick || state.stickUnsupported) return false;
    try {
      await api.stickPost(postId, stick: stick);
    } on DsmApiException catch (e) {
      if (e.code == 407) {
        // r319：异步空隙之后不许裸写 state（provider 可能已销毁）
        if (!ref.mounted) return false;
        state = state.copyWith(stickUnsupported: true);
      }
      return false;
    } catch (_) {
      return false;
    }
    await ref
        .read(chatStoreProvider)
        .applyPostPatch(channelId, postId, isSticky: stick);
    return true;
  }

  /// 读频道的通知档位（`SYNO.Chat.Channel.Preference / get`）。
  ///
  /// 读出来同时写回本地 `channels.notification_mobile`，通知过滤和 UI 都用本地值。
  /// 请求失败时回落到本地缓存（离线也能看）。
  Future<String> loadChannelNotification(int channelId) async {
    final api = _api;
    final store = ref.read(chatStoreProvider);
    if (api == null) {
      return (await _channelById(store, channelId))?.notificationMobile ?? '';
    }
    try {
      final pref = await api.channelPreference(channelId);
      await store.applyChannelPreference(
        channelId,
        notificationMobile: pref.notificationMobile,
        notificationDesktop: pref.notificationDesktop,
        notificationMute: pref.notificationMute,
      );
      return pref.notificationMobile;
    } catch (_) {
      return (await _channelById(store, channelId))?.notificationMobile ?? '';
    }
  }

  /// 写频道的通知档位（`SYNO.Chat.Channel.Preference / set`，只写手机端档位）。
  Future<bool> setChannelNotification(int channelId, String value) async {
    final api = _api;
    if (api == null) return false;
    try {
      await api.setChannelNotification(channelId, value);
    } on DsmApiException {
      return false;
    } catch (_) {
      return false;
    }
    // ⚠️ 只写 `notification_mobile`：`notification_mute` 是服务端另一个独立字段
    // （桌面端语义），这里派生一个本地 mute 会被下一次 get 冲掉，纯属自找麻烦；
    // "none 即静音"由通知过滤直接看档位处理。
    await ref
        .read(chatStoreProvider)
        .applyChannelPreference(channelId, notificationMobile: value);
    return true;
  }

  /// 表情回应 / 取消回应。成功后以服务端广播为准，这里先本地生效。
  Future<bool> setReaction(
    int channelId,
    int postId, {
    required bool on,
    int? stickerId,
    String? stickerName,
  }) async {
    final api = _api;
    if (api == null) return false;
    try {
      if (on) {
        await api.setReaction(
          postId: postId,
          stickerId: stickerId,
          stickerName: stickerName,
        );
      } else {
        await api.deleteReaction(
          postId: postId,
          stickerId: stickerId,
          stickerName: stickerName,
        );
      }
      // 本地先按服务端的真实形状乐观更新：一条记录 + `user_ids` 数组
      // （真机实测 `{sticker_name: thumbsup, user_ids: [14]}`）。
      final store = ref.read(chatStoreProvider);
      final post = await store.postById(channelId, postId);
      if (post != null) {
        final key = stickerId != null && stickerId != 0
            ? 'sticker_id'
            : 'sticker_name';
        final value = stickerId != null && stickerId != 0
            ? stickerId
            : stickerName;
        final me = state.myUserId;
        final list = <Map<String, dynamic>>[];
        var found = false;
        for (final r in post.reactions) {
          if (r[key] != value) {
            list.add(Map<String, dynamic>.from(r));
            continue;
          }
          found = true;
          final ids = <int>[
            for (final id in (r['user_ids'] as List? ?? const []))
              if (id is num) id.toInt() else int.tryParse('$id') ?? 0,
            if (r['user_ids'] == null && r['user_id'] is num)
              (r['user_id'] as num).toInt(),
          ]..removeWhere((id) => id == me);
          if (on) ids.add(me);
          if (ids.isEmpty) continue; // 没人点了就整条去掉
          list.add(
            {...Map<String, dynamic>.from(r), key: value, 'user_ids': ids}
              ..remove('user_id'),
          );
        }
        if (on && !found) {
          list.add({
            key: value,
            'user_ids': [me],
            'create_at': DateTime.now().millisecondsSinceEpoch,
          });
        }
        await store.applyPostPatch(channelId, postId, reactions: list);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 转发到若干频道（`Post/forward`）—— 服务端会在目标频道各生成一条新消息
  Future<bool> forwardPost(int postId, List<int> channelIds) async {
    final api = _api;
    if (api == null || channelIds.isEmpty) return false;
    try {
      await api.forwardPost(postId: postId, channelIds: channelIds);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 发话题回复（`is_thread = true` + `thread_id`）
  Future<bool> sendThreadReply(
    int channelId,
    int parentPostId,
    String text,
  ) async {
    final api = _api;
    final connId = state.connId;
    final body = text.trim();
    if (api == null || connId == null || connId.isEmpty || body.isEmpty) {
      return false;
    }
    final store = ref.read(chatStoreProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    final tmp = await store.insertPendingPost(
      channelId: channelId,
      creatorId: state.myUserId,
      message: body,
      nowMillis: now,
      threadId: parentPostId,
    );
    _activeTemps.add(tmp);
    try {
      final raw = await api.createPost(
        channelId: channelId,
        message: body,
        connId: connId,
        threadId: parentPostId,
        isThread: true,
        mobileToken: '$tmp',
      );
      final confirmed = PostDto.fromJson(raw);
      _activeTemps.remove(tmp);
      await store.confirmPendingPost(
        channelId: channelId,
        tmpPostId: tmp,
        server: confirmed.postId > 0
            ? confirmed
            : PostDto(
                postId: 0,
                channelId: channelId,
                creatorId: state.myUserId,
                message: body,
                createAt: now,
                threadId: parentPostId,
                tmpPostId: tmp,
                state: 1,
              ),
      );
      await store.bumpCommentCount(channelId, parentPostId, at: now);
      return true;
    } catch (_) {
      _activeTemps.remove(tmp);
      await store.failPendingPost(channelId, tmp);
      return false;
    }
  }

  /// 话题已读上报（整频道或单个话题）
  Future<int> markThreadRead(int channelId, {int? threadId}) async {
    final api = _api;
    final connId = state.connId;
    if (api == null || connId == null || connId.isEmpty) return 0;
    var lastViewAt = 0;
    try {
      lastViewAt = await api.viewChannelThreads(
        channelId: channelId,
        connId: connId,
        threadId: threadId,
      );
    } catch (_) {
      // 上报失败不影响本地已读
    }
    await ref
        .read(chatStoreProvider)
        .resetThreadUnread(
          channelId,
          threadId: threadId,
          lastViewCommentAt: lastViewAt,
        );
    return lastViewAt;
  }

  /// 拉某条消息的话题回复（`Post/list` + `thread_id`）
  Future<int> loadThreadReplies(
    int channelId,
    int parentPostId, {
    int limit = 50,
  }) async {
    final api = _api;
    if (api == null || parentPostId <= 0) return 0;
    final raw = await api.listPosts(
      channelId: channelId,
      threadId: parentPostId,
      prevCount: limit,
      nextCount: 0,
      has: kPostHas,
    );
    final posts = _parsePosts(raw, channelId);
    await ref.read(chatStoreProvider).upsertPosts(posts);
    return posts.length;
  }

  /// "先调接口、成功后落库"的公共骨架
  Future<bool> _patchFlag(
    int channelId,
    int postId,
    Future<void> Function() remote,
    Future<void> Function(ChatStore store) local,
  ) async {
    if (_api == null || postId <= 0) return false;
    try {
      await remote();
      await local(ref.read(chatStoreProvider));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从服务端拉一次成员表，顺带把 `broken_user_ids` 这个**权威**结果写进本地
  /// （`Channel/list` 不带 broken_users，只能靠这个 API 或实时事件）。
  Future<bool> syncChannelMembers(int channelId) async {
    final api = _api;
    if (api == null || channelId <= 0) return false;
    final store = ref.read(chatStoreProvider);
    try {
      final members = await api.listChannelMembers(channelId);
      await store.applyChannelMembers(
        channelId,
        userIds: members.userIds,
        brokenUserIds: members.brokenUserIds,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 邀请成员进频道（原版 `AccountManager.inviteNamed`）。
  ///
  /// 加密频道要**逐人封一份频道密钥**（`channel_key_encs` 与 `user_ids` 按位置
  /// 一一对应）；本机没有可用频道密钥时直接失败，别建出"进得来但读不了"的局面。
  Future<bool> inviteMembers(int channelId, List<int> userIds) async {
    final api = _api;
    if (api == null || userIds.isEmpty) return false;
    final store = ref.read(chatStoreProvider);
    final channel = await _channelById(store, channelId);
    if (channel == null) return false;
    List<String> keyEncs = const [];
    if (channel.encrypted) {
      final users = await store.allUsers();
      final byId = {for (final u in users) u.userId: u};
      final e2ee = ref.read(e2eeServiceProvider);
      final sealed = <String>[];
      for (final uid in userIds) {
        final pk = byId[uid]?.publicKey ?? '';
        if (pk.isEmpty) {
          debugPrint('[invite] #$uid 没有公钥，不能进加密频道');
          return false;
        }
        try {
          sealed.add(e2ee.sealChannelKey(channelId, pk));
        } catch (e) {
          debugPrint('[invite] 本地没有 #$channelId 的频道密钥，无法分发：$e');
          return false;
        }
      }
      keyEncs = sealed;
    }
    try {
      await api.inviteNamedChannel(
        channelId,
        userIds: userIds,
        channelKeyEncs: keyEncs,
      );
      // 服务端不广播"成员列表变了"，本地自己补一次权威同步
      await syncChannelMembers(channelId);
      return true;
    } catch (e) {
      debugPrint('[invite] 邀请失败：$e');
      return false;
    }
  }

  /// 批量踢人（原版 `AccountManager.kickUsers`：`Entry.Request` parallel compound
  /// 里每人一段 `Channel.Named kick v1`）。
  Future<bool> kickMembers(int channelId, List<int> userIds) async {
    final api = _api;
    if (api == null || userIds.isEmpty) return false;
    try {
      await api.kickNamedChannels(channelId, userIds);
      await syncChannelMembers(channelId);
      return true;
    } catch (e) {
      debugPrint('[kick] 失败：$e');
      return false;
    }
  }

  /// 订阅 / 取消订阅一个话题（`SYNO.Chat.Post.Subscribe create|delete`）。
  ///
  /// 服务端只回 `BasicVo`（没有内容），所以本地按结果直接改 `subscribes`
  /// —— 随后服务端的 `post.subscribe` 广播也会到达（幂等，不重复追加）。
  Future<bool> setPostSubscribed(
    int channelId,
    int postId, {
    required bool subscribed,
  }) async {
    final api = _api;
    if (api == null || postId <= 0) return false;
    try {
      if (subscribed) {
        await api.subscribePost(postId);
      } else {
        await api.unsubscribePost(postId);
      }
      await ref
          .read(chatStoreProvider)
          .setSubscribed(channelId, postId, subscribed: subscribed);
      return true;
    } catch (e) {
      debugPrint('[sub] 订阅失败：$e');
      return false;
    }
  }

  /// 点机器人消息里的按钮（`SYNO.Chat.Post.Attachment / trigger`）。
  ///
  /// 原版链路：`ActionAdapter.onClick` → `ChatBotEvent.trigger(post, attachment,
  /// 附件下标, 按钮下标)` → `ChannelPresenter.triggerChatBotAttachment` →
  /// `AccountManager#triggerChatBotAttachment`（只发**被点的那一个** action）。
  /// 服务端把它转给机器人的 outgoing URL，机器人再回一段 JSON 改这条消息；
  /// 客户端**本地不改内容**，等 `post.update` 广播回来就行。
  ///
  /// 返回是否成功（UI 靠它结束"处理中"动画）。附件/按钮下标越界直接返回 false。
  Future<bool> triggerChatbotAction({
    required int channelId,
    required int postId,
    required int attachmentIndex,
    required int actionIndex,
  }) async {
    final api = _api;
    if (api == null || postId <= 0) return false;
    final post = await ref.read(chatStoreProvider).postById(channelId, postId);
    final attachments = post?.chatbotAttachments ?? const [];
    if (attachmentIndex < 0 || attachmentIndex >= attachments.length) {
      return false;
    }
    final attachment = attachments[attachmentIndex];
    if (actionIndex < 0 || actionIndex >= attachment.actions.length) {
      return false;
    }
    final action = attachment.actions[actionIndex];
    try {
      await api.triggerChatbotAction(
        postId: postId,
        attachmentIndex: attachmentIndex,
        actionIndex: actionIndex,
        callbackId: attachment.callbackId,
        name: action.name,
        type: action.type,
        value: action.value,
      );
      return true;
    } catch (e) {
      debugPrint('[bot] 按钮触发失败：$e');
      return false;
    }
  }

  /// 正在输入（[threadId] 传话题 id；频道内 typing 恒为 0）。
  ///
  /// 对齐原版 `ChannelPresenter.typing()` 的状态机（`mTyping`）：
  ///   * 已经在"输入中"就**不再重复发**（10 秒窗口内只发一条）；
  ///   * 每次调用都把"10 秒后自动 clear"的计时器往后推；
  ///   * 10 秒没动静就发 `client.user.clear_typing`，状态复位。
  void typing([int threadId = 0]) {
    if (!_typingSent) {
      _typingSent = true;
      _socket?.typing(threadId);
    }
    _typingClearTimer?.cancel();
    _typingClearTimer = Timer(_typingWindow, () {
      _typingClearTimer = null;
      _typingSent = false;
      _socket?.clearTyping();
    });
  }

  /// 立即通知服务端"停止输入"（发消息、离开页面时用）
  void clearTyping() {
    _typingClearTimer?.cancel();
    _typingClearTimer = null;
    if (!_typingSent) return;
    _typingSent = false;
    _socket?.clearTyping();
  }

  static List<PostDto> _parsePosts(
    List<Map<String, dynamic>> raw,
    int channelId,
  ) {
    final out = <PostDto>[];
    for (final json in raw) {
      final dto = PostDto.fromJson(json);
      // 服务端偶尔不给 channel_id，用调用方上下文补上
      out.add(dto.channelId == 0 ? dto.copyWith(channelId: channelId) : dto);
    }
    return out;
  }

  /// 收到新消息事件后把正文补齐（事件载荷不含 message）。
  ///
  /// 对齐原库：`SocketHelper` 收到 `client.post.create` 后会去
  /// `fetchServerPosts` 拉增量，而不是指望 socket 带全量内容。
  Future<void> _fetchPostIfMissing(int channelId, int postId) async {
    final api = _api;
    if (api == null || postId <= 0 || !ref.mounted) return;
    final store = ref.read(chatStoreProvider);
    final existing = await store.postById(channelId, postId);
    if (existing != null) {
      // 正文已经在本地（socket 重连会重放历史事件）：照样过一遍通知过滤，
      // 重复的那些由通知服务按 post_id 去重。
      await _notifyPost([existing], store);
      return;
    }
    try {
      final raw = await api.listPosts(
        channelId: channelId,
        postId: postId,
        prevCount: 1,
        nextCount: 1,
        has: kPostHas,
      );
      final posts = _parsePosts(raw, channelId);
      if (posts.isNotEmpty) await store.upsertPosts(posts);
      // Phase 8：捞到正文才能提醒（加密频道还要有正文才解得开）
      await _notifyPost(posts, store);
    } catch (_) {
      // 捞不到就算了：未读和排序时间已经更新，正文等下次进频道再补
    }
  }

  /// Phase 8：把刚落库的新消息交给通知服务（自己看的频道/自己发的会被过滤掉）
  Future<void> _notifyPost(List<PostDto> posts, ChatStore store) async {
    for (final post in posts) {
      if (post.postId <= 0) continue;
      if (post.creatorId == state.myUserId) continue;
      final channel = await _channelById(store, post.channelId);
      if (channel == null || !ref.mounted) continue;
      try {
        await ref
            .read(notificationServiceProvider)
            .maybeNotify(post, channel: channel);
      } catch (e) {
        // 通知失败绝不能影响消息落库
        debugPrint('[p8] 通知失败：$e');
      }
    }
  }

  /// 原生通知动作（回复/已读/贪睡）→ 通知服务
  Future<void> handleNotificationAction(NotificationAction action) async {
    await ref.read(notificationServiceProvider).handleAction(action);
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

final chatSessionControllerProvider =
    NotifierProvider<ChatSessionController, ChatSyncState>(
      ChatSessionController.new,
    );
