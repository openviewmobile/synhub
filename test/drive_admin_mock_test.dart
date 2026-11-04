// ③Drive **管理员接口**的 Mock Server 核实（新规 B1：必须通过）。
//
// ## 这一份用例要钉什么
//
// ① **正证**：管理员会话下，5 个只读管理接口在本仓 **Mock Server**
//    （`tool/mock_dsm/mock_dsm_core.dart` + 权威 `catalog.json`）上**全部通过**，
//    且客户端发的 `api/method/version/params` 与官方 SPK 的
//    `SYNO.SynologyDrive.lib` 与官方管理端 JS **逐字一致**：
//      * `Settings/list`  v1  params 空
//      * `Config/get`     v1  params 空
//      * `DBUsage/get`    v1  params 空
//      * `DBUsage/status` v1  params 空
//      * `Privilege/list` v1  `additional: ["status","enabled"]`
// ② **反证（新规 R2 的服务端侧）**：同一批接口在**非管理员**会话下必须是
//    `105`（Mock Server 按 `catalog.json` 的 `adminOnly` 判）—— 这条防止
//    以后有人把管理接口做成"人人可调"。
// ③ **版本守卫**：这些 API 的 `maxVersion` 在权威目录里就是 1，客户端不许
//    拿一个目录里不存在的版本去调（`v2` 必须 `103`）。
// ④ **页面门控**：非管理员看不到入口、直接打开也拿不到数据（fail-closed）。
//
// 全程内存 Mock，**不碰真机**（§5.1；本文件没有任何写方法调用）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/drive_admin_api.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/admin/admin_gate.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_admin_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/chat_harness.dart' show FakeTransport;
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/mock_dsm_transport.dart';

const _settingsFields = {
  'enable_public_sharing': true,
  'enable_normal_user_sharing': false,
  'use_del_by_cnt': true,
  'del_cnt': 1000000,
  'support_moving_repository': true,
};
const _configFields = {'db_volume': '/volume1', 'use_del_by_span': false};
const _dbFields = {'usage': 20480, 'last_update_usage_time': '2026-09-24 10:00'};
const _privileges = [
  {'name': 'demo_user', 'enable': true, 'status': 'enabled'},
  {'name': 'guest', 'enable': false, 'status': 'disabled'},
];

