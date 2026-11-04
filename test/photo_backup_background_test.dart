// 相册备份「后台化 + 双落点」的**行为**用例（不是脚手架，全是断言）。
//
// 覆盖（对应 `docs/photo-backup-background.md` 的证据表）：
//   1. 两个落点各自独立游标（内存 + Drift 两种存储）；
//   2. Drift v11 → v12 递增迁移 + 老 JSON 游标补种（向前兼容，不丢账本）；
//   3. 落点能力门：105/160 隐藏、102/103 只影响该选项、没连上置灰；
//   4. 去重：官方抽样 MD5 窗口形态（(1000+200)KB 取最后 200KB）+ 全文件 MD4，
//      以及队列里两条去重腿真的会跳过；
//   5. 官方同构：只扫 DCIM、串行并发 1；
//   6. 后台入口的参数解析/报告序列化/无会话语义；
//   7. 前台/后台互斥：前台跑的时候要 `reportForeground(true/false)`；
//   8. 「仅充电」硬约束前台也生效。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/media/device_media_library.dart';
import 'package:synhub/src/features/photos/photo_backup_background.dart';
import 'package:synhub/src/features/photos/photo_backup_dedup.dart';
import 'package:synhub/src/features/photos/photo_backup_page.dart';
import 'package:synhub/src/features/photos/photo_backup_platform.dart';
import 'package:synhub/src/features/photos/photo_backup_providers.dart';
import 'package:synhub/src/features/photos/photo_backup_queue.dart';
import 'package:synhub/src/features/photos/photo_backup_runner.dart';
import 'package:synhub/src/features/photos/photo_backup_store.dart';
import 'package:synhub/src/features/photos/photo_backup_target.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ------------------------------------------------------------------ 假件

DeviceMediaAsset _asset(
  String name, {
  int size = 1000,
  bool video = false,
  int taken = 1700000000000,
  String path = 'DCIM/Camera',
}) => DeviceMediaAsset(
  id: name,
  uri: 'content://media/external/file/${name.hashCode}',
  displayName: name,
  size: size,
  takenTimeMs: taken,
  modifiedTimeMs: taken,
  mimeType: video ? 'video/mp4' : 'image/jpeg',
  isVideo: video,
  relativePath: path,
);

class _FakeMedia implements DeviceMediaLibrary {
  _FakeMedia(this.assets);

  List<DeviceMediaAsset> assets;
  MediaPermission permission = MediaPermission.granted;
  int listCalls = 0;
  Map<String, String> paths = {};

  @override
  Future<MediaPermission> permissionStatus() async => permission;

  @override
  Future<MediaPermission> ensurePermission({bool interactive = true}) async =>
      permission;

  @override
  Future<List<DeviceMediaAsset>> list({
    bool includeVideos = true,
    int limit = 500,
    int offset = 0,
  }) async {
    listCalls++;
    // ★ D77：尊重 offset（分页枚举用）；旧实现忽略 offset，
    //   会让分页循环每批都拿到同一批数据。
    return assets
        .where((a) => includeVideos || !a.isVideo)
        .skip(offset)
        .take(limit)
        .toList();
  }

  @override
  Future<String?> materialize(DeviceMediaAsset asset) async =>
      paths[asset.displayName] ?? '/tmp/photo-backup-fake/${asset.displayName}';
}

/// 上传器：记录每次上传的落点/目标；可设并发闸门与失败名单。
class _FakeUploader implements PhotoBackupUploader {
  final uploaded =
      <({String name, String folderId, PhotoBackupDestination destination})>[];
  final Set<String> failNames = {};
  int active = 0;
  int maxActive = 0;

  @override
  Future<String> upload({
    required DeviceMediaAsset asset,
    required String localPath,
    required String targetFolderId,
    required PhotoBackupDestination destination,
    void Function(int sent, int total)? onProgress,
  }) async {
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await Future<void>.delayed(Duration.zero);
      if (failNames.contains(asset.displayName)) throw StateError('boom');
      onProgress?.call(100, 100);
      uploaded.add((
        name: asset.displayName,
        folderId: targetFolderId,
        destination: destination,
      ));
      return 'unit-${asset.displayName}';
    } finally {
      active--;
    }
  }
}

/// 确定性哈希：名字里带 `same` 的算成同一个内容哈希。
class _FakeHasher implements PhotoBackupHasher {
  _FakeHasher({this.sampled = const {}, this.full = const {}});

  Map<String, String> sampled;
  Map<String, String> full;
  int sampledCalls = 0;

  @override
  Future<String> sampledMd5(String path) async {
    sampledCalls++;
    for (final e in sampled.entries) {
      if (path.endsWith(e.key)) return e.value;
    }
    return '';
  }

  @override
  Future<String> fullMd4(String path) async {
    for (final e in full.entries) {
      if (path.endsWith(e.key)) return e.value;
    }
    return '';
  }
}

/// 记录原生调用的假平台（真平台在单测环境里不会回应，见 `_safe` 注释）。
class _FakePlatform implements PhotoBackupPlatform {
  PhotoBackupPlatformStatus state = const PhotoBackupPlatformStatus(
    supported: true,
    deviceName: 'Pixel 8',
  );
  final List<String> calls = [];
  bool registered = false;
  int? handle;
  bool? lastEnabled;
  PhotoBackupDestination? lastDestination;
  bool? lastChargeOnly;
  bool? lastScreenOffOnly;
  bool? lastWifiOnly;
  final List<bool> foreground = [];

  @override
  Future<PhotoBackupPlatformStatus> status() async => state;

  @override
  Future<bool> registerCallback(int rawHandle) async {
    calls.add('registerCallback');
    registered = true;
    handle = rawHandle;
    return true;
  }

  @override
  Future<bool> setSchedule({
    required bool enabled,
    required bool chargeOnly,
    required bool screenOffOnly,
    required bool wifiOnly,
    required PhotoBackupDestination destination,
  }) async {
    calls.add('setSchedule');
    lastEnabled = enabled;
    lastChargeOnly = chargeOnly;
    lastScreenOffOnly = screenOffOnly;
    lastWifiOnly = wifiOnly;
    lastDestination = destination;
    state = PhotoBackupPlatformStatus(
      supported: true,
      scheduled: enabled,
      charging: state.charging,
      screenInteractive: state.screenInteractive,
      deviceName: state.deviceName,
      lastResult: state.lastResult,
      destination: destination,
      enabled: enabled,
      chargeOnly: chargeOnly,
      screenOffOnly: screenOffOnly,
      wifiOnly: wifiOnly,
    );
    return true;
  }

  @override
  Future<bool> runNow() async {
    calls.add('runNow');
    return true;
  }

  @override
  Future<bool> cancel() async {
    calls.add('cancel');
    return true;
  }

  @override
  Future<void> reportForeground(bool running) async {
    calls.add('reportForeground:$running');
    foreground.add(running);
  }

  @override
  Future<bool> requestIgnoreBatteryOptimization() async {
    calls.add('requestIgnoreBatteryOptimization');
    return true;
  }
}

