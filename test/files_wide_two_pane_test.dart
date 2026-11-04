// r284：**文件 / Drive 宽屏双栏**（机制量用例 + 反向验证）。r293 随阈值
// 840→700 同步改判（Pad 竖 768 / 桌面 800 / iPad 竖 834 改判 expanded）。
//
// 被测机制（全部钉**机制量**，不钉"某元素此刻可不可见"，见 §2.0.30②）：
//
// | # | 机制量 | 判据 |
// |---|---|---|
// | ① | 断点**只有一份** | `appWindowSizeOf` 的裁定；接入点用的是同一个 `AdaptiveScaffold` |
// | ② | 双栏几何 | `detail.left ≥ master.right`（左右分栏 x 关系）+ 两矩形同屏 + 不重叠 |
// | ③ | 宽屏点项**不推路由** | `NavigatorObserver.didPush` 计数**不变** + 左栏仍可见 |
// | ④ | 窄屏点项**推路由** | 计数 +1 且栈顶是 `FilePreviewPage`（既有路径逐字节不变） |
// | ⑤ | 窄屏**不存在右栏** | `file-wide-region` `findsNothing`（不是"看不见"，是不在树里） |
// | ⑥ | FAB/视口修法不回归 | 宽屏下 Drive 列表视口下沿仍 ≤ FAB 顶（`kDriveFabFootprint`）；**右栏**三种列表（NAS 目录/Drive 目录/文件详情）同样如此（§7） |
//
// 尺寸矩阵（真机逻辑尺寸）：1210×834（iPad 横）/ 1024×768（Pad 横）/
// **834×1210（iPad 竖，r293 起 expanded）** / **800×600（桌面测试窗口，
// r293 起 expanded）** / 673×841（折叠内屏，仍 medium）/ 320×780（折叠外屏）/
// 507×1024（分屏一半）/ ★ 763.077×676.923（Mate X2 内屏横，真机实测）/
// ★ 676.923×763.077（Mate X2 内屏竖，真机实测）。
//
// ★ **834×1210 的裁定（r293 已改判，旧注释不再成立）**：r284 时写的是
//   "834 < `kAppWindowMediumMax=840` ⇒ medium ⇒ 单列"。r293 起上界 = **700**
//   ⇒ 834 ≥ 700 ⇒ **expanded ⇒ 双栏**。iPad 竖屏并排后每栏 ≈500pt，仍可读。
//   单列档现在由 673×841 与 676.923×763.077 覆盖（这两档 < 700）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/ui/adaptive_layout.dart';
import 'package:synhub/src/core/ui/orb_button.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_browse_view.dart'
    show kDriveFabFootprint;
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_row.dart' show FileRow;
import 'package:synhub/src/features/files/file_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

// ---------------------------------------------------------------- 尺寸矩阵

const kIpadLandscape = Size(1210, 834);
const kIpadPortrait = Size(834, 1210);
const kPadLandscape = Size(1024, 768);
const kDesktop = Size(800, 600);
const kFoldInner = Size(673, 841);
const kFoldOuter = Size(320, 780);
const kSplitHalf = Size(507, 1024);

/// ★ 真机 **HUAWEI Mate X2（TET-AN00）内屏** 运行时逻辑尺寸（r292 逐位实测）：
/// 内屏 2480×2200 @520dpi、dpr 3.25 ⇒ 短边 2200/3.25 = 676.923、长边
/// 2480/3.25 = 763.077。竖屏宽 676.923（medium）、横屏宽 763.077（expanded）。
const double kMateX2DpShort = 2200 / 3.25;
const double kMateX2DpLong = 2480 / 3.25;
const kMateX2Portrait = Size(kMateX2DpShort, kMateX2DpLong);
const kMateX2Landscape = Size(kMateX2DpLong, kMateX2DpShort);

/// 应当并排的（expanded）—— r293 起新增 iPad 竖、桌面、Mate X2 横。
const kTwoPaneSizes = <Size>[
  kPadLandscape,
  kIpadLandscape,
  kIpadPortrait, // r293：834 ≥ 700
  kDesktop, // r293：800 ≥ 700
  kMateX2Landscape, // r293：763.077 ≥ 700（本轮的唯一目标机型）
];

/// 应当单列的（medium / compact）
const kSingleColumnSizes = <Size>[
  kFoldInner, // 673 < 700
  kMateX2Portrait, // 676.923 < 700（★ 与 Mate X2 横屏成对）
  kFoldOuter,
  kSplitHalf,
];

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
};

