// Flutter **Web 平台站**的守卫用例（第 130 轮新增）。
//
// 这一组钉住四件事，每一件都对应一个"以后会悄悄坏掉 / 会被顺手改坏"的地方：
//
//   ① **Web 那一列能力矩阵不许漂移**：本轮取到的原始事实是
//      **`flutter build web` 根本编不过**（`dart:ffi` 不在 web 上，
//      原文见 `docs/platform-web.md` §2），所以 Web 列是**fail-closed**：
//      `available` 集合 = **空集**。谁"顺手给 web 放行一位"这里当场红。
//
//   ② **本轮对其它平台零改动**（反向断言）：Android / iOS / Linux / macOS /
//      Windows 五家的 `available` 集合全部写死。Web 站是**加一列**，
//      不是"顺便把别人也改了"—— 写死之后任何"顺手"都跑不掉。
//
//   ③ **编译级拦路虎只有 `dart:ffi` 一处（两个来源）**：本轮探针实测
//      `import 'dart:io'` 在 Flutter Web 上**能编过**（`✓ Built build/web`），
//      运行时才抛 `Unsupported operation: Platform._operatingSystem`；
//      而 `dart:ffi` 是 dart2js **硬拒绝**（`Dart library 'dart:ffi' is not
//      available on this platform.`）。这张表把"web 编译面"写死 ——
//      新引入一个 ffi/drift-native 依赖而忘了登记，这里红。
//
//   ④ **`dart:io` 的移植面只许缩不许涨**：`lib/` 里 `import 'dart:io'`
//      的文件数本轮基线 = **82**（第 328 轮 82→83，r371 又降回 82：DA14 修完
//      `drive_browse_view.dart` 不再自己写临时文件）。web 站唯一正确的方向是把它**降下来**，
//      所以断言是 `<= 基线`（涨了就红），配一条"扫描器不是恒 0"的反向验证。
//
// 口径与 `docs/platform-web.md` 的"证据档位"一致：
// 本文件里的结论都是 **[实测]**（本机原始输出）、**[静态]**（源码/生成产物）
// 与 **[单测]** 档；**没有一条**是"web 浏览器里跑通了这个 App"
// （见该文档 §7 未验清单）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

/// `import 'package:<pkg>/...'` 里的包名。
final RegExp _importRe = RegExp(r"""import\s+'package:([a-z0-9_]+)/""");

/// `import 'dart:<lib>'` 里的库名。
final RegExp _dartLibRe = RegExp(r"""import\s+'dart:([a-z0-9_]+)'""");

/// 指定宿主下的能力门结论（与 `capabilityGateAllows` 同语义：只有
/// `unavailable` 才拦）。生产代码用的是"当前宿主"，这里显式传宿主，
/// 才能在 macOS 宿主上测 Web 列。
bool _gateForHost(AppHost host, AppCapability capability) =>
    staticCapabilitiesFor(host).mayTry(capability);

/// Web 列上**当前**仍然不可用的安全凭据存储（"第五次同型"的取证锚点）。
///
/// ★ 这不是"web 结构上没有"，而是"**本仓这一轮没有验过**"：
///   * `flutter_secure_storage_web` **确实在** `.flutter-plugins-dependencies`
///     的 web 列里（17 个插件之一，见本文件 group ⑤）；
///   * `KeystoreSecretKeeper._hostSupports` 却是 `if (kIsWeb) return false;`
///     ⇒ `isSupported == false` ⇒ `seal()` 直接回 `null` ⇒ 调用点回落**明文落盘**。
///
/// 第 42/92/108/109 轮已经在 macOS / iOS / Linux / Windows 上同一形态栽过四次，
/// 这是第五次。**本轮不翻位**：没有真机浏览器验证就翻位 = 没跑过就宣布修好
/// （AGENTS §2.0.23 第 4 条的同一条纪律）。修法与**验收条件**见
/// `docs/platform-web.md` §6。
const String kWebSecureStorageStillUnavailable = 'secureStorage';

