// ★★ ④笔记 第 241 轮：**J8「从其它 App 接收分享（剪藏 / 图片）」** 的补证用例。
//
// J8 的接收端是 `ShareIntentHost`（挂在频道列表页外层）+ `note_share_clip.dart`。
// 此前只有一个用例走"URL 分享 → 剪藏到笔记"（`note_gaps_wave2_test`），
// **纯文本**与**图片/文件**两条分支、以及"没有可用笔记本/未连接"的失败口径
// 都没有断言 ⇒ 本轮补齐（官方 DS note 的 `SEND */*` 目标正是这三类载荷）。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/chat/share_intent.dart';
import 'package:synhub/src/features/notes/note_providers.dart'
    show notebooksProvider, noteApiProvider;
import 'package:synhub/src/features/notes/note_share_clip.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _noteTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 4},
  'SYNO.NoteStation.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

ShareIntentData _share({
  String text = '',
  String subject = '',
  String mime = 'text/plain',
  List<ShareIntentFile> files = const [],
}) => ShareIntentData(
  action: 'android.intent.action.SEND',
  mimeType: mime,
  text: text,
  subject: subject,
  files: files,
);

void main() {
  group('J8 剪藏 · 纯函数口径', () {
    test('默认落点：预设笔记本优先，否则第一条；没有则 null（不猜）', () {
      const preset = NotebookDto(objectId: 'nb-p', title: '我的笔记本', preset: true);
      const plain = NotebookDto(objectId: 'nb-1', title: '工作');
      expect(defaultNotebookIdForClip(const [plain, preset]), 'nb-p');
      expect(defaultNotebookIdForClip(const [plain]), 'nb-1');
      expect(defaultNotebookIdForClip(const []), isNull);
    });

    test('文本里取第一条 http(s) URL；没有则 null', () {
      expect(firstUrlIn('看这个 https://a.b/c 和 http://d.e'), 'https://a.b/c');
      expect(firstUrlIn('没有链接'), isNull);
      expect(firstUrlIn('ftp://x'), isNull, reason: '只认 http(s)');
    });

    test('正文 HTML 转义：& < > 都要转（官方 content 是 HTML）', () {
      expect(escapeNoteHtml('a&b<c>d'), 'a&amp;b&lt;c&gt;d');
    });
  });

  group('J8 剪藏 · 三分支端到端（走真 API 链路）', () {
    late ProviderContainer container;
    late WidgetRef captured;
    late FakeTransport t;

    Future<void> boot(Map<String, Map<String, dynamic>> responses) async {
      t = FakeTransport(responses, {...FakeTransport.table, ..._noteTable});
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      container = ProviderContainer(
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
    }

    testWidgets('① 纯文本（无 URL）→ Note/create，正文是转义后的 <p>，标题取 subject', (
      tester,
    ) async {
      await boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb-1', 'title': '工作', 'preset': true},
          ],
        },
        'SYNO.NoteStation.Note.create': {'object_id': 'n-1', 'ver': '1.0'},
      });
      await _captureRef(tester, container, (ref) => captured = ref);

      final id = await clipSharedPayloadToNote(
        captured,
        _share(text: '第一行 & 第二行\n<b>别当 HTML</b>', subject: '标题'),
      );
      expect(id, 'n-1');
      final create = t.calls.lastWhere((c) => c['method'] == 'create');
      expect(create['api'], 'SYNO.NoteStation.Note');
      expect(create['title'], '"标题"');
      expect(create['parent_id'], '"nb-1"');
      final content = '${create['content']}';
      expect(content, contains('<p>'));
      expect(content, contains('&amp;'), reason: '& 必须转义');
      expect(content, contains('&lt;b&gt;'), reason: '<b> 必须转义，不能变标签');
      expect(
        t.calls.any((c) => c['method'] == 'set' && c['files'] != null),
        isFalse,
        reason: '无附件时不该发 multipart',
      );
    });

    testWidgets('② URL 分享 → 走网页剪藏（capability 无 Ghost ⇒ 回退 Note/create v2）', (
      tester,
    ) async {
      await boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb-1', 'title': '工作', 'preset': true},
          ],
        },
        'SYNO.NoteStation.Note.create': {'object_id': 'n-2', 'ver': '1.0'},
      });
      await _captureRef(tester, container, (ref) => captured = ref);

      await clipSharedPayloadToNote(
        captured,
        _share(text: '看看 https://example.com/news 这篇', subject: '页面标题'),
      );
      final create = t.calls.lastWhere((c) => c['method'] == 'create');
      expect(create['title'], '"页面标题"');
      expect(create['clipper_url'], '"https://example.com/news"');
      expect(create['clipper_mode'], isNotNull, reason: '剪藏必须带 mode');
      expect(
        '${create['clipper_user_agent']}',
        contains('Chrome'),
        reason: '官方 ClipperService 的默认 UA',
      );
    });

    testWidgets('③ 图片分享 → Note/create + Note/set multipart，图片进正文（ref+convert）', (
      tester,
    ) async {
      await boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb-1', 'title': '工作', 'preset': true},
          ],
        },
        'SYNO.NoteStation.Note.create': {'object_id': 'n-3', 'ver': '1.0'},
        'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
      });
      await _captureRef(tester, container, (ref) => captured = ref);

      await clipSharedPayloadToNote(
        captured,
        _share(
          text: '照片说明',
          mime: 'image/png',
          files: const [
            ShareIntentFile(path: '/tmp/a.png', name: 'a.png', mime: 'image/png'),
          ],
        ),
      );
      final upload = t.calls.lastWhere((c) => c['files'] != null);
      expect(upload['api'], 'SYNO.NoteStation.Note');
      expect(upload['method'], 'set');
      expect(upload['files'], ['${_javaHash('a.png')}:a.png']);
      final att = _attachments(upload);
      expect(att.single['convert'], isTrue, reason: '图片要服务端转缩略图');
      expect(
        '${upload['content']}',
        contains('ref='),
        reason: '图片进正文 ⇒ content 里必须带 <img ref>',
      );
    });

    testWidgets('③b 非图片文件 → 同样 multipart，但 ref 为空、convert=false', (tester) async {
      await boot({
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': [
            {'object_id': 'nb-1', 'title': '工作', 'preset': true},
          ],
        },
        'SYNO.NoteStation.Note.create': {'object_id': 'n-4', 'ver': '1.0'},
        'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
      });
      await _captureRef(tester, container, (ref) => captured = ref);

      await clipSharedPayloadToNote(
        captured,
        _share(
          mime: 'application/pdf',
          files: const [
            ShareIntentFile(
              path: '/tmp/r.pdf',
              name: 'r.pdf',
              mime: 'application/pdf',
            ),
          ],
        ),
      );
      final upload = t.calls.lastWhere((c) => c['files'] != null);
      final att = _attachments(upload);
      // ⚠️ `ref` 由上传层兜底生成（base64(ts+name)），**非图片也会有一个**；
      //    真正的分界是 ①`convert=false`（不要求服务端转缩略图）
      //    ②正文里**没有**指向它的 `<img ref>`（即不进正文）。
      expect(att.single['convert'], isFalse);
      expect(att.single['format'], 'raw');
      final content = '${upload['content']}';
      expect(
        content.contains('ref='),
        isFalse,
        reason: '非图片不进正文（官方也是纯附件）',
      );
    });

    testWidgets('④ 没有可用笔记本 ⇒ 明确异常（不静默建到别处）', (tester) async {
      await boot({
        'SYNO.NoteStation.Notebook.list': {'notebooks': <dynamic>[]},
      });
      await _captureRef(tester, container, (ref) => captured = ref);
      await expectLater(
        clipSharedPayloadToNote(captured, _share(text: 'x')),
        throwsA(isA<NoteShareClipException>()),
      );
      expect(
        t.calls.any((c) => c['method'] == 'create'),
        isFalse,
        reason: '没有落点就不许发 create',
      );
    });

    testWidgets('⑤ API 未就绪（未连接）⇒ 明确异常', (tester) async {
      container = ProviderContainer(
        overrides: [
          noteApiProvider.overrideWithValue(null),
          chatDatabaseProvider.overrideWith((ref) {
            final db = ChatDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return db;
          }),
        ],
      );
      addTearDown(container.dispose);
      await _captureRef(tester, container, (ref) => captured = ref);
      await expectLater(
        clipSharedPayloadToNote(captured, _share(text: 'x')),
        throwsA(isA<NoteShareClipException>()),
      );
    });
  });

  group('J8 剪藏 · notebooksProvider 兜底', () {
    testWidgets('笔记本列表拉取失败 ⇒ 当"没有可用笔记本"处理（不崩）', (tester) async {
      final t = FakeTransport({
        'SYNO.NoteStation.Notebook.list': {'notebooks': <dynamic>[]},
      }, {...FakeTransport.table, ..._noteTable});
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final container = ProviderContainer(
        overrides: [
          noteApiProvider.overrideWithValue(NoteStationApi(api)),
          notebooksProvider.overrideWith((ref) async {
            throw StateError('offline');
          }),
        ],
      );
      addTearDown(container.dispose);
      late WidgetRef captured;
      await _captureRef(tester, container, (ref) => captured = ref);
      await expectLater(
        clipSharedPayloadToNote(captured, _share(text: 'x')),
        throwsA(isA<NoteShareClipException>()),
      );
    });
  });
}

/// 把一个 `ProviderContainer` 装进 widget 树以拿到真 `WidgetRef`（剪藏入口要它）。
Future<void> _captureRef(
  WidgetTester tester,
  ProviderContainer container,
  void Function(WidgetRef) onRef,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Consumer(
          builder: (ctx, ref, _) {
            onRef(ref);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pump();
}

List<Map<String, dynamic>> _attachments(Map<String, dynamic> call) {
  final decoded = jsonDecode(call['attachment'] as String) as List;
  return decoded.cast<Map<String, dynamic>>();
}

int _javaHash(String s) {
  var h = 0;
  for (final code in s.codeUnits) {
    h = (31 * h + code) & 0xFFFFFFFF;
    if (h >= 0x80000000) h -= 0x100000000;
  }
  return h;
}
