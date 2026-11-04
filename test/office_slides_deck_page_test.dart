// O3：`.oslides` **页面层**集成用例。
//
// 两件事必须证明：
//   ① `OfficeSlidesPage` 拿到真实 PPTX（`deckLoader` 注入 = 生产里
//      `drive.downloadUrl` + `DsmWebApi.getBytes` 的同一份字节）时，渲染的是
//      **16:9 幻灯片画布**（不是文字流），并且页面上**没有**任何开发者文案；
//   ② 拿不到 PPTX 时回落到既有 OFile 渲染，并给一行**用户语言**的说明
//      （绝不静默空白、绝不出现"本批/从简/只读预览"）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_model.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/features/files/office_viewer_page.dart';
import 'package:synhub/src/features/office/office_slides_page.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_write_gate.dart';

/// 最小假后端：只读渲染只需 `snapshot` + `gate`；会话建不起来也**不挡渲染**
/// （页面会把它如实标成 `sessionNote`，这正是"写权限不确定不能挡读"的设计）。
class _FakeBackend implements OfficeSlidesBackend {
  @override
  Future<OfficeWriteGateInputs> loadGate() async => const OfficeWriteGateInputs(
    canWrite: true,
    canComment: true,
    schemaMobile: 2003,
  );

  @override
  Future<OfficeSlidesSnapshot> loadSnapshot() async => OfficeSlidesSnapshot(
    sections: _sections(),
    version: 7,
    raw: const <String, dynamic>{'ntype': 'presentation'},
  );

  @override
  Future<OfficeSlidesSession> openSession() async =>
      throw StateError('测试里不建协作会话');

  @override
  Future<void> closeSession(OfficeSlidesSession session) async {}
}

Uint8List _fixture(String name) =>
    File('test/fixtures/office_slides_o3/$name').readAsBytesSync();

late OSlidesDeck _deck;

