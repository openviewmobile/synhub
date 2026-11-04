// ★★★ 第 129 轮 / 台账 C2 + G6。
//
// C2 官方：`camera` / `new_photo`，选图四路 = 相册 / 拍照 / 本机文件 / NAS
//         （`note_picker.dart` 的 `NotePickSource`，NPC 面板逐项 pop 对应值）。
// G6 官方：编辑器 `menu_editor` 的 `find_previous`/`find_next`
//         ⇒ 我们用 Quill 自带查找（`showSearchButton: true`），
//         这里断言**查找按钮真的在工具栏里**。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations, QuillToolbarSearchButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<NotePickSource> picked;
  late ProviderContainer container;

  Future<void> boot() async {
    const ppChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ppChannel, (call) async => '/tmp');
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ppChannel, null),
    );
    picked = <NotePickSource>[];
    final db = ChatDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        chatDatabaseProvider.overrideWithValue(db),
        noteLocalPickerProvider.overrideWith((ref) => (source) async {
          picked.add(source);
          return const <NotePickedImage>[];
        }),
      ],
    );
    addTearDown(container.dispose);
  }

  Future<void> openPickerSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const NoteEditorPage(
            notebooks: [NotebookDto(objectId: 'nb1', title: '工作')],
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
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
    await tester.pumpAndSettle();
  }

  testWidgets('★ C2：相册 / 本机文件两路走注入的选择器（来源值正确）', (tester) async {
    await boot();

    for (final (label, source) in const [
      ('从相册选', NotePickSource.gallery),
      ('从文件选', NotePickSource.file),
    ]) {
      await openPickerSheet(tester);
      expect(find.text(label), findsOneWidget, reason: '面板里必须有"$label"');
      // ★ r491：行卡换成 `DesignRowTile` 后行高变了，必须先滚到可见再点，
      //   否则点到的是**隔壁那一行**（真机同理：手指落在两行之间就会点错）。
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        picked.last,
        source,
        reason: '"$label" 必须对应 $source（否则真机上会走错通道）',
      );
    }
  });

  testWidgets('★ C2：面板四路齐全（相册/拍照/本机文件/NAS，含官方四项）',
      (tester) async {
    await boot();
    await openPickerSheet(tester);
    for (final label in const ['从相册选', '拍一张', '从文件选', '从 NAS 选']) {
      expect(find.text(label), findsOneWidget, reason: '入口"$label"必须存在');
    }
    // NAS 走的是 `pickNasImages`（有自己的浏览页），不是本地选择器 ——
    // 这里只断言入口在、枚举值在；浏览页由 `note_nas_picker.dart` 负责。
    expect(NotePickSource.values, containsAll(<NotePickSource>[
      NotePickSource.gallery,
      NotePickSource.camera,
      NotePickSource.file,
      NotePickSource.nas,
    ]));
  });

  testWidgets('★ G6：编辑器工具栏里有查找按钮（find_previous/next 的入口）',
      (tester) async {
    await boot();
    await openPickerSheet(tester); // 复用同一棵树；先把编辑器起起来
    // 关掉选图面板，回到编辑器
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      find.byType(QuillToolbarSearchButton),
      findsOneWidget,
      reason: '官方编辑器有查找/上下一处；入口没了等于功能没了',
    );
  });
}
