// 登录链对齐 2.11.1：`SYNO.Chat.User/login`（v1）。
//
// 原版 `LoginPresenter` 的顺序是：
//   `Auth/login` → **`SYNO.Chat.User/login`** → 用户/频道列表 → socket
// 这一步给三样东西：校时（current_time）、`db_uuid`、`is_admin`/`user_id`。
// 我们之前直接跳到 `SYNO.Chat.User/get`，既没有校时也不知道自己是不是管理员。
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'support/chat_harness.dart';

int _v(Map<String, dynamic> call) => int.parse('${call['version']}');

Map<String, dynamic> _lastOf(FakeTransport t, String apiDotMethod) =>
    t.calls.lastWhere(
      (c) => '${c['api']}.${c['method']}' == apiDotMethod,
      orElse: () => const {},
    );

void main() {
  group('SYNO.Chat.User/login', () {
    test('发 v1，并且解析 current_time / db_uuid / is_admin', () async {
      final t = FakeTransport({
        'SYNO.Chat.User.login': {
          'current_time': 1700000000000,
          'db_uuid': 'uuid-A',
          'first_time': false,
          'user': {'user_id': 14, 'is_admin': true},
        },
      });
      final api = ChatApi(await _bootApi(t));
      final res = await api.userLogin();

      final call = _lastOf(t, 'SYNO.Chat.User.login');
      expect(_v(call), 1, reason: '原版 `getUserLogin(..., "login", 1)` 是 v1');
      expect(call['method'], 'login');

      expect(res.dbUuid, 'uuid-A');
      expect(res.userId, 14);
      expect(res.isAdmin, isTrue);
      expect(res.currentTime, 1700000000000);
      // 校时：skew = 服务端时间 - 本机时间（可正可负，只断言量级关系）
      expect(res.skewMillis(), isNot(0));
    });

    test('解析 `SYNO.Chat.User/login` 时缺 user 段也不炸', () async {
      final t = FakeTransport({
        'SYNO.Chat.User.login': {'current_time': 1, 'db_uuid': 'u'},
      });
      final api = ChatApi(await _bootApi(t));
      final res = await api.userLogin();
      expect(res.userId, 0);
      expect(res.isAdmin, isFalse);
    });
  });

  group('登录链落进 ChatSyncState', () {
    test('myUserId / isAdmin / clockSkew / dbUuid 都来自 User/login', () async {
      // 服务端时间故意偏 60s（不是 5s）：这台机器上"造 boot + 登录链"本身就可能
      // 花掉 2s 以上，5s 的余量在跑全量（大量测试并行）时会偶发只剩 2.6s → 变红。
      // 断言的是"偏移被算出来且方向对"，余量给足才不 flaky。
      final serverTime = DateTime.now().millisecondsSinceEpoch + 60000;
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.login': {
            'current_time': serverTime,
            'db_uuid': 'uuid-A',
            'user': {'user_id': 99, 'is_admin': true},
          },
        },
      );
      final st = h.container.read(chatSessionControllerProvider);
      expect(st.myUserId, 99, reason: 'login 的 user_id 优先于 User/get');
      expect(st.isAdmin, isTrue);
      expect(st.dbUuid, 'uuid-A');
      expect(st.clockSkewMillis, greaterThan(30000));
    });

    test('db_uuid 变了（服务端换库）→ 清掉本地缓存', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.login': {
            'current_time': DateTime.now().millisecondsSinceEpoch,
            'db_uuid': 'uuid-A',
            'user': {'user_id': 14},
          },
        },
      );
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        const PostDto(postId: 1, channelId: 5, message: 'x', createAt: 1),
      ]);
      await store.upsertChannels([
        ChannelDto.fromJson({'channel_id': 5, 'type': 'public'}),
      ]);
      expect(await store.postsForChannel(5), isNotEmpty);

      // 服务端换了库
      h.transport.responses['SYNO.Chat.User.login'] = {
        'current_time': DateTime.now().millisecondsSinceEpoch,
        'db_uuid': 'uuid-B',
        'user': {'user_id': 14},
      };
      await h.ctrl.refresh();

      expect(
        await store.postsForChannel(5),
        isEmpty,
        reason: 'db_uuid 不一致时本地消息缓存必须作废',
      );
      expect(h.container.read(chatSessionControllerProvider).dbUuid, 'uuid-B');
    });

    // ★★ r326（D24）：上面那条只覆盖**同进程内**换库（旧 `state.dbUuid` 在
    // 这个进程里已经非空）。真正的场景是 **App 冷启动** —— 进程刚起来
    // `state.dbUuid` 必然是空串，旧代码那个 `state.dbUuid.isNotEmpty` 判据
    // 恒假 ⇒ "服务端换库 ⇒ 本地缓存作废"**跨启动永远不会触发**
    // （§2.0.45 的"前提不可达"family；走查实测：Mock 重启后屏上还是上一轮的
    // 旧频道/旧消息）。修法：`db_uuid` 落**本地键值表**（`clearAllData()` 不动
    // 键值表），冷启动也有得比。
    test('★★ D24：冷启动（新进程、同一本地库）也要认出换库并作废缓存', () async {
      // 两台"进程"共用同一个本地库 = 同一台设备上的 App 重启
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      const dbUuidA = 'cold-uuid-A';
      const dbUuidB = 'cold-uuid-B';

      Map<String, dynamic> login(String uuid) => {
        'current_time': DateTime.now().millisecondsSinceEpoch,
        'db_uuid': uuid,
        'user': {'user_id': 14},
      };

      // ---- 进程 1：登录一次，留下"上辈子"的本地消息 ----
      final h1 = await bootChat(
        extra: {'SYNO.Chat.User.login': login(dbUuidA)},
        database: db,
      );
      final store1 = h1.container.read(chatStoreProvider);
      await store1.upsertPosts([
        const PostDto(postId: 900, channelId: 5, message: '上辈子遗留', createAt: 1),
      ]);
      final probe = ChatStore(db);
      expect(
        await probe.postsForChannel(5),
        isNotEmpty,
        reason: '自证：两个"进程"确实共用一个本地库（否则下面那条是假绿）',
      );
      // （"落没落键值表"这条断言放到**行为断言之后** —— 反向验证时要先看到
      //   "冷启动没清缓存"这个行为差异，而不是先看到"没写键"，见下方注释。）

      // ---- 进程 2：App 冷启动；服务端已经换库 ----
      // 注意：这里**不许**依赖同一个 ProviderContainer —— 新容器 = 新进程，
      // `state.dbUuid` 从空串开始，只能靠本地键值表认出换库。
      final h2 = await bootChat(
        extra: {'SYNO.Chat.User.login': login(dbUuidB)},
        database: db,
      );
      expect(h2.container.read(chatSessionControllerProvider).dbUuid, dbUuidB);
      expect(
        await probe.postsForChannel(5),
        isEmpty,
        reason: '冷启动也必须认出换库并把旧缓存作废（旧代码这里会留下旧消息）',
      );
      // ★ 机制量：服务端下发的 db_uuid 必须**落本地键值表**（下一次冷启动的判据）
      expect(
        await probe.setting('chat_server_db_uuid'),
        dbUuidB,
        reason: '登录后要把服务端 db_uuid 落到本地键值表',
      );
    });
  });
}

/// 起一个只装了假传输的 DsmWebApi（不走 ChatSessionController）
Future<DsmWebApi> _bootApi(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}
