// 相册「释放手机空间」(P51) **页面层**用例。
//
// ## ⚠️ 这里**绝不真的删任何文件**
//
// 删除能力是注入的假实现（[FakeMediaLibrary]），只记录"被要求删了哪些 uri"。
//
// ## 覆盖的三条安全不变量（页面视角）
//
//   1. **未备份的照片不被删除** —— 未备份的项既不上榜、也永不被要求删；
//   2. **用户拒绝系统确认时不删除任何文件** —— 页面显示"已取消…"，
//      **绝不出现**"已释放"；
//   3. **平台通道不可用时给出人话说明且不假装成功** —— 显示人话 + 「去系统设置」，
//      点了会真的调系统设置入口，且**绝不出现**"已释放"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';

import 'package:synhub/src/data/media/device_media_library.dart';
import 'package:synhub/src/features/photos/photo_backup_page.dart';
import 'package:synhub/src/features/photos/photo_backup_providers.dart';
import 'package:synhub/src/features/photos/photo_backup_queue.dart';
import 'package:synhub/src/features/photos/photo_backup_target.dart';
import 'package:synhub/src/features/photos/photo_free_up_page.dart';

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
  });

  final List<DeviceMediaAsset> assets;
  MediaPermission permission;
  MediaDeleteSupport support;
  bool userConfirms;

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
    final confirmed = support.canDeleteOnDevice && userConfirms;
    return MediaDeleteOutcome(
      support: support,
      confirmed: confirmed,
      requested: assets.length,
      deletedUris: confirmed ? List.of(requestedUris) : const [],
      failedUris: confirmed ? const [] : List.of(requestedUris),
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

class FakeTargets extends PhotoBackupTargets {
  FakeTargets({this.remote = const []})
    : super(
        fotoOf: () => null,
        driveOf: () => null,
        deviceNameOf: () => 'Test',
      );

  final List<RemotePhotoEntry> remote;

  @override
  PhotoBackupTargetInfo info(PhotoBackupDestination destination) =>
      PhotoBackupTargetInfo(
        destination: destination,
        gate: PhotoBackupTargetGate.ready,
      );

  @override
  Future<List<RemotePhotoEntry>> remoteEntries(
    PhotoBackupDestination destination, {
    required String ref,
  }) async => remote;
}

/// 装好页面并等首帧稳定。
Future<FakeMediaLibrary> _pump(
  WidgetTester tester, {
  required List<DeviceMediaAsset> assets,
  Set<String> doneKeys = const {},
  List<RemotePhotoEntry> remote = const [],
  MediaPermission permission = MediaPermission.granted,
  MediaDeleteSupport support = MediaDeleteSupport.systemConfirm,
  bool userConfirms = true,
  Widget? page,
}) async {
  final media = FakeMediaLibrary(
    assets,
    permission: permission,
    support: support,
    userConfirms: userConfirms,
  );
  final container = ProviderContainer(
    overrides: [
      deviceMediaLibraryProvider.overrideWithValue(media),
      photoBackupStoreProvider.overrideWithValue(
        InMemoryPhotoBackupStore(
          PhotoBackupSnapshot(
            doneKeys: doneKeys,
            targetFolderId: '7',
            targetFolderName: '手机备份',
          ),
        ),
      ),
      photoBackupTargetsProvider.overrideWithValue(FakeTargets(remote: remote)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: page ?? const PhotoFreeUpSpacePage()),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return media;
}

void main() {
  testWidgets('① 说明卡常驻：先讲清楚"只删除已备份的照片"', (tester) async {
    await _pump(tester, assets: [_asset('a.jpg')]);
    expect(find.byKey(const Key('photo-free-up-explain')), findsOneWidget);
    expect(find.text('只删除已备份的照片'), findsOneWidget);
  });

  testWidgets('② 显示可释放量与计数；**未备份的照片不上榜**', (tester) async {
    final a = _asset('a.jpg', size: 2048);
    final b = _asset('b.jpg', size: 4096); // 没备份
    await _pump(tester, assets: [a, b], doneKeys: {a.stableKey});

    expect(find.text('可释放 2.0 KB'), findsOneWidget);
    expect(find.text('已备份 1 张 · 未备份 1 张不会删除'), findsOneWidget);
    expect(find.byKey(Key('photo-free-up-item-${a.id}')), findsOneWidget);
    // 安全不变量 1：未备份的 b **不在**可删除列表里
    expect(find.byKey(Key('photo-free-up-item-${b.id}')), findsNothing);
    expect(find.text('b.jpg'), findsNothing);
  });

  testWidgets('③ 确认删除 → 显示已释放；逐项标"已删除"；只请求候选', (tester) async {
    final a = _asset('a.jpg', size: 2048);
    final b = _asset('b.jpg', size: 4096); // 没备份
    final c = _asset('c.jpg', size: 1024);
    final media = await _pump(
      tester,
      assets: [a, b, c],
      doneKeys: {a.stableKey, c.stableKey},
    );

    await tester.tap(find.byKey(const Key('photo-free-up-start')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byKey(const Key('photo-free-up-result')), findsOneWidget);
    expect(find.text('已释放 3.0 KB（2 张）'), findsWidgets);
    // 逐项列表在结果卡下面，先滚到它可见（ListView 是懒构建的）
    await tester.scrollUntilVisible(
      find.byKey(Key('photo-free-up-item-${a.id}')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('已删除'), findsNWidgets(2));
    // 安全不变量 1：未备份的 b 从来没被要求删
    expect(media.requestedUris, hasLength(2));
    expect(media.requestedUris, isNot(contains(b.uri)));
    // 真的删过才清 App 临时副本
    expect(media.cacheClearCalls, 1);
    expect(find.text('可释放 0 B'), findsNothing);
  });

  testWidgets('④ 安全不变量 2：拒绝系统确认 → 显示已取消，**绝不出现"已释放"**', (tester) async {
    final a = _asset('a.jpg', size: 2048);
    final media = await _pump(
      tester,
      assets: [a],
      doneKeys: {a.stableKey},
      userConfirms: false,
    );
    final before = find.text('可释放 2.0 KB');
    expect(before, findsOneWidget);

    await tester.tap(find.byKey(const Key('photo-free-up-start')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('已取消，没有删除任何照片'), findsWidgets);
    expect(find.textContaining('已释放'), findsNothing);
    // 一项都没标成"已删除"，可释放量一张都没少
    expect(find.textContaining('已删除'), findsNothing);
    expect(find.text('可释放 2.0 KB'), findsOneWidget);
    // 什么都没被动过 → 连 App 临时副本都不清
    expect(media.cacheClearCalls, 0);
  });

  testWidgets('⑤ 安全不变量 3：平台只给"手动清理" → 人话说明 + 去系统设置，不假装成功', (tester) async {
    final a = _asset('a.jpg', size: 2048);
    final media = await _pump(
      tester,
      assets: [a],
      doneKeys: {a.stableKey},
      support: MediaDeleteSupport.settingsOnly,
    );

    expect(find.byKey(const Key('photo-free-up-platform')), findsOneWidget);
    expect(find.text('这台设备需要你手动清理'), findsOneWidget);
    // **没有**"释放空间"代删按钮（平台不给删就不给按）
    expect(find.byKey(const Key('photo-free-up-start')), findsNothing);

    await tester.tap(find.byKey(const Key('photo-free-up-settings')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(media.openSettingsCalls, 1);
    // 全程没有"已释放"，也没请求过删除
    expect(find.textContaining('已释放'), findsNothing);
    expect(media.requestCalls, 0);
  });

  testWidgets('⑤ 安全不变量 3b：没有删除能力（无宿主）同样只给人话，不假装成功', (tester) async {
    final a = _asset('a.jpg', size: 2048);
    // 用一个**不实现删除能力**的探针：provider 会回 null → 页面走降级
    final onlyReader = _ReaderOnlyLibrary([a]);
    final container = ProviderContainer(
      overrides: [
        deviceMediaLibraryProvider.overrideWithValue(onlyReader),
        photoBackupStoreProvider.overrideWithValue(
          InMemoryPhotoBackupStore(
            PhotoBackupSnapshot(doneKeys: {a.stableKey}, targetFolderId: '7'),
          ),
        ),
        photoBackupTargetsProvider.overrideWithValue(FakeTargets()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: const PhotoFreeUpSpacePage()),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('这台设备不能由应用删除照片'), findsOneWidget);
    expect(find.textContaining('什么都没被删除'), findsOneWidget);
    expect(find.byKey(const Key('photo-free-up-start')), findsNothing);
    expect(find.textContaining('已释放'), findsNothing);
  });

  testWidgets('⑥ 权限被拒 → 明确引导（不静默失败）', (tester) async {
    await _pump(
      tester,
      assets: [_asset('a.jpg')],
      permission: MediaPermission.denied,
    );
    expect(find.byKey(const Key('photo-free-up-permission')), findsOneWidget);
    expect(find.byKey(const Key('photo-free-up-grant')), findsOneWidget);
    expect(find.byKey(const Key('photo-free-up-start')), findsNothing);
  });

  testWidgets('⑦ 没有已备份的照片 → 人话空态，不是白屏', (tester) async {
    await _pump(tester, assets: [_asset('a.jpg')]);
    expect(find.text('没有可释放的照片'), findsOneWidget);
    expect(find.byKey(const Key('photo-free-up-start')), findsNothing);
  });

  testWidgets('⑧ 备份页有入口，点进去就是「释放手机空间」页', (tester) async {
    await _pump(
      tester,
      assets: [_asset('a.jpg')],
      page: const PhotoBackupPage(),
    );
    final entry = find.byKey(const Key('photo-free-up-entry'));
    expect(entry, findsOneWidget);
    expect(find.text('释放手机空间'), findsOneWidget);

    await tester.tap(entry);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const Key('photo-free-up-page')), findsOneWidget);
  });
}

/// 只读探针（**没有**删除能力）—— 用来复现"平台通道不可用"。
class _ReaderOnlyLibrary implements DeviceMediaLibrary {
  _ReaderOnlyLibrary(this.assets);

  final List<DeviceMediaAsset> assets;

  @override
  Future<MediaPermission> permissionStatus() async => MediaPermission.granted;

  @override
  Future<MediaPermission> ensurePermission({bool interactive = true}) async =>
      MediaPermission.granted;

  @override
  Future<List<DeviceMediaAsset>> list({
    bool includeVideos = true,
    int limit = 500,
    int offset = 0,
  }) async => assets;

  @override
  Future<String?> materialize(DeviceMediaAsset asset) async => null;
}
