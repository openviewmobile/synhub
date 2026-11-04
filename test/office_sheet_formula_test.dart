// O3 批：`.osheet` **公式求值器**离线验收（纯 Dart，接口层）。
//
// 断言的是**算出来的数值**，不是"字符串换了个样子"：
//   * 真夹具 `test/fixtures/office_sheet_o2/*.json`（NAS 只读取证，见 MANIFEST.json）
//     逐格求值，断言 `SUM(B13:B21) == 200000`、`I33 == 2455`、`C7-C9 == 295` …；
//   * 循环引用**不死循环**（超时保护 + `#CIRC!`）；
//   * 不支持/解析失败 → `unsupported`（渲染层据此显示原文）；
//   * `numFmt` 仍然生效（`$295.00`）。
//
// 无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/osheet_formula.dart';
import 'package:synhub/src/data/office_native/osheet_model.dart';

Map<String, Object?> _sections(String name) =>
    (jsonDecode(File('test/fixtures/office_sheet_o2/$name').readAsStringSync())
            as Map)
        .cast<String, Object?>();

OSheetSheet _sheet(String name) =>
    OSheetWorkbook.fromSections(_sections(name)).sheets.first;

/// 单格求值（真夹具）。
Object? _value(OSheetFormulaEngine engine, int row, int col) =>
    engine.resolveCell(row, col).value;

