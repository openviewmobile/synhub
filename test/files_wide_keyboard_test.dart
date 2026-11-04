// r675 · `DA301`：宽屏文件站的**硬件键盘**（Enter 打开 / Esc 关信息卡）。
//
// 为什么要有这条：iOS 模拟器 + iPad 妙控键盘上实测发现 —— 整仓 `LogicalKeyboardKey`
// **零命中**，也就是说"iPad 当电脑用"时 Enter / Esc 什么都不做（Finder 里这是两个
// 最基本的键）。修法见 `file_browse_page.dart` 的 `_WideKeys`：只在 `expanded`
// 且筛选框没开时收键，走的是与双击、右栏「打开」**同一条** `_openWide`。
//
// 判据（全部是机制量，不钉"某个像素此刻在哪"）：
// | # | 判据 | 反向验证 |
// |---|---|---|
// | ① | 宽屏选中一行后 `Enter` ⇒ 走打开路径（进入目录：面包屑变 `/home/docs`） | 去掉 `_WideKeys` ⇒ 停在 `/home` ❌ |
// | ② | 宽屏选中一行后 `Esc` ⇒ 右栏回到空态（`file-wide-empty` 回来） | 不派发 Esc ⇒ 信息卡还在 ❌ |
// | ③ | **窄屏**（compact）按 Enter/Esc **什么都不做**：不推路由、不崩 | 把 enabled 改成恒 true ⇒ 窄屏会推路由 ❌ |
// | ④ | 筛选框开着时 Enter 归筛选（`_WideKeys` 让位），不打开选中项 | — |
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart'
    show driveApiProvider;
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_row.dart' show FileRow;

import 'support/chat_harness.dart' show FakeTransport;

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

class _Boot {
  _Boot(this.c, this.nav);
  final ProviderContainer c;
  final List<Route<dynamic>> nav;
}

class _RouteCounter extends NavigatorObserver {
  final List<Route<dynamic>> pushes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
    super.didPush(route, previousRoute);
  }
}

Future<_Boot> _pumpPage(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.FileStation.List.list') {
      final path = '${params['folder_path'] ?? ''}';
      final files = path == '/home/docs'
          ? [_entry('inner.txt')]
          : [_entry('docs', dir: true), _entry('a.txt')];
      return {'success': true, 'files': files, 'total': files.length, 'offset': 0};
    }
    return {'success': true};
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
  addTearDown(() async => db.close());
  addTearDown(c.dispose);

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
  return _Boot(c, nav.pushes);
}

void _drain(WidgetTester tester) {
  var n = 0;
  while (n < 60 && tester.takeException() != null) {
    n++;
  }
}

const _ipadLandscape = Size(1210, 834);
const _iphonePortrait = Size(402, 874);

/// 选中 `docs` 这一行（宽屏：**单击只选中**，不进入）。
Future<void> _selectDocs(WidgetTester tester) async {
  final row = find.ancestor(
    of: find.text('docs'),
    matching: find.byType(FileRow),
  );
  expect(row, findsOneWidget, reason: '左栏应有 docs 行');
  await tester.tap(row);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pressEnter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _pressEsc(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('DA301 ①：宽屏选中后 Enter = 打开（进入 docs）', (tester) async {
    await _pumpPage(tester, _ipadLandscape);
    expect(find.byKey(const Key('file-wide-master')), findsOneWidget,
        reason: '前提：1210×834 必须是 expanded（宽屏）');
    await _selectDocs(tester);
    // 单击只选中：右栏出信息卡、面包屑仍在 /home
    expect(find.byKey(const Key('file-wide-empty')), findsNothing,
        reason: '前提：单击后右栏是信息卡（不是空态）');

    await _pressEnter(tester);

    // 打开路径 = 进入目录：左栏出现 docs 的内容，右栏回到空态
    expect(find.text('inner.txt'), findsOneWidget,
        reason: '★ DA301：Enter 必须走与双击同一条"打开"路径（进入 docs）');
    expect(find.byKey(const Key('file-wide-empty')), findsOneWidget,
        reason: '进入后右栏应回到空态（不是停在上一级的信息卡）');
  });

  testWidgets('DA301 ②：宽屏 Esc = 关掉右栏信息卡（选中清空）', (tester) async {
    await _pumpPage(tester, _ipadLandscape);
    await _selectDocs(tester);
    expect(find.byKey(const Key('file-wide-empty')), findsNothing,
        reason: '前提：选中后右栏是信息卡');

    await _pressEsc(tester);

    expect(find.byKey(const Key('file-wide-empty')), findsOneWidget,
        reason: '★ DA301：Esc 必须把右栏清回空态（等价于点 ✕）');
    // 反向：Esc 不许顺手把目录也退了（面包屑仍在 /home ⇒ 还在列表里）
    expect(find.text('docs'), findsOneWidget,
        reason: 'Esc 只关信息卡，不换目录');
  });

  testWidgets('DA301 ③：窄屏按 Enter/Esc 什么都不做（不许误伤表单语义）',
      (tester) async {
    final boot = await _pumpPage(tester, _iphonePortrait);
    expect(find.byKey(const Key('file-wide-master')), findsOneWidget);
    expect(find.byKey(const Key('file-wide-region')), findsNothing,
        reason: '前提：窄屏没有右栏（不是"看不见"，是不在树里）');
    final settled = boot.nav.length;
    // 窄屏这两键必须**完全不作为**：不换目录、不推路由、不抛异常
    await _pressEnter(tester);
    await _pressEsc(tester);
    expect(boot.nav.length, settled,
        reason: '★ DA301：窄屏 Enter/Esc 不许推路由（否则会顶掉表单/退出的语义）');
    expect(find.text('docs'), findsOneWidget,
        reason: '★ DA301：窄屏 Enter 不许把目录打开（窄屏的打开靠点行）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('DA301 ④：筛选框开着时 Enter 归筛选（_WideKeys 让位）', (tester) async {
    await _pumpPage(tester, _ipadLandscape);
    await _selectDocs(tester);
    // 打开「在目录内筛选」（顶栏的 filter 动作）
    await tester.tap(find.byIcon(Icons.filter_alt_outlined).first);
    await tester.pump(const Duration(milliseconds: 400));
    await _pressEnter(tester);
    // 判定：仍在 /home（没有因为 Enter 把 docs 打开）
    expect(find.text('inner.txt'), findsNothing,
        reason: '★ 筛选框开着时 Enter 不该触发"打开选中项"');
    // 左栏行 + 右栏信息卡各有一处 `docs`（所以是 findsWidgets 而不是 one）
    expect(find.text('docs'), findsWidgets);
  });
}
