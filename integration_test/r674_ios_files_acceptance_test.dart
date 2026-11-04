// r674 **iOS 文件站闭环**装置（iPad 宽屏 + iPhone 窄屏 / 真 NAS 只读）。
//
// 为什么要这一支：r673 把宽屏文件站从"两级浏览器"改成 **Finder 列表 + 信息窗格**，
// 判据是**窗口宽度**（`appWindowSizeOf(...).isExpanded`，≥700pt），**没有平台门控**
// ⇒ iPad 竖屏 834pt、iPhone 横屏 ~844pt 都会走新的 `file-wide-*` 路径，
// 而这一版此前**只在 macOS 上验过**（`docs/platform-ios-ui-audit.md` 的台账停在 10-07，
// r666 的 78 屏是 10-26）⇒ iOS 这一格是**过期**的，本支就是来补这一格。
//
// 与 `r132_ios_ui_audit_test.dart` 共用同一套**宿主截图握手**：
//   * 用例只负责把界面导航到位、把界面名写进 `tmp/r132_ios_ui/req.txt`；
//   * 宿主 `tool/r132_ios_shot_poller.sh` 看到 req 就 `xcrun simctl io booted screenshot`
//     截**设备帧缓冲**（与宿主锁屏无关），再写 `ack.txt` 放行 ⇒ 1:1 确定性映射。
//
// 跑法（iPad Pro 11" M4 竖屏 834×1210 = 宽屏档）：
//   export PATH="<flutter-sdk>/bin:$PATH"
//   tool/r132_ios_shot_poller.sh com.openviewai.synhub.ios /tmp/r674_ios_ipad &
//   set -a; . /tmp/.synhub_nas_env; set +a
//   flutter test integration_test/r674_ios_files_acceptance_test.dart \
//     -d F256554B-41CE-45A0-8489-D8A4019D01DB --timeout 2400s \
//     --dart-define=SYNO_NAS_URL=https://nas.example.com:5001 \
//     --dart-define=SYNO_NAS_ACCOUNT=demo_user \
//     --dart-define=SYNO_NAS_PASSWORD="$SYNO_NAS_PASSWORD"
//
// 用法约定：
//   * `AUDIT_SCENES=s200,s204` 只跑某些场景（名字前缀匹配）；
//   * 口令**只从 `--dart-define` 来**，缺值直接报错退出（不许写死，§2.0.39）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/router/app_router.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/media/media_source.dart'
    show mediaNameWithoutExtension;
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
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
const String _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const String _onlyScenes = String.fromEnvironment('AUDIT_SCENES');

bool _wantScene(String name) =>
    _onlyScenes.isEmpty ||
    _onlyScenes.split(',').map((e) => e.trim()).any(name.startsWith);

final Directory _syncDir = Directory('${Directory.systemTemp.path}/r132_ios_ui')
  ..createSync(recursive: true);
File get _req => File('${_syncDir.path}/req.txt');
File get _ack => File('${_syncDir.path}/ack.txt');

final GlobalKey _rootKey = GlobalKey(debugLabel: 'r674-root');
final List<String> _report = <String>[];

void _note(String s) {
  _report.add(s);
  debugPrint('[ios674] $s');
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
  Duration timeout = const Duration(seconds: 60),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await tester.pump(const Duration(milliseconds: 64));
    await Future<void>.delayed(const Duration(milliseconds: 64));
  }
  throw StateError('等待超时：$label');
}

bool _hasKey(String k) => find.byKey(Key(k)).hitTestable().evaluate().isNotEmpty;
bool _hasKeyAny(String k) => find.byKey(Key(k)).evaluate().isNotEmpty;
bool _hasTextAny(String s) => find.text(s).evaluate().isNotEmpty;
bool _hasAnyKey(List<String> ks) => ks.any(_hasKeyAny);

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

