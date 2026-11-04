// 「文件」第二来源（Synology Drive，P0.1 尾巴）的离线测试。
//
// 关注四件事：
//   1. **参数与官方逐字对齐**（`path=id:<file_id>`、`files` 是 JSON 数组字符串、
//      列表用 v3 / 写操作用 v2）—— 真机上参数写错的表现是 `114/120`，不是崩溃；
//   2. 回包是 `{items,total}`（不是 FileStation 的 `{files,total}`）；
//   3. 缩略图/下载**不是 JSON 接口**：URL 里带 api/method/version + `_sid`，
//      服务端直接回字节；
//   4. 页面：Drive 源能列目录、进子目录、面包屑回退、空态/错误态说人话。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/data/dto/drive_label_dto.dart';
import 'package:synhub/src/data/dto/drive_share_dto.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_browse_view.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/office_export.dart';
import 'package:synhub/src/features/files/office_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 有界条件等待：交替 flush 假时钟 microtask（`pump`）与给真实 I/O 时间
/// （`runAsync`），直到 [done] 成立即返回。
///
/// 用于"真实文件 I/O 无法被假时钟推进"的收尾。**上限只防死等，不参与判定**；
/// 不要用固定延时窗口（负载下会 flake —— 本文件的 Office 两条曾用
/// `3 × runAsync(150ms)`，08:46 全量就红在这里）。
Future<void> _settleUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxRounds = 300,
  Duration realStep = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < maxRounds && !done(); i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(realStep));
  }
  await tester.pump();
}

/// 1×1 透明 PNG（够 Flutter 解码）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 真机上 `Files/list` 回来的形状（2026-09-18 实测，字段名逐个对照）
Map<String, dynamic> _item({
  required String id,
  required String name,
  required String type,
  required String path,
  int size = 780,
  String content = 'document',
}) => {
  'file_id': id,
  'name': name,
  'type': type,
  'path': path,
  'display_path': '/mydrive$path',
  'parent_id': '900',
  'size': type == 'dir' ? 0 : size,
  'modified_time': 1789739500,
  'created_time': 1789739499,
  'content_type': type == 'dir' ? 'dir' : content,
  'starred': false,
  'shared': false,
  'owner': {'display_name': 'demo_user', 'name': 'demo_user', 'uid': 1028},
  'capabilities': {
    'can_download': true,
    'can_preview': true,
    'can_write': true,
  },
  'version_id': '8',
};

const _driveTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  // 表里写 maxVersion 2，但真机 v2 回 1000 → 版本协商必须选到 1
  'SYNO.SynologyDrive.Trash': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  // P3：团队文件夹只有 v1
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
  // P3 尾巴：版本 / 共享 / 成员候选（真机：Revisions 只有 v1，Sharing 只有 v1）
  'SYNO.SynologyDrive.Revisions': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Sharing': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Share.Priv': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

DsmWebApi _api(FakeTransport t) => DsmWebApi(t);

