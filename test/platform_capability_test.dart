// 平台能力层 + 路径层的守卫用例（第 279 轮新增）。
//
// 这一组用例存在的理由（都是"以后会悄悄坏掉"的地方）：
//   ① **横竖都不能崩**：宿主上 `MissingPluginException` 是**预期路径**，
//      必须映射成 `unavailable:bridge-missing`，而不是抛穿到界面；
//   ② **三态不许塌成两态**：`unknown`（没问完）与 `unavailable`（问了说不能）
//      必须可区分 —— 一律塌成 `false` 就会重演 §2.0.6 的"冷启动把端侧降级"；
//   ③ **`can()` 只认 available**：不许把"探测中"当"能用"（假装能用）；
//   ④ **每台宿主 × 每个能力都有条目**：加平台/加能力时忘了填表要当场红；
//   ⑤ **路径裁决**：`Android/media` 收件箱在桌面上必须**不存在**（不是报错），
//      `/storage/emulated/0` 只在 Android 上出现；
//   ⑥ **原因码是 ASCII 机器码**（不许混中文，否则就退化成"给人看的句子"，
//      没法当判据 —— 与 `i18n_coverage_test` 同一口径）。
//
// 宿主测试跑在 macOS 上 ⇒ 天然覆盖 macOS 那一列；其余平台用
// `debugForceAppHost` 强制（与 `media_tls_policy.dart` 的 `debugForceAndroid`
// 同一手法，**生产不使用**）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_paths.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/net/device_traffic.dart';
import 'package:synhub/src/features/chat/chat_deep_link.dart';
import 'package:synhub/src/features/files/file_shortcut.dart';
import 'package:synhub/src/features/files/media_store_save.dart';

/// 每个 [AppCapability] 都有一条结论。
void expectComplete(AppPlatformCapabilities caps) {
  for (final c in AppCapability.values) {
    final s = caps.statusOf(c);
    expect(s.capability, c, reason: '${caps.host.name}/${c.name} 缺条目');
    expect(s.reason, isNotEmpty, reason: '${caps.host.name}/${c.name} 没有原因码');
  }
}

