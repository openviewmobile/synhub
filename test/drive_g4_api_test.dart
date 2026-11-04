// Drive G4 批次：**接口层 + 动作层**离线测试（D21 / D31 / D34 / D35 / D40 / D72）。
//
// 全部不依赖 widget；动作层通过注入假 `DriveSendBridge` + 假 `DriveLocalWriter`
// 覆盖"打包字节怎么拿、拿到之后交给谁"两个关键分支。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_g4_providers.dart';
import 'package:synhub/src/features/drive/drive_send_bridge.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.AdvanceSharing.Public': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
}) {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) => {
    ...?responses['${params['api']}.${params['method']}'],
    'success': true,
  };
  return t;
}

Future<DriveApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return DriveApi(api);
}

Map<String, dynamic> _call(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

DriveEntryDto _entry({String id = '1', String name = 'a.txt'}) =>
    DriveEntryDto.fromJson({
      'file_id': id,
      'name': name,
      'type': 'file',
      'path': '/$name',
      'display_path': '/mydrive/$name',
      'parent_id': '900',
      'size': 2048,
      'modified_time': 1789739500,
      'created_time': 1789739400,
      'content_type': 'document',
      'owner': {'display_name': 'demo_user', 'name': 'demo_user'},
      'capabilities': {'can_download': true},
    });

/// 记录调用的假桥。
class _RecordingBridge implements DriveSendBridge {
  final List<String> saves = [];
  final List<String> shares = [];
  bool saveOk = true;
  bool shareOk = true;
  String? savePath;

  @override
  Future<String?> saveToDownloads({
    required String path,
    required String name,
    required String mime,
  }) async {
    saves.add('$path|$name|$mime');
    savePath = path;
    return saveOk ? 'content://downloads/$name' : null;
  }

  @override
  Future<bool> share({
    required String path,
    required String name,
    required String mime,
  }) async {
    shares.add('$path|$name|$mime');
    return shareOk;
  }

  @override
  Future<bool> canShare({required String path, required String mime}) async =>
      true;
}

void main() {
  // ------------------------------------------------------------ D21 计算机

  group('D21 计算机列表（Files/list_backup_tasks v3）', () {
    test('走 v3 + offset/limit，解析 items/total', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list_backup_tasks': {
            'items': [
              {
                'file_id': 'c1',
                'name': 'DESKTOP-1',
                'type': 'dir',
                'display_path': '/mydrive/Computers/DESKTOP-1',
                'size': 0,
                'modified_time': 1789739500,
              },
            ],
            'total': 1,
          },
        },
      );
      final api = await _api(t);
      final r = await api.listBackupTasks();
      final call = _call(t, 'list_backup_tasks');
      expect(call['api'], 'SYNO.SynologyDrive.Files');
      expect(call['version'], '3');
      expect(call['offset'], 0);
      expect(call['limit'], 100);
      expect(r.total, 1);
      expect(r.items.single.name, 'DESKTOP-1');
    });

    test('服务器只到 v2 → 走 v2（negotiate 收敛，不发 v3）', () async {
      final t = FakeTransport(
        {
          'SYNO.SynologyDrive.Files.list_backup_tasks': {
            'items': const [],
            'total': 0,
          },
        },
        {
          ...FakeTransport.table,
          'SYNO.SynologyDrive.Files': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 2,
          },
        },
      );
      final api = await _api(t);
      await api.listBackupTasks();
      expect(_call(t, 'list_backup_tasks')['version'], '2');
    });

    test('driveComputersProvider 未连接即抛（页面显示未连接）', () {
      final c = ProviderContainer(
        overrides: [driveApiProvider.overrideWithValue(null)],
      );
      addTearDown(c.dispose);
      expect(
        () => c.read(driveComputersProvider.future),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ------------------------------------------------------------ D31/D34/D35

  group('D31/D34/D35 打包下载 / 发送副本 / 压缩并发送', () {
    test('D31 saveArchive：一段式 download → 落盘 → 存进「下载」目录', () async {
      final t = _transport();
      t.downloadBytes = const [1, 2, 3, 4];
      final api = await _api(t);
      final bridge = _RecordingBridge();
      final written = <String>[];
      final actions = DriveTransferActions(
        api: api,
        bridge: bridge,
        writer: (name, bytes) async {
          written.add('$name:${bytes.length}');
          return '/tmp/$name';
        },
      );

      final out = await actions.saveArchive(
        fileIds: const ['1', '2'],
        archiveName: 'bundle',
      );

      // 打包下载的 URL 走 Files/download 的 archive_name 变体（v≤7）
      final url = t.downloads.single;
      expect(url, contains('api=SYNO.SynologyDrive.Files'));
      expect(url, contains('method=download'));
      expect(url, contains('archive_name=bundle'));
      expect(url, contains('force_download=true'));
      expect(written, ['bundle.zip:4']);
      expect(bridge.saves.single, contains('application/zip'));
      expect(out.status, DriveTransferStatus.done);
      expect(out.detail, 'bundle.zip');
    });

    test('D31 一段式失败 → 回落两段式（createArchiveTask + task_id 下载）', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.download': {'task_id': 'T-9'},
        },
      );
      // 一段式：URL 里带 archive_name 的那次失败；task_id 那次成功
      t.failures['archive_name'] = 500;
      t.downloadBytes = const [9, 9];
      final api = await _api(t);
      final bridge = _RecordingBridge();
      final actions = DriveTransferActions(
        api: api,
        bridge: bridge,
        writer: (name, bytes) async => '/tmp/$name',
      );

      final out = await actions.saveArchive(
        fileIds: const ['1'],
        archiveName: 'b',
      );
      expect(out.isDone, isTrue);
      // 建任务那次调用（POST）必须在
      final create = _call(t, 'download');
      expect(create['api'], 'SYNO.SynologyDrive.Files');
      expect(create['method'], 'download');
      expect(create['archive_name'], 'b');
      expect(create['force_download'], true);
      // 两段式最终下载的 URL 带 task_id
      expect(t.downloads.length, 2);
      expect(t.downloads.last, contains('task_id=T-9'));
    });

    test('D35 shareArchive：走 ACTION_SEND 分享面板，不是存下载目录', () async {
      final t = _transport();
      t.downloadBytes = const [7];
      final api = await _api(t);
      final bridge = _RecordingBridge();
      final actions = DriveTransferActions(
        api: api,
        bridge: bridge,
        writer: (name, bytes) async => '/tmp/$name',
      );

      final out = await actions.shareArchive(
        fileIds: const ['1'],
        archiveName: 'pkg.zip',
      );
      expect(out.status, DriveTransferStatus.done);
      expect(bridge.saves, isEmpty);
      expect(bridge.shares.single, contains('application/zip'));
      // 已经是 .zip 后缀就不再追加一层
      expect(out.detail, 'pkg.zip');
    });

    test('桥不可用 → noHandler（**不装成成功**）', () async {
      final t = _transport();
      t.downloadBytes = const [1];
      final api = await _api(t);
      final bridge = _RecordingBridge()..saveOk = false;
      final actions = DriveTransferActions(
        api: api,
        bridge: bridge,
        writer: (name, bytes) async => '/tmp/$name',
      );
      final out = await actions.saveArchive(
        fileIds: const ['1'],
        archiveName: 'a',
      );
      expect(out.status, DriveTransferStatus.noHandler);
      expect(out.detail, '/tmp/a.zip');
    });

    test('空选择 → failed(empty-selection)，一个请求都不发', () async {
      final t = _transport();
      final api = await _api(t);
      final actions = DriveTransferActions(
        api: api,
        bridge: _RecordingBridge(),
        writer: (name, bytes) async => '/tmp/$name',
      );
      final out = await actions.saveArchive(
        fileIds: const [],
        archiveName: 'a',
      );
      expect(out.status, DriveTransferStatus.failed);
      expect(out.detail, 'empty-selection');
      expect(t.downloads, isEmpty);
    });

    test('D34 sendCopy：单条目原文件下载后交给分享面板', () async {
      final t = _transport();
      t.downloadBytes = const [5, 5, 5];
      final api = await _api(t);
      final bridge = _RecordingBridge();
      final actions = DriveTransferActions(
        api: api,
        bridge: bridge,
        writer: (name, bytes) async => '/tmp/$name',
      );
      final out = await actions.sendCopy(
        entry: _entry(id: '7', name: 'note.txt'),
      );
      expect(out.status, DriveTransferStatus.done);
      expect(out.detail, 'note.txt');
      expect(bridge.shares.single, contains('/tmp/note.txt'));
      expect(t.downloads.single, contains('method=download'));
    });
  });

  // ------------------------------------------------------------ D40 密码

  group('D40 AdvanceSharing 密码校验', () {
    test('auth：api/method/version=1 + sharing_link + password', () async {
      final t = _transport(
        responses: {'SYNO.SynologyDrive.AdvanceSharing.Public.auth': const {}},
      );
      final api = await _api(t);
      final ok = await api.authAdvanceSharingPassword(
        sharingLink: 'https://nas/sharing/abc',
        password: 'p@ss',
      );
      expect(ok, isTrue);
      final call = _call(t, 'auth');
      expect(call['api'], 'SYNO.SynologyDrive.AdvanceSharing.Public');
      expect(call['version'], '1');
      expect(call['sharing_link'], 'https://nas/sharing/abc');
      expect(call['password'], 'p@ss');
    });

    test('服务端拒绝（1036 无效分享链接）→ 回 false，不抛', () async {
      final t = _transport();
      t.failures['SYNO.SynologyDrive.AdvanceSharing.Public.auth'] = 1036;
      final api = await _api(t);
      expect(
        await api.authAdvanceSharingPassword(sharingLink: 'x', password: 'y'),
        isFalse,
      );
    });
  });

  // ------------------------------------------------------------ D72 备份目录

  group('D72 照片备份的日期结构（none/year/year_and_month）', () {
    final taken = DateTime(2026, 3, 7, 21, 5);

    test('三种结构的后缀与官方 pattern 逐字一致', () {
      expect(
        DriveApi.backupStructureSuffix(DriveBackupStructure.none, taken),
        '',
      );
      expect(
        DriveApi.backupStructureSuffix(DriveBackupStructure.year, taken),
        '2026',
      );
      expect(
        DriveApi.backupStructureSuffix(
          DriveBackupStructure.yearAndMonth,
          taken,
        ),
        '2026/03',
      );
    });

    test('月份补零（1 月 = 01）', () {
      expect(
        DriveApi.backupStructureSuffix(
          DriveBackupStructure.yearAndMonth,
          DateTime(2026, 1, 2),
        ),
        '2026/01',
      );
    });

    test('目录路径：none 不落日期层；taken 为空也退回 base', () {
      final base = DriveApi.photoBackupFolderPath('HONOR');
      expect(
        DriveApi.photoBackupFolderPathFor(
          device: 'HONOR',
          structure: DriveBackupStructure.none,
          taken: taken,
        ),
        base,
      );
      expect(
        DriveApi.photoBackupFolderPathFor(device: 'HONOR', taken: null),
        base,
      );
      expect(
        DriveApi.photoBackupFolderPathFor(
          device: 'HONOR',
          structure: DriveBackupStructure.year,
          taken: taken,
        ),
        '$base/2026',
      );
      expect(
        DriveApi.photoBackupFolderPathFor(
          device: 'HONOR',
          structure: DriveBackupStructure.yearAndMonth,
          taken: taken,
        ),
        '$base/2026/03',
      );
    });

    test('fromValue：认不出的值回落 year_and_month（官方 Companion 同口径）', () {
      expect(DriveBackupStructure.fromValue('none'), DriveBackupStructure.none);
      expect(DriveBackupStructure.fromValue('year'), DriveBackupStructure.year);
      expect(
        DriveBackupStructure.fromValue('bogus'),
        DriveBackupStructure.yearAndMonth,
      );
      expect(
        DriveBackupStructure.fromValue(null),
        DriveBackupStructure.yearAndMonth,
      );
    });
  });
}
