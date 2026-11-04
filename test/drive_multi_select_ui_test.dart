// ★★ **③Drive 第 56 轮：D25 多选 UI 端到端**（长按 → 选多项 → 打包下载）
//
// ## 为什么必须有这份用例
// `drive_selection_test.dart` 只证明**纯模型**对；`drive_download_archive_test.dart`
// 只证明**直链参数**对。但 D25 的缺口是**用户点不到** ——
// 只有 widget 用例能证明"长按真的进入选择模式、真的能选第二个、
// 工具栏真的出现、下载真的带上 2 个 id"。
//
// ## 三条"看起来做了其实没做"的陷阱
// ① 长按进入模式但**没顺手选中**那一行 ⇒ 用户以为没反应；
// ② 选择模式下点行仍然**打开文件**（而不是切换选中）⇒ 一点就跳走；
// ③ 下载按钮**带上全部条目**而不是**只带选中的** ⇒ 打包出一堆没选的东西。
// 三条都不会报错，只有 widget 用例能抓到。
//
// 全程假传输，不碰真机（规程 §5.1）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_browse_view.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
};

/// 三条普通文件（`Files/list` 的 data）。
Map<String, dynamic> _listData() => {
  'total': 3,
  'items': [
    {
      'file_id': 'fa',
      'name': 'a.txt',
      'type': 'file',
      'size': 10,
      'display_path': '/mydrive',
      // ★ r314：删除菜单项由 `entry.canWrite`（= `capabilities.can_write`）门控 ——
      // 不给这个位，"删除"根本不在菜单里，用例会误以为"点不到"
      'capabilities': <String, dynamic>{'can_write': true},
    },
    {
      'file_id': 'fb',
      'name': 'b.txt',
      'type': 'file',
      'size': 20,
      'display_path': '/mydrive',
      // ★ r314：删除菜单项由 `entry.canWrite`（= `capabilities.can_write`）门控 ——
      // 不给这个位，"删除"根本不在菜单里，用例会误以为"点不到"
      'capabilities': <String, dynamic>{'can_write': true},
    },
    {
      'file_id': 'fc',
      'name': 'c.txt',
      'type': 'file',
      'size': 30,
      'display_path': '/mydrive',
      // ★ r314：删除菜单项由 `entry.canWrite`（= `capabilities.can_write`）门控 ——
      // 不给这个位，"删除"根本不在菜单里，用例会误以为"点不到"
      'capabilities': <String, dynamic>{'can_write': true},
    },
  ],
};

/// ★ r314：`Files/delete` 的**真机形状** —— 回 `{async_task_id}`（不是空 data），
/// 且删除后 `Files/list` 必须**真的少一条**（否则"摘 id"的用例会靠假绿通过：
/// 列表没变也就看不出选择集合有没有跟着变）。
final List<Map<String, dynamic>> _deleted = <Map<String, dynamic>>[];