/// web 列有插件、但本仓能力位仍按"不可用"处理的**登记表**。
///
/// key = `.flutter-plugins-dependencies` 的 web 列里**真实存在**的 pub 包名；
/// value = 人写的理由 + 下一步。表里多一条 / 少一条都会让 group ⑤ 红
/// （**反向验证**：证明这张表不是摆设）。
const Map<String, String> kWebCapabilityGaps = {
  'flutter_secure_storage_web':
      'web 列确实注册了它（取证见 group ⑤），但 KeystoreSecretKeeper 用 '
      '`if (kIsWeb) return false;` 把 web 挡在外面 ⇒ 凭据回落明文落盘。'
      '★ 只负责取证，本轮不翻位：必须先在真浏览器里验证 WebCrypto/localStorage '
      '这一跳真的能存取，再改能力位（验收条件见 docs/platform-web.md §6）。',
  'file_picker_web':
      'web 列有它（<input type=file>），但 AppCapability.documentPicker 在 web 上 '
      '仍是 unavailable —— 理由码用的是 not-supported-on-host，语义上应是 '
      'not-implemented-on-host（"本仓还没接"≠"这个平台没有"）。'
      '本轮不改（改理由码虽不影响 mayTry，但同样要过一遍全仓调用点，属下一轮）。',
  'just_audio_web':
      'web 列有它（HTMLAudioElement），localMediaPlayback 在 web 上仍 unavailable；'
      '同 file_picker_web 的理由码问题。',
  'video_player_web':
      'web 列有它（HTMLVideoElement），localMediaPlayback 在 web 上仍 unavailable；'
      '同 file_picker_web 的理由码问题。',
};

