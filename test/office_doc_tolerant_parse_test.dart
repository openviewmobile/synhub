// 「`Restaurant menu.odoc` 打不开」这个 bug 的**离线**用例（**不发起任何 NAS 请求**）。
//
// ## 现象与根因（父 agent 真机复现 + 本批定位）
// * 现象：真机打开 `Restaurant menu.odoc` → 「打开失败 / 操作未能完成」；
//   logcat：`I/flutter: [office:describeError] MalformedDocNodeException:
//   malformed doc node at $content[0]: "marks" is only valid on text nodes`。
// * 5 份官方样本里**只有这一份**会炸。
// * 根因：服务端回包的内容树里，**非文本节点**（`picture`）上带了 `marks`；
//   而协作层校验器 `lib/src/data/office_collab/doc_schema.dart` 明确拒绝这种形态
//   （注释：`` `marks` on a non-text node is not produced by the fork; reject it. ``）
//   ⇒ **抛异常 ⇒ 整篇文档一个字节都渲染不出来**。
//
// ## 本批的处置（父 agent 批准的方案 A：只改**解析/校验/降级**，不碰任何写路径）
// * 校验器**一个字都没改**（`doc_schema.dart` 不在本批改动清单里，
//   既有用例 `office_collab_m1_schema_test.dart` 仍要求它抛）；
// * 改的是**只读调用点**（`office_doc_page.dart` 的 `loadSnapshot`）：
//   走 `officeDocParseNodeTolerant` —— 把**非文本节点上的 `marks` 摘掉**后重试，
//   成功就继续渲染，并把"摘了什么、摘了几处"记成一条**如实上报**的 note。
//
// ## 这是不是"放宽校验"
// **不是**。校验器语义完全保留：`DocNode.fromRawJson` 对同一份数据**照样抛**
// （本文件 T5 逐条断言这一点）。变的是**调用点的降级策略**：
// 从"违规 ⇒ 整篇不可读"改成"违规 ⇒ 忽略那处非法 marks + 明确登记 + 继续读"。
// 编辑/OT/写路径一个都没走这条通道（它们仍用严格校验）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/doc_schema.dart';
import 'package:synhub/src/features/office/office_doc_tolerant_parse.dart';

const List<String> _allSamples = <String>[
  'restaurant_menu',
  'product_spec',
  'student_report',
  'five_day_trip_planner',
  'vacation_packing_list',
];

