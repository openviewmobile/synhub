// ★★ **`@channel` / `@here` 的「服务端成功回包」端到端验证**
// —— ②聊天 审计行 **106**（规则 B2）。
//
// ## 这轮真的抓到一个 bug（不是"补测试"，是**证明代码错了**）
//
// 审计行 106 原判「`@channel`/`@here` 已实现·未验证 · 无真机/真服务端回包」。
// 按 B2 拿 Mock 造出**服务端成功回包**之后，暴露出一个**确定性错位**：
//
// ```
//   服务端:  {"message": "@channel @bob 上线了", "mentions": [{"user_id": -2}, {"user_id": 3}]}
//   我方:    PostDto._mentionIds 里 `.where((e) => e > 0)`   ← ★ 把伪用户 -2 丢掉了
//            ⇒ mentions 变成 [3]
//   渲染:    rich_text.parseMessage 按**下标**配对（`mentions[mentionIndex]`）
//            ⇒ 文本里第 1 个 @ 是 `@channel`，被配上 mentions[0] = 3 ⇒ **高亮成了 bob**
//            ⇒ 第 2 个 @ 是 `@bob`，mentions 只有 1 个 ⇒ **不高亮**
// ```
//
// 两个都错，而且**方向相反**。`usernames`（按 `@名字` 查表那条路）也救不了：
// 它只由**真实用户**构造（`chat_page.dart:1268-1273`），里面没有 `channel`/`here`。
//
// ## 官方语义（伪用户 id）
// * `@channel` → **-2**，`@here` → **-1**：`autocomplete.dart:143-144` 与原版
//   `ChatUtil.atMention` 一致（APK 里 `at_channel`/`AT_CHANNEL`/`at_here`/`AT_HERE`
//   四个字符串本轮 `grep` 确认存在）。
// * ⇒ 它们在 `PostVo.mentions` 里是**合法成员**，**过滤掉它们就是错的**。
//
// ## 不做什么
// 不碰真机、不碰真 NAS（§5.1）。全部离线 + Mock 回包。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/autocomplete.dart';
import 'package:synhub/src/features/chat/rich_text.dart';

/// 服务端成功回包里的 `mentions`：可能是 `{"user_id": n}`，也可能直接是数字。
List<Object> _wireMentions(List<int> ids) => [
  for (final i in ids) {'user_id': i},
];

