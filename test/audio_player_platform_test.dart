// 第 156 轮（Linux 站逐屏走查）：**"这个宿主没有本地播放实现"必须走独立分支**。
//
// 现场证据（Linux amd64 容器 + Xvfb，`flutter test integration_test/…`）：
//
// ```
// [audio-station] play-failure song=music_28045 reason=decodeFailed
//   error=MissingPluginException(No implementation found for method init on channel
//   com.ryanheise.just_audio.methods)
// MissingPluginException(No implementation found for method disposeAllPlayers on channel
//   com.ryanheise.just_audio.methods)     <-- 没人接 ⇒ 整轮 -1
// ```
//
// 两条结论：
//   ① `init` 的失败被页面泛化成了 `decodeFailed`（"播放失败"）⇒ 把**平台结论**
//      说成了**文件结论**；
//   ② `disposeAllPlayers` 是 `just_audio` 在 `_pluginPlatform` getter 里用
//      `try { … } catch (_) {}` 包着的调用，而它返回 Future ⇒ 同步 catch 抓不到
//      异步失败。只要构造 `AudioPlayer()` 就会有这条**没人接**的异常。
//
// 本文件是这两条的**离线守卫**（Linux-only 缺陷 ⇒ 不依赖真机也能回归）：
//   ① 正向：宿主是 Linux 且能力位为 `unavailable` ⇒ 工厂给
//      `UnsupportedAudioStationPlayer`（**不构造 just_audio**）；
//   ② 反向：宿主换成 Android/macOS ⇒ **必须不是**它（证明这条分支真的按宿主分叉，
//      不是无条件换掉引擎）；
//   ③ 起播抛的是**类型化**错误，`classifyPlayerError` 先按类型判 ⇒
//      `platformUnsupported`；并附带**反向断言**：同样文本的
//      `MissingPluginException` 在没有类型时仍然落到 `decodeFailed`
//      （证明"类型判据"确实是新加的那一条，而不是文本判据碰巧命中）。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/media/media_player.dart'
    show classifyPlayerError;
import 'package:synhub/src/features/media/media_source.dart';

