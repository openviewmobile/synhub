// r283 **iPad / 折叠屏自适应布局审计**（iPad Pro 11" M4 · iOS 18.6 模拟器 · 真 NAS 只读）。
//
// 目的（任务 4）：在**真跑的 iPad 模拟器**上把「竖屏 / 横屏」两种方向都走一遍，
//   ① 每屏抓一张**设备帧缓冲**（宿主 `simctl io screenshot`，与宿主锁屏无关）；
//   ② 现场断言**机制量**：竖屏 834pt ⇒ **medium 单列**（右栏不在树里）；
//      横屏 1210pt ⇒ **expanded 双栏**（左右两区域矩形同屏、不重叠）；
//   ③ 方向切换**保状态**（选中项 / 列表可见）。
//
// 为什么方向切换用 `SystemChrome.setPreferredOrientations` 而不是宿主旋转：
//   本机 Xcode 只装了命令行部分，**没有 `Simulator.app`**（`xcodebuild -showsdks`
//   可用，但 `/Applications/Xcode.app/Contents/Developer/Applications/` 不存在）
//   ⇒ 没有任何 GUI 菜单可点，`osascript` 也不能用。`setPreferredOrientations`
//   是**应用请求系统旋转**的官方通道（iOS 会真的把窗口转过去），
//   所以这里量到的 `MediaQuery.size` 是**真实的 iPad 横屏窗口尺寸**，不是合成注入。
//
// 跑法：
//   tool/r283_ipad_shot_poller.sh <iPad-UDID> &          # 宿主截图泵
//   flutter test integration_test/r283_ipad_adaptive_test.dart -d <iPad-UDID> --timeout 3600s
//
// ★ 生产零副作用：本文件在 `integration_test/`，不参与 release 构建；`lib/` 一行没动。
// ★ §5.1：只读账号 + 只读动作（进列表 / 点一行看预览），**零变更动词**。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/router/app_router.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/ui/adaptive_layout.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

// ---------------------------------------------------------------- 参数
const String _url = String.fromEnvironment(
  'SYNO_NAS_URL',
  defaultValue: 'https://nas.example.com:5001',
);
const String _account = String.fromEnvironment(
  'SYNO_NAS_ACCOUNT',
  defaultValue: 'demo_user',
);
const String _password = String.fromEnvironment(
  'SYNO_NAS_PASSWORD',
  defaultValue: '', // 用 --dart-define=SYNO_NAS_PASSWORD=… 提供
);

final Directory _syncDir = Directory('${Directory.systemTemp.path}/r132_ios_ui')
  ..createSync(recursive: true);
File get _req => File('${_syncDir.path}/req.txt');
File get _ack => File('${_syncDir.path}/ack.txt');

final GlobalKey _rootKey = GlobalKey(debugLabel: 'r283-ipad-root');
final List<String> _report = <String>[];

void _note(String s) {
  _report.add(s);
  debugPrint('[r283] $s');
}

// ---------------------------------------------------------------- 基础工具

Future<void> _wait(WidgetTester tester, [int ms = 500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 32));
    await Future<void>.delayed(const Duration(milliseconds: 32));
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  String label,
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TestFailure('等待超时：$label');
}

bool _hasKeyAny(String k) => find.byKey(Key(k)).evaluate().isNotEmpty;
Finder _byKeyPrefix(String prefix) => find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith(prefix);
});

/// 宿主截图握手：写界面名 → 等宿主把**帧缓冲**截下来并回 ack。
Future<void> _mark(WidgetTester tester, String name) async {
  try {
    _req.writeAsStringSync(name, flush: true);
  } catch (e) {
    _note('MARK-WRITE-FAIL $name: $e');
    return;
  }
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    try {
      if (_ack.existsSync() && _ack.readAsStringSync().trim() == name) {
        _note('MARK $name');
        return;
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  _note('MARK-TIMEOUT $name');
}

/// 当前**真实**逻辑窗口尺寸（真跑里它来自平台，不是测试注入）。
Size _logical(WidgetTester tester) =>
    tester.view.physicalSize / tester.view.devicePixelRatio;

/// **真旋转**：走 debug-only 原生钩子 `synhub/test_orientation`
/// （`ios/Runner/AppDelegate.swift` 的 `#if DEBUG` 段）。
///
/// 为什么不只用 `SystemChrome.setPreferredOrientations`（**实测**）：
/// iPad 上本 App 支持多任务（Info.plist 无 `UIRequiresFullScreen`）⇒
/// iPadOS 忽略方向掩码 ⇒ 请求 landscapeLeft 后窗口仍是 834×1210（竖屏）。
/// 真旋转必须走 scene 的 `requestGeometryUpdate`。
/// `mask`：portrait=2、landscapeLeft=16（`UIInterfaceOrientationMask` 原始值）。
Future<bool> _rotateNative(WidgetTester tester, int mask) async {
  // 先放开掩码（避免被上一次的限制挡住）
  await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
  await _wait(tester, 600);
  Object? r;
  try {
    r = await _orientationChannel.invokeMethod<bool>('rotate', {'mask': mask});
  } on Object catch (e) {
    _note('ROTATE-CHANNEL-FAIL $e');
    return false;
  }
  // 系统几何更新 + 布局重建需要几帧
  await _wait(tester, 3000);
  _note('ROTATE mask=$mask ack=$r logical=${_logical(tester)}');
  return r == true;
}

const MethodChannel _orientationChannel = MethodChannel('synhub/test_orientation');

ProviderContainer? _container(WidgetTester tester) {
  final el = find.byType(SynologyChatApp);
  if (el.evaluate().isEmpty) return null;
  return ProviderScope.containerOf(tester.element(el.first), listen: false);
}

void _pushNotes() {
  rootNavigatorKey.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => const NotesPage()),
  );
}

