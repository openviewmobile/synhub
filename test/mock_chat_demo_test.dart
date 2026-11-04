// `tool/mock_dsm/mock_chat_demo.dart`（可写内存聊天库）的离线用例。
//
// 为什么要有这一档（第 326 轮）：聊天模块在 Mock Server 上**没有任何 Post 夹具**
// ⇒ 「发一条消息」成功没有**跨进程**意义上的判据；而且 `Chat.Post/create` 要的
// `conn_id` 来自 socket 的 `client.init` 事件（Mock 以前从不下发 ⇒ 客户端
// `connId` 恒 null ⇒ `sendMessage()` 第一步就返回 false）。
// 这个文件把两条都钉住：① `conn_id` 必须是**本进程 socket 下发过的那个**；
// ② `RO` 规则（`conn_id`/`message` 必须是带引号的 JSON 串）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';

import '../tool/mock_dsm/mock_chat_demo.dart';
import '../tool/mock_dsm/mock_dsm_core.dart';

/// 起一台装了聊天内存库的 backend + 取库引用。
({
  MockDsmBackend b,
  MockChatStation db,
  MockDsmResponse Function(String, String, Map<String, dynamic>) call,
})
_boot({MockChatStation? seeded}) {
  final b = MockDsmBackend(catalog: DsmCatalog.load());
  // ★ 走 `backend.handle(...)`（与真机同一条入口：目录校验 + 版本 + 方法表 +
  //   authLevel 都过一遍），**不要**直接摸 `fixtures`。
  final sid = b.login(username: 'mockuser', admin: false);
  final db = b.installChatDemo(station: seeded);

  /// ★ 版本按目录协商（`Chat.Post` 的 maxVersion 是 8；`list` 在 v1..v8 都有）。
  ///   仪器侧也要按方法表谈版本（§2.0.15 在仪器侧的复现）。
  int versionFor(String api, String method) {
    final spec = b.catalog.apis[api];
    if (spec == null) return 1;
    for (var v = spec.maxVersion; v >= spec.minVersion; v--) {
      if (spec.methods[v]?.contains(method) ?? false) return v;
    }
    return spec.maxVersion;
  }

  MockDsmResponse call(
    String api,
    String method,
    Map<String, dynamic> p, {
    int? version,
  }) => b.handle('entry.cgi', {
    'api': api,
    'method': method,
    'version': version ?? versionFor(api, method),
    '_sid': sid,
    ...p,
  });
  return (b: b, db: db, call: call);
}

Map<String, dynamic> _data(MockDsmResponse r) =>
    Map<String, dynamic>.from(r.json['data'] as Map);

List<Map<String, dynamic>> _posts(MockDsmResponse r) => [
  for (final e in (_data(r)['posts'] as List)) Map<String, dynamic>.from(e as Map),
];

/// 客户端 `createPost` 的**逐字形状**：`conn_id`/`message` 带引号、`type` 裸值。
Map<String, dynamic> _createParams({
  required String connId,
  required String message,
  int channelId = 1,
  int tmpPostId = 0,
  String type = 'normal',
}) => {
  'channel_id': '$channelId',
  'conn_id': '"$connId"',
  'message': '"$message"',
  'type': type,
  'is_thread': 'false',
  'mobile_token': '"$tmpPostId"',
};

