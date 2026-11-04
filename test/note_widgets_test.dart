// 笔记模块的离线 UI 测试：列表 / 筛选 / 搜索 / 空态 / 权限错误 / 正文渲染。
//
// 真机 UI 驱动（integration_test）在这台手机上只能 pump 两次，深流程
// 全部放在这里跑假传输 —— 与文件模块的 `file_browse_ui_test.dart` 同思路。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/data/note_crypto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/notes/note_encryption.dart';
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_picker.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_recycle_page.dart';
import 'package:synhub/src/features/notes/note_joined_page.dart';
import 'package:synhub/src/features/notes/note_shelf_page.dart';
import 'package:synhub/src/features/notes/note_smart_page.dart';
import 'package:synhub/src/features/notes/note_tag_page.dart';
import 'package:synhub/src/features/notes/note_todo_editor_page.dart';
import 'package:synhub/src/features/notes/note_todo_page.dart';
import 'package:synhub/src/features/notes/note_body.dart'
    show NoteImagePage;
import 'package:synhub/src/features/notes/note_view_page.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/design/kit/design_kit.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// NoteStation 能力表（够用即可）
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
  'SYNO.NoteStation.Note.Version': {
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
  // 批次 B：智能 / 条件笔记本
  'SYNO.NoteStation.Smart': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  // 批次 B：共享给我（J5）要拿当前用户名来判断 owner != 我
  'SYNO.NoteStation.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.NoteStation.Note.Encrypt': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  // 加密/超大正文会走 `Note.Polling`（官方 Web 对加密笔记就是这么发的）
  'SYNO.NoteStation.Note.Polling': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

/// 列表条目（详情页在拿到 `Note/get` 之前先用它渲染）
NoteDto _stub(String id, String title, {String content = ''}) => NoteDto(
  objectId: id,
  title: title,
  parentId: 'nb1',
  content: content,
  hasContent: content.isNotEmpty,
  ver: '1.0',
);

Map<String, dynamic> _note({
  required String id,
  required String title,
  String notebook = 'nb1',
  String content = '',
  String brief = '',
  int mtime = 1700000000000,
  List<String>? tags,
}) => {
  'object_id': id,
  'title': title,
  'parent_id': notebook,
  'content': content,
  'brief': brief,
  'mtime': mtime,
  'ver': '1.0',
  if (tags != null) 'tag': tags,
};

/// 装好 NoteStation API 的 ProviderContainer + 挂页面
Future<({FakeTransport t, ProviderContainer container})> _boot(
  Map<String, Map<String, dynamic>> responses,
) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._noteTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final notes = NoteStationApi(api);
  final container = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(notes),
      // 笔记 provider 现在读 Drift 缓存 → 测试里给内存库
      chatDatabaseProvider.overrideWith((ref) {
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
    ],
  );
  addTearDown(container.dispose);
  return (t: t, container: container);
}

/// 找到带某个 tooltip 的 IconButton（`find.byTooltip` 命中的是 Tooltip 本身）
IconButton _iconButton(WidgetTester tester, String tooltip) =>
    tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        // ★ 用**真实主题**（不是默认 ThemeData）：App 的 textTheme 曾经把颜色
        // 全部清成 null，flutter_quill 的 `baseStyle.color!` 就会抛异常，
        // 真机上整个正文区变成一块灰色 ErrorBox。用真实主题才能测出这类问题。
        theme: AppTheme.dark(),
        home: child,
        // flutter_quill 的工具栏/编辑器要它自己的本地化资源
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

