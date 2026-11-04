// ★★★ r693（`DA332` / `DA333` / `DA334`）：**安卓专属的入口/开关不许在桌面摆出来**。
//
// 怎么发现的：Linux 走查 r693 把「设置 → 后台保活」「笔记 → 后台同步」
// 「通知与后台」三屏推上来抓像素，三屏的文字都是**安卓系统**才有的东西
// （电池优化白名单 / WorkManager 拉取 / 前台常驻服务），而对应的桥
// （`synhub/background`、`synhub/note_sync`）在桌面宿主上**不存在**
// ⇒ 开关点下去永远不动 = **假控件**（AGENTS：假控件比没控件更坏），
// 页顶横幅还把"服务没跑"读成"链路没准备好"，把用户往错的排查方向带。
//
// 修法：三处都按**能力位** fail-closed（`capabilityGateAllows`），
// 桌面**不摆入口**，手机照旧 —— 这正是 `app_platform.dart` 文件头"只有
// `available` 才放行"的口径。
//
// 本用例的判据（双向，防"恒假"）：
//   ① 强制宿主 = `linux` ⇒ 三处入口/区段**不在**；
//   ② 强制宿主 = `android` ⇒ **在**（证明门不是恒关）；
//   ③ 反向往回：改回 linux ⇒ 又不在（证明门是**当次读宿主**，不是一次性缓存）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/features/settings/notification_settings_page.dart';
import 'package:synhub/src/features/settings/settings_page.dart';

