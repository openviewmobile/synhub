// s289（r689）：iPhone **横屏**（宽屏断点）第一次在 iOS 上真取几何 + 走查。
//
// 之前的 iOS 读数全部来自**竖屏**：iPhone 16 Pro = 402×874 pt；iPad 那条
// （r686）在 iPadOS 18.6 模拟器上被 `geometry_update_failed` 挡下
// （"current windowing mode does not allow programmatic changes"）。
// **iPhone 没有分屏**，同一套 `requestGeometryUpdate` 钩子在 iPhone 上是能成的
// ——本轮就在这里把它验掉。
//
// 三件事（逐条断言）：
//   ① `rotate(mask: 16 /* landscapeLeft */)` 回 `true`，且 `FlutterView` 的
//      逻辑尺寸**真的**变成 ~874×402（宽 > 高）；
//   ② 横屏下布局**零 `FlutterError`**（宽屏最常见的回归是 RenderFlex overflow）；
//   ③ 走查登录页的几个可交互面（语言/服务器输入/登录按钮）在横屏下**都在树上**
//      且可点（不要求登录，本用例零 NAS 接触 ⇒ 只走"未登录"这一段）。
//
// **证不到**：登录之后的模块页（文件站/笔记/相册…）横屏布局 —— 那需要会话
// （本轮零 NAS 接触，见 §5.1）。这一条留在台账里当"环境不可得"，不写成"验过"。
//
// 跑法（截图由宿主在 `R689_LANDSCAPE_HOLD` 期间抓）：
//   flutter test integration_test/r689c_iphone_landscape_test.dart \
//     -d 1FFF0EDA-3230-46F5-A011-6119E6040381 --dart-define=R689_LANDSCAPE_HOLD=20
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/servers/server_setup_page.dart';
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';

/// >0 = 横屏摆好后停住这么久，好让宿主 `simctl io … screenshot` 抓像素。
const int _holdSeconds = int.fromEnvironment('R689_LANDSCAPE_HOLD');

