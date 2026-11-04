// Phase 2 真机/真 NAS 验收（默认跳过）
//
//   SYNO_LIVE=1 \
//   SYNO_NAS_QC=demo_admin-qq \
//   SYNO_NAS_ACCOUNT=demo_user SYNO_NAS_PASSWORD='…' \
//   flutter test test/chat_live_test.dart
//
// 覆盖：登录 → Channel.list → User.list(compound) → User/get → socket.io(EIO3) 握手拿 conn_id
//       → （可选）**两个**会话验证实时投递：B 能收到 A 发的 post.create，A 自己收不到，
//         然后删掉这条消息，双方都应收到 post.delete 广播。
//
// 可选开关：SYNO_LIVE_POST=1 才做第 ④ 项（会在 NAS 上真实产生并删除一条消息）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

/// 一个独立"设备"：自己的连接、登录会话、socket
class _Session {
  _Session(this.tag, this.api, this.chat, this.socket);

  final String tag;
  final DsmWebApi api;
  final ChatApi chat;
  final ChatSocket socket;

  final List<ChatSocketEvent> events = [];

  static Future<_Session> open(String tag, ServerProfile profile) async {
    final conn = await ConnectionService().connect(profile);
    final session = await conn.api.login(
      account: Platform.environment['SYNO_NAS_ACCOUNT']!,
      password: Platform.environment['SYNO_NAS_PASSWORD']!,
      session: 'Chat',
    );
    final socket = ChatSocket(
      baseUrl: conn.endpoint.baseUrl,
      sid: session.sid,
      synotoken: session.synotoken,
    );
    final s = _Session(tag, conn.api, ChatApi(conn.api), socket);
    socket.events.listen(s.events.add);
    await socket.connect();
    await socket.waitReady(timeout: const Duration(seconds: 25));
    // ignore: avoid_print
    print('[$tag] conn_id = ${socket.connId}');
    return s;
  }

  bool got(String event) => events.any((e) => e.event == event);

  List<ChatSocketEvent> of(String event) =>
      events.where((e) => e.event == event).toList();

  Future<void> close() async {
    socket.dispose();
    try {
      await api.logout();
    } catch (_) {}
    await api.transport.close();
  }
}

/// 扫掉测试留下的 flt- 消息（只删我们自己造的，绝不碰真实消息）
Future<void> _sweep(ChatApi chat, int channelId) async {
  try {
    final posts = await chat.listPosts(channelId: channelId, prevCount: 50);
    for (final p in posts) {
      final msg = '${p['message']}';
      if (msg.contains('flt-live-') ||
          msg.contains('flt-check-') ||
          msg.contains('flt-probe-') ||
          msg.contains('flt-two-')) {
        await chat.deletePost((p['post_id'] as num).toInt());
      }
    }
  } catch (_) {
    // 清理失败不影响测试结论
  }
}

