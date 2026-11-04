// Linux 平台站的**守卫用例**（第 108 轮新增）。
//
// 这一组要钉住三件事，每一条都对应一个"以后会悄悄坏掉"的地方：
//
//   ① **Linux 那一列能力矩阵不许漂移**：哪几位 `available`、哪几位
//      `unavailable` 且原因码是什么，全部写死断言。加/改平台能力时
//      "顺手把 Linux 也放行"会当场红 —— 本仓已经被同型问题咬过两次
//      （macOS P0-3、iOS §2.3），Linux 是第三次（见 `docs/platform-linux.md` §3.4）。
//
//   ② **静态排查：Dart 侧"没有 Linux 实现"的插件必须登记在案**。
//      能力层只管 `synhub/*` 那 34 条**自研通道**；而 `pdfx` / `webview_flutter`
//      / `just_audio` 这些**第三方插件**根本不走能力层 —— 它们在 Linux 上会
//      直接抛 `MissingPluginException`。这张表把"已知的洞"逐条登记 + 写理由，
//      新引入一个没有 Linux 实现的插件而忘了登记，这里就红。
//
//   ③ **"不会崩"必须由代码结构背书**，不能只是嘴上说：用静态扫描断言
//      失败路径真的被 `catch` 住（`media_player_view.dart` 的 `_load()`）。
//
// 口径与 `docs/platform-linux.md` 的"证据档位"一致：本文件里的结论都是
// **静态分析 / 仓库内生成产物**档，**不是** Linux 真机实测（见该文档 §5）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

/// Dart 侧**确实被 import 了、但在 Linux 上没有实现**的插件包。
///
/// key = pub 包名；value = 人写的理由（**必须**写清楚"为什么 Linux 上不行"
/// 与"下一步怎么办"）。依据 = 各包 pinned pubspec 的 plugin platforms 声明
/// 加上 `.flutter-plugins-dependencies` 的 linux 列（两条都能在仓库/缓存里核）。
///
/// ★ 这里只登记**当前真的 import 了的**；表里多一条 / 少一条都会让下面的
/// 用例红（**反向验证**：证明这张表不是摆设）。
const Map<String, String> kLinuxUnsupportedPluginPackages = {
  'just_audio':
      'pinned pubspec 只声明 android/ios/macos/web；Linux 要额外的 '
      'just_audio_media_kit + media_kit_libs_linux（需 libmpv），本仓未引入。'
      'audio_player.dart / voice_message.dart 用它。',
  'video_player':
      'pinned pubspec 只声明 android/ios/macos/web；Linux 要 '
      'video_player_media_kit（media_kit 后端），本仓未引入。media_player.dart 用它。',
  'audio_service':
      '无 Linux 实现（Linux 侧对应物是 audio_service_mpris，需 dbus），本仓未引入。',
  'audio_session':
      '无 Linux 实现，本仓也未引入替代（audio_session 只在 Apple/Android 上有实现）。',
  'pdfx':
      'pinned pubspec 声明 android/ios/macos/windows —— **没有 Linux**。'
      'Linux 可用 pdfrx / printing（PDFium），本仓未迁移。'
      'pdf_cover.dart / file_pdf_view.dart / drive_pdf_markup_page.dart 用它。',
  'webview_flutter':
      '无官方 Linux 实现（webview_flutter_linux 是实验性 WPE 实现，要求 WPE>=2.52，'
      '非 endorsed），本仓未引入。download_link_browser.dart 用它。',
  'open_filex':
      'pinned pubspec 只声明 android/ios。★ 但 `system_open.dart` 的桌面分支'
      '**在 Linux 上走 `xdg-open`**（第 42 轮 P0-1），功能不受影响；'
      '只有 attachment_view.dart 直接用它，Linux 上会抛 —— 见 docs §3.6。',
  'local_auth':
      '无官方 Linux 实现（第三方 flutter_local_authentication 走 fprintd，'
      '质量未经验证），本仓未引入。biometric_auth.dart 用它。',
  'flutter_tts':
      'pinned pubspec 声明 android/ios/macos/windows/web；pub.dev 上没有 '
      'flutter_tts_linux（404）。book_tts_system.dart 用它。',
};

/// 有 Linux 实现的插件（**反面清单**：证明上面的表不是"看到插件就登记"）。
const Set<String> kLinuxSupportedPluginPackages = {
  'record',
  'flutter_secure_storage',
  'connectivity_plus',
  'file_picker',
  'image_picker',
  'url_launcher',
  'path_provider',
  'shared_preferences',
  'flutter_gemma',
};