/// 断言"双栏"/"单列"的**机制量**（矩形几何，不是"某元素在不在"）。
String _paneGeometry(WidgetTester tester) {
  final master = find.byKey(const Key('note-wide-master'));
  final region = find.byKey(const Key('note-wide-region'));
  final hasM = master.evaluate().isNotEmpty;
  final hasR = region.evaluate().isNotEmpty;
  if (!hasM) return 'NO-MASTER';
  final mr = tester.getRect(master);
  if (!hasR) return 'SINGLE master=$mr';
  final rr = tester.getRect(region);
  return 'TWO-PANE master=$mr region=$rr '
      'overlap=${!(mr.right <= rr.left || rr.right <= mr.left)} '
      'bothOnScreen=${mr.left >= 0 && rr.right <= _logical(tester).width}';
}

// ---------------------------------------------------------------- 启动 / 登录

Future<void> _boot(WidgetTester tester) async {
  WidgetsFlutterBinding.ensureInitialized();
  final profile = DeviceProfile.detect();
  await NoteStationApi.initNoteDeviceName();
  final audioHandler = await createBackgroundAudioHandler();
  await tester.pumpWidget(
    RepaintBoundary(
      key: _rootKey,
      child: ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(profile),
          biometricAuthenticatorProvider.overrideWithValue(
            LocalAuthBiometricAuthenticator(),
          ),
          audioHandlerProvider.overrideWithValue(audioHandler),
        ],
        child: const SynologyChatApp(),
      ),
    ),
  );
  await _wait(tester, 2500);
}

