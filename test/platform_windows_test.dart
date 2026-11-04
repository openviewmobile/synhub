// Windows 平台站的**守卫用例**（第 109 轮新增；第 293 轮翻位更新）。
//
// ★★ 第 293 轮：**`secureStorage` 已翻位成 `available|ok`**，而且是先在
//    **真 Windows 11 ARM64 虚拟机**上取根因、再修、再逐条验收的（见
//    `docs/platform-windows.md` §15）。第 109 轮那条"已知矛盾登记"到此消除：
//
//    * 根因（真机插桩原文）：`seal()` **从来没走到插件** ——
//      `_r293Probe seal BLOCKED … isSupported=false capAllowed=false
//      hostSupports=false targetPlatform=windows usesPluginSecureStorage=false`；
//      而**同一个进程里直连插件是成功的**
//      （`_r293Probe plugin-direct write/read OK … readBackMatched=true`）
//      ⇒ 不是插件没就绪、不是选项不兼容、不是异常被吞，而是**被排除在选择之外**；
//    * 修法：`app_platform.dart` 的白名单加 Windows +
//      `keystore_secret_keeper.dart` 的 `usesPluginSecureStorageFor()` 加 Windows；
//    * 后端事实（**别写成"凭据管理器"**）：`flutter_secure_storage_windows` 4.2.2
//      的默认 `write` 写 **DPAPI 文件** `flutter_secure_storage.dat`
//      （`CryptProtectData`），并**主动删除**旧的凭据管理器条目 ⇒
//      `cmdkey /list` **本来就该是 `* NONE *`**；验收判据是那个 DPAPI 文件 +
//      落盘库里 `secret_sealed:true` + `secret` 变成 `macos-secure:<alias>`。
//
// 这一组的第一职责仍然是**冻结 Windows 那一列**（第 109 轮给 Linux 站修 P0 时
// 动过 `app_platform.dart`；`case AppHost.windows:` 是从 `AppHost.linux:` 逐字节
// 拆出来的）。现在钉住的是：① 29 位逐位写死；② `available` 恰好 **4** 位
// （离屏渲染 / 文档选择 / **安全存储** / **本地播放**）；③ `unknown` 集合为空；
// ④ 能力门只放行那 4 位；⑤ Linux 与 Windows 的差异集合**恰好为空**
// （★ r690 Linux 翻本地播放、★ r703 Windows 也翻 ⇒ 两家在 29 位上又完全一致）。
//
// 口径：第 109 轮这些结论都是**静态分析 / 仓库内生成产物**档；**第 293 轮**
// 的 `secureStorage` 那一位另有**真机实测**档（同一台 VM 上跑过、抓过、验过）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/platform/desktop_notify_windows.dart';
// ★ 第 293 轮：翻位的**另一半**在 keeper 里（能力层放行 ≠ keeper 会走插件）。
import 'package:synhub/src/core/security/keystore_secret_keeper.dart';

