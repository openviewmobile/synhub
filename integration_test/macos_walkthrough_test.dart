// macOS **按模块走查**（第 63 轮 / r63）：在 **macOS 桌面端真渲染**里，
// 用**真 NAS**（只读）逐模块走一遍，并抓**真实渲染像素**。
//
// 跑法：
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test integration_test/macos_walkthrough_test.dart -d macos \
//     --dart-define=SYNO_NAS_URL=https://nas.example.com:5001 \
//     --dart-define=SYNO_NAS_ACCOUNT=demo_user \
//     --dart-define=SYNO_NAS_PASSWORD='…'
//
// 文件名**故意不匹配** `tool/device_feature_suite.sh` 的通配
// （`p0_*` / `phase*` / `drive_*` / `media_*`）⇒ 不会污染真机矩阵资产。
//
// ★ 像素证据为什么不是 `screencapture`：
//   本轮宿主 macOS 会话处于**锁屏**（`loginwindow`，见 docs/platform-macos.md §5），
//   锁屏时窗口服务器不渲染其它 App 的窗口内容 —— 实测 `screencapture -x` 只能
//   拿到锁屏壁纸，`screencapture -l <SynHub 窗口 id>` 只能拿到**纯黑**的内容区。
//   因此改用**应用内真实渲染抓帧**：`RenderRepaintBoundary.toImage()` ——
//   它取的是这个 macOS App 由 Impeller/Metal 真正画出来的图层（真字体、真图标、
//   真数据），不是布局断言。每张图都带 `[walk] shot` 日志 + 写出字节数。
//
// ★ 定义一律在用例内给默认值（AGENTS §2.0.20⑤）：本用例指向的是仓库既有的
//   **专用测试 NAS**（同一组凭据也硬编码在 `tool/flt_apis.dart` 等只读探针里）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/router/app_router.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/features/servers/session_controller.dart';
import 'package:synhub/src/core/media/camera_support.dart';
import 'package:synhub/src/core/ui/debounced_status_line.dart';
import 'package:synhub/src/features/chat/channel_row.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';

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

/// 只跑某几个模块（逗号分隔，如 `--dart-define=WALK_ONLY=office`），
/// 空 = 全跑。只为**迭代提速**，不影响最终交付口径（交付时全跑）。
const String _only = String.fromEnvironment('WALK_ONLY');

bool _want(String tag) =>
    _only.isEmpty || _only.split(',').map((e) => e.trim()).contains(tag);

/// 截图落点 = 本 App 容器的 tmp（沙箱**只允许**写容器内；
/// 实测写 `/tmp` 会 `PathAccessException(Operation not permitted)`）。
final Directory _shotDir = Directory('${Directory.systemTemp.path}/macwalk_r63')
  ..createSync(recursive: true);

final GlobalKey _rootKey = GlobalKey(debugLabel: 'walk-root');

/// 本轮走查的结论表（模块 → 结论/证据），最后由测试打印出来。
final List<String> _report = <String>[];

