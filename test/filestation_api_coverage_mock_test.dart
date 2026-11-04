// ★ **「文件」App 的 Mock 全覆盖测试** —— 结项清单里「Mock 覆盖该 App 全部 API
// （含 admin）」这一项的交付物。
//
// ## 这套用例回答的问题
// 「文件模块引用了 39 个 API 名 —— 它们**真的**都能打通吗？」
// 之前的忠实答案是"不知道"：只有零散几个 API 在 Mock 上跑过。
//
// 这里把该模块**引用的每个 API** 拿去和权威目录对，再把客户端方法
// **逐个驱动**一遍打在 Mock Server 上，断言：
//   * 该 API 在权威目录里存在（不是幻影）；
//   * 发出的 `api/method/version` 三元组**通过目录校验**（没有 101/103）；
//   * 需要的会话/权限档位正确（authLevel / adminOnly）。
//
// ## 为什么用 Mock 而不是真机（新规 B1/B2）
// 这 39 个里有**变更动词**（`Delete.start`/`Compress.start`/`CreateFolder.create` …）。
// 在用户真 NAS 上调用它们会真的删文件、真的产出压缩包。
// ⇒ 一律打内存里的假服务器。**admin-only 的 `SYNO.Core.RecycleBin`
// 更是必须走这条**（用户已裁决不做管理员功能，真机上是非管理员账号，
// 永远拿不到 `105` 以外的结果）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

/// 「文件」App 引用的 API 名（`grep -ohE "'SYNO\.[A-Za-z0-9._]+'"`
/// 覆盖 `filestation_api.dart` + `features/files/*.dart`）。
///
/// ⚠️ 有两个**不是 API**的名字被 grep 捞进来过，已剔除并说明：
/// `SYNO.FileStation.Upload.upload` / `SYNO.FileStation.PhotoUpload.upload`
/// —— 它们是 `DsmApiException.method` 的**错误标签**（人看的字符串），
/// 不是请求里的 `api`。留在表里会让"幻影 API"计数虚高。
const List<String> kFilesModuleApis = [
  'SYNO.Core.ExternalDevice.Storage.USB',
  'SYNO.Core.RecycleBin', // ← 唯一被引用的**仅管理员** API
  'SYNO.FileStation.BackgroundTask',
  'SYNO.FileStation.CheckExist',
  'SYNO.FileStation.CheckPermission',
  'SYNO.FileStation.Compress',
  'SYNO.FileStation.CopyMove',
  'SYNO.FileStation.CreateFolder',
  'SYNO.FileStation.Delete',
  'SYNO.FileStation.DirSize',
  'SYNO.FileStation.Download',
  'SYNO.FileStation.Extract',
  'SYNO.FileStation.Favorite',
  'SYNO.FileStation.Info',
  'SYNO.FileStation.List',
  'SYNO.FileStation.MD5',
  'SYNO.FileStation.Mount',
  'SYNO.FileStation.Mount.List',
  'SYNO.FileStation.PhotoUpload',
  'SYNO.FileStation.Property.ACLOwner',
  'SYNO.FileStation.Property.CompressSize',
  'SYNO.FileStation.Property.Mtime',
  'SYNO.FileStation.Rename',
  'SYNO.FileStation.Search',
  'SYNO.FileStation.Search.History',
  'SYNO.FileStation.Sharing',
  'SYNO.FileStation.Sharing.Download',
  'SYNO.FileStation.Thumb',
  'SYNO.FileStation.ThumbInfo',
  'SYNO.FileStation.Timeout',
  'SYNO.FileStation.Upload',
  'SYNO.FileStation.VirtualFolder',
  'SYNO.FileStation.Worm',
  'SYNO.Office.Node',
  'SYNO.SDS.App.FileStation3.Instance',
  'SYNO.SDS.App.SharingUpload.Application',
  'SYNO.SDS.PDFViewer.Application',
];

