// NoteStation **wave5**（DSnote 对齐）离线套件。
//
// 覆盖本批新增/修正的服务端契约与 UI（证据逐字来自**官方 Android APK 反编译
// 源码 + smali**、**SPK 的 `webapi/SYNO.NoteStation.lib`** 与**官方前端明文 JS**）：
//   * I2 改口令：没有 `change_password` 接口 —— 官方是"本地换口令重加密 +
//     `Note/copy` 出副本"。带附件走 `Note.Polling/copy` + `cipher_key`
//     （APK `CopyNoteOperation.copyEncrypt` / `encryptParams`），
//     **不发**官方 Web 的顶层 `encryption:[…]`（那是 `synowebapi` 传输层选项）。
//   * A8 清空回收站：官方 `emptyRecycleBin` 把整筐 id **数组**交给
//     `Note/delete` v3（**不是**逐条循环）。
//   * A14 归档：`Notebook.Polling/archive` v1 `{object_id,enable}` →
//     `archive_status` → `archive_stop`（`Notebook/set` 没有 archive 字段）。
//   * A13 笔记信息：大小 = 官方 `NoteVo.getApproximateSize()` 口径；
//     **内部 id 一律不上屏**。
//   * N3 `source_url` 查看/编辑（`Note/set` 的 `source_url`，空串可清空）。
//   * F4 子标签：`Tag/set` 只收 `tag_id`+`title` ⇒ 嵌套是**标题 `/` 分层**
//     （官方 `checkTagIsParent` / `combineToFullTag` / `getTagChild`）。
//   * F9 列表/网格（官方 Web `view_by`: snippet/card，纯 UI）。
//   * G4 标签 + 操作符（`Note/list` 的 `tag` + `tag_operator`）。
//
// ★ 四个 falsification（红 → 原字节还原 → sha256 一致 → 绿）见 §F。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/data/note_crypto.dart';
import 'package:synhub/src/dsm/cgi_encryption.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_encryption.dart';
import 'package:synhub/src/features/notes/note_info_sheet.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_recycle_page.dart';
import 'package:synhub/src/features/notes/note_tag_tree.dart';
import 'package:synhub/src/features/notes/notes_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

const String kNoteApi = 'SYNO.NoteStation.Note';
const String kNotebookApi = 'SYNO.NoteStation.Notebook';
const String kNotebookPollingApi = 'SYNO.NoteStation.Notebook.Polling';
const String kPollingApi = 'SYNO.NoteStation.Note.Polling';
const String kTagApi = 'SYNO.NoteStation.Tag';

/// 真机 `SYNO.API.Info` 快照子集（wave5 用到的都在）。
const _noteTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  kNoteApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 4},
  kNotebookApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  kNotebookPollingApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  kPollingApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 3},
  kTagApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.API.Encryption': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Note.Encrypt': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// 记录"到底把哪些参数交给了 CGI 加密"的 `DsmCgiEncryption` 子类。
///
/// 改口令的 `cipher_key` 路线靠它钉死：密文本身解不开（公钥加密），
/// 但**加密前的参数表**是我们可以断言的（Falsification ① 就落在这里）。
/// 公钥用 harness 的真实 `getinfo`（登录本身就走真 RSA）。
class _RecordingCipher extends DsmCgiEncryption {
  _RecordingCipher(super.data);

  Map<String, String>? seen;

  @override
  Map<String, String> encryptFromParamList(Map<String, String> params) {
    seen = Map<String, String>.from(params);
    return super.encryptFromParamList(params);
  }
}

Future<({FakeTransport t, NoteStationApi notes, _RecordingCipher cipher})>
_apiBoot([
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, Map<String, dynamic>> extraTable = const {},
]) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._noteTable,
    ...extraTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final info = await api.call(
    'SYNO.API.Encryption',
    'getinfo',
    preferredVersion: 1,
    requiresAuth: false,
  );
  final cipher = _RecordingCipher(DsmCipherData.fromJson(info));
  final notes = NoteStationApi(api, cipherFactory: (_) => cipher);
  return (t: t, notes: notes, cipher: cipher);
}

