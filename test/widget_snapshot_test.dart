// 小组件**数据映射纯函数**的单测（缺口 P66 相册 / N1 笔记）。
//
// 覆盖批次要求的三个离线用例族：
//   1. **"取最近 N 张 / 条"** —— 排序、去重、截断、稳定序；
//   2. **"未登录 / 未连接时的占位文案"** —— 顺序与文案都是行为契约；
//   3. **"空数据不崩"** —— 空列表、坏 JSON、版本不符、单条脏数据。
//
// 页面层不可测 Android 小组件（那是 launcher 进程里的 RemoteViews），
// 所以小组件"显示什么"这件事的**全部逻辑**都放在
// `lib/src/features/widgets/widget_snapshot.dart` 里，本文件直接调。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/widgets/widget_snapshot.dart';

void main() {
  group('recentWidgetPhotos（取最近 N 张）', () {
    test('按拍摄时间降序，只取前 N 张', () {
      final photos = [
        const WidgetPhotoEntry(id: '1', name: 'a.jpg', takenAt: 100),
        const WidgetPhotoEntry(id: '2', name: 'b.jpg', takenAt: 300),
        const WidgetPhotoEntry(id: '3', name: 'c.jpg', takenAt: 200),
        const WidgetPhotoEntry(id: '4', name: 'd.jpg', takenAt: 400),
        const WidgetPhotoEntry(id: '5', name: 'e.jpg', takenAt: 50),
      ];
      final got = recentWidgetPhotos(photos, limit: 3);
      expect(got.map((e) => e.id).toList(), ['4', '2', '3']);
    });

    test('时间相同时按 id 升序 —— 同一份输入永远同一份输出（不闪）', () {
      final a = recentWidgetPhotos([
        const WidgetPhotoEntry(id: 'b', name: 'b', takenAt: 7),
        const WidgetPhotoEntry(id: 'a', name: 'a', takenAt: 7),
        const WidgetPhotoEntry(id: 'c', name: 'c', takenAt: 7),
      ]);
      final b = recentWidgetPhotos([
        const WidgetPhotoEntry(id: 'c', name: 'c', takenAt: 7),
        const WidgetPhotoEntry(id: 'a', name: 'a', takenAt: 7),
        const WidgetPhotoEntry(id: 'b', name: 'b', takenAt: 7),
      ]);
      expect(a.map((e) => e.id).toList(), ['a', 'b', 'c']);
      expect(b.map((e) => e.id).toList(), ['a', 'b', 'c']);
    });

    test('按 id 去重 —— 分页合并后的重复条目只出现一次', () {
      final got = recentWidgetPhotos([
        const WidgetPhotoEntry(id: '1', name: 'first', takenAt: 100),
        const WidgetPhotoEntry(id: '1', name: 'dup', takenAt: 999),
        const WidgetPhotoEntry(id: '2', name: 'b', takenAt: 200),
      ]);
      expect(got.map((e) => e.id).toList(), ['2', '1']);
      // 先出现的条目胜出（不是时间更大的那条）
      expect(got.last.name, 'first');
    });

    test('id 为空的条目直接丢弃（点不开也存不了缩略图）', () {
      final got = recentWidgetPhotos([
        const WidgetPhotoEntry(id: '', name: 'no id', takenAt: 999),
        // 只含空白的 id 同样是脏值
        const WidgetPhotoEntry(id: '   ', name: 'blank id', takenAt: 998),
        const WidgetPhotoEntry(id: '1', name: 'ok', takenAt: 1),
      ]);
      expect(got.map((e) => e.id).toList(), ['1']);
    });

    test('limit <= 0 → 空列表（不是"全部"）', () {
      expect(
        recentWidgetPhotos([
          const WidgetPhotoEntry(id: '1', name: 'a'),
        ], limit: 0),
        isEmpty,
      );
      expect(
        recentWidgetPhotos([
          const WidgetPhotoEntry(id: '1', name: 'a'),
        ], limit: -3),
        isEmpty,
      );
    });

    test('空列表不崩', () {
      expect(recentWidgetPhotos(const []), isEmpty);
    });

    test('条数不足 limit 时原样返回，不补齐', () {
      final got = recentWidgetPhotos([
        const WidgetPhotoEntry(id: '1', name: 'a', takenAt: 1),
      ], limit: 4);
      expect(got, hasLength(1));
    });
  });

  group('recentWidgetNotes（取最近 N 条笔记）', () {
    test('按 mtime 降序 + 去重 + 截断', () {
      final got = recentWidgetNotes([
        const WidgetNoteEntry(id: 'n1', title: '一周前', mtime: 10),
        const WidgetNoteEntry(id: 'n2', title: '刚刚', mtime: 900),
        const WidgetNoteEntry(id: 'n3', title: '今天', mtime: 500),
        const WidgetNoteEntry(id: 'n2', title: '重复', mtime: 800),
      ], limit: 2);
      expect(got.map((e) => e.id).toList(), ['n2', 'n3']);
      expect(got.first.title, '刚刚');
    });

    test('空列表不崩', () {
      expect(recentWidgetNotes(const []), isEmpty);
    });
  });

  group('widgetPendingTodos（未完成待办）', () {
    test('滤掉已完成', () {
      final got = widgetPendingTodos([
        const WidgetTodoEntry(id: 't1', title: '要做', done: false),
        const WidgetTodoEntry(id: 't2', title: '做完了', done: true),
      ]);
      expect(got.map((e) => e.id).toList(), ['t1']);
    });

    test('有截止时间的在前，且按截止时间升序（最紧急在前）', () {
      final got = widgetPendingTodos([
        const WidgetTodoEntry(id: 'later', title: '晚', due: 2000),
        const WidgetTodoEntry(id: 'none', title: '没截止'),
        const WidgetTodoEntry(id: 'sooner', title: '早', due: 1000),
      ]);
      expect(got.map((e) => e.id).toList(), ['sooner', 'later', 'none']);
    });

    test('都没有截止时间时按 id 升序（稳定）', () {
      final got = widgetPendingTodos([
        const WidgetTodoEntry(id: 'z', title: 'z'),
        const WidgetTodoEntry(id: 'a', title: 'a'),
      ]);
      expect(got.map((e) => e.id).toList(), ['a', 'z']);
    });

    test('空列表 / 全已完成 不崩', () {
      expect(widgetPendingTodos(const []), isEmpty);
      expect(
        widgetPendingTodos([
          const WidgetTodoEntry(id: 't', title: 'x', done: true),
        ]),
        isEmpty,
      );
    });
  });

  group('占位策略（未登录 / 未连接 / 空数据）', () {
    test('没有快照 → 未登录（不是"连不上"）', () {
      expect(widgetPhotoPlaceholder(null), WidgetPlaceholder.notLoggedIn);
      expect(widgetNotePlaceholder(null), WidgetPlaceholder.notLoggedIn);
      expect(widgetTodoPlaceholder(null), WidgetPlaceholder.notLoggedIn);
    });

    test('未登录优先于未连接 —— 不能把用户骗去查网络', () {
      const s = WidgetSnapshot(loggedIn: false, connected: false);
      expect(widgetPhotoPlaceholder(s), WidgetPlaceholder.notLoggedIn);
      expect(widgetNotePlaceholder(s), WidgetPlaceholder.notLoggedIn);
      expect(widgetTodoPlaceholder(s), WidgetPlaceholder.notLoggedIn);
    });

    test('已登录但未连接 → 未连接', () {
      const s = WidgetSnapshot(loggedIn: true, connected: false);
      expect(widgetPhotoPlaceholder(s), WidgetPlaceholder.notConnected);
      expect(widgetNotePlaceholder(s), WidgetPlaceholder.notConnected);
      expect(widgetTodoPlaceholder(s), WidgetPlaceholder.notConnected);
    });

    test('连上了但相册为空 → noPhotos', () {
      const s = WidgetSnapshot(loggedIn: true, connected: true);
      expect(widgetPhotoPlaceholder(s), WidgetPlaceholder.noPhotos);
      expect(widgetNotePlaceholder(s), WidgetPlaceholder.noNotes);
      expect(widgetTodoPlaceholder(s), WidgetPlaceholder.noTodos);
    });

    test('有数据 → null（表示"能画内容，不要占位"）', () {
      const s = WidgetSnapshot(
        loggedIn: true,
        connected: true,
        photos: [WidgetPhotoEntry(id: '1', name: 'a')],
        notes: [WidgetNoteEntry(id: 'n', title: 't')],
        todos: [WidgetTodoEntry(id: 't', title: 'x')],
      );
      expect(widgetPhotoPlaceholder(s), isNull);
      expect(widgetNotePlaceholder(s), isNull);
      expect(widgetTodoPlaceholder(s), isNull);
    });

    test('三类的"空数据"占位文案互不相同、且都不是空串', () {
      final photos = widgetPlaceholderText(
        WidgetPlaceholder.noPhotos,
        WidgetKind.photos,
      );
      final notes = widgetPlaceholderText(
        WidgetPlaceholder.noNotes,
        WidgetKind.notes,
      );
      final todos = widgetPlaceholderText(
        WidgetPlaceholder.noTodos,
        WidgetKind.todos,
      );
      for (final t in [photos, notes, todos]) {
        expect(t.trim(), isNotEmpty);
      }
      expect({photos, notes, todos}, hasLength(3));
    });

    test('未登录 / 未连接的文案按类别给出、且都不是空串 —— 绝不空白', () {
      for (final kind in WidgetKind.values) {
        for (final p in [
          WidgetPlaceholder.notLoggedIn,
          WidgetPlaceholder.notConnected,
        ]) {
          final text = widgetPlaceholderText(p, kind);
          expect(text.trim(), isNotEmpty, reason: '$p/$kind 必须是明确的人话');
        }
      }
    });

    test('未登录与未连接的文案不同（两种问题要说清是哪种）', () {
      final notLoggedIn = widgetPlaceholderText(
        WidgetPlaceholder.notLoggedIn,
        WidgetKind.photos,
      );
      final notConnected = widgetPlaceholderText(
        WidgetPlaceholder.notConnected,
        WidgetKind.photos,
      );
      expect(notLoggedIn, isNot(notConnected));
    });

    test('标题 / 新建笔记文案非空', () {
      for (final kind in WidgetKind.values) {
        expect(widgetTitleText(kind).trim(), isNotEmpty);
      }
      expect(widgetNewNoteText().trim(), isNotEmpty);
    });
  });

  group('JSON 编解码（跨进程契约）', () {
    test('往返一致', () {
      final snapshot = WidgetSnapshot(
        loggedIn: true,
        connected: true,
        updatedAt: 1700000000000,
        photos: const [
          WidgetPhotoEntry(
            id: '1',
            name: 'IMG_0001.JPG',
            takenAt: 1699999999,
            thumbPath: '/data/x/widget_thumbs/1.jpg',
            isVideo: true,
          ),
        ],
        notes: const [
          WidgetNoteEntry(id: 'n1', title: '购物清单', mtime: 5, encrypted: true),
        ],
        todos: const [
          WidgetTodoEntry(id: 't1', title: '买菜', noteId: 'n1', due: 42),
        ],
      );
      final back = decodeWidgetSnapshot(encodeWidgetSnapshot(snapshot));
      expect(back, isNotNull);
      expect(back!.loggedIn, isTrue);
      expect(back.updatedAt, 1700000000000);
      expect(back.photos.single.id, '1');
      expect(back.photos.single.thumbPath, '/data/x/widget_thumbs/1.jpg');
      expect(back.photos.single.isVideo, isTrue);
      expect(back.notes.single.encrypted, isTrue);
      expect(back.todos.single.noteId, 'n1');
      expect(back.todos.single.due, 42);
    });

    test('空快照往返不崩（0 张 / 0 条）', () {
      final back = decodeWidgetSnapshot(
        encodeWidgetSnapshot(const WidgetSnapshot()),
      );
      expect(back, isNotNull);
      expect(back!.photos, isEmpty);
      expect(back.notes, isEmpty);
      expect(back.todos, isEmpty);
      expect(widgetPhotoPlaceholder(back), WidgetPlaceholder.notLoggedIn);
    });

    test('空串 / null / 半截 JSON / 非对象 → null（绝不抛）', () {
      expect(decodeWidgetSnapshot(null), isNull);
      expect(decodeWidgetSnapshot(''), isNull);
      expect(decodeWidgetSnapshot('   '), isNull);
      expect(decodeWidgetSnapshot('{"v":1,'), isNull);
      expect(decodeWidgetSnapshot('[1,2,3]'), isNull);
      expect(decodeWidgetSnapshot('"just a string"'), isNull);
      expect(decodeWidgetSnapshot('null'), isNull);
    });

    test('版本号不匹配 → 整份丢弃（宁可不显示，也不显示错字段）', () {
      expect(decodeWidgetSnapshot('{"v":99,"loggedIn":true}'), isNull);
      expect(decodeWidgetSnapshot('{"loggedIn":true}'), isNull);
    });

    test('缺键取默认值，不是崩', () {
      final back = decodeWidgetSnapshot('{"v":1}');
      expect(back, isNotNull);
      expect(back!.loggedIn, isFalse);
      expect(back.connected, isFalse);
      expect(back.photos, isEmpty);
    });

    test('类型不对：photos 不是数组 → 当空数组', () {
      final back = decodeWidgetSnapshot(
        '{"v":1,"loggedIn":true,"connected":true,"photos":"nope"}',
      );
      expect(back, isNotNull);
      expect(back!.photos, isEmpty);
      expect(widgetPhotoPlaceholder(back), WidgetPlaceholder.noPhotos);
    });

    test('单条脏数据被丢弃，其余条目照常', () {
      final back = decodeWidgetSnapshot(
        '{"v":1,"loggedIn":true,"connected":true,'
        '"photos":[{"id":"ok","name":"a","takenAt":1}, 7, "bad", '
        '{"id":"ok2","name":"b","takenAt":2}]}',
      );
      expect(back, isNotNull);
      expect(back!.photos.map((e) => e.id).toList(), ['ok', 'ok2']);
    });
  });

  group('点击落点解析（parseWidgetTarget）', () {
    test('固定落点', () {
      expect(
        parseWidgetTarget('photos'),
        const WidgetTarget(WidgetTargetKind.photos),
      );
      expect(
        parseWidgetTarget('notes'),
        const WidgetTarget(WidgetTargetKind.notes),
      );
      expect(
        parseWidgetTarget('note_new'),
        const WidgetTarget(WidgetTargetKind.newNote),
      );
    });

    test('带 id 的落点', () {
      expect(
        parseWidgetTarget('photo:12345'),
        const WidgetTarget(WidgetTargetKind.photo, '12345'),
      );
      expect(
        parseWidgetTarget('note:n-abc'),
        const WidgetTarget(WidgetTargetKind.note, 'n-abc'),
      );
      expect(
        parseWidgetTarget('todo:n-abc'),
        const WidgetTarget(WidgetTargetKind.todo, 'n-abc'),
      );
    });

    test('编码/解析往返一致', () {
      for (final t in const [
        WidgetTarget(WidgetTargetKind.photos),
        WidgetTarget(WidgetTargetKind.notes),
        WidgetTarget(WidgetTargetKind.newNote),
        WidgetTarget(WidgetTargetKind.photo, 'p1'),
        WidgetTarget(WidgetTargetKind.note, 'n1'),
        WidgetTarget(WidgetTargetKind.todo, 'n9'),
      ]) {
        expect(parseWidgetTarget(t.encode()), t);
      }
    });

    test('坏 extra 一律 null，绝不崩（不认识就忽略）', () {
      expect(parseWidgetTarget(null), isNull);
      expect(parseWidgetTarget(''), isNull);
      expect(parseWidgetTarget('   '), isNull);
      expect(parseWidgetTarget('garbage'), isNull);
      expect(parseWidgetTarget('photo:'), isNull);
      expect(parseWidgetTarget('photo:   '), isNull);
      expect(parseWidgetTarget(':123'), isNull);
      expect(parseWidgetTarget('unknown:123'), isNull);
      expect(parseWidgetTarget('https://example.com'), isNull);
    });
  });
  _n1NotebookWidgetTests();
  _n1NotebookIsNotesListTests();
  _n1QuickstartActionBarTests();
}