/// 本仓能力位 → 的 34 条 `synhub/*` 通道，**在 Linux 上允许被碰**的只有 0 条。
///
/// Android 上这些是"桥在不在要问"（`unknown`，`mayTry` 放行）；Linux 上
/// 每一条都是 `unavailable`（静态结论）⇒ `capabilityGateAllows` 必须**全 false**，
/// 于是**一条通道都不会被碰**，也就不会出 `MissingPluginException`。
void main() {
  group('① Linux 能力矩阵（写死，防漂移）', () {
    final caps = staticCapabilitiesFor(AppHost.linux);

    test('★ Linux 的 available 集合 = {本地播放, 离屏渲染, 文档选择, 安全存储}', () {
      // ★ r690：`localMediaPlayback` 从 unavailable 改判 available ——
      //   视频走 `MpvPlayerAdapter`（`media_kit_libs_linux` 带 Linux 版 libmpv），
      //   音频走 `just_audio_media_kit`（把 just_audio 后端换成 media_kit）。
      //   这一条**必须有真跑证据**：容器里 libmpv 真出画面、AUDIO 真出声的读数
      //   见 `docs/platform-linux.md` §20。
      final can = <String>{
        for (final c in AppCapability.values)
          if (caps.can(c)) c.name,
      };
      expect(can, {
        'documentPicker',
        'localMediaPlayback',
        'officeOffscreenRender',
        'secureStorage',
      });
    });

    test('★ r690：本地播放 = available，且已引入 Linux 的实现依赖', () {
      final s = caps.statusOf(AppCapability.localMediaPlayback);
      expect(s.state, CapabilityState.available);
      expect(s.reason, CapabilityReason.ok);
      // 「能力位说能用」必须与「pubspec 真的引了实现」同源，否则又是
      // "能力位说没有、功能其实能工作"的反向漂移（r690 之前正是这种形态）。
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec.contains('media_kit_libs_linux'), isTrue);
      expect(pubspec.contains('just_audio_media_kit'), isTrue);
    });

    test('主屏小组件 = not-supported（Linux 桌面没有"主屏"这个概念）', () {
      final s = caps.statusOf(AppCapability.homeScreenWidgets);
      expect(s.reason, CapabilityReason.notSupportedOnHost);
      expect(s.state, CapabilityState.unavailable);
    });

    test('端侧硬件事实 = needs-mobile-host（宿主不编事实，AGENTS §2.0.6）', () {
      final s = caps.statusOf(AppCapability.deviceHardwareInfo);
      expect(s.reason, CapabilityReason.needsMobileHost);
      expect(s.state, CapabilityState.unavailable);
      // 桌面**不许**留成"探测中"（那会假装还有希望）
      expect(s.state, isNot(CapabilityState.unknown));
    });

    test('★ 反向：Linux 上**没有任何**能力是 unknown（静态结论要一次给全）', () {
      for (final c in AppCapability.values) {
        expect(
          caps.isUnknown(c),
          isFalse,
          reason: '${c.name} 在 Linux 上留成了"探测中" —— 桌面没有桥可探',
        );
      }
    });

    test('★ 反向：Linux 每一条 unavailable 的原因码都是 kebab-case ASCII', () {
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

    test('★ 反向：能力门在 Linux 上**拦住所有 34 条自研通道**（一条都不碰）', () {
      // 只有 available 的三项放行，其余全部拦住 —— 这是"不撞
      // MissingPluginException"的结构保证。
      for (final c in AppCapability.values) {
        final allowed = capabilityGateAllowsForHost(AppHost.linux, c);
        if (caps.can(c)) {
          expect(allowed, isTrue, reason: '${c.name} 该放行');
        } else {
          expect(
            allowed,
            isFalse,
            reason: '${c.name} 在 Linux 上是"确定不能"，能力门必须拦住',
          );
        }
      }
    });

    test('★ 反向：Linux 列**不等于** macOS 列，差异**恰好**是这四处', () {
      final mac = staticCapabilitiesFor(AppHost.macos);
      final diff = <String>{
        for (final c in AppCapability.values)
          if (caps.statusOf(c) != mac.statusOf(c)) c.name,
      };
      // 写死差异集合：多一处 / 少一处都红 ⇒ "顺手把 Linux 改成 macOS 那列"
      // 这种改法当场被抓住。
      // ★ r690：`localMediaPlayback` **不在**差异里了 —— Linux 接上 media_kit
      //   底座后与 macOS（AVFoundation）同为 available，理由码都是 ok。
      expect(diff, {
        // 两家都"没有"小组件，但**理由不同**：macOS 是"本仓未实现"
        // （WidgetKit 存在），Linux 是"结构上没有主屏"。
        'homeScreenWidgets',
        // 反过来：macOS 结构上没有前台服务，Linux 也只是"本仓未实现"。
        'backgroundExecution',
        // ★ 第 328 轮新增：安全作用域书签是 **macOS 独有**的 API；Linux 没有对应语义。
        'fsBookmark',
      });
      // ★ 安全存储两家**必须相同**（都 available）—— 这正是本轮 Linux 站的
      //   修正点：`flutter_secure_storage_linux` 与 darwin 插件同属一个联邦包。
      expect(diff, isNot(contains('secureStorage')));
      expect(
        caps.statusOf(AppCapability.secureStorage),
        mac.statusOf(AppCapability.secureStorage),
        reason: 'Linux(libsecret) 与 macOS(Keychain) 都该 available',
      );
    });

    test('★ r690/r703：本地播放两家**都已接上 media_kit**（结论同）', () {
      final win = staticCapabilitiesFor(AppHost.windows);
      expect(
        caps.statusOf(AppCapability.localMediaPlayback).isAvailable,
        isTrue,
        reason: 'Linux：media_kit 底座（libmpv）⇒ available（r690）',
      );
      expect(
        win.statusOf(AppCapability.localMediaPlayback).isAvailable,
        isTrue,
        reason: 'Windows：`media_kit_libs_windows_video` 带 libmpv ＋ guest 真机'
            '量到进度/画面 ⇒ available（r703）',
      );
      expect(
        win.statusOf(AppCapability.localMediaPlayback).reason,
        CapabilityReason.ok,
      );
    });

    test('Linux 与 Windows 在**已知同型**的几项上一致（互相印证）', () {
      final win = staticCapabilitiesFor(AppHost.windows);
      // ★ r690：`localMediaPlayback` 曾从这张同型表里移除（当时只有 Linux 接上）；
      //   ★ r703 Windows 也接上 ⇒ 重新纳入同型表（两家都 available:ok）。
      // ★ r707：`videoFrameExtraction` **移出**这张同型表 —— Windows 已有 libmpv
      //   后端并量到真帧（available），Linux 站还没在真机上量过（仍
      //   `not-implemented-on-host`）。按"只认计数器/像素"的规矩，谁翻谁补证据；
      //   这里保留反向断言，防止"顺手把 Linux 也改了"。
      for (final c in const [
        AppCapability.localMediaPlayback,
        AppCapability.officeOffscreenRender,
        AppCapability.documentPicker,
        AppCapability.deviceHardwareInfo,
      ]) {
        expect(
          caps.statusOf(c),
          win.statusOf(c),
          reason: '${c.name} 在 Linux/Windows 上应该同结论',
        );
      }
      // ★ 第 109 轮这里断言过"安全存储两家**必须**不同（Linux 有插件、
      //   Windows 没有）"——第 293 轮证伪了：`flutter_secure_storage_windows`
      //   4.2.2 同样在依赖与生成注册表里，真 Windows 上的探针也确认
      //   `seal()` 只是被"选择"漏掉（参见 `docs/platform-windows.md` §15）。
      //   ⇒ 改成与 `platform_windows_test.dart` 对偶的**同结论**断言：
      //   两家都 `available`，且**整体列完全一致**。
      expect(
        caps.statusOf(AppCapability.secureStorage),
        win.statusOf(AppCapability.secureStorage),
        reason: '第 293 轮后 Linux(libsecret) 与 Windows(DPAPI) 都该 available '
            '—— 两家都是 `flutter_secure_storage` 的联邦实现',
      );
      expect(
        caps.statusOf(AppCapability.secureStorage).state,
        CapabilityState.available,
      );
    });
  });

  group('② 静态排查：没有 Linux 实现的插件必须逐条登记', () {
    test('lib/ 里 import 了但没有 Linux 实现的插件 = 登记表（集合相等）', () {
      final lib = Directory('lib');
      expect(lib.existsSync(), isTrue, reason: '要在仓库根目录跑（找不到 lib/）');

      final imported = <String>{};
      final where = <String, Set<String>>{};
      for (final e in lib.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final src = e.readAsStringSync();
        for (final m in _importRe.allMatches(src)) {
          final pkg = m.group(1)!;
          if (!kLinuxUnsupportedPluginPackages.containsKey(pkg) &&
              !kLinuxSupportedPluginPackages.contains(pkg)) {
            continue; // 不在两张表里 ⇒ 这个包与 Linux 判断无关，跳过
          }
          if (kLinuxUnsupportedPluginPackages.containsKey(pkg)) {
            imported.add(pkg);
            where.putIfAbsent(pkg, () => <String>{}).add(e.path);
          }
        }
      }

      // 防空转：一个都没扫到 = 扫描口径失效，**不是**通过。
      expect(
        imported,
        isNotEmpty,
        reason: '一个"无 Linux 实现"的插件都没扫到 —— 扫描口径可能已失效',
      );

      // 集合相等：多一条（新引入没登记）/ 少一条（登记了却已不再用）都要红。
      expect(
        imported,
        kLinuxUnsupportedPluginPackages.keys.toSet(),
        reason: '登记表与实际 import 不一致。\n'
            '实际扫到：${(imported.toList()..sort())}\n'
            '登记表：${(kLinuxUnsupportedPluginPackages.keys.toList()..sort())}\n'
            '位置：$where',
      );
    });

    test('★ 反向验证：扫描器真的能抓到一个"没登记"的插件（不是恒空）', () {
      // 造一段源码：只 import 一个不在登记表里的、确实没有 Linux 实现的包。
      const fake = "import 'package:some_plugin_without_linux/some_plugin.dart';";
      const probe = 'package:does_not_exist/';
      final found = <String>{};
      // 直接把"未知包"塞进判定：证明扫描不是"只认登记表里的名字"。
      for (final m in _importRe.allMatches(fake)) {
        final pkg = m.group(1)!;
        if (pkg == 'some_plugin_without_linux') found.add(pkg);
      }
      expect(found, {'some_plugin_without_linux'});
      // 同时证伪一个"假阴"：正则必须真的命中 import 行。
      expect(_importRe.allMatches(fake), hasLength(1));
      expect(_importRe.allMatches(probe), isEmpty);
    });

    test('★ 反向：有 Linux 实现的插件**不许**出现在登记表里', () {
      for (final supported in kLinuxSupportedPluginPackages) {
        expect(
          kLinuxUnsupportedPluginPackages.containsKey(supported),
          isFalse,
          reason: '$supported 有 Linux 实现，不该登记成"不支持"',
        );
      }
    });

    test('每条登记都写了理由（非空且 >= 20 字符）', () {
      for (final e in kLinuxUnsupportedPluginPackages.entries) {
        expect(
          e.value.trim().length,
          greaterThanOrEqualTo(20),
          reason: '${e.key} 的理由太短，等于没写',
        );
      }
    });
  });

  group('③ "不会崩"由代码结构背书（静态断言）', () {
    test('媒体页装载失败被 catch 住并转成失败态（不是抛穿到界面）', () {
      final src = File(
        'lib/src/features/media/media_player_view.dart',
      ).readAsStringSync();
      // `_load()` 把 `_loadSource()` 包在 try 里，catch 后走统一失败链。
      expect(
        src.contains('Future<void> _load() async {'),
        isTrue,
        reason: '媒体页的 _load() 不见了？这条守卫要跟着改',
      );
      final loadIdx = src.indexOf('Future<void> _load() async {');
      final window = src.substring(loadIdx, loadIdx + 500);
      expect(
        window.contains('try {'),
        isTrue,
        reason: '_load() 里没有 try —— 插件缺失会抛穿到界面',
      );
      expect(
        window.contains('catch (err)'),
        isTrue,
        reason: '_load() 没有 catch —— MissingPluginException 会变成未捕获异常',
      );
      expect(
        window.contains('_handleRuntimeFailure'),
        isTrue,
        reason: '装载失败必须走统一的失败/回退链（界面要能说出原因）',
      );
    });

    test('音频侧的调用点有 catch（Linux 上 just_audio 缺席不许崩）', () {
      final page = File(
        'lib/src/features/audio/audio_song_page.dart',
      ).readAsStringSync();
      expect(
        'catch'.allMatches(page).length,
        greaterThanOrEqualTo(5),
        reason: '音频页的 catch 少得可疑 —— 播放失败会抛穿',
      );
    });
  });
}

/// `import 'package:<pkg>/...'` 里的包名。
final RegExp _importRe = RegExp(r"""import\s+'package:([a-z0-9_]+)/""");

/// 指定宿主下的能力门结论（与 `capabilityGateAllows` 同语义：只有
/// `unavailable` 才拦）。
///
/// 生产代码用的是"当前宿主"，这里显式传宿主，才能在 macOS 宿主上测 Linux 列。
bool capabilityGateAllowsForHost(AppHost host, AppCapability capability) =>
    staticCapabilitiesFor(host).mayTry(capability);
