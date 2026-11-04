// §11 第 ③ 项：Drive 的 `Office.Node.Version` 与 Drive 侧后台任务。
//
// 接口形态全部有**官方出处**（NAS 上实际装的包 + 官方 Web 前端调用点）：
//   * Office 3.8.0-22711：`SYNO.Office.Node.Version` v1 = `get list restore rename`
//     （`allowUser` 含 normal.*），调用形态见 `ui/dist/ui.doc.js` 的
//     `SYNO.SDS.Office.History.Store` / `GetAction().renameVersion|restoreVersion`；
//   * Drive 4.2.0-30058：`SYNO.SynologyDrive.Tasks` v1 = `list get delete`，
//     官方前端 `drive/synodrive_common.js` 里 `list_tasks` / `delete_task`。
//
// 这里钉的是"参数与版本发对了、回包解析对了、页面动作接对了"。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/dto/drive_task_dto.dart';
import 'package:synhub/src/data/dto/office_version_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/drive_revisions_page.dart';
import 'package:synhub/src/features/files/drive_tasks_page.dart';
import 'package:synhub/src/features/files/office_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Revisions': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Tasks': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Office.Node': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.Office.Node.Version': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Office.Export': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.File': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
};

DriveEntryDto _entry({
  String name = '报告.odoc',
  String fileId = '9',
  String permanentLink = '19wEMJG0KyQTlkshZgwjHzL48cT9JYKR',
}) => DriveEntryDto(
  fileId: fileId,
  name: name,
  type: 'file',
  path: '/$name',
  displayPath: '/mydrive/$name',
  parentId: '1',
  size: 2048,
  modifiedTime: 1789775507,
  createdTime: 1789775501,
  contentType: 'document',
  starred: false,
  shared: false,
  owner: 'demo_user',
  canDownload: true,
  canPreview: true,
  canWrite: true,
  capabilities: const {'can_write': true},
  versionId: '65',
  permanentLink: permanentLink,
);