/// 与 `r674`/`r132` 同款开机：把真 App 树 pump 起来（含 libmpv 与几个初始化），
/// 否则 `LoginPage` 永远不会出现。
Future<void> _boot(WidgetTester tester) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android) {
    try {
      MediaKit.ensureInitialized();
    } catch (_) {
      // 没有 Mpv.framework 的宿主上视频退回主引擎，不影响本用例
    }
  }
  final profile = DeviceProfile.detect();
  await NoteStationApi.initNoteDeviceName();
  await registerNoteBackgroundSync();
  final audioHandler = await createBackgroundAudioHandler();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceProfileProvider.overrideWithValue(profile),
        biometricAuthenticatorProvider.overrideWithValue(
          LocalAuthBiometricAuthenticator(),
        ),
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const SynologyChatApp(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 2500));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r689 ⑥ iPhone 横屏：874×402 · 零溢出 · 登录面都可交互', (tester) async {
    final errors = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exceptionAsString());
      prev?.call(details);
    };
    addTearDown(() => FlutterError.onError = prev);

    Size sizeOf() => tester.view.physicalSize / tester.view.devicePixelRatio;

    // ★ 先**把 App 真的跑起来**：`flutter test integration_test/…` 的 entrypoint
    //   是本文件，**不会**替你执行 `lib/main.dart` ⇒ 不 pumpWidget 的话树上只有
    //   "Test starting..." 占位页（本节第一版就栽在这，取到的 editableFields=0 是
    //   占位页的读数，不是登录页）。这里照 `r674` 的 `_boot` 同款开机。
    await _boot(tester);
    for (var i = 0; i < 200 && find.byType(ServerSetupPage).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ServerSetupPage).evaluate(), isNotEmpty,
        reason: 'App 没起来（首屏应是「连接到你的 NAS」）');
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final portrait = sizeOf();
    // ignore: avoid_print
    print('[r689c] portrait=${portrait.width.toStringAsFixed(1)}x'
        '${portrait.height.toStringAsFixed(1)} dpr=${tester.view.devicePixelRatio}');
    expect(portrait.width, lessThan(portrait.height), reason: '起点必须是竖屏');

    // ① 真旋转（DEBUG-only 原生钩子，与 r283/r686 同一条）
    const channel = MethodChannel('synhub/test_orientation');
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    await tester.pump(const Duration(milliseconds: 600));
    final ack = await channel.invokeMethod<bool>('rotate', <String, int>{
          'mask': 16, // UIInterfaceOrientationMaskLandscapeLeft
        }) ??
        false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final land = sizeOf();
    // ignore: avoid_print
    print('[r689c] rotate ack=$ack landscape=${land.width.toStringAsFixed(1)}x'
        '${land.height.toStringAsFixed(1)}');

    expect(ack, isTrue, reason: 'iPhone 上 requestGeometryUpdate 必须成功（iPad 那条才是环境限制）');
    expect(land.width, greaterThan(land.height), reason: '旋转后宽必须 > 高');
    // iPhone 16 Pro 横屏逻辑尺寸 = 874×402（物理 2622×1206 @3x）
    expect(land.width, greaterThanOrEqualTo(780));
    expect(land.height, lessThanOrEqualTo(430));

    // ② 横屏下零布局异常（含 overflow）
    expect(errors, isEmpty, reason: '横屏出现 FlutterError：${errors.join(' | ')}');

    // ③ 首屏（未登录时就是「连接到你的 NAS」`ServerSetupPage`）在横屏下
    //    **真的可交互**。不押文案语言（同一 App 会按系统语言出简/繁/英）⇒ 押控件：
    //    地址输入框 + 提交用的能量核都必须命中 hit-test 且落在视口内
    //    （横屏最容易把底部提交按钮顶出屏幕 —— 这正是要验的回归）。
    // 诊断：把树上所有 Text 打出来（排查"页面到底是哪一个"用）
    final texts = <String>[];
    for (final e in find.byType(Text).evaluate()) {
      final t = e.widget as Text;
      final v = t.data ?? t.textSpan?.toPlainText();
      if (v != null && v.trim().isNotEmpty) texts.add(v.trim());
    }
    // ignore: avoid_print
    print('[r689c] texts=${texts.take(12).toList()} total=${texts.length}');

    final fields = find.byType(EditableText);
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    // ignore: avoid_print
    print('[r689c] editableFields=${fields.evaluate().length} '
        'hitTestable=${fields.hitTestable().evaluate().length} '
        'orb=${find.byType(EnergyOrb).evaluate().length} view=${view.width}x${view.height}');
    expect(fields.evaluate().length, greaterThanOrEqualTo(1),
        reason: '横屏下首屏一个输入框都没有 = 页面没渲染出来');

    // ★ 402pt 高的横屏装不下整页 ⇒ 首屏**必然**要滚。这里验的是"滚得到"：
    //   一路往上拖，直到输入框命中 hit-test；拖 N 次还够不着才算缺陷
    //   （横屏最常见的回归不是"不在首屏"，而是**根本够不着**：被
    //    `Expanded`+`Center` 死锁成不可滚）。
    expect(find.byType(Scrollable).evaluate(), isNotEmpty,
        reason: '首屏没有 Scrollable ⇒ 矮屏下内容撑出去就只能靠裁');
    var drags = 0;
    while (fields.hitTestable().evaluate().isEmpty && drags < 6) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 200));
      drags++;
    }
    // ignore: avoid_print
    print('[r689c] drags=$drags fieldHit=${fields.hitTestable().evaluate().length}');
    expect(fields.hitTestable().evaluate(), isNotEmpty,
        reason: '拖了 $drags 次仍够不着地址输入框 ⇒ 横屏下不可达');

    // 命中之后矩形必须真的落在视口内（不是"半截在屏幕外"）
    final rect = tester.getRect(fields.hitTestable().first);
    expect(rect.left, greaterThanOrEqualTo(-0.5));
    expect(rect.right, lessThanOrEqualTo(view.width + 0.5));
    expect(rect.top, greaterThanOrEqualTo(-0.5));
    expect(rect.bottom, lessThanOrEqualTo(view.height + 0.5),
        reason: '输入框底边 ${rect.bottom} 超出视口 ${view.height}');

    // 提交用的能量核：滚到顶之后必须可见可点（主行动不能被矮屏挤没）
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(EnergyOrb).hitTestable().evaluate(), isNotEmpty,
        reason: '提交按钮（能量核）在横屏下不可见/不可点');

    if (_holdSeconds > 0) {
      // ignore: avoid_print
      print('[r689c] holding $_holdSeconds s for pixel evidence');
      for (var i = 0; i < _holdSeconds * 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // 转回竖屏，别把后续用例留在横屏
    await channel.invokeMethod<bool>('rotate', <String, int>{'mask': 2});
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final back = sizeOf();
    // ignore: avoid_print
    print('[r689c] restored=${back.width.toStringAsFixed(1)}x'
        '${back.height.toStringAsFixed(1)}');
    expect(back.width, lessThan(back.height), reason: '必须能转回竖屏');
  });
}
