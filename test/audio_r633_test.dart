// 音频播放器**人视角**修正（r633）—— DA219 / DA220 / DA221 / DA222。
//
// 现场（审计 + 真机截图）：
//   * DA219：失败提示下面印着一行英文机器码（`session_expired` /
//     `network_failed`…），还塞进了 `Semantics` —— 普通用户读到机器码，
//     读屏用户听到机器码，截图外发把排障信息一起带出去。
//   * DA220：全屏歌词**暂停中进来不对齐当前句**（停在开头＋半屏空白）；
//     没有字号调节；一行都复制不了；入口是右上角一个 ~24dp 的小图标
//     （真机按 3 次没点中）。
//   * DA221：睡眠定时菜单看不出当前是哪一档，想关要去菜单外面另找「取消」。
//   * DA222：进度条只给"已播 / 负的剩余"，从不显示总长；读屏只念百分比。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/audio_lyrics.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/media/audio_lyrics_view.dart';

LrcDocument _doc() => parseLrc(
  '[00:00]第一句\n'
  '[00:10]第二句\n'
  '[00:20]第三句\n'
  '[00:30]第四句\n'
  '[00:40]第五句\n'
  '[00:50]第六句\n',
);

Future<void> _pumpLyrics(
  WidgetTester tester, {
  required Duration position,
  double fontScale = 1.0,
  ValueChanged<String>? onCopied,
  double height = 320,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SizedBox(
          height: height,
          child: SyncedLyricsView(
            key: const Key('lyrics'),
            document: _doc(),
            position: position,
            height: height,
            lineHeight: 38 * fontScale,
            fontScale: fontScale,
            onCopied: onCopied,
            lineKeyPrefix: 'ly',
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  group('DA220 全屏歌词', () {
    testWidgets('① 首帧就对齐当前句（暂停中进来也能看到"正在唱的那句"）', (tester) async {
      // 位置 = 35s ⇒ 当前行是第 4 句（index 3）
      await _pumpLyrics(tester, position: const Duration(seconds: 35));

      final list = tester.widget<ListView>(
        find.byKey(const Key('lyrics-timed-list')),
      );
      final offset = list.controller!.offset;
      expect(
        offset,
        greaterThan(0),
        reason: 'DA220：首帧必须已经滚到当前句（旧版停在 0 ⇒ 屏上是歌词开头）',
      );

      // 当前句必须在视口里（几何判据，构建出来不算过）
      final line = find.byKey(const Key('ly-3'));
      expect(line, findsOneWidget);
      final rect = tester.getRect(line);
      final viewport = tester.getRect(find.byKey(const Key('lyrics')));
      expect(
        rect.top >= viewport.top - 1 && rect.bottom <= viewport.bottom + 1,
        isTrue,
        reason: 'DA220：当前句必须落在可视区内，rect=$rect viewport=$viewport',
      );
    });

    testWidgets('② 字号倍率真的放大正文（行高由调用方一起给）', (tester) async {
      await _pumpLyrics(tester, position: const Duration(seconds: 35));
      final small = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const Key('ly-3')),
          matching: find.byType(RichText),
        ),
      );
      final smallSize = small.text.style!.fontSize!;

      await _pumpLyrics(
        tester,
        position: const Duration(seconds: 35),
        fontScale: 1.45,
      );
      final big = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const Key('ly-3')),
          matching: find.byType(RichText),
        ),
      );
      expect(
        big.text.style!.fontSize!,
        greaterThan(smallSize),
        reason: 'DA220：A+ 必须真的把字号放大（只改行高不算）',
      );
    });

    testWidgets('③ 长按一行 = 复制这句（真的进剪贴板 + 回调）', (tester) async {
      String? copied;
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pumpLyrics(
        tester,
        position: const Duration(seconds: 35),
        onCopied: (t) => copied = t,
      );

      await tester.longPress(find.byKey(const Key('ly-tap-3')));
      await tester.pump();
      expect(
        clipboard,
        contains('第四句'),
        reason: 'DA220：长按必须把这一句放进剪贴板',
      );
      expect(copied, '第四句');
    });
  });

  group('DA221 睡眠定时', () {
    test('① 选中档位可回读；取消后清空（菜单靠它打勾）', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final timer = c.read(audioSleepTimerProvider.notifier);
      expect(timer.chosenMinutes, isNull);
      timer.start(const Duration(minutes: 30));
      expect(timer.chosenMinutes, 30);
      expect(c.read(audioSleepTimerProvider), const Duration(minutes: 30));
      timer.cancel();
      expect(timer.chosenMinutes, isNull);
      expect(c.read(audioSleepTimerProvider), isNull);
    });

    test('② 换档位要覆盖（不许同时记住两档）', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final timer = c.read(audioSleepTimerProvider.notifier);
      timer.start(const Duration(minutes: 60));
      timer.start(const Duration(minutes: 15));
      expect(timer.chosenMinutes, 15);
      timer.cancel();
    });
  });

  group('DA219 / DA222 静态判据（这两条改的是"屏上有没有"）', () {
    final songPage = File(
      'lib/src/features/audio/audio_song_page.dart',
    ).readAsStringSync();

    test('DA219：诊断串不许再进可见 Text / Semantics', () {
      expect(
        songPage.contains("Semantics(\n            label: reasonTag"),
        isFalse,
        reason: 'DA219：机器码不许进 Semantics（读屏会念出来）',
      );
      expect(
        songPage.contains("key: const Key('as-play-failure-reason')"),
        isFalse,
        reason: 'DA219：诊断串不许再以可见文本上屏',
      );
      expect(
        songPage.contains("Key('as-play-failure-reason:\$reasonTag')"),
        isTrue,
        reason: 'DA219：测试/排障要留一个零尺寸可断言标记',
      );
      expect(
        songPage.contains("debugPrint('[audio-song] failure reason="),
        isTrue,
        reason: 'DA219：排障信息要落到 logcat',
      );
    });

    test('DA222：进度条给总长 + 读屏格式化回调', () {
      expect(
        songPage.contains('semanticFormatterCallback'),
        isTrue,
        reason: 'DA222：Slider 必须念"已播 / 总长"，不能只念百分比',
      );
      expect(
        songPage.contains("maxMs > 0 ? _fmtMs(maxMs) : '—'"),
        isTrue,
        reason: 'DA222：右端显示总长（旧版是"负的剩余"）',
      );
      expect(
        songPage.contains("'-\${_fmtMs(maxMs - value)}'"),
        isFalse,
        reason: 'DA222：负剩余写法必须已被替换',
      );
    });
  });
}
