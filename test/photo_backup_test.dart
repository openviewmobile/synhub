// 相册「手机自动备份」离线测试。
//
// 覆盖四层：
//   1. **去重判定**（`PhotoBackupPlanner`）：同名不同内容 / 同内容不同名 /
//      已在 NAS 上 / 本地记账过 / 视频排除；
//   2. **队列状态机**（`PhotoBackupQueue`）：并发上限、暂停/继续、取消、
//      自动重试、失败隔离、账本落盘；
//   3. **接口层**（`FotoApi`）：`upload_to_folder` / `upload` 的**请求拼装**
//      （逐字对照官方 Web 前端）、`backup_check` 的解析与 `upload_check` 回落；
//   4. **页面层**（`PhotoBackupPage`）：权限被拒路径、目标相册、空态、进度、
//      上传时带的目标 folder id。
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/network_type.dart';
import 'package:synhub/src/data/drive_api.dart' show DriveBackupStructure;
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/media/device_media_library.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notifications/notification_service.dart'
    show networkTypeProbeProvider;
import 'package:synhub/src/features/photos/photo_backup_page.dart';
import 'package:synhub/src/features/photos/photo_backup_providers.dart';
import 'package:synhub/src/features/photos/photo_backup_queue.dart';
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _fotoTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Browse.Folder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Browse.GeneralTag': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Upload.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 8,
  },
};

/// 一条假的本机相册条目。
///
/// 默认 `relativePath` 是 **`DCIM/Camera`**（真实相机的 MediaStore
/// `RELATIVE_PATH`）—— 官方相机备份的范围**恒为 DCIM**
/// （`PhotoBackupSettings.java:143-144` + `PBUtils.java:42-45`），我们的功能默认
/// 也是 DCIM-only，所以页面用例必须用 DCIM 里的文件才代表真实场景。
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

/// 假媒体源：可控权限、可控枚举结果、materialize 回一个假路径。
class FakeMediaLibrary implements DeviceMediaLibrary {
  FakeMediaLibrary(
    this.assets, {
    this.permission = MediaPermission.granted,
    this.onMaterialize,
  });

  final List<DeviceMediaAsset> assets;
  MediaPermission permission;

  /// 材料化时抛错（测失败隔离）
  void Function(DeviceMediaAsset asset)? onMaterialize;
  int materializeCalls = 0;
  int listCalls = 0;

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
    return [
      for (final a in assets)
        if (includeVideos || !a.isVideo) a,
    ];
  }

  @override
  Future<String?> materialize(DeviceMediaAsset asset) async {
    materializeCalls++;
    onMaterialize?.call(asset);
    return '/tmp/fake/${asset.displayName}';
  }
}

/// 假上传器：记录每次上传；可设并发闸门 / 指定失败文件名。
class FakeUploader implements PhotoBackupUploader {
  /// 每次上传的记录（`{name, folderId, path}`）
  final uploaded = <({String name, String folderId, String path})>[];

  /// 这些文件名会上传失败
  final Set<String> failNames = {};
  Completer<void>? gate;
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
      // 让并发真的重叠：不给这一步的话 async 函数会同步跑完，测不出上限
      await Future<void>.delayed(Duration.zero);
      final currentGate = gate;
      if (currentGate != null) await currentGate.future;
      if (failNames.contains(asset.displayName)) {
        throw StateError('boom');
      }
      onProgress?.call(50, 100);
      uploaded.add((
        name: asset.displayName,
        folderId: targetFolderId,
        path: localPath,
      ));
      onProgress?.call(100, 100);
      return 'unit-${asset.displayName}';
    } finally {
      active--;
    }
  }
}

class FakeNetworkProbe implements NetworkTypeProbe {
  FakeNetworkProbe(this.type);

  final NetworkType type;

  @override
  Future<NetworkType> current() async => type;
}

