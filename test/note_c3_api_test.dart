// C3（NoteStation 补齐）API 层离线测试：**参数形态**是重点。
//
// 本批接口与 Note 写接口不同：导出/导入的参数是**普通字符串/数字**
// （服务端 `GetAndCheckString` / `GetAndCheckInt`），**不能** Gson 二次编码；
// 只有 `Note.Version` 与 Note 写接口同源（带引号的 JSON 串）。
// 一条写错的表现就是"参数无效 120"，所以离线把形态钉死。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真机 `SYNO.API.Info` 快照子集（含 C3 新增的 Export/Import 名）
const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.NoteStation.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Note.Version': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Export.Word': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Export.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Export.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Import.Enex': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Import.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Import.Evernote': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Future<({NoteStationApi notes, FakeTransport t})> _boot([
  Map<String, Map<String, dynamic>> responses = const {},
]) async {
  final t = FakeTransport({...responses}, {...FakeTransport.table, ..._table});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (notes: NoteStationApi(api), t: t);
}

Map<String, dynamic> _callOf(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

void main() {
  group('版本历史（Note.Version）', () {
    test('list：limit=100 + filter.listable=true（都是带引号的 JSON 串）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.Version.list': {
          'versions': [
            {
              'id': 'v1',
              'version': '1.1',
              'author': 'u1',
              'mtime': 1700000000000,
              'commit_msg': {'device': 'DS920+'},
              'last_version': false,
            },
          ],
          'total': 1,
        },
      });
      final rows = await b.notes.listVersions('n1');
      expect(rows, hasLength(1));
      final c = _callOf(b.t, 'SYNO.NoteStation.Note.Version', 'list');
      expect(c['version'], '2', reason: '能力表 maxVersion=2 → 取 v2');
      expect(c['object_id'], '"n1"', reason: 'Note 系参数是带引号的 JSON 串');
      expect(c['limit'], 100, reason: '官方 itemsPerPage=100');
      expect(c['filter'], '{"listable":true}', reason: '官方固定发 listable');
    });

    test('restore：参数名是 ver（不是 version）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.Version.restore': <String, dynamic>{},
      });
      await b.notes.restoreVersion('n1', '1.1');
      final c = _callOf(b.t, 'SYNO.NoteStation.Note.Version', 'restore');
      expect(c['ver'], '"1.1"', reason: '★ 官方 restoreNoteVersion 传的是 ver');
      expect(c['version'], '2', reason: 'version 只能是协议版本；要是被当成"版本号"发出去就会变');
      expect(c['object_id'], '"n1"');
    });

    test('预览走 Note/get + ver（官方 History.Preview.Window 就是这条路）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.get': {
          'object_id': 'n1',
          'title': 'T',
          'content': '<p>旧</p>',
          'ver': '1.1',
        },
      });
      final note = await b.notes.getNote('n1', ver: '1.1');
      expect(note.content, '<p>旧</p>');
      final c = _callOf(b.t, 'SYNO.NoteStation.Note', 'get');
      expect(c['ver'], '"1.1"');
      expect(c['version'], '1', reason: 'Note/get 用 ver 选版本，version 仍是协议版本');
    });

    test('复制为新笔记：copy 带 object_id/title/parent_id/ver', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.copy': {'object_id': 'new-9'},
      });
      final id = await b.notes.copyNote(
        'n1',
        parentId: 'nb1',
        title: 'T - 1.1',
        ver: '1.1',
      );
      expect(id, 'new-9');
      final c = _callOf(b.t, 'SYNO.NoteStation.Note', 'copy');
      expect(c['object_id'], '"n1"');
      expect(c['parent_id'], '"nb1"');
      expect(c['title'], '"T - 1.1"');
      expect(c['ver'], '"1.1"');
    });
  });

  group('导出（Export.*）', () {
    test('Word：start 只发 object_id(+token)，参数不加引号', () async {
      final b = await _boot({
        'SYNO.NoteStation.Export.Word.start': {'task_id': 't-1'},
      });
      final taskId = await b.notes.startWordExport('n1', token: 'tok');
      expect(taskId, 't-1');
      final c = _callOf(b.t, 'SYNO.NoteStation.Export.Word', 'start');
      expect(c['object_id'], 'n1', reason: '导出接口是普通字符串，不能带引号');
      expect(c['token'], 'tok');
      expect(
        c.containsKey('timezone_offset'),
        isFalse,
        reason: '官方 exportWord 不传 timezone_offset',
      );
    });

    test(
      'Note(.nsx)：start 带 timezone_offset（=-60*getTimezoneOffset）',
      () async {
        final b = await _boot({
          'SYNO.NoteStation.Export.Note.start': {'task_id': 't-2'},
        });
        await b.notes.startNoteExport('n1', timezoneOffset: 480);
        final c = _callOf(b.t, 'SYNO.NoteStation.Export.Note', 'start');
        expect(c['object_id'], 'n1');
        expect(c['timezone_offset'], 480);
      },
    );

    test('timezoneOffsetMinutes 与 JS 的 -60*getTimezoneOffset 同号', () {
      // UTC+8：JS getTimezoneOffset() = -480 → -60*1*-8 = 480
      final at = DateTime.utc(2024, 1, 1).toLocal();
      final expectMinutes = -at.timeZoneOffset.inMinutes;
      expect(NoteStationApi.timezoneOffsetMinutes(at), expectMinutes);
    });

    test('status：只发 task_id；回包 filename/finish 解析', () async {
      final b = await _boot({
        'SYNO.NoteStation.Export.Word.status': {
          'finish': true,
          'filename': '周会.docx',
        },
      });
      final st = await b.notes.wordExportStatus('t-1');
      expect(st.finish, isTrue);
      expect(st.filename, '周会.docx');
      final c = _callOf(b.t, 'SYNO.NoteStation.Export.Word', 'status');
      expect(c['task_id'], 't-1');
      expect(c.keys.where((k) => k.startsWith('object_id')), isEmpty);
    });

    test('download 直链：带 _sid / task_id / remove=true / version=1', () async {
      final b = await _boot();
      final url = b.notes.wordExportUrl('t-1');
      expect(url, contains('api=SYNO.NoteStation.Export.Word'));
      expect(url, contains('method=download'));
      expect(url, contains('task_id=t-1'));
      expect(url, contains('remove=true'));
      expect(url, contains('version=1'));
    });

    test('Notebook：start 发 object_id/dest/save_config/export_todo', () async {
      final b = await _boot({
        'SYNO.NoteStation.Export.Notebook.start': {'task_id': 't-3'},
      });
      await b.notes.startNotebookExport(
        notebookId: 'nb1',
        dest: '/share/notes',
        saveConfig: true,
        exportTodo: true,
      );
      final c = _callOf(b.t, 'SYNO.NoteStation.Export.Notebook', 'start');
      expect(c['object_id'], 'nb1');
      expect(c['dest'], '/share/notes');
      expect(c['save_config'], true);
      expect(c['export_todo'], true);
    });

    test('Notebook：status 不带任何参数', () async {
      final b = await _boot({
        'SYNO.NoteStation.Export.Notebook.status': {'finish': false},
      });
      await b.notes.notebookExportStatus();
      final c = _callOf(b.t, 'SYNO.NoteStation.Export.Notebook', 'status');
      expect(
        c.keys.toSet().difference({
          'api',
          'method',
          'version',
          '_sid',
          'path',
        }).toSet(),
        isEmpty,
        reason: '官方 compound 轮询里 Notebook.status 就是空参数',
      );
    });
  });

  group('导入（Import.*）', () {
    test('Enex：multipart 的 file 元数据 + 以文件名为字段名', () async {
      final dir = Directory.systemTemp.createTempSync('note-c3-api');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/ever.enex')
        ..writeAsStringSync('<en-export/>');

      final b = await _boot({
        'SYNO.NoteStation.Import.Enex.start': {'task_id': 'imp-1'},
      });
      final taskId = await b.notes.startEnexImport(
        path: file.path,
        fileName: 'ever.enex',
      );
      expect(taskId, 'imp-1');
      final c = _lastMultipart(b.t);
      expect(c['api'], 'SYNO.NoteStation.Import.Enex');
      expect(c['method'], 'start');
      expect(c['version'], '1');
      expect(jsonDecode(c['file'] as String), [
        {'format': 'raw', 'name': 'ever.enex'},
      ], reason: '官方 e.append("file", Ext.encode(o))，o=[{format:raw,name}]');
      expect(c['files'], ['ever.enex:ever.enex'], reason: '字段名就是文件名');
      expect(c['file_name'], 'ever.enex');
      expect(
        c.containsKey('html5upload'),
        isFalse,
        reason: 'html5upload 是客户端标志，不作为 API 参数',
      );
    });

    test('Enex：status/stop 都不带参数；进度字段解析', () async {
      final b = await _boot({
        'SYNO.NoteStation.Import.Enex.status': {
          'finish': false,
          'data': {'current': 3, 'total': 10, 'finish_time': 0},
        },
      });
      final st = await b.notes.enexImportStatus();
      expect(st.current, 3);
      expect(st.total, 10);
      expect(st.percent, 30);
      expect(st.finish, isFalse);
      final c = _callOf(b.t, 'SYNO.NoteStation.Import.Enex', 'status');
      expect(
        c.keys.toSet().difference({'api', 'method', 'version', '_sid', 'path'}),
        isEmpty,
      );
    });

    test('Notebook(.nsx)：走同一个 multipart 形态', () async {
      final dir = Directory.systemTemp.createTempSync('note-c3-api2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/a.nsx')..writeAsStringSync('x');
      final b = await _boot({
        'SYNO.NoteStation.Import.Notebook.start': {'task_id': 'imp-2'},
      });
      await b.notes.startNotebookImport(path: file.path, fileName: 'a.nsx');
      final c = _lastMultipart(b.t);
      expect(c['api'], 'SYNO.NoteStation.Import.Notebook');
      expect(c['files'], ['a.nsx:a.nsx']);
    });
  });

  group('Evernote 云导入（Import.Evernote）', () {
    test('get_oauth_url 是带 server 的授权直链', () async {
      final b = await _boot();
      final url = b.notes.evernoteOAuthUrl('MyNAS');
      expect(url, contains('api=SYNO.NoteStation.Import.Evernote'));
      expect(url, contains('method=get_oauth_url'));
      expect(url, contains('server=MyNAS'));
    });

    test('list_notebooks：limit=50，root=notebooks', () async {
      final b = await _boot({
        'SYNO.NoteStation.Import.Evernote.list_notebooks': {
          'notebooks': [
            {
              'guid': 'g1',
              'name': '收件箱',
              'checked': true,
              'ctime': 1,
              'mtime': 2,
              'stack': 'S',
            },
          ],
        },
      });
      final list = await b.notes.evernoteListNotebooks();
      expect(list, hasLength(1));
      expect(list.first.guid, 'g1');
      expect(list.first.displayName, '收件箱');
      expect(list.first.stack, 'S');
      final c = _callOf(
        b.t,
        'SYNO.NoteStation.Import.Evernote',
        'list_notebooks',
      );
      expect(c['limit'], 50);
    });

    test('add_import_task：notebook_guid + merge_notebook', () async {
      final b = await _boot({
        'SYNO.NoteStation.Import.Evernote.add_import_task': <String, dynamic>{},
      });
      await b.notes.evernoteAddImportTask(notebookGuid: 'g1');
      final c = _callOf(
        b.t,
        'SYNO.NoteStation.Import.Evernote',
        'add_import_task',
      );
      expect(
        c['notebook_guid'],
        '"g1"',
        reason: 'Gson 二次编码（官方 Java 端 gson.toJson）',
      );
      expect(c['merge_notebook'], 'false');
    });

    test('get_status 字段：token/notebook_left/note_left/importing', () async {
      final b = await _boot({
        'SYNO.NoteStation.Import.Evernote.get_status': {
          'token': 7,
          'last_error': 19,
          'notebook_left': 2,
          'notebook_count': 5,
          'note_left': 10,
          'note_count': 100,
          'importing': false,
        },
      });
      final st = await b.notes.evernoteStatus();
      expect(st.token, 7, reason: '官方 JS 比较是 token<1 → 数字');
      expect(st.notebookLeft, 2);
      expect(st.notebookCount, 5);
      expect(st.waiting, isTrue, reason: '官方 19 = 等待授权');
      expect(st.active, isTrue);
    });

    test('import_lock → {lock}；prepare_notebooks → {task_id}', () async {
      final b = await _boot({
        'SYNO.NoteStation.Import.Evernote.import_lock': {'lock': 'L'},
        'SYNO.NoteStation.Import.Evernote.prepare_notebooks': {'task_id': 'p1'},
        'SYNO.NoteStation.Import.Evernote.prepare_notebooks_status': {
          'finish': true,
        },
      });
      expect(await b.notes.evernoteImportLock(), 'L');
      expect(await b.notes.evernotePrepareNotebooks(), 'p1');
      expect(await b.notes.evernotePrepareNotebooksStatus(), isTrue);
    });
  });

  group('停止 / 收尾方法（都只发协议参数）', () {
    const noArg = {'api', 'method', 'version', '_sid', 'path'};

    test('Export.Word/Note.stop 只带 task_id', () async {
      final b = await _boot({
        'SYNO.NoteStation.Export.Word.stop': <String, dynamic>{},
        'SYNO.NoteStation.Export.Note.stop': <String, dynamic>{},
      });
      await b.notes.stopWordExport('t-1');
      await b.notes.stopNoteExport('t-2');
      expect(
        _callOf(b.t, 'SYNO.NoteStation.Export.Word', 'stop')['task_id'],
        't-1',
      );
      expect(
        _callOf(b.t, 'SYNO.NoteStation.Export.Note', 'stop')['task_id'],
        't-2',
      );
    });

    test(
      'Export.Notebook.stop / Import.Enex.stop / Import.Notebook.stop 无参数',
      () async {
        final b = await _boot();
        await b.notes.stopNotebookExport();
        await b.notes.stopEnexImport();
        await b.notes.stopNotebookImport();
        for (final api in [
          'SYNO.NoteStation.Export.Notebook',
          'SYNO.NoteStation.Import.Enex',
          'SYNO.NoteStation.Import.Notebook',
        ]) {
          final c = _callOf(b.t, api, 'stop');
          expect(
            c.keys.toSet().difference(noArg),
            isEmpty,
            reason: '$api stop 官方就是空参数',
          );
        }
      },
    );

    test('Evernote check_oauth_token / import / import_stop 无参数', () async {
      final b = await _boot();
      await b.notes.checkEvernoteOAuthToken();
      await b.notes.startEvernoteImport();
      await b.notes.stopEvernoteImport();
      for (final m in ['check_oauth_token', 'import', 'import_stop']) {
        final c = _callOf(b.t, 'SYNO.NoteStation.Import.Evernote', m);
        expect(c.keys.toSet().difference(noArg), isEmpty, reason: '$m 无参数');
      }
    });
  });

  group('网页剪藏（借 Note/create 的顶层字段）', () {
    test(
      'clipperParams 发顶层 source_url/clipper_url/clipper_mode/user_agent',
      () {
        final p = NoteStationApi.clipperParams(
          sourceUrl: 'https://a/b',
          clipperUrl: 'https://a/b',
          clipperMode: 'article',
          clipperUserAgent: 'UA',
        );
        expect(p['source_url'], '"https://a/b"');
        expect(p['clipper_url'], '"https://a/b"');
        expect(p['clipper_mode'], '"article"');
        expect(p['clipper_user_agent'], '"UA"');
        expect(
          p.containsKey('clipper'),
          isFalse,
          reason: 'clipper 字段类型/语义无原文 → 不透传（待取证）',
        );
      },
    );

    test('createNote 把剪藏字段带进 create 请求', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.create': {'object_id': 'clip-1', 'ver': '1.0'},
      });
      final created = await b.notes.createNote(
        title: '网页',
        parentId: 'nb1',
        sourceUrl: 'https://a/b',
        clipperUrl: 'https://a/b',
        clipperMode: 'article',
      );
      expect(created.objectId, 'clip-1');
      final c = _callOf(b.t, 'SYNO.NoteStation.Note', 'create');
      expect(c['source_url'], '"https://a/b"');
      expect(c['clipper_url'], '"https://a/b"');
      expect(c['clipper_mode'], '"article"');
      // 剪藏字段与 create 的必需外壳共存（真机 §5.4 的 create 参数全集）
      expect(c['parent_id'], '"nb1"');
      expect(c['commit_msg'], '{"device":"Flutter","listable":false}');
    });
  });
}

/// 最后一次 multipart 上传记录（含 `files`/`file_name` 键）
Map<String, dynamic> _lastMultipart(FakeTransport t) => t.calls.lastWhere(
  (c) => c.containsKey('files') || c.containsKey('file_name'),
);
