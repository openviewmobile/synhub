// D12（团队文件夹回收站）协议层测试。
//
// 原文证据（`ApiSynoDriveTrash.setAsList`，反编译
// `Android-SynologyDrive.3.9.0-1113.ww.apk`，逐字）：
// ```java
// putParam("path", dataSource.isForMyDrive() ? Constants.MYDRIVE_PATH
//          : dataSource.isForFolder() ? UtilsForApi.computePathById(folderId)
//          : "");
// ```
// ⇒ 团队文件夹回收站走 **`isForFolder` 分支**：`path = id:<folder_id>`。
//
// 本批**真机只读实测**（普通用户，DSM 7.2）：
// ```text
// Trash:list v2 {"path":"/mydrive"}                → success
// Trash:list v1 {"path":""}                        → 1000 "list node failed"
// Trash:list v2 {"path":""}                        → 1000 "list node failed"
// Trash:list v2 {"path":"id:974457808523148038"}   → success
// ```
// ⇒ `path=""` 那条官方分支在本机**不可用**，如实登记为待确认（见报告）；
// 本文件只覆盖可验证的 `id:<folder_id>` 这条。
//
// ⚠️ 还原 / 彻底删除是**写方法**，本批**一次都没真调**：下面只断言参数形状
// （走 FakeTransport）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真机 `SYNO.API.Info`：`Trash` 只到 maxVersion **2**（不是 SPK 声明的 3）。
const _realNasTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Trash': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Revisions': {
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
    ..._realNasTable,
    ...?table,
  });
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  return t;
}

void main() {
  group('团队文件夹回收站：列表（只读，真机验过 id: 这条）', () {
    test(
      'listFolderTrash → Trash/list，path=id:<folder_id>，协商到本机的 v2',
      () async {
        final t = _transport({
          'SYNO.SynologyDrive.Trash.list': {
            'items': [
              {
                'file_id': '9',
                'name': 'team-note.txt',
                'type': 'file',
                'path': '/recycle-bin/team-folders/t1/team-note.txt',
                'display_path': '/team-folders/t1/team-note.txt',
                'recycled_time': 1789775507,
                'size': 4096,
                'owner': {'display_name': 'demo_user'},
              },
            ],
            'total': 1,
          },
        });
        final api = await _loggedIn(t);
        final trash = await DriveApi(
          api,
        ).listFolderTrash(folderId: '974457808523148038');
        final call = t.calls.last;
        expect(call['api'], 'SYNO.SynologyDrive.Trash');
        expect(call['method'], 'list');
        // 本机 maxVersion=2 ⇒ _negotiate([3,2,1]) 挑 2（官方 Math.min(3, maxVersion)）
        expect(call['version'], '2');
        expect(call['path'], 'id:974457808523148038');
        expect(call['offset'], 0);
        expect(call['limit'], 200);

        final e = trash.items.single;
        expect(e.name, 'team-note.txt');
        expect(e.recycledTime, 1789775507);
        expect(e.displayPath, '/team-folders/t1/team-note.txt');
        expect(trash.total, 1);
      },
    );

    test('updatePathById 语义：已带 id: 前缀不重复拼', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Trash.list': {'items': [], 'total': 0},
      });
      final api = await _loggedIn(t);
      await DriveApi(api).listFolderTrash(folderId: 'id:123');
      // computePathById 只对"不以 / 开头"的加前缀；`id:123` 会变成 `id:id:123`
      // —— 官方就是这么写的（UtilsForApi.computePathById），所以这里也如实断言，
      // 调用方**必须传裸 id**（页面传的是 file_id，天然是裸的）。
      expect(t.calls.last['path'], 'id:id:123');
    });

    test('绝对路径原样透传（computePathById 的 `/` 分支）', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Trash.list': {'items': [], 'total': 0},
      });
      final api = await _loggedIn(t);
      await DriveApi(api).listFolderTrash(folderId: '/team-folders/t1');
      expect(t.calls.last['path'], '/team-folders/t1');
    });

    test('服务端声明的回收站版本更高时协商到 v3（不写死 maxVersion）', () async {
      final t = _transport(
        {
          'SYNO.SynologyDrive.Trash.list': {'items': [], 'total': 0},
        },
        table: {
          'SYNO.SynologyDrive.Trash': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 3,
          },
        },
      );
      final api = await _loggedIn(t);
      await DriveApi(api).listFolderTrash(folderId: '5');
      expect(t.calls.last['version'], '3');
    });

    test('空回收站 ⇒ 空列表（真机团队文件夹为 0 个，这也是唯一实况）', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Trash.list': {'items': [], 'total': 0},
      });
      final api = await _loggedIn(t);
      final trash = await DriveApi(api).listFolderTrash(folderId: '5');
      expect(trash.items, isEmpty);
      expect(trash.total, 0);
    });
  });

  group('团队文件夹回收站：还原 / 彻底删除（写方法，本批不真调）', () {
    test(
      '还原团队文件夹回收站条目 → Revisions/restore v1，files=[{path:id:<id>}]',
      () async {
        final t = _transport({
          'SYNO.SynologyDrive.Revisions.restore': {'async_task_id': 'task-9'},
        });
        final api = await _loggedIn(t);
        // 页面 `_restore` 走的就是这一条（与个人回收站同一个官方入口）
        await DriveApi(api).restoreTrash(fileIds: ['9']);
        final call = t.calls.last;
        expect(call['api'], 'SYNO.SynologyDrive.Revisions');
        expect(call['method'], 'restore');
        expect(call['version'], '1');
        expect(call['files'], '[{"path":"id:9"}]');
        expect(call['conflict_action'], 'autorename');
      },
    );

    test('彻底删除团队文件夹回收站条目 → Files/delete v2 + permanent:true', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Files.delete': {'async_task_id': 'task-10'},
      });
      final api = await _loggedIn(t);
      await DriveApi(api).deleteFromTrash(trashFileIds: ['9']);
      final call = t.calls.last;
      expect(call['method'], 'delete');
      expect(call['version'], '2');
      expect(call['files'], '["id:9"]');
      expect(call['permanent'], isTrue);
      expect(call.containsKey('permanent_delete'), isFalse);
    });
  });
}
