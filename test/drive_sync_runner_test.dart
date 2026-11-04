// ★★ ③Drive 第 220 轮 **D65 执行器** 的用例：
//   ① 核心派发/失败隔离/冲突命名（纯离线，用假 IO）；
//   ② 真实 `DriveApiSyncIo` 的 wire 契约走 **Mock Server**（新规 B2）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_sync_runner.dart';
import 'package:synhub/src/features/drive/drive_sync_task.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

/// 记录型假远端
class _FakeRemote implements DriveSyncRemoteIo {
  final calls = <String>[];
  final failOn = <String>{};
  String folderId = '42';

  @override
  Future<String> ensureFolder(String relDir) async {
    calls.add('ensure:$relDir');
    if (failOn.contains('ensure')) throw StateError('ensure 失败');
    return folderId;
  }

  @override
  Future<void> upload({required String localPath, required String relPath}) async {
    calls.add('upload:$relPath');
    if (failOn.contains(relPath)) throw StateError('上传失败');
  }

  @override
  Future<void> download({required String relPath, required String localPath}) async {
    calls.add('download:$relPath');
  }

  @override
  Future<void> removeRemote(String relPath) async {
    calls.add('removeRemote:$relPath');
  }
}

class _FakeLocal implements DriveSyncLocalIo {
  final calls = <String>[];

  @override
  String absolutePath(String relPath) => '/root/$relPath';

  @override
  Future<void> removeLocal(String relPath) async => calls.add('removeLocal:$relPath');

  @override
  Future<String> renameLocalConflict(String relPath, String stamp) async {
    calls.add('rename:$relPath@$stamp');
    return '/root/${driveSyncConflictName(relPath, stamp)}';
  }
}

DriveSyncAction _a(DriveSyncActionKind k, String path) =>
    DriveSyncAction(k, path, '测试');