/// 只在**左栏**（`file-wide-master`）里点那一行 —— 右栏信息卡里也有同名 `Text`，
/// 不限定子树就会点到信息卡上（§2.0.73 的仪器假红）。
Future<bool> _tapMasterRow(
  WidgetTester tester,
  String name, {
  int settle = 1200,
}) async {
  final row = find.descendant(
    of: find.byKey(const Key('file-wide-master')),
    matching: find.text(name),
  );
  if (row.evaluate().isEmpty) return false;
  await tester.ensureVisible(row.first);
  await _wait(tester, 150);
  await tester.tap(row.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// **真旋转**（r283 的 debug 钩子，`ios/Runner/AppDelegate.swift` 里
/// `synhub/test_orientation`）。`mask`：portrait=2、landscapeLeft=16、landscapeRight=32。
///
/// 为什么要走原生：iPad 上本 App 允许分屏（`Info.plist` 无 `UIRequiresFullScreen`）
/// ⇒ iPadOS **忽略** `SystemChrome.setPreferredOrientations` 的掩码，
/// 请求横屏后窗口仍是 834×1210（r283 实测）。
Future<bool> _rotate(WidgetTester tester, int mask) async {
  await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
  await _wait(tester, 500);
  Object? r;
  try {
    r = await _orientChannel.invokeMethod<bool>('rotate', {'mask': mask});
  } on Object catch (e) {
    _note('ROTATE-CHANNEL-FAIL $e');
    return false;
  }
  await _wait(tester, 2500);
  final sz = _logical(tester);
  _note('ROTATE mask=$mask ack=$r logical=${sz.width.round()}×${sz.height.round()}');
  return r == true;
}

const MethodChannel _orientChannel = MethodChannel('synhub/test_orientation');

/// 当前**真实**逻辑窗口尺寸（来自平台，不是测试注入）。
Size _logical(WidgetTester tester) =>
    tester.view.physicalSize / tester.view.devicePixelRatio;

bool get _wideNow => find.byKey(const Key('file-wide-region')).evaluate().isNotEmpty;

/// 在文件站里**打开一条 NAS 路径**（`dirs` 逐级；两种档位都覆盖）。
///
/// 宽屏：左栏点一下选中、再点一下进入（与用户手指同一套动作）；
/// 窄屏：单击即进入。两条都不是"直接改状态"，所以它验的是真交互。
Future<void> _openNasDir(WidgetTester tester, List<String> dirs) async {
  for (final d in dirs) {
    // 行可能在折线以下（`/home` 有十几项）⇒ 先在**当前档位的那一栏里**滚着找。
    Finder row = _wideNow
        ? find.descendant(
            of: find.byKey(const Key('file-wide-master')),
            matching: find.text(d),
          )
        : find.text(d);
    for (var i = 0; i < 12 && row.evaluate().isEmpty; i++) {
      final scroller = _wideNow
          ? find.descendant(
              of: find.byKey(const Key('file-wide-master')),
              matching: _vScroller,
            )
          : _vScroller;
      if (scroller.evaluate().isEmpty) break;
      await tester.drag(scroller.first, const Offset(0, -320));
      await _wait(tester, 800);
      row = _wideNow
          ? find.descendant(
              of: find.byKey(const Key('file-wide-master')),
              matching: find.text(d),
            )
          : find.text(d);
    }
    if (row.evaluate().isEmpty) {
      _note('DIAG 找不到 $d，当前可见文案 = ${_visibleTexts()}');
      throw StateError('列表里滚到底也没有这个目录：$d');
    }
    if (_wideNow) {
      await _enterWideRow(tester, d);
    } else {
      await tester.ensureVisible(row.first);
      await _wait(tester, 150);
      await tester.tap(row.first, warnIfMissed: false);
      await _wait(tester, 2500);
    }
    // 层级证据：进入任何一层之后都会出现「上一级」（r674 同一口径）
    await _waitFor(
      tester,
      '进入 $d（出现上一级入口）',
      () => _hasAnyKey(const ['file-breadcrumb-up', 'file-up', 'file-wide-up']),
      timeout: const Duration(seconds: 60),
    );
    _note('进入目录 $d（档位=${_wideNow ? '宽' : '窄'}）');
  }
}

/// **把播放器/预览路由全部关掉**，然后回到 `/home/Video` 目录。
///
/// ★ r675 的教训：上一版靠"点播放器顶栏返回 / 读 `media-video-surface` 判在不在
/// 播放器"两条判据 —— 而控件 4s 自动隐藏后 `media-video-surface` 会从树上消失，
/// 于是"还在播放器里"被误判成"已经在列表"，接着 tap 命中的是上一支视频的页面：
/// **三张截图一模一样**（mp4 的 `00:03/00:12` 一直挂在那里）。
/// 现在：直接 `Navigator.pop` 到 shell（最多 5 次），再用**列表证据**
/// （`file-wide-master` / `file-up` / `file-breadcrumb-up`）确认回来了。
Future<void> _resetToVideoDir(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    final onPreview = _hasAnyKey(const [
      'preview-video-stage',
      'preview-audio-stage',
      'media-top-bar',
      'media-video-surface',
    ]);
    if (!onPreview) break;
    final nav = Navigator.of(
      tester.element(find.byType(Scaffold).last),
      rootNavigator: true,
    );
    if (!nav.canPop()) break;
    nav.pop();
    await _wait(tester, 1500);
  }
  if (_hasAnyKey(const ['preview-video-stage', 'media-top-bar'])) {
    _note('DIAG 关不掉预览：texts=${_visibleTexts().take(8).toList()}');
    throw StateError('关不掉上一支视频的预览页');
  }
  // 确认脚下是文件站（底栏 Files），再逐级回到根、进 /home/Video
  await _toFileRoot(tester);
  await _openNasDir(tester, ['home', 'Video']);
}

/// **竖直**列表的 Scrollable。
///
/// 坑：文件页顶上有一层横向 `PageView`（`file-source-pager`），
/// `find.byType(Scrollable).first` 命中的就是它 —— 竖直拖它**纹丝不动**，
/// 于是"滚到底也没有 Video"这种假红（r675 实测踩到）。
Finder get _vScroller => find.byWidgetPredicate(
  (w) =>
      w is Scrollable &&
      (w.axisDirection == AxisDirection.down ||
          w.axisDirection == AxisDirection.up),
);

/// 失败诊断用：当前树上**看得见**的文案（前 40 条）。
List<String> _visibleTexts() {
  final out = <String>[];
  for (final e in find.byType(Text).evaluate()) {
    final d = (e.widget as Text).data;
    if (d != null && d.trim().isNotEmpty) out.add(d.trim());
    if (out.length >= 40) break;
  }
  return out;
}

/// 列表里找不到就**滚一滚再找**（"列表里没有"必须先滚到底，§2.0.47）。
Future<Finder?> _scrollToText(WidgetTester tester, String text) async {
  for (var i = 0; i < 12; i++) {
    final f = find.text(text);
    if (f.evaluate().isNotEmpty) return f;
    if (_vScroller.evaluate().isEmpty) return null;
    await tester.drag(_vScroller.first, const Offset(0, -320));
    await _wait(tester, 700);
  }
  final f = find.text(text);
  return f.evaluate().isEmpty ? null : f;
}

/// 打开当前目录里的某个**文件**（宽屏两下 / 窄屏一下），然后看落到了哪种舞台。
///
/// 返回 `'inline'`（内置播放器真的在）/ `'external'`（本机解不了 ⇒ 说明页 + 交系统应用）。
Future<String?> _openFileStage(
  WidgetTester tester,
  String name, {
  /// ★ r678（`DA311`）：这条必须由 **libmpv** 出画（`.mkv`/`.AVI`）。
  ///
  /// 为什么不能只看"surface ＋ 标题 ＋ 进度在涨"：iOS 上 `.AVI` 走 AVFoundation
  /// 时是**标题对、时钟在涨、画面全黑** —— 这正是 r676 `DA306` 那类假绿。
  /// 有了 `media-engine-mpv` 这个身份，才能断言"画是兜底引擎画的"。
  bool expectMpvEngine = false,
  /// ★ r676（`DA306`）：这条样本在 iOS 上**本机一定解不了**（`.mkv`/`.AVI`）。
  /// 判据因此收窄成"**有界时间内必须出现兜底面板**"：`inline` 在这条上不是成绩，
  /// 而是**上一版的假绿**（`media-top-title` 只要显示这条文件名就算 `inline`，
  /// 而黑屏页面同样有那条标题）。
  bool expectFallback = false,
}) async {
  final started = DateTime.now();
  if (_hasKeyAny('media-video-surface') ||
      _hasKeyAny('media-fallback-panel')) {
    throw StateError('还在上一个视频里（没回到目录就点开下一个 ⇒ 会假绿）');
  }
  // ★ 诊断（r675 现场）：预览页**自己认为**打开的是哪一条？
  void logPreviewEntry(String when) {
    final pages = find.byType(FilePreviewPage).evaluate().toList();
    final names = <String>[
      for (final e in pages) (e.widget as FilePreviewPage).entry.name,
    ];
    _note('PREVIEW[$when] pages=${pages.length} entry=$names');
  }

  final finder = await _scrollToText(tester, name);
  if (finder == null) throw StateError('目录里滚到底也没有：$name');
  _note('TAP 目标=$name');
  logPreviewEntry('tap 前');
  if (_wideNow) {
    await tester.ensureVisible(finder.first);
    await _wait(tester, 150);
    await tester.tap(finder.first, warnIfMissed: false);
    await _wait(tester, 120);
    await tester.tap(finder.first, warnIfMissed: false);
  } else {
    await tester.ensureVisible(finder.first);
    await _wait(tester, 150);
    await tester.tap(finder.first, warnIfMissed: false);
  }
  await _wait(tester, 1500);
  logPreviewEntry('tap 后 1.5s');
  await _wait(tester, 2500);
  // 判据三条缺一不可：
  //   ① `media-video-surface` 在（播放器画了画面舞台）；
  //   ② 顶栏标题**就是这条文件**（否则可能是上一支视频残留 —— r675 假绿）；
  //   ③ 不在"外部打开"说明页（`preview-video-stage` 但没 surface）。
  // ★ r678：顶栏标题是**去扩展名**的名字（`DA244`：`60招基础街球S01E01.AVI` →
  //   `60招基础街球S01E01`）⇒ 拿带扩展名的前 18 字去 `contains` 永远不成立，
  //   真播也会被判成 null（本轮 s242 的假红）。比对口径必须与顶栏同一份。
  final baseName = mediaNameWithoutExtension(name);
  final shortName = baseName.length > 18
      ? baseName.substring(0, 18)
      : baseName;
  // ★ r678：换引擎（AVFoundation → libmpv）之后顶栏会随控件一起隐藏 ⇒
  //   只看"此刻顶栏有没有这条标题"会把**真播**判成 null（本轮 s242 就是这么假红的）。
  //   判据改成"**曾经**见到过这条标题"，并且允许主动点一下画面把控件唤回来。
  var sawTitle = false;
  void noteTitle() {
    if (sawTitle) return;
    final titled = _hasTextAny('media-top-title')
        ? find
            .descendant(
              of: find.byKey(const Key('media-top-title')),
              matching: find.textContaining(shortName),
            )
            .evaluate()
            .isNotEmpty
        : _visibleTexts().any((t) => t.contains(shortName));
    if (titled) sawTitle = true;
  }
  // 60 × 500ms = 30s：iOS 上"一直 buffering"的判死窗口是 2 倍看门狗（30s），
  // 等不够就会把"刚要在 30s 给面板"误判成"永远不给"。
  for (var i = 0; i < 70; i++) {
    if (i % 14 == 0) {
      // 诊断：到底停在哪一屏（DA303 现场取证用；不打全树，只打关键 key 与可见文案）
      final keys = <String>[
        'media-video-surface',
        'media-top-bar',
        'media-top-title',
        'media-more',
        'media-fallback-panel',
        'preview-video-stage',
        'preview-office-native',
      ].where(_hasKeyAny).toList();
      _note('POLL${i ~/ 14} keys=$keys texts=${_visibleTexts().take(6).toList()}');
    }
    if (i == 1 || i == 4) {
      _note('TAP 后 i=$i title=${_visibleTexts().take(3).toList()}');
    }
    // ★ r676（`DA306`）：兜底面板 = **诚实回退**（原因 + 用其他应用打开/下载）
    if (_hasKeyAny('media-fallback-panel')) {
      final secs = DateTime.now().difference(started).inMilliseconds / 1000;
      _note('FALLBACK ${secs}s title=${_visibleTexts().take(4).toList()}');
      return 'fallback';
    }
    if (expectFallback) {
      // 这条本机解不了：`inline` 不接受（见函数头 `expectFallback` 注释）
      await _wait(tester, 500);
      continue;
    }
    if (_hasKeyAny('media-video-surface')) {
      noteTitle();
      if (!_hasKeyAny('media-top-bar') && !sawTitle) {
        // 控件隐藏中：点一下画面把它唤回来（顶栏标题是"条目身份"的唯一证据）
        await tester.tap(
          find.byKey(const Key('media-video-surface')).first,
          warnIfMissed: false,
        );
        await _wait(tester, 400);
        noteTitle();
      }
      if (sawTitle) {
      if (!expectMpvEngine) return 'inline';
      // 等兜底引擎接上（AVFoundation 判死 → dispose → 新建 mpv → 载入）
      if (_hasKeyAny('media-engine-mpv')) {
        _note('ENGINE mpv 已出画（${DateTime.now().difference(started).inMilliseconds}ms）');
        return 'inline';
      }
      // 还没换：继续等（不判死 —— 这一条的判据是"mpv 出画"）
    }
    } else if (_hasKeyAny('preview-video-stage')) {
      await _wait(tester, 600);
      if (!_hasKeyAny('media-video-surface')) return 'external';
      continue;
    }
    await _wait(tester, 500);
  }
  return null;
}

/// ★ r678（`DA311`）：**画面真的在动**吗 —— 读 `media-progress` 的 `posMs` 两次。
///
/// 为什么不能只看 `media-video-surface` 在树上：`.AVI` 在 r676 之前就是
/// "surface 在、标题对、零画面"（AVFoundation ready 但不出画）⇒ 只看 key 是假绿。
/// 这里钉两件事：① 控件条出来后进度**确实在涨**（≥500ms）；② 期间**没有**
/// 兜底面板、**没有** `media-no-picture-blackout`（那是"本条零画面"的盖黑证据）。
///
/// ⚠️ 进度在涨**不等于**像素在动（仍以截图判据为准，见 `docs/evidence-r678-ios/`）。
Future<int> _playingProgressMs(WidgetTester tester, String label) async {
  final surface = find.byKey(const Key('media-video-surface'));
  if (surface.evaluate().isEmpty) {
    throw StateError('$label 没有 media-video-surface（播不了）');
  }
  // ★ 控件条 3s 自动隐藏，而**点画面是"切换"**（第一下可能正好把刚弹出来的
  //   收掉）⇒ 反复"看—点—等"，直到 `media-progress` 出现（≤6 次 / ≈2.4s）。
  var slider = find.byKey(const Key('media-progress'));
  for (var i = 0; i < 6 && slider.evaluate().isEmpty; i++) {
    await tester.tap(surface.first, warnIfMissed: false);
    await _wait(tester, 400);
    slider = find.byKey(const Key('media-progress'));
  }
  if (slider.evaluate().isEmpty) {
    throw StateError('$label 控件条点不出来（读不到进度）');
  }
  final w = tester.widget<Slider>(slider.first);
  final ms = w.value.round();
  _note('PROGRESS[$label] posMs=$ms max=${w.max.round()}');
  return ms;
}

Future<void> _assertReallyPlaying(WidgetTester tester, String label) async {
  final before = await _playingProgressMs(tester, '$label-t0');
  await _wait(tester, 3000);
  final after = await _playingProgressMs(tester, '$label-t1');
  if (find.byKey(const Key('media-fallback-panel')).evaluate().isNotEmpty) {
    throw StateError('$label 播着播着出了兜底面板（引擎换了但没播成）');
  }
  if (find.byKey(const Key('media-no-picture-blackout')).evaluate().isNotEmpty) {
    throw StateError('$label 被判成"本条零画面"（盖黑在）—— 不是真播');
  }
  if (after - before < 500) {
    throw StateError('$label 3s 内进度只涨了 ${after - before}ms（<500ms）⇒ 没在播');
  }
  _note('PLAYING[$label] +${after - before}ms');
}

/// 宽屏"进入"：同一行**再点一次**（≤500 ms 的第二下 = 打开，DA298 的真机口径）。
/// 不用 `onDoubleTap`：widget 测试能量到、真机/模拟器点不出来（§2.0.73 的教训）。
Future<void> _enterWideRow(WidgetTester tester, String name) async {
  if (!await _tapMasterRow(tester, name, settle: 120)) {
    throw StateError('左栏没有行：$name');
  }
  await _tapMasterRow(tester, name, settle: 3000);
}

Future<void> _boot(WidgetTester tester) async {
  WidgetsFlutterBinding.ensureInitialized();
  // ★ r678（`DA311`）：装置要**和 `main()` 一样**先初始化 libmpv ——
  //   `SynologyChatApp` 是直接 build 的（不走 `main()`），少了这一步，
  //   兜底引擎一 `Player()` 就抛
  //   `MediaKit.ensureInitialized must be called before using any API`，
  //   整场景直接失败（本轮第一次跑就是这么红的：仪器前提缺一步，不是产品缺陷）。
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      MediaKit.ensureInitialized();
    } catch (e) {
      _note('MediaKit 初始化失败（视频退回主引擎）：$e');
    }
  }
  // ★ 与 r132 审计装置**同款开机**：`restoring` 的settle 依赖这几个初始化
  //   （少一个就会一直卡在 restoring=true ⇒ 首屏永远等不到，见本轮第一次跑）。
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

