// M73（审计行 225）：**在 File Station 里上传本机照片**。
//
// ## 官方基线
// DSfile 4.17.2-609 的文件抽屉有 `PBUploadManager` / "Instant Upload"。
// 我们此前只有相册侧的自动备份，**没有这个入口** ⇒ 属于"官方有、我们没有"。
//
// ## 本组怎么验（新规：无法真机验证的走 Mock Server）
//   * **M73-1**：让**真实的 `FileStationApi`** 打在 `MockDsmBackend` 上，
//     断言 `photoUpload` 发出的 `api/method/version` 组合**通过权威目录校验**
//     （不是"回了 200 就算过" —— mock 会对错的组合回 103）。
//   * **M73-2**：本机照片枚举的三种权限结果。
//   * **M73-3/4**：入口出现在 ＋ 面板里；选择面板返回所选项。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/media/device_media_library.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_local_photos_pick.dart';
import 'package:synhub/src/features/photos/photo_backup_providers.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import '../tool/mock_dsm/mock_dsm_server.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/mock_dsm_transport.dart';

// ---------------------------------------------------------------- 假件

/// 假本机相册：只回权限与固定几张照片，不碰 MediaStore。
class _FakeMediaLibrary implements DeviceMediaLibrary {
  _FakeMediaLibrary({this.permission = MediaPermission.granted});

  MediaPermission permission;
  List<DeviceMediaAsset>? assets;
  int listCalls = 0;
  bool? lastIncludeVideos;

  @override
  Future<MediaPermission> permissionStatus() async => permission;

  @override
  Future<MediaPermission> ensurePermission({bool interactive = true}) async =>
      permission;

  @override
  Future<List<DeviceMediaAsset>> list({
    bool includeVideos = true,
    int offset = 0,
    int limit = 500,
  }) async {
    listCalls++;
    lastIncludeVideos = includeVideos;
    return assets ??
        [
          const DeviceMediaAsset(
            id: '1',
            uri: 'content://media/external/file/1',
            displayName: 'IMG_0001.jpg',
            size: 2048,
            takenTimeMs: 1700000000000,
            modifiedTimeMs: 1700000000000,
          ),
        ];
  }

  @override
  Future<String?> materialize(DeviceMediaAsset asset) async =>
      '/tmp/${asset.displayName}';
}

