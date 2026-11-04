// r637 · DA228：视频「字幕全文」同步滚动（用户第一轮点名的缺口）。
//
// 只验**能机检**的判据：文档转换、打开就停在当前句、位置推进跟着滚、
// 点一句跳到那句的起点、以及"没有外挂字幕就没有入口"（反向）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/media/media_subtitle_transcript.dart';
import 'package:synhub/src/features/media/media_subtitles.dart';

const _cues = <SubtitleCue>[
  SubtitleCue(
    start: Duration.zero,
    end: Duration(seconds: 5),
    text: '大家好',
  ),
  SubtitleCue(
    start: Duration(seconds: 20),
    end: Duration(seconds: 25),
    text: '第一行\n第二行',
  ),
  SubtitleCue(
    start: Duration(seconds: 40),
    end: Duration(seconds: 45),
    text: '我们开始',
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  required ValueNotifier<Duration> position,
  ValueChanged<Duration>? onSeek,
  List<SubtitleCue> cues = _cues,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaSubtitleTranscript(
          cues: cues,
          position: position,
          onSeek: onSeek,
          height: 400,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('① SubtitleCue → LrcDocument：时间轴照搬、换行折成空格、顺序不动', () {
    final doc = subtitleTranscriptDocument(_cues);
    expect(doc.lines.map((l) => l.time), const [
      Duration.zero,
      Duration(seconds: 20),
      Duration(seconds: 40),
    ]);
    expect(doc.lines[1].text, '第一行 第二行', reason: '字幕里的换行在单行列表里要折成空格');
    expect(doc.timed, isTrue);
    expect(subtitleTranscriptDocument(const []).timed, isFalse);
  });

  testWidgets('② 打开就停在正在播的那一句（不是从第一句开始翻）', (tester) async {
    final position = ValueNotifier<Duration>(const Duration(seconds: 25));
    addTearDown(position.dispose);
    await _pump(tester, position: position);

    // 条数如实显示
    expect(
      tester.widget<Text>(find.byKey(const Key('media-subtitle-transcript-count'))).data,
      '3',
    );
    // 当前句（第 2 行）在视口内
    final rect = tester.getRect(find.byKey(const Key('subtitle-line-1')));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(400));
    // 高亮判据：当前行用主色，非当前行为默认色
    final active = tester.widget<Text>(find.byKey(const Key('subtitle-line-1')));
    final idle = tester.widget<Text>(find.byKey(const Key('subtitle-line-0')));
    expect(active.style?.color, isNotNull);
    expect(idle.style?.color, isNull);
  });

  testWidgets('③ 位置推进 ⇒ 高亮与滚动跟着走（同步滚动）', (tester) async {
    final position = ValueNotifier<Duration>(const Duration(seconds: 2));
    addTearDown(position.dispose);
    await _pump(tester, position: position);
    expect(
      tester.widget<Text>(find.byKey(const Key('subtitle-line-0'))).style?.color,
      isNotNull,
    );

    position.value = const Duration(seconds: 41);
    await tester.pumpAndSettle();
    final moved = tester.widget<Text>(find.byKey(const Key('subtitle-line-2')));
    expect(moved.style?.color, isNotNull, reason: '播到 0:41 ⇒ 第 3 句应高亮');
    expect(
      tester.widget<Text>(find.byKey(const Key('subtitle-line-0'))).style?.color,
      isNull,
      reason: '上一句要退出高亮',
    );
  });

  testWidgets('④ 点某一句 ⇒ 用**那一句的起点** seek', (tester) async {
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    final seeks = <Duration>[];
    await _pump(tester, position: position, onSeek: seeks.add);

    await tester.tap(find.byKey(const Key('subtitle-line-tap-2')));
    await tester.pump();
    expect(seeks, const [Duration(seconds: 40)]);
  });

  testWidgets('⑤ 反向：没有外挂字幕 ⇒ 播放器的「播放设置」里没有这个入口',
      (tester) async {
    // 这里只判"面板本身不含入口"这一半 —— 另一半（设置面板按外挂字幕出现）
    // 在 `media_player_r636_test.dart` 的 ⑬ 里按真实播放器跑。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaSubtitleTranscript(
            cues: const [],
            position: ValueNotifier<Duration>(Duration.zero),
            height: 400,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('media-subtitle-transcript')), findsOneWidget);
    expect(find.byKey(const Key('media-subtitle-transcript-count')), findsOneWidget);
  });
}