/// 登录并返回**同一个** api（DriveApi 的 URL 要带 `_sid`，所以不能另建一个）
Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = _api(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

void main() {
  group('DriveApi：参数与官方对齐', () {
    test('list 用 v3 + path/offset/limit/sort_by/sort_direction', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {
        'items': [
          _item(
            id: '973840842603147299',
            name: 'drive-probe',
            type: 'dir',
            path: '/drive-probe',
          ),
        ],
        'total': 1,
        'success': true,
      };
      final api = await _loggedIn(t);
      final result = await DriveApi(
        api,
      ).list(path: kDriveRoot, sortBy: DriveSortBy.name, sortDirection: 'desc');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.Files');
      expect(call['method'], 'list');
      expect(call['version'], '3', reason: '官方 get_file/list 用 v3');
      expect(call['path'], '/mydrive');
      expect(call['offset'], 0);
      expect(call['limit'], 200);
      expect(call['sort_by'], 'name');
      expect(call['sort_direction'], 'desc');
      expect(result.total, 1);
      expect(result.items.single.name, 'drive-probe');
      expect(result.items.single.isDir, isTrue);
      expect(result.items.single.pathId, 'id:973840842603147299');
    });

    test('list 的 path 支持 id:<file_id>（官方 getPathId）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {'items': const [], 'total': 0, 'success': true};
      final api = await _loggedIn(t);
      await DriveApi(api).list(path: 'id:123');
      expect(t.calls.last['path'], 'id:123');
    });

    test('get 用 v3、delete 用 v2 且 files 是 JSON 数组字符串', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {
        'file_id': '9',
        'name': 'a.txt',
        'type': 'file',
        'size': 10,
        'success': true,
      };
      final api = await _loggedIn(t);
      final drive = DriveApi(api);
      await drive.get(path: 'id:9');
      expect(t.calls.last['version'], '3');
      expect(t.calls.last['path'], 'id:9');

      t.onCall = (params) => {'async_task_id': 'task-1', 'success': true};
      await drive.delete(fileIds: ['9', '10']);
      final del = t.calls.last;
      expect(del['method'], 'delete');
      expect(del['version'], '2');
      // 真机实测：必须是 `["id:9","id:10"]` 这种 JSON 串；传裸 id 会 114
      expect(del['files'], '["id:9","id:10"]');
      // 普通删除**只发 files** ⇒ 语义就是"进回收站"（真机唯一对活动文件有效的形态）。
      // ⚠️ 绝不能发 `permanent_delete`（服务端不认，等同不传）；
      //    `permanent` 只对**回收站条目**有效，对活动文件是静默 no-op。
      expect(del.containsKey('permanent'), isFalse);
      expect(del.containsKey('permanent_delete'), isFalse);
    });

    test('deleteFromTrash 只给回收站条目发 `permanent:true`（真机唯一有效形态）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {'async_task_id': 'task-2', 'success': true};
      final api = await _loggedIn(t);
      await DriveApi(api).deleteFromTrash(trashFileIds: ['9']);
      final call = t.calls.last;
      expect(call['method'], 'delete');
      expect(call['version'], '2');
      expect(call['files'], '["id:9"]');
      // 真机 A/B：对回收站条目发 `permanent:true` → 从回收站永久消失；
      // 参数名**不是** `permanent_delete`（服务端不认识的串）。
      expect(call['permanent'], true);
      expect(call.containsKey('permanent_delete'), isFalse);
    });

    test('create 用 type:"folder"（用 dir 会被拒）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {
        'file_id': '11',
        'name': 'sub',
        'type': 'dir',
        'success': true,
      };
      final api = await _loggedIn(t);
      await DriveApi(api).createFolder(path: '/mydrive/sub');
      expect(t.calls.last['type'], 'folder');
      expect(t.calls.last['version'], '2');
    });

    test('星标 / 标签 / 复制移动的参数形态', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {'success': true};
      final api = await _loggedIn(t);
      final drive = DriveApi(api);
      await drive.star(fileIds: ['9'], starred: true);
      expect(t.calls.last['files'], '["id:9"]');
      expect(t.calls.last['starred'], true);
      // 打标签：真机验证过的编码是**动作数组**（不是 id 列表）
      await drive.setLabels(
        fileIds: ['9'],
        changes: [const DriveLabelChange.add('3')],
      );
      expect(t.calls.last['labels'], '[{"action":"add","label_id":3}]');
      expect(t.calls.last['method'], 'label');
      expect(t.calls.last['version'], '2');
      await drive.setLabels(
        fileIds: ['9'],
        changes: [const DriveLabelChange.remove('3')],
      );
      expect(t.calls.last['labels'], '[{"action":"delete","label_id":3}]');
      await drive.copyOrMove(
        fileIds: ['9'],
        toParentFolderId: '77',
        move: true,
      );
      expect(t.calls.last['method'], 'move');
      expect(t.calls.last['to_parent_folder'], 'id:77');
      expect(t.calls.last['conflict_action'], 'autorename');
    });
  });

  group('回收站（真机的坑都在参数上）', () {
    test('Trash/list 必须带 path + offset/limit，且只能用 v1', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {
        'items': [
          _item(
            id: '9',
            name: 'probe-note.txt',
            type: 'file',
            path: '/recycle-bin/mydrive/probe-note.txt',
            content: 'text',
          ),
        ],
        'total': 1,
        'success': true,
      };
      final api = await _loggedIn(t);
      final trash = await DriveApi(api).listTrash();
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.Trash');
      expect(call['method'], 'list');
      // 表里写着 maxVersion 2，但发 v2 真机回 1000 → 必须 v1
      expect(call['version'], '1');
      // 少了 path 真机回 1000（看着像未知错误，其实是缺参数）
      expect(call['path'], '/mydrive');
      expect(call['offset'], 0);
      expect(call['limit'], 200);
      expect(trash.total, 1);
      expect(trash.items.single.name, 'probe-note.txt');
    });

    test('Trash/empty 只收 path（空间路径）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {'async_task_id': 'task-9', 'success': true};
      final api = await _loggedIn(t);
      final task = await DriveApi(api).emptyTrash();
      final emptied = t.calls.where((c) => c['method'] == 'empty').toList();
      expect(emptied, hasLength(1), reason: '确认后正好清空一次');
      expect(emptied.single['api'], 'SYNO.SynologyDrive.Trash');
      expect(emptied.single['path'], '/mydrive');
      expect(task, 'task-9');
    });
  });

  group('Drive 更多（P3）：回收站/星标/共享给我/团队文件夹', () {
    test('list_starred / shared_with_me 用 v3，TeamFolders 用 v1', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {'items': const [], 'total': 0};
      final api = await _loggedIn(t);
      final drive = DriveApi(api);

      await drive.listStarred();
      expect(t.calls.last['api'], 'SYNO.SynologyDrive.Files');
      expect(t.calls.last['method'], 'list_starred');
      expect(t.calls.last['version'], '3');

      await drive.sharedWithMe();
      expect(t.calls.last['method'], 'shared_with_me');
      expect(t.calls.last['version'], '3');

      await drive.teamFolders();
      final team = t.calls.last;
      expect(team['api'], 'SYNO.SynologyDrive.TeamFolders');
      expect(team['method'], 'list');
      expect(team['version'], '1', reason: 'TeamFolders 只有 v1');
      expect(team['offset'], 0);
    });

    // ★ r369（真机 DA22）：`TeamFolders/list` 的条目**不带 `type`** ——
    // 真机像素：团队文件夹 `teamdrivetest` 的大小列显示 `0 B`（不是 `Folder`），
    // 点进去进的是**文件预览页**（`This kind of file opens in a system app`）。
    // 团队文件夹按定义是目录 ⇒ 这一批在边界上声明 `dir`。
    test('TeamFolders/list 的条目没有 type，也必须解析成目录（DA22）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      // 回包逐字形态：**没有 type 字段**（这就是那个坑）
      t.onCall = (params) => {
            'items': [
              {'file_id': '12345', 'name': 'teamdrivetest', 'size': 0},
            ],
            'total': 1,
          };
      final api = await _loggedIn(t);
      final drive = DriveApi(api);

      final page = await drive.teamFolders();
      expect(page.items, hasLength(1));
      expect(
        page.items.first.isDir,
        isTrue,
        reason: '团队文件夹是目录；type 缺失时不许按 DriveEntryDto 的兜底当文件',
      );
      expect(page.items.first.humanSize, '', reason: '目录不显示大小');
      expect(page.items.first.pathId, 'id:12345');
    });

    test('反向：普通 Files/list 条目缺 type 仍按文件处理（修复只作用于团队文件夹）', () {
      final entry = DriveEntryDto.fromJson(const {
        'file_id': '999',
        'name': 'a.bin',
      });
      expect(entry.isDir, isFalse);
    });

    test('Trash/get_size 用 v2，只带 path', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      // 真机空回收站回 `{items:null}`
      t.onCall = (params) => {'items': null};
      final api = await _loggedIn(t);
      final size = await DriveApi(api).trashSize();
      expect(t.calls.last['api'], 'SYNO.SynologyDrive.Trash');
      expect(t.calls.last['method'], 'get_size');
      expect(t.calls.last['version'], '2');
      expect(t.calls.last['path'], '/mydrive');
      expect(size, 0);
    });

    test('Trash/get_size 有内容时把尺寸加起来', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {
        'items': [
          {'size': 1024},
          {'size': 2048},
        ],
      };
      final api = await _loggedIn(t);
      expect(await DriveApi(api).trashSize(), 3072);
    });

    testWidgets('更多页：四个分段都在，写操作只有「清空回收站」且要二次确认', (tester) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {
        'items': [
          _item(
            id: '9',
            name: 'probe-note.txt',
            type: 'file',
            path: '/recycle-bin/mydrive/probe-note.txt',
            content: 'text',
          ),
        ],
        'total': 1,
      };
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(api)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DriveMorePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 回收站里的条目看得见
      expect(find.text('probe-note.txt'), findsOneWidget);
      expect(find.textContaining('已删除'), findsOneWidget);

      // 清空要确认，取消就什么都不做
      await tester.tap(find.text('清空回收站'));
      await tester.pumpAndSettle();
      expect(find.text('清空回收站？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        t.calls.where((c) => c['method'] == 'empty'),
        isEmpty,
        reason: '点了取消不能真清空',
      );

      // 确认之后才会发 empty
      await tester.tap(find.text('清空回收站'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      final emptied = t.calls.where((c) => c['method'] == 'empty').toList();
      expect(emptied, hasLength(1), reason: '确认后正好清空一次');
      expect(emptied.single['api'], 'SYNO.SynologyDrive.Trash');
      expect(emptied.single['path'], '/mydrive');
    });

    // DA10（r355 真机取证）：回收站里的**目录**行，其 `file_id` 是
    // `Trash/list` 回的回收站条目 id；拿它发 `Files/list path=id:<…>`
    // 真机**必然**回 1003 ⇒ 不许再给这个必然报错的入口。
    // 正面判据：点它**不推** `DriveFolderPage`；反向：文件行**仍然**推预览。
    testWidgets('★ DA10a：回收站目录行不可点进必然 1003 的文件夹页，文件行仍可点开', (tester) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) {
        if (params['method'] == 'list' && params['api']?.toString().contains('Trash') == true) {
          return {
            'items': [
              _item(id: '9', name: 'probe-dir', type: 'dir', path: '/probe-dir'),
              _item(
                id: '10',
                name: 'probe-note.txt',
                type: 'file',
                path: '/probe-note.txt',
                content: 'text',
              ),
            ],
            'total': 2,
          };
        }
        return {'items': const [], 'total': 0};
      };
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(api)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DriveMorePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('probe-dir'), findsOneWidget);

      // ① 目录行点了不推文件夹页（页面在，但点完还停在更多页）
      await tester.tap(find.text('probe-dir'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('drive-folder-page')),
        findsNothing,
        reason: '回收站目录的 id 拿去 Files/list 必然 1003，不许给这个入口',
      );
      expect(find.text('清空回收站'), findsOneWidget, reason: '应当还停在更多页');

      // ② 反向：文件行仍然可点开（说明关的是"必然报错的那一类"，不是整页）
      await tester.tap(find.text('probe-note.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(DriveMorePage),
        findsOneWidget,
        reason: '文件行走预览通道，不该把整个页面拆掉',
      );
      expect(t.calls.any((c) => c['method'] == 'list'), isTrue);
    });

    testWidgets('更多页四段支持左右滑动切换', (tester) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {'items': const [], 'total': 0};
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(api)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DriveMorePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final pager = find.byKey(const Key('drive-more-pager'));
      // 左滑 → 星标
      await tester.fling(pager, const Offset(-600, 0), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('还没有星标文件'), findsOneWidget);

      // 再左滑 → 共享给我
      await tester.fling(pager, const Offset(-600, 0), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('没有人共享给你'), findsOneWidget);

      // 右滑 → 回星标
      await tester.fling(pager, const Offset(600, 0), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('还没有星标文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('更多页：星标/共享/团队空的时候各自说人话', (tester) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {'items': const [], 'total': 0};
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(api)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DriveMorePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 切段走分页容器（懒构建）：多给一帧让该段的请求落地
      await tester.tap(find.text('星标'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('还没有星标文件'), findsOneWidget);

      await tester.tap(find.text('共享给我'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('没有人共享给你'), findsOneWidget);

      await tester.tap(find.text('团队文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('没有团队文件夹'), findsOneWidget);
    });
  });

  group('版本历史 / 共享 / 标签（P3 尾巴：形状全部来自真机探针）', () {
    test('Revisions/list：path=id:<id> + v1，条目字段解析', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {
        'items': [
          {
            'version_id': 65,
            'size': 2048,
            'created_time': 1789775511,
            'modified_time': 1789775507,
            'hash': 'abc',
            'editor_display_name': 'demo_user',
          },
          {
            'version_id': 64,
            'size': 1024,
            'created_time': 1789775506,
            'modified_time': 1789775501,
            'hash': 'def',
            'editor_display_name': '#1029',
          },
        ],
        'total': 2,
      };
      final api = await _loggedIn(t);
      final revs = await DriveApi(api).listRevisions(fileId: '9');
      expect(t.calls.last['method'], 'list');
      expect(t.calls.last['api'], 'SYNO.SynologyDrive.Revisions');
      expect(t.calls.last['version'], '1');
      expect(t.calls.last['path'], 'id:9');
      expect(revs, hasLength(2));
      expect(revs.first.versionId, '65');
      expect(revs.first.humanSize, '2.0 KB');
      expect(revs.first.editorLabel, 'demo_user');
      // `#` 开头的 uid → 官方 Web 端显示"已删除用户"
      expect(revs.last.editorLabel, '已删除用户');
      expect(revs.first.isCurrent('65'), isTrue);
      expect(revs.last.isCurrent('65'), isFalse);
    });

    test('Revisions/restore：对象数组 + conflict_action（真机 114 的坑）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {'async_task_id': 'task-40'};
      final api = await _loggedIn(t);
      final id = await DriveApi(
        api,
      ).restoreRevision(fileId: '9', versionId: '64');
      expect(id, 'task-40');
      expect(t.calls.last['method'], 'restore');
      expect(t.calls.last['version'], '1');
      expect(t.calls.last['files'], '[{"path":"id:9","version_id":64}]');
      expect(t.calls.last['conflict_action'], 'version');
    });

    test('Revisions/download：直链带 files=[{path,version_id}]', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      final api = await _loggedIn(t);
      final url = DriveApi(
        api,
      ).revisionDownloadUrl(fileId: '9', versionId: '64');
      expect(url, contains('method=download'));
      expect(url, contains('Revisions'));
      expect(
        Uri.parse(url).queryParameters['files'],
        '[{"path":"id:9","version_id":64}]',
      );
    });

    test('Sharing：list / create_link / update（邀请+移除）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) {
        if (params['method'] == 'list') {
          return {
            'items': [
              {
                'permission_id': 1,
                'name': 'demo_user',
                'type': 'user',
                'role': 'viewer',
                'inherited': false,
              },
            ],
            'total': 1,
          };
        }
        if (params['method'] == 'create_link') {
          return {'url': 'https://nas/d/f/abc'};
        }
        return {'success': true};
      };
      final api = await _loggedIn(t);
      final drive = DriveApi(api);

      final shares = await drive.listShares(fileId: '9');
      expect(t.calls.last['path'], 'id:9');
      expect(t.calls.last['version'], '1');
      expect(shares.single.name, 'demo_user');
      expect(shares.single.role, DriveShareRole.viewer);
      expect(shares.single.isGroup, isFalse);

      expect(await drive.createShareLink(fileId: '9'), 'https://nas/d/f/abc');
      expect(t.calls.last['method'], 'create_link');

      await drive.updateShares(
        fileId: '9',
        changes: [
          const DriveShareChange.invite(
            name: 'demo_user',
            type: 'user',
            role: DriveShareRole.viewer,
          ),
        ],
      );
      expect(
        t.calls.last['permissions'],
        '[{"action":"update","member":{"type":"user","name":"demo_user"},"role":"viewer"}]',
      );
      await drive.updateShares(
        fileId: '9',
        changes: [const DriveShareChange.remove(name: 'demo_user', type: 'user')],
      );
      expect(
        t.calls.last['permissions'],
        '[{"action":"delete","member":{"type":"user","name":"demo_user"}}]',
      );
    });

    test('Share.Priv/list：搜成员（query + additional + filter）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {
        'list': [
          {'id': 1027, 'name': 'demo_user', 'nickname': 'demo', 'type': 'user'},
          {'id': 101, 'name': 'administrators', 'type': 'group'},
        ],
        'offset': 0,
        'total': 2,
      };
      final api = await _loggedIn(t);
      final found = await DriveApi(api).searchPrincipals(query: 'fig');
      expect(found, hasLength(2));
      expect(found.first.name, 'demo_user');
      expect(found.first.nickname, 'demo');
      expect(found.last.type, 'group');
      expect(t.calls.last['api'], 'SYNO.SynologyDrive.Share.Priv');
      expect(t.calls.last['query'], 'fig');
      expect(t.calls.last['additional'], '["nickname"]');
    });

    test('Labels：list / create / update / delete 的引号串编码', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) {
        if (params['method'] == 'list') {
          return {
            'items': [
              {
                'label_id': 3,
                'name': '重要',
                'color': '#ff8800',
                'position': 0,
                'type': 'personal_label',
              },
            ],
            'total': 1,
          };
        }
        if (params['method'] == 'create') {
          return {
            'label_id': 4,
            'name': '项目',
            'color': '#000000',
            'position': 1,
            'type': 'personal_label',
          };
        }
        if (params['method'] == 'update') {
          return {
            'label_id': 4,
            'name': '项目A',
            'color': '#00ff00',
            'position': 1,
            'type': 'personal_label',
          };
        }
        return {'success': true};
      };
      final api = await _loggedIn(t);
      final drive = DriveApi(api);

      final labels = await drive.listLabels();
      expect(t.calls.last['api'], 'SYNO.SynologyDrive.Labels');
      expect(t.calls.last['version'], '1');
      expect(labels.single.name, '重要');
      expect(labels.single.colorValue, 0xFFff8800);
      expect(labels.single.isShared, isFalse);

      final created = await drive.createLabel('项目');
      expect(t.calls.last['name'], '"项目"');
      expect(created.labelId, '4');

      await drive.updateLabel(labelId: '4', name: '项目A', color: '#00ff00');
      expect(t.calls.last['label_id'], '"4"');
      expect(t.calls.last['name'], '"项目A"');

      await drive.deleteLabel('4');
      expect(t.calls.last['method'], 'delete');
      expect(t.calls.last['label_id'], '"4"');
    });

    test('Files/list_labelled：label_id 必须引号串', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) => {
        'items': [
          {'file_id': '9', 'name': 'a.txt', 'type': 'file', 'size': 10},
        ],
        'total': 1,
      };
      final api = await _loggedIn(t);
      final r = await DriveApi(api).listLabelled(labelId: '3');
      expect(t.calls.last['method'], 'list_labelled');
      expect(t.calls.last['version'], '2');
      expect(t.calls.last['label_id'], '"3"');
      expect(r.total, 1);
      expect(r.items.single.name, 'a.txt');
    });
  });

  group('缩略图 / 下载直链（服务端直接回字节）', () {
    test('thumbnailUrl / downloadUrl 带 api/method/version/_sid', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      final api = await _loggedIn(t);
      final drive = DriveApi(api);

      final thumb = drive.thumbnailUrl(fileId: '9', size: 'medium');
      expect(thumb, contains('api=SYNO.SynologyDrive.Files'));
      expect(thumb, contains('method=get_thumbnail'));
      expect(thumb, contains('path=id%3A9'));
      expect(thumb, contains('size=medium'));
      expect(thumb, contains('_sid='));

      final dl = drive.downloadUrl(fileId: '9');
      expect(dl, contains('method=download'));
      // files 是 JSON 数组字符串，URL 编码后是 %5B%22id%3A9%22%5D
      expect(dl, contains('files=%5B%22id%3A9%22%5D'));
      expect(dl, contains('force_download=true'));
      expect(dl, contains('_sid='));
    });
  });

  group('条目模型', () {
    test('列表回包是 {items,total}，字段容错 + 人类可读大小', () {
      final parsed = DriveEntryDto.listFromJson({
        'items': [
          _item(
            id: '9',
            name: 'a.txt',
            type: 'file',
            path: '/a.txt',
            size: 1536,
          ),
          {'file_id': 10, 'name': 'dir', 'type': 'dir', 'size': 0},
        ],
        'total': '2',
      });
      expect(parsed.total, 2);
      expect(parsed.items.first.humanSize, '1.5 KB');
      expect(parsed.items.first.extension, 'txt');
      expect(parsed.items[1].fileId, '10', reason: '数字型 file_id 也要能读');
      expect(parsed.items[1].displayPath, '', reason: '缺字段一律容错');
    });
  });

  group('Drive 文件的预览（同一套预览页 + 直链字节）', () {
    testWidgets('预览页用 bytesUrl 取字节（不是 FileStation 的 path）', (tester) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.downloadBytes = _png;
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(api)),
          // 预览页取字节时需要 api（真机上有连接，单测里得显式给）
          fileApiProvider.overrideWithValue(FileStationApi(api)),
        ],
      );
      final entry = DriveEntryDto.fromJson(
        _item(
          id: '9',
          name: 'a.png',
          type: 'file',
          path: '/a.png',
          content: 'image',
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: FilePreviewPage(
              entry: driveEntryAsFile(entry),
              bytesUrl:
                  'https://nas/webapi/entry.cgi?method=download&files=id%3A9',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        t.downloads.single,
        contains('method=download'),
        reason: 'Drive 文件必须走 Files/download 直链',
      );
      expect(t.downloads.single, isNot(contains('FileStation')));
      expect(find.byType(Image), findsWidgets);
    });
  });

  group('Drive 源页面', () {
    Future<({FakeTransport t, ProviderContainer c})> pump(
      WidgetTester tester, {
      required Map<String, Map<String, dynamic>> byPath,
      int failures = 0,
    }) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._driveTable,
      });
      t.onCall = (params) {
        final path = '${params['path']}';
        if (byPath.containsKey(path)) {
          return {...byPath[path]!, 'success': true};
        }
        return {'items': const [], 'total': 0, 'success': true};
      };
      if (failures > 0) {
        t.failures['SYNO.SynologyDrive.Files.list'] = failures;
      }
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(api)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: DriveBrowseView())),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      return (t: t, c: c);
    }

    testWidgets('列目录 + 点进子目录 + 面包屑回退', (tester) async {
      final boot = await pump(
        tester,
        byPath: {
          '/mydrive': {
            'items': [
              _item(
                id: '1',
                name: 'drive-probe',
                type: 'dir',
                path: '/drive-probe',
              ),
              _item(
                id: '2',
                name: 'readme.md',
                type: 'file',
                path: '/readme.md',
                content: 'text',
              ),
            ],
            'total': 2,
          },
          '/mydrive/drive-probe': {
            'items': [
              _item(
                id: '3',
                name: 'probe-pic.png',
                type: 'file',
                path: '/drive-probe/probe-pic.png',
                content: 'image',
              ),
            ],
            'total': 1,
          },
        },
      );
      expect(find.text('drive-probe'), findsOneWidget);
      expect(find.text('readme.md'), findsOneWidget);

      await tester.tap(find.text('drive-probe'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('probe-pic.png'), findsOneWidget);
      // 目录栈压入了子目录（面包屑在浏览页里，由 file_browse_page 渲染）
      expect(boot.c.read(driveStackProvider), [
        kDriveRoot,
        '/mydrive/drive-probe',
      ]);

      // 面包屑回退到根（等同于点第一段）
      boot.c.read(driveStackProvider.notifier).popTo(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('readme.md'), findsOneWidget);
      expect(boot.c.read(driveStackProvider), [kDriveRoot]);
    });

    testWidgets('空目录 → 说人话（区分根目录与子目录）', (tester) async {
      await pump(tester, byPath: const {});
      expect(find.text('这个目录是空的'), findsOneWidget);
      expect(find.textContaining('个人空间（/mydrive）里还没有文件'), findsOneWidget);
    });

    testWidgets('接口失败 → 错误态 + 可重试（不白屏）', (tester) async {
      await pump(tester, byPath: const {}, failures: 500);
      expect(find.text('打不开这个目录'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });
  // §11 第 ⑧ 项（Office L2）：Drive 行菜单里的「下载为 …」与「转换为 Office 文档」。
  // 只看两件事：菜单项在对的文件上出现、点下去发的请求形状对（参数细节由
  // `office_export_test.dart` 的接口层用例逐个钉）。
  group('Drive 行菜单 · Office L2', () {
    Future<({FakeTransport t, ProviderContainer c})> pump(
      WidgetTester tester, {
      required Map<String, Map<String, dynamic>> byPath,
    }) async {
      final t = FakeTransport({}, {
        ...FakeTransport.table,
        ..._driveTable,
        // Office L2 的两个接口（`_driveTable` 里没有，缺了会回 102/103）
        'SYNO.Office.Import': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
        'SYNO.Office.Export': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      t.onCall = (params) {
        final path = '${params['path']}';
        if (byPath.containsKey(path)) {
          return {...byPath[path]!, 'success': true};
        }
        return {'errors': const <dynamic>[], 'success': true};
      };
      t.bytesByUrl['SYNO.Office.Export'] = utf8.encode('%PDF-1.7 fake');
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final dir = Directory.systemTemp.createTempSync('drive_office_menu');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          driveApiProvider.overrideWithValue(DriveApi(api)),
          officeApiProvider.overrideWithValue(OfficeApi(api)),
          officeDownloadDirProvider.overrideWithValue(() async => dir),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: DriveBrowseView())),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      return (t: t, c: c);
    }

    testWidgets('原生文档：菜单只给服务端真能产出的两种格式，点"Office 文件"发 Export/download', (
      tester,
    ) async {
      final boot = await pump(
        tester,
        byPath: {
          '/mydrive': {
            'items': [
              _item(id: '9', name: '报告.odoc', type: 'file', path: '/报告.odoc'),
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('下载为 Office 文件'), findsOneWidget);
      expect(find.text('下载为 OpenDocument'), findsOneWidget);
      // 服务端不产出 PDF（会回落成 ODF）→ 不给这一项
      expect(find.text('下载为 PDF'), findsNothing);
      // 原生文档不给"转换为 Office 文档"（它已经是原生格式了）
      expect(find.text('转换为 Office 文档'), findsNothing);

      await tester.tap(find.text('下载为 Office 文件'));
      // 落盘是真实文件 I/O：`flutter_test` 的假时钟不推进它。以"toast 出现"为
      // 终止条件做**有界条件等待**（交替推进假时钟与真实时间，条件达成即返回；
      // 上限只防死等，不参与判定）。⚠️ 不要退回固定延时窗口：负载下会 flake
      // （本文件 08:46 全量就红在这里）。
      await _settleUntil(
        tester,
        () => find.text('已导出：报告.docx').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.text('已导出：报告.docx'), findsOneWidget);
      expect(boot.t.downloads, isEmpty);
      // 真机唯一验过的 Export/download 形状：path=id:<file_id> + **目标扩展名**
      // （`.odoc` → `docx`；`ms` 只是官方前端档位名，不是服务端参数值）
      expect(boot.t.postDownloads.single, contains('format=docx'));
      expect(boot.t.postDownloads.single, isNot(contains('format=ms')));
      expect(boot.t.postDownloads.single, contains('path=id:9'));
      expect(boot.t.postDownloads.single, isNot(contains('object_id')));
    });

    testWidgets('上传文档：菜单给"转换为 Office 文档"，点下去发 check + convert', (tester) async {
      final boot = await pump(
        tester,
        byPath: {
          '/mydrive': {
            'items': [
              _item(id: '9', name: '报告.docx', type: 'file', path: '/报告.docx'),
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('转换为 Office 文档'), findsOneWidget);
      expect(find.text('下载为 PDF'), findsNothing);

      await tester.tap(find.text('转换为 Office 文档'));
      // 同上：以目标 toast 出现为终止条件的有界条件等待，不用固定延时窗口。
      await _settleUntil(
        tester,
        () => find.text('已转换为 报告.odoc（稍后出现在列表里）').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.text('已转换为 报告.odoc（稍后出现在列表里）'), findsOneWidget);
      final check = boot.t.calls.firstWhere((e) => e['method'] == 'check');
      expect(check['files'], '[{"path":"id:9"}]');
      final convert = boot.t.calls.firstWhere((e) => e['method'] == 'convert');
      expect(convert['conflict_action'], 'autorename');
      // 目标是文件自己所在目录（`_item` 里 parent_id=900）
      expect(convert['to_parent_folder'], 'id:900');
    });

    testWidgets('表格多一个 CSV；普通文件不给 Office 菜单项', (tester) async {
      await pump(
        tester,
        byPath: {
          '/mydrive': {
            'items': [
              _item(
                id: '8',
                name: '预算.osheet',
                type: 'file',
                path: '/预算.osheet',
              ),
              _item(
                id: '7',
                name: '照片.jpg',
                type: 'file',
                path: '/照片.jpg',
                content: 'image',
              ),
            ],
            'total': 2,
          },
        },
      );
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('预算.osheet'),
            matching: find.byType(DesignRowTile),
          ),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('下载为 OpenDocument'), findsOneWidget);

      // 关掉再开普通文件那条
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('照片.jpg'),
            matching: find.byType(DesignRowTile),
          ),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('下载为'), findsNothing);
      expect(find.text('转换为 Office 文档'), findsNothing);
      // 普通文件该有的动作还在
      expect(find.text('版本历史'), findsOneWidget);
    });
  });
}
