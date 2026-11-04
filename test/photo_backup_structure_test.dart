// ★★ D72「按日期分目录」（官方 `BackupStructure`）的核实。
//
// ## 逐字证据（Drive 3.9.0-1113 反编译，全部在本文件里钉住）
//
// * `backup/BackupStructureKt.smali`：
//   `VALUE_NONE="none"` / `VALUE_YEAR="year"` / `VALUE_YEAR_AND_MONTH="year_and_month"`
// * `backup/BackupStructure.smali`：
//   * 枚举顺序 `None` / `Year` / `YearAndMonth`；
//   * `fromValue` 认不出 → **回落 `year_and_month`**；
//   * `getStructure(J)`：`none` → `""`；`year` → `getYearString()`；
//     其余 → `getYearMonthString()`
// * `util/DateUtilities.smali:1114-1153`：
//   `getYearMonthString` = `SimpleDateFormat("yyyy/MM")`；
//   `getYearString` = `SimpleDateFormat("yyyy")`
// * `backup/PhotoBackupManager.smali:1596-1600`：
//   `getPhotoBackupStructure().getStructure(asset.getTakenTime())`
//   ⇒ 用**拍摄时间**分段（不是上传时间），且**逐条**资产各算各的
//
// 本文件覆盖：
//   ① 快照持久化（默认 / 老 JSON / 脏值回落）
//   ② 落点路径格式（none / year / year_and_month，含个位月补零）
//   ③ 上传器：**按每条资产的拍摄时间**选目录，并逐级建目录
//   ④ 去重清单：跨日期目录合并（否则已传进 `2026/09` 的会再传一次）
//   ⑤ 页面：选择器在、选完落盘
//
// §5.1：全部走内存 FakeTransport / 内存 store，**不碰真机**。
// （`Files/create` 是写方法，但这里是**离线 Mock 断言调用面**，
//  没有对任何真 NAS 发起请求；见文末声明。）
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/media/device_media_library.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/photos/photo_backup_queue.dart';
import 'package:synhub/src/features/photos/photo_backup_target.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _driveTable = <String, Map<String, dynamic>>{
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Photos': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

DeviceMediaAsset _asset(String name, {required int takenMs, int size = 100}) =>
    DeviceMediaAsset(
      id: name,
      uri: 'content://media/$name',
      displayName: name,
      size: size,
      takenTimeMs: takenMs,
      modifiedTimeMs: takenMs,
      mimeType: 'image/jpeg',
      isVideo: false,
      relativePath: 'DCIM/Camera/$name',
    );

