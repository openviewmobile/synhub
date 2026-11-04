// C3（NoteStation 补齐）页面级离线测试：导出 / 导入 / 版本回滚 / 网页剪藏。
//
// 验收口径（每条特性都要覆盖）：
//   ① 成功（假回包）
//   ② `105` → 无权限文案
//   ③ `119` → 会话提示、**入口保留**（绝不隐藏模块）
//   ④ 能力位缺失 → **只隐藏该入口**（`partial`，笔记列表照常渲染）
//   ⑤ 危险操作（回滚 / 导入）取消确认 → **零请求**
//
// 全部走 `FakeTransport`，不碰网络、不碰设备。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart' show OpenResult, ResultType;
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_c3_actions.dart';
import 'package:synhub/src/features/notes/note_c3_pages.dart';
import 'package:synhub/src/features/notes/note_c3_providers.dart';
import 'package:synhub/src/features/notes/note_c3_text.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_view_page.dart';
import 'package:synhub/src/features/notes/notes_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

// ---------------------------------------------------------------- 固定数据

/// NoteStation 的**必需**能力位（模块在不在就看它）
const _requiredApis = {'SYNO.NoteStation.Note', 'SYNO.NoteStation.Notebook'};

/// C3 全部可选能力位（导出/导入/版本）
const _allC3Apis = {
  kNoteVersionApi,
  kNoteExportWordApi,
  kNoteExportNoteApi,
  kNoteExportNotebookApi,
  kNoteImportEnexApi,
  kNoteImportNotebookApi,
  kNoteImportEvernoteApi,
};

const _noteTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  // 官方剪藏**优先**走 Ghost v2（[E2] ApiNSNoteGhost / ClipperService）
  'SYNO.NoteStation.Note.Ghost': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
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
  'SYNO.NoteStation.Export.Word': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Export.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Export.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Import.Enex': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Import.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Import.Evernote': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// "这台 NAS 上有哪些 API" —— 必需 + C3 可选
const _presentApis = {..._requiredApis, ..._allC3Apis};

NoteDto _stub(String id, String title, {String content = ''}) => NoteDto(
  objectId: id,
  title: title,
  parentId: 'nb1',
  content: content,
  hasContent: content.isNotEmpty,
  ver: '1.0',
);

Map<String, dynamic> _note(String id, String title) => {
  'object_id': id,
  'title': title,
  'parent_id': 'nb1',
  'content': '<p>正文</p>',
  'brief': '摘要',
  'mtime': 1700000000000,
  'ver': '1.0',
};

