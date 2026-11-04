// ★ r413（DA72）：均衡器（可选增强）失败**不许把起播（主功能）带死**。
//
// 真机现场：点播放后界面/通知都进入"正在播放"，却**一点声音都没有**、进度恒 0；
// logcat 逐字 `play-failure … reason=decodeFailed error=PlatformException(Error:
// java.lang.NullPointerException: Attempt to invoke virtual method 'short
// android.media.audiofx.Equalizer.getNumberOfBands()' on a null object reference…)`。
//
// 根因（`just_audio` 0.10.6）：`_setPlatformActive()` **先** `audioEffect._activate()`
// **后** `_load()`；而 `AndroidEqualizer._activate()` 要的频段参数在平台
// `audioEffectsMap` 里（Java `AudioPlayer.java:831` 的
// `audioEffectsMap.get("AndroidEqualizer")`），它要等
// `onAudioSessionIdChanged` 才填 ⇒ 首次接平台那一次是 `null` ⇒ NPE ⇒ 整个
// `load()` 塌掉。
//
// 本文件覆盖三件事：
//   ① 错误指纹判据（**别的错误不许命中**，否则会把真错误掩盖成"均衡器不可用"）；
//   ② 降级决策（只降一次、只对效果族降级）；
//   ③ 接线守卫（源码结构：`playQueue` 必须真的接上降级 + 降级后如实回不可用）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/audio/audio_effect_fallback.dart';

/// 真机 logcat 里那条错误的**逐字**形态（`PlatformException` 的 toString）。
PlatformException deviceEqualizerNpe() => PlatformException(
  code: 'Error',
  message:
      "java.lang.NullPointerException: Attempt to invoke virtual method "
      "'short android.media.audiofx.Equalizer.getNumberOfBands()' on a null "
      'object reference',
  details:
      "java.lang.NullPointerException: Attempt to invoke virtual method "
      "'short android.media.audiofx.Equalizer.getNumberOfBands()' on a null "
      'object reference',
);