void main() {
  group('AT-1. DTO 解析：伪用户 **必须保留**（这是 bug 的根）', () {
    test('★ `mentions` 里的 -2 / -1 不能被 `> 0` 过滤掉', () {
      final post = PostDto.fromJson({
        'post_id': 1,
        'channel_id': 5,
        'message': '@channel @bob 上线了',
        'mentions': _wireMentions([-2, 3]),
      });
      expect(post.mentions, [
        -2,
        3,
      ], reason: '★ 原实现 `.where((e) => e > 0)` 把 -2 丢了 ⇒ 与文本里的 @ 错位');
    });

    test('`@here` 的 -1 同样要保留', () {
      final post = PostDto.fromJson({
        'post_id': 2,
        'channel_id': 5,
        'message': '@here 注意',
        'mentions': _wireMentions([-1]),
      });
      expect(post.mentions, [-1]);
    });

    test('★ 非法值（缺 user_id / 非数字）仍然要被丢掉 —— 0 不是合法 id', () {
      final post = PostDto.fromJson({
        'post_id': 3,
        'channel_id': 5,
        'message': 'x',
        'mentions': [
          {'user_id': 'abc'}, // 解析成 0
          <String, dynamic>{}, // 缺字段 → 0
          {'user_id': 7},
        ],
      });
      expect(post.mentions, [7], reason: '0 表示"没解析出来"，该丢');
    });

    test('数字形态（不是 map）也认', () {
      final post = PostDto.fromJson({
        'post_id': 4,
        'channel_id': 5,
        'message': 'x',
        'mentions': [-2, 9],
      });
      expect(post.mentions, [-2, 9]);
    });
  });

  group('AT-2. ★ 渲染：`@channel` 不再被错配成后面那个人', () {
    test('★ 文本 `@channel @bob` + mentions [-2,3] ⇒ 各配各的', () {
      final segs = parseMessage(
        '@channel @bob 上线了',
        mentions: const [-2, 3],
        usernames: const {'bob': 3},
        mentionNames: const {-2: 'channel', 3: 'bob'},
      );
      final mentions = segs.whereType<MentionSegment>().toList();
      expect(mentions, hasLength(2));
      expect(mentions[0].text, '@channel');
      expect(
        mentions[0].userId,
        -2,
        reason: '★ `@channel` 必须配 -2（原来错配成 3 = bob）',
      );
      expect(mentions[1].text, '@bob');
      expect(mentions[1].userId, 3);
    });

    test('★ 修复前的错误结果长什么样（把 DTO 的过滤效果还原出来做对照）', () {
      // 这就是旧行为：mentions 只剩 [3]
      final segs = parseMessage(
        '@channel @bob 上线了',
        mentions: const [3],
        usernames: const {'bob': 3},
        mentionNames: const {-2: 'channel', 3: 'bob'},
      );
      final mentions = segs.whereType<MentionSegment>().toList();
      expect(mentions[0].text, '@channel');
      expect(
        mentions[0].userId,
        3,
        reason: '旧行为：@channel 被配成 bob ⇒ 所以必须去掉那个过滤',
      );
      expect(mentions[0].userId, isNot(-2));
    });

    test('★ `@here` 同理', () {
      final segs = parseMessage(
        '@here @bob 注意',
        mentions: const [-1, 3],
        usernames: const {'bob': 3},
        mentionNames: const {-1: 'here', 3: 'bob'},
      );
      final ms = segs.whereType<MentionSegment>().toList();
      expect(ms[0].userId, -1);
      expect(ms[1].userId, 3);
    });

    test('`usernames` 命中时优先按名字配（原库也是这个优先级）', () {
      final segs = parseMessage(
        '@bob @channel',
        mentions: const [3, -2],
        usernames: const {'bob': 3},
        mentionNames: const {-2: 'channel'},
      );
      final ms = segs.whereType<MentionSegment>().toList();
      expect(ms[0].userId, 3, reason: '名字查得到就用查到的');
      expect(ms[1].userId, -2);
    });

    test('只有 `@channel` 时也准', () {
      final segs = parseMessage(
        '@channel 全体注意',
        mentions: const [-2],
        usernames: const {},
        mentionNames: const {-2: 'channel'},
      );
      final ms = segs.whereType<MentionSegment>().toList();
      expect(ms.single.userId, -2);
      expect(ms.single.text, '@channel');
    });
  });

  group('AT-3. DTO 与渲染**串起来**（模拟服务端回包 → 界面片段）', () {
    test('★ 服务端回包 → PostDto → parseMessage，两步都对', () {
      // 服务端成功回包（`Post/create` 或 `Post/list` 里的那条 ）
      final post = PostDto.fromJson({
        'post_id': 42,
        'channel_id': 5,
        'message': '@channel 大家看下 @bob',
        'mentions': _wireMentions([-2, 3]),
      });

      final segs = parseMessage(
        post.message,
        mentions: post.mentions,
        usernames: const {'bob': 3},
        mentionNames: mentionNamesById(const []),
      );
      final ms = segs.whereType<MentionSegment>().toList();
      expect(ms, hasLength(2));
      expect(ms[0].text, '@channel');
      expect(ms[0].userId, -2);
      expect(ms[1].text, '@bob');
      expect(ms[1].userId, 3);
    });
  });

  group('AT-4. 候选侧（既有能力，防回归）', () {
    test('`@channel`/`@here` 的伪 id 就是 -2 / -1', () {
      // 与 `autocomplete.dart:143-144` 逐字一致
      expect(const MentionTarget(userId: -2, username: 'channel').userId, -2);
      expect(const MentionTarget(userId: -1, username: 'here').userId, -1);
    });
  });
}