/// 默认回包：足够 NotesPage / NoteViewPage / 导出 / 导入 / 版本跑起来
Map<String, Map<String, dynamic>> _baseResponses({
  bool versionFinish = true,
  bool importFinish = true,
}) => {
  'SYNO.NoteStation.Notebook.list': {
    'notebooks': [
      {'object_id': 'nb1', 'title': '工作', 'ver': '1.0'},
    ],
    'total': 1,
  },
  'SYNO.NoteStation.Note.list': {
    'notes': [_note('n1', '周会纪要')],
    'total': 1,
  },
  'SYNO.NoteStation.Note.get': {
    'object_id': 'n1',
    'title': '周会纪要',
    'content': '<p>正文</p>',
    'ver': '1.0',
  },
  'SYNO.NoteStation.Note.create': {'object_id': 'clip-1', 'ver': '1.0'},
  'SYNO.NoteStation.Note.Version.list': {
    'versions': [
      {
        'id': 'v1',
        'version': '1.1',
        'author': 'u',
        'mtime': 1700000000000,
        'commit_msg': {'device': 'DS920+'},
      },
    ],
    'total': 1,
  },
  'SYNO.NoteStation.Note.Version.restore': <String, dynamic>{},
  'SYNO.NoteStation.Export.Word.start': {'task_id': 't-w'},
  'SYNO.NoteStation.Export.Word.status': {
    'finish': versionFinish,
    'filename': '周会纪要.docx',
  },
  'SYNO.NoteStation.Export.Note.start': {'task_id': 't-n'},
  'SYNO.NoteStation.Export.Note.status': {
    'finish': versionFinish,
    'filename': '周会纪要.nsx',
  },
  'SYNO.NoteStation.Export.Word.stop': <String, dynamic>{},
  'SYNO.NoteStation.Note.Version.stop': <String, dynamic>{},
  'SYNO.NoteStation.Import.Notebook.start': {'task_id': 'i-1'},
  'SYNO.NoteStation.Import.Notebook.status': {
    'finish': importFinish,
    'data': {'current': 3, 'total': 3},
  },
  'SYNO.NoteStation.Import.Notebook.stop': <String, dynamic>{},
  'SYNO.NoteStation.Import.Enex.start': {'task_id': 'i-2'},
  'SYNO.NoteStation.Import.Enex.status': {
    'finish': importFinish,
    'data': {'current': 1, 'total': 1},
  },
  'SYNO.NoteStation.Import.Enex.stop': <String, dynamic>{},
  // 探针（能力位在位时会被打一枪）
  'SYNO.NoteStation.Export.Notebook.status': {'finish': true},
  'SYNO.NoteStation.Import.Evernote.get_status': {
    'token': 7,
    'notebook_left': 0,
    'notebook_count': 1,
    'note_left': 0,
    'note_count': 1,
  },
};

// ---------------------------------------------------------------- 装配

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

/// 一个"检测过"的 Note 能力快照
ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.note
              ? classifyApiTable(kServiceRegistry[StationService.note]!, apis)
              : AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 1, 1),
    );

const _allFeatures = {
  NoteC3Feature.version,
  NoteC3Feature.exportWord,
  NoteC3Feature.exportNote,
  NoteC3Feature.exportNotebook,
  NoteC3Feature.importEnex,
  NoteC3Feature.importNotebook,
  NoteC3Feature.importEvernote,
  NoteC3Feature.clipper,
};

Future<({FakeTransport t, ProviderContainer c})> _boot({
  Map<String, Map<String, dynamic>>? responses,
  Map<String, int> failures = const {},
  Set<String> apis = _presentApis,
  NoteC3Availability? availability,
  NoteArchivePicker? picker,
  Directory? downloadDir,
  List<String>? opened,
  List<Uri>? openedUrls,
  Duration pollInterval = Duration.zero,
  Map<String, Map<String, dynamic>>? noteTable,
}) async {
  final t = FakeTransport(responses ?? _baseResponses(), {
    ...FakeTransport.table,
    ...(noteTable ?? _noteTable),
  });
  t.failures.addAll(failures);
  t.downloadBytes = utf8.encode('DOCX-BYTES');
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');

  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      noteApiProvider.overrideWithValue(NoteStationApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
      if (availability != null)
        noteC3AvailabilityProvider.overrideWith((ref) async => availability),
      noteC3PollIntervalProvider.overrideWithValue(pollInterval),
      if (picker != null) noteArchivePickerProvider.overrideWithValue(picker),
      if (downloadDir != null)
        noteC3DownloadDirProvider.overrideWithValue(() async => downloadDir),
      // FakeAsync 下异步 I/O 不会在 pump 之间落地 → 测试里同步写
      noteC3FileWriterProvider.overrideWithValue(
        (file, bytes) async => file.writeAsBytesSync(bytes),
      ),
      if (opened != null)
        noteC3SystemOpenProvider.overrideWithValue((path) async {
          opened.add(path);
          return OpenResult(type: ResultType.done, message: 'test');
        }),
      if (openedUrls != null)
        noteUrlOpenerProvider.overrideWithValue((url) async {
          openedUrls.add(url);
          return true;
        }),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  return (t: t, c: c);
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
  await _settle(tester);
}

/// 探针/动作都是串行的，多 pump 几次让它们全部落地
Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

int _count(FakeTransport t, String api, String method) =>
    t.calls.where((c) => c['api'] == api && c['method'] == method).length;

bool _touchedVersionRestore(FakeTransport t) =>
    _count(t, kNoteVersionApi, 'restore') > 0;

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await _settle(tester);
}

