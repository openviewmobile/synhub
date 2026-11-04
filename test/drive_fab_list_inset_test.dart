// D15（macOS 走查 `f25_drive_root.png`）/ Linux `LD-S1` 的离线复现与回归守卫。
//
// 缺陷：Drive 根页右下 `+`（文件页 Scaffold 的 `OrbButton`，52×52，
// `endFloat` 距底 16）**压在最后一行的行菜单 `⋮` 上** ⇒ 行菜单被遮、
// 点击区重叠。机制：Drive 列表底部留白原本只有 `Gap.xl`（24），
// 小于 FAB 的竖向占位（16 + 52 = 68）⇒ 滚到底时两者相交。
//
// 本用例钉的是**机制量**（§2.0.30②）：
//   * 滚动偏移必须真的到底（`pixels == maxScrollExtent`）；
//   * 最后一行必须真的贴在列表底部（`lastTile.bottom == listBottom − pad`）；
//   * 底部留白必须 ≥ FAB 的竖向占位（直径 52 + `endFloat` 外边距 16）。
// 反向验证（报告里有原文）：把 `kDriveListBottomInset` 临时改回 24 ⇒
// 「不相交」这条**当场红**。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/core/ui/orb_button.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_browse_view.dart'
    show kDriveListBottomInset, kDriveFabFootprint;
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 40 项，保证列表一定溢出（可滚到底）。
/// [count] 现在可调：短列表那一支用 ≤5 项复现"不可滚动"。
Map<String, dynamic> _listData({int count = 40}) => {
  'total': count,
  'items': [
    for (var i = 0; i < count; i++)
      {
        'file_id': 'f${i.toString().padLeft(2, '0')}',
        'name': 'item-${i.toString().padLeft(2, '0')}.txt',
        'type': 'file',
        'size': 10 + i,
        'display_path': '/mydrive',
        'modified_time': 1700000000 + i,
      },
  ],
};

