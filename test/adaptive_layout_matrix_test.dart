// 折叠屏 / Pad / iPad 适配**测试矩阵**（r283；r293 随阈值 840→700 同步改判）。
//
// 覆盖（逐条对应任务表的场景）：
//
// | 场景 | 逻辑尺寸(dp) | 本仓裁定 | 断言 |
// |---|---|---|---|
// | 折叠**外屏** | 320×780 | compact(<600) | 单列；`note-wide-detail` 不在树里；0 布局异常 |
// | 折叠**内屏**（展开）竖 | 673×841 | **medium**(600–699) | 单列（★ 断点裁定见下）；0 布局异常 |
// | 折叠**半折** | 673×841 + 合成 fold 竖带 34dp | 折痕**优先于**断点 | 可点元素矩形与折痕带**不相交** |
// | Pad 竖 | 768×1024 | **expanded**(>=700，r293 起) | **双栏**；0 布局异常 |
// | Pad 横 | 1024×768 | expanded(>=700) | 双栏：两区域同在屏内、不重叠；点行**不推路由** |
// | 分屏一半 | 507×1024 | compact | 单列；不溢出、不重叠 |
// | 桌面 | 800×600 | **expanded**(>=700，r293 起) | **双栏**；窄屏推路由由 673×841 档覆盖 |
// | ★ Mate X2 内屏**竖** | 676.923×763.077 | medium（真机实测） | 单列 |
// | ★ Mate X2 内屏**横** | 763.077×676.923 | expanded（真机实测） | 双栏 |
//
// ★ **r293 阈值调整（840 → 700）**：断点不再是 Material 3 的 600/840，而是本仓
//   自己的 **600/700**（理由 + 真机取证见 `lib/src/core/ui/adaptive_layout.dart`
//   文件头 §一 与 `docs/device-verification.md` 的 r293 一节）。直接后果：
//   744/768/800/820/834 这几档**由 medium 改判 expanded（双栏）**；而 673
//   （折叠内屏竖）与 676.923（Mate X2 内屏竖）**仍留 medium（单列）** ——
//   这正是取 700 而不是 660 的理由（660 会把 676.923 也推进双栏）。
//
// ★ **Pad 竖 768×1024 的改判要写清**：r283 的旧注释写"任务表把 Pad 竖标成
//   expanded，但给定断点 600–840 ⇒ 只能 medium"。r293 起断点是 **600/700**，
//   768 ≥ 700 ⇒ **expanded ⇒ 双栏**，与任务表的箭头重新一致。旧注释里那句
//   "与任务表的差异"**不再成立**，已删除（不留历史说辞，见 §2.0.26）。
//
// 折痕用**合成** `DisplayFeature` 注入（不依赖真机；真机折叠屏本机没有）——
// 注入路径与真机完全一致：`MediaQueryData.displayFeatures` 就是
// `WidgetsBinding` 从 `FlutterView.displayFeatures` 原样搬过来的
// （Flutter 3.47.4 `media_query.dart:335`）。
//
// ★ 平台事实（已取证，见 `adaptive_layout.dart` 文件头 §二）：`displayFeatures`
//   **只在 Android 被填充**（`window.dart:318` 原文），iOS/iPadOS 恒为空列表
//   ⇒ 本文件的折痕分支在 iPad 上是空操作；iPad 的适配走的是**断点双栏**。
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/ui/adaptive_layout.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_view_page.dart';
import 'package:synhub/src/features/notes/note_widgets.dart' show NoteRow;
import 'package:synhub/src/features/notes/notes_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

// ---------------------------------------------------------------- 场景常量

/// 折叠**外屏**（如 Galaxy Z Flip 外屏、副屏）
const kFoldOuter = Size(320, 780);

/// 折叠**内屏**（Galaxy Z Fold 内屏 ≈ 673×841 dp）
const kFoldInner = Size(673, 841);

/// 半折时折痕的合成带宽（dp）—— 取官方 Layoutlib 常见值 34
const double kFoldBandWidth = 34;

/// 折痕左边缘 x：673 宽居中放一条 34dp 带 ⇒ 左 319.5 / 右 319.5
const double kFoldBandLeft = (673 - kFoldBandWidth) / 2;