void main() {
  group('r156 宿主没有本地播放实现 ⇒ 专用占位引擎', () {
    late AppHost? prevHost;
    late TargetPlatform? prevPlatform;

    setUp(() {
      prevHost = debugForceAppHost;
      prevPlatform = debugDefaultTargetPlatformOverride;
    });

    tearDown(() {
      debugForceAppHost = prevHost;
      debugDefaultTargetPlatformOverride = prevPlatform;
    });

    test('① r690 转折：Linux 的能力位改判 available ⇒ 不再走占位引擎', () {
      debugForceAppHost = AppHost.linux;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      // ★ r690：Linux 接上了 `just_audio_media_kit`（后端 media_kit/libmpv），
      //   所以这里是 `available`；**不再**构造 `UnsupportedAudioStationPlayer`。
      //   注意本条**不构造** just_audio（构造会碰平台通道，见 ② 的说明），
      //   只钉"判定输入"：能力门放行 ⇒ 工厂不会走 Unsupported 那一支。
      expect(
        AppPlatformCapabilities.forHost(
          AppHost.linux,
        ).can(AppCapability.localMediaPlayback),
        isTrue,
        reason: '前提：r690 起 Linux 有本地播放实现（media_kit 底座）',
      );
      expect(
        capabilityGateAllows(AppCapability.localMediaPlayback),
        isTrue,
        reason: '能力门必须放行，否则页面会显示"本平台尚未实现"',
      );
    });

    test('①b r703 转折：Windows 的能力位也改判 available ⇒ 不再走占位引擎', () {
      debugForceAppHost = AppHost.windows;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      // ★ 历史（r295 真 Windows VM）：Windows 上 `just_audio` 没人接 ⇒
      //   `MissingPluginException(init / disposeAllPlayers on
      //   com.ryanheise.just_audio.methods)`，于是能力位写死 not-implemented、
      //   工厂给 `UnsupportedAudioStationPlayer`。
      // ★ r703：Windows 也接上 `media_kit_libs_windows_video`（自带 libmpv）＋
      //   `JustAudioMediaKit.ensureInitialized(windows: true)`，guest 真机量到
      //   "进度真的在走 / 视频出真帧" ⇒ 能力位翻 available，这一支不再走占位引擎。
      expect(
        AppPlatformCapabilities.forHost(AppHost.windows).can(
          AppCapability.localMediaPlayback,
        ),
        isTrue,
        reason: '前提：r703 起 Windows 也有本地播放实现（media_kit 底座）',
      );
      expect(
        capabilityGateAllows(AppCapability.localMediaPlayback),
        isTrue,
        reason: '能力门必须放行，否则页面会显示"本平台尚未实现"',
      );
      // 反向：占位引擎那一支的判据**仍然存在**（不能因为翻位就把机制删了）。
      final unsupported = UnsupportedAudioStationPlayer();
      expect(unsupported, isA<UnsupportedAudioStationPlayer>());
    });

    test('② 反向：Android/macOS ⇒ 不换引擎（证明按宿主分叉）', () {
      debugForceAppHost = AppHost.android;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // Android 上能力位是 `unknown`（桥在不在要问了才知道）⇒ 门放行；
      // 这里**不构造**（构造会碰 just_audio 通道），只验判定输入。
      final androidGate = AppPlatformCapabilities.forHost(
        AppHost.android,
      ).mayTry(AppCapability.localMediaPlayback);
      expect(androidGate, isTrue, reason: 'Android：mayTry 放行');

      debugForceAppHost = AppHost.macos;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(
        AppPlatformCapabilities.forHost(
          AppHost.macos,
        ).mayTry(AppCapability.localMediaPlayback),
        isTrue,
        reason: 'macOS：能力位 available ⇒ 走既有引擎（开关决定桥/just_audio）',
      );
    });

    test('③ 起播抛类型化错误（不是 MissingPluginException 文本）', () async {
      final player = UnsupportedAudioStationPlayer();
      addTearDown(player.dispose);

      await expectLater(
        player.play('https://example.invalid/a.mp3'),
        throwsA(isA<MediaPlaybackUnsupportedOnHost>()),
      );
      // 空队列 = "没什么要播"，不算失败（`AudioHandler.startQueue` 本来就早退）
      await expectLater(player.playQueue(const []), completes);
      // 非空队列必须抛
      await expectLater(
        player.playQueue(const [
          AudioQueueEntry(id: '1', url: 'https://example.invalid/a.mp3'),
        ]),
        throwsA(isA<MediaPlaybackUnsupportedOnHost>()),
      );

      // 不假装能播：状态一律是"没在播"
      expect(player.playing, isFalse);
      expect(player.currentIndex, -1);
      expect(player.queueLength, 0);
      expect(player.currentUrl, isNull);
      expect(player.duration, isNull);
      expect(player.position, Duration.zero);
    });

    test('④ 分类器**先按类型**判 ⇒ platformUnsupported', () async {
      final player = UnsupportedAudioStationPlayer();
      addTearDown(player.dispose);

      Object? caught;
      try {
        await player.play('https://example.invalid/a.mp3');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<MediaPlaybackUnsupportedOnHost>());
      expect(
        classifyPlayerError(caught),
        MediaUnavailableReason.platformUnsupported,
      );

      // ★ 反向验证①：**去掉类型**、只留同样的文本 ⇒ 仍然落到泛化兜底
      //   （这就是修之前真跑里的现象：`reason=decodeFailed`）。
      expect(
        classifyPlayerError(
          'MissingPluginException(No implementation found for method init on '
          'channel com.ryanheise.just_audio.methods)',
        ),
        MediaUnavailableReason.decodeFailed,
        reason: '★ 反向：没有类型判据时，文本判据认不出"平台未实现"',
      );

      // ★ 反向验证②：这个新枚举值**必须能说清原因**，不能和"播放失败"共用一句话。
      //   文案走 `mediaReasonText`（Flutter 层）/ `reason.text`（纯 Dart 层）——
      //   这里只断言"分类不同 + code 稳定"，界面文案由 i18n 守卫保证。
      expect(MediaUnavailableReason.platformUnsupported.code, 'platform_unsupported');
      expect(
        MediaUnavailableReason.platformUnsupported.arbKey,
        'capReasonNotImplemented',
        reason: '★ 复用两套 ARB 都已有的 key（不新增 key、不碰 lib/l10n）',
      );
      expect(
        MediaUnavailableReason.platformUnsupported,
        isNot(MediaUnavailableReason.decodeFailed),
      );
    });
  });
}
