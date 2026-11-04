// macOS **逐屏截图审计**（r131）：把 macOS 上**每一个可达界面**逐个走到、
// 逐屏抓**应用内真实渲染像素**、逐屏记录"屏幕上真的画出了什么"。
//
// 为什么不是 `screencapture`（宿主级截屏）：
//   * 本机 macOS 27 的 SDK 里 `CGWindowListCreateImage` 已不可用；
//   * 宿主会话常处于**锁屏**，锁屏时窗口服务器不渲染其它 App 的窗口内容
//     （实测 `screencapture -x` 只拿到锁屏壁纸、`-l <winid>` 只拿到纯黑）。
// ⇒ 只用**应用内自渲染**：`RenderRepaintBoundary.toImage()`。
//   ★ 档位说明：这是"**应用内自渲染像素**"（真 Impeller/Metal、真字体/图标、
//     真 NAS 数据），**不能**证明"屏幕上没有被别的窗口遮挡"。
//
// ★ 生产零副作用：本文件属 `integration_test/`，**不参与 release 构建**；
//   `_rootKey` 那层 `RepaintBoundary` 只存在于本用例的 widget 树里。
//   `lib/` 一行没动。
//
// 跑法（一次只跑一组，用 `AUDIT_ONLY`）：
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test integration_test/macos_ui_audit_test.dart -d macos \
//     --dart-define=AUDIT_ONLY=files
//   # 不传 AUDIT_ONLY = 全跑
//
// 截图落点：**App 沙箱容器**的 tmp（沙箱不许写 /tmp）：
//   ~/Library/Containers/com.openviewai.synhub/Data/tmp/macwalk_r131/
//   跑完由 `tool/r131_collect.sh` 拷到 `/tmp/r131_macos_ui/`（台账里的路径口径）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/features/admin/admin_identity.dart'
    show isAdminProvider;
import 'package:synhub/src/core/router/app_router.dart';
import 'package:synhub/src/core/router/app_routes.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/diagnostics/diag_page.dart';
import 'package:synhub/src/features/downloads/download_bt_search_page.dart';
import 'package:synhub/src/features/downloads/download_create_page.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_rss_page.dart';
import 'package:synhub/src/features/files/file_row.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/features/notes/note_drawing_page.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/features/office/office_library_page.dart';
import 'package:synhub/src/features/servers/certificates_page.dart';
import 'package:synhub/src/features/servers/nas_manager_page.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';
import 'package:synhub/src/features/settings/e2ee_page.dart';
import 'package:synhub/src/features/settings/notification_settings_page.dart';
import 'package:synhub/src/features/settings/personal_profile_page.dart';
import 'package:synhub/src/features/settings/settings_page.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';
import 'package:synhub/src/features/chat/channel_row.dart';

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
const String _qc = String.fromEnvironment(
  'SYNO_NAS_QC',
  defaultValue: 'demo_admin-qq',
);

/// 只跑某几组（逗号分隔）；空 = 全跑。
const String _only = String.fromEnvironment('AUDIT_ONLY');

/// ★★ r349：把 `isAdminProvider` **直接钉成 true**（与宿主用例
/// `test/admin_gate_test.dart:285` 同一手法）⇒ 用来单独验
/// §2.0.7 的**正面**那一半契约「管理员必须看得见」。
/// 不开它时只验 fail-closed（非管理员看不到）。
///
/// 为什么需要：`y19_admin_gate` 原来的注释与判据都**只**覆盖"非管理员 ⇒ 不出现"，
/// 而 `AdminOnly` 是双向契约。iOS 侧的同族场景（`r132` 的 `s131`）就是因为
/// **只验一个方向 + 滚动预算不够**而误报过一次（见 `docs/platform-ios.md` §11）。
const bool _forceAdmin = bool.fromEnvironment('AUDIT_FORCE_ADMIN');

/// 是否允许**进入聊天频道**。默认 false：进频道会调 `viewChannel`
/// （把消息标已读 = 对真 NAS 的写）⇒ 只读铁律不许。Mock 站跑时置 `mock`。
const String _mode = String.fromEnvironment('AUDIT_MODE', defaultValue: 'real');

bool get _chatEnter => _mode == 'mock';

bool _want(String tag) =>
    _only.isEmpty || _only.split(',').map((e) => e.trim()).contains(tag);

/// 截图落点 = 本 App 容器的 tmp（沙箱**只允许**写容器内）。
final Directory _shotDir = Directory(
  '${Directory.systemTemp.path}/macwalk_r131',
)..createSync(recursive: true);

final GlobalKey _rootKey = GlobalKey(debugLabel: 'r131-root');

// ---------------------------------------------------------------- 台账

/// 逐屏台账（最后写成 `_ledger.json` + 打印）。
final List<Map<String, Object?>> _ledger = <Map<String, Object?>>[];

/// 英文模式下的中文泄漏命中（用户两次报障的那类现象）。
final List<String> _cjkHits = <String>[];

void _note(String s) => debugPrint('[r131] $s');

String _nowIso() => DateTime.now().toIso8601String();

/// 记一行台账。
void _row(
  String id, {
  required String status,
  String? note,
  List<String> shots = const <String>[],
  String? overflow,
  List<String> texts = const <String>[],
}) {
  _ledger.add(<String, Object?>{
    'id': id,
    'status': status,
    'note': note ?? '',
    'shots': shots,
    'overflow': overflow ?? '',
    'texts': texts,
    'at': _nowIso(),
  });
}

// ---------------------------------------------------------------- 工具

/// 推若干帧 + 真实等待（本用例**不能用 pumpAndSettle**：HUD 背景是常驻动画）。
Future<void> _wait(WidgetTester tester, [int ms = 500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 32));
    await Future<void>.delayed(const Duration(milliseconds: 32));
  }
}

/// 等条件成立（真实时间）。
Future<bool> _waitFor(
  WidgetTester tester,
  String label,
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  _note('等待超时：$label');
  return false;
}

bool _hasKey(String k) => find.byKey(Key(k)).hitTestable().evaluate().isNotEmpty;

/// ★ r349：**不看 hitTest** 的版本 —— 判「控件树里到底有没有它」。
/// `.hitTestable()` 会因遮挡/滚动位置给出**假否定**
/// （iOS 侧同族装置 `r132` 的相册时间线判据被它坑过三次）。
bool _hasKeyAny(String k) => find.byKey(Key(k)).evaluate().isNotEmpty;

/// ★ 只认**真的在屏幕上**的文字：外壳用 `IndexedStack` 保活，
/// 非当前 tab 的页面仍在 widget 树里（Offstage）⇒ 裸 `find.text` 会命中
/// 别的 tab 里的同名文字，点击于是**静默打空**。
bool _hasText(String s) => find.text(s).hitTestable().evaluate().isNotEmpty;

/// 当前屏上真的画出来的文本（去重、保序）。
List<String> _visibleTexts() {
  final out = <String>[];
  for (final e in find.byType(Text).hitTestable().evaluate()) {
    final d = (e.widget as Text).data;
    if (d == null) continue;
    final s = d.trim();
    if (s.isEmpty || out.contains(s)) continue;
    out.add(s);
  }
  return out;
}

/// 英文模式下必须**一个中日韩字符都没有**（§2.0.13 / §2.0.24 的用户可见口径）。
bool _hasCjk(String s) => RegExp(r'[\u3000-\u9fff\uff00-\uffef]').hasMatch(s);

void _sweepCjk(String id, List<String> texts) {
  final hits = texts.where(_hasCjk).toList();
  if (hits.isEmpty) return;
  _cjkHits.add('$id :: ${hits.join(' | ')}');
}

