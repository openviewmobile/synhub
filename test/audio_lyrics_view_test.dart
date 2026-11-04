// 歌词滚动视图的回归用例（第 274 轮用户报障：「歌词也没有滚动的效果」）。
//
// 三条要钉住的事：
//   ① **有时间轴** ⇒ 当前行高亮 + 随播放位置自动居中滚动 + 点行跳转；
//   ② **没有时间轴** ⇒ 明确标注（`audioLyricsPlainTextHintText()` 那句），
//      **不假装同步**；
//   ③ 用户手动滚动时自动跟随**让位**（不跟手指抢），过一段时间再恢复。
//
// 纯函数（下标/偏移/让位判定）单独一组，不依赖 widget 环境。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/audio_lyrics.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/audio_lyrics_view.dart';

LrcDocument _timed() => parseLrc(
  '[00:00.00]line 0\n'
  '[00:04.00]line 1\n'
  '[00:08.00]line 2\n'
  '[00:12.00]line 3\n'
  '[00:16.00]line 4\n'
  '[00:20.00]line 5\n'
  '[00:24.00]line 6\n'
  '[00:28.00]line 7\n',
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.dark(), 
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Center(
                        // 高度与视图默认 `height`(260) 一致：居中 padding 是按
            // `height/2` 算的，视口比它小的话后半屏的行**点不中**。
            child: SizedBox(width: 320, height: 260, child: child),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // ★ r631（DA213）：真机撞到「全屏歌词页只有署名、正文一个字都没有」。
  //   根因：调用方传 `height: double.infinity`，顶部留白 `height/2` 变成无穷大
  //   ⇒ 每一行都被推出视口。这里同时钉住两件事：
  //   ① 视图自己兜住无穷高度（不靠调用方守规矩）；
  //   ② 有限高度下，高亮行**真的落在视口里**（不是"构建出来了"就算过）。
  group('DA213：无穷高度不许把歌词推出屏幕', () {
    testWidgets('height=infinity ⇒ 仍渲染出可见的行（不抛 overflow）', (tester) async {
      final doc = _timed();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(),
              child: SizedBox(
                width: 320,
                height: 400,
                child: SyncedLyricsView(
                  document: doc,
                  position: const Duration(seconds: 9),
                  height: double.infinity,
                  lineKeyPrefix: 'infinite-line',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // 至少有一行真的在屏内（y 在 0..400 之间）
      final visible = <String>[];
      for (var i = 0; i < doc.lines.length; i++) {
        final f = find.byKey(Key('infinite-line-$i'));
        if (f.evaluate().isEmpty) continue;
        final r = tester.getRect(f);
        if (r.top >= -1 && r.bottom <= 401) visible.add('$i');
      }
      expect(
        visible,
        isNotEmpty,
        reason: 'DA213：无穷高度曾让整屏歌词消失，必须至少有一行落在视口内',
      );
    });
  });

  group('纯函数：当前行下标', () {
    final lines = [
      const LyricLine(time: Duration.zero, text: 'a'),
      const LyricLine(time: Duration(seconds: 4), text: 'b'),
      const LyricLine(time: Duration(seconds: 8), text: 'c'),
    ];

    test('没有时间轴 / 空表 → -1', () {
      expect(activeLyricLineIndex(const [], Duration.zero), -1);
      expect(activeLyricLineIndex(const [], const Duration(seconds: 9)), -1);
    });

    test('前奏（第一行之前）→ -1（不硬指一行）', () {
      final doc = parseLrc('[00:05.00]first');
      expect(
        activeLyricLineIndex(doc.lines, const Duration(seconds: 2)),
        -1,
      );
    });

    test('边界：正好落在某行的时间点 → 就是那一行', () {
      expect(activeLyricLineIndex(lines, Duration.zero), 0);
      expect(activeLyricLineIndex(lines, const Duration(seconds: 4)), 1);
      expect(activeLyricLineIndex(lines, const Duration(seconds: 8)), 2);
    });

    test('行与行之间 → 前一行；超过最后一行 → 最后一行', () {
      expect(activeLyricLineIndex(lines, const Duration(seconds: 7)), 1);
      expect(activeLyricLineIndex(lines, const Duration(seconds: 999)), 2);
    });

    test('同一时间点重复出现 → 取最后一个（LRC 允许多标签）', () {
      final doc = parseLrc('[00:10.00]a\n[00:10.00]b');
      expect(
        activeLyricLineIndex(doc.lines, const Duration(seconds: 10)),
        1,
      );
    });
  });

  group('纯函数：居中滚动偏移', () {
    test('中间的行 → 居中（index*行高 − 半个视口余量）', () {
      // 视口 200，行高 28，第 10 行：10*28 − (200−28)/2 = 280 − 86 = 194
      expect(
        lyricCenteredScrollOffset(
          index: 10,
          lineCount: 20,
          viewportHeight: 200,
          lineHeight: 28,
          maxScrollExtent: 1000,
        ),
        194,
      );
    });

    test('前几行 → clamp 到 0（不出现负偏移）', () {
      expect(
        lyricCenteredScrollOffset(
          index: 0,
          lineCount: 20,
          viewportHeight: 200,
          lineHeight: 28,
          maxScrollExtent: 1000,
        ),
        0,
      );
    });

    test('末尾 → clamp 到 maxScrollExtent', () {
      expect(
        lyricCenteredScrollOffset(
          index: 19,
          lineCount: 20,
          viewportHeight: 200,
          lineHeight: 28,
          maxScrollExtent: 100,
        ),
        100,
      );
    });

    test('无高亮 / 视口非法 / 内容不滚 → 0（不抛）', () {
      expect(
        lyricCenteredScrollOffset(
          index: -1,
          lineCount: 20,
          viewportHeight: 200,
          lineHeight: 28,
          maxScrollExtent: 1000,
        ),
        0,
      );
      expect(
        lyricCenteredScrollOffset(
          index: 3,
          lineCount: 20,
          viewportHeight: 0,
          lineHeight: 28,
          maxScrollExtent: 1000,
        ),
        0,
      );
      expect(
        lyricCenteredScrollOffset(
          index: 3,
          lineCount: 20,
          viewportHeight: 200,
          lineHeight: 28,
          maxScrollExtent: 0,
        ),
        0,
      );
    });
  });

  group('纯函数：自动跟随让位', () {
    test('正在拖 → 不让位不行（false）', () {
      expect(
        lyricAutoScrollAllowed(
          userScrolling: true,
          sinceUserScroll: const Duration(seconds: 99),
        ),
        isFalse,
      );
    });

    test('刚拖完（延迟内）→ 不跟随', () {
      expect(
        lyricAutoScrollAllowed(
          userScrolling: false,
          sinceUserScroll: const Duration(seconds: 1),
        ),
        isFalse,
      );
    });

    test('过了延迟 → 恢复跟随', () {
      expect(
        lyricAutoScrollAllowed(
          userScrolling: false,
          sinceUserScroll: const Duration(seconds: 5),
        ),
        isTrue,
      );
    });
  });

  group('★ DA112（r477）：留白与"居中"必须是同一套坐标（r476 真机翻车点）', () {
    test('DA112 · 公式吃 topPadding：留白 100、行高 40、视口 400、第 5 行 → 120', () {
      // 5*40 + 40/2 + 100 − 400/2 = 200 + 20 + 100 − 200 = 120
      expect(
        lyricCenteredScrollOffset(
          index: 5,
          lineCount: 12,
          viewportHeight: 400,
          lineHeight: 40,
          maxScrollExtent: 9999,
          topPadding: 100,
        ),
        120,
      );
    });

    test('DA112 · 留白为 0 时与老公式等价（不破坏既有调用）', () {
      final a = lyricCenteredScrollOffset(
        index: 7,
        lineCount: 12,
        viewportHeight: 300,
        lineHeight: 30,
        maxScrollExtent: 9999,
      );
      final b = lyricCenteredScrollOffset(
        index: 7,
        lineCount: 12,
        viewportHeight: 300,
        lineHeight: 30,
        maxScrollExtent: 9999,
        topPadding: 0,
      );
      expect(a, b);
    });

    testWidgets('DA112 · 起播后高亮行**停在视口中部**（不是贴底）', (tester) async {
      final doc = _timed();
      // 先起播（第 0 行）再跳到第 5 行（20s）—— 跟随滚动只在"行变了"时触发，
      // 直接以 20s 首帧建树是不滚的（builder 也只建出视口内几行）。
      await _pump(
        tester,
        SyncedLyricsView(document: doc, position: Duration.zero),
      );
      await _pump(
        tester,
        SyncedLyricsView(
          document: doc,
          position: const Duration(seconds: 20),
        ),
      );
      await tester.pumpAndSettle();

      final listRect = tester.getRect(find.byKey(const Key('lyrics-timed-list')));
      final lineRect = tester.getRect(find.byKey(const Key('lyrics-line-5')));
      final viewportCenter = listRect.center.dy;
      final lineCenter = lineRect.center.dy;
      expect(
        (lineCenter - viewportCenter).abs(),
        lessThan(40),
        reason:
            '高亮行必须停在视口中部（±40dp）；贴底/贴顶说明公式与留白不是同一套坐标',
      );
    });

    testWidgets('DA112 · 还没到第一句（无高亮行）→ 不留半屏空白', (tester) async {
      // 第一句在 5s；位置 1s ⇒ 前奏，没有高亮行
      final doc = parseLrc('[00:05.00]first\n[00:09.00]second\n');
      await _pump(
        tester,
        SyncedLyricsView(document: doc, position: const Duration(seconds: 1)),
      );
      await tester.pumpAndSettle();
      final listRect = tester.getRect(find.byKey(const Key('lyrics-timed-list')));
      final lineRect = tester.getRect(find.byKey(const Key('lyrics-line-0')));
      expect(
        lineRect.top - listRect.top,
        lessThan(60),
        reason: '没有高亮行时歌詞要从顶部开始排（顶部空白不许≥半屏）',
      );
    });
  });

  group('视图：有时间轴 → 高亮跟着位置走', () {
    testWidgets('当前行高亮，且随位置前移；列表真的滚起来', (tester) async {
      final doc = _timed();
      await _pump(
        tester,
        SyncedLyricsView(document: doc, position: Duration.zero),
      );
      // 第 0 行：主色 + 加粗
      Text w0() => tester.widget<Text>(find.byKey(const Key('lyrics-line-0')));
      expect(w0().style?.fontWeight, FontWeight.w600);

      final before = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      expect(before, 0);

      // 位置跳到第 6 行 → 高亮换行 + 滚动偏移变化
      await _pump(
        tester,
        SyncedLyricsView(document: doc, position: const Duration(seconds: 24)),
      );
      await tester.pumpAndSettle();
      // 第 0 行可能已被 `ListView.builder` 回收（滚出视口）——那是**正确**的
      // 惰性构建行为，所以只在它还在树上时才断言"不再高亮"。
      final line0 = find.byKey(const Key('lyrics-line-0'));
      if (line0.evaluate().isNotEmpty) {
        expect(
          tester.widget<Text>(line0).style?.fontWeight,
          isNot(FontWeight.w600),
        );
      }
      expect(
        tester
            .widget<Text>(find.byKey(const Key('lyrics-line-6')))
            .style
            ?.fontWeight,
        FontWeight.w600,
      );
      final after = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      expect(after, greaterThan(before));
    });

    testWidgets('点某一行 → 回调拿到那一行的时间点（可 seek）', (tester) async {
      final doc = _timed();
      Duration? seeked;
      await _pump(
        tester,
        SyncedLyricsView(
          document: doc,
          position: Duration.zero,
          onSeek: (at) => seeked = at,
        ),
      );
      // ★ r633（DA220）：首帧现在会**主动滚到当前行**（`_active` 对齐），
      //   滚动是一段 ~280ms 的动画 ⇒ 必须等动画停稳再点，否则点的是动画中途
      //   的坐标（真机用户看到的是停稳后的排版，用例也要按停稳的排版点）。
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('lyrics-line-tap-2')));
      expect(seeked, const Duration(seconds: 8));
    });

    testWidgets('减少动态效果 → 仍然跳到该行（只是不用动画）', (tester) async {
      final doc = _timed();
      await _pump(
        tester,
        SyncedLyricsView(document: doc, position: Duration.zero),
        disableAnimations: true,
      );
      await _pump(
        tester,
        SyncedLyricsView(document: doc, position: const Duration(seconds: 24)),
        disableAnimations: true,
      );
      await tester.pump();
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        greaterThan(0),
      );
    });
  });

  group('视图：没有时间轴 → 如实标注，不假装同步', () {
    testWidgets('显示「不会自动滚动」说明，且**没有**高亮行', (tester) async {
      final plain = parseLrc('just a line\nanother line\n');
      expect(plain.timed, isFalse);
      await _pump(
        tester,
        SyncedLyricsView(
          document: plain,
          position: const Duration(seconds: 30),
        ),
      );
      expect(find.byKey(const Key('lyrics-untimed-hint')), findsOneWidget);
      expect(find.byKey(const Key('lyrics-untimed-list')), findsOneWidget);
      // 有时间轴的列表**不该**存在（两态互斥）
      expect(find.byKey(const Key('lyrics-timed-list')), findsNothing);
      // 位置再往前推也不会"高亮"任何一行
      await _pump(
        tester,
        SyncedLyricsView(
          document: plain,
          position: const Duration(minutes: 3),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lyrics-untimed-hint')), findsOneWidget);
    });

    testWidgets('空文档 → 什么都不画（由调用方给空态）', (tester) async {
      await _pump(
        tester,
        SyncedLyricsView(
          document: const LrcDocument.empty(),
          position: Duration.zero,
        ),
      );
      expect(find.byKey(const Key('lyrics-timed-list')), findsNothing);
      expect(find.byKey(const Key('lyrics-untimed-list')), findsNothing);
    });

    testWidgets('无时间轴时点行**不**触发 seek', (tester) async {
      var taps = 0;
      final plain = parseLrc('a\nb\n');
      await _pump(
        tester,
        SyncedLyricsView(
          document: plain,
          position: Duration.zero,
          onSeek: (_) => taps++,
        ),
      );
      // 无时间轴分支没有 tap 包装
      expect(find.byKey(const Key('lyrics-line-tap-0')), findsNothing);
      expect(taps, 0);
    });
  });

  // ★★★ r644（`DA239` / `DA240`）：滑走之后**回不去**，以及边缘那半行"齐刀切掉"。
  //
  //   ① `DA239`：手动滑走后自动跟随要让位 4 秒（这是对的），但"我现在就想回去"
  //      没有任何落点 ⇒ 当前行滑出视口时给一颗「回到正在唱的那句」，点完自己消失；
  //   ② `DA240`：视口边缘那一行是硬切的半行 ⇒ 只在**还有内容**的那一边渐隐，
  //      到顶/到底不渐隐（那里确实没东西，渐隐会骗人）。
  group('★ r644 DA239/DA240：回到当前句 + 边缘渐隐', () {
    test('DA239 纯函数：当前行完整在视口里才算 visible', () {
      // 8 行 × 28，顶部留白 130，视口 260。
      // 第 2 行：top = 130+56 = 186，bottom = 214。
      expect(
        lyricActiveLineVisible(
          index: 2,
          lineHeight: 28,
          topPadding: 130,
          offset: 70,
          viewportHeight: 260,
        ),
        isTrue,
      );
      // 往下滑 200（offset 270）⇒ 第 2 行（186..214）已经在上边界之上
      expect(
        lyricActiveLineVisible(
          index: 2,
          lineHeight: 28,
          topPadding: 130,
          offset: 270,
          viewportHeight: 260,
        ),
        isFalse,
      );
      // 只露出半行也不算可见（否则按钮会在"其实还看得见"的时候乱冒）
      expect(
        lyricActiveLineVisible(
          index: 2,
          lineHeight: 28,
          topPadding: 130,
          offset: 195,
          viewportHeight: 260,
        ),
        isFalse,
      );
      // 没有高亮行 / 视口未知 ⇒ 不算（不给假控件）
      expect(
        lyricActiveLineVisible(
          index: -1,
          lineHeight: 28,
          topPadding: 8,
          offset: 0,
          viewportHeight: 260,
        ),
        isFalse,
      );
    });

    testWidgets('DA239 滑走后出现「回到正在唱的那句」，点一下回到居中且按钮消失',
        (tester) async {
      final doc = _timed();
      await _pump(
        tester,
        SyncedLyricsView(
          document: doc,
          position: const Duration(seconds: 9), // 第 2 行
          lineKeyPrefix: 'jump-line',
        ),
        disableAnimations: true,
      );
      await tester.pump(); // 首帧对齐
      await tester.pump();
      final listFinder = find.byKey(const Key('lyrics-timed-list'));
      expect(listFinder, findsOneWidget);

      // 反向：还没滑走时**不许**出现这颗按钮（否则就是永久占位的假控件）
      expect(find.byKey(const Key('lyrics-jump-to-active')), findsNothing);

      // 手指往下滑到底（-400 会被 maxScrollExtent 夹住）⇒ 第 2 行滑出视口
      await tester.drag(listFinder, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('lyrics-jump-to-active')),
        findsOneWidget,
        reason: 'DA239：当前行已滑出视口，必须给"回到正在唱的那句"的落点',
      );
      // 48dp 最小点击区（可达性）
      final size = tester.getSize(find.byKey(const Key('lyrics-jump-to-active')));
      expect(size.height, greaterThanOrEqualTo(48.0));

      await tester.tap(find.byKey(const Key('lyrics-jump-to-active')));
      await tester.pumpAndSettle();

      // 点完：按钮自己消失，且第 2 行重新落在**视口**里（居中）
      //   注：`_pump` 把视图居中放在 800x600 的测试窗口里 ⇒ 断言必须相对
      //   列表自己的矩形，不能拿屏幕坐标跟 0..260 比。
      expect(find.byKey(const Key('lyrics-jump-to-active')), findsNothing);
      final view = tester.getRect(listFinder);
      final rect = tester.getRect(find.byKey(const Key('jump-line-2')));
      expect(rect.top, greaterThanOrEqualTo(view.top - 0.5));
      expect(rect.bottom, lessThanOrEqualTo(view.bottom + 0.5));
      expect(
        (rect.center.dy - view.center.dy).abs(),
        lessThanOrEqualTo(4.0),
        reason: 'DA239：回到当前句应当是**居中**，不是随便停在某个位置',
      );
    });

    testWidgets('DA240 还有内容的那一边才渐隐；短歌词不溢出 ⇒ 不渐隐',
        (tester) async {
      final doc = _timed();
      await _pump(
        tester,
        SyncedLyricsView(
          document: doc,
          position: const Duration(seconds: 9),
          lineKeyPrefix: 'fade-line',
        ),
        disableAnimations: true,
      );
      await tester.pump();
      await tester.pump();
      // 剩下 6 行 × 28 + 底部留白 130 ⇒ 下面还有内容
      //
      // ★ 遮罩**常驻**（见 `EdgeFade` 注释：包/不包会重建 ListView ⇒ 滚动归零），
      //   所以判据是**方向**而不是"有没有"。
      expect(find.byKey(const Key('lyrics-edge-fade')), findsOneWidget);
      final fading = tester.widget<EdgeFade>(
        find.byKey(const Key('lyrics-edge-fade')),
      );
      expect(
        fading.fadeTop || fading.fadeBottom,
        isTrue,
        reason: 'DA240：还有内容的那一侧必须渐隐',
      );
      expect(fading.fadeBottom, isTrue, reason: 'DA240：下面还有内容 ⇒ 下边渐隐');
      expect(
        fading.fadeTop,
        isTrue,
        reason: 'DA240：当前句居中 ⇒ 上面也有内容，上边同样渐隐',
      );

      // 反向：短歌词 + 没有高亮 ⇒ 不溢出，两边界都没有内容 ⇒ 不渐隐
      await _pump(
        tester,
        SyncedLyricsView(
          document: parseLrc('[00:10.00]only\n[00:20.00]two\n'),
          position: Duration.zero,
          lineKeyPrefix: 'short-line',
        ),
      );
      await tester.pump();
      final idle = tester.widget<EdgeFade>(
        find.byKey(const Key('lyrics-edge-fade')),
      );
      expect(idle.fadeTop, isFalse);
      expect(idle.fadeBottom, isFalse);
    });
  });
}