/// 官方样本的**内容树**（`provenance.content.data`，即 `Snapshot:get` 的 `data`）。
Map<String, Object?> _contentTree(String name) {
  final raw =
      jsonDecode(
            File(
              'test/fixtures/office_doc_redesign/${name}_snapshot.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final content = raw['content']! as Map<String, Object?>;
  return content['data']! as Map<String, Object?>;
}

/// 数出"挂在非文本节点上的 marks"有多少处、多少条。
({int nodes, int marks}) _illegalMarks(Object? node) {
  var nodes = 0;
  var marks = 0;
  void walk(Object? n) {
    if (n is List) {
      for (final c in n) {
        walk(c);
      }
      return;
    }
    if (n is! Map) return;
    final type = n['type'];
    final m = n['marks'];
    if (type != 'text' && m is List && m.isNotEmpty) {
      nodes++;
      marks += m.length;
    }
    walk(n['content']);
  }

  walk(node);
  return (nodes: nodes, marks: marks);
}

ODocxLikeTolerantResult _tolerant(String name) =>
    officeDocParseNodeTolerant(_contentTree(name));

void main() {
  // =========================================================================
  // 1. 触发条件：**只有** `restaurant_menu` 违规
  // =========================================================================
  group('M. 触发条件（真样本逐份统计）', () {
    test('M1. 5 份官方样本里只有 `restaurant_menu` 在非文本节点上带 marks', () {
      final counts = <String, ({int nodes, int marks})>{
        for (final n in _allSamples) n: _illegalMarks(_contentTree(n)),
      };
      expect(counts['restaurant_menu']!.nodes, 10, reason: '10 个 picture 节点');
      expect(counts['restaurant_menu']!.marks, 25, reason: '合计 25 条 mark');
      for (final n in _allSamples.where((x) => x != 'restaurant_menu')) {
        expect(counts[n]!.nodes, 0, reason: '$n 不该有非法 marks');
        expect(counts[n]!.marks, 0);
      }
    });

    test('M2. **严格**校验：`restaurant_menu` 抛、其余 4 份不抛', () {
      for (final n in _allSamples) {
        Object? err;
        try {
          DocNode.fromRawJson(_contentTree(n));
        } on Object catch (e) {
          err = e;
        }
        if (n == 'restaurant_menu') {
          expect(err, isA<MalformedDocNodeException>());
          expect('$err', contains('only valid on text nodes'));
          expect('$err', contains(r'$content[0]'));
        } else {
          expect(err, isNull, reason: '$n 不该抛');
        }
      }
    });
  });

  // =========================================================================
  // 2. 容忍解析：能读出来 + 如实上报
  // =========================================================================
  group('T. `officeDocParseNodeTolerant`', () {
    test('T1. `restaurant_menu` 现在**能解析出文档**（不再整篇不可读）', () {
      final r = _tolerant('restaurant_menu');
      expect(r.node, isNotNull, reason: '这就是"打不开"的修复点');
      expect(r.node!.type, 'doc');
      expect(r.node!.content, isNotNull);
      expect(r.node!.content!.isNotEmpty, isTrue);
    });

    test('T2. **如实上报**：note 说明摘了几处、多少条、摘的是什么', () {
      final r = _tolerant('restaurant_menu');
      final note = r.note;
      expect(note, isNotNull, reason: '不能静默吞掉');
      expect(note, contains('10'), reason: '节点数要写出来');
      expect(note, contains('25'), reason: 'mark 条数要写出来');
      expect(note, contains('marks'), reason: '要说清楚摘的是 marks');
      // 不静默：note 会被 `office_doc_page.dart` 追加进 `layoutNote` 上屏。
    });

    test('T3. 摘掉的**只有**非文本节点上的 marks；文本节点的 marks 原样保留', () {
      final tree = _contentTree('restaurant_menu');
      final r = officeDocParseNodeTolerant(tree);
      expect(r.node, isNotNull);
      Map<String, Object?>? findPicture(Object? n) {
        if (n is List) {
          for (final c in n) {
            final f = findPicture(c);
            if (f != null) return f;
          }
          return null;
        }
        if (n is! Map) return null;
        if (n['type'] == 'picture') return n.cast<String, Object?>();
        return findPicture(n['content']);
      }

      final picture = findPicture(r.node!.toRawJson());
      expect(picture, isNotNull, reason: 'picture 节点本身必须还在（只摘 marks）');
      expect(picture!['marks'], isNull);
      // picture 的布局信息在 `attrs.config` 里（`office_doc_view.dart` 的
      // `_imageNode` 读的是它），所以摘 marks **不会**影响图片的尺寸/位置。
      expect(picture['attrs'], isNotNull);
    });

    test('T4. 4 份合法样本：**同一个对象**返回、note 为空（不产生任何副作用）', () {
      for (final n in _allSamples.where((x) => x != 'restaurant_menu')) {
        final tree = _contentTree(n);
        final r = officeDocParseNodeTolerant(tree);
        expect(r.node, isNotNull);
        expect(r.note, isNull, reason: '$n 没有违规，不该有 note');
        // **对象同一性**：没改动就不重建（零深拷贝、零行为变化）。
        // 注意：要看的是**清洗器**的输出引用（`DocNode.toRawJson()` 每次都会重建）。
        final cleaned = officeDocStripNonTextMarks(tree);
        expect(cleaned.changed, isFalse);
        expect(identical(cleaned.json, tree), isTrue, reason: '$n 应原样返回同一个对象');
        expect(cleaned.strippedNodes, 0);
        expect(cleaned.strippedMarks, 0);
      }
    });

    test('T5. 合法样本经容忍解析后，与**严格**解析结果一致', () {
      for (final n in _allSamples.where((x) => x != 'restaurant_menu')) {
        final tree = _contentTree(n);
        final strict = DocNode.fromRawJson(tree);
        final tolerant = officeDocParseNodeTolerant(tree).node!;
        expect(
          jsonEncode(tolerant.toRawJson()),
          jsonEncode(strict.toRawJson()),
          reason: '$n 两条路径必须给出同一棵树',
        );
      }
    });

    test('T6. 校验器**没有被放宽**：同一份数据 `DocNode.fromRawJson` 照样抛', () {
      final tree = _contentTree('restaurant_menu');
      expect(
        () => DocNode.fromRawJson(tree),
        throwsA(isA<MalformedDocNodeException>()),
        reason: '严格校验语义必须原样保留（只读调用点自己选择了降级）',
      );
      // 而容忍解析对同一份数据成功 —— 两者并存，互不削弱。
      expect(officeDocParseNodeTolerant(tree).node, isNotNull);
    });

    test('T7. `marks: []`（空数组）**同样非法**（校验器只看"键存在且非 null"）', () {
      // 用**没有必填 attrs** 的节点类型（`paragraph`）来验证空数组这一支。
      final tree = <String, Object?>{
        'type': 'doc',
        'content': <Object?>[
          <String, Object?>{
            'type': 'paragraph',
            'attrs': <String, Object?>{},
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'x'},
            ],
            'marks': <Object?>[],
          },
        ],
      };
      // 严格校验：**空 marks 也抛**（`containsKey && != null` 才是判据）。
      expect(
        () => DocNode.fromRawJson(tree),
        throwsA(isA<MalformedDocNodeException>()),
      );
      // 容忍解析：同样摘掉这个非法的键，并如实上报（计 1 处 / 1 条）。
      final cleaned = officeDocStripNonTextMarks(tree);
      expect(cleaned.changed, isTrue);
      expect(cleaned.strippedNodes, 1);
      expect(cleaned.strippedMarks, 1, reason: '空数组也算"一个非法的键"');
      final r = officeDocParseNodeTolerant(tree);
      expect(r.node, isNotNull);
      expect(r.note, isNotNull);
      // 原始对象没被改（T9 再全面验一次）。
      expect((tree['content']! as List).first, isA<Map>());
    });

    test('T8. 顶层不是对象 → 明确失败（null + 可读说明）；畸形 Map 仍然**抛**', () {
      for (final bad in <Object?>[null, 'not a tree', 42, <Object?>[]]) {
        final r = officeDocParseNodeTolerant(bad);
        expect(r.node, isNull, reason: '$bad 不是文档树');
        // 失败时也要有可读的说明，不是空 note + null。
        expect(r.note, isNotNull);
        expect(r.note, isNotEmpty);
      }
      // 但"是个 Map、只是内容畸形"**不兜底**：校验器的异常照旧上抛，
      // 免得容错变成"什么都当成功"的静默失败。
      expect(
        () => officeDocParseNodeTolerant(<String, Object?>{}),
        throwsA(isA<MalformedDocNodeException>()),
      );
    });

    test('T9. 剥离是**只读**的：不改动传入的对象', () {
      final tree = _contentTree('restaurant_menu');
      final before = jsonEncode(tree);
      officeDocParseNodeTolerant(tree);
      expect(jsonEncode(tree), before, reason: '绝不原地修改调用方的数据');
    });

    test('T10. 反复调用结果稳定（幂等）', () {
      final tree = _contentTree('restaurant_menu');
      final a = officeDocParseNodeTolerant(tree);
      final b = officeDocParseNodeTolerant(tree);
      expect(jsonEncode(a.node!.toRawJson()), jsonEncode(b.node!.toRawJson()));
      expect(a.note, b.note);
    });

    test('T11. 文本节点上的 marks **一条都不能少**（别把好数据也摘了）', () {
      final tree = _contentTree('restaurant_menu');
      int countTextMarks(Object? n) {
        var c = 0;
        void walk(Object? x) {
          if (x is List) {
            for (final y in x) {
              walk(y);
            }
            return;
          }
          if (x is! Map) return;
          if (x['type'] == 'text' && x['marks'] is List) {
            c += (x['marks']! as List).length;
          }
          walk(x['content']);
        }

        walk(n);
        return c;
      }

      final before = countTextMarks(tree);
      final after = countTextMarks(
        officeDocParseNodeTolerant(tree).node!.toRawJson(),
      );
      expect(before, greaterThan(0), reason: '真样本里文本 marks 非空');
      expect(after, before, reason: '文本 marks 必须逐条保留');
    });
  });
}

/// `officeDocParseNodeTolerant` 的返回类型别名（避免测试里写一长串泛型）。
typedef ODocxLikeTolerantResult = OfficeDocTolerantParseResult;