ProviderContainer? _container(WidgetTester tester) {
  final el = find.byType(SynologyChatApp);
  if (el.evaluate().isEmpty) return null;
  return ProviderScope.containerOf(tester.element(el.first), listen: false);
}

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

/// 登录（沿用 r132 的 s010–s013 手势：直连地址 → 证书信任 → 账密 → 能量核）。
Future<void> _ensureLoggedIn(
  WidgetTester tester,
  ProviderContainer container,
) async {
  if (container.read(sessionControllerProvider).loggedIn) {
    _note('静默重登：已登录，跳过登录 UI');
    return;
  }
  // 从 setup 子页回到 setup 主页
  // ★ 必须用 `rootNavigatorKey`：`SynologyChatApp` 自身**不在** Navigator 之下，
  //   拿它的 element 去 `Navigator.of` 会抛"context does not include a Navigator"
  //   （本轮第二次跑就是这么红的）。
  final nav = rootNavigatorKey.currentState;
  var guard = 0;
  while (!_hasTextAny('Connect to your NAS') && guard++ < 6) {
    if (nav == null || !nav.canPop()) break;
    nav.pop();
    await _wait(tester, 800);
  }
  // 直连地址
  final lan = find.byIcon(Icons.lan_outlined).hitTestable();
  if (lan.evaluate().isNotEmpty) {
    await tester.tap(lan.first, warnIfMissed: false);
    await _wait(tester, 600);
  }
  final tf = find.byType(TextField);
  if (tf.evaluate().isNotEmpty) {
    await tester.enterText(tf.first, _url);
    await _wait(tester, 400);
  }
  final orb0 = find.byType(EnergyOrb);
  if (orb0.evaluate().isNotEmpty) {
    await tester.tap(orb0.first, warnIfMissed: false);
  }
  // 证书信任
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.byType(AlertDialog).evaluate().isNotEmpty) break;
    if (container.read(sessionControllerProvider).connection != null) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (find.byType(AlertDialog).evaluate().isNotEmpty) {
    final ok = find.byType(FilledButton);
    if (ok.evaluate().isNotEmpty) {
      await tester.tap(ok.last, warnIfMissed: false);
    }
    await _wait(tester, 1200);
  }
  // 账密
  await _waitFor(
    tester,
    '进入登录页（≥2 个输入框）',
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
    timeout: const Duration(seconds: 150),
  );
  _note('登录成功 account=${container.read(sessionControllerProvider).session?.account}');
  await _wait(tester, 4000);
}

