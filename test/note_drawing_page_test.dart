// 绘图板 UI + 编辑器入口（能力位降级）的离线 widget 测试。
//
// 覆盖：
//   * 单指绘制 → 导出 PNG（saver 收到真 PNG 字节）→ pop 回 NotePickedImage；
//   * 空画布插入 → 明确提示、**不静默**、不落盘；
//   * 导出/落盘失败 → 明确错误提示、页面保留（**不静默**）；
//   * 能力位在位 → 入口可见；能力位缺失 → 入口隐藏并给原因（降级门控）。
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_drawing.dart';
import 'package:synhub/src/features/notes/note_drawing_page.dart';
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_picker.dart';
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
};

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

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

Future<ProviderContainer> _boot({
  Set<String> apis = const {
    'SYNO.NoteStation.Note',
    'SYNO.NoteStation.Notebook',
  },
  NotePaintingSaver? saver,
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._noteTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      noteApiProvider.overrideWithValue(NoteStationApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
      if (saver != null) notePaintingSaverProvider.overrideWithValue(saver),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer c,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
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
}

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('画一笔 → 插入 → saver 收到真 PNG 字节并回传文件', (tester) async {
    _wide(tester);
    Uint8List? captured;
    final c = await _boot(
      saver: (png) async {
        captured = png;
        return const NotePickedImage(
          path: '/tmp/painting.png',
          name: 'painting.png',
          mimeType: 'image/png',
        );
      },
    );
    NotePickedImage? result;
    await _pump(
      tester,
      c,
      Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await Navigator.of(ctx).push<NotePickedImage>(
                  MaterialPageRoute(
                    builder: (_) => const NoteDrawingPage(devicePixelRatio: 1),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 单指画一笔
    await tester.drag(
      find.byKey(const Key('note-drawing-canvas')),
      const Offset(80, 60),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('note-drawing-insert')));
    // `toImage`/`toByteData` 是引擎侧异步：widget 测试里必须 runAsync 才落地
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(captured, isNotNull, reason: '导出必须真的落盘');
    expect(looksLikePng(captured!), isTrue, reason: 'PNG 魔数');
    expect(result, isNotNull);
    expect(result!.mimeType, 'image/png');
    expect(find.byType(NoteDrawingPage), findsNothing, reason: '插入后应关闭绘图板');
  });

  testWidgets('空画布插入 → 明确提示，不落盘（失败不静默）', (tester) async {
    _wide(tester);
    Uint8List? captured;
    final c = await _boot(
      saver: (png) async {
        captured = png;
        return const NotePickedImage(path: '/tmp/p.png', name: 'p.png');
      },
    );
    await _pump(tester, c, const NoteDrawingPage(devicePixelRatio: 1));

    await tester.tap(find.byKey(const Key('note-drawing-insert')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('画布还是空的'), findsOneWidget);
    expect(captured, isNull, reason: '空画布不该导出');
  });

  testWidgets('导出/落盘失败 → 明确错误提示、页面保留（失败不静默）', (tester) async {
    _wide(tester);
    final c = await _boot(saver: (_) async => throw StateError('磁盘写入失败'));
    await _pump(tester, c, const NoteDrawingPage(devicePixelRatio: 1));

    await tester.drag(
      find.byKey(const Key('note-drawing-canvas')),
      const Offset(60, 40),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-drawing-insert')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('手绘导出失败'), findsOneWidget);
    expect(
      find.byType(NoteDrawingPage),
      findsOneWidget,
      reason: '失败时不能假装成功关掉页面',
    );
  });

  testWidgets('清空后插入 → 明确提示（清空真的清了模型）', (tester) async {
    _wide(tester);
    Uint8List? captured;
    final c = await _boot(
      saver: (png) async {
        captured = png;
        return const NotePickedImage(path: '/tmp/p.png', name: 'p.png');
      },
    );
    await _pump(tester, c, const NoteDrawingPage(devicePixelRatio: 1));
    await tester.drag(
      find.byKey(const Key('note-drawing-canvas')),
      const Offset(70, 70),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-drawing-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-drawing-insert')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('画布还是空的'), findsOneWidget);
    expect(captured, isNull);
  });

  group('编辑器入口 + 能力位降级', () {
    NoteDto stub() => NoteDto(
      objectId: 'n1',
      title: 'T',
      parentId: 'nb1',
      content: '<p>hi</p>',
      hasContent: true,
      ver: '1.0',
    );

    Future<void> openSheet(WidgetTester tester, ProviderContainer c) async {
      _wide(tester);
      await _pump(
        tester,
        c,
        NoteEditorPage(
          note: stub(),
          notebooks: const [NotebookDto(objectId: 'nb1', title: '工作')],
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
      await tester.pumpAndSettle();
    }

    testWidgets('能力位在位 → 手绘入口可见', (tester) async {
      final c = await _boot();
      await openSheet(tester, c);
      expect(find.byKey(const Key('note-drawing-entry')), findsOneWidget);
      expect(
        find.byKey(const Key('note-drawing-entry-unavailable')),
        findsNothing,
      );
    });

    testWidgets('能力位缺失 → 手绘入口隐藏 + 给原因（降级门控）', (tester) async {
      // 能力表里**没有** SYNO.NoteStation.Note（但模块状态仍可用）
      final c = await _boot(apis: const {'SYNO.NoteStation.Notebook'});
      await openSheet(tester, c);
      expect(find.byKey(const Key('note-drawing-entry')), findsNothing);
      final unavailable = find.byKey(
        const Key('note-drawing-entry-unavailable'),
      );
      expect(unavailable, findsOneWidget);
      expect(find.textContaining('缺少笔记附件接口'), findsOneWidget);
    });

    testWidgets('未检测（fail-open）→ 入口保留，不因不确定而隐藏', (tester) async {
      final c = await _boot(
        apis: const {}, // 空能力表 = 还没检测过
      );
      await openSheet(tester, c);
      expect(find.byKey(const Key('note-drawing-entry')), findsOneWidget);
    });
  });
}
