// Office C′ 演示文稿（Slides）批 1 —— 只读渲染器（证据驱动）离线测试。
//
// 夹具来源（**真实数据**；完整帧的裁剪片段，逐字保留结构与文本值）：
//   * `test/fixtures/office_collab/slides_snapshot_frame.json`
//     —— 真机 `SYNO.Office.Snapshot:get v4` 回包
//     `/tmp/office_probe_evid/snap_probe_exported.oslides.json` 的 `get.data`
//     裁剪：`settings` + `master_container`（只留 master_background +
//     title_master_holder 一支）+ `slide_container` 的第 1、3 页（verbatim）
//     + `comment` + `file`。sha256 `398ff214946b77c5…`。
//     真机原文（未裁剪）里：`ntype:"presentation"`、
//     `content.data.attrs = {cx:960, cy:540, schema:13, type:"presentation"}`、
//     15 slide / 15 note / 16 layout / image×6。
//   * 24 份官方主题 `template/slides/<theme>/text.json`（**不 vendored**；
//     运行时读，缺失则 skip）。
//
// 无网络、无设备、无构建。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/office_collab_client.dart';
import 'package:synhub/src/data/office_native/office_json.dart';
import 'package:synhub/src/features/office/office_slides_edit.dart';
import 'package:synhub/src/features/office/office_slides_schema.dart';
import 'package:synhub/src/features/office/office_slides_view.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/office_samples.dart';

Map<String, Object?> _readEvidenceJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

Map<String, Object?> _frameSections() =>
    _readEvidenceJson('test/fixtures/office_collab/slides_snapshot_frame.json');

final Directory _samplesRoot = Directory(
  '${officeTemplateRoot().path}/slides',
);

final String? _skipReason = _samplesRoot.existsSync()
    ? null
    : '官方主题样本缺失：${_samplesRoot.path}（包内样本，不 vendored）';

List<String> _sampleNames() {
  if (!_samplesRoot.existsSync()) return const [];
  final names =
      _samplesRoot
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .toList()
        ..sort();
  return names;
}

Widget _host(
  Map<String, Object?> sections, [
  OfficeSlidesRenderReport? report,
]) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: OfficeSlidesView(sections: sections, report: report),
  ),
);

int _countType(Object? node, String type) {
  var n = 0;
  void walk(Object? x) {
    if (x is List) {
      for (final y in x) {
        walk(y);
      }
      return;
    }
    if (x is! Map) return;
    if (x['type'] == type) n++;
    walk(x['content']);
  }

  walk(node);
  return n;
}

