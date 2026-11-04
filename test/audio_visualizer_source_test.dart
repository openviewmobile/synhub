// 律动**电平来源**的回归用例（第 274 轮用户报障：「没有播放视觉特效」）。
//
// 要钉住的事：
//   ① 来源选择是**纯函数**，三条门槛（Android / RECORD_AUDIO 已授予 / 桥可用）
//      缺一即回落 —— 八种组合逐个验；
//   ② **回落要诚实**：推导动效的说明句只能说「律动动效」，
//      只有真频谱才允许出现"频谱"两个字（这是本仓的既有铁律，别改回去）；
//   ③ 桥的客户端在**非 Android / 宿主**上不碰平台通道（返回明确的 reason），
//      所以测试环境不会因为通道缺失而抛；
//   ④ 来源原因串可被 logcat grep（`audio-visual-src`）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/audio_visualizer.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/audio_visualizer_source.dart';

void main() {
  group('来源选择（纯函数，八种组合）', () {
    test('三条都满足 → 真频谱', () {
      expect(
        chooseAudioVisualSource(
          isAndroid: true,
          hasRecordAudioPermission: true,
          bridgeAttached: true,
        ),
        AudioVisualSource.platformSpectrum,
      );
    });

    test('不是 Android → 推导（宿主/测试环境没有平台通道）', () {
      for (final perm in [true, false]) {
        for (final bridge in [true, false]) {
          expect(
            chooseAudioVisualSource(
              isAndroid: false,
              hasRecordAudioPermission: perm,
              bridgeAttached: bridge,
            ),
            AudioVisualSource.derived,
          );
        }
      }
    });

    test('★ 权限没授予 → 推导（**绝不因此弹权限框**）', () {
      for (final android in [true, false]) {
        for (final bridge in [true, false]) {
          expect(
            chooseAudioVisualSource(
              isAndroid: android,
              hasRecordAudioPermission: false,
              bridgeAttached: bridge,
            ),
            AudioVisualSource.derived,
            reason: 'Visualizer 官方文档逐字要求 RECORD_AUDIO；'
                '音频站页面以前从不问麦克风，不能因为动效突然弹窗',
          );
        }
      }
    });

    test('桥挂不上（平台不支持 / 会话 id 拿不到）→ 推导', () {
      for (final android in [true, false]) {
        for (final perm in [true, false]) {
          expect(
            chooseAudioVisualSource(
              isAndroid: android,
              hasRecordAudioPermission: perm,
              bridgeAttached: false,
            ),
            AudioVisualSource.derived,
          );
        }
      }
    });
  });

  group('说明句必须与来源一致（不许把推导说成频谱）', () {
    test('推导 → 「律动动效」，**不含**"频谱"', () {
      final s = audioVisualizerCaptionFor(AudioVisualSource.derived);
      expect(s, isNotEmpty);
      expect(s.contains('频谱'), isFalse);
      // 与既有 `audioVisualizerCaptionText()` 是同一句
      expect(s, audioVisualizerCaptionText());
    });

    test('真频谱 → 明说"真实频谱"', () {
      final s = audioVisualizerCaptionFor(AudioVisualSource.platformSpectrum);
      expect(s.contains('真实频谱'), isTrue);
    });

    test('原因串可 grep（同前缀 audio-visual-src）', () {
      for (final s in AudioVisualSource.values) {
        expect(audioVisualSourceReason(s), startsWith('audio-visual-src '));
      }
      expect(
        audioVisualSourceReason(AudioVisualSource.platformSpectrum),
        contains('platform-spectrum'),
      );
      expect(
        audioVisualSourceReason(AudioVisualSource.derived),
        contains('derived'),
      );
    });
  });

  group('桥客户端在宿主上不碰平台通道', () {
    const client = AudioVisualizerBridgeClient();

    // ★ 第 279 轮：原因码从 `not-android` 改成**平台能力层**给的原因码。
    //   语义没变（宿主上照样"不碰通道、直接给明确原因"），变的是这句话
    //   现在由 `AppPlatformCapabilities` 统一给出，桌面三平台都是
    //   `not-implemented-on-host`（Android 上是 `unknown` ⇒ 放过去试桥）。
    final hostReason = AppPlatformCapabilities.current()
        .reasonOf(AppCapability.audioVisualizer);

    test('probe：非 Android → available=false + 明确原因', () async {
      final r = await client.probe();
      expect(r.available, isFalse);
      expect(r.reason, hostReason);
      expect(r.reason, 'not-implemented-on-host'); // 桌面三平台一致性断言
    });

    test('attach：非 Android / 会话 id 非法 → 直接拒，不调通道', () async {
      expect(
        (await client.attach(sessionId: 7, bars: 28)).reason,
        hostReason,
      );
      expect(
        (await client.attach(sessionId: 0, bars: 28)).reason,
        hostReason,
      );
    });

    test('detach：非 Android → 静默返回（不抛）', () async {
      await client.detach();
    });
  });

  group('视图：真频谱与推导动效的说明句真的切了', () {
    Future<void> pump(WidgetTester tester, List<double>? levels) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Center(
              child: AudioVisualizer(
                playing: true,
                position: const Duration(seconds: 3),
                duration: const Duration(seconds: 120),
                barCount: 8,
                size: const Size(120, 120),
                spectrumLevels: levels,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    testWidgets('有真频谱 → 说明句写「真实频谱」', (tester) async {
      await pump(tester, const [0.1, 0.4, 0.9, 0.2, 0.5, 0.3, 0.7, 0.6]);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('audio-visualizer-caption')))
            .data,
        audioVisualizerCaptionFor(AudioVisualSource.platformSpectrum),
      );
      // 画布在（动效真的渲染了）
      expect(find.byKey(const Key('audio-visualizer-canvas')), findsOneWidget);
    });

    testWidgets('没有真频谱 → 说明句写「律动动效」，且不含"频谱"', (tester) async {
      await pump(tester, null);
      final caption = tester
          .widget<Text>(find.byKey(const Key('audio-visualizer-caption')))
          .data;
      expect(caption, audioVisualizerCaptionFor(AudioVisualSource.derived));
      expect(caption!.contains('频谱'), isFalse);
    });

    testWidgets('长度不对的频谱 → 当作没有（宁可退回推导，也不画错位的柱子）', (
      tester,
    ) async {
      await pump(tester, const [0.5, 0.5]); // barCount 是 8
      final caption = tester
          .widget<Text>(find.byKey(const Key('audio-visualizer-caption')))
          .data;
      expect(caption, audioVisualizerCaptionFor(AudioVisualSource.derived));
    });

    testWidgets('暂停后画面停住（不回到推导曲线），说明句也保持不变', (tester) async {
      await pump(tester, const [0.2, 0.8, 0.4, 0.6, 0.1, 0.9, 0.3, 0.5]);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Center(
              child: AudioVisualizer(
                playing: false,
                position: const Duration(seconds: 3),
                duration: const Duration(seconds: 120),
                barCount: 8,
                size: const Size(120, 120),
                spectrumLevels: null, // 停了之后来源断了
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('audio-visualizer-caption')))
            .data,
        audioVisualizerCaptionFor(AudioVisualSource.platformSpectrum),
      );
    });
  });
}
