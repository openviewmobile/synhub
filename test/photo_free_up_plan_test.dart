// 相册「释放手机空间」(P51) **接口层**用例：判定口径 + 编排 + 三条安全不变量。
//
// ## ⚠️ 这里**绝不真的删任何文件**
//
// 全部依赖都是假的：[FakeMediaLibrary] 只记录"被要求删了哪些 uri"，一个真实
// 文件都不碰；[FakeTargets] 不发任何网络请求。
//
// ## 三条安全不变量（本文件的主角）
//
//   1. **未备份的照片不被删除** —— 候选只由 [PhotoFreeUpPlanner] 产生，而它复用
//      相机备份"这张已经传上去了"的判据；未备份 / 判定不确定一律保留；
//   2. **用户拒绝系统确认时不删除任何文件** —— `confirmed == false` ⇒ 一项都不删；
//   3. **平台通道不可用时给出人话说明且不假装成功** —— 走
//      `FreeUpRunOutcome.unsupported`，`deleted` 恒为 0。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/media/device_media_library.dart';
import 'package:synhub/src/features/photos/photo_backup_queue.dart';
import 'package:synhub/src/features/photos/photo_backup_target.dart';
import 'package:synhub/src/features/photos/photo_free_up_controller.dart';
import 'package:synhub/src/features/photos/photo_free_up_plan.dart';

/// 一条假的本机相册条目（默认在真实相机的 `DCIM/Camera` 里）。
DeviceMediaAsset _asset(
  String name, {
  int size = 1000,
  bool video = false,
  String path = 'DCIM/Camera',
  int taken = 1700000000000,
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

/// 假的本机相册 + 假的删除能力（**绝不真删文件**）。
class FakeMediaLibrary implements DeviceMediaLibrary, DeviceMediaDeleter {
  FakeMediaLibrary(
    this.assets, {
    this.permission = MediaPermission.granted,
    this.support = MediaDeleteSupport.systemConfirm,
    this.userConfirms = true,
    this.deleteOnlyFirstN,
  });

  final List<DeviceMediaAsset> assets;
  MediaPermission permission;
  MediaDeleteSupport support;

  /// 用户在系统确认框上点的是"允许"还是"取消"
  bool userConfirms;

  /// 确认后只删前 N 张（null = 全删）；用来测"部分失败"
  int? deleteOnlyFirstN;

  /// 被要求删除的 uri（测试断言"只请求了候选"）
  List<String> requestedUris = const [];
  int requestCalls = 0;
  int cacheClearCalls = 0;
  int openSettingsCalls = 0;

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
  }) async => [
    for (final a in assets)
      if (includeVideos || !a.isVideo) a,
  ];

  @override
  Future<String?> materialize(DeviceMediaAsset asset) async => null;

  @override
  Future<MediaDeleteSupport> deleteSupport() async => support;

  @override
  Future<MediaDeleteOutcome> requestDelete(
    List<DeviceMediaAsset> assets,
  ) async {
    requestCalls++;
    requestedUris = [for (final a in assets) a.uri];
    if (!support.canDeleteOnDevice || !userConfirms) {
      // 平台不给删 / 用户拒绝 ⇒ **一项都不删**
      return MediaDeleteOutcome(
        support: support,
        confirmed: false,
        requested: assets.length,
        failedUris: requestedUris,
      );
    }
    final n = deleteOnlyFirstN ?? assets.length;
    final deleted = requestedUris.take(n).toList();
    return MediaDeleteOutcome(
      support: support,
      confirmed: true,
      requested: assets.length,
      deletedUris: deleted,
      failedUris: requestedUris.skip(n).toList(),
    );
  }

  @override
  Future<bool> openSystemSettings() async {
    openSettingsCalls++;
    return true;
  }

  @override
  Future<bool> clearUploadCache() async {
    cacheClearCalls++;
    return true;
  }
}

/// 假的落点集合：可控"能不能用 / 清单里有什么"，**不发任何网络请求**。
class FakeTargets extends PhotoBackupTargets {
  FakeTargets({
    this.usable = true,
    this.connected = true,
    this.remote = const [],
    this.remoteCalls = 0,
  }) : super(
         fotoOf: () => null,
         driveOf: () => null,
         deviceNameOf: () => 'Test',
       );

  final bool usable;
  final bool connected;
  final List<RemotePhotoEntry> remote;

  /// 记了几次真正的"读 NAS 清单"调用（断言只读、且不该白调）
  int remoteCalls;

