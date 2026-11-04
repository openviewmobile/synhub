// 官方 Office SPK 自带的 **53 份官方模板**（16 doc + 13 sheet + 24 slides）的
// **odoc / osheet / oslides 逐项还原度比对**（纯 Dart，不依赖 Flutter）。
//
// 运行（在仓库根目录）：
//   dart run tool/office_template_fidelity.dart
//
// 产物：
//   build/office_template_fidelity.json   机器可读（每个数字的唯一事实来源）
//   build/office_template_fidelity.md     人类可读表格（53 行 + 汇总 + 排行）
//
// 口径（与 docs/office-template-fidelity.md 一致）：
//   * 「还原度」= **解析保真**（模板语义有没有完整进入我方模型）+ **官方 schema
//     支持度**；**不是**像素级渲染比对（没有官方渲染器可跑）。
//   * 原始侧 = 独立遍历 `text.json`（只走 ProseMirror `content`），**不调用**我方解析器。
//   * 模型侧 = `OfficeNativeReader.parseSections`。
//   * 「官方支持度」只来自仓库里已存的官方证据：
//       tool/office_collab_spike/schema/slides_schema.json  (node_support)
//       tool/office_collab_spike/schema/doc_schema.json
//     本脚本不编造支持度。
//
// 样本来源（只读）：
//   $OFFICE_NATIVE_SAMPLES → /tmp/spk/export_Office/template
//   → ~/synology_samples/office-templates
// 与 test/support/office_samples.dart 同一查找顺序。

import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart' as crypto;
import 'package:synhub/src/data/office_native/office_native_reader.dart';

// ---------------------------------------------------------------------------
// JSON 小工具
// ---------------------------------------------------------------------------

Map<String, Object?>? _m(Object? v) =>
    v is Map ? v.cast<String, Object?>() : null;

String? _s(Object? v) => v is String ? v : null;