void main() {
  // 第 55 轮：反向验证要装假通道 handler ⇒ 需要 Flutter binding。
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    debugForceAppHost = null;
    debugForceCapabilityGate = false;
  });

  group('宿主识别', () {
    test('可强制指定宿主，且 afterEach 复原', () {
      final real = detectAppHost();
      debugForceAppHost = AppHost.android;
      expect(currentAppHost, AppHost.android);
      debugForceAppHost = null;
      expect(currentAppHost, real);
    });

    test('宿主分类谓词', () {
      expect(AppHost.android.isMobile, isTrue);
      expect(AppHost.ios.isMobile, isTrue);
      expect(AppHost.macos.isMobile, isFalse);
      expect(AppHost.macos.isDesktop, isTrue);
      expect(AppHost.macos.isApple, isTrue);
      expect(AppHost.linux.isApple, isFalse);
      expect(AppHost.web.isMobile, isFalse);
      expect(AppHost.web.isDesktop, isFalse);
    });
  });

  group('静态表：每台宿主 × 每个能力都有条目', () {
    for (final host in AppHost.values) {
      test('${host.name}: 表是完整的，且原因码是 ASCII 机器码', () {
        final caps = staticCapabilitiesFor(host);
        expectComplete(caps);
        for (final c in AppCapability.values) {
          final s = caps.statusOf(c);
          expect(
            RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(s.reason),
            isTrue,
            reason: '${host.name}/${c.name} 原因码不是 kebab-case ASCII: ${s.reason}',
          );
          // 原因码**不许**混中日韩（那就没法当判据了）
          expect(
            RegExp(r'[\u3000-\u9fff\uff00-\uffef]').hasMatch(s.reason),
            isFalse,
            reason: '${host.name}/${c.name} 原因码混了中文: ${s.reason}',
          );
        }
      });
    }

    test('diagLines 覆盖全部能力、一行一条', () {
      final caps = staticCapabilitiesFor(AppHost.macos);
      expect(caps.diagLines.length, AppCapability.values.length);
      for (final line in caps.diagLines) {
        expect(line, contains('='));
        expect(line, contains('('));
      }
    });
  });

  group('macOS 列（宿主测试天然覆盖）', () {
    final caps = staticCapabilitiesFor(AppHost.macos);

    test('本地播放可用（just_audio/video_player 的 darwin 实现随包）', () {
      expect(caps.can(AppCapability.localMediaPlayback), isTrue);
      expect(caps.statusOf(AppCapability.localMediaPlayback).reason, 'ok');
    });

    test('离屏渲染可用（纯 Dart，与宿主无关）', () {
      expect(caps.can(AppCapability.officeOffscreenRender), isTrue);
    });

    test('文档选择器可用（file_picker_darwin = NSOpenPanel）', () {
      expect(caps.can(AppCapability.documentPicker), isTrue);
    });

    test('Kotlin-only 的桥在 macOS 上一律 unavailable（不是 unknown）', () {
      for (final c in const [
        AppCapability.videoFrameExtraction,
        AppCapability.audioVisualizer,
        AppCapability.networkTrafficCounters,
        AppCapability.cast,
        AppCapability.homeScreenWidgets,
      ]) {
        final s = caps.statusOf(c);
        expect(s.isUnavailable, isTrue, reason: c.name);
        expect(s.reason, CapabilityReason.notImplementedOnHost, reason: c.name);
        expect(caps.can(c), isFalse);
        expect(caps.mayTry(c), isFalse, reason: '确定不能的能力不该去碰通道');
      }
    });

    test('后台保活是"结构上没有"（macOS 无前台服务语义，App Nap 会降频）', () {
      expect(
        caps.statusOf(AppCapability.backgroundExecution).reason,
        CapabilityReason.notSupportedOnHost,
      );
    });

    test('桌面**不编**手机硬件事实（AGENTS §2.0.6 第 3 条）', () {
      expect(
        caps.statusOf(AppCapability.deviceHardwareInfo).reason,
        CapabilityReason.needsMobileHost,
      );
    });

    test('macOS 的静态表一条 unknown 都没有（零通道调用）', () {
      final unknown = [
        for (final c in AppCapability.values)
          if (caps.statusOf(c).isUnknown) c.name,
      ];
      expect(unknown, isEmpty);
    });
  });

  group('Android / iOS 列', () {
    test('Android：桥能力是 unknown（未知待探测），不是 available', () {
      final caps = staticCapabilitiesFor(AppHost.android);
      for (final c in const [
        AppCapability.videoFrameExtraction,
        AppCapability.audioVisualizer,
        AppCapability.networkTrafficCounters,
        AppCapability.cast,
        AppCapability.backgroundExecution,
        AppCapability.homeScreenWidgets,
        AppCapability.localNotifications,
        AppCapability.documentPicker,
        AppCapability.deviceHardwareInfo,
      ]) {
        final s = caps.statusOf(c);
        expect(s.isUnknown, isTrue, reason: c.name);
        expect(s.reason, CapabilityReason.probePending, reason: c.name);
        // ★ 关键：`can` 不认 unknown（不假装能用），`mayTry` 认（放过去试桥）
        expect(caps.can(c), isFalse, reason: c.name);
        expect(caps.mayTry(c), isTrue, reason: c.name);
      }
    });

    test('iOS：播放/文档选择/离屏渲染/Keychain 可用；Kotlin-only 的明确"未实现"', () {
      final caps = staticCapabilitiesFor(AppHost.ios);
      // 正向：iOS 上真有实现的四项 —— 每项的依据逐条写在
      // `app_platform.dart` 的 iOS 分支注释里（不许"顺手"加一项而不写依据）。
      for (final c in const [
        AppCapability.localMediaPlayback,
        AppCapability.documentPicker,
        AppCapability.officeOffscreenRender,
        // ★ 第 92 轮：iOS 走 Keychain（`flutter_secure_storage` 的 darwin 插件
        //   同时声明 ios+macos），与 macOS 同一份实现 ⇒ 从 `unavailable` 改判。
        AppCapability.secureStorage,
      ]) {
        expect(caps.can(c), isTrue, reason: c.name);
        expect(caps.mayTry(c), isTrue, reason: c.name);
        expect(caps.reasonOf(c), CapabilityReason.ok, reason: c.name);
      }
      // 反向：Kotlin-only 的桥在 iOS 上必须**拦住**（既不静默失败、也不假装能用）
      for (final c in const [
        // ★ r689：`videoFrameExtraction`（AVAssetImageGenerator）/
        //   `networkTrafficCounters`（getifaddrs）/ `cast`（AirPlay）/
        //   `audioVisualizer`（MTAudioProcessingTap + vDSP）**四条已全部退出这份
        //   名单** —— iOS 上"未实现"的能力位到此为零，见下面的 available 全集用例。
        // ★ r688：`homeScreenWidgets` 已从这份名单退出（WidgetKit 扩展落地）。
        // ★ r682：`backgroundExecution` / `localNotifications` 已从这份名单退出
        //   （`BackgroundBridge.swift` 落地），见下面的 available 全集用例。
        AppCapability.mediaStoreExport,
        AppCapability.localMediaLibrary,
        // ★ r687：`systemShare` 已从这份名单退出（`ShareBridge.swift` 的
        //   `UIActivityViewController` 落地），见 available 全集用例。
        AppCapability.systemOpen,
        AppCapability.driveSafSession,
        AppCapability.oemCompat,
        AppCapability.downloadNotifications,
        AppCapability.networkInfo,
        AppCapability.audioEqualizer,
        AppCapability.deviceLocation,
        AppCapability.driveWatch,
        AppCapability.noteReminders,
        AppCapability.scheduledNoteSync,
        AppCapability.photoBackup,
        AppCapability.sleepBackup,
        AppCapability.fileShortcut,
      ]) {
        expect(caps.statusOf(c).isUnavailable, isTrue, reason: c.name);
        expect(caps.mayTry(c), isFalse, reason: c.name);
        expect(caps.can(c), isFalse, reason: c.name);
      }
    });

    test('★ 反向：iOS 的 available 集合**恰好**是这 14 项（多了少了都要红）', () {
      final caps = staticCapabilitiesFor(AppHost.ios);
      final allowed = [
        for (final c in AppCapability.values)
          if (caps.can(c)) c.name,
      ]..sort();
      // r680：`deepLink` 进榜 —— `ios/Runner/DeepLinkBridge.swift` ＋
      // `Info.plist` 的 `CFBundleURLTypes` 成对落地（两个文件缺一条，
      // 模拟器上 `simctl openurl` 就打不进来，见 `docs/platform-ios.md` §18）。
      // r681：`deviceHardwareInfo` 进榜 —— `ios/Runner/DeviceCapabilityBridge.swift`
      // 随包编译（读 ProcessInfo / sysctl / Metal），与 Android 的 Kotlin 桥同档
      // ⇒ 静态 `available`（读数见 `docs/platform-ios.md` §19）。
      // r682：`backgroundExecution`（后台执行窗口 + BGAppRefreshTask）与
      // `localNotifications`（UNUserNotificationCenter）也进榜。
      // r687：`systemShare` 进榜 —— `ios/Runner/ShareBridge.swift` 的
      // `UIActivityViewController`（通道 `synhub/share_text` ＋ `synhub/media_open`）。
      // r688：`homeScreenWidgets` 进榜 —— `ios/Widget/SynHubHomeWidget.swift`
      // 的 WidgetKit 扩展（App 侧 `WidgetBridge.swift` 写 App Group 快照）。
      // r689：`videoFrameExtraction` / `networkTrafficCounters` / `cast` 进榜 ——
      // `ios/Runner/VideoFrameBridge.swift`（AVAssetImageGenerator）与
      // `ios/Runner/TrafficAndCastBridge.swift`（getifaddrs / AirPlay）随包编译。
      // ★ 注意 `networkTrafficCounters`：**静态 available 不等于"能按 App 计量"** ——
      // iOS 没有按 UID 的计数 API，桥如实回 -1（Dart `supported == false`）。
      // r689：`audioVisualizer` 也进榜（`MTAudioProcessingTap` + vDSP FFT）。
      expect(allowed, const [
        'audioVisualizer',
        'backgroundExecution',
        'cast',
        'deepLink',
        'deviceHardwareInfo',
        'documentPicker',
        'homeScreenWidgets',
        'localMediaPlayback',
        'localNotifications',
        'networkTrafficCounters',
        'officeOffscreenRender',
        'secureStorage',
        'systemShare',
        'videoFrameExtraction',
      ]);
      expect(caps.can(AppCapability.deviceHardwareInfo), isTrue);
      // 每一条能力都必须有结论（不许留洞）
      expectComplete(caps);
    });

    test('★ 反向：安全存储只给"插件列里真的有它"的五家，web/unknown 必须拦住', () {
      // ★★ 第 108 轮（Linux 站）口径修正：这条用例原来叫
      //    「Keychain 只给手机+Apple 三家，Linux/Windows 必须拦住」。
      //    Linux 从"拦住"改成"放行"**不是放宽**，而是纠一个事实错误：
      //    `flutter_secure_storage_linux` 3.0.3 **本来就随包解析进来了**，
      //    而且 `linux/flutter/generated_plugin_registrant.cc` 这份**生成产物**
      //    里就注册着它（下面的 in-repo 取证断言钉死这一点）。
      //    原来把 Linux 归到"拦住"那一侧，真实后果是 Linux 上凭据只能明文落盘
      //    —— 与第 42 轮 macOS、第 92 轮 iOS 是**同一个漏的第三次**。
      // ★★ 第 293 轮（Windows 站）是**第四次**：`flutter_secure_storage_windows`
      //    4.2.2 同样在依赖与生成注册表里，而真 Windows 上的探针显示
      //    `seal()` 被能力层**和** keeper 双双挡在插件之外
      //    （`isSupported=false capAllowed=false hostSupports=false`）⇒ 明文落盘。
      //    见 `docs/platform-windows.md` §15。
      for (final host in const [
        AppHost.android,
        AppHost.macos,
        AppHost.ios,
        AppHost.linux,
        AppHost.windows,
      ]) {
        expect(
          staticCapabilitiesFor(host).can(AppCapability.secureStorage),
          isTrue,
          reason: host.name,
        );
      }
      // 两家必须拦住，而且**原因码要逐家对得上**（不是一句"反正 false"）：
      //   * web：结构上没有这个概念 ⇒ `not-supported-on-host`；
      //   * unknown：连宿主都认不出来 ⇒ `bridge-missing`。
      const expectedReason = {
        AppHost.web: CapabilityReason.notSupportedOnHost,
        AppHost.unknown: CapabilityReason.bridgeMissing,
      };
      for (final host in const [
        AppHost.web,
        AppHost.unknown,
      ]) {
        final caps = staticCapabilitiesFor(host);
        expect(
          caps.can(AppCapability.secureStorage),
          isFalse,
          reason: host.name,
        );
        expect(
          caps.mayTry(AppCapability.secureStorage),
          isFalse,
          reason: host.name,
        );
        expect(
          caps.reasonOf(AppCapability.secureStorage),
          expectedReason[host],
          reason: '${host.name}：要给得出机器可读原因，不许静默',
        );
      }
    });

    test('★ Linux 放行的**依据**必须能在仓库里核到（否则这条结论就是编的）', () {
      // 结论 = "Linux 有平台安全存储"。依据 = 两个**生成/锁定的产物**：
      //   ① `.flutter-plugins-dependencies` 的 linux 列里有该插件；
      //   ② `linux/flutter/generated_plugin_registrant.cc` 里注册了它。
      // 少了任何一条，上面那条"放行"就该被推翻 —— 所以这里直接读文件断言，
      // 让"能力层说了可 Linux 上其实没有"这种漂移在离线测试里就红。
      final deps = File('.flutter-plugins-dependencies').readAsStringSync();
      final linux = (jsonDecode(deps)
          as Map<String, Object?>)['plugins'] as Map<String, Object?>;
      final linuxPlugins = (linux['linux'] as List<Object?>)
          .map((e) => (e as Map<String, Object?>)['name'])
          .toList();
      expect(
        linuxPlugins,
        contains('flutter_secure_storage_linux'),
        reason: '.flutter-plugins-dependencies 的 linux 列里没有安全存储插件',
      );

      final registrar = File(
        'linux/flutter/generated_plugin_registrant.cc',
      ).readAsStringSync();
      expect(
        registrar,
        contains('flutter_secure_storage_linux'),
        reason: 'Linux 插件注册表里没有注册安全存储插件 ⇒ Linux 上的 '
            '`secureStorage: available` 结论不成立',
      );
      // ★ 反向：注册表里**同样不该**出现根本不支持 Linux 的插件
      //   （证明这份取证不是"看到啥都算数"）。
      for (final bogus in const ['just_audio', 'video_player', 'pdfx']) {
        expect(
          registrar,
          isNot(contains(bogus)),
          reason: '$bogus 没有 Linux 实现，不该出现在 Linux 注册表里',
        );
      }
    });

    test('★ 第 293 轮：Windows 放行的**依据**同样必须能在仓库里核到', () {
      // 与上面 Linux 那条同型：结论 = "Windows 有平台安全存储"，
      // 依据 = ① `.flutter-plugins-dependencies` 的 windows 列里有该插件；
      //        ② `windows/flutter/generated_plugin_registrant.cc`（生成产物）
      //           里注册了它；③ `pubspec.lock` 里是 4.2.2。
      // 少了任何一条，Windows 那一位 `available` 就该被推翻。
      final deps = File('.flutter-plugins-dependencies').readAsStringSync();
      final plugins =
          (jsonDecode(deps) as Map<String, Object?>)['plugins'] as Map<String, Object?>;
      final windowsPlugins = (plugins['windows'] as List<Object?>)
          .map((e) => (e as Map<String, Object?>)['name'])
          .toList();
      expect(
        windowsPlugins,
        contains('flutter_secure_storage_windows'),
        reason: '.flutter-plugins-dependencies 的 windows 列里没有安全存储插件',
      );

      final registrar =
          File('windows/flutter/generated_plugin_registrant.cc').readAsStringSync();
      expect(
        registrar,
        contains('FlutterSecureStorageWindowsPluginRegisterWithRegistrar('),
        reason: 'Windows 插件注册表里没有注册安全存储插件 ⇒ Windows 上的 '
            '`secureStorage: available` 结论不成立',
      );
      expect(
        File('windows/flutter/generated_plugins.cmake').readAsStringSync(),
        contains('flutter_secure_storage_windows'),
        reason: 'generated_plugins.cmake 没把该插件挂进构建 ⇒ 注册表是空壳',
      );
      final lock = File('pubspec.lock').readAsStringSync();
      expect(lock, contains('flutter_secure_storage_windows:'));
      expect(lock, contains('version: "4.2.2"'));

      // ★ 反向：Windows 注册表里**不该**出现没有 Windows 实现的插件
      //   （证明这份取证不是"看到啥都算数"）。
      for (final bogus in const ['just_audio', 'video_player', 'flutter_secure_storage_linux']) {
        expect(
          registrar,
          isNot(contains(bogus)),
          reason: '$bogus 没有 Windows 实现，不该出现在 Windows 注册表里',
        );
      }
    });
  });

  group('Linux / Windows / web / unknown 列', () {
    // ★ r690：两家在这一格上**分开**了 —— Linux 接上了 `just_audio_media_kit`
    //   + `media_kit_libs_linux`（audio 与 video 都换成 media_kit 底座），
    //   Windows 仍是 `not-implemented-on-host`（Windows 那一份 media_kit 库
    //   没装、也没验过，不许顺手改）。这条用例的存在意义正是钉住这个分叉。
    test('r690：Linux 本地播放 = available（media_kit 底座）', () {
      final s = staticCapabilitiesFor(
        AppHost.linux,
      ).statusOf(AppCapability.localMediaPlayback);
      expect(s.isAvailable, isTrue);
      expect(s.reason, CapabilityReason.ok);
    });
    for (final host in const [AppHost.windows]) {
      // ★ r703：Windows 的本地播放**已接上**（`media_kit_libs_windows_video` 带
      //   libmpv + `main()` 两个 ensureInitialized + guest 真机进度/画面读数）。
      test('${host.name}: 本地播放 = available:ok（r703 翻位）', () {
        final caps = staticCapabilitiesFor(host);
        final s = caps.statusOf(AppCapability.localMediaPlayback);
        expect(s.isAvailable, isTrue);
        expect(s.reason, CapabilityReason.ok);
      });

      test('${host.name}: 本地播放不再是"未实现"（反向）', () {
        final s = staticCapabilitiesFor(host)
            .statusOf(AppCapability.localMediaPlayback);
        expect(s.reason, isNot(CapabilityReason.notImplementedOnHost));
      });

      test('${host.name}: 主屏小组件是"结构上没有"', () {
        expect(
          staticCapabilitiesFor(host)
              .statusOf(AppCapability.homeScreenWidgets)
              .reason,
          CapabilityReason.notSupportedOnHost,
        );
      });
    }

    test('web / unknown：全部 unavailable，且不抛', () {
      for (final host in const [AppHost.web, AppHost.unknown]) {
        final caps = staticCapabilitiesFor(host);
        expectComplete(caps);
        for (final c in AppCapability.values) {
          expect(caps.can(c), isFalse, reason: '${host.name}/${c.name}');
        }
      }
    });
  });

  group('探测：桥缺失不许崩（宿主上的预期路径）', () {
    Future<AppPlatformCapabilities> probeWith(Object Function() boom) =>
        probeAppCapabilities(
          base: staticCapabilitiesFor(AppHost.android),
          timeout: null,
          probe: (channel, method) async => throw boom(),
        );

    test('MissingPluginException → unavailable:bridge-missing（不抛）', () async {
      final caps = await probeWith(() => MissingPluginException('no bridge'));
      final s = caps.statusOf(AppCapability.videoFrameExtraction);
      expect(s.isUnavailable, isTrue);
      expect(s.reason, CapabilityReason.bridgeMissing);
      expect(s.bridge, 'synhub/video_frame');
      // 其它条目也都被解成同一个结论（一条都不留 unknown 才算"问完了"）
      expect(
        caps.entries.values.where((e) => e.isUnknown),
        isEmpty,
      );
    });

    test('PlatformException → unavailable:probe-error（桥在但报错）', () async {
      final caps = await probeWith(() => PlatformException(code: 'boom'));
      expect(
        caps.statusOf(AppCapability.audioVisualizer).reason,
        CapabilityReason.probeError,
      );
    });

    test('普通异常 → unavailable:probe-error（不挑异常类型）', () async {
      final caps = await probeWith(() => StateError('weird'));
      expect(
        caps.statusOf(AppCapability.cast).reason,
        CapabilityReason.probeError,
      );
    });

    test('超时 → **unknown**:probe-timeout（"没问出来"≠"问了说不能"）', () async {
      final caps = await probeAppCapabilities(
        base: staticCapabilitiesFor(AppHost.android),
        timeout: const Duration(milliseconds: 20),
        probe: (channel, method) => Completer<Object?>().future,
      );
      final s = caps.statusOf(AppCapability.videoFrameExtraction);
      expect(s.isUnknown, isTrue);
      expect(s.reason, CapabilityReason.probeTimeout);
      // ★ 超时**不许**降级成 unavailable：那会让功能在慢网络上"永久消失"
      expect(s.isUnavailable, isFalse);
      expect(caps.mayTry(AppCapability.videoFrameExtraction), isTrue);
    });

    test('桥应答有值 → available；`false` → device-says-no', () async {
      final ok = await probeAppCapabilities(
        base: staticCapabilitiesFor(AppHost.android),
        timeout: null,
        probe: (channel, method) async => true,
      );
      expect(ok.can(AppCapability.videoFrameExtraction), isTrue);
      expect(ok.statusOf(AppCapability.videoFrameExtraction).reason, 'ok');

      final no = await probeAppCapabilities(
        base: staticCapabilitiesFor(AppHost.android),
        timeout: null,
        probe: (channel, method) async => false,
      );
      final s = no.statusOf(AppCapability.videoFrameExtraction);
      expect(s.isUnavailable, isTrue);
      expect(s.reason, CapabilityReason.deviceSaysNo);
    });

    test('静态已确定的能力**不探测**（不多打一次通道）', () async {
      var calls = 0;
      await probeAppCapabilities(
        base: staticCapabilitiesFor(AppHost.macos),
        timeout: null,
        probe: (channel, method) async {
          calls++;
          return true;
        },
      );
      expect(calls, 0);
    });

    test('没有登记探测点的能力如实报 bridge-missing（配置错误不静默）', () {
      const ghost = CapabilityStatus.unknown(AppCapability.officeOffscreenRender);
      final base = AppPlatformCapabilities(AppHost.macos, {ghost.capability: ghost});
      // 手动构造一张"能力标了 unknown 但没登记桥"的表
      return probeAppCapabilities(base: base, timeout: null, probe: (c, m) async => true)
          .then((caps) {
            expect(
              caps.statusOf(AppCapability.officeOffscreenRender).reason,
              CapabilityReason.bridgeMissing,
            );
          });
    });
  });

  group('classifyProbeResult（纯函数，逐档）', () {
    CapabilityStatus run({
      String channel = 'ch',
      Object? value,
      Object? error,
    }) => classifyProbeResult(
      AppCapability.cast,
      channel: channel,
      value: value,
      error: error,
    );

    test('null 值 = 通道通了（算可用）', () {
      expect(run(value: null).state, CapabilityState.available);
    });

    test('显式 false / {available:false} / {ok:false} = 本机不支持', () {
      expect(run(value: false).reason, CapabilityReason.deviceSaysNo);
      expect(
        run(value: {'available': false}).reason,
        CapabilityReason.deviceSaysNo,
      );
      expect(run(value: {'ok': false}).reason, CapabilityReason.deviceSaysNo);
    });

    test('非空 / {available:true} / {ok:true} = 可用', () {
      expect(run(value: 1).state, CapabilityState.available);
      expect(run(value: {'available': true}).state, CapabilityState.available);
      expect(run(value: {'ok': true}).state, CapabilityState.available);
    });

    test('原因码恒为 ASCII，且 bridge 带出来', () {
      final s = run(error: MissingPluginException('x'));
      expect(s.reason, 'bridge-missing');
      expect(s.bridge, 'ch');
    });
  });

  group('AppPaths：路径裁决', () {
    late Directory tmp;
    late PathProviderDirs fake;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('r279_paths_');
      fake = (
        support: () async => Directory('${tmp.path}/support'),
        documents: () async => Directory('${tmp.path}/documents'),
        cache: () async => Directory('${tmp.path}/cache'),
        temp: () async => Directory('${tmp.path}/temp'),
        external: () async =>
            Directory('${tmp.path}/ext/Android/data/com.openviewai.synhub/files'),
      );
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('下载目录：桌面上是**应用容器内**的 documents/downloads（免授权）', () async {
      debugForceAppHost = AppHost.macos;
      final d = await AppPaths.downloadsDirectory(dirs: fake);
      expect(d.path, endsWith('documents/downloads'));
      expect(d.existsSync(), isTrue);
    });

    test('模型保管库：所有平台统一 <support>/models_vault', () async {
      for (final host in const [AppHost.android, AppHost.macos, AppHost.linux]) {
        debugForceAppHost = host;
        final d = await AppPaths.modelVaultDirectory(dirs: fake);
        expect(d.path, endsWith('support/models_vault'), reason: host.name);
      }
    });

    test('模型收件箱：Android 有（Android/media/<pkg>/models）', () async {
      debugForceAppHost = AppHost.android;
      final r = await AppPaths.modelInboxRoot(dirs: fake);
      expect(r.exists, isTrue);
      expect(r.reason, 'ok');
      expect(r.path, endsWith('Android/media/com.openviewai.synhub/models'));
    });

    test('模型收件箱：macOS/Linux/Windows/iOS **没有这个概念**（不是报错）', () async {
      for (final host in const [
        AppHost.macos,
        AppHost.linux,
        AppHost.windows,
        AppHost.ios,
      ]) {
        debugForceAppHost = host;
        final r = await AppPaths.modelInboxRoot(dirs: fake);
        expect(r.exists, isFalse, reason: host.name);
        expect(r.reason, CapabilityReason.notSupportedOnHost, reason: host.name);
        expect(r.path, isEmpty);
      }
    });

    test('本地文件根：Android = /storage/emulated/0', () async {
      debugForceAppHost = AppHost.android;
      final roots = await AppPaths.localFileRoots(dirs: fake);
      expect(roots.length, 1);
      expect(roots.single.path, '/storage/emulated/0');
      expect(roots.single.reason, 'ok');
    });

    test('本地文件根：桌面 = 容器内的 documents + temp（不假装能读家目录）', () async {
      debugForceAppHost = AppHost.macos;
      final roots = await AppPaths.localFileRoots(dirs: fake);
      expect(roots.map((r) => r.id), containsAll(['local_documents', 'local_temp']));
      for (final r in roots) {
        expect(r.path, startsWith(tmp.path));
        expect(r.reason, 'ok');
      }
      // ★ 不许出现 Android 的字面量
      expect(
        roots.any((r) => r.path.contains('/storage/emulated')),
        isFalse,
      );
    });

    test('本地文件根：web/unknown → 空 + not-supported-on-host', () async {
      for (final host in const [AppHost.web, AppHost.unknown]) {
        debugForceAppHost = host;
        final roots = await AppPaths.localFileRoots(dirs: fake);
        expect(roots.single.exists, isFalse, reason: host.name);
        expect(roots.single.reason, CapabilityReason.notSupportedOnHost);
      }
    });

    test('笔记"外置存储"：Android 用应用专属外置目录', () async {
      debugForceAppHost = AppHost.android;
      final r = await AppPaths.noteStorageRoot(external: true, dirs: fake);
      expect(r.path, contains('Android/data/com.openviewai.synhub/files'));
      expect(r.fallbackReason, isEmpty);
    });

    test('笔记"外置存储"：桌面上**回退内部并如实报原因**（不假装成功）', () async {
      for (final host in const [AppHost.macos, AppHost.linux, AppHost.windows]) {
        debugForceAppHost = host;
        final r = await AppPaths.noteStorageRoot(external: true, dirs: fake);
        expect(r.path, endsWith('documents'), reason: host.name);
        expect(r.fallbackReason, CapabilityReason.notSupportedOnHost);
      }
    });

    test('外置目录取不到（抛/回 null）时不崩，回退内部 + bridge-missing', () async {
      debugForceAppHost = AppHost.android;
      final broken = (
        support: fake.support,
        documents: fake.documents,
        cache: fake.cache,
        temp: fake.temp,
        external: () async => null,
      );
      final r = await AppPaths.noteStorageRoot(external: true, dirs: broken);
      expect(r.path, endsWith('documents'));
      expect(r.fallbackReason, CapabilityReason.bridgeMissing);
    });
  });

  group('AppPathRoot / CapabilityStatus 形状', () {
    test('CapabilityStatus 的相等按 (能力, 状态, 原因) —— 便于直接断言', () {
      const a = CapabilityStatus.unavailable(
        AppCapability.cast,
        CapabilityReason.bridgeMissing,
      );
      const b = CapabilityStatus.unavailable(
        AppCapability.cast,
        CapabilityReason.bridgeMissing,
      );
      const c = CapabilityStatus.unavailable(
        AppCapability.cast,
        CapabilityReason.probeError,
      );
      expect(a, b);
      expect(a, isNot(c));
      expect(a.hashCode, b.hashCode);
    });

    test('label 三态各不相同（界面据此区分"探测中"与"不可用"）', () {
      final labels = {
        for (final s in [
          const CapabilityStatus.available(AppCapability.cast),
          const CapabilityStatus.unavailable(
            AppCapability.cast,
            CapabilityReason.bridgeMissing,
          ),
          const CapabilityStatus.unknown(AppCapability.cast),
        ])
          s.label,
      };
      expect(labels.length, 3);
    });

    test('未登记的条目回 unavailable:bridge-missing（不抛、不静默 null）', () {
      const caps = AppPlatformCapabilities(AppHost.macos, {});
      final s = caps.statusOf(AppCapability.cast);
      expect(s.reason, CapabilityReason.bridgeMissing);
      expect(caps.can(AppCapability.cast), isFalse);
    });

    test('UnavailableAdapter 的动作**响**（拒绝），不静默 no-op', () {
      final caps = staticCapabilitiesFor(AppHost.macos);
      final a = adapterFor(caps, AppCapability.cast);
      expect(a.status().isUnavailable, isTrue);
      expect(() => (a as UnavailableAdapter).refuse('connect'), throwsUnsupportedError);
    });
  });

  group('能力原因的数据层文案（i18n 三步的第三步）', () {
    test('全部原因码都能取到非空文案（含未登记码的回落）', () {
      for (final r in const [
        CapabilityReason.ok,
        CapabilityReason.notSupportedOnHost,
        CapabilityReason.notImplementedOnHost,
        CapabilityReason.needsMobileHost,
        CapabilityReason.bridgeMissing,
        CapabilityReason.probePending,
        CapabilityReason.probeTimeout,
        CapabilityReason.probeError,
        CapabilityReason.deviceSaysNo,
        'something-brand-new',
      ]) {
        expect(capabilityReasonText(r), isNotEmpty, reason: r);
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // 第 55 轮：Android-only 桥的**能力门**（普查见 docs/platform-macos.md §5）
  // ═══════════════════════════════════════════════════════════════════════
  group('第 55 轮：Android-only 桥在宿主上如实报"未实现"', () {
    test('macOS：全部 Android-only 桥能力 = unavailable:not-implemented-on-host', () {
      final caps = staticCapabilitiesFor(AppHost.macos);
      expect(kAndroidOnlyBridgeCapabilities, isNotEmpty);
      for (final c in kAndroidOnlyBridgeCapabilities) {
        final s = caps.statusOf(c);
        expect(s.isUnavailable, isTrue, reason: c.name);
        expect(s.reason, CapabilityReason.notImplementedOnHost, reason: c.name);
        expect(caps.can(c), isFalse, reason: c.name);
        // mayTry=false ⇒ 连通道都不碰（这是"如实报"与"撞异常"的分界）
        expect(caps.mayTry(c), isFalse, reason: c.name);
      }
    });

    test('Android：同样这些能力是静态 available（Kotlin 随包编译进去）', () {
      final caps = staticCapabilitiesFor(AppHost.android);
      for (final c in kAndroidOnlyBridgeCapabilities) {
        expect(caps.can(c), isTrue, reason: c.name);
        expect(caps.mayTry(c), isTrue, reason: c.name);
      }
    });

    test('iOS / Linux / Windows：同 macOS（如实"未实现"，不假装有桥）', () {
      for (final host in const [AppHost.ios, AppHost.linux, AppHost.windows]) {
        final caps = staticCapabilitiesFor(host);
        for (final c in kAndroidOnlyBridgeCapabilities) {
          expect(caps.mayTry(c), isFalse, reason: '${host.name}/${c.name}');
        }
      }
    });

    test('r680：深链在 Android 与 iOS 都放行，桌面/web 仍如实拦下', () {
      for (final host in const [AppHost.android, AppHost.ios]) {
        expect(
          staticCapabilitiesFor(host).mayTry(AppCapability.deepLink),
          isTrue,
          reason: host.name,
        );
      }
      for (final host in const [
        AppHost.macos,
        AppHost.linux,
        AppHost.windows,
      ]) {
        final status = staticCapabilitiesFor(host).statusOf(
          AppCapability.deepLink,
        );
        expect(status.isAvailable, isFalse, reason: host.name);
        expect(
          status.reason,
          CapabilityReason.notImplementedOnHost,
          reason: host.name,
        );
      }
      // web 的理由是"这个宿主结构上没有"（不是"还没写"），沿用 switch 的结论
      final webStatus = staticCapabilitiesFor(
        AppHost.web,
      ).statusOf(AppCapability.deepLink);
      expect(webStatus.isAvailable, isFalse);
      expect(webStatus.reason, CapabilityReason.notSupportedOnHost);
    });

    test('能力门：宿主拦下且原因是机器码；Android 与强制放行时放行', () {
      debugForceAppHost = AppHost.macos;
      expect(capabilityGateAllows(AppCapability.deepLink), isFalse);
      expect(
        capabilityGateReason(AppCapability.deepLink),
        CapabilityReason.notImplementedOnHost,
      );
      debugForceAppHost = AppHost.android;
      expect(capabilityGateAllows(AppCapability.deepLink), isTrue);
      debugForceAppHost = AppHost.ios;
      expect(capabilityGateAllows(AppCapability.deepLink), isTrue);
      debugForceAppHost = AppHost.macos;
      debugForceCapabilityGate = true;
      expect(capabilityGateAllows(AppCapability.deepLink), isTrue);
    });

    test('降级分支不抛异常：宿主上直接用这些桥，全部安全回落', () async {
      debugForceAppHost = AppHost.macos;
      // 深链：没有待处理载荷（不是异常，是"本平台没有深链"）
      final dl = MethodChannelChatDeepLinkSource();
      expect(await dl.takePending(), isNull);
      dl.dispose();
      // 快捷方式：钉不上（UI 可据 status() 说明原因）
      expect(
        await MethodChannelShortcutBridge().pinShortcut(
          id: 'i',
          label: 'l',
          path: '/p',
        ),
        isFalse,
      );
      expect(
        MethodChannelShortcutBridge.status().reason,
        CapabilityReason.notImplementedOnHost,
      );
      // MediaStore 导出：unsupported + 原因码（不是 failed）
      final saver = MethodChannelMediaStoreSaver();
      expect(await saver.isSupported(), isFalse);
      final r = await saver.saveToDownloads(sourcePath: '/tmp/a', name: 'a');
      expect(r.ok, isFalse);
      expect(r.unsupported, isTrue);
      expect(r.reason, CapabilityReason.notImplementedOnHost);
      // 流量计数：没有 UID 计数 → null（估算档整体不可用）
      expect(await MethodChannelDeviceTrafficProbe().snapshot(), isNull);
    });

    test('★ 反向验证：门开着时**真的会去碰通道**（这道门不是恒假）', () async {
      debugForceAppHost = AppHost.macos;
      var touched = 0;
      const channel = MethodChannel('synhub/deep_link');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        touched++;
        return {
          'scheme': 'synochat',
          'address': 'nas.local',
          'account': 'bob',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      // ① macOS 默认：能力门拦下 ⇒ 通道一次都没碰
      final blocked = MethodChannelChatDeepLinkSource();
      expect(await blocked.takePending(), isNull);
      expect(touched, 0, reason: 'macOS 上不该碰 Android 的 deep_link 桥');
      blocked.dispose();

      // ② 强制放行（证明门是"可开的"，不是恒假）：通道被碰、载荷被解析
      debugForceCapabilityGate = true;
      final allowed = MethodChannelChatDeepLinkSource();
      final link = await allowed.takePending();
      expect(touched, 1, reason: '门开着时必须真的调用通道');
      expect(link, isNotNull);
      expect(link!.address, 'nas.local');
      expect(link.account, 'bob');
      expect(link.secure, isFalse);
      allowed.dispose();
    });
  });
}
