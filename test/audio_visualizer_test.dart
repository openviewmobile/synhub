// 播放律动可视化（`audio_visualizer.dart`）的**离线**单测。
//
// 这个文件的头号使命不是"画得像不像"，而是**守住诚实与性能这两条线**：
//   ① 界面文案必须叫「律动动效」，**不许**出现"频谱"（它不是真实频谱 ——
//      原因与 Android 官方文档证据见 `audio_visualizer.dart` 文件头）；
//   ② 动画必须是**有界**的：`pumpAndSettle()` 不许超时（本仓既有音频用例
//      大量依赖它；曾经因为一个 `CircularProgressIndicator` 直接超时）；
//   ③ 暂停/空闲时不许留 ticker（省电），`disableAnimations`（无障碍）
//      时完全不动；
//   ④ 推导出的数据是**确定性**的（同一时间点同一输入 → 同一帧），
//      这样"随播放位置律动"才是可复现的。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/audio_visualizer.dart';

/// 造一张纯色 PNG（用来验证"封面主色"真的读到了像素）。
Future<Uint8List> _solidPng(int r, int g, int b, {int size = 16}) async {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('推导出的律动数据（不是真实频谱）', () {
    test('确定：同一输入永远给同一帧', () {
      final a = derivedAudioVisualLevels(seconds: 12.5, barCount: 16);
      final b = derivedAudioVisualLevels(seconds: 12.5, barCount: 16);
      expect(a, b);
    });

    test('柱数就是请求的柱数，且每根都在 0..1（画不出屏外的柱子）', () {
      for (final n in [1, 8, 28, 64]) {
        final levels = derivedAudioVisualLevels(seconds: 3, barCount: n);
        expect(levels, hasLength(n));
        for (final v in levels) {
          expect(v, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('随时间变化（"随播放位置律动"这一步真的发生了）', () {
      final a = derivedAudioVisualLevels(seconds: 1.0, barCount: 24, seed: 7);
      final b = derivedAudioVisualLevels(seconds: 1.9, barCount: 24, seed: 7);
      expect(a, isNot(b));
    });

    test('不同文件（seed 不同）给不同的形态', () {
      // seed 与实现约定一致，是 0..1（越界会被钳住 ⇒ 用界内的两个值）
      final a = derivedAudioVisualLevels(seconds: 1.0, barCount: 12, seed: 0.1);
      final b = derivedAudioVisualLevels(seconds: 1.0, barCount: 12, seed: 0.9);
      expect(a, isNot(b));
    });

    test('seed 越界会被钳住（不产生 NaN，也不"整首歌一个样"）', () {
      final clamped = derivedAudioVisualLevels(
        seconds: 1.0,
        barCount: 8,
        seed: 9.9,
      );
      expect(
        clamped,
        derivedAudioVisualLevels(seconds: 1.0, barCount: 8, seed: 1.0),
      );
    });

    test('拖动进度（progress 变化）会改相位，但不越界', () {
      final a = derivedAudioVisualLevels(seconds: 5, barCount: 12, progress: 0.1);
      final b = derivedAudioVisualLevels(seconds: 5, barCount: 12, progress: 0.8);
      expect(a, isNot(b));
      for (final v in b) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });

    test('负数/超大时间不崩（位置在极端时刻也不会画出 NaN）', () {
      for (final s in [-10.0, 0.0, 1e9]) {
        for (final v in derivedAudioVisualLevels(seconds: s, barCount: 8)) {
          expect(v.isFinite, isTrue);
          expect(v, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('呼吸值也在 0..1 且随时间变化', () {
      final a = derivedAudioVisualBreath(seconds: 0.4);
      final b = derivedAudioVisualBreath(seconds: 1.9);
      expect(a, inInclusiveRange(0.0, 1.0));
      expect(b, inInclusiveRange(0.0, 1.0));
      expect(a, isNot(b));
    });

    test('seed 与主色由文件 key 稳定推出', () {
      expect(audioVisualizerSeedForKey('/home/a.mp3'),
          audioVisualizerSeedForKey('/home/a.mp3'));
      expect(audioVisualizerSeedForKey('/home/a.mp3'),
          isNot(audioVisualizerSeedForKey('/home/b.mp3')));
      final color = audioVisualizerAccentForKey('/home/a.mp3');
      expect(color, audioVisualizerAccentForKey('/home/a.mp3'));
      expect(color.a, 1.0, reason: '必须是不透明色');
    });
  });

  group('封面主色（真的解码像素，拿不到就返回 null）', () {
    // ⚠️ 必须用 `tester.runAsync()` 包住：`ui.instantiateImageCodec` 是**真实**
    // 异步（走引擎解码线程），widget 测试默认的 FakeAsync 里它的 Future
    // **永远不会完成** —— 我第一次没包，整个用例挂了 7 分钟才被 runner 掐掉。
    testWidgets('纯色封面 → 取到一个有色相的主色', (tester) async {
      final bytes = await _solidPng(200, 40, 40);
      final color = await tester.runAsync(() => dominantCoverColor(bytes));
      expect(color, isNotNull, reason: '能解码的封面必须给出主色');
      // 红色封面 → 红通道最大，且饱和度被抬到可用的下限
      final hsl = HSLColor.fromColor(color!);
      expect(hsl.saturation, greaterThanOrEqualTo(0.35));
      expect(color.r, greaterThan(color.g));
      expect(color.r, greaterThan(color.b));
    });

    testWidgets('灰度封面也会被抬到最低饱和度（否则高亮看不见）', (tester) async {
      final bytes = await _solidPng(128, 128, 128);
      final color = await tester.runAsync(() => dominantCoverColor(bytes));
      expect(color, isNotNull);
      // 实现里钳到 ≥0.35；`HSLColor.toColor()` 走 8 位量化再读回来会有
      // ~0.004 的抖动（实测 0.3464…）⇒ 断言留一点容差，别把量化误差当缺陷。
      expect(
        HSLColor.fromColor(color!).saturation,
        greaterThanOrEqualTo(0.34),
      );
    });

    testWidgets('没有封面 / 坏字节 → null（界面照常用默认色，不抛）', (tester) async {
      expect(
        await tester.runAsync(() => dominantCoverColor(null)),
        isNull,
      );
      expect(
        await tester.runAsync(() => dominantCoverColor(Uint8List(0))),
        isNull,
      );
      expect(
        await tester.runAsync(
          () => dominantCoverColor(Uint8List.fromList([1, 2, 3, 4, 5])),
        ),
        isNull,
        reason: '不是图片的字节必须优雅失败',
      );
    });
  });

  group('AudioVisualizer 组件', () {
    Widget host(
      Widget child, {
      bool playing = false,
      bool disableAnimations = false,
    }) => MaterialApp(theme: AppTheme.dark(), 
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(body: Center(child: child)),
      ),
    );

    AudioVisualizer viz({
      bool playing = false,
      Duration position = Duration.zero,
      Duration? duration = const Duration(seconds: 100),
      bool compact = false,
    }) => AudioVisualizer(
      playing: playing,
      position: position,
      duration: duration,
      seedKey: '/home/song.mp3',
      compact: compact,
    );

    testWidgets('画面与文案都在：可观测点是 audio-visualizer / -canvas / -caption',
        (tester) async {
      await tester.pumpWidget(host(viz()));
      await tester.pump();
      expect(find.byKey(const Key('audio-visualizer')), findsOneWidget);
      expect(find.byKey(const Key('audio-visualizer-canvas')), findsOneWidget);
      expect(find.byKey(const Key('audio-visualizer-caption')), findsOneWidget);
      expect(find.text('律动动效'), findsOneWidget);
    });

    testWidgets('★ 诚实底线：界面**不许**把推导动效叫成"频谱"', (tester) async {
      await tester.pumpWidget(host(viz(playing: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.textContaining('频谱'),
        findsNothing,
        reason: '这不是真实频谱（Android Visualizer 需要 RECORD_AUDIO），不许这么标',
      );
      expect(
        find.textContaining('FFT'),
        findsNothing,
        reason: '更不许标成 FFT',
      );
    });

    testWidgets('暂停/空闲：没有常驻动画（pumpAndSettle 必须能收敛）', (tester) async {
      await tester.pumpWidget(host(viz()));
      await tester.pump();
      // 若能超时，这里会直接抛 "pumpAndSettle timed out" —— 就是我们要防的回归
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-visualizer')), findsOneWidget);
    });

    testWidgets('播放中：每来一个位置更新只是**有界**地推进一下，仍能收敛', (tester) async {
      Widget build(Duration p) => host(viz(playing: true, position: p));
      await tester.pumpWidget(build(const Duration(seconds: 1)));
      await tester.pump();
      await tester.pumpWidget(build(const Duration(seconds: 2)));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-visualizer')), findsOneWidget);
    });

    testWidgets('无障碍开了"减少动画" → 完全不动（pumpAndSettle 立刻收敛）',
        (tester) async {
      Widget build(Duration p) =>
          host(viz(playing: true, position: p), disableAnimations: true);
      await tester.pumpWidget(build(const Duration(seconds: 1)));
      await tester.pump();
      await tester.pumpWidget(build(const Duration(seconds: 1, milliseconds: 500)));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-visualizer')), findsOneWidget);
    });

    testWidgets('紧凑模式（矮屏/横屏）也能画，且没有 RenderFlex 溢出', (tester) async {
      await tester.pumpWidget(host(viz(compact: true)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('audio-visualizer-canvas')), findsOneWidget);
      // 紧凑模式**不留文案行**（屏就那么大，画面优先）—— 这是设计取舍，钉住它
      expect(find.byKey(const Key('audio-visualizer-caption')), findsNothing);
    });

    testWidgets('时长未知 / 无封面 / 组件被换掉：都不崩', (tester) async {
      await tester.pumpWidget(
        host(viz(duration: null, playing: true)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // 换掉组件 → dispose 掉 ticker
      await tester.pumpWidget(MaterialApp(theme: AppTheme.dark(), home: SizedBox()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('canvans 尺寸就是请求的尺寸（布局可预期）', (tester) async {
      await tester.pumpWidget(
        host(
          AudioVisualizer(
            playing: false,
            position: Duration.zero,
            duration: const Duration(seconds: 10),
            seedKey: 'k',
            size: const Size(150, 150),
          ),
        ),
      );
      await tester.pump();
      final size = tester.getSize(find.byKey(const Key('audio-visualizer-canvas')));
      expect(size.width, 150);
      // 底部要给律动柱留出 34px 的条带（不是把柱子画到封面上去）
      expect(size.height, 150 + 34);
    });
  });

  group('画笔重绘判定', () {
    const accentA = Color(0xFF112233);
    const accentB = Color(0xFF445566);
    const frameA = AudioVisualFrame(
      levels: [0.1, 0.2],
      breath: 0.3,
      accent: accentA,
    );
    const frameB = AudioVisualFrame(
      levels: [0.4, 0.2],
      breath: 0.3,
      accent: accentA,
    );

    test('帧或主色变了才重绘', () {
      final p1 = AudioVisualizerPainter(frame: frameA, accent: accentA);
      final p2 = AudioVisualizerPainter(frame: frameA, accent: accentA);
      final p3 = AudioVisualizerPainter(frame: frameB, accent: accentA);
      expect(p2.shouldRepaint(p1), isFalse);
      expect(p3.shouldRepaint(p1), isTrue);
      expect(
        AudioVisualizerPainter(frame: frameB, accent: accentB)
            .shouldRepaint(p3),
        isTrue,
        reason: '只换主色也要重绘',
      );
    });

    test('帧相等性（levels 是列表，得比内容不是比引用）', () {
      final b = AudioVisualFrame(
        levels: const [0.1, 0.2],
        breath: 0.3,
        accent: accentA,
      );
      expect(frameA, b);
      expect(frameA.hashCode, b.hashCode);
      expect(
        frameA ==
            const AudioVisualFrame(
              levels: [0.1],
              breath: 0.3,
              accent: accentA,
            ),
        isFalse,
      );
    });
  });

  test('默认柱数/步长是常量（界面与用例共用，别各写一份）', () {
    expect(kAudioVisualizerBarCount, greaterThan(0));
    expect(kAudioVisualizerStep, const Duration(milliseconds: 260));
  });

  test('像素级确定性：同一时间点算两次，逐柱完全相同', () {
    final a = derivedAudioVisualLevels(seconds: 42.424, barCount: 28, seed: 3.5);
    final b = derivedAudioVisualLevels(seconds: 42.424, barCount: 28, seed: 3.5);
    for (var i = 0; i < a.length; i++) {
      expect(a[i], b[i]);
    }
  });
}
