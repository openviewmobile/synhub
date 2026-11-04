// Office C′ 编辑器 UI 批 2 —— 编辑链路（位置算术 / step 构造 / 逆 step）离线测试。
//
// 预言机 = `test/fixtures/office_collab/transform_vectors.json`：官方
// `server/common/prosemirror/index.js` bundle 产出的 `result`。逆 step 的验证方式是
// **把 my-inverse 作用在官方 result 上，必须逐字节回到原始 doc**——即用官方
// transform 的输出来约束我们的逆 step。
//
// 无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/doc_schema.dart';
import 'package:synhub/src/data/office_collab/doc_step.dart';
import 'package:synhub/src/data/office_collab/doc_transform.dart';
import 'package:synhub/src/features/office/office_doc_edit.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/office_collab/$name').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> _asMap(Object? v) => (v as Map).cast<String, Object?>();

void main() {
  final vectors = _fixture('transform_vectors.json');
  final docs = _asMap(vectors['docs']);
  final buckets = _asMap(vectors['vectors']);
  final base = _asMap(docs['docBase']);
  final marked = _asMap(docs['docMarked']);
  final schema = DocSchema.document;

  List<Map<String, Object?>> bucket(String name) =>
      (buckets[name]! as List).map(_asMap).toList();

  List<Map<String, Object?>> stepsOf(Map<String, Object?> v) =>
      (v['steps']! as List).map(_asMap).toList();

  const paragraph = OfficeDocPath(<int>[3, 0]);

  group('E1. 位置算术只用 DocSchema.nodeSize（M1）', () {
    test('真机锚点：正文段落起点 20 / 内容起点 21 / 文本 21..37（16 字）', () {
      final root = DocNode.fromRawJson(base);
      // 向量 `.vectors.text[insert-text-mid-marker]` 在 26 处插入；`.vectors.attrs`
      // 的 `setNodeAttrs pos:20`。段落起点 20、内容起点 21 与 M1 §2.4 /
      // protocol-spike §2.4 的真机锚点一致。
      expect(officeDocNodeStart(root, paragraph), 20);
      expect(officeDocContentStart(root, paragraph), 21);
      expect(
        officeDocNodeSize(root.content![3].content![0]),
        18,
        reason: 'paragraph = 16 字 text + 2',
      );
      expect(
        officeDocInlineText(root.content![3].content![0])!.text.length,
        16,
      );
    });

    test('路径逐级累加 == 手工用 nodeSize 求和的期望值', () {
      final root = DocNode.fromRawJson(base);
      var expected = 0;
      final kids = root.content!;
      for (var i = 0; i < 3; i++) {
        expected += schema.nodeSize(kids[i]);
      }
      // 根的子节点从 0 开始（根自身的 +2 不在位置空间），所以 edit_area 起点 =
      // 前 3 个兄弟的 nodeSize 之和。
      expect(officeDocNodeStart(root, const OfficeDocPath(<int>[3])), expected);
      expect(officeDocNodeSize(kids.first), 1, reason: 'settings 是 leaf');
    });

    test('每个锚点都与 M2 DocResolvedPos.self 交叉一致（偏移约定不另造）', () {
      final root = DocNode.fromRawJson(base);
      for (final path in const <List<int>>[
        <int>[0],
        <int>[1],
        <int>[2],
        <int>[3],
        <int>[3, 0],
        <int>[3, 0, 0],
      ]) {
        final start = officeDocNodeStart(root, OfficeDocPath(path));
        final resolved = DocResolvedPos.resolve(base, start).self;
        expect(resolved, isNotNull, reason: '$path @ $start');
        // M2 的 raw self 与我们的 M1 节点必须是同一个 type。
        final node = officeDocNodeAt(root, start);
        expect(node, isNotNull, reason: '$path @ $start');
        expect(resolved!['type'], node!.type, reason: '$path @ $start');
      }
    });

    test('officeDocNodeAt 找得到段落节点（逆 step 读旧属性用）', () {
      final root = DocNode.fromRawJson(base);
      final at20 = officeDocNodeAt(root, 20);
      expect(at20, isNotNull);
      expect(at20!.type, 'paragraph');
      expect(officeDocNodeAt(root, 21)!.type, 'text');
    });
  });

  group('E2. 文本编辑 step == 官方向量', () {
    final root = DocNode.fromRawJson(base);

    test('中段插入 XYZ → 与 insert-text-mid-marker 的 step 逐字段相同', () {
      final v = bucket(
        'text',
      ).firstWhere((x) => x['id'] == 'insert-text-mid-marker');
      final step = officeDocReplaceText(
        root,
        paragraph,
        charFrom: 5,
        charTo: 5,
        insert: 'XYZ',
      );
      expect(canonicalJson(step.toJson()), canonicalJson(stepsOf(v).single));
      expect(
        step.structure,
        isFalse,
        reason: 'structure 必须 false（M2 write-only）',
      );
      expect(step.slice.openLeft, 0);
      expect(step.slice.openRight, 0);
    });

    test('替换 2..7 为 HELLO → 与 replace-range-with-text 相同', () {
      final v = bucket(
        'text',
      ).firstWhere((x) => x['id'] == 'replace-range-with-text');
      final step = officeDocReplaceText(
        root,
        paragraph,
        charFrom: 2,
        charTo: 7,
        insert: 'HELLO',
      );
      expect(canonicalJson(step.toJson()), canonicalJson(stepsOf(v).single));
    });

    test('删掉 15/16 字（向量 delete-whole-marker 的实际区间）→ slice=null', () {
      final v = bucket(
        'text',
      ).firstWhere((x) => x['id'] == 'delete-whole-marker');
      final step = officeDocReplaceText(
        root,
        paragraph,
        charFrom: 0,
        charTo: 15,
        insert: '',
      );
      expect(canonicalJson(step.toJson()), canonicalJson(stepsOf(v).single));
      expect(step.toJson()['slice'], isNull);
      // 向量名说 "whole marker" 但 21..36 只删了 16 字里的前 15 个；官方结果
      // 里残留 "E"。我们只对齐官方 step/result，不替它改语义。
      final applied = applySteps(base, <DocStep>[step]);
      expect(
        officeDocInlineText(
          DocNode.fromRawJson(applied).content![3].content![0],
        )!.text,
        'E',
      );
    });
  });

  group('E3. 工具栏 step（presence mark / 标题 / 列表）', () {
    test('加粗 0..5 → 与 add-strong-presence 相同', () {
      final root = DocNode.fromRawJson(base);
      final v = bucket(
        'mark',
      ).firstWhere((x) => x['id'] == 'add-strong-presence');
      final step = officeDocAddPresenceMark(
        root,
        paragraph,
        charFrom: 0,
        charTo: 5,
        markName: 'strong',
      );
      expect(canonicalJson(step.toJson()), canonicalJson(stepsOf(v).single));
    });

    test('斜体/下划线 → 与 add-em / add-underline 向量相同', () {
      final root = DocNode.fromRawJson(base);
      for (final pair in <List<String>>[
        <String>['add-em-presence', 'em'],
        <String>['add-underline-presence', 'underline'],
      ]) {
        final v = bucket('mark').firstWhere((x) => x['id'] == pair[0]);
        final official = stepsOf(v).single;
        final officialFrom = official['from']! as int;
        final officialTo = official['to']! as int;
        final step = officeDocAddPresenceMark(
          root,
          paragraph,
          charFrom: officialFrom - 21,
          charTo: officialTo - 21,
          markName: pair[1],
        );
        expect(
          canonicalJson(step.toJson()),
          canonicalJson(official),
          reason: pair[1],
        );
      }
    });

    test('取消加粗 → 与 remove-strong 相同', () {
      final root = DocNode.fromRawJson(marked);
      final v = bucket('mark').firstWhere((x) => x['id'] == 'remove-strong');
      final step = officeDocRemovePresenceMark(
        root,
        paragraph,
        charFrom: 0,
        charTo: 15,
        markName: 'strong',
      );
      expect(canonicalJson(step.toJson()), canonicalJson(stepsOf(v).single));
    });

    test('标题级别与列表都落在 setNodeAttrs pos=20（段落起点）', () {
      final root = DocNode.fromRawJson(base);
      final h = officeDocSetHeadingLevel(root, paragraph, 2);
      expect(h.pos, 20);
      expect(h.attrs['headingLevel'], 2);
      // `setNodeAttrs` 通道的官方证据：`.vectors.attrs[set-paragraph-text-align]`
      // 的 pos 也是 20（同一个段落起点）。
      final officialPos = stepsOf(
        bucket(
          'attrs',
        ).firstWhere((x) => x['id'] == 'set-paragraph-text-align'),
      ).single['pos'];
      expect(h.pos, officialPos);

      final on = officeDocSetList(root, paragraph, on: true, listId: 'list-1');
      expect(on.pos, 20);
      expect(on.attrs['listId'], 'list-1');
      expect(on.attrs['listLevel'], 0);
      expect(on.attrs['listMarks'], isEmpty);

      final off = officeDocSetList(root, paragraph, on: false);
      expect(
        off.attrs.values.every((v) => v == null),
        isTrue,
        reason: '关闭列表用 null 删除 attr（M2 mergeSettableAttrs 语义）',
      );
    });

    test('非 text 内联（hard_break）段落不可编辑，明确抛错', () {
      final doc = <String, Object?>{
        'type': 'doc',
        'content': <Object?>[
          <String, Object?>{
            'type': 'edit_area',
            'attrs': <String, Object?>{'listMap': <String, Object?>{}},
            'content': <Object?>[
              <String, Object?>{
                'type': 'paragraph',
                'content': <Object?>[
                  <String, Object?>{'type': 'text', 'text': 'a'},
                  <String, Object?>{'type': 'hard_break'},
                ],
              },
            ],
          },
        ],
      };
      final root = DocNode.fromRawJson(doc);
      expect(officeDocIsEditableBlock(root.content![0].content![0]), isFalse);
      expect(
        () => officeDocReplaceText(
          root,
          const OfficeDocPath(<int>[0, 0]),
          charFrom: 0,
          charTo: 0,
          insert: 'x',
        ),
        throwsA(isA<DocRangeError>()),
      );
    });
  });

  group('E4. 逆 step：my-inverse(官方 result) 逐字节回到原 doc', () {
    // 本批实际发出的 step 类型 = text/mark/attrs 三个桶；
    // `set-paragraph-then-split` 含结构性 replace（openLeft=1）→ 本批不做，逆 step
    // 明确返回 null，故从"可逆"用例里排除并在报告登记。
    const excluded = <String>{'set-paragraph-then-split'};

    test('text/mark/attrs 每个向量的逆 step 都还原', () {
      var checked = 0;
      for (final bucketName in <String>['text', 'mark', 'attrs']) {
        for (final v in bucket(bucketName)) {
          final id = v['id']! as String;
          if (excluded.contains(id)) continue;
          final doc = _asMap(docs[v['doc']]);
          final steps = stepsOf(v).map(DocStep.fromJson).toList();
          final oracleResult = _asMap(v['result']);

          // 先按官方 step 顺序算出每步之前的 doc，再逐字节确认官方 result：
          final befores = <DocJson>[];
          var cur = doc;
          for (final s in steps) {
            befores.add(cur);
            cur = applySteps(cur, <DocStep>[s]);
          }
          expect(
            canonicalJson(cur),
            canonicalJson(oracleResult),
            reason: '$id: 端口应用结果必须等于官方 result',
          );

          // 逆序应用 my-inverse，回到原 doc。
          var back = oracleResult;
          for (var i = steps.length - 1; i >= 0; i--) {
            final inv = officeDocInvertStep(steps[i], befores[i]);
            expect(inv, isNotNull, reason: '$id step#$i 应该有逆 step');
            back = applySteps(back, <DocStep>[inv!]);
          }
          expect(
            canonicalJson(back),
            canonicalJson(doc),
            reason: '$id: 逆 step 必须逐字节还原',
          );
          checked++;
        }
      }
      expect(
        checked,
        greaterThanOrEqualTo(15),
        reason: '至少覆盖 text+mark+attrs 的 15 个向量',
      );
    });

    test('撤销后再重做（逆 step 里再取逆）也回到官方 result', () {
      final v = bucket(
        'mark',
      ).firstWhere((x) => x['id'] == 'add-font-size-valued');
      final doc = _asMap(docs[v['doc']]);
      final step = DocStep.fromJson(stepsOf(v).single);
      final applied = applySteps(doc, <DocStep>[step]);
      final inv = officeDocInvertStep(step, doc)!;
      final undone = applySteps(applied, <DocStep>[inv]);
      expect(canonicalJson(undone), canonicalJson(doc));
      // 逆 step 的逆 step（redo）= 原 step 的效果。
      final redo = officeDocInvertStep(inv, undone)!;
      final redone = applySteps(undone, <DocStep>[redo]);
      expect(canonicalJson(redone), canonicalJson(applied));
    });

    test('结构性 replace（openLeft != 0）逆 step 明确为 null，不假装支持', () {
      final v = bucket(
        'structure',
      ).firstWhere((x) => x['id'] == 'split-marker-middle');
      final doc = _asMap(docs[v['doc']]);
      final step = DocStep.fromJson(stepsOf(v).single);
      expect(officeDocInvertStep(step, doc), isNull);
    });

    test('setNodeAttrs 的逆 step 恢复被覆盖的旧值（deep attr 递归）', () {
      final v = bucket(
        'attrs',
      ).firstWhere((x) => x['id'] == 'set-root-page-setup-partial-orientation');
      final doc = _asMap(docs[v['doc']]);
      final step = DocStep.fromJson(stepsOf(v).single);
      final applied = applySteps(doc, <DocStep>[step]);
      final rootAttrs = _asMap(_asMap(applied)['attrs']);
      final pageSetup = _asMap(rootAttrs['page_setup']);
      expect(pageSetup['orientation'], 'landscape');
      final inv = officeDocInvertStep(step, doc) as SetRootNodeAttrsStep;
      final restored = applySteps(applied, <DocStep>[inv]);
      expect(canonicalJson(restored), canonicalJson(doc));
      final restoredSetup = _asMap(
        _asMap(_asMap(restored)['attrs'])['page_setup'],
      );
      expect(restoredSetup['orientation'], 'portrait');
      // 只回滚 orientation，其它 page_setup 字段不动。
      expect(restoredSetup['left'], pageSetup['left']);
    });
  });

  group('E5. 选区 mark 判定与 411 文案', () {
    test('已全段加粗 → fullyMarked 为 true（决定按钮是取消）', () {
      final root = DocNode.fromRawJson(marked);
      // docMarked: "C3SPIKE-DOC-BAS"(15, font_size+strong) + "E"(无 mark)。
      expect(
        officeDocSelectionFullyMarked(
          root,
          const OfficeDocTextSelection(path: paragraph, start: 0, end: 6),
          'strong',
        ),
        isTrue,
      );
      expect(
        officeDocSelectionFullyMarked(
          root,
          const OfficeDocTextSelection(path: paragraph, start: 0, end: 16),
          'strong',
        ),
        isFalse,
        reason: 'docMarked 只有前 15 个字符带 strong，第 16 个 "E" 不带',
      );
    });

    test('步骤描述能指出"哪一步"', () {
      final root = DocNode.fromRawJson(base);
      final del = officeDocReplaceText(
        root,
        paragraph,
        charFrom: 0,
        charTo: 15,
        insert: '',
      );
      expect(officeDocDescribeStep(del), contains('删除文本'));
      final add = officeDocAddPresenceMark(
        root,
        paragraph,
        charFrom: 0,
        charTo: 3,
        markName: 'em',
      );
      expect(officeDocDescribeStep(add), contains('斜体'));
      final head = officeDocSetHeadingLevel(root, paragraph, 3);
      expect(officeDocDescribeStep(head), contains('标题级别 3'));
    });
  });
}