/// Pad 竖 / Pad 横
const kPadPortrait = Size(768, 1024);
const kPadLandscape = Size(1024, 768);

/// iPad Pro 11" 横屏（1194×834 pt）—— 真机逻辑尺寸，佐证双栏在 iPad 上也会触发
const kIpadPro11Landscape = Size(1194, 834);

/// 分屏一半（Pad 竖屏对半分）
const kSplitHalf = Size(507, 1024);

/// 桌面窗口（既有测试窗口）—— r293 起 800 ≥ 700 ⇒ **expanded（双栏）**。
const kDesktop = Size(800, 600);

/// ★ 真机 **HUAWEI Mate X2（TET-AN00）内屏**的运行时 `MediaQuery` 逻辑尺寸。
///
/// 内屏 2480×2200 @520dpi、dpr 3.25（r292 逐位实测）：
///   竖屏 = 2200/3.25 × 2480/3.25 = **676.923 × 763.077**
///   横屏 = 2480/3.25 × 2200/3.25 = **763.077 × 676.923**
/// 这两个数**必须逐位保留**（写成算式而不是四舍五入的 676.9/763.1）。
const double kMateX2DpShort = 2200 / 3.25; // 676.9230769…
const double kMateX2DpLong = 2480 / 3.25; // 763.0769230…

/// Mate X2 内屏**竖屏**（676.923 宽 ⇒ medium ⇒ **单列**）。
const kMateX2Portrait = Size(kMateX2DpShort, kMateX2DpLong);

/// Mate X2 内屏**横屏**（763.077 宽 ⇒ expanded ⇒ **双栏**）。
const kMateX2Landscape = Size(kMateX2DpLong, kMateX2DpShort);

const _noteTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.NoteStation.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

// ---------------------------------------------------------------- 测试装置

Map<String, dynamic> _noteJson(String id, String title) => {
  'object_id': id,
  'title': title,
  'parent_id': 'nb1',
  'brief': 'brief-$id',
  'content': '<p>body-$id</p>',
  'has_content': true,
  'mtime': 1700000000,
  'ctime': 1690000000,
  'ver': '1.0',
  'recycle': false,
  'encrypt': false,
  'tags': <String>[],
};

/// 合成本轮折痕（竖向 `fold`，半折姿态）。
ui.DisplayFeature _foldBand() => ui.DisplayFeature(
  bounds: const Rect.fromLTWH(kFoldBandLeft, 0, kFoldBandWidth, 841),
  type: ui.DisplayFeatureType.fold,
  state: ui.DisplayFeatureState.postureHalfOpened,
);

/// 合成横向铰链带（横折），用来覆盖 `horizontalObstructingBand` 分支。
ui.DisplayFeature _hingeBandHorizontal() => ui.DisplayFeature(
  bounds: const Rect.fromLTWH(0, 400, 673, 40),
  type: ui.DisplayFeatureType.hinge,
  state: ui.DisplayFeatureState.postureHalfOpened,
);

/// 合成挖孔 —— **不**参与避让（`cutout` 已被 `MediaQuery.padding` 处理）。
ui.DisplayFeature _cutout() => ui.DisplayFeature(
  bounds: const Rect.fromLTWH(300, 0, 40, 40),
  type: ui.DisplayFeatureType.cutout,
  state: ui.DisplayFeatureState.unknown,
);

Future<({FakeTransport t, ProviderContainer c})> _boot() async {
  final t = FakeTransport({
    'SYNO.NoteStation.Note.list': {
      'total': 2,
      'notes': [
        _noteJson('n1', '对齐会议'),
        _noteJson('n2', '购物清单'),
      ],
    },
    'SYNO.NoteStation.Notebook.list': {
      'notebooks': [
        {'object_id': 'nb1', 'title': 'NB1', 'ver': 'v1'},
      ],
    },
    'SYNO.NoteStation.Note.get': {'note': _noteJson('n1', '对齐会议')},
  }, {...FakeTransport.table, ..._noteTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final c = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(NoteStationApi(api)),
      chatDatabaseProvider.overrideWithValue(db),
    ],
  );
  addTearDown(c.dispose);
  return (t: t, c: c);
}