/// Windows 那一列**逐位写死**（`capability.name → 'state|reason'`）。
///
/// 改这里 = 改 Windows 行为，必须同步 `docs/platform-windows.md` §4/§15 与
/// `AGENTS.md §2.0.23`。
final Map<String, String> kWindowsColumn = {
  // ── 真的能用（3 位）──────────────────────────────────────────────────
  'officeOffscreenRender': 'available|ok', // 纯 Dart（OOXML + canvas）
  'documentPicker': 'available|ok', // file_selector_windows 已注册
  // ★ 第 293 轮翻位：插件在依赖里 + 在生成注册表里 + **真 Windows 上跑通**
  //   （DPAPI 文件成形、库 `secret_sealed:true`）。见文件头与 §15。
  'secureStorage': 'available|ok',
  // ★ r703 翻位：`media_kit_libs_windows_video` 随包带 libmpv（构建期校验 MD5），
  //   `main()` 在 Windows 上也初始化 media_kit / just_audio_media_kit；
  //   **guest 真机上量到"进度真的在走 / 视频出真帧"**（读数见
  //   `docs/windows-page-coverage.md` §4.5）。三条缺一不许翻。
  'localMediaPlayback': 'available|ok',
  // ★ r707 翻位：抽帧后端换成 libmpv（`MpvVideoFrameExtractor`，纯 Dart 调
  //   `screenshot-raw`，不建 VideoController）。guest 读数：同一条 mp4
  //   `setVideoTrack(auto)` 之后 `1280x720 / 513321B / 采样色数=6872`，
  //   整条生产流水线出 `docs/evidence-r707-win/271_video_frame.png`。
  'videoFrameExtraction': 'available|ok',
  // ── 本仓尚未实现（21 位；另有 1 位 bridge-missing 见文件末尾）──────────
  'audioVisualizer': 'unavailable|not-implemented-on-host',
  'networkTrafficCounters': 'unavailable|not-implemented-on-host',
  'cast': 'unavailable|not-implemented-on-host',
  'backgroundExecution': 'unavailable|not-implemented-on-host',
  // ★ r709：这一位**取决于安装形态**（打包态可推导 AUMID ⇒ available；
  //   免安装 ⇒ not-implemented-on-host）。`staticCapabilitiesFor()` 看的是**当前进程**，
  //   所以在 macOS 上跑用例时这里必须是 unavailable —— 两格都写出来，
  //   别让"测试宿主机恰好不是 Windows"变成假绿（r709 现场发现的）。
  'localNotifications': Platform.isWindows
      ? 'available|ok'
      : 'unavailable|not-implemented-on-host',
  // Android-only 桥（17 位，与 Linux 同口径）
  'deepLink': 'unavailable|not-implemented-on-host',
  'systemShare': 'unavailable|not-implemented-on-host',
  'fileShortcut': 'unavailable|not-implemented-on-host',
  'driveSafSession': 'unavailable|not-implemented-on-host',
  'mediaStoreExport': 'unavailable|not-implemented-on-host',
  'localMediaLibrary': 'unavailable|not-implemented-on-host',
  'deviceLocation': 'unavailable|not-implemented-on-host',
  'networkInfo': 'unavailable|not-implemented-on-host',
  'audioEqualizer': 'unavailable|not-implemented-on-host',
  'driveWatch': 'unavailable|not-implemented-on-host',
  'noteReminders': 'unavailable|not-implemented-on-host',
  'scheduledNoteSync': 'unavailable|not-implemented-on-host',
  'photoBackup': 'unavailable|not-implemented-on-host',
  'sleepBackup': 'unavailable|not-implemented-on-host',
  'oemCompat': 'unavailable|not-implemented-on-host',
  'downloadNotifications': 'unavailable|not-implemented-on-host',
  'systemOpen': 'unavailable|not-implemented-on-host',
  // ── 结构上没有（1 位）────────────────────────────────────────────────
  'homeScreenWidgets': 'unavailable|not-supported-on-host',
  // ── 需要手机宿主的事实（1 位）────────────────────────────────────────
  'deviceHardwareInfo': 'unavailable|needs-mobile-host',
  // ★ 第 328 轮新增第 30 位：安全作用域书签是 **macOS 独有**的桥
  //   （`app_platform.dart` 只在 macOS 那一支 `put` 它）⇒ 其余宿主拿到
  //   `statusOf` 的**默认值** `unavailable|bridge-missing`（如实：桥不存在）。
  'fsBookmark': 'unavailable|bridge-missing',
};