void _note(String s) {
  _report.add(s);
  debugPrint('[walk] $s');
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

bool _hasKey(String k) => find.byKey(Key(k)).evaluate().isNotEmpty;

/// ★ 只认**真的在屏幕上**的文字：外壳用 `IndexedStack` 保活，
/// 非当前 tab 的页面仍在 widget 树里（Offstage）⇒ 裸 `find.text` 会命中
/// 别的 tab 里的同名文字，`tap(warnIfMissed:false)` 于是**静默打空**。
bool _hasText(String s) => find.text(s).hitTestable().evaluate().isNotEmpty;

/// 文本**包含**匹配（服务器回的中文/长串用得上）。
bool _hasTextContaining(String s) =>
    find.textContaining(s).hitTestable().evaluate().isNotEmpty;

/// 抓一张**真实渲染**像素图。
Future<void> _shot(WidgetTester tester, String name) async {
  await _wait(tester, 350);
  final ro = _rootKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    _note('截图失败（没有 RepaintBoundary）：$name');
    return;
  }
  await tester.runAsync(() async {
    final img = await ro.toImage(pixelRatio: 2.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('${_shotDir.path}/$name.png');
    f.writeAsBytesSync(bd!.buffer.asUint8List());
    _note(
      'SHOT $name → ${f.path} (${img.width}x${img.height}, '
      '${bd.lengthInBytes}B)',
    );
  });
}

/// 点第 [index] 个 [EnergyOrb]（页面里的「主行动」）——**先滚动到可见**，
/// 否则 800x600 的桌面窗口下它在折叠线以下，`tap` 会静默打空。
Future<bool> _tapOrb(WidgetTester tester, {int index = 0}) async {
  final all = find.byType(EnergyOrb);
  if (all.evaluate().length <= index) return false;
  final f = all.at(index);
  try {
    await tester.ensureVisible(f);
  } catch (_) {
    // 没有可滚动祖先：原地即可
  }
  await _wait(tester, 250);
  await tester.tap(f, warnIfMissed: false);
  await _wait(tester, 600);
  return true;
}

/// 打印"当前屏幕上真的画出来了什么"：关心的 key + 可见文本。
/// 走查里每个模块失败时必须能立刻看出**卡在哪一态**（loading / failure / 空 / 正常）。
void _dumpUi(WidgetTester tester, String tag) {
  const keys = <String>[
    'office-doc-view', 'office-doc-loading', 'office-doc-failure',
    'office-doc-empty-doc', 'office-doc-session-expired',
    'office-sheet-page', 'office-sheet-loading', 'office-sheet-failure',
    'office-slides-page', 'office-slides-loading', 'office-slides-failure',
    'file-page-loading', 'file-page-error',
    // 其它模块的"这一页真的画出来了"锚点
    'as-home-recently-played', 'as-library-personal', 'as-home-menu',
    'note-fts-entry', 'note-joined-entry', 'note-c3-import-entry',
    'photo-album-create', 'photo-backup-entry', 'photo-concepts-count',
    'ds-add-task', 'ds-browser-open', 'ds-batch-menu',
  ];
  final present = keys.where((k) => _hasKey(k)).toList();
  final texts = <String>[];
  for (final e in find.byType(Text).evaluate().take(40)) {
    final d = (e.widget as Text).data;
    if (d != null && d.trim().isNotEmpty) texts.add(d.trim());
  }
  _note('$tag keys=${present.join('|')} texts=${texts.take(18).join(' / ')}');
}

/// 点一个 key；找不到返回 false。
Future<bool> _tapKey(
  WidgetTester tester,
  String key, {
  int settle = 700,
}) async {
  final f = find.byKey(Key(key));
  if (f.evaluate().isEmpty) return false;
  // ⚠️ 同 `_tapText`：**不调** `ensureVisible` —— 它内部 `pumpAndSettle()` 会
  //    被每秒刷新的状态行/角标拖住（r670 实测：卡满 10 分钟才抛）。
  if (!f.hitTestable().evaluate().isNotEmpty) return false;
  await _wait(tester, 120);
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 点一段文字（取最后一个匹配：文件列表里的名字常在面包屑里也出现一次）。
Future<bool> _tapText(
  WidgetTester tester,
  String text, {
  int settle = 900,
  bool last = true,
}) async {
  final all = find.text(text).hitTestable();
  if (all.evaluate().isEmpty) return false;
  final f = last ? all.last : all.first;
  // ⚠️ 这里**故意不调** `tester.ensureVisible`：它内部会 `pumpAndSettle()`，
  //    而本页有一个每秒刷新的定高状态行/角标 ⇒ "永远有待处理帧" ⇒
  //    实测会卡满 10 分钟再抛（r670 文件模块连续两次卡死在这）。
  await _wait(tester, 150);
  await tester.tap(f, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 在**左栏**（`file-wide-master`）里点某一行，并保证"真的进去"。
///
/// ★ r673：宽屏右栏改成**信息卡**后，左栏单击只选中（右栏出详情），
///   要再点同一行（`alreadyShown` 规则）或按「打开」才进入 ——
///   走查里两下点击之间天然隔 ≈1.5 s，所以这里不依赖 500ms 时间窗，
///   而是"同一行再点一次"。窄屏（没有 `file-wide-master`）单击即进入，
///   第二下找不到目标会自动跳过。
Future<void> _enterFolderInMaster(
  WidgetTester tester,
  String name, {
  int settle = 2500,
}) async {
  Finder row() => find.descendant(
    of: find.byKey(const Key('file-wide-master')),
    matching: find.text(name),
  );
  final wide = find.byKey(const Key('file-wide-master')).evaluate().isNotEmpty;
  if (wide) {
    if (row().evaluate().isEmpty) return;
    await tester.tap(row().hitTestable().first, warnIfMissed: false);
    await _wait(tester, 1500);
    // 第二下 = 打开（右栏已经显示它，走 `alreadyShown` 那条判据）
    if (row().evaluate().isNotEmpty) {
      await tester.tap(row().hitTestable().first, warnIfMissed: false);
      await _wait(tester, settle);
      return;
    }
  }
  await _tapText(tester, name, settle: settle);
}

/// 自足导航：外壳 → 文件 → `home` → [sub]（如 `Drive` / `Video`）。
/// **每个模块都自己走一遍**，这样 `WALK_ONLY` 只跑单个模块时也成立。
Future<void> _gotoHomeSub(
  WidgetTester tester,
  String sub, {
  String expectAfter = '',
}) async {
  await _resetToShell(tester);
  await _tapKey(tester, 'dock-files', settle: 1500);
  await _dismissCoach(tester);
  // ★ 文件页用 `IndexedStack` 保活，浏览栈**会留在上一处** ⇒ 先逐级退回 NAS 根
  // ★ r670：**宽屏右栏的"上一级"是 `file-wide-up`，窄屏才是 `file-up`**，
  //   而 `file-breadcrumb-up` 又只出现在窄屏面包屑上（`DA291` 三种表示）。
  //   走查只认一种 key ⇒ Windows 站在 `/home/Drive` 里"回不到根"，
  //   表现成"等待超时：文件根目录出现"（macOS 站恰好上次停在根，才没暴露）。
  for (var i = 0; i < 10; i++) {
    if (_hasText('docker')) break;
    var ok = await _tapKey(tester, 'file-up', settle: 1200);
    if (!ok) ok = await _tapKey(tester, 'file-wide-up', settle: 1200);
    if (!ok) ok = await _tapKey(tester, 'file-breadcrumb-up', settle: 1200);
    if (!ok) {
      // 最后一招：切回 NAS 源（切源会回到该源的根）
      ok = await _tapAnyText(tester, const [
        'NAS files',
        'NAS 文件',
      ], settle: 1500);
    }
    if (!ok) break;
  }
  await _waitFor(
    tester,
    '文件根目录出现',
    () => _hasText('docker'),
    timeout: const Duration(seconds: 60),
  );
  await _wait(tester, 1500);
  _dumpTexts(tester, 'gotoHomeSub@root');
  final intoHome = await _enterFolder(
    tester,
    'home',
    // `/home` 有 9 个目录，窗口矮时靠下的 `Music` 根本没被 Sliver 构建
    // （r670 macOS 800x600 实测：只到 `ebooktest`）⇒ 判据用**靠上的两个**，
    // 别拿"列表中部以后的条目"当"进没进去"。
    visible: () => _hasText('Drive') && _hasText('Download'),
  );
  _dumpTexts(tester, 'gotoHomeSub@home');
  expect(intoHome, isTrue, reason: 'NAS 根目录里进不去 `home`');
  await _wait(tester, 2000);
  if (sub.isNotEmpty) {
    // `/home` 有 10 个子项，靠下的（如 `Video`）在 800x600 的窗口里没被构建 ⇒
    // 必须先滚动才点得到。
    final intoSub = await _enterFolder(
      tester,
      sub,
      visible: () => _hasTextContaining(expectAfter),
      timeout: const Duration(seconds: 30),
    );
    expect(intoSub, isTrue, reason: '/home 里点不进 `$sub`');
    if (expectAfter.isNotEmpty) {
      await _waitFor(
        tester,
        '/home/$sub 列表出现',
        // ★ r717：长文件名在真 NAS 上被 ellipsis 截断 ⇒ 用"包含"判据。
        () => _hasTextContaining(expectAfter),
        timeout: const Duration(seconds: 60),
      );
      await _wait(tester, 2000);
    }
  }
}

/// ★ r670：**站与站之间的 UI 语言不同**（macOS 走英文、Windows 走中文系统
/// 语言），所以判据一律"任一语言命中即可"，别把某端的语言写死成契约。
bool _hasAnyText(List<String> ss) => ss.any(_hasText);
bool _hasAnyContaining(List<String> ss) => ss.any(_hasTextContaining);

Future<bool> _tapAnyText(
  WidgetTester tester,
  List<String> ss, {
  int settle = 2000,
}) async {
  for (final s in ss) {
    if (await _tapText(tester, s, settle: settle)) return true;
  }
  return false;
}

/// 首次进 Drive / File Station 会弹一层**引导卡**（"This is My Drive —
/// it's split into three scopes" / "Got it"）。`flutter test` 每次都装新包 ⇒
/// 每轮都是"第一次" ⇒ 走查必须先把它收掉，否则它会挡住条目与后续点击。
Future<void> _dismissCoach(WidgetTester tester) async {
  for (final label in const ['Got it', '知道了', 'Dismiss', 'Skip', '稍后']) {
    for (var i = 0; i < 2; i++) {
      if (!_hasText(label)) break;
      await _tapText(tester, label, settle: 900);
    }
  }
}

/// 宽屏文件站是**两步**：左侧点条目 = 选中（右栏出详情），再按右栏的
/// `file-wide-open` 才真正打开（§2.0.70 ⑪ 的规矩；r670 Office 模块第一版
/// 只做了第一步 ⇒ 截图还停在列表上）。
Future<void> _openInWidePane(
  WidgetTester tester,
  String name, {
  int settle = 4000,
}) async {
  var tapped = await _tapText(tester, name, settle: 1500);
  if (!tapped) {
    // 靠下的条目（`Celestial.oslides` 在 /mydrive 15 项里排第 5 行之后）
    // 还没被 Sliver 构建 ⇒ 先滚到可见再点。
    tapped = await _tapTextScrolling(tester, name, settle: 1500);
  }
  if (!tapped) {
    // ★ r717：真 NAS 的长文件名会被 ellipsis 截断，精确匹配假阴 ⇒ 退到"包含"。
    tapped = await _tapTextScrolling(tester, name, containing: true, settle: 1500);
  }
  expect(tapped, isTrue, reason: '列表里找不到 $name');
  if (!_hasKey('file-wide-open') && !_hasKey('file-wide-preview')) {
    await _waitFor(
      tester,
      '$name 选中出详情',
      () => _hasKey('file-wide-open'),
      timeout: const Duration(seconds: 25),
    );
  }
  expect(
    await _tapKey(tester, 'file-wide-open', settle: settle),
    isTrue,
    reason: '$name 的"预览"按钮点不到',
  );
}

/// ★ r671（`DA297`/`DA298`）：宽屏「左选右开」的两条**用户手测**判据。
///
/// ① 单击文件 ⇒ 右栏详情卡必须带**头部与「上一级」**（以前只剩名字/体积/路径，
///    没有任何回父目录的入口 —— 用户："这个页面无返回到上级父目录"）；
/// ② **双击**文件行 ⇒ 直接进预览（以前只能"选中 → 按「打开预览」"两跳 ——
///    用户："打开文件不能直接打开，会出现一个中间页面"）。
///
/// ★ 只有宽屏（`file-wide-detail` 存在）才做这两条；窄屏单击本来就是直接打开，
///   不在这里重复量（窄屏那条由 ⑦ 的 `_openInWidePane` 之外的老路径覆盖）。
Future<void> _assertWideDetailBackAndDoubleTap(
  WidgetTester tester,
  String name,
) async {
  var tapped = await _tapText(tester, name, settle: 1500);
  if (!tapped) {
    tapped = await _tapTextScrolling(tester, name, settle: 1500);
  }
  expect(tapped, isTrue, reason: '列表里找不到 $name');
  await _wait(tester, 800);
  if (!_hasKey('file-wide-detail')) {
    _note('② 文件：本次不是宽屏（没有 file-wide-detail）⇒ DA297/DA298 跳过');
    return;
  }
  expect(
    _hasKey('file-wide-header'),
    isTrue,
    reason: 'DA297：右栏详情卡必须带头部（就是"回父目录"的那一行）',
  );
  expect(_hasKey('file-wide-up'), isTrue, reason: 'DA297：详情卡必须能回「上一级」');
  await _shot(tester, '07c_wide_detail_back');

  // ② 双击直接打开：两次 tap 必须落在 `kDoubleTapTimeout` 之内。
  //   ★ 必须点在**左栏列表里那一行**：选中之后右栏详情卡上也有同一个文件名
  //     （那是 `Text`，不是行）—— 拿 `find.text(name).last` 会点到详情卡上，
  //     r671 第一版就是这么假红的（`MODULE-FAIL ⑥ 等待超时：DA298 …`）。
  final row = find.descendant(
    of: find.byKey(const Key('file-wide-master')),
    matching: find.text(name).hitTestable(),
  );
  expect(row.evaluate().isNotEmpty, isTrue, reason: '双击前左栏必须有 $name 行');
  // ★ 两下之间**不留任何等待**：真机上每次 `tester.tap` 自己就要几十到上百毫秒，
  //   再加一个 `_wait` 就可能超过 App 那边 500ms 的判定窗（r671 第三版假红）。
  final sw = Stopwatch()..start();
  await tester.tap(row.last, warnIfMissed: false);
  await tester.tap(row.last, warnIfMissed: false);
  sw.stop();
  debugPrint('[walk] DA298 两次点击间隔 ≈ ${sw.elapsedMilliseconds}ms');
  // ★ `.odoc` 走的是**Office 阅读器**（`openFileUnified`），不是
  //   `FilePreviewPage` —— r671 第二版只等 `FilePreviewPage` ⇒ 又是假红
  //   （`MODULE-FAIL ⑥ 等待超时：DA298`）。判据改成"任一阅读器出来了"。
  await _wait(tester, 1500);
  debugPrint(
    '[walk] DA298 after taps: detail=${_hasKey('file-wide-detail')} '
    'preview=${find.byType(FilePreviewPage).evaluate().isNotEmpty} '
    'doc=${_hasKey('office-doc-view')} empty=${_hasKey('file-wide-empty')}',
  );
  _dumpUi(tester, '② 双击后');
  await _waitFor(
    tester,
    'DA298 双击直接打开（预览/阅读器）',
    () =>
        find.byType(FilePreviewPage).evaluate().isNotEmpty ||
        _hasKey('office-doc-view') ||
        _hasKey('office-sheet-page') ||
        _hasKey('office-slides-page'),
    timeout: const Duration(seconds: 30),
  );
  _dumpUi(tester, '② 双击打开');
  await _wait(tester, 2500);
  await _shot(tester, '07d_wide_doubletap_open');
  _note('② 文件：详情卡有头部+上一级（DA297）· 双击直接打开预览（DA298）');
  await _resetToShell(tester);
}

/// 把当前屏上所有 `Text` 打出来（诊断用；只在失败时才需要看）。
// ignore: unused_element
void _dumpTexts(WidgetTester tester, String tag) {
  final seen = <String>[];
  for (final e in find.byType(Text).evaluate()) {
    final t = (e.widget as Text).data;
    if (t != null && t.trim().isNotEmpty && !seen.contains(t)) seen.add(t);
  }
  debugPrint('[walk] TEXTS($tag) = $seen');
}

/// 进目录：**宽屏单点即进、窄屏也是单点**，但真机上偶尔会因为
/// 上一帧还在动画/引导卡而吞掉这一次点击 ⇒ 这里做"点 → 等 → 再点"，
/// 并在第二次给一次 `file-wide-open`（宽屏右栏的"打开"）。
Future<bool> _enterFolder(
  WidgetTester tester,
  String name, {
  required bool Function() visible,
  Duration timeout = const Duration(seconds: 25),
}) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    var tapped = await _tapText(tester, name, settle: 1500);
    if (!tapped) {
      tapped = await _tapTextScrolling(tester, name, settle: 1500);
    }
    if (tapped) {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await _wait(tester, 600);
        if (visible()) return true;
      }
      // 还停在原处 ⇒ 试试宽屏右栏的"打开"（选中后才会出现）
      await _tapKey(tester, 'file-wide-open', settle: 1200);
      final d2 = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(d2)) {
        await _wait(tester, 600);
        if (visible()) return true;
      }
    } else {
      await _wait(tester, 800);
    }
  }
  return visible();
}

