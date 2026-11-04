// **可写的内存聊天频道**：让 Mock 也能"记住"发出去的消息（`Chat.Post/create`）。
//
// 为什么需要它（第 326 轮，macOS 写侧第五档）：
//   r319–r325 已经把**文件站 / 下载站 / 笔记 / 相册**的写动词接到可写内存上；
//   聊天模块在 Mock Server 上**没有任何 Post 夹具**（只有一条
//   `SYNO.Chat.Channel.list.json` 让频道列表能画出来）⇒ 消息只能走
//   "未注册夹具 ⇒ `{'success':true,'data':{}}`"（§2.0.38 的契约），
//   于是「发一条消息」成功没有**跨进程**意义上的判据。
//
// ★ 还有一道**协议前提**：`Chat.Post/create` 要一个 `conn_id`，它来自
//   **socket.io 的 `client.init` 事件**（`lib/src/data/remote/socket/chat_socket.dart:219`
//   `_handleInit`：`{id, version}` ⇒ `connId`）。Mock 的 socket 以前只回
//   `40`（连命名空间）就完了、**从不发 `client.init`** ⇒ 客户端的 `connId`
//   恒为 null ⇒ `sendMessage()` 在第一步就 `return false`（"连不上实时通道"）。
//   本轮把这一层补上：`mock_dsm_server.dart` 的 `_serveSocket` 收到 `40` 之后
//   发 `42["client.init",{"id":…,"version":…}]`，并把该 id 登记进本库。
//   ⇒ `Post/create` 可以**校验 `conn_id` 是不是本进程刚下发的那个** ——
//   这条判据同时证明"握手真的走通了"，而不是"参数恰好非空"。
//
// ★ 字段名逐字对齐客户端消费方 `lib/src/data/dto/post_dto.dart`
//   （`PostDto.fromJson`）：`post_id` / `channel_id` / `creator_id` / `thread_id`
//   / `type` / `message` / `create_at` / `update_at` / `comment_count` / `is_star`
//   / `is_sticky` / `props` / `hashtags` / `mentions` / `reactions` / `url_props`；
//   **列表根键是 `posts`**（`lib/src/data/chat_api.dart:1552` 读 `data['posts']`）。
// ★ 一切都在内存里，进程退出即消失；**不碰**真 NAS、不碰磁盘。
import 'mock_ds_demo.dart';
import 'mock_dsm_core.dart';

/// 内存库里的一条消息。
class MockChatPost {
  MockChatPost({
    required this.postId,
    required this.channelId,
    required this.message,
    this.creatorId = 1,
    int? createAt,
    this.type = 'normal',
    this.tmpPostId = 0,
  }) : createAt = createAt ?? DateTime.now().millisecondsSinceEpoch;

  final int postId;
  final int channelId;
  final String message;
  final int creatorId;
  /// Unix **毫秒**（与真机一致；见 `test/fixtures/post_list.json`）
  final int createAt;
  final String type;

  /// 客户端发来的本地临时 id（`mobile_token`，用于多设备对账）。
  final int tmpPostId;

  /// 服务端回包里的 `props`（`PostDto` 会读 `props.encrypted` / `safe_url`…）。
  Map<String, dynamic> get props => {'safe_url': true};
}

/// 一个极小的内存 ChatStation。
class MockChatStation {
  MockChatStation._(this._posts, this._seq);

  /// 种子里给 `channel 1`（`general`，就是 `SYNO.Chat.Channel.list.json` 里那条）
  /// 放**一条消息**，好让"进频道就能看到历史"这条路径有数据。
  factory MockChatStation.seeded() => MockChatStation._(<MockChatPost>[
    MockChatPost(
      postId: 1,
      channelId: 1,
      message: 'mock seeded message',
      // 种子消息**不是我自己发的**（`creator_id=2`）⇒ 界面画成"收到的消息"，
      // 与真机一致（自己发的在右侧带对勾）。
      creatorId: mockMateUserId,
      // ★ **毫秒**：真机录下来的 `test/fixtures/post_list.json` 里
      //   `create_at` 是 13 位（`1612400211640`）、`docs/chat-api-wire.md` 同。
      //   ⚠️ 我第一版按"秒"写，像素立刻抓到：日期分隔显示成 **1970/1/21**
      //   （客户端 `dayLabel()` 走的是 `DateTime.fromMillisecondsSinceEpoch`）
      //   —— 这就是"布局断言证明不了渲染，要看像素"的又一例。
      createAt: 1758800000000,
    ),
  ], 1);

