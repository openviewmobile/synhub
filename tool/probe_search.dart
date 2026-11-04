// Phase 6 探针：`SYNO.Chat.Post/search` 到底怎么用（参数怎么编码、返回什么形状、
// 各个过滤器是否有效）。跑完自清理。
//
// 反编译依据 `AccountManager.search(from, in, after, before, keyword, hashtag,
// mention, has, file_type, offset, limit, sort_by, sort_by_array)`：
//   * 版本候选 [5,3,2]；
//   * **所有值都要再 JSON 序列化一次**（Gson.toJson）；
//   * v>=3 时 `has` 里的 `file`/`vote` 要挪到 `post_type`。
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
  final dir = Directory.systemTemp.createTempSync('p6');

  Future<void> pause() => Future<void>.delayed(const Duration(seconds: 3));

  try {
    final tag = 'fltp6$ts';
    final base = 'flt-p6-$ts';
    Future<int> post(
      String message, {
      int? threadId,
      bool isThread = false,
    }) async {
      final raw = await chat.createPost(
        channelId: 1,
        connId: sess.sid,
        message: message,
        threadId: threadId,
        isThread: isThread,
      );
      final id = (raw['post_id'] as num).toInt();
      created.add(id);
      print(
        '  创建 $id ← ${message.length > 40 ? message.substring(0, 40) : message}',
      );
      await pause();
      return id;
    }

    print('== 造数据 ==');
    final urlId = await post('$base-url https://example.com/p6-$ts');
    await post('$base-tag #$tag');
    final plainId = await post('$base-plain 普通消息');
    await chat.starPost(plainId);
    print('  $plainId 已星标');
    await post('$base-reply 这是回复', threadId: urlId, isThread: true);
    final png = File('${dir.path}/$base.png');
    png.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAABH0lEQVR4nO3PkaKDAAAF0GAQBIMg'
        'CIJBMAiCQRAMgiAIgsEgCIJBMAgGQTAYBEEQBMEgCILBIAiCIAiCIBgEQRAE7xPeD9zzB4cgCGK3'
        '25EkSVHUfr+naZphGJZlOY47HA48zx+PR0EQRFE8nU6SJMmyfD6fFUVRVVXTNF3XDcO4XC7X69U0'
        'TcuybNu+3W6O49zvd9d1H4/H53m+7z+fz9frFQRBGIZRFMVxnCRJmqbv9zvLsjzPi6L4fD7f77cs'
        'y6qq6rpumqZt267r+r4fhmEcx9/vN03TPM/Lsqzrum0bgQACCCCAAAIIIIAAAggggAACCCCAAAII'
        'IIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAgj8F/gDmnuhWk7edLMAAAAASUVORK5C'
        'YII=',
      ),
    );
    final up = await chat.uploadPost(
      channelId: 1,
      connId: sess.sid,
      filePath: png.path,
      fileName: '$base.png',
    );
    created.add((up['post_id'] as num).toInt());
    print('  上传 ${up['post_id']}');
    await pause();

    print('\n== search 各种参数 ==');
    Future<void> run(String label, Map<String, String> params) async {
      try {
        final r = await api.call(
          'SYNO.Chat.Post',
          'search',
          preferredVersion: 5,
          params: {...params, 'limit': '50', 'offset': '0'},
        );
        final posts = r['search_results'];
        final ids = posts is List
            ? posts
                  .map((p) => (p as Map)['post_id'])
                  .where((id) => created.contains(id))
                  .toList()
            : const [];
        print(
          '$label → keys=${r.keys.toList()} '
          'total=${r['total']} 本页=${posts is List ? posts.length : '?'} 命中我的=${ids.length} $ids',
        );
      } catch (e) {
        print('$label → ERR $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    String j(Object v) => jsonEncode(v);

    await run('无参数（只 limit/offset）', const {});
    await run('keyword=JSON 编码', {'keyword': j('flt-p6-$ts')});
    await run('keyword=裸文本', {'keyword': 'flt-p6-$ts'});
    await run('has=[url]', {
      'has': j(['url']),
    });
    await run('has=[star]', {
      'has': j(['star']),
    });
    await run('has=[thread]', {
      'has': j(['thread']),
    });
    await run('has=[file] (v5 应该无效)', {
      'has': j(['file']),
    });
    await run('post_type=[file]', {
      'post_type': j(['file']),
    });
    await run('hashtag=[$tag]', {
      'hashtag': j([tag]),
    });
    await run('from=[14]', {
      'from': j([14]),
    });
    await run('in=[1]', {
      'in': j([1]),
    });
    await run('file_type=[png]', {
      'file_type': j(['png']),
    });
    await run('after=现在-60s', {
      'after': j(DateTime.now().millisecondsSinceEpoch - 60000),
    });
    await run('before=现在-60s', {
      'before': j(DateTime.now().millisecondsSinceEpoch - 60000),
    });
    await run('sort_by=ASC', {'sort_by': j('ASC')});
    await run('sort_by_array=[create_at]', {
      'sort_by_array': j(['create_at']),
    });
    await run('in=[1]+keyword', {
      'in': j([1]),
      'keyword': j('flt-p6-$ts'),
    });

    // 详情：确认返回字段够不够渲染（mentions/hashtags/url_props/reactions）
    final r = await api.call(
      'SYNO.Chat.Post',
      'search',
      preferredVersion: 5,
      params: {'keyword': j('flt-p6-$ts'), 'limit': '50', 'offset': '0'},
    );
    final posts = (r['search_results'] as List?) ?? const [];
    if (posts.isNotEmpty) {
      print('\n单条字段: ${(posts.first as Map).keys.join(',')}');
      final withUrl = posts.cast<Map>().firstWhere(
        (p) => (p['url_props'] as List?)?.isNotEmpty == true,
        orElse: () => const {},
      );
      print(
        'url_props 例子: ${withUrl.isEmpty ? '-' : jsonEncode(withUrl['url_props'])}',
      );
      final withTag = posts.cast<Map>().firstWhere(
        (p) => (p['hashtags'] as List?)?.isNotEmpty == true,
        orElse: () => const {},
      );
      print(
        'hashtags 例子: ${withTag.isEmpty ? '-' : jsonEncode(withTag['hashtags'])}',
      );
    }

    // 错值
    await run('has=[不存在的过滤]', {
      'has': j(['nope']),
    });
    await run('offset 非数字', {'offset': 'abc'});
  } finally {
    for (final id in created) {
      try {
        await chat.deletePost(id);
      } catch (_) {}
    }
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    print('\n已清理 ${created.length} 条');
  }
}
