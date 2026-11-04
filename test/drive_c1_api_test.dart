// C1（Drive 补齐）协议层测试：回收站恢复/永久删除、AdvanceSharing、
// FileRequest、Notifications、Files.lock/request_unlock、TeamFolders 成员。
//
// 每条断言都能对回**原文证据**（文件 + 位置写在 docs 实施记录与
// `drive_api.dart` 的注释里）：
//   * `/tmp/spk/out/SynologyDrive.apis.txt` 的方法表（模块 + 版本）；
//   * 官方 `drive/synodrive_common.js` 的 `WebAPIDesc` / `copyTo(...)` 参数表；
//   * 官方 `drive/drive_bundle.js` 的 Vue 调用参数；
//   * 本仓库真机实测（`Files.delete`：进回收站只发 `files`；清回收站条目发
//     `permanent:true` —— `permanent_delete` 服务端不认）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/dto/drive_file_request_dto.dart';
import 'package:synhub/src/data/dto/drive_share_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

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

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 一次调用就够的假服务器：记录所有请求，回包里补 `success:true`
FakeTransport _transport(Map<String, Map<String, dynamic>> responses) {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._c1Table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  return t;
}

void main() {
  group('回收站（C1）：恢复 / 永久删除 / 条目字段', () {
    test(
      'restoreTrash → Revisions/restore v1 + files/conflict_action',
      () async {
        final t = _transport({
          'SYNO.SynologyDrive.Revisions.restore': {'async_task_id': 'task-7'},
        });
        final api = await _loggedIn(t);
        final task = await DriveApi(api).restoreTrash(fileIds: ['9']);
        final call = t.calls.last;
        expect(call['api'], 'SYNO.SynologyDrive.Revisions');
        expect(call['method'], 'restore');
        expect(call['version'], '1');
        // 官方 WebAPI.restoreNode 的 copyTo 白名单：files, conflict_action,
        // to_parent_folder（synodrive_common.js:571465）
        expect(call['files'], '[{"path":"id:9"}]');
        expect(call['conflict_action'], 'autorename');
        expect(call.containsKey('to_parent_folder'), isFalse);
        expect(task, 'task-7');
      },
    );

    test('restoreTrash 指定 to_parent_folder 时按 path id 回传', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Revisions.restore': {'async_task_id': 't'},
      });
      final api = await _loggedIn(t);
      await DriveApi(api).restoreTrash(fileIds: ['9'], toParentFolder: 'id:3');
      expect(t.calls.last['to_parent_folder'], 'id:3');
    });

    test('永久删除（回收站条目）→ Files/delete v2 + `permanent:true`（真机参数）', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Files.delete': {'async_task_id': 'task-8'},
      });
      final api = await _loggedIn(t);
      await DriveApi(api).deleteFromTrash(trashFileIds: ['9']);
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.Files');
      expect(call['method'], 'delete');
      expect(call['version'], '2');
      expect(call['files'], '["id:9"]');
      // ⚠️ 真机 A/B 对照（docs/live-write-verification.md §7）：
      //   对**回收站条目**发 `permanent:true` → 从回收站永久消失 ✅
      //   `permanent_delete:true` → 服务端**不识别**（包内也没这个串）
      expect(call['permanent'], isTrue);
      expect(call.containsKey('permanent_delete'), isFalse);
    });

    test('Trash/list 解析 recycled_time 与 display_path', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Trash.list': {
          'items': [
            {
              'file_id': '9',
              'name': 'probe-note.txt',
              'type': 'file',
              'path': '/recycle-bin/mydrive/probe-note.txt',
              'display_path': '/mydrive/probe-note.txt',
              'recycled_time': 1789775507,
              'size': 2048,
            },
          ],
          'total': 1,
        },
      });
      final api = await _loggedIn(t);
      final trash = await DriveApi(api).listTrash();
      final entry = trash.items.single;
      expect(entry.recycledTime, 1789775507);
      expect(entry.displayPath, '/mydrive/probe-note.txt');
      expect(entry.humanSize, '2.0 KB');
    });
  });

  group('高级共享（AdvanceSharing）', () {
    test('get → AdvanceSharing/get v1，参数只有 path', () async {
      final t = _transport({
        'SYNO.SynologyDrive.AdvanceSharing.get': {
          'sharing_link': 'abc123',
          'url': 'https://nas/d/s/abc123',
          'role': 'previewer',
          'protect_password': 'pw',
          'due_date': 1789775507,
        },
      });
      final api = await _loggedIn(t);
      final info = await DriveApi(api).getAdvanceSharing(path: 'id:9');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.AdvanceSharing');
      expect(call['method'], 'get');
      expect(call['version'], '1');
      expect(call['path'], 'id:9');
      expect(info.sharingLink, 'abc123');
      expect(info.hasPassword, isTrue);
      expect(info.hasExpiry, isTrue);
      // 官方把 previewer 归一回 viewer（并关掉"允许下载"）
      expect(info.normalizedRole, DriveShareRole.viewer);
    });

    test('create → 参数 {path}', () async {
      final t = _transport({
        'SYNO.SynologyDrive.AdvanceSharing.create': {
          'sharing_link': 'new',
          'url': 'https://nas/d/s/new',
          'role': 'viewer',
          'due_date': 0,
        },
      });
      final api = await _loggedIn(t);
      final info = await DriveApi(api).createAdvanceSharing(path: 'id:9');
      final call = t.calls.last;
      expect(call['method'], 'create');
      expect(call['path'], 'id:9');
      expect(info.url, 'https://nas/d/s/new');
      expect(info.hasExpiry, isFalse);
    });

    // ★ 第 59 轮订正：这条用例原先叫「…（**密码保护不实现**）」，
    // 断言 `protect_password` **不发** —— 它固化了我的**错误假设**
    // （以为官方对该字段挂了 encryption）。三条证据否掉了那个假设
    // （APK 裸 putParam / 服务端 .lib 里 encryption 出现 0 次 /
    //   服务端二进制把它当 DB 列），所以改为断言**官方真实行为**。
    // 这是「**修正错误假设**」，不是"改测试迁就代码"。
    test('update → 官方五个参数（含 protect_password 明文）', () async {
      final t = _transport(const {});
      final api = await _loggedIn(t);
      await DriveApi(api).updateAdvanceSharing(
        path: 'id:9',
        sharingLink: 'abc123',
        role: DriveShareRole.commenter,
        dueDate: 1800000000,
        protectPassword: 'pw',
      );
      final call = t.calls.last;
      expect(call['method'], 'update');
      expect(call['path'], 'id:9');
      expect(call['sharing_link'], 'abc123');
      expect(call['role'], 'commenter');
      expect(call['due_date'], 1800000000);
      expect(
        call['protect_password'],
        'pw',
        reason: '★ 官方就是**明文**发这个字段（HTTPS 保护），不是加密后的串',
      );
      expect(
        call.containsKey('cipherkey'),
        isFalse,
        reason: '★ 不加密 —— 加密了服务端会把密文当密码存进 DB',
      );
    });

    test('★★ `update` 是**全量覆盖**：不传 dueDate/密码 ⇒ 发 0 / 空串', () async {
      final t = _transport(const {});
      final api = await _loggedIn(t);
      await DriveApi(
        api,
      ).updateAdvanceSharing(path: 'id:9', sharingLink: 'abc123');
      final call = t.calls.last;
      expect(
        call['due_date'],
        0,
        reason:
            '★ 官方 `dueDate != null ? …/1000 : 0L` ——'
            '"不传"就是"清掉有效期"，不是"保持不变"',
      );
      expect(call['protect_password'], '', reason: '★ 同理：不传 = 清掉密码');
    });

    test('delete → {path, sharing_link}', () async {
      final t = _transport(const {});
      final api = await _loggedIn(t);
      await DriveApi(
        api,
      ).deleteAdvanceSharing(path: 'id:9', sharingLink: 'abc123');
      final call = t.calls.last;
      expect(call['method'], 'delete');
      expect(call['path'], 'id:9');
      expect(call['sharing_link'], 'abc123');
    });
  });

  group('请求文件（FileRequest）', () {
    test('list → v1 + offset/limit（status 可选）', () async {
      final t = _transport({
        'SYNO.SynologyDrive.FileRequest.list': {
          'items': [
            {
              'file_id': '9',
              'title': '交作业',
              'destination_folder': '/mydrive/homework',
              'sharing_link': 'fr1',
              'permanent_link': 'perm1',
              'file_request_status': 'active',
              'is_expired': false,
              'created_time': 1789775507,
            },
          ],
          'total': 1,
        },
      });
      final api = await _loggedIn(t);
      final page = await DriveApi(api).listFileRequests(status: 'active');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.FileRequest');
      expect(call['method'], 'list');
      expect(call['version'], '1');
      expect(call['offset'], 0);
      expect(call['limit'], 200);
      expect(call['status'], 'active');
      expect(page.total, 1);
      expect(page.items.single.title, '交作业');
      expect(page.items.single.isActive, isTrue);
    });

    test('create → title/identifier/description/protect_password/due_date/'
        'has_due_date_hour + path=id:<folder>', () async {
      final t = _transport({
        'SYNO.SynologyDrive.FileRequest.create': {
          'title': '交作业',
          'sharing_link': 'fr1',
          'url': 'https://nas/f/fr1',
        },
      });
      final api = await _loggedIn(t);
      final created = await DriveApi(api).createFileRequest(
        folderId: '3',
        title: '交作业',
        description: '请上传 PDF',
        identifier: 'name',
        dueDate: 1800000000,
        hasDueDateHour: true,
      );
      final call = t.calls.last;
      expect(call['method'], 'create');
      expect(call['title'], '交作业');
      expect(call['identifier'], 'name');
      expect(call['description'], '请上传 PDF');
      expect(call['protect_password'], '');
      expect(call['due_date'], 1800000000);
      expect(call['has_due_date_hour'], isTrue);
      expect(call['path'], 'id:3');
      expect(created.url, 'https://nas/f/fr1');
    });

    test(
      'update → 加 sharing_link + path=link:<permanent_link> + 关闭状态',
      () async {
        final t = _transport({
          'SYNO.SynologyDrive.FileRequest.update': {'title': '交作业'},
        });
        final api = await _loggedIn(t);
        await DriveApi(api).updateFileRequest(
          sharingLink: 'fr1',
          path: 'link:perm1',
          title: '交作业',
          fileRequestStatus: 'inactive',
        );
        final call = t.calls.last;
        expect(call['method'], 'update');
        expect(call['sharing_link'], 'fr1');
        expect(call['path'], 'link:perm1');
        expect(call['file_request_status'], 'inactive');
      },
    );

    test('delete → 只带 sharing_link', () async {
      final t = _transport(const {});
      final api = await _loggedIn(t);
      await DriveApi(api).deleteFileRequest(sharingLink: 'fr1');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.FileRequest');
      expect(call['method'], 'delete');
      expect(call['sharing_link'], 'fr1');
    });

    test('过期 / error / readonly / inactive 都不算 active', () {
      const base = {'title': 'x', 'sharing_link': 's'};
      for (final status in ['error', 'readonly', 'inactive']) {
        final dto = DriveFileRequestDto.fromJson({
          ...base,
          'file_request_status': status,
        });
        expect(dto.isActive, isFalse, reason: status);
      }
      final active = DriveFileRequestDto.fromJson({
        ...base,
        'file_request_status': 'active',
      });
      expect(active.isActive, isTrue);
      final expired = DriveFileRequestDto.fromJson({
        ...base,
        'file_request_status': 'active',
        'is_expired': true,
      });
      expect(expired.isActive, isFalse);
    });
  });

  group('通知（Notifications）', () {
    test('list → v1 + {limit:100}，解析 items', () async {
      final t = _transport({
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
      });
      final api = await _loggedIn(t);
      final items = await DriveApi(api).listNotifications();
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.Notifications');
      expect(call['method'], 'list');
      expect(call['version'], '1');
      expect(call['limit'], 100);
      expect(items.single.notificationId, 'n1');
      expect(items.single.typeLabel, 'upload');
    });

    test('create → {content,type}（content 是 JSON 串）', () async {
      final t = _transport(const {});
      final api = await _loggedIn(t);
      await DriveApi(api).createNotification(
        content: const {
          'action': 'upload',
          'names': ['a.txt'],
        },
        type: 'drive#upload_task',
      );
      final call = t.calls.last;
      expect(call['method'], 'create');
      expect(call['type'], 'drive#upload_task');
      expect(call['content'], '{"action":"upload","names":["a.txt"]}');
    });

    test('delete（清空全部）→ 官方传空参数', () async {
      final t = _transport(const {});
      final api = await _loggedIn(t);
      await DriveApi(api).clearNotifications();
      final call = t.calls.last;
      expect(call['method'], 'delete');
      // 只剩 api/version/method/_sid 四个框架字段 = 没有业务参数
      expect(
        call.keys.where(
          (k) => !const ['api', 'version', 'method', '_sid'].contains(k),
        ),
        isEmpty,
      );
    });
  });

  group('文件锁（Files.lock / request_unlock）', () {
    test('加锁 → Files/lock v2 + {files, perform_lock:true}', () async {
      final t = _transport(const {});
      final api = await _loggedIn(t);
      await DriveApi(api).setNodeLock(fileIds: ['9'], lock: true);
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.Files');
      expect(call['method'], 'lock');
      expect(call['version'], '2');
      expect(call['files'], '["id:9"]');
      expect(call['perform_lock'], isTrue);
    });

    test('解锁 → 同一个接口 perform_lock:false', () async {
      final t = _transport(const {});
      final api = await _loggedIn(t);
      await DriveApi(api).setNodeLock(fileIds: ['9'], lock: false);
      expect(t.calls.last['perform_lock'], isFalse);
    });

    test('请求解锁 → Files/request_unlock v2 + {path}', () async {
      final t = _transport(const {});
      final api = await _loggedIn(t);
      await DriveApi(api).requestNodeUnlock(path: 'id:9');
      final call = t.calls.last;
      expect(call['method'], 'request_unlock');
      expect(call['version'], '2');
      expect(call['path'], 'id:9');
    });

    test('条目解析 node_locking / capabilities.can_lock', () {
      final entry = DriveEntryDto.fromJson({
        'file_id': '9',
        'name': 'a.txt',
        'type': 'file',
        'capabilities': {'can_write': true, 'can_lock': true},
        'node_locking': {
          'is_locked': true,
          'lock_user': {'name': 'demo_user', 'display_name': 'K'},
        },
      });
      expect(entry.canLock, isTrue);
      expect(entry.isLocked, isTrue);
      expect(entry.lockUserName, 'demo_user');
      expect(entry.lockUserDisplayName, 'K');
      final free = DriveEntryDto.fromJson({
        'file_id': '10',
        'name': 'b.txt',
        'type': 'file',
      });
      // 服务端没给 can_lock 时按官方语义 fail-open
      expect(free.canLock, isTrue);
      expect(free.isLocked, isFalse);
    });
  });

  group('团队文件夹成员（TeamFolders/list_members）', () {
    test('→ v1 + {team_id, offset, limit}，解析 display_name/role', () async {
      final t = _transport({
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
      });
      final api = await _loggedIn(t);
      final members = await DriveApi(api).listTeamFolderMembers(teamId: '77');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.TeamFolders');
      expect(call['method'], 'list_members');
      expect(call['version'], '1');
      expect(call['team_id'], '77');
      expect(call['offset'], 0);
      expect(call['limit'], 100);
      expect(members.single.label, 'K');
      expect(members.single.role, 'organizer');
    });
  });
}
