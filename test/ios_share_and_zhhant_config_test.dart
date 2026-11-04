// r687：iOS 站两条「未实现」的静态守卫 —— 系统分享面板（`DA320`）与
// 繁体中文显示名（`DA321`）。
//
// 为什么要有静态守卫：这两条在模拟器上的运行期证据分别是一次
// `integration_test/r687_ios_share_sheet_test.dart` 与一张系统弹框像素，
// 但**接线本身**（pbxproj 有没有把 Swift 编进去、AppDelegate 有没有注册、
// Info.plist 的 lproj 有没有进包、能力位有没有翻对）都是"漏一条就静默坏"的位置：
//   * Swift 文件没进 `Sources` ⇒ 通道 `MissingPluginException`（不报编译错）；
//   * `zh-Hant.lproj` 没进 `PBXVariantGroup` ⇒ 系统回落 `CFBundleDisplayName`；
//   * 能力位没从 Kotlin-only 集合里移出 ⇒ Dart 侧连通道都不碰（返回 false）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('DA320 iOS 系统分享面板（UIActivityViewController）', () {
    test('★ 桥的三件套：Swift 实现 / pbxproj 编译进 Runner / AppDelegate 注册', () {
      final swift = _read('ios/Runner/ShareBridge.swift');
      // 两条通道名必须与 Dart 侧逐字一致
      expect(swift, contains('static let shareTextChannel = "synhub/share_text"'));
      expect(swift, contains('static let mediaOpenChannel = "synhub/media_open"'));
      expect(swift, contains('UIActivityViewController('));
      // iPad 缺锚点必崩（NSGenericException）
      expect(swift, contains('popoverPresentationController'));
      expect(swift, contains('sourceRect'));
      // 必须从活着的 scene 取 VC（keyWindow 已废弃且多 scene 不可靠）
      expect(swift, contains('connectedScenes'));
      // 空载荷 / 落不了盘的附件必须如实 false
      expect(swift, contains('guard !text.isEmpty else'));
      expect(swift, contains('guard urls.count == paths.count'));

      final proj = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(proj, contains('ShareBridge.swift in Sources'));
      expect(proj, contains('path = ShareBridge.swift'));
      final appDelegate = _read('ios/Runner/AppDelegate.swift');
      expect(appDelegate, contains('ShareBridge.register(with: registrar)'));
      expect(appDelegate, contains('forPlugin: "SynHubShare"'));
    });

    test('★ 能力位：iOS 与 Android 都放行 systemShare，桌面/web 仍拦住', () {
      for (final host in const [AppHost.ios, AppHost.android]) {
        final caps = staticCapabilitiesFor(host);
        expect(caps.can(AppCapability.systemShare), isTrue,
            reason: '${host.name} 必须放行');
      }
      for (final host in const [
        AppHost.macos,
        AppHost.linux,
        AppHost.windows,
        AppHost.web,
      ]) {
        final caps = staticCapabilitiesFor(host);
        expect(caps.can(AppCapability.systemShare), isFalse,
            reason: '${host.name} 没有 UIActivityViewController/ACTION_SEND 等价物');
      }
    });

    test('★ 反向：Dart 侧两处出站都还在用这两条通道（没人把通道改名）', () {
      final note = _read('lib/src/features/notes/note_share_out.dart');
      expect(note, contains("kNoteShareOutChannel = 'synhub/share_text'"));
      expect(note, contains("invokeMethod<bool>('shareText'"));
      final files = _read('lib/src/features/files/file_link_share.dart');
      expect(files, contains("invokeMethod<bool>('shareFiles'"));
    });
  });

  group('DA321 iOS 繁体中文显示名（zh-Hant）', () {
    test('★ lproj 与 pbxproj 成对：文件存在 + 变体组 + knownRegions', () {
      final zhHant = _read('ios/Runner/zh-Hant.lproj/InfoPlist.strings');
      expect(zhHant, contains('CFBundleDisplayName = "星樞";'));
      expect(zhHant, contains('CFBundleName = "星樞";'));
      // 简繁不能混（简体的"星枢"不许出现在繁体文件里）
      expect(zhHant.contains('星枢'), isFalse);

      final proj = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(proj, contains('zh-Hant.lproj/InfoPlist.strings'));
      expect(proj, contains('"zh-Hant",'), reason: 'knownRegions 缺 zh-Hant ⇒ 不参与本地化');
      expect('AA95F0040000000000000004'.allMatches(proj).length, 2,
          reason: '文件引用 + 变体组子项，各一份');
    });

    test('★ 与安卓同一套名字：zh-Hans=星枢 / zh-Hant=星樞', () {
      final hans = _read('ios/Runner/zh-Hans.lproj/InfoPlist.strings');
      expect(hans, contains('星枢'));
      final androidTw =
          _read('android/app/src/main/res/values-zh-rTW/strings.xml');
      final androidHk =
          _read('android/app/src/main/res/values-zh-rHK/strings.xml');
      expect(androidTw, contains('星樞'));
      expect(androidHk, contains('星樞'));
      // iOS 的繁体与安卓的繁体必须是同一个字
      expect(zhHantOf(), contains('星樞'));
    });
  });
}

/// 只读一次，避免上面两个 test 各读一遍（也让失败信息更直观）。
String zhHantOf() => _read('ios/Runner/zh-Hant.lproj/InfoPlist.strings');