/// 自足导航：外壳 → 文件 → **My Drive** 标签（Office 样本都在这里，不在
/// File Station 的 `/home/Drive` 里 —— r670 用 `tool/nas_mydrive_state.dart`
/// 只读列过：`/mydrive` 15 项含 Product spec.odoc / Travel expenses.osheet /
/// Celestial.oslides，而 `/home/Drive` 只有 4 项）。
Future<void> _gotoMyDrive(WidgetTester tester) async {
  await _resetToShell(tester);
  await _tapKey(tester, 'dock-files', settle: 1500);
  expect(
    await _tapAnyText(tester, const ['My Drive', '我的 Drive'], settle: 2500),
    isTrue,
    reason: '文件页顶部应有 My Drive 胶囊',
  );
  // 首次进 My Drive 会有一层**引导卡** ⇒ 先收掉再找文件。
  await _dismissCoach(tester);
  await _waitFor(
    tester,
    'My Drive 列表出现',
    () => _hasTextContaining('trip planner'),
    timeout: const Duration(seconds: 60),
  );
  await _wait(tester, 2000);
}

/// 列表里的目标可能**还没被 Sliver 构建**（800x600 的窗口下靠下的行根本没建）
/// ⇒ 先滚动到可见再点。
Future<bool> _tapTextScrolling(
  WidgetTester tester,
  String text, {
  int maxScrolls = 30,
  int settle = 4000,
  /// ★ r717：真 NAS 的长文件名会被 ellipsis 截断 ⇒ 精确 `find.text` 假阴。
  bool containing = false,
}) async {
  // `scrollUntilVisible` 在有多个 Scrollable 的页面会抛 `Too many elements`
  // （文件页里来源分页器也是 Scrollable）⇒ 直接对列表区域做竖直拖拽。
  //
  // ★ 第 92 轮 iOS 迁移：拖拽起点**不许写死坐标**。原来是 `Offset(400, 380)` ——
  //   那是 800x600 桌面窗口下的列表中部；iPhone 16 的逻辑宽度只有 **393**
  //   ⇒ x=400 **落在屏幕外**，`dragFrom` 什么都拖不动 ⇒ osheet/oslides/`Video`
  //   这些靠下的行在手机上永远"找不到"。现象看着像"iOS 放不了/打不开"，
  //   其实只是**探针几何写死了**（真根因）。
  //   改成按当前视图逻辑尺寸取"列表中部"，桌面（800x600）下与原来几乎重合。
  final view = tester.view;
  final logical = view.physicalSize / view.devicePixelRatio;
  // ★ r670（Windows 站真机）：宽屏文件站是**三栏**（来源树 / 条目列表 / 详情），
  //   竖直 Scrollable 不止一个 ⇒ 只在"正中"拖会拖到右详情栏，条目列表纹丝不动，
  //   表现成"`/home` 里找不到 `Video`"。改成**逐个纵向带**试（§2.0.70 ⑥ 的同型坑）。
  final bands = <double>[0.5, 0.32, 0.2, 0.68];
  bool found() => (containing ? find.textContaining(text) : find.text(text))
      .hitTestable()
      .evaluate()
      .isNotEmpty;
  for (final fx in bands) {
    for (var i = 0; i < 8 && !found(); i++) {
      await tester.dragFrom(
        Offset(logical.width * fx, logical.height * 0.6),
        const Offset(0, -220),
      );
      await _wait(tester, 300);
    }
    if (found()) break;
  }
  if (!found()) {
    for (var i = 0; i < maxScrolls && !found(); i++) {
      await tester.dragFrom(
        Offset(logical.width * 0.5, logical.height * 0.6),
        const Offset(0, -220),
      );
      await _wait(tester, 300);
    }
  }
  if (containing) {
    final f = find.textContaining(text).hitTestable();
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f.first, warnIfMissed: false);
      await _wait(tester, settle);
      return true;
    }
    return false;
  }
  return _tapText(tester, text, settle: settle);
}