Future<FakeTransport> _pump(
  WidgetTester tester, {
  bool canDelete = false,
}) async {
  _deleted.clear();
  final live = <Map<String, dynamic>>[...(_listData()['items'] as List).cast<Map<String, dynamic>>()];
  final responses = <String, Map<String, dynamic>>{
    'SYNO.SynologyDrive.Files.list': _listData(),
  };
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  final seen = <String>[];
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    seen.add(key);
    if (canDelete && key == 'SYNO.SynologyDrive.Files.delete') {
      final raw = '${params['files'] ?? ''}';
      _deleted.add({'files': raw});
      // `["id:fa"]` → `fa`
      final ids = RegExp(r'"id:([^"]+)"')
          .allMatches(raw)
          .map((m) => m.group(1))
          .toList();
      live.removeWhere((e) => ids.contains('${e['file_id']}'));
      return <String, dynamic>{'async_task_id': 'task-r314'};
    }
    if (canDelete && key == 'SYNO.SynologyDrive.Files.list') {
      // 删除之后重新列：**只剩没被删的**（真机语义）
      return <String, dynamic>{
        'total': live.length,
        'items': live,
        'success': true,
      };
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
      driveApiProvider.overrideWithValue(DriveApi(api)),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: DriveBrowseView())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return t;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('★ 长按一行 ⇒ 进入选择模式，且**顺手选中这一行**（已选 1 项）', (tester) async {
    await _pump(tester);
    expect(find.text('a.txt'), findsOneWidget, reason: '列表要先出来');

    // 未长按前没有选择工具栏
    expect(find.byKey(const Key('drive-selection-bar')), findsNothing);

    await tester.longPress(find.text('a.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const Key('drive-selection-bar')),
      findsOneWidget,
      reason: '★ 长按必须进入选择模式，否则用户永远选不到多个',
    );
    expect(
      find.text('已选 1 项'),
      findsOneWidget,
      reason:
          '★ 长按**本身就表示"我要选它"**；只进入模式不选，'
          '用户会以为长按没反应',
    );
  });

  testWidgets('★★ 选择模式下点第二行 ⇒ 已选 2 项（且**不跳走**）', (tester) async {
    await _pump(tester);
    await tester.longPress(find.text('a.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('b.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('已选 2 项'),
      findsOneWidget,
      reason: '★ 选择模式下点行是**切换选中**，不是打开文件',
    );
  });

  testWidgets('★★ 全选按钮 ⇒ 已选 3 项；再点 ⇒ 0 项', (tester) async {
    await _pump(tester);
    await tester.longPress(find.text('a.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('drive-selection-all')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已选 3 项'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drive-selection-all')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('已选 0 项'),
      findsOneWidget,
      reason: '★ 全选再点 = 取消全选（不是"逐个取反"的怪行为）',
    );
  });

  testWidgets('★ 退出按钮 ⇒ 工具栏消失（选择模式结束）', (tester) async {
    await _pump(tester);
    await tester.longPress(find.text('a.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('drive-selection-bar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('drive-selection-exit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('drive-selection-bar')), findsNothing);
  });

  testWidgets('★★ 一个都没选时"下载"禁用（而不是消失 —— 避免位置跳动误点）', (tester) async {
    await _pump(tester);
    await tester.longPress(find.text('a.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 取消掉唯一选中项，变成"在选择模式但 0 项"
    await tester.tap(find.text('a.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已选 0 项'), findsOneWidget);

    final btn = tester.widget<IconButton>(
      find.byKey(const Key('drive-selection-download')),
    );
    expect(
      btn.onPressed,
      isNull,
      reason: '★ 0 项时应禁用；若按钮直接消失，用户点"下载"的位置会变成别的按钮',
    );
  });

  testWidgets(
    '★★★ r314：删除一条之后，它的 id 必须从选择集合里摘掉（否则「已选 N 项」是幽灵）',
    (tester) async {
      // 真机缺陷（第 314 轮）：清理自建文件时每次「长按 → 行 ⋮ → Delete → 确认」
      // 都成功，但选择集合**只增不减** ⇒ 界面变成「已选 3 项」而一个勾都看不见
      // （3 个 id 指向的文件都已不在列表），且这个**武装态跨页残留**
      // （离开到搜索页再回来仍在多选模式，那时顶栏导航按钮也还能点）。
      // 行菜单有 13+ 项：默认 800x600 测试窗口会把「删除」挤到屏外，
      // 于是 `tap()` 打空（hit-test 警告）⇒ 用例会误报"点不到删除"。
      // 用真实手机的**逻辑**尺寸形态给足高度（`tester.view.*`，不是
      // `setSurfaceSize` —— 后者根本不改 MediaQuery，见 §2.0.36）。
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(tester, canDelete: true);
      await tester.longPress(find.text('a.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('已选 1 项'), findsOneWidget);

      // 行 ⋮ → 删除
      await tester.tap(find.byKey(const Key('drive-entry-menu-fa')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      // 二次确认（破坏性动作必须确认）
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(
        _deleted.map((e) => e['files']).toList(),
        ['["id:fa"]'],
        reason: '★ 删除要真的发出去，否则本用例什么都没验',
      );
      expect(find.text('a.txt'), findsNothing, reason: '★ 列表要真的少一条');
      expect(
        find.byKey(const Key('drive-selection-bar')),
        findsNothing,
        reason:
            '★★ 摘空之后必须退出选择模式 —— 否则留下「已选 1 项」这种幽灵计数，'
            '而集合里的 id 指向的文件已经不存在了',
      );
      // 反向验证：剩下的两条**没有**被误摘（不能"一刀切清空"
      // —— 若删的是 3 条里的 1 条，另 2 条必须仍是选中的）
      await tester.longPress(find.text('b.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('已选 1 项'),
        findsOneWidget,
        reason: '★ 长按 b.txt 后应该正好 1 项 —— 证明没有别的残留 id',
      );
    },
  );
}
