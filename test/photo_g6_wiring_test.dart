// 相册 **G6 批次**离线用例：
//   * 用户后台任务 `SYNO.Foto.BackgroundTask.Info:list_user_task`（v1）；
//   * 迁移状态 `SYNO.Foto.Migration:get_status`（v1）。
//
// ## 契约来源（**离线**，本次不发起任何 NAS 请求）
//
// * 方法表：`/tmp/spk/export_SynologyPhotos/usr/webapi/SYNO.Foto.lib`
//   → 两者都 `minVersion:1, maxVersion:1`；
//   `BackgroundTask.Info` v1 = `abort_task/clear_completed_task/get_error_detail/
//   get_status/list_user_task`，`Migration` v1 = `get_status`；
// * 后台任务条目字段：官方 Web 前端 `ui/react_bundle.js` 的 `listUserTask()`
//   映射函数逐字（`id` / `target_folder` / `operation` / `status` / `total` /
//   `completion` / `error` / `skip` / `overwrite` / `create_time` / `extra_info`）；
//   状态枚举 `waiting/processing/aborting/done`，操作枚举 `copy/move`；
// * 迁移字段：`usr/lib/libwebapi-impl-migration.so` 字符串常量
//   `current` / `status` / `title_key` / `total`，状态字面值 `done` / `running`；
// * 真机只读实测（`docs/g6-api-probe-facts.md:38-39`）：
//   `{"list": []}`、`{"current":2,"status":"done","title_key":"","total":0}`。
//
// ## 本文件要钉死的四件事
//
// ① 版本协商走 `SYNO.API.Info` 的区间（**不硬编码 maxVersion**）；
// ② **空响应 → 人话空态**（真机上就是这两支）；
// ③ 枚举串（`status` / `operation` / `title_key`）**只映射已知值，
//    未知值绝不透原文**；
// ④ 内部 id（任务 `id`）**绝不上屏**。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/dto/foto_g6_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/foto_g6_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_background_tasks_page.dart';
import 'package:synhub/src/features/photos/photo_c2_page.dart';
import 'package:synhub/src/features/photos/photo_c2_providers.dart';
import 'package:synhub/src/features/photos/photo_g6_providers.dart';
import 'package:synhub/src/features/photos/photo_migration_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Browse.Album': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  // G6 的两个**全局** API（真机 `SYNO.API.Info`：v1..1 path=entry.cgi）
  'SYNO.Foto.BackgroundTask.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Migration': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// 真机回包逐字：`{"list": []}`
Map<String, dynamic> _emptyTasks() => {'list': []};

/// 真机回包逐字：`{"current": 2, "status": "done", "title_key": "", "total": 0}`
Map<String, dynamic> _doneMigration() => {
  'current': 2,
  'status': 'done',
  'title_key': '',
  'total': 0,
};

/// 条目字段**逐字**用官方 `listUserTask()` 映射里读的键名。
Map<String, dynamic> _taskItem() => {
  'id': 987654,
  'operation': 'copy',
  'status': 'processing',
  'total': 10,
  'completion': 4,
  'error': 1,
  'skip': 0,
  'overwrite': 2,
  'create_time': 1789775507,
  'target_folder': {'id': 1030, 'owner_user_id': 4},
  'extra_info': {'version': 2},
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
}) {
  final t = FakeTransport({...responses}, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.Foto.Setting.User.get') {
      return {
        'team_space_permission': 'none',
        'enable_person': true,
        'enable_similar': true,
      };
    }
    return responses[key] ?? const <String, dynamic>{};
  };
  return t;
}

Map<String, dynamic> _callOf(FakeTransport t, String api) =>
    t.calls.lastWhere((c) => c['api'] == api);