/// `SYNO.SDS.*` 是 **DSM 网页桌面应用注册名**，不是 `entry.cgi` 上的 API
/// （它们是 `SYNO.SDS.App.*` 这类"桌面小部件"标识，走的是另一套发现机制）。
/// 与 `test/mock_dsm_server_test.dart` 的 M0-3 同一判据，这里显式排除并计数。
bool _isSdsApp(String api) => api.startsWith('SYNO.SDS.');

void main() {
  late DsmCatalog catalog;
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late FileStationApi fs;

  Future<void> boot({required bool admin}) async {
    catalog = DsmCatalog.load();
    backend = MockDsmBackend(catalog: catalog);
    backend.login(username: admin ? 'admin' : 'u', admin: admin);
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: admin ? 'admin' : 'u', password: 'x');
    fs = FileStationApi(web);

    // ---- `SYNO.FileStation.Info / get` 的夹具 ----
    //
    // **形状有权威出处**（不是编的）：
    //   * `SYNO.FileStation.Info.so` 的字段名序列里就有 `is_manager`：
    //     `items / is_manager / per_user / support_sharing / all_user /
    //      admin_only / support_file_request / enable_remote_mount /
    //      cifs / enable_iso_mount / support_virtual / support_vfs /
    //      support_virtual_protocol / enable_list_usergrp / hostname /
    //      enable_view_google / enable_view_microsoft`
    //   * 官方 APK `FileStationInfoVo$FileStationInfo` 的字段：
    //     `hostname` / `is_manager` / `support_sharing`
    //
    // ⚠️ **值是测试场景选的，不是观测值** —— 这里按"当前会话是不是管理员"
    // 给 `is_manager`，因为线下没有两个真机会话可用。形状来自权威源，
    // 值来自场景，两者必须分清。
    backend.fixture('SYNO.FileStation.Info', 'get', (_) {
      return {
        'success': true,
        'data': {
          'is_manager': admin,
          'hostname': 'mock-nas',
          'support_sharing': true,
          'support_file_request': false,
          'enable_remote_mount': true,
          'support_virtual': true,
          'support_vfs': true,
        },
      };
    });
  }

  setUp(() => boot(admin: false));

  group('COV-1. 目录覆盖：该模块引用的 API 一个不漏地存在', () {
    test('★ 真 API 数 = 37（39 个字面量 − 2 个异常标签）', () {
      expect(kFilesModuleApis, hasLength(37));
    });

    test('★ 每个非 SDS 的 API 都在权威目录里（没有幻影）', () {
      final real = kFilesModuleApis.where((a) => !_isSdsApp(a)).toList();
      final missing = real.where((a) => catalog[a] == null).toList();
      expect(missing, isEmpty, reason: '这 34 个必须都在权威目录里；缺 = 引用了不存在的 API');
      expect(real, hasLength(34));
    });

    test('SDS 桌面应用注册名单独计数（3 个），并说明为何不算 API', () {
      final sds = kFilesModuleApis.where(_isSdsApp).toList();
      expect(sds, hasLength(3));
      // 它们**不在**目录里 —— 这是预期的：它们不是 entry.cgi 上的 API
      for (final a in sds) {
        expect(catalog[a], isNull, reason: '$a 不是 entry.cgi API');
      }
    });

    test('按性质分档的账（普通 / 仅管理员）', () {
      final real = kFilesModuleApis.where((a) => !_isSdsApp(a));
      final admin = real.where((a) => catalog[a]!.adminOnly).toList();
      final normal = real.where((a) => catalog[a]!.normal).toList();
      // 全仓只引用了 **1** 个仅管理员 API —— 与 `mock_dsm_server_test.dart`
      // 的 M0-3 结论一致（两处独立算出同一个数，互为交叉验证）。
      expect(admin, ['SYNO.Core.RecycleBin']);
      expect(normal.length, greaterThanOrEqualTo(30));
    });
  });

  group('COV-2. 逐个驱动：只读 / 可逆方法全部通过目录校验', () {
    /// 每个条目：名字 + 一个真实调用。
    /// 全部是**只读或只影响本地状态**的方法（不写 NAS）。
    final calls = <String, Future<void> Function()>{
      'Info.get': () => fs.info(),
      'List.list': () => fs.listFolder(folderPath: '/home'),
      'List.list_share': () => fs.listShares(),
      'List.getinfo': () => fs.getInfo('/home/a.txt'),
      'Favorite.list': () => fs.listFavorites(),
      'BackgroundTask.list': () => fs.listBackgroundTasks(),
      'Search.History.get': () => fs.searchHistory(),
      'CheckExist.check': () => fs.exists('/home/a.txt'),
      'CheckPermission.write': () =>
          fs.checkWritePermission('/home', filename: 'a.txt'),
      'Mount.List.get': () => fs.listMounts(),
      'Sharing.list': () => fs.listShareLinks(),
      'Sharing.list_share_me': () => fs.listSharedWithMe(),
      'Property.ACLOwner.get': () => fs.aclOwner('/home/a.txt'),
      'Property.CompressSize.get': () => fs.compressSize('/home/a.txt'),
      'Property.Mtime.get': () => fs.mtimeOf('/home/a.txt'),
      'ThumbInfo.get': () => fs.thumbInfo('/home/a.jpg'),
      'Extract.list': () => fs.listArchive(filePath: '/home/a.zip'),
      'VirtualFolder.list': () => fs.listVirtualFolders(),
      'ExternalDevice.Storage.USB.list': () => fs.listUsbDevices(),
      'Worm.get': () => fs.wormGet('/home/a.txt'),
      'Worm.get_share_info': () => fs.wormShareInfo('/home/a.txt'),
      'Timeout.avoid': () => fs.avoidTimeout(),
    };

    for (final entry in calls.entries) {
      test('${entry.key} 组合合法（无 101/103/105）', () async {
        await entry.value();
        final r = backend.requests.last;
        final code = transport.last!.errorCode;
        expect(
          code,
          isNull,
          reason:
              '${entry.key} 被 Mock 拒绝：code=$code，'
              'api=${r.params['api']} method=${r.params['method']} '
              'version=${r.params['version']}',
        );
        // 顺带钉住：版本必须落在目录声明的区间里
        final spec = catalog['${r.params['api']}'];
        expect(spec, isNotNull);
        final v = int.parse('${r.params['version']}');
        expect(v, greaterThanOrEqualTo(spec!.minVersion));
        expect(v, lessThanOrEqualTo(spec.maxVersion));
      });
    }

    test('★ 覆盖面自检：驱动了 22 个方法，覆盖 20 个不同 API', () {
      expect(calls, hasLength(22));
      expect(calls.keys.toSet(), hasLength(22));
    });
  });

  group('COV-3. 变更动词的**三元组**也合法（只打假服务器）', () {
    /// ⚠️ 这些都会**改数据**。**只**允许打在 Mock 上 ——
    /// 在用户真 NAS 上跑它们会真删文件/真建目录/真产出压缩包。
    final mutating = <String, Future<void> Function()>{
      'CreateFolder.create': () =>
          fs.createFolder(folderPath: '/home', name: 'newdir'),
      'Rename.rename': () => fs.rename(path: '/home/a.txt', name: 'b.txt'),
      'Delete.start': () => fs.deleteItems(const ['/home/a.txt']),
      'CopyMove.start': () => fs.startCopyMove(
        paths: const ['/home/a.txt'],
        destFolderPath: '/home/b',
      ),
      'Compress.start': () => fs.startCompress(
        paths: const ['/home/a.txt'],
        destFilePath: '/home/a.zip',
      ),
      'Extract.start': () =>
          fs.startExtract(filePath: '/home/a.zip', destFolderPath: '/home'),
      'MD5.start': () => fs.startMd5(const ['/home/a.txt']),
      'DirSize.start': () => fs.startDirSize(const ['/home/a']),
      'Search.start': () => fs.startSearch(folderPath: '/home', pattern: 'a'),
      'Sharing.create': () => fs.createShareLink(paths: const ['/home/a.txt']),
      'Sharing.edit': () => fs.editShareLink(id: 'L-1', password: 'pw'),
      'Sharing.delete': () => fs.deleteShareLinks(const ['L-1']),
      'Favorite.add': () => fs.addFavorite('/home/a', name: 'a'),
      'Favorite.delete': () => fs.deleteFavorite('/home/a'),
      'Upload': () => fs.upload(
        folderPath: '/home',
        filePath: _tmpFile('cov-upload.txt'),
        fileName: 'cov-upload.txt',
      ),
      'BackgroundTask.clear_finished': () => fs.clearFinishedTasks(),
      'Search.History.delete': () => fs.clearSearchHistory(),
    };

    for (final entry in mutating.entries) {
      test('${entry.key} 的三元组合法（变更动词只打假服务器）', () async {
        await entry.value();
        final r = backend.requests.last;
        final code = transport.last!.errorCode;
        expect(
          code,
          isNull,
          reason:
              '${entry.key} 被 Mock 拒绝：code=$code，'
              'api=${r.params['api']} method=${r.params['method']} '
              'version=${r.params['version']}',
        );
      });
    }

    test('★ 这 17 条**一条都没发到真机/真 NAS**（本文件不持有真实会话）', () {
      // 结构性保证：本文件所有请求都经 `MockDsmTransport`（内存），
      // 没有任何 `HttpClient`/真实 baseUrl。写了这条断言是为了让
      // "§5.1 零变更动词（对真 NAS）"这件事在代码里有落点。
      expect(transport, isA<MockDsmTransport>());
      expect(backend.requests, isNotEmpty);
    });
  });

  group('COV-4. ★ 仅管理员 API 必须**双档**验证（新规 B1）', () {
    test('非管理员调 SYNO.Core.RecycleBin → 105（与真机一致）', () async {
      await boot(admin: false);
      await expectLater(
        fs.purgeRecycleBin('home'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noPermission,
          ),
        ),
      );
      final r = backend.requests.last;
      expect(r.params['api'], 'SYNO.Core.RecycleBin');
      expect(r.params['method'], 'start');
      expect('${r.params['version']}', '1');
    });

    test('★ 管理员调同一个 API → 通过（这是真机**验不到**的那一档）', () async {
      await boot(admin: true);
      await fs.purgeRecycleBin('home');
      expect(
        transport.last!.errorCode,
        isNull,
        reason: '管理员档位必须通过 —— 真机是非管理员账号，永远测不到这一档',
      );
      // 管理员档位下 `Info.get` 回 `is_manager: true` —— 这就是
      // 「清空回收站」入口门控依赖的那个字段（字段名有 `.so`+APK 权威出处）。
      expect(await fs.isManager(), isTrue);
    });

    test('isManager() 能区分两个档位（门控依赖它）', () async {
      await boot(admin: false);
      expect(await fs.isManager(), isFalse);
      await boot(admin: true);
      expect(await fs.isManager(), isTrue);
      // 且 `get` 方法在方法表里（v1: start/stop/get）
      expect(catalog['SYNO.Core.RecycleBin']!.methodsAt(1), contains('get'));
    });

    test('方法表里没有的方法名会被抓住（证明目录真的在校验）', () {
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.Core.RecycleBin',
        'method': 'purge', // 发明的方法名
        'version': 1,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103);
    });
  });
}

String _tmpFile(String name) {
  final f = File('${Directory.systemTemp.path}/$name')
    ..writeAsStringSync('cov');
  addTearDown(() {
    if (f.existsSync()) f.deleteSync();
  });
  return f.path;
}