/// 抓一张**真实渲染**像素图。
Future<void> _shot(WidgetTester tester, String name) async {
  await _wait(tester, 350);
  final ro = _rootKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    _note('截图失败（没有 RepaintBoundary）：$name');
    return;
  }
  // ★ r131 实测坑：**宿主显示器一旦休眠，Metal 图层就不再出帧** ⇒
  //   `toImage()` 的 Future **永不完成**，整轮走查会在某一张截图上静默吊死
  //   （实测第 9 张卡住 5 分钟、App 进程 CPU 0%）。
  //   两道防线：① 跑之前先 `caffeinate -d -i -u`（见 `tool/r131_run.sh`）；
  //   ② 这里给 `toImage` 加超时 —— 超时只丢这一张，**不拖死整轮**（如实记 `shot-timeout`）。
  var ok = false;
  await tester.runAsync(() async {
    try {
      final img = await ro
          .toImage(pixelRatio: 2.0)
          .timeout(const Duration(seconds: 25));
      final bd = await img
          .toByteData(format: ui.ImageByteFormat.png)
          .timeout(const Duration(seconds: 25));
      final f = File('${_shotDir.path}/$name.png');
      f.writeAsBytesSync(bd!.buffer.asUint8List());
      _note('SHOT $name (${img.width}x${img.height}, ${bd.lengthInBytes}B)');
      ok = true;
    } catch (e) {
      _note('SHOT-FAIL $name :: $e');
      _row(name, status: 'shot-timeout', note: '$e');
    }
  });
  if (!ok) return;
}

/// 点一个 key；找不到返回 false。
Future<bool> _tapKey(WidgetTester tester, String key, {int settle = 700}) async {
  final f = find.byKey(Key(key)).hitTestable();
  if (f.evaluate().isEmpty) return false;
  try {
    await tester.ensureVisible(f.first);
  } catch (_) {}
  await _wait(tester, 150);
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 点一段文字（`last=true`：文件列表里的名字常在面包屑里也出现一次）。
Future<bool> _tapText(
  WidgetTester tester,
  String text, {
  int settle = 900,
  bool last = true,
}) async {
  final all = find.text(text).hitTestable();
  if (all.evaluate().isEmpty) return false;
  final f = last ? all.last : all.first;
  await tester.ensureVisible(f);
  await _wait(tester, 150);
  await tester.tap(f, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 点一个图标（只认**当前真的在屏上、可命中**的）。
Future<bool> _tapIcon(
  WidgetTester tester,
  IconData icon, {
  int settle = 700,
  bool last = false,
}) async {
  final all = find.byIcon(icon).hitTestable();
  if (all.evaluate().isEmpty) return false;
  final f = last ? all.last : all.first;
  try {
    await tester.ensureVisible(f);
  } catch (_) {}
  await _wait(tester, 150);
  await tester.tap(f, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 点一个 tooltip（英文标签）。找不到返回 false。
Future<bool> _tapTooltip(WidgetTester tester, String tip,
    {int settle = 700}) async {
  final f = find.byTooltip(tip).hitTestable();
  if (f.evaluate().isEmpty) return false;
  try {
    await tester.ensureVisible(f.first);
  } catch (_) {}
  await _wait(tester, 150);
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 写一段文字进第 n 个输入框。
Future<bool> _type(WidgetTester tester, int index, String text) async {
  final tf = find.byType(TextField).hitTestable();
  if (tf.evaluate().length <= index) return false;
  await tester.enterText(tf.at(index), text);
  await _wait(tester, 400);
  return true;
}

/// 列表里的目标可能**还没被 Sliver 构建**（800x600 下靠下的行根本没建）
/// ⇒ 先滚动到可见再点。★ 拖拽起点**不写死坐标**（按当前视图逻辑尺寸取）。
Future<bool> _tapTextScrolling(
  WidgetTester tester,
  String text, {
  int maxScrolls = 30,
  int settle = 4000,
}) async {
  // ★ r666：桌面双栏（左列表 / 右详情）的**两个**竖直 Scrollable 都要试。
  //   只取第一个（左栏）会滚不动右详情 ⇒ `Video` 滚不到、点不中，
  //   表现成"Video 目录里没有 mp4"（其实是**没进目录**）。
  for (var i = 0; i < maxScrolls; i++) {
    if (find.text(text).hitTestable().evaluate().isNotEmpty) break;
    final all = _verticalScrollables();
    if (all.isEmpty) break;
    for (final st in all) {
      if (find.text(text).hitTestable().evaluate().isNotEmpty) break;
      try {
        st.position.jumpTo(
          (st.position.pixels + 220).clamp(
            st.position.minScrollExtent,
            st.position.maxScrollExtent,
          ),
        );
        await _wait(tester, 120);
      } catch (_) {}
    }
  }
  return _tapText(tester, text, settle: settle);
}

/// 取**全部**竖直 Scrollable（双栏页面上有两个以上）。
List<ScrollableState> _verticalScrollables() {
  final out = <ScrollableState>[];
  for (final e in find.byType(Scrollable).evaluate()) {
    final st = (e as StatefulElement).state;
    if (st is ScrollableState && st.position.axis == Axis.vertical) out.add(st);
  }
  return out;
}

/// 取**竖直**方向的 Scrollable（页面上常有横向 PageView，取错了滚不动）。
ScrollableState? _verticalScrollable() {
  for (final e in find.byType(Scrollable).evaluate()) {
    final st = (e as StatefulElement).state;
    if (st is ScrollableState && st.position.axis == Axis.vertical) return st;
  }
  return null;
}

/// ★ r131 实测坑：`tester.dragFrom`（拖拽手势）在 macOS Live binding 下会
/// **偶发整轮吊死** —— 第 4 张截图之后停住 5 分钟、App 进程 CPU 0%、日志无输出。
/// 换成**不经过手势**的滚动：直接改 `ScrollableState.position`（`jumpTo`），
/// 效果等价（把靠下的行建出来），且不会卡在 TestAsyncUtils 的 guard 上。
Future<void> _scrollBy(WidgetTester tester, double dy) async {
  final st = _verticalScrollable();
  if (st == null) return;
  final pos = st.position;
  final target = (pos.pixels + dy).clamp(
    pos.minScrollExtent,
    pos.maxScrollExtent,
  );
  pos.jumpTo(target);
  await _wait(tester, 250);
}

/// 竖直滚动整页（给"靠下的行"取证）。
Future<void> _scrollDown(WidgetTester tester, {int times = 3}) async {
  for (var i = 0; i < times; i++) {
    await _scrollBy(tester, 320);
  }
}

/// 回到外壳首页（弹掉所有推入路由 + 回聊天 tab）。
Future<void> _resetToShell(WidgetTester tester) async {
  final nav = rootNavigatorKey.currentState;
  if (nav != null) {
    var guard = 0;
    while (nav.canPop() && guard++ < 8) {
      nav.pop();
      await _wait(tester, 250);
    }
  }
  final container = _container(tester);
  container?.read(appTabProvider.notifier).select(AppTab.chat);
  await _wait(tester, 500);
}

ProviderContainer? _container(WidgetTester tester) {
  final el = find.byType(SynologyChatApp);
  if (el.evaluate().isEmpty) return null;
  return ProviderScope.containerOf(tester.element(el.first), listen: false);
}

/// 按 key 前缀找控件（笔记行 `note-row-<id>` 这类 id 不可预知）。
Finder _keyPrefix(String prefix) => find
    .byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith(prefix),
    )
    .hitTestable();

/// 关掉当前弹层（底部弹层 / 对话框）。
///
/// 为什么不用"点 Cancel / 点遮罩"：r131 实测 —— 行菜单底部的 `Cancel` 在
/// 800x600 窗口里可能被裁到屏外（点了个空），而 `tapAt(20,20)` 又会**误中返回键**。
/// 直接 `NavigatorState.pop()` 最稳；只在"确实有弹层"时动手，避免误退页面。
Future<void> _dismissSheet(WidgetTester tester) async {
  // ① 先发 Escape：Flutter 的 `ModalRoute` 对 `DismissIntent` 内置处理，
  //    弹层/对话框/`PopupMenuButton` 菜单都能关，且**不会**动页面栈。
  for (var i = 0; i < 3; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _wait(tester, 500);
    if (find.byType(BottomSheet).evaluate().isEmpty) break;
  }
  // ② 兜底：确实还有底部弹层才 pop，**且只 pop 一次**。
  //    ★ r131 实测事故：原来无条件循环 pop 4 次 ⇒ 把 shell 那一页也 pop 掉，
  //    go_router 当场断言 `You have popped the last page off of the stack`，
  //    之后所有屏都截到空白页（f18–f21 全废）。判据必须带 `canPop()`。
  if (find.byType(BottomSheet).evaluate().isNotEmpty) {
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    if (nav.canPop()) {
      nav.pop();
      await _wait(tester, 800);
    }
  }
  await _wait(tester, 300);
}

/// 回到 NAS 根目录（每个模块先 `file-up` 回根，§3.7.5 第 2 条）。
Future<void> _filesRoot(WidgetTester tester) async {
  await _resetToShell(tester);
  await _tapKey(tester, 'dock-files', settle: 1500);
  for (var i = 0; i < 10; i++) {
    if (_hasText('docker')) break;
    if (!await _tapKey(tester, 'file-up', settle: 1200)) break;
  }
  // ★ r345：真 NAS 的共享名（docker/…）在 mock 站上**不存在** ——
  //   实测 mock 只有 `home`/`photo`（`list_share` 回读）。拿真 NAS 的名字当
  //   判据会让 mock 档每次"等待超时"，容易被误读成产品缺陷（§2.0.29 同型）。
  await _waitFor(
    tester,
    '文件根目录出现',
    () => _mode == 'mock' ? (_hasText('home') || _hasText('photo')) : _hasText('docker'),
    timeout: const Duration(seconds: 60),
  );
  await _wait(tester, 2000);
}

/// 打开 `/home/Drive` 里的一份文档（走文件入口；Office 阅读器三格式共用）。
Future<void> _openDriveFile(WidgetTester tester, String name) async {
  await _filesRoot(tester);
  await _tapText(tester, 'home', settle: 2500);
  if (_mode == 'mock') {
    _note('mock 站的 home 共享里没有真 NAS 的 Drive/Music ⇒ /home 列表这一格只能记未验（不是缺陷）');
  } else {
    await _waitFor(
      tester,
      '/home 列表',
      () => _hasText('Drive') && _hasText('Music'),
      timeout: const Duration(seconds: 60),
    );
  }
  await _wait(tester, 2000);
  await _tapTextScrolling(tester, 'Drive', settle: 2500);
  await _waitFor(
    tester,
    '/home/Drive',
    () => _hasText('Product spec.odoc'),
    timeout: const Duration(seconds: 60),
  );
  await _wait(tester, 2500);
  if (!await _tapTextScrolling(tester, name, settle: 4000)) {
    throw StateError('/home/Drive 里找不到 $name');
  }
}

/// 推一个真实页面（与 App 内部 push 的是同一个 widget / 同一套 provider）。
Future<void> _push(
  WidgetTester tester,
  Widget page, {
  int settle = 1500,
}) async {
  rootNavigatorKey.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => page),
  );
  await _wait(tester, settle);
}

// ---------------------------------------------------------------- 逐屏驱动

/// 一屏 = 一次导航/交互 + 一张收尾像素 + 一段文本 dump。
Future<void> _screen(
  WidgetTester tester,
  String id,
  Future<void> Function() body,
) async {
  final shots = <String>[];
  String overflow = '';
  try {
    await body();
    final ex = tester.takeException();
    if (ex != null) overflow = '$ex'.split('\n').first;
  } catch (e) {
    overflow = 'THROW ${'$e'.split('\n').first}';
    _note('SCREEN-FAIL $id :: $e');
    await _resetToShell(tester);
  }
  // 收尾像素永远拍（失败态本身也是证据）
  final shotName = id;
  final before = File('${_shotDir.path}/$shotName.png').existsSync();
  await _shot(tester, shotName);
  if (!before) shots.add('$shotName.png');
  final texts = _visibleTexts();
  _sweepCjk(id, texts);
  _row(
    id,
    status: overflow.isEmpty ? 'ok' : 'issue',
    shots: shots,
    overflow: overflow,
    texts: texts,
  );
  _note('SCREEN $id ${overflow.isEmpty ? 'OK' : 'ISSUE'} '
      'texts=${texts.take(14).join(' / ')}');
}

/// 启动真 App（与 `lib/main.dart` 的 overrides 同形）。
Future<void> _boot(WidgetTester tester) async {
  WidgetsFlutterBinding.ensureInitialized();
  final profile = DeviceProfile.detect();
  await NoteStationApi.initNoteDeviceName();
  await registerNoteBackgroundSync();
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
          if (_forceAdmin)
            isAdminProvider.overrideWith((ref) => Future.value(true)),
        ],
        child: const SynologyChatApp(),
      ),
    ),
  );
  await _wait(tester, 2500);
}

