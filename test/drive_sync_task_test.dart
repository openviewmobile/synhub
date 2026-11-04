// ★★ ③Drive 第 217 轮 **D65「同步任务 / 同步设备管理」** 的离线用例。
//
// 官方口径（208 轮取证 + 本轮复核）：官方「同步任务」是**本地目录同步引擎**
// （Room `SyncDB`/`TaskInfo` + `SyncRunner`），**不是**服务端任务 API ——
// catalog 里 `SYNO.SynologyDrive.Sync*` **0 命中**。所以：
//   * 任务模型/校验/差异决策/存储 ⇒ 纯离线用例（本文件前半）；
//   * 它唯一用到的服务端面 —— 远端列举 `SYNO.SynologyDrive.Files.list` ⇒
//     **Mock Server 验**（页面那条用例）；
//   * ⚠️ 真正的文件搬运 + 后台常驻（`DriveFileWatchService`）仍未实现，
//     台账保持 🟠，不冒充 ✅。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_sync_task.dart';
import 'package:synhub/src/features/drive/drive_sync_tasks_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

DriveSyncTask _task({
  String id = 't1',
  String local = '/sdcard/项目',
  String remote = '/mydrive/项目',
  DriveSyncConflict conflict = DriveSyncConflict.rename,
  bool ignoreLocalRemove = false,
  int limitSize = 0,
  DriveSyncStatus status = DriveSyncStatus.idle,
  bool auto = true,
  int interval = 30,
  int lastSyncAtMs = 0,
  bool deleted = false,
}) => DriveSyncTask(
  deleted: deleted,
  id: id,
  localRoot: local,
  remoteRoot: remote,
  conflict: conflict,
  ignoreLocalRemove: ignoreLocalRemove,
  limitSize: limitSize,
  status: status,
  autoSyncEnabled: auto,
  autoSyncInterval: interval,
  lastSyncAtMs: lastSyncAtMs,
);

DriveSyncLocalEntry _l(String p, int size, int ms) =>
    DriveSyncLocalEntry(path: p, isDir: false, size: size, modifiedMs: ms);

DriveSyncRemoteEntry _r(String p, int size, int ms) =>
    DriveSyncRemoteEntry(path: p, isDir: false, size: size, modifiedMs: ms);