/// 把测试窗口固定成 [size]（dpr=1 ⇒ 逻辑尺寸 = 传入尺寸），并注入合成折痕。
void _view(
  WidgetTester tester,
  Size size, {
  List<ui.DisplayFeature> features = const <ui.DisplayFeature>[],
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _injectedFeatures = features;
}

List<ui.DisplayFeature> _injectedFeatures = const <ui.DisplayFeature>[];

Widget _app(ProviderContainer c, Widget home) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(
    theme: AppTheme.dark(),
    localizationsDelegates: const [
      FlutterQuillLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: FlutterQuillLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(displayFeatures: _injectedFeatures),
      child: child ?? const SizedBox.shrink(),
    ),
    home: home,
  ),
);

Future<void> _pumpNotes(
  WidgetTester tester,
  ProviderContainer c,
) async {
  await tester.pumpWidget(_app(c, const NotesPage()));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pump(const Duration(milliseconds: 400));
  _drain(tester);
}

List<FlutterErrorDetails> _capture() {
  final out = <FlutterErrorDetails>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (d) {
    out.add(d);
    prev?.call(d);
  };
  addTearDown(() => FlutterError.onError = prev);
  return out;
}

void _drain(WidgetTester tester) {
  var n = 0;
  while (n < 60 && tester.takeException() != null) {
    n++;
  }
}

/// 断言"本轮 0 布局异常"（溢出 / unbounded / not laid out 全算）。
void _expectNoLayoutError(String what, List<FlutterErrorDetails> captured) {
  if (captured.isEmpty) return;
  fail(
    '$what：出现 ${captured.length} 条布局异常，首条：'
    '${captured.first.exception.toString().split('\n').first}',
  );
}

/// 所有**可点元素**的全局矩形（折痕不相交判据的输入）。
///
/// 覆盖：`IconButton`（AppBar 动作 / 折叠菜单）、`NoteRow`（列表行）、
/// `FloatingActionButton`（新建）、`InkWell`（行内/胶囊的点击面）、
/// `TextField`（搜索框）。`find.byType(InkWell)` 会与 `NoteRow` 内部重复，
/// 这里**不去重** —— 多量一遍只会让判据更严，不会放行。
List<Rect> _clickableRects(WidgetTester tester) {
  final out = <Rect>[];
  for (final f in <Finder>[
    find.byType(IconButton),
    find.byType(NoteRow),
    find.byType(FloatingActionButton),
    find.byType(InkWell),
    find.byType(TextField),
  ]) {
    for (final e in f.evaluate()) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize && ro.size.width > 0 && ro.size.height > 0) {
        out.add(ro.localToGlobal(Offset.zero) & ro.size);
      }
    }
  }
  return out;
}

