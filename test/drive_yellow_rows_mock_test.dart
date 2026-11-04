// ★★★ ③Drive 第 218 轮：**11 个 🟡 行的 Mock Server 复核（🟡→✅）**。
//
// 用户 2026-09-23 新规 B1/B2：真机/真 NAS 无法验证的，一律用**本地 Mock Server**
// 验证。这 11 行的卡点全是"真机未验"（见台账第 218 轮前的状态列），
// 所以本轮把它们**逐行走 Mock**：
//
//   D13 回收站恢复   → `Revisions/restore` + `Files/delete(permanent)`
//   D29 复制/移动     → `Files/copy` / `Files/move`
//   D32 文件锁        → `Files/lock` + `Files/request_unlock`
//   D36 请求访问      → `Files/request_access`
//   D42 文件请求      → `FileRequest/{list,create,update,delete}`
//   D44 通知中心      → `Notifications/{list,create,delete}`
//   D48 文件名搜索    → `Files/search`
//   D50 高级筛选      → `Files/search` 的筛选参数
//   D55 Office 编辑   → `Office.Node.Encrypt/check` + 空白文档 `Files/create`
//   D74/D79 后台备份  → **没有服务端面**（本地 WorkManager + 通知），
//                       用离线用例 + 真机记录取证，不在本文件里假装 Mock。
//
// ⚠️ 本文件**不新增功能**，只把"已实现但未验证"的行按 Mock 权威契约核实；
// 台账同步改判为 ✅并写明"Mock 核实；真机未验"（证据词汇表允许）。
// §5.1：全部打内存 Mock，零真机/真 NAS 调用。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_search_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late MockDsmBackend backend;
  late DsmWebApi web;
  late DriveApi drive;

  Future<void> boot({bool admin = false}) async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'u', admin: admin);
    web = DsmWebApi(MockDsmTransport(backend));
    await web.discover();
    await web.login(account: 'u', password: 'x');
    drive = DriveApi(web);
  }

  Map<String, dynamic> last(String apiName) => backend.requests
      .lastWhere((r) => '${r.params['api']}' == apiName)
      .params;

  /// Mock 的目录是权威表 ⇒ 断言"这个 api/method/version 三元组真的合法"。
  void expectLegal(String api, String method, String version) {
    final entry = DsmCatalog.load().apis[api];
    expect(entry, isNotNull, reason: '$api 必须在权威目录里');
    final versions = entry!.methods;
    expect(
      versions[int.parse(version)],
      contains(method),
      reason: '★ $api v$version 必须含 $method（权威 .lib 表）',
    );
  }

  setUp(() => boot());

  group('第 218 轮 · D13 回收站恢复（Mock 核实）', () {
    test('恢复 → Revisions/restore，回包 id 上屏', () async {
      backend.fixture('SYNO.SynologyDrive.Revisions', 'restore', (p) => {
        'success': true,
        'data': {'async_task_id': '77'},
      });
      final id = await drive.restoreTrash(fileIds: ['12']);
      expect(id, '77');
      final p = last('SYNO.SynologyDrive.Revisions');
      expect('${p['method']}', 'restore');
      expectLegal('SYNO.SynologyDrive.Revisions', 'restore', '${p['version']}');
      expect('${p['files']}', contains('12'));
    });

    test('永久删除 → Files/delete 带 permanent:true', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'delete', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      await drive.deleteFromTrash(trashFileIds: ['12']);
      final p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'delete');
      expect('${p['permanent']}', 'true', reason: '真机参数：永久删除要 permanent');
      expectLegal('SYNO.SynologyDrive.Files', 'delete', '${p['version']}');
    });
  });

  group('第 218 轮 · D29 复制 / 移动（Mock 核实）', () {
    test('复制 → Files/copy；移动 → Files/move（同一 API 层）', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'copy', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      backend.fixture('SYNO.SynologyDrive.Files', 'move', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      await drive.copyOrMove(
        fileIds: ['1'],
        toParentFolderId: '9',
        move: false,
      );
      var p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'copy');
      expectLegal('SYNO.SynologyDrive.Files', 'copy', '${p['version']}');
      expect('${p['to_parent_folder']}', contains('id:9'));

      await drive.copyOrMove(
        fileIds: ['1'],
        toParentFolderId: '9',
        move: true,
      );
      p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'move');
      expectLegal('SYNO.SynologyDrive.Files', 'move', '${p['version']}');
    });
  });

  group('第 218 轮 · D32 文件锁（Mock 核实）', () {
    test('加锁/解锁都是 Files/lock，靠 perform_lock 区分', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'lock', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      await drive.setNodeLock(fileIds: ['1'], lock: true);
      var p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'lock');
      expect('${p['perform_lock']}', 'true');
      expectLegal('SYNO.SynologyDrive.Files', 'lock', '${p['version']}');

      await drive.setNodeLock(fileIds: ['1'], lock: false);
      p = last('SYNO.SynologyDrive.Files');
      expect('${p['perform_lock']}', 'false');
    });

    test('请求解锁 → Files/request_unlock + {path}', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'request_unlock', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      await drive.requestNodeUnlock(path: '/mydrive/锁定.docx');
      final p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'request_unlock');
      expect('${p['path']}', '/mydrive/锁定.docx');
      expectLegal('SYNO.SynologyDrive.Files', 'request_unlock', '${p['version']}');
    });
  });

  group('第 218 轮 · D36 请求访问权限（Mock 核实，补上"写路径未实调"）', () {
    test('request_access 走 v11（Files 的 maxVersion），成功即通过', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'request_access', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      await drive.requestAccess(path: '/mydrive/受限目录');
      final p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'request_access');
      expect('${p['path']}', '/mydrive/受限目录');
      final v = '${p['version']}';
      expect(v, '11', reason: '我方选 v11');
      expectLegal('SYNO.SynologyDrive.Files', 'request_access', v);
    });
  });

  group('第 218 轮 · D42 文件请求（Mock 核实）', () {
    test('list → FileRequest/list', () async {
      backend.fixture('SYNO.SynologyDrive.FileRequest', 'list', (p) => {
        'success': true,
        'data': {'total': 0, 'items': const []},
      });
      final r = await drive.listFileRequests();
      expect(r.items, isEmpty);
      final p = last('SYNO.SynologyDrive.FileRequest');
      expect('${p['method']}', 'list');
      expectLegal('SYNO.SynologyDrive.FileRequest', 'list', '${p['version']}');
    });

    test('create → title/identifier/due_date 全带上', () async {
      backend.fixture('SYNO.SynologyDrive.FileRequest', 'create', (p) => {
        'success': true,
        'data': {'sharing_link': 'https://nas/f/abc'},
      });
      final dto = await drive.createFileRequest(
        folderId: '77',
        title: '交作业',
        identifier: 'hw',
        description: '请上传',
      );
      expect(dto.sharingLink, contains('abc'));
      final p = last('SYNO.SynologyDrive.FileRequest');
      expect('${p['method']}', 'create');
      expect('${p['title']}', '交作业');
      expectLegal('SYNO.SynologyDrive.FileRequest', 'create', '${p['version']}');
    });

    test('update / delete（只带 sharing_link）都通', () async {
      backend.fixture('SYNO.SynologyDrive.FileRequest', 'update', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      backend.fixture('SYNO.SynologyDrive.FileRequest', 'delete', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      await drive.updateFileRequest(
        sharingLink: 'https://nas/f/abc',
        path: 'link:https://nas/f/abc',
        title: '改名',
      );
      var p = last('SYNO.SynologyDrive.FileRequest');
      expect('${p['method']}', 'update');
      expectLegal('SYNO.SynologyDrive.FileRequest', 'update', '${p['version']}');

      await drive.deleteFileRequest(sharingLink: 'https://nas/f/abc');
      p = last('SYNO.SynologyDrive.FileRequest');
      expect('${p['method']}', 'delete');
      expectLegal('SYNO.SynologyDrive.FileRequest', 'delete', '${p['version']}');
    });
  });

  group('第 218 轮 · D44 通知中心（Mock 核实 + 版本疑点当场了结）', () {
    test('★ 权威目录：Notifications 的 delete 在 **v1 也有** ⇒ 我方 v1 合法', () {
      final entry = DsmCatalog.load().apis['SYNO.SynologyDrive.Notifications']!;
      expect(entry.methods[1], contains('delete'));
      expect(entry.methods[2], contains('delete'));
      expect(entry.maxVersion, 2);
    });

    test('list → Notifications/list v1 + limit', () async {
      backend.fixture('SYNO.SynologyDrive.Notifications', 'list', (p) => {
        'success': true,
        'data': {'items': const []},
      });
      final items = await drive.listNotifications();
      expect(items, isEmpty);
      final p = last('SYNO.SynologyDrive.Notifications');
      expect('${p['method']}', 'list');
      expect('${p['limit']}', '100');
      expectLegal('SYNO.SynologyDrive.Notifications', 'list', '${p['version']}');
    });

    test('create / 清空（delete，空参数）都通', () async {
      backend.fixture('SYNO.SynologyDrive.Notifications', 'create', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      backend.fixture('SYNO.SynologyDrive.Notifications', 'delete', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      await drive.createNotification(content: '{"a":1}', type: 'comment');
      var p = last('SYNO.SynologyDrive.Notifications');
      expect('${p['method']}', 'create');
      expectLegal('SYNO.SynologyDrive.Notifications', 'create', '${p['version']}');

      await drive.clearNotifications();
      p = last('SYNO.SynologyDrive.Notifications');
      expect('${p['method']}', 'delete');
      expectLegal('SYNO.SynologyDrive.Notifications', 'delete', '${p['version']}');
    });
  });

  group('第 218 轮 · D48/D50 搜索与高级筛选（Mock 核实）', () {
    test('关键词 → Files/search，空结果不炸', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'search', (p) => {
        'success': true,
        'data': {'total': 0, 'items': const []},
      });
      final r = await drive.search('报告');
      expect(r.items, isEmpty);
      final p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'search');
      expect('${p['keyword']}', '报告');
      expectLegal('SYNO.SynologyDrive.Files', 'search', '${p['version']}');
    });

    test('高级筛选：位置/类型/大小都进 wire（官方取值）', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'search', (p) => {
        'success': true,
        'data': {'total': 1, 'items': const []},
      });
      await drive.search(
        '季度',
        location: DriveSearchLocation.myDrive,
        fileType: DriveSearchFileType.document,
        size: DriveSearchSize.greaterThan,
        sizeMegabytes: 5,
      );
      final p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'search');
      // 官方参数名以 API 层实现为准；这里断言它们**确实发出去了**
      expect(p.keys.any((k) => k == 'location'), isTrue);
      expect(p.keys.any((k) => k == 'file_type'), isTrue);
      // 大小按官方语义换成 min_size（大于 N MB ⇒ 下界）
      expect(p.keys.any((k) => k == 'min_size'), isTrue);
    });
  });

  group('第 218 轮 · D55 Office 编辑（Mock 核实）', () {
    test('加密探测 → Office.Node.Encrypt/check', () async {
      backend.fixture('SYNO.Office.Node.Encrypt', 'check', (p) => {
        'success': true,
        'data': const <String, Object?>{},
      });
      // 语义（读实现）：调用成功 ⇒ **可以打开**（return true 表示"能读"），
      // 57373 才是"要密码"。
      final ok = await drive.officeEncryptCheck(fileId: '55');
      expect(ok, isTrue);
      final p = last('SYNO.Office.Node.Encrypt');
      expect('${p['method']}', 'check');
      expect('${p['path']}', 'id:55');
      expectLegal('SYNO.Office.Node.Encrypt', 'check', '${p['version']}');
    });

    test('空白文档新建 → Files/create（type=file）', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'create', (p) => {
        'success': true,
        'data': {
          'file_id': '88',
          'name': '未命名.odoc',
          'type': 'file',
          'path': '',
          'display_path': '',
          'parent_id': '0',
          'size': 0,
          'modified_time': 1,
          'created_time': 1,
          'content_type': '',
          'capabilities': const <String, Object?>{},
        },
      });
      final e = await drive.createTextFile(
        path: '/mydrive/未命名.odoc',
      );
      expect(e.name, '未命名.odoc');
      final p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'create');
      expect('${p['type']}', 'file');
      expectLegal('SYNO.SynologyDrive.Files', 'create', '${p['version']}');
    });
  });

  group('第 218 轮 · D74/D79 后台备份：**没有服务端面**，如实不假装 Mock', () {
    test('D74/D79 是本地 WorkManager + 通知 ⇒ 证据类型是离线用例 + 真机记录', () {
      // 官方 `PhotoBackupWorker` / WorkManager 的排程与前台通知都在**客户端**，
      // Mock Server 无对应 API（catalog 里没有 backup worker 之类的方法）。
      final entry = DsmCatalog.load().apis['SYNO.SynologyDrive.Mobile.Notification'];
      expect(
        entry,
        isNotNull,
        reason: '通知订阅是 FCM 那条（用户已排除）；后台备份本身不走服务端任务',
      );
      // ⇒ 台账里这两行的证据写成「离线用例 + docs/device-round-r8.md §3.2」，
      //   不写成"Mock 核实"（那是另一回事）。
    });
  });
}
