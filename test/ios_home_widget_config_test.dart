// r688：iOS 主屏小组件（`DA322`）的静态守卫。
//
// 为什么这类"接线型"改动必须有静态守卫：WidgetKit 的每一环**漏了都不报错**：
//   * `PlugIns/SynHubWidget.appex` 没被 Embed ⇒ 包里没扩展，主屏找不到小组件；
//   * App Group 在 App 侧与扩展侧**不一致** ⇒ App 写得进、扩展读不到（两个都"成功"）；
//   * 扩展的 `CFBundleVersion` 展开成空 ⇒ `simctl install` 才报
//     "Invalid placeholder attributes"（编译期完全正常）；
//   * `synhubwidget` 没进 `Info.plist` 的 URLTypes ⇒ 点击落点永远收不到；
//   * 扩展 Info.plist 的 `NSExtensionPointIdentifier` 写错 ⇒ 系统不认它是小组件。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('DA322 iOS 主屏小组件（WidgetKit）', () {
    test('★ 扩展源码：三档家族 + App Group 键 + 专用的点击 scheme', () {
      final swift = _read('ios/Widget/SynHubHomeWidget.swift');
      expect(swift, contains('import WidgetKit'));
      expect(swift, contains('@main'));
      expect(swift, contains('StaticConfiguration(kind:'));
      expect(swift, contains('.supportedFamilies([.systemSmall, .systemMedium, .systemLarge])'));
      // App Group 名与键必须与 App 侧逐字一致（下面还有一条交叉断言）
      expect(swift, contains('static let appGroup = "group.com.openviewai.synhub.ios"'));
      expect(swift, contains('static let snapshotKey = "snapshot"'));
      // 点击落点用**专用** scheme，不蹭 synochat
      expect(swift, contains('synhubwidget://open?target='));
      // 代码里不许出现聊天深链的**字面量**（注释里提到它是在讲"为什么不蹭"）
      expect(swift.contains('"synochat'), isFalse,
          reason: '扩展里不许出现聊天深链（语义污染）');
    });

    test('★ App 侧桥：通道名/三个方法 + App Group 一致性 + 专用 scheme 解析', () {
      final bridge = _read('ios/Runner/WidgetBridge.swift');
      expect(bridge, contains('static let channelName = "synhub/widget"'));
      for (final m in const ['pushSnapshot', 'requestRefresh', 'takePendingTarget']) {
        expect(bridge, contains('"$m"'), reason: '缺方法 $m ⇒ Dart 侧拿到 MissingPlugin');
      }
      expect(bridge, contains('WidgetCenter.shared.reloadAllTimelines()'));
      expect(bridge, contains('static let appGroup = "group.com.openviewai.synhub.ios"'));
      expect(bridge, contains('static let widgetScheme = "synhubwidget"'));

      // 交叉：扩展与桥的 App Group 字面量必须同一串
      final widget = _read('ios/Widget/SynHubHomeWidget.swift');
      expect(
        widget.contains('group.com.openviewai.synhub.ios'),
        isTrue,
      );
      for (final ent in const [
        'ios/Runner/Runner.entitlements',
        'ios/Widget/Widget.entitlements',
      ]) {
        expect(_read(ent), contains('<string>group.com.openviewai.synhub.ios</string>'),
            reason: '$ent 少了同一个 group ⇒ 共享目录不存在');
      }
    });

    test('★ pbxproj：扩展 target / Embed 相位 / 编译开关 / INFO 路径 / 版本号来源', () {
      final proj = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(proj, contains('name = SynHubWidget;'));
      expect(proj, contains('com.apple.product-type.app-extension'));
      expect(proj, contains('SynHubWidget.appex in Embed App Extensions'));
      expect(proj, contains('dstSubfolderSpec = 13'));
      expect(proj, contains('INFOPLIST_FILE = Widget/WidgetInfo.plist;'));
      expect(proj, contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'));
      expect(proj, contains('CODE_SIGN_ENTITLEMENTS = Widget/Widget.entitlements;'));
      // ★ 版本号必须来自 Flutter 的 Generated.xcconfig（否则两个键被整条删掉）
      expect(proj, contains('baseConfigurationReference = AB00F0000000000000000006'),
          reason: 'Widget.xcconfig 未接 ⇒ CFBundleVersion 为空 ⇒ 装不上');
      expect(_read('ios/Widget/Widget.xcconfig'),
          contains('#include "../Flutter/Generated.xcconfig"'));
      // 扩展 Info.plist 的扩展点
      expect(_read('ios/Widget/WidgetInfo.plist'),
          contains('com.apple.widgetkit-extension'));
      // 点击 scheme 已登记
      expect(_read('ios/Runner/Info.plist'), contains('<string>synhubwidget</string>'));
    });

    test('★ scene 路由：自家子类接管（Flutter 转发在 warm 路上不可靠）', () {
      final scene = _read('ios/Runner/SynHubSceneDelegate.swift');
      expect(scene, contains('final class SynHubSceneDelegate: FlutterSceneDelegate'));
      expect(scene, contains('openURLContexts'));
      expect(scene, contains('super.scene(scene, openURLContexts: rest)'),
          reason: '别的 scheme 必须原样交回 super');
      // Info.plist 指向自家子类
      expect(_read('ios/Runner/Info.plist'),
          contains(r'$(PRODUCT_MODULE_NAME).SynHubSceneDelegate'));
      // AppDelegate 注册了桥
      expect(_read('ios/Runner/AppDelegate.swift'),
          contains('forPlugin: "SynHubWidget"'));
    });

    test('★ 能力位：iOS 静态放行 · Android 走桥探测 · 桌面/web 仍拦住', () {
      // iOS：桥随包编译进去 ⇒ 静态 available（与 r687 的 systemShare 同口径）
      expect(staticCapabilitiesFor(AppHost.ios).can(AppCapability.homeScreenWidgets),
          isTrue, reason: 'iOS 的 WidgetKit 扩展随包编译');
      // Android：6 个 AppWidgetProvider 在，但能力位是**桥探测**（不是静态 ok）
      final android =
          staticCapabilitiesFor(AppHost.android).statusOf(AppCapability.homeScreenWidgets);
      expect(android.reason, isNot(CapabilityReason.notSupportedOnHost),
          reason: 'Android 有 AppWidgetProvider，不许报"平台上没有"');
      for (final host in const [
        AppHost.macos,
        AppHost.linux,
        AppHost.windows,
        AppHost.web,
      ]) {
        expect(staticCapabilitiesFor(host).can(AppCapability.homeScreenWidgets),
            isFalse, reason: '${host.name} 没有主屏小组件');
      }
    });
  });
}
