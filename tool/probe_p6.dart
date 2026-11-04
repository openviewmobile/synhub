// Phase 6 探针：投票 / 提醒 / 定时消息 的真实请求与响应形状。跑完自清理。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      const String.fromEnvironment('SYNO_NAS_URL'),
      dio: DioFactory.create(),
    ),
  );
  await api.discover();
  final sess = await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  final chat = ChatApi(api);
  final ts = DateTime.now().millisecondsSinceEpoch;
  final created = <int>[];
  final cronjobs = <int>[];

  String j(Object v) => jsonEncode(v);
  Future<void> pause() => Future<void>.delayed(const Duration(seconds: 3));

  Future<void> tryCall(
    String label,
    String apiName,
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      final r = await api.call(
        apiName,
        method,
        preferredVersion: 1,
        params: params,
      );
      print(
        '$label → ${jsonEncode(r).length > 700 ? '${jsonEncode(r).substring(0, 700)}…' : jsonEncode(r)}',
      );
    } catch (e) {
      print('$label → ERR $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  try {
    print('== 投票 ==');
    final votePost = await chat.createPost(
      channelId: 1,
      connId: sess.sid,
      message: 'flt-p6-$ts-vote 午饭吃什么？',
    );
    created.add((votePost['post_id'] as num).toInt());
    print('先建普通消息 ${votePost['post_id']}（投票要另建）');

    // Vote/create：message/choices/options 都是 JSON 编码
    final voteChoices = <Map<String, dynamic>>[
      {'text': '面条'},
      {'text': '米饭'},
      {'text': '随便'},
    ];
    Map<String, dynamic>? voteRaw;
    await Future<void>.delayed(const Duration(seconds: 5));
    await tryCall('Vote/create', 'SYNO.Chat.Post.Vote', 'create', {
      'channel_id': '1',
      'message': j('flt-p6-$ts-vote 午饭吃什么？'),
      'choices': j(voteChoices),
      'options': j({
        'anonymous': false,
        'multiple': false,
        'add_option': false,
        'expire_at': 0,
      }),
    });
    // 上面只打印；再建一次并留 ID
    try {
      final r = await api.call(
        'SYNO.Chat.Post.Vote',
        'create',
        preferredVersion: 1,
        params: {
          'channel_id': '1',
          'message': j('flt-p6-$ts-vote2 晚饭吃什么？'),
          'choices': j(voteChoices),
          'options': j({
            'anonymous': false,
            'multiple': true,
            'add_option': true,
            'expire_at': 0,
          }),
        },
      );
      voteRaw = r;
      created.add((r['post_id'] as num).toInt());
      print('投票消息 post_id=${r['post_id']}');
      print('  单条字段: ${r.keys.join(',')}');
      print('  vote=${jsonEncode(r['vote'])}');
    } catch (e) {
      print('Vote/create 第二次失败: $e');
    }
    await pause();

    final voteId = voteRaw == null ? 0 : (voteRaw['post_id'] as num).toInt();
    if (voteId > 0) {
      await tryCall('Vote/get_choices', 'SYNO.Chat.Post.Vote', 'get_choices', {
        'post_id': '$voteId',
      });
      // 拿 choice id 再投票
      try {
        final ch = await api.call(
          'SYNO.Chat.Post.Vote',
          'get_choices',
          preferredVersion: 1,
          params: {'post_id': '$voteId'},
        );
        final choices = (ch['choices'] as List?) ?? const [];
        print('choices=${jsonEncode(choices)}');
        if (choices.isNotEmpty) {
          final ids = choices
              .take(2)
              .map((c) => (c as Map)['choice_id'])
              .toList();
          await tryCall('Vote/vote', 'SYNO.Chat.Post.Vote', 'vote', {
            'post_id': '$voteId',
            'choice_ids': j(ids),
          });
          await tryCall(
            'Vote/get_choices(投完)',
            'SYNO.Chat.Post.Vote',
            'get_choices',
            {'post_id': '$voteId'},
          );
        }
      } catch (e) {
        print('get_choices 失败: $e');
      }
      await tryCall('Vote/close', 'SYNO.Chat.Post.Vote', 'close', {
        'post_id': '$voteId',
      });
      await tryCall(
        'Vote/list? 用 Post/list 看 vote 字段',
        'SYNO.Chat.Post',
        'list',
        {'channel_id': '1', 'prev_count': '5', 'next_count': '0'},
      );
    }

    print('\n== 提醒 ==');
    final plain = await chat.createPost(
      channelId: 1,
      connId: sess.sid,
      message: 'flt-p6-$ts-remind 提醒我',
    );
    final plainId = (plain['post_id'] as num).toInt();
    created.add(plainId);
    await pause();
    final remindAt = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
    await tryCall('Reminder/set', 'SYNO.Chat.Post.Reminder', 'set', {
      'post_id': '$plainId',
      'remind_at': '$remindAt',
    });
    await tryCall('Reminder/get', 'SYNO.Chat.Post.Reminder', 'get', {
      'post_id': '$plainId',
    });
    await tryCall('Reminder/list', 'SYNO.Chat.Post.Reminder', 'list', {
      'channel_id': '1',
    });
    await tryCall('Reminder/delete', 'SYNO.Chat.Post.Reminder', 'delete', {
      'post_id': '$plainId',
    });

    print('\n== 定时消息 ==');
    final sendAt = DateTime.now().millisecondsSinceEpoch + 86400 * 1000;
    await tryCall('Schedule/create', 'SYNO.Chat.Post.Schedule', 'create', {
      'channel_id': '1',
      'message': j('flt-p6-$ts-sched 明天的消息'),
      'send_at': '$sendAt',
    });
    try {
      final r = await api.call(
        'SYNO.Chat.Post.Schedule',
        'create',
        preferredVersion: 1,
        params: {
          'channel_id': '1',
          'message': j('flt-p6-$ts-sched2 后天的消息'),
          'send_at': '$sendAt',
        },
      );
      final id = (r['cronjob_id'] as num?)?.toInt() ?? 0;
      if (id > 0) cronjobs.add(id);
      print('cronjob_id=$id keys=${r.keys.join(',')}');
    } catch (e) {
      print('Schedule/create 第二次失败: $e');
    }
    await tryCall('Schedule/list', 'SYNO.Chat.Post.Schedule', 'list', {
      'channel_id': '1',
    });
    for (final id in cronjobs) {
      await tryCall('Schedule/delete', 'SYNO.Chat.Post.Schedule', 'delete', {
        'cronjob_id': '$id',
      });
    }
  } finally {
    for (final id in created) {
      try {
        await chat.deletePost(id);
      } catch (_) {}
    }
    for (final id in cronjobs) {
      try {
        await api.call(
          'SYNO.Chat.Post.Schedule',
          'delete',
          preferredVersion: 1,
          params: {'cronjob_id': '$id'},
        );
      } catch (_) {}
    }
    print('\n已清理 post=${created.length} cronjob=${cronjobs.length}');
  }
}

// 让分析器闭嘴：File/IO 只是为了对齐其它探针的导入
// ignore: unused_element
final _keep = File;