/// 装好夹具的 Mock 后端（管理员 / 普通用户两种会话）。
Future<({MockDsmBackend backend, DsmWebApi web})> _mock({required bool admin}) async {
  final backend = MockDsmBackend(catalog: DsmCatalog.load());
  backend.login(username: admin ? 'admin' : 'demo_user', admin: admin);
  backend.fixture(
    'SYNO.SynologyDrive.Settings',
    'list',
    (_) => {'success': true, 'data': _settingsFields},
  );
  backend.fixture(
    'SYNO.SynologyDrive.Config',
    'get',
    (_) => {'success': true, 'data': _configFields},
  );
  backend.fixture(
    'SYNO.SynologyDrive.DBUsage',
    'get',
    (_) => {'success': true, 'data': _dbFields},
  );
  backend.fixture(
    'SYNO.SynologyDrive.DBUsage',
    'status',
    (_) => {
      'success': true,
      'data': {'usage': 20480, 'finish': true, 'time': '2026-09-24 10:01'},
    },
  );
  backend.fixture(
    'SYNO.SynologyDrive.Privilege',
    'list',
    (_) => {
      'success': true,
      'data': {'items': _privileges, 'total': _privileges.length},
    },
  );
  final web = DsmWebApi(MockDsmTransport(backend));
  await web.discover();
  await web.login(account: admin ? 'admin' : 'demo_user', password: 'x');
  return (backend: backend, web: web);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('B1-DA-1. Mock Server：管理员会话下 5 个只读管理接口全过', () {
    test('★★ 逐个接口：成功 + 方法/版本/参数与官方逐字一致', () async {
      final m = await _mock(admin: true);
      final api = DriveAdminApi(m.web);

      final settings = await api.settings();
      expect(settings['enable_public_sharing'], isTrue);
      expect(settings['del_cnt'], 1000000);

      final config = await api.config();
      expect(config['db_volume'], '/volume1');

      final usage = await api.dbUsage();
      expect(usage['usage'], 20480);

      final status = await api.dbUsageStatus();
      expect(status['finish'], isTrue);

      final priv = await api.privileges();
      expect(priv.map((e) => e['name']), ['demo_user', 'guest']);

      // 客户端实际发了什么（Mock Server 的请求日志）
      final calls = m.backend.requests
          .where((r) => '${r.params['api']}'.startsWith('SYNO.SynologyDrive'))
          .map((r) => (
                api: r.params['api'],
                method: r.params['method'],
                version: '${r.params['version']}',
                params: r.params,
              ))
          .toList();
      expect(calls.length, 5, reason: '5 个接口各一次，不多不少');

      Map<String, dynamic> callOf(String apiName, String method) =>
          calls.firstWhere(
            (c) => c.api == apiName && c.method == method,
          ).params;

      expect(callOf('SYNO.SynologyDrive.Settings', 'list')['version'], '1');
      expect(callOf('SYNO.SynologyDrive.Config', 'get')['version'], '1');
      expect(callOf('SYNO.SynologyDrive.DBUsage', 'get')['version'], '1');
      expect(callOf('SYNO.SynologyDrive.DBUsage', 'status')['version'], '1');
      final privParams = callOf('SYNO.SynologyDrive.Privilege', 'list');
      expect(privParams['version'], '1');
      // `additional` 数组逐字：官方 `setApiParams()` 就是这两个
      expect(privParams['additional'], ['status', 'enabled']);

      // 只读：没有任何变更动词
      const mutating = {
        'set',
        'update',
        'start',
        'stop',
        'delete',
        'create',
        'import',
        'export',
      };
      for (final c in calls) {
        expect(mutating.contains(c.method), isFalse, reason: '${c.method} 是写方法');
      }
    });
  });

  group('B1-DA-2. 反证：非管理员会话一律 105', () {
    test('★★ 5 个管理接口在普通用户会话下全部被拒（105）', () async {
      final m = await _mock(admin: false);
      final api = DriveAdminApi(m.web);

      Future<void> expectDenied(Future<void> Function() f) async {
        try {
          await f();
          fail('非管理员竟然调通了管理接口');
        } on DsmApiException catch (e) {
          expect(e.code, 105, reason: '官方 admin-only 的拒绝码是 105');
        }
      }

      await expectDenied(api.settings);
      await expectDenied(api.config);
      await expectDenied(api.dbUsage);
      await expectDenied(api.dbUsageStatus);
      await expectDenied(api.privileges);
    });
  });

  group('B1-DA-3. 版本守卫：目录里的版本/方法/管理员位', () {
    test('★ 四个 API 都在权威目录里且是 admin-only；方法表逐版本', () {
      final catalog = DsmCatalog.load();
      for (final name in const [
        'SYNO.SynologyDrive.Settings',
        'SYNO.SynologyDrive.Config',
        'SYNO.SynologyDrive.DBUsage',
        'SYNO.SynologyDrive.Privilege',
      ]) {
        final spec = catalog[name];
        expect(spec, isNotNull, reason: '$name 必须在权威目录里');
        expect(spec!.adminOnly, isTrue, reason: '$name 是 admin-only');
      }
      // `Settings` 在 SPK 里是 v1–v3（v2 起才有 `list_targets`）；
      // 另三个就是 v1。客户端必须按**方法存在的最早版本**调，而不是 maxVersion。
      expect(catalog['SYNO.SynologyDrive.Settings']!.maxVersion, 3);
      expect(catalog['SYNO.SynologyDrive.Config']!.maxVersion, 1);
      expect(catalog['SYNO.SynologyDrive.DBUsage']!.maxVersion, 1);
      expect(catalog['SYNO.SynologyDrive.Privilege']!.maxVersion, 1);
      expect(catalog['SYNO.SynologyDrive.Settings']!.hasMethod(1, 'list'), isTrue);
      expect(catalog['SYNO.SynologyDrive.Settings']!.hasMethod(1, 'list_targets'), isFalse,
          reason: 'list_targets 从 v2 才有 —— 这条就是"版本陷阱"的守卫');
    });

    test('★ Mock Server：目录里没有的版本一律 103', () async {
      final m = await _mock(admin: true);
      final res = m.backend.handle('entry.cgi', {
        'api': 'SYNO.SynologyDrive.Privilege',
        'method': 'list',
        'version': 2,
        '_sid': m.backend.sessions.first,
      });
      expect(res.json['success'], isFalse);
      expect((res.json['error']! as Map)['code'], 103);
      // 方法在 v1 之外/不存在的方法也必须是 103（防"凭印象实现"）
      final res2 = m.backend.handle('entry.cgi', {
        'api': 'SYNO.SynologyDrive.Settings',
        'method': 'set_enable',
        'version': 1,
        '_sid': m.backend.sessions.first,
      });
      expect(res2.json['success'], isFalse);
      expect((res2.json['error']! as Map)['code'], 103);
    });
  });

  group('B1-DA-4. 页面门控（fail-closed）', () {
    testWidgets('★★ 管理员：页面渲染服务端原样字段', (tester) async {
      await _pumpPage(tester, admin: true);
      expect(find.byKey(const Key('drive-admin-page')), findsOneWidget);
      expect(find.byKey(const Key('drive-admin-denied')), findsNothing);
      expect(
        find.byKey(const Key('drive-admin-field-enable_public_sharing')),
        findsOneWidget,
      );
      final priv = find.byKey(const Key('drive-admin-privilege-demo_user'));
      await tester.scrollUntilVisible(priv, 200);
      await tester.pumpAndSettle();
      expect(priv, findsOneWidget);
    });

    testWidgets('★★ 非管理员：直接打开也只有「需要管理员权限」', (tester) async {
      await _pumpPage(tester, admin: false);
      expect(find.byKey(const Key('drive-admin-denied')), findsOneWidget);
      expect(find.byKey(const Key('drive-admin-page')), findsNothing);
    });
  });
}