// ★★★ N1（第 107 轮）：笔记本小组件 —— 官方 `NotebookAppWidgetProvider`
// + `NotebookListAppWidgetAdapter`（DSnote APK dex 取证）。
void _n1NotebookWidgetTests() {
  group('N1. 笔记本小组件（官方 NotebookAppWidgetProvider 对应物）', () {
    WidgetNotebookEntry b(String id, {String name = '', int mtime = 0}) =>
        WidgetNotebookEntry(id: id, name: name, mtime: mtime);

    test('★ 排序：mtime 降序、同时间按 id 升序（稳定，不闪）', () {
      final out = widgetNotebooks([
        b('c', mtime: 100),
        b('a', mtime: 300),
        b('b', mtime: 100),
      ]);
      expect(out.map((e) => e.id).toList(), ['a', 'b', 'c']);
    });

    test('★ 去重 + 空 id 丢弃（服务端可能回 " " 这种脏值）', () {
      final out = widgetNotebooks([b('x'), b('x'), b(''), b('   ')]);
      expect(out, hasLength(1));
      expect(out.single.id, 'x');
    });

    test('★ limit<=0 ⇒ 空；超出上限截断', () {
      expect(widgetNotebooks([b('a')], limit: 0), isEmpty);
      expect(widgetNotebooks(List.generate(9, (i) => b('n$i'))), hasLength(4));
    });

    test('★★ 占位顺序：未登录 > 未连接 > 没有笔记本', () {
      expect(widgetNotebookPlaceholder(null), WidgetPlaceholder.notLoggedIn);
      expect(
        widgetNotebookPlaceholder(const WidgetSnapshot(loggedIn: false)),
        WidgetPlaceholder.notLoggedIn,
      );
      expect(
        widgetNotebookPlaceholder(const WidgetSnapshot(loggedIn: true)),
        WidgetPlaceholder.notConnected,
      );
      expect(
        widgetNotebookPlaceholder(
          const WidgetSnapshot(loggedIn: true, connected: true),
        ),
        WidgetPlaceholder.noNotebooks,
      );
      expect(
        widgetNotebookPlaceholder(
          WidgetSnapshot(loggedIn: true, connected: true, notebooks: [b('a')]),
        ),
        isNull,
      );
    });

    test('★ 笔记本占位文案是非空人话', () {
      expect(
        widgetPlaceholderText(
          WidgetPlaceholder.noNotebooks,
          WidgetKind.notebooks,
        ).trim(),
        isNotEmpty,
      );
      expect(widgetTitleText(WidgetKind.notebooks).trim(), isNotEmpty);
    });

    test('★★ JSON 往返带上 notebooks（跨进程契约）', () {
      final snap = WidgetSnapshot(
        loggedIn: true,
        connected: true,
        notebooks: [
          const WidgetNotebookEntry(id: 'b1', name: '工作', count: 3, mtime: 9),
        ],
      );
      final back = decodeWidgetSnapshot(encodeWidgetSnapshot(snap));
      expect(back, isNotNull);
      expect(back!.notebooks, hasLength(1));
      expect(back.notebooks.single.id, 'b1');
      expect(back.notebooks.single.name, '工作');
      expect(back.notebooks.single.count, 3);
    });

    test('★ 旧快照（没有 notebooks 键）解析成空列表，不抛', () {
      const legacy =
          '{"v":1,"loggedIn":true,"connected":true,"photos":[],"notes":[],'
          '"todos":[],"updatedAt":1}';
      final back = decodeWidgetSnapshot(legacy);
      expect(back, isNotNull);
      expect(back!.notebooks, isEmpty);
      expect(widgetNotebookPlaceholder(back), WidgetPlaceholder.noNotebooks);
    });

    test('★ 点击落点 notebook:<id> 可编码可解析（坏值回 null）', () {
      const t = WidgetTarget(WidgetTargetKind.notebook, 'b1');
      expect(t.encode(), 'notebook:b1');
      expect(parseWidgetTarget('notebook:b1'), t);
      expect(parseWidgetTarget('notebook:'), isNull);
      expect(parseWidgetTarget('nope:b1'), isNull);
    });
  });
}

