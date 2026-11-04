// 阅读器 **E2 第一批** 离线测试：脚注/超链接跳转、选中菜单 + 查词、
// 翻译/解释/摘要（AI 通道 A 的参数与错误态）、导出到笔记、听书状态机。
//
// 分层同 E1：
//   * 接口层/纯函数（解析、词表、TTS 状态机、笔记导出参数、prompt 拼装）；
//   * 页面层（widget）：点链接跳段与跳回、工具菜单 → 朗读/导出、
//     查词弹层命中与未命中、选中菜单按钮表。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/ai/cloud_llm_client.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/ai/ai_prompts.dart';
import 'package:synhub/src/features/ai/cloud_engine.dart';
import 'package:synhub/src/features/ai/llm_engine.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/book_dictionary.dart';
import 'package:synhub/src/features/files/book_dict_sheet.dart';
import 'package:synhub/src/features/files/book_note_export.dart';
import 'package:synhub/src/features/files/book_providers.dart';
import 'package:synhub/src/features/files/book_tts.dart';
import 'package:synhub/src/features/files/book_tts_system.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/notes/note_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

// ------------------------------------------------------------------ 测试用书

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 一本带**脚注**的 EPUB：第一章末尾有 `#fn1` 注释，第二章用跨文件链接指过来。
///
/// 没有任何目录（nav/NCX）—— 所以这里的切段**只能**来自正文里的 `<a href="#…">`，
/// 正好验证"脚注走的是同一套段内切开机制"。
Uint8List _footnoteEpub() => _zip({
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
  'OEBPS/content.opf': '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>锚点之书</dc:title><dc:creator>作者</dc:creator>
  </metadata>
  <manifest>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''',
  'OEBPS/text/ch1.xhtml': '''
<html><body><h1>第一章 正文</h1>
<p>正文里有个脚注<a href="#fn1" id="ref1">1</a>，还有 <a href="https://example.com/x">外链</a>。</p>
<p>第二段正文。</p>
<div id="fn1"><p>这是脚注内容。</p></div>
</body></html>''',
  'OEBPS/text/ch2.xhtml': '''
<html><body><h1>第二章 引用</h1>
<p>回看<a href="ch1.xhtml#fn1">注 1</a>。</p></body></html>''',
});

/// 带 FB2 脚注的最小书
Uint8List _footnoteFb2() => Uint8List.fromList(
  utf8.encode('''
<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"
             xmlns:l="http://www.w3.org/1999/xlink">
  <description><title-info><book-title>FB2 脚注</book-title></title-info></description>
  <body>
    <section><title><p>第一节</p></title>
      <p>正文带脚注<a l:href="#fn1">1</a>。</p>
      <p id="fn1">【1】FB2 的脚注文字。</p>
    </section>
  </body>
</FictionBook>'''),
);

Future<BookParseResult> _parse(String name, List<int> bytes) async =>
    parseBook(bookFormatOf(name.split('.').last), bytes);

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 4096,
  mtime: 1700000000000,
);

// ------------------------------------------------------------------ 假 TTS

class FakeTtsEngine implements TtsEngine {
  final List<String> spoken = [];
  TtsDone? _done;
  int stops = 0;
  int pauses = 0;
  int disposes = 0;

  /// 非空则模拟"引擎立刻失败"（真机：系统 TTS 没绑定）
  Object? failWith;

  /// 引擎能力探测的答案（DA200：真机没装 TTS ⇒ false）
  bool available = true;

  @override
  Future<bool> availableFor(String text) async => available;

  @override
  Future<void> speak(String text, {required TtsDone onDone}) async {
    spoken.add(text);
    if (failWith != null) {
      onDone(failWith);
      return;
    }
    _done = onDone;
  }

  /// 模拟"这一段读完了"
  void complete([Object? error]) {
    final d = _done;
    _done = null;
    d?.call(error);
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> dispose() async => disposes++;
}

// ------------------------------------------------------------------ 笔记接口

const _noteTable = {
  'SYNO.NoteStation.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

Future<NoteStationApi> _noteApi(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return NoteStationApi(api);
}

FakeTransport _noteTransport({List<String>? existingNotebooks}) {
  final t = FakeTransport({}, {...FakeTransport.table, ..._noteTable});
  final notebooks = existingNotebooks ?? <String>[];
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    switch (key) {
      case 'SYNO.NoteStation.Notebook.list':
        return {
          'notebooks': [
            for (final id in notebooks) {'object_id': id, 'title': '我的笔记本'},
          ],
        };
      case 'SYNO.NoteStation.Notebook.create':
        return {'object_id': 'nb-new'};
      case 'SYNO.NoteStation.Note.create':
        return {'object_id': 'note-1', 'ver': '1.0'};
      case 'SYNO.NoteStation.Note.set':
        return {'success': true};
    }
    return {'success': true};
  };
  return t;
}

// ------------------------------------------------------------------ 阅读页

Future<ProviderContainer> _open(
  WidgetTester tester,
  String name,
  List<int> bytes, {
  NoteStationApi? noteApi,
  TtsEngine? tts,
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table});
  t.downloadBytes = bytes;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
      if (noteApi != null) noteApiProvider.overrideWithValue(noteApi),
      if (tts != null) ttsEngineProvider.overrideWithValue(tts),
    ],
  );
  addTearDown(() async {
    c.dispose();
    await db.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: FileBookStage(entry: _entry(name), bytesUrl: 'https://nas/x'),
        ),
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
  await tester.pump(const Duration(milliseconds: 300));
  return c;
}

Future<void> _tool(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('阅读工具'));
  await tester.pumpAndSettle();
  final item = find.text(label);
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

/// 找到正文里含 [needle] 的那一个 Quill 编辑器
quill.QuillEditor _editorWith(WidgetTester tester, String needle) {
  for (final e in tester.widgetList<quill.QuillEditor>(
    find.byType(quill.QuillEditor),
  )) {
    if (e.controller.document.toPlainText().contains(needle)) return e;
  }
  fail('没找到包含「$needle」的编辑器');
}

void main() {
  // ---------------------------------------------------------------- 解析层
  group('解析层 · 脚注 / 超链接锚点', () {
    test('脚注锚点在章内切开，anchorFor 精确落到注释段', () async {
      final book = (await _parse('x.epub', _footnoteEpub())).content;
      // 第一章被 `#fn1` 切成两段 + 第二章 = 3 段（这本书没有目录）
      expect(book.chapters.length, 3);
      expect(book.toc, isEmpty, reason: '没有原书目录时 toc 仍为空');
      expect(
        book.anchors['OEBPS/text/ch1.xhtml#fn1'],
        1,
        reason: '锚点表要指向切开后的注释段',
      );
      expect(book.anchorFor('OEBPS/text/ch1.xhtml', '#fn1'), 1);
      // 切开后正文不丢：第一段有正文，第二段有注释
      expect(book.chapters[0].html, contains('正文里有个脚注'));
      expect(book.chapters[1].html, contains('这是脚注内容'));
    });

    test('跨文件链接：被指向的章也会在锚点处切开', () async {
      final book = (await _parse('x.epub', _footnoteEpub())).content;
      expect(
        book.anchorFor('OEBPS/text/ch2.xhtml', 'ch1.xhtml#fn1'),
        1,
        reason: '第二章里的跨文件链接应落到第一章的注释段',
      );
    });

    test('链接分类：外链 / 本文件锚点 / 书内跨文件', () {
      final ext = classifyBookLink('OEBPS/text/ch1.xhtml', 'https://a.b/c');
      expect(ext.kind, BookLinkKind.external);
      final mail = classifyBookLink('OEBPS/text/ch1.xhtml', 'mailto:a@b.c');
      expect(mail.kind, BookLinkKind.external);

      final anchor = classifyBookLink('OEBPS/text/ch1.xhtml', '#fn1');
      expect(anchor.kind, BookLinkKind.anchor);
      expect(anchor.path, 'OEBPS/text/ch1.xhtml');
      expect(anchor.fragment, 'fn1');

      final cross = classifyBookLink('OEBPS/text/ch2.xhtml', 'ch1.xhtml#fn1');
      expect(cross.kind, BookLinkKind.internal);
      expect(cross.path, 'OEBPS/text/ch1.xhtml');
      expect(cross.fragment, 'fn1');
    });

    test('找不到的锚点 → anchorFor 返回 null（界面据此给提示）', () async {
      final book = (await _parse('x.epub', _footnoteEpub())).content;
      expect(book.anchorFor('OEBPS/text/ch1.xhtml', '#nope'), isNull);
      // 没有锚点的纯文件链接也不算锚点
      expect(book.anchorFor('OEBPS/text/ch2.xhtml', 'ch1.xhtml'), isNull);
      // 外链永远不查锚点表
      expect(book.anchorFor('OEBPS/text/ch1.xhtml', 'https://a.b/c'), isNull);
    });

    test('FB2：保留 `<a l:href>`，脚注 id 能定位到所在段', () async {
      final book = (await _parse('x.fb2', _footnoteFb2())).content;
      expect(book.anchors['#fn1'], isNotNull);
      final html = book.chapters[book.anchors['#fn1']!].html;
      expect(html, contains('id="fn1"'));
      expect(html, contains('href="#fn1"'));
      expect(book.anchorFor('', '#fn1'), book.anchors['#fn1']);
    });

    test('内部链接目标提取：只收带 `#` 的书内链接', () {
      final targets = bookInternalLinkTargets(
        'OEBPS/text/ch1.xhtml',
        '<p><a href="#fn1">1</a> <a href="https://x.y">外</a> '
            '<a href="ch2.xhtml#s2">跨</a> <a href="ch3.xhtml">纯文件</a></p>',
      );
      expect(targets.map((e) => e.fragment).toList(), ['fn1', 's2']);
      expect(targets.map((e) => e.path).toList(), [
        'OEBPS/text/ch1.xhtml',
        'OEBPS/text/ch2.xhtml',
      ]);
    });
  });

  // ---------------------------------------------------------------- 词表
  group('内置词表 · 查词', () {
    test('大小写不敏感 + 形态还原（复数/过去式/进行时/副词）', () {
      expect(lookupWord('Books')!.word, 'book');
      expect(lookupWord('books')!.word, 'book');
      expect(lookupWord("book's")!.word, 'book');
      expect(lookupWord('running')!.word, 'run');
      expect(lookupWord('loved')!.word, 'love');
      expect(lookupWord('readers')!.word, 'reader');
    });

    test('选中一句话时取其中第一个词', () {
      expect(normalizeLookupWord('the quick brown fox'), 'the');
      expect(lookupWord('Read the book.')!.word, 'read');
      expect(normalizeLookupWord('“book,”'), 'book');
      expect(normalizeLookupWord(''), '');
    });

    test('查不到返回 null，且给出明确提示文案', () {
      expect(lookupWord('zzzznotaword'), isNull);
      expect(lookupWord('Nebuchadnezzar'), isNull);
      final t = AppTextZh();
      expect(
        t.bookDictNotFound('zzzz'),
        contains('zzzz'),
        reason: '提示里必须带上用户查的词',
      );
    });

    test('词性有中文回落也有英文译文', () {
      expect(DictPos.noun.label, '名词');
      expect(DictPos.noun.labelIn(AppTextZh()), '名词');
      expect(DictPos.noun.labelIn(AppTextEn()), 'Noun');
      expect(DictPos.verb.labelIn(AppTextEn()), 'Verb');
      // 命中词条确实带词性与释义
      final entry = lookupWord('alpha')!;
      expect(entry.phonetic, isNotEmpty);
      expect(entry.senses, isNotEmpty);
      expect(entry.senses.first.pos, DictPos.noun);
      expect(entry.senses.first.meaning, isNotEmpty);
    });

    test('词表非空且至少能覆盖常见词', () {
      expect(kBookDictionarySize, greaterThan(40));
      expect(kBookDictionary.containsKey('book'), isTrue);
      expect(kBookDictionary.containsKey('time'), isTrue);
    });
  });

  // ---------------------------------------------------------------- 听书
  group('听书 · TTS 状态机（纯 Dart）', () {
    test('play → 按段落推进，读完最后一段回到 idle', () async {
      final engine = FakeTtsEngine();
      final ctl = TtsController(
        engine: engine,
        paragraphs: const ['第一段', '第二段', '第三段'],
      );
      await ctl.play();
      expect(ctl.state, TtsPlaybackState.playing);
      expect(ctl.index, 0);
      expect(engine.spoken, ['第一段']);

      engine.complete();
      await Future<void>.delayed(Duration.zero);
      expect(ctl.index, 1);
      expect(engine.spoken, ['第一段', '第二段']);

      engine.complete();
      await Future<void>.delayed(Duration.zero);
      expect(ctl.index, 2);

      engine.complete();
      await Future<void>.delayed(Duration.zero);
      expect(ctl.state, TtsPlaybackState.idle);
      expect(ctl.index, 2, reason: '读完停在最后一段');
    });

    test('pause 停在原段；resume 从本段开头重读', () async {
      final engine = FakeTtsEngine();
      final ctl = TtsController(engine: engine, paragraphs: const ['甲段', '乙段']);
      await ctl.play();
      await ctl.pause();
      expect(ctl.state, TtsPlaybackState.paused);
      expect(engine.pauses, 1);

      // 暂停后引擎的完成回调不能偷偷推进
      engine.complete();
      await Future<void>.delayed(Duration.zero);
      expect(ctl.index, 0);
      expect(ctl.state, TtsPlaybackState.paused);

      await ctl.play(); // = resume
      expect(ctl.state, TtsPlaybackState.playing);
      expect(engine.spoken, ['甲段', '甲段'], reason: '继续 = 从本段开头重读');
    });

    test('stop 作废在途回调，不会读下一段', () async {
      final engine = FakeTtsEngine();
      final ctl = TtsController(engine: engine, paragraphs: const ['甲段', '乙段']);
      await ctl.play();
      final pending = engine._done;
      await ctl.stop();
      expect(ctl.state, TtsPlaybackState.idle);
      expect(engine.stops, 1);
      // 迟到的完成回调应被丢弃
      pending?.call(null);
      await Future<void>.delayed(Duration.zero);
      expect(engine.spoken, ['甲段']);
      expect(ctl.state, TtsPlaybackState.idle);
    });

    test('出错：回 idle 并把错误交给界面', () async {
      final engine = FakeTtsEngine();
      Object? got;
      final ctl = TtsController(
        engine: engine,
        paragraphs: const ['甲段'],
        onError: (e) => got = e,
      );
      await ctl.play();
      engine.complete('boom');
      await Future<void>.delayed(Duration.zero);
      expect(ctl.state, TtsPlaybackState.idle);
      expect('$got', contains('boom'));
    });

    test('段落切分：短碎片并进上一段', () {
      final out = ttsParagraphsOf('这是一段完整的话。\n\n12\n第二段也够长的话。');
      expect(out.length, 2);
      expect(out[0], contains('12'), reason: '页码碎片并进上一段');
      expect(out[1], '第二段也够长的话。');
      expect(ttsParagraphsOf(''), isEmpty);
    });

    test('语言判定：中文段用 zh、英文段用 en', () {
      expect(ttsLanguageFor('这是一句中文'), 'zh-CN');
      expect(ttsLanguageFor('This is English'), 'en-US');
      expect(ttsLanguageFor('中文 mixed English'), 'zh-CN');
    });
  });

  // ---------------------------------------------------------------- 导出笔记
  group('导出到笔记 · 构建器（纯函数）', () {
    BookNoteDraft draft({int? percent}) => buildBookNoteDraft(
      t: AppTextZh(),
      bookTitle: '锚点之书',
      chapterTitle: '第一章 正文',
      chapter: 0,
      chapterCount: 3,
      selection: '正文里有个脚注1。',
      note: '我的想法',
      percent: percent,
    );

    test('标题带书名与章节', () {
      final d = draft();
      expect(d.title, contains('锚点之书'));
      expect(d.title, contains('第 1 章'));
    });

    test('标签带书名 / 读书笔记 / 章节', () {
      final d = draft();
      expect(d.tags, contains('锚点之书'));
      expect(d.tags, contains('读书笔记'));
      expect(d.tags, contains('第1章'));
    });

    test('正文是 Markdown（引用原文 + 自己的话 + 出处行）', () {
      final d = draft(percent: 42);
      expect(d.markdown, startsWith('> 正文里有个脚注1。'));
      expect(d.markdown, contains('我的想法'));
      expect(d.markdown, contains('——'));
      expect(d.markdown, contains('42%'), reason: '位置标签要带上');
      expect(d.markdown, contains('共 3 章'));
      // HTML 走 Markdown 管线：可见正文 + 可无损取回的源码注释
      expect(d.html, contains('dsh-md'));
      expect(d.html, contains('<blockquote>'));
    });

    test('没有选中时也能导出（整章），署名用"无题"兜底', () {
      final d = buildBookNoteDraft(
        t: AppTextZh(),
        bookTitle: '  ',
        chapterTitle: '',
        chapter: 1,
        chapterCount: 2,
        selection: '某段正文',
      );
      expect(d.title, contains(AppTextZh().bookUntitled));
      expect(d.tags.first, AppTextZh().bookUntitled);
    });
  });

  group('导出到笔记 · 接口层', () {
    test('复用已有笔记本：Note/create 带标题/父本/正文，Note/set 打标签', () async {
      final t = _noteTransport(existingNotebooks: ['nb1']);
      final api = await _noteApi(t);
      final draft = buildBookNoteDraft(
        t: AppTextZh(),
        bookTitle: '锚点之书',
        chapterTitle: '第一章 正文',
        chapter: 0,
        chapterCount: 3,
        selection: '正文里有个脚注1。',
      );
      final result = await BookNoteExporter(api).export(draft);

      expect(result.objectId, 'note-1');
      expect(result.tagged, isTrue);
      final create = t.calls.firstWhere(
        (c) => c['method'] == 'create' && c['api'] == 'SYNO.NoteStation.Note',
      );
      expect('${create['title']}', contains('锚点之书'));
      expect(create['parent_id'], '"nb1"');
      expect('${create['content']}', contains('dsh-md'));

      final set = t.calls.firstWhere(
        (c) => c['method'] == 'set' && c['api'] == 'SYNO.NoteStation.Note',
      );
      expect('${set['tag']}', contains('锚点之书'));
      expect('${set['tag']}', contains('读书笔记'));
    });

    test('一个笔记本都没有 → 先建「读书笔记」再用', () async {
      final t = _noteTransport();
      final api = await _noteApi(t);
      final draft = buildBookNoteDraft(
        t: AppTextZh(),
        bookTitle: '锚点之书',
        chapterTitle: '第一章 正文',
        chapter: 0,
        chapterCount: 3,
        selection: 'x',
      );
      final result = await BookNoteExporter(api).export(draft);
      expect(result.notebookTitle, '读书笔记');
      final nb = t.calls.firstWhere(
        (c) =>
            c['api'] == 'SYNO.NoteStation.Notebook' && c['method'] == 'create',
      );
      expect('${nb['title']}', contains('读书笔记'));
      final create = t.calls.firstWhere(
        (c) => c['method'] == 'create' && c['api'] == 'SYNO.NoteStation.Note',
      );
      expect(create['parent_id'], '"nb-new"');
    });
  });

  // ---------------------------------------------------------------- AI 通道 A
  group('AI 通道 A · 参数拼装与错误态', () {
    test('翻译只发选中的那一段（不夹带整章）', () {
      final prompt = aiUserPrompt(
        const AiRequest(
          kind: AiTaskKind.translate,
          text: 'ONLY THIS PARAGRAPH',
          title: '锚点之书',
        ),
        language: '英文',
      );
      expect(prompt, contains('ONLY THIS PARAGRAPH'));
      expect(prompt, contains('英文'));
      expect(
        aiUserPrompt(
          const AiRequest(
            kind: AiTaskKind.explain,
            text: 'ONLY THIS PARAGRAPH',
          ),
        ),
        contains('ONLY THIS PARAGRAPH'),
      );
    });

    test('云端没配 key/地址 → 可读错误（不会静默）', () async {
      final engine = CloudLlmEngine(configOf: () => null);
      await expectLater(
        engine.generate(const LlmPrompt(system: 's', user: 'u')),
        emitsError(
          predicate<Object>(
            (e) => '$e' == AppTextZh().aiCloudNotConfigured,
            '错误文案要说人话',
          ),
        ),
      );
    });

    test('网络超时 → 可读文案（含主机名）', () {
      final msg = describeCloudError(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionTimeout,
          error: 'timeout',
        ),
      );
      expect(msg, contains('超时'));
    });

    test('连接失败 → 可读文案', () {
      final msg = describeCloudError(
        DioException(
          requestOptions: RequestOptions(path: 'https://api.example.com/v1'),
          type: DioExceptionType.connectionError,
          error: 'SocketException',
        ),
      );
      expect(msg, contains('api.example.com'));
    });
  });

  // ---------------------------------------------------------------- 选中菜单
  group('选中菜单按钮表', () {
    test('六项都在：翻译/解释/查词/朗读/导出到笔记/复制', () {
      final labels = bookSelectionMenuItems(
        t: AppTextZh(),
        text: 'alpha',
        onAiSelection: (_, _) {},
        onSelectAction: (_, _) {},
        onCopy: () {},
      ).map((e) => e.label).toList();
      expect(labels, ['翻译', '解释', '查词', '朗读', '导出到笔记', '复制']);
    });

    test('点每一项走对应的回调（带选中文本）', () {
      AiTaskKind? aiKind;
      BookSelectionAction? action;
      var copied = false;
      final items = bookSelectionMenuItems(
        t: AppTextZh(),
        text: 'alpha',
        onAiSelection: (k, s) {
          aiKind = k;
          expect(s, 'alpha');
        },
        onSelectAction: (a, s) {
          action = a;
          expect(s, 'alpha');
        },
        onCopy: () => copied = true,
      );
      items[0].onPressed!();
      expect(aiKind, AiTaskKind.translate);
      items[1].onPressed!();
      expect(aiKind, AiTaskKind.explain);
      items[2].onPressed!();
      expect(action, BookSelectionAction.lookup);
      items[3].onPressed!();
      expect(action, BookSelectionAction.speak);
      items[4].onPressed!();
      expect(action, BookSelectionAction.exportNote);
      items[5].onPressed!();
      expect(copied, isTrue);
    });

    test('没选中时只剩复制', () {
      final items = bookSelectionMenuItems(
        t: AppTextZh(),
        text: '',
        onAiSelection: (_, _) {},
        onSelectAction: (_, _) {},
        onCopy: () {},
      );
      expect(items.map((e) => e.label).toList(), ['复制']);
    });
  });

  // ---------------------------------------------------------------- 查词弹层
  group('查词弹层（widget）', () {
    Future<void> pumpSheet(WidgetTester tester, String word) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(body: BookDictionarySheet(word: word)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('命中：显示原形、音标、词性与释义', (tester) async {
      await pumpSheet(tester, 'Books');
      expect(find.byKey(const Key('book-dict-word')), findsOneWidget);
      expect(find.text('book'), findsOneWidget);
      expect(find.text('/bʊk/'), findsOneWidget);
      expect(find.text('名词'), findsOneWidget);
      expect(find.textContaining('书'), findsWidgets);
      expect(find.byKey(const Key('book-dict-notfound')), findsNothing);
    });

    testWidgets('未命中：给明确提示 + 引导走 AI 解释', (tester) async {
      await pumpSheet(tester, 'zzzznotaword');
      expect(find.byKey(const Key('book-dict-notfound')), findsOneWidget);
      expect(find.textContaining('zzzznotaword'), findsOneWidget);
      expect(find.textContaining('AI'), findsWidgets);
    });
  });

  // ---------------------------------------------------------------- 阅读页
  group('阅读页 E2（widget）', () {
    testWidgets('点脚注链接：跳到注释段，并能「返回原处」', (tester) async {
      await _open(tester, 'x.epub', _footnoteEpub());
      expect(find.textContaining('第 1/3 章'), findsOneWidget);
      expect(find.byKey(const Key('book-link-back')), findsNothing);

      final editor = _editorWith(tester, '正文里有个脚注');
      // ⚠️ 真机踩过的坑：quill 默认会用 `LinkValidator` 把 `#fn1` 改写成
      // `https://#fn1`（内链全变外链）。必须原样透传 —— 这条离线用例守住它。
      expect(editor.config.transformLink!('#fn1'), '#fn1');
      expect(editor.config.transformLink!('ch1.xhtml#fn1'), 'ch1.xhtml#fn1');
      expect(
        editor.config.transformLink!('https://example.com/x'),
        'https://example.com/x',
      );
      editor.config.onLaunchUrl!('#fn1');
      await tester.pumpAndSettle();

      // 跳到注释那一段（第 2 段），并且出现"返回原处"
      expect(find.textContaining('第 2/3 章'), findsOneWidget);
      expect(find.byKey(const Key('book-link-back')), findsOneWidget);

      await tester.tap(find.byKey(const Key('book-link-back')));
      await tester.pumpAndSettle();
      expect(find.textContaining('第 1/3 章'), findsOneWidget);
      expect(find.byKey(const Key('book-link-back')), findsNothing);
    });

    testWidgets('点外链：测试环境不启动浏览器，给可读提示', (tester) async {
      await _open(tester, 'x.epub', _footnoteEpub());
      final editor = _editorWith(tester, '正文里有个脚注');
      editor.config.onLaunchUrl!('https://example.com/x');
      await tester.pumpAndSettle();
      expect(find.textContaining('打不开这个链接'), findsOneWidget);
      // 不该换章
      expect(find.textContaining('第 1/3 章'), findsOneWidget);
    });

    testWidgets('点找不到的锚点：提示"不在书里"，不跳错地方', (tester) async {
      await _open(tester, 'x.epub', _footnoteEpub());
      final editor = _editorWith(tester, '正文里有个脚注');
      editor.config.onLaunchUrl!('#missing');
      await tester.pumpAndSettle();
      expect(find.textContaining('不在书里'), findsOneWidget);
      expect(find.textContaining('第 1/3 章'), findsOneWidget);
    });

    testWidgets('工具菜单 → 朗读：假引擎驱动，弹层按段落推进', (tester) async {
      final tts = FakeTtsEngine();
      await _open(tester, 'x.epub', _footnoteEpub(), tts: tts);
      await _tool(tester, '朗读');
      expect(find.byKey(const Key('book-tts-state')), findsOneWidget);
      expect(find.textContaining('第 1/'), findsWidgets);

      await tester.tap(find.byKey(const Key('book-tts-play')));
      await tester.pumpAndSettle();
      expect(tts.spoken, isNotEmpty);

      tts.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('第 2/'), findsWidgets);

      await tester.tap(find.byKey(const Key('book-tts-pause')));
      await tester.pumpAndSettle();
      expect(tts.pauses, 1);
    });

    testWidgets('引擎不可用：弹层说「这台设备没有可用的语音引擎」，不假装在念', (tester) async {
      final tts = FakeTtsEngine()..failWith = kTtsEngineUnavailable;
      await _open(tester, 'x.epub', _footnoteEpub(), tts: tts);
      await _tool(tester, '朗读');
      await tester.tap(find.byKey(const Key('book-tts-play')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-tts-error')), findsOneWidget);
      expect(find.text('这台设备没有可用的语音引擎'), findsWidgets);
      // 关键：不能停在"暂停"按钮上（那就是"假装在念"）
      expect(find.byKey(const Key('book-tts-pause')), findsNothing);
      expect(find.byKey(const Key('book-tts-play')), findsOneWidget);
    });

    testWidgets('DA200 引擎探测为"不可用"：进层就说清楚，且按钮点不动', (tester) async {
      final tts = FakeTtsEngine()..available = false;
      await _open(tester, 'x.epub', _footnoteEpub(), tts: tts);
      await _tool(tester, '朗读');
      await tester.pumpAndSettle();
      // 进层即提示（不用点一次才知道）
      expect(find.byKey(const Key('book-tts-no-engine')), findsOneWidget);
      expect(find.byKey(const Key('book-tts-error')), findsNothing);
      final btn = tester.widget<FilledButton>(
        find.byKey(const Key('book-tts-play')),
      );
      expect(btn.onPressed, isNull, reason: '引擎不可用 ⇒ 不许给能点的按钮');
      // 点也点不动：一次都没念
      await tester.tap(find.byKey(const Key('book-tts-play')));
      await tester.pumpAndSettle();
      expect(tts.spoken, isEmpty);
      expect(find.byKey(const Key('book-tts-pause')), findsNothing);
    });

    testWidgets('DA200 引擎可用：按钮可点、且不显示"没有语音引擎"', (tester) async {
      final tts = FakeTtsEngine();
      await _open(tester, 'x.epub', _footnoteEpub(), tts: tts);
      await _tool(tester, '朗读');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-tts-no-engine')), findsNothing);
      final btn = tester.widget<FilledButton>(
        find.byKey(const Key('book-tts-play')),
      );
      expect(btn.onPressed, isNotNull);
    });

    testWidgets('工具菜单 → 导出到笔记：请求里带书名/章节/标签', (tester) async {
      final noteTransport = _noteTransport(existingNotebooks: ['nb1']);
      final noteApi = await _noteApi(noteTransport);
      await _open(tester, 'x.epub', _footnoteEpub(), noteApi: noteApi);
      await _tool(tester, '导出到笔记');
      await tester.pumpAndSettle();

      final create = noteTransport.calls.firstWhere(
        (c) => c['api'] == 'SYNO.NoteStation.Note' && c['method'] == 'create',
      );
      expect('${create['title']}', contains('锚点之书'));
      expect('${create['title']}', contains('第 1 章'));
      expect('${create['content']}', contains('正文'));
      expect(find.textContaining('已存到'), findsOneWidget);

      final set = noteTransport.calls.firstWhere(
        (c) => c['method'] == 'set' && c['api'] == 'SYNO.NoteStation.Note',
      );
      expect('${set['tag']}', contains('锚点之书'));
    });

    testWidgets('没连 NAS（笔记接口为 null）→ 导出给"未连接"提示', (tester) async {
      await _open(tester, 'x.epub', _footnoteEpub());
      await _tool(tester, '导出到笔记');
      await tester.pumpAndSettle();
      expect(find.textContaining('未连接'), findsWidgets);
    });
  });
}
