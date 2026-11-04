// `.osheet` 只读模型的**官方样本硬验收**（阶段 1 的核心标准）。
//
// 样本：`template/sheet/*/text.json`（13 份，包内官方样本，**不 vendored 进仓库**；
// 路径见 `docs/office-native-format-research.md` §5.2）。
//
// 硬标准（研究文档 §9.1 步骤 4–5 / §9.3）：
//   把 text.json **直接喂**给 `OSheetWorkbook.fromSections`，
//   **逐单元格**与原始 JSON 比对：`s`（样式索引）/ `v`（值）/ `f`（公式，推测）/
//   文本 —— 必须 100% 一致，且模型里不能多、不能少任何一个单元格。
//
// 样本缺失时整组 `skip` 并写明原因（样本不在仓库里，换机/清理 /tmp 就会缺）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/office_native_reader.dart';
import 'support/office_samples.dart';

final Directory _root = Directory(
  officeTemplateRoot().path,
);

final String? _skipReason = _root.existsSync()
    ? null
    : '官方样本缺失：${_root.path}（包内样本，不 vendored；'
          '见 docs/office-native-format-research.md §5）';

List<String> _sheetSampleNames() {
  final dir = Directory('${_root.path}/sheet');
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

Map<String, Object?> _readJson(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  return (decoded as Map).cast<String, Object?>();
}

void main() {
  final names = _sheetSampleNames();

  test('样本目录存在时至少 13 份（否则整组 skip 有据可查）', () {
    if (_skipReason != null) {
      markTestSkipped(_skipReason!);
      return;
    }
    expect(names, hasLength(13), reason: '官方 sheet 模板样本应为 13 份');
  }, skip: _skipReason ?? false);

  group('逐单元格 100% 一致（13 份）', () {
    for (final name in names) {
      test(name, () {
        final raw = _readJson('${_root.path}/sheet/$name/text.json');
        final doc = OfficeNativeReader.parseSections(
          raw,
          format: OfficeNativeFormat.osheet,
        );
        final workbook = doc.workbook!;

        final rawSheetIds = raw.keys.where((k) => k.startsWith('sh_')).toList()
          ..sort();
        expect(
          workbook.sheets.map((s) => s.id).toSet(),
          rawSheetIds.toSet(),
          reason: '$name: 工作表集合不一致',
        );

        var rawCellTotal = 0;
        var valueCellTotal = 0;
        var stringCellTotal = 0;
        var zeroStyleCells = 0;

        for (final sheetId in rawSheetIds) {
          final rawSheet = (raw[sheetId] as Map).cast<String, Object?>();
          final rawCells = ((rawSheet['cells'] as Map?) ?? const {})
              .cast<String, Object?>();
          final sheet = workbook.sheetById(sheetId)!;

          // 行数/列数/表名：直接来自 index + section。
          expect(
            sheet.rowCount,
            rawSheet['rowCount'],
            reason: '$sheetId rowCount',
          );
          expect(
            sheet.colCount,
            rawSheet['colCount'],
            reason: '$sheetId colCount',
          );
          expect(
            sheet.title,
            ((raw['index'] as Map)['sheets'] as Map)[sheetId]['title'],
            reason: '$sheetId title',
          );

          // 单元格**数量**必须一致（不能多、不能少）。
          var rawCount = 0;
          for (final row in rawCells.values) {
            rawCount += (row as Map).length;
          }
          expect(sheet.cellCount, rawCount, reason: '$sheetId: 单元格总数不一致');

          // 逐单元格比对。
          final mismatches = <String>[];
          for (final rowEntry in rawCells.entries) {
            final r = int.parse(rowEntry.key);
            final rawRow = (rowEntry.value as Map).cast<String, Object?>();
            for (final colEntry in rawRow.entries) {
              final c = int.parse(colEntry.key);
              final rawCell = (colEntry.value as Map).cast<String, Object?>();
              final cell = sheet.cellAt(r, c);
              if (cell == null) {
                mismatches.add('r$r,c$c: 模型缺该单元格');
                continue;
              }
              if (cell.row != r || cell.col != c) {
                mismatches.add('r$r,c$c: 行列元数据 (${cell.row},${cell.col}) 不符');
              }
              if (cell.styleIndex != rawCell['s']) {
                mismatches.add(
                  'r$r,c$c: s ${cell.styleIndex} != ${rawCell['s']}',
                );
              }
              if (cell.value != rawCell['v']) {
                mismatches.add('r$r,c$c: v ${cell.value} != ${rawCell['v']}');
              }
              if (cell.formula != rawCell['f']) {
                mismatches.add('r$r,c$c: f ${cell.formula} != ${rawCell['f']}');
              }
              final rawValue = rawCell['v'];
              if (rawValue is String) {
                if (cell.text != rawValue) {
                  mismatches.add('r$r,c$c: text "${cell.text}" != "$rawValue"');
                }
                stringCellTotal++;
              }
              if (rawValue != null) valueCellTotal++;
              rawCellTotal++;
            }
          }
          expect(
            mismatches,
            isEmpty,
            reason: '$sheetId 不一致：${mismatches.take(5)}',
          );

          // 模型里也不能有原始 JSON 没有的单元格。
          final extra = <String>[];
          for (final row in sheet.cells.entries) {
            final rawRow = ((rawCells['${row.key}'] as Map?) ?? const {})
                .cast<String, Object?>();
            for (final col in row.value.keys) {
              if (!rawRow.containsKey('$col')) {
                extra.add('r${row.key},c$col');
              }
            }
          }
          expect(extra, isEmpty, reason: '$sheetId 多出单元格：${extra.take(5)}');

          // 样式 id 不变式（13 份样本实测）：`0 <= s <= styles.length`，
          // 且 `s>0` 时必须能按"1 基"回到样式池（越界即为不一致）。
          if (workbook.styles != null) {
            final pool = workbook.styles!;
            for (final cell in sheet.allCells) {
              final s = cell.styleIndex;
              if (s == null) continue;
              expect(s, greaterThanOrEqualTo(0));
              expect(
                s,
                lessThanOrEqualTo(pool.styleCount),
                reason:
                    '$sheetId r${cell.row},c${cell.col}: s=$s > ${pool.styleCount}',
              );
              if (s > 0) {
                expect(
                  pool.slotsAt(s),
                  isNotNull,
                  reason: '$sheetId r${cell.row},c${cell.col}: s=$s 越界',
                );
              }
              if (s == 0) zeroStyleCells++;
            }
          }
        }

        // 打印实测统计（供回报/文档引用）。
        // ignore: avoid_print
        print(
          'SHEET_SAMPLE $name sheets=${workbook.sheets.length} '
          'cells=$rawCellTotal values=$valueCellTotal strings=$stringCellTotal '
          'styles=${workbook.styles?.styleCount ?? 0} zeroStyle=$zeroStyleCells '
          '一致=100%',
        );
      }, skip: _skipReason ?? false);
    }
  });
}
