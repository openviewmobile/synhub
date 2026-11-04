// §11 第 ⑧ 项（Office L2）：**导出**（`Office.Export/download`，含"下载为 PDF"）
// 与**转换**（`Office.Import/check` → `Office.Import/convert`）。
//
// 接口形态全部有官方出处（NAS 上实际装的 Office 3.8.0-22711）：
//   * `ui/dist/ui.doc.js` 的 `SYNO.SDS.Office.Action.superclass.exportNode`
//     → 白名单逐字 `path,object_id,password,format,ver`；
//     **写入批次真机（docs/live-write-verification.md §3）只验过
//     `{path:"id:<file_id>", format:"xlsx"}`** → `200` + OOXML(ZIP)，且
//     `link_id`→`57350`、`object_id`→`57351`、`Excel.save`→`57383`
//     ⇒ 我们**只发 `path`**，`format` 发**目标扩展名**（officeExportServerFormat）；
//   * 同文件的 `checkImportOffice` → `{files:[{path}]}`（带口令时 `{path,password}`）
//     与 `convertOffice` → 白名单逐字 `files,conflict_action,to_parent_folder`，
//     调用方固定 `conflict_action:'autorename'`；
//   * `webapi/SYNO.Office.lib`：`Import` v1 = `check convert info start status stop`。
//
// 这里钉的是"参数/版本/文件名发对了、回包解析对了、动作接对了"。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/office_export.dart';
import 'package:synhub/src/features/files/office_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.Import': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.Export': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
};

/// 一个最小页面：一个按钮，按下去调 [onTap]（拿得到真正的 `WidgetRef`）
class _Harness extends ConsumerWidget {
  const _Harness({required this.onTap});

  final Future<String> Function(WidgetRef ref) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(theme: AppTheme.dark(), 
    home: Scaffold(
      body: Center(
        child: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              try {
                final r = await onTap(ref);
                if (ctx.mounted) {
                  ScaffoldMessenger.of(
                    ctx,
                  ).showSnackBar(SnackBar(content: Text('ok:$r')));
                }
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(
                    ctx,
                  ).showSnackBar(SnackBar(content: Text('err:$e')));
                }
              }
            },
            child: const Text('run'),
          ),
        ),
      ),
    ),
  );
}

