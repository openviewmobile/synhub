// C1（Drive 补齐）页面与能力位测试。
//
// 覆盖验收里的四类：① 成功路径（FakeTransport 假响应）② 失败路径
// （105 / 119 / 业务错误码）③ 能力位缺失 → 入口隐藏（Drive **不**隐藏）
// ④ 危险操作二次确认（取消 = 不执行）。
import 'dart:async';

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
import 'package:synhub/src/features/admin/admin_gate.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_advance_sharing_page.dart';
import 'package:synhub/src/features/drive/drive_extras_page.dart';
import 'package:synhub/src/features/drive/drive_file_request_page.dart';
import 'package:synhub/src/features/drive/drive_notifications_page.dart';
import 'package:synhub/src/features/drive/drive_team_members_page.dart';
import 'package:synhub/src/features/drive/drive_trash_page.dart';
import 'package:synhub/src/features/files/drive_browse_view.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _c1Table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Revisions': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Trash': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.SynologyDrive.AdvanceSharing': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.FileRequest': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.NodeLocking': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.Notifications': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.TeamFolders': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// 固定快照的可用性 notifier（测试直接给结果，不走真探测）
class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

/// 一个"检测过"的 Drive 能力快照：[driveApis] 是 `SYNO.API.Info` 里有的 API。
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
};

Map<String, dynamic> _trashItem() => {
  'file_id': '9',
  'name': 'probe-note.txt',
  'type': 'file',
  'path': '/recycle-bin/mydrive/probe-note.txt',
  'display_path': '/mydrive/probe-note.txt',
  'recycled_time': 1789775507,
  'size': 2048,
  'owner': {'display_name': 'demo_user'},
};