void main() {
  group('D65 · 任务模型（与官方 TaskInfo 逐字段对齐）', () {
    test('toJson 的键就是官方 Room 列名', () {
      final keys = _task().toJson().keys.toSet();
      expect(keys, {
        'id',
        'local_root',
        'remote_root',
        'remote_root_change_id',
        'status',
        'auto_sync_enabled',
        'auto_sync_interval',
        'conflict_rename',
        'conflict_keep_latest',
        'ignore_local_remove',
        'index_home',
        'limit_size',
        'https',
        'deleted',
        'last_sync_at',
      });
    });

    test('JSON 往返不丢字段（含两个冲突布尔）', () {
      final t = _task(
        conflict: DriveSyncConflict.keepLatest,
        ignoreLocalRemove: true,
        limitSize: 1024,
      ).copyWith(remoteRootChangeId: 'cur-9', lastSyncAtMs: 1700000000000);
      final back = DriveSyncTask.fromJson(t.toJson());
      expect(back.localRoot, t.localRoot);
      expect(back.remoteRoot, t.remoteRoot);
      expect(back.remoteRootChangeId, 'cur-9');
      expect(back.conflict, DriveSyncConflict.keepLatest);
      expect(back.ignoreLocalRemove, isTrue);
      expect(back.limitSize, 1024);
      expect(back.lastSyncAtMs, 1700000000000);
      expect(back.toJson()['conflict_keep_latest'], isTrue);
      expect(back.toJson()['conflict_rename'], isFalse);
    });

    test('status 用官方 wire 值；未知值退回 idle', () {
      expect(DriveSyncStatus.syncing.wire, 'syncing');
      expect(_task(status: DriveSyncStatus.paused).toJson()['status'], 'paused');
      expect(driveSyncStatusOf('whatever'), DriveSyncStatus.idle);
    });

    test('localName 取末段（列表标题）', () {
      expect(_task(local: '/sdcard/我的/项目').localName, '项目');
    });
  });

  group('D65 · 路径归一化与校验', () {
    test('本地/远端都去尾斜杠；远端补前导 /', () {
      expect(normalizeDriveLocalRoot('/sdcard/x/'), '/sdcard/x');
      expect(normalizeDriveLocalRoot('C:\\Users\\a\\'), 'C:/Users/a');
      expect(normalizeDriveRemoteRoot('mydrive/x/'), '/mydrive/x');
      expect(normalizeDriveRemoteRoot('/mydrive/x//'), '/mydrive/x');
    });

    test('本地或远端为空 ⇒ 拒', () {
      expect(validateDriveSyncTask(_task(local: '  '), const []).ok, isFalse);
      expect(validateDriveSyncTask(_task(remote: ''), const []).ok, isFalse);
    });

    test('同一远端目录不能被两个任务占用', () {
      final v = validateDriveSyncTask(_task(id: 't2'), [_task(id: 't1')]);
      expect(v.ok, isFalse);
      expect(v.error, contains('占用'));
      // 自己更新自己不算冲突
      expect(validateDriveSyncTask(_task(id: 't1'), [_task(id: 't1')]).ok, isTrue);
    });

    test('本地目录互相包含 ⇒ 拒（否则一个文件被两个任务抢）', () {
      final v = validateDriveSyncTask(
        _task(id: 't2', local: '/sdcard/a/b', remote: '/mydrive/b'),
        [_task(id: 't1', local: '/sdcard/a', remote: '/mydrive/a')],
      );
      expect(v.ok, isFalse);
      expect(v.error, contains('包含'));
    });

    test('自动同步但间隔 <=0 ⇒ 拒', () {
      expect(validateDriveSyncTask(_task(interval: 0), const []).ok, isFalse);
      expect(
        validateDriveSyncTask(_task(auto: false, interval: 0), const []).ok,
        isTrue,
      );
    });
  });

  group('D65 · 差异决策（官方 SyncRunner 的判定层）', () {
    test('只有本地有 ⇒ 上传', () {
      final d = planDriveSync(
        local: [_l('a.txt', 10, 1000)],
        remote: const [],
        task: _task(),
      );
      expect(d.uploads, 1);
      expect(d.actions.single.kind, DriveSyncActionKind.upload);
    });

    test('只有远端有 ⇒ 删远端（默认语义）', () {
      final d = planDriveSync(
        local: const [],
        remote: [_r('gone.txt', 10, 1000)],
        task: _task(),
      );
      expect(d.actions.single.kind, DriveSyncActionKind.removeRemote);
    });

    test('ignore_local_remove ⇒ 远端保留并拉回来（不跟着删）', () {
      final d = planDriveSync(
        local: const [],
        remote: [_r('keep.txt', 10, 1000)],
        task: _task(ignoreLocalRemove: true),
      );
      expect(d.actions.single.kind, DriveSyncActionKind.download);
      expect(d.actions.single.reason, contains('忽略本地删除'));
    });

    test('大小/时间一致 ⇒ 跳过（不重复搬运）', () {
      final d = planDriveSync(
        local: [_l('same.txt', 10, 5000)],
        remote: [_r('same.txt', 10, 5000)],
        task: _task(),
      );
      expect(d.isEmpty, isTrue);
    });

    test('keepLatest：谁新听谁的', () {
      final up = planDriveSync(
        local: [_l('x', 10, 9000)],
        remote: [_r('x', 10, 1000)],
        task: _task(conflict: DriveSyncConflict.keepLatest),
      );
      expect(up.actions.single.kind, DriveSyncActionKind.upload);
      final down = planDriveSync(
        local: [_l('x', 10, 1000)],
        remote: [_r('x', 99, 9000)],
        task: _task(conflict: DriveSyncConflict.keepLatest),
      );
      expect(down.actions.single.kind, DriveSyncActionKind.download);
    });

    test('rename：两端都改过 ⇒ 本地生成冲突副本', () {
      final d = planDriveSync(
        local: [_l('x', 10, 9000)],
        remote: [_r('x', 99, 1000)],
        task: _task(conflict: DriveSyncConflict.rename),
      );
      expect(d.actions.single.kind, DriveSyncActionKind.renameLocal);
      expect(d.conflicts, 1);
    });

    test('limit_size：超限的文件跳过并给理由', () {
      final d = planDriveSync(
        local: [_l('big.bin', 5000, 1), _l('small.bin', 10, 1)],
        remote: const [],
        task: _task(limitSize: 1000),
      );
      expect(d.uploads, 1);
      expect(
        d.actions.firstWhere((a) => a.path == 'big.bin').kind,
        DriveSyncActionKind.skip,
      );
      expect(
        d.actions.firstWhere((a) => a.path == 'big.bin').reason,
        contains('上限'),
      );
    });

    test('目录条目不产生动作；结果按路径排序', () {
      final d = planDriveSync(
        local: [
          const DriveSyncLocalEntry(path: 'dir', isDir: true, size: 0, modifiedMs: 0),
          _l('b.txt', 1, 1),
          _l('a.txt', 1, 1),
        ],
        remote: const [],
        task: _task(),
      );
      expect(d.actions.map((a) => a.path), ['a.txt', 'b.txt']);
    });
  });

  group('D65 · 自动同步调度决策', () {
    final t0 = DateTime.fromMillisecondsSinceEpoch(1000 * 60 * 60 * 24);

    test('从未同步 ⇒ 立即该跑；关掉自动同步 ⇒ 不跑', () {
      expect(driveSyncDue(_task(), t0), isTrue);
      expect(driveSyncDue(_task(auto: false), t0), isFalse);
    });

    test('同步中不重入；到间隔才跑', () {
      final syncing = _task(status: DriveSyncStatus.syncing, lastSyncAtMs: 0);
      expect(driveSyncDue(syncing, t0), isFalse);
      final justNow = _task(
        interval: 30,
        lastSyncAtMs: t0.millisecondsSinceEpoch,
      );
      expect(driveSyncDue(justNow, t0), isFalse);
      expect(
        driveSyncDue(
          justNow,
          t0.add(const Duration(minutes: 31)),
        ),
        isTrue,
      );
    });

    test('nextIn 给剩余时间（该跑时为 0）', () {
      final t = _task(interval: 30, lastSyncAtMs: t0.millisecondsSinceEpoch);
      expect(
        driveSyncNextIn(t, t0.add(const Duration(minutes: 10))),
        const Duration(minutes: 20),
      );
      expect(driveSyncNextIn(t, t0.add(const Duration(minutes: 40))), Duration.zero);
      expect(driveSyncNextIn(_task(), t0), Duration.zero);
    });
  });

  group('D65 · 存储', () {
    test('Memory 存储 save/load 真的写进去', () async {
      final s = MemoryDriveSyncTaskStore();
      expect(await s.load(), isEmpty);
      await s.save([_task()]);
      expect((await s.load()).single.id, 't1');
      expect(s.snapshot.single.remoteRoot, '/mydrive/项目');
    });

    test('JSON 文件存储：往返 + 坏文件当空表（页面不该打不开）', () async {
      final dir = Directory.systemTemp.createTempSync('d65_store');
      final f = File('${dir.path}/tasks.json');
      final store = JsonDriveSyncTaskStore(f);
      expect(await store.load(), isEmpty);
      await store.save([_task(), _task(id: 't2', remote: '/mydrive/2')]);
      final back = await store.load();
      expect(back.map((t) => t.id), ['t1', 't2']);
      // 键名是官方列名
      expect(jsonDecode(await f.readAsString()).first['local_root'], '/sdcard/项目');

      await f.writeAsString('{ 不是 JSON');
      expect(await store.load(), isEmpty);
    });

    test('软删：deleted=true 保留在库里，但 live 列表不显示', () async {
      final dir = Directory.systemTemp.createTempSync('d65_del');
      final f = File('${dir.path}/tasks.json');
      final store = JsonDriveSyncTaskStore(f);
      await store.save([_task(deleted: true), _task(id: 't2', remote: '/mydrive/2')]);
      final all = await store.load();
      expect(all.where((t) => !t.deleted).length, 1);
    });
  });

  group('D65 · 页面（离线 + Mock 核实 Files/list）', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required MockDsmBackend backend,
      required List<DriveSyncTask> tasks,
      required List<DriveSyncLocalEntry> local,
    }) async {
      final web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: 'u', password: 'x');
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(web)),
          driveSyncStoreProvider.overrideWithValue(
            MemoryDriveSyncTaskStore(tasks),
          ),
          driveSyncLocalScannerProvider.overrideWithValue((_) async => local),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const DriveSyncTasksPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return c;
    }

    MockDsmBackend backend() {
      final b = MockDsmBackend(catalog: DsmCatalog.load());
      b.login(username: 'u', admin: false);
      return b;
    }

    testWidgets('空态：说明"还没有同步任务"', (tester) async {
      await pump(tester, backend: backend(), tasks: const [], local: const []);
      expect(find.byKey(const Key('drive-sync-tasks-page')), findsOneWidget);
      expect(find.textContaining('还没有同步任务'), findsOneWidget);
    });

    testWidgets('新建任务：填本地/远端 → 保存后进列表', (tester) async {
      await pump(tester, backend: backend(), tasks: const [], local: const []);
      await tester.tap(find.byKey(const Key('drive-sync-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-sync-dialog')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('drive-sync-local-field')),
        '/sdcard/项目/',
      );
      await tester.enterText(
        find.byKey(const Key('drive-sync-remote-field')),
        'mydrive/项目',
      );
      await tester.tap(find.byKey(const Key('drive-sync-save')));
      await tester.pumpAndSettle();
      expect(find.text('项目'), findsWidgets);
      expect(find.textContaining('/mydrive/项目'), findsOneWidget);
    });

    testWidgets('重复远端目录 ⇒ 拒绝并提示', (tester) async {
      await pump(
        tester,
        backend: backend(),
        tasks: [_task(id: 't1', remote: '/mydrive/项目')],
        local: const [],
      );
      await tester.tap(find.byKey(const Key('drive-sync-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('drive-sync-local-field')),
        '/sdcard/别的',
      );
      await tester.enterText(
        find.byKey(const Key('drive-sync-remote-field')),
        '/mydrive/项目',
      );
      await tester.tap(find.byKey(const Key('drive-sync-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('占用'), findsOneWidget);
    });

    testWidgets('删除任务 ⇒ 从列表消失（软删，仍在库里）', (tester) async {
      final c = await pump(
        tester,
        backend: backend(),
        tasks: [_task(id: 't1')],
        local: const [],
      );
      await tester.tap(find.byKey(const Key('drive-sync-menu-t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-sync-task-t1')), findsNothing);
      final store = c.read(driveSyncStoreProvider) as MemoryDriveSyncTaskStore;
      expect(store.snapshot.single.deleted, isTrue);
    });

    testWidgets('立即检查：本地扫描 + Mock `Files/list` → 差异明细（含冲突）', (
      tester,
    ) async {
      final b = backend();
      // Mock 的 Files/list 返回远端目录内容（官方字段名）
      b.fixture('SYNO.SynologyDrive.Files', 'list', (p) => {
        'success': true,
        'data': {
          'total': 2,
          'offset': 0,
          'items': [
            {
              'file_id': 'r1',
              'name': '远端新增.txt',
              'type': 'file',
              'size': 10,
              'modified_time': 1000,
              'path': '',
              'display_path': '',
              'parent_id': '0',
              'created_time': 1000,
              'content_type': 'text/plain',
              'capabilities': {},
            },
            {
              'file_id': 'r2',
              'name': '两端都改.txt',
              'type': 'file',
              'size': 999,
              'modified_time': 1000,
              'path': '',
              'display_path': '',
              'parent_id': '0',
              'created_time': 1000,
              'content_type': 'text/plain',
              'capabilities': {},
            },
          ],
        },
      });
      await pump(
        tester,
        backend: b,
        tasks: [_task(id: 't1')],
        local: [_l('本地新增.txt', 5, 1), _l('两端都改.txt', 5, 9000)],
      );
      await tester.tap(find.byKey(const Key('drive-sync-menu-t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即检查'));
      await tester.pumpAndSettle();
      expect(find.textContaining('待上传 1'), findsOneWidget);
      expect(find.textContaining('冲突 1'), findsOneWidget);
      // 诚实边界那句话必须在（r378 去掉"本轮"这种会过期的进度话）
      expect(find.textContaining('只做差异检查'), findsOneWidget);
      expect(find.textContaining('本轮'), findsNothing);
      // Mock 真的被调到了
      expect(
        b.requests.any((r) => '${r.params['api']}' == 'SYNO.SynologyDrive.Files'),
        isTrue,
      );
    });
  });
}
