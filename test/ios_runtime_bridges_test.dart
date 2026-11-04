// r689（`DA323`–`DA326`）的**宿主守卫**：iOS 四条系统集成桥的"接线是否还在"。
//
// 为什么需要这一份：模拟器上的 `integration_test/r689*` 证明的是**跑到的那一刻**
// 是通的；而这类桥最容易出的错是**静默失效**（AGENTS §2.0.55–2.0.64 第③句：
// "原生桥最易漏的是注册"）—— 文件在、Swift 写得对、但
//   ① `project.pbxproj` 的 `Sources` 里没有它 ⇒ 压根不编译；
//   ② `AppDelegate` 没 `register` ⇒ 通道没人接（`MissingPluginException`）；
//   ③ 能力位没跟着翻 ⇒ Dart 侧连通道都不碰。
// 三者缺一条，模拟器上就退化成"桥在，但界面拿不到东西"，且**编译期毫无征兆**。
//
// 本文件逐条静态断言（纯文本读取 + 能力矩阵，不依赖任何模拟器）：
//   ① 四个 Swift 文件存在，且都在 pbxproj 的 `Sources` 相位里（24 位 ID 成对）；
//   ② 四个桥都在 `AppDelegate.swift` 里 `register`（缺一个就红）；
//   ③ 能力矩阵：iOS 上四条 `available`；Android 上四条也都在（Kotlin 桥仍在）；
//      Web/Linux 上仍是 `not-implemented`（不许顺带翻别人的位）；
//   ④ 平台差异写进了代码注释（`uidRx=-1`、`airplay`、`MTAudioProcessingTap`）——
//      防"以后有人把 iOS 的流量桥改成编一个按 App 的数"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/platform/app_platform.dart';

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '缺文件：$path');
  return f.readAsStringSync();
}

/// iOS target 里"这个 Swift 文件被编译"的判据：
/// `PBXBuildFile` ＋ `PBXFileReference` ＋ `Sources` 相位三处都有它的名字。
void _expectCompiled(String pbx, String name, String id) {
  expect(pbx.contains('$name in Sources'), isTrue, reason: '$name 不在 Sources 相位');
  expect(pbx.contains(name), isTrue);
  // ★ 24 个十六进制字符：多写几位 `plutil` 仍 OK、`xcodebuild` 仍"成功"，
  //   但 `PBXFileReference` 静默不生效（r688 踩过）。
  expect(id.length, 24, reason: '$name 的 pbxproj ID 不是 24 字符');
  expect(RegExp(r'^[0-9A-F]{24}$').hasMatch(id), isTrue, reason: '$name 的 ID 不是纯十六进制');
  expect(pbx.contains('$id /* $name */'), isTrue, reason: '$name 的 FileReference 不存在');
  expect(pbx.contains('fileRef = $id'), isTrue, reason: '$name 的 BuildFile 没指向它');
}

