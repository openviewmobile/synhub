// NoteStation **wave4**（DSnote 对齐）离线套件。
//
// 覆盖本批新增/修正的服务端契约与 UI（证据逐字来自**官方前端明文 JS**、
// **官方 Android 反编译**与**真机复测**）：
//   * `Note.Version / list` v1 只传 `object_id`（JSON），v2 才带 `limit`+`filter`
//     —— 真机 v1 `{object_id}` 就回 4 条；**主键是 object_id，不是 id**；
//   * `Note.Version` 版本行**内部 id（version hash）不上屏**，只显示官方
//     `Info.History.Window` 的三列：时间 / 作者 / 设备；
//   * `Shortcut / set|delete` v1：`object_id` 或 `tag_id`（Gson 二次编码），
//     逐字来自 `SetShortcutOperation.java` / `DeleteShortcutOperation.java`；
//   * `FTS / search` v1：**空关键字不发请求**、结果取 root `data.matches`、
//     失败如实报错；
//   * 导出：官方 `Export.{Note,Word}` 的 `start/status/download` 契约 + 不再
//     调起外部应用 + **`finish != true` 绝不显示"已导出"**；
//   * C5：从相机/视频新建（编辑器首帧自动调起来源）。
//
// ★ 四个 falsification（红 → 原字节还原 → resh256 一致 → 绿）见 §F。
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
import 'package:synhub/src/features/notes/note_fts_search_page.dart';
import 'package:synhub/src/features/notes/note_picker.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_shortcut_page.dart';
import 'package:synhub/src/features/notes/note_view_page.dart';
import 'package:synhub/src/features/notes/note_wave4_providers.dart';
import 'package:synhub/src/features/notes/note_wave4_text.dart';
import 'package:synhub/src/features/notes/notes_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

const String kFtsApi = 'SYNO.NoteStation.FTS';
const String kShortcutApi = 'SYNO.NoteStation.Shortcut';
const String kVersionApi = 'SYNO.NoteStation.Note.Version';
const String kExportWordApi = 'SYNO.NoteStation.Export.Word';
const String kExportNoteApi = 'SYNO.NoteStation.Export.Note';

/// 真机 `SYNO.API.Info` 快照子集（wave4 用到的都在）。
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
  'SYNO.NoteStation.Shortcut': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.FTS': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
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
};

Future<NoteStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return NoteStationApi(api);
}

FakeTransport _transport(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, Map<String, dynamic>> extraTable = const {},
}) => FakeTransport(responses, {
  ...FakeTransport.table,
  ..._noteTable,
  ...extraTable,
});

Map<String, dynamic> _callOf(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

int _count(FakeTransport t, String api, String method) =>
    t.calls.where((c) => c['api'] == api && c['method'] == method).length;

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

// ---------------------------------------------------------------- UI 装配

Future<({FakeTransport t, ProviderContainer c})> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Set<String>? apis,
  Map<String, int> failures = const {},
  NoteC3Availability? availability,
  Directory? downloadDir,
  List<String>? opened,
  Duration pollInterval = Duration.zero,
  NoteLocalPicker? picker,
}) async {
  final t = _transport(responses);
  t.failures.addAll(failures);
  final api = await _api(t);
  final dir = downloadDir ?? Directory.systemTemp.createTempSync('note-w4');
  final container = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(api),
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
                  'SYNO.NoteStation.Note',
                  kShortcutApi,
                  kFtsApi,
                  kVersionApi,
                  kExportWordApi,
                  kExportNoteApi,
                },
          ),
        ),
      ),
      if (availability != null)
        noteC3AvailabilityProvider.overrideWith((ref) async => availability),
      noteC3PollIntervalProvider.overrideWithValue(pollInterval),
      noteC3DownloadDirProvider.overrideWithValue(() async => dir),
      noteC3FileWriterProvider.overrideWithValue(
        (file, bytes) async => file.writeAsBytesSync(bytes),
      ),
      if (opened != null)
        noteC3SystemOpenProvider.overrideWithValue((path) async {
          opened.add(path);
          return OpenResult(type: ResultType.done, message: 'test');
        }),
      if (picker != null) noteLocalPickerProvider.overrideWithValue(picker),
    ],
  );
  addTearDown(container.dispose);
  if (downloadDir == null) {
    addTearDown(() => dir.deleteSync(recursive: true));
  }
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
  await tester.pump(const Duration(milliseconds: 50));
}