import 'support/chat_harness.dart';
import 'support/fake_background.dart';

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer c,
  Widget child, {
  List<Object> overrides = const [],
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: ProviderScope(
        // ignore: argument_type_not_assignable
        overrides: overrides.cast(),
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          home: child,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}

/// 设置页是长列表（懒构建）：不滚下去，靠后的行**根本没建**，
/// 那样"没找到"就是假绿 —— 每次都先滚到底再断言。
/// 设置页是**懒构建**长列表：默认 800×600 的测试窗口里，靠后的行**根本没建**，
/// 那样"没找到"就是假绿（滚到底只能看到最后几行，中间的行又已被回收）。
/// 所以把视口拉高到能一次装下整页 —— 这样"在不在"才是真的在不在。
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 每次用例后必须复位，否则会污染同进程里后面的用例。
void _forceHost(AppHost? host) {
  debugForceAppHost = host;
  addTearDown(() => debugForceAppHost = null);
}

/// 正向分支用**能力门放行开关**，不用"假装宿主是安卓"：
/// 安卓那一列的能力是 `probe(...)`，宿主测试里没有桥 ⇒ 探出来就是 unavailable，
/// 换宿主并不能证明"门开着的这一支也通"（那正是 AGENTS 说的"恒假判据"）。
void _forceGate(bool open) {
  debugForceCapabilityGate = open;
  addTearDown(() => debugForceCapabilityGate = false);
}

void main() {
  group('DA332 设置页「后台保活设置」只在有后台执行能力的宿主上出现', () {
    testWidgets('linux：不摆该行；门放开时摆出来（双向）', (tester) async {
      final h = await bootChat();
      _forceHost(AppHost.linux);
      _tallView(tester);
      await _pump(tester, h.container, const SettingsPage());
      expect(
        find.byKey(const Key('settings-oem-keepalive')),
        findsNothing,
        reason: '桌面宿主没有"电池优化白名单"这类系统页，摆出来就是死控件',
      );

      // 反向：门放开 ⇒ 这一行必须回来（证明上面那条 `findsNothing` 不是"恒假"）
      debugForceAppHost = AppHost.linux;
      _forceGate(true);
      await _pump(tester, h.container, const SettingsPage());
      expect(
        find.byKey(const Key('settings-oem-keepalive')),
        findsOneWidget,
        reason: '手机上这一行是功能的一部分（不用 FCM，保活决定通知能否到达）',
      );
      debugForceCapabilityGate = false;

      debugForceAppHost = AppHost.linux;
      await _pump(tester, h.container, const SettingsPage());
      expect(
        find.byKey(const Key('settings-oem-keepalive')),
        findsNothing,
        reason: '能力门必须**当次**读宿主，不是一次性缓存',
      );
    });
  });

  group('DA334 通知设置页的前台服务/开机自启两段只在手机上有', () {
    Future<void> pumpNotif(WidgetTester tester, ProviderContainer c) => _pump(
          tester,
          c,
          const NotificationSettingsPage(),
          overrides: [
            backgroundServiceProvider.overrideWithValue(FakeBackground()),
          ],
        );

    testWidgets('linux：两段都不在，横幅不再说"链路未就绪"', (tester) async {
      final h = await bootChat();
      _forceHost(AppHost.linux);
      await pumpNotif(tester, h.container);

      expect(find.text('前台服务'), findsNothing,
          reason: '桌面没有 `synhub/background` 桥 ⇒ 这段的两个开关都是死的');
      expect(find.text('前台常驻服务'), findsNothing);
      expect(find.text('开机自启'), findsNothing);
      // ★ 横幅：桌面判"链路好不好"只认 socket，不许因为"前台服务没跑"就报警
      expect(find.text('本机链路未完全就绪：请检查后台服务与网络。'), findsNothing,
          reason: '桌面没有前台服务，拿它当判据会把用户往错的排查方向带');
      // ★ DA335：**判据对了不等于文案对了** —— `notifLinkOk`/`notifLinkWarn` 两句
      //   都替用户说"后台服务在跑/没跑"，桌面上没有那个服务 ⇒ 这两句在桌面是假话。
      //   桌面只允许落到 `*ChannelOnly` 两句，且**恰好一句**（取决于 socket 状态）。
      const fgsOk = '本机链路正常：后台服务在跑，实时通道已连接。';
      const fgsWarn = '本机链路未完全就绪：请检查后台服务与网络。';
      const chOk = '本机链路正常：实时通道已连接（本平台没有常驻后台服务）。';
      const chWarn = '本机链路未就绪：实时通道没有连上，请检查网络。';
      expect(find.text(fgsOk), findsNothing, reason: '桌面这一句是假话（DA335）');
      expect(find.text(fgsWarn), findsNothing, reason: '桌面这一句是假话（DA335）');
      final channelOnly = find.text(chOk).evaluate().length +
          find.text(chWarn).evaluate().length;
      expect(channelOnly, 1, reason: '桌面横幅必须是 ChannelOnly 两句之一（DA335）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('门放开：两段都在（双向）', (tester) async {
      final h = await bootChat();
      _forceHost(AppHost.linux);
      _forceGate(true);
      await pumpNotif(tester, h.container);
      expect(find.text('前台服务'), findsOneWidget);
      expect(find.text('前台常驻服务'), findsOneWidget);
      expect(find.text('开机自启'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('DA333 笔记「后台同步」入口：源码守卫（该条走 WorkManager 桥）', () {
    // 这一条不另起一套 notes Mock 夹具：入口只是一个 `PopupMenuItem`，
    // 判据放在**源码结构**上更稳（AGENTS 里"纯文本守卫"同一手法），
    // 并带反向验证 —— 一旦有人把 `if (...)` 去掉，这里立刻红。
    test('bgSync 菜单项必须在能力门内，且门是 scheduledNoteSync', () {
      final src = _read('lib/src/features/notes/notes_page.dart');
      expect(
        src.contains('if (capabilityGateAllows(AppCapability.scheduledNoteSync))'),
        isTrue,
        reason: 'DA333 的门控条件被删掉了',
      );
      // 反向：不许再有"无条件"的 bgSync 菜单项（同一行上方 3 行内必须有 if）
      final idx = src.indexOf("value: 'bgSync'");
      expect(idx, greaterThan(0));
      final before = src.substring(idx - 260, idx);
      expect(before.contains('capabilityGateAllows('), isTrue,
          reason: 'bgSync 菜单项又变回无条件了（桌面会重新出现死开关）');
    });

    test('设置页的保活行与通知页的两段同样是"能力门里"的', () {
      final settings = _read('lib/src/features/settings/settings_page.dart');
      expect(
        settings.contains(
            'if (capabilityGateAllows(AppCapability.backgroundExecution))'),
        isTrue,
      );
      final notif =
          _read('lib/src/features/settings/notification_settings_page.dart');
      expect(notif.contains('if (_hasForegroundService) ...['), isTrue);
      expect(
        notif.contains(
            'capabilityGateAllows(AppCapability.backgroundExecution)'),
        isTrue,
      );
    });
  });
}

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '找不到 $path');
  return f.readAsStringSync();
}
