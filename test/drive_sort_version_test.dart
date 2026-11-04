// ★★ 第 256 轮真机缺陷回归：Drive「排序」把界面变成死胡同（用户原话：
// 「drive选了文件排序过滤条件之后界面出问题了，回不去了」）。
//
// ## 真机根因（只读实测，真 NAS nas.example.com，2026-09-25）
//
// `SYNO.SynologyDrive.Files:list` 的 `sort_by` **按版本支持不同的键**：
// ```
// v3 sort_by=created_time -> 120 {"name":"sort_by","reason":"condition"}   ← 被拒
// v2 sort_by=created_time -> 成功（total=14，字段与 v3 完全相同的 41 个）
// v1 sort_by=created_time -> 成功
// v3 sort_by=name|size|modified_time|type|owner -> 成功
// ```
// 本仓 `DriveApi.list` 协商到的是 **v3** ⇒ 用户一选「创建时间」，
// 列表请求 120，`drive_browse_view` 的 error 分支**只渲染错误提示、
// 排序工具栏整个消失** ⇒ 用户再也点不到「默认排序」，只能杀进程。
//
// ## 两条不变量（本文件钉死）
// ① 「创建时间」必须走 **v2**（其余排序键仍走 v3）—— 根治，不再产生 120；
// ② **列表报错时排序入口必须还在**（工具栏 + 一键重置）—— 兜底，
//    任何"错误原因就是当前排序"的未来情形都不能再变成死胡同。
//
// 全程假传输，不碰真机（规程 §5.1）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
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
  // 真机的 `Files` 注册到 maxVersion 11 ⇒ `_negotiate(_v3)` 会挑 3。
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
};

Map<String, dynamic> _listData() => {
  'total': 1,
  'items': [
    {
      'file_id': 'fa',
      'name': 'a.txt',
      'type': 'file',
      'size': 10,
      'display_path': '/mydrive',
    },
  ],
};

Future<({FakeTransport t, DriveApi api})> _api() async {
  final t = FakeTransport({
    'SYNO.SynologyDrive.Files.list': _listData(),
  }, {...FakeTransport.table, ..._table});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, api: DriveApi(api));
}

/// 最后一次 `Files/list` 调用（拿它的 version / sort_by）。
Map<String, String> _lastListCall(FakeTransport t) {
  final list = [
    for (final c in t.calls)
      if (c['api'] == 'SYNO.SynologyDrive.Files' && c['method'] == 'list')
        {
          for (final e in c.entries) e.key: '${e.value}',
        },
  ];
  expect(list, isNotEmpty, reason: '必须有 Files/list 调用被发出');
  return list.last;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('① root cause：排序键与版本必须配对', () {
    test('★「创建时间」必须走 v2（v3 会回 120）', () async {
      final a = await _api();
      await a.api.list(sortBy: DriveSortBy.createdTime);
      final call = _lastListCall(a.t);
      expect(call['sort_by'], 'created_time');
      expect(
        call['version'],
        '2',
        reason:
            '真机 v3 + sort_by=created_time 回 120（sort_by/condition），'
            'v2 正常 ⇒ 这个排序键必须发 v2',
      );
    });

    test('★ 其余排序键仍走 v3（不要把 v2 当成"统一版本"）', () async {
      for (final by in [
        DriveSortBy.name,
        DriveSortBy.size,
        DriveSortBy.modifiedTime,
      ]) {
        final a = await _api();
        await a.api.list(sortBy: by);
        final call = _lastListCall(a.t);
        expect(call['sort_by'], by.value);
        expect(call['version'], '3', reason: '${by.value} 在 v3 上实测成功');
      }
    });

    test('★ 不排序时不发 sort_by（默认序不能被菜单悄悄改掉）', () async {
      final a = await _api();
      await a.api.list();
      final call = _lastListCall(a.t);
      expect(call.containsKey('sort_by'), isFalse);
      expect(call['version'], '3');
    });
  });

  group('② 兜底：列表报错时不许把排序入口吞掉', () {
    Future<ProviderContainer> pump(WidgetTester tester, {required bool fail}) async {
      final t = FakeTransport({
        'SYNO.SynologyDrive.Files.list': _listData(),
      }, {...FakeTransport.table, ..._table});
      if (fail) t.failures['SYNO.SynologyDrive.Files.list'] = 120;
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
      return c;
    }

    testWidgets('★ 列表 120 + 已选排序 ⇒ 工具栏与「重置排序」都还在（不是死胡同）', (tester) async {
      final c = await pump(tester, fail: true);
      c.read(driveSortProvider.notifier).set(DriveSortBy.createdTime);
      // 改排序会重新拉列表：要等这一次请求再次失败落地（否则停在 loading）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 报错确实发生了
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      expect(
        find.byKey(const Key('drive-sort-menu')),
        findsOneWidget,
        reason:
            '★ 错误态里必须还能点排序 —— 否则"错误原因就是当前排序"时'
            '用户回不去（真机缺陷）',
      );
      expect(
        find.byKey(const Key('drive-sort-reset-on-error')),
        findsOneWidget,
        reason: '★ 一键重置是给用户的明确退路',
      );

      // 点重置 ⇒ 排序回到默认（并重新拉列表）
      await tester.tap(find.byKey(const Key('drive-sort-reset-on-error')));
      await tester.pump();
      expect(
        c.read(driveSortProvider).by,
        isNull,
        reason: '点「重置排序」必须真的把排序清掉',
      );
    });

    testWidgets('★ 没有排序时列表报错 ⇒ 不显示重置按钮（别加噪音）', (tester) async {
      await pump(tester, fail: true);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(
        find.byKey(const Key('drive-sort-reset-on-error')),
        findsNothing,
        reason: '没有排序可重置时不出现该按钮',
      );
    });

    testWidgets('★ 列表正常时错误兜底 UI 不该出现（回归保护）', (tester) async {
      await pump(tester, fail: false);
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.byKey(const Key('drive-sort-reset-on-error')), findsNothing);
      expect(find.byKey(const Key('drive-sort-menu')), findsOneWidget);
    });
  });
}