/// 切回 NAS files 源（否则一直在 "My Drive"）。
Future<void> _selectNasSource(WidgetTester tester) async {
  final f = find.text('NAS files').hitTestable();
  if (f.evaluate().isEmpty) return;
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, 1200);
}

/// 回到文件站**根目录**（宽屏窄屏都走 `file-breadcrumb-up`／`file-up` 两条 key）。
Future<void> _toFileRoot(WidgetTester tester) async {
  if (!await _tapKey(tester, 'dock-files', settle: 1800)) {
    throw StateError('底栏没有 Files');
  }
  await _wait(tester, 1200);
  await _selectNasSource(tester);
  for (var i = 0; i < 10; i++) {
    if (_hasKey('file-breadcrumb-up')) {
      if (!await _tapKey(tester, 'file-breadcrumb-up', settle: 1400)) break;
      continue;
    }
    if (_hasKey('file-up')) {
      if (!await _tapKey(tester, 'file-up', settle: 1400)) break;
      continue;
    }
    break;
  }
  await _waitFor(
    tester,
    '文件根目录',
    () => !_hasKey('file-breadcrumb-up') && !_hasKey('file-up'),
    timeout: const Duration(seconds: 60),
  );
  await _wait(tester, 1200);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r674 iOS 文件站闭环（宽屏信息窗格 / 窄屏返回）', (tester) async {
    if (_password.isEmpty) {
      fail('SYNO_NAS_PASSWORD 未提供：口令只许从 --dart-define 来（§2.0.39）');
    }
    final failures = <String>[];
    final scenes = <String>[];

    Future<void> scene(String name, Future<void> Function() body) async {
      if (!_wantScene(name)) return;
      scenes.add(name);
      try {
        await body();
        await _wait(tester, 500);
        await _mark(tester, name);
        var n = 0;
        var ex = tester.takeException();
        while (ex != null && n < 40) {
          n++;
          if (n == 1) {
            _note('EXC $name: ${'$ex'.split('\n').take(6).join(' ⏎ ')}');
          }
          ex = tester.takeException();
        }
        if (n > 0) _note('OVERFLOW $name: $n 个异常');
      } catch (e) {
        failures.add('$name: ${'$e'.split('\n').first}');
        _note('SCENE-FAIL $name: $e');
        try {
          await _mark(tester, '${name}__FAIL');
        } catch (_) {}
      }
    }

    _note('截图握手目录 = ${_syncDir.path}');
    _note('目标 NAS = $_url 账号=$_account');
    try {
      _ack.deleteSync();
    } catch (_) {}
    try {
      _req.deleteSync();
    } catch (_) {}

    await _boot(tester);
    final container = _container(tester)!;
    await _waitFor(
      tester,
      'restore 结束',
      () => !container.read(sessionControllerProvider).restoring,
      timeout: const Duration(seconds: 90),
    );
    await _ensureLoggedIn(tester, container);
    await _toFileRoot(tester);

    final wide = _hasKeyAny('file-wide-region');
    _note('本轮窗口档位 = ${wide ? '宽屏（走 file-wide-*）' : '窄屏'}');

    if (wide) {
      // ---- s199：宽屏根目录（左栏列表 + 右栏空态）
      await scene('s199_wide_root', () async {
        expect(_hasKeyAny('file-wide-master'), isTrue,
            reason: '宽屏必须有左栏 file-wide-master');
        expect(_hasKeyAny('file-wide-empty'), isTrue,
            reason: '未选中时右栏应是空态');
      });

      // ---- s200：单击一行 ⇒ 选中 + 信息卡（不是进入）
      await scene('s200_wide_select_home', () async {
        if (!await _tapMasterRow(tester, 'home')) {
          throw StateError('左栏根目录没有 home 行');
        }
        await _waitFor(
          tester,
          '右栏出信息卡',
          () => _hasKeyAny('file-wide-detail'),
          timeout: const Duration(seconds: 20),
        );
        expect(_hasKeyAny('file-wide-open'), isTrue,
            reason: 'DA299：信息卡必须给一个显式的打开出口');
        // 单击**不许**进入（否则又变回"两跳/中间页"的旧毛病）
        expect(_hasKeyAny('file-wide-empty'), isFalse,
            reason: '选中后不该还是空态');
        expect(_hasTextAny('Shared folders'), isTrue,
            reason: '单击后仍应停在根目录（面包屑不变）');
        _note('s200 单击后：信息卡在，面包屑仍在根（单击只选中）');
      });

      // ---- s201：信息卡的「打开文件夹」 ⇒ 进入 /home
      await scene('s201_wide_open_folder', () async {
        if (!await _tapKey(tester, 'file-wide-open', settle: 4000)) {
          throw StateError('信息卡没有 file-wide-open');
        }
        await _waitFor(
          tester,
          '进入 /home（左栏有 Download 行）',
          () => _hasTextAny('Download') || _hasTextAny('Drive'),
          timeout: const Duration(seconds: 60),
        );
        expect(_hasKeyAny('file-wide-detail'), isFalse,
            reason: '进入目录后右栏应回到空态（选中已清）');
        _note('s201 「打开文件夹」进入 /home，右栏回空态');
      });

      // ---- s202：/home 里单击 Download ⇒ 信息卡（类型/项数/路径）
      await scene('s202_wide_inspector_folder', () async {
        if (!await _tapMasterRow(tester, 'Download')) {
          throw StateError('/home 左栏没有 Download 行');
        }
        await _waitFor(
          tester,
          'Download 信息卡',
          () => _hasKeyAny('file-wide-detail'),
          timeout: const Duration(seconds: 20),
        );
        expect(_hasTextAny('/home/Download'), isTrue,
            reason: '信息卡必须给出路径（回答"这是哪个东西"）');
        _note('s202 Download 信息卡：路径 /home/Download 已显示');
      });

      // ---- s203：右栏 ✕ ⇒ 回空态（不留一张清不掉的卡）
      await scene('s203_wide_close_inspector', () async {
        if (!await _tapKey(tester, 'file-wide-close', settle: 1500)) {
          throw StateError('信息卡没有 ✕（file-wide-close）');
        }
        expect(_hasKeyAny('file-wide-empty'), isTrue,
            reason: 'DA300：✕ 必须能清掉右栏');
        expect(_hasKeyAny('file-wide-detail'), isFalse,
            reason: 'DA300：清掉后不许还留着信息卡');
        _note('s203 ✕ 之后右栏回空态');
      });

      // ---- s204：双击（同一行再点一次）直接进入，不用再按按钮
      await scene('s204_wide_double_tap_enter', () async {
        await _enterWideRow(tester, 'Download');
        await _waitFor(
          tester,
          '进入 /home/Download',
          () => _hasKey('file-breadcrumb-up'),
          timeout: const Duration(seconds: 60),
        );
        // ★ 判据钉**面包屑最后一段 = Download**（不是 `find.text('/home/Download')`：
        //   进入后右栏是空态，那条路径文本只出现在信息卡里 ⇒ 拿它判据会假红，
        //   本轮第一次跑就是这样 —— 像素 006 里面包屑已经是 `home › Download`）。
        final crumbs = find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('file-crumb-'),
        );
        expect(crumbs.evaluate().length, greaterThan(0),
            reason: '进入后应有面包屑段');
        expect(_hasTextAny('Download'), isTrue,
            reason: 'DA298：再点一次必须真的进入该目录（面包屑末段 = Download）');
        expect(_hasKeyAny('file-wide-detail'), isFalse,
            reason: '进入目录后右栏不该还留着信息卡');
        _note('s204 双击/再点一次进入 /home/Download');
      });

      // ---- s205：左栏面包屑「上一级」回到 /home
      await scene('s205_wide_up', () async {
        if (!await _tapKey(tester, 'file-breadcrumb-up', settle: 3000)) {
          throw StateError('没有 file-breadcrumb-up');
        }
        await _waitFor(
          tester,
          '回到 /home',
          () => _hasTextAny('/home') || _hasTextAny('Download'),
          timeout: const Duration(seconds: 60),
        );
        _note('s205 左栏「上一级」回到 /home');
      });
    } else {
      // ---- 窄屏：单击一行 = 进入（旧的单栏路径，r673 一字未改）
      await scene('s210_narrow_root', () async {
        expect(_hasKeyAny('file-wide-region'), isFalse,
            reason: '窄屏不许出现宽屏右栏');
        expect(_hasTextAny('Shared folders'), isTrue,
            reason: '根目录应有 Shared folders 段');
      });
      await scene('s211_narrow_enter_home', () async {
        final f = find.text('home').hitTestable();
        if (f.evaluate().isEmpty) throw StateError('窄屏根目录没有 home 行');
        await tester.tap(f.first, warnIfMissed: false);
        await _waitFor(
          tester,
          '进入 /home（窄屏）',
          () => _hasKey('file-up') || _hasKey('file-breadcrumb-up'),
          timeout: const Duration(seconds: 60),
        );
        _note('s211 窄屏单击进入 /home，出现返回入口');
      });
      await scene('s212_narrow_back', () async {
        final up = _hasKey('file-breadcrumb-up')
            ? 'file-breadcrumb-up'
            : 'file-up';
        if (!await _tapKey(tester, up, settle: 3000)) {
          throw StateError('窄屏没有返回入口（DA291 不许复发）');
        }
        await _waitFor(
          tester,
          '窄屏回到根',
          () => !_hasKey('file-up') && !_hasKey('file-breadcrumb-up'),
          timeout: const Duration(seconds: 60),
        );
        _note('s212 窄屏返回根目录');
      });
    }

    // ================================================== r675：横屏 / 键盘 / 视频
    //
    // 这一组是"iOS 上还能闭的环"（r675）：**iPhone 横屏 844×390 也是 expanded**
    // （断点 700，无平台门控）⇒ 宽屏文件站在手机上横过来就走 `file-wide-*`，
    // 而 r674 只验了竖屏。旋转走 r283 的 debug 原生钩子（iPad 会忽略方向掩码）。

    await scene('s230_land_rotate', () async {
      // ★ r675（iOS）：iPad 上原生 `requestGeometryUpdate` 会被系统拒绝
      //   （`UISceneErrorDomain`："The current windowing mode does not allow for
      //   programmatic changes to interface orientation"）—— iPadOS 多窗口模式不许
      //   程序改方向。所以这里**判据落"现在是不是横屏"**，不落"钩子有没有 ack"：
      //   宿主侧用 `osascript` 把模拟器旋转过也能进入同一场景（真机同理，用户自己转）。
      final acked = await _rotate(tester, 16);
      final sz = _logical(tester);
      if (sz.width <= sz.height) {
        throw StateError(
          '旋转后仍是竖屏：${sz.width.round()}×${sz.height.round()}'
          '（钩子 ack=$acked；iPad 需从宿主侧旋转）',
        );
      }
      _note('s230 旋转来源 = ${acked ? '原生钩子' : '宿主/用户已横屏'}');
      _note('s230 横屏逻辑尺寸 = ${sz.width.round()}×${sz.height.round()}'
          '（≥700 ⇒ 宽屏档）');
    });

    await scene('s231_land_wide_root', () async {
      await _toFileRoot(tester);
      if (!_wideNow) {
        throw StateError(
          '横屏（${_logical(tester).width.round()}pt）没有进宽屏档：'
          'file-wide-region 不在树里',
        );
      }
      expect(_hasKeyAny('file-wide-master'), isTrue);
      expect(_hasKeyAny('file-wide-empty'), isTrue, reason: '未选中时右栏是空态');
      // `DA302` 的真机读数：右栏到底有多高（决定空态走紧凑档的阈值）
      final region = tester.getRect(find.byKey(const Key('file-wide-region')));
      final empty = tester.getRect(find.byKey(const Key('file-wide-empty')));
      _note('s231 右栏 region=${region.width.round()}×${region.height.round()}'
          ' · 空态区=${empty.height.round()}pt');
      _note('s231 横屏宽屏根目录：左栏 + 空态右栏');
    });

    await scene('s232_land_enter_by_keyboard', () async {
      // 单击只选中（不许进），再用**硬件键盘 Enter** 打开 —— `DA301` 的判据。
      if (!await _tapMasterRow(tester, 'home', settle: 1200)) {
        throw StateError('左栏没有 home 行');
      }
      await _waitFor(
        tester,
        '右栏出信息卡',
        () => _hasKeyAny('file-wide-detail'),
        timeout: const Duration(seconds: 20),
      );
      expect(_hasTextAny('Shared folders'), isTrue, reason: '单击不许进入（仍是根）');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _waitFor(
        tester,
        'Enter 打开 /home',
        () => _hasKeyAny('file-crumb-1') || _hasTextAny('Download'),
        timeout: const Duration(seconds: 30),
      );
      _note('s232 Enter 打开了 /home（硬件键盘与双击同一条路）');
    });

    await scene('s233_land_esc_closes_inspector', () async {
      final dir = _wideNow ? 'Download' : 'Drive';
      final finder = await _scrollToText(tester, dir);
      if (finder == null) throw StateError('列表里没有 $dir');
      await tester.tap(finder.first, warnIfMissed: false);
      await _waitFor(
        tester,
        '右栏出信息卡',
        () => _hasKeyAny('file-wide-detail'),
        timeout: const Duration(seconds: 20),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _waitFor(
        tester,
        'Esc 关信息卡',
        () => _hasKeyAny('file-wide-empty'),
        timeout: const Duration(seconds: 20),
      );
      // Esc 只关信息卡，不许退出目录（面包屑还在 /home）
      expect(_hasTextAny('Download'), isTrue, reason: 'Esc 不该换目录');
      _note('s233 Esc 清空右栏，目录没动');
    });

    await scene('s234_land_back_portrait_keeps_path', () async {
      if (!await _rotate(tester, 2)) {
        throw StateError('转回竖屏失败');
      }
      final sz = _logical(tester);
      if (sz.width >= sz.height) {
        throw StateError('转回后仍是横屏：${sz.width.round()}×${sz.height.round()}');
      }
      await _wait(tester, 2000);
      if (_wideNow && sz.width < 700) {
        throw StateError('竖屏（${sz.width.round()}pt）不该还有宽屏右栏');
      }
      // 关键：旋转**不该把用户从当前目录踢回根**（r671 的"中间页"教训）
      final inHome = _hasAnyKey(const [
        'file-breadcrumb-up',
        'file-up',
        'file-wide-up',
      ]);
      expect(inHome, isTrue, reason: '旋转后必须还停在 /home（有"上一级"入口）');
      _note('s234 转回竖屏：档位=${_wideNow ? '宽' : '窄'}，仍在 /home');
    });

    // ---------------------------------------------------------------- 视频
    // 真 NAS `/home/Video` 实测三件样本（r675）：
    //   mp4（H.264，AVFoundation 能解）/ mkv / avi（iOS 只能交给系统应用）。
    // 判据不是"能不能播所有格式"，而是：**能播的真播、不能播的说清原因**，
    // 两态都不许是"黑屏 / 没反应"。
    await scene('s240_video_mp4_inline', () async {
      await _resetToVideoDir(tester);
      final stage = await _openFileStage(
        tester,
        '01_1._The_Rate_of_Chemical_Reactions__10-12.mp4',
      );
      _note('s240 mp4 舞台 = $stage');
      if (_hasKeyAny('media-engine-mpv')) {
        throw StateError('mp4 不该换到 libmpv（AVFoundation 本来就解得了）');
      }
      if (stage != 'inline') {
        throw StateError('mp4 在 iOS 上必须能内置播放（AVFoundation 支持 H.264），'
            '实际=$stage');
      }
    });

    // ★ r678（`DA311`）：`.mkv` 在 iOS 上**必须真播** —— 主引擎（AVFoundation）
    // 报 `-11828` 后由 libmpv 兜底引擎重开同一个文件。
    // 判据三层缺一不可：surface ＋ 标题是这条 ⇒ 进度在涨 ⇒ 没有兜底面板/盖黑。
    await scene('s241_video_mkv_libmpv', () async {
      await _resetToVideoDir(tester);
      final stage = await _openFileStage(
        tester,
        'Citizen Kane (1941).mkv',
        expectMpvEngine: true,
      );
      _note('s241 mkv 舞台 = $stage（r678 起应为 inline：libmpv 兜底）');
      if (stage != 'inline') {
        throw StateError('mkv 没播出画面（实际=$stage）：libmpv 兜底没接上（DA311）');
      }
      await _assertReallyPlaying(tester, 's241-mkv');
      await _mark(tester, 's241_video_mkv_libmpv_playing');
      // 第二张：再跑 3s 后取，证明"不是一张静止的帧"
      await _wait(tester, 3000);
      await _mark(tester, 's241_video_mkv_libmpv_later');
    });

    // ★ r678（`DA311`）：`.AVI` 同理（r676 时是"ready 但零画面"⇒ 3×5s 判死出面板）。
    await scene('s242_video_avi_libmpv', () async {
      await _resetToVideoDir(tester);
      final stage = await _openFileStage(
        tester,
        '60招基础街球S01E01.AVI',
        expectMpvEngine: true,
      );
      _note('s242 avi 舞台 = $stage（r678 起应为 inline：libmpv 兜底）');
      if (stage != 'inline') {
        throw StateError('avi 没播出画面（实际=$stage）：libmpv 兜底没接上（DA311）');
      }
      await _assertReallyPlaying(tester, 's242-avi');
      await _mark(tester, 's242_video_avi_libmpv_playing');
      await _wait(tester, 3000);
      await _mark(tester, 's242_video_avi_libmpv_later');
    });

    _note('场景数 = ${scenes.length} · 失败场景数 = ${failures.length}');
    for (final f in failures) {
      _note('FAIL $f');
    }
    expect(failures, isEmpty, reason: '文件站闭环有失败场景');
  });
}
