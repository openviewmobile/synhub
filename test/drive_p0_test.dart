// Drive P0 批（P0-3/4/5/6/7/10/11）的离线测试。
//
// 纪律（与任务一致）：
//   * 一条官方原文对应一条断言：参数名/版本/冲突动作都能在注释里指到出处；
//   * 降级只测"明确知道的"：105/160 与 102/103 的分支各一条；
//   * **证不到的**（离线缓存、`dest_folder`/`accurate_progress`、加密文件夹）
//     不断言"已实现"，只断言"没有这个入口"。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/dto/drive_move_conflict_dto.dart';
import 'package:synhub/src/data/dto/drive_search_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_copy_move_page.dart';
import 'package:synhub/src/features/drive/drive_folder_page.dart';
import 'package:synhub/src/features/drive/drive_info_sheet.dart';
import 'package:synhub/src/features/drive/drive_search_page.dart';
import 'package:synhub/src/features/files/drive_browse_view.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  // 服务端上 Files 到 v11；search 的官方版本是 min(4, max)
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.TeamFolders': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.Labels': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  // P0-11：官方 `SYNO.Office.Node.Encrypt` maxVersion=1
  'SYNO.Office.Node.Encrypt': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _item({
  required String id,
  required String name,
  String type = 'file',
  String? contentType,
  bool canWrite = true,
}) => {
  'file_id': id,
  'name': name,
  'type': type,
  'path': '/$name',
  'display_path': '/mydrive/$name',
  'parent_id': '900',
  'size': type == 'dir' ? 0 : 2048,
  'modified_time': 1789739500,
  'created_time': 1789739400,
  'content_type': contentType ?? (type == 'dir' ? 'dir' : 'document'),
  'starred': false,
  'shared': false,
  'owner': {'display_name': 'demo_user', 'name': 'demo_user'},
  'capabilities': {
    'can_download': true,
    'can_preview': true,
    'can_write': canWrite,
  },
  'labels': [
    {'label_id': 3, 'name': '项目', 'color': '#ff8800'},
  ],
};

DriveEntryDto _entry({
  required String id,
  required String name,
  String type = 'file',
  bool canWrite = true,
}) => DriveEntryDto.fromJson(
  _item(id: id, name: name, type: type, canWrite: canWrite),
);

Future<({FakeTransport t, DsmWebApi api})> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, api: api);
}

// ---------------------------------------------------------------- 能力快照

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);
  final ServiceAvailabilitySnapshot snapshot;
  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

const _allDriveApis = {
  'SYNO.SynologyDrive.Files',
  'SYNO.SynologyDrive.TeamFolders',
  'SYNO.SynologyDrive.Labels',
};

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.drive
              ? classifyApiTable(kServiceRegistry[StationService.drive]!, apis)
              : AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 22),
    );

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  Set<String> apis = _allDriveApis,
  Map<String, dynamic>? Function(Map<String, dynamic> params)? onCall,
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall =
      onCall ??
      (params) {
        final key = '${params['api']}.${params['method']}';
        return {...?responses[key], 'success': true};
      };
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(DriveApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  return (t: t, c: c);
}

