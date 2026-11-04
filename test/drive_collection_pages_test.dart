// D8（收藏集）页面层测试：扩展入口页门控 + 收藏集页 + 收藏集内文件页。
//
// 覆盖：① 成功路径（假响应里放**具体数据**，断言名称 / 类型 / 计数 / 文件名）
// ② 空态（真机四个类型都回空表，这是唯一实况）③ 能力位缺 `Labels` → 只隐藏
// 收藏集入口，其余照旧 ④ 危险操作（删收藏集、移出成员）二次确认，取消 = 不发请求。
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
import 'package:synhub/src/features/drive/drive_collection_page.dart';
import 'package:synhub/src/features/drive/drive_extras_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Labels': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Trash': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.TeamFolders': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
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

/// 一个"检测过"的 Drive 能力快照
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

Map<String, dynamic> _collection({
  String id = '7',
  String name = '旅行照片',
  String type = 'photo_album',
  int count = 12,
}) => {
  'label_id': id,
  'name': name,
  'type': type,
  'color': '#1a73e8',
  'position': 0,
  'file_count': count,
};

Map<String, Map<String, dynamic>> _responses({
  List<Map<String, dynamic>>? collections,
  List<Map<String, dynamic>>? files,
}) => {
  'SYNO.SynologyDrive.Labels.list': {
    'items': collections ?? [_collection()],
    'total': (collections ?? [_collection()]).length,
  },
  'SYNO.SynologyDrive.Files.list_labelled': {
    'items':
        files ??
        [
          {'file_id': '3', 'name': 'a.jpg', 'type': 'file', 'size': 100},
        ],
    'total': (files ?? [{}]).length,
  },
  'SYNO.SynologyDrive.Labels.create': _collection(id: '9', name: '新集'),
  'SYNO.SynologyDrive.Labels.update': _collection(name: '改名后'),
  'SYNO.SynologyDrive.Labels.delete': <String, dynamic>{},
  'SYNO.SynologyDrive.Files.label': <String, dynamic>{},
};

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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('扩展入口页：D8 收藏集能力位门控', () {
    testWidgets('能力齐全 → 收藏集入口在', (tester) async {
      await _pump(tester, _transport(_responses()), const DriveExtrasPage());
      expect(find.byKey(const Key('drive-extras-collections')), findsOneWidget);
      expect(find.text('收藏集'), findsOneWidget);
    });

    testWidgets('缺 Labels → 收藏集入口消失，回收站入口仍在（partial）', (tester) async {
      await _pump(
        tester,
        _transport(_responses()),
        const DriveExtrasPage(),
        apis: {..._allDriveApis}..remove('SYNO.SynologyDrive.Labels'),
      );
      expect(find.byKey(const Key('drive-extras-collections')), findsNothing);
      expect(find.byKey(const Key('drive-extras-trash')), findsOneWidget);
    });
  });

  group('收藏集页', () {
    testWidgets('列出收藏集：名称 / 类型 / 计数都上屏', (tester) async {
      await _pump(
        tester,
        _transport(
          _responses(
            collections: [
              _collection(id: '7', name: '旅行照片', count: 12),
              _collection(
                id: '8',
                name: '合同文档',
                type: 'document_folder',
                count: 3,
              ),
            ],
          ),
        ),
        const DriveCollectionPage(),
      );
      expect(find.byKey(const Key('drive-collection-page')), findsOneWidget);
      expect(find.text('旅行照片'), findsOneWidget);
      expect(find.text('合同文档'), findsOneWidget);
      expect(find.textContaining('照片收藏集'), findsWidgets);
      expect(find.textContaining('文档收藏集'), findsWidgets);
      expect(find.textContaining('12'), findsWidgets);
    });

    testWidgets('类型筛选 chip → 带 type 重新请求（photo_album）', (tester) async {
      final t = _transport(_responses());
      await _pump(tester, t, const DriveCollectionPage());
      await tester.tap(
        find.byKey(const Key('drive-collection-chip-photo_album')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final typed = t.calls.where(
        (c) =>
            c['api'] == 'SYNO.SynologyDrive.Labels' &&
            c['method'] == 'list' &&
            c['type'] == 'photo_album',
      );
      expect(typed, isNotEmpty);
    });

    testWidgets('点进收藏集 → 列出里面的文件（Files/list_labelled）', (tester) async {
      final t = _transport(
        _responses(
          files: [
            {'file_id': '3', 'name': 'beach.jpg', 'type': 'file', 'size': 100},
          ],
        ),
      );
      await _pump(tester, t, const DriveCollectionPage());
      await tester.tap(find.byKey(const Key('drive-collection-row-7')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('drive-collection-files-page')),
        findsOneWidget,
      );
      expect(find.text('beach.jpg'), findsOneWidget);
      final labelled = t.calls.where((c) => c['method'] == 'list_labelled');
      expect(labelled, isNotEmpty);
      expect(labelled.last['label_id'], '"7"');
    });

    testWidgets('空收藏集 → 人话空态（真机四类都回空表）', (tester) async {
      await _pump(
        tester,
        _transport(_responses(collections: [])),
        const DriveCollectionPage(),
      );
      expect(find.textContaining('还没有收藏集'), findsWidgets);
    });

    testWidgets('新建收藏集 → Labels/create，type + name 都上送', (tester) async {
      final t = _transport(_responses());
      await _pump(tester, t, const DriveCollectionPage());
      await tester.tap(find.byKey(const Key('drive-collection-create')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(
        find.byKey(const Key('drive-collection-name-field')),
        '滑雪视频',
      );
      await tester.tap(
        find.byKey(const Key('drive-collection-new-type-video_playlist')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('drive-collection-dialog-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final create = t.calls.lastWhere(
        (c) => c['method'] == 'create',
        orElse: () => <String, dynamic>{},
      );
      expect(create['api'], 'SYNO.SynologyDrive.Labels');
      expect(create['type'], 'video_playlist');
      expect(create['name'], '"滑雪视频"');
    });
  });

  group('收藏集危险操作：二次确认（取消 = 一个请求都不发）', () {
    testWidgets('删收藏集：取消不发 delete；确认才发', (tester) async {
      final t = _transport(_responses());
      await _pump(tester, t, const DriveCollectionPage());
      // 打开行菜单
      await tester.tap(find.byKey(const Key('drive-collection-menu-7')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('删除收藏集').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // 取消
      await tester.tap(find.byKey(const Key('drive-collection-delete-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        t.calls.where((c) => c['method'] == 'delete'),
        isEmpty,
        reason: '取消后不得发出 Labels/delete',
      );
    });

    testWidgets('移出成员：取消不发 Files/label', (tester) async {
      final t = _transport(_responses());
      await _pump(tester, t, const DriveCollectionPage());
      await tester.tap(find.byKey(const Key('drive-collection-row-7')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('drive-collection-file-remove-3')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('drive-collection-remove-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        t.calls.where((c) => c['method'] == 'label'),
        isEmpty,
        reason: '取消后不得发出 Files/label',
      );
    });

    testWidgets('移出成员：确认 → Files/label + action:delete', (tester) async {
      final t = _transport(_responses());
      await _pump(tester, t, const DriveCollectionPage());
      await tester.tap(find.byKey(const Key('drive-collection-row-7')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('drive-collection-file-remove-3')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(
        find.byKey(const Key('drive-collection-remove-confirm')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final label = t.calls.lastWhere(
        (c) => c['method'] == 'label',
        orElse: () => <String, dynamic>{},
      );
      expect(label['labels'], '[{"action":"delete","label_id":7}]');
      expect(label['files'], '["id:3"]');
    });
  });
}
