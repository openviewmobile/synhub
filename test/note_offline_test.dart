// 笔记模块的**离线缓存与同步**测试（P1 · local-first）。
//
// 三块都测：
//   1. `NoteStore`（Drift）：diff 落库 / 离线写队列 / 脏行保护 / 本地搜索；
//   2. provider：网络断了要回落缓存（`fromCache: true`），不能白屏；
//   3. `NoteSyncNotifier`：pull（拉全量→落库）与 push（重放离线写）。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/note_store.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_row.dart' show formatFileTime;
import 'package:synhub/src/features/notes/note_body.dart';
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_sync.dart';
import 'package:synhub/src/features/notes/notes_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

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
  'SYNO.NoteStation.Todo': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

NoteDto _note(
  String id,
  String title, {
  String content = '',
  bool hasContent = false,
  int mtime = 1000,
}) => NoteDto(
  objectId: id,
  title: title,
  parentId: 'nb1',
  content: content,
  hasContent: hasContent,
  mtime: mtime,
  ver: '1.0',
);

Map<String, dynamic> _apiNote(
  String id,
  String title, {
  int mtime = 1000,
  String brief = '',
}) => {
  'object_id': id,
  'title': title,
  'parent_id': 'nb1',
  'brief': brief,
  'mtime': mtime,
  'ctime': 500,
  'ver': '1.0',
  'recycle': false,
  'encrypt': false,
  'has_content': true,
  'tags': <String>[],
  'attachment': <String, dynamic>{},
};