/// 最小 `@C_text/*` section 字典（OFile 回落路径用；结构与 `oslides_model.dart`
/// 的注释一致：`content.data.attrs` = `{schema,type,cx,cy}`）。
Map<String, Object?> _sections() => <String, Object?>{
  'content': <String, Object?>{
    'version': 7,
    'data': <String, Object?>{
      'type': 'doc',
      'attrs': <String, Object?>{
        'schema': 13,
        'type': 'presentation',
        'cx': 960,
        'cy': 540,
      },
      'content': <Object?>[
        <String, Object?>{
          'type': 'slide_container',
          'attrs': <String, Object?>{},
          'content': <Object?>[
            <String, Object?>{
              'type': 'slide',
              'attrs': <String, Object?>{'id': 'S1', 'is_visible': true},
              'content': <Object?>[
                <String, Object?>{
                  'type': 'slide_content_container',
                  'attrs': <String, Object?>{},
                  'content': <Object?>[
                    <String, Object?>{
                      'type': 'paragraph',
                      'attrs': <String, Object?>{},
                      'content': <Object?>[
                        <String, Object?>{
                          'type': 'text',
                          'text': 'O3-FALLBACK-TEXT',
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
    },
  },
  'index': <String, Object?>{'schemaVersion': 13},
};

Widget _pageHost(Future<OSlidesDeck?> Function()? loader) => ProviderScope(
  child: MaterialApp(theme: AppTheme.dark(), 
    home: OfficeSlidesPage(
      request: const OfficeSlidesRequest(
        fileId: 'FILEID',
        name: 'Technology.oslides',
      ),
      backend: _FakeBackend(),
      deckLoader: loader,
    ),
  ),
);

void _expectNoDeveloperWording() {
  for (final bad in const [
    '版式从简',
    '本批',
    '只读预览',
    '不支持编辑',
    '仅展示每页的文本与图片',
    '从简',
    '见下方标记',
  ]) {
    expect(find.textContaining(bad), findsNothing, reason: bad);
  }
}

void main() {
  setUpAll(() {
    _deck = OSlidesDeck.parse(_fixture('technology.oslides'))!;
  });

  group('OfficeSlidesPage：拿到真实 PPTX', () {
    testWidgets('渲染 16:9 幻灯片画布 + 页码指示，而不是文字流', (tester) async {
      await tester.pumpWidget(_pageHost(() async => _deck));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-deck')), findsOneWidget);
      expect(find.byKey(const Key('office-slides-canvas-0')), findsOneWidget);
      expect(
        find.byKey(const Key('office-slides-page-indicator')),
        findsOneWidget,
      );
      expect(find.text('1 / 15'), findsOneWidget);
      final box = tester.renderObject<RenderBox>(
        find.byKey(const Key('office-slides-canvas-0')),
      );
      expect(box.size.width / box.size.height, closeTo(16 / 9, 0.02));
    });

    testWidgets('形状按真实坐标定位（slide1 标题来自版式继承）', (tester) async {
      await tester.pumpWidget(_pageHost(() async => _deck));
      await tester.pumpAndSettle();
      final z = _deck.slides[0].shapes.indexWhere(
        (s) => s.placeholderType == 'title',
      );
      final p = tester.widget<Positioned>(
        find.byKey(Key('office-slides-shape-0-$z')),
      );
      expect(p.left, closeTo(540000 / 9525, 0.01));
      expect(p.top, closeTo(2093190 / 9525, 0.01));
    });

    testWidgets('页码随左右滑动变化', (tester) async {
      await tester.pumpWidget(_pageHost(() async => _deck));
      await tester.pumpAndSettle();
      await tester.fling(
        find.byKey(const Key('office-slides-pages')),
        const Offset(-400, 0),
        1200,
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 15'), findsOneWidget);
    });

    testWidgets('没有任何开发者文案', (tester) async {
      await tester.pumpWidget(_pageHost(() async => _deck));
      await tester.pumpAndSettle();
      _expectNoDeveloperWording();
    });
  });

  group('OfficeSlidesPage：拿不到 PPTX（回落 OFile）', () {
    testWidgets('回落既有文本渲染 + 一行用户语言说明', (tester) async {
      await tester.pumpWidget(_pageHost(() async => null));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-deck')), findsNothing);
      expect(
        find.byKey(const Key('office-slides-deck-fallback-note')),
        findsOneWidget,
      );
      expect(find.textContaining('版式没有读到'), findsOneWidget);
      // 回落路径仍把 OFile 里的文字显示出来（不静默空白）。
      expect(find.byKey(const Key('office-slides-view')), findsOneWidget);
      _expectNoDeveloperWording();
    });

    testWidgets('deckLoader 抛异常也不崩（等于没读到）', (tester) async {
      await tester.pumpWidget(
        _pageHost(() async => throw StateError('drive down')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-deck-fallback-note')),
        findsOneWidget,
      );
    });
  });

  group('OSlidesView（统一预览里的 .oslides 分支）', () {
    testWidgets('有 deck → 真实幻灯片画布', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OSlidesView(
              presentation: OSlidesPresentation.fromSections(_sections()),
              deck: _deck,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('office-slides-deck')), findsOneWidget);
      expect(find.text('1 / 15'), findsOneWidget);
    });

    testWidgets('没有 deck → 16:9 文本画布 + 页码指示（不空白、无工程措辞）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OSlidesView(
              presentation: OSlidesPresentation.fromSections(_sections()),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('office-slides-fallback')), findsOneWidget);
      final canvas = find.byKey(const Key('office-slides-fallback-canvas-0'));
      expect(canvas, findsOneWidget);
      final box = tester.renderObject<RenderBox>(canvas);
      expect(box.size.width / box.size.height, closeTo(16 / 9, 0.001));
      expect(find.textContaining('O3-FALLBACK-TEXT'), findsOneWidget);
      expect(find.text('1 / 1'), findsOneWidget);
      _expectNoDeveloperWording();
    });
  });

  group('备注（真实文件备注为空）', () {
    testWidgets('deck 的备注在模型里为空而不是 null', (tester) async {
      for (final slide in _deck.slides) {
        expect(slide.notes, isA<String>());
        expect(slide.notes.trim(), isEmpty);
      }
    });
  });
}
