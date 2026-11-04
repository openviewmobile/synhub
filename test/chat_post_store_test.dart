// 消息落库的离线验证：真实 fixture 解析 + upsert 去重 + 乐观发送对账。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';

ChatStore _store() => ChatStore(ChatDatabase(NativeDatabase.memory()));

void main() {
  group('PostDto 解析（用真实 fixture）', () {
    late List<Map<String, dynamic>> posts;

    setUpAll(() {
      final raw = File('test/fixtures/post_list.json').readAsStringSync();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      posts = (data['posts'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    });

    test('真实系统消息（channel.join）解析正确', () {
      final p = PostDto.fromJson(
        posts.firstWhere((e) => e['type'] == 'system'),
      );
      expect(p.postId, 4294967297);
      expect(p.channelId, 1);
      expect(p.creatorId, 1);
      expect(p.isSystem, isTrue);
      expect(p.isDeleted, isFalse);
      expect(p.encrypted, isFalse);
      expect(p.systemEvent, 'channel.join');
      expect((p.systemProps!['target_user_ids'] as List).cast<int>(), [
        4,
        6,
        14,
      ]);
      expect(p.message, '');
      expect(p.createAt, 1612400211640);
    });

    test('缺字段不会炸（带 has 才有 reactions/file_props）', () {
      final p = PostDto.fromJson({'post_id': 7, 'channel_id': 2});
      expect(p.postId, 7);
      expect(p.channelId, 2);
      expect(p.type, 'normal');
      expect(p.hashtags, isEmpty);
      expect(p.reactions, isEmpty);
      expect(p.fileProps, isNull);
      expect(p.forwardType, 'none');
      expect(p.sortKey, greaterThan(0));
    });

    test('mentions 两种形状都认', () {
      final a = PostDto.fromJson({
        'post_id': 1,
        'channel_id': 1,
        'mentions': [
          {'user_id': 3, 'type': 'user'},
          {'user_id': 5},
        ],
      });
      final b = PostDto.fromJson({
        'post_id': 2,
        'channel_id': 1,
        'mentions': [3, 5],
      });
      expect(a.mentions, [3, 5]);
      expect(b.mentions, [3, 5]);
    });

    test('thread_id == post_id 不算线程回复', () {
      final p = PostDto.fromJson({
        'post_id': 9,
        'channel_id': 1,
        'thread_id': 9,
      });
      expect(p.isThreadReply, isFalse);
      final q = PostDto.fromJson({
        'post_id': 9,
        'channel_id': 1,
        'thread_id': 5,
      });
      expect(q.isThreadReply, isTrue);
    });
  });

  group('消息落库', () {
    test('upsert 同一条不产生重复行（按 channel+post_id 去重）', () async {
      final store = _store();
      const p = PostDto(postId: 100, channelId: 1, message: 'hi', createAt: 10);
      await store.upsertPosts([p]);
      await store.upsertPosts([p.copyWith(message: 'hi2')]);

      final all = await store.postsForChannel(1);
      expect(all.length, 1);
      expect(all.single.message, 'hi2');
    });

    test('新消息在前；beforeSortKey 向上翻页只取更早的', () async {
      final store = _store();
      await store.upsertPosts([
        for (var i = 1; i <= 5; i++)
          PostDto(
            postId: 100 + i,
            channelId: 1,
            message: 'm$i',
            createAt: i * 100,
          ),
      ]);

      final page1 = await store.postsForChannel(1, limit: 2);
      expect(page1.map((p) => p.message), ['m5', 'm4']);

      final page2 = await store.postsForChannel(
        1,
        limit: 2,
        beforeSortKey: page1.last.sortKey,
      );
      expect(page2.map((p) => p.message), ['m3', 'm2']);
    });

    test('不同频道互不干扰', () async {
      final store = _store();
      await store.upsertPosts([
        const PostDto(postId: 1, channelId: 1, message: 'a'),
        const PostDto(postId: 2, channelId: 2, message: 'b'),
      ]);
      expect((await store.postsForChannel(1)).single.message, 'a');
      expect((await store.postsForChannel(2)).single.message, 'b');
    });

    test('乐观发送：插入待发 → 确认替换（不产生两行）', () async {
      final store = _store();
      final tmp = await store.insertPendingPost(
        channelId: 1,
        creatorId: 14,
        message: '草稿',
        nowMillis: 500,
      );

      var posts = await store.postsForChannel(1);
      expect(posts.single.state, 1, reason: '发送中');
      expect(posts.single.postId, 0);

      await store.confirmPendingPost(
        channelId: 1,
        tmpPostId: tmp,
        server: const PostDto(
          postId: 4294967400,
          channelId: 1,
          creatorId: 14,
          message: '草稿',
          createAt: 501,
        ),
      );

      posts = await store.postsForChannel(1);
      expect(posts.length, 1, reason: '不能出现本地行 + 服务端行两条');
      expect(posts.single.postId, 4294967400);
      expect(posts.single.state, 0);
    });

    test('乐观发送失败：标记 state=2 且保留', () async {
      final store = _store();
      final tmp = await store.insertPendingPost(
        channelId: 1,
        creatorId: 14,
        message: '发不出去',
        nowMillis: 600,
      );
      await store.failPendingPost(1, tmp);

      final posts = await store.postsForChannel(1);
      expect(posts.single.state, 2);
      expect(posts.single.message, '发不出去');
    });

    test('deletePost 只删指定频道的那条', () async {
      final store = _store();
      await store.upsertPosts([
        const PostDto(postId: 1, channelId: 1, message: 'a'),
        const PostDto(postId: 2, channelId: 1, message: 'b'),
      ]);
      await store.deletePost(1, 1);
      final left = await store.postsForChannel(1);
      expect(left.single.postId, 2);
    });

    test('watchPosts 会随写入自动推新（流式）', () async {
      final store = _store();
      final emissions = <List<PostDto>>[];
      final sub = store.watchPosts(1).listen(emissions.add);

      await store.upsertPosts([
        const PostDto(postId: 1, channelId: 1, message: 'x', createAt: 1),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(emissions, isNotEmpty);
      expect(emissions.last.single.message, 'x');
    });

    test('嵌套结构原样往返（reactions/url_props/system_props）', () async {
      final store = _store();
      await store.upsertPosts([
        PostDto(
          postId: 1,
          channelId: 1,
          message: 'hi',
          reactions: const [
            {
              'sticker_name': 'smile',
              'user_ids': [1, 2],
            },
          ],
          urlProps: const [
            {'url': 'https://x', 'title': 't'},
          ],
          systemProps: const {'event': 'channel.join'},
          hashtags: const ['a', 'b'],
        ),
      ]);
      final p = (await store.postsForChannel(1)).single;
      expect(p.reactions.single['sticker_name'], 'smile');
      expect(p.urlProps.single['url'], 'https://x');
      expect(p.systemProps!['event'], 'channel.join');
      expect(p.hashtags, ['a', 'b']);
    });
  });
}