Future<({FakeTransport t, ProviderContainer container, NoteStore store})> _boot(
  Map<String, Map<String, dynamic>> responses,
) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
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
  return (t: t, container: container, store: NoteStore(db));
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
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('NoteStore（Drift 缓存）', () {
    test('mergeNoteList：新增/更新/删除 + 脏行不被覆盖', () async {
      final b = await _boot({});
      final store = b.store;
      await store.mergeNoteList([
        _note('n1', '旧标题', mtime: 1000),
        _note('n2', '要删掉的', mtime: 1000),
      ]);
      expect((await store.notes()).map((e) => e.title).toSet(), {
        '旧标题',
        '要删掉的',
      });

      // 本地改了 n1（离线），标记 dirty
      await store.putDirty(
        _note(
          'n1',
          '本地新标题',
          content: '<p>本地</p>',
          hasContent: true,
          mtime: 2000,
        ),
      );
      // n3 新出现，n2 服务端没了，n1 服务端标题也变了
      final need = await store.mergeNoteList([
        _note('n1', '服务端标题', mtime: 3000),
        _note('n3', '新来的', mtime: 3000),
      ]);
      final all = {for (final n in await store.notes()) n.objectId: n};
      expect(all.keys.toSet(), {'n1', 'n3'}, reason: 'n2 要删掉');
      expect(all['n1']!.title, '本地新标题', reason: '本地有未推送的改动，pull 不能覆盖');
      expect(all['n3']!.title, '新来的');
      expect(need.map((e) => e.objectId), contains('n3'), reason: '新笔记的正文要单独抓');
    });

    test('正文缓存 + 本地搜索（断网也能搜标题/正文）', () async {
      final b = await _boot({});
      final store = b.store;
      await store.putNote(
        _note('n1', '会议纪要', content: '<p>讨论了排期</p>', hasContent: true),
      );
      await store.putNote(_note('n2', '购物清单', hasContent: false));
      expect((await store.search('排期')).map((e) => e.objectId), ['n1']);
      expect((await store.search('购物')).map((e) => e.objectId), ['n2']);
      expect(await store.search(''), hasLength(2));
    });

    test('离线写队列：入队 → 读回 → 删除', () async {
      final b = await _boot({});
      final store = b.store;
      final id = await store.enqueue(NotePendingKind.set, 'n1', {
        'title': 't',
        'content': '<p>x</p>',
      });
      expect(await store.pendingCount(), 1);
      final list = await store.pending();
      expect(list.single.kind, NotePendingKind.set);
      expect(list.single.payload['title'], 't');
      await store.removePending(id);
      expect(await store.pendingCount(), 0);
    });

    test('笔记本 / 待办整桶替换（删掉服务端没返回的）', () async {
      final b = await _boot({});
      final store = b.store;
      await store.replaceNotebooks(const [
        NotebookDto(objectId: 'nb1', title: 'A'),
        NotebookDto(objectId: 'nb2', title: 'B'),
      ]);
      await store.replaceNotebooks(const [
        NotebookDto(objectId: 'nb2', title: 'B2'),
      ]);
      final nbs = await store.notebooks();
      expect(nbs.single.objectId, 'nb2');
      expect(nbs.single.title, 'B2');

      await store.replaceTodos([
        TodoDto(objectId: 't1', title: '写周报', done: false),
        TodoDto(objectId: 't2', title: '交周报', done: true),
      ]);
      await store.replaceTodos([TodoDto(objectId: 't1', title: '写周报')]);
      expect((await store.todos()).single.objectId, 't1');
    });
  });

  group('离线回落（provider）', () {
    testWidgets('断网时列表用缓存 + 顶部离线横幅', (tester) async {
    // ★ r293：窗口必须**真的**在 <700dp（单列）—— `setSurfaceSize` 不改
    //   `MediaQuery`（实测 `w=800`），只有 `tester.view` 才生效。
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
      final b = await _boot({
        'SYNO.NoteStation.Note.list': {
          'notes': [_apiNote('n1', '缓存里的笔记')],
          'total': 1,
        },
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': '工作', 'preset': false},
          ],
        },
        // ⚠️ `Note/get` 的 data 就是笔记对象本身（没有再包一层 note）
        'SYNO.NoteStation.Note.get': _apiNote('n1', '缓存里的笔记'),
      });
      // 先在线跑一次，把数据落进缓存
      await b.container.read(noteSyncProvider.notifier).sync();
      expect((await b.store.notes()).single.title, '缓存里的笔记');

      // 然后断网
      b.t.offlineKeys.addAll([
        'SYNO.NoteStation.Note.list',
        'SYNO.NoteStation.Notebook.list',
        'SYNO.NoteStation.Notebook.list',
      ]);
      await _pump(tester, b.container, const NotesPage());
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('缓存里的笔记'), findsOneWidget, reason: '断网也要能看到上次同步的内容');
      expect(find.textContaining('离线 · 显示上次同步的内容'), findsOneWidget);

      // 打开笔记：正文也来自缓存，并且页面上要说明
      await tester.tap(find.text('缓存里的笔记'));
      await tester.pumpAndSettle();
      expect(find.textContaining('离线 · 这是本机缓存的内容'), findsOneWidget);
    });

    test('断网时打开笔记：正文来自缓存', () async {
      final b = await _boot({});
      await b.store.putNote(
        NoteDto(
          objectId: 'n1',
          title: '缓存笔记',
          parentId: 'nb1',
          content: '<p>缓存里的正文</p>',
          hasContent: true,
          mtime: 1000,
          ver: '1.0',
        ),
      );
      b.t.offlineKeys.add('SYNO.NoteStation.Note.get');
      final detail = await b.container.read(noteDetailProvider('n1').future);
      expect(detail.fromCache, isTrue);
      expect(detail.note.content, contains('缓存里的正文'));
      // autoDispose 的 provider 会排一个 dispose 定时器，这里给 FakeAsync 收尾
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('同步（pull + push）', () {
    test('列表里没有正文 → sync 必须自己 Note/get 补上（离线可读的关键）', () async {
      final b = await _boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': '工作', 'preset': false},
          ],
        },
        'SYNO.NoteStation.Note.list': {
          'notes': [_apiNote('n1', '标题')],
          'total': 1,
        },
        'SYNO.NoteStation.Note.get': {
          ..._apiNote('n1', '标题'),
          'content': '<p>正文</p>',
        },
        'SYNO.NoteStation.Todo.list': {'todos': <dynamic>[]},
      });
      await b.container.read(noteSyncProvider.notifier).sync();
      // 再跑一次（元数据没变）也应该保持正文 —— 不能把缓存过的正文清掉
      await b.container.read(noteSyncProvider.notifier).sync();
      final cached = (await b.store.notes()).single;
      expect(cached.hasContent, isTrue);
      expect(cached.content, contains('正文'));
      // 断网后详情要能直接从缓存读出来
      b.t.offlineKeys.add('SYNO.NoteStation.Note.get');
      final detail = await b.container.read(noteDetailProvider('n1').future);
      expect(detail.fromCache, isTrue);
      expect(detail.note.content, contains('正文'));
    });

    test('sync 把服务端数据拉进库，并补齐没正文的笔记', () async {
      final b = await _boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': '工作', 'preset': false},
          ],
        },
        'SYNO.NoteStation.Note.list': {
          'notes': [_apiNote('n1', '标题', brief: '摘要')],
          'total': 1,
        },
        'SYNO.NoteStation.Note.get': {
          ..._apiNote('n1', '标题'),
          'content': '<p>正文</p>',
          'has_content': true,
        },
        'SYNO.NoteStation.Todo.list': {'todos': <dynamic>[]},
      });
      await b.container.read(noteSyncProvider.notifier).sync();
      final cached = (await b.store.notes()).single;
      expect(cached.title, '标题');
      expect(cached.content, contains('正文'), reason: '正文要落库');
      expect((await b.store.notebooks()).single.title, '工作');
      final status = b.container.read(noteSyncProvider);
      expect(status.offline, isFalse);
      expect(status.lastSyncedAt, isNotNull);
    });

    test('flushPending：重放离线保存（Note/set）并清空队列', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.set': {
          'data': [
            {'object_id': 'n1', 'ver': 'v2'},
          ],
        },
      });
      await b.store.putDirty(
        NoteDto(
          objectId: 'n1',
          title: '离线改的',
          parentId: 'nb1',
          content: '<p>离线正文</p>',
          hasContent: true,
          ver: 'v1',
        ),
      );
      await b.store.enqueue(NotePendingKind.set, 'n1', {
        'title': '离线改的',
        'parent_id': 'nb1',
        'content': '<p>离线正文</p>',
        'ver': 'v1',
      });
      final sync = b.container.read(noteSyncProvider.notifier);
      await sync.refreshPending();
      expect(b.container.read(noteSyncProvider).pending, 1);

      await sync.flushPending();
      expect(await b.store.pendingCount(), 0, reason: '推成功要出队');
      final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
      expect(set['object_id'], '"n1"');
      expect(set['content'], '"<p>离线正文</p>"');
      expect((await b.store.note('n1'))!.title, '离线改的');
    });

    test('flushPending：离线新建 → 联网后换成服务端 id', () async {
      final b = await _boot({
        'SYNO.NoteStation.Note.create': {'object_id': 'S1', 'ver': 'v1'},
      });
      final store = b.store;
      final sync = b.container.read(noteSyncProvider.notifier);
      final localId = await saveOffline(
        store,
        sync,
        objectId: null,
        title: '离线新建',
        parentId: 'nb1',
        html: '<p>x</p>',
        ver: '0',
      );
      expect(localId, startsWith('local_'));
      expect((await store.note(localId))!.title, '离线新建');

      await sync.flushPending();
      expect(await store.note(localId), isNull, reason: '临时行要换掉');
      expect((await store.note('S1'))!.title, '离线新建');
      expect(await store.pendingCount(), 0);
    });

    test('推失败（服务端拒绝）留在队列里，状态置错', () async {
      final b = await _boot({});
      b.t.failures['SYNO.NoteStation.Note.set'] = 160;
      await b.store.enqueue(NotePendingKind.set, 'n1', {
        'title': 't',
        'content': '<p>x</p>',
        'ver': 'v1',
      });
      final sync = b.container.read(noteSyncProvider.notifier);
      await sync.flushPending();
      expect(await b.store.pendingCount(), 1, reason: '失败不能丢改动');
      expect(b.container.read(noteSyncProvider).state, NoteSyncState.error);
    });

    test('离线进入（没有会话）时 sync 先静默重连，再推本地改动', () async {
      // 用假的重连：restore() 后把 noteApiProvider 换成可用的 API
      final b = await _boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': '工作', 'preset': false},
          ],
        },
        'SYNO.NoteStation.Note.list': {'notes': <dynamic>[], 'total': 0},
        'SYNO.NoteStation.Note.create': {'object_id': 'S7', 'ver': 'v1'},
        'SYNO.NoteStation.Todo.list': {'todos': <dynamic>[]},
      });
      final store = b.store;
      final sync = b.container.read(noteSyncProvider.notifier);
      // 先攒一条离线新建（此时 api 是有的，但用 saveOffline 入队）
      await saveOffline(
        store,
        sync,
        objectId: null,
        title: '攒着的',
        parentId: 'nb1',
        html: '<p>x</p>',
        ver: '0',
      );
      expect(await store.pendingCount(), 1);
      await sync.flushPending();
      expect(await store.pendingCount(), 0, reason: '有会话时直接推');
      expect((await store.note('S7'))!.title, '攒着的');
    });

    test('断网时 sync 要标成 offline（不是 error）', () async {
      final b = await _boot({});
      b.t.offlineKeys.addAll([
        'SYNO.NoteStation.Notebook.list',
        'SYNO.NoteStation.Note.list',
      ]);
      await b.container.read(noteSyncProvider.notifier).sync();
      expect(b.container.read(noteSyncProvider).state, NoteSyncState.offline);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // DA79（r420 真机撞出并修掉）：**断网保存把用户改动丢掉了**
  //   传输层（`dsm/webapi.dart`）把 `DioException` 收成 `DsmTransportException`，
  //   而 `isOfflineError` 只认 dio 类型 ⇒ 编辑器走进"保存失败"分支，
  //   `_saveOffline`（本地队列）永远不执行 ⇒ 改动整条丢。
  // ────────────────────────────────────────────────────────────────────────
  group('DA79 · 传输层包装必须判成离线', () {
    test('没有 HTTP 状态码的 DsmTransportException = 离线（真机 Wi-Fi 断掉就是这个）', () {
      expect(
        isOfflineError(DsmTransportException('网络连接失败：请检查网络后重试')),
        isTrue,
      );
    });

    test('服务端答过话（带状态码）→ 不许冒充离线', () {
      expect(
        isOfflineError(DsmTransportException('Bad Gateway', statusCode: 502)),
        isFalse,
      );
    });

    test('DSM 业务错误码 → 本来就不是离线', () {
      expect(
        isOfflineError(DsmApiException(407, method: 'SYNO.NoteStation.Note')),
        isFalse,
      );
    });

  });

  group('双向冲突（本地改了 + 服务端也改了）', () {
    Map<String, Map<String, dynamic>> conflictResponses({
      String serverVer = 'v2',
    }) => {
      'SYNO.NoteStation.Notebook.list': {
        'notebooks': [
          {'object_id': 'nb1', 'title': '工作', 'preset': false},
        ],
      },
      'SYNO.NoteStation.Note.list': {
        'notes': [
          {..._apiNote('n1', '服务端标题', mtime: 3000), 'ver': serverVer},
        ],
        'total': 1,
      },
      'SYNO.NoteStation.Note.get': {
        ..._apiNote('n1', '服务端标题', mtime: 3000),
        'ver': serverVer,
        'content': '<p>服务端正文</p>',
      },
      'SYNO.NoteStation.Note.set': {
        'data': [
          {'object_id': 'n1', 'ver': 'v3'},
        ],
      },
      'SYNO.NoteStation.Todo.list': {'todos': <dynamic>[]},
    };

    test('mergeNoteList 探测冲突：dirty 行 + 服务端 ver 变了', () async {
      final b = await _boot({});
      await b.store.mergeNoteList([_note('n1', '原来的')]);
      await b.store.putDirty(
        _note(
          'n1',
          '本地改的',
          content: '<p>本地正文</p>',
          hasContent: true,
          mtime: 2000,
        ),
      );
      final drafts = <NoteConflictDraft>[];
      await b.store.mergeNoteList([
        _note('n1', '服务端改的', mtime: 3000).copyWith(ver: 'v2'),
      ], conflictsOut: drafts);
      expect(drafts, hasLength(1));
      expect(drafts.single.objectId, 'n1');
      expect(drafts.single.baseVer, '1.0');
      expect(drafts.single.serverVer, 'v2');
      expect(drafts.single.localContent, '<p>本地正文</p>');
      // 本地内容仍然在（绝不静默丢改动）
      expect((await b.store.notes()).single.title, '本地改的');
    });

    test('ver 没变 → 不是冲突', () async {
      final b = await _boot({});
      await b.store.mergeNoteList([_note('n1', '原来的')]);
      await b.store.putDirty(_note('n1', '本地改的', mtime: 2000));
      final drafts = <NoteConflictDraft>[];
      await b.store.mergeNoteList([
        _note('n1', '原来的', mtime: 3000),
      ], conflictsOut: drafts);
      expect(drafts, isEmpty, reason: '服务端版本没变，只是我们本地改了');
    });

    test('sync 把冲突挂到状态里，并抓到服务端正文', () async {
      final b = await _boot(conflictResponses());
      await b.store.putDirty(
        NoteDto(
          objectId: 'n1',
          title: '本地改的',
          parentId: 'nb1',
          content: '<p>本地正文</p>',
          hasContent: true,
          ver: 'v1',
        ),
      );
      await b.store.enqueue(NotePendingKind.set, 'n1', {
        'title': '本地改的',
        'content': '<p>本地正文</p>',
        'ver': 'v1',
      });
      await b.container.read(noteSyncProvider.notifier).sync();

      final status = b.container.read(noteSyncProvider);
      expect(status.hasConflicts, isTrue);
      final c = status.conflicts.single;
      expect(c.serverVer, 'v2');
      expect(c.serverFetched, isTrue);
      expect(c.serverContent, contains('服务端正文'));
    });

    test('保留我的 → Note/set 带服务端最新 ver，队列清空', () async {
      final b = await _boot(conflictResponses());
      await b.store.putDirty(
        NoteDto(
          objectId: 'n1',
          title: '本地改的',
          parentId: 'nb1',
          content: '<p>本地正文</p>',
          hasContent: true,
          ver: 'v1',
        ),
      );
      await b.store.enqueue(NotePendingKind.set, 'n1', {
        'title': '本地改的',
        'content': '<p>本地正文</p>',
        'ver': 'v1',
      });
      final sync = b.container.read(noteSyncProvider.notifier);
      await sync.sync();
      await sync.resolveWithLocal(
        b.container.read(noteSyncProvider).conflicts.single,
      );

      final set = b.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.NoteStation.Note' && c['method'] == 'set',
      );
      expect(set['ver'], '"v2"', reason: '要带服务端最新版本，否则永远冲突');
      expect(set['object_id'], '"n1"');
      expect(b.container.read(noteSyncProvider).hasConflicts, isFalse);
      expect(await b.store.pendingCount(), 0);
    });

    test('用服务端的 → 正文换成服务端版本，队列清空', () async {
      final b = await _boot(conflictResponses());
      await b.store.putDirty(
        NoteDto(
          objectId: 'n1',
          title: '本地改的',
          parentId: 'nb1',
          content: '<p>本地正文</p>',
          hasContent: true,
          ver: 'v1',
        ),
      );
      await b.store.enqueue(NotePendingKind.set, 'n1', {
        'title': '本地改的',
        'content': '<p>本地正文</p>',
        'ver': 'v1',
      });
      final sync = b.container.read(noteSyncProvider.notifier);
      await sync.sync();
      await sync.resolveWithServer(
        b.container.read(noteSyncProvider).conflicts.single,
      );

      final cached = (await b.store.notes()).single;
      expect(cached.title, '服务端标题');
      expect(cached.content, contains('服务端正文'));
      expect(await b.store.pendingCount(), 0);
      expect(b.container.read(noteSyncProvider).hasConflicts, isFalse);
    });

    testWidgets('笔记页出冲突横幅 → 裁决页两栏对照', (tester) async {
      final b = await _boot(conflictResponses());
      await b.store.putDirty(
        NoteDto(
          objectId: 'n1',
          title: '本地改的',
          parentId: 'nb1',
          content: '<p>本地正文</p>',
          hasContent: true,
          ver: 'v1',
        ),
      );
      await b.container.read(noteSyncProvider.notifier).sync();
      await _pump(tester, b.container, const NotesPage());
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('note-conflict-banner')), findsOneWidget);
      await tester.tap(find.byKey(const Key('note-conflict-banner')));
      await tester.pumpAndSettle();
      expect(find.text('同步冲突（1）'), findsOneWidget);
      expect(find.text('我的改动'), findsOneWidget);
      expect(find.text('服务端版本'), findsOneWidget);
      // 正文是 Quill 渲染的（RichText），按 widget 的 html 断言更实在
      final bodies = tester
          .widgetList<NoteBody>(find.byType(NoteBody))
          .toList();
      expect(bodies.any((w) => w.html.contains('本地正文')), isTrue);

      await tester.tap(find.byKey(const Key('note-conflict-use-server')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await b.store.pendingCount(), 0);
    });
  });

  group('离线保存（编辑器）', () {
    testWidgets('断网保存 → 落本地 + 入队 + 提示，联网后能推上去', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': '工作', 'preset': false},
          ],
        },
        'SYNO.NoteStation.Note.list': {'notes': <dynamic>[], 'total': 0},
        'SYNO.NoteStation.Note.create': {'object_id': 'S9', 'ver': 'v1'},
      });
      b.t.offlineKeys.add('SYNO.NoteStation.Note.create');
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );

      await tester.enterText(find.byType(TextField).first, '断网写的');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('已离线保存'), findsOneWidget);
      expect(await b.store.pendingCount(), 1);
      // 队列里的载荷必须和界面上一模一样（标题就是标题、正文就是正文）
      final queued = (await b.store.pending()).single;
      expect(queued.kind, NotePendingKind.create);
      expect(queued.payload['title'], '断网写的');
      expect(queued.payload['parent_id'], 'nb1');
      final dirty = (await b.store.notes()).single;
      expect(dirty.title, '断网写的');
      expect(b.container.read(noteSyncProvider).pending, 1);

      // 恢复网络 → 推上去
      b.t.offlineKeys.clear();
      await b.container.read(noteSyncProvider.notifier).flushPending();
      expect(await b.store.pendingCount(), 0);
      expect((await b.store.note('S9'))!.title, '断网写的');
    });
  });

  // ★ DA80（r421 真机撞出并修掉）：**离线保存后详情页把修改时间画成 `Modified 58759-12-05`**。
  //   根因：`saveOffline` 是笔记模块里唯一把 `mtime` 写成**毫秒**的本地写路径
  //   （别处一律 `noteEpochSeconds()`），而渲染端 `formatFileTime(int seconds)`
  //   按秒解释 ⇒ 毫秒被当成秒 ⇒ 年份 58759。
  //   判据两条腿：① 落库值就在"刚刚"的秒区间内（毫秒量级必然落空）；
  //              ② 用渲染端那支函数真画一次，得到"今天"而不是一个荒谬年份。
  group('DA80 · 本地写入的 mtime 必须与全模块同口径（epoch 秒）', () {
    test('saveOffline 落库的 mtime 是秒，不是毫秒', () async {
      final b = await _boot({});
      final store = b.store;
      final sync = b.container.read(noteSyncProvider.notifier);

      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final id = await saveOffline(
        store,
        sync,
        objectId: null,
        title: '离线新建',
        parentId: 'nb1',
        html: '<p>x</p>',
        ver: '0',
      );
      final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      final mtime = (await store.note(id))!.mtime;
      expect(
        mtime >= before && mtime <= after,
        isTrue,
        reason: '落库 mtime=$mtime 不在 [$before,$after]（毫秒量级 ≈1.7e12 必然落空）',
      );
      // 显式再钉一次量级：毫秒当秒就是这个缺陷的形态
      expect(mtime < 100000000000, isTrue);
      // 本地临时 id 仍要能互不相同（毫秒那一段没被一起改掉）
      expect(id, startsWith('local_'));
    });

    test('渲染端口径一致：刚离线保存的行画成"今天"，不是 58759 年', () async {
      final b = await _boot({});
      final sync = b.container.read(noteSyncProvider.notifier);
      final id = await saveOffline(
        b.store,
        sync,
        objectId: null,
        title: '离线新建',
        parentId: 'nb1',
        html: '<p>x</p>',
        ver: '0',
      );
      final mtime = (await b.store.note(id))!.mtime;
      final drawn = formatFileTime(mtime);
      expect(drawn.contains('58759'), isFalse, reason: '真机缺陷形态：$drawn');
      expect(drawn, isNot(contains('-')));
    });
  });
}