/// 菜单项可能超出可视区域（`PopupMenuButton` 内部是滚动列表）→ 先滚到可见再点
Future<void> _tapMenuItem(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await _settle(tester);
  await tester.tap(f);
  await _settle(tester);
}

void main() {
  // -------------------------------------------------------------- 入口显隐

  group('入口显隐（能力位 / 105 / 119）', () {
    test('能力位全在 → 八个入口全可见', () async {
      final b = await _boot();
      final a = await b.c.read(noteC3AvailabilityProvider.future);
      expect(a.visible, containsAll(_allFeatures));
      expect(a.denied, isEmpty);
      expect(a.sessionExpired, isFalse);
    });

    test('只缺 Export.Word → 只有它不可见（partial，模块不隐藏）', () async {
      final b = await _boot(
        apis: _presentApis.difference({kNoteExportWordApi}),
      );
      final a = await b.c.read(noteC3AvailabilityProvider.future);
      expect(a.shows(NoteC3Feature.exportWord), isFalse);
      expect(a.shows(NoteC3Feature.exportNote), isTrue, reason: '别的导出还在');
      expect(a.shows(NoteC3Feature.version), isTrue);
      expect(a.shows(NoteC3Feature.clipper), isTrue, reason: '剪藏只依赖必需的 Note 位');
      expect(
        _count(b.t, kNoteExportWordApi, 'status'),
        0,
        reason: '能力位缺失就不该打探针',
      );
    });

    test('探针 105 → 该入口 denied（不隐藏模块的其他入口）', () async {
      final b = await _boot(failures: {'$kNoteExportWordApi.status': 105});
      final a = await b.c.read(noteC3AvailabilityProvider.future);
      expect(a.shows(NoteC3Feature.exportWord), isFalse);
      expect(a.isDenied(NoteC3Feature.exportWord), isTrue);
      expect(a.shows(NoteC3Feature.exportNote), isTrue);
      expect(a.sessionExpired, isFalse);
    });

    test('探针 119 → 会话提示，但八个入口一个都不少', () async {
      final b = await _boot(failures: {'$kNoteExportWordApi.status': 119});
      final a = await b.c.read(noteC3AvailabilityProvider.future);
      expect(a.sessionExpired, isTrue);
      expect(a.shows(NoteC3Feature.exportWord), isTrue, reason: '绝不隐藏');
      expect(a.visible, containsAll(_allFeatures));
    });

    testWidgets('能力位缺失：笔记列表照常渲染，只少了导入入口', (tester) async {
      final b = await _boot(
        apis: _presentApis.difference({
          kNoteImportEnexApi,
          kNoteImportNotebookApi,
          kNoteImportEvernoteApi,
        }),
      );
      await _pump(tester, b.c, const NotesPage());
      expect(find.text('周会纪要'), findsOneWidget, reason: '模块本身还在');
      await _openMenu(tester);
      expect(find.byKey(const Key('note-c3-import-entry')), findsNothing);
      expect(
        find.byKey(const Key('note-c3-clip-entry')),
        findsOneWidget,
        reason: '剪藏不受导入能力位影响',
      );
    });
  });

  // -------------------------------------------------------------- 导出

  group('导出（Export.Word / Export.Note）', () {
    testWidgets('成功：start → status → download → 落盘（wave4 起不再调起外部应用）', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('note-c3-exp');
      addTearDown(() => dir.deleteSync(recursive: true));
      final opened = <String>[];
      final b = await _boot(downloadDir: dir, opened: opened);

      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.tap(find.byKey(const Key('note-c3-export-button')));
      await _settle(tester);
      expect(find.byKey(const Key('note-c3-export-word')), findsOneWidget);
      expect(find.byKey(const Key('note-c3-export-note')), findsOneWidget);

      await tester.tap(find.byKey(const Key('note-c3-export-word')));
      await _settle(tester, 20);

      expect(_count(b.t, kNoteExportWordApi, 'start'), 1);
      expect(
        b.t.calls
            .where(
              (c) =>
                  c['api'] == kNoteExportWordApi &&
                  c['method'] == 'status' &&
                  c['task_id'] == 't-w',
            )
            .length,
        1,
        reason: '导出流程自己轮询了一次（探针那次 task_id 是空串）',
      );
      expect(b.t.downloads.single, contains('task_id=t-w'));
      final file = File('${dir.path}/周会纪要.docx');
      expect(file.existsSync(), isTrue, reason: '以服务端 filename 落盘');
      expect(file.readAsStringSync(), 'DOCX-BYTES');
      // ★ wave4：导出**不调起外部应用**（用户明确要求本机测试不要弹
      //   Preview/QuickTime）——只落盘，`SystemOpen` 一次都不该被调。
      expect(opened, isEmpty, reason: '导出本身不得调起外部应用');
      expect(find.textContaining('已导出到'), findsOneWidget);
    });

    testWidgets('.nsx 导出走 Export.Note', (tester) async {
      final dir = Directory.systemTemp.createTempSync('note-c3-exp2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final b = await _boot(downloadDir: dir);
      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.tap(find.byKey(const Key('note-c3-export-button')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-c3-export-note')));
      await _settle(tester, 20);
      expect(_count(b.t, kNoteExportNoteApi, 'start'), 1);
      expect(File('${dir.path}/周会纪要.nsx').existsSync(), isTrue);
    });

    testWidgets('105：提示无权限，不落盘', (tester) async {
      final dir = Directory.systemTemp.createTempSync('note-c3-exp3');
      addTearDown(() => dir.deleteSync(recursive: true));
      final b = await _boot(
        downloadDir: dir,
        // 入口可见（availability 由页面 watch 的真实 provider 给），但 start 被拒
        failures: {'$kNoteExportWordApi.start': 105},
      );
      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.tap(find.byKey(const Key('note-c3-export-button')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-c3-export-word')));
      await _settle(tester, 20);
      expect(find.textContaining('没有权限'), findsOneWidget);
      expect(dir.listSync(), isEmpty);
    });

    testWidgets('能力位缺失：NoteViewPage 没有导出按钮', (tester) async {
      final b = await _boot(
        apis: _presentApis.difference({kNoteExportWordApi, kNoteExportNoteApi}),
      );
      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      expect(find.byKey(const Key('note-c3-export-button')), findsNothing);
      expect(
        find.byKey(const Key('note-c3-version-button')),
        findsOneWidget,
        reason: '只缺导出的能力位，版本入口必须还在（partial）',
      );
    });
  });

  // -------------------------------------------------------------- 版本

  group('版本历史（Note.Version）', () {
    testWidgets('列表 → 回滚取消 → 零请求；确认 → restore 带 ver', (tester) async {
      final b = await _boot();
      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.tap(find.byKey(const Key('note-c3-version-button')));
      await _settle(tester, 20);
      expect(find.text('版本历史'), findsOneWidget);
      expect(find.textContaining('DS920+'), findsOneWidget);

      // ⑤ 取消 → 零请求
      await tester.tap(find.byKey(const Key('note-c3-restore-1.1')));
      await _settle(tester);
      expect(find.byKey(const Key('note-c3-restore-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('note-c3-restore-cancel')));
      await _settle(tester, 20);
      expect(_touchedVersionRestore(b.t), isFalse, reason: '★ 取消 → 零请求');

      // ① 确认 → 真的发 restore
      await tester.tap(find.byKey(const Key('note-c3-restore-1.1')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-c3-restore-ok')));
      await _settle(tester, 20);
      expect(_count(b.t, kNoteVersionApi, 'restore'), 1);
      final call = b.t.calls.lastWhere((c) => c['method'] == 'restore');
      expect(call['ver'], '"1.1"');
      expect(find.textContaining('已恢复'), findsOneWidget);
    });

    testWidgets('105：列表打开报无权限文案', (tester) async {
      final b = await _boot(failures: {'$kNoteVersionApi.list': 105});
      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.tap(find.byKey(const Key('note-c3-version-button')));
      await _settle(tester, 20);
      expect(find.textContaining('没有权限'), findsOneWidget);
    });

    testWidgets('版本预览：Note/get 带 ver，正文用同一渲染路径', (tester) async {
      final b = await _boot();
      await _pump(
        tester,
        b.c,
        NoteVersionPreviewPage(
          note: _stub('n1', '周会纪要'),
          version: const NoteC3Version(version: '1.1'),
        ),
      );
      await _settle(tester, 20);
      expect(find.textContaining('正文', findRichText: true), findsWidgets);
      final call = b.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.NoteStation.Note' && c['method'] == 'get',
      );
      expect(call['ver'], '"1.1"');
    });
  });

  // -------------------------------------------------------------- 导入

  group('导入（.nsx / .enex）', () {
    testWidgets('取消确认 → 零请求（★ 危险操作）', (tester) async {
      final dir = Directory.systemTemp.createTempSync('note-c3-imp');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/a.nsx')..writeAsStringSync('x');
      final b = await _boot(
        picker: ({required List<String> allowedExtensions}) async =>
            (path: f.path, name: 'a.nsx'),
      );
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-import-entry');
      expect(find.byKey(const Key('note-c3-import-nsx')), findsOneWidget);
      expect(find.byKey(const Key('note-c3-import-enex')), findsOneWidget);

      await tester.tap(find.byKey(const Key('note-c3-import-nsx')));
      await _settle(tester, 20);
      expect(find.byKey(const Key('note-c3-import-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('note-c3-import-cancel')));
      await _settle(tester, 20);
      expect(
        _count(b.t, kNoteImportNotebookApi, 'start'),
        0,
        reason: '★ 取消 → 零请求（探针打的是 status，不算）',
      );
      expect(_count(b.t, kNoteImportEnexApi, 'start'), 0);
    });

    testWidgets('确认 → multipart 上传 + 轮询 status + 完成提示', (tester) async {
      final dir = Directory.systemTemp.createTempSync('note-c3-imp2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/a.nsx')..writeAsStringSync('x');
      final b = await _boot(
        picker: ({required List<String> allowedExtensions}) async =>
            (path: f.path, name: 'a.nsx'),
      );
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-import-entry');
      await tester.tap(find.byKey(const Key('note-c3-import-nsx')));
      await _settle(tester, 20);
      await tester.tap(find.byKey(const Key('note-c3-import-ok')));
      await _settle(tester, 30);

      expect(_count(b.t, kNoteImportNotebookApi, 'start'), 1);
      expect(_count(b.t, kNoteImportNotebookApi, 'status'), greaterThan(0));
      expect(find.text('导入完成'), findsOneWidget);
    });

    testWidgets('导入中点「取消导入」→ 调 Import.Notebook/stop + 已取消提示', (tester) async {
      final dir = Directory.systemTemp.createTempSync('note-c3-imp4');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/a.nsx')..writeAsStringSync('x');
      final b = await _boot(
        // status 一直说"没完"，好让我们在轮询中间点取消
        responses: _baseResponses(importFinish: false),
        // 轮询间隔要非 0：否则 250 次轮询会在同一批微任务里跑完直接超时
        pollInterval: const Duration(milliseconds: 50),
        picker: ({required List<String> allowedExtensions}) async =>
            (path: f.path, name: 'a.nsx'),
      );
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-import-entry');
      await tester.tap(find.byKey(const Key('note-c3-import-nsx')));
      await _settle(tester, 20);
      await tester.tap(find.byKey(const Key('note-c3-import-ok')));
      await _settle(tester, 8);
      await tester.tap(find.byKey(const Key('note-c3-progress-cancel')));
      await _settle(tester, 20);
      expect(_count(b.t, kNoteImportNotebookApi, 'stop'), 1);
      expect(find.text('已取消'), findsOneWidget);
    });

    testWidgets('105：start 被拒 → 无权限文案', (tester) async {
      final dir = Directory.systemTemp.createTempSync('note-c3-imp3');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/a.enex')..writeAsStringSync('x');
      final b = await _boot(
        failures: {'$kNoteImportEnexApi.start': 105},
        picker: ({required List<String> allowedExtensions}) async =>
            (path: f.path, name: 'a.enex'),
      );
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-import-entry');
      await tester.tap(find.byKey(const Key('note-c3-import-enex')));
      await _settle(tester, 20);
      await tester.tap(find.byKey(const Key('note-c3-import-ok')));
      await _settle(tester, 30);
      expect(find.textContaining('没有权限'), findsOneWidget);
    });

    testWidgets('Evernote 入口 → 打开账号导入页', (tester) async {
      final b = await _boot();
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-import-entry');
      await tester.tap(find.byKey(const Key('note-c3-import-evernote')));
      await _settle(tester, 20);
      expect(find.byKey(const Key('note-c3-evernote-auth')), findsOneWidget);
      expect(find.byKey(const Key('note-c3-evernote-prepare')), findsOneWidget);
      // 打开就拉了 get_status（探针那次 + 页面这次）
      expect(_count(b.t, kNoteImportEvernoteApi, 'get_status'), greaterThan(0));
    });

    testWidgets('Evernote 授权：真的打开系统浏览器（审计 §6.3 的夸大修正）', (tester) async {
      final urls = <Uri>[];
      final b = await _boot(openedUrls: urls);
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-import-entry');
      await tester.tap(find.byKey(const Key('note-c3-import-evernote')));
      await _settle(tester, 20);

      await tester.tap(find.byKey(const Key('note-c3-evernote-auth')));
      await _settle(tester, 20);
      // 授权页 URL 来自 `Import.Evernote/get_oauth_url`
      expect(urls, hasLength(1));
      expect('${urls.single}', contains('get_oauth_url'));
      expect(find.textContaining('已在浏览器打开'), findsOneWidget);
    });

    testWidgets('Evernote 合并同名笔记本：开关真的传给 add_import_task', (tester) async {
      final b = await _boot(
        responses: {
          ..._baseResponses(),
          'SYNO.NoteStation.Import.Evernote.prepare_notebooks':
              <String, dynamic>{},
          'SYNO.NoteStation.Import.Evernote.prepare_notebooks_status': {
            'finish': true,
          },
          'SYNO.NoteStation.Import.Evernote.list_notebooks': {
            'notebooks': [
              {'guid': 'g1', 'name': '工作', 'stack': 'Stack'},
            ],
          },
          'SYNO.NoteStation.Import.Evernote.add_import_task':
              <String, dynamic>{},
          'SYNO.NoteStation.Import.Evernote.import': <String, dynamic>{},
          'SYNO.NoteStation.Import.Evernote.import_lock': {'lock': true},
        },
      );
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-import-entry');
      await tester.tap(find.byKey(const Key('note-c3-import-evernote')));
      await _settle(tester, 20);

      // lock 展示条（原来根本不显示）
      expect(find.byKey(const Key('note-c3-evernote-lock')), findsOneWidget);
      await tester.tap(find.byKey(const Key('note-c3-evernote-prepare')));
      await _settle(tester, 20);
      expect(find.byKey(const Key('note-c3-evernote-nb-g1')), findsOneWidget);

      // 默认 false
      await tester.tap(find.byKey(const Key('note-c3-evernote-nb-g1')));
      await _settle(tester, 20);
      var c = b.t.calls.lastWhere((c) => c['method'] == 'add_import_task');
      expect(c['notebook_guid'], '"g1"', reason: '官方 Gson 二次编码');
      expect(c['merge_notebook'], 'false');

      // 打开开关 → true
      await tester.tap(find.byKey(const Key('note-c3-evernote-merge')));
      await _settle(tester, 10);
      await tester.tap(find.byKey(const Key('note-c3-evernote-nb-g1')));
      await _settle(tester, 20);
      c = b.t.calls.lastWhere((c) => c['method'] == 'add_import_task');
      expect(c['merge_notebook'], 'true');
    });
  });

  // -------------------------------------------------------------- 笔记本导出

  group('笔记本导出到 NAS（Export.Notebook）', () {
    testWidgets('目标目录为空 → 报错且零请求', (tester) async {
      final b = await _boot();
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-export-notebook-entry');
      expect(
        find.byKey(const Key('note-c3-notebook-export-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('note-c3-notebook-export-ok')));
      await _settle(tester, 20);
      expect(
        find.byKey(const Key('note-c3-notebook-export-error')),
        findsOneWidget,
      );
      expect(_count(b.t, kNoteExportNotebookApi, 'start'), 0);
    });

    testWidgets('填了目录 → start(dest/save_config/export_todo) + 完成提示', (
      tester,
    ) async {
      final b = await _boot();
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-export-notebook-entry');
      await tester.enterText(
        find.byKey(const Key('note-c3-notebook-export-dest')),
        '/notes',
      );
      await tester.tap(find.byKey(const Key('note-c3-notebook-export-config')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-c3-notebook-export-ok')));
      await _settle(tester, 30);
      final c = b.t.calls.lastWhere(
        (c) => c['api'] == kNoteExportNotebookApi && c['method'] == 'start',
      );
      expect(c['object_id'], 'nb1');
      expect(c['dest'], '/notes');
      expect(c['save_config'], true);
      expect(c['export_todo'], false);
      expect(find.text('已导出到 NAS 目录'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------- 网页剪藏

  group('网页剪藏（Web Clipper）', () {
    testWidgets('非法 URL → 报错且零请求', (tester) async {
      final b = await _boot();
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-clip-entry');
      await tester.enterText(
        find.byKey(const Key('note-c3-clip-url')),
        'ftp://bad',
      );
      await tester.tap(find.byKey(const Key('note-c3-clip-ok')));
      await _settle(tester, 20);
      expect(find.byKey(const Key('note-c3-clip-error')), findsOneWidget);
      expect(_count(b.t, 'SYNO.NoteStation.Note', 'create'), 0);
    });

    testWidgets('合法 URL → Ghost/create v2（官方优先路径，不发 source_url）', (
      tester,
    ) async {
      final b = await _boot();
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-clip-entry');
      await tester.enterText(
        find.byKey(const Key('note-c3-clip-url')),
        'https://example.com/a',
      );
      await tester.enterText(
        find.byKey(const Key('note-c3-clip-name')),
        '一篇文章',
      );
      await tester.tap(find.byKey(const Key('note-c3-clip-ok')));
      await _settle(tester, 30);
      // 官方 `ClipperService.createNoteByURL`：Ghost 支持时**不发** Note/create
      expect(_count(b.t, 'SYNO.NoteStation.Note', 'create'), 0);
      final c = b.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.NoteStation.Note.Ghost',
      );
      expect(c['method'], 'create');
      expect(c['version'], '2');
      expect(c['title'], '"一篇文章"');
      expect(c['parent_id'], '"nb1"');
      expect(c['clipper_url'], '"https://example.com/a"');
      // 官方枚举：`simplepage` / `fullpage`（设置 clipper_retrieve_type=simplified）
      expect(c['clipper_mode'], '"simplepage"');
      // 官方剪藏**不发** source_url（审计 U8）；正文也由服务端抓，不发 content
      expect(c.containsKey('source_url'), isFalse);
      expect(c.containsKey('content'), isFalse);
      // Ghost 的 commit_msg 只有 device（没有 listable）
      expect(c['commit_msg'], '{"device":"Flutter"}');
      // 官方 Chrome/40 UA
      expect('${c['clipper_user_agent']}', contains('Chrome/40.0.2214.89'));
    });

    testWidgets('Ghost 不可用 → 回退 Note/create v2（同参数集合）', (tester) async {
      final b = await _boot(
        noteTable: {..._noteTable}..remove('SYNO.NoteStation.Note.Ghost'),
      );
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-clip-entry');
      await tester.enterText(
        find.byKey(const Key('note-c3-clip-url')),
        'https://example.com/b',
      );
      await tester.tap(find.byKey(const Key('note-c3-clip-ok')));
      await _settle(tester, 30);
      final c = b.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.NoteStation.Note' && c['method'] == 'create',
      );
      expect(c['version'], '2', reason: 'ClipperService 回退时写死 v2');
      expect(c['clipper_mode'], '"simplepage"');
      expect(c.containsKey('source_url'), isFalse);
    });

    testWidgets('选「完整网页」→ clipper_mode=fullpage', (tester) async {
      final b = await _boot();
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      await _tapMenuItem(tester, 'note-c3-clip-entry');
      await tester.enterText(
        find.byKey(const Key('note-c3-clip-url')),
        'https://example.com/c',
      );
      // SegmentedButton 的第二段「完整网页」
      await tester.tap(find.text('完整网页'));
      await _settle(tester, 10);
      await tester.tap(find.byKey(const Key('note-c3-clip-ok')));
      await _settle(tester, 30);
      final c = b.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.NoteStation.Note.Ghost',
      );
      expect(c['clipper_mode'], '"fullpage"');
    });

    testWidgets('能力位缺失：入口隐藏（但笔记列表还在）', (tester) async {
      final b = await _boot(
        apis: _presentApis
            .difference({
              kNoteImportEnexApi,
              kNoteImportNotebookApi,
              kNoteImportEvernoteApi,
            })
            .difference({kNoteExportWordApi}),
      );
      await _pump(tester, b.c, const NotesPage());
      expect(find.text('周会纪要'), findsOneWidget);
      await _openMenu(tester);
      expect(find.byKey(const Key('note-c3-clip-entry')), findsOneWidget);
    });

    testWidgets('119：会话提示、入口仍在', (tester) async {
      final b = await _boot(failures: {'$kNoteExportWordApi.status': 119});
      await _pump(tester, b.c, const NotesPage());
      await _openMenu(tester);
      expect(find.byKey(const Key('note-c3-clip-entry')), findsOneWidget);
      expect(find.byKey(const Key('note-c3-import-entry')), findsOneWidget);
    });
  });

  // -------------------------------------------------------------- 文案

  group('文案（noteC3 键 / zh 兜底）', () {
    test('键都有非空中文兜底，占位符能填', () {
      expect(noteC3(NoteC3TextKeys.exportTitle, '导出笔记'), '导出笔记');
      expect(
        noteC3Fill(NoteC3TextKeys.exportOpened, '已导出并打开 {name}', {
          'name': 'a.docx',
        }),
        '已导出并打开 a.docx',
      );
      expect(noteC3SessionText(), isNotEmpty);
      expect(noteC3NoPermissionText(), isNotEmpty);
      expect(isValidClipUrl('https://a'), isTrue);
      expect(isValidClipUrl('http://a'), isTrue);
      expect(isValidClipUrl('ftp://a'), isFalse);
      expect(isValidClipUrl('https://'), isTrue, reason: '官方只判前 4 个字符');
    });
  });
}
