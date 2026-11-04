// Office **只读三跳通道**（本批真机修正）的离线用例。
//
// 钉死的真机真值（`docs/live-nas-verification.md` §⑦）：
//   1. `SYNO.Office.Snapshot:get` **v4** 对 `.odoc/.osheet/.oslides` 回原生内容树，
//      **不需要先 convert** → 它是只读主通道；
//   2. `Sheet.Snapshot.create` / `Doc.Snapshot.create` / `Presentation.Snapshot.create`
//      真机全回 **103（方法不存在）** → 代码里**绝不能**调用任何 `*.Snapshot.create`；
//   3. `link_id` = Drive 的 `permanent_link`，取法
//      `SynologyDrive.Files:get v2 {path:'/mydrive/<name>'}`；
//   4. **路径语义不可互换**：Drive API 只认 `/mydrive`（`/home/Drive` → 1000），
//      File Station 用 `/home/Drive`；
//   5. 优先级：`Snapshot:get` → File Station 原生字节 → Drive（转码：改扩展名 + 提示）；
//      任何一跳失败**静默回落**，只有全失败才弹错误面板。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_registry.dart'
    show AvailabilityState, hidesModule;
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/data/office_native/office_native_reader.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_providers.dart'
    show FileBytesRequest, fileBytesProvider;
import 'package:synhub/src/features/files/office_providers.dart'
    show officeApiProvider;
import 'package:synhub/src/features/files/drive_providers.dart'
    show driveApiProvider;
import 'package:synhub/src/features/files/office_viewer_page.dart';

import 'support/chat_harness.dart' show FakeTransport;
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/ofile_fixture.dart';

// ------------------------------------------------------------------ 夹具

const _apiTable = <String, Map<String, dynamic>>{
  'SYNO.Office.Snapshot': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Office.Node': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.FileStation.Download': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 真机 `Snapshot:get v4` 对 `.odoc` 的回包形态（§⑦.3 原文形态）：
/// `data.content = {data: {attrs: {type: document}, content: [...]}}`，
/// 与 OFile `@C_text/content` section 同形。
Map<String, Object?> snapshotOdocData() => {
  'comment': null,
  'content': {
    'version': 111,
    'data': {
      'type': 'doc',
      'attrs': {'schema': 13, 'type': 'document'},
      'content': [
        {
          'type': 'edit_area',
          'attrs': const {},
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '快照正文'},
              ],
            },
          ],
        },
      ],
    },
  },
  'file': const [],
  'ntype': 21,
  'object_id': '1028_SNAPSHOT0000000000000.doc',
};

Map<String, Object?> odocSections() => {
  'content': {
    'version': 111,
    'data': {
      'type': 'doc',
      'attrs': {'schema': 13, 'type': 'document'},
      'content': [
        {
          'type': 'edit_area',
          'attrs': const {},
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '原生字节正文'},
              ],
            },
          ],
        },
      ],
    },
  },
};

Uint8List odocBytes() => buildTestOFile(sections: odocSections());

