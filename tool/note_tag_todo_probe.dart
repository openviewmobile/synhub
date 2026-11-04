// 真机探针：标签（`Note/set` 的 `tag` + Tag API）、待办（Todo create/set/delete）、
// 回收站（`Note/delete recycle=true` → `Note/restore` → 彻底删除）三条链路。
//
// 运行：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/note_tag_todo_probe.dart
//
// 探针产物（笔记 / 待办 / 标签）在结束前都会删干净。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'NoteStation',
  );
  final notes = NoteStationApi(api);
  final home = (await notes.listNotebooks()).first.objectId;

  // ---------------------------------------------------------------- 标签
  final created = await notes.createNote(
    title: '标签待办探针',
    parentId: home,
    html: '<p>probe</p>',
  );
  print('① 建笔记 ${created.objectId} ver=${created.ver}');
  await notes.setNote(
    objectId: created.objectId,
    ver: created.ver,
    tags: ['探针标签'],
  );
  final withTag = await notes.getNote(created.objectId);
  print('   加标签后 tags=${withTag.tags}');

  final tags = await notes.listTags();
  print('   Tag/list 共 ${tags.length} 个');
  for (final t in tags) {
    print(
      '     - id=${t.tagId} title=${t.title} '
      'count=${t.count} ids=${t.itemIds} cat=${t.category}',
    );
  }
  final probeTag = tags.where((t) => t.title == '探针标签').toList();
  print('   探针标签存在=${probeTag.length == 1}');

  // 清空标签（官方只发非空列表；这里验证传空数组能不能清掉）
  final refreshed = await notes.getNote(created.objectId);
  await notes.setNote(
    objectId: created.objectId,
    ver: refreshed.ver,
    tags: const [],
  );
  final cleared = await notes.getNote(created.objectId);
  print('   传 tag=[] 之后 tags=${cleared.tags}（空 = 清掉了）');

  // ---------------------------------------------------------------- 待办
  print('② 待办');
  final before = await notes.listTodos();
  print('   Todo/list 现有 ${before.length} 条');
  final todo = await notes.createTodo(
    title: '探针待办',
    priority: TodoPriority.medium,
  );
  print('   Todo/create → ${todo.objectId} done=${todo.done}');
  var mine = (await notes.listTodos()).firstWhere(
    (t) => t.objectId == todo.objectId,
    orElse: () => todo,
  );
  print(
    '   回读 done=${mine.done} priority=${mine.priority} '
    'due=${mine.dueDate} star=${mine.star} parent=${mine.parentId}',
  );
  await notes.setTodoDone(mine, true);
  mine = (await notes.listTodos()).firstWhere(
    (t) => t.objectId == todo.objectId,
    orElse: () => todo,
  );
  print('   勾选后 done=${mine.done}（应为 true）');
  print('   未完成筛选 ${(await notes.listTodos(done: false)).length} 条');

  // ------------------------------------------------------------ 回收站
  print('③ 回收站');
  await notes.deleteNote(created.objectId, recycle: true);
  final inBin = (await notes.listNotes(
    limit: 50,
  )).notes.where((n) => n.recycle).toList();
  print('   进回收站后在回收站里=${inBin.any((n) => n.objectId == created.objectId)}');
  await notes.restoreNote(created.objectId);
  final restored = (await notes.listNotes(
    limit: 50,
  )).notes.where((n) => n.objectId == created.objectId).toList();
  print('   还原后 recycle=${restored.isEmpty ? '不在列表' : restored.first.recycle}');

  // ---------------------------------------------------------------- 清理
  await notes.deleteTodos([todo.objectId]);
  print(
    '④ 清理：Todo/delete → '
    '${(await notes.listTodos()).where((t) => t.objectId == todo.objectId).isEmpty}',
  );
  for (final t in probeTag) {
    try {
      await notes.deleteTag(t.tagId);
    } catch (e) {
      // 标签在"最后一个引用被清掉"后可能已经被服务端自动回收，
      // 这时再删会拿到 1003 —— UI 上要当成"已经没了"，不能报错。
      print('   Tag/delete 报错（可能已被自动回收）：$e');
    }
  }
  final left = (await notes.listTags()).where((t) => t.title == '探针标签');
  print('   Tag/delete → 剩余 ${left.length}');
  await notes.deleteNote(created.objectId, recycle: false);
  final still = (await notes.listNotes(
    limit: 50,
  )).notes.where((n) => n.objectId == created.objectId);
  print('   探针笔记彻底删除=${still.isEmpty}');
  print(
    '   最终笔记：${(await notes.listNotes(limit: 50)).notes.map((e) => e.title).toList()}',
  );

  api.transport.close();
  exit(0);
}
