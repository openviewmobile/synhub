// Office C′ 编辑器 UI 批 1 —— 只读渲染器（schema 驱动）离线测试。
//
// 夹具全部是已提交的真机证据：
//   * test/fixtures/office_collab/dart_fetched_doc_v1.json（编辑器 fetch v1）
//   * test/fixtures/office_collab/snapshot_doc_pre.json（@C_text/content Import 态）
//   * test/fixtures/office_collab/transform_vectors.json（54 份文档，含 mark）
//
// 无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/doc_schema.dart';
import 'package:synhub/src/features/office/office_doc_edit.dart';
import 'package:synhub/src/features/office/office_doc_image.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/features/office/office_doc_view.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/office_collab/$name').readAsStringSync())
        as Map<String, Object?>;

Widget _host(Object? doc, [OfficeDocRenderReport? report]) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(
    body: OfficeDocView(doc: doc, report: report),
  ),
);

/// 在夹具里找一个带 [markName] mark 的 text 节点（真机证据）。
///
/// mark 分布在 `docs.docMarked`（strong/font_size）与 `vectors[*]` 的 step
/// slice 里（em/underline/color/font_size），所以这里对整份夹具递归。
Map<String, Object?>? _findMarkedText(
  Map<String, Object?> fixture,
  String markName,
) {
  Map<String, Object?>? found;
  void walk(Object? n) {
    if (found != null) return;
    if (n is Map) {
      final map = n.cast<String, Object?>();
      if (map['type'] == 'text') {
        final marks = map['marks'];
        if (marks is List &&
            marks.whereType<Map>().any(
              (m) => m['_'] == markName || m['type'] == markName,
            )) {
          found = map;
          return;
        }
      }
      for (final v in map.values) {
        walk(v);
      }
    } else if (n is List) {
      for (final v in n) {
        walk(v);
      }
    }
  }

  walk(fixture);
  return found;
}

/// ★ 第 313 轮的假编辑宿主：只需要回答"哪些路径可编辑"并收下回调。
class _FakeEditHost implements OfficeDocEditHost {
  _FakeEditHost({this.enabled = true, Set<String>? editable})
    : editable = editable ?? <String>{};

  @override
  final bool enabled;

  /// 空集 = 任何路径都不可编辑（反向用）。
  final Set<String> editable;

  @override
  bool isEditablePath(OfficeDocPath path) =>
      editable.isEmpty || editable.contains(path.key);

  @override
  void onParagraphChanged(OfficeDocPath path, String text) {}

  @override
  void onParagraphSelection(OfficeDocPath path, int start, int end) {}

  @override
  void onParagraphFocused(OfficeDocPath path) {}
}

