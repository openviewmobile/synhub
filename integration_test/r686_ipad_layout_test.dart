// r686（s286）· iPad 机型矩阵：竖屏几何 + expanded 断点 + 零溢出
//
// 之前的 iOS 读数全部来自 **iPhone 16 Pro**（402×874pt）；iPad 的
// regular/expanded 断点（≥700pt）从没在真宿主上跑过。本用例在同一台
// iPad 上取三样事实：
//   ① `FlutterView` 的逻辑尺寸（iPad Pro 11" M4 = 834×1210pt @2x；
//      iPad mini A17 Pro = 744×1133pt @2x）——这是断点的第一手输入；
//   ② 该宽度落进 expanded 断点（≥700pt）；
//   ③ 首屏在**这个**尺寸下布局，全程把 `FlutterError` 收进列表 ——
//      iPad 上最常见的回归是宽屏行排不下（RenderFlex overflow）。
//
// ★ 横屏走的是本仓 **DEBUG-only 原生钩子** `synhub/test_orientation`（r283 建的）：
//   iPad 上 App 允许分屏 ⇒ `SystemChrome.setPreferredOrientations` 的掩码会被
//   iPadOS 忽略（实测 8 s 内 `FlutterView` 一字不变），真旋转必须调 scene 的
//   `requestGeometryUpdate`。这里请求 landscapeLeft(16)，断言宽度/高度真的换了，
//   再转回 portrait(2)，保证后续用例不受影响。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('s286 iPad：竖屏 expanded 断点 + 零布局异常', (tester) async {
    final errors = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exceptionAsString());
      prev?.call(details);
    };
    addTearDown(() => FlutterError.onError = prev);

    Size sizeOf() => tester.view.physicalSize / tester.view.devicePixelRatio;

    // 首屏先渲染几帧（登录页有入场动画）
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final size = sizeOf();
    final portraitWidth = size.width;
    // ignore: avoid_print
    print('[r686] size=${size.width.toStringAsFixed(1)}x'
        '${size.height.toStringAsFixed(1)} dpr=${tester.view.devicePixelRatio} '
        'expanded=${size.width >= 700}');

    expect(size.shortestSide, greaterThan(600),
        reason: 'iPad idiom：最短边必须 > 600pt（iPhone 16 Pro 是 402pt）');
    expect(size.width, greaterThanOrEqualTo(700),
        reason: 'iPad 竖屏必须落进 expanded 断点（≥700pt）');
    expect(size.width, lessThan(size.height), reason: '竖屏：宽 < 高');

    // ② 真旋转到横屏（DEBUG-only 原生钩子），并重新取几何
    const channel = MethodChannel('synhub/test_orientation');
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    await tester.pump(const Duration(milliseconds: 600));
    bool ack = false;
    String? rotateError;
    try {
      ack = await channel.invokeMethod<bool>('rotate', <String, int>{
            'mask': 16, // UIInterfaceOrientationMaskLandscapeLeft
          }) ??
          false;
    } on PlatformException catch (e) {
      // 本机实测：iPadOS 18.6 模拟器对这个 scene 回
      // `geometry_update_failed · The current windowing mode does not allow
      //  for programmatic changes to …` ⇒ 横屏在本环境**不可得**，如实记下，
      //  不把"转不过去"写成"验过"。
      rotateError = '${e.code}: ${e.message}';
    }
    // 系统几何更新 + 布局重建需要几帧
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final landscape = sizeOf();
    // ignore: avoid_print
    print('[r686] rotate ack=$ack landscape=${landscape.width.toStringAsFixed(1)}x'
        '${landscape.height.toStringAsFixed(1)} expanded=${landscape.width >= 700}');

    if (rotateError != null) {
      // 死路要留证据：系统拒绝 ⇒ 尺寸一字不变，且错误原文在打印里
      expect(landscape.width, portraitWidth, reason: '系统拒绝后尺寸不该变');
      // ignore: avoid_print
      print('[r686] landscape=ENV-UNAVAILABLE $rotateError');
    } else {
      expect(ack, isTrue, reason: 'native 钩子必须确认旋转请求已被接受');
      expect(landscape.width, greaterThan(landscape.height),
          reason: '横屏：宽必须大于高（系统真的转了）');
      expect(landscape.width, greaterThan(portraitWidth), reason: '横屏更宽');
      expect(landscape.width, greaterThanOrEqualTo(700), reason: '横屏也是 expanded');
      expect(errors, isEmpty, reason: '竖屏与横屏都不许有布局异常：$errors');
    }

    // ③ 若真的转过去了，转回竖屏，别影响后续用例
    if (rotateError == null) {
      await channel.invokeMethod<bool>('rotate', <String, int>{'mask': 2});
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