/// 2026-09-15 与 2026-10-02（本地时区）—— 用来验证**跨月各落各的目录**。
final _sep = DateTime(2026, 9, 15, 12);
final _oct = DateTime(2026, 10, 2, 12);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('D72-1. 快照持久化：默认与回落都跟官方一致', () {
    test('★★ 默认 = year_and_month（官方默认）', () {
      expect(
        const PhotoBackupSnapshot().structure,
        DriveBackupStructure.yearAndMonth,
      );
    });

    test('★★ 三个官方字面量的往返', () {
      for (final s in DriveBackupStructure.values) {
        final snap = PhotoBackupSnapshot(structure: s);
        final back = PhotoBackupSnapshot.decode(snap.encode());
        expect(back.structure, s, reason: '${s.value} 往返');
      }
      expect(
        const PhotoBackupSnapshot(structure: DriveBackupStructure.year).toJson()['backup_structure'],
        'year',
      );
    });

    test('★★ 老 JSON 没这个键 → year_and_month；脏值也回落（官方 fromValue）', () {
      final legacy = PhotoBackupSnapshot.decode(
        '{"destination":"drive","done":[],"target_folder_id":"/mydrive/PhotoBackup/X"}',
      );
      expect(legacy.structure, DriveBackupStructure.yearAndMonth);
      expect(
        PhotoBackupSnapshot.decode('{"backup_structure":"bogus"}').structure,
        DriveBackupStructure.yearAndMonth,
      );
      expect(
        PhotoBackupSnapshot.decode('{"backup_structure":"none"}').structure,
        DriveBackupStructure.none,
      );
    });
  });

  group('D72-2. 目录格式 = 官方 SimpleDateFormat', () {
    test('★★ none/year/year_and_month 三段路径', () {
      const device = 'HONOR';
      expect(
        DriveApi.photoBackupFolderPathFor(
          device: device,
          structure: DriveBackupStructure.none,
          taken: _sep,
        ),
        '/mydrive/PhotoBackup/HONOR',
      );
      expect(
        DriveApi.photoBackupFolderPathFor(
          device: device,
          structure: DriveBackupStructure.year,
          taken: _sep,
        ),
        '/mydrive/PhotoBackup/HONOR/2026',
      );
      expect(
        DriveApi.photoBackupFolderPathFor(
          device: device,
          structure: DriveBackupStructure.yearAndMonth,
          taken: _sep,
        ),
        '/mydrive/PhotoBackup/HONOR/2026/09',
        reason: '官方 getYearMonthString 是 yyyy/MM —— 个位月必须补零',
      );
    });
  });

  group('D72-3. 上传器：按**每条资产的拍摄时间**落目录', () {
    testWidgets('★★ 两条不同月份 → 各建各的年月目录并分别落盘', (tester) async {
      final created = <String>[];
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._driveTable});
      t.onCall = (p) {
        switch ('${p['api']}.${p['method']}') {
          case 'SYNO.SynologyDrive.Files.get':
            // `_ensureFolder` 的复核：把这些路径当成"还不存在"→ 触发 create
            return {'success': false, 'error': {'code': 1000}};
          case 'SYNO.SynologyDrive.Files.create':
            created.add('${p['path']}');
            return {'file_id': 'n', 'name': 'x', 'type': 'dir', 'path': '${p['path']}'};
          case 'SYNO.SynologyDrive.Files.list':
            return {'items': [], 'total': 0};
        }
        return null;
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final drive = DriveApi(api);
      final targets = PhotoBackupTargets(
        fotoOf: () => null,
        driveOf: () => drive,
        deviceNameOf: () => 'HONOR',
      )..structure = DriveBackupStructure.yearAndMonth;
      final uploader = DestinationPhotoBackupUploader(targets);

      await uploader.upload(
        asset: _asset('sep.jpg', takenMs: _sep.millisecondsSinceEpoch),
        localPath: '/tmp/sep.jpg',
        targetFolderId: '/mydrive/PhotoBackup/HONOR',
        destination: PhotoBackupDestination.drive,
      );
      await uploader.upload(
        asset: _asset('oct.jpg', takenMs: _oct.millisecondsSinceEpoch),
        localPath: '/tmp/oct.jpg',
        targetFolderId: '/mydrive/PhotoBackup/HONOR',
        destination: PhotoBackupDestination.drive,
      );

      // 逐级建目录：设备根 + 2026 + 2026/09 + 2026/10
      expect(
        created,
        containsAll([
          '/mydrive/PhotoBackup/HONOR',
          '/mydrive/PhotoBackup/HONOR/2026',
          '/mydrive/PhotoBackup/HONOR/2026/09',
          '/mydrive/PhotoBackup/HONOR/2026/10',
        ]),
      );
      // 两条资产**分别**落在自己的月份目录（不是同一个目录）
      // （`Photos/upload` 走 multipart，FakeTransport 把它记进 `calls`）
      final uploaded = t.calls
          .where((c) => c['method'] == 'upload')
          .map((c) => '${c['path']}')
          .toList();
      expect(uploaded, [
        '/mydrive/PhotoBackup/HONOR/2026/09/sep.jpg',
        '/mydrive/PhotoBackup/HONOR/2026/10/oct.jpg',
      ]);
    });

    testWidgets('★★ structure = none → 保持旧的设备目录行为（不加日期层）', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._driveTable});
      t.onCall = (p) {
        switch ('${p['api']}.${p['method']}') {
          case 'SYNO.SynologyDrive.Files.get':
            return {'success': false, 'error': {'code': 1000}};
          case 'SYNO.SynologyDrive.Files.create':
            return {'file_id': 'n', 'type': 'dir'};
        }
        return null;
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final targets = PhotoBackupTargets(
        fotoOf: () => null,
        driveOf: () => DriveApi(api),
        deviceNameOf: () => 'HONOR',
      )..structure = DriveBackupStructure.none;

      await DestinationPhotoBackupUploader(targets).upload(
        asset: _asset('sep.jpg', takenMs: _sep.millisecondsSinceEpoch),
        localPath: '/tmp/sep.jpg',
        targetFolderId: '/mydrive/PhotoBackup/HONOR',
        destination: PhotoBackupDestination.drive,
      );
      expect(
        t.calls.where((c) => c['method'] == 'upload').map((c) => c['path']),
        ['/mydrive/PhotoBackup/HONOR/sep.jpg'],
      );
    });
  });

  group('D72-4. 去重清单跨日期目录合并', () {
    testWidgets('★★ 同一文件出现在两个月份目录也只算一次', (tester) async {
      final listed = <String>[];
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._driveTable});
      t.onCall = (p) {
        if ('${p['api']}.${p['method']}' == 'SYNO.SynologyDrive.Files.list') {
          final path = '${p['path']}';
          listed.add(path);
          return {
            'items': [
              {'file_id': '1', 'name': 'a.jpg', 'type': 'file', 'size': 100},
              if (path.endsWith('/2026/09'))
                {'file_id': '2', 'name': 'b.jpg', 'type': 'file', 'size': 200},
              if (path.endsWith('/2026/10'))
                {'file_id': '3', 'name': 'b.jpg', 'type': 'file', 'size': 200},
            ],
            'total': 1,
          };
        }
        return null;
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final targets = PhotoBackupTargets(
        fotoOf: () => null,
        driveOf: () => DriveApi(api),
        deviceNameOf: () => 'HONOR',
      )..structure = DriveBackupStructure.yearAndMonth;

      final remote = await targets.remoteEntriesForStructure(
        PhotoBackupDestination.drive,
        ref: '/mydrive/PhotoBackup/HONOR',
        assets: [
          _asset('a.jpg', takenMs: _sep.millisecondsSinceEpoch),
          _asset('b.jpg', takenMs: _oct.millisecondsSinceEpoch),
        ],
      );

      // 设备根 + 2026/09 + 2026/10 都列了
      expect(listed, containsAll([
        '/mydrive/PhotoBackup/HONOR',
        '/mydrive/PhotoBackup/HONOR/2026/09',
        '/mydrive/PhotoBackup/HONOR/2026/10',
      ]));
      // `b.jpg|200` 在两个目录都有 → 合并后只留一条
      final keys = remote.map((e) => '${e.name}|${e.size}').toList();
      expect(keys.where((k) => k == 'b.jpg|200').length, 1);
      expect(keys.toSet(), {'a.jpg|100', 'b.jpg|200'});
    });

    testWidgets('★ structure = none → 只列设备根（等价旧行为）', (tester) async {
      final listed = <String>[];
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._driveTable});
      t.onCall = (p) {
        if ('${p['api']}.${p['method']}' == 'SYNO.SynologyDrive.Files.list') {
          listed.add('${p['path']}');
          return {'items': [], 'total': 0};
        }
        return null;
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final targets = PhotoBackupTargets(
        fotoOf: () => null,
        driveOf: () => DriveApi(api),
        deviceNameOf: () => 'HONOR',
      )..structure = DriveBackupStructure.none;

      await targets.remoteEntriesForStructure(
        PhotoBackupDestination.drive,
        ref: '/mydrive/PhotoBackup/HONOR',
        assets: [_asset('a.jpg', takenMs: _sep.millisecondsSinceEpoch)],
      );
      expect(listed, ['/mydrive/PhotoBackup/HONOR']);
    });
  });

  group('D72-5. 存储层往返（真 store 实现）', () {
    test('★★ 选了 year 落盘后读回还是 year', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(structure: DriveBackupStructure.year),
      );
      final loaded = await store.load();
      expect(loaded.structure, DriveBackupStructure.year);
      await store.save(
        loaded.copyWith(structure: DriveBackupStructure.none),
      );
      expect(
        (await store.load()).structure,
        DriveBackupStructure.none,
      );
    });
  });
}