void main() {
  final fetchDoc = _fixture('dart_fetched_doc_v1.json');
  final snapshotPre = _fixture('snapshot_doc_pre.json');
  final vectors = _fixture('transform_vectors.json');
  final schema = DocSchema.document;

  group('V1. 覆盖表与 schema 逐字一致（schema 驱动，不是硬编码）', () {
    test('node 覆盖表的 key 集合 == schema.nodes 的 key 集合', () {
      expect(
        kOfficeDocNodeSupport.keys.toSet(),
        schema.nodes.keys.toSet(),
        reason: '渲染覆盖表必须与 doc_schema_generated.dart 的节点集合完全相同',
      );
      expect(kOfficeDocNodeSupport, hasLength(schema.nodes.length));
    });

    test('mark 覆盖表的 key 集合 == schema.marks + schema.attrMarks', () {
      final expected = <String>{...schema.marks.keys, ...schema.attrMarks.keys};
      expect(kOfficeDocMarkSupport.keys.toSet(), expected);
      expect(kOfficeDocMarkSupport, hasLength(expected.length));
    });

    test('每个覆盖项都写了依据（夹具路径或 schema 条目）', () {
      for (final entry in kOfficeDocNodeSupport.entries) {
        expect(entry.value.evidence.trim(), isNotEmpty, reason: entry.key);
      }
      for (final entry in kOfficeDocMarkSupport.entries) {
        expect(entry.value.evidence.trim(), isNotEmpty, reason: entry.key);
      }
    });

    test('schema 没有 heading / list 节点：标题与列表是 style_paragraph 的 attrs', () {
      expect(schema.nodes.containsKey('heading'), isFalse);
      expect(schema.nodes.containsKey('list'), isFalse);
      expect(schema.nodes.containsKey('list_item'), isFalse);
      expect(
        schema.nodes['style_paragraph']!.attrs.keys,
        containsAll(<String>[
          'headingLevel',
          'headingId',
          'listId',
          'listLevel',
        ]),
      );
    });

    test('officeDocSchemaAttr 只读 schema 声明过的 attr', () {
      // paragraph 声明了 headingLevel。
      expect(
        officeDocSchemaAttr(<String, Object?>{
          'type': 'paragraph',
          'attrs': <String, Object?>{'headingLevel': 2},
        }, 'headingLevel'),
        2,
      );
      // text 没有 attrs（schema 声明为空）→ 不读。
      expect(
        officeDocSchemaAttr(<String, Object?>{
          'type': 'text',
          'attrs': <String, Object?>{'headingLevel': 2},
        }, 'headingLevel'),
        isNull,
      );
      // schema 未声明的名字一律不读。
      expect(
        officeDocSchemaAttr(<String, Object?>{
          'type': 'paragraph',
          'attrs': <String, Object?>{'notAnAttr': 1},
        }, 'notAnAttr'),
        isNull,
      );
    });
  });

  group('V2. 真机夹具渲染', () {
    testWidgets('fetch v1 夹具：正文文本、样式定义、页面装饰都出现', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(_host(fetchDoc, report));

      // 正文（paragraph → text "C3SPIKE-DOC-BASE"）。
      expect(find.text('C3SPIKE-DOC-BASE', findRichText: true), findsOneWidget);
      // 样式定义（style_editor，7 个 style_paragraph，headingLevel 0..5）。
      expect(find.byKey(const Key('office-doc-style-editor')), findsOneWidget);
      // 页面装饰（page_decorate / header / footer / page_num）。
      expect(find.byKey(const Key('office-doc-page-decorate')), findsOneWidget);
      expect(find.textContaining('页眉'), findsWidgets);
      expect(find.textContaining('页脚'), findsWidgets);
      expect(find.textContaining('页码'), findsWidgets);
      // 夹具里的节点本批全部支持 → 无降级。
      expect(report.hasDegradations, isFalse, reason: '${report.messages}');
    });

    testWidgets('DA203 页眉/页脚/页码小字标签在白纸上必须 ≥4.5:1', (tester) async {
      // 真机 r613（Drive Office 编辑态，亮色）：这三个标签原来是
      // `const TextStyle(fontSize: 11, color: Colors.grey)` —— #9E9E9E 画在白纸上
      // 只有 **2.68:1**（AA 要 4.5）。而且文档的"纸"在任何主题下都是白的，
      // 所以既不能用 `Colors.grey`，也不能用暗色档的 `DesignPalette.dim`。
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(_host(fetchDoc, report));

      var checked = 0;
      for (final needle in <String>['页眉', '页脚', '页码']) {
        final finder = find.textContaining(needle);
        expect(finder, findsWidgets, reason: '夹具里应该有 $needle 标签，否则用例没落在地上');
        for (final el in finder.evaluate()) {
          final w = el.widget;
          if (w is! Text) continue;
          final color = w.style?.color;
          expect(color, isNotNull, reason: '$needle 标签没有显式颜色（会去继承，不可判）');
          final ratio = DesignPalette.contrastRatio(
            color!,
            const Color(0xFFFFFFFF),
          );
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '$needle 标签在白纸上只有 ${ratio.toStringAsFixed(2)}:1 → 不合格',
          );
          checked++;
        }
      }
      expect(checked, greaterThan(0), reason: '一个纸面标签都没量到');

      // 反向守卫：这份文件里不许再出现 `Colors.grey` 的文字色
      expect(officePageLabel, const Color(0xFF5C6A7E));
    });

    testWidgets('snapshot_doc_pre 夹具（Import 态）的 @C_text/content 也能渲染', (
      tester,
    ) async {
      final content = (snapshotPre['content']! as Map)['data'];
      expect(content, isA<Map<Object?, Object?>>());
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(_host(content, report));
      expect(find.text('C3SPIKE-DOC-BASE', findRichText: true), findsOneWidget);
      expect(report.hasDegradations, isFalse, reason: '${report.messages}');
    });

    testWidgets('transform_vectors 夹具里带 mark 的真机文本可渲染且无降级', (tester) async {
      for (final mark in <String>[
        'strong',
        'em',
        'underline',
        'color',
        'font_size',
      ]) {
        final textNode = _findMarkedText(vectors, mark);
        expect(textNode, isNotNull, reason: '夹具里应存在 $mark');
        final report = OfficeDocRenderReport();
        final doc = <String, Object?>{
          'type': 'doc',
          'content': <Object?>[
            <String, Object?>{
              'type': 'edit_area',
              'content': <Object?>[
                <String, Object?>{
                  'type': 'paragraph',
                  'content': <Object?>[textNode],
                },
              ],
            },
          ],
        };
        await tester.pumpWidget(_host(doc, report));
        expect(
          report.unsupportedMarkNames,
          isNot(contains(mark)),
          reason: '$mark 应被渲染：${report.unsupportedMarkNames}',
        );
        expect(report.unknownMarkNames, isEmpty, reason: '${report.messages}');
      }
    });
  });

  group('V3. 未知 / 未支持内容的降级（不许崩、不许静默丢）', () {
    testWidgets('unknown node（schema 未声明）→ 可见降级卡片 + 计数，不抛', (tester) async {
      final report = OfficeDocRenderReport();
      final doc = <String, Object?>{
        'type': 'doc',
        'content': <Object?>[
          <String, Object?>{'type': 'mystery_node_xyz'},
        ],
      };
      await tester.pumpWidget(_host(doc, report));
      expect(tester.takeException(), isNull);
      expect(report.unknownNodeTypes['mystery_node_xyz'], 1);
      expect(report.hasDegradations, isTrue);
      expect(find.textContaining('mystery_node_xyz'), findsWidgets);
    });

    testWidgets('图片节点（image）本批已实现 → 走图片组件，不再当"不支持渲染"', (tester) async {
      final report = OfficeDocRenderReport();
      final doc = <String, Object?>{
        'type': 'doc',
        'content': <Object?>[
          <String, Object?>{
            'type': 'edit_area',
            'content': <Object?>[
              <String, Object?>{
                'type': 'image',
                'attrs': <String, Object?>{'src': 'x'},
              },
            ],
          },
        ],
      };
      await tester.pumpWidget(_host(doc, report));
      expect(tester.takeException(), isNull);
      // 图片是"给人看的"：走 OfficeDocImage（无字节时是失败态 + 重试），
      // 既不是"暂不支持渲染"降级卡片，也不把内部类型名/file_id 打到界面上。
      expect(report.unsupportedNodeTypes, isNot(contains('image')));
      expect(report.unknownNodeTypes, isEmpty);
      expect(find.byType(OfficeDocImage), findsOneWidget);
      expect(find.textContaining('image'), findsNothing);
      expect(find.textContaining('src'), findsNothing);
    });

    testWidgets('unknown mark（schema 未声明）→ 纯文本保留 + 计数，不抛', (tester) async {
      final report = OfficeDocRenderReport();
      final doc = <String, Object?>{
        'type': 'doc',
        'content': <Object?>[
          <String, Object?>{
            'type': 'edit_area',
            'content': <Object?>[
              <String, Object?>{
                'type': 'paragraph',
                'content': <Object?>[
                  <String, Object?>{
                    'type': 'text',
                    'text': 'KEEP-ME',
                    'marks': <Object?>[
                      <String, Object?>{'_': 'mystery_mark'},
                    ],
                  },
                ],
              },
            ],
          },
        ],
      };
      await tester.pumpWidget(_host(doc, report));
      expect(tester.takeException(), isNull);
      expect(report.unknownMarkNames['mystery_mark'], 1);
      expect(find.text('KEEP-ME', findRichText: true), findsOneWidget);
    });

    testWidgets('顶层不是对象 → 明确降级，不抛', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(_host(<Object?>['not', 'a', 'doc'], report));
      expect(tester.takeException(), isNull);
      expect(report.hasDegradations, isTrue);
    });

    testWidgets('空文档 → 明确"没有可显示的正文块"', (tester) async {
      await tester.pumpWidget(_host(<String, Object?>{'type': 'doc'}));
      expect(find.byKey(const Key('office-doc-empty')), findsOneWidget);
    });
  });

  group('V4. mark 值解析', () {
    test('CSS 颜色解析：hex / rgb 认，坏值返回 null（不抛）', () {
      expect(officeDocParseColor('#ff0000'), const Color(0xffff0000));
      expect(officeDocParseColor('#f00'), const Color(0xffff0000));
      expect(officeDocParseColor('#80ff0000'), const Color(0x80ff0000));
      expect(officeDocParseColor('rgb(1, 2, 3)'), const Color(0xff010203));
      expect(officeDocParseColor('transparent'), isNull);
      expect(officeDocParseColor('chartreuse'), isNull);
      expect(officeDocParseColor(42), isNull);
    });
  });

  group('V5. 真实文档的 nodeSize 锚点（M1 §2.4 / protocol-spike §2.4）仍然成立', () {
    test('doc/paragraph 的 nodeSize 与真机锚点一致（渲染器没改写文档树）', () {
      // protocol-spike §2.4：settings=1, style_editor=16, invisible=2,
      // edit_area=20, page_decorate=31（合计 70），doc = 70 + 2 = 72；
      // 正文 paragraph 的插入位 37 = 19(edit_area 起点) + 1 + 1 + 16。
      final doc = DocNode.fromRawJson(fetchDoc);
      expect(schema.nodeSize(doc), 72);
      final editArea = doc.content!.firstWhere((c) => c.type == 'edit_area');
      expect(schema.nodeSize(editArea), 20);
      final paragraph = editArea.content!.first;
      expect(schema.nodeSize(paragraph), 18);
    });
  });

  group('V13. 第 313 轮：编辑态的"点正文开始输入"与"报告按帧替换"', () {
    testWidgets('★ r313：点正文里字段**之外**的位置，也要把焦点交给正文段落', (tester) async {
      // 真机缺口：空白文档里可输入段落只有 `351x20 dp`（`[office:field] rect`），
      // 点页面别处毫无反应 ⇒ 看起来像"编辑器坏了"。官方在 `edit_area` 内任意
      // 位置点击都落 caret（`queryChildOffset("edit_area", true) + 1`）。
      final prompt = ValueNotifier<int>(0);
      addTearDown(prompt.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: OfficeDocView(
              doc: fetchDoc,
              editHost: _FakeEditHost(),
              caretPrompt: prompt,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final promptFinder = find.byKey(const Key('office-doc-caret-prompt'));
      expect(promptFinder, findsOneWidget, reason: '编辑态必须有"点正文开始输入"的手势层');
      final fields = find.byType(TextField);
      expect(fields, findsWidgets, reason: '编辑态必须渲染出可输入段落');
      for (final f in tester.widgetList<TextField>(fields)) {
        expect(f.focusNode!.hasFocus, isFalse, reason: '还没点 ⇒ 不该已经聚焦');
      }

      // 反向验证①：只读态（没有宿主）**不许**有这一层（只读点击不该改任何东西）。
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(body: OfficeDocView(doc: fetchDoc)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-doc-caret-prompt')),
        findsNothing,
        reason: '只读态不该有"点正文开始输入"的手势层',
      );
      expect(find.byType(TextField), findsNothing, reason: '只读态不该有输入控件');

      // 反向验证②：宿主在但 `enabled == false`（门控不让写）同样不许有这一层。
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: OfficeDocView(
              doc: fetchDoc,
              editHost: _FakeEditHost(enabled: false),
              caretPrompt: prompt,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-doc-caret-prompt')),
        findsNothing,
        reason: '宿主 enabled=false 时不该有输入手势层',
      );
      expect(find.byType(TextField), findsNothing);

      // 回到编辑态：在正文区里找一个**不在任何字段矩形内**的点并点它。
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: OfficeDocView(
              doc: fetchDoc,
              editHost: _FakeEditHost(),
              caretPrompt: prompt,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final promptRect = tester.getRect(promptFinder);
      final fieldRects = find
          .byType(TextField)
          .evaluate()
          .map((e) => tester.getRect(find.byWidget(e.widget)))
          .toList();
      final candidates = <Offset>[
        Offset(promptRect.center.dx, promptRect.top + 8),
        Offset(promptRect.center.dx, promptRect.bottom - 8),
        Offset(promptRect.left + 4, promptRect.center.dy),
        Offset(promptRect.right - 4, promptRect.center.dy),
      ];
      final outside = candidates
          .where(
            (o) =>
                promptRect.contains(o) &&
                fieldRects.every((r) => !r.contains(o)),
          )
          .toList();
      expect(
        outside,
        isNotEmpty,
        reason: '正文区里必须存在字段之外的点：prompt=$promptRect fields=$fieldRects',
      );

      await tester.tapAt(outside.first);
      await tester.pump();
      final focused = tester
          .widgetList<TextField>(find.byType(TextField))
          .where((f) => f.focusNode!.hasFocus)
          .length;
      expect(focused, 1, reason: '点正文空白处 ⇒ 必须**恰好一个**正文段落拿到焦点（官方 caret 语义）');
    });

    testWidgets('★ r313：渲染报告按帧替换 —— 重建不会让 messages/计数无界增长', (tester) async {
      // 真机缺口：页面持有的 `OfficeDocRenderReport` 是长生命的，视图每次 build
      // 都往 `messages` 里 add ⇒ 真机一行日志涨到几万字符、计数虚高。
      final report = OfficeDocRenderReport();
      final doc = <String, Object?>{
        'type': 'doc',
        'content': <Object?>[
          <String, Object?>{'type': 'definitely_not_a_schema_node'},
        ],
      };
      Widget app() => MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: OfficeDocView(doc: doc, report: report),
        ),
      );
      await tester.pumpWidget(app());
      final firstLen = report.messages.length;
      expect(firstLen, greaterThan(0), reason: '未知节点必须如实登记（不许静默）');
      expect(report.unknownNodeTypes['definitely_not_a_schema_node'], 1);

      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(app());
        await tester.pump();
      }
      expect(
        report.messages.length,
        firstLen,
        reason: '重建 5 次后报告仍是"最近一帧的量"（追加会让它无界增长）',
      );
      expect(
        report.unknownNodeTypes['definitely_not_a_schema_node'],
        1,
        reason: '计数是"这一帧出现了几个"，不是"累计登记了几次"',
      );
    });
  });
}