  /// 只有库、没有任何消息（"列表里没有"要从空这个起点判）。
  factory MockChatStation.empty() => MockChatStation._(<MockChatPost>[], 0);

  final List<MockChatPost> _posts;
  int _seq;

  /// 本进程的"服务端数据库标识"。
  ///
  /// ★ 每次**起进程**都不一样（内存库本来就是空的）⇒ 客户端 `ChatUserLogin`
  ///   发现 `db_uuid` 与本地记录不一致时会 `store.clearAllData()`（官方
  ///   `DbUuidException` 的语义："服务端重装过，本地缓存作废"）。
  ///   这条同时让走查**每次从干净的本地库开始**，不会被上一轮遗留的旧消息干扰。
  final String dbUuid =
      'mock-chat-db-${DateTime.now().microsecondsSinceEpoch}';

  /// 本机用户的 `user_id`（与 `SYNO.Chat.Channel.list.json` 里的 `members:[1,2]`
  /// 和 `user.user_id = 1` 对齐）。
  static const int mockUserId = 1;

  /// 另一个真人成员（`SYNO.Chat.Channel.list.json` 的 `members:[1,2]`）——
  /// 用来演示"收到的消息"与"我发的消息"两种气泡。
  static const int mockMateUserId = 2;

  /// 一个合法的 `UserVo`（`UserDto.fromJson` 消费的键名）。
  Map<String, dynamic> get mockUserJson => _userJson(
    mockUserId,
    'mockuser',
    'Mock User',
  );

  /// 频道里的另一位真人成员。
  Map<String, dynamic> get mockMateJson =>
      _userJson(mockMateUserId, 'mockmate', 'Mock Mate');

  static Map<String, dynamic> _userJson(
    int id,
    String username,
    String nickname,
  ) => {
    'user_id': id,
    'username': username,
    'nickname': nickname,
    'type': 'human',
    'is_admin': false,
    'is_disabled': false,
  };

  /// 本进程通过 socket **下发过**的 `conn_id`（`_serveSocket` 登记进来）。
  final Set<String> issuedConnIds = <String>{};

  /// `Post/create` **接受过**的 `conn_id`（判据：它必须是下发过的那些之一）。
  final List<String> acceptedConnIds = <String>[];

  /// 收到的原始 form 值（排查"客户端到底发了什么形状"）。
  final List<({String rawConnId, String rawMessage, String type})> rawCreates =
      <({String rawConnId, String rawMessage, String type})>[];

  List<MockChatPost> get all => List<MockChatPost>.unmodifiable(_posts);

  /// 某个频道里已有的消息，按 `create_at` 升序（与界面一致：旧 → 新）。
  List<MockChatPost> postsOf(int channelId) {
    final out = [
      for (final p in _posts)
        if (p.channelId == channelId) p,
    ];
    out.sort((a, b) => a.createAt.compareTo(b.createAt));
    return out;
  }

  /// 登记一个刚下发的连接 id（由 mock 的 socket 层调用）。
  void registerConnId(String id) {
    if (id.isNotEmpty) issuedConnIds.add(id);
  }

  /// 落一条**新消息**（只有 `channelId > 0` 且正文非空才算合法）。
  MockChatPost? add({
    required int channelId,
    required String message,
    String type = 'normal',
    int tmpPostId = 0,
    int creatorId = 1,
  }) {
    if (channelId <= 0 || message.isEmpty) return null;
    _seq++;
    final made = MockChatPost(
      postId: _seq,
      channelId: channelId,
      message: message,
      creatorId: creatorId,
      type: type,
      tmpPostId: tmpPostId,
    );
    _posts.add(made);
    return made;
  }
}

