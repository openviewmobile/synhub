// 富文本解析（@提及 / #话题 / URL）的纯函数 + 渲染测试。
//
// 说明：APK 里**没有** emoji 短代码表（见 rich_text.dart 顶部注释），
// 所以这里只验证这三类内联元素。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/chat/rich_text.dart';

List<String> _kinds(String text, {List<int> mentions = const []}) =>
    parseMessage(
      text,
      mentions: mentions,
    ).map((s) => s.runtimeType.toString()).toList();

/// 递归摊平 RichText 里的所有 TextSpan
Iterable<TextSpan> _walk(WidgetTester tester) sync* {
  final richText = tester.widget<RichText>(find.byType(RichText));
  final stack = <TextSpan>[richText.text as TextSpan];
  while (stack.isNotEmpty) {
    final span = stack.removeLast();
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) stack.add(child);
    }
  }
}

void main() {
  group('parseMessage', () {
    test('纯文本 → 单个 Plain', () {
      expect(parseMessage('你好 NAS'), [const PlainSegment('你好 NAS')]);
    });

    test('空串 → 空列表', () {
      expect(parseMessage(''), isEmpty);
    });

    test('@提及 切出来，并按 mentions 顺序配 user_id', () {
      final segs = parseMessage('@amy 和 @bob 看下', mentions: [7, 9]);
      expect(segs, [
        const MentionSegment('@amy', 7),
        const PlainSegment(' 和 '),
        const MentionSegment('@bob', 9),
        const PlainSegment(' 看下'),
      ]);
    });

    test('提到的人名能反查 user_id 时优先用名字', () {
      final segs = parseMessage('@amy hi', usernames: {'amy': 42});
      expect(segs.first, const MentionSegment('@amy', 42));
    });

    test('mentions 数量不够时 user_id = 0（只高亮）', () {
      final segs = parseMessage('@ghost 在吗');
      expect(segs.first, const MentionSegment('@ghost', 0));
    });

    test('#话题 切出来并去掉井号', () {
      final segs = parseMessage('今天 #flutter 很棒');
      expect(segs, [
        const PlainSegment('今天 '),
        const HashtagSegment('#flutter', 'flutter'),
        const PlainSegment(' 很棒'),
      ]);
    });

    test('URL 整段切出来', () {
      final segs = parseMessage('见 https://example.com/a?b=1 谢谢');
      expect(segs, [
        const PlainSegment('见 '),
        const UrlSegment('https://example.com/a?b=1'),
        const PlainSegment(' 谢谢'),
      ]);
    });

    test('句子结尾的标点不算进 URL/提及里', () {
      expect(parseMessage('看 https://a.com/x).'), [
        const PlainSegment('看 '),
        const UrlSegment('https://a.com/x'),
        const PlainSegment(').'),
      ]);
      expect(parseMessage('@amy, 你好').first, const MentionSegment('@amy', 0));
    });

    test('孤立的 @ / # 不当成元素', () {
      expect(parseMessage('@ 和 #'), [const PlainSegment('@ 和 #')]);
    });

    test('同一句里三类混排，顺序不乱', () {
      final segs = parseMessage('#tag @bob https://x.io/y 结束');
      expect(segs.first, isA<HashtagSegment>());
      expect(segs[1], isA<PlainSegment>());
      expect(segs[2], isA<MentionSegment>());
      expect(segs[3], isA<PlainSegment>());
      expect(segs[4], isA<UrlSegment>());
      expect(segs[5], const PlainSegment(' 结束'));
    });

    test('非 http 的 ftp/file 不当 URL', () {
      expect(_kinds('ftp://x.com f'), ['PlainSegment']);
    });

    test('emoji 原样保留（没有短代码转换）', () {
      expect(parseMessage('好耶 🎉🥳'), [const PlainSegment('好耶 🎉🥳')]);
    });
  });

  group('MessageText', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child)));
    }

    testWidgets('渲染后正文文字完整', (tester) async {
      await pump(tester, const MessageText('#tag @bob https://x.io/y 结束'));
      expect(find.textContaining('结束'), findsOneWidget);
    });

    testWidgets('点话题/提及/链接分别触发回调', (tester) async {
      final taps = <String>[];
      await pump(
        tester,
        MessageText(
          '#tag @bob https://x.io/y',
          usernames: const {'bob': 5},
          onHashtag: (t) => taps.add('tag:$t'),
          onMention: (id, n) => taps.add('mention:$id:$n'),
          onUrl: (u) => taps.add('url:$u'),
        ),
      );

      // 直接触发各 span 的 onTap，避免依赖手势竞技场的时序。
      // 注意 Text.rich 会再包一层 TextSpan，所以要**递归**收集。
      for (final span in _walk(tester)) {
        final r = span.recognizer;
        if (r is! TapGestureRecognizer) continue;
        r.onTap?.call();
      }

      // 顺序取决于遍历方式，这里只要求三个回调都被正确触发
      expect(
        taps,
        unorderedEquals(['tag:tag', 'mention:5:bob', 'url:https://x.io/y']),
      );
    });

    testWidgets('没有回调时不注册 recognizer（不可点）', (tester) async {
      await pump(tester, const MessageText('#tag @bob https://x.io/y'));
      final spans = _walk(tester).toList();
      expect(spans, isNotEmpty);
      expect(spans.every((s) => s.recognizer == null), isTrue);
    });

    test('`@u:<id>` 换成可读名字（原版 SpannableParser.parseMention）', () {
      const names = {4: 'demo_user', 3: 'jitsi'};
      expect(parseMessage('@u:4 你好', mentionNames: names), [
        const MentionSegment('@demo_user', 4),
        const PlainSegment(' 你好'),
      ]);
      expect(parseMessage('麻烦 @u:4，谢谢', mentionNames: names), [
        const PlainSegment('麻烦 '),
        const MentionSegment('@demo_user', 4),
        const PlainSegment('，谢谢'),
      ]);
      // 连着两个
      expect(parseMessage('@u:4@u:3', mentionNames: names), [
        const MentionSegment('@demo_user', 4),
        const MentionSegment('@jitsi', 3),
      ]);
    });

    test('本地没这个用户时保持 `@u:<id>` 原文', () {
      final segs = parseMessage('@u:99 你好', mentionNames: const {4: 'demo_user'});
      expect(segs.first, isA<MentionSegment>());
      expect((segs.first as MentionSegment).text, '@u:99');
    });

    test('human 用 username、bot 用 nickname', () {
      expect(
        mentionNameOf(
          UserDto.fromJson({
            'user_id': 4,
            'username': 'demo_user',
            'nickname': 'demo',
            'type': 'human',
          }),
        ),
        'demo_user',
      );
      expect(
        mentionNameOf(
          UserDto.fromJson({
            'user_id': 3,
            'username': 'jitsi',
            'nickname': 'Jitsi Meet',
            'type': 'bot',
          }),
        ),
        'Jitsi Meet',
      );
      expect(
        mentionNamesById([
          UserDto.fromJson({
            'user_id': 4,
            'username': 'demo_user',
            'type': 'human',
          }),
          UserDto.fromJson({
            'user_id': 3,
            'username': 'jitsi',
            'nickname': 'Jitsi',
            'type': 'bot',
          }),
          UserDto.fromJson({'user_id': 0, 'username': '', 'type': 'human'}),
        ]),
        {4: 'demo_user', 3: 'Jitsi'},
      );
    });

    testWidgets('渲染 `@u:4` 显示用户名而不是 id', (tester) async {
      await pump(
        tester,
        const MessageText('@u:4 上线了', mentionNames: {4: 'demo_user'}),
      );
      final texts = _walk(tester).map((s) => s.text).whereType<String>();
      expect(texts.join(), contains('@demo_user'));
      expect(texts.join(), isNot(contains('@u:4')));
    });

    testWidgets('重复 build 不会因为 recognizer 泄漏而报错', (tester) async {
      var n = 0;
      await pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              MessageText('#a', onHashtag: (_) => n++),
              TextButton(
                onPressed: () => setState(() {}),
                child: const Text('重绘'),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.text('重绘'));
      await tester.pump();
      await tester.tap(find.text('重绘'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