void main() {
  final caps = staticCapabilitiesFor(AppHost.windows);

  group('① Windows 能力矩阵（逐位写死，防漂移）', () {
    test('★ 30 位**一位不缺**，且逐位状态/原因码与登记完全一致', () {
      // 先钉住总数：`AppCapability` 加了新位而这里没登记 ⇒ 当场红。
      // ★ 第 328 轮：`fsBookmark`（macOS 专属，见 AGENTS §2.0.58）是第 30 位。
      expect(AppCapability.values.length, 30);
      expect(kWindowsColumn.length, AppCapability.values.length);

      for (final c in AppCapability.values) {
        final expected = kWindowsColumn[c.name];
        expect(
          expected,
          isNotNull,
          reason: '新增了能力位 ${c.name}，Windows 列没登记 —— 先给结论再改这里',
        );
        final s = caps.statusOf(c);
        expect(
          '${s.state.name}|${s.reason}',
          expected,
          reason: 'Windows 的 ${c.name} 结论漂移了',
        );
      }
    });

    test('★ Windows 的 available 集合**恰好** = 五位（＋ Windows 宿主上的本地通知）', () {
      final can = <String>{
        for (final c in AppCapability.values)
          if (caps.can(c)) c.name,
      };
      const base = {
        'documentPicker',
        'officeOffscreenRender',
        // ★ 第 293 轮翻位（真机验收后才许加这一行，见文件头）。
        'secureStorage',
        // ★ r703 翻位（guest 真机进度/画面都量到，见文件头）。
        'localMediaPlayback',
        // ★ r707 翻位：libmpv 抽帧后端（guest 出 271_video_frame.png）。
        'videoFrameExtraction',
      };
      // ★ r709：`localNotifications` 是**第 6 位**，但只在**打包态的 Windows** 上成立
      //   （判据 = 能推导出 AUMID）。用例跑在 macOS 上时它必须**不在**集合里，
      //   跑在 Windows 上时必须在 —— 两格写清，避免"宿主机不是 Windows ⇒ 恒绿"。
      expect(
        can,
        Platform.isWindows ? {...base, 'localNotifications'} : base,
        reason: Platform.isWindows
            ? 'Windows 宿主：打包态本地通知应当可用（第 6 位）'
            : '非 Windows 宿主：本地通知必须如实不可用（fail-closed）',
      );
    });

    test('★ r709 反向：Windows 宿主的本地通知判据能被单独钉住（不随测试宿主机变）', () {
      const packaged =
          r'C:\Program Files\WindowsApps\com.flutter.synhub_1.0.0.0_x64__fxkeb4dgdm144\synhub.exe';
      const unpackaged =
          r'C:\src\synhub_r703\build\windows\x64\runner\Release\synhub.exe';
      expect(
        windowsToastCapability(exePath: packaged, isWindows: true),
        isTrue,
        reason: '打包态 Windows ⇒ 能推导 AUMID ⇒ 可用（这一格是 r709 翻位的依据）',
      );
      expect(
        windowsToastCapability(exePath: unpackaged, isWindows: true),
        isFalse,
        reason: '免安装 ⇒ 推导不出 AUMID ⇒ 如实未实现',
      );
      expect(
        windowsToastCapability(exePath: packaged, isWindows: false),
        isFalse,
        reason: '非 Windows 宿主 ⇒ 一律不可用',
      );
    });

    test('本地播放 = available:ok（★ r703 翻位；既不是"平台不支持"也不是"未实现"）', () {
      final s = caps.statusOf(AppCapability.localMediaPlayback);
      expect(s.state, CapabilityState.available);
      expect(s.reason, CapabilityReason.ok);
      expect(s.reason, isNot(CapabilityReason.notImplementedOnHost));
      expect(s.reason, isNot(CapabilityReason.notSupportedOnHost));
    });

    test('主屏小组件 = not-supported（Windows 桌面结构与 Linux 同型）', () {
      final s = caps.statusOf(AppCapability.homeScreenWidgets);
      expect(s.state, CapabilityState.unavailable);
      expect(s.reason, CapabilityReason.notSupportedOnHost);
    });

    test('端侧硬件事实 = needs-mobile-host（宿主不编事实，AGENTS §2.0.6）', () {
      final s = caps.statusOf(AppCapability.deviceHardwareInfo);
      expect(s.state, CapabilityState.unavailable);
      expect(s.reason, CapabilityReason.needsMobileHost);
    });

    test('★ 反向：Windows 上**没有任何**能力是 unknown（桌面没有桥可探）', () {
      for (final c in AppCapability.values) {
        expect(
          caps.isUnknown(c),
          isFalse,
          reason: '${c.name} 在 Windows 上留成了"探测中" —— 桌面没有桥可探',
        );
      }
    });

    test('★ 反向：每一条 unavailable 的原因码都是 kebab-case ASCII', () {
      final re = RegExp(r'^[a-z][a-z0-9-]*$');
      for (final c in AppCapability.values) {
        expect(
          re.hasMatch(caps.statusOf(c).reason),
          isTrue,
          reason: '${c.name} 的原因码不是机器可读 ASCII',
        );
      }
    });

    test('★ 反向：能力门在 Windows 上**只放行 available 那几位**', () {
      for (final c in AppCapability.values) {
        final allowed = _gateAllowsForHost(AppHost.windows, c);
        expect(
          allowed,
          caps.can(c),
          reason: '${c.name}：Windows 上 available 之外一律该被能力门拦住',
        );
      }
    });

    test('★ 反向：Linux 与 Windows 的差异集合**恰好** = {抽帧}（r707 只翻了 Windows；r709 的本地通知两家同格）', () {
      final linux = staticCapabilitiesFor(AppHost.linux);
      final diff = <String>{
        for (final c in AppCapability.values)
          if (caps.statusOf(c) != linux.statusOf(c)) c.name,
      };
      // 第 109 轮这里写死的是 `{'secureStorage'}`（Linux 放行、Windows 拦住）；
      // 第 293 轮 Windows 补齐后两家在 29 位上完全一致；
      // ★ r690：Linux 的 `localMediaPlayback` 翻成 available（容器里 libmpv 真出画面 +
      //   just_audio_media_kit 真走时间轴，见 `docs/platform-linux-acceptance.md` §A）。
      //   ★ r703：Windows 也翻（guest 上 libmpv 真出进度/画面）⇒ 两家**又完全一致**。
      //   这一行仍然防"顺手把 Windows 改样"：多一位少一位都红。
      // ★ r707：Windows 的 `videoFrameExtraction` 翻成 available，而 Linux 仍是
      //   `not-implemented-on-host` —— 抽帧后端（`MpvVideoFrameExtractor`）**代码上**
      //   两家都能跑（`hostSupported()` 含 linux），但 Linux 站还没在真机上量过
      //   ⇒ 按"只认计数器/像素"的规矩，**Linux 不翻**。谁翻 Linux 谁补证据。
      expect(diff, {'videoFrameExtraction'});
      expect(
        linux.statusOf(AppCapability.secureStorage).state,
        CapabilityState.available,
      );
      expect(
        caps.statusOf(AppCapability.secureStorage).state,
        CapabilityState.available,
      );
    });

    test('★ 反向：Windows 列与 macOS 列的差异**恰好**是这 4 处', () {
      final mac = staticCapabilitiesFor(AppHost.macos);
      final diff = <String>{
        for (final c in AppCapability.values)
          if (caps.statusOf(c) != mac.statusOf(c)) c.name,
      };
      // 写死差异集合：多一处 / 少一处都红 ⇒ "顺手把 Windows 改成 macOS 那列"
      // 当场被抓住。★ 第 293 轮 `secureStorage` 已从差异里消失（两家都 available）。
      expect(diff, {
        // ★ r707：Windows 有 libmpv 抽帧后端，macOS 没有（`not-implemented-on-host`）。
        'videoFrameExtraction',
        // ★ r703：`localMediaPlayback` 已从差异里消失（两家都 available）。
        // 两家都"没有"，但**理由不同**：macOS 结构上没有前台服务
        // （`not-supported-on-host`），Windows 与 Linux 只是本仓未实现。
        'backgroundExecution',
        // 反过来：macOS 是"本仓未实现"（WidgetKit 存在），Windows 结构上没有主屏。
        'homeScreenWidgets',
        // ★ 第 328 轮新增：安全作用域书签是 **macOS 独有**的 API
        //   （`URL.bookmarkData(options:.withSecurityScope)`）；Windows 没有对应语义。
        'fsBookmark',
      });
      expect(
        mac.statusOf(AppCapability.localMediaPlayback).state,
        CapabilityState.available,
      );
      expect(
        mac.statusOf(AppCapability.secureStorage).state,
        CapabilityState.available,
      );
    });
  });

  group('② ★ 第 293 轮翻位：secureStorage（能力层 + 证据层 + keeper 机制三层同时钉）', () {
    test('能力层现在报 available:ok，能力门放行', () {
      final s = caps.statusOf(AppCapability.secureStorage);
      expect(s.state, CapabilityState.available);
      expect(s.reason, CapabilityReason.ok);
      expect(
        _gateAllowsForHost(AppHost.windows, AppCapability.secureStorage),
        isTrue,
      );
      expect(caps.can(AppCapability.secureStorage), isTrue);
      expect(caps.mayTry(AppCapability.secureStorage), isTrue);
    });

    // 证据一侧：插件**确实**在依赖里、**确实**在生成注册表里。
    // 这两条是硬事实（生成产物 + lock），不是推断。
    test('★ 证据一侧：pubspec.lock 里有 flutter_secure_storage_windows', () {
      final lock = File('pubspec.lock').readAsStringSync();
      expect(lock, contains('flutter_secure_storage_windows:'));
      expect(lock, contains('version: "4.2.2"'));
    });

    test('★ 证据一侧：Windows 生成注册表**注册了**该插件', () {
      final reg =
          File('windows/flutter/generated_plugin_registrant.cc').readAsStringSync();
      expect(
        reg,
        contains(
          '#include <flutter_secure_storage_windows/flutter_secure_storage_windows_plugin.h>',
        ),
      );
      expect(
        reg,
        contains('FlutterSecureStorageWindowsPluginRegisterWithRegistrar('),
      );
      final cmake = File('windows/flutter/generated_plugins.cmake').readAsStringSync();
      expect(cmake, contains('flutter_secure_storage_windows'));
    });

    test('★ 证据一侧：.flutter-plugins-dependencies 的 windows 列含它', () {
      final raw = File('.flutter-plugins-dependencies').readAsStringSync();
      expect(raw, contains('"flutter_secure_storage_windows"'));
      expect(raw, contains('"windows"'));
    });

    test('★ 机制一侧：Windows 属于 `_usesPluginSecureStorage` 那条路', () {
      // ★★ 这条是第 293 轮**新增的那条回归守卫**的第一档：只改能力层
      //    （`app_platform.dart`）而忘了改 keeper（`keystore_secret_keeper.dart`）
      //    时，能力层会说"能用"、keeper 却仍把 Windows 挡在插件之外 ⇒
      //    照旧明文落盘。两条必须同时成立，这里把 keeper 那一半也钉住。
      //    （完整矩阵 + 反向验证见 `test/secret_keeper_host_matrix_test.dart`。）
      expect(usesPluginSecureStorageFor(TargetPlatform.windows), isTrue);
      expect(
        secretKeeperHostSupportedFor(
          platform: TargetPlatform.windows,
          isWeb: false,
          inFlutterTest: false,
        ),
        isTrue,
      );
      // 反向：Android 走自研通道 ⇒ **不在**插件集合里（别顺手加进来）。
      expect(usesPluginSecureStorageFor(TargetPlatform.android), isFalse);
      expect(
        secretKeeperHostSupportedFor(
          platform: TargetPlatform.android,
          isWeb: false,
          inFlutterTest: false,
        ),
        isTrue, // Android 走 channel，所以"宿主支持"仍为真
      );
      // 反向：真测试环境必须挡住（退化路径）。
      expect(
        secretKeeperHostSupportedFor(
          platform: TargetPlatform.windows,
          isWeb: false,
          inFlutterTest: true,
        ),
        isFalse,
      );
    });
  });

  group('③ Windows 工程骨架（不许静默消失）', () {
    test('windows/ 工程与 runner 都在（否则"能编"这件事无从谈起）', () {
      for (final p in const [
        'windows/CMakeLists.txt',
        'windows/runner/main.cpp',
        'windows/runner/flutter_window.cpp',
        'windows/runner/win32_window.cpp',
        'windows/runner/Runner.rc',
        'windows/flutter/generated_plugin_registrant.cc',
      ]) {
        expect(File(p).existsSync(), isTrue, reason: '$p 不见了');
      }
    });

    test('Windows 列里"没有 just_audio / video_player 实现"这条结论有插件列背书', () {
      final raw = File('.flutter-plugins-dependencies').readAsStringSync();
      final win = _windowsColumnNames(raw);
      // 第三方媒体插件**不在** windows 列里 ⇒ 调它必撞 MissingPluginException。
      expect(win, isNot(contains('just_audio')));
      expect(win, isNot(contains('video_player')));
      expect(win, isNot(contains('audio_service')));
      expect(win, isNot(contains('webview_flutter')));
      // 反面：确实有的那几个（证明上面不是"看到名字就排除"）。
      expect(win, contains('file_selector_windows'));
      expect(win, contains('path_provider_windows'));
      expect(win, contains('local_auth_windows'));
    });
  });
}

/// 能力门语义的宿主版（与 `test/platform_linux_test.dart` 末尾同型；
/// 生产代码里没有这个重载 —— 它只服务测试）。
bool _gateAllowsForHost(AppHost host, AppCapability capability) =>
    !staticCapabilitiesFor(host).statusOf(capability).isUnavailable;

/// 仅给断言用：把 `.flutter-plugins-dependencies` 的 windows 列拉成名字集合。
///
/// ★ 用 `jsonDecode` 而不是"从 `"windows"` 切片"：这份文件里各列的键序是
/// `ios / android / macos / linux / windows / web` ⇒ 从 `"windows"` 往后切
/// **会把 web 列一起卷进来**（第 109 轮踩过，`audio_service_web` 混进来了）。
Set<String> _windowsColumnNames(String raw) {
  final root = jsonDecode(raw) as Map<String, dynamic>;
  final plugins = root['plugins'] as Map<String, dynamic>;
  final win = (plugins['windows'] as List?) ?? const [];
  return {
    for (final p in win) (p as Map)['name'] as String,
  };
}
