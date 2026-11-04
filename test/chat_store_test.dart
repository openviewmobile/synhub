// ChatStore 的离线单元测试 —— 用内存 SQLite（NativeDatabase.memory()）验证
// drift 表的 upsert / 排序 / 未读计数 / JSON 列往返。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';

void main() {
  late ChatDatabase db;
  late ChatStore store;

  setUp(() {
    db = ChatDatabase(NativeDatabase.memory());
    store = ChatStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('upsertChannels 先插入再按 channel_id 覆盖，不产生重复行', () async {
    await store.upsertChannels([const ChannelDto(channelId: 1, name: 'A')]);
    await store.upsertChannels([const ChannelDto(channelId: 1, name: 'B')]);

    final all = await store.allChannels();
    expect(all, hasLength(1));
    expect(all.single.channelId, 1);
    expect(all.single.name, 'B');
  });

  test('upsertUsers 的字段合并不能把机器人/斜杠命令字段抹掉（踩过的坑）', () async {
    // 真机链路：`User/list` 分 human/bot 两段，同一个机器人会被写两次，
    // 第二次走 `_mergeUser`。早先 `_mergeUser` 漏传 bot/slash 字段 →
    // `welcome_note`/`purpose`/`hide_from_user`/`slash_cmd` 全被清空，
    // 机器人列表（`isListedBot`）和机器人会话欢迎语跟着一起坏。
    final bot = UserDto.fromJson(const {
      'user_id': 11,
      'username': 'bot_11',
      'nickname': '小助手',
      'type': 'bot',
      'bot_type': 'chatbot',
      'chatbot_props': {
        'welcome_note': '有什么可以帮您？',
        'purpose': '答疑',
        'hide_from_user': true,
      },
      'bot_props': {'is_system': true, 'sticker_name': 'synobot'},
    });
    await store.upsertUsers([bot]);
    // 第二次写：同一个人、只有基础字段（模拟分段返回/部分广播）
    await store.upsertUsers([
      UserDto.fromJson(const {
        'user_id': 11,
        'username': 'bot_11',
        'nickname': '小助手',
        'type': 'bot',
        'bot_type': 'chatbot',
      }),
    ]);
    final u = (await store.allUsers()).single;
    expect(u.chatbotWelcomeNote, '有什么可以帮您？');
    expect(u.chatbotPurpose, '答疑');
    expect(u.chatbotHideFromUser, isTrue);
    expect(u.botIsSystem, isTrue);
    expect(u.botStickerName, 'synobot');
    expect(u.isListedBot, isFalse, reason: 'hide_from_user 的机器人不该列出来');

    // 斜杠命令机器人同理
    final slash = UserDto.fromJson(const {
      'user_id': 12,
      'username': 'jitsi',
      'type': 'bot',
      'bot_type': 'slash',
      'slash_props': {
        'cmd': 'jitsi',
        'description': '开视频会议',
        'url': 'https://example.com/j',
      },
    });
    await store.upsertUsers([slash]);
    await store.upsertUsers([
      UserDto.fromJson(const {
        'user_id': 12,
        'username': 'jitsi',
        'type': 'bot',
        'bot_type': 'slash',
      }),
    ]);
    final s2 = (await store.allUsers()).firstWhere((u) => u.userId == 12);
    expect(s2.slashCmd, 'jitsi');
    expect(s2.slashDescription, '开视频会议');
    expect(s2.slashUrl, 'https://example.com/j');
    expect(s2.isSlashBot, isTrue);
  });

  test('upsertChannels 遇到空字段时保留旧值（非例外字段）', () async {
    await store.upsertChannels([
      const ChannelDto(channelId: 1, name: 'A', purpose: 'p', creatorId: 42),
    ]);
    await store.upsertChannels([const ChannelDto(channelId: 1, name: '')]);

    final c = (await store.allChannels()).single;
    expect(c.name, 'A');
    expect(c.purpose, 'p');
    expect(c.creatorId, 42);
  });

  test(
    'watchChannels 按 sortKey 降序（channelOrderTime 缺失时退回 lastPostAt）',
    () async {
      await store.upsertChannels([
        const ChannelDto(channelId: 1, channelOrderTime: 0, lastPostAt: 100),
        const ChannelDto(channelId: 2, channelOrderTime: 200),
        const ChannelDto(channelId: 3, channelOrderTime: 0, lastPostAt: 50),
      ]);

      final list = await store.watchChannels().first;
      expect(list.map((c) => c.channelId).toList(), [2, 1, 3]);
      expect(list.map((c) => c.sortKey).toList(), [200, 100, 50]);
    },
  );

  test('applyPostCreate 未读 +1 并更新 lastPostAt；未知频道返回 null', () async {
    await store.upsertChannels([
      const ChannelDto(channelId: 7, unread: 1, lastPostAt: 100),
    ]);

    final updated = await store.applyPostCreate(channelId: 7, createAt: 200);
    expect(updated, isNotNull);
    expect(updated!.unread, 2);
    expect(updated.lastPostAt, 200);

    // 已落库
    final stored = (await store.allChannels()).single;
    expect(stored.unread, 2);
    expect(stored.lastPostAt, 200);

    // 未知频道
    expect(await store.applyPostCreate(channelId: 999, createAt: 1), isNull);
  });

  test('markRead 清零未读系列并把 lastViewAt 设为 nowMillis', () async {
    await store.upsertChannels([
      const ChannelDto(
        channelId: 3,
        unread: 5,
        unreadMention: 2,
        unreadComment: 4,
        unreadMentionComment: 1,
        unreadThread: {11: 3},
        lastViewAt: 10,
      ),
    ]);

    await store.markRead(3, nowMillis: 999);

    final c = (await store.allChannels()).single;
    expect(c.unread, 0);
    expect(c.unreadMention, 0);
    expect(c.unreadComment, 0);
    expect(c.unreadMentionComment, 0);
    expect(c.unreadThread, isEmpty);
    expect(c.lastViewAt, 999);
  });

  test('setJoined 只改 isJoined', () async {
    await store.upsertChannels([
      const ChannelDto(channelId: 5, name: 'n', isJoined: false),
    ]);

    final joined = await store.setJoined(5, joined: true);
    expect(joined!.isJoined, isTrue);
    expect(joined.name, 'n');

    expect(await store.setJoined(999, joined: true), isNull);
  });

  test('upsertUsers 按 user_id 覆盖，且新 avatarColor 为空时保留旧值', () async {
    await store.upsertUsers([
      const UserDto(userId: 1, username: 'u', avatarColor: '#ff0000'),
    ]);
    await store.upsertUsers([
      const UserDto(userId: 1, username: 'u2', avatarColor: ''),
    ]);

    final users = await store.allUsers();
    expect(users, hasLength(1));
    expect(users.single.username, 'u2');
    expect(users.single.avatarColor, '#ff0000');
  });

  test('upsertUserFromEvent 解析 user.update 载荷写入用户', () async {
    await store.upsertUserFromEvent({
      'user_id': 9,
      'username': 'bob',
      'nickname': 'Bob',
      'user_props': {'avatar_color': '#00ff00'},
    });

    final users = await store.allUsers();
    expect(users, hasLength(1));
    expect(users.single.userId, 9);
    expect(users.single.displayName, 'Bob');
    expect(users.single.avatarColor, '#00ff00');
  });

  test('unreadThread / subscribes / members 经 JSON 文本往返', () async {
    const thread = {11: 2, 22: 3};
    const subscribes = [100, 200];
    const members = [1, 2, 3];

    await store.upsertChannels([
      const ChannelDto(
        channelId: 4,
        unreadThread: thread,
        subscribes: subscribes,
        members: members,
      ),
    ]);

    final c = (await store.allChannels()).single;
    expect(c.unreadThread, thread);
    expect(c.subscribes, subscribes);
    expect(c.members, members);

    // 重新读一遍（走磁盘以外的同一库，确认不是内存缓存）
    final again = (await store.allChannels()).single;
    expect(again.unreadThread, thread);
    expect(again.members, members);
  });

  // ---------------------------------------------------------------- 本地清理

  // 对位官方 `DatabaseHelper.setChannels(channels, true)`
  // （`DatabaseHelper.java:703-739`：本地行不在传入列表里且 flag 为 true 时
  // `delete("ChatChannel", "channel_id = ? ")`）。
  //
  // 冒烟现象：真机上出现过 `hidden:Synology Office:1028…` 这种**服务端早已
  // 不再返回**的频道，未读数也是本地陈旧值。根因就是原实现只 upsert、从不删。
  group('upsertChannels(removeMissing:) 服务端不再返回的频道要清掉', () {
    test('默认 false：不剪（事件路径的单条 upsert 不能误删别的频道）', () async {
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
        const ChannelDto(channelId: 2, name: '会被服务端丢掉'),
      ]);

      // 只 upsert 频道 1，且**不带** removeMissing
      await store.upsertChannels([const ChannelDto(channelId: 1, name: 'A2')]);

      final ids = (await store.allChannels()).map((c) => c.channelId).toList();
      expect(ids, containsAll(<int>[1, 2]));
    });

    test('true：服务端没返回的行连同它的消息一起删掉', () async {
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: '还在'),
        const ChannelDto(channelId: 2, name: 'hidden:Synology Office:1028'),
      ]);
      await store.upsertPosts([
        const PostDto(postId: 10, channelId: 2, message: '陈旧消息'),
        const PostDto(postId: 11, channelId: 1, message: '正常消息'),
      ]);

      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: '还在'),
      ], removeMissing: true);

      final ids = (await store.allChannels()).map((c) => c.channelId).toList();
      expect(ids, [1], reason: '服务端不再返回的频道 2 必须消失');
      expect(await store.postsForChannel(2), isEmpty, reason: '关联消息也要清');
      expect(
        await store.postsForChannel(1),
        hasLength(1),
        reason: '在列表里的频道不能误删',
      );
    });

    test('服务端仍返回的频道即使字段为空也保留（只剪"名单外"的）', () async {
      await store.upsertChannels([
        const ChannelDto(
          channelId: 1,
          name: 'A',
          purpose: 'p',
          channelKeyEnc: 'KEY',
        ),
      ]);

      // 服务端这次只回了 id + 空字段（合并规则保留旧值），行必须还在
      await store.upsertChannels([
        const ChannelDto(channelId: 1),
      ], removeMissing: true);

      final c = (await store.allChannels()).single;
      expect(c.name, 'A');
      expect(c.purpose, 'p');
      expect(c.channelKeyEnc, 'KEY');
    });

    test('空列表绝不剪库（回包抖动/形状意外时不能把整个频道库清空）', () async {
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
        const ChannelDto(channelId: 2, name: 'B'),
      ]);

      await store.upsertChannels(const [], removeMissing: true);

      final ids = (await store.allChannels()).map((c) => c.channelId).toList();
      expect(ids, [1, 2], reason: '空列表="没拿到"，不是"服务端说一个都没有"');
    });

    test('有失败消息（state=2）的频道不剪，消息也留着（重发入口不能丢）', () async {
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
        const ChannelDto(channelId: 2, name: '有失败消息'),
      ]);
      final tmpId = await store.insertPendingPost(
        channelId: 2,
        creatorId: 9,
        message: '发不出去',
        nowMillis: 1000,
      );
      await store.failPendingPost(2, tmpId);

      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
      ], removeMissing: true);

      final ids = (await store.allChannels()).map((c) => c.channelId).toList();
      expect(ids, containsAll(<int>[1, 2]), reason: 'state=2 的频道是例外，不能藏');
      expect(await store.postsForChannel(2), hasLength(1));
    });

    test('有过期消息（state=3）的频道同样不剪（2 进频道后会变成 3）', () async {
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
        const ChannelDto(channelId: 2, name: '有过期消息'),
      ]);
      await store.insertPendingPost(
        channelId: 2,
        creatorId: 9,
        message: '过期了',
        nowMillis: 1000,
      );
      await store.markOutdatedPosts(2, nowMillis: 2000);

      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
      ], removeMissing: true);

      final ids = (await store.allChannels()).map((c) => c.channelId).toList();
      expect(ids, containsAll(<int>[1, 2]), reason: '漏了 state=3 就会出现"消息找不回"');
      expect(await store.postsForChannel(2), hasLength(1));
    });

    test('绝不碰 keyValueRows：E2EE 身份等本地设置清理后仍可读', () async {
      // 'e2ee_identity' = `E2eeService._identityKey`（私钥封口令后存在这里）
      await store.setSetting('e2ee_identity', '{"private_key_enc":"SEALED"}');
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
        const ChannelDto(channelId: 2, name: '会消失'),
      ]);

      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
      ], removeMissing: true);

      final settings = await store.allSettings();
      expect(settings['e2ee_identity'], '{"private_key_enc":"SEALED"}');
    });

    test('带 channel_key_enc 的加密频道不剪（那份密文只有本地有，删了就永久丢密钥）', () async {
      // 服务端 `Channel/list` 对"自己建的"频道**不返回** channel_key_enc，
      // 而 `E2eeService._channelKeys` 只是内存 map ⇒ 这一列是重启后唯一的
      // 密钥恢复来源（`loadChannelKeys`）。剪掉行 = 历史密文永久解不开。
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
        const ChannelDto(
          channelId: 7,
          name: '加密频道',
          encrypted: true,
          channelKeyEnc: 'SEALED-KEY',
        ),
      ]);

      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
      ], removeMissing: true);

      final all = await store.allChannels();
      expect(
        all.map((c) => c.channelId),
        containsAll(<int>[1, 7]),
        reason: '带 E2EE 密文的行不能由"清理缓存"清掉',
      );
      final enc = all.firstWhere((c) => c.channelId == 7);
      expect(enc.channelKeyEnc, 'SEALED-KEY');
    });
    test('本地新建保护是**临时**的：服务端一旦收录，之后再消失照样剪（剪枝没被废掉）', () async {
      // "先写本地、再同步"的既有写法（`initiateChatbot` / 加密频道 create）
      await store.upsertLocallyCreatedChannel(
        const ChannelDto(channelId: 77, name: '刚建的'),
      );

      // ① 服务端还没收录 → 保护，绝不能删
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
      ], removeMissing: true);
      expect(
        (await store.allChannels()).map((c) => c.channelId),
        containsAll(<int>[1, 77]),
        reason: '列表滞后不是"这个频道没了"的证据',
      );

      // ② 服务端收录了一次 → 保护撤销（行仍在）
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
        const ChannelDto(channelId: 77, name: '刚建的'),
      ], removeMissing: true);
      expect((await store.allChannels()).map((c) => c.channelId), contains(77));

      // ③ 之后服务端又不再返回它 → 这次必须剪掉（证明剪枝功能仍在）
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'A'),
      ], removeMissing: true);
      expect(
        (await store.allChannels()).map((c) => c.channelId),
        isNot(contains(77)),
        reason: '已被服务端确认过的频道再消失，就该清掉',
      );
    });
  });

  // ★★ r326（D23）：`confirmPendingPost` 与"列表刷新"的**竞态**。
  //
  // 背景（真机/走查实测，r326 run 4 的诊断串）：
  //   `[chat] 发消息失败 channel=1 tmp=1791541967418：
  //    SqliteException(2067) UNIQUE constraint failed: post_rows.dedupe_key`
  // 时序：`Post/create` 的服务端回执 与 进频道那次 `Post/list` 几乎同时到 ——
  // 列表刷新先按服务端键（`p:<post_id>`）把这条消息写进库，随后
  // `confirmPendingPost` 又把**待发行**（`t:<channel>:<tmp>`）原地 replace 成
  // 服务端键 ⇒ 撞上 `post_rows.dedupe_key` 的 UNIQUE 索引 ⇒ 抛异常 ⇒
  // `sendMessage()` 的 catch 走 `failPendingPost()` ⇒
  // **服务端明明已经收到，界面却显示 `Send failed · Retry`**。
  group('D23 发送确认遇上列表刷新，不许把"已发出"误判成失败', () {
    PostDto serverPost(int postId) => PostDto(
      postId: postId,
      channelId: 1,
      creatorId: 1,
      message: '你好',
      createAt: 1770000000000,
    );

    test('① 先刷新到服务端那条、再确认 ⇒ 不抛异常，且只剩一行', () async {
      final tmp = await store.insertPendingPost(
        channelId: 1,
        creatorId: 1,
        message: '你好',
        nowMillis: 1770000000000,
      );
      // 列表刷新抢先写入服务端那条（同一时刻的另一条异步路径）
      await store.upsertPosts([serverPost(42)]);
      // 这一句在修复前抛 SqliteException(2067)
      await store.confirmPendingPost(
        channelId: 1,
        tmpPostId: tmp,
        server: serverPost(42),
      );
      final rows = await store.postsForChannel(1);
      expect(rows, hasLength(1), reason: '不许留下"待发行 + 服务端行"两行');
      expect(rows.single.postId, 42);
      expect(rows.single.message, '你好');
    });

    test('② 常规时序（没有抢先刷新）⇒ 待发行被换成服务端那条', () async {
      final tmp = await store.insertPendingPost(
        channelId: 1,
        creatorId: 1,
        message: '常规',
        nowMillis: 1770000001000,
      );
      await store.confirmPendingPost(
        channelId: 1,
        tmpPostId: tmp,
        server: PostDto(
          postId: 7,
          channelId: 1,
          creatorId: 1,
          message: '常规',
          createAt: 1770000001000,
        ),
      );
      final rows = await store.postsForChannel(1);
      expect(rows, hasLength(1));
      expect(rows.single.postId, 7);
      expect(rows.single.tmpPostId, 0, reason: '已是服务端行，不该再带本地临时 id');
    });

    test('③ 确认时待发行已不在（被清理）⇒ 只补一条服务端行，不抛', () async {
      await store.confirmPendingPost(
        channelId: 1,
        tmpPostId: 999999,
        server: serverPost(51),
      );
      final rows = await store.postsForChannel(1);
      expect(rows, hasLength(1));
      expect(rows.single.postId, 51);
    });
  });

  // 第 327 轮真机实测（Android，真 NAS）：第 326 轮的 D24「换库 ⇒ 清缓存」
  // 把 **加密频道的密钥行**也一起清了 —— 频道 267 `flt-p7m-enc-278125`
  // 的 `channel_key_enc` 消失，而重新同步（`Channel/list` 带 `is_joined=true`）
  // **没有把它带回来**（自己建的频道服务端不给这段密文）。
  // 剪枝侧早就有这条保护（`_pruneChannelsMissingFrom` 保护 ④），
  // 但清理走的是另一条路 ⇒ 漏了。守卫如下。
  group('D25 换库清缓存不许丢掉加密频道的密钥（真机踩到的不可逆损失）', () {
    const keyBlob = 'Scd0Z8bIRmMm/jBLo0TPwxXq2UrW73PexWYWfrepN1VL0A4SS2QtNHhLG6mAuB9TG';

    test('① 带 channel_key_enc 的频道行与它的消息被留下，其余全清', () async {
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'general'),
        const ChannelDto(
          channelId: 267,
          name: 'flt-p7m-enc-278125',
          type: 'private',
          encrypted: true,
          channelKeyEnc: keyBlob,
        ),
      ]);
      await store.upsertPosts([
        const PostDto(postId: 11, channelId: 1, message: '普通频道的消息'),
        const PostDto(postId: 12, channelId: 267, message: '密文消息'),
      ]);
      await store.upsertUsers([
        UserDto.fromJson(const {'user_id': 14, 'username': 'demo_user'}),
      ]);

      await store.clearAllData();

      final channels = await store.allChannels();
      expect(
        channels.map((c) => c.channelId).toList(),
        [267],
        reason: '加密频道必须活下来（服务端不会把这段密钥给回来）',
      );
      expect(channels.single.channelKeyEnc, keyBlob, reason: '密钥必须逐字不变');
      expect(
        (await store.postsForChannel(267)).map((p) => p.postId).toList(),
        [12],
        reason: '它的消息也不该被清（同一个频道一起放过）',
      );
      expect(await store.postsForChannel(1), isEmpty, reason: '普通频道照清');
      expect(await store.allUsers(), isEmpty, reason: '用户行照清');
    });

    test('② 没有加密频道时全清（保护不留残渣）', () async {
      await store.upsertChannels([
        const ChannelDto(channelId: 1, name: 'general'),
        const ChannelDto(channelId: 2, name: 'other'),
      ]);
      await store.upsertPosts([
        const PostDto(postId: 21, channelId: 1, message: 'a'),
        const PostDto(postId: 22, channelId: 2, message: 'b'),
      ]);

      await store.clearAllData();

      expect(await store.allChannels(), isEmpty);
      expect(await store.postsForChannel(1), isEmpty);
      expect(await store.postsForChannel(2), isEmpty);
    });

    test('③ 空库上清理不炸（keep 为空也不许生成非法 SQL）', () async {
      await store.clearAllData();
      expect(await store.allChannels(), isEmpty);
    });
  });
}
