// D65（同步任务 / 同步设备管理）协议层 + 页面层复核测试。
//
// ## 本项的真实现状（复核结论）
//
// 官方 APK **没有**独立的 `SYNO.SynologyDrive.Sync` API 族；SPK
// `openapi_v2.json` / `openapi_v1.json` 里也**没有** sync / collection / recycle
// 的 REST 路径（只有 `/admin/client` → `SYNO.SynologyDrive.Connection`）。
// 「同步任务 / 同步设备」在官方由两个**只读**接口承载，**本仓库都已实现**：
//   * `SYNO.SynologyDrive.Connection:list`（v2，回退 v1）→ 「已连接的设备」
//     （`drive_connections_page.dart`，G6 批次）；
//   * `SYNO.SynologyDrive.Files:list_backup_tasks`（**v3**）→ 「计算机」
//     （`drive_computers_page.dart`，G4/D21 批次）。
//
// 因此 D65 是**已实现项**，本批的工作是**复核 + 补只读回归用例**，
// 而不是重复造一套。
//
// ## 管理类动作（暂停 / 恢复 / 删除）为什么不写代码
//
// `.lib` 逐字 `methods: {1:[list, delete], 2:[list, delete, summary]}`
// ⇒ 官方"删除已连接设备"= `Connection:delete`，**命中 §5.1 变更动词黑名单**。
// 上游决策（`docs/drive-authoritative-api-crosscheck.md:91`）明确：
// **只做 `list`，不做 `delete`**。本文件用断言把"只发读动词"钉死。
//
// 真机只读实测（普通账号，DSM 7.2）：`Connection:list` v1/v2 都 success
// （`{"items":[],"total":0}`）；`Files:list_backup_tasks` v3 success、v1/v2 回 103。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_connection_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_connections_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Connection': {
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

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

FakeTransport _transport(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, Map<String, dynamic>>? table,
}) {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._table,
    ...?table,
  });
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  return t;
}