Map<String, dynamic> _callOf(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

// ---------------------------------------------------------------- UI 装配

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values) s: AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 1, 1),
    );

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

Future<({FakeTransport t, ProviderContainer c})> _uiBoot(
  Map<String, Map<String, dynamic>> responses, {
  Set<String>? apis,
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._noteTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final container = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(NoteStationApi(api)),
      chatDatabaseProvider.overrideWith((ref) {
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(
          _snap(
            apis ??
                {
                  kNoteApi,
                  kNotebookApi,
                  kTagApi,
                  kNotebookPollingApi,
                  kPollingApi,
                },
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (t: t, c: container);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: child,
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

Map<String, dynamic> _noteJson({
  required String id,
  String title = 'T',
  String parent = 'nb1',
  int mtime = 1700000000,
  int ctime = 1690000000,
  String? sourceUrl,
  List<String> tags = const [],
  bool recycle = false,
  bool encrypt = false,
}) => {
  'object_id': id,
  'title': title,
  'parent_id': parent,
  'brief': 'brief-$id',
  'mtime': mtime,
  'ctime': ctime,
  'source_url': ?sourceUrl,
  'tag': tags,
  'recycle': recycle,
  'encrypt': encrypt,
  'ver': 'v1',
};

void main() {
  // ================================================================ A. API 级
  group('A14 归档：Notebook.Polling/archive v1（服务端 .lib + 官方 Web JS）', () {
    test('archive → archive_status(finish) → archive_stop，参数逐字对齐', () async {
      final b = await _apiBoot({
        '$kNotebookPollingApi.archive': {'task_id': 'TASK-1'},
        '$kNotebookPollingApi.archive_status': {
          'finish': true,
          'success': true,
        },
        '$kNotebookPollingApi.archive_stop': <String, dynamic>{},
      });
      await b.notes.archiveNotebook('NB1', enable: true);
      final archive = _callOf(b.t, kNotebookPollingApi, 'archive');
      expect('${archive['version']}', '1', reason: '官方 JS 写死 version:1');
      expect(jsonDecode('${archive['object_id']}'), 'NB1');
      expect(jsonDecode('${archive['enable']}'), true);
      final status = _callOf(b.t, kNotebookPollingApi, 'archive_status');
      expect(jsonDecode('${status['task_id']}'), 'TASK-1');
      expect(
        b.t.calls.any(
          (c) =>
              c['api'] == kNotebookPollingApi && c['method'] == 'archive_stop',
        ),
        isTrue,
        reason: '官方 pollingArchiveNotebookDone 一定会 archive_stop',
      );
      // 绝不走 Notebook/set（那里没有 archive 字段）
      expect(
        b.t.calls.any(
          (c) =>
              c['api'] == kNotebookApi &&
              c['method'] == 'set' &&
              '${c['archive']}' != 'null',
        ),
        isFalse,
      );
    });

    test('取消归档 enable=false', () async {
      final b = await _apiBoot({
        '$kNotebookPollingApi.archive': {'task_id': 'T2'},
        '$kNotebookPollingApi.archive_status': {'finish': true},
        '$kNotebookPollingApi.archive_stop': <String, dynamic>{},
      });
      await b.notes.archiveNotebook('NB2', enable: false);
      final archive = _callOf(b.t, kNotebookPollingApi, 'archive');
      expect(jsonDecode('${archive['enable']}'), false);
    });

    test('archive_status 带 errors → 如实抛错，绝不假装成功', () async {
      final b = await _apiBoot({
        '$kNotebookPollingApi.archive': {'task_id': 'T3'},
        '$kNotebookPollingApi.archive_status': {
          'finish': true,
          'errors': {'code': 1003},
        },
      });
      await expectLater(
        b.notes.archiveNotebook('NB3', enable: true),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 1003)),
      );
    });
  });

  group('I2 改口令：Note.Polling/copy + cipher_key（APK copyEncrypt）', () {
    test('cipher 收到 old_password/new_password；线上只有 cipher_key，无明文口令', () async {
      final b = await _apiBoot({
        '$kPollingApi.copy': {'task_id': 'PT-1'},
        '$kPollingApi.copy_status': {
          'finish': true,
          'success': true,
          'data': [
            {'object_id': 'NEW-1', 'ver': 'v9'},
          ],
        },
        '$kPollingApi.copy_stop': <String, dynamic>{},
      });
      final id = await b.notes.copyNoteEncryptPolling(
        objectId: 'OLD-1',
        title: 'T （副本）',
        parentId: 'nb1',
        oldPassword: 'old-pw',
        newPassword: 'new-pw',
        encryptedContent: 'U2FsdGVkX19cipher',
      );
      expect(id, 'NEW-1');

      // ★ Falsification ①：加密前的参数表必须同时含 old_password / new_password
      final seen = b.cipher.seen!;
      expect(
        seen.containsKey('old_password'),
        isTrue,
        reason: '服务端要靠 old_password 解原密文（漏发就换不了口令）',
      );
      expect(
        seen.containsKey('new_password'),
        isTrue,
        reason: 'new_password 是新密文的密钥',
      );
      expect(jsonDecode(seen['old_password']!), 'old-pw');
      expect(jsonDecode(seen['new_password']!), 'new-pw');

      final copy = _callOf(b.t, kPollingApi, 'copy');
      expect(
        '${copy['version']}',
        '3',
        reason: '本仓库轮询统一 negotiate([3,2,1])；.lib 确认 v1/v2/v3 的 copy 方法集完全相同',
      );
      expect(jsonDecode('${copy['object_id']}'), 'OLD-1');
      expect(jsonDecode('${copy['encrypt']}'), true);
      expect(jsonDecode('${copy['content']}'), 'U2FsdGVkX19cipher');
      // cipher_key 是**单个**字段（APK encryptFromParamList 的产物）
      expect(copy.containsKey('cipherkey'), isFalse);
      expect(
        copy.keys.any((k) => k == '__cIpHeRtExT'),
        isTrue,
        reason: 'cipherkey 的字段名来自 getinfo，Android 也是这个形态',
      );
      // 顶层 encryption 字段：DsmWebApi.call 只传 params，**不该**出现别的壳
      expect(copy.containsKey('encryption'), isFalse);
      // 绝不明文发口令
      expect(copy.containsKey('old_password'), isFalse);
      expect(copy.containsKey('new_password'), isFalse);
      expect(copy.containsKey('password'), isFalse);
    });
  });

  group('G4 标签 + 操作符：Note/list 的 tag + tag_operator', () {
    test('选中标签 → tag 是 JSON 数组、tag_operator 是 JSON 串', () async {
      final b = await _apiBoot({
        '$kNoteApi.list': {'total': 0, 'notes': <dynamic>[]},
      });
      await b.notes.listNotes(
        tags: ['work', 'work/urgent'],
        tagOperator: NoteStationApi.tagOperatorAnd,
      );
      final call = _callOf(b.t, kNoteApi, 'list');
      expect(jsonDecode('${call['tag']}'), ['work', 'work/urgent']);
      expect(jsonDecode('${call['tag_operator']}'), 'and');
    });

    test('没选标签就不发这两个字段（官方 query_params 也是可选）', () async {
      final b = await _apiBoot({
        '$kNoteApi.list': {'total': 0, 'notes': <dynamic>[]},
      });
      await b.notes.listNotes();
      final call = _callOf(b.t, kNoteApi, 'list');
      expect(call.containsKey('tag'), isFalse);
      expect(call.containsKey('tag_operator'), isFalse);
    });

    test('本地兜底过滤：AND = 全含，OR = 含其一', () {
      final a = NoteDto(objectId: 'a', title: 'a', tags: const ['x', 'y']);
      final b = NoteDto(objectId: 'b', title: 'b', tags: const ['x']);
      final c = NoteDto(objectId: 'c', title: 'c', tags: const ['z']);
      expect(
        filterNotesByTags(
          [a, b, c],
          const ['x', 'y'],
          'and',
        ).map((n) => n.objectId),
        ['a'],
      );
      expect(
        filterNotesByTags(
          [a, b, c],
          const ['x', 'y'],
          'or',
        ).map((n) => n.objectId),
        ['a', 'b'],
      );
      expect(filterNotesByTags([a, b, c], const [], 'or').length, 3);
    });
  });

  group('N3 source_url：Note/set 的 source_url（可写可清空）', () {
    test('写入：source_url 是 Gson 串', () async {
      final b = await _apiBoot({
        '$kNoteApi.set': {
          'data': [
            {'object_id': 'N1', 'ver': 'v2'},
          ],
        },
      });
      await b.notes.setNote(
        objectId: 'N1',
        ver: 'v1',
        sourceUrl: 'https://example.com/a',
      );
      final call = _callOf(b.t, kNoteApi, 'set');
      expect(jsonDecode('${call['source_url']}'), 'https://example.com/a');
    });

    test('清空：传空串时仍然发 source_url（不能被"非空才发"吞掉）', () async {
      final b = await _apiBoot({
        '$kNoteApi.set': {
          'data': [
            {'object_id': 'N1', 'ver': 'v2'},
          ],
        },
      });
      await b.notes.setNote(objectId: 'N1', ver: 'v1', sourceUrl: '');
      final call = _callOf(b.t, kNoteApi, 'set');
      expect(call.containsKey('source_url'), isTrue);
      expect(jsonDecode('${call['source_url']}'), '');
    });

    test('不传这个参数时完全不发 source_url', () async {
      final b = await _apiBoot({
        '$kNoteApi.set': {
          'data': [
            {'object_id': 'N1', 'ver': 'v2'},
          ],
        },
      });
      await b.notes.setNote(objectId: 'N1', ver: 'v1', title: 'x');
      final call = _callOf(b.t, kNoteApi, 'set');
      expect(call.containsKey('source_url'), isFalse);
    });
  });

  // ============================================================ B. 纯逻辑层
  group('F4 子标签：官方标题 "/" 分层的逐字移植', () {
    test('checkNoteTagIsParent：`work` 是 `work/urgent` 的父，不是 `workshop` 的', () {
      expect(checkNoteTagIsParent('work', 'work/urgent'), isTrue);
      expect(checkNoteTagIsParent('work', 'workshop'), isFalse);
      expect(checkNoteTagIsParent('work', 'work'), isFalse);
      expect(checkNoteTagIsParent('work/', 'work/urgent'), isTrue);
    });

    test('combineNoteTag / noteTagChildLabel 与官方 getTagChild 互为逆', () {
      expect(combineNoteTag('work', 'urgent'), 'work/urgent');
      expect(combineNoteTag('work/', 'urgent'), 'work/urgent');
      expect(combineNoteTag('', 'urgent'), 'urgent');
      expect(noteTagChildLabel('work/urgent', 'work'), 'urgent');
      expect(noteTagChildLabel('work/urgent', 'work/'), 'urgent');
      expect(noteTagChildLabel('urgent', ''), 'urgent');
    });

    test('buildNoteTagTree：缺父标签时按根处理，不臆造父对象', () {
      final tree = buildNoteTagTree(const [
        (title: 'work', count: 1),
        (title: 'work/urgent', count: 2),
        (title: 'work/urgent/today', count: 3),
        (title: 'orphan/child', count: 4),
        (title: 'life', count: 0),
      ]);
      expect(tree.map((n) => n.title), ['life', 'orphan/child', 'work']);
      final work = tree.firstWhere((n) => n.title == 'work');
      expect(work.children.map((n) => n.title), ['urgent']);
      final urgent = work.children.single;
      expect(urgent.children.map((n) => n.title), ['today']);
      expect(work.totalCount, 6);
      // 缺 `orphan` 父对象 → `orphan/child` 是根，且显示名保持完整标题
      expect(
        tree.firstWhere((n) => n.title == 'orphan/child').children,
        isEmpty,
      );
    });

    test('flattenNoteTagTree：折叠子标签时第 2 层之后都不可见', () {
      final tree = buildNoteTagTree(const [
        (title: 'work', count: 0),
        (title: 'work/urgent', count: 0),
        (title: 'work/urgent/today', count: 0),
      ]);
      final folded = flattenNoteTagTree(tree, showSubTags: false);
      expect(folded.where((e) => e.visible).map((e) => e.node.title), ['work']);
      final open = flattenNoteTagTree(tree, showSubTags: true);
      expect(open.where((e) => e.visible).map((e) => e.node.title), [
        'work',
        'urgent',
        'today',
      ]);
      expect(open.map((e) => e.depth), [0, 1, 2]);
    });
  });

  group('A13 笔记信息：大小用官方 getApproximateSize 口径', () {
    test('1000 + title + brief + content + 附件×100 + Σtag', () {
      final note = NoteDto(
        objectId: 'N1',
        title: 'abcd', // 4
        brief: 'bb', // 2
        content: 'ccccccc', // 7
        tags: const ['x', 'yy'], // 3
        attachments: const {'f1': NoteAttachmentDto(fileId: 'f1', name: 'a')},
      );
      expect(noteApproximateSize(note), 1000 + 4 + 2 + 7 + 100 + 3);
    });
  });

  // ================================================================== C. UI
  group('A8 清空回收站：批量（Note/delete v3 数组），不是逐条循环', () {
    testWidgets('点清空 → 恰好一次 delete，object_id 是全部 id 的数组', (tester) async {
      final b = await _uiBoot({
        '$kNoteApi.list': {
          'total': 2,
          'notes': [
            _noteJson(id: 'r1', title: 'R1', recycle: true),
            _noteJson(id: 'r2', title: 'R2', recycle: true),
          ],
        },
        '$kNotebookApi.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': 'NB1', 'ver': 'v1'},
          ],
        },
        '$kNoteApi.delete': {'success': true},
      });
      await _pump(tester, b.c, const NoteRecyclePage());
      expect(find.text('R1'), findsOneWidget);
      await tester.tap(find.byType(TextButton).first);
      await tester.pumpAndSettle();
      // 确认对话框
      await tester.tap(find.widgetWithText(FilledButton, '清空'));
      await tester.pumpAndSettle();
      final deletes = b.t.calls.where((c) => c['method'] == 'delete').toList();
      expect(deletes.length, 1, reason: '批量清空只发一次 Note/delete');
      expect(jsonDecode('${deletes.single['object_id']}'), ['r1', 'r2']);
      expect(jsonDecode('${deletes.single['recycle']}'), false);
    });
  });

  group('A14 归档入口：能力位缺失时**绝不显示**（Falsification ②）', () {
    Future<void> openNotebookMenu(WidgetTester tester) async {
      await tester.longPress(find.text('NB1'));
      await tester.pumpAndSettle();
    }

    testWidgets('有 Notebook.Polling 能力位 → 显示归档入口', (tester) async {
      final b = await _uiBoot({
        '$kNoteApi.list': {'total': 0, 'notes': <dynamic>[]},
        '$kNotebookApi.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': 'NB1', 'ver': 'v1'},
          ],
        },
      });
      await _pump(tester, b.c, const NotesPage());
      await openNotebookMenu(tester);
      expect(find.byKey(const Key('note-notebook-archive')), findsOneWidget);
    });

    testWidgets('缺能力位 → 归档入口消失（其余管理项仍在）', (tester) async {
      final b = await _uiBoot(
        {
          '$kNoteApi.list': {'total': 0, 'notes': <dynamic>[]},
          '$kNotebookApi.list': {
            'notebooks': [
              {'object_id': 'nb1', 'title': 'NB1', 'ver': 'v1'},
            ],
          },
        },
        apis: {kNoteApi, kNotebookApi, kTagApi, kPollingApi},
      );
      await _pump(tester, b.c, const NotesPage());
      await openNotebookMenu(tester);
      expect(find.byKey(const Key('note-notebook-archive')), findsNothing);
      expect(find.text('重命名'), findsOneWidget);
    });
  });

  group('F9 视图切换：列表 ⇄ 网格（纯 UI，无服务端调用）', () {
    testWidgets('默认列表；点切换后出现网格卡片', (tester) async {
      final b = await _uiBoot({
        '$kNoteApi.list': {
          'total': 1,
          'notes': [_noteJson(id: 'n1', title: 'Hello')],
        },
        '$kNotebookApi.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': 'NB1', 'ver': 'v1'},
          ],
        },
      });
      await _pump(tester, b.c, const NotesPage());
      expect(find.byKey(const Key('note-row-n1')), findsOneWidget);
      expect(find.byKey(const Key('note-grid-n1')), findsNothing);
      final before = b.t.calls.length;
      await tester.tap(find.byKey(const Key('note-view-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-grid-n1')), findsOneWidget);
      expect(find.byKey(const Key('note-row-n1')), findsNothing);
      expect(
        b.t.calls.length,
        before,
        reason: '视图切换是纯 UI（官方 view_by 只存本地用户设置）',
      );
    });
  });

  group('A13 笔记信息面板：内部 id 不上屏（Falsification ④）', () {
    testWidgets('显示大小/创建/修改/来源；object_id 不出现在任何文本里', (tester) async {
      final b = await _uiBoot({
        '$kNotebookApi.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': 'NB1', 'ver': 'v1'},
          ],
        },
      });
      final note = NoteDto(
        objectId: 'OBJECT-ID-SECRET',
        title: '我的笔记',
        parentId: 'nb1',
        content: '<p>hello</p>',
        brief: 'brief',
        ctime: 1690000000,
        mtime: 1700000000,
        ver: 'v1',
        sourceUrl: 'https://example.com/src',
        hasContent: true,
      );
      await _pump(tester, b.c, Scaffold(body: NoteInfoSheet(note: note)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-info-size')), findsOneWidget);
      expect(find.byKey(const Key('note-info-modified')), findsOneWidget);
      expect(find.text('https://example.com/src'), findsOneWidget);
      // ★ 内部 id 一律不上屏
      expect(find.textContaining('OBJECT-ID-SECRET'), findsNothing);
      expect(find.textContaining('nb1'), findsNothing);
    });
  });

  group('I2 改口令服务层：换口令＝本地重加密 + Note/copy（无附件分支）', () {
    test('content 用新口令重加密；旧口令解不开', () async {
      final b = await _apiBoot({
        '$kNoteApi.copy': {'object_id': 'NEW-9'},
      });
      final service = NoteEncryptionService(b.notes, NoteUnlockStore());
      final plain = '<p>secret</p>';
      final note = NoteDto(
        objectId: 'N1',
        title: 'T',
        parentId: 'nb1',
        ver: 'v1',
        encrypt: true,
        hasContent: true,
        content: NoteCrypto.encryptContent(plain, 'old-pw'),
      );
      final newId = await service.changePassword(
        note,
        oldPassword: 'old-pw',
        newPassword: 'new-pw',
      );
      expect(newId, 'NEW-9');
      final copy = _callOf(b.t, kNoteApi, 'copy');
      expect('${copy['version']}', '1');
      expect(jsonDecode('${copy['encrypt']}'), true);
      final cipher = jsonDecode('${copy['content']}') as String;
      expect(NoteCrypto.decryptContent(cipher, 'new-pw'), plain);
      expect(
        () => NoteCrypto.decryptContent(cipher, 'old-pw'),
        throwsA(isA<NoteDecryptException>()),
      );
      // 无附件分支：**不走** Polling，也不发任何口令明文
      expect(b.t.calls.any((c) => c['api'] == kPollingApi), isFalse);
      expect(copy.containsKey('old_password'), isFalse);
      expect(copy.containsKey('new_password'), isFalse);
    });
  });
}
