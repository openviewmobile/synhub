// ★★ ③Drive 第 212 轮 **D67「应用内 / 系统推送通知」** 的可做部分：
// **后台任务未读角标**（官方 `BackgroundTaskManager` 的 `unreadCount`）。
//
// ## 官方事实（`SynologyDrive 3.9.0-1113` smali）
// * `model/manager/BackgroundTaskManager.smali:1387` `getBadgeDisplayCount()`：
//   遍历 `getTasks()`，**跳过** `status.isFinished() && exceptions.isEmpty()`，
//   其余每个 +1 ⇒ 角标 = **进行中 + 失败（有异常）** 的任务数；
// * `:4341` `clearUnread()`：把 `unreadCount` 置 0 并 `notifyTaskCountChanged()`；
// * `unreadCount` 是**内存字段**（`:368`），不做持久化。
//
// ## 推送那一半为什么不在这里
// 官方的"系统推送"走 **FCM**（`SYNO.SynologyDrive.Mobile.Notification`
// 的 `pair/subscribe/unpair/unsubscribe` + `NotificationVo` 类型）。
// **用户已裁决本产品不做 FCM**（项目硬约束），所以推送不是"漏做"，
// 而是产品边界；本文件只钉**能做且官方有**的那半边：应用内未读角标。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_task_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/drive_tasks_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Tasks': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

DriveTaskDto _task(
  String id, {
  required String status,
  List<String> errors = const [],
}) => DriveTaskDto.fromJson({
  'task_id': id,
  'status': status,
  'progress': 0.5,
  'errors': errors,
  'result': {'action': 'upload', 'names': ['$id.bin'], 'task_id': id},
});

void main() {
  group('D67 · 角标判据（官方 getBadgeDisplayCount）', () {
    test('进行中 + 失败计数；干净完成的不算', () {
      final tasks = [
        _task('a', status: 'in_progress'),
        _task('b', status: 'finished', errors: ['boom']), // 失败（有异常）
        _task('c', status: 'finished'), // 干净完成 → 不算
      ];
      expect(driveTaskBadgeCount(tasks), 2);
      expect(driveTaskBadgeCount(const <DriveTaskDto>[]), 0);
    });
  });

  group('D67 · 角标 provider（看过就清）', () {
    Future<ProviderContainer> boot(FakeTransport t) async {
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      return ProviderContainer(
        overrides: [driveApiProvider.overrideWithValue(DriveApi(api))],
      );
    }

    FakeTransport withTasks(List<Map<String, dynamic>> items) {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        if ('${params['method']}' == 'list') {
          return {'items': items, 'total': items.length};
        }
        return {'success': true};
      };
      return t;
    }

    test('未看过的进行中/失败任务计入；markSeen 后归零', () async {
      final t = withTasks([
        {
          'task_id': 't1',
          'status': 'in_progress',
          'progress': 0.3,
          'result': {'action': 'upload', 'names': ['a'], 'task_id': 't1'},
        },
        {
          'task_id': 't2',
          'status': 'finished',
          'errors': ['boom'],
          'result': {'action': 'download', 'names': ['b'], 'task_id': 't2'},
        },
        {
          'task_id': 't3',
          'status': 'finished',
          'result': {'action': 'download', 'names': ['c'], 'task_id': 't3'},
        },
      ]);
      final c = await boot(t);
      addTearDown(c.dispose);
      expect(await c.read(driveTaskBadgeProvider.future), 2);

      c.read(driveTaskSeenProvider.notifier).markSeen(['t1', 't2', 't3']);
      expect(await c.read(driveTaskBadgeProvider.future), 0);
    });

    test('看过之后又来新任务 ⇒ 角标只数新的', () async {
      final t = withTasks([
        {
          'task_id': 't1',
          'status': 'in_progress',
          'progress': 0.3,
          'result': {'action': 'upload', 'names': ['a'], 'task_id': 't1'},
        },
      ]);
      final c = await boot(t);
      addTearDown(c.dispose);
      c.read(driveTaskSeenProvider.notifier).markSeen(['t1']);
      expect(await c.read(driveTaskBadgeProvider.future), 0);

      // 服务端又来一条新任务（同一次轮询里返回）
      t.onCall = (params) {
        if ('${params['method']}' == 'list') {
          return {
            'items': [
              {
                'task_id': 't1',
                'status': 'in_progress',
                'progress': 0.4,
                'result': {
                  'action': 'upload',
                  'names': ['a'],
                  'task_id': 't1',
                },
              },
              {
                'task_id': 't9',
                'status': 'in_progress',
                'progress': 0.1,
                'result': {
                  'action': 'upload',
                  'names': ['z'],
                  'task_id': 't9',
                },
              },
            ],
            'total': 2,
          };
        }
        return {'success': true};
      };
      c.invalidate(driveTaskBadgeProvider);
      expect(await c.read(driveTaskBadgeProvider.future), 1);
    });

    test('markSeen 幂等：重复标记相同 id 不产生新状态（不抖）', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final before = c.read(driveTaskSeenProvider);
      c.read(driveTaskSeenProvider.notifier).markSeen(['a']);
      final once = c.read(driveTaskSeenProvider);
      c.read(driveTaskSeenProvider.notifier).markSeen(['a']);
      expect(identical(once, c.read(driveTaskSeenProvider)), isTrue);
      expect(before, isEmpty);
      expect(once, {'a'});
      // 空 id 不许塞进去（deleteId 可能为空串）
      c.read(driveTaskSeenProvider.notifier).markSeen(['', 'b']);
      expect(c.read(driveTaskSeenProvider), {'a', 'b'});
    });
  });

  group('D67 · 页面接线', () {
    testWidgets('进过任务页 ⇒ 任务 id 被标记已读（角标随之消失）', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        if ('${params['method']}' == 'list') {
          return {
            'items': [
              {
                'task_id': 't1',
                'status': 'in_progress',
                'progress': 0.3,
                'result': {
                  'action': 'upload',
                  'names': ['a'],
                  'task_id': 't1',
                },
              },
            ],
            'total': 1,
          };
        }
        return {'success': true};
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c = ProviderContainer(
        overrides: [driveApiProvider.overrideWithValue(DriveApi(api))],
      );
      addTearDown(c.dispose);
      expect(c.read(driveTaskSeenProvider), isEmpty);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DriveTasksPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        c.read(driveTaskSeenProvider),
        contains('t1'),
        reason: '官方 clearUnread：进任务页就算看过',
      );
      expect(await c.read(driveTaskBadgeProvider.future), 0);
    });

    test('源码核验：顶栏角标只认 Drive 源、且有稳定 Key', () {
      // 私有 `_Deck` 没法直接构造（在 page 里），用源码断言钉住接线本身：
      // 角标必须 (a) 由 driveTaskBadgeProvider 供给、(b) 只在 Drive 源生效、
      // (c) 有 `file-drive-tasks-badge` 这个 Key（供真机/截图核对用）。
      final src = File(
        'lib/src/features/files/file_browse_page.dart',
      ).readAsStringSync();
      expect(src, contains('driveTaskBadgeProvider'));
      expect(src, contains("source == FileSource.drive"));
      expect(src, contains("Key('file-drive-tasks-badge')"));
      expect(src, contains('tasksBadge'));
    });
  });
}