/// 多拍几帧，让 bottom sheet / 路由动画走完（与 c3 套件的 `_settle` 同款）。
Future<void> _settle(WidgetTester tester, [int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

NoteDto _stub(String id, String title) =>
    NoteDto(objectId: id, title: title, content: '<p>正文</p>', hasContent: true);

void main() {
  // ============================================================ 服务端契约

  group('版本历史（Note.Version/list）', () {
    test('★F1 v1 只发 object_id（JSON）；id 不是参数名', () async {
      final t = _transport(
        {
          '$kVersionApi.list': {
            'count': 4,
            'total': 4,
            'versions': [
              {
                'author': 'demo_user',
                'commit_msg': <String, dynamic>{},
                'id': 1,
                'last_version': ['c1f0ecb6'],
                'mtime': 1789874506,
                'version': '7ea263b4',
              },
            ],
          },
        },
        extraTable: {
          kVersionApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
        },
      );
      final api = await _api(t);
      final rows = await api.listVersions('1028_R9e9u0SSQfyWJYplAK9h5');
      expect(rows, hasLength(1));

      final c = _callOf(t, kVersionApi, 'list');
      expect('${c['version']}', '1', reason: '能力表 maxVersion=1 → v1');
      expect(
        c['object_id'],
        '"1028_R9e9u0SSQfyWJYplAK9h5"',
        reason: '★ 真机：主键是 object_id（Gson 二次编码）',
      );
      expect(
        c.containsKey('id'),
        isFalse,
        reason: '★F1 传 id 而不是 object_id 必红（真机原判定就是漏参数）',
      );
      expect(c.containsKey('limit'), isFalse, reason: 'v1 没有 limit');
      expect(c.containsKey('filter'), isFalse, reason: 'v1 没有 filter');
    });

    test('v2 仍按官方 Web 发 limit + filter.listable', () async {
      final t = _transport({
        '$kVersionApi.list': {'versions': <dynamic>[], 'total': 0},
      });
      final api = await _api(t);
      await api.listVersions('n1');
      final c = _callOf(t, kVersionApi, 'list');
      expect('${c['version']}', '2');
      expect(c['limit'], 100);
      expect(c['filter'], '{"listable":true}');
    });
  });

  group('快捷方式写入（Shortcut/set|delete）', () {
    test('set 笔记：只发 object_id（JSON），不发 tag_id', () async {
      final t = _transport({'$kShortcutApi.set': <String, dynamic>{}});
      final api = await _api(t);
      await api.setShortcut(objectId: 'n1');

      final c = _callOf(t, kShortcutApi, 'set');
      expect('${c['version']}', '1');
      expect(c['object_id'], '"n1"');
      expect(c.containsKey('tag_id'), isFalse);
    });

    test('set 标签：发 tag_id（官方 setTagShortcut 分支）', () async {
      final t = _transport({'$kShortcutApi.set': <String, dynamic>{}});
      final api = await _api(t);
      await api.setShortcut(tagId: 'test@1028');

      final c = _callOf(t, kShortcutApi, 'set');
      expect(c['tag_id'], '"test@1028"');
      expect(c.containsKey('object_id'), isFalse);
    });

    test('delete 与 set 同参数形态', () async {
      final t = _transport({'$kShortcutApi.delete': <String, dynamic>{}});
      final api = await _api(t);
      await api.deleteShortcut(objectId: 'n1');
      final c = _callOf(t, kShortcutApi, 'delete');
      expect(c['object_id'], '"n1"');
    });

    test('两个 id 都不给 → 本地 ArgumentError（不发 114 空请求）', () async {
      final t = _transport({});
      final api = await _api(t);
      expect(() => api.setShortcut(), throwsArgumentError);
      expect(() => api.deleteShortcut(), throwsArgumentError);
      expect(_count(t, kShortcutApi, 'set'), 0);
      expect(_count(t, kShortcutApi, 'delete'), 0);
    });
  });

  group('全文检索（FTS/search）', () {
    test('★F2 空关键字：provider 直接返回空且零请求', () async {
      final t = _transport({
        '$kFtsApi.search': {'matches': <dynamic>[]},
      });
      final api = await _api(t);
      final container = ProviderContainer(
        overrides: [noteApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final rows = await container.read(noteFtsSearchProvider('   ').future);
      expect(rows, isEmpty);
      expect(_count(t, kFtsApi, 'search'), 0, reason: '★F2 空关键字仍发请求必红');
    });

    test('非空关键字：keyword 原样发出，结果取 root data.matches', () async {
      final t = _transport({
        '$kFtsApi.search': {
          'matches': [
            {'object_id': 'n1', 'title': '周会纪要', 'mtime': 1789874506},
          ],
        },
      });
      final api = await _api(t);
      final rows = await api.searchNotes(keyword: '周会');
      expect(rows.single.title, '周会纪要');
      final c = _callOf(t, kFtsApi, 'search');
      expect(c['keyword'], '周会');
    });
  });

  // ============================================================ UI

  group('版本历史 UI：内部 id 不上屏', () {
    testWidgets('只显示时间/作者/设备，不显示 version hash 与 id', (tester) async {
      final b = await _boot({
        '$kVersionApi.list': {
          'versions': [
            {
              'id': '7',
              'version': 'HASH7ea263b4',
              'author': 'demo_user',
              'mtime': 1789874506,
              'commit_msg': {'device': 'DS920+'},
            },
          ],
          'total': 1,
        },
      });
      await _pump(tester, b.c, NoteVersionPage(note: _stub('n1', '周会纪要')));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('demo_user'), findsOneWidget);
      expect(find.textContaining('DS920+'), findsOneWidget);
      expect(
        find.textContaining('HASH7ea263b4'),
        findsNothing,
        reason: 'version hash 是服务端内部标识，不上屏',
      );
      expect(find.text('7'), findsNothing, reason: '版本行 id 也不上屏');
      expect(tester.takeException(), isNull);
    });
  });

  group('★F4 入口能力位门控', () {
    testWidgets('能力表缺 Note.Version → 版本入口隐藏', (tester) async {
      final b = await _boot(
        {
          'SYNO.NoteStation.Note.get': {
            'object_id': 'n1',
            'title': '周会纪要',
            'content': '<p>正文</p>',
          },
        },
        apis: {'SYNO.NoteStation.Note', kExportWordApi, kExportNoteApi},
      );
      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byKey(const Key('note-c3-version-button')),
        findsNothing,
        reason: '★F4 能力位缺失仍显示版本入口必红',
      );
    });

    testWidgets('能力表有 Note.Version → 版本入口出现', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Note.get': {
          'object_id': 'n1',
          'title': '周会纪要',
          'content': '<p>正文</p>',
        },
      });
      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('note-c3-version-button')), findsOneWidget);
    });
  });

  group('全文检索页（FTS UI）', () {
    testWidgets('空关键字 → 提示态且零 FTS 请求；检索 0 条 → 明确空态', (tester) async {
      final b = await _boot({
        '$kFtsApi.search': {'matches': <dynamic>[]},
      });
      await _pump(tester, b.c, const NoteFtsSearchPage());
      expect(find.byKey(const Key('note-fts-prompt')), findsOneWidget);
      expect(_count(b.t, kFtsApi, 'search'), 0, reason: '★F2 UI 侧同理');

      await tester.enterText(find.byKey(const Key('note-fts-field')), '周会');
      await tester.tap(find.byKey(const Key('note-fts-submit')));
      await _settle(tester);

      expect(_count(b.t, kFtsApi, 'search'), 1);
      expect(_callOf(b.t, kFtsApi, 'search')['keyword'], '周会');
      expect(find.byKey(const Key('note-fts-empty')), findsOneWidget);
    });

    testWidgets('检索失败 → 如实错误态（不静默回落）', (tester) async {
      final b = await _boot(
        {
          '$kFtsApi.search': {'matches': <dynamic>[]},
        },
        failures: {'$kFtsApi.search': 160},
      );
      await _pump(tester, b.c, const NoteFtsSearchPage());
      await tester.enterText(find.byKey(const Key('note-fts-field')), '周会');
      await tester.tap(find.byKey(const Key('note-fts-submit')));
      await _settle(tester);

      expect(find.byKey(const Key('note-fts-error')), findsOneWidget);
      expect(find.textContaining('Note Station 权限'), findsOneWidget);
    });
  });

  group('F5 快捷方式写入 / 跳转', () {
    testWidgets('笔记页「加入快捷方式」→ Shortcut/set object_id', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Note.get': {
          'object_id': 'n1',
          'title': '周会纪要',
          'content': '<p>正文</p>',
        },
        '$kShortcutApi.list': {'offset': 0, 'total': 0},
        '$kShortcutApi.set': <String, dynamic>{},
      });
      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('note-shortcut-toggle')));
      await _settle(tester);

      final c = _callOf(b.t, kShortcutApi, 'set');
      expect(c['object_id'], '"n1"');
      expect(find.textContaining('已加入快捷方式'), findsOneWidget);
    });

    testWidgets('快捷方式页：点条目跳到笔记（items 的目标 id）', (tester) async {
      final b = await _boot({
        '$kShortcutApi.list': {
          'offset': 0,
          'total': 1,
          'shortcuts': [
            {
              'id': '1028_sn',
              'category': 'note',
              'title': '周会纪要',
              'items': ['1028_n1'],
            },
          ],
        },
        'SYNO.NoteStation.Note.get': {
          'object_id': '1028_n1',
          'title': '周会纪要',
          'content': '<p>正文</p>',
        },
      });
      await _pump(tester, b.c, const NoteShortcutPage());
      await _settle(tester);

      await tester.tap(find.text('周会纪要'));
      await _settle(tester);
      final get = _callOf(b.t, 'SYNO.NoteStation.Note', 'get');
      expect(get['object_id'], '"1028_n1"');
    });

    testWidgets('删除：取消确认 → 零请求；确认 → Shortcut/delete 目标 id', (tester) async {
      final b = await _boot({
        '$kShortcutApi.list': {
          'offset': 0,
          'total': 1,
          'shortcuts': [
            {
              'id': '1028_sn',
              'category': 'note',
              'title': '周会纪要',
              'items': ['1028_n1'],
            },
          ],
        },
        '$kShortcutApi.delete': <String, dynamic>{},
      });
      await _pump(tester, b.c, const NoteShortcutPage());
      await _settle(tester);

      await tester.tap(find.byKey(const Key('note-shortcut-delete-1028_sn')));
      await _settle(tester);
      expect(_count(b.t, kShortcutApi, 'delete'), 0, reason: '取消确认前零请求');

      await tester.tap(find.byKey(const Key('note-shortcut-delete-ok')));
      await _settle(tester);
      final del = _callOf(b.t, kShortcutApi, 'delete');
      expect(del['object_id'], '"1028_n1"', reason: '官方按目标对象 id 删');
      expect(find.textContaining('已取消快捷方式'), findsOneWidget);
    });
  });

  group('导出（官方 Export 契约 + 不谎报完成）', () {
    testWidgets('完成：start → status → download(remove=true) → 落盘，不再调起外部应用', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('note-w4-exp');
      addTearDown(() => dir.deleteSync(recursive: true));
      final opened = <String>[];
      final b = await _boot(
        {
          'SYNO.NoteStation.Note.get': {
            'object_id': 'n1',
            'title': '周会纪要',
            'content': '<p>正文</p>',
          },
          '$kExportWordApi.start': {
            'task_id': 'demo_user/NoteStation_OutputWord1',
          },
          '$kExportWordApi.status': {'finish': true, 'filename': '周会纪要.docx'},
          '$kExportWordApi.stop': <String, dynamic>{},
        },
        downloadDir: dir,
        opened: opened,
      );

      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('note-c3-export-button')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-c3-export-word')));
      await _settle(tester);

      final start = _callOf(b.t, kExportWordApi, 'start');
      expect(start['object_id'], 'n1', reason: '官方 Word start 是裸 object_id');
      expect(
        start.containsKey('timezone_offset'),
        isFalse,
        reason: '官方 exportWord 不带 timezone_offset',
      );
      final status = _callOf(b.t, kExportWordApi, 'status');
      expect(status['task_id'], 'demo_user/NoteStation_OutputWord1');
      expect(b.t.downloads.single, contains('task_id='));
      expect(b.t.downloads.single, contains('remove=true'));
      expect(File('${dir.path}/周会纪要.docx').existsSync(), isTrue);
      expect(opened, isEmpty, reason: '导出本身不得调起外部应用');
      expect(find.textContaining('已导出到'), findsOneWidget);
    });

    testWidgets('★F3 status 一直 finish=false → 绝不显示"已导出"，如实报失败', (tester) async {
      final dir = Directory.systemTemp.createTempSync('note-w4-exp2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final b = await _boot({
        'SYNO.NoteStation.Note.get': {
          'object_id': 'n1',
          'title': '周会纪要',
          'content': '<p>正文</p>',
        },
        '$kExportWordApi.start': {'task_id': 't-w'},
        '$kExportWordApi.status': {'finish': false, 'filename': 'x.docx'},
        '$kExportWordApi.stop': <String, dynamic>{},
      }, downloadDir: dir);

      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('note-c3-export-button')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-c3-export-word')));
      await _settle(tester);

      expect(
        find.textContaining('已导出到'),
        findsNothing,
        reason: '★F3 finish != true 仍显示"已导出"必红',
      );
      expect(find.textContaining('导出失败'), findsOneWidget);
    });

    test('导出子系统 114（errors.synodrive）→ 中性说明，不谎报成功', () {
      final e = DsmApiException(
        114,
        method: 'SYNO.NoteStation.Export.Word.status',
        raw: {
          'success': false,
          'error': {'code': 114},
          'errors': {'synodrive': 0},
        },
      );
      final text = describeNoteExportError(e);
      expect(text, contains('导出子系统'));
      expect(text, contains('114'));
    });
  });

  group('C5 从相机/视频新建', () {
    testWidgets('抽屉「拍照新建」→ 新建编辑器并自动调起相机来源', (tester) async {
      final seen = <NotePickSource>[];
      final b = await _boot(
        {
          'SYNO.NoteStation.Note.list': {'notes': <dynamic>[], 'total': 0},
          'SYNO.NoteStation.Notebook.list': {
            'notebooks': <dynamic>[],
            'total': 0,
          },
        },
        picker: (source) async {
          seen.add(source);
          return const <NotePickedImage>[];
        },
      );
      await _pump(tester, b.c, const NotesPage());
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byTooltip('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // wave4 的入口排在菜单末尾（不挤动既有条目），先滚到可见再点。
      await tester.ensureVisible(
        find.byKey(const Key('note-new-camera-entry')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('note-new-camera-entry')));
      await _settle(tester);

      expect(
        seen,
        contains(NotePickSource.camera),
        reason: '新建后自动调起相机（官方抽屉入口）',
      );
    });
  });

  group('文案（wave4 key / zh 兜底）', () {
    test('键都有非空中文兜底，占位符能填', () {
      expect(noteWave4(NoteWave4TextKeys.ftsTitle, '全文检索'), '全文检索');
      expect(
        noteWave4Fill(NoteWave4TextKeys.exportSaved, '已导出到 {name}', {
          'name': 'a.docx',
        }),
        '已导出到 a.docx',
      );
      expect(noteWave4(NoteWave4TextKeys.exportSubsystem, 'x'), isNotEmpty);
      expect(noteWave4(NoteWave4TextKeys.shortcutNoTarget, 'x'), isNotEmpty);
    });
  });
}