Map<String, dynamic> _driveItem({
  bool locked = false,
  bool canWrite = true,
  bool isDir = false,
}) => {
  'file_id': '2',
  'name': isDir ? 'homework' : 'readme.md',
  'type': isDir ? 'dir' : 'file',
  'path': isDir ? '/homework' : '/readme.md',
  'display_path': isDir ? '/mydrive/homework' : '/mydrive/readme.md',
  'parent_id': '1',
  'size': isDir ? 0 : 780,
  'modified_time': 1789775507,
  'content_type': isDir ? 'dir' : 'text',
  'capabilities': {
    'can_download': true,
    'can_preview': true,
    'can_write': canWrite,
    'can_lock': true,
  },
  'node_locking': {
    'is_locked': locked,
    'lock_user': {'name': 'demo_user', 'display_name': 'K'},
  },
};

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> apis = _allDriveApis,
  Map<String, int> failures = const {},
  /// ★ r373：注入身份。`null` = 不覆盖（与改前一致，老用例零影响）。
  AsyncValue<bool>? identity,
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._c1Table});
  t.onCall = (params) {
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
      if (identity != null)
        isAdminProvider.overrideWith((ref) {
          if (identity is AsyncData<bool>) return Future.value(identity.value);
          // 身份"还在查"：永远不完成的 future = 那一帧的未知态
          return Completer<bool>().future;
        }),
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

  group('能力位（§15 hidesModule 语义）', () {
    test('缺一个可选位 → partial，Drive 不隐藏', () {
      final snap = _snap({..._allDriveApis}..remove(kDriveFileRequestApi));
      expect(snap.stateOf(StationService.drive), AvailabilityState.partial);
      expect(hidesModule(snap.stateOf(StationService.drive)), isFalse);
      expect(snap.hasApi(StationService.drive, kDriveFileRequestApi), isFalse);
      expect(snap.hasApi(StationService.drive, kDriveTrashApi), isTrue);
    });

    test('105 → unauthorized（隐藏模块级）；119/106 → sessionExpired（绝不隐藏）', () {
      expect(classifyErrorCode(105), AvailabilityState.unauthorized);
      expect(hidesModule(classifyErrorCode(105)), isTrue);
      expect(classifyErrorCode(119), AvailabilityState.sessionExpired);
      expect(hidesModule(classifyErrorCode(119)), isFalse);
      expect(classifyErrorCode(106), AvailabilityState.sessionExpired);
      expect(hidesModule(classifyErrorCode(106)), isFalse);
    });
  });

  group('扩展入口页（能力位缺失 → 该入口隐藏）', () {
    testWidgets('能力齐全 → 四个入口都在', (tester) async {
      await _pump(tester, const DriveExtrasPage());
      expect(find.byKey(const Key('drive-extras-page')), findsOneWidget);
      expect(find.byKey(const Key('drive-extras-trash')), findsOneWidget);
      expect(
        find.byKey(const Key('drive-extras-file-requests')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('drive-extras-notifications')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('drive-extras-team-members')),
        findsOneWidget,
      );
    });

    testWidgets('缺 FileRequest → 只隐藏该入口，其余照旧（partial）', (tester) async {
      await _pump(
        tester,
        const DriveExtrasPage(),
        apis: {..._allDriveApis}..remove(kDriveFileRequestApi),
      );
      expect(find.byKey(const Key('drive-extras-page')), findsOneWidget);
      expect(find.byKey(const Key('drive-extras-file-requests')), findsNothing);
      expect(find.byKey(const Key('drive-extras-trash')), findsOneWidget);
      expect(
        find.byKey(const Key('drive-extras-notifications')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('drive-extras-team-members')),
        findsOneWidget,
      );
    });

    testWidgets('缺 Trash / Notifications / TeamFolders 各自只隐藏自己', (
      tester,
    ) async {
      await _pump(
        tester,
        const DriveExtrasPage(),
        apis: {..._allDriveApis}
          ..remove(kDriveTrashApi)
          ..remove(kDriveNotificationsApi)
          ..remove(kDriveTeamFoldersApi),
      );
      expect(find.byKey(const Key('drive-extras-trash')), findsNothing);
      expect(find.byKey(const Key('drive-extras-notifications')), findsNothing);
      expect(find.byKey(const Key('drive-extras-team-members')), findsNothing);
      expect(
        find.byKey(const Key('drive-extras-file-requests')),
        findsOneWidget,
      );
    });
  });

  // ★★★ r373：Drive「扩展入口」页里的**管理入口**（`drive-extras-admin`，
  // `drive_extras_page.dart:99` 的 `AdminOnly`）也必须有**成对**用例 ——
  // r372 真机已证"非管理员看不见"这一半，管理员那一半按用户裁定走 Mock/单元级。
  //
  // 为什么必须成对（见 `test/admin_gate_test.dart` 顶部）：
  //   只测"非管理员看不到" ⇒ **把入口删了也会全绿**；
  //   只测"管理员看得到" ⇒ **门控没生效也会全绿**。
  //
  // 列表是 `ListView`（懒构建）⇒ 断言前**必须滚到底**（§2.0.47：
  // 说"列表里没有"之前先滚到锚点，否则会把"没构建"读成"没有"）。
  group('★★ 扩展入口页：Drive 管理页是管理员专属（成对）', () {
    /// 滚到最后一个入口（`drive-extras-team-trash`）当"到底"锚点。
    Future<void> scrollToEnd(WidgetTester tester) async {
      await tester.dragUntilVisible(
        find.byKey(const Key('drive-extras-team-trash')),
        find.byType(Scrollable).first,
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('非管理员 ⇒ 管理入口隐藏；滚到底后其它入口都在', (tester) async {
      await _pump(
        tester,
        const DriveExtrasPage(),
        identity: const AsyncData(false),
      );
      expect(
        find.byKey(const Key('drive-extras-admin')),
        findsNothing,
        reason: '★ R2：非管理员不许看到 Drive 管理页入口',
      );
      await scrollToEnd(tester);
      expect(
        find.byKey(const Key('drive-extras-team-trash')),
        findsOneWidget,
        reason: '对照：已经滚到底部，底部入口可见',
      );
      expect(
        find.byKey(const Key('drive-extras-admin')),
        findsNothing,
        reason: '★ 滚到底也**没有** —— 排除"只是没构建"的假绿',
      );
      expect(find.text('管理（管理员）'), findsNothing, reason: '★ 连文字都不该出现');
    });

    testWidgets('管理员 ⇒ 管理入口展示（R3）', (tester) async {
      await _pump(
        tester,
        const DriveExtrasPage(),
        identity: const AsyncData(true),
      );
      await scrollToEnd(tester);
      expect(
        find.byKey(const Key('drive-extras-admin')),
        findsOneWidget,
        reason: '★★★ 新规 R3：管理员必须能正常看到并使用管理功能',
      );
    });

    testWidgets('身份未定（fail-closed）⇒ 也不显示', (tester) async {
      await _pump(
        tester,
        const DriveExtrasPage(),
        identity: const AsyncLoading<bool>(),
      );
      await scrollToEnd(tester);
      expect(find.byKey(const Key('drive-extras-admin')), findsNothing);
      expect(
        find.byKey(const Key('drive-extras-team-trash')),
        findsOneWidget,
        reason: '同一个列表里其它入口正常 —— 证明"藏"的确实是门控',
      );
    });
  });

  group('回收站页', () {
    Map<String, Map<String, dynamic>> trashResponses() => {
      'SYNO.SynologyDrive.Trash.list': {
        'items': [_trashItem()],
        'total': 1,
      },
      'SYNO.SynologyDrive.Trash.get_size': {
        'items': [
          {'size': 2048},
        ],
      },
    };

    testWidgets('成功：名称 / 原位置 / 删除时间 / 大小都在', (tester) async {
      await _pump(tester, const DriveTrashPage(), responses: trashResponses());
      expect(find.text('probe-note.txt'), findsOneWidget);
      expect(
        find.textContaining('原位置: /mydrive/probe-note.txt'),
        findsOneWidget,
      );
      expect(find.textContaining('删除于:'), findsOneWidget);
      expect(find.textContaining('2.0 KB'), findsWidgets);
      expect(find.byKey(const Key('drive-trash-empty')), findsOneWidget);
    });

    testWidgets('★ DA10c 恢复：点一下就走 Revisions/restore', (tester) async {
      final boot = await _pump(
        tester,
        const DriveTrashPage(),
        responses: {
          ...trashResponses(),
          'SYNO.SynologyDrive.Revisions.restore': {'async_task_id': 't1'},
        },
      );
      await tester.tap(find.byKey(const Key('drive-trash-restore-9')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final restore = boot.t.calls
          .where((c) => c['method'] == 'restore')
          .toList();
      expect(restore, hasLength(1));
      expect(restore.single['api'], 'SYNO.SynologyDrive.Revisions');
      expect(restore.single['files'], '[{"path":"id:9"}]');
    });

    testWidgets('永久删除必须先确认；取消 → 一个请求都不发', (tester) async {
      final boot = await _pump(
        tester,
        const DriveTrashPage(),
        responses: trashResponses(),
      );
      await tester.tap(find.byKey(const Key('drive-trash-delete-forever-9')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const Key('drive-trash-delete-confirm')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('drive-trash-delete-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        boot.t.calls.where((c) => c['method'] == 'delete'),
        isEmpty,
        reason: '取消确认后绝不能真的删',
      );

      // 再走一遍并确认 → 走 Files/delete + `permanent:true`（真机语义：清回收站）
      await tester.tap(find.byKey(const Key('drive-trash-delete-forever-9')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('drive-trash-delete-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final deletes = boot.t.calls
          .where((c) => c['method'] == 'delete')
          .toList();
      expect(deletes, hasLength(1));
      expect(deletes.single['api'], 'SYNO.SynologyDrive.Files');
      expect(deletes.single['files'], '["id:9"]');
      // 本页条目来自 Trash/list，它的 file_id 就是**回收站条目 id**：
      // 只有对它发 `permanent:true` 才真能从回收站清掉（`permanent_delete`
      // 服务端不认；对活动文件发 `permanent:true` 是静默 no-op）。
      expect(deletes.single['permanent'], isTrue);
      expect(deletes.single.containsKey('permanent_delete'), isFalse);
    });

    testWidgets('清空回收站必须先确认；取消 → 不发 empty', (tester) async {
      final boot = await _pump(
        tester,
        const DriveTrashPage(),
        responses: trashResponses(),
      );
      await tester.tap(find.byKey(const Key('drive-trash-empty')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const Key('drive-trash-empty-confirm')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('drive-trash-empty-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(boot.t.calls.where((c) => c['method'] == 'empty'), isEmpty);
    });

    testWidgets('105 → 无权限提示（不崩、不隐藏模块）', (tester) async {
      await _pump(
        tester,
        const DriveTrashPage(),
        responses: trashResponses(),
        failures: {'SYNO.SynologyDrive.Trash.list': 105},
      );
      expect(find.textContaining('没有权限'), findsOneWidget);
    });
  });

  group('通知页', () {
    testWidgets('成功列出 + 清空要二次确认（取消不发请求）', (tester) async {
      final boot = await _pump(
        tester,
        const DriveNotificationsPage(),
        responses: {
          'SYNO.SynologyDrive.Notifications.list': {
            'items': [
              {
                'notification_id': 'n1',
                'type': 'drive#upload_task',
                'time': 1789775507,
                'content': {
                  'action': 'upload',
                  'names': ['a.txt'],
                },
              },
            ],
            'total': 1,
          },
        },
      );
      expect(find.byKey(const Key('drive-notification-n1')), findsOneWidget);
      expect(find.textContaining('upload'), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-notifications-clear')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(
        find.byKey(const Key('drive-notifications-clear-cancel')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(boot.t.calls.where((c) => c['method'] == 'delete'), isEmpty);
    });
  });

  group('请求文件页', () {
    Map<String, Map<String, dynamic>> frResponses() => {
      'SYNO.SynologyDrive.FileRequest.list': {
        'items': [
          {
            'file_id': '9',
            'title': '交作业',
            'destination_folder': '/mydrive/homework',
            'sharing_link': 'fr1',
            'permanent_link': 'perm1',
            'file_request_status': 'active',
            'created_time': 1789775507,
          },
        ],
        'total': 1,
      },
    };

    testWidgets('成功列出；关闭走 update；删除要二次确认', (tester) async {
      final boot = await _pump(
        tester,
        const DriveFileRequestPage(),
        responses: {
          ...frResponses(),
          'SYNO.SynologyDrive.FileRequest.update': {'title': '交作业'},
        },
      );
      expect(find.text('交作业'), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-file-request-toggle-fr1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final updates = boot.t.calls
          .where((c) => c['method'] == 'update')
          .toList();
      expect(updates, hasLength(1));
      expect(updates.single['sharing_link'], 'fr1');
      expect(updates.single['path'], 'link:perm1');
      expect(updates.single['file_request_status'], 'inactive');

      await tester.tap(find.byKey(const Key('drive-file-request-delete-fr1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(
        find.byKey(const Key('drive-file-request-delete-cancel')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(boot.t.calls.where((c) => c['method'] == 'delete'), isEmpty);
    });

    testWidgets('业务错误码（1003 文件不存在）→ 说人话的错误态', (tester) async {
      await _pump(
        tester,
        const DriveFileRequestPage(),
        responses: frResponses(),
        failures: {'SYNO.SynologyDrive.FileRequest.list': 1003},
      );
      expect(find.text('打不开这个列表'), findsOneWidget);
    });
  });

  group('团队文件夹成员页', () {
    testWidgets('先列团队文件夹，点进去看成员', (tester) async {
      await _pump(
        tester,
        const DriveTeamMembersPage(),
        responses: {
          'SYNO.SynologyDrive.TeamFolders.list': {
            'items': [
              {
                'file_id': '77',
                'name': 'design',
                'type': 'dir',
                'path': '/team-folders/design',
                'display_path': '/team-folders/design',
              },
            ],
            'total': 1,
          },
          'SYNO.SynologyDrive.TeamFolders.list_members': {
            'items': [
              {
                'display_name': 'K',
                'name': 'demo_user',
                'uid': '1028',
                'role': 'organizer',
              },
            ],
            'total': 1,
          },
        },
      );
      expect(find.byKey(const Key('drive-team-folder-77')), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-team-folder-77')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('drive-team-member-demo_user')),
        findsOneWidget,
      );
      expect(find.textContaining('organizer'), findsOneWidget);
    });
  });

  group('文件列表行菜单：能力位缺失 → 对应菜单项隐藏', () {
    Future<({FakeTransport t, ProviderContainer c})> pumpBrowse(
      WidgetTester tester,
      Set<String> apis, {
      bool locked = false,
      bool isDir = false,
    }) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._c1Table});
      t.onCall = (params) => {
        'items': [_driveItem(locked: locked, isDir: isDir)],
        'total': 1,
        'success': true,
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
          child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: DriveBrowseView())),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return (t: t, c: c);
    }

    testWidgets('能力齐全 → 有「高级共享」「锁定」', (tester) async {
      await pumpBrowse(tester, _allDriveApis);
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('高级共享'), findsOneWidget);
      expect(find.text('锁定'), findsOneWidget);
    });

    testWidgets('缺 NodeLocking → 「锁定」消失；缺 AdvanceSharing → 「高级共享」消失', (
      tester,
    ) async {
      await pumpBrowse(
        tester,
        {..._allDriveApis}
          ..remove(kDriveNodeLockingApi)
          ..remove(kDriveAdvanceSharingApi),
      );
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('高级共享'), findsNothing);
      expect(find.text('锁定'), findsNothing);
      // 其它菜单项不受影响
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('已锁定的文件 → 出现「解锁」「请求解锁」并走 Files/lock', (tester) async {
      final boot = await pumpBrowse(tester, _allDriveApis, locked: true);
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('解锁'), findsOneWidget);
      expect(find.text('请求解锁'), findsOneWidget);
      await tester.tap(find.text('解锁'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final lock = boot.t.calls.where((c) => c['method'] == 'lock').toList();
      expect(lock, hasLength(1));
      expect(lock.single['perform_lock'], isFalse);
      expect(lock.single['files'], '["id:2"]');
    });

    testWidgets('文件夹菜单 → 「请求文件」→ 填标题 → FileRequest/create(path=id:<folder>)', (
      tester,
    ) async {
      final boot = await pumpBrowse(tester, _allDriveApis, isDir: true);
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('请求文件'), findsOneWidget);
      await tester.tap(find.text('请求文件'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(find.byType(TextField), '交作业');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // D43：标题之后要再选"上传者目录命名策略"（官方 identifierOptions）
      expect(
        find.byKey(const Key('drive-request-identifier-dialog')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('drive-request-identifier-create-folder')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final creates = boot.t.calls
          .where((c) => c['method'] == 'create')
          .toList();
      expect(creates, hasLength(1));
      expect(creates.single['api'], 'SYNO.SynologyDrive.FileRequest');
      expect(creates.single['title'], '交作业');
      expect(creates.single['identifier'], 'create_folder');
      expect(creates.single['path'], 'id:2');
    });

    testWidgets('缺 FileRequest 能力位 → 文件夹上不再显示「请求文件」', (tester) async {
      await pumpBrowse(
        tester,
        {..._allDriveApis}..remove(kDriveFileRequestApi),
        isDir: true,
      );
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('请求文件'), findsNothing);
      expect(find.text('删除'), findsOneWidget);
    });
  });

  group('高级共享页（管理与查看，无新建入口）', () {
    Map<String, Map<String, dynamic>> advResponses() => {
      'SYNO.SynologyDrive.AdvanceSharing.get': {
        'sharing_link': 'abc123',
        'url': 'https://nas/d/s/abc123',
        'role': 'viewer',
        'protect_password': 'pw',
        'due_date': 1800000000,
      },
    };

    testWidgets('成功：显示链接 / 角色 / 有效期 / 密码标记', (tester) async {
      await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:2', entryName: 'readme.md'),
        responses: advResponses(),
      );
      expect(
        find.byKey(const Key('drive-advance-sharing-page')),
        findsOneWidget,
      );
      expect(find.text('https://nas/d/s/abc123'), findsOneWidget);
      expect(
        find.byKey(const Key('drive-advance-sharing-role')),
        findsOneWidget,
      );
      expect(find.textContaining('已设置访问密码'), findsOneWidget);
      // 用户决定（§641）：不给"新建公开链接"入口
      expect(find.textContaining('新建'), findsNothing);
    });

    // ★ 第 60 轮 D39：访问密码编辑器**真的渲染出来了**（不只是能编译）。
    testWidgets('D39：密码输入框与保存按钮在场，且初值是服务端回显的密码', (tester) async {
      await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:2', entryName: 'readme.md'),
        responses: advResponses(),
      );
      expect(
        find.byKey(const Key('drive-link-password-field')),
        findsOneWidget,
        reason: '★ D39 的 UI 半边：没有这个框，用户就设不了密码',
      );
      expect(find.byKey(const Key('drive-link-password-save')), findsOneWidget);
      // 官方 `get` 会回显 `protect_password` ⇒ 初值应是它（不是空）
      final field = tester.widget<TextField>(
        find.byKey(const Key('drive-link-password-field')),
      );
      expect(
        field.controller?.text,
        'pw',
        reason:
            '★ 回填是"读-改-写"的前提：初值空的话，用户一保存就会'
            '把密码改成空串（= 清掉）',
      );
    });

    // ★ 第 61 轮 D39 收口：有效期编辑器**真的渲染**了。
    testWidgets('D39：有效期标签 + 修改按钮在场（有有效期时还有取消按钮）', (tester) async {
      await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:2', entryName: 'readme.md'),
        responses: advResponses(),
      );
      expect(
        find.byKey(const Key('drive-link-expiry-label')),
        findsOneWidget,
        reason: '★ D39 最后一项：没有这个，有效期就只能看不能改',
      );
      expect(find.byKey(const Key('drive-link-expiry-pick')), findsOneWidget);
      expect(
        find.byKey(const Key('drive-link-expiry-clear')),
        findsOneWidget,
        reason: '★ 已有有效期才给"取消有效期"（0 = 不过期）',
      );
    });

    testWidgets('D39：不过期时不给"取消有效期"，按钮文案是"添加有效期"', (tester) async {
      await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:2', entryName: 'readme.md'),
        responses: {
          'SYNO.SynologyDrive.AdvanceSharing.get': {
            'sharing_link': 'abc123',
            'url': 'https://nas/d/s/abc123',
            'role': 'viewer',
            'protect_password': '',
            'due_date': 0,
          },
        },
      );
      expect(find.byKey(const Key('drive-link-expiry-label')), findsOneWidget);
      expect(
        find.byKey(const Key('drive-link-expiry-clear')),
        findsNothing,
        reason: '★ 本来就没有效期，给"取消"是多余且误导',
      );
      expect(find.textContaining('添加有效期'), findsOneWidget);
    });

    // ★ 用户既定决定：**不给**"新建公开链接"入口
    // （`docs/workspace-expansion-evaluation.md:1238-1239` §641）。
    // 这条用例把"决定的排除项"钉住，防止以后有人把它当缺口又加回去。
    testWidgets('★ 无"新建公开链接"入口是**用户决定**，不是缺口', (tester) async {
      await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:2', entryName: 'readme.md'),
        responses: advResponses(),
      );
      expect(
        find.textContaining('新建'),
        findsNothing,
        reason: '★ §641 用户决定：只做查看/改角色/关链接',
      );
    });

    testWidgets('关闭链接要二次确认；取消 → 不发 delete；确认 → 走 delete', (tester) async {
      final boot = await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:2', entryName: 'readme.md'),
        responses: advResponses(),
      );
      await tester.tap(find.byKey(const Key('drive-advance-sharing-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const Key('drive-advance-sharing-close-confirm')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('drive-advance-sharing-close-cancel')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(boot.t.calls.where((c) => c['method'] == 'delete'), isEmpty);

      await tester.tap(find.byKey(const Key('drive-advance-sharing-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(
        find.byKey(const Key('drive-advance-sharing-close-confirm')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final deletes = boot.t.calls
          .where((c) => c['method'] == 'delete')
          .toList();
      expect(deletes, hasLength(1));
      expect(deletes.single['api'], 'SYNO.SynologyDrive.AdvanceSharing');
      expect(deletes.single['sharing_link'], 'abc123');
      expect(deletes.single['path'], 'id:2');
    });

    testWidgets('1036（还没开过链接）→ 空态，不当错误', (tester) async {
      await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:2', entryName: 'readme.md'),
        responses: advResponses(),
        failures: {'SYNO.SynologyDrive.AdvanceSharing.get': 1036},
      );
      expect(find.text('还没有公开链接'), findsOneWidget);
    });

    // ★ DA196：同一句「匿名公开链接…」原来在**页头 intro** 和**空态 message** 各出现一次
    //   （两处传同一个 key）。真机上就是上下同一句话，读起来像渲染错乱。
    testWidgets('DA196 1036 空态里那句说明只出现一次', (tester) async {
      await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:2', entryName: 'readme.md'),
        responses: advResponses(),
        failures: {'SYNO.SynologyDrive.AdvanceSharing.get': 1036},
      );
      final intro = find.textContaining('匿名公开链接');
      expect(intro, findsOneWidget,
          reason: '这句说明在页面上出现了 ${intro.evaluate().length} 次（DA196）');
    });
  });
}