Map<String, dynamic> _entry(String name, {bool dir = false}) => {
  'name': name,
  'path': '/home/$name',
  'isdir': dir,
  'additional': {
    'size': dir ? 0 : 12,
    'time': {'mtime': 1758100000},
    'perm': {
      'acl': {'read': true, 'write': true, 'exec': false},
    },
  },
};

Map<String, dynamic> _driveEntry(String id, String name, {bool dir = false}) => {
  'file_id': id,
  'name': name,
  'type': dir ? 'dir' : 'file',
  'size': dir ? 0 : 12,
  'display_path': '/mydrive/$name',
  'modified_time': 1700000000,
};

/// 路由计数（机制量③④）：`MaterialApp` 的初始 `home` 也算一次 `didPush`，
/// 所以断言一律用**差值**。
class _RouteCounter extends NavigatorObserver {
  final List<Route<dynamic>> pushes = <Route<dynamic>>[];

  int get count => pushes.length;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
    super.didPush(route, previousRoute);
  }
}

class _Boot {
  _Boot(this.c, this.nav);

  final ProviderContainer c;
  final _RouteCounter nav;
}

/// 起一个真的 `FileBrowsePage`（NAS 源，起始目录 = `/home`）。
///
/// 用 `initialPath` 而不是"先点根目录的共享"：这样左栏第一屏就有
/// **一个目录 + 一个文件**，两种点击路径都能量。
Future<_Boot> _pumpPage(
  WidgetTester tester,
  Size size, {
  bool drive = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final responses = <String, Map<String, dynamic>>{
    'SYNO.SynologyDrive.Files.list': {
      'total': 2,
      'items': [
        _driveEntry('d1', 'dfolder', dir: true),
        _driveEntry('d2', 'dfile.txt'),
      ],
    },
  };
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  // NAS 源的目录列表按 `folder_path` 分档：`/home` 一个目录 + 一个文件；
  // `/home/docs` 里放一个 `inner.txt`（用来验证"窄屏进目录"真的换了左栏内容）。
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.FileStation.List.list') {
      final path = '${params['folder_path'] ?? ''}';
      final files = path == '/home/docs'
          ? [_entry('inner.txt')]
          : [_entry('docs', dir: true), _entry('a.txt')];
      return {'success': true, 'files': files, 'total': files.length, 'offset': 0};
    }
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
  // LIFO：先 dispose 容器（断掉 drift 订阅）再关库（见 drive_fab_list_inset_test）。
  addTearDown(() async => db.close());
  addTearDown(c.dispose);
  if (drive) {
    c.read(fileSourceProvider.notifier).select(FileSource.drive);
  }

  final nav = _RouteCounter();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        navigatorObservers: [nav],
        home: const FileBrowsePage(initialPath: '/home'),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  _drain(tester);
  return _Boot(c, nav);
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

void _expectNoLayoutError(String what, List<FlutterErrorDetails> captured) {
  if (captured.isEmpty) return;
  fail(
    '$what：出现 ${captured.length} 条布局异常，首条：'
    '${captured.first.exception.toString().split('\n').first}',
  );
}

Finder _master() => find.byKey(const Key('file-wide-master'));
Finder _region() => find.byKey(const Key('file-wide-region'));
Finder _empty() => find.byKey(const Key('file-wide-empty'));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // ══════════════════════════════════ §1 断点只有一份（纯函数，机制量①）
  group('§1 断点复用：宽度分级仍只有 adaptive_layout 一份', () {
    test('尺寸矩阵的分级裁定（含 699/700 与真机 763.077/676.923 成对取样）', () {
      expect(appWindowSizeOf(kPadLandscape), AppWindowSize.expanded);
      expect(appWindowSizeOf(kIpadLandscape), AppWindowSize.expanded);
      // ★ r293 改判：桌面 800 与 iPad 竖 834 现在 ≥ 700 ⇒ expanded
      expect(appWindowSizeOf(kDesktop), AppWindowSize.expanded);
      expect(appWindowSizeOf(kIpadPortrait), AppWindowSize.expanded);
      expect(appWindowSizeOf(kFoldInner), AppWindowSize.medium);
      expect(appWindowSizeOf(kFoldOuter), AppWindowSize.compact);
      expect(appWindowSizeOf(kSplitHalf), AppWindowSize.compact);
      // 边界（贴边）—— 断点两侧**各一条**
      expect(appWindowSizeOf(const Size(599.5, 800)), AppWindowSize.compact);
      expect(appWindowSizeOf(const Size(600, 800)), AppWindowSize.medium);
      expect(appWindowSizeOf(const Size(699, 800)), AppWindowSize.medium);
      expect(appWindowSizeOf(const Size(699.5, 800)), AppWindowSize.medium);
      expect(appWindowSizeOf(const Size(700, 800)), AppWindowSize.expanded);
      // ★ 真机 HUAWEI Mate X2 内屏两朝向（逐位实测；成对裁定）
      expect(appWindowSizeOf(kMateX2Portrait), AppWindowSize.medium);
      expect(kMateX2Portrait.width, closeTo(676.923, 0.001));
      expect(appWindowSizeOf(kMateX2Landscape), AppWindowSize.expanded);
      expect(kMateX2Landscape.width, closeTo(763.077, 0.001));
      // 断点常量本身
      expect(kAppWindowCompactMax, 600.0);
      expect(kAppWindowMediumMax, 700.0);
    });
  });

  // ══════════════════════════════════ §2 expanded：双栏几何（机制量②）
  for (final s in kTwoPaneSizes) {
    testWidgets(
      '${s.width.toInt()}×${s.height.toInt()} 双栏：两栏同屏、不重叠、'
      'detail 在 master 右侧；右栏空态在',
      (tester) async {
        final cap = _capture();
        await _pumpPage(tester, s);

        expect(
          appWindowSizeOf(s),
          AppWindowSize.expanded,
          reason: '前提：本档必须 expanded',
        );
        expect(_master(), findsOneWidget, reason: '左栏区域必须在');
        expect(_region(), findsOneWidget, reason: 'expanded 必须并排右栏区域');

        final mr = tester.getRect(_master());
        final dr = tester.getRect(_region());
        final screen = Offset.zero & s;

        // 机制量：两栏矩形**同时**整块在屏内
        expect(
          mr.left >= screen.left - 0.5 &&
              mr.right <= screen.right + 0.5 &&
              mr.width > 0,
          isTrue,
          reason: '左栏矩形 $mr 必须整块在屏内（宽 ${s.width}）',
        );
        expect(
          dr.left >= screen.left - 0.5 &&
              dr.right <= screen.right + 0.5 &&
              dr.width > 0,
          isTrue,
          reason: '右栏矩形 $dr 必须整块在屏内（宽 ${s.width}）',
        );
        // 机制量：左右分栏的 x 关系 —— 左栏右缘 ≤ 右栏左缘（不重叠且右栏在右）
        expect(
          dr.left,
          greaterThanOrEqualTo(mr.right - 1),
          reason: '右栏必须整体在左栏右侧（左栏 $mr / 右栏 $dr）',
        );
        expect(
          dr.overlaps(mr),
          isFalse,
          reason: '两栏矩形不许重叠：左栏 $mr / 右栏 $dr',
        );
        // 机制量：两栏合起来不超过整屏（没有第三栏、也没有超出）
        expect(
          mr.width + dr.width,
          lessThanOrEqualTo(screen.width + 2),
          reason: '两栏宽度之和 ${mr.width + dr.width} 不应超过屏宽 ${screen.width}',
        );
        // 未选中 ⇒ 右栏空态
        expect(_empty(), findsOneWidget);
        _expectNoLayoutError('${s.width}×${s.height} 双栏', cap);
      },
    );
  }

  // ══════════════════════════════════ §3 medium/compact：单列（机制量⑤）
  for (final s in kSingleColumnSizes) {
    testWidgets(
      '${s.width.toInt()}×${s.height.toInt()} 单列：右栏'
      '**不在树里**、左栏占满宽；0 布局异常',
      (tester) async {
        final cap = _capture();
        await _pumpPage(tester, s);

        expect(
          appWindowSizeOf(s).isExpanded,
          isFalse,
          reason: '前提：本档不是 expanded',
        );
        expect(
          _region(),
          findsNothing,
          reason:
              '${s.width}×${s.height}（${appWindowSizeOf(s).name}）必须单列 —— '
              '右栏根本不许进树（窄屏等价性不变量）',
        );
        expect(_empty(), findsNothing);
        expect(_master(), findsOneWidget);
        final mr = tester.getRect(_master());
        expect(
          mr.width,
          closeTo(s.width, 1),
          reason: '单列时左栏必须占满整宽（实测 ${mr.width} / 期望 ${s.width}）',
        );
        // 左栏内容真的在（不是"整屏空着也算单列"）
        expect(find.text('a.txt'), findsOneWidget);
        _expectNoLayoutError('${s.width}×${s.height} 单列', cap);
      },
    );
  }

  // ══════════════════════════════════ §4 宽屏点项：不推路由（机制量③）
  group('§4 宽屏（1024×768）：点项就地填右栏，不推路由', () {
    // ★ r673：右栏从"第二级目录列表"改成**信息卡（Inspector）** ——
    //   列内容只发生在左栏，导航只有一条轨道（跟 Finder 列表视图一致）。
    testWidgets('左栏点目录行：路由不变、右栏出该目录的信息卡（不列内容）', (tester) async {
      final boot = await _pumpPage(tester, kPadLandscape);
      final before = boot.nav.count;

      await tester.tap(find.text('docs'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        boot.nav.count,
        before,
        reason: '宽屏点目录不许 push 路由（路由计数 $before → ${boot.nav.count}）',
      );
      expect(find.text('a.txt'), findsOneWidget, reason: '左栏仍在，下层没有被替换');
      expect(_empty(), findsNothing, reason: '选中后右栏不许还是空态');
      expect(
        find.byKey(const Key('file-wide-detail')),
        findsOneWidget,
        reason: '右栏出的是信息卡',
      );
      expect(
        find.byKey(const Key('file-wide-nas-list')),
        findsNothing,
        reason: '★ 右栏**不再**列目录内容（那正是"两层导航混在一起"的来源）',
      );
      expect(
        find.byKey(const Key('file-wide-open')),
        findsOneWidget,
        reason: '信息卡必须给一个显式「打开文件夹」出口',
      );
    });

    testWidgets('信息卡「打开文件夹」= 进入该目录（与双击同一条路径）', (tester) async {
      final boot = await _pumpPage(tester, kPadLandscape);
      await tester.tap(find.text('docs'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final stackBefore = boot.c.read(fileBrowseStackProvider).length;
      await tester.tap(find.byKey(const Key('file-wide-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        boot.c.read(fileBrowseStackProvider).length,
        stackBefore + 1,
        reason: '目录的「打开」必须是进入（左栏目录栈 +1）',
      );
      expect(
        boot.c.read(fileBrowseStackProvider).last,
        contains('docs'),
        reason: '进入的就是被选中的那个目录',
      );
    });

    testWidgets('左栏点文件行：路由计数不变、右栏换成详情（不推 FilePreviewPage）', (tester) async {
      final boot = await _pumpPage(tester, kPadLandscape);
      final before = boot.nav.count;

      await tester.tap(find.text('a.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byType(FilePreviewPage),
        findsNothing,
        reason: '宽屏点文件行是"右栏详情"，不是 push 预览路由',
      );
      expect(boot.nav.count, before, reason: '路由计数必须不变');
      expect(find.byKey(const Key('file-wide-detail')), findsOneWidget);
    });

    testWidgets('右栏「打开预览」是**显式动作** ⇒ 只有它推路由', (tester) async {
      final boot = await _pumpPage(tester, kPadLandscape);

      await tester.tap(find.text('a.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final before = boot.nav.count;

      await tester.tap(find.byKey(const Key('file-wide-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byType(FilePreviewPage),
        findsOneWidget,
        reason: '显式点「打开预览」才走既有预览入口',
      );
      expect(boot.nav.count, before + 1, reason: '这一支必须真的 push 了一条路由');
    });

    testWidgets('Drive 源：点目录行只出信息卡，不推路由也不 push Drive 栈', (tester) async {
      final boot = await _pumpPage(tester, kPadLandscape, drive: true);
      final before = boot.nav.count;
      final drivePathBefore = boot.c.read(driveStackProvider).last;

      await tester.tap(find.text('dfolder'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(boot.nav.count, before, reason: '宽屏 Drive 点目录不许推路由');
      expect(
        boot.c.read(driveStackProvider).last,
        drivePathBefore,
        reason: '单击只选中 ⇒ 左栏目录栈必须没变',
      );
      expect(
        find.byKey(const Key('file-wide-detail')),
        findsOneWidget,
        reason: '右栏出的是信息卡',
      );
      expect(
        find.byKey(const Key('file-wide-drive-list')),
        findsNothing,
        reason: '★ 右栏不再列 Drive 目录内容',
      );
    });

    testWidgets('Drive 源：信息卡「打开文件夹」= push Drive 目录栈', (tester) async {
      final boot = await _pumpPage(tester, kPadLandscape, drive: true);
      final drivePathBefore = boot.c.read(driveStackProvider).last;

      await tester.tap(find.text('dfolder'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('file-wide-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        boot.c.read(driveStackProvider).last,
        isNot(drivePathBefore),
        reason: '目录的「打开」必须走 Drive 栈进入',
      );
    });
  });

  // ══════════════════════════════════ §5 窄屏点项：仍推路由（机制量④）
  //
  // ★ r293：这一组原来挂在**桌面 800×600** 上；800 现在 ≥ 700 ⇒ expanded。
  //   窄屏路径的覆盖**不许消失**（§2.0.29），改挂到 673×841（medium）
  //   与真机竖屏 676.923×763.077 —— 后者就是本轮"竖屏必须仍单栏"的靶子。
  group('§5 窄屏（673×841 / 676.923×763.077，medium）：点项仍走原路径', () {
    for (final s in const [kFoldInner, kMateX2Portrait]) {
      testWidgets('${s.width.toStringAsFixed(3)} 宽：点文件行 ⇒ push FilePreviewPage，路由计数 +1', (
        tester,
      ) async {
        final boot = await _pumpPage(tester, s);
        final before = boot.nav.count;

        expect(
          appWindowSizeOf(s).isExpanded,
          isFalse,
          reason: '前提：本档不是 expanded（${s.width} < 700）',
        );
        await tester.tap(find.text('a.txt'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          find.byType(FilePreviewPage),
          findsOneWidget,
          reason: '窄屏点文件必须 push 预览路由（既有行为不许变）',
        );
        expect(boot.nav.count, before + 1, reason: '窄屏这一支必须真的 push');
        expect(_region(), findsNothing);
      });

      testWidgets('${s.width.toStringAsFixed(3)} 宽：点目录行 ⇒ 左栏进目录（不推路由、无右栏）', (
        tester,
      ) async {
        final boot = await _pumpPage(tester, s);
        final before = boot.nav.count;

        await tester.tap(find.text('docs'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(boot.nav.count, before, reason: '进目录是左栏栈，不是路由');
        expect(_region(), findsNothing, reason: '窄屏不许出现右栏');
        expect(
          find.text('inner.txt'),
          findsOneWidget,
          reason: '窄屏点目录应把左栏换成 /home/docs 的内容（既有行为）',
        );
      });
    }
  });

  // ══════════════════════════════════ §6 FAB / 视口修法不回归（机制量⑥）
  testWidgets('宽屏 Drive 源：列表视口下沿仍 ≤ FAB 顶（kDriveFabFootprint 机制继续有效）', (
    tester,
  ) async {
    await _pumpPage(tester, kPadLandscape, drive: true);

    final list = find.byKey(const Key('drive-list'));
    expect(list, findsOneWidget, reason: '前提：宽屏左栏的 Drive 列表要出来');
    final fab = tester.getRect(find.byType(OrbButton));
    final listRect = tester.getRect(list);

    expect(
      kDriveFabFootprint,
      greaterThanOrEqualTo(fab.height),
      reason: '视口避让的高度至少要盖住 FAB 直径',
    );
    expect(
      listRect.bottom,
      lessThanOrEqualTo(fab.top + 0.5),
      reason:
          '宽屏下 Drive 列表视口也必须避开 FAB（视口底 ${listRect.bottom} '
          '应 ≤ FAB 顶 ${fab.top}）—— D15/LD-S1 的修法不许被双栏改动回退',
    );
    expect(tester.takeException(), isNull);
  });

  // ══════════════════════════════════ §7 右栏列表也要避开 FAB（机制量⑥）
  //
  // 为什么必须补：宽屏下 `+`（`OrbButton`）落在**右栏**右下角。右栏是本轮
  // **新增**的列表宿主 ⇒ 若只给内容留白（`kDriveListBottomInset`），"滚不动
  // 的短目录"里最后一行永远落进 FAB 矩形 = D15 原样复发。判据钉**视口下沿**
  // （机制量），不钉"某行此刻可不可见"（结果量，见 §2.0.30②）。
  group('§7 宽屏右栏的列表视口下沿 ≤ FAB 顶', () {
    testWidgets('右栏目录信息卡：file-wide-detail 视口避开 FAB（原"目录列表"那一支）', (
      tester,
    ) async {
      await _pumpPage(tester, kPadLandscape);
      await tester.tap(find.text('docs'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final list = find.byKey(const Key('file-wide-detail'));
      expect(list, findsOneWidget, reason: '前提：右栏目录信息卡要出来');
      final fab = tester.getRect(find.byType(OrbButton));
      final r = tester.getRect(list);
      expect(
        r.bottom,
        lessThanOrEqualTo(fab.top + 0.5),
        reason:
            '右栏信息卡视口底 ${r.bottom} 必须 ≤ FAB 顶 ${fab.top}'
            '（否则最后一行永远滚不进 FAB 上方 ⇒ D15 复发）',
      );
      expect(
        kDriveFabFootprint,
        greaterThanOrEqualTo(fab.height),
        reason: '视口避让高度至少盖住 FAB 直径',
      );
      expect(tester.takeException(), isNull);
    });

    // ★ r677（`DA308`）：**空态**（未选中）不只要有 key，它的**文字**也不许钻到
    //   FAB 底下 —— r675 横屏像素里说明第二行 "...double-click" 被 `+` 压掉半行。
    //   判据 = 文字矩形与 FAB 矩形**不相交**（像素可复核：`docs/evidence-r677-ios/`）。
    testWidgets('DA308：iPhone 横屏（874×402）右栏空态文字不许与 FAB 相交', (
      tester,
    ) async {
      await _pumpPage(tester, const Size(874, 402));
      final empty = find.byKey(const Key('file-wide-empty'));
      expect(empty, findsOneWidget, reason: '前提：未选中时右栏是空态');
      final fab = tester.getRect(find.byType(OrbButton));
      // **机制量**：短视口下空态的水平让位必须至少到 FAB 左沿
      // （只靠"文字此刻不与 FAB 相交"抓不住 —— 这里的空态是顶部对齐的，
      //  真机上右栏只有 102pt 高、内容被挤成整块才会压到 FAB 那一带；
      //  所以判据钉"让位宽度"，它蕴含"任何垂直位置都不会压住"。）
      final emptyRect = tester.getRect(empty);
      expect(
        emptyRect.right,
        lessThanOrEqualTo(fab.left + 0.5),
        reason:
            'DA308：短视口空态右沿 ${emptyRect.right} 必须 ≤ FAB 左沿 ${fab.left}'
            '（否则说明文字在纵向居中时会压住 `+`）',
      );
      final texts = find.descendant(of: empty, matching: find.byType(Text));
      expect(texts, findsWidgets, reason: '空态必须有标题（DA302）');
      var checked = 0;
      for (var i = 0; i < texts.evaluate().length; i++) {
        final r = tester.getRect(texts.at(i));
        if (r.width <= 0.5 || r.height <= 0.5) continue;
        checked++;
        expect(
          r.overlaps(fab),
          isFalse,
          reason:
              '空态文字 ${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)}'
              ' ${r.width.toStringAsFixed(1)}×${r.height.toStringAsFixed(1)} '
              '与 FAB ${fab.left.toStringAsFixed(1)},${fab.top.toStringAsFixed(1)}'
              ' ${fab.width.toStringAsFixed(1)}×${fab.height.toStringAsFixed(1)} 相交'
              '（DA308：横屏右栏 300×102pt 时说明末行会被 `+` 压住）',
        );
      }
      expect(checked, greaterThan(0), reason: '至少量到一个可见 Text');
      expect(tester.takeException(), isNull);
    });

    // 高屏（iPad 横）同样不许相交 —— 让位只在短视口生效，别的尺寸不许回退。
    // ★ 单独一个用例：`_pumpPage` 在一个用例里挂两次会留 pending timer（实测）。
    testWidgets('DA308 反向：iPad 横屏（1210×834）空态文字也不与 FAB 相交', (
      tester,
    ) async {
      await _pumpPage(tester, kPadLandscape);
      final fab = tester.getRect(find.byType(OrbButton));
      final empty = find.byKey(const Key('file-wide-empty'));
      expect(empty, findsOneWidget);
      final texts = find.descendant(of: empty, matching: find.byType(Text));
      var checked = 0;
      for (var i = 0; i < texts.evaluate().length; i++) {
        final r = tester.getRect(texts.at(i));
        if (r.width <= 0.5 || r.height <= 0.5) continue;
        checked++;
        expect(r.overlaps(fab), isFalse, reason: 'iPad 横屏同样不许相交');
      }
      expect(checked, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('左栏 NAS 列表：file-nas-list 视口避开 FAB（右栏改造后左栏仍是列表宿主）', (
      tester,
    ) async {
      await _pumpPage(tester, kPadLandscape);
      final fab = tester.getRect(find.byType(OrbButton));
      // 左栏的列表 key 以实际实现为准：取 GroupedListView/ListView 里最下沿那个
      final lists = find.byType(ListView);
      expect(lists, findsWidgets);
      var worst = -1.0;
      for (var i = 0; i < lists.evaluate().length; i++) {
        final r = tester.getRect(lists.at(i));
        if (r.width <= 1 || r.height <= 1) continue;
        if (r.bottom > worst) worst = r.bottom;
      }
      expect(
        worst,
        lessThanOrEqualTo(fab.top + 0.5),
        reason: '左栏列表视口下沿 $worst 必须 ≤ FAB 顶 ${fab.top}',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('右栏文件详情：file-wide-detail 视口避开 FAB', (tester) async {
      await _pumpPage(tester, kPadLandscape);
      await tester.tap(find.text('a.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final detail = find.byKey(const Key('file-wide-detail'));
      expect(detail, findsOneWidget, reason: '前提：右栏文件详情要出来');
      final fab = tester.getRect(find.byType(OrbButton));
      final r = tester.getRect(detail);
      expect(
        r.bottom,
        lessThanOrEqualTo(fab.top + 0.5),
        reason: '右栏详情视口底 ${r.bottom} 必须 ≤ FAB 顶 ${fab.top}',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ══════════════════════════════════ §8 r673（DA299 / DA300）：右栏改成
  // 「信息窗格 Inspector」后的标准交互。DA299 = 两套导航混在一起（右栏既列目录
  // 又再钻）；DA300 = 选中行无高亮 + 右栏清不掉。
  //
  // 用户 2026-10-29：「左右分屏这个交互还是设计的有点奇怪，参考业界标准」。
  // 这一组钉住三条**交互不变量**（不是"长什么样"）：
  //   ① 选中项在左栏必须**亮起来**（否则右栏显示谁全靠猜）；
  //   ② 右栏只有一条打开路径（`file-wide-open`），目录/文件的标签各说各的话；
  //   ③ 右栏可以**关掉**（回到空态），不会变成一张清不掉的卡。
  group('§8 信息卡（Inspector）：高亮 / 打开标签 / 可关闭', () {
    testWidgets('单击目录 ⇒ 左栏该行 selected=true（右栏显示谁，左栏就亮谁）', (
      tester,
    ) async {
      await _pumpPage(tester, kPadLandscape);
      await tester.tap(find.text('docs'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final rows = find.byType(FileRow);
      var lit = 0;
      for (var i = 0; i < rows.evaluate().length; i++) {
        final row = tester.widget<FileRow>(rows.at(i));
        if (row.selected) lit++;
        if (row.entry.name == 'docs') {
          expect(row.selected, isTrue, reason: '被选中的目录必须在左栏高亮');
        }
      }
      expect(lit, 1, reason: '宽屏单选态只能亮一行（实测 $lit 行）');
    });

    testWidgets('目录信息卡：标签是「打开文件夹」，文件信息卡：标签是「打开预览」', (
      tester,
    ) async {
      await _pumpPage(tester, kPadLandscape);

      await tester.tap(find.text('docs'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byKey(const Key('file-wide-detail')),
          matching: find.text('打开文件夹'),
        ),
        findsOneWidget,
        reason: '目录的打开动作必须说清是"打开文件夹"',
      );

      await tester.tap(find.text('a.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byKey(const Key('file-wide-detail')),
          matching: find.text('打开预览'),
        ),
        findsOneWidget,
        reason: '文件的打开动作必须说清是"打开预览"',
      );
    });

    testWidgets('右栏「✕」⇒ 回到空态（不会留一张清不掉的卡）', (tester) async {
      await _pumpPage(tester, kPadLandscape);
      await tester.tap(find.text('docs'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_empty(), findsNothing);

      await tester.tap(find.byKey(const Key('file-wide-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(_empty(), findsOneWidget, reason: '关掉后右栏必须回到空态');
      expect(
        find.byKey(const Key('file-wide-detail')),
        findsNothing,
        reason: '信息卡必须真的没了',
      );
    });
  });
}