/// 只发过读动词 —— 把"本批不碰管理动作（`Connection:delete` 等）"钉死。
///
/// 判据用**变更动词黑名单**（§5.1），而不是枚举白名单：任何
/// `delete/set/create/update/add/remove/cancel/stop/start/move/copy/restore/...`
/// 出现即失败；`discover` 的 `getinfo` / `query` 等读调用放行。
void expectReadOnlyCalls(FakeTransport t) {
  const blacklist = [
    'delete',
    'set',
    'create',
    'update',
    'add',
    'remove',
    'cancel',
    'stop',
    'start',
    'move',
    'copy',
    'restore',
    'clear',
    'purge',
    'empty',
  ];
  for (final c in t.calls) {
    final m = '${c['method'] ?? ''}'.toLowerCase();
    for (final verb in blacklist) {
      expect(
        m.contains(verb),
        isFalse,
        reason: 'D65 只允许读动词，实际发了含变更动词「$verb」的 $m',
      );
    }
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('D65 同步设备：Connection/list（只读）', () {
    test('listConnections → Connection/list v2，解析九个字段', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Connection.list': {
          'items': [
            {
              'client_id': 'cid-1',
              'client_name': 'LGE-AN10',
              'login_time': 1789775507,
              'client_status': 'connected',
              'client_type': 'mobile',
              'client_ip': '192.168.0.9',
              'client_location': '局域网',
              'client_version': '3.9.0-1113',
              'last_auth_time': 1789775600,
            },
          ],
          'total': 1,
        },
      });
      final api = await _loggedIn(t);
      final page = await DriveApi(api).listConnections();
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.Connection');
      expect(call['method'], 'list');
      // 候选 [2,1] ⇒ 本机 max 2 ⇒ v2
      expect(call['version'], '2');
      final d = page.items.single;
      expect(d.clientName, 'LGE-AN10');
      expect(d.clientStatus, 'connected');
      expect(d.statusLabelKey(), 'driveG6ConnectionStatusConnected');
      expect(d.clientIp, '192.168.0.9');
      expect(d.clientVersion, '3.9.0-1113');
      expect(page.total, 1);
      expectReadOnlyCalls(t);
    });

    test('老服务器只到 v1 ⇒ 协商到 v1', () async {
      final t = _transport(
        {
          'SYNO.SynologyDrive.Connection.list': {'items': [], 'total': 0},
        },
        table: {
          'SYNO.SynologyDrive.Connection': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      final api = await _loggedIn(t);
      await DriveApi(api).listConnections();
      expect(t.calls.last['version'], '1');
    });

    test('认不出的 client_status 不透原文（statusLabelKey → null）', () {
      final d = DriveConnectionDto.fromJson({
        'client_id': 'x',
        'client_status': 'weird_internal_state',
      });
      expect(d.statusLabelKey(), isNull);
      // 显示名永不回落到内部 id
      expect(d.displayName('未知设备'), '未知设备');
    });
  });

  group('D65 同步任务：Files/list_backup_tasks（只读）', () {
    test(
      'listBackupTasks → Files/list_backup_tasks v3 + offset/limit',
      () async {
        final t = _transport({
          'SYNO.SynologyDrive.Files.list_backup_tasks': {
            'items': [
              {
                'file_id': '11',
                'name': 'DESKTOP-01',
                'type': 'dir',
                'modified_time': 1789775507,
              },
            ],
            'total': 1,
          },
        });
        final api = await _loggedIn(t);
        final tasks = await DriveApi(api).listBackupTasks();
        final call = t.calls.last;
        expect(call['api'], 'SYNO.SynologyDrive.Files');
        expect(call['method'], 'list_backup_tasks');
        // 官方 setAsComputers = Math.min(3, maxVersion)，本机 Files max 11 ⇒ 3
        expect(call['version'], '3');
        expect(call['offset'], 0);
        expect(call['limit'], 100);
        expect(tasks.items.single.name, 'DESKTOP-01');
        expectReadOnlyCalls(t);
      },
    );
  });

  group('D65 页面层：已连接设备页（状态是具体数据，不只断言控件）', () {
    testWidgets('有设备 → 设备名 / 状态 / 类型 / 版本 / IP 都上屏', (tester) async {
      final t = _transport({
        'SYNO.SynologyDrive.Connection.list': {
          'items': [
            {
              'client_id': 'cid-1',
              'client_name': 'LGE-AN10',
              'login_time': 1789775507,
              'client_status': 'connected',
              'client_type': 'mobile',
              'client_ip': '192.168.0.9',
              'client_version': '3.9.0-1113',
            },
          ],
          'total': 1,
        },
      });
      await _pump(tester, t, const DriveConnectionsPage());
      expect(find.byKey(const Key('drive-connections-page')), findsOneWidget);
      expect(find.text('LGE-AN10'), findsOneWidget);
      expect(find.textContaining('已连接'), findsWidgets);
      expect(find.textContaining('mobile'), findsOneWidget);
      expect(find.textContaining('3.9.0-1113'), findsOneWidget);
      expect(find.textContaining('192.168.0.9'), findsOneWidget);
      // 内部 id 只在 Key 里，绝不上屏
      expect(find.text('cid-1'), findsNothing);
      expect(find.byKey(const Key('drive-connections-list')), findsOneWidget);
      expectReadOnlyCalls(t);
    });

    testWidgets('无设备（真机实况）→ 人话空态', (tester) async {
      final t = _transport({
        'SYNO.SynologyDrive.Connection.list': {'items': [], 'total': 0},
      });
      await _pump(tester, t, const DriveConnectionsPage());
      expect(find.byKey(const Key('drive-connections-empty')), findsOneWidget);
      expect(find.textContaining('没有已连接的设备'), findsOneWidget);
    });
  });
}

/// 只借 DTO 的解析 + 文案判定，避免测试里再 import 一遍 DTO 类型名冲突
typedef DriveConnectionDtoProbe = DriveConnectionDto;

Future<void> _pump(WidgetTester tester, FakeTransport t, Widget page) async {
  final api = await _loggedIn(t);
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
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}