  @override
  PhotoBackupTargetInfo info(PhotoBackupDestination destination) {
    if (!connected) {
      return PhotoBackupTargetInfo(
        destination: destination,
        gate: PhotoBackupTargetGate.notConnected,
        reason: '还没连接 NAS',
      );
    }
    return PhotoBackupTargetInfo(
      destination: destination,
      gate: usable
          ? PhotoBackupTargetGate.ready
          : PhotoBackupTargetGate.missingService,
    );
  }

  @override
  Future<List<RemotePhotoEntry>> remoteEntries(
    PhotoBackupDestination destination, {
    required String ref,
  }) async {
    remoteCalls++;
    return remote;
  }
}

PhotoFreeUpController _controller({
  required List<DeviceMediaAsset> assets,
  Set<String> doneKeys = const {},
  List<RemotePhotoEntry> remote = const [],
  FakeMediaLibrary? media,
  FakeTargets? targets,
  bool withDeleter = true,
  bool remoteChecked = true,
  bool connected = true,
  bool includeVideos = true,
  bool dcimOnly = true,
}) {
  final lib = media ?? FakeMediaLibrary(assets);
  return PhotoFreeUpController(
    media: lib,
    deleter: withDeleter ? lib : null,
    store: InMemoryPhotoBackupStore(
      PhotoBackupSnapshot(
        doneKeys: doneKeys,
        includeVideos: includeVideos,
        dcimOnly: dcimOnly,
        targetFolderId: remoteChecked ? '7' : '',
        targetFolderName: remoteChecked ? '手机备份' : '',
      ),
    ),
    targets:
        targets ??
        FakeTargets(remote: remote, connected: connected, usable: connected),
  );
}