Future<void> _pumpDriveRoot(
  WidgetTester tester,
  Size surface, {
  int count = 40,
  bool grid = false,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final responses = <String, Map<String, dynamic>>{
    'SYNO.SynologyDrive.Files.list': _listData(count: count),
  };
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
      driveApiProvider.overrideWithValue(DriveApi(api)),
    ],
  );
  // ★ 顺序要紧：LIFO ⇒ 先 dispose 容器（断掉 FileBrowsePage 持有的 drift
  //   订阅），再关库。反过来（先 `db.close()`）会挂在 drift 的 `close()` 上。
  addTearDown(() async => db.close());
  addTearDown(c.dispose);
  // 复刻 `f25`：文件 Tab → 切到「我的 Drive」来源 ⇒ FileBrowsePage 里
  // 右边是 DriveBrowseView，右下是 FileBrowsePage 的 OrbButton FAB。
  c.read(fileSourceProvider.notifier).select(FileSource.drive);
  if (grid) {
    // f12：切到网格态（与列表态同一段视口 Padding 才算"共用同一机制"）。
    c.read(driveViewModeProvider.notifier).set(DriveViewMode.grid);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: FileBrowsePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// f12：网格态里"最下面那一行"的卡片与它的行菜单 `⋮`。
///
/// 网格卡片的更多按钮在卡片**右上角**（`_DriveGridTile`），所以"最后一行"
/// 取矩形 `bottom` 最大的那块卡片；同一行里按 `top` 取最靠上的那块，
/// 取到的才是会被 FAB 带压到的候选。
({Rect tile, Rect menu}) _lastGridTileAndMenu(WidgetTester tester) {
  final tiles = <(Rect, Widget)>[];
  for (final e in find
      .byWidgetPredicate(
        (w) => w is InkWell && w.key.toString().contains('drive-grid-tile-'),
      )
      .evaluate()) {
    tiles.add((tester.getRect(find.byWidget(e.widget)), e.widget));
  }
  expect(tiles, isNotEmpty, reason: '前提：网格里要有卡片');
  tiles.sort((a, b) {
    final dy = b.$1.bottom.compareTo(a.$1.bottom);
    if (dy != 0) return dy;
    return a.$1.top.compareTo(b.$1.top);
  });
  final tileRect = tiles.first.$1;
  final tileWidget = tiles.first.$2;
  final menu = find.descendant(
    of: find.byWidget(tileWidget),
    matching: _driveMenus(),
  );
  expect(menu, findsOneWidget, reason: '最后一行卡片必须带行菜单 ⋮');
  return (tile: tileRect, menu: tester.getRect(menu));
}

/// f12：把网格滚到真正的底部（懒加载的 max 只是估算，用真手势逼成精确值）。
Future<ScrollPosition> _scrollGridToBottom(WidgetTester tester) async {
  final grid = find.byKey(const Key('drive-grid'));
  expect(grid, findsOneWidget, reason: '前提：Drive 网格要出来');
  final scrollable = find.descendant(
    of: grid,
    matching: find.byType(Scrollable),
  );
  final pos = tester.state<ScrollableState>(scrollable).position;
  for (var i = 0; i < 20; i++) {
    await tester.drag(grid, const Offset(0, -1200));
    await tester.pump();
  }
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return pos;
}

Finder _driveMenus() => find.byWidgetPredicate(
  (w) =>
      w is PopupMenuButton &&
      w.key.toString().contains('drive-entry-menu-'),
);

/// 滚到真正的底部，返回列表的 `ScrollPosition`。
///
/// ⚠️ 不能只 `jumpTo(maxScrollExtent)`：懒加载列表在滚动前的
/// `maxScrollExtent` 只是**估算**（实测 393/420/800 三档都偏大或偏小），
/// 跳过去未必到底。用真手势反复拖，把 max 逼成精确值后再跳。
Future<ScrollPosition> _scrollToBottom(WidgetTester tester) async {
  final list = find.byKey(const Key('drive-list'));
  expect(list, findsOneWidget, reason: '前提：Drive 列表要出来（否则测的是空气）');
  final scrollable = find.descendant(
    of: list,
    matching: find.byType(Scrollable),
  );
  final pos = tester.state<ScrollableState>(scrollable).position;
  for (var i = 0; i < 8; i++) {
    await tester.drag(list, const Offset(0, -1500));
    await tester.pump();
  }
  // 让 overscroll 的弹回动画走完，落到**真正的** maxScrollExtent。
  // （★ 不要在拖动后再 `jumpTo(maxScrollExtent)`：懒加载列表的 max 在
  //   滚动前只是估算，可能比真实值小 ⇒ 会往回弹，反而没到底。）
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return pos;
}

/// 最下面那一行（`ListTile`）以及它的行菜单 `⋮`。
({Rect tile, Rect menu}) _lastRowAndMenu(WidgetTester tester) {
  Rect? lastTile;
  Finder? lastTileFinder;
  for (final e in find.byType(DesignRowTile).evaluate()) {
    final f = find.byWidget(e.widget);
    final r = tester.getRect(f);
    if (lastTile == null || r.bottom > lastTile.bottom) {
      lastTile = r;
      lastTileFinder = f;
    }
  }
  expect(lastTile, isNotNull, reason: '前提：列表里要有 ListTile');
  final menu = find.descendant(of: lastTileFinder!, matching: _driveMenus());
  expect(menu, findsOneWidget, reason: '最后一行必须带行菜单 ⋮');
  return (tile: lastTile!, menu: tester.getRect(menu));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('不变量：Drive 列表底部留白 ≥ FAB 竖向占位（直径 + endFloat 外边距）', (
    tester,
  ) async {
    // 这里用 FAB 的**默认**尺寸；它是 `OrbButton` 出厂值，页面没传 size。
    const fabDiameter = 52.0;
    const fabEndFloatMargin = 16.0;
    expect(
      kDriveListBottomInset,
      greaterThanOrEqualTo(fabDiameter),
      reason: '留白至少要有 FAB 直径',
    );
    expect(
      kDriveListBottomInset,
      greaterThanOrEqualTo(fabDiameter + fabEndFloatMargin),
      reason: 'FAB 的竖向占位 = 直径 + endFloat 距底外边距',
    );
  });

  for (final s in const [
    (Size(393, 852), '393pt iOS 内容区'),
    (Size(420, 1000), '420 本仓常用'),
    (Size(800, 600), '800 桌面'),
  ]) {
    testWidgets('D15 复现/守卫 ${s.$2}：FAB 不与最后一行行菜单相交，且两者都在屏内', (
      tester,
    ) async {
      await _pumpDriveRoot(tester, s.$1);
      final pos = await _scrollToBottom(tester);

      final screen = Offset.zero & tester.binding.renderViews.first.size;
      final fab = tester.getRect(find.byType(OrbButton));
      final listRect = tester.getRect(find.byKey(const Key('drive-list')));
      final row = _lastRowAndMenu(tester);
      final lv = tester.widget<ListView>(find.byKey(const Key('drive-list')));
      final pad = (lv.padding as EdgeInsets).bottom;

      // ignore: avoid_print
      print(
        'PROBE after [${s.$2}]: fab=[${fab.left.toStringAsFixed(1)},'
        '${fab.top.toStringAsFixed(1)} ${fab.width.toStringAsFixed(1)}x'
        '${fab.height.toStringAsFixed(1)}] rowMenu=[${row.menu.left.toStringAsFixed(1)},'
        '${row.menu.top.toStringAsFixed(1)} ${row.menu.width.toStringAsFixed(1)}x'
        '${row.menu.height.toStringAsFixed(1)}] overlaps=${fab.overlaps(row.menu)} '
        'paddingBottom=${pad.toStringAsFixed(1)} fabSize=${fab.width.toStringAsFixed(1)} '
        'pixels=${pos.pixels.toStringAsFixed(1)}/max=${pos.maxScrollExtent.toStringAsFixed(1)} '
        'lastTileBottom=${row.tile.bottom.toStringAsFixed(1)} '
        'listBottom=${listRect.bottom.toStringAsFixed(1)}',
      );

      // ---- 防假绿：先证明"真的在底部、量的真是最后一行"（机制量）----
      expect(
        pos.pixels,
        closeTo(pos.maxScrollExtent, 0.6),
        reason: '没有滚到底的话，下面"不相交"就是假绿',
      );
      expect(
        row.tile.bottom,
        closeTo(listRect.bottom - pad, 3),
        reason:
            '最后一行必须贴在列表底部（留白处），否则测的不是同一件事：'
            'tileBottom=${row.tile.bottom} listBottom=${listRect.bottom} pad=$pad '
            'pixels=${pos.pixels} max=${pos.maxScrollExtent}',
      );

      // ---- 正向 1：FAB 与最后一行行菜单不相交 ----
      expect(
        fab.overlaps(row.menu),
        isFalse,
        reason:
            'FAB($fab) 压住了最后一行的行菜单(${row.menu})：'
            '列表底部留白 $pad 必须 ≥ FAB 占位 ${fab.height} + '
            '${screen.bottom - fab.bottom}（见 kDriveListBottomInset）',
      );

      // ---- 正向 2：两者都在屏内 ----
      expect(fab.overlaps(screen), isTrue, reason: 'FAB 必须在屏内');
      expect(row.menu.overlaps(screen), isTrue, reason: '行菜单必须在屏内');

      // ---- 正向 3：底部留白 ≥ FAB 直径（显式不变量）----
      expect(
        pad,
        greaterThanOrEqualTo(fab.height),
        reason: '留白必须 ≥ FAB 直径',
      );
      expect(
        pad,
        greaterThanOrEqualTo(fab.height + (screen.bottom - fab.bottom)),
        reason: '留白必须 ≥ FAB 竖向占位（含 endFloat 距底外边距）',
      );

      expect(tester.takeException(), isNull);
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // ★ D15 真机补充（协调方推翻了"离线全绿"的结论）：真机 Drive 根只有 4 个
  // 文件 + 一条引导横幅，**列表不可滚动** ⇒ 只加"内容底部留白"改变不了最后
  // 一行的落点，FAB 依旧压住行菜单 `⋮`。这一支专门测**不可滚动的短列表**。
  //
  // 断言口径（§2.0.30②）：钉**视口矩形与 FAB 顶的关系**（机制量），
  // 不钉"某个元素看起来可见"；并先钉 `maxScrollExtent == 0` 证明"真的不可滚动"。
  //
  // 反向验证：把 `DriveBrowseView.build` 里那层 `Padding(bottom: kDriveFabFootprint
  // + viewPadding.bottom)` 去掉 ⇒ 本用例的 `listRect.bottom <= fab.top` **当场红**。
  // ─────────────────────────────────────────────────────────────────────
  testWidgets('★ D15 真机补充：短列表（4 项、不可滚动）FAB 也不压最后一行行菜单', (
    tester,
  ) async {
    // ★ r491：行卡换成 `DesignRowTile` 后行更高（62 vs 56），4 项在这个高度下
    //   已经能滚 15px ⇒ 前提（不可滚动）不成立。改成 3 项把前提重新钉住；
    //   `maxScrollExtent == 0` 的断言保留 —— 再有变化会当场红，提示重新标定。
    await _pumpDriveRoot(tester, const Size(393, 700), count: 3);

    final list = find.byKey(const Key('drive-list'));
    expect(list, findsOneWidget, reason: '前提：Drive 列表要出来');
    final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
    final pos = tester.state<ScrollableState>(scrollable).position;

    final screen = Offset.zero & tester.binding.renderViews.first.size;
    final fab = tester.getRect(find.byType(OrbButton));
    final listRect = tester.getRect(list);
    final row = _lastRowAndMenu(tester);

    // ignore: avoid_print
    print(
      'PROBE short: fab=[${fab.left.toStringAsFixed(1)},${fab.top.toStringAsFixed(1)} '
      '${fab.width.toStringAsFixed(1)}x${fab.height.toStringAsFixed(1)}] '
      'listRect=[${listRect.left.toStringAsFixed(1)},${listRect.top.toStringAsFixed(1)} '
      '${listRect.width.toStringAsFixed(1)}x${listRect.height.toStringAsFixed(1)}] '
      'rowMenu=[${row.menu.left.toStringAsFixed(1)},${row.menu.top.toStringAsFixed(1)} '
      '${row.menu.width.toStringAsFixed(1)}x${row.menu.height.toStringAsFixed(1)}] '
      'lastTileBottom=${row.tile.bottom.toStringAsFixed(1)} '
      'overlaps=${fab.overlaps(row.menu)} '
      'max=${pos.maxScrollExtent.toStringAsFixed(1)} pixels=${pos.pixels.toStringAsFixed(1)}',
    );

    // ---- 防假绿：这一支必须是**真的不可滚动**（否则测的是另一件事）----
    expect(
      pos.maxScrollExtent,
      0,
      reason: '本支的前提 = 短列表不可滚动（这正是真机推翻"留白足够"的场景）',
    );
    expect(pos.pixels, 0);

    // ---- 机制量（本次修复的核心）：列表视口下沿必须整体高于 FAB 顶 ----
    expect(
      listRect.bottom,
      lessThanOrEqualTo(fab.top + 0.5),
      reason:
          '列表视口必须避开 FAB（视口底 ${listRect.bottom} 应 ≤ FAB 顶 ${fab.top}）；'
          '否则任何一行都可能落进 FAB 矩形（内容留白对不可滚动列表无效）',
    );
    // 修复常量本身就是 FAB 的竖向占位：留白 ≥ 占位
    expect(
      kDriveFabFootprint,
      greaterThanOrEqualTo(fab.height),
      reason: '视口避让的高度至少要盖住 FAB 直径',
    );

    // ---- 正向 1：不与该行行菜单相交 ----
    expect(
      fab.overlaps(row.menu),
      isFalse,
      reason: 'FAB($fab) 压住了短列表最后一行行菜单(${row.menu})',
    );

    // ---- 正向 2：最后一行 `⋮` 的矩形**完整在屏内** ----
    expect(row.menu.left, greaterThanOrEqualTo(screen.left));
    expect(row.menu.top, greaterThanOrEqualTo(screen.top));
    expect(
      row.menu.right,
      lessThanOrEqualTo(screen.right + 0.5),
      reason: '行菜单右边不得出屏：menu=$row,menu screen=$screen',
    );
    expect(
      row.menu.bottom,
      lessThanOrEqualTo(screen.bottom + 0.5),
      reason: '行菜单下边不得出屏（完整在屏内才是"没被裁掉"）',
    );

    expect(tester.takeException(), isNull);
  });

  // ─────────────────────────────────────────────────────────────────────
  // ★ f12：**网格态**底行被 FAB 遮挡（D15 的同型缺陷，网格支）。
  //
  // 机制确认：网格不是另一条 `if (isGrid)` 分支——`GridView.builder` 与
  // `ListView.separated` 同处 `DriveBrowseView.build` 的那一层
  // `Padding(bottom: kDriveFabFootprint + viewPadding.bottom)` 之下
  // （`drive_browse_view.dart:263-295`）⇒ 视口避让对两种视图**共用**。
  // 因此这两条用例钉的是**同一机制在网格态也必须成立**（机制量，§2.0.30②）：
  //   ① 视口下沿 ≤ FAB 顶（`gridRect.bottom <= fab.top`）；
  //   ② 底行卡片行菜单矩形 ∩ FAB 矩形 = ∅。
  // 反向验证：把 `kDriveFabFootprint` 从视口 Padding 里去掉（保留
  // `viewPadding.bottom`）⇒ ①② 当场红（原文见报告）。
  // ─────────────────────────────────────────────────────────────────────
  testWidgets('★ f12 网格×4 项未滚动：视口避让 FAB，底行卡片菜单不相交', (tester) async {
    await _pumpDriveRoot(tester, const Size(393, 700), count: 4, grid: true);

    final grid = find.byKey(const Key('drive-grid'));
    expect(grid, findsOneWidget, reason: '前提：Drive 网格要出来');
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    final pos = tester.state<ScrollableState>(scrollable).position;

    final screen = Offset.zero & tester.binding.renderViews.first.size;
    final fab = tester.getRect(find.byType(OrbButton));
    final gridRect = tester.getRect(grid);
    final row = _lastGridTileAndMenu(tester);

    // ignore: avoid_print
    print(
      'PROBE f12 grid-short: fab=[${fab.left.toStringAsFixed(1)},'
      '${fab.top.toStringAsFixed(1)} ${fab.width.toStringAsFixed(1)}x'
      '${fab.height.toStringAsFixed(1)}] gridRect=[${gridRect.left.toStringAsFixed(1)},'
      '${gridRect.top.toStringAsFixed(1)} ${gridRect.width.toStringAsFixed(1)}x'
      '${gridRect.height.toStringAsFixed(1)}] rowMenu=[${row.menu.left.toStringAsFixed(1)},'
      '${row.menu.top.toStringAsFixed(1)} ${row.menu.width.toStringAsFixed(1)}x'
      '${row.menu.height.toStringAsFixed(1)}] tileBottom=${row.tile.bottom.toStringAsFixed(1)} '
      'overlaps=${fab.overlaps(row.menu)} '
      'pixels=${pos.pixels.toStringAsFixed(1)}/max=${pos.maxScrollExtent.toStringAsFixed(1)}',
    );

    // ---- 防假绿：这一支是"停在顶部未滚动" ----
    expect(pos.pixels, 0, reason: '本支的前提 = 4 项短内容停在顶部未滚动');

    // ---- 机制量①：视口下沿 ≤ FAB 顶 ----
    expect(
      gridRect.bottom,
      lessThanOrEqualTo(fab.top + 0.5),
      reason:
          '网格视口必须避开 FAB（视口底 ${gridRect.bottom} 应 ≤ FAB 顶 ${fab.top}）；'
          '否则行内容会落进 FAB 矩形',
    );

    // ---- 机制量②：底行卡片行菜单 ∩ FAB = ∅ ----
    expect(
      fab.overlaps(row.menu),
      isFalse,
      reason: 'FAB($fab) 压住了网格底行卡片行菜单(${row.menu})',
    );
    expect(kDriveFabFootprint, greaterThanOrEqualTo(fab.height));

    // ---- 正向：两者都在屏内 ----
    expect(fab.overlaps(screen), isTrue, reason: 'FAB 必须在屏内');
    expect(row.menu.overlaps(screen), isTrue, reason: '底行行菜单必须在屏内');

    expect(tester.takeException(), isNull);
  });

  testWidgets('★ f12 网格×40 项滚到底：视口避让 FAB，底行卡片菜单不相交', (tester) async {
    await _pumpDriveRoot(tester, const Size(393, 700), count: 40, grid: true);

    final grid = find.byKey(const Key('drive-grid'));
    expect(grid, findsOneWidget, reason: '前提：Drive 网格要出来');
    final pos = await _scrollGridToBottom(tester);

    final screen = Offset.zero & tester.binding.renderViews.first.size;
    final fab = tester.getRect(find.byType(OrbButton));
    final gridRect = tester.getRect(grid);
    final row = _lastGridTileAndMenu(tester);

    // ignore: avoid_print
    print(
      'PROBE f12 grid-bottom: fab=[${fab.left.toStringAsFixed(1)},'
      '${fab.top.toStringAsFixed(1)} ${fab.width.toStringAsFixed(1)}x'
      '${fab.height.toStringAsFixed(1)}] gridRect=[${gridRect.left.toStringAsFixed(1)},'
      '${gridRect.top.toStringAsFixed(1)} ${gridRect.width.toStringAsFixed(1)}x'
      '${gridRect.height.toStringAsFixed(1)}] rowMenu=[${row.menu.left.toStringAsFixed(1)},'
      '${row.menu.top.toStringAsFixed(1)} ${row.menu.width.toStringAsFixed(1)}x'
      '${row.menu.height.toStringAsFixed(1)}] tileBottom=${row.tile.bottom.toStringAsFixed(1)} '
      'overlaps=${fab.overlaps(row.menu)} '
      'pixels=${pos.pixels.toStringAsFixed(1)}/max=${pos.maxScrollExtent.toStringAsFixed(1)}',
    );

    // ---- 防假绿：真的滚到底（否则"不相交"是假绿）----
    expect(
      pos.pixels,
      closeTo(pos.maxScrollExtent, 0.6),
      reason: '没有滚到底的话，下面的"不相交"就是假绿',
    );

    // ---- 机制量①：视口下沿 ≤ FAB 顶 ----
    expect(
      gridRect.bottom,
      lessThanOrEqualTo(fab.top + 0.5),
      reason:
          '网格视口必须避开 FAB（视口底 ${gridRect.bottom} 应 ≤ FAB 顶 ${fab.top}）',
    );

    // ---- 机制量②：底行卡片行菜单 ∩ FAB = ∅ ----
    expect(
      fab.overlaps(row.menu),
      isFalse,
      reason:
          'FAB($fab) 压住了滚到底后底行卡片的行菜单(${row.menu})：'
          'rowMenuBottom=${row.menu.bottom} fabTop=${fab.top}',
    );

    // ---- 正向：两者都在屏内 ----
    expect(fab.overlaps(screen), isTrue, reason: 'FAB 必须在屏内');
    expect(row.menu.overlaps(screen), isTrue, reason: '底行行菜单必须在屏内');

    expect(tester.takeException(), isNull);
  });
}
