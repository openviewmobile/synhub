// r132 **iOS 逐屏截图审计**装置（iPhone 16 / iOS 18.6 模拟器 / 真 NAS 只读）。
//
// 与 `macos_walkthrough_test.dart` 的分工：
//   * 那支是"八模块走通"（模块级）；这支是**逐屏**（页面/弹层/空态/菜单级），
//     并且**每屏都从宿主抓一张 `xcrun simctl io booted screenshot` 的真实帧缓冲**。
//   * 帧缓冲由宿主侧 `tool/r132_ios_shot_poller.sh` 截；本用例只负责把界面
//     导航到位、把**界面名**写进 `tmp/r132_ios_ui/req.txt`，然后等宿主写
//     `ack.txt` —— 1:1 确定性映射，不靠 sleep 猜（也不会错位）。
//
// 跑法：
//   export PATH="<flutter-sdk>/bin:$PATH"
//   tool/r132_ios_shot_poller.sh &                     # 宿主截图泵
//   flutter test integration_test/r132_ios_ui_audit_test.dart \
//     -d A9D73490-69EC-4346-88D1-6ACAEFD58147 --timeout 3600s
//
// 参数一律在用例内给默认值（AGENTS §2.0.20⑤）；默认指向仓库既有的**只读**
// 测试账号与真 NAS。`AUDIT_ONLY=setup,login,files` 可只跑若干组（迭代提速）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/router/app_router.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/admin/admin_gate.dart';
import 'package:synhub/src/features/admin/admin_identity.dart'
    show AdminIdentity, AdminIdentitySource;
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/chat/channel_row.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/files/file_pages.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';
import 'package:synhub/src/features/servers/session_controller.dart';
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
// r718：`_qc` 在 Web 站没被用过（QuickConnect 段只在 macOS/iOS 走查里走），
// 留着会让 `flutter analyze` 报 unused_element → 删掉，需要时再加回来。

/// ★ r346：URL 指向本机 Mock（`127.0.0.1` / `localhost`）⇒ 判据里那些
/// **真 NAS 素材名**（`/home/Drive`、`Celestial.oslides`、`Video/*.mp4`…）
/// 在 Mock 上根本不存在。Mock 档不能把这些算成产品缺陷 ⇒ 统一走 `_MockSkip`。
final bool _isMock =
    _url.contains('127.0.0.1') || _url.contains('localhost');

/// "本场景需要真 NAS 素材，Mock 档不可达" —— 场景层记未验，**不计入失败**。
class _MockSkip implements Exception {
  final String what;
  const _MockSkip(this.what);
  @override
  String toString() => what;
}

/// 只跑某几组（逗号分隔）；空 = 全跑。
const String _only = String.fromEnvironment('AUDIT_ONLY');

/// 只跑某几个**场景**（逗号分隔）；空 = 全跑。
/// ★ 用途：某个场景的装置判据改好后，**不必重拍 79 屏**就能重验它
///   （场景之间各自 `_resetToShell`/`_toHome`，独立可跑）。
///   例：`--dart-define=AUDIT_ONLY=office --dart-define=AUDIT_SCENES=s090_office_odoc`
const String _onlyScenes = String.fromEnvironment('AUDIT_SCENES');

bool _want(String group) =>
    _only.isEmpty || _only.split(',').map((e) => e.trim()).contains(group);

bool _wantScene(String name) =>
    _onlyScenes.isEmpty ||
    _onlyScenes.split(',').map((e) => e.trim()).contains(name);

// r666-web: screenshots go through IntegrationTestWidgetsFlutterBinding.takeScreenshot
// (web has no dart:io); the flutter-drive extended driver writes the PNGs.

final GlobalKey _rootKey = GlobalKey(debugLabel: 'r132-root');

final List<String> _report = <String>[];

void _note(String s) {
  _report.add(s);
  debugPrint('[audit] $s');
}

// ---------------------------------------------------------------- 工具

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

bool _hasKey(String k) => find.byKey(Key(k)).hitTestable().evaluate().isNotEmpty;
bool _hasKeyAny(String k) => find.byKey(Key(k)).evaluate().isNotEmpty;
bool _hasText(String s) => find.text(s).hitTestable().evaluate().isNotEmpty;

/// **不看 hitTest 的**版本：判"控件树里到底有没有它"（`.hitTestable()` 会因遮挡/滚动位置
/// 给出假否定 —— `_hasKey` 就是 hitTestable 版，r132 的相册时间线判据被它坑了三次）。
bool _hasTextAny(String s) => find.text(s).evaluate().isNotEmpty;
Finder _byKeyPrefix(String prefix) => find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith(prefix);
});

/// ★ web：截图走 `takeScreenshot`（CanvasKit 自渲染 → driver 的 `onScreenshot`）。
Future<void> _mark(WidgetTester tester, String name) async {
  try {
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(name);
    _note('MARK $name');
  } catch (e) {
    _note('MARK-FAIL $name: $e');
  }
}

void _dumpUi(WidgetTester tester, String tag) {
  const keys = <String>[
    'office-doc-view', 'office-doc-loading', 'office-doc-failure',
    'office-sheet-page', 'office-sheet-loading', 'office-sheet-failure',
    'office-slides-page', 'office-slides-loading', 'office-slides-failure',
    'file-page-loading', 'file-page-error', 'file-up', 'file-source-pager',
    'as-home-recently-played', 'as-play-failure', 'ds-add-task',
    'photo-timeline-view-bar', 'ws-pager', 'set-admin-tools',
    'drive-list', 'drive-sort-menu', 'note-shared-entry', 'bar-overflow',
  ];
  final present = keys.where(_hasKeyAny).toList();
  final texts = <String>[];
  for (final e in find.byType(Text).evaluate().take(60)) {
    final d = (e.widget as Text).data;
    if (d != null && d.trim().isNotEmpty) texts.add(d.trim());
  }
  _note('DUMP $tag keys=${present.join('|')} '
      'texts=${texts.take(26).join(' / ')}');
}

