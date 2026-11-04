// 笔记的 Markdown 模式：转换层单测 + 编辑器行为测试。
//
// 关键口径（见 `lib/src/features/notes/note_markdown.dart` 顶部）：
//   * 落库形态 = `<!--dsh-md:1:<base64 源码>-->` + **渲染好的 HTML** ——
//     官方端看排版正常，我们这边能无损拿回源码；
//   * 源码里可能有 `-->`，所以必须 base64（直接塞会截断注释）；
//   * 保存接口**不变**：还是 `Note/create|set` 的 `content` 字段（API 与官方一致）。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_markdown.dart';
import 'package:synhub/src/features/notes/note_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

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
};

Map<String, dynamic> _note({
  required String id,
  required String title,
  String content = '',
  String ver = '1.0',
}) => {
  'object_id': id,
  'title': title,
  'parent_id': 'nb1',
  'content': content,
  'brief': '',
  'mtime': 1700000000000,
  'ver': ver,
};

Future<({FakeTransport t, ProviderContainer container})> _boot(
  Map<String, Map<String, dynamic>> responses,
) async {
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
    ],
  );
  addTearDown(container.dispose);
  return (t: t, container: container);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget page,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        // 用真实主题 + quill 本地化（否则工具栏按钮会抛
        // MissingFlutterQuillLocalizationException）
        theme: AppTheme.dark(),
        home: page,
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
}

/// 按 hintText 找 TextField（标题框和 Markdown 源码框都是 TextField，
/// 靠位置 index 拿容易拿错；hint 是唯一的）
Finder _byHint(String hint) => find.byWidgetPredicate(
  (w) => w is TextField && (w.decoration?.hintText ?? '') == hint,
);