extension MockChatDemo on MockDsmBackend {
  /// 装上内存聊天库并注册夹具；返回库本体（服务端与用例可读）。
  MockChatStation installChatDemo({MockChatStation? station}) {
    final db = station ?? MockChatStation.seeded();

    Map<String, dynamic> postJson(MockChatPost p) => {
      'post_id': p.postId,
      'channel_id': p.channelId,
      'creator_id': p.creatorId,
      'thread_id': 0,
      'type': p.type,
      'message': p.message,
      'create_at': p.createAt,
      'update_at': p.createAt,
      'delete_at': 0,
      'last_comment_at': 0,
      'last_pin_at': 0,
      'comment_count': 0,
      'is_star': false,
      'is_sticky': false,
      'props': p.props,
      'hashtags': <String>[],
      'hashtags_additional': <dynamic>[],
      'mentions': <int>[],
      'reactions': <dynamic>[],
      'url_props': <dynamic>[],
      // 客户端会把它当 `tmp_post_id` 回读（`PostDto.fromJson` 的 `mobile_token` 兜底）
      if (p.tmpPostId > 0) 'mobile_token': p.tmpPostId,
    };

    /// `Chat.User/login`（v1）—— 聊天登录链的**第一步**。
    ///
    /// 客户端 `ChatUserLogin.fromJson` 读 `current_time`（**毫秒**）/`db_uuid`/
    /// `user.user_id`/`user.is_admin`。此前 Mock 没有这条 ⇒ 全部为 0/空：
    /// `myUserId = 0`（自己发的消息被当成别人的）、`db_uuid` 为空 ⇒
    /// 陈旧缓存永远清不掉（走查里就会看到**别的会话遗留的旧频道/旧消息**）。
    fixture('SYNO.Chat.User', 'login', (p) {
      return {
        'success': true,
        'data': {
          'db_uuid': db.dbUuid,
          'current_time': DateTime.now().millisecondsSinceEpoch,
          'first_time': false,
          'user': db.mockUserJson,
        },
      };
    });

    /// `Chat.User/get`（v3）—— "我是谁"（`myUser()` 读 `data['user']`）。
    fixture('SYNO.Chat.User', 'get', (p) {
      return {
        'success': true,
        'data': {'user': db.mockUserJson},
      };
    });

    /// `Chat.User/list`（v2）—— 按 `type` 分 human/bot 两段（客户端走 compound）。
    fixture('SYNO.Chat.User', 'list', (p) {
      final type = '${p['type'] ?? 'human'}';
      final users = type == 'bot'
          ? <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[db.mockUserJson, db.mockMateJson];
      return {
        'success': true,
        'data': {'users': users},
      };
    });

    /// `Post/list`：客户端进频道时拉第一页（`channel_id` + `prev_count`/`next_count`）。
    fixture('SYNO.Chat.Post', 'list', (p) {
      final channelId = int.tryParse('${p['channel_id'] ?? '0'}') ?? 0;
      final prev = int.tryParse('${p['prev_count'] ?? '50'}') ?? 50;
      final rows = db.postsOf(channelId);
      // `prev_count` = 取末尾多少条（界面是"最新的在下"）
      final page = prev > 0 && rows.length > prev
          ? rows.sublist(rows.length - prev)
          : rows;
      return {
        'success': true,
        'data': {
          'posts': [for (final x in page) postJson(x)],
          'total': rows.length,
        },
      };
    });

    /// `Post/create`：**发消息**。
    ///
    /// ★ 仪器契约（每条都在单测里钉住）：
    ///   ① `conn_id` / `message` 必须是**官方 `RO` 规则的 JSON 串**（带引号）
    ///      —— 不是就回 `120`（客户端 `_jsonString` 总是加引号；裸值是真缺陷）；
    ///   ② `conn_id` 必须是**本进程 socket 刚下发过的那个**，否则回 `101`
    ///      （★ 这是**本仪器的约定**，官方对失效 conn_id 的错误码未取证）；
    ///   ③ 频道/正文非法（`channel_id<=0`、正文空）⇒ `114`，且**不留下半条**。
    fixture('SYNO.Chat.Post', 'create', (p) {
      final rawConn = '${p['conn_id'] ?? ''}';
      final rawMessage = '${p['message'] ?? ''}';
      final connId = unquoteJson(rawConn);
      final message = unquoteJson(rawMessage);
      final type = '${p['type'] ?? 'normal'}';
      db.rawCreates.add((rawConnId: rawConn, rawMessage: rawMessage, type: type));
      if (!rawConn.startsWith('"') || !rawMessage.startsWith('"')) {
        return {
          'success': false,
          'error': {'code': 120},
        };
      }
      if (connId.isEmpty || !db.issuedConnIds.contains(connId)) {
        return {
          'success': false,
          'error': {'code': 101},
        };
      }
      final channelId = int.tryParse('${p['channel_id'] ?? '0'}') ?? 0;
      final tmp = int.tryParse(unquoteJson('${p['mobile_token'] ?? ''}')) ?? 0;
      final made = db.add(
        channelId: channelId,
        message: message,
        type: type == 'normal' || type.isEmpty ? 'normal' : type,
        tmpPostId: tmp,
      );
      if (made == null) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      db.acceptedConnIds.add(connId);
      return {
        'success': true,
        'data': {'post': postJson(made)},
      };
    });

    return db;
  }
}
