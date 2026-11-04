// `.odoc` / `.oslides` 只读模型的**官方样本验证**（16 + 24 份）。
//
// 样本：`template/doc/*/text.json`（16 份）与 `template/slides/*/text.json`（24 份）
// —— 包内官方样本，**不 vendored 进仓库**（研究文档 §5.1/§5.3）。
//
// 标准（研究文档 §9.2/§9.3）：文本抽取**非空**、结构合理；每份记录
// 章节/标题/表格/列表数、幻灯片页数与文本长度。样本缺失时 `skip` 并写明原因。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/office_json.dart';
import 'package:synhub/src/data/office_native/office_native_reader.dart';
import 'support/office_samples.dart';

final Directory _root = Directory(
  officeTemplateRoot().path,
);

final String? _skipReason = _root.existsSync()
    ? null
    : '官方样本缺失：${_root.path}（包内样本，不 vendored；'
          '见 docs/office-native-format-research.md §5）';

List<String> _sampleNames(String kind) {
  final dir = Directory('${_root.path}/$kind');
  if (!dir.existsSync()) return const [];
  final names =
      dir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .toList()
        ..sort();
  return names;
}

Map<String, Object?> _readJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

/// 收集子树里所有 `{"type":"text"}` 的文本（只走 `content`）。
List<String> _textNodes(Object? node) {
  final out = <String>[];
  void walk(Object? n) {
    if (n is List) {
      for (final x in n) {
        walk(x);
      }
      return;
    }
    final map = asJsonMap(n);
    if (map == null) return;
    if (asJsonString(map['type']) == 'text') {
      final t = asJsonString(map['text']);
      if (t != null && t.isNotEmpty) out.add(t);
    }
    walk(map['content']);
  }

  walk(node);
  return out;
}

void main() {
  final docNames = _sampleNames('doc');
  final slidesNames = _sampleNames('slides');

  test('样本目录存在时 doc=16 / slides=24', () {
    if (_skipReason != null) {
      markTestSkipped(_skipReason!);
      return;
    }
    expect(docNames, hasLength(16));
    expect(slidesNames, hasLength(24));
  }, skip: _skipReason ?? false);

  group('template/doc/*/text.json → .odoc 模型（16 份）', () {
    for (final name in docNames) {
      test(name, () {
        final raw = _readJson('${_root.path}/doc/$name/text.json');
        final doc = OfficeNativeReader.parseSections(raw);
        expect(doc.format, OfficeNativeFormat.odoc, reason: '格式自动判别');
        final model = doc.document!;

        // 结构非空。
        expect(model.blocks, isNotEmpty, reason: '$name: 正文块为空');
        expect(model.plainText.trim(), isNotEmpty, reason: '$name: 正文文本为空');
        expect(model.schema, 13);
        expect(model.version, isNotNull);
        expect(model.pageSetup.pageType, 'a4');
        expect(model.pageSetup.orientation, 'portrait');

        // 正文文本必须覆盖 edit_area 里**全部** text 节点（不丢字）。
        final data = asJsonMap(asJsonMap(raw['content'])?['data']);
        final editArea = findFirstNodeByType(data?['content'], 'edit_area');
        final nodes = _textNodes(editArea?['content']);
        expect(nodes, isNotEmpty, reason: '$name: edit_area 无 text 节点');
        final joined = model.plainText;
        for (final t in nodes) {
          expect(joined.contains(t), isTrue, reason: '$name: 正文漏了 "$t"');
        }

        // ignore: avoid_print
        print(
          'DOC_SAMPLE $name blocks=${model.blocks.length} '
          'headings=${model.headings.length} lists=${model.listItems.length} '
          'tables=${model.tables.length} images=${model.images.length} '
          'textLen=${model.textLength} textNodes=${nodes.length} '
          'nodeTypes=${model.nodeTypeCounts.length}',
        );
      }, skip: _skipReason ?? false);
    }
  });

  group('template/slides/*/text.json → .oslides 模型（24 份）', () {
    for (final name in slidesNames) {
      test(name, () {
        final raw = _readJson('${_root.path}/slides/$name/text.json');
        final doc = OfficeNativeReader.parseSections(raw);
        expect(doc.format, OfficeNativeFormat.oslides, reason: '格式自动判别');
        final model = doc.presentation!;

        expect(model.slides, isNotEmpty, reason: '$name: 无幻灯片');
        expect(model.schema, 13);
        expect(model.cx, 960);
        expect(model.cy, 540);

        // 页序 = slide_container 里 slide 节点的文档顺序。
        final data = asJsonMap(asJsonMap(raw['content'])?['data']);
        final slideContainer = findFirstNodeByType(
          data?['content'],
          'slide_container',
        );
        final rawSlides = findNodesByType(slideContainer?['content'], 'slide');
        expect(model.slides, hasLength(rawSlides.length), reason: '$name: 页数');
        for (var i = 0; i < rawSlides.length; i++) {
          expect(
            model.slides[i].id,
            asJsonString(asJsonMap(rawSlides[i]['attrs'])?['id']),
            reason: '$name: 第 ${i + 1} 页顺序/ id 不一致',
          );
        }

        // 每页正文必须覆盖该页 slide_content_container 的所有 text 节点；
        // 同时统计"整份样本里到底有没有 text 节点"。
        // 实测：24 份**主题模板**里有一批是纯主题（只有母版/版式占位符，
        // 全篇 0 个 `text` 节点），此时"文本非空"不可能成立——如实记录，
        // 不为了让断言好看而造假。
        var harvested = 0;
        final masterNodes = _textNodes(
          findFirstNodeByType(data?['content'], 'master_container')?['content'],
        );
        harvested += masterNodes.length;
        for (final t in masterNodes) {
          expect(
            model.master.plainText.contains(t),
            isTrue,
            reason: '$name master: 漏了 "$t"',
          );
        }
        var slideTextNodes = 0;
        for (var i = 0; i < rawSlides.length; i++) {
          final contentContainer = findFirstNodeByType(
            rawSlides[i]['content'],
            'slide_content_container',
          );
          final nodes = _textNodes(contentContainer?['content']);
          slideTextNodes += nodes.length;
          harvested += nodes.length;
          final text = model.slides[i].plainText;
          for (final t in nodes) {
            expect(
              text.contains(t),
              isTrue,
              reason: '$name p${i + 1}: 漏了 "$t"',
            );
          }
        }
        final union = '${model.master.plainText}\n${model.plainText}';
        if (harvested == 0) {
          expect(
            union.trim(),
            isEmpty,
            reason: '$name: 样本无 text 节点（纯主题），不应抽出真实文字',
          );
        } else {
          // 不 trim：样本里有些占位符是 U+00A0（不可见但确实是 text 节点）。
          expect(union, isNotEmpty, reason: '$name: 文本为空');
        }

        // ignore: avoid_print
        print(
          'SLIDES_SAMPLE $name pages=${model.slides.length} '
          'layouts=${model.layoutCount} images=${model.imageCount} '
          'textLen=${model.textLength} slideTextNodes=$slideTextNodes '
          'masterTextNodes=${masterNodes.length} '
          'masterBlocks=${model.master.blocks.length} '
          'nodeTypes=${model.nodeTypeCounts.length}',
        );
      }, skip: _skipReason ?? false);
    }
  });
}
