// D12（团队文件夹回收站）页面层测试。
//
// 覆盖：① 先列团队文件夹（只读）② 点进去看该文件夹的回收站
// （`Trash/list` + `path=id:<folder_id>`，**这是真机验过的只读形态**）
// ③ 还原 = `Revisions/restore`（写：只断言参数）④ 彻底删除二次确认
// （取消 = 不发 `Files/delete`）⑤ 没有"清空"入口（官方对团队文件夹没有）
// ⑥ 能力位缺 `TeamFolders` → 入口隐藏。
//
// ⚠️ 真机上**只验列表**这一只读部分；还原 / 彻底删除本批不真调（§5.1）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_extras_page.dart';
import 'package:synhub/src/features/drive/drive_team_trash_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.TeamFolders': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.Trash': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Revisions': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Labels': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.SynologyDrive.Notifications': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.FileRequest': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

ServiceAvailabilitySnapshot _snap(Set<String> driveApis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.drive
              ? classifyApiTable(
                  kServiceRegistry[StationService.drive]!,
                  driveApis,
                )
              : AvailabilityState.available,
      },
      apis: driveApis,
      checkedAt: DateTime(2026, 9, 22),
    );

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

const _allDriveApis = {
  'SYNO.SynologyDrive.Files',
  'SYNO.SynologyDrive.Labels',
  'SYNO.SynologyDrive.Trash',
  'SYNO.SynologyDrive.TeamFolders',
  'SYNO.SynologyDrive.Notifications',
  'SYNO.SynologyDrive.FileRequest',
};

Map<String, dynamic> _teamFolder({
  String id = '974457808523148038',
  String name = '设计部',
}) => {
  'file_id': id,
  'name': name,
  'type': 'dir',
  'display_path': '/team-folders/$name',
  'owner': {'display_name': 'admin'},
};

Map<String, dynamic> _trashItem() => {
  'file_id': '9',
  'name': 'team-note.txt',
  'type': 'file',
  'path': '/recycle-bin/team-folders/t1/team-note.txt',
  'display_path': '/team-folders/设计部/team-note.txt',
  'recycled_time': 1789775507,
  'size': 4096,
  'owner': {'display_name': 'demo_user'},
};

Map<String, Map<String, dynamic>> _responses({
  List<Map<String, dynamic>>? folders,
  List<Map<String, dynamic>>? trash,
}) {
  final f = folders ?? [_teamFolder()];
  final tr = trash ?? [_trashItem()];
  return {
    'SYNO.SynologyDrive.TeamFolders.list': {'items': f, 'total': f.length},
    'SYNO.SynologyDrive.Trash.list': {'items': tr, 'total': tr.length},
    'SYNO.SynologyDrive.Revisions.restore': {'async_task_id': 'task-9'},
    'SYNO.SynologyDrive.Files.delete': {'async_task_id': 'task-10'},
  };
}

FakeTransport _transport(Map<String, Map<String, dynamic>> responses) {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  return t;
}

Future<void> _pump(
  WidgetTester tester,
  FakeTransport t,
  Widget page, {
  Set<String> apis = _allDriveApis,
}) async {
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
}

