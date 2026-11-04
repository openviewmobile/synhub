// Wave2 笔记缺口补齐的离线用例：
//   * A12 多选批量（`Note/delete` v3 / `Note/set` v3 的 `object_id` **数组**形态）
//   * C9/G5 附件文本搜索（服务端 `FTS:search` + `Note/get_attachment_text` v4）
//   * F7 排序参数透传（`Note/list` 的 `sort_by`/`sort_direction`）
//   * N7 默认字号落 KV
//   * J8/L2 分享面板剪藏到笔记
//   * C4/C5 笔记录音/录像附件入口
//
// 真机取证（本批 NAS `SYNO.API.Info` + 逐条实调）：
//   * `SYNO.NoteStation.FTS:search` v1 OK，回包 `{matches:[...], offset:int}`；
//     `Note:search` / `SYNO.NoteStation.Search` **不存在**（103/102）；
//   * `Note:list` v4 OK 且接受 `sort_by`（但"OK ≠ 参数被采纳"，故这里只断言
//     **参数确实透传**，不断言服务端已按它排序）。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/note_store.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/chat/share_intent.dart';
import 'package:synhub/src/features/chat/share_intent_host.dart';
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_picker.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/notes_page.dart';

import 'support/chat_harness.dart' show FakeTransport, bootChat;

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
  'SYNO.NoteStation.Todo': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Setting': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.FTS': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _apiNote(
  String id,
  String title, {
  String parentId = 'nb1',
  int mtime = 1000,
  int ctime = 500,
  Map<String, dynamic> attachment = const {},
}) => {
  'object_id': id,
  'title': title,
  'parent_id': parentId,
  'brief': '',
  'mtime': mtime,
  'ctime': ctime,
  'ver': '1.0',
  'recycle': false,
  'encrypt': false,
  'has_content': true,
  'tags': <String>[],
  'attachment': attachment,
};

Map<String, dynamic> _notebook(
  String id,
  String title, {
  bool preset = false,
}) => {'object_id': id, 'title': title, 'preset': preset};

/// API 级 boot（不建容器）
Future<({NoteStationApi notes, FakeTransport t})> _apiBoot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, Map<String, dynamic>>? apiTable,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._noteTable,
    ...?apiTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (notes: NoteStationApi(api), t: t);
}

/// provider/UI 级 boot（真 Drift 内存库）
Future<
  ({
    FakeTransport t,
    ProviderContainer container,
    NoteStore store,
    ChatStore chatStore,
  })
>
_containerBoot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, Map<String, dynamic>>? apiTable,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._noteTable,
    ...?apiTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(NoteStationApi(api)),
      chatDatabaseProvider.overrideWithValue(db),
    ],
  );
  addTearDown(container.dispose);
  return (
    t: t,
    container: container,
    store: NoteStore(db),
    chatStore: ChatStore(db),
  );
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