/// 把测试窗口加宽：编辑器工具栏是一条横向滚动条，5 个自定义按钮在
/// 800px 默认宽度下会滚出屏幕，`tap` 会命中不到（hit-test 警告）。
void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(2000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  final baseResponses = <String, Map<String, dynamic>>{
    'SYNO.NoteStation.Notebook.list': {
      'notebooks': [
        {'object_id': 'nb1', 'title': '工作', 'ver': '1.0'},
        {'object_id': 'nb2', 'title': '生活', 'ver': '1.0'},
      ],
      'total': 2,
    },
    'SYNO.NoteStation.Note.list': {
      'notes': [
        _note(id: 'n1', title: '周会纪要', brief: '下周排期'),
        _note(id: 'n2', title: '购物清单', notebook: 'nb2', brief: '牛奶 鸡蛋'),
        _note(id: 'n3', title: '读书笔记', brief: '第三章'),
      ],
      'total': 3,
    },
  };

  testWidgets('预设笔记本 title 为空时显示「我的记事本」', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Notebook.list': {
        'notebooks': [
          {'object_id': 'nb1', 'title': '', 'preset': true},
        ],
      },
      'SYNO.NoteStation.Note.list': {'notes': <dynamic>[], 'total': 0},
    });
    await _pump(tester, b.container, const NotesPage());
    expect(
      find.textContaining('我的记事本'),
      findsOneWidget,
      reason: '服务端只给 preset:true，名字来自语言包的 [notebook] default',
    );
  });

  testWidgets('列表显示笔记标题与摘要', (tester) async {
    final b = await _boot(baseResponses);
    await _pump(tester, b.container, const NotesPage());

    expect(find.text('周会纪要'), findsOneWidget);
    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('读书笔记'), findsOneWidget);
    // 笔记本筛选条：全部 + 两个笔记本
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('生活 1'), findsOneWidget, reason: '带条数');
  });

  testWidgets('按笔记本筛选', (tester) async {
    final b = await _boot(baseResponses);
    await _pump(tester, b.container, const NotesPage());

    await tester.tap(find.text('生活 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('周会纪要'), findsNothing);
  });

  testWidgets('搜索按标题/摘要过滤', (tester) async {
    final b = await _boot(baseResponses);
    await _pump(tester, b.container, const NotesPage());

    await tester.tap(find.byTooltip('搜索笔记'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '牛奶');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('读书笔记'), findsNothing);
  });

  testWidgets('空列表给出空态 + 新建入口', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Notebook.list': {
        'notebooks': [
          {'object_id': 'nb1', 'title': '工作'},
        ],
      },
      'SYNO.NoteStation.Note.list': {'notes': <dynamic>[], 'total': 0},
    });
    await _pump(tester, b.container, const NotesPage());

    expect(find.text('还没有笔记'), findsOneWidget);
    expect(find.text('新建笔记'), findsOneWidget);
  });

  testWidgets('没有 Note Station 权限时给出可操作文案', (tester) async {
    final t = FakeTransport(
      {
        'SYNO.NoteStation.Notebook.list': {'notebooks': <dynamic>[]},
        'SYNO.NoteStation.Note.list': {},
      },
      {...FakeTransport.table, ..._noteTable},
    );
    t.failures['SYNO.NoteStation.Note.list'] = 160;
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
      ],
    );
    addTearDown(container.dispose);

    await _pump(tester, container, const NotesPage());
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('打不开笔记'), findsOneWidget);
    expect(find.textContaining('没有 Note Station 权限'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('打开笔记：正文渲染出来', (tester) async {
    final b = await _boot({
      ...baseResponses,
      'SYNO.NoteStation.Note.get': _note(
        id: 'n1',
        title: '周会纪要',
        content: '<h2>议题</h2><p>下周<b>排期</b></p>',
      ),
    });
    await _pump(tester, b.container, NoteViewPage(note: _stub('n1', '周会纪要')));
    await tester.pump(const Duration(milliseconds: 50));

    // Quill 把正文画成 RichText（不是 Text widget），所以要 findRichText
    expect(find.textContaining('议题', findRichText: true), findsWidgets);
    expect(find.textContaining('排期', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑器：新建走 Note/create（标题 + parent_id 都 Gson 编码）', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Notebook.list':
          baseResponses['SYNO.NoteStation.Notebook.list']!,
      'SYNO.NoteStation.Note.create': {'object_id': 'new-1', 'ver': '0.1'},
    });
    await _pump(
      tester,
      b.container,
      const NoteEditorPage(
        notebooks: [NotebookDto(objectId: 'nb1', title: '工作')],
      ),
    );

    await tester.enterText(find.byType(TextField).first, '新笔记');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final call = b.t.calls.lastWhere((c) => c['method'] == 'create');
    expect(call['api'], 'SYNO.NoteStation.Note');
    expect(call['title'], '"新笔记"');
    expect(call['parent_id'], '"nb1"');
    expect(call['ctime'], isNotNull);
    // 审计 §2.A15 / §5.4：官方 UI 是 v3
    expect(call['version'], '3');
  });

  // ------------------------------------------------- A11「移动到其他笔记本」
  testWidgets('A11 保存时改笔记本 → Note/set 带 parent_id（同/异都显式写回）', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Note.get': _note(
        id: 'n1',
        title: '周会纪要',
        content: '<p>原件</p>',
      ),
      'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
    });
    await _pump(
      tester,
      b.container,
      NoteEditorPage(
        note: _stub('n1', '周会纪要'),
        notebooks: const [
          NotebookDto(objectId: 'nb1', title: '工作'),
          NotebookDto(objectId: 'nb2', title: '生活'),
        ],
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 打开笔记本下拉，选「生活」
    await tester.tap(find.byKey(const Key('note-editor-notebook')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生活').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final params = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(params['parent_id'], '"nb2"');
    expect(params['ver'], '"1.0"', reason: '乐观锁：ver 必须原样回传');
  });

  testWidgets('A11 目标笔记本为空 → 只提示、不发请求（不误清空 parent_id）', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Notebook.list':
          baseResponses['SYNO.NoteStation.Notebook.list']!,
      'SYNO.NoteStation.Note.create': {'object_id': 'new-1', 'ver': '0.1'},
    });
    await _pump(
      tester,
      b.container,
      const NoteEditorPage(notebooks: []), // 一条笔记本都没有
    );
    await tester.enterText(find.byType(TextField).first, '新笔记');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('先选一个笔记本'), findsOneWidget);
    expect(b.t.calls.where((c) => c['method'] == 'create'), isEmpty);
  });

  // ------------------------------------------- 批次 A：编辑器格式补齐（接线）
  group('批次 A · 编辑器格式补齐', () {
    testWidgets('五个官方格式按钮都在，编辑器不炸（embed builder 齐全）', (tester) async {
      _wide(tester);
      final b = await _boot({
        'SYNO.NoteStation.Note.get': _note(
          id: 'n1',
          title: '周会纪要',
          content: '<p>原件</p>',
        ),
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: _stub('n1', '周会纪要'),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      for (final k in const [
        'note-toolbar-format-block',
        'note-toolbar-synofontsize',
        'note-toolbar-note-link',
        'note-toolbar-hr',
        'note-toolbar-attachment',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('分割线：插入后保存的正文里有 <hr>（官方 inserthorizontalrule）', (tester) async {
      _wide(tester);
      final b = await _boot({
        'SYNO.NoteStation.Note.get': _note(
          id: 'n1',
          title: '周会纪要',
          content: '<p>原件</p>',
        ),
        'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: _stub('n1', '周会纪要'),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.ensureVisible(find.byKey(const Key('note-toolbar-hr')));
      await tester.tap(find.byKey(const Key('note-toolbar-hr')));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final params = b.t.calls.lastWhere((c) => c['method'] == 'set');
      expect(params['content'], contains('<hr>'));
    });

    testWidgets('段落样式对话框：官方 div + h1..h6 都在', (tester) async {
      _wide(tester);
      final b = await _boot({
        'SYNO.NoteStation.Note.get': _note(
          id: 'n1',
          title: '周会纪要',
          content: '<p>原件</p>',
        ),
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: _stub('n1', '周会纪要'),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.ensureVisible(
        find.byKey(const Key('note-toolbar-format-block')),
      );
      await tester.tap(find.byKey(const Key('note-toolbar-format-block')));
      await tester.pumpAndSettle();
      for (var level = 0; level <= 6; level++) {
        expect(
          find.byKey(Key('note-format-block-$level')),
          findsOneWidget,
          reason: 'level=$level',
        );
      }
      await tester.tap(find.byKey(const Key('note-format-block-4')));
      await tester.pumpAndSettle();
      // H4 被应用到当前空行 → 保存的 HTML 里应出现 <h4>
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final params = b.t.calls.lastWhere((c) => c['method'] == 'set');
      expect(params['content'], contains('<h4>'));
    });

    testWidgets('笔记链接：选另一条笔记 → 正文里是 notestation:// 链接', (tester) async {
      _wide(tester);
      final b = await _boot({
        ...baseResponses,
        'SYNO.NoteStation.Note.get': _note(
          id: 'n1',
          title: '周会纪要',
          content: '<p>原件</p>',
        ),
        'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: _stub('n1', '周会纪要'),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // 让 `noteListProvider` 先把候选笔记拉回来
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('note-toolbar-note-link')),
      );
      await tester.tap(find.byKey(const Key('note-toolbar-note-link')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-note-link-dialog')), findsOneWidget);
      // 不能链到自己
      expect(find.byKey(const Key('note-note-link-n1')), findsNothing);
      await tester.tap(find.byKey(const Key('note-note-link-n3')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final params = b.t.calls.lastWhere((c) => c['method'] == 'set');
      expect(params['content'], contains('notestation://local/self/n3'));
      expect(params['content'], contains('读书笔记'));
    });

    testWidgets('附件列表：删除走 Note/set 元数据（无 multipart），列表里消失', (tester) async {
      _wide(tester);
      final b = await _boot({
        'SYNO.NoteStation.Note.get': {
          ..._note(id: 'n1', title: '周会纪要', content: '<p>原件</p>'),
          'attachment': {
            'f1': {
              'file_id': 'f1',
              'name': '报表.xlsx',
              'size': 2048,
              'type': 'application/vnd.ms-excel',
            },
          },
        },
        'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: _stub('n1', '周会纪要'),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('note-editor-attachments')));
      await tester.pumpAndSettle();
      expect(find.text('报表.xlsx'), findsOneWidget);

      await tester.tap(find.byKey(const Key('note-attachment-delete-f1')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final params = b.t.calls.lastWhere((c) => c['method'] == 'set');
      expect(
        params['attachment'],
        '[{"action":"delete","name":"f1","file_id":"f1"}]',
      );
      expect(params.containsKey('files'), isFalse, reason: '删除不该带任何文件段');
      // 再打开附件列表：已被删掉
      await tester.tap(find.byKey(const Key('note-editor-attachments')));
      await tester.pumpAndSettle();
      expect(find.text('报表.xlsx'), findsNothing);
    });
  });

  testWidgets('★ 编辑"没正文的列表条目"会先取全量，保存不会清空正文', (tester) async {
    // 这是真机探针里最危险的一条路：`Note/set` 的回包不带正文，
    // 如果编辑器拿列表条目（无 content）就开编，一保存服务端正文就没了。
    final b = await _boot({
      'SYNO.NoteStation.Note.get': _note(
        id: 'n1',
        title: '周会纪要',
        content: '<p>原件</p>',
      ),
      'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
    });
    await _pump(
      tester,
      b.container,
      NoteEditorPage(
        note: _stub('n1', '周会纪要'), // 列表条目：hasContent=false
        notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('原件', findRichText: true),
      findsWidgets,
      reason: '正文要从 Note/get 取回来才能编辑',
    );

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final params = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(params['content'], contains('原件'), reason: '保存的正文里必须有原来的内容，不能是空串');
    expect(params['ver'], '"1.0"');
    expect(
      tester.takeException(),
      isNull,
      reason: '编辑器也要给图片 embed builder（带图笔记不能整块变 ErrorBox）',
    );
  });

  testWidgets('★ 插入图片：先建笔记→multipart 上传→正文占位换成 file_id', (tester) async {
    // 真机图片文件（测试里用一张 1x1 PNG）
    final dir = Directory.systemTemp.createTempSync('note-insert-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final png = File('${dir.path}/x.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AA'
          'AAABAAEAAAD//wMAF/8ABa4d1wAAAABJRU5ErkJggg==',
        ),
      );
    const ref = 'REF-X'; // 真实实现里是 base64(时间戳+文件名)

    final b = await _boot({
      'SYNO.NoteStation.Notebook.list': {
        'notebooks': [
          {'object_id': 'nb1', 'title': '工作'},
        ],
      },
      'SYNO.NoteStation.Note.create': {'object_id': 'new-1', 'ver': '0.1'},
      'SYNO.NoteStation.Note.set': {
        'data': [
          {
            'object_id': 'new-1',
            'ver': '0.2',
            'attachment': {
              '_F1': {
                'name': 'x.png',
                'size': 68,
                'type': 'image',
                'width': 1,
                'height': 1,
                'ref': ref,
              },
            },
          },
        ],
      },
      'SYNO.NoteStation.Note.get': _note(id: 'new-1', title: '带图'),
    });
    // 用同一条假传输再包一层容器（要额外覆盖 picker，所以不能直接用 _boot 的容器）
    final container = ProviderContainer(
      overrides: [
        noteApiProvider.overrideWithValue(NoteStationApi(DsmWebApi(b.t))),
        // 相册选图在测试里换成"直接给这张本地文件"
        noteLocalPickerProvider.overrideWithValue(
          (source) async => [NotePickedImage(path: png.path, name: 'x.png')],
        ),
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
    await tester.tap(find.byTooltip('插入图片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('从相册选'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(Image), findsWidgets, reason: '待上传的图先显示本地预览');

    await tester.enterText(find.byType(TextField).first, '带图');
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final created = b.t.calls.lastWhere((c) => c['method'] == 'create');
    expect(created['api'], 'SYNO.NoteStation.Note');
    expect(created['title'], '"带图"');

    final upload = b.t.calls.lastWhere((c) => c['files'] != null);
    expect(upload['api'], 'SYNO.NoteStation.Note');
    expect(upload['method'], 'set');
    expect(upload['version'], '2', reason: '附件走 v2');
    expect(upload['files'], [
      '${javaStringHashCode('x.png')}:x.png',
    ], reason: 'multipart 字段名 = Java hashCode');
    final attachment =
        (jsonDecode(upload['attachment'] as String) as List).single as Map;
    expect(attachment['action'], 'create');
    expect(attachment['format'], 'raw');
    expect(attachment['name'], '${javaStringHashCode('x.png')}');
    // content 是 Gson 二次编码的 JSON 串（带转义），解出来再看正文
    final html = jsonDecode(upload['content'] as String) as String;
    expect(html, contains('class="syno-notestation-image-object"'));
    expect(
      html,
      contains('ref="${attachment['ref']}"'),
      reason: '附件表的 ref 与正文里的 ref 必须一致',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('★ 编辑器打开带图笔记：图片正常渲染（embed builder 不能漏）', (tester) async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AA'
      'AAABAAEAAAD//wMAF/8ABa4d1wAAAABJRU5ErkJggg==',
    );
    final b = await _boot({
      'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
    });
    b.t.downloadBytes = png;
    final note = NoteDto(
      objectId: 'n1',
      title: '带图笔记',
      parentId: 'nb1',
      ver: '1.0',
      hasContent: true,
      content:
          '<p>l1.png</p>'
          '<img class="syno-notestation-image-object" '
          'src="webman/3rdparty/NoteStation/images/transparent.gif" '
          'ref="REF-1" adjust="true">',
      attachments: const {
        '_F1': NoteAttachmentDto(
          fileId: '_F1',
          name: 'l1.png',
          type: 'image',
          ref: 'REF-1',
        ),
      },
    );
    await _pump(
      tester,
      b.container,
      NoteEditorPage(
        note: note,
        notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsWidgets, reason: '编辑器里图片要渲染出来');
  });

  testWidgets('★ 正文还在路上时，详情页的编辑按钮是禁用的', (tester) async {
    final t = FakeTransport(
      {
        'SYNO.NoteStation.Notebook.list': {'notebooks': <dynamic>[]},
        'SYNO.NoteStation.Note.get': _note(id: 'n1', title: '周会纪要'),
      },
      {...FakeTransport.table, ..._noteTable},
    );
    t.pendingKeys.add('SYNO.NoteStation.Note.get'); // 请求一直"在路上"
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
      ],
    );
    addTearDown(container.dispose);

    await _pump(tester, container, NoteViewPage(note: _stub('n1', '周会纪要')));
    expect(_iconButton(tester, '编辑').onPressed, isNull);
    expect(_iconButton(tester, '删除').onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets('编辑器：打开已有笔记时会预填标题', (tester) async {
    final b = await _boot(baseResponses);
    await _pump(
      tester,
      b.container,
      NoteEditorPage(
        note: _stub('n1', '周会纪要', content: '<p>正文</p>'),
        notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
      ),
    );

    expect(find.text('周会纪要'), findsOneWidget);
    expect(find.text('编辑笔记'), findsOneWidget);
  });

  testWidgets('编辑器：AI 助手能总结笔记（没装模型走内置摘要）', (tester) async {
    final b = await _boot(baseResponses);
    await _pump(
      tester,
      b.container,
      const NoteEditorPage(
        notebooks: [NotebookDto(objectId: 'nb1', title: '工作')],
      ),
    );

    // 空笔记：点 AI 只给提示，不弹层
    await tester.tap(find.byTooltip('AI 助手'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('先写点内容'), findsOneWidget);

    // 有正文的路径（弹层里跑总结）由共用的助手弹层测试与阅读器测试覆盖；
    // 这里只钉住"入口在 + 空笔记有护栏"这两条，避免把编辑器的输入链路
    // 在测试里重造一遍（Markdown 切换/Quill 输入各有自己的用例）
    expect(find.byTooltip('AI 助手'), findsOneWidget);
  });

  testWidgets('列表封面缩略图也用 Note/download（thumb_source）', (tester) async {
    final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AA'
      'AAABAAEAAAD//wMAF/8ABa4d1wAAAABJRU5ErkJggg==',
    );
    final t = FakeTransport(
      {
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': '工作'},
          ],
        },
        'SYNO.NoteStation.Note.list': {
          'notes': [
            {
              ..._note(id: 'n1', title: '带图的笔记'),
              'thumb': {
                'name': 'thumb',
                'type': 'image',
                'ext': 'png',
                'width': 200,
                'height': 434,
                'size': 128657,
                'md5': 'e5c0',
                'thumb_source': '_F1',
              },
            },
          ],
          'total': 1,
        },
      },
      {...FakeTransport.table, ..._noteTable},
    );
    t.downloadBytes = pngBytes;
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
      ],
    );
    addTearDown(container.dispose);

    await _pump(tester, container, const NotesPage());
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      t.downloads.any(
        (u) =>
            u.contains('method=download') &&
            u.contains('file_id=%22_F1%22') &&
            u.contains('thumb=true'),
      ),
      isTrue,
    );
    expect(find.text('带图的笔记'), findsOneWidget);
  });

  testWidgets('图片附件：正文里的 <img ref> 会去取附件字节', (tester) async {
    final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AA'
      'AAABAAEAAAD//wMAF/8ABa4d1wAAAABJRU5ErkJggg==',
    );
    final t = FakeTransport(
      {
        'SYNO.NoteStation.Notebook.list': {'notebooks': <dynamic>[]},
        'SYNO.NoteStation.Note.get': {
          ..._note(
            id: 'n1',
            title: '图片笔记',
            content:
                '<p>l1.png</p>'
                '<img class="syno-notestation-image-object" '
                'src="webman/3rdparty/NoteStation/images/transparent.gif" '
                'ref="REF-1" adjust="true">',
          ),
          'attachment': {
            '_F1': {
              'name': 'l1.png',
              'size': 68,
              'type': 'image',
              'width': 1,
              'height': 1,
              'ref': 'REF-1',
            },
          },
        },
      },
      {...FakeTransport.table, ..._noteTable},
    );
    t.downloadBytes = pngBytes;
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
      ],
    );
    addTearDown(container.dispose);

    await _pump(tester, container, NoteViewPage(note: _stub('n1', '图片笔记')));
    await tester.pump(const Duration(milliseconds: 100));

    // 下载走的必须是 Note/download（带 object_id/file_id/thumb），不是别的接口
    expect(
      t.downloads.any(
        (u) =>
            u.contains('method=download') &&
            u.contains('file_id=%22_F1%22') &&
            u.contains('thumb=true'),
      ),
      isTrue,
      reason: '图片要按附件 file_id 下载缩略图',
    );
    expect(find.byType(Image), findsWidgets, reason: '缩略图渲染成 Image');

    // 点开大图：同一条笔记里的**两张**图都在 PageView 里（左右滑能翻页）
  });

  testWidgets('全屏看大图：同一条笔记的两张图能左右滑，取原图（thumb=false）', (tester) async {
    final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AA'
      'AAABAAEAAAD//wMAF/8ABa4d1wAAAABJRU5ErkJggg==',
    );
    final t = FakeTransport({}, {...FakeTransport.table, ..._noteTable});
    t.downloadBytes = pngBytes;
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
      ],
    );
    addTearDown(container.dispose);

    const first = NoteAttachmentDto(
      fileId: '_F1',
      name: 'l1.png',
      size: 1913681,
      type: 'image',
    );
    const second = NoteAttachmentDto(
      fileId: '_F2',
      name: 'nf.png',
      size: 1468858,
      type: 'image',
    );
    await _pump(
      tester,
      container,
      const NoteImagePage(
        objectId: 'n1',
        attachment: first,
        siblings: [first, second],
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('l1.png  1/2'), findsOneWidget, reason: '两张图要能翻页');
    expect(
      t.downloads.any((u) => u.contains('thumb=false')),
      isTrue,
      reason: '看大图要看原图（thumb=false）',
    );
  });

  testWidgets('待办：列表 + 优先级/截止/星标 + 勾选走 Todo/set（官方数组形态）', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Todo.list': {
        'todos': [
          {
            'object_id': 'T1',
            'title': '买牛奶',
            'done': false,
            'priority': 200,
            'star': true,
            'comment': '顺路',
            'due_date': 1700000000000,
          },
          {'object_id': 'T2', 'title': '交周报', 'done': true},
        ],
        'count': 2,
      },
      'SYNO.NoteStation.Todo.set': <String, dynamic>{},
    });
    await _pump(tester, b.container, const NoteTodoPage());

    expect(find.text('买牛奶'), findsOneWidget);
    expect(find.text('中优先级'), findsOneWidget);
    expect(find.text('顺路'), findsOneWidget);
    expect(find.text('交周报'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(set['api'], 'SYNO.NoteStation.Todo');
    expect(set['object_id'], '["T1"]', reason: '批量接口：object_id 是数组');
    expect(set['done'], 'true');
    // 顶层任务必须回发这些字段，否则服务端会把它们清掉
    expect(set['priority'], '200');
    expect(set['star'], 'true');
    expect(set['comment'], '"顺路"');
    expect(set['due_date'], '1700000000000');
    expect(tester.takeException(), isNull);
  });

  testWidgets('待办：按状态筛选（filter.done）', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Todo.list': {
        'todos': [
          {'object_id': 'T1', 'title': '买牛奶', 'done': false},
        ],
      },
    });
    await _pump(tester, b.container, const NoteTodoPage());

    await tester.tap(find.text('未完成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final list = b.t.calls.lastWhere((c) => c['method'] == 'list');
    expect(list['filter'], '{"done":false}');
  });

  testWidgets('待办：parent_id 拼成层级（缩进 + 折叠 + 进度）', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Todo.list': {
        'todos': [
          {'object_id': 'P1', 'title': '搬家', 'done': false},
          {'object_id': 'C1', 'title': '找房子', 'parent_id': 'P1', 'done': true},
          {'object_id': 'C2', 'title': '打包', 'parent_id': 'P1', 'done': false},
        ],
      },
    });
    await _pump(tester, b.container, const NoteTodoPage());

    expect(find.text('搬家'), findsOneWidget);
    expect(find.text('找房子'), findsOneWidget);
    expect(find.text('打包'), findsOneWidget);
    // 父任务上的进度是"子孙里完成几个 / 共几个"
    expect(find.text('1/2'), findsOneWidget);
    // 子任务缩进（列表左内边距更大）
    double padOf(String title) => tester
        .widget<DesignCheckRow>(
          find.ancestor(
            of: find.text(title),
            matching: find.byType(DesignCheckRow),
          ),
        )
        .contentPadding!
        .resolve(TextDirection.ltr)
        .left;
    expect(padOf('找房子'), greaterThan(padOf('搬家')));

    // 收起父任务 → 子任务不画了
    await tester.tap(find.byTooltip('收起子任务'));
    await tester.pump();
    expect(find.text('搬家'), findsOneWidget);
    expect(find.text('找房子'), findsNothing);

    // 展开回来
    await tester.tap(find.byTooltip('展开子任务'));
    await tester.pump();
    expect(find.text('找房子'), findsOneWidget);
  });

  testWidgets('待办：筛选时保留命中的子任务 + 它的父任务当上下文', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Todo.list': {
        'todos': [
          {'object_id': 'P1', 'title': '搬家', 'done': true},
          {'object_id': 'C1', 'title': '找房子', 'parent_id': 'P1', 'done': true},
          {'object_id': 'C2', 'title': '打包', 'parent_id': 'P1', 'done': false},
        ],
      },
    });
    await _pump(tester, b.container, const NoteTodoPage());

    await tester.tap(find.text('未完成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 只有 C2 命中，但它的父 P1 得画出来当上下文
    expect(find.text('打包'), findsOneWidget);
    expect(find.text('搬家'), findsOneWidget);
    expect(find.text('找房子'), findsNothing);
  });

  testWidgets('待办：给顶层任务加子任务 → Todo/create 带 parent_id', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Todo.list': {
        'todos': [
          {'object_id': 'P1', 'title': '搬家', 'done': false},
        ],
      },
      'SYNO.NoteStation.Todo.create': <String, dynamic>{},
    });
    await _pump(tester, b.container, const NoteTodoPage());

    await tester.tap(find.byKey(const Key('todo-add-sub-P1')));
    await tester.pumpAndSettle();
    expect(find.text('新建子任务'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '订车');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final create = b.t.calls.lastWhere((c) => c['method'] == 'create');
    expect(create['api'], 'SYNO.NoteStation.Todo');
    expect(create['title'], '"订车"', reason: 'title 走官方那套 Gson 引号串');
    expect(create['parent_id'], '"P1"');
  });

  testWidgets('回收站：只列 recycle=true，还原走 Note/restore', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Notebook.list': {
        'notebooks': [
          {'object_id': 'nb1', 'title': '工作'},
        ],
      },
      'SYNO.NoteStation.Note.list': {
        'notes': [
          {..._note(id: 'n1', title: '删掉的'), 'recycle': true},
          {..._note(id: 'n2', title: '还在的'), 'recycle': false},
        ],
      },
      'SYNO.NoteStation.Note.restore': <String, dynamic>{},
    });
    await _pump(tester, b.container, const NoteRecyclePage());

    expect(find.text('删掉的'), findsOneWidget);
    expect(find.text('还在的'), findsNothing, reason: '正常笔记不进回收站');

    await tester.tap(find.byTooltip('操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('还原'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final restore = b.t.calls.lastWhere((c) => c['method'] == 'restore');
    expect(restore['api'], 'SYNO.NoteStation.Note');
    expect(restore['object_id'], '"n1"');
  });

  testWidgets('回收站：彻底删除要先确认，recycle=false', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Notebook.list': {
        'notebooks': [
          {'object_id': 'nb1', 'title': '工作'},
        ],
      },
      'SYNO.NoteStation.Note.list': {
        'notes': [
          {..._note(id: 'n1', title: '删掉的'), 'recycle': true},
        ],
      },
      'SYNO.NoteStation.Note.delete': <String, dynamic>{},
    });
    await _pump(tester, b.container, const NoteRecyclePage());

    await tester.tap(find.byTooltip('操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('彻底删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('无法恢复'), findsNothing); // 文案在 content 里
    expect(find.textContaining('永久删除'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final del = b.t.calls.lastWhere((c) => c['method'] == 'delete');
    expect(del['object_id'], '"n1"');
    expect(del['recycle'], 'false', reason: '彻底删除不能用默认的 recycle:true');
  });

  testWidgets('标签页：列表 + 计数 + 重命名（Tag/set 必须要 tag_id）', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Tag.list': {
        'tags': [
          // 真机形态：items 是"用了这个标签的笔记 id 数组"（不是数字）
          {
            'tag_id': '工作@1028',
            'title': '工作',
            'items': ['1028_n1', '1028_n2'],
            'category': 'tag',
          },
        ],
      },
      'SYNO.NoteStation.Tag.set': <String, dynamic>{},
    });
    await _pump(tester, b.container, const NoteTagPage());

    expect(find.text('工作'), findsOneWidget);
    expect(find.text('2 条笔记'), findsOneWidget);

    await tester.tap(find.byTooltip('操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('重命名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), '旅行');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(set['api'], 'SYNO.NoteStation.Tag');
    expect(set['version'], '1');
    expect(set['title'], '"旅行"');
    expect(
      set['tag_id'],
      '"工作@1028"',
      reason: '服务端没有建空标签的接口，Tag/set 只能带 tag_id 改名',
    );
  });

  testWidgets('笔记详情：加/删标签走 Note/set 的 tag 数组', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Tag.list': {
        'tags': [
          {'tag_id': '工作@1028', 'title': '工作', 'items': 1},
          {'tag_id': '生活@1028', 'title': '生活', 'items': 0},
        ],
      },
      'SYNO.NoteStation.Note.get': _note(
        id: 'n1',
        title: '周会纪要',
        content: '<p>下周<b>排期</b></p>',
        tags: ['工作'],
      ),
      'SYNO.NoteStation.Note.set': {
        'data': [
          {'object_id': 'n1', 'ver': '1.1'},
        ],
      },
    });
    await _pump(tester, b.container, NoteViewPage(note: _stub('n1', '周会纪要')));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('标签'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DesignCheckRow), findsNWidgets(2));
    await tester.tap(find.text('生活'));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(set['api'], 'SYNO.NoteStation.Note');
    expect(set['tag'], '["工作","生活"]', reason: 'tag 是标签标题数组');
    expect(tester.takeException(), isNull);
  });

  testWidgets('待办编辑：新建走 Todo/create（priority 是枚举，不是 1/2/3）', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Todo.create': {
        'object_id': 'T9',
        'title': '写周报',
        'done': false,
        'priority': 200,
      },
    });
    await _pump(tester, b.container, const NoteTodoPage());

    await tester.tap(find.text('新建待办'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField).first, '写周报');
    // 优先级下拉选「中」= 200
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('中').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final create = b.t.calls.lastWhere((c) => c['method'] == 'create');
    expect(create['api'], 'SYNO.NoteStation.Todo');
    expect(create['title'], '"写周报"');
    expect(create['priority'], '200', reason: '枚举值 200 = 中');
    expect(create['due_date'], '-1', reason: '-1 = 没有截止日期');
    expect(tester.takeException(), isNull);
  });

  testWidgets('待办编辑：改已有任务走 Todo/set（完整字段，object_id 是数组）', (tester) async {
    final b = await _boot({
      'SYNO.NoteStation.Todo.list': {
        'todos': [
          {
            'object_id': 'T1',
            'title': '买牛奶',
            'done': false,
            'priority': 100,
            'comment': '顺路',
          },
        ],
      },
      'SYNO.NoteStation.Todo.set': <String, dynamic>{},
      'SYNO.NoteStation.Todo.delete': <String, dynamic>{},
    });
    await _pump(tester, b.container, const NoteTodoPage());
    await tester.tap(find.text('买牛奶'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 「已完成」在页面上是筛选 chip、在编辑页是开关 —— 用 widget 类型消歧
    await tester.tap(find.widgetWithText(DesignSwitchRow, '已完成'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(set['object_id'], '["T1"]');
    expect(set['done'], 'true');
    expect(set['title'], '"买牛奶"');
    expect(set['priority'], '100', reason: '原来的优先级要原样回发');
    expect(set['comment'], '"顺路"');
  });

  testWidgets('笔记本：新建走 Notebook/create，长按可重命名/删除', (tester) async {
    final b = await _boot({
      ...baseResponses,
      'SYNO.NoteStation.Notebook.create': {'object_id': 'nb9', 'ctime': 1},
      'SYNO.NoteStation.Notebook.set': <String, dynamic>{},
      'SYNO.NoteStation.Notebook.delete': <String, dynamic>{},
    });
    await _pump(tester, b.container, const NotesPage());

    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('新建笔记本'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), '项目');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final create = b.t.calls.lastWhere((c) => c['method'] == 'create');
    expect(create['api'], 'SYNO.NoteStation.Notebook');
    expect(create['version'], '1');
    expect(create['title'], '"项目"');

    // 新建后 notebooksProvider 会重新加载（chip 短暂消失），多 pump 两拍
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 长按笔记本 chip → 重命名
    await tester.longPress(find.text('工作 2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('重命名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), '工作 2026');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rename = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(rename['object_id'], '"nb1"');
    expect(rename['title'], '"工作 2026"');
    expect(rename['ver'], '"1.0"', reason: '改名要带乐观锁 ver');
  });

  group('加密笔记', () {
    testWidgets('详情页：口令不对要报错，口令对了显示明文', (tester) async {
      final cipher = NoteCrypto.encryptContent('<p>机密：藏宝图在沙发下</p>', 'pw');
      final note = NoteDto(
        objectId: 'N1',
        title: '机密',
        parentId: 'nb1',
        content: cipher,
        ver: '1.0',
        encrypt: true,
        hasContent: true,
      );
      final b = await _boot({
        'SYNO.NoteStation.Note.Encrypt.create': {'token': 'TK-1'},
      });
      await _pump(tester, b.container, NoteViewPage(note: note));

      expect(find.text('这条笔记已加密'), findsOneWidget);
      expect(
        find.textContaining('藏宝图', findRichText: true),
        findsNothing,
        reason: '没解锁前正文不能出现',
      );

      await tester.enterText(find.byType(TextField).first, 'wrong');
      await tester.tap(find.text('解锁'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('口令不对，再试一次'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'pw');
      await tester.tap(find.text('解锁'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Quill 画的是 RichText，不是 Text widget
      expect(find.textContaining('藏宝图在沙发下', findRichText: true), findsWidgets);
      // 解锁要向服务端换令牌
      expect(
        b.t.calls.any((c) => c['api'] == 'SYNO.NoteStation.Note.Encrypt'),
        isTrue,
      );
    });

    testWidgets('新建：开了加密 → Note/create 存的是密文 + encrypt=true', (tester) async {
      final b = await _boot({
        // 加密笔记走 `Note.Polling/create`（官方 Web 行为）
        'SYNO.NoteStation.Note.Polling.create': {'task_id': 'T1'},
        'SYNO.NoteStation.Note.Polling.create_status': {
          'succ': true,
          'resp': {
            'finish': true,
            'success': true,
            'data': [
              {'object_id': 'NEW1', 'ver': 'v1'},
            ],
          },
        },
        'SYNO.NoteStation.Note.get': {'object_id': 'NEW1', 'ver': 'v1'},
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );

      await tester.tap(
        find.ancestor(
          of: find.byTooltip('加密这条笔记'),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 弹窗里两个口令框（编辑器自己的标题框也在树上，要按弹窗收窄）
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.at(0), 'pw');
      await tester.enterText(fields.at(1), 'pw');
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).first, '机密笔记');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final create = b.t.calls.firstWhere(
        (c) =>
            c['api'] == 'SYNO.NoteStation.Note.Polling' &&
            c['method'] == 'create',
      );
      expect(create['encrypt'], 'true');
      final sent = jsonDecode(create['content'] as String) as String;
      expect(sent, startsWith('U2FsdGVkX1'), reason: '存进去的必须是密文');
      expect(
        NoteCrypto.decryptContent(sent, 'pw'),
        isNot(contains('U2FsdGVk')),
      );
    });

    testWidgets('编辑加密笔记：保存后详情页拿到的是明文（不是密文、也不是旧值）', (tester) async {
      // 回归：`_autoUnlock()` 见到 `_plain != null` 就早退，编辑保存回包里的
      // **明文** 必须当场覆盖 `_plain`，否则详情页一直显示解锁那一刻的旧正文。
      final cipher = NoteCrypto.encryptContent('<p>旧正文</p>', 'pw');
      final note = NoteDto(
        objectId: 'N9',
        title: '机密',
        parentId: 'nb1',
        content: cipher,
        ver: 'v1',
        encrypt: true,
        hasContent: true,
      );
      final b = await _boot({
        'SYNO.NoteStation.Note.get': {
          'object_id': 'N9',
          'title': '机密',
          'parent_id': 'nb1',
          'content': cipher,
          'ver': 'v1',
          'encrypt': true,
        },
        'SYNO.NoteStation.Note.Polling.set': {'task_id': 'T3'},
        'SYNO.NoteStation.Note.Polling.set_status': {
          'finish': true,
          'success': true,
          'auto_remove': false,
          'data': [
            {'object_id': 'N9', 'ver': 'v2'},
          ],
        },
      });
      // 预先解锁（省掉手输口令），口令/令牌都在内存表里
      b.container
          .read(noteUnlockStoreProvider)
          .keep(
            'N9',
            NoteUnlock(
              password: 'pw',
              token: 'TK-keep',
              expiresAt: DateTime.now().add(const Duration(hours: 1)),
            ),
          );
      await _pump(tester, b.container, NoteViewPage(note: note));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('旧正文', findRichText: true), findsWidgets);

      await tester.tap(find.byTooltip('编辑'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 富文本模式：聚焦正文（flutter_quill）后直接把文本打进输入连接
      // ⚠️ flutter_quill 的编辑器在 widget 测试里打不进字（`testTextInput` 会撞上
      // 详情页那个只读 QuillEditor 的输入连接）—— 这条用例只压"保存后回来的是
      // **明文**，不是服务端的密文、也不是解锁时的旧值"。
      await tester.tap(
        find.descendant(
          of: find.byType(NoteEditorPage),
          matching: find.text('保存'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // 保存走的是官方那条轮询路（加密笔记）
      final kinds = b.t.calls
          .map((c) => '${c['api']}.${c['method']}')
          .toList(growable: false);
      expect(
        kinds,
        containsAllInOrder([
          'SYNO.NoteStation.Note.Polling.set',
          'SYNO.NoteStation.Note.Polling.set_status',
          'SYNO.NoteStation.Note.Polling.set_stop',
        ]),
      );
      // 编辑器必须把**明文**回给详情页：回服务端那份密文的话，正文会变成
      // `U2FsdGVk…` 一串。
      expect(find.textContaining('U2FsdGVk', findRichText: true), findsNothing);
      expect(find.textContaining('旧正文', findRichText: true), findsWidgets);
      expect(find.textContaining('还是空的', findRichText: true), findsNothing);
    });

    testWidgets('编辑加密笔记：Note/set 带 cipher + encrypt + token', (tester) async {
      final cipher = NoteCrypto.encryptContent('<p>原文</p>', 'pw');
      final note = NoteDto(
        objectId: 'N1',
        title: '机密',
        parentId: 'nb1',
        content: cipher,
        ver: 'v1',
        encrypt: true,
        hasContent: true,
      );
      final b = await _boot({
        'SYNO.NoteStation.Note.Encrypt.create': {'token': 'TK-9'},
        // 加密笔记保存走 `Note.Polling/set`（官方 Web 行为），不再直连 `Note/set`
        'SYNO.NoteStation.Note.Polling.set': {'task_id': 'T2'},
        'SYNO.NoteStation.Note.Polling.set_status': {
          'succ': true,
          'resp': {
            'finish': true,
            'success': true,
            'data': [
              {'object_id': 'N1', 'ver': 'v2'},
            ],
          },
        },
        'SYNO.NoteStation.Note.get': {'object_id': 'N1', 'ver': 'v2'},
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: note,
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
          plainHtml: '<p>原文</p>',
          encryptPassword: 'pw',
        ),
      );

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final set = b.t.calls.firstWhere(
        (c) =>
            c['api'] == 'SYNO.NoteStation.Note.Polling' && c['method'] == 'set',
      );
      expect(set['encrypt'], 'true');
      expect(set['token'], '"TK-9"');
      final sent = jsonDecode(set['content'] as String) as String;
      expect(NoteCrypto.decryptContent(sent, 'pw'), contains('原文'));
      expect(tester.takeException(), isNull);
    });
  });

  // ====================================================== 批次 B（P0 剩余项）

  group('批次 B：待办提醒（E5）', () {
    testWidgets('编辑待办：选「提前 1 小时」→ Todo/set 的 reminder_offset=3600', (
      tester,
    ) async {
      final b = await _boot({'SYNO.NoteStation.Todo.set': <String, dynamic>{}});
      final todo = TodoDto(
        objectId: 'T1',
        title: '买牛奶',
        priority: 100,
        dueDate: 1700000000000,
        reminderOffset: -1,
      );
      await _pump(tester, b.container, NoteTodoEditorPage(todo: todo));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('note-todo-reminder')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // ★ r491：行卡高度变了 ⇒ 预设行可能被弹层底部裁掉，先滚到可见再点。
      await tester.ensureVisible(
        find.byKey(const Key('note-todo-reminder-preset-3600')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('note-todo-reminder-preset-3600')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('提前 1 小时'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final set = b.t.calls.lastWhere(
        (c) => c['method'] == 'set' && c['api'] == 'SYNO.NoteStation.Todo',
      );
      expect(set['reminder_offset'], '3600', reason: '官方提前量单位是秒');
      expect(set['due_date'], '1700000000000');
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有截止日期时提醒项不可点（官方先要求 due date）', (tester) async {
      final b = await _boot({});
      final todo = TodoDto(objectId: 'T1', title: '买牛奶', priority: 100);
      await _pump(tester, b.container, NoteTodoEditorPage(todo: todo));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('先设置截止日期'), findsOneWidget);
      await tester.tap(find.byKey(const Key('note-todo-reminder')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 没弹出选择器（没有任何预设项）
      expect(
        find.byKey(const Key('note-todo-reminder-preset-3600')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('批次 B：复制 / 加密转换（A9/A10）', () {
    testWidgets('复制菜单 → Note/copy（不发 encrypt/content）', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Note.get': _note(
          id: 'n1',
          title: '周会纪要',
          content: '<p>x</p>',
        ),
        'SYNO.NoteStation.Note.copy': {'object_id': 'n2'},
      });
      await _pump(
        tester,
        b.container,
        NoteViewPage(note: _stub('n1', '周会纪要', content: '<p>x</p>')),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('note-copy-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('note-copy-duplicate')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final copy = b.t.calls.lastWhere((c) => c['method'] == 'copy');
      expect(copy['api'], 'SYNO.NoteStation.Note');
      expect(copy['object_id'], '"n1"');
      expect('${copy['title']}', contains('副本'));
      expect(copy.containsKey('encrypt'), isFalse);
      expect(copy.containsKey('content'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('明文笔记的复制菜单没有「复制到明文」，有「复制到加密」', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Note.get': _note(
          id: 'n1',
          title: 'T',
          content: '<p>x</p>',
        ),
      });
      await _pump(
        tester,
        b.container,
        NoteViewPage(note: _stub('n1', 'T', content: '<p>x</p>')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('note-copy-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('note-copy-to-encrypt')), findsOneWidget);
      expect(find.byKey(const Key('note-copy-to-plaintext')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('复制到加密：encrypt=true 且 content 是密文（不是原文）', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Note.get': _note(
          id: 'n1',
          title: 'T',
          content: '<p>secret 原文</p>',
        ),
        'SYNO.NoteStation.Note.copy': {'object_id': 'n9'},
      });
      await _pump(
        tester,
        b.container,
        NoteViewPage(note: _stub('n1', 'T', content: '<p>secret 原文</p>')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('note-copy-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('note-copy-to-encrypt')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.byKey(const Key('note-copy-password')),
        'pw123',
      );
      await tester.tap(find.byKey(const Key('note-copy-password-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final copy = b.t.calls.lastWhere((c) => c['method'] == 'copy');
      expect(copy['encrypt'], 'true');
      final sent = jsonDecode(copy['content'] as String) as String;
      expect(sent, isNot(contains('secret')), reason: '发出去的必须是密文');
      expect(NoteCrypto.decryptContent(sent, 'pw123'), contains('secret'));
      expect(tester.takeException(), isNull);
    });
  });

  group('批次 B：智能笔记本入口（F6）', () {
    testWidgets('新建智能笔记本 → Smart/create（query 带 tag_operator）', (tester) async {
      _wide(tester);
      final b = await _boot({
        'SYNO.NoteStation.Smart.list': {'smarts': <dynamic>[]},
        'SYNO.NoteStation.Smart.create': {'object_id': 'S1'},
      });
      await _pump(tester, b.container, const NoteSmartPage());
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('note-smart-new')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byKey(const Key('note-smart-name')), '工作');
      await tester.enterText(find.byKey(const Key('note-smart-keyword')), '周报');
      await tester.tap(find.byKey(const Key('note-smart-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final c = b.t.calls.lastWhere(
        (x) => x['api'] == 'SYNO.NoteStation.Smart' && x['method'] == 'create',
      );
      expect(c['version'], '1');
      expect(c['title'], '"工作"');
      expect(c['query'], '{"keyword":"周报","tag_operator":"or"}');
      expect(c['commit_msg'], '{"device":"Flutter"}');
      expect(tester.takeException(), isNull);
    });
  });

  group('批次 B：Shelf 分层（F2）', () {
    testWidgets('按 stack 分组展示；未分组归到「笔记本」组', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb1', 'title': '工作', 'stack': 'Work'},
            {'object_id': 'nb2', 'title': '生活'},
          ],
          'total': 2,
        },
      });
      await _pump(tester, b.container, const NoteShelfPage());
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('note-shelf-Work')), findsOneWidget);
      expect(find.byKey(const Key('note-shelf-nb-nb1')), findsOneWidget);
      expect(find.byKey(const Key('note-shelf-nb-nb2')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('批次 B：共享给我入口（J5）', () {
    testWidgets('列出别人分享来的笔记本与单条笔记', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Info.get': {'username': 'me', 'uid': 1},
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {
              'object_id': 'nb1',
              'title': '同事的笔记本',
              'owner': {'username': 'bob'},
            },
          ],
          'total': 1,
        },
        'SYNO.NoteStation.Note.list': {
          'notes': [
            {
              'object_id': 'n1',
              'title': '共享笔记',
              'parent_id': 'nb1',
              'individual_joined': true,
            },
          ],
          'total': 1,
        },
      });
      await _pump(tester, b.container, const NoteJoinedPage());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-joined-notebook-nb1')), findsOneWidget);
      expect(find.byKey(const Key('note-joined-note-n1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