/// 一个最小的、**证据形状**的 sections 字典（键/类型取自真机帧与 24 份模板；
/// 文本值用短标记，便于断言，不冒充真实内容）。
Map<String, Object?> _miniSections({
  Object? extraSlideContent,
}) => <String, Object?>{
  'content': <String, Object?>{
    'version': 7,
    'data': <String, Object?>{
      'attrs': <String, Object?>{
        'schema': 13,
        'type': 'presentation',
        'cx': 960,
        'cy': 540,
      },
      'content': <Object?>[
        <String, Object?>{'type': 'settings', 'attrs': <String, Object?>{}},
        <String, Object?>{
          'type': 'slide_container',
          'attrs': <String, Object?>{
            'page_num_enabled': false,
            'date_time_enabled': false,
          },
          'content': <Object?>[
            <String, Object?>{
              'type': 'slide',
              'attrs': <String, Object?>{
                'id': 'S1',
                'master_id': 'M',
                'layout_id': 'L',
                'is_visible': true,
              },
              'content': <Object?>[
                <String, Object?>{
                  'type': 'slide_content_container',
                  'attrs': <String, Object?>{},
                  'content': <Object?>[
                    ?extraSlideContent,
                    <String, Object?>{
                      'type': 'paragraph',
                      'attrs': <String, Object?>{'textAlign': 'center'},
                      'content': <Object?>[
                        <String, Object?>{
                          'type': 'text',
                          'text': 'MINI-SLIDE-TEXT',
                          'marks': <Object?>[
                            <String, Object?>{'_': 'strong'},
                          ],
                        },
                      ],
                    },
                  ],
                },
                <String, Object?>{
                  'type': 'note',
                  'attrs': <String, Object?>{},
                  'content': <Object?>[
                    <String, Object?>{
                      'type': 'paragraph',
                      'attrs': <String, Object?>{},
                      'content': <Object?>[
                        <String, Object?>{'type': 'text', 'text': 'MINI-NOTE'},
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
  'comment': <String, Object?>{'data': <Object?>[], 'format': 1},
};

void main() {
  group('S1. schema / step / section / 字段登记表（与机读产物逐字一致）', () {
    test('78 节点 == slides_schema.json.nodes', () {
      final doc = _readEvidenceJson(kOfficeSlidesEvidencePath);
      final expected = <String>{
        for (final n in (doc['nodes'] as List)) '${(n as Map)['name']}',
      };
      expect(expected, hasLength(78));
      expect(kOfficeSlidesNodeNames, expected, reason: '节点名必须逐字等于导出');
      expect(kOfficeSlidesNodeSpecs, hasLength(kOfficeSlidesNodeCount));
      expect(kOfficeSlidesNodeCount, 78);
    });

    test('16 mark == marks ∪ attr_marks', () {
      final doc = _readEvidenceJson(kOfficeSlidesEvidencePath);
      final expected = <String>{
        for (final m in (doc['marks'] as List)) '${(m as Map)['name']}',
        for (final m in (doc['attr_marks'] as Map).values)
          '${(m as Map)['name']}',
      };
      expect(expected, hasLength(16));
      expect(kOfficeSlidesMarkNames, expected);
      expect(kOfficeSlidesMarkCount, 12);
      expect(kOfficeSlidesAttrMarkCount, 4);
    });

    test(
      '51 step == slides_schema.json.steps.entries（那是 .oslides 的"命令"对应物）',
      () {
        final doc = _readEvidenceJson(kOfficeSlidesEvidencePath);
        final steps = (doc['steps'] as Map)['entries'] as List;
        final expected = <String>{
          for (final s in steps) '${(s as Map)['name']}',
        };
        expect(expected, hasLength(51));
        expect(kOfficeSlidesStepNames, expected);
        expect(kOfficeSlidesStepCount, 51);
        expect(kOfficeSlidesStepSpecs, hasLength(51));
        expect(isOfficeSlidesStepKnown('setNodeAttrs'), isTrue);
        expect(isOfficeSlidesStepKnown('setSlideAnimation'), isTrue);
        expect(isOfficeSlidesStepKnown('definitely_not_a_step'), isFalse);
        // `V<n>` 后缀（`Step.normalizeStepId` 会去掉）。
        expect(kOfficeSlidesVersionedStepNames, contains('insertTableRowV2'));
      },
    );

    test('每个节点的 attrKeys / support 与导出逐条一致', () {
      final doc = _readEvidenceJson(kOfficeSlidesEvidencePath);
      final support = (doc['node_support'] as Map).cast<String, Object?>();
      for (final raw in doc['nodes'] as List) {
        final n = raw as Map;
        final name = '${n['name']}';
        final spec = kOfficeSlidesNodeSpecs[name]!;
        expect(spec.attrKeys.toSet(), {
          for (final k in (n['attr_keys'] as List)) '$k',
        }, reason: '$name 的属性登记表必须逐字等于导出');
        expect(spec.isText, n['isText']);
        expect(spec.isLeaf, n['isLeaf']);
        expect(spec.content, n['content']);
        expect(spec.groups.toSet(), {
          for (final g in (n['groups'] as List)) '$g',
        });
        final s = (support[name] as Map)['support'];
        expect(spec.support.name, s, reason: '$name 的渲染支持度必须等于导出');
      }
    });

    test('step registry / dispatcher 函数偏移 == 导出原文', () {
      final doc = _readEvidenceJson(kOfficeSlidesEvidencePath);
      final fns = ((doc['steps'] as Map)['registry_functions'] as Map)
          .cast<String, Object?>();
      final actual = <String, int>{
        for (final f in kOfficeSlidesStepRegistryFns) f.name: f.offset,
      };
      final expected = <String, int>{
        for (final e in fns.entries)
          e.key: ((e.value as Map)['offset'] as num).toInt(),
      };
      expect(actual, expected);
      expect(kOfficeSlidesStepRegistryFns.map((f) => f.name).toSet(), {
        'register',
        'jsonID',
        'stepClass',
        'normalizeStepId',
        'fromJSONDispatch',
      });
      expect(kOfficeSlidesStepDispatcher, contains('stepClass'));
      expect(kOfficeSlidesStepRegistry, contains('JSON id'));
    });

    test('section 表 == 导出的 observed.section_keys', () {
      final doc = _readEvidenceJson(kOfficeSlidesEvidencePath);
      final observed = (doc['observed'] as Map).cast<String, Object?>();
      final expected = <String>{
        for (final k in (observed['section_keys'] as Map).keys) '$k',
      };
      expect(expected, hasLength(4));
      expect(kOfficeSlidesSections.keys.toSet(), expected);
      expect(
        officeSlidesSectionEvidence('content').support,
        OfficeSlidesSectionSupport.rendered,
      );
      expect(
        officeSlidesSectionEvidence('index').support,
        OfficeSlidesSectionSupport.structural,
      );
      expect(
        officeSlidesSectionEvidence('definitely_not_a_section').support,
        OfficeSlidesSectionSupport.unknown,
      );
    });

    test('mark 支持表 key 必须与 schema 的 mark 集合完全相同', () {
      expect(kOfficeSlidesMarkSupport.keys.toSet(), kOfficeSlidesMarkNames);
      expect(
        kOfficeSlidesMarkSupport['tracking'],
        OfficeSlidesMarkSupport.metadata,
      );
      expect(
        kOfficeSlidesMarkSupport['text_align'],
        OfficeSlidesMarkSupport.degraded,
      );
      expect(
        kOfficeSlidesMarkSupport['color'],
        OfficeSlidesMarkSupport.rendered,
      );
    });

    test('section ↔ "@C_text/" + section；schema 事实与真机帧一致', () {
      final doc2 = _readEvidenceJson(kOfficeSlidesEvidencePath);
      expect(officeSlidesSectionKey('content'), '@C_text/content');
      expect(officeSlidesSectionKey('index'), '@C_text/index');
      expect(kOfficeSlidesSchemaName, 'presentation');
      expect(kOfficeSlidesSchemaVersion, 13);
      expect(kOfficeSlidesTopNodeName, 'doc');
      expect(
        kOfficeSlidesTopNodeContent,
        'settings master_container slide_container',
      );
      expect(kOfficeSlidesRootAttrKeys, {'schema', 'type', 'cx', 'cy'});
      // 这三个键集合同样来自机读产物（observed.*_keys），逐字比对。
      final observed = (doc2['observed'] as Map).cast<String, Object?>();
      expect(kOfficeSlidesContentKeys, {
        for (final k in (observed['content_keys'] as Map).keys) '$k',
      });
      expect(kOfficeSlidesContentDataKeys, {
        for (final k in (observed['content_data_keys'] as Map).keys) '$k',
      });
      expect(kOfficeSlidesRootAttrKeys, {
        for (final k in (observed['root_attr_keys'] as Map).keys) '$k',
      });
      expect(kOfficeSlidesSnapshotDataKeys, {
        for (final k in (observed['snapshot_data_keys'] as Map).keys)
          if (!'$k'.contains('.')) '$k',
      });
      expect(isOfficeSlidesNodeKnown('slide_container'), isTrue);
      expect(isOfficeSlidesNodeKnown('definitely_not_a_node'), isFalse);
      expect(kOfficeSlidesNodeSpecs['slide']!.attrKeys.toSet(), {
        'trackingSelf',
        'master_id',
        'layout_id',
        'id',
        'is_visible',
        'transition',
        'animations',
      });
    });
  });

  group('S2. 真机帧形状快照：页序 / 正文 / 摘要 / 未知字段', () {
    testWidgets('两页照渲染：页标签 / 正文 / 备注 / 摘要', (tester) async {
      final sections = _frameSections();
      final report = OfficeSlidesRenderReport();
      await tester.pumpWidget(_host(sections, report));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('office-slides-view')), findsOneWidget);
      expect(find.byKey(const Key('office-slide-0')), findsOneWidget);
      expect(find.byKey(const Key('office-slide-page-0')), findsOneWidget);
      expect(find.text('第 1 页'), findsOneWidget);
      // 真机第 1 页的标题文字（verbatim）。
      expect(find.textContaining('Social Media'), findsWidgets);
      // 摘要行。
      expect(find.byKey(const Key('office-slides-summary')), findsOneWidget);
      expect(find.textContaining('幻灯片 2 页'), findsOneWidget);

      // 批 C：幻灯片现在是**整页画布**（960×540 等比缩放），第 2 页/母版卡会落在
      // 视口外（ListView 懒构建 → finder 默认 skipOffstage 看不到）。
      // 断言前先滚动到目标，断言强度不变（仍然要求真的渲染出来）。
      await tester.drag(find.byType(ListView), const Offset(0, -720));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slide-1')), findsOneWidget);
      expect(find.byKey(const Key('office-slide-page-1')), findsOneWidget);
      expect(find.text('第 2 页'), findsOneWidget);
      // 真机第 2 页的正文文字（verbatim）。
      expect(find.textContaining('Hello!'), findsWidgets);

      // 母版单独成卡（不并入各页正文）。
      await tester.drag(find.byType(ListView), const Offset(0, -720));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slide-master')), findsOneWidget);

      expect(report.slidesRendered, 2);
      expect(report.notesRendered, 2);
      expect(report.unknownNodeTypes, isEmpty);
      expect(report.unknownMarks, isEmpty);
    });

    testWidgets('真实制品里的未声明属性键必须可见计数（type_id / shape_type）', (tester) async {
      final report = OfficeSlidesRenderReport();
      await tester.pumpWidget(_host(_frameSections(), report));
      await tester.pumpAndSettle();

      // 真机帧里 `title_master_holder.type_id` / `title_slide_holder_shape.shape_type`
      // 出现在数据里但 schemaPresentation **没有声明**（见 slides_schema.json
      // observed.attr_keys_not_declared）→ 必须进 unknownFields。
      expect(
        report.unknownFields.keys,
        contains('title_master_holder.type_id'),
      );
      expect(
        report.unknownFields.keys,
        contains('title_slide_holder_shape.shape_type'),
      );
      expect(report.hasDegradations, isTrue);
      expect(
        find.byKey(const Key('office-slides-partial-banner')),
        findsOneWidget,
      );
      // 降级横幅可见 ≠ 内容丢失：正文照渲染（第 2 页在视口外 → 先滚动到它）。
      await tester.drag(find.byType(ListView), const Offset(0, -720));
      await tester.pumpAndSettle();
      expect(find.textContaining('Hello!'), findsWidgets);
    });

    test('scan：section 登记（content 渲染；index/comment 只登记不解释）', () {
      final report = OfficeSlidesRenderReport();
      scanOfficeSlidesSections(_frameSections(), report);
      expect(report.slidesRendered, 2);
      expect(report.registeredOnlySections.keys, contains('comment'));
      expect(report.unknownSections, isEmpty);
      expect(report.unknownNodeTypes, isEmpty);
      expect(report.messages.any((m) => m.contains('@C_text/comment')), isTrue);
    });
  });

  group('S3. 官方主题样本（24 份，运行时读；缺失则 skip）', () {
    final names = _sampleNames();

    test('样本目录存在时 24 份', () {
      if (_skipReason != null) {
        markTestSkipped(_skipReason!);
        return;
      }
      expect(names, hasLength(24));
    }, skip: _skipReason ?? false);

    for (final name in names) {
      test(name, () {
        final raw = _readEvidenceJson('${_samplesRoot.path}/$name/text.json');
        final report = OfficeSlidesRenderReport();
        scanOfficeSlidesSections(raw, report);

        final data = ((raw['content'] as Map)['data'] as Map);
        final slideContainer = (data['content'] as List).firstWhere(
          (x) => (x as Map)['type'] == 'slide_container',
          orElse: () => null,
        );
        final slides = slideContainer == null
            ? 0
            : _countType(slideContainer, 'slide');
        expect(report.slidesRendered, slides, reason: '$name: 页数');
        // 24 份样本里**没有一种**节点/mark 落在 schema 之外。
        expect(report.unknownNodeTypes, isEmpty, reason: '$name: 未知节点');
        expect(report.unknownMarks, isEmpty, reason: '$name: 未知 mark');
        expect(report.unknownSections, isEmpty, reason: '$name: 未知 section');
        // 唯一的未知字段应当是导出里记过名的那批未声明属性键。
        final declared = kOfficeSlidesNodeSpecs;
        for (final key in report.unknownFields.keys) {
          final parts = key.split('.');
          final node = parts.first;
          expect(
            declared.containsKey(node),
            isTrue,
            reason: '$name: $key 落在 schema 外的节点上',
          );
          expect(
            declared[node]!.declaresAttr(parts.last),
            isFalse,
            reason: '$name: $key 其实是 schema 声明过的属性',
          );
        }
      }, skip: _skipReason ?? false);
    }

    testWidgets('任取一份样本能渲染出幻灯片（缺失则 skip）', (tester) async {
      if (_skipReason != null) {
        markTestSkipped(_skipReason!);
        return;
      }
      final raw = _readEvidenceJson(
        '${_samplesRoot.path}/${names.first}/text.json',
      );
      final report = OfficeSlidesRenderReport();
      await tester.pumpWidget(_host(raw, report));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-view')), findsOneWidget);
      expect(report.slidesRendered, greaterThan(0));
    }, skip: _skipReason != null);
  });

  group('S4. 未知 section / 字段 / 节点 / mark / step：可见降级 + 计数，不崩不静默', () {
    test('未知 section 计数 + 消息（不崩）', () {
      final sections = <String, Object?>{
        ..._miniSections(),
        'mystery_section': <String, Object?>{'x': 1},
      };
      final report = OfficeSlidesRenderReport();
      scanOfficeSlidesSections(sections, report);
      expect(report.unknownSections['mystery_section'], 1);
      expect(report.hasDegradations, isTrue);
      expect(
        report.messages.any((m) => m.contains('@C_text/mystery_section')),
        isTrue,
      );
    });

    test('未知字段（index / content.data.attrs / 节点 attrs）都进 unknownFields', () {
      final sections = <String, Object?>{
        'content': <String, Object?>{
          'version': 1,
          'weird': true,
          'data': <String, Object?>{
            'attrs': <String, Object?>{'schema': 13, 'bogus_attr': 1},
            'content': <Object?>[
              <String, Object?>{
                'type': 'paragraph',
                'attrs': <String, Object?>{'unknownParagraphKey': 'x'},
                'content': <Object?>[
                  <String, Object?>{'type': 'text', 'text': 'T'},
                ],
              },
            ],
          },
        },
        'index': <String, Object?>{'schemaVersion': 13, 'bogus': 2},
      };
      final report = OfficeSlidesRenderReport();
      scanOfficeSlidesSections(sections, report);
      expect(report.unknownFields.keys, contains('content.weird'));
      expect(
        report.unknownFields.keys,
        contains('content.data.attrs.bogus_attr'),
      );
      expect(
        report.unknownFields.keys,
        contains('paragraph.unknownParagraphKey'),
      );
      expect(report.unknownFields.keys, contains('index.bogus'));
      expect(report.unknownFields, hasLength(4));
    });

    test('未知节点 / degraded 节点：计数 + 消息，不抛', () {
      final sections = _miniSections(
        extraSlideContent: <String, Object?>{
          'type': 'not_a_real_type',
          'attrs': <String, Object?>{},
          'content': <Object?>[],
        },
      );
      final report = OfficeSlidesRenderReport();
      scanOfficeSlidesSections(sections, report);
      expect(report.unknownNodeTypes['not_a_real_type'], 1);
      // schema 声明但本批不渲染的节点（degraded）也计数。
      final withImage = _miniSections(
        extraSlideContent: <String, Object?>{
          'type': 'image',
          'attrs': <String, Object?>{'file_id': '1'},
        },
      );
      final report2 = OfficeSlidesRenderReport();
      scanOfficeSlidesSections(withImage, report2);
      expect(report2.unsupportedNodeTypes['image'], 1);
      expect(report2.hasDegradations, isTrue);
    });

    testWidgets('未知节点画出可见降级卡片，且其它内容照渲染（不静默丢）', (tester) async {
      final report = OfficeSlidesRenderReport();
      final sections = _miniSections(
        extraSlideContent: <String, Object?>{
          'type': 'not_a_real_type',
          'attrs': <String, Object?>{},
        },
      );
      await tester.pumpWidget(_host(sections, report));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-view')), findsOneWidget);
      expect(find.textContaining('not_a_real_type'), findsWidgets);
      expect(find.text('MINI-SLIDE-TEXT'), findsOneWidget);
      expect(report.unknownNodeTypes['not_a_real_type'], 1);
    });

    testWidgets('未知 mark：文本照渲染 + 计数（不静默）', (tester) async {
      final report = OfficeSlidesRenderReport();
      final sections = _miniSections(
        extraSlideContent: <String, Object?>{
          'type': 'paragraph',
          'attrs': <String, Object?>{},
          'content': <Object?>[
            <String, Object?>{
              'type': 'text',
              'text': 'MARKED-TEXT',
              'marks': <Object?>[
                <String, Object?>{'_': 'definitely_not_a_mark'},
                <String, Object?>{'_': 'tracking', 'id': 'rev1'},
              ],
            },
          ],
        },
      );
      await tester.pumpWidget(_host(sections, report));
      await tester.pumpAndSettle();
      expect(find.textContaining('MARKED-TEXT'), findsWidgets);
      expect(report.unknownMarks['definitely_not_a_mark'], 1);
      expect(report.unsupportedMarks['tracking'], 1);
    });

    test('init 的 step 列表：不回放，认识/不认识都登记', () {
      final report = OfficeSlidesRenderReport();
      scanOfficeSlidesCommands(
        <Object?>[
          <String, Object?>{'stepType': 'setNodeAttrs'},
          <String, Object?>{'stepType': 'teleport'},
          <String, Object?>{'cmd': 'mysteryCmd'},
        ],
        report,
        source: 'test',
      );
      expect(report.commandsNotReplayed, 3);
      expect(report.seenSteps['setNodeAttrs'], 1);
      expect(report.unknownSteps['setNodeAttrs'], isNull);
      expect(report.unknownSteps['teleport'], 1);
      expect(report.unknownSteps['mysteryCmd'], 1);
      expect(report.hasDegradations, isTrue);
    });

    test('缺 stepType/cmd/type 的条目 → malformedCommands（不静默）', () {
      final report = OfficeSlidesRenderReport();
      scanOfficeSlidesCommands(
        <Object?>[
          <String, Object?>{'nope': 1},
        ],
        report,
        source: 'test',
      );
      expect(report.malformedCommands, 1);
      expect(
        report.messages.any((m) => m.contains('没有 stepType/cmd 字段')),
        isTrue,
      );
    });

    test('content 不是对象 / 缺 content：不崩，明确登记', () {
      final report = OfficeSlidesRenderReport();
      scanOfficeSlidesSections(<String, Object?>{'content': 'nope'}, report);
      expect(report.messages, isNotEmpty);
      final report2 = OfficeSlidesRenderReport();
      scanOfficeSlidesSections(const <String, Object?>{}, report2);
      expect(report2.messages, isEmpty);
      expect(report2.hasDegradations, isFalse);
    });

    testWidgets('content 不是对象 → 明确的空内容卡片，不崩', (tester) async {
      final report = OfficeSlidesRenderReport();
      await tester.pumpWidget(
        _host(<String, Object?>{'content': 'not-a-map'}, report),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-empty')), findsOneWidget);
      expect(find.textContaining('没有可显示的幻灯片'), findsOneWidget);
      expect(
        report.messages.any((m) => m.contains('content section 不是对象')),
        isTrue,
      );
    });

    test('officeSlidesParseColor：认不出返回 null（不抛）', () {
      expect(officeSlidesParseColor('#fff'), const Color(0xffffffff));
      expect(officeSlidesParseColor('#141e32'), const Color(0xff141e32));
      expect(
        officeSlidesParseColor('rgb(20, 30, 50)'),
        const Color(0xff141e32),
      );
      expect(officeSlidesParseColor('transparent'), isNull);
      expect(officeSlidesParseColor('not-a-color'), isNull);
      expect(officeSlidesParseColor(42), isNull);
    });
  });

  group('S6. 批 2 编辑接线（点按 / 乐观显示 / pending 标记）', () {
    Map<String, Object?> baseOf(Map<String, Object?> sections) =>
        asJsonMap(asJsonMap(sections['content'])?['data']) ??
        <String, Object?>{};

    testWidgets('canEdit 时正文块可点按，回调拿到真块', (tester) async {
      final sections = _frameSections();
      final sink = _ViewFakeSink();
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: baseOf(sections),
        initialVersion: 7,
      )..editable = true;
      OfficeSlidesEditableBlock? tapped;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OfficeSlidesView(
              sections: sections,
              edit: edit,
              onEditBlock: (b) => tapped = b,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final block = edit.blocks.firstWhere((b) => b.editable);
      final gesture = find.byKey(Key('office-slide-edit-${block.id}'));
      expect(gesture, findsOneWidget, reason: '块 ${block.id} 应可点按');
      await tester.tap(gesture);
      await tester.pumpAndSettle();
      expect(tapped?.id, block.id);
      edit.dispose();
      await sink.close();
    });

    testWidgets('未确认块 → 乐观文本 + pending 标记', (tester) async {
      final sections = _frameSections();
      final sink = _ViewFakeSink()..holdSends = true;
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: baseOf(sections),
        initialVersion: 7,
      )..editable = true;
      final block = edit.blocks.firstWhere((b) => b.editable);
      await edit.editBlockText(block.id, 'PENDING-TEXT');
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OfficeSlidesView(
              sections: sections,
              edit: edit,
              onEditBlock: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('office-slide-pending-${block.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('office-slide-pending-text-${block.id}')),
        findsOneWidget,
      );
      expect(find.text('PENDING-TEXT'), findsOneWidget);
      edit.dispose();
      await sink.close();
    });

    testWidgets('canEdit=false → 有标记但 onTap 为空（不伪装可编辑）', (tester) async {
      final sections = _frameSections();
      final sink = _ViewFakeSink();
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: baseOf(sections),
        initialVersion: 7,
      );
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OfficeSlidesView(sections: sections, edit: edit),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final block = edit.blocks.first;
      final gesture = tester.widget<GestureDetector>(
        find.byKey(Key('office-slide-edit-${block.id}')),
      );
      expect(gesture.onTap, isNull);
      edit.dispose();
      await sink.close();
    });
  });
}

/// view 测试用的最小假通道。
class _ViewFakeSink implements OfficeSlidesCommandSink {
  bool holdSends = false;
  final StreamController<OfficeCollabEvent> _in =
      StreamController<OfficeCollabEvent>.broadcast();

  @override
  Future<Object?> sendEvent(Map<String, Object?> frame) async {
    if (holdSends) return Completer<Object?>().future; // 永久挂起
    return <Object?>[
      null,
      <String, Object?>{'version': 99},
    ];
  }

  @override
  Future<Object?> poll(int version) async => <Object?>[
    null,
    <String, Object?>{'version': version, 'wait': true, 'steps': <Object?>[]},
  ];

  @override
  Stream<OfficeCollabEvent> get incoming => _in.stream;

  Future<void> close() => _in.close();
}