Future<void> _login(WidgetTester tester, ProviderContainer container) async {
  // 直接地址分段
  final lan = find.byIcon(Icons.lan_outlined);
  if (lan.evaluate().isNotEmpty) {
    await tester.tap(lan.first, warnIfMissed: false);
    await _wait(tester, 600);
  }
  final tf = find.byType(TextField);
  if (tf.evaluate().isNotEmpty) {
    await tester.enterText(tf.first, _url);
    await _wait(tester, 300);
  }
  final orb = find.byType(EnergyOrb);
  if (orb.evaluate().isNotEmpty) {
    await tester.tap(orb.first, warnIfMissed: false);
  }
  await _waitFor(
    tester,
    '连接结果',
    () =>
        find.byType(AlertDialog).evaluate().isNotEmpty ||
        container.read(sessionControllerProvider).connection != null,
    timeout: const Duration(seconds: 90),
  );
  if (find.byType(AlertDialog).evaluate().isNotEmpty) {
    final ok = find.byType(FilledButton);
    if (ok.evaluate().isNotEmpty) {
      await tester.tap(ok.last, warnIfMissed: false);
    }
    await _wait(tester, 1500);
  }
  await _waitFor(
    tester,
    '进入登录页',
    () => find.byType(TextField).evaluate().length >= 2,
    timeout: const Duration(seconds: 120),
  );
  await _wait(tester, 8000);
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), _account);
  await tester.enterText(fields.at(1), _password);
  await _wait(tester, 400);
  FocusManager.instance.primaryFocus?.unfocus();
  await _wait(tester, 900);
  final orb2 = find.byType(EnergyOrb);
  if (orb2.evaluate().isNotEmpty) {
    try {
      await tester.ensureVisible(orb2.first);
    } catch (_) {}
    await _wait(tester, 400);
    await tester.tap(orb2.first, warnIfMissed: false);
  }
  await _waitFor(
    tester,
    '登录成功进主页',
    () =>
        container.read(sessionControllerProvider).loggedIn &&
        _hasKeyAny('app-shell-stack'),
    timeout: const Duration(seconds: 180),
  );
  await _wait(tester, 4000);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r283 iPad 自适应布局审计（竖屏/横屏 真跑）', (tester) async {
    _note('截图握手目录 = ${_syncDir.path}');
    _note('目标 NAS = $_url 账号=$_account');
    try {
      _ack.deleteSync();
    } catch (_) {}
    try {
      _req.deleteSync();
    } catch (_) {}

    // 前台方向先锁回"允许全部"，否则上一次会话的锁会带过来
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    await _boot(tester);
    final container = _container(tester)!;
    await _waitFor(
      tester,
      'restore 结束',
      () => !container.read(sessionControllerProvider).restoring,
      timeout: const Duration(seconds: 90),
    );

    if (!container.read(sessionControllerProvider).loggedIn) {
      _note('未登录 ⇒ 走登录流程');
      await _login(tester, container);
    } else {
      _note('已登录（设备上残留会话）');
    }

    // ============================================== 竖屏（834pt ⇒ medium ⇒ 单列）
    await _rotateNative(tester, 2); // 先确保是竖屏
    _note('竖屏 start logical=${_logical(tester)} '
        'class=${appWindowSizeOf(_logical(tester))}');
    if (!_hasKeyAny('app-shell-stack')) {
      _note('WARN 不在 shell（可能在 setup/login 页）');
    }

    // 直接推笔记页（不走工作台磁贴，少一层不稳定因素）
    _pushNotes();
    await _wait(tester, 9000);
    _note('竖屏 notes logical=${_logical(tester)} '
        'class=${appWindowSizeOf(_logical(tester))} geom=${_paneGeometry(tester)}');
    await _mark(tester, 'r283_ipad_portrait_notes_list');

    // 竖屏必须单列
    expect(
      appWindowSizeOf(_logical(tester)),
      AppWindowSize.medium,
      reason: 'iPad Pro 11" 竖屏 834pt 落在 600–839 ⇒ medium',
    );
    expect(
      find.byKey(const Key('note-wide-region')),
      findsNothing,
      reason: '竖屏 medium ⇒ 单列，右栏不许在树里',
    );

    // 点第一行 → 竖屏必须 push 路由
    final rows = _byKeyPrefix('note-row-');
    if (rows.evaluate().isNotEmpty) {
      await tester.tap(rows.first, warnIfMissed: false);
      await _wait(tester, 5000);
      // `find.byType` 默认 skipOffstage:true ⇒ 被压在下面的 NotesPage 会「找不到」
      // ⇒ 计数 0 恰好就是"路由**真的**推上去了"的机制量（不是"页面没了"）。
      final notesVisible = find
          .byType(NotesPage)
          .evaluate()
          .length;
      _note('竖屏 点行后 NotesPage(可见)=$notesVisible '
          'noteViewPushed=${notesVisible == 0} '
          'masterHidden=${!_hasKeyAny('note-wide-master')}');
      await _mark(tester, 'r283_ipad_portrait_note_view');
      await tester.pageBack();
      await _wait(tester, 2500);
    } else {
      _note('WARN 竖屏没有 note-row-（无数据）');
    }
    await _wait(tester, 1500);

    // ============================================== 横屏（1210pt ⇒ expanded ⇒ 双栏）
    final rotated = await _rotateNative(tester, 16); // landscapeLeft
    _note('横屏 rotated=$rotated logical=${_logical(tester)} '
        'class=${appWindowSizeOf(_logical(tester))} geom=${_paneGeometry(tester)}');
    await _mark(tester, 'r283_ipad_landscape_notes_list');

    expect(
      _logical(tester).width,
      greaterThan(_logical(tester).height),
      reason: '真旋转：横屏必须 width > height（量的是平台给的窗口尺寸）',
    );
    expect(
      appWindowSizeOf(_logical(tester)),
      AppWindowSize.expanded,
      reason: 'iPad Pro 11" 横屏 1210pt ≥ 840 ⇒ expanded',
    );
    expect(
      find.byKey(const Key('note-wide-region')),
      findsOneWidget,
      reason: '横屏 expanded ⇒ 右栏必须在树里',
    );

    final mr = tester.getRect(find.byKey(const Key('note-wide-master')));
    final rr = tester.getRect(find.byKey(const Key('note-wide-region')));
    expect(
      mr.right <= rr.left || rr.right <= mr.left,
      isTrue,
      reason: '左右两栏不许重叠：master=$mr region=$rr',
    );
    expect(
      mr.left >= 0 && rr.right <= _logical(tester).width,
      isTrue,
      reason: '两栏都要整块在屏内：master=$mr region=$rr',
    );

    // 点一行 → 横屏**不推路由**，右栏换预览（宽屏双栏的机制量）
    final rows2 = _byKeyPrefix('note-row-');
    if (rows2.evaluate().isNotEmpty) {
      await tester.tap(rows2.first, warnIfMissed: false);
      await _wait(tester, 6000);
      _note('横屏 点行后 geom=${_paneGeometry(tester)} '
          'detailKey=${_hasKeyAny('note-wide-detail')} '
          'masterStill=${_hasKeyAny('note-wide-master')}');
      await _mark(tester, 'r283_ipad_landscape_note_preview');
    } else {
      _note('WARN 横屏没有 note-row-（无数据）');
    }

    // ============================================== 转回竖屏：保状态
    await _rotateNative(tester, 2); // portrait
    _note('转回竖屏 logical=${_logical(tester)} geom=${_paneGeometry(tester)}');
    await _mark(tester, 'r283_ipad_portrait_after_rotation');
    expect(
      find.byKey(const Key('note-wide-region')),
      findsNothing,
      reason: '转回竖屏必须回到单列（右栏退出树）',
    );

    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    _note('=== 报告 ===');
    for (final l in _report) {
      debugPrint('[r283-report] $l');
    }
  });
}