void main() {
  // ══════════════════════════════════════════════════ §1 断点纯函数（机制量）
  group('§1 尺寸分级纯函数（断点 = 600 / 700）', () {
    test('compact / medium / expanded 三档边界（含 ±0.5 与 699/700 成对取样）', () {
      expect(appWindowSizeOf(const Size(599.5, 800)), AppWindowSize.compact);
      expect(appWindowSizeOf(const Size(600, 800)), AppWindowSize.medium);
      // ★ 成对边界：699 ⇒ medium、700 ⇒ expanded（**同一断点两侧各一条**）
      expect(appWindowSizeOf(const Size(699, 800)), AppWindowSize.medium);
      expect(appWindowSizeOf(const Size(699.5, 800)), AppWindowSize.medium);
      expect(appWindowSizeOf(const Size(700, 800)), AppWindowSize.expanded);
      // 上界常量本身必须就是 700（防止"断言对了但常量又飘了"）
      expect(kAppWindowCompactMax, 600.0);
      expect(kAppWindowMediumMax, 700.0);
    });

    test('★ 真机 HUAWEI Mate X2 内屏两个朝向（逐位实测值，成对裁定）', () {
      // 竖 676.923 < 700 ⇒ medium（单列）
      expect(appWindowSizeOf(kMateX2Portrait), AppWindowSize.medium);
      expect(kMateX2Portrait.width, closeTo(676.923, 0.001));
      // 横 763.077 >= 700 ⇒ expanded（双栏）
      expect(appWindowSizeOf(kMateX2Landscape), AppWindowSize.expanded);
      expect(kMateX2Landscape.width, closeTo(763.077, 0.001));
      // 成对：同一台机器的两个朝向必须给出**不同**裁定，否则"降阈值"没意义
      expect(
        appWindowSizeOf(kMateX2Portrait),
        isNot(appWindowSizeOf(kMateX2Landscape)),
        reason: 'Mate X2 竖屏必须单列、横屏必须双栏（这是本轮降阈值的唯一目标）',
      );
    });

    test('矩阵七行的分级裁定（这台设备到底该单列还是双栏）', () {
      expect(appWindowSizeOf(kFoldOuter), AppWindowSize.compact);
      expect(appWindowSizeOf(kFoldInner), AppWindowSize.medium);
      // ★ r293：768（Pad 竖）与 800（桌面）由 medium 改判 expanded
      expect(appWindowSizeOf(kPadPortrait), AppWindowSize.expanded);
      expect(appWindowSizeOf(kPadLandscape), AppWindowSize.expanded);
      expect(appWindowSizeOf(kIpadPro11Landscape), AppWindowSize.expanded);
      expect(appWindowSizeOf(kSplitHalf), AppWindowSize.compact);
      expect(appWindowSizeOf(kDesktop), AppWindowSize.expanded);
    });

    test('只有 expanded 支持双栏', () {
      expect(AppWindowSize.compact.supportsTwoPane, isFalse);
      expect(AppWindowSize.medium.supportsTwoPane, isFalse);
      expect(AppWindowSize.expanded.supportsTwoPane, isTrue);
    });
  });

  // ══════════════════════════════════════════════════ §2 折痕带筛选（纯函数）
  group('§2 折痕带筛选：fold/hinge 避让，cutout 不避让', () {
    test('竖向 fold 命中；cutout 不命中', () {
      expect(verticalObstructingBand([_foldBand()], kFoldInner), isNotNull);
      expect(verticalObstructingBand([_cutout()], kFoldInner), isNull);
      expect(
        horizontalObstructingBand([_hingeBandHorizontal()], kFoldInner),
        isNotNull,
      );
    });

    test('横向带不会被当成竖向带（两个函数互不串台）', () {
      expect(verticalObstructingBand([_hingeBandHorizontal()], kFoldInner), isNull);
      expect(horizontalObstructingBand([_foldBand()], kFoldInner), isNull);
    });

    test('rectHitsBands：压线相交为真、贴边为假', () {
      const band = Rect.fromLTWH(300, 0, 34, 800);
      expect(rectHitsBands(const Rect.fromLTWH(310, 100, 10, 10), [band]), isTrue);
      expect(rectHitsBands(const Rect.fromLTWH(0, 100, 300, 10), [band]), isFalse);
      expect(rectHitsBands(const Rect.fromLTWH(334, 100, 10, 10), [band]), isFalse);
    });
  });

  // ══════════════════════════════════════════════════ §3 逐场景
  group('§3 折叠外屏 320×780（compact）', () {
    testWidgets('单列：只有 master 区域，右栏根本不在树里；0 布局异常', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kFoldOuter);
      await _pumpNotes(tester, b.c);
      expect(find.byKey(const Key('note-wide-master')), findsOneWidget);
      expect(
        find.byKey(const Key('note-wide-detail')),
        findsNothing,
        reason: 'compact（320 < 600）必须单列',
      );
      expect(find.byKey(const Key('note-row-n1')), findsOneWidget);
      _expectNoLayoutError('折叠外屏 320×780', cap);
    });
  });

  group('§3 折叠内屏 673×841（medium）', () {
    testWidgets('按断点（600–699）= medium ⇒ 单列', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kFoldInner);
      await _pumpNotes(tester, b.c);
      expect(appWindowSizeOf(kFoldInner), AppWindowSize.medium);
      expect(find.byKey(const Key('note-wide-master')), findsOneWidget);
      expect(find.byKey(const Key('note-wide-detail')), findsNothing);
      _expectNoLayoutError('折叠内屏 673×841', cap);
    });
  });

  group('§3 折叠半折 673×841 + 合成 fold（竖带 34dp）', () {
    testWidgets('可点元素矩形与折痕带不相交（折痕优先于断点）', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kFoldInner, features: [_foldBand()]);
      await _pumpNotes(tester, b.c);

      final band = verticalObstructingBand([_foldBand()], kFoldInner)!;
      expect(band.width, kFoldBandWidth);
      expect(
        find.byKey(const Key('note-wide-master')),
        findsOneWidget,
        reason: '折痕分栏：左栏仍是 master',
      );

      final rects = _clickableRects(tester);
      expect(
        rects,
        isNotEmpty,
        reason: '这一屏必须有可点元素，否则"不相交"是空断言',
      );
      final bad = rects.where((r) => rectHitsBands(r, [band])).toList();
      expect(
        bad,
        isEmpty,
        reason: '折痕带 $band 内不许有可点元素，命中：$bad',
      );
      // 机制量②：整页区域也不许跨折痕（不只是"这一刻恰好没有可点元素落在带里"）
      final mr = tester.getRect(find.byKey(const Key('note-wide-master')));
      expect(
        rectHitsBands(mr, [band]),
        isFalse,
        reason: '整页区域 $mr 不许跨折痕带 $band',
      );
      _expectNoLayoutError('折叠半折 673×841', cap);
    });

    testWidgets('横折（hinge，横带 40dp）：可点元素与整页区域都不压带', (tester) async {
      final b = await _boot();
      _view(tester, kFoldInner, features: [_hingeBandHorizontal()]);
      await _pumpNotes(tester, b.c);
      final band = horizontalObstructingBand(
        [_hingeBandHorizontal()],
        kFoldInner,
      )!;
      final rects = _clickableRects(tester);
      expect(rects, isNotEmpty);
      final bad = rects.where((r) => rectHitsBands(r, [band])).toList();
      expect(bad, isEmpty, reason: '横向铰链带 $band 内不许有可点元素，命中：$bad');
      final mr = tester.getRect(find.byKey(const Key('note-wide-master')));
      expect(
        rectHitsBands(mr, [band]),
        isFalse,
        reason: '整页区域 $mr 不许跨横向铰链带 $band',
      );
    });
  });

  group('§3 Pad 竖 768×1024（r293 起 = expanded）', () {
    testWidgets('双栏（768 ≥ 700）：右栏区域在树里、两栏不重叠、0 布局异常', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kPadPortrait);
      await _pumpNotes(tester, b.c);
      expect(appWindowSizeOf(kPadPortrait), AppWindowSize.expanded);
      expect(find.byKey(const Key('note-wide-master')), findsOneWidget);
      expect(
        find.byKey(const Key('note-wide-region')),
        findsOneWidget,
        reason: 'Pad 竖 768 ≥ 700 ⇒ expanded，右栏区域必须在树里',
      );
      expect(find.byKey(const Key('note-wide-empty')), findsOneWidget);
      final mr = tester.getRect(find.byKey(const Key('note-wide-master')));
      final dr = tester.getRect(find.byKey(const Key('note-wide-region')));
      expect(
        dr.overlaps(mr),
        isFalse,
        reason: '两栏不许重叠：master $mr / region $dr',
      );
      expect(
        mr.width + dr.width,
        lessThanOrEqualTo(kPadPortrait.width + 2),
        reason: '两栏宽度之和 ${mr.width + dr.width} 不应超过屏宽 ${kPadPortrait.width}',
      );
      _expectNoLayoutError('Pad 竖 768×1024', cap);
    });
  });

  // ══════════════════════════════════════════════════ §3 ★ 真机 Mate X2 两朝向
  group('§3 ★ HUAWEI Mate X2 内屏（真机运行时逻辑尺寸）', () {
    testWidgets('竖屏 676.923 ⇒ medium ⇒ 单列（右栏不在树里）', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kMateX2Portrait);
      await _pumpNotes(tester, b.c);
      expect(appWindowSizeOf(kMateX2Portrait), AppWindowSize.medium);
      expect(find.byKey(const Key('note-wide-master')), findsOneWidget);
      expect(
        find.byKey(const Key('note-wide-detail')),
        findsNothing,
        reason: 'Mate X2 竖屏 676.923 < 700 ⇒ 必须单列',
      );
      _expectNoLayoutError('Mate X2 竖屏 676.923', cap);
    });

    testWidgets('横屏 763.077 ⇒ expanded ⇒ 两栏（master 与 region 同屏、不重叠）', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kMateX2Landscape);
      await _pumpNotes(tester, b.c);
      expect(appWindowSizeOf(kMateX2Landscape), AppWindowSize.expanded);
      final master = find.byKey(const Key('note-wide-master'));
      final region = find.byKey(const Key('note-wide-region'));
      expect(master, findsOneWidget);
      expect(region, findsOneWidget, reason: 'Mate X2 横屏 763.077 ≥ 700 ⇒ 必须两栏');
      final mr = tester.getRect(master);
      final dr = tester.getRect(region);
      expect(
        mr.left >= -0.5 && mr.right <= kMateX2Landscape.width + 0.5 && mr.width > 0,
        isTrue,
        reason: 'master 矩形 $mr 必须整块在屏内（宽 ${kMateX2Landscape.width}）',
      );
      expect(
        dr.left >= -0.5 && dr.right <= kMateX2Landscape.width + 0.5 && dr.width > 0,
        isTrue,
        reason: 'region 矩形 $dr 必须整块在屏内（宽 ${kMateX2Landscape.width}）',
      );
      expect(dr.left, greaterThanOrEqualTo(mr.right - 1));
      expect(dr.overlaps(mr), isFalse, reason: '两栏不许重叠：$mr / $dr');
      _expectNoLayoutError('Mate X2 横屏 763.077', cap);
    });
  });

  group('§3 Pad 横 1024×768（expanded）', () {
    testWidgets('双栏：两区域同屏、不重叠；可点元素不越界', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kPadLandscape);
      await _pumpNotes(tester, b.c);

      final master = find.byKey(const Key('note-wide-master'));
      final detail = find.byKey(const Key('note-wide-region'));
      expect(master, findsOneWidget);
      expect(detail, findsOneWidget, reason: 'expanded 必须并排右栏区域');

      final mr = tester.getRect(master);
      final dr = tester.getRect(detail);
      // 机制量①：两区域矩形**同时**在屏内
      expect(
        mr.left >= 0 && mr.right <= kPadLandscape.width && mr.width > 0,
        isTrue,
        reason: 'master 矩形 $mr 必须整块在屏内（宽 ${kPadLandscape.width}）',
      );
      expect(
        dr.left >= 0 && dr.right <= kPadLandscape.width && dr.width > 0,
        isTrue,
        reason: 'detail 矩形 $dr 必须整块在屏内（宽 ${kPadLandscape.width}）',
      );
      // 机制量②：两区域**不重叠**
      expect(
        mr.right <= dr.left || dr.right <= mr.left,
        isTrue,
        reason: 'master $mr 与 detail $dr 不许重叠',
      );
      expect(dr.left, greaterThanOrEqualTo(mr.right - 1));
      // 机制量③：可点元素都不越出自己那一栏
      for (final r in _clickableRects(tester)) {
        expect(
          r.left >= mr.left - 1 && r.right <= dr.right + 1,
          isTrue,
          reason: '可点元素 $r 越出了双栏范围',
        );
      }
      expect(find.byKey(const Key('note-wide-empty')), findsOneWidget);
      _expectNoLayoutError('Pad 横 1024×768', cap);
    });

    testWidgets('点行 → 右栏换成预览、**不推路由**（机制量）', (tester) async {
      final b = await _boot();
      _view(tester, kPadLandscape);
      await _pumpNotes(tester, b.c);
      expect(find.byType(NoteViewPage), findsNothing);

      await tester.tap(find.byKey(const Key('note-row-n1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byType(NoteViewPage),
        findsNothing,
        reason: '宽屏点行是"右栏预览"，不是 push 路由',
      );
      expect(find.byKey(const Key('note-wide-empty')), findsNothing);
      expect(find.byKey(const Key('note-wide-detail')), findsOneWidget);
      expect(find.text('对齐会议'), findsWidgets);
    });

    testWidgets('iPad Pro 11" 横屏 1194×834 同样进 expanded ⇒ 双栏', (tester) async {
      final b = await _boot();
      _view(tester, kIpadPro11Landscape);
      await _pumpNotes(tester, b.c);
      expect(appWindowSizeOf(kIpadPro11Landscape), AppWindowSize.expanded);
      expect(find.byKey(const Key('note-wide-region')), findsOneWidget);
      expect(find.byKey(const Key('note-wide-empty')), findsOneWidget);
    });
  });

  group('§3 分屏一半 507×1024（compact）', () {
    testWidgets('单列、不溢出、不重叠', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kSplitHalf);
      await _pumpNotes(tester, b.c);
      expect(appWindowSizeOf(kSplitHalf), AppWindowSize.compact);
      expect(find.byKey(const Key('note-wide-detail')), findsNothing);
      final mr = tester.getRect(find.byKey(const Key('note-wide-master')));
      expect(mr.width, kSplitHalf.width);
      _expectNoLayoutError('分屏一半 507×1024', cap);
    });
  });

  // ══════════════════════════════════════════════════ §3 窄屏路径（medium 档）
  //
  // ★ r293：原来的"窄屏推路由"覆盖挂在**桌面 800×600** 上；800 现在 ≥ 700
  //   ⇒ expanded（双栏）。窄屏路径的覆盖**不许因此消失**（§2.0.29：去重不是
  //   删入口），改挂到 673×841（medium，< 700）—— 这一档与折叠屏内屏竖屏
  //   同量级，是真正会走 `Navigator.push` 的宽度。
  group('§3 窄屏 673×841（medium）：单列路径与既有 key 不回归', () {
    testWidgets('单列；既有 key 全在；点行仍 push 路由且返回栈正确', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kFoldInner);
      await _pumpNotes(tester, b.c);

      expect(find.byKey(const Key('note-wide-detail')), findsNothing);
      expect(find.byKey(const Key('note-row-n1')), findsOneWidget);
      expect(find.byKey(const Key('note-row-n2')), findsOneWidget);
      for (final k in const [
        'note-sort-entry',
        'note-view-toggle',
        'note-tag-filter-entry',
        'note-wide-master',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: '既有 key $k 必须还在');
      }

      // 窄屏推路由：进栈 → 返回 → 栈回到列表
      await tester.tap(find.byKey(const Key('note-row-n1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NoteViewPage), findsOneWidget, reason: '窄屏必须 push 路由');
      expect(find.byKey(const Key('note-wide-region')), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(NoteViewPage), findsNothing);
      expect(find.byKey(const Key('note-wide-master')), findsOneWidget);
      expect(find.byKey(const Key('note-row-n1')), findsOneWidget);
      _expectNoLayoutError('窄屏 673×841', cap);
    });
  });

  group('§3 桌面 800×600（r293 起 = expanded）', () {
    testWidgets('双栏：右栏区域在树里、点行不推路由（改判为宽屏路径）', (tester) async {
      final b = await _boot();
      final cap = _capture();
      _view(tester, kDesktop);
      await _pumpNotes(tester, b.c);

      expect(appWindowSizeOf(kDesktop), AppWindowSize.expanded);
      expect(find.byKey(const Key('note-wide-region')), findsOneWidget);
      expect(find.byKey(const Key('note-wide-empty')), findsOneWidget);
      expect(find.byType(NoteViewPage), findsNothing);

      await tester.tap(find.byKey(const Key('note-row-n1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byType(NoteViewPage),
        findsNothing,
        reason: '800 ≥ 700 是宽屏：点行是"右栏预览"，不是 push 路由',
      );
      expect(find.byKey(const Key('note-wide-detail')), findsOneWidget);
      expect(find.byKey(const Key('note-wide-empty')), findsNothing);
      _expectNoLayoutError('桌面 800×600', cap);
    });
  });
}
