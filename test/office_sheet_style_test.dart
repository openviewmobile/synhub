// Office 批 D —— `.osheet` 样式 / 合并 / 条件格式解析（纯函数）的离线用例。
//
// 夹具是**官方随包真实数据**（`test/fixtures/office_templates/sheet_*.json`，
// 逐字节复制自 SPK `template/sheet/*/text.json`；bytes/sha256/出处见同目录
// MANIFEST.json）。
//
// 无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/osheet_model.dart';
import 'package:synhub/src/features/office/office_sheet_style.dart';

Map<String, Object?> _fixture(String name) =>
    (jsonDecode(File('test/fixtures/office_templates/$name').readAsStringSync())
            as Map)
        .cast<String, Object?>();

OSheetStylePool _pool(Map<String, Object?> sections) =>
    OSheetWorkbook.fromSections(sections).styles!;

void main() {
  group('D1. 颜色解析（裸 hex / # / 空 / 垃圾）', () {
    test('裸 hex（真实样本 fonts/fills 形态，无 #）', () {
      expect(officeSheetParseColor('ffffff'), const Color(0xFFFFFFFF));
      expect(officeSheetParseColor('1bb3a6'), const Color(0xFF1BB3A6));
      expect(officeSheetParseColor('000000'), const Color(0xFF000000));
    });

    test('带 # 的边框色（真实样本 borders[].b 形态）', () {
      expect(officeSheetParseColor('#1bb3a6'), const Color(0xFF1BB3A6));
    });

    test('空串 / null / 垃圾 / 非字符串 → null（不猜、不编默认色）', () {
      expect(officeSheetParseColor(''), isNull);
      expect(officeSheetParseColor('   '), isNull);
      expect(officeSheetParseColor(null), isNull);
      expect(officeSheetParseColor('zzzzzz'), isNull);
      expect(officeSheetParseColor(42), isNull);
      expect(officeSheetParseColor(<Object?>[1, 2, 3]), isNull);
    });
  });

  group('D2. 共享样式表解引用（styles[i] 是索引数组，绝不是颜色）', () {
    final pool = _pool(_fixture('sheet_to_do_list_simple.json'));

    test('s=12 → styles[11] 的全部槽位逐项解引用（真实样本）', () {
      // styles[11] = [2, 3, 1, 4, 1, 0, 0]
      //   font=3 → fonts[2]  {c:ffffff,n:Trebuchet MS,sz:24}
      //   fill=1 → fills[0]  {bg:1bb3a6}
      //   align=4 → alignments[3] {h:left,v:bottom}
      //   border=1 → borders[0] {b:[null,null,#1bb3a6,null]}
      final style = officeSheetResolveStyle(pool: pool, styleId: 12);
      expect(style.fontColor, const Color(0xFFFFFFFF));
      expect(style.fontSize, 24);
      expect(style.fontFamily, 'Trebuchet MS');
      expect(style.fillColor, const Color(0xFF1BB3A6));
      expect(style.alignH, 'left');
      expect(style.alignV, 'bottom');
      expect(style.borderBottom, const Color(0xFF1BB3A6));
      expect(style.borderTop, isNull);
      expect(style.borderLeft, isNull);
      expect(style.borderRight, isNull);
      expect(style.numberFormat, isNull);
    });

    test('s=13 → font 12 / align right（与 s=12 不同的解引用结果）', () {
      // styles[12] = [1, 6, 1, 5, 1, 0, 0] → fonts[5] sz=12、alignments[4].h=right
      final style = officeSheetResolveStyle(pool: pool, styleId: 13);
      expect(style.fontSize, 12);
      expect(style.fontFamily, 'Trebuchet MS');
      expect(style.alignH, 'right');
      expect(style.alignV, 'bottom');
    });

    test('s=10 → numberFormat 被解引用登记（M/d/yyyy），但不重排数值', () {
      // styles[9] = [30, 8, 0, 3, 0, 1, 0] → nf=1 → numberFormats[0] {fc:M/d/yyyy}
      final style = officeSheetResolveStyle(pool: pool, styleId: 10);
      expect(style.numberFormat, 'M/d/yyyy');
      expect(style.alignH, 'center');
      expect(style.wrap, isTrue, reason: 'alignments[2].w == wrap');
      // 值本身仍由调用方按原值显示（本模块没有任何数值重排 API）。
    });

    test('`styles[i]` 本身是 List → 不会被当成颜色（解引用纪律）', () {
      final rawStyle = pool.styleAt(12);
      expect(rawStyle, isA<List<Object?>>());
      expect(officeSheetParseColor(rawStyle), isNull);
      // 而真正的字色来自 fonts[]，不是 styles[]。
      expect(
        officeSheetResolveStyle(pool: pool, styleId: 12).fontColor,
        const Color(0xFFFFFFFF),
      );
    });

    test('越界 / s=0 / 池为 null → 空样式（不崩）', () {
      expect(officeSheetResolveStyle(pool: pool, styleId: 0).isEmpty, isTrue);
      expect(
        officeSheetResolveStyle(pool: pool, styleId: 9999).isEmpty,
        isTrue,
      );
      expect(officeSheetResolveStyle(pool: null, styleId: 12).isEmpty, isTrue);
      expect(
        officeSheetResolveStyle(pool: pool, styleId: null).isEmpty,
        isTrue,
      );
    });

    test('subsetExpense：字体加粗/斜体/下划线 + 边框四边', () {
      final p = _pool(_fixture('sheet_expense_report.json'));
      // 找一个有 border 的样式，逐项检查解析不崩且形态正确。
      var sawBorder = false;
      var sawBold = false;
      for (var s = 1; s <= p.styleCount; s++) {
        final r = officeSheetResolveStyle(pool: p, styleId: s);
        if (r.hasBorder) sawBorder = true;
        if (r.bold) sawBold = true;
        expect(r.toBoxBorder(), r.hasBorder ? isNotNull : isNull);
      }
      expect(sawBorder, isTrue, reason: 'expense_report 有真实边框样式');
      expect(sawBold, isTrue, reason: 'expense_report 有真实加粗字体');
    });
  });

  group('D3. mergeCells = [r1,c1,r2,c2]（行列区间，非 colspan）', () {
    test('真实样本 5 处合并：归一化 + 锚点/覆盖 + span', () {
      final sheet = _fixture('sheet_to_do_list_simple.json')['sh_1'] as Map;
      final regions = officeSheetMergeRegions(sheet['mergeCells']);
      expect(regions, hasLength(5));
      final index = OfficeSheetMergeIndex(regions);

      // [0,1,0,3]：B1:D1（跨 3 列、1 行）
      final b1 = index.anchorAt(0, 1)!;
      expect(b1.colSpan, 3);
      expect(b1.rowSpan, 1);
      expect(b1.a1, 'B1:D1');
      expect(index.isCovered(0, 2), isTrue);
      expect(index.isCovered(0, 3), isTrue);
      expect(index.isCovered(0, 1), isFalse, reason: '锚点不被覆盖');

      // [0,0,1,0]：A1:A2（跨 2 行、1 列）—— 工作表有**行区间**合并
      final a1 = index.anchorAt(0, 0)!;
      expect(a1.rowSpan, 2);
      expect(a1.colSpan, 1);
      expect(index.isCovered(1, 0), isTrue);
    });

    test('反转的四元组也会归一化；坏数据丢弃', () {
      final regions = officeSheetMergeRegions(<Object?>[
        <Object?>[3, 4, 1, 2], // r1>r2, c1>c2
        <Object?>[1, 2, 3], // 长度不对
        <Object?>['x', 1, 2, 3], // 非整数
        <Object?>[-1, 0, 2, 2], // 负行
        <Object?>[0, 0, 1, 1],
        <Object?>[0, 0, 1, 1], // 重复
      ]);
      expect(regions, hasLength(2));
      expect(regions[0].r1, 1);
      expect(regions[0].c1, 2);
      expect(regions[0].r2, 3);
      expect(regions[0].c2, 4);
      expect(regions[1].a1, 'A1:B2');
    });

    test('超出 rowCount/colCount 的区间被夹到边界', () {
      final regions = officeSheetMergeRegions(
        <Object?>[
          <Object?>[0, 0, 99, 99],
        ],
        rowCount: 3,
        colCount: 2,
      );
      expect(regions.single.r2, 2);
      expect(regions.single.c2, 1);
    });
  });

  group('D4. A1 区间（条件格式 ranges）', () {
    test('B4:E33 / C30 / 绝对引用', () {
      final r = parseOfficeSheetRange('B4:E33')!;
      expect((r.r1, r.c1, r.r2, r.c2), (3, 1, 32, 4));
      final single = parseOfficeSheetRange('C30')!;
      expect((single.r1, single.c1, single.r2, single.c2), (29, 2, 29, 2));
      final abs = parseOfficeSheetRange(r'$B$4:$E$33')!;
      expect((abs.r1, abs.c1, abs.r2, abs.c2), (3, 1, 32, 4));
      expect(parseOfficeSheetRange('nope'), isNull);
      expect(parseOfficeSheetRange(''), isNull);
    });

    test('列标题字母互逆', () {
      expect(officeSheetColumnIndex('A'), 0);
      expect(officeSheetColumnIndex('Z'), 25);
      expect(officeSheetColumnIndex('AA'), 26);
      expect(officeSheetColumnIndex('AB'), 27);
      expect(officeSheetColumnLabel(52), 'BA');
      expect(officeSheetColumnIndex(''), isNull);
      expect(officeSheetColumnIndex('A1'), isNull);
    });
  });

  group('D5. 条件格式 cfs（f1 原文，不求值）', () {
    test('to_do_list_simple：color + strike，范围 B4:E33', () {
      final sheet = _fixture('sheet_to_do_list_simple.json')['sh_1'] as Map;
      final cfs = officeSheetConditionalFormats(sheet['cfs']);
      expect(cfs, hasLength(1));
      expect(cfs.single.formula, 'not(isblank(\$C4))');
      expect(cfs.single.type, 'expression');
      expect(cfs.single.ranges.single.contains(3, 1), isTrue);
      expect(cfs.single.ranges.single.contains(2, 1), isFalse);

      final base = officeSheetResolveStyle(
        pool: _pool(_fixture('sheet_to_do_list_simple.json')),
        styleId: 9,
      );
      final hit = officeSheetApplyConditionalFormats(
        base,
        officeSheetConditionalAt(cfs, 3, 1),
      );
      expect(hit.fontColor, const Color(0xFFB4B8BC));
      expect(hit.strike, isTrue);
      // 范围外不叠加。
      final miss = officeSheetApplyConditionalFormats(
        base,
        officeSheetConditionalAt(cfs, 2, 1),
      );
      expect(miss.fontColor, isNot(const Color(0xFFB4B8BC)));
      expect(miss.strike, isFalse);
    });

    test('to_do_list_professional：cellIs/containsText 多类型都能解析', () {
      final sections = _fixture('sheet_to_do_list_professional.json');
      final sh1 = officeSheetConditionalFormats(
        (sections['sh_1'] as Map)['cfs'],
      );
      expect(sh1, hasLength(3));
      expect(sh1.map((c) => c.type).toSet(), {'cellIs', 'containsText'});
      expect(sh1.any((c) => c.op == 'equal'), isTrue);
      expect(sh1.any((c) => c.text == 'Ongoing'), isTrue);
      // 条件公式**原样保留**（不求值）。
      expect(sh1.first.formula, '"High"');
      // 两张表各 3 条（sh_1 / sh_2 都是真实数据）。
      final sh2 = officeSheetConditionalFormats(
        (sections['sh_2'] as Map)['cfs'],
      );
      expect(sh2, hasLength(3));
    });

    test('bgColor 叠加成填充色，color 叠加成字色', () {
      final base = officeSheetResolveStyle(
        pool: _pool(_fixture('sheet_expense_report.json')),
        styleId: 1,
      );
      final merged = base.mergeConditional(<String, Object?>{
        'bgColor': 'F3F3F3',
        'color': 'e04343',
        'strike': true,
      });
      expect(merged.fillColor, const Color(0xFFF3F3F3));
      expect(merged.fontColor, const Color(0xFFE04343));
      expect(merged.strike, isTrue);
      expect(merged.fromConditionalFormat, isTrue);
    });
  });
}