// ---------------------------------------------------------------- 页面 harness

const _adminTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Settings': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.Config': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.DBUsage': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.Privilege': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

const _adminResponses = {
  'SYNO.SynologyDrive.Settings.list': _settingsFields,
  'SYNO.SynologyDrive.Config.get': _configFields,
  'SYNO.SynologyDrive.DBUsage.get': _dbFields,
  'SYNO.SynologyDrive.Privilege.list': {
    'items': _privileges,
    'total': 2,
  },
};

ServiceAvailabilitySnapshot _snap() => ServiceAvailabilitySnapshot(
  states: {
    for (final s in StationService.values)
      s: s == StationService.drive
          ? classifyApiTable(
              kServiceRegistry[StationService.drive]!,
              _adminTable.keys.toSet(),
            )
          : AvailabilityState.available,
  },
  apis: _adminTable.keys.toSet(),
  checkedAt: DateTime(2026, 9, 24),
);

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);
  final ServiceAvailabilitySnapshot snapshot;
  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

Future<void> _pumpPage(WidgetTester tester, {required bool admin}) async {
  final t = FakeTransport(_adminResponses, {
    ...FakeTransport.table,
    ..._adminTable,
  });
  t.onCall = (p) {
    final key = '${p['api']}.${p['method']}';
    return {...?_adminResponses[key], 'success': true};
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(DriveApi(api)),
      isAdminProvider.overrideWith((ref) => admin),
      serviceAvailabilityProvider.overrideWith(() => _FixedAvailability(_snap())),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: DriveAdminPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}