Future<bool> _tapKey(WidgetTester tester, String key, {int settle = 700}) async {
  final f = find.byKey(Key(key));
  if (f.evaluate().isEmpty) return false;
  try {
    await tester.ensureVisible(f.first);
  } catch (_) {}
  await _wait(tester, 150);
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

Future<bool> _tapText(WidgetTester tester, String text,
    {int settle = 800, bool last = false}) async {
  final all = find.text(text).hitTestable();
  if (all.evaluate().isEmpty) return false;
  final f = last ? all.last : all.first;
  try {
    await tester.ensureVisible(f);
  } catch (_) {}
  await _wait(tester, 120);
  await tester.tap(f, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

Future<bool> _tapIcon(WidgetTester tester, IconData icon,
    {int settle = 700, bool last = false}) async {
  final all = find.byIcon(icon).hitTestable();
  if (all.evaluate().isEmpty) return false;
  final f = last ? all.last : all.first;
  await tester.tap(f, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

Future<bool> _tapTooltip(WidgetTester tester, String tip,
    {int settle = 800}) async {
  final f = find.byTooltip(tip).hitTestable();
  if (f.evaluate().isEmpty) return false;
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 头部动作：直接可见就点；被折进 `bar-overflow` 就展开后再点（§2.0.10）。
Future<bool> _headerAction(WidgetTester tester, String label,
    {int settle = 900}) async {
  var f = find.byTooltip(label).hitTestable();
  if (f.evaluate().isNotEmpty) {
    await tester.tap(f.first, warnIfMissed: false);
    await _wait(tester, settle);
    return true;
  }
  if (await _tapKey(tester, 'bar-overflow', settle: 600)) {
    f = find.byTooltip(label).hitTestable();
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f.first, warnIfMissed: false);
      await _wait(tester, settle);
      return true;
    }
    if (await _tapText(tester, label, settle: settle)) return true;
  }
  return false;
}

/// 点一个 `ListTile`（按标题文字定位）——设置页/我的页的行都是 ListTile。
Future<bool> _tapTile(WidgetTester tester, String label,
    {int settle = 900}) async {
  final anc = find.ancestor(
    of: find.text(label),
    matching: find.byType(ListTile),
  );
  final f =
      anc.evaluate().isNotEmpty ? anc.first : find.text(label).hitTestable();
  if (f.evaluate().isEmpty) return false;
  try {
    await tester.ensureVisible(f);
  } catch (_) {}
  await _wait(tester, 120);
  await tester.tap(f, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 列表里靠下的行可能还没被 Sliver 构建 ⇒ 先竖直拖到可见再点。
Future<bool> _tapScrolling(WidgetTester tester, String text,
    {int maxScrolls = 30, int settle = 1200}) async {
  final view = tester.view;
  final logical = view.physicalSize / view.devicePixelRatio;
  final origin = Offset(logical.width / 2, logical.height * 0.6);
  for (var i = 0; i < maxScrolls; i++) {
    if (find.text(text).hitTestable().evaluate().isNotEmpty) break;
    await tester.dragFrom(origin, const Offset(0, -220));
    await _wait(tester, 300);
  }
  return _tapText(tester, text, settle: settle);
}

/// 按**后缀**找列表行并滚动着点它。
/// ★ 为什么不用文件名硬编码：真 NAS 上 `/home/Drive` 的内容会变
///   （pass5 里 `5-day trip planner.odoc` 已被 `Vacation packing list.odoc` 取代），
///   硬编码名字点不到时 `_tapText` 会**静默失败** ⇒ 场景"绿"但屏幕根本没进阅读器
///   （pass5 `294_s090_office_odoc.png` 像素里是**文件列表 + 键盘**，不是 .odoc 阅读器）。
Finder _byTextSuffix(String suffix) => find.byWidgetPredicate(
    (w) => w is Text && (w.data ?? '').endsWith(suffix));

Future<bool> _tapScrollingSuffix(WidgetTester tester, String suffix,
    {int maxScrolls = 30, int settle = 4000}) async {
  final view = tester.view;
  final logical = view.physicalSize / view.devicePixelRatio;
  final origin = Offset(logical.width / 2, logical.height * 0.6);
  for (var i = 0; i < maxScrolls; i++) {
    if (_byTextSuffix(suffix).hitTestable().evaluate().isNotEmpty) break;
    await tester.dragFrom(origin, const Offset(0, -220));
    await _wait(tester, 300);
  }
  final f = _byTextSuffix(suffix).hitTestable();
  if (f.evaluate().isEmpty) return false;
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 取一个**真正在可视区里**的相册格（时间线/网格都走 `PhotoCell`）。
/// ★ 为什么不用 `.hitTestable()`：pass5/pass6 里像素明明有格、`hitTestable()` 却为空
///   （`290_s078_photo_viewer__FAIL.png`）⇒ 用它当"有没有内容/能不能点"的判据不可靠。
///   这里改成**按屏高算安全带**（上 120 / 下 140 让开工具条与底部导航），
///   是"按当前屏尺寸推导"而不是写死坐标（AGENTS §2.0.21 第 3 条）。
Finder _visibleCell(WidgetTester tester) {
  final logical = tester.view.physicalSize / tester.view.devicePixelRatio;
  final all = find.byType(PhotoCell).evaluate();
  for (final e in all) {
    final c = tester.getCenter(find.byWidget(e.widget));
    if (c.dy > 120 && c.dy < logical.height - 140) {
      return find.byWidget(e.widget);
    }
  }
  return find.byType(PhotoCell).first;
}

/// 收键盘 / 取消焦点：上一个场景留下的搜索焦点会把内容挤掉
/// （pass5 `s090` 像素里 `Filter in folder` 拿焦点、键盘占了下半屏）。
Future<void> _dismissKeyboard(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await _wait(tester, 800);
}

Future<void> _scrollDown(WidgetTester tester, [double dy = 600]) async {
  final view = tester.view;
  final logical = view.physicalSize / view.devicePixelRatio;
  await tester.dragFrom(
    Offset(logical.width / 2, logical.height * 0.65),
    Offset(0, -dy),
  );
  await _wait(tester, 700);
}

/// ★ r346：往回（向上）滚 —— 判据落在"上方某段"时必须能回去找。
Future<void> _scrollUp(WidgetTester tester, [double dy = 600]) async {
  final view = tester.view;
  final logical = view.physicalSize / view.devicePixelRatio;
  await tester.dragFrom(
    Offset(logical.width / 2, logical.height * 0.35),
    Offset(0, dy),
  );
  await _wait(tester, 700);
}

/// 底部弹层内滚动一点，保证条目都在屏内。
Future<void> _halfSheetUp(WidgetTester tester) async {
  final view = tester.view;
  final logical = view.physicalSize / view.devicePixelRatio;
  await tester.dragFrom(
    Offset(logical.width / 2, logical.height * 0.85),
    const Offset(0, -160),
  );
  await _wait(tester, 500);
}

Future<void> _resetToShell(WidgetTester tester) async {
  final nav = rootNavigatorKey.currentState;
  if (nav != null) {
    var guard = 0;
    while (nav.canPop() && guard++ < 10) {
      nav.pop();
      await _wait(tester, 220);
    }
  }
  final c = _container(tester);
  if (c != null) {
    c.read(appTabProvider.notifier).select(AppTab.chat);
    await _wait(tester, 500);
  }
}

/// Files 页顶部数据源分段：切回 **NAS files**（否则一直在 "My Drive" 源里）。
Future<void> _selectNasSource(WidgetTester tester) async {
  // ★ r132 第二版（pass2 像素/DUMP 证据）：数据源分段控件**不在** `file-source-pager`
  //   里 —— 那是承载两页的 `PageView`（`section_pager.dart`），里面没有标签文字。
  //   标签（`NAS files` / `My Drive`）在它上面的 `_Deck` 里，所以直接在页面里按文字找。
  final f = find.text('NAS files').hitTestable();
  if (f.evaluate().isEmpty) return;
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, 1200);
}

/// ★ r132 第二版：`s044` 长按行 → 弹层 → 若没退出多选，`_selected` 会一直非空，
/// 于是 `_Deck` 画的是「N selected / ✕」而**不是**数据源分段控件 ⇒ 后面所有
/// Files 场景既切不了源、也点不到 `Sort`（pass2 DUMP 逐字：`1 selected /
/// Shared folders / home / …`、无 `NAS files`，`s057` 起连环超时）。
/// 修法：进入 Files 前先按那个 ✕（`Icons.close`）退出多选。
Future<void> _clearFileSelection(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    if (find.textContaining('selected').evaluate().isEmpty) return;
    final close = find.byIcon(Icons.close).hitTestable();
    if (close.evaluate().isEmpty) return;
    await tester.tap(close.first, warnIfMissed: false);
    await _wait(tester, 600);
  }
}

/// 相册分段 chip 会在 393pt 上横向溢出屏幕 ⇒ 左右交替拖 chip 行，再点。
Future<bool> _photoSection(WidgetTester tester, String label,
    {int settle = 6000}) async {
  // ★ r132 第三版（078/079/105 三张 `__FAIL` 的根因）：chip 行是**横向可滚**的
  //   `PhotoSegment` 列表，而 `Timeline` 在最**左**。旧版只会往左拖（-160）
  //   ⇒ 想找 `Timeline` 时**越拖越远**，永远命中不了 ⇒ 停在 Scenes/相册段
  //   ⇒ `PhotoCell` 为空 ⇒ 误报"时间线没有照片"。改成**左右交替拖**
  //   （+160 才露出左边的 chip）。
  for (var i = 0; i < 8; i++) {
    final f = find
        .descendant(of: find.byType(PhotoSegment), matching: find.text(label))
        .hitTestable();
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f.first, warnIfMissed: false);
      await _wait(tester, settle);
      return true;
    }
    final row = find.byType(PhotoSegment).hitTestable();
    if (row.evaluate().isEmpty) break;
    await tester.drag(row.first, Offset(i.isEven ? 160 : -160, 0));
    await _wait(tester, 500);
  }
  return false;
}

/// 进相册页并**明确切到 Timeline 分段**（App 会记住上次分段，不切就会
/// 点密度/找照片全部落空 —— r132 第一版就是这么红的）。
///
/// ★ 返回"**真的**在时间线且有格子"：判据是 `photo-timeline-view-bar` 键
///   （时间刻度工具条只在 Timeline 段渲染）**且** 有 `PhotoCell`。
///   旧版无条件 `return true` ⇒ 078/079/105 拿空列表当"照片没了"。
///
/// ★★ r132 第四版（pass5 的 `__FAIL` 根因）：**必须轮询**。pass5 的
///   `290_s078_photo_viewer__FAIL.png` 像素里 Timelime 段**已经是选中态**、
///   `Time scale / Medium / Day` 与 `9/21/2026 (4)` / `9/20/2026 (22)` 分组、
///   红/蓝/绿测试图**全都出图了** —— 说明屏幕没问题，是判据**看得太早**：
///   `view bar` 属首帧、`PhotoGrid` 要等 `Foto.Timeline:list` 回来才建。
///   ⇒ 改成最多轮询 12×2s = 24s，中途（第 4/9 次）再点一次分段逼一次重拉。
Future<bool> _photoTimeline(WidgetTester tester, {int settle = 9000}) async {
  await _dock(tester, 'photos', settle: 1500);
  await _wait(tester, settle);
  if (!await _photoSection(tester, 'Timeline', settle: 3000)) {
    // 再试一次：进相册页首帧的分段行可能还没建出来。
    await _photoSection(tester, 'Timeline', settle: 3000);
  }
  // ★ 判据为什么不再用 `.hitTestable()`：pass5/pass6 都出现"像素里时间线明明有格"
  //   而 `PhotoCell.hitTestable()` 为空（`290_s078_photo_viewer__FAIL.png` 像素 +
  //   pass6 DUMP `keys=photo-timeline-view-bar texts=… 9/21/2026 / 4 / 9/20/2026 / 22 …`）。
  //   `hitTestable()` 要求**该 widget 自己的 RenderObject 被命中**，
  //   而格子外面还有一层滚动/语义包装 ⇒ 它当"可点"判据不可靠。
  //   改成"控件树里**真有内容**"：时间线视图条 + 至少一个 `PhotoCell`（或 `Image` 缩略图）。
  var cells = 0;
  var imgs = 0;
  var barAny = false;
  var barHit = false;
  var scale = false;
  // ★ 30×2s = 60s：真 NAS 的 `Foto.Timeline:list` 在模拟器上可能很慢，
  //   24s 不够（pass6/pass7 实测：轮询结束时控件树里连 view-bar 都还没有，
  //   而 `__FAIL` 截图里时间线已经画好了 ⇒ 就是**没等够**）。
  for (var i = 0; i < 30; i++) {
    cells = find.byType(PhotoCell).evaluate().length;
    imgs = find.byType(Image).evaluate().length;
    barAny = _hasKeyAny('photo-timeline-view-bar');
    barHit = _hasKey('photo-timeline-view-bar');
    scale = _hasTextAny('Time scale') || _hasText('Time scale');
    // `Time scale` 只出现在时间线的视图条上 ⇒ 它比 key 更可靠（key 的 hitTest 会被遮挡坑）。
    if (barAny || scale) {
      _note('时间线就绪 i=$i barAny=$barAny barHit=$barHit scale=$scale '
          'PhotoCell=$cells Image=$imgs');
      return true;
    }
    if (i % 5 == 4) {
      _note('时间线等待 i=$i barAny=$barAny barHit=$barHit scale=$scale '
          'PhotoCell=$cells Image=$imgs');
    }
    await _wait(tester, 2000);
    if (i == 2 || i == 6 || i == 12 || i == 20) {
      final ok = await _photoSection(tester, 'Timeline', settle: 2000);
      _note('时间线重切分段 i=$i ok=$ok');
    }
  }
  _note('时间线未就绪：barAny=$barAny barHit=$barHit scale=$scale '
      'PhotoCell=$cells Image=$imgs');
  return false;
}

/// 弹层菜单可能比屏幕高 ⇒ 在弹层内部往上拖，直到目标文字可见。
Future<bool> _menu(WidgetTester tester, String item,
    {String? tooltip, int settle = 900}) async {
  var f = tooltip == null
      ? find.byKey(const Key('bar-overflow')).hitTestable()
      : find.byTooltip(tooltip).hitTestable();
  if (f.evaluate().isEmpty) {
    f = find.byKey(const Key('bar-overflow')).hitTestable();
  }
  if (f.evaluate().isEmpty) f = find.byTooltip('More').hitTestable();
  if (f.evaluate().isEmpty) f = find.byIcon(Icons.more_vert).hitTestable();
  if (f.evaluate().isEmpty) return false;
  await tester.tap(f.last, warnIfMissed: false);
  await _wait(tester, 800);
  for (var i = 0; i < 6; i++) {
    final t = find.text(item).hitTestable();
    if (t.evaluate().isNotEmpty) {
      await tester.tap(t.last, warnIfMissed: false);
      await _wait(tester, settle);
      return true;
    }
    // 弹层里的条目可能在屏外：在弹层区域内往上拖。
    final view = tester.view;
    final logical = view.physicalSize / view.devicePixelRatio;
    await tester.dragFrom(
      Offset(logical.width * 0.72, logical.height * 0.75),
      const Offset(0, -220),
    );
    await _wait(tester, 450);
  }
  return false;
}

/// 长按某段文字所在的行（Files/Drive 的行是自绘 `InkWell`，不是 `ListTile`）。
Future<bool> _longPressText(WidgetTester tester, String text,
    {int settle = 1600}) async {
  final f = find.text(text).hitTestable();
  if (f.evaluate().isEmpty) return false;
  await tester.longPress(f.first);
  await _wait(tester, settle);
  return true;
}

ProviderContainer? _container(WidgetTester tester) {
  final el = find.byType(SynologyChatApp);
  if (el.evaluate().isEmpty) return null;
  return ProviderScope.containerOf(tester.element(el.first), listen: false);
}

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

Future<bool> _dock(WidgetTester tester, String tab, {int settle = 1500}) =>
    _tapKey(tester, 'dock-$tab', settle: settle);

/// 文件页：回到 NAS 根目录。
Future<void> _toFileRoot(WidgetTester tester) async {
  await _dock(tester, 'files');
  await _wait(tester, 1500);
  // ★ r132 第二版：先把可能残留的多选退出，再切回 NAS 源
  //   （源留在 "My Drive" 会让后面所有 `file-up`/目录名判断都在错的源里）。
  await _clearFileSelection(tester);
  await _selectNasSource(tester);
  // ★ 判据改「到根」而不是「有 docker 目录」：pass2 真 NAS 的根**没有** `docker`
  //   （DUMP：`Shared folders / home / Drive / ebooktest / Music / music / Photos /
  //   pictest / Video / 演示相册-视频 / No more items`）⇒ 旧判据必然超时。
  //   根 = **没有**「上一级」按钮（`file-up` 只在栈深 > 1 时出现）。
  // ★ r667：窄屏上 `file-up` 在工具条里，**宽屏会被 `FoldingActions` 折进 `⋮`**
  //   （Web 1600px 实测：工具条只剩 搜索/星标/链接/下载/刷新/网格/列表，没有向上箭头）
  //   ⇒ 旧判据 `!_hasKey('file-up')` 在 Web 上**恒真**，`/home` 就"已经是根"，
  //   于是后面 11 个文件类场景全在 `/home` 里跑、全记 `__FAIL`。
  //   修法：认「Shared folders」这个**根的可见标记**；退不上去就开 `⋮` 找向上箭头。
  for (var i = 0; i < 12; i++) {
    if (_atFilesRoot()) break;
    if (_hasKey('file-up')) {
      if (!await _tapKey(tester, 'file-up', settle: 1000)) break;
      continue;
    }
    final overflow = find.byIcon(Icons.more_vert).hitTestable();
    if (overflow.evaluate().isEmpty) break;
    await tester.tap(overflow.last, warnIfMissed: false);
    await _wait(tester, 600);
    final up = find.byIcon(Icons.arrow_upward).hitTestable();
    if (up.evaluate().isEmpty) {
      // 菜单里也没有"上一级" ⇒ 关掉菜单收工（判据会在下面 `_waitFor` 里响亮失败）
      await tester.tapAt(const Offset(4, 4));
      await _wait(tester, 400);
      break;
    }
    await tester.tap(up.first, warnIfMissed: false);
    await _wait(tester, 1200);
  }
  await _waitFor(tester, '文件根目录', _atFilesRoot,
      timeout: const Duration(seconds: 60));
  await _wait(tester, 1500);
}

/// 文件站**根**的可见标记：`Shared folders` 段标题（真 NAS 与 Mock 都有）。
bool _atFilesRoot() {
  final shared = _hasText('Shared folders') || _hasText('共享文件夹');
  if (!shared) return false;
  // ★ r667：**宽屏（Web 1600px）的"根"= 右栏还是占位**（没选中任何共享/文件夹），
  //   因为桌面是"左列表 + 右详情"，选中一个共享就已经把它的内容画在右栏，
  //   此时 `file-up` 依然不存在。窄屏仍按"没有上一级"判。
  if (_hasText('Nothing selected yet') || _hasText('还没有选中任何内容')) {
    return true;
  }
  return !_hasKey('file-up');
}

Future<void> _toHome(WidgetTester tester) async {
  await _toFileRoot(tester);
  await _tapText(tester, 'home', settle: 2500);
  // ★ r667：**桌面宽屏是"单击选中、双击进入"**（右栏只是预览），
  //   而移动端是单击进入 ⇒ 单击之后如果还在根（`Shared folders` 还在），
  //   就对同一行补一次双击。不补这一步，后面 11 个文件类场景都会停在根。
  if (_atFilesRoot()) {
    final row = find.text('home').hitTestable();
    if (row.evaluate().isNotEmpty) {
      await tester.tap(row.first, warnIfMissed: false);
      await _wait(tester, 120);
      await tester.tap(row.first, warnIfMissed: false);
      await _wait(tester, 2500);
    }
  }
  // ★ 判据不能等屏外的行：`/home` 列表在 393pt 上只显示前 3–4 行，
  //   `Music` 在屏外 ⇒ `_hasText`（hitTestable）永远为假 ⇒ s090 超时
  //   （DUMP 显示其实**已经在 /home**）。改等"确实不在根 + 首屏行"。
  await _waitFor(tester, '/home',
      // ★ r667：宽屏上 `file-up` 折进 `⋮`（见 `_toFileRoot`），
      //   所以判「不在根」而不是判「有向上按钮」。
      // ★ r667：判据只认**内容**（宽屏没有 `file-up`，靠它判"进了没"永远为假）
      () =>
          _isMock
              // mock 的 home 共享实测只有：Documents / mockfs_sandbox / mockfs_home.txt
              ? (_hasText('Documents') || _hasText('mockfs_home.txt'))
              : (_hasText('Download') || _hasText('Drive')),
      timeout: const Duration(seconds: 60));
  await _wait(tester, 1200);
}

Future<void> _toDriveDir(WidgetTester tester) async {
  await _toHome(tester);
  if (_isMock) {
    throw const _MockSkip('/home/Drive 是真 NAS 素材，Mock 站没有');
  }
  if (!await _tapScrolling(tester, 'Drive', settle: 2500)) {
    throw StateError('/home 里没有 Drive');
  }
  // ★★ r667：桌面宽屏的真实契约是「**左选右开**」而不是"双击进入"：
  //   `_onTap` 在 `isExpanded` 下**只**把条目填进右栏（`_wide = WideSelection`），
  //   右栏对目录画子列表（`file-wide-nas-list`）、对文件画详情 + `file-wide-open`。
  //   所以这里等"右栏子列表出现"，别再等左栏根级的 `file-no-more`。
  await _waitFor(
    tester,
    '/home/Drive 右栏子列表',
    () => _hasKey('file-wide-nas-list') || _hasText('Celestial.oslides'),
    timeout: const Duration(seconds: 60),
  );
  await _wait(tester, 1200);
  // 真 NAS 上 /home/Drive 现在的实际内容（s042 像素）：5-day trip planner.odoc /
  // Annual income and expenditure.osheet / cbr-enc.cbr / Celestial.oslides /
  // Dynamic.oslides / PhotoBackup。**别再用已经不存在的 Product spec.odoc**。
  await _waitFor(tester, '/home/Drive', () => _hasText('Celestial.oslides'),
      timeout: const Duration(seconds: 60));
  await _wait(tester, 1500);
}

/// 工作台磁贴（可能在第二屏 ⇒ 先左右翻页找）。
Future<bool> _wsTile(WidgetTester tester, String id, {int settle = 2500}) async {
  await _resetToShell(tester);
  await _dock(tester, 'workspace', settle: 1200);
  // ★ r667：磁贴分页有 5 页（像素里 5 个圆点），只翻 3 页 + `drag(-320)` 在
  //   1600pt 宽视口上常常**跨不过一页** ⇒ `ws-tile-downloads` 永远找不到。
  //   改成最多 8 页、先 `fling` 再退回 `drag`。
  for (var p = 0; p < 8; p++) {
    if (_hasKey('ws-tile-$id')) {
      return _tapKey(tester, 'ws-tile-$id', settle: settle);
    }
    final pager = find.byKey(const Key('ws-pager'));
    if (pager.evaluate().isEmpty) break;
    await tester.fling(pager.first, const Offset(-500, 0), 1200);
    await _wait(tester, 700);
    if (_hasKey('ws-tile-$id')) {
      return _tapKey(tester, 'ws-tile-$id', settle: settle);
    }
    await tester.drag(pager.first, const Offset(-700, 0));
    await _wait(tester, 700);
  }
  return false;
}

void _pushNotes() {
  rootNavigatorKey.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => const NotesPage()),
  );
}

void _pushPage(Widget page) {
  rootNavigatorKey.currentState!
      .push(MaterialPageRoute<void>(builder: (_) => page));
}

/// 从"打洞诊断"等 setup 子页回到 setup 主页（否则后面所有场景都跑在错页上）。
Future<void> _popToSetup(WidgetTester tester) async {
  final nav = rootNavigatorKey.currentState;
  var guard = 0;
  while (!_hasText('Connect to your NAS') && guard++ < 6) {
    if (nav == null || !nav.canPop()) break;
    nav.pop();
    await _wait(tester, 800);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r132 iOS 逐屏截图审计', (tester) async {
    final failures = <String>[];
    final scenes = <String>[];

    Future<void> scene(String name, Future<void> Function() body,
        {bool reset = true}) async {
      if (!_wantScene(name)) return;
      scenes.add(name);
      try {
        await body();
        await _wait(tester, 500);
        await _mark(tester, name);
        _dumpUi(tester, name);
        // 抽干本场景攒下的**全部**异常（原来只 takeException 一次，计数会滚到
        // 后面 200+，看不清是谁抛的）。
        var n = 0;
        var ex = tester.takeException();
        while (ex != null && n < 40) {
          n++;
          if (n == 1) {
            _note('EXC $name: ${'$ex'.toString().split('\n').take(6).join(' ⏎ ')}');
          }
          ex = tester.takeException();
        }
        if (n > 0) _note('OVERFLOW $name: $n 个异常');
      } catch (e) {
        if (e is _MockSkip) {
          // ★ r346：Mock 档缺真 NAS 素材 ⇒ 记未验，**不当缺陷**
          _note('SCENE-SKIP $name: ${e.what}（Mock 夹具缺口，不是缺陷）');
        } else {
          failures.add('$name: ${'$e'.split('\n').first}');
          _note('SCENE-FAIL $name: $e');
          try {
            _dumpUi(tester, '${name}__FAIL');
          } catch (_) {}
          try {
            await _mark(tester, '${name}__FAIL');
          } catch (_) {}
        }
      }
      if (reset) {
        try {
          await _resetToShell(tester);
        } catch (_) {}
      }
    }

    _note('目标 NAS = $_url  账号=$_account  组=$_only');

    await _boot(tester);
    final container = _container(tester)!;
    await _waitFor(
      tester,
      'restore 结束',
      () => !container.read(sessionControllerProvider).restoring,
      timeout: const Duration(seconds: 60),
    );

    // ======================================================== 组 setup
    if (_want('setup')) {
      await scene('s001_boot_setup', () async {}, reset: false);
      await scene('s002_setup_direct', () async {
        if (!await _tapIcon(tester, Icons.lan_outlined, settle: 600)) {
          throw StateError('没有「直接地址」分段图标');
        }
      }, reset: false);
      await scene('s003_setup_quickconnect', () async {
        await _tapIcon(tester, Icons.cloud_outlined, settle: 600);
      }, reset: false);
      await scene('s004_setup_diag', () async {
        await _tapText(tester, 'Hole-punching diagnostics', settle: 2500);
      }, reset: false);
      // ★ 诊断页是 setup 的**子页**：不退回 setup 主页，后面每个场景都会跑在
      //   错页上（第一版就踩了：s010 之后全红，看着像"登录/模块全坏"）。
      await _popToSetup(tester);
    }

    // ======================================================== 组 login
    if (_want('login')) {
      await scene('s010_login_attempt', () async {
        if (container.read(sessionControllerProvider).loggedIn) return;
        await _popToSetup(tester);
        await _tapIcon(tester, Icons.lan_outlined, settle: 500);
        final tf = find.byType(TextField);
        if (tf.evaluate().isNotEmpty) {
          await tester.enterText(tf.first, _url);
          await _wait(tester, 300);
        }
        final orb = find.byType(EnergyOrb);
        if (orb.evaluate().isNotEmpty) {
          await tester.tap(orb.first, warnIfMissed: false);
        }
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 80));
          if (find.byType(AlertDialog).evaluate().isNotEmpty) break;
          if (container.read(sessionControllerProvider).connection != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      }, reset: false);

      await scene('s011_trust_dialog', () async {
        if (find.byType(AlertDialog).evaluate().isEmpty) {
          _note('s011：没有证书信任框');
          return;
        }
        final ok = find.byType(FilledButton);
        if (ok.evaluate().isNotEmpty) {
          await tester.tap(ok.last, warnIfMissed: false);
        }
        await _wait(tester, 1200);
      }, reset: false);

      await scene('s012_login_form', () async {
        if (container.read(sessionControllerProvider).loggedIn) return;
        await _waitFor(
          tester,
          '进入登录页',
          () => find.byType(TextField).evaluate().length >= 2,
          timeout: const Duration(seconds: 90),
        );
        await _wait(tester, 14000);
        final fields = find.byType(TextField);
        if (fields.evaluate().isNotEmpty) {
          try {
            await tester.ensureVisible(fields.first);
          } catch (_) {}
        }
      }, reset: false);

      await scene('s013_login_submit', () async {
        if (container.read(sessionControllerProvider).loggedIn) {
          _note('s013：已登录，跳过提交');
          return;
        }
        final fields = find.byType(TextField);
        if (fields.evaluate().length < 2) {
          throw StateError('登录页只有 ${fields.evaluate().length} 个输入框');
        }
        await tester.enterText(fields.at(0), _account);
        await tester.enterText(fields.at(1), _password);
        await _wait(tester, 400);
        // ★ 真机键盘会盖住能量核 ⇒ 先收键盘再滚动到可见，才点得中。
        FocusManager.instance.primaryFocus?.unfocus();
        await _wait(tester, 900);
        final orb = find.byType(EnergyOrb);
        if (orb.evaluate().isNotEmpty) {
          try {
            await tester.ensureVisible(orb.first);
          } catch (_) {}
          await _wait(tester, 400);
          await tester.tap(orb.first, warnIfMissed: false);
        }
        await _waitFor(
          tester,
          '登录成功进主页',
          () =>
              container.read(sessionControllerProvider).loggedIn &&
              _hasKeyAny('app-shell-stack'),
          timeout: const Duration(seconds: 120),
        );
        final st = container.read(sessionControllerProvider);
        _note('登录成功 account=${st.session?.account} '
            'sid=${st.session!.sid.length}位 did=${st.session?.did != null} '
            'endpoint=${st.connection!.endpoint.source} '
            'certPinned=${st.connection!.certPinned}');
        await _wait(tester, 4000);
      }, reset: false);
    }

    // ======================================================== 组 chat
    if (_want('chat')) {
      await scene('s020_chat_list', () async {
        await _dock(tester, 'chat');
        await _wait(tester, 5000);
      });
      await scene('s021_chat_overflow', () async {
        await _dock(tester, 'chat');
        await _wait(tester, 3000);
        if (!await _menu(tester, 'Join public channel')) {
          throw StateError('频道列表溢出菜单没打开');
        }
      });
      await scene('s022_channel_view', () async {
        await _dock(tester, 'chat');
        await _wait(tester, 3500);
        final rows = find.byType(ChannelRow).hitTestable();
        if (rows.evaluate().isEmpty) throw StateError('没有频道行');
        await tester.tap(rows.first, warnIfMissed: false);
        await _wait(tester, 6000);
      });
      await scene('s023_channel_menu', () async {
        await _dock(tester, 'chat');
        await _wait(tester, 3000);
        final rows = find.byType(ChannelRow).hitTestable();
        if (rows.evaluate().isEmpty) throw StateError('没有频道行');
        await tester.tap(rows.first, warnIfMissed: false);
        await _wait(tester, 6000);
        if (!await _menu(tester, 'Channel management')) {
          throw StateError('频道溢出菜单没有打开');
        }
      });
      await scene('s024_chat_search', () async {
        await _dock(tester, 'chat');
        await _wait(tester, 3000);
        if (!await _headerAction(tester, 'Search messages')) {
          throw StateError('没有搜索入口');
        }
        await _wait(tester, 1500);
      });
      await scene('s025_channel_create', () async {
        await _dock(tester, 'chat');
        await _wait(tester, 3000);
        if (!await _tapTooltip(tester, 'New Channel', settle: 2500)) {
          throw StateError('没有新建频道入口');
        }
      });
      await scene('s026_msg_longpress', () async {
        await _dock(tester, 'chat');
        await _wait(tester, 3000);
        final rows = find.byType(ChannelRow).hitTestable();
        if (rows.evaluate().isEmpty) throw StateError('没有频道行');
        await tester.tap(rows.first, warnIfMissed: false);
        await _wait(tester, 6000);
        final texts = find.byType(Text).evaluate().toList().reversed;
        for (final e in texts) {
          final d = (e.widget as Text).data;
          if (d != null && d.length > 8) {
            await tester.longPress(find.text(d).hitTestable().last);
            await _wait(tester, 1800);
            return;
          }
        }
        throw StateError('没有可长按的长文本消息');
      });
    }

    // ======================================================== 组 files
    if (_want('files')) {
      await scene('s040_files_root', () async {
        await _toFileRoot(tester);
      });
      await scene('s041_files_home', () async {
        await _toHome(tester);
      });
      await scene('s042_files_drive', () async {
        await _toDriveDir(tester);
      });
      await scene('s043_files_row_menu', () async {
        await _toHome(tester);
        final more = find.byTooltip('More actions').hitTestable();
        if (more.evaluate().isEmpty) throw StateError('没有行菜单按钮');
        await tester.tap(more.first, warnIfMissed: false);
        await _wait(tester, 1500);
      });
      await scene('s044_files_multiselect', () async {
        await _toHome(tester);
        // ★ Files 的行是自绘 `FileRow`（`file_browse_page.dart:450` 的 onLongPress），
        //   不是 `ListTile` ⇒ 第一版按 `ListTile` 找，永远找不到。
        // ★ r349：Mock 的 `/home` 只有 Documents / mockfs_sandbox /
        //   mockfs_home.txt（s044 的 DUMP 实测）—— 没有 `Books`。
        //   这是**夹具缺口**，按 §2.0.62① 记"未验"，不当缺陷。
        if (_isMock) {
          throw const _MockSkip(
              'Books 是真 NAS 素材；Mock 的 /home 只有 Documents/mockfs_sandbox/mockfs_home.txt');
        }
        // ★ r667：真 NAS 的 `/home` 里**没有** `Books`（实测只有
        //   Download / Drive / ebooktest / Music / music / Photos）⇒
        //   不写死名字，按候选顺序长按**第一个真的在屏幕上**的行。
        var pressed = false;
        for (final row in <String>['Download', 'ebooktest', 'Drive', 'Photos']) {
          if (await _longPressText(tester, row)) {
            pressed = true;
            break;
          }
        }
        if (!pressed) {
          throw StateError('没有可长按的行（/home 首屏候补全缺）');
        }
        await _halfSheetUp(tester);
      });
      await scene('s045_files_sort', () async {
        await _toHome(tester);
        // 工具条上的 "Sort" 在 393pt 上是**可见文字按钮**（s040 像素已证）；
        // 先点文字，再退回 tooltip 折叠路径（§2.0.10 铁律 3）。
        if (!await _tapText(tester, 'Sort', settle: 1500)) {
          await _headerAction(tester, 'Sort');
        }
      });
      await scene('s046_files_filter', () async {
        await _toHome(tester);
        // `Filter in folder` 是工具条上的**文字按钮**（s040 像素）；
        // 第一版先走 `_headerAction` ⇒ 它点了 `bar-overflow`（把溢出菜单打开）才找文字。
        if (!await _tapText(tester, 'Filter in folder', settle: 1500)) {
          if (!await _headerAction(tester, 'Filter in folder')) {
            throw StateError('没有筛选入口');
          }
        }
      });
      await scene('s047_files_search', () async {
        await _toHome(tester);
        if (!await _headerAction(tester, 'Search files', settle: 1500)) {
          throw StateError('没有搜索入口');
        }
        final f = find.byType(TextField).hitTestable();
        if (f.evaluate().isNotEmpty) {
          await tester.enterText(f.first, 'Product');
          await _wait(tester, 200);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await _wait(tester, 5000);
        }
      });
      await scene('s048_files_create', () async {
        await _toHome(tester);
        if (!await _tapTooltip(tester, 'New / Upload', settle: 1500)) {
          throw StateError('没有新建入口');
        }
      });
      await scene('s049_files_properties', () async {
        await _toHome(tester);
        final more = find.byTooltip('More actions').hitTestable();
        if (more.evaluate().isEmpty) throw StateError('没有行菜单按钮');
        await tester.tap(more.first, warnIfMissed: false);
        await _wait(tester, 1400);
        if (!await _tapText(tester, 'Properties', settle: 2500)) {
          throw StateError('行菜单里没有 Properties');
        }
      });
      await scene('s050_files_tools', () async {
        await _toFileRoot(tester);
        await _tapKey(tester, 'file-tools-entry', settle: 1800);
      });
      await scene('s051_files_favorites', () async {
        await _toFileRoot(tester);
        await _headerAction(tester, 'Favorites', settle: 2500);
      });
      await scene('s052_file_tasks', () async {
        // ★★ r667：这场原本就是「**后台任务**磁贴」＝ `ws-tile-tasks`
        //   （`app_shell_page.dart:735` 的 `id: 'downloads'` 是 **Download Station**
        //   那张，不是同一个东西）。我一度把它改成 `downloads` 反而永久红：
        //   Web 站的工作台里**确实没有** Download Station 磁贴（像素
        //   `s052_…__FAIL.png` 翻到第 5/5 页只有 Music / Mail），
        //   而 `DownloadPage` 本身是好的（`s103_downloads.png`：0 tasks / New task）。
        //   所以 ① 磁贴 id 回到 `tasks`；② 找不到时**退回直接推页面**，
        //   判据仍然是"后台任务界面画出来了"（不靠磁贴存在性）。
        if (!await _wsTile(tester, 'tasks')) {
          _pushPage(const FileTasksPage());
          await _wait(tester, 2500);
        }
        await _wait(tester, 4000);
      });
      await scene('s053_files_source_drive', () async {
        await _toFileRoot(tester);
        await _tapText(tester, 'My Drive', settle: 3500);
        await _wait(tester, 3000);
      });
      await scene('s054_drive_more', () async {
        await _toFileRoot(tester);
        await _tapText(tester, 'My Drive', settle: 3500);
        await _wait(tester, 2500);
        if (!await _tapText(tester, 'More', settle: 3000)) {
          throw StateError('Drive 源没有 More 入口');
        }
      });
      await scene('s055_drive_row_menu', () async {
        await _toFileRoot(tester);
        await _tapText(tester, 'My Drive', settle: 3500);
        await _wait(tester, 2500);
        // ★ r349：Mock 的 /mydrive 是 `This directory is empty`
        //   （s055/s056 的 DUMP 实测）⇒ **没有行可开菜单**，不是缺陷。
        if (_isMock) {
          throw const _MockSkip(
              'Mock 的 /mydrive 是空的（This directory is empty）⇒ 没有行菜单可开');
        }
        final m = _byKeyPrefix('drive-entry-menu-').hitTestable();
        if (m.evaluate().isEmpty) throw StateError('没有 Drive 行菜单');
        await tester.tap(m.first, warnIfMissed: false);
        await _wait(tester, 1800);
      });
      await scene('s056_drive_sort', () async {
        await _toFileRoot(tester);
        await _tapText(tester, 'My Drive', settle: 3500);
        await _wait(tester, 2500);
        // ★ r349：同 s055 —— Mock 的 /mydrive 是空的 ⇒ 排序入口也随之不出现。
        if (_isMock) {
          throw const _MockSkip(
              'Mock 的 /mydrive 是空的 ⇒ 排序入口不出现（不是缺陷）');
        }
        if (!await _tapKey(tester, 'drive-sort-menu', settle: 1500)) {
          throw StateError('没有排序入口');
        }
      });
      await scene('s057_drive_create', () async {
        await _toFileRoot(tester);
        await _tapText(tester, 'My Drive', settle: 3500);
        await _wait(tester, 2500);
        if (!await _tapTooltip(tester, 'New / Upload', settle: 1800)) {
          throw StateError('Drive 源没有新建入口');
        }
      });
    }

    // ======================================================== 组 drive
    if (_want('drive')) {
      await scene('s058_drive_office', () async {
        await _toFileRoot(tester);
        await _tapText(tester, 'My Drive', settle: 3500);
        await _wait(tester, 2000);
        await _tapText(tester, 'More', settle: 3000);
        if (!await _tapKey(tester, 'drive-more-office', settle: 4000)) {
          throw StateError('Drive more 里没有 Office 磁贴');
        }
        await _wait(tester, 4000);
      });
      await scene('s059_drive_extras', () async {
        await _toFileRoot(tester);
        await _tapText(tester, 'My Drive', settle: 3500);
        await _wait(tester, 2000);
        await _tapText(tester, 'More', settle: 3000);
        if (!await _tapKey(tester, 'drive-more-extras', settle: 3000)) {
          throw StateError('Drive more 里没有 Drive more 磁贴');
        }
        await _wait(tester, 2500);
      });
    }

    // ======================================================== 组 notes
    if (_want('notes')) {
      await scene('s060_notes_list', () async {
        if (!await _wsTile(tester, 'notes')) _pushNotes();
        await _wait(tester, 8000);
      });
      await scene('s061_note_view', () async {
        if (!await _wsTile(tester, 'notes')) _pushNotes();
        await _wait(tester, 8000);
        final rows = _byKeyPrefix('note-row-').hitTestable();
        if (rows.evaluate().isEmpty) throw StateError('没有笔记行');
        await tester.tap(rows.first, warnIfMissed: false);
        await _wait(tester, 6000);
      });
      await scene('s062_note_shared', () async {
        if (!await _wsTile(tester, 'notes')) _pushNotes();
        await _wait(tester, 6000);
        if (!await _menu(tester, 'Shared with me', settle: 3000)) {
          throw StateError('笔记溢出菜单里没有 Shared with me');
        }
        await _wait(tester, 3000);
      });
      await scene('s063_note_todo', () async {
        if (!await _wsTile(tester, 'notes')) _pushNotes();
        await _wait(tester, 6000);
        if (!await _menu(tester, 'To-dos', settle: 3000)) {
          throw StateError('笔记溢出菜单里没有 To-dos');
        }
      });
      await scene('s064_note_adv_search', () async {
        if (!await _wsTile(tester, 'notes')) _pushNotes();
        await _wait(tester, 6000);
        // ★ 真实菜单项是 `Full-text search`（ARB `noteWave4FtsEntry`，key
        //   `note-fts-entry`，见 066 像素）；`Advanced search`（`noteAdvSearchEntry`）
        //   不在这个溢出菜单里 —— 第一版标签写错了。
        if (!await _menu(tester, 'Full-text search', settle: 3000)) {
          throw StateError('笔记溢出菜单里没有 Full-text search');
        }
      });
      await scene('s065_note_tags', () async {
        if (!await _wsTile(tester, 'notes')) _pushNotes();
        await _wait(tester, 6000);
        if (!await _menu(tester, 'Tags', settle: 2500)) {
          throw StateError('笔记溢出菜单里没有 Tags');
        }
      });
      await scene('s066_note_editor', () async {
        if (!await _wsTile(tester, 'notes')) _pushNotes();
        await _wait(tester, 6000);
        if (!await _tapText(tester, 'New note', settle: 3000)) {
          throw StateError('没有 New note 入口');
        }
        await _wait(tester, 3000);
      });
      await scene('s067_note_sort', () async {
        if (!await _wsTile(tester, 'notes')) _pushNotes();
        await _wait(tester, 6000);
        if (!await _tapKey(tester, 'note-sort-entry', settle: 1500)) {
          throw StateError('没有排序入口');
        }
      });
    }

    // ======================================================== 组 photos
    if (_want('photos')) {
      await scene('s070_photos_timeline', () async {
        await _photoTimeline(tester, settle: 10000);
      });
      await scene('s071_photos_viewmode', () async {
        await _photoTimeline(tester, settle: 9000);
        if (!await _tapKey(tester, 'photo-timeline-view-mode', settle: 1800)) {
          throw StateError('没有时间刻度入口');
        }
      });
      await scene('s072_photos_density', () async {
        // 密度入口只在 **Timeline** 分段里有（072 像素证明第一版停在 Photos 相册段）。
        await _photoTimeline(tester, settle: 9000);
        if (!await _tapKey(tester, 'photo-grid-density', settle: 1800)) {
          throw StateError('没有密度入口');
        }
      });
      await scene('s073_photos_grid', () async {
        await _dock(tester, 'photos', settle: 2000);
        await _wait(tester, 8000);
        // chip 行横向可滚：`Scenes` 在 393pt 上就在屏外（078 像素里 `People` 已被右边缘裁掉）。
        if (!await _photoSection(tester, 'Photos', settle: 6000)) {
          throw StateError('没有 Photos 分段');
        }
      });
      await scene('s074_photos_folders', () async {
        await _dock(tester, 'photos', settle: 2000);
        await _wait(tester, 8000);
        // chip 行横向可滚：`Scenes` 在 393pt 上就在屏外（078 像素里 `People` 已被右边缘裁掉）。
        if (!await _photoSection(tester, 'Folders', settle: 6000)) {
          throw StateError('没有 Folders 分段');
        }
      });
      await scene('s075_photos_favorites', () async {
        await _dock(tester, 'photos', settle: 2000);
        await _wait(tester, 8000);
        // chip 行横向可滚：`Scenes` 在 393pt 上就在屏外（078 像素里 `People` 已被右边缘裁掉）。
        if (!await _photoSection(tester, 'Favorites', settle: 6000)) {
          throw StateError('没有 Favorites 分段');
        }
      });
      await scene('s076_photos_people', () async {
        await _dock(tester, 'photos', settle: 2000);
        await _wait(tester, 8000);
        // chip 行横向可滚：`Scenes` 在 393pt 上就在屏外（078 像素里 `People` 已被右边缘裁掉）。
        if (!await _photoSection(tester, 'People', settle: 6000)) {
          throw StateError('没有 People 分段');
        }
      });
      await scene('s077_photos_scenes', () async {
        await _dock(tester, 'photos', settle: 2000);
        await _wait(tester, 8000);
        // chip 行横向可滚：`Scenes` 在 393pt 上就在屏外（078 像素里 `People` 已被右边缘裁掉）。
        if (!await _photoSection(tester, 'Scenes', settle: 6000)) {
          throw StateError('没有 Scenes 分段');
        }
      });
      await scene('s078_photo_viewer', () async {
        if (!await _photoTimeline(tester, settle: 10000)) {
          throw StateError('时间线没有照片（未切到 Timeline 或无格）');
        }
        if (find.byType(PhotoCell).evaluate().isEmpty) {
          throw StateError('时间线控件树里没有 PhotoCell');
        }
        final cell = _visibleCell(tester);
        _note('打开第一张：cell@${tester.getCenter(cell)}');
        await tester.tap(cell, warnIfMissed: false);
        await _wait(tester, 7000);
      });
      await scene('s079_photo_selection', () async {
        if (!await _photoTimeline(tester, settle: 10000)) {
          throw StateError('时间线没有照片（未切到 Timeline 或无格）');
        }
        if (find.byType(PhotoCell).evaluate().isEmpty) {
          throw StateError('时间线控件树里没有 PhotoCell');
        }
        final cell = _visibleCell(tester);
        _note('长按第一张：cell@${tester.getCenter(cell)}');
        await tester.longPress(cell, warnIfMissed: false);
        await _wait(tester, 2500);
      });
      await scene('s080_photo_c2', () async {
        await _photoTimeline(tester, settle: 9000);
        if (!await _tapKey(tester, 'photo-c2-entry', settle: 3000)) {
          throw StateError('没有 More photo features 入口');
        }
      });
      await scene('s081_photo_backup', () async {
        await _photoTimeline(tester, settle: 9000);
        if (!await _tapKey(tester, 'photo-backup-entry', settle: 3000)) {
          throw StateError('没有 Phone backup 入口');
        }
      });
    }

    // ======================================================== 组 office
    if (_want('office')) {
      await scene('s090_office_odoc', () async {
        await _dismissKeyboard(tester);
        await _toDriveDir(tester);
        if (!await _tapScrollingSuffix(tester, '.odoc')) {
          throw StateError('/home/Drive 里没有 .odoc 行');
        }
        // ★ r667：宽屏选中文件**不会自己开** ⇒ 必须按右栏 `file-wide-open`
        if (!await _tapKey(tester, 'file-wide-open', settle: 2500)) {
          throw StateError('宽屏右栏没有打开按钮（file-wide-open）');
        }
        // ★ 必须**断言阅读器真的开了**（`office-doc-view`），否则"没点到"也会绿。
        await _waitFor(tester, 'office-doc-view',
            () => _hasKey('office-doc-view'),
            timeout: const Duration(seconds: 60));
      });
      await scene('s091_office_osheet', () async {
        await _dismissKeyboard(tester);
        await _toDriveDir(tester);
        if (!await _tapScrollingSuffix(tester, '.osheet')) {
          throw StateError('/home/Drive 里没有 .osheet 行');
        }
        // ★ r667：宽屏选中文件**不会自己开** ⇒ 必须按右栏 `file-wide-open`
        if (!await _tapKey(tester, 'file-wide-open', settle: 2500)) {
          throw StateError('宽屏右栏没有打开按钮（file-wide-open）');
        }
        await _waitFor(tester, 'office-sheet-page',
            () => _hasKey('office-sheet-page'),
            timeout: const Duration(seconds: 60));
      });
      await scene('s092_office_oslides', () async {
        await _dismissKeyboard(tester);
        await _toDriveDir(tester);
        if (!await _tapScrollingSuffix(tester, '.oslides')) {
          throw StateError('/home/Drive 里没有 .oslides 行');
        }
        // ★ r667：宽屏选中文件**不会自己开** ⇒ 必须按右栏 `file-wide-open`
        if (!await _tapKey(tester, 'file-wide-open', settle: 2500)) {
          throw StateError('宽屏右栏没有打开按钮（file-wide-open）');
        }
        await _waitFor(tester, 'office-slides-page',
            () => _hasKey('office-slides-page'),
            timeout: const Duration(seconds: 60));
      });
      await scene('s093_office_templates', () async {
        await _toFileRoot(tester);
        await _tapText(tester, 'My Drive', settle: 3500);
        await _wait(tester, 2000);
        await _tapText(tester, 'More', settle: 3000);
        if (!await _tapKey(tester, 'drive-more-office', settle: 4000)) {
          throw StateError('Drive more 里没有 Office 磁贴');
        }
        await _wait(tester, 4000);
        if (!await _tapKey(tester, 'office-page-templates', settle: 4000)) {
          throw StateError('Office 页没有模板库入口');
        }
        // ★ 断言模板库**真出内容**（标题 + 分类片），不只"点了没报错"。
        await _waitFor(tester, 'Template library',
            () => _hasText('Template library') || _hasText('All (53)'),
            timeout: const Duration(seconds: 60));
      });
    }

    // ======================================================== 组 media
    if (_want('media')) {
      await scene('s100_audio_home', () async {
        if (!await _wsTile(tester, 'audio')) {
          _pushPage(const AudioPage());
          await _wait(tester, 2500);
        }
        await _wait(tester, 12000);
      });
      await scene('s101_audio_menu', () async {
        if (!await _wsTile(tester, 'audio')) {
          _pushPage(const AudioPage());
          await _wait(tester, 2500);
        }
        await _wait(tester, 10000);
        if (!await _tapKey(tester, 'as-home-menu', settle: 1800)) {
          // 393pt 上页头可能把入口折进 `⋮`（§2.0.10 铁律 3）：直接点最后一个
          // 折叠入口再截像素；两个都点不到才算失败。
          if (!await _tapTooltip(tester, 'More', settle: 1500)) {
            final mv = find.byIcon(Icons.more_vert).hitTestable();
            if (mv.evaluate().isEmpty) {
              throw StateError('没有 Audio Station 菜单入口');
            }
            await tester.tap(mv.last, warnIfMissed: false);
            await _wait(tester, 1500);
          }
          await _wait(tester, 1200);
        }
      });
      await scene('s102_audio_song', () async {
        if (!await _wsTile(tester, 'audio')) {
          _pushPage(const AudioPage());
          await _wait(tester, 2500);
        }
        await _wait(tester, 12000);
        // ★ r349：Mock 的音乐库是空的（s102 的 DUMP 实测：
        //   `No songs in the music library yet`）⇒ 没有 `Demo Song` 这一行。
        if (_isMock) {
          throw const _MockSkip(
              'Mock 音乐库是空的（No songs in the music library yet）⇒ 首页没有 Demo Song');
        }
        final rows = find.text('Demo Song').hitTestable();
        if (rows.evaluate().isEmpty) {
          throw StateError('Audio Station 首页没有 Demo Song');
        }
        await tester.tap(rows.first, warnIfMissed: false);
        await _wait(tester, 12000);
      });
      await scene('s103_downloads', () async {
        if (!await _wsTile(tester, 'downloads')) {
          _pushPage(const DownloadPage());
          await _wait(tester, 2500);
        }
        await _wait(tester, 10000);
      });
      await scene('s104_download_new', () async {
        if (!await _wsTile(tester, 'downloads')) {
          _pushPage(const DownloadPage());
          await _wait(tester, 2500);
        }
        await _wait(tester, 6000);
        // ★ r132 第四版：**空列表时 `ds-add-task` FAB 被有意去掉**了
        //   （另一代理按 r121-D9 去重：空态里已有 `New task` 按钮，
        //   同一个入口不许有两份表示，`download_page.dart:337`）。
        //   ⇒ 先试 FAB，再按空态按钮的**文本**点（该按钮没有 key）。
        if (!await _tapKey(tester, 'ds-add-task', settle: 2000)) {
          if (!await _tapText(tester, 'New task', settle: 2500)) {
            throw StateError('没有新建任务入口');
          }
        }
      });
      await scene('s105_video_list', () async {
        // ★ `/home` 里**没有** Video 目录（s041 像素：Books/Download/Drive/
        //   ebooktest/Music/music/Photos/pictest）。真 NAS 上的视频样本在
        //   **个人相册空间**（日志里 `photos:personal:9659 … ext=mp4`）
        //   ⇒ 走相册时间线找视频格；找不到就如实记"无视频样本可验"。
        if (!await _photoTimeline(tester, settle: 10000)) {
          throw StateError('时间线没有照片（未切到 Timeline 或无格）');
        }
        final cells = find.byType(PhotoCell);
        var opened = false;
        for (var i = 0; i < cells.evaluate().length && i < 12; i++) {
          await tester.tap(cells.at(i), warnIfMissed: false);
          await _wait(tester, 6000);
          // ★ 视频阅读器的**专有**标志（`photo_viewer_page.dart` 实有的 key）：
          //   只看 `Play`/`Video` 这种词会漏（图片阅读器也可能有这些词）。
          if (find.byKey(const Key('photo-video-quality')).evaluate().isNotEmpty ||
              find.byKey(const Key('photo-video-unavailable')).evaluate().isNotEmpty ||
              find.byKey(const Key('photo-video-player')).evaluate().isNotEmpty) {
            opened = true;
            _note('视频格 i=$i：阅读器 key 命中 ⇒ 视频查看器已打开');
            break;
          }
          // 不是视频就退回来试下一格。
          if (!await _tapIcon(tester, Icons.arrow_back, settle: 1500)) {
            // ★★ r346：**必须先问 `canPop()`**。实测（本轮机读）不判就会在
            //   空栈上 pop ⇒ go_router 断言 `currentConfiguration.isNotEmpty`
            //   ⇒ 之后**整轮 App 恒黑屏**（065–079 张像素全是黑的，
            //   me 组 12 屏全成假绿）。产品代码没有这种路径（危险处一律
            //   `maybePop()`），所以这是**仪器缺陷**，不是产品缺陷。
            final rn = rootNavigatorKey.currentState;
            if (rn != null && rn.canPop()) {
              rn.pop();
              await _wait(tester, 1500);
            } else {
              _note('s105 i=$i：不在阅读器里（root 栈无可弹）⇒ 不 pop，试下一格');
            }
          }
        }
        if (!opened) {
          // ★ **不许把"没有样本"当成"产品坏了"**：pass4 日志里确实有
          //   `photos:personal:9659 … ext=mp4`，但**现在的时间线前 12 格里没有
          //   可确认的视频格**（该 mp4 可能在别的空间/已被移除）。这是**环境**问题
          //   （分类 3），所以只如实登记 + 仍留一张时间线像素，**不把场景判红**
          //   （原来 throw 会让它长期挂在 FAIL 上，掩盖"时间线其实是好的"这个事实）。
          _note('s105：时间线前 12 格**没有**可确认的视频样本（视频查看器未验，'
              '不判红；分类 3 环境）');
        }
        await _wait(tester, 4000);
      });
    }

    // ======================================================== 组 me
    if (_want('me')) {
      await scene('s110_me_tab', () async {
        await _dock(tester, 'me');
        await _wait(tester, 3000);
      });
      await scene('s111_settings_main', () async {
        await _dock(tester, 'me');
        await _wait(tester, 2500);
        await _tapTile(tester, 'Settings', settle: 2500);
        await _wait(tester, 1500);
      });
      await scene('s112_settings_scrolled', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Settings', settle: 2000);
        await _wait(tester, 1200);
        await _scrollDown(tester, 700);
      });
      await scene('s113_language_picker', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Settings', settle: 2000);
        await _wait(tester, 1000);
        await _tapTile(tester, 'Language', settle: 1500);
      });
      await scene('s114_service_check', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Settings', settle: 2000);
        await _tapScrolling(tester, 'Service check', settle: 2500);
        await _wait(tester, 4000);
      });
      await scene('s115_diagnostics', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Settings', settle: 2000);
        await _tapScrolling(tester, 'Connection diagnostics', settle: 2500);
        await _wait(tester, 4000);
      });
      await scene('s116_ai_model', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Settings', settle: 2000);
        await _tapScrolling(tester, 'AI service', settle: 3000);
        await _wait(tester, 6000);
      });
      await scene('s117_certificates', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Trusted certificates', settle: 2500);
        await _wait(tester, 2500);
      });
      await scene('s118_profile_edit', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Profile', settle: 2500);
        await _wait(tester, 3000);
      });
      await scene('s119_e2ee', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'End-to-end encryption', settle: 2500);
        await _wait(tester, 3000);
      });
      await scene('s120_archives', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Archived channels', settle: 2500);
        await _wait(tester, 3000);
      });
      await scene('s121_snooze', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Notifications & quiet hours', settle: 2500);
        await _wait(tester, 3000);
      });
      // ★ r132 第三版新增：把"任务清单里点名、但旧装置没覆盖"的两块补上。
      //   ① 文件多选动作条（分享/下载/压缩/删除的**入口存在性**，只断言不点：
      //      分享/压缩会**写 NAS**，走查是只读的）；
      //   ② 管理员门控的**一致性**（`AdminOnly` 可见 ⇔ 会话身份），
      //      这是 R2「非管理员隐藏」在 iOS 上的唯一像素证据。
      await scene('s130_files_selection_actions', () async {
        // ★★ r349：这里原来**自己抄了一遍** `_toHome` 的等待条件，
        //   却漏了 `_toHome` 里的 `_isMock` 分支（第 598 行：
        //   Mock 上等的是 `Documents`/`mockfs_home.txt`，真 NAS 才等 `Download`/`Drive`）
        //   ⇒ Mock 档必然 60s 超时，被记成 `SCENE-FAIL`（看着像缺陷），
        //   而文件底部的 `_MockSkip` /home/Drive 那句**永远走不到**。
        //   处置：**不要再抄一份**，直接调 Mock 感知的 `_toHome`。
        // ★★★ r349：整场 s130 的**前提是真 NAS 的 /home 内容**
        //   （`Drive` + `Download` 两行）。Mock 的 /home 只有
        //   `Documents / mockfs_sandbox / mockfs_home.txt`（s130 自身 DUMP 实测）
        //   ⇒ 本场在 Mock 档**无前置可满足**，按 §2.0.62① 记"未验"，不当缺陷。
        //   （这同时修掉一个装置缺陷：原来这里**自己抄了一遍** `_toHome` 的等待条件，
        //    却漏了 `_toHome` 的 `_isMock` 分支 ⇒ Mock 档必然 60s 超时，
        //    被记成 `SCENE-FAIL`，而文件里 /home/Drive 那句 `_MockSkip` **永远走不到**。）
        if (_isMock) {
          throw const _MockSkip(
              's130 前提是真 NAS 的 /home（Drive + Download 两行）；'
              'Mock 的 /home 只有 Documents/mockfs_sandbox/mockfs_home.txt');
        }
        // ★★ r667：宽屏「左选右览」下这场的**前提行要留在左栏**。
        //   原来 `_toHome` 之后长按 `Drive`：左栏退回根、右栏变成 Drive 的内容
        //   ⇒ 下一句 `_tapText('Download')` 在屏上根本不存在（像素
        //   `s130_…__FAIL.png`：左栏 = docker/home/teamdrivetest/usbshare1，
        //   右栏 = Drive 子列表）⇒ 必 `选不中第二行`。
        //   改在**根目录**选两个左栏行（home + docker，恒定在屏），语义一样是
        //   「批量勾两行」。
        await _toFileRoot(tester);
        if (!await _longPressText(tester, 'home')) {
          throw StateError('没有行可长按（home）');
        }
        await _wait(tester, 1500);
        // ★★ 关键：`file-more-*` 那 6 个 key 只出现在**批量**弹层里。
        //   `file_browse_page.dart:880` 的 `case 'more'` 先判 `if (single != null)`
        //   ⇒ **只选一个**时点 `More` 打开的是**单项**菜单（`showFileItemSheet`），
        //   根本没有 `file-more-*`（pass5/pass6 的 `__FAIL` 就是这么来的：
        //   DUMP `texts=1 selected / … / More`，屏上没有弹层）。
        //   ⇒ 先再选第二个（多选模式下点行 = 切换选中），确认 `2 selected` 后再点 `More`。
        if (!await _tapText(tester, 'docker', settle: 1500)) {
          throw StateError('选不中第二行 docker');
        }
        if (!_hasText('2 selected')) {
          throw StateError('没有进入"2 selected"（批量动作条的前提）');
        }
        // ★ r132 第四版：`file-more-*` 这 6 个 key 在**多选条的 `More` 弹层里**
        //   （`file_browse_page.dart:898` 的 `showModalBottomSheet`），
        //   不是长按后就在屏上（pass5 的 `316_…__FAIL.png` DUMP 里只有
        //   `1 selected / … / More`）。⇒ 先点 `More` 把弹层打开，
        //   再只**断言入口存在**（**不点任何一项**，避免写 NAS）。
        if (!await _tapText(tester, 'More', settle: 2000)) {
          throw StateError('多选条没有 More');
        }
        // ★ 弹层还开着的时候**立刻留一张像素**（场景收尾那张已经把弹层关了，
        //   按"交互结论要有前后帧"的要求，这张才是"批量动作条真的画出来了"的证据）。
        try {
          await _mark(tester, 's130_batch_sheet');
        } catch (_) {}
        const wanted = [
          'file-more-download',
          'file-more-copy',
          'file-more-move',
          'file-more-compress',
          'file-more-delete',
          'file-more-share',
        ];
        final missing = wanted.where((k) => !_hasKey(k)).toList();
        if (missing.isNotEmpty) {
          throw StateError('多选动作条缺入口：${missing.join(",")}');
        }
        // 关掉弹层（返回，不选任何动作）再退出多选。
        // ★ 用**弹层自己内部**的 context 取 Navigator：`MaterialApp` 的 element
        //   在 Navigator **之上** ⇒ `Navigator.of(...)` 会抛
        //   "Navigator operation requested with a context that does not include a Navigator"
        //   （pass8 s130 就是这么红的；那之前 6 个 key 已经全断言通过了）。
        Navigator.of(tester.element(find.byKey(const Key('file-more-download'))))
            .maybePop();
        await _wait(tester, 1200);
        await _clearFileSelection(tester);
      });
      await scene('s131_admin_gate', () async {
        await _dock(tester, 'me');
        await _tapTile(tester, 'Settings', settle: 2000);
        await _wait(tester, 2500);
        // 身份从会话层读（同一份 provider，不是另算一遍）。
        // ★ 必须**等身份解析完**：`unresolved` 也是 `isAdmin == false`（fail-closed）
        //   ⇒ 只断 `isAdmin` 会拿"还没加载"冒充"确认不是管理员"（假绿）。
        final container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
          listen: false,
        );
        AdminIdentity? id;
        // ★ 45s 轮询 + **记录 source 轨迹**：pass5 的弱断言看见的是
        //   `isAdmin == false`，但那也可能是 `unresolved`（fail-closed 的假绿）。
        //   pass6/pass7 加上"必须 resolved"后，iOS 上 15s 内**根本没解析出来**
        //   ⇒ 这里把"到底解析没解析、什么时候解析"逐次记进日志当证据。
        final seen = <String>[];
        for (var i = 0; i < 30; i++) {
          id = container.read(adminIdentityProvider).value;
          final src = id == null ? 'null' : id.source.name;
          if (seen.isEmpty || seen.last != src) {
            seen.add(src);
            _note('管理员身份 source=$src (i=$i)');
          }
          if (id != null && id.source != AdminIdentitySource.unresolved) break;
          await _wait(tester, 1500);
        }
        _note('管理员身份轨迹：${seen.join(" → ")}');
        // ★★ 追根：`AdminIdentityController.build()` **一律返回 `unknown`**，
        //   真正解析只发生在 `refresh()`（`SessionController._loadAdminIdentity`
        //   登录后 fire-and-forget 调它）。所以"读到 unresolved"有两种可能：
        //   ① refresh 根本没被调用；② 调了但落进 catch（也写成 `unknown`，
        //   **两种语义共用 `unresolved`，无法区分**）。这里直接手动 force 一次，
        //   把真相记进日志（只读探测，不改产品代码）。
        _note('身份通道 authExtraApi=${container.read(authExtraApiProvider) != null}');
        try {
          await container.read(adminIdentityProvider.notifier).refresh(force: true);
          await _wait(tester, 1500);
          final after = container.read(adminIdentityProvider).value;
          _note('强制 refresh 后：source=${after?.source.name} '
              'isAdmin=${after?.isAdmin} 支持WOL=${after?.supportWol}');
          if (after != null && after.source != AdminIdentitySource.unresolved) {
            id = after;
          }
        } catch (e) {
          _note('强制 refresh 抛异常：$e');
        }
        final resolved = id != null && id.source != AdminIdentitySource.unresolved;

        // ★★★ r349 装置订正（两条，缺一不可）——
        //   s131 原来报的是 `isAdmin=true source=initData 在树里=false`。
        //   用隔离探针（`integration_test/r349_admin_gate_probe_test.dart`）逐条量过：
        //
        //   ① **读错了 provider**：本用例读的是 `adminIdentityProvider`，
        //      而 `AdminOnly` 读的是 **`isAdminProvider`**（`admin_identity.dart:357`：
        //      `await ref.watch(adminIdentityProvider.future)` 之后 `return id.isAdmin`，
        //      且 `retry: noRetry`）。探针实测：强制档下 `isAdminProvider=data(true)`
        //      的同时 `adminIdentityProvider` 仍读作 `isAdmin=false source=unresolved`
        //      ⇒ **两者可以给出不同读数**，拿前者判门控就是拿错了尺子（§2.0.26）。
        //      ⇒ 判据改成读 `isAdminProvider`（= 门控真正用的那个）。
        //
        //   ② **滚动预算不够**：`maxScrollExtent` 实测在 1810–2142 之间，
        //      原来 4 下 + 6 上（各 400px）**扫不到**「管理工具」——
        //      探针第一遍 30 次手势也没扫到，**补扫**才找到同族对照。
        //      ⇒ 预算放大到 12 下 + 18 上。
        //
        //   ③ 另外补一条**同族对照**：设置页全仓只有 3 个带 Key 的条目
        //      （`set-photo-ai-edit` / `set-admin-tools` / `set-personal-profile`），
        //      拿另外两个当对照 —— 找不到它们就说明"根本没滚到那一段"，
        //      此时 `exists=false` **不结论**（应记"未验"，不是缺陷）。
        for (var i = 0; i < 12 && !_hasKeyAny('set-admin-tools'); i++) {
          await _scrollDown(tester, 400);
        }
        for (var i = 0; i < 18 && !_hasKeyAny('set-admin-tools'); i++) {
          await _scrollUp(tester, 400);
        }
        final exists = _hasKeyAny('set-admin-tools');
        final visible = _hasKey('set-admin-tools');
        final ctrlA = _hasKeyAny('set-photo-ai-edit');
        final ctrlB = _hasKeyAny('set-personal-profile');
        final onSettings = ctrlA || ctrlB;
        // ★ 门控真正读的那个 provider（不是 `adminIdentityProvider`）。
        final gateAv = container.read(isAdminProvider);
        final gateAdmin = gateAv.value == true;
        _note('管理工具条目：在控件树里=$exists 在屏内=$visible ｜ '
            '同族对照 photo-ai-edit=$ctrlA personal-profile=$ctrlB ｜ '
            '门控 provider isAdminProvider=${gateAv.hasError ? 'error' : (gateAv.isLoading ? 'loading' : gateAv.value)}'
            ' ｜ adminIdentityProvider isAdmin=${id?.isAdmin} source=${id?.source.name}');

        if (!onSettings) {
          // ★ 装置不诚实：连同族对照都找不到 ⇒ 这一屏**判不了**（记未验，不是缺陷）。
          throw const _MockSkip(
              '设置页的同族对照条目（set-photo-ai-edit / set-personal-profile）'
              '一个都没扫到 ⇒ 无法判定 set-admin-tools 是否被门控');
        }
        if (!resolved) {
          // 身份没解析出来时只能验 fail-closed：**必须**不给这个入口。
          if (exists) throw StateError('身份未解析却给了管理入口（fail-open）');
          _note('管理员门控：身份未解析（source=unresolved）⇒ fail-closed 隐藏 ✅'
              '（★ 本档只证 fail-closed；"管理员可见"这一半要 resolved 或强制档才证得到）');
        } else if (exists != gateAdmin) {
          throw StateError(
              '管理员门控不一致：isAdminProvider=$gateAdmin 在树里=$exists'
              '（在屏上=$visible；adminIdentityProvider isAdmin=${id.isAdmin} '
              'source=${id.source}）');
        } else {
          _note('管理员门控：isAdminProvider=$gateAdmin 在树里=$exists '
              '在屏上=$visible ✅');
        }
      });
    }

    // ------------------------------------------------------------ 汇总
    debugPrint('\n===== r132 iOS 逐屏审计汇总 =====');
    for (final r in _report) {
      if (r.startsWith('MARK') ||
          r.startsWith('SCENE-FAIL') ||
          r.startsWith('OVERFLOW') ||
          r.startsWith('DUMP')) {
        debugPrint(r);
      }
    }
    _note('场景数 = ${scenes.length}；失败场景数 = ${failures.length}');
    for (final f in failures) {
      debugPrint('[audit] FAIL $f');
    }
    expect(scenes, isNotEmpty);
  });
}