void main() {
  group('① 音频效果族错误指纹', () {
    test('真机逐字那条 NPE ⇒ 命中', () {
      expect(isAudioEffectFailure(deviceEqualizerNpe()), isTrue);
    });

    test('三个指纹各自单独出现都命中', () {
      expect(
        isAudioEffectFailure('PlatformException(Error: android.media.audiofx)'),
        isTrue,
      );
      expect(
        isAudioEffectFailure('load failed: AndroidEqualizer is null'),
        isTrue,
      );
      expect(
        isAudioEffectFailure('java.lang.NullPointerException: getNumberOfBands'),
        isTrue,
      );
    });

    test('★ 别的错误**不许**命中（否则把真错误说成"均衡器不可用"）', () {
      // 鉴权（第 274 轮真机缺陷同款）
      expect(
        isAudioEffectFailure(
          PlatformException(
            code: 'Error',
            message: 'no extractor can read this stream',
          ),
        ),
        isFalse,
      );
      // 服务端 105 / 401
      expect(isAudioEffectFailure('DsmException(105, session expired)'), isFalse);
      // 网络
      expect(
        isAudioEffectFailure('SocketException: Connection refused'),
        isFalse,
      );
      // 平台通道缺失（宿主上跑）
      expect(
        isAudioEffectFailure(
          MissingPluginException('No implementation found for method load'),
        ),
        isFalse,
      );
      // 超时（`just_audio` 的 load 超时）
      expect(isAudioEffectFailure('TimeoutException after 0:00:06.000000'), isFalse);
      // 空 / null
      expect(isAudioEffectFailure(null), isFalse);
      expect(isAudioEffectFailure(''), isFalse);
    });
  });

  group('② 降级决策', () {
    test('效果族 + 还没降过 ⇒ 降级重试', () {
      expect(
        shouldFallbackToNoEqualizer(
          deviceEqualizerNpe(),
          alreadyDegraded: false,
        ),
        isTrue,
      );
    });

    test('★ 已经降过 ⇒ 不许再降（否则"失败—重建"打转）', () {
      expect(
        shouldFallbackToNoEqualizer(
          deviceEqualizerNpe(),
          alreadyDegraded: true,
        ),
        isFalse,
      );
    });

    test('★ 非效果族 ⇒ 绝不降级（真错误必须原样抛给页面分类）', () {
      expect(
        shouldFallbackToNoEqualizer(
          'DsmException(105, session expired)',
          alreadyDegraded: false,
        ),
        isFalse,
      );
      expect(
        shouldFallbackToNoEqualizer(null, alreadyDegraded: false),
        isFalse,
      );
    });
  });

  group('③ 降级流程模型（按 playQueue 的顺序走一遍）', () {
    test('★ 效果族失败 ⇒ 摘掉均衡器 + 重试一次 ⇒ 出声', () async {
      final calls = <String>[];
      var degraded = false;
      Future<String> attempt() async {
        calls.add('attempt($degraded)');
        if (!degraded) throw deviceEqualizerNpe();
        return 'playing';
      }

      Future<String> run() async {
        try {
          return await attempt();
        } catch (e) {
          if (!shouldFallbackToNoEqualizer(
            e,
            alreadyDegraded: degraded,
          )) {
            rethrow;
          }
          calls.add('degrade');
          degraded = true;
          return attempt();
        }
      }

      expect(await run(), 'playing');
      expect(calls, ['attempt(false)', 'degrade', 'attempt(true)']);
    });

    test('★ 非效果族失败 ⇒ 原样抛出、**不**降级（真错误不许被掩盖）', () async {
      var degraded = false;
      var degradedCalls = 0;
      Future<String> attempt() async => throw 'DsmException(105, session expired)';
      Future<String> run() async {
        try {
          return await attempt();
        } catch (e) {
          if (!shouldFallbackToNoEqualizer(
            e,
            alreadyDegraded: degraded,
          )) {
            rethrow;
          }
          degraded = true;
          degradedCalls++;
          return attempt();
        }
      }

      await expectLater(run(), throwsA('DsmException(105, session expired)'));
      expect(degradedCalls, 0);
    });

    test('★ 已降级还失败 ⇒ 不再重建（不许"失败—重建"打转）', () async {
      var degraded = true;
      var attempts = 0;
      Future<String> run() async {
        attempts++;
        try {
          return await Future<String>.error(deviceEqualizerNpe());
        } catch (e) {
          if (!shouldFallbackToNoEqualizer(
            e,
            alreadyDegraded: degraded,
          )) {
            rethrow;
          }
          degraded = true;
          return Future<String>.error(deviceEqualizerNpe());
        }
      }

      await expectLater(run(), throwsA(isA<PlatformException>()));
      expect(attempts, 1);
      expect(degraded, isTrue);
    });
  });

  group('④ 接线守卫（源码结构，防以后重构把降级摘掉）', () {
    late String source;

    setUpAll(() {
      source = File(
        'lib/src/features/audio/audio_player.dart',
      ).readAsStringSync();
    });

    test('playQueue 的 catch 里必须真的调降级决策 + 重建后重试一次', () {
      expect(source.contains('shouldFallbackToNoEqualizer('), isTrue);
      expect(
        source.contains('if (!shouldFallbackToNoEqualizer(e, alreadyDegraded: _equalizerDisabled))'),
        isTrue,
      );
      expect(source.contains('await _degradeWithoutEqualizer();'), isTrue);
      // 重建之后必须**再试一次**同一批 sources（否则用户还是没声音）
      final retryAt = source.indexOf('await _degradeWithoutEqualizer();');
      final tail = source.substring(retryAt);
      expect(tail.contains('setAudioSources('), isTrue);
    });

    test('降级要把均衡器从管道里摘掉（换实例，不是只改标志位）', () {
      final at = source.indexOf('Future<void> _degradeWithoutEqualizer()');
      expect(at, greaterThan(0));
      final body = source.substring(at, at + 600);
      expect(body.contains('_equalizerDisabled = true;'), isTrue);
      expect(body.contains('_player = _buildPlayer();'), isTrue);
      expect(body.contains('await old.dispose();'), isTrue);
    });

    test('管道里挂效果必须带 `!_equalizerDisabled`（摘掉后不许再挂回去）', () {
      expect(
        source.contains('if (_nativeEqAllowed && !_equalizerDisabled) _equalizer'),
        isTrue,
      );
    });

    test('降级后 equalizerInfo 立刻回 null、setEqualizerEnabled 不再打平台', () {
      // 同上：锚到**实现**那一行
      final infoAt = source.indexOf(
        'Future<AudioEqualizerInfo?> equalizerInfo() async {',
      );
      expect(infoAt, greaterThan(0));
      expect(
        source.substring(infoAt, infoAt + 400).contains(
          'if (_equalizerDisabled) return null;',
        ),
        isTrue,
      );
      // 注意：抽象接口那一行也长这样 ⇒ 必须锚到**实现**（`) async {`）
      final setAt = source.indexOf(
        'Future<void> setEqualizerEnabled(bool enabled) async {',
      );
      expect(setAt, greaterThan(0));
      expect(
        source.substring(setAt, setAt + 400).contains('if (_equalizerDisabled)'),
        isTrue,
      );
    });
  });
}
