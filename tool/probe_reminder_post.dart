// 摸「提醒」在**消息流里**长什么样（Phase 6 只做了 API + 列表页，没做流内渲染）。
//
// 反编译事实：`Post.viewType()` 里
// ```java
// if (prop.forward() != null && "reminder".equals(prop.forward().type())) return 110;
// ```
// 110 = `ForwardHolder` + `item_post_forward`，由 `bindReminder()` 渲染成
// 「嗨！以下是您关于 { 此信息 } 的提醒。」（`system_remind_msg`），其中「此信息」
// 是跳到 `origin_post_id`/`origin_thread_id`/`origin_user_id`/`origin_channel_id`
// 的链接，标题行是**原消息作者**、时间用 `origin_create_at`。
//
// 我们这个探针只读：先看现有频道里有没有已经存在的提醒条目；没有就现建一个
// （`Post.Reminder/set`，60 秒后到期），等它到期后再看 `Post/list` / `Reminder/list`
// 里冒出来的那条 PostVo 的完整 JSON，再删掉它。
//
//   dart run -DSYNO_NAS_URL=… -DSYNO_NAS_ACCOUNT=… "-DSYNO_NAS_PASSWORD=…" \
//            tool/probe_reminder_post.dart
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

late DsmWebApi api;
late ChatApi chat;

void dumpPost(String label, Map<String, dynamic> p) {
  final props = p['props'];
  print(
    '  [$label] post_id=${p['post_id']} type=${p['type']} '
    'message=${jsonEncode(p['message'])}',
  );
  print('         props=${jsonEncode(props)}');
}

Future<void> main() async {
  api = DsmWebApi(
    DirectTransport.url(
      const String.fromEnvironment('SYNO_NAS_URL'),
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  chat = ChatApi(api);
  final me = await chat.myUser();
  print('我 = #${me?.userId}');

  final channels = await chat.listChannels();
  print('频道 ${channels.length} 个');

  // ① 先扫一遍：有没有已经存在的提醒条目
  for (final c in channels) {
    try {
      final r = await api.call(
        'SYNO.Chat.Post.Reminder',
        'list',
        preferredVersion: 1,
        params: {'channel_id': '${c.channelId}'},
      );
      final posts = (r['posts'] as List?) ?? const [];
      if (posts.isNotEmpty) {
        print('频道 #${c.channelId}「${c.name}」有 ${posts.length} 条提醒：');
        for (final p in posts) {
          dumpPost('已有', Map<String, dynamic>.from(p as Map));
        }
      }
    } catch (_) {}
  }

  // ② 没有就现造一个：挑 #1，拿**最新一条**消息当靶子
  final target = channels.firstWhere(
    (c) => c.channelId == 1,
    orElse: () => channels.first,
  );
  Future<List<Map<String, dynamic>>> newest(int n) async {
    final r = await api.call(
      'SYNO.Chat.Post',
      'list',
      preferredVersion: 8,
      params: {
        'channel_id': '${target.channelId}',
        'prev_count': '$n',
        'next_count': '0',
      },
    );
    return ((r['posts'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  final before = await newest(10);
  if (before.isEmpty) {
    print('频道 #${target.channelId} 里没有消息，没法测提醒');
    return;
  }
  final victim = before.last; // prev_count 是从最新往回，最后一条是这批里最旧的
  final victimId = (victim['post_id'] as num).toInt();
  final newestId = (before.first['post_id'] as num).toInt();
  print('\n最新 post_id=$newestId，靶子 post_id=$victimId');
  dumpPost('靶子', victim);

  final remindAt = DateTime.now().millisecondsSinceEpoch + 60 * 1000;
  print('设提醒 → $remindAt');
  await api.call(
    'SYNO.Chat.Post.Reminder',
    'set',
    preferredVersion: 1,
    params: {'post_id': '$victimId', 'remind_at': '$remindAt'},
  );
  final after = await api.call(
    'SYNO.Chat.Post.Reminder',
    'list',
    preferredVersion: 1,
    params: {'channel_id': '${target.channelId}'},
  );
  print('设完立刻看 Reminder/list：');
  for (final p in (after['posts'] as List?) ?? const []) {
    dumpPost('列表里', Map<String, dynamic>.from(p as Map));
  }

  print('\n等 75 秒让它到期…');
  await Future<void>.delayed(const Duration(seconds: 75));

  print('\n到期后最新的 10 条：');
  for (final p in await newest(10)) {
    final pid = (p['post_id'] as num).toInt();
    dumpPost(pid > newestId ? '新' : '旧', p);
  }
  final list3 = await api.call(
    'SYNO.Chat.Post.Reminder',
    'list',
    preferredVersion: 1,
    params: {'channel_id': '${target.channelId}'},
  );
  print('\n到期后的 Reminder/list：');
  for (final p in (list3['posts'] as List?) ?? const []) {
    dumpPost('reminder', Map<String, dynamic>.from(p as Map));
  }

  print('\n清理：删掉刚设的提醒');
  try {
    await api.call(
      'SYNO.Chat.Post.Reminder',
      'delete',
      preferredVersion: 1,
      params: {'post_id': '$victimId'},
    );
    print('  删除 ✓');
  } catch (e) {
    print('  删除失败：$e');
  }
}