void main() {
  group('A12 批量接口 id 数组形态（API 级）', () {
    test('deleteNotes：Note/delete v3，object_id 是 JSON 数组', () async {
      final b = await _apiBoot({
        'SYNO.NoteStation.Note.delete': {'success': true},
      });
      await b.notes.deleteNotes(['n1', 'n2', 'n3']);
      final call = b.t.calls.lastWhere((c) => c['method'] == 'delete');
      expect('${call['version']}', '3', reason: '官方 Web 写死 version:3');
      expect(jsonDecode('${call['object_id']}'), ['n1', 'n2', 'n3']);
      expect(jsonDecode('${call['recycle']}'), true);
    });

    test('moveNotes：Note/set v3 数组 + parent_id；errors[] 逐条回报', () async {
      final b = await _apiBoot({
        'SYNO.NoteStation.Note.set': {
          'data': [
            {'object_id': 'n1', 'ver': '2.0'},
          ],
          'errors': [
            {'code': 1003, 'object_id': 'n2'},
          ],
        },
      });
      final r = await b.notes.moveNotes(['n1', 'n2'], parentId: 'nb9');
      expect(r.succeeded, 1);
      expect(r.failed, {'n2': 1003});
      final call = b.t.calls.lastWhere((c) => c['method'] == 'set');
      expect('${call['version']}', '3');
      expect(jsonDecode('${call['object_id']}'), ['n1', 'n2']);
      expect(jsonDecode('${call['parent_id']}'), 'nb9');
      expect(jsonDecode('${call['commit_msg']}')['device'], isNotEmpty);
    });

    test('老服务端（Note v2）deleteNotes 退回逐条标量调用', () async {
      final b = await _apiBoot(
        {
          'SYNO.NoteStation.Note.delete': {'success': true},
        },
        apiTable: {
          'SYNO.NoteStation.Note': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 2,
          },
        },
      );
      expect(b.notes.supportsNoteBatch, isFalse);
      final r = await b.notes.deleteNotes(['n1', 'n2']);
      expect(r.succeeded, 2);
      final deletes = b.t.calls.where((c) => c['method'] == 'delete').toList();
      expect(deletes, hasLength(2), reason: 'v3 不可用 → 逐条');
      expect(jsonDecode('${deletes[0]['object_id']}'), 'n1');
      expect(deletes.every((c) => '${c['version']}' == '1'), isTrue);
    });
  });

  group('C9/G5 附件文本搜索', () {
    test('search_attachment：读 Setting/get v2 的能力位', () async {
      final on = await _apiBoot({
        'SYNO.NoteStation.Setting.get': {'search_attachment': true},
      });
      expect(await on.notes.searchAttachmentEnabled(), isTrue);
      final off = await _apiBoot({
        'SYNO.NoteStation.Setting.get': {'search_attachment': false},
      });
      expect(await off.notes.searchAttachmentEnabled(), isFalse);
      // 读不到设置 → false（不报错）
      final missing = await _apiBoot({
        'SYNO.NoteStation.Setting.get': {'success': true},
      });
      expect(await missing.notes.searchAttachmentEnabled(), isFalse);
    });

    test('开关打开：附件搜索走服务端 FTS:search（真机取证的方法）', () async {
      final b = await _containerBoot({
        'SYNO.NoteStation.Setting.get': {'search_attachment': true},
        'SYNO.NoteStation.Note.list': {
          'notes': [_apiNote('n1', '甲')],
          'total': 1,
        },
        'SYNO.NoteStation.FTS.search': {
          'matches': [
            {'object_id': 'n2', 'title': '附件里提到季度'},
          ],
          'offset': 0,
        },
      });
      await b.chatStore.setSetting(kNoteAttachmentSearchKey, 'true');
      final hits = await b.container.read(
        noteAttachmentSearchMatchesProvider('季度').future,
      );
      expect(hits, {'n2'});
      expect(
        b.t.calls.any(
          (c) => c['api'] == 'SYNO.NoteStation.FTS' && c['method'] == 'search',
        ),
        isTrue,
        reason: '附件/全文搜索的落点是 FTS:search',
      );
    });

    test('FTS 空结果 → 本地兜底真的调用 Note/get_attachment_text', () async {
      final b = await _containerBoot({
        'SYNO.NoteStation.Setting.get': {'search_attachment': true},
        'SYNO.NoteStation.Note.list': {
          'notes': [_apiNote('n1', '甲')],
          'total': 1,
        },
        'SYNO.NoteStation.FTS.search': {'matches': <dynamic>[], 'offset': 0},
        'SYNO.NoteStation.Note.get': _apiNote(
          'n1',
          '甲',
          attachment: {
            'f1': {'name': 'report.txt', 'type': 'text/plain', 'size': 12},
          },
        ),
        'SYNO.NoteStation.Note.get_attachment_text': {'text': '季度报告正文'},
      });
      await b.chatStore.setSetting(kNoteAttachmentSearchKey, 'true');
      final hits = await b.container.read(
        noteAttachmentSearchMatchesProvider('季度').future,
      );
      expect(hits, {'n1'});
      expect(
        b.t.calls.any((c) => c['method'] == 'get_attachment_text'),
        isTrue,
        reason: 'get_attachment_text 必须真的被调用（不再是死代码）',
      );
    });

    test('搜索 UI 的可见列表并入附件命中（C9 真的接进了搜索链路）', () async {
      final b = await _containerBoot({
        'SYNO.NoteStation.Setting.get': {'search_attachment': true},
        'SYNO.NoteStation.Note.list': {
          'notes': [_apiNote('n1', '甲'), _apiNote('n2', '乙')],
          'total': 2,
        },
        // 标题里没有"季度"，只有 FTS 命中 → 靠附件命中并入
        'SYNO.NoteStation.FTS.search': {
          'matches': [
            {'object_id': 'n2'},
          ],
          'offset': 0,
        },
      });
      await b.chatStore.setSetting(kNoteAttachmentSearchKey, 'true');
      b.container.read(noteKeywordProvider.notifier).set('季度');
      final visible = await b.container.read(visibleNotesProvider.future);
      expect(visible.map((n) => n.objectId), contains('n2'));
    });

    test('开关关闭：不发任何附件请求（隐藏而非报错）', () async {
      final b = await _containerBoot({
        'SYNO.NoteStation.Note.list': {
          'notes': [_apiNote('n1', '甲')],
          'total': 1,
        },
        'SYNO.NoteStation.Setting.get': {'search_attachment': true},
      });
      final enabled = await b.container.read(
        noteAttachmentSearchEnabledProvider.future,
      );
      expect(enabled, isFalse, reason: '本地 KV 默认关');
      final hits = await b.container.read(
        noteAttachmentSearchMatchesProvider('季度').future,
      );
      expect(hits, isEmpty);
      expect(
        b.t.calls.any(
          (c) =>
              c['method'] == 'get_attachment_text' ||
              c['api'] == 'SYNO.NoteStation.FTS',
        ),
        isFalse,
        reason: '关了就不能发请求',
      );
    });
  });

  group('F7 排序参数透传', () {
    test('noteSortProvider → Note/list 带 sort_by/sort_direction', () async {
      final b = await _containerBoot({
        'SYNO.NoteStation.Note.list': {
          'notes': [_apiNote('n1', '乙'), _apiNote('n2', '甲')],
          'total': 2,
        },
      });
      // 默认 mtime desc
      await b.container.read(noteListProvider.future);
      var list = b.t.calls.lastWhere((c) => c['method'] == 'list');
      expect(list['sort_by'], 'mtime');
      expect(list['sort_direction'], 'desc');

      // 切成标题升序 → 参数必须跟着变
      final n = b.container.read(noteSortProvider.notifier);
      n.setBy('title');
      n.setDirection('asc');
      await b.container.read(noteListProvider.future);
      list = b.t.calls.lastWhere((c) => c['method'] == 'list');
      expect(list['sort_by'], 'title');
      expect(list['sort_direction'], 'asc');
    });
  });

  group('N7 默认字号', () {
    test('默认 x-small（官方值），设置后落 KV 并读回', () async {
      final b = await _containerBoot({});
      expect(
        b.container.read(noteDefaultFontSizeProvider),
        'syno-fontsize-x-small',
      );
      await b.container
          .read(noteDefaultFontSizeProvider.notifier)
          .set('syno-fontsize-xx-large');
      expect(
        await b.chatStore.setting(kNoteDefaultFontSizeKey),
        'syno-fontsize-xx-large',
      );
      expect(
        b.container.read(noteDefaultFontSizeProvider),
        'syno-fontsize-xx-large',
      );
    });
  });

  group('C4/C5 录音 / 录像', () {
    test('录音文件名照官方 file_<millis>.3gp', () {
      final name = noteAudioFileName(DateTime.fromMillisecondsSinceEpoch(42));
      expect(name, 'file_42.3gp');
    });

    testWidgets('编辑器：录音入口 → 面板 → 停止走注入的录音器', (tester) async {
      // path_provider 在 widget 测试里没有平台实现 → 临时目录给个假的
      TestWidgetsFlutterBinding.ensureInitialized();
      const ppChannel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ppChannel, (call) async => '/tmp');
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ppChannel, null),
      );
      final fake = _FakeRecorder();
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          noteAudioRecorderProvider.overrideWithValue(fake),
          noteLocalPickerProvider.overrideWithValue((_) async => const []),
        ],
      );
      addTearDown(container.dispose);
      await _pump(
        tester,
        container,
        const NoteEditorPage(
          notebooks: [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-record-audio-entry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('note-record-audio-entry')));
      await tester.pumpAndSettle();
      expect(fake.started, isTrue);
      await tester.tap(find.byKey(const Key('note-audio-record-stop')));
      await tester.pumpAndSettle();
      expect(fake.stopped, isTrue);
    });
  });

  group('A12 多选（UI）', () {
    testWidgets('长按进入多选 → 计数 → 全选 → 反选 → 批量删除数组下发', (tester) async {
      final b = await _containerBoot({
        'SYNO.NoteStation.Note.list': {
          'notes': [
            _apiNote('n1', '甲'),
            _apiNote('n2', '乙'),
            _apiNote('n3', '丙'),
          ],
          'total': 3,
        },
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [_notebook('nb1', '工作')],
        },
        'SYNO.NoteStation.Note.delete': {'success': true},
      });
      await _pump(tester, b.container, const NotesPage());
      await tester.pump(const Duration(milliseconds: 120));

      // 长按一条进入多选
      await tester.longPress(find.text('甲'));
      await tester.pump();
      expect(find.byKey(const Key('note-selection-count')), findsOneWidget);
      expect(find.text('已选 1 项'), findsOneWidget);

      // 全选 → 3
      await tester.tap(find.byKey(const Key('note-selection-all')));
      await tester.pump();
      expect(find.text('已选 3 项'), findsOneWidget);

      // 反选 → 0
      await tester.tap(find.byKey(const Key('note-selection-invert')));
      await tester.pump();
      expect(find.text('已选 0 项'), findsOneWidget);

      // 再全选后批量删除
      await tester.tap(find.byKey(const Key('note-selection-all')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('note-selection-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      final call = b.t.calls.lastWhere((c) => c['method'] == 'delete');
      expect('${call['version']}', '3');
      expect(jsonDecode('${call['object_id']}').length, 3);
    });

    testWidgets('批量移动：选目标笔记本 → Note/set 数组 + parent_id', (tester) async {
      final b = await _containerBoot({
        'SYNO.NoteStation.Note.list': {
          'notes': [_apiNote('n1', '甲'), _apiNote('n2', '乙')],
          'total': 2,
        },
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [_notebook('nb1', '工作'), _notebook('nb2', '归档')],
        },
        'SYNO.NoteStation.Note.set': {
          'data': <dynamic>[],
          'errors': <dynamic>[],
        },
      });
      await _pump(tester, b.container, const NotesPage());
      await tester.pump(const Duration(milliseconds: 120));

      await tester.longPress(find.text('甲'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('note-selection-all')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('note-selection-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-move-target-nb2')));
      await tester.pumpAndSettle();

      final call = b.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.NoteStation.Note' && c['method'] == 'set',
      );
      expect(jsonDecode('${call['object_id']}').length, 2);
      expect(jsonDecode('${call['parent_id']}'), 'nb2');
    });
  });

  group('J8/L2 分享面板剪藏到笔记', () {
    testWidgets('分享底部弹层出现「剪藏到笔记」，点它建笔记而不是发频道', (tester) async {
      final source = _FakeShareSource(
        const ShareIntentData(
          action: 'android.intent.action.SEND',
          mimeType: 'text/plain',
          text: 'https://example.com/news',
          subject: '页面标题',
          files: [],
        ),
      );
      // 笔记 API 单独一条 transport（带 Note 能力表）
      final noteTransport = FakeTransport(
        {
          'SYNO.NoteStation.Notebook.list': {
            'notebooks': [_notebook('nb1', '工作', preset: true)],
          },
          'SYNO.NoteStation.Note.create': {'object_id': 'new1', 'ver': '1.0'},
        },
        {...FakeTransport.table, ..._noteTable},
      );
      final noteApi = DsmWebApi(noteTransport);
      await noteApi.discover();
      await noteApi.login(account: 'a', password: 'b');

      final h = await bootChat(
        moreOverrides: [
          shareIntentSourceProvider.overrideWithValue(source),
          noteApiProvider.overrideWithValue(NoteStationApi(noteApi)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: const MaterialApp(
            home: Scaffold(body: ShareIntentHost(child: SizedBox.shrink())),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('note-clip-share-entry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('note-clip-share-entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // 必须真的路由到笔记：发起了 Note/create（剪藏），**没有**发到 Chat
      expect(
        noteTransport.calls.any(
          (c) => c['api'] == 'SYNO.NoteStation.Note' && c['method'] == 'create',
        ),
        isTrue,
        reason: '剪藏分支要调用 Note/create',
      );
      expect(
        h.transport.calls.any(
          (c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'create',
        ),
        isFalse,
        reason: '剪藏不应再走 Chat 发送链路',
      );
    });
  });
}

class _FakeRecorder implements NoteAudioRecorder {
  bool started = false;
  bool stopped = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start(String path) async => started = true;

  @override
  Future<String?> stop() async {
    stopped = true;
    return '/tmp/file_42.3gp';
  }

  @override
  Future<void> cancel() async {}
}

/// 离线假分享源（同 `chat_share_intent_test.dart`）
class _FakeShareSource implements ShareIntentSource {
  _FakeShareSource(this.pending);

  ShareIntentData? pending;

  @override
  Stream<ShareIntentData> get incoming => const Stream.empty();

  @override
  Future<ShareIntentData?> takePending() async {
    final p = pending;
    pending = null;
    return p;
  }

  @override
  void dispose() {}
}