// ★★★ 第 109 轮**语义更正**：官方 `NotebookAppWidgetProvider`
// （label = `widget_notebook` = "List of notes"）列的是**选中笔记本里的笔记**，
// 不是笔记本列表；配置页 `NotebookListAppWidgetActivity` 取证。
void _n1NotebookIsNotesListTests() {
  group('109. Notebook widget 的真实语义 = 选中本里的笔记', () {
    WidgetNoteEntry n(String id, {String book = '', int mtime = 0}) =>
        WidgetNoteEntry(id: id, title: 't$id', mtime: mtime, notebookId: book);

    test('★ 按笔记本过滤：只留该本、顺序沿用 recentWidgetNotes', () {
      final out = widgetNotesInNotebook([
        n('a', book: 'b1', mtime: 1),
        n('b', book: 'b2', mtime: 9),
        n('c', book: 'b1', mtime: 5),
      ], notebookId: 'b1');
      expect(out.map((e) => e.id).toList(), ['c', 'a']);
    });

    test('★ notebookId 为空 = 全部笔记（配置页选"全部笔记"）', () {
      final out = widgetNotesInNotebook([
        n('a', book: 'b1'),
        n('b', book: 'b2'),
      ], notebookId: '');
      expect(out, hasLength(2));
    });

    test('★ 选了空笔记本 ⇒ 空列表（要么显示"还没有笔记"，不显示别的本的）', () {
      final out = widgetNotesInNotebook([n('a', book: 'b1')], notebookId: 'b9');
      expect(out, isEmpty);
    });

    test('★ notebookId/notebookName 往返进 JSON（跨进程契约）', () {
      final snap = WidgetSnapshot(
        loggedIn: true,
        connected: true,
        notes: [
          const WidgetNoteEntry(
            id: 'n1',
            title: 'x',
            notebookId: 'b7',
            notebookName: '工作',
          ),
        ],
      );
      final back = decodeWidgetSnapshot(encodeWidgetSnapshot(snap))!;
      expect(back.notes.single.notebookId, 'b7');
      expect(back.notes.single.notebookName, '工作');
    });

    test('★ 旧快照（没有 notebookId）⇒ 空串，不抛', () {
      const legacy =
          '{"v":1,"loggedIn":true,"connected":true,"photos":[],'
          '"notes":[{"id":"n1","title":"x","mtime":1,"encrypted":false}],'
          '"todos":[],"updatedAt":1}';
      final back = decodeWidgetSnapshot(legacy)!;
      expect(back.notes.single.notebookId, '');
      expect(widgetNotesInNotebook(back.notes, notebookId: 'b1'), isEmpty);
      expect(widgetNotesInNotebook(back.notes, notebookId: ''), hasLength(1));
    });
  });
}