/// 官方 `Node.Version/list` 的真实回包形状（`versions` 根 + 这些字段名）
Map<String, dynamic> versionsPayload() => {
  'versions': [
    {
      'version': '7',
      'author': {'uid': 4, 'name': 'demo_user', 'nickname': 'demo_user'},
      'mtime': 1789775507,
      'editors': ['demo_user'],
      'ver_name': '定稿',
      'commit_msg': '交付版本',
      'first_version': false,
      'listable': true,
      'title': '报告',
    },
    {
      'version': '1',
      'author': 'demo_user',
      'mtime': 1789000000,
      'editors': ['demo_user', 'guest'],
      'ver_name': '',
      'first_version': true,
      'listable': true,
    },
  ],
  'total': 2,
};

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (responses.containsKey(key)) return responses[key]!;
    return {'success': true};
  };
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(DriveApi(api)),
      officeApiProvider.overrideWithValue(OfficeApi(api)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  return (t: t, c: c);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Office 版本 · 接口层', () {
    late FakeTransport t;
    late OfficeApi office;

    setUp(() async {
      t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        if ('${params['method']}' == 'list') return versionsPayload();
        return {'success': true};
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      office = OfficeApi(api);
    });

    test('列表：v1 + Drive 页形态 path=id: + additional + 分页', () async {
      final vers = await office.nodeVersions(fileId: '9');
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'list');
      expect(call['api'], 'SYNO.Office.Node.Version');
      expect('${call['version']}', '1');
      // 官方 Drive 页用的是 `Utils.getPathId(file_id)` = id:<file_id>；
      // 真机 `Node:list` 不存在（103）、`Node:get {object_id}` → 1000 ⇒ 只发 path
      expect(call['path'], 'id:9');
      expect(
        call.containsKey('object_id'),
        isFalse,
        reason: 'object_id 形态已被真机否掉',
      );
      expect(call['limit'], '30', reason: '官方首批 limit=30');
      expect(call['offset'], '0');
      expect(call['additional'], contains('"uid":true'));
      expect(call['additional'], contains('"nickname":true'));

      expect(vers.length, 2);
      expect(vers.first.version, '7');
      expect(vers.first.verName, '定稿');
      expect(vers.first.label, '定稿');
      // author 两种形态（字符串 / {uid,name,nickname}）都要能出名字
      expect(vers.first.author, 'demo_user');
      expect(vers[1].author, 'demo_user');
      expect(vers[1].label, '未命名版本', reason: '内部 hash 不上界面');
      expect(vers[1].firstVersion, isTrue);
      expect(vers[1].editors, ['demo_user', 'guest']);
      // mtime 是**秒**（官方 Ext reader 直接喂 Date）
      expect(vers.first.modifiedTime!.year, 2026);
    });

    test('列表只打一次 path（不再有"被拒后换 object_id"的兜底）', () async {
      // 旧代码在遇到 57351 时会用 permanent_link 当 object_id 再试一次 ——
      // 写入批次真机证明 `object_id` 入参形态根本不被接受（1000），
      // 且 permanent_link 不是 object_id ⇒ 该兜底已删，错误如实抛出。
      t.failTimes['SYNO.Office.Node.Version.list'] = 1000;
      await expectLater(
        office.nodeVersions(fileId: '9'),
        throwsA(isA<DsmApiException>()),
      );
      final listCalls = t.calls
          .where((c) => '${c['method']}' == 'list')
          .toList();
      expect(listCalls, hasLength(1), reason: '只发一种形态，不拿 link_id 乱试');
      expect(listCalls.single['path'], 'id:9');
      expect(listCalls.single.containsKey('object_id'), isFalse);
    });

    test('恢复统一发 path=id:<file_id>（不再用 Node/get 的内部 id）', () async {
      await office.restoreNodeVersion(fileId: '9', version: '7');
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'restore');
      expect('${call['version']}', '1');
      // 真机在 Node.Version:list 上验过 path=id:<file_id>；object_id 的来源
      // （Node:get 的 object_id 入参）已被真机否掉（1000）⇒ 统一走 path
      expect(call['path'], 'id:9');
      expect(call.containsKey('object_id'), isFalse);
      expect(call['ver'], '7');
      expect(call.containsKey('password'), isFalse, reason: '未加密文档不带 password');
    });

    test('解析内部 id：Office.Node/get v1 + **只发 path** + basic:true，并缓存', () async {
      t.onCall = (params) {
        if ('${params['api']}.${params['method']}' == 'SYNO.Office.Node.get') {
          return {
            'object_id': '1028_35AO5B4V1P53DFEPKM2O8',
            'title': 'Untitled',
          };
        }
        return {'success': true};
      };
      final id = await office.resolveObjectId(fileId: '9');
      expect(id, '1028_35AO5B4V1P53DFEPKM2O8');
      final call = t.calls.lastWhere(
        (c) => '${c['api']}' == 'SYNO.Office.Node',
      );
      expect('${call['version']}', '1');
      expect(call['path'], 'id:9', reason: '官方 Drive 页用 getPathId');
      expect(call['basic'], 'true');
      // 真机 `Node:get {object_id}` → 1000（该形态已删）；`Node:list` → 103（不存在）
      expect(call.containsKey('object_id'), isFalse);
      expect(call['method'], 'get', reason: 'Node 族根本没有 list 方法');
      // 第二次不再打接口（缓存）
      final before = t.calls.length;
      expect(await office.resolveObjectId(fileId: '9'), id);
      expect(t.calls.length, before);
    });

    test('★ r314：不同文件各自的 object_id 不许串台（会话级单例 + 按文件缓存）',
        () async {
      // 真机缺陷：`officeApiProvider` 是会话级单例，而旧实现把 `object_id` 缓存在
      // **不带 key 的字段**里 ⇒ 第二个文件拿到第一个文件的 id，
      // `Permission:check` 因 object/link 不配对而三位全 false（界面说"没权限"）。
      t.onCall = (params) {
        if ('${params['api']}.${params['method']}' == 'SYNO.Office.Node.get') {
          final path = '${params['path']}';
          final fileId = path.startsWith('id:') ? path.substring(3) : path;
          return <String, Object?>{'object_id': '1028_OBJ_$fileId.doc'};
        }
        return {'success': true};
      };
      expect(await office.resolveObjectId(fileId: '9'), '1028_OBJ_9.doc');
      // 第二个文件必须**自己问一次**，且拿到自己的 id（不是 9 的那个）
      expect(await office.resolveObjectId(fileId: '10'), '1028_OBJ_10.doc');
      final paths = t.calls
          .where((c) => '${c['method']}' == 'get')
          .map((c) => '${c['path']}')
          .toList();
      expect(paths, <String>['id:9', 'id:10'], reason: '每个文件各问一次，不许复用');
      // 回头再问 9 仍是 9 的 id，且**不再打接口**（按文件缓存仍有效）
      final before = t.calls.length;
      expect(await office.resolveObjectId(fileId: '9'), '1028_OBJ_9.doc');
      expect(await office.resolveObjectId(fileId: '10'), '1028_OBJ_10.doc');
      expect(t.calls.length, before, reason: '同一文件重复问仍走缓存');
    });

    test('命名：rename v1 **只发 object_id**（官方白名单里没有 path）', () async {
      await office.renameNodeVersion(
        objectId: '1028_ABC',
        version: '7',
        verName: '定稿',
      );
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'rename');
      expect('${call['version']}', '1');
      expect(call['object_id'], '1028_ABC');
      expect(call.containsKey('path'), isFalse, reason: 'rename 不认 path');
      expect(call['ver'], '7');
      expect(call['ver_name'], '定稿');
      expect(call['overwrite'], 'true', reason: '官方传 overwrite:true');
    });

    test('path 形态被拒（1000）→ 如实抛出，不拿 link_id 当 object_id 乱试', () async {
      // 旧实现：第一次（path）失败 → 第二次把 Drive 的 permanent_link 当
      // `object_id` 再试。写入批次真机推翻该兜底：`Node:get {object_id}` → 1000、
      // `Node:list` → 103（不存在），且 permanent_link 从来不是 object_id。
      t.failTimes['SYNO.Office.Node.Version.list'] = 1000;
      await expectLater(
        office.nodeVersions(fileId: '9'),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 1000)),
      );

      final listCalls = t.calls
          .where((c) => '${c['method']}' == 'list')
          .toList();
      expect(listCalls, hasLength(1));
      expect(listCalls.single['path'], 'id:9');
      expect(listCalls.single.containsKey('object_id'), isFalse);
    });

    test('导出某个版本的直链：Export/download v1 + path=id: + 目标扩展名 + ver', () {
      final url = office.nodeVersionDownloadUrl(
        fileId: '9',
        version: '7',
        fileName: '报告.odoc',
      );
      expect(url, contains('SYNO.Office.Export'));
      expect(url, contains('method=download'));
      expect(url, contains('version=1'));
      expect(url, contains(Uri.encodeComponent('id:9')));
      // 真机唯一验过的 format 是**目标扩展名**（xlsx）；`ms` 只是官方档位名
      expect(url, contains('format=docx'));
      expect(url, isNot(contains('format=ms')));
      expect(url, isNot(contains('object_id')));
      expect(url, contains('ver=7'));
      // 官方 `EXPORT_EXTENSION`：odoc → docx
      expect(Uri.decodeFull(url), contains('报告.docx'));
    });

    test('扩展名判定与导出名（官方 isOfficeFile / EXPORT_EXTENSION）', () {
      expect(isOfficeNativeName('a.odoc'), isTrue);
      expect(isOfficeNativeName('a.OSHEET'), isTrue);
      expect(isOfficeNativeName('a.oslides'), isTrue);
      expect(isOfficeNativeName('a.docx'), isFalse);
      expect(isOfficeNativeName('odoc'), isFalse);
      expect(exportFileName('a.odoc'), 'a.docx');
      expect(exportFileName('a.osheet'), 'a.xlsx');
      expect(exportFileName('a.oslides'), 'a.pptx');
      expect(exportFileName('a.png'), 'a.png');
    });
  });

  group('Office 版本 · 页面层', () {
    testWidgets('Office 文档走 Office 版本（不是 Revisions），并标出命名/初始版本', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        DriveRevisionsPage(entry: _entry()),
        responses: {
          'SYNO.Office.Node.Version.list': versionsPayload(),
          'SYNO.Office.Node.get': {'object_id': '1028_35AO5B4V1P53DFEPKM2O8'},
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('版本历史'), findsOneWidget);
      // r508：品牌行改正常大小写（`Synology Office · …`）。
      expect(find.textContaining('Synology Office'), findsOneWidget);
      expect(find.text('定稿'), findsOneWidget);
      expect(find.text('未命名版本'), findsOneWidget);
      expect(find.textContaining('初始版本'), findsOneWidget);
      expect(find.textContaining('交付版本'), findsOneWidget);
      // **不该**去打 Drive 的 Revisions
      expect(
        boot.t.calls.any((c) => '${c['api']}'.contains('Revisions')),
        isFalse,
        reason: 'Office 文档在官方就是走 Office.Node.Version',
      );
    });

    testWidgets('恢复：二次确认后才发 restore，且提示"稍等几秒"', (tester) async {
      final boot = await _pump(
        tester,
        DriveRevisionsPage(entry: _entry()),
        responses: {
          'SYNO.Office.Node.Version.list': versionsPayload(),
          'SYNO.Office.Node.get': {'object_id': '1028_35AO5B4V1P53DFEPKM2O8'},
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('恢复到这个版本').first);
      await tester.pumpAndSettle();
      expect(find.text('恢复到这个版本？'), findsOneWidget);
      await tester.tap(find.text('恢复'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final call = boot.t.calls.lastWhere(
        (c) => '${c['method']}' == 'restore',
        orElse: () => throw StateError('没有发 restore'),
      );
      // 真机验过的形态：`path=id:<file_id>`（不再用 Node/get 的内部 id）
      expect(call['path'], 'id:9');
      expect(call.containsKey('object_id'), isFalse);
      expect(call['ver'], '7');
      expect(find.textContaining('已恢复'), findsOneWidget);
    });

    testWidgets('命名版本：填名称 → rename(ver_name)', (tester) async {
      final boot = await _pump(
        tester,
        DriveRevisionsPage(entry: _entry()),
        responses: {
          'SYNO.Office.Node.Version.list': versionsPayload(),
          'SYNO.Office.Node.get': {'object_id': '1028_35AO5B4V1P53DFEPKM2O8'},
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('命名这个版本').first);
      await tester.pumpAndSettle();
      expect(
        find.text('更改版本名称'),
        findsOneWidget,
        reason: '已有名字 → 官方 change_version_name',
      );
      await tester.enterText(find.byType(TextField), '终稿');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final call = boot.t.calls.lastWhere(
        (c) => '${c['method']}' == 'rename',
        orElse: () => throw StateError('没有发 rename'),
      );
      // 先经 Node/get 解析内部 id，再按官方 rename 形态发 object_id
      expect(call['object_id'], '1028_35AO5B4V1P53DFEPKM2O8');
      expect(call.containsKey('path'), isFalse);
      expect(call['ver'], '7');
      expect(call['ver_name'], '终稿');
      expect(call['overwrite'], 'true');
      expect(find.textContaining('已命名为'), findsOneWidget);
    });

    testWidgets('拿不到内部 id → 不发 rename，直接说明原因（而非 114）', (tester) async {
      final boot = await _pump(
        tester,
        DriveRevisionsPage(entry: _entry()),
        responses: {'SYNO.Office.Node.Version.list': versionsPayload()},
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('命名这个版本').first);
      await tester.pumpAndSettle();
      // 没有 Node/get 回包 → 解析不出内部 id → 连对话框都不该弹
      expect(find.text('服务端没给出这份文档的内部 id，暂时不能命名版本'), findsOneWidget);
      expect(
        boot.t.calls.any((c) => '${c['method']}' == 'rename'),
        isFalse,
        reason: 'rename 只认 object_id，缺了就别发（省得用户看到"缺少必需参数"）',
      );
    });

    testWidgets('普通文件仍然走 Drive 的 Revisions', (tester) async {
      final boot = await _pump(
        tester,
        DriveRevisionsPage(entry: _entry(name: '报告.docx')),
        responses: {
          'SYNO.SynologyDrive.Revisions.list': {
            'items': [
              {
                'version_id': 65,
                'size': 2048,
                'modified_time': 1789775507,
                'editor_display_name': 'demo_user',
              },
            ],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      // r508：品牌行改成正常大小写（`Synology Drive · …`），不再全大写。
      // DA151 的守卫会盯住"features 里不许再出现全大写品牌码"。
      expect(find.textContaining('Synology Drive'), findsOneWidget);
      expect(find.textContaining('版本号 65'), findsOneWidget);
      expect(
        boot.t.calls.any((c) => '${c['api']}'.contains('Office')),
        isFalse,
        reason: '非 Office 文档不该碰 Office API',
      );
    });

    testWidgets('office 版本列表挂了 → 说人话 + 可重试', (tester) async {
      await _pump(
        tester,
        DriveRevisionsPage(entry: _entry()),
        failures: {'SYNO.Office.Node.Version.list': 1000},
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('打不开版本历史'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('Drive 后台任务 · 接口层', () {
    late FakeTransport t;
    late DriveApi drive;

    setUp(() async {
      t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        if ('${params['method']}' == 'list') {
          return {
            'items': [
              {
                'task_id': 't1',
                'status': 'in_progress',
                'progress': 0.5,
                'in_progress': true,
                'result': {
                  'action': 'upload',
                  'names': ['a.png'],
                  'total_size': 2048,
                  'task_id': 't1',
                },
              },
              {
                'task_id': 't2',
                'status': 'finished',
                'progress': 100,
                'result': {
                  'action': 'download',
                  'names': ['b.bin', 'c.bin'],
                  'total_size': 1048576,
                  'task_id': 't2',
                },
              },
            ],
            'total': 2,
          };
        }
        return {'success': true};
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      drive = DriveApi(api);
    });

    test('列表：Tasks/list v1 + 分页；解析 result.action/names/progress', () async {
      final tasks = await drive.listTasks();
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'list');
      expect(call['api'], 'SYNO.SynologyDrive.Tasks');
      expect('${call['version']}', '1');
      expect(call['offset'], '0');
      expect(call['limit'], '200');

      expect(tasks.length, 2);
      expect(tasks.first.action, 'upload');
      expect(tasks.first.inProgress, isTrue);
      expect(tasks.first.progress, 50, reason: '0–1 的小数要归一成百分比');
      expect(tasks.first.title, '上传 · a.png');
      expect(tasks.first.humanSize, '2.0 KB');
      expect(tasks[1].finished, isTrue);
      expect(tasks[1].title, contains('下载'));
      expect(tasks[1].title, contains('等 2 项'));
      expect(tasks[1].humanSize, '1.0 MB');
    });

    test('单条：Tasks/get v1 + {task_id}；两种回包形状都认', () async {
      // 官方 `ApiSynoDriveTasks.setAsGet(String)`：参数名就是 `task_id`
      // （`:82` 起 `const-string "task_id"`），方法枚举只有 list/get/delete。
      t.onCall = (params) {
        if ('${params['method']}' == 'get') {
          return {
            'task_id': 't1',
            'status': 'in_progress',
            'progress': 0.5,
            'result': {
              'action': 'upload',
              'names': ['a.png'],
              'total_size': 2048,
              'task_id': 't1',
            },
          };
        }
        return {'success': true};
      };
      final one = (await drive.getTask('t1'))!;
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'get');
      expect(call['api'], 'SYNO.SynologyDrive.Tasks');
      expect('${call['version']}', '1');
      expect(call['task_id'], 't1');
      expect(one.progress, 50, reason: '回包本身是任务对象时直接解析');

      // 万一是 `{items:[...]}` 形状（官方 TaskGetWork 用模型直映射，
      // 这条是防御性兼容）也要取到第一条，而不是解析出空任务。
      t.onCall = (params) {
        if ('${params['method']}' == 'get') {
          return {
            'items': [
              {
                'task_id': 't9',
                'status': 'finished',
                'result': {
                  'action': 'download',
                  'names': ['z.zip'],
                  'task_id': 't9',
                },
              },
            ],
          };
        }
        return {'success': true};
      };
      final wrapped = (await drive.getTask('t9'))!;
      expect(wrapped.finished, isTrue);
      expect(wrapped.title, contains('下载'));

      // 回包连任务对象都没有（`{}`）⇒ 必须回 null，而不是造一个空任务
      t.onCall = (params) => {'success': true};
      expect(await drive.getTask('nope'), isNull);
    });

    test('删除：Tasks/delete v1 + {task_id}（官方删的是 result.task_id）', () async {
      await drive.deleteTask('t2');
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'delete');
      expect(call['api'], 'SYNO.SynologyDrive.Tasks');
      expect('${call['version']}', '1');
      expect(call['task_id'], 't2');
    });

    test('commit_msg 是 map 时只取人写的文本（真机就是 map）', () {
      final dto = OfficeVersionDto.fromJson(const {
        'version': 'abc123',
        'commit_msg': {
          'device': 'desktop',
          'first_version': true,
          'listable': true,
          'text': '定稿备注',
        },
      });
      expect(dto.commitMsg, '定稿备注');
      expect(dto.firstVersion, isTrue, reason: 'first_version 挂在 map 里也要认');
      expect(dto.label, '未命名版本');
      // 只有元数据、没有文本 → 空（不要把 map 打印串显示出来）
      final meta = OfficeVersionDto.fromJson(const {
        'commit_msg': {'device': 'desktop', 'first_version': true},
      });
      expect(meta.commitMsg, isEmpty);
    });

    test('回包缺 items 不炸；progress 超范围会夹住', () {
      expect(DriveTaskDto.listFromJson(const {}), isEmpty);
      final dto = DriveTaskDto.fromJson(const {
        'task_id': 'x',
        'progress': 250,
      });
      expect(dto.progress, 100);
      expect(dto.title, '任务', reason: '没有 action/names 也给个中性标题');
      expect(dto.humanSize, '—');
    });
  });

  group('Drive 后台任务 · 页面层', () {
    testWidgets('列出 Drive 任务（类型 + 进度 + 大小），删除走 Tasks/delete', (tester) async {
      final boot = await _pump(
        tester,
        const DriveTasksPage(),
        responses: {
          'SYNO.SynologyDrive.Tasks.list': {
            'items': [
              {
                'task_id': 't1',
                'status': 'in_progress',
                'progress': 30,
                'result': {
                  'action': 'upload',
                  'names': ['a.png'],
                  'total_size': 2048,
                  'task_id': 't1',
                },
              },
              {
                'task_id': 't2',
                'status': 'finished',
                'progress': 1,
                'result': {
                  'action': 'download',
                  'names': ['z.zip'],
                  'total_size': 1048576,
                  'task_id': 't2',
                },
              },
            ],
            'total': 2,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('后台任务'), findsOneWidget);
      expect(find.text('上传 · a.png'), findsOneWidget);
      expect(find.textContaining('30%'), findsOneWidget);
      expect(find.byKey(const Key('drive-task-t1')), findsOneWidget);

      // ★ D53：删除前必须确认（官方 `Tasks/delete` 只删记录，不中止传输，
      //   所以对"进行中"的任务要把这句话摆在用户面前）。
      await tester.tap(find.byKey(const Key('drive-task-remove-t1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('drive-task-remove-dialog')), findsOneWidget);
      expect(find.textContaining('不会中止服务端正在进行的传输'), findsOneWidget);

      // 先点"取消"：绝不能发 delete
      await tester.tap(find.byKey(const Key('drive-task-remove-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        boot.t.calls.where((c) => '${c['method']}' == 'delete'),
        isEmpty,
        reason: '取消确认后不许删',
      );

      // 再来一次，这回确认
      await tester.tap(find.byKey(const Key('drive-task-remove-t1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('drive-task-remove-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final call = boot.t.calls.lastWhere(
        (c) => '${c['method']}' == 'delete',
        orElse: () => throw StateError('没有发 delete'),
      );
      expect(call['task_id'], 't1');

      // 已完成的记录：确认文案换成"移除记录、不影响文件"
      await tester.tap(find.byKey(const Key('drive-task-remove-t2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('只是把记录从任务列表里清掉'), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-task-remove-cancel')));
      await tester.pump();
    });

    testWidgets('★ D53：点一行看单条详情（Tasks/get 覆盖列表快照）', (tester) async {
      final boot = await _pump(
        tester,
        const DriveTasksPage(),
        responses: {
          'SYNO.SynologyDrive.Tasks.list': {
            'items': [
              {
                'task_id': 't1',
                'status': 'in_progress',
                'progress': 30,
                'result': {
                  'action': 'upload',
                  'names': ['a.png'],
                  'total_size': 2048,
                  'task_id': 't1',
                },
              },
            ],
            'total': 1,
          },
          // 服务端最新状态：已经跑到 87% 了（列表里还是 30%）
          'SYNO.SynologyDrive.Tasks.get': {
            'task_id': 't1',
            'status': 'in_progress',
            'progress': 0.87,
            'errors': <dynamic>[],
            'result': {
              'action': 'upload',
              'names': ['a.png', 'b.png'],
              'total_size': 4096,
              'task_id': 't1',
            },
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('drive-task-t1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(const Key('drive-task-sheet')), findsOneWidget);
      final getCall = boot.t.calls.lastWhere(
        (c) => '${c['method']}' == 'get',
        orElse: () => throw StateError('点行没有发 Tasks/get'),
      );
      expect(getCall['api'], 'SYNO.SynologyDrive.Tasks');
      expect(getCall['task_id'], 't1');
      expect(
        find.byKey(const Key('drive-task-detail-progress')),
        findsOneWidget,
      );
      // 详情里的 87% 来自 Tasks/get；列表里的 30% 只是快照
      expect(
        tester
            .widget<Text>(find.byKey(const Key('drive-task-detail-progress')))
            .data,
        '87%',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('drive-task-detail-names')))
            .data,
        contains('b.png'),
      );

      // 详情页里的"移除"同样要走确认
      await tester.tap(find.byKey(const Key('drive-task-detail-remove')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('drive-task-remove-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-task-remove-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        boot.t.calls.where((c) => '${c['method']}' == 'delete'),
        isNotEmpty,
      );
    });

    testWidgets('★ D53：详情拉不到（103）→ 仍显示快照并明说"拿不到最新状态"', (tester) async {
      await _pump(
        tester,
        const DriveTasksPage(),
        responses: {
          'SYNO.SynologyDrive.Tasks.list': {
            'items': [
              {
                'task_id': 't3',
                'status': 'in_progress',
                'progress': 30,
                'result': {'action': 'upload', 'names': ['a.png']},
              },
            ],
            'total': 1,
          },
        },
        failures: {'SYNO.SynologyDrive.Tasks.get': 103},
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('drive-task-t3')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('drive-task-sheet')), findsOneWidget);
      expect(find.textContaining('拿不到最新状态'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('drive-task-detail-progress')))
            .data,
        '30%',
        reason: '拿不到就用列表快照，别显示假进度',
      );
    });

    testWidgets('没有任务 → 说明与 NAS 侧任务的区别（不是白屏）', (tester) async {
      await _pump(
        tester,
        const DriveTasksPage(),
        responses: {
          'SYNO.SynologyDrive.Tasks.list': {'items': <dynamic>[], 'total': 0},
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('没有后台任务'), findsOneWidget);
      expect(find.textContaining('NAS 文件'), findsOneWidget);
    });

    testWidgets('读任务失败 → 报错 + 重试', (tester) async {
      await _pump(
        tester,
        const DriveTasksPage(),
        failures: {'SYNO.SynologyDrive.Tasks.list': 103},
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('读任务失败'), findsOneWidget);
    });
  });
}