void main() {
  test('① 种子频道 1 有一条消息；`Post/list` 的字段名与真 DTO 一致', () {
    final h = _boot();
    final r = h.call('SYNO.Chat.Post', 'list', {'channel_id': '1'});
    expect(r.ok, isTrue);
    final posts = _posts(r);
    expect(posts, hasLength(1));
    expect(posts.first['message'], 'mock seeded message');
    expect(
      posts.first['creator_id'],
      MockChatStation.mockMateUserId,
      reason: '种子是**别人**发的（界面要画成收到的消息，而不是我发的）',
    );
    // 用**真 DTO** 解析：字段名写错这条会红
    final dto = PostDto.fromJson(posts.first);
    expect(dto.postId, 1);
    expect(dto.channelId, 1);
    expect(dto.message, 'mock seeded message');
    expect(dto.creatorId, greaterThan(0));
    expect(dto.type, 'normal');
    expect(dto.createAt, greaterThan(1000000000000), reason: '毫秒（13 位）量级');
    expect(dto.encrypted, isFalse);
    expect(dto.safeUrl, isTrue, reason: 'props.safe_url 缺失时默认 true');
  });

  test('② 频道隔离：别的频道是空的（0 条也要能判）', () {
    final h = _boot();
    final other = h.call('SYNO.Chat.Post', 'list', {'channel_id': '2'});
    expect(_posts(other), isEmpty);
    expect(_data(other)['total'], 0);
  });

  test('③ **socket 下发过的 `conn_id`** + 合法形状 ⇒ 落库、`list` 能回读', () {
    final h = _boot();
    h.db.registerConnId('mock-socket-1-conn');
    final before = _posts(h.call('SYNO.Chat.Post', 'list', {'channel_id': '1'}));
    final made = h.call(
      'SYNO.Chat.Post',
      'create',
      _createParams(
        connId: 'mock-socket-1-conn',
        message: 'r326 发出去的第一条',
        tmpPostId: 4242,
      ),
    );
    expect(made.ok, isTrue);
    expect(_data(made)['post'], isA<Map>(), reason: '客户端读 `data["post"]`');
    final after = _posts(h.call('SYNO.Chat.Post', 'list', {'channel_id': '1'}));
    expect(after, hasLength(before.length + 1), reason: '判据取 list 回读');
    final last = after.last;
    expect(last['message'], 'r326 发出去的第一条');
    expect(last['channel_id'], 1);
    // `mobile_token` 会被 `PostDto` 当 `tmp_post_id` 回读（多设备对账）
    expect(PostDto.fromJson(last).tmpPostId, 4242);
    expect(h.db.acceptedConnIds, ['mock-socket-1-conn']);
  });

  test('④ ★ 未下发过的 `conn_id` ⇒ 101，**不许**落库（这条证明握手是真前提）', () {
    final h = _boot();
    final before = h.db.all.length;
    final bad = h.call(
      'SYNO.Chat.Post',
      'create',
      _createParams(connId: 'not-from-this-socket', message: '不该进去'),
    );
    expect(bad.ok, isFalse);
    expect(bad.errorCode, 101);
    expect(h.db.all, hasLength(before), reason: '被拒的请求不许改状态');
    // 登记之后同一个 id 就能发了（反向验证：拒的原因**确实**是"没下发过"）
    final id = 'not-from-this-socket';
    h.db.registerConnId(id);
    final ok = h.call(
      'SYNO.Chat.Post',
      'create',
      _createParams(connId: id, message: '现在能进去了'),
    );
    expect(ok.ok, isTrue, reason: '登记后必须放行（否则拒绝理由是编的）');
  });

  test('⑤ ★ 官方 `RO` 规则：`conn_id`/`message` 必须是**带引号的 JSON 串**', () {
    final h = _boot();
    h.db.registerConnId('c1');
    final before = h.db.all.length;
    // 裸 message（不带引号）
    final bareMsg = h.call('SYNO.Chat.Post', 'create', {
      'channel_id': '1',
      'conn_id': '"c1"',
      'message': 'bare text',
      'type': 'normal',
    });
    expect(bareMsg.errorCode, 120);
    // 裸 conn_id（不带引号）
    final bareConn = h.call('SYNO.Chat.Post', 'create', {
      'channel_id': '1',
      'conn_id': 'c1',
      'message': '"text"',
      'type': 'normal',
    });
    expect(bareConn.errorCode, 120);
    expect(h.db.all, hasLength(before), reason: '两次被拒都不许改状态');
    // 记录下的**原始**形态（排查用）：确实是裸值
    expect(h.db.rawCreates.first.rawMessage, 'bare text');
    expect(h.db.rawCreates.last.rawConnId, 'c1');
  });

  test('⑥ 频道号非法 / 正文为空 ⇒ 114，且不留下半条', () {
    final h = _boot();
    h.db.registerConnId('c1');
    final before = h.db.all.length;
    final noChannel = h.call(
      'SYNO.Chat.Post',
      'create',
      _createParams(connId: 'c1', message: 'x', channelId: 0),
    );
    expect(noChannel.errorCode, 114);
    final emptyMsg = h.call(
      'SYNO.Chat.Post',
      'create',
      _createParams(connId: 'c1', message: ''),
    );
    expect(emptyMsg.errorCode, 114);
    expect(h.db.all, hasLength(before));
  });

  test('⑦ `post_id` 递增、`create_at` 是**毫秒**、`prev_count` 取末尾 N 条', () {
    final h = _boot();
    h.db.registerConnId('c1');
    for (var i = 0; i < 3; i++) {
      final r = h.call(
        'SYNO.Chat.Post',
        'create',
        _createParams(connId: 'c1', message: '第 $i 条'),
      );
      expect(r.ok, isTrue);
    }
    final all = _posts(h.call('SYNO.Chat.Post', 'list', {'channel_id': '1'}));
    expect(all, hasLength(4), reason: '1 条种子 + 3 条新发');
    final ids = [for (final p in all) p['post_id'] as int];
    expect(ids, [1, 2, 3, 4], reason: '按 create_at 升序回读');
    // ★ **毫秒**（真机 `test/fixtures/post_list.json` = `1612400211640`）：
    //   客户端 `dayLabel()`/`_PostTile._time()` 都是
    //   `DateTime.fromMillisecondsSinceEpoch(createAt)` ⇒ 写"秒"会让日期
    //   分隔显示成 1970（r326 像素抓到过）。
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final delta = (all.last['create_at'] as int) - nowMs;
    expect(delta.abs(), lessThan(60 * 1000), reason: '毫秒量级：差 < 1 分钟');
    final page = _posts(
      h.call('SYNO.Chat.Post', 'list', {'channel_id': '1', 'prev_count': '2'}),
    );
    expect(page.map((p) => p['message']), ['第 1 条', '第 2 条']);
  });

  test('⑧ `empty()` 的起点是"一条消息都没有"', () {
    final h = _boot(seeded: MockChatStation.empty());
    final r = h.call('SYNO.Chat.Post', 'list', {'channel_id': '1'});
    expect(_posts(r), isEmpty);
  });

  // ---- ⑩–⑫：`SYNO.Entry.Request/request`（DSM 的批量调用）----
  //
  // ★ 为什么这几条在**这一轮**加：真机第一次踩到 compound 是**聊天同步** ——
  //   `ChatSessionController._sync` 第 2 步 `listUsers()` 走的就是
  //   `api.compound([Chat.User/list human, Chat.User/list bot])`。
  //   Mock 原先不解析 `compound` ⇒ 客户端抛"响应缺少 result 数组" ⇒
  //   后面 `listChannels()` 根本没执行 ⇒ **频道列表只剩本地旧数据**
  //   （屏上显示的是别的会话遗留的频道，看着像"夹具没生效"）。

  test('⑩ compound 两段：顺序保留、逐段 success、`has_fail=false`', () {
    final h = _boot();
    // 先造一条消息，证明子请求**真的走了业务**（不是"复制粘贴的假回包"）
    h.db.registerConnId('c1');
    h.call(
      'SYNO.Chat.Post',
      'create',
      _createParams(connId: 'c1', message: 'compound 之前的消息'),
    );
    final r = h.call('SYNO.Entry.Request', 'request', {
      'compound': jsonEncode([
        {
          'api': 'SYNO.Chat.User',
          'method': 'list',
          'version': 2,
          'type': 'human',
        },
        {
          'api': 'SYNO.Chat.Post',
          'method': 'list',
          'version': 2,
          'channel_id': '1',
        },
      ]),
      'mode': 'parallel',
    });
    expect(r.ok, isTrue);
    final data = _data(r);
    expect(data['has_fail'], isFalse);
    final result = (data['result'] as List);
    expect(result, hasLength(2), reason: '顺序与请求一致、一段不少');
    final seg0 = Map<String, dynamic>.from(result[0] as Map);
    final seg1 = Map<String, dynamic>.from(result[1] as Map);
    expect(seg0['api'], 'SYNO.Chat.User');
    expect(seg0['method'], 'list');
    expect(seg0['version'], 2);
    expect(seg0['success'], isTrue);
    expect(seg1['api'], 'SYNO.Chat.Post');
    final posts = (seg1['data'] as Map)['posts'] as List;
    expect(
      [for (final p in posts) (p as Map)['message']],
      contains('compound 之前的消息'),
    );
  });

  test('⑪ compound 里有一段坏（版本里没这个方法）⇒ `has_fail=true`，但整体仍 success', () {
    final h = _boot();
    final r = h.call('SYNO.Entry.Request', 'request', {
      'compound': jsonEncode([
        {
          'api': 'SYNO.Chat.Post',
          'method': 'list',
          'version': 2,
          'channel_id': '1',
        },
        // `Chat.Channel` v1 的方法表里没有 `list_channels` 这种拼写
        {
          'api': 'SYNO.Chat.Channel',
          'method': 'list_channels',
          'version': 1,
        },
      ]),
    });
    expect(r.ok, isTrue, reason: '整体是成功的（每段自带 success）');
    final data = _data(r);
    expect(data['has_fail'], isTrue);
    final result = (data['result'] as List);
    expect((result[0] as Map)['success'], isTrue, reason: '好的那段照旧有数据');
    expect((result[1] as Map)['success'], isFalse);
    expect(((result[1] as Map)['error'] as Map)['code'], 103);
  });

  test('⑫ compound 参数缺失/不是 JSON 数组 ⇒ 114；★ 鉴权在**每一段**上', () {
    final h = _boot();
    expect(h.call('SYNO.Entry.Request', 'request', const {}).errorCode, 114);
    expect(
      h.call('SYNO.Entry.Request', 'request', const {'compound': 'not-json'})
          .errorCode,
      114,
    );
    // ★ 未登录：**外层** `SYNO.Entry.Request` 的 authLevel 就是 **0**
    //   （权威目录 `catalog.json`：`authLevel: 0`，来自 SPK 的 `.lib`）
    //   ⇒ 批量调用本身不要求会话，**鉴权落在每一段上**。
    //   这条同时证明我们的实现是"逐段走同一条 handle()"，而不是"一次放行全放行"。
    final noAuth = h.b.handle('/entry.cgi', const {
      'api': 'SYNO.Entry.Request',
      'method': 'request',
      'version': 2,
      'compound':
          '[{"api":"SYNO.Chat.Post","method":"list","version":2,'
          '"channel_id":"1"}]',
    });
    expect(noAuth.ok, isTrue, reason: '外层 authLevel=0，不拦');
    final seg = ((_data(noAuth)['result'] as List).single as Map);
    expect(seg['success'], isFalse);
    expect((seg['error'] as Map)['code'], 119, reason: '未登录的**那一段**回 119');
  });

  // ---- ⑬–⑮：聊天登录链（`User/login` / `User/get` / `User/list`）----
  //
  // ★ 为什么在这一轮补：Mock 原先这三条**都没有夹具** ⇒ `myUserId = 0`、
  //   `db_uuid` 为空：自己发的消息被当成"别人发的"，且**陈旧缓存永远清不掉**
  //   （走查里屏上会出现上一轮/别的会话遗留的旧频道与旧消息）。

  test('⑬ `User/login` 的 `db_uuid`/`current_time`/`user` 能被真 `ChatUserLogin` 解析', () {
    final h = _boot();
    final r = h.call('SYNO.Chat.User', 'login', const {});
    expect(r.ok, isTrue);
    final login = ChatUserLogin.fromJson(_data(r));
    expect(login.dbUuid, isNotEmpty);
    expect(login.userId, MockChatStation.mockUserId);
    expect(login.isAdmin, isFalse);
    // `current_time` 是**毫秒**（`ChatUserLogin.skewMillis()` 与本地毫秒相减）
    expect(login.skewMillis().abs(), lessThan(60000));
  });

  test('⑭ `User/get` 与 `User/list`（human/bot）的键名对得上真 `UserDto`', () {
    final h = _boot();
    final me = h.call('SYNO.Chat.User', 'get', const {});
    final dto = UserDto.fromJson(
      Map<String, dynamic>.from((_data(me)['user'] as Map)),
    );
    expect(dto.userId, MockChatStation.mockUserId);
    expect(dto.username, 'mockuser');
    expect(dto.nickname, 'Mock User');
    expect(dto.type, 'human');
    expect(dto.isDisabled, isFalse);

    final humans = h.call('SYNO.Chat.User', 'list', const {'type': 'human'});
    final users = (_data(humans)['users'] as List)
        .map((e) => UserDto.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    expect(users, hasLength(2), reason: '我自己 + 频道里另一位成员');
    expect(users.first.userId, MockChatStation.mockUserId);
    expect(users.last.userId, MockChatStation.mockMateUserId);
    final bots = h.call('SYNO.Chat.User', 'list', const {'type': 'bot'});
    expect(_data(bots)['users'], isEmpty);
  });

  test('⑮ `db_uuid` 每次起库都不同（= 客户端会清掉陈旧缓存）', () {
    final a = MockChatStation.seeded();
    final b = MockChatStation.seeded();
    expect(a.dbUuid, isNot(b.dbUuid));
    expect(a.dbUuid, startsWith('mock-chat-db-'));
  });

  test('⑨ 直接构造的库也能被 fixture 用（`add()` 的合法性判据）', () {
    final db = MockChatStation.empty();
    expect(db.add(channelId: 0, message: 'x'), isNull, reason: '频道号非法');
    expect(db.add(channelId: 1, message: ''), isNull, reason: '正文为空');
    expect(db.add(channelId: 1, message: 'ok')?.postId, 1);
    expect(db.postsOf(1).single.message, 'ok');
  });
}