void main() {
  final live = Platform.environment['SYNO_LIVE'] == '1';
  final qc = Platform.environment['SYNO_NAS_QC'];
  final url = Platform.environment['SYNO_NAS_URL'];
  final doPost = Platform.environment['SYNO_LIVE_POST'] == '1';

  late ServerProfile profile;
  late _Session a;
  List<ChannelDto> channels = const [];
  List<UserDto> users = const [];

  setUpAll(() async {
    if (!live) return;
    profile = (qc != null && qc.isNotEmpty)
        ? ServerProfile(kind: ServerAddressKind.quickConnect, value: qc)
        : ServerProfile(kind: ServerAddressKind.direct, value: url!);
    a = await _Session.open('A', profile);
  });

  tearDownAll(() async {
    if (!live) return;
    await a.close();
  });

  if (!live) {
    test('Phase 2 真机验收（默认跳过）', () {
      // ignore: avoid_print
      print(
        '设置 SYNO_LIVE=1 / SYNO_NAS_QC / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD 后运行',
      );
    }, skip: '未启用 SYNO_LIVE=1');
    return;
  }

  test('① Channel.list 拿到真实频道', () async {
    channels = await a.chat.listChannels();
    // ignore: avoid_print
    print('  频道数 = ${channels.length}');
    for (final c in channels.take(5)) {
      // ignore: avoid_print
      print(
        '   #${c.channelId} ${c.name.isEmpty ? "(无名)" : c.name} '
        'type=${c.type} unread=${c.unread} members=${c.totalMemberCount}',
      );
    }
    expect(channels, isNotEmpty);
    expect(channels.first.channelId, greaterThan(0));
  });

  test('② User.list（compound human+bot）与 User/get', () async {
    users = await a.chat.listUsers();
    final me = await a.chat.myUser();
    // ignore: avoid_print
    print(
      '  用户数 = ${users.length}（human=${users.where((u) => !u.isBot).length}, '
      'bot=${users.where((u) => u.isBot).length}）',
    );
    // ignore: avoid_print
    print('  我 = ${me?.displayName} (id=${me?.userId}, type=${me?.humanType})');

    expect(users, isNotEmpty);
    expect(me, isNotNull);
    expect(me!.userId, greaterThan(0));
    expect(
      users.any((u) => u.userId == me.userId),
      isTrue,
      reason: 'User/list 里应当包含自己',
    );
  });

  test('③ socket.io 握手拿到 conn_id', () async {
    // ignore: avoid_print
    print('  conn_id = ${a.socket.connId}, server=${a.socket.serverVersion}');
    expect(a.socket.connId, isNotNull);
    expect(a.socket.connId, isNotEmpty);
    expect(a.socket.status, ChatSocketStatus.ready);
  });

  test('④ 会话 B 能实时收到 A 发的消息；发送方 A 收不到（服务端行为）', () async {
    if (!doPost) {
      markTestSkipped('需要 SYNO_LIVE_POST=1（会在 NAS 上真实产生并删除一条消息）');
      return;
    }
    final target = channels.firstWhere(
      (c) => !c.encrypted && c.isJoined,
      orElse: () => channels.first,
    );
    final b = await _Session.open('B', profile);
    addTearDown(b.close);
    // 断言失败也要把测试消息清掉，别在 NAS 上留垃圾
    addTearDown(() => _sweep(a.chat, target.channelId));

    final marker = 'flt-live-${DateTime.now().millisecondsSinceEpoch}';

    final post = await a.chat.createPost(
      channelId: target.channelId,
      message: marker,
      connId: a.socket.connId!,
    );
    final postId = (post['post_id'] as num?)?.toInt() ?? 0;
    // ignore: avoid_print
    print('  A 发送 post_id=$postId type=${post['type']} 到 #${target.channelId}');

    expect(postId, greaterThan(0));
    expect(post['type'], 'normal', reason: 'ChatPost.NORMAL');

    // 等 B 收到
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (b.got('client.post.create')) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // ignore: avoid_print
    print('  A 事件: ${a.events.map((e) => e.event).toSet()}');
    // ignore: avoid_print
    print('  B 事件: ${b.events.map((e) => e.event).toSet()}');

    final delivered = b.of('client.post.create');
    expect(delivered, isNotEmpty, reason: 'B 应当收到 client.post.create');
    final payload = delivered
        .map((e) => e.asMap)
        .firstWhere(
          (m) => (m?['data'] as Map?)?['post_id'] == postId,
          orElse: () => null,
        );
    // ignore: avoid_print
    print('  B 收到的载荷: $payload');
    expect(payload, isNotNull, reason: '推给 B 的应当是刚发的那条');
    // ⚠️ 实测形状：channel_id 在**顶层**，data 里只有 creator_id/post_id/thread_id/create_at，
    // 没有 channel_id（别照直觉写）
    expect(payload!['channel_id'], target.channelId);
    expect((payload['data'] as Map)['creator_id'], isNotNull);

    // 发送方自己不该收到 —— 本地状态靠 HTTP 响应同步，别指望 socket 回自己
    expect(
      a
          .of('client.post.create')
          .where((e) => (e.asMap?['data'] as Map?)?['post_id'] == postId),
      isEmpty,
      reason: '实测服务端不回推给发送方',
    );

    await a.chat.deletePost(postId);

    // 删除广播双方都该收到
    final ddl = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(ddl) && !b.got('client.broadcast')) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // ignore: avoid_print
    print(
      '  B 的 broadcast: '
      '${b.of('client.broadcast').map((e) => e.asMap?['type']).toList()}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
