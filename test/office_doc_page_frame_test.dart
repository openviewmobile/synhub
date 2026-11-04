// 批 B：**页眉 / 页脚 / 页码 → 页边区域** + 分隔线 / 分页 + 图表（未取证）离线测试。
//
// 夹具是真实 NAS 文档 `5-day trip planner.odoc`（以及另外两份文档字节一致）的
// `page_decorate` 原文节点：test/fixtures/office_doc_tables/page_decorate_*.json。
// 真实样例的 header/footer 内容是**空 paragraph**，所以"可见页眉文字"的用例把文字
// **注入真实节点形状**（派生，见 MANIFEST.json :: derived）。
//
// 无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_doc_page_frame.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_doc_view.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/office_doc_tables/$name').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> _deepCopy(Object? v) =>
    (jsonDecode(jsonEncode(v)) as Map).cast<String, Object?>();

/// 真实 `page_decorate` 节点 + 注入可见文字（真实样例的页眉页脚是空段落）。
Map<String, Object?> _decorated({
  String pageNumType = 'normal',
  bool withPageNum = true,
}) {
  final deco = _deepCopy(_baseDecorate);
  final content = (deco['content']! as List).cast<Map<String, Object?>>();
  if (!withPageNum) {
    content.removeWhere((n) => n['type'] == 'page_num');
  }
  for (final n in content) {
    final type = n['type'];
    if (type != 'header' && type != 'footer') continue;
    final kind = ((n['attrs'] as Map)['type'] ?? '').toString().toUpperCase();
    final suffix = type == 'header' ? 'HDR' : 'FTR';
    n['content'] = <Object?>[
      <String, Object?>{
        'type': 'paragraph',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '$kind-$suffix'},
        ],
      },
    ];
  }
  final pn = content.firstWhere(
    (n) => n['type'] == 'page_num',
    orElse: () => <String, Object?>{},
  );
  if (pn.isNotEmpty) {
    (pn['attrs']! as Map)['type'] = pageNumType;
  }
  return deco;
}

Map<String, Object?> _doc(Map<String, Object?> decorate) => <String, Object?>{
  'type': 'doc',
  'content': <Object?>[
    <String, Object?>{
      'type': 'edit_area',
      'content': <Object?>[
        <String, Object?>{
          'type': 'paragraph',
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'BODY'},
          ],
        },
      ],
    },
    decorate,
  ],
};

Widget _host(
  Object? doc, {
  OfficeDocRenderReport? report,
  OfficeDocPageKind pageKind = OfficeDocPageKind.normal,
  int pageNumber = 1,
}) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: OfficeDocView(
      doc: doc,
      report: report,
      showHeaderNote: false,
      pageKind: pageKind,
      pageNumber: pageNumber,
    ),
  ),
);

final Map<String, Object?> _baseDecorate = _fixture(
  'page_decorate_five_day_trip_planner.json',
);