/// 交替 flush microtask（`pump`）与给真实 I/O 时间（`runAsync`），直到 [done]。
///
/// `flutter_test` 的假时钟不推进真实文件 I/O；真实 I/O 只能在 `runAsync`
/// 窗口里前进，而 await 之后的续体要在假时钟 zone 里由 `pump` flush。条件
/// 达成即返回（不改判定，不是"睡固定时长再看"），上限只在用例本应失败时兜底。
Future<void> _settle(
  WidgetTester tester,
  bool Function() done, {
  int maxRounds = 300,
  Duration realStep = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < maxRounds && !done(); i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(realStep));
  }
  await tester.pump();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Office 导出 · 文件名与格式表', () {
    test('微软格式按官方 EXPORT_EXTENSION 换后缀', () {
      expect(officeExportFileName('报告.odoc', 'ms'), '报告.docx');
      expect(officeExportFileName('预算.osheet', 'ms'), '预算.xlsx');
      expect(officeExportFileName('演示.oslides', 'ms'), '演示.pptx');
    });

    test('pdf / odf / csv 的后缀', () {
      expect(officeExportFileName('报告.odoc', 'pdf'), '报告.pdf');
      expect(officeExportFileName('报告.odoc', 'odf'), '报告.odt');
      expect(officeExportFileName('预算.osheet', 'odf'), '预算.ods');
      expect(officeExportFileName('演示.oslides', 'odf'), '演示.odp');
      expect(officeExportFileName('预算.osheet', 'csv'), '预算.csv');
    });

    test('格式表：只列服务端真能产出的 ms/odf（pdf/csv 是官方前端行为）', () {
      // 真机实测：pdf 会被服务端回落成 ODF、csv 是官方前端自己拼的 →
      // 菜单里不给这两项（发了只会拿到"名字叫 .pdf 其实是 odt"的文件）
      expect(officeExportFormatsFor('预算.osheet'), [
        OfficeExportFormat.ms,
        OfficeExportFormat.odf,
      ]);
      expect(officeExportFormatsFor('报告.odoc'), [
        OfficeExportFormat.ms,
        OfficeExportFormat.odf,
      ]);
      expect(officeExportFormatsFor('报告.docx'), isEmpty);
      expect(officeExportFormatsFor('照片.jpg'), isEmpty);
    });

    test('可转换扩展名与转换后的原生格式', () {
      expect(isOfficeConvertibleName('报告.docx'), isTrue);
      expect(isOfficeConvertibleName('预算.xlsx'), isTrue);
      expect(isOfficeConvertibleName('预算.csv'), isTrue);
      expect(isOfficeConvertibleName('演示.ppt'), isTrue);
      expect(isOfficeConvertibleName('说明.rtf'), isTrue);
      // 已经是原生格式 / 根本不是文档 → 不显示"转换"
      expect(isOfficeConvertibleName('报告.odoc'), isFalse);
      expect(isOfficeConvertibleName('照片.jpg'), isFalse);
      expect(isOfficeConvertibleName('压缩包.zip'), isFalse);
      expect(officeConvertedFileName('报告.docx'), '报告.odoc');
      expect(officeConvertedFileName('预算.xlsx'), '预算.osheet');
      expect(officeConvertedFileName('数据.csv'), '数据.osheet');
      expect(officeConvertedFileName('演示.pptx'), '演示.oslides');
    });
  });

  group('Office 导出 · 接口层', () {
    late FakeTransport t;
    late OfficeApi office;

    setUp(() async {
      t = FakeTransport({}, {...FakeTransport.table, ..._table});
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      office = OfficeApi(api);
    });

    test('Export/download：走 POST 表单（format 放查询串服务端不认）', () async {
      await office.exportBytes(fileId: '9', format: 'pdf', fileName: '报告.odoc');
      // 关键：**POST 表单**（查询串上的 format 服务端不认，真机实测 2026-09-20）
      expect(t.downloads, isEmpty);
      final post = t.postDownloads.single;
      expect(post, startsWith('entry.cgi?'));
      expect(post, contains('api=SYNO.Office.Export'));
      expect(post, contains('method=download'));
      expect(post, contains('version=1'));
      expect(post, contains('path=id:9'));
      expect(post, contains('format=pdf'));
      // 官方总会带 password（没有口令时是空串）
      expect(post, contains('password=&'));
      expect(post, isNot(contains('ver=')));
      // 导出文件名按格式换成 .pdf（服务端据此定 Content-Disposition）
      expect(post, contains('filename=报告.pdf'));
      // 会话 id 也在表单体里
      expect(post, contains('_sid=FAKE-SID'));
    });

    test('Export/download：指定版本带 ver，文件名按 ms 映射成 .docx', () async {
      final url = office.exportDownloadUrl(
        fileId: '9',
        // 服务端认的是**目标扩展名**（真机唯一验过 `format:"xlsx"`），
        // `ms` 只是官方前端档位名 → 先经 officeExportServerFormat 映射
        format: officeExportServerFormat('报告.odoc', 'ms'),
        version: 'probe-version',
        fileName: '报告.odoc',
      );
      expect(url, contains('ver=probe-version'));
      expect(url, contains('format=docx'));
      expect(url, contains('filename=${Uri.encodeQueryComponent('报告.docx')}'));
    });

    test('Export/download 的 format：真机唯一验过的形状是目标扩展名 xlsx', () async {
      // 真机（docs/live-write-verification.md §3）：唯一可用 =
      // {path:"id:<file_id>", format:"xlsx"} → 200 + OOXML(ZIP)。
      // 所以 .osheet 这一档发出去的就是 `xlsx`（不是官方前端的档位名 `ms`）。
      await office.exportBytes(
        fileId: '9',
        format: officeExportServerFormat(
          '预算.osheet',
          OfficeExportFormat.ms.code,
        ),
        fileName: '预算.osheet',
      );
      final post = t.postDownloads.single;
      expect(post, contains('path=id:9'));
      expect(post, contains('format=xlsx'));
      expect(post, isNot(contains('format=ms')));
      // 服务端的 Content-Disposition basename **不带扩展名**，落盘名由客户端补
      // → exportBytes 带出去的 filename 仍是带扩展名的 .xlsx（官方 exportNode 白名单）
      expect(post, contains('filename=预算.xlsx'));
      expect(
        officeExportFileName('预算.osheet', OfficeExportFormat.ms.code),
        '预算.xlsx',
      );
    });

    test('Export/download **只发 path**：不再有 object_id 形态（真机 57351）', () async {
      await office.exportBytes(
        fileId: '9',
        format: officeExportServerFormat('报告.odoc', 'ms'),
        fileName: '报告.odoc',
      );
      final post = t.postDownloads.single;
      expect(post, contains('path=id:9'));
      expect(post, isNot(contains('object_id')));
      expect(post, isNot(contains('link_id')));
    });

    test('officeExportServerFormat：ms 按源扩展名换目标扩展名，odf 原样透传', () {
      expect(officeExportServerFormat('预算.osheet', 'ms'), 'xlsx');
      expect(officeExportServerFormat('报告.odoc', 'ms'), 'docx');
      expect(officeExportServerFormat('演示.oslides', 'ms'), 'pptx');
      expect(officeExportServerFormat('预算.osheet', 'odf'), 'odf');
      expect(officeExportServerFormat('报告.odoc', 'pdf'), 'pdf');
    });

    test('Import/check：files 是 Gson 数组串，57373 解析成"要口令"', () async {
      t.responses['SYNO.Office.Import.check'] = {
        'errors': [
          {'code': 57373, 'path': 'id:9', 'file_id': 9, 'name': '报告.docx'},
        ],
      };
      final issues = await office.importCheck(fileId: '9');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.Office.Import');
      expect(call['method'], 'check');
      expect(call['version'], '1');
      expect(call['files'], '[{"path":"id:9"}]');
      expect(issues.single.code, 57373);
      expect(issues.single.needsPassword, isTrue);
      expect(issues.single.fileId, '9');
      expect(issues.single.name, '报告.docx');
    });

    test('Import/check：带口令走 path+password（官方 GenPasswordWindow 分支）', () async {
      t.responses['SYNO.Office.Import.check'] = {'errors': <dynamic>[]};
      final issues = await office.importCheck(fileId: '9', password: 's3cret');
      final call = t.calls.last;
      expect(call['path'], 'id:9');
      expect(call['password'], 's3cret');
      expect(call.containsKey('files'), isFalse);
      expect(issues, isEmpty);
    });

    test(
      'Import/convert：files + conflict_action=autorename + to_parent_folder',
      () async {
        await office.importConvert(fileId: '9', toParentFolderId: '5');
        final call = t.calls.last;
        expect(call['api'], 'SYNO.Office.Import');
        expect(call['method'], 'convert');
        expect(call['version'], '1');
        expect(call['files'], '[{"path":"id:9"}]');
        expect(call['conflict_action'], 'autorename');
        expect(call['to_parent_folder'], 'id:5');
        expect(call.containsKey('additional_passwords'), isFalse);
      },
    );

    test(
      'Import/convert：带口令时 additional_passwords 是 [{path,password}]',
      () async {
        await office.importConvert(fileId: '9', password: 's3cret');
        final call = t.calls.last;
        expect(
          call['additional_passwords'],
          '[{"path":"id:9","password":"s3cret"}]',
        );
        expect(call.containsKey('to_parent_folder'), isFalse);
      },
    );
  });

  group('Office 导出 · 服务层', () {
    late FakeTransport t;
    late ProviderContainer c;
    late Directory dir;

    Future<void> boot(WidgetTester tester, Widget page) async {
      t = FakeTransport({}, {...FakeTransport.table, ..._table});
      // 真字节：导出"PDF"的第一段就该是 %PDF（这里只在测试里断言落盘内容）
      // 真字节只是为了断言"原样落盘"；真机上的 magic 头另有探针（见 docs）
      t.bytesByUrl['SYNO.Office.Export'] = utf8.encode('%PDF-1.7 fake\n');
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      dir = Directory.systemTemp.createTempSync('office_export_test');
      c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(
            ChatDatabase(NativeDatabase.memory()),
          ),
          officeApiProvider.overrideWithValue(OfficeApi(api)),
          officeDownloadDirProvider.overrideWithValue(() async => dir),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: page),
      );
      await tester.pump();
    }

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    testWidgets('下载为 OpenDocument：取字节 → 落盘成 .odt', (tester) async {
      // 完成信号 = **产品 Future 真正返回**，而不是"文件出现在磁盘上"。
      // 实测（本机）：`File.writeAsBytes` 会**先创建文件**，`existsSync()` 在
      // 写入真正完成之前就为 true —— 之前以它作终止条件会在 tap 后第一次检查
      // 就退出循环，此时 `downloadOfficeAs` 仍停在 `await writeAsBytes`，于是
      // `ok:` snackbar 永远没机会出现（不是延时不够，是信号选错了）。
      final done = Completer<void>();
      await boot(
        tester,
        _Harness(
          onTap: (ref) async {
            try {
              return await downloadOfficeAs(
                ref,
                fileId: '9',
                name: '报告.odoc',
                format: OfficeExportFormat.odf,
              );
            } finally {
              if (!done.isCompleted) done.complete();
            }
          },
        ),
      );
      await tester.tap(find.text('run'));
      await tester.pump();
      // 交替推进两种时钟，直到产品 Future 返回；上限只防死等，不参与判定。
      await _settle(tester, () => done.isCompleted);
      await tester.pumpAndSettle();
      expect(find.text('ok:报告.odt'), findsOneWidget);
      final file = File('${dir.path}/报告.odt');
      expect(file.existsSync(), isTrue);
      expect(utf8.decode(file.readAsBytesSync()), startsWith('%PDF-1.7'));
      expect(t.postDownloads.single, contains('format=odf'));
    });

    testWidgets('转换成功后返回预期的新文件名，参数带 autorename', (tester) async {
      await boot(
        tester,
        _Harness(
          onTap: (ref) => convertToOfficeDocument(
            ref,
            fileId: '9',
            name: '报告.docx',
            parentId: '5',
          ),
        ),
      );
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();
      expect(find.text('ok:报告.odoc'), findsOneWidget);
      final check = t.calls.firstWhere((e) => e['method'] == 'check');
      expect(check['files'], '[{"path":"id:9"}]');
      final convert = t.calls.firstWhere((e) => e['method'] == 'convert');
      expect(convert['conflict_action'], 'autorename');
      expect(convert['to_parent_folder'], 'id:5');
    });

    testWidgets('check 回 57373 → 抛"要口令"（页面据此弹口令框）', (tester) async {
      await boot(
        tester,
        _Harness(
          onTap: (ref) =>
              convertToOfficeDocument(ref, fileId: '9', name: '报告.docx'),
        ),
      );
      t.responses['SYNO.Office.Import.check'] = {
        'errors': [
          {'code': 57373},
        ],
      };
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();
      expect(find.textContaining('err:这份文档有口令'), findsOneWidget);
      // 没到 convert 那一步
      expect(t.calls.any((e) => e['method'] == 'convert'), isFalse);
    });

    testWidgets('check 回其它错误码 → 抛"转不了"（不弹口令框）', (tester) async {
      await boot(
        tester,
        _Harness(
          onTap: (ref) =>
              convertToOfficeDocument(ref, fileId: '9', name: '压缩包.zip'),
        ),
      );
      t.responses['SYNO.Office.Import.check'] = {
        'errors': [
          {'code': 1234},
        ],
      };
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();
      expect(find.textContaining('err:这个文件转不了（服务端错误码 1234）'), findsOneWidget);
      expect(t.calls.any((e) => e['method'] == 'convert'), isFalse);
    });

    testWidgets('带上口令：check 走 path+password，convert 带 additional_passwords', (
      tester,
    ) async {
      await boot(
        tester,
        _Harness(
          onTap: (ref) => convertToOfficeDocument(
            ref,
            fileId: '9',
            name: '报告.docx',
            password: 's3cret',
          ),
        ),
      );
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();
      final check = t.calls.firstWhere((e) => e['method'] == 'check');
      expect(check['password'], 's3cret');
      final convert = t.calls.firstWhere((e) => e['method'] == 'convert');
      expect(
        convert['additional_passwords'],
        '[{"path":"id:9","password":"s3cret"}]',
      );
    });

    testWidgets('套件缺失（officeApiProvider=null）→ 明确报错，不发请求', (tester) async {
      await boot(
        tester,
        _Harness(
          onTap: (ref) =>
              convertToOfficeDocument(ref, fileId: '9', name: '报告.docx'),
        ),
      );
      c = ProviderContainer(
        overrides: [officeApiProvider.overrideWithValue(null)],
      );
      // 重新挂一遍，用 null 的 Office
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: _Harness(
            onTap: (ref) =>
                convertToOfficeDocument(ref, fileId: '9', name: '报告.docx'),
          ),
        ),
      );
      await tester.pump();
      final before = t.calls.length;
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('err:这台 NAS 上没有 Synology Office'),
        findsOneWidget,
      );
      expect(t.calls.length, before);
    });
  });
}