void main() {
  group('① 判定口径：哪些本地照片算"已备份、可删"', () {
    test('本机备份记录命中的才可删；没备份的**一定保留**', () {
      final a = _asset('a.jpg', size: 2048);
      final b = _asset('b.jpg', size: 4096);
      final plan = PhotoFreeUpPlanner.plan(
        assets: [a, b],
        doneKeys: {a.stableKey},
        remote: const [],
      );
      // 安全不变量 1：只有 a 进候选，b 被明确保留
      expect(plan.entries.map((e) => e.asset.displayName), ['a.jpg']);
      expect(plan.entries.single.reason, FreeUpReason.backupLedger);
      expect(plan.keptCount, 1);
      expect(plan.reclaimableBytes, 2048);
    });

    test('NAS 上已有**同名 + 同大小** → 可删（依据标成 NAS 清单）', () {
      final c = _asset('c.jpg', size: 500);
      final plan = PhotoFreeUpPlanner.plan(
        assets: [c],
        doneKeys: const {},
        remote: const [RemotePhotoEntry(name: 'c.jpg', size: 500)],
      );
      expect(plan.entries.single.reason, FreeUpReason.remoteListing);
    });

    test('⚠️ 同名但**大小不同** → 判定不确定 ⇒ 绝不删', () {
      final c = _asset('c.jpg', size: 500);
      final plan = PhotoFreeUpPlanner.plan(
        assets: [c],
        doneKeys: const {},
        remote: const [RemotePhotoEntry(name: 'c.jpg', size: 501)],
      );
      expect(plan.entries, isEmpty);
      expect(plan.keptCount, 1);
      expect(plan.reclaimableBytes, 0);
    });

    test('⚠️ 0 字节的清单条目不算证据 ⇒ 绝不删', () {
      final c = _asset('c.jpg', size: 0);
      final plan = PhotoFreeUpPlanner.plan(
        assets: [c],
        doneKeys: const {},
        remote: const [RemotePhotoEntry(name: 'c.jpg', size: 0)],
      );
      expect(plan.entries, isEmpty);
      expect(plan.keptCount, 1);
    });

    test('⚠️ 只有"同内容的 md5 记录"（改名过的另一张）不算这张已备份 ⇒ 不删', () {
      final a = _asset('a.jpg', size: 1000);
      final plan = PhotoFreeUpPlanner.plan(
        assets: [a],
        doneKeys: {'md5:deadbeef|1000'},
        remote: const [],
      );
      expect(plan.entries, isEmpty);
      expect(plan.keptCount, 1);
    });

    test('关掉视频备份时，NAS 上有同名视频也**不删**（不在备份范围内）', () {
      final v = _asset('v.mp4', size: 900, video: true);
      final plan = PhotoFreeUpPlanner.plan(
        assets: [v],
        doneKeys: const {},
        remote: const [RemotePhotoEntry(name: 'v.mp4', size: 900)],
        includeVideos: false,
      );
      expect(plan.entries, isEmpty);
      expect(plan.keptCount, 1);
    });

    test('DCIM 之外的照片（如截图）不在备份范围 ⇒ 不进候选', () {
      final s = _asset('shot.png', path: 'Pictures/Screenshots');
      final plan = PhotoFreeUpPlanner.plan(
        assets: [s],
        doneKeys: const {},
        remote: const [RemotePhotoEntry(name: 'shot.png', size: 1000)],
        dcimOnly: true,
      );
      // 官方相机备份恒扫 DCIM → 范围外的项连计划都不进
      expect(plan.entries, isEmpty);
      expect(plan.scannedCount, 0);
    });

    test('多条命中去重后不重复计入可释放量', () {
      final a = _asset('a.jpg', size: 1000);
      final plan = PhotoFreeUpPlanner.plan(
        assets: [a],
        doneKeys: {a.stableKey},
        remote: const [RemotePhotoEntry(name: 'a.jpg', size: 1000)],
      );
      expect(plan.entries, hasLength(1));
      expect(plan.reclaimableBytes, 1000);
    });
  });

  group('② 核对（scan）', () {
    test('读 NAS 清单是**只读**、且只读一次；没设过目标就不读', () async {
      final a = _asset('a.jpg');
      final routedTargets = FakeTargets(
        remote: const [RemotePhotoEntry(name: 'a.jpg', size: 1000)],
      );
      final withTarget = _controller(
        assets: [a],
        doneKeys: {a.stableKey},
        targets: routedTargets,
      );
      await withTarget.scan();
      expect(withTarget.remoteChecked, isTrue);
      expect(withTarget.reclaimableCount, 1);
      // 只读清单**恰好读了一次**
      expect(routedTargets.remoteCalls, 1);

      final unusedTargets = FakeTargets(
        remote: const [RemotePhotoEntry(name: 'a.jpg', size: 1000)],
      );
      final noTarget = _controller(
        assets: [a],
        doneKeys: {a.stableKey},
        targets: unusedTargets,
        remoteChecked: false,
      );
      await noTarget.scan();
      expect(noTarget.remoteChecked, isFalse);
      // 没设过目标 → **一次网络调用都不发**
      expect(unusedTargets.remoteCalls, 0);
      // 账本命中照样能算出来（**不建目录、不发写操作**）
      expect(noTarget.reclaimableCount, 1);
    });

    test('权限被拒 → 不枚举、不给候选（更不会删）', () async {
      final media = FakeMediaLibrary([
        _asset('a.jpg'),
      ], permission: MediaPermission.denied);
      final c = _controller(assets: const [], media: media);
      await c.scan();
      expect(c.permission.isUsable, isFalse);
      expect(c.reclaimableCount, 0);
      final report = await c.run();
      expect(report.outcome, FreeUpRunOutcome.nothing);
      expect(media.requestCalls, 0);
    });

    test('NAS 没连上 → 只按本机账本判断，并给出"没连上"标记', () async {
      final a = _asset('a.jpg');
      final c = _controller(
        assets: [a],
        doneKeys: {a.stableKey},
        connected: false,
      );
      await c.scan();
      expect(c.notConnected, isTrue);
      expect(c.remoteChecked, isFalse);
      expect(c.reclaimableCount, 1);
    });
  });

  group('③ 执行（run）：三条安全不变量', () {
    test('安全不变量 1：**未备份的照片绝不被要求删除**', () async {
      final a = _asset('a.jpg', size: 2048);
      final b = _asset('b.jpg', size: 4096);
      final c = _asset('c.jpg', size: 512);
      final media = FakeMediaLibrary([a, b, c]);
      final controller = _controller(
        assets: [a, b, c],
        doneKeys: {a.stableKey},
        remote: const [RemotePhotoEntry(name: 'c.jpg', size: 512)],
        media: media,
      );
      await controller.scan();
      await controller.run();

      expect(media.requestedUris, containsAll([a.uri, c.uri]));
      // **关键**：未备份的 b 从头到尾没被要求删过
      expect(media.requestedUris, isNot(contains(b.uri)));
      expect(media.requestedUris, hasLength(2));
    });

    test('安全不变量 2：**用户拒绝系统确认时不删除任何文件**', () async {
      final a = _asset('a.jpg', size: 2048);
      final media = FakeMediaLibrary([a], userConfirms: false);
      final controller = _controller(
        assets: [a],
        doneKeys: {a.stableKey},
        media: media,
      );
      await controller.scan();
      final before = controller.reclaimableBytes;
      final report = await controller.run();

      expect(report.outcome, FreeUpRunOutcome.rejected);
      expect(report.deleted, 0);
      expect(report.bytesDeleted, 0);
      // 一项都没被标成"已删除"
      expect(controller.entries.every((e) => !e.isDeleted), isTrue);
      // 可释放量一张都没少
      expect(controller.reclaimableBytes, before);
    });

    test('安全不变量 3a：**没有删除能力**时如实说"不支持"，deleted 恒为 0', () async {
      final a = _asset('a.jpg', size: 2048);
      final controller = PhotoFreeUpController(
        media: FakeMediaLibrary([a]),
        deleter: null,
        store: InMemoryPhotoBackupStore(
          PhotoBackupSnapshot(doneKeys: {a.stableKey}, targetFolderId: '7'),
        ),
        targets: FakeTargets(),
      );
      await controller.scan();
      expect(controller.hasDeleter, isFalse);
      final report = await controller.run();
      expect(report.outcome, FreeUpRunOutcome.unsupported);
      expect(report.deleted, 0);
      expect(report.bytesDeleted, 0);
      expect(controller.reclaimableBytes, 2048);
    });

    test('安全不变量 3b：平台只给"手动清理"（settings_only）时不假装成功', () async {
      final a = _asset('a.jpg', size: 2048);
      final media = FakeMediaLibrary([
        a,
      ], support: MediaDeleteSupport.settingsOnly);
      final controller = _controller(
        assets: [a],
        doneKeys: {a.stableKey},
        media: media,
      );
      await controller.scan();
      expect(controller.support.canDeleteOnDevice, isFalse);
      final report = await controller.run();
      expect(report.outcome, FreeUpRunOutcome.unsupported);
      expect(report.deleted, 0);
      expect(controller.entries.single.isDeleted, isFalse);
    });

    test('用户确认后成功删除 → 结局/字节/逐项状态都按事实落', () async {
      final a = _asset('a.jpg', size: 2048);
      final c = _asset('c.jpg', size: 1024);
      final media = FakeMediaLibrary([a, c]);
      final controller = _controller(
        assets: [a, c],
        doneKeys: {a.stableKey, c.stableKey},
        media: media,
      );
      await controller.scan();
      final report = await controller.run();

      expect(report.outcome, FreeUpRunOutcome.deleted);
      expect(report.deleted, 2);
      expect(report.failed, 0);
      expect(report.bytesDeleted, 3072);
      expect(controller.entries.every((e) => e.isDeleted), isTrue);
      // 删掉之后"可释放"归零（不再重复计）
      expect(controller.reclaimableBytes, 0);
      expect(controller.deletedCount, 2);
    });

    test('部分失败：确认了但只有一部分真删掉 → failed 数如实报', () async {
      final a = _asset('a.jpg', size: 2048);
      final b = _asset('b.jpg', size: 4096);
      final media = FakeMediaLibrary([a, b], deleteOnlyFirstN: 1);
      final controller = _controller(
        assets: [a, b],
        doneKeys: {a.stableKey, b.stableKey},
        media: media,
      );
      await controller.scan();
      final report = await controller.run();

      expect(report.outcome, FreeUpRunOutcome.deleted);
      expect(report.deleted, 1);
      expect(report.failed, 1);
      expect(report.bytesDeleted, 2048);
      expect(controller.reclaimableBytes, 4096);
    });

    test('确认了但一张都没删成 → failed（**不是**"已释放"）', () async {
      final a = _asset('a.jpg', size: 2048);
      final media = FakeMediaLibrary([a], deleteOnlyFirstN: 0);
      final controller = _controller(
        assets: [a],
        doneKeys: {a.stableKey},
        media: media,
      );
      await controller.scan();
      final report = await controller.run();
      expect(report.outcome, FreeUpRunOutcome.failed);
      expect(report.deleted, 0);
      expect(report.bytesDeleted, 0);
    });

    test('没有候选时不打扰删除能力', () async {
      final b = _asset('b.jpg'); // 没备份
      final media = FakeMediaLibrary([b]);
      final controller = _controller(assets: [b], media: media);
      await controller.scan();
      final report = await controller.run();
      expect(report.outcome, FreeUpRunOutcome.nothing);
      expect(media.requestCalls, 0);
    });

    test('清 App 临时副本与跳系统设置都走既有能力（本机操作，不碰 NAS）', () async {
      final a = _asset('a.jpg');
      final media = FakeMediaLibrary([a]);
      final controller = _controller(
        assets: [a],
        doneKeys: {a.stableKey},
        media: media,
      );
      await controller.scan();
      expect(await controller.clearAppCache(), isTrue);
      expect(await controller.openSystemSettings(), isTrue);
      expect(media.cacheClearCalls, 1);
      expect(media.openSettingsCalls, 1);
    });
  });
}