// ★★★ N1（第 110 轮）：官方 `ShortcutAppWidgetProvider`（"Quickstart"）动作栏的
// 6 个落点。官方布局 `res/layout/appwidget_shortcut.xml` 的按钮 id：
// `app` / `new_camera` / `new_audio` / `new_att` / `new_plain` / `todos`。
void _n1QuickstartActionBarTests() {
  group('110. Quickstart 动作栏落点（官方 appwidget_shortcut）', () {
    test('★ 5 个动作各编一个稳定串（与 Kotlin 侧逐字一致）', () {
      expect(
        const WidgetTarget(WidgetTargetKind.newCamera).encode(),
        'note_camera',
      );
      expect(
        const WidgetTarget(WidgetTargetKind.newAudio).encode(),
        'note_audio',
      );
      expect(
        const WidgetTarget(WidgetTargetKind.newAttachment).encode(),
        'note_att',
      );
      expect(const WidgetTarget(WidgetTargetKind.newNote).encode(), 'note_new');
      expect(
        const WidgetTarget(WidgetTargetKind.newTodo).encode(),
        'todo_list',
      );
      // logo 格复用已有的 notes 落点（只打开 App）
      expect(const WidgetTarget(WidgetTargetKind.notes).encode(), 'notes');
    });

    test('★ 全部可解析回原 target（Kotlin PendingIntent → Dart 路由）', () {
      for (final t in const [
        WidgetTarget(WidgetTargetKind.newCamera),
        WidgetTarget(WidgetTargetKind.newAudio),
        WidgetTarget(WidgetTargetKind.newAttachment),
        WidgetTarget(WidgetTargetKind.newNote),
        WidgetTarget(WidgetTargetKind.newTodo),
      ]) {
        expect(parseWidgetTarget(t.encode()), t, reason: t.encode());
      }
    });

    test('★ 坏串仍然回 null（不认识的 extra 绝不崩 App）', () {
      for (final bad in ['note_cam', 'note_audio2', 'todos_list', '', '  ']) {
        expect(parseWidgetTarget(bad), isNull, reason: bad);
      }
    });
  });
}