void main() {
  group('P1. page_decorate 解析（真机 7 个 attrs + cover/even/normal）', () {
    test('真实节点：num-pos="br"，header/footer 各 3 种页型，page_num=normal', () {
      final d = OfficeDocDecorations.parse(_baseDecorate);
      expect(d.numPosition, 'br');
      expect(d.headers.keys.toSet(), <String>{'cover', 'even', 'normal'});
      expect(d.footers.keys.toSet(), <String>{'cover', 'even', 'normal'});
      expect(d.pageNums.keys.toSet(), <String>{'normal'});
      expect(officeDocNumPositionAlignment('br'), Alignment.bottomRight);
      expect(officeDocNumPositionAlignment('tl'), Alignment.topLeft);
      expect(officeDocNumPositionAlignment('bc'), Alignment(0, 1));
      // 认不出的写法回落右下（真机默认）。
      expect(officeDocNumPositionAlignment('??'), Alignment.bottomRight);
    });

    test('按页型取装饰：normal 帧不取 cover/even，cover 帧只取 cover', () {
      final d = OfficeDocDecorations.parse(_baseDecorate);
      expect(d.headerFor(OfficeDocPageKind.normal), isNotNull);
      expect(
        ((d.headerFor(OfficeDocPageKind.normal)! as Map)['attrs']
            as Map)['type'],
        'normal',
      );
      expect(
        ((d.headerFor(OfficeDocPageKind.cover)! as Map)['attrs']
            as Map)['type'],
        'cover',
      );
      expect(d.footerFor(OfficeDocPageKind.normal), isNotNull);
      expect(d.pageNumFor(OfficeDocPageKind.normal), isNotNull);
      // normal 帧里 cover/even 的页眉页脚是被跳过的（登记用）。
      expect(d.skippedFor(OfficeDocPageKind.normal), contains('header(cover)'));
      expect(d.skippedFor(OfficeDocPageKind.normal), contains('footer(cover)'));
    });

    test('全部 13 份真实文档的 page_decorate 三份夹具字节一致（实探）', () {
      final a = File(
        'test/fixtures/office_doc_tables/page_decorate_five_day_trip_planner.json',
      ).readAsBytesSync();
      for (final n in <String>[
        'page_decorate_product_spec.json',
        'page_decorate_vacation_packing_list.json',
      ]) {
        expect(
          File('test/fixtures/office_doc_tables/$n').readAsBytesSync(),
          a,
          reason: '$n 应与 trip planner 的 page_decorate 逐字节一致',
        );
      }
    });
  });

  group('P2. 页边区域渲染：cover 不印在正文页', () {
    testWidgets('normal 帧：印 normal 页眉页脚，**不印 cover 页眉页脚**', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(_host(_doc(_decorated()), report: report));
      expect(tester.takeException(), isNull);
      // 页眉/页脚带存在，且印的是 normal 那一份。
      expect(find.byKey(const Key('office-doc-page-header')), findsOneWidget);
      expect(find.byKey(const Key('office-doc-page-footer')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('office-doc-page-header')),
          matching: find.text('NORMAL-HDR', findRichText: true),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('office-doc-page-footer')),
          matching: find.text('NORMAL-FTR', findRichText: true),
        ),
        findsOneWidget,
      );
      // 关键判据：cover 的页眉页脚**不得**被印到正文页上。
      expect(find.text('COVER-HDR', findRichText: true), findsNothing);
      expect(find.text('COVER-FTR', findRichText: true), findsNothing);
      expect(
        report.messages.any(
          (m) => m.contains('不印这些页边装饰') && m.contains('header(cover)'),
        ),
        isTrue,
        reason: '被跳过的 cover 装饰必须如实登记：${report.messages}',
      );
    });

    testWidgets('cover 帧：印 cover 的，**不印 normal 的**（规则双向成立）', (tester) async {
      await tester.pumpWidget(
        _host(_doc(_decorated()), pageKind: OfficeDocPageKind.cover),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('COVER-HDR', findRichText: true), findsOneWidget);
      expect(find.text('COVER-FTR', findRichText: true), findsOneWidget);
      expect(find.text('NORMAL-HDR', findRichText: true), findsNothing);
      expect(find.text('NORMAL-FTR', findRichText: true), findsNothing);
    });

    testWidgets('页眉页脚印在**页边区域**：页眉在正文之上、页脚在正文之下，且不在正文流里', (tester) async {
      await tester.pumpWidget(_host(_doc(_decorated())));
      expect(tester.takeException(), isNull);
      final headerRect = tester.getRect(
        find.byKey(const Key('office-doc-page-header')),
      );
      final footerRect = tester.getRect(
        find.byKey(const Key('office-doc-page-footer')),
      );
      final bodyRect = tester.getRect(find.text('BODY', findRichText: true));
      expect(headerRect.bottom, lessThanOrEqualTo(bodyRect.top));
      expect(footerRect.top, greaterThanOrEqualTo(bodyRect.bottom));
      // 正文不在页眉/页脚带里（装饰不是正文流里的一行字）。
      expect(
        find.descendant(
          of: find.byKey(const Key('office-doc-page-header')),
          matching: find.text('BODY', findRichText: true),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('office-doc-page-footer')),
          matching: find.text('BODY', findRichText: true),
        ),
        findsNothing,
      );
      // 页眉带里也不再有"页面装饰"这类正文说明行。
      expect(find.textContaining('页面装饰'), findsNothing);
    });
  });

  group('P3. 页码：按 type 决定是否显示 + 显示真实页码 + num-pos 定位', () {
    testWidgets('normal 页码显示**真实页码**（1 → 3），且不显示 `#` 占位', (tester) async {
      await tester.pumpWidget(_host(_doc(_decorated()), pageNumber: 1));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('office-doc-page-num-text')))
            .data,
        '1',
      );
      await tester.pumpWidget(_host(_doc(_decorated()), pageNumber: 3));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('office-doc-page-num-text')))
            .data,
        '3',
      );
      expect(find.text('#', findRichText: true), findsNothing);
      // 页码在**下边距**（页脚带）里，并靠右下（num-pos="br"）。
      final footerRect = tester.getRect(
        find.byKey(const Key('office-doc-page-footer')),
      );
      final numRect = tester.getRect(
        find.byKey(const Key('office-doc-page-num-text')),
      );
      expect(numRect.top, greaterThanOrEqualTo(footerRect.top));
      expect(numRect.center.dy, greaterThan(footerRect.center.dy));
      expect(footerRect.right - numRect.right, lessThan(80));
    });

    testWidgets('page_num type 不匹配当前页型 → 不显示页码（只登记）', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(
        _host(_doc(_decorated(pageNumType: 'cover')), report: report),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('office-doc-page-num-text')), findsNothing);
      expect(
        report.messages.any((m) => m.contains('page_num(cover)')),
        isTrue,
        reason: '不匹配的 page_num 必须登记：${report.messages}',
      );
    });

    testWidgets('文档没有 page_num 节点 → 不显示页码，也不报降级', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(
        _host(_doc(_decorated(withPageNum: false)), report: report),
      );
      expect(find.byKey(const Key('office-doc-page-num-text')), findsNothing);
      expect(report.hasDegradations, isFalse);
    });
  });

  group('P4. 分隔线 / 分页 / 图表（未取证）', () {
    testWidgets('horizontal_rule 与 page_break 有明确节点与视觉分隔', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(
        _host(<String, Object?>{
          'type': 'doc',
          'content': <Object?>[
            <String, Object?>{
              'type': 'edit_area',
              'content': <Object?>[
                <String, Object?>{'type': 'horizontal_rule'},
                <String, Object?>{'type': 'page_break'},
              ],
            },
          ],
        }, report: report),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('office-doc-horizontal-rule')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('office-doc-page-break')), findsOneWidget);
      expect(find.text('分页', findRichText: true), findsOneWidget);
      expect(report.hasDegradations, isFalse, reason: '${report.messages}');
    });

    testWidgets('chart：按 schema width/height 占位并**明确登记未取证**', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(
        _host(<String, Object?>{
          'type': 'doc',
          'content': <Object?>[
            <String, Object?>{
              'type': 'edit_area',
              'content': <Object?>[
                <String, Object?>{
                  'type': 'chart',
                  'attrs': <String, Object?>{
                    'synochart': 'abc',
                    'width': 300,
                    'height': 200,
                  },
                },
              ],
            },
          ],
        }, report: report),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('office-doc-chart')), findsOneWidget);
      // 按 schema width/height（300×200）占位。
      expect(
        tester.getSize(find.byKey(const Key('office-doc-chart'))),
        const Size(300, 200),
      );
      expect(find.byKey(const Key('office-doc-chart-label')), findsOneWidget);
      expect(
        report.messages.any((m) => m.contains('chart 节点未取证')),
        isTrue,
        reason: 'chart 无真实样例 → 必须登记未取证：${report.messages}',
      );
      // 内部标识不上屏。
      expect(find.textContaining('synochart'), findsNothing);
    });

    testWidgets('不在 page_decorate 里的 header/footer 如实登记（未取证形态）', (
      tester,
    ) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(
        _host(<String, Object?>{
          'type': 'doc',
          'content': <Object?>[
            <String, Object?>{
              'type': 'header',
              'attrs': <String, Object?>{'type': 'normal'},
              'content': <Object?>[
                <String, Object?>{
                  'type': 'paragraph',
                  'content': <Object?>[
                    <String, Object?>{'type': 'text', 'text': 'LOOSE-HDR'},
                  ],
                },
              ],
            },
          ],
        }, report: report),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('LOOSE-HDR', findRichText: true), findsWidgets);
      expect(
        report.messages.any((m) => m.contains('不在 page_decorate 内')),
        isTrue,
      );
    });
  });
}
