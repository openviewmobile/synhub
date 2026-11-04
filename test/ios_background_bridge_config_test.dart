// r682：iOS **后台执行 + 本地通知**桥的静态接线守卫。
//
// 守三件事（都是"漏了不报错、只在运行期怪"的）：
//   ① `Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` 与 Swift 里的常量**逐字一致**
//      （不一致 ⇒ `submit` 抛 `NSInternalInconsistencyException`）；
//   ② `registerBackgroundTasks()` 在 `didFinishLaunching` **返回之前**被调用
//      （晚于启动完成再注册 ⇒ 系统直接抛异常）；
//   ③ pbxproj 有 Sources 相位、AppDelegate 有 `registrar` + `register(with:)` 成对。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/platform/app_platform.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('DA316 iOS 后台执行/通知桥', () {
    const swift = 'ios/Runner/BackgroundBridge.swift';
    const taskId = 'com.openviewai.synhub.refresh';

    test('Swift 实现：强引用单例 + 通道名 + 三个关键系统 API', () {
      expect(File(swift).existsSync(), isTrue);
      final src = _read(swift);
      expect(src, contains('static let shared = BackgroundBridge()'));
      expect(src, contains('"synhub/background"'));
      // 后台执行窗口 / 后台刷新 / 通知中心各一处（少了哪条都说明这段没接）
      expect(src, contains('beginBackgroundTask(withName:'));
      expect(src, contains('BGTaskScheduler.shared.submit'));
      expect(src, contains('requestAuthorization(options:'));
      // 任务标识常量
      expect(src, contains('let kSynhubRefreshTaskId = "$taskId"'));
    });

    test('Info.plist：任务标识逐字一致 + UIBackgroundModes 含 fetch', () {
      final plist = _read('ios/Runner/Info.plist');
      expect(plist, contains('<key>BGTaskSchedulerPermittedIdentifiers</key>'));
      expect(plist, contains('<string>$taskId</string>'));
      expect(plist, contains('<key>UIBackgroundModes</key>'));
      expect(plist, contains('<string>fetch</string>'));
      // ★ 只允许一个标识（多了说明抄错/残留）
      expect(taskId.allMatches(plist).length, 1);
    });

    test('AppDelegate：注册在 didFinishLaunching 返回之前（Apple 硬要求）', () {
      final app = _read('ios/Runner/AppDelegate.swift');
      final launch = app.indexOf('didFinishLaunchingWithOptions');
      final reg = app.indexOf('BackgroundBridge.registerBackgroundTasks()');
      final superCall = app.indexOf(
        'return super.application(application, didFinishLaunchingWithOptions:',
      );
      expect(reg, greaterThan(launch));
      expect(reg, lessThan(superCall), reason: '晚于 return 就是运行期崩');
      expect(app, contains('forPlugin: "SynHubBackground"'));
      expect(app, contains('BackgroundBridge.register(with: registrar)'));
    });

    test('pbxproj：build file + file ref + group + Sources 相位', () {
      final proj = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(proj, contains('AA97B0010000000000000001'));
      expect(proj, contains('AA97F0010000000000000001'));
      expect(proj, contains('BackgroundBridge.swift in Sources'));
      expect('BackgroundBridge'.allMatches(proj).length, greaterThanOrEqualTo(4));
    });

    test('DA319 ★ r685：刷新 handler 被提出成可调方法，并把事实落盘 + 报 Dart', () {
      final sw = _read('ios/Runner/BackgroundBridge.swift');
      // 注册闭包只允许留一行调用（逻辑留在闭包里，模拟器上就验不了）
      expect(sw, contains('BackgroundBridge.shared.handleRefreshLaunch(task.identifier)'));
      expect(sw, contains('@objc func handleRefreshLaunch(_ taskId: String)'));
      expect(sw, contains('channel?.invokeMethod("onBackgroundRefresh"'));
      for (final k in <String>[
        'kRefreshFiredKey',
        'kRefreshLastAtKey',
        'kRefreshLastTaskKey',
      ]) {
        expect(sw, contains(k));
      }
      expect(sw, contains('case "refreshStats"'));
      // ★ Swift 类必须对 ObjC 可见，否则 LLDB 调不到（r685 踩过：静默 nil）
      expect(sw, contains('@objc(BackgroundBridge)'));
      expect(sw, contains('@objc static let shared'));

      final dart = _read('lib/src/native/background_service.dart');
      expect(dart, contains("'refreshStats'"));
      expect(dart, contains('setRefreshHandler'));
      expect(dart, contains("call.method == 'onBackgroundRefresh'"));

      final sh = _read('tool/r685_trigger_bg_refresh.sh');
      expect(sh, contains('handleRefreshLaunch'));
      expect(sh, contains('NSClassFromString'));
    });

    test('能力层：iOS 的 backgroundExecution / localNotifications 都是 available', () {
      final caps = staticCapabilitiesFor(AppHost.ios);
      expect(caps.can(AppCapability.backgroundExecution), isTrue);
      expect(caps.can(AppCapability.localNotifications), isTrue);
    });

    test('★ 反向：桌面仍把 backgroundExecution 判成"结构上没有"', () {
      final caps = staticCapabilitiesFor(AppHost.macos);
      expect(caps.can(AppCapability.backgroundExecution), isFalse);
      expect(
        caps.statusOf(AppCapability.backgroundExecution).reason,
        CapabilityReason.notSupportedOnHost,
      );
    });
  });
}