Finder _mdSourceField() => find.byWidgetPredicate(
  (w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('# 标题'),
);

void main() {
  group('Markdown ⇄ NoteStation HTML', () {
    test('保存形态：注释里放 base64 源码，后面跟渲染好的 HTML', () {
      final html = markdownToNoteHtml('# 标题\n\n这是**粗体**。');
      expect(html, startsWith(kMarkdownMarkerPrefix));
      expect(html, contains('<h1>标题</h1>'));
      expect(html, contains('<strong>粗体</strong>'));
      expect(isMarkdownNote(html), isTrue);

      // 源码无损取回
      expect(markdownSourceFromHtml(html), '# 标题\n\n这是**粗体**。');
      // 可见部分不含标记
      final visible = markdownVisibleHtml(html);
      expect(visible.contains('dsh-md'), isFalse);
      expect(visible, contains('<strong>粗体</strong>'));
    });

    test('源码里出现 `-->` 也不会截断注释（这就是要 base64 的原因）', () {
      const tricky = 'a --> b\n\n```\n<div>x</div>\n```';
      final html = markdownToNoteHtml(tricky);
      expect(markdownSourceFromHtml(html), tricky);
      expect(markdownVisibleHtml(html), contains('<pre>'));
    });

    test('GFM：表格 / 任务列表 / 删除线都能转出来', () {
      final html = markdownBodyToHtml(
        '| a | b |\n| --- | --- |\n| 1 | 2 |\n\n'
        '- [ ] 待办\n\n~~删除~~',
      );
      expect(html, contains('<table>'));
      expect(html, contains('<del>删除</del>'));
      expect(html, contains('checkbox'));
    });

    test('普通富文本笔记不会被误判成 Markdown', () {
      expect(isMarkdownNote('<h1>老笔记</h1>'), isFalse);
      expect(markdownSourceFromHtml('<h1>老笔记</h1>'), isNull);
      // 坏 base64 也要安全落地（当成普通富文本）
      expect(markdownSourceFromHtml('$kMarkdownMarkerPrefix!!!-->'), isNull);
    });

    test('精确编码：源码以 base64Url 存在标记里（便于排障）', () {
      final html = markdownToNoteHtml('# 标题');
      final encoded = base64Url.encode(utf8.encode('# 标题'));
      expect(html, contains(encoded));
    });
  });

  group('编辑器：Markdown 模式', () {
    testWidgets('打开 Markdown 笔记 → 源码框里是原文，预览渲染成 HTML', (tester) async {
      final md = markdownToNoteHtml('# 周会\n\n- [ ] 排期');
      final b = await _boot({
        'SYNO.NoteStation.Note.get': _note(id: 'n1', title: '周会', content: md),
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: NoteDto(
            objectId: 'n1',
            title: '周会',
            parentId: 'nb1',
            content: md,
            hasContent: true,
            ver: '1.0',
          ),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 自动进 Markdown 模式（源码在编辑框里），且**不显示**标记本体
      expect(find.textContaining('# 周会'), findsOneWidget);
      expect(find.textContaining('dsh-md'), findsNothing);

      // 预览：渲染后的正文
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pump();
      expect(find.textContaining('周会', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Markdown 笔记保存：content 带标记 + 渲染 HTML，仍走 Note/set', (
      tester,
    ) async {
      final md = markdownToNoteHtml('# 旧标题');
      final b = await _boot({
        'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: NoteDto(
            objectId: 'n1',
            title: '旧标题',
            parentId: 'nb1',
            content: md,
            hasContent: true,
            ver: '1.0',
          ),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 改源码后保存
      await tester.enterText(_mdSourceField(), '## 新标题\n\n正文');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final call = b.t.calls.lastWhere((c) => c['method'] == 'set');
      final content = call['content'] as String;
      expect(content, contains(kMarkdownMarkerPrefix));
      expect(content, contains('<h2>新标题</h2>'));
      // 源码（base64）要跟着更新
      expect(markdownSourceFromHtml(content), '## 新标题\n\n正文');
    });

    testWidgets('富文本笔记 → 切 Markdown：先确认，源码里保留原格式', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: NoteDto(
            objectId: 'n2',
            title: '老笔记',
            parentId: 'nb1',
            content: '<h1>老笔记</h1><p>正文</p>',
            hasContent: true,
            ver: '1.0',
          ),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byTooltip('用 Markdown 编辑'));
      await tester.pumpAndSettle();
      expect(find.text('用 Markdown 编辑？'), findsOneWidget);
      await tester.tap(find.text('开始'));
      await tester.pumpAndSettle();

      // 源码框里拿到的是**原来的内容**（不做有损反解），标记还没写进去
      final src = tester.widget<TextField>(_mdSourceField()).controller!.text;
      expect(src, contains('老笔记'));
      expect(src, isNot(contains(kMarkdownMarkerPrefix)));

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final content =
          b.t.calls.lastWhere((c) => c['method'] == 'set')['content'] as String;
      expect(content, contains(kMarkdownMarkerPrefix));
      expect(content, contains('<h1>老笔记</h1>'));
    });

    testWidgets('新建笔记也能直接走 Markdown（Note/create 的 content 带标记）', (
      tester,
    ) async {
      final b = await _boot({
        'SYNO.NoteStation.Note.create': {'object_id': 'new-1', 'ver': '0.1'},
      });
      await _pump(
        tester,
        b.container,
        const NoteEditorPage(
          notebooks: [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );

      await tester.tap(find.byTooltip('用 Markdown 编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始'));
      await tester.pumpAndSettle();

      await tester.enterText(_byHint('标题'), 'MD 新笔记');
      await tester.enterText(_mdSourceField(), '# 你好\n\n**世界**');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final call = b.t.calls.lastWhere((c) => c['method'] == 'create');
      expect(call['title'], '"MD 新笔记"');
      final content = call['content'] as String;
      expect(content, contains(kMarkdownMarkerPrefix));
      expect(content, contains('<strong>世界</strong>'));
      expect(markdownSourceFromHtml(content), '# 你好\n\n**世界**');
    });

    testWidgets('Markdown 模式下「插入图片」置灰（图片改走语法）', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Note.get': _note(
          id: 'n1',
          title: 't',
          content: markdownToNoteHtml('# t'),
        ),
      });
      await _pump(
        tester,
        b.container,
        NoteEditorPage(
          note: NoteDto(
            objectId: 'n1',
            title: 't',
            parentId: 'nb1',
            content: markdownToNoteHtml('# t'),
            hasContent: true,
            ver: '1.0',
          ),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final button = tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byIcon(Icons.add_photo_alternate_outlined),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(button.onPressed, isNull);
      expect(b.t.calls.where((c) => c['method'] == 'upload').length, 0);
    });
  });
}
