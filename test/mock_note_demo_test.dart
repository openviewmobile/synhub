// `tool/mock_dsm/mock_note_demo.dart`（可写内存笔记库）的离线用例。
//
// 为什么要有这一档（第 324 轮）：笔记模块在 Mock Server 上**原来一条夹具都没有**
// ⇒ 「新建 / 编辑笔记」成功没有在**跨进程**意义上无法判定。这个文件把内存库的
// 语义逐条钉住（字段名、`Note/set` 的**特殊回包形状**、空标题合法性、
// 拒绝的请求不许改状态），它是 macOS 集成测试那一档的**前置证据**。
import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import '../tool/mock_dsm/mock_note_demo.dart';

/// 起一台装了笔记内存库的 backend + 取库引用。
({MockDsmBackend b, MockNoteStation db, MockDsmResponse Function(String, String, Map<String, dynamic>) call})
_boot({MockNoteStation? seeded}) {
  final b = MockDsmBackend(catalog: DsmCatalog.load());
  // ★ 走 `backend.handle(...)`（与真机同一条入口：目录校验 + 版本 + 方法表 +
  //   authLevel 都过一遍），**不要**直接摸 `fixtures` —— 那样"夹具注册对了但
  //   目录里版本对不上"这类缺陷就测不出来。
  final sid = b.login(username: 'mockuser', admin: false);
  final db = b.installNoteDemo(ns: seeded);
  /// ★ 版本**按目录协商**（`Notebook` 的 maxVersion 是 **2**、`Note` 是 4）——
  /// 第一版这里写死 `version: 3`，`Notebook/list` 就回 `103`（方法不存在）。
  /// 这正是 §2.0.15 那条"版本陷阱"在**仪器侧**的复现：Mock 自己也要按方法表谈版本。
  int versionFor(String api, String method) {
    final spec = b.catalog.apis[api];
    if (spec == null) return 1;
    for (var v = spec.maxVersion; v >= spec.minVersion; v--) {
      if (spec.methods[v]?.contains(method) ?? false) return v;
    }
    return spec.maxVersion;
  }

  MockDsmResponse call(
    String api,
    String method,
    Map<String, dynamic> p, {
    int? version,
  }) => b.handle('entry.cgi', {
    'api': api,
    'method': method,
    'version': version ?? versionFor(api, method),
    '_sid': sid,
    ...p,
  });
  return (b: b, db: db, call: call);
}

Map<String, dynamic> _data(MockDsmResponse r) =>
    Map<String, dynamic>.from(r.json['data'] as Map);

List<Map<String, dynamic>> _notes(MockDsmResponse r) => [
  for (final e in (_data(r)['notes'] as List))
    Map<String, dynamic>.from(e as Map),
];

List<Map<String, dynamic>> _notebooks(MockDsmResponse r) => [
  for (final e in (_data(r)['notebooks'] as List))
    Map<String, dynamic>.from(e as Map),
];

