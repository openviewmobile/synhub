// s288（r688）：iOS 的**主屏小组件**真的接上了 —— WidgetKit 扩展 ＋ `synhub/widget` 桥。
//
// 本用例只证"模拟器上能证的那部分"，逐条对应能力位翻转的四个前提：
//   ① `pushSnapshot` 回 true（= 快照真的写进 App Group 的 UserDefaults）；
//   ② 脏载荷回 false（不落脏数据、不假装成功）；
//   ③ `requestRefresh` 回 true（= `WidgetCenter.reloadAllTimelines()` 走通）；
//   ④ `synhubwidget://open?target=…` 真的被 App 收下，并且 `takePendingTarget`
//      能取走、**取走即清**（第二次必须 null）——这是"点小组件能进对页"的骨架。
//
// **验不到**（诚实分界，见 `docs/platform-ios.md` §27.4）：
//   * 把小组件拖到主屏 / 系统何时刷新时间线 —— `simctl` 没有"加小组件"的 verb，
//     无头模拟器点不了；
//   * 扩展进程里 `SynHubWidgetStore.load()` 的实际渲染 —— 同上。
//
// 跑法（后半段的 openurl 由宿主在用例等待期间发出，命令见 §27.3）：
//   flutter test integration_test/r688_ios_home_widget_test.dart \
//     -d 1FFF0EDA-3230-46F5-A011-6119E6040381 --dart-define=R688_WAIT_TARGET=1
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

const MethodChannel _widget = MethodChannel('synhub/widget');

/// 1 = 等宿主发 `synhubwidget://`（取点击落点用）；默认 0 = 不等。
const int _waitTarget = int.fromEnvironment('R688_WAIT_TARGET');

/// >0 = 落盘后**停住**这么久，好让宿主从外面读 App Group 里的快照（实测证据用）。
const int _holdSeconds = int.fromEnvironment('R688_HOLD_SECONDS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r688 主屏小组件：快照可落盘 · 可请求刷新 · 点击落点可取走', (tester) async {
    // ⓪ 能力层：iOS 上 homeScreenWidgets 必须 available（r688 的改动）
    final caps = staticCapabilitiesFor(AppHost.ios);
    expect(caps.can(AppCapability.homeScreenWidgets), isTrue,
        reason: 'WidgetKit 扩展 + WidgetBridge 已落地 ⇒ 能力层不许再拦');
    // ignore: avoid_print
    print('[r688] capability homeScreenWidgets='
        '${caps.statusOf(AppCapability.homeScreenWidgets).reason}');

    // ① 快照落盘
    const snapshot = '{"noteCount":7,"todoCount":3,"recentNoteTitle":"r688 探针",'
        '"shortcuts":[{"id":"notes","title":"笔记","symbol":"note.text"}],'
        '"updatedAt":1730000000}';
    final pushed =
        await _widget.invokeMethod<bool>('pushSnapshot', {'snapshot': snapshot});
    // ignore: avoid_print
    print('[r688] pushSnapshot -> $pushed');
    expect(pushed, isTrue, reason: 'false = App Group 写不进 / 通道没接');

    if (_holdSeconds > 0) {
      // ignore: avoid_print
      print('[r688] holding $_holdSeconds s（宿主此时读 App Group）');
      for (var i = 0; i < _holdSeconds * 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // ② 脏载荷必须如实拒绝
    final bad = await _widget
        .invokeMethod<bool>('pushSnapshot', {'snapshot': '{not json'});
    final empty = await _widget.invokeMethod<bool>('pushSnapshot', {'snapshot': ''});
    // ignore: avoid_print
    print('[r688] dirty=$bad empty=$empty');
    expect(bad, isFalse, reason: '坏 JSON 不许落盘');
    expect(empty, isFalse, reason: '空载荷不许落盘');

    // ③ 请求系统重画
    final refreshed = await _widget.invokeMethod<bool>('requestRefresh');
    // ignore: avoid_print
    print('[r688] requestRefresh -> $refreshed');
    expect(refreshed, isTrue);

    // ③-b 取走即清：此刻还没有点击 ⇒ null
    final none = await _widget.invokeMethod<String>('takePendingTarget');
    expect(none, isNull, reason: '没人点过就不许有落点');

    // ④ 小组件点击的**解析与落点语义**（DEBUG 钩子，见 §27.4 的"为什么不是 openurl"）
    //
    // `xcrun simctl openurl` 在无头模拟器上会先弹系统确认框（没人能点）⇒
    // 原生投递这一段验不到；这里验的是"URL 进来之后"的全部行为。
    final simulated = await _widget.invokeMethod<bool>(
      'simulateWidgetURL',
      {'url': 'synhubwidget://open?target=notes'},
    );
    final taken = await _widget.invokeMethod<String>('takePendingTarget');
    // ignore: avoid_print
    print('[r688] simulateWidgetURL -> $simulated takePendingTarget -> $taken');
    expect(simulated, isTrue, reason: '专用 scheme 必须被认下');
    expect(taken, 'notes');
    final cleared = await _widget.invokeMethod<String>('takePendingTarget');
    expect(cleared, isNull, reason: '落点必须取走即清');
    // 不是我们的 scheme 必须不认（否则会吃掉聊天深链）
    final other = await _widget.invokeMethod<bool>(
      'simulateWidgetURL',
      {'url': 'synochat://?address=nas.r688.test&account=tester'},
    );
    expect(other, isFalse, reason: 'synochat 不归小组件桥管');

    // ⑤ 等宿主的 `synhubwidget://open?target=notes`（环境不可得时跳过）
    if (_waitTarget == 1) {
      // ignore: avoid_print
      print('[r688] WAITING_TARGET 至多 40 s');
      String? target;
      for (var i = 0; i < 40 && target == null; i++) {
        await tester.pump(const Duration(seconds: 1));
        target = await _widget.invokeMethod<String>('takePendingTarget');
      }
      // ignore: avoid_print
      print('[r688] pendingTarget -> $target');
      expect(target, 'notes', reason: '专用 scheme 没被 SceneDelegate 收到');

      // 取走即清
      final again = await _widget.invokeMethod<String>('takePendingTarget');
      expect(again, isNull, reason: '落点必须取走即清');
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