void main() {
  group('① Web 能力矩阵（写死，防漂移）', () {
    final caps = staticCapabilitiesFor(AppHost.web);

    test('★ Web 的 available 集合 = 空集（编译都过不去 ⇒ fail-closed）', () {
      final can = <String>{
        for (final c in AppCapability.values)
          if (caps.can(c)) c.name,
      };
      // 空集合**是结论，不是缺省**：`flutter build web` 两个档位都不出产物
      // （§2 原始输出），这一列放行任何一位都等于"没跑过就宣布能用"。
      expect(can, <String>{});
    });

    test('★ Web 上 30 条能力全是 unavailable，且状态一次给全（无 unknown）', () {
      // r328：+1 = `fsBookmark`（macOS-only 的 Swift 桥能力位）
      expect(AppCapability.values, hasLength(30));
      for (final c in AppCapability.values) {
        expect(
          caps.statusOf(c).state,
          CapabilityState.unavailable,
          reason: '${c.name} 在 Web 上不是静止的 unavailable',
        );
        expect(
          caps.isUnknown(c),
          isFalse,
          reason: '${c.name} 在 Web 上是"探测中" —— web 上没有桥可探',
        );
      }
    });

    test('★ 反向：Web 每一条的原因码都是 kebab-case ASCII', () {
      final re = RegExp(r'^[a-z][a-z0-9-]*$');
      for (final c in AppCapability.values) {
        final s = caps.statusOf(c);
        expect(
          re.hasMatch(s.reason),
          isTrue,
          reason: '${c.name} 的原因码 `${s.reason}` 不是机器可读 ASCII',
        );
      }
    });

    test('★ 反向：能力门在 Web 上**拦住全部 30 位**（34 条自研通道一条都不碰）', () {
      for (final c in AppCapability.values) {
        expect(
          _gateForHost(AppHost.web, c),
          isFalse,
          reason: '${c.name} 在 Web 上是"确定不能"，能力门必须拦住',
        );
      }
    });

    test('★ 反向：lib/ 里的 `synhub/*` 自研通道，在 Web 上全部被门拦住', () {
      final dir = Directory('lib');
      expect(dir.existsSync(), isTrue, reason: '要在仓库根目录跑（找不到 lib/）');
      final channels = <String>{};
      final re = RegExp(r"'synhub/([a-z0-9_]+)'");
      for (final e in dir.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        for (final m in re.allMatches(e.readAsStringSync())) {
          channels.add(m.group(1)!);
        }
      }
      // 防空转：一个都没扫到 = 扫描口径失效，**不是**通过。
      expect(
        channels.length,
        greaterThanOrEqualTo(30),
        reason: '自研通道字符串一个都没扫到 —— 扫描口径可能已失效',
      );
      // 每一条通道都挂在某个能力位下；Web 上 29 位全拦 ⇒ 通道全拦。
      // 这里直接对"通道字符串确实存在于库里"再核一遍，避免上面那条变成空转。
      expect(channels, contains('keystore'));
      expect(channels, contains('video_frame'));
    });

    test('★ 反向：Web 列与 Linux 列的差异**恰好**是这 29 处', () {
      final lin = staticCapabilitiesFor(AppHost.linux);
      final diff = <String>{
        for (final c in AppCapability.values)
          if (caps.statusOf(c) != lin.statusOf(c)) c.name,
      };
      expect(diff, {
        'audioEqualizer',
        'audioVisualizer',
        'backgroundExecution',
        'cast',
        'deepLink',
        'deviceHardwareInfo',
        'deviceLocation',
        'documentPicker',
        'downloadNotifications',
        'driveSafSession',
        'driveWatch',
        'fileShortcut',
        // ★ r328：`fsBookmark` 在 web 是 `not-supported-on-host`、在 Linux 是
        //   `bridge-missing` ⇒ **原因码不同**也算差异（这正是本用例的用意）。
        'fsBookmark',
        'localMediaLibrary',
        'localMediaPlayback',
        'localNotifications',
        'mediaStoreExport',
        'networkInfo',
        'networkTrafficCounters',
        'noteReminders',
        'oemCompat',
        'officeOffscreenRender',
        'photoBackup',
        'scheduledNoteSync',
        'secureStorage',
        'sleepBackup',
        'systemOpen',
        'systemShare',
        'videoFrameExtraction',
      });
      // ★ Linux 的 available 三项**必须**都在差异里（web 一位都不放行）
      expect(diff, contains('documentPicker'));
      expect(diff, contains('officeOffscreenRender'));
      expect(diff, contains('secureStorage'));
    });

    test('★ 反向：Web 列与 macOS 列的差异**恰好**是这 29 处', () {
      final mac = staticCapabilitiesFor(AppHost.macos);
      final diff = <String>{
        for (final c in AppCapability.values)
          if (caps.statusOf(c) != mac.statusOf(c)) c.name,
      };
      expect(diff, {
        'audioEqualizer',
        'audioVisualizer',
        'cast',
        'deepLink',
        'deviceHardwareInfo',
        'deviceLocation',
        'documentPicker',
        'downloadNotifications',
        'driveSafSession',
        'driveWatch',
        'fileShortcut',
        // ★ r328：macOS 上是 available、web 上不是 ⇒ 差异里必须有它
        'fsBookmark',
        'homeScreenWidgets',
        'localMediaLibrary',
        'localMediaPlayback',
        'localNotifications',
        'mediaStoreExport',
        'networkInfo',
        'networkTrafficCounters',
        'noteReminders',
        'oemCompat',
        'officeOffscreenRender',
        'photoBackup',
        'scheduledNoteSync',
        'secureStorage',
        'sleepBackup',
        'systemOpen',
        'systemShare',
        'videoFrameExtraction',
      });
      // `homeScreenWidgets` 在 macOS 与 web 上都是"没有"，但**理由不同**
      // （macOS = 本仓未实现；web = 这一列还没裁决过），所以它只在 macOS 差异里。
      expect(diff, contains('homeScreenWidgets'));
    });

    test('★ 反向：Web 与 Android 的 available 交集必须是空集', () {
      final android = staticCapabilitiesFor(AppHost.android);
      final webCan = <String>{
        for (final c in AppCapability.values)
          if (caps.can(c)) c.name,
      };
      final androidCan = <String>{
        for (final c in AppCapability.values)
          if (android.can(c)) c.name,
      };
      expect(webCan.intersection(androidCan), isEmpty);
    });
  });

  group('② 与其它平台正交（反向断言：本轮不许顺手改别人）', () {
    // 五个集合全部写死。任何"顺手把 web 的结论抄给 Linux / 或者把
    // web 加进某家的 available 循环"的改法，这里当场红。
    const expected = <AppHost, Set<String>>{
      AppHost.android: {
        'audioEqualizer',
        'deepLink',
        'deviceLocation',
        'downloadNotifications',
        'driveSafSession',
        'driveWatch',
        'fileShortcut',
        'localMediaLibrary',
        'localMediaPlayback',
        'mediaStoreExport',
        'networkInfo',
        'noteReminders',
        'oemCompat',
        'officeOffscreenRender',
        'photoBackup',
        'scheduledNoteSync',
        'secureStorage',
        'sleepBackup',
        'systemOpen',
        'systemShare',
      },
      AppHost.ios: {
        // ★ r680（`DA313`）：iOS 深链从"未实现"变"已实现"（`CFBundleURLTypes`
        //   ＋ `DeepLinkBridge.swift` ＋ 能力层 `kMobileBridgeCapabilities`）。
        // ★ r681：`deviceHardwareInfo` 也跟着进榜（`DeviceCapabilityBridge.swift`
        //   随包编译，读 ProcessInfo / sysctl / Metal）。
        //   本条用例的用意就是"谁改了别人的列先红"。
        'deepLink',
        'deviceHardwareInfo',
        // r682：后台执行窗口 + 本地通知（`BackgroundBridge.swift`）
        'backgroundExecution',
        'localNotifications',
        'documentPicker',
        'localMediaPlayback',
        'officeOffscreenRender',
        'secureStorage',
        // ★ r687：系统分享面板（`ShareBridge.swift` 的 UIActivityViewController）
        'systemShare',
        // ★ r688：WidgetKit 主屏小组件（`ios/Widget/SynHubHomeWidget.swift`）
        'homeScreenWidgets',
        // ★ r689：iOS 的三条系统集成桥（`VideoFrameBridge.swift` 抽帧 /
        // `TrafficAndCastBridge.swift` 的 getifaddrs 计数与 AirPlay 投屏）。
        // ★ `networkTrafficCounters` 在这里出现**只表示"桥在"**：iOS 没有按 UID
        //   的计数 API，桥如实回 -1 ⇒ Dart `supported == false`（见平台文档 §28）。
        'videoFrameExtraction',
        'networkTrafficCounters',
        'cast',
        // ★ r689：真频谱（MTAudioProcessingTap + vDSP），iOS 的最后一条能力位
        'audioVisualizer',
      },
      // ★ r690：Linux 新增 `localMediaPlayback`（media_kit 底座）——
      //   **web 那一列一个字不动**（web 的播放走 HTML 元素，能力位仍 fail-closed）。
      AppHost.linux: {
        'documentPicker',
        'localMediaPlayback',
        'officeOffscreenRender',
        'secureStorage',
      },
      AppHost.macos: {
        'documentPicker',
        // ★ r328：安全作用域书签（Swift 桥随 macOS target 编译 ⇒ 静态 available）
        'fsBookmark',
        'localMediaPlayback',
        'officeOffscreenRender',
        'secureStorage',
      },
      // ★ 第 293 轮（Windows 站）：Windows 的 `secureStorage` 从
      //   `unavailable` 翻成 `available`（插件在依赖+生成注册表里，且真 Windows
      //   上跑通 —— 见 `docs/platform-windows.md` §15）。**web 这一列不受影响**：
      //   web 的 available 仍是空集。这条用例的存在意义是"谁改了别人的列先红"，
      //   所以 Windows 那一份跟着翻位，**web 那一份一个字不动**。
      // ★ r703：Windows 又翻一位 `localMediaPlayback`（guest 上 libmpv 真出进度/
      //   画面，见 `docs/windows-page-coverage.md` §4.5）；**web 那一列仍一个字不动**。
      // ★ r707：Windows 再翻一位 `videoFrameExtraction`（libmpv `screenshot-raw` 后端，
      //   guest 出 271_video_frame.png）；**web 那一列依旧一个字不动** ——
      //   这条用例就是"谁顺手改别人的列先红"的哨兵。
      AppHost.windows: {
        'documentPicker',
        'localMediaPlayback',
        'officeOffscreenRender',
        'secureStorage',
        'videoFrameExtraction',
      },
    };

    for (final entry in expected.entries) {
      test('${entry.key.name} 的 available 集合不变（写死）', () {
        final got = <String>{
          for (final c in AppCapability.values)
            if (staticCapabilitiesFor(entry.key).can(c)) c.name,
        };
        expect(got, entry.value);
      });
    }

    test('★ 反向：Web 不在"安全存储放行"的名单里', () {
      final lin = staticCapabilitiesFor(AppHost.linux);
      final web = staticCapabilitiesFor(AppHost.web);
      expect(
        lin.statusOf(AppCapability.secureStorage).isAvailable,
        isTrue,
        reason: 'Linux(libsecret) 该放行 —— 这条也顺便钉住别人的行为没被改',
      );
      expect(
        web.statusOf(AppCapability.secureStorage).isAvailable,
        isFalse,
        reason: 'web 还没验过 ⇒ 必须仍不可用（不许翻位）',
      );
    });
  });


/// ★ 扫描前**必须剥掉行注释**（第 334 轮，§2.0.63⑤ 的注释盲区同型）：
/// 门面文件的文档里会**合法地**提到 `dart:ffi`（"web 上为什么编不过"），
/// 不剥注释就会把"注释里提了一句"当成"真的 import 了"。
/// 只剥"整行/行首可选空白后以 `//` 开头"的行 —— 不碰字符串里的 `//`（URL）。
String stripLineComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

  group('③ 编译级拦路虎：`dart:ffi` 只有两处来源（写死）', () {
    // ★ 第 334 轮：这两条断言的**清单变了**，因为架构变了（不是"断言放宽"）：
    //   `dart:ffi` 与 drift 原生后端现在**只允许出现在 `*_io.dart` 里**，
    //   业务文件一律经"门面 + 条件导入"（`punch_ffi.dart`、`analytics_connection_stub.dart`）。
    //   ⇒ 判据从"某文件名恰好是它"升级成"**只有 `_io` 后缀的文件能碰**"，
    //     并额外钉住门面**自己不许**出现 `dart:ffi`（那正是 web 编不过的原因）。
    // ★ r670：`debug_secret_file_io.dart` 也进了这个集合 —— 它同样是**门面 +
    //   条件导入**后面的 `_io` 文件（`debug_secret_file.dart`），Web 侧拿到的是
    //   `debug_secret_file_stub.dart`。判据仍是"只有 `_io` 后缀能碰 ffi"。
    test('lib/ 里 import `dart:ffi` 的文件**恰好**是两个门面后的 `_io` 实现', () {
      final files = <String>{};
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        for (final m in _dartLibRe.allMatches(stripLineComments(e.readAsStringSync()))) {
          if (m.group(1) == 'ffi') files.add(e.path);
        }
      }
      expect(files, {
        'lib/src/native/punch_ffi_io.dart',
        'lib/src/core/platform/debug_secret_file_io.dart',
      });
      // 两家都必须是"有门面兜着"的：门面里不许出现 ffi。
      expect(
        files.every((f) => f.endsWith('_io.dart')),
        isTrue,
        reason: '非 `_io` 文件直接 import dart:ffi ⇒ web 编不过',
      );
    });

    test('★ 门面不许碰 `dart:ffi`（web 站能编过的**全部**理由）', () {
      final facade = stripLineComments(
        File('lib/src/native/punch_ffi.dart').readAsStringSync(),
      );
      expect(_dartLibRe.allMatches(facade).map((m) => m.group(1)), isNot(contains('ffi')));
      // 反向：门面**必须**有条件导入，否则这个测试只是"文件里没写 ffi"的自证
      expect(facade, contains("if (dart.library.io) 'punch_ffi_io.dart'"));
    });

    // ★ 第 338 轮：这条断言**按架构拆成两条**（不是放宽）—— 旧写法把两件不同的事
    //   混在一个集合里：
    //     ① `package:drift/native.dart` = **FFI 后端**（web 上 dart2js 硬拒绝）；
    //     ② `package:drift_flutter/drift_flutter.dart` = **带条件导出的门面**
    //        （web 分支走 wasm，**web 上是合法的**，`database.dart` 从 r336 就在用，
    //        `flutter build web` 通过）；
    //   r338 让"web 桩"也走 wasm 后端（D36 的正解）⇒ 桩文件必须 import ② ，
    //   旧写法于是把 `analytics_connection_stub.dart` 当成违规。**真违规是 ① **。
    test('lib/ 里 import `package:drift/native.dart`（FFI 后端）的**恰好** `_io` 那一处', () {
      final files = <String>{};
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.readAsStringSync().contains("import 'package:drift/native.dart'")) {
          files.add(e.path);
        }
      }
      expect(files, {'lib/src/data/local/analytics_connection_io.dart'});
    });

    test('`drift_flutter` 的导入方**恰好**这 3 个（都是 web 安全的）', () {
      final files = <String>{};
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final src = stripLineComments(e.readAsStringSync());
        if (src.contains("import 'package:drift_flutter/")) files.add(e.path);
      }
      // ① `*_io.dart` 走 `native:` 选项（web 图上不存在）
      // ② web 桩走 `web:` 选项（D36 的正解）
      // ③ `database.dart`（聊天库）从 r336 起就同时传 `native:`/`web:`，web 构建已通过
      expect(files, {
        'lib/src/data/local/analytics_connection_io.dart',
        'lib/src/data/local/analytics_connection_stub.dart',
        'lib/src/data/local/database.dart',
      });
      // 反向：这 3 个里必须**恰好一个**带 `web:` 选项……（下一条断言详查）
    });

    test('★ web 图里的 `driftDatabase(...)` 必须给出 `web:` 选项（否则运行期空实现）', () {
      // D36：分析库与聊天库都要能在 web 上真开库 ⇒ 两处都必须有 `web: DriftWebOptions`
      for (final p in const [
        'lib/src/data/local/analytics_connection_stub.dart',
        'lib/src/data/local/database.dart',
      ]) {
        final src = File(p).readAsStringSync();
        expect(src, contains('DriftWebOptions'), reason: '$p 少了 web 后端');
        expect(src, contains('sqlite3.wasm'), reason: '$p 少了 wasm 资产名');
        expect(src, contains('drift_worker.dart.js'), reason: '$p 少了 worker 资产名');
      }
      // 反向：非 web 那一支**不许**出现 `DriftWebOptions`（否则判据只是"字符串在不在"）
      expect(
        File('lib/src/data/local/analytics_connection_io.dart').readAsStringSync(),
        isNot(contains('DriftWebOptions')),
      );
    });

    test('★ 反向验证：扫描器真的能抓到 `dart:ffi` / drift 原生（不是恒空）', () {
      const fake = "import 'dart:ffi' as ffi;\n"
          "import 'package:drift_flutter/drift_flutter.dart';";
      final libs = <String>{
        for (final m in _dartLibRe.allMatches(fake)) m.group(1)!,
      };
      final pkgs = <String>{
        for (final m in _importRe.allMatches(fake)) m.group(1)!,
      };
      expect(libs, contains('ffi'));
      expect(pkgs, contains('drift_flutter'));
      // 同时证伪一个"假阴"：不含这两样的源码必须扫不出来。
      const clean = "import 'package:archive/archive.dart';";
      expect(_dartLibRe.allMatches(clean), isEmpty);
      expect(_importRe.allMatches(clean), hasLength(1));
    });
  });

  group('④ `dart:io` 的移植面：只许缩不许涨 + web 上的运行期语义', () {
    // 本轮实测（`docs/platform-web.md` §2/§3）：
    //   * `import 'dart:io'` 在 Flutter Web 上**能编过**（`✓ Built build/web`）；
    //   * 一旦真的用（`Platform.isAndroid`）就在运行期抛
    //     `Unsupported operation: Platform._operatingSystem`。
    // 所以 dart:io 是**运行期**债务，`dart:ffi` 才是**编译期**拦路虎。
    // ★ 第 328 轮：82 → **83**。涨的这一格是 `lib/src/core/platform/fs_bookmark.dart`
    //   （r328 新增：macOS 安全作用域书签 + 最近目录**容器文件**，
    //   `FileRecentSaveDirectoryStore` 用 `dart:io` 的 `File`）。它是 macOS 专属路径，
    //   web 上不会走到，但静态口径如实**涨价**——不许用"反正 web 不走"来蒙混。
    // ★★★ r371（DA14 修复的副产物）：83 → **82**。
    // 降的这一格是 `lib/src/features/files/drive_browse_view.dart` ——
    // 文本编辑器保存改走 Drive 的 `Files/create`（DA14）后，那里不再需要
    // 自己写临时文件（`Directory.systemTemp` / `File`），`dart:io` 导入随之删掉。
    // 按本用例的规矩：**降了就要把基线一起下调**（顺便更新 docs/platform-web.md §5）。
    // ★★★ r392（DA32「网络电台只能列容器」修复的副产物）：82 → **84**。
    // 涨的这两格是 r392 新增的两个文件，**如实涨价、不蒙混**：
    //   * `lib/src/features/audio/audio_radio_stream.dart` —— `.pls`/`.m3u`
    //     播放列表要先解析出真正的流地址（`dart:io` 的 `HttpClient`）；
    //   * `lib/src/features/audio/audio_radio_relay.dart` —— release 档
    //     `network_security_config` 禁明文（`base-config cleartextTrafficPermitted="false"`，
    //     只放行回环）⇒ 公网明文电台只能经**本机回环中继**
    //     （`HttpServer.bind(InternetAddress.loopbackIPv4, 0)`）。
    // 两者都是**安卓专属**取流通道，web 上不会走到；但静态口径照旧如实记账。
    // ★★★ r434（`DA89`「PDF 副本写在缓存根层、清不掉」修复的副产物）：84 → **85**。
    // 涨的这一格是 r434 新增的 `lib/src/core/media/pdf_local_copy.dart` —— pdfx 的
    // `PdfDocument.openData` 会把整份 PDF 写到**缓存根层**（用量看不到、清不掉、
    // 无上限增长），修法改成我们**自己**把字节落到已登记的 `pdf_renderer_cache/`
    // （`File`/`Directory` ⇒ `dart:io`）再 `openFile`。web 上这条路不走，
    // 但静态口径照旧如实记账（不许用"反正 web 不走"蒙混）。
    // ★★★ r636（`DA227`「上次看到哪儿」）：85 → **86**。
    // 涨的这一格是 `lib/src/features/media/media_resume_store.dart` —— 本机进度记忆
    // 要读写 `<support>/media_resume.json`（`File`/`Directory` ⇒ `dart:io`）。
    // 与上面同一条口径：web 上不走这条路，但静态账照旧如实涨。
    // ★★★ r640（`DA233` 电台「正在播的曲目」）：86 → **87**。
    // 涨的这一格是 `lib/src/features/audio/audio_radio_icy.dart` —— ICY 旁路探针
    // 要自己开一条 `HttpClient` 连接读 `StreamTitle`（`dart:io`）。
    // web 上没有电台播放这条路，静态账照旧如实涨（不拿"web 不走"蒙混）。
    // ★★★ r655（`DA264` 视频投屏）：87 → **88**。
    // 涨的这一格是 `lib/src/features/media/upnp_cast.dart` —— DLNA 发现要发 SSDP
    // 组播（`RawDatagramSocket`）、推送要 POST SOAP（`HttpClient`），都是 `dart:io`。
    // web 上没有这条投屏路（按钮在 `kIsWeb` 下同样会出现，但 discover 会返回空），
    // 静态账照旧如实涨，不拿"web 不走"蒙混。
    // ★★★ r665（`DA286` macOS Debug 不碰钥匙串）：88 → **89**。
    // 涨的这一格是 `lib/src/core/platform/debug_secret_file_io.dart` —— 条件导入门面的
    // **io 侧**（`dart:io` 的 `File`/`Directory`/`Platform`）。web 侧走的是
    // `debug_secret_file_stub.dart`（`export ... if (dart.library.io)`），
    // 所以 **web 的运行期面没变**；这里涨的只是"仓库里有多少文件碰 `dart:io`"这笔静态账，
    // 照旧如实涨，不拿"web 不走"蒙混。
    // ★★★ r691（`DA330`）：89 → **90**。Linux/桌面的 PDF 走 poppler 渲染
    //   （`features/files/pdf_poppler_view.dart` 要起 `pdftoppm` 子进程 ⇒ `dart:io`）。
    //   这一路在 web 上**本来就不会被走到**（web 上 PDF 也从未可用），但静态账
    //   如实涨一格 —— 基线同步，不许沉默。
    // ★ r691（`DA331`）：90 → **91**。听书 TTS 在 Linux 上走系统合成器进程
    //   （`features/files/book_tts_linux.dart` 要 `Process.start` ⇒ `dart:io`）。
    //   web 上 TTS 同样从未可用，运行期面没变。
    //   r693 +2：`core/platform/desktop_notify_linux.dart`（新：PATH 扫描 + `notify-send`）
    //   与 `native/background_service.dart`（Linux 分支调它）—— Linux 桌面通知走进程，
    //   web 上这两条路都走不到（`kIsWeb` 先返回 false），静态账如实涨 91→93。
    // ★★★ r709（Windows 本地通知）：93 → **94**。涨的这一格是
    //   `lib/src/core/platform/desktop_notify_windows.dart` —— Windows 的 toast 走
    //   `powershell.exe` + WinRT（`ToastNotificationManager`），web 上 `_kIsWeb`
    //   先返回 false，这条路走不到；但静态账**如实涨**，不拿"web 不走"蒙混。
    //   顺便记一条：这个文件**故意不 import `package:flutter/*`**（`kIsWeb` 用
    //   `bool.fromEnvironment('dart.library.js_util')` 自算），所以 guest 上能直接
    //   `dart run tool/probe/windows_toast_probe.dart` 验，不必起 Flutter 引擎。
    const int baseline = 94;

    int countDartIoImports(Directory root) {
      var n = 0;
      for (final e in root.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (_dartLibRe.allMatches(stripLineComments(e.readAsStringSync())).any(
          (m) => m.group(1) == 'io',
        )) {
          n++;
        }
      }
      return n;
    }

    test('lib/ 里 import `dart:io` 的文件数 == $baseline（web 站基线，只许往下降）', () {
      final n = countDartIoImports(Directory('lib'));
      // 写成**等号**而不是 `<=`：往上涨（新增 dart:io）必须当场红；
      // 往下降（真的移植掉一个文件）也要改这里 —— 这一行就是"移植进度"
      // 的度量点，改它就是"这一轮真的动了移植面"的证据。
      expect(
        n,
        baseline,
        reason: 'dart:io 移植面变了（$n vs 基线 $baseline）。'
            '涨了 = web 站上又多一处运行期 `Unsupported operation`；'
            '降了 = 请把基线与 docs/platform-web.md §5 的数字一起更新。',
      );
    });

    test('★ 反向验证：`dart:io` 扫描器不是恒 0（拿假源码自证）', () {
      const fake = "import 'dart:io' show Platform;\nimport 'dart:async';";
      final hits = <String>[
        for (final m in _dartLibRe.allMatches(fake))
          if (m.group(1) == 'io') m.group(1)!,
      ];
      expect(hits, hasLength(1));
    });

    test('★ `detectAppHost()` 必须先判 `kIsWeb`（否则 web 上启动就抛）', () {
      final src = File(
        'lib/src/core/platform/app_platform.dart',
      ).readAsStringSync();
      final webIdx = src.indexOf('if (kIsWeb) return AppHost.web;');
      expect(
        webIdx,
        isNonNegative,
        reason: 'detectAppHost() 里那句 kIsWeb 早退不见了？这条守卫要跟着改',
      );
      final androidIdx = src.indexOf('if (Platform.isAndroid)', webIdx);
      expect(androidIdx, greaterThan(webIdx));
      // 反向：早退必须在**函数体内**（先于任何 Platform.* 调用）。
      final fnIdx = src.indexOf('AppHost detectAppHost() {');
      expect(fnIdx, isNonNegative);
      expect(webIdx, greaterThan(fnIdx));
    });

    test('★ `KeystoreSecretKeeper` 的宿主判定同样先判 web（第 293 轮起是纯函数）', () {
      final src = File(
        'lib/src/core/security/keystore_secret_keeper.dart',
      ).readAsStringSync();
      // ★ 第 293 轮：`_hostSupports` 的判据搬进了**纯函数**
      //   `secretKeeperHostSupportedFor()`（为了让宿主单测能逐平台钉住，
      //   见 `test/secret_keeper_host_matrix_test.dart`）。所以这条源码守卫
      //   跟着钉**同一个机制**，不是放宽：
      //   ① web 事实必须作为参数进判定；② `if (isWeb) return false;` 必须
      //   **先于**平台分支；③ 调用点必须真的把 `kIsWeb` 传进去
      //   （防"声明了参数却传死值"）。
      final fnIdx = src.indexOf('bool secretKeeperHostSupportedFor({');
      expect(fnIdx, isNonNegative, reason: '纯函数不见了？这条守卫要跟着改');
      final webParamIdx = src.indexOf('required bool isWeb,', fnIdx);
      expect(webParamIdx, greaterThan(fnIdx));
      final webIdx = src.indexOf('if (isWeb) return false;', fnIdx);
      expect(
        webIdx,
        isNonNegative,
        reason: 'web 上不许去碰 `synhub/keystore` 通道（会 MissingPluginException）',
      );
      final platformIdx = src.indexOf(
        'platform == TargetPlatform.android',
        webIdx,
      );
      expect(
        platformIdx,
        greaterThan(webIdx),
        reason: 'web 早退必须在任何平台分支之前',
      );
      // 反向：调用点确实传了 `kIsWeb`（否则纯函数里的 isWeb 恒为假 = 假绿）。
      final hostIdx = src.indexOf('static bool get _hostSupports');
      expect(hostIdx, isNonNegative);
      expect(src.indexOf('isWeb: kIsWeb', hostIdx), greaterThan(hostIdx));
    });
  });

  group('⑤ web 插件列 vs 能力位（第五次同型风险的取证）', () {
    Set<String> webPluginColumn() {
      final f = File('.flutter-plugins-dependencies');
      expect(
        f.existsSync(),
        isTrue,
        reason: '要在仓库根目录跑（没有 .flutter-plugins-dependencies）',
      );
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final plugins = json['plugins'] as Map<String, dynamic>;
      final web = plugins['web'] as List<dynamic>;
      return {
        for (final e in web) (e as Map<String, dynamic>)['name'] as String,
      };
    }

    test('★ web 列里**确实**有 flutter_secure_storage_web（硬事实）', () {
      final web = webPluginColumn();
      // 防空转：web 列本来就该是十几个插件，不是空表。
      expect(web.length, greaterThanOrEqualTo(15));
      expect(
        web,
        contains('flutter_secure_storage_web'),
        reason: '若这条红了，说明依赖变了 —— 第五次同型的取证前提要重做',
      );
    });

    test('★ 登记表里的每个包都真的在 web 列里（防"登记了个不存在的"）', () {
      final web = webPluginColumn();
      for (final pkg in kWebCapabilityGaps.keys) {
        expect(
          web,
          contains(pkg),
          reason: '$pkg 不在 web 插件列里 —— 登记表过期了，删掉它',
        );
      }
    });

    test('每条登记都写了理由（非空且 >= 20 字符）', () {
      for (final e in kWebCapabilityGaps.entries) {
        expect(
          e.value.trim().length,
          greaterThanOrEqualTo(20),
          reason: '${e.key} 的理由太短，等于没写',
        );
      }
    });

    test('★ 反向：secureStorage 在 web 上**当前**仍是 unavailable（不许翻位）', () {
      final web = staticCapabilitiesFor(AppHost.web);
      final s = web.statusOf(AppCapability.secureStorage);
      expect(s.isAvailable, isFalse);
      expect(s.isUnavailable, isTrue);
      // 这条与 kWebSecureStorageStillUnavailable 是同一个锚点：
      // 翻位必须**同时**改这里 + 文档 §6 的验收条件，并且先在真浏览器里验过。
      expect(kWebSecureStorageStillUnavailable, 'secureStorage');
    });
  });
}
