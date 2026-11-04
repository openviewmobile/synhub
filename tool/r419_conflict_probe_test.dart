// r419 · `note_conflict_page` 冲突场景的**宿主侧**（跑法 = `flutter test tool/…`）。
//
// 为什么不用 `dart run tool/*.dart`（仪器91）：`data/note_api.dart` 经
// `core/device/device_model.dart` 拉进 `package:flutter`，纯 Dart 编不过。
// 而 `flutter test` **只扫 `test/`** ⇒ 放在 `tool/` 既能用 Flutter 运行器、
// 又不会被全量闸门②收走（不会因为缺凭据而红）。
//
// 场景（设备侧配合）：
//   ① ensure  宿主建一条探针笔记（设备同步后进本地缓存，记 ver=V1）
//   ② 设备**离线**改这条 → 本地 dirty（基线 ver 仍是 V1）
//   ③ bump    宿主把同一条改掉 → 服务端 ver=V2
//   ④ 设备联网同步 → `mergeNoteList` 探测到"本地 dirty ＋ 服务端 ver 变走"
//      ⇒ `note-conflict-banner` 出现 → 点开就是 `note_conflict_page`（真数据）
//   ⑤ delete  宿主删探针（当轮还原）
//
// 跑法（凭据只走 `--dart-define`，**不落库**）：
//   set -a; . ~/.synhub-nas.env; set +a
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test tool/r419_conflict_probe_test.dart \
//     --dart-define=STAGE=ensure \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String stage = String.fromEnvironment('STAGE', defaultValue: 'list');
const String objectIdArg = String.fromEnvironment('OBJECT_ID');
const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String probeTitle = String.fromEnvironment(
  'PROBE_TITLE',
  defaultValue: 'r419 冲突探针',
);

Future<NoteStationApi> _login() async {
  if (url.isEmpty || account.isEmpty || password.isEmpty) {
    throw StateError('缺 --dart-define=NAS_URL/NAS_ACCOUNT/NAS_PASSWORD');
  }
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'NoteStation');
  return NoteStationApi(api);
}

void main() {
  test('r419 冲突场景 · 宿主阶段 STAGE=$stage', () async {
    final notes = await _login();
    switch (stage) {
      case 'list':
        final list = await notes.listNotes(limit: 500);
        print('r419|notes=${list.notes.length}|total=${list.total}');
        for (final n in list.notes) {
          print('r419|row|${n.objectId}|ver=${n.ver}|$probeTitle<=|${n.title}');
        }
      case 'ensure':
        final list = await notes.listNotes(limit: 500);
        final hit = list.notes.where((n) => n.title == probeTitle).toList();
        if (hit.isNotEmpty) {
          print('r419|ensure|exists|${hit.first.objectId}|ver=${hit.first.ver}');
          return;
        }
        final nbs = await notes.listNotebooks();
        final nb = nbs.firstWhere(
          (n) => n.preset,
          orElse: () => nbs.first,
        );
        final created = await notes.createNote(
          title: probeTitle,
          parentId: nb.objectId,
          html: '<div>本地基线（r419 探针）</div>',
        );
        print('r419|ensure|created|${created.objectId}|ver=${created.ver}');
      case 'get':
        final n = await notes.getNote(objectIdArg);
        print('r419|get|${n.objectId}|ver=${n.ver}|title=${n.title}');
        print('r419|get|content=${n.content}');
      case 'bump':
        final cur = await notes.getNote(objectIdArg);
        final after = await notes.setNote(
          objectId: objectIdArg,
          ver: cur.ver,
          title: cur.title,
          html: '<div>服务端这一侧改过（r419 探针）</div>',
        );
        print('r419|bump|before=${cur.ver}|after=${after?.ver}');
      case 'delete':
        // 探针笔记可能已经在回收站口径里 —— 真删（recycle=false）
        await notes.deleteNote(objectIdArg, recycle: false);
        print('r419|delete|ok|$objectIdArg');
      default:
        fail('未知 STAGE=$stage');
    }
  });
}
