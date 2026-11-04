// r419 冲突场景的**宿主探针**（只为造/清 `note_conflict_page` 的真机数据态）。
//
// 为什么要有它：`note_conflict_page` 只有在"本地 dirty + 服务端 ver 变了"时才出现，
// 而服务端那一半必须由**另一个客户端**改 —— 本探针就是那个客户端，复用 App 自己的
// `NoteStationApi`（连带官方加密/回包形状），所以宿主侧不重复实现任何协议。
//
// 子命令（**写动词只在前三个**，`list` 是只读）：
//   list                     列笔记（object_id / ver / 标题）
//   ensure <标题>            没有同名探针就建一条，打印 object_id
//   bump <object_id> <正文>   用**最新 ver** 改正文（⇒ 服务端 ver 前进）
//   delete <object_id>       删掉（收尾用）
//
// 用法：
//   set -a; . ~/.synhub-nas.env; set +a
//   export PATH="<flutter-sdk>/bin:$PATH"
//   SYNO_NAS_URL="$SYNO_NAS_URL" SYNO_ACCOUNT="$SYNO_NAS_ACCOUNT" SYNO_PASSWORD="$SYNO_NAS_PASSWORD" \
//     dart run tool/r419_note_probe.dart list
//
// ★★ r419 实测：**这个文件现在跑不起来**（`dart run` 编不过）——
//   链路 `note_api.dart` → `core/device/device_model.dart` → `package:flutter`
//   ⇒ Dart 3.13.3 下报一堆 Flutter 框架的 switch 穷尽性错误（不是我的语法错）。
//   既存探针（如 `tool/note_probe.dart`）能跑，是因为它们**绕过** `note_api.dart` 直接打 `webapi.dart`。
//   **正解（下一轮照做）**：把场景写成 `tool/*_test.dart` 用 `flutter test tool/xxx_test.dart` 跑
//   （`flutter test` 只扫 `test/`，所以放 `tool/` 既能用 Flutter 运行器、又不会进全量闸门②）。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
  final cmd = args.isEmpty ? 'list' : args.first;
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

  switch (cmd) {
    case 'list':
      final list = await notes.listNotes(limit: 500);
      print('笔记数 = ${list.notes.length}');
      for (final n in list.notes) {
        print('${n.objectId}\tver=${n.ver}\t${n.title}');
      }
    case 'ensure':
      final title = args[1];
      final list = await notes.listNotes(limit: 500);
      final hit = list.notes.where((n) => n.title == title).toList();
      if (hit.isNotEmpty) {
        print('已存在：${hit.first.objectId}\tver=${hit.first.ver}');
        return;
      }
      final notebooks = await notes.listNotebooks();
      final nb = notebooks.firstWhere(
        (n) => n.preset,
        orElse: () => notebooks.first,
      );
      final created = await notes.createNote(
        title: title,
        parentId: nb.objectId,
        html: '<div>本地基线 v1</div>',
      );
      print('已创建：${created.objectId}\tver=${created.ver}');
    case 'bump':
      final objectId = args[1];
      final body = args[2];
      final cur = await notes.getNote(objectId);
      print('改前：ver=${cur.ver} title=${cur.title}');
      final after = await notes.setNote(
        objectId: objectId,
        ver: cur.ver,
        title: cur.title,
        html: '<div>$body</div>',
      );
      print('改后：ver=${after?.ver} title=${after?.title}');
    case 'delete':
      final objectId = args[1];
      await notes.deleteNote(objectId);
      print('已删除：$objectId');
    default:
      print('未知子命令：$cmd');
      exitCode = 2;
  }
}
