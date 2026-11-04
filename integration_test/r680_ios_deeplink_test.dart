// r680 · iOS 模拟器「深链真的能打进来」验收（`synochat://` 四条 scheme）。
//
// 这条用例证的是**整条链路**，不是 Dart 解析器（那部分早有单测）：
//   `UIApplication.shared.open(synochat://…)`（App 自己发起，见下）
//   → SpringBoard 按 `Info.plist` 的 `CFBundleURLTypes` 解析出本 App
//   → `FlutterSceneDelegate` 把 `scene(_:openURLContexts:)` 转给 `DeepLinkBridge.swift`
//   → `synhub/deep_link` 通道 → Dart `takePending()`
//
// ## 为什么不用 `xcrun simctl openurl` 打进来（r680 实测）
//
// iOS 18 的模拟器上，从"外部"打开自定义 scheme 会先弹**系统确认框**
// （「Open in “SynHub”?」，像素见 `docs/evidence-r680-ios/01_…png`）：
// 没人点「Open」，URL 就停在 SpringBoard，**scene delegate 一次都不会被调用**；
// 而本机的 Xcode 里**没有 `Simulator.app`**（无头模拟器）⇒ 自动化点不了那个按钮。
//
// 折中办法：App 里加一条**仅模拟器**的钩子 `synhub/test_deeplink`（`open`），
// 它调的是**真的** `UIApplication.shared.open(_:)` —— 于是"scheme 解析 / scene 回调 /
// 桥 / 通道"全都是真实系统链路，唯一被替换的是**"谁点了这一下"**。
// 那一下本身由 `xcrun simctl openurl` 的**弹框像素**证明（系统确实把 scheme
// 解析到了 SynHub），见 `docs/platform-ios.md` §18.2。
//
// 判据（缺一条都不算通过）：
//   ① iOS 能力层放行 `deepLink`；
//   ② `UIApplication.shared.open` 返回 true（系统接受了这个 scheme）；
//   ③ Dart 侧 `takePending()` 真的拿到 `address` / `account`，且 `secure` 跟 scheme 走；
//   ④ 同一个载荷**只能取到一次**（取走即清，与 Android 同语义）。
//
// 跑法：
//   tool/r132_ios_shot_poller.sh com.openviewai.synhub.ios /tmp/r680_shots &
//   flutter test integration_test/r680_ios_deeplink_test.dart -d <sim-id>
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/features/chat/chat_deep_link.dart';

/// 宿主截图握手的落点（与 r132/r674/r679 同一套协议：写 req → 等 ack）
const String _shotDir = String.fromEnvironment(
  'SHOT_DIR',
  defaultValue: '/tmp/r680_shots',
);

/// 仅模拟器存在的测试钩子通道（`ios/Runner/DeepLinkBridge.swift`，
/// `#if targetEnvironment(simulator)` 才有；真机产物里不存在）
const String _hookChannel = 'synhub/test_deeplink';

Future<void> _mark(WidgetTester tester, String name) async {
  final dir = Directory(_shotDir);
  if (!dir.existsSync()) {
    // ignore: avoid_print
    print('[r680] (no shot poller) MARK $name');
    return;
  }
  final req = File('${dir.path}/req.txt');
  final ack = File('${dir.path}/ack.txt');
  req.writeAsStringSync(name);
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ack.existsSync() && ack.readAsStringSync().trim() == name) {
      ack.deleteSync();
      // ignore: avoid_print
      print('[r680] SHOT $name');
      return;
    }
  }
  // ignore: avoid_print
  print('[r680] SHOT TIMEOUT $name');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('s280 iOS 深链：system open → scene → channel → Dart', (
    tester,
  ) async {
    // ① 能力层在 iOS 上放行（否则 Dart 侧连通道都不会碰）
    expect(
      staticCapabilitiesFor(AppHost.ios).mayTry(AppCapability.deepLink),
      isTrue,
      reason: 'iOS 能力表未放行 deepLink',
    );

    final source = MethodChannelChatDeepLinkSource();
    addTearDown(source.dispose);

    /// 走真实系统链路打开一个 URL，并等 Dart 侧收到载荷。
    ///
    /// ★ 为什么要等 `incoming` 而不是轮询 `takePending()`（r680 实测踩到）：
    /// 桥存下载荷后会 `invokeMethod("onDeepLink")`；`MethodChannelChatDeepLinkSource`
    /// 收到这个提醒**自己**就把载荷取走了（转进 `incoming` 流）⇒ 外面再 poll
    /// `takePending()` 永远拿到 null。产品里 `ChatDeepLinkHost` 也是订阅这条流，
    /// 所以这里必须跟产品同一条路。
    Future<ChatDeepLink?> open(String url) async {
      final next = source.incoming.first.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw StateError('20 秒内没收到 $url 的回调'),
      );
      final accepted = await const MethodChannel(
        _hookChannel,
      ).invokeMethod<bool>('open', {'url': url});
      // ② 系统接受了这个 scheme（`Info.plist` 没写对时这里就是 false / 抛异常）
      expect(accepted, isTrue, reason: '系统未接受 $url');
      return next;
    }

    // 干净起点：还没人发过链接
    expect(await source.takePending(), isNull, reason: '起点就不干净');

    var link = await open(
      'synochat://?address=nas.r680.test&account=probe',
    );
    expect(link, isNotNull, reason: '30 秒内没收到系统回调过来的深链');
    // ignore: avoid_print
    print('[r680] GOT $link');
    expect(link!.scheme, 'synochat');
    expect(link.address, 'nas.r680.test');
    expect(link.account, 'probe');
    expect(link.secure, isFalse);

    // ④ 取走即清（载荷已被 incoming 那条路取走，再取必须是空）
    expect(await source.takePending(), isNull, reason: '同一载荷被消费了两次');

    // ③ secure 的 scheme 也必须对（`synochats://` → https）
    link = await open(
      'synochats://?address=nas.r680.test&account=probe',
    );
    expect(link, isNotNull);
    expect(link!.scheme, 'synochats');
    expect(link.secure, isTrue);

    // 少参数也不能崩（官方 `fillInData` 拿到 null 就置空）
    link = await open('synochat://');
    expect(link, isNotNull);
    expect(link!.address, isEmpty);
    expect(link.account, isEmpty);

    await _mark(tester, 's280_deeplink_received');
  });
}