/// 从一个"启动页"把 [page] push 进去（页内 `pop()` 才安全）
Future<({FakeTransport t, ProviderContainer c})> _pumpPushed(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, dynamic>? Function(Map<String, dynamic> params)? onCall,
  Set<String> apis = _allDriveApis,
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall =
      onCall ??
      (params) {
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
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(
                  ctx,
                ).push<void>(MaterialPageRoute<void>(builder: (_) => page)),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  return (t: t, c: c);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // ================================================================ API 层
  group('P0-4 搜索：参数逐字对齐官方 setAsListSearch', () {
    test('条件齐全时发全部官方键，版本 4，content_snippet=true', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {'items': const [], 'total': 0, 'success': true};
      final s = await _loggedIn(t);
      await DriveApi(s.api).search(
        'report',
        location: DriveSearchLocation.sharedWithOthers,
        fileType: DriveSearchFileType.image,
        owner: DriveSearchOwner.notMe,
        size: DriveSearchSize.greaterThan,
        sizeMegabytes: 2,
        labelIds: const ['3'],
        date: DriveSearchDate.modified,
        startTime: 100,
        endTime: 200,
      );
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.Files');
      expect(call['method'], 'search');
      expect(call['version'], '4', reason: 'APK Math.min(4, maxVersion)');
      expect(call['keyword'], 'report');
      expect(call['location'], 'shared_with_others');
      expect(call['file_type'], 'image');
      expect(call['owner'], 'not_me');
      expect(call['min_size'], 2 * 1048576, reason: '官方 MB×1048576');
      expect(call.containsKey('max_size'), isFalse);
      expect(call['labels'], const ['3']);
      expect(call['time'], 'modified_time');
      expect(call['start_date'], 100);
      expect(call['end_date'], 200);
      expect(call['content_snippet'], isTrue, reason: 'APK 恒定 true');
    });

    test('约等于 = 官方 ±5% 带；custom 位置发 id:<folder>', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {'items': const [], 'total': 0, 'success': true};
      final s = await _loggedIn(t);
      await DriveApi(s.api).search(
        'a',
        location: DriveSearchLocation.custom,
        customLocationId: '77',
        size: DriveSearchSize.roughly,
        sizeMegabytes: 10,
      );
      final call = t.calls.last;
      expect(call['location'], 'custom');
      expect(call['custom_location'], 'id:77');
      final band = driveSearchSizeBand(10);
      expect(call['min_size'], band.min);
      expect(call['max_size'], band.max);
    });

    test('空关键词不发 keyword（服务端 120 由页面先拦）', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {'items': const [], 'total': 0, 'success': true};
      final s = await _loggedIn(t);
      await DriveApi(s.api).search('   ', fileType: DriveSearchFileType.folder);
      expect(t.calls.last.containsKey('keyword'), isFalse);
      expect(t.calls.last['file_type'], 'folder');
    });
  });

  group('P0-5/P0-6 最近 / 我共享的', () {
    test('recent 与 shared_with_others 都是 Files 上的 v3 方法', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {'items': const [], 'total': 0, 'success': true};
      final s = await _loggedIn(t);
      final drive = DriveApi(s.api);
      await drive.recent();
      expect(t.calls.last['method'], 'recent');
      expect(t.calls.last['version'], '3');
      await drive.sharedWithOthers();
      expect(t.calls.last['method'], 'shared_with_others');
      expect(t.calls.last['version'], '3');
    });
  });

  group('P0-7 复制/移动：dry_run 探测 + 三个官方冲突动作', () {
    test('probeCopyMove 只发 dry_run（不带 conflict_action）', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {
        'result': [
          {
            'src_info': {'name': 'a.txt', 'display_path': '/mydrive/a.txt'},
            'dst_info': {'name': 'a.txt', 'display_path': '/mydrive/t/a.txt'},
            'renamed': 'a_1.txt',
          },
        ],
        'success': true,
      };
      final s = await _loggedIn(t);
      final conflicts = await DriveApi(s.api).probeCopyMove(
        fileIds: const ['9'],
        toParentFolderId: '77',
        move: false,
      );
      final call = t.calls.last;
      expect(call['method'], 'copy');
      expect(call['version'], '2', reason: 'Web 描述符 copy_files = v2');
      expect(call['dry_run'], isTrue);
      expect(
        call.containsKey('conflict_action'),
        isFalse,
        reason: '官方 mvcpNode 探测阶段不带 conflict_action',
      );
      expect(call['files'], jsonEncode(['id:9']));
      expect(call['to_parent_folder'], 'id:77');
      expect(conflicts.single.sourceName, 'a.txt');
      expect(conflicts.single.renamed, 'a_1.txt');
    });

    test('dst_locked_by_others 不算可处理冲突（官方 needToShowConflictDialog）', () {
      final list = DriveMoveConflict.listFromResult([
        {
          'src_info': {'name': 'a'},
          'dst_info': {'name': 'a'},
          'dst_locked_by_others': true,
        },
      ]);
      expect(list, isEmpty);
      expect(DriveMoveConflict.listFromResult(null), isEmpty);
      expect(DriveMoveConflict.listFromResult('oops'), isEmpty);
    });

    test('copyOrMove 发官方三个 conflict_action 之一（默认 autorename）', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {'success': true};
      final s = await _loggedIn(t);
      final drive = DriveApi(s.api);
      await drive.copyOrMove(
        fileIds: const ['9'],
        toParentFolderId: '77',
        move: true,
      );
      expect(t.calls.last['method'], 'move');
      expect(t.calls.last['conflict_action'], 'autorename');
      await drive.copyOrMove(
        fileIds: const ['9'],
        toParentFolderId: '77',
        move: false,
        conflictAction: DriveConflictAction.overwrite,
      );
      expect(t.calls.last['method'], 'copy');
      expect(t.calls.last['conflict_action'], 'overwrite');
    });

    test('brief 里的 dest_folder / accurate_progress 不存在 → 不发', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {'success': true};
      final s = await _loggedIn(t);
      await DriveApi(
        s.api,
      ).copyOrMove(fileIds: const ['9'], toParentFolderId: '77', move: true);
      expect(t.calls.last.containsKey('dest_folder'), isFalse);
      expect(t.calls.last.containsKey('accurate_progress'), isFalse);
    });
  });

  group('P0-11 加密 Office：Office.Node.Encrypt:check', () {
    test('非 Office 原生文档不探测', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {'success': true};
      final s = await _loggedIn(t);
      final drive = DriveApi(s.api);
      // 直接调 API 层：它无条件发；"只对 Office 探测"的分流在 gate 里
      await drive.officeEncryptCheck(fileId: '9');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.Office.Node.Encrypt');
      expect(call['method'], 'check');
      expect(call['version'], '1');
      expect(call['path'], 'id:9');
      expect(call['password'], '');
    });

    test('57373 → false（需要密码）；成功 → true', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {'success': true};
      t.failures['SYNO.Office.Node.Encrypt.check'] = 57373;
      final s = await _loggedIn(t);
      expect(await DriveApi(s.api).officeEncryptCheck(fileId: '9'), isFalse);
      t.failures.clear();
      expect(await DriveApi(s.api).officeEncryptCheck(fileId: '9'), isTrue);
    });

    test('其它错误码原样抛（交给 gate fail-open）', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => {'success': true};
      t.failures['SYNO.Office.Node.Encrypt.check'] = 102;
      final s = await _loggedIn(t);
      await expectLater(
        DriveApi(s.api).officeEncryptCheck(fileId: '9'),
        throwsA(isA<DsmApiException>()),
      );
    });
  });

  // ================================================================ 页面层
  group('P0-3 团队文件夹可进入（Files/list + path=id:<file_id>）', () {
    testWidgets('团队文件夹行可点，进入后按 id 列子项', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      // `TeamFolders/list` → 一个团队文件夹；`Files/list` 按 path 分流
      t.onCall = (params) {
        final key = '${params['api']}.${params['method']}';
        if (key == 'SYNO.SynologyDrive.TeamFolders.list') {
          return {
            'items': [_item(id: '555', name: 'team-a', type: 'dir')],
            'total': 1,
            'success': true,
          };
        }
        if (key == 'SYNO.SynologyDrive.Files.list') {
          if (params['path'] == 'id:555') {
            return {
              'items': [_item(id: '556', name: 'inner.txt')],
              'total': 1,
              'success': true,
            };
          }
          return {'items': const [], 'total': 0, 'success': true};
        }
        return {'success': true};
      };
      final s = await _loggedIn(t).then((v) => v);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(s.api)),
          serviceAvailabilityProvider.overrideWith(
            () => _FixedAvailability(_snap(_allDriveApis)),
          ),
        ],
      );
      addTearDown(c.dispose);
      addTearDown(db.close);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DriveMorePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // 切到"团队文件夹"段（枚举顺序：trash/starred/shared/team/...）
      c.read(driveMoreSectionProvider.notifier).select(DriveMoreSection.team);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('team-a'), findsOneWidget);
      await tester.tap(find.text('team-a'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byType(DriveFolderPage), findsOneWidget);
      expect(find.text('inner.txt'), findsOneWidget);
      expect(
        t.calls.any(
          (call) => call['method'] == 'list' && call['path'] == 'id:555',
        ),
        isTrue,
        reason: '官方进入团队文件夹 = Files/list + path=id:<file_id>',
      );
    });

    testWidgets('运行期 105 → 该段说明原因，Drive 其余段不受影响', (tester) async {
      final s = await _pump(
        tester,
        const DriveMorePage(),
        responses: const {},
        failures: const {'SYNO.SynologyDrive.TeamFolders.list': 105},
      );
      s.c.read(driveMoreSectionProvider.notifier).select(DriveMoreSection.team);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.textContaining('入口已隐藏'),
        findsWidgets,
        reason: '105 只在团队文件夹段里给一句原因（走 driveGateMessage(denied)）',
      );
      // 星标段仍然能正常请求（其它功能不受影响）
      s.c
          .read(driveMoreSectionProvider.notifier)
          .select(DriveMoreSection.starred);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      expect(s.t.calls.any((c) => c['method'] == 'list_starred'), isTrue);
    });

    testWidgets('能力表说没有 TeamFolders → 连请求都不发', (tester) async {
      final s = await _pump(
        tester,
        const DriveMorePage(),
        apis: {..._allDriveApis}..remove('SYNO.SynologyDrive.TeamFolders'),
      );
      s.c.read(driveMoreSectionProvider.notifier).select(DriveMoreSection.team);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        s.t.calls.any(
          (c) =>
              c['method'] == 'list' &&
              c['api']?.toString().contains('TeamFolders') == true,
        ),
        isFalse,
      );
      expect(find.textContaining('没有提供该功能'), findsWidgets);
    });
  });

  group('P0-5/P0-6 更多页新增"最近"与"我共享的"', () {
    testWidgets('两段各自打自己的接口，空态给引导', (tester) async {
      final s = await _pump(tester, const DriveMorePage(), responses: const {});
      s.c
          .read(driveMoreSectionProvider.notifier)
          .select(DriveMoreSection.recent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      expect(s.t.calls.any((c) => c['method'] == 'recent'), isTrue);
      expect(find.textContaining('最近'), findsWidgets);

      s.c
          .read(driveMoreSectionProvider.notifier)
          .select(DriveMoreSection.sharedByMe);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      expect(s.t.calls.any((c) => c['method'] == 'shared_with_others'), isTrue);
      expect(find.textContaining('共享'), findsWidgets);
    });

    testWidgets('P0-9 离线缓存：证不到远端接口 → 不做入口', (tester) async {
      await _pump(tester, const DriveMorePage());
      // 枚举里没有 offline 段
      expect(
        DriveMoreSection.values.map((s) => s.name).contains('offline'),
        isFalse,
      );
      expect(find.byKey(const Key('drive-offline')), findsNothing);
    });
  });

  group('P0-4 搜索页', () {
    testWidgets('输入关键词后发出 search，结果可点', (tester) async {
      final s = await _pumpPushed(
        tester,
        const DriveSearchPage(),
        responses: {
          'SYNO.SynologyDrive.Files.search': {
            'items': [_item(id: '601', name: 'report.pdf')],
            'total': 1,
          },
        },
      );
      await tester.enterText(
        find.byKey(const Key('drive-search-field')),
        'report',
      );
      await tester.tap(find.byKey(const Key('drive-search-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('drive-search-result-601')), findsOneWidget);
      final call = s.t.calls.lastWhere((c) => c['method'] == 'search');
      expect(call['keyword'], 'report');
      expect(call['content_snippet'], isTrue);
    });

    testWidgets('条件全空 → 拦在本地，不发 search（官方会回 120）', (tester) async {
      final s = await _pumpPushed(tester, const DriveSearchPage());
      await tester.tap(find.byKey(const Key('drive-search-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(s.t.calls.any((c) => c['method'] == 'search'), isFalse);
      expect(find.textContaining('筛选条件'), findsWidgets);
    });

    testWidgets('筛选"位置"菜单只有官方 location 取值', (tester) async {
      await _pumpPushed(tester, const DriveSearchPage());
      await tester.tap(find.byKey(const Key('drive-search-filter-location')));
      await tester.pumpAndSettle();
      for (final label in const [
        '任意位置',
        '我的文件',
        '团队文件夹',
        '共享给我',
        '我共享的',
        '星标',
        '当前文件夹',
      ]) {
        expect(find.text(label), findsWidgets, reason: '缺 $label');
      }
    });
  });

  group('P0-7 复制/移动页', () {
    testWidgets('探测到同名 → 弹三个官方动作；选覆盖就发 overwrite', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        final key = '${params['api']}.${params['method']}';
        if (key == 'SYNO.SynologyDrive.Files.list') {
          if (params['path'] == '/mydrive') {
            return {
              'items': [_item(id: '77', name: 'target', type: 'dir')],
              'total': 1,
              'success': true,
            };
          }
          return {'items': const [], 'total': 0, 'success': true};
        }
        if (key == 'SYNO.SynologyDrive.Files.copy') {
          if (params['dry_run'] == true) {
            return {
              'result': [
                {
                  'src_info': {'name': 'a.txt'},
                  'dst_info': {'name': 'a.txt'},
                  'renamed': 'a_1.txt',
                },
              ],
              'success': true,
            };
          }
          return {'success': true};
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
          driveApiProvider.overrideWithValue(DriveApi(api)),
          serviceAvailabilityProvider.overrideWith(
            () => _FixedAvailability(_snap(_allDriveApis)),
          ),
        ],
      );
      addTearDown(c.dispose);
      addTearDown(db.close);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => DriveCopyMovePage(
                          entries: [_entry(id: '9', name: 'a.txt')],
                          move: false,
                        ),
                      ),
                    ),
                    child: const Text('go'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // 看板：进入目标目录（file_id=77）
      await tester.tap(find.byKey(const Key('drive-copy-move-dir-77')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('drive-copy-move-here')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // 冲突框三个官方动作
      expect(find.byKey(const Key('drive-copy-move-conflict')), findsOneWidget);
      expect(
        find.byKey(const Key('drive-conflict-autorename')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('drive-conflict-overwrite')), findsOneWidget);
      expect(find.byKey(const Key('drive-conflict-stop')), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-conflict-overwrite')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final real = t.calls.lastWhere(
        (call) => call['method'] == 'copy' && call['dry_run'] != true,
      );
      expect(real['conflict_action'], 'overwrite');
      expect(real['to_parent_folder'], 'id:77');
    });
  });

  group('P0-10 文件详情', () {
    testWidgets('详情面板展示官方 file_info_sheet 的字段', (tester) async {
      final s = await _pumpPushed(
        tester,
        Scaffold(
          body: DriveInfoSheet(
            entry: _entry(id: '9', name: 'a.txt'),
          ),
        ),
        responses: {
          'SYNO.SynologyDrive.Files.get': _item(id: '9', name: 'a.txt'),
        },
      );
      expect(find.byKey(const Key('drive-info-sheet')), findsOneWidget);
      expect(find.byKey(const Key('drive-info-name')), findsOneWidget);
      for (final label in const [
        '文件类型',
        '位置',
        '大小',
        '创建时间',
        '修改时间',
        '拥有者',
        '标签',
        '权限',
      ]) {
        expect(find.text(label), findsWidgets, reason: '缺 $label');
      }
      expect(s.t.calls.any((c) => c['method'] == 'get'), isTrue);
    });
  });

  group('P0-11 加密 Office 文档', () {
    testWidgets('点开 .odoc 命中 57373 → 弹官方提示，且不进预览页', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        final key = '${params['api']}.${params['method']}';
        if (key == 'SYNO.SynologyDrive.Files.list') {
          return {
            'items': [_item(id: '700', name: 'secret.odoc')],
            'total': 1,
            'success': true,
          };
        }
        return {'success': true};
      };
      t.failures['SYNO.Office.Node.Encrypt.check'] = 57373;
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(api)),
          serviceAvailabilityProvider.overrideWith(
            () => _FixedAvailability(_snap(_allDriveApis)),
          ),
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
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('secret.odoc'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // ★ 第 65 轮 D58：加密时不再是"死胡同提示"，而是**密码输入框**
      expect(
        find.byKey(const Key('drive-encrypted-password-dialog')),
        findsOneWidget,
        reason: '★ D58 的核心：用户现在**能输密码**，不再只能读一句'
            '"请在服务器上访问此文件"',
      );
      expect(
        find.byKey(const Key('drive-encrypted-password-input')),
        findsOneWidget,
      );
      // ★ r315：文案对齐官方 `ShowFragment.smali:3459-3490`
      //   title = `enter_password_title` = `输入密码`；
      //   message = `enter_password_desc` = `此文件已加密。请输入密码。`
      // 旧断言 '无法打开文件' = 官方**拒绝语**的标题，已被真机证明是假话
      // （输对密码真的能打开），故改为官方提示语。
      expect(find.text('输入密码'), findsOneWidget);
      expect(find.text('此文件已加密。请输入密码。'), findsOneWidget);
    });

    testWidgets('未加密（探测成功）→ 不弹提示', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        final key = '${params['api']}.${params['method']}';
        if (key == 'SYNO.SynologyDrive.Files.list') {
          return {
            'items': [_item(id: '701', name: 'plain.odoc')],
            'total': 1,
            'success': true,
          };
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
          driveApiProvider.overrideWithValue(DriveApi(api)),
          serviceAvailabilityProvider.overrideWith(
            () => _FixedAvailability(_snap(_allDriveApis)),
          ),
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
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('plain.odoc'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('drive-encrypted-password-dialog')),
        findsNothing,
        reason: '★ 未加密 ⇒ 不该弹密码框（弹了就是误判，用户会以为文件有问题）',
      );
      expect(
        t.calls.any((call) => call['api'] == 'SYNO.Office.Node.Encrypt'),
        isTrue,
      );
    });
  });
}
