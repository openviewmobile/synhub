// Drive **G6 批次**离线用例：`SYNO.SynologyDrive.Connection:list`（已连接的设备）
// 与 `FileRequest` 的 `1076`（服务端关掉 file request）。
//
// ## 契约来源（**离线**，本次不发起任何 NAS 请求）
//
// * 方法表：`/tmp/spk/export_SynologyDrive/webapi/drive/SYNO.SynologyDrive.lib`
//   → `minVersion:1, maxVersion:2`，`methods:{1:[list,delete],2:[list,delete,summary]}`；
// * 条目字段白名单：`lib/SYNO.SynologyDrive.so` 字符串常量
//   `["client_id","client_name","login_time","client_status","client_type",
//    "client_ip","client_location","client_version","last_auth_time"]`；
// * 真机只读实测（`docs/g6-api-probe-facts.md:37`）：
//   `Connection:list` **v1 与 v2 都 success**、无必填参数、
//   回 `{"items": [], "total": 0}`；
// * `FileRequest:list` v1 → **`1076`**
//   `"protocol error, reason = 'file request is disabled'"`
//   （`docs/g6-api-probe-facts.md:44-50`）。
//
// ## 本文件要钉死的四件事
//
// ① 版本协商：候选 `[2,1]` 与服务端区间取交集 —— **不硬编码 maxVersion**
//    （老包只到 v1 时必须发 v1）；
// ② **空响应 → 人话空态**（真机上就是这一支）；
// ③ 内部 id（`client_id`）**绝不上屏**；
// ④ `1076` → 人话，**绝不显示原始协议报文**。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_connection_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_connections_page.dart';
import 'package:synhub/src/features/drive/drive_extras_page.dart';
import 'package:synhub/src/features/drive/drive_file_request_page.dart';
import 'package:synhub/src/features/drive/drive_g6_providers.dart';
import 'package:synhub/src/features/drive/drive_g6_text.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _g6Table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Connection': {
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

/// 真机回包逐字：`{"items": [], "total": 0}`
Map<String, dynamic> _emptyConnections() => {'items': [], 'total': 0};

/// 条目字段**逐字**用 `.so` 白名单里的九个键名（非空分支用）。
Map<String, dynamic> _connectionItem() => {
  'client_id': '4242',
  'client_name': 'demo_user-mac',
  'login_time': 1789775507,
  'client_status': 'connected',
  'client_type': 'desktop',
  'client_ip': '192.168.0.10',
  'client_location': 'LAN',
  'client_version': '3.5.0',
  'last_auth_time': 1789775600,
};

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, Map<String, dynamic>>? table,
  Map<String, int> failures = const {},
}) {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._g6Table,
    ...?table,
  });
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  t.failures.addAll(failures);
  return t;
}

Future<DriveApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return DriveApi(api);
}

Map<String, dynamic> _callOf(FakeTransport t, String api) =>
    t.calls.lastWhere((c) => c['api'] == api);

// ---------------------------------------------------------------- 能力快照

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

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