void main() {
  group('D65 执行器 · 派发与失败隔离', () {
    test('五种动作各自打到对的 IO 原语；skip 不发', () async {
      final remote = _FakeRemote();
      final local = _FakeLocal();
      final ex = DriveSyncExecutor(remote: remote, local: local);
      final r = await ex.run(
        DriveSyncDiff([
          _a(DriveSyncActionKind.upload, '子目录/a.txt'),
          _a(DriveSyncActionKind.download, 'b.txt'),
          _a(DriveSyncActionKind.removeLocal, 'c.txt'),
          _a(DriveSyncActionKind.removeRemote, 'd.txt'),
          _a(DriveSyncActionKind.renameLocal, 'e.txt'),
          _a(DriveSyncActionKind.skip, 'f.txt'),
        ]),
        stamp: 'STAMP',
      );
      expect(r.executed, 5);
      expect(r.failed, 0);
      expect(r.allOk, isTrue);
      // 上传前会先 ensure 相对目录
      expect(remote.calls.first, 'ensure:子目录');
      expect(remote.calls, contains('upload:子目录/a.txt'));
      expect(remote.calls, contains('download:b.txt'));
      expect(remote.calls, contains('removeRemote:d.txt'));
      expect(local.calls, contains('removeLocal:c.txt'));
      expect(local.calls, contains('rename:e.txt@STAMP'));
      expect(remote.calls.any((c) => c.contains('f.txt')), isFalse);
    });

    test('单条失败**不中断**其余，失败原因带回', () async {
      final remote = _FakeRemote()..failOn.add('bad.txt');
      final local = _FakeLocal();
      final r = await DriveSyncExecutor(remote: remote, local: local).run(
        DriveSyncDiff([
          _a(DriveSyncActionKind.upload, 'bad.txt'),
          _a(DriveSyncActionKind.upload, 'good.txt'),
        ]),
      );
      expect(r.executed, 1);
      expect(r.failed, 1);
      expect(r.allOk, isFalse);
      expect(r.failures.single.action.path, 'bad.txt');
      expect(r.failures.single.error, contains('上传失败'));
      expect(remote.calls, contains('upload:good.txt'));
    });

    test('全是 skip ⇒ 不发任何 IO，且 allOk', () async {
      final remote = _FakeRemote();
      final local = _FakeLocal();
      final r = await DriveSyncExecutor(remote: remote, local: local).run(
        DriveSyncDiff([_a(DriveSyncActionKind.skip, 'x')]),
      );
      expect(r.outcomes, isEmpty);
      expect(remote.calls, isEmpty);
      expect(local.calls, isEmpty);
      expect(r.allOk, isTrue);
    });

    test('进度回调覆盖每一条（含收尾）', () async {
      final seen = <int>[];
      await DriveSyncExecutor(remote: _FakeRemote(), local: _FakeLocal()).run(
        DriveSyncDiff([
          _a(DriveSyncActionKind.upload, 'a'),
          _a(DriveSyncActionKind.upload, 'b'),
        ]),
        onProgress: (_, done, total) => seen.add(done),
      );
      expect(seen, [0, 1, 2]);
    });
  });

  group('D65 执行器 · 冲突副本命名', () {
    test('带目录/带后缀/无后缀都规整', () {
      expect(
        driveSyncConflictName('报告.docx', 'S'),
        '报告 (冲突 S).docx',
      );
      expect(
        driveSyncConflictName('子/报告.tar.gz', 'S'),
        '子/报告.tar (冲突 S).gz',
      );
      expect(driveSyncConflictName('README', 'S'), 'README (冲突 S)');
    });
  });

  group('D65 执行器 · 本地 IO（真实 dart:io）', () {
    test('删文件 / 删目录 / 冲突改名真的落盘', () async {
      final root = Directory.systemTemp.createTempSync('d65_io');
      final io = LocalDriveSyncIo(root.path);
      File('${root.path}/a.txt').writeAsStringSync('x');
      Directory('${root.path}/d').createSync();
      File('${root.path}/b.txt').writeAsStringSync('y');

      await io.removeLocal('a.txt');
      await io.removeLocal('d');
      final renamed = await io.renameLocalConflict('b.txt', 'S');
      expect(File('${root.path}/a.txt').existsSync(), isFalse);
      expect(Directory('${root.path}/d').existsSync(), isFalse);
      expect(File('${root.path}/b.txt').existsSync(), isFalse);
      expect(renamed, endsWith('b (冲突 S).txt'));
      expect(File(renamed).readAsStringSync(), 'y');
    });
  });

  group('D65 执行器 · DriveApiSyncIo 走 Mock Server', () {
    late MockDsmBackend backend;
    late DriveApi drive;
    late DriveApiSyncIo io;

    setUp(() async {
      backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: 'u', admin: false);
      final web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: 'u', password: 'x');
      drive = DriveApi(web);
      io = DriveApiSyncIo(drive, remoteRoot: '/mydrive/项目');
    });

    Map<String, dynamic> last(String apiName) => backend.requests
        .lastWhere((r) => '${r.params['api']}' == apiName)
        .params;

    Map<String, dynamic> entryJson(String id, String name) => {
      'file_id': id,
      'name': name,
      'type': 'file',
      'size': 1,
      'modified_time': 1,
      'path': '',
      'display_path': '',
      'parent_id': '0',
      'created_time': 1,
      'content_type': '',
      'capabilities': const <String, Object?>{},
    };

    test('ensureFolder：逐级 `Files/get`，缺了就 `Files/create`', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'get', (p) {
        final path = '${p['path']}';
        if (path.endsWith('/子')) return {'success': true, 'data': entryJson('11', '子')};
        // 第一级故意不存在 ⇒ 触发 create
        return {'success': false, 'error': {'code': 1000}};
      });
      backend.fixture('SYNO.SynologyDrive.Files', 'create', (p) => {
        'success': true,
        'data': entryJson('10', '外'),
      });
      final id = await io.ensureFolder('外/子');
      expect(id, '11');
      expect(last('SYNO.SynologyDrive.Files')['method'], isNotNull);
      expect(
        backend.requests.any(
          (r) => '${r.params['api']}' == 'SYNO.SynologyDrive.Files' &&
              '${r.params['method']}' == 'create' &&
              '${r.params['path']}' == '/mydrive/项目/外',
        ),
        isTrue,
        reason: '缺的目录要用 Files/create 建出来',
      );
    });

    test('upload → `Files/upload`，path=id:<父目录 id>', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'get', (p) => {
        'success': true,
        'data': entryJson('11', '子'),
      });
      backend.fixture('SYNO.SynologyDrive.Files', 'upload', (p) => {
        'success': true,
        'data': {'file_id': '900', 'hash': 'h'},
      });
      final tmp = Directory.systemTemp.createTempSync('d65_up');
      final f = File('${tmp.path}/a.txt')..writeAsStringSync('hello');
      await io.upload(localPath: f.path, relPath: '子/a.txt');
      final p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'upload');
      expect('${p['path']}', 'id:11/报告.txt'.replaceAll('报告', 'a'));
      expect('${p['conflict_action']}', 'version');
    });

    test('removeRemote → `Files/delete`，用查到的 file_id', () async {
      backend.fixture('SYNO.SynologyDrive.Files', 'get', (p) => {
        'success': true,
        'data': entryJson('55', 'x.txt'),
      });
      backend.fixture('SYNO.SynologyDrive.Files', 'delete', (p) => {
        'success': true,
        'data': {'async_task_id': 't1'},
      });
      await io.removeRemote('x.txt');
      final p = last('SYNO.SynologyDrive.Files');
      expect('${p['method']}', 'delete');
      expect('${p['files']}', contains('id:55'));
    });
  });
}
