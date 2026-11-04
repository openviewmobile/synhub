// r680 · iOS 的两个「配置型交付」必须**成对**落地的守卫。
//
// 为什么需要它：这两件事的失败方式都是**静默**的 ——
//   * 只写 `DeepLinkBridge.swift` 不给 `Info.plist` 声明 `CFBundleURLTypes`
//     ⇒ 系统根本不会投递 URL，桥永远收不到东西（代码看着完全正常）；
//   * 只声明 scheme 不写桥 / 桥没进 `Sources` ⇒ App 被拉起但没人接收；
//   * `zh-Hans.lproj/InfoPlist.strings` 写好了但没进 Xcode 的 **variant group**
//     ⇒ 编译产物里没有这个 lproj，图标下永远显示英文名。
// 这三条在模拟器上都能用 `simctl openurl` / 主屏像素抓到，但**没人会每轮都抓**
// ⇒ 这里用纯文本断言把"成对"这件事钉住（改配置不跑它就等于没改）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '$path 不存在');
  return f.readAsStringSync();
}

void main() {
  group('DA313 · iOS 聊天深链（scheme 声明 ↔ Swift 桥 ↔ pbxproj Sources）', () {
    test('Info.plist 声明了官方四条 scheme', () {
      final plist = _read('ios/Runner/Info.plist');
      expect(plist.contains('<key>CFBundleURLTypes</key>'), isTrue);
      for (final scheme in const [
        'synochat',
        'synochats',
        'synochatGuest',
        'synochatsGuest',
      ]) {
        expect(
          plist.contains('<string>$scheme</string>'),
          isTrue,
          reason: 'Info.plist 缺 scheme：$scheme',
        );
      }
      // 反向：官方 OAuth 回跳那条**不许**声明（本 App 没有 OIDC 登录）
      expect(
        plist.contains('<string>synology-chat</string>'),
        isFalse,
        reason: 'synology-chat 是官方 AppAuth 的 OAuth 回跳，声明了只会误导',
      );
    });

    test('Swift 桥认同样四条 scheme，并接住 scene 的两条入口', () {
      final swift = _read('ios/Runner/DeepLinkBridge.swift');
      expect(swift.contains('synhub/deep_link'), isTrue);
      for (final scheme in const [
        'synochat',
        'synochats',
        'synochatGuest',
        'synochatsGuest',
      ]) {
        expect(swift.contains('"$scheme"'), isTrue, reason: scheme);
      }
      // UIScene 架构下这两条缺一不可：冷启动走 willConnectTo，前台走 openURLContexts
      expect(swift.contains('willConnectTo'), isTrue);
      expect(swift.contains('openURLContexts'), isTrue);
      expect(swift.contains('addSceneDelegate'), isTrue);
    });

    test('桥在 pbxproj 里真的进了 Runner 的 Sources（漏了就静默不编译）', () {
      final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(pbx.contains('DeepLinkBridge.swift in Sources'), isTrue);
      expect(pbx.contains('AA94B0010000000000000001'), isTrue);
      // AppDelegate 必须注册它（注册 ≠ 会调用的老账，r676 的 DA306 同源）
      final appDelegate = _read('ios/Runner/AppDelegate.swift');
      expect(appDelegate.contains('DeepLinkBridge.register'), isTrue);
    });
  });

  group('DA314 · iOS 简体中文显示名「星枢」', () {
    test('zh-Hans 与 Base 两份 InfoPlist.strings 都存在且值正确', () {
      final zh = _read('ios/Runner/zh-Hans.lproj/InfoPlist.strings');
      expect(zh.contains('CFBundleDisplayName = "星枢"'), isTrue);
      final base = _read('ios/Runner/Base.lproj/InfoPlist.strings');
      expect(base.contains('CFBundleDisplayName = "SynHub"'), isTrue);
    });

    test('两份都进了 variant group ＋ knownRegions（否则产物里没有 lproj）', () {
      final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(pbx.contains('isa = PBXVariantGroup'), isTrue);
      expect(pbx.contains('InfoPlist.strings in Resources'), isTrue);
      expect(pbx.contains('name = "zh-Hans"'), isTrue);
      expect(pbx.contains('"zh-Hans",'), isTrue, reason: 'knownRegions 缺 zh-Hans');
      // 与 macOS 同口径（那边早已有这两份）
      expect(
        File('macos/Runner/zh-Hans.lproj/InfoPlist.strings').existsSync(),
        isTrue,
      );
    });
  });
}
