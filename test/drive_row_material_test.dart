// ★★ r131（macOS 逐屏走查）回归：**Drive 列表行必须自带透明 `Material` 祖先**。
//
// ## 为什么必须有这份用例
// macOS 逐屏截图走查里，真实 NAS 的 Drive 根目录一屏（14 项）**在 debug 下抛了 8 次**
// 框架断言：
//
// ```
// ListTile background color or ink splashes may be invisible.
// The ListTile is wrapped in a ColoredBox that has a background color. …
// ```
//
// 机制：Drive 页跑在外壳的 `FieldBackdrop` 里，而它内部是
// `ColoredBox(color: hud.deep, child: Stack(...))` —— `ListTile` 把底色与
// 水波纹画在**最近的 Material 祖先**上，中间夹一层带色 `ColoredBox`
// 就把这两样盖住了。后果不是"难看"而是**用户点一行没有任何反馈**
// （release 下不报错，正因如此只能靠像素/断言取证）。
//
// 同一坑本仓已在 `drive_tasks_page` / `file_mount_page` / `file_offline_page` /
// `file_pages` / `webdav_page` 各修过一次（都是"补一层透明 Material"），
// **Drive 列表行漏了**。这份用例把 Drive 这一行钉进守卫。
//
// ## 反向验证（必须真的能抓到）
// 把 `drive_browse_view.dart` 里 `_DriveRow` 的
// `Material(type: MaterialType.transparency, child: …)` 拆掉 ⇒
// 本用例第 1 条**当场红**（`takeException` 拿到那条 ListTile 断言）。
//
// 全程假传输，不碰真机（规程 §5.1）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/core/ui/field_backdrop.dart';
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

/// 三条普通文件（`Files/list` 的 data）—— 数量不重要，只要 >1（断言是按行触发的）。
Map<String, dynamic> _listData() => {
  'total': 3,
  'items': [
    {
      'file_id': 'fa',
      'name': 'a.txt',
      'type': 'file',
      'size': 10,
      'display_path': '/mydrive',
    },
    {
      'file_id': 'fb',
      'name': 'b.txt',
      'type': 'file',
      'size': 20,
      'display_path': '/mydrive',
    },
    {
      'file_id': 'fc',
      'name': 'c.txt',
      'type': 'file',
      'size': 30,
      'display_path': '/mydrive',
    },
  ],
};

/// 泵出"外壳里的一页"：`FieldBackdrop` **必须开着**（关掉就走
/// `enabled == false` 那条分支，虽然也是 ColoredBox，但我们要复刻真机形状：
/// 外层 `ColoredBox` + 里层 `Stack` 的那条）。
Future<void> _pump(WidgetTester tester, {required bool backdrop}) async {
  final responses = <String, Map<String, dynamic>>{
    'SYNO.SynologyDrive.Files.list': _listData(),
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
      driveApiProvider.overrideWithValue(DriveApi(api)),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  // ★ 形状必须照抄真外壳（`app_shell_page.dart:412`）：
  //   `Scaffold(body: FieldBackdrop(child: <page>))`
  //   —— `Scaffold` 提供**上层** `Material`，`FieldBackdrop` 的 `ColoredBox`
  //   夹在它和 `ListTile` **中间**，这才是断言真的触发的形状。
  //   反例（我第一版）：`FieldBackdrop(child: Scaffold(...))` ⇒ `Material`
  //   在 `ColoredBox` 里面，走查不到中间层 ⇒ 用例假绿。

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: backdrop
              ? const FieldBackdrop(child: DriveBrowseView())
              : const DriveBrowseView(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('★★ Drive 列表行在 FieldBackdrop 里 ⇒ 不抛 ListTile 水波纹断言', (tester) async {
    await _pump(tester, backdrop: true);
    expect(
      find.text('a.txt'),
      findsOneWidget,
      reason: '前提：列表要先出来（否则这条用例测的是空气）',
    );
    // 断言：一帧里**没有**任何异常。修之前这里是
    // 「ListTile background color or ink splashes may be invisible.」
    expect(
      tester.takeException(),
      isNull,
      reason:
          '★ 反向验证：把 `_DriveRow` 的透明 `Material` 拆掉，这条必红 —— '
          '在真实外壳（FieldBackdrop 的 ColoredBox）里，ListTile 的底色与'
          '水波纹都会被盖住（用户点一行毫无反馈）',
    );
  });

  testWidgets('★ 每一行都自带 Material 祖先（逐行检查，别只查第一行）', (tester) async {
    await _pump(tester, backdrop: true);
    for (final name in const ['a.txt', 'b.txt', 'c.txt']) {
      final tile = find.ancestor(
        of: find.text(name),
        matching: find.byType(DesignRowTile),
      );
      expect(tile, findsOneWidget, reason: '$name 应该是一个 ListTile 行');
      expect(
        find.ancestor(of: tile, matching: find.byType(Material)),
        findsWidgets,
        reason: '★ 反向验证：$name 这行没有 Material 祖先 ⇒ 外壳的 ColoredBox '
            '会把 ink 盖住（真机实测 Drive 根目录一屏 8 次断言）',
      );
    }
  });

  testWidgets('★ 列表本身仍然可用（修复不能把行点坏）', (tester) async {
    await _pump(tester, backdrop: true);
    await tester.longPress(find.text('a.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const Key('drive-selection-bar')),
      findsOneWidget,
      reason: '补一层透明 Material 不许改变点击/长按行为',
    );
    expect(tester.takeException(), isNull);
  });
}