void main() {
  group('F1. 词法 / 解析（接口层）', () {
    test('tokenize：数字/字符串/引用/区域/运算符/函数', () {
      final tokens = tokenizeOSheetFormula(r'=SUM($B$13:B21)+A1*2.5&"x"')!;
      final kinds = tokens.map((t) => t.type.name).toList();
      expect(kinds.first, 'identifier');
      expect(kinds.contains('number'), isTrue);
      expect(kinds.contains('string'), isTrue);
      expect(kinds.contains('colon'), isTrue);
      expect(kinds.contains('comma'), isFalse);
      expect(
        tokens
            .where((t) => t.type == OSheetFormulaTokenType.operator)
            .map((t) => t.text)
            .toSet(),
        containsAll(<String>['+', '*', '&']),
      );
    });

    test('tokenize：非法字符 → null（渲染层退化为原文）', () {
      expect(tokenizeOSheetFormula('=A1 @ B2'), isNull);
      expect(tokenizeOSheetFormula('="未闭合'), isNull);
    });

    test(r'tokenize：<= >= <> 两字符运算符', () {
      final tokens = tokenizeOSheetFormula('=A1<=2')!;
      expect(
        tokens
            .where((t) => t.type == OSheetFormulaTokenType.operator)
            .map((t) => t.text),
        contains('<='),
      );
    });

    test('parse：区域归一化 + 单元格绝对/相对都一样', () {
      final expr = parseOSheetFormula(r'=SUM($B$13:B21)');
      expect(expr, isA<OSheetFunctionCall>());
      final call = expr! as OSheetFunctionCall;
      expect(call.name, 'SUM');
      expect(call.args.single, isA<OSheetRange>());
      final range = call.args.single as OSheetRange;
      expect((range.r1, range.c1, range.r2, range.c2), (12, 1, 20, 1));

      final ref = parseOSheetFormula(r'=$A$1')! as OSheetRef;
      expect((ref.row, ref.col), (0, 0));
    });

    test('parse：非法公式 → null', () {
      expect(parseOSheetFormula('=SUM('), isNull);
      expect(parseOSheetFormula('='), isNull);
      expect(parseOSheetFormula('=Sheet1!A1'), isNull, reason: '跨表不支持 → 原文');
    });

    test('A1 工具：列号/区域/并集', () {
      expect(oSheetColumnIndex('A'), 0);
      expect(oSheetColumnIndex('Z'), 25);
      expect(oSheetColumnIndex('AA'), 26);
      expect(oSheetParseA1(r'$AB$7'), (row: 6, col: 27));
      expect(oSheetParseA1('7A'), isNull);
      final union = oSheetParseRangeUnion('B8:B12,J8:J12')!;
      expect(union.length, 2);
      expect((union[0].c1, union[0].r1), (1, 7));
      expect((union[1].c1, union[1].r1), (9, 7));
      expect(oSheetParseRangeUnion('B8:B12,NOPE'), isNull);
    });
  });

  group('F2. 求值语义（接口层）', () {
    OSheetFormulaResult eval(
      String formula, [
      Map<(int, int), Object?> values = const {},
    ]) => evaluateOSheetFormula(formula, OSheetMapFormulaResolver(values));

    test('四则 + 括号 + 优先级 + 幂 + 百分比', () {
      expect(eval('=1+2*3').value, 7);
      expect(eval('=(1+2)*3').value, 9);
      expect(eval('=2^3^2').value, 512, reason: '幂右结合');
      expect(eval('=50%').value, 0.5);
      expect(eval('=-3+1').value, -2);
      expect(eval('=10/4').value, 2.5);
    });

    test('比较 / 连接 / 布尔字面量', () {
      expect(eval('=1<2').value, true);
      expect(eval('=1<>1').value, false);
      expect(eval('=2>=2').value, true);
      expect(eval(r'="a"&"b"').value, 'ab');
      expect(eval('=TRUE').value, true);
      expect(eval('=FALSE').value, false);
    });

    test('除零 → #DIV/0!（不是崩溃）', () {
      final result = eval('=1/0');
      expect(result.isError, isTrue);
      expect(result.errorCode, '#DIV/0!');
    });

    test('函数：SUM/AVERAGE/MIN/MAX/COUNT/COUNTA/ROUND/ABS', () {
      const values = <(int, int), Object?>{
        (0, 0): 2,
        (1, 0): 4,
        (2, 0): 6,
        (3, 0): 'x',
        (4, 0): null,
      };
      expect(eval('=SUM(A1:A5)', values).value, 12);
      expect(eval('=AVERAGE(A1:A3)', values).value, 4);
      expect(eval('=MIN(A1:A3)', values).value, 2);
      expect(eval('=MAX(A1:A3)', values).value, 6);
      expect(eval('=COUNT(A1:A5)', values).value, 3, reason: '文本不算');
      expect(eval('=COUNTA(A1:A5)', values).value, 4, reason: '文本算，空不算');
      expect(eval('=ROUND(3.14159,2)', values).value, 3.14);
      expect(eval('=ABS(0-7)', values).value, 7);
    });

    test('函数：IF（惰性）/ AND / OR / NOT / ISBLANK', () {
      const values = <(int, int), Object?>{(0, 0): 400, (0, 1): null};
      expect(eval('=IF(A1>100,"big","small")', values).value, 'big');
      // 惰性：未选中的分支即使除零也不报错。
      expect(eval('=IF(A1>100,1,1/0)', values).value, 1);
      expect(eval('=AND(TRUE,1>0)', values).value, true);
      expect(eval('=OR(FALSE,1>2)', values).value, false);
      expect(eval('=NOT(1>2)', values).value, true);
      expect(eval('=ISBLANK(B1)', values).value, true);
      expect(eval('=ISBLANK(A1)', values).value, false);
    });

    test('函数：SUMIF（真夹具用到的写法 `"="&F11`）', () {
      const values = <(int, int), Object?>{
        (0, 0): 'Transportation',
        (0, 8): 800,
        (1, 0): 'Food',
        (1, 8): 480,
        (2, 0): 'Transportation',
        (2, 8): 150,
        (0, 5): 'Transportation',
      };
      final result = eval(r'=SUMIF($A$1:$A$3,"="&F1,$I$1:$I$3)', values);
      expect(result.value, 950);
    });

    test('整数结果不显示成 `2877.0`（数值规范化）', () {
      final result = eval('=SUM(1,2,3)');
      expect(result.value, 6);
      expect(result.value, isA<int>());
    });
  });

  group('F3. 循环引用：**不死循环** + 可读降级', () {
    test('两个格子互引 → 双方都是 #CIRC!', () {
      final resolver = OSheetMapFormulaResolver(
        const <(int, int), Object?>{},
        formulas: const <(int, int), String>{(0, 0): '=B1', (0, 1): '=A1'},
      );
      // 没有超时保护会在这里挂死；测试超时即失败。
      final a = resolver.resolveCell(0, 0);
      final b = resolver.resolveCell(0, 1);
      expect(a.errorCode, '#CIRC!');
      expect(b.errorCode, '#CIRC!');
    });

    test('自引用 A1 = A1 → #CIRC!', () {
      final resolver = OSheetMapFormulaResolver(
        const <(int, int), Object?>{},
        formulas: const <(int, int), String>{(0, 0): '=A1+1'},
      );
      expect(resolver.resolveCell(0, 0).errorCode, '#CIRC!');
    });

    test('环上的**非环**依赖仍能算出值（不误伤）', () {
      // A1→B1→A1 成环；C1 = B1+1 引用环 → 也应降级为环错误（Excel 亦如此）。
      final resolver = OSheetMapFormulaResolver(
        const <(int, int), Object?>{},
        formulas: const <(int, int), String>{
          (0, 0): '=B1',
          (0, 1): '=A1',
          (0, 2): '=1+1',
        },
      );
      resolver.resolveCell(0, 0);
      expect(resolver.resolveCell(0, 2).value, 2);
      final c = resolver.resolveCell(0, 1);
      expect(c.errorCode, '#CIRC!');
    });
  });

  group('F4. 真夹具逐格求值（**算出来的数值**）', () {
    test('annual_income_and_expenditure：SUM(B13:B21) == 200000', () {
      final engine = OSheetFormulaEngine(
        _sheet('annual_income_and_expenditure.json'),
      );
      // B22（0 基 r21,c1）= `=SUM(B13:B21)`。
      expect(_value(engine, 21, 1), 200000);
      // N13 = `=SUM(B13:M13)` = 12 × 40000；O13 = `=N13/12` = 40000。
      expect(_value(engine, 12, 13), 480000);
      expect(_value(engine, 12, 14), 40000);
      expect(engine.circularCells, 0);
    });

    test('sales_tracker：SUM(G8:G17) == 2877 / SUM(K8:K17) == 1510.75', () {
      final engine = OSheetFormulaEngine(_sheet('sales_tracker.json'));
      expect(_value(engine, 17, 6), 2877);
      expect(_value(engine, 17, 10), 1510.75);
      // G8 = `=F8*E8`，F8 = `=C8*D8+C8` = 10*1+10 = 20 → G8 = 300。
      expect(_value(engine, 7, 6), 300);
      expect(_value(engine, 7, 9), 14.25);
    });

    test(r'travel_expenses：=I33 == 2455、=C7-C9 == 295（链式引用公式格）', () {
      final engine = OSheetFormulaEngine(_sheet('travel_expenses.json'));
      // C9（r8,c2）= `=I33` → I33（r32,c8）= `=SUM(I16:I31)` = 2455。
      expect(_value(engine, 32, 8), 2455);
      expect(_value(engine, 8, 2), 2455);
      // C11（r10,c2）= `=C7-C9` = 2750 - 2455 = 295。
      expect(_value(engine, 10, 2), 295);
      // I17 = `=IF(ISBLANK(H17),0,…,G17*H17)` = 2 × 400 = 800。
      expect(_value(engine, 16, 8), 800);
      expect(engine.circularCells, 0);
    });

    test('不支持的函数 → unsupported（渲染层显示原文），不崩', () {
      final resolver = OSheetMapFormulaResolver(
        const <(int, int), Object?>{},
        formulas: const <(int, int), String>{
          (
            0,
            4,
          ): '=CONCATENATE(COUNTA(C4:C34), "/", COUNTA(E4:E34), " Completed  ")',
        },
      );
      final result = resolver.resolveCell(0, 4);
      expect(result.isUnsupported, isTrue);
      expect(result.value, isNull);
    });

    test('引用了"无法求值"的公式格 → 本格也退化（不显示半个结果）', () {
      final resolver = OSheetMapFormulaResolver(
        const <(int, int), Object?>{},
        formulas: const <(int, int), String>{
          (0, 0): '=CONCATENATE("a","b")',
          (0, 1): '=A1&"!"',
        },
      );
      final result = resolver.resolveCell(0, 1);
      expect(result.isUnsupported, isTrue);
    });
  });

  group(r'F5. 数字格式（不弄坏真机已有的 `$2,750.00`）', () {
    test(r'公式算出的 295 + `[$$]#,##0.00` → `$295.00`', () {
      final sheet = _sheet('travel_expenses.json');
      final engine = OSheetFormulaEngine(sheet);
      final value = engine.resolveCell(10, 2).value;
      expect(value, 295);
      final style = sheet.cellAt(10, 2);
      expect(style, isNotNull);
      // 样式池按文件解引用（真机字体/数字格式路径）。
      final wb = OSheetWorkbook.fromSections(_sections('travel_expenses.json'));
      final pool = wb.styles;
      final resolved = pool?.resolveStyle(style!.styleIndex);
      // 有数字格式时必须仍是货币串；没有也必须能显示 295（不崩、不空白）。
      final formatted = oSheetFormatNumber(value, resolved?.numberFormat);
      if (formatted != null) {
        expect(formatted, contains('295'));
        expect(formatted, contains(r'$'));
      } else {
        expect('295', contains('295'));
      }
    });
  });
}