void main() {
  test('① 种子里有预设笔记本；`Notebook/list` 的字段名与 DTO 一致', () {
    final h = _boot();
    final r = h.call('SYNO.NoteStation.Notebook', 'list', {});
    expect(r.ok, isTrue);
    final list = _notebooks(r);
    expect(list, hasLength(1));
    // 官方预设笔记本：`preset: true` + `title: ""`（显示名由客户端兜）
    expect(list.first['preset'], isTrue);
    expect(list.first['title'], '');
    expect(list.first['object_id'], h.db.notebooks.first.id);
  });

  test('② `Note/list` 不带 content（`hasContent` 的判据），`get` 才带正文', () {
    final h = _boot();
    h.db.addNote(title: 'with body', parentId: 'nb_1', content: '<p>hi</p>');
    final list = _notes(h.call('SYNO.NoteStation.Note', 'list', {}));
    expect(list.map((n) => n['title']), contains('with body'));
    expect(
      list.every((n) => !n.containsKey('content')),
      isTrue,
      reason: '★ 列表项必须**不带** `content` 键 —— 客户端 `NoteDto.hasContent` 就是按它判的',
    );
    final id = list.firstWhere((n) => n['title'] == 'with body')['object_id'];
    final one = _data(h.call('SYNO.NoteStation.Note', 'get', {
      'object_id': '"$id"',
    }));
    expect(one['content'], '<p>hi</p>');
  });

  test('③ 新建笔记：`create` 后**列表里真的多一条**（不是"回了 success"）', () {
    final h = _boot();
    final before = _notes(h.call('SYNO.NoteStation.Note', 'list', {})).length;
    final r = h.call('SYNO.NoteStation.Note', 'create', {
      'title': '"r324 新笔记"',
      'parent_id': '"nb_1"',
      'content': '"<p>正文</p>"',
      'commit_msg': '{"device":"mock"}',
    });
    expect(r.ok, isTrue);
    final id = '${_data(r)['object_id']}';
    expect(id, isNotEmpty, reason: '必须回 object_id（客户端靠它建本地行）');
    final after = _notes(h.call('SYNO.NoteStation.Note', 'list', {}));
    expect(after, hasLength(before + 1));
    expect(after.map((n) => n['title']), contains('r324 新笔记'));
    // 正文也真的存进去了（回读 `get`，不看 create 的响应体）
    final one = _data(h.call('SYNO.NoteStation.Note', 'get', {
      'object_id': '"$id"',
    }));
    expect(one['content'], '<p>正文</p>');
  });

  test('④ `Note/set`：改标题 + **版本号 +1**，回包是 `{data:{data:[…]}}` 形状', () {
    final h = _boot();
    final id = h.db.notes.first.id;
    final ver0 = h.db.notes.first.ver;
    final r = h.call('SYNO.NoteStation.Note', 'set', {
      'object_id': '"$id"',
      'ver': '"$ver0"',
      'title': '"改过的标题"',
      'commit_msg': '{"device":"mock"}',
    });
    expect(r.ok, isTrue);
    final d = _data(r);
    // ★ 这个形状是官方 `NoteVoV2`：**成功也走 data.data 数组**（不是裸 note）
    expect(d['data'], isA<List>());
    expect((d['data'] as List), isNotEmpty);
    expect(d['errors'], isEmpty, reason: '成功的保存不该带 errors');
    expect(
      '${((d['data'] as List).first as Map)['title']}',
      '改过的标题',
      reason: '★ 回包里的 title 必须是新值（客户端 `_unwrapSetResponse` 直接用它）',
    );
    expect(h.db.noteById(id)!.ver, '${int.parse(ver0) + 1}', reason: '乐观锁版本要 +1');
    // 服务端回读（跨调用判据）
    final after = _notes(h.call('SYNO.NoteStation.Note', 'list', {}));
    expect(after.firstWhere((n) => n['object_id'] == id)['title'], '改过的标题');
  });

  test('⑤ `set` 传空标题是**合法**的（空串 ≠ 没传）；未知 id 走 errors 分支', () {
    final h = _boot();
    final id = h.db.notes.first.id;
    final r = h.call('SYNO.NoteStation.Note', 'set', {
      'object_id': '"$id"',
      'title': '""',
      'commit_msg': '{"device":"mock"}',
    });
    expect(r.ok, isTrue);
    expect(
      h.db.noteById(id)!.title,
      '',
      reason: '★ `title:""` 必须真的被写成空 —— 拿"空串"当"没传"是最容易犯的错（官方允许空标题）',
    );
    final miss = h.call('SYNO.NoteStation.Note', 'set', {
      'object_id': '"nope"',
      'title': '"x"',
    });
    expect(
      miss.ok,
      isTrue,
      reason: '★ 官方 `Note/set` 的失败也走 `success:true` + `errors` 信封（不是 error 码）',
    );
    final errs = _data(miss)['errors'] as List;
    expect('${(errs.first as Map)['code']}', '117');
    expect(h.db.notes, hasLength(1), reason: '未知 id 不许凭空造一条');
  });

  test('⑥ `create` 缺 `parent_id` / 父笔记本不存在 ⇒ 114，且**不留下半条笔记**', () {
    final h = _boot();
    for (final parent in ['', '"nb_不存在"']) {
      final r = h.call('SYNO.NoteStation.Note', 'create', {
        'title': '"半条"',
        'parent_id': '"$parent"'.replaceAll('""', ''),
      });
      expect(r.ok, isFalse);
      expect(r.errorCode, 114);
    }
    expect(h.db.notes, hasLength(1), reason: '被拒的请求不许改状态');
  });

  test('⑦ `list` 认 `sort_by`/`sort_direction`/`limit`（排序参数发对了才看得出来）', () {
    final h = _boot();
    h.db.addNote(title: 'a', parentId: 'nb_1');
    h.db.addNote(title: 'b', parentId: 'nb_1');
    final asc = _notes(
      h.call('SYNO.NoteStation.Note', 'list', {
        'sort_by': '"ctime"',
        'sort_direction': '"asc"',
      }),
    );
    expect(
      asc.map((n) => n['title']).toList().first,
      'mock seeded note',
      reason: '升序第一条 = 最早创建的那条',
    );
    final limited = _notes(h.call('SYNO.NoteStation.Note', 'list', {'limit': '1'}));
    expect(limited, hasLength(1));
    expect(_data(h.call('SYNO.NoteStation.Note', 'list', {}))['total'], 3);
  });

  test('⑧ `delete` 之后列表里没有它；空库（`empty()`）种子里没有任何笔记', () {
    final h = _boot();
    final id = h.db.notes.first.id;
    final r = h.call('SYNO.NoteStation.Note', 'delete', {'object_id': '"$id"'});
    expect(r.ok, isTrue);
    expect(_notes(h.call('SYNO.NoteStation.Note', 'list', {})), isEmpty);

    final e = _boot(seeded: MockNoteStation.empty());
    expect(_notes(e.call('SYNO.NoteStation.Note', 'list', {})), isEmpty);
    expect(
      _notebooks(e.call('SYNO.NoteStation.Notebook', 'list', {})),
      hasLength(1),
      reason: '空库仍要有**一个可选的笔记本**，否则"新建笔记"这条路走不到',
    );
  });
}