FileEntryDto _entry(String name, {String path = 'drive:9'}) => FileEntryDto(
  name: name,
  path: path,
  isDir: false,
  size: 2048,
  mtime: 1789739500,
);

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 渲染一个只读查看器，返回收集到的取字节请求（证明走了哪一跳）。
Future<List<FileBytesRequest>> _pumpViewer(
  WidgetTester tester,
  FakeTransport transport, {
  required FileEntryDto entry,
  String linkId = '',
  String? drivePath,
  String? nativeBytesUrl,
  String? driveBytesUrl,
  Future<Uint8List> Function(FileBytesRequest req)? bytes,
}) async {
  final api = await _loggedIn(transport);
  final requests = <FileBytesRequest>[];
  final container = ProviderContainer(
    overrides: [
      officeApiProvider.overrideWithValue(OfficeApi(api)),
      driveApiProvider.overrideWithValue(DriveApi(api)),
      fileBytesProvider.overrideWith((ref, req) async {
        requests.add(req);
        if (bytes != null) return bytes(req);
        throw StateError('本用例不应走字节通道');
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: OfficeNativeViewer(
            entry: entry,
            linkId: linkId,
            drivePath: drivePath,
            nativeBytesUrl: nativeBytesUrl,
            bytesUrl: driveBytesUrl,
            onDownload: () {},
            onOpen: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return requests;
}

void main() {
  // ★★★ 第 256 轮：用户裁决 —— 「同一份文档在 nas files 里和 my drive 里打开不一样，
  // 这块需要保持统一，nas files 打开 office 三种格式要**调用 my drive 里的阅读器**」。
  //
  // 阅读器本来就是同一套（`officeNativeReadProvider` 三跳）；差别只在输入：
  // My Drive 有 `permanent_link`（⇒ 第一跳 `Snapshot:get`，高保真），
  // NAS「文件」只有 DSM 路径（`/home/Drive/x`）⇒ 原来直接掉到字节/文本降级路径。
  // 修法：把 DSM 路径映射成 Drive 路径（已取证的个人空间对应关系），
  // 第一跳就同样可用。
  group('★ 第 256 轮：NAS「文件」来源与 My Drive 走同一跳（用户裁决）', () {
    test('officeDrivePathForFileStationPath：只映射已取证的 /home/Drive ↔ /mydrive', () {
      expect(officeDrivePathForFileStationPath('/home/Drive'), '/mydrive');
      expect(
        officeDrivePathForFileStationPath('/home/Drive/报告.odoc'),
        '/mydrive/报告.odoc',
      );
      expect(
        officeDrivePathForFileStationPath('/home/Drive/a b/c.oslides'),
        '/mydrive/a b/c.oslides',
        reason: '子目录与空格都要原样保留',
      );
      // 未取证的映射一概不猜
      expect(officeDrivePathForFileStationPath('/docker/x.odoc'), isNull);
      expect(officeDrivePathForFileStationPath('/volume1/homes/x.odoc'), isNull);
      expect(officeDrivePathForFileStationPath('/home/DriveX'), isNull);
      expect(officeDrivePathForFileStationPath('   '), isNull);
    });

    testWidgets(
      '★ 文件来源（只有 DSM 路径，没给 linkId/drivePath）⇒ 自动补 Drive 路径并命中 Snapshot:get',
      (tester) async {
        final t = FakeTransport({
          // Drive 侧按路径换 `permanent_link`（真机取法：Files:get v2）
          'SYNO.SynologyDrive.Files.get': {
            'file_id': '9',
            'name': '报告.odoc',
            'type': 'file',
            'display_path': '/mydrive/报告.odoc',
            'dsm_path': '/home/Drive/报告.odoc',
            'permanent_link': 'LINK_FROM_NAS_PATH',
            'size': 2048,
          },
          'SYNO.Office.Snapshot.get': snapshotOdocData(),
        }, {...FakeTransport.table, ..._apiTable});
        final requests = await _pumpViewer(
          tester,
          t,
          entry: _entry('报告.odoc', path: '/home/Drive/报告.odoc'),
          // 关键：**不给** linkId / drivePath —— 这正是从 NAS「文件」打开时的样子
        );

        final snap = t.calls.singleWhere(
          (c) => c['api'] == 'SYNO.Office.Snapshot',
        );
        expect(
          snap['link_id'],
          'LINK_FROM_NAS_PATH',
          reason: '★ NAS 路径必须先换成 Drive 的 permanent_link 再打 Snapshot',
        );
        expect(
          requests,
          isEmpty,
          reason: '★ 第一跳命中就不该再落回 FileStation 字节通道（那正是"两边不一样"的原因）',
        );
        expect(find.text('快照正文'), findsOneWidget, reason: '高保真内容树要真的渲染出来');
      },
    );

    testWidgets('★ 非 Drive 可映射路径（/docker）不给 Drive 路径，仍走原有字节跳', (tester) async {
      final t = FakeTransport({
        'SYNO.Office.Snapshot.get': snapshotOdocData(),
      }, {...FakeTransport.table, ..._apiTable});
      final requests = await _pumpViewer(
        tester,
        t,
        entry: _entry('报告.odoc', path: '/docker/报告.odoc'),
        bytes: (req) async => odocBytes(),
      );
      expect(
        t.calls.any((c) => c['api'] == 'SYNO.SynologyDrive.Files'),
        isFalse,
        reason: '不猜映射：非个人空间路径不该去打 Drive',
      );
      expect(requests, isNotEmpty, reason: '回落通道必须仍然可用');
    });
  });

  group('① Snapshot:get 主通道（URL 形态 / link_id）', () {
    testWidgets('link_id 已知 → Snapshot:get v4 命中，不再走字节通道', (tester) async {
      final t = FakeTransport(
        {'SYNO.Office.Snapshot.get': snapshotOdocData()},
        {...FakeTransport.table, ..._apiTable},
      );
      final requests = await _pumpViewer(
        tester,
        t,
        entry: _entry('报告.odoc'),
        linkId: 'LINK_SNAPSHOT_1',
      );

      // 主通道命中：原生内容树渲染出来了。
      expect(find.byKey(const Key('office-native-viewer')), findsOneWidget);
      // 开发者横幅（"只读预览 / 本批不支持编辑"）已删除 → 断言**不存在**。
      expect(find.textContaining('只读预览'), findsNothing);
      expect(find.text('快照正文'), findsOneWidget);

      // URL 形态钉死：api / method / version=4 / link_id。
      final call = t.calls.singleWhere(
        (c) => c['api'] == 'SYNO.Office.Snapshot',
      );
      expect(call['method'], 'get');
      expect(call['version'], '4', reason: '真机只取证了 v4');
      expect(call['link_id'], 'LINK_SNAPSHOT_1');
      expect(
        call.containsKey('object_id'),
        isFalse,
        reason: 'Snapshot:get 只认 link_id，绝不混用 object_id',
      );
      expect(requests, isEmpty, reason: '第一跳命中就不该再取字节');
      expect(
        t.calls.any((c) => '${c['api']}'.contains('Snapshot.create')),
        isFalse,
        reason: '真机 103：绝不能调用任何 *.Snapshot.create',
      );
    });

    testWidgets(
      'link_id 为空 → 先 Files:get {path:/mydrive/...} 取 permanent_link，再 Snapshot:get',
      (tester) async {
        final t = FakeTransport(
          {
            'SYNO.SynologyDrive.Files.get': {
              'permanent_link': 'LINK_FROM_DRIVE',
            },
            'SYNO.Office.Snapshot.get': snapshotOdocData(),
          },
          {...FakeTransport.table, ..._apiTable},
        );
        await _pumpViewer(
          tester,
          t,
          entry: _entry('报告.odoc'),
          drivePath: '/mydrive/报表/报告.odoc',
        );

        expect(find.text('快照正文'), findsOneWidget);
        final driveCall = t.calls.singleWhere(
          (c) => c['api'] == 'SYNO.SynologyDrive.Files' && c['method'] == 'get',
        );
        // Drive 路径语义：只认 /mydrive（真机 /home/Drive → 1000）。
        expect(driveCall['path'], '/mydrive/报表/报告.odoc');
        expect('${driveCall['path']}', isNot(contains('/home/Drive')));
        expect(driveCall['version'], '2', reason: '真机取 permanent_link 用的是 v2');
        final snap = t.calls.singleWhere(
          (c) => c['api'] == 'SYNO.Office.Snapshot',
        );
        expect(snap['link_id'], 'LINK_FROM_DRIVE');
      },
    );

    testWidgets('缺能力位（partial）→ Snapshot 通道跳过并回落，模块不隐藏', (tester) async {
      // 能力表里**没有** `SYNO.Office.Snapshot` → 第一跳必须跳过。
      final tableWithoutSnapshot = Map<String, Map<String, dynamic>>.from(
        _apiTable,
      )..remove('SYNO.Office.Snapshot');
      final t = FakeTransport(
        {'SYNO.Office.Snapshot.get': snapshotOdocData()},
        {...FakeTransport.table, ...tableWithoutSnapshot},
      );
      const nativeUrl =
          'https://fake.test/webapi/entry.cgi?api=FileStation.Download';
      final requests = await _pumpViewer(
        tester,
        t,
        entry: _entry('报告.odoc'),
        linkId: 'LINK_1',
        nativeBytesUrl: nativeUrl,
        bytes: (req) async => odocBytes(),
      );

      expect(
        t.calls.any((c) => c['api'] == 'SYNO.Office.Snapshot'),
        isFalse,
        reason: '能力位缺位 → 第一跳必须跳过',
      );
      expect(requests.single.url, nativeUrl);
      expect(find.text('原生字节正文'), findsOneWidget);
      expect(hidesModule(AvailabilityState.partial), isFalse);
    });
  });

  group('② 回落：Snapshot 不可用 → File Station 原生字节', () {
    testWidgets('Snapshot 回 105 → 静默回落原生字节，不弹错误面板', (tester) async {
      final t = FakeTransport(
        {'SYNO.Office.Snapshot.get': const {}},
        {...FakeTransport.table, ..._apiTable},
      );
      t.failures['SYNO.Office.Snapshot.get'] = 105;
      const nativeUrl =
          'https://fake.test/webapi/entry.cgi?api=FileStation.Download';
      final bytes = odocBytes();
      final requests = await _pumpViewer(
        tester,
        t,
        entry: _entry('报告.odoc'),
        linkId: 'LINK_1',
        nativeBytesUrl: nativeUrl,
        driveBytesUrl: 'https://fake.test/drive/download',
        bytes: (req) async => bytes,
      );

      expect(find.byKey(const Key('office-native-viewer')), findsOneWidget);
      expect(find.text('原生字节正文'), findsOneWidget);
      expect(find.byKey(const Key('office-native-error')), findsNothing);
      expect(requests.single.url, nativeUrl, reason: '第二跳 = File Station 原生字节');
    });
  });

  group('③ 再回落：Drive 转码 → 改扩展名 + 提示', () {
    testWidgets('Snapshot + 原生字节都不可用 → Drive 直链被识别为转码包', (tester) async {
      final t = FakeTransport(
        {'SYNO.Office.Snapshot.get': const {}},
        {...FakeTransport.table, ..._apiTable},
      );
      t.failures['SYNO.Office.Snapshot.get'] = 105;
      final requests = await _pumpViewer(
        tester,
        t,
        entry: _entry('预算.osheet'),
        linkId: 'LINK_1',
        driveBytesUrl: 'https://fake.test/drive/download',
        // OOXML/zip（PK\x03\x04）= Drive 转码产物。
        bytes: (req) async =>
            Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 1, 2, 3]),
      );

      expect(requests.single.url, 'https://fake.test/drive/download');
      expect(find.text('拿到的是转换后的文件'), findsOneWidget);
      expect(find.textContaining('OOXML/zip'), findsOneWidget);
      expect(find.text('打不开这个 Office 文档'), findsNothing);
    });

    test('下载决策：没有原生直链 → 保存为真实扩展名并标记已转换', () {
      final plan = planOfficeDownload(
        name: '预算.osheet',
        driveUrl: 'https://fake.test/drive/download',
        nativeUrl: null,
      );
      expect(plan.transcoded, isTrue);
      expect(plan.saveName, '预算.xlsx', reason: '.osheet 里装的其实是 xlsx，必须改名');
      expect(plan.saveName, isNot(endsWith('.osheet')));
    });
  });

  group('④⑤ 错误码纪律', () {
    testWidgets('全通道 105 → 无权限提示', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._apiTable});
      t.failures['SYNO.Office.Snapshot.get'] = 105;
      await _pumpViewer(
        tester,
        t,
        entry: _entry('受限.osheet', path: '/home/Drive/受限.osheet'),
        linkId: 'LINK_1',
        bytes: (req) async =>
            throw DsmApiException(105, method: 'SYNO.FileStation.Download'),
      );
      expect(find.text('无权限读取这份文档'), findsOneWidget);
    });

    testWidgets('全通道 119 → 会话提示，且**绝不隐藏模块**', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._apiTable});
      t.failures['SYNO.Office.Snapshot.get'] = 119;
      await _pumpViewer(
        tester,
        t,
        entry: _entry('会话.osheet', path: '/home/Drive/会话.osheet'),
        linkId: 'LINK_1',
        bytes: (req) async =>
            throw DsmApiException(119, method: 'SYNO.FileStation.Download'),
      );
      expect(find.text('会话已过期'), findsOneWidget);
      expect(
        hidesModule(AvailabilityState.sessionExpired),
        isFalse,
        reason: '119/106 绝不隐藏模块',
      );
      expect(hidesModule(AvailabilityState.partial), isFalse);
    });
  });

  group('⑥ 路径语义：Drive 用 /mydrive、File Station 用 /home/Drive（不混用）', () {
    test('Drive API 取 permanent_link 只发 /mydrive', () async {
      final t = FakeTransport(
        {
          'SYNO.SynologyDrive.Files.get': {
            'file_id': '77',
            'permanent_link': '19yWHSFsnwKCjheEtq0WKNPLmGxy0W1r',
          },
        },
        {...FakeTransport.table, ..._apiTable},
      );
      final api = await _loggedIn(t);
      final link = await DriveApi(api).permanentLinkForPath(
        path: '/mydrive/Annual income and expenditure.osheet',
      );

      expect(link, '19yWHSFsnwKCjheEtq0WKNPLmGxy0W1r');
      final call = t.calls.singleWhere(
        (c) => c['api'] == 'SYNO.SynologyDrive.Files',
      );
      expect(call['api'], 'SYNO.SynologyDrive.Files');
      expect(call['method'], 'get');
      expect(call['path'], '/mydrive/Annual income and expenditure.osheet');
      expect('${call['path']}', isNot(contains('/home/Drive')));
    });

    test('File Station 下载直链只发 /home/Drive', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._apiTable});
      final fs = FileStationApi(await _loggedIn(t));
      final url = fs.downloadUrl(['/home/Drive/报表/报告.odoc']);
      final decoded = Uri.decodeComponent(url);
      expect(decoded, contains('/home/Drive/报表/报告.odoc'));
      expect(decoded, isNot(contains('/mydrive')));
    });

    test('officeNativeFileStationPath：/mydrive → /home/Drive，绝不给 Drive 用', () {
      expect(
        officeNativeFileStationPath(
          dsmPath: '',
          displayPath: '/mydrive/报表/报告.odoc',
        ),
        '/home/Drive/报表/报告.odoc',
      );
      expect(
        officeNativeFileStationPath(
          dsmPath: '/home/Drive/报表/报告.odoc',
          displayPath: '/mydrive/报表/报告.odoc',
        ),
        '/home/Drive/报表/报告.odoc',
      );
      for (final p in [
        officeNativeFileStationPath(
          dsmPath: '',
          displayPath: '/mydrive/a.odoc',
        ),
        officeNativeFileStationPath(
          dsmPath: '/home/Drive/a.odoc',
          displayPath: '/mydrive/a.odoc',
        ),
      ]) {
        expect(p, isNotNull);
        expect(p, startsWith('/home/Drive'));
        expect(p, isNot(contains('/mydrive')));
      }
    });
  });

  group('优先级与内容树适配（纯函数）', () {
    test(
      'officeReadHopOrder：Snapshot → FileStationNative → Drive → byPath',
      () {
        expect(
          officeReadHopOrder(
            snapshotUsable: true,
            hasNativeUrl: true,
            hasDriveUrl: true,
          ),
          [
            OfficeReadHop.snapshot,
            OfficeReadHop.fileStationNative,
            OfficeReadHop.driveBytes,
          ],
        );
        expect(
          officeReadHopOrder(
            snapshotUsable: false,
            hasNativeUrl: false,
            hasDriveUrl: true,
          ),
          [OfficeReadHop.driveBytes],
        );
        expect(
          officeReadHopOrder(
            snapshotUsable: false,
            hasNativeUrl: false,
            hasDriveUrl: false,
          ),
          [OfficeReadHop.byPath],
        );
      },
    );

    test('officeSectionsFromSnapshot：odoc 同形直接接；osheet 形态未取证 → null', () {
      final sections = officeSectionsFromSnapshot(
        snapshotOdocData(),
        format: OfficeNativeFormat.odoc,
      );
      expect(sections, isNotNull);
      expect(sections!.keys, ['content']);
      final doc = OfficeNativeReader.parseSections(
        sections,
        format: OfficeNativeFormat.odoc,
      );
      expect(doc.document, isNotNull);
      expect(doc.document!.plainText, contains('快照正文'));

      // `.osheet` 的内容树 ↔ 原生 section 映射未取证：不猜，返回 null 触发回落。
      expect(
        officeSectionsFromSnapshot({
          'content': {
            'data': {
              'attrs': {'type': 'sheet'},
            },
          },
        }, format: OfficeNativeFormat.osheet),
        isNull,
      );
      // 只有回包本身长得像 section 字典才敢用。
      expect(
        officeSectionsFromSnapshot({
          'content': {
            'index': {
              'order': ['sh_1'],
            },
            'sh_1': {'rowCount': 1, 'colCount': 1, 'cells': const {}},
          },
        }, format: OfficeNativeFormat.osheet),
        isNotNull,
      );
    });
  });
}