/// 回到外壳首页：把所有推入的路由弹掉，并回到聊天空。
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
  if (container != null) {
    container.read(appTabProvider.notifier).select(AppTab.chat);
    await _wait(tester, 500);
  }
}

ProviderContainer? _container(WidgetTester tester) {
  final el = find.byType(SynologyChatApp);
  if (el.evaluate().isEmpty) return null;
  return ProviderScope.containerOf(tester.element(el.first), listen: false);
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
        ],
        child: const SynologyChatApp(),
      ),
    ),
  );
  await _wait(tester, 2500);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS 走查：启动 → 真 NAS 登录 → 八模块', (tester) async {
    final failures = <String>[];
    Future<void> step(String name, Future<void> Function() body) async {
      try {
        await body();
        // ★ 第 92 轮 iOS 迁移：把"布局溢出"归到**具体模块**上。
        //   原来溢出错误只在整轮结束、widget 已经 DISPOSED 之后才被打印 ⇒
        //   creator 链全是 `(DEFUNCT)`，**根本认不出是哪个页面**
        //   （iOS 首跑就抓到一条 `RenderFlex overflowed by 25 pixels`，
        //   靠消除法才定位）。每步结束立刻取异常，creator 链就是活的。
        //   这是**加强**守卫：以前溢出照样能"模块全绿"。
        final overflow = tester.takeException();
        if (overflow != null) {
          throw StateError('模块内有未处理异常（多为布局溢出）：$overflow');
        }
      } catch (e) {
        failures.add('$name: ${'$e'.split('\n').first}');
        _note('MODULE-FAIL $name: $e');
        await _resetToShell(tester);
      }
    }

    debugPrint('[walk] 截图目录 = ${_shotDir.path}');
    debugPrint('[walk] 目标 NAS = $_url  QC=$_qc  账号=$_account');

    // ============================================================ 启动
    await _boot(tester);
    await _shot(tester, '00_boot_setup');
    _note(
      '① 启动：连接页已渲染（key=srv-orb=${find.byType(EnergyOrb).evaluate().length}）',
    );

    final container = _container(tester)!;

    // 静默重登（restore）先跑完，否则连接按钮是禁用的
    await _waitFor(
      tester,
      'restore 结束',
      () => !container.read(sessionControllerProvider).restoring,
    );

    // ============================================================ ① 登录/QuickConnect
    await step('① 登录', () async {
      if (!_want('login')) return;
      if (container.read(sessionControllerProvider).loggedIn) {
        // 上一轮跑过 ⇒ 冷启动静默重登已经进了主页（这也是"登录可用"的一种形态）
        _note('① 静默重登（restore）直接进入主页，跳过手动登录 UI');
        await _wait(tester, 3000);
        await _shot(tester, '03_home_chat');
        return;
      }
      // 用真 UI：切到「直接地址」段（按图标找，避免语言相关文案）→ 填地址 → 点能量核
      final seg = find.byIcon(Icons.lan_outlined);
      if (seg.evaluate().isNotEmpty) {
        await tester.tap(seg.first, warnIfMissed: false);
        await _wait(tester, 400);
      } else {
        _note('① 未找到「直接地址」段图标，改用控制器直连');
      }
      final tf = find.byType(TextField);
      if (tf.evaluate().isNotEmpty) {
        await tester.enterText(tf.first, _url);
        await _wait(tester, 300);
      }
      // 首连信任：App 自己的 prompt 会弹真框（`_SynologyChatAppState.initState`
      // 把 `trust.prompt` 接到 `showCertificateTrustDialog`），这里抓图后点「信任」。
      var sawDialog = false;
      await _tapOrb(tester);
      // 握手 + 首连信任框（轮询真实时间；不能 pumpAndSettle）
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 80));
        if (find.byType(AlertDialog).evaluate().isNotEmpty) {
          sawDialog = true;
          break;
        }
        if (container.read(sessionControllerProvider).connection != null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      if (sawDialog) {
        await _shot(tester, '01_trust_dialog');
        final ok = find.byType(FilledButton);
        if (ok.evaluate().isNotEmpty) {
          await tester.tap(ok.last, warnIfMissed: false);
        }
        await _wait(tester, 1200);
      }
      await _waitFor(
        tester,
        '连接建立',
        () => container.read(sessionControllerProvider).connection != null,
        timeout: const Duration(seconds: 90),
      );
      final conn = container.read(sessionControllerProvider).connection!;
      _note(
        '① 连接成功：label=${conn.profile.label} '
        'trustDialog=$sawDialog',
      );
      expect(conn.profile.value, _url);

      // 登录页
      await _waitFor(
        tester,
        '进入登录页',
        () => find.byType(TextField).evaluate().length >= 2,
      );
      // ★ 进登录页后会先播一段 `SYSTEM BOOT` HUD（SELF-TEST/LINK/CRYPTO/HUD），
      //   它会盖住表单 ⇒ 等它演完，并把第一个输入框滚进视口再拍。
      await _wait(tester, 14000);
      final fields = find.byType(TextField);
      if (fields.evaluate().isNotEmpty) {
        try {
          await tester.ensureVisible(fields.first);
          await _wait(tester, 800);
        } catch (_) {}
      }
      await _shot(tester, '02_login_page');
      await tester.enterText(fields.at(0), _account);
      await tester.enterText(fields.at(1), _password);
      await _wait(tester, 400);
      await _tapOrb(tester);
      try {
        await _waitFor(
          tester,
          '登录成功进主页',
          () =>
              container.read(sessionControllerProvider).loggedIn &&
              _hasKey('app-shell-stack'),
          timeout: const Duration(seconds: 90),
        );
      } catch (_) {
        final e = container.read(sessionControllerProvider);
        _note(
          '① 登录失败诊断：error=${e.error} otp=${e.otpRequired} '
          'busy=${e.busy} connected=${e.connected}',
        );
        rethrow;
      }
      final st = container.read(sessionControllerProvider);
      _note(
        '① 登录成功：account=${st.session?.account} '
        'sid=${st.session!.sid.length}位 did=${st.session?.did != null} '
        'endpoint=${st.connection!.endpoint.source} '
        'certPinned=${st.connection!.certPinned}',
      );
      await _wait(tester, 4000); // 服务可用性探测 + 频道列表
      await _shot(tester, '03_home_chat');
    });

    // ============================================================ ④ Chat
    await step('④ Chat', () async {
      if (!_want('chat')) return;
      await _tapKey(tester, 'dock-chat', settle: 1200);
      await _wait(tester, 6000);
      final rows = find.byType(ChannelRow).hitTestable().evaluate().length;
      await _shot(tester, '04_chat');
      _dumpUi(tester, '④ Chat');
      _note(
        '④ Chat：频道列表行数=$rows '
        'hasSyncFailed=${_hasText('Sync failed') || _hasText('同步失败')}',
      );
      // ★ r670：旧断言盯的是"大写 CHANNELS"与"synobot 字样"，这两样在 UI 改版后
      //   已经不存在 ⇒ 假红（不是产品缺陷）。改钉**机制**：真的画出频道行、真的
      //   带回服务器给的数量。
      expect(rows, greaterThan(0), reason: '频道列表要真的列出频道行（不是只有组头）');
      expect(
        _hasAnyContaining(const ['channels', '个频道']),
        isTrue,
        reason: '要显示真实频道数（服务器回的）',
      );
      // DA294：状态行必须是**定高单行**，且每行频道卡高度一致（抖动的两条根因）
      final statusH = tester
          .getSize(find.byType(DebouncedStatusLine).first)
          .height;
      final rowHeights = {
        for (final e in find.byType(ChannelRow).hitTestable().evaluate())
          tester.getSize(find.byWidget(e.widget)).height,
      };
      _note('④ Chat：状态行高=$statusH 频道行高=$rowHeights');
      expect(rowHeights.length, 1, reason: '行高不一致 ⇒ 未读数一变就整列抖（DA294）');
      expect(
        statusH,
        inInclusiveRange(12, 24),
        reason: '状态行必须是"按字号算出来"的定高，不是被文案撑开（DA294）',
      );
    });

    // ============================================================ ② 文件浏览
    await step('② 文件', () async {
      if (!_want('files')) return;
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-files', settle: 1500);
      for (var i = 0; i < 8; i++) {
        if (_hasText('docker')) break;
        if (!await _tapKey(tester, 'file-up', settle: 1200)) break;
      }
      await _waitFor(
        tester,
        '文件根目录出现',
        () => _hasText('docker'),
        timeout: const Duration(seconds: 60),
      );
      await _wait(tester, 2500);
      await _shot(tester, '05_files_root');
      expect(_hasText('home'), isTrue, reason: 'NAS 根目录应有 home 共享');

      await _enterFolderInMaster(tester, 'home', settle: 2500);
      await _waitFor(
        tester,
        '/home 列表出现',
        () => _hasText('Drive') && _hasText('Music'),
        timeout: const Duration(seconds: 60),
      );
      await _wait(tester, 2500);
      await _shot(tester, '06_files_home');

      // ★ r673：宽屏右栏 = **信息窗格**（左栏唯一导航面）。这里把"选中一行的
      //   信息卡"也留一张像素证据：左栏该行必须亮起来，右栏给名字/类型/项数/路径
      //   与**唯一**的打开按钮。
      if (_hasKey('file-wide-master')) {
        final sel = find.descendant(
          of: find.byKey(const Key('file-wide-master')),
          matching: find.text('Download'),
        );
        if (sel.evaluate().isNotEmpty) {
          await tester.tap(sel.hitTestable().first, warnIfMissed: false);
          await _wait(tester, 1500);
          expect(
            _hasKey('file-wide-detail'),
            isTrue,
            reason: 'DA299：宽屏单击一行必须在右栏出信息卡',
          );
          expect(
            _hasKey('file-wide-open'),
            isTrue,
            reason: 'DA299：信息卡必须给一个显式的「打开」出口',
          );
          await _shot(tester, '06b_files_inspector');
          _note('② 文件：宽屏信息卡 —— 左栏选中行高亮 ＋ 右栏名字/类型/项数/路径 ＋「打开文件夹」');
        }
      }

      // ★ r670：`/home/Drive` 里的样本文件早已被清理，钉固定文件名 = 假红。
      //   改钉**行为**：能进去（面包屑出现 Drive）、能出来（`file-up` 回到 /home）。
      await _enterFolderInMaster(tester, 'Drive', settle: 2500);
      // DA291 的两套入口：窄屏是带字的「上一级」(`file-breadcrumb-up`)，
      // 宽屏是右栏头部**可点的路径段** (`file-wide-crumb-<i>`)。
      bool hasUp() =>
          _hasKey('file-breadcrumb-up') || _hasKey('file-wide-crumb-1');
      await _waitFor(
        tester,
        '进入 /home/Drive',
        hasUp,
        timeout: const Duration(seconds: 60),
      );
      await _wait(tester, 2000);
      await _shot(tester, '07_files_drive');
      expect(hasUp(), isTrue, reason: 'DA291：子目录里必须有回父目录的入口');
      final backOk = _hasKey('file-breadcrumb-up')
          ? await _tapKey(tester, 'file-breadcrumb-up', settle: 2500)
          : await _tapKey(tester, 'file-wide-crumb-0', settle: 2500);
      expect(backOk, isTrue, reason: 'DA291：「上一级/父路径段」必须点得动');
      await _waitFor(
        tester,
        '回到 /home',
        () => _hasText('Music') || _hasText('Download'),
        timeout: const Duration(seconds: 45),
      );
      await _shot(tester, '07b_files_back');
      _note('② 文件：/home → /home/Drive → 上一级，三跳都在像素上成立');
    });

    // ============================================================ ⑥ Office 阅读器
    await step('⑥ Office', () async {
      if (!_want('office')) return;
      // 阅读器 .odoc
      await _gotoMyDrive(tester);
      // ★ r671：宽屏详情卡（`DA297`）＋ 双击直接打开（`DA298`）真机判据
      await _assertWideDetailBackAndDoubleTap(
        tester,
        '5-day trip planner.odoc',
      );
      await _gotoMyDrive(tester);
      // 用**当前真实样本**（`tool/nas_mydrive_state.dart` 只读列过 /mydrive）。
      await _openInWidePane(tester, '5-day trip planner.odoc');
      await _wait(tester, 20000);
      await _shot(tester, '08_office_odoc');
      _dumpUi(tester, '⑥ odoc');
      expect(
        _hasKey('office-doc-view'),
        isTrue,
        reason: 'odoc 阅读器应出正文视图（不是 loading/failure）',
      );
      _note('⑥ Office：5-day trip planner.odoc 在阅读器里出正文');

      // 阅读器 .osheet
      await _gotoMyDrive(tester);
      await _openInWidePane(tester, 'Annual income and expenditure.osheet');
      await _wait(tester, 20000);
      await _shot(tester, '09_office_osheet');
      _dumpUi(tester, '⑥ osheet');
      expect(_hasKey('office-sheet-page'), isTrue, reason: 'osheet 阅读器应出页');

      // 阅读器 .oslides
      await _gotoMyDrive(tester);
      await _openInWidePane(tester, 'Celestial.oslides');
      await _wait(tester, 20000);
      await _shot(tester, '10_office_oslides');
      _dumpUi(tester, '⑥ oslides');
      expect(_hasKey('office-slides-page'), isTrue, reason: 'oslides 阅读器应出页');
    });

    // ============================================================ ⑤ 相册
    await step('⑤ 相册', () async {
      if (!_want('photos')) return;
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-photos', settle: 1500);
      await _wait(tester, 12000);
      await _shot(tester, '11_photos');
      final imgs = find.byType(Image).evaluate().length;
      _dumpUi(tester, '⑤ 相册');
      _note('⑤ 相册：Image 组件数=$imgs');
      expect(
        _hasAnyText(const ['Timeline', '时间轴', '时间线']),
        isTrue,
        reason: '相册时间线要画出来',
      );
      expect(imgs > 0, isTrue, reason: '时间线里要真有图片组件');
    });

    // ============================================================ ③ 笔记
    await step('③ 笔记', () async {
      if (!_want('notes')) return;
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-workspace', settle: 1500);
      await _shot(tester, '12_workspace');
      var opened = await _tapKey(tester, 'ws-tile-notes', settle: 2500);
      if (!opened) {
        _note('③ 工作台里没找到笔记磁贴，改用根导航直接推真实页面');
        rootNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const NotesPage()),
        );
        await _wait(tester, 2500);
      }
      await _wait(tester, 10000);
      await _shot(tester, '13_notes');
      _dumpUi(tester, '③ 笔记');
      // 笔记本名后面带**条数**（"My notebook 6"），会随真实数据变
      // ⇒ 只钉"笔记本名在"，不钉条数。
      expect(
        _hasAnyContaining(const ['My notebook', '记事本']),
        isTrue,
        reason: '要列出真实笔记本（NoteStation 真数据）',
      );
      _note('③ 笔记：笔记本列表已渲染，且含真实笔记本名');
    });

    // ============================================================ ⑦ 音视频播放
    await step('⑦ 音视频', () async {
      if (!_want('media')) return;
      // 音频：Audio Station 页
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-workspace', settle: 1200);
      var opened = await _tapKey(tester, 'ws-tile-audio', settle: 2500);
      if (!opened) {
        _note('⑦ 工作台里没找到 Audio 磁贴，改用根导航直接推真实页面');
        rootNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const AudioPage()),
        );
        await _wait(tester, 2500);
      }
      await _wait(tester, 12000);
      await _shot(tester, '14_audio');
      _dumpUi(tester, '⑦ Audio Station');
      expect(_hasText('Demo Song'), isTrue, reason: 'Audio Station 首页要列出真实歌曲');

      // 真点一首歌：证"能不能放"，而不只是"列表画出来了"。
      // 只读（对音频流发 HTTP GET），零变更动词。
      final song = find.text('Demo Song').hitTestable();
      if (song.evaluate().isNotEmpty) {
        await tester.tap(song.first, warnIfMissed: false);
        await _wait(tester, 15000);
        await _shot(tester, '14b_audio_play');
        _dumpUi(tester, '⑦ 点歌之后');
        // 再点一次「播放」，看音频流在 macOS 上到底能不能真的出声/走动。
        final play = find.byIcon(Icons.play_arrow).hitTestable();
        if (play.evaluate().isNotEmpty) {
          await tester.tap(play.first, warnIfMissed: false);
          await _wait(tester, 12000);
          await _shot(tester, '14c_audio_playing');
          _dumpUi(tester, '⑦ 点播放之后');
          // ★ 本轮修的真实缺陷：音频失败说明句过去复用了**视频**文案
          //   （"Download the video before watching"）。修完必须是中性那句。
          expect(
            _hasTextContaining('Download the video before watching'),
            isFalse,
            reason: '音频不该出现"下载视频"的说法',
          );
          // ★ r87：音频"能放"的判据是**位置真的在前进**，不是"进度条画出来了"。
          // 取两次 `as-progress` 滑块的 value（数值，不是布局断言）：第二次必须
          // 严格大于第一次，否则就是"看着像在播、实际没出声也没走"。
          // ★ r670（Windows 站真机）：`createDefaultAudioStationPlayer()`
          //   在 Windows/Linux 上**故意**走 `UnsupportedAudioStationPlayer`
          //   （`docs/platform-windows.md` §16.2：宿主没有本地播放实现），
          //   页面如实显示"播放失败" ⇒ 这不是缺陷，是平台边界。
          //   所以"进度必须前进"只在**有本地播放实现**的平台上成立。
          final platformUnsupported = _hasAnyContaining(const [
            '播放失败',
            'Playback failed',
            '不支持',
          ]);
          if (platformUnsupported) {
            _note('⑦ 音频：本平台无本地播放实现（如实显示"播放失败"）— 平台边界，非缺陷');
          }
          final slider = find.byKey(const Key('as-progress')).hitTestable();
          if (slider.evaluate().isNotEmpty) {
            final v1 = tester.widget<Slider>(slider.first).value;
            await _wait(tester, 6000);
            final v2 = tester.widget<Slider>(slider.first).value;
            _note('⑦ 音频进度：${v1.round()}ms → ${v2.round()}ms');
            if (!platformUnsupported) {
              expect(v2, greaterThan(v1), reason: '音频位置必须真的前进（macOS 自研桥能放）');
            }
          } else {
            _note('⑦ 没找到 as-progress 滑块（位置判据缺失，如实记录）');
          }
        } else {
          _note('⑦ 歌曲页没有可见的播放键');
        }
      } else {
        _note('⑦ 没找到可点的歌曲行（Audio Station 首页为空？）');
      }

      // 视频：文件 → home → Video → 点一个 mp4
      // ★ r717：判据原来用整条长文件名（`01_1._The_Rate_of_Chemical_…mp4`），
      //   真 NAS 上这行**被 ellipsis 截断** ⇒ `_hasTextContaining` 回假，
      //   整模块报 `Expected: true`（看着像"进不去 Video"，其实已经进去了）。
      //   ⇒ 用**短且唯一**的片段当可见判据；下面的打开动作同理。
      await _gotoHomeSub(
        tester,
        'Video',
        expectAfter: 'Citizen Kane',
      );
      await _shot(tester, '15_video_list');
      // ★ r670：宽屏是「左选右开」—— 点行只是选中，要再按右栏 `file-wide-open`
      //   才真的打开（同 Office 的 `_openInWidePane`；原来直接点行 ⇒ Windows
      //   站在这里 `Expected: true` 卡住）。
      await _openInWidePane(tester, 'Citizen Kane');
      await _wait(tester, 12000);
      await _shot(tester, '16_video_play');
      _dumpUi(tester, '⑦ 视频预览');
      // ★ r87：视频"能放"的判据是**没有落到回退面板**（回退文案出现即视为
      // 不能内置播）。像素证据是同帧的 `16_video_play.png`（真帧）。
      // ★ r670：Windows/Linux 宿主没有本地视频实现（同 §16.2 的边界）⇒
      //   如实显示失败/交给系统播放器是**正确行为**，不是缺陷。
      final videoUnsupported = _hasAnyContaining(const [
        '播放失败',
        'Playback failed',
        '不支持',
        'system player',
      ]);
      if (videoUnsupported) {
        _note('⑦ 视频：本平台无内置播放实现（如实回退）— 平台边界，非缺陷');
      } else {
        expect(
          _hasTextContaining('Playback failed'),
          isFalse,
          reason: '视频必须内置播放出真帧，不能是"播放失败"回退面板',
        );
        expect(
          _hasTextContaining('system player'),
          isFalse,
          reason: '视频不该提示"交给系统播放器"',
        );
      }
      _note('⑦ 音视频：Audio Station 页 + 文件里的 mp4 预览页都已打开（均内置播放）');
    });

    // ============================================================ ⑧ 下载
    await step('⑧ 下载', () async {
      if (!_want('download')) return;
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-workspace', settle: 1500);
      var opened = await _tapKey(tester, 'ws-tile-downloads', settle: 2500);
      if (!opened) {
        _note('⑧ 工作台里没找到下载磁贴，改用根导航直接推真实页面');
        rootNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const DownloadPage()),
        );
        await _wait(tester, 2500);
      }
      await _wait(tester, 12000);
      await _shot(tester, '17_downloads');
      _dumpUi(tester, '⑧ 下载');
      // 队列为空时"新建任务"是**空态按钮**，FAB 按 D9 故意不摆
      //（同一个入口不给两份表示）⇒ 两条判据二选一。
      expect(
        _hasKey('ds-add-task') || _hasAnyContaining(const ['New task', '新建任务']),
        isTrue,
        reason: 'Download Station 要给出"新建任务"入口（空态按钮或 FAB）',
      );
      _note('⑧ 下载：Download Station 页已渲染（本账号队列为空）');
    });

    // ====================================== ⑨ 桌面五项（r670：DA290–DA295）
    //   ★ 这一节是**用户手测报回来的五条**（r668 §2.0.71）在真 macOS 上的
    //     复验位：每一条都钉"机制"，不钉文案。
    await step('⑨ 桌面五项', () async {
      if (!_want('desk5')) return;
      await _resetToShell(tester);

      // ---- DA292：工作台磁贴宽度必须跟窗口走（写死 2 列会把宽屏撑爆）
      await _tapKey(tester, 'dock-workspace', settle: 1800);
      final tileFinder = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('ws-tile-'),
      );
      // 工作台磁贴要等能力画像/用量回来才画 ⇒ 等它出现（不是"立刻有")。
      await _waitFor(
        tester,
        '工作台磁贴出现',
        () => tileFinder.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 40),
      );
      await _wait(tester, 2000);
      await _shot(tester, '18_workspace_wide');
      final tiles = tileFinder.evaluate().toList();
      final widths = <double>[
        for (final e in tiles) tester.getSize(find.byWidget(e.widget)).width,
      ];
      final maxW = widths.isEmpty
          ? 0.0
          : widths.reduce((a, b) => a > b ? a : b);
      final winW =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      _note(
        '⑨ DA292 工作台：磁贴=${tiles.length} 最宽=${maxW.toStringAsFixed(1)}dp '
        '窗口=${winW.toStringAsFixed(1)}dp',
      );
      expect(tiles, isNotEmpty, reason: '工作台要真的画出磁贴');
      // DA292 的机制是**给磁贴宽度封顶**（列数跟宽度走）⇒ 任何窗口宽下
      // 单格都不许超过 420dp；窗口够宽时还必须真的排到 3 列以上。
      expect(
        maxW,
        lessThanOrEqualTo(420.0),
        reason: 'DA292：磁贴宽度必须封顶（列数写死时宽屏一格半屏）',
      );
      expect(
        winW / maxW,
        greaterThanOrEqualTo(1.8),
        reason: 'DA292：一行至少要排得下两格（winW/格宽 ≥ 1.8）',
      );

      // ---- DA293：桌面没有相机实现 ⇒ 不许摆"拍照"（假控件比没控件更坏）
      expect(kCameraCaptureSupported, isFalse, reason: 'DA293：macOS 不该声称支持拍照');
      await _tapKey(tester, 'dock-me', settle: 1800);
      await _wait(tester, 2000);
      await _shot(tester, '19_me');
      // "资料"卡片的文案随 locale 变（zh=个人资料 / en=Profile），两个都试
      String? meProfile;
      for (final t in const ['个人资料', 'Profile']) {
        if (_hasText(t)) {
          meProfile = t;
          break;
        }
      }
      if (meProfile != null) {
        await _tapText(tester, meProfile, settle: 2500);
        await _wait(tester, 2500);
        await _shot(tester, '20_profile_edit');
        final hasCamera = _hasText('拍照') || _hasText('Take photo');
        expect(hasCamera, isFalse, reason: 'DA293：桌面没有相机就不许摆"拍照"按钮');
        _note('⑨ DA293 资料编辑页已打开，未见拍照入口（kCameraCaptureSupported=false）');
      } else {
        _note('⑨ DA293 未找到"资料"入口文案，跳过点击（能力位断言已过）');
      }

      // ---- DA295：凭据落在 App 沙箱的文件里（不再问钥匙串）
      //   ★ 这条只对 **macOS 档**成立（Windows/Linux 的落盘位置与权限模型
      //     不同，见 `docs/platform-windows.md`）；非 macOS 站如实记一句跳过。
      if (!Platform.isMacOS) {
        _note(
          '⑨ DA295 跳过：非 macOS 档（Windows 凭据落 %APPDATA%，见 platform-windows.md）',
        );
      } else {
        final home = Platform.environment['HOME'] ?? '';
        final cred = File(
          '$home/Library/Application Support/synhub/debug_secrets.json',
        );
        final exists = cred.existsSync();
        final mode = exists ? (cred.statSync().mode & 0x1FF) : -1;
        _note('⑨ DA295 凭据文件 exists=$exists mode=${mode.toRadixString(8)}');
        expect(exists, isTrue, reason: 'DA295：macOS 档凭据必须落沙箱文件（不许走钥匙串）');
        expect(mode, 0x180, reason: 'DA295：凭据文件必须是 0600（外层容器 0700 兜底）');
      }

      // ---- DA294：聊天页状态行定高、行高一致（相位变化不许改布局）
      //   资料编辑页是**推上去的整页**（底栏被盖住）⇒ 先回外壳再切页
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-chat', settle: 1500);
      await _wait(tester, 2500);
      await _shot(tester, '21_chat_desk5');
      final statusH = tester
          .getSize(find.byType(DebouncedStatusLine).first)
          .height;
      final rowH = <double>{
        for (final e in find.byType(ChannelRow).hitTestable().evaluate())
          tester.getSize(find.byWidget(e.widget)).height,
      };
      _note('⑨ DA294 状态行高=$statusH 行高集合=$rowH');
      expect(rowH.length, 1, reason: 'DA294：行高不一致 ⇒ 未读一变整列抖');
      expect(
        statusH,
        inInclusiveRange(12, 24),
        reason: 'DA294：状态行是按字号算的定高，不是被文案撑开',
      );
    });

    await _resetToShell(tester);

    // ------------------------------------------------------------ 汇总
    debugPrint('\n===== 走查汇总 =====');
    for (final r in _report) {
      if (r.startsWith('SHOT') || r.startsWith('MODULE-FAIL')) {
        debugPrint(r);
      }
    }
    _note('失败模块数 = ${failures.length}');
    for (final f in failures) {
      debugPrint('[walk] FAIL $f');
    }
    expect(failures, isEmpty, reason: '有模块没走通：$failures');
  });
}