/// 一个假的 `SYNO.Foto.*` 个人空间 API（只用来给能力门判定 `apiTable`）。
Future<FotoApi> _fotoApi({
  required Map<String, Map<String, dynamic>> table,
  Map<String, Map<String, dynamic>> responses = const {},
}) async {
  // 合并默认能力表：登录要先过 `SYNO.API.Encryption.getinfo`
  final t = FakeTransport({...responses}, {...FakeTransport.table, ...table});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FotoApi(api);
}

/// 一个假的 `SYNO.SynologyDrive.*` API。
Future<DriveApi> _driveApi({
  required Map<String, Map<String, dynamic>> table,
  Map<String, Map<String, dynamic>> responses = const {},
}) async {
  final t = FakeTransport({...responses}, {...FakeTransport.table, ...table});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return DriveApi(api);
}

const _fotoTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Browse.Folder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Upload.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 8,
  },
};

const _driveTableWithPhotos = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Photos': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

void main() {
  // 通道用例要 `TestDefaultBinaryMessengerBinding.instance`，先起绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  // ------------------------------------------------------- 1. 落点与账本隔离

  group('落点账本隔离', () {
    test('内存账本：两个落点各记各的，切落点清游标但保留全局选项', () async {
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          destination: PhotoBackupDestination.synologyPhotos,
          doneKeys: {'1.jpg'},
          lastFinishedAtMs: 111,
          targetFolderId: '7',
          targetFolderName: '手机备份',
          includeVideos: false,
          chargeOnly: true,
        ),
      );

      // 切到 Drive：选项跟着走，游标必须清空（否则会"以为都传过了"一张不传）
      final drive = await store.loadFor(PhotoBackupDestination.drive);
      expect(drive.destination, PhotoBackupDestination.drive);
      expect(drive.doneKeys, isEmpty, reason: '换落点不能继承另一个落点的账本');
      expect(drive.lastFinishedAtMs, 0);
      expect(drive.targetFolderId, isEmpty);
      expect(drive.includeVideos, isFalse, reason: '全局选项要保留');
      expect(drive.chargeOnly, isTrue, reason: '全局选项要保留');

      // Drive 跑一轮
      await store.save(
        drive.copyWith(
          doneKeys: {'drive-only.jpg'},
          targetFolderId: '/mydrive/PhotoBackup/Pixel',
        ),
      );

      // 切回 Photos：原来的游标还在，Drive 的不会串进来
      final photos = await store.loadFor(PhotoBackupDestination.synologyPhotos);
      expect(photos.doneKeys, {'1.jpg'});
      expect(photos.lastFinishedAtMs, 111);
      expect(photos.targetFolderId, '7');
      expect(photos.doneKeys, isNot(contains('drive-only.jpg')));
    });

    test('快照 JSON：新键往返；老 JSON 缺键 → Photos + DCIM-only', () {
      const snap = PhotoBackupSnapshot(
        destination: PhotoBackupDestination.drive,
        doneKeys: {'k'},
        chargeOnly: true,
        screenOffOnly: true,
        dcimOnly: false,
        enabled: true,
      );
      final back = PhotoBackupSnapshot.decode(snap.encode());
      expect(back.destination, PhotoBackupDestination.drive);
      expect(back.chargeOnly, isTrue);
      expect(back.screenOffOnly, isTrue);
      expect(back.dcimOnly, isFalse);
      expect(back.doneKeys, {'k'});

      // 老版本写下的 JSON（没有 destination/charge_only/dcim_only）
      final legacy = PhotoBackupSnapshot.decode(
        jsonEncode({
          'done': ['legacy.jpg'],
          'last_finished_at': 42,
          'target_folder_id': '7',
          'target_folder_name': '手机备份',
          'include_videos': true,
          'wifi_only': false,
          'enabled': true,
        }),
      );
      expect(
        legacy.destination,
        PhotoBackupDestination.synologyPhotos,
        reason: '历史游标只可能属于 Photos',
      );
      expect(legacy.doneKeys, {'legacy.jpg'});
      expect(legacy.dcimOnly, isTrue, reason: '官方恒 DCIM，缺键按 true');
      expect(legacy.chargeOnly, isFalse);
      expect(legacy.screenOffOnly, isFalse);
    });

    test('落点 id 稳定（写进 prefs/原生参数，不能改）', () {
      expect(PhotoBackupDestination.drive.id, 'drive');
      expect(
        PhotoBackupDestination.synologyPhotos.id,
        'synology_photos',
        reason: '原生 `PhotoBackupPlugin.DEST_DRIVE` 之外都算 Photos',
      );
      expect(
        PhotoBackupDestination.fromId('nonsense'),
        PhotoBackupDestination.synologyPhotos,
        reason: '认不出来就按老默认（Photos）',
      );
    });
  });

  // ------------------------------------------------- 2. Drift 迁移 + 向前兼容

  group('Drift v12 迁移', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('photo-backup-db');
      file = File('${dir.path}/chat.sqlite');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    Future<bool> hasTable(ChatDatabase db, String table) async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      return rows.any((r) => r.read<String>('name') == table);
    }

    test('v11 → v12：只加 photo_backup_target_rows 表，老数据一行不动', () async {
      // 1) 建当前版本的库，把 v12 新表删掉、版本号改回 11，冒充老库
      final fresh = ChatDatabase(NativeDatabase(file));
      expect(
        await hasTable(fresh, 'photo_backup_target_rows'),
        isTrue,
        reason: '当前 schema 里必须有这张表',
      );
      await fresh.customStatement('DROP TABLE photo_backup_target_rows');
      // v13 的 `worm_state` 是另一批次的递增迁移；要冒充真正的 v11 老库，
      // 这一列也必须先拿掉（否则 onUpgrade(11→13) 会 "duplicate column name"）。
      await fresh.customStatement(
        'ALTER TABLE file_entry_rows DROP COLUMN worm_state',
      );
      await fresh.customStatement('PRAGMA user_version = 11');
      await fresh.close();

      // 2) 用当前版本打开 → onUpgrade(11→13) 必须把表建回来
      final db = ChatDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(
        await hasTable(db, 'photo_backup_target_rows'),
        isTrue,
        reason: 'v12 迁移：没建表的话老库升上来一读就崩',
      );
      final cols = await db
          .customSelect("PRAGMA table_info('file_entry_rows')")
          .get();
      expect(
        cols.any((r) => r.read<String>('name') == 'worm_state'),
        isTrue,
        reason: '顺带确认 v13 那一步在真老库上也能跑',
      );

      // 3) 表真的能用（主键 = 落点，两个落点各一行）
      final store = DriftPhotoBackupStore(SettingsService(ChatStore(db)), db);
      await store.save(
        const PhotoBackupSnapshot(
          destination: PhotoBackupDestination.synologyPhotos,
          doneKeys: {'p.jpg'},
          targetFolderId: '7',
          lastFinishedAtMs: 100,
        ),
      );
      await store.save(
        const PhotoBackupSnapshot(
          destination: PhotoBackupDestination.drive,
          doneKeys: {'d.jpg'},
          targetFolderId: '/mydrive/PhotoBackup/Pixel',
          lastFinishedAtMs: 200,
        ),
      );
      final photos = await store.loadFor(PhotoBackupDestination.synologyPhotos);
      final drive = await store.loadFor(PhotoBackupDestination.drive);
      expect(photos.doneKeys, {'p.jpg'});
      expect(photos.targetFolderId, '7');
      expect(photos.lastFinishedAtMs, 100);
      expect(drive.doneKeys, {'d.jpg'});
      expect(drive.targetFolderId, '/mydrive/PhotoBackup/Pixel');
      expect(drive.lastFinishedAtMs, 200);
    });

    test('老 JSON 里的游标补种进 Photos 行，且第二次读不会重复补种', () async {
      final db = ChatDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final settings = SettingsService(ChatStore(db));
      // 老版本留下的整包状态（选项 + Photos 游标混在一起）
      await settings.setPhotoBackupRaw(
        jsonEncode({
          'done': ['old.jpg'],
          'last_finished_at': 777,
          'target_folder_id': '9',
          'target_folder_name': '手机备份',
          'include_videos': false,
          'wifi_only': true,
          'enabled': true,
        }),
      );
      final store = DriftPhotoBackupStore(settings, db);

      final photos = await store.load();
      expect(photos.destination, PhotoBackupDestination.synologyPhotos);
      expect(photos.doneKeys, {'old.jpg'}, reason: '补种：老账本不能丢');
      expect(photos.targetFolderId, '9');
      expect(photos.lastFinishedAtMs, 777);
      expect(photos.includeVideos, isFalse);
      expect(photos.wifiOnly, isTrue);

      // 幂等：再读一次结果一样（不会把补种当成"新数据"反复覆盖）
      final again = await store.loadFor(PhotoBackupDestination.drive);
      final rows = await db.select(db.photoBackupTargetRows).get();
      expect(
        rows.where((r) => r.destination == 'synology_photos').length,
        1,
        reason: '补种只能写一行',
      );
      // Drive 那份不继承 Photos 的游标，但继承全局选项
      expect(again.doneKeys, isEmpty);
      expect(again.includeVideos, isFalse);
      expect(again.wifiOnly, isTrue);
    });

    test('写盘后老 JSON 里的游标字段被清空（游标只有表里一份真值）', () async {
      final db = ChatDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final settings = SettingsService(ChatStore(db));
      final store = DriftPhotoBackupStore(settings, db);
      await store.save(
        const PhotoBackupSnapshot(
          destination: PhotoBackupDestination.drive,
          doneKeys: {'x.jpg'},
          lastFinishedAtMs: 5,
          targetFolderId: '/mydrive/PhotoBackup/Pixel',
          targetFolderName: 'Pixel',
          includeVideos: false,
        ),
      );
      final raw = jsonDecode((await settings.photoBackupRaw())!) as Map;
      expect(raw['done'], isEmpty, reason: '游标不进 JSON');
      expect(raw['target_folder_id'], '');
      expect(raw['last_finished_at'], 0);
      expect(raw['destination'], 'drive', reason: '选中落点是全局选项');
      expect(raw['include_videos'], false, reason: '选项还在');
    });
  });

  // ------------------------------------------------------------- 3. 能力门

  group('落点能力门（105/160 隐藏、102/103 只影响该选项）', () {
    Future<PhotoBackupTargets> targets({
      FotoApi? foto,
      DriveApi? drive,
    }) async => PhotoBackupTargets(
      fotoOf: () => foto,
      driveOf: () => drive,
      deviceNameOf: () => 'Pixel',
    );

    test('没连上：两个落点都不可用（置灰 + 原因）', () async {
      final t = await targets();
      for (final d in PhotoBackupDestination.values) {
        final info = t.info(d);
        expect(info.isUsable, isFalse, reason: '$d 没连上不该可用');
        expect(info.isHidden, isFalse, reason: '没连上只是置灰，不该隐藏');
        expect(info.reason, isNotEmpty);
      }
    });

    test('105（noPermission）→ 隐藏该选项；160（noAppPrivilege）同理', () async {
      final t = await targets(foto: await _fotoApi(table: _fotoTable));
      expect(t.info(PhotoBackupDestination.synologyPhotos).isUsable, isTrue);

      t.noteError(PhotoBackupDestination.synologyPhotos, DsmApiException(105));
      final info105 = t.info(PhotoBackupDestination.synologyPhotos);
      expect(info105.gate, PhotoBackupTargetGate.noPermission);
      expect(info105.isHidden, isTrue, reason: '105 是确定性拒绝 → 隐藏');
      expect(info105.reason, isNotEmpty);

      t.noteError(PhotoBackupDestination.synologyPhotos, DsmApiException(160));
      expect(
        t.info(PhotoBackupDestination.synologyPhotos).gate,
        PhotoBackupTargetGate.noPermission,
        reason: '160 与 105 同为账号级拒绝',
      );
    });

    test('102/103 → 只影响该落点（缺服务），不隐藏', () async {
      final t = await targets(
        foto: await _fotoApi(table: _fotoTable),
        drive: await _driveApi(table: _driveTableWithPhotos),
      );
      t.noteError(PhotoBackupDestination.drive, DsmApiException(102));
      final drive = t.info(PhotoBackupDestination.drive);
      expect(drive.gate, PhotoBackupTargetGate.missingService);
      expect(drive.isHidden, isFalse, reason: '102 换台 NAS 可能就有 → 只置灰');
      expect(
        t.info(PhotoBackupDestination.synologyPhotos).isUsable,
        isTrue,
        reason: '一个落点缺服务不能牵连另一个',
      );

      t.resetGates();
      expect(
        t.info(PhotoBackupDestination.drive).isUsable,
        isTrue,
        reason: '重连后要能恢复',
      );
    });

    test('能力表里没有对应 API → 那个落点缺服务（另一个照常可用）', () async {
      final t = await targets(
        foto: await _fotoApi(
          table: {
            'SYNO.API.Info': {
              'path': 'query.cgi',
              'minVersion': 1,
              'maxVersion': 1,
            },
            // 故意不给 SYNO.Foto.Upload.Item
          },
        ),
        drive: await _driveApi(table: _driveTableWithPhotos),
      );
      expect(
        t.info(PhotoBackupDestination.synologyPhotos).gate,
        PhotoBackupTargetGate.missingService,
      );
      expect(
        t.info(PhotoBackupDestination.drive).gate,
        PhotoBackupTargetGate.ready,
      );
    });

    test('Drive 落点路径 = 官方 /mydrive/PhotoBackup/<设备名>（含清洗）', () {
      expect(
        DriveApi.photoBackupFolderPath('Pixel 8'),
        '/mydrive/PhotoBackup/Pixel_8',
      );
      expect(
        DriveApi.kDrivePhotoBackupRoot,
        '/mydrive/PhotoBackup',
        reason: '官方 Constants.BACKUP_PHOTO_PATH',
      );
      expect(
        DriveApi.photoBackupFolderPath(''),
        '/mydrive/PhotoBackup/Android',
      );
    });
  });

  // ------------------------------------------------------------------ 4. 去重

  group('去重（抽样 MD5 + 全文件 MD4）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('photo-dedup');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('抽样 MD5 = 官方 (1000+200)KB 窗口的最后 200KB', () async {
      expect(kSampledMd5WindowBytes, 1200 * 1024);
      expect(kSampledMd5TailBytes, 200 * 1024);

      // 官方读的是**文件头部** (1000+200)KB 这一段窗口，再取窗口的最后 200KB
      // （`MD5Utils.java:31-47`）。所以：
      //   * 偏移 0..1000KB 完全不同 → 不该影响结果；
      //   * 偏移 1000KB..1200KB 相同 → 抽样哈希必须相同；
      //   * 1200KB 之后的尾巴根本不在窗口里 → 也不该影响结果。
      final window = List<int>.generate(200 * 1024, (i) => i % 251);
      final tail = List<int>.filled(336 * 1024, 0x33);
      final a = File('${dir.path}/a.bin');
      final b = File('${dir.path}/b.bin');
      await a.writeAsBytes([
        ...List<int>.filled(1000 * 1024, 0x11),
        ...window,
        ...tail,
      ]);
      await b.writeAsBytes([
        ...List<int>.filled(1000 * 1024, 0x22),
        ...window,
        ...List<int>.filled(336 * 1024, 0x44),
      ]);
      expect(a.lengthSync(), 1536 * 1024);
      expect(b.lengthSync(), 1536 * 1024);
      const hasher = FilePhotoBackupHasher();
      final ha = await hasher.sampledMd5(a.path);
      final hb = await hasher.sampledMd5(b.path);
      expect(ha, isNotEmpty);
      expect(ha, hb, reason: '前 1000KB 与 1200KB 之后的尾巴都不该影响抽样结果');

      // 窗口里那 200KB 不同 → 抽样就不同
      final c = File('${dir.path}/c.bin');
      await c.writeAsBytes([
        ...List<int>.filled(1000 * 1024, 0x11),
        ...List<int>.filled(200 * 1024, 0x55),
        ...tail,
      ]);
      expect(await hasher.sampledMd5(c.path), isNot(ha));
    });

    test('抽样 MD5 的纯函数与文件实现一致；读不到文件回空串（不抛）', () async {
      // 300KB：比窗口短 → 整文件参与哈希
      final small = List<int>.generate(300 * 1024, (i) => (i * 7) % 256);
      final smallFile = File('${dir.path}/small.bin');
      await smallFile.writeAsBytes(small);
      const hasher = FilePhotoBackupHasher();
      expect(
        await hasher.sampledMd5(smallFile.path),
        sampledMd5OfWindow(Uint8List.fromList(small), fileLength: small.length),
      );

      // 1.5MB：文件实现读头 1.2MB 再取尾部 200KB；纯函数吃同一段窗口
      final big = List<int>.generate(1536 * 1024, (i) => (i * 13) % 256);
      final bigFile = File('${dir.path}/big.bin');
      await bigFile.writeAsBytes(big);
      expect(
        await hasher.sampledMd5(bigFile.path),
        sampledMd5OfWindow(
          Uint8List.fromList(big.sublist(0, kSampledMd5WindowBytes)),
          fileLength: big.length,
        ),
        reason: '纯函数与文件实现必须是同一套窗口语义',
      );

      expect(await hasher.sampledMd5('${dir.path}/missing.bin'), '');
      expect(await hasher.fullMd4('${dir.path}/missing.bin'), '');
    });

    test('全文件 MD4 用已知向量钉住（官方 FileInfo.hash 就是这个）', () {
      // RFC 1320 测试向量
      expect(
        fullMd4OfBytes(Uint8List.fromList(utf8.encode('abc'))),
        'a448017aaf21d8525fc10ae87aa6729d',
      );
      expect(
        fullMd4OfBytes(Uint8List.fromList(utf8.encode(''))),
        '31d6cfe0d16ae931b73c59d7e0c089c0',
      );
    });

    test('账本 token：算得出哈希时带大小后缀，算不出回落 stableKey', () {
      final asset = _asset('a.jpg', size: 1000);
      expect(
        PhotoBackupQueue.ledgerToken(asset, sampledMd5: 'deadbeef'),
        'md5:deadbeef|1000',
      );
      expect(
        PhotoBackupQueue.ledgerToken(asset, sampledMd5: ''),
        asset.stableKey,
      );
    });

    test('队列：抽样 MD5 命中账本 → 跳过（duplicateContent），不上传', () async {
      final media = _FakeMedia([_asset('a.jpg')]);
      final up = _FakeUploader();
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(doneKeys: {'md5:samemd5|1000'}),
      );
      final snapshot = await store.load();
      final queue = PhotoBackupQueue(
        media: media,
        uploader: up,
        store: store,
        snapshot: snapshot,
        hasher: _FakeHasher(sampled: {'a.jpg': 'samemd5'}),
      );
      queue.load(
        PhotoBackupPlanner.plan(
          assets: media.assets,
          doneKeys: const {},
          remote: const [],
        ),
      );
      queue.start();
      await _settle();
      expect(up.uploaded, isEmpty, reason: '同内容（改了名）不该重复传');
      expect(queue.counts.skipped, 1);
      expect(queue.items.single.skipReason, BackupSkipReason.duplicateContent);
    });

    test('队列：服务端全文件 MD4 相同 → 跳过（existsOnNas）并记进账本', () async {
      final media = _FakeMedia([_asset('a.jpg')]);
      final asset = media.assets.single;
      final up = _FakeUploader();
      final store = InMemoryPhotoBackupStore();
      final queue = PhotoBackupQueue(
        media: media,
        uploader: up,
        store: store,
        hasher: _FakeHasher(full: {'a.jpg': 'AABBCC'}),
        remoteHashes: {asset.remoteKey: 'aabbcc'},
      );
      queue.load(
        PhotoBackupPlanner.plan(
          assets: media.assets,
          doneKeys: const {},
          remote: const [],
        ),
      );
      queue.start();
      await _settle();
      expect(up.uploaded, isEmpty);
      expect(queue.items.single.skipReason, BackupSkipReason.existsOnNas);
      final saved = await store.load();
      expect(
        saved.doneKeys,
        contains(asset.stableKey),
        reason: '跳过也要记账，下次规划期就省掉一次哈希',
      );
    });

    test('队列：哈希相同但服务端没有这个文件 → 照传（抽样只用于本机去重）', () async {
      final media = _FakeMedia([_asset('a.jpg')]);
      final up = _FakeUploader();
      final queue = PhotoBackupQueue(
        media: media,
        uploader: up,
        store: InMemoryPhotoBackupStore(),
        hasher: _FakeHasher(sampled: {'a.jpg': 'samemd5'}),
      );
      queue.load(
        PhotoBackupPlanner.plan(
          assets: media.assets,
          doneKeys: const {},
          remote: const [],
        ),
      );
      queue.start();
      await _settle();
      expect(up.uploaded.single.name, 'a.jpg');
      expect(
        up.uploaded.single.destination,
        PhotoBackupDestination.synologyPhotos,
      );
    });
  });

  // --------------------------------------------------- 5. 官方同构：范围/并发

  group('官方同构（只扫 DCIM + 串行 1）', () {
    test('isDcimAsset：DCIM 任意层级算，其它目录不算', () {
      expect(PhotoBackupPlanner.isDcimAsset(_asset('a.jpg')), isTrue);
      expect(
        PhotoBackupPlanner.isDcimAsset(_asset('a.jpg', path: 'dcim/Camera')),
        isTrue,
        reason: '大小写不敏感',
      );
      expect(
        PhotoBackupPlanner.isDcimAsset(
          _asset('a.jpg', path: 'Pictures/Screenshots'),
        ),
        isFalse,
      );
      expect(
        PhotoBackupPlanner.isDcimAsset(_asset('a.jpg', path: 'Download')),
        isFalse,
      );
    });

    test('plan(dcimOnly: true) 范围外的项**不进计划**（不是标跳过）', () {
      final assets = [
        _asset('camera.jpg'),
        _asset('screenshot.png', path: 'Pictures/Screenshots'),
        _asset('download.jpg', path: 'Download'),
      ];
      final out = PhotoBackupPlanner.plan(
        assets: assets,
        doneKeys: const {},
        remote: const [],
        dcimOnly: true,
      );
      expect(out.map((i) => i.asset.displayName), ['camera.jpg']);
      expect(
        PhotoBackupPlanner.plan(
          assets: assets,
          doneKeys: const {},
          remote: const [],
        ).length,
        3,
        reason: '默认（中立）不过滤',
      );
    });

    test('快照默认 dcimOnly=true（功能层官方同构）', () {
      expect(const PhotoBackupSnapshot().dcimOnly, isTrue);
      expect(
        const PhotoBackupSnapshot().destination,
        PhotoBackupDestination.synologyPhotos,
      );
    });

    test('编排器恒为串行 1：两个文件并发上限 = 1，落点传给上传器', () async {
      final media = _FakeMedia([_asset('a.jpg'), _asset('b.jpg')]);
      final up = _FakeUploader();
      final runner = PhotoBackupRunner(
        media: media,
        uploader: up,
        store: InMemoryPhotoBackupStore(
          const PhotoBackupSnapshot(
            destination: PhotoBackupDestination.drive,
            targetFolderId: '/mydrive/PhotoBackup/Pixel',
          ),
        ),
        targets: PhotoBackupTargets(
          fotoOf: () => null,
          driveOf: () => null,
          deviceNameOf: () => 'Pixel',
        ),
        maxConcurrent: 1,
      );
      final report = await runner.run(
        const PhotoBackupSnapshot(
          destination: PhotoBackupDestination.drive,
          targetFolderId: '/mydrive/PhotoBackup/Pixel',
        ),
      );
      expect(report.ok, isTrue);
      expect(report.done, 2);
      expect(up.maxActive, 1, reason: '官方单线程池：串行，不是并发 2');
      expect(
        up.uploaded.every((u) => u.destination == PhotoBackupDestination.drive),
        isTrue,
      );
      expect(
        up.uploaded.every((u) => u.folderId == '/mydrive/PhotoBackup/Pixel'),
        isTrue,
      );
    });

    test('编排器的 prepare 只枚举一次本机相册', () async {
      final media = _FakeMedia([_asset('a.jpg')]);
      final runner = PhotoBackupRunner(
        media: media,
        uploader: _FakeUploader(),
        store: InMemoryPhotoBackupStore(
          const PhotoBackupSnapshot(targetFolderId: '7'),
        ),
        targets: PhotoBackupTargets(
          fotoOf: () => null,
          driveOf: () => null,
          deviceNameOf: () => 'Pixel',
        ),
      );
      final prepared = await runner.prepare(
        const PhotoBackupSnapshot(targetFolderId: '7'),
      );
      expect(prepared.error, isNull);
      expect(media.listCalls, 1);
      prepared.queue!.dispose();
    });

    test('★★★ D77：450 张 ⇒ 分 3 批（200/200/50），每批 offset 正确', () async {
      // 官方（`drive-parity-audit.md:262`）：200 个 id 一批、上限 5000。
      final media = _PagedMedia(List.generate(450, (i) => _asset('p$i.jpg')));
      final runner = PhotoBackupRunner(
        media: media,
        uploader: _FakeUploader(),
        store: InMemoryPhotoBackupStore(
          const PhotoBackupSnapshot(targetFolderId: '7'),
        ),
        targets: PhotoBackupTargets(
          fotoOf: () => null,
          driveOf: () => null,
          deviceNameOf: () => 'Pixel',
        ),
      );
      final prepared = await runner.prepare(
        const PhotoBackupSnapshot(targetFolderId: '7'),
      );
      expect(prepared.error, isNull);
      expect(media.calls, [
        (200, 0),
        (200, 200),
        (200, 400), // 最后一批只有 50 个 ⇒ 不满 ⇒ 停
      ]);
      prepared.queue!.dispose();
    });

    test('★★★ D77：总上限生效（assetLimit=250 截断在 250）', () async {
      final media = _PagedMedia(List.generate(450, (i) => _asset('q$i.jpg')));
      final runner = PhotoBackupRunner(
        media: media,
        uploader: _FakeUploader(),
        store: InMemoryPhotoBackupStore(
          const PhotoBackupSnapshot(targetFolderId: '7'),
        ),
        targets: PhotoBackupTargets(
          fotoOf: () => null,
          driveOf: () => null,
          deviceNameOf: () => 'Pixel',
        ),
        assetLimit: 250,
      );
      final prepared = await runner.prepare(
        const PhotoBackupSnapshot(targetFolderId: '7'),
      );
      expect(prepared.error, isNull);
      // 拿满 250 后停：两批（200 + 50）
      expect(media.calls.length, 2);
      expect(media.calls.last, (200, 200));
      prepared.queue!.dispose();
    });

    test('★★★ D70：wifiOnly + 运行中网络变差 ⇒ 自动暂停、不派新任务', () async {
      var networkOk = false; // 一开始就不给网（模拟"起跑后切到 4G"）
      final media = _FakeMedia([_asset('a.jpg'), _asset('b.jpg')]);
      final up = _FakeUploader();
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(wifiOnly: true, targetFolderId: '7'),
      );
      final queue = PhotoBackupQueue(
        media: media,
        uploader: up,
        store: store,
        snapshot: await store.load(),
        connectionGate: () async => networkOk,
      );
      queue.load(
        PhotoBackupPlanner.plan(
          assets: media.assets,
          doneKeys: const {},
          remote: const [],
        ),
      );
      queue.start();
      await _settle();
      expect(queue.paused, isTrue, reason: '★ 运行中门禁不过 ⇒ 自动暂停（旧行为会继续传）');
      expect(up.uploaded, isEmpty);

      // 网络恢复（回 Wi-Fi）⇒ resume 续跑
      networkOk = true;
      queue.resume();
      await _settle();
      expect(queue.paused, isFalse);
      expect(up.uploaded, hasLength(2));
      queue.dispose();
    });

    test('★★★ D70：wifiOnly + 网络一直可用 ⇒ 正常传完（gate 不误伤）', () async {
      final media = _FakeMedia([_asset('c.jpg')]);
      final up = _FakeUploader();
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(wifiOnly: true, targetFolderId: '7'),
      );
      final queue = PhotoBackupQueue(
        media: media,
        uploader: up,
        store: store,
        snapshot: await store.load(),
        connectionGate: () async => true,
      );
      queue.load(
        PhotoBackupPlanner.plan(
          assets: media.assets,
          doneKeys: const {},
          remote: const [],
        ),
      );
      queue.start();
      await _settle();
      expect(up.uploaded, hasLength(1));
      expect(queue.paused, isFalse);
      queue.dispose();
    });

    test('没连上时 prepare 给 not-connected（页面才好显示"还没连接"）', () async {
      final media = _FakeMedia([_asset('a.jpg')]);
      final runner = PhotoBackupRunner(
        media: media,
        uploader: _FakeUploader(),
        store: InMemoryPhotoBackupStore(),
        targets: PhotoBackupTargets(
          fotoOf: () => null,
          driveOf: () => null,
          deviceNameOf: () => 'Pixel',
        ),
      );
      final prepared = await runner.prepare(const PhotoBackupSnapshot());
      expect(prepared.queue, isNull);
      expect(prepared.error, 'not-connected');
    });
  });

  // ------------------------------------------------------- 6. 后台入口契约

  group('后台入口（WorkManager → Dart）', () {
    test('参数解析 + 报告序列化：真的跑了 Dart 备份而不是假装成功', () async {
      final media = _FakeMedia([_asset('a.jpg')]);
      final up = _FakeUploader();
      final report = await runPhotoBackupInBackground(
        const {
          'destination': 'drive',
          'chargeOnly': true,
          'screenOffOnly': true,
          'wifiOnly': false,
          // 原生 `PhotoBackupPlugin` 填的 `Build.MODEL`
          'device': 'Pixel 8',
        },
        open: (device) async => PhotoBackupBackgroundContext(
          store: InMemoryPhotoBackupStore(
            const PhotoBackupSnapshot(
              destination: PhotoBackupDestination.drive,
              targetFolderId: '/mydrive/PhotoBackup/Pixel_8',
            ),
          ),
          runner: PhotoBackupRunner(
            media: media,
            uploader: up,
            store: InMemoryPhotoBackupStore(
              const PhotoBackupSnapshot(
                destination: PhotoBackupDestination.drive,
                targetFolderId: '/mydrive/PhotoBackup/Pixel_8',
              ),
            ),
            targets: PhotoBackupTargets(
              fotoOf: () => null,
              driveOf: () => null,
              deviceNameOf: () => device,
            ),
          ),
          close: () async {},
        ),
      );
      expect(report['ok'], isTrue);
      expect(report['destination'], 'drive');
      expect(report['done'], 1);
      expect(report['failed'], 0);
      expect(report['total'], 1);
      expect(up.uploaded.single.folderId, '/mydrive/PhotoBackup/Pixel_8');
      expect(up.uploaded.single.destination, PhotoBackupDestination.drive);
    });

    test('没有可静默重登的会话 → no-saved-session（不清数据、不假装成功）', () async {
      final report = await runPhotoBackupInBackground(const {
        'destination': 'synology_photos',
        'device': 'Pixel',
      }, open: (device) async => null);
      expect(report['ok'], isFalse);
      expect(report['error'], 'no-saved-session');
      expect(report['done'], 0);
      expect(report['total'], 0);
    });

    test('报告 map 往返（原生读 ok/done/total/skipped/failed）', () {
      const report = PhotoBackupRunReport(
        destination: PhotoBackupDestination.drive,
        total: 3,
        done: 2,
        failed: 1,
        skipped: 0,
      );
      final back = PhotoBackupRunReport.fromMap(report.toMap());
      expect(back.destination, PhotoBackupDestination.drive);
      expect(back.total, 3);
      expect(back.done, 2);
      expect(back.failed, 1);
      expect(back.ok, isTrue);

      final bad = PhotoBackupRunReport.fromMap(const {'error': 'boom'});
      expect(bad.ok, isFalse);
      expect(bad.error, 'boom');
      expect(bad.destination, PhotoBackupDestination.synologyPhotos);
    });

    test('后台通道名/方法与原生 Kotlin 常量对齐（改了就静默失联）', () {
      expect(kPhotoBackupChannel, 'synhub/photo_backup');
      expect(kPhotoBackupBackgroundChannel, 'synhub/photo_backup_bg');
      expect(kPhotoBackupCallbackName, 'photoBackupBackgroundMain');
    });

    test('runBackup 的参数名与原生一致（device 不能漏）', () async {
      Map<String, Object?>? seen;
      final handler = _RecordingHandler((args) {
        seen = args;
        return const <String, Object?>{'ok': true};
      });
      const channel = MethodChannel(kPhotoBackupBackgroundChannel);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'runBackup') return null;
        return handler.call((call.arguments as Map?)?.cast<String, Object?>());
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await channel.invokeMethod<Map<Object?, Object?>>('runBackup', {
        'destination': 'drive',
        'chargeOnly': true,
        'screenOffOnly': true,
        'wifiOnly': false,
        'device': 'Pixel 8',
      });
      expect(seen, isNotNull);
      expect(seen!.keys.toSet(), {
        'destination',
        'chargeOnly',
        'screenOffOnly',
        'wifiOnly',
        'device',
      }, reason: '原生 Kotlin 传的就是这五个 key');
      expect(seen!['device'], 'Pixel 8');
    });
  });

  // ------------------------------------------------------- 7. 前台/后台互斥

  group('前台与后台互斥', () {
    test('前台跑之前开、跑完关（原生 Worker 靠这个标志让路）', () async {
      final platform = _FakePlatform();
      final media = _FakeMedia([_asset('a.jpg')]);
      final runner = PhotoBackupRunner(
        media: media,
        uploader: _FakeUploader(),
        store: InMemoryPhotoBackupStore(
          const PhotoBackupSnapshot(targetFolderId: '7'),
        ),
        targets: PhotoBackupTargets(
          fotoOf: () => null,
          driveOf: () => null,
          deviceNameOf: () => 'Pixel',
        ),
      );

      // 页面里的顺序：reportForeground(true) → start → onFinished 里 false
      await platform.reportForeground(true);
      final report = await runner.run(
        const PhotoBackupSnapshot(targetFolderId: '7'),
      );
      await platform.reportForeground(false);
      expect(report.done, 1);
      expect(platform.foreground, [true, false]);
    });

    test('排程参数（开关/约束/落点）逐项透传给原生', () async {
      final platform = _FakePlatform();
      await platform.setSchedule(
        enabled: true,
        chargeOnly: true,
        screenOffOnly: true,
        wifiOnly: true,
        destination: PhotoBackupDestination.drive,
      );
      expect(platform.lastEnabled, isTrue);
      expect(platform.lastChargeOnly, isTrue);
      expect(platform.lastScreenOffOnly, isTrue);
      expect(platform.lastWifiOnly, isTrue);
      expect(platform.lastDestination, PhotoBackupDestination.drive);
      expect(platform.state.scheduled, isTrue);
      expect(platform.state.destination, PhotoBackupDestination.drive);

      // 关掉自动备份 = 撤排程
      await platform.setSchedule(
        enabled: false,
        chargeOnly: true,
        screenOffOnly: true,
        wifiOnly: true,
        destination: PhotoBackupDestination.drive,
      );
      expect(platform.state.scheduled, isFalse);
    });

    test('不支持的平台一律"没排上"（绝不假装）', () async {
      const platform = UnsupportedPhotoBackupPlatform();
      final status = await platform.status();
      expect(status.supported, isFalse);
      expect(status.scheduled, isFalse);
      expect(
        await platform.setSchedule(
          enabled: true,
          chargeOnly: false,
          screenOffOnly: false,
          wifiOnly: false,
          destination: PhotoBackupDestination.drive,
        ),
        isFalse,
      );
    });
  });

  // ---------------------------------------------- 8. 「仅充电」是硬约束

  group('仅充电（前台也不许硬闯）', () {
    test('充电状态从原生 status 来；未充电时该被拦', () {
      const charging = PhotoBackupPlatformStatus(
        supported: true,
        charging: true,
      );
      const notCharging = PhotoBackupPlatformStatus(
        supported: true,
        charging: false,
      );
      expect(_shouldRunChargeOnly(true, charging), isTrue);
      expect(_shouldRunChargeOnly(true, notCharging), isFalse);
      expect(
        _shouldRunChargeOnly(false, notCharging),
        isTrue,
        reason: '没开「仅充电」就不拦',
      );
    });

    test('status map 解析充电/息屏/设备名/上次结果', () {
      final s = PhotoBackupPlatformStatus.fromMap(const {
        'supported': true,
        'scheduled': true,
        'charging': true,
        'screenInteractive': false,
        'deviceName': 'Pixel 8',
        'lastResult': '完成 3 / 跳过 1 / 失败 0',
        'destination': 'drive',
        'enabled': true,
        'chargeOnly': true,
        'screenOffOnly': true,
        'wifiOnly': false,
      });
      expect(s.supported, isTrue);
      expect(s.scheduled, isTrue);
      expect(s.charging, isTrue);
      expect(s.screenInteractive, isFalse);
      expect(s.deviceName, 'Pixel 8');
      expect(s.lastResult, contains('完成 3'));
      expect(s.destination, PhotoBackupDestination.drive);
      expect(s.chargeOnly, isTrue);
      expect(s.screenOffOnly, isTrue);
    });
  });

  // ------------------------------------------------- 9. 页面（备份页）集成

  group('备份页：落点选择 / 后台卡片 / 仅充电拦截', () {
    Future<Widget> page({
      required InMemoryPhotoBackupStore store,
      required _FakePlatform platform,
      _FakeUploader? uploader,
      List<DeviceMediaAsset>? assets,
      PhotoBackupPlatformStatus? status,
      PhotoBackupSnapshot? initial,
    }) async {
      if (status != null) platform.state = status;
      final foto = await _fotoApi(table: _fotoTable);
      final drive = await _driveApi(table: _driveTableWithPhotos);
      final snapshot = initial ?? await store.load();
      final container = ProviderContainer(
        overrides: [
          fotoApiProvider.overrideWithValue(foto),
          deviceMediaLibraryProvider.overrideWithValue(
            _FakeMedia(assets ?? [_asset('a.jpg')]),
          ),
          photoBackupStoreProvider.overrideWithValue(store),
          photoBackupHasherProvider.overrideWithValue(_FakeHasher()),
          photoBackupPlatformProvider.overrideWithValue(platform),
          photoBackupUploaderProvider.overrideWithValue(
            uploader ?? _FakeUploader(),
          ),
          photoBackupTargetsProvider.overrideWithValue(
            PhotoBackupTargets(
              fotoOf: () => foto,
              driveOf: () => drive,
              deviceNameOf: () => 'Pixel 8',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(snapshot.destination, isNotNull);
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: PhotoBackupPage()),
      );
    }

    testWidgets('落点单选：两个选项都在，Drive 显示官方路径', (tester) async {
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
        ),
      );
      final platform = _FakePlatform();
      await tester.pumpWidget(await page(store: store, platform: platform));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byKey(const Key('photo-backup-destination-drive')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('photo-backup-destination-synology_photos')),
        findsOneWidget,
      );
      expect(
        find.textContaining('/mydrive/PhotoBackup/Pixel_8'),
        findsOneWidget,
        reason: 'Drive 落点路径必须按官方 /mydrive/PhotoBackup/<设备名> 显示',
      );
      // 当前是 Photos：目标卡显示已选相册
      expect(find.text('目标：手机备份'), findsOneWidget);
    });

    testWidgets('切到 Drive → 目标换成设备目录；切回 Photos → 原相册还在', (tester) async {
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
        ),
      );
      final platform = _FakePlatform();
      await tester.pumpWidget(await page(store: store, platform: platform));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('photo-backup-destination-drive')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('目标：Pixel_8'), findsOneWidget);
      expect(
        platform.lastDestination,
        PhotoBackupDestination.drive,
        reason: '落点变化要透传给原生排程',
      );

      await tester.tap(
        find.byKey(const Key('photo-backup-destination-synology_photos')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('目标：手机备份'),
        findsOneWidget,
        reason: '切回来必须还是原来那个相册（两个落点各自记账）',
      );
      expect(platform.lastDestination, PhotoBackupDestination.synologyPhotos);
    });

    // ---- 真机同构：`SynologyChatApp` 会调 setCurrentText，dataText 从此返回 ARB
    // ---- 模板；带占位符的 key 若不在调用点替换，就会把 `{path}` 画到屏幕上。
    testWidgets('装了翻译表后落点路径不得显示 {path}（真机缺陷复现位）', (tester) async {
      addTearDown(() => setCurrentText(AppTextZh()));
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
        ),
      );
      final platform = _FakePlatform();
      setCurrentText(AppTextZh());
      await tester.pumpWidget(await page(store: store, platform: platform));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('photo-backup-destination-drive')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.textContaining('{path}'),
        findsNothing,
        reason:
            'pbTargetPathLabel 的 {path} 必须在调用点替换，'
            '否则真机上会显示「落点路径：{path}」',
      );
      expect(
        find.textContaining('/mydrive/PhotoBackup/Pixel_8'),
        findsOneWidget,
        reason: 'Drive 落点路径要显示真实路径',
      );
    });

    testWidgets('英文翻译表下落点路径同样不得显示 {path}', (tester) async {
      addTearDown(() => setCurrentText(AppTextZh()));
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
        ),
      );
      final platform = _FakePlatform();
      setCurrentText(AppTextEn());
      await tester.pumpWidget(await page(store: store, platform: platform));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('photo-backup-destination-drive')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('{path}'), findsNothing);
      expect(find.textContaining('Destination path:'), findsOneWidget);
    });

    testWidgets('装了翻译表后后台卡片不得显示 {name}/{result}', (tester) async {
      addTearDown(() => setCurrentText(AppTextZh()));
      final store = InMemoryPhotoBackupStore(const PhotoBackupSnapshot());
      final platform = _FakePlatform();
      setCurrentText(AppTextZh());
      await tester.pumpWidget(
        await page(
          store: store,
          platform: platform,
          status: const PhotoBackupPlatformStatus(
            supported: true,
            scheduled: true,
            charging: true,
            screenInteractive: false,
            deviceName: 'Pixel 8',
            lastResult: '完成 3 / 跳过 1 / 失败 0',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.textContaining('{name}'),
        findsNothing,
        reason: 'pbBackgroundDevice 的 {name} 必须在调用点替换',
      );
      expect(find.textContaining('{result}'), findsNothing);
      expect(find.textContaining('本机设备名：Pixel 8'), findsOneWidget);
      expect(find.textContaining('上次后台结果：完成 3'), findsOneWidget);
    });

    testWidgets('后台卡片：排程/充电/息屏/设备名 + 立即排队按钮', (tester) async {
      final store = InMemoryPhotoBackupStore(const PhotoBackupSnapshot());
      final platform = _FakePlatform();
      await tester.pumpWidget(
        await page(
          store: store,
          platform: platform,
          status: const PhotoBackupPlatformStatus(
            supported: true,
            scheduled: true,
            charging: true,
            screenInteractive: false,
            deviceName: 'Pixel 8',
            lastResult: '完成 3 / 跳过 1 / 失败 0',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('photo-backup-background')), findsOneWidget);
      expect(find.textContaining('已开启系统级后台排程'), findsOneWidget);
      expect(find.text('正在充电'), findsOneWidget);
      expect(find.textContaining('屏幕已熄'), findsOneWidget);
      expect(find.textContaining('本机设备名：Pixel 8'), findsOneWidget);
      expect(find.textContaining('上次后台结果'), findsOneWidget);
      expect(
        find.textContaining('已开启系统级后台排程'),
        findsOneWidget,
        reason: '排程状态要如实显示，不假装',
      );

      await tester.ensureVisible(find.byKey(const Key('photo-backup-run-now')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-backup-run-now')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(platform.calls, contains('runNow'), reason: '「立即排队跑一次」必须真的调原生排一次');
    });

    testWidgets('平台不支持 → 如实说"只在应用打开时备份"，不给假按钮', (tester) async {
      final store = InMemoryPhotoBackupStore(const PhotoBackupSnapshot());
      final platform = _FakePlatform();
      await tester.pumpWidget(
        await page(
          store: store,
          platform: platform,
          status: const PhotoBackupPlatformStatus(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('不支持系统级后台排程'), findsOneWidget);
      expect(find.byKey(const Key('photo-backup-run-now')), findsNothing);
    });

    testWidgets('「仅充电」开着且未充电 → 点开始不传，明确提示', (tester) async {
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
          chargeOnly: true,
        ),
      );
      final platform = _FakePlatform();
      final uploader = _FakeUploader();
      await tester.pumpWidget(
        await page(
          store: store,
          platform: platform,
          uploader: uploader,
          status: const PhotoBackupPlatformStatus(
            supported: true,
            charging: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('photo-backup-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(uploader.uploaded, isEmpty, reason: '「仅充电」是硬约束');
      expect(find.textContaining('仅充电时备份'), findsWidgets);
    });

    // ★★ D80「电池优化引导」：口径 = 只有**还没进白名单**才提示，
    // 进了一键申请就真调原生接口（`requestIgnoreBatteryOptimization`）。
    testWidgets('★★ D80：未加白名单 → 显示引导，点「去加入白名单」真调原生', (tester) async {
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
        ),
      );
      final platform = _FakePlatform();
      await tester.pumpWidget(
        await page(
          store: store,
          platform: platform,
          status: const PhotoBackupPlatformStatus(
            supported: true,
            batteryOptimizationIgnored: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final btn = find.byKey(const Key('photo-backup-battery'));
      expect(btn, findsOneWidget);
      await tester.ensureVisible(btn);
      await tester.pumpAndSettle();
      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(
        platform.calls,
        contains('requestIgnoreBatteryOptimization'),
        reason: '引导按钮必须真调原生申请，不能只弹一句话',
      );
    });

    testWidgets('★★ D80：已在白名单 → 不再显示引导（不啰嗦）', (tester) async {
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
        ),
      );
      final platform = _FakePlatform();
      await tester.pumpWidget(
        await page(
          store: store,
          platform: platform,
          status: const PhotoBackupPlatformStatus(
            supported: true,
            batteryOptimizationIgnored: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('photo-backup-battery')), findsNothing);
    });

    testWidgets('开着自动备份打开页面 → 对一次排程（开机/升级后自愈）', (tester) async {
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
          enabled: true,
          chargeOnly: true,
          dcimOnly: true,
        ),
      );
      final platform = _FakePlatform();
      await tester.pumpWidget(await page(store: store, platform: platform));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(platform.calls, contains('registerCallback'));
      expect(platform.calls, contains('setSchedule'));
      expect(platform.lastEnabled, isTrue);
      expect(platform.lastChargeOnly, isTrue);
      expect(platform.lastDestination, PhotoBackupDestination.synologyPhotos);
    });

    testWidgets('前台跑一轮 → 先 reportForeground(true) 再 (false)（不跟后台双跑）', (
      tester,
    ) async {
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
        ),
      );
      final platform = _FakePlatform();
      final uploader = _FakeUploader();
      await tester.pumpWidget(
        await page(store: store, platform: platform, uploader: uploader),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('photo-backup-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(uploader.uploaded.map((e) => e.name), ['a.jpg']);
      expect(uploader.uploaded.single.folderId, '7');
      expect(platform.foreground.first, isTrue);
      expect(platform.foreground.last, isFalse, reason: '跑完必须松掉互斥标志，否则后台永远让路');
    });
  });
}

/// 把队列里的微任务全部跑完（队列不用 Timer，纯 Future）。
Future<void> _settle([int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 页面 `_start` 里那条判定的纯函数化（同一份口径，见 `photo_backup_page.dart`）。
bool _shouldRunChargeOnly(bool chargeOnly, PhotoBackupPlatformStatus status) =>
    !chargeOnly || status.charging;

class _RecordingHandler {
  _RecordingHandler(this.onCall);

  final Map<String, Object?> Function(Map<String, Object?> args) onCall;

  Map<String, Object?> call(Map<String, Object?>? args) =>
      onCall(args ?? const {});
}

// ★★★ D77（第 101 轮）：分页枚举 —— 官方 200/批、上限 5000
// （`drive-parity-audit.md:262`，`PBTaskManager.java:100-121`）。
// 旧实现单次 limit:2000 ⇒ 超过 2000 张永远扫不全。
class _PagedMedia extends _FakeMedia {
  _PagedMedia(super.assets);

  final List<(int, int)> calls = [];

  @override
  Future<List<DeviceMediaAsset>> list({
    bool includeVideos = true,
    int limit = 500,
    int offset = 0,
  }) async {
    calls.add((limit, offset));
    return super.list(
      includeVideos: includeVideos,
      limit: limit,
      offset: offset,
    );
  }
}
