// ★★ ④笔记 第 240 轮：**C3「任意文件附件」**的补证用例。
//
// C3 的口径：**非图片**文件走附件通道（官方同一批 `attachment[]`），
// 但**不进正文**（不像图片那样插 embed）；上传时 `convert:false`
// （非图片不需要服务端生成缩略图）。
//
// 此前只有"图片进正文"的用例（`note_widgets_test`），"普通文件"这一支没有断言
// ⇒ 本轮补上：入口 → pending → 保存时上传字段与 `convert` 标志。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;

import 'package:synhub/src/core/theme/app_theme.dart' show AppTheme;
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_picker.dart';
import 'package:synhub/src/features/notes/note_providers.dart'
    show noteApiProvider;

import 'support/chat_harness.dart' show FakeTransport;



/// 与 `note_widgets_test` 同款的笔记能力表（缺了它 `discover` 拿不到方法版本，
/// 保存链路会静默失败 —— 240 轮踩到）。
const _noteTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 4},
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
  'SYNO.NoteStation.Tag': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
};

Future<void> _pumpEditor(WidgetTester tester, ProviderContainer container) async {
  // 编辑器工具栏很长（800x600 默认画布下按钮会跑到 x=1427 之外、tap 打不中）
  // ⇒ 给一个够宽的画布（240 轮实测）。
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        // ★ 真实主题 + quill 自己的本地化：缺任一都会在编辑页抛异常
        //（`baseStyle.color!` / `FlutterQuillLocalizations` 未找到）
        theme: AppTheme.dark(),
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
        home: const NoteEditorPage(
          notebooks: [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('C3：选普通文件 → 进"待上传附件"，不进正文；保存时 convert=false', (tester) async {
    final t = FakeTransport(const {
      'SYNO.NoteStation.Note.create': {'object_id': 'new-1'},
      'SYNO.NoteStation.Note.set': {'data': <dynamic>[]},
    }, {...FakeTransport.table, ..._noteTable});
    final api = DsmWebApi(t);
    await api.discover();
    await api.login(account: 'a', password: 'b');
    final db = ChatDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [
        chatDatabaseProvider.overrideWithValue(db),
        // ★ 必须显式给 api：测试容器里没有登录会话，noteApiProvider 会是 null，
        //   保存就会静默失败（240 轮踩到 "Bad state: No element"）
        noteApiProvider.overrideWithValue(NoteStationApi(api)),
        // 假的文件选择器：给一个**非图片**文件
        noteFilePickerProvider.overrideWithValue(
          () async => [
            const NotePickedImage(
              path: '/tmp/报表.xlsx',
              name: '报表.xlsx',
              mimeType: 'application/vnd.ms-excel',
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);

    await _pumpEditor(tester, container);

    await tester.tap(find.byKey(const Key('note-toolbar-attachment')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 编辑区里**不出现图片 embed**（普通文件不进正文）
    expect(find.byType(Image), findsNothing, reason: 'C3：非图片不进正文');

    await tester.enterText(find.byType(TextField).first, '带文件');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final upload = t.calls.lastWhere((c) => c['files'] != null);
    expect(upload['api'], 'SYNO.NoteStation.Note');
    expect(upload['method'], 'set');
    expect(upload['files'], [
      '${_javaHash('报表.xlsx')}:报表.xlsx',
    ], reason: 'multipart 字段名 = Java hashCode（官方口径）');

    final uploads =
        (jsonDecode(upload['attachment'] as String) as List).cast<Map>();
    // 官方口径：`attachment[].name` 是 multipart 字段名（Java hashCode），
    // 真文件名编码在 `ref`（base64）里 —— 与非图片"原样上传"一致。
    final entry = uploads.singleWhere(
      (m) => m['name'] == '${_javaHash('报表.xlsx')}',
    );
    expect(entry['action'], 'create');
    expect(entry['format'], 'raw', reason: 'C3：普通文件按原始格式上传');
    expect(
      entry['convert'],
      isFalse,
      reason: 'C3：非图片不要求服务端转缩略图',
    );
  });

  testWidgets('C3：选择器抛错 ⇒ 如实提示、不产生附件、不崩', (tester) async {
    final t = FakeTransport(const {
    }, {...FakeTransport.table, ..._noteTable});
    final api = DsmWebApi(t);
    await api.discover();
    await api.login(account: 'a', password: 'b');
    final db = ChatDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        chatDatabaseProvider.overrideWithValue(db),
        noteApiProvider.overrideWithValue(NoteStationApi(api)),
        noteFilePickerProvider.overrideWithValue(
          () async => throw StateError('picker broke'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await _pumpEditor(tester, container);
    await tester.tap(find.byKey(const Key('note-toolbar-attachment')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SnackBar), findsOneWidget, reason: '失败不静默');
  });
}

/// 与官方 multipart 字段名一致的 Java `String.hashCode`
int _javaHash(String s) {
  var h = 0;
  for (final code in s.codeUnits) {
    h = (31 * h + code) & 0xFFFFFFFF;
    if (h >= 0x80000000) h -= 0x100000000;
  }
  return h;
}