/// 进到"某个团队文件夹的回收站"页
Future<void> _openFolderTrash(WidgetTester tester, FakeTransport t) async {
  await _pump(tester, t, const DriveTeamTrashPage());
  await tester.tap(
    find.byKey(const Key('drive-team-trash-folder-974457808523148038')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('扩展入口页：D12 团队文件夹回收站能力位门控', () {
    testWidgets('有 TeamFolders → 入口在', (tester) async {
      await _pump(tester, _transport(_responses()), const DriveExtrasPage());
      expect(find.byKey(const Key('drive-extras-team-trash')), findsOneWidget);
      expect(find.text('团队文件夹回收站'), findsOneWidget);
    });

    testWidgets('缺 TeamFolders → 入口消失，回收站入口仍在', (tester) async {
      await _pump(
        tester,
        _transport(_responses()),
        const DriveExtrasPage(),
        apis: {..._allDriveApis}..remove('SYNO.SynologyDrive.TeamFolders'),
      );
      expect(find.byKey(const Key('drive-extras-team-trash')), findsNothing);
      expect(find.byKey(const Key('drive-extras-trash')), findsOneWidget);
    });
  });

  group('团队文件夹回收站页（只读列表，真机验过这条）', () {
    testWidgets('先列团队文件夹，名称上屏', (tester) async {
      await _pump(tester, _transport(_responses()), const DriveTeamTrashPage());
      expect(find.byKey(const Key('drive-team-trash-page')), findsOneWidget);
      expect(find.text('设计部'), findsOneWidget);
    });

    testWidgets('没有团队文件夹 → 人话空态', (tester) async {
      await _pump(
        tester,
        _transport(_responses(folders: [])),
        const DriveTeamTrashPage(),
      );
      expect(find.textContaining('没有团队文件夹'), findsWidgets);
    });

    testWidgets('点进团队文件夹 → Trash/list path=id:<folder_id>，条目字段上屏', (
      tester,
    ) async {
      final t = _transport(_responses());
      await _openFolderTrash(tester, t);
      expect(find.byKey(const Key('drive-folder-trash-page')), findsOneWidget);
      expect(find.text('team-note.txt'), findsOneWidget);
      expect(
        find.textContaining('/team-folders/设计部/team-note.txt'),
        findsWidgets,
      );
      final trashCall = t.calls.lastWhere(
        (c) => c['method'] == 'list' && c['api'] == 'SYNO.SynologyDrive.Trash',
      );
      expect(trashCall['path'], 'id:974457808523148038');
      // 本机 Trash maxVersion=2（API.Info），协商出的就是 2
      expect(trashCall['version'], '2');
    });

    testWidgets('没有"清空"入口（官方对团队文件夹没有清空）', (tester) async {
      final t = _transport(_responses());
      await _openFolderTrash(tester, t);
      expect(find.byKey(const Key('drive-trash-empty')), findsNothing);
      // 页面也不应发过 Trash/empty
      expect(t.calls.where((c) => c['method'] == 'empty'), isEmpty);
    });
  });

  group('团队文件夹回收站：还原 / 彻底删除（写方法，本批不真调）', () {
    testWidgets('还原 → Revisions/restore，files=[{path:id:<id>}]', (
      tester,
    ) async {
      final t = _transport(_responses());
      await _openFolderTrash(tester, t);
      await tester.tap(find.byKey(const Key('drive-folder-trash-restore-9')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final call = t.calls.lastWhere(
        (c) => c['method'] == 'restore',
        orElse: () => <String, dynamic>{},
      );
      expect(call['api'], 'SYNO.SynologyDrive.Revisions');
      expect(call['version'], '1');
      expect(call['files'], '[{"path":"id:9"}]');
    });

    testWidgets('彻底删除：取消不发 Files/delete', (tester) async {
      final t = _transport(_responses());
      await _openFolderTrash(tester, t);
      await tester.tap(
        find.byKey(const Key('drive-folder-trash-delete-forever-9')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(
        find.byKey(const Key('drive-folder-trash-delete-cancel')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(t.calls.where((c) => c['method'] == 'delete'), isEmpty);
    });

    testWidgets('彻底删除：确认 → Files/delete + permanent:true', (tester) async {
      final t = _transport(_responses());
      await _openFolderTrash(tester, t);
      await tester.tap(
        find.byKey(const Key('drive-folder-trash-delete-forever-9')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(
        find.byKey(const Key('drive-folder-trash-delete-confirm')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final call = t.calls.lastWhere(
        (c) => c['method'] == 'delete',
        orElse: () => <String, dynamic>{},
      );
      expect(call['api'], 'SYNO.SynologyDrive.Files');
      expect(call['version'], '2');
      expect(call['files'], '["id:9"]');
      expect(call['permanent'], isTrue);
    });
  });
}