void main() {
  group('r689 iOS 四条系统集成桥（宿主守卫，不需要模拟器）', () {
    test('① DA323 抽帧：四个 Swift 文件存在且都在 iOS target 的 Sources 里', () {
      final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
      _expectCompiled(pbx, 'VideoFrameBridge.swift', 'AB02F00000000000000000A1');
      _expectCompiled(pbx, 'TrafficAndCastBridge.swift', 'AB02F00000000000000000A2');
      _expectCompiled(pbx, 'AudioVisualizerBridge.swift', 'AB02F00000000000000000A3');
      for (final f in const [
        'ios/Runner/VideoFrameBridge.swift',
        'ios/Runner/TrafficAndCastBridge.swift',
        'ios/Runner/AudioVisualizerBridge.swift',
      ]) {
        expect(_read(f).length, greaterThan(1000), reason: '$f 内容可疑（太短）');
      }
      // 抽帧 / 流量 / 投屏 / 频谱四条关键字都在各自的实现里
      expect(_read('ios/Runner/VideoFrameBridge.swift'), contains('AVAssetImageGenerator'));
      final tc = _read('ios/Runner/TrafficAndCastBridge.swift');
      expect(tc, contains('getifaddrs'));
      expect(tc, contains('AVRouteDetector'));
      expect(tc, contains('AVRoutePickerView'));
      final av = _read('ios/Runner/AudioVisualizerBridge.swift');
      expect(av, contains('MTAudioProcessingTapCreate'));
      expect(av, contains('vDSP_fft_zrip'));
    });

    test('② DA323/DA324/DA325/DA326 寄存点都在 AppDelegate 里（漏一个 = 通道没人接）', () {
      final app = _read('ios/Runner/AppDelegate.swift');
      expect(app, contains('VideoFrameBridge.register'));
      expect(app, contains('TrafficBridge.register'));
      expect(app, contains('CastBridge.register'));
      expect(app, contains('AudioVisualizerBridge.register'));
      // registrar 必须从 pluginRegistry 里取（不能自己 new 一个 messenger）
      // registrar 必须从 `pluginRegistry.registrar(forPlugin:` 取（跨行写法也要认）
      expect(app, contains('pluginRegistry.registrar('));
    });

    test('③ DA323/DA324/DA325/DA326 能力矩阵：iOS 四条全 available，别人一位没动', () {
      final ios = staticCapabilitiesFor(AppHost.ios);
      for (final c in const [
        AppCapability.videoFrameExtraction,
        AppCapability.networkTrafficCounters,
        AppCapability.cast,
        AppCapability.audioVisualizer,
      ]) {
        expect(ios.can(c), isTrue, reason: 'iOS 上 ${c.name} 必须 available（r689 已接线）');
      }
      // Android：Kotlin 那四份桥仍在 ⇒ 不许因为加 iOS 而把 Android 弄没
      final android = staticCapabilitiesFor(AppHost.android);
      for (final c in const [
        AppCapability.videoFrameExtraction,
        AppCapability.audioVisualizer,
        AppCapability.cast,
      ]) {
        expect(android.statusOf(c).isUnavailable, isFalse, reason: 'Android 上 ${c.name} 掉档了');
      }
      // ★ 反向：Web / Linux 上这四条必须仍然"没有实现"（不许顺手翻位）
      for (final host in const [AppHost.web, AppHost.linux]) {
        final caps = staticCapabilitiesFor(host);
        for (final c in const [
          AppCapability.videoFrameExtraction,
          AppCapability.networkTrafficCounters,
          AppCapability.cast,
          AppCapability.audioVisualizer,
        ]) {
          expect(caps.statusOf(c).isUnavailable, isTrue, reason: '${host.name}+${c.name} 被翻了');
        }
      }
    });

    test('④ DA324/DA325/DA326 平台差异必须写在代码里（iOS 上不许编"按 App 的流量"）', () {
      final tc = _read('ios/Runner/TrafficAndCastBridge.swift');
      // iOS 没有按 UID 的计数 API ⇒ 必须如实 -1（Dart 的 supported 会跟着 false）
      expect(tc, contains('"uidRx": -1'));
      expect(tc, contains('"uidTx": -1'));
      expect(tc, contains('没有按 App'));
      // 投屏在 iOS 上是 AirPlay，`kind` 必须能区分
      expect(tc, contains('"kind": "airplay"'));
      // 照片投送（Cast 命名空间）在 iOS 上没有等价物 ⇒ 如实 false
      expect(tc, contains('no-cast-namespace-on-ios'));

      final av = _read('ios/Runner/AudioVisualizerBridge.swift');
      // 静音铁律：测试/实现里不许出现"靠音量找人"的做法
      // tap 必须挂在 post-effects 位置（`kMTAudioProcessingTapCreationFlag_PostEffects`）
      expect(av, contains('kMTAudioProcessingTapCreationFlag_PostEffects'));
      expect(av, contains('不许'), reason: '文件里必须留下"实时线程不许 allocate"的说明');

      // ★ 单声道非交错只有 1 个 buffer —— r689 的 bug 就栽在这条，
      //   修法必须留在代码里（判据只认 ASBD 标志，不看 buffers.count）
      expect(av, contains('kAudioFormatFlagIsNonInterleaved'));
      expect(av, contains('buffers.count'));
    });

    test('⑤ DA326 Dart 侧接线：iOS 播放器实现 AudioSpectrumSession', () {
      final nasp = _read('lib/src/features/audio/native_audio_station_player.dart');
      expect(nasp, contains('AudioSpectrumSession'));
      expect(nasp, contains('androidAudioSessionId'));
      // 合成本地代数（iOS 拿不到 AVPlayer 的会话号）
      expect(nasp, contains('_created ? 1 : null'));
    });

    test('⑥ DA326 静音铁律：频谱的集成用例不许出现能听见的探针', () {
      // ★ 只盯"会起播"的那个用例；`r689_ios_runtime_bridges_test.dart` 全程不碰音频。
      for (final f in const [
        'integration_test/r689b_ios_spectrum_test.dart',
      ]) {
        final src = _read(f);
        // ★ 判据钉"起播动作"而不是"构造"：`NativeAudioStationPlayer()` 允许出现
        //   （用来断言它实现了 `AudioSpectrumSession`），但**不许**用它 `.play(`
        //   ——它把 `volume: 1.0` 写死，会让测试真的出声（用户 2026-10-30 被吓到过）。
        expect(RegExp(r'(player|_?playerInstance)\.play\(').hasMatch(src), isFalse,
            reason: '$f 用播放器起播 ⇒ 可能出声；请走 `muted: true, volume: 0` 的桥');
        // 必须有"静音"声明（`muted: true` ＋ `volume: 0.0`，两道都上）
        expect(src, contains('muted: true'), reason: '$f 没声明静音播放');
        expect(src, contains('volume: 0.0'), reason: '$f 没把音量压到 0');
      }
      // ★ 反向自证：`r689` 那条用例里**一个** `autoplay: true` 都不许有
      //   （它只验抽帧/流量/投屏，任何起播都会出声）。
      final other = _read('integration_test/r689_ios_runtime_bridges_test.dart');
      expect(other.contains('autoplay: true'), isFalse);
    });
  });
}