const _allDriveApis = {
  'SYNO.SynologyDrive.Files',
  'SYNO.SynologyDrive.Revisions',
  'SYNO.SynologyDrive.Trash',
  'SYNO.SynologyDrive.AdvanceSharing',
  'SYNO.SynologyDrive.FileRequest',
  'SYNO.SynologyDrive.NodeLocking',
  'SYNO.SynologyDrive.Notifications',
  'SYNO.SynologyDrive.TeamFolders',
  kDriveConnectionApi,
};

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> apis = _allDriveApis,
  Map<String, int> failures = const {},
}) async {
  final t = _transport(responses: responses, failures: failures);
  final api = await _api(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(api),
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('① 接口层：Connection/list 的版本协商（**不硬编码 maxVersion**）', () {
    test('服务端 v1..2 → 发 v2；api/method 逐字正确', () async {
      final t = _transport(
        responses: {'SYNO.SynologyDrive.Connection.list': _emptyConnections()},
      );
      final api = await _api(t);
      final page = await api.listConnections();

      final call = _callOf(t, 'SYNO.SynologyDrive.Connection');
      expect(call['method'], 'list');
      // 候选 [2,1] ∩ [1,2] → 2
      expect(call['version'], '2');
      expect(page.items, isEmpty);
      expect(page.total, 0);
      expect(page.isEmpty, isTrue);
    });

    test('老包只声明到 v1 → **回退发 v1**（协商，不是写死）', () async {
      final t = _transport(
        responses: {'SYNO.SynologyDrive.Connection.list': _emptyConnections()},
        table: {
          'SYNO.SynologyDrive.Connection': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      final api = await _api(t);
      await api.listConnections();

      final call = _callOf(t, 'SYNO.SynologyDrive.Connection');
      expect(call['version'], '1');
    });

    test('空响应逐字 → 空列表 + total 0（真机就是这一支，**不是错误**）', () async {
      final t = _transport(
        responses: {'SYNO.SynologyDrive.Connection.list': _emptyConnections()},
      );
      final api = await _api(t);
      final page = await api.listConnections();
      expect(page.items, hasLength(0));
      expect(page.total, 0);
    });

    test('非空条目：九个白名单字段都解析；内部 id 不参与显示名兜底', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Connection.list': {
            'items': [_connectionItem()],
            'total': 7,
          },
        },
      );
      final api = await _api(t);
      final page = await api.listConnections();
      expect(page.items, hasLength(1));
      // 服务端给的 total 原样保留（分页语义）
      expect(page.total, 7);

      final c = page.items.single;
      expect(c.clientId, '4242');
      expect(c.clientName, 'demo_user-mac');
      expect(c.clientStatus, 'connected');
      expect(c.clientType, 'desktop');
      expect(c.clientIp, '192.168.0.10');
      expect(c.clientLocation, 'LAN');
      expect(c.clientVersion, '3.5.0');
      expect(c.loginTime, 1789775507);
      expect(c.lastAuthTime, 1789775600);
      expect(c.statusLabelKey(), 'driveG6ConnectionStatusConnected');
      expect(c.displayName('未知设备'), 'demo_user-mac');
    });

    test('未知 client_status → **不给 key**（UI 不透原文）', () {
      final c = DriveConnectionListDto.fromJson({
        'items': [
          {..._connectionItem(), 'client_status': 'weird_state'},
        ],
        'total': 1,
      }).items.single;
      expect(c.statusLabelKey(), isNull);
    });

    test('client_name 为空 → 显示名回落**人话**，绝不回落 client_id', () {
      final c = DriveConnectionListDto.fromJson({
        'items': [
          {..._connectionItem(), 'client_name': ''},
        ],
        'total': 1,
      }).items.single;
      expect(c.displayName('未知设备'), '未知设备');
      expect(c.displayName('未知设备'), isNot('4242'));
    });
  });

  group('② provider：driveConnectionsProvider', () {
    test('空响应 → 空列表（不抛）', () async {
      final t = _transport(
        responses: {'SYNO.SynologyDrive.Connection.list': _emptyConnections()},
      );
      final api = await _api(t);
      final c = ProviderContainer(
        overrides: [driveApiProvider.overrideWithValue(api)],
      );
      addTearDown(c.dispose);
      final page = await c.read(driveConnectionsProvider.future);
      expect(page.isEmpty, isTrue);
    });
  });

  group('③ 页面层：空响应 → 人话空态（不是白屏）', () {
    testWidgets('空 items → 画空态标题/说明，且不画列表', (tester) async {
      final r = await _pump(
        tester,
        const DriveConnectionsPage(),
        responses: {'SYNO.SynologyDrive.Connection.list': _emptyConnections()},
      );
      expect(find.byKey(const Key('drive-connections-page')), findsOneWidget);
      expect(find.byKey(const Key('drive-connections-empty')), findsOneWidget);
      // 人话空态：标题 + 说明都能找到（**真机上的唯一表现**）
      expect(find.text('当前没有已连接的设备'), findsOneWidget);
      expect(find.textContaining('这里会列出该设备'), findsOneWidget);
      expect(find.byKey(const Key('drive-connections-list')), findsNothing);
      // 页面确实发了请求（不是"没请求所以空白"）
      expect(
        r.t.calls.any((c) => c['api'] == 'SYNO.SynologyDrive.Connection'),
        isTrue,
      );
    });

    testWidgets('非空 items → 列表渲染；内部 id 不上屏', (tester) async {
      await _pump(
        tester,
        const DriveConnectionsPage(),
        responses: {
          'SYNO.SynologyDrive.Connection.list': {
            'items': [_connectionItem()],
            'total': 1,
          },
        },
      );
      expect(find.byKey(const Key('drive-connections-list')), findsOneWidget);
      expect(find.text('demo_user-mac'), findsOneWidget);
      // ⚠️ client_id（4242）只允许出现在 Key 里，**绝不上屏**
      expect(find.textContaining('4242'), findsNothing);
      expect(find.byKey(const Key('drive-connections-empty')), findsNothing);
    });

    testWidgets('传输错误 → 错误态（人话），不装成空态', (tester) async {
      final t = _transport();
      t.offlineKeys.add('SYNO.SynologyDrive.Connection.list');
      final api = await _api(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(c.dispose);
      addTearDown(db.close);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DriveConnectionsPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('drive-connections-error')), findsOneWidget);
      expect(find.byKey(const Key('drive-connections-empty')), findsNothing);
    });
  });

  group('④ 入口门控：能力位缺失 → 隐藏（Drive 模块不隐藏）', () {
    testWidgets('缺 SYNO.SynologyDrive.Connection → 入口不出现，且不发请求', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const DriveExtrasPage(),
        apis: {..._allDriveApis}..remove(kDriveConnectionApi),
      );
      expect(find.byKey(const Key('drive-extras-connections')), findsNothing);
      expect(
        r.t.calls.any((c) => c['api'] == 'SYNO.SynologyDrive.Connection'),
        isFalse,
      );
    });

    testWidgets('能力位在 → 入口出现，点开是「已连接的设备」页', (tester) async {
      await _pump(
        tester,
        const DriveExtrasPage(),
        responses: {'SYNO.SynologyDrive.Connection.list': _emptyConnections()},
      );
      expect(find.byKey(const Key('drive-extras-connections')), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-extras-connections')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(DriveConnectionsPage), findsOneWidget);
      expect(find.text('当前没有已连接的设备'), findsOneWidget);
    });
  });

  group('⑤ FileRequest 的 1076：人话，绝不透协议原文', () {
    const rawMessage = "protocol error, reason = 'file request is disabled'";

    test('接口层：1076 抛 DsmApiException(1076)，不是"空列表"', () async {
      final t = _transport(
        failures: {'SYNO.SynologyDrive.FileRequest.list': 1076},
      );
      final api = await _api(t);
      await expectLater(
        api.listFileRequests(),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 1076)),
      );
    });

    test('文案层：1076 → 人话，原文一个字都不出现', () {
      final err = DsmApiException(
        1076,
        method: 'SYNO.SynologyDrive.FileRequest.list',
        raw: {
          'error': {
            'code': 1076,
            'errors': {'line': 63, 'message': rawMessage},
          },
        },
      );
      final text = describeDriveG6Error(err);
      expect(text, '这台 NAS 没有开启「文件请求」功能，请在 DSM 的 Drive 管理控制台中启用后重试。');
      expect(text.contains('protocol error'), isFalse);
      expect(text.contains('file request is disabled'), isFalse);
      expect(text.contains('1076'), isFalse);
      expect(text.contains('DsmApiException'), isFalse);
    });

    test('文案层：非 DsmApiException 走 userFacingError（不吐 Dart 类型名）', () {
      final text = describeDriveG6Error(
        StateError('boom at package:foo/bar.dart:1'),
      );
      expect(text, isNot(contains('StateError')));
      expect(text, isNot(contains('package:')));
      expect(text, isNot(contains('boom')));
    });

    testWidgets('页面层：1076 → 错误态显示人话，不显示原始协议报文', (tester) async {
      await _pump(
        tester,
        const DriveFileRequestPage(),
        failures: {'SYNO.SynologyDrive.FileRequest.list': 1076},
      );
      expect(find.byKey(const Key('drive-file-request-page')), findsOneWidget);
      expect(find.byKey(const Key('drive-file-request-error')), findsOneWidget);
      expect(
        find.text('这台 NAS 没有开启「文件请求」功能，请在 DSM 的 Drive 管理控制台中启用后重试。'),
        findsOneWidget,
      );
      expect(find.textContaining('protocol error'), findsNothing);
      expect(find.textContaining('file request is disabled'), findsNothing);
      // 也**不得**把 1076 这个码当成"空列表"渲染
      expect(find.byKey(const Key('drive-file-request-page')), findsOneWidget);
    });
  });
}
