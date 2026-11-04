// NoteStation API 层的离线测试：**参数编码**是重点。
//
// 这些接口的参数是 Gson 二次编码（字符串带引号、对象整体当 JSON 串），
// 写错的表现是"参数无效 120"——离线把形态钉死，真机只剩权限问题。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// NoteStation 能力表（真机 `SYNO.API.Info` 的快照子集）
const _noteTable = {
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
  'SYNO.NoteStation.Tag': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Todo': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  // 智能 / 条件笔记本（批次 B）：官方 APK `ApiNSSmart.VERSION = 1`
  'SYNO.NoteStation.Smart': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.NoteStation.Setting': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Note.Version': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 官方剪藏优先的 Ghost v2 能力位（默认**不在**表里 → 走回退分支）
const _ghostTable = {
  'SYNO.NoteStation.Note.Ghost': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
};

Future<({NoteStationApi notes, FakeTransport t})> _boot([
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  Map<String, Map<String, dynamic>> extraTable = const {},
]) async {
  final t = FakeTransport(
    {for (final e in responses.entries) e.key: e.value},
    {...FakeTransport.table, ..._noteTable, ...extraTable},
  );
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (notes: NoteStationApi(api), t: t);
}

Map<String, dynamic> _callOf(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

void main() {
  group('参数编码（Gson 二次编码）', () {
    test('get：object_id 带引号，field 是 JSON 串', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.get': {
          'object_id': 'abc',
          'title': 'T',
          'content': '<p>hi</p>',
          'ver': '1.0',
        },
      });
      final note = await b.notes.getNote('abc');
      expect(note.title, 'T');
      expect(note.content, '<p>hi</p>');
      final params = _callOf(b.t, 'SYNO.NoteStation.Note', 'get');
      expect(params['object_id'], '"abc"', reason: '必须是带引号的 JSON 串');
      expect(params['field'], '{"individual_shared":true}');
    });

    test('list：field 三个开关 + 排序参数', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.list': {'notes': [], 'total': 0},
      });
      await b.notes.listNotes(offset: 20, limit: 50);
      final c = _callOf(b.t, 'SYNO.NoteStation.Note', 'list');
      expect(c['version'], '4', reason: '服务器最大 v4 就取 v4');
      final params = c;
      expect(
        params['field'],
        '{"old_parent_id":true,"individual_joined":true,"individual_shared":true}',
      );
      expect(params['offset'], 20);
      expect(params['limit'], 50);
      expect(params['sort_by'], 'mtime');
      expect(params['sort_direction'], 'desc');
    });

    test(
      'create：title/parent_id/ctime + 必需外壳 commit_msg(listable:false)',
      () async {
        final b = await _boot({
          'SYNO.NoteStation.Note.create': {'object_id': 'new-1'},
        });
        final created = await b.notes.createNote(
          title: '标题',
          parentId: 'nb1',
          html: '<p>x</p>',
          ctime: 1700000000000,
        );
        expect(created.objectId, 'new-1');
        final params = _callOf(b.t, 'SYNO.NoteStation.Note', 'create');
        expect(params['title'], '"标题"');
        // 真机（docs/live-write-verification.md §5.4）：**是 `parent_id`，不是
        // `notebook_id`**（后者回 114）
        expect(params['parent_id'], '"nb1"');
        expect(params.containsKey('notebook_id'), isFalse);
        // ★ 第 316 轮更正：原来这里断言的是 **13 位毫秒** `1700000000000`
        // —— 那条断言把缺陷钉成了"期望"。NoteStation 全字段是 **epoch 秒**
        // （服务端按 32 位整型存，毫秒会被截断 ⇒ 真机新建笔记显示 1985-04-10）。
        expect(params['ctime'], '1700000000');
        expect(params['content'], '"<p>x</p>"');
        // 必需外壳：`commit_msg{device, listable:false}`（真机 create 的参数全集）
        expect(params['commit_msg'], '{"device":"Flutter","listable":false}');
        // 真机参数全集里 encrypt 是常发字段（官方 JS 每次都发）
        expect(params['encrypt'], 'false');
      },
    );

    test('set：ver 必须回传（乐观锁）；只带要改的字段', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.set': {'object_id': 'abc', 'ver': '2.0'},
      });
      await b.notes.setNote(
        objectId: 'abc',
        ver: '1.0',
        title: '新标题',
        html: '<p>n</p>',
      );
      final params = _callOf(b.t, 'SYNO.NoteStation.Note', 'set');
      expect(params['object_id'], '"abc"');
      expect(params['ver'], '"1.0"');
      expect(params['title'], '"新标题"');
      expect(params.containsKey('tag'), isFalse, reason: '没传的字段不该发');
      expect(params.containsKey('latitude'), isFalse);
    });

    test('delete：recycle 是布尔', () async {
      final b = await _boot({'SYNO.NoteStation.Note.delete': const {}});
      await b.notes.deleteNote('abc');
      final params = _callOf(b.t, 'SYNO.NoteStation.Note', 'delete');
      expect(params['object_id'], '"abc"');
      expect(params['recycle'], 'true');
    });

    test('Notebook/list：v2 带 filter，v1 不带', () async {
      final b = await _boot({
        'SYNO.NoteStation.Notebook.list': {'notebooks': [], 'total': 0},
      });
      await b.notes.listNotebooks();
      final c = _callOf(b.t, 'SYNO.NoteStation.Notebook', 'list');
      expect(c['version'], '2');
      expect(c['filter'], '{"archive":false}');
    });

    test('Todo/list：不传 done 就不带 filter', () async {
      final b = await _boot({
        'SYNO.NoteStation.Todo.list': {'todos': []},
      });
      await b.notes.listTodos();
      expect(
        _callOf(b.t, 'SYNO.NoteStation.Todo', 'list').containsKey('filter'),
        isFalse,
      );
      await b.notes.listTodos(done: false);
      expect(
        _callOf(b.t, 'SYNO.NoteStation.Todo', 'list')['filter'],
        '{"done":false}',
      );
    });
  });

  group('响应解析（字段缺省要容错）', () {
    test('笔记本：老字段 old_parent_id / owner 字符串都认', () async {
      final b = await _boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {
              'object_id': 'nb1',
              'title': '工作',
              'old_parent_id': 'root',
              'mtime': 1700000000000,
              'ver': '3.0',
              'owner': {'username': 'demo'},
            },
            {'object_id': 'nb2'},
          ],
          'total': 2,
        },
      });
      final list = await b.notes.listNotebooks();
      expect(list, hasLength(2));
      expect(list[0].title, '工作');
      expect(list[0].parentId, 'root');
      expect(list[0].ownerName, 'demo');
      expect(list[1].title, '', reason: '缺字段不抛');
    });

    test('笔记：标签数组 / 加密 / 经纬度 / 无标题', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.list': {
          'notes': [
            {
              'object_id': 'n1',
              'title': '',
              'parent_id': 'nb1',
              'tag': ['a', 'b'],
              'encrypt': true,
              'latitude': 31.2,
              'longitude': 121.5,
              'mtime': 1700000001000,
            },
          ],
          'total': 1,
        },
      });
      final r = await b.notes.listNotes();
      final note = r.notes.single;
      expect(note.displayTitle, '无标题笔记');
      expect(note.tags, ['a', 'b']);
      expect(note.encrypt, isTrue);
      expect(note.latitude, closeTo(31.2, 0.001));
      expect(note.hasContent, isFalse, reason: '列表接口没给正文');
      expect(r.total, 1);
    });

    test('版本历史：字段缺失也不炸', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.Version.list': {
          'versions': [
            {'version': '1.0', 'mtime': 1700000000000, 'author': 'demo'},
            <String, dynamic>{},
          ],
        },
      });
      final rows = await b.notes.listVersions('n1');
      expect(rows, hasLength(2));
      expect(rows.first['version'], '1.0');
    });

    test('Info：版本对象与权限位', () async {
      final b = await _boot({
        'SYNO.NoteStation.Info.get': {
          'username': 'demo_user',
          'uid': 1028,
          'is_admin': false,
          'hash': 'h',
          'allow_share': false,
          'version': {'major': '2', 'minor': '6', 'build': '10'},
        },
      });
      final info = await b.notes.info();
      expect(info!.username, 'demo_user');
      expect(info.version, '2.6.10');
      expect(info.allowShare, isFalse);
    });

    test('Tag/Todo 解析', () async {
      // `items` 的**真机形态**是"用了这个标签的笔记 id 数组"，不是数字
      // （以前这里按数字钉的 fixture，正好掩盖了"标签页永远是 0 条笔记"的 bug）
      final b = await _boot({
        'SYNO.NoteStation.Tag.list': {
          'tags': [
            {
              'tag_id': 't1',
              'title': '重要',
              'items': ['1028_R9e9u0SSQfyWJYplAK9h5'],
            },
            // 老/自建接口直接给数字时也要能用
            {'tag_id': 't2', 'title': '归档', 'items': 3},
            {'tag_id': 't3', 'title': '空标签'},
          ],
        },
        'SYNO.NoteStation.Todo.list': {
          'todos': [
            {'object_id': 'td1', 'title': '买牛奶', 'done': false, 'star': true},
          ],
        },
      });
      final tags = await b.notes.listTags();
      expect(tags.map((t) => t.title), ['重要', '归档', '空标签']);
      expect(tags[0].count, 1, reason: '数组长度就是笔记数');
      expect(tags[0].itemIds, ['1028_R9e9u0SSQfyWJYplAK9h5']);
      expect(tags[1].count, 3, reason: '数字形态兜底');
      expect(tags[2].count, 0, reason: '没有 items 字段 → 0');
      final todo = (await b.notes.listTodos()).single;
      expect(todo.title, '买牛奶');
      expect(todo.star, isTrue);
    });
  });

  group('附件上传（图片）', () {
    test('文件名 hashCode 用 Java 的算法（不是 Dart 的）', () {
      // 这三个值是用 Java 规则（h = 31h + codeUnit，32 位有符号）算出来的，
      // 官方 App 的 multipart 字段名就是这个字符串
      expect(javaStringHashCode('l1.png'), -1156284928);
      expect(javaStringHashCode('nf.png'), -1050080013);
      expect(javaStringHashCode('a.txt'), 91067235);
      // 对照：Dart 自己的 String.hashCode 是另一个数（所以绝不能直接用）
      expect('l1.png'.hashCode, isNot(-1156284928));
    });

    test('multipart 字段名 = attachment[].name = 文件名 hashCode', () async {
      final file = File('${Directory.systemTemp.path}/note-up-$pid.png')
        ..writeAsBytesSync(List.filled(32, 7));
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      final b = await _boot({
        'SYNO.NoteStation.Note.set': {
          'data': [
            {
              'object_id': 'abc',
              'ver': '2.0',
              'attachment': {
                '_F1': {
                  'name': 'l1.png',
                  'size': 32,
                  'type': 'image',
                  'width': 4,
                  'height': 8,
                  'md5': 'x',
                  'ref': 'REF-1',
                },
              },
            },
          ],
        },
      });
      final note = await b.notes.uploadAttachments(
        objectId: 'abc',
        ver: '1.0',
        html: '<p>l1.png</p><img ref="REF-1">',
        files: [
          NoteAttachmentUpload(
            path: file.path,
            fileName: 'l1.png',
            ref: 'REF-1',
          ),
        ],
      );
      // 回包是 `{data:{data:[…],errors:[…]}}`，要解出第一条笔记
      expect(note, isNotNull);
      expect(note!.ver, '2.0');
      expect(note.attachments['_F1']!.name, 'l1.png');
      expect(note.attachments['_F1']!.isImage, isTrue);
      expect(note.attachments['_F1']!.displaySize, '32 B');

      final call = b.t.calls.lastWhere(
        (c) => c['method'] == 'set' && c['files'] != null,
      );
      expect(call['api'], 'SYNO.NoteStation.Note');
      expect(call['version'], '2', reason: '附件走 v2（官方 SetNoteOperationV2）');
      expect(call['object_id'], '"abc"');
      expect(call['ver'], '"1.0"');
      expect(call['commit_msg'], '{"device":"Flutter"}');
      final attachment =
          (jsonDecode(call['attachment'] as String) as List).single as Map;
      expect(attachment['action'], 'create');
      expect(attachment['format'], 'raw');
      expect(attachment['ref'], 'REF-1');
      expect(attachment['convert'], isTrue);
      expect(attachment['name'], '-1156284928');
      // multipart 的文件部分：字段名是 hashCode，filename 才是真名
      expect(call['files'], ['-1156284928:l1.png']);
      expect(call['file_bytes'], List.filled(32, 7));
    });

    test('一次可以带多个文件（真机就用它传了 l1.png + nf.png）', () async {
      final dir = Directory.systemTemp.createTempSync('note-multi-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = File('${dir.path}/l1.png')..writeAsBytesSync([1, 2, 3]);
      final n = File('${dir.path}/nf.png')..writeAsBytesSync([4, 5]);
      final b = await _boot({
        'SYNO.NoteStation.Note.set': {'data': []},
      });
      final note = await b.notes.uploadAttachments(
        objectId: 'abc',
        ver: '1.0',
        files: [
          NoteAttachmentUpload(path: a.path, fileName: 'l1.png'),
          NoteAttachmentUpload(path: n.path, fileName: 'nf.png'),
        ],
      );
      expect(note, isNull, reason: '服务端没回笔记就用 null，不瞎编');
      final call = b.t.calls.lastWhere((c) => c['files'] != null);
      expect(call['files'], ['-1156284928:l1.png', '-1050080013:nf.png']);
      final list = jsonDecode(call['attachment'] as String) as List;
      expect(list, hasLength(2));
      expect((list[1] as Map)['name'], '-1050080013');
      // ref 没给就按官方 Web 端规则生成（base64 里能解出文件名）
      final generated = utf8.decode(
        base64Decode((list[0] as Map)['ref'] as String),
      );
      expect(generated, endsWith('l1.png'));
    });

    test('set 回包里的 errors 要抛（一条请求可能部分失败）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.set': {
          'data': [],
          'errors': [
            {'code': 407, 'object_id': 'abc'},
          ],
        },
      });
      await expectLater(
        b.notes.setNote(objectId: 'abc', ver: '1.0', title: 'x'),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 407)),
      );
    });

    test('附件直链带 object_id/file_id/format/thumb', () async {
      final b = await _boot();
      final url = b.notes.attachmentUrl('abc', '_F1', thumb: true);
      expect(url, contains('api=SYNO.NoteStation.Note'));
      expect(url, contains('method=download'));
      expect(url, contains('object_id=%22abc%22'));
      expect(url, contains('file_id=%22_F1%22'));
      expect(url, contains('format=%22raw%22'));
      expect(url, contains('thumb=true'));
      expect(b.notes.attachmentUrl('abc', '_F1'), contains('thumb=false'));
    });
  });

  group('失败语义', () {
    test('没有 NoteStation 权限（160）会抛，带 api/method', () async {
      final b = await _boot(
        const {'SYNO.NoteStation.Info.get': {}},
        const {'SYNO.NoteStation.Info.get': 160},
      );
      await expectLater(
        b.notes.info(),
        throwsA(
          isA<DsmApiException>()
              .having((e) => e.code, 'code', 160)
              .having((e) => e.method, 'method', 'SYNO.NoteStation.Info.get'),
        ),
      );
    });

    test('参数形态错了（120）也抛', () async {
      final b = await _boot(
        const {'SYNO.NoteStation.Note.list': {}},
        const {'SYNO.NoteStation.Note.list': 120},
      );
      await expectLater(b.notes.listNotes(), throwsA(isA<DsmApiException>()));
    });

    test('服务器只到 v1 时不会硬发 v2/v4', () async {
      final t = FakeTransport(
        {
          'SYNO.NoteStation.Notebook.list': {'notebooks': []},
        },
        {
          ...FakeTransport.table,
          'SYNO.NoteStation.Notebook': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
          'SYNO.NoteStation.Note': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final notes = NoteStationApi(api);
      await notes.listNotebooks();
      final c = t.calls.lastWhere((c) => c['method'] == 'list');
      expect(c['version'], '1');
      expect(c.containsKey('filter'), isFalse);
    });
  });

  test('Todo/set：object_id 是数组 + 顶层任务要回发全部字段（官方形态）', () async {
    final t = FakeTransport();
    t.responses['SYNO.NoteStation.Todo.set'] = <String, dynamic>{};
    final api = NoteStationApi(DsmWebApi(t));

    // 顶层任务：字段全发（少发哪个服务端就清哪个）
    await api.setTodoDone(
      const TodoDto(
        objectId: 'T1',
        title: '买牛奶',
        done: false,
        dueDate: 1700000000000,
        priority: 2,
        reminderOffset: 300,
        noteId: 'N1',
        comment: '顺路',
        star: true,
      ),
      true,
    );
    var c = t.calls.last;
    expect(c['method'], 'set');
    expect(c['object_id'], '["T1"]', reason: 'object_id 必须是数组');
    expect(c['done'], 'true');
    expect(c['due_date'], '1700000000000');
    expect(c['priority'], '2');
    expect(c['reminder_offset'], '300');
    expect(c['note_id'], '"N1"');
    expect(c['comment'], '"顺路"');
    expect(c['star'], 'true');
    expect(c.containsKey('parent_id'), isFalse);

    // 子任务：只发 parent_id
    await api.setTodoDone(
      const TodoDto(objectId: 'T2', title: '子任务', parentId: 'T1'),
      true,
    );
    c = t.calls.last;
    expect(c['object_id'], '["T2"]');
    expect(c['parent_id'], '"T1"');
    expect(c.containsKey('due_date'), isFalse);
  });

  test('Todo/create 与 Todo/delete、Note/restore、Tag/set|delete 的形态', () async {
    final t = FakeTransport();
    t.responses['SYNO.NoteStation.Todo.create'] = {
      'data': {'object_id': 'T9', 'title': '写周报', 'done': false},
    };
    t.responses['SYNO.NoteStation.Todo.delete'] = <String, dynamic>{};
    t.responses['SYNO.NoteStation.Note.restore'] = <String, dynamic>{};
    t.responses['SYNO.NoteStation.Tag.set'] = <String, dynamic>{};
    t.responses['SYNO.NoteStation.Tag.delete'] = <String, dynamic>{};
    final api = NoteStationApi(DsmWebApi(t));

    final todo = await api.createTodo(title: '写周报', priority: 1);
    expect(todo.objectId, 'T9');
    var c = t.calls.last;
    expect(c['method'], 'create');
    expect(c['title'], '"写周报"');
    expect(c['done'], 'false');
    // 默认无截止日期用 -1（0 是 1970 年），优先级枚举见 TodoPriority
    expect(c['due_date'], '-1');
    expect(c['priority'], '1');

    await api.deleteTodos(['T9']);
    c = t.calls.last;
    expect(c['method'], 'delete');
    expect(c['version'], '1');
    expect(c['object_id'], '["T9"]');

    await api.restoreNote('N9');
    c = t.calls.last;
    expect(c['api'], 'SYNO.NoteStation.Note');
    expect(c['method'], 'restore');
    expect(c['version'], '1');
    expect(c['object_id'], '"N9"');

    await api.renameTag(tagId: 'G1', title: '工作');
    c = t.calls.last;
    expect(c['method'], 'set');
    expect(c['version'], '1');
    expect(c['tag_id'], '"G1"');
    expect(c['title'], '"工作"');

    await api.deleteTag('G1');
    c = t.calls.last;
    expect(c['method'], 'delete');
    expect(c['tag_id'], '"G1"', reason: '删除标签是标量，不是数组');
  });

  // ---------------------------------------------- 批次 A：真实缺陷的接口形状

  group('批次 A：剪藏 / create / 附件删除 / 移动', () {
    test('create 是 v3，且带 parent_id + commit_msg（官方真形状）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.create': {'object_id': 'new-1', 'ver': '1.0'},
      });
      await b.notes.createNote(title: 'T', parentId: 'nb1');
      final c = _callOf(b.t, 'SYNO.NoteStation.Note', 'create');
      // 官方 UI（live-write-verification §5.4）：version:3
      expect(c['version'], '3');
      expect(c['parent_id'], '"nb1"');
      expect(c.containsKey('notebook_id'), isFalse);
      expect(c['commit_msg'], '{"device":"Flutter","listable":false}');
    });

    test('Note.Ghost/create v2：官方剪藏形状（无 source_url/content）', () async {
      final t = FakeTransport(
        {'SYNO.NoteStation.Note.Ghost.create': <String, dynamic>{}},
        {...FakeTransport.table, ..._noteTable, ..._ghostTable},
      );
      final api = NoteStationApi(DsmWebApi(t));
      await api.createGhostNote(
        url: 'https://a.b/c',
        title: '标题',
        parentId: 'nb1',
        clipperMode: NoteStationApi.clipperModeFull,
        tags: const ['t1'],
      );
      final c = t.calls.last;
      expect(c['api'], 'SYNO.NoteStation.Note.Ghost');
      expect(c['version'], '2');
      expect(c['clipper_url'], '"https://a.b/c"');
      expect(c['clipper_mode'], '"fullpage"');
      expect(c['tag'], '["t1"]');
      expect(c['commit_msg'], '{"device":"Flutter"}');
      expect('${c['clipper_user_agent']}', contains('Chrome/40.0.2214.89'));
      expect(c.containsKey('source_url'), isFalse);
      expect(c.containsKey('content'), isFalse);
      // 官方规则：whole→fullpage，其余→simplepage
      expect(NoteStationApi.clipperModeFor('whole'), 'fullpage');
      expect(NoteStationApi.clipperModeFor('simplified'), 'simplepage');
      expect(NoteStationApi.clipperModeFor('other'), 'simplepage');
    });

    test('supportsGhostCreate 只看服务端版本表', () async {
      final withGhost = await _boot(
        {'SYNO.NoteStation.Note.Ghost.create': <String, dynamic>{}},
        {},
        _ghostTable,
      );
      expect(withGhost.notes.supportsGhostCreate(), isTrue);
      final without = await _boot();
      expect(without.notes.supportsGhostCreate(), isFalse);
    });

    test(
      'deleteNoteAttachments：只发元数据（name/file_id = 远端 id，无文件 part）',
      () async {
        final b = await _boot({
          'SYNO.NoteStation.Note.set': {'data': []},
        });
        await b.notes.deleteNoteAttachments(
          objectId: 'n1',
          ver: '1.0',
          fileIds: ['f1', 'f2'],
        );
        final c = _callOf(b.t, 'SYNO.NoteStation.Note', 'set');
        expect(
          c['attachment'],
          '[{"action":"delete","name":"f1","file_id":"f1"},'
          '{"action":"delete","name":"f2","file_id":"f2"}]',
        );
        // 删除是普通表单请求：没有任何 multipart 文件段
        expect(c.containsKey('files'), isFalse);
        expect(c.containsKey('file_name'), isFalse);
      },
    );

    test('A11 移动到其他笔记本：Note/set 带 parent_id；失败会抛', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.set': {'object_id': 'n1', 'ver': '2.0'},
      });
      // 目标笔记本不同
      await b.notes.setNote(objectId: 'n1', ver: '1.0', parentId: 'nb2');
      expect(
        _callOf(b.t, 'SYNO.NoteStation.Note', 'set')['parent_id'],
        '"nb2"',
      );
      // 目标笔记本相同：仍然是显式写回（幂等，服务端不报错）
      await b.notes.setNote(objectId: 'n1', ver: '2.0', parentId: 'nb2');
      expect(
        _callOf(b.t, 'SYNO.NoteStation.Note', 'set')['parent_id'],
        '"nb2"',
      );
      // 不传 parent_id → 不动笔记本（不能误清空）
      await b.notes.setNote(objectId: 'n1', ver: '2.0', title: 'x');
      expect(
        _callOf(b.t, 'SYNO.NoteStation.Note', 'set').containsKey('parent_id'),
        isFalse,
      );
      // 失败分支（服务端 120）要抛
      final bad = await _boot(
        {'SYNO.NoteStation.Note.set': <String, dynamic>{}},
        {'SYNO.NoteStation.Note.set': 120},
      );
      await expectLater(
        bad.notes.setNote(objectId: 'n1', ver: '1.0', parentId: 'nb2'),
        throwsA(isA<DsmApiException>()),
      );
    });
  });

  // ---------------------------------------------- 批次 B：智能 / Shelf / 复制

  group('批次 B：智能笔记本（SYNO.NoteStation.Smart v1）', () {
    test('list v1：field={query:true}，回包 smarts[] 解出 query', () async {
      final b = await _boot({
        'SYNO.NoteStation.Smart.list': {
          'smarts': [
            {
              'object_id': 'S1',
              'title': '工作',
              'query': {'keyword': '周报', 'tag_operator': 'and'},
            },
          ],
          'offset': 0,
          'total': 1,
        },
      });
      final list = await b.notes.listSmartNotebooks();
      expect(list.single.objectId, 'S1');
      expect(list.single.query.keyword, '周报');
      expect(list.single.query.tagAndOperator, isTrue);
      final c = _callOf(b.t, 'SYNO.NoteStation.Smart', 'list');
      expect(c['version'], '1');
      expect(c['field'], '{"query":true}');
    });

    test('create v1：title + query + commit_msg（三个都 Gson 二次编码）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Smart.create': {'object_id': 'S9'},
      });
      final id = await b.notes.createSmartNotebook(
        title: '待办收集',
        query: const NoteSmartQuery(keyword: 'todo', tags: ['work']),
      );
      expect(id, 'S9');
      final c = _callOf(b.t, 'SYNO.NoteStation.Smart', 'create');
      expect(c['version'], '1');
      expect(c['title'], '"待办收集"');
      // Gson：对象整体是字符串；null 字段不出现；tag_operator 总在
      expect(
        c['query'],
        '{"tag":["work"],"keyword":"todo","tag_operator":"or"}',
      );
      expect(c['commit_msg'], '{"device":"Flutter"}');
    });

    test('set v1：object_id 必发；title/query 非空才发', () async {
      final b = await _boot({
        'SYNO.NoteStation.Smart.set': <String, dynamic>{},
      });
      await b.notes.updateSmartNotebook(objectId: 'S1');
      var c = _callOf(b.t, 'SYNO.NoteStation.Smart', 'set');
      expect(c['object_id'], '"S1"');
      expect(c.containsKey('title'), isFalse);
      expect(c.containsKey('query'), isFalse);

      await b.notes.updateSmartNotebook(
        objectId: 'S1',
        title: '新名',
        query: const NoteSmartQuery(keyword: 'k'),
      );
      c = _callOf(b.t, 'SYNO.NoteStation.Smart', 'set');
      expect(c['title'], '"新名"');
      expect(c['query'], '{"keyword":"k","tag_operator":"or"}');
    });

    test('delete v1：object_id 标量（不是数组）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Smart.delete': <String, dynamic>{},
      });
      await b.notes.deleteSmartNotebook('S1');
      final c = _callOf(b.t, 'SYNO.NoteStation.Smart', 'delete');
      expect(c['version'], '1');
      expect(c['object_id'], '"S1"');
    });
  });

  group('批次 B：Shelf（Notebook/set v2 的 stack）', () {
    test('setNotebookStack：v2 + stack 字段（Gson 字符串）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Notebook.set': <String, dynamic>{},
      });
      await b.notes.setNotebookStack('nb1', stack: 'Work');
      final c = _callOf(b.t, 'SYNO.NoteStation.Notebook', 'set');
      expect(c['version'], '2', reason: 'VERSION_2_STACK');
      expect(c['object_id'], '"nb1"');
      expect(c['stack'], '"Work"');
    });

    test('移出 Shelf：stack 发 null（官方 remove_from_stack）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Notebook.set': <String, dynamic>{},
      });
      await b.notes.setNotebookStack('nb1', stack: null);
      final c = _callOf(b.t, 'SYNO.NoteStation.Notebook', 'set');
      expect(c['stack'], 'null');
    });
  });

  group('批次 B：复制 / 复制到加密 / 复制到明文（Note/copy v1）', () {
    test('普通复制：只发 object_id/title/parent_id，不发 encrypt/content', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.copy': {'object_id': 'n2'},
      });
      final id = await b.notes.copyNote(
        'n1',
        parentId: 'nb1',
        title: '原标题（副本）',
      );
      expect(id, 'n2');
      final c = _callOf(b.t, 'SYNO.NoteStation.Note', 'copy');
      expect(c['version'], '1');
      expect(c['object_id'], '"n1"');
      expect(c['title'], '"原标题（副本）"');
      expect(c['parent_id'], '"nb1"');
      expect(c.containsKey('encrypt'), isFalse);
      expect(c.containsKey('content'), isFalse);
    });

    test('复制到加密：encrypt=true + content=密文', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.copy': {'object_id': 'n3'},
      });
      await b.notes.copyNote(
        'n1',
        parentId: 'nb1',
        title: '副本',
        encrypt: true,
        content: 'CIPHERTEXT',
      );
      final c = _callOf(b.t, 'SYNO.NoteStation.Note', 'copy');
      expect(c['encrypt'], 'true');
      expect(c['content'], '"CIPHERTEXT"');
    });

    test('复制到明文：encrypt=false + content=明文', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.copy': {'object_id': 'n4'},
      });
      await b.notes.copyNote(
        'n1',
        parentId: 'nb1',
        title: '副本',
        encrypt: false,
        content: '<p>plain</p>',
      );
      final c = _callOf(b.t, 'SYNO.NoteStation.Note', 'copy');
      expect(c['encrypt'], 'false');
      expect(c['content'], '"<p>plain</p>"');
    });
  });
}