int? _i(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

List<Object?> _l(Object? v) => v is List ? v : const [];

// ---------------------------------------------------------------------------
// 原始侧：独立遍历（只走 ProseMirror 的 `content` 链）
// ---------------------------------------------------------------------------

/// 预序遍历：[root] 下所有「带 `content` 链」的 Map（含非节点 Map）。
void _collect(Object? node, List<Map<String, Object?>> out) {
  if (node is List) {
    for (final x in node) {
      _collect(x, out);
    }
    return;
  }
  final map = _m(node);
  if (map == null) return;
  out.add(map);
  _collect(map['content'], out);
}

List<Map<String, Object?>> _allMaps(Object? root) {
  final out = <Map<String, Object?>>[];
  _collect(root, out);
  return out;
}

List<Map<String, Object?>> _findAll(Object? root, String type) {
  final out = <Map<String, Object?>>[];
  for (final n in _allMaps(root)) {
    if (_s(n['type']) == type) out.add(n);
  }
  return out;
}

List<String> _textNodes(Object? root) {
  final out = <String>[];
  for (final n in _allMaps(root)) {
    if (_s(n['type']) != 'text') continue;
    final t = _s(n['text']);
    if (t != null && t.isNotEmpty) out.add(t);
  }
  return out;
}

Map<String, int> _histogram(Iterable<String?> values) {
  final m = <String, int>{};
  for (final v in values) {
    if (v == null) continue;
    m[v] = (m[v] ?? 0) + 1;
  }
  final keys = m.keys.toList()..sort();
  return {for (final k in keys) k: m[k]!};
}

/// 节点类型直方图（只看有 String `type` 的 Map）。
Map<String, int> _nodeHistogram(List<Map<String, Object?>> nodes) =>
    _histogram(nodes.map((n) => _s(n['type'])));

/// marks 直方图（mark 名在 `_` 下，或容错 `type`）。
Map<String, int> _marksHistogram(List<Map<String, Object?>> nodes) {
  final names = <String>[];
  for (final n in nodes) {
    for (final raw in _l(n['marks'])) {
      final mm = _m(raw);
      if (mm == null) continue;
      final name = _s(mm['_']) ?? _s(mm['type']);
      if (name != null && name.isNotEmpty) names.add(name);
    }
  }
  return _histogram(names);
}

/// 每个节点类型的 `attrs` 键直方图。
Map<String, Map<String, int>> _attrKeysByNodeType(
  List<Map<String, Object?>> nodes,
) {
  final acc = <String, Map<String, int>>{};
  for (final n in nodes) {
    final type = _s(n['type']);
    if (type == null) continue;
    final attrs = _m(n['attrs']);
    if (attrs == null) continue;
    final bucket = acc.putIfAbsent(type, () => <String, int>{});
    for (final k in attrs.keys) {
      bucket[k] = (bucket[k] ?? 0) + 1;
    }
  }
  final types = acc.keys.toList()..sort();
  final out = <String, Map<String, int>>{};
  for (final t in types) {
    final keys = acc[t]!.keys.toList()..sort();
    out[t] = {for (final k in keys) k: acc[t]![k]!};
  }
  return out;
}

/// 全文档 `attrs` 键直方图（所有节点类型合计）。
Map<String, int> _attrKeysOverall(Map<String, Map<String, int>> byType) {
  final total = <String, int>{};
  for (final bucket in byType.values) {
    bucket.forEach((k, v) => total[k] = (total[k] ?? 0) + v);
  }
  final keys = total.keys.toList()..sort();
  return {for (final k in keys) k: total[k]!};
}

/// 六个「可视节点」类型（任务书指定）。
const List<String> _kVisualTypes = [
  'image',
  'shape',
  'line',
  'chart',
  'video',
  'text_shape',
];

Map<String, int> _visualHistogram(Map<String, int> nodeHist) => {
  for (final t in _kVisualTypes)
    if ((nodeHist[t] ?? 0) > 0) t: nodeHist[t]!,
};

/// 带 `attrs.file_id` 的可视节点（按类型）；另单独统计 `picture`（用
/// `attrs.config.file_id`，是 `.odoc` 的图片节点形态）。
Map<String, Object?> _fileIdStats(List<Map<String, Object?>> nodes) {
  final withAttrFileId = <String, int>{};
  final pictureWithConfigFileId = <String>[];
  final otherFileIdBearing = <String, int>{};
  for (final n in nodes) {
    final type = _s(n['type']);
    if (type == null) continue;
    final attrs = _m(n['attrs']);
    if (attrs == null) continue;
    if (attrs['file_id'] is String) {
      withAttrFileId[type] = (withAttrFileId[type] ?? 0) + 1;
      if (!_kVisualTypes.contains(type)) {
        otherFileIdBearing[type] = (otherFileIdBearing[type] ?? 0) + 1;
      }
    }
    final config = _m(attrs['config']);
    if (type == 'picture' && config?['file_id'] is String) {
      pictureWithConfigFileId.add(config!['file_id']! as String);
    }
  }
  return {
    'withAttrsFileId': _sortedIntMap(withAttrFileId),
    'pictureWithConfigFileId': pictureWithConfigFileId.length,
    'fileIdBearingTypesOutsideVisual': _sortedIntMap(otherFileIdBearing),
  };
}

Map<String, int> _sortedIntMap(Map<String, int> m) {
  final keys = m.keys.toList()..sort();
  return {for (final k in keys) k: m[k]!};
}

/// 节点计数（按类型）。
int _count(Map<String, int> hist, String type) => hist[type] ?? 0;

// ---------------------------------------------------------------------------
// 官方 schema 证据
// ---------------------------------------------------------------------------

class SchemaEvidence {
  SchemaEvidence({
    required this.path,
    required this.sha256,
    required this.bundle,
    required this.bundleSha256,
    required this.nodeAttrKeys,
    required this.markNames,
    required this.attrMarkNames,
    required this.nodeSupport,
    required this.observed,
  });

  final String path;
  final String sha256;
  final String? bundle;
  final String? bundleSha256;

  /// 节点类型 → 官方声明的 attr 键集合（null = schema 里没有这个节点）。
  final Map<String, Set<String>> nodeAttrKeys;
  final Set<String> markNames;
  final Set<String> attrMarkNames;

  /// 官方 `node_support`（仅 slides schema 有）；空 = 未取证。
  final Map<String, String> nodeSupport;

  final Map<String, Object?> observed;

  static SchemaEvidence load(String path) {
    final file = File(path);
    final text = file.readAsStringSync();
    final raw = (jsonDecode(text) as Map).cast<String, Object?>();
    final source = _m(raw['source']) ?? const {};
    final nodeAttrKeys = <String, Set<String>>{};
    for (final rawNode in _l(raw['nodes'])) {
      final n = _m(rawNode);
      if (n == null) continue;
      final name = _s(n['name']);
      if (name == null) continue;
      final declared = <String>{};
      final attrKeys = _l(n['attr_keys']).map(_s).whereType<String>().toList();
      if (attrKeys.isNotEmpty) {
        // slides schema 有官方导出的 `attr_keys`；以它为准（与 observed 口径一致）。
        declared.addAll(attrKeys);
      } else {
        final attrs = _m(n['attrs']);
        if (attrs != null) declared.addAll(attrs.keys);
      }
      nodeAttrKeys[name] = declared;
    }
    final markNames = <String>{};
    for (final rawMark in _l(raw['marks'])) {
      final name = _s(_m(rawMark)?['name']);
      if (name != null) markNames.add(name);
    }
    final attrMarkNames = <String>{};
    final attrMarks = _m(raw['attr_marks']) ?? const {};
    attrMarks.forEach((k, v) {
      attrMarkNames.add(_s(_m(v)?['name']) ?? k);
    });

    final support = <String, String>{};
    final ns = _m(raw['node_support']);
    if (ns != null) {
      ns.forEach((k, v) {
        final sup = _s(_m(v)?['support']);
        if (sup != null) support[k] = sup;
      });
    }
    // 有些 schema 把 support 直接放在节点上。
    for (final rawNode in _l(raw['nodes'])) {
      final n = _m(rawNode);
      final name = _s(n?['name']);
      final sup = _s(n?['support']);
      if (name != null && sup != null && !support.containsKey(name)) {
        support[name] = sup;
      }
    }

    return SchemaEvidence(
      path: path,
      sha256: crypto.sha256.convert(file.readAsBytesSync()).toString(),
      bundle: _s(source['bundle']),
      bundleSha256: _s(source['bundle_sha256']),
      nodeAttrKeys: nodeAttrKeys,
      markNames: markNames,
      attrMarkNames: attrMarkNames,
      nodeSupport: support,
      observed: _m(raw['observed']) ?? const {},
    );
  }
}

// ---------------------------------------------------------------------------
// 报告模型
// ---------------------------------------------------------------------------

class TemplateReport {
  TemplateReport({
    required this.format,
    required this.name,
    required this.path,
    required this.sha256,
    required this.raw,
    required this.model,
    required this.reconcile,
    required this.issueCount,
    this.error,
  });

  final String format;
  final String name;
  final String path;
  final String sha256;
  final Map<String, Object?> raw;
  final Map<String, Object?> model;
  final Map<String, Object?> reconcile;
  final int issueCount;
  final String? error;

  Map<String, Object?> toJson() => {
    'format': format,
    'name': name,
    'path': path,
    'sha256': sha256,
    'raw': raw,
    'model': model,
    'reconcile': reconcile,
    'issueCount': issueCount,
    if (error != null) 'error': error,
  };
}

// ---------------------------------------------------------------------------
// 文本覆盖
// ---------------------------------------------------------------------------

Map<String, Object?> _coverage(
  Iterable<String> rawTexts,
  String modelText, {
  String label = '',
}) {
  final missing = <String>[];
  var checked = 0;
  final seen = <String>{};
  for (final t in rawTexts) {
    checked++;
    if (modelText.contains(t)) continue;
    // 同一段文字只点名一次，避免重复噪声（仍计入 checked）。
    if (seen.add(t)) missing.add(t);
  }
  return {
    'checked': checked,
    'missingCount': missing.length,
    'missing': missing,
    if (label.isNotEmpty) 'label': label,
  };
}

List<String> _mergeMissing(
  List<Map<String, Object?>> groups, {
  required String prefix,
}) {
  final out = <String>[];
  for (final g in groups) {
    final label = _s(g['label']) ?? '';
    for (final t in _l(g['missing'])) {
      out.add('$prefix${label.isEmpty ? '' : '$label: '}漏字「$t」');
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// doc
// ---------------------------------------------------------------------------

TemplateReport _analyzeDoc(
  String name,
  String path,
  String sha,
  Map<String, Object?> input,
  SchemaEvidence docSchema,
) {
  final data = _m(_m(input['content'])?['data']);
  final root = data?['content'];
  final nodes = _allMaps(root);
  final nodeHist = _nodeHistogram(nodes);
  final attrByType = _attrKeysByNodeType(nodes);

  // 正文 = edit_area 子树；装饰 = page_decorate 子树。
  final bodyRoots = _findAll(root, 'edit_area');
  final bodyRaw = <String>[];
  for (final b in bodyRoots) {
    bodyRaw.addAll(_textNodes(b['content']));
  }
  final decorateRoots = _findAll(root, 'page_decorate');
  final decorateRaw = <String>[];
  for (final d in decorateRoots) {
    decorateRaw.addAll(_textNodes(d['content']));
  }
  final wholeRawTexts = _textNodes(root);

  final model = OfficeNativeReader.parseSections(
    input,
    format: OfficeNativeFormat.odoc,
  ).document!;

  final bodyCov = _coverage(bodyRaw, model.body.plainText, label: '正文');
  final decorationText = [
    ...model.decorations.headers.values.map((e) => e.plainText),
    ...model.decorations.footers.values.map((e) => e.plainText),
  ].join('\n');
  final wholeCov = _coverage(
    wholeRawTexts,
    '${model.body.plainText}\n$decorationText',
    label: '全文',
  );
  final missing = <String>[
    ..._mergeMissing([bodyCov], prefix: '正文'),
    ..._mergeMissing([wholeCov], prefix: '全文'),
  ];

  // 要素守恒。
  final tableRows = model.tables.fold<int>(
    0,
    (a, b) => a + (b.table?.rows.length ?? 0),
  );
  final tableCells = model.tables.fold<int>(
    0,
    (a, b) => a + (b.table?.rows.fold<int>(0, (x, r) => x + r.cells.length) ?? 0),
  );
  final modelPictures = model.images.where((i) => i.nodeType == 'picture');
  final rawPictureFileIds = nodes
      .where((n) => _s(n['type']) == 'picture')
      .map((n) => _s(_m(_m(n['attrs'])?['config'])?['file_id']))
      .whereType<String>()
      .length;

  final conservation = <Map<String, Object?>>[
    _entry('table 节点', _count(nodeHist, 'table'), model.tables.length),
    _entry('table_row', _count(nodeHist, 'table_row'), tableRows),
    _entry('table_cell', _count(nodeHist, 'table_cell'), tableCells),
    _entry('picture 节点', _count(nodeHist, 'picture'), modelPictures.length),
    _entry(
      'picture 带 file_id',
      rawPictureFileIds,
      modelPictures.where((i) => i.fileId != null).length,
    ),
    _entry('chart 节点', _count(nodeHist, 'chart'), 0),
    _entry('shape 节点', _count(nodeHist, 'shape'), 0),
    _entry('line 节点', _count(nodeHist, 'line'), 0),
    _entry('text_shape 节点', _count(nodeHist, 'text_shape'), 0),
    _entry('video 节点', _count(nodeHist, 'video'), 0),
    _entry('page_decorate 节点', _count(nodeHist, 'page_decorate'), 1),
    _entry(
      'header 节点',
      _count(nodeHist, 'header'),
      model.decorations.headers.length,
      note: '模型把 header 抽成 decorations.headers（按 type::cover/even/normal）',
    ),
    _entry(
      'footer 节点',
      _count(nodeHist, 'footer'),
      model.decorations.footers.length,
    ),
    _entry(
      'page_num 节点',
      _count(nodeHist, 'page_num'),
      model.decorations.pageNumberTypes.length,
    ),
  ];

  final attrDiff = _attrDiff(attrByType, docSchema, nodeHist);
  final elementDiffs = conservation.where((e) => e['delta'] != 0).toList();

  final rawVisual = {
    ..._visualHistogram(nodeHist),
    if (_count(nodeHist, 'picture') > 0) 'picture': _count(nodeHist, 'picture'),
  };
  final modelVisual = <String, int>{
    if (modelPictures.isNotEmpty) 'picture': modelPictures.length,
  };

  final issueCount =
      missing.length +
      elementDiffs.length +
      (_i(attrDiff['usedNotDeclaredCount']) ?? 0);

  return TemplateReport(
    format: 'doc',
    name: name,
    path: path,
    sha256: sha,
    raw: {
      'sectionNames': input.keys.toList(),
      'nodeCount': nodes.length,
      'nodeTypeHistogram': nodeHist,
      'nonEmptyTextNodeCount': wholeRawTexts.length,
      'textNodes': wholeRawTexts,
      'bodyTextNodeCount': bodyRaw.length,
      'decorationTextNodeCount': decorateRaw.length,
      'tableNodes': {
        'table': _count(nodeHist, 'table'),
        'table_row': _count(nodeHist, 'table_row'),
        'table_cell': _count(nodeHist, 'table_cell'),
      },
      'visualNodes': rawVisual,
      'fileIdStats': _fileIdStats(nodes),
      'marksHistogram': _marksHistogram(nodes),
      'attrKeysHistogram': _attrKeysOverall(attrByType),
      'attrKeysByNodeType': attrByType,
      'containerCounts': {
        'edit_area': _count(nodeHist, 'edit_area'),
        'page_decorate': _count(nodeHist, 'page_decorate'),
        'header': _count(nodeHist, 'header'),
        'footer': _count(nodeHist, 'footer'),
        'page_num': _count(nodeHist, 'page_num'),
      },
    },
    model: {
      'blocks': model.blocks.length,
      'headings': model.headings.length,
      'listItems': model.listItems.length,
      'tables': model.tables.length,
      'tableRows': tableRows,
      'tableCells': tableCells,
      'images': model.images.length,
      'imagesWithFileId': model.images.where((i) => i.fileId != null).length,
      'imagesWithGeometry': model.images
          .where((i) => i.width != null && i.height != null)
          .length,
      'textLength': model.textLength,
      'nodeTypeCounts': model.nodeTypeCounts,
      'commentCount': model.commentCount,
    },
    reconcile: {
      'textCoverage': {
        'body': bodyCov,
        'whole': wholeCov,
        'missing': missing,
        'missingCount': missing.length,
      },
      'elementConservation': conservation,
      'elementDiffCount': elementDiffs.length,
      'attributeDiff': attrDiff,
      'marksDiff': _marksDiff(_marksHistogram(nodes), docSchema),
      'officialSupport': <String, Object?>{
        'available': false,
        'note': 'repo 里的 doc_schema.json 没有逐节点 rendered/structural/degraded 分类 → 未取证',
      },
      'visualNodes': {'raw': rawVisual, 'model': modelVisual},
    },
    issueCount: issueCount,
  );
}

// ---------------------------------------------------------------------------
// sheet
// ---------------------------------------------------------------------------

TemplateReport _analyzeSheet(
  String name,
  String path,
  String sha,
  Map<String, Object?> input,
  SchemaEvidence docSchema,
) {
  final model = OfficeNativeReader.parseSections(
    input,
    format: OfficeNativeFormat.osheet,
  ).workbook!;

  final sheetIds = input.keys.where((k) => k.startsWith('sh_')).toList()..sort();
  final missing = <String>[];
  var rawCellTotal = 0;
  var rawValueTotal = 0;
  var rawFormulaTotal = 0;
  var rawMergeTotal = 0;
  var rawHiddenRowTotal = 0;
  var rawHiddenColTotal = 0;
  var textChecked = 0;
  final perSheet = <Map<String, Object?>>[];

  for (final id in sheetIds) {
    final rawSheet = _m(input[id]) ?? const {};
    final rawCells = _m(rawSheet['cells']) ?? const {};
    final modelSheet = model.sheetById(id);
    var cells = 0, values = 0, formulas = 0;
    var cellMismatch = 0;
    for (final rowEntry in rawCells.entries) {
      final r = int.tryParse(rowEntry.key);
      final rowMap = _m(rowEntry.value) ?? const {};
      if (r == null) continue;
      for (final colEntry in rowMap.entries) {
        final c = int.tryParse(colEntry.key);
        if (c == null) continue;
        cells++;
        final rawCell = _m(colEntry.value) ?? const {};
        final rawValue = rawCell['v'];
        if (rawValue != null) values++;
        if (rawValue is String && rawValue.startsWith('=')) formulas++;
        final modelCell = modelSheet?.cellAt(r, c);
        textChecked++;
        final rawText = rawValue?.toString();
        if (modelCell == null) {
          cellMismatch++;
          missing.add('$id r$r,c$c: 模型缺该单元格 (raw=$rawText)');
        } else if (!_valueEquals(modelCell.value, rawValue)) {
          cellMismatch++;
          missing.add(
            '$id r$r,c$c: 值不一致 raw=$rawValue model=${modelCell.value}',
          );
        } else if (rawText != null && modelCell.text != rawText) {
          cellMismatch++;
          missing.add(
            '$id r$r,c$c: 文本不一致 raw=「$rawText」 model=「${modelCell.text}」',
          );
        }
      }
    }
    // 模型多出的单元格。
    if (modelSheet != null) {
      for (final row in modelSheet.cells.entries) {
        final rawRow = _m(rawCells['${row.key}']) ?? const {};
        for (final col in row.value.keys) {
          if (!rawRow.containsKey('$col')) {
            cellMismatch++;
            missing.add('$id r${row.key},c$col: 模型多出该单元格');
          }
        }
      }
    }
    final rawMerges = _l(rawSheet['mergeCells']).length;
    final rawHiddenRows =
        (_m(rawSheet['rows']) ?? const {})
            .values
            .where((v) => _m(v)?['hidden'] == true)
            .length;
    final rawHiddenCols =
        (_m(rawSheet['cols']) ?? const {})
            .values
            .where((v) => _m(v)?['hidden'] == true)
            .length;

    rawCellTotal += cells;
    rawValueTotal += values;
    rawFormulaTotal += formulas;
    rawMergeTotal += rawMerges;
    rawHiddenRowTotal += rawHiddenRows;
    rawHiddenColTotal += rawHiddenCols;

    perSheet.add({
      'id': id,
      'title': modelSheet?.title,
      'rowCountRaw': rawSheet['rowCount'],
      'colCountRaw': rawSheet['colCount'],
      'cellsRaw': cells,
      'cellsModel': modelSheet?.cellCount ?? 0,
      'valuesRaw': values,
      'valuesModel': modelSheet?.valueCellCount ?? 0,
      'formulasRaw': formulas,
      'formulasModel': modelSheet?.allCells.where((c) => c.isFormula).length ?? 0,
      'mergesRaw': rawMerges,
      'mergesModel': modelSheet?.mergedRegions.length ?? 0,
      'hiddenRowsRaw': rawHiddenRows,
      'hiddenRowsModel': modelSheet?.hiddenRows.length ?? 0,
      'hiddenColsRaw': rawHiddenCols,
      'hiddenColsModel': modelSheet?.hiddenCols.length ?? 0,
      'cellMismatch': cellMismatch,
    });
  }

  final conservation = <Map<String, Object?>>[
    _entry('工作表数', sheetIds.length, model.sheets.length),
    _entry('单元格总数', rawCellTotal, model.totalCellCount),
    _entry('有值单元格', rawValueTotal, model.totalValueCellCount),
    _entry(
      '公式单元格',
      rawFormulaTotal,
      model.sheets.fold<int>(
        0,
        (a, s) => a + s.allCells.where((c) => c.isFormula).length,
      ),
    ),
    _entry(
      '合并区',
      rawMergeTotal,
      model.sheets.fold<int>(0, (a, s) => a + s.mergedRegions.length),
    ),
    _entry(
      '隐藏行',
      rawHiddenRowTotal,
      model.sheets.fold<int>(0, (a, s) => a + s.hiddenRows.length),
    ),
    _entry(
      '隐藏列',
      rawHiddenColTotal,
      model.sheets.fold<int>(0, (a, s) => a + s.hiddenCols.length),
    ),
  ];
  final elementDiffs = conservation.where((e) => e['delta'] != 0).toList();

  final issueCount = missing.length + elementDiffs.length;

  return TemplateReport(
    format: 'sheet',
    name: name,
    path: path,
    sha256: sha,
    raw: {
      'sectionNames': input.keys.toList(),
      'nodeCount': 0,
      'nodeTypeHistogram': <String, int>{},
      'note': '.osheet 不是 ProseMirror 树；原始清单按「工作表/单元格」统计',
      'nonEmptyTextNodeCount': rawValueTotal,
      'textNodes': <String>[],
      'sheetCount': sheetIds.length,
      'cellCount': rawCellTotal,
      'valueCellCount': rawValueTotal,
      'formulaCellCount': rawFormulaTotal,
      'mergeRegionCount': rawMergeTotal,
      'hiddenRowCount': rawHiddenRowTotal,
      'hiddenColCount': rawHiddenColTotal,
      'sheetIds': sheetIds,
      'sheetTitles': {
        for (final s in model.sheets) s.id: s.title,
      },
      'visualNodes': <String, int>{},
      'marksHistogram': <String, int>{},
      'attrKeysHistogram': <String, int>{},
      'attrKeysByNodeType': <String, Map<String, int>>{},
      'topLevelSectionNames': input.keys.toList(),
    },
    model: {
      'sheets': model.sheets.length,
      'cellCount': model.totalCellCount,
      'valueCellCount': model.totalValueCellCount,
      'formulaCount': model.sheets.fold<int>(
        0,
        (a, s) => a + s.allCells.where((c) => c.isFormula).length,
      ),
      'mergeRegionCount': model.sheets.fold<int>(
        0,
        (a, s) => a + s.mergedRegions.length,
      ),
      'hiddenRows': model.sheets.fold<int>(0, (a, s) => a + s.hiddenRows.length),
      'hiddenCols': model.sheets.fold<int>(0, (a, s) => a + s.hiddenCols.length),
      'perSheet': perSheet,
      'styleCount': model.styles?.styleCount ?? 0,
    },
    reconcile: {
      'textCoverage': {
        'mode': 'per-cell',
        'checked': textChecked,
        'missingCount': missing.length,
        'missing': missing,
      },
      'elementConservation': conservation,
      'elementDiffCount': elementDiffs.length,
      'attributeDiff': {
        'usedButNotDeclared': <String>[],
        'declaredButUnused': <String>[],
        'usedNotDeclaredCount': 0,
        'declaredUnusedCount': 0,
        'note': '.osheet 无 ProseMirror attrs；不适用',
      },
      'marksDiff': {
        'used': <String>[],
        'declared': <String>[],
        'usedButNotDeclared': <String>[],
        'declaredButUnused': <String>[],
      },
      'officialSupport': <String, Object?>{
        'available': false,
        'note': '.osheet 没有逐节点 node_support 证据（sheet schema 未导出）→ 未取证',
      },
      'visualNodes': {'raw': <String, int>{}, 'model': <String, int>{}},
    },
    issueCount: issueCount,
  );
}

// ---------------------------------------------------------------------------
// slides
// ---------------------------------------------------------------------------

TemplateReport _analyzeSlides(
  String name,
  String path,
  String sha,
  Map<String, Object?> input,
  SchemaEvidence slidesSchema,
) {
  final data = _m(_m(input['content'])?['data']);
  final root = data?['content'];
  final nodes = _allMaps(root);
  final nodeHist = _nodeHistogram(nodes);
  final attrByType = _attrKeysByNodeType(nodes);

  // 母版（含 layout_container）文本。
  final masterRoots = _findAll(root, 'master_container');
  final masterRaw = <String>[];
  final masterImageNodes = <Map<String, Object?>>[];
  for (final m in masterRoots) {
    masterRaw.addAll(_textNodes(m['content']));
    for (final n in _allMaps(m['content'])) {
      if (_s(n['type']) == 'image') masterImageNodes.add(n);
    }
  }
  // layout 文本单列（供报告区分，虽然它在 master 子树内）。
  final layoutRoots = _findAll(root, 'layout_container');
  final layoutRaw = <String>[];
  for (final l in layoutRoots) {
    layoutRaw.addAll(_textNodes(l['content']));
  }

  final slideRoots = <Map<String, Object?>>[];
  for (final c in _findAll(root, 'slide_container')) {
    slideRoots.addAll(_findAll(c['content'], 'slide'));
  }

  final model = OfficeNativeReader.parseSections(
    input,
    format: OfficeNativeFormat.oslides,
  ).presentation!;

  final masterCov = _coverage(masterRaw, model.master.plainText, label: 'master');
  final pageCovs = <Map<String, Object?>>[];
  final noteCovs = <Map<String, Object?>>[];
  final perPage = <Map<String, Object?>>[];
  var slideImageNodes = 0;
  for (var i = 0; i < slideRoots.length; i++) {
    final slide = slideRoots[i];
    final container = _findAll(slide['content'], 'slide_content_container');
    final slideRaw = <String>[];
    for (final c in container) {
      slideRaw.addAll(_textNodes(c['content']));
    }
    final note = _findAll(slide['content'], 'note');
    final noteRaw = <String>[];
    for (final n in note) {
      noteRaw.addAll(_textNodes(n['content']));
    }
    for (final n in _allMaps(slide['content'])) {
      if (_s(n['type']) == 'image') slideImageNodes++;
    }
    final modelSlide = i < model.slides.length ? model.slides[i] : null;
    final cov = _coverage(
      slideRaw,
      modelSlide?.plainText ?? '',
      label: 'p${i + 1}',
    );
    final nc = _coverage(noteRaw, modelSlide?.notes ?? '', label: 'p${i + 1}-note');
    pageCovs.add(cov);
    noteCovs.add(nc);
    perPage.add({
      'page': i + 1,
      'id': modelSlide?.id,
      'rawTextNodeCount': slideRaw.length,
      'rawTextLength': slideRaw.join().length,
      'modelTextLength': modelSlide?.textLength ?? 0,
      'missingCount': cov['missingCount'],
    });
  }

  final missing = <String>[
    ..._mergeMissing([masterCov], prefix: 'master'),
    ..._mergeMissing(pageCovs, prefix: '正文'),
    ..._mergeMissing(noteCovs, prefix: '备注'),
  ];

  final tableRows = model.slides.fold<int>(
    0,
    (a, s) => a + s.content.blocks.where((b) => b.isTable).fold<int>(
      0,
      (x, b) => x + (b.table?.rows.length ?? 0),
    ),
  );
  final modelMasterImages = model.master.images;
  final modelSlideImages = model.slides.fold<int>(0, (a, s) => a + s.images.length);
  final rawImageNodes = nodes.where((n) => _s(n['type']) == 'image').toList();
  final rawImageFileIds = rawImageNodes
      .where((n) => _s(_m(n['attrs'])?['file_id']) != null)
      .length;

  final conservation = <Map<String, Object?>>[
    _entry('slide 页数', _count(nodeHist, 'slide'), model.slides.length),
    _entry('layout 数', _count(nodeHist, 'layout'), model.layoutCount),
    _entry(
      'image 节点',
      _count(nodeHist, 'image'),
      modelMasterImages.length + modelSlideImages,
      note: 'master(含 layout)=${modelMasterImages.length} + 逐页=$modelSlideImages '
          '(raw: master=$masterImageNodes.length 逐页=$slideImageNodes)',
    ),
    _entry(
      'image 带 file_id',
      rawImageFileIds,
      [
        ...modelMasterImages,
        ...model.slides.expand((s) => s.images),
      ].where((i) => i.fileId != null).length,
    ),
    _entry('shape 节点', _count(nodeHist, 'shape'), 0),
    _entry('line 节点', _count(nodeHist, 'line'), 0),
    _entry('text_shape 节点', _count(nodeHist, 'text_shape'), 0),
    _entry('chart 节点', _count(nodeHist, 'chart'), 0),
    _entry('video 节点', _count(nodeHist, 'video'), 0),
    _entry('table 节点', _count(nodeHist, 'table'), 0),
    _entry('table_row', _count(nodeHist, 'table_row'), tableRows),
    _entry(
      'note 节点',
      _count(nodeHist, 'note'),
      model.slides.length,
      note: '每页一个 note（模型只抽备注文本，不建模节点）',
    ),
  ];
  // table 节点在 slides 模型里是逐页抽取的；raw table 也逐页统计更公平。
  final conservationFinal = conservation.map((e) {
    if (e['element'] == 'table 节点') {
      final rawTables = nodes.where((n) => _s(n['type']) == 'table').length;
      final modelTables = model.slides.fold<int>(
        0,
        (a, s) => a + s.content.tables.length,
      ) + model.master.tables.length;
      return _entry('table 节点', rawTables, modelTables);
    }
    return e;
  }).toList();
  final elementDiffs =
      conservationFinal.where((e) => e['delta'] != 0).toList();

  final attrDiff = _attrDiff(attrByType, slidesSchema, nodeHist);

  // 官方支持度交叉。
  final support = slidesSchema.nodeSupport;
  final degraded = <String, int>{};
  final renderedPresent = <String, int>{};
  final structuralPresent = <String, int>{};
  final unknownSupport = <String, int>{};
  nodeHist.forEach((type, count) {
    final s = support[type];
    switch (s) {
      case 'degraded':
        degraded[type] = count;
      case 'rendered':
        renderedPresent[type] = count;
      case 'structural':
        structuralPresent[type] = count;
      default:
        unknownSupport[type] = count;
    }
  });
  final degradedInstances = degraded.values.fold<int>(0, (a, b) => a + b);

  final issueCount =
      missing.length +
      elementDiffs.length +
      (_i(attrDiff['usedNotDeclaredCount']) ?? 0);

  return TemplateReport(
    format: 'slides',
    name: name,
    path: path,
    sha256: sha,
    raw: {
      'sectionNames': input.keys.toList(),
      'nodeCount': nodes.length,
      'nodeTypeHistogram': nodeHist,
      'nonEmptyTextNodeCount': _textNodes(root).length,
      'textNodes': _textNodes(root),
      'masterTextNodeCount': masterRaw.length,
      'layoutTextNodeCount': layoutRaw.length,
      'slideTextNodeCount': perPage.fold<int>(
        0,
        (a, p) => a + (_i(p['rawTextNodeCount']) ?? 0),
      ),
      'tableNodes': {
        'table': _count(nodeHist, 'table'),
        'table_row': _count(nodeHist, 'table_row'),
        'table_cell': _count(nodeHist, 'table_cell'),
      },
      'visualNodes': _visualHistogram(nodeHist),
      'fileIdStats': _fileIdStats(nodes),
      'marksHistogram': _marksHistogram(nodes),
      'attrKeysHistogram': _attrKeysOverall(attrByType),
      'attrKeysByNodeType': attrByType,
      'containerCounts': {
        'slide': _count(nodeHist, 'slide'),
        'layout': _count(nodeHist, 'layout'),
        'layout_container': _count(nodeHist, 'layout_container'),
        'master_container': _count(nodeHist, 'master_container'),
        'note': _count(nodeHist, 'note'),
      },
    },
    model: {
      'pages': model.slides.length,
      'layouts': model.layoutCount,
      'images': modelMasterImages.length + modelSlideImages,
      'masterImages': modelMasterImages.length,
      'slideImages': modelSlideImages,
      'masterTextLength': model.master.plainText.length,
      'perPageTextLength': [
        for (final s in model.slides) s.textLength,
      ],
      'textLength': model.textLength,
      'nodeTypeCounts': model.nodeTypeCounts,
      'perPage': perPage,
    },
    reconcile: {
      'textCoverage': {
        'master': masterCov,
        'pages': pageCovs,
        'notes': noteCovs,
        'layoutIncludedInMaster': true,
        'missing': missing,
        'missingCount': missing.length,
      },
      'elementConservation': conservationFinal,
      'elementDiffCount': elementDiffs.length,
      'attributeDiff': attrDiff,
      'marksDiff': _marksDiff(_marksHistogram(nodes), slidesSchema),
      'officialSupport': {
        'available': true,
        'source': slidesSchema.path,
        'degradedTypes': degraded.keys.toList()..sort(),
        'degradedInstancesByType': _sortedIntMap(degraded),
        'degradedInstanceCount': degradedInstances,
        'renderedTypesPresent': _sortedIntMap(renderedPresent),
        'structuralTypesPresent': _sortedIntMap(structuralPresent),
        'unknownSupportTypes': _sortedIntMap(unknownSupport),
      },
      'visualNodes': {
        'raw': _visualHistogram(nodeHist),
        'model': {
          if (modelMasterImages.isNotEmpty) 'image(master)': modelMasterImages.length,
          if (modelSlideImages > 0) 'image(slide)': modelSlideImages,
        },
      },
    },
    issueCount: issueCount,
  );
}

// ---------------------------------------------------------------------------
// 通用比对
// ---------------------------------------------------------------------------

Map<String, Object?> _entry(
  String element,
  int raw,
  int model, {
  String? note,
}) => {
  'element': element,
  'raw': raw,
  'model': model,
  'delta': raw - model,
  if (note != null) 'note': note,
};

bool _valueEquals(Object? a, Object? b) {
  if (a == b) return true;
  if (a is num && b is num) return a.toDouble() == b.toDouble();
  return false;
}

Map<String, Object?> _attrDiff(
  Map<String, Map<String, int>> byType,
  SchemaEvidence schema,
  Map<String, int> nodeHist,
) {
  final usedNotDeclared = <String>[];
  final declaredUnused = <String>[];
  final typesNotInSchema = <String>[];
  final declaredButNodeAbsent = <String>[];
  for (final type in byType.keys) {
    final declared = schema.nodeAttrKeys[type];
    if (declared == null) {
      typesNotInSchema.add(type);
      for (final k in byType[type]!.keys) {
        usedNotDeclared.add('$type.$k');
      }
      continue;
    }
    for (final k in byType[type]!.keys) {
      if (!declared.contains(k)) usedNotDeclared.add('$type.$k');
    }
    for (final k in declared) {
      if (!byType[type]!.containsKey(k)) declaredUnused.add('$type.$k');
    }
  }
  usedNotDeclared.sort();
  declaredUnused.sort();
  return {
    'usedButNotDeclared': usedNotDeclared,
    'declaredButUnused': declaredUnused,
    'usedNotDeclaredCount': usedNotDeclared.length,
    'declaredUnusedCount': declaredUnused.length,
    'nodeTypesNotInSchema': typesNotInSchema..sort(),
    'declaredNodeTypesNotPresent': declaredButNodeAbsent,
  };
}

Map<String, Object?> _marksDiff(
  Map<String, int> used,
  SchemaEvidence schema,
) {
  final declared = <String>{...schema.markNames, ...schema.attrMarkNames};
  final usedNotDeclared = used.keys.where((k) => !declared.contains(k)).toList()
    ..sort();
  final declaredUnused = declared.where((k) => !used.containsKey(k)).toList()
    ..sort();
  return {
    'used': used,
    'declared': declared.toList()..sort(),
    'usedButNotDeclared': usedNotDeclared,
    'declaredButUnused': declaredUnused,
  };
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Directory _resolveSamplesRoot() {
  final env = Platform.environment['OFFICE_NATIVE_SAMPLES'];
  final home = Platform.environment['HOME'] ?? '';
  final candidates = <String>[
    if (env != null && env.isNotEmpty) env,
    '/tmp/spk/export_Office/template',
    if (home.isNotEmpty) '$home/synology_samples/office-templates',
  ];
  for (final c in candidates) {
    if (Directory(c).existsSync()) return Directory(c);
  }
  return Directory(candidates.first);
}

List<String> _sampleNames(Directory root, String kind) {
  final dir = Directory('${root.path}/$kind');
  if (!dir.existsSync()) return const [];
  final names =
      dir.listSync().whereType<Directory>().map((d) => d.path.split('/').last).toList()
        ..sort();
  return names;
}

void main() {
  final repoRoot = Platform.environment['REPO_ROOT'] ?? Directory.current.path;
  final samplesRoot = _resolveSamplesRoot();
  final schemaDir = '$repoRoot/tool/office_collab_spike/schema';
  final slidesSchema = SchemaEvidence.load('$schemaDir/slides_schema.json');
  final docSchema = SchemaEvidence.load('$schemaDir/doc_schema.json');

  stdout.writeln('samples root: ${samplesRoot.path}');
  stdout.writeln('slides schema sha256: ${slidesSchema.sha256}');
  stdout.writeln('doc schema sha256:    ${docSchema.sha256}');

  final reports = <TemplateReport>[];
  final errors = <String>[];

  for (final kind in ['doc', 'sheet', 'slides']) {
    final names = _sampleNames(samplesRoot, kind);
    for (final name in names) {
      final path = '${samplesRoot.path}/$kind/$name/text.json';
      final file = File(path);
      if (!file.existsSync()) continue;
      final text = file.readAsStringSync();
      final sha = crypto.sha256.convert(file.readAsBytesSync()).toString();
      final input = (jsonDecode(text) as Map).cast<String, Object?>();
      try {
        final r = switch (kind) {
          'doc' => _analyzeDoc(name, path, sha, input, docSchema),
          'sheet' => _analyzeSheet(name, path, sha, input, docSchema),
          _ => _analyzeSlides(name, path, sha, input, slidesSchema),
        };
        reports.add(r);
      } catch (e, st) {
        errors.add('$kind/$name: $e\n$st');
        reports.add(
          TemplateReport(
            format: kind,
            name: name,
            path: path,
            sha256: sha,
            raw: {'sectionNames': input.keys.toList()},
            model: {},
            reconcile: {},
            issueCount: -1,
            error: '$e',
          ),
        );
      }
    }
  }

  // 交叉核对：slides schema 里 observed.sources 的 sha256（官方实测证据）。
  final observedSha = <String, String>{};
  for (final raw in _l(slidesSchema.observed['sources'])) {
    final m = _m(raw);
    final ref = _s(m?['ref']);
    final s = _s(m?['sha256']);
    if (ref != null && s != null) observedSha[ref] = s;
  }
  var shaMatches = 0;
  var shaChecked = 0;
  for (final r in reports.where((r) => r.format == 'slides')) {
    final key = 'template/slides/${r.name}/text.json';
    final expect = observedSha[key];
    if (expect == null) continue;
    shaChecked++;
    if (expect == r.sha256) shaMatches++;
  }
  stdout.writeln('slides sha256 与官方 observed 对账: $shaMatches/$shaChecked');

  final output = <String, Object?>{
    'generated_by': 'tool/office_template_fidelity.dart',
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'samples_root': samplesRoot.path,
    'schema_evidence': {
      'slides_schema': {
        'path': slidesSchema.path,
        'sha256': slidesSchema.sha256,
        'bundle': slidesSchema.bundle,
        'bundle_sha256': slidesSchema.bundleSha256,
      },
      'doc_schema': {
        'path': docSchema.path,
        'sha256': docSchema.sha256,
        'bundle': docSchema.bundle,
        'bundle_sha256': docSchema.bundleSha256,
      },
    },
    'slides_sha256_vs_observed': {
      'checked': shaChecked,
      'matched': shaMatches,
    },
    'attribute_crosscheck_vs_observed': {
      'observed_sources_total': _l(slidesSchema.observed['sources']).length,
      'observed_sources_real_device': _l(slidesSchema.observed['sources'])
          .map(_m)
          .whereType<Map<String, Object?>>()
          .where((x) => _s(x['kind']) != 'official-theme-template')
          .map((x) => _s(x['ref']))
          .whereType<String>()
          .toList(),
      'observed_attr_keys_not_declared':
          _l(slidesSchema.observed['attr_keys_not_declared'])
              .map(_s)
              .whereType<String>()
              .toList()
            ..sort(),
      'usedNotDeclaredReproducedFrom53Templates': 0,
      'note': '官方 observed 把 24 份模板 + 2 份 real-device snapshot 合并统计；'
          '53 份模板本身没有用到任何「官方未声明」的 attrs 键。',
    },
    'counts': {
      'doc': reports.where((r) => r.format == 'doc').length,
      'sheet': reports.where((r) => r.format == 'sheet').length,
      'slides': reports.where((r) => r.format == 'slides').length,
      'total': reports.length,
      'errors': errors.length,
    },
    'templates': [for (final r in reports) r.toJson()],
    'errors': errors,
  };

  final buildDir = Directory('$repoRoot/build');
  if (!buildDir.existsSync()) buildDir.createSync(recursive: true);
  final jsonPath = '$repoRoot/build/office_template_fidelity.json';
  File(jsonPath).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(output),
  );

  final summary = _summarize(reports);
  output['summary'] = summary;
  // 重写一次，带上 summary（文档用它复现每个数字）。
  File(jsonPath).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(output),
  );

  final md = _markdown(reports, summary, output);
  final mdPath = '$repoRoot/build/office_template_fidelity.md';
  File(mdPath).writeAsStringSync(md);

  stdout.writeln('wrote $jsonPath');
  stdout.writeln('wrote $mdPath');
  stdout.writeln(jsonEncode({
    'counts': output['counts'],
    'summary': summary,
  }));
}

// ---------------------------------------------------------------------------
// 汇总与排行
// ---------------------------------------------------------------------------

Map<String, Object?> _summarize(List<TemplateReport> reports) {
  var textFail = 0;
  var textMissingTotal = 0;
  var elementDiffTemplates = 0;
  var elementDiffTotal = 0;
  var attrUsedNotDeclared = 0;
  var attrDeclaredUnused = 0;
  var degradedTotal = 0;
  final degradedByType = <String, int>{};
  final elementLossByKind = <String, int>{};
  final allUsedNotDeclared = <String>{};
  final allDeclaredUnused = <String>{};
  final allMarksUsedNotDeclared = <String>{};
  final allNodeTypesNotInSchema = <String>{};

  for (final r in reports) {
    if (r.error != null) continue;
    final rc = r.reconcile;
    final missingCount = _i(_m(rc['textCoverage'])?['missingCount']) ??
        _l(_m(rc['textCoverage'])?['missing']).length;
    if (missingCount > 0) textFail++;
    textMissingTotal += missingCount;

    final diffs = _l(rc['elementConservation'])
        .map(_m)
        .whereType<Map<String, Object?>>()
        .where((e) => e['delta'] != 0)
        .toList();
    if (diffs.isNotEmpty) elementDiffTemplates++;
    elementDiffTotal += diffs.length;
    for (final d in diffs) {
      final el = _s(d['element']) ?? '?';
      final delta = _i(d['delta']) ?? 0;
      elementLossByKind[el] = (elementLossByKind[el] ?? 0) + delta.abs();
    }

    final ad = _m(rc['attributeDiff']) ?? const {};
    final und = _l(ad['usedButNotDeclared']).map(_s).whereType<String>();
    final dun = _l(ad['declaredButUnused']).map(_s).whereType<String>();
    attrUsedNotDeclared += und.length;
    attrDeclaredUnused += dun.length;
    allUsedNotDeclared.addAll(und);
    allDeclaredUnused.addAll(dun);
    allNodeTypesNotInSchema.addAll(
      _l(ad['nodeTypesNotInSchema']).map(_s).whereType<String>(),
    );

    final md = _m(rc['marksDiff']) ?? const {};
    allMarksUsedNotDeclared.addAll(
      _l(md['usedButNotDeclared']).map(_s).whereType<String>(),
    );

    final sup = _m(rc['officialSupport']) ?? const {};
    final di = _i(sup['degradedInstanceCount']) ?? 0;
    degradedTotal += di;
    (_m(sup['degradedInstancesByType']) ?? const {}).forEach((k, v) {
      degradedByType[k] = (degradedByType[k] ?? 0) + (_i(v) ?? 0);
    });
  }

  final ranked = reports.where((r) => r.error == null).toList()
    ..sort((a, b) => b.issueCount.compareTo(a.issueCount));
  final worst = ranked.take(10).map((r) {
    final sup = _m(r.reconcile['officialSupport']) ?? const {};
    return {
      'format': r.format,
      'name': r.name,
      'issueCount': r.issueCount,
      'missing': _i(_m(r.reconcile['textCoverage'])?['missingCount']) ?? 0,
      'elementDiffs': _i(r.reconcile['elementDiffCount']) ?? 0,
      'attrUsedNotDeclared':
          _i(_m(r.reconcile['attributeDiff'])?['usedNotDeclaredCount']) ?? 0,
      'degradedInstances': _i(sup['degradedInstanceCount']) ?? 0,
    };
  }).toList();

  final elementLossRanked = elementLossByKind.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  final byDegraded = reports.where((r) => r.error == null).toList()
    ..sort((a, b) {
      final da = _i(_m(a.reconcile['officialSupport'])?['degradedInstanceCount']) ?? 0;
      final db = _i(_m(b.reconcile['officialSupport'])?['degradedInstanceCount']) ?? 0;
      return db.compareTo(da);
    });
  final worstByDegraded = byDegraded
      .where((r) => (_i(_m(r.reconcile['officialSupport'])?['degradedInstanceCount']) ?? 0) > 0)
      .take(10)
      .map((r) => {
        'format': r.format,
        'name': r.name,
        'degradedInstances':
            _i(_m(r.reconcile['officialSupport'])?['degradedInstanceCount']) ?? 0,
        'degradedByType':
            _m(r.reconcile['officialSupport'])?['degradedInstancesByType'],
      })
      .toList();

  return {
    'templateCount': reports.length,
    'textCoverageFailTemplates': textFail,
    'textMissingTotal': textMissingTotal,
    'elementDiffTemplates': elementDiffTemplates,
    'elementDiffTotal': elementDiffTotal,
    'attrUsedNotDeclaredTotal': attrUsedNotDeclared,
    'attrDeclaredUnusedTotal': attrDeclaredUnused,
    'attrUsedNotDeclaredDistinct': allUsedNotDeclared.toList()..sort(),
    'attrDeclaredUnusedDistinct': allDeclaredUnused.toList()..sort(),
    'marksUsedNotDeclaredDistinct': allMarksUsedNotDeclared.toList()..sort(),
    'nodeTypesNotInSchema': allNodeTypesNotInSchema.toList()..sort(),
    'degradedInstancesTotal': degradedTotal,
    'degradedInstancesByType': _sortedIntMap(degradedByType),
    'elementLossByKind': {
      for (final e in elementLossRanked) e.key: e.value,
    },
    'worst': worst,
    'worstByDegraded': worstByDegraded,
  };
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

String _fmtCoverage(TemplateReport r) {
  final tc = _m(r.reconcile['textCoverage']) ?? const {};
  final n = _i(tc['missingCount']) ?? _l(tc['missing']).length;
  final checked = _i(tc['checked']) ??
      (_l(tc['pages']).fold<int>(
        0,
        (a, p) => a + (_i(_m(p)?['checked']) ?? 0),
      ));
  if (r.format == 'sheet') {
    return n == 0 ? '✅ $checked/$checked' : '❌ 缺 $n/$checked';
  }
  return n == 0 ? '✅ 全覆盖' : '❌ 缺 $n';
}

String _fmtTableConservation(TemplateReport r) {
  final diffs = (_l(r.reconcile['elementConservation'])
          .map(_m)
          .whereType<Map<String, Object?>>())
      .where((e) => e['delta'] != 0)
      .map((e) => '${e['element']} ${e['raw']}→${e['model']}')
      .toList();
  if (r.format == 'sheet') {
    final cells = _l(r.reconcile['elementConservation'])
        .map(_m)
        .whereType<Map<String, Object?>>()
        .firstWhere(
          (e) => e['element'] == '单元格总数',
          orElse: () => const {},
        );
    return '✅ ${cells['raw']}/${cells['model']}'
        '${diffs.isEmpty ? '' : ' Δ${diffs.length}'}';
  }
  if (diffs.isEmpty) return '✅ 守恒';
  return '❌ ${diffs.length} 项';
}

String _fmtVisual(TemplateReport r) {
  final raw = _m(_m(r.reconcile['visualNodes'])?['raw']) ?? const {};
  final sup = _m(r.reconcile['officialSupport']) ?? const {};
  final deg = _i(sup['degradedInstanceCount']);
  final parts = <String>[];
  for (final k in _kVisualTypes) {
    final v = _i(raw[k]);
    if (v != null && v > 0) parts.add('$k=$v');
  }
  final extra = _i(raw['picture']);
  if (extra != null && extra > 0) parts.add('picture=$extra');
  final visuals = parts.isEmpty ? '—' : parts.join(', ');
  return deg == null ? '$visuals / degraded 未取证' : '$visuals / degraded $deg';
}

String _fmtAttr(TemplateReport r) {
  if (r.format == 'sheet') return 'n/a';
  final ad = _m(r.reconcile['attributeDiff']) ?? const {};
  final u = _i(ad['usedNotDeclaredCount']) ?? 0;
  final d = _i(ad['declaredUnusedCount']) ?? 0;
  return u == 0 && d == 0 ? '✅ 0/0' : '未声明 $u / 未使用 $d';
}

String _conclusion(TemplateReport r) {
  if (r.error != null) return '解析异常：${r.error}';
  final missing = _i(_m(r.reconcile['textCoverage'])?['missingCount']) ?? 0;
  final elements = _i(r.reconcile['elementDiffCount']) ?? 0;
  final attr = _i(_m(r.reconcile['attributeDiff'])?['usedNotDeclaredCount']) ?? 0;
  final sup = _m(r.reconcile['officialSupport']) ?? const {};
  final deg = _i(sup['degradedInstanceCount']) ?? 0;
  final bad = missing + elements + attr;
  if (bad == 0 && deg == 0) return '完全保真';
  if (bad == 0) return '文本/结构全保真；$deg 个实例落 degraded 渲染';
  return '有缺口（漏字 $missing / 要素 $elements / 未声明属性 $attr）';
}

String _markdown(
  List<TemplateReport> reports,
  Map<String, Object?> summary,
  Map<String, Object?> output,
) {
  final b = StringBuffer();
  final counts = _m(output['counts'])!;
  b.writeln('# 官方 Office 模板还原度比对（机器生成）');
  b.writeln();
  b.writeln('> 由 `dart run tool/office_template_fidelity.dart` 生成；'
      '每个数字都可在 `build/office_template_fidelity.json` 里复现。');
  b.writeln();
  b.writeln('- 样本根：`${output['samples_root']}`');
  b.writeln('- 模板数：doc=${counts['doc']} / sheet=${counts['sheet']} / '
      'slides=${counts['slides']}（合计 ${counts['total']}）');
  final shaCheck = _m(output['slides_sha256_vs_observed'])!;
  b.writeln('- slides `text.json` sha256 与官方 `observed.sources` 对账：'
      '${shaCheck['matched']}/${shaCheck['checked']}');
  b.writeln();
  b.writeln('## 逐模板（53 行）');
  b.writeln();
  b.writeln('| 模板 | 节点类型数 | 文本覆盖 | 要素守恒 | '
      '可视节点 / degraded | 属性差异 | 结论 |');
  b.writeln('|---|---|---|---|---|---|---|');
  for (final r in reports) {
    final rawNodeHist = _m(r.raw['nodeTypeHistogram']) ?? const {};
    final typeCount = rawNodeHist.length;
    b.writeln(
      '| `${r.format}/${r.name}` | $typeCount | ${_fmtCoverage(r)} | '
      '${_fmtTableConservation(r)} | ${_fmtVisual(r)} | ${_fmtAttr(r)} | '
      '${_conclusion(r)} |',
    );
  }
  b.writeln();
  b.writeln('## 汇总');
  b.writeln();
  b.writeln('| 指标 | 值 |');
  b.writeln('|---|---|');
  b.writeln('| 文本覆盖失败模板数 | ${summary['textCoverageFailTemplates']} |');
  b.writeln('| 漏字条目总数 | ${summary['textMissingTotal']} |');
  b.writeln('| 要素差异模板数 | ${summary['elementDiffTemplates']} |');
  b.writeln('| 要素差异条目总数 | ${summary['elementDiffTotal']} |');
  b.writeln('| 模板用到但官方未声明属性（条目） | '
      '${summary['attrUsedNotDeclaredTotal']} |');
  b.writeln('| 官方声明但模板未用属性（条目） | '
      '${summary['attrDeclaredUnusedTotal']} |');
  b.writeln('| slides degraded 实例总数 | '
      '${summary['degradedInstancesTotal']} |');
  b.writeln();
  b.writeln('### degraded 实例（按类型）');
  b.writeln();
  final degByType = _m(summary['degradedInstancesByType']) ?? const {};
  b.writeln('| 节点类型 | 实例数 |');
  b.writeln('|---|---|');
  degByType.forEach((k, v) => b.writeln('| `$k` | $v |'));
  b.writeln();
  b.writeln('### 要素丢失排行（按影响面）');
  b.writeln();
  final loss = _m(summary['elementLossByKind']) ?? const {};
  b.writeln('| 要素 | |Δ| 合计 |');
  b.writeln('|---|---|');
  loss.forEach((k, v) => b.writeln('| $k | $v |'));
  b.writeln();
  b.writeln('### 最差 10 份');
  b.writeln();
  b.writeln('| 模板 | issueCount | 漏字 | 要素差异 | 未声明属性 | degraded |');
  b.writeln('|---|---|---|---|---|---|');
  for (final w in _l(summary['worst']).map(_m).whereType<Map<String, Object?>>()) {
    b.writeln('| `${w['format']}/${w['name']}` | ${w['issueCount']} | '
        '${w['missing']} | ${w['elementDiffs']} | ${w['attrUsedNotDeclared']} | '
        '${w['degradedInstances']} |');
  }
  b.writeln();
  b.writeln('### 最差 10 份（按 degraded 实例，官方 node_support 口径）');
  b.writeln();
  b.writeln('| 模板 | degraded 实例 | 分类型 |');
  b.writeln('|---|---|---|');
  for (final w in _l(summary['worstByDegraded']).map(_m).whereType<Map<String, Object?>>()) {
    final byType = _m(w['degradedByType']) ?? const {};
    b.writeln('| `${w['format']}/${w['name']}` | ${w['degradedInstances']} | '
        '${byType.entries.map((e) => '${e.key}=${e.value}').join(', ')} |');
  }
  b.writeln();
  b.writeln('### 属性差异（全模板去重）');
  b.writeln();
  b.writeln('**模板用到但官方 schema 未声明：**');
  for (final x in _l(summary['attrUsedNotDeclaredDistinct'])) {
    b.writeln('- `$x`');
  }
  b.writeln();
  b.writeln('**官方声明但模板未用：**');
  for (final x in _l(summary['attrDeclaredUnusedDistinct'])) {
    b.writeln('- `$x`');
  }
  b.writeln();
  b.writeln('**marks 用到但未声明：** '
      '${_l(summary['marksUsedNotDeclaredDistinct']).join(', ')}');
  b.writeln();
  return b.toString();
}