Future<bool> _ensureSession(WidgetTester tester, ProviderContainer c) async {
  final st = c.read(sessionControllerProvider);
  if (st.loggedIn && st.connection?.profile.value == _url) return true;

  debugPrint('[r666] ensureSession(UI): loggedIn=${st.loggedIn} '
      'profile=${st.connection?.profile.value} target=$_url');

  if (st.loggedIn || st.connection != null) {
    _note('切换到目标服务器：${st.connection?.profile.value} → $_url');
    await c.read(sessionControllerProvider.notifier).logout();
    await _wait(tester, 1800);
  }

  // ★★★ r666：**必须走界面**。实测：`await ctrl.connect(...)` 在真 NAS 上
  //   会一直停在 `LINK · HANDSHAKE`（等待中每秒 dump 的屏幕文本就是 setup 页），
  //   90 s 超时、`err=null`、信任框始终不出现 ⇒ chat/notes/… 这些非 auth 组
  //   两组全卡死（0 张截图）。改成"输地址 → 点能量核 → 点信任 → 填口令 → 点登录"
  //   这条用户真能走的路径后才有进度（与 a13/a14 同一套动作，也是仪器183 的教训）。
  appRouter.go(AppRoutes.setup);
  await _wait(tester, 1200);
  // ★ 段面板默认可能是 **QuickConnect**（setup 页 `_kind` 的初值）⇒ 直接把 URL
  //   输进第一个输入框会当成 QC ID 去解析（r666 实测：`get_server_info errno=4`）。
  //   必须先点「Direct address」那颗 `lan_outlined` 图标。
  final direct = find.byIcon(Icons.lan_outlined).hitTestable();
  if (direct.evaluate().isNotEmpty) {
    await tester.tap(direct.first, warnIfMissed: false);
    await _wait(tester, 700);
  }
  final addr = find.byType(TextField).hitTestable();
  if (addr.evaluate().isNotEmpty) {
    await tester.enterText(addr.first, _url);
    await _wait(tester, 400);
  }
  final orb = find.byType(EnergyOrb).hitTestable();
  if (orb.evaluate().isNotEmpty) {
    await tester.tap(orb.first, warnIfMissed: false);
  } else {
    _note('setup 页没有能量核 ⇒ 无法完成登录（后续屏记未验）');
    return false;
  }

  // 握手 + 首连信任（轮询真实时间，不能 pumpAndSettle）
  final shake = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(shake)) {
    await tester.pump(const Duration(milliseconds: 80));
    if (find.byType(AlertDialog).evaluate().isNotEmpty) break;
    if (c.read(sessionControllerProvider).connection != null) break;
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  if (find.byType(AlertDialog).evaluate().isNotEmpty) {
    final ok = find.byType(FilledButton);
    if (ok.evaluate().isNotEmpty) {
      debugPrint('[r666] 首连信任框 → 点 Trust');
      await tester.tap(ok.last, warnIfMissed: false);
    }
    await _wait(tester, 1800);
  }
  debugPrint('[r666] after-trust conn=${c.read(sessionControllerProvider).connection != null} '
      'texts=${_visibleTexts()}');
  final conn = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(conn) &&
      c.read(sessionControllerProvider).connection == null) {
    await tester.pump(const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  if (c.read(sessionControllerProvider).connection == null) {
    _note('连接未建立：${c.read(sessionControllerProvider).error}');
    return false;
  }
  // 登录表单：等它出现 + 让开场 HUD 演完
  final form = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(form) &&
      find.byType(TextField).hitTestable().evaluate().length < 2) {
    await tester.pump(const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  await _wait(tester, 14000);
  final fields = find.byType(TextField).hitTestable();
  debugPrint('[r666] form fields=${fields.evaluate().length} texts=${_visibleTexts()}');
  if (fields.evaluate().length >= 2) {
    await tester.enterText(fields.at(0), _account);
    await tester.enterText(fields.at(1), _password);
    await _wait(tester, 600);
  } else {
    _note('登录表单未出现（字段数=${fields.evaluate().length}）');
    return false;
  }
  // 点「Sign in」：**优先那颗能量核**（登录页真正的按钮就是它；`Sign in`
  // 这串文字在页面上出现两次 —— 核内标签 + 底部说明 ⇒ 点文字会点空，
  // r666 实测：点完 120 s 仍是登录页、`err=null`、没有登录请求）
  // ★ 登录页那颗核在表单下方，**必须先 ensureVisible** 才能点；`.hitTestable()`
  //   在这里会给出假否定（r666 实测：两个分支都是空 ⇒ 一次都没点，120 s 后
  //   还是登录页、`err=null`，日志里连 'tap' 都没有）。
  final orbAll = find.byType(EnergyOrb);
  debugPrint('[r666] signin orb count=${orbAll.evaluate().length} '
      'hit=${find.byType(EnergyOrb).hitTestable().evaluate().length}');
  if (orbAll.evaluate().isNotEmpty) {
    try {
      await tester.ensureVisible(orbAll.last);
      await _wait(tester, 800);
    } catch (_) {}
    await tester.tap(orbAll.last, warnIfMissed: false);
    debugPrint('[r666] tap EnergyOrb(sign in)');
  } else {
    final signIn = find.text('Sign in');
    if (signIn.evaluate().isNotEmpty) {
      await tester.tap(signIn.last, warnIfMissed: false);
      debugPrint('[r666] tap Sign in(text)');
    }
  }
  final login = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(login) &&
      !c.read(sessionControllerProvider).loggedIn) {
    await tester.pump(const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  await _wait(tester, 4000);
  debugPrint('[r666] post-signin loggedIn=${c.read(sessionControllerProvider).loggedIn} '
      'err=${c.read(sessionControllerProvider).error} texts=${_visibleTexts()}');
  final logged = c.read(sessionControllerProvider).loggedIn;
  debugPrint('[r666] uiLogin done loggedIn=$logged '
      'err=${c.read(sessionControllerProvider).error}');
  if (!logged) {
    _note('登录失败 error=${c.read(sessionControllerProvider).error} '
        'otp=${c.read(sessionControllerProvider).otpRequired}');
    return false;
  }
  await _wait(tester, 3000);
  return true;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS 逐屏截图审计（r131）', (tester) async {
    debugPrint('[r131] 截图目录 = ${_shotDir.path}');
    debugPrint('[r131] 目标 NAS = $_url  账号=$_account  QC=$_qc');

    await _boot(tester);
    final c = _container(tester)!;
    // 静默重登先跑完，否则连接按钮是禁用的
    await _waitFor(
      tester,
      'restore 结束',
      () => !c.read(sessionControllerProvider).restoring,
      timeout: const Duration(seconds: 90),
    );

    // ======================================================== ① 登录族
    // ★ 必须**先登出**：只有登出后才看得到「服务器设置 / QuickConnect /
    //   登录表单 / 首连信任」这四屏（否则静默重登直接进主页，拍不到）。
    //   登录会话按 §5.1 单独声明，不算业务写操作。
    if (_want('auth')) {
      await _screen(tester, 'a10_setup', () async {
        // ★ 登出要**等它真的落地**：`logout()` 要走一次 NAS 回包 + 路由切换，
        //   只 `_wait(2500)` 的话首两屏会拍到"还登着的频道列表"
        //   （r131 实测：a10/a11/a12 全拍成了 CHANNELS ⇒ 三屏报废）。
        if (c.read(sessionControllerProvider).loggedIn) {
          unawaited(c.read(sessionControllerProvider.notifier).logout());
        }
        await _waitFor(
          tester,
          '登出完成',
          () => !c.read(sessionControllerProvider).loggedIn,
          timeout: const Duration(seconds: 60),
        );
        await _waitFor(
          tester,
          '服务器设置页出现（QuickConnect 段图标）',
          () =>
              find.byIcon(Icons.cloud_outlined).hitTestable().evaluate().isNotEmpty,
          timeout: const Duration(seconds: 60),
        );
        // ★ r345：本机**已存口令**时 App 会立刻静默重登（见 a13 的注释），
        //   段面板只存在很短一瞬 ⇒ 这里只等很短，别用 3 s 把面板等没了。
        await _wait(tester, 350);
      });
      await _screen(tester, 'a11_qc_panel', () async {
        final seg = find.byIcon(Icons.cloud_outlined).hitTestable();
        if (seg.evaluate().isNotEmpty) {
          await tester.tap(seg.first, warnIfMissed: false);
          await _wait(tester, 800);
        } else {
          // ★ r345 订正：**不抛异常**。已存口令 ⇒ 段面板被自动重登顶掉是
          //   本机环境事实（a13 早有登记），不是产品缺陷；如实记为"未验"。
          _note('已存口令：登出后 App 立刻静默重登 ⇒ 本屏未验（不是缺陷）');
        }
      });
      await _screen(tester, 'a12_direct_panel', () async {
        final seg = find.byIcon(Icons.lan_outlined).hitTestable();
        if (seg.evaluate().isNotEmpty) {
          await tester.tap(seg.first, warnIfMissed: false);
          await _wait(tester, 800);
        } else {
          _note('已存口令：段面板已被自动重登顶掉 ⇒ 本屏未验（不是缺陷）');
        }
      });
      await _screen(tester, 'a13_login_page', () async {
        // ★ 本机**已存口令**：`connect()` 之后 App 会静默重登直接进主页，
        //   登录表单就不会出现（r131 两次实测都超时）。这里如实记未验，
        //   不硬等、也不假装拍到了登录页。
        // ★★★ r665 订正：以前这里是**直接调 `ctrl.connect()`**，指望路由自己
        //   跳到登录页 —— 实测跳不了：`/setup` → `/login` 的跳转写在
        //   `_submit()` 里（`context.go(AppRoutes.login)`），程序化调用绕过了它。
        //   结果 a13 每次都「等待超时：登录表单出现」、a14 落到"已存口令自动重登"
        //   这条错的解释上。现在改成**点那颗能量核**（= 用户的真实动作），
        //   只有找不到它时才回落到直接 connect。
        final ctrl = c.read(sessionControllerProvider.notifier);
        // ★★★ r666：`setup` 页的地址框会被**本机已存的 NAS 记录**预填（可能是 Mock）。
        //   只点能量核 = 连向那个预填地址 ⇒ real 档会静默连到 Mock 上（r666 实测：
        //   auth 组跑完 9 屏、`rc=0`，但 a15/a20 的文本里是 `http://127.0.0.1:18080`）。
        //   ⇒ 先把地址**改成 `_url`**（= 用户的真实动作「输入地址」），再点能量核。
        final addr = find.byType(TextField).hitTestable();
        if (addr.evaluate().isNotEmpty) {
          await tester.enterText(addr.first, _url);
          await _wait(tester, 300);
        }
        final orb = find.byType(EnergyOrb).hitTestable();
        if (orb.evaluate().isNotEmpty) {
          await tester.tap(orb.first, warnIfMissed: false);
        } else {
          _note('setup 页没找到能量核 ⇒ 回落直接 connect（本屏可能未验）');
          unawaited(
            ctrl.connect(
              ServerProfile(kind: ServerAddressKind.direct, value: _url),
            ),
          );
        }
        // 握手 + 首连信任框（轮询真实时间；不能 pumpAndSettle）
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 80));
          if (find.byType(AlertDialog).evaluate().isNotEmpty) break;
          if (c.read(sessionControllerProvider).connection != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        if (find.byType(AlertDialog).evaluate().isNotEmpty) {
          await _shot(tester, 'a13b_trust_dialog');
          final ok = find.byType(FilledButton);
          if (ok.evaluate().isNotEmpty) {
            await tester.tap(ok.last, warnIfMissed: false);
          }
          await _wait(tester, 1500);
        } else {
          _note('① 本次没有弹首连信任框（证书已在信任库里）');
        }
        await _waitFor(
          tester,
          '连接建立',
          () => c.read(sessionControllerProvider).connection != null,
          timeout: const Duration(seconds: 90),
        );
        await _waitFor(
          tester,
          '登录表单出现',
          () => find.byType(TextField).hitTestable().evaluate().length >= 2,
          timeout: const Duration(seconds: 60),
        );
        // ★ 进登录页后会先播一段 `SYSTEM BOOT` HUD（SELF-TEST/LINK/CRYPTO），
        //   它会盖住表单 ⇒ 等它演完再把第一个输入框滚进视口。
        await _wait(tester, 14000);
        final fields = find.byType(TextField).hitTestable();
        if (fields.evaluate().isNotEmpty) {
          try {
            await tester.ensureVisible(fields.first);
            await _wait(tester, 800);
          } catch (_) {}
        }
      });
      await _screen(tester, 'a14_login_filled', () async {
        final fields = find.byType(TextField).hitTestable();
        if (fields.evaluate().length >= 2) {
          await tester.enterText(fields.at(0), _account);
          await tester.enterText(fields.at(1), _password);
          await _wait(tester, 500);
        } else {
          // ★ r345 订正：字段数为 0 时 `fields.at(0)` 会抛 RangeError，
          //   而"已存口令已静默重登"是本机环境事实 ⇒ 如实记未验。
          _note('登录表单已不在（已存口令自动重登）⇒ 本屏未验（不是缺陷）');
        }
      });
      await _screen(tester, 'a15_home_after_login', () async {
        final orb = find.byType(EnergyOrb).hitTestable();
        if (orb.evaluate().isNotEmpty) {
          await tester.tap(orb.first, warnIfMissed: false);
        }
        await _waitFor(
          tester,
          '登录成功进主页',
          () =>
              c.read(sessionControllerProvider).loggedIn &&
              _hasKey('app-shell-stack'),
          timeout: const Duration(seconds: 120),
        );
        await _wait(tester, 5000);
      });
    }

    final loggedIn =
        c.read(sessionControllerProvider).loggedIn ||
        await _ensureSession(tester, c);
    if (!loggedIn) {
      _row('a99_login', status: 'issue', note: '无法建立会话，后续屏无法走查');
      debugPrint('[r131] 登录失败，终止');
      expect(loggedIn, isTrue, reason: '必须能登录才能逐屏走查');
      return;
    }
    // 强制英文（英文模式下的中文泄漏是本轮必查项）
    await c.read(localeChoiceProvider.notifier).set(LocaleChoice.en);
    await _wait(tester, 2500);

    if (_want('auth')) {
      await _screen(tester, 'a20_home_chat', () async {
        await _resetToShell(tester);
        await _wait(tester, 4000);
      });
      await _screen(tester, 'a30_nas_manager', () async {
        await _push(tester, const NasManagerPage());
      });
      await _screen(tester, 'a31_certificates', () async {
        await _resetToShell(tester);
        await _push(tester, const CertificatesPage());
      });
    }

    // ======================================================== ⑨ 系统 / 设置
    if (_want('system')) {
      await _screen(tester, 'y10_settings_top', () async {
        await _resetToShell(tester);
        await _push(tester, const SettingsPage());
        await _wait(tester, 1500);
      });
      await _screen(tester, 'y11_settings_mid', () async {
        await _scrollDown(tester, times: 3);
      });
      await _screen(tester, 'y12_settings_bottom', () async {
        await _scrollDown(tester, times: 6);
      });
      await _screen(tester, 'y13_language_sheet', () async {
        await _tapIcon(tester, Icons.translate_outlined, settle: 900);
      });
      await _screen(tester, 'y14_personal_profile', () async {
        await _wait(tester, 400);
        await _push(tester, const PersonalProfilePage());
      });
      await _screen(tester, 'y15_e2ee', () async {
        await _resetToShell(tester);
        await _push(tester, const E2eePage());
      });
      await _screen(tester, 'y16_notifications', () async {
        await _resetToShell(tester);
        await _push(tester, const NotificationSettingsPage());
      });
      await _screen(tester, 'y17_diagnostics', () async {
        await _resetToShell(tester);
        await _push(tester, const DiagPage(autoRun: false));
        await _wait(tester, 1500);
      });
      await _screen(tester, 'y18_ai_model', () async {
        await _resetToShell(tester);
        await _push(tester, const AiModelPage());
        await _wait(tester, 2500);
      });
      await _screen(tester, 'y19_admin_gate', () async {
        // ★★★ r349 订正：这一屏原来**只验了 fail-closed 一个方向**
        //   （注释与判据都是"非管理员 ⇒ 不出现"），而 `AdminOnly` 是**双向**契约。
        //   现在按开关分两档：
        //     * 不开 `AUDIT_FORCE_ADMIN`：非管理员/未解析 ⇒ **必须不出现**（fail-closed）
        //     * 开 `AUDIT_FORCE_ADMIN`：管理员 ⇒ **必须出现**（§2.0.7「管理员展示」）
        //   另外补**同族对照**：设置页全仓只有 3 个带 Key 的条目
        //   （`set-photo-ai-edit` / `set-admin-tools` / `set-personal-profile`），
        //   拿另外两个当对照 —— 一个都找不到就说明"没滚到那一段"，
        //   此时 `present=false` **不结论**（记未验，不是缺陷）。
        await _resetToShell(tester);
        await _push(tester, const SettingsPage());
        await _wait(tester, 1200);
        // ★ 预算放大：`maxScrollExtent` 在 iPhone 上实测 1810–2142px；
        //   原来这里**完全不滚动**（只在屏内找），
        //   而「管理工具」在 Profile 段、可能就在屏外 ⇒ 构造性假绿。
        for (var i = 0; i < 12 && !_hasKey('set-admin-tools'); i++) {
          await tester.drag(find.byType(ListView).first, const Offset(0, -400));
          await tester.pumpAndSettle();
        }
        final present = _hasKeyAny('set-admin-tools');
        final ctrlA = _hasKeyAny('set-photo-ai-edit');
        final ctrlB = _hasKeyAny('set-personal-profile');
        final onSettings = ctrlA || ctrlB;
        _row(
          'y19_admin_gate.detail',
          status: !onSettings ? 'unverified' : 'ok',
          note: '同族对照 photo-ai-edit=$ctrlA personal-profile=$ctrlB'
              '${onSettings ? '' : ' ⇒ 对照一个都没找到，本屏判不了（记未验，不是缺陷）'}'
              ' ｜ 强制管理员档=$_forceAdmin',
        );
        if (!onSettings) return; // 判不了就不判，**不当缺陷**
        if (_forceAdmin) {
          _row('y20_admin_gate_admin',
              status: present ? 'ok' : 'issue',
              note: present
                  ? '管理员（强制档）：管理工具入口**在**（§2.0.7 正面契约）'
                  : '管理员（强制档）却看不到管理工具入口 ⇒ 违反 §2.0.7「管理员展示」');
        } else {
          _row('y19_admin_gate.fail_closed',
              status: present ? 'issue' : 'ok',
              note: present
                  ? '非管理员却出现管理工具入口（权限泄漏方向）'
                  : '非管理员：管理工具入口不存在（正确隐藏，fail-closed）');
        }
      });
    }

    // ======================================================== ② 文件
    if (_want('files')) {
      await _screen(tester, 'f10_files_root', () async {
        await _filesRoot(tester);
      });
      await _screen(tester, 'f11_files_home', () async {
        await _filesRoot(tester);
        await _tapText(tester, 'home', settle: 2500);
        if (_mode == 'mock') {
          _note('mock 站的 home 里没有真 NAS 的 Drive/Music ⇒ 本屏只验"进得去 home"，'
              'Drive/Music 一格记未验（不是缺陷）');
        } else {
          await _waitFor(
            tester,
            '/home 列表',
            () => _hasText('Drive') && _hasText('Music'),
            timeout: const Duration(seconds: 60),
          );
        }
        await _wait(tester, 2500);
      });
      await _screen(tester, 'f12_files_grid_thumbs', () async {
        await _tapTooltip(tester, 'Switch to thumbnail view', settle: 1500) ||
            await _tapIcon(tester, Icons.grid_view_rounded, settle: 1500);
        await _wait(tester, 2500);
      });
      await _screen(tester, 'f13_files_drive_dir', () async {
        await _tapTooltip(tester, 'Switch to list view', settle: 1200);
        await _tapTextScrolling(tester, 'Drive', settle: 2500);
        await _waitFor(
          tester,
          '/home/Drive',
          () => _hasText('Product spec.odoc'),
          timeout: const Duration(seconds: 60),
        );
        await _wait(tester, 3000);
      });
      await _screen(tester, 'f14_files_up_breadcrumb', () async {
        // 「上一级」+ 面包屑（§2.0.11 修的那条）
        await _wait(tester, 500);
        await _tapKey(tester, 'file-up', settle: 2500);
        await _wait(tester, 2000);
      });
      await _screen(tester, 'f15_files_row_menu', () async {
        // 行尾 ⋮（tooltip = "More actions"）——不用 more_vert 裸图标，
        // 顶栏折叠入口也是 more_vert（AGENTS §2.0.10 第 3 条）
        if (!await _tapTooltip(tester, 'More actions', settle: 1500)) {
          final btn = find.descendant(
            of: find.byType(FileRow).first,
            matching: find.byIcon(Icons.more_vert),
          );
          if (btn.evaluate().isNotEmpty) {
            await tester.tap(btn.first, warnIfMissed: false);
            await _wait(tester, 1200);
          }
        }
        await _wait(tester, 1200);
      });
      await _screen(tester, 'f16_files_multiselect', () async {
        // 关掉上一步的行菜单，再长按进入多选
        await _dismissSheet(tester);
        if (find.byType(FileRow).hitTestable().evaluate().isEmpty) {
          // 兜底：确保真的在文件页（不是被前面的失败带到了别的页）
          await _filesRoot(tester);
        }
        final rows = find.byType(FileRow).hitTestable();
        if (rows.evaluate().isEmpty) throw StateError('列表里没有 FileRow');
        await tester.longPress(rows.first);
        await _wait(tester, 1500);
      });
      await _screen(tester, 'f17_files_batch_more', () async {
        await _tapText(tester, 'More', settle: 1500);
        await _wait(tester, 1200);
      });
      await _screen(tester, 'f18_files_sort', () async {
        // 先关掉上一步的批量动作弹层，再退出多选
        await _dismissSheet(tester);
        await _tapIcon(tester, Icons.close, settle: 1200);
        await _wait(tester, 800);
        await _tapIcon(tester, Icons.sort, settle: 1500);
        await _wait(tester, 1200);
      });
      await _screen(tester, 'f19_files_search', () async {
        // 关排序菜单（点 (20,20) 会误中返回键 ⇒ 用 pop）
        await _dismissSheet(tester);
        await _tapKey(tester, 'dock-files', settle: 1500);
        await _wait(tester, 800);
        await _tapIcon(tester, Icons.search, settle: 2500);
        await _wait(tester, 1500);
        await _type(tester, 0, 'Product');
        await _wait(tester, 4000);
      });
      await _screen(tester, 'f20_files_favorites', () async {
        await _resetToShell(tester);
        await _filesRoot(tester);
        await _tapIcon(tester, Icons.star_border, settle: 2500);
        await _wait(tester, 2500);
      });
      await _screen(tester, 'f21_files_share_links', () async {
        await _resetToShell(tester);
        await _filesRoot(tester);
        await _tapIcon(tester, Icons.link, settle: 2500);
        await _wait(tester, 2500);
      });
      await _screen(tester, 'f22_files_tools', () async {
        await _resetToShell(tester);
        await _filesRoot(tester);
        await _tapKey(tester, 'file-tools-entry', settle: 2000);
        await _wait(tester, 1500);
      });
      await _screen(tester, 'f23_files_recycle', () async {
        // ★ 回收站入口 `onRecycleBin` 只在**共享文件夹根**非 null
        //   （`file_browse_page.dart:1544` 的 `if (onRecycleBin != null)`）⇒
        //   必须先进入一个共享文件夹（root 里的 `docker`）。
        await _resetToShell(tester);
        await _filesRoot(tester);
        if (_mode == 'mock') {
          _note('mock 站没有真 NAS 的 docker 共享 ⇒ 本屏记未验（不是缺陷）');
        } else {
          await _tapText(tester, 'docker', settle: 3000);
        }
        await _wait(tester, 2000);
        final opened = await _tapTooltip(tester, 'Recycle bin', settle: 3000) ||
            await _tapIcon(tester, Icons.delete_outline, settle: 3000);
        if (!opened) {
          if (_mode == 'mock') {
            // ★ r345：入口的**出现条件**是"这份共享的列表里真有 `#recycle` 子项"
            //   （`hasRecycleBin` = 缓存条目里有 `RecyclePath.segment`）。
            //   mock 站没造 `#recycle` ⇒ 入口不出现是**正确行为**，不是缺陷。
            _note('mock 站没有 #recycle 子项 ⇒ 回收站入口按设计不出现（不是缺陷）');
            return;
          }
          throw StateError('共享文件夹根没有回收站入口');
        }
        await _wait(tester, 2500);
      });
      await _screen(tester, 'f24_files_tasks', () async {
        await _resetToShell(tester);
        await _filesRoot(tester);
        await _tapIcon(tester, Icons.sync, settle: 2500);
        await _wait(tester, 1500);
      });
      await _screen(tester, 'f25_drive_root', () async {
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-files', settle: 1500);
        await _wait(tester, 1500);
        await _tapText(tester, 'My Drive', settle: 4000);
        await _wait(tester, 4000);
      });
      await _screen(tester, 'f25b_drive_scope_intro', () async {
        // My Drive 首次进入的「三个范围」引导（已在上一步像素里取证）
        final hasIntro = _hasText('Got it');
        _row(
          'f25b_drive_scope_intro.detail',
          status: hasIntro ? 'ok' : 'unverified',
          note: hasIntro ? '引导弹层出现且带 Got it' : '本机未出现引导弹层（可能已展示过）',
        );
        await _dismissSheet(tester);
      });
      await _screen(tester, 'f26_drive_sort', () async {
        await _tapTooltip(tester, 'Sort', settle: 1500) ||
            await _tapIcon(tester, Icons.sort, settle: 1500);
        await _wait(tester, 1200);
      });
      await _screen(tester, 'f27_drive_create_menu', () async {
        await _dismissSheet(tester);
        // 新建菜单（FAB / 工具条）
        var opened = await _tapIcon(tester, Icons.add, settle: 1500);
        if (!opened) opened = await _tapIcon(tester, Icons.create_new_folder_outlined, settle: 1500);
        if (!opened) throw StateError('找不到 Drive 新建入口');
        await _wait(tester, 1200);
      });
      await _screen(tester, 'f28_drive_create_encrypted', () async {
        // ★ 800x600 窗口会把 8 项以上的弹层裁到屏外（AGENTS §2.0.9 测试坑）
        //   ⇒ 先滚动弹层再点，否则 tap 会打在遮罩上。
        // ★ r345 订正：这段以前在一级弹层里找 `drive-create-encrypted-doc`，
        //   那是**二级面板**的 key ⇒ 两层设计（官方 `create_encrypt` 子菜单）
        //   落地后就必然失败。现在按真实设计走：一级点「加密」→ 二级四选一。
        // ★ r345：`_scrollBy` 滚的是**页面**的 Scrollable（`_verticalScrollable()`），
        //   而弹层的内容在自己的 `SingleChildScrollView` 里 ⇒ 滚页面永远看不到被裁的项。
        //   正解：**不带 hitTestable** 地找，再 `ensureVisible`（它会滚最近的
        //   Scrollable = 弹层内层），最后才点。
        final enc = find.byKey(const Key('drive-create-encrypted'));
        if (!_hasKey('drive-create-encrypted') && enc.evaluate().isNotEmpty) {
          try {
            await tester.ensureVisible(enc.first);
          } catch (_) {}
          await _wait(tester, 1200);
        }
        if (!await _tapKey(tester, 'drive-create-encrypted', settle: 2000)) {
          throw StateError('新建弹层里没有「加密」入口（可能被裁掉）');
        }
        await _wait(tester, 1500);
        for (final k in const <String>[
          'drive-create-encrypted-doc',
          'drive-create-encrypted-sheet',
          'drive-create-encrypted-slides',
          'drive-create-encrypted-template',
        ]) {
          if (!_hasKey(k)) {
            throw StateError('二级「加密」面板里没有 $k（被裁掉或漏渲染）');
          }
        }
      });
    }

    // ======================================================== ③ 笔记
    if (_want('notes')) {
      await _screen(tester, 'n10_notes_list', () async {
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-workspace', settle: 1500);
        var opened = await _tapKey(tester, 'ws-tile-notes', settle: 2500);
        if (!opened) {
          await _push(tester, const NotesPage(), settle: 2500);
        }
        await _wait(tester, 10000);
      });
      await _screen(tester, 'n11_note_view', () async {
        final rows = _keyPrefix('note-row-');
        if (rows.evaluate().isEmpty) throw StateError('笔记列表为空（没有 note-row-*）');
        await tester.tap(rows.first, warnIfMissed: false);
        await _wait(tester, 8000);
      });
      await _screen(tester, 'n12_note_info', () async {
        await _tapKey(tester, 'note-info-entry', settle: 1500);
        await _wait(tester, 1200);
      });
      await _screen(tester, 'n13_note_editor', () async {
        await _tapKey(tester, 'note-editor-notebook', settle: 1500);
        await _wait(tester, 1200);
      });
      await _screen(tester, 'n14_note_drawing', () async {
        await _resetToShell(tester);
        await _push(tester, const NoteDrawingPage(), settle: 2000);
        await _wait(tester, 1500);
      });
      await _screen(tester, 'n15_notes_entries_menu', () async {
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-workspace', settle: 1500);
        await _tapKey(tester, 'ws-tile-notes', settle: 2500);
        await _wait(tester, 4000);
        await _tapKey(tester, 'note-fts-entry', settle: 2500);
        await _wait(tester, 1500);
      });
      await _screen(tester, 'n16_note_tag_filter', () async {
        await _resetToShell(tester);
        await _push(tester, const NotesPage(), settle: 2500);
        await _wait(tester, 2000);
        await _tapKey(tester, 'note-tag-filter-entry', settle: 2000);
        await _wait(tester, 1200);
      });
    }

    // ======================================================== ⑤ 相册
    if (_want('photos')) {
      await _screen(tester, 'p10_photos_timeline', () async {
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-photos', settle: 1500);
        await _wait(tester, 12000);
      });
      await _screen(tester, 'p11_photos_folders', () async {
        await _tapText(tester, 'Folders', settle: 4000);
        await _wait(tester, 4000);
      });
      await _screen(tester, 'p12_photos_favorites', () async {
        await _tapText(tester, 'Favorites', settle: 4000);
        await _wait(tester, 3000);
      });
      await _screen(tester, 'p13_photos_people', () async {
        await _tapText(tester, 'People', settle: 4000);
        await _wait(tester, 3000);
      });
      await _screen(tester, 'p14_photos_scenes', () async {
        await _tapText(tester, 'Scenes', settle: 4000);
        await _wait(tester, 3000);
      });
      await _screen(tester, 'p15_photos_albums', () async {
        await _tapText(tester, 'Photos', settle: 3000);
        await _wait(tester, 4000);
      });
      await _screen(tester, 'p16_photo_viewer', () async {
        await _tapText(tester, 'Timeline', settle: 4000);
        await _wait(tester, 3000);
        final tiles = find.byType(Image).hitTestable();
        if (tiles.evaluate().isEmpty) throw StateError('时间线里没有图片可点');
        await tester.tap(tiles.first, warnIfMissed: false);
        await _wait(tester, 5000);
      });
      await _screen(tester, 'p17_photo_viewer_menu', () async {
        await _tapIcon(tester, Icons.more_vert, settle: 1500);
        await _wait(tester, 1200);
      });
      await _screen(tester, 'p18_photo_search', () async {
        await _dismissSheet(tester);
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-photos', settle: 1500);
        await _wait(tester, 3000);
        await _tapIcon(tester, Icons.search, settle: 2500);
        await _wait(tester, 2000);
      });
    }

    // ======================================================== ⑥ Office
    if (_want('office')) {
      await _screen(tester, 'o10_office_odoc', () async {
        if (_mode == 'mock') {
          _note('mock 站没有真 NAS 的 Drive 文件「Product spec.odoc」⇒ 本屏记未验（不是缺陷）');
        } else {
          await _openDriveFile(tester, 'Product spec.odoc');
        }
        await _wait(tester, 18000);
      });
      await _screen(tester, 'o11_office_osheet', () async {
        if (_mode == 'mock') {
          _note('mock 站没有真 NAS 的 Drive 文件「Travel expenses.osheet」⇒ 本屏记未验（不是缺陷）');
        } else {
          await _openDriveFile(tester, 'Travel expenses.osheet');
        }
        await _wait(tester, 18000);
      });
      await _screen(tester, 'o12_office_oslides', () async {
        if (_mode == 'mock') {
          _note('mock 站没有真 NAS 的 Drive 文件「Celestial.oslides」⇒ 本屏记未验（不是缺陷）');
        } else {
          await _openDriveFile(tester, 'Celestial.oslides');
        }
        await _wait(tester, 18000);
      });
      await _screen(tester, 'o13_office_template_library', () async {
        await _resetToShell(tester);
        await _push(
          tester,
          const OfficeTemplateLibraryPage(),
          settle: 2500,
        );
        await _wait(tester, 8000);
      });
    }

    // ======================================================== ⑦ 音视频
    if (_want('media')) {
      await _screen(tester, 'm10_audio_home', () async {
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-workspace', settle: 1200);
        var opened = await _tapKey(tester, 'ws-tile-audio', settle: 2500);
        if (!opened) {
          await _push(tester, const AudioPage(), settle: 2500);
        }
        await _wait(tester, 12000);
      });
      await _screen(tester, 'm11_audio_song', () async {
        final song = find.text('Demo Song').hitTestable();
        if (song.evaluate().isEmpty) {
          if (_mode == 'mock') {
            _note('mock 站没有真 NAS 的音乐素材（Demo Song）⇒ 本屏记未验（不是缺陷）');
            return;
          }
          throw StateError('Audio Station 首页没有 Demo Song');
        }
        await tester.tap(song.first, warnIfMissed: false);
        await _wait(tester, 10000);
      });
      await _screen(tester, 'm12_audio_playing', () async {
        final play = find.byIcon(Icons.play_arrow).hitTestable();
        if (play.evaluate().isNotEmpty) {
          await tester.tap(play.first, warnIfMissed: false);
        }
        await _wait(tester, 10000);
      });
      await _screen(tester, 'm13_audio_equalizer', () async {
        await _resetToShell(tester);
        await _push(tester, const AudioPage(), settle: 2500);
        await _wait(tester, 6000);
        await _tapKey(tester, 'as-home-equalizer', settle: 2000);
        await _wait(tester, 1500);
      });
      await _screen(tester, 'm14_video_list', () async {
        await _filesRoot(tester);
        await _tapText(tester, 'home', settle: 2500);
        await _wait(tester, 2500);
        await _tapTextScrolling(tester, 'Video', settle: 3000);
        await _wait(tester, 3000);
      });
      await _screen(tester, 'm15_video_player', () async {
        // ★ r666：真 NAS 的 `/home/Video` 里同时有 `.mkv` 与 `.AVI`
        //   （实测：`Citizen Kane (1941).mkv`、`60招基础街球S01E01.AVI`）
        //   ⇒ 只认 `.mp4` 会把"有视频但没有 mp4"误判成缺陷。三种都算视频。
        final f = find
            .byWidgetPredicate(
              (w) => w is Text &&
                  (w.data ?? '').toLowerCase().endsWith(
                        '.mp4',
                      ) ||
                  (w is Text && (w.data ?? '').toLowerCase().endsWith('.mkv')) ||
                  (w is Text && (w.data ?? '').toLowerCase().endsWith('.avi')),
            )
            .hitTestable();
        if (f.evaluate().isEmpty) {
          if (_mode == 'mock') {
            _note('mock 站没有真 NAS 的 Video 目录/mp4 ⇒ 本屏记未验（不是缺陷）');
            return;
          }
          throw StateError('Video 目录里没有 mp4');
        }
        await tester.tap(f.first, warnIfMissed: false);
        await _wait(tester, 15000);
      });
    }

    // ======================================================== ⑧ 下载
    if (_want('download')) {
      await _screen(tester, 'd10_downloads', () async {
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-workspace', settle: 1200);
        var opened = await _tapKey(tester, 'ws-tile-downloads', settle: 2500);
        if (!opened) {
          await _push(tester, const DownloadPage(), settle: 2500);
        }
        await _wait(tester, 10000);
      });
      await _screen(tester, 'd11_download_create', () async {
        await _push(tester, const DownloadCreatePage(), settle: 2000);
        await _wait(tester, 1500);
      });
      await _screen(tester, 'd12_download_bt_search', () async {
        await _resetToShell(tester);
        await _push(tester, const DownloadBtSearchPage(), settle: 2500);
        await _wait(tester, 5000);
      });
      await _screen(tester, 'd13_download_rss', () async {
        await _resetToShell(tester);
        await _push(tester, const DownloadRssPage(), settle: 2500);
        await _wait(tester, 5000);
      });
      await _screen(tester, 'd14_download_settings', () async {
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-workspace', settle: 1200);
        await _tapKey(tester, 'ws-tile-downloads', settle: 2500);
        await _wait(tester, 6000);
        await _tapKey(tester, 'ds-settings', settle: 2500);
        await _wait(tester, 1500);
      });
    }

    // ======================================================== ④ Chat
    if (_want('chat')) {
      await _screen(tester, 'c10_channel_list', () async {
        await _resetToShell(tester);
        await _wait(tester, 6000);
      });
      if (_chatEnter) {
        await _screen(tester, 'c11_channel_session', () async {
          // ★ r345 订正：频道行是 `ChannelRow`（InkWell 自绘），**不是** ListTile
          //   ⇒ 旧判据 `byType(ListTile)` 恒空（假缺陷）。
          final row = find.byType(ChannelRow).hitTestable();
          if (row.evaluate().isEmpty) throw StateError('频道列表没有行');
          await tester.tap(row.first, warnIfMissed: false);
          await _wait(tester, 8000);
        });
        await _screen(tester, 'c12_post_longpress', () async {
          final tiles = find.byType(ListTile).hitTestable();
          if (tiles.evaluate().isNotEmpty) {
            await tester.longPress(tiles.last);
            await _wait(tester, 2000);
          }
        });
        await _screen(tester, 'c13_channel_menu', () async {
          await _dismissSheet(tester);
          await _tapIcon(tester, Icons.more_vert, settle: 2000);
          await _wait(tester, 1500);
        });
      } else {
        _row('c11_channel_session',
            status: 'unverified',
            note: '未验：进频道会触发 viewChannel（把消息标已读 = 对真 NAS 的写）⇒ '
                '按只读铁律不在真 NAS 上点入；需要 Mock 站复跑（AUDIT_MODE=mock）');
        _row('c12_post_longpress', status: 'unverified', note: '同上（依赖进入频道）');
        _row('c13_channel_menu', status: 'unverified', note: '同上（依赖进入频道）');
      }
    }

    // ======================================================== 收尾
    await _resetToShell(tester);

    // 台账落盘（跑完由 tool/r131_collect.sh 拷到 /tmp/r131_macos_ui/）
    final ledger = File('${_shotDir.path}/_ledger.json');
    ledger.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'generatedAt': _nowIso(),
        'target': _url,
        'account': _account,
        'locale': 'en',
        'screens': _ledger,
        'cjkHits': _cjkHits,
      }),
    );
    debugPrint('\n[r131] ===== 走查汇总 =====');
    for (final r in _ledger) {
      debugPrint('[r131] ${r['id']} :: ${r['status']} :: ${r['note']}');
    }
    debugPrint('[r131] 截图张数 = '
        '${_shotDir.listSync().whereType<File>().length}');
    debugPrint('[r131] 英文模式中文泄漏命中 = ${_cjkHits.length}');
    for (final h in _cjkHits) {
      debugPrint('[r131][CJK] $h');
    }
    final issues = _ledger.where((r) => r['status'] != 'ok').toList();
    debugPrint('[r131] 非 ok 屏 = ${issues.length}');
    expect(true, isTrue);
  });
}