/// 让队列里的微任务全部跑完（队列不用 Timer，纯 Future）
Future<void> _settle([int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

void main() {
  group('去重计划', () {
    test('同名同大小 = 已在 NAS → 跳过', () {
      final plan = PhotoBackupPlanner.plan(
        assets: [_asset('a.jpg', size: 100)],
        doneKeys: const {},
        remote: const [RemotePhotoEntry(name: 'a.jpg', size: 100)],
      );
      expect(plan.single.state, BackupItemState.skipped);
      expect(plan.single.skipReason, BackupSkipReason.existsOnNas);
    });

    test('同名不同大小 = 新内容 → 要传', () {
      final plan = PhotoBackupPlanner.plan(
        assets: [_asset('a.jpg', size: 200)],
        doneKeys: const {},
        remote: const [RemotePhotoEntry(name: 'a.jpg', size: 100)],
      );
      expect(plan.single.state, BackupItemState.pending);
    });

    test('同内容不同名（客户端认不出哈希）→ 按新文件传，交给服务端 duplicate_hash', () {
      final plan = PhotoBackupPlanner.plan(
        assets: [_asset('b.jpg', size: 100)],
        doneKeys: const {},
        remote: const [RemotePhotoEntry(name: 'a.jpg', size: 100)],
      );
      expect(plan.single.state, BackupItemState.pending);
    });

    test('本地账本已记过 → 跳过', () {
      final asset = _asset('a.jpg', size: 100);
      final plan = PhotoBackupPlanner.plan(
        assets: [asset],
        doneKeys: {asset.stableKey},
        remote: const [],
      );
      expect(plan.single.skipReason, BackupSkipReason.alreadyDone);
    });

    test('不含视频时视频跳过，图片照传', () {
      final plan = PhotoBackupPlanner.plan(
        assets: [_asset('v.mp4', video: true), _asset('a.jpg')],
        doneKeys: const {},
        remote: const [],
        includeVideos: false,
      );
      expect(plan.first.skipReason, BackupSkipReason.videoExcluded);
      expect(plan.last.state, BackupItemState.pending);
    });
  });

  group('本地账本', () {
    test('encode/decode 往返', () {
      const snap = PhotoBackupSnapshot(
        doneKeys: {'x', 'y'},
        lastFinishedAtMs: 123,
        targetFolderId: '7',
        targetFolderName: '手机备份',
        includeVideos: false,
        wifiOnly: true,
        enabled: true,
      );
      final back = PhotoBackupSnapshot.decode(snap.encode());
      expect(back.doneKeys, {'x', 'y'});
      expect(back.lastFinishedAtMs, 123);
      expect(back.targetFolderId, '7');
      expect(back.includeVideos, isFalse);
      expect(back.wifiOnly, isTrue);
      expect(back.enabled, isTrue);
    });

    test('脏数据当"没记过"，不炸', () {
      expect(PhotoBackupSnapshot.decode('{oops').doneKeys, isEmpty);
      expect(PhotoBackupSnapshot.decode('[]').targetFolderId, '');
      expect(PhotoBackupSnapshot.decode(null).lastFinishedAtMs, 0);
    });
  });

  group('队列状态机', () {
    test('并发上限：最多同时跑 maxConcurrent 个', () async {
      final media = FakeMediaLibrary([
        for (var i = 0; i < 5; i++) _asset('p$i.jpg'),
      ]);
      final uploader = FakeUploader();
      final queue = PhotoBackupQueue(
        media: media,
        uploader: uploader,
        store: InMemoryPhotoBackupStore(),
        maxConcurrent: 2,
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
      expect(uploader.maxActive, 2, reason: '受限并发不能超过 2');
      expect(queue.counts.done, 5);
      expect(queue.running, isFalse);
    });

    test('暂停后不再调度，继续后跑完', () async {
      final media = FakeMediaLibrary([
        for (var i = 0; i < 3; i++) _asset('p$i.jpg'),
      ]);
      final uploader = FakeUploader()..gate = Completer<void>();
      final queue = PhotoBackupQueue(
        media: media,
        uploader: uploader,
        store: InMemoryPhotoBackupStore(),
        maxConcurrent: 1,
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
      expect(uploader.uploaded, isEmpty, reason: '第一张被 gate 卡住');
      expect(queue.counts.uploading, 1);
      queue.pause();
      uploader.gate!.complete();
      await _settle();
      expect(uploader.uploaded.length, 1, reason: '暂停后不再发新的');
      expect(queue.paused, isTrue);
      expect(queue.counts.pending, 2);
      queue.resume();
      await _settle();
      expect(uploader.uploaded.length, 3);
      expect(queue.counts.done, 3);
    });

    test('取消：还没开始的标失败(cancelled)，在传的让它结束', () async {
      final media = FakeMediaLibrary([
        for (var i = 0; i < 3; i++) _asset('p$i.jpg'),
      ]);
      final uploader = FakeUploader()..gate = Completer<void>();
      final queue = PhotoBackupQueue(
        media: media,
        uploader: uploader,
        store: InMemoryPhotoBackupStore(),
        maxConcurrent: 1,
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
      queue.cancel();
      expect(queue.counts.pending, 0);
      expect(queue.counts.failed, 2);
      expect(queue.failedItems.every((i) => i.error == 'cancelled'), isTrue);
      uploader.gate!.complete();
      await _settle();
      expect(queue.counts.done, 1);
      expect(queue.running, isFalse);
    });

    test('失败隔离 + 自动重试一次：坏文件不影响别人', () async {
      final media = FakeMediaLibrary([_asset('bad.jpg'), _asset('good.jpg')]);
      final uploader = FakeUploader()..failNames.add('bad.jpg');
      final queue = PhotoBackupQueue(
        media: media,
        uploader: uploader,
        store: InMemoryPhotoBackupStore(),
        maxConcurrent: 2,
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
      expect(queue.counts.done, 1);
      expect(queue.counts.failed, 1);
      final bad = queue.failedItems.single;
      expect(bad.asset.displayName, 'bad.jpg');
      expect(bad.attempts, 2, reason: '失败后自动重试一次');
      // 真机缺陷回归（2026-09-22）：`item.error` 是**直接显示**给用户的
      // （`photo_backup_page.dart` 的失败项列表），所以它必须是用户语言；
      // 原始异常保留在 `item.cause`（诊断通道），报障/排查从这里取。
      expect(bad.error, isNotEmpty);
      expect(bad.error, isNot(contains('boom')));
      expect('${bad.cause}', contains('boom'));
    });

    test('手动重试失败项 → 变好就完成', () async {
      final media = FakeMediaLibrary([_asset('bad.jpg')]);
      final uploader = FakeUploader()..failNames.add('bad.jpg');
      final queue = PhotoBackupQueue(
        media: media,
        uploader: uploader,
        store: InMemoryPhotoBackupStore(),
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
      expect(queue.counts.failed, 1);
      uploader.failNames.clear();
      queue.retryFailed();
      await _settle();
      expect(queue.counts.done, 1);
      expect(queue.counts.failed, 0);
    });

    test('成功项写进账本（下次不会重传）', () async {
      final media = FakeMediaLibrary([_asset('a.jpg')]);
      final store = InMemoryPhotoBackupStore();
      final queue = PhotoBackupQueue(
        media: media,
        uploader: FakeUploader(),
        store: store,
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
      final saved = await store.load();
      expect(saved.doneKeys, contains(media.assets.single.stableKey));
      expect(saved.hasFinished, isTrue, reason: '收尾会记上次完成时间');
    });

    test('材料化失败算这一项失败，不牵连其他', () async {
      final media = FakeMediaLibrary([_asset('bad.jpg'), _asset('ok.jpg')]);
      media.onMaterialize = (asset) {
        if (asset.displayName == 'bad.jpg') throw StateError('打不开');
      };
      final queue = PhotoBackupQueue(
        media: media,
        uploader: FakeUploader(),
        store: InMemoryPhotoBackupStore(),
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
      expect(queue.counts.done, 1);
      expect(queue.counts.failed, 1);
    });
  });

  group('上传请求拼装', () {
    test(
      'upload_to_folder：官方 Web 前端形态（file + name + mtime 秒 + target_folder_id）',
      () async {
        final t = FakeTransport(
          {
            'SYNO.Foto.Upload.Item.upload_to_folder': {'unit_id': 42},
          },
          {...FakeTransport.table, ..._fotoTable},
        );
        final api = await _loggedIn(t);
        final id = await FotoApi(api).uploadToFolder(
          folderId: '7',
          filePath: '/tmp/a.jpg',
          fileName: 'a.jpg',
          mtimeMs: 1700000000000,
          mimeType: 'image/jpeg',
        );
        expect(id, '42');
        final call = t.calls.lastWhere(
          (c) => c['api'] == 'SYNO.Foto.Upload.Item',
        );
        expect(call['api'], 'SYNO.Foto.Upload.Item');
        expect(call['method'], 'upload_to_folder');
        expect(call['version'], '8');
        // 官方 `RO`：除 api/method/version 外每个值都 JSON.stringify
        expect(call['name'], '"a.jpg"');
        expect(call['mtime'], '1700000000', reason: '官方 Math.round(ms/1e3) 是秒');
        expect(call['target_folder_id'], '7', reason: 'folder id 是数字，不带引号');
        expect(call['duplicate'], '"rename"');
        expect(call['file_field'], 'file');
        expect(call['file_name'], 'a.jpg');
        expect(call['_sid'], isNotEmpty);
      },
    );

    test('upload：时间轴形态（folder=["PhotoLibrary"] + uploadDestination）', () async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Upload.Item.upload': {'unit_id': 9},
        },
        {...FakeTransport.table, ..._fotoTable},
      );
      final api = await _loggedIn(t);
      await FotoApi(api).uploadToTimeline(
        filePath: '/tmp/a.jpg',
        fileName: 'a.jpg',
        mtimeMs: 1700000000500,
      );
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Upload.Item',
      );
      expect(call['method'], 'upload');
      expect(call['version'], '8');
      expect(call['uploadDestination'], '"timeline"');
      expect(call['folder'], '["PhotoLibrary"]');
    });

    test('backup_check：check 数组 + 认得出 list 的名字', () async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Upload.Item.backup_check': {
            'list': [
              {'name': 'a.jpg'},
            ],
          },
        },
        {...FakeTransport.table, ..._fotoTable},
      );
      final api = await _loggedIn(t);
      final result = await FotoApi(api).backupCheck([
        const FotoBackupCheckEntry(
          name: 'a.jpg',
          hash: 'h1',
          takenTime: 1700000000,
          mtime: 1700000000,
        ),
      ]);
      expect(result.usable, isTrue);
      expect(result.existingNames, {'a.jpg'});
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Upload.Item',
      );
      expect(call['method'], 'backup_check');
      expect(call['check'], contains('"hash_code":"h1"'));
      expect(call['check'], contains('"takentime":1700000000'));
    });

    test('backup_check 认不出结构 → usable=false（调用方回落客户端去重）', () async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Upload.Item.backup_check': {'weird': 1},
        },
        {...FakeTransport.table, ..._fotoTable},
      );
      final api = await _loggedIn(t);
      final result = await FotoApi(
        api,
      ).backupCheck([const FotoBackupCheckEntry(name: 'a.jpg', hash: 'h1')]);
      expect(result.usable, isFalse);
      expect(result.existingNames, isEmpty);
    });

    test('backup_check 用 hash_code 反查名字', () async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Upload.Item.backup_check': {
            'duplicate_list': [
              {'hash_code': 'h1'},
            ],
          },
        },
        {...FakeTransport.table, ..._fotoTable},
      );
      final api = await _loggedIn(t);
      final result = await FotoApi(
        api,
      ).backupCheck([const FotoBackupCheckEntry(name: 'a.jpg', hash: 'h1')]);
      expect(result.existingNames, {'a.jpg'});
    });

    test('backup_check 103 → 回落到 upload_check', () async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Upload.Item.upload_check': {
            'list': ['a.jpg'],
          },
        },
        {...FakeTransport.table, ..._fotoTable},
      );
      t.failures['SYNO.Foto.Upload.Item.backup_check'] = 103;
      final api = await _loggedIn(t);
      final result = await FotoApi(
        api,
      ).backupCheck([const FotoBackupCheckEntry(name: 'a.jpg')]);
      expect(result.existingNames, {'a.jpg'});
      expect(
        t.calls.map((c) => c['method']),
        containsAll(['backup_check', 'upload_check']),
      );
    });
  });

  group('★ D72 按日期分目录（页面选择器）', () {
    testWidgets('★★ 选择器在、显示官方默认 year_and_month、选完落盘', (tester) async {
      final store = InMemoryPhotoBackupStore(
        const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
        ),
      );
      final t = FakeTransport(
        {
          'SYNO.Foto.Setting.User.get': {
            'team_space_permission': 'none',
            'enable_person': false,
            'timeline_group_unit': 'day',
          },
          'SYNO.Foto.Browse.Folder.list': {'list': []},
          'SYNO.Foto.Browse.Item.list': {'list': []},
        },
        {...FakeTransport.table, ..._fotoTable},
      );
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fotoApiProvider.overrideWithValue(FotoApi(api)),
          deviceMediaLibraryProvider.overrideWithValue(
            FakeMediaLibrary(const []),
          ),
          photoBackupUploaderProvider.overrideWithValue(FakeUploader()),
          photoBackupStoreProvider.overrideWithValue(store),
          photoBackupHasherProvider.overrideWithValue(
            const NoopPhotoBackupHasher(),
          ),
          networkTypeProbeProvider.overrideWithValue(
            FakeNetworkProbe(NetworkType.wifi),
          ),
        ],
      );
      addTearDown(db.close);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: PhotoBackupPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final tile = find.byKey(const Key('photo-backup-structure'));
      expect(tile, findsOneWidget);
      // 官方默认 year_and_month
      expect(
        find.textContaining('year_and_month'),
        findsOneWidget,
      );

      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      // 三个官方取值都在
      for (final v in const ['none', 'year', 'year_and_month']) {
        expect(
          find.byKey(Key('photo-backup-structure-$v')),
          findsOneWidget,
          reason: '官方 BackupStructure 的 $v',
        );
      }
      await tester.tap(find.byKey(const Key('photo-backup-structure-year')));
      await tester.pumpAndSettle();
      expect(
        (await store.load()).structure,
        DriveBackupStructure.year,
        reason: '选完必须落盘（与其它开关同一路径）',
      );
    });
  });

  group('备份页', () {
    Future<
      ({
        FakeTransport t,
        FakeUploader up,
        FakeMediaLibrary media,
        ProviderContainer c,
      })
    >
    pump(
      WidgetTester tester, {
      required List<DeviceMediaAsset> assets,
      MediaPermission permission = MediaPermission.granted,
      PhotoBackupSnapshot snapshot = const PhotoBackupSnapshot(
        targetFolderId: '7',
        targetFolderName: '手机备份',
      ),
      NetworkType network = NetworkType.wifi,
      Map<String, Map<String, dynamic>> responses = const {},
    }) async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Setting.User.get': {
            'team_space_permission': 'none',
            'enable_person': false,
            'timeline_group_unit': 'day',
          },
          'SYNO.Foto.Browse.Folder.list': {'list': []},
          'SYNO.Foto.Browse.Item.list': {'list': []},
          ...responses,
        },
        {...FakeTransport.table, ..._fotoTable},
      );
      final api = await _loggedIn(t);
      final media = FakeMediaLibrary(assets, permission: permission);
      final up = FakeUploader();
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fotoApiProvider.overrideWithValue(FotoApi(api)),
          deviceMediaLibraryProvider.overrideWithValue(media),
          photoBackupUploaderProvider.overrideWithValue(up),
          photoBackupStoreProvider.overrideWithValue(
            InMemoryPhotoBackupStore(snapshot),
          ),
          // 真哈希要读磁盘，`testWidgets` 的假时钟驱动不了真实 I/O；
          // 去重逻辑本身在 `photo_backup_dedup_test.dart` 用真字节钉住。
          photoBackupHasherProvider.overrideWithValue(
            const NoopPhotoBackupHasher(),
          ),
          networkTypeProbeProvider.overrideWithValue(FakeNetworkProbe(network)),
        ],
      );
      addTearDown(db.close);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: PhotoBackupPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      return (t: t, up: up, media: media, c: c);
    }

    testWidgets('权限被拒 → 明确引导（不静默失败）', (tester) async {
      final boot = await pump(
        tester,
        assets: [_asset('a.jpg')],
        permission: MediaPermission.denied,
      );
      expect(find.text('没有权限读不到本机照片，请允许访问「照片和视频」后再试'), findsOneWidget);
      expect(find.byKey(const Key('photo-backup-grant')), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-backup-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('备份失败'), findsOneWidget);
      expect(boot.up.uploaded, isEmpty);
    });

    testWidgets('授权后状态变绿', (tester) async {
      final boot = await pump(
        tester,
        assets: [_asset('a.jpg')],
        permission: MediaPermission.denied,
      );
      boot.media.permission = MediaPermission.granted;
      await tester.tap(find.byKey(const Key('photo-backup-grant')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('已获得相册读取权限'), findsOneWidget);
    });

    testWidgets('目标相册与开关展示（来自本地账本）', (tester) async {
      await pump(tester, assets: const []);
      expect(find.text('目标：手机备份'), findsOneWidget);
      expect(find.byKey(const Key('photo-backup-videos')), findsOneWidget);
      expect(find.byKey(const Key('photo-backup-wifi')), findsOneWidget);
    });

    testWidgets('P43 上传质量：选「低」→ 落盘 upload_quality=low（下次自动带档位）', (tester) async {
      final boot = await pump(tester, assets: const []);
      expect(find.byKey(const Key('photo-backup-quality')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('photo-backup-quality-select')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-backup-quality-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-backup-quality-low')).last);
      await tester.pumpAndSettle();
      final store =
          boot.c.read(photoBackupStoreProvider) as InMemoryPhotoBackupStore;
      expect(
        (await store.load()).uploadQuality.id,
        'low',
        reason: '档位必须落盘（重启备份仍生效）',
      );
      // 页面上的选择也要跟着变（不是只写盘）
      expect(find.text('低（长边 1280）'), findsWidgets);
    });

    testWidgets('点开始 → 按目标文件夹上传 + 进度刷新', (tester) async {
      final boot = await pump(
        tester,
        assets: [_asset('a.jpg'), _asset('b.jpg')],
      );
      await tester.tap(find.byKey(const Key('photo-backup-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        boot.up.uploaded.map((e) => e.name),
        containsAll(['a.jpg', 'b.jpg']),
      );
      expect(
        boot.up.uploaded.every((e) => e.folderId == '7'),
        isTrue,
        reason: '必须传到选定的目标成册文件夹',
      );
      expect(boot.media.listCalls, 1);
      expect(find.byKey(const Key('photo-backup-progress')), findsOneWidget);
      // 收尾后「上次完成」要顶掉「还没备份过」（真机曾是漏项）
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('上次完成'), findsOneWidget);
      expect(find.text('还没备份过'), findsNothing);
    });

    testWidgets('没有新照片 → 空结果提示', (tester) async {
      final boot = await pump(tester, assets: const []);
      await tester.tap(find.byKey(const Key('photo-backup-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(boot.up.uploaded, isEmpty);
      expect(find.text('没有需要备份的新照片'), findsOneWidget);
    });

    testWidgets('仅 Wi-Fi + 蜂窝网络 → 不传并提示', (tester) async {
      final boot = await pump(
        tester,
        assets: [_asset('a.jpg')],
        network: NetworkType.mobile,
        snapshot: const PhotoBackupSnapshot(
          targetFolderId: '7',
          targetFolderName: '手机备份',
          wifiOnly: true,
        ),
      );
      await tester.tap(find.byKey(const Key('photo-backup-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(boot.up.uploaded, isEmpty);
      expect(find.text('当前不是 Wi-Fi，已按「仅 Wi-Fi」暂停'), findsOneWidget);
    });

    testWidgets('已在 NAS 上的同名同大小 → 不算待传', (tester) async {
      final boot = await pump(
        tester,
        assets: [_asset('a.jpg', size: 100)],
        responses: {
          'SYNO.Foto.Browse.Item.list': {
            'list': [
              {
                'id': '55',
                'filename': 'a.jpg',
                'filesize': 100,
                'type': 'photo',
              },
            ],
          },
        },
      );
      await tester.tap(find.byKey(const Key('photo-backup-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(boot.up.uploaded, isEmpty);
      expect(find.textContaining('跳过 1'), findsOneWidget);
    });

    testWidgets('未连接 NAS → 目标为空时给"还没连接"错误', (tester) async {
      // fotoApiProvider 为 null 的装配：单开一个 container
      final c = ProviderContainer(
        overrides: [
          fotoApiProvider.overrideWithValue(null),
          deviceMediaLibraryProvider.overrideWithValue(
            FakeMediaLibrary([_asset('a.jpg')]),
          ),
          photoBackupStoreProvider.overrideWithValue(
            InMemoryPhotoBackupStore(const PhotoBackupSnapshot()),
          ),
          photoBackupUploaderProvider.overrideWithValue(FakeUploader()),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: PhotoBackupPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('photo-backup-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('备份失败'), findsOneWidget);
    });
  });

  group('备份页入口', () {
    testWidgets('相册页头部点「手机备份」→ 打开备份页', (tester) async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Setting.User.get': {
            'team_space_permission': 'none',
            'timeline_group_unit': 'day',
          },
          'SYNO.Foto.Browse.Item.list': {'list': []},
          'SYNO.Foto.Browse.Folder.list': {'list': []},
        },
        {...FakeTransport.table, ..._fotoTable},
      );
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fotoApiProvider.overrideWithValue(FotoApi(api)),
          deviceMediaLibraryProvider.overrideWithValue(
            FakeMediaLibrary(const []),
          ),
          photoBackupUploaderProvider.overrideWithValue(FakeUploader()),
          photoBackupStoreProvider.overrideWithValue(
            InMemoryPhotoBackupStore(
              const PhotoBackupSnapshot(
                targetFolderId: '7',
                targetFolderName: '手机备份',
              ),
            ),
          ),
        ],
      );
      addTearDown(db.close);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: PhotoBrowsePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('photo-backup-entry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-backup-entry')));
      await tester.pumpAndSettle();
      expect(find.text('手机备份'), findsWidgets);
    });
  });
}