void main() {
  // =====================================================================
  // M73-1：真实 API 层 × Mock Server（新规路径）
  // =====================================================================
  group('M73-1. photoUpload 打在 Mock Server 上：组合必须通过权威目录校验', () {
    late DsmCatalog catalog;
    late MockDsmBackend backend;
    late MockDsmTransport transport;

    setUp(() {
      catalog = DsmCatalog.load();
      backend = MockDsmBackend(catalog: catalog);
      // 装上**真机取证过**的夹具 —— 没有它 mock 只回 `data:{}`，
      // "调用合法"能证，"返回值被正确解析"证不了。
      MockDsmFixtureStore(
        Directory('tool/mock_dsm/fixtures'),
      ).installInto(backend);
      backend.login(username: 'u', admin: false);
      transport = MockDsmTransport(backend);
    });

    test('PhotoUpload 在权威目录里是"普通用户可用"的 v2-v3 接口', () {
      final spec = catalog['SYNO.FileStation.PhotoUpload'];
      expect(spec, isNotNull, reason: '目录里必须有它，否则无从对齐');
      expect(spec!.normal, isTrue, reason: '普通用户应当可用');
      expect(spec.versions, containsAll([2, 3]));
      expect(spec.versionsWith('upload'), containsAll([2, 3]));
    });

    test('★ 协商出的版本 + 方法组合合法（mock 不回 103）', () async {
      final web = DsmWebApi(transport);
      await web.discover();
      // 必须**通过客户端**登录：sid 由客户端持有并注入 `_sid`，
      // 光在后端预置会话是不够的（会得到 119）。
      await web.login(account: 'u', password: 'x');
      final fs = FileStationApi(web);

      final bytes = File('/tmp/m73-probe.jpg');
      await bytes.writeAsBytes(List<int>.filled(24, 7));
      addTearDown(() {
        if (bytes.existsSync()) bytes.deleteSync();
      });

      final res = await fs.photoUpload(
        folderPath: '/home/Photos',
        filePath: bytes.path,
        fileName: 'IMG_0001.jpg',
      );

      // ---- 到底发了什么 ----
      final up = transport.lastUpload!;
      expect(up.fields['api'], 'SYNO.FileStation.PhotoUpload');
      expect(up.fields['method'], 'upload');
      final version = int.parse('${up.fields['version']}');
      final spec = catalog['SYNO.FileStation.PhotoUpload']!;
      expect(
        spec.versionsWith('upload'),
        contains(version),
        reason: '发的 v$version 必须在目录的方法表里（否则真机会吃 103）',
      );
      // `dest_folder_path` 只在 v1 发；我们永不发（minVersion=2）。
      expect(up.fields.containsKey('dest_folder_path'), isFalse);
      expect(up.fields['path'], '/home/Photos');

      // ---- mock 的判定 ----
      expect(
        transport.last!.errorCode,
        isNot(103),
        reason: '组合非法时 mock 会回 103；这里必须是"通过校验"',
      );
      expect(res.fileName, isNotEmpty);
    });

    test('api 名字若被写错 ⇒ mock 立刻 101/103（证明这条用例不是必过）', () async {
      // A/B：把方法名改成一个该版本不存在的名字，mock 必须拒绝。
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.FileStation.PhotoUpload',
        'method': 'not_a_real_method',
        'version': 3,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103);
    });
  });

  // =====================================================================
  // M73-2：本机照片枚举的权限语义
  // =====================================================================
  group('M73-2. 本机照片枚举', () {
    /// 读一次本机照片，返回 `AsyncValue`（错误也要能看见 —— `denied` 那条靠它）。
    Future<AsyncValue<List<DeviceMediaAsset>>> read(
      WidgetTester tester,
      _FakeMediaLibrary lib,
    ) async {
      late AsyncValue<List<DeviceMediaAsset>> snap;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [deviceMediaLibraryProvider.overrideWithValue(lib)],
          child: Consumer(
            builder: (context, ref, _) {
              snap = ref.watch(localPhotosProvider);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return snap;
    }

    testWidgets('granted ⇒ 只枚举图片（includeVideos=false）', (tester) async {
      final lib = _FakeMediaLibrary();
      final snap = await read(tester, lib);
      final list = snap.requireValue;
      expect(list, hasLength(1));
      expect(list.single.displayName, 'IMG_0001.jpg');
      expect(lib.lastIncludeVideos, isFalse, reason: '照片入口不该混进视频');
    });

    testWidgets('partial（Android 14+ 只授权选中几张）⇒ 也放行', (tester) async {
      final lib = _FakeMediaLibrary(permission: MediaPermission.partial);
      final snap = await read(tester, lib);
      expect(snap.requireValue, isNotEmpty);
      expect(lib.listCalls, 1);
    });

    testWidgets('denied ⇒ 抛 permissionDenied（UI 提示去设置，不是"上传失败"）', (
      tester,
    ) async {
      final lib = _FakeMediaLibrary(permission: MediaPermission.denied);
      final snap = await read(tester, lib);
      // Riverpod 3 里"失败后立刻读"可能还是 `AsyncLoading`（带上 error），
      // 所以断言 `hasError` 而不是具体类型 —— 断言类型会误报。
      expect(snap.hasError, isTrue, reason: 'denied 必须是错误态: $snap');
      expect(snap.error, isA<DeviceMediaPermissionDenied>());
      expect(lib.listCalls, 0, reason: '没权限就不该去枚举');
    });
  });

  // =====================================================================
  // M73-3/4：UI
  // =====================================================================
  group('M73-3. 选择面板', () {
    testWidgets('点一张 ⇒ 返回那一张', (tester) async {
      final assets = [
        const DeviceMediaAsset(
          id: '7',
          uri: 'content://media/external/file/7',
          displayName: 'IMG_0007.jpg',
          size: 4096,
          takenTimeMs: 1700000000000,
          modifiedTimeMs: 1700000000000,
        ),
      ];
      List<DeviceMediaAsset>? picked;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    picked = await showLocalPhotosSheet(
                      context,
                      assets: assets,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(localPhotosSheetTitle()), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local-photo-7')));
      await tester.pumpAndSettle();
      expect(picked, hasLength(1));
      expect(picked!.single.displayName, 'IMG_0007.jpg');
    });

    testWidgets('本机没有照片 ⇒ 给"没找到照片"的提示（不是空白面板）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showLocalPhotosSheet(context, assets: const []),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(localPhotosEmpty()), findsOneWidget);
    });
  });

  // =====================================================================
  // M73-4：**接线守卫** —— 防止"只写了 picker，没接进 UI"
  // =====================================================================
  group('M73-4. UI 接线（读源码断言，防"半截实现"）', () {
    late String src;

    setUpAll(() {
      src = File(
        'lib/src/features/files/file_browse_page.dart',
      ).readAsStringSync();
    });

    test('＋ 面板里有「上传本机照片」这一项，且 key 固定', () {
      expect(src, contains("Key('file-upload-local-photo')"));
      expect(src, contains('localPhotosSheetTitle()'));
    });

    test('★★ r371（DA15）：照片那行的副标题与「上传文件」那行**不是同一句**', () {
      // 缺陷原文（r359）：两行副标题逐字相同 ⇒ 用户看不出差别。
      // 判据必须钉在**这一行自己的 description** 上（不是"文件里存在新 key"）。
      final start = src.indexOf("Key('file-upload-local-photo')");
      expect(start, greaterThan(0));
      final row = src.substring(start, start + 900);
      expect(
        row,
        contains('t.fileUploadLocalPhotoFromDevice('),
        reason: '照片行要用自己的那句',
      );
      expect(
        row,
        isNot(contains('t.fileUploadFromDevice(')),
        reason: '★★ 不许再和「上传文件」共用同一句副标题',
      );
      // 反向：普通上传那行**仍然**用通用那句（别把两行都改了）
      final upStart = src.indexOf("label: t.driveUploadFileTitle");
      expect(upStart, greaterThan(0));
      expect(
        src.substring(upStart, upStart + 200),
        contains('t.fileUploadFromDevice('),
      );
    });

    test('★★ r371（DA15）：新 key 两语都有值，且英文里没有中文', () {
      final zh = AppTextZh().fileUploadLocalPhotoFromDevice('目标');
      final en = AppTextEn().fileUploadLocalPhotoFromDevice('Target');
      expect(zh, contains('目标'));
      expect(en, contains('Target'));
      expect(
        RegExp(r'[\u4E00-\u9FFF]').hasMatch(en),
        isFalse,
        reason: '英文界面出现中文 = 用户报的"中英混排"',
      );
      expect(
        zh,
        isNot(AppTextZh().fileUploadFromDevice('目标')),
        reason: '两句必须是不同的文案',
      );
    });

    test('该动作真的接到上传实现上（不是空壳）', () {
      expect(src, contains("case 'uploadPhoto':"));
      expect(src, contains('_pickAndUploadLocalPhoto'));
      expect(src, contains('actions.uploadPhoto('));
      // 必须走 PhotoUpload 那条链路。注意 `actions.upload(` 在既有的
      // `_pickAndUpload` 里**本来就存在**，所以不能用"源码里没有它"来断言
      // （我第一版就是这么写的，被自己证伪）。改成按方法体切片判定。
      final body = src.substring(
        src.indexOf('Future<void> _pickAndUploadLocalPhoto()'),
        src.indexOf('Future<void> _pickAndUpload()'),
      );
      expect(body, contains('actions.uploadPhoto('));
      expect(
        body,
        isNot(contains('actions.upload(')),
        reason: 'M73 这条必须走 PhotoUpload，不能退化成普通 Upload',
      );
    });

    test('三种失败分别给不同提示（权限被拒 ≠ 读取失败）', () {
      expect(src, contains('localPhotosNeedPermission()'));
      expect(src, contains('localPhotosPickFailed()'));
      expect(src, contains('on DeviceMediaPermissionDenied'));
    });

    test('冲突策略与普通上传同源（默认绝不静默覆盖）', () {
      expect(src, contains('uploadConflictExists('));
      expect(src, contains('showUploadConflictSheet('));
      expect(src, contains('UploadConflictPolicy.skip'));
    });
  });
}