const _allApis = {
  'SYNO.Foto.Browse.Item',
  'SYNO.Foto.Browse.Album',
  'SYNO.Foto.Streaming',
  'SYNO.Foto.Thumbnail',
  'SYNO.Foto.Download',
  'SYNO.Foto.Setting.User',
  kFotoSharingApi,
  kFotoPhotoRequestApi,
  kFotoGeocodingApi,
  kFotoSearchApi,
  kFotoSearchFilterApi,
  kFotoConditionAlbumApi,
  kFotoSimilarApi,
  kFotoGeneralTagApi,
  kFotoPersonApi,
  kFotoRecentlyAddedApi,
  kFotoBackgroundTaskInfoApi,
  kFotoMigrationApi,
};

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.photo
              ? classifyApiTable(kServiceRegistry[StationService.photo]!, apis)
              : AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 22),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> apis = _allApis,
}) async {
  final t = _transport(responses: responses);
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
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
  await _settle(tester);
  return (t: t, c: c);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('① 接口层：BackgroundTask.Info/list_user_task', () {
    test('api/method 逐字正确；版本走能力表协商（1..1 → v1）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.BackgroundTask.Info.list_user_task': _emptyTasks(),
        },
      );
      final api = await _loggedIn(t);
      final tasks = await FotoG6Api(api).listUserTasks();

      final call = _callOf(t, 'SYNO.Foto.BackgroundTask.Info');
      expect(call['method'], 'list_user_task');
      expect(call['version'], '1');
      // ⚠️ **全局** API：不带个人/共享空间前缀（本机无 FotoTeam 对应体）
      expect(call['api'], 'SYNO.Foto.BackgroundTask.Info');
      // **无必填参数**
      expect(call.containsKey('offset'), isFalse);
      expect(tasks, isEmpty);
    });

    test('空响应逐字 `{"list": []}` → 空列表（真机就是这一支，不是错误）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.BackgroundTask.Info.list_user_task': _emptyTasks(),
        },
      );
      final api = await _loggedIn(t);
      expect(await FotoG6Api(api).listUserTasks(), isEmpty);
    });

    test('非空条目：字段逐字解析；枚举串映射到文案 key', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.BackgroundTask.Info.list_user_task': {
            'list': [_taskItem()],
          },
        },
      );
      final api = await _loggedIn(t);
      final tasks = await FotoG6Api(api).listUserTasks();
      expect(tasks, hasLength(1));

      final task = tasks.single;
      expect(task.id, '987654');
      expect(task.operation, 'copy');
      expect(task.status, 'processing');
      expect(task.total, 10);
      expect(task.completion, 4);
      expect(task.error, 1);
      expect(task.skip, 0);
      expect(task.overwrite, 2);
      expect(task.createTime, 1789775507);
      expect(task.operationLabelKey, 'photoG6TaskOperationCopy');
      expect(task.statusLabelKey, 'photoG6TaskStatusProcessing');
      expect(task.hasErrors, isTrue);
      expect(task.isPending, isTrue);
      expect(task.ratio, closeTo(0.4, 0.001));
    });

    test('未知 operation / status → **不给 key**（UI 不透原文）', () {
      final task = FotoBackgroundTaskDto.fromJson({
        ..._taskItem(),
        'operation': 'teleport',
        'status': 'quantum',
      });
      expect(task.operationLabelKey, isNull);
      expect(task.statusLabelKey, isNull);
    });

    test('total 为 0 时进度不除零', () {
      final task = FotoBackgroundTaskDto.fromJson({..._taskItem(), 'total': 0});
      expect(task.ratio, 0);
    });
  });

  group('② 接口层：Migration/get_status', () {
    test('api/method 逐字正确；版本走能力表协商（1..1 → v1）；无必填参数', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Migration.get_status': _doneMigration()},
      );
      final api = await _loggedIn(t);
      final status = await FotoG6Api(api).migrationStatus();

      final call = _callOf(t, 'SYNO.Foto.Migration');
      expect(call['method'], 'get_status');
      expect(call['version'], '1');
      expect(call['api'], 'SYNO.Foto.Migration');

      // 真机回包逐字
      expect(status.current, 2);
      expect(status.total, 0);
      expect(status.titleKey, '');
      // `status` 是**枚举串**，不是布尔
      expect(status.status, 'done');
      expect(status.state, FotoMigrationState.done);
    });

    test('status 枚举：done / running / failed / migration_finished / 未知兜底', () {
      expect(FotoMigrationState.fromWire('done'), FotoMigrationState.done);
      expect(
        FotoMigrationState.fromWire('migration_finished'),
        FotoMigrationState.done,
      );
      expect(
        FotoMigrationState.fromWire('running'),
        FotoMigrationState.running,
      );
      expect(FotoMigrationState.fromWire('failed'), FotoMigrationState.failed);
      // **未知值绝不透原文** → 收敛到 unknown，并有一条人话 key
      expect(FotoMigrationState.fromWire('weird'), FotoMigrationState.unknown);
      expect(FotoMigrationState.fromWire(null), FotoMigrationState.unknown);
      expect(
        FotoMigrationState.unknown.labelKey,
        'photoG6MigrationStatusUnknown',
      );
    });

    test('title_key 只映射有证据的阶段名；未知 → null（不透原文）', () {
      const key = 'photoG6MigrationStagePhotoStation';
      expect(
        FotoMigrationStatusDto.fromJson({
          'title_key': 'migrating_photo_station',
        }).stageLabelKey,
        key,
      );
      expect(
        FotoMigrationStatusDto.fromJson({
          'title_key': 'photos_migrating_photostation',
        }).stageLabelKey,
        key,
      );
      expect(
        FotoMigrationStatusDto.fromJson({
          'title_key': 'migrating_moments_personal',
        }).stageLabelKey,
        'photoG6MigrationStageMomentsPersonal',
      );
      expect(
        FotoMigrationStatusDto.fromJson({
          'title_key': 'secret_stage',
        }).stageLabelKey,
        isNull,
      );
      expect(FotoMigrationStatusDto.fromJson(const {}).stageLabelKey, isNull);
    });
  });

  group('③ provider', () {
    test('photoBackgroundTasksProvider：空响应 → 空列表（不抛）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.BackgroundTask.Info.list_user_task': _emptyTasks(),
        },
      );
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      final tasks = await c.read(photoBackgroundTasksProvider.future);
      expect(tasks, isEmpty);
    });

    test('photoMigrationStatusProvider：真机回包 → done / total 0', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Migration.get_status': _doneMigration()},
      );
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      final status = await c.read(photoMigrationStatusProvider.future);
      expect(status.state, FotoMigrationState.done);
      expect(status.total, 0);
      expect(status.current, 2);
    });
  });

  group('④ 页面层：空响应 → 人话空态（不是白屏）', () {
    testWidgets('后台任务空列表 → 空态标题/说明；内部 id 不上屏', (tester) async {
      final r = await _pump(
        tester,
        const PhotoBackgroundTasksPage(),
        responses: {
          'SYNO.Foto.BackgroundTask.Info.list_user_task': _emptyTasks(),
        },
      );
      expect(find.byKey(const Key('photo-g6-tasks-page')), findsOneWidget);
      expect(find.text('当前没有正在进行的后台任务'), findsOneWidget);
      expect(find.textContaining('会在这里显示进度'), findsOneWidget);
      expect(find.byKey(const Key('photo-g6-tasks-list')), findsNothing);
      // 页面确实发了请求（不是"没请求所以空白"）
      expect(
        r.t.calls.any((c) => c['api'] == 'SYNO.Foto.BackgroundTask.Info'),
        isTrue,
      );
    });

    testWidgets('后台任务非空 → 列表渲染；任务 id 不上屏', (tester) async {
      await _pump(
        tester,
        const PhotoBackgroundTasksPage(),
        responses: {
          'SYNO.Foto.BackgroundTask.Info.list_user_task': {
            'list': [_taskItem()],
          },
        },
      );
      expect(find.byKey(const Key('photo-g6-tasks-list')), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.textContaining('进行中'), findsOneWidget);
      // ⚠️ 内部任务 id（987654）绝不上屏
      expect(find.textContaining('987654'), findsNothing);
    });

    testWidgets('迁移 status=done,total=0（真机）→ 人话空态', (tester) async {
      await _pump(
        tester,
        const PhotoMigrationPage(),
        responses: {'SYNO.Foto.Migration.get_status': _doneMigration()},
      );
      expect(find.byKey(const Key('photo-g6-migration-page')), findsOneWidget);
      expect(find.text('当前没有正在进行的迁移'), findsOneWidget);
      expect(find.textContaining('这里会显示结果'), findsOneWidget);
    });

    testWidgets('迁移 running + 有阶段 → 画正文（不是空态）', (tester) async {
      await _pump(
        tester,
        const PhotoMigrationPage(),
        responses: {
          'SYNO.Foto.Migration.get_status': {
            'current': 3,
            'status': 'running',
            'title_key': 'migrating_photo_station',
            'total': 8,
          },
        },
      );
      expect(find.byKey(const Key('photo-g6-migration-body')), findsOneWidget);
      expect(find.text('正在迁移'), findsOneWidget);
      expect(find.text('正在迁移 Photo Station 的照片'), findsOneWidget);
      expect(find.textContaining('第 3 / 8 步'), findsOneWidget);
    });

    testWidgets('迁移**未知状态** → 通用人话；原文（status/title_key）绝不上屏', (tester) async {
      await _pump(
        tester,
        const PhotoMigrationPage(),
        responses: {
          'SYNO.Foto.Migration.get_status': {
            'current': 0,
            'status': 'quantum_state',
            'title_key': 'secret_stage',
            'total': 0,
          },
        },
      );
      expect(find.text('暂时读不到迁移状态，请稍后重试'), findsOneWidget);
      expect(find.textContaining('quantum_state'), findsNothing);
      expect(find.textContaining('secret_stage'), findsNothing);
      // **不得**把"未知"装成"空态"
      expect(find.text('当前没有正在进行的迁移'), findsNothing);
    });
  });

  group('⑤ hub 入口门控（能力位缺失 → 隐藏，且不发探测）', () {
    testWidgets('缺 BackgroundTask.Info → 入口不出现，也不发请求', (tester) async {
      final r = await _pump(
        tester,
        const PhotoC2Page(),
        apis: {..._allApis}..remove(kFotoBackgroundTaskInfoApi),
      );
      expect(
        find.byKey(const Key('photo-c2-entry-background-task')),
        findsNothing,
      );
      expect(
        r.t.calls.any((c) => c['api'] == 'SYNO.Foto.BackgroundTask.Info'),
        isFalse,
      );
    });

    testWidgets('缺 Migration → 入口不出现，也不发请求', (tester) async {
      final r = await _pump(
        tester,
        const PhotoC2Page(),
        apis: {..._allApis}..remove(kFotoMigrationApi),
      );
      expect(find.byKey(const Key('photo-c2-entry-migration')), findsNothing);
      expect(r.t.calls.any((c) => c['api'] == 'SYNO.Foto.Migration'), isFalse);
    });

    testWidgets('能力位在 → 两个入口都出现，点开各自页面', (tester) async {
      // 只留两个 G6 能力位（+ 相册必需 API）：hub 的 ListView 是**懒构建**的，
      // 入口一多，靠后的那条根本不会被 build，`findsOneWidget` 会假失败。
      const g6Only = {
        'SYNO.Foto.Browse.Item',
        'SYNO.Foto.Browse.Album',
        kFotoBackgroundTaskInfoApi,
        kFotoMigrationApi,
      };
      await _pump(
        tester,
        const PhotoC2Page(),
        apis: g6Only,
        responses: {
          'SYNO.Foto.BackgroundTask.Info.list_user_task': _emptyTasks(),
          'SYNO.Foto.Migration.get_status': _doneMigration(),
        },
      );
      expect(
        find.byKey(const Key('photo-c2-entry-background-task')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('photo-c2-entry-migration')), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-c2-entry-background-task')));
      await _settle(tester);
      expect(find.byType(PhotoBackgroundTasksPage), findsOneWidget);
      expect(find.text('当前没有正在进行的后台任务'), findsOneWidget);
    });

    testWidgets('能力位在 → 迁移入口点开是「迁移状态」页（真机回包 → 空态）', (tester) async {
      const g6Only = {
        'SYNO.Foto.Browse.Item',
        'SYNO.Foto.Browse.Album',
        kFotoBackgroundTaskInfoApi,
        kFotoMigrationApi,
      };
      await _pump(
        tester,
        const PhotoC2Page(),
        apis: g6Only,
        responses: {
          'SYNO.Foto.BackgroundTask.Info.list_user_task': _emptyTasks(),
          'SYNO.Foto.Migration.get_status': _doneMigration(),
        },
      );
      await tester.tap(find.byKey(const Key('photo-c2-entry-migration')));
      await _settle(tester);
      expect(find.byType(PhotoMigrationPage), findsOneWidget);
      expect(find.text('当前没有正在进行的迁移'), findsOneWidget);
    });
  });
}
